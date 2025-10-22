import '../storage/read_model_storage.dart';

/// Raw transaction with merkle proof for import
class ImportableTransaction {
  final String txid;
  final String rawHex;
  final int blockHeight;
  final MerkleProof? merkleProof;
  final DateTime timestamp;
  
  ImportableTransaction({
    required this.txid,
    required this.rawHex,
    required this.blockHeight,
    this.merkleProof,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();
}

/// Result of transaction import operation
class TransactionImportResult {
  final bool success;
  final int transactionsImported;
  final int utxosHarvested;
  final List<String> importedTxids;
  final List<String> harvestedUtxoIds;
  final String? error;
  
  TransactionImportResult.success({
    required this.transactionsImported,
    required this.utxosHarvested,
    required this.importedTxids,
    required this.harvestedUtxoIds,
  }) : success = true, error = null;
  
  TransactionImportResult.error(this.error)
    : success = false,
      transactionsImported = 0,
      utxosHarvested = 0,
      importedTxids = const [],
      harvestedUtxoIds = const [];
}

