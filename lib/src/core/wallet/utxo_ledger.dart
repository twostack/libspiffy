/// The wallet's UTXOs: receiving, confirming and spending them, which of them
/// can fund a transaction, and the Benford split initiation (bead
/// libspiffy-dp4; part of `BitcoinWalletAggregate`). Reservations are in
/// utxo_reservations.dart.
library;

import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:eventador/eventador.dart';
import 'package:logging/logging.dart';

import '../../models/bitcoin_utxo.dart';
import '../../models/wallet_balances.dart';
import '../../models/wallet_state.dart';
import '../../models/wallet_type.dart';
import '../../models/persistent_map.dart';
import '../../plugin/plugin_registry.dart';
import '../../utils/network_name.dart';
import '../wallet_commands.dart';
import '../wallet_events.dart';
import '../wallet_output_ownership.dart';
import 'deferred_payments.dart';
import 'outgoing_transactions.dart';

final _log = Logger('BitcoinWalletAggregate');

/// UTXO commands, events and queries of the wallet aggregate. Pure.
abstract final class UtxoLedger {
  // ---------------------------------------------------------------------------
  // Queries
  // ---------------------------------------------------------------------------

  /// Whether [utxo] is watch-only funds ([WalletBalances.isWatchOnly]).
  static bool isWatchOnly(WalletState state, BitcoinUtxo utxo) => WalletBalances.isWatchOnly(state, utxo);

  /// Available UTXOs for spending ([WalletBalances.isSpendable]: excludes
  /// plugin-managed UTXOs like tokens, watch-only UTXOs at watch addresses
  /// (bead libspiffy-87a2), bare multisig UTXOs the wallet cannot spend
  /// alone (bead libspiffy-0k8) and inputs of deferred payments recorded
  /// before holds were journaled (bead libspiffy-8j9w)), in state order.
  /// Their total is [WalletState.availableBalance].
  static List<BitcoinUtxo> available(WalletState state) {
    return state.utxos.values.where((utxo) => WalletBalances.isSpendable(state, utxo)).toList();
  }

  /// [available] UTXOs, largest first, until they cover [amount].
  static List<BitcoinUtxo> selectForAmount(WalletState state, BigInt amount) {
    final availableUtxos = available(state);
    availableUtxos.sort((a, b) => b.satoshis.compareTo(a.satoshis)); // Largest first

    final selected = <BitcoinUtxo>[];
    BigInt totalSelected = BigInt.zero;

    for (final utxo in availableUtxos) {
      selected.add(utxo);
      totalSelected += utxo.satoshis;

      if (totalSelected >= amount) {
        break;
      }
    }

    if (totalSelected < amount) {
      throw StateError('Insufficient funds: need $amount satoshis, have $totalSelected available');
    }

    return selected;
  }

  /// Whether [utxoKey] is an available UTXO.
  static bool isAvailable(WalletState state, String utxoKey) {
    final utxo = state.utxos[utxoKey];
    return utxo != null && utxo.status == UTXOStatus.available;
  }

  /// The UTXOs reserved by [reservationId].
  static List<BitcoinUtxo> reservedBy(WalletState state, String reservationId) {
    return state.utxos.values.where((utxo) => utxo.reservedByTxId == reservationId).toList();
  }

  /// Throws when [scriptPubKey] is a bare multisig script and the wallet
  /// holds fewer of the script's keys than it requires, however the output
  /// is attributed: an invoice's multisig output under a 'p2ms:m-of-n'
  /// pseudo-address was exempt and could be credited as spendable balance
  /// (bead libspiffy-n0p).
  static void rejectMultisigNotSpendableAlone(WalletState currentState, String scriptPubKey, String utxoKey) {
    final BareMultisigScript? multisig;
    try {
      multisig = BareMultisigScript.parse(dartsv.SVScript.fromHex(scriptPubKey));
    } catch (_) {
      return;
    }
    if (multisig == null) return;
    final network = NetworkName.toDartsv(currentState.networkType);
    if (multisig.spendableAloneBy(currentState.addresses.containsKey, network) == null) {
      throw StateError('UTXO $utxoKey is a ${multisig.threshold}-of-'
          '${multisig.publicKeysHex.length} multisig output the wallet cannot '
          'spend alone; it is not a wallet UTXO');
    }
  }

