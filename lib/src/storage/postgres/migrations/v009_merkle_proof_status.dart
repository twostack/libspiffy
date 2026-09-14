/// Migration v009: merkle proofs keep a status instead of being deleted.
library;

import 'package:postgres/postgres.dart';

import '../postgres_migrations.dart';

/// Audit bead libspiffy-mny (data retention): after a reorganization the
/// proof of a transaction whose block left the active chain was deleted, and
/// a proof stored before its block header was known carried the placeholder
/// block hash `'pending'`. Proofs cannot be fetched again, so they are kept
/// with a status (`MerkleProofStatus`):
///
/// * `status` (`verified`, `pendingHeader`, `orphaned`) and
///   `status_changed_at` columns. Existing rows become `pendingHeader` with a
///   NULL `block_hash` where it was `'pending'` (the column becomes
///   nullable), and `verified` otherwise.
/// * One row per txid (`uk_merkle_proofs_txid`, v005) becomes: at most one
///   non-orphaned row per txid (`uk_merkle_proofs_txid_current`), one row per
///   (txid, block hash) (`uk_merkle_proofs_txid_block`) and, for rows without
///   a block hash, one row per (txid, proof) (`uk_merkle_proofs_txid_unhashed`,
///   on an md5 of the proof, which can exceed a btree entry).
/// * Indexes for a txid's history and for the status queries.
class V009MerkleProofStatus extends Migration {
  @override
  int get version => 9;

  @override
  String get name => 'merkle_proof_status';

  @override
  Future<void> up(Session conn) async {
    await conn.execute('''
      ALTER TABLE merkle_proofs
      ADD COLUMN IF NOT EXISTS status VARCHAR(16) NOT NULL DEFAULT 'verified'
    ''');
    await conn.execute('''
      ALTER TABLE merkle_proofs
      ADD COLUMN IF NOT EXISTS status_changed_at TIMESTAMPTZ
    ''');
    await conn.execute('ALTER TABLE merkle_proofs ALTER COLUMN block_hash DROP NOT NULL');
    await conn.execute('''
      UPDATE merkle_proofs SET status = 'pendingHeader', block_hash = NULL
      WHERE block_hash = 'pending'
    ''');
    await conn.execute('ALTER TABLE merkle_proofs ALTER COLUMN status DROP DEFAULT');
    await conn.execute('''
      ALTER TABLE merkle_proofs
      ADD CONSTRAINT ck_merkle_proofs_status
      CHECK (status IN ('verified', 'pendingHeader', 'orphaned'))
    ''');

    await conn.execute('''
      ALTER TABLE merkle_proofs
      DROP CONSTRAINT IF EXISTS uk_merkle_proofs_txid
    ''');
    await conn.execute('''
      CREATE UNIQUE INDEX uk_merkle_proofs_txid_current
      ON merkle_proofs(txid) WHERE status <> 'orphaned'
    ''');
    await conn.execute('''
      CREATE UNIQUE INDEX uk_merkle_proofs_txid_block
      ON merkle_proofs(txid, block_hash) WHERE block_hash IS NOT NULL
    ''');
    await conn.execute('''
      CREATE UNIQUE INDEX uk_merkle_proofs_txid_unhashed
      ON merkle_proofs(txid, md5(merkle_proof_json)) WHERE block_hash IS NULL
    ''');
    await conn.execute('''
      CREATE INDEX IF NOT EXISTS idx_merkle_proofs_txid
      ON merkle_proofs(txid)
    ''');
    await conn.execute('''
      CREATE INDEX IF NOT EXISTS idx_merkle_proofs_status
      ON merkle_proofs(status)
    ''');
  }

  @override
  Future<void> down(Session conn) async {
    await conn.execute('DROP INDEX IF EXISTS idx_merkle_proofs_status');
    await conn.execute('DROP INDEX IF EXISTS idx_merkle_proofs_txid');
    await conn.execute('DROP INDEX IF EXISTS uk_merkle_proofs_txid_unhashed');
    await conn.execute('DROP INDEX IF EXISTS uk_merkle_proofs_txid_block');
    await conn.execute('DROP INDEX IF EXISTS uk_merkle_proofs_txid_current');

    // The pre-v009 model holds one proof per txid and no orphaned proofs
    // (it deleted them). Restoring it deletes the orphaned rows: the only
    // place this migration drops data, and only on the way down. The rows
    // left are the current proof of each txid, so uk_merkle_proofs_txid
    // holds again.
    await conn.execute("DELETE FROM merkle_proofs WHERE status = 'orphaned'");
    await conn.execute('''
      UPDATE merkle_proofs SET block_hash = 'pending'
      WHERE block_hash IS NULL
    ''');
    await conn.execute('ALTER TABLE merkle_proofs ALTER COLUMN block_hash SET NOT NULL');
    await conn.execute('''
      ALTER TABLE merkle_proofs
      DROP CONSTRAINT IF EXISTS ck_merkle_proofs_status
    ''');
    await conn.execute('ALTER TABLE merkle_proofs DROP COLUMN IF EXISTS status_changed_at');
    await conn.execute('ALTER TABLE merkle_proofs DROP COLUMN IF EXISTS status');
    await conn.execute('''
      ALTER TABLE merkle_proofs
      ADD CONSTRAINT uk_merkle_proofs_txid UNIQUE (txid)
    ''');
  }
}
