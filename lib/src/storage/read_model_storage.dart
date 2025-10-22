import '../models/bitcoin_utxo.dart';
import '../models/bitcoin_transaction.dart';
import 'package:spiffynode/spiffy_node.dart';

/// Abstract interface for read-model storage operations.
///
/// This interface handles query operations for wallet data projections,
/// including UTXOs, transactions, block headers, and merkle proofs.
/// This represents the "read side" of CQRS pattern.
abstract class ReadModelStorage {
  // ========================================
  // Wallet Metadata
  // ========================================
  
  /// Store or update wallet metadata
  Future<void> storeWallet(
    String walletId,
    String name, {
    String? rootAddress,
    String? networkType,
    Map<String, dynamic>? metadata,
  });
  
  /// Get wallet metadata
  Future<Map<String, dynamic>?> getWallet(String walletId);
  
  /// List all wallet IDs
  Future<List<String>> listWallets();
  
  /// Get all addresses for a wallet
  /// 
  /// Used by transaction import to identify wallet outputs.
  /// Returns addresses from UTXO records or address generation events.
  Future<List<String>> getWalletAddresses(String walletId);
  
  // ========================================
  // UTXO Queries
  // ========================================

  /// Get all UTXOs for a specific wallet.
  ///
  /// Parameters:
  /// - [walletId]: Unique identifier for the wallet
  /// - [includeSpent]: Whether to include spent UTXOs (default: false)
  ///
  /// Returns: List of UTXOs for the wallet
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
  Future<List<BitcoinUtxo>> getAvailableUTXOs(String walletId);

  /// Upsert (insert or update) a UTXO in the read model.
  ///
  /// Used by projections to persist UTXO state changes.
  ///
  /// Parameters:
  /// - [walletId]: Unique identifier for the wallet
  /// - [utxo]: UTXO to store
  Future<void> upsertUTXO(String walletId, BitcoinUtxo utxo);

  /// Delete a UTXO from the read model.
  ///
  /// Used by projections when UTXOs are spent.
  ///
  /// Parameters:
  /// - [walletId]: Unique identifier for the wallet
  /// - [txid]: Transaction ID
  /// - [vout]: Output index
  Future<void> deleteUTXO(String walletId, String txid, int vout);

  /// Calculate the total balance for a wallet.
  ///
  /// This should return the sum of all available (unspent) UTXOs
  /// for the wallet, excluding reserved UTXOs.
  ///
  /// Parameters:
  /// - [walletId]: Unique identifier for the wallet
  ///
  /// Returns: Total balance in satoshis
  Future<BigInt> getBalance(String walletId);

  // ========================================
  // Transaction History
  // ========================================

  /// Get transaction history for a wallet
  ///
  /// Parameters:
  /// - [walletId]: Unique identifier for the wallet
  /// - [limit]: Maximum number of transactions to return
  /// - [offset]: Number of transactions to skip
  ///
  /// Returns: List of transactions in reverse chronological order
  Future<List<BitcoinTransaction>> getTransactionHistory(
    String walletId, {
    int? limit,
    int? offset,
  });

  /// Get a specific transaction by ID
  ///
  /// Parameters:
  /// - [txid]: Transaction ID to retrieve
  ///
  /// Returns: Transaction if found, null if not found
  Future<BitcoinTransaction?> getTransaction(String txid);

  /// Store a raw transaction in the read model.
  ///
  /// Used by TransactionImportService to persist historical transaction data
  /// for BEEF construction and transaction history queries.
  ///
  /// Parameters:
  /// - [walletId]: Wallet ID this transaction belongs to
  /// - [transaction]: Transaction to store
  Future<void> storeTransaction(String walletId, BitcoinTransaction transaction);

  // ========================================
  // Block Header Storage (SPV)
  // ========================================

  /// Store a block header at a specific height
  ///
  /// Parameters:
  /// - [header]: Block header to store
  /// - [height]: Block height
  Future<void> storeBlockHeader(BlockHeader header, int height);

  /// Get block header by hash
  ///
  /// Parameters:
  /// - [hash]: Block hash as hex string
  ///
  /// Returns: Block header if found, null if not found
  Future<BlockHeader?> getBlockHeaderByHash(String hash);

  /// Get block header by height
  ///
  /// Parameters:
  /// - [height]: Block height
  ///
  /// Returns: Block header if found, null if not found
  Future<BlockHeader?> getBlockHeaderByHeight(int height);

  /// Get height for a block hash
  ///
  /// Parameters:
  /// - [hash]: Block hash as hex string
  ///
  /// Returns: Block height if found, null if not found
  Future<int?> getHeightByBlockHash(String hash);

