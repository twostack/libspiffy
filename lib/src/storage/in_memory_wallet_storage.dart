import 'dart:async';
import 'dart:collection';
import 'package:collection/collection.dart' show mergeSort;
import 'package:meta/meta.dart' show visibleForTesting;
import 'package:spiffynode/spiffy_node.dart';
import '../models/wallet_event.dart';
import '../models/bitcoin_utxo.dart';
import '../models/bitcoin_transaction.dart';
import '../models/address_metadata.dart';
import '../models/transaction_address_link.dart';
import '../models/invoice_read_model.dart';
import '../models/payment_channel.dart';
import '../models/deferred_payment.dart';
import '../actors/invoice_messages.dart';
import '../services/watch_only_funds.dart' show splitBalanceUtxos;
import 'wallet_storage.dart';
import 'merkle_proof_rows.dart';
import 'transaction_row_rules.dart';
import 'wallet_row_rules.dart';

/// In-memory implementation of WalletStorage for development and testing.
/// 
/// This implementation stores all data in memory using Maps and Lists.
/// Data is lost when the application restarts. This should only be used
/// for development, testing, and demo purposes.
/// 
/// Features:
/// - Thread-safe operations with proper synchronization
/// - UTXO indexing for efficient queries
/// - Balance caching with invalidation
/// - Event ordering preservation
/// - Memory usage tracking
class InMemoryWalletStorage implements WalletStorage {
  // Event storage: walletId -> List of events
  final Map<String, List<WalletEvent>> _events = {};
  
  // UTXO storage: walletId -> Map<utxoKey, BitcoinUtxo>
  final Map<String, Map<String, BitcoinUtxo>> _utxos = {};
  
  // Transaction storage: walletId -> (txid -> BitcoinTransaction), in the
  // order the wallet first stored each txid. Keyed per wallet: wallet A
  // paying wallet B in the same store gives each its own row (audit S-05).
  final Map<String, Map<String, BitcoinTransaction>> _transactions = {};

  // Wallets holding a row for a txid, in the order they first stored it
  // (getTransaction without a wallet id returns the first).
  final Map<String, List<String>> _txidWallets = {};

  // Confirmed rows by block height, as (walletId, txid) keys, and confirmed
  // rows without a height: the rows a reorganization may have changed are
  // found without reading the confirmed history (bead libspiffy-ctkm).
  // Maintained by _putTransaction, deleteWallet and clear.
  final SplayTreeMap<int, Set<(String, String)>> _confirmedByHeight = SplayTreeMap();
  final Set<(String, String)> _confirmedWithoutHeight = {};

  // Rows by status and last update, as (walletId, txid) keys ordered by
  // (updatedAt, store order): a bounded feed of the rows with a status that
  // changed recently, without reading that status's whole history (bead
  // libspiffy-5bju, [getTransactionsByStatusSince]). Maintained by
  // _putTransaction, deleteWallet and clear.
  final Map<TransactionStatus, SplayTreeMap<(int, int), (String, String)>> _byStatusUpdatedAt = {};

  static int _compareUpdateKeys((int, int) a, (int, int) b) =>
      a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$2.compareTo(b.$2);

  // Store order of each (walletId, txid) row: breaks createdAt ties in the
  // newest-first lookups.
  final Map<(String, String), int> _txStoreOrder = {};
  int _nextTxStoreOrder = 0;

  /// Transaction rows the transaction read queries have visited (scanned or
  /// returned) since this storage was created. Lets a test observe how many
  /// rows an operation reads; tests may reset it.
  @visibleForTesting
  int transactionRowsRead = 0;

  /// Merkle proof rows the proof list queries (by status, by status and
  /// height or change time, history) have returned since this storage was
  /// created: the rows a backend with an index on those columns reads. Lets
  /// a test observe how many proofs an operation reads; tests may reset it.
  @visibleForTesting
  int merkleProofRowsRead = 0;

  // Block header storage: height -> BlockHeader
  final Map<int, BlockHeader> _blockHeaders = {};
  
  // Block header hash to height mapping: hash -> height
  final Map<String, int> _hashToHeight = {};
  
  // Orphaned block headers: hash -> BlockHeader
  final Map<String, BlockHeader> _orphanedHeaders = {};

  // Address metadata: walletId -> (address -> metadata)
  final Map<String, Map<String, AddressMetadata>> _addresses = {};

  // Transaction-address junction: walletId -> (txid -> links). The
  // insertion order of the inner map is the store order.
  final Map<String, Map<String, List<TransactionAddressLink>>> _txAddresses = {};

  // Merkle proof storage: txid -> every proof row, oldest first (bead mny:
  // rows are never removed; at most one is not orphaned).
  final Map<String, List<MerkleProof>> _merkleProofs = {};

  // Block hash to merkle proofs mapping: blockHash -> txids with a row
  // naming that block (filtered by status on read).
  final Map<String, Set<String>> _blockToProofs = {};

  // Ancestor transactions (bead zsh): txid -> raw hex. Not wallet rows;
  // never removed by deleteWallet.
  final Map<String, String> _ancestorTransactions = {};
  
  // Balance cache: walletId -> balance. No longer read: getBalance depends
  // on the wallet's address rows as well as its UTXOs (bead libspiffy-vsap).
  // Kept for [statistics] and [clearBalanceCache].
  final Map<String, BigInt> _balanceCache = {};
  
  // Existing wallets in creation order: a metadata row (storeWallet) or, as
  // this class is also the event store, a saved event stream. UTXO and
  // transaction rows do not create a wallet (audit S-15).
  final LinkedHashSet<String> _walletIds = LinkedHashSet<String>();
  
  // Synchronization for thread safety
  final Map<String, Completer<void>?> _locks = {};
  
  // Statistics
  int _totalEvents = 0;
  int _totalUtxos = 0;
  int _totalTransactions = 0;
  int _totalHeaders = 0;
  int _totalProofs = 0;
  
