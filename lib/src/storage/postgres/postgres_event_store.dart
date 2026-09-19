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
///
/// ## Journal order
///
/// Journal ids (`BIGSERIAL`) are allocated at INSERT time, but appends to
/// different persistence ids commit in any order, so the id order is not the
/// order in which rows become visible. The global streams
/// ([allEventsWithSequence], [allEvents], [eventsByTag]) therefore read in
/// *commit-horizon order*: each row carries the id of the transaction that
/// wrote it (`tx_id`, migration v008), a read only takes rows whose
/// transaction is older than the oldest transaction still running
/// (`pg_snapshot_xmin(pg_current_snapshot())`), and rows are ordered by
/// `(tx_id, id)`. Every transaction that can still commit then sorts after
/// everything already delivered, so a cursor never passes a row that becomes
/// visible later. Appends that do not overlap in time are delivered in id
/// order; overlapping appends may be delivered with a later id first. The
/// sequence reported with each event is still its journal id: resuming from
/// an id continues after that row's `(tx_id, id)` position.
///
/// A transaction that stays open holds the horizon back, so a writing
/// transaction left open anywhere on the server (the horizon is
/// cluster-wide) delays delivery until it ends. Nothing is lost or reordered.
///
/// [eventsByPersistenceId] reads one actor's journal by sequence number;
/// appends to one persistence id are serialised, so no horizon is needed.
///
/// Live streams re-read the journal from their own cursor whenever this
/// instance commits an append and, when [livePollInterval] is set, on that
/// interval, which also delivers appends made by other processes.
class PostgresEventStore implements EventStore, EventStream {
  final _log = Logger('PostgresEventStore');
  final PostgresConfig _config;
  Pool? _pool;
  bool _isInitialized = false;
  bool _isClosed = false;

  /// How often an idle live stream re-reads the journal. Appends made by this
  /// instance wake its live streams at once; this interval bounds how late a
  /// live stream sees appends made by another process (or another store
  /// instance). `null` disables polling: other writers' events then arrive
  /// only with this instance's next append.
  final Duration? livePollInterval;

  /// Highest `tx_id` this instance has committed an append under.
  int _maxCommittedTx = -1;

  /// Incremented on every append this instance commits.
  int _commitGeneration = 0;

  /// Idle live streams, woken by the next append this instance commits and
  /// by [close].
  final Set<Completer<void>> _waiters = {};

  /// Shortest and longest wait before a live stream re-reads a journal whose
  /// horizon has not yet passed an append this instance committed.
  static const Duration _minHorizonRetry = Duration(milliseconds: 2);
  static const Duration _maxHorizonRetry = Duration(milliseconds: 200);

  /// Test hooks around each of a replay's journal page queries:
  /// [beforeReplayQuery] is awaited just before a page SELECT is issued and
  /// [afterReplayQuery] just after it returns, before any of its rows is
  /// emitted. They let a test park
  /// the replay and persist events at an exact point relative to the query's
  /// snapshot, which is otherwise a timing race. They run for the replay's
  /// pages only, not for a live stream's later re-reads. Never set in
  /// production.
  @visibleForTesting
  Future<void> Function()? beforeReplayQuery;
  @visibleForTesting
  Future<void> Function()? afterReplayQuery;

  /// Test hook awaited inside the append transaction after the version check
  /// and before the insert. Lets a test park one writer at exactly the point
  /// where a rival could slip in. Never set in production.
  @visibleForTesting
  Future<void> Function()? afterVersionCheck;

  /// Test hook awaited inside the append transaction after the insert and
  /// before COMMIT: the rows hold journal ids but are not visible yet.
  /// Never set in production.
  @visibleForTesting
  Future<void> Function(String persistenceId)? beforeCommit;

  /// Test hook awaited after the append transaction committed and before
  /// this instance wakes its live streams. Never set in production.
  @visibleForTesting
  Future<void> Function(String persistenceId)? afterCommit;

  /// Rows fetched per journal page by the event streams. Streams read the
  /// journal in keyset pages so a long journal is never loaded in one result
  /// set.
  @visibleForTesting
  int journalPageSize = 500;

