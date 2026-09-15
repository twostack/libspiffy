/// Migration v018: index of merkle proofs by status and status change time.
library;

import 'package:postgres/postgres.dart';

import '../postgres_migrations.dart';

/// Bead libspiffy-hccp: on each header notification SPVActor looks for
/// confirmations resting only on a rejected proof. It read every rejected
/// proof ever stored; it now reads the proofs whose status became rejected
/// or orphaned since its previous check.
/// `ReadModelStorage.getMerkleProofsByStatusChangedSince` reads only those
/// rows through `idx_merkle_proofs_status_changed` on
/// (status, status_changed_at).
class V018MerkleProofStatusChangedIndex extends Migration {
  @override
  int get version => 18;

  @override
  String get name => 'merkle_proof_status_changed_index';

  @override
  Future<void> up(Session conn) async {
    await conn.execute('''
      CREATE INDEX IF NOT EXISTS idx_merkle_proofs_status_changed
        ON merkle_proofs (status, status_changed_at)
    ''');
  }

  /// Restores the previous schema (index only: no row changes).
  @override
  Future<void> down(Session conn) async {
    await conn.execute('DROP INDEX IF EXISTS idx_merkle_proofs_status_changed');
  }
}
