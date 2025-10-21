# Guide: Building Projections for Read Models

This guide explains how to create and manage projections to build real-time read models from your event stream in Eventador.

## 1. Introduction

### What are Projections?

A projection is a process that listens to a stream of events and transforms them into a new representation, typically a denormalized read model. In a CQRS (Command Query Responsibility Segregation) architecture, projections are responsible for building the "read side" of your application.

### Projections and Persistent Actors

In Eventador, persistent actors are the primary source of events. When a command is processed by a persistent actor, it results in one or more events being persisted to the `EventStore`. Projections subscribe to the `EventStore` and are notified when new events are persisted. They can then process these events to update their read models.

This creates a one-way flow of data:

`Command` -> `Persistent Actor` -> `Event` -> `EventStore` -> `Projection` -> `Read Model`

### Why use Projections?

*   **Optimized for Queries**: Read models can be tailored to the specific needs of your UI, making queries fast and efficient.
*   **Decoupling**: Projections decouple your read models from your write models, allowing them to evolve independently.
*   **Real-time Updates**: Projections can update read models in real-time as new events occur.

## 2. Creating a Projection

To create a projection, you need to extend the `Projection` base class:

```dart
class MyProjection extends Projection<MyReadModel> {
  MyProjection({
    required String projectionId,
    required EventStore eventStore,
  }) : super(projectionId: projectionId, eventStore: eventStore);

  // ... implementation ...
}
```

The key components are:

*   `projectionId`: A unique identifier for the projection. This is used to store and retrieve checkpoints.
*   `eventStore`: An instance of an `EventStore` implementation, which is used to read the event stream.
*   `MyReadModel`: The type of the read model that this projection builds.

## 3. Handling Events

The `handle` method is where you define the logic for processing events and updating your read model.

```dart
@override
Future<bool> handle(Event event) async {
  if (event is UserRegistered) {
    _readModel = _readModel.copyWith(
      totalUsers: _readModel.totalUsers + 1,
    );
    return true;
  }
  return false;
}
```

**Key Points**:

*   The `handle` method should return `true` if the event was processed, and `false` otherwise.
*   It is responsible for updating the in-memory read model.
*   You should also persist the updated read model to a database or other storage medium.

## 4. Managing Checkpoints

To avoid reprocessing the entire event stream every time the projection starts, we use checkpoints. A checkpoint stores the sequence number of the last event that was processed.

The `Projection` base class automatically handles loading and saving checkpoints. You can access the current checkpoint via the `checkpoint` property.

## 5. Full Example

Here is a complete example of a `CounterProjection` that works with the `CounterActor` from the [Persistent Actors Guide](./persistent-actors-guide.md).

```dart
import 'package:eventador/eventador.dart';

// 1. Define Events (from the CounterActor)
class CounterIncrementedEvent extends Event {
  final int value;
  CounterIncrementedEvent(this.value);
}

class CounterDecrementedEvent extends Event {
  final int value;
  CounterDecrementedEvent(this.value);
}

// 2. Define the Read Model
class CounterReadModel {
  final int totalIncrements;
  final int totalDecrements;
  final int currentValue;

  CounterReadModel({
    this.totalIncrements = 0,
    this.totalDecrements = 0,
    this.currentValue = 0,
  });

  CounterReadModel copyWith({
    int? totalIncrements,
    int? totalDecrements,
    int? currentValue,
  }) {
    return CounterReadModel(
      totalIncrements: totalIncrements ?? this.totalIncrements,
      totalDecrements: totalDecrements ?? this.totalDecrements,
      currentValue: currentValue ?? this.currentValue,
    );
  }
}

// 3. Implement the Projection
class CounterProjection extends Projection<CounterReadModel> {
  late CounterReadModel _readModel;

  CounterProjection({
    required String projectionId,
    required EventStore eventStore,
  }) : super(projectionId: projectionId, eventStore: eventStore) {
    _readModel = CounterReadModel();
  }

  @override
  CounterReadModel get readModel => _readModel;

  @override
  List<Type> get interestedEventTypes => [
        CounterIncrementedEvent,
        CounterDecrementedEvent,
      ];

  @override
  Future<bool> handle(Event event) async {
    if (event is CounterIncrementedEvent) {
      _readModel = _readModel.copyWith(
        totalIncrements: _readModel.totalIncrements + 1,
        currentValue: _readModel.currentValue + event.value,
      );
      return true;
    } else if (event is CounterDecrementedEvent) {
      _readModel = _readModel.copyWith(
        totalDecrements: _readModel.totalDecrements + 1,
        currentValue: _readModel.currentValue - event.value,
      );
      return true;
    }
    return false;
  }

  @override
  Future<void> reset() async {
    _readModel = CounterReadModel();
  }
}
```
