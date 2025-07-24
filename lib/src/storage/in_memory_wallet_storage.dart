import 'dart:async';
import '../models/wallet_event.dart';
import '../models/bitcoin_utxo.dart';
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
  
  // Balance cache: walletId -> balance
  final Map<String, BigInt> _balanceCache = {};
  
  // Wallet existence tracking
  final Set<String> _walletIds = {};
  
  // Synchronization for thread safety
  final Map<String, Completer<void>?> _locks = {};
  
  // Statistics
  int _totalEvents = 0;
  int _totalUtxos = 0;
  
  /// Get storage statistics for monitoring
  Map<String, dynamic> get statistics => {
    'totalWallets': _walletIds.length,
    'totalEvents': _totalEvents,
    'totalUtxos': _totalUtxos,
    'memoryUsage': {
      'events': _events.length,
      'utxos': _utxos.length,
      'balanceCache': _balanceCache.length,
    },
  };
  
  /// Clear all cached balances (useful for testing)
  void clearBalanceCache() {
    _balanceCache.clear();
  }
  
  @override
  Future<void> saveEvents(String walletId, List<WalletEvent> events) async {
    if (events.isEmpty) return;
    
    await _withLock(walletId, () async {
      // Initialize wallet if it doesn't exist
      _walletIds.add(walletId);
      _events.putIfAbsent(walletId, () => <WalletEvent>[]);
      
      // Add events in order
      final walletEvents = _events[walletId]!;
      walletEvents.addAll(events);
      
      // Sort by version to maintain order
      walletEvents.sort((a, b) => a.version.compareTo(b.version));
      
      _totalEvents += events.length;
      
      // Invalidate balance cache since wallet state changed
      _balanceCache.remove(walletId);
    });
  }
  
  @override
  Future<List<WalletEvent>> loadEvents(String walletId, {int? fromVersion}) async {
    return await _withLock(walletId, () async {
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
      final walletUtxos = _utxos[walletId] ?? <String, BitcoinUtxo>{};
      
      return walletUtxos.values
          .where((utxo) => includeSpent || !utxo.isSpent)
          .toList();
    });
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
  Future<BigInt> getBalance(String walletId) async {
    return await _withLock(walletId, () async {
      // Check cache first  
      if (_balanceCache.containsKey(walletId)) {
        return _balanceCache[walletId]!;
      }
      
      // Calculate balance from available UTXOs
      final availableUtxos = await getAvailableUTXOs(walletId);
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
  
  /// Clear all data (useful for testing)
  void clear() {
    _events.clear();
    _utxos.clear();
    _balanceCache.clear();
    _walletIds.clear();
    _totalEvents = 0;
    _totalUtxos = 0;
  }
} 