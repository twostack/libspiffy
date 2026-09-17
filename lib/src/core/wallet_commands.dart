import 'package:eventador/eventador.dart';
import '../models/bitcoin_transaction.dart'; // For TransactionStatus
import '../models/bitcoin_utxo.dart'; // For UTXOStatus
import 'wallet_events.dart' show BeefAncestor;

/// Base class for all wallet commands
abstract class WalletCommand extends Command {
  final String walletId;

  WalletCommand({
    required this.walletId,
    String? commandId,
    DateTime? timestamp,
    Map<String, dynamic>? metadata,
  }) : super(
          commandId: commandId,
          timestamp: timestamp,
          metadata: metadata,
        );

  /// Command type identifier for logging and debugging
  String get commandType;

  @override
  String toString() {
    return '$commandType(commandId: $commandId, walletId: $walletId, timestamp: $timestamp)';
  }
}

// =============================================================================
// WALLET LIFECYCLE COMMANDS
// =============================================================================

/// Command to create a new wallet
class CreateWalletCommand extends WalletCommand {
  final String walletName;
  final String? mnemonic; // For HD wallets - will generate if null
  final String? wif; // For WIF wallets
  final String? xpriv; // For XPRIV wallets
  final String? xpub; // For watch-only XPUB wallets [NEW]
  final String? passphrase; // Optional passphrase for mnemonic
  final Map<String, dynamic>? walletMetadata; // Additional wallet metadata

  CreateWalletCommand({
    required String walletId,
    required this.walletName,
    this.mnemonic,
    this.wif,
    this.xpriv,
    this.xpub,
    this.passphrase,
    this.walletMetadata,
    String? commandId,
    DateTime? timestamp,
    Map<String, dynamic>? metadata,
  }) : super(
          walletId: walletId,
          commandId: commandId,
          timestamp: timestamp,
          metadata: metadata,
        ) {
    // Validation: At most one wallet type can be specified
    final specified = [
      mnemonic != null && mnemonic!.isNotEmpty,
      wif != null && wif!.isNotEmpty,
      xpriv != null && xpriv!.isNotEmpty,
      xpub != null && xpub!.isNotEmpty,
    ].where((x) => x).length;
    
    if (specified > 1) {
      throw ArgumentError(
        'Only one of mnemonic, wif, xpriv, or xpub can be specified'
      );
    }
  }

  @override
  String get commandType => 'CreateWalletCommand';
}

/// Command to permanently delete a wallet
class DeleteWalletCommand extends WalletCommand {
  final String? reason;

  DeleteWalletCommand({
    required String walletId,
    this.reason,
    String? commandId,
    DateTime? timestamp,
    Map<String, dynamic>? metadata,
  }) : super(
          walletId: walletId,
          commandId: commandId,
          timestamp: timestamp,
          metadata: metadata,
        );

  @override
  String get commandType => 'DeleteWalletCommand';
}

/// Command to update wallet configuration
class UpdateWalletConfigurationCommand extends WalletCommand {
  final String? newName;
  final Map<String, dynamic>? newMetadata;

  UpdateWalletConfigurationCommand({
    required String walletId,
    this.newName,
    this.newMetadata,
    String? commandId,
    DateTime? timestamp,
    Map<String, dynamic>? metadata,
  }) : super(
          walletId: walletId,
          commandId: commandId,
          timestamp: timestamp,
          metadata: metadata,
        );

  @override
  String get commandType => 'UpdateWalletConfigurationCommand';
}

/// Command to import a wallet from xpriv with transaction history
class ImportWalletFromXprivCommand extends WalletCommand {
  final String xpriv;
  final String walletName;
  final bool importTransactionHistory;
  final int addressGapLimit;
  final int? transactionLimit; // Per address
  final Map<String, dynamic>? walletMetadata;

  ImportWalletFromXprivCommand({
    required String walletId,
    required this.xpriv,
    required this.walletName,
    this.importTransactionHistory = true,
    this.addressGapLimit = 20,
    this.transactionLimit,
    this.walletMetadata,
    String? commandId,
    DateTime? timestamp,
    Map<String, dynamic>? metadata,
  }) : super(
          walletId: walletId,
          commandId: commandId,
          timestamp: timestamp,
          metadata: metadata,
        );

  @override
  String get commandType => 'ImportWalletFromXprivCommand';
}

// =============================================================================
// ADDRESS MANAGEMENT COMMANDS
// =============================================================================

/// Command to generate a new address
class GenerateAddressCommand extends WalletCommand {
  final String? label; // Optional label for the address
  final String? purpose; // Purpose: 'receive', 'change', etc.
  final bool includePublicKey; // If true, includes public key hex in response (needed for multisig/channels)

  GenerateAddressCommand({
    required String walletId,
    this.label,
    this.purpose,
    this.includePublicKey = false,
    String? correlationId,
    String? commandId,
    DateTime? timestamp,
    Map<String, dynamic>? metadata,
  }) : super(
          walletId: walletId,
          commandId: commandId,
          timestamp: timestamp,
          metadata: {
            ...?metadata,
            if (correlationId != null) 'correlationId': correlationId,
          },
        );

