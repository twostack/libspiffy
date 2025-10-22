import 'dart:typed_data';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:dactor/dactor.dart';
import 'package:convert/convert.dart';

import '../storage/read_model_storage.dart';
import '../models/bitcoin_transaction.dart';
import '../core/wallet_commands.dart';
import '../actors/wallet_messages.dart';
import '../utils/beef.dart';
import '../utils/bump.dart';
import 'transaction_import_models.dart';
import 'transaction_analyzer.dart';

/// Service for importing historical transactions and harvesting UTXOs
/// 
/// Uses hybrid event sourcing approach:
/// - Transaction history stored as reference data in ReadModelStorage
/// - UTXOs harvested via commands to BitcoinWalletAggregate (event-sourced)
class TransactionImportService {
  final ReadModelStorage _storage;
  final ActorRef _walletManager;
  
  TransactionImportService({
    required ReadModelStorage storage,
    required ActorRef walletManager,
  }) : _storage = storage,
       _walletManager = walletManager;
  
  /// Import transactions for a wallet
  /// 
  /// Steps:
  /// 1. Store raw transactions + merkle proofs in ReadModelStorage
  /// 2. Sort transactions by dependency order
  /// 3. Two-phase analysis: identify wallet outputs, track spending
  /// 4. Issue ReceiveUTXOCommand to aggregate for each unspent output
  /// 
  /// This maintains event sourcing for wallet state while storing
  /// transaction history as queryable reference data.
  Future<TransactionImportResult> importTransactions({
    required String walletId,
    required List<ImportableTransaction> transactions,
    required List<String> walletAddresses,
  }) async {
    try {
      if (transactions.isEmpty) {
        return TransactionImportResult.error('No transactions to import');
      }
      
      if (walletAddresses.isEmpty) {
        return TransactionImportResult.error('No wallet addresses provided');
      }
      
      print('Importing ${transactions.length} transactions for wallet $walletId...');
      
      // Step 1: Store merkle proofs and prepare transactions for analysis
      final importedTxids = <String>[];
      final transactionHeights = <String, int>{};
      final transactionTimestamps = <String, DateTime>{};
      final dartsvTransactions = <dartsv.Transaction>[];
      
      for (final importTx in transactions) {
        // Store merkle proof if available
        if (importTx.merkleProof != null) {
          await _storage.storeMerkleProof(importTx.txid, importTx.merkleProof!);
        }
        
        // Parse transaction for analysis and storage
        final dartsvTx = dartsv.Transaction.fromHex(importTx.rawHex);
        
        // Store raw transaction in read model (for BEEF construction)
        final outputValue = dartsvTx.outputs.fold<BigInt>(
          BigInt.zero,
          (sum, output) => sum + output.satoshis,
        );
        
        final bitcoinTx = BitcoinTransaction(
          txid: importTx.txid,
          rawHex: importTx.rawHex,
          status: importTx.blockHeight > 0 
              ? TransactionStatus.confirmed 
              : TransactionStatus.pending,
          blockHeight: importTx.blockHeight > 0 ? importTx.blockHeight : null,
          confirmations: importTx.blockHeight > 0 ? 1 : 0,
          inputValue: BigInt.zero, // Not needed for reference data
          outputValue: outputValue,
          fee: BigInt.zero, // Not needed for reference data
          receivingAddresses: [], // Not needed for reference data
          sendingAddresses: [], // Not needed for reference data  
          netAmount: BigInt.zero, // Not needed for reference data
          createdAt: importTx.timestamp,
          updatedAt: importTx.timestamp,
          lockTime: dartsvTx.nLockTime,
          version: dartsvTx.version,
        );
        
        await _storage.storeTransaction(walletId, bitcoinTx);
        
        importedTxids.add(importTx.txid);
        transactionHeights[importTx.txid] = importTx.blockHeight;
        transactionTimestamps[importTx.txid] = importTx.timestamp;
        dartsvTransactions.add(dartsvTx);
      }
      
      print('✓ Stored ${importedTxids.length} transactions and merkle proofs in read model');
      
      // Step 2: Sort by dependency order (parents before children)
      final sortedTransactions = TransactionAnalyzer.sortByDependency(
        dartsvTransactions,
      );
      
      print('✓ Sorted transactions by dependency order');
      
      // Step 3: Two-phase UTXO harvesting
      final harvestResult = TransactionAnalyzer.harvestUTXOs(
        transactions: sortedTransactions,
        walletAddresses: walletAddresses,
        transactionHeights: transactionHeights,
        transactionTimestamps: transactionTimestamps,
      );
      
      print('✓ Harvested ${harvestResult.utxos.length} UTXOs '
            '(${harvestResult.totalAmount} satoshis)');
      
      // Step 4: Issue ReceiveUTXOCommand for each UTXO (event-sourced)
      final harvestedUtxoIds = <String>[];
      
      for (final utxo in harvestResult.utxos) {
        final command = ReceiveUTXOCommand(
          walletId: walletId,
          txid: utxo.txid,
          vout: utxo.vout,
          satoshis: utxo.satoshis,
          scriptPubKey: utxo.scriptPubKey,
          address: utxo.address,
          blockHeight: utxo.blockHeight,
          confirmations: utxo.blockHeight > 0 ? 1 : 0,
        );
        
        // Send to WalletManagerActor (which routes to aggregate)
        _walletManager.tell(WalletCommandMessage(walletId, command));
        
        harvestedUtxoIds.add('${utxo.txid}:${utxo.vout}');
      }
      
      print('✓ Issued ${harvestResult.utxos.length} ReceiveUTXOCommands to aggregate');
      
      // Give aggregate time to process commands
      await Future.delayed(Duration(milliseconds: 100));
      
      return TransactionImportResult.success(
        transactionsImported: importedTxids.length,
        utxosHarvested: harvestedUtxoIds.length,
        importedTxids: importedTxids,
        harvestedUtxoIds: harvestedUtxoIds,
      );
      
    } catch (e, stackTrace) {
      print('Error importing transactions: $e');
      print(stackTrace);
      return TransactionImportResult.error('Import failed: $e');
    }
  }
  
