import 'package:spiffynode/spiffy_node.dart';
import '../storage/wallet_storage.dart';
import '../models/bitcoin_transaction.dart';

/// Base class for all SPV-related messages
abstract class SPVMessage {}

/// Messages for block header management

/// Message sent when new block headers are received from SpiffyNode
class BlockHeadersReceivedMessage implements SPVMessage {
  final String peerId;
  final List<BlockHeader> headers;
  final int startHeight;
  final bool isReorganization;
  final DateTime receivedAt;

  BlockHeadersReceivedMessage({
    required this.peerId,
    required this.headers,
    required this.startHeight,
    this.isReorganization = false,
    DateTime? receivedAt,
  }) : receivedAt = receivedAt ?? DateTime.now();

  @override
  String toString() => 'BlockHeadersReceivedMessage(peer: $peerId, '
      'headers: ${headers.length}, startHeight: $startHeight)';
}

/// Message sent when a block header is successfully stored
class BlockHeaderStoredMessage implements SPVMessage {
  final BlockHeader header;
  final int height;
  final bool isReorg;
  final DateTime storedAt;
  
  BlockHeaderStoredMessage({
    required this.header,
    required this.height,
    this.isReorg = false,
    DateTime? storedAt,
  }) : storedAt = storedAt ?? DateTime.now();

  @override
  String toString() => 'BlockHeaderStoredMessage(height: $height, '
      'hash: ${header.blockHash().toString().substring(0, 16)}...)';
}

/// Message to request block header synchronization
class RequestHeaderSyncMessage implements SPVMessage {
  final String? walletId; // null = sync for all wallets
  final int? fromHeight; // null = sync from genesis
  final String? stopHash; // null = sync to tip
  final bool forceFull; // Force full resync even if already synced
  
  RequestHeaderSyncMessage({
    this.walletId,
    this.fromHeight,
    this.stopHash,
    this.forceFull = false,
  });

  @override
  String toString() => 'RequestHeaderSyncMessage(wallet: $walletId, '
      'fromHeight: $fromHeight, forceFull: $forceFull)';
}

/// Chain tip event from SpiffyNode's ChainTipTracker
class ChainTipEventMessage implements SPVMessage {
  final ChainTip? oldTip;
  final ChainTip newTip;
  final ChainTipEventType eventType;
  final String? triggeringPeer;
  final String description;
  final DateTime eventTime;

  ChainTipEventMessage({
    this.oldTip,
    required this.newTip,
    required this.eventType,
    this.triggeringPeer,
    required this.description,
    DateTime? eventTime,
  }) : eventTime = eventTime ?? DateTime.now();

  /// Height change (positive for increase, negative for decrease)
  int get heightChange {
    if (oldTip == null) return newTip.height;
    return newTip.height - oldTip!.height;
  }

  /// Whether this represents a blockchain reorganization
  bool get isReorganization => eventType == ChainTipEventType.reorganization;

  @override
  String toString() => 'ChainTipEventMessage($eventType: $description, '
      'height: ${newTip.height})';
}

/// Messages for transaction validation

/// Message to validate a transaction received from a counterparty
class ValidateTransactionMessage implements SPVMessage {
  final String walletId;
  final BitcoinTransaction transaction;
  final List<MerkleProof> merkleProofs;
  final String fromCounterparty;
  final bool requireAllProofs; // Require proofs for all inputs
  final DateTime receivedAt;
  
  ValidateTransactionMessage({
    required this.walletId,
    required this.transaction,
    required this.merkleProofs,
    required this.fromCounterparty,
    this.requireAllProofs = true,
    DateTime? receivedAt,
  }) : receivedAt = receivedAt ?? DateTime.now();

  @override
  String toString() => 'ValidateTransactionMessage(wallet: $walletId, '
      'tx: ${transaction.txid}, proofs: ${merkleProofs.length})';
}

/// Result of transaction validation
class TransactionValidationResult implements SPVMessage {
  final String walletId;
  final String transactionId;
  final bool isValid;
  final BitcoinTransaction? transaction;
  final int? blockHeight;
  final List<String> validatedInputs; // List of input UTXOs that were validated
  final List<String> invalidInputs; // List of input UTXOs that failed validation
  final String? error;
  final DateTime validatedAt;
  
  TransactionValidationResult({
    required this.walletId,
    required this.transactionId,
    required this.isValid,
    this.transaction,
    this.blockHeight,
    this.validatedInputs = const [],
    this.invalidInputs = const [],
    this.error,
    DateTime? validatedAt,
  }) : validatedAt = validatedAt ?? DateTime.now();

  /// Whether validation was successful
  bool get hasValidation => isValid && error == null;

  /// Summary of validation results
  String get validationSummary {
    if (isValid) {
      return 'Valid (${validatedInputs.length} inputs validated)';
    } else {
      return 'Invalid: $error (${invalidInputs.length} inputs failed)';
    }
  }

  @override
  String toString() => 'TransactionValidationResult(wallet: $walletId, '
      'tx: $transactionId, valid: $isValid)';
}

/// Message to validate a BEEF (Bitcoin Extended Format) transaction package
class ValidateBEEFMessage implements SPVMessage {
  final String walletId;
  final String beefHex;
  final String fromCounterparty;
  final bool storeMerkleProofs; // Whether to store extracted proofs
  final DateTime receivedAt;

  ValidateBEEFMessage({
    required this.walletId,
    required this.beefHex,
    required this.fromCounterparty,
    this.storeMerkleProofs = true,
    DateTime? receivedAt,
  }) : receivedAt = receivedAt ?? DateTime.now();

