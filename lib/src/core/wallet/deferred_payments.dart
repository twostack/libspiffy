/// Deferred payments and the holds on their inputs (bead libspiffy-7p2;
/// split out of `BitcoinWalletAggregate` by bead libspiffy-dp4).
library;

import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:eventador/eventador.dart';
import 'package:logging/logging.dart';

import '../../models/bitcoin_utxo.dart';
import '../../models/deferred_payment.dart'
    show DeferredNetworkStatus, DeferredPayment, DeferredPaymentPurpose, DeferredPaymentState;
import '../../models/persistent_map.dart';
import '../../models/wallet_event.dart';
import '../../models/wallet_state.dart';
import '../wallet_commands.dart';
import '../wallet_events.dart';
import 'legacy_deferred_spends.dart';
import 'outgoing_transactions.dart';
import 'state_records.dart';

export 'legacy_deferred_spends.dart' show LegacyDeferredSpend;

final _log = Logger('BitcoinWalletAggregate');

/// The deferred payments of one wallet aggregate.
///
/// A transaction recorded with deferSpend was handed to its recipient, who
/// normally broadcasts it (spv-understanding.md). Its inputs are held until
/// exactly one of: the network reports it (the spend applies), ARC reports
/// it REJECTED (failed, inputs released), or the user cancels it (inputs
/// released). DOUBLE_SPEND_ATTEMPTED is recorded and changes nothing else:
/// ARC may still mine the payment (bead libspiffy-ey2). Reservation expiry,
/// cleanup and reservations of any priority never touch a held input; the
/// aggregate, not a coordinator, enforces it, so it survives restarts and
/// replays.
///
/// A reclaim (bead libspiffy-87a) is the one way a hold moves rather than
/// ends: the wallet records its own transaction spending the held inputs
/// back to itself, the hold moves to that self-spend, and the payment
/// resolves as [DeferredPaymentState.reclaimed] once the network has it.
///
/// State: metadata['deferredSpends'] (txid -> record with state, held keys,
/// last network status; `reclaimTxid` on a payment being reclaimed and
/// `reclaimOf` on the self-spend that reclaims it) and
/// metadata['deferredHolds'] (utxoKey -> txid of the outstanding payment
/// holding it).
///
/// Payments a journal recorded before holds were journaled are inferred from
/// the state ([legacySpends]) and hold their inputs like journaled ones.
class DeferredPayments {
  static const String _deferredSpendsKey = WalletMetadataKeys.deferredSpends;
  static const String _deferredHoldsKey = WalletMetadataKeys.deferredHolds;

  /// `reservationReason` of a held input.
  static const String holdReason = 'deferred-spend';

  /// `reservationPriority` of a held input. Informational: a hold is refused
  /// to every reservation by rule, not by priority.
  static const int holdPriority = 1 << 30;

  /// The deferred-payment record of [txid] in [state], or null.
  static Map? record(WalletState state, String txid) {
    final records = state.metadata[_deferredSpendsKey];
    final record = records is Map ? records[txid] : null;
    return record is Map ? record : null;
  }

  /// The outstanding deferred payment holding [utxoKey], journaled holds only.
  static String? explicitHolder(WalletState state, String utxoKey) {
    final holds = state.metadata[_deferredHoldsKey];
    return holds is Map ? holds[utxoKey]?.toString() : null;
  }

  /// The outstanding deferred payment holding [utxoKey]: a journaled hold, or
  /// one inferred from a journal older than the holds.
  String? holderOf(WalletState state, String utxoKey) {
    final explicit = explicitHolder(state, utxoKey);
    if (explicit != null) return explicit;
    for (final legacy in legacySpends(state)) {
      if (legacy.heldKeys.contains(utxoKey)) return legacy.txid;
    }
    return null;
  }

  /// The keys every un-journaled outstanding deferred payment holds.
  Set<String> legacyHeldKeys(WalletState state) => state.legacyDeferredHeldKeys;

  /// Carries the finding "no un-journaled deferred payment" of [current]
  /// over to [next], the state the application of [event] turned it into,
  /// unless [event] can create such a payment (a recorded transaction, a
  /// received UTXO, a reverted confirmation): the inference then runs once
  /// per state change that could create one, not once per event.
  void stateApplied(WalletState current, WalletState next, WalletEvent event) {
    if (event is UTXOReceivedEvent || event is TransactionRecordedEvent || event is TransactionConfirmationRevertedEvent) {
      return;
    }
    next.carryNoLegacyDeferredSpendsFrom(current);
  }

