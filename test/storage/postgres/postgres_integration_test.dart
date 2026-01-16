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

import 'dart:io';

import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:test/test.dart';

import 'package:libspiffy/src/storage/postgres/postgres_config.dart';
import 'package:libspiffy/src/storage/postgres/postgres_event_store.dart';
import 'package:libspiffy/src/storage/postgres/postgres_wallet_storage.dart';
import 'package:libspiffy/src/storage/postgres/postgres_migrations.dart';
import 'package:libspiffy/src/models/bitcoin_utxo.dart';
import 'package:libspiffy/src/models/bitcoin_transaction.dart';
import 'package:libspiffy/src/models/address_metadata.dart';
import 'package:libspiffy/src/models/invoice_read_model.dart';
import 'package:libspiffy/src/actors/invoice_messages.dart' show InvoiceStatus;

/// Get PostgreSQL configuration from environment or use defaults
PostgresConfig getTestConfig() {
  return PostgresConfig(
    host: Platform.environment['POSTGRES_HOST'] ?? 'localhost',
    port: int.tryParse(Platform.environment['POSTGRES_PORT'] ?? '5432') ?? 5432,
    database: Platform.environment['POSTGRES_DATABASE'] ?? 'libspiffy_test',
    username: Platform.environment['POSTGRES_USER'] ?? 'postgres',
    password: Platform.environment['POSTGRES_PASSWORD'] ?? 'postgres',
    maxConnections: 5,
  );
}

void main() {
  final config = getTestConfig();

  group('PostgreSQL Migrations', () {
    test('should run migrations successfully', () async {
      final migrations = PostgresMigrations(config);

      // Reset to clean state
      await migrations.reset();

      // Run migrations
      await migrations.migrate();

      // Verify version
      final version = await migrations.getCurrentVersion();
      expect(version, equals(1));

      // Verify applied migrations
      final applied = await migrations.getAppliedMigrations();
      expect(applied, hasLength(1));
      expect(applied.first.name, equals('initial_schema'));
    });

    test('should handle re-running migrations idempotently', () async {
      final migrations = PostgresMigrations(config);

      // Run twice - should not fail
      await migrations.migrate();
      await migrations.migrate();

      final version = await migrations.getCurrentVersion();
      expect(version, equals(1));
    });

    test('should rollback migrations', () async {
      final migrations = PostgresMigrations(config);

      await migrations.migrate();
      expect(await migrations.getCurrentVersion(), equals(1));

      final didRollback = await migrations.rollback();
      expect(didRollback, isTrue);
      expect(await migrations.getCurrentVersion(), equals(0));
    });
  });

  group('PostgresEventStore', () {
    late PostgresEventStore eventStore;

    setUpAll(() async {
      // Ensure migrations are run
      final migrations = PostgresMigrations(config);
      await migrations.migrate();
    });

    setUp(() async {
      eventStore = PostgresEventStore(config);
      await eventStore.initialize();
    });

    tearDown(() async {
      await eventStore.close();
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
        expect(retrieved.invoiceId, equals('inv-001'));
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
