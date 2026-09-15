/// Migration v014: index of confirmed transactions by block height.
library;

import 'package:postgres/postgres.dart';

import '../postgres_migrations.dart';

/// Bead libspiffy-ctkm: on a header-chain reorganization SPVActor read every
/// wallet's confirmed history (raw hex included) to find the confirmations
/// above the fork point. `ReadModelStorage.getConfirmedTransactionsFromHeight`
/// reads only those rows through `idx_transactions_confirmed_height`, a
/// partial index on `block_height` over the confirmed rows (rows with no
/// height are indexed too, as NULL).
///
/// The by-txid lookup (`getTransactionsByTxids`) uses `idx_transactions_txid`
/// (v005).
class V014ConfirmedTransactionHeightIndex extends Migration {
  @override
  int get version => 14;

  @override
  String get name => 'confirmed_transaction_height_index';

  @override
  Future<void> up(Session conn) async {
    await conn.execute('''
      CREATE INDEX IF NOT EXISTS idx_transactions_confirmed_height
        ON bitcoin_transactions (block_height)
        WHERE status = 'confirmed'
    ''');
  }

  /// Restores the v013 schema (an index only: no row changes).
  @override
  Future<void> down(Session conn) async {
    await conn.execute('DROP INDEX IF EXISTS idx_transactions_confirmed_height');
  }
}
