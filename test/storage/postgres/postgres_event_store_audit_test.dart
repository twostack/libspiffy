/// Audit regression tests for the Postgres event store, migrations and
/// secure storage (audit S-09, S-10, S-11, S-22, S-23, S-21, KM-9).
///
/// Requires the local PostgreSQL server; the database comes from
/// POSTGRES_DATABASE (see postgres_integration_test.dart for the settings).
@Tags(['postgres', 'integration'])
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:eventador/eventador.dart';
import 'package:postgres/postgres.dart';
import 'package:test/test.dart';

import 'package:libspiffy/src/crypto/encryption_service.dart';
import 'package:libspiffy/src/storage/postgres/postgres_config.dart';
import 'package:libspiffy/src/storage/postgres/postgres_event_store.dart';
import 'package:libspiffy/src/storage/postgres/postgres_migrations.dart';
import 'package:libspiffy/src/storage/postgres/postgres_secure_storage.dart';
import 'package:libspiffy/src/storage/secure_storage.dart';

PostgresConfig _testConfig() => PostgresConfig(
      host: Platform.environment['POSTGRES_HOST'] ?? 'localhost',
      port:
          int.tryParse(Platform.environment['POSTGRES_PORT'] ?? '5432') ?? 5432,
      database: Platform.environment['POSTGRES_DATABASE'] ?? 'libspiffy_test',
      username: Platform.environment['POSTGRES_USER'] ?? 'postgres',
      password: Platform.environment['POSTGRES_PASSWORD'] ?? 'postgres',
      // The local test server has no SSL.
      enableSsl: false,
      maxConnections: 5,
    );

class AuditEvent extends Event {
  final String data;

  AuditEvent(this.data, {super.eventId, super.timestamp});

  @override
  Map<String, dynamic> toMap() => {...super.toMap(), 'data': data};

  static AuditEvent fromMap(Map<String, dynamic> map) => AuditEvent(
        map['data'] as String,
        eventId: map['eventId'] as String,
        timestamp: map['timestamp'] is DateTime
            ? map['timestamp'] as DateTime
            : DateTime.parse(map['timestamp'] as String),
      );
}

/// Carries its tags through the [EventTags] mixin only, never in metadata.
class TaggedAuditEvent extends Event with EventTags {
  final String data;
  final Set<String> tagSet;

  TaggedAuditEvent(this.data, this.tagSet, {super.eventId, super.timestamp});

  @override
  Set<String> get tags => tagSet;

  @override
  Map<String, dynamic> toMap() =>
      {...super.toMap(), 'data': data, 'tagSet': tagSet.toList()};

  static TaggedAuditEvent fromMap(Map<String, dynamic> map) => TaggedAuditEvent(
        map['data'] as String,
        (map['tagSet'] as List).cast<String>().toSet(),
        eventId: map['eventId'] as String,
        timestamp: map['timestamp'] is DateTime
            ? map['timestamp'] as DateTime
            : DateTime.parse(map['timestamp'] as String),
      );
}

String _stamp() => DateTime.now().microsecondsSinceEpoch.toString();