  /// Get storage statistics for monitoring
  Map<String, dynamic> get statistics => {
    'totalWallets': _walletIds.length,
    'totalEvents': _totalEvents,
    'totalUtxos': _totalUtxos,
    'totalTransactions': _totalTransactions,
    'totalHeaders': _totalHeaders,
    'totalProofs': _totalProofs,
    'memoryUsage': {
      'events': _events.length,
      'utxos': _utxos.length,
      'transactions': _transactions.length,
      'blockHeaders': _blockHeaders.length,
      'merkleProofs': _merkleProofs.length,
      'balanceCache': _balanceCache.length,
    },
  };
  
  /// Clear all cached balances (useful for testing)
  void clearBalanceCache() {
    _balanceCache.clear();
  }
  
  // ========================================
  // Wallet Metadata
  // ========================================
  
  // Wallet metadata storage
  final Map<String, Map<String, dynamic>> _walletMetadata = {};
  
  @override
  Future<void> storeWallet(
    String walletId,
    String name, {
    String? rootAddress,
    String? networkType,
    Map<String, dynamic>? metadata,
  }) async {
    // Typed values converted or rejected before anything is written, as on
    // every backend (bead libspiffy-k7na).
    metadata = WalletRowRules.normalizeMetadata(metadata);
    // Merge with the existing record (as the Isar and Postgres backends do)
    // so a balance update that omits rootAddress/network keeps them.
    final existing = _walletMetadata[walletId];
    final mergedMetadata = <String, dynamic>{
      ...?(existing?['metadata'] as Map<String, dynamic>?),
      ...?metadata,
    };
    final network = networkType ?? existing?['network'] as String? ?? 'mainnet';
    _walletMetadata[walletId] = {
      'walletId': walletId,
      'name': name,
      'rootAddress': rootAddress ?? existing?['rootAddress'],
      'network': network,
      'networkType': network, // legacy key
      'metadata': mergedMetadata,
    };
    _walletIds.add(walletId);
  }
  
  @override
  Future<Map<String, dynamic>?> getWallet(String walletId) async {
    return _walletMetadata[walletId];
  }
  
  @override
  Future<List<String>> listWallets() async {
    // Newest first, as every backend (audit S-19).
    return _walletIds.toList().reversed.toList();
  }
  
  @override
  Future<List<String>> getWalletAddresses(String walletId) async {
    // Registered addresses first, then any address only known from a UTXO.
    final addresses = <String>{...?_addresses[walletId]?.keys};
    final utxos = await getAvailableUTXOs(walletId);
    addresses.addAll(utxos.map((u) => u.address).where((a) => a.isNotEmpty));
    return addresses.toList();
  }
  
  @override
  Future<void> deleteWallet(String walletId) async {
    // Read associations BEFORE removing maps
    final txids = _transactions[walletId]?.keys.toList();
    for (final tx in _transactions[walletId]?.values ?? const <BitcoinTransaction>[]) {
      _unindexConfirmed(walletId, tx);
      _unindexByUpdate(walletId, tx);
    }
    final invoiceIds = _walletInvoices[walletId];

    // Remove wallet data (a hard delete, as every backend: audit S-15)
    _events.remove(walletId);
    _utxos.remove(walletId);
    _transactions.remove(walletId);
    _addresses.remove(walletId);
    _txAddresses.remove(walletId);
_balanceCache.remove(walletId);
    _walletMetadata.remove(walletId);
    _walletIds.remove(walletId);
    _walletInvoices.remove(walletId);
    _deferredPayments.remove(walletId);
    _deferredPaymentsByState.remove(walletId);

    // Drop the wallet from the txid index (other wallets keep their rows)
    if (txids != null) {
      for (final txid in txids) {
        _txStoreOrder.remove((walletId, txid));
        final owners = _txidWallets[txid];
        owners?.remove(walletId);
        if (owners != null && owners.isEmpty) _txidWallets.remove(txid);
      }
    }

    // Clean up associated invoices
    if (invoiceIds != null) {
      for (final invoiceId in invoiceIds) {
        _invoices.remove(invoiceId);
      }
    }

    // And payment channels
    final channelIds = _walletChannels.remove(walletId);
    if (channelIds != null) {
      for (final channelId in channelIds) {
        _paymentChannels.remove(channelId);
      }
    }
  }
  
  @override
  Future<void> saveEvents(String walletId, List<WalletEvent> events) async {
    await _withLock(walletId, () async {
      // Initialize wallet if it doesn't exist (even for empty event lists)
      _walletIds.add(walletId);
      _events.putIfAbsent(walletId, () => <WalletEvent>[]);
      
      if (events.isNotEmpty) {
        // Add events in order
        final walletEvents = _events[walletId]!;
        walletEvents.addAll(events);
        
        // Sort by version to maintain order
        walletEvents.sort((a, b) => a.version.compareTo(b.version));
        
        _totalEvents += events.length;
        
        // Invalidate balance cache since wallet state changed
        _balanceCache.remove(walletId);
      }
    });
  }
  
  @override
  Future<List<WalletEvent>> loadEvents(String walletId, {int? fromVersion}) async {
    return await _withLock(walletId, () async {
      if (!_walletIds.contains(walletId)) {
        throw StorageException('Wallet not found: $walletId');
      }
      
      final walletEvents = _events[walletId] ?? <WalletEvent>[];
      
      if (fromVersion == null) {
        return List<WalletEvent>.from(walletEvents);
      }
      
      return walletEvents
          .where((event) => event.version > fromVersion)
          .toList();
    });
  }
  
  @override
  Future<List<BitcoinUtxo>> getUTXOs(String walletId, {bool includeSpent = false}) async {
    // An unknown wallet has no UTXOs (audit S-15: no exception).
    return await _withLock(walletId, () async {
      final walletUtxos = _utxos[walletId] ?? <String, BitcoinUtxo>{};
      return _newestFirst(walletUtxos.values
          .where((utxo) => includeSpent || !utxo.isSpent)
          .toList());
    });
  }

  /// Newest first by createdAt; ties keep the store order (audit S-19).
  static List<BitcoinUtxo> _newestFirst(List<BitcoinUtxo> utxos) {
    mergeSort<BitcoinUtxo>(utxos, compare: (a, b) => b.createdAt.compareTo(a.createdAt));
    return utxos;
  }
  
  @override
  Future<List<BitcoinUtxo>> getAvailableUTXOs(String walletId) async {
    return await _withLock(walletId, () async {
      final walletUtxos = _utxos[walletId] ?? <String, BitcoinUtxo>{};
      return walletUtxos.values
          .where((utxo) => utxo.isAvailable)
          .toList();
    });
  }
  