  /// Outgoing transactions recorded with a deferred spend before holds were
  /// journaled, still outstanding ([inferLegacyDeferredSpends], computed
  /// once per state: [WalletState.legacyDeferredSpends]).
  List<LegacyDeferredSpend> legacySpends(WalletState state) => state.legacyDeferredSpends;

  /// `{'utxoKey', 'satoshis'}` of each of [keys].
  static List<Map<String, dynamic>> _heldInputMaps(WalletState state, Iterable<String> keys) => [
        for (final key in keys) {'utxoKey': key, 'satoshis': (state.utxos[key]?.satoshis ?? BigInt.zero).toString()},
      ];

  /// The hold of [command]'s transaction: the wallet's unspent inputs it
  /// spends that no other deferred payment holds.
  ///
  /// [supersedes] is the one deferred payment whose hold this transaction
  /// takes over: the payment a reclaim's self-spend reclaims (bead
  /// libspiffy-87a). For every other payment the first hold still wins.
  TransactionSpendDeferredEvent holdEvent(
    WalletState state,
    RecordOutgoingTransactionCommand command, {
    required int version,
    bool reactivated = false,
    String? supersedes,
  }) {
    final held = <String>[];
    for (final key in command.spentUtxoKeys.toSet()) {
      final utxo = state.utxos[key];
      if (utxo == null || utxo.status == UTXOStatus.spent) continue;
      final holder = holderOf(state, key);
      if (holder != null && holder != command.txid && holder != supersedes) {
        _log.warning('Input $key of ${command.txid} is already held by deferred payment $holder; '
            'not held again');
        continue;
      }
      held.add(key);
    }
    final now = DateTime.now();
    return TransactionSpendDeferredEvent(
      walletId: command.walletId,
      txid: command.txid,
      heldInputs: _heldInputMaps(state, held),
      recipientAddresses: command.recipientAddresses,
      paymentAmount: command.paymentAmount.toString(),
      fee: command.fee,
      invoiceId: command.invoiceId,
      purpose: command.purpose,
      reactivated: reactivated,
      supersedes: supersedes,
      recordedAt: now,
      version: version,
      timestamp: now,
    );
  }

  /// Hold events for every un-journaled outstanding deferred payment
  /// ([legacySpends]), versions from [firstVersion].
  List<TransactionSpendDeferredEvent> inferredHoldEvents(WalletState state, String walletId, int firstVersion) {
    final legacy = legacySpends(state);
    final now = DateTime.now();
    return [
      for (var i = 0; i < legacy.length; i++)
        TransactionSpendDeferredEvent(
          walletId: walletId,
          txid: legacy[i].txid,
          heldInputs: _heldInputMaps(state, legacy[i].heldKeys),
          recipientAddresses: [
            for (final a in (legacy[i].record['recipientAddresses'] as List? ?? const [])) a.toString(),
          ],
          paymentAmount: legacy[i].record['paymentAmount']?.toString() ?? '0',
          fee: (legacy[i].record['fee'] as num?)?.toInt() ?? 0,
          purpose: 'legacy',
          inferred: true,
          recordedAt: DateTime.tryParse(legacy[i].record['recordedAt']?.toString() ?? '') ?? now,
          version: firstVersion + i,
          timestamp: now,
        ),
    ];
  }

  /// The inputs [txid] holds and the status each returns to on release.
  /// [inferredKeys] are the keys of a hold journaled in the same command.
  static List<ReleasedDeferredInput> _releasableInputs(WalletState state, String txid, {List<String>? inferredKeys}) {
    final holds = state.metadata[_deferredHoldsKey];
    final keys = inferredKeys ??
        [
          if (holds is Map)
            for (final entry in holds.entries)
              if (entry.value?.toString() == txid) entry.key.toString(),
        ];
    return [
      for (final key in keys)
        if (state.utxos[key] case final utxo? when utxo.status != UTXOStatus.spent)
          ReleasedDeferredInput(utxoKey: key, restoredStatus: utxo.statusToRestoreOnRelease),
    ];
  }

  // ---------------------------------------------------------------------------
  // Commands
  // ---------------------------------------------------------------------------

  List<Event> reconcile(WalletState currentState, ReconcileDeferredSpendsCommand command) {
    if (!currentState.isCreated) return const [];
    final events = inferredHoldEvents(currentState, command.walletId, currentState.version + 1);
    if (events.isNotEmpty) {
      _log.info('Wallet ${command.walletId}: ${events.length} deferred payment(s) recorded before '
          'holds were journaled are held now: ${[for (final e in events) e.txid]}');
    }
    return events;
  }

