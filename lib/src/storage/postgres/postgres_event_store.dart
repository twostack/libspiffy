/// PostgreSQL-based event store for libspiffy.
///
/// Implements Eventador's EventStore and EventStream interfaces using PostgreSQL
/// as the persistence layer.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:eventador/eventador.dart';
import 'package:logging/logging.dart';
import 'package:meta/meta.dart';
import 'package:postgres/postgres.dart';

import 'postgres_config.dart';

/// PostgreSQL implementation of EventStore and EventStream.
///
/// This class provides event sourcing capabilities using PostgreSQL:
/// - Event persistence with optimistic concurrency control
/// - Snapshot storage for aggregate state recovery
/// - Saga state management
/// - Event streaming for projections
class PostgresEventStore implements EventStore, EventStream {
  final _log = Logger('PostgresEventStore');
  final PostgresConfig _config;
  Pool? _pool;
  /// Events published after their transaction commits, with the journal
  /// position they were stored at. Live subscribers read from this so no
  /// per-event lookup is needed and ordering matches the journal.
  final StreamController<_PersistedEvent> _live =
      StreamController<_PersistedEvent>.broadcast();
  bool _isInitialized = false;
  bool _isClosed = false;

  /// Test hooks around each of a replay's journal page queries:
  /// [beforeReplayQuery] is awaited just before a page SELECT is issued and
  /// [afterReplayQuery] just after it returns, before any of its rows is
  /// emitted. They let a test park
  /// the replay and persist events at an exact point relative to the query's
  /// snapshot, which is otherwise a timing race. Never set in production.
  @visibleForTesting
  Future<void> Function()? beforeReplayQuery;
  @visibleForTesting
  Future<void> Function()? afterReplayQuery;

  /// Test hook awaited inside the append transaction after the version check
  /// and before the insert. Lets a test park one writer at exactly the point
  /// where a rival could slip in. Never set in production.
  @visibleForTesting
  Future<void> Function()? afterVersionCheck;

  /// Rows fetched per journal page by the event streams. Replays read the
  /// journal in keyset pages (`WHERE id > last ORDER BY id LIMIT n`) so a
  /// long journal is never loaded in one result set.
  @visibleForTesting
  int journalPageSize = 500;

  /// Number of INSERT statements issued into `event_envelopes`, for tests
  /// that check a batch is written in one round trip.
  @visibleForTesting
  int insertStatementCount = 0;

  /// Advisory lock class for per-persistence-id append locks (two-key form,
  /// so it never collides with the single-key migration lock).
  static const int _appendLockClass = 0x53504659; // 'SPFY'

  /// Rows per multi-row INSERT: 8 parameters each, well below the protocol's
  /// 65535 bind-parameter limit.
  static const int _maxRowsPerInsert = 1000;

  /// Creates a new PostgresEventStore with the given configuration.
  ///
  /// Call [initialize] before using the event store.
  PostgresEventStore(this._config);

  /// Initializes the event store.
  ///
  /// This must be called before using any other methods.
  Future<void> initialize() async {
    if (_isInitialized) return;
    _pool = await _config.createPool();
    _isInitialized = true;
  }

  void _ensureInitialized() {
    if (_isClosed) {
      throw StateError('PostgresEventStore has been closed.');
    }
    if (!_isInitialized || _pool == null) {
      throw StateError('PostgresEventStore not initialized. Call initialize() first.');
    }
  }

  // ============================================================================
  // EventStore Implementation
  // ============================================================================

  @override
  Future<void> persistEvent(
    String persistenceId,
    Event event,
    int expectedVersion,
  ) async {
    _ensureInitialized();
    final persisted = await _append(persistenceId, [event], expectedVersion);

    // Publish AFTER the transaction commits so a subscriber that re-reads the
    // row (or a projection that checkpoints the id) sees committed data.
    _publish(persisted.single);
  }

  @override
  Future<void> persistEvents(
    String persistenceId,
    List<Event> events,
    int expectedVersion,
  ) async {
    if (events.isEmpty) return;
    _ensureInitialized();
    final persisted = await _append(persistenceId, events, expectedVersion);

    // Publish after commit, in journal order
    for (final p in persisted) {
      _publish(p);
    }
  }