  /// Throws when [scriptPubKey] is a P2PK script locked to a key the wallet
  /// neither holds nor watches, however the output is attributed (bead
  /// libspiffy-abwk).
  ///
  /// The counterpart of [rejectMultisigNotSpendableAlone], which this file
  /// has had since beads viy and n0p. A P2PK script had no such rule:
  /// nothing compared its key with the wallet's own, and nothing required
  /// the attributed address to have anything to do with the script, so an
  /// output nobody but its owner can spend could be taken on as a wallet
  /// UTXO (bead libspiffy-kfvv, V-93, which established that this is
  /// reachable and answered it by never selecting such a row).
  ///
  /// **A watch address is not refused.** The wallet holds no key for one and
  /// never will, but tracking exactly that is what a watch address is for:
  /// the output is taken on, reported as watch-only funds, and never
  /// selected.
  ///
  /// Both encodings of the key count ([p2pkAddresses]): a wallet whose
  /// address record is the compressed form of a key pushed uncompressed
  /// holds it, and refusing that would refuse the wallet's own money.
  ///
  /// This is a COMMAND-path rule only. [applyReceived] validates no script,
  /// deliberately: a journal written before this guard is still the record,
  /// and nothing already journaled is dropped.
  static void rejectP2pkNotOurs(WalletState currentState, String scriptPubKey, String utxoKey) {
    final addresses = p2pkAddresses(scriptPubKey, NetworkName.toDartsv(currentState.networkType));
    if (addresses.isEmpty) return; // Not a P2PK script we can read.
    for (final address in addresses) {
      if (currentState.addresses.containsKey(address) ||
          currentState.watchAddresses.containsKey(address)) {
        return;
      }
    }
    throw StateError('UTXO $utxoKey is a P2PK output locked to a key the wallet '
        'neither holds nor watches; it is not a wallet UTXO');
  }

  /// The plugin metadata of a UTXO locked by [scriptPubKey] that was
  /// received with [metadata], naming the plugin that manages it (bead
  /// libspiffy-ecy8).
  ///
  /// A UTXO is plugin-managed when its metadata names a `pluginId`
  /// ([BitcoinUtxo.isPluginManaged]), on the wallet aggregate and on the
  /// read side alike. The read model takes the `pluginId` of a script that
  /// a registered plugin claims (and no standard template matches) from
  /// the script itself; so does the aggregate here, for metadata without a
  /// `pluginId` (a plugin's `extractMetadata` need not name itself, and
  /// may return nothing). [metadata] itself when it names a `pluginId`,
  /// when no plugin is registered, or when no plugin claims the script.
  static Map<String, dynamic>? pluginMetadataNamingPlugin(String scriptPubKey, Map<String, dynamic>? metadata) {
    if (metadata?['pluginId'] != null || !PluginRegistry().hasPlugins || scriptPubKey.isEmpty) return metadata;
    // A P2PKH script is a standard template: no parse.
    if (scriptPubKey.length == 50 && scriptPubKey.startsWith('76a914') && scriptPubKey.endsWith('88ac')) {
      return metadata;
    }
    try {
      final script = dartsv.SVScript.fromHex(scriptPubKey);
      dartsv.TemplateRegistry.initialize();
      if (dartsv.ScriptTemplateRegistry().identifyScriptType(script) != null) return metadata;
      final claimed = PluginRegistry().identifyScript(script);
      if (claimed == null) return metadata;
      return {...?metadata, 'pluginId': claimed.pluginId};
    } catch (e) {
      _log.fine('Could not identify the script of a received UTXO: $e');
      return metadata;
    }
  }