  List<Event> recordNetworkStatus(WalletState currentState, RecordTransactionNetworkStatusCommand command) {
    if (!currentState.isCreated) {
      throw StateError('Cannot record a network status for non-existent wallet');
    }
    final events = <Event>[];
    final record = DeferredPayments.record(currentState, command.txid);
    List<String>? inferredKeys;
    if (record == null) {
      final inferred = inferredHoldEvents(currentState, command.walletId, currentState.version + 1);
      final own = inferred.where((e) => e.txid == command.txid).firstOrNull;
      if (own == null) return const []; // not a deferred payment of this wallet
      events.addAll(inferred);
      inferredKeys = own.heldUtxoKeys;
    }

    final state = record?['state']?.toString() ?? DeferredPaymentState.outstanding.name;
    final definitiveFailure =
        DeferredNetworkStatus.isDefinitiveFailure(command.networkStatus) && state == DeferredPaymentState.outstanding.name;
    // A competing transaction the record does not list yet is news even when
    // the status is unchanged (bead libspiffy-pkum).
    final newCompetitor =
        DeferredPayment.mergeCompetingTxids(record?['competingTxids'] as List?, command.competingTxids) != null;
    if (command.explicit ||
        definitiveFailure ||
        newCompetitor ||
        record?['lastNetworkStatus'] != command.networkStatus) {
      events.add(TransactionNetworkStatusCheckedEvent(
        walletId: command.walletId,
        txid: command.txid,
        networkStatus: command.networkStatus,
        source: command.source,
        checkedAt: command.checkedAt,
        blockHeight: command.blockHeight,
        explicit: command.explicit,
        competingTxids: command.competingTxids,
        version: currentState.version + events.length + 1,
        timestamp: DateTime.now(),
      ));
    }
    if (definitiveFailure) {
      final released = _releasableInputs(currentState, command.txid, inferredKeys: inferredKeys);
      events.add(DeferredTransactionFailedEvent(
        walletId: command.walletId,
        txid: command.txid,
        networkStatus: command.networkStatus,
        reason: command.detail ?? '${command.source} reported ${command.networkStatus}',
        releasedInputs: released,
        version: currentState.version + events.length + 1,
        timestamp: DateTime.now(),
      ));
      _log.warning('Deferred payment ${command.txid} failed (${command.networkStatus}); '
          'released ${released.length} input(s)');
    }
    return events;
  }

  List<Event> cancel(WalletState currentState, CancelDeferredSpendCommand command) {
    if (!currentState.isCreated) {
      throw StateError('Cannot cancel a deferred payment of non-existent wallet');
    }
    final events = <Event>[];
    final record = DeferredPayments.record(currentState, command.txid);
    List<String>? inferredKeys;
    if (record == null) {
      final inferred = inferredHoldEvents(currentState, command.walletId, currentState.version + 1);
      final own = inferred.where((e) => e.txid == command.txid).firstOrNull;
      if (own == null) {
        throw StateError('Transaction ${command.txid} is not a deferred payment of wallet ${command.walletId}');
      }
      events.addAll(inferred);
      inferredKeys = own.heldUtxoKeys;
    }
    final state = record?['state']?.toString() ?? DeferredPaymentState.outstanding.name;
    if (state != DeferredPaymentState.outstanding.name) {
      throw StateError('Deferred payment ${command.txid} is $state, not outstanding; nothing to cancel');
    }
    final reclaimedBy = record?['reclaimTxid']?.toString();
    if (reclaimedBy != null) {
      throw StateError('Deferred payment ${command.txid} is being reclaimed by $reclaimedBy; '
          'it cannot be cancelled (the reclaim resolves it once the network has the self-spend)');
    }
    // A reclaim is immediate and irreversible: cancelling the self-spend
    // would release the inputs it took over and leave the payment it
    // reclaims stranded, held by nothing and reclaimable by nothing.
    final reclaimOf = record?['reclaimOf']?.toString();
    if (reclaimOf != null) {
      throw StateError('Transaction ${command.txid} is the reclaim of deferred payment $reclaimOf; '
          'a reclaim cannot be cancelled');
    }
    final lastStatus = record?['lastNetworkStatus']?.toString();
    if (DeferredNetworkStatus.isOnNetwork(lastStatus) || DeferredNetworkStatus.isOnNetwork(command.networkStatus)) {
      throw StateError('Deferred payment ${command.txid} is known to the network '
          '(${command.networkStatus ?? lastStatus}); it cannot be cancelled');
    }
    final released = _releasableInputs(currentState, command.txid, inferredKeys: inferredKeys);
    events.add(DeferredTransactionCancelledEvent(
      walletId: command.walletId,
      txid: command.txid,
      reason: command.reason,
      networkStatus: command.networkStatus,
      releasedInputs: released,
      version: currentState.version + events.length + 1,
      timestamp: DateTime.now(),
    ));
    return events;
  }

