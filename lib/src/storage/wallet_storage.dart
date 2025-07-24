import '../models/wallet_event.dart';
import '../models/bitcoin_utxo.dart';

/// Abstract interface for wallet data storage operations.
/// 
/// This interface provides both event sourcing operations (events, snapshots)
/// and query operations (read model projections) for wallet data.
/// 
/// Implementations should provide:
/// - Event store operations for event sourcing
/// - Snapshot operations for performance optimization  
/// - UTXO queries for balance calculations and transaction building
/// - Transaction queries for wallet history
abstract class WalletStorage {
  // ========================================
  // Event Store Operations
  // ========================================
  
  /// Save a list of events for a specific wallet.
  /// 
  /// Events should be saved atomically - either all events are saved
  /// or none are saved. The implementation should handle concurrency
  /// and ensure event ordering is maintained.
  /// 
  /// Parameters:
  /// - [walletId]: Unique identifier for the wallet
  /// - [events]: List of events to save
  /// 
  /// Throws [StorageException] if the save operation fails
  Future<void> saveEvents(String walletId, List<WalletEvent> events);
  
  /// Load events for a specific wallet, optionally starting from a version.
  /// 
  /// Events should be returned in the order they were saved.
  /// If [fromVersion] is provided, only events after that version
  /// should be returned.
  /// 
  /// Parameters:
  /// - [walletId]: Unique identifier for the wallet
  /// - [fromVersion]: Optional version number to start loading from
  /// 
  /// Returns: List of events in chronological order
  /// 
  /// Throws [StorageException] if the load operation fails
  Future<List<WalletEvent>> loadEvents(String walletId, {int? fromVersion});
  
  // ========================================
  // UTXO Queries (Read Model)
  // ========================================
  
  /// Get all UTXOs for a specific wallet.
  /// 
  /// Parameters:
  /// - [walletId]: Unique identifier for the wallet
  /// - [includeSpent]: Whether to include spent UTXOs (default: false)
  /// 
  /// Returns: List of UTXOs for the wallet
  /// 
  /// Throws [StorageException] if the query fails
  Future<List<BitcoinUtxo>> getUTXOs(String walletId, {bool includeSpent = false});
  
  /// Get only available (unspent and unreserved) UTXOs for a wallet.
  /// 
  /// This is the primary method for transaction building, as it returns
  /// only UTXOs that can be spent immediately.
  /// 
  /// Parameters:
  /// - [walletId]: Unique identifier for the wallet
  /// 
  /// Returns: List of available UTXOs
  /// 
  /// Throws [StorageException] if the query fails
  Future<List<BitcoinUtxo>> getAvailableUTXOs(String walletId);
  
  /// Calculate the total balance for a wallet.
  /// 
  /// This should return the sum of all available (unspent) UTXOs
  /// for the wallet, excluding reserved UTXOs.
  /// 
  /// Parameters:
  /// - [walletId]: Unique identifier for the wallet
  /// 
  /// Returns: Total balance in satoshis
  /// 
  /// Throws [StorageException] if the calculation fails
  Future<BigInt> getBalance(String walletId);
  
  // ========================================
  // Wallet Management
  // ========================================
  
  /// Get a list of all wallet IDs in storage.
  /// 
  /// This is useful for wallet enumeration and management operations.
  /// 
  /// Returns: List of wallet identifiers
  /// 
  /// Throws [StorageException] if the query fails
  Future<List<String>> getWalletIds();
  
  /// Check if a wallet exists in storage.
  /// 
  /// Parameters:
  /// - [walletId]: Unique identifier for the wallet
  /// 
  /// Returns: true if the wallet exists, false otherwise
  /// 
  /// Throws [StorageException] if the check fails
  Future<bool> walletExists(String walletId);
  
  /// Delete all data for a specific wallet.
  /// 
  /// This operation should remove all events, snapshots, and
  /// read model data for the wallet. Use with caution.
  /// 
  /// Parameters:
  /// - [walletId]: Unique identifier for the wallet
  /// 
  /// Throws [StorageException] if the delete operation fails
  Future<void> deleteWallet(String walletId);
}

/// Exception thrown when storage operations fail.
class StorageException implements Exception {
  final String message;
  final Object? cause;
  
  const StorageException(this.message, [this.cause]);
  
  @override
  String toString() {
    if (cause != null) {
      return 'StorageException: $message (caused by: $cause)';
    }
    return 'StorageException: $message';
  }
} 