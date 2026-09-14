/// Migration v003: widen block header integer columns and persist UTXO
/// plugin metadata.
library;

import 'package:postgres/postgres.dart';

import '../postgres_migrations.dart';

/// Two schema defects found in the September 2026 audit:
///
/// * `block_headers.nonce`, `version`, `bits` and `timestamp` were `INTEGER`
///   (int4). A block header's nonce is a uint32, so any block whose nonce is
///   2^31 or more (roughly half of all blocks; block 1's nonce is
///   2573394689) failed to store with "value out of range for type integer",
///   and `validateAndStoreHeader` reported it as an invalid header.
/// * `bitcoin_utxos` had no column for `BitcoinUtxo.pluginMetadata`, so token
///   (plugin-managed) outputs were indistinguishable from payment outputs:
///   `getPaymentUTXOs` and `getBalance` counted them and coin selection could
///   spend them as ordinary funding.
class V003HeaderIntsAndPluginMetadata extends Migration {
  @override
  int get version => 3;

  @override
  String get name => 'header_ints_and_plugin_metadata';

  @override
  Future<void> up(Session conn) async {
    for (final column in ['timestamp', 'version', 'bits', 'nonce']) {
      await conn.execute(
        'ALTER TABLE block_headers ALTER COLUMN $column TYPE BIGINT',
      );
    }

    await conn.execute('''
      ALTER TABLE bitcoin_utxos
      ADD COLUMN IF NOT EXISTS plugin_metadata JSONB
    ''');

    // Supports the pluginId filters in getPaymentUTXOs / getUTXOsByPlugin.
    await conn.execute('''
      CREATE INDEX IF NOT EXISTS idx_utxos_plugin_id
      ON bitcoin_utxos ((plugin_metadata->>'pluginId'))
    ''');
  }

  @override
  Future<void> down(Session conn) async {
    await conn.execute('DROP INDEX IF EXISTS idx_utxos_plugin_id');
    await conn.execute(
      'ALTER TABLE bitcoin_utxos DROP COLUMN IF EXISTS plugin_metadata',
    );
    // Narrowing back fails if any stored value no longer fits, which is the
    // correct outcome: such a database cannot be used by the older release.
    for (final column in ['timestamp', 'version', 'bits', 'nonce']) {
      await conn.execute(
        'ALTER TABLE block_headers ALTER COLUMN $column TYPE INTEGER',
      );
    }
  }
}
