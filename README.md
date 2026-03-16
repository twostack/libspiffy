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
-  HD wallet address generation and management
-  UTXO tracking with confirmation status
-  Transaction creation and signing
-  SPV transaction verification with merkle proofs (BEEF/BUMP)
-  Multi-wallet support with isolation
-  Event-sourced state with full audit trail

### Advanced Features
-  **Invoice-based payment system** for simplified SPV validation
-  UTXO holds and reservations
-  Funding requests for transaction preparation
-  Automatic cleanup of expired holds
-  Snapshot support for performance optimization
-  Real-time balance calculations
-  **ARC service integration** for transaction broadcasting and fee estimation
-  Transaction fee calculation from BEEF data

### Network Integration
-  Bitcoin P2P network connectivity
-  Block header synchronization and validation
-  **BEEF (Background Evaluation Extended Format)** transaction validation
-  **BUMP (BSV Universal Merkle Path)** merkle proof validation
-  Merkle proof validation against header chain
-  ARC (Authoritative Repository of Certificates) service integration

## System Architecture

LibSpiffy implements a **CQRS (Command Query Responsibility Segregation)** architecture with complete separation between write operations (commands → events → EventStore) and read operations (queries → ReadModels).

```
┌────────────────────────────────────────────────────────────────────────────┐
│                        LibSpiffy CQRS Architecture                         │
├────────────────────────────────────────────────────────────────────────────┤
│                                                                            │
│  PUBLIC API (import 'package:libspiffy/coordinator.dart')                 │
│  ┌────────────────────────────────────────────────────────────────────┐   │
│  │  WalletCoordinatorActor (Unified Facade)                          │   │
│  │  • Send: CreateWalletCommand, PayInvoiceCommand, GetBalanceQuery  │   │
│  │  • Recv: WalletCreatedEvent, PaymentReadyEvent, BalanceResponse   │   │
│  │  • Handles correlation tracking, error routing, channel P2P       │   │
│  └──────────────────────────────┬─────────────────────────────────────┘   │
│                                 │ Internal delegation                     │
│  COMMAND SIDE (Write Operations)│                                         │
│  ┌──────────────────┐      ┌───┴────────────────┐                         │
│  │ Wallet Manager   │─────▶│ Invoice Coordinator│                         │
│  │ Actor            │      │ Actor              │                         │
│  │ • Routes cmds    │      │ • Routes invoice   │                         │
│  │ • Spawns aggr.   │      │   commands         │                         │
│  │ • Multi-wallet   │      │ • Spawns invoice   │                         │
│  └────────┬─────────┘      │   aggregates       │                         │
│           │                └──────────┬─────────┘                          │
│           ▼                           ▼                                    │
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
│              │ Projection Mgr  │  (Read-Only from EventStore)             │
│              └────────┬────────┘                                          │
│         ┌─────────────┴─────────────┐                                     │
│         ▼                           ▼                                     │
│  ┌──────────────┐          ┌──────────────┐                              │
│  │   Wallet     │          │   Invoice    │                              │
│  │  Projection  │          │  Projection  │                              │
│  └──────┬───────┘          └──────┬───────┘                              │
│         └────────────┬────────────┘                                      │
│                      ▼                                                   │
│           ┌─────────────────────┐                                        │
│           │  Read Model Storage │  (Isar / PostgreSQL / In-Memory)       │
│           └─────────────────────┘                                        │
│                      ▲                                                   │
│  QUERY SIDE (Read Operations)                                            │
│  ┌──────────────────┐     ┌────────────────┐     ┌─────────────────┐     │
│  │   SPV Actor      │     │   ARC Actor    │     │ Header Sync     │     │
│  │ • BEEF/BUMP val. │     │ • Broadcast    │     │ • Block headers │     │
│  │ • Invoice match  │     │ • Fee estimate │     │ • Merkle proofs │     │
│  │ • Fee calc       │     │ • Policy query │     │ • Chain valid.  │     │
│  └──────────────────┘     └────────────────┘     └─────────────────┘     │
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
- Dependencies: dactor, eventador, duraq, dartsv

### ⚠️ Critical: Event Type Registration

**Before using LibSpiffy**, you must understand that all event types must be registered with Eventador's `EventRegistry` for proper CBOR deserialization after system restarts.

**LibSpiffy handles this automatically** during initialization via `_registerEventTypes()`, but if you're extending LibSpiffy with custom events, you'll need to register them:

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
- 11 Wallet events (WalletCreatedEvent, AddressGeneratedEvent, UTXOReceivedEvent, etc.)
- 5 Invoice events (InvoiceCreatedEvent, InvoicePaidEvent, etc.)

**Why this matters:**
- Events are stored in CBOR format in the EventStore
- After restart, Eventador needs to deserialize events back into Dart objects
- Without registration: `ArgumentError: Event type 'XYZ' not registered`

See the [Eventador README](../eventador/README.md#event-type-registry-critical) for complete details on event registration.

### Installation

```bash
# Clone the repository
git clone <repository-url>
cd libspiffy

