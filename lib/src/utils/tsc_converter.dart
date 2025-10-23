import 'dart:typed_data';
import 'package:convert/convert.dart';
import 'package:logging/logging.dart' hide Level;

import '../models/blockchain_data_models.dart';
import 'bump.dart';

/// Converter for TSC (Transaction Confirmation Proof) format to BUMP
///
/// TSC is the merkle proof format returned by WhatsOnChain API:
/// {
///   "index": <transaction position in block>,
///   "txOrId": "<transaction id>",
///   "target": "<merkle root>",
///   "nodes": ["<hash1>", "<hash2>", ...] // Sibling hashes
/// }
///
/// BUMP (BSV Universal Merkle Path) is LibSpiffy's compact binary format
/// for merkle proofs, supporting SPV validation.
class TscConverter {
  final Logger _logger = Logger('TscConverter');

  /// Convert TSC merkle proof data to BUMP format
  ///
  /// Parameters:
  /// - [proofData]: MerkleProofData containing TSC-format proof
  ///
  /// Returns a BUMP structure ready for SPV validation.
  ///
  /// Example:
  /// ```dart
  /// final converter = TscConverter();
  /// final bump = converter.convertToBump(merkleProofData);
  /// ```
  BUMP convertToBump(MerkleProofData proofData) {
    _logger.fine('Converting TSC proof for ${proofData.txid}');

    if (proofData.nodes.isEmpty) {
      throw TscConversionException(
        'TSC proof has no sibling nodes',
        txid: proofData.txid,
      );
    }

    // Build merkle path from TSC nodes
    final path = _buildMerklePath(
      txIndex: proofData.index,
      siblingHashes: proofData.nodes,
    );

    return BUMP(
      blockHeight: proofData.blockHeight,
      path: path,
    );
  }

  /// Build merkle path from transaction index and sibling hashes
  ///
  /// The merkle path represents the route from the transaction (leaf) to the
  /// merkle root. At each level, we need to know:
  /// - The sibling hash (from TSC nodes)
  /// - Whether our node is on the left or right
  ///
  /// The transaction index tells us the position at the leaf level.
  /// We divide by 2 at each level to determine the parent position.
  List<Level> _buildMerklePath({
    required int txIndex,
    required List<String> siblingHashes,
  }) {
    final path = <Level>[];
    int currentPosition = txIndex;

    for (int levelIndex = 0; levelIndex < siblingHashes.length; levelIndex++) {
      final siblingHash = siblingHashes[levelIndex];

      // Determine if we're on the left (even) or right (odd) at this level
      final isRightSide = (currentPosition % 2) == 1;

      // The sibling hash is always on the opposite side
      // If we're on right (index odd), sibling is on left (offset = currentPosition - 1)
      // If we're on left (index even), sibling is on right (offset = currentPosition + 1)
      final siblingOffset = isRightSide ? currentPosition - 1 : currentPosition + 1;

      // Convert sibling hash from hex to bytes
      Uint8List hashBytes;
      try {
        hashBytes = Uint8List.fromList(hex.decode(siblingHash));
      } catch (e) {
        throw TscConversionException(
          'Invalid hex hash at level $levelIndex: $siblingHash',
        );
      }

      if (hashBytes.length != 32) {
        throw TscConversionException(
          'Hash at level $levelIndex has invalid length ${hashBytes.length} (expected 32)',
        );
      }

      // Create level with sibling leaf
      final level = Level(
        leaves: [
          Leaf(
            offset: siblingOffset,
            hash: hashBytes,
            isTxid: false, // Sibling hashes are never txids
            duplicate: false,
          ),
        ],
      );

      path.add(level);

      // Move to parent position for next level
      currentPosition = currentPosition ~/ 2;
    }

    return path;
  }

  /// Validate that a TSC proof has all required fields
  bool validateTscProof(Map<String, dynamic> tscProof) {
    try {
      if (!tscProof.containsKey('index') || tscProof['index'] is! int) {
        _logger.warning('TSC proof missing or invalid index field');
        return false;
      }

      if (!tscProof.containsKey('txOrId') || tscProof['txOrId'] is! String) {
        _logger.warning('TSC proof missing or invalid txOrId field');
        return false;
      }

      if (!tscProof.containsKey('target') || tscProof['target'] is! String) {
        _logger.warning('TSC proof missing or invalid target field');
        return false;
      }

      if (!tscProof.containsKey('nodes') || tscProof['nodes'] is! List) {
        _logger.warning('TSC proof missing or invalid nodes field');
        return false;
      }

      final nodes = tscProof['nodes'] as List;
      if (nodes.isEmpty) {
        _logger.warning('TSC proof has empty nodes array');
        return false;
      }

      // Validate all nodes are strings
      if (nodes.any((node) => node is! String)) {
        _logger.warning('TSC proof contains non-string node');
        return false;
      }

      return true;
    } catch (e) {
      _logger.warning('Error validating TSC proof: $e');
      return false;
    }
  }

  /// Validate that a BUMP structure is valid
  bool validateBump(BUMP bump) {
    try {
      if (bump.blockHeight < 0) {
        _logger.warning('BUMP has invalid block height: ${bump.blockHeight}');
        return false;
      }

      if (bump.path.isEmpty) {
        _logger.warning('BUMP has empty path');
        return false;
      }

      for (int i = 0; i < bump.path.length; i++) {
        final level = bump.path[i];

        if (level.leaves.isEmpty) {
          _logger.warning('BUMP level $i has no leaves');
          return false;
        }

        for (final leaf in level.leaves) {
          if (!leaf.duplicate && (leaf.hash == null || leaf.hash!.length != 32)) {
            _logger.warning(
              'BUMP level $i has invalid hash (length: ${leaf.hash?.length})',
            );
            return false;
          }
        }
      }

      return true;
    } catch (e) {
      _logger.warning('Error validating BUMP: $e');
      return false;
    }
  }

  /// Create a MerkleProofData from raw TSC response
  ///
  /// This is a helper method for converting raw WhatsOnChain API responses
  /// into MerkleProofData objects.
  MerkleProofData createProofDataFromTsc({
    required Map<String, dynamic> tscProof,
    required int blockHeight,
  }) {
    if (!validateTscProof(tscProof)) {
      throw TscConversionException('Invalid TSC proof structure');
    }

    return MerkleProofData(
      txid: tscProof['txOrId'] as String,
      blockHeight: blockHeight,
      merkleRoot: tscProof['target'] as String,
      index: tscProof['index'] as int,
      nodes: (tscProof['nodes'] as List).cast<String>(),
      format: 'tsc',
      rawData: tscProof,
    );
  }
}

/// Exception thrown during TSC to BUMP conversion
class TscConversionException implements Exception {
  final String message;
  final String? txid;
  final dynamic originalError;

  TscConversionException(
    this.message, {
    this.txid,
    this.originalError,
  });

  @override
  String toString() {
    final buffer = StringBuffer('TscConversionException: $message');
    if (txid != null) buffer.write(' (txid: $txid)');
    if (originalError != null) buffer.write('\nCaused by: $originalError');
    return buffer.toString();
  }
}

