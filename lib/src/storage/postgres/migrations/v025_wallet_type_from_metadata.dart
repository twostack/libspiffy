/// Migration v025: the wallet row's type is the type the wallet was created
/// with.
library;

import 'package:postgres/postgres.dart';

import '../postgres_migrations.dart';

/// Bead libspiffy-bfs1: `PostgresWalletStorage.storeWallet` inserted every
/// wallet row with `wallet_type = 'hd'`, whatever type the wallet was
/// created with, so `getWallet(id)['walletType']` answered `hd` for an xpub
/// (watch-only) wallet. The read side's balances now ask that column whether
/// the wallet holds keys at all, so a wrong `hd` would count a watch-only
/// wallet's money as spendable.
///
/// The type was never lost: `WalletProjection` writes it into the row's
/// metadata as `walletType` when it creates the row, and `metadata_json` has
/// held it ever since. This migration copies it into the column wherever the
/// two disagree. A row whose metadata names no type keeps its column: there
/// is no evidence to correct it with.
class V025WalletTypeFromMetadata extends Migration {
  @override
  int get version => 25;

  @override
  String get name => 'wallet_type_from_metadata';

  @override
  Future<void> up(Session conn) async {
    await conn.execute('''
      UPDATE wallet_metadata
      SET wallet_type = metadata_json->>'walletType'
      WHERE metadata_json->>'walletType' IS NOT NULL
        AND wallet_type IS DISTINCT FROM metadata_json->>'walletType'
    ''');
  }

  /// Nothing to undo: the corrected column is what a v024 schema should
  /// have held, and restoring the wrong `hd` would bring back the defect.
  @override
  Future<void> down(Session conn) async {}
}