  /// Reclaims the outstanding deferred payment [command]`.txid`: records the
  /// wallet's own self-spend of its held inputs, moves the hold to that
  /// transaction and journals the reclaim (bead libspiffy-87a).
  ///
  /// The payment is not resolved here. It becomes
  /// [DeferredPaymentState.reclaimed] when the network has the self-spend
  /// (seen or mined), so a self-spend that never reaches the network leaves
  /// the payment outstanding with its inputs still held — by the self-spend.
  ///
  /// Refused for a payment that is not outstanding, one already being
  /// reclaimed, one whose hold was never journaled (run
  /// [ReconcileDeferredSpendsCommand] first), and for a transaction that
  /// does not spend exactly the inputs the payment holds or pays no fee.
  List<Event> reclaim(
      WalletState currentState, ReclaimDeferredSpendCommand command, OutgoingTransactions outgoing) {
    if (!currentState.isCreated) {
      throw StateError('Cannot reclaim a deferred payment of non-existent wallet');
    }
    final record = DeferredPayments.record(currentState, command.txid);
    if (record == null) {
      throw StateError('Transaction ${command.txid} is not a journaled deferred payment of wallet '
          '${command.walletId}; reconcile the wallet (ReconcileDeferredSpendsCommand) before reclaiming it');
    }
    final state = record['state']?.toString() ?? DeferredPaymentState.outstanding.name;
    if (state != DeferredPaymentState.outstanding.name) {
      throw StateError('Deferred payment ${command.txid} is $state, not outstanding; nothing to reclaim');
    }
    final inFlight = record['reclaimTxid']?.toString();
    if (inFlight != null) {
      throw StateError('Deferred payment ${command.txid} is already being reclaimed by $inFlight');
    }
    if (command.reclaimTxid == command.txid) {
      throw ArgumentError('The reclaim of ${command.txid} cannot be the payment itself');
    }

    final holds = currentState.metadata[_deferredHoldsKey];
    final heldKeys = <String>[
      if (holds is Map)
        for (final entry in holds.entries)
          if (entry.value?.toString() == command.txid) entry.key.toString(),
    ]..sort();
    if (heldKeys.isEmpty) {
      throw StateError('Deferred payment ${command.txid} holds no inputs; there is nothing to reclaim');
    }
    for (final key in heldKeys) {
      final utxo = currentState.utxos[key];
      if (utxo == null || utxo.status == UTXOStatus.spent) {
        throw StateError('Input $key of deferred payment ${command.txid} is spent or unknown; '
            'it cannot be reclaimed');
      }
    }

    final dartsv.Transaction parsed;
    try {
      parsed = dartsv.Transaction.fromHex(command.rawHex);
    } catch (e) {
      throw ArgumentError('The reclaim transaction of ${command.txid} does not parse: $e');
    }
    if (parsed.id != command.reclaimTxid) {
      throw ArgumentError('The reclaim transaction is ${parsed.id}, not ${command.reclaimTxid}');
    }
    final spends = <String>{
      for (final input in parsed.inputs) '${input.prevTxnId}:${input.prevTxnOutputIndex}',
    };
    if (spends.length != heldKeys.length || !spends.containsAll(heldKeys)) {
      throw StateError('The reclaim ${command.reclaimTxid} spends $spends, not exactly the inputs '
          'deferred payment ${command.txid} holds ($heldKeys)');
    }

    final totalIn = heldKeys.fold(BigInt.zero, (sum, k) => sum + (currentState.utxos[k]?.satoshis ?? BigInt.zero));
    final totalOut = parsed.outputs.fold(BigInt.zero, (sum, o) => sum + o.satoshis);
    if (totalOut >= totalIn) {
      throw StateError('The reclaim ${command.reclaimTxid} pays out $totalOut of $totalIn satoshis; '
          'it leaves no fee');
    }

    // The self-spend is an outgoing transaction like any other, recorded
    // with a deferred spend so its inputs are not marked spent before the
    // network has it; its hold takes over the reclaimed payment's.
    final events = outgoing.recordOutgoing(
      currentState,
      RecordOutgoingTransactionCommand(
        walletId: command.walletId,
        txid: command.reclaimTxid,
        rawHex: command.rawHex,
        totalInputSats: totalIn.toInt(),
        totalOutputSats: totalOut.toInt(),
        fee: (totalIn - totalOut).toInt(),
        numInputs: parsed.inputs.length,
        numOutputs: parsed.outputs.length,
        txVersion: parsed.version,
        txLockTime: parsed.nLockTime,
        spentUtxoKeys: heldKeys,
        recipientAddresses: command.recipientAddresses,
        paymentAmount: totalOut,
        deferSpend: true,
        purpose: DeferredPaymentPurpose.reclaimOf(command.txid),
      ),
      supersedesDeferred: command.txid,
    );
    events.add(DeferredSpendReclaimedEvent(
      walletId: command.walletId,
      txid: command.txid,
      reclaimTxid: command.reclaimTxid,
      reclaimedUtxoKeys: heldKeys,
      reason: command.reason,
      version: currentState.version + events.length + 1,
      timestamp: DateTime.now(),
    ));
    _log.info('Deferred payment ${command.txid} is being reclaimed by ${command.reclaimTxid}: '
        '${heldKeys.length} input(s), ${totalIn - totalOut} satoshis fee');
    return events;
  }