  @override
  String get commandType => 'GenerateAddressCommand';
  
  /// Get the optional correlation ID from metadata
  String? getCorrelationId() => metadata['correlationId'] as String?;
}


/// Command to update an address label
class UpdateAddressLabelCommand extends WalletCommand {
  final String address;
  final String? newLabel;

  UpdateAddressLabelCommand({
    required String walletId,
    required this.address,
    this.newLabel,
    String? commandId,
    DateTime? timestamp,
    Map<String, dynamic>? metadata,   
  }) : super(
          walletId: walletId,
          commandId: commandId,
          timestamp: timestamp,
          metadata: metadata,
        );

  @override
  String get commandType => 'UpdateAddressLabelCommand';
}

/// Command to register a discovered address (from wallet import)
/// 
/// This command is sent by ImportActor to properly persist discovered addresses
/// through the CQRS EventStore flow, ensuring WalletProjection can build the
/// read model with AddressEntity records.
class RegisterDiscoveredAddressCommand extends WalletCommand {
  final String address;
  final int derivationIndex;
  final bool isChange;
  final int transactionCount;

  RegisterDiscoveredAddressCommand({
    required String walletId,
    required this.address,
    required this.derivationIndex,
    required this.isChange,
    required this.transactionCount,
    String? commandId,
    DateTime? timestamp,
    Map<String, dynamic>? metadata,
  }) : super(
          walletId: walletId,
          commandId: commandId,
          timestamp: timestamp,
          metadata: metadata,
        );

  @override
  String get commandType => 'RegisterDiscoveredAddressCommand';

  @override
  Map<String, dynamic> toMap() {
    return {
      ...super.toMap(),
      'address': address,
      'derivationIndex': derivationIndex,
      'isChange': isChange,
      'transactionCount': transactionCount,
    };
  }
}

/// Adds a watch address to the wallet (bead libspiffy-p4kv): an address the
/// wallet holds no key for whose payments it attributes to itself.
///
/// Journals a WatchAddressAddedEvent. Idempotent: an address that is already
/// a watch address, or one the wallet derived itself, journals nothing (the
/// wallet already owns it, and a derived address keeps its row).
class AddWatchAddressCommand extends WalletCommand {
  final String address;
  final String scriptType;
  final String? label;

  AddWatchAddressCommand({
    required String walletId,
    required this.address,
    required this.scriptType,
    this.label,
    String? commandId,
    DateTime? timestamp,
    Map<String, dynamic>? metadata,
  }) : super(walletId: walletId, commandId: commandId, timestamp: timestamp, metadata: metadata);

  @override
  String get commandType => 'AddWatchAddressCommand';
}

/// A watch address the read model recorded before watch addresses were
/// journaled (an address row with purpose `watch`).
class LegacyWatchAddress {
  final String address;
  final String scriptType;
  final String? label;
  final DateTime registeredAt;

  const LegacyWatchAddress({
    required this.address,
    required this.scriptType,
    this.label,
    required this.registeredAt,
  });
}

/// Journals the watch addresses the read model recorded before watch
/// addresses were journaled (bead libspiffy-p4kv), so that the wallet knows
/// them and a read model rebuilt from the journal keeps them.
///
/// Each address the wallet does not already own gets a WatchAddressAddedEvent
/// with `reconciled: true`; nothing else is journaled, so sending it again is
/// harmless. WalletManagerActor sends it when it loads a wallet from the
/// journal. The read-model rows are never removed.
class ReconcileWatchAddressesCommand extends WalletCommand {
  final List<LegacyWatchAddress> addresses;

  ReconcileWatchAddressesCommand({
    required String walletId,
    required this.addresses,
    String? commandId,
    DateTime? timestamp,
    Map<String, dynamic>? metadata,
  }) : super(walletId: walletId, commandId: commandId, timestamp: timestamp, metadata: metadata);

  @override
  String get commandType => 'ReconcileWatchAddressesCommand';
}

// =============================================================================
// UTXO MANAGEMENT COMMANDS
// =============================================================================

/// Command to record a received UTXO.
///
/// [initialStatus] is the caller's, not derived from [blockHeight] or
/// [confirmations]: a height or a confirmation count a caller hands us is a
/// claim, not evidence, and only a merkle proof that verified against our
/// active header chain makes a UTXO spendable (spv-understanding.md). The
/// sender of this command is the one that verified the proof — see
/// `WalletManagerActor._processSPVResultForWallet`, which passes
/// `initialStatus: available` together with the height exactly when the BEEF
/// carried a proof, and `pending` with no height when it did not.
///
/// So the two must agree, and a [blockHeight] with `pending` is rejected at
/// construction (bead libspiffy-5ry): taking a height and a confirmation
/// count while defaulting the status to `pending` left callers with a wallet
/// that quietly reported nothing spendable and no explanation.
class ReceiveUTXOCommand extends WalletCommand {
  final String txid;
  final int vout;
  final BigInt satoshis;
  final String scriptPubKey;
  final String address;

  /// The height of the block a verified merkle proof placed this UTXO's
  /// transaction in; null while it is unproven.
  final int? blockHeight;
  final int? confirmations;

