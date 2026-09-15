import 'package:collection/collection.dart' show mergeSort;

import '../models/bitcoin_utxo.dart';
import '../models/bitcoin_transaction.dart';
import '../models/address_metadata.dart';
import '../models/transaction_address_link.dart';
import '../models/invoice_read_model.dart';
import '../models/payment_channel.dart';
import '../models/deferred_payment.dart';
import '../actors/invoice_messages.dart' show InvoiceStatus;
import 'package:spiffynode/spiffy_node.dart';

export '../models/deferred_payment.dart';

/// Abstract interface for read-model storage operations.
///
/// This interface handles query operations for wallet data projections,
/// including UTXOs, transactions, block headers, and merkle proofs.
/// This represents the "read side" of CQRS pattern.
///
/// Rules every backend follows (audit 2026-09-14 S-15, S-19; contract tests
/// in `test/storage/wallet_lifecycle_contract.dart`):
/// * A wallet exists when its metadata row exists ([storeWallet]); UTXO,
///   transaction or address rows alone do not create a wallet.
/// * [deleteWallet] is a hard delete; storing the wallet again creates it
///   afresh.
/// * Queries for an unknown wallet return empty results (zero balance, null
///   metadata) and never throw.
/// * List queries return the newest rows first (`createdAt` descending):
///   [listWallets], [getWalletIds], [getUTXOs], [getUTXOsByPlugin],
///   [getTransactionHistory], [getTransactionsByStatus],
///   [getAddressesWithMetadata], [getTransactionsByAddress] and the invoice
///   lists.
abstract class ReadModelStorage {
  // ========================================
  // Wallet Metadata
  // ========================================
  
  /// Store or update wallet metadata.
  ///
  /// Creates the wallet when no metadata row exists (including after
  /// [deleteWallet]); otherwise merges into the existing row.
  Future<void> storeWallet(
    String walletId,
    String name, {
    String? rootAddress,
    String? networkType,
    Map<String, dynamic>? metadata,
  });
  
  /// Get wallet metadata; null for an unknown or deleted wallet.
  Future<Map<String, dynamic>?> getWallet(String walletId);

  /// List the IDs of all existing wallets, newest first.
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

  /// The wallet's address rows whose purpose is [purpose] (for example
  /// `watch`), in no particular order. Filtered in the backend: only the
  /// matching rows are loaded (bead libspiffy-p4kv).
  Future<List<AddressMetadata>> getAddressesByPurpose(String walletId, String purpose);

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
  /// Returns: List of UTXOs for the wallet, newest first (empty for an
  /// unknown wallet). `createdAt` and `updatedAt` are returned as stored.
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
  /// The sum of the wallet's [getPaymentUTXOs]: UTXOs with status available
  /// (not pending, reserved or spent), whatever their confirmations, except
  /// those whose plugin metadata names a `pluginId`. Watch-only UTXOs count:
  /// this sum does not filter them (the coordinator's `BalanceResponse`
  /// reports them apart). See spv-understanding.md,
  /// "Balances", for how the other balance APIs differ.
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
  /// (`createdAt` descending); [offset] and [limit] apply to that order.
  /// Every returned transaction carries [walletId].
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

  /// Every wallet's row for each of [txids] (bead libspiffy-ctkm).
  ///
  /// Unlike [getTransactionsBatch], a txid several wallets hold returns one
  /// row per wallet, each with its `walletId`. Txids no wallet holds return
  /// nothing (ancestor transactions are not wallet rows). Rows come newest
  /// first (`createdAt` descending). Backends read only the rows of [txids]
  /// (the txid index), never a wallet's or every wallet's history.
  ///
  /// The default implementation reads every row through
  /// [getTransactionsByStatus]; the libspiffy backends override it.
  Future<List<BitcoinTransaction>> getTransactionsByTxids(List<String> txids) async {
    final wanted = txids.toSet();
    if (wanted.isEmpty) return [];
    final rows = [
      for (final status in TransactionStatus.values)
        for (final tx in await getTransactionsByStatus(status))
          if (wanted.contains(tx.txid)) tx,
    ];
    mergeSort<BitcoinTransaction>(rows, compare: (a, b) => b.createdAt.compareTo(a.createdAt));
    return rows;
  }