  /// Import transactions from BEEF package
  /// 
  /// Convenience method that extracts transactions and merkle proofs
  /// from a BEEF package and imports them.
  Future<TransactionImportResult> importFromBEEF({
    required String walletId,
    required Uint8List beefBytes,
    required List<String> walletAddresses,
  }) async {
    try {
      final beef = BEEF.parse(beefBytes);
      
      // Extract transactions with merkle proofs
      final importable = <ImportableTransaction>[];
      
      for (int i = 0; i < beef.txs.length; i++) {
        final rawHex = hex.encode(beef.txs[i]);
        final txid = _calculateTxid(beef.txs[i]);
        
        // Find merkle proof if available
        MerkleProof? merkleProof;
        if (i < beef.hasMerkle.length && beef.hasMerkle[i]) {
          final bumpIndex = beef.bumpIndex[i];
          final bump = beef.bumps[bumpIndex];
          merkleProof = _extractMerkleProofFromBUMP(txid, bump);
        }
        
        importable.add(ImportableTransaction(
          txid: txid,
          rawHex: rawHex,
          blockHeight: merkleProof?.blockHeight ?? 0,
          merkleProof: merkleProof,
        ));
      }
      
      return importTransactions(
        walletId: walletId,
        transactions: importable,
        walletAddresses: walletAddresses,
      );
      
    } catch (e) {
      return TransactionImportResult.error('Failed to parse BEEF: $e');
    }
  }
  
  String _calculateTxid(Uint8List txBytes) {
    // Parse the transaction to get its ID
    try {
      final txHex = hex.encode(txBytes);
      final tx = dartsv.Transaction.fromHex(txHex);
      return tx.id;
    } catch (e) {
      // Fallback to hex prefix if parsing fails
      return hex.encode(txBytes).substring(0, 64);
    }
  }
  
  MerkleProof _extractMerkleProofFromBUMP(String txid, BUMP bump) {
    // Extract merkle path from BUMP structure
    final path = <String>[];
    for (int i = 1; i < bump.path.length; i++) {
      final level = bump.path[i];
      if (level.leaves.isNotEmpty) {
        final hash = level.leaves[0].hash;
        if (hash != null) {
          path.add(hex.encode(hash));
        }
      }
    }
    
    return MerkleProof(
      blockHash: '', // Not available in BUMP
      txid: txid,
      merkleProof: path,
      position: bump.path[0].leaves[0].offset,
      blockHeight: bump.blockHeight,
    );
  }
}