  /// Status to set when creating the UTXO: `available` when a verified
  /// merkle proof backs [blockHeight], `pending` while the transaction is
  /// unproven (and then without a [blockHeight]).
  final UTXOStatus initialStatus;
  final int? derivationIndex;
  final Map<String, dynamic>? pluginMetadata;

  /// The app's opaque marker for the counterparty this payment is with
  /// (bead libspiffy-cq16, spv-understanding.md "Core Data Management"
  /// requirement 5): an Ed25519 identity key, an email address, a peer id,
  /// an internal account id — whatever the app uses for identity. libspiffy
  /// journals it and returns it; it never interprets, validates or parses
  /// it, and the identity record itself stays with the app. Not an address:
  /// it is kept apart from the address-derived counterparty columns of the
  /// read model. Null when the app supplies none.
  final String? counterpartyMarker;

  ReceiveUTXOCommand({
    required String walletId,
    required this.txid,
    required this.vout,
    required this.satoshis,
    required this.scriptPubKey,
    required this.address,
    this.blockHeight,
    this.confirmations,
    this.initialStatus = UTXOStatus.pending, // Default to pending for new receives
    this.derivationIndex,
    this.pluginMetadata,
    this.counterpartyMarker,
    String? commandId,
    DateTime? timestamp,
    Map<String, dynamic>? metadata,
  }) : super(
          walletId: walletId,
          commandId: commandId,
          timestamp: timestamp,
          metadata: metadata,
        ) {
    // A block height is a verified merkle proof's fingerprint, so it cannot
    // sit on a UTXO the wallet is holding as unproven. The status is not
    // derived from the height (that would conjure spendable funds out of a
    // caller's claim); the contradiction is refused instead, and here rather
    // than in the aggregate because the senders of this command `tell()` it
    // with no sender to answer to, so an error raised there is dropped.
    if (blockHeight != null && initialStatus == UTXOStatus.pending) {
      throw ArgumentError(
        'ReceiveUTXOCommand for $txid:$vout carries blockHeight $blockHeight while '
        'initialStatus is pending. A block height is recorded only from a merkle proof '
        'that verified against our header chain, and a UTXO with such a proof is '
        'spendable. Pass initialStatus: UTXOStatus.available when a verified proof backs '
        'this height, or leave blockHeight (and confirmations) unset while the '
        'transaction is unproven, so the UTXO stays pending until a proof confirms it.',
      );
    }
  }

  @override
  String get commandType => 'ReceiveUTXOCommand';
}

/// Command to mark UTXO as available for spending
class MarkUTXOAvailableCommand extends WalletCommand {
  final String txid;
  final int vout;
  
  MarkUTXOAvailableCommand({
    required String walletId,
    required this.txid,
    required this.vout,
    String? commandId,
    DateTime? timestamp,
    Map<String, dynamic>? metadata,
  }) : super(
          walletId: walletId,
          commandId: commandId,
          timestamp: timestamp,
          metadata: metadata,
        );
  
  @override
  String get commandType => 'MarkUTXOAvailableCommand';
}

/// Command to record an imported transaction (from blockchain scan)
class RecordImportedTransactionCommand extends WalletCommand {
  final String txid;
  final String rawHex;
  final int blockHeight;
  final String bumpProofHex;
  final int totalOutputSats;
  final int numInputs;
  final int numOutputs;
  final int txVersion;
  final int txLockTime;
  final List<String> walletReceivingAddresses;
  final int walletReceivedSats;
  final int totalInputSats;
  final List<String> sendingAddresses;

  /// For a transaction received unproven: the ancestors its BEEF carried
  /// back to proven transactions, with their BUMPs, parents first (bead
  /// libspiffy-zsh). Journaled on the TransactionImportedEvent.
  final List<BeefAncestor> ancestors;

  /// The app's opaque marker for the counterparty this payment is with
  /// (bead libspiffy-cq16, spv-understanding.md "Core Data Management"
  /// requirement 5): an Ed25519 identity key, an email address, a peer id,
  /// an internal account id — whatever the app uses for identity. libspiffy
  /// journals it and returns it; it never interprets, validates or parses
  /// it, and the identity record itself stays with the app. Not an address:
  /// it is kept apart from the address-derived counterparty columns of the
  /// read model. Null when the app supplies none.
  final String? counterpartyMarker;

  RecordImportedTransactionCommand({
    required String walletId,
    required this.txid,
    required this.rawHex,
    required this.blockHeight,
    required this.bumpProofHex,
    required this.totalOutputSats,
    required this.numInputs,
    required this.numOutputs,
    required this.txVersion,
    required this.txLockTime,
    required this.walletReceivingAddresses,
    required this.walletReceivedSats,
    required this.totalInputSats,
    required this.sendingAddresses,
    this.ancestors = const [],
    this.counterpartyMarker,
    String? commandId,
    DateTime? timestamp,
    Map<String, dynamic>? metadata,
  }) : super(
          walletId: walletId,
          commandId: commandId,
          timestamp: timestamp,
          metadata: metadata,
        );

  @override
  String get commandType => 'RecordImportedTransactionCommand';
}

