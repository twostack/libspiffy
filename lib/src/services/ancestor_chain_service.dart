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
import 'package:logging/logging.dart';

import '../models/bitcoin_transaction.dart';
import '../storage/read_model_storage.dart';
import '../utils/beef.dart';
import '../utils/bump.dart';
import '../utils/crypto_utils.dart';

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
  static final _log = Logger('AncestorChainService');
  final ReadModelStorage _storage;

  AncestorChainService({
    required ReadModelStorage storage,
  }) : _storage = storage;

  /// Collect ancestor chain for a list of UTXOs using BFS with batch queries.
  ///
  /// Walks back through the transaction graph until merkle proofs are found.
  /// Uses batch DB queries per depth level for performance.
  ///
  /// Parameters:
  /// - [maxDepth]: Maximum ancestor depth to traverse (default 20, BSV limit is 25)
  /// - [timeout]: Maximum time for collection (default 15 seconds)
  Future<AncestorChainResult> collectAncestorChainForUtxos(
    List<String> utxoTxids, {
    int maxDepth = 20,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final sw = Stopwatch()..start();
    final deadline = DateTime.now().add(timeout);
    final visited = <String>{};
    final ancestorTxs = <BitcoinTransaction>[];
    final merkleProofs = <MerkleProof>[];
    final blockHeights = <int>{};

    var frontier = utxoTxids.toSet();
    int depth = 0;

    while (frontier.isNotEmpty && depth < maxDepth) {
      if (DateTime.now().isAfter(deadline)) {
        _log.warning('Ancestor collection timed out at depth $depth after ${sw.elapsedMilliseconds}ms '
            '(visited ${visited.length} txs)');
        return AncestorChainResult.error(
          'Ancestor chain collection timed out after ${sw.elapsedMilliseconds}ms '
          '(depth=$depth, visited=${visited.length})',
        );
      }

      final unvisited = frontier.difference(visited).toList();
      if (unvisited.isEmpty) break;
      visited.addAll(unvisited);

      // Batch fetch transactions and proofs for this depth level
      final txMap = await _storage.getTransactionsBatch(unvisited);
      final proofMap = await _storage.getMerkleProofsBatch(unvisited);

      final nextFrontier = <String>{};

      for (final txid in unvisited) {
        final tx = txMap[txid];
        if (tx == null) {
          _log.warning('Transaction $txid not found at depth $depth');
          return AncestorChainResult.error(
            'Transaction $txid not found in storage - may need to import historical transactions',
          );
        }

        ancestorTxs.add(tx);

        final proof = proofMap[txid];
        if (proof != null) {
          // Found merkle proof — this branch is complete
          merkleProofs.add(proof);
          blockHeights.add(proof.blockHeight);
        } else {
          // No proof — parse inputs to continue walking
          try {
            final dartsvTx = dartsv.Transaction.fromHex(tx.rawHex);
            for (final input in dartsvTx.inputs) {
              nextFrontier.add(input.prevTxnId);
            }
          } catch (e) {
            return AncestorChainResult.error('Failed to parse transaction $txid: $e');
          }
        }
      }

      frontier = nextFrontier;
      depth++;
    }

    _log.info('Ancestor collection: ${sw.elapsedMilliseconds}ms, '
        'depth=$depth, visited=${visited.length}, '
        'ancestors=${ancestorTxs.length}, proofs=${merkleProofs.length}');

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

  /// Create BEEF package from a new transaction and its ancestor chain
  ///
  /// Orders transactions correctly: ancestors (with proofs) → new transaction (no proof)
  Future<BEEFWithAncestryResult> createBeefWithAncestry({
    required BitcoinTransaction newTransaction,
    required List<BitcoinTransaction> ancestorTransactions,
    required List<MerkleProof> merkleProofs,
  }) async {
    try {

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
        bumps.add(CryptoUtils.buildBUMPFromMerkleProof(proof));
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


      // 5. Create BEEF using the existing BEEF.create() method
      final beef = BEEF.create(
        bumps: bumps,
        txs: txBytes,
        hasMerkle: hasMerkle,
        bumpIndex: bumpIndex,
      );

      // 6. Serialize BEEF
      final serialized = beef.serialize();

      // 7. Verify BEEF can be parsed (sanity check)
      try {
        final parsed = BEEF.parse(serialized);
      } catch (e, stackTrace) {
        throw Exception('Created BEEF is invalid: $e');
      }

      return BEEFWithAncestryResult.success(
        beefBytes: serialized,
        ancestorCount: ancestorTransactions.length,
        proofCount: merkleProofs.length,
      );
    } catch (e, stackTrace) {
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
        bumps.add(CryptoUtils.buildBUMPFromMerkleProof(proof));
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


      // 5. Create and serialize BEEF
      final beef = BEEF.create(
        bumps: bumps,
        txs: txBytes,
        hasMerkle: hasMerkle,
        bumpIndex: bumpIndex,
      );

      final serialized = beef.serialize();

      // 6. Verify
      try {
        final parsed = BEEF.parse(serialized);
      } catch (e) {
        throw Exception('Created BEEF is invalid: $e');
      }

      return BEEFWithAncestryResult.success(
        beefBytes: serialized,
        ancestorCount: ancestorTransactions.length,
        proofCount: merkleProofs.length,
      );
    } catch (e, stackTrace) {
      return BEEFWithAncestryResult.error('Failed to create BEEF: $e');
    }
  }

}


