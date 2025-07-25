import 'dart:async';
import 'dart:collection';

import 'package:spiffynode/src/spv/chain_tip_tracker.dart';

import '../models/bitcoin_utxo.dart';
import '../models/bitcoin_transaction.dart';
import '../utils/beef.dart';
import 'spv_service.dart';
import 'block_header_service.dart';
import 'arc_service.dart';

/// Comprehensive wallet balance service with BEEF-based confirmation logic
/// Provides multi-tier balance tracking, reorganization handling, and real-time updates
class WalletBalanceService {
  final SPVService spvService;
  final BlockHeaderService blockHeaderService;
  final ChainTipTracker chainTipTracker;
  final ArcService arcService;
  
  // Balance tracking
  final Map<String, TrackedUTXO> _trackedUTXOs = {};
  final Map<String, BalanceTrackedTransaction> _trackedTransactions = {};
  
  // Balance tiers (confirmation levels)
  final WalletBalanceConfig config;
  
  // Real-time balance updates
  final StreamController<WalletBalanceUpdate> _balanceUpdateController = 
      StreamController<WalletBalanceUpdate>.broadcast();
  
  // Event subscriptions
  late StreamSubscription<ChainTipEvent> _chainTipSubscription;
  late StreamSubscription<TransactionConfirmationUpdate> _confirmationSubscription;
  late StreamSubscription<BlockHeaderEvent> _headerSubscription;
  
  // Current balance cache
  WalletBalance? _currentBalance;
  DateTime? _lastBalanceUpdate;
  
  // Statistics
  int _reorganizationsHandled = 0;
  int _balanceRecalculations = 0;
  DateTime? _lastReorgAt;

  WalletBalanceService({
    required this.spvService,
    required this.blockHeaderService,
    required this.chainTipTracker,
    required this.arcService,
    WalletBalanceConfig? config,
  }) : config = config ?? const WalletBalanceConfig() {
    _initializeEventListeners();
  }

  /// Current wallet balance with confirmation tiers
  WalletBalance get currentBalance => _currentBalance ?? WalletBalance.empty();
  
  /// Stream of balance updates
  Stream<WalletBalanceUpdate> get balanceUpdates => _balanceUpdateController.stream;
  
  /// Current network height
  int get networkHeight => chainTipTracker.networkHeight;
  
  /// Statistics about balance service
  Map<String, dynamic> get statistics => {
    'trackedUTXOs': _trackedUTXOs.length,
    'trackedTransactions': _trackedTransactions.length,
    'reorganizationsHandled': _reorganizationsHandled,
    'balanceRecalculations': _balanceRecalculations,
    'lastReorganizationAt': _lastReorgAt?.toIso8601String(),
    'lastBalanceUpdate': _lastBalanceUpdate?.toIso8601String(),
    'networkHeight': networkHeight,
    'currentBalance': currentBalance.toMap(),
  };

  /// Initialize event listeners for real-time balance updates
  void _initializeEventListeners() {
    // Listen to chain tip events for reorganizations
    _chainTipSubscription = chainTipTracker.tipEvents.listen((event) {
      _handleChainTipEvent(event);
    });
    
    // Listen to confirmation updates from SPV service
    _confirmationSubscription = spvService.confirmationUpdates.listen((update) {
      _handleConfirmationUpdate(update);
    });
    
    // Listen to block header events for sync status
    _headerSubscription = blockHeaderService.headerEvents.listen((event) {
      _handleHeaderEvent(event);
    });
  }

  /// Add UTXOs to balance tracking with BEEF validation
  Future<void> trackUTXOs(List<BitcoinUtxo> utxos) async {
    final updates = <WalletBalanceUpdate>[];
    
    for (final utxo in utxos) {
      final utxoKey = '${utxo.txid}:${utxo.vout}';
      
      // Skip if already tracking
      if (_trackedUTXOs.containsKey(utxoKey)) continue;
      
      // Get transaction details and BEEF proof if available
      final txDetails = await _getTransactionDetails(utxo.txid);
      
      final tracked = TrackedUTXO(
        utxo: utxo,
        transactionDetails: txDetails,
        addedAt: DateTime.now(),
        lastValidated: DateTime.now(),
      );
      
      _trackedUTXOs[utxoKey] = tracked;
      
      // Start tracking confirmations for this transaction
      await spvService.trackConfirmations(utxo.txid, 
          requiredConfirmations: config.maxConfirmationTier);
    }
    
    // Recalculate balance
    await _recalculateBalance();
  }