/// Command to record an outgoing transaction (payment created by this wallet)
/// Records transaction in PENDING state until payment is confirmed by recipient
class RecordOutgoingTransactionCommand extends WalletCommand {
  final String txid;
  final String rawHex;
  final int totalInputSats;
  final int totalOutputSats;
  final int fee;
  final int numInputs;
  final int numOutputs;
  final int txVersion;
  final int txLockTime;
  final List<String> spentUtxoKeys; // UTXOs being spent by this transaction
  final List<String> recipientAddresses;
  final BigInt paymentAmount;
  final String? changeAddress;
  final BigInt? changeAmount;
  /// When true, do NOT emit UTXOSpentEvents for spentUtxoKeys.
  /// The spent marking is deferred to ARCActor when the tx reaches SEEN_ON_NETWORK.
  ///
  /// The wallet holds the inputs it has unspent for this transaction
  /// (TransactionSpendDeferredEvent, bead libspiffy-7p2): reserved by the
  /// txid with no expiry, so no reservation expiry, cleanup or other
  /// reservation can release or take them. The hold ends when the network
  /// reports the transaction, when ARC reports it REJECTED, or when it is
  /// cancelled (DOUBLE_SPEND_ATTEMPTED keeps it held, bead libspiffy-ey2)
  /// ([CancelDeferredSpendCommand]).
  final bool deferSpend;

  /// Invoice this transaction pays, if any (listed with the deferred payment).
  final String? invoiceId;

  /// What recorded the transaction (`invoice-payment`, `channel-funding`,
  /// ...), listed with the deferred payment.
  final String? purpose;

  /// When true, this transaction was signed externally (e.g., by a plugin's
  /// `CallbackTransactionSigner`) without going through [SignTransactionCommand].
  /// The aggregate emits a [TransactionSignedEvent] alongside the
  /// [TransactionRecordedEvent] to keep the audit trail symmetric with
  /// wallet-internal signing.
  final bool preSigned;

  /// Optional signer provenance: derivation index, plugin id, role, signer
  /// type — anything the coordinator wants captured for forensic replay.
  /// Propagated to [TransactionSignedEvent.metadata] when [preSigned] is true.
  final Map<String, dynamic>? signerMetadata;

  /// The app's opaque marker for the counterparty this payment is with
  /// (bead libspiffy-cq16, spv-understanding.md "Core Data Management"
  /// requirement 5): an Ed25519 identity key, an email address, a peer id,
  /// an internal account id — whatever the app uses for identity. libspiffy
  /// journals it and returns it; it never interprets, validates or parses
  /// it, and the identity record itself stays with the app. Not an address:
  /// it is kept apart from the address-derived counterparty columns of the
  /// read model. Null when the app supplies none.
  final String? counterpartyMarker;

  RecordOutgoingTransactionCommand({
    required String walletId,
    required this.txid,
    required this.rawHex,
    required this.totalInputSats,
    required this.totalOutputSats,
    required this.fee,
    required this.numInputs,
    required this.numOutputs,
    required this.txVersion,
    required this.txLockTime,
    required this.spentUtxoKeys,
    required this.recipientAddresses,
    required this.paymentAmount,
    this.changeAddress,
    this.changeAmount,
    this.deferSpend = false,
    this.preSigned = false,
    this.signerMetadata,
    this.invoiceId,
    this.purpose,
    this.counterpartyMarker,
    String? commandId,
    DateTime? timestamp,
    Map<String, dynamic>? metadata,
  }) : super(
          walletId: walletId,
          commandId: commandId,
          timestamp: timestamp,
          metadata: metadata,
        );

  @override
  String get commandType => 'RecordOutgoingTransactionCommand';
}

/// Command to confirm a pending transaction (transition from pending to confirmed)
class ConfirmTransactionCommand extends WalletCommand {
  final String txid;
  final int? blockHeight;
  final String? blockHash;

  /// The hex-encoded BRC-74 BUMP proving the transaction is in the block
  /// (ARC's `merklePath`), journaled with the confirmation so a read model
  /// rebuilt from the journal keeps the proof (bead libspiffy-9ek).
  final String? bumpHex;

  /// Confirm only a transaction this wallet recorded as an outgoing
  /// transaction and has not confirmed yet; otherwise journal nothing (bead
  /// libspiffy-fggl).
  ///
  /// Set when the proof was not asked for but handed to us: every BUMP of a
  /// received BEEF that verifies against our header chain is offered to the
  /// wallet, and most of them prove transactions of counterparties, which
  /// are no business of this wallet's journal. It also makes the same BEEF
  /// delivered twice journal one confirmation.
  final bool onlyIfRecorded;

  ConfirmTransactionCommand({
    required String walletId,
    required this.txid,
    this.blockHeight,
    this.blockHash,
    this.bumpHex,
    this.onlyIfRecorded = false,
    String? commandId,
    DateTime? timestamp,
    Map<String, dynamic>? metadata,
  }) : super(
          walletId: walletId,
          commandId: commandId,
          timestamp: timestamp,
          metadata: metadata,
        );

  @override
  String get commandType => 'ConfirmTransactionCommand';
}

/// Command to update a transaction's status (e.g., from ARC status transitions)
class UpdateTransactionStatusCommand extends WalletCommand {
  final String txid;
  final TransactionStatus newStatus;

