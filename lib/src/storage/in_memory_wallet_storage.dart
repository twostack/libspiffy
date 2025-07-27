import 'dart:async';
import 'package:spiffynode/spiffy_node.dart';
import '../models/wallet_event.dart';
import '../models/bitcoin_utxo.dart';
import '../models/bitcoin_transaction.dart';
import 'wallet_storage.dart';

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
  
  // Transaction storage: txid -> BitcoinTransaction
  final Map<String, BitcoinTransaction> _transactions = {};
  
  // Transaction history by wallet: walletId -> List of txids
  final Map<String, List<String>> _walletTransactions = {};
  
  // Block header storage: height -> BlockHeader
  final Map<int, BlockHeader> _blockHeaders = {};
  
  // Block header hash to height mapping: hash -> height
  final Map<String, int> _hashToHeight = {};
  
  // Orphaned block headers: hash -> BlockHeader
  final Map<String, BlockHeader> _orphanedHeaders = {};
  
  // Merkle proof storage: txid -> MerkleProof
  final Map<String, MerkleProof> _merkleProofs = {};
  
  // Block hash to merkle proofs mapping: blockHash -> List<txid>
  final Map<String, List<String>> _blockToProofs = {};
  
  // Balance cache: walletId -> balance
  final Map<String, BigInt> _balanceCache = {};
  
  // Wallet existence tracking
  final Set<String> _walletIds = {};
  
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
    return await _withLock(walletId, () async {
      if (!_walletIds.contains(walletId)) {
        throw StorageException('Wallet not found: $walletId');
      }
      
      final walletUtxos = _utxos[walletId] ?? <String, BitcoinUtxo>{};
      
      return walletUtxos.values
          .where((utxo) => includeSpent || !utxo.isSpent)
          .toList();
    });
  }
  
  @override
  Future<List<BitcoinUtxo>> getAvailableUTXOs(String walletId) async {
    return await _withLock(walletId, () async {
      if (!_walletIds.contains(walletId)) {
        throw StorageException('Wallet not found: $walletId');
      }
      
      final walletUtxos = _utxos[walletId] ?? <String, BitcoinUtxo>{};
      
      return walletUtxos.values
          .where((utxo) => utxo.isAvailable)
          .toList();
    });
  }
  
  @override
  Future<BigInt> getBalance(String walletId) async {
    return await _withLock(walletId, () async {
      if (!_walletIds.contains(walletId)) {
        throw StorageException('Wallet not found: $walletId');
      }
      
      // Check cache first  
      if (_balanceCache.containsKey(walletId)) {
        return _balanceCache[walletId]!;
      }
      
      // Calculate balance from available UTXOs (avoid nested locking)
      final walletUtxos = _utxos[walletId] ?? <String, BitcoinUtxo>{};
      final availableUtxos = walletUtxos.values
          .where((utxo) => utxo.isAvailable)
          .toList();
      
      final balance = availableUtxos.fold<BigInt>(
        BigInt.zero,
        (sum, utxo) => sum + utxo.satoshis,
      );
      
      // Cache the result
      _balanceCache[walletId] = balance;
      
      return balance;
    });
  }
  
  @override
  Future<List<String>> getWalletIds() async {
    return List<String>.from(_walletIds);
  }
  
  @override
  Future<bool> walletExists(String walletId) async {
    return _walletIds.contains(walletId);
  }
  
  @override
  Future<void> deleteWallet(String walletId) async {
    await _withLock(walletId, () async {
      final eventsRemoved = _events[walletId]?.length ?? 0;
      final utxosRemoved = _utxos[walletId]?.length ?? 0;
      
      _events.remove(walletId);
      _utxos.remove(walletId);
      _balanceCache.remove(walletId);
      _walletIds.remove(walletId);
      
      _totalEvents -= eventsRemoved;
      _totalUtxos -= utxosRemoved;
    });
  }
  
  // ========================================
  // UTXO Management Methods (for internal use)
  // ========================================
  
  /// Add or update a UTXO in storage
  /// This is typically called by event handlers when processing UTXOReceivedEvent
  Future<void> addOrUpdateUtxo(String walletId, BitcoinUtxo utxo) async {
    await _withLock(walletId, () async {
      _walletIds.add(walletId);
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
      if (!_walletIds.contains(walletId)) {
        throw StorageException('Wallet not found: $walletId');
      }

      final walletTxIds = _walletTransactions[walletId] ?? [];
      var txIds = List<String>.from(walletTxIds);
      
      // Apply offset
      if (offset != null && offset > 0) {
        txIds = txIds.skip(offset).toList();
      }
      
      // Apply limit
      if (limit != null && limit > 0) {
        txIds = txIds.take(limit).toList();
      }
      
      // Get transactions in order
      return txIds.map((txid) => _transactions[txid]!).toList();
    });
  }

  @override
  Future<BitcoinTransaction?> getTransaction(String txid) async {
    return _transactions[txid];
  }

  // ========================================
  // Block Header Storage Methods
  // ========================================

  @override
  Future<void> storeBlockHeader(BlockHeader header, int height) async {
    await _withGlobalLock(() async {
      final hash = header.blockHash().toString();
      
      _blockHeaders[height] = header;
      _hashToHeight[hash] = height;
      _totalHeaders++;
    });
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
        if (header != null) {
          _orphanedHeaders[hash] = header;
          _blockHeaders.remove(height);
          _hashToHeight.remove(hash);
        }
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

  @override
  Future<void> storeMerkleProof(String txid, MerkleProof proof) async {
    await _withGlobalLock(() async {
      _merkleProofs[txid] = proof;
      
      // Update block to proofs mapping
      final blockProofs = _blockToProofs.putIfAbsent(proof.blockHash, () => []);
      if (!blockProofs.contains(txid)) {
        blockProofs.add(txid);
      }
      
      _totalProofs++;
    });
  }

  @override
  Future<MerkleProof?> getMerkleProof(String txid) async {
    return _merkleProofs[txid];
  }

  @override
  Future<List<MerkleProof>> getMerkleProofsForBlock(String blockHash) async {
    final txIds = _blockToProofs[blockHash] ?? [];
    return txIds.map((txid) => _merkleProofs[txid]!).toList();
  }

  // ========================================
  // Transaction Management Methods (Internal)
  // ========================================

  /// Add a transaction to storage
  Future<void> addTransaction(String walletId, BitcoinTransaction transaction) async {
    await _withLock(walletId, () async {
      _walletIds.add(walletId);
      _transactions[transaction.txid] = transaction;
      
      final walletTxs = _walletTransactions.putIfAbsent(walletId, () => []);
      if (!walletTxs.contains(transaction.txid)) {
        walletTxs.add(transaction.txid);
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
  
  /// Clear all data (useful for testing)
  void clear() {
    _events.clear();
    _utxos.clear();
    _transactions.clear();
    _walletTransactions.clear();
    _blockHeaders.clear();
    _hashToHeight.clear();
    _orphanedHeaders.clear();
    _merkleProofs.clear();
    _blockToProofs.clear();
    _balanceCache.clear();
    _walletIds.clear();
    _totalEvents = 0;
    _totalUtxos = 0;
    _totalTransactions = 0;
    _totalHeaders = 0;
    _totalProofs = 0;
  }
} 