/// Resolves once [otherArrived] holds or another session in this database is
/// waiting on an advisory lock (the fixed code serialises writers that way).
Future<void> _waitForRivalOrLockWaiter(
  Pool admin,
  bool Function() otherArrived,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (!otherArrived()) {
    final r = await admin.execute('''
      SELECT count(*) FROM pg_locks l
      JOIN pg_database d ON d.oid = l.database
      WHERE d.datname = current_database()
        AND l.locktype = 'advisory' AND NOT l.granted
    ''');
    if ((r.first[0] as int) > 0) return;
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('neither rival arrived nor a lock waiter appeared');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

/// Installs symmetric gates on two parties: whichever reaches its gate first
/// parks until the other reaches its gate too (the unserialised race), the
/// other is blocked on an advisory lock (the fix), or the other has already
/// finished (it failed before reaching its gate). Returns the callbacks that
/// mark each party finished.
(void Function(), void Function()) _installRaceGates(
  Pool admin,
  void Function(Future<void> Function() gate) setA,
  void Function(Future<void> Function() gate) setB,
) {
  var aArrived = false;
  var bArrived = false;
  var aDone = false;
  var bDone = false;
  setA(() async {
    aArrived = true;
    if (!bArrived) {
      await _waitForRivalOrLockWaiter(admin, () => bArrived || bDone);
    }
  });
  setB(() async {
    bArrived = true;
    if (!aArrived) {
      await _waitForRivalOrLockWaiter(admin, () => aArrived || aDone);
    }
  });
  return (() => aDone = true, () => bDone = true);
}

Future<void> _clearBlockHeaders(Pool admin) async {
  try {
    await admin.execute('DELETE FROM block_headers');
  } catch (_) {}
}

void main() {
  final config = _testConfig();
  late Pool admin;

  setUpAll(() async {
    admin = await config.createPool();
    await PostgresMigrations(config).migrate();
    EventRegistry.register<AuditEvent>('AuditEvent', AuditEvent.fromMap);
    EventRegistry.register<TaggedAuditEvent>(
        'TaggedAuditEvent', TaggedAuditEvent.fromMap);
  });

  tearDownAll(() async {
    // Leave the schema fully migrated for the other suites.
    await PostgresMigrations(config).migrate();
    await admin.close();
  });

  group('PostgresEventStore concurrency (audit S-09)', () {
    late PostgresEventStore a;
    late PostgresEventStore b;

    setUp(() async {
      a = PostgresEventStore(config);
      b = PostgresEventStore(config);
      await a.initialize();
      await b.initialize();
    });

    tearDown(() async {
      await a.close();
      await b.close();
    });

    Future<List<Object?>> outcomes(List<Future<void>> writes) =>
        Future.wait(writes.map((f) => f.then<Object?>((_) => null,
            onError: (Object e) => e)));

    test(
        'two persistEvent calls with the same expectedVersion: one wins, '
        'the other gets ConcurrencyException', () async {
      final pid = 's09-single-${_stamp()}';
      final (aDone, bDone) = _installRaceGates(admin,
          (g) => a.afterVersionCheck = g, (g) => b.afterVersionCheck = g);

      final results = await outcomes([
        a.persistEvent(pid, AuditEvent('from-a'), 0).whenComplete(aDone),
        b.persistEvent(pid, AuditEvent('from-b'), 0).whenComplete(bDone),
      ]);

      expect(results.where((r) => r == null), hasLength(1),
          reason: 'exactly one writer succeeds; got $results');
      // The loser was held on the append lock and then failed the version
      // check, rather than colliding on the unique constraint.
      expect(
          results.whereType<Object>().single,
          isA<ConcurrencyException>().having(
              (e) => e.message, 'message', contains('current version is')));
      expect(await a.getHighestSequenceNumber(pid), 1);
    });

    test(
        'two persistEvents batches with the same expectedVersion: one wins, '
        'the other gets ConcurrencyException', () async {
      final pid = 's09-batch-${_stamp()}';
      await a.persistEvent(pid, AuditEvent('seed'), 0);
      final (aDone, bDone) = _installRaceGates(admin,
          (g) => a.afterVersionCheck = g, (g) => b.afterVersionCheck = g);

      final results = await outcomes([
        a
            .persistEvents(pid, [AuditEvent('a1'), AuditEvent('a2')], 1)
            .whenComplete(aDone),
        b
            .persistEvents(pid, [AuditEvent('b1'), AuditEvent('b2')], 1)
            .whenComplete(bDone),
      ]);

      expect(results.where((r) => r == null), hasLength(1),
          reason: 'exactly one writer succeeds; got $results');
      // The loser was held on the append lock and then failed the version
      // check, rather than colliding on the unique constraint.
      expect(
          results.whereType<Object>().single,
          isA<ConcurrencyException>().having(
              (e) => e.message, 'message', contains('current version is')));
      final data = (await a.getEvents(pid)).map((e) => (e as AuditEvent).data);
      expect(data.length, 3);
      expect(data.first, 'seed');
    });

    test(
        'a unique violation on (persistence_id, sequence_number) surfaces as '
        'ConcurrencyException', () async {
      // A writer that bypasses this store (or an older instance without the
      // lock) commits the same sequence number between our version check
      // and our insert.
      final pid = 's09-bypass-${_stamp()}';
      a.afterVersionCheck = () async {
        await admin.execute(
          Sql.named('''
            INSERT INTO event_envelopes (persistence_id, sequence_number,
              event_data, event_type, timestamp, event_id)
            VALUES (@pid, 1, @data, 'AuditEvent', NOW(), @eid)
          '''),
          parameters: {
            'pid': pid,
            'data': TypedValue(Type.byteArray, Uint8List.fromList([0])),
            'eid': 'bypass-${_stamp()}',
          },
        );
      };
      await expectLater(a.persistEvent(pid, AuditEvent('late'), 0),
          throwsA(isA<ConcurrencyException>()));
    });

    test('persistEvents stores a batch with one INSERT statement', () async {
      final pid = 's09-onestatement-${_stamp()}';
      final before = a.insertStatementCount;
      await a.persistEvents(
          pid, List.generate(25, (i) => AuditEvent('e$i')), 0);
      expect(a.insertStatementCount - before, 1);

      final events = await a.getEvents(pid);
      expect(events.map((e) => (e as AuditEvent).data),
          List.generate(25, (i) => 'e$i'));
      final rows = await admin.execute(
        Sql.named('SELECT id FROM event_envelopes '
            'WHERE persistence_id = @pid ORDER BY sequence_number'),
        parameters: {'pid': pid},
      );
      final ids = rows.map((r) => r[0] as int).toList();
      expect(ids, hasLength(25));
      for (var i = 1; i < ids.length; i++) {
        expect(ids[i], greaterThan(ids[i - 1]),
            reason: 'journal ids follow sequence order within a batch');
      }
    });
  });

  group('PostgresEventStore journal paging (audit S-10)', () {
    late PostgresEventStore store;

    setUp(() async {
      store = PostgresEventStore(config);
      await store.initialize();
    });

    tearDown(() async {
      await store.close();
    });

    Future<int> lastJournalId() async {
      final r = await admin
          .execute('SELECT COALESCE(MAX(id), 0) FROM event_envelopes');
      return r.first[0] as int;
    }

    test('allEventsWithSequence reads the journal in keyset pages', () async {
      final pid = 's10-all-${_stamp()}';
      final from = await lastJournalId();
      await store.persistEvents(
          pid, List.generate(5, (i) => AuditEvent('p$i')), 0);

      store.journalPageSize = 2;
      var pageQueries = 0;
      store.beforeReplayQuery = () async => pageQueries++;

      final rows = await store
          .allEventsWithSequence(fromSequence: from, live: false)
          .toList();

      expect(rows.map((r) => (r.$1 as AuditEvent).data),
          ['p0', 'p1', 'p2', 'p3', 'p4']);
      expect(rows.map((r) => r.$2), List.generate(5, (i) => from + 1 + i));
      expect(pageQueries, 3, reason: 'pages of 2, 2 and 1 rows');
    });

    test('eventsByPersistenceId reads one actor in keyset pages', () async {
      final stamp = _stamp();
      final pid = 's10-actor-$stamp';
      final other = 's10-other-$stamp';
      for (var i = 0; i < 4; i++) {
        await store.persistEvent(pid, AuditEvent('a$i'), i);
        await store.persistEvent(other, AuditEvent('o$i'), i);
      }

      store.journalPageSize = 2;
      var pageQueries = 0;
      store.beforeReplayQuery = () async => pageQueries++;

      final events =
          await store.eventsByPersistenceId(pid, live: false).toList();

      expect(events.map((e) => (e as AuditEvent).data),
          ['a0', 'a1', 'a2', 'a3']);
      expect(pageQueries, 3,
          reason: 'two full pages, then an empty page ends the scan');
    });

    test('a page ending on an undeserializable row does not stall the scan',
        () async {
      final pid = 's10-bad-${_stamp()}';
      final from = await lastJournalId();
      await store.persistEvent(pid, AuditEvent('ok0'), 0);
      await admin.execute(
        Sql.named('''
          INSERT INTO event_envelopes (persistence_id, sequence_number,
            event_data, event_type, timestamp, event_id)
          VALUES (@pid, 2, @data, 'NoSuchAuditEventType', NOW(), @eid)
        '''),
        parameters: {
          'pid': pid,
          'data': TypedValue(Type.byteArray, Uint8List.fromList([1, 2, 3])),
          'eid': 'bad-${_stamp()}',
        },
      );
      await store.persistEvent(pid, AuditEvent('ok1'), 2);
      await store.persistEvent(pid, AuditEvent('ok2'), 3);

      store.journalPageSize = 2;
      final all = await store
          .allEventsWithSequence(fromSequence: from, live: false)
          .map((r) => (r.$1 as AuditEvent).data)
          .toList();
      expect(all, ['ok0', 'ok1', 'ok2']);

      final byActor = await store
          .eventsByPersistenceId(pid, live: false)
          .map((e) => (e as AuditEvent).data)
          .toList();
      expect(byActor, ['ok0', 'ok1', 'ok2']);
    });

    test(
        'a paged live replay delivers events persisted between pages exactly '
        'once, in order', () async {
      final pid = 's10-live-${_stamp()}';
      final from = await lastJournalId();
      await store.persistEvents(
          pid, List.generate(5, (i) => AuditEvent('seed$i')), 0);
      var version = 5;

      store.journalPageSize = 2;
      var pages = 0;
      store.afterReplayQuery = () async {
        pages++;
        if (pages == 1) {
          // Committed after page 1's snapshot: these arrive live AND appear
          // in a later page.
          await store.persistEvent(pid, AuditEvent('mid0'), version++);
          await store.persistEvent(pid, AuditEvent('mid1'), version++);
        }
      };

      final received = <(String, int)>[];
      final done = Completer<void>();
      final sub = store
          .allEventsWithSequence(fromSequence: from)
          .where((r) => r.$1 is AuditEvent)
          .listen((r) {
        received.add(((r.$1 as AuditEvent).data, r.$2));
        if (received.length == 8 && !done.isCompleted) done.complete();
      });

      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (received.length < 7 && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await store.persistEvent(pid, AuditEvent('live0'), version++);
      await done.future.timeout(const Duration(seconds: 10));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await sub.cancel();

      expect(received.map((r) => r.$1), [
        'seed0', 'seed1', 'seed2', 'seed3', 'seed4', 'mid0', 'mid1', 'live0',
      ]);
      expect(received.map((r) => r.$2), List.generate(8, (i) => from + 1 + i));
      expect(pages, greaterThan(1));
    });
  });

  group('PostgresEventStore eventsByTag (audit S-11)', () {
    late PostgresEventStore store;

    setUp(() async {
      store = PostgresEventStore(config);
      await store.initialize();
    });

    tearDown(() async {
      await store.close();
    });

    test('delivers events whose tags come from the EventTags mixin', () async {
      final stamp = _stamp();
      final tag = 'audit-tag-$stamp';
      final pid = 's11-$stamp';
      final fromR = await admin
          .execute('SELECT COALESCE(MAX(id), 0) FROM event_envelopes');
      final from = fromR.first[0] as int;

      await store.persistEvent(pid, TaggedAuditEvent('t0', {tag, 'x'}), 0);
      await store.persistEvent(pid, AuditEvent('untagged'), 1);
      await store.persistEvent(pid, TaggedAuditEvent('other', {'x'}), 2);
      await store.persistEvent(pid, TaggedAuditEvent('t1', {tag}), 3);

      final replayed = await store
          .eventsByTag(tag, fromSequence: from, live: false)
          .map((e) => (e as TaggedAuditEvent).data)
          .toList();
      expect(replayed, ['t0', 't1']);

      final live = <String>[];
      final sub = store
          .eventsByTag(tag, fromSequence: from)
          .listen((e) => live.add((e as TaggedAuditEvent).data));
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (live.length < 2 && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await store.persistEvent(pid, TaggedAuditEvent('t2', {tag}), 4);
      while (live.length < 3 && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await sub.cancel();
      expect(live, ['t0', 't1', 't2']);
    });
  });

  group('PostgresEventStore snapshots and errors (audit S-23)', () {
    late PostgresEventStore store;

    setUp(() async {
      store = PostgresEventStore(config);
      await store.initialize();
    });

    tearDown(() async {
      await store.close();
    });

    test('saveSnapshot on an existing row rewrites schema_version', () async {
      final pid = 's23-schema-${_stamp()}';
      await store.saveSnapshot(pid, {'n': 1}, 1);
      await admin.execute(
        Sql.named('UPDATE snapshot_envelopes SET schema_version = 7 '
            'WHERE persistence_id = @pid'),
        parameters: {'pid': pid},
      );

      await store.saveSnapshot(pid, {'n': 2}, 2);

      final r = await admin.execute(
        Sql.named('SELECT schema_version, sequence_number '
            'FROM snapshot_envelopes WHERE persistence_id = @pid'),
        parameters: {'pid': pid},
      );
      expect(r.first[0], 1, reason: 'schema_version must follow the upsert');
      expect(r.first[1], 2);
    });

    // A NUL byte is not valid in a Postgres text value, so the server rejects
    // the parameter: a database error, not a deserialization error.
    const badId = 'bad\u0000id';

    test('loadSnapshot wraps a database error in EventStoreException', () {
      expect(store.loadSnapshot(badId), throwsA(isA<EventStoreException>()));
    });

    test('loadSnapshot wraps an undeserializable snapshot in '
        'EventStoreException', () async {
      final pid = 's23-badstate-${_stamp()}';
      await admin.execute(
        Sql.named('''
          INSERT INTO snapshot_envelopes (persistence_id, sequence_number,
            snapshot_data, timestamp, state_type, size_bytes)
          VALUES (@pid, 1, @data, NOW(), 'Whatever', 3)
        '''),
        parameters: {
          'pid': pid,
          'data': TypedValue(Type.byteArray, Uint8List.fromList([0xff, 0, 1])),
        },
      );
      await expectLater(
          store.loadSnapshot(pid), throwsA(isA<EventStoreException>()));
    });

    test('getEvents wraps a database error in EventStoreException', () {
      expect(store.getEvents(badId), throwsA(isA<EventStoreException>()));
    });

    test('saveSnapshot and getHighestSequenceNumber wrap database errors', () {
      expect(store.saveSnapshot(badId, {'n': 1}, 1),
          throwsA(isA<EventStoreException>()));
      expect(store.getHighestSequenceNumber(badId),
          throwsA(isA<EventStoreException>()));
    });
  });

  group('PostgresMigrations (audit S-22, S-21)', () {
    Future<void> resetSchema({required bool dropMigrationsTable}) async {
      await _clearBlockHeaders(admin);
      await PostgresMigrations(config).reset();
      if (dropMigrationsTable) {
        await admin.execute('DROP TABLE IF EXISTS schema_migrations');
      }
    }

    Future<void> runConcurrently() async {
      final first = PostgresMigrations(config);
      final second = PostgresMigrations(config);
      final (firstDone, secondDone) = _installRaceGates(
        admin,
        (g) => first.afterVersionRead = (_) => g(),
        (g) => second.afterVersionRead = (_) => g(),
      );
      final results = await Future.wait([
        first.migrate().whenComplete(firstDone).then<Object?>((_) => null,
            onError: (Object e) => e),
        second.migrate().whenComplete(secondDone).then<Object?>((_) => null,
            onError: (Object e) => e),
      ]);
      expect(results, [null, null],
          reason: 'both instances must finish starting up');

      final applied = await first.getAppliedMigrations();
      expect(applied.map((m) => m.version).toSet(), hasLength(applied.length));
      expect(await first.getPendingMigrations(), isEmpty);
    }

    test('two instances migrating a reset database together both complete',
        () async {
      await resetSchema(dropMigrationsTable: false);
      await runConcurrently();
    });

    test('two instances migrating a fresh database together both complete',
        () async {
      await resetSchema(dropMigrationsTable: true);
      await runConcurrently();
    });

    test('reset() and rollback() on a database without schema_migrations',
        () async {
      await resetSchema(dropMigrationsTable: true);
      final migrations = PostgresMigrations(config);

      await migrations.reset();
      expect(await migrations.rollback(), isFalse);
      expect(await migrations.getCurrentVersion(), 0);
      expect(await migrations.getAppliedMigrations(), isEmpty);

      await migrations.migrate();
      expect(await migrations.getPendingMigrations(), isEmpty);
    });

    test('getCurrentVersion reports an unreachable database instead of 0',
        () async {
      final unreachable = config.copyWith(
          port: 1, connectionTimeout: const Duration(seconds: 2));
      await expectLater(
          PostgresMigrations(unreachable).getCurrentVersion(), throwsA(anything));
      await expectLater(PostgresMigrations(unreachable).getAppliedMigrations(),
          throwsA(anything));
    });

    test('withPool migrates through a caller-owned pool and leaves it open',
        () async {
      final pool = await config.createPool();
      try {
        final migrations = PostgresMigrations.withPool(pool);
        await migrations.migrate();
        expect(await migrations.getPendingMigrations(), isEmpty);
        expect(await migrations.getCurrentVersion(), greaterThan(0));
        // Still usable: the manager did not close the caller's pool.
        expect((await pool.execute('SELECT 1')).first[0], 1);
      } finally {
        await pool.close();
      }
    });
  });

  group('PostgresConfig on a live server (audit S-14)', () {
    test('schema and idleTimeout reach the server session', () async {
      const schema = 'lane1_audit_schema';
      await admin.execute('CREATE SCHEMA IF NOT EXISTS $schema');
      final pool = await config
          .copyWith(schema: schema, idleTimeout: const Duration(seconds: 90))
          .createPool();
      try {
        final searchPath = await pool.execute('SHOW search_path');
        expect(searchPath.first[0], schema);
        final idle = await pool.execute('SHOW idle_session_timeout');
        expect(idle.first[0], anyOf('90s', '90000ms', '1min 30s'));
      } finally {
        await pool.close();
      }
    });

    test('the pool replaces a session the server closed for idling', () async {
      final pool = await config
          .copyWith(idleTimeout: const Duration(seconds: 1))
          .createPool();
      try {
        final first = (await pool.execute('SELECT pg_backend_pid()')).first[0];
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        final second =
            (await pool.execute('SELECT pg_backend_pid()')).first[0];
        expect(second, isNot(first),
            reason: 'the idle session was closed and a new one opened');
      } finally {
        await pool.close();
      }
    });
  });

  group('PostgresSecureStorage key versions (audit KM-9)', () {
    late EncryptionService keyV1;
    late EncryptionService otherV1;
    late EncryptionService keyV2;

    setUp(() async {
      keyV1 = EncryptionService(
          masterKey: await EncryptionService.generateMasterKey());
      otherV1 = EncryptionService(
          masterKey: await EncryptionService.generateMasterKey());
      keyV2 = EncryptionService(
          masterKey: await EncryptionService.generateMasterKey(),
          keyVersion: 2);
      await PostgresSecureStorage(pool: admin, encryptionService: keyV1)
          .deleteAll();
    });

    test('getAll reports a secret it cannot decrypt instead of dropping it',
        () async {
      final writer =
          PostgresSecureStorage(pool: admin, encryptionService: keyV1);
      await writer.setXPub('w-good', 'xpub-good');
      final wrongKey =
          PostgresSecureStorage(pool: admin, encryptionService: otherV1);
      await wrongKey.setXPub('w-other', 'xpub-other');

      // wrongKey can read its own row but not writer's.
      await expectLater(
        wrongKey.getAll(),
        throwsA(isA<SecureStorageException>().having(
            (e) => e.message, 'message', contains('wallet_xpub_w-good'))),
      );
    });

    test('a row under a key_version this storage has no key for is reported '
        'as such', () async {
      await PostgresSecureStorage(pool: admin, encryptionService: keyV1)
          .setXPub('w-v1', 'xpub-v1');
      final current =
          PostgresSecureStorage(pool: admin, encryptionService: keyV2);

      await expectLater(
        current.getXPub('w-v1'),
        throwsA(isA<SecureStorageException>()
            .having((e) => e.message, 'message', contains('key version 1'))),
      );
      await expectLater(
        current.getAll(),
        throwsA(isA<SecureStorageException>()
            .having((e) => e.message, 'message', contains('key version 1'))),
      );
    });

    test('rows written under a previous key version stay readable after '
        'rotation, and new writes use the current version', () async {
      await PostgresSecureStorage(pool: admin, encryptionService: keyV1)
          .setXPub('w-old', 'xpub-old');
      final rotated = PostgresSecureStorage(
          pool: admin, encryptionService: keyV2, previousKeys: [keyV1]);

      expect(await rotated.getXPub('w-old'), 'xpub-old');
      await rotated.setXPub('w-new', 'xpub-new');
      expect(await rotated.getAll(), {
        'wallet_xpub_w-old': 'xpub-old',
        'wallet_xpub_w-new': 'xpub-new',
      });

      final versions = await admin.execute(
          "SELECT key_name, key_version FROM secure_secrets "
          "WHERE key_name LIKE 'wallet_xpub_w-%' ORDER BY key_name");
      expect({for (final r in versions) r[0]: r[1]},
          {'wallet_xpub_w-new': 2, 'wallet_xpub_w-old': 1});
    });

    test('reencryptToCurrentKey moves every row onto the current key version',
        () async {
      final v1 = PostgresSecureStorage(pool: admin, encryptionService: keyV1);
      await v1.setXPub('w-a', 'xpub-a');
      await v1.setString('wallet_hdpubkey_w-b', 'hd-b');

      final rotated = PostgresSecureStorage(
          pool: admin, encryptionService: keyV2, previousKeys: [keyV1]);
      expect(await rotated.reencryptToCurrentKey(), 2);
      expect(await rotated.reencryptToCurrentKey(), 0);

      // The old key can now be dropped.
      final v2Only =
          PostgresSecureStorage(pool: admin, encryptionService: keyV2);
      expect(await v2Only.getAll(), {
        'wallet_xpub_w-a': 'xpub-a',
        'wallet_hdpubkey_w-b': 'hd-b',
      });
    });

    test('previousKeys may not repeat a key version', () {
      expect(
        () => PostgresSecureStorage(
            pool: admin, encryptionService: keyV1, previousKeys: [otherV1]),
        throwsArgumentError,
      );
    });
  });
}
