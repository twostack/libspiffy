# Guide: Building Projections for Read Models

This guide explains how to create and manage projections to build real-time read models from your event stream in Eventador using an Akka Persistence-inspired architecture.

## 1. Introduction

### What are Projections?

A projection is a process that listens to a stream of events and transforms them into a new representation, typically a denormalized read model. In a CQRS (Command Query Responsibility Segregation) architecture, projections are responsible for building the "read side" of your application.

### Architecture: Akka Persistence Query Pattern

Eventador implements an **Akka Persistence Query-inspired architecture** where projections automatically subscribe to event streams rather than receiving manually routed events. This provides:

- **Automatic Event Flow**: Events automatically flow from EventStore to projections
- **Stream-Based Processing**: Projections consume events from streams, supporting both replay and live streaming
- **Separation of Concerns**: EventStore doesn't know about ProjectionManager
- **Pull-Based Model**: Projections subscribe to and pull events from streams

### Event Flow

```
Command → Aggregate → EventStore.persist()
                          ↓
                    Broadcast to EventStream
                          ↓
              ProjectionManager (subscribed)
                          ↓
                    Filter by event type
                          ↓
                  Route to interested Projections
                          ↓
                    Update Read Models
```

### Why use Projections?

*   **Optimized for Queries**: Read models can be tailored to specific UI needs, making queries fast and efficient
*   **Decoupling**: Projections decouple read models from write models, allowing independent evolution
*   **Real-time Updates**: Projections update read models in real-time as new events occur
*   **Automatic Streaming**: No manual event routing needed - projections automatically receive events
*   **Replay Support**: Can rebuild read models by replaying historical events

## 2. Creating a Projection

To create a projection, extend the `Projection` base class:

```dart
class AccountSummaryProjection extends Projection<Map<String, AccountSummary>> {
  final Isar isar;
  final Map<String, AccountSummary> _inMemoryCache = {};

  AccountSummaryProjection({required this.isar});

  @override
  String get projectionId => 'account-summary';

  @override
  Map<String, AccountSummary> get readModel => _inMemoryCache;

  @override
  List<Type> get interestedEventTypes => [
        AccountOpenedEvent,
        MoneyDepositedEvent,
        MoneyWithdrawnEvent,
      ];

  @override
  Future<bool> handle(Event event) async {
    // Handle events and update read model
    // Return true if handled, false otherwise
  }

  @override
  Future<void> reset() async {
    // Reset read model to initial state
  }

  @override
  Future<void> rebuild() async {
    // Rebuild read model from scratch
  }
}
```

**Key Components**:

*   `projectionId`: Unique identifier for the projection (used for checkpointing)
*   `readModel`: The current state of the read model (in-memory or database-backed)
*   `interestedEventTypes`: List of event types this projection processes
*   No EventStore parameter needed - ProjectionManager handles the streaming!

## 3. Handling Events

The `handle` method processes events and updates your read model:

```dart
@override
Future<bool> handle(Event event) async {
  try {
    if (event is AccountOpenedEvent) {
      await _handleAccountOpened(event);
      return true;
    } else if (event is MoneyDepositedEvent) {
      await _handleMoneyDeposited(event);
      return true;
    } else if (event is MoneyWithdrawnEvent) {
      await _handleMoneyWithdrawn(event);
      return true;
    }
    return false;
  } catch (e, stackTrace) {
    await onError(e, stackTrace);
    rethrow;
  }
}

Future<void> _handleAccountOpened(AccountOpenedEvent event) async {
  final summary = AccountSummary.fromEvent(
    event.aggregateId,
    event.accountHolder,
    event.initialDeposit,
  );

  // Update in-memory cache
  _inMemoryCache[event.aggregateId] = summary;

  // Persist to database
  await isar.writeTxn(() async {
    await isar.accountSummarys.put(summary);
  });

  print('📊 Account Summary Created: ${event.aggregateId}');
}
```

**Best Practices**:

*   Return `true` if the event was processed, `false` otherwise
*   Update both in-memory cache and persistent storage
*   Handle errors gracefully using try-catch
*   Use the `onError` callback for error reporting
*   Keep event handlers focused and single-purpose

## 4. Using ProjectionManager

The `ProjectionManager` handles automatic event streaming to projections:

```dart
void main() async {
  // 1. Create EventStore with EventStream support
  final eventStore = await IsarEventStore.create(
    directory: './data',
    name: 'my_app',
  );

  // 2. Create projection
  final projection = AccountSummaryProjection(isar: isar);

  // 3. Create ProjectionManager with EventStream
  final projectionManager = ProjectionManager(eventStore);

  // 4. Register projection - auto-subscribes to event stream
  await projectionManager.registerProjection(projection);

  // 5. Start streaming events to projections
  await projectionManager.start();

  // 6. Use aggregates normally - events flow automatically!
  final account = BankAccountAggregate(
    accountId: 'account-001',
    eventStore: eventStore,
  );
  
  await account.handle(OpenAccountCommand(...));
  
  // No manual routing needed! Events automatically flow to projections
  
  // 7. Query the read model
  final summary = await projection.getAccountSummary('account-001');
  print('Balance: \$${summary?.balance}');

  // 8. Cleanup
  await projectionManager.stop();
}
```

**Key Points**:

*   ProjectionManager accepts an `EventStream` (which EventStore implements)
*   `registerProjection()` takes a projection instance
*   `start()` begins streaming events to all registered projections
*   Events automatically flow to projections - no manual routing!
*   Multiple projections can be registered and run concurrently

## 5. Managing Checkpoints

Projections track their progress using checkpoints:

