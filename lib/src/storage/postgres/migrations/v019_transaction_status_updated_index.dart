/// Migration v019: index of transactions by status and last update.
library;

import 'package:postgres/postgres.dart';

import '../postgres_migrations.dart';

/// Bead libspiffy-5bju: ARCActor polls recently failed transactions, because
/// one ARC reported REJECTED can still be mined (a competing spend loses, or
/// the report was stale) and nothing else would ever ask again. The poll must
/// never read a wallet's whole failed history, so
/// `ReadModelStorage.getTransactionsByStatusSince` reads a recent window with
/// a row cap through `idx_transactions_status_updated` on
/// (status, updated_at DESC).
class V019TransactionStatusUpdatedIndex extends Migration {
  @override
  int get version => 19;

  @override
  String get name => 'transaction_status_updated_index';

  @override
  Future<void> up(Session conn) async {
    await conn.execute('''
      CREATE INDEX IF NOT EXISTS idx_transactions_status_updated
        ON bitcoin_transactions (status, updated_at DESC)
    ''');
  }

  /// Restores the previous schema (index only: no row changes).
  @override
  Future<void> down(Session conn) async {
    await conn.execute('DROP INDEX IF EXISTS idx_transactions_status_updated');
  }
}
