/// Journal ids that commit out of order (audit bead libspiffy-xp4).
///
/// Journal ids are allocated at INSERT time, but appends to different
/// persistence ids commit in any order. A reader that advances an
/// `id > last` cursor, or a live stream that drops ids at or below the last
/// one it delivered, used to pass an id whose transaction had not committed
/// yet and never deliver it. These tests park writers at exact points with
/// the store's `@visibleForTesting` hooks.
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

import 'package:libspiffy/src/storage/postgres/postgres_config.dart';
import 'package:libspiffy/src/storage/postgres/postgres_event_store.dart';
import 'package:libspiffy/src/storage/postgres/postgres_migrations.dart';

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

class OrderEvent extends Event {
  final String data;

  OrderEvent(this.data, {super.eventId, super.timestamp});

  @override
  Map<String, dynamic> toMap() => {...super.toMap(), 'data': data};

  static OrderEvent fromMap(Map<String, dynamic> map) => OrderEvent(
        map['data'] as String,
        eventId: map['eventId'] as String,
        timestamp: map['timestamp'] is DateTime
            ? map['timestamp'] as DateTime
            : DateTime.parse(map['timestamp'] as String),
      );
}

String _stamp() => DateTime.now().microsecondsSinceEpoch.toString();

/// Polls [condition] until it holds or [timeout] passes; returns whether it
/// held (never throws, so a test can report what it received instead).
Future<bool> _eventually(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) return false;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  return true;
}

/// A writer parked at a hook until [release] completes.
class _Gate {
  final parked = Completer<void>();
  final release = Completer<void>();

  Future<void> Function(String) hookFor(String persistenceId) => (pid) async {
        if (pid != persistenceId) return;
        parked.complete();
        await release.future;
      };
}

