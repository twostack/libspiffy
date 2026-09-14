/// PostgreSQL-based event store for libspiffy.
///
/// Implements Eventador's EventStore and EventStream interfaces using PostgreSQL
/// as the persistence layer.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:eventador/eventador.dart';
import 'package:logging/logging.dart';

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

    final persisted = await _pool!.runTx((session) async {
      // Check optimistic concurrency
      final currentVersion = await _getHighestSequenceNumber(session, persistenceId);
      if (currentVersion != expectedVersion) {
        throw ConcurrencyException(
          'Expected version $expectedVersion, but current version is $currentVersion',
        );
      }

      return _insertEvent(session, persistenceId, event, currentVersion + 1);
    });

    // Publish AFTER the transaction commits so a subscriber that re-reads the
    // row (or a projection that checkpoints the id) sees committed data.
    _publish(persisted);
  }

  /// Inserts one envelope and returns it with the journal id Postgres assigned.
  Future<_PersistedEvent> _insertEvent(
    TxSession session,
    String persistenceId,
    Event event,
    int sequenceNumber,
  ) async {
    // Serialize event and metadata, convert to Uint8List for BYTEA columns.
    // persistableMetadata drops transient ActorRef entries (eventador 3.0).
    final eventData = Uint8List.fromList(CborSerializer.serializeEvent(event));
    final metadataData = Uint8List.fromList(
      CborSerializer.serializeMetadata(event.persistableMetadata),
    );

    final result = await session.execute(
      Sql.named('''
        INSERT INTO event_envelopes (
          persistence_id, sequence_number, event_data, event_type,
          timestamp, metadata_data, event_id, schema_version
        ) VALUES (
          @persistenceId, @sequenceNumber, @eventData, @eventType,
          @timestamp, @metadataData, @eventId, @schemaVersion
        )
        RETURNING id
      '''),
      parameters: {
        'persistenceId': persistenceId,
        'sequenceNumber': sequenceNumber,
        'eventData': TypedValue(Type.byteArray, eventData),
        'eventType': event.typeName,
        'timestamp': event.timestamp,
        'metadataData': TypedValue(Type.byteArray, metadataData),
        'eventId': event.eventId,
        'schemaVersion': event is VersionedEvent ? event.schemaVersion : 1,
      },
    );
    final id = result.first[0] as int;
    return _PersistedEvent(event, id, persistenceId, sequenceNumber);
  }

  void _publish(_PersistedEvent persisted) {
    if (!_live.isClosed) {
      _live.add(persisted);
    }
  }

  @override
  Future<void> persistEvents(
    String persistenceId,
    List<Event> events,
    int expectedVersion,
  ) async {
    if (events.isEmpty) return;

    _ensureInitialized();

    final persisted = await _pool!.runTx((session) async {
      // Check optimistic concurrency
      final currentVersion = await _getHighestSequenceNumber(session, persistenceId);
      if (currentVersion != expectedVersion) {
        throw ConcurrencyException(
          'Expected version $expectedVersion, but current version is $currentVersion',
        );
      }

      // Insert all events atomically
      final stored = <_PersistedEvent>[];
      for (var i = 0; i < events.length; i++) {
        stored.add(await _insertEvent(
          session, persistenceId, events[i], currentVersion + i + 1,
        ));
      }
      return stored;
    });

    // Publish after commit, in journal order
    for (final p in persisted) {
      _publish(p);
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
  }

  @override
  Future<int> getHighestSequenceNumber(String persistenceId) async {
    _ensureInitialized();
    return _getHighestSequenceNumber(null, persistenceId);
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

    final snapshotDataList = CborSerializer.serializeState(state);
    final metadataDataList = CborSerializer.serializeMetadata(<String, String>{});

    // Convert List<int> to Uint8List for PostgreSQL BYTEA columns
    final snapshotData = Uint8List.fromList(snapshotDataList);
    final metadataData = Uint8List.fromList(metadataDataList);

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
          sequence_number = @sequenceNumber,
          snapshot_data = @snapshotData,
          timestamp = @timestamp,
          state_type = @stateType,
          size_bytes = @sizeBytes,
          metadata_data = @metadataData
      '''),
      parameters: {
        'persistenceId': persistenceId,
        'sequenceNumber': sequenceNumber,
        'snapshotData': TypedValue(Type.byteArray, snapshotData),
        'timestamp': DateTime.now(),
        'stateType': state is State ? state.typeName : state.runtimeType.toString(),
        'schemaVersion': 1,
        'sizeBytes': snapshotData.length,
        'metadataData': TypedValue(Type.byteArray, metadataData),
      },
    );
  }

  @override
  Future<SnapshotData?> loadSnapshot(String persistenceId) async {
    _ensureInitialized();

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
    final snapshotData = row[0] as Uint8List;
    final sequenceNumber = row[1] as int;
    final timestamp = row[2] as DateTime;
    final stateType = row[3] as String;

    final state = CborSerializer.deserializeState(snapshotData, stateType);

    return SnapshotData(
      state: state,
      sequenceNumber: sequenceNumber,
      timestamp: timestamp,
    );
  }

  @override
  Future<void> deleteOldSnapshots(String persistenceId, int keepCount) async {
    _ensureInitialized();

    if (keepCount <= 0) {
      await _pool!.execute(
        Sql.named('DELETE FROM snapshot_envelopes WHERE persistence_id = @persistenceId'),
        parameters: {'persistenceId': persistenceId},
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
    // Tags are carried in event metadata under 'tags' (List<String>).
    return allEvents(fromSequence: fromSequence, live: live).where((event) {
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

  /// Every journal row with `id > fromId`, in id order.
  Stream<_PersistedEvent> _journalAfterId(int fromId) async* {
    final result = await _pool!.execute(
      Sql.named('''
        SELECT id, persistence_id, sequence_number, event_data, event_type, event_id
        FROM event_envelopes
        WHERE id > @fromId
        ORDER BY id ASC
      '''),
      parameters: {'fromId': fromId},
    );
    for (final row in result) {
      final p = _rowToPersisted(row);
      if (p != null) yield p;
    }
  }

  /// One actor's journal rows with `sequence_number > fromSequence`, in order.
  Stream<_PersistedEvent> _journalForActorAfter(
    String persistenceId,
    int fromSequence,
  ) async* {
    final result = await _pool!.execute(
      Sql.named('''
        SELECT id, persistence_id, sequence_number, event_data, event_type, event_id
        FROM event_envelopes
        WHERE persistence_id = @persistenceId
          AND sequence_number > @fromSequence
        ORDER BY sequence_number ASC
      '''),
      parameters: {
        'persistenceId': persistenceId,
        'fromSequence': fromSequence,
      },
    );
    for (final row in result) {
      final p = _rowToPersisted(row);
      if (p != null) yield p;
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
