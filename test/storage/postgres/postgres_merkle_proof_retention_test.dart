/// Bead libspiffy-mny on PostgreSQL: the retention contract and migration
/// v009 (proof status; one current proof per txid instead of one row), and
/// bead libspiffy-azl: migration v012 (the rejected status).
@Tags(['postgres', 'integration'])
library;

import 'dart:io';

import 'package:postgres/postgres.dart' show Sql, ServerException;
import 'package:test/test.dart';

import 'package:libspiffy/src/storage/postgres/postgres_config.dart';
import 'package:libspiffy/src/storage/postgres/postgres_migrations.dart';
import 'package:libspiffy/src/storage/postgres/postgres_wallet_storage.dart';
import 'package:libspiffy/src/storage/read_model_storage.dart';

import '../ancestor_transaction_contract.dart';
import '../merkle_proof_retention_contract.dart';

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

    defineMerkleProofRetentionContract(() => storage, unique: () => 'p$run-${counter++}');
    defineAncestorTransactionContract(() => storage, unique: () => 'p$run-${counter++}');
  });

  test('v009 turns pending placeholders into pendingHeader, keeps orphaned rows, and rolls back', () async {
    final migrations = PostgresMigrations(config);
    await migrations.migrate();
    final pool = await config.createPool();
    final storage = PostgresWalletStorage(config);
    await storage.initialize();
    String hex64(String tag) => (tag.codeUnits.fold<int>(run, (h, c) => (h * 31 + c) & 0x7fffffff))
        .toRadixString(16)
        .padLeft(64, '0');
    final pendingTx = hex64('v009-pending');
    final verifiedTx = hex64('v009-verified');
    final orphanOnlyTx = hex64('v009-orphan-only');
    final blockA = hex64('v009-block-a');
    final blockB = hex64('v009-block-b');
    final txids = [pendingTx, verifiedTx, orphanOnlyTx];

    Future<void> insertV007Row(String txid, String blockHash, String proof) => pool.execute(
          Sql.named('''
            INSERT INTO merkle_proofs (txid, block_hash, block_height, position, merkle_proof_json, created_at)
            VALUES (@txid, @blockHash, 7, 0, @proof, NOW())
          '''),
          parameters: {'txid': txid, 'blockHash': blockHash, 'proof': proof},
        );
    Future<List<List<Object?>>> rawRows(String txid, String columns) async => [
          for (final row in await pool.execute(
            Sql.named('SELECT $columns FROM merkle_proofs WHERE txid = @txid ORDER BY id'),
            parameters: {'txid': txid},
          ))
            row.toList(),
        ];

    try {
      // --- the pre-v009 shape, with a 'pending' placeholder row ----------
      expect(await migrations.rollback(), isTrue); // v016
      expect(await migrations.rollback(), isTrue); // v015
      expect(await migrations.rollback(), isTrue); // v014
      expect(await migrations.rollback(), isTrue); // v013
      expect(await migrations.rollback(), isTrue); // v012
      expect(await migrations.rollback(), isTrue); // v011
      expect(await migrations.rollback(), isTrue); // v010
      expect(await migrations.rollback(), isTrue); // v009
      expect(await migrations.getCurrentVersion(), equals(8));
      await pool.execute(
        Sql.named('DELETE FROM merkle_proofs WHERE txid IN (@a, @b, @c)'),
        parameters: {'a': txids[0], 'b': txids[1], 'c': txids[2]},
      );
      await insertV007Row(pendingTx, 'pending', 'fe01');
      await insertV007Row(verifiedTx, blockA, 'fe02');
      await insertV007Row(orphanOnlyTx, blockA, 'fe03');

      // --- up -------------------------------------------------------------
      await migrations.migrate();
      expect(await migrations.getCurrentVersion(), equals(16));
      expect(await rawRows(pendingTx, 'block_hash, status'), [
        [null, 'pendingHeader']
      ]);
      expect(await rawRows(verifiedTx, 'block_hash, status'), [
        [blockA, 'verified']
      ]);
      final pending = (await storage.getMerkleProof(pendingTx))!;
      expect((pending.blockHash, pending.status), (null, MerkleProofStatus.pendingHeader));
      expect([for (final p in await storage.getMerkleProofsByStatus(MerkleProofStatus.pendingHeader)) p.txid],
          contains(pendingTx));

      // A reorganization: verifiedTx re-mined in block B, orphanOnlyTx not.
      expect(await storage.markMerkleProofOrphaned(verifiedTx, blockHash: blockA), isTrue);
      await storage.storeMerkleProof(verifiedTx, MerkleProof(
          txid: verifiedTx, blockHash: blockB, blockHeight: 8, position: 0, merkleProof: ['fe04']));
      expect(await storage.markMerkleProofOrphaned(orphanOnlyTx), isTrue);
      expect(await rawRows(verifiedTx, 'block_hash, status'), [
        [blockA, 'orphaned'],
        [blockB, 'verified'],
      ]);

      // The database enforces the rules itself.
      Future<void> expectRejected(String txid, String? blockHash, String status, String proof) async {
        await expectLater(
          pool.execute(
            Sql.named('''
              INSERT INTO merkle_proofs (txid, block_hash, block_height, position, merkle_proof_json,
                                         created_at, status)
              VALUES (@txid, @blockHash, 9, 0, @proof, NOW(), @status)
            '''),
            parameters: {'txid': txid, 'blockHash': blockHash, 'status': status, 'proof': proof},
          ),
          throwsA(isA<ServerException>()),
        );
      }

      await expectRejected(verifiedTx, hex64('v009-block-c'), 'verified', 'fe05'); // second current
      await expectRejected(verifiedTx, blockA, 'orphaned', 'fe06'); // same (txid, block)
      await expectRejected(pendingTx, null, 'orphaned', 'fe01'); // same unhashed proof
      await expectRejected(orphanOnlyTx, null, 'bogus', 'fe07'); // unknown status

      // --- down -----------------------------------------------------------
      expect(await migrations.rollback(), isTrue); // v016
      expect(await migrations.rollback(), isTrue); // v015
      expect(await migrations.rollback(), isTrue); // v014
      expect(await migrations.rollback(), isTrue); // v013
      expect(await migrations.rollback(), isTrue); // v012
      expect(await migrations.rollback(), isTrue); // v011
      expect(await migrations.rollback(), isTrue); // v010
      expect(await migrations.rollback(), isTrue); // v009
      expect(await migrations.getCurrentVersion(), equals(8));
      expect(await rawRows(pendingTx, 'block_hash'), [
        ['pending']
      ]);
      expect(await rawRows(verifiedTx, 'block_hash, merkle_proof_json'), [
        [blockB, 'fe04']
      ], reason: 'down keeps the current proof and drops the orphaned one');
      expect(await rawRows(orphanOnlyTx, 'block_hash'), isEmpty,
          reason: 'the pre-v009 model has no orphaned proofs');
      await expectLater(insertV007Row(verifiedTx, blockA, 'fe08'), throwsA(isA<ServerException>()),
          reason: 'uk_merkle_proofs_txid is restored');

      // --- up again, leaving the database at the latest version ----------
      await migrations.migrate();
      expect(await migrations.getCurrentVersion(), equals(16));
      expect((await storage.getMerkleProof(pendingTx))!.status, MerkleProofStatus.pendingHeader);
    } finally {
      await migrations.migrate();
      // Test rows only; the storage API itself never deletes proofs.
      await pool.execute(
        Sql.named('DELETE FROM merkle_proofs WHERE txid IN (@a, @b, @c)'),
        parameters: {'a': txids[0], 'b': txids[1], 'c': txids[2]},
      );
      await storage.close();
      await pool.close();
    }
  });

  test('v012 admits rejected rows next to the current proof, and rolls them back to orphaned', () async {
    final migrations = PostgresMigrations(config);
    await migrations.migrate();
    final pool = await config.createPool();
    final storage = PostgresWalletStorage(config);
    await storage.initialize();
    String hex64(String tag) => (tag.codeUnits.fold<int>(run, (h, c) => (h * 31 + c) & 0x7fffffff))
        .toRadixString(16)
        .padLeft(64, '0');
    final txid = hex64('v012-tx');
    final block = hex64('v012-block');
    Future<List<List<Object?>>> rawRows(String columns) async => [
          for (final row in await pool.execute(
            Sql.named('SELECT $columns FROM merkle_proofs WHERE txid = @txid ORDER BY id'),
            parameters: {'txid': txid},
          ))
            row.toList(),
        ];
    Future<void> insert(String? blockHash, String status, String proof) => pool.execute(
          Sql.named('''
            INSERT INTO merkle_proofs (txid, block_hash, block_height, position, merkle_proof_json,
                                       created_at, status)
            VALUES (@txid, @blockHash, 9, 0, @proof, NOW(), @status)
          '''),
          parameters: {'txid': txid, 'blockHash': blockHash, 'status': status, 'proof': proof},
        );

    try {
      expect(await migrations.getCurrentVersion(), equals(16));
      await storage.storeMerkleProof(txid, MerkleProof(
          txid: txid, blockHash: block, blockHeight: 9, position: 0, merkleProof: ['fe12']));
      await storage.storeMerkleProof(txid, MerkleProof(
          txid: txid,
          blockHash: null,
          blockHeight: 9,
          position: 0,
          merkleProof: ['fe13'],
          status: MerkleProofStatus.rejected));
      expect(await rawRows('block_hash, status, merkle_proof_json'), [
        [block, 'verified', 'fe12'],
        [null, 'rejected', 'fe13'],
      ]);
      expect((await storage.getMerkleProof(txid))!.merkleProof, ['fe12']);

      // The database itself: several rejected rows beside one current row,
      // still one current row only.
      await insert(null, 'rejected', 'fe14');
      await expectLater(insert(null, 'pendingHeader', 'fe15'), throwsA(isA<ServerException>()),
          reason: 'a second current proof');
      await expectLater(insert(null, 'bogus', 'fe16'), throwsA(isA<ServerException>()));

      // --- down: rejected rows become orphaned, none is deleted ----------
      expect(await migrations.rollback(), isTrue); // v016
      expect(await migrations.rollback(), isTrue); // v015
      expect(await migrations.rollback(), isTrue); // v014
      expect(await migrations.rollback(), isTrue); // v013
      expect(await migrations.rollback(), isTrue); // v012
      expect(await migrations.getCurrentVersion(), equals(11));
      expect(await rawRows('block_hash, status, merkle_proof_json'), [
        [block, 'verified', 'fe12'],
        [null, 'orphaned', 'fe13'],
        [null, 'orphaned', 'fe14'],
      ]);
      await expectLater(insert(null, 'rejected', 'fe17'), throwsA(isA<ServerException>()),
          reason: 'v011 has no rejected status');

      // --- up again ------------------------------------------------------
      await migrations.migrate();
      expect(await migrations.getCurrentVersion(), equals(16));
      await insert(null, 'rejected', 'fe18');
      expect((await storage.getMerkleProof(txid))!.merkleProof, ['fe12']);
    } finally {
      await migrations.migrate();
      // Test rows only; the storage API itself never deletes proofs.
      await pool.execute(Sql.named('DELETE FROM merkle_proofs WHERE txid = @txid'), parameters: {'txid': txid});
      await storage.close();
      await pool.close();
    }
  });

  test('v016 (hg0) indexes proofs by (status, block height), replacing the status index, and rolls back', () async {
    final migrations = PostgresMigrations(config);
    await migrations.migrate();
    final pool = await config.createPool();
    Future<List<String>> indexes() async => [
          for (final row in await pool.execute(
              "SELECT indexname FROM pg_indexes WHERE schemaname = current_schema() "
              "AND indexname IN ('idx_merkle_proofs_status', 'idx_merkle_proofs_status_height') ORDER BY indexname"))
            row[0] as String,
        ];
    try {
      expect(await migrations.getCurrentVersion(), equals(16));
      expect(await indexes(), ['idx_merkle_proofs_status_height']);
      expect(await migrations.rollback(), isTrue); // v016
      expect(await indexes(), ['idx_merkle_proofs_status']);
      await migrations.migrate();
      expect(await indexes(), ['idx_merkle_proofs_status_height']);
    } finally {
      await migrations.migrate();
      await pool.close();
    }
  });
}
