import 'dart:async';
import 'dart:convert';
import 'package:isar/isar.dart';
import 'package:spiffynode/spiffy_node.dart';
import '../models/bitcoin_utxo.dart';
import '../models/bitcoin_transaction.dart';
import '../models/address_metadata.dart';
import '../models/transaction_address_link.dart';
import '../models/invoice_read_model.dart';
import '../models/payment_channel.dart';
import '../actors/invoice_messages.dart';
import 'read_model_storage.dart';
import 'libspiffy_schemas.dart';
import 'merkle_proof_rows.dart';
import 'isar_config.dart';
import 'payment_channel_entity.dart';

/// Isar-based implementation of ReadModelStorage.
///
/// This storage implementation provides persistent read-model operations
/// using Isar database.
///
/// **Features:**
/// - Persistent storage using Isar
/// - Index-backed queries (where clauses, native offset/limit)
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
  
  /// Creates the storage on [_isar].
  ///
  /// [config] is ignored: no operation ever ran in an isolate (audit
  /// 2026-09-14 S-21). It is accepted for source compatibility only.
  IsarWalletStorage(
    this._isar, {
    @Deprecated('Ignored: IsarWalletStorage never used isolates. Will be removed.')
    IsolateConfig? config,
  });

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

      // A row soft-deleted by an older version is a deleted wallet: storing
      // it again creates the wallet afresh, reusing the row (audit S-15).
      if (entity == null || entity.isDeleted) {
        final reusedId = entity?.id;
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
        if (reusedId != null) entity.id = reusedId;
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
    
    if (entity == null || entity.isDeleted) return null;

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
    // Newest first. isDeleted only marks rows soft-deleted by older
    // versions; deleteWallet now removes the row.
    return await _isar.walletMetadataEntitys
        .filter()
        .isDeletedEqualTo(false)
        .sortByCreatedAtDesc()
        .walletIdProperty()
        .findAll();
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
        .addressWalletIdEqualTo(address, walletId)
        .count();

    return count > 0;
  }

  @override
  Future<AddressMetadata?> getAddressMetadata(String walletId, String address) async {
    final entity = await _isar.addressEntitys
        .where()
        .addressWalletIdEqualTo(address, walletId)
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
    // The walletId index narrows the scan to this wallet (the former
    // filter() read the whole collection); offset/limit run in Isar.
    final entities = await _isar.addressEntitys
        .where()
        .walletIdEqualTo(walletId)
        .filter()
        .optional(includeUnused == false, (q) => q.usageCountGreaterThan(0))
        .optional(isChange != null, (q) => q.isChangeEqualTo(isChange!))
        .sortByCreatedAtDesc()
        .offset(offset ?? 0)
        .limit(limit ?? _noLimit)
        .findAll();
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
    await _isar.writeTxn(() async {
      // Unique (address, walletId) index: the former filter() scanned the
      // whole collection per call, O(n^2) over an import (audit S-16).
      final existing = await _isar.addressEntitys
          .where()
          .addressWalletIdEqualTo(metadata.address, walletId)
          .findFirst();

      final entity = metadata.toEntity(walletId);
      
      // If exists, preserve the ID for update; otherwise Isar will insert new
      if (existing != null) {
        entity.id = existing.id;
      }
      
      await _isar.addressEntitys.put(entity);
    });
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
          .where()
          .addressWalletIdEqualTo(address, walletId)
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
      await _junctionByTxid(walletId, txid).deleteAll();
      
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
    final txids = await _junctionByAddress(walletId, address)
        .optional(direction != null, (q) => q.directionEqualTo(direction!))
        .sortByCreatedAtDesc()
        .distinctByTxid()
        .offset(offset ?? 0)
        .limit(limit ?? _noLimit)
        .txidProperty()
        .findAll();
    return txids;
  }

  @override
  Future<TransactionAddresses> getTransactionAddresses(
    String walletId,
    String txid,
  ) async {
    final entities = await _junctionByTxid(walletId, txid).findAll();

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
    return await _junctionByAddress(walletId, address).distinctByTxid().count();
  }

  /// Junction rows of ([walletId], [txid]) through the walletIdTxid index.
  /// The concatenated key is ambiguous when ids contain '_', so the exact
  /// fields are filtered as well.
  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity, QAfterFilterCondition>
      _junctionByTxid(String walletId, String txid) => _isar.transactionAddressEntitys
          .where()
          .walletIdTxidEqualToAnyTxid('${walletId}_$txid')
          .filter()
          .walletIdEqualTo(walletId)
          .txidEqualTo(txid);

  /// Junction rows of ([walletId], [address]) through the walletIdAddress
  /// index (see [_junctionByTxid]).
  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity, QAfterFilterCondition>
      _junctionByAddress(String walletId, String address) => _isar.transactionAddressEntitys
          .where()
          .walletIdAddressEqualToAnyAddress('${walletId}_$address')
          .filter()
          .walletIdEqualTo(walletId)
          .addressEqualTo(address);

  /// Isar's limit() takes an int; this stands for "no limit".
  static const _noLimit = 0x7fffffff;

  @override
  Future<void> deleteWallet(String walletId) async {
    await _isar.writeTxn(() async {
      // Hard delete, as every backend (audit S-15). The former soft delete
      // kept the row flagged, so storeWallet could never bring the wallet
      // back into listWallets. A replayed journal converges regardless:
      // WalletDeletedEvent follows WalletCreatedEvent.
      await _isar.walletMetadataEntitys
          .where()
          .walletIdEqualTo(walletId)
          .deleteAll();

      // Delete all addresses for this wallet
      await _isar.addressEntitys
          .where()
          .walletIdEqualTo(walletId)
          .deleteAll();

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

      // Delete all transaction-address links for this wallet
      await _isar.transactionAddressEntitys
          .where()
          .walletIdEqualTo(walletId)
          .deleteAll();

      // Delete all invoices for this wallet
      await _isar.invoiceEntitys
          .where()
          .walletIdEqualTo(walletId)
          .deleteAll();

      // Delete all payment channels for this wallet
      await _isar.paymentChannelEntitys
          .where()
          .walletIdEqualTo(walletId)
          .deleteAll();
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
    // Unspent rows come from the (walletId, status) index: spent rows are
    // not read at all (audit S-16; they used to be loaded and dropped).
    // Newest first (S-19).
    final query = _isar.bitcoinUtxoEntitys.where();
    final entities = await (includeSpent
            ? query.walletIdEqualTo(walletId)
            : query.walletIdEqualToStatusNotEqualTo(walletId, UTXOStatus.spent.name))
        .sortByCreatedAtDesc()
        .findAll();
    return entities.map((e) => e.toDomain()).toList();
  }

  @override
  Future<List<BitcoinUtxo>> getAvailableUTXOs(String walletId) async {
    final entities = await _isar.bitcoinUtxoEntitys
        .where()
        .walletIdStatusEqualTo(walletId, UTXOStatus.available.name)
        .findAll();

    return entities.map((e) => e.toDomain()).toList();
  }

  @override
  Future<List<BitcoinUtxo>> getPaymentUTXOs(String walletId) async {
    final entities = await _isar.bitcoinUtxoEntitys
        .where()
        .walletIdStatusEqualTo(walletId, UTXOStatus.available.name)
        .findAll();

    // Exclude UTXOs managed by token plugins (e.g., PP1/PP2/PP3 outputs).
    // Standard P2PKH outputs may have script-analysis metadata (scriptType,
    // address) but are still valid payment UTXOs — only exclude those with
    // an explicit pluginId from a registered TransactionBuilderPlugin.
    return entities.map((e) => e.toDomain()).where((utxo) {
      final meta = utxo.pluginMetadata;
      if (meta == null) return true;
      return meta['pluginId'] == null;
    }).toList();
  }

  @override
  Future<List<BitcoinUtxo>> getUTXOsByPlugin(
    String walletId,
    String pluginId, {
    Map<String, dynamic>? metadataFilter,
  }) async {
    // Isar doesn't natively filter on JSON map fields, so we filter in memory
    final allUtxos = await getUTXOs(walletId);
    return allUtxos.where((utxo) {
      final meta = utxo.pluginMetadata;
      if (meta == null || meta['pluginId'] != pluginId) return false;
      if (metadataFilter != null) {
        for (final entry in metadataFilter.entries) {
          if (meta[entry.key] != entry.value) return false;
        }
      }
      return true;
    }).toList();
  }

  @override
  Future<BigInt> getBalance(String walletId) async {
    final utxos = await getPaymentUTXOs(walletId);
    return utxos.fold<BigInt>(
      BigInt.zero,
      (sum, utxo) => sum + utxo.satoshis,
    );
  }

  @override
  Future<void> upsertUTXO(String walletId, BitcoinUtxo utxo) async {
    await _isar.writeTxn(() async {
      // Unique (utxoKey, walletId) index.
      final existingEntity = await _utxoRow(walletId, utxo.txid, utxo.vout).findFirst();

      if (existingEntity != null) {
        // createdAt and the first spend time are kept.
        await _isar.bitcoinUtxoEntitys.put(existingEntity..applyDomain(utxo));
      } else {
        await _isar.bitcoinUtxoEntitys
            .put(BitcoinUtxoEntity.fromDomain(utxo, walletId: walletId));
      }
    });
  }

  @override
  Future<void> deleteUTXO(String walletId, String txid, int vout) async {
    await _isar.writeTxn(() async {
      await _utxoRow(walletId, txid, vout).deleteAll();
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterWhereClause> _utxoRow(
          String walletId, String txid, int vout) =>
      _isar.bitcoinUtxoEntitys.where().utxoKeyWalletIdEqualTo('$txid:$vout', walletId);

  // ========================================
  // Transaction History
  // ========================================

  @override
  Future<List<BitcoinTransaction>> getTransactionHistory(
    String walletId, {
    int? limit,
    int? offset,
  }) async {
    // Walks the (walletId, createdAt) index backwards: newest first, with
    // offset/limit applied by Isar. The former query loaded and sorted every
    // row of the wallet, then skipped in Dart (audit S-16).
    final entities = await _isar.bitcoinTransactionEntitys
        .where(sort: Sort.desc)
        .walletIdEqualToAnyCreatedAt(walletId)
        .offset(offset ?? 0)
        .limit(limit ?? _noLimit)
        .findAll();
    return entities.map((e) => e.toDomain()).toList();
  }

  @override
  Future<BitcoinTransaction?> getTransaction(String txid, {String? walletId}) async {
    if (walletId != null) {
      final entity = await _isar.bitcoinTransactionEntitys
          .where()
          .txidWalletIdEqualTo(txid, walletId)
          .findFirst();
      return entity?.toDomain();
    }
    // Without a wallet id: the row of the wallet that stored the txid first.
    final entities = await _isar.bitcoinTransactionEntitys
        .where()
        .txidEqualTo(txid)
        .findAll();
    if (entities.isEmpty) return null;
    return entities.reduce((a, b) => a.id <= b.id ? a : b).toDomain();
  }

  @override
  Future<Map<String, BitcoinTransaction>> getTransactionsBatch(List<String> txids) async {
    if (txids.isEmpty) return {};
    final entities = await _isar.bitcoinTransactionEntitys
        .where()
        .anyOf(txids, (q, txid) => q.txidEqualTo(txid))
        .findAll();
    // A txid held by several wallets maps to the first-stored row.
    final firstByTxid = <String, BitcoinTransactionEntity>{};
    for (final e in entities) {
      final current = firstByTxid[e.txid];
      if (current == null || e.id < current.id) firstByTxid[e.txid] = e;
    }
    return {for (final e in firstByTxid.values) e.txid: e.toDomain()};
  }

  @override
  Future<List<BitcoinTransaction>> getTransactionsByStatus(
    TransactionStatus status, {
    String? walletId,
  }) async {
    final entities = await _isar.bitcoinTransactionEntitys
        .where()
        .statusEqualTo(status.name)
        .filter()
        .optional(walletId != null, (q) => q.walletIdEqualTo(walletId!))
        .sortByCreatedAtDesc()
        .findAll();
    
    return entities.map((e) => e.toDomain()).toList();
  }

  @override
  Future<void> storeTransaction(String walletId, BitcoinTransaction transaction) async {
    await _isar.writeTxn(() async {
      // Check if this wallet already has the transaction. Rows are keyed by
      // (walletId, txid): another wallet's row for the same txid is a
      // different row (audit S-05).
      final existing = await _isar.bitcoinTransactionEntitys
          .where()
          .txidWalletIdEqualTo(transaction.txid, walletId)
          .findFirst();
      
      // One conversion for both paths (audit S-21): createdAt and
      // counterparty are set once, on insert.
      if (existing != null) {
        await _isar.bitcoinTransactionEntitys.put(existing..applyDomain(transaction));
      } else {
        await _isar.bitcoinTransactionEntitys
            .put(BitcoinTransactionEntity.fromDomain(transaction, walletId: walletId));
      }
    });
  }

  // ========================================
  // Block Header Storage (SPV)
  // ========================================

  @override
  Future<void> storeBlockHeader(BlockHeader header, int height) async {
    await storeBlockHeadersBulk([(header, height)]);
  }

  /// Upsert by hash (audit S-12, bead libspiffy-0v3): a stored hash reuses
  /// its Isar id, so re-storing is idempotent instead of violating the
  /// unique hash index, and a header orphaned by an earlier reorganization
  /// is re-activated (orphan flag cleared, height set).
  @override
  Future<void> storeBlockHeadersBulk(List<(BlockHeader, int)> headers) async {
    if (headers.isEmpty) return;
    // Last occurrence wins if a batch repeats a hash.
    final byHash = <String, BlockHeaderEntity>{};
    for (final (header, height) in headers) {
      final entity = BlockHeaderEntity.fromBlockHeader(header, height);
      byHash[entity.hash] = entity;
    }
    final entities = byHash.values.toList();

    await _isar.writeTxn(() async {
      final existing = await _isar.blockHeaderEntitys
          .getAllByHash(entities.map((e) => e.hash).toList());
      for (var i = 0; i < entities.length; i++) {
        final stored = existing[i];
        if (stored != null) entities[i].id = stored.id;
      }
      await _isar.blockHeaderEntitys.putAll(entities);
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
    // Use height index in descending order — avoids loading all 1.7M headers
    // into memory for an in-memory sort (sortByHeightDesc is always in-memory).
    // Instead, traverse the height index from the top and filter in-memory.
    // Walk the height index from the top and take the first header that is
    // not orphaned. After a reorg the orphaned and replacement headers share
    // a height, and a lookup by height alone returned whichever was stored
    // first (the orphan).
    final entity = await _isar.blockHeaderEntitys
        .where(sort: Sort.desc)
        .anyHeight()
        .filter()
        .isOrphanedEqualTo(false)
        .findFirst();

    return entity?.toBlockHeader();
  }

  @override
  Future<int> getBestHeight() async {
    final entity = await _isar.blockHeaderEntitys
        .where(sort: Sort.desc)
        .anyHeight()
        .filter()
        .isOrphanedEqualTo(false)
        .findFirst();

    return entity?.height ?? 0;
  }

  @override
  Future<List<BlockHeader>> getRecentHeaders(int count) async {
    final entities = await _isar.blockHeaderEntitys
        .where(sort: Sort.desc)
        .heightGreaterThan(-1)
        .filter()
        .isOrphanedEqualTo(false)
        .limit(count)
        .findAll();

    return entities.map((e) => e.toBlockHeader()).toList();
  }

  // ========================================
  // Merkle Proof Storage (SPV)
  // ========================================

  /// Rows are only added or updated, in one write transaction (bead mny);
  /// see [ReadModelStorage.storeMerkleProof] and `planMerkleProofStore`.
  @override
  Future<void> storeMerkleProof(String txid, MerkleProof proof) async {
    await _isar.writeTxn(() async {
      final entities = await _merkleProofRows(txid);
      final plan = planMerkleProofStore(
          [for (final e in entities) e.toMerkleProof()], txid, proof);
      final puts = <MerkleProofEntity>[];
      for (final i in plan.orphan) {
        puts.add(entities[i]
          ..setFrom(entities[i].toMerkleProof().copyWith(
              status: MerkleProofStatus.orphaned, statusChangedAt: plan.orphanedAt)));
      }
      final target = plan.target;
      puts.add(target == null
          ? MerkleProofEntity.fromMerkleProof(plan.row)
          : (entities[target]..setFrom(plan.row)));
      await _isar.merkleProofEntitys.putAll(puts);
    });
  }

  @override
  Future<bool> markMerkleProofOrphaned(
    String txid, {
    String? blockHash,
    List<String>? onlyIfMerkleProof,
    DateTime? at,
  }) async {
    return _isar.writeTxn(() async {
      final entities = await _merkleProofRows(txid);
      final i = findMerkleProofToOrphan([for (final e in entities) e.toMerkleProof()],
          blockHash: blockHash, onlyIfMerkleProof: onlyIfMerkleProof);
      if (i == null) return false;
      await _isar.merkleProofEntitys.put(entities[i]
        ..setFrom(entities[i].toMerkleProof().copyWith(
            status: MerkleProofStatus.orphaned, statusChangedAt: at ?? DateTime.now())));
      return true;
    });
  }

  /// Every row of [txid], oldest first.
  Future<List<MerkleProofEntity>> _merkleProofRows(String txid) async {
    final entities = await _isar.merkleProofEntitys.where().txidEqualTo(txid).findAll();
    return entities..sort((a, b) => a.id.compareTo(b.id));
  }

  @override
  Future<MerkleProof?> getMerkleProof(String txid) async {
    // Newest current row, should a pre-S-13 store still hold duplicates.
    return currentMerkleProof([for (final e in await _merkleProofRows(txid)) e.toMerkleProof()]);
  }

  @override
  Future<Map<String, MerkleProof>> getMerkleProofsBatch(List<String> txids) async {
    if (txids.isEmpty) return {};
    final entities = await _isar.merkleProofEntitys
        .where()
        .anyOf(txids, (q, txid) => q.txidEqualTo(txid))
        .findAll();
    entities.sort((a, b) => a.id.compareTo(b.id));
    final current = <String, MerkleProof>{};
    for (final e in entities) {
      final proof = e.toMerkleProof();
      if (proof.isCurrent) current[e.txid] = proof;
    }
    return current;
  }

  @override
  Future<List<MerkleProof>> getMerkleProofHistory(String txid) async {
    return [for (final e in await _merkleProofRows(txid)) e.toMerkleProof()];
  }

  @override
  Future<List<MerkleProof>> getMerkleProofsByStatus(MerkleProofStatus status) async {
    final entities = await _isar.merkleProofEntitys.where().statusEqualTo(status.name).findAll();
    // Rows written before bead mny have no status (see MerkleProofEntity).
    if (status == MerkleProofStatus.pendingHeader) {
      entities.addAll(await _isar.merkleProofEntitys
          .where()
          .blockHashEqualTo(MerkleProof.legacyPendingBlockHash)
          .filter()
          .statusIsNull()
          .findAll());
    } else if (status == MerkleProofStatus.verified) {
      entities.addAll(await _isar.merkleProofEntitys
          .where()
          .statusIsNull()
          .filter()
          .not()
          .blockHashEqualTo(MerkleProof.legacyPendingBlockHash)
          .findAll());
    }
    entities.sort((a, b) => a.id.compareTo(b.id));
    return [for (final e in entities) e.toMerkleProof()];
  }

  @override
  Future<List<MerkleProof>> getMerkleProofsForBlock(String blockHash) async {
    final entities = await _isar.merkleProofEntitys
        .where()
        .blockHashEqualTo(blockHash)
        .findAll();

    return [
      for (final e in entities)
        if (e.toMerkleProof() case final proof when proof.isCurrent) proof,
    ];
  }

  // ========================================
  // Wallet Management
  // ========================================

  /// The same wallets, in the same order, as [listWallets] (formerly the
  /// wallet ids found on UTXO and transaction rows, audit S-15).
  @override
  Future<List<String>> getWalletIds() => listWallets();

  /// A wallet exists when its metadata row does (audit S-15).
  @override
  Future<bool> walletExists(String walletId) async {
    final count = await _isar.walletMetadataEntitys
        .where()
        .walletIdEqualTo(walletId)
        .filter()
        .isDeletedEqualTo(false)
        .count();
    return count > 0;
  }

  // ========================================
  // Invoice Operations
  // ========================================

  @override
  Future<void> storeInvoice(InvoiceReadModel invoice) async {
    final entity = InvoiceEntity.fromDomain(invoice);
    await _isar.writeTxn(() async {
      // Upsert: reuse the Isar id of an existing row with this invoiceId.
      final existing = await _isar.invoiceEntitys
          .where()
          .invoiceIdEqualTo(invoice.invoiceId)
          .findFirst();
      if (existing != null) {
        entity.id = existing.id;
      }
      await _isar.invoiceEntitys.put(entity);
    });
  }

  @override
  Future<InvoiceReadModel?> getInvoice(String invoiceId) async {
    final entity = await _isar.invoiceEntitys
        .where()
        .invoiceIdEqualTo(invoiceId)
        .findFirst();

    return entity?.toDomain();
  }

  @override
  Future<List<InvoiceReadModel>> listInvoices({
    String? walletId,
    InvoiceStatus? status,
  }) async {
    final entities = await _isar.invoiceEntitys
        .filter()
        .optional(walletId != null, (q) => q.walletIdEqualTo(walletId!))
        .optional(status != null, (q) => q.statusEqualTo(status!.name))
        .sortByCreatedAtDesc()
        .findAll();

    return entities.map((e) => e.toDomain()).toList();
  }

  @override
  Future<List<InvoiceReadModel>> getInvoicesByWallet(String walletId) =>
      listInvoices(walletId: walletId);

  @override
  Future<List<InvoiceReadModel>> getInvoicesByStatus(
    InvoiceStatus status, {
    String? walletId,
  }) =>
      listInvoices(walletId: walletId, status: status);

  @override
  Future<void> updateInvoiceStatus(
    String invoiceId,
    InvoiceStatus status, {
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
        entity.status = status.name;

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
  //
  // The Isar PaymentChannelEntity is an implementation detail of this
  // backend: callers pass and receive the domain PaymentChannel (audit S-01).

  @override
  Future<void> storePaymentChannel(PaymentChannel channel) async {
    await _isar.writeTxn(() async {
      final entity = PaymentChannelEntity.fromPaymentChannel(channel);

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
  Future<PaymentChannel?> getPaymentChannel(String channelId) async {
    final entity = await _isar.paymentChannelEntitys
        .where()
        .channelIdEqualTo(channelId)
        .findFirst();
    return entity?.toPaymentChannel();
  }

  @override
  Future<List<PaymentChannel>> getPaymentChannelsForWallet(String walletId) async {
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
      return '{}';
    }
  }

  Map<String, dynamic> _decodeJson(String jsonString) {
    try {
      if (jsonString.isEmpty) return {};
      return jsonDecode(jsonString) as Map<String, dynamic>;
    } catch (e) {
      return {};
    }
  }
}