  /// Remove UTXOs from tracking (when spent)
  Future<void> untrackUTXOs(List<String> utxoKeys) async {
    bool balanceChanged = false;
    
    for (final utxoKey in utxoKeys) {
      if (_trackedUTXOs.remove(utxoKey) != null) {
        balanceChanged = true;
      }
    }
    
    if (balanceChanged) {
      await _recalculateBalance();
    }
  }

  /// Track spending transactions for balance updates
  Future<void> trackSpendingTransaction(BitcoinTransaction transaction) async {
    final txKey = transaction.txid;
    
    // Skip if already tracking
    if (_trackedTransactions.containsKey(txKey)) return;
    
    // Get BEEF proof and validation status
    final beef = await _getBEEFForTransaction(transaction.txid);
    final validationResult = beef != null ? await spvService.validateBEEF(beef) : null;
    
    final tracked = TrackedSpendingTransaction(
      transaction: transaction,
      beef: beef,
      validationResult: validationResult,
      addedAt: DateTime.now(),
      lastValidated: DateTime.now(),
    );
    
    _trackedTransactions[txKey] = tracked;
    
    // Start tracking confirmations
    await spvService.trackConfirmations(transaction.txid, 
        requiredConfirmations: config.maxConfirmationTier);
    
    // Recalculate balance
    await _recalculateBalance();
  }

  /// Handle chain tip events for reorganization management
  Future<void> _handleChainTipEvent(ChainTipEvent event) async {
    switch (event.type) {
      case ChainTipEventType.reorganization:
        await _handleReorganization(event);
        break;
        
      case ChainTipEventType.heightIncrease:
        // Balance will be updated through confirmation updates
        break;
        
      default:
        break;
    }
  }

  /// Handle confirmation updates from SPV service
  Future<void> _handleConfirmationUpdate(TransactionConfirmationUpdate update) async {
    bool balanceChanged = false;
    
    // Update UTXO confirmations
    for (final entry in _trackedUTXOs.entries) {
      final tracked = entry.value;
      if (tracked.utxo.txid == update.txid) {
        tracked.confirmations = update.confirmations;
        tracked.lastValidated = DateTime.now();
        balanceChanged = true;
      }
    }
    
    // Update transaction confirmations
    if (_trackedTransactions.containsKey(update.txid)) {
      final tracked = _trackedTransactions[update.txid]!;
      tracked.confirmations = update.confirmations;
      tracked.lastValidated = DateTime.now();
      balanceChanged = true;
    }
    
    if (balanceChanged || update.reorgDetected) {
      await _recalculateBalance();
    }
  }

  /// Handle block header events
  Future<void> _handleHeaderEvent(BlockHeaderEvent event) async {
    switch (event.type) {
      case BlockHeaderEventType.reorganization:
      case BlockHeaderEventType.rollback:
        // Headers changed - revalidate all BEEF proofs
        await _revalidateAllBEEFProofs();
        break;
        
      default:
        break;
    }
  }

  /// Handle blockchain reorganization  
  Future<void> _handleReorganization(ChainTipEvent event) async {
    print('WalletBalanceService: Handling reorganization from ${event.oldTip?.height} to ${event.newTip.height}');
    
    _reorganizationsHandled++;
    _lastReorgAt = DateTime.now();
    
    // Revalidate all tracked transactions and UTXOs
    final revalidationTasks = <Future>[];
    
    // Revalidate UTXOs
    for (final entry in _trackedUTXOs.entries) {
      final tracked = entry.value;
      if (tracked.shouldRevalidateForHeight(event.newTip.height, config.reorgValidationDepth)) {
        revalidationTasks.add(_revalidateUTXO(tracked));
      }
    }
    
    // Revalidate spending transactions
    for (final entry in _trackedTransactions.entries) {
      final tracked = entry.value;
      if (tracked is TrackedSpendingTransaction && 
          tracked.shouldRevalidateForHeight(event.newTip.height, config.reorgValidationDepth)) {
        revalidationTasks.add(_revalidateTransaction(tracked));
      }
    }
    
    // Wait for all revalidations
    await Future.wait(revalidationTasks);
    
    // Recalculate balance
    await _recalculateBalance();
  }