  /// Names the managing plugin in the metadata of each UTXO restored from a
  /// snapshot ([pluginMetadataNamingPlugin]), as a replay of its
  /// [UTXOReceivedEvent] would: a snapshot written before bead ecy8 holds
  /// the metadata as received.
  static void namePluginsOfRestoredUtxos(WalletStateBuilder state) {
    if (!PluginRegistry().hasPlugins) return;
    for (final entry in state.utxos.entries.toList()) {
      final utxo = entry.value;
      final named = pluginMetadataNamingPlugin(utxo.scriptPubKey, utxo.pluginMetadata);
      if (identical(named, utxo.pluginMetadata)) continue;
      state.utxos = state.utxos.put(entry.key, utxo.copyWith(pluginMetadata: unmodifiableDeepCopy(named)));
    }
  }

  // ---------------------------------------------------------------------------
  // Commands
  // ---------------------------------------------------------------------------

  static List<Event> receive(WalletState currentState, ReceiveUTXOCommand command) {
    // Business rule: Wallet must exist
    if (!currentState.isCreated) {
      throw StateError('Cannot receive UTXO for non-existent wallet');
    }

    final utxoKey = '${command.txid}:${command.vout}';

    // Business rule: an outpoint is received once. A second receipt is a
    // no-op, not an error (bead libspiffy-fggl): it happens on the normal
    // path, when a counterparty hands back a BEEF holding a transaction of
    // ours whose change output we recorded when we built it, or redelivers a
    // payment we already hold. The stored row is never overwritten — it may
    // be reserved, spent, or confirmed, and its reservation and spending
    // history are not re-fetchable. A proof that arrives with the second
    // delivery advances it through the confirmation path
    // (ConfirmTransactionCommand / MarkUTXOAvailableCommand), which is
    // checked against our header chain; a bare redelivery says nothing new.
    //
    // It used to throw. The throw was reported nowhere: the senders of this
    // command tell() it without a sender to reply to, so the error was
    // dropped and the sibling commands of the same receive still ran.
    if (currentState.utxos.containsKey(utxoKey)) {
      _log.info('UTXO $utxoKey is already in wallet ${command.walletId}; the stored row is kept as it is '
          'and nothing is journaled');
      return const [];
    }

    // Business rule: Amount must be positive
    if (command.satoshis <= BigInt.zero) {
      throw ArgumentError('UTXO amount must be positive');
    }

    // Business rule: a bare multisig output is a wallet UTXO only when the
    // wallet can spend it alone, whatever address it is attributed to
    // (beads libspiffy-viy, libspiffy-n0p).
    rejectMultisigNotSpendableAlone(currentState, command.scriptPubKey, utxoKey);

    // Business rule: the same for a P2PK output, which had no such rule
    // (bead libspiffy-abwk). A watch address is not refused — tracking an
    // address the wallet holds no key for is what one is for.
    rejectP2pkNotOurs(currentState, command.scriptPubKey, utxoKey);

    // The status is the caller's (it defaults to pending) and is never
    // derived from the command's block height or confirmation count: only
    // the sender knows whether a merkle proof verified against our header
    // chain, and a height or a count it merely asserts is a claim, not
    // evidence (spv-understanding.md). The command itself refuses the one
    // combination that cannot be true — a block height with pending — so a
    // caller cannot end up holding mined funds the wallet will not spend
    // (bead libspiffy-5ry).
    final initialStatus = command.initialStatus;

    final event = UTXOReceivedEvent(
      walletId: command.walletId,
      txid: command.txid,
      vout: command.vout,
      satoshis: command.satoshis.toInt(),
      scriptPubKey: command.scriptPubKey,
      address: command.address,
      initialStatus: initialStatus,
      blockHeight: command.blockHeight,
      confirmations: command.confirmations,
      derivationIndex: command.derivationIndex,
      pluginMetadata: command.pluginMetadata,
      // Who paid us, as the app names them (bead libspiffy-cq16). Journaled
      // verbatim and never interpreted.
      counterpartyMarker: command.counterpartyMarker,
      version: currentState.version + 1,
      timestamp: DateTime.now(),
    );

    return [event];
  }

