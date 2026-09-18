/// Migration v023: a transaction row keeps its nLockTime and its version.
library;

import 'package:postgres/postgres.dart';

import '../../transaction_row_rules.dart';
import '../postgres_migrations.dart';

/// Bead libspiffy-zpu7 (doc/reachability-sweep-2026-09-18.md, D-1):
/// `bitcoin_transactions` had no column for either field, so
/// `PostgresWalletStorage._rowToTransaction` answered `lockTime: 0,
/// version: 1` for every row it ever returned — while the in-memory backend
/// returned the real values, so the same wallet answered differently
/// depending on its backend. `0` is not a missing reading: a payment
/// channel's refund is defined by its nLockTime, and `0` says "spendable
/// now" about a transaction that is not.
///
/// Both are BIGINT and nullable:
///
/// * BIGINT because both are unsigned 32-bit consensus fields, which a
///   signed `INTEGER` cannot hold above 2147483647 — the same range bug
///   v022 fixed on `payment_channels.lock_time_unix`. An nLockTime in the
///   timestamp domain passes that value in 2038, and one in the block-height
///   domain never does, but the column should not be the thing that decides.
/// * Nullable because a row written before this migration may have no
///   evidence of either value. Where the wallet holds the transaction's raw
///   hex it has evidence and this migration reads it back (the hex is never
///   dropped — spv-understanding.md, Data Retention); where it does not,
///   the row keeps NULL. A plausible default would be a reading nobody can
///   justify, and this is the field where a wrong reading is the dangerous
///   one, so the V-80 precedent applies: absent is recorded as absent.
///
/// The backfill deserializes each row's `raw_hex` with the same parser the
/// storage uses on the way in ([TransactionRowRules.intrinsicsOfRawHex]), so
/// a migrated row and a freshly stored one cannot disagree. Hex that does
/// not deserialize is left NULL rather than guessed at. Nothing is deleted
/// and no other column is touched.
class V023TransactionLockTimeAndVersion extends Migration {
  @override
  int get version => 23;

  @override
  String get name => 'transaction_lock_time_and_version';

  /// Rows read and rewritten per round of the backfill.
  static const _batch = 500;

  @override
  Future<void> up(Session conn) async {
    await conn.execute('''
      ALTER TABLE bitcoin_transactions
        ADD COLUMN IF NOT EXISTS lock_time BIGINT,
        ADD COLUMN IF NOT EXISTS tx_version BIGINT
    ''');

    // Backfill from the stored raw hex, in batches ordered by the primary
    // key so the cursor always advances — including past rows whose hex does
    // not deserialize and which therefore stay NULL.
    var afterWallet = '';
    var afterTxid = '';
    while (true) {
      final rows = await conn.execute(
        Sql.named('''
          SELECT wallet_id, txid, raw_hex
          FROM bitcoin_transactions
          WHERE (lock_time IS NULL OR tx_version IS NULL)
            AND raw_hex <> ''
            AND (wallet_id, txid) > (@afterWallet, @afterTxid)
          ORDER BY wallet_id, txid
          LIMIT $_batch
        '''),
        parameters: {'afterWallet': afterWallet, 'afterTxid': afterTxid},
      );
      if (rows.isEmpty) break;
      for (final row in rows) {
        final walletId = row[0] as String;
        final txid = row[1] as String;
        final intrinsics = TransactionRowRules.intrinsicsOfRawHex(row[2] as String);
        if (intrinsics != null) {
          await conn.execute(
            Sql.named('''
              UPDATE bitcoin_transactions
              SET lock_time = COALESCE(lock_time, @lockTime),
                  tx_version = COALESCE(tx_version, @txVersion)
              WHERE wallet_id = @walletId AND txid = @txid
            '''),
            parameters: {
              'walletId': walletId,
              'txid': txid,
              'lockTime': intrinsics.lockTime,
              'txVersion': intrinsics.version,
            },
          );
        }
      }
      afterWallet = rows.last[0] as String;
      afterTxid = rows.last[1] as String;
    }
  }

  /// The columns are kept. They hold consensus fields of transactions the
  /// wallet may no longer be able to obtain anywhere else, and dropping them
  /// would destroy that to undo a schema change that costs nothing to leave
  /// in place (as v021). A v022 schema ignores the extra columns.
  @override
  Future<void> down(Session conn) async {}
}
