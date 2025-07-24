# LibSpiffy - Event-Sourced Bitcoin Wallet

An actor-based Bitcoin wallet implementation using event sourcing, CQRS, and SPV (Simplified Payment Verification) built with the Dactor/Eventador/DuraQ stack.

## 🏗️ Architecture Overview

LibSpiffy implements a sophisticated Bitcoin wallet system using modern architectural patterns:

- **Event Sourcing**: All wallet state changes are captured as immutable events
- **CQRS**: Clear separation between commands (write operations) and queries (read operations)
- **Actor Model**: Concurrent, fault-tolerant processing using Dactor
- **SPV**: Lightweight Bitcoin verification using merkle proofs
- **Hybrid Stack**: Combines Dactor (actors), Eventador (event store), and DuraQ (workflows)

## 🎯 Key Features

### Core Wallet Functionality
- ✅ HD wallet address generation and management
- ✅ UTXO tracking with confirmation status
- ✅ Transaction creation and signing
- ✅ SPV transaction verification with merkle proofs
- ✅ Multi-wallet support with isolation
- ✅ Event-sourced state with full audit trail

### Advanced Features
- ✅ UTXO holds and reservations
- ✅ Funding requests for transaction preparation
- ✅ Automatic cleanup of expired holds
- ✅ Snapshot support for performance optimization
- ✅ Real-time balance calculations
- ✅ Transaction broadcasting via libp2p

### Network Integration
- ✅ Bitcoin P2P network connectivity
- ✅ Block header synchronization and validation
- ✅ Libp2p-based SPV transaction exchange
- ✅ Merkle proof validation against header chain
- ✅ Peer-to-peer transaction broadcasting

## 🏛️ System Architecture

```
┌────────────────────────────────────────────────────────────────┐
│                    LibSpiffy Bitcoin Wallet                    │
├────────────────────────────────────────────────────────────────┤
│                                                                │
│  ┌─────────────────┐    ┌──────────────────┐                   │
│  │ Wallet Manager  │    │ Block Header     │                   │
│  │ Actor           │    │ Manager Actor    │                   │
│  │                 │    │                  │                   │
│  │ • Multi-wallet  │    │ • Header chain   │                   │
│  │ • Command route │    │ • Merkle proof   │                   │
│  │ • Lifecycle mgmt│    │ • SPV validation │                   │
│  └─────────────────┘    └──────────────────┘                   │
│           │                       │                            │
│           │              ┌────────┴────────┐                   │
│           │              │                 │                   │
│  ┌────────▼────────┐    ┌▼─────────────┐  ┌▼──────────────┐    │
│  │ Bitcoin Wallet  │    │ Bitcoin P2P  │  │ Libp2p        │    │
│  │ Aggregate       │    │ Actor        │  │ Actor         │    │
│  │                 │    │              │  │               │    │
│  │ • Event sourcing│    │ • Peer conn. │  │ • SPV tx      │    │
│  │ • UTXO tracking │    │ • Block sync │  │ • Broadcasting│    │
│  │ • Tx creation   │    │ • Header req │  │ • DHT routing │    │
│  └─────────────────┘    └──────────────┘  └───────────────┘    │
│           │                                                    │
│           │                                                    │
│  ┌────────▼────────┐                                           │
│  │ Event Store     │                                           │
│  │ (Eventador)     │                                           │
│  │                 │                                           │
│  │ • Immutable log │                                           │
│  │ • Event replay  │                                           │
│  │ • Snapshots     │                                           │
│  └─────────────────┘                                           │
│                                                                │
└────────────────────────────────────────────────────────────────┘
```

## 🚀 Quick Start

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

### Basic Usage

```dart
import 'package:libspiffy/libspiffy.dart';

// Initialize the wallet system
final example = BitcoinWalletSystemExample();
await example.initialize();

// Create a wallet
await example.demonstrateWalletOperations();

// Cleanup
await example.shutdown();
```

## 📋 Core Components

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

### 3. Bitcoin P2P Actor

Handles Bitcoin network connectivity and block header synchronization:

```dart
// Start P2P connection
bitcoinP2P.tell(StartP2PMessage(
  seedNodes: ['testnet-seed.bitcoin.jonasschnelli.ch'],
));

// Subscribe to block headers
bitcoinP2P.tell(SubscribeToBlockHeadersMessage(
  subscriber: myActor,
  subscriptionId: 'my-subscription',
));
```

### 4. Block Header Manager Actor

Manages block headers and validates merkle proofs:

```dart
// Start header manager
headerManager.tell(StartHeaderManagerMessage(
  bitcoinP2PActor: bitcoinP2P,
  startHeight: 0,
));

// Validate merkle proof
headerManager.tell(ValidateMerkleProofMessage(
  requestId: 'validate-1',
  merkleProof: proof,
  txid: 'transaction-id',
));
```