  static List<Event> markAvailable(WalletState currentState, MarkUTXOAvailableCommand command) {
    // Business rule: Wallet must exist
    if (!currentState.isCreated) {
      throw StateError('Cannot mark UTXO available for non-existent wallet');
    }

    final utxoKey = '${command.txid}:${command.vout}';
    final utxo = currentState.utxos[utxoKey];

    if (utxo == null) {
      throw StateError('UTXO $utxoKey not found');
    }

    // A pending UTXO that is reserved still needs the promotion: the
    // reservation stays, and its release then restores `available` (M4).
    final pendingUnderReservation =
        utxo.status == UTXOStatus.reserved && utxo.statusBeforeReservation == UTXOStatus.pending;
    // A voided output is promoted too (bead libspiffy-3arz): the command says
    // it is in a block, which outranks the resolution that voided it.
    if (utxo.status != UTXOStatus.pending && utxo.status != UTXOStatus.voided && !pendingUnderReservation) {
      // Already available or spent, no-op
      return [];
    }

    return [
      UTXOMarkedAvailableEvent(
        walletId: command.walletId,
        txid: command.txid,
        vout: command.vout,
        version: currentState.version + 1,
        timestamp: DateTime.now(),
      )
    ];
  }

  static List<Event> spend(WalletState currentState, SpendUTXOCommand command) {
    // Business rule: Wallet must exist
    if (!currentState.isCreated) {
      throw StateError('Cannot spend UTXO for non-existent wallet');
    }

    // Business rule: UTXO must exist and be available
    final utxo = currentState.utxos[command.utxoKey];
    if (utxo == null) {
      throw StateError('UTXO ${command.utxoKey} not found in wallet');
    }

    // A spend supersedes a reservation: the payment coordinator reserves the
    // inputs, records the transaction with deferSpend, and ARC marks them
    // spent once the transaction is seen on the network. Rejecting reserved
    // UTXOs here meant that spend never applied, and the reservation expiry
    // later returned an on-chain-spent coin to `available`.
    // The payment coordinator reserves under a payment id (the txid exists
    // only after signing), so a reservation by another id is superseded too
    // when the wallet's own recorded transaction [SpendUTXOCommand.spendingTxId]
    // spends this UTXO (T-1: every standard payment's input stayed reserved).
    final spendable = utxo.status == UTXOStatus.available ||
        (utxo.status == UTXOStatus.reserved &&
            (utxo.reservedByTxId == null || utxo.reservedByTxId == command.spendingTxId)) ||
        ((utxo.status == UTXOStatus.reserved || utxo.status == UTXOStatus.pending) &&
            OutgoingTransactions.recordedTransactionSpends(currentState, command.spendingTxId, command.utxoKey));
    if (!spendable) {
      throw StateError('UTXO ${command.utxoKey} is not available for spending (status: ${utxo.status}, reservedBy: ${utxo.reservedByTxId})');
    }

    // Parse txid and vout from utxoKey
    final parts = command.utxoKey.split(':');
    final txid = parts[0];
    final vout = int.parse(parts[1]);

    final event = UTXOSpentEvent(
      walletId: command.walletId,
      txid: txid,
      vout: vout,
      spentInTxId: command.spendingTxId,
      version: currentState.version + 1,
      timestamp: DateTime.now(),
    );

    return [event];
  }