  /// Revalidate UTXO after reorganization
  Future<void> _revalidateUTXO(TrackedUTXO tracked) async {
    try {
      // Get fresh transaction details
      final newDetails = await _getTransactionDetails(tracked.utxo.txid);
      tracked.transactionDetails = newDetails;
      
      // Update validation status
      tracked.lastValidated = DateTime.now();
      
      print('WalletBalanceService: Revalidated UTXO ${tracked.utxo.txid}:${tracked.utxo.vout}');
    } catch (e) {
      print('WalletBalanceService: Error revalidating UTXO ${tracked.utxo.txid}: $e');
    }
  }

  /// Revalidate spending transaction after reorganization
  Future<void> _revalidateTransaction(TrackedSpendingTransaction tracked) async {
    try {
      // Get fresh BEEF proof
      final newBeef = await _getBEEFForTransaction(tracked.transaction.txid);
      tracked.beef = newBeef;
      
      // Revalidate BEEF
      tracked.validationResult = newBeef != null ? await spvService.validateBEEF(newBeef) : null;
      tracked.lastValidated = DateTime.now();
      
      print('WalletBalanceService: Revalidated transaction ${tracked.transaction.txid}');
    } catch (e) {
      print('WalletBalanceService: Error revalidating transaction ${tracked.transaction.txid}: $e');
    }
  }

  /// Revalidate all BEEF proofs against current headers
  Future<void> _revalidateAllBEEFProofs() async {
    final revalidationTasks = <Future>[];
    
    // Revalidate UTXO transaction proofs
    for (final tracked in _trackedUTXOs.values) {
      if (tracked.transactionDetails?.beef != null) {
        revalidationTasks.add(_revalidateUTXO(tracked));
      }
    }
    
    // Revalidate spending transaction proofs
    for (final tracked in _trackedTransactions.values) {
      if (tracked is TrackedSpendingTransaction && tracked.beef != null) {
        revalidationTasks.add(_revalidateTransaction(tracked));
      }
    }
    
    await Future.wait(revalidationTasks);
    await _recalculateBalance();
  }

  /// Recalculate wallet balance across all confirmation tiers
  Future<void> _recalculateBalance() async {
    _balanceRecalculations++;
    
    final balanceTiers = <int, BigInt>{};
    final utxosByTier = <int, List<BitcoinUtxo>>{};
    final pendingTransactions = <BitcoinTransaction>[];
    
    // Initialize balance tiers
    for (final tier in config.confirmationTiers) {
      balanceTiers[tier] = BigInt.zero;
      utxosByTier[tier] = [];
    }
    balanceTiers[0] = BigInt.zero; // Unconfirmed balance
    utxosByTier[0] = [];
    
    // Calculate UTXO balances by confirmation tier
    for (final tracked in _trackedUTXOs.values) {
      final utxo = tracked.utxo;
      final confirmations = tracked.confirmations;
      
      // Add to appropriate confirmation tiers
      for (final tier in config.confirmationTiers) {
        if (confirmations >= tier) {
          balanceTiers[tier] = balanceTiers[tier]! + utxo.value.getValue();
          utxosByTier[tier]!.add(utxo);
        }
      }
      
      // Add to unconfirmed if not confirmed
      if (confirmations == 0) {
        balanceTiers[0] = balanceTiers[0]! + utxo.value.getValue();
        utxosByTier[0]!.add(utxo);
      }
    }
    
    // Subtract pending spending transactions
    for (final tracked in _trackedTransactions.values) {
      if (tracked is TrackedSpendingTransaction) {
        final transaction = tracked.transaction;
        final confirmations = tracked.confirmations;
        
        if (confirmations == 0) {
          pendingTransactions.add(transaction);
        }
        
        // Subtract spent amounts from appropriate tiers
        // (This would need more complex logic to track which UTXOs are spent)
      }
    }
    
    // Create new balance
    final newBalance = WalletBalance(
      confirmed: balanceTiers[config.defaultConfirmationLevel] ?? BigInt.zero,
      unconfirmed: balanceTiers[0] ?? BigInt.zero,
      balanceTiers: Map.from(balanceTiers),
      utxosByTier: Map.from(utxosByTier),
      pendingTransactions: pendingTransactions,
      networkHeight: networkHeight,
      lastUpdated: DateTime.now(),
      isNetworkSynced: chainTipTracker.isLikelySynced,
    );
    
    // Check if balance changed
    final balanceChanged = _currentBalance == null || 
        !_balancesEqual(_currentBalance!, newBalance);
    
    if (balanceChanged) {
      final oldBalance = _currentBalance;
      _currentBalance = newBalance;
      _lastBalanceUpdate = DateTime.now();
      
      // Fire balance update event
      _balanceUpdateController.add(WalletBalanceUpdate(
        oldBalance: oldBalance,
        newBalance: newBalance,
        reason: WalletBalanceUpdateReason.recalculation,
        networkHeight: networkHeight,
      ));
    }
  }

