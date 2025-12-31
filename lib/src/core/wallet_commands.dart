import 'package:eventador/eventador.dart';
import '../models/bitcoin_utxo.dart'; // For UTXOStatus

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
  final String? passphrase; // Optional passphrase for mnemonic
  final Map<String, dynamic>? walletMetadata; // Additional wallet metadata

  CreateWalletCommand({
    required String walletId,
    required this.walletName,
    this.mnemonic,
    this.wif,
    this.xpriv,
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
    ].where((x) => x).length;
    
    if (specified > 1) {
      throw ArgumentError(
        'Only one of mnemonic, wif, or xpriv can be specified'
      );
    }
  }

  @override
  String get commandType => 'CreateWalletCommand';
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

  GenerateAddressCommand({
    required String walletId,
    this.label,
    this.purpose,
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
  String get commandType => 'GenerateAddressCommand';
}

/// Command to generate an address for payment channels
/// Returns address + public key + derivation index (needed for channel operations)
class GenerateChannelAddressCommand extends WalletCommand {
  final String correlationId; // Unique ID to correlate request/response
  final String? context; // Context identifier (e.g., "audiospace:meeting-123")
  final String? label; // Optional label for the address
  
  GenerateChannelAddressCommand({
    required String walletId,
    String? correlationId,
    this.context,
    this.label,
    String? commandId,
    DateTime? timestamp,
    Map<String, dynamic>? metadata,
  }) : correlationId = correlationId ?? commandId ?? 'channel-${DateTime.now().millisecondsSinceEpoch}',
       super(
          walletId: walletId,
          commandId: commandId,
          timestamp: timestamp,
          metadata: metadata,
        );

  @override
  String get commandType => 'GenerateChannelAddressCommand';
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

// =============================================================================
// UTXO MANAGEMENT COMMANDS
// =============================================================================

/// Command to record a received UTXO
class ReceiveUTXOCommand extends WalletCommand {
  final String txid;
  final int vout;
  final BigInt satoshis;
  final String scriptPubKey;
  final String address;
  final int? blockHeight; // null for unconfirmed
  final int? confirmations;
  final UTXOStatus initialStatus; // Status to set when creating the UTXO

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

  ConfirmTransactionCommand({
    required String walletId,
    required this.txid,
    this.blockHeight,
    this.blockHash,
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

/// Command to create a new transaction
class CreateTransactionCommand extends WalletCommand {
  final String transactionId;
  final List<TransactionOutput> outputs;
  final BigInt? feeRate; // Satoshis per KB
  final String? changeAddress; // null = auto-generate
  final bool allowDust; // Allow dust outputs
  final Map<String, dynamic>? transactionMetadata; // Additional transaction metadata

  CreateTransactionCommand({
    required String walletId,
    required this.transactionId,
    required this.outputs,
    this.feeRate,
    this.changeAddress,
    this.allowDust = false,
    this.transactionMetadata,
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
  String get commandType => 'CreateTransactionCommand';
}

/// Command to sign a transaction
class SignTransactionCommand extends WalletCommand {
  final String transactionId;
  final String rawTransaction; // Unsigned transaction hex
  final List<String> utxoKeys; // UTXOs being spent
  final List<String> publicKeys;

  SignTransactionCommand({
    required String walletId,
    required this.transactionId,
    required this.rawTransaction,
    required this.utxoKeys,
    required this.publicKeys,
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
  final int derivationIndex; // Which key to use (m/0/{index})
  final int inputIndex; // Which input to sign
  final int prevOutValue; // Satoshi value of input being spent
  final String redeemScriptHex; // 2-of-2 multisig redeem script
  final int sighashType; // SIGHASH flags (e.g., SIGHASH_ALL | SIGHASH_FORKID)

  SignMultisigTransactionCommand({
    required String walletId,
    required this.transactionId,
    required this.rawTransaction,
    required this.derivationIndex,
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

  BuildFundingTransactionCommand({
    required String walletId,
    required this.correlationId,
    required this.channelId,
    required this.clientPubKeyHex,
    required this.serverPubKeyHex,
    required this.fundingAmountSats,
    required this.changeAddressBase58,
    this.derivationIndex,
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

// =============================================================================
// SUPPORTING CLASSES
// =============================================================================

/// Represents a transaction output for CreateTransactionCommand
class TransactionOutput {
  final String address;
  final BigInt satoshis;
  final String? script; // Optional custom script (null = P2PKH)

  const TransactionOutput({
    required this.address,
    required this.satoshis,
    this.script,
  });

  @override
  String toString() {
    return 'TransactionOutput(address: $address, satoshis: $satoshis, script: $script)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is TransactionOutput &&
        other.address == address &&
        other.satoshis == satoshis &&
        other.script == script;
  }

  @override
  int get hashCode {
    return address.hashCode ^ satoshis.hashCode ^ script.hashCode;
  }
} 