  /// Records a confirmation count a caller reports for a UTXO.
  ///
  /// Nothing about the count or the height is verified — they come straight
  /// from the caller — so the event they are journaled in changes no status
  /// (see [applyConfirmationUpdated] and [UpdateUTXOConfirmationsCommand],
  /// bead libspiffy-8oaq) and its height reaches no row (bead
  /// libspiffy-pq8p). The height is still journaled, as the claim it was:
  /// the journal records what we were told, and applying the event is where
  /// the claim is given no authority.
  static List<Event> updateConfirmations(WalletState currentState, UpdateUTXOConfirmationsCommand command) {
    // Business rule: Wallet must exist
    if (!currentState.isCreated) {
      throw StateError('Cannot update UTXO confirmations for non-existent wallet');
    }

    // Business rule: UTXO must exist
    final utxo = currentState.utxos[command.utxoKey];
    if (utxo == null) {
      throw StateError('UTXO ${command.utxoKey} not found in wallet');
    }

    // Parse txid and vout from utxoKey
    final parts = command.utxoKey.split(':');
    final txid = parts[0];
    final vout = int.parse(parts[1]);

    // Confirmations may decrease (a reorg); that is allowed.

    final event = UTXOConfirmationUpdatedEvent(
      walletId: command.walletId,
      txid: txid,
      vout: vout,
      confirmations: command.confirmations,
      // An absent height is journaled as absent. It used to be journaled as
      // 0 — the genesis block — which said the output was mined in January
      // 2009 (bead libspiffy-8oaq).
      blockHeight: command.blockHeight,
      version: currentState.version + 1,
      timestamp: DateTime.now(),
    );

    return [event];
  }

  /// Validates a request to split UTXOs according to Benford's Law
  /// distribution and emits [UTXOSplitInitiatedEvent].
  ///
  /// The actual orchestration (transaction building, signing, broadcasting)
  /// is performed by BenfordCoordinatorActor, which listens to the
  /// UTXOSplitInitiatedEvent and handles all external service calls.
  static List<Event> splitToBenford(WalletState currentState, SplitUTXOsToBenfordCommand command) {
    // Business rule: Wallet must exist
    if (!currentState.isCreated) {
      throw StateError('Cannot split UTXOs for non-existent wallet');
    }

    // Business rule: Watch-only wallets cannot sign
    if (currentState.walletType == WalletType.xpub) {
      throw StateError('Signing (split) not supported for watch-only wallets');
    }

    // Get all available UTXOs. Selection is the shared rule, so a
    // plugin-managed output is never split; the diagnosis of an empty result
    // is the shared reason helper, so the split says which exclusion emptied
    // the wallet just as channel funding does (bead libspiffy-f4qy: it used
    // to name watch-only funds and nothing else, so a wallet holding only
    // token outputs was told only that it had none).
    final availableUtxos = available(currentState);
    if (availableUtxos.isEmpty) {
      throw StateError(WalletBalances.noneSelectableReason(
        currentState,
        noneMessage: 'No available UTXOs to split',
      ));
    }

    // Emit single event - BenfordCoordinatorActor will handle orchestration
    return [
      UTXOSplitInitiatedEvent(
        walletId: command.walletId,
        utxoKeysToSplit: availableUtxos.map((u) => u.key).toList(),
        targetUtxoCount: command.targetUtxoCount,
        feeRate: command.feeRate ?? BigInt.one,
        version: currentState.version + 1,
        timestamp: DateTime.now(),
      ),
    ];
  }

  // ---------------------------------------------------------------------------
  // Events
  // ---------------------------------------------------------------------------

