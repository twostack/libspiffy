import '../models/wallet_event.dart';
import '../models/bitcoin_utxo.dart';
import '../models/bitcoin_transaction.dart';
import 'package:spiffynode/spiffy_node.dart'; // For BlockHeader

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
  // Transaction History (Read Model)
  // ========================================

  /// Get transaction history for a wallet
  /// 
  /// Parameters:
  /// - [walletId]: Unique identifier for the wallet
  /// - [limit]: Maximum number of transactions to return
  /// - [offset]: Number of transactions to skip
  /// 
  /// Returns: List of transactions in reverse chronological order
  /// 
  /// Throws [StorageException] if the query fails
  Future<List<BitcoinTransaction>> getTransactionHistory(String walletId, {int? limit, int? offset});

  /// Get a specific transaction by ID
  /// 
  /// Parameters:
  /// - [txid]: Transaction ID to retrieve
  /// 
  /// Returns: Transaction if found, null if not found
  /// 
  /// Throws [StorageException] if the query fails
  Future<BitcoinTransaction?> getTransaction(String txid);

  // ========================================
  // Block Header Storage (SPV)
  // ========================================

  /// Store a block header at a specific height
  /// 
  /// Parameters:
  /// - [header]: Block header to store
  /// - [height]: Block height
  /// 
  /// Throws [StorageException] if the store operation fails
  Future<void> storeBlockHeader(BlockHeader header, int height);

  /// Get block header by hash
  /// 
  /// Parameters:
  /// - [hash]: Block hash as hex string
  /// 
  /// Returns: Block header if found, null if not found
  /// 
  /// Throws [StorageException] if the query fails
  Future<BlockHeader?> getBlockHeaderByHash(String hash);

  /// Get block header by height
  /// 
  /// Parameters:
  /// - [height]: Block height
  /// 
  /// Returns: Block header if found, null if not found
  /// 
  /// Throws [StorageException] if the query fails
  Future<BlockHeader?> getBlockHeaderByHeight(int height);

  /// Get height for a block hash
  /// 
  /// Parameters:
  /// - [hash]: Block hash as hex string
  /// 
  /// Returns: Block height if found, null if not found
  /// 
  /// Throws [StorageException] if the query fails
  Future<int?> getHeightByBlockHash(String hash);

  /// Get range of block headers
  /// 
  /// Parameters:
  /// - [fromHeight]: Starting height (inclusive)
  /// - [toHeight]: Ending height (inclusive)
  /// 
  /// Returns: List of block headers in height order
  /// 
  /// Throws [StorageException] if the query fails
  Future<List<BlockHeader>> getBlockHeaderRange(int fromHeight, int toHeight);

  /// Mark a block header as orphaned due to reorganization
  /// 
  /// Parameters:
  /// - [hash]: Block hash as hex string
  /// 
  /// Throws [StorageException] if the operation fails
  Future<void> markHeaderAsOrphaned(String hash);

  /// Get current chain tip header
  /// 
  /// Returns: Current chain tip header, null if no headers stored
  /// 
  /// Throws [StorageException] if the query fails
  Future<BlockHeader?> getChainTip();

  /// Get current best block height
  /// 
  /// Returns: Best known block height, 0 if no headers stored
  /// 
  /// Throws [StorageException] if the query fails
  Future<int> getBestHeight();

  /// Get recent block headers
  /// 
  /// Parameters:
  /// - [count]: Number of recent headers to retrieve
  /// 
  /// Returns: List of recent headers in reverse height order (newest first)
  /// 
  /// Throws [StorageException] if the query fails
  Future<List<BlockHeader>> getRecentHeaders(int count);

  // ========================================
  // Merkle Proof Storage (SPV)
  // ========================================

  /// Store merkle proof for a transaction
  /// 
  /// Parameters:
  /// - [txid]: Transaction ID
  /// - [proof]: Merkle proof data
  /// 
  /// Throws [StorageException] if the store operation fails
  Future<void> storeMerkleProof(String txid, MerkleProof proof);

  /// Get merkle proof for a transaction
  /// 
  /// Parameters:
  /// - [txid]: Transaction ID
  /// 
  /// Returns: Merkle proof if found, null if not found
  /// 
  /// Throws [StorageException] if the query fails
  Future<MerkleProof?> getMerkleProof(String txid);

  /// Get all merkle proofs for a block
  /// 
  /// Parameters:
  /// - [blockHash]: Block hash as hex string
  /// 
  /// Returns: List of merkle proofs for transactions in the block
  /// 
  /// Throws [StorageException] if the query fails
  Future<List<MerkleProof>> getMerkleProofsForBlock(String blockHash);
  
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

/// Merkle proof data for SPV validation
class MerkleProof {
  final String blockHash;
  final String txid;
  final List<String> merkleProof; // Sibling hashes in merkle tree
  final int position; // Position of tx in block
  final int blockHeight;
  final DateTime createdAt;

  MerkleProof({
    required this.blockHash,
    required this.txid,
    required this.merkleProof,
    required this.position,
    required this.blockHeight,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  Map<String, dynamic> toMap() {
    return {
      'blockHash': blockHash,
      'txid': txid,
      'merkleProof': merkleProof,
      'position': position,
      'blockHeight': blockHeight,
      'createdAt': createdAt.toIso8601String(),
    };
  }

  factory MerkleProof.fromMap(Map<String, dynamic> map) {
    return MerkleProof(
      blockHash: map['blockHash'],
      txid: map['txid'],
      merkleProof: List<String>.from(map['merkleProof']),
      position: map['position'],
      blockHeight: map['blockHeight'],
      createdAt: DateTime.parse(map['createdAt']),
    );
  }
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