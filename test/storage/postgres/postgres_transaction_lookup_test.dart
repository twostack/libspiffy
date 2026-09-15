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
import '../transaction_status_contract.dart';

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
    defineTransactionStatusContract(() => storage, unique: () => 'ps$run-${counter++}',
        storedCounterparty: (walletId, txid) async {
      final pool = await config.createPool();
      try {
        final rows = await pool.execute(
            Sql.named('SELECT primary_counterparty, counterparty FROM bitcoin_transactions '
                'WHERE wallet_id = @walletId AND txid = @txid'),
            parameters: {'walletId': walletId, 'txid': txid});
        if (rows.isEmpty) return null;
        return (primaryCounterparty: rows.single[0] as String?, counterparty: rows.single[1] as String?);
      } finally {
        await pool.close();
      }
    });

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

  test('v015 recomputes the counterparty columns of rows stored with the earlier rule (7dj)', () async {
    final migrations = PostgresMigrations(config);
    await migrations.migrate();
    final storage = PostgresWalletStorage(config);
    await storage.initialize();
    final pool = await config.createPool();
    final walletId = 'w-cp-migration-$run';
    BitcoinTransaction row(String txid, int net, List<String> receiving, List<String> sending) => BitcoinTransaction(
          txid: txid,
          rawHex: '0100000000000000000000',
          status: TransactionStatus.pending,
          inputValue: BigInt.from(5000),
          outputValue: BigInt.from(4800),
          fee: BigInt.from(200),
          receivingAddresses: receiving,
          sendingAddresses: sending,
          netAmount: BigInt.from(net),
          createdAt: DateTime.utc(2026, 9, 15),
          updatedAt: DateTime.utc(2026, 9, 15),
          lockTime: 0,
          version: 1,
        );
    final incoming = contractHex64('cp-mig-in-$run');
    final outgoing = contractHex64('cp-mig-out-$run');
    final self = contractHex64('cp-mig-self-$run');
    Future<(String?, String?)> columns(String txid) async {
      final r = await pool.execute(
          Sql.named('SELECT primary_counterparty, counterparty FROM bitcoin_transactions '
              'WHERE wallet_id = @w AND txid = @t'),
          parameters: {'w': walletId, 't': txid});
      return (r.single[0] as String?, r.single[1] as String?);
    }

    try {
      await storage.storeTransaction(walletId, row(incoming, 3000, ['ours-1', 'ours-2'], ['sender-1', 'sender-2']));
      await storage.storeTransaction(walletId, row(outgoing, -2200, ['payee-1', 'payee-2'], ['ours-3']));
      await storage.storeTransaction(walletId, row(self, 0, ['ours-5'], ['ours-1']));
      // As the earlier rule stored them: the first receiving address, no
      // counterparty.
      await pool.execute(
          Sql.named('UPDATE bitcoin_transactions SET primary_counterparty = receiving_addresses->>0, '
              'counterparty = NULL WHERE wallet_id = @w'),
          parameters: {'w': walletId});
      expect(await columns(incoming), ('ours-1', null));

      while (await migrations.getCurrentVersion() >= 15) {
        await migrations.rollback();
      }
      await migrations.migrate();

      expect(await columns(incoming), ('sender-1', 'sender-1'));
      expect(await columns(outgoing), ('payee-1', 'payee-1'));
      expect(await columns(self), (null, null));
      final stored = (await storage.getTransaction(incoming, walletId: walletId))!;
      expect(stored.receivingAddresses, ['ours-1', 'ours-2'], reason: 'the addresses the columns derive from are unchanged');
      expect(stored.sendingAddresses, ['sender-1', 'sender-2']);
    } finally {
      await pool.close();
      await storage.close();
    }
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
