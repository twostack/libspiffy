import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:logging/logging.dart';

import '../models/blockchain_data_models.dart';
import 'blockchain_data_source.dart';
import '../utils/tsc_converter.dart';
import '../utils/bump.dart';

/// Service for importing transactions with SPV validation
///
/// This service orchestrates the complete import process:
/// 1. Fetch raw transaction data
/// 2. Retrieve merkle proof
/// 3. Convert proof to BUMP format
/// 4. Return validated transaction with proof
///
/// Example:
/// ```dart
/// final importService = TransactionImportService(
///   dataSource: dataSource,
///   converter: TscConverter(),
/// );
///
/// final imported = await importService.importTransaction(
///   txid: 'abc123...',
/// );
/// ```
class TransactionImportService {
  final Logger _logger = Logger('TransactionImportService');
  final BlockchainDataSource _dataSource;
  final TscConverter _converter;

  TransactionImportService({
    required BlockchainDataSource dataSource,
    TscConverter? converter,
  })  : _dataSource = dataSource,
        _converter = converter ?? TscConverter();

  /// Import a single transaction with merkle proof
  ///
  /// Parameters:
  /// - [txid]: Transaction ID to import
  ///
  /// Returns [ImportedTransaction] with raw hex and BUMP proof.
  ///
  /// Throws [TransactionImportException] if import fails.
  Future<ImportedTransaction> importTransaction(String txid) async {
    _logger.fine('Importing transaction $txid');

    try {
      // Fetch raw transaction
      _logger.info('      → Fetching raw transaction for $txid...');
      final rawHex = await _dataSource.getRawTransaction(txid);
      _logger.info('      ✅ Raw TX fetched (${rawHex.length} bytes)');

      // Fetch merkle proof
      _logger.info('      → Fetching merkle proof for $txid...');
      final proofData = await _dataSource.getMerkleProof(txid);
      _logger.info('      ✅ Merkle proof fetched (height: ${proofData.blockHeight})');

      // Convert TSC proof to BUMP
      _logger.info('      → Converting TSC proof to BUMP...');
      final bump = _converter.convertToBump(proofData);
      _logger.info('      ✅ BUMP created (${bump.path.length} levels)');

      // Validate BUMP structure
      if (!_converter.validateBump(bump)) {
        throw TransactionImportException(
          'Generated BUMP failed validation',
          txid: txid,
        );
      }

      _logger.info('      ✅ Transaction $txid fully imported and validated');

      return ImportedTransaction(
        txid: txid,
        rawHex: rawHex,
        blockHeight: proofData.blockHeight,
        bump: bump,
      );
    } on DataSourceException catch (e) {
      _logger.severe('      ❌ Data source error for $txid: ${e.message}');
      throw TransactionImportException(
        'Data source error: ${e.message}',
        txid: txid,
        originalError: e,
      );
    } catch (e, stackTrace) {
      _logger.severe('      ❌ Import failed for $txid: $e');
      _logger.fine('      Stack trace: $stackTrace');
      throw TransactionImportException(
        'Import failed',
        txid: txid,
        originalError: e,
      );
    }
  }

  /// Import multiple transactions in batch
  ///
  /// Parameters:
  /// - [txids]: List of transaction IDs to import
  /// - [onProgress]: Optional progress callback
  ///
  /// Returns list of [ImportedTransaction], skipping any that fail.
  Future<List<ImportedTransaction>> importTransactions({
    required List<String> txids,
    void Function(int completed, int total)? onProgress,
  }) async {
    _logger.info('📦 Importing ${txids.length} transactions');

    final imported = <ImportedTransaction>[];
    int completed = 0;

    for (final txid in txids) {
      try {
        _logger.info('   → Importing TX $txid (${completed + 1}/${txids.length})');
        final transaction = await importTransaction(txid);
        imported.add(transaction);
        _logger.info('   ✅ TX $txid imported successfully');
      } catch (e, stackTrace) {
        _logger.warning('   ❌ Failed to import transaction $txid: $e');
        _logger.fine('   Stack trace: $stackTrace');
        // Continue with other transactions
      }

      completed++;
      if (onProgress != null) {
        onProgress(completed, txids.length);
      }
    }

    _logger.info('📊 Import complete: ${imported.length}/${txids.length} transactions successful');

    return imported;
  }