  @override
  Future<List<BitcoinUtxo>> getPaymentUTXOs(String walletId) async {
    return await _withLock(walletId, () async {
      final walletUtxos = _utxos[walletId] ?? <String, BitcoinUtxo>{};
      return walletUtxos.values
          // The payment-UTXO rule shared with the Isar and Postgres
          // backends (audit S-18, bead ecy8): script-analysis metadata alone
          // does not exclude a UTXO.
          .where((utxo) => utxo.isAvailable && !utxo.isPluginManaged)
          .toList();
    });
  }

  @override
  Future<List<BitcoinUtxo>> getUTXOsByPlugin(
    String walletId,
    String pluginId, {
    Map<String, dynamic>? metadataFilter,
  }) async {
    return await _withLock(walletId, () async {
      final walletUtxos = _utxos[walletId] ?? <String, BitcoinUtxo>{};

      return _newestFirst(walletUtxos.values.where((utxo) {
        final meta = utxo.pluginMetadata;
        if (meta == null || meta['pluginId'] != pluginId) return false;
        if (metadataFilter != null) {
          for (final entry in metadataFilter.entries) {
            if (meta[entry.key] != entry.value) return false;
          }
        }
        return true;
      }).toList());
    });
  }

  /// [ReadModelStorage.getBalance]; same rule as the other backends
  /// ([splitBalanceUtxos] over [getPaymentUTXOs]). Not cached: the result
  /// depends on the wallet's address rows too (bead libspiffy-vsap).
  @override
  Future<BigInt> getBalance(String walletId) async =>
      (await splitBalanceUtxos(this, walletId, await getPaymentUTXOs(walletId))).spendableSatoshis;

  @override
  Future<BigInt> getWatchOnlyBalance(String walletId) async =>
      (await splitBalanceUtxos(this, walletId, await getPaymentUTXOs(walletId))).watchOnlySatoshis;

  @override
  Future<void> upsertUTXO(String walletId, BitcoinUtxo utxo) async {
    await _withLock(walletId, () async {
      // A UTXO row does not create the wallet (audit S-15).
      final utxoKey = '${utxo.txid}:${utxo.vout}';
      final walletUtxos = _utxos.putIfAbsent(walletId, () => {});
      final existing = walletUtxos[utxoKey];
      // A block height, plugin metadata or derivation index the update lacks
      // keeps the stored value, as on the persistent backends. A
      // zero-confirmation update (a confirmation taken back after a reorg,
      // audit 3b0) clears the height. The spending transaction, once stored,
      // is spend history and never replaced (bead libspiffy-viy).
      walletUtxos[utxoKey] = existing == null
          ? utxo
          : utxo.copyWith(
              blockHeight: utxo.blockHeight ??
                  ((utxo.confirmations ?? 0) > 0 ? existing.blockHeight : null),
              pluginMetadata: utxo.pluginMetadata ?? existing.pluginMetadata,
              derivationIndex: utxo.derivationIndex ?? existing.derivationIndex,
              spentInTxId: existing.spentInTxId ?? utxo.spentInTxId,
            );

      // Invalidate cache
      _balanceCache.remove(walletId);
    });
  }

  @override
  Future<void> deleteUTXO(String walletId, String txid, int vout) async {
    await _withLock(walletId, () async {
      if (_utxos.containsKey(walletId)) {
        final utxoKey = '$txid:$vout';
        _utxos[walletId]!.remove(utxoKey);
        
        // Invalidate cache
        _balanceCache.remove(walletId);
      }
    });
  }
  
  @override
  Future<List<String>> getWalletIds() => listWallets();
  
  @override
  Future<bool> walletExists(String walletId) async {
    return _walletIds.contains(walletId);
  }
  
  // ========================================
  // UTXO Management Methods (for internal use)
  // ========================================
  
  /// Add or update a UTXO in storage
  /// This is typically called by event handlers when processing UTXOReceivedEvent
  Future<void> addOrUpdateUtxo(String walletId, BitcoinUtxo utxo) async {
    await _withLock(walletId, () async {
      final walletUtxos = _utxos.putIfAbsent(walletId, () => <String, BitcoinUtxo>{});
      
      final isNew = !walletUtxos.containsKey(utxo.key);
      walletUtxos[utxo.key] = utxo;
      
      if (isNew) {
        _totalUtxos++;
      }
      
      // Invalidate balance cache
      _balanceCache.remove(walletId);
    });
  }
  
  /// Remove a UTXO from storage
  /// This is typically called by event handlers when processing UTXOSpentEvent
  Future<void> removeUtxo(String walletId, String utxoKey) async {
    await _withLock(walletId, () async {
      final walletUtxos = _utxos[walletId];
      if (walletUtxos != null && walletUtxos.containsKey(utxoKey)) {
        walletUtxos.remove(utxoKey);
        _totalUtxos--;
        
        // Invalidate balance cache
        _balanceCache.remove(walletId);
      }
    });
  }
  
  /// Update UTXO status (e.g., reserve, spend, release)
  Future<void> updateUtxoStatus(String walletId, String utxoKey, BitcoinUtxo updatedUtxo) async {
    await _withLock(walletId, () async {
      final walletUtxos = _utxos[walletId];
      if (walletUtxos != null && walletUtxos.containsKey(utxoKey)) {
        walletUtxos[utxoKey] = updatedUtxo;
        
        // Invalidate balance cache since UTXO availability changed
        _balanceCache.remove(walletId);
      }
    });
  }
  
  // ========================================
  // Transaction History Methods
  // ========================================

  @override
  Future<List<BitcoinTransaction>> getTransactionHistory(String walletId, {int? limit, int? offset}) async {
    return await _withLock(walletId, () async {
      // Newest first (createdAt descending; ties keep the store order), and
      // empty for an unknown wallet (audit S-15, S-19).
      final sorted = (_transactions[walletId]?.values ?? const <BitcoinTransaction>[])
          .toList();
      transactionRowsRead += sorted.length;
      mergeSort<BitcoinTransaction>(sorted,
          compare: (a, b) => b.createdAt.compareTo(a.createdAt));
      Iterable<BitcoinTransaction> txs = sorted;

      // Apply offset
      if (offset != null && offset > 0) {
        txs = txs.skip(offset);
      }

      // Apply limit
      if (limit != null && limit > 0) {
        txs = txs.take(limit);
      }

      return txs.toList();
    });
  }