  /// Number of INSERT statements issued into `event_envelopes`, for tests
  /// that check a batch is written in one round trip.
  @visibleForTesting
  int insertStatementCount = 0;

  /// Number of journal page queries that have returned (replays and live
  /// re-reads), so a test can wait until a stream has read the journal.
  @visibleForTesting
  int journalReadCount = 0;

  /// Distinct persistence ids fetched per page by [currentPersistenceIds].
  /// One page is one round trip.
  @visibleForTesting
  int persistenceIdPageSize = 500;

  /// Number of page queries [currentPersistenceIds] has issued, so a test
  /// can check that it pages instead of reading the journal in one query.
  @visibleForTesting
  int persistenceIdQueryCount = 0;

  /// Test hook called with the SQL and parameters of each
  /// [currentPersistenceIds] page, just before the query is issued, so a
  /// test can EXPLAIN the statement the store really runs rather than a copy
  /// of it. Never set in production.
  @visibleForTesting
  void Function(String sql, Map<String, Object?> parameters)?
      onPersistenceIdsQuery;

  /// Advisory lock class for per-persistence-id append locks (two-key form,
  /// so it never collides with the single-key migration lock).
  static const int _appendLockClass = 0x53504659; // 'SPFY'

  /// Rows per multi-row INSERT: 8 parameters each, well below the protocol's
  /// 65535 bind-parameter limit.
  static const int _maxRowsPerInsert = 1000;