  /// Appends [events] to [persistenceId]'s journal in one transaction.
  ///
  /// Optimistic concurrency under READ COMMITTED: two writers with the same
  /// [expectedVersion] would both pass a plain `MAX(sequence_number)` check,
  /// and the loser would then hit `uk_persistence_sequence`. So the
  /// transaction first takes a transaction-scoped advisory lock on the
  /// persistence id; a rival writer waits there, and its version read (a new
  /// statement, hence a new snapshot) sees the winner's commit and fails with
  /// [ConcurrencyException]. A unique violation on that constraint (a writer
  /// that bypassed the lock) is reported as [ConcurrencyException] too.
  Future<List<_PersistedEvent>> _append(
    String persistenceId,
    List<Event> events,
    int expectedVersion,
  ) async {
    try {
      return await _pool!.runTx((session) async {
        await session.execute(
          Sql.named(
            'SELECT pg_advisory_xact_lock($_appendLockClass, '
            'hashtext(@persistenceId))',
          ),
          parameters: {'persistenceId': persistenceId},
        );

        final currentVersion =
            await _getHighestSequenceNumber(session, persistenceId);
        if (currentVersion != expectedVersion) {
          throw ConcurrencyException(
            'Expected version $expectedVersion, but current version is $currentVersion',
          );
        }
        await afterVersionCheck?.call();

        final stored = <_PersistedEvent>[];
        for (var start = 0; start < events.length; start += _maxRowsPerInsert) {
          final end = start + _maxRowsPerInsert < events.length
              ? start + _maxRowsPerInsert
              : events.length;
          stored.addAll(await _insertEvents(
            session,
            persistenceId,
            events.sublist(start, end),
            currentVersion + start + 1,
          ));
        }
        return stored;
      });
    } on ServerException catch (e) {
      if (e.code == '23505' && e.constraintName == 'uk_persistence_sequence') {
        throw ConcurrencyException(
          'Concurrent write to $persistenceId: the sequence number after '
          '$expectedVersion was already taken',
        );
      }
      rethrow;
    }
  }

  /// Inserts [events] with one multi-row INSERT, numbering them from
  /// [firstSequence], and returns them with the journal ids Postgres assigned.
  Future<List<_PersistedEvent>> _insertEvents(
    TxSession session,
    String persistenceId,
    List<Event> events,
    int firstSequence,
  ) async {
    final rows = <String>[];
    final parameters = <String, Object?>{'persistenceId': persistenceId};
    for (var i = 0; i < events.length; i++) {
      final event = events[i];
      // persistableMetadata drops transient ActorRef entries (eventador 3.0).
      final eventData =
          Uint8List.fromList(CborSerializer.serializeEvent(event));
      final metadataData = Uint8List.fromList(
        CborSerializer.serializeMetadata(event.persistableMetadata),
      );
      rows.add('(@persistenceId, @seq$i, @data$i, @type$i, @ts$i, @meta$i, '
          '@eid$i, @ver$i)');
      parameters['seq$i'] = firstSequence + i;
      parameters['data$i'] = TypedValue(Type.byteArray, eventData);
      parameters['type$i'] = event.typeName;
      parameters['ts$i'] = event.timestamp;
      parameters['meta$i'] = TypedValue(Type.byteArray, metadataData);
      parameters['eid$i'] = event.eventId;
      parameters['ver$i'] = event is VersionedEvent ? event.schemaVersion : 1;
    }

    insertStatementCount++;
    final result = await session.execute(
      Sql.named('''
        INSERT INTO event_envelopes (
          persistence_id, sequence_number, event_data, event_type,
          timestamp, metadata_data, event_id, schema_version
        ) VALUES ${rows.join(', ')}
        RETURNING id, sequence_number
      '''),
      parameters: parameters,
    );

    final idBySequence = {
      for (final row in result) row[1] as int: row[0] as int,
    };
    return [
      for (var i = 0; i < events.length; i++)
        _PersistedEvent(
          events[i],
          idBySequence[firstSequence + i]!,
          persistenceId,
          firstSequence + i,
        ),
    ];
  }

  void _publish(_PersistedEvent persisted) {
    if (!_live.isClosed) {
      _live.add(persisted);
    }
  }