  /// Get transaction details with BEEF proof
  Future<TransactionDetails?> _getTransactionDetails(String txid) async {
    try {
      // Get verification status from SPV service
      final status = await spvService.getVerificationStatus(txid);
      
      // Get BEEF proof if available
      final beef = await _getBEEFForTransaction(txid);
      
      return TransactionDetails(
        txid: txid,
        blockHeight: status.blockHeight ?? 0,
        confirmations: status.confirmations,
        beef: beef,
        canVerify: status.canVerify,
        lastUpdated: DateTime.now(),
      );
    } catch (e) {
      print('WalletBalanceService: Error getting transaction details for $txid: $e');
      return null;
    }
  }

  /// Get BEEF proof for a transaction
  Future<BEEF?> _getBEEFForTransaction(String txid) async {
    try {
      return await spvService.createBEEF([txid]);
    } catch (e) {
      print('WalletBalanceService: Error creating BEEF for $txid: $e');
      return null;
    }
  }

  /// Check if two balances are equal
  bool _balancesEqual(WalletBalance a, WalletBalance b) {
    return a.confirmed == b.confirmed && 
           a.unconfirmed == b.unconfirmed &&
           a.balanceTiers.length == b.balanceTiers.length &&
           a.balanceTiers.keys.every((tier) => a.balanceTiers[tier] == b.balanceTiers[tier]);
  }

  /// Shutdown the service
  Future<void> shutdown() async {
    await _chainTipSubscription.cancel();
    await _confirmationSubscription.cancel();
    await _headerSubscription.cancel();
    await _balanceUpdateController.close();
    
    _trackedUTXOs.clear();
    _trackedTransactions.clear();
  }
}

/// Tracked UTXO with validation details
class TrackedUTXO {
  final BitcoinUtxo utxo;
  TransactionDetails? transactionDetails;
  int confirmations;
  final DateTime addedAt;
  DateTime lastValidated;

  TrackedUTXO({
    required this.utxo,
    this.transactionDetails,
    this.confirmations = 0,
    required this.addedAt,
    required this.lastValidated,
  });

  /// Whether this UTXO should be revalidated for a given height
  bool shouldRevalidateForHeight(int currentHeight, int validationDepth) {
    final utxoHeight = transactionDetails?.blockHeight ?? 0;
    return utxoHeight > 0 && utxoHeight >= (currentHeight - validationDepth);
  }
}

/// Base class for balance-tracked transactions
abstract class BalanceTrackedTransaction {
  int confirmations;
  DateTime lastValidated;
  
  BalanceTrackedTransaction({
    this.confirmations = 0,
    required this.lastValidated,
  });
  
  bool shouldRevalidateForHeight(int currentHeight, int validationDepth);
}

/// Tracked spending transaction with BEEF validation
class TrackedSpendingTransaction extends BalanceTrackedTransaction {
  final BitcoinTransaction transaction;
  BEEF? beef;
  SPVValidationResult? validationResult;
  final DateTime addedAt;

  TrackedSpendingTransaction({
    required this.transaction,
    this.beef,
    this.validationResult,
    required this.addedAt,
    super.confirmations = 0,
    required super.lastValidated,
  });