  @override
  String toString() => 'ValidateBEEFMessage(wallet: $walletId, '
      'beef: ${beefHex.length} bytes)';
}

/// Result of BEEF validation
class BEEFValidationResult implements SPVMessage {
  final String walletId;
  final bool isValid;
  final List<BitcoinTransaction> transactions;
  final List<MerkleProof> merkleProofs;
  final String? merkleRoot;
  final String? error;
  final DateTime validatedAt;

  BEEFValidationResult({
    required this.walletId,
    required this.isValid,
    this.transactions = const [],
    this.merkleProofs = const [],
    this.merkleRoot,
    this.error,
    DateTime? validatedAt,
  }) : validatedAt = validatedAt ?? DateTime.now();

  @override
  String toString() => 'BEEFValidationResult(wallet: $walletId, '
      'valid: $isValid, txs: ${transactions.length})';
}

/// Messages for merkle proof management

/// Request to retrieve merkle proof from ARC or other source
class RetrieveMerkleProofMessage implements SPVMessage {
  final String txid;
  final int? knownBlockHeight;
  final String? knownBlockHash;
  final String walletId;
  final bool storeAfterRetrieval;
  final DateTime requestedAt;

  RetrieveMerkleProofMessage({
    required this.txid,
    this.knownBlockHeight,
    this.knownBlockHash,
    required this.walletId,
    this.storeAfterRetrieval = true,
    DateTime? requestedAt,
  }) : requestedAt = requestedAt ?? DateTime.now();

  @override
  String toString() => 'RetrieveMerkleProofMessage(tx: $txid, '
      'wallet: $walletId, height: $knownBlockHeight)';
}

/// Message sent when a merkle proof is retrieved/stored
class MerkleProofStoredMessage implements SPVMessage {
  final String txid;
  final MerkleProof proof;
  final String source; // 'arc', 'counterparty', 'restored'
  final DateTime storedAt;

  MerkleProofStoredMessage({
    required this.txid,
    required this.proof,
    this.source = 'unknown',
    DateTime? storedAt,
  }) : storedAt = storedAt ?? DateTime.now();

  @override
  String toString() => 'MerkleProofStoredMessage(tx: $txid, '
      'source: $source, height: ${proof.blockHeight})';
}

/// Messages for SPV status and control

/// Request SPV status information
class GetSPVStatusMessage implements SPVMessage {
  final String? walletId; // null = global status

  GetSPVStatusMessage({this.walletId});

  @override
  String toString() => 'GetSPVStatusMessage(wallet: $walletId)';
}

/// SPV status response
class SPVStatusMessage implements SPVMessage {
  final String? walletId;
  final int currentHeight;
  final int networkHeight;
  final bool isSynced;
  final int headersCached;
  final int merkleProofsStored;
  final DateTime lastHeaderUpdate;
  final List<String> connectedPeers;
  final bool isHealthy;
  final String? statusMessage;

  SPVStatusMessage({
    this.walletId,
    required this.currentHeight,
    required this.networkHeight,
    required this.isSynced,
    required this.headersCached,
    required this.merkleProofsStored,
    required this.lastHeaderUpdate,
    required this.connectedPeers,
    required this.isHealthy,
    this.statusMessage,
  });

  /// Sync progress as percentage (0.0 to 1.0)
  double get syncProgress {
    if (networkHeight == 0) return 1.0;
    return (currentHeight / networkHeight).clamp(0.0, 1.0);
  }

  /// How far behind the network we are
  int get heightDifference => networkHeight - currentHeight;

  @override
  String toString() => 'SPVStatusMessage(height: $currentHeight/$networkHeight, '
      'synced: $isSynced, healthy: $isHealthy)';
}

/// Message to start/stop SPV operations
class SPVControlMessage implements SPVMessage {
  final SPVControlAction action;
  final String? walletId; // null = global control
  final Map<String, dynamic>? parameters;

  SPVControlMessage({
    required this.action,
    this.walletId,
    this.parameters,
  });

  @override
  String toString() => 'SPVControlMessage(action: $action, wallet: $walletId)';
}

enum SPVControlAction {
  start,
  stop,
  pause,
  resume,
  reset,
  forceSync,
}

/// Error message for SPV operations
class SPVErrorMessage implements SPVMessage {
  final String operation;
  final String error;
  final String? walletId;
  final DateTime errorTime;
  final bool isFatal;

  SPVErrorMessage({
    required this.operation,
    required this.error,
    this.walletId,
    DateTime? errorTime,
    this.isFatal = false,
  }) : errorTime = errorTime ?? DateTime.now();

  @override
  String toString() => 'SPVErrorMessage(op: $operation, '
      'error: $error, fatal: $isFatal)';
}

/// Configuration message for SPV operations
class SPVConfigMessage implements SPVMessage {
  final bool enableHeaderValidation;
  final bool enableMerkleProofValidation;
  final int maxHeaderCacheSize;
  final Duration headerSyncTimeout;
  final int reorgProtectionDepth;
  final bool autoRetryFailedValidations;

  SPVConfigMessage({
    this.enableHeaderValidation = true,
    this.enableMerkleProofValidation = true,
    this.maxHeaderCacheSize = 2016,
    this.headerSyncTimeout = const Duration(minutes: 10),
    this.reorgProtectionDepth = 6,
    this.autoRetryFailedValidations = true,
  });

  @override
  String toString() => 'SPVConfigMessage(headerValidation: $enableHeaderValidation, '
      'proofValidation: $enableMerkleProofValidation)';
} 