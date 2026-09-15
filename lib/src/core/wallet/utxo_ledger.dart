/// The wallet's UTXOs: receiving, confirming and spending them, which of them
/// can fund a transaction, and the Benford split initiation (bead
/// libspiffy-dp4; part of `BitcoinWalletAggregate`). Reservations are in
/// utxo_reservations.dart.
library;

import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:eventador/eventador.dart';
import 'package:logging/logging.dart';

import '../../models/bitcoin_utxo.dart';
import '../../models/wallet_state.dart';
import '../../models/wallet_type.dart';
import '../../models/persistent_map.dart';
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

  /// Whether [utxo] is watch-only funds: attributed to the wallet through a
  /// watch address the wallet holds no key for (bead libspiffy-87a2). Such a
  /// UTXO is kept (with its transaction and proof) but never funds a
  /// transaction. A bare multisig UTXO over a watch address is not
  /// watch-only when the wallet's own keys meet its threshold.
  static bool isWatchOnly(WalletState state, BitcoinUtxo utxo) =>
      state.watchAddresses.isNotEmpty &&
      isWatchOnlyOutput(
        scriptHex: utxo.scriptPubKey,
        address: utxo.address,
        isWatchAddress: state.watchAddresses.containsKey,
        hasKeyFor: state.addresses.containsKey,
        network: NetworkName.toDartsv(state.networkType),
      );

  /// Available UTXOs for spending (excludes plugin-managed UTXOs like
  /// tokens, and watch-only UTXOs at watch addresses, bead libspiffy-87a2),
  /// in state order.
  static List<BitcoinUtxo> available(WalletState state) {
    return state.utxos.values
        .where((utxo) => utxo.status == UTXOStatus.available && !utxo.hasPluginMetadata && !isWatchOnly(state, utxo))
        .toList();
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

  // ---------------------------------------------------------------------------
  // Commands
  // ---------------------------------------------------------------------------

  static List<Event> receive(WalletState currentState, ReceiveUTXOCommand command) {
    // Business rule: Wallet must exist
    if (!currentState.isCreated) {
      throw StateError('Cannot receive UTXO for non-existent wallet');
    }

    final utxoKey = '${command.txid}:${command.vout}';

    // Business rule: Cannot receive duplicate UTXO
    if (currentState.utxos.containsKey(utxoKey)) {
      throw StateError('UTXO $utxoKey already exists in wallet');
    }

    // Business rule: Amount must be positive
    if (command.satoshis <= BigInt.zero) {
      throw ArgumentError('UTXO amount must be positive');
    }

    // Business rule: a bare multisig output is a wallet UTXO only when the
    // wallet can spend it alone, whatever address it is attributed to
    // (beads libspiffy-viy, libspiffy-n0p).
    rejectMultisigNotSpendableAlone(currentState, command.scriptPubKey, utxoKey);

    // Use the initialStatus provided by the caller (defaults to pending)
    // The caller (e.g., wallet_manager_actor for SPV-validated UTXOs) is responsible
    // for determining the appropriate status based on merkle proof verification
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
    if (utxo.status != UTXOStatus.pending && !pendingUnderReservation) {
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
      blockHeight: command.blockHeight ?? 0,
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

    // Get all available UTXOs
    final availableUtxos = available(currentState);
    if (availableUtxos.isEmpty) {
      final watchOnly = currentState.utxos.values
          .where((u) => u.status == UTXOStatus.available && !u.hasPluginMetadata && isWatchOnly(currentState, u))
          .length;
      throw StateError(watchOnly == 0
          ? 'No available UTXOs to split'
          : 'No available UTXOs to split: the $watchOnly available UTXO(s) are at watch addresses, '
              'watch-only funds the wallet holds no key for');
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
      pluginMetadata:
          event.pluginMetadata == null ? null : unmodifiableDeepCopy(event.pluginMetadata) as Map<String, dynamic>,
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

  static void applyConfirmationUpdated(WalletStateBuilder state, UTXOConfirmationUpdatedEvent event) {
    final utxoKey = '${event.txid}:${event.vout}';
    final utxo = state.utxos[utxoKey];
    if (utxo != null) {
      state.putUtxo(
        utxoKey,
        utxo.updateConfirmations(
          blockHeight: event.blockHeight,
          confirmations: event.confirmations,
          timestamp: event.timestamp,
        ),
      );
    }
    state.version = event.version;
    state.lastModified = event.timestamp;
  }
}
