import 'package:collection/collection.dart' show mergeSort;
import 'package:dartsv/dartsv.dart' as dartsv;

import '../models/bitcoin_utxo.dart';
import '../models/bitcoin_transaction.dart';
import '../models/address_metadata.dart';
import '../models/transaction_address_link.dart';
import '../models/invoice_read_model.dart';
import '../models/payment_channel.dart';
import '../models/deferred_payment.dart';
import '../models/pending_receive.dart';
import '../actors/invoice_messages.dart' show InvoiceStatus;
import 'package:spiffynode/spiffy_node.dart';

export '../models/deferred_payment.dart';
export '../models/pending_receive.dart';

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
  /// [deleteWallet]); otherwise merges into the existing row: a null
  /// [rootAddress], [networkType] or [metadata] keeps what is stored, and a
  /// [metadata] map is merged key by key, so a caller may resupply only the
  /// keys it changed.
  ///
  /// A store never removes a metadata key. Writing a key null blanks it and
  /// keeps it; the whole document goes only with [deleteWallet].
  ///
  /// [networkType] is canonicalised on the way in
  /// (`WalletRowRules.canonicalNetwork`), so the `'main'` / `'test'` /
  /// `'regtest'` spelling the actor system, importer and P2P layer use is
  /// stored as the read model's own `'mainnet'` / `'testnet'` / `'regtest'`
  /// and never sits in a row beside it. A wallet CREATED without a network
  /// gets `WalletRowRules.defaultNetwork` -- testnet, which is what
  /// `NetworkName` and the wallet aggregate resolve an unspecified network
  /// to (bead libspiffy-sxk5). It used to be `'mainnet'` on all three
  /// backends, so a caller who omitted [networkType] created a row that read
  /// back as mainnet -- MAIN address encoding -- for a wallet the aggregate
  /// considered testnet.
  Future<void> storeWallet(
    String walletId,
    String name, {
    String? rootAddress,
    String? networkType,
    Map<String, dynamic>? metadata,
  });
  
  /// Get wallet metadata; null for an unknown or deleted wallet. The
  /// `metadata` entry is a map, empty when the wallet has none, never null.
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
  /// The spendable part of the wallet's [getPaymentUTXOs] (UTXOs with status
  /// available, whatever their confirmations, whose plugin metadata names no
  /// `pluginId`): watch-only UTXOs (at a watch address the wallet holds no
  /// key for, reported by [getWatchOnlyBalance]) and bare multisig UTXOs the
  /// wallet's keys cannot spend alone (kept from a journal written before
  /// bead viy) are left out (beads libspiffy-vsap, libspiffy-0k8). The same
  /// UTXOs as `WalletState.availableBalance` on the wallet aggregate and the
  /// coordinator's `BalanceResponse.totalBalance`. See spv-understanding.md,
  /// "Balances", for how the other balance APIs differ.
  ///
  /// Parameters:
  /// - [walletId]: Unique identifier for the wallet
  ///
  /// Returns: Total balance in satoshis
  Future<BigInt> getBalance(String walletId);

  /// The watch-only part of the wallet's [getPaymentUTXOs]: available UTXOs
  /// the wallet holds no key for because a key they need is a watch address
  /// (bead libspiffy-vsap). Not part of [getBalance]; the coordinator's
  /// `BalanceResponse.watchOnlyBalance`.
  Future<BigInt> getWatchOnlyBalance(String walletId);

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

  /// The rows with [status] last updated at or after [since], newest first
  /// (`updatedAt` descending), at most [limit] of them (bead libspiffy-5bju).
  ///
  /// A bounded feed of recently changed rows, for work that must revisit a
  /// terminal state without ever reading its whole history: ARCActor polls
  /// recently failed transactions this way, because a transaction ARC
  /// reported REJECTED can still be mined (a competing spend loses, or the
  /// report was stale) and nothing else would ever ask again. Reading every
  /// failed row the wallet ever had, on a timer, is what the window and the
  /// cap exist to prevent.
  ///
  /// [limit] must be positive. Rows whose `updatedAt` was never stored are
  /// read as their `createdAt` (the backends store it that way).
  ///
  /// The default implementation filters [getTransactionsByStatus] and so is
  /// not bounded at the storage layer; the libspiffy backends override it.
  Future<List<BitcoinTransaction>> getTransactionsByStatusSince(
    TransactionStatus status,
    DateTime since, {
    int limit = 100,
  }) async {
    final rows = [
      for (final tx in await getTransactionsByStatus(status))
        if (!tx.updatedAt.isBefore(since)) tx,
    ];
    mergeSort<BitcoinTransaction>(rows, compare: (a, b) => b.updatedAt.compareTo(a.updatedAt));
    return rows.length <= limit ? rows : rows.sublist(0, limit);
  }

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
  /// An update never lowers the stored status (bead libspiffy-7dj,
  /// `TransactionRowRules.setsStatus`): a confirmed row keeps its status,
  /// block height and confirmations whatever a later record says, and a row
  /// does not go back along created, signed, broadcast / pending,
  /// seenOnNetwork. Take a confirmation back with
  /// [storeRevertedTransaction]. An update without raw hex keeps the stored
  /// bytes; a confirmed update without a block height keeps the stored one.
  ///
  /// [BitcoinTransaction.counterpartyMarker] — the app's opaque marker for
  /// the counterparty the payment was with (bead libspiffy-cq16,
  /// spv-understanding.md requirement 5) — is set once, by the first record
  /// that carries one, and no later update blanks it or replaces it with a
  /// different value, a revert included
  /// ([TransactionRowRules.counterpartyMarkerAfter]). It is stored verbatim
  /// and never interpreted, and it is not the address-derived counterparty
  /// a backend may also keep.
  ///
  /// Parameters:
  /// - [walletId]: Wallet ID this transaction belongs to
  /// - [transaction]: Transaction to store
  Future<void> storeTransaction(String walletId, BitcoinTransaction transaction);

  /// Stores [transaction] as the row of ([walletId], txid) with the status,
  /// block height and confirmations it carries, even when that lowers a
  /// confirmed status: the one way a confirmation is taken back, used for a
  /// reorganization past the confirming block or a proof its block header
  /// contradicts (audit 3b0, bead libspiffy-7dj). A non-confirmed record
  /// clears the stored block height. Raw hex and the other rules of
  /// [storeTransaction] apply; nothing is deleted.
  ///
  /// The default implementation calls [storeTransaction] (for a backend
  /// without the status rule); the libspiffy backends override it.
  Future<void> storeRevertedTransaction(String walletId, BitcoinTransaction transaction) =>
      storeTransaction(walletId, transaction);

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
  /// active chain) is left alone. A marked proof without a block hash
  /// records [blockHash] (the block that left the chain; a read model rebuilt
  /// from the journal meets such a proof before its header, bead
  /// libspiffy-yix) unless another row of [txid] already names that block.
  /// [at] is recorded as `statusChangedAt` (default now). Returns whether a
  /// proof was marked; marking again is a no-op that returns false.
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

  /// The proof rows with [status] whose block height is between [fromHeight]
  /// and [toHeight] (both inclusive), oldest first (bead libspiffy-hg0).
  ///
  /// Serves header-chain reorganizations: the orphaned and rejected proofs at
  /// the heights whose active header changed are checked again without
  /// reading every orphaned or rejected proof ever stored. Backends read only
  /// those rows (a (status, block height) index).
  ///
  /// The default implementation filters [getMerkleProofsByStatus]; the
  /// libspiffy backends override it.
  Future<List<MerkleProof>> getMerkleProofsByStatusBetweenHeights(
    MerkleProofStatus status,
    int fromHeight,
    int toHeight,
  ) async {
    return [
      for (final proof in await getMerkleProofsByStatus(status))
        if (proof.blockHeight >= fromHeight && proof.blockHeight <= toHeight) proof,
    ];
  }

  /// The proof rows with [status] whose status changed at or after [since]
  /// ([MerkleProof.statusChangedAt]), oldest first (bead libspiffy-hccp).
  /// Rows without a `statusChangedAt` are not returned.
  ///
  /// Serves SPVActor's check for confirmations resting only on a rejected
  /// proof: each header notification reads the proofs that became rejected
  /// (or orphaned) since the previous check, not every rejected proof ever
  /// stored. Backends read only those rows (a (status, status changed at)
  /// index).
  ///
  /// The default implementation filters [getMerkleProofsByStatus]; the
  /// libspiffy backends override it.
  Future<List<MerkleProof>> getMerkleProofsByStatusChangedSince(
    MerkleProofStatus status,
    DateTime since,
  ) async {
    return [
      for (final proof in await getMerkleProofsByStatus(status))
        if (proof.statusChangedAt case final changedAt? when !changedAt.isBefore(since)) proof,
    ];
  }

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
  // Parked receives (bead libspiffy-vfai)
  // ========================================
  //
  // A BEEF whose merkle proof names a block our headers have not reached
  // proves nothing yet, so the receive waits (bead libspiffy-68mz). Its
  // evidence is retained above; these rows are the waiting receive itself, so
  // that the wallet is still credited when the header arrives after a
  // restart. Keyed by (walletId, txid), never deleted except by
  // [deleteWallet] (a row of a receive that named no wallet is not a wallet's
  // row and survives even that).

  /// Park [receive] until headers reach its `neededHeight`, or update the row
  /// already parked for its (walletId, txid).
  ///
  /// An update keeps the stored `createdAt` and clears any resolution: the
  /// receive is waiting again. Storing a receive the caller has judged
  /// (`resolvedAt` set) records that outcome.
  Future<void> storePendingReceive(PendingReceive receive);

  /// The parked receive of ([walletId], [txid]), resolved or not.
  Future<PendingReceive?> getPendingReceive(String walletId, String txid);

  /// The receives still waiting ([PendingReceive.isWaiting]) whose
  /// `neededHeight` is at most [height], oldest first, at most [limit] of
  /// them.
  ///
  /// SPVActor replays these when headers reach [height]. The cap bounds one
  /// replay pass: the rest are read by the next header notification, so
  /// nothing is lost. [limit] must be positive.
  Future<List<PendingReceive>> getPendingReceivesUpToHeight(int height, {int limit = 64});

  /// Record that the receive of ([walletId], [txid]) stopped waiting:
  /// [resolution] says why (it was recorded, or it failed for a reason more
  /// headers cannot change). The row is kept, and no longer replayed.
  ///
  /// A no-op when no row is parked for that key. Returns whether a waiting
  /// row was resolved.
  Future<bool> resolvePendingReceive(String walletId, String txid, String resolution, {DateTime? at});

  // ========================================
  // Outputs waiting for a proof (bead libspiffy-0lx)
  // ========================================

  /// The wallet's unspent outputs that cannot be proven to a counterparty
  /// right now, each with the ancestors that stand in the way
  /// (bead libspiffy-0lx).
  ///
  /// Spending a received output means handing the counterparty a BEEF that
  /// walks back from it to transactions with merkle proofs
  /// (`AncestorChainService`). While the output's own transaction is not
  /// mined, that walk rests on the proofs its BEEF carried for its
  /// ancestors. When a reorganization orphans such an ancestor's block, its
  /// proof is kept but no longer counts (`getMerkleProof` returns nothing),
  /// and the output silently becomes unspendable: nothing fetches a new
  /// proof, because ARC answers for transactions we broadcast and the
  /// counterparty is not asked again. This query is how the wallet *says*
  /// so, instead of holding an output that quietly cannot be paid with.
  ///
  /// An output is listed when the walk from its transaction reaches an
  /// ancestor that has no current proof and whose raw transaction is not
  /// stored either, or when the walk runs past [maxDepth]. Each
  /// [OutputAwaitingProof.ancestors] entry names that ancestor and what its
  /// last proof said ([MerkleProofStatus.orphaned] after a reorganization,
  /// [MerkleProofStatus.rejected] when our header contradicted it, none when
  /// no proof was ever stored). The list is empty when every unspent output
  /// can be proven; spent outputs are not listed.
  ///
  /// An output leaves the list by itself once a fresh proof for the ancestor
  /// is stored, wherever it comes from: a reorganization that puts the block
  /// back (SPVActor revives the proof), a later BEEF carrying a new BUMP, or
  /// ARC answering for the transaction.
  ///
  /// Reads the wallet's unspent UTXO rows and, per distinct transaction in
  /// the walk, its proof and raw bytes; results are memoised across outputs
  /// that share ancestry.
  Future<List<OutputAwaitingProof>> getOutputsAwaitingAncestorProof(
    String walletId, {
    int maxDepth = 20,
  });

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