  @override
  Future<List<Event>> getEvents(
    String persistenceId, {
    int fromSequence = 0,
    int? toSequence,
  }) async {
    _ensureInitialized();

    String sql = '''
      SELECT event_data, event_type, event_id
      FROM event_envelopes
      WHERE persistence_id = @persistenceId
        AND sequence_number > @fromSequence
    ''';

    final parameters = <String, dynamic>{
      'persistenceId': persistenceId,
      'fromSequence': fromSequence,
    };

    if (toSequence != null) {
      sql += ' AND sequence_number <= @toSequence';
      parameters['toSequence'] = toSequence;
    }

    sql += ' ORDER BY sequence_number ASC';

    try {
      final result = await _pool!.execute(
        Sql.named(sql),
        parameters: parameters,
      );

      final events = <Event>[];
      for (final row in result) {
        try {
          final eventData = row[0] as Uint8List;
          final eventType = row[1] as String;
          final event = CborSerializer.deserializeEvent(eventData, eventType);
          events.add(event);
        } catch (e) {
          final eventId = row[2] as String;
          throw EventStoreException(
            'Failed to deserialize event $eventId of type ${row[1]}',
            e,
          );
        }
      }

      return events;
    } catch (e) {
      if (e is EventStoreException) rethrow;
      throw EventStoreException('Failed to get events for $persistenceId', e);
    }
  }

  @override
  Future<int> getHighestSequenceNumber(String persistenceId) async {
    _ensureInitialized();
    try {
      return await _getHighestSequenceNumber(null, persistenceId);
    } catch (e) {
      throw EventStoreException(
        'Failed to get highest sequence number for $persistenceId',
        e,
      );
    }
  }

  Future<int> _getHighestSequenceNumber(
    TxSession? session,
    String persistenceId,
  ) async {
    final executor = session ?? _pool!;

    final result = await executor.execute(
      Sql.named('''
        SELECT COALESCE(MAX(sequence_number), 0) as max_seq
        FROM event_envelopes
        WHERE persistence_id = @persistenceId
      '''),
      parameters: {'persistenceId': persistenceId},
    );

    return result.first[0] as int;
  }

  @override
  Future<void> saveSnapshot(
    String persistenceId,
    dynamic state,
    int sequenceNumber,
  ) async {
    _ensureInitialized();

    try {
      // Convert List<int> to Uint8List for PostgreSQL BYTEA columns
      final snapshotData =
          Uint8List.fromList(CborSerializer.serializeState(state));
      final metadataData = Uint8List.fromList(
        CborSerializer.serializeMetadata(<String, String>{}),
      );

      await _pool!.execute(
        Sql.named('''
          INSERT INTO snapshot_envelopes (
            persistence_id, sequence_number, snapshot_data, timestamp,
            state_type, schema_version, size_bytes, metadata_data
          ) VALUES (
            @persistenceId, @sequenceNumber, @snapshotData, @timestamp,
            @stateType, @schemaVersion, @sizeBytes, @metadataData
          )
          ON CONFLICT (persistence_id) DO UPDATE SET
            sequence_number = EXCLUDED.sequence_number,
            snapshot_data = EXCLUDED.snapshot_data,
            timestamp = EXCLUDED.timestamp,
            state_type = EXCLUDED.state_type,
            schema_version = EXCLUDED.schema_version,
            size_bytes = EXCLUDED.size_bytes,
            metadata_data = EXCLUDED.metadata_data
        '''),
        parameters: {
          'persistenceId': persistenceId,
          'sequenceNumber': sequenceNumber,
          'snapshotData': TypedValue(Type.byteArray, snapshotData),
          'timestamp': DateTime.now(),
          'stateType':
              state is State ? state.typeName : state.runtimeType.toString(),
          'schemaVersion': 1,
          'sizeBytes': snapshotData.length,
          'metadataData': TypedValue(Type.byteArray, metadataData),
        },
      );
    } catch (e) {
      throw EventStoreException(
        'Failed to save snapshot for $persistenceId',
        e,
      );
    }
  }

  @override
  Future<SnapshotData?> loadSnapshot(String persistenceId) async {
    _ensureInitialized();

    try {
      final result = await _pool!.execute(
        Sql.named('''
          SELECT snapshot_data, sequence_number, timestamp, state_type
          FROM snapshot_envelopes
          WHERE persistence_id = @persistenceId
        '''),
        parameters: {'persistenceId': persistenceId},
      );

      if (result.isEmpty) return null;

      final row = result.first;
      final state = CborSerializer.deserializeState(
        row[0] as Uint8List,
        row[3] as String,
      );

      return SnapshotData(
        state: state,
        sequenceNumber: row[1] as int,
        timestamp: row[2] as DateTime,
      );
    } catch (e) {
      throw EventStoreException(
        'Failed to load snapshot for $persistenceId',
        e,
      );
    }
  }