  UpdateTransactionStatusCommand({
    required String walletId,
    required this.txid,
    required this.newStatus,
    String? commandId,
    DateTime? timestamp,
    Map<String, dynamic>? metadata,
  }) : super(
          walletId: walletId,
          commandId: commandId,
          timestamp: timestamp,
          metadata: metadata,
        );

  @override
  String get commandType => 'UpdateTransactionStatusCommand';
}

/// Command to spend a UTXO
class SpendUTXOCommand extends WalletCommand {
  final String utxoKey; // Format: "txid:vout"
  final String spendingTxId;
  final BigInt fee; // Fee portion allocated to this input
  final int? blockHeight; // Block height when spending was confirmed

  SpendUTXOCommand({
    required String walletId,
    required this.utxoKey,
    required this.spendingTxId,
    required this.fee,
    this.blockHeight,
    String? commandId,
    DateTime? timestamp,
    Map<String, dynamic>? metadata,
  }) : super(
          walletId: walletId,
          commandId: commandId,
          timestamp: timestamp,
          metadata: metadata,
        );

  @override
  String get commandType => 'SpendUTXOCommand';
}

/// Command to update UTXO confirmations
class UpdateUTXOConfirmationsCommand extends WalletCommand {
  final String utxoKey; // Format: "txid:vout"
  final int confirmations;
  final int? blockHeight;

  UpdateUTXOConfirmationsCommand({
    required String walletId,
    required this.utxoKey,
    required this.confirmations,
    this.blockHeight,
    String? commandId,
    DateTime? timestamp,
    Map<String, dynamic>? metadata,
  }) : super(
          walletId: walletId,
          commandId: commandId,
          timestamp: timestamp,
          metadata: metadata,
        );

  @override
  String get commandType => 'UpdateUTXOConfirmationsCommand';
}

/// Command to reserve a UTXO for a transaction
class ReserveUTXOCommand extends WalletCommand {
  final String utxoKey; // Format: "txid:vout"
  final String reservedByTxId;
  final String? reservationReason;
  final Duration? reservationDuration;
  final int priority;

  ReserveUTXOCommand({
    required String walletId,
    required this.utxoKey,
    required this.reservedByTxId,
    this.reservationReason,
    this.reservationDuration,
    this.priority = 0,
    String? commandId,
    DateTime? timestamp,
    Map<String, dynamic>? metadata,
  }) : super(
          walletId: walletId,
          commandId: commandId,
          timestamp: timestamp,
          metadata: metadata,
        );

  @override
  String get commandType => 'ReserveUTXOCommand';
}

/// Command to release a UTXO reservation
class ReleaseUTXOCommand extends WalletCommand {
  final String utxoKey; // Format: "txid:vout"
  final String? releaseReason;

  ReleaseUTXOCommand({
    required String walletId,
    required this.utxoKey,
    this.releaseReason,
    String? commandId,
    DateTime? timestamp,
    Map<String, dynamic>? metadata,
  }) : super(
          walletId: walletId,
          commandId: commandId,
          timestamp: timestamp,
          metadata: metadata,
        );

  @override
  String get commandType => 'ReleaseUTXOCommand';
}

/// Command to renew/extend a UTXO reservation
class RenewUTXOReservationCommand extends WalletCommand {
  final String utxoKey; // Format: "txid:vout"
  final Duration extensionDuration;
  final String? renewalReason;

  RenewUTXOReservationCommand({
    required String walletId,
    required this.utxoKey,
    required this.extensionDuration,
    this.renewalReason,
    String? commandId,
    DateTime? timestamp,
    Map<String, dynamic>? metadata,
  }) : super(
          walletId: walletId,
          commandId: commandId,
          timestamp: timestamp,
          metadata: metadata,
        );

  @override
  String get commandType => 'RenewUTXOReservationCommand';
}

/// Command to clean up expired UTXO reservations
class CleanupExpiredReservationsCommand extends WalletCommand {
  final DateTime? cutoffTime; // Cleanup reservations older than this, or now if null

  CleanupExpiredReservationsCommand({
    required String walletId,
    this.cutoffTime,
    String? commandId,
    DateTime? timestamp,
    Map<String, dynamic>? metadata,
  }) : super(
          walletId: walletId,
          commandId: commandId,
          timestamp: timestamp,
          metadata: metadata,
        );

  @override
  String get commandType => 'CleanupExpiredReservationsCommand';
}

// =============================================================================
// TRANSACTION MANAGEMENT COMMANDS
// =============================================================================

/// Command to sign a transaction
class SignTransactionCommand extends WalletCommand {
  final String transactionId;
  final String rawTransaction; // Unsigned transaction hex
  final List<String> utxoKeys; // UTXOs being spent
  final List<String> publicKeys;
  /// Addresses for each UTXO (parallel to utxoKeys). Used for key derivation.
  final List<String> addresses;
  /// Derivation indices for each UTXO (parallel to utxoKeys).
  /// When provided, the aggregate uses these directly instead of looking up in state.
  final List<int> derivationIndices;
  /// Derivation chain for each UTXO (parallel to utxoKeys): true when the
  /// UTXO's address is on the change chain (m/1/{index}), false for the
  /// receive chain (m/0/{index}). Entries beyond the list's length, or an
  /// empty list, mean "resolve the chain from the aggregate's own address
  /// records", which is correct for every address the aggregate generated
  /// or discovered itself.
  final List<bool> isChangeFlags;

