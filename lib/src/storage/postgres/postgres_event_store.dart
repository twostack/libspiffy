/// PostgreSQL-based event store for libspiffy.
///
/// Implements Eventador's EventStore and EventStream interfaces using PostgreSQL
/// as the persistence layer.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:eventador/eventador.dart';
import 'package:eventador/src/storage/event_stream.dart';
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
  final PostgresConfig _config;
  Pool? _pool;
  final StreamController<Event> _eventStreamController =
      StreamController<Event>.broadcast();
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

    await _pool!.runTx((session) async {
      // Check optimistic concurrency
      final currentVersion = await _getHighestSequenceNumber(session, persistenceId);
      if (currentVersion != expectedVersion) {
        throw ConcurrencyException(
          'Expected version $expectedVersion, but current version is $currentVersion',
        );
      }

      final nextSequence = currentVersion + 1;

      // Serialize event and metadata, convert to Uint8List for BYTEA columns
      final eventData = Uint8List.fromList(CborSerializer.serializeEvent(event));
      final metadataData = Uint8List.fromList(CborSerializer.serializeMetadata(
        event.metadata.cast<String, String>(),
      ));

      // Insert event
      await session.execute(
        Sql.named('''
          INSERT INTO event_envelopes (
            persistence_id, sequence_number, event_data, event_type,
            timestamp, metadata_data, event_id, schema_version
          ) VALUES (
            @persistenceId, @sequenceNumber, @eventData, @eventType,
            @timestamp, @metadataData, @eventId, @schemaVersion
          )
        '''),
        parameters: {
          'persistenceId': persistenceId,
          'sequenceNumber': nextSequence,
          'eventData': TypedValue(Type.byteArray, eventData),
          'eventType': event.runtimeType.toString(),
          'timestamp': event.timestamp,
          'metadataData': TypedValue(Type.byteArray, metadataData),
          'eventId': event.eventId,
          'schemaVersion': event is VersionedEvent ? event.schemaVersion : 1,
        },
      );
    });

    // Emit to local stream for in-process listeners
    _eventStreamController.add(event);
  }

  @override
  Future<void> persistEvents(
    String persistenceId,
    List<Event> events,
    int expectedVersion,
  ) async {
    if (events.isEmpty) return;

    _ensureInitialized();

    await _pool!.runTx((session) async {
      // Check optimistic concurrency
      final currentVersion = await _getHighestSequenceNumber(session, persistenceId);
      if (currentVersion != expectedVersion) {
        throw ConcurrencyException(
          'Expected version $expectedVersion, but current version is $currentVersion',
        );
      }

      // Insert all events
      for (var i = 0; i < events.length; i++) {
        final event = events[i];
        final nextSequence = currentVersion + i + 1;

        // Serialize and convert to Uint8List for BYTEA columns
        final eventData = Uint8List.fromList(CborSerializer.serializeEvent(event));
        final metadataData = Uint8List.fromList(CborSerializer.serializeMetadata(
          event.metadata.cast<String, String>(),
        ));

        await session.execute(
          Sql.named('''
            INSERT INTO event_envelopes (
              persistence_id, sequence_number, event_data, event_type,
              timestamp, metadata_data, event_id, schema_version
            ) VALUES (
              @persistenceId, @sequenceNumber, @eventData, @eventType,
              @timestamp, @metadataData, @eventId, @schemaVersion
            )
          '''),
          parameters: {
            'persistenceId': persistenceId,
            'sequenceNumber': nextSequence,
            'eventData': TypedValue(Type.byteArray, eventData),
            'eventType': event.runtimeType.toString(),
            'timestamp': event.timestamp,
            'metadataData': TypedValue(Type.byteArray, metadataData),
            'eventId': event.eventId,
            'schemaVersion': event is VersionedEvent ? event.schemaVersion : 1,
          },
        );
      }
    });

    // Emit to local stream
    for (final event in events) {
      _eventStreamController.add(event);
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
        'stateType': state.runtimeType.toString(),
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
  Future<void> saveSagaState(SagaStateEnvelope envelope) async {
    _ensureInitialized();

    // stateData is already CBOR-encoded (List<int>) in SagaStateEnvelope
    final stateData = Uint8List.fromList(envelope.stateData);

    await _pool!.execute(
      Sql.named('''
        INSERT INTO saga_state_envelopes (
          persistence_id, state_data, state_type, status, last_updated_at
        ) VALUES (
          @persistenceId, @stateData, @stateType, @status, @lastUpdatedAt
        )
        ON CONFLICT (persistence_id) DO UPDATE SET
          state_data = @stateData,
          state_type = @stateType,
          status = @status,
          last_updated_at = @lastUpdatedAt
      '''),
      parameters: {
        'persistenceId': envelope.persistenceId,
        'stateData': TypedValue(Type.byteArray, stateData),
        'stateType': envelope.stateType,
        'status': envelope.status.name,
        'lastUpdatedAt': envelope.lastUpdatedAt,
      },
    );
  }

  @override
  Future<SagaStateEnvelope?> loadSagaState(String persistenceId) async {
    _ensureInitialized();

    final result = await _pool!.execute(
      Sql.named('''
        SELECT state_data, state_type, status, last_updated_at
        FROM saga_state_envelopes
        WHERE persistence_id = @persistenceId
      '''),
      parameters: {'persistenceId': persistenceId},
    );

    if (result.isEmpty) return null;

    final row = result.first;
    final stateData = row[0] as Uint8List;
    final stateType = row[1] as String;
    final statusStr = row[2] as String;
    final lastUpdatedAt = row[3] as DateTime;

    // Parse status enum
    final status = SagaStatus.values.firstWhere(
      (s) => s.name == statusStr,
      orElse: () => SagaStatus.running,
    );

    // SagaStateEnvelope uses default constructor with cascade assignment
    return SagaStateEnvelope()
      ..persistenceId = persistenceId
      ..stateData = stateData.toList() // Convert Uint8List to List<int>
      ..stateType = stateType
      ..status = status
      ..lastUpdatedAt = lastUpdatedAt;
  }

  @override
  Future<void> close() async {
    _isClosed = true;
    await _eventStreamController.close();
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
  }) async* {
    _ensureInitialized();

    // Replay historical events
    final result = await _pool!.execute(
      Sql.named('''
        SELECT id, event_data, event_type
        FROM event_envelopes
        WHERE id > @fromSequence
        ORDER BY id ASC
      '''),
      parameters: {'fromSequence': fromSequence},
    );

    for (final row in result) {
      try {
        final eventData = row[1] as Uint8List;
        final eventType = row[2] as String;
        final event = CborSerializer.deserializeEvent(eventData, eventType);
        yield event;
      } catch (e) {
        print('Error deserializing event: $e');
      }
    }

    // If live mode, subscribe to new events
    if (live) {
      yield* _eventStreamController.stream;
    }
  }

  @override
  Stream<(Event, int)> allEventsWithSequence({
    int fromSequence = 0,
    bool live = true,
  }) async* {
    _ensureInitialized();

    // Replay historical events with sequence numbers
    final result = await _pool!.execute(
      Sql.named('''
        SELECT id, event_data, event_type
        FROM event_envelopes
        WHERE id > @fromSequence
        ORDER BY id ASC
      '''),
      parameters: {'fromSequence': fromSequence},
    );

    int lastSeenId = fromSequence;
    for (final row in result) {
      final id = row[0] as int;
      try {
        final eventData = row[1] as Uint8List;
        final eventType = row[2] as String;
        final event = CborSerializer.deserializeEvent(eventData, eventType);
        lastSeenId = id;
        yield (event, id);
      } catch (e) {
        print('Error deserializing event: $e');
      }
    }

    // If live mode, continue with new events
    if (live) {
      await for (final event in _eventStreamController.stream) {
        // Get the sequence number for this event
        final seqResult = await _pool!.execute(
          Sql.named('SELECT id FROM event_envelopes WHERE event_id = @eventId'),
          parameters: {'eventId': event.eventId},
        );
        if (seqResult.isNotEmpty) {
          final id = seqResult.first[0] as int;
          if (id > lastSeenId) {
            lastSeenId = id;
            yield (event, id);
          }
        }
      }
    }
  }

  @override
  Stream<Event> eventsByTag(
    String tag, {
    int fromSequence = 0,
    bool live = true,
  }) async* {
    // Filter events by tag - check if event implements tag interface
    await for (final event in allEvents(fromSequence: fromSequence, live: live)) {
      // Check if event has tags (simplified - full implementation would check EventTags mixin)
      final metadata = event.metadata;
      if (metadata.containsKey('tags')) {
        final tags = metadata['tags'];
        if (tags is List && tags.contains(tag)) {
          yield event;
        }
      }
    }
  }

  @override
  Stream<Event> eventsByPersistenceId(
    String persistenceId, {
    int fromSequence = 0,
    bool live = true,
  }) async* {
    _ensureInitialized();

    // Replay historical events for this persistence ID
    final result = await _pool!.execute(
      Sql.named('''
        SELECT event_data, event_type
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
      try {
        final eventData = row[0] as Uint8List;
        final eventType = row[1] as String;
        final event = CborSerializer.deserializeEvent(eventData, eventType);
        yield event;
      } catch (e) {
        print('Error deserializing event: $e');
      }
    }

    // Live mode - filter stream by persistence ID (simplified)
    if (live) {
      yield* _eventStreamController.stream;
    }
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
