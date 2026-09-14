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
///   "nodes": ["<hash1>", "*", ...] // Sibling hashes bottom-up; "*" = duplicate
/// }
///
/// BUMP (BSV Universal Merkle Path, BRC-74) is the binary merkle path format
/// embedded in BEEF; see [BUMP] for the layout.
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

    // TSC nodes are display-format (big-endian) hex, bottom-up, with "*"
    // marking a level where the working hash is paired with itself. An empty
    // list is the single-transaction block (root == txid). BUMP.fromTscProof
    // is the one BRC-74 builder in the library; it reverses the hashes into
    // internal byte order and emits txid + sibling at level 0.
    try {
      return BUMP.fromTscProof(
        blockHeight: proofData.blockHeight,
        txid: proofData.txid,
        index: proofData.index,
        nodes: proofData.nodes,
      );
    } on BUMPException catch (e) {
      throw TscConversionException(e.message, txid: proofData.txid, originalError: e);
    }
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

      // Validate all nodes are 32-byte hex hashes or the "*" duplicate marker
      // (an empty list is the single-transaction block)
      if (nodes.any((node) => node is! String || (node != '*' && node.length != 64))) {
        _logger.warning('TSC proof contains a node that is neither a hash nor "*"');
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

