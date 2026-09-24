/// Migration v026: an address row records its chain, not a change flag.
library;

import 'package:postgres/postgres.dart';

import '../postgres_migrations.dart';

/// Bead libspiffy-m8qu: an address is on one of three chains of the
/// wallet's HD tree — receive (`m/0/i`), change (`m/1/i`) or delegated
/// (`m/2/i`, addresses a service issues from the wallet's xpub for an
/// offline payee; `AddressChain`). `is_change` could name only two, and a
/// delegated address stored as "not change" would be signed for with the
/// receive-chain key: the wrong key.
///
/// `chain` holds `AddressChain.index` and is backfilled from `is_change`
/// (every row written before this migration is receive or change), which is
/// then dropped: the backfill leaves nothing it alone records. The
/// derivation index follows the column.
class V026AddressChain extends Migration {
  @override
  int get version => 26;

  @override
  String get name => 'address_chain';

  @override
  Future<void> up(Session conn) async {
    await conn.execute('ALTER TABLE addresses ADD COLUMN IF NOT EXISTS chain SMALLINT NOT NULL DEFAULT 0');
    await conn.execute('UPDATE addresses SET chain = 1 WHERE is_change');
    await conn.execute('DROP INDEX IF EXISTS idx_addresses_derivation');
    await conn.execute('ALTER TABLE addresses DROP COLUMN is_change');
    await conn.execute('''
      CREATE INDEX IF NOT EXISTS idx_addresses_derivation
      ON addresses(wallet_id, derivation_index, chain)
    ''');
  }

  /// Restores `is_change` from `chain`. A delegated address becomes "not
  /// change": a v025 schema has no way to say more, and the release that
  /// reads it does not know the delegated chain.
  @override
  Future<void> down(Session conn) async {
    await conn.execute('ALTER TABLE addresses ADD COLUMN IF NOT EXISTS is_change BOOLEAN NOT NULL DEFAULT FALSE');
    await conn.execute('UPDATE addresses SET is_change = (chain = 1)');
    await conn.execute('DROP INDEX IF EXISTS idx_addresses_derivation');
    await conn.execute('ALTER TABLE addresses DROP COLUMN chain');
    await conn.execute('''
      CREATE INDEX IF NOT EXISTS idx_addresses_derivation
      ON addresses(wallet_id, derivation_index, is_change)
    ''');
  }
}