  @override
  Future<BitcoinTransaction?> getTransaction(String txid, {String? walletId}) async {
    final BitcoinTransaction? tx;
    if (walletId != null) {
      tx = _transactions[walletId]?[txid];
    } else {
      final owners = _txidWallets[txid];
      tx = owners == null || owners.isEmpty ? null : _transactions[owners.first]?[txid];
    }
    if (tx != null) transactionRowsRead++;
    return tx;
  }

  @override
  Future<Map<String, BitcoinTransaction>> getTransactionsBatch(List<String> txids) async {
    final result = <String, BitcoinTransaction>{};
    for (final txid in txids) {
      final tx = await getTransaction(txid);
      if (tx != null) result[txid] = tx;
    }
    return result;
  }

  @override
  Future<List<BitcoinTransaction>> getTransactionsByStatus(
    TransactionStatus status, {
    String? walletId,
  }) async {
    // Get all transactions or filter by wallet
    Iterable<BitcoinTransaction> transactions;
    
    if (walletId != null) {
      // Filter by wallet
      transactions = _transactions[walletId]?.values ?? const <BitcoinTransaction>[];
    } else {
      // Get all transactions (one row per wallet holding the txid)
      transactions = _transactions.values.expand((txs) => txs.values);
    }
    
    // Filter by status and sort by creation date (descending, stable)
    final filtered = transactions.where((tx) {
      transactionRowsRead++;
      return tx.status == status;
    }).toList();
    mergeSort<BitcoinTransaction>(filtered,
        compare: (a, b) => b.createdAt.compareTo(a.createdAt));
    return filtered;
  }

  @override
  Future<List<BitcoinTransaction>> getTransactionsByStatusSince(
    TransactionStatus status,
    DateTime since, {
    int limit = 100,
  }) async {
    // Walks the (status, updatedAt) index backwards from the newest row and
    // stops at [since] or [limit]: the rows older than the window are never
    // visited (bead libspiffy-5bju).
    final byUpdate = _byStatusUpdatedAt[status];
    if (byUpdate == null || limit <= 0) return const [];
    final sinceMicros = since.microsecondsSinceEpoch;
    final rows = <BitcoinTransaction>[];
    for ((int, int)? key = byUpdate.lastKey(); key != null; key = byUpdate.lastKeyBefore(key)) {
      if (key.$1 < sinceMicros) break;
      final (walletId, txid) = byUpdate[key]!;
      final tx = _transactions[walletId]?[txid];
      if (tx == null) continue;
      transactionRowsRead++;
      rows.add(tx);
      if (rows.length >= limit) break;
    }
    return rows;
  }

  @override
  Future<List<BitcoinTransaction>> getTransactionsByTxids(List<String> txids) async {
    final rows = <BitcoinTransaction>[
      for (final txid in txids.toSet())
        for (final walletId in _txidWallets[txid] ?? const <String>[])
          if (_transactions[walletId]?[txid] case final tx?) tx,
    ];
    return _transactionsNewestFirst(rows);
  }

  @override
  Future<List<BitcoinTransaction>> getConfirmedTransactionsFromHeight(
    int minHeight, {
    bool includeWithoutHeight = false,
  }) async {
    // Walks the heights from minHeight up only.
    final keys = <(String, String)>[
      for (int? height = _confirmedByHeight.containsKey(minHeight) ? minHeight : _confirmedByHeight.firstKeyAfter(minHeight);
          height != null;
          height = _confirmedByHeight.firstKeyAfter(height))
        ..._confirmedByHeight[height]!,
      if (includeWithoutHeight) ..._confirmedWithoutHeight,
    ];
    return _transactionsNewestFirst([
      for (final (walletId, txid) in keys) _transactions[walletId]![txid]!,
    ]);
  }

  /// [rows] newest first (createdAt descending, then store order), counted
  /// as read.
  List<BitcoinTransaction> _transactionsNewestFirst(List<BitcoinTransaction> rows) {
    transactionRowsRead += rows.length;
    int order(BitcoinTransaction tx) => _txStoreOrder[(tx.walletId!, tx.txid)] ?? 0;
    rows.sort((a, b) {
      final byTime = b.createdAt.compareTo(a.createdAt);
      return byTime != 0 ? byTime : order(a).compareTo(order(b));
    });
    return rows;
  }

  @override
  Future<void> storeTransaction(String walletId, BitcoinTransaction transaction) async {
    await _withLock(walletId, () async {
      _putTransaction(walletId, transaction);
    });
  }

  @override
  Future<void> storeRevertedTransaction(String walletId, BitcoinTransaction transaction) async {
    await _withLock(walletId, () async {
      _putTransaction(walletId, transaction, reverting: true);
    });
  }

