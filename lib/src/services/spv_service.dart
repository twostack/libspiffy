import 'dart:async';
import 'dart:typed_data';

import 'package:spiffynode/src/spv/chain_tip_tracker.dart';

import '../utils/beef.dart';
import '../utils/bump.dart';
import 'arc_service.dart';
import 'block_header_service.dart';

/// Enhanced SPV service with ChainTipTracker and BlockHeaderService integration
/// Provides real-time blockchain monitoring, confirmation tracking, and BEEF/BUMP validation
class SPVService {
  final ArcService arcService;
  final ChainTipTracker chainTipTracker;
  final BlockHeaderService blockHeaderService;
  final StreamController<TransactionConfirmationUpdate> _confirmationController = 
      StreamController<TransactionConfirmationUpdate>.broadcast();
  
  // Transaction confirmation tracking
  final Map<String, TrackedTransaction> _trackedTransactions = {};
  final Map<String, Timer> _confirmationTimers = {};
  
  late StreamSubscription<ChainTipEvent> _chainTipSubscription;

  SPVService({
    required this.arcService,
    required this.chainTipTracker,
    required this.blockHeaderService,
  }) {
    _initializeChainTipMonitoring();
  }

  /// Current network height from ChainTipTracker
  int get networkHeight => chainTipTracker.networkHeight;
  
  /// Whether we're synced with the network
  bool get isNetworkSynced => chainTipTracker.isLikelySynced;
  
  /// Stream of transaction confirmation updates
  Stream<TransactionConfirmationUpdate> get confirmationUpdates => 
      _confirmationController.stream;
  
  /// Current chain tip information
  ChainTip? get currentChainTip => chainTipTracker.bestTip;

  /// Initialize chain tip monitoring for confirmation tracking
  void _initializeChainTipMonitoring() {
    _chainTipSubscription = chainTipTracker.tipEvents.listen((event) {
      _handleChainTipEvent(event);
    });
  }

  /// Handle chain tip events for confirmation updates
  Future<void> _handleChainTipEvent(ChainTipEvent event) async {
    switch (event.type) {
      case ChainTipEventType.heightIncrease:
        await _updateConfirmationCounts(event.newTip.height);
        break;
        
      case ChainTipEventType.reorganization:
        await _handleReorganization(event);
        break;
        
      case ChainTipEventType.newTip:
        await _updateConfirmationCounts(event.newTip.height);
        break;
        
      default:
        // Handle other events if needed
        break;
    }
  }

  /// Update confirmation counts for all tracked transactions
  Future<void> _updateConfirmationCounts(int currentHeight) async {
    final updates = <TransactionConfirmationUpdate>[];
    
    for (final entry in _trackedTransactions.entries) {
      final txid = entry.key;
      final tracked = entry.value;
      
      if (tracked.blockHeight > 0) {
        final oldConfirmations = tracked.confirmations;
        final newConfirmations = currentHeight - tracked.blockHeight + 1;
        
        if (newConfirmations != oldConfirmations) {
          tracked.confirmations = newConfirmations;
          tracked.lastUpdated = DateTime.now();
          
          final update = TransactionConfirmationUpdate(
            txid: txid,
            blockHeight: tracked.blockHeight,
            confirmations: newConfirmations,
            isConfirmed: newConfirmations >= tracked.requiredConfirmations,
            networkHeight: currentHeight,
          );
          
          updates.add(update);
        }
      }
    }
    
    // Send all updates
    for (final update in updates) {
      _confirmationController.add(update);
    }
  }

  /// Handle blockchain reorganization
  Future<void> _handleReorganization(ChainTipEvent event) async {
    print('SPVService: Handling reorganization from ${event.oldTip?.height} to ${event.newTip.height}');
    
    // Re-validate all tracked transactions
    final revalidationTasks = <Future>[];
    
    for (final entry in _trackedTransactions.entries) {
      final txid = entry.key;
      final tracked = entry.value;
      
      // If transaction was in a block that might be affected by reorg
      if (tracked.blockHeight > 0 && tracked.blockHeight >= event.newTip.height - 10) {
        revalidationTasks.add(_revalidateTransaction(txid, tracked));
      }
    }
    
    // Wait for all revalidations to complete
    await Future.wait(revalidationTasks);
  }

