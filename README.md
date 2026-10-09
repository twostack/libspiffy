# LibSpiffy - Event-Sourced Bitcoin Wallet

An actor-based Bitcoin wallet implementation using event sourcing, CQRS, and SPV (Simplified Payment Verification) built with the Dactor/Eventador/DuraQ stack.

## Architecture Overview

LibSpiffy implements a sophisticated Bitcoin wallet system using modern architectural patterns:

- **Event Sourcing**: All wallet state changes are captured as immutable events
- **CQRS**: Clear separation between commands (write operations) and queries (read operations)
- **Actor Model**: Concurrent, fault-tolerant processing using Dactor
- **SPV**: Lightweight Bitcoin verification using merkle proofs
- **Hybrid Stack**: Combines Dactor (actors), Eventador (event store), and DuraQ (workflows)

## Key Features

### Core Wallet Functionality
- HD wallet address generation and management
- Wallet import (xpub watch-only, WIF private key)
- UTXO tracking with confirmation status
- Transaction creation and signing
- SPV transaction verification with merkle proofs (BEEF/BUMP)
- Multi-wallet support with isolation
- Event-sourced state with full audit trail

### Advanced Features
- **Invoice-based payment system** for simplified SPV validation
- **Multi-output invoices** (P2PKH, P2MS multisig, OP_RETURN metadata, Plugin-delegated outputs)
- **Plugin system** for custom script types and token protocols (ScriptPlugin, TransactionBuilderPlugin)
- **Payment channels** for off-chain micropayments with on-chain settlement
- **Benford distribution** UTXO splitting for transaction privacy
- UTXO holds and reservations with automatic cleanup
- Snapshot support for performance optimization
- Real-time balance calculations
- **ARC (Authoritative Response Component)** service integration for broadcasting and the policy fee rate every transaction pays
- Transaction fee calculation from BEEF data

### Storage & Deployment
- **Isar** embedded database for mobile/desktop
- **PostgreSQL** backend for server-side deployments
- **In-memory** storage for development and testing
- AES-256-GCM encrypted key storage (xpub/xpriv)
- Pluggable storage interfaces for custom backends

### Network Integration
- Bitcoin P2P network connectivity via SpiffyNode
- Block header synchronization (P2P network and CDN-based fast sync)
- **BEEF (Background Evaluation Extended Format)** transaction validation
- **BUMP (BSV Universal Merkle Path)** merkle proof validation
- Merkle proof validation against header chain
- ARC (Authoritative Response Component) service integration
- WhatsOnChain blockchain data source for wallet import

## System Architecture

LibSpiffy implements a **CQRS (Command Query Responsibility Segregation)** architecture with complete separation between write operations (commands → events → EventStore) and read operations (queries → ReadModels).

```
┌───────────────────────────────────────────────────────────────────────────┐
│                        LibSpiffy CQRS Architecture                        │
├───────────────────────────────────────────────────────────────────────────┤
│                                                                           │
│  PUBLIC API (import 'package:libspiffy/coordinator.dart')                 │
│  ┌────────────────────────────────────────────────────────────────────┐   │
│  │  WalletCoordinatorActor (Unified Facade)                           │   │
│  │  • Send: CreateWalletCommand, PayInvoiceCommand, GetBalanceQuery   │   │
│  │  • Recv: WalletCreatedEvent, PaymentReadyEvent, BalanceResponse    │   │
│  │  • Answers each request with its own reply (ask), channel P2P      │   │
│  └────────────────────────────────┬───────────────────────────────────┘   │
│                                   │ Internal delegation                   │
│  COMMAND SIDE (Write Operations)  │                                       │
│  ┌──────────────────┐      ┌──────┴─────────────┐                         │
│  │ Wallet Manager   │─────▶│ Invoice Coordinator│                         │
│  │ Actor            │      │ Actor              │                         │
│  │ • Routes cmds    │      │ • Routes invoice   │                         │
│  │ • Spawns aggr.   │      │   commands         │                         │
│  │ • Multi-wallet   │      │ • Spawns invoice   │                         │
│  └────────┬─────────┘      │   aggregates       │                         │
│           │                └──────────┬─────────┘                         │
│           ▼                           ▼                                   │
│  ┌────────────────┐        ┌────────────────┐                             │
│  │ Wallet         │        │ Invoice        │                             │
│  │ Aggregate      │        │ Aggregate      │                             │
│  │ • Validates    │        │ • Validates    │                             │
│  │ • Emits events │        │ • Emits events │                             │
│  └────────┬───────┘        └────────┬───────┘                             │
│           └────────────┬────────────┘                                     │
│                        ▼                                                  │
│              ┌─────────────────┐                                          │
│              │   Event Store   │  (Write-Only from Aggregates)            │
│              │   (Eventador)   │                                          │
│              └────────┬────────┘                                          │
│  ═════════════════════╪═══════════════════════════════════════════════    │
│                       ▼  Event Stream                                     │
│              ┌─────────────────┐                                          │
│              │Projection Actors│  (Read-Only from EventStore)             │
│              └────────┬────────┘                                          │
│         ┌─────────────┴─────────────┐                                     │
│         ▼                           ▼                                     │
│  ┌──────────────┐          ┌──────────────┐                               │
│  │   Wallet     │          │   Invoice    │                               │
│  │  Projection  │          │  Projection  │                               │
│  └──────┬───────┘          └──────┬───────┘                               │
│         └────────────┬────────────┘                                       │
│                      ▼                                                    │
│           ┌─────────────────────┐                                         │
│           │  Read Model Storage │  (Isar / PostgreSQL / In-Memory)        │
│           └─────────────────────┘                                         │
│                      ▲                                                    │
│  QUERY SIDE (Read Operations)                                             │
│  ┌──────────────────┐     ┌────────────────┐     ┌─────────────────┐      │
│  │   SPV Actor      │     │   ARC Actor    │     │ Header Sync     │      │
│  │ • BEEF/BUMP val. │     │ • Broadcast    │     │ • Block headers │      │
│  │ • Invoice match  │     │ • Fee estimate │     │ • Reorgs        │      │
│  │ • Fee calc       │     │ • Policy query │     │ • Chain valid.  │      │
│  └──────────────────┘     └────────────────┘     └─────────────────┘      │
│                                                                           │
└───────────────────────────────────────────────────────────────────────────┘
```

### Key CQRS Principles in LibSpiffy

**Write Side (Commands)**
- Commands routed through Coordinator Actors
- Aggregates (event-sourced) validate and emit events
- Events persisted to EventStore (immutable, append-only)
- No direct storage writes by application code

**Read Side (Queries)**  
- Projections subscribe to EventStore event stream
- Projections update denormalized ReadModels in Isar
- Queries read from ReadModels (never EventStore)
- Optimized for fast lookups without joins

**Benefits**
- **Performance**: Reads optimized separately from writes
- **Scalability**: Read/write can scale independently
- **Audit Trail**: Complete event history in EventStore
- **Eventual Consistency**: Projections update asynchronously
- **Flexibility**: Multiple read models from same events

## Quick Start

### Prerequisites

- Dart SDK 3.5.1 or later
- Dependencies: dactor, eventador, duraq (+ duraq_isar for the Isar backend), dartsv

### ⚠️ Critical: Event Type Registration

**Before using LibSpiffy**, you must understand that all event types must be registered with Eventador's `EventRegistry` for proper CBOR deserialization after system restarts.

**LibSpiffy handles this automatically** during initialization via `LibSpiffyActorSystem.registerEventTypes()`, but if you're extending LibSpiffy with custom events, you'll need to register them:

```dart
import 'package:eventador/eventador.dart';

// Register custom event types BEFORE initializing LibSpiffy
void registerMyCustomEvents() {
  EventRegistry.register<MyCustomWalletEvent>(
    'MyCustomWalletEvent',
    (map) => MyCustomWalletEvent.fromMap(map),
  );
}

// Then initialize LibSpiffy
await initializeLibSpiffy(dataDirectory: './wallet-data');
```

**What LibSpiffy registers automatically:**
- The wallet events (WalletCreatedEvent, AddressGeneratedEvent, UTXOReceivedEvent, etc.)
- The invoice events (InvoiceCreatedEvent, InvoicePaidEvent, etc.)
- The payment channel events (ChannelOpenedEvent, ChannelClosedEvent, etc.)

Each is registered under its stable type name (`wallet.utxo.received`, for example), with the class name as an alias where an earlier release journaled the event under it.

**Why this matters:**
- Events are stored in CBOR format in the EventStore
- After restart, Eventador needs to deserialize events back into Dart objects
- Without registration: `ArgumentError: Event type XYZ not registered`

