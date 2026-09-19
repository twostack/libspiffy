/// Persist failures that are not concurrency conflicts (bead libspiffy-tpv).
///
/// [PostgresEventStore] recognises an optimistic-locking conflict and reports
/// it as [ConcurrencyException], which callers retry. Every other database
/// failure used to escape as package:postgres' raw [ServerException]: a
/// caller could not tell a libspiffy storage failure from any other driver
/// error, and nothing in the message said which actor's journal was being
/// written. These tests pin both halves — the typed wrapper, and the
/// original still reachable through it.
///
/// Requires the local PostgreSQL server; the database comes from
/// POSTGRES_DATABASE (see postgres_integration_test.dart for the settings).
@Tags(['postgres', 'integration'])
library;

import 'dart:io';

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

class FailureEvent extends Event {
  final String data;

  FailureEvent(this.data, {super.eventId, super.timestamp});

  @override
  Map<String, dynamic> toMap() => {...super.toMap(), 'data': data};

  static FailureEvent fromMap(Map<String, dynamic> map) => FailureEvent(
        map['data'] as String,
        eventId: map['eventId'] as String,
        timestamp: map['timestamp'] is DateTime
            ? map['timestamp'] as DateTime
            : DateTime.parse(map['timestamp'] as String),
      );
}

String _stamp() => DateTime.now().microsecondsSinceEpoch.toString();

void main() {
  final config = _testConfig();
  late PostgresEventStore store;

  setUpAll(() async {
    await PostgresMigrations(config).migrate();
    EventRegistry.register<FailureEvent>('FailureEvent', FailureEvent.fromMap);
  });

  setUp(() async {
    store = PostgresEventStore(config, livePollInterval: null);
    await store.initialize();
  });

  tearDown(() async {
    await store.close();
  });

  group('non-concurrency persist failures (libspiffy-tpv)', () {
    test('a duplicate event id is an EventStoreException, not a raw '
        'ServerException', () async {
      final stamp = _stamp();
      // The same Event object, so the same event_id, appended to two
      // journals: the second insert violates event_envelopes_event_id_key,
      // which is a unique violation but not an optimistic-locking conflict.
      final event = FailureEvent('duplicate-$stamp');
      await store.persistEvent('errors-a-$stamp', event, 0);

      Object? thrown;
      try {
        await store.persistEvent('errors-b-$stamp', event, 0);
      } catch (e) {
        thrown = e;
      }

      expect(thrown, isNot(isA<ServerException>()),
          reason: 'the driver exception must not escape');
      expect(thrown, isNot(isA<ConcurrencyException>()),
          reason: 'a duplicate event id is not a version conflict');
      expect(thrown, isA<EventStoreException>());

      final failure = thrown as EventStoreException;
      // The message names the journal being written and the SQLSTATE.
      expect(failure.message, contains('errors-b-$stamp'));
      expect(failure.message, contains('23505'));
      expect(failure.message, contains('event_envelopes_event_id_key'));
      // Nothing is swallowed: the driver's own exception is the cause.
      expect(failure.cause, isA<ServerException>());
      final cause = failure.cause as ServerException;
      expect(cause.code, '23505');
      expect(cause.constraintName, 'event_envelopes_event_id_key');
      expect(failure.toString(), contains('caused by'));
    });

    test('a value the column cannot hold is an EventStoreException carrying '
        'the driver error', () async {
      final stamp = _stamp();
      // persistence_id is VARCHAR(255); 300 characters is SQLSTATE 22001.
      final longId = 'x' * 300;

      Object? thrown;
      StackTrace? stack;
      try {
        await store.persistEvent(longId, FailureEvent('long-$stamp'), 0);
      } catch (e, s) {
        thrown = e;
        stack = s;
      }

      expect(thrown, isA<EventStoreException>());
      final failure = thrown as EventStoreException;
      expect(failure.cause, isA<ServerException>());
      expect((failure.cause as ServerException).code, '22001');
      // The original stack trace survives the wrapping, so the driver frame
      // that actually failed is still in it.
      expect(stack.toString(), contains('postgres'));
    });

    test('a version conflict is still a ConcurrencyException', () async {
      final stamp = _stamp();
      final pid = 'errors-conflict-$stamp';
      await store.persistEvent(pid, FailureEvent('first-$stamp'), 0);

      expect(
        () => store.persistEvent(pid, FailureEvent('second-$stamp'), 0),
        throwsA(isA<ConcurrencyException>()),
      );
    });

    test('a batch append reports its size and journal in the failure',
        () async {
      final stamp = _stamp();
      final shared = FailureEvent('batch-duplicate-$stamp');
      await store.persistEvent('errors-c-$stamp', shared, 0);

      Object? thrown;
      try {
        await store.persistEvents(
          'errors-d-$stamp',
          [FailureEvent('batch-a-$stamp'), shared],
          0,
        );
      } catch (e) {
        thrown = e;
      }

      expect(thrown, isA<EventStoreException>());
      expect((thrown as EventStoreException).message,
          contains('2 event(s) to errors-d-$stamp'));
    });
  });
}
