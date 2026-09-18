/// Migration v022: a payment channel's nLockTime is a 64-bit unix timestamp.
library;

import 'package:postgres/postgres.dart';

import '../postgres_migrations.dart';

/// Bead libspiffy-cqc (c): `payment_channels.lock_time_unix` was created as a
/// signed 32-bit `INTEGER` (v001), which cannot hold a unix timestamp after
/// 2038-01-19 03:14:07 UTC. A channel whose refund becomes spendable after
/// that date could not be stored at all — Postgres rejected the insert with
/// `22003: value "..." is out of range for type integer` — so the wallet lost
/// a channel it had already negotiated.
///
/// The value is an nLockTime, which Bitcoin itself carries as an unsigned
/// 32-bit field, so `BIGINT` covers the whole representable range with room
/// to spare. Isar stores the field as a 64-bit `Long` and Dart ints are
/// 64-bit, so only the Postgres backend needed widening.
///
/// `ALTER COLUMN ... TYPE BIGINT` widens in place: every existing value fits
/// unchanged and no row is rewritten lossily.
class V022ChannelLockTimeBigint extends Migration {
  @override
  int get version => 22;

  @override
  String get name => 'channel_lock_time_bigint';

  @override
  Future<void> up(Session conn) async {
    await conn.execute('''
      ALTER TABLE payment_channels
        ALTER COLUMN lock_time_unix TYPE BIGINT
    ''');
  }

  /// Narrows back to `INTEGER`. This is lossy by definition — it is the very
  /// range this migration exists to restore — so any channel whose lock time
  /// does not fit makes the rollback fail loudly rather than silently
  /// truncating a locktime the wallet needs to spend its refund.
  @override
  Future<void> down(Session conn) async {
    await conn.execute('''
      ALTER TABLE payment_channels
        ALTER COLUMN lock_time_unix TYPE INTEGER
    ''');
  }
}
