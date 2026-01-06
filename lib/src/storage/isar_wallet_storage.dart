import 'dart:async';
import 'dart:convert';
import 'package:isar/isar.dart';
import 'package:spiffynode/spiffy_node.dart';
import '../models/bitcoin_utxo.dart';
import '../models/bitcoin_transaction.dart';
import '../models/address_metadata.dart';
import '../models/transaction_address_link.dart';
import '../actors/invoice_messages.dart';
import 'read_model_storage.dart';
import 'libspiffy_schemas.dart';
import 'isar_config.dart';
import 'payment_channel_entity.dart';

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
  
  /// Expose Isar instance for ProjectionManager to handle automatic checkpoint persistence
  Isar get isar => _isar;
  
  // ignore: unused_field
  final IsolateConfig _config;

  IsarWalletStorage(this._isar, {IsolateConfig? config})
      : _config = config ?? IsolateConfig.defaultConfig();

  // ========================================
  // Wallet Metadata
  // ========================================
  
  @override
  Future<void> storeWallet(
    String walletId,
    String name, {
    String? rootAddress,
    String? networkType,
    Map<String, dynamic>? metadata,
  }) async {
    await _isar.writeTxn(() async {
      var entity = await _isar.walletMetadataEntitys
          .where()
          .walletIdEqualTo(walletId)
          .findFirst();
      
      if (entity == null) {
        entity = WalletMetadataEntity()
          ..walletId = walletId
          ..name = name
          ..walletType = metadata?['walletType'] as String? ?? 'hd'
          ..network = networkType ?? 'mainnet'
          ..rootAddress = rootAddress
          ..derivationIndex = metadata?['derivationIndex'] as int? ?? 0
          ..isCreated = true
          ..createdAt = DateTime.now()
          ..lastAccessedAt = DateTime.now()
          ..metadataJson = _encodeJson(metadata ?? {})
          ..aggregateVersion = metadata?['aggregateVersion'] as int? ?? 0
          ..confirmedBalance = metadata?['confirmedBalance'] as String? ?? '0'
          ..unconfirmedBalance = metadata?['unconfirmedBalance'] as String? ?? '0'
          ..addressesJson = metadata?['addressesJson'] as String? ?? ''
          ..publicKeysJson = metadata?['publicKeysJson'] as String? ?? '';
      } else {
        entity.name = name;
        entity.network = networkType ?? entity.network;
        if (rootAddress != null) entity.rootAddress = rootAddress;
        entity.lastAccessedAt = DateTime.now();
        
        // Update balances and metadata if provided
        if (metadata != null) {
          // Update balance fields
          if (metadata.containsKey('confirmedBalance')) {
            entity.confirmedBalance = metadata['confirmedBalance'] as String;
          }
          if (metadata.containsKey('unconfirmedBalance')) {
            entity.unconfirmedBalance = metadata['unconfirmedBalance'] as String;
          }
          
          // Merge new metadata with existing metadata
          final existingMeta = _decodeJson(entity.metadataJson);
          existingMeta.addAll(metadata);
          entity.metadataJson = _encodeJson(existingMeta);
        }
      }
      
      await _isar.walletMetadataEntitys.put(entity);
    });
  }
  
  @override
  Future<Map<String, dynamic>?> getWallet(String walletId) async {
    final entity = await _isar.walletMetadataEntitys
        .where()
        .walletIdEqualTo(walletId)
        .findFirst();
    
    if (entity == null) return null;
    
    return {
      'walletId': entity.walletId,
      'name': entity.name,
      'walletType': entity.walletType,
      'network': entity.network,
      'rootAddress': entity.rootAddress,
      'derivationIndex': entity.derivationIndex,
      'isCreated': entity.isCreated,
      'createdAt': entity.createdAt.toIso8601String(),
      'lastAccessedAt': entity.lastAccessedAt.toIso8601String(),
      'confirmedBalance': entity.confirmedBalance,
      'unconfirmedBalance': entity.unconfirmedBalance,
      'metadata': _decodeJson(entity.metadataJson),
    };
  }
  
  @override
  Future<List<String>> listWallets() async {
    final entities = await _isar.walletMetadataEntitys
        .where()
        .sortByCreatedAtDesc()
        .findAll();
    
    return entities.map((e) => e.walletId).toList();
  }
  
  @override
  Future<List<String>> getWalletAddresses(String walletId) async {
    final addresses = await _isar.addressEntitys
        .where()
        .walletIdEqualTo(walletId)
        .addressProperty()
        .findAll();
    return addresses;
  }

  // ========================================
  // Address Management
  // ========================================

  @override
  Future<bool> isWalletAddress(String walletId, String address) async {
    final count = await _isar.addressEntitys
        .where()
        .addressEqualTo(address)
        .filter()
        .walletIdEqualTo(walletId)
        .count();
    
    // Debug logging for address lookup
    if (count == 0) {
      // Check how many addresses exist for this wallet
      final totalAddresses = await _isar.addressEntitys
          .where()
          .walletIdEqualTo(walletId)
          .count();
      print('[IsarWalletStorage] Address lookup: $address NOT found (wallet has $totalAddresses addresses)');
    } else {
      print('[IsarWalletStorage] Address lookup: $address FOUND in wallet');
    }
    
    return count > 0;
  }

  @override
  Future<AddressMetadata?> getAddressMetadata(String walletId, String address) async {
    final entity = await _isar.addressEntitys
        .where()
        .addressEqualTo(address)
        .filter()
        .walletIdEqualTo(walletId)
        .findFirst();
    
    return entity != null ? AddressMetadata.fromEntity(entity) : null;
  }

  @override
  Future<Map<String, bool>> checkAddresses(String walletId, List<String> addresses) async {
    final result = <String, bool>{};
    
    // Batch query using 'in' filter
    final foundAddresses = await _isar.addressEntitys
        .where()
        .anyOf(addresses, (q, address) => q.addressEqualTo(address))
        .filter()
        .walletIdEqualTo(walletId)
        .addressProperty()
        .findAll();
    
    final foundSet = foundAddresses.toSet();
    for (final address in addresses) {
      result[address] = foundSet.contains(address);
    }
    
    return result;
  }

  @override
  Future<List<AddressMetadata>> getAddressesWithMetadata(
    String walletId, {
    bool? includeUnused,
    bool? isChange,
    int? limit,
    int? offset,
  }) async {
    var query = _isar.addressEntitys
        .filter()
        .walletIdEqualTo(walletId);
    
    if (includeUnused == false) {
      query = query.usageCountGreaterThan(0);
    }
    
    if (isChange != null) {
      query = query.isChangeEqualTo(isChange);
    }
    
    var orderedQuery = query.sortByCreatedAtDesc();
    
    if (offset != null && limit != null) {
      final entities = await orderedQuery.offset(offset).limit(limit).findAll();
      return entities.map((e) => AddressMetadata.fromEntity(e)).toList();
    } else if (offset != null) {
      final entities = await orderedQuery.offset(offset).findAll();
      return entities.map((e) => AddressMetadata.fromEntity(e)).toList();
    } else if (limit != null) {
      final entities = await orderedQuery.limit(limit).findAll();
      return entities.map((e) => AddressMetadata.fromEntity(e)).toList();
    }
    
    final entities = await orderedQuery.findAll();
    return entities.map((e) => AddressMetadata.fromEntity(e)).toList();
  }

  @override
  Future<List<AddressMetadata>> getAddressRange(
    String walletId, {
    required int startIndex,
    required int count,
    bool isChange = false,
  }) async {
    final entities = await _isar.addressEntitys
        .where()
        .walletIdEqualTo(walletId)
        .filter()
        .isChangeEqualTo(isChange)
        .and()
        .derivationIndexBetween(startIndex, startIndex + count - 1)
        .sortByDerivationIndex()
        .findAll();
    
    return entities.map((e) => AddressMetadata.fromEntity(e)).toList();
  }

  @override
  Future<void> upsertAddress(String walletId, AddressMetadata metadata) async {
    print('[IsarWalletStorage] 💾 Upserting address: ${metadata.address} for wallet $walletId');
    await _isar.writeTxn(() async {
      // Find existing entity by address (unique index)
      final existing = await _isar.addressEntitys
          .filter()
          .addressEqualTo(metadata.address)
          .and()
          .walletIdEqualTo(walletId)
          .findFirst();
      
      final entity = metadata.toEntity(walletId);
      
      // If exists, preserve the ID for update; otherwise Isar will insert new
      if (existing != null) {
        entity.id = existing.id;
      }
      
      await _isar.addressEntitys.put(entity);
    });
    print('[IsarWalletStorage]    ✅ Address persisted to Isar');
  }
  
  @override
  Future<int> getAddressCount(String walletId) async {
    return await _isar.addressEntitys
        .where()
        .walletIdEqualTo(walletId)
        .count();
  }

  @override
  Future<void> updateAddressUsage(
    String walletId,
    String address, {
    DateTime? usedAt,
    BigInt? balanceDelta,
  }) async {
    await _isar.writeTxn(() async {
      final entity = await _isar.addressEntitys
          .filter()
          .addressEqualTo(address)
          .and()
          .walletIdEqualTo(walletId)
          .findFirst();
      
      if (entity == null) return;
      
      if (usedAt != null) {
        entity.firstUsedAt ??= usedAt;
        entity.lastUsedAt = usedAt;
        entity.usageCount++;
      }
      
      if (balanceDelta != null) {
        final currentBalance = BigInt.parse(entity.balance);
        entity.balance = (currentBalance + balanceDelta).toString();
      }
      
      await _isar.addressEntitys.put(entity);
    });
  }

  // ========================================
  // Transaction-Address Junction
  // ========================================

  @override
  Future<void> storeTransactionAddresses(
    String walletId,
    String txid,
    List<TransactionAddressLink> links,
  ) async {
    await _isar.writeTxn(() async {
      // Delete existing records for this transaction
      await _isar.transactionAddressEntitys
          .where()
          .txidEqualTo(txid)
          .filter()
          .walletIdEqualTo(walletId)
          .deleteAll();
      
      // Insert new records
      final entities = links.map((link) {
        return TransactionAddressEntity()
          ..walletId = walletId
          ..txid = txid
          ..address = link.address
          ..direction = link.direction
          ..amount = link.amount.toString()
          ..vout = link.vout
          ..vin = link.vin
          ..createdAt = DateTime.now()
          ..walletIdAddress = '${walletId}_${link.address}'
          ..walletIdTxid = '${walletId}_$txid';
      }).toList();
      
      await _isar.transactionAddressEntitys.putAll(entities);
    });
  }

  @override
  Future<List<String>> getTransactionsByAddress(
    String walletId,
    String address, {
    String? direction,
    int? limit,
    int? offset,
  }) async {
    var query = _isar.transactionAddressEntitys
        .where()
        .addressEqualTo(address)
        .filter()
        .walletIdEqualTo(walletId);

    if (direction != null) {
      query = query.directionEqualTo(direction);
    }
    
    var orderedQuery = query
        .sortByCreatedAtDesc()
        .distinctByTxid();
    
    if (offset != null && limit != null) {
      final entities = await orderedQuery.offset(offset).limit(limit).findAll();
      return entities.map((e) => e.txid).toList();
    } else if (offset != null) {
      final entities = await orderedQuery.offset(offset).findAll();
      return entities.map((e) => e.txid).toList();
    } else if (limit != null) {
      final entities = await orderedQuery.limit(limit).findAll();
      return entities.map((e) => e.txid).toList();
    }
    
    final entities = await orderedQuery.findAll();
    return entities.map((e) => e.txid).toList();
  }

  @override
  Future<TransactionAddresses> getTransactionAddresses(
    String walletId,
    String txid,
  ) async {
    final entities = await _isar.transactionAddressEntitys
        .where()
        .walletIdEqualTo(walletId)
        .filter()
        .txidEqualTo(txid)
        .findAll();
    
    final inputs = entities
        .where((e) => e.direction == 'input')
        .map((e) => TransactionAddressLink(
              address: e.address,
              direction: e.direction,
              amount: BigInt.parse(e.amount),
              vin: e.vin,
            ))
        .toList();
    
    final outputs = entities
        .where((e) => e.direction == 'output')
        .map((e) => TransactionAddressLink(
              address: e.address,
              direction: e.direction,
              amount: BigInt.parse(e.amount),
              vout: e.vout,
            ))
        .toList();
    
    return TransactionAddresses(inputs: inputs, outputs: outputs);
  }

  @override
  Future<int> getAddressTransactionCount(String walletId, String address) async {
    return await _isar.transactionAddressEntitys
        .where()
        .walletIdEqualTo(walletId)
        .filter()
        .addressEqualTo(address)
        .distinctByTxid()
        .count();
  }
  
  @override
  Future<void> deleteWallet(String walletId) async {
    await _isar.writeTxn(() async {
      // Delete all UTXOs for this wallet
      await _isar.bitcoinUtxoEntitys
          .where()
          .walletIdEqualTo(walletId)
          .deleteAll();
      
      // Delete all transactions for this wallet
      await _isar.bitcoinTransactionEntitys
          .where()
          .walletIdEqualTo(walletId)
          .deleteAll();
      
      // Delete all invoices for this wallet
      await _isar.invoiceEntitys
          .where()
          .walletIdEqualTo(walletId)
          .deleteAll();
          
      // Note: Events are managed by Eventador's EventStore, not deleted here
    });
  }

  // ========================================
  // UTXO Queries
  // ========================================

  @override
  Future<List<BitcoinUtxo>> getUTXOs(
    String walletId, {
    bool includeSpent = false,
  }) async {
    final allEntities = await _isar.bitcoinUtxoEntitys
        .where()
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
        .where()
        .walletIdEqualTo(walletId)
        .filter()
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

  @override
  Future<void> upsertUTXO(String walletId, BitcoinUtxo utxo) async {
    await _isar.writeTxn(() async {
      // Check if UTXO already exists
      final existingEntity = await _isar.bitcoinUtxoEntitys
          .where()
          .walletIdEqualTo(walletId)
          .filter()
          .txidEqualTo(utxo.txid)
          .and()
          .voutEqualTo(utxo.vout)
          .findFirst();
      
      if (existingEntity != null) {
        // Update existing
        print('[IsarWalletStorage] Updating existing UTXO ${utxo.txid.substring(0,8)}:${utxo.vout} - status: ${utxo.status.name}');
        if (existingEntity.status == 'spent' && utxo.status != UTXOStatus.spent) {
          print('[IsarWalletStorage]   ⚠️  WARNING: Overwriting SPENT status with ${utxo.status.name}!');
          print('[IsarWalletStorage]   Stack trace: ${StackTrace.current}');
        }
        existingEntity
          ..satoshis = utxo.satoshis.toString()
          ..scriptPubKey = utxo.scriptPubKey
          ..address = utxo.address
          ..blockHeight = utxo.blockHeight
          ..confirmations = utxo.confirmations ?? 0
          ..status = utxo.status.name
          ..isSpendable = utxo.status == UTXOStatus.available;
        
        if (utxo.status == UTXOStatus.spent) {
          existingEntity.spentAt = utxo.updatedAt;
        }
        
        await _isar.bitcoinUtxoEntitys.put(existingEntity);
        print('[IsarWalletStorage]   ✅ UTXO updated in Isar with status: ${utxo.status.name}');
      } else {
        // Insert new
        final entity = BitcoinUtxoEntity.fromDomain(utxo);
        entity.walletId = walletId; // Set the walletId
        await _isar.bitcoinUtxoEntitys.put(entity);
      }
    });
  }

  @override
  Future<void> deleteUTXO(String walletId, String txid, int vout) async {
    await _isar.writeTxn(() async {
      await _isar.bitcoinUtxoEntitys
          .where()
          .walletIdEqualTo(walletId)
          .filter()
          .txidEqualTo(txid)
          .and()
          .voutEqualTo(vout)
          .deleteAll();
    });
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
        .where()
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
        .where()
        .txidEqualTo(txid)
        .findFirst();

    return entity?.toDomain();
  }

  @override
  Future<List<BitcoinTransaction>> getTransactionsByStatus(
    TransactionStatus status, {
    String? walletId,
  }) async {
    var query = _isar.bitcoinTransactionEntitys
        .filter()
        .statusEqualTo(status.name);
    
    if (walletId != null) {
      query = query.walletIdEqualTo(walletId);
    }
    
    final entities = await query
        .sortByCreatedAtDesc()
        .findAll();
    
    return entities.map((e) => e.toDomain()).toList();
  }

  @override
  Future<void> storeTransaction(String walletId, BitcoinTransaction transaction) async {
    await _isar.writeTxn(() async {
      // Check if transaction already exists
      final existing = await _isar.bitcoinTransactionEntitys
          .where()
          .txidEqualTo(transaction.txid)
          .findFirst();
      
      if (existing != null) {
        // Update existing transaction
        existing
          ..rawHex = transaction.rawHex
          ..status = transaction.status.name
          ..blockHeight = transaction.blockHeight
          ..confirmations = transaction.confirmations ?? 0
          ..totalInput = transaction.inputValue.toString()
          ..totalOutput = transaction.outputValue.toString()
          ..fee = transaction.fee.toString()
          ..netAmount = transaction.netAmount.toString()
          ..isIncoming = transaction.netAmount > BigInt.zero
          ..isOutgoing = transaction.netAmount < BigInt.zero
          ..receivingAddressesJson = jsonEncode(transaction.receivingAddresses)
          ..sendingAddressesJson = jsonEncode(transaction.sendingAddresses)
          ..primaryCounterparty = _getPrimaryCounterparty(transaction)
          ..notes = transaction.memo;
        
        if (transaction.blockHeight != null && transaction.blockHeight! > 0) {
          existing.confirmedAt = transaction.updatedAt;
        }
        
        await _isar.bitcoinTransactionEntitys.put(existing);
        return;
      } else {
        // Insert new transaction
        final entity = BitcoinTransactionEntity()
          ..walletId = walletId
          ..txid = transaction.txid
          ..rawHex = transaction.rawHex
          ..blockHeight = transaction.blockHeight
          ..blockHash = null // Not available in BitcoinTransaction
          ..confirmations = transaction.confirmations ?? 0
          ..totalInput = transaction.inputValue.toString()
          ..totalOutput = transaction.outputValue.toString()
          ..fee = transaction.fee.toString()
          ..netAmount = transaction.netAmount.toString()
          ..isIncoming = transaction.netAmount > BigInt.zero
          ..isOutgoing = transaction.netAmount < BigInt.zero
          ..status = transaction.status.name
          ..createdAt = transaction.createdAt
          ..confirmedAt = (transaction.blockHeight != null && transaction.blockHeight! > 0) 
              ? transaction.updatedAt 
              : null
          ..broadcastAt = null // Not available in BitcoinTransaction
          ..receivingAddressesJson = jsonEncode(transaction.receivingAddresses)
          ..sendingAddressesJson = jsonEncode(transaction.sendingAddresses)
          ..primaryCounterparty = _getPrimaryCounterparty(transaction)
          ..counterparty = _getPrimaryCounterparty(transaction)
          ..notes = transaction.memo;
        
        await _isar.bitcoinTransactionEntitys.put(entity);
      }
    });
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
        .where()
        .hashEqualTo(hash)
        .filter()
        .isOrphanedEqualTo(false)
        .findFirst();

    return entity?.toBlockHeader();
  }

  @override
  Future<BlockHeader?> getBlockHeaderByHeight(int height) async {
    final entity = await _isar.blockHeaderEntitys
        .where()
        .heightEqualTo(height)
        .filter()
        .isOrphanedEqualTo(false)
        .findFirst();

    return entity?.toBlockHeader();
  }

  @override
  Future<int?> getHeightByBlockHash(String hash) async {
    final entity = await _isar.blockHeaderEntitys
        .where()
        .hashEqualTo(hash)
        .filter()
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
        .where()
        .heightBetween(fromHeight, toHeight)
        .filter()
        .isOrphanedEqualTo(false)
        .sortByHeight()
        .findAll();

    return entities.map((e) => e.toBlockHeader()).toList();
  }

  @override
  Future<void> markHeaderAsOrphaned(String hash) async {
    await _isar.writeTxn(() async {
      final entity = await _isar.blockHeaderEntitys
          .where()
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
        .where()
        .isOrphanedEqualTo(false)
        .sortByHeightDesc()
        .findFirst();

    return entity?.toBlockHeader();
  }

  @override
  Future<int> getBestHeight() async {
    final entity = await _isar.blockHeaderEntitys
        .where()
        .isOrphanedEqualTo(false)
        .sortByHeightDesc()
        .findFirst();

    return entity?.height ?? 0;
  }

  @override
  Future<List<BlockHeader>> getRecentHeaders(int count) async {
    final entities = await _isar.blockHeaderEntitys
        .where()
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
        .where()
        .txidEqualTo(txid)
        .findFirst();

    return entity?.toMerkleProof();
  }

  @override
  Future<List<MerkleProof>> getMerkleProofsForBlock(String blockHash) async {
    final entities = await _isar.merkleProofEntitys
        .where()
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
        .where()
        .walletIdEqualTo(walletId)
        .count();

    if (hasUtxos > 0) return true;

    final hasTransactions = await _isar.bitcoinTransactionEntitys
        .where()
        .walletIdEqualTo(walletId)
        .count();

    return hasTransactions > 0;
  }

  // ========================================
  // Helper Methods
  // ========================================

  String? _getPrimaryCounterparty(BitcoinTransaction tx) {
    final netAmount = tx.netAmount;
    if (netAmount > BigInt.zero) {
      return tx.sendingAddresses.isNotEmpty ? tx.sendingAddresses.first : null;
    } else if (netAmount < BigInt.zero) {
      return tx.receivingAddresses.isNotEmpty ? tx.receivingAddresses.first : null;
    }
    return null;
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
        .where()
        .invoiceIdEqualTo(invoiceId)
        .findFirst();
    
    return entity?.toDomain();
  }

  @override
  Future<List<dynamic>> getInvoicesByWallet(String walletId) async {
    final entities = await _isar.invoiceEntitys
        .where()
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
    final statusName = status is String ? status : (status as InvoiceStatus).toString().split('.').last;
    
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
          .where()
          .invoiceIdEqualTo(invoiceId)
          .findFirst();
      
      if (entity != null) {
        final statusName = status is String ? status : (status as InvoiceStatus).toString().split('.').last;
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

  // ========================================
  // Payment Channel Storage
  // ========================================

  @override
  Future<void> storePaymentChannel(dynamic channel) async {
    await _isar.writeTxn(() async {
      PaymentChannelEntity entity;
      
      // Support both PaymentChannelEntity (projection) and PaymentChannel (old code)
      if (channel is PaymentChannelEntity) {
        entity = channel;
      } else {
        entity = PaymentChannelEntity.fromPaymentChannel(channel);
      }
      
      // Check if channel already exists (upsert)
      final existing = await _isar.paymentChannelEntitys
          .where()
          .channelIdEqualTo(entity.channelId)
          .findFirst();
      
      // If exists, keep the same Isar ID for update
      if (existing != null) {
        entity.id = existing.id;
      }
      
      await _isar.paymentChannelEntitys.put(entity);
    });
  }

  @override
  Future<dynamic> getPaymentChannel(String channelId) async {
    final entity = await _isar.paymentChannelEntitys
        .where()
        .channelIdEqualTo(channelId)
        .findFirst();
    // Return entity directly for projection, can be converted to PaymentChannel if needed
    return entity;
  }

  @override
  Future<List<dynamic>> getPaymentChannelsForWallet(String walletId) async {
    final entities = await _isar.paymentChannelEntitys
        .where()
        .walletIdEqualTo(walletId)
        .findAll();
    return entities.map((e) => e.toPaymentChannel()).toList();
  }

  @override
  Future<void> updatePaymentChannelState(String channelId, String state) async {
    await _isar.writeTxn(() async {
      final entity = await _isar.paymentChannelEntitys
          .where()
          .channelIdEqualTo(channelId)
          .findFirst();
      if (entity != null) {
        entity.state = state;
        await _isar.paymentChannelEntitys.put(entity);
      }
    });
  }

  @override
  Future<void> updatePaymentChannelBalance(
    String channelId,
    BigInt clientBalance,
    BigInt serverBalance,
  ) async {
    await _isar.writeTxn(() async {
      final entity = await _isar.paymentChannelEntitys
          .where()
          .channelIdEqualTo(channelId)
          .findFirst();
      if (entity != null) {
        entity.clientBalanceSats = clientBalance.toString();
        entity.serverBalanceSats = serverBalance.toString();
        await _isar.paymentChannelEntitys.put(entity);
      }
    });
  }

  @override
  Future<void> deletePaymentChannel(String channelId) async {
    await _isar.writeTxn(() async {
      final entity = await _isar.paymentChannelEntitys
          .where()
          .channelIdEqualTo(channelId)
          .findFirst();
      if (entity != null) {
        await _isar.paymentChannelEntitys.delete(entity.id);
      }
    });
  }

  // ========================================
  // Helper Methods
  // ========================================

  String _encodeJson(Map<String, dynamic> data) {
    try {
      return jsonEncode(data);
    } catch (e) {
      print('Error encoding JSON: $e');
      return '{}';
    }
  }

  Map<String, dynamic> _decodeJson(String jsonString) {
    try {
      if (jsonString.isEmpty) return {};
      return jsonDecode(jsonString) as Map<String, dynamic>;
    } catch (e) {
      print('Error decoding JSON: $e');
      return {};
    }
  }
}

