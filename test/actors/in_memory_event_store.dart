import 'package:eventador/eventador.dart';

/// Minimal in-memory [EventStore] for actor-level tests that do not need
/// Isar. Records every persisted event so tests can assert on what (if
/// anything) an aggregate wrote.
class InMemoryEventStore implements EventStore {
  final Map<String, List<Event>> _journal = {};

  /// Every event persisted, in order, keyed by persistence id.
  Map<String, List<Event>> get journal => _journal;

  /// All persisted events across every persistence id.
  List<Event> get allEvents => _journal.values.expand((e) => e).toList();

  @override
  Future<void> persistEvent(
      String persistenceId, Event event, int expectedVersion) async {
    _journal.putIfAbsent(persistenceId, () => []).add(event);
  }

  @override
  Future<void> persistEvents(
      String persistenceId, List<Event> events, int expectedVersion) async {
    _journal.putIfAbsent(persistenceId, () => []).addAll(events);
  }

  @override
  Future<List<Event>> getEvents(String persistenceId,
      {int fromSequence = 0, int? toSequence}) async {
    // Sequence numbers are 1-based journal positions.
    final events = _journal[persistenceId] ?? const <Event>[];
    final start = fromSequence <= 1 ? 0 : fromSequence - 1;
    final end = toSequence == null || toSequence > events.length
        ? events.length
        : toSequence;
    if (start >= end) return const [];
    return events.sublist(start, end);
  }

  @override
  Future<int> getHighestSequenceNumber(String persistenceId) async {
    return _journal[persistenceId]?.length ?? 0;
  }

  @override
  Future<void> saveSnapshot(
      String persistenceId, dynamic state, int sequenceNumber) async {}

  @override
  Future<SnapshotData?> loadSnapshot(String persistenceId) async => null;

  @override
  Future<void> deleteOldSnapshots(String persistenceId, int keepCount) async {}

  @override
  Future<void> close() async {}
}
