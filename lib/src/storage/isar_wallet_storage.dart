import 'dart:async';
import 'package:isar/isar.dart';
import 'package:spiffynode/spiffy_node.dart';
import '../models/bitcoin_utxo.dart';
import '../models/bitcoin_transaction.dart';
import 'read_model_storage.dart';
import 'libspiffy_schemas.dart';
import 'isar_config.dart';

// TODO: Import compute from foundation when needed for isolate operations
// import 'package:flutter/foundation.dart' show compute;

/// Isar-based implementation of ReadModelStorage.
///
/// This storage implementation provides persistent read-model operations
/// using Isar database with optional isolate support for heavy operations.
///
/// **Features:**
/// - Persistent storage using Isar
/// - Isolate-aware operations for UI responsiveness
/// - Efficient indexing and querying
/// - Support for SPV validation (block headers, merkle proofs)
///
/// **Usage:**
/// ```dart
/// final isar = await Isar.open([...LibSpiffySchemas.walletSchemas]);
/// final storage = IsarWalletStorage(isar);
/// ```
class IsarWalletStorage implements ReadModelStorage {
  final Isar _isar;
  // ignore: unused_field
  final IsolateConfig _config;

  IsarWalletStorage(this._isar, {IsolateConfig? config})
      : _config = config ?? IsolateConfig.defaultConfig();

  // ========================================
  // UTXO Queries
  // ========================================

  @override
  Future<List<BitcoinUtxo>> getUTXOs(
    String walletId, {
    bool includeSpent = false,
  }) async {
    final allEntities = await _isar.bitcoinUtxoEntitys
        .filter()
        .walletIdEqualTo(walletId)
        .findAll();
    
    if (includeSpent) {
      return allEntities.map((e) => e.toDomain()).toList();
    } else {
      // Filter out spent UTXOs
      final unspent = allEntities.where((e) => e.status != 'spent').toList();
      return unspent.map((e) => e.toDomain()).toList();
    }
  }

  @override
  Future<List<BitcoinUtxo>> getAvailableUTXOs(String walletId) async {
    final entities = await _isar.bitcoinUtxoEntitys
        .filter()
        .walletIdEqualTo(walletId)
        .and()
        .statusEqualTo('available')
        .findAll();

    return entities.map((e) => e.toDomain()).toList();
  }

  @override
  Future<BigInt> getBalance(String walletId) async {
    final utxos = await getAvailableUTXOs(walletId);
    return utxos.fold<BigInt>(
      BigInt.zero,
      (sum, utxo) => sum + utxo.satoshis,
    );
  }

  // ========================================
  // Transaction History
  // ========================================

  @override
  Future<List<BitcoinTransaction>> getTransactionHistory(
    String walletId, {
    int? limit,
    int? offset,
  }) async {
    final allEntities = await _isar.bitcoinTransactionEntitys
        .filter()
        .walletIdEqualTo(walletId)
        .sortByCreatedAtDesc()
        .findAll();

    // Apply offset and limit in memory
    var result = allEntities;
    if (offset != null) {
      result = result.skip(offset).toList();
    }
    if (limit != null) {
      result = result.take(limit).toList();
    }
    
    return result.map((e) => e.toDomain()).toList();
  }

  @override
  Future<BitcoinTransaction?> getTransaction(String txid) async {
    final entity = await _isar.bitcoinTransactionEntitys
        .filter()
        .txidEqualTo(txid)
        .findFirst();

    return entity?.toDomain();
  }

  // ========================================
  // Block Header Storage (SPV)
  // ========================================

  @override
  Future<void> storeBlockHeader(BlockHeader header, int height) async {
    final entity = BlockHeaderEntity.fromBlockHeader(header, height);

    await _isar.writeTxn(() async {
      await _isar.blockHeaderEntitys.put(entity);
    });
  }

  @override
  Future<BlockHeader?> getBlockHeaderByHash(String hash) async {
    final entity = await _isar.blockHeaderEntitys
        .filter()
        .hashEqualTo(hash)
        .and()
        .isOrphanedEqualTo(false)
        .findFirst();

    return entity?.toBlockHeader();
  }

  @override
  Future<BlockHeader?> getBlockHeaderByHeight(int height) async {
    final entity = await _isar.blockHeaderEntitys
        .filter()
        .heightEqualTo(height)
        .and()
        .isOrphanedEqualTo(false)
        .findFirst();

    return entity?.toBlockHeader();
  }

  @override
  Future<int?> getHeightByBlockHash(String hash) async {
    final entity = await _isar.blockHeaderEntitys
        .filter()
        .hashEqualTo(hash)
        .and()
        .isOrphanedEqualTo(false)
        .findFirst();

    return entity?.height;
  }

  @override
  Future<List<BlockHeader>> getBlockHeaderRange(
    int fromHeight,
    int toHeight,
  ) async {
    final entities = await _isar.blockHeaderEntitys
        .filter()
        .heightBetween(fromHeight, toHeight)
        .and()
        .isOrphanedEqualTo(false)
        .sortByHeight()
        .findAll();

    return entities.map((e) => e.toBlockHeader()).toList();
  }

  @override
  Future<void> markHeaderAsOrphaned(String hash) async {
    await _isar.writeTxn(() async {
      final entity = await _isar.blockHeaderEntitys
          .filter()
          .hashEqualTo(hash)
          .findFirst();

      if (entity != null) {
        entity.isOrphaned = true;
        await _isar.blockHeaderEntitys.put(entity);
      }
    });
  }

  @override
  Future<BlockHeader?> getChainTip() async {
    final entity = await _isar.blockHeaderEntitys
        .filter()
        .isOrphanedEqualTo(false)
        .sortByHeightDesc()
        .findFirst();

    return entity?.toBlockHeader();
  }