  SignTransactionCommand({
    required String walletId,
    required this.transactionId,
    required this.rawTransaction,
    required this.utxoKeys,
    required this.publicKeys,
    this.addresses = const [],
    this.derivationIndices = const [],
    this.isChangeFlags = const [],
    String? commandId,
    DateTime? timestamp,
    Map<String, dynamic>? metadata,
  }) : super(
          walletId: walletId,
          commandId: commandId,
          timestamp: timestamp,
          metadata: metadata,
        );

  @override
  String get commandType => 'SignTransactionCommand';
}

/// Command to broadcast a transaction
class BroadcastTransactionCommand extends WalletCommand {
  final String transactionId;
  final String signedTransaction; // Signed transaction hex

  BroadcastTransactionCommand({
    required String walletId,
    required this.transactionId,
    required this.signedTransaction,
    String? commandId,
    DateTime? timestamp,
    Map<String, dynamic>? metadata,
  }) : super(
          walletId: walletId,
          commandId: commandId,
          timestamp: timestamp,
          metadata: metadata,
        );

  @override
  String get commandType => 'BroadcastTransactionCommand';
}

/// Command to sign a multisig transaction input
/// Used for payment channels where we need to sign one input of a 2-of-2 multisig
class SignMultisigTransactionCommand extends WalletCommand {
  final String transactionId;
  final String rawTransaction; // Unsigned transaction hex
  final int derivationIndex; // Which key to use (m/{chain}/{index})
  /// Whether [derivationIndex] is on the change chain (m/1/{index}) rather
  /// than the receive chain (m/0/{index}).
  final bool isChange;
  final int inputIndex; // Which input to sign
  final int prevOutValue; // Satoshi value of input being spent
  final String redeemScriptHex; // 2-of-2 multisig redeem script
  final int sighashType; // SIGHASH flags (e.g., SIGHASH_ALL | SIGHASH_FORKID)

  SignMultisigTransactionCommand({
    required String walletId,
    required this.transactionId,
    required this.rawTransaction,
    required this.derivationIndex,
    this.isChange = false,
    required this.inputIndex,
    required this.prevOutValue,
    required this.redeemScriptHex,
    this.sighashType = 0x41, // SIGHASH_ALL | SIGHASH_FORKID by default
    String? commandId,
    DateTime? timestamp,
    Map<String, dynamic>? metadata,
  }) : super(
          walletId: walletId,
          commandId: commandId,
          timestamp: timestamp,
          metadata: metadata,
        );

  @override
  String get commandType => 'SignMultisigTransactionCommand';
}

/// Command to sign one input of a transaction with the wallet key at an
/// explicit derivation path, against a caller-supplied subscript and amount.
///
/// The aggregate replies `InputSignedResponse` carrying the signature (DER
/// plus sighash byte) and the signing key's public key; nothing is journaled.
/// For WIF wallets the path is ignored (single key); watch-only wallets are
/// refused.
class SignInputCommand extends WalletCommand {
  /// Transaction whose input is signed (hex). Unlocking scripts are ignored:
  /// the signature hash does not cover them.
  final String rawTransaction;

  /// Index of the input to sign.
  final int inputIndex;

  /// Script the signature commits to: the locking script of the output
  /// being spent (or the part of it after the last executed OP_CODESEPARATOR).
  final String subscriptHex;

  /// Value of the output being spent, in satoshis.
  final BigInt satoshis;

  /// Key path `m/{isChange ? 1 : 0}/{derivationIndex}`.
  final int derivationIndex;
  final bool isChange;

  /// SIGHASH flags; SIGHASH_ALL | SIGHASH_FORKID by default.
  final int sighashType;

  SignInputCommand({
    required super.walletId,
    required this.rawTransaction,
    required this.inputIndex,
    required this.subscriptHex,
    required this.satoshis,
    required this.derivationIndex,
    this.isChange = false,
    this.sighashType = 0x41,
    super.commandId,
    super.timestamp,
    super.metadata,
  });

  @override
  String get commandType => 'SignInputCommand';
}

/// Command to build and sign a payment channel funding transaction.
/// 
/// This creates a 2-of-2 multisig output funded by the client's UTXOs.
/// The signing happens entirely within the wallet aggregate, keeping keys secure.
class BuildFundingTransactionCommand extends WalletCommand {
  final String correlationId; // To match response
  final String channelId;
  final String clientPubKeyHex;
  final String serverPubKeyHex;
  final int fundingAmountSats;
  final String changeAddressBase58;
  final int? derivationIndex; // If provided, use this key; otherwise use default
  /// Whether [derivationIndex] is on the change chain (m/1/{index}) rather
  /// than the receive chain (m/0/{index}).
  final bool isChange;