# Install dependencies
dart pub get

# Run the example
dart run example/bitcoin_wallet_example.dart
```

### Basic Usage (Coordinator API - Recommended)

The **WalletCoordinatorActor** is the canonical public interface for third-party apps. It provides a unified command/event API that handles all internal actor orchestration, correlation tracking, and async response routing.

```dart
import 'package:libspiffy/libspiffy.dart';
import 'package:libspiffy/coordinator.dart';

// Initialize LibSpiffy
final libspiffy = LibSpiffyActorSystem();
await libspiffy.initialize(
  dataDirectory: './wallet-data',
  arcConfig: ArcServiceConfig.taalMainnet(),
  enableP2P: true,
);

// Use the coordinator - THE single entry point
final coordinator = libspiffy.coordinator;

// Subscribe to events
libspiffy.coordinatorEvents?.listen((event) {
  if (event is WalletCreatedEvent) {
    print('Wallet created: ${event.walletId}');
  } else if (event is PaymentReadyEvent) {
    print('BEEF ready to send: ${event.txid}');
  } else if (event is BalanceResponse) {
    print('Balance: ${event.totalBalance} sats');
  }
});

// Send commands
coordinator.tell(CreateWalletCommand(
  walletId: 'my-wallet',
  name: 'My Bitcoin Wallet',
));

coordinator.tell(CreateInvoiceCommand(
  walletId: 'my-wallet',
  amount: BigInt.from(100000),
  description: 'Payment for services',
));

coordinator.tell(GetBalanceQuery(walletId: 'my-wallet'));

// Cleanup
await libspiffy.shutdown();
```

### Direct Actor Access (Advanced)

For advanced use cases, you can access internal actors directly:

```dart
import 'package:libspiffy/libspiffy.dart';

await initializeLibSpiffy(dataDirectory: './wallet-data');

// Direct actor access (advanced - most apps should use the coordinator)
final walletManager = getLibSpiffySystem().walletManager;
final spvActor = getLibSpiffySystem().spvActor;

walletManager.tell(CreateWalletMessage('my-wallet', 'My Wallet'));

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
walletManager.tell(CreateWalletMessage(...));

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

LibSpiffy provides a built-in `WalletCoordinatorActor` that serves as the canonical gateway. You no longer need to build your own:

```dart
import 'package:libspiffy/coordinator.dart';

// The coordinator IS the gateway - no custom actor needed
final coordinator = getLibSpiffySystem().coordinator;

// Send any command
coordinator.tell(CreateWalletCommand(walletId: 'my-wallet', name: 'My Wallet'));
coordinator.tell(PayInvoiceCommand(walletId: 'my-wallet', invoiceId: '...', ...));
coordinator.tell(GetBalanceQuery(walletId: 'my-wallet'));

// Subscribe to all events
getLibSpiffySystem().coordinatorEvents?.listen((event) {
  switch (event) {
    case WalletCreatedEvent e: handleWalletCreated(e);
    case PaymentReadyEvent e: handlePaymentReady(e);
    case BEEFValidationResultEvent e: handleBEEFValidated(e);
    case ErrorEvent e: handleError(e);
    default: break;
  }
});
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
│ • Invoice        │            │  Manager     │                         │
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
// Coordinator spawns or retrieves aggregate actor
final invoiceAggregateRef = await actorSystem.spawn(
  'Invoice_$invoiceId',
  () => InvoiceAggregate(
    persistenceId: 'Invoice_$invoiceId',
    eventStore: eventStore,
  ),
);

// Sends command to aggregate
invoiceAggregateRef.tell(CreateInvoiceCommand(...));
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
// This happens BEFORE eventHandler is called
```

