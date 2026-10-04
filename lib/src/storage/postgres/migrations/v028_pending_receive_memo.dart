/// Migration v028: the payer's note on a parked receive.
library;

import 'package:postgres/postgres.dart';

import '../postgres_migrations.dart';

/// A receive parked for a block header (migration v020) is replayed later,
/// and the replay is what journals the payment. The payment's note (memo),
/// written by the payer for the payee, must reach that journal as the
/// counterparty marker does, so the parked row keeps it.
///
/// TEXT, nullable: existing rows have no memo and none can be invented for
/// them. The transaction row needs no new column: `bitcoin_transactions.notes`
/// (v001) holds the memo.
class V028PendingReceiveMemo extends Migration {
  @override
  int get version => 28;

  @override
  String get name => 'pending_receive_memo';

  @override
  Future<void> up(Session conn) async {
    await conn.execute('''
      ALTER TABLE pending_receives
        ADD COLUMN IF NOT EXISTS memo TEXT
    ''');
  }

  /// The column is kept. It holds notes a payer handed us that nobody can
  /// supply again (spv-understanding.md, Data Retention). A v027 schema
  /// ignores the extra column.
  @override
  Future<void> down(Session conn) async {}
}