  // ---------------------------------------------------------------------------
  // Events
  // ---------------------------------------------------------------------------

  /// The deferred-payment records in [state] (converted and stored once,
  /// e.g. after a snapshot's untyped round trip; afterwards returned as is,
  /// so applying an event costs no copy of every record).
  static PersistentMap<String, dynamic> _recordsForUpdate(WalletStateBuilder state) {
    final existing = state.metadata[_deferredSpendsKey];
    if (existing is PersistentMap<String, dynamic>) return existing;
    var records = PersistentMap<String, dynamic>.empty();
    if (existing is Map) {
      existing.forEach((txid, record) => records = records.put(txid.toString(), freezeDeep(record)));
    }
    state.metadata = state.metadata.put(_deferredSpendsKey, records);
    return records;
  }

  /// The record of [txid] in [state], or null (creates no metadata entry).
  /// A changed record is stored back with [_putRecord].
  static PersistentMap<String, dynamic>? _recordForUpdate(WalletStateBuilder state, String txid) {
    if (state.metadata[_deferredSpendsKey] is! Map) return null;
    final record = _recordsForUpdate(state)[txid];
    return record is Map ? frozenRecord(record) : null;
  }

  static void _putRecord(WalletStateBuilder state, String txid, PersistentMap<String, dynamic> record) {
    state.metadata = state.metadata.put(_deferredSpendsKey, _recordsForUpdate(state).put(txid, record));
  }

  /// The deferred holds in [state] (converted and stored once).
  static PersistentMap<String, dynamic> _holdsForUpdate(WalletStateBuilder state) {
    final existing = state.metadata[_deferredHoldsKey];
    if (existing is PersistentMap<String, dynamic>) return existing;
    var holds = PersistentMap<String, dynamic>.empty();
    if (existing is Map) {
      existing.forEach((key, txid) => holds = holds.put(key.toString(), txid.toString()));
    }
    state.metadata = state.metadata.put(_deferredHoldsKey, holds);
    return holds;
  }