  static void applyReceived(WalletStateBuilder state, UTXOReceivedEvent event) {
    final utxoKey = '${event.txid}:${event.vout}';
    if (state.utxos.containsKey(utxoKey)) {
      // First receipt wins (audit 2026-09-14 M9). The command handlers no
      // longer emit a second UTXOReceivedEvent for a known outpoint, but
      // journals written before the fix can hold one (the outgoing-tx
      // scanner re-emitted it); overwriting would reset the UTXO's status
      // and drop its reservation or spent mark. Replay must not throw.
      _log.fine('Ignoring UTXOReceivedEvent for known outpoint $utxoKey');
      state.version = event.version;
      state.lastModified = event.timestamp;
      return;
    }
    final utxo = BitcoinUtxo.create(
      txid: event.txid,
      vout: event.vout,
      satoshis: BigInt.from(event.satoshis),
      scriptPubKey: event.scriptPubKey,
      address: event.address,
      blockHeight: event.blockHeight,
      confirmations: event.confirmations ?? 0,
      status: event.initialStatus, // Use the status from the event
      derivationIndex: event.derivationIndex,
      pluginMetadata: switch (pluginMetadataNamingPlugin(event.scriptPubKey, event.pluginMetadata)) {
        null => null,
        final metadata => unmodifiableDeepCopy(metadata) as Map<String, dynamic>,
      },
      createdAt: event.timestamp,
    );

    state.putUtxo(utxoKey, utxo);
    state.version = event.version;
    state.lastModified = event.timestamp;
  }

  static void applyMarkedAvailable(WalletStateBuilder state, UTXOMarkedAvailableEvent event) {
    final utxoKey = '${event.txid}:${event.vout}';
    final utxo = state.utxos[utxoKey];

    if (utxo != null) {
      state.putUtxo(
        utxoKey,
        utxo.status == UTXOStatus.reserved
            ? utxo.copyWith(statusBeforeReservation: UTXOStatus.available, updatedAt: event.timestamp)
            : utxo.markAvailable(timestamp: event.timestamp),
      );
      state.version = event.version;
      state.lastModified = event.timestamp;
    }
  }

  static void applySpent(WalletStateBuilder state, UTXOSpentEvent event) {
    final utxoKey = '${event.txid}:${event.vout}';
    final utxo = state.utxos[utxoKey];
    if (utxo != null) {
      state.putUtxo(
        utxoKey,
        utxo.markSpent(timestamp: event.timestamp, spentInTxId: event.spentInTxId),
      );
    }
    // A spent input is held by nobody; a deferred payment whose input the
    // transaction itself spent is on the network (bead libspiffy-7p2).
    DeferredPayments.applyInputSpent(state, utxoKey, event.spentInTxId, event.timestamp);
    state.version = event.version;
    state.lastModified = event.timestamp;
  }

  /// Writes the reported count onto the row, and nothing else.
  ///
  /// The status is deliberately untouched: a count nobody checked cannot
  /// make an output spendable, and it cannot un-void one (bead
  /// libspiffy-8oaq). **The height the event carries is deliberately not
  /// written either** (bead libspiffy-pq8p): `blockHeight != null` is the
  /// wallet's test for confirmed at every layer
  /// ([WalletBalances.bucketOf], `BitcoinUtxo.isConfirmed`,
  /// spv-understanding.md "Balances"), so recording an unverified height
  /// here made an unproven claim *report* as confirmed even after
  /// libspiffy-8oaq had stopped it making anything spendable. A height is
  /// evidence and this command has none; the count it does carry is kept
  /// (Data Retention: we keep what we were told), and the event keeps
  /// journalling the height as the claim it was, so nothing about the
  /// record is lost. `OutgoingTransactions.applyConfirmed` — driven by
  /// `ConfirmTransactionCommand`, whose senders derive the height from a
  /// BUMP checked against our own headers — is the only writer of a UTXO's
  /// height, and `applyConfirmationReverted` the only one that takes it off.
  static void applyConfirmationUpdated(WalletStateBuilder state, UTXOConfirmationUpdatedEvent event) {
    final utxoKey = '${event.txid}:${event.vout}';
    final utxo = state.utxos[utxoKey];
    if (utxo != null) {
      state.putUtxo(
        utxoKey,
        utxo.updateConfirmations(
          confirmations: event.confirmations,
          timestamp: event.timestamp,
        ),
      );
    }
    state.version = event.version;
    state.lastModified = event.timestamp;
  }
}
