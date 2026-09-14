/// Migration v006: newest-first list indexes and `updated_at` columns.
library;

import 'package:postgres/postgres.dart';

import '../postgres_migrations.dart';

/// Read-model defects found in the September 2026 audit:
///
/// * S-19: the list queries filter by wallet and order by `created_at DESC`
///   (the order every backend now returns), but only single-column
///   `wallet_id` indexes existed, so each page sorted all of the wallet's
///   rows. Composite `(wallet_id, created_at DESC)` indexes serve them.
/// * S-20: `bitcoin_utxos` and `bitcoin_transactions` had no `updated_at`
///   column, so every read returned `updatedAt == createdAt`. Existing rows
///   are back-filled with their `created_at` (the best value known).
class V006ListIndexesAndUpdatedAt extends Migration {
  @override
  int get version => 6;

  @override
  String get name => 'list_indexes_and_updated_at';

  /// Index name -> `table(columns)`.
  static const _indexes = {
    'idx_transactions_wallet_created': 'bitcoin_transactions(wallet_id, created_at DESC)',
    'idx_utxos_wallet_created': 'bitcoin_utxos(wallet_id, created_at DESC)',
    'idx_addresses_wallet_created': 'addresses(wallet_id, created_at DESC)',
    'idx_tx_addr_wallet_address_created':
        'transaction_addresses(wallet_id, address, created_at DESC)',
    'idx_invoices_wallet_created': 'invoices(wallet_id, created_at DESC)',
    'idx_channels_wallet_created': 'payment_channels(wallet_id, created_at DESC)',
    'idx_wallet_metadata_created': 'wallet_metadata(created_at DESC)',
  };

  @override
  Future<void> up(Session conn) async {
    for (final entry in _indexes.entries) {
      await conn.execute('CREATE INDEX IF NOT EXISTS ${entry.key} ON ${entry.value}');
    }

    for (final table in ['bitcoin_utxos', 'bitcoin_transactions']) {
      await conn.execute('ALTER TABLE $table ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ');
      await conn.execute('UPDATE $table SET updated_at = created_at WHERE updated_at IS NULL');
    }
  }

  @override
  Future<void> down(Session conn) async {
    for (final table in ['bitcoin_utxos', 'bitcoin_transactions']) {
      await conn.execute('ALTER TABLE $table DROP COLUMN IF EXISTS updated_at');
    }
    for (final name in _indexes.keys) {
      await conn.execute('DROP INDEX IF EXISTS $name');
    }
  }
}