  static void applySpendDeferred(WalletStateBuilder state, TransactionSpendDeferredEvent event) {
    var records = _recordsForUpdate(state);
    final reactivated = event.reactivated ? _recordForUpdate(state, event.txid) : null;
    if (reactivated != null && reactivated['state'] == DeferredPaymentState.cancelled.name) {
      // Outstanding again (bead libspiffy-4r0); the cancellation stays in
      // the journal.
      records = records.put(
        event.txid,
        reactivated
            .put('state', DeferredPaymentState.outstanding.name)
            .put('heldUtxoKeys', freezeDeep(event.heldUtxoKeys))
            .put('reactivatedAt', event.timestamp.toIso8601String())
            .without('resolvedAt')
            .without('resolutionReason'),
      );
      // It can settle again, so its own change is pending again rather than
      // voided (bead libspiffy-3arz).
      _unvoidOwnOutputs(state, event.txid, event.timestamp);
    }
    if (!records.containsKey(event.txid)) {
      records = records.put(
        event.txid,
        freezeMap(<String, dynamic>{
          'txid': event.txid,
          'heldUtxoKeys': event.heldUtxoKeys,
          'state': DeferredPaymentState.outstanding.name,
          'invoiceId': event.invoiceId,
          'purpose': event.purpose,
          'inferred': event.inferred,
          'recordedAt': event.recordedAt.toIso8601String(),
        }),
      );
    }
    state.metadata = state.metadata.put(_deferredSpendsKey, records);
    var holds = _holdsForUpdate(state);
    for (final key in event.heldUtxoKeys) {
      final utxo = state.utxos[key];
      if (utxo == null || utxo.status == UTXOStatus.spent) continue;
      final holder = holds[key];
      // The first hold wins, except where a reclaim's self-spend takes over
      // the hold of the payment it reclaims (bead libspiffy-87a).
      if (holder != null && holder != event.txid && holder != event.supersedes) continue;
      holds = holds.put(key, event.txid);
      state.putUtxo(
        key,
        utxo.copyWith(
          status: UTXOStatus.reserved,
          statusBeforeReservation: utxo.statusToRestoreOnRelease,
          reservedByTxId: event.txid,
          reservationExpiresAt: null,
          reservationPriority: holdPriority,
          reservationReason: holdReason,
          updatedAt: event.timestamp,
        ),
      );
    }
    state.metadata = state.metadata.put(_deferredHoldsKey, holds);
    state.version = event.version;
    state.lastModified = event.timestamp;
  }

  /// An outstanding, failed or cancelled deferred payment [txid] is on the
  /// network. When [txid] is a reclaim's self-spend, the payment it reclaims
  /// resolves now (bead libspiffy-87a): that is the moment the recipient's
  /// copy can no longer be mined.
  static void _markSeen(WalletStateBuilder state, String txid, DateTime at) {
    final record = _recordForUpdate(state, txid);
    if (record == null) return;
    final paymentState = record['state'];
    if (paymentState == DeferredPaymentState.outstanding.name ||
        paymentState == DeferredPaymentState.failed.name ||
        paymentState == DeferredPaymentState.cancelled.name) {
      _putRecord(
        state,
        txid,
        record.put('state', DeferredPaymentState.seen.name).put('resolvedAt', at.toIso8601String()),
      );
    }
    final reclaims = record['reclaimOf']?.toString();
    if (reclaims != null) _resolveReclaimed(state, reclaims, txid, at);
  }

  /// The deferred payment [txid] is reclaimed: [reclaimTxid], the wallet's
  /// own self-spend of its inputs, is on the network. Terminal; a payment
  /// already resolved otherwise is left as it is.
  static void _resolveReclaimed(WalletStateBuilder state, String txid, String reclaimTxid, DateTime at) {
    final record = _recordForUpdate(state, txid);
    if (record == null || record['state'] != DeferredPaymentState.outstanding.name) return;
    _putRecord(
      state,
      txid,
      record
          .put('state', DeferredPaymentState.reclaimed.name)
          .put('resolvedAt', at.toIso8601String())
          .put('resolutionReason', DeferredPayment.reclaimedBy(reclaimTxid)),
    );
    _voidOwnOutputs(state, txid, at);
  }

  /// The wallet's own pending outputs of [txid] — its change — say what is
  /// true once [txid] is resolved as a payment the network will not settle:
  /// they are [UTXOStatus.voided] rather than pending forever (bead
  /// libspiffy-3arz).
  ///
  /// Nothing is deleted and nothing is rewritten beyond the status
  /// (spv-understanding.md, Data Retention): the row, its amount, its script
  /// and its reservation history stay. Only a `pending` output is touched —
  /// one already `available` was confirmed by a proof, which outranks any
  /// resolution we recorded, and a `reserved` or `spent` one is somebody
  /// else's business.
  ///
  /// This does not close the door on a later confirmation. Confirming [txid]
  /// makes its voided outputs available again (`OutgoingTransactions.confirm`),
  /// exactly as it does its pending ones, and recording the payment again
  /// takes them back to pending ([_unvoidOwnOutputs]).
  static void _voidOwnOutputs(WalletStateBuilder state, String txid, DateTime at) {
    for (final entry in state.utxos.entries) {
      final utxo = entry.value;
      if (utxo.txid != txid || utxo.status != UTXOStatus.pending) continue;
      state.putUtxo(entry.key, utxo.markVoided(timestamp: at));
    }
  }

