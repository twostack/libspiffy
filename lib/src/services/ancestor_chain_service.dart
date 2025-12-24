/// Ancestor Chain Collection and BEEF Creation Service
///
/// This service provides reusable logic for collecting ancestor transactions
/// back to merkle proofs and building BEEF packages with proper ordering.
///
/// Used by:
/// - PaymentCoordinatorActor: For P2P invoice payments
/// - PaymentChannelService: For unconfirmed funding transaction support

import 'dart:typed_data';
import 'package:convert/convert.dart';
import 'package:dartsv/dartsv.dart' as dartsv;

import '../models/bitcoin_transaction.dart';
import '../storage/read_model_storage.dart';
import '../utils/beef.dart';
import '../utils/bump.dart';

/// Result of ancestor chain collection
class AncestorChainResult {
  final bool isValid;
  final List<BitcoinTransaction> ancestorTransactions;
  final List<MerkleProof> merkleProofs;
  final List<int> blockHeights;
  final String? error;

  AncestorChainResult.success({
    required this.ancestorTransactions,
    required this.merkleProofs,
    required this.blockHeights,
  })  : isValid = true,
        error = null;

  AncestorChainResult.error(this.error)
      : isValid = false,
        ancestorTransactions = const [],
        merkleProofs = const [],
        blockHeights = const [];
}

/// Result of BEEF creation with ancestry
class BEEFWithAncestryResult {
  final bool success;
  final Uint8List? beefBytes;
  final String? beefHex;
  final int? ancestorCount;
  final int? proofCount;
  final String? error;

  BEEFWithAncestryResult.success({
    required this.beefBytes,
    required this.ancestorCount,
    required this.proofCount,
  })  : success = true,
        beefHex = beefBytes != null ? hex.encode(beefBytes) : null,
        error = null;

  BEEFWithAncestryResult.error(this.error)
      : success = false,
        beefBytes = null,
        beefHex = null,
        ancestorCount = null,
        proofCount = null;
}

/// Service for collecting ancestor transaction chains and creating BEEFs
class AncestorChainService {
  final ReadModelStorage _storage;

  AncestorChainService({
    required ReadModelStorage storage,
  }) : _storage = storage;

  /// Collect ancestor chain for a list of UTXOs
  ///
  /// Walks back through the transaction graph until merkle proofs are found.
  /// This is critical for creating valid BEEFs when the immediate transaction
  /// doesn't have a merkle proof yet (unconfirmed).
  Future<AncestorChainResult> collectAncestorChainForUtxos(
    List<String> utxoTxids,
  ) async {
    final ancestorTxs = <BitcoinTransaction>[];
    final merkleProofs = <MerkleProof>[];
    final blockHeights = <int>{};
    final visited = <String>{}; // Prevent infinite loops

    for (final txid in utxoTxids) {
      final result = await _collectAncestorsRecursive(
        txid,
        visited,
        ancestorTxs,
        merkleProofs,
        blockHeights,
      );

      if (!result.success) {
        return AncestorChainResult.error(result.error!);
      }
    }

    // Validate we have at least one merkle proof
    if (merkleProofs.isEmpty) {
      return AncestorChainResult.error(
        'No merkle proofs found in transaction chain - cannot create valid BEEF',
      );
    }

    return AncestorChainResult.success(
      ancestorTransactions: ancestorTxs,
      merkleProofs: merkleProofs,
      blockHeights: blockHeights.toList(),
    );
  }

  /// Collect ancestor chain for a single transaction
  Future<AncestorChainResult> collectAncestorChain(String txid) async {
    return collectAncestorChainForUtxos([txid]);
  }