  @override
  Future<void> deleteOldSnapshots(String persistenceId, int keepCount) async {
    _ensureInitialized();

    // Only one snapshot is kept per persistence id (unique constraint), so
    // there is nothing to trim for keepCount > 0.
    if (keepCount > 0) return;
    try {
      await _pool!.execute(
        Sql.named(
          'DELETE FROM snapshot_envelopes WHERE persistence_id = @persistenceId',
        ),
        parameters: {'persistenceId': persistenceId},
      );
    } catch (e) {
      throw EventStoreException(
        'Failed to delete old snapshots for $persistenceId',
        e,
      );
    }
  }

  @override
  Future<void> close() async {
    _isClosed = true;
    await _live.close();
    await _pool?.close();
    _pool = null;
    _isInitialized = false;
  }

  // ============================================================================
  // EventStream Implementation
  // ============================================================================

  @override
  Stream<Event> allEvents({
    int fromSequence = 0,
    bool live = true,
  }) {
    return allEventsWithSequence(fromSequence: fromSequence, live: live)
        .map((pair) => pair.$1);
  }

  @override
  Stream<(Event, int)> allEventsWithSequence({
    int fromSequence = 0,
    bool live = true,
  }) {
    _ensureInitialized();
    final historical = _journalAfterId(fromSequence);
    final source = live
        ? _replayThenLive(
            from: fromSequence,
            historical: historical,
            keyOf: (p) => p.envelopeId,
          )
        : historical;
    return source.map((p) => (p.event, p.envelopeId));
  }

  @override
  Stream<Event> eventsByTag(
    String tag, {
    int fromSequence = 0,
    bool live = true,
  }) {
    // Tags come from the EventTags mixin, as in eventador's IsarEventStore.
    // A `tags` list in event metadata is still honoured as a fallback, since
    // earlier versions of this store matched on that alone.
    return allEvents(fromSequence: fromSequence, live: live).where((event) {
      if (event is EventTags && event.tags.contains(tag)) return true;
      final tags = event.metadata['tags'];
      return tags is List && tags.contains(tag);
    });
  }

  @override
  Stream<Event> eventsByPersistenceId(
    String persistenceId, {
    int fromSequence = 0,
    bool live = true,
  }) {
    _ensureInitialized();
    final historical = _journalForActorAfter(persistenceId, fromSequence);
    final source = live
        ? _replayThenLive(
            from: fromSequence,
            historical: historical,
            keyOf: (p) => p.sequenceNumber,
            accept: (p) => p.persistenceId == persistenceId,
          )
        : historical;
    return source.map((p) => p.event);
  }

  /// Every journal row with `id > fromId`, in id order, read in keyset
  /// pages of [journalPageSize] rows.
  Stream<_PersistedEvent> _journalAfterId(int fromId) async* {
    var lastId = fromId;
    while (true) {
      final pageSize = journalPageSize < 1 ? 1 : journalPageSize;
      await beforeReplayQuery?.call();
      final page = await _pool!.execute(
        Sql.named('''
          SELECT id, persistence_id, sequence_number, event_data, event_type, event_id
          FROM event_envelopes
          WHERE id > @lastId
          ORDER BY id ASC
          LIMIT @pageSize
        '''),
        parameters: {'lastId': lastId, 'pageSize': pageSize},
      );
      await afterReplayQuery?.call();
      for (final row in page) {
        // Advance past every row, including one that fails to decode.
        lastId = row[0] as int;
        final p = _rowToPersisted(row);
        if (p != null) yield p;
      }
      if (page.length < pageSize) break;
    }
  }