  /// Confirmed rows of every wallet whose `blockHeight` is at least
  /// [minHeight]; with [includeWithoutHeight], also confirmed rows that have
  /// no block height (bead libspiffy-ctkm). Rows come newest first
  /// (`createdAt` descending).
  ///
  /// Serves header-chain reorganizations: the confirmations that may rest on
  /// a changed block are found without reading the confirmed history.
  /// Backends read only those rows (a (status, block height) index).
  ///
  /// The default implementation filters
  /// [getTransactionsByStatus]; the libspiffy backends override it.
  Future<List<BitcoinTransaction>> getConfirmedTransactionsFromHeight(
    int minHeight, {
    bool includeWithoutHeight = false,
  }) async {
    return [
      for (final tx in await getTransactionsByStatus(TransactionStatus.confirmed))
        if (tx.blockHeight == null ? includeWithoutHeight : tx.blockHeight! >= minHeight) tx,
    ];
  }

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
  /// Proofs are never deleted (audit bead libspiffy-mny). A transaction has
  /// one row per block its proofs name, plus rows without a block hash for
  /// proofs whose header was not known (told apart by their `merkleProof`).
  /// At most one row per txid is current ([MerkleProof.isCurrent]: verified
  /// or pendingHeader): the transaction's current proof.
  ///
  /// Storing [proof]:
  /// * updates the row with the same (txid, block hash); else the row with
  ///   no block hash and the same `merkleProof` (a
  ///   [MerkleProofStatus.pendingHeader] proof whose header arrived); else,
  ///   when [proof] has no block hash, a row with the same `merkleProof`
  ///   (keeping that row's block hash); otherwise it adds a row. A
  ///   [MerkleProofStatus.rejected] proof is stored without a block hash and
  ///   only ever updates a row that has none (bead libspiffy-azl);
  /// * when [proof] is current, marks every other current row of [txid]
  ///   orphaned (the transaction was mined again in another block): [proof]
  ///   becomes the current proof;
  /// * when [proof] is orphaned or rejected, leaves the current proof alone.
  ///
  /// A row keeps its first `createdAt`; `statusChangedAt` moves when its
  /// status changes ([MerkleProof.statusChangedAt], default now).
  Future<void> storeMerkleProof(String txid, MerkleProof proof);

  /// Mark the current proof of [txid] orphaned: its block left the active
  /// chain (audit 3b0, bead libspiffy-mny). The row is kept and stays readable
  /// through [getMerkleProofHistory]; [getMerkleProof] no longer returns it.
  ///
  /// With [blockHash] the proof is marked only while it names that block (a
  /// proof without a block hash matches any [blockHash]); with
  /// [onlyIfMerkleProof] only while its `merkleProof` equals that list. So a
  /// newer proof stored in the meantime (the transaction re-mined on the
  /// active chain) is left alone. [at] is recorded as `statusChangedAt`
  /// (default now). Returns whether a proof was marked; marking again is a
  /// no-op that returns false.
  Future<bool> markMerkleProofOrphaned(
    String txid, {
    String? blockHash,
    List<String>? onlyIfMerkleProof,
    DateTime? at,
  });

  /// The current proof of [txid]: its one [MerkleProof.isCurrent] row
  /// ([MerkleProofStatus.verified] or [MerkleProofStatus.pendingHeader]), or
  /// null. Orphaned and rejected rows are never returned.
  ///
  /// Parameters:
  /// - [txid]: Transaction ID
  Future<MerkleProof?> getMerkleProof(String txid);

  /// Batch get the current proofs by txid list (see [getMerkleProof]).
  ///
  /// Returns a map of txid → proof for all txids that have a current proof.
  /// Orphaned and rejected proofs are never returned, so BEEFs are never
  /// built from them.
  /// Default implementation loops over single-item getMerkleProof.
  Future<Map<String, MerkleProof>> getMerkleProofsBatch(List<String> txids) async {
    final result = <String, MerkleProof>{};
    for (final txid in txids) {
      final proof = await getMerkleProof(txid);
      if (proof != null) result[txid] = proof;
    }
    return result;
  }

  /// Every proof row stored for [txid], orphaned and rejected ones included,
  /// oldest first.
  Future<List<MerkleProof>> getMerkleProofHistory(String txid);

  /// Every proof row with [status] (for example the
  /// [MerkleProofStatus.pendingHeader] proofs to check once headers arrive).
  Future<List<MerkleProof>> getMerkleProofsByStatus(MerkleProofStatus status);

  /// The current ([MerkleProof.isCurrent]) proofs that name [blockHash].
  ///
  /// Parameters:
  /// - [blockHash]: Block hash as hex string
  Future<List<MerkleProof>> getMerkleProofsForBlock(String blockHash);

