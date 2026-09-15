/// Migration v015: the counterparty columns of transaction rows follow the
/// rule every backend shares.
library;

import 'package:postgres/postgres.dart';

import '../postgres_migrations.dart';

/// Bead libspiffy-7dj: `PostgresWalletStorage.storeTransaction` stored the
/// first receiving address as `primary_counterparty` of every row, so an
/// incoming transaction named one of the wallet's own addresses, and left
/// `counterparty` empty. The Isar backend stores the other party
/// (`TransactionRowRules.primaryCounterpartyOf`): the first sending address
/// of an incoming transaction (`net_amount > 0`), the first receiving
/// address of an outgoing one (`net_amount < 0`), none otherwise.
///
/// Both columns are derived from columns the row keeps (`net_amount`,
/// `sending_addresses`, `receiving_addresses`), so they are recomputed from
/// them: `primary_counterparty` for every row, `counterparty` (set once, on
/// insert) where it is empty. No other column changes; nothing is deleted.
class V015TransactionCounterparty extends Migration {
  @override
  int get version => 15;

  @override
  String get name => 'transaction_counterparty';

  static const _derived = '''
      CASE
        WHEN net_amount > 0 AND jsonb_typeof(sending_addresses) = 'array'
          THEN sending_addresses->>0
        WHEN net_amount < 0 AND jsonb_typeof(receiving_addresses) = 'array'
          THEN receiving_addresses->>0
      END''';

  @override
  Future<void> up(Session conn) async {
    // A value that does not fit the column is left as it is (no insert
    // could have stored it either).
    await conn.execute('''
      UPDATE bitcoin_transactions
      SET primary_counterparty = $_derived
      WHERE primary_counterparty IS DISTINCT FROM ($_derived)
        AND COALESCE(length($_derived), 0) <= 255
    ''');
    await conn.execute('''
      UPDATE bitcoin_transactions
      SET counterparty = $_derived
      WHERE counterparty IS NULL
        AND ($_derived) IS NOT NULL
        AND length($_derived) <= 255
    ''');
  }

  /// No schema change to undo. The recomputed values stay: they are derived
  /// from the row, and the storage writes its own on the next update.
  @override
  Future<void> down(Session conn) async {}
}