**Step 5: Event Application**
```dart
// Inside InvoiceAggregate.eventHandler()
@override
void eventHandler(Event event) {
  ensureStateInitialized(); // Critical for recovery
  
  if (event is InvoiceCreatedEvent) {
    // Mutate currentState directly (new in Eventador)
    currentState.status = InvoiceStatus.pending;
    currentState.amount = event.amount;
    currentState.addresses = event.addresses;
    currentState.createdAt = event.timestamp;
    currentState.version++;
  }
}
```

#### Read Side (EventStore → Projections → ReadModels)

**Step 6: Event Streaming**
```dart
// ProjectionManager subscribes to EventStore
// Streams events to registered projections
await projectionManager.start(); // Starts event stream processing
```

**Step 7: Projection Handling**
```dart
// InvoiceProjection.handle() receives events
@override
Future<bool> handle(Event event) async {
  if (event is InvoiceCreatedEvent) {
    // Create denormalized read model
    final invoice = Invoice(
      invoiceId: event.invoiceId,
      walletId: event.walletId,
      addresses: event.addresses,
      amount: event.amount,
      status: InvoiceStatus.pending,
      createdAt: event.createdAt,
      // ... optimized for queries
    );
    
    // Write to ReadModelStorage (Isar)
    await storage.storeInvoice(invoice);
    
    // Update checkpoint for idempotent replay
    await updateCheckpoint(event.version);
    
    return true; // Event handled
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
  final invoice = await storage.getInvoice(msg.invoiceId);
  
  context.sender?.tell(InvoiceDetailsResponse(
    invoiceId: invoice.invoiceId,
    status: invoice.status,
    // ... all denormalized data
  ));
}
```

### Recovery After Restart

When the system restarts, aggregates recover their state by replaying events:

```dart
// 1. Aggregate spawned during recovery
final aggregate = InvoiceAggregate(
  persistenceId: 'Invoice_abc123',
  eventStore: eventStore,
);

// 2. AggregateRoot.preStart() automatically replays events from EventStore
// 3. Events applied via eventHandler() to rebuild state
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

LibSpiffy uses **two separate Isar databases with different schemas**:

**EventStore (Write-Only by Aggregates)**
- Schema: `EventEnvelope`, `SnapshotEnvelope` (from Eventador)
- Format: CBOR-serialized events
- Access: AggregateRoot base class only
- Purpose: Immutable audit trail, recovery

**ReadModelStorage (Write-Only by Projections, Read by App)**
- Schema: `InvoiceEntity`, `BitcoinUtxoEntity`, `BitcoinTransactionEntity` (from LibSpiffy)
- Format: Denormalized domain objects
- Access: Projections write, application reads
- Purpose: Fast queries, optimized for reads

This separation ensures:
- Clear CQRS boundaries
- Independent scaling of read/write
- No accidental EventStore queries
- Optimized storage formats for each use case

## Invoice-Based SPV Payments

LibSpiffy implements a streamlined SPV payment verification system using invoices:

### Creating and Paying Invoices

```dart
// 1. Receiver creates an invoice with payment addresses
final invoice = await createInvoice(
  walletId: 'bob-wallet',
  amount: BigInt.from(100000), // satoshis
  description: 'Payment for services',
  numberOfAddresses: 1, // Can request multiple addresses
);

// Invoice contains:
// - invoiceId: Unique identifier
// - addresses: Pre-generated payment addresses
// - amount: Expected payment amount
// - expiresAt: Invoice expiration time

// 2. Sender creates transaction paying to invoice address(es)
final tx = await createTransaction(
  fromWallet: 'alice-wallet',
  toAddresses: [invoice.addresses.first],
  amount: invoice.amount,
);

// 3. Sender broadcasts transaction with BEEF (includes merkle proof)
await broadcastTransaction(
  transaction: tx,
  beef: beef, // Contains tx + parent txs + merkle proof
  invoiceId: invoice.invoiceId, // Links tx to invoice
);