  /// Get range of block headers
  ///
  /// Parameters:
  /// - [fromHeight]: Starting height (inclusive)
  /// - [toHeight]: Ending height (inclusive)
  ///
  /// Returns: List of block headers in height order
  Future<List<BlockHeader>> getBlockHeaderRange(int fromHeight, int toHeight);

  /// Mark a block header as orphaned due to reorganization
  ///
  /// Parameters:
  /// - [hash]: Block hash as hex string
  Future<void> markHeaderAsOrphaned(String hash);

  /// Get current chain tip header
  ///
  /// Returns: Current chain tip header, null if no headers stored
  Future<BlockHeader?> getChainTip();

  /// Get current best block height
  ///
  /// Returns: Best known block height, 0 if no headers stored
  Future<int> getBestHeight();

  /// Get recent block headers
  ///
  /// Parameters:
  /// - [count]: Number of recent headers to retrieve
  ///
  /// Returns: List of recent headers in reverse height order (newest first)
  Future<List<BlockHeader>> getRecentHeaders(int count);

  // ========================================
  // Merkle Proof Storage (SPV)
  // ========================================

  /// Store merkle proof for a transaction
  ///
  /// Parameters:
  /// - [txid]: Transaction ID
  /// - [proof]: Merkle proof data
  Future<void> storeMerkleProof(String txid, MerkleProof proof);

  /// Get merkle proof for a transaction
  ///
  /// Parameters:
  /// - [txid]: Transaction ID
  ///
  /// Returns: Merkle proof if found, null if not found
  Future<MerkleProof?> getMerkleProof(String txid);

  /// Get all merkle proofs for a block
  ///
  /// Parameters:
  /// - [blockHash]: Block hash as hex string
  ///
  /// Returns: List of merkle proofs for transactions in the block
  Future<List<MerkleProof>> getMerkleProofsForBlock(String blockHash);

  // ========================================
  // Wallet Management
  // ========================================

  /// Get a list of all wallet IDs in storage.
  ///
  /// This is useful for wallet enumeration and management operations.
  ///
  /// Returns: List of wallet identifiers
  Future<List<String>> getWalletIds();

  /// Check if a wallet exists in storage.
  ///
  /// Parameters:
  /// - [walletId]: Unique identifier for the wallet
  ///
  /// Returns: true if the wallet exists, false otherwise
  Future<bool> walletExists(String walletId);

  /// Delete all data for a specific wallet.
  ///
  /// This operation should remove all read model data for the wallet.
  /// Use with caution.
  ///
  /// Parameters:
  /// - [walletId]: Unique identifier for the wallet
  Future<void> deleteWallet(String walletId);

  // ========================================
  // Invoice Operations
  // ========================================

  /// Store an invoice in the read model.
  ///
  /// Parameters:
  /// - [invoice]: Invoice to store
  Future<void> storeInvoice(dynamic invoice);

  /// Get a specific invoice by ID.
  ///
  /// Parameters:
  /// - [invoiceId]: Unique identifier for the invoice
  ///
  /// Returns: Invoice if found, null if not found
  Future<dynamic> getInvoice(String invoiceId);

  /// Get all invoices for a specific wallet.
  ///
  /// Parameters:
  /// - [walletId]: Unique identifier for the wallet
  ///
  /// Returns: List of invoices for the wallet
  Future<List<dynamic>> getInvoicesByWallet(String walletId);

  /// Get all invoices with a specific status.
  ///
  /// Parameters:
  /// - [status]: Invoice status to filter by
  /// - [walletId]: Optional wallet ID to filter further
  ///
  /// Returns: List of invoices matching the status
  Future<List<dynamic>> getInvoicesByStatus(dynamic status, {String? walletId});

  /// Update the status of an invoice.
  ///
  /// Parameters:
  /// - [invoiceId]: Unique identifier for the invoice
  /// - [status]: New status for the invoice
  /// - [txid]: Transaction ID if paid
  /// - [amountReceived]: Amount received if paid
  /// - [paidAt]: Timestamp when paid
  Future<void> updateInvoiceStatus(
    String invoiceId,
    dynamic status, {
    String? txid,
    BigInt? amountReceived,
    DateTime? paidAt,
  });

  /// Get the count of stored merkle proofs.
  ///
  /// Parameters:
  /// - [walletId]: Optional wallet ID to count proofs for a specific wallet
  ///
  /// Returns: Number of merkle proofs stored
  Future<int> getMerkleProofCount({String? walletId});
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