  /// Re-validate a transaction after reorganization
  Future<void> _revalidateTransaction(String txid, TrackedTransaction tracked) async {
    try {
      // Get fresh merkle proof from ARC
      final proof = await arcService.getMerkleProof(txid);
      
      if (proof != null) {
        // Update block height if it changed
        if (proof.blockHeight != tracked.blockHeight) {
          tracked.blockHeight = proof.blockHeight;
          tracked.merkleProof = proof;
          tracked.lastUpdated = DateTime.now();
          
          // Recalculate confirmations
          final newConfirmations = networkHeight - proof.blockHeight + 1;
          tracked.confirmations = newConfirmations;
          
          _confirmationController.add(TransactionConfirmationUpdate(
            txid: txid,
            blockHeight: proof.blockHeight,
            confirmations: newConfirmations,
            isConfirmed: newConfirmations >= tracked.requiredConfirmations,
            networkHeight: networkHeight,
            reorgDetected: true,
          ));
        }
      } else {
        // Transaction no longer has a merkle proof - might be back in mempool
        tracked.blockHeight = 0;
        tracked.confirmations = 0;
        tracked.merkleProof = null;
        tracked.lastUpdated = DateTime.now();
        
        _confirmationController.add(TransactionConfirmationUpdate(
          txid: txid,
          blockHeight: 0,
          confirmations: 0,
          isConfirmed: false,
          networkHeight: networkHeight,
          reorgDetected: true,
        ));
      }
    } catch (e) {
      print('SPVService: Error revalidating transaction $txid: $e');
    }
  }

  /// Validate a BEEF package against current blockchain state
  Future<SPVValidationResult> validateBEEF(BEEF beef) async {
    if (!beef.validate()) {
      return SPVValidationResult(
        isValid: false,
        reason: 'Invalid BEEF structure',
      );
    }

    final verifiedTxs = beef.getVerifiedTransactions();
    if (verifiedTxs.isEmpty) {
      return SPVValidationResult(
        isValid: true,
        reason: 'No transactions with merkle proofs to validate',
      );
    }

    final validatedTxids = <String>[];
    final failedTxids = <String>[];

    // Validate each transaction with merkle proof
    for (final tx in verifiedTxs) {
      final txid = tx['txid'] as Uint8List;
      final txidHex = _bytesToHex(txid);
      final blockHeight = tx['blockHeight'] as int;
      final bumpIdx = tx['bumpIndex'] as int;

      try {
        // Get block header merkle root
        final blockMerkleRoot = await _getBlockHeaderMerkleRoot(blockHeight);
        
        if (blockMerkleRoot == null) {
          failedTxids.add(txidHex);
          continue;
        }

        // Compute merkle root from BUMP
        final computedMerkleRoot = beef.bumps[bumpIdx].computeMerkleRoot(txid);
        final computedMerkleRootHex = _bytesToHex(computedMerkleRoot.reversed.toList());

        // Compare merkle roots
        if (computedMerkleRootHex == blockMerkleRoot) {
          validatedTxids.add(txidHex);
        } else {
          failedTxids.add(txidHex);
        }
      } catch (e) {
        print('SPVService: Error validating transaction $txidHex: $e');
        failedTxids.add(txidHex);
      }
    }

    return SPVValidationResult(
      isValid: failedTxids.isEmpty,
      reason: failedTxids.isEmpty ? null : 'Failed to validate ${failedTxids.length} transactions',
      validatedTxids: validatedTxids,
      failedTxids: failedTxids,
    );
  }

  /// Validate a single transaction using its merkle proof
  Future<bool> validateTransaction(String txidHex, BUMP merkleProof) async {
    try {
      final txidBytes = _hexToBytes(txidHex);
      
      // Get block height from merkle proof
      final blockHeight = merkleProof.blockHeight;
      
      // Get block header merkle root
      final blockMerkleRoot = await _getBlockHeaderMerkleRoot(blockHeight);
      if (blockMerkleRoot == null) {
        return false;
      }
      
      // Compute merkle root from BUMP
      final computedMerkleRoot = merkleProof.computeMerkleRoot(txidBytes);
      final computedMerkleRootHex = _bytesToHex(computedMerkleRoot.reversed.toList());
      
      return computedMerkleRootHex == blockMerkleRoot;
    } catch (e) {
      print('SPVService: Error validating transaction $txidHex: $e');
      return false;
    }
  }

