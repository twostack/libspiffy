/// The cost of [PostgresEventStore.currentPersistenceIds] (bead
/// libspiffy-tpv).
///
/// It used to be `SELECT DISTINCT persistence_id FROM event_envelopes`: one
/// statement that reads every row of a journal which only ever grows (no
/// path deletes journal rows, by design) to return one row per actor. It now
/// walks `idx_event_envelopes_persistence_id` in keyset pages, so the work
/// is proportional to the number of distinct ids instead.
///
/// These tests observe the behaviour, never the clock: they EXPLAIN ANALYZE
/// the statement the store actually issued (captured through
/// `onPersistenceIdsQuery`) and count the rows it read out of
/// `event_envelopes`, and they count the round trips the stream makes.
///
/// Requires the local PostgreSQL server; the database comes from
/// POSTGRES_DATABASE (see postgres_integration_test.dart for the settings).
@Tags(['postgres', 'integration'])
library;

import 'dart:convert';
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

class IdsEvent extends Event {
  final String data;

  IdsEvent(this.data, {super.eventId, super.timestamp});

  @override
  Map<String, dynamic> toMap() => {...super.toMap(), 'data': data};

  static IdsEvent fromMap(Map<String, dynamic> map) => IdsEvent(
        map['data'] as String,
        eventId: map['eventId'] as String,
        timestamp: map['timestamp'] is DateTime
            ? map['timestamp'] as DateTime
            : DateTime.parse(map['timestamp'] as String),
      );
}

String _stamp() => DateTime.now().microsecondsSinceEpoch.toString();

/// Every node of an EXPLAIN plan tree, depth first.
Iterable<Map<String, dynamic>> _nodes(Map<String, dynamic> node) sync* {
  yield node;
  final children = node['Plans'];
  if (children is List) {
    for (final child in children) {
      yield* _nodes(child as Map<String, dynamic>);
    }
  }
}

/// The rows a plan actually read out of `event_envelopes`, summed over every
/// scan node and all of its loops.
int _rowsReadFromJournal(Map<String, dynamic> plan) {
  var total = 0;
  for (final node in _nodes(plan)) {
    if (node['Relation Name'] != 'event_envelopes') continue;
    final rows = (node['Actual Rows'] as num?)?.toDouble() ?? 0;
    final loops = (node['Actual Loops'] as num?)?.toDouble() ?? 1;
    total += (rows * loops).round();
  }
  return total;
}

/// The scan node types the plan uses on `event_envelopes`, each with the
/// index it used (or `null`).
List<(String, String?)> _journalScans(Map<String, dynamic> plan) => [
      for (final node in _nodes(plan))
        if (node['Relation Name'] == 'event_envelopes')
          (node['Node Type'] as String, node['Index Name'] as String?),
    ];

