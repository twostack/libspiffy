/// Migration v012: the `rejected` merkle proof status.
library;

import 'package:postgres/postgres.dart';

import '../postgres_migrations.dart';

/// Audit bead libspiffy-azl: a proof whose root contradicts the stored header
/// at its height was stored as `pendingHeader`, so it stayed the
/// transaction's current proof and was put into BEEFs. Such a proof now has
/// the status `rejected` (`MerkleProofStatus.rejected`): kept, never current.
///
/// * `ck_merkle_proofs_status` (v009) admits `rejected`.
/// * `uk_merkle_proofs_txid_current` (v009: at most one non-orphaned row per
///   txid) becomes at most one `verified` or `pendingHeader` row per txid, so
///   a rejected row can sit next to the current proof. No row existing
///   before this migration is rejected, so the index covers the same rows.
class V012MerkleProofRejectedStatus extends Migration {
  @override
  int get version => 12;

  @override
  String get name => 'merkle_proof_rejected_status';

  @override
  Future<void> up(Session conn) async {
    await conn.execute('ALTER TABLE merkle_proofs DROP CONSTRAINT IF EXISTS ck_merkle_proofs_status');
    await conn.execute('''
      ALTER TABLE merkle_proofs
      ADD CONSTRAINT ck_merkle_proofs_status
      CHECK (status IN ('verified', 'pendingHeader', 'orphaned', 'rejected'))
    ''');
    await conn.execute('DROP INDEX IF EXISTS uk_merkle_proofs_txid_current');
    await conn.execute('''
      CREATE UNIQUE INDEX uk_merkle_proofs_txid_current
      ON merkle_proofs(txid) WHERE status IN ('verified', 'pendingHeader')
    ''');
  }

  /// Restores the v011 schema. The v011 model has no `rejected` status; its
  /// non-current proofs are `orphaned`, so rejected rows become orphaned. No
  /// row is deleted.
  @override
  Future<void> down(Session conn) async {
    await conn.execute('DROP INDEX IF EXISTS uk_merkle_proofs_txid_current');
    await conn.execute('ALTER TABLE merkle_proofs DROP CONSTRAINT IF EXISTS ck_merkle_proofs_status');
    await conn.execute("UPDATE merkle_proofs SET status = 'orphaned' WHERE status = 'rejected'");
    await conn.execute('''
      ALTER TABLE merkle_proofs
      ADD CONSTRAINT ck_merkle_proofs_status
      CHECK (status IN ('verified', 'pendingHeader', 'orphaned'))
    ''');
    await conn.execute('''
      CREATE UNIQUE INDEX uk_merkle_proofs_txid_current
      ON merkle_proofs(txid) WHERE status <> 'orphaned'
    ''');
  }
}
