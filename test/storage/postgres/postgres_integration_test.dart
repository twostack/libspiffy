/// PostgreSQL Integration Tests for libspiffy
///
/// These tests require a running PostgreSQL instance. Configure via environment:
///   POSTGRES_HOST (default: localhost)
///   POSTGRES_PORT (default: 5432)
///   POSTGRES_DATABASE (default: libspiffy_test)
///   POSTGRES_USER (default: postgres)
///   POSTGRES_PASSWORD (default: postgres)
///
/// To run: dart test test/storage/postgres/ --tags=postgres
/// To skip: dart test --exclude-tags=postgres
///
/// Docker quickstart:
///   docker run -d --name libspiffy-postgres \
///     -e POSTGRES_USER=postgres \
///     -e POSTGRES_PASSWORD=postgres \
///     -e POSTGRES_DB=libspiffy_test \
///     -p 5432:5432 postgres:16
@Tags(['postgres', 'integration'])
library;

import 'dart:async';
import 'dart:io';

import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:eventador/eventador.dart';
import 'package:postgres/postgres.dart' show Sql;
import 'package:spiffynode/spiffy_node.dart';
import 'package:test/test.dart';

import 'package:libspiffy/src/storage/postgres/postgres_config.dart';
import 'package:libspiffy/src/storage/postgres/postgres_event_store.dart';
import 'package:libspiffy/src/storage/postgres/postgres_wallet_storage.dart';
import 'package:libspiffy/src/storage/postgres/postgres_migrations.dart';
import 'package:libspiffy/src/models/bitcoin_utxo.dart';
import 'package:libspiffy/src/models/bitcoin_transaction.dart';
import 'package:libspiffy/src/models/address_metadata.dart';
import 'package:libspiffy/src/models/invoice_read_model.dart';
import 'package:libspiffy/src/models/payment_channel.dart';
import 'package:libspiffy/src/actors/invoice_messages.dart' show InvoiceStatus;

import '../channel_read_model_contract.dart';
import '../invoice_read_model_contract.dart';
import '../header_reorg_contract.dart';
import '../read_model_keying_contract.dart';
import '../wallet_lifecycle_contract.dart';

/// Get PostgreSQL configuration from environment or use defaults
PostgresConfig getTestConfig() {
  return PostgresConfig(
    host: Platform.environment['POSTGRES_HOST'] ?? 'localhost',
    port: int.tryParse(Platform.environment['POSTGRES_PORT'] ?? '5432') ?? 5432,
    database: Platform.environment['POSTGRES_DATABASE'] ?? 'libspiffy_test',
    username: Platform.environment['POSTGRES_USER'] ?? 'postgres',
    password: Platform.environment['POSTGRES_PASSWORD'] ?? 'postgres',
    // SSL is on by default (audit S-14); the local test server has none.
    enableSsl: false,
    maxConnections: 5,
  );
}

/// Removes every stored block header.
///
/// The header tests store real mainnet headers whose nonce exceeds int32.
/// Such rows make v003's `down` (narrowing back to INTEGER) fail, so they
/// must be gone before the schema is reset and after the header group.
Future<void> clearBlockHeaders(PostgresConfig config) async {
  final pool = await config.createPool();
  try {
    await pool.execute('DELETE FROM block_headers');
  } catch (_) {
    // Table absent (schema not yet migrated): nothing to clear.
  } finally {
    await pool.close();
  }
}

/// Minimal event for the event-stream tests.
class StreamRaceEvent extends Event {
  final String data;

  /// Padding so a large journal makes the replay SELECT measurably slow.
  final String padding;

  StreamRaceEvent(
    this.data, {
    this.padding = '',
    super.eventId,
    super.timestamp,
  });

  @override
  Map<String, dynamic> toMap() =>
      {...super.toMap(), 'data': data, 'padding': padding};

  static StreamRaceEvent fromMap(Map<String, dynamic> map) => StreamRaceEvent(
        map['data'] as String,
        padding: map['padding'] as String? ?? '',
        eventId: map['eventId'] as String,
        timestamp: map['timestamp'] is DateTime
            ? map['timestamp'] as DateTime
            : DateTime.parse(map['timestamp'] as String),
      );
}

/// Polls until [condition] holds or [timeout] elapses.
Future<void> waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

/// A header for the block-header tests, unique per [seed].
BlockHeader syntheticHeader(int seed) => BlockHeader(
      version: 1,
      prevBlock: Hash.fromHex(seed.toRadixString(16).padLeft(64, '0')),
      merkleRoot: Hash.fromHex((seed + 1).toRadixString(16).padLeft(64, '0')),
      timestamp: DateTime.fromMillisecondsSinceEpoch(
        (1231469665 + seed) * 1000,
        isUtc: true,
      ),
      bits: 0x1d00ffff,
      nonce: seed,
    );

void main() {
  final config = getTestConfig();

  group('PostgreSQL Migrations', () {
    test('should run migrations successfully', () async {
      final migrations = PostgresMigrations(config);

      // Reset to clean state
      await clearBlockHeaders(config);
      await migrations.reset();

      // Run migrations
      await migrations.migrate();

      // Verify version: v001 initial schema, v002 secure secrets,
      // v003 header ints + plugin metadata, v004 channel columns +
      // invoice outputs, v005 wallet-scoped keys + unique proofs,
      // v007 nullable channel server key, v008 journal tx id, v009 merkle proof status,
      // v010 ancestor transactions, v011 UTXO reservation columns,
      // v012 merkle proof rejected status, v013 deferred payments,
      // v014 confirmed transaction height index, v015 transaction counterparty,
      // v016 merkle proof status height index, v017 deferred payment
      // competing txids, v018 merkle proof status changed index,
      // v019 transaction status updated index, v020 pending receives,
      // v021 transaction counterparty marker,
      // v022 channel lock time BIGINT,
      // v023 transaction lock time and version,
      // v024 the UTXO row's status flag renamed is_available
      final version = await migrations.getCurrentVersion();
      expect(version, equals(24));

      // Verify applied migrations
      final applied = await migrations.getAppliedMigrations();
      expect(applied, hasLength(24));
      expect(applied.first.name, equals('initial_schema'));
      expect(applied.last.name, equals('utxo_is_available_column'));
    });

    test('should handle re-running migrations idempotently', () async {
      final migrations = PostgresMigrations(config);

      // Run twice - should not fail
      await migrations.migrate();
      await migrations.migrate();

      final version = await migrations.getCurrentVersion();
      expect(version, equals(24));
    });

    test('should rollback migrations one at a time', () async {
      final migrations = PostgresMigrations(config);

      await migrations.migrate();
      expect(await migrations.getCurrentVersion(), equals(24));

      expect(await migrations.rollback(), isTrue);
      expect(await migrations.getCurrentVersion(), equals(23));

      expect(await migrations.rollback(), isTrue);
      expect(await migrations.getCurrentVersion(), equals(22));

      expect(await migrations.rollback(), isTrue);
      expect(await migrations.getCurrentVersion(), equals(21));

      expect(await migrations.rollback(), isTrue);
      expect(await migrations.getCurrentVersion(), equals(20));

      expect(await migrations.rollback(), isTrue);
      expect(await migrations.getCurrentVersion(), equals(19));

      expect(await migrations.rollback(), isTrue);
      expect(await migrations.getCurrentVersion(), equals(18));

      expect(await migrations.rollback(), isTrue);
      expect(await migrations.getCurrentVersion(), equals(17));

      expect(await migrations.rollback(), isTrue);
      expect(await migrations.getCurrentVersion(), equals(16));

      expect(await migrations.rollback(), isTrue);
      expect(await migrations.getCurrentVersion(), equals(15));

      expect(await migrations.rollback(), isTrue);
      expect(await migrations.getCurrentVersion(), equals(14));

      expect(await migrations.rollback(), isTrue);
      expect(await migrations.getCurrentVersion(), equals(13));

      expect(await migrations.rollback(), isTrue);
      expect(await migrations.getCurrentVersion(), equals(12));

      expect(await migrations.rollback(), isTrue);
      expect(await migrations.getCurrentVersion(), equals(11));

      expect(await migrations.rollback(), isTrue);
      expect(await migrations.getCurrentVersion(), equals(10));

      expect(await migrations.rollback(), isTrue);
      expect(await migrations.getCurrentVersion(), equals(9));

      expect(await migrations.rollback(), isTrue);
      expect(await migrations.getCurrentVersion(), equals(8));

      expect(await migrations.rollback(), isTrue);
      expect(await migrations.getCurrentVersion(), equals(7));

      expect(await migrations.rollback(), isTrue);
      expect(await migrations.getCurrentVersion(), equals(6));

      expect(await migrations.rollback(), isTrue);
      expect(await migrations.getCurrentVersion(), equals(5));

      expect(await migrations.rollback(), isTrue);
      expect(await migrations.getCurrentVersion(), equals(4));

      expect(await migrations.rollback(), isTrue);
      expect(await migrations.getCurrentVersion(), equals(3));

      expect(await migrations.rollback(), isTrue);
      expect(await migrations.getCurrentVersion(), equals(2));

      expect(await migrations.rollback(), isTrue);
      expect(await migrations.getCurrentVersion(), equals(1));

      expect(await migrations.rollback(), isTrue);
      expect(await migrations.getCurrentVersion(), equals(0));

      // Nothing left to roll back
      expect(await migrations.rollback(), isFalse);
    });

    test('v005 rolls back and re-applies with two wallets sharing a txid, an outpoint and a proof',
        () async {
      final migrations = PostgresMigrations(config);
      await migrations.migrate();
      expect(await migrations.getCurrentVersion(), equals(24));

      final storage = PostgresWalletStorage(config);
      await storage.initialize();
      final txid = 'f5' * 32;
      BitcoinTransaction tx(int net) => BitcoinTransaction(
            txid: txid,
            rawHex: '01000000',
            status: TransactionStatus.pending,
            inputValue: BigInt.from(2000),
            outputValue: BigInt.from(1800),
            fee: BigInt.from(200),
            receivingAddresses: const [],
            sendingAddresses: const [],
            netAmount: BigInt.from(net),
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
            lockTime: 0,
            version: 1,
          );
      BitcoinUtxo utxo() => BitcoinUtxo(
            txid: txid,
            vout: 0,
            value: dartsv.Coin.ofSat(BigInt.from(1800)),
            scriptPubKey: '76a914',
            address: 'addr',
            status: UTXOStatus.available,
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          );
      try {
        await storage.storeTransaction('v005-a', tx(-1800));
        await storage.storeTransaction('v005-b', tx(1800));
        await storage.upsertUTXO('v005-a', utxo());
        await storage.upsertUTXO('v005-b', utxo());
      } finally {
        await storage.close();
      }

      // v018, v017, v016, v015, v014, v013, v012, v011, v010, v009, v008, v007 and v006 first;
      // then v005's down keeps the first-stored row so the global keys can be restored.
      expect(await migrations.rollback(), isTrue); // v024 (utxo is_available column)
      expect(await migrations.rollback(), isTrue); // v023 (transaction lock time and version)
      expect(await migrations.rollback(), isTrue); // v022 (channel lock time BIGINT)
      expect(await migrations.rollback(), isTrue); // v021 (transaction counterparty marker)
      expect(await migrations.rollback(), isTrue); // v020 (pending receives)
      expect(await migrations.rollback(), isTrue); // v019
      expect(await migrations.rollback(), isTrue); // v018
      expect(await migrations.rollback(), isTrue); // v017
      expect(await migrations.rollback(), isTrue); // v016
      expect(await migrations.rollback(), isTrue); // v015
      expect(await migrations.rollback(), isTrue); // v014
      expect(await migrations.rollback(), isTrue); // v013
      expect(await migrations.rollback(), isTrue); // v012
      expect(await migrations.rollback(), isTrue); // v011
      expect(await migrations.rollback(), isTrue); // v010
      expect(await migrations.rollback(), isTrue); // v009
      expect(await migrations.rollback(), isTrue); // v008
      expect(await migrations.rollback(), isTrue); // v007
      expect(await migrations.rollback(), isTrue); // v006
      expect(await migrations.getCurrentVersion(), equals(5));
      expect(await migrations.rollback(), isTrue);
      expect(await migrations.getCurrentVersion(), equals(4));
      final pool = await config.createPool();
      try {
        final txRows = await pool.execute(
          Sql.named('SELECT wallet_id FROM bitcoin_transactions WHERE txid = @txid'),
          parameters: {'txid': txid},
        );
        expect(txRows.map((r) => r[0]), ['v005-a']);
        final utxoRows = await pool.execute(
          Sql.named('SELECT wallet_id FROM bitcoin_utxos WHERE txid = @txid'),
          parameters: {'txid': txid},
        );
        expect(utxoRows.map((r) => r[0]), ['v005-a']);

        // Up again, and leave the database at the latest version.
        await migrations.migrate();
        expect(await migrations.getCurrentVersion(), equals(24));
        await pool.execute(
          Sql.named('DELETE FROM bitcoin_transactions WHERE txid = @txid'),
          parameters: {'txid': txid},
        );
        await pool.execute(
          Sql.named('DELETE FROM bitcoin_utxos WHERE txid = @txid'),
          parameters: {'txid': txid},
        );
      } finally {
        await pool.close();
      }
    });

    test('v007 rolls back and re-applies with a channel that has no server key (y3b)',
        () async {
      final migrations = PostgresMigrations(config);
      await migrations.migrate();
      final channelId = 'v007-channel-${DateTime.now().microsecondsSinceEpoch}';
      final storage = PostgresWalletStorage(config);
      await storage.initialize();
      final pool = await config.createPool();
      try {
        await runRequestedChannelServerKeyContract(storage,
            channelId: '$channelId-accepted', walletId: 'v007-wallet');
        await storage.storePaymentChannel(PaymentChannel(
          channelId: channelId,
          walletId: 'v007-wallet',
          role: PaymentChannelRole.client,
          clientPeerId: 'c',
          serverPeerId: 's',
          clientPubKeyHex: contractClientPubKeyHex,
          fundingAmountSats: BigInt.from(5000),
          lockTimeUnix: contractLockTimeUnix,
        ));

        Future<Object?> serverKeyColumn() async => (await pool.execute(
              Sql.named('SELECT server_pub_key_hex FROM payment_channels '
                  'WHERE channel_id = @id'),
              parameters: {'id': channelId},
            ))
                .single[0];

        expect(await serverKeyColumn(), isNull);

        // Down restores NOT NULL with the old '' placeholder.
        expect(await migrations.rollback(), isTrue); // v024 (utxo is_available column)
        expect(await migrations.rollback(), isTrue); // v023 (transaction lock time and version)
      expect(await migrations.rollback(), isTrue); // v022 (channel lock time BIGINT)
        expect(await migrations.rollback(), isTrue); // v021 (transaction counterparty marker)
      expect(await migrations.rollback(), isTrue); // v020 (pending receives)
      expect(await migrations.rollback(), isTrue); // v019
        expect(await migrations.rollback(), isTrue); // v018
        expect(await migrations.rollback(), isTrue); // v017
        expect(await migrations.rollback(), isTrue); // v016
        expect(await migrations.rollback(), isTrue); // v015
        expect(await migrations.rollback(), isTrue); // v014
        expect(await migrations.rollback(), isTrue); // v013
        expect(await migrations.rollback(), isTrue); // v012
        expect(await migrations.rollback(), isTrue); // v011
        expect(await migrations.rollback(), isTrue); // v010
        expect(await migrations.rollback(), isTrue); // v009
        expect(await migrations.rollback(), isTrue); // v008
        expect(await migrations.rollback(), isTrue);
        expect(await migrations.getCurrentVersion(), equals(6));
        expect(await serverKeyColumn(), equals(''));

        // Up turns the placeholder back into NULL.
        await migrations.migrate();
        expect(await migrations.getCurrentVersion(), equals(24));
        expect(await serverKeyColumn(), isNull);
        expect((await storage.getPaymentChannel(channelId))!.serverPubKeyHex,
            isNull);
        expect(
            (await storage.getPaymentChannel('$channelId-accepted'))!
                .serverPubKeyHex,
            equals(contractServerPubKeyHex));
      } finally {
        await pool.execute(
          Sql.named("DELETE FROM payment_channels WHERE wallet_id = 'v007-wallet'"),
        );
        await pool.close();
        await storage.close();
      }
    });
  });

  group('PostgresEventStore', () {
    late PostgresEventStore eventStore;

    setUpAll(() async {
      // Ensure migrations are run
      final migrations = PostgresMigrations(config);
      await migrations.migrate();
      EventRegistry.register<StreamRaceEvent>(
        'StreamRaceEvent',
        StreamRaceEvent.fromMap,
      );
    });

    setUp(() async {
      eventStore = PostgresEventStore(config);
      await eventStore.initialize();
    });

    tearDown(() async {
      await eventStore.close();
    });

    // S-00: the live subscription used to be opened only after the historical
    // replay finished, so anything persisted between the replay SELECT's
    // snapshot and the end of the replay was never delivered to that
    // subscriber. The store's replay hooks park the replay at exact points so
    // the race is reproduced deterministically:
    //   before the query  -> events land in the snapshot AND arrive live
    //                        (must be delivered once, not twice);
    //   after the query   -> events are not in the snapshot and arrive live
    //                        while the replay is still running (must be
    //                        buffered, not lost);
    //   after the replay  -> ordinary live events.
    test(
        'live stream delivers events persisted during replay exactly once, in order',
        () async {
      final pid = 'stream-race-${DateTime.now().microsecondsSinceEpoch}';
      const seeded = 10;
      const beforeQuery = 3;
      const afterQuery = 4;
      const live = 3;

      var version = 0;
      Future<void> persist(String tag, int count) async {
        for (var i = 0; i < count; i++) {
          await eventStore.persistEvent(
              pid, StreamRaceEvent('$tag-$i'), version++);
        }
      }

      await persist('seed', seeded);
      final baseline =
          await eventStore.allEventsWithSequence(live: false).toList();
      final firstId = baseline[baseline.length - seeded].$2;

      final queryGate = Completer<void>();
      final queryIssued = Completer<void>();
      final rowsGate = Completer<void>();
      final queryDone = Completer<void>();
      eventStore.beforeReplayQuery = () {
        queryIssued.complete();
        return queryGate.future;
      };
      eventStore.afterReplayQuery = () {
        queryDone.complete();
        return rowsGate.future;
      };

      final received = <(Event, int)>[];
      final sub = eventStore
          .allEventsWithSequence(fromSequence: firstId - 1)
          .listen(received.add);

      // Replay parked before its SELECT: these commit into the snapshot and
      // are also published live to the (already open) subscription.
      await queryIssued.future;
      await persist('before', beforeQuery);
      expect(received, isEmpty, reason: 'nothing is emitted before the replay');
      queryGate.complete();

      // Replay parked after its SELECT returned, before any row is emitted:
      // these are NOT in the snapshot and arrive live mid-replay.
      await queryDone.future;
      await persist('during', afterQuery);
      expect(received, isEmpty, reason: 'nothing is emitted before the rows');
      rowsGate.complete();

      await waitUntil(
          () => received.length >= seeded + beforeQuery + afterQuery);
      await persist('live', live);
      final total = seeded + beforeQuery + afterQuery + live;
      await waitUntil(() => received.length >= total);
      await sub.cancel();

      expect(received.map((r) => r.$2), List.generate(total, (i) => firstId + i),
          reason: 'envelope ids must be contiguous, strictly increasing, '
              'and each delivered exactly once');
      expect(
        received.map((r) => (r.$1 as StreamRaceEvent).data),
        [
          for (var i = 0; i < seeded; i++) 'seed-$i',
          for (var i = 0; i < beforeQuery; i++) 'before-$i',
          for (var i = 0; i < afterQuery; i++) 'during-$i',
          for (var i = 0; i < live; i++) 'live-$i',
        ],
      );
    });

    test('per-actor live stream buffers events persisted during replay',
        () async {
      final stamp = DateTime.now().microsecondsSinceEpoch;
      final a = 'actor-a-$stamp';
      final b = 'actor-b-$stamp';
      var versionA = 0;
      var versionB = 0;
      Future<void> persistA(String tag) => eventStore.persistEvent(
          a, StreamRaceEvent('a-$tag'), versionA++);
      Future<void> persistB(String tag) => eventStore.persistEvent(
          b, StreamRaceEvent('b-$tag'), versionB++);

      await persistA('seed-0');
      await persistA('seed-1');
      await persistB('seed-0');

      final rowsGate = Completer<void>();
      final queryDone = Completer<void>();
      eventStore.afterReplayQuery = () {
        queryDone.complete();
        return rowsGate.future;
      };

      final received = <String>[];
      final sub = eventStore
          .eventsByPersistenceId(a)
          .listen((e) => received.add((e as StreamRaceEvent).data));

      await queryDone.future;
      await persistA('during-0');
      await persistB('during-0');
      await persistA('during-1');
      rowsGate.complete();

      await waitUntil(() => received.length >= 4);
      await persistB('live-0');
      await persistA('live-0');
      await waitUntil(() => received.length >= 5);
      await sub.cancel();

      expect(received,
          ['a-seed-0', 'a-seed-1', 'a-during-0', 'a-during-1', 'a-live-0']);
    });

    test('live stream stays gap-free without hooks while events are persisted',
        () async {
      // The unhooked path: subscribe while a batch of persists is in flight
      // and check the property that matters (no gap, no duplicate, in order).
      // Which persists land in the replay snapshot and which arrive live is
      // timing-dependent, so this does not by itself prove the race.
      final pid = 'stream-natural-${DateTime.now().microsecondsSinceEpoch}';
      const seeded = 300;
      const during = 10;
      var version = 0;
      for (var b = 0; b < seeded; b += 100) {
        final batch = List.generate(
            100, (i) => StreamRaceEvent('seed-${b + i}', padding: 'x' * 1024));
        await eventStore.persistEvents(pid, batch, version);
        version += batch.length;
      }
      final baseline =
          await eventStore.allEventsWithSequence(live: false).toList();
      final firstId = baseline[baseline.length - seeded].$2;

      final received = <int>[];
      final sub = eventStore
          .allEventsWithSequence(fromSequence: firstId - 1)
          .listen((r) => received.add(r.$2));
      for (var i = 0; i < during; i++) {
        await eventStore.persistEvent(
            pid, StreamRaceEvent('during-$i'), version++);
      }
      await waitUntil(() => received.length >= seeded + during);
      await sub.cancel();

      expect(received, List.generate(seeded + during, (i) => firstId + i));
    });
    test('should get highest sequence number for new persistence ID', () async {
      final seq = await eventStore.getHighestSequenceNumber('new-aggregate-id');
      expect(seq, equals(0));
    });

    test('should load null snapshot for non-existent aggregate', () async {
      final snapshot = await eventStore.loadSnapshot('non-existent-id');
      expect(snapshot, isNull);
    });

    test('should save and load snapshot', () async {
      const persistenceId = 'test-aggregate-snapshot';
      final state = {'balance': 1000, 'name': 'Test Wallet'};

      await eventStore.saveSnapshot(persistenceId, state, 5);

      final loaded = await eventStore.loadSnapshot(persistenceId);
      expect(loaded, isNotNull);
      expect(loaded!.sequenceNumber, equals(5));
      expect(loaded.state, isA<Map>());
    });

    test('should list persistence IDs', () async {
      final ids = await eventStore.currentPersistenceIds().toList();
      expect(ids, isA<List<String>>());
    });
  });

  group('PostgresWalletStorage', () {
    late PostgresWalletStorage storage;
    const testWalletId = 'test-wallet-postgres';

    setUpAll(() async {
      final migrations = PostgresMigrations(config);
      await migrations.migrate();
    });

    setUp(() async {
      storage = PostgresWalletStorage(config);
      await storage.initialize();
    });

    tearDown(() async {
      await storage.close();
    });

    group('Wallet Metadata', () {
      test('should store and retrieve wallet', () async {
        await storage.storeWallet(
          testWalletId,
          'Test Wallet',
          networkType: 'testnet',
          metadata: {'version': 1},
        );

        final wallet = await storage.getWallet(testWalletId);
        expect(wallet, isNotNull);
        expect(wallet!['name'], equals('Test Wallet'));
      });

      test('should list wallets', () async {
        await storage.storeWallet('wallet-1', 'Wallet One');
        await storage.storeWallet('wallet-2', 'Wallet Two');

        final wallets = await storage.listWallets();
        expect(wallets, contains('wallet-1'));
        expect(wallets, contains('wallet-2'));
      });

      test('keeps the network on a metadata-only update', () async {
        // S-06: a balance/metadata update passes no networkType; the old
        // code bound `networkType ?? 'mainnet'`, so every such update reset
        // a testnet wallet to mainnet.
        await storage.storeWallet(
          'net-wallet',
          'Net Wallet',
          networkType: 'testnet',
          metadata: {'version': 1},
        );
        await storage.storeWallet(
          'net-wallet',
          'Net Wallet',
          metadata: {'confirmedBalance': '100'},
        );

        final wallet = await storage.getWallet('net-wallet');
        expect(wallet, isNotNull);
        expect(wallet!['network'], equals('testnet'));
      });
    });

    group('UTXO Operations', () {
      test('should store and retrieve UTXO', () async {
        await storage.storeWallet(testWalletId, 'UTXO Test Wallet');

        final utxo = BitcoinUtxo(
          txid: 'abc123def456789012345678901234567890123456789012345678901234',
          vout: 0,
          value: dartsv.Coin.ofSat(BigInt.from(50000)),
          scriptPubKey: '76a914...88ac',
          address: 'mtest123...',
          status: UTXOStatus.available,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );

        await storage.upsertUTXO(testWalletId, utxo);

        final utxos = await storage.getUTXOs(testWalletId);
        expect(utxos, isNotEmpty);
        expect(utxos.first.txid, equals(utxo.txid));
      });

      test('should calculate balance', () async {
        await storage.storeWallet('balance-wallet', 'Balance Wallet');

        final utxo1 = BitcoinUtxo(
          txid: 'tx1${'0' * 60}',
          vout: 0,
          value: dartsv.Coin.ofSat(BigInt.from(10000)),
          scriptPubKey: '76a914...88ac',
          address: 'addr1',
          status: UTXOStatus.available,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );

        final utxo2 = BitcoinUtxo(
          txid: 'tx2${'0' * 60}',
          vout: 0,
          value: dartsv.Coin.ofSat(BigInt.from(20000)),
          scriptPubKey: '76a914...88ac',
          address: 'addr2',
          status: UTXOStatus.available,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );

        await storage.upsertUTXO('balance-wallet', utxo1);
        await storage.upsertUTXO('balance-wallet', utxo2);

        final balance = await storage.getBalance('balance-wallet');
        expect(balance, equals(BigInt.from(30000)));
      });

      test('keeps plugin-managed UTXOs out of payment UTXOs and balance', () async {
        await storage.storeWallet('plugin-wallet', 'Plugin Wallet');
        final payment = BitcoinUtxo(
          txid: 'pay${'0' * 61}',
          vout: 0,
          value: dartsv.Coin.ofSat(BigInt.from(10000)),
          scriptPubKey: '76a914...88ac',
          address: 'addr-pay',
          status: UTXOStatus.available,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );
        final token = BitcoinUtxo(
          txid: 'tok${'0' * 61}',
          vout: 1,
          value: dartsv.Coin.ofSat(BigInt.from(1)),
          scriptPubKey: '76a914...88ac',
          address: 'addr-token',
          status: UTXOStatus.available,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
          pluginMetadata: {'pluginId': 'pp1', 'tokenId': 't-1'},
        );
        await storage.upsertUTXO('plugin-wallet', payment);
        await storage.upsertUTXO('plugin-wallet', token);

        // Metadata round-trips through the JSONB column.
        final all = await storage.getUTXOs('plugin-wallet');
        final storedToken = all.firstWhere((u) => u.txid == token.txid);
        expect(storedToken.pluginMetadata, equals({'pluginId': 'pp1', 'tokenId': 't-1'}));

        // Before v003 the column did not exist, so the token was selectable
        // as ordinary funding and counted in the balance.
        final paymentUtxos = await storage.getPaymentUTXOs('plugin-wallet');
        expect(paymentUtxos.map((u) => u.txid), equals([payment.txid]));
        expect(await storage.getBalance('plugin-wallet'), equals(BigInt.from(10000)));

        final byPlugin = await storage.getUTXOsByPlugin('plugin-wallet', 'pp1');
        expect(byPlugin.map((u) => u.txid), equals([token.txid]));
        final filtered = await storage.getUTXOsByPlugin(
          'plugin-wallet', 'pp1', metadataFilter: {'tokenId': 'other'});
        expect(filtered, isEmpty);
      });

      test('should filter spent UTXOs', () async {
        await storage.storeWallet('spent-test', 'Spent Test');

        final available = BitcoinUtxo(
          txid: 'avail${'0' * 59}',
          vout: 0,
          value: dartsv.Coin.ofSat(BigInt.from(5000)),
          scriptPubKey: '76a914...88ac',
          address: 'addr1',
          status: UTXOStatus.available,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );

        final spent = BitcoinUtxo(
          txid: 'spent${'0' * 59}',
          vout: 0,
          value: dartsv.Coin.ofSat(BigInt.from(3000)),
          scriptPubKey: '76a914...88ac',
          address: 'addr2',
          status: UTXOStatus.spent,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );

        await storage.upsertUTXO('spent-test', available);
        await storage.upsertUTXO('spent-test', spent);

        final utxos = await storage.getUTXOs('spent-test', includeSpent: false);
        expect(utxos, hasLength(1));
        expect(utxos.first.txid, equals(available.txid));
      });
    });

    group('Block Header Operations', () {
      setUpAll(() => clearBlockHeaders(config));
      // Leave no header behind whose nonce cannot be narrowed back to
      // INTEGER, or the next run's schema reset (v003 down) fails.
      tearDownAll(() => clearBlockHeaders(config));

      test('stores a bulk batch atomically', () async {
        // S-08: the batch used to be one autocommitted INSERT per header, so
        // a failure part-way left the earlier headers stored. The third
        // header's height does not fit the INTEGER height column.
        final h1 = syntheticHeader(101);
        final h2 = syntheticHeader(102);
        final h3 = syntheticHeader(103);
        const height1 = 700001;
        const height2 = 700002;
        const badHeight = 1 << 40;

        await expectLater(
          storage.storeBlockHeadersBulk([
            (h1, height1),
            (h2, height2),
            (h3, badHeight),
          ]),
          throwsA(anything),
        );

        expect(await storage.getBlockHeaderByHeight(height1), isNull,
            reason: 'a failed batch must not leave its first header stored');
        expect(await storage.getBlockHeaderByHeight(height2), isNull,
            reason: 'a failed batch must not leave its second header stored');
        expect(await storage.getBlockHeaderByHash(h1.blockHash().toString()),
            isNull);
      });

      test('S-08: a bulk batch is written as multi-row statements in chunks, with upsert semantics',
          () async {
        // S-08: one INSERT per header made a CDN sync ~900k round-trips.
        final statements = <int>[];
        storage.headerInsertChunkSize = 3;
        storage.onHeaderInsertStatement = statements.add;
        final headers = [
          for (var i = 0; i < 7; i++) (syntheticHeader(300 + i), 710000 + i),
        ];

        await storage.storeBlockHeadersBulk(headers);

        expect(statements, [3, 3, 1],
            reason: '7 headers in chunks of 3 are three multi-row statements');
        for (final (header, height) in headers) {
          expect((await storage.getBlockHeaderByHeight(height))?.blockHash(),
              equals(header.blockHash()));
        }

        // Upsert: an orphaned header is re-activated, a hash repeated
        // within the batch is written once, nothing is duplicated.
        final orphan = headers[2].$1.blockHash().toString();
        await storage.markHeaderAsOrphaned(orphan);
        expect(await storage.getBlockHeaderByHash(orphan), isNull);
        statements.clear();
        await storage.storeBlockHeadersBulk([...headers, headers[2]]);
        expect(statements, [3, 3, 1]);
        expect(await storage.getBlockHeaderByHash(orphan), isNotNull);
        expect(await storage.getHeightByBlockHash(orphan), 710002);
        expect(await storage.getBlockHeaderRange(710000, 710006), hasLength(7));
        final pool = await config.createPool();
        try {
          final count = await pool.execute(
              'SELECT COUNT(*) FROM block_headers WHERE height BETWEEN 710000 AND 710006');
          expect(count.first[0], 7);
        } finally {
          await pool.close();
        }
      });

      test('stores a header whose nonce exceeds int32', () async {
        // Block 1 on mainnet has nonce 2573394689 (> 2^31 - 1); with the
        // INTEGER column of v001 this insert failed as out of range.
        final header = BlockHeader(
          version: 1,
          prevBlock: Hash.fromHex('000000000019d6689c085ae165831e934ff763ae46a2a6c172b3f1b60a8ce26f'),
          merkleRoot: Hash.fromHex('0e3e2357e806b6cdb1f70b54c3a3a17b6714ee1f0e68bebb44a74b1efd512098'),
          timestamp: DateTime.fromMillisecondsSinceEpoch(1231469665 * 1000, isUtc: true),
          bits: 0x1d00ffff,
          nonce: 2573394689,
        );
        await storage.storeBlockHeadersBulk([(header, 1)]);
        final stored = await storage.getBlockHeaderByHeight(1);
        expect(stored, isNotNull);
        expect(stored!.nonce, equals(2573394689));
      });
    });

    group('Address Operations', () {
      test('should store and retrieve address', () async {
        await storage.storeWallet('addr-wallet', 'Address Wallet');

        final address = AddressMetadata(
          address: 'mtest1234567890abcdef',
          scriptType: 'p2pkh',
          derivationPath: "m/44'/1'/0'/0/0",
          derivationIndex: 0,
          isChange: false,
          label: 'Main Address',
          purpose: 'receive',
          firstUsedAt: null,
          lastUsedAt: null,
          usageCount: 0,
          balance: BigInt.zero,
          createdAt: DateTime.now(),
          isWatched: true,
        );

        await storage.upsertAddress('addr-wallet', address);

        final addresses = await storage.getAddressesWithMetadata('addr-wallet');
        expect(addresses, isNotEmpty);
        expect(addresses.first.address, equals(address.address));
      });

      test('should get address count', () async {
        await storage.storeWallet('count-wallet', 'Count Wallet');

        for (var i = 0; i < 5; i++) {
          final addr = AddressMetadata(
            address: 'addr$i${'0' * 20}',
            scriptType: 'p2pkh',
            isChange: false,
            purpose: 'receive',
            usageCount: 0,
            balance: BigInt.zero,
            createdAt: DateTime.now(),
            isWatched: true,
          );
          await storage.upsertAddress('count-wallet', addr);
        }

        final count = await storage.getAddressCount('count-wallet');
        expect(count, equals(5));
      });
    });

    group('Transaction Operations', () {
      test('should store and retrieve transaction', () async {
        await storage.storeWallet('tx-wallet', 'Transaction Wallet');

        final tx = BitcoinTransaction(
          txid: 'txid${'0' * 60}',
          rawHex: '0100000001...',
          status: TransactionStatus.confirmed,
          blockHeight: 100000,
          confirmations: 6,
          inputValue: BigInt.from(50000),
          outputValue: BigInt.from(49000),
          fee: BigInt.from(1000),
          netAmount: BigInt.from(-50000),
          receivingAddresses: ['addr1'],
          sendingAddresses: ['addr2'],
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
          lockTime: 0,
          version: 1,
        );

        await storage.storeTransaction('tx-wallet', tx);

        final history = await storage.getTransactionHistory('tx-wallet');
        expect(history, isNotEmpty);
        expect(history.first.txid, equals(tx.txid));
      });

      test('should get transaction by ID', () async {
        await storage.storeWallet('tx-get-wallet', 'TX Get Wallet');

        final tx = BitcoinTransaction(
          txid: 'unique${'0' * 58}',
          rawHex: '0100000001...',
          status: TransactionStatus.pending,
          inputValue: BigInt.from(10000),
          outputValue: BigInt.from(9500),
          fee: BigInt.from(500),
          netAmount: BigInt.from(-10000),
          receivingAddresses: [],
          sendingAddresses: [],
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
          lockTime: 0,
          version: 1,
        );

        await storage.storeTransaction('tx-get-wallet', tx);

        final retrieved = await storage.getTransaction(tx.txid);
        expect(retrieved, isNotNull);
        expect(retrieved!.txid, equals(tx.txid));
      });
    });

    group('Invoice Operations', () {
      test('should store and retrieve invoice', () async {
        await storage.storeWallet('invoice-wallet', 'Invoice Wallet');

        final invoice = InvoiceReadModel(
          invoiceId: 'inv-001',
          walletId: 'invoice-wallet',
          addresses: ['addr1', 'addr2'],
          amount: BigInt.from(100000),
          description: 'Test Invoice',
          status: InvoiceStatus.pending,
          createdAt: DateTime.now(),
          expiresAt: DateTime.now().add(Duration(hours: 24)),
          lastUpdated: DateTime.now(),
          metadata: {},
        );

        await storage.storeInvoice(invoice);

        final retrieved = await storage.getInvoice('inv-001');
        expect(retrieved, isNotNull);
        expect(retrieved!.invoiceId, equals('inv-001'));
        expect(retrieved.amount, equals(BigInt.from(100000)));
      });

      test('should list invoices by wallet', () async {
        await storage.storeWallet('inv-list-wallet', 'Invoice List Wallet');

        for (var i = 0; i < 3; i++) {
          final invoice = InvoiceReadModel(
            invoiceId: 'inv-list-$i',
            walletId: 'inv-list-wallet',
            addresses: ['addr$i'],
            amount: BigInt.from(10000 * (i + 1)),
            status: InvoiceStatus.pending,
            createdAt: DateTime.now(),
            lastUpdated: DateTime.now(),
            metadata: {},
          );
          await storage.storeInvoice(invoice);
        }

        final invoices = await storage.getInvoicesByWallet('inv-list-wallet');
        expect(invoices, hasLength(3));
      });

      /// Audit 2026-09-14 S-07: Postgres had no outputs_json column, so the
      /// structured outputs the projection stored were silently dropped.
      test('round-trips a typed InvoiceReadModel with outputs through store, status update and list (audit S-07)',
          () async {
        final suffix = DateTime.now().microsecondsSinceEpoch;
        await runInvoiceRoundTripContract(
          storage,
          invoiceId: 'pg-invoice-contract-$suffix',
          walletId: 'pg-invoice-wallet-$suffix',
        );
      });
    });

    /// Audit 2026-09-14 S-01: ChannelProjection handed the Postgres backend
    /// an Isar PaymentChannelEntity, which it cast to PaymentChannel
    /// (TypeError on every channel event); the ON CONFLICT clause never
    /// updated the server or funding columns; latest_payment_tx_id,
    /// settlement_tx_id and error_message had no columns.
    group('Payment Channel Operations (audit S-01)', () {
      test('projects open -> payment -> settle through ChannelProjection and reads back every field',
          () async {
        final suffix = DateTime.now().microsecondsSinceEpoch;
        await runChannelLifecycleContract(
          storage,
          channelId: 'pg-channel-contract-$suffix',
          walletId: 'pg-channel-wallet-$suffix',
        );
      });

      test('every channel field survives storage and projection updates (32t, y3b)',
          () async {
        final suffix = DateTime.now().microsecondsSinceEpoch;
        await runChannelFullFieldRetentionContract(
          storage,
          channelId: 'pg-channel-retention-$suffix',
          walletId: 'pg-channel-wallet-$suffix',
        );
      });

      test('a claimed refund records its txid in the read model (cqc)',
          () async {
        final suffix = DateTime.now().microsecondsSinceEpoch;
        await runRefundClaimedContract(
          storage,
          channelId: 'pg-channel-refund-$suffix',
          walletId: 'pg-channel-refund-wallet-$suffix',
        );
      });

      test('a lock time past 2038 round-trips (cqc)', () async {
        final suffix = DateTime.now().microsecondsSinceEpoch;
        final walletId = 'pg-channel-locktime-wallet-$suffix';
        try {
          await runPost2038LockTimeContract(
            storage,
            channelId: 'pg-channel-locktime-$suffix',
            walletId: walletId,
          );
        } finally {
          // These rows are the only ones in the shared test database whose
          // lock time does not fit a 32-bit INTEGER, and v022's `down`
          // narrows the column back. Leaving them behind would make every
          // later rollback test in the suite fail, so drop them here.
          final pool = await config.createPool();
          try {
            await pool.execute(
              Sql.named(
                  'DELETE FROM payment_channels WHERE wallet_id = @walletId'),
              parameters: {'walletId': walletId},
            );
          } finally {
            await pool.close();
          }
        }
      });

      test('a requested channel reads back with a null server key (y3b)',
          () async {
        final suffix = DateTime.now().microsecondsSinceEpoch;
        await runRequestedChannelServerKeyContract(
          storage,
          channelId: 'pg-channel-server-key-$suffix',
          walletId: 'pg-channel-wallet-$suffix',
        );
      });

      test('a legacy empty server key reads back as null (y3b)', () async {
        final suffix = DateTime.now().microsecondsSinceEpoch;
        final channelId = 'pg-channel-legacy-key-$suffix';
        await runChannelLifecycleContract(
          storage,
          channelId: channelId,
          walletId: 'pg-channel-wallet-$suffix',
        );
        // Rows written before y3b hold '' for a channel without a server key.
        final pool = await config.createPool();
        try {
          await pool.execute(
            Sql.named("UPDATE payment_channels SET server_pub_key_hex = '' "
                'WHERE channel_id = @id'),
            parameters: {'id': channelId},
          );
        } finally {
          await pool.close();
        }

        final channel = await storage.getPaymentChannel(channelId);
        expect(channel!.serverPubKeyHex, isNull);
      });

      test('stores a failed channel with an error message and reads it back',
          () async {
        final suffix = DateTime.now().microsecondsSinceEpoch;
        final channelId = 'pg-channel-failed-$suffix';
        await storage.storePaymentChannel(PaymentChannel(
          channelId: channelId,
          walletId: 'pg-channel-wallet-$suffix',
          role: PaymentChannelRole.server,
          clientPeerId: 'c',
          serverPeerId: 's',
          clientPubKeyHex: contractClientPubKeyHex,
          serverPubKeyHex: contractServerPubKeyHex,
          fundingAmountSats: BigInt.from(5000),
          lockTimeUnix: contractLockTimeUnix,
          state: PaymentChannelState.failed,
          errorMessage: 'peer rejected: insufficient funds',
        ));
        final channel = await storage.getPaymentChannel(channelId);
        expect(channel, isNotNull);
        expect(channel!.state, equals(PaymentChannelState.failed));
        expect(channel.errorMessage, equals('peer rejected: insufficient funds'));
        expect(channel.fundingTxId, isNull);
        expect(channel.clientAddressB58, isNull);
        expect(channel.role, equals(PaymentChannelRole.server));
      });
    });
    /// Audit 2026-09-14 S-15, S-16, S-19, S-20: the wallet lifecycle,
    /// ordering, round-trip and retention contract shared with the in-memory
    /// and Isar backends.
    group('lifecycle', () {
      final run = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
      var counter = 0;
      defineWalletLifecycleContract(
        () => storage,
        unique: () => 'pl$run${counter++}',
      );

      test('S-20 / p8qc: upsertUTXO records spent_at and is_available and keeps the spend history',
          () async {
        final wallet = 'pg-spent-cols-$run';
        final txid = contractHex64('pg-spent-cols-$run');
        final created = DateTime.utc(2026, 9, 1);
        final firstSpend = DateTime.utc(2026, 9, 2);
        final base = BitcoinUtxo(
          txid: txid,
          vout: 0,
          value: dartsv.Coin.ofSat(BigInt.from(1000)),
          scriptPubKey: '76a914000000000000000000000000000000000000000088ac',
          address: 'mkHS9ne12qx9pS9VojpwU5xtRd4T7X7ZUt',
          status: UTXOStatus.available,
          createdAt: created,
          updatedAt: created,
        );
        final pool = await config.createPool();
        Future<List<Object?>> columns() async {
          final rows = await pool.execute(
            Sql.named('SELECT spent_at, is_available, spent_in_tx_id FROM bitcoin_utxos '
                'WHERE wallet_id = @w AND txid = @t AND vout = 0'),
            parameters: {'w': wallet, 't': txid},
          );
          return rows.single.toList();
        }

        try {
          // Bead libspiffy-p8qc: the column holds `status = available` and
          // is named after it. It was `is_spendable`, the name of
          // `WalletBalances.isSpendable` — a rule over the whole wallet
          // state that no per-row column can hold, so a plugin-managed or
          // watch-only row was stored as spendable. Migration v024 renames
          // it; nothing may re-introduce the promise.
          final columnNames = await pool.execute(
            Sql.named("SELECT column_name FROM information_schema.columns "
                "WHERE table_name = 'bitcoin_utxos'"),
          );
          final names = columnNames.map((r) => r[0] as String).toSet();
          expect(names, contains('is_available'));
          expect(names, isNot(contains('is_spendable')));

          await storage.upsertUTXO(wallet, base.copyWith(status: UTXOStatus.reserved));
          expect(await columns(), [null, false, null],
              reason: 'a reserved UTXO is not spendable');

          await storage.upsertUTXO(
              wallet, base.copyWith(status: UTXOStatus.spent, updatedAt: firstSpend));
          var cols = await columns();
          expect((cols[0] as DateTime?)?.toUtc(), firstSpend,
              reason: 'spent_at must record the spend time');
          expect(cols[1], isFalse);

          // The domain model carries no spending txid; a value recorded in
          // the row (by SQL here) must not be overwritten with NULL.
          await pool.execute(
            Sql.named('UPDATE bitcoin_utxos SET spent_in_tx_id = @s '
                'WHERE wallet_id = @w AND txid = @t AND vout = 0'),
            parameters: {'s': 'ab' * 32, 'w': wallet, 't': txid},
          );

          // A later update of the spent row keeps the first spend time and
          // the spending txid.
          await storage.upsertUTXO(wallet,
              base.copyWith(status: UTXOStatus.spent, updatedAt: DateTime.utc(2026, 9, 5)));
          cols = await columns();
          expect((cols[0] as DateTime?)?.toUtc(), firstSpend);
          expect(cols[2], 'ab' * 32,
              reason: 'spent_in_tx_id is spend history and must not be overwritten');

          // Even a direct caller storing the row as available again does not
          // erase the spend history; only is_available follows the status.
          await storage.upsertUTXO(wallet, base);
          cols = await columns();
          expect((cols[0] as DateTime?)?.toUtc(), firstSpend);
          expect(cols[1], isTrue);
          expect(cols[2], 'ab' * 32);
        } finally {
          await pool.close();
        }
      });

      test('S-19: v006 creates the (wallet_id, created_at DESC) list indexes',
          () async {
        final pool = await config.createPool();
        try {
          final rows = await pool.execute(
            "SELECT indexname, indexdef FROM pg_indexes WHERE schemaname = current_schema()",
          );
          final defs = {for (final r in rows) r[0] as String: r[1] as String};
          const expected = {
            'idx_transactions_wallet_created': 'bitcoin_transactions',
            'idx_utxos_wallet_created': 'bitcoin_utxos',
            'idx_addresses_wallet_created': 'addresses',
            'idx_tx_addr_wallet_address_created': 'transaction_addresses',
            'idx_invoices_wallet_created': 'invoices',
            'idx_channels_wallet_created': 'payment_channels',
            'idx_wallet_metadata_created': 'wallet_metadata',
          };
          for (final entry in expected.entries) {
            expect(defs.keys, contains(entry.key));
            expect(defs[entry.key], contains('${entry.value} USING'));
            expect(defs[entry.key], contains('created_at DESC'));
          }
        } finally {
          await pool.close();
        }
      });
    });

    /// Audit 2026-09-14 S-05, S-12, S-13, S-17, S-18 and bead
    /// libspiffy-0v3: the keying contract shared with the in-memory and
    /// Isar backends.
    group('keying contract', () {
      final run = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
      var counter = 0;
      // Header rows are global: clear them before each header test and
      // leave none behind for the next schema reset.
      tearDownAll(() => clearBlockHeaders(config));
      defineReadModelKeyingContract(
        () => storage,
        unique: () => 'p$run${counter++}',
        beforeHeaders: () => clearBlockHeaders(config),
      );

      test('0v3: BlockHeaderChain reorg A -> B -> A persists branch A across a restart',
          () async {
        await clearBlockHeaders(config);
        await runReorgBackOntoOrphanedBranchContract(storage);
      });
    });
  });

  group('PostgreSQL Connection Pooling', () {
    test('should handle concurrent operations', () async {
      final storage = PostgresWalletStorage(config);
      await storage.initialize();

      // Create test wallet
      await storage.storeWallet('concurrent-test', 'Concurrent Test');

      // Run multiple operations concurrently
      final futures = List.generate(10, (i) async {
        final utxo = BitcoinUtxo(
          txid: 'concurrent$i${'0' * 53}',
          vout: 0,
          value: dartsv.Coin.ofSat(BigInt.from(1000 * (i + 1))),
          scriptPubKey: '76a914...88ac',
          address: 'addr$i',
          status: UTXOStatus.available,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );
        await storage.upsertUTXO('concurrent-test', utxo);
      });

      await Future.wait(futures);

      final utxos = await storage.getUTXOs('concurrent-test');
      expect(utxos, hasLength(10));

      await storage.close();
    });
  });
}