  /// Track confirmations for a transaction
  Future<void> trackConfirmations(
    String txidHex, {
    int requiredConfirmations = 6,
    Duration timeout = const Duration(hours: 24),
  }) async {
    // Cancel existing timer if any
    _confirmationTimers[txidHex]?.cancel();
    
    // Get initial transaction status
    final proof = await arcService.getMerkleProof(txidHex);
    
    final tracked = TrackedTransaction(
      txid: txidHex,
      blockHeight: proof?.blockHeight ?? 0,
      confirmations: proof != null ? (networkHeight - proof.blockHeight + 1) : 0,
      requiredConfirmations: requiredConfirmations,
      merkleProof: proof,
      startedTracking: DateTime.now(),
      lastUpdated: DateTime.now(),
    );
    
    _trackedTransactions[txidHex] = tracked;
    
    // Send initial update
    _confirmationController.add(TransactionConfirmationUpdate(
      txid: txidHex,
      blockHeight: tracked.blockHeight,
      confirmations: tracked.confirmations,
      isConfirmed: tracked.confirmations >= requiredConfirmations,
      networkHeight: networkHeight,
    ));
    
    // Set timeout timer
    _confirmationTimers[txidHex] = Timer(timeout, () {
      stopTrackingConfirmations(txidHex);
    });
  }

  /// Stop tracking confirmations for a transaction
  void stopTrackingConfirmations(String txidHex) {
    _trackedTransactions.remove(txidHex);
    _confirmationTimers[txidHex]?.cancel();
    _confirmationTimers.remove(txidHex);
  }

  /// Verify that a transaction is included in a specific block
  Future<bool> verifyTransactionInclusion(String txidHex, int blockHeight) async {
    try {
      // First check if we have the block header
      final blockHeaderMerkleRoot = await _getBlockHeaderMerkleRoot(blockHeight);
      if (blockHeaderMerkleRoot == null) {
        return false;
      }
      
      // Get merkle proof from ARC
      final proof = await arcService.getMerkleProof(txidHex);
      
      if (proof == null || proof.blockHeight != blockHeight) {
        return false;
      }
      
      // Verify merkle root matches block header
      if (proof.merkleRoot != blockHeaderMerkleRoot) {
        return false;
      }
      
      return true;
    } catch (e) {
      print('SPVService: Error verifying transaction inclusion: $e');
      throw SPVException('Failed to verify transaction inclusion: $e');
    }
  }

  /// Create a BEEF package for transactions with merkle proofs
  Future<BEEF?> createBEEF(List<String> txids) async {
    try {
      final proofs = await arcService.getBatchMerkleProofs(txids);
      if (proofs.isEmpty) return null;

      final bumps = <BUMP>[];
      final txs = <Uint8List>[];
      final hasMerkle = <bool>[];
      final bumpIndex = <int>[];

      // Group proofs by block height
      final proofsByHeight = <int, List<ArcMerkleProofResponse>>{};
      for (final proof in proofs) {
        proofsByHeight.putIfAbsent(proof.blockHeight, () => []).add(proof);
      }

      // Create BUMPs for each block height
      for (final entry in proofsByHeight.entries) {
        final blockProofs = entry.value;
        final bump = await _createBUMPFromArcProofs(blockProofs);
        bumps.add(bump);
      }

      // Get raw transaction data
      int currentBumpIndex = 0;
      for (final txid in txids) {
        final rawTx = await arcService.getRawTransaction(txid);
        if (rawTx.isEmpty) continue;

        final txBytes = _hexToBytes(rawTx);
        txs.add(txBytes);

        final hasProof = proofs.any((p) => p.txid == txid);
        hasMerkle.add(hasProof);

        if (hasProof) {
          final proof = proofs.firstWhere((p) => p.txid == txid);
          final bumpIdx = proofsByHeight.keys.toList().indexOf(proof.blockHeight);
          bumpIndex.add(bumpIdx);
        }
      }

      return BEEF.create(
        bumps: bumps,
        txs: txs,
        hasMerkle: hasMerkle,
        bumpIndex: bumpIndex,
      );
    } catch (e) {
      print('SPVService: Error creating BEEF: $e');
      return null;
    }
  }

  /// Get verification status for a transaction
  Future<TransactionVerificationStatus> getVerificationStatus(String txidHex) async {
    try {
      final proof = await arcService.getMerkleProof(txidHex);
      
      if (proof == null) {
        return TransactionVerificationStatus(
          txid: txidHex,
          canVerify: false,
          reason: 'No merkle proof available',
          confirmations: 0,
          networkHeight: networkHeight,
        );
      }

      final confirmations = networkHeight - proof.blockHeight + 1;
      
      return TransactionVerificationStatus(
        txid: txidHex,
        canVerify: true,
        blockHeight: proof.blockHeight,
        merkleRoot: proof.merkleRoot,
        confirmations: confirmations,
        networkHeight: networkHeight,
        isNetworkSynced: isNetworkSynced,
      );
    } catch (e) {
      return TransactionVerificationStatus(
        txid: txidHex,
        canVerify: false,
        reason: 'Error retrieving proof: $e',
        confirmations: 0,
        networkHeight: networkHeight,
      );
    }
  }

