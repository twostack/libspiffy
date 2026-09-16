/// Migration v020: receives parked until their block headers arrive.
library;

import 'package:postgres/postgres.dart';

import '../postgres_migrations.dart';

/// Bead libspiffy-vfai. A BEEF whose merkle proof names a block our headers
/// have not reached proves nothing yet, so the receive waits (bead
/// libspiffy-68mz). Its evidence was already retained durably — the
/// transactions in `ancestor_transactions`, the BUMPs in `merkle_proofs` as
/// `pendingHeader` — but the waiting receive itself lived in an in-memory
/// queue, so a restart credited the wallet with nothing when the header
/// finally arrived, although no counterparty can be asked to send the BEEF
/// again.
///
/// One row per (wallet, subject txid), holding the BEEF exactly as it was
/// handed to us. Rows are never deleted except with their wallet: a replay
/// that settles the receive stamps `resolved_at`, which is also what stops it
/// being replayed on every later header.
class V020PendingReceives extends Migration {
  @override
  int get version => 20;

  @override
  String get name => 'pending_receives';

  @override
  Future<void> up(Session conn) async {
    await conn.execute('''
      CREATE TABLE IF NOT EXISTS pending_receives (
        wallet_id VARCHAR(255) NOT NULL,
        txid VARCHAR(64) NOT NULL,
        beef_hex TEXT NOT NULL,
        from_counterparty TEXT NOT NULL DEFAULT '',
        invoice_id VARCHAR(255),
        needed_height BIGINT NOT NULL,
        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        resolved_at TIMESTAMPTZ,
        resolution TEXT,
        PRIMARY KEY (wallet_id, txid)
      )
    ''');
    // The replay reads the waiting rows at or below the chain height, oldest
    // first; the partial index holds only those.
    await conn.execute('''
      CREATE INDEX IF NOT EXISTS idx_pending_receives_waiting
        ON pending_receives (needed_height, created_at)
        WHERE resolved_at IS NULL
    ''');
  }

  /// Dropping the table loses the automatic retry of receives still waiting
  /// (their transactions and BUMPs are kept in their own tables); it exists
  /// only to restore the v020 schema.
  @override
  Future<void> down(Session conn) async {
    await conn.execute('DROP INDEX IF EXISTS idx_pending_receives_waiting');
    await conn.execute('DROP TABLE IF EXISTS pending_receives');
  }
}