// 4. SPV Actor validates the transaction:
//    - Verifies merkle proof against block header chain
//    - Confirms outputs match invoice addresses
//    - Validates payment amount
//    - Calculates transaction fee from BEEF data
//    - Marks invoice as paid

// 5. Receiver's wallet is automatically updated with new UTXOs
```

### SPV Validation Flow

1. **Transaction Received**: SPV Actor receives transaction with BEEF and invoice ID
2. **Merkle Proof Validation**: Validates transaction is in a valid block
3. **Invoice Lookup**: Retrieves expected payment addresses from Invoice Manager
4. **Output Verification**: Confirms transaction pays to invoice addresses
5. **Amount Validation**: Verifies payment amount matches invoice
6. **UTXO Extraction**: Identifies new spendable UTXOs and spent UTXOs
7. **Fee Calculation**: Computes transaction fee from input/output values in BEEF
8. **State Update**: Wallet state updated via event sourcing
9. **Invoice Marking**: Invoice marked as paid

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
    if (command is GenerateAddressCommand) {
      return [AddressGeneratedEvent(
        walletId: persistenceId,
        address: generatedAddress,
        derivationIndex: currentState.nextDerivationIndex,
        // ...
      )];
    }
    // ... other command handlers
  }
  
  @override
  void eventHandler(Event event) {
    ensureStateInitialized(); // Critical!
    
    // Mutate currentState directly based on events
    if (event is AddressGeneratedEvent) {
      currentState.addresses[event.address] = event.derivationIndex;
      currentState.nextDerivationIndex++;
      currentState.version++;
    }
    // ... other event handlers
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
// Create wallet (spawns BitcoinWalletAggregate actor)
walletManager.tell(CreateWalletMessage(
  walletId: 'wallet-001',
  name: 'My Bitcoin Wallet',
));

// Send command to wallet aggregate
walletManager.tell(WalletCommandMessage(
  walletId: 'wallet-001',
  command: GenerateAddressCommand(
    walletId: 'wallet-001',
    metadata: {'purpose': 'receiving'},
  ),
));

// Query wallet (reads from ReadModel, not EventStore)
walletManager.tell(GetWalletBalanceMessage(
  walletId: 'wallet-001',
));
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
        invoiceId: persistenceId,
        walletId: command.walletId,
        addresses: command.addresses,
        amount: command.amount,
        createdAt: DateTime.now(),
        // ...
      )];
    }
    
    if (command is MarkInvoicePaidCommand) {
      // Business rule validation
      if (currentState.status != InvoiceStatus.pending) {
        throw StateError('Invoice is not pending');
      }
      
      return [InvoicePaidEvent(
        invoiceId: persistenceId,
        paidAt: DateTime.now(),
        txid: command.txid,
        amountReceived: command.amountReceived,
      )];
    }
    // ... other commands
  }
  
  @override
  void eventHandler(Event event) {
    ensureStateInitialized();
    
    if (event is InvoiceCreatedEvent) {
      currentState.status = InvoiceStatus.pending;
      currentState.amount = event.amount;
      currentState.addresses = event.addresses;
      // ...
    }
    
    if (event is InvoicePaidEvent) {
      currentState.status = InvoiceStatus.paid;
      currentState.paidAt = event.paidAt;
      currentState.paymentTxid = event.txid;
      // ...
    }
  }
}
```

**Key Features:**
- Invoice state machine (pending → paid/expired/cancelled)
- Business rule enforcement
- Complete audit trail of invoice lifecycle

### 4. Invoice Coordinator Actor (Coordinator)

Long-lived coordinator for invoice operations (replaces old InvoiceManagerActor):

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
  txid: 'transaction-hex',
  amountReceived: BigInt.from(100000),
  addressesPaidTo: ['address1'],
));

// Check invoice status (queries ReadModel)
invoiceCoordinator.tell(CheckInvoiceMessage(
  invoiceId: 'invoice-123',
));