  /// The reverse: a payment that is outstanding again (bead libspiffy-4r0)
  /// can settle again, so its own voided outputs are pending again.
  static void _unvoidOwnOutputs(WalletStateBuilder state, String txid, DateTime at) {
    for (final entry in state.utxos.entries) {
      final utxo = entry.value;
      if (utxo.txid != txid || utxo.status != UTXOStatus.voided) continue;
      state.putUtxo(entry.key, utxo.copyWith(status: UTXOStatus.pending, updatedAt: at));
    }
  }

  /// A reclaim was journaled: the reclaimed payment names its self-spend and
  /// the self-spend names the payment it reclaims. Neither is resolved here.
  static void applyReclaimed(WalletStateBuilder state, DeferredSpendReclaimedEvent event) {
    final reclaimed = _recordForUpdate(state, event.txid);
    if (reclaimed != null && reclaimed['reclaimTxid'] == null) {
      _putRecord(state, event.txid, reclaimed.put('reclaimTxid', event.reclaimTxid));
    }
    final self = _recordForUpdate(state, event.reclaimTxid);
    if (self != null) {
      if (self['reclaimOf'] == null) {
        _putRecord(state, event.reclaimTxid, self.put('reclaimOf', event.txid));
      }
      // Replayed (or journaled) after the self-spend already reached the
      // network: the payment is reclaimed now.
      final selfState = self['state'];
      if (selfState == DeferredPaymentState.seen.name || selfState == DeferredPaymentState.mined.name) {
        _resolveReclaimed(state, event.txid, event.reclaimTxid, event.timestamp);
      }
    }
    state.version = event.version;
    state.lastModified = event.timestamp;
  }

  /// [utxoKey] was spent by [spentInTxId]: a spent input is held by nobody,
  /// and a deferred payment whose input the transaction itself spent is on
  /// the network.
  ///
  /// When the input was held by a reclaim's self-spend and something else
  /// spent it, that reclaim lost (bead libspiffy-wfvi): it is failed here and
  /// now, without waiting for ARC to report it REJECTED. See [_failLostReclaim].
  static void applyInputSpent(WalletStateBuilder state, String utxoKey, String spentInTxId, DateTime at) {
    final holds = state.metadata[_deferredHoldsKey];
    String? holder;
    if (holds is Map && holds.containsKey(utxoKey)) {
      holder = holds[utxoKey]?.toString();
      state.metadata = state.metadata.put(_deferredHoldsKey, frozenRecord(holds).without(utxoKey));
    }
    _markSeen(state, spentInTxId, at);
    if (holder != null && holder != spentInTxId) {
      _failLostReclaim(state, holder, utxoKey, spentInTxId, at);
    }
  }

  /// A reclaim's self-spend [reclaimTxid] held [utxoKey] and [spentInTxId] —
  /// another transaction, in practice the recipient's copy of the payment
  /// being reclaimed — spent it. The self-spend can never be mined now, so
  /// the reclaim is failed with the reason (bead libspiffy-wfvi).
  ///
  /// This is Bitcoin SV: of two spends of one input the one the network saw
  /// first is mined and the other is rejected, whatever fee it carries
  /// (spv-understanding.md, Critical Implementation Note 3). There is no
  /// replace-by-fee, so nothing here looks at, raises or retries a fee: the
  /// race is over and the only thing left to do is record the outcome
  /// accurately instead of waiting for ARC to say the same thing.
  ///
  /// Only a reclaim is failed this way. An ordinary deferred payment whose
  /// input another transaction spends stays outstanding and keeps being
  /// polled (bead libspiffy-ey2): either transaction may still be mined, and
  /// the wallet does not decide that from a spend it observed.
  static void _failLostReclaim(
      WalletStateBuilder state, String reclaimTxid, String utxoKey, String spentInTxId, DateTime at) {
    final record = _recordForUpdate(state, reclaimTxid);
    if (record == null) return;
    final reclaims = record['reclaimOf']?.toString();
    if (reclaims == null) return; // not a reclaim's self-spend
    if (record['state'] != DeferredPaymentState.outstanding.name) return;
    _putRecord(
      state,
      reclaimTxid,
      record
          .put('state', DeferredPaymentState.failed.name)
          .put('resolvedAt', at.toIso8601String())
          .put('resolutionReason', DeferredPayment.reclaimLostRace(utxoKey, spentInTxId)),
    );
    _voidOwnOutputs(state, reclaimTxid, at);
    _log.warning('The reclaim $reclaimTxid of deferred payment $reclaims failed: its input $utxoKey was '
        'spent by $spentInTxId. First seen wins on this network, so the self-spend can no longer be '
        'mined; no fee would have changed that');
  }

