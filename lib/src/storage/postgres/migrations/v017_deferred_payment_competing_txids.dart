/// Migration v017: competing transactions of a deferred payment.
library;

import 'package:postgres/postgres.dart';

import '../postgres_migrations.dart';

/// Bead libspiffy-pkum: when ARC reports DOUBLE_SPEND_ATTEMPTED it names the
/// competing transactions (`competingTxs`). They are journaled with the
/// status (TransactionNetworkStatusCheckedEvent.competingTxids) and listed
/// with the payment: `deferred_payments.competing_txids` holds every txid
/// reported so far as a JSON array, `[]` for a row stored before this
/// migration (a journal written before it holds none either).
class V017DeferredPaymentCompetingTxids extends Migration {
  @override
  int get version => 17;

  @override
  String get name => 'deferred_payment_competing_txids';

  @override
  Future<void> up(Session conn) async {
    await conn.execute('''
      ALTER TABLE deferred_payments
        ADD COLUMN IF NOT EXISTS competing_txids JSONB NOT NULL DEFAULT '[]'::jsonb
    ''');
  }

  /// Restores the v016 schema. The column's values are rebuilt from the
  /// wallet journal, which keeps them.
  @override
  Future<void> down(Session conn) async {
    await conn.execute('ALTER TABLE deferred_payments DROP COLUMN IF EXISTS competing_txids');
  }
}
