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

```
┌──────────────────────────────────────────────────────────────────────┐
│                      LibSpiffy Bitcoin Wallet                        │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  ┌─────────────────┐    ┌──────────────────┐  ┌─────────────────┐    │
│  │ Wallet Manager  │───▶│ Invoice Manager  │  │ Block Header    │    │
│  │ Actor           │    │ Actor            │  │ Sync Actor      │    │
│  │                 │    │                  │  │                 │    │
│  │ • Multi-wallet  │    │ • Invoice track  │  │ • Header chain  │    │
│  │ • Command route │    │ • Address alloc  │  │ • Merkle proof  │    │
│  │ • Lifecycle mgmt│    │ • Payment match  │  │ • Chain valid.  │    │
│  └────────┬────────┘    └──────────────────┘  └─────────────────┘    │
│           │                       ▲                    │             │
│           │                       │                    │             │
│  ┌────────▼────────┐    ┌─────────┴──────┐  ┌──────────▼────────┐    │
│  │ Bitcoin Wallet  │    │ SPV Actor      │  │ ARC Actor         │    │
│  │ Aggregate       │    │                │  │                   │    │
│  │                 │    │ • BEEF valid.  │  │ • Tx broadcast    │    │
│  │ • Event sourcing│    │ • BUMP proofs  │  │ • Fee estimation  │    │
│  │ • UTXO tracking │    │ • Invoice match│  │ • Policy query    │    │
│  │ • Tx creation   │    │ • Fee calc     │  │ • Status track    │    │
│  └─────────────────┘    └────────────────┘  └───────────────────┘    │
│           │                                                          │
│           │                                                          │
│  ┌────────▼────────┐                                                 │
│  │ Event Store     │                                                 │
│  │ (Eventador)     │                                                 │
│  │                 │                                                 │
│  │ • Immutable log │                                                 │
│  │ • Event replay  │                                                 │
│  │ • Snapshots     │                                                 │
│  └─────────────────┘                                                 │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
```

## Quick Start

### Prerequisites

- Dart SDK 3.5.1 or later
- Dependencies: dactor, eventador, duraq, dartsv

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

### Basic Usage (Standalone)

```dart
import 'package:libspiffy/libspiffy.dart';

// Initialize LibSpiffy with its own actor system
await initializeLibSpiffy(
  dataDirectory: './wallet-data',
  arcConfig: ArcServiceConfig(
    baseUrl: 'https://arc.taal.com',
    network: 'mainnet',
  ),
);

// Get actor references
final walletManager = getLibSpiffySystem().walletManager;
final spvActor = getLibSpiffySystem().spvActor;

// Create a wallet
walletManager.tell(CreateWalletMessage(
  walletId: 'my-wallet',
  label: 'My Bitcoin Wallet',
));

// Cleanup
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
    invoiceManager: getLibSpiffySystem().invoiceManager,
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

### Pattern 3: Gateway Actor

Create a single gateway actor for controlled interaction:

```dart
class WalletGatewayActor extends Actor {
  final ActorRef _walletManager;
  final ActorRef _invoiceManager;
  final ActorRef _spvActor;
  
  WalletGatewayActor() 
      : _walletManager = getLibSpiffySystem().walletManager,
        _invoiceManager = getLibSpiffySystem().invoiceManager,
        _spvActor = getLibSpiffySystem().spvActor;
  
  @override
  Future<void> onMessage(dynamic message) async {
    if (message is WalletRequest) {
      // Route to appropriate LibSpiffy actor
      _walletManager.tell(
        CreateWalletMessage(walletId: message.walletId),
        sender: context.sender,
      );
    } else if (message is InvoiceRequest) {
      _invoiceManager.tell(
        CreateInvoiceMessage(
          walletId: message.walletId,
          amount: message.amount,
        ),
        sender: context.sender,
      );
    }
  }
}

// Usage
final gateway = await hostActorSystem.spawn(
  'wallet-gateway',
  () => WalletGatewayActor(),
);

// All wallet interactions go through gateway
gateway.tell(WalletRequest(...));
```

**Best for:** Applications requiring controlled access to wallet functionality or additional business logic layers.

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

### 1. Bitcoin Wallet Aggregate

The heart of the system - implements event sourcing for wallet operations:

```dart
// Create wallet aggregate
final wallet = BitcoinWalletAggregate(
  walletId: 'my-wallet',
  eventStore: eventStore,
  snapshotConfig: SnapshotConfig.production(),
);

// Process commands
final events = await wallet.processCommand(
  GenerateAddressCommand(
    commandId: 'gen-addr-1',
    walletId: 'my-wallet',
    purpose: AddressPurpose.receiving,
  ),
);
```

### 2. Wallet Manager Actor

Supervises multiple wallet aggregates and routes commands:

```dart
// Create wallet
walletManager.tell(CreateWalletMessage(
  walletId: 'wallet-001',
  label: 'My Bitcoin Wallet',
));

// Execute command
walletManager.tell(ExecuteWalletCommandMessage(
  walletId: 'wallet-001',
  command: GenerateAddressCommand(...),
));
```

### 3. Invoice Manager Actor

Manages invoice lifecycle and payment address allocation:

```dart
// Create an invoice
invoiceManager.tell(CreateInvoiceMessage(
  walletId: 'wallet-001',
  amount: BigInt.from(100000),
  description: 'Payment for services',
  numberOfAddresses: 1,
));

// Check invoice status
invoiceManager.tell(CheckInvoiceMessage(
  invoiceId: 'invoice-123',
));