  /// One actor's journal rows with `sequence_number > fromSequence`, in
  /// order, read in keyset pages of [journalPageSize] rows.
  Stream<_PersistedEvent> _journalForActorAfter(
    String persistenceId,
    int fromSequence,
  ) async* {
    var lastSequence = fromSequence;
    while (true) {
      final pageSize = journalPageSize < 1 ? 1 : journalPageSize;
      await beforeReplayQuery?.call();
      final page = await _pool!.execute(
        Sql.named('''
          SELECT id, persistence_id, sequence_number, event_data, event_type, event_id
          FROM event_envelopes
          WHERE persistence_id = @persistenceId
            AND sequence_number > @lastSequence
          ORDER BY sequence_number ASC
          LIMIT @pageSize
        '''),
        parameters: {
          'persistenceId': persistenceId,
          'lastSequence': lastSequence,
          'pageSize': pageSize,
        },
      );
      await afterReplayQuery?.call();
      for (final row in page) {
        lastSequence = row[2] as int;
        final p = _rowToPersisted(row);
        if (p != null) yield p;
      }
      if (page.length < pageSize) break;
    }
  }

  _PersistedEvent? _rowToPersisted(ResultRow row) {
    final id = row[0] as int;
    final persistenceId = row[1] as String;
    final sequenceNumber = row[2] as int;
    final eventType = row[4] as String;
    try {
      final event = CborSerializer.deserializeEvent(
        row[3] as Uint8List,
        eventType,
      );
      return _PersistedEvent(event, id, persistenceId, sequenceNumber);
    } catch (e) {
      // An undeserializable row (unregistered type, bad bytes) is skipped so a
      // projection is not wedged forever on it; the id is logged so the
      // operator can find it.
      _log.warning(
        'Skipping event id=$id eventId=${row[5]} type=$eventType '
        '($persistenceId#$sequenceNumber): $e',
      );
      return null;
    }
  }

  /// Replays [historical], then continues with live events.
  ///
  /// The live subscription is opened *before* the replay starts, and live
  /// events arriving during the replay are buffered and drained afterwards,
  /// so nothing persisted while the replay runs can be missed. [keyOf] gives
  /// the monotonic position used to drop anything already seen (an event that
  /// was both read from the journal and received live). Mirrors
  /// eventador's IsarEventStore.
  Stream<_PersistedEvent> _replayThenLive({
    required int from,
    required Stream<_PersistedEvent> historical,
    required int Function(_PersistedEvent) keyOf,
    bool Function(_PersistedEvent)? accept,
  }) {
    late final StreamController<_PersistedEvent> controller;
    StreamSubscription<_PersistedEvent>? liveSub;
    var lastKey = from;
    var replaying = true;
    var cancelled = false;
    final pending = <_PersistedEvent>[];

    void emit(_PersistedEvent p) {
      if (cancelled || controller.isClosed) return;
      if (accept != null && !accept(p)) return;
      final key = keyOf(p);
      if (key > lastKey) {
        lastKey = key;
        controller.add(p);
      }
    }

    Future<void> replay() async {
      try {
        await for (final p in historical) {
          if (cancelled) return;
          emit(p);
        }
        // No await between here and the end of the drain, so no live event
        // can slip in between the buffered ones and pass-through mode.
        replaying = false;
        for (final p in pending) {
          emit(p);
        }
        pending.clear();
      } catch (e, s) {
        if (!controller.isClosed) {
          controller.addError(e, s);
          await controller.close();
        }
      }
    }

    controller = StreamController<_PersistedEvent>(
      onListen: () {
        // Subscribe to live events first so nothing persisted during the
        // replay can be missed.
        liveSub = _live.stream.listen(
          (p) {
            if (replaying) {
              pending.add(p);
            } else {
              emit(p);
            }
          },
          onError: (Object e, StackTrace s) {
            if (!controller.isClosed) controller.addError(e, s);
          },
          onDone: () {
            if (!controller.isClosed) controller.close();
          },
        );
        replay();
      },
      onCancel: () async {
        cancelled = true;
        await liveSub?.cancel();
        liveSub = null;
      },
    );

    return controller.stream;
  }

  @override
  Stream<String> currentPersistenceIds() async* {
    _ensureInitialized();

    final result = await _pool!.execute(
      'SELECT DISTINCT persistence_id FROM event_envelopes ORDER BY persistence_id',
    );

    for (final row in result) {
      final id = row[0] as String?;
      if (id != null) {
        yield id;
      }
    }
  }
}

/// An event together with where it landed in the journal.
class _PersistedEvent {
  final Event event;

  /// The `id` column: the global journal position.
  final int envelopeId;
  final String persistenceId;

  /// Position within [persistenceId]'s own journal.
  final int sequenceNumber;

  const _PersistedEvent(
    this.event,
    this.envelopeId,
    this.persistenceId,
    this.sequenceNumber,
  );
}