// List invoices (queries ReadModel with optional filter)
invoiceCoordinator.tell(ListInvoicesMessage(
  walletId: 'wallet-001',
  status: InvoiceStatus.pending, // Optional
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
class WalletProjection extends Projection<WalletReadModel> {
  @override
  Future<bool> handle(Event event) async {
    if (event is UTXOReceivedEvent) {
      // Update denormalized UTXO view in Isar
      await storage.storeUTXO(BitcoinUtxo.fromEvent(event));
      return true;
    }
    // ... other wallet events
  }
}

// InvoiceProjection - Updates invoice read models  
class InvoiceProjection extends Projection<InvoiceReadModel> {
  @override
  Future<bool> handle(Event event) async {
    if (event is InvoiceCreatedEvent) {
      // Check for existing invoice (idempotent replay)
      final existing = await storage.getInvoice(event.invoiceId);
      if (existing == null) {
        await storage.storeInvoice(Invoice.fromEvent(event));
      }
      return true;
    }
    
    if (event is InvoicePaidEvent) {
      // Update existing invoice status
      await storage.updateInvoiceStatus(
        event.invoiceId,
        InvoiceStatus.paid,
        paidAt: event.paidAt,
        txid: event.txid,
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

### 6. Projection Manager (CQRS Orchestration)

Coordinates event streaming to all projections:

```dart
// Initialized automatically by LibSpiffyActorSystem
final projectionManager = ProjectionManager(eventStore);

// Register projections
await projectionManager.registerProjection(walletProjection);
await projectionManager.registerProjection(invoiceProjection);

// Start event streaming
await projectionManager.start();

// ProjectionManager:
// - Streams events from EventStore
// - Routes events to interested projections
// - Manages checkpoints for each projection
// - Handles projection failures gracefully
```

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
// 6. Mark invoice as paid
```

### 8. ARC Actor

Interfaces with ARC service for transaction broadcasting and fee estimation:

```dart
// Broadcast a transaction
arcActor.tell(BroadcastTransactionMessage(
  txid: 'transaction-id',
  rawTx: transactionHex,
));

// Estimate transaction fee
arcActor.tell(EstimateFeeMessage(
  estimatedSize: 250, // bytes
));

// Query transaction status
arcActor.tell(GetTransactionStatusMessage(
  txid: 'transaction-id',
));

// Get ARC policy (fee rates, limits)
arcActor.tell(GetPolicyMessage());
```

### 9. Block Header Sync Actor

Manages block headers and validates merkle proofs:

```dart
// Start header sync
headerSync.tell(StartHeaderSyncMessage(
  startHeight: 0,
  targetHeight: null, // null = sync to tip
));

// Validate merkle proof
headerSync.tell(ValidateMerkleProofMessage(
  requestId: 'validate-1',
  merkleProof: proof,
  txid: 'transaction-id',
));

## Event Sourcing Flow

### Commands → Events → State

```dart
// 1. Command represents user intention
final command = GenerateAddressCommand(
  commandId: 'gen-addr-1',
  walletId: 'wallet-001',
  purpose: AddressPurpose.receiving,
);

// 2. Command handler produces events
final events = [
  AddressGeneratedEvent(
    eventId: 'event-1',
    walletId: 'wallet-001',
    address: 'bc1q...',
    derivationPath: "m/44'/0'/0'/0/0",
    purpose: AddressPurpose.receiving,
    timestamp: DateTime.now(),
  ),
];

// 3. Events are applied to update state
final newState = currentState.applyEvent(events.first);
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
- **TransactionAddedEvent**: Transaction added to wallet
- **SpendingTransactionCreatedEvent**: Outgoing transaction created
- **TransactionBroadcastEvent**: Transaction sent to network

#### UTXO Reservation Events (BitcoinWalletAggregate)
- **UTXOReservationPlacedEvent**: UTXO reserved for future use
- **UTXOReservationReleasedEvent**: UTXO reservation removed
- **UTXOReservationExpiredEvent**: UTXO reservation timed out
- **UTXOReservedEvent**: UTXO marked as reserved
- **UTXOReleasedEvent**: UTXO released from reservation
- **UTXOReservationRenewedEvent**: UTXO reservation extended

#### Invoice Events (InvoiceAggregate)
- **InvoiceCreatedEvent**: Invoice created with payment addresses
- **InvoiceStatusChangedEvent**: Invoice status transition
- **InvoicePaidEvent**: Invoice marked as paid after SPV validation
- **InvoiceExpiredEvent**: Invoice expired before payment
- **InvoiceCancelledEvent**: Invoice cancelled by user

**Note**: These are now proper domain events persisted to EventStore, not actor messages. InvoiceProjection subscribes to these events and updates the invoice read models in Isar.

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

### Event Store Configuration

```dart
final eventStore = InMemoryEventStore(); // Development
// or
final eventStore = PostgreSQLEventStore(connectionString); // Production
```

### Snapshot Configuration

```dart
final snapshotConfig = SnapshotConfig(
  snapshotFrequency: 100, // Every 100 events
  retentionPolicy: RetentionPolicy.keepLast(10), // Keep 10 snapshots
  compressionEnabled: true,
);
```

### Network Configuration

```dart
// ARC Service (for transaction broadcasting)
final arcConfig = ArcServiceConfig(
  baseUrl: 'https://arc.taal.com', // or your preferred ARC endpoint
  apiKey: 'your-api-key', // Optional, depending on provider
  network: 'mainnet', // or 'testnet'
);

// Block Header Sync
final headerSyncConfig = {
  'startHeight': 0, // Start from genesis or latest known
  'batchSize': 2000, // Headers per batch request
  'maxRetries': 3,
  'retryDelay': Duration(seconds: 5),
};

// Invoice Configuration
final invoiceConfig = {
  'defaultExpiration': Duration(hours: 24),
  'cleanupInterval': Duration(hours: 1),
  'maxAddressesPerInvoice': 10,
};
```

## Monitoring and Observability

### Actor Metrics
- Message processing rates
- Error rates and types
- Actor lifecycle events
- Memory usage and performance

### Wallet Metrics
- Balance changes over time
- Transaction volume and fees
- UTXO set size and distribution
- Address generation patterns
- Event store size and growth

### Invoice Metrics
- Invoice creation rate
- Payment success rate
- Invoice expiration rate
- Average payment time
- Active vs. paid vs. expired invoices

### SPV Validation Metrics
- Merkle proof validation success rate
- BEEF/BUMP processing time
- Fee calculation accuracy
- Address verification success rate
- Block header sync progress

### Network Metrics
- ARC service response times
- Transaction broadcast success rate
- Block header sync status
- Network fee rates

## Testing

### Unit Tests
```bash
# Run all unit tests
dart test test/

# Test specific components
dart test test/actors/invoice_manager_actor_test.dart
dart test test/services/arc_service_test.dart
dart test test/crypto/dartsv_crypto_integration_test.dart
```

### Integration Tests
```bash
# Run all integration tests
dart test test/integration/

# Invoice-based SPV payment flow
dart test test/integration/invoice_spv_integration_test.dart

# Full SPV validation with real testnet data
dart test test/integration/full_spv_validation_test.dart

# Wallet operations
dart test test/integration/wallet_integration_test.dart
```

### BEEF/BUMP Tests
```bash
# Test merkle proof validation
dart test test/bump_test.dart
dart test test/beef_test.dart
```

### Example Scenarios
```bash
dart run example/bitcoin_wallet_example.dart
```

### Test Coverage

The test suite includes:
- **Unit Tests**: Individual component testing (aggregates, actors, services)
- **Integration Tests**: End-to-end flows including invoice creation and SPV validation
- **Real Testnet Data**: Full SPV validation using actual Bitcoin testnet transactions
- **Mock Services**: Comprehensive mocking for isolated testing
- **Edge Cases**: Error handling, invalid proofs, expired invoices

## Development

### Project Structure
```
lib/
├── src/
│   ├── actors/                      # CQRS Coordinators
│   │   ├── libspiffy_actor_system.dart  # System initialization
│   │   ├── wallet_manager_actor.dart    # Wallet coordinator
│   │   ├── invoice_coordinator_actor.dart # Invoice coordinator (CQRS)
│   │   ├── spv_actor.dart               # SPV validation with BEEF/BUMP
│   │   ├── arc_actor.dart               # ARC service integration
│   │   ├── header_sync_actor.dart       # Block header synchronization
│   │   ├── wallet_messages.dart         # Wallet actor messages
│   │   └── invoice_messages.dart        # Invoice actor messages
│   ├── core/                        # Domain Aggregates (Write Side)
│   │   ├── bitcoin_wallet_aggregate.dart # Event-sourced wallet
│   │   ├── invoice_aggregate.dart       # Event-sourced invoices
│   │   ├── wallet_commands.dart         # Wallet command definitions
│   │   ├── wallet_events.dart           # Wallet event definitions
│   │   ├── invoice_commands.dart        # Invoice command definitions
│   │   └── invoice_events.dart          # Invoice event definitions
│   ├── projections/                 # CQRS Read Side
│   │   ├── wallet_projection.dart       # Wallet read model updates
│   │   └── invoice_projection.dart      # Invoice read model updates
│   ├── models/                      # Domain Models
│   │   ├── wallet_state.dart            # Wallet aggregate state
│   │   ├── invoice_state.dart           # Invoice aggregate state
│   │   ├── wallet_read_model.dart       # Wallet query model
│   │   ├── invoice_read_model.dart      # Invoice query model
│   │   ├── bitcoin_transaction.dart     # Transaction model
│   │   └── bitcoin_utxo.dart            # UTXO model
│   ├── storage/                     # Persistence Layer
│   │   ├── read_model_storage.dart      # Read model interface
│   │   ├── isar_wallet_storage.dart     # Isar implementation
│   │   ├── in_memory_wallet_storage.dart # In-memory for tests
│   │   ├── libspiffy_schemas.dart       # Isar schemas (read models)
│   │   └── secure_storage.dart          # Secure key storage
│   ├── services/                    # Supporting Services
│   │   ├── arc_service.dart             # ARC API client
│   │   ├── spv_service.dart             # SPV validation logic
│   │   ├── crypto_service.dart          # Cryptographic operations
│   │   └── transaction_builder_service.dart
│   ├── integration/                 # External Integrations
│   │   └── spiffynode_bridge.dart       # SpiffyNode P2P bridge
│   └── utils/                       # Utility Functions
│       ├── beef.dart                    # BEEF format handling
│       ├── bump.dart                    # BUMP merkle proofs
│       └── crypto_utils.dart            # Crypto helpers
├── example/                         # Usage Examples
│   └── bitcoin_wallet_example.dart
└── test/                            # Test Suites
    ├── actors/                      # Actor unit tests
    ├── integration/                 # Integration tests (CQRS flow)
    │   ├── alice_bob_p2p_payment_test.dart # Full P2P payment flow
    │   ├── invoice_persistence_test.dart    # Invoice CQRS test
    │   ├── invoice_spv_integration_test.dart
    │   └── full_spv_validation_test.dart
    ├── services/                    # Service tests
    ├── mocks/                       # Test mocks
    │   ├── mock_arc_service.dart
    │   └── mock_peer_manager.dart
    ├── beef_test.dart               # BEEF validation tests
    └── bump_test.dart               # BUMP validation tests
```

**Key Architectural Layers:**
- **actors/**: Long-lived coordinators that route commands
- **core/**: Event-sourced aggregates (write-side domain logic)
- **projections/**: Read-side event handlers (update read models)
- **models/**: Separated into aggregate state (mutable) and read models (denormalized)
- **storage/**: Read model persistence (Isar), EventStore managed by Eventador

### Adding New Features

#### Adding Wallet Commands/Events (CQRS Pattern)

Follow these steps to add new functionality using proper CQRS patterns:

**Step 1: Define Command**
```dart
// Add to lib/src/core/wallet_commands.dart
class MyNewCommand extends Command {
  final String walletId;
  final String someParameter;
  
  MyNewCommand({
    required this.walletId,
    required this.someParameter,
  });
}
```

**Step 2: Define Event**
```dart
// Add to lib/src/core/wallet_events.dart
class MyNewEvent extends WalletEvent {
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
  Map<String, dynamic> getEventData() {
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
// Add to lib/src/actors/libspiffy_actor_system.dart → _registerEventTypes()
EventRegistry.register<MyNewEvent>(
  'MyNewEvent',
  (map) => MyNewEvent.fromMap(map),
);
```

**Step 4: Add Command Handler in BitcoinWalletAggregate**
```dart
// In lib/src/core/bitcoin_wallet_aggregate.dart → handleCommand()
@override
Future<List<Event>> handleCommand(WalletState currentState, Command command) async {
  return switch (command.runtimeType) {
    MyNewCommand => _handleMyNewCommand(currentState, command as MyNewCommand),
    // ... other commands
    _ => throw ArgumentError('Unknown command: ${command.runtimeType}'),
  };
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
    ),
  ];
}
```

**Step 5: Add Event Handler in BitcoinWalletAggregate**
```dart
// In lib/src/core/bitcoin_wallet_aggregate.dart → eventHandler()
@override
void eventHandler(Event event) {
  ensureStateInitialized(); // CRITICAL!
  
  if (event is! WalletEvent) {
    throw ArgumentError('Expected WalletEvent, got ${event.runtimeType}');
  }

  switch (event.runtimeType) {
    case MyNewEvent:
      _applyMyNewEvent(event as MyNewEvent);
      break;
    // ... other events
    default:
      throw ArgumentError('Unknown event: ${event.runtimeType}');
  }
}

// Mutate currentState directly (new Eventador pattern)
void _applyMyNewEvent(MyNewEvent event) {
  currentState.someField = event.someData;
  currentState.version++;
  currentState.lastModified = event.timestamp;
}
```

**Step 6: Update Projection (if needed)**
```dart
// In lib/src/projections/wallet_projection.dart → handle()
@override
Future<bool> handle(Event event) async {
  if (event is MyNewEvent) {
    // Update read model in Isar
    await _storage.updateSomeReadModel(
      event.walletId,
      event.someData,
    );
    return true;
  }
  // ... other events
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
     String? get correlationId => null;
     @override
     Map<String, dynamic> get metadata => {'data': data};
   }
   ```

2. **Handle Message in Actor**
   ```dart
   @override
   Future<void> onMessage(dynamic message) async {
     switch (message.runtimeType) {
       case MyNewMessage:
         await _handleMyNewMessage(message as MyNewMessage);
         break;
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
- Reserve UTXOs before transaction creation
- Set expiration times on reservations
- Release reservations after transaction broadcast
- Track UTXO lifecycle through events

❌ **DON'T**:
- Spend UTXOs without reservation
- Keep indefinite reservations
- Manually track UTXO state outside events
- Modify UTXO state without commands/events

## Contributing

1. Fork the repository
2. Create a feature branch
3. Add tests for new functionality
4. Ensure all tests pass
5. Submit a pull request

## License

This project is licensed under the MIT License - see the LICENSE file for details.

## Acknowledgments

- **Dactor**: Actor model framework for Dart
- **Eventador**: Event sourcing and CQRS library
- **DuraQ**: Operational workflow management
- **DartSV**: Bitcoin SV library for Dart
- **Bitcoin Community**: For the foundational protocols and specifications

## Further Reading

### Architecture Patterns
- [Event Sourcing Pattern](https://martinfowler.com/eaaDev/EventSourcing.html)
- [CQRS Pattern](https://docs.microsoft.com/en-us/azure/architecture/patterns/cqrs)
- [Actor Model](https://en.wikipedia.org/wiki/Actor_model)
- [Domain-Driven Design](https://martinfowler.com/bliki/DomainDrivenDesign.html)

### Bitcoin & BSV
- [SPV (Simplified Payment Verification)](https://bitcoin.org/bitcoin.pdf)
- [Bitcoin Protocol Documentation](https://developer.bitcoin.org/)
- [BEEF Specification](https://bsv.brc.dev/transactions/0062) - Background Evaluation Extended Format
- [BUMP Specification](https://bsv.brc.dev/transactions/0058) - BSV Universal Merkle Path
- [BRC-71 Standard](https://bsv.brc.dev/transactions/0071) - Merkle Path Format
- [TSC Proof Format](https://tsc.bitcoinassociation.net/) - Teranode Storage Chain

### Libraries & Frameworks
- [Dactor](https://github.com/GunterO/dactor) - Actor framework for Dart
- [Eventador](https://github.com/GunterO/eventador) - Event sourcing library
- [DartSV](https://github.com/twostack/dartsv) - Bitcoin SV library for Dart

---

**LibSpiffy** - Building the future of Bitcoin wallets with event sourcing and actor-based architecture. 