  @override
  Future<int> getBestHeight() async {
    final entity = await _isar.blockHeaderEntitys
        .filter()
        .isOrphanedEqualTo(false)
        .sortByHeightDesc()
        .findFirst();

    return entity?.height ?? 0;
  }

  @override
  Future<List<BlockHeader>> getRecentHeaders(int count) async {
    final entities = await _isar.blockHeaderEntitys
        .filter()
        .isOrphanedEqualTo(false)
        .sortByHeightDesc()
        .limit(count)
        .findAll();

    return entities.map((e) => e.toBlockHeader()).toList();
  }

  // ========================================
  // Merkle Proof Storage (SPV)
  // ========================================

  @override
  Future<void> storeMerkleProof(String txid, MerkleProof proof) async {
    final entity = MerkleProofEntity.fromMerkleProof(proof);

    await _isar.writeTxn(() async {
      await _isar.merkleProofEntitys.put(entity);
    });
  }

  @override
  Future<MerkleProof?> getMerkleProof(String txid) async {
    final entity = await _isar.merkleProofEntitys
        .filter()
        .txidEqualTo(txid)
        .findFirst();

    return entity?.toMerkleProof();
  }

  @override
  Future<List<MerkleProof>> getMerkleProofsForBlock(String blockHash) async {
    final entities = await _isar.merkleProofEntitys
        .filter()
        .blockHashEqualTo(blockHash)
        .findAll();

    return entities.map((e) => e.toMerkleProof()).toList();
  }

  // ========================================
  // Wallet Management
  // ========================================

  @override
  Future<List<String>> getWalletIds() async {
    // Get unique wallet IDs from UTXOs
    final utxoWallets = await _isar.bitcoinUtxoEntitys
        .where()
        .distinctByWalletId()
        .walletIdProperty()
        .findAll();

    // Get unique wallet IDs from transactions
    final txWallets = await _isar.bitcoinTransactionEntitys
        .where()
        .distinctByWalletId()
        .walletIdProperty()
        .findAll();

    // Combine and deduplicate
    final allWallets = <String>{...utxoWallets, ...txWallets}.toList();
    return allWallets;
  }

  @override
  Future<bool> walletExists(String walletId) async {
    final hasUtxos = await _isar.bitcoinUtxoEntitys
        .filter()
        .walletIdEqualTo(walletId)
        .count();

    if (hasUtxos > 0) return true;

    final hasTransactions = await _isar.bitcoinTransactionEntitys
        .filter()
        .walletIdEqualTo(walletId)
        .count();

    return hasTransactions > 0;
  }

  @override
  Future<void> deleteWallet(String walletId) async {
    await _isar.writeTxn(() async {
      // Delete all UTXOs for this wallet
      await _isar.bitcoinUtxoEntitys
          .filter()
          .walletIdEqualTo(walletId)
          .deleteAll();

      // Delete all transactions for this wallet
      await _isar.bitcoinTransactionEntitys
          .filter()
          .walletIdEqualTo(walletId)
          .deleteAll();

      // Delete wallet metadata if it exists
      await _isar.walletMetadataEntitys
          .filter()
          .walletIdEqualTo(walletId)
          .deleteAll();

      // Delete all invoices for this wallet
      await _isar.invoiceEntitys
          .filter()
          .walletIdEqualTo(walletId)
          .deleteAll();
    });
  }

  // ========================================
  // Invoice Operations
  // ========================================

  @override
  Future<void> storeInvoice(dynamic invoice) async {
    final entity = InvoiceEntity.fromDomain(invoice);
    await _isar.writeTxn(() async {
      await _isar.invoiceEntitys.put(entity);
    });
  }

  @override
  Future<dynamic> getInvoice(String invoiceId) async {
    final entity = await _isar.invoiceEntitys
        .filter()
        .invoiceIdEqualTo(invoiceId)
        .findFirst();
    
    return entity?.toDomain();
  }

  @override
  Future<List<dynamic>> getInvoicesByWallet(String walletId) async {
    final entities = await _isar.invoiceEntitys
        .filter()
        .walletIdEqualTo(walletId)
        .sortByCreatedAtDesc()
        .findAll();
    
    return entities.map((e) => e.toDomain()).toList();
  }

  @override
  Future<List<dynamic>> getInvoicesByStatus(
    dynamic status, {
    String? walletId,
  }) async {
    final statusName = status is String ? status : status.name;
    
    var query = _isar.invoiceEntitys
        .filter()
        .statusEqualTo(statusName);
    
    if (walletId != null) {
      query = query.walletIdEqualTo(walletId);
    }
    
    final entities = await query
        .sortByCreatedAtDesc()
        .findAll();
    
    return entities.map((e) => e.toDomain()).toList();
  }

  @override
  Future<void> updateInvoiceStatus(
    String invoiceId,
    dynamic status, {
    String? txid,
    BigInt? amountReceived,
    DateTime? paidAt,
  }) async {
    await _isar.writeTxn(() async {
      final entity = await _isar.invoiceEntitys
          .filter()
          .invoiceIdEqualTo(invoiceId)
          .findFirst();
      
      if (entity != null) {
        final statusName = status is String ? status : status.name;
        entity.status = statusName;
        
        if (txid != null) {
          entity.paymentTxid = txid;
        }
        if (amountReceived != null) {
          entity.amountReceived = amountReceived.toString();
        }
        if (paidAt != null) {
          entity.paidAt = paidAt;
        }
        
        await _isar.invoiceEntitys.put(entity);
      }
    });
  }

  @override
  Future<int> getMerkleProofCount({String? walletId}) async {
    // Merkle proofs are stored globally, not per-wallet
    // So we ignore the walletId parameter for now
    return await _isar.merkleProofEntitys.count();
  }
}