  /// Recursively collect ancestors until merkle proof found
  Future<_CollectionStep> _collectAncestorsRecursive(
    String txid,
    Set<String> visited,
    List<BitcoinTransaction> ancestorTxs,
    List<MerkleProof> merkleProofs,
    Set<int> blockHeights,
  ) async {
    // Skip if already processed
    if (visited.contains(txid)) {
      return _CollectionStep.success();
    }
    visited.add(txid);

    // Get transaction from storage (must exist)
    final tx = await _storage.getTransaction(txid);
    if (tx == null) {
      return _CollectionStep.error(
        'Transaction $txid not found in storage - may need to import historical transactions',
      );
    }

    // Check for merkle proof (stopping condition)
    final proof = await _storage.getMerkleProof(txid);

    if (proof != null) {
      // Found merkle proof - chain complete for this branch
      ancestorTxs.add(tx);
      merkleProofs.add(proof);
      blockHeights.add(proof.blockHeight);
      return _CollectionStep.success();
    }

    // No merkle proof - must recurse to parents
    ancestorTxs.add(tx);

    // Parse transaction to get parent txids
    try {
      final dartsvTx = dartsv.Transaction.fromHex(tx.rawHex);

      for (final input in dartsvTx.inputs) {
        final parentTxid = input.prevTxnId;

        // Recursively process parent
        final result = await _collectAncestorsRecursive(
          parentTxid,
          visited,
          ancestorTxs,
          merkleProofs,
          blockHeights,
        );

        if (!result.success) {
          return result; // Propagate error
        }
      }
    } catch (e) {
      return _CollectionStep.error('Failed to parse transaction $txid: $e');
    }

    return _CollectionStep.success();
  }

  /// Create BEEF package from a new transaction and its ancestor chain
  ///
  /// Orders transactions correctly: ancestors (with proofs) → new transaction (no proof)
  Future<BEEFWithAncestryResult> createBeefWithAncestry({
    required BitcoinTransaction newTransaction,
    required List<BitcoinTransaction> ancestorTransactions,
    required List<MerkleProof> merkleProofs,
  }) async {
    try {
      print('  📥 createBeefWithAncestry:');
      print('    New transaction: ${newTransaction.txid}');
      print('    Ancestor transactions: ${ancestorTransactions.length}');
      print('    Merkle proofs: ${merkleProofs.length}');

      // 1. Convert all transactions to raw bytes
      final txBytes = <Uint8List>[];

      // Add ancestor transactions first (in order they were collected)
      for (final tx in ancestorTransactions) {
        txBytes.add(Uint8List.fromList(hex.decode(tx.rawHex)));
      }

      // Add new transaction last (no merkle proof yet)
      txBytes.add(Uint8List.fromList(hex.decode(newTransaction.rawHex)));

      // 2. Build BUMPs from merkle proofs
      final bumps = <BUMP>[];
      for (final proof in merkleProofs) {
        bumps.add(_buildBUMPFromMerkleProof(proof));
      }

      // 3. Set hasMerkle flags - only ancestors with proofs have true
      final hasMerkle = <bool>[];
      for (final ancestor in ancestorTransactions) {
        final hasProof = merkleProofs.any((p) => p.txid == ancestor.txid);
        hasMerkle.add(hasProof);
      }
      // New transaction doesn't have a merkle proof yet (unconfirmed)
      hasMerkle.add(false);

      // 4. Build bumpIndex array - maps transactions with proofs to their BUMP index
      final bumpIndex = <int>[];
      for (int i = 0; i < ancestorTransactions.length; i++) {
        if (hasMerkle[i]) {
          // Find which BUMP this transaction corresponds to
          final proofIdx = merkleProofs
              .indexWhere((p) => p.txid == ancestorTransactions[i].txid);
          if (proofIdx != -1) {
            bumpIndex.add(proofIdx);
          }
        }
      }

      print('  📊 BEEF.create() inputs:');
      print('    txBytes: ${txBytes.length} transactions');
      print('    bumps: ${bumps.length} merkle proofs');
      print('    hasMerkle: ${hasMerkle.length} flags = $hasMerkle');
      print('    bumpIndex: ${bumpIndex.length} indices = $bumpIndex');

      // 5. Create BEEF using the existing BEEF.create() method
      final beef = BEEF.create(
        bumps: bumps,
        txs: txBytes,
        hasMerkle: hasMerkle,
        bumpIndex: bumpIndex,
      );

      // 6. Serialize BEEF
      final serialized = beef.serialize();
      print('  ✓ BEEF serialized: ${serialized.length} bytes');

      // 7. Verify BEEF can be parsed (sanity check)
      try {
        final parsed = BEEF.parse(serialized);
        print('  ✓ BEEF parse verification passed');
        print('    Parsed ${parsed.txs.length} transactions');
        print('    Parsed ${parsed.bumps.length} merkle proofs');
      } catch (e, stackTrace) {
        print('  ❌ BEEF parse verification FAILED: $e');
        print('  Stack trace: $stackTrace');
        throw Exception('Created BEEF is invalid: $e');
      }

      return BEEFWithAncestryResult.success(
        beefBytes: serialized,
        ancestorCount: ancestorTransactions.length,
        proofCount: merkleProofs.length,
      );
    } catch (e, stackTrace) {
      print('Error creating BEEF with ancestry: $e');
      print('Stack trace: $stackTrace');
      return BEEFWithAncestryResult.error('Failed to create BEEF: $e');
    }
  }

