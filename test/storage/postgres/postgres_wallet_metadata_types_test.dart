/// Bead libspiffy-k7na on PostgreSQL: the wallet metadata type contract
/// shared with the in-memory and Isar backends, and migration v025, which
/// repairs the `wallet_type` column rows were written with (bead
/// libspiffy-bfs1), migration v026, which gives every address row its
/// chain (bead libspiffy-m8qu), and migration v027, which lets an address
/// row record a type-42 derivation (bead libspiffy-zxkd).
@Tags(['postgres', 'integration'])
library;

import 'dart:io';

import 'package:postgres/postgres.dart';
import 'package:test/test.dart';

import 'package:libspiffy/src/models/address_chain.dart';
import 'package:libspiffy/src/models/address_metadata.dart';
import 'package:libspiffy/src/models/key_path.dart';
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

    // Bead libspiffy-zxkd: v027 makes the chain nullable and adds the
    // type-42 columns. It refuses to go back while a type-42 row exists: a
    // v026 schema has no place for its derivation, and dropping it would
    // leave the wallet unable to sign for the money at that address.
    test('v027 stores a type-42 row, and will not roll back over one', () async {
      final migrations = PostgresMigrations(config);
      final pool = await config.createPool();
      final wallet = 'v027-$run';
      final derivation = Type42Derivation(
          anchorPublicKey: '02133b035cda4ba15f93b5fdde11c1f73eb9f1a79b60c6caa1c78e1c4c64ed72ce',
          anchorContext: [7, 7, 7],
          senderPublicKey: '02dfcbe35d95b55b5f3168ea8f12717e266ceddf88d04d2ff741272dfb0e542c2a',
          invoiceNumber: 'inv-$run');
      try {
        expect(await migrations.getCurrentVersion(), 27);
        await storage.upsertAddress(
            wallet,
            AddressMetadata(
              address: 'v027-t-$run',
              scriptType: 'p2pkh',
              chain: null,
              type42: derivation,
              purpose: 'type42',
              usageCount: 0,
              balance: BigInt.zero,
              createdAt: DateTime.utc(2026, 9, 24),
              isWatched: true,
            ));
        await expectLater(migrations.rollback(), throwsA(isA<StateError>()));
        expect(await migrations.getCurrentVersion(), 27);
        expect((await storage.getAddressMetadata(wallet, 'v027-t-$run'))!.type42, derivation);

        await pool.execute(Sql.named('DELETE FROM addresses WHERE wallet_id = @w'), parameters: {'w': wallet});
        expect(await migrations.rollback(), isTrue);
        expect(await migrations.getCurrentVersion(), 26);
        await migrations.migrate();
        expect(await migrations.getCurrentVersion(), 27);
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