  /// Get network statistics
  Map<String, dynamic> getNetworkStatistics() {
    return {
      'networkHeight': networkHeight,
      'isNetworkSynced': isNetworkSynced,
      'activePeers': chainTipTracker.activePeerCount,
      'chainTipConfidence': currentChainTip?.confidence ?? 0.0,
      'trackedTransactions': _trackedTransactions.length,
      'potentialReorgs': chainTipTracker.isPotentialReorg,
      ...chainTipTracker.statistics,
    };
  }

  /// Get block header merkle root from BlockHeaderService
  Future<String?> _getBlockHeaderMerkleRoot(int blockHeight) async {
    return blockHeaderService.getMerkleRoot(blockHeight);
  }

  /// Create BUMP from ARC merkle proof response
  Future<BUMP> _createBUMPFromArcProof(ArcMerkleProofResponse proof) async {
    // This is a simplified implementation
    // Real implementation would need to parse the merkle path from ARC
    return BUMP.fromBytes(Uint8List(0)); // Placeholder
  }

  /// Create BUMP from multiple ARC proofs for the same block
  Future<BUMP> _createBUMPFromArcProofs(List<ArcMerkleProofResponse> proofs) async {
    // This is a simplified implementation
    // Real implementation would need to construct the merkle tree properly
    return BUMP.fromBytes(Uint8List(0)); // Placeholder
  }

  /// Convert hex string to bytes
  Uint8List _hexToBytes(String hex) {
    final bytes = <int>[];
    for (int i = 0; i < hex.length; i += 2) {
      bytes.add(int.parse(hex.substring(i, i + 2), radix: 16));
    }
    return Uint8List.fromList(bytes);
  }

  /// Convert bytes to hex string
  String _bytesToHex(List<int> bytes) {
    return bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join('');
  }

  /// Shutdown the service
  Future<void> shutdown() async {
    await _chainTipSubscription.cancel();
    await _confirmationController.close();
    
    // Cancel all timers
    for (final timer in _confirmationTimers.values) {
      timer.cancel();
    }
    _confirmationTimers.clear();
    _trackedTransactions.clear();
  }
}

/// Tracked transaction for confirmation monitoring
class TrackedTransaction {
  final String txid;
  int blockHeight;
  int confirmations;
  final int requiredConfirmations;
  ArcMerkleProofResponse? merkleProof;
  final DateTime startedTracking;
  DateTime lastUpdated;

  TrackedTransaction({
    required this.txid,
    required this.blockHeight,
    required this.confirmations,
    required this.requiredConfirmations,
    this.merkleProof,
    required this.startedTracking,
    required this.lastUpdated,
  });
}

/// Transaction confirmation update event
class TransactionConfirmationUpdate {
  final String txid;
  final int blockHeight;
  final int confirmations;
  final bool isConfirmed;
  final int networkHeight;
  final bool reorgDetected;

  TransactionConfirmationUpdate({
    required this.txid,
    required this.blockHeight,
    required this.confirmations,
    required this.isConfirmed,
    required this.networkHeight,
    this.reorgDetected = false,
  });

  @override
  String toString() => 'TransactionConfirmationUpdate($txid: $confirmations confirmations, confirmed: $isConfirmed)';
}

/// Enhanced transaction verification status
class TransactionVerificationStatus {
  final String txid;
  final bool canVerify;
  final String? reason;
  final int? blockHeight;
  final String? merkleRoot;
  final int confirmations;
  final int networkHeight;
  final bool isNetworkSynced;

  TransactionVerificationStatus({
    required this.txid,
    required this.canVerify,
    this.reason,
    this.blockHeight,
    this.merkleRoot,
    required this.confirmations,
    required this.networkHeight,
    this.isNetworkSynced = false,
  });
}

/// SPV validation result with detailed information
class SPVValidationResult {
  final bool isValid;
  final String? reason;
  final List<String> validatedTxids;
  final List<String> failedTxids;

  SPVValidationResult({
    required this.isValid,
    this.reason,
    this.validatedTxids = const [],
    this.failedTxids = const [],
  });
}

/// Exception thrown by SPV service operations
class SPVException implements Exception {
  final String message;
  
  SPVException(this.message);
  
  @override
  String toString() => 'SPVException: $message';
} 