  /// Create BEEF from multiple new transactions (e.g., funding tx + payment tx)
  Future<BEEFWithAncestryResult> createBeefWithMultipleNewTransactions({
    required List<BitcoinTransaction> newTransactions,
    required List<BitcoinTransaction> ancestorTransactions,
    required List<MerkleProof> merkleProofs,
  }) async {
    try {
      print('  📥 createBeefWithMultipleNewTransactions:');
      print('    New transactions: ${newTransactions.length}');
      print('    Ancestor transactions: ${ancestorTransactions.length}');
      print('    Merkle proofs: ${merkleProofs.length}');

      // 1. Convert all transactions to raw bytes
      final txBytes = <Uint8List>[];

      // Add ancestor transactions first
      for (final tx in ancestorTransactions) {
        txBytes.add(Uint8List.fromList(hex.decode(tx.rawHex)));
      }

      // Add new transactions (in order provided)
      for (final tx in newTransactions) {
        txBytes.add(Uint8List.fromList(hex.decode(tx.rawHex)));
      }

      // 2. Build BUMPs from merkle proofs
      final bumps = <BUMP>[];
      for (final proof in merkleProofs) {
        bumps.add(_buildBUMPFromMerkleProof(proof));
      }

      // 3. Set hasMerkle flags
      final hasMerkle = <bool>[];
      
      // Ancestors with proofs
      for (final ancestor in ancestorTransactions) {
        final hasProof = merkleProofs.any((p) => p.txid == ancestor.txid);
        hasMerkle.add(hasProof);
      }
      
      // New transactions don't have proofs yet
      for (int i = 0; i < newTransactions.length; i++) {
        hasMerkle.add(false);
      }

      // 4. Build bumpIndex array
      final bumpIndex = <int>[];
      for (int i = 0; i < ancestorTransactions.length; i++) {
        if (hasMerkle[i]) {
          final proofIdx = merkleProofs
              .indexWhere((p) => p.txid == ancestorTransactions[i].txid);
          if (proofIdx != -1) {
            bumpIndex.add(proofIdx);
          }
        }
      }

      print('  📊 BEEF.create() inputs:');
      print('    txBytes: ${txBytes.length} transactions');
      print('    bumps: ${bumps.length} merkle proofs');
      print('    hasMerkle: $hasMerkle');
      print('    bumpIndex: $bumpIndex');

      // 5. Create and serialize BEEF
      final beef = BEEF.create(
        bumps: bumps,
        txs: txBytes,
        hasMerkle: hasMerkle,
        bumpIndex: bumpIndex,
      );

      final serialized = beef.serialize();
      print('  ✓ BEEF serialized: ${serialized.length} bytes');

      // 6. Verify
      try {
        final parsed = BEEF.parse(serialized);
        print('  ✓ BEEF parse verification passed');
        print('    Parsed ${parsed.txs.length} transactions');
      } catch (e) {
        print('  ❌ BEEF parse verification FAILED: $e');
        throw Exception('Created BEEF is invalid: $e');
      }

      return BEEFWithAncestryResult.success(
        beefBytes: serialized,
        ancestorCount: ancestorTransactions.length,
        proofCount: merkleProofs.length,
      );
    } catch (e, stackTrace) {
      print('Error creating BEEF: $e');
      print('Stack trace: $stackTrace');
      return BEEFWithAncestryResult.error('Failed to create BEEF: $e');
    }
  }