  BuildFundingTransactionCommand({
    required String walletId,
    required this.correlationId,
    required this.channelId,
    required this.clientPubKeyHex,
    required this.serverPubKeyHex,
    required this.fundingAmountSats,
    required this.changeAddressBase58,
    this.derivationIndex,
    this.isChange = false,
    String? commandId,
    DateTime? timestamp,
    Map<String, dynamic>? metadata,
  }) : super(
          walletId: walletId,
          commandId: commandId,
          timestamp: timestamp,
          metadata: metadata,
        );

  @override
  String get commandType => 'BuildFundingTransactionCommand';
}

// =============================================================================
// UTXO RESERVATION COMMANDS
// =============================================================================

/// Command to reserve UTXOs for a transaction
class ReserveUTXOsCommand extends WalletCommand {
  final List<String> utxoKeys; // UTXOs to reserve
  final String reservationId; // Transaction or operation ID
  final Duration? reservationDuration; // Auto-expiry time (null = manual release)

  ReserveUTXOsCommand({
    required String walletId,
    required this.utxoKeys,
    required this.reservationId,
    this.reservationDuration,
    String? commandId,
    DateTime? timestamp,
    Map<String, dynamic>? metadata,
  }) : super(
          walletId: walletId,
          commandId: commandId,
          timestamp: timestamp,
          metadata: metadata,
        );

  @override
  String get commandType => 'ReserveUTXOsCommand';
}

/// Command to release UTXO reservations
class ReleaseUTXOsCommand extends WalletCommand {
  final String reservationId; // Transaction or operation ID to release

  ReleaseUTXOsCommand({
    required String walletId,
    required this.reservationId,
    String? commandId,
    DateTime? timestamp,
    Map<String, dynamic>? metadata,
  }) : super(
          walletId: walletId,
          commandId: commandId,
          timestamp: timestamp,
          metadata: metadata,
        );

  @override
  String get commandType => 'ReleaseUTXOsCommand';
}

// =============================================================================
// PRIVACY COMMANDS
// =============================================================================

/// Command to split wallet UTXOs into Benford distribution for privacy
/// 
/// This command processes each available UTXO individually, splitting it into
/// multiple outputs whose amounts follow Benford's Law distribution. This makes
/// transaction patterns appear more natural and organic, improving privacy.
/// 
/// Each source UTXO will be split into [targetUtxoCount] new UTXOs through
/// a single transaction (1 input -> N outputs). The outputs are sent to newly
/// generated addresses within the same wallet.
/// 
/// This is NOT part of the SPV flow - we broadcast our own transactions directly
/// via ArcService and handle CQRS integration manually.
class SplitUTXOsToBenfordCommand extends WalletCommand {
  /// Number of outputs to create per source UTXO
  final int targetUtxoCount;
  
  /// Optional fee rate in satoshis per byte (default: 1 for BSV)
  final BigInt? feeRate;
  
  /// Maximum number of UTXOs to split (null = split all available)
  /// This allows users to keep some UTXOs available for transactions
  final int? maxUtxosToSplit;

  SplitUTXOsToBenfordCommand({
    required String walletId,
    required this.targetUtxoCount,
    this.feeRate,
    this.maxUtxosToSplit,
    String? commandId,
    DateTime? timestamp,
    Map<String, dynamic>? metadata,
  }) : super(
          walletId: walletId,
          commandId: commandId,
          timestamp: timestamp,
          metadata: metadata,
        ) {
    // Validation
    if (targetUtxoCount < 2) {
      throw ArgumentError('Target UTXO count must be at least 2');
    }
    if (targetUtxoCount > 100) {
      throw ArgumentError('Target UTXO count cannot exceed 100 (transaction size limits)');
    }
    if (feeRate != null && feeRate! <= BigInt.zero) {
      throw ArgumentError('Fee rate must be positive');
    }
    if (maxUtxosToSplit != null && maxUtxosToSplit! < 1) {
      throw ArgumentError('maxUtxosToSplit must be at least 1');
    }
  }

  @override
  String get commandType => 'SplitUTXOsToBenfordCommand';
  
  @override
  String toString() {
    return 'SplitUTXOsToBenfordCommand('
        'walletId: $walletId, '
        'targetUtxoCount: $targetUtxoCount, '
        'feeRate: $feeRate, '
        'commandId: $commandId'
        ')';
  }
}

/// Command to preload a wallet aggregate at startup
/// 
/// This is a no-op command that triggers wallet loading without performing
/// any actual operation. Used during system initialization to ensure wallet
/// aggregates are ready before commands arrive.
class PreloadWalletCommand extends WalletCommand {
  PreloadWalletCommand({
    required String walletId,
    String? commandId,
    DateTime? timestamp,
    Map<String, dynamic>? metadata,
  }) : super(
          walletId: walletId,
          commandId: commandId,
          timestamp: timestamp,
          metadata: metadata,
        );

  @override
  String get commandType => 'PreloadWalletCommand';
  
  @override
  String toString() {
    return 'PreloadWalletCommand(walletId: $walletId, commandId: $commandId)';
  }
}