/// The shared implementation of
/// [ReadModelStorage.getOutputsAwaitingAncestorProof], in terms of the
/// interface's own reads, so every backend answers it the same way
/// (bead libspiffy-0lx). Backends call it from their override.
Future<List<OutputAwaitingProof>> outputsAwaitingAncestorProof(
  ReadModelStorage storage,
  String walletId, {
  int maxDepth = 20,
}) async {
  final utxos = await storage.getUTXOs(walletId);
  if (utxos.isEmpty) return const [];

  final memo = <String, List<AwaitedAncestorProof>>{};

  Future<AwaitedAncestorProof> gap(String txid, String reason) async {
    MerkleProof? last;
    for (final proof in await storage.getMerkleProofHistory(txid)) {
      last = proof;
    }
    return AwaitedAncestorProof(
      txid: txid,
      lastProofStatus: last?.status,
      blockHeight: last?.blockHeight,
      reason: reason,
    );
  }

  Future<List<AwaitedAncestorProof>> gapsOf(String txid, int depth, Set<String> onPath) async {
    final cached = memo[txid];
    if (cached != null) return cached;
    if (!onPath.add(txid)) return const []; // a cycle cannot happen in a tx graph

    Future<List<AwaitedAncestorProof>> done(List<AwaitedAncestorProof> result) async {
      onPath.remove(txid);
      memo[txid] = result;
      return result;
    }

    // A current proof (verified, or pendingHeader while no header is known
    // at its height) ends the walk: this branch can go into a BEEF.
    if (await storage.getMerkleProof(txid) != null) return done(const []);

    final rawHex = (await storage.getTransaction(txid))?.rawHex ??
        (await storage.getAncestorTransactionsBatch([txid]))[txid];
    if (rawHex == null || rawHex.isEmpty) {
      return done([
        await gap(txid, 'no merkle proof on the active chain and no stored transaction to walk back from: '
            'a fresh proof for this transaction is needed before the output can be spent')
      ]);
    }
    if (depth >= maxDepth) {
      return done([await gap(txid, 'the ancestor walk reached its depth limit ($maxDepth) without a proof')]);
    }

    final List<String> parents;
    try {
      parents = [for (final input in dartsv.Transaction.fromHex(rawHex).inputs) input.prevTxnId];
    } catch (e) {
      return done([await gap(txid, 'the stored transaction does not parse: $e')]);
    }

    final deeper = <AwaitedAncestorProof>[];
    final seen = <String>{};
    for (final parent in parents) {
      if (!seen.add(parent)) continue;
      for (final entry in await gapsOf(parent, depth + 1, onPath)) {
        if (!deeper.any((e) => e.txid == entry.txid)) deeper.add(entry);
      }
    }
    if (deeper.isEmpty) return done(const []);

    // This transaction's own proof left the active chain (orphaned by a
    // reorganization, or rejected by a header that contradicts it). A fresh
    // proof for *it* unblocks the whole branch, so it is what the output is
    // named as waiting for, rather than whatever the walk ran into behind it.
    final history = await storage.getMerkleProofHistory(txid);
    if (history.isNotEmpty) {
      final last = history.last;
      return done([
        AwaitedAncestorProof(
          txid: txid,
          lastProofStatus: last.status,
          blockHeight: last.blockHeight,
          reason: 'its merkle proof is ${last.status.name}: the block at height ${last.blockHeight} it names is '
              'not on the active chain, so a fresh proof for this transaction is needed before the output '
              'can be spent',
        )
      ]);
    }
    return done(deeper);
  }

  final blocked = <(String, int, List<AwaitedAncestorProof>)>[];
  for (final utxo in utxos) {
    // Spent, or voided (bead libspiffy-3arz: the output of a transaction the
    // network will not settle). Neither can be put into a BEEF, so neither is
    // waiting on a proof.
    if (utxo.status == UTXOStatus.spent || utxo.status == UTXOStatus.voided) continue;
    final gaps = await gapsOf(utxo.txid, 0, <String>{});
    if (gaps.isEmpty) continue;
    blocked.add((utxo.txid, utxo.vout, gaps));
  }
  if (blocked.isEmpty) return const [];

  // Who to ask for a fresh proof (bead libspiffy-a2v3): the counterparty of
  // *this* transaction, not of the ancestor that lost its proof — the
  // ancestor is usually a stranger's transaction we have no marker for. One
  // batch read for the blocked transactions, not one per output, and this
  // wallet's rows only: two wallets that hold the same transaction each have
  // their own counterparty for it ([ReadModelStorage.getTransactionsByTxids]).
  final markers = <String, String?>{
    for (final row in await storage.getTransactionsByTxids({for (final b in blocked) b.$1}.toList()))
      if (row.walletId == walletId) row.txid: row.counterpartyMarker,
  };
  return [
    for (final (txid, vout, gaps) in blocked)
      OutputAwaitingProof(
        txid: txid,
        vout: vout,
        ancestors: gaps,
        counterpartyMarker: markers[txid],
      ),
  ];
}