  // ========================================
  // Ancestor Transactions (SPV evidence)
  // ========================================
  //
  // Audit bead libspiffy-zsh. A counterparty that pays us with a BEEF for a
  // transaction that is not mined yet includes its ancestors back to mined
  // ones (with their BUMPs). Spending the received output before the payment
  // is mined needs those ancestors again, and nothing can supply them later
  // (no block scanning, no indexer). They are not wallet transactions, so
  // they live apart from the per-wallet transaction rows: keyed by txid only
  // (the raw bytes of a txid are the same for everyone, like its merkle
  // proofs), never listed in a wallet's history, status queries or balance,
  // never returned by [getTransaction] or [getTransactionsBatch], and never
  // deleted, not even by [deleteWallet]. Their BUMPs are stored as merkle
  // proofs ([storeMerkleProof]).

  /// Store the raw transaction [rawHex] of [txid] as ancestor evidence.
  ///
  /// Insert-if-absent: storing a txid that is already present changes
  /// nothing (the row keeps its first `rawHex` and time). The caller checks
  /// that [rawHex] hashes to [txid].
  Future<void> storeAncestorTransaction(String txid, String rawHex);

  /// The raw hex of every stored ancestor transaction among [txids], as a
  /// map txid → rawHex (txids without a row are absent).
  Future<Map<String, String>> getAncestorTransactionsBatch(List<String> txids);

  // ========================================
  // Deferred payments (bead libspiffy-7p2)
  // ========================================
  //
  // Outgoing transactions recorded with a deferred spend, projected from the
  // wallet journal (TransactionSpendDeferredEvent and the events resolving
  // it). Rows are keyed by (walletId, txid) and never deleted except by
  // [deleteWallet]: resolved payments stay listable with their state.

  /// Insert or replace the row of [payment] (key: walletId, txid).
  Future<void> storeDeferredPayment(DeferredPayment payment);

  /// The deferred payment [txid] of [walletId], or null.
  Future<DeferredPayment?> getDeferredPayment(String walletId, String txid);

  /// A page of [walletId]'s deferred payments matching [query], in its
  /// order (createdAt, then txid; newest first unless
  /// [DeferredPaymentQuery.oldestFirst]). Backends answer the default
  /// outstanding-only query from an index on (wallet, state, createdAt),
  /// never by reading every row. Throws [FormatException] for a cursor this
  /// API did not produce.
  Future<DeferredPaymentPage> listDeferredPayments(
    String walletId, {
    DeferredPaymentQuery query = const DeferredPaymentQuery(),
  });

  // ========================================
  // Wallet Management
  // ========================================

  /// Get a list of all wallet IDs in storage.
  ///
  /// The same wallets, in the same order, as [listWallets].
  ///
  /// Returns: List of wallet identifiers
  Future<List<String>> getWalletIds();

  /// Check if a wallet exists in storage.
  ///
  /// Parameters:
  /// - [walletId]: Unique identifier for the wallet
  ///
  /// Returns: true if the wallet's metadata row exists
  Future<bool> walletExists(String walletId);

  /// Delete all data for a specific wallet.
  ///
  /// A hard delete of the wallet's metadata, addresses, UTXOs, transactions,
  /// transaction-address links, invoices and payment channels. Block
  /// headers, merkle proofs and ancestor transactions are shared and stay.
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
  /// Returns: Number of merkle proof rows stored, orphaned ones included
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

/// Where a stored [MerkleProof] stands against the local header chain
/// (audit beads libspiffy-mny, libspiffy-azl).
///
/// Only [verified] and [pendingHeader] proofs are current
/// ([MerkleProof.isCurrent]): at most one per transaction, returned by
/// `getMerkleProof`, put in BEEFs and backing a confirmation. [orphaned] and
/// [rejected] rows are kept for the record (proofs are never deleted).
///
/// Transitions: a proof is stored [verified] when its root matches the
/// active header at its height, [pendingHeader] when no header is known
/// there, [rejected] when the header there contradicts it. A
/// [pendingHeader] proof becomes [verified] or [rejected] when its header
/// arrives (SPVActor). A [verified] proof becomes [orphaned] when its block
/// leaves the active chain. A later proof of the transaction that verifies
/// (the same one against a new active header, or another one) becomes
/// current whatever the earlier rows say.
enum MerkleProofStatus {
  /// Its root matches the header at its height on the active chain.
  verified,