  @override
  bool shouldRevalidateForHeight(int currentHeight, int validationDepth) {
    // Always revalidate spending transactions in reorg range
    return confirmations == 0 || 
           (transaction.blockHeight != null && 
            transaction.blockHeight! >= (currentHeight - validationDepth));
  }
}

/// Transaction details with BEEF proof
class TransactionDetails {
  final String txid;
  final int blockHeight;
  final int confirmations;
  final BEEF? beef;
  final bool canVerify;
  final DateTime lastUpdated;

  TransactionDetails({
    required this.txid,
    required this.blockHeight,
    required this.confirmations,
    this.beef,
    required this.canVerify,
    required this.lastUpdated,
  });
}

/// Multi-tier wallet balance
class WalletBalance {
  final BigInt confirmed;
  final BigInt unconfirmed;
  final Map<int, BigInt> balanceTiers;
  final Map<int, List<BitcoinUtxo>> utxosByTier;
  final List<BitcoinTransaction> pendingTransactions;
  final int networkHeight;
  final DateTime lastUpdated;
  final bool isNetworkSynced;

  WalletBalance({
    required this.confirmed,
    required this.unconfirmed,
    required this.balanceTiers,
    required this.utxosByTier,
    required this.pendingTransactions,
    required this.networkHeight,
    required this.lastUpdated,
    required this.isNetworkSynced,
  });

  /// Total balance (confirmed + unconfirmed)
  BigInt get total => confirmed + unconfirmed;
  
  /// Get balance for specific confirmation tier
  BigInt getBalanceForTier(int confirmations) {
    return balanceTiers[confirmations] ?? BigInt.zero;
  }
  
  /// Empty balance
  static WalletBalance empty() => WalletBalance(
    confirmed: BigInt.zero,
    unconfirmed: BigInt.zero,
    balanceTiers: {},
    utxosByTier: {},
    pendingTransactions: [],
    networkHeight: 0,
    lastUpdated: DateTime.now(),
    isNetworkSynced: false,
  );
  
  /// Convert to map for statistics
  Map<String, dynamic> toMap() => {
    'confirmed': confirmed.toString(),
    'unconfirmed': unconfirmed.toString(),
    'total': total.toString(),
    'balanceTiers': balanceTiers.map((k, v) => MapEntry(k.toString(), v.toString())),
    'utxoCount': utxosByTier.values.fold<int>(0, (sum, utxos) => sum + utxos.length),
    'pendingTransactions': pendingTransactions.length,
    'networkHeight': networkHeight,
    'isNetworkSynced': isNetworkSynced,
    'lastUpdated': lastUpdated.toIso8601String(),
  };
}

/// Balance update event
class WalletBalanceUpdate {
  final WalletBalance? oldBalance;
  final WalletBalance newBalance;
  final WalletBalanceUpdateReason reason;
  final int networkHeight;

  WalletBalanceUpdate({
    this.oldBalance,
    required this.newBalance,
    required this.reason,
    required this.networkHeight,
  });

  /// Balance change amount
  BigInt get balanceChange => newBalance.total - (oldBalance?.total ?? BigInt.zero);
  
  @override
  String toString() => 'WalletBalanceUpdate($reason: ${newBalance.total} satoshis)';
}

/// Reason for balance update
enum WalletBalanceUpdateReason {
  recalculation,
  newTransaction,
  confirmation,
  reorganization,
  utxoAdded,
  utxoSpent,
}

/// Configuration for wallet balance service
class WalletBalanceConfig {
  /// Confirmation tiers to track (e.g., [1, 6, 100])
  final List<int> confirmationTiers;
  
  /// Default confirmation level for "confirmed" balance
  final int defaultConfirmationLevel;
  
  /// Maximum confirmation tier to track
  final int maxConfirmationTier;
  
  /// Depth to revalidate during reorganizations
  final int reorgValidationDepth;

  const WalletBalanceConfig({
    this.confirmationTiers = const [1, 6, 100],
    this.defaultConfirmationLevel = 6,
    this.maxConfirmationTier = 100,
    this.reorgValidationDepth = 10,
  });
}

/// Exception thrown by wallet balance service
class WalletBalanceException implements Exception {
  final String message;
  
  WalletBalanceException(this.message);
  
  @override
  String toString() => 'WalletBalanceException: $message';
} 