  /// Insert or replace the ([walletId], txid) row. Returns true when new.
  ///
  /// The stored copy carries [walletId] whatever the caller's model says,
  /// as the persistent backends return it (audit S-20). An update without
  /// raw hex keeps the stored bytes: an SPV wallet cannot fetch the
  /// transaction again. An update whose status [TransactionRowRules.setsStatus]
  /// refuses keeps the stored status, block height and confirmations (7dj),
  /// unless [reverting]. A confirmed update without a block height keeps the
  /// stored height; a non-confirmed one clears it (a reorg took the
  /// confirmation back, audit 3b0).
  bool _putTransaction(String walletId, BitcoinTransaction transaction, {bool reverting = false}) {
    final walletTxs = _transactions.putIfAbsent(walletId, () => {});
    final existing = walletTxs[transaction.txid];
    final isNew = existing == null;
    if (existing != null) {
      _unindexConfirmed(walletId, existing);
      _unindexByUpdate(walletId, existing);
    }
    final keepsStatus =
        existing != null && !reverting && !TransactionRowRules.setsStatus(existing.status, transaction.status);
    final stored = walletTxs[transaction.txid] = keepsStatus
        ? BitcoinTransaction(
            walletId: walletId,
            txid: transaction.txid,
            rawHex: transaction.rawHex.isEmpty ? existing.rawHex : transaction.rawHex,
            status: existing.status,
            blockHeight: existing.blockHeight,
            confirmations: existing.confirmations,
            inputValue: transaction.inputValue,
            outputValue: transaction.outputValue,
            fee: transaction.fee,
            receivingAddresses: transaction.receivingAddresses,
            sendingAddresses: transaction.sendingAddresses,
            netAmount: transaction.netAmount,
            createdAt: transaction.createdAt,
            updatedAt: transaction.updatedAt,
            memo: transaction.memo,
            lockTime: transaction.lockTime,
            version: transaction.version,
          )
        : transaction.copyWith(
            walletId: walletId,
            rawHex: transaction.rawHex.isEmpty ? existing?.rawHex : null,
            blockHeight: transaction.blockHeight ??
                (transaction.status == TransactionStatus.confirmed ? existing?.blockHeight : null),
          );
    _indexConfirmed(walletId, stored);
    if (isNew) {
      _txidWallets.putIfAbsent(transaction.txid, () => []).add(walletId);
      _txStoreOrder[(walletId, transaction.txid)] = _nextTxStoreOrder++;
    }
    _indexByUpdate(walletId, stored);
    return isNew;
  }

  /// The key of the stored row [tx] of [walletId] in [_byStatusUpdatedAt].
  (int, int) _updateKey(String walletId, BitcoinTransaction tx) =>
      (tx.updatedAt.microsecondsSinceEpoch, _txStoreOrder[(walletId, tx.txid)] ?? 0);

  /// Add the stored row [tx] of [walletId] to the (status, updatedAt) index.
  void _indexByUpdate(String walletId, BitcoinTransaction tx) {
    _byStatusUpdatedAt
        .putIfAbsent(tx.status, () => SplayTreeMap(_compareUpdateKeys))[_updateKey(walletId, tx)] =
        (walletId, tx.txid);
  }

  /// Remove the stored row [tx] of [walletId] from that index.
  void _unindexByUpdate(String walletId, BitcoinTransaction tx) {
    final byUpdate = _byStatusUpdatedAt[tx.status];
    if (byUpdate == null) return;
    byUpdate.remove(_updateKey(walletId, tx));
    if (byUpdate.isEmpty) _byStatusUpdatedAt.remove(tx.status);
  }

  /// Add the stored row [tx] of [walletId] to the confirmed-height index.
  void _indexConfirmed(String walletId, BitcoinTransaction tx) {
    if (tx.status != TransactionStatus.confirmed) return;
    final key = (walletId, tx.txid);
    final height = tx.blockHeight;
    if (height == null) {
      _confirmedWithoutHeight.add(key);
    } else {
      _confirmedByHeight.putIfAbsent(height, () => {}).add(key);
    }
  }

  /// Remove the stored row [tx] of [walletId] from the confirmed-height index.
  void _unindexConfirmed(String walletId, BitcoinTransaction tx) {
    final key = (walletId, tx.txid);
    _confirmedWithoutHeight.remove(key);
    final height = tx.blockHeight;
    if (height == null) return;
    final keys = _confirmedByHeight[height];
    if (keys == null) return;
    keys.remove(key);
    if (keys.isEmpty) _confirmedByHeight.remove(height);
  }

  // ========================================
  // Block Header Storage Methods
  // ========================================

  @override
  Future<void> storeBlockHeader(BlockHeader header, int height) async {
    await _withGlobalLock(() async {
      _putActiveHeader(header, height);
    });
  }

  @override
  Future<void> storeBlockHeadersBulk(List<(BlockHeader, int)> headers) async {
    await _withGlobalLock(() async {
      for (final (header, height) in headers) {
        _putActiveHeader(header, height);
      }
    });
  }

  /// Upsert [header] as the active header at [height]: idempotent for a
  /// hash already stored there, re-activates an orphaned header, and moves
  /// a hash stored at another height. This store holds one header per
  /// height, so a different header at [height] loses its hash entry.
  void _putActiveHeader(BlockHeader header, int height) {
    final hash = header.blockHash().toString();

    final previousHeight = _hashToHeight[hash];
    if (previousHeight != null && previousHeight != height) {
      _blockHeaders.remove(previousHeight);
    }
    final displaced = _blockHeaders[height];
    if (displaced != null) {
      final displacedHash = displaced.blockHash().toString();
      if (displacedHash != hash) _hashToHeight.remove(displacedHash);
    }

    if (previousHeight == null) _totalHeaders++;
    _orphanedHeaders.remove(hash);
    _blockHeaders[height] = header;
    _hashToHeight[hash] = height;
  }

  @override
  Future<BlockHeader?> getBlockHeaderByHash(String hash) async {
    final height = _hashToHeight[hash];
    if (height == null) return null;
    return _blockHeaders[height];
  }

  @override
  Future<BlockHeader?> getBlockHeaderByHeight(int height) async {
    return _blockHeaders[height];
  }

  @override
  Future<int?> getHeightByBlockHash(String hash) async {
    return _hashToHeight[hash];
  }

  @override
  Future<List<BlockHeader>> getBlockHeaderRange(int fromHeight, int toHeight) async {
    final headers = <BlockHeader>[];
    for (int height = fromHeight; height <= toHeight; height++) {
      final header = _blockHeaders[height];
      if (header != null) {
        headers.add(header);
      }
    }
    return headers;
  }

  @override
  Future<void> markHeaderAsOrphaned(String hash) async {
    await _withGlobalLock(() async {
      final height = _hashToHeight[hash];
      if (height != null) {
        final header = _blockHeaders[height];
        // Only retire the header if it is the one with this hash.
        if (header != null && header.blockHash().toString() == hash) {
          _orphanedHeaders[hash] = header;
          _blockHeaders.remove(height);
        }
        _hashToHeight.remove(hash);
      }
    });
  }

  @override
  Future<BlockHeader?> getChainTip() async {
    if (_blockHeaders.isEmpty) return null;
    final maxHeight = _blockHeaders.keys.reduce((a, b) => a > b ? a : b);
    return _blockHeaders[maxHeight];
  }

  @override
  Future<int> getBestHeight() async {
    if (_blockHeaders.isEmpty) return 0;
    return _blockHeaders.keys.reduce((a, b) => a > b ? a : b);
  }

  @override
  Future<List<BlockHeader>> getRecentHeaders(int count) async {
    final sortedHeights = _blockHeaders.keys.toList()..sort((a, b) => b.compareTo(a));
    final recentHeights = sortedHeights.take(count);
    return recentHeights.map((height) => _blockHeaders[height]!).toList();
  }

  // ========================================
  // Merkle Proof Storage Methods
  // ========================================

  /// Rows are only added or updated (bead mny); see
  /// [ReadModelStorage.storeMerkleProof] and `planMerkleProofStore`.
  @override
  Future<void> storeMerkleProof(String txid, MerkleProof proof) async {
    await _withGlobalLock(() async {
      final rows = _merkleProofs.putIfAbsent(txid, () => []);
      final plan = planMerkleProofStore(rows, txid, proof);
      for (final i in plan.orphan) {
        rows[i] = rows[i].copyWith(status: MerkleProofStatus.orphaned, statusChangedAt: plan.orphanedAt);
      }
      if (plan.target == null) {
        rows.add(plan.row);
        _totalProofs++;
      } else {
        rows[plan.target!] = plan.row;
      }
      final hash = plan.row.blockHash;
      if (hash != null) _blockToProofs.putIfAbsent(hash, () => {}).add(txid);
    });
  }

  @override
  Future<bool> markMerkleProofOrphaned(
    String txid, {
    String? blockHash,
    List<String>? onlyIfMerkleProof,
    DateTime? at,
  }) async {
    return _withGlobalLock(() async {
      final rows = _merkleProofs[txid];
      if (rows == null) return false;
      final plan = planMerkleProofOrphan(rows,
          blockHash: blockHash, onlyIfMerkleProof: onlyIfMerkleProof, at: at ?? DateTime.now());
      if (plan == null) return false;
      rows[plan.index] = plan.row;
      final hash = plan.row.blockHash;
      if (hash != null) _blockToProofs.putIfAbsent(hash, () => {}).add(txid);
      return true;
    });
  }

  @override
  Future<MerkleProof?> getMerkleProof(String txid) async {
    return currentMerkleProof(_merkleProofs[txid] ?? const []);
  }

  @override
  Future<Map<String, MerkleProof>> getMerkleProofsBatch(List<String> txids) async {
    final result = <String, MerkleProof>{};
    for (final txid in txids) {
      final proof = currentMerkleProof(_merkleProofs[txid] ?? const []);
      if (proof != null) result[txid] = proof;
    }
    return result;
  }

  @override
  Future<List<MerkleProof>> getMerkleProofHistory(String txid) async {
    return _countProofRows(List.unmodifiable(_merkleProofs[txid] ?? const <MerkleProof>[]));
  }

  List<MerkleProof> _countProofRows(List<MerkleProof> rows) {
    merkleProofRowsRead += rows.length;
    return rows;
  }

  @override
  Future<List<MerkleProof>> getMerkleProofsByStatus(MerkleProofStatus status) async {
    return _countProofRows([
      for (final rows in _merkleProofs.values)
        for (final r in rows)
          if (r.status == status) r,
    ]);
  }

  @override
  Future<List<MerkleProof>> getMerkleProofsByStatusBetweenHeights(
    MerkleProofStatus status,
    int fromHeight,
    int toHeight,
  ) async {
    return _countProofRows([
      for (final rows in _merkleProofs.values)
        for (final r in rows)
          if (r.status == status && r.blockHeight >= fromHeight && r.blockHeight <= toHeight) r,
    ]);
  }

  @override
  Future<List<MerkleProof>> getMerkleProofsByStatusChangedSince(MerkleProofStatus status, DateTime since) async {
    return _countProofRows([
      for (final rows in _merkleProofs.values)
        for (final r in rows)
          if (r.status == status && r.statusChangedAt != null && !r.statusChangedAt!.isBefore(since)) r,
    ]);
  }

  @override
  Future<List<MerkleProof>> getMerkleProofsForBlock(String blockHash) async {
    return [
      for (final txid in _blockToProofs[blockHash] ?? const <String>{})
        for (final r in _merkleProofs[txid]!)
          if (r.isCurrent && r.blockHash == blockHash) r,
    ];
  }

  // ========================================
  // Ancestor Transactions (bead zsh)
  // ========================================

  @override
  Future<void> storeAncestorTransaction(String txid, String rawHex) async {
    _ancestorTransactions.putIfAbsent(txid, () => rawHex);
  }

  @override
  Future<Map<String, String>> getAncestorTransactionsBatch(List<String> txids) async {
    return {
      for (final txid in txids)
        if (_ancestorTransactions.containsKey(txid)) txid: _ancestorTransactions[txid]!,
    };
  }

  // ========================================
  // Deferred payments (bead libspiffy-7p2)
  // ========================================

  /// walletId -> txid -> payment.
  final Map<String, Map<String, DeferredPayment>> _deferredPayments = {};

  /// walletId -> state -> txids in that state (the index the listing reads).
  final Map<String, Map<DeferredPaymentState, Set<String>>> _deferredPaymentsByState = {};

  /// Rows [listDeferredPayments] has read (test hook: a query reads only the
  /// rows of the states it asks for).
  @visibleForTesting
  int deferredPaymentRowsRead = 0;

  @override
  Future<void> storeDeferredPayment(DeferredPayment payment) async {
    final rows = _deferredPayments.putIfAbsent(payment.walletId, () => {});
    final index = _deferredPaymentsByState.putIfAbsent(payment.walletId, () => {});
    final previous = rows[payment.txid];
    if (previous != null) index[previous.state]?.remove(payment.txid);
    rows[payment.txid] = payment;
    index.putIfAbsent(payment.state, () => <String>{}).add(payment.txid);
  }

  @override
  Future<DeferredPayment?> getDeferredPayment(String walletId, String txid) async =>
      _deferredPayments[walletId]?[txid];

