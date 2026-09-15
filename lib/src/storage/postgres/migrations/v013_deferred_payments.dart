/// Migration v013: deferred payments.
library;

import 'package:postgres/postgres.dart';

import '../postgres_migrations.dart';

/// Bead libspiffy-7p2: outgoing transactions recorded with a deferred spend
/// (handed to the recipient, not yet settled by the network), with the
/// inputs they hold, their state and last network status. One row per
/// (wallet, txid); rows are never deleted except with their wallet.
///
/// `ix_deferred_payments_wallet_state_created` serves the listing: the
/// default outstanding-only query reads only that wallet's outstanding rows,
/// in page order.
class V013DeferredPayments extends Migration {
  @override
  int get version => 13;

  @override
  String get name => 'deferred_payments';

  @override
  Future<void> up(Session conn) async {
    await conn.execute('''
      CREATE TABLE IF NOT EXISTS deferred_payments (
        wallet_id VARCHAR(255) NOT NULL,
        txid VARCHAR(64) NOT NULL,
        state VARCHAR(20) NOT NULL,
        created_at TIMESTAMPTZ NOT NULL,
        updated_at TIMESTAMPTZ NOT NULL,
        invoice_id VARCHAR(255),
        purpose VARCHAR(100),
        recipient_addresses JSONB NOT NULL DEFAULT '[]'::jsonb,
        amount BIGINT NOT NULL,
        fee BIGINT NOT NULL,
        held_inputs JSONB NOT NULL DEFAULT '[]'::jsonb,
        last_network_status VARCHAR(50),
        last_network_status_source VARCHAR(20),
        last_checked_at TIMESTAMPTZ,
        resolved_at TIMESTAMPTZ,
        resolution_reason TEXT,
        inferred BOOLEAN NOT NULL DEFAULT FALSE,
        PRIMARY KEY (wallet_id, txid)
      )
    ''');
    await conn.execute('''
      CREATE INDEX IF NOT EXISTS ix_deferred_payments_wallet_state_created
        ON deferred_payments (wallet_id, state, created_at DESC, txid DESC)
    ''');
  }

  /// Restores the v012 schema. Dropping the table discards the deferred
  /// payment rows; they are rebuilt by replaying the wallet journal.
  @override
  Future<void> down(Session conn) async {
    await conn.execute('DROP TABLE IF EXISTS deferred_payments');
  }
}
