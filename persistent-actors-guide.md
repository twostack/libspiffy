# Guide: Working with Persistent Actors

This guide provides a comprehensive overview of how to create and work with persistent actors in the Eventador framework.

## 1. Introduction

### What is a persistent actor?

A persistent actor is an actor that saves its state to a durable storage medium, allowing it to be recovered after a system restart or crash. In Eventador, this is achieved through event sourcing.

### Why use event sourcing?

Event sourcing is a powerful pattern for building robust, auditable systems. Instead of storing the current state of an actor, we store a sequence of events that have led to that state. This provides several benefits:

*   **Complete Audit Trail**: The event log is a complete, immutable record of everything that has happened in the system.
*   **Easy Debugging and Testing**: You can replay events to reconstruct the state of the system at any point in time.
*   **Temporal Queries**: You can query the state of the system as it was in the past.

### The Command-Event-State Model

The core of a persistent actor is the command-event-state model:

*   **Commands**: A command is a request to change the state of an actor. It represents an *intent* to do something.
*   **Events**: An event is a fact that something has happened. It is the result of a successful command and is immutable.
*   **State**: The state of an actor is the in-memory representation of its data, which is derived from applying the sequence of events.

## 2. Creating a Persistent Actor

To create a persistent actor, you need to extend the `PersistentActor` base class:

```dart
class MyActor extends PersistentActor {
  MyActor({
    required String persistenceId,
    required EventStore eventStore,
  }) : super(persistenceId: persistenceId, eventStore: eventStore);

  // ... implementation ...
}
```

The key components are:

*   `persistenceId`: A unique identifier for the actor instance. This is used to look up the actor's events in the event store.
*   `eventStore`: An instance of an `EventStore` implementation, which is responsible for saving and loading events.

## 3. Handling Commands

The `commandHandler` method is where you define the business logic for your actor. It receives a `Command` and is responsible for validating it and generating events.

```dart
@override
Future<void> commandHandler(Command command) async {
  if (command is Increment) {
    // 1. Validate the command
    if (command.value <= 0) {
      throw Exception('Value must be positive');
    }

    // 2. Generate an event
    final event = Incremented(command.value);

    // 3. Persist the event
    await persistEvent(event);
  }
}
```

**Key Points**:

*   The `commandHandler` should **not** modify the actor's state directly.
*   It should perform all necessary validation before generating events.
*   It should call `persistEvent` to save the events.

## 4. Applying Events

The `eventHandler` method is responsible for applying an event to the actor's state.

```dart
@override
void eventHandler(Event event) {
  if (event is Incremented) {
    _state = _state.copyWith(value: _state.value + event.value);
  }
}
```

**Key Points**:

*   The `eventHandler` must be a **pure function**. It should not have any side effects other than modifying the actor's in-memory state.
*   It is called in two scenarios:
    1.  During recovery, to replay events from the event store.
    2.  After a new event has been successfully persisted.

## 5. Persisting Events

The `persistEvent` method saves an event to the event store. Once the event is saved, it is passed to the `eventHandler` to be applied to the state.

```dart
await persistEvent(MyEvent(value: 42));
```

This method handles the details of optimistic concurrency control, ensuring that the event is only persisted if the actor's state has not changed since the last event was read.

## 6. Handling Queries

The `queryHandler` method is for handling messages that do not result in a state change. This is where you would put logic for reading the actor's current state.

```dart
@override
Future<void> queryHandler(dynamic message) async {
  if (message is GetValue) {
    // Reply to the sender with the current state
    context.sender.tell(_state.value);
  }
}
```

## 7. Snapshots

For actors with long-lived event streams, replaying all events on recovery can be time-consuming. Snapshots are a performance optimization that allows you to save a snapshot of the actor's state at a particular point in time.

To use snapshots, you need to implement two methods:

*   `getSnapshotState()`: This method should return a serializable representation of the actor's current state.
*   `onSnapshot(dynamic snapshotState, int sequenceNumber)`: This method is called during recovery if a snapshot is found. It should restore the actor's state from the snapshot data.

```dart
@override
Future<dynamic> getSnapshotState() async {
  return _state.toMap();
}

@override
Future<void> onSnapshot(dynamic snapshotState, int sequenceNumber) async {
  _state = CounterState.fromMap(snapshotState);
}
```

You can also configure automatic snapshots to be taken after a certain number of events or after a certain amount of time has passed.

## 8. Full Example

Here is a complete example of a simple counter actor:

```dart
import 'package:eventador/eventador.dart';

// 1. Define Commands & Messages
class Increment extends Command {
  final int value;
  Increment(this.value);
}

class GetValue {} // A regular message for queries

// 2. Define Events
class Incremented extends Event {
  final int value;
  Incremented(this.value);
}

// 3. Define State
class CounterState {
  final int value;
  CounterState({this.value = 0});

  CounterState copyWith({int? value}) {
    return CounterState(value: value ?? this.value);
  }

  Map<String, dynamic> toMap() => {'value': value};

  static CounterState fromMap(Map<String, dynamic> map) {
    return CounterState(value: map['value'] ?? 0);
  }
}

// 4. Implement the Actor
class CounterActor extends PersistentActor {
  late CounterState _state;

  CounterActor({
    required String persistenceId,
    required EventStore eventStore,
  }) : super(persistenceId: persistenceId, eventStore: eventStore) {
    _state = CounterState();
  }

  @override
  Future<void> commandHandler(Command command) async {
    if (command is Increment) {
      final event = Incremented(command.value);
      await persistEvent(event);
    }
  }

  @override
  void eventHandler(Event event) {
    if (event is Incremented) {
      _state = _state.copyWith(value: _state.value + event.value);
    }
  }

  @override
  Future<void> queryHandler(dynamic message) async {
    if (message is GetValue) {
      context.sender.tell(_state.value);
    }
  }

  @override
  Future<dynamic> getSnapshotState() async {
    return _state.toMap();
  }

  @override
  Future<void> onSnapshot(dynamic snapshotState, int sequenceNumber) async {
    _state = CounterState.fromMap(snapshotState);
  }
}

```