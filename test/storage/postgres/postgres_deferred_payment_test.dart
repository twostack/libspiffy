/// Bead libspiffy-7p2 on PostgreSQL: the deferred-payment read model
/// contract and migration v013 (table and listing index).
@Tags(['postgres', 'integration'])
library;

import 'dart:io';

import 'package:postgres/postgres.dart' show Sql;
import 'package:test/test.dart';

import 'package:libspiffy/src/storage/postgres/postgres_config.dart';
import 'package:libspiffy/src/storage/postgres/postgres_migrations.dart';
import 'package:libspiffy/src/storage/postgres/postgres_wallet_storage.dart';
import 'package:libspiffy/src/storage/read_model_storage.dart';

import '../deferred_payment_contract.dart';

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

    defineDeferredPaymentContract(() => storage, unique: () => 'p$run-${counter++}');

    test('the outstanding-only listing is served by the v013 index with a LIMIT, not a table scan', () async {
      final walletId = 'w-plan-$run';
      for (var i = 0; i < 30; i++) {
        await storage.storeDeferredPayment(contractDeferredPayment(
          walletId: walletId,
          txid: contractTxid('plan$i-$run'),
          minutesAfterBase: i,
          state: i < 3 ? DeferredPaymentState.outstanding : DeferredPaymentState.mined,
        ));
      }
      String? sql;
      Map<String, dynamic>? parameters;
      storage.onDeferredPaymentQuery = (s, p) {
        sql = s;
        parameters = p;
      };
      final page = await storage.listDeferredPayments(walletId, query: const DeferredPaymentQuery(limit: 2));
      expect(page.payments, hasLength(2));
      expect(sql, contains('LIMIT 3'));

      final pool = await config.createPool();
      try {
        final plan = await pool.runTx((session) async {
          // A tiny table is always cheaper to scan; forbid that to see which
          // index can serve the query.
          await session.execute('SET LOCAL enable_seqscan = off');
          final rows = await session.execute(Sql.named('EXPLAIN $sql'), parameters: parameters);
          return rows.map((r) => r[0].toString()).join('\n');
        });
        expect(plan, contains('ix_deferred_payments_wallet_state_created'), reason: plan);
        expect(plan, contains('Limit'), reason: plan);
        expect(plan, isNot(contains('Sort')), reason: 'the index order is the page order:\n$plan');
      } finally {
        await pool.close();
      }
    });
  });

  test('v013 rolls back and re-applies', () async {
    final migrations = PostgresMigrations(config);
    await migrations.migrate();
    expect(await migrations.getCurrentVersion(), greaterThanOrEqualTo(13));
    final pool = await config.createPool();
    Future<bool> tableExists() async => (await pool.execute(
            "SELECT 1 FROM information_schema.tables WHERE table_name = 'deferred_payments'"))
        .isNotEmpty;
    try {
      expect(await tableExists(), isTrue);
      while (await migrations.getCurrentVersion() >= 13) {
        await migrations.rollback();
      }
      expect(await tableExists(), isFalse);
      await migrations.migrate();
      expect(await tableExists(), isTrue);
    } finally {
      await pool.close();
    }
  });
}
