import 'package:dactor/dactor.dart';
import 'package:libspiffy/libspiffy.dart';
import '../core/wallet_commands.dart';

/// Messages for coordinating between actors in the LibSpiffy system

// ==========================================================================
// ARC TRANSACTION TRACKING MESSAGES
// ==========================================================================

/// Register transaction outputs for status tracking
class RegisterTransactionOutputsMessage implements Message {
  final String txid;
  final String walletId;
  final List<int> vouts;

  RegisterTransactionOutputsMessage({
    required this.txid,
    required this.walletId,
    required this.vouts,
  });

  @override
  String get correlationId => 'register-outputs-$txid';
  @override
  Map<String, dynamic> get metadata => {'walletId': walletId};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

// ==========================================================================
// WALLET MANAGER MESSAGES
// ==========================================================================

/// Request to create a new wallet
class CreateWalletMessage implements Message {
  final String walletId;
  final String name;
  final String? mnemonic;
  final String? wif;
  final String? xpriv;
  final Map<String, dynamic>? walletMetadata;

  CreateWalletMessage(
    this.walletId,
    this.name, {
    this.mnemonic,
    this.wif,
    this.xpriv,
    this.walletMetadata,
  });

  @override
  String get correlationId => 'create-wallet-$walletId';
  @override
  Map<String, dynamic> get metadata => walletMetadata ?? {};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// Response containing wallet creation result (from WalletManagerActor to external caller)
class WalletCreatedMessage implements Message {
  final String walletId;
  final String rootAddress;
  final bool success;
  final String? error;

  WalletCreatedMessage(this.walletId, this.rootAddress, this.success, {this.error});

  @override
  String get correlationId => 'wallet-created-$walletId';
  @override
  Map<String, dynamic> get metadata => {};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// Response from BitcoinWalletAggregate after processing CreateWalletCommand
class WalletCreatedResponse implements Message {
  final String walletId;
  final String rootAddress;
  final bool success;
  final String? error;

  WalletCreatedResponse({
    required this.walletId,
    required this.rootAddress,
    required this.success,
    this.error,
  });

  @override
  String get correlationId => 'wallet-created-response-$walletId';
  @override
  Map<String, dynamic> get metadata => {'walletId': walletId};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// Response from BitcoinWalletAggregate after processing GenerateAddressCommand
class AddressGeneratedResponse implements Message {
  final String walletId;
  final String address;
  final int derivationIndex;
  final bool success;
  final String? error;
  final Map<String, dynamic> _metadata;

  AddressGeneratedResponse({
    required this.walletId,
    required this.address,
    required this.derivationIndex,
    required this.success,
    this.error,
    Map<String, dynamic>? metadata,
  }) : _metadata = metadata ?? {};

  @override
  String get correlationId => 'address-generated-response-$walletId-$derivationIndex';
  @override
  Map<String, dynamic> get metadata => {
    'walletId': walletId,
    'address': address,
    ..._metadata, // Merge passed metadata
  };
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// Response from BitcoinWalletAggregate after processing CreateTransactionCommand
class TransactionCreatedResponse implements Message {
  final String walletId;
  final String txid;
  final String rawHex;
  final bool success;
  final String? error;

  TransactionCreatedResponse({
    required this.walletId,
    required this.txid,
    required this.rawHex,
    required this.success,
    this.error,
  });

  @override
  String get correlationId => 'transaction-created-response-$txid';
  @override
  Map<String, dynamic> get metadata => {'walletId': walletId, 'txid': txid};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// Response from BitcoinWalletAggregate after signing transaction
class TransactionSignedResponse implements Message {
  final String walletId;
  final String txid;
  final String signedHex;
  final bool success;
  final String? error;

  TransactionSignedResponse({
    required this.walletId,
    required this.txid,
    required this.signedHex,
    required this.success,
    this.error,
  });

  @override
  String get correlationId => 'transaction-signed-response-$txid';
  @override
  Map<String, dynamic> get metadata => {'walletId': walletId, 'txid': txid};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// Route a command to a specific wallet
class WalletCommandMessage implements Message {
  final String walletId;
  final WalletCommand command;

  WalletCommandMessage(this.walletId, this.command);

  @override
  String get correlationId => 'wallet-cmd-${walletId}-${command.commandId}';
  @override
  Map<String, dynamic> get metadata => {'walletId': walletId};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// Request list of all wallets
class ListWalletsMessage implements Message {
  @override
  String get correlationId => 'list-wallets-${DateTime.now().millisecondsSinceEpoch}';
  @override
  Map<String, dynamic> get metadata => {};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// Response with list of wallet IDs
class WalletListMessage implements Message {
  final List<String> walletIds;

  WalletListMessage(this.walletIds);

  @override
  String get correlationId => 'wallet-list-${DateTime.now().millisecondsSinceEpoch}';
  @override
  Map<String, dynamic> get metadata => {};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

// ==========================================================================
// SPV ACTOR MESSAGES - CORRECTED FOR TRUE SPV
// ==========================================================================

/// Receive transaction directly from counterparty with proofs (CORE SPV)
class ReceiveTransactionMessage implements Message {
  final String transactionId;
  final BEEF beef; //BEEF data for transactionId
  final String fromCounterparty;
  final String? targetWalletId; // Which wallet this transaction is for
  final String? invoiceId; // Invoice ID for payment matching (transmitted in BEEF metadata)
  final DateTime receivedAt;

