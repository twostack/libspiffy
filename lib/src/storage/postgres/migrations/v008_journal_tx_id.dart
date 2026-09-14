/// Migration v008: journal rows record the transaction that wrote them.
library;

import 'package:postgres/postgres.dart';

import '../postgres_migrations.dart';

/// Audit bead libspiffy-xp4: journal ids (`BIGSERIAL`) are allocated at
/// INSERT time, but appends to different persistence ids commit in any
/// order, so a reader advancing an `id > last` cursor could pass an id whose
/// transaction had not committed yet and never deliver it.
///
/// `tx_id` holds the writing transaction's id (`pg_current_xact_id()`, as a
/// bigint). The event store reads only rows whose transaction is older than
/// the oldest transaction still running (`pg_snapshot_xmin`), ordered by
/// `(tx_id, id)`: every transaction that could still commit a row then sorts
/// after everything already read. Existing rows get `tx_id = 0`, before any
/// real transaction id, so they keep their id order and precede new rows.
///
/// The column is added with a constant default (no table rewrite) and the
/// volatile default is set afterwards, so the backfill is a catalog change.
class V008JournalTxId extends Migration {
  @override
  int get version => 8;

  @override
  String get name => 'journal_tx_id';

  @override
  Future<void> up(Session conn) async {
    await conn.execute(
      'ALTER TABLE event_envelopes ADD COLUMN tx_id BIGINT NOT NULL DEFAULT 0',
    );
    await conn.execute(
      'ALTER TABLE event_envelopes ALTER COLUMN tx_id '
      'SET DEFAULT (pg_current_xact_id()::text::bigint)',
    );
    await conn.execute(
      'CREATE INDEX IF NOT EXISTS idx_event_envelopes_tx_id_id '
      'ON event_envelopes (tx_id, id)',
    );
  }

  @override
  Future<void> down(Session conn) async {
    await conn.execute('DROP INDEX IF EXISTS idx_event_envelopes_tx_id_id');
    await conn
        .execute('ALTER TABLE event_envelopes DROP COLUMN IF EXISTS tx_id');
  }
}