```dart
@override
Future<int> getCheckpoint() async {
  // Load checkpoint from persistent storage
  // For in-memory: return 0
  // For database: query and return last processed sequence
  return 0;
}

@override
Future<void> updateCheckpoint(int sequenceNumber) async {
  // Save checkpoint to persistent storage
  // This allows resuming from the last processed event
}
```

**Checkpoint Usage**:

*   ProjectionManager loads the checkpoint when subscribing
*   Events are replayed from the checkpoint position
*   Prevents reprocessing all events on restart
*   Should be persisted to survive application restarts

## 6. Persisting Read Models

### Option 1: In-Memory (Simple)

```dart
class SimpleProjection extends Projection<MyReadModel> {
  MyReadModel _readModel = MyReadModel.empty();

  @override
  MyReadModel get readModel => _readModel;

  @override
  Future<bool> handle(Event event) async {
    // Update in-memory model only
    _readModel = _readModel.copyWith(...);
    return true;
  }
}
```

### Option 2: Database-Backed (Production)

```dart
class DatabaseProjection extends Projection<Map<String, Summary>> {
  final Isar isar;
  final Map<String, Summary> _cache = {};

  @override
  Map<String, Summary> get readModel => _cache;

  @override
  Future<bool> handle(Event event) async {
    // 1. Update in-memory cache
    _cache[key] = summary;

    // 2. Persist to database
    await isar.writeTxn(() async {
      await isar.summarys.put(summary);
    });

    return true;
  }

  // Query methods for read model
  Future<Summary?> getSummary(String id) async {
    // Try cache first
    if (_cache.containsKey(id)) {
      return _cache[id];
    }

    // Load from database
    final summary = await isar.summarys
        .filter()
        .idEqualTo(id)
        .findFirst();

    if (summary != null) {
      _cache[id] = summary;
    }

    return summary;
  }
}
```

## 7. Complete Example: Bank Account

See `example/bank_account_e2e_example.dart` for a complete working example featuring:

- **BankAccountAggregate**: Write-side aggregate with business rules
- **AccountSummaryProjection**: Read-side projection with Isar persistence
- **ProjectionManager**: Automatic event streaming setup
- **Full E2E Flow**: Commands → Events → Projections → Read Model queries

### Key Excerpts:

```dart
// Define Isar Read Model
@collection
class AccountSummary {
  Id id = Isar.autoIncrement;
  @Index(unique: true)
  late String accountId;
  late String accountHolder;
  late double balance;
  late int transactionCount;
  // ... more fields
}

// Create Projection
class AccountSummaryProjection extends Projection<Map<String, AccountSummary>> {
  final Isar isar;
  final Map<String, AccountSummary> _inMemoryCache = {};

  @override
  String get projectionId => 'account-summary';

  @override
  List<Type> get interestedEventTypes => [
    AccountOpenedEvent,
    MoneyDepositedEvent,
    MoneyWithdrawnEvent,
  ];

  @override
  Future<bool> handle(Event event) async {
    if (event is AccountOpenedEvent) {
      final summary = AccountSummary.fromEvent(...);
      _inMemoryCache[event.aggregateId] = summary;
      await isar.writeTxn(() => isar.accountSummarys.put(summary));
      return true;
    }
    // ... handle other events
    return false;
  }

  // Query methods
  Future<AccountSummary?> getAccountSummary(String accountId) async {
    // Check cache, then database
  }

  Future<double> getTotalBalanceAllAccounts() async {
    final accounts = await isar.accountSummarys.where().findAll();
    return accounts.fold(0.0, (sum, account) => sum + account.balance);
  }
}

// Setup in main()
final eventStore = await IsarEventStore.create(...);
final projection = AccountSummaryProjection(isar: isar);
final projectionManager = ProjectionManager(eventStore);

await projectionManager.registerProjection(projection);
await projectionManager.start();

// Events now automatically flow to projection!
```

## 8. Advanced Topics

### Rebuilding Projections

```dart
// Rebuild a specific projection from scratch
await projectionManager.rebuildProjection('account-summary');
```

This will:
1. Pause the projection
2. Reset the read model
3. Replay all events from the beginning
4. Resume normal operation

### Pausing and Resuming

```dart
// Pause a projection
await projectionManager.pauseProjection('account-summary');

// Resume a projection
await projectionManager.resumeProjection('account-summary');
```

### Monitoring Projections

```dart
// Get projection status
final info = await projectionManager.getProjectionInfo('account-summary');
print('Status: ${info.status}');
print('Events processed: ${info.eventsProcessed}');
print('Last sequence: ${info.lastProcessedSequence}');

// Get all projections
final allInfos = projectionManager.getProjectionInfos();
```

## 9. Best Practices

1. **Idempotency**: Design event handlers to be idempotent (safe to process same event multiple times)
2. **Error Handling**: Implement proper error handling and use `onError` callback
3. **Checkpointing**: Persist checkpoints regularly for fast recovery
4. **Caching**: Use in-memory caching for frequently accessed data
5. **Batch Updates**: Consider batching database writes for performance
6. **Monitoring**: Track projection health and lag using ProjectionInfo
7. **Testing**: Test projections independently with mock event streams
8. **Read Model Design**: Design read models for query patterns, not normalized data

## 10. Comparison with Akka Persistence

Eventador's projection system is inspired by Akka Persistence Query:

| Feature | Akka Persistence | Eventador |
|---------|------------------|-----------|
| Event Streaming | `eventsByTag()`, `allEvents()` | `EventStream` interface |
| Projection Manager | Akka Projection | `ProjectionManager` |
| Subscription | Pull-based streams | Pull-based Dart streams |
| Checkpointing | Offset storage | `getCheckpoint()` / `updateCheckpoint()` |
| Read Model | User-defined | `Projection<TReadModel>` |

Both systems follow the same principle: **projections subscribe to event streams rather than receiving manually routed events**.
