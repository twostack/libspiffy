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
import '../spv/merkle_proof_header_check.dart';
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

      // Batch fetch transactions and proofs for this depth level. A txid
      // that is no wallet's transaction may be an ancestor a received BEEF
      // carried (bead zsh).
      final txMap = {...await _storage.getTransactionsBatch(unvisited)};
      final missing = [for (final txid in unvisited) if (!txMap.containsKey(txid)) txid];
      if (missing.isNotEmpty) {
        final ancestors = await _storage.getAncestorTransactionsBatch(missing);
        for (final entry in ancestors.entries) {
          txMap[entry.key] = _ancestorRecord(entry.key, entry.value);
        }
      }
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
        if (proof != null && await _usableInBeef(proof)) {
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

  /// Whether [proof] may go into a BEEF (bead azl). Only a transaction's
  /// current proof is returned by the storage, and of those:
  /// * a [MerkleProofStatus.verified] proof is used: it matched the active
  ///   header at its height, and a reorganization marks it orphaned;
  /// * a [MerkleProofStatus.pendingHeader] proof is used while no header is
  ///   known at its height: SPV has the receiver check it against its own
  ///   headers, and a wallet may hand on a transaction before its own
  ///   headers have caught up. If a header has arrived there since (SPVActor
  ///   has not re-checked the proof yet, or the row predates azl) it is used
  ///   only if it matches that header;
  /// * nothing else ([MerkleProofStatus.orphaned], [MerkleProofStatus.rejected])
  ///   is ever used, whatever a storage implementation returns.
  /// An unusable proof is treated as no proof: the walk continues to the
  /// transaction's inputs.
  Future<bool> _usableInBeef(MerkleProof proof) async {
    switch (proof.status) {
      case MerkleProofStatus.verified:
        return true;
      case MerkleProofStatus.orphaned:
      case MerkleProofStatus.rejected:
        _log.warning('Stored ${proof.status.name} proof for ${proof.txid} is not used in a BEEF');
        return false;
      case MerkleProofStatus.pendingHeader:
        final check = await checkBumpHexAgainstHeaders(
          txid: proof.txid,
          bumpHex: proof.merkleProof.length == 1 ? proof.merkleProof.single : '',
          headerAt: _storage.getBlockHeaderByHeight,
        );
        if (check.isVerified || check.status == ProofHeaderStatus.headerUnknown) return true;
        _log.warning('Unverified proof for ${proof.txid} does not match the stored header chain ($check); '
            'not used in a BEEF');
        return false;
    }
  }

  /// A stored ancestor transaction (no wallet row) as the record the BEEF
  /// builders use: only [BitcoinTransaction.txid] and `rawHex` are read.
  static BitcoinTransaction _ancestorRecord(String txid, String rawHex) {
    final epoch = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    return BitcoinTransaction(
      txid: txid,
      rawHex: rawHex,
      status: TransactionStatus.pending,
      inputValue: BigInt.zero,
      outputValue: BigInt.zero,
      fee: BigInt.zero,
      receivingAddresses: const [],
      sendingAddresses: const [],
      netAmount: BigInt.zero,
      createdAt: epoch,
      updatedAt: epoch,
      lockTime: 0,
      version: 1,
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
  ///
  /// Ancestors mined in the same block share one BRC-74 multi-leaf BUMP
  /// instead of one BUMP each (see [BeefBumps]); the BEEF is the single
  /// place every outgoing BEEF of the library is assembled, so they all do.
  static BEEF buildBeef(
    List<BitcoinTransaction> ancestors,
    List<BitcoinTransaction> unproven,
    List<MerkleProof> merkleProofs,
  ) {
    final ordered = orderParentsFirst(ancestors);
    final proofs = _proofsInTransactionOrder(ordered, merkleProofs);
    final bumpByTxid = <String, BUMP>{};
    for (final proof in proofs) {
      if (bumpByTxid.containsKey(proof.txid)) continue;
      bumpByTxid[proof.txid] = CryptoUtils.buildBUMPFromMerkleProof(proof);
    }
    final merged = BeefBumps.of(bumpByTxid);
    final bumps = merged.bumps;

    final txBytes = <Uint8List>[];
    final hasMerkle = <bool>[];
    final bumpIndex = <int>[];
    for (final tx in ordered) {
      txBytes.add(Uint8List.fromList(hex.decode(tx.rawHex)));
      final idx = merged.indexFor(tx.txid);
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
      final serialized = buildBeef(ancestorTransactions, [newTransaction], merkleProofs).serialize();

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
      final serialized = buildBeef(ancestorTransactions, newTransactions, merkleProofs).serialize();

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


