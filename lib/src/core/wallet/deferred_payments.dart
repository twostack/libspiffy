/// Deferred payments and the holds on their inputs (bead libspiffy-7p2;
/// split out of `BitcoinWalletAggregate` by bead libspiffy-dp4).
library;

import 'package:eventador/eventador.dart';
import 'package:logging/logging.dart';

import '../../models/bitcoin_utxo.dart';
import '../../models/deferred_payment.dart' show DeferredNetworkStatus, DeferredPaymentState;
import '../../models/persistent_map.dart';
import '../../models/wallet_event.dart';
import '../../models/wallet_state.dart';
import '../wallet_commands.dart';
import '../wallet_events.dart';
import 'state_records.dart';

final _log = Logger('BitcoinWalletAggregate');

/// The deferred payments of one wallet aggregate.
///
/// A transaction recorded with deferSpend was handed to its recipient, who
/// normally broadcasts it (spv-understanding.md). Its inputs are held until
/// exactly one of: the network reports it (the spend applies), ARC reports
/// it REJECTED / DOUBLE_SPEND_ATTEMPTED (failed, inputs released), or the
/// user cancels it (inputs released). Reservation expiry, cleanup and
/// reservations of any priority never touch a held input; the aggregate,
/// not a coordinator, enforces it, so it survives restarts and replays.
///
/// State: metadata['deferredSpends'] (txid -> record with state, held keys,
/// last network status) and metadata['deferredHolds'] (utxoKey -> txid of
/// the outstanding payment holding it).
///
/// An instance belongs to one aggregate: it caches the last state found to
/// hold no un-journaled deferred payment ([stateApplied] keeps the cache).
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
  Set<String> legacyHeldKeys(WalletState state) => {for (final l in legacySpends(state)) ...l.heldKeys};

  /// The state last found to hold no un-journaled deferred payment, so the
  /// inference below runs once per state change that could create one (a
  /// recorded transaction, a received UTXO, a reverted confirmation).
  WalletState? _noLegacyDeferredSpendsIn;

  /// Keeps the cached "no un-journaled deferred payment" check across the
  /// application of [event], which turned [current] into [next]: the check
  /// carries over unless the event can create such a payment.
  void stateApplied(WalletState current, WalletState next, WalletEvent event) {
    if (event is UTXOReceivedEvent || event is TransactionRecordedEvent || event is TransactionConfirmationRevertedEvent) {
      _noLegacyDeferredSpendsIn = null;
    } else if (identical(_noLegacyDeferredSpendsIn, current)) {
      _noLegacyDeferredSpendsIn = next;
    }
  }

  /// Outgoing transactions recorded with a deferred spend before holds were
  /// journaled, still outstanding: a record with no deferred-payment record,
  /// not confirmed, whose inputs the wallet still has unspent. A record
  /// without deferSpend spent its inputs in its own command, so it never
  /// qualifies. Oldest record first; an input two records list is held by
  /// the older one.
  List<LegacyDeferredSpend> legacySpends(WalletState state) {
    if (identical(_noLegacyDeferredSpendsIn, state)) return const [];
    final records = state.metadata[WalletMetadataKeys.outgoingTransactions];
    final deferred = state.metadata[_deferredSpendsKey];
    final holds = state.metadata[_deferredHoldsKey];

    // One pass over the records keeps the candidates (usually none); only
    // those are ordered.
    bool unheldUnspent(Object? key) {
      final utxo = state.utxos[key.toString()];
      return utxo != null && utxo.status != UTXOStatus.spent && !(holds is Map && holds.containsKey(key.toString()));
    }

    final candidates = <Map>[
      for (final record in <Object?>[
        if (records is Map) ...records.values,
        if (records is List) ...records,
      ])
        if (record is Map &&
            record['txid'] != null &&
            !(deferred is Map && deferred.containsKey(record['txid'].toString())) &&
            record['status'] != 'confirmed' &&
            record['spentUtxoKeys'] is List &&
            (record['spentUtxoKeys'] as List).any(unheldUnspent))
          record,
    ]..sort((a, b) => (a['recordedAt']?.toString() ?? '').compareTo(b['recordedAt']?.toString() ?? ''));

    final claimed = <String>{};
    final result = <LegacyDeferredSpend>[];
    for (final record in candidates) {
      final held = <String>[
        for (final k in record['spentUtxoKeys'] as List)
          if (unheldUnspent(k) && claimed.add(k.toString())) k.toString(),
      ];
      if (held.isNotEmpty) result.add(LegacyDeferredSpend(record['txid'].toString(), held, record));
    }
    if (result.isEmpty) _noLegacyDeferredSpendsIn = state;
    return result;
  }

  /// `{'utxoKey', 'satoshis'}` of each of [keys].
  static List<Map<String, dynamic>> _heldInputMaps(WalletState state, Iterable<String> keys) => [
        for (final key in keys) {'utxoKey': key, 'satoshis': (state.utxos[key]?.satoshis ?? BigInt.zero).toString()},
      ];

  /// The hold of [command]'s transaction: the wallet's unspent inputs it
  /// spends that no other deferred payment holds.
  TransactionSpendDeferredEvent holdEvent(
    WalletState state,
    RecordOutgoingTransactionCommand command, {
    required int version,
    bool reactivated = false,
  }) {
    final held = <String>[];
    for (final key in command.spentUtxoKeys.toSet()) {
      final utxo = state.utxos[key];
      if (utxo == null || utxo.status == UTXOStatus.spent) continue;
      final holder = holderOf(state, key);
      if (holder != null && holder != command.txid) {
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
    if (command.explicit || definitiveFailure || record?['lastNetworkStatus'] != command.networkStatus) {
      events.add(TransactionNetworkStatusCheckedEvent(
        walletId: command.walletId,
        txid: command.txid,
        networkStatus: command.networkStatus,
        source: command.source,
        checkedAt: command.checkedAt,
        blockHeight: command.blockHeight,
        explicit: command.explicit,
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
      if (holder != null && holder != event.txid) continue; // the first hold wins
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
  /// network.
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
  }

  /// [utxoKey] was spent by [spentInTxId]: a spent input is held by nobody,
  /// and a deferred payment whose input the transaction itself spent is on
  /// the network.
  static void applyInputSpent(WalletStateBuilder state, String utxoKey, String spentInTxId, DateTime at) {
    final holds = state.metadata[_deferredHoldsKey];
    if (holds is Map && holds.containsKey(utxoKey)) {
      state.metadata = state.metadata.put(_deferredHoldsKey, frozenRecord(holds).without(utxoKey));
    }
    _markSeen(state, spentInTxId, at);
  }

  /// [txid] is confirmed: a deferred payment of it is mined.
  static void applyConfirmed(WalletStateBuilder state, String txid, DateTime at) {
    final deferred = _recordForUpdate(state, txid);
    if (deferred != null) {
      var mined = deferred.put('state', DeferredPaymentState.mined.name);
      if (mined['resolvedAt'] == null) mined = mined.put('resolvedAt', at.toIso8601String());
      _putRecord(state, txid, mined);
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
      _putRecord(
        state,
        event.txid,
        record
            .put('lastNetworkStatus', event.networkStatus)
            .put('lastNetworkStatusSource', event.source)
            .put('lastCheckedAt', event.checkedAt.toIso8601String()),
      );
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
  /// reserved by it returns to its recorded status.
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

/// An outgoing transaction recorded with a deferred spend before holds were
/// journaled, with the inputs it still holds ([DeferredPayments.legacySpends]).
class LegacyDeferredSpend {
  final String txid;
  final List<String> heldKeys;
  final Map record;

  LegacyDeferredSpend(this.txid, this.heldKeys, this.record);
}
