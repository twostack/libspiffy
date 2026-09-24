/// Bead libspiffy-k7na on PostgreSQL: the wallet metadata type contract
/// shared with the in-memory and Isar backends, and migration v025, which
/// repairs the `wallet_type` column rows were written with (bead
/// libspiffy-bfs1), and migration v026, which gives every address row its
/// chain (bead libspiffy-m8qu).
@Tags(['postgres', 'integration'])
library;

import 'dart:io';

import 'package:postgres/postgres.dart';
import 'package:test/test.dart';

import 'package:libspiffy/src/models/address_chain.dart';
import 'package:libspiffy/src/storage/postgres/postgres_config.dart';
import 'package:libspiffy/src/storage/postgres/postgres_migrations.dart';
import 'package:libspiffy/src/storage/postgres/postgres_wallet_storage.dart';

import '../wallet_metadata_types_contract.dart';

void main() {
  final config = PostgresConfig(
    host: Platform.environment['POSTGRES_HOST'] ?? 'localhost',
    port: int.tryParse(Platform.environment['POSTGRES_PORT'] ?? '5432') ?? 5432,
    database: Platform.environment['POSTGRES_DATABASE'] ?? 'libspiffy_test',
    username: Platform.environment['POSTGRES_USER'] ?? 'postgres',
    password: Platform.environment['POSTGRES_PASSWORD'] ?? 'postgres',
    maxConnections: 2,
    enableSsl: false, // the local test server has no TLS
  );
  final run = DateTime.now().microsecondsSinceEpoch;

  group('PostgresWalletStorage', () {
    late PostgresWalletStorage storage;
    var counter = 0;

    setUpAll(() async {
      await PostgresMigrations(config).migrate();
    });

    setUp(() async {
      storage = PostgresWalletStorage(config);
      await storage.initialize();
    });

    tearDown(() async {
      await storage.close();
    });

    defineWalletMetadataTypesContract(() => storage, unique: () => 'pw$run-${counter++}');

    // Bead libspiffy-m8qu: v026 replaces is_change with chain, backfilled
    // from it, so an address stored before the delegated chain existed is
    // read on the chain it was on.
    test('v026 gives every address row the chain its is_change recorded', () async {
      final migrations = PostgresMigrations(config);
      final pool = await config.createPool();
      final wallet = 'v026-$run';
      try {
        while (await migrations.getCurrentVersion() >= 26) {
          await migrations.rollback();
        }
        expect(await migrations.getCurrentVersion(), 25);
        for (final (address, isChange) in [('v026-r-$run', false), ('v026-c-$run', true)]) {
          await pool.execute(
            Sql.named('''
              INSERT INTO addresses (wallet_id, address, script_type, derivation_index, is_change, purpose, created_at)
              VALUES (@w, @a, 'p2pkh', 3, @c, @p, NOW())
            '''),
            parameters: {'w': wallet, 'a': address, 'c': isChange, 'p': isChange ? 'change' : 'receive'},
          );
        }
        await migrations.migrate();

        expect((await storage.getAddressMetadata(wallet, 'v026-c-$run'))!.chain, AddressChain.change);
        expect((await storage.getAddressMetadata(wallet, 'v026-r-$run'))!.chain, AddressChain.receive);
        expect((await storage.getAddressRange(wallet, startIndex: 3, count: 1, chain: AddressChain.change))
            .map((a) => a.address), ['v026-c-$run']);
      } finally {
        await pool.execute(Sql.named('DELETE FROM addresses WHERE wallet_id = @w'), parameters: {'w': wallet});
        await pool.close();
      }
    });

    // Every row used to be inserted with wallet_type 'hd'. The type the
    // wallet was created with is in the row's metadata, and v025 copies it
    // into the column; a row whose metadata names no type is left alone.
    test('v025 corrects the wallet_type column from the type in the row metadata', () async {
      final migrations = PostgresMigrations(config);
      final pool = await config.createPool();
      final xpubWallet = 'v025-xpub-$run';
      final untyped = 'v025-untyped-$run';
      try {
        await storage.storeWallet(xpubWallet, 'W', networkType: 'testnet', metadata: {'walletType': 'xpub'});
        await storage.storeWallet(untyped, 'W', networkType: 'testnet', metadata: {'label': 'none'});
        // As a row written before the fix looked.
        await pool.execute(Sql.named("UPDATE wallet_metadata SET wallet_type = 'hd' WHERE wallet_id = @w"),
            parameters: {'w': xpubWallet});
        expect((await storage.getWallet(xpubWallet))!['walletType'], 'hd');

        while (await migrations.getCurrentVersion() >= 25) {
          await migrations.rollback();
        }
        expect(await migrations.getCurrentVersion(), 24);
        await migrations.migrate();

        expect((await storage.getWallet(xpubWallet))!['walletType'], 'xpub');
        expect((await storage.getWallet(untyped))!['walletType'], 'hd');
      } finally {
        await pool.execute(Sql.named('DELETE FROM wallet_metadata WHERE wallet_id IN (@a, @b)'),
            parameters: {'a': xpubWallet, 'b': untyped});
        await pool.close();
      }
    });
  });
}
