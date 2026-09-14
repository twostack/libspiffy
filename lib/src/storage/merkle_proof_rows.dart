/// The merkle proof retention rules shared by every ReadModelStorage backend
/// (audit bead libspiffy-mny). Not exported: backends load the rows of one
/// txid, ask these functions what to write, and write it.
library;

import 'read_model_storage.dart';

/// What [planMerkleProofStore] decided.
class MerkleProofStorePlan {
  /// Index (into the rows passed in) of the row to overwrite with [row], or
  /// null to add [row] as a new row.
  final int? target;

  /// The row to write.
  final MerkleProof row;

  /// Indexes of other rows that must become orphaned (with [orphanedAt]).
  final List<int> orphan;

  final DateTime orphanedAt;

  const MerkleProofStorePlan(this.target, this.row, this.orphan, this.orphanedAt);
}

/// Decide how storing [proof] for [txid] changes [rows] (every stored row of
/// [txid], oldest first), following `ReadModelStorage.storeMerkleProof`:
/// rows are only ever added or updated, and at most one row stays current
/// ([MerkleProof.isCurrent]).
MerkleProofStorePlan planMerkleProofStore(
  List<MerkleProof> rows,
  String txid,
  MerkleProof proof, {
  DateTime? now,
}) {
  final at = now ?? DateTime.now();
  // A rejected proof names no block of ours (bead azl): it is stored without
  // a block hash and only updates a row that has none, so it can never
  // overwrite the row of a block it claims to be in.
  final rejected = proof.status == MerkleProofStatus.rejected;
  final hash = rejected || proof.blockHash == MerkleProof.legacyPendingBlockHash ? null : proof.blockHash;

  int? target;
  if (rejected) {
    target = _indexWhere(
            rows, (r) => r.blockHash == null && r.isCurrent && MerkleProof.sameContent(r.merkleProof, proof.merkleProof)) ??
        _indexWhere(rows, (r) => r.blockHash == null && MerkleProof.sameContent(r.merkleProof, proof.merkleProof));
  } else if (hash != null) {
    target = _indexWhere(rows, (r) => r.blockHash == hash);
    target ??= _indexWhere(
        rows, (r) => r.blockHash == null && MerkleProof.sameContent(r.merkleProof, proof.merkleProof));
  } else {
    target = _indexWhere(
            rows, (r) => r.isCurrent && MerkleProof.sameContent(r.merkleProof, proof.merkleProof)) ??
        _indexWhere(rows, (r) => MerkleProof.sameContent(r.merkleProof, proof.merkleProof));
  }

  final previous = target == null ? null : rows[target];
  final statusChanged = previous == null || previous.status != proof.status;
  final row = MerkleProof(
    txid: txid,
    blockHash: rejected ? null : (hash ?? previous?.blockHash),
    blockHeight: proof.blockHeight,
    position: proof.position,
    merkleProof: proof.merkleProof,
    createdAt: previous?.createdAt ?? proof.createdAt,
    status: proof.status,
    statusChangedAt: statusChanged ? (proof.statusChangedAt ?? at) : previous.statusChangedAt,
  );

  final orphan = <int>[
    if (proof.isCurrent)
      for (var i = 0; i < rows.length; i++)
        if (i != target && rows[i].isCurrent) i,
  ];
  return MerkleProofStorePlan(target, row, orphan, proof.statusChangedAt ?? at);
}

/// The index of the row `ReadModelStorage.markMerkleProofOrphaned` marks, or
/// null when no current row matches.
int? findMerkleProofToOrphan(
  List<MerkleProof> rows, {
  String? blockHash,
  List<String>? onlyIfMerkleProof,
}) {
  final hash = blockHash == MerkleProof.legacyPendingBlockHash ? null : blockHash;
  return _indexWhere(
    rows,
    (r) =>
        r.isCurrent &&
        (hash == null || r.blockHash == null || r.blockHash == hash) &&
        (onlyIfMerkleProof == null || MerkleProof.sameContent(r.merkleProof, onlyIfMerkleProof)),
  );
}

/// The current row of a txid: the newest [MerkleProof.isCurrent] one (a
/// store written before bead mny may hold several).
MerkleProof? currentMerkleProof(Iterable<MerkleProof> rows) {
  MerkleProof? current;
  for (final r in rows) {
    if (r.isCurrent) current = r;
  }
  return current;
}

int? _indexWhere(List<MerkleProof> rows, bool Function(MerkleProof) test) {
  for (var i = 0; i < rows.length; i++) {
    if (test(rows[i])) return i;
  }
  return null;
}