/// Command to take back the confirmation of [txid] (audit 3b0).
///
/// Sent by SPVActor when the block the transaction was confirmed in left
/// the active chain in a reorganization, or when a proof accepted before
/// its block header was known does not match that header. The transaction
/// returns to pending and needs a new proof; its UTXOs lose their
/// confirmations and those that were spendable become pending. The dropped
/// proof is identified by [merkleProof] (the stored BUMP hex) so the read
/// model deletes exactly that proof and never a newer one.
class RevertTransactionConfirmationCommand extends WalletCommand {
  final String txid;

  /// Height and hash of the block the dropped proof pointed at, when known.
  final int? blockHeight;
  final String? blockHash;

  /// The stored proof being dropped (`MerkleProof.merkleProof`), if any.
  final List<String>? merkleProof;

  /// Why the confirmation was reverted (for the journal and logs).
  final String reason;

  RevertTransactionConfirmationCommand({
    required String walletId,
    required this.txid,
    required this.reason,
    this.blockHeight,
    this.blockHash,
    this.merkleProof,
    String? commandId,
    DateTime? timestamp,
    Map<String, dynamic>? metadata,
  }) : super(
          walletId: walletId,
          commandId: commandId,
          timestamp: timestamp,
          metadata: metadata,
        );

  @override
  String get commandType => 'RevertTransactionConfirmationCommand';
}

// =============================================================================
// DEFERRED PAYMENTS (bead libspiffy-7p2)
// =============================================================================

/// Journals the holds of outgoing transactions recorded with a deferred spend
/// before holds were journaled (journals written before bead libspiffy-7p2).
///
/// A record with no hold whose inputs the wallet still has unspent (and that
/// is not confirmed) is an outstanding deferred payment: a non-deferred
/// record spent its inputs in the same command. Each gets a
/// TransactionSpendDeferredEvent with `inferred: true`, even when its
/// reservation already expired or was released. No events when there is
/// nothing to reconcile. WalletManagerActor sends this when it loads a wallet
/// from the journal; the reservation commands apply the same inference, so
/// the hold is enforced before it is journaled too.
class ReconcileDeferredSpendsCommand extends WalletCommand {
  ReconcileDeferredSpendsCommand({
    required String walletId,
    String? commandId,
    DateTime? timestamp,
    Map<String, dynamic>? metadata,
  }) : super(walletId: walletId, commandId: commandId, timestamp: timestamp, metadata: metadata);

  @override
  String get commandType => 'ReconcileDeferredSpendsCommand';
}

/// Records a network status observed for [txid] (ARC or the data source).
///
/// Only a deferred payment of this wallet is affected; any other txid is a
/// no-op. The status is journaled when [explicit] or when it differs from the
/// last recorded one. REJECTED on an outstanding payment also fails it and
/// releases its inputs. Every other status (404 / NOT_FOUND, orphan mempool,
/// in-flight statuses, DOUBLE_SPEND_ATTEMPTED, which ARC documents as not
/// final: bead libspiffy-ey2) leaves the hold in place.
class RecordTransactionNetworkStatusCommand extends WalletCommand {
  final String txid;

  /// ARC's wire name (`SEEN_ON_NETWORK`, `REJECTED`, ...) or `NOT_FOUND`.
  final String networkStatus;

  /// `arc` or `dataSource`.
  final String source;
  final DateTime checkedAt;
  final int? blockHeight;
  final bool explicit;

  /// ARC's message for a failure (journaled as the failure reason).
  final String? detail;

  /// The competing transactions ARC named (`competingTxs`, reported with
  /// DOUBLE_SPEND_ATTEMPTED; bead libspiffy-pkum). Journaled with the status;
  /// a txid the payment's record does not hold yet journals the status even
  /// when it is unchanged.
  final List<String> competingTxids;

  RecordTransactionNetworkStatusCommand({
    required String walletId,
    required this.txid,
    required this.networkStatus,
    this.source = 'arc',
    DateTime? checkedAt,
    this.blockHeight,
    this.explicit = false,
    this.detail,
    this.competingTxids = const [],
    String? commandId,
    DateTime? timestamp,
    Map<String, dynamic>? metadata,
  })  : checkedAt = checkedAt ?? DateTime.now(),
        super(walletId: walletId, commandId: commandId, timestamp: timestamp, metadata: metadata);

  @override
  String get commandType => 'RecordTransactionNetworkStatusCommand';
}

/// Cancels the outstanding deferred payment [txid] and releases its inputs.
///
/// The aggregate refuses a payment that is not outstanding, or whose last
/// recorded network status says the network has it. It does not query the
/// network itself: `CancelDeferredPaymentCommand` on the coordinator checks
/// first and passes the answer as [networkStatus].
///
/// Cancelling does not revoke the signed transaction the recipient holds. If
/// it is broadcast later and reaches miners it spends those inputs, and a
/// later payment that reused them fails.
class CancelDeferredSpendCommand extends WalletCommand {
  final String txid;
  final String? reason;
  final String? networkStatus;

  CancelDeferredSpendCommand({
    required String walletId,
    required this.txid,
    this.reason,
    this.networkStatus,
    String? commandId,
    DateTime? timestamp,
    Map<String, dynamic>? metadata,
  }) : super(walletId: walletId, commandId: commandId, timestamp: timestamp, metadata: metadata);

  @override
  String get commandType => 'CancelDeferredSpendCommand';
}
