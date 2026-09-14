/// Migration v011: the reservation and derivation index of a UTXO row.
library;

import 'package:postgres/postgres.dart';

import '../postgres_migrations.dart';

/// Bead libspiffy-viy: `bitcoin_utxos` stored a reserved UTXO's status but
/// not its reservation, so every read returned a reserved UTXO without its
/// holder (`reservedByTxId`), reason, expiry, priority or the status its
/// release restores, and without its derivation index. The columns are
/// nullable: rows written before this migration read back without them, as
/// before. `spent_in_tx_id` existed since v001 but was never written; it is
/// now (and never overwritten once set).
class V011UtxoReservationColumns extends Migration {
  @override
  int get version => 11;

  @override
  String get name => 'utxo_reservation_columns';

  /// Column name -> type.
  static const _columns = {
    'reserved_by_tx_id': 'TEXT',
    'reservation_reason': 'TEXT',
    'reservation_expires_at': 'TIMESTAMPTZ',
    'reservation_priority': 'INTEGER',
    'status_before_reservation': 'VARCHAR(50)',
    'derivation_index': 'INTEGER',
  };

  @override
  Future<void> up(Session conn) async {
    for (final entry in _columns.entries) {
      await conn.execute(
          'ALTER TABLE bitcoin_utxos ADD COLUMN IF NOT EXISTS ${entry.key} ${entry.value}');
    }
  }

  /// Restores the v010 schema; the reservations and derivation indexes the
  /// columns held are dropped with them.
  @override
  Future<void> down(Session conn) async {
    for (final name in _columns.keys) {
      await conn.execute('ALTER TABLE bitcoin_utxos DROP COLUMN IF EXISTS $name');
    }
  }
}