  /// Build a BUMP from a MerkleProof
  ///
  /// Converts our MerkleProof storage format to the BUMP structure needed for BEEF.
  /// Supports two storage formats:
  /// 1. Raw BUMP hex string (single element > 64 chars) - parse directly
  /// 2. List of sibling hashes (each 64 chars) - build BUMP from scratch
  BUMP _buildBUMPFromMerkleProof(MerkleProof proof) {
    // Check if merkleProof contains a raw BUMP serialization
    if (proof.merkleProof.length == 1 && proof.merkleProof[0].length > 64) {
      // This is a raw BUMP hex string - parse it directly
      print('  [AncestorChain] Detected raw BUMP format, parsing directly...');
      try {
        final bumpBytes = Uint8List.fromList(hex.decode(proof.merkleProof[0]));
        final bump = BUMP.fromBytes(bumpBytes);
        print(
            '  [AncestorChain] ✓ Parsed BUMP: height=${bump.blockHeight}, levels=${bump.path.length}');
        return bump;
      } catch (e) {
        print('  [AncestorChain] ❌ Failed to parse raw BUMP: $e');
        rethrow;
      }
    }

    // Build BUMP from sibling hashes
    final levels = <Level>[];

    // Level 0: Transaction ID at its position in the block
    // CRITICAL: proof.txid is in display format (big-endian) from database
    // but BUMP stores txids in internal format (little-endian)
    final reversedTxid = _reverseHexBytes(proof.txid);
    levels.add(Level(leaves: [
      Leaf(
        offset: proof.position,
        duplicate: false,
        isTxid: true,
        hash: Uint8List.fromList(hex.decode(reversedTxid)),
      ),
    ]));

    // Subsequent levels: merkle path siblings with calculated offsets
    for (int i = 0; i < proof.merkleProof.length; i++) {
      // Calculate sibling offset using bit manipulation
      final indexBit = (proof.position >> i) & 1;
      final siblingOffset =
          indexBit == 0 ? (proof.position | (1 << i)) : (proof.position & ~(1 << i));

      // CRITICAL: proof.merkleProof[i] is in display format (big-endian)
      // but BUMP stores hashes in internal format (little-endian)
      final siblingHashHex = proof.merkleProof[i];
      final reversedHash = _reverseHexBytes(siblingHashHex);

      levels.add(Level(leaves: [
        Leaf(
          offset: siblingOffset,
          duplicate: false,
          isTxid: false,
          hash: Uint8List.fromList(hex.decode(reversedHash)),
        ),
      ]));
    }

    return BUMP(
      blockHeight: proof.blockHeight,
      path: levels,
    );
  }

  /// Reverse bytes in a hex string (for Bitcoin's little-endian format)
  ///
  /// Converts between display format (big-endian) and internal format (little-endian)
  String _reverseHexBytes(String hexString) {
    if (hexString.length % 2 != 0) {
      throw Exception(
          'Hex string must have an even number of characters: $hexString');
    }

    final result = StringBuffer();
    for (int i = hexString.length - 2; i >= 0; i -= 2) {
      result.write(hexString.substring(i, i + 2));
    }
    return result.toString();
  }
}

/// Internal helper for recursion step result
class _CollectionStep {
  final bool success;
  final String? error;

  _CollectionStep.success()
      : success = true,
        error = null;

  _CollectionStep.error(this.error) : success = false;
}