  @override
  Future<DeferredPaymentPage> listDeferredPayments(
    String walletId, {
    DeferredPaymentQuery query = const DeferredPaymentQuery(),
  }) async {
    DeferredPaymentQuery.decodeCursor(query.cursor); // rejects a foreign cursor
    final rows = _deferredPayments[walletId];
    final index = _deferredPaymentsByState[walletId];
    if (rows == null || index == null) return const DeferredPaymentPage(payments: []);
    final candidates = <DeferredPayment>[];
    for (final state in query.states) {
      for (final txid in index[state] ?? const <String>{}) {
        deferredPaymentRowsRead++;
        final row = rows[txid];
        if (row != null && query.matches(row)) candidates.add(row);
      }
    }
    candidates.sort(query.compare);
    return query.page(candidates);
  }

  // ========================================
  // Transaction Management Methods (Internal)
  // ========================================

  /// Add a transaction to storage
  Future<void> addTransaction(String walletId, BitcoinTransaction transaction) async {
    await _withLock(walletId, () async {
      if (_putTransaction(walletId, transaction)) {
        _totalTransactions++;
      }
    });
  }

  // ========================================
  // Private Helper Methods
  // ========================================
  
  /// Execute a function with exclusive access to a wallet's data
  Future<T> _withLock<T>(String walletId, Future<T> Function() fn) async {
    // Wait for any existing lock to complete
    while (_locks[walletId] != null) {
      await _locks[walletId]!.future;
    }
    
    // Create new lock
    final completer = Completer<void>();
    _locks[walletId] = completer;
    
    try {
      final result = await fn();
      return result;
    } catch (e) {
      throw StorageException('Operation failed for wallet $walletId', e);
    } finally {
      // Release lock
      _locks[walletId] = null;
      completer.complete();
    }
  }

  /// Execute a function with exclusive access to global data (block headers, merkle proofs)
  Future<T> _withGlobalLock<T>(Future<T> Function() fn) async {
    const globalKey = '__global__';
    
    // Wait for any existing lock to complete
    while (_locks[globalKey] != null) {
      await _locks[globalKey]!.future;
    }
    
    // Create new lock
    final completer = Completer<void>();
    _locks[globalKey] = completer;
    
    try {
      final result = await fn();
      return result;
    } catch (e) {
      throw StorageException('Global operation failed', e);
    } finally {
      // Release lock
      _locks[globalKey] = null;
      completer.complete();
    }
  }
  
  // ========================================
  // Invoice Operations
  // ========================================

  // Invoice storage: invoiceId -> read model (immutable; replaced on update)
  final Map<String, InvoiceReadModel> _invoices = {};
  
  // Invoice by wallet: walletId -> List of invoiceIds
  final Map<String, List<String>> _walletInvoices = {};

  @override
  Future<void> storeInvoice(InvoiceReadModel invoice) async {
    await _withLock(invoice.walletId, () async {
      _invoices[invoice.invoiceId] = invoice;
      
      final walletInvs = _walletInvoices.putIfAbsent(invoice.walletId, () => []);
      if (!walletInvs.contains(invoice.invoiceId)) {
        walletInvs.add(invoice.invoiceId);
      }
    });
  }

  @override
  Future<InvoiceReadModel?> getInvoice(String invoiceId) async {
    return _invoices[invoiceId];
  }

  @override
  Future<List<InvoiceReadModel>> listInvoices({
    String? walletId,
    InvoiceStatus? status,
  }) async {
    final candidates = walletId == null
        ? _invoices.values
        : (_walletInvoices[walletId] ?? const <String>[])
            .map((id) => _invoices[id])
            .whereType<InvoiceReadModel>();
    final result = candidates
        .where((inv) => status == null || inv.status == status)
        .toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return result;
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
    final invoice = _invoices[invoiceId];
    if (invoice == null) return;
    await _withLock(invoice.walletId, () async {
      // InvoiceReadModel is immutable: replace it rather than assign to
      // its final fields (audit S-07).
      _invoices[invoiceId] = invoice.copyWith(
        status: status,
        paymentTxid: txid,
        amountReceived: amountReceived,
        paidAt: paidAt,
        lastUpdated: DateTime.now(),
      );
    });
  }

  @override
  Future<int> getMerkleProofCount({String? walletId}) async {
    // In-memory storage doesn't track proofs by wallet
    // Return total count of proof rows, orphaned ones included
    return _merkleProofs.values.fold<int>(0, (n, rows) => n + rows.length);
  }

  // ========================================
  // Address Management (same semantics as the Isar backend, audit S-18)
  // ========================================

  @override
  Future<bool> isWalletAddress(String walletId, String address) async {
    return _addresses[walletId]?.containsKey(address) ?? false;
  }

  @override
  Future<AddressMetadata?> getAddressMetadata(String walletId, String address) async {
    return _addresses[walletId]?[address];
  }

  @override
  Future<Map<String, bool>> checkAddresses(String walletId, List<String> addresses) async {
    final known = _addresses[walletId];
    return {for (final addr in addresses) addr: known?.containsKey(addr) ?? false};
  }

  @override
  Future<List<AddressMetadata>> getAddressesWithMetadata(
    String walletId, {
    bool? includeUnused,
    bool? isChange,
    int? limit,
    int? offset,
  }) async {
    // Newest first, as the Isar backend sorts by creation time.
    final matching = (_addresses[walletId]?.values ?? const <AddressMetadata>[])
        .where((a) => includeUnused != false || a.usageCount > 0)
        .where((a) => isChange == null || a.isChange == isChange)
        .toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    Iterable<AddressMetadata> result = matching;
    if (offset != null) result = result.skip(offset);
    if (limit != null) result = result.take(limit);
    return result.toList();
  }

  @override
  Future<List<AddressMetadata>> getAddressRange(
    String walletId, {
    required int startIndex,
    required int count,
    bool isChange = false,
  }) async {
    final endIndex = startIndex + count - 1;
    return (_addresses[walletId]?.values ?? const <AddressMetadata>[])
        .where((a) =>
            a.isChange == isChange &&
            a.derivationIndex != null &&
            a.derivationIndex! >= startIndex &&
            a.derivationIndex! <= endIndex)
        .toList()
      ..sort((a, b) => a.derivationIndex!.compareTo(b.derivationIndex!));
  }