### 5. Libp2p Actor

Handles SPV transaction communication via libp2p:

```dart
// Start libp2p node
libp2p.tell(StartLibp2pMessage(
  listenAddresses: ['/ip4/0.0.0.0/tcp/4001'],
  bootstrapPeers: [...],
));

// Broadcast transaction
libp2p.tell(BroadcastTransactionMessage(
  txid: 'tx-id',
  transaction: transaction,
));
```

## 🔄 Event Sourcing Flow

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

- **AddressGeneratedEvent**: New address created
- **UTXOReceivedEvent**: Incoming UTXO detected
- **UTXOSpentEvent**: UTXO consumed in transaction
- **TransactionAddedEvent**: Transaction added to wallet
- **SpendingTransactionCreatedEvent**: Outgoing transaction created
- **UTXOHoldPlacedEvent**: UTXO reserved for future use
- **UTXOHoldReleasedEvent**: UTXO hold removed
- **FundingRequestCreatedEvent**: Funding request established
- **TransactionConfirmationsUpdatedEvent**: Confirmation count updated
- **TransactionBroadcastEvent**: Transaction sent to network

## 🔐 Security Features

### SPV Verification
- Merkle proof validation against block headers
- Header chain validation with proof-of-work checks
- Transaction authenticity verification without full blockchain

### UTXO Management
- Atomic UTXO selection and reservation
- Prevents double-spending through holds
- Automatic cleanup of expired reservations

### Event Integrity
- Immutable event log with cryptographic hashing
- Complete audit trail of all wallet operations
- Snapshot validation and consistency checks

## 🛠️ Configuration

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
// Bitcoin P2P
final p2pConfig = {
  'seedNodes': [
    'testnet-seed.bitcoin.jonasschnelli.ch',
    'seed.tbtc.petertodd.org',
  ],
  'maxPeers': 8,
  'connectionTimeout': 30000,
};

// Libp2p
final libp2pConfig = {
  'protocols': ['/spv-tx/1.0.0', '/bitcoin-spv/1.0.0'],
  'maxPeers': 50,
  'heartbeatInterval': 30000,
};
```

## 📊 Monitoring and Observability

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

### Network Metrics
- P2P connection status
- Block header sync progress
- SPV transaction success rates
- Peer connectivity and health

## 🧪 Testing

### Unit Tests
```bash
dart test test/unit/
```

### Integration Tests
```bash
dart test test/integration/
```

### Example Scenarios
```bash
dart run example/bitcoin_wallet_example.dart
```

## 🔧 Development

### Project Structure
```
lib/
├── src/
│   ├── actors/           # Actor implementations
│   ├── models/           # Domain models and DTOs
│   ├── wallet/           # Core wallet logic
│   ├── services/         # Supporting services
│   └── utils/            # Utility functions
├── example/              # Usage examples
└── test/                 # Test suites
```

### Adding New Features

1. **Define Commands and Events**
   ```dart
   // Add to wallet_commands.dart
   class MyNewCommand extends WalletCommand { ... }
   
   // Add to wallet_events.dart
   class MyNewEvent extends WalletEvent { ... }
   ```

2. **Implement Command Handler**
   ```dart
   // In BitcoinWalletAggregate
   List<Event> _handleMyNewCommand(WalletState state, MyNewCommand cmd) {
     // Business logic here
     return [MyNewEvent(...)];
   }
   ```

3. **Implement Event Application**
   ```dart
   // In BitcoinWalletAggregate
   WalletState _applyMyNewEvent(WalletState state, MyNewEvent event) {
     // State update logic here
     return state.copyWith(...);
   }
   ```

## 🤝 Contributing

1. Fork the repository
2. Create a feature branch
3. Add tests for new functionality
4. Ensure all tests pass
5. Submit a pull request

## 📄 License

This project is licensed under the MIT License - see the LICENSE file for details.

## 🙏 Acknowledgments

- **Dactor**: Actor model framework for Dart
- **Eventador**: Event sourcing and CQRS library
- **DuraQ**: Operational workflow management
- **DartSV**: Bitcoin SV library for Dart
- **Bitcoin Community**: For the foundational protocols and specifications

## 📚 Further Reading

- [Event Sourcing Pattern](https://martinfowler.com/eaaDev/EventSourcing.html)
- [CQRS Pattern](https://docs.microsoft.com/en-us/azure/architecture/patterns/cqrs)
- [Actor Model](https://en.wikipedia.org/wiki/Actor_model)
- [SPV (Simplified Payment Verification)](https://bitcoin.org/bitcoin.pdf)
- [Bitcoin Protocol Documentation](https://developer.bitcoin.org/)

---

**LibSpiffy** - Building the future of Bitcoin wallets with event sourcing and actor-based architecture. 🚀