  ReceiveTransactionMessage({
    required this.transactionId,
    required this.beef,
    required this.fromCounterparty,
    this.targetWalletId,
    this.invoiceId,
    DateTime? receivedAt,
  }) : receivedAt = receivedAt ?? DateTime.now();

  @override
  String get correlationId => 'receive-tx-${transactionId}-${fromCounterparty}';
  @override
  Map<String, dynamic> get metadata => {
    'counterparty': fromCounterparty,
    'walletId': targetWalletId,
    'invoiceId': invoiceId,
  };
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => receivedAt;
}


/// SPV validation result after processing received transaction
class SPVValidationResult implements Message {
  final String txid;
  final bool isValid;
  final String? validationError;
  final List<Map<String, dynamic>> spendableUTXOs; // UTXOs we can now spend
  final List<Map<String, dynamic>> spentUTXOs; // UTXOs that were spent
  final String? targetWalletId;
  final BigInt? transactionFee; // Total transaction fee (only when spentUTXOs is not empty)
  final Map<String, dynamic>? transactionData; // Full transaction data for recording history

  SPVValidationResult({
    required this.txid,
    required this.isValid,
    this.validationError,
    this.spendableUTXOs = const [],
    this.spentUTXOs = const [],
    this.targetWalletId,
    this.transactionFee,
    this.transactionData,
  });

  @override
  String get correlationId => 'spv-validation-$txid';
  @override
  Map<String, dynamic> get metadata => {
    'valid': isValid,
    'walletId': targetWalletId,
  };
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// Block header update from SpiffyNode
class BlockHeaderUpdateMessage implements Message {
  final dynamic blockHeader; // Will be SpiffyNode's BlockHeader type
  final int height;
  final bool isReorganization;
  final List<dynamic>? orphanedHeaders; // If reorg occurred

  BlockHeaderUpdateMessage({
    required this.blockHeader,
    required this.height,
    this.isReorganization = false,
    this.orphanedHeaders,
  });

  @override
  String get correlationId => 'block-header-update-$height';
  @override
  Map<String, dynamic> get metadata => {
    'height': height,
    'reorg': isReorganization,
  };
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// Request BEEF validation (enhanced transaction format)
class ValidateBEEFMessage implements Message {
  final String beefData;
  final String? targetWalletId;

  ValidateBEEFMessage(this.beefData, {this.targetWalletId});

  @override
  String get correlationId => 'validate-beef-${DateTime.now().millisecondsSinceEpoch}';
  @override
  Map<String, dynamic> get metadata => {'walletId': targetWalletId};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// BEEF validation result
class BEEFValidationResult implements Message {
  final bool isValid;
  final String? merkleRoot;
  final String? error;
  final String? targetWalletId;
  final List<Map<String, dynamic>>? extractedTransactions;

  BEEFValidationResult({
    required this.isValid,
    this.merkleRoot,
    this.error,
    this.targetWalletId,
    this.extractedTransactions,
  });

  @override
  String get correlationId => 'beef-result-${DateTime.now().millisecondsSinceEpoch}';
  @override
  Map<String, dynamic> get metadata => {'walletId': targetWalletId};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

// ==========================================================================
// ARC ACTOR MESSAGES - ENHANCED WITH PROOF RETRIEVAL
// ==========================================================================

/// Request to broadcast a transaction
class BroadcastTransactionMessage implements Message {
  final String walletId;
  final String txHex;
  final String txid;

  BroadcastTransactionMessage(this.walletId, this.txHex, this.txid);

  @override
  String get correlationId => 'broadcast-$txid';
  @override
  Map<String, dynamic> get metadata => {'walletId': walletId, 'txid': txid};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// Request to broadcast BEEF data
class BroadcastBEEFMessage implements Message {
  final String walletId;
  final String beefHex;
  final String txid;

  BroadcastBEEFMessage(this.walletId, this.beefHex, this.txid);

  @override
  String get correlationId => 'broadcast-beef-$txid';
  @override
  Map<String, dynamic> get metadata => {'walletId': walletId, 'txid': txid};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// Request merkle proof retrieval from ARC (NEW)
class RetrieveMerkleProofMessage implements Message {
  final String txid;
  final int? knownBlockHeight;
  final String walletId;

  RetrieveMerkleProofMessage({
    required this.txid,
    this.knownBlockHeight,
    required this.walletId,
  });

  @override
  String get correlationId => 'retrieve-proof-$txid';
  @override
  Map<String, dynamic> get metadata => {
    'txid': txid,
    'walletId': walletId,
    'blockHeight': knownBlockHeight,
  };
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// Merkle proof retrieved from ARC (NEW)
class MerkleProofMessage implements Message {
  final String txid;
  final dynamic merkleProof; // Will be MerkleProof type
  final bool success;
  final String? error;

  MerkleProofMessage({
    required this.txid,
    this.merkleProof,
    required this.success,
    this.error,
  });