  /// [txid] is confirmed: a deferred payment of it is mined.
  static void applyConfirmed(WalletStateBuilder state, String txid, DateTime at) {
    final deferred = _recordForUpdate(state, txid);
    if (deferred != null) {
      var mined = deferred.put('state', DeferredPaymentState.mined.name);
      if (mined['resolvedAt'] == null) mined = mined.put('resolvedAt', at.toIso8601String());
      _putRecord(state, txid, mined);
      final reclaims = deferred['reclaimOf']?.toString();
      if (reclaims != null) _resolveReclaimed(state, reclaims, txid, at);
    }
  }

  /// [txid] is no longer confirmed: a mined deferred payment of it is back to
  /// seen.
  static void applyConfirmationReverted(WalletStateBuilder state, String txid) {
    final deferred = _recordForUpdate(state, txid);
    if (deferred != null && deferred['state'] == DeferredPaymentState.mined.name) {
      _putRecord(state, txid, deferred.put('state', DeferredPaymentState.seen.name));
    }
  }

  static void applyNetworkStatusChecked(WalletStateBuilder state, TransactionNetworkStatusCheckedEvent event) {
    final record = _recordForUpdate(state, event.txid);
    if (record != null) {
      var updated = record
          .put('lastNetworkStatus', event.networkStatus)
          .put('lastNetworkStatusSource', event.source)
          .put('lastCheckedAt', event.checkedAt.toIso8601String());
      // Every competing txid ARC named so far, first-reported order (bead
      // libspiffy-pkum); a status naming none keeps them.
      final competing = DeferredPayment.mergeCompetingTxids(record['competingTxids'] as List?, event.competingTxids);
      if (competing != null) updated = updated.put('competingTxids', freezeDeep(competing));
      _putRecord(state, event.txid, updated);
      if (DeferredNetworkStatus.isOnNetwork(event.networkStatus)) {
        _markSeen(state, event.txid, event.timestamp);
      }
    }
    state.version = event.version;
    state.lastModified = event.timestamp;
  }

  static void applyFailed(WalletStateBuilder state, DeferredTransactionFailedEvent failed) => _applyResolution(
      state, failed.txid, DeferredPaymentState.failed, failed.releasedInputs, failed.reason ?? failed.networkStatus, failed);

  static void applyCancelled(WalletStateBuilder state, DeferredTransactionCancelledEvent cancelled) =>
      _applyResolution(state, cancelled.txid, DeferredPaymentState.cancelled, cancelled.releasedInputs,
          cancelled.reason, cancelled);

  /// A deferred payment failed or was cancelled: each released input still
  /// reserved by it returns to its recorded status, and the transaction's own
  /// pending outputs — its change — become [UTXOStatus.voided], since that
  /// transaction is not one the network is going to settle (bead
  /// libspiffy-3arz). Nothing is deleted; see [_voidOwnOutputs].
  static void _applyResolution(WalletStateBuilder state, String txid, DeferredPaymentState resolution,
      List<ReleasedDeferredInput> released, String? reason, WalletEvent event) {
    final record = _recordForUpdate(state, txid);
    if (record != null && record['state'] == DeferredPaymentState.outstanding.name) {
      _putRecord(
        state,
        txid,
        record
            .put('state', resolution.name)
            .put('resolvedAt', event.timestamp.toIso8601String())
            .put('resolutionReason', reason),
      );
    }
    _voidOwnOutputs(state, txid, event.timestamp);
    for (final input in released) {
      final holds = state.metadata[_deferredHoldsKey];
      if (holds is Map && holds[input.utxoKey]?.toString() == txid) {
        state.metadata = state.metadata.put(_deferredHoldsKey, frozenRecord(holds).without(input.utxoKey));
      }
      final utxo = state.utxos[input.utxoKey];
      if (utxo != null && utxo.status == UTXOStatus.reserved && utxo.reservedByTxId == txid) {
        state.putUtxo(
          input.utxoKey,
          utxo.releaseReservation(restoreStatus: input.restoredStatus, timestamp: event.timestamp),
        );
      }
    }
    state.version = event.version;
    state.lastModified = event.timestamp;
  }
}