/// One of a wallet's unspent outputs that cannot be proven to a counterparty
/// right now (bead libspiffy-0lx): the walk back from its transaction to a
/// merkle proof on the active header chain does not complete.
///
/// Returned by [ReadModelStorage.getOutputsAwaitingAncestorProof]. The output
/// is still the wallet's and its row is untouched; it simply cannot be put
/// into a BEEF until one of [ancestors] has a proof again.
class OutputAwaitingProof {
  /// The output's transaction.
  final String txid;

  /// The output's index in that transaction.
  final int vout;

  /// The ancestors the walk could not get past, in the order it met them.
  final List<AwaitedAncestorProof> ancestors;

  /// Who to ask for a fresh proof (bead libspiffy-a2v3):
  /// [BitcoinTransaction.counterpartyMarker] on [txid]'s own row — the
  /// counterparty who handed us *this* transaction and owed us the proofs
  /// its ancestry needs. Not the orphaned ancestor's counterparty, who is
  /// almost always a stranger we never dealt with and hold no marker for.
  ///
  /// Null when none was recorded (a payment taken in before markers existed,
  /// or an app that supplied none). Then nobody can be asked and the output
  /// is unrecoverable by request: only its ancestor's block returning to the
  /// active chain restores it.
  ///
  /// `RequestAncestorProofCommand` is how the wallet asks.
  final String? counterpartyMarker;

