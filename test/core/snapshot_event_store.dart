/// An in-memory event store that keeps snapshots, for tests of aggregate
/// snapshot restores.
library;

import 'package:eventador/eventador.dart';

/// In-memory event store with snapshots (CBOR-serialized, like the real
/// stores) and exclusive `fromSequence`.
class SnapshotEventStore implements EventStore {
  final Map<String, List<Event>> journal = {};
  final Map<String, ({List<int> bytes, int sequenceNumber, String type})> snapshots = {};

  void append(String persistenceId, Iterable<Event> events) =>
      journal.putIfAbsent(persistenceId, () => []).addAll(events);

  @override
  Future<void> persistEvent(String persistenceId, Event event, int expectedVersion) async =>
      append(persistenceId, [event]);

  @override
  Future<void> persistEvents(String persistenceId, List<Event> events, int expectedVersion) async =>
      append(persistenceId, events);

  @override
  Future<List<Event>> getEvents(String persistenceId, {int fromSequence = 0, int? toSequence}) async {
    final events = journal[persistenceId] ?? const <Event>[];
    final end = toSequence == null || toSequence > events.length ? events.length : toSequence;
    if (fromSequence >= end) return const [];
    return events.sublist(fromSequence, end);
  }

  @override
  Future<int> getHighestSequenceNumber(String persistenceId) async =>
      journal[persistenceId]?.length ?? 0;

  @override
  Future<void> saveSnapshot(String persistenceId, dynamic state, int sequenceNumber) async {
    snapshots[persistenceId] = (
      bytes: CborSerializer.serializeState(state),
      sequenceNumber: sequenceNumber,
      type: state is State ? state.typeName : state.runtimeType.toString(),
    );
  }

  @override
  Future<SnapshotData?> loadSnapshot(String persistenceId) async {
    final s = snapshots[persistenceId];
    if (s == null) return null;
    return SnapshotData(
      state: CborSerializer.deserializeState(s.bytes, s.type),
      sequenceNumber: s.sequenceNumber,
      timestamp: DateTime.utc(2026),
    );
  }

  @override
  Future<void> deleteOldSnapshots(String persistenceId, int keepCount) async {}

  @override
  Future<void> close() async {}
}

