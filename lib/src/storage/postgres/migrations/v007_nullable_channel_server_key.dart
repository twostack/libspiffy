/// Migration v007: a payment channel's server key is nullable.
library;

import 'package:postgres/postgres.dart';

import '../postgres_migrations.dart';

/// Audit bead libspiffy-y3b: a requested channel has no server key until the
/// server accepts it, but v001 declared `payment_channels.server_pub_key_hex`
/// `NOT NULL`, so the projection stored `''` as a placeholder that readers
/// took for a key. The column becomes nullable and existing placeholders
/// become `NULL`.
class V007NullableChannelServerKey extends Migration {
  @override
  int get version => 7;

  @override
  String get name => 'nullable_channel_server_key';

  @override
  Future<void> up(Session conn) async {
    await conn.execute(
      'ALTER TABLE payment_channels ALTER COLUMN server_pub_key_hex DROP NOT NULL',
    );
    await conn.execute(
      "UPDATE payment_channels SET server_pub_key_hex = NULL "
      "WHERE server_pub_key_hex = ''",
    );
  }

  @override
  Future<void> down(Session conn) async {
    // Restore the v001 constraint with the placeholder the pre-v007
    // projection used for a channel without a server key.
    await conn.execute(
      "UPDATE payment_channels SET server_pub_key_hex = '' "
      'WHERE server_pub_key_hex IS NULL',
    );
    await conn.execute(
      'ALTER TABLE payment_channels ALTER COLUMN server_pub_key_hex SET NOT NULL',
    );
  }
}