  /// Creates a new PostgresEventStore with the given configuration.
  ///
  /// Call [initialize] before using the event store. See [livePollInterval].
  PostgresEventStore(
    this._config, {
    this.livePollInterval = const Duration(seconds: 1),
  });

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
    final txId = await _append(persistenceId, [event], expectedVersion);
    await afterCommit?.call(persistenceId);
    _notifyCommitted(txId);
  }

  @override
  Future<void> persistEvents(
    String persistenceId,
    List<Event> events,
    int expectedVersion,
  ) async {
    if (events.isEmpty) return;
    _ensureInitialized();
    final txId = await _append(persistenceId, events, expectedVersion);
    await afterCommit?.call(persistenceId);
    _notifyCommitted(txId);
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
  ///
  /// Every *other* failure — any other server error (a duplicate
  /// `event_id`, a value too long for its column, a permission or
  /// connection error), a serialization failure, anything — is reported as
  /// [EventStoreException] naming the persistence id, rather than escaping
  /// as the driver's raw [ServerException]. Nothing is swallowed: the
  /// original is the exception's `cause`, and it is thrown with the original
  /// stack trace, so the driver's message, SQLSTATE and call site all stay
  /// reachable. Only [ConcurrencyException] — which callers retry — is
  /// distinguished, and it is never manufactured from an error that is not
  /// an optimistic-locking conflict.
  ///
  /// Returns the id of the transaction the events were written under.
  Future<int> _append(
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

        var txId = -1;
        for (var start = 0; start < events.length; start += _maxRowsPerInsert) {
          final end = start + _maxRowsPerInsert < events.length
              ? start + _maxRowsPerInsert
              : events.length;
          txId = await _insertEvents(
            session,
            persistenceId,
            events.sublist(start, end),
            currentVersion + start + 1,
          );
        }
        await beforeCommit?.call(persistenceId);
        return txId;
      });
    } on ConcurrencyException {
      rethrow;
    } on EventStoreException {
      rethrow;
    } on ServerException catch (e, stackTrace) {
      if (e.code == '23505' && e.constraintName == 'uk_persistence_sequence') {
        throw ConcurrencyException(
          'Concurrent write to $persistenceId: the sequence number after '
          '$expectedVersion was already taken',
        );
      }
      Error.throwWithStackTrace(
        EventStoreException(
          'Failed to append ${events.length} event(s) to $persistenceId '
          '(SQLSTATE ${e.code}'
          '${e.constraintName == null ? '' : ', constraint ${e.constraintName}'}'
          ')',
          e,
        ),
        stackTrace,
      );
    } catch (e, stackTrace) {
      Error.throwWithStackTrace(
        EventStoreException(
          'Failed to append ${events.length} event(s) to $persistenceId',
          e,
        ),
        stackTrace,
      );
    }
  }

  /// Inserts [events] with one multi-row INSERT, numbering them from
  /// [firstSequence], and returns the id of the writing transaction (the
  /// `tx_id` column's default).
  Future<int> _insertEvents(
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
        RETURNING tx_id
      '''),
      parameters: parameters,
    );
    return result.first[0] as int;
  }

  /// Records a committed append and wakes this instance's live streams.
  void _notifyCommitted(int txId) {
    if (txId > _maxCommittedTx) _maxCommittedTx = txId;
    _commitGeneration++;
    _wakeWaiters();
  }

  void _wakeWaiters() {
    final waiters = _waiters.toList();
    _waiters.clear();
    for (final c in waiters) {
      if (!c.isCompleted) c.complete();
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
    _wakeWaiters();
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

  /// Streams the whole journal in commit-horizon order (see the class
  /// documentation), each event with its journal id.
  ///
  /// [fromSequence] is a journal id this stream delivered before (a
  /// projection checkpoint): the stream continues after that row's position.
  /// For an id with no row it continues after the row with the greatest
  /// lower id; `0` (or less) starts at the beginning.
  @override
  Stream<(Event, int)> allEventsWithSequence({
    int fromSequence = 0,
    bool live = true,
  }) {
    _ensureInitialized();
    return _tail(
      start: () => _journalPositionOf(fromSequence),
      readPage: _readJournalPage,
      live: live,
    ).map((p) => (p.event, p.envelopeId));
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
    return _tail(
      start: () async => (tx: 0, id: fromSequence),
      readPage: (after, limit) =>
          _readActorPage(persistenceId, after.id, limit),
      live: live,
    ).map((p) => p.event);
  }

  /// The `(tx_id, id)` position a global stream resumes after, for the
  /// journal id [fromId].
  Future<_Position> _journalPositionOf(int fromId) async {
    const beginning = (tx: -1, id: 0);
    if (fromId <= 0) return beginning;
    final result = await _pool!.execute(
      Sql.named('''
        SELECT tx_id, id FROM event_envelopes
        WHERE id <= @fromId
        ORDER BY id DESC
        LIMIT 1
      '''),
      parameters: {'fromId': fromId},
    );
    if (result.isEmpty) return beginning;
    return (tx: result.first[0] as int, id: result.first[1] as int);
  }

  /// Up to [limit] journal rows after [after] in `(tx_id, id)` order, taking
  /// only rows written by transactions older than every transaction still
  /// running when the statement's snapshot was taken. Those rows are all
  /// committed (or rolled back) and visible, and any row that commits later
  /// has a higher `tx_id`, so the cursor never passes a row that appears
  /// later. The page also reports that horizon.
  Future<_JournalPage> _readJournalPage(_Position after, int limit) async {
    final result = await _pool!.execute(
      Sql.named('''
        WITH horizon AS (
          SELECT pg_snapshot_xmin(pg_current_snapshot())::text::bigint AS xmin
        )
        SELECT e.id, e.persistence_id, e.sequence_number, e.event_data,
               e.event_type, e.event_id, e.tx_id, horizon.xmin
        FROM horizon
        LEFT JOIN LATERAL (
          SELECT id, persistence_id, sequence_number, event_data, event_type,
                 event_id, tx_id
          FROM event_envelopes
          WHERE (tx_id, id) > (@afterTx:int8, @afterId:int8)
            AND tx_id < horizon.xmin
          ORDER BY tx_id, id
          LIMIT @limit:int8
        ) e ON TRUE
      '''),
      parameters: {'afterTx': after.tx, 'afterId': after.id, 'limit': limit},
    );
    return _JournalPage(
      [
        for (final row in result)
          if (row[0] != null)
            ((tx: row[6] as int, id: row[0] as int), _rowToPersisted(row)),
      ],
      horizon: result.first[7] as int,
    );
  }

  /// Up to [limit] of one actor's journal rows with a sequence number above
  /// [afterSequence], in order. Appends to one persistence id are serialised
  /// on its advisory lock, so sequence number k+1 commits only after k and
  /// this cursor needs no horizon.
  Future<_JournalPage> _readActorPage(
    String persistenceId,
    int afterSequence,
    int limit,
  ) async {
    final result = await _pool!.execute(
      Sql.named('''
        SELECT id, persistence_id, sequence_number, event_data, event_type, event_id
        FROM event_envelopes
        WHERE persistence_id = @persistenceId
          AND sequence_number > @afterSequence
        ORDER BY sequence_number ASC
        LIMIT @limit
      '''),
      parameters: {
        'persistenceId': persistenceId,
        'afterSequence': afterSequence,
        'limit': limit,
      },
    );
    return _JournalPage([
      for (final row in result)
        ((tx: 0, id: row[2] as int), _rowToPersisted(row)),
    ]);
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

  /// Reads the journal from a cursor in keyset pages: first the replay (every
  /// page up to the first short one), then, when [live], the same read again
  /// whenever there may be something new.
  ///
  /// The cursor is the only state: a row is emitted when the cursor moves
  /// past it, so every row is delivered once and in the reader's order,
  /// whether it was committed before the subscription, during the replay or
  /// later. A live stream re-reads at once if this instance committed an
  /// append while the last read ran, when this instance commits one, after
  /// [livePollInterval], and, while an append this instance committed is not
  /// yet below the horizon, after a short backoff.
  Stream<_PersistedEvent> _tail({
    required Future<_Position> Function() start,
    required Future<_JournalPage> Function(_Position after, int limit) readPage,
    required bool live,
  }) {
    late final StreamController<_PersistedEvent> controller;
    var cancelled = false;
    Completer<void>? wake;

    bool stopped() => cancelled || _isClosed;

    void wakeUp() {
      final c = wake;
      if (c != null && !c.isCompleted) c.complete();
    }

    // Waits for an append by this instance, close(), cancellation, resume
    // (while paused) or [timeout], whichever comes first.
    Future<void> sleep(Duration? timeout) async {
      if (stopped()) return;
      final c = Completer<void>();
      wake = c;
      _waiters.add(c);
      final timer = timeout == null ? null : Timer(timeout, wakeUp);
      await c.future;
      timer?.cancel();
      _waiters.remove(c);
      wake = null;
    }

    Future<void> run() async {
      try {
        var cursor = await start();
        var replaying = true;
        var retry = _minHorizonRetry;
        int? replayTarget;
        while (!stopped()) {
          final generation = _commitGeneration;
          final limit = journalPageSize < 1 ? 1 : journalPageSize;
          if (replaying) await beforeReplayQuery?.call();
          if (stopped()) break;
          final page = await readPage(cursor, limit);
          journalReadCount++;
          if (replaying) await afterReplayQuery?.call();
          for (final (position, event) in page.rows) {
            if (stopped()) break;
            cursor = position;
            if (event != null) controller.add(event);
          }
          while (controller.isPaused && !stopped()) {
            await sleep(null);
          }
          if (page.rows.length >= limit) continue;

          replaying = false;
          if (page.rows.isNotEmpty) retry = _minHorizonRetry;
          // A replay (live: false) still waits for the appends this instance
          // committed before it reached the end, so a caller reads its own
          // writes; a live stream waits for every append it knows of.
          final committed =
              live ? _maxCommittedTx : (replayTarget ??= _maxCommittedTx);
          final horizon = page.horizon;
          final unreadOwnAppend = horizon != null && committed >= horizon;
          if (!live && !unreadOwnAppend) break;
          if (live && _commitGeneration != generation) continue;
          if (unreadOwnAppend) {
            // An append committed here is not below the horizon yet: an
            // older transaction is still running.
            await sleep(retry);
            final doubled = retry * 2;
            retry = doubled > _maxHorizonRetry ? _maxHorizonRetry : doubled;
            continue;
          }
          await sleep(livePollInterval);
        }
      } catch (e, s) {
        if (!stopped() && !controller.isClosed) controller.addError(e, s);
      }
      if (!controller.isClosed) unawaited(controller.close());
    }

    controller = StreamController<_PersistedEvent>(
      onListen: () => unawaited(run()),
      onResume: wakeUp,
      onCancel: () {
        cancelled = true;
        wakeUp();
      },
    );
    return controller.stream;
  }

  /// Every persistence id in the journal, in ascending order.
  ///
  /// ## Cost
  ///
  /// `SELECT DISTINCT persistence_id` reads *every* journal row (the planner
  /// picks a sequential scan and a hash aggregate over the lot) to return
  /// one row per actor. The journal only ever grows and is never trimmed, so
  /// that cost grows with the wallet's whole history while the answer stays
  /// the size of the actor list.
  ///
  /// This reads it as a keyset ("skip", or "loose index") scan instead: find
  /// the first id, then repeatedly find the smallest id greater than the
  /// last one. Each step is one descent of `idx_event_envelopes_persistence_id`
  /// (an index-only scan with `LIMIT 1`), so the work is proportional to the
  /// number of *distinct* ids, not to the number of events. Nothing is
  /// stored differently and no row is skipped: this is the same set of ids,
  /// read a cheaper way.
  ///
  /// ## Contract
  ///
  /// The ids arrive in the same ascending order as before, and the stream is
  /// still drained to completion by a plain `toList()`. What changed is that
  /// the read is no longer one statement: it is issued in pages of
  /// [persistenceIdPageSize] ids, so the result is not a single snapshot of
  /// the journal. An actor whose first event is appended after this stream
  /// has passed its id may be missed, and one appended ahead of the cursor
  /// will be included — as for any paged read. Ids already delivered are
  /// never repeated and never go away (nothing deletes journal rows).
  @override
  Stream<String> currentPersistenceIds() async* {
    _ensureInitialized();

    String? after;
    while (true) {
      final limit = persistenceIdPageSize < 1 ? 1 : persistenceIdPageSize;
      final sql = _persistenceIdPageSql(after: after);
      final parameters = <String, Object?>{
        'limit': limit,
        if (after != null) 'after': after,
      };
      onPersistenceIdsQuery?.call(sql, parameters);
      persistenceIdQueryCount++;
      final result = await _pool!.execute(
        Sql.named(sql),
        parameters: parameters,
      );

      var count = 0;
      for (final row in result) {
        final id = row[0] as String?;
        if (id == null) continue;
        count++;
        after = id;
        yield id;
      }
      if (count < limit) return;
    }
  }

  /// One page of the skip scan over `persistence_id`.
  ///
  /// The anchor takes the smallest id (greater than [after], when resuming);
  /// each recursive step takes the smallest id greater than the previous
  /// one, as a scalar subquery so the recursion ends on a `NULL` row rather
  /// than needing a second pass. The outer `LIMIT` stops the recursion after
  /// a page's worth of ids: a recursive CTE is evaluated on demand, so a
  /// page never walks past the ids it returns.
  static String _persistenceIdPageSql({String? after}) => '''
        WITH RECURSIVE ids AS (
          (SELECT persistence_id
             FROM event_envelopes
            ${after == null ? '' : 'WHERE persistence_id > @after'}
            ORDER BY persistence_id
            LIMIT 1)
          UNION ALL
          SELECT (SELECT e.persistence_id
                    FROM event_envelopes e
                   WHERE e.persistence_id > ids.persistence_id
                   ORDER BY e.persistence_id
                   LIMIT 1)
            FROM ids
           WHERE ids.persistence_id IS NOT NULL
        )
        SELECT persistence_id FROM ids
         WHERE persistence_id IS NOT NULL
         LIMIT @limit
      ''';
}

/// A stream cursor: `(tx_id, id)` for the global journal order, `(0,
/// sequence_number)` for one actor's journal.
typedef _Position = ({int tx, int id});

/// One keyset page of journal rows, each with the cursor position it moves
/// to and its event (`null` for a row that could not be decoded).
class _JournalPage {
  final List<(_Position, _PersistedEvent?)> rows;

  /// The visibility horizon of a global read (`pg_snapshot_xmin`); `null`
  /// for reads that need none.
  final int? horizon;

  const _JournalPage(this.rows, {this.horizon});
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