  @override
  String get correlationId => 'merkle-proof-$txid';
  @override
  Map<String, dynamic> get metadata => {'txid': txid, 'success': success};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// Check transaction status
class CheckTransactionStatusMessage implements Message {
  final String txid;

  CheckTransactionStatusMessage(this.txid);

  @override
  String get correlationId => 'check-status-$txid';
  @override
  Map<String, dynamic> get metadata => {'txid': txid};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// Transaction status response (ENHANCED)
class TransactionStatusMessage implements Message {
  final String txid;
  final String status; // 'pending', 'confirmed', 'failed'
  final int? confirmations;
  final int? blockHeight;
  final bool proofAvailable; // NEW: Can we get merkle proof now?

  TransactionStatusMessage({
    required this.txid,
    required this.status,
    this.confirmations,
    this.blockHeight,
    this.proofAvailable = false,
  });

  @override
  String get correlationId => 'tx-status-$txid';
  @override
  Map<String, dynamic> get metadata => {'txid': txid, 'status': status};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// Request fee quote
class GetFeeQuoteMessage implements Message {
  @override
  String get correlationId => 'fee-quote-${DateTime.now().millisecondsSinceEpoch}';
  @override
  Map<String, dynamic> get metadata => {};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// Fee quote response
class FeeQuoteMessage implements Message {
  final Map<String, dynamic> feeData;

  FeeQuoteMessage(this.feeData);

  @override
  String get correlationId => 'fee-quote-response-${DateTime.now().millisecondsSinceEpoch}';
  @override
  Map<String, dynamic> get metadata => {};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// Estimate fee for transaction
class EstimateFeeMessage implements Message {
  final int inputCount;
  final int outputCount;

  EstimateFeeMessage(this.inputCount, this.outputCount);

  @override
  String get correlationId => 'estimate-fee-${DateTime.now().millisecondsSinceEpoch}';
  @override
  Map<String, dynamic> get metadata => {};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// Fee estimate response
class FeeEstimateMessage implements Message {
  final BigInt estimatedFee;

  FeeEstimateMessage(this.estimatedFee);

  @override
  String get correlationId => 'fee-estimate-response-${DateTime.now().millisecondsSinceEpoch}';
  @override
  Map<String, dynamic> get metadata => {};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// Broadcast success notification
class BroadcastSuccessMessage implements Message {
  final String txid;
  final String? networkTxid;

  BroadcastSuccessMessage(this.txid, this.networkTxid);

  @override
  String get correlationId => 'broadcast-success-$txid';
  @override
  Map<String, dynamic> get metadata => {'txid': txid};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// Broadcast failure notification
class BroadcastFailedMessage implements Message {
  final String txid;
  final String error;

  BroadcastFailedMessage(this.txid, this.error);

  @override
  String get correlationId => 'broadcast-failed-$txid';
  @override
  Map<String, dynamic> get metadata => {'txid': txid};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// Notification about blockchain reorganization
class BlockchainReorganizationNotification implements Message {
  final int orphanedHeaderCount;
  final int newHeight;

  BlockchainReorganizationNotification({
    required this.orphanedHeaderCount,
    required this.newHeight,
  });

  @override
  String get correlationId => 'blockchain-reorg-${DateTime.now().millisecondsSinceEpoch}';
  @override
  Map<String, dynamic> get metadata => {
    'orphanedHeaderCount': orphanedHeaderCount,
    'newHeight': newHeight,
  };
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
} 

/// Message to set the Benford coordinator reference in WalletManager
class SetBenfordCoordinatorMessage implements Message {
  final ActorRef benfordCoordinator;

  SetBenfordCoordinatorMessage(this.benfordCoordinator);

  @override
  String get correlationId => 'set-benford-coordinator-${DateTime.now().millisecondsSinceEpoch}';
  @override
  Map<String, dynamic> get metadata => {'actorRef': benfordCoordinator.toString()};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// Message to trigger checking all pending UTXOs from storage against Arc
/// 
/// Sent when new block headers are received to check if any pending UTXOs
/// have been mined and need merkle proofs fetched from Arc.
class CheckStoragePendingUTXOsMessage implements Message {
  /// Block height that triggered this check (informational)
  final int triggerBlockHeight;
  
  CheckStoragePendingUTXOsMessage({required this.triggerBlockHeight});

  @override
  String get correlationId => 'check-pending-utxos-${DateTime.now().millisecondsSinceEpoch}';
  @override
  Map<String, dynamic> get metadata => {'triggerBlockHeight': triggerBlockHeight};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// Message to set the ARC actor reference in SPVActor
/// 
/// Used to wire up the ARCActor reference after actor system initialization,
/// enabling SPVActor to trigger pending UTXO checks when block headers arrive.
class SetArcActorForSPVMessage implements Message {
  final ActorRef arcActor;

  SetArcActorForSPVMessage(this.arcActor);

  @override
  String get correlationId => 'set-arc-actor-spv-${DateTime.now().millisecondsSinceEpoch}';
  @override
  Map<String, dynamic> get metadata => {'arcActorRef': arcActor.toString()};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}
