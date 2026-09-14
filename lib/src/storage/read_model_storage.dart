import '../models/bitcoin_utxo.dart';
import '../models/bitcoin_transaction.dart';
import '../models/address_metadata.dart';
import '../models/transaction_address_link.dart';
import '../models/invoice_read_model.dart';
import '../models/payment_channel.dart';
import '../actors/invoice_messages.dart' show InvoiceStatus;
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
  // Address Management
  // ========================================

  /// Check if an address belongs to a wallet (O(1) hash lookup)
  Future<bool> isWalletAddress(String walletId, String address);

  /// Get address metadata if it belongs to wallet
  Future<AddressMetadata?> getAddressMetadata(String walletId, String address);

  /// Batch check if addresses belong to wallet (optimized for bulk operations)
  Future<Map<String, bool>> checkAddresses(String walletId, List<String> addresses);

  /// Get all addresses for a wallet with pagination
  Future<List<AddressMetadata>> getAddressesWithMetadata(
    String walletId, {
    bool? includeUnused,
    bool? isChange,
    int? limit,
    int? offset,
  });

  /// Get addresses by derivation range (efficient for HD wallets)
  Future<List<AddressMetadata>> getAddressRange(
    String walletId, {
    required int startIndex,
    required int count,
    bool isChange = false,
  });

  /// Store or update address metadata
  Future<void> upsertAddress(String walletId, AddressMetadata metadata);
  
  /// Get the count of addresses for a wallet (for verification during import)
  Future<int> getAddressCount(String walletId);

  /// Update address usage statistics.
  ///
  /// [usedAt] records a use (first/last used, usage count + 1);
  /// [balanceDelta] adjusts the balance. A call with only a balance delta
  /// (a spend) does not count as a use.
  Future<void> updateAddressUsage(
    String walletId,
    String address, {
    DateTime? usedAt,
    BigInt? balanceDelta,
  });

  // ========================================
  // Transaction-Address Junction (Address-Centric Queries)
  // ========================================

  /// Store transaction-address junction records.
  ///
  /// Replaces the links previously stored for ([walletId], [txid]), so a
  /// projection replay leaves exactly one set of rows.
  Future<void> storeTransactionAddresses(
    String walletId,
    String txid,
    List<TransactionAddressLink> links,
  );

  /// Get all transactions involving a specific address
  Future<List<String>> getTransactionsByAddress(
    String walletId,
    String address, {
    String? direction, // 'input', 'output', or null for both
    int? limit,
    int? offset,
  });

  /// Get all addresses involved in a transaction
  Future<TransactionAddresses> getTransactionAddresses(
    String walletId,
    String txid,
  );

  /// Get transaction count for an address
  Future<int> getAddressTransactionCount(String walletId, String address);
  
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

  /// Get available UTXOs suitable for BSV payments.
  ///
  /// Like [getAvailableUTXOs] but excludes UTXOs whose plugin metadata names
  /// a `pluginId` (e.g. token scripts). These UTXOs are managed by their
  /// respective plugins and must not be selected as funding inputs for
  /// ordinary payments. Metadata without a `pluginId` (script analysis of a
  /// plain P2PKH output) does not exclude a UTXO. Same rule on every backend.
  Future<List<BitcoinUtxo>> getPaymentUTXOs(String walletId);

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

  /// Get UTXOs managed by a specific plugin.
  ///
  /// Filters UTXOs whose [BitcoinUtxo.pluginMetadata] contains a matching
  /// 'pluginId'. Optionally filters further by additional metadata keys.
  ///
  /// Parameters:
  /// - [walletId]: Unique identifier for the wallet
  /// - [pluginId]: Plugin identifier to filter by
  /// - [metadataFilter]: Optional additional key-value pairs that must match
  ///   within pluginMetadata (e.g., {'scriptType': 'pp1_nft', 'tokenId': '...'})
  ///
  /// Returns: List of matching UTXOs
  Future<List<BitcoinUtxo>> getUTXOsByPlugin(
    String walletId,
    String pluginId, {
    Map<String, dynamic>? metadataFilter,
  });

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

  /// Get a specific transaction by ID.
  ///
  /// Transactions are stored per wallet (audit 2026-09-14 S-05): when wallet
  /// A pays wallet B in the same store, each wallet has its own row for the
  /// txid with its own `netAmount`, direction and status.
  ///
  /// Parameters:
  /// - [txid]: Transaction ID to retrieve
  /// - [walletId]: the wallet whose row to return. Pass it whenever the
  ///   wallet-specific fields matter. When null, the row of the wallet that
  ///   stored the txid first is returned; its wallet-independent fields
  ///   (`rawHex`, `fee`, input/output values) are the same for every wallet.
  ///
  /// Returns: Transaction if found, null if not found
  Future<BitcoinTransaction?> getTransaction(String txid, {String? walletId});

  /// Batch get transactions by txid list
  ///
  /// Returns a map of txid → transaction for all found transactions. Like
  /// [getTransaction] without a wallet id, a txid stored by several wallets
  /// maps to the row of the wallet that stored it first.
  /// Default implementation loops over single-item getTransaction.
  Future<Map<String, BitcoinTransaction>> getTransactionsBatch(List<String> txids) async {
    final result = <String, BitcoinTransaction>{};
    for (final txid in txids) {
      final tx = await getTransaction(txid);
      if (tx != null) result[txid] = tx;
    }
    return result;
  }

  /// Get transactions by status
  /// 
  /// Parameters:
  /// - [status]: Transaction status to filter by
  /// - [walletId]: Optional wallet ID to filter by specific wallet
  /// 
  /// Returns: List of transactions matching the status
  Future<List<BitcoinTransaction>> getTransactionsByStatus(
    TransactionStatus status, {
    String? walletId,
  });

  /// Store a raw transaction in the read model.
  ///
  /// Used by TransactionImportService to persist historical transaction data
  /// for BEEF construction and transaction history queries.
  ///
  /// Inserts or updates the row keyed by ([walletId], txid); another
  /// wallet's row for the same txid is never touched.
  ///
  /// Parameters:
  /// - [walletId]: Wallet ID this transaction belongs to
  /// - [transaction]: Transaction to store
  Future<void> storeTransaction(String walletId, BitcoinTransaction transaction);

  // ========================================
  // Block Header Storage (SPV)
  // ========================================

  /// Store a block header as part of the active chain at [height].
  ///
  /// An upsert keyed by the block hash: storing a hash that is already
  /// present is idempotent, and storing a header that was orphaned earlier
  /// (a reorganization back onto a previous branch) clears its orphan flag
  /// and sets its height. Retire headers with [markHeaderAsOrphaned].
  ///
  /// Parameters:
  /// - [header]: Block header to store
  /// - [height]: Block height
  Future<void> storeBlockHeader(BlockHeader header, int height);

  /// Bulk store block headers for fast initial sync (CDN import).
  ///
  /// Same upsert semantics as [storeBlockHeader].
  ///
  /// Parameters:
  /// - [headers]: List of (BlockHeader, height) pairs to store
  ///
  /// Implementations should use batch/transaction writes for performance.
  /// Default implementation falls back to sequential storeBlockHeader calls.
  Future<void> storeBlockHeadersBulk(List<(BlockHeader, int)> headers) async {
    for (final (header, height) in headers) {
      await storeBlockHeader(header, height);
    }
  }

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

  /// Store merkle proof for a transaction.
  ///
  /// There is at most one proof per txid: a later proof (for example after
  /// the transaction was re-mined in another block during a reorganization)
  /// replaces the earlier one.
  ///
  /// Parameters:
  /// - [txid]: Transaction ID
  /// - [proof]: Merkle proof data
  Future<void> storeMerkleProof(String txid, MerkleProof proof);

  /// Delete the merkle proof of [txid] (audit 3b0: a proof whose block left
  /// the active chain, or that does not match its block header).
  ///
  /// With [onlyIfMerkleProof] the proof is deleted only while its
  /// `merkleProof` still equals that list, so a newer proof stored in the
  /// meantime (the transaction re-mined on the active chain) survives.
  /// Returns whether a proof was deleted.
  Future<bool> deleteMerkleProof(String txid, {List<String>? onlyIfMerkleProof});

  /// Get merkle proof for a transaction
  ///
  /// Parameters:
  /// - [txid]: Transaction ID
  ///
  /// Returns: Merkle proof if found, null if not found
  Future<MerkleProof?> getMerkleProof(String txid);

  /// Batch get merkle proofs by txid list
  ///
  /// Returns a map of txid → proof for all txids that have proofs.
  /// Default implementation loops over single-item getMerkleProof.
  Future<Map<String, MerkleProof>> getMerkleProofsBatch(List<String> txids) async {
    final result = <String, MerkleProof>{};
    for (final txid in txids) {
      final proof = await getMerkleProof(txid);
      if (proof != null) result[txid] = proof;
    }
    return result;
  }

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
  //
  // Every backend stores and returns the [InvoiceReadModel] that
  // `InvoiceProjection` builds (audit 2026-09-14 S-07). Structured outputs
  // must survive the round trip.

  /// Store an invoice read model (insert, or replace an existing row with
  /// the same `invoiceId`).
  Future<void> storeInvoice(InvoiceReadModel invoice);

  /// Get a specific invoice by ID.
  ///
  /// Returns: the invoice read model if found, null if not found
  Future<InvoiceReadModel?> getInvoice(String invoiceId);

  /// List invoices, newest first.
  ///
  /// Parameters:
  /// - [walletId]: restrict to one wallet (null = every wallet)
  /// - [status]: restrict to one status (null = every status)
  Future<List<InvoiceReadModel>> listInvoices({
    String? walletId,
    InvoiceStatus? status,
  });

  /// Get all invoices for a specific wallet, newest first.
  ///
  /// Equivalent to `listInvoices(walletId: walletId)`.
  Future<List<InvoiceReadModel>> getInvoicesByWallet(String walletId);

  /// Get all invoices with a specific status, newest first.
  ///
  /// Equivalent to `listInvoices(status: status, walletId: walletId)`.
  Future<List<InvoiceReadModel>> getInvoicesByStatus(
    InvoiceStatus status, {
    String? walletId,
  });

  /// Update the status of an invoice.
  ///
  /// [txid], [amountReceived] and [paidAt] replace the stored values only
  /// when non-null; an unknown [invoiceId] is a no-op.
  Future<void> updateInvoiceStatus(
    String invoiceId,
    InvoiceStatus status, {
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

  // ========================================
  // Payment Channel Storage
  // ========================================
  //
  // Typed on the domain [PaymentChannel] (audit 2026-09-14 S-01). Backends
  // convert to their own row/entity representation internally; callers
  // never see an Isar entity.

  /// Store a payment channel (insert, or replace every mutable column of an
  /// existing row with the same `channelId`).
  Future<void> storePaymentChannel(PaymentChannel channel);

  /// Get a payment channel by ID.
  Future<PaymentChannel?> getPaymentChannel(String channelId);

  /// Get all payment channels for a wallet.
  Future<List<PaymentChannel>> getPaymentChannelsForWallet(String walletId);

  /// Update payment channel state.
  ///
  /// [state] is a [PaymentChannelState] name (`PaymentChannelState.name`).
  Future<void> updatePaymentChannelState(String channelId, String state);

  /// Update payment channel balances
  Future<void> updatePaymentChannelBalance(
    String channelId,
    BigInt clientBalance,
    BigInt serverBalance,
  );

  /// Delete a payment channel
  Future<void> deletePaymentChannel(String channelId);
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

