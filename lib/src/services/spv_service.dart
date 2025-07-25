import 'dart:async';
import 'dart:typed_data';

import '../utils/beef.dart';
import '../utils/bump.dart';
import 'arc_service.dart';

/// SPV service for Bitcoin SV transaction validation using BEEF/BUMP
/// Integrates with ARC service for merkle proof retrieval and validation
class SPVService {
  final ArcService arcService;
  final Function(int blockHeight)? getBlockHeaderMerkleRoot;

  SPVService({
    required this.arcService,
    this.getBlockHeaderMerkleRoot,
  });

  /// Validate a BEEF package against block headers
  /// Returns true if all transactions with merkle proofs are valid
  Future<bool> validateBEEF(BEEF beef) async {
    // Basic BEEF structure validation
    if (!beef.validate()) {
      return false;
    }

    // Get transactions with merkle proofs
    final verifiedTxs = beef.getVerifiedTransactions();
    
    if (verifiedTxs.isEmpty) {
      return true; // No transactions to validate
    }

    // Validate each transaction with merkle proof
    for (final tx in verifiedTxs) {
      final txid = tx['txid'] as Uint8List;
      final blockHeight = tx['blockHeight'] as int;
      final bumpIdx = tx['bumpIndex'] as int;
      
      // Get block header merkle root (integration point)
      if (getBlockHeaderMerkleRoot != null) {
        final blockMerkleRoot = await getBlockHeaderMerkleRoot!(blockHeight);
        if (blockMerkleRoot == null) {
          return false; // Block header not available
        }
        
        // Compute merkle root from BUMP
        final computedMerkleRoot = beef.bumps[bumpIdx].computeMerkleRoot(txid);
        final computedMerkleRootHex = _bytesToHex(computedMerkleRoot.reversed.toList());
        
        // Compare merkle roots
        if (computedMerkleRootHex != blockMerkleRoot) {
          return false; // Merkle root mismatch
        }
      } else {
        // Fallback: Just validate the merkle path structure
        if (!beef.bumps[bumpIdx].validateMerklePath(txid)) {
          return false; // Invalid merkle path
        }
      }
    }

    return true;
  }

  /// Validate a single transaction using BEEF
  Future<bool> validateTransaction(String txidHex, BEEF beef) async {
    return beef.validateTransactionHex(txidHex);
  }

  /// Create a BEEF package for a list of transactions
  /// Retrieves merkle proofs from ARC service
  Future<BEEF?> createBEEF(List<String> txids) async {
    try {
      // Get merkle proofs for all transactions
      final proofs = await arcService.getBatchMerkleProofs(txids);
      
      if (proofs.isEmpty) {
        return null; // No proofs available
      }

      // Convert ARC proofs to BUMPs
      final bumps = <BUMP>[];
      final txs = <Uint8List>[];
      final hasMerkle = <bool>[];
      final bumpIndex = <int>[];

      // Group proofs by block height to create BUMPs
      final proofsByHeight = <int, List<ArcMerkleProofResponse>>{};
      for (final proof in proofs) {
        proofsByHeight.putIfAbsent(proof.blockHeight, () => []).add(proof);
      }

      // Create BUMPs for each block height
      for (final entry in proofsByHeight.entries) {
        final blockHeight = entry.key;
        final blockProofs = entry.value;
        
        // Convert merkle proofs to BUMP format
        final bump = _createBUMPFromProofs(blockHeight, blockProofs);
        bumps.add(bump);
      }

      // Get raw transaction data and build BEEF structure
      int currentBumpIndex = 0;
      for (int i = 0; i < txids.length; i++) {
        final txid = txids[i];
        
        // Get raw transaction from ARC
        final rawTx = await arcService.getRawTransaction(txid);
        if (rawTx.isEmpty) {
          continue; // Skip if transaction not found
        }
        
        final txBytes = _hexToBytes(rawTx);
        txs.add(txBytes);
        
        // Check if this transaction has a proof
        final hasProof = proofs.any((p) => p.txid == txid);
        hasMerkle.add(hasProof);
        
        if (hasProof) {
          // Find which BUMP this transaction belongs to
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
      return null; // Failed to create BEEF
    }
  }

  /// Get verification status for a transaction
  /// Returns information about whether the transaction can be validated
  Future<TransactionVerificationStatus> getVerificationStatus(String txidHex) async {
    try {
      // Try to get merkle proof from ARC
      final proof = await arcService.getMerkleProof(txidHex);
      
      if (proof == null) {
        return TransactionVerificationStatus(
          txid: txidHex,
          canVerify: false,
          reason: 'No merkle proof available',
        );
      }

      return TransactionVerificationStatus(
        txid: txidHex,
        canVerify: true,
        blockHeight: proof.blockHeight,
        merkleRoot: proof.merkleRoot,
      );

    } catch (e) {
      return TransactionVerificationStatus(
        txid: txidHex,
        canVerify: false,
        reason: 'Error retrieving proof: $e',
      );
    }
  }

  /// Convert ARC merkle proofs to BUMP format
  /// This is a simplified implementation - a full implementation would
  /// need to properly construct the merkle tree structure
  BUMP _createBUMPFromProofs(int blockHeight, List<ArcMerkleProofResponse> proofs) {
    // Simplified BUMP creation - in production, this would need
    // to properly reconstruct the merkle tree structure from the proofs
    final levels = <Level>[];
    
    // Create a basic level with the transaction leaves
    final leaves = <Leaf>[];
    for (int i = 0; i < proofs.length; i++) {
      final proof = proofs[i];
      final txidBytes = _hexToBytes(proof.txid);
      
      leaves.add(Leaf(
        offset: i,
        duplicate: false,
        isTxid: true,
        hash: txidBytes,
      ));
    }
    
    levels.add(Level(leaves: leaves));
    
    return BUMP(
      blockHeight: blockHeight,
      path: levels,
    );
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
}

/// Transaction verification status information
class TransactionVerificationStatus {
  final String txid;
  final bool canVerify;
  final String? reason;
  final int? blockHeight;
  final String? merkleRoot;

  TransactionVerificationStatus({
    required this.txid,
    required this.canVerify,
    this.reason,
    this.blockHeight,
    this.merkleRoot,
  });
}

/// SPV validation result
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