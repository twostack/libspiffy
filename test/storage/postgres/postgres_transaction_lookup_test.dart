/// Bead libspiffy-ctkm on PostgreSQL: the transaction lookup contract, the
/// indexes serving it (v005 txid index, v014 confirmed-height index) and
/// migration v014.
@Tags(['postgres', 'integration'])
library;

import 'dart:io';

import 'package:postgres/postgres.dart' show Sql;
import 'package:test/test.dart';

import 'package:libspiffy/src/models/bitcoin_transaction.dart';
import 'package:libspiffy/src/storage/postgres/postgres_config.dart';
import 'package:libspiffy/src/storage/postgres/postgres_migrations.dart';
import 'package:libspiffy/src/storage/postgres/postgres_wallet_storage.dart';

import '../read_model_keying_contract.dart' show contractHex64;
import '../transaction_lookup_contract.dart';

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

    defineTransactionLookupContract(() => storage, unique: () => 'p$run-${counter++}');

    /// The plan of the last lookup query [body] ran, with sequential scans
    /// forbidden (a small table is always cheaper to scan).
    Future<String> planOf(Future<void> Function() body) async {
      String? sql;
      Map<String, dynamic>? parameters;
      storage.onTransactionLookupQuery = (s, p) {
        sql = s;
        parameters = p;
      };
      await body();
      expect(sql, isNotNull);
      final pool = await config.createPool();
      try {
        return await pool.runTx((session) async {
          await session.execute('SET LOCAL enable_seqscan = off');
          final rows = await session.execute(Sql.named('EXPLAIN $sql'), parameters: parameters);
          return rows.map((r) => r[0].toString()).join('\n');
        });
      } finally {
        await pool.close();
      }
    }

    BitcoinTransaction tx(String txid, int? height) => BitcoinTransaction(
          txid: txid,
          rawHex: '0100000000000000000000',
          status: TransactionStatus.confirmed,
          blockHeight: height,
          confirmations: 1,
          inputValue: BigInt.from(2000),
          outputValue: BigInt.from(1800),
          fee: BigInt.from(200),
          receivingAddresses: const [],
          sendingAddresses: const [],
          netAmount: BigInt.from(1800),
          createdAt: DateTime.utc(2026, 9, 15),
          updatedAt: DateTime.utc(2026, 9, 15),
          lockTime: 0,
          version: 1,
        );

    test('confirmed rows from a height are read through the v014 index, not by scanning the table', () async {
      final walletId = 'w-plan-height-$run';
      for (var i = 0; i < 20; i++) {
        await storage.storeTransaction(walletId, tx(contractHex64('plan-h$i-$run'), 100 + i));
      }

      final withHeight = await planOf(() => storage.getConfirmedTransactionsFromHeight(115));
      expect(withHeight, contains('idx_transactions_confirmed_height'), reason: withHeight);
      expect(withHeight, isNot(contains('Seq Scan')), reason: withHeight);

      final withoutHeight =
          await planOf(() => storage.getConfirmedTransactionsFromHeight(115, includeWithoutHeight: true));
      expect(withoutHeight, contains('idx_transactions_confirmed_height'), reason: withoutHeight);
      expect(withoutHeight, isNot(contains('Seq Scan')), reason: withoutHeight);
    });

    test('rows by txid are read through the txid index', () async {
      final walletId = 'w-plan-txid-$run';
      final txids = [for (var i = 0; i < 3; i++) contractHex64('plan-t$i-$run')];
      for (final txid in txids) {
        await storage.storeTransaction(walletId, tx(txid, 5));
      }

      final plan = await planOf(() => storage.getTransactionsByTxids(txids));
      expect(plan, contains('idx_transactions_txid'), reason: plan);
      expect(plan, isNot(contains('Seq Scan')), reason: plan);
    });
  });

  test('v014 rolls back and re-applies', () async {
    final migrations = PostgresMigrations(config);
    await migrations.migrate();
    expect(await migrations.getCurrentVersion(), greaterThanOrEqualTo(14));
    final pool = await config.createPool();
    Future<bool> indexExists() async => (await pool.execute(
            "SELECT 1 FROM pg_indexes WHERE schemaname = current_schema() "
            "AND indexname = 'idx_transactions_confirmed_height'"))
        .isNotEmpty;
    try {
      expect(await indexExists(), isTrue);
      while (await migrations.getCurrentVersion() >= 14) {
        await migrations.rollback();
      }
      expect(await migrations.getCurrentVersion(), 13);
      expect(await indexExists(), isFalse);
      await migrations.migrate();
      expect(await indexExists(), isTrue);
    } finally {
      await pool.close();
    }
  });
}