  /// Not yet matched against a header: no header was known at its height
  /// when it was stored. SPVActor checks it when headers arrive; it then
  /// becomes [verified] or [rejected] (and the confirmation is taken back).
  /// Until then it is the transaction's current proof: `getMerkleProof`
  /// returns it and outgoing BEEFs carry it (the receiver verifies it
  /// against its own headers; SPV lets a wallet sign and hand on a
  /// transaction before its own headers have caught up).
  pendingHeader,

  /// It was verified in a block that has left the active chain (a
  /// reorganization). Kept for the record; never a transaction's current
  /// proof and never put in a BEEF.
  orphaned,

  /// The active header at its height contradicts it: the root it computes is
  /// not that header's merkle root, or it cannot be walked to a root at all.
  /// It was never verified on our chain (a forged proof, or one for a block
  /// we do not have), so it has no block hash. Kept for the record; never a
  /// transaction's current proof, never put in a BEEF, never backing a
  /// confirmation, and it never displaces a current proof.
  rejected,
}

/// Merkle proof data for SPV validation
class MerkleProof {
  /// Hash of the block the proof is for; null when no header was known at
  /// [blockHeight] when it was stored.
  final String? blockHash;
  final String txid;
  final List<String> merkleProof; // Since SPV-06: [rawBumpHex]
  final int position; // Position of tx in block
  final int blockHeight;
  final DateTime createdAt;

  /// See [MerkleProofStatus]. Defaults to [MerkleProofStatus.pendingHeader]
  /// when [blockHash] is null, otherwise [MerkleProofStatus.verified].
  final MerkleProofStatus status;

  /// When [status] last changed, if recorded.
  final DateTime? statusChangedAt;

  MerkleProof({
    required this.blockHash,
    required this.txid,
    required this.merkleProof,
    required this.position,
    required this.blockHeight,
    DateTime? createdAt,
    MerkleProofStatus? status,
    this.statusChangedAt,
  })  : createdAt = createdAt ?? DateTime.now(),
        status = status ??
            (blockHash == null ? MerkleProofStatus.pendingHeader : MerkleProofStatus.verified);

  /// The block hash stored before bead mny for a proof whose header was not
  /// known (a [MerkleProofStatus.pendingHeader] proof with no block hash
  /// since). Backends read it as null.
  static const String legacyPendingBlockHash = 'pending';

  /// Whether this proof can be a transaction's current proof:
  /// [MerkleProofStatus.verified] or [MerkleProofStatus.pendingHeader], not
  /// [MerkleProofStatus.orphaned] or [MerkleProofStatus.rejected].
  bool get isCurrent => status == MerkleProofStatus.verified || status == MerkleProofStatus.pendingHeader;

  /// A copy with the given fields replaced ([blockHash] cannot be cleared).
  MerkleProof copyWith({
    String? blockHash,
    int? blockHeight,
    int? position,
    List<String>? merkleProof,
    MerkleProofStatus? status,
    DateTime? statusChangedAt,
  }) {
    return MerkleProof(
      blockHash: blockHash ?? this.blockHash,
      txid: txid,
      merkleProof: merkleProof ?? this.merkleProof,
      position: position ?? this.position,
      blockHeight: blockHeight ?? this.blockHeight,
      createdAt: createdAt,
      status: status ?? this.status,
      statusChangedAt: statusChangedAt ?? this.statusChangedAt,
    );
  }

  /// Whether two `merkleProof` lists are the same proof.
  static bool sameContent(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  Map<String, dynamic> toMap() {
    return {
      'blockHash': blockHash,
      'txid': txid,
      'merkleProof': merkleProof,
      'position': position,
      'blockHeight': blockHeight,
      'createdAt': createdAt.toIso8601String(),
      'status': status.name,
      if (statusChangedAt != null) 'statusChangedAt': statusChangedAt!.toIso8601String(),
    };
  }

  factory MerkleProof.fromMap(Map<String, dynamic> map) {
    final blockHash = map['blockHash'] as String?;
    final status = map['status'] as String?;
    final changedAt = map['statusChangedAt'] as String?;
    return MerkleProof(
      blockHash: blockHash == legacyPendingBlockHash ? null : blockHash,
      txid: map['txid'],
      merkleProof: List<String>.from(map['merkleProof']),
      position: map['position'],
      blockHeight: map['blockHeight'],
      createdAt: DateTime.parse(map['createdAt']),
      status: status == null ? null : MerkleProofStatus.values.byName(status),
      statusChangedAt: changedAt == null ? null : DateTime.parse(changedAt),
    );
  }
}