See the [eventador package](https://pub.dev/packages/eventador) for complete details on event registration.

### Installation

Add libspiffy to `pubspec.yaml`. `Isar` is part of the public API
(`LibSpiffyActorSystem.initialize(isar:)`, `LibSpiffySchemas`), so the host
depends on Isar too:

```yaml
dependencies:
  libspiffy: ^5.0.0
  isar_community: ^3.3.2
  isar_community_flutter_libs: ^3.3.2 # Flutter apps only

dev_dependencies: # only when the host has Isar collections of its own
  isar_community_generator: ^3.3.2
  build_runner: ^2.7.0
```

Import Isar as `package:isar_community/isar.dart`.

**macOS and iOS hosts:** the published `isar_community` 3.3.2 binary
preallocates disk space past the end of the database file every time the file
grows, and never releases it. Until `isar_community` releases the fix,
override both packages with the 3.3.2 build on libmdbx v0.13.12, as the 4.0.0
entry in [CHANGELOG.md](CHANGELOG.md) describes:

```yaml
dependency_overrides:
  isar_community:
    git:
      url: https://github.com/stephanfeb/isar-community.git
      ref: 3.3.2-libmdbx-0.13.12
      path: packages/isar_community
  isar_community_flutter_libs: # Flutter apps only
    git:
      url: https://github.com/stephanfeb/isar-community.git
      ref: 3.3.2-libmdbx-0.13.12
      path: packages/isar_community_flutter_libs
```

### Basic Usage (Coordinator API - Recommended)

`libspiffy.coordinator` (a `WalletCoordinator`) is the canonical public interface for third-party apps. A command or query is a `CoordinatorRequest`: `ask` sends it and returns its own reply, whatever else is on the event stream, and throws `CoordinatorFailure` when it failed. `tell` sends without waiting, and `on<E>()` follows one kind of event: what happens without a request, such as a balance change or an incoming payment.

```dart
import 'package:libspiffy/libspiffy.dart';
import 'package:libspiffy/coordinator.dart';

// Initialize LibSpiffy
final libspiffy = LibSpiffyActorSystem();
await libspiffy.initialize(
  dataDirectory: './wallet-data',
  networkType: 'main', // 'test' (the default) for testnet
  arcConfig: ArcServiceConfig.taalMainnet(),
  enableP2P: true,
);

// Use the coordinator - THE single entry point
final coordinator = libspiffy.coordinator;

// A request returns its own reply. The app supplies the wallet's key
// material (a mnemonic, xpriv, WIF or xpub) and backs it up.
final mnemonic = await DartSVCryptoService().generateMnemonic();
final wallet = await coordinator.ask(CreateWalletCommand(
  walletId: 'my-wallet',
  name: 'My Bitcoin Wallet',
  mnemonic: mnemonic,
));
print('Wallet created, root address ${wallet.rootAddress}');

final invoice = await coordinator.ask(CreateInvoiceCommand(
  walletId: 'my-wallet',
  amount: BigInt.from(100000),
  description: 'Payment for services',
));
print('Pay ${invoice.amount} sats to ${invoice.addresses.first}');

final balance = await coordinator.ask(GetBalanceQuery(walletId: 'my-wallet'));
print('Balance: ${balance.totalBalance} sats');

// A failure throws, carrying the reply (or ErrorEvent) that reported it.
try {
  await coordinator.ask(DeleteWalletCommand(walletId: 'no-such-wallet'));
} on CoordinatorFailure catch (failure) {
  print('Not deleted: ${failure.message}');
}

// What happens without a request is followed on the event stream.
coordinator.on<BalanceUpdatedEvent>(walletId: 'my-wallet').listen((event) {
  print('Balance now: ${event.totalBalance} sats');
});

// Cleanup
await libspiffy.shutdown();
```

`example/coordinator_example.dart` runs this offline: `dart run example/coordinator_example.dart`.

### Direct Actor Access (Advanced)

For advanced use cases, you can access internal actors directly:

```dart
import 'package:libspiffy/libspiffy.dart';

await initializeLibSpiffy(dataDirectory: './wallet-data');

// Direct actor access (advanced - most apps should use the coordinator)
final walletManager = getLibSpiffySystem().walletManager;
final spvActor = getLibSpiffySystem().spvActor;

// libspiffy generates no keys: the app supplies a mnemonic, xpriv, WIF or xpub
final mnemonic = await DartSVCryptoService().generateMnemonic();
walletManager.tell(CreateWalletMessage('my-wallet', 'My Wallet', mnemonic: mnemonic));

await shutdownLibSpiffy();
```

### Integration with Host Actor System

If your application already uses Dactor actors, LibSpiffy can integrate seamlessly:

```dart
import 'package:dactor/dactor.dart';
import 'package:libspiffy/libspiffy.dart';

// Your application's actor system
final hostActorSystem = LocalActorSystem(ActorSystemConfig());

// Initialize LibSpiffy using your actor system
await initializeLibSpiffy(
  actorSystem: hostActorSystem,  // LibSpiffy actors join your system!
  dataDirectory: './wallet-data',
);

// Now all actors are in the same system
// You can spawn your own actors that interact with LibSpiffy
// (PaymentProcessorActor is the host's own actor, not part of LibSpiffy)
final myActor = await hostActorSystem.spawn(
  'payment-processor',
  () => PaymentProcessorActor(
    walletManager: getLibSpiffySystem().walletManager,
    invoiceCoordinator: getLibSpiffySystem().invoiceCoordinator,
  ),
);

// When shutting down, LibSpiffy won't shutdown the host's actor system
await shutdownLibSpiffy(); // Only closes LibSpiffy's resources

// Host manages its own actor system
await hostActorSystem.shutdown();
```

### Benefits of Shared Actor System

- **Unified Supervision**: Single supervision tree for all actors
- **Better Resource Efficiency**: One message dispatcher instead of two
- **Clearer Failure Propagation**: Unified error handling and recovery
- **Natural Actor Hierarchy**: LibSpiffy actors integrate into your supervision strategy
- **Direct Communication**: No cross-system message overhead

## Actor System Integration Patterns

### Pattern 1: Standalone Mode

Use LibSpiffy as a complete, self-contained wallet system:

```dart
// LibSpiffy manages everything
await initializeLibSpiffy(dataDirectory: './data');

// Use wallet functionality
final walletManager = getLibSpiffySystem().walletManager;
final mnemonic = await DartSVCryptoService().generateMnemonic();
walletManager.tell(CreateWalletMessage('my-wallet', 'My Wallet', mnemonic: mnemonic));

// LibSpiffy handles its own lifecycle
await shutdownLibSpiffy();
```

**Best for:** Simple applications, microservices, or when LibSpiffy is the primary component.

### Pattern 2: Integrated Mode

Integrate LibSpiffy into an existing actor-based application:

```dart
// Host application setup
final app = MyActorBasedApp();
await app.initialize();

// LibSpiffy joins the host's actor system
await initializeLibSpiffy(
  actorSystem: app.actorSystem,
  dataDirectory: './data',
);

// Your actors can directly communicate with LibSpiffy actors
// (MyActorBasedApp and PaymentProcessorActor are the host's own classes)
final paymentProcessor = await app.actorSystem.spawn(
  'payment-processor',
  () => PaymentProcessorActor(
    walletManager: getLibSpiffySystem().walletManager,
    spvActor: getLibSpiffySystem().spvActor,
  ),
);

// Lifecycle management
await shutdownLibSpiffy();  // Closes LibSpiffy resources only
await app.shutdown();       // Host manages actor system shutdown
```

**Best for:** Complex applications with multiple actor-based subsystems.

### Pattern 3: Coordinator (Built-in Gateway)

LibSpiffy provides a built-in `WalletCoordinator` that serves as the canonical gateway. You no longer need to build your own:

```dart
import 'package:libspiffy/coordinator.dart';

// The coordinator IS the gateway - no custom actor needed
final coordinator = getLibSpiffySystem().coordinator;

// Ask, and get the request's own reply
await coordinator.ask(CreateWalletCommand(walletId: 'my-wallet', name: 'My Wallet', mnemonic: mnemonic));
final payment = await coordinator.ask(PayInvoiceCommand(
  walletId: 'my-wallet',
  invoiceId: invoiceId,
  addresses: [paymentAddress],
  amount: BigInt.from(50000),
));
handlePaymentReady(payment);

// Follow what arrives without a request
coordinator.on<InvoicePaidEvent>().listen(handleInvoicePaid);
coordinator.on<ErrorEvent>().listen(handleError);
```

**Best for:** All third-party integrations. This is the recommended pattern for most applications.

### Checking Integration Mode

```dart
// Check if LibSpiffy owns its actor system
if (getLibSpiffySystem().ownsActorSystem) {
  print('LibSpiffy is running in standalone mode');
} else {
  print('LibSpiffy is integrated with host actor system');
}

// Access the underlying actor system if needed
final actorSystem = getLibSpiffySystem().actorSystem;
```

## CQRS Event Sourcing Flow

LibSpiffy implements a complete CQRS (Command Query Responsibility Segregation) architecture with event sourcing. Understanding this flow is crucial for working with the system.

### Complete Flow Diagram

```
Commands (Write)                      Events (Immutable)                 Queries (Read)
     │                                      │                                │
     ▼                                      ▼                                ▼
┌─────────────┐                    ┌──────────────┐                 ┌──────────────┐
│   Command   │                    │    Event     │                 │    Query     │
│   (Intent)  │                    │  (Fact)      │                 │  (Question)  │
└──────┬──────┘                    └──────┬───────┘                 └──────┬───────┘
       │                                  │                                │
       │ 1. Route                         │ 3. Persist                     │ 7. Read
       ▼                                  ▼                                ▼
┌─────────────────┐              ┌──────────────┐               ┌──────────────────┐
│  Coordinator    │              │  EventStore  │               │  ReadModel       │
│  Actor          │              │  (Isar CBOR) │               │  Storage (Isar)  │
│ • Wallet Mgr    │              │              │               │                  │
│ • Invoice Coord │              │ • Immutable  │               │ • Denormalized   │
└────────┬────────┘              │ • Append-only│               │ • Fast lookups   │
         │                       │ • Recovery   │               │ • No joins       │
         │ 2. Spawn/Tell         └──────┬───────┘               └────────▲─────────┘
         ▼                              │                                │
┌──────────────────┐                    │ 4. Stream                      │ 6. Update
│   Aggregate      │                    ▼                                │
│   (Domain Logic) │            ┌──────────────┐                         │
│ • Wallet         │            │  Projection  │                         │
│ • Invoice        │            │  Actors      │                         │
│                  │            │              │                         │
│ • Validate       │            │ • Subscribe  │                         │
│ • Emit Events    │◀───────────│ • Route      │                         │
└──────────────────┘ 5. Replay  │ • Checkpoint │                         │
                                └──────┬───────┘                         │
                                       │                                 │
                                       │ 5. Route by type               │
                                       ▼                                 │
                            ┌──────────────────────┐                     │
                            │    Projections       │─────────────────────┘
                            │ • WalletProjection   │
                            │ • InvoiceProjection  │
                            └──────────────────────┘
```

### Step-by-Step Flow

#### Write Side (Commands → Events → EventStore)

**Step 1: Command Routing**
```dart
// User sends a command to coordinator
invoiceCoordinator.tell(CreateInvoiceMessage(
  walletId: 'wallet-001',
  amount: BigInt.from(100000),
  description: 'Payment for services',
));
```

**Step 2: Aggregate Spawning/Routing**
```dart
// Inside InvoiceCoordinatorActor: spawn the invoice's aggregate actor
final aggregateActor = await context.system.spawn(
  'invoice-aggregate-$invoiceId',
  () => InvoiceAggregate(
    aggregateId: invoiceId,
    aggregateType: 'Invoice',
    eventStore: _eventStore,
  ),
);

// Sends command to aggregate
aggregateActor.tell(CreateInvoiceCommand(
  invoiceId: invoiceId,
  walletId: walletId,
  addresses: addresses, // generated by the wallet for this invoice
  amount: amount,
));
```

**Step 3: Event Emission**
```dart
// Inside InvoiceAggregate.handleCommand()
@override
Future<List<Event>> handleCommand(InvoiceState currentState, Command command) async {
  if (command is CreateInvoiceCommand) {
    // Validate business rules
    if (command.amount <= BigInt.zero) {
      throw ArgumentError('Amount must be positive');
    }
    
    // Return events (not state changes!)
    return [InvoiceCreatedEvent(
      invoiceId: command.invoiceId,
      walletId: command.walletId,
      addresses: command.addresses,
      amount: command.amount,
      // ... other fields
    )];
  }
}
```

**Step 4: Event Persistence**
```dart
// AggregateRoot base class automatically persists events to EventStore
// Events stored as CBOR in Isar
// This happens BEFORE the event is applied to the aggregate's state
```

**Step 5: Event Application**
```dart
// Inside InvoiceAggregate.applyEvent(): each event yields a new,
// immutable InvoiceState. The state passed in is never modified.
@override
InvoiceState applyEvent(InvoiceState state, Event event) {
  return switch (event) {
    final InvoiceCreatedEvent evt => state.copyWith(
        isCreated: true,
        walletId: evt.walletId,
        addresses: evt.addresses,
        amount: evt.amount,
        status: InvoiceStatus.pending,
        createdAt: evt.timestamp,
        expiresAt: evt.expiresAt,
        version: evt.version,
        lastModified: evt.timestamp,
      ),
    // ... other events
    _ => throw ArgumentError('Unknown event type: ${event.runtimeType}'),
  };
}
```

#### Read Side (EventStore → Projections → ReadModels)

**Step 6: Event Streaming**
```dart
// Each projection runs inside an Eventador ProjectionActor, spawned by
// LibSpiffyActorSystem. The actor subscribes to the event stream and
// hands each event to the projection.
final invoiceProjectionRef = await actorSystem.spawn(
  'projection-invoice-projection',
  () => ProjectionActor(invoiceProjection, eventStream, isar: isar),
);
```

**Step 7: Projection Handling**
```dart
// InvoiceProjection.handle() receives events
@override
Future<bool> handle(Event event) async {
  if (event is InvoiceCreatedEvent) {
    // Create denormalized read model
    final readModel = InvoiceReadModel(
      invoiceId: event.invoiceId,
      walletId: event.walletId,
      addresses: List.from(event.addresses),
      amount: event.amount,
      status: InvoiceStatus.pending,
      createdAt: event.timestamp,
      expiresAt: event.expiresAt,
      lastUpdated: event.timestamp,
      metadata: event.invoiceMetadata ?? {},
      // ... optimized for queries
    );

    // Write to ReadModelStorage, unless a replay already stored it
    if (await _storage.getInvoice(event.invoiceId) == null) {
      await _storage.storeInvoice(readModel);
    }

    return true; // Event handled; the ProjectionActor advances the checkpoint
  }
  return false; // Event not handled by this projection
}
```

**Step 8: Query Execution**
```dart
// Queries NEVER touch EventStore, only ReadModelStorage
invoiceCoordinator.tell(CheckInvoiceMessage(invoiceId));

// Inside coordinator
Future<void> _handleCheckInvoice(CheckInvoiceMessage msg) async {
  // Query read model storage (fast!)
  final invoice = await _storage.getInvoice(msg.invoiceId);
  if (invoice == null) {
    // Answered with InvoiceDetailsResponse(found: false, error: 'Invoice not found')
    return;
  }

  // InvoiceDetailsResponse with all denormalized data
  context.sender?.tell(_detailsFromReadModel(invoice));
}
```

### Recovery After Restart

When the system restarts, aggregates recover their state by replaying events:

```dart
// 1. Aggregate spawned during recovery
final aggregate = InvoiceAggregate(
  aggregateId: 'abc123',
  aggregateType: 'Invoice',
  eventStore: eventStore,
);

// 2. AggregateRoot.preStart() automatically replays events from EventStore
// 3. Events applied via applyEvent() to rebuild state
// 4. Aggregate ready to process new commands with correct state

// Projections also replay from their last checkpoint
// This ensures ReadModels are eventually consistent
```

### Key Principles

**✅ DO:**
- Route all commands through coordinators
- Let aggregates emit events (never mutate storage directly)
- Use projections to build read models
- Query read models for fast lookups
- Register event types before system startup

**❌ DON'T:**
- Write to storage from aggregates or coordinators
- Read from EventStore for queries (use ReadModels)
- Skip event registration (causes deserialization errors)
- Mutate events after creation (they're immutable)
- Query EventStore for business logic

### Storage Separation

LibSpiffy uses **separate databases for events and read models**:

**EventStore (Write-Only by Aggregates)**
- Schema: `EventEnvelope`, `SnapshotEnvelope` (from Eventador)
- Format: CBOR-serialized events
- Access: AggregateRoot base class only
- Purpose: Immutable audit trail, recovery

**ReadModelStorage (Write-Only by Projections, Read by App)**
- Schema: `InvoiceEntity`, `BitcoinUtxoEntity`, `BitcoinTransactionEntity`, `PaymentChannelEntity`
- Format: Denormalized domain objects
- Access: Projections write, application reads
- Purpose: Fast queries, optimized for reads

**Storage Backends:**
- **Isar** (mobile/desktop) — embedded, zero-config
- **PostgreSQL** (server) — connection pooling, migrations, SSL support
- **In-memory** (development/testing)

This separation ensures:
- Clear CQRS boundaries
- Independent scaling of read/write
- No accidental EventStore queries
- Optimized storage formats for each use case
- Deployment flexibility across mobile, desktop, and server

## Invoice-Based SPV Payments

LibSpiffy implements a streamlined SPV payment verification system using invoices:

### Creating and Paying Invoices

```dart
// 1. Receiver creates an invoice with payment addresses
final invoice = await bobCoordinator.ask(CreateInvoiceCommand(
  walletId: 'bob-wallet',
  amount: BigInt.from(100000), // satoshis
  description: 'Payment for services',
  numberOfAddresses: 1, // Can request multiple addresses
));

// The InvoiceCreatedEvent carries:
// - invoiceId: Unique identifier
// - addresses: Pre-generated payment addresses
// - amount: Expected payment amount
// - expiresAt: Invoice expiration time
// The receiver shares these with the sender.

// 2. Sender builds and signs a transaction paying the invoice address(es)
final payment = await aliceCoordinator.ask(PayInvoiceCommand(
  walletId: 'alice-wallet',
  invoiceId: invoice.invoiceId, // Links tx to invoice
  addresses: [invoice.addresses.first],
  amount: invoice.amount,
));

// The PaymentReadyEvent carries txid and beefBytes (tx + parent txs +
// merkle proofs). The payment is not broadcast; the sender hands the BEEF to
// the receiver over the app's own transport.

// 3. Receiver validates the BEEF it was handed
final verdict = await bobCoordinator.ask(ValidateBEEFCommand(
  walletId: 'bob-wallet',
  beefHex: hex.encode(payment.beefBytes),
  invoiceId: invoice.invoiceId,
));

// 4. SPV Actor validates the transaction:
//    - Verifies merkle proof against block header chain
//    - Confirms outputs match invoice addresses
//    - Validates payment amount
//    - Calculates transaction fee from BEEF data
// verdict: BEEFValidationResultEvent (broadcasted, networkStatus); an
// invalid payment throws CoordinatorFailure

// 5. Receiver's wallet is automatically updated with new UTXOs, and the
//    invoice is marked paid (InvoicePaidEvent) once ARC says the network
//    holds the payment
```

### SPV Validation Flow

1. **Transaction Received**: SPV Actor receives transaction with BEEF and invoice ID
2. **Merkle Proof Validation**: Validates transaction is in a valid block
3. **Invoice Lookup**: Retrieves expected payment addresses from the Invoice Coordinator
4. **Output Verification**: Confirms transaction pays to invoice addresses
5. **Amount Validation**: Verifies payment amount matches invoice
6. **UTXO Extraction**: Identifies new spendable UTXOs and spent UTXOs
7. **Fee Calculation**: Computes transaction fee from input/output values in BEEF
8. **State Update**: Wallet state updated via event sourcing
9. **Invoice Marking**: Invoice marked as paid once ARC reports the network holds the payment

### Payments Handed to the Recipient (Deferred Payments)

A payment built with `PayInvoiceCommand` is handed to the recipient, who normally
broadcasts it. Until the network has it, the wallet holds its inputs: they are
reserved by the transaction with no expiry, and neither the reservation cleanup
nor another payment can take them. The hold ends when ARC reports the
transaction `SEEN_ON_NETWORK` or `MINED` (inputs spent), when ARC reports it
`REJECTED` (payment failed, inputs released), when you cancel it, or when
the network holds your reclaim of it. `DOUBLE_SPEND_ATTEMPTED` (another
transaction spends an input) is no verdict: the payment stays outstanding,
its inputs held, until one of the two is mined. Every step is journaled;
resolved payments stay listable.

A payment can carry a **deadline** (`PayInvoiceCommand(deadline:)`, a UTC
instant; bead libspiffy-8442). While it is still outstanding when the deadline
passes, the wallet reclaims it by itself: the coordinator sweeps the wallets'
outstanding payments once a minute (`LibSpiffyActorSystem.initialize(
deadlineSweepInterval:)`) and sends the reclaim for each one that is due, as a
`ReclaimDeferredPaymentCommand` would, answered by a
`DeferredPaymentReclaimedEvent` whose request id is `deadline-<txid>`. A
payment the network has taken, that its counterparty completed, or that you
cancelled before the deadline is no longer outstanding and is left alone. The
deadline bounds the option the payment gives its holder; it does not end it:
the holder can still complete or broadcast the payment until the reclaim is
mined, and the two then race as any reclaim does. `GetDeferredPaymentsQuery(
dueBefore:)` lists what is due. A half that the counterparty must complete is
the case this is for: a node that withdraws its halves past an age sets the
deadline instead of running its own clock.

Each answer below comes once the wallet's read model shows it, so a query
made on hearing it sees the status, the spent inputs and the change. A
broadcast or a reclaim succeeds only when the network holds the
transaction: a status ARC gives while still processing is followed for up
to 30 s until it gives a verdict, and one still processing then, in the
orphan mempool (an input unknown or already spent in a block), contested or
rejected is reported unsuccessful with the reason.

```dart
// Payments the recipient has not broadcast after an hour
final stale = await coordinator.ask(GetDeferredPaymentsQuery(
  walletId: 'alice-wallet',
  olderThan: const Duration(hours: 1),
));
// stale.payments: txid, invoice, recipients, amount, fee, held inputs, last
// network status and check time, state, raw tx, BEEF

// Ask the network now (ARC; or via: DeferredPaymentNetworkSource.arcThenDataSource)
final status = await coordinator.ask(CheckDeferredPaymentStatusCommand(walletId: 'alice-wallet', txid: txid));
// DeferredPaymentStatusEvent (MINED confirms only when the merkle proof
// matches the local header chain)

// Broadcast it yourself
await coordinator.ask(BroadcastDeferredPaymentCommand(walletId: 'alice-wallet', txid: txid));

// Give up on it: refused (CoordinatorFailure) if the network knows the transaction
await coordinator.ask(CancelDeferredPaymentCommand(walletId: 'alice-wallet', txid: txid, reason: 'expired'));

// Revoke it: spend its inputs back to the wallet at ARC's policy fee
final reclaim = await coordinator.ask(ReclaimDeferredPaymentCommand(walletId: 'alice-wallet', txid: txid));
// reclaim.reclaimTxid, .fee; a failure's DeferredPaymentReclaimedEvent names
// the competing txids
```

Cancelling does not revoke the signed transaction the recipient holds: if they
broadcast it later and it still reaches miners, it spends those inputs, and a
later payment that reused them fails. Reclaiming does revoke it, if the
reclaim reaches the network first: first seen wins, and no fee changes that.
If the recipient's copy got there first, the reclaim is rejected and names
it.

### Benefits

- **Simplified Verification**: No need to scan entire blockchain for transactions
- **Immediate Validation**: SPV validation completes in milliseconds
- **Privacy**: Addresses are single-use and linked to specific invoices
- **Security**: Merkle proofs provide cryptographic assurance
- **Efficient**: Only block headers needed, not full blocks

## Core Components

### 1. Bitcoin Wallet Aggregate (Event-Sourced)

The core domain logic for wallet operations - an Eventador `AggregateRoot`:

```dart
// Spawned automatically by WalletManagerActor
// Each wallet is an independent aggregate actor
class BitcoinWalletAggregate extends AggregateRoot<WalletState> {
  @override
  Future<List<Event>> handleCommand(WalletState currentState, Command command) async {
    // Validate business rules and return events
    switch (command) {
      case final GenerateAddressCommand cmd:
        // Derives the next key; returns an AddressGeneratedEvent
        return await _keys.generateAddress(currentState, cmd);
      // ... other command handlers
    }
  }

  @override
  WalletState applyEvent(WalletState current, Event event) {
    // current is never modified: the event is applied to a draft of it,
    // and the aggregate's state is replaced with the result
    final state = current.toBuilder();
    switch (event) {
      case final AddressGeneratedEvent evt:
        state.addresses = state.addresses.put(evt.address, evt.label);
        state.nextDerivationIndex = evt.derivationIndex + 1;
        state.version = evt.version;
      // ... other event handlers
    }
    return state.build();
  }
}
```

**Key Features:**
- Event-sourced: All state changes via events
- Validation: Business rules enforced before events
- Recovery: Rebuilds state from events after restart
- Snapshots: Configurable for performance

### 2. Wallet Manager Actor (Coordinator)

Long-lived coordinator that manages multiple wallet aggregates:

```dart
// Create wallet (spawns BitcoinWalletAggregate actor) from the app's key
// material: a mnemonic, xpriv, WIF or xpub
walletManager.tell(CreateWalletMessage('wallet-001', 'My Bitcoin Wallet', mnemonic: mnemonic));

// Send a command to a wallet aggregate. An application asks the
// coordinator instead: its GenerateAddressCommand answers with an
// AddressGeneratedEvent once the read model holds the address, with the
// key's public key when asked for (includePublicKey). The aggregate's own
// command is in 'package:libspiffy/internals.dart'.
walletManager.tell(WalletCommandMessage(
  'wallet-001',
  GenerateAddressCommand(
    walletId: 'wallet-001',
    purpose: 'receive',
  ),
));

// Query wallet (reads from ReadModel, not EventStore). The wallet manager
// has no balance message: read the read model, or ask the coordinator
// GetBalanceQuery, answered with a BalanceResponse.
final BigInt balance = await getLibSpiffySystem().walletStorage.getBalance('wallet-001');
```

**Responsibilities:**
- Routes commands to appropriate wallet aggregates
- Spawns wallet aggregate actors on-demand
- Manages wallet lifecycle
- Automated UTXO reservation cleanup

### 3. Invoice Aggregate (Event-Sourced)

Domain logic for invoice lifecycle - an Eventador `AggregateRoot`:

```dart
// Spawned by InvoiceCoordinatorActor per invoice
class InvoiceAggregate extends AggregateRoot<InvoiceState> {
  @override
  Future<List<Event>> handleCommand(InvoiceState currentState, Command command) async {
    if (command is CreateInvoiceCommand) {
      return [InvoiceCreatedEvent(
        invoiceId: command.invoiceId,
        walletId: command.walletId,
        addresses: command.addresses,
        amount: command.amount,
        version: currentState.version + 1,
        // ...
      )];
    }

    if (command is MarkInvoicePaidCommand) {
      // Business rule validation
      if (currentState.status != InvoiceStatus.pending) {
        throw StateError('Invoice ${command.invoiceId} is not pending');
      }

      return [InvoicePaidEvent(
        invoiceId: command.invoiceId,
        walletId: currentState.walletId,
        txid: command.txid,
        amountReceived: command.amountReceived,
        addressesPaidTo: command.addressesPaidTo,
        paidAt: command.paidAt ?? DateTime.now(),
        version: currentState.version + 1,
      )];
    }
    // ... other commands
  }

  // Each event yields a new, immutable InvoiceState
  @override
  InvoiceState applyEvent(InvoiceState state, Event event) {
    if (event is InvoiceCreatedEvent) {
      return state.copyWith(
        isCreated: true,
        status: InvoiceStatus.pending,
        amount: event.amount,
        addresses: event.addresses,
        // ...
      );
    }

    if (event is InvoicePaidEvent) {
      return state.copyWith(
        status: InvoiceStatus.paid,
        paidAt: event.paidAt,
        paymentTxid: event.txid,
        // ...
      );
    }
    // ... other events
  }
}
```

**Key Features:**
- Invoice state machine (pending → paid/expired/cancelled)
- Business rule enforcement
- Complete audit trail of invoice lifecycle

### 4. Invoice Coordinator Actor (Coordinator)

Long-lived coordinator for invoice operations:

```dart
// Create an invoice (spawns InvoiceAggregate, requests addresses from wallet)
invoiceCoordinator.tell(CreateInvoiceMessage(
  walletId: 'wallet-001',
  amount: BigInt.from(100000),
  description: 'Payment for services',
  numberOfAddresses: 1,
));

// Mark invoice as paid (routes to InvoiceAggregate)
invoiceCoordinator.tell(MarkInvoicePaidMessage(
  invoiceId: 'invoice-123',
  txid: 'txid-hex',
  amountReceived: BigInt.from(100000),
  addressesPaidTo: ['address1'],
));

// Check invoice status (queries ReadModel)
invoiceCoordinator.tell(CheckInvoiceMessage('invoice-123'));

// List invoices (queries ReadModel with optional filter)
invoiceCoordinator.tell(ListInvoicesMessage(
  walletId: 'wallet-001',
  filterStatus: InvoiceStatus.pending, // Optional
));

// Cancel invoice (routes to InvoiceAggregate)
invoiceCoordinator.tell(CancelInvoiceMessage(
  invoiceId: 'invoice-123',
));
```

**Responsibilities:**
- Routes commands to InvoiceAggregate actors
- Coordinates with WalletManager for address generation
- Queries ReadModelStorage for invoice lookups
- Periodic expiration checks
- Does NOT write to storage (projections do that!)

### 5. Projections (Read-Side Event Handlers)

Projections listen to EventStore and update ReadModels:

```dart
// WalletProjection - Updates wallet read models
class WalletProjection extends Projection<void> {
  @override
  Future<bool> handle(Event event) async {
    if (event is! WalletEvent) return false;

    switch (event) {
      case final UTXOReceivedEvent evt:
        // Update the denormalized UTXO and address rows
        await _handleUTXOReceived(evt);
        return true;
      // ... other wallet events
    }
  }
}

// InvoiceProjection - Updates invoice read models
class InvoiceProjection extends Projection<InvoiceReadModel> {
  @override
  Future<bool> handle(Event event) async {
    if (event is InvoiceCreatedEvent) {
      // Check for existing invoice (idempotent replay)
      final existing = await _storage.getInvoice(event.invoiceId);
      if (existing == null) {
        await _storage.storeInvoice(InvoiceReadModel(
          invoiceId: event.invoiceId,
          walletId: event.walletId,
          // ...
        ));
      }
      return true;
    }

    if (event is InvoicePaidEvent) {
      // Update existing invoice status
      await _storage.updateInvoiceStatus(
        event.invoiceId,
        InvoiceStatus.paid,
        txid: event.txid,
        amountReceived: event.amountReceived,
        paidAt: event.paidAt,
      );
      return true;
    }
    // ... other invoice events
  }
}
```

**Key Features:**
- Subscribes to event stream from EventStore
- Builds denormalized read models
- Checkpointing for idempotent replay
- Eventual consistency (async updates)

### 6. Projection Actors (CQRS Orchestration)

Each projection runs inside an Eventador `ProjectionActor`. Spawning the actor
is the registration; there is no projection manager:

```dart
// Done automatically by LibSpiffyActorSystem, for the wallet, invoice and
// channel projections
final walletProjection = WalletProjection(
  projectionId: 'wallet-projection',
  eventStore: eventStore,
  storage: walletStorage,
);
final walletProjectionRef = await actorSystem.spawn(
  'projection-wallet-projection',
  () => ProjectionActor(walletProjection, eventStream, isar: isar),
);

// ProjectionActor:
// - Owns the event-stream subscription
// - Hands the projection the events it is interested in
// - Keeps the projection's checkpoint (not advanced when handle() fails)
// - Answers AwaitEventApplied, so a coordinator can wait until the read
//   model shows a command's outcome
```

The refs are `LibSpiffyActorSystem.walletProjectionRef`,
`invoiceProjectionRef` and `channelProjectionRef`.

### 7. SPV Actor

Handles SPV transaction validation with BEEF/BUMP merkle proofs:

```dart
// Receive and validate a transaction
spvActor.tell(ReceiveTransactionMessage(
  transactionId: 'txid-hex',
  beef: beefData, // Contains tx + parents + merkle proof
  fromCounterparty: 'alice',
  targetWalletId: 'bob-wallet',
  invoiceId: 'invoice-123', // Links to invoice
));

// SPV Actor will:
// 1. Validate merkle proof against block headers
// 2. Verify outputs match invoice addresses
// 3. Calculate transaction fee
// 4. Extract spendable UTXOs
// 5. Update wallet state via commands
// The coordinator then submits the payment to ARC and marks the invoice
// paid once ARC says the network holds it (SEEN_ON_NETWORK or MINED), not
// on validation alone: a payment the network refuses pays nothing.
```

### 8. ARC Actor

Interfaces with ARC for the transactions the wallet broadcasts (its own, and
the payments it receives) and for the fee rate every transaction pays:

```dart
// Broadcast a transaction; the reply says how far ARC got with it
// (BroadcastSuccessMessage.networkStatus) or why it failed.
arcActor.tell(BroadcastTransactionMessage(walletId, rawTxHex, txid));

// ARC's published policy rate. Every fee the wallet pays is this rate on the
// transaction's signed size; a rate ARC could not be asked for is a failure,
// never a guessed one. There is no replace-by-fee on BSV, so nothing is ever
// paid above it.
final quote = await arcActor.ask<FeeRateQuote>(GetFeeRateMessage(), const Duration(seconds: 30));
final fee = quote.rate?.feeFor(signedSizeBytes);

// How far a transaction the wallet broadcast has got
arcActor.tell(CheckTransactionStatusMessage(txid));
```

### 9. Block Header Sync Actor

Keeps the block header chain (`BlockHeaderChain`) in step with the network: it
asks peers for headers, stores the batches they send, and tells the SPV Actor
about stored headers and reorganizations. Header sync continues from the tip
of the stored chain. This actor does not validate merkle proofs: the SPV Actor
checks a proof against the header chain.

Its messages are LibSpiffy's own and are not exported. An application reads
the chain it keeps:

```dart
final libspiffy = getLibSpiffySystem();

// The stored chain
final height = libspiffy.headerChain.bestHeight;
final tip = libspiffy.headerChain.chainTip;
final header = await libspiffy.headerChain.getHeaderByHeight(850000);

```

The system takes commands before its headers are synced; a payment whose
block header has not arrived yet waits for it. Whether the chain has caught
up with its peers comes from the coordinator:

```dart
libspiffy.coordinator.on<HeaderSyncStatusEvent>().listen((event) {
  final status = event.status; // height, networkHeight, synced, peerCount
});
final now = (await libspiffy.coordinator.ask(GetHeaderSyncStatusQuery())).status;
```

`synced` turns true when a peer answers with less than a full batch of
headers: it had nothing more. Every batch stored is a
`BlockHeadersStoredEvent`.

### 10. Plugin System

LibSpiffy provides an extensible plugin architecture for custom Bitcoin script types and token protocols. Plugins are decoupled from the core library — no compile-time dependency on token implementations.

```dart
// Register a plugin (e.g., tstokenlib for TSL1 tokens)
final registry = PluginRegistry();
registry.register(myTokenPlugin);

// Plugins provide:
// - Script identification: recognize custom script types in UTXOs
// - Metadata extraction: parse protocol-specific data from scripts
// - Lock/unlock builders: construct locking and unlocking scripts
// - Transaction builders: build complete multi-output protocol transactions

// Send a plugin-based payment via coordinator
final tokenPayment = await coordinator.ask(PayInvoiceCommand(
  walletId: 'my-wallet',
  invoiceId: 'invoice-123',
  addresses: [],
  amount: BigInt.zero,
  outputs: [
    PluginOutputSpec(
      pluginId: 'tsl1',
      pluginScriptType: 'pp1_nft',
      params: {...},
      amount: BigInt.one,
    ),
  ],
));
```

The `CallbackTransactionSigner` enables plugins to sign transactions without exposing private keys — the wallet aggregate retains exclusive control of key material.

See [Plugin API Guide](doc/script-plugin-api-guide.md) for the full interface reference.

### 11. Payment Channels

One-way payment channels: a client locks funds in a 2-of-2 output shared with
a server, then pays the server in small increments off-chain. The server
settles on-chain once.

```dart
// A node that does channels says when they stop taking payments and how long
// they must run. There is no default: without it, no channel is requested,
// accepted or paid.
await libspiffy.initialize(
  // ...
  channelPeerId: myPeerId,
  channelTiming: ChannelTiming(
    settlementMargin: const Duration(hours: 1),
    minimumLifetime: const Duration(days: 1),
  ),
);

// Client: open, pay, close. Each returns once its step is done; the open
// once the server has accepted and the funding is on the network.
final channel = await coordinator.ask(OpenChannelCommand(
  walletId: 'my-wallet',
  serverPeerId: serverPeerId,
  fundingAmountSats: 1000000,
  lockTimeDurationSeconds: 7 * 24 * 3600,
));
await coordinator.ask(ChannelPayCommand(channelId: channel.channelId, walletId: 'my-wallet', amountSats: 1000));
await coordinator.ask(CloseChannelCommand(channelId: channel.channelId));
```

Peer messages travel over the app's own transport: deliver what arrives as
`ChannelP2PReceived`, and send what the coordinator emits as
`ChannelP2PMessageToSendEvent`.

**How the protocol protects each side.**

- **Funding:** before the client broadcasts its funding, it holds a refund
  that the server has signed. The refund returns everything to the client
  once the lock time passes. The server opens the channel only after it
  has SPV-validated the funding and submitted it to ARC, and ARC reports
  the network holds it (see "What counts as on the network" below).
- **Payments:** each payment is a transaction spending the funding output,
  signed by the client. The server checks what it pays, its fee, and the
  client's signature. The server keeps its own signature: only the server
  ever holds a fully signed payment, so the client cannot broadcast an
  earlier state that pays the server less.
- **Settlement:** the server settles by broadcasting its latest payment. It
  does this when either side closes the channel, and on its own once the
  settlement margin begins. It then hands the settlement to the client,
  which records its share.
- **Refund:** the client claims its refund (`ClaimChannelRefundCommand`)
  only once the chain's median time past, read from its block headers, is
  after the lock time. The network judges the lock time against that, not
  the clock, and on mainnet it trails the clock by about an hour. Until
  then a node holds the refund only as non-final, and drops it for any
  final spend of the funding output, such as the server's settlement.
- **What counts as on the network:** a channel transaction the library
  submits (the server's funding submission, the settlement, the refund)
  counts as held only when ARC reports `SEEN_ON_NETWORK` or `MINED`. A
  double spend, or an orphan (an input the node cannot connect, or one
  already spent in a block), fails the step, and nothing is recorded;
  repeating the step retries it. A status ARC gives while still processing
  is no verdict: the library asks ARC again until it gives one, at the
  delays `LibSpiffyActorSystem.initialize(arcInFlightFollowDelays:)` sets
  (about 30 s in all by default), and fails the step if it has not.
- **Peers:** messages about a channel are accepted only from the channel's
  counterparty, and only in that counterparty's role.

**Timing (`ChannelTiming`).**

- Within `settlementMargin` of the lock time, no payment is made or
  acknowledged, and the server settles. The margin must cover:
  - the broadcast itself;
  - clock skew between the parties;
  - that the network judges a time lock against the median time of the
    last eleven blocks, not the clock.
- A server accepts a channel only if it has at least `minimumLifetime` to
  run, and only if its lock time is a time rather than a block height.
- A client should ask for comfortably more than its server's minimum,
  because the server measures the remaining time when it accepts.
- A settlement ARC does not take leaves the channel `closing`, and the
  host is told. Closing again retries it, and so does a restart.

**Known risk: fee changes.** A payment's fee is checked against ARC's
policy rate when the server acknowledges it, and the settlement is that
payment. If the policy rate rises before the server settles, ARC may refuse
the settlement. The server cannot re-sign it alone, and BSV has no
replacement. Network fee changes are announced well in advance, so
operators can settle their channels before a change takes effect.

### 12. Additional Coordinators

- **PaymentCoordinatorActor**: Orchestrates multi-step payment flows including plugin-based transactions
- **BenfordCoordinatorActor**: UTXO splitting using Benford's Law distribution for transaction privacy
- **ImportActor**: Wallet import from blockchain via address discovery

## Event Sourcing Flow

### Commands → Events → State

```dart
// 1. Command represents user intention
final command = GenerateAddressCommand(
  commandId: 'gen-addr-1',
  walletId: 'wallet-001',
  purpose: 'receive',
);

// 2. Command handler produces events
final events = [
  AddressGeneratedEvent(
    eventId: 'event-1',
    walletId: 'wallet-001',
    address: 'mipc...', // base58 P2PKH: testnet m or n, mainnet 1
    derivationIndex: 0,
    chain: AddressChain.receive, // key path m/0/0
    purpose: 'receive',
    timestamp: DateTime.now(),
  ),
];

// 3. Events are applied to produce the next state (the aggregate's applyEvent)
final newState = aggregate.applyEvent(currentState, events.first);
```

### Event Types

All events are persisted to EventStore and streamed to Projections for read-model updates.

#### Wallet Events (BitcoinWalletAggregate)
- **WalletCreatedEvent**: New wallet initialized
- **AddressGeneratedEvent**: New address created  
- **AddressLabelUpdatedEvent**: Address label changed
- **UTXOReceivedEvent**: Incoming UTXO detected
- **UTXOSpentEvent**: UTXO consumed in transaction
- **UTXOConfirmationUpdatedEvent**: UTXO confirmation count changed
- **TransactionRecordedEvent**: Outgoing transaction recorded
- **TransactionSignedEvent**: Transaction signed
- **TransactionBroadcastEvent**: Transaction sent to network

#### UTXO Reservation Events (BitcoinWalletAggregate)
- **UTXOReservedEvent**: UTXO marked as reserved
- **UTXOReleasedEvent**: UTXO released from reservation
- **UTXOReservationRenewedEvent**: UTXO reservation extended
- **UTXOReservationPlacedEvent** / **UTXOReservationReleasedEvent** / **UTXOReservationExpiredEvent**: no longer emitted; replayed from journals written by earlier releases

#### Deferred Payment Events (BitcoinWalletAggregate)
- **TransactionSpendDeferredEvent** (`wallet.transaction.spend_deferred`): inputs of a handed-over payment held
- **TransactionNetworkStatusCheckedEvent** (`wallet.transaction.network_status_checked`): network status observed
- **DeferredTransactionFailedEvent** (`wallet.transaction.deferred_failed`): ARC rejected it; inputs released
- **DeferredTransactionCancelledEvent** (`wallet.transaction.deferred_cancelled`): cancelled; inputs released
- **DeferredSpendReclaimedEvent** (`wallet.transaction.deferred_reclaimed`): reclaimed; inputs spent back to the wallet
- **DeferredSpendCompletedEvent** (`wallet.transaction.deferred_completed`): the counterparty's completed transaction recorded in the half's place
- **TransactionVoidedEvent** (`wallet.transaction.voided`): an unsettled transaction whose input a confirmed transaction spends; its pending outputs are voided

#### Invoice Events (InvoiceAggregate)
- **InvoiceCreatedEvent**: Invoice created with payment addresses
- **InvoiceStatusChangedEvent**: no longer emitted; replayed from journals written by earlier releases
- **InvoicePaidEvent**: Invoice marked as paid after SPV validation
- **InvoiceExpiredEvent**: Invoice expired before payment
- **InvoiceCancelledEvent**: Invoice cancelled by user

#### Payment Channel Events (PaymentChannelAggregate)
- **ChannelRequestedEvent** / **ChannelAcceptedEvent** / **ChannelRejectedEvent**: a channel proposed, accepted by the server, or refused
- **RefundBuiltEvent** / **RefundCountersignedEvent**: the client's refund, and the server's signature on it
- **FundingBroadcastStartedEvent** / **FundingBroadcastFailedEvent** / **FundingRecordedInWalletEvent**: the client's funding reaching the network and its wallet
- **ChannelOpenedEvent**: the funding output the channel spends
- **PaymentRecordedEvent** (client) / **PaymentAcknowledgedEvent** (server): a payment
- **ChannelClosingEvent** / **ChannelClosedEvent**: a cooperative close, and its settlement
- **ChannelExpiredEvent** / **RefundClaimedEvent**: the lock time passed; the client's refund broadcast
- **ReturnLegRecordedInWalletEvent**: the transaction that ended the channel is in this side's wallet
- **PaymentCountersignedEvent**: deprecated, replayed from older client journals only

**Note**: All domain events are persisted to EventStore and streamed to their respective projections (WalletProjection, InvoiceProjection, ChannelProjection) for read model updates.

## Security Features

### SPV Verification
- **BEEF (Background Evaluation Extended Format)**: Validates transactions with parent transaction context
- **BUMP (BSV Universal Merkle Path)**: Efficient merkle proof format for SPV validation
- **Merkle Proof Validation**: Cryptographic verification against block header chain
- **Header Chain Validation**: Ensures block headers form a valid chain
- **Invoice-Based Address Verification**: Confirms payments to expected addresses only
- **Transaction Authenticity**: Verification without full blockchain download

### UTXO Management
- **Atomic UTXO Selection**: Reservation prevents double-spending
- **Automatic Cleanup**: Expired reservations released automatically
- **Deferred-Payment Holds**: Inputs of a payment handed to a recipient are never released by expiry; only the network's answer or a cancellation ends the hold
- **Event-Sourced Tracking**: Full history of UTXO lifecycle
- **Fee Calculation**: Accurate fee computation from BEEF data

### Payment Verification
- **Invoice System**: Pre-allocated addresses for expected payments
- **Amount Validation**: Confirms payment matches invoice amount
- **Expiration Handling**: Time-limited invoices prevent indefinite address monitoring
- **Privacy**: Single-use addresses linked to specific payments

### Event Integrity
- **Immutable Event Log**: All state changes permanently recorded
- **Complete Audit Trail**: Full history of wallet operations
- **Snapshot Support**: Performance optimization with integrity checks
- **Idempotent Commands**: Safe command replay and retry

## Configuration

### Storage Backend

```dart
// Mobile/Desktop — Isar embedded database
final libspiffy = LibSpiffyActorSystem();
await libspiffy.initialize(dataDirectory: './wallet-data');

// Server — PostgreSQL
await libspiffy.initialize(
  storageBackend: StorageBackend.postgres,
  // SSL is required by default; a local server without TLS needs
  // '?sslmode=disable'. Use sslmode=verify-full in production.
  postgresConfig: PostgresConfig.fromConnectionString(
    'postgresql://user:pass@localhost:5432/wallets?sslmode=disable',
  ),
);

// Development — In-memory
await libspiffy.initialize(
  storageBackend: StorageBackend.inMemory,
);
```

### Network Configuration

```dart
// ARC Service (for transaction broadcasting)
final arcConfig = ArcServiceConfig(
  baseUrl: 'https://arc.taal.com/v1',
  apiKey: 'your-api-key',
);
// Or use presets:
ArcServiceConfig.taalMainnet(apiKey: 'your-api-key');
ArcServiceConfig.taalTestnet(apiKey: 'your-api-key');
ArcServiceConfig.gorillaPoolMainnet();
ArcServiceConfig.gorillaPoolTestnet();
// Arcade, the Teranode-era ARC, serves the same API at its root (no /v1):
ArcServiceConfig.bsvaArcadeTestnet();
// The wallet pays ARC's published policy rate. An app that knows its
// network sets a floor under it (an ARC can publish a rate no miner mines
// at); libspiffy assumes none of its own:
ArcServiceConfig.gorillaPoolTestnet(minimumFeeRate: const FeeRate(satoshis: 1, bytes: 1000));

await libspiffy.initialize(
  dataDirectory: './wallet-data',
  networkType: 'main', // 'main' or 'test' (default)
  arcConfig: arcConfig,
  // CDN-based fast header sync (https), before headers come from peers
  cdnBaseUrl: 'https://cdn.example.com/headers',
  onHeaderSyncProgress: (current, total, phase) {},
  onHeaderSyncResult: (CdnSyncResult result) {
    // success, or the error that ended it, or that no CDN was configured
  },
  // P2P header sync
  enableP2P: true,
  peerAddresses: ['seed.example.com:8333'], // optional; the network's DNS seeds otherwise
);
```

`startHeight` is the block height this node reports to peers in its version
handshake. Header sync does not start from it: it continues from the tip of
the stored header chain.

## Testing

```bash
# Run all tests
dart test

# Run by category
dart test test/unit/                    # Unit tests
dart test test/integration/             # Integration tests
dart test test/services/                # Service tests
dart test test/core_models/             # Domain model tests

# PostgreSQL storage (needs a running PostgreSQL; see
# test/storage/postgres/postgres_integration_test.dart)
POSTGRES_DATABASE=libspiffy_test dart test --tags=postgres test/storage/postgres/

# Against a real regtest Teranode and Arcade (needs ../localnet-teranode:
# Arcade :23011, RPC :19292, DataHub :18090, wire protocol :18444; coins
# come from its faucet; LOCALNET_TERANODE names another checkout). Skipped
# unless asked for; they mine blocks on the stack's shared chain.
# LOCALNET_LOG=1 prints the library's logs, tagged by node.
dart test -P localnet test/integration/localnet_node_e2e_test.dart      # header sync, restarts
dart test -P localnet test/integration/localnet_payment_e2e_test.dart   # invoices and payments
dart test -P localnet test/integration/localnet_channel_e2e_test.dart   # payment channels
dart test -P localnet test/integration/localnet_deferred_e2e_test.dart  # deferred payments, double spends
dart test -P localnet test/integration/localnet_reorg_e2e_test.dart     # chain reorganizations
dart test -P localnet test/integration/localnet_delegated_payment_e2e_test.dart  # payment to an offline xpub payee
dart test -P localnet test/integration/localnet_type42_payment_e2e_test.dart     # type-42 payment to an offline payee

# Against the public testnet Arcade, reading from WhatsOnChain. Skipped
# unless asked for.
dart test -P arcade test/integration/arcade_testnet_live_test.dart
```

### What the suite covers

- **Integration tests**: end-to-end flows including the coordinator API, P2P payments and payment channels (also against a real regtest Teranode and Arcade), SPV validation, token lifecycle, invoice persistence, wallet import, header sync
- **Unit tests**: plugin registry, output specs, encryption, CDN sync, script builders
- **Service tests**: ARC service, payment channels, address discovery, WhatsOnChain TSC proofs
- **Core model tests**: UTXO, transaction, wallet state, commands, events
- **Storage tests**: Isar schemas, wallet storage, PostgreSQL integration
- **Actor and aggregate tests**: the actors, the channel, wallet and invoice aggregates, and their replies
- **Format tests**: BEEF/BUMP parsing, format equivalence, SPV validation
- **Crypto tests**: DartSV crypto service, key derivation

## Development

### Project Structure
```
lib/
├── libspiffy.dart                       # Primary barrel file
├── coordinator.dart                     # Public API (WalletCoordinator, requests, replies, events)
├── internals.dart                       # Aggregate commands, domain events (advanced use)
└── src/
    ├── actors/                          # Actor System
    │   ├── libspiffy_actor_system.dart      # System initialization & event registration
    │   ├── wallet_coordinator.dart           # WalletCoordinator: tell, ask, on
    │   ├── wallet_coordinator_actor.dart     # The actor behind WalletCoordinator
    │   ├── wallet_manager_actor.dart         # Wallet aggregate coordinator
    │   ├── invoice_coordinator_actor.dart    # Invoice aggregate coordinator
    │   ├── payment_coordinator_actor.dart    # Payment flow orchestration
    │   ├── spv_actor.dart                    # SPV validation with BEEF/BUMP
    │   ├── arc_actor.dart                    # ARC service integration
    │   ├── header_sync_actor.dart            # Block header synchronization
    │   ├── benford_coordinator_actor.dart    # Privacy-preserving UTXO splitting
    │   ├── import_actor.dart                 # Wallet import from blockchain
    │   ├── channel_p2p_adapter.dart          # Payment channel P2P communication
    │   ├── coordinator_messages.dart         # Public API commands/events
    │   ├── wallet_messages.dart              # Wallet actor messages
    │   ├── invoice_messages.dart             # Invoice actor messages
    │   ├── payment_messages.dart             # Payment flow messages
    │   ├── payment_channel_messages.dart     # Channel protocol messages
    │   └── spv_messages.dart                 # SPV and header sync messages
    ├── core/                            # Domain Aggregates (Write Side)
    │   ├── bitcoin_wallet_aggregate.dart     # Event-sourced wallet
    │   ├── invoice_aggregate.dart            # Event-sourced invoices
    │   ├── payment_channel_aggregate.dart    # Event-sourced payment channels
    │   ├── wallet_commands.dart              # Wallet command definitions
    │   ├── wallet_events.dart                # Wallet event definitions
    │   ├── invoice_commands.dart             # Invoice command definitions
    │   ├── invoice_events.dart               # Invoice event definitions
    │   ├── channel_commands.dart             # Channel command definitions
    │   ├── channel_events.dart               # Channel event definitions
    │   └── channel_state.dart                # Channel aggregate state
    ├── plugin/                          # Extensible Plugin System
    │   ├── script_plugin.dart               # Base plugin interface
    │   ├── transaction_builder_plugin.dart   # Multi-output transaction builder
    │   ├── plugin_registry.dart             # Plugin discovery & management
    │   └── plugin_types.dart                # Plugin data structures
    ├── projections/                     # CQRS Read Side
    │   ├── wallet_projection.dart           # Wallet read model updates
    │   ├── invoice_projection.dart          # Invoice read model updates
    │   └── channel_projection.dart          # Channel read model updates
    ├── models/                          # Domain Models
    │   ├── wallet_state.dart                # Wallet aggregate state
    │   ├── wallet_read_model.dart           # Wallet query model
    │   ├── invoice_state.dart               # Invoice aggregate state
    │   ├── invoice_read_model.dart          # Invoice query model
    │   ├── invoice_output_spec.dart         # Multi-output specs (P2PKH, P2MS, OP_RETURN, Plugin)
    │   ├── bitcoin_utxo.dart                # UTXO model with plugin metadata
    │   ├── bitcoin_transaction.dart         # Transaction model
    │   ├── address_metadata.dart            # Address with script type and usage
    │   ├── blockchain_data_models.dart      # Blockchain API response models
    │   ├── payment_channel.dart             # Channel read model
    │   ├── transaction_address_link.dart    # Transaction-address junction
    │   └── wallet_type.dart                 # Enum: HD, WIF, XPRIV, XPUB
    ├── spv/                             # SPV Validation
    │   ├── block_header_chain.dart          # Header chain management
    │   ├── cdn_header_sync_service.dart     # Fast CDN-based header sync
    │   ├── cdn_header_sync_config.dart      # CDN sync configuration
    │   └── cdn_manifest.dart                # CDN manifest structures
    ├── storage/                         # Persistence Layer
    │   ├── read_model_storage.dart          # Read model interface
    │   ├── event_storage.dart               # Event store interface
    │   ├── secure_storage.dart              # Encrypted key storage interface
    │   ├── storage_backend.dart             # Backend enum & factory
    │   ├── isar_wallet_storage.dart         # Isar implementation (mobile/desktop)
    │   ├── in_memory_wallet_storage.dart    # In-memory (dev/test)
    │   ├── in_memory_secure_storage.dart    # In-memory key storage (dev/test)
    │   ├── libspiffy_schemas.dart           # Isar schema definitions
    │   ├── payment_channel_entity.dart      # Channel Isar entity
    │   └── postgres/                        # PostgreSQL backend (server)
    │       ├── postgres_config.dart             # Connection & pool config
    │       ├── postgres_wallet_storage.dart      # Read model store
    │       ├── postgres_event_store.dart         # Event sourcing store
    │       ├── postgres_secure_storage.dart      # Encrypted key storage
    │       ├── postgres_migrations.dart          # Migration infrastructure
    │       └── migrations/                      # Schema versions
    │           ├── v001_initial_schema.dart
    │           ├── v002_secure_secrets.dart
    │           └── ...                              # up to v029_deferred_payment_deadline.dart
    ├── services/                        # Business Logic Services
    │   ├── crypto_service.dart              # Cryptographic interface (BIP32/39)
    │   ├── dartsv_crypto_service.dart       # DartSV crypto implementation
    │   ├── callback_transaction_signer.dart # Secure signer for plugins
    │   ├── arc_service.dart                 # ARC API client
    │   ├── arc_service_config.dart          # ARC configuration
    │   ├── ancestor_chain_service.dart      # Transaction ancestry chains
    │   ├── payment_channel_builder.dart     # Channel transaction builder
    │   ├── address_discovery_service.dart   # Hierarchical address discovery
    │   ├── script_type_registry.dart        # Script type identification
    │   ├── transaction_analyzer.dart        # Two-phase UTXO analysis
    │   ├── transaction_import_service.dart  # Historical transaction import
    │   ├── blockchain_data_source.dart      # Blockchain API interface
    │   ├── whatsonchain_data_source.dart    # WhatsOnChain implementation
    │   └── transaction/builder/             # Lock/unlock script builders
    │       ├── hodl_lockbuilder.dart            # Time-locked scripts
    │       ├── hodl_unlockbuilder.dart
    │       ├── op_return_lockbuilder.dart       # OP_RETURN metadata
    │       └── ...                              # AIP, BMAP, MAP, B://, PP1, PP2, partial witness
    ├── crypto/                          # Encryption
    │   └── encryption_service.dart          # AES-256-GCM with HKDF
    ├── integration/                     # External System Bridges
    │   └── spiffynode_bridge.dart           # SpiffyNode P2P bridge
    └── utils/                           # Utilities
        ├── beef.dart                        # BEEF format parsing
        ├── bump.dart                        # BUMP merkle path utilities
        ├── benford_distribution.dart        # Benford's Law splitting
        ├── crypto_utils.dart                # Cryptographic helpers
        ├── hex_utils.dart                   # Hex conversion
        └── tsc_converter.dart               # TSC merkle proof to BUMP conversion
```

**Key Architectural Layers:**
- **actors/**: Long-lived coordinators that route commands; WalletCoordinator is the single public entry point
- **core/**: Event-sourced aggregates (write-side domain logic)
- **plugin/**: Extensible system for custom script types and token protocols
- **projections/**: Read-side event handlers (update read models)
- **models/**: Separated into aggregate state (immutable: each event yields a new state) and read models (denormalized)
- **spv/**: Block header chain, CDN header sync and merkle proof checks (BEEF/BUMP parsing is in utils/)
- **storage/**: Read model persistence — Isar (mobile), PostgreSQL (server), in-memory (dev); the event store is Eventador's Isar store, or libspiffy's PostgreSQL event store on a server

### Adding New Features

#### Adding Wallet Commands/Events (CQRS Pattern)

Follow these steps to add new functionality using proper CQRS patterns:

**Step 1: Define Command**
```dart
// Add to lib/src/core/wallet_commands.dart
class MyNewCommand extends WalletCommand {
  final String someParameter;

  MyNewCommand({
    required String walletId,
    required this.someParameter,
    String? commandId,
    DateTime? timestamp,
    Map<String, dynamic>? metadata,
  }) : super(
          walletId: walletId,
          commandId: commandId,
          timestamp: timestamp,
          metadata: metadata,
        );

  @override
  String get commandType => 'MyNewCommand';
}
```

**Step 2: Define Event**
```dart
// Add to lib/src/core/wallet_events.dart
class MyNewEvent extends WalletEvent {
  /// Journal identifier of this event type. Stored with every event and
  /// independent of the class name; never change it.
  static const String stableTypeName = 'wallet.my_new';

  @override
  String get typeName => stableTypeName;

  final String someData;

  MyNewEvent({
    required String walletId,
    required this.someData,
    String? eventId,
    DateTime? timestamp,
    int? version,
  }) : super(
    walletId: walletId,
    eventId: eventId,
    timestamp: timestamp,
    version: version,
  );

  @override
  Map<String, dynamic> getWalletEventData() {
    return {
      'someData': someData,
    };
  }
  
  // CRITICAL: fromMap for deserialization after restart
  static MyNewEvent fromMap(Map<String, dynamic> map) {
    return MyNewEvent(
      walletId: map['walletId'] as String,
      someData: map['someData'] as String,
      eventId: map['eventId'] as String?,
      timestamp: map['timestamp'] != null
          ? (map['timestamp'] is String
              ? DateTime.parse(map['timestamp'])
              : map['timestamp'] as DateTime)
          : null,
      version: map['version'] as int?,
    );
  }
}
```

**Step 3: Register Event Type**
```dart
// Add to lib/src/actors/libspiffy_actor_system.dart → registerEventTypes()
EventRegistry.register<MyNewEvent>(MyNewEvent.stableTypeName, MyNewEvent.fromMap);
```

**Step 4: Add Command Handler in BitcoinWalletAggregate**
```dart
// In lib/src/core/bitcoin_wallet_aggregate.dart → handleCommand()
@override
Future<List<Event>> handleCommand(WalletState currentState, Command command) async {
  switch (command) {
    case final MyNewCommand cmd:
      return _handleMyNewCommand(currentState, cmd);
    // ... other commands
  }
}

List<Event> _handleMyNewCommand(WalletState state, MyNewCommand cmd) {
  // Validate business rules
  if (!state.isCreated) {
    throw StateError('Wallet not yet created');
  }
  
  // Perform business logic
  final result = performSomeOperation(cmd.someParameter);
  
  // Return events (not state changes!)
  return [
    MyNewEvent(
      walletId: cmd.walletId,
      someData: result,
      version: state.version + 1,
    ),
  ];
}
```

**Step 5: Apply the Event in BitcoinWalletAggregate**
```dart
// In lib/src/core/bitcoin_wallet_aggregate.dart → applyEvent()
@override
WalletState applyEvent(WalletState current, Event event) {
  if (event is! WalletEvent) {
    throw ArgumentError('Expected WalletEvent, got ${event.runtimeType}');
  }
  // current is never modified: the event is applied to a draft of it
  final state = current.toBuilder();

  switch (event) {
    case final MyNewEvent evt:
      _applyMyNewEvent(state, evt);
    // ... other events
  }

  return state.build();
}

// Fill in the draft (add someField to WalletState and WalletStateBuilder)
void _applyMyNewEvent(WalletStateBuilder state, MyNewEvent event) {
  state.someField = event.someData;
  state.version = event.version;
  state.lastModified = event.timestamp;
}
```

**Step 6: Update Projection (if needed)**
```dart
// In lib/src/projections/wallet_projection.dart: add MyNewEvent to
// interestedEventTypes, and an arm to handle()
@override
Future<bool> handle(Event event) async {
  if (event is! WalletEvent) {
    return false;
  }

  switch (event) {
    case final MyNewEvent evt:
      // Update the read model through ReadModelStorage (_storage); a new
      // kind of row needs a method on the interface and on every backend
      await _handleMyNewEvent(evt);
      return true;
    // ... other events
  }
}
```

**Key Points:**
- ✅ Commands go to aggregates via coordinators
- ✅ Aggregates validate and emit events
- ✅ Events are persisted to EventStore automatically
- ✅ Projections update read models asynchronously
- ✅ All event types MUST be registered for deserialization
- ❌ Never write to storage from aggregates or coordinators

#### Adding Actor Messages

1. **Define Message in wallet_messages.dart or custom file**
   ```dart
   class MyNewMessage implements Message {
     final String data;

     MyNewMessage(this.data);

     @override
     String get correlationId => 'my-new-message-$data';
     @override
     Map<String, dynamic> get metadata => {'data': data};
     @override
     ActorRef? get replyTo => null;
     @override
     DateTime get timestamp => DateTime.now();
   }
   ```

2. **Handle Message in Actor**
   ```dart
   @override
   Future<void> onMessage(dynamic message) async {
     switch (message) {
       case final MyNewMessage msg:
         await _handleMyNewMessage(msg);
       // ... other cases
     }
   }
   
   Future<void> _handleMyNewMessage(MyNewMessage msg) async {
     // Process message
     // Optionally send response
     context.sender?.tell(MyResponseMessage(...));
   }
   ```

## Best Practices

### Event Sourcing Patterns

✅ **DO**:
- Keep events immutable and descriptive
- Store business intent in events, not just data changes
- Use event versioning for schema evolution
- Apply events in order to rebuild state

❌ **DON'T**:
- Query the EventStore directly for business logic
- Modify events after they're persisted
- Store computed values in events (recalculate from state)
- Skip event application during replay

### Actor Communication

✅ **DO**:
- Use message-passing for all actor communication
- Implement proper command-response patterns
- Handle timeouts and failures gracefully
- Keep messages immutable

❌ **DON'T**:
- Access actors' internal state directly
- Use fire-and-forget for operations requiring confirmation
- Block waiting for responses (use async patterns)
- Share mutable state between actors

### Actor System Integration

✅ **DO**:
- Use integrated mode when building actor-based applications
- Let the host application manage actor system lifecycle
- Use standalone mode for simple use cases or microservices
- Check `ownsActorSystem` if lifecycle management is unclear
- Provide custom storage/crypto implementations via initialization

❌ **DON'T**:
- Create multiple actor systems unnecessarily
- Shutdown the host's actor system from LibSpiffy
- Mix standalone and integrated modes in same application
- Assume LibSpiffy owns the actor system without checking

### SPV Validation

✅ **DO**:
- Always validate merkle proofs against block headers
- Verify payment amounts match invoices
- Calculate fees from BEEF data
- Use invoice-based address verification

❌ **DON'T**:
- Trust transaction data without merkle proof
- Accept payments to unexpected addresses
- Skip block header chain validation
- Process transactions without proper BEEF context

### UTXO Management

✅ **DO**:
- Let `PayInvoiceCommand` select and hold a payment's inputs; it reserves them before it builds
- Settle every payment you hand over: the recipient broadcasts it, or you broadcast, cancel or reclaim it (the deferred-payment commands)
- Give a payment a `deadline` when its counterparty may never complete or broadcast it
- Release a reservation you no longer need with `ReleaseUTXOsCommand`
- Record a transaction built outside the wallet that spends its outputs (`RecordOutgoingCommand`)

❌ **DON'T**:
- Expect a payment's held inputs to come back with time: only the network's answer, a cancellation or a reclaim ends the hold
- Track UTXO state outside the wallet: read it from the read model, or ask the coordinator

## Documentation

- [Developer Guide](doc/developer-guide.md) — Public API reference and programming model
- [Plugin API Guide](doc/script-plugin-api-guide.md) — Building custom script/token plugins
- [Multi-Output Invoice Guide](doc/multi-output-invoice-guide.md) — P2PKH, P2MS, OP_RETURN, and plugin outputs
- [CDN Header Sync Guide](doc/cdn-header-sync-guide.md) — Fast block header synchronization
- [PostgreSQL Secure Storage Guide](doc/postgres-secure-storage-guide.md) — Server deployment with encrypted keys
- [Projections Guide](projections-guide.md) — Building CQRS read models
- [Wallet Architecture](wallet-architecture.md) — Detailed system architecture
- [SPV Understanding](spv-understanding.md) — SPV concepts and implementation

## Acknowledgments

- **[Dactor](https://github.com/twostack/dactor)**: Actor model framework for Dart
- **[Eventador](https://github.com/twostack/eventador)**: Event sourcing and CQRS library
- **[DuraQ](https://github.com/twostack/duraq)**: Operational workflow management
- **[DartSV](https://github.com/twostack/dartsv)**: Bitcoin SV library for Dart
- **[SpiffyNode](https://github.com/twostack/spiffynode)**: SPV chain tracking and P2P connectivity

## Further Reading

### Architecture Patterns
- [Event Sourcing Pattern](https://martinfowler.com/eaaDev/EventSourcing.html)
- [CQRS Pattern](https://docs.microsoft.com/en-us/azure/architecture/patterns/cqrs)
- [Actor Model](https://en.wikipedia.org/wiki/Actor_model)
- [Domain-Driven Design](https://martinfowler.com/bliki/DomainDrivenDesign.html)

### Bitcoin & BSV
- [SPV (Simplified Payment Verification)](https://bitcoin.org/bitcoin.pdf)
- [BEEF Specification](https://bsv.brc.dev/transactions/0062) - Background Evaluation Extended Format
- [BUMP Specification](https://bsv.brc.dev/transactions/0058) - BSV Universal Merkle Path
- [BRC-71 Standard](https://bsv.brc.dev/transactions/0071) - Merkle Path Format

## License

This project is licensed under the MIT License - see the LICENSE file for details.