void main() {
  final config = _testConfig();
  late Pool admin;
  late PostgresEventStore store;
  final captured = <(String, Map<String, Object?>)>[];

  setUpAll(() async {
    await PostgresMigrations(config).migrate();
    EventRegistry.register<IdsEvent>('IdsEvent', IdsEvent.fromMap);
    admin = await config.createPool();

    // Enough rows that "reads every row" and "reads one row per id" are far
    // apart, so the assertions below can tell them apart at all.
    final seed = PostgresEventStore(config, livePollInterval: null);
    await seed.initialize();
    final stamp = _stamp();
    for (var actor = 0; actor < 2; actor++) {
      await seed.persistEvents(
        'ids-seed-$actor-$stamp',
        [for (var i = 0; i < 60; i++) IdsEvent('seed-$actor-$i-$stamp')],
        0,
      );
    }
    await seed.close();
  });

  tearDownAll(() async {
    await admin.close();
  });

  setUp(() async {
    captured.clear();
    store = PostgresEventStore(config, livePollInterval: null);
    await store.initialize();
    store.onPersistenceIdsQuery = (sql, parameters) =>
        captured.add((sql, Map<String, Object?>.from(parameters)));
  });

  tearDown(() async {
    await store.close();
  });

  Future<({int rows, int ids})> journalSize() async {
    final r = await admin.execute(
      'SELECT COUNT(*), COUNT(DISTINCT persistence_id) FROM event_envelopes',
    );
    return (rows: r.first[0] as int, ids: r.first[1] as int);
  }

  /// Runs EXPLAIN (ANALYZE) over the statement the store issued and returns
  /// its plan tree.
  Future<Map<String, dynamic>> explain(
    String sql,
    Map<String, Object?> parameters,
  ) async {
    final result = await admin.execute(
      Sql.named('EXPLAIN (ANALYZE, FORMAT JSON) $sql'),
      parameters: parameters,
    );
    final raw = result.first[0];
    final decoded = raw is String ? jsonDecode(raw) : raw;
    final plans = decoded as List<dynamic>;
    return (plans.first as Map<String, dynamic>)['Plan']
        as Map<String, dynamic>;
  }

  group('currentPersistenceIds cost (libspiffy-tpv)', () {
    test('returns every persistence id, in ascending order', () async {
      final stamp = _stamp();
      final pid = 'ids-order-$stamp';
      await store.persistEvent(pid, IdsEvent('one-$stamp'), 0);

      final ids = await store.currentPersistenceIds().toList();

      expect(ids, contains(pid));
      expect(ids, equals(List<String>.from(ids)..sort()));
      expect(ids.toSet().length, ids.length, reason: 'no id is repeated');
      expect(ids.length, (await journalSize()).ids);
    });

    test('reads one row per persistence id, not every journal row', () async {
      final ids = await store.currentPersistenceIds().toList();
      expect(captured, isNotEmpty);

      final size = await journalSize();
      // One row per id (plus the anchor's) is what a skip scan reads; the
      // rounding in EXPLAIN's per-loop averages gets a couple of rows of
      // slack.
      final budget = ids.length + 3;
      expect(size.rows, greaterThan(budget * 3),
          reason: 'the journal must be long enough for "reads every row" and '
              '"reads one row per id" to be distinguishable');

      var rowsRead = 0;
      for (final (sql, parameters) in captured) {
        rowsRead += _rowsReadFromJournal(await explain(sql, parameters));
      }

      expect(rowsRead, lessThanOrEqualTo(budget),
          reason: 'read $rowsRead rows of ${size.rows} for ${ids.length} ids');
    });

    test('walks the persistence_id index instead of scanning the journal',
        () async {
      await store.currentPersistenceIds().toList();
      expect(captured, isNotEmpty);

      final scans = _journalScans(await explain(
        captured.first.$1,
        captured.first.$2,
      ));

      expect(scans, isNotEmpty);
      expect(
        scans.map((s) => s.$2),
        everyElement('idx_event_envelopes_persistence_id'),
        reason: 'every access to event_envelopes goes through the index: '
            '$scans',
      );
      expect(
        scans.map((s) => s.$1),
        everyElement(contains('Index Only Scan')),
        reason: 'no heap scan of the journal: $scans',
      );
    });

    test('pages the journal instead of issuing one unbounded query', () async {
      store.persistenceIdPageSize = 2;
      final ids = await store.currentPersistenceIds().toList();

      expect(ids.length, greaterThan(4),
          reason: 'the journal needs several ids for paging to show');
      // Full pages of two until a short (possibly empty) page ends it.
      expect(store.persistenceIdQueryCount, ids.length ~/ 2 + 1);
      expect(captured.length, store.persistenceIdQueryCount);
      // Every page after the first resumes from the last id it delivered.
      expect(captured.first.$2.containsKey('after'), isFalse);
      expect(captured[1].$2['after'], ids[1]);
      expect(ids, equals(List<String>.from(ids)..sort()));
    });

    test('a page reads only its own ids out of the journal', () async {
      store.persistenceIdPageSize = 2;
      await store.currentPersistenceIds().toList();

      final plan = await explain(captured.first.$1, captured.first.$2);
      // A two-id page reads two ids, whatever the journal holds.
      expect(_rowsReadFromJournal(plan), lessThanOrEqualTo(4));
    });
  });
}
