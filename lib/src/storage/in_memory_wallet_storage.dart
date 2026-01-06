import 'dart:async';
import 'package:spiffynode/spiffy_node.dart';
import '../models/wallet_event.dart';
import '../models/bitcoin_utxo.dart';
import '../models/bitcoin_transaction.dart';
import '../models/address_metadata.dart';
import '../models/transaction_address_link.dart';
import '../actors/invoice_messages.dart';
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
    _walletMetadata[walletId] = {
      'walletId': walletId,
      'name': name,
      'rootAddress': rootAddress,
      'networkType': networkType,
      'metadata': metadata ?? {},
    };
    _walletIds.add(walletId);
  }
  
  @override
  Future<Map<String, dynamic>?> getWallet(String walletId) async {
    return _walletMetadata[walletId];
  }
  
  @override
  Future<List<String>> listWallets() async {
    return _walletIds.toList();
  }
  
  @override
  Future<List<String>> getWalletAddresses(String walletId) async {
    // Get unique addresses from UTXO records
    final utxos = await getAvailableUTXOs(walletId);
    final addresses = utxos.map((u) => u.address).toSet().toList();
    return addresses;
  }
  
  @override
  Future<void> deleteWallet(String walletId) async {
    _events.remove(walletId);
    _utxos.remove(walletId);
    _walletTransactions.remove(walletId);
    _balanceCache.remove(walletId);
    _walletMetadata.remove(walletId);
    _walletIds.remove(walletId);
    _walletInvoices.remove(walletId);
    
    // Remove transactions belonging to this wallet
    final txids = _walletTransactions[walletId];
    if (txids != null) {
      for (final txid in txids) {
        _transactions.remove(txid);
      }
    }
    
    // Remove invoices belonging to this wallet
    final invoiceIds = _walletInvoices[walletId];
    if (invoiceIds != null) {
      for (final invoiceId in invoiceIds) {
        _invoices.remove(invoiceId);
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
  Future<void> upsertUTXO(String walletId, BitcoinUtxo utxo) async {
    await _withLock(walletId, () async {
      if (!_walletIds.contains(walletId)) {
        _walletIds.add(walletId);
      }
      
      if (!_utxos.containsKey(walletId)) {
        _utxos[walletId] = {};
      }
      
      final utxoKey = '${utxo.txid}:${utxo.vout}';
      _utxos[walletId]![utxoKey] = utxo;
      
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
  Future<List<String>> getWalletIds() async {
    return List<String>.from(_walletIds);
  }
  
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

  @override
  Future<List<BitcoinTransaction>> getTransactionsByStatus(
    TransactionStatus status, {
    String? walletId,
  }) async {
    // Get all transactions or filter by wallet
    Iterable<BitcoinTransaction> transactions;
    
    if (walletId != null) {
      // Filter by wallet
      final walletTxIds = _walletTransactions[walletId] ?? [];
      transactions = walletTxIds
          .map((txid) => _transactions[txid])
          .where((tx) => tx != null)
          .cast<BitcoinTransaction>();
    } else {
      // Get all transactions
      transactions = _transactions.values;
    }
    
    // Filter by status and sort by creation date (descending)
    final filtered = transactions
        .where((tx) => tx.status == status)
        .toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    
    return filtered;
  }

  @override
  Future<void> storeTransaction(String walletId, BitcoinTransaction transaction) async {
    await _withLock(walletId, () async {
      // Store transaction
      _transactions[transaction.txid] = transaction;
      
      // Associate transaction with wallet
      if (!_walletTransactions.containsKey(walletId)) {
        _walletTransactions[walletId] = [];
      }
      
      if (!_walletTransactions[walletId]!.contains(transaction.txid)) {
        _walletTransactions[walletId]!.add(transaction.txid);
      }
    });
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
  
  // ========================================
  // Invoice Operations
  // ========================================

  // Invoice storage: invoiceId -> Invoice
  final Map<String, dynamic> _invoices = {};
  
  // Invoice by wallet: walletId -> List of invoiceIds
  final Map<String, List<String>> _walletInvoices = {};

  @override
  Future<void> storeInvoice(dynamic invoice) async {
    final invoiceId = invoice.invoiceId as String;
    final walletId = invoice.walletId as String;
    
    await _withLock(walletId, () async {
      _invoices[invoiceId] = invoice;
      
      final walletInvs = _walletInvoices.putIfAbsent(walletId, () => []);
      if (!walletInvs.contains(invoiceId)) {
        walletInvs.add(invoiceId);
      }
    });
  }

  @override
  Future<dynamic> getInvoice(String invoiceId) async {
    return _invoices[invoiceId];
  }

  @override
  Future<List<dynamic>> getInvoicesByWallet(String walletId) async {
    return await _withLock(walletId, () async {
      final invoiceIds = _walletInvoices[walletId] ?? [];
      return invoiceIds
          .map((id) => _invoices[id])
          .where((inv) => inv != null)
          .toList();
    });
  }

  @override
  Future<List<dynamic>> getInvoicesByStatus(dynamic status, {String? walletId}) async {
    final statusName = status is String ? status : (status as InvoiceStatus).toString().split('.').last;
    
    if (walletId != null) {
      return await _withLock(walletId, () async {
        final invoiceIds = _walletInvoices[walletId] ?? [];
        return invoiceIds
            .map((id) => _invoices[id])
            .where((inv) => inv != null && inv.status.name == statusName)
            .toList();
      });
    }
    
    // Global search across all invoices
    return _invoices.values
        .where((inv) => inv.status.name == statusName)
        .toList();
  }

  @override
  Future<void> updateInvoiceStatus(
    String invoiceId,
    dynamic status, {
    String? txid,
    BigInt? amountReceived,
    DateTime? paidAt,
  }) async {
    final invoice = _invoices[invoiceId];
    if (invoice != null) {
      final statusEnum = status is String 
          ? InvoiceStatus.values.firstWhere((s) => s.toString().split('.').last == status)
          : status;
      
      invoice.status = statusEnum;
      
      if (txid != null) {
        invoice.paymentTxid = txid;
      }
      if (amountReceived != null) {
        invoice.amountReceived = amountReceived;
      }
      if (paidAt != null) {
        invoice.paidAt = paidAt;
      }
    }
  }

  @override
  Future<int> getMerkleProofCount({String? walletId}) async {
    // In-memory storage doesn't track proofs by wallet
    // Return total count
    return _merkleProofs.length;
  }

  // Address Management Methods (stubs for in-memory storage)
  
  @override
  Future<bool> isWalletAddress(String walletId, String address) async {
    // Stub implementation for in-memory storage
    return false;
  }
  
  @override
  Future<AddressMetadata?> getAddressMetadata(String walletId, String address) async {
    // Stub implementation for in-memory storage
    return null;
  }
  
  @override
  Future<Map<String, bool>> checkAddresses(String walletId, List<String> addresses) async {
    // Stub implementation for in-memory storage
    return {for (var addr in addresses) addr: false};
  }
  
  @override
  Future<List<AddressMetadata>> getAddressesWithMetadata(
    String walletId, {
    bool? includeUnused,
    bool? isChange,
    int? limit,
    int? offset,
  }) async {
    // Stub implementation for in-memory storage
    return [];
  }
  
  @override
  Future<List<AddressMetadata>> getAddressRange(
    String walletId, {
    required int startIndex,
    required int count,
    bool isChange = false,
  }) async {
    // Stub implementation for in-memory storage
    return [];
  }
  
  @override
  Future<void> upsertAddress(String walletId, AddressMetadata metadata) async {
    // Stub implementation for in-memory storage
  }
  
  @override
  Future<int> getAddressCount(String walletId) async {
    // Stub implementation for in-memory storage
    return 0;
  }
  
  @override
  Future<void> updateAddressUsage(
    String walletId,
    String address, {
    DateTime? usedAt,
    BigInt? balanceDelta,
  }) async {
    // Stub implementation for in-memory storage
  }
  
  // Transaction-Address Junction Methods (stubs for in-memory storage)
  
  @override
  Future<void> storeTransactionAddresses(
    String walletId,
    String txid,
    List<TransactionAddressLink> links,
  ) async {
    // Stub implementation for in-memory storage
  }
  
  @override
  Future<List<String>> getTransactionsByAddress(
    String walletId,
    String address, {
    String? direction,
    int? limit,
    int? offset,
  }) async {
    // Stub implementation for in-memory storage
    return [];
  }
  
  @override
  Future<TransactionAddresses> getTransactionAddresses(String walletId, String txid) async {
    // Stub implementation for in-memory storage
    return TransactionAddresses(inputs: [], outputs: []);
  }
  
  @override
  Future<int> getAddressTransactionCount(String walletId, String address) async {
    // Stub implementation for in-memory storage
    return 0;
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

  final Map<String, dynamic> _paymentChannels = {};
  final Map<String, List<String>> _walletChannels = {};

  @override
  Future<void> storePaymentChannel(dynamic channel) async {
    await _withGlobalLock(() async {
      _paymentChannels[channel.channelId] = channel;
      
      // Index by wallet
      final walletChannels = _walletChannels.putIfAbsent(channel.walletId, () => []);
      if (!walletChannels.contains(channel.channelId)) {
        walletChannels.add(channel.channelId);
      }
    });
  }

  @override
  Future<dynamic> getPaymentChannel(String channelId) async {
    return _paymentChannels[channelId];
  }

  @override
  Future<List<dynamic>> getPaymentChannelsForWallet(String walletId) async {
    final channelIds = _walletChannels[walletId] ?? [];
    return channelIds
        .map((id) => _paymentChannels[id])
        .where((ch) => ch != null)
        .toList();
  }

  @override
  Future<void> updatePaymentChannelState(String channelId, String state) async {
    await _withGlobalLock(() async {
      final channel = _paymentChannels[channelId];
      if (channel != null) {
        // Update the state field
        channel.state = state;
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
        channel.clientBalanceSats = clientBalance;
        channel.serverBalanceSats = serverBalance;
      }
    });
  }

  @override
  Future<void> deletePaymentChannel(String channelId) async {
    await _withGlobalLock(() async {
      final channel = _paymentChannels.remove(channelId);
      if (channel != null) {
        // Remove from wallet index
        final walletChannels = _walletChannels[channel.walletId];
        walletChannels?.remove(channelId);
      }
    });
  }
} 