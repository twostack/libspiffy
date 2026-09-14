/// Migration v010: ancestor transactions carried by received BEEFs.
library;

import 'package:postgres/postgres.dart';

import '../postgres_migrations.dart';

/// Audit bead libspiffy-zsh (data retention): a BEEF paying us for a
/// transaction that is not mined yet carries its ancestors back to mined
/// ones. They are needed to spend the received outputs before the payment is
/// mined and cannot be fetched again, so they are kept, keyed by txid (they
/// are not wallet transactions: no wallet id, not removed by a wallet
/// deletion). Their BUMPs go to `merkle_proofs`.
class V010AncestorTransactions extends Migration {
  @override
  int get version => 10;

  @override
  String get name => 'ancestor_transactions';

  @override
  Future<void> up(Session conn) async {
    await conn.execute('''
      CREATE TABLE IF NOT EXISTS ancestor_transactions (
        txid VARCHAR(64) PRIMARY KEY,
        raw_hex TEXT NOT NULL,
        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
      )
    ''');
  }

  /// Dropping the table discards evidence that cannot be fetched again; it
  /// exists only to restore the v009 schema.
  @override
  Future<void> down(Session conn) async {
    await conn.execute('DROP TABLE IF EXISTS ancestor_transactions');
  }
}
