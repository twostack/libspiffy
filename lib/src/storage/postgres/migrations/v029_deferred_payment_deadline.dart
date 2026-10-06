/// Migration v029: a deferred payment's deadline (bead libspiffy-8442).
library;

import 'package:postgres/postgres.dart';

import '../postgres_migrations.dart';

/// When the wallet reclaims an outstanding deferred payment by itself.
/// TIMESTAMPTZ, nullable: a row stored before the column existed has no
/// deadline, and none is invented for it.
class V029DeferredPaymentDeadline extends Migration {
  @override
  int get version => 29;

  @override
  String get name => 'deferred_payment_deadline';

  @override
  Future<void> up(Session conn) async {
    await conn.execute('''
      ALTER TABLE deferred_payments
        ADD COLUMN IF NOT EXISTS deadline TIMESTAMPTZ
    ''');
  }

  /// The column is kept: a v028 schema ignores it, and the deadlines in it
  /// are the app's, which nobody can supply again.
  @override
  Future<void> down(Session conn) async {}
}