// List invoices for a wallet
invoiceManager.tell(ListInvoicesMessage(
  walletId: 'wallet-001',
  status: InvoiceStatus.pending, // Optional filter
));

// Cancel an invoice
invoiceManager.tell(CancelInvoiceMessage(
  invoiceId: 'invoice-123',
));
```

### 4. SPV Actor

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

### 5. ARC Actor

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

### 6. Block Header Sync Actor

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

#### Wallet Events
- **WalletCreatedEvent**: New wallet initialized
- **AddressGeneratedEvent**: New address created
- **AddressLabelUpdatedEvent**: Address label changed
- **UTXOReceivedEvent**: Incoming UTXO detected
- **UTXOSpentEvent**: UTXO consumed in transaction
- **UTXOConfirmationUpdatedEvent**: UTXO confirmation count changed
- **TransactionAddedEvent**: Transaction added to wallet
- **SpendingTransactionCreatedEvent**: Outgoing transaction created
- **TransactionBroadcastEvent**: Transaction sent to network

#### UTXO Reservation Events
- **UTXOReservationPlacedEvent**: UTXO reserved for future use
- **UTXOReservationReleasedEvent**: UTXO reservation removed
- **UTXOReservationExpiredEvent**: UTXO reservation timed out
- **UTXOReservedEvent**: UTXO marked as reserved
- **UTXOReleasedEvent**: UTXO released from reservation
- **UTXOReservationRenewedEvent**: UTXO reservation extended

#### Invoice Events (Actor-level, not persisted in wallet aggregate)
- **InvoiceCreatedMessage**: Invoice created with payment addresses
- **InvoiceDetailsResponse**: Invoice status and details
- **MarkInvoicePaidMessage**: Invoice marked as paid after SPV validation
- **InvoiceExpiredMessage**: Invoice expired before payment
- **InvoiceCancelledMessage**: Invoice cancelled by user

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
│   ├── actors/                      # Actor implementations
│   │   ├── wallet_manager_actor.dart    # Multi-wallet coordination
│   │   ├── invoice_manager_actor.dart   # Invoice lifecycle management
│   │   ├── spv_actor.dart               # SPV validation with BEEF/BUMP
│   │   ├── arc_actor.dart               # ARC service integration
│   │   ├── header_sync_actor.dart       # Block header synchronization
│   │   └── wallet_messages.dart         # Actor message types
│   ├── core/                        # Domain logic
│   │   ├── bitcoin_wallet_aggregate.dart # Event-sourced wallet
│   │   ├── wallet_commands.dart         # Command definitions
│   │   └── wallet_events.dart           # Event definitions
│   ├── models/                      # Domain models
│   │   ├── bitcoin_transaction.dart
│   │   ├── bitcoin_utxo.dart
│   │   └── wallet_state.dart
│   ├── services/                    # Supporting services
│   │   ├── arc_service.dart             # ARC API client
│   │   ├── spv_service.dart             # SPV validation logic
│   │   ├── crypto_service.dart          # Cryptographic operations
│   │   └── transaction_builder_service.dart
│   ├── storage/                     # Persistence layer
│   │   ├── wallet_storage.dart          # Wallet state storage
│   │   └── secure_storage.dart          # Secure key storage
│   └── utils/                       # Utility functions
│       ├── beef.dart                    # BEEF format handling
│       ├── bump.dart                    # BUMP merkle proofs
│       └── crypto_utils.dart            # Crypto helpers
├── example/                         # Usage examples
└── test/                            # Test suites
    ├── actors/                      # Actor unit tests
    ├── integration/                 # Integration tests
    │   ├── invoice_spv_integration_test.dart
    │   └── full_spv_validation_test.dart
    ├── services/                    # Service tests
    ├── beef_test.dart               # BEEF validation tests
    └── bump_test.dart               # BUMP validation tests
```

### Adding New Features

#### Adding Wallet Commands/Events

1. **Define Commands and Events**
   ```dart
   // Add to wallet_commands.dart
   class MyNewCommand extends WalletCommand {
     final String walletId;
     final String someParameter;
     
     MyNewCommand({required this.walletId, required this.someParameter});
   }
   
   // Add to wallet_events.dart
   class MyNewEvent extends WalletEvent {
     final String someData;
     
     MyNewEvent({
       required String eventId,
       required String walletId,
       required this.someData,
       required DateTime timestamp,
     }) : super(eventId: eventId, walletId: walletId, timestamp: timestamp);
   }
   ```

2. **Implement Command Handler in BitcoinWalletAggregate**
   ```dart
   List<Event> _handleMyNewCommand(WalletState state, MyNewCommand cmd) {
     // Validation
     if (state.someCondition) {
       throw Exception('Invalid state for command');
     }
     
     // Business logic
     final result = performSomeOperation(cmd.someParameter);
     
     // Return events
     return [
       MyNewEvent(
         eventId: generateEventId(),
         walletId: cmd.walletId,
         someData: result,
         timestamp: DateTime.now(),
       ),
     ];
   }
   ```

3. **Implement Event Application**
   ```dart
   WalletState _applyMyNewEvent(WalletState state, MyNewEvent event) {
     // Update state based on event
     return state.copyWith(
       someField: event.someData,
       version: event.version,
       lastModified: event.timestamp,
     );
   }
   ```

4. **Register Handler in registerHandlers() (if using registration pattern)**
   ```dart
   @override
   void registerHandlers() {
     registerCommandHandler<MyNewCommand>(_handleMyNewCommand);
   }
   ```

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