  /// Import all transactions for a discovered address
  ///
  /// Parameters:
  /// - [address]: The discovered address
  ///
  /// Returns list of [ImportedTransaction] for the address.
  Future<List<ImportedTransaction>> importAddressTransactions(
    DiscoveredAddress address,
  ) async {
    _logger.info(
      '🔄 Importing ${address.transactionCount} transactions for address ${address.address}',
    );
    _logger.info('   TXIDs: ${address.txids.join(", ")}');

    final result = await importTransactions(
      txids: address.txids,
      onProgress: (completed, total) {
        _logger.info('   Progress: $completed/$total transactions imported');
      },
    );
    
    _logger.info('   ✅ Completed: ${result.length} transactions imported for ${address.address}');
    return result;
  }

  /// Import transactions for multiple addresses
  ///
  /// Parameters:
  /// - [addresses]: List of discovered addresses
  /// - [onProgress]: Optional progress callback (addressIndex, totalAddresses)
  ///
  /// Returns flat list of all imported transactions.
  Future<List<ImportedTransaction>> importAllAddressTransactions({
    required List<DiscoveredAddress> addresses,
    void Function(int addressIndex, int totalAddresses)? onProgress,
  }) async {
    _logger.info('Importing transactions for ${addresses.length} addresses');

    final allTransactions = <ImportedTransaction>[];
    int addressIndex = 0;

    for (final address in addresses) {
      _logger.fine(
        'Processing address ${address.address} (${address.transactionCount} txs)',
      );

      final transactions = await importAddressTransactions(address);
      allTransactions.addAll(transactions);

      addressIndex++;
      if (onProgress != null) {
        onProgress(addressIndex, addresses.length);
      }
    }

    _logger.info('Imported total of ${allTransactions.length} transactions');

    return allTransactions;
  }

  /// Get transaction info without importing (for previewing)
  ///
  /// Fetches transaction details without retrieving the full raw hex
  /// or merkle proof. Useful for showing import preview.
  Future<TransactionInfo?> getTransactionInfo(String txid) async {
    try {
      final history = await _dataSource.getTransactionHistory('');
      return history.firstWhere(
        (tx) => tx.txid == txid,
        orElse: () => TransactionInfo(txid: txid),
      );
    } catch (e) {
      _logger.warning('Could not get transaction info for $txid: $e');
      return null;
    }
  }
}

/// Represents a successfully imported transaction
class ImportedTransaction {
  /// Transaction ID
  final String txid;

  /// Raw transaction hex
  final String rawHex;

  /// Block height where transaction was confirmed
  final int blockHeight;

  /// BUMP merkle proof
  final BUMP bump;

  /// Parsed transaction (lazy-loaded)
  dartsv.Transaction? _parsedTransaction;

  ImportedTransaction({
    required this.txid,
    required this.rawHex,
    required this.blockHeight,
    required this.bump,
  });

  /// Get parsed DartSV transaction
  dartsv.Transaction get transaction {
    _parsedTransaction ??= dartsv.Transaction.fromHex(rawHex);
    return _parsedTransaction!;
  }

  @override
  String toString() {
    return 'ImportedTransaction(txid: $txid, blockHeight: $blockHeight)';
  }
}

/// Exception thrown during transaction import
class TransactionImportException implements Exception {
  final String message;
  final String? txid;
  final dynamic originalError;

  TransactionImportException(
    this.message, {
    this.txid,
    this.originalError,
  });

  @override
  String toString() {
    final buffer = StringBuffer('TransactionImportException: $message');
    if (txid != null) buffer.write(' (txid: $txid)');
    if (originalError != null) buffer.write('\nCaused by: $originalError');
    return buffer.toString();
  }
}
