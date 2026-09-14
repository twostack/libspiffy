/// Migration v004: complete the payment-channel columns and persist invoice
/// output specs.
library;

import 'package:postgres/postgres.dart';

import '../postgres_migrations.dart';

/// Two read-model defects found in the September 2026 audit (S-01, S-07):
///
/// * `payment_channels` had no columns for `PaymentChannel.latestPaymentTxId`,
///   `settlementTxId` and `errorMessage`, and declared the funding and
///   address columns `NOT NULL` although a channel has no funding transaction
///   until it opens and no counter-party address until it is accepted.
///   The projection therefore could not persist a requested channel at all.
/// * `invoices` had no column for `InvoiceReadModel.outputs`, so the
///   structured output specs of multi-output invoices were dropped on the
///   Postgres backend while Isar kept them.
class V004ChannelColumnsAndInvoiceOutputs extends Migration {
  static const _nullableChannelColumns = {
    'funding_tx_id': "''",
    'funding_tx_hex': "''",
    'funding_output_index': '0',
    'client_address_b58': "''",
    'server_address_b58': "''",
  };

  @override
  int get version => 4;

  @override
  String get name => 'channel_columns_and_invoice_outputs';

  @override
  Future<void> up(Session conn) async {
    await conn.execute('''
      ALTER TABLE payment_channels
        ADD COLUMN IF NOT EXISTS latest_payment_tx_id VARCHAR(64),
        ADD COLUMN IF NOT EXISTS settlement_tx_id VARCHAR(64),
        ADD COLUMN IF NOT EXISTS error_message TEXT
    ''');

    for (final column in _nullableChannelColumns.keys) {
      await conn.execute(
        'ALTER TABLE payment_channels ALTER COLUMN $column DROP NOT NULL',
      );
    }

    await conn.execute('''
      ALTER TABLE invoices
      ADD COLUMN IF NOT EXISTS outputs_json JSONB
    ''');
  }

  @override
  Future<void> down(Session conn) async {
    await conn.execute(
      'ALTER TABLE invoices DROP COLUMN IF EXISTS outputs_json',
    );

    // Restore the v001 NOT NULL constraints. Rows the projection stored
    // before funding get the placeholder values the pre-v004 projection
    // used, so the constraint can be re-established.
    for (final entry in _nullableChannelColumns.entries) {
      await conn.execute(
        'UPDATE payment_channels SET ${entry.key} = ${entry.value} '
        'WHERE ${entry.key} IS NULL',
      );
      await conn.execute(
        'ALTER TABLE payment_channels ALTER COLUMN ${entry.key} SET NOT NULL',
      );
    }

    await conn.execute('''
      ALTER TABLE payment_channels
        DROP COLUMN IF EXISTS latest_payment_tx_id,
        DROP COLUMN IF EXISTS settlement_tx_id,
        DROP COLUMN IF EXISTS error_message
    ''');
  }
}