void main() {
  final config = _testConfig();
  late Pool admin;

  setUpAll(() async {
    admin = await config.createPool();
    await PostgresMigrations(config).migrate();
    EventRegistry.register<OrderEvent>('OrderEvent', OrderEvent.fromMap);
  });

  tearDownAll(() async {
    await PostgresMigrations(config).migrate();
    await admin.close();
  });

  Future<int> lastJournalId() async {
    final r =
        await admin.execute('SELECT COALESCE(MAX(id), 0) FROM event_envelopes');
    return r.first[0] as int;
  }

  Future<int> journalIdOf(String persistenceId) async {
    final r = await admin.execute(
      Sql.named('SELECT id FROM event_envelopes WHERE persistence_id = @pid'),
      parameters: {'pid': persistenceId},
    );
    return r.single[0] as int;
  }

  /// This test's events from [rows], as `(data, journal id)`.
  List<(String, int)> mine(Iterable<(Event, int)> rows, String stamp) => [
        for (final (event, id) in rows)
          if (event is OrderEvent && event.data.endsWith(stamp))
            (event.data, id),
      ];

  group('Postgres journal order (libspiffy-xp4)', () {
    late PostgresEventStore store;

    setUp(() async {
      store = PostgresEventStore(config);
      await store.initialize();
    });

    tearDown(() async {
      await store.close();
    });

    test(
        'a replay run while a lower journal id is uncommitted, resumed from its '
        'checkpoint after that commit, delivers both events in id order',
        () async {
      final stamp = _stamp();
      final from = await lastJournalId();
      // The replay runs on another store instance: it knows nothing of the
      // writer's appends, like a projection in another process.
      final reader = PostgresEventStore(config);
      await reader.initialize();
      try {
        final gate = _Gate();
        store.beforeCommit = gate.hookFor('xp4-a-$stamp');
        final a = store.persistEvent('xp4-a-$stamp', OrderEvent('a-$stamp'), 0);
        await gate.parked.future;
        await store.persistEvent('xp4-b-$stamp', OrderEvent('b-$stamp'), 0);
        expect(await journalIdOf('xp4-b-$stamp'), greaterThan(from));

        final firstRun = mine(
            await reader
                .allEventsWithSequence(fromSequence: from, live: false)
                .toList(),
            stamp);
        final delivered = [...firstRun];
        var checkpoint = firstRun.isEmpty ? from : firstRun.last.$2;

        gate.release.complete();
        await a;
        final idA = await journalIdOf('xp4-a-$stamp');
        final idB = await journalIdOf('xp4-b-$stamp');
        expect(idA, lessThan(idB),
            reason: 'scenario: the parked writer has '
                'the lower journal id');

        // Resume from the checkpoint, as a projection does, until both are in
        // (a writing transaction elsewhere on the server can hold the horizon
        // back for a moment).
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        while (delivered.length < 2 && DateTime.now().isBefore(deadline)) {
          final more = mine(
              await reader
                  .allEventsWithSequence(fromSequence: checkpoint, live: false)
                  .toList(),
              stamp);
          delivered.addAll(more);
          if (more.isNotEmpty) checkpoint = more.last.$2;
          if (delivered.length < 2) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
        }

        expect(delivered, [('a-$stamp', idA), ('b-$stamp', idB)]);
      } finally {
        await reader.close();
      }
    });

    test(
        'a live subscription opened while a lower journal id is uncommitted '
        'delivers both events exactly once, in id order', () async {
      final stamp = _stamp();
      final from = await lastJournalId();
      final received = <(Event, int)>[];
      final sub =
          store.allEventsWithSequence(fromSequence: from).listen(received.add);
      try {
        // Let the replay finish first, so both appends reach the live path.
        await _eventually(() => store.journalReadCount > 0);

        final gate = _Gate();
        store.beforeCommit = gate.hookFor('xp4-a-$stamp');
        final a = store.persistEvent('xp4-a-$stamp', OrderEvent('a-$stamp'), 0);
        await gate.parked.future;
        final readsBeforeB = store.journalReadCount;
        await store.persistEvent('xp4-b-$stamp', OrderEvent('b-$stamp'), 0);
        // The stream reacted to b (read the journal, or received b) while a
        // is still uncommitted.
        await _eventually(() =>
            mine(received, stamp).isNotEmpty ||
            store.journalReadCount > readsBeforeB);

        gate.release.complete();
        await a;
        await _eventually(() => mine(received, stamp).length >= 2);
        await Future<void>.delayed(const Duration(milliseconds: 50));

        final idA = await journalIdOf('xp4-a-$stamp');
        final idB = await journalIdOf('xp4-b-$stamp');
        expect(idA, lessThan(idB));
        expect(mine(received, stamp), [('a-$stamp', idA), ('b-$stamp', idB)]);
      } finally {
        await sub.cancel();
      }
    });

    test(
        'an append parked after COMMIT and before waking live streams is not '
        'dropped when a later append is delivered first', () async {
      final stamp = _stamp();
      final from = await lastJournalId();
      final received = <(Event, int)>[];
      final sub =
          store.allEventsWithSequence(fromSequence: from).listen(received.add);
      try {
        await _eventually(() => store.journalReadCount > 0);

        final gate = _Gate();
        store.afterCommit = gate.hookFor('xp4-a-$stamp');
        final a = store.persistEvent('xp4-a-$stamp', OrderEvent('a-$stamp'), 0);
        await gate.parked.future;
        await store.persistEvent('xp4-b-$stamp', OrderEvent('b-$stamp'), 0);
        await _eventually(
            () => mine(received, stamp).any((r) => r.$1 == 'b-$stamp'));

        gate.release.complete();
        await a;
        await _eventually(() => mine(received, stamp).length >= 2);
        await Future<void>.delayed(const Duration(milliseconds: 50));

        final idA = await journalIdOf('xp4-a-$stamp');
        final idB = await journalIdOf('xp4-b-$stamp');
        expect(mine(received, stamp), [('a-$stamp', idA), ('b-$stamp', idB)]);
      } finally {
        await sub.cancel();
      }
    });

    test(
        'a store instance on its own pool (another process) streams the '
        "writer's events live, in order, with a lower id committing last",
        () async {
      final stamp = _stamp();
      final from = await lastJournalId();
      final reader = PostgresEventStore(config,
          livePollInterval: const Duration(milliseconds: 20));
      await reader.initialize();
      final received = <(Event, int)>[];
      final sub =
          reader.allEventsWithSequence(fromSequence: from).listen(received.add);
      try {
        await _eventually(() => reader.journalReadCount > 0);

        final gate = _Gate();
        store.beforeCommit = gate.hookFor('xp4-a-$stamp');
        final a = store.persistEvent('xp4-a-$stamp', OrderEvent('a-$stamp'), 0);
        await gate.parked.future;
        await store.persistEvent('xp4-b-$stamp', OrderEvent('b-$stamp'), 0);
        // The reader polled at least once after b committed, a still open.
        final readsAfterB = reader.journalReadCount;
        await _eventually(() =>
            mine(received, stamp).isNotEmpty ||
            reader.journalReadCount > readsAfterB + 1);

        gate.release.complete();
        await a;
        await _eventually(() => mine(received, stamp).length >= 2);
        await Future<void>.delayed(const Duration(milliseconds: 50));

        final idA = await journalIdOf('xp4-a-$stamp');
        final idB = await journalIdOf('xp4-b-$stamp');
        final expected = [('a-$stamp', idA), ('b-$stamp', idB)];
        expect(mine(received, stamp), expected, reason: 'live');
        expect(
            mine(
                await reader
                    .allEventsWithSequence(fromSequence: from, live: false)
                    .toList(),
                stamp),
            expected,
            reason: 'replay');
      } finally {
        await sub.cancel();
        await reader.close();
      }
    });

    test(
        'a row whose id was allocated before a committed higher id, but whose '
        'transaction started after it, is delivered after a checkpoint on the '
        'higher id', () async {
      // Ids and transaction ids can be allocated in opposite orders, so
      // ordering by id under a transaction horizon would still skip `a`;
      // the stream orders by (tx_id, id).
      final stamp = _stamp();
      final from = await lastJournalId();
      final reader = PostgresEventStore(config);
      await reader.initialize();
      Map<String, Object?> row(String pid, String data) => {
            'pid': pid,
            'data': TypedValue(
                Type.byteArray,
                Uint8List.fromList(
                    CborSerializer.serializeEvent(OrderEvent(data)))),
            'eid': 'xp4-raw-$data',
          };
      const insert = '''
        INSERT INTO event_envelopes (id, persistence_id, sequence_number,
          event_data, event_type, timestamp, event_id)
        VALUES (COALESCE(@id:int8, nextval(pg_get_serial_sequence('event_envelopes', 'id'))),
          @pid, 1, @data, 'OrderEvent', NOW(), @eid)
      ''';
      try {
        final idA = (await admin.execute(
                "SELECT nextval(pg_get_serial_sequence('event_envelopes', 'id'))"))
            .first[0] as int;
        await admin.execute(Sql.named(insert),
            parameters: {'id': null, ...row('xp4-b-$stamp', 'b-$stamp')});
        final idB = await journalIdOf('xp4-b-$stamp');
        expect(idA, lessThan(idB));

        final first = mine(
            await reader
                .allEventsWithSequence(fromSequence: from, live: false)
                .toList(),
            stamp);
        expect(first, [('b-$stamp', idB)]);

        // `a` commits under a newer transaction with the older id.
        await admin.execute(Sql.named(insert),
            parameters: {'id': idA, ...row('xp4-a-$stamp', 'a-$stamp')});
        final resumed = mine(
            await reader
                .allEventsWithSequence(fromSequence: idB, live: false)
                .toList(),
            stamp);
        expect(resumed, [('a-$stamp', idA)]);
      } finally {
        await reader.close();
      }
    });

    test(
        'a live stream delivers an append held back by an unrelated older '
        'transaction once it ends, without polling', () async {
      final stamp = _stamp();
      final from = await lastJournalId();
      final quiet = PostgresEventStore(config, livePollInterval: null);
      await quiet.initialize();
      final received = <(Event, int)>[];
      final sub =
          quiet.allEventsWithSequence(fromSequence: from).listen(received.add);
      final holdOpen = Completer<void>();
      final opened = Completer<void>();
      Future<void>? older;
      try {
        await _eventually(() => quiet.journalReadCount > 0);
        older = admin.runTx((tx) async {
          await tx.execute('SELECT pg_current_xact_id()');
          opened.complete();
          await holdOpen.future;
        });
        await opened.future;
        final readsBefore = quiet.journalReadCount;
        await quiet.persistEvent('xp4-held-$stamp', OrderEvent('h-$stamp'), 0);
        await _eventually(() => quiet.journalReadCount > readsBefore);
        holdOpen.complete();
        await older;
        await _eventually(() => mine(received, stamp).isNotEmpty);
        expect(mine(received, stamp),
            [('h-$stamp', await journalIdOf('xp4-held-$stamp'))]);
      } finally {
        if (!holdOpen.isCompleted) holdOpen.complete();
        await older;
        await sub.cancel();
        await quiet.close();
      }
    });

    test(
        'a replay (live: false) includes the appends this instance committed, '
        'even while an older transaction holds the horizon back', () async {
      final stamp = _stamp();
      final from = await lastJournalId();
      final holdOpen = Completer<void>();
      final opened = Completer<void>();
      final older = admin.runTx((tx) async {
        await tx.execute('SELECT pg_current_xact_id()');
        opened.complete();
        await holdOpen.future;
      });
      await opened.future;
      try {
        await store.persistEvent('xp4-ryw-$stamp', OrderEvent('r-$stamp'), 0);
        final readsBefore = store.journalReadCount;
        final replay = store
            .allEventsWithSequence(fromSequence: from, live: false)
            .toList();
        await _eventually(() => store.journalReadCount > readsBefore);
        holdOpen.complete();
        await older;
        expect(mine(await replay.timeout(const Duration(seconds: 10)), stamp),
            [('r-$stamp', await journalIdOf('xp4-ryw-$stamp'))]);
      } finally {
        if (!holdOpen.isCompleted) holdOpen.complete();
      }
    });
  });

  group('Postgres migration v008 (libspiffy-xp4)', () {
    test(
        'existing rows get tx_id 0 and replay before new rows; down drops the '
        'column and index', () async {
      final migrations = PostgresMigrations(config);
      Future<bool> hasColumn() async => (await admin.execute(
            "SELECT EXISTS (SELECT 1 FROM information_schema.columns "
            "WHERE table_name = 'event_envelopes' AND column_name = 'tx_id')",
          ))
              .first[0] as bool;
      Future<bool> hasIndex() async => (await admin.execute(
            "SELECT to_regclass('idx_event_envelopes_tx_id_id') IS NOT NULL",
          ))
              .first[0] as bool;

      final stamp = _stamp();
      final from = await lastJournalId();
      while (await migrations.getCurrentVersion() > 7) {
        await migrations.rollback();
      }
      expect(await hasColumn(), isFalse);
      expect(await hasIndex(), isFalse);

      // A row stored before v008.
      await admin.execute(
        Sql.named('''
          INSERT INTO event_envelopes (persistence_id, sequence_number,
            event_data, event_type, timestamp, event_id)
          VALUES (@pid, 1, @data, 'OrderEvent', NOW(), @eid)
        '''),
        parameters: {
          'pid': 'xp4-legacy-$stamp',
          'data': TypedValue(
              Type.byteArray,
              Uint8List.fromList(
                  CborSerializer.serializeEvent(OrderEvent('legacy-$stamp')))),
          'eid': 'xp4-legacy-$stamp',
        },
      );

      await migrations.migrate();
      expect(await hasColumn(), isTrue);
      expect(await hasIndex(), isTrue);
      final legacyTx = await admin.execute(
        Sql.named(
            'SELECT tx_id FROM event_envelopes WHERE persistence_id = @pid'),
        parameters: {'pid': 'xp4-legacy-$stamp'},
      );
      expect(legacyTx.single[0], 0);

      final store = PostgresEventStore(config);
      await store.initialize();
      try {
        await store.persistEvent('xp4-new-$stamp', OrderEvent('new-$stamp'), 0);
        final newTx = await admin.execute(
          Sql.named(
              'SELECT tx_id FROM event_envelopes WHERE persistence_id = @pid'),
          parameters: {'pid': 'xp4-new-$stamp'},
        );
        expect(newTx.single[0] as int, greaterThan(0));
        expect(
          mine(
                  await store
                      .allEventsWithSequence(fromSequence: from, live: false)
                      .toList(),
                  stamp)
              .map((r) => r.$1),
          ['legacy-$stamp', 'new-$stamp'],
        );
      } finally {
        await store.close();
      }
    });
  });
}
