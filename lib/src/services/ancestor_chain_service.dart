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

    // The walk runs from the UTXOs back to the proofs (children first);
    // BRC-62 wants parents before the children that spend them.
    final ordered = orderParentsFirst(ancestorTxs);
    return AncestorChainResult.success(
      ancestorTransactions: ordered,
      merkleProofs: _proofsInTransactionOrder(ordered, merkleProofs),
      blockHeights: blockHeights.toList(),
    );
  }

  /// [transactions] in topological order: every transaction after the ones
  /// in the list it spends (BRC-62). Otherwise the input order is kept.
  ///
  /// A transaction whose raw hex does not parse is treated as having no
  /// in-list parents.
  static List<BitcoinTransaction> orderParentsFirst(List<BitcoinTransaction> transactions) {
    final byId = <String, BitcoinTransaction>{};
    for (final tx in transactions) {
      byId.putIfAbsent(tx.txid, () => tx);
    }
    final parents = <String, List<String>>{};
    for (final tx in byId.values) {
      final inList = <String>[];
      try {
        for (final input in dartsv.Transaction.fromHex(tx.rawHex).inputs) {
          if (byId.containsKey(input.prevTxnId) && input.prevTxnId != tx.txid) {
            inList.add(input.prevTxnId);
          }
        }
      } catch (e) {
        _log.warning('Cannot parse ${tx.txid} while ordering ancestors: $e');
      }
      parents[tx.txid] = inList;
    }

    final ordered = <BitcoinTransaction>[];
    final done = <String>{};
    final inProgress = <String>{};
    void visit(String txid) {
      if (done.contains(txid) || !inProgress.add(txid)) return; // cycle guard
      for (final parent in parents[txid]!) {
        visit(parent);
      }
      inProgress.remove(txid);
      done.add(txid);
      ordered.add(byId[txid]!);
    }

    for (final txid in byId.keys) {
      visit(txid);
    }
    return ordered;
  }

  /// [proofs] reordered to follow the proven transactions in [ordered], so
  /// the k-th transaction with a proof uses the k-th BUMP. Proofs for
  /// transactions not in [ordered] keep their relative order at the end.
  static List<MerkleProof> _proofsInTransactionOrder(
      List<BitcoinTransaction> ordered, List<MerkleProof> proofs) {
    final byTxid = <String, MerkleProof>{};
    for (final proof in proofs) {
      byTxid.putIfAbsent(proof.txid, () => proof);
    }
    final result = <MerkleProof>[];
    for (final tx in ordered) {
      final proof = byTxid.remove(tx.txid);
      if (proof != null) result.add(proof);
    }
    result.addAll(proofs.where((p) => byTxid.remove(p.txid) != null));
    return result;
  }

  /// Raw transactions, BUMPs, has-BUMP flags and BUMP indices for a BEEF of
  /// [ancestors] (reordered parents first) followed by [unproven], in order.
  static BEEF _buildBeef(
    List<BitcoinTransaction> ancestors,
    List<BitcoinTransaction> unproven,
    List<MerkleProof> merkleProofs,
  ) {
    final ordered = orderParentsFirst(ancestors);
    final proofs = _proofsInTransactionOrder(ordered, merkleProofs);
    final proofIndex = <String, int>{};
    final bumps = <BUMP>[];
    for (final proof in proofs) {
      if (proofIndex.containsKey(proof.txid)) continue;
      proofIndex[proof.txid] = bumps.length;
      bumps.add(CryptoUtils.buildBUMPFromMerkleProof(proof));
    }

    final txBytes = <Uint8List>[];
    final hasMerkle = <bool>[];
    final bumpIndex = <int>[];
    for (final tx in ordered) {
      txBytes.add(Uint8List.fromList(hex.decode(tx.rawHex)));
      final idx = proofIndex[tx.txid];
      hasMerkle.add(idx != null);
      if (idx != null) bumpIndex.add(idx);
    }
    // New transactions have no merkle proof yet (unconfirmed).
    for (final tx in unproven) {
      txBytes.add(Uint8List.fromList(hex.decode(tx.rawHex)));
      hasMerkle.add(false);
    }

    return BEEF.create(
      bumps: bumps,
      txs: txBytes,
      hasMerkle: hasMerkle,
      bumpIndex: bumpIndex,
    );
  }

  /// Collect ancestor chain for a single transaction
  Future<AncestorChainResult> collectAncestorChain(String txid) async {
    return collectAncestorChainForUtxos([txid]);
  }

  /// Create BEEF package from a new transaction and its ancestor chain
  ///
  /// Orders transactions per BRC-62: ancestors parents first (whatever
  /// order they are passed in), then the new transaction (no proof). BUMPs
  /// follow the order of the proven transactions.
  Future<BEEFWithAncestryResult> createBeefWithAncestry({
    required BitcoinTransaction newTransaction,
    required List<BitcoinTransaction> ancestorTransactions,
    required List<MerkleProof> merkleProofs,
  }) async {
    try {
      final serialized = _buildBeef(ancestorTransactions, [newTransaction], merkleProofs).serialize();

      // Sanity check: the BEEF must parse.
      try {
        BEEF.parse(serialized);
      } catch (e) {
        throw Exception('Created BEEF is invalid: $e');
      }

      return BEEFWithAncestryResult.success(
        beefBytes: serialized,
        ancestorCount: ancestorTransactions.length,
        proofCount: merkleProofs.length,
      );
    } catch (e) {
      return BEEFWithAncestryResult.error('Failed to create BEEF: $e');
    }
  }

  /// Create BEEF from multiple new transactions (e.g., funding tx + payment tx)
  ///
  /// Ancestors are ordered parents first; [newTransactions] follow in the
  /// order given (callers pass them parents first).
  Future<BEEFWithAncestryResult> createBeefWithMultipleNewTransactions({
    required List<BitcoinTransaction> newTransactions,
    required List<BitcoinTransaction> ancestorTransactions,
    required List<MerkleProof> merkleProofs,
  }) async {
    try {
      final serialized = _buildBeef(ancestorTransactions, newTransactions, merkleProofs).serialize();

      try {
        BEEF.parse(serialized);
      } catch (e) {
        throw Exception('Created BEEF is invalid: $e');
      }

      return BEEFWithAncestryResult.success(
        beefBytes: serialized,
        ancestorCount: ancestorTransactions.length,
        proofCount: merkleProofs.length,
      );
    } catch (e) {
      return BEEFWithAncestryResult.error('Failed to create BEEF: $e');
    }
  }
}


