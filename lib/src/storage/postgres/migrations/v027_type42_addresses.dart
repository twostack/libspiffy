/// Migration v027: an address row can record a type-42 derivation.
library;

import 'package:postgres/postgres.dart';

import '../postgres_migrations.dart';

/// Bead libspiffy-zxkd: a payer can pay the wallet at an address it derived
/// from the wallet's anchor key with BRC-42 (`Type42Derivation`). Such an
/// address is not on the HD tree, so its row has no chain: `chain` becomes
/// nullable, and the derivation the wallet signs for it with is recorded in
/// `type42_sender_public_key` and `type42_invoice_number`.
class V027Type42Addresses extends Migration {
  @override
  int get version => 27;

  @override
  String get name => 'type42_addresses';

  @override
  Future<void> up(Session conn) async {
    await conn.execute('ALTER TABLE addresses ALTER COLUMN chain DROP NOT NULL');
    await conn.execute('ALTER TABLE addresses ADD COLUMN IF NOT EXISTS type42_sender_public_key TEXT');
    await conn.execute('ALTER TABLE addresses ADD COLUMN IF NOT EXISTS type42_invoice_number TEXT');
  }

  /// Refused while a type-42 row exists: a v026 schema cannot say where its
  /// key comes from, and dropping the record would leave the wallet unable
  /// to sign for the money at it.
  @override
  Future<void> down(Session conn) async {
    final rows = await conn.execute('SELECT COUNT(*) FROM addresses WHERE type42_sender_public_key IS NOT NULL');
    final count = rows.first[0] as int;
    if (count > 0) {
      throw StateError('Cannot revert v027: $count address row(s) record a type-42 derivation, '
          'which a v026 schema has no place for');
    }
    await conn.execute('ALTER TABLE addresses DROP COLUMN IF EXISTS type42_invoice_number');
    await conn.execute('ALTER TABLE addresses DROP COLUMN IF EXISTS type42_sender_public_key');
    await conn.execute('ALTER TABLE addresses ALTER COLUMN chain SET NOT NULL');
  }
}
