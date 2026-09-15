/// Migration v016: index of merkle proofs by status and block height.
library;

import 'package:postgres/postgres.dart';

import '../postgres_migrations.dart';

/// Bead libspiffy-hg0: after a header-chain reorganization SPVActor checks
/// the orphaned and rejected proofs at the heights whose active header
/// changed, so a proof whose block is active again is verified again.
/// `ReadModelStorage.getMerkleProofsByStatusBetweenHeights` reads only those
/// rows through `idx_merkle_proofs_status_height` on (status, block_height),
/// not every orphaned or rejected proof ever stored.
///
/// The index replaces `idx_merkle_proofs_status` (v009), whose status-only
/// lookups use its prefix.
class V016MerkleProofStatusHeightIndex extends Migration {
  @override
  int get version => 16;

  @override
  String get name => 'merkle_proof_status_height_index';

  @override
  Future<void> up(Session conn) async {
    await conn.execute('''
      CREATE INDEX IF NOT EXISTS idx_merkle_proofs_status_height
        ON merkle_proofs (status, block_height)
    ''');
    await conn.execute('DROP INDEX IF EXISTS idx_merkle_proofs_status');
  }

  /// Restores the previous schema (indexes only: no row changes).
  @override
  Future<void> down(Session conn) async {
    await conn.execute('''
      CREATE INDEX IF NOT EXISTS idx_merkle_proofs_status
        ON merkle_proofs (status)
    ''');
    await conn.execute('DROP INDEX IF EXISTS idx_merkle_proofs_status_height');
  }
}