  const OutputAwaitingProof({
    required this.txid,
    required this.vout,
    required this.ancestors,
    this.counterpartyMarker,
  });

  /// The outpoint, `txid:vout`.
  String get outpoint => '$txid:$vout';

  @override
  String toString() => '$outpoint awaits a proof for ${[for (final a in ancestors) a.txid]}'
      '${counterpartyMarker == null ? ' (no counterparty recorded to ask)' : ', ask $counterpartyMarker'}';
}

/// An ancestor transaction a spend is waiting on, and what its last stored
/// proof said (bead libspiffy-0lx).
class AwaitedAncestorProof {
  /// The ancestor transaction.
  final String txid;

  /// The status of the last proof stored for it: [MerkleProofStatus.orphaned]
  /// when a reorganization took its block off the active chain,
  /// [MerkleProofStatus.rejected] when a header we hold contradicted it, null
  /// when no proof was ever stored.
  final MerkleProofStatus? lastProofStatus;

  /// The block height that proof named, if there was one.
  final int? blockHeight;

  /// Why the walk stopped here, in words.
  final String reason;

  const AwaitedAncestorProof({
    required this.txid,
    required this.reason,
    this.lastProofStatus,
    this.blockHeight,
  });

  @override
  String toString() => '$txid (${lastProofStatus?.name ?? 'no proof'}'
      '${blockHeight == null ? '' : ' at height $blockHeight'}): $reason';
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
/// current whatever the earlier rows say: SPVActor stores an [orphaned] or
/// [rejected] proof verified again when a reorganization makes active a
/// header at its height that it verifies against (beads hg0, 10r).
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
  /// confirmation, and it never displaces a current proof. If the header at
  /// its height changes to one it verifies against, it becomes [verified].
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