  @override
  Future<List<AddressMetadata>> getAddressesByPurpose(String walletId, String purpose) async => [
        for (final a in _addresses[walletId]?.values ?? const <AddressMetadata>[])
          if (a.purpose == purpose) a,
      ];

  @override
  Future<void> upsertAddress(String walletId, AddressMetadata metadata) async {
    await _withLock(walletId, () async {
      _addresses.putIfAbsent(walletId, () => {})[metadata.address] = metadata;
    });
  }

  @override
  Future<int> getAddressCount(String walletId) async {
    return _addresses[walletId]?.length ?? 0;
  }

  @override
  Future<void> updateAddressUsage(
    String walletId,
    String address, {
    DateTime? usedAt,
    BigInt? balanceDelta,
  }) async {
    await _withLock(walletId, () async {
      final current = _addresses[walletId]?[address];
      if (current == null) return;
      _addresses[walletId]![address] = AddressMetadata(
        address: current.address,
        scriptType: current.scriptType,
        derivationPath: current.derivationPath,
        derivationIndex: current.derivationIndex,
        isChange: current.isChange,
        label: current.label,
        purpose: current.purpose,
        firstUsedAt: current.firstUsedAt ?? usedAt,
        lastUsedAt: usedAt ?? current.lastUsedAt,
        usageCount: current.usageCount + (usedAt != null ? 1 : 0),
        balance: current.balance + (balanceDelta ?? BigInt.zero),
        createdAt: current.createdAt,
        isWatched: current.isWatched,
      );
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
    await _withLock(walletId, () async {
      final walletLinks = _txAddresses.putIfAbsent(walletId, () => {});
      // Replace (not append) so a replay leaves one set; re-insert so the
      // txid moves to the newest position like a freshly written Isar row.
      walletLinks.remove(txid);
      walletLinks[txid] = List.unmodifiable(links);
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
    final walletLinks = _txAddresses[walletId];
    if (walletLinks == null) return [];
    // Newest first, as the Isar backend orders by creation time.
    Iterable<String> txids = walletLinks.entries
        .where((e) => e.value.any((l) =>
            l.address == address && (direction == null || l.direction == direction)))
        .map((e) => e.key)
        .toList()
        .reversed;
    if (offset != null) txids = txids.skip(offset);
    if (limit != null) txids = txids.take(limit);
    return txids.toList();
  }

  @override
  Future<TransactionAddresses> getTransactionAddresses(String walletId, String txid) async {
    final links = _txAddresses[walletId]?[txid] ?? const <TransactionAddressLink>[];
    return TransactionAddresses(
      inputs: links.where((l) => l.direction == 'input').toList(),
      outputs: links.where((l) => l.direction == 'output').toList(),
    );
  }

  @override
  Future<int> getAddressTransactionCount(String walletId, String address) async {
    final walletLinks = _txAddresses[walletId];
    if (walletLinks == null) return 0;
    return walletLinks.values
        .where((links) => links.any((l) => l.address == address))
        .length;
  }

  /// Clear all data (useful for testing)
  void clear() {
    _events.clear();
    _utxos.clear();
    _transactions.clear();
    _txidWallets.clear();
    _confirmedByHeight.clear();
    _confirmedWithoutHeight.clear();
    _byStatusUpdatedAt.clear();
    _txStoreOrder.clear();
    _addresses.clear();
    _txAddresses.clear();
    _blockHeaders.clear();
    _hashToHeight.clear();
    _orphanedHeaders.clear();
    _merkleProofs.clear();
    _blockToProofs.clear();
    _ancestorTransactions.clear();
    _deferredPayments.clear();
    _deferredPaymentsByState.clear();
    _balanceCache.clear();
    _walletIds.clear();
    _invoices.clear();
    _walletInvoices.clear();
    _paymentChannels.clear();
    _walletChannels.clear();
    _totalEvents = 0;
    _totalUtxos = 0;
    _totalTransactions = 0;
    _totalHeaders = 0;
    _totalProofs = 0;
  }

  // ========================================
  // Payment Channel Storage
  // ========================================
  //
  // Channels are stored and returned as snapshots (copyWith) so that, like
  // the persistent backends, a caller mutating a fetched channel changes
  // nothing until it calls storePaymentChannel again.

  final Map<String, PaymentChannel> _paymentChannels = {};
  final Map<String, List<String>> _walletChannels = {};

  @override
  Future<void> storePaymentChannel(PaymentChannel channel) async {
    await _withGlobalLock(() async {
      _paymentChannels[channel.channelId] = channel.copyWith();
      
      // Index by wallet
      final walletChannels = _walletChannels.putIfAbsent(channel.walletId, () => []);
      if (!walletChannels.contains(channel.channelId)) {
        walletChannels.add(channel.channelId);
      }
    });
  }

  @override
  Future<PaymentChannel?> getPaymentChannel(String channelId) async {
    return _paymentChannels[channelId]?.copyWith();
  }

  @override
  Future<List<PaymentChannel>> getPaymentChannelsForWallet(String walletId) async {
    final channelIds = _walletChannels[walletId] ?? const <String>[];
    return channelIds
        .map((id) => _paymentChannels[id])
        .whereType<PaymentChannel>()
        .map((ch) => ch.copyWith())
        .toList();
  }

  @override
  Future<void> updatePaymentChannelState(String channelId, String state) async {
    await _withGlobalLock(() async {
      final channel = _paymentChannels[channelId];
      if (channel != null) {
        _paymentChannels[channelId] =
            channel.copyWith(state: PaymentChannelState.values.byName(state));
      }
    });
  }

  @override
  Future<void> updatePaymentChannelBalance(
    String channelId,
    BigInt clientBalance,
    BigInt serverBalance,
  ) async {
    await _withGlobalLock(() async {
      final channel = _paymentChannels[channelId];
      if (channel != null) {
        _paymentChannels[channelId] = channel.copyWith(
          clientBalanceSats: clientBalance,
          serverBalanceSats: serverBalance,
        );
      }
    });
  }

  @override
  Future<void> deletePaymentChannel(String channelId) async {
    await _withGlobalLock(() async {
      final channel = _paymentChannels.remove(channelId);
      if (channel != null) {
        // Remove from wallet index
        _walletChannels[channel.walletId]?.remove(channelId);
      }
    });
  }
}
