# LibSpiffy Wallet Architecture

## Overview

LibSpiffy implements a **script-centric, event-sourced Bitcoin SPV wallet** that can handle arbitrary Bitcoin scripts and protocols while maintaining clean separation between core wallet mechanics and domain-specific functionality.

## Core Architectural Principles

### 1. Script-Centric Design
- The wallet can handle **any Bitcoin script type**, not just P2PKH
- Uses DartSV's `ScriptTemplateRegistry` for script identification and builder factories
- UTXOs are analyzed and categorized based on their script types
- Script metadata is cached to avoid re-parsing for UI display

### 2. Event Sourcing
- Built on **Eventador** framework for complete audit trail
- All wallet state changes are captured as immutable events
- Aggregate root pattern ensures consistency
- Projections provide domain-specific read models

### 3. Protocol Agnostic Core
- Core wallet handles Bitcoin mechanics only
- Domain-specific protocols (AIP, BMAP, tokens) handled via projections
- Clean separation allows protocol experts to build specialized views
- Cross-protocol relationships tracked in projections

### 4. SPV + ARC (Authoritative Response Component) Integration
- **SpiffyNode** provides SPV block header tracking and P2P connectivity
- **ARC Service** handles transaction broadcasting and merkle proof retrieval
- **BEEF/BUMP** integration for transaction packaging with proofs

### 5. Unified Coordinator Interface
- **WalletCoordinatorActor** is THE canonical public interface for third-party apps
- Apps send commands (`CreateWalletCommand`, `PayInvoiceCommand`, etc.) and subscribe to events (`WalletCreatedEvent`, `PaymentReadyEvent`, etc.)
- Coordinator handles all internal actor orchestration, correlation tracking, and async response routing
- Separate import: `package:libspiffy/coordinator.dart` — clean names, no collisions with internal domain types
- Transport-agnostic — works via direct calls, isolate message passing, or FFI

## WalletCoordinatorActor

The coordinator is the facade that sits between external clients and LibSpiffy's internal actor system. It eliminates the need for third-party apps to understand or orchestrate the 12 internal actors.

### Import Pattern

```dart
// Public API — clean command/event names
import 'package:libspiffy/coordinator.dart';

// Internal domain types — for advanced use
import 'package:libspiffy/libspiffy.dart';
```

The two imports use different naming conventions to avoid collisions:
- Coordinator: `CreateWalletCommand` / `WalletCreatedEvent` (Command/Event suffix)
- Internal: `CreateWalletMessage` / `WalletCreatedMessage` (Message suffix)

### Command/Event Flow

```
App sends:    CreateWalletCommand ──→ WalletCoordinatorActor
                                          │
Coordinator:  translates to ──→ CreateWalletMessage ──→ WalletManagerActor
                                                               │
Internal:     WalletManagerActor spawns aggregate, emits ──→ WalletCreatedMessage
                                                               │
Coordinator:  translates to ──→ WalletCreatedEvent ──→ Stream<CoordinatorEvent>
                                                               │
App receives: event on stream ◄────────────────────────────────┘
```

### Correlation Tracking

The coordinator internalizes multi-step correlation that apps would otherwise need to manage:

- **BEEF validation flow**: `ValidateBEEFCommand` → structural validation → SPV validation → broadcast → `BEEFValidationResultEvent`
- **Payment flow**: `PayInvoiceCommand` → UTXO selection → ancestor chain → TX build → sign → BEEF → `PaymentReadyEvent`
- **Timestamp archive flow**: `TimestampCommand` → OP_RETURN outputs → payment → broadcast → `TimestampCompleteEvent`

### Channel P2P Adapter

The `ChannelP2PAdapter` is composed inside the coordinator (not a separate actor). It translates between raw P2P messages and LibSpiffy's `PaymentChannelManagerActor`:

- **Incoming**: `ChannelP2PReceived(messageType, payload)` → appropriate channel manager message
- **Outgoing**: Channel events → `ChannelP2PMessageToSendEvent(toPeerId, messageType, payload)` — app transmits via its P2P layer

## System Architecture

LibSpiffy uses a **CQRS-based layered architecture** combining **Dactor actors** (coordination layer) with **Eventador aggregates** (business logic layer) and **Projections** (read-side updates):

```
┌─────────────────────────────────────────────────────────────────┐
│                     EXTERNAL CLIENTS                            │
│              (Mobile App, CLI, Web Interface)                   │
└─────────────────────────┬───────────────────────────────────────┘
                          │  import 'package:libspiffy/coordinator.dart'
                          │  Commands (CreateWalletCommand, PayInvoiceCommand, ...)
                          ▼
┌─────────────────────────────────────────────────────────────────┐
│         WALLET COORDINATOR (Unified Public Interface)           │
│                                                                 │
│  ┌─────────────────────────────────────────────────────────────┐│
│  │ WalletCoordinatorActor                                      ││
│  │                                                             ││
│  │ • THE single entry point for third-party apps               ││
│  │ • Routes commands to internal actors                        ││
│  │ • Tracks correlations (BEEF↔invoice, SPV↔tx, etc.)          ││
│  │ • Emits events on Stream<CoordinatorEvent>                  ││
│  │ • Composes ChannelP2PAdapter for payment channels           ││
│  │ • Direct CQRS reads for balance/transaction queries         ││
│  └─────────────────────────────────────────────────────────────┘│
└─────────────────────────┬───────────────────────────────────────┘
                          │  Internal Messages
                          ▼
┌──────────────────────────────────────────────────────────────────┐
│           DACTOR COORDINATION LAYER (Internal Actors)            │
│                                                                  │
│  ┌─────────────────────┐  ┌──────────────────────────────────┐   │
│  │ WalletManagerActor  │  │  InvoiceCoordinatorActor         │   │
│  │                     │  │                                  │   │
│  │ • Multi-wallet mgmt │  │ • Invoice lifecycle routing      │   │
│  │ • Command routing   │  │ • Address coordination           │   │
│  │ • Wallet lifecycle  │  │ • Query read models              │   │
│  │ • UTXO cleanup      │  │ • Expiration checks              │   │
│  └─────────────────────┘  └──────────────────────────────────┘   │
│                                                                  │
│  ┌─────────────────────┐  ┌─────────────────────────────────────┐│
│  │      SPVActor       │  │          HeaderSyncActor            ││
│  │                     │  │                                     ││
│  │ • BEEF/BUMP valid.  │  │ • Block header management           ││
│  │ • Tx validation     │  │ • Chain tip events                  ││
│  │ • Merkle proofs     │  │ • Header storage                    ││
│  │ • Invoice matching  │  │ • SPV coordination                  ││
│  └─────────────────────┘  └─────────────────────────────────────┘│
│                                                                  │
│  ┌─────────────────────┐  ┌─────────────────────────────────────┐│
│  │      ARCActor       │  │         SpiffyNodeBridge            ││
│  │                     │  │                                     ││
│  │ • Tx broadcasting   │  │ • SpiffyNode event translation      ││
│  │ • Fee estimation    │  │ • P2P message routing               ││
│  │ • Merkle retrieval  │  │ • Chain tip monitoring              ││
│  │ • Policy query      │  │ • Header forwarding                 ││
│  └─────────────────────┘  └─────────────────────────────────────┘│
│                                                                  │
│  ┌──────────────────────────┐  ┌────────────────────────────────┐│
│  │ PaymentCoordinatorActor  │  │ PaymentChannelManagerActor     ││
│  │                          │  │                                ││
│  │ • UTXO selection         │  │ • Payment channel lifecycle    ││
│  │ • Ancestor proof coll.   │  │ • Channel state management    ││
│  │ • BEEF construction      │  │ • P2P channel messages        ││
│  │ • Does NOT broadcast     │  │ • Balance negotiation         ││
│  └──────────────────────────┘  └────────────────────────────────┘│
│                                                                  │
│  ┌──────────────────────────┐  ┌────────────────────────────────┐│
│  │ BenfordCoordinatorActor  │  │ TxLifecycleCoordinatorActor   ││
│  │                          │  │                                ││
│  │ • Benford's Law UTXO     │  │ • Pending tx tracking         ││
│  │   splitting              │  │ • Restart recovery            ││
│  │ • Privacy-compliant      │  │ • ARC registration            ││
│  │   change outputs         │  │ • Status monitoring           ││
│  └──────────────────────────┘  └────────────────────────────────┘│
│                                                                  │
│  ┌──────────────────────────┐                                    │
│  │      ImportActor         │                                    │
│  │                          │                                    │
│  │ • Wallet import          │                                    │
│  │ • Address discovery      │                                    │
│  │ • Tx harvesting          │                                    │
│  └──────────────────────────┘                                    │
└─────────────────────────┬────────────────────────────────────────┘
                          │ Commands
                          ▼
┌─────────────────────────────────────────────────────────────────┐
│         EVENTADOR BUSINESS LAYER (Write Side - CQRS)            │
│                                                                 │
│  ┌───────────────────────────┐  ┌────────────────────────────┐  │
│  │  BITCOIN WALLET AGGREGATE │  │    INVOICE AGGREGATE       │  │
│  │   (Event-Sourced Root)    │  │  (Event-Sourced Root)      │  │
│  │                           │  │                            │  │
│  │ • Script-aware UTXO       │  │ • Invoice state machine    │  │
│  │ • Registry-driven tx      │  │ • Payment validation       │  │
│  │ • Protocol registration   │  │ • Status transitions       │  │
│  │ • UTXO categorization     │  │ • Expiration handling      │  │
│  │ • Business rules          │  │ • Business rules           │  │
│  │ • State consistency       │  │ • Audit trail              │  │
│  └───────────────────────────┘  └────────────────────────────┘  │
└─────────────────────────┬───────────────────────────────────────┘
                          │ Events (Immutable)
                          ▼
┌─────────────────────────────────────────────────────────────────┐
│                EVENT STORE (Write-Only by Aggregates)           │
│                   (Eventador + Isar CBOR)                       │
│                                                                 │
│  Wallet Events: WalletCreatedEvent, UTXOReceivedEvent,          │
│                 UTXOSpentEvent, TransactionCreatedEvent         │
│  Invoice Events: InvoiceCreatedEvent, InvoicePaidEvent,         │
│                  InvoiceExpiredEvent, InvoiceCancelledEvent     │
│  Block Events: BlockHeaderStoredEvent, ChainTipEventMessage     │
└─────────────────────────┬───────────────────────────────────────┘
                          │ Event Stream
                          ▼
┌─────────────────────────────────────────────────────────────────┐
│              PROJECTION MANAGER (CQRS Orchestration)            │
│                                                                 │
│  • Streams events from EventStore                               │
│  • Routes events to interested projections                      │
│  • Manages checkpoints for each projection                      │
│  • Ensures eventual consistency                                 │
└─────────────────────────┬───────────────────────────────────────┘
                          │ Events by Type
                          ▼
┌─────────────────────────────────────────────────────────────────┐
│       CQRS PROJECTIONS (Read Side - Write to ReadModels)        │
│                                                                 │
│  ┌───────────────────┐  ┌────────────────────────────────────┐  │
│  │ WalletProjection  │  │      InvoiceProjection             │  │
│  │                   │  │                                    │  │
│  │ • UTXO views      │  │ • Invoice status tracking          │  │
│  │ • Balance updates │  │ • Address associations             │  │
│  │ • Tx history      │  │ • Payment matching                 │  │
│  │ • Confirmations   │  │ • Expiration monitoring            │  │
│  └───────────────────┘  └────────────────────────────────────┘  │
│                                                                 │
│  ┌────────────────────────────────────────────────────────────┐ │
│  │           Domain Projections (Optional)                    │ │
│  │                                                            │ │
│  │ • TokenProjection (NFT tracking)                           │ │
│  │ • IdentityProjection (AIP signatures)                      │ │
│  │ • SocialMediaProjection (BMAP content)                     │ │
│  │ • Custom protocol views                                    │ │
│  └────────────────────────────────────────────────────────────┘ │
└─────────────────────────┬───────────────────────────────────────┘
                          │ Writes
                          ▼
┌─────────────────────────────────────────────────────────────────┐
│      READ MODEL STORAGE (Isar - Query Optimized, Read-Only)     │
│                                                                 │
│  ┌─────────────────────┐    ┌─────────────────────────────────┐ │
│  │ ReadModelStorage    │    │      BlockHeaderChain           │ │
│  │ (Denormalized)      │    │                                 │ │
│  │                     │    │ • Header validation/storage     │ │
│  │ • UTXOs (fast query)│    │ • Chain reorganization          │ │
│  │ • Transactions      │    │ • Merkle proof verification     │ │
│  │ • Invoices          │    │ • SPV transaction validation    │ │
│  │ • Balances          │    │                                 │ │
│  │ • No joins needed   │    │                                 │ │
│  └─────────────────────┘    └─────────────────────────────────┘ │
└─────────────────────────┬───────────────────────────────────────┘
                          │ Reads (Queries)
                          ▼
┌─────────────────────────────────────────────────────────────────┐
│                   SERVICES LAYER                                │
│                                                                 │
│  ┌──────────────────┐  ┌──────────────────┐  ┌────────────────┐ │
│  │   CryptoService  │  │    ARC Service   │  │  SpiffyNode    │ │
│  │                  │  │                  │  │   P2P/SPV      │ │
│  │ • HD Wallets     │  │ • Tx Broadcast   │  │                │ │
│  │ • Address Gen    │  │ • Merkle Proofs  │  │ • Block Headers│ │
│  │ • Tx Building    │  │ • BEEF/BUMP      │  │ • Chain Tips   │ │
│  │ • Tx Signing     │  │ • Fee Estimation │  │ • Peer Mgmt    │ │
│  └──────────────────┘  └──────────────────┘  └────────────────┘ │
└─────────────────────────────────────────────────────────────────┘
```

### Key CQRS Flow

**Write Side (Commands → Events → EventStore):**
1. Coordinator Actor receives command
2. Spawns/routes to appropriate Aggregate
3. Aggregate validates and emits events
4. Events persisted to EventStore (CBOR)

**Read Side (EventStore → Projections → ReadModels):**
1. ProjectionManager streams events from EventStore
2. Routes events to interested Projections
3. Projections update denormalized ReadModels
4. Applications query ReadModels (never EventStore)

**Benefits:**
- **Separation**: Clear boundary between write and read operations
- **Performance**: Optimized read models for fast queries
- **Scalability**: Read/write can scale independently
- **Audit Trail**: Complete event history in EventStore
- **Eventual Consistency**: Projections update asynchronously

## Layered Architecture Explained

### Dactor Coordination Layer (CQRS Coordinators)
The **Dactor actors** are long-lived coordinators that route commands to aggregates and query read models. They **never directly modify state** - that's the job of aggregates and projections.

**Key Responsibilities:**
- **Command Routing**: Route commands to appropriate aggregate actors
- **Aggregate Spawning**: Spawn aggregate actors on-demand (one per entity)
- **External Integration**: Manage SpiffyNode, ARC Service, and other external systems
- **Query Handling**: Query read models (not EventStore) for application needs
- **Coordination**: Coordinate between aggregates (e.g., Invoice requesting wallet address)

**Key Benefits:**
- **Concurrency**: Handle multiple operations simultaneously
- **Scalability**: Can distribute across multiple nodes
- **Fault Tolerance**: Supervision trees handle failures
- **Clean Separation**: No business logic in coordinators

### Eventador Business Layer (CQRS Write Side)
The **Aggregates** (BitcoinWalletAggregate, InvoiceAggregate) contain all business logic and maintain consistency through event sourcing. Each entity (wallet, invoice) is a separate aggregate actor instance.

**Key Responsibilities:**
- **Command Validation**: Enforce business rules before emitting events
- **Event Emission**: Produce immutable events representing state changes
- **State Management**: Maintain mutable state from event replay
- **Consistency**: Ensure state transitions are valid and atomic

**Key Benefits:**
- **Consistency**: Event sourcing ensures reliable state management
- **Business Rules**: All domain logic centralized and testable
- **Audit Trail**: Complete history of all operations
- **Recovery**: State can be rebuilt from events after restart
- **Testability**: Pure command handlers and event appliers

### CQRS Read Side (Projections)
The **Projections** (WalletProjection, InvoiceProjection) listen to event streams and update denormalized read models optimized for queries.

**Key Responsibilities:**
- **Event Handling**: Subscribe to events from EventStore
- **Read Model Updates**: Write denormalized data to ReadModelStorage
- **Checkpointing**: Track last processed event for idempotent replay
- **View Building**: Create optimized query models

**Key Benefits:**
- **Performance**: Read models optimized for fast queries
- **Flexibility**: Multiple read models from same events
- **Eventual Consistency**: Async updates don't block writes
- **Scalability**: Read and write scale independently

### CQRS Integration Pattern
```
Commands → Coordinators → Aggregates → Events → EventStore
                                                    ↓
                                          ProjectionManager
                                                    ↓
                                              Projections
                                                    ↓
                                           ReadModelStorage ← Queries
```

**Complete Flow Example (Invoice Payment):**
1. **SPVActor** validates BEEF transaction with invoice metadata
2. Sends `MarkInvoicePaidMessage` to **InvoiceCoordinatorActor**
3. **InvoiceCoordinatorActor** routes `MarkInvoicePaidCommand` to **InvoiceAggregate**
4. **InvoiceAggregate** validates state (pending?) and emits `InvoicePaidEvent`
5. **EventStore** persists event (CBOR format)
6. **ProjectionManager** streams event to **InvoiceProjection**
7. **InvoiceProjection** updates invoice read model in Isar (status: paid)
8. **Application** queries read model to show updated invoice status

**Critical CQRS Rules:**
- ❌ Coordinators never write to storage (except via commands to aggregates)
- ❌ Aggregates never query read models (only use their own state)
- ❌ Projections never emit events (only read and update read models)
- ✅ Commands go through aggregates only
- ✅ Queries read from read models only (never EventStore)
- ✅ Events are the source of truth for state reconstruction

## Dactor Actor Implementations

### WalletManagerActor

The central coordinator that manages multiple wallet aggregates and routes commands:

```dart
class WalletManagerActor extends Actor {
  final Map<String, BitcoinWalletAggregate> _wallets = {};
  final EventStore _eventStore;
  final ActorRef _spvActor;
  final ActorRef _arcActor;
  
  @override
  Future<void> onReceive(Message message) async {
    switch (message.payload) {
      case CreateWalletMessage msg:
        await _createWallet(msg.walletId, msg.name, msg.metadata);
        
      case WalletCommandMessage msg:
        await _routeCommandToWallet(msg.walletId, msg.command);
        
      case ListWalletsMessage():
        sender.tell(WalletListMessage(_wallets.keys.toList()));
        
      case BackupWalletMessage msg:
        await _backupWallet(msg.walletId);
        
      case RestoreWalletMessage msg:
        await _restoreWallet(msg.walletId, msg.backupData);
    }
  }
  
  Future<void> _routeCommandToWallet(String walletId, WalletCommand command) async {
    var aggregate = _wallets[walletId];
    if (aggregate == null) {
      // Load wallet from event store
      aggregate = await _loadWalletFromEventStore(walletId);
      _wallets[walletId] = aggregate;
    }
    
    // Handle command and get events
    var events = aggregate.handleCommand(aggregate.currentState, command);
    
    // Persist events
    await _eventStore.appendEvents(walletId, events, aggregate.version);
    
    // Apply events to update state
    for (var event in events) {
      aggregate.currentState = aggregate.applyEvent(aggregate.currentState, event);
    }
  }
  
  Future<BitcoinWalletAggregate> _loadWalletFromEventStore(String walletId) async {
    var events = await _eventStore.getEvents(walletId);
    var aggregate = BitcoinWalletAggregate(
      aggregateId: walletId,
      aggregateType: 'BitcoinWallet',
      eventStore: _eventStore,
    );
    
    // Replay events to rebuild state
    for (var event in events) {
      aggregate.currentState = aggregate.applyEvent(aggregate.currentState, event);
    }
    
    return aggregate;
  }
}
```

### SPVActor

Handles true SPV validation using stored block headers and merkle proofs:

```dart
class SPVActor extends Actor {
  final WalletStorage _storage;
  final ActorRef _walletManager;
  final BlockHeaderChain _headerChain;
  final Map<String, String> _addressToWallet = {}; // address -> walletId mapping
  
  @override
  Future<void> onReceive(Message message) async {
    switch (message.payload) {
      case ValidateBEEFMessage msg:
        var result = await _validateBEEFProof(msg.beefData);
        sender.tell(BEEFValidationResult(result.isValid, result.merkleRoot));
        
      case ValidateTransactionMessage msg:
        var result = await _validateTransactionSPV(msg.transaction, msg.merkleProof);
        sender.tell(TransactionValidationResult(result.isValid, result.blockHeight));
        
      case RetrieveMerkleProofMessage msg:
        var proof = await _storage.getMerkleProof(msg.txid);
        sender.tell(MerkleProofMessage(msg.txid, proof));
        
      case GetSPVStatusMessage():
        var status = await _getSPVStatus();
        sender.tell(SPVStatusMessage(status));
        
      case AddMonitoringAddressMessage msg:
        _addressToWallet[msg.address] = msg.walletId;
    }
  }
  
  Future<BEEFValidationResult> _validateBEEFProof(String beefData) async {
    try {
      var beef = BEEF.fromHex(beefData);
      
      // Extract transactions and proofs from BEEF
      var transactions = _extractTransactions(beef);
      var merkleProofs = _extractMerkleProofs(beef);
      
      // Validate each transaction against stored headers
      for (var i = 0; i < transactions.length; i++) {
        var tx = transactions[i];
        var proof = merkleProofs[i];
        
        var blockHeader = await _getBlockHeader(proof.blockHash);
        if (blockHeader == null) {
          return BEEFValidationResult(false, null, 'Block header not found');
        }
        
        var isValid = _verifyMerkleProof(tx.id, proof, blockHeader.merkleRoot);
        if (!isValid) {
          return BEEFValidationResult(false, null, 'Invalid merkle proof for tx ${tx.id}');
        }
      }
      
      return BEEFValidationResult(true, beef.merkleRoot, null);
    } catch (e) {
      return BEEFValidationResult(false, null, e.toString());
    }
  }
  
  Future<BlockHeader?> _getBlockHeader(String blockHash) async {
    return await _storage.getBlockHeader(blockHash);
  }
  
  List<BitcoinTransaction> _extractSpendableUTXOs(List<BitcoinTransaction> transactions) {
    var spendableUTXOs = <BitcoinUtxo>[];
    
    for (var tx in transactions) {
      for (var i = 0; i < tx.outputs.length; i++) {
        var output = tx.outputs[i];
        
        // Check if output belongs to any monitored wallet
        var walletId = _findWalletForOutput(output);
        if (walletId != null) {
          // TODO: Implement wallet key management integration
          // This would check if the output can be spent by wallet keys
          var utxo = BitcoinUtxo.fromTransactionOutput(
            output,
            tx.id,
            i,
            tx.blockHeight ?? 0,
            tx.confirmations ?? 0,
          );
          spendableUTXOs.add(utxo);
        }
      }
    }
    
    return spendableUTXOs;
  }
  
  List<BitcoinUtxo> _extractSpentUTXOs(List<BitcoinTransaction> transactions) {
    var spentUTXOs = <BitcoinUtxo>[];
    
    for (var tx in transactions) {
      for (var input in tx.inputs) {
        // TODO: Check if spent UTXO belongs to monitored wallets
        // This would require tracking wallet UTXOs
      }
    }
    
    return spentUTXOs;
  }
  
  String? _findWalletForOutput(TransactionOutput output) {
    // TODO: Implement address/script -> wallet mapping
    // This would check script against wallet addresses/pubkeys
    return null;
  }
}
```

### HeaderSyncActor

Manages block header synchronization and chain tip tracking. For fast initial sync, `CdnHeaderSyncService` provides an alternative path that bulk-downloads headers from a CDN before switching to P2P incremental sync.

```dart
class HeaderSyncActor extends Actor {
  final BlockHeaderChain _headerChain;
  final ActorRef? _spvActor;
  int _headersProcessed = 0;
  int _totalExpectedHeaders = 0;
  
  @override
  Future<void> onReceive(Message message) async {
    switch (message.payload) {
      case BlockHeadersReceivedMessage msg:
        await _processHeaders(msg.headers, msg.source);
        
      case ChainTipEventMessage msg:
        await _handleChainTipEvent(msg.chainTip, msg.eventType);
        
      case RequestHeaderSyncMessage msg:
        await _initiateHeaderSync(msg.startHeight, msg.requestor);
        
      case GetSyncStatusMessage():
        sender.tell(HeaderSyncStatusMessage(
          _headersProcessed,
          _totalExpectedHeaders,
          _headerChain.currentTip?.height ?? 0,
        ));
    }
  }
  
  Future<void> _processHeaders(List<BlockHeader> headers, String source) async {
    try {
      for (var header in headers) {
        var stored = await _headerChain.addHeader(header);
        if (stored) {
          _headersProcessed++;
          
          // Notify SPV Actor of new header for validation
          _spvActor?.tell(BlockHeaderStoredMessage(
            blockHash: header.blockHash(),
            height: header.height ?? 0,
            merkleRoot: header.merkleRoot,
          ));
        }
      }
      
      // Update chain tip if headers extended the chain
      var currentTip = await _headerChain.getCurrentTip();
      if (currentTip != null) {
        _spvActor?.tell(ChainTipUpdatedMessage(
          blockHash: currentTip.blockHash,
          height: currentTip.height,
          previousHash: currentTip.prevBlock,
        ));
      }
      
    } catch (e) {
      sender.tell(HeaderSyncErrorMessage('Failed to process headers: $e'));
    }
  }
  
  Future<void> _handleChainTipEvent(ChainTip chainTip, ChainTipEventType eventType) async {
    switch (eventType) {
      case ChainTipEventType.newTip:
        await _handleNewChainTip(chainTip);
        break;
      case ChainTipEventType.reorganization:
        await _handleChainReorganization(chainTip);
        break;
    }
  }
  
  Future<void> _handleNewChainTip(ChainTip chainTip) async {
    // Update our chain tip and notify interested actors
    var header = await _headerChain.getHeader(chainTip.blockHash);
    if (header != null) {
      _spvActor?.tell(ChainTipUpdatedMessage(
        blockHash: chainTip.blockHash,
        height: chainTip.height,
        previousHash: header.prevBlock,
      ));
    }
  }
  
  Future<void> _handleChainReorganization(ChainTip newTip) async {
    // Handle chain reorganization
    var affectedHeaders = await _headerChain.handleReorganization(newTip.blockHash);
    
    _spvActor?.tell(ChainReorganizationMessage(
      newTipHash: newTip.blockHash,
      newTipHeight: newTip.height,
      affectedBlocks: affectedHeaders.map((h) => h.blockHash()).toList(),
    ));
  }
}
```

### SpiffyNodeBridge

Translates SpiffyNode events to LibSpiffy actor messages:

```dart
class SpiffyNodeBridge {
  final ActorRef _headerSyncActor;
  final ActorRef? _spvActor;
  StreamSubscription<ChainTipEvent>? _chainTipSubscription;
  
  SpiffyNodeBridge({
    required ActorRef headerSyncActor,
    ActorRef? spvActor,
  }) : _headerSyncActor = headerSyncActor,
       _spvActor = spvActor;
  
  /// Connect to SpiffyNode and start event translation
  void connectToSpiffyNode(PeerManager peerManager) {
    // Subscribe to chain tip events
    _chainTipSubscription = peerManager.chainTipTracker.tipEvents.listen(
      (event) => _translateChainTipEvent(event),
      onError: (error) => print('Chain tip event error: $error'),
    );
    
    // Register peer handler to capture MsgHeaders
    peerManager.addPeerHandler(LibSpiffyPeerHandler(this));
  }
  
  /// Disconnect from SpiffyNode
  void disconnectFromSpiffyNode() {
    _chainTipSubscription?.cancel();
    _chainTipSubscription = null;
  }
  
  /// Translate SpiffyNode ChainTipEvent to LibSpiffy actor message
  void _translateChainTipEvent(ChainTipEvent event) {
    var chainTip = _SimpleChainTip(
      blockHash: event.tip.blockHash,
      height: event.tip.height,
      timestamp: event.tip.timestamp,
    );
    
    var eventType = ChainTipEventType.values.firstWhere(
      (type) => type.name == event.type.name,
      orElse: () => ChainTipEventType.newTip,
    );
    
    _headerSyncActor.tell(ChainTipEventMessage(
      chainTip: chainTip,
      eventType: eventType,
      source: 'SpiffyNode',
    ));
  }
  
  /// Forward MsgHeaders from SpiffyNode to HeaderSyncActor
  void storeHeaders(MsgHeaders headersMessage) {
    var headers = headersMessage.headers.map((header) => 
      BlockHeader.fromSpiffyNodeHeader(header)
    ).toList();
    
    _headerSyncActor.tell(BlockHeadersReceivedMessage(
      headers: headers,
      source: 'SpiffyNode',
      requestId: null,
    ));
  }
}

/// Peer handler that captures MsgHeaders and forwards to bridge
class LibSpiffyPeerHandler extends PeerHandler {
  final SpiffyNodeBridge _bridge;
  
  LibSpiffyPeerHandler(this._bridge);
  
  @override
  Future<void> handleHeaders(MsgHeaders message, Peer peer) async {
    // Forward headers to LibSpiffy for storage
    _bridge.storeHeaders(message);
  }
  
  // Other message handlers can be added as needed
  @override
  Future<void> handleAddr(MsgAddr message, Peer peer) async {
    // Could forward address announcements if needed
  }
  
  @override
  Future<void> handleInv(MsgInv message, Peer peer) async {
    // Could forward inventory announcements if needed
  }
}

/// Simple ChainTip implementation for message translation
class _SimpleChainTip implements ChainTip {
  @override
  final String blockHash;
  
  @override  
  final int height;
  
  @override
  final DateTime timestamp;
  
  _SimpleChainTip({
    required this.blockHash,
    required this.height,
    required this.timestamp,
  });
}
```

### ARCActor

Handles ARC service integration for transaction broadcasting and monitoring:

```dart
class ARCActor extends Actor {
  final ARCService _arcService;
  final ActorRef _walletManager;
  final Map<String, TransactionStatus> _transactionStatus = {};
  final Timer? _statusCheckTimer;
  
  @override
  Future<void> onReceive(Message message) async {
    switch (message.payload) {
      case BroadcastTransactionMessage msg:
        await _broadcastTransaction(msg.walletId, msg.txHex, msg.txid);
        
      case BroadcastBEEFMessage msg:
        await _broadcastBEEF(msg.walletId, msg.beefHex, msg.txid);
        
      case CheckTransactionStatusMessage msg:
        await _checkTransactionStatus(msg.txid);
        
      case GetFeeQuoteMessage():
        var quote = await _arcService.getFeeQuote();
        sender.tell(FeeQuoteMessage(quote));
        
      case EstimateFeeMessage msg:
        var fee = await _arcService.estimateFee(msg.inputCount, msg.outputCount);
        sender.tell(FeeEstimateMessage(fee));
        
      case GetMerkleProofMessage msg:
        var proof = await _arcService.getMerkleProof(msg.txid);
        sender.tell(MerkleProofMessage(proof));
        
      case StartStatusMonitoringMessage msg:
        _startStatusMonitoring(msg.txids);
    }
  }
  
  Future<void> _broadcastTransaction(String walletId, String txHex, String txid) async {
    try {
      var response = await _arcService.broadcastTransaction(txHex);
      
      if (response.isSuccess) {
        // Notify wallet of successful broadcast
        var command = BroadcastTransactionCommand(
          walletId: walletId,
          transactionId: txid,
        );
        _walletManager.tell(WalletCommandMessage(walletId, command));
        
        // Start monitoring transaction status
        _transactionStatus[txid] = TransactionStatus.broadcasted;
        _startStatusMonitoring([txid]);
        
        sender.tell(BroadcastSuccessMessage(txid, response.txid));
      } else {
        sender.tell(BroadcastFailedMessage(txid, response.error));
      }
    } catch (e) {
      sender.tell(BroadcastFailedMessage(txid, e.toString()));
    }
  }
  
  Future<void> _broadcastBEEF(String walletId, String beefHex, String txid) async {
    try {
      var response = await _arcService.broadcastBEEF(beefHex);
      
      if (response.isSuccess) {
        var command = BroadcastTransactionCommand(
          walletId: walletId,
          transactionId: txid,
        );
        _walletManager.tell(WalletCommandMessage(walletId, command));
        
        sender.tell(BroadcastSuccessMessage(txid, response.txid));
      } else {
        sender.tell(BroadcastFailedMessage(txid, response.error));
      }
    } catch (e) {
      sender.tell(BroadcastFailedMessage(txid, e.toString()));
    }
  }
  
  Future<void> _checkTransactionStatus(String txid) async {
    try {
      var status = await _arcService.getTransactionStatus(txid);
      var previousStatus = _transactionStatus[txid];
      
      if (status != previousStatus) {
        _transactionStatus[txid] = status;
        
        // Notify relevant wallets of status changes
        if (status.isConfirmed && previousStatus != TransactionStatus.confirmed) {
          // Find wallet for this transaction and update confirmations
          // This would require mapping txid -> walletId
          var command = UpdateUTXOConfirmationsCommand(
            walletId: 'wallet_id', // Would need to track this
            utxoKey: txid,
            confirmations: status.confirmations,
            blockHeight: status.blockHeight,
          );
          _walletManager.tell(WalletCommandMessage('wallet_id', command));
        }
      }
      
      sender.tell(TransactionStatusMessage(txid, status));
    } catch (e) {
      sender.tell(TransactionStatusErrorMessage(txid, e.toString()));
    }
  }
  
  void _startStatusMonitoring(List<String> txids) {
    // Periodically check transaction status
    Timer.periodic(Duration(seconds: 30), (timer) {
      for (var txid in txids) {
        if (_transactionStatus[txid] != TransactionStatus.confirmed) {
          self.tell(CheckTransactionStatusMessage(txid));
        }
      }
    });
  }
}
```

### PaymentCoordinatorActor

The PaymentCoordinatorActor orchestrates the construction of outbound payments without broadcasting them. It selects UTXOs from the wallet aggregate, collects ancestor proofs for each input, and assembles a complete BEEF envelope that the caller (typically the WalletCoordinatorActor) can then hand off to the ARCActor for broadcast. By separating construction from broadcast, the coordinator supports dry-run validation, multi-party signing flows, and payment channel funding.

**Key Responsibilities:**
- UTXO selection using the wallet aggregate's funding and special UTXO pools
- Ancestor proof collection for each selected input (merkle paths back to confirmed headers)
- BEEF envelope construction packaging the transaction with its ancestor proofs
- Fee estimation coordination with ARCActor fee quotes
- Does **not** broadcast -- returns the assembled BEEF to the caller

### BenfordCoordinatorActor

The BenfordCoordinatorActor applies Benford's Law statistical distribution to UTXO splitting decisions. When the wallet creates change outputs or consolidates UTXOs, this actor determines split amounts whose leading-digit distribution matches the natural logarithmic curve (digit 1 at ~30.1%, digit 9 at ~4.6%). This makes the wallet's on-chain footprint statistically indistinguishable from organic economic activity, resisting chain-analysis clustering.

**Key Responsibilities:**
- Generating Benford-compliant split amounts for change outputs
- Advising the PaymentCoordinatorActor on privacy-optimal output structures
- Periodic UTXO pool analysis and consolidation recommendations
- Privacy score calculation and reporting

### TransactionLifecycleCoordinatorActor

The TransactionLifecycleCoordinatorActor tracks every outbound transaction from creation through final confirmation. It maintains a registry of pending transactions, registers callback URLs with the ARCActor for status webhooks, and on restart recovers incomplete transactions from the event store to resume monitoring.

**Key Responsibilities:**
- Tracking pending transaction state (created, broadcast, seen, confirmed)
- Registering transactions with ARCActor for merkle proof callbacks
- Recovering in-flight transactions on wallet restart
- Emitting lifecycle events (broadcast success/failure, confirmation milestones)

### ImportActor

The ImportActor handles wallet import from the blockchain when a user restores from a mnemonic or xpub. It performs address discovery using the standard BIP-44 gap limit, queries transaction history for each discovered address, and feeds the recovered UTXOs and transactions back into the wallet aggregate via the normal command flow.

**Key Responsibilities:**
- BIP-44 address discovery with configurable gap limit
- Transaction harvesting for discovered addresses
- UTXO reconstruction from harvested transaction history
- Progress reporting during long-running import operations

## Plugin System

LibSpiffy provides an extensible plugin system for custom script types and multi-output protocol transactions.

- **ScriptPlugin**: Interface for registering custom script types. Implementations provide script identification, metadata extraction, and locking/unlocking script builders, which are registered with the `ScriptTemplateRegistry` at wallet initialization.
- **TransactionBuilderPlugin**: Interface for plugins that need to add multiple outputs to a transaction (e.g., token protocols, OP_RETURN data protocols). The plugin receives the `TransactionBuilder` and appends its outputs before the transaction is finalized.
- **PluginRegistry**: Singleton that manages all registered `ScriptPlugin` and `TransactionBuilderPlugin` instances. Actors query the registry to resolve script types and invoke builder plugins during transaction construction.
- **CallbackTransactionSigner**: A signing adapter that lets plugins request transaction signing without direct access to private keys. The plugin provides unsigned inputs and receives signatures through a callback, keeping key material confined to the `CryptoService`.

## Core Components

### BitcoinWalletAggregate

The event-sourced aggregate root that handles all wallet operations:

```dart
class BitcoinWalletAggregate extends AggregateRoot<WalletState> {
  @override
  WalletState createInitialState() {
    // Register all protocol templates at initialization
    final registry = ScriptTypeRegistry();
    registry.registerScriptType(AIPTemplate());
    registry.registerScriptType(BMAPTemplate());
    registry.registerScriptType(HodlTemplate());
    registry.registerScriptType(TokenTemplate());
    
    return WalletState.initial(registry: registry);
  }

  // Command handlers produce events
  List<Event> _handleCreateTransaction(WalletState currentState, CreateTransactionCommand command);
  List<Event> _handleUTXOReceived(WalletState currentState, UTXOReceivedCommand command);

  // Event appliers update state
  WalletState _applyTransactionCreated(WalletState currentState, TransactionCreatedEvent event);
  WalletState _applyUTXOReceived(WalletState currentState, UTXOReceivedEvent event);
}
```

### UTXO Model with Script Awareness

```dart
class BitcoinUtxo {
  // Core UTXO data
  final String txid;
  final int vout;
  final dartsv.Coin value;
  final SVScript script;
  
  // Script analysis (cached)
  final String scriptType;           // "p2pkh", "aip", "bmap", "hodl"
  final Map<String, dynamic> scriptMetadata;  // {address, publicKey, protocol data}
  final UTXOCategory category;       // funding, special, protocol
  final bool spendable;
  
  // Factory with script analysis
  static BitcoinUtxo fromTransactionOutput(
    TransactionOutput output,
    ScriptTypeRegistry registry,
    List<String> walletAddresses,
    List<String> walletPubKeys
  ) {
    var scriptType = registry.identifyScriptType(output.script);
    var metadata = registry.extractScriptMetadata(output.script);
    var spendable = registry.canOutputBeSpentBy(output, walletAddresses, walletPubKeys: walletPubKeys);
    
    return BitcoinUtxo(
      scriptType: scriptType ?? 'unknown',
      scriptMetadata: metadata ?? {},
      category: _categorizeUTXO(scriptType, spendable),
      spendable: spendable,
      // ... other fields
    );
  }
}

enum UTXOCategory {
  funding,      // P2PKH - preferred for general spending
  special,      // Multisig, time-locked - spendable but special handling
  protocol      // OP_RETURN, data outputs - tracked but unspendable
}
```

### WalletState Structure

```dart
class WalletState extends eventador.State {
  // UTXO categorization for efficient spending
  final Map<String, BitcoinUtxo> fundingUTXOs;     // P2PKH - preferred for spending
  final Map<String, BitcoinUtxo> specialUTXOs;     // Multisig, conditional
  final Map<String, BitcoinUtxo> protocolOutputs;  // Data, unspendable
  
  // Wallet metadata
  final String walletId;
  final String? rootAddress;
  final int nextDerivationIndex;
  final bool isCreated;
  final Map<String, dynamic> metadata;
  
  // Cached for performance
  final dartsv.Coin confirmedBalance;
  final dartsv.Coin unconfirmedBalance;
  final List<String> addresses;
  final List<String> publicKeys;
  
  // Registry for script analysis
  final ScriptTypeRegistry scriptRegistry;
}
```

### Invoice System (CQRS Pattern)

LibSpiffy implements a complete invoice-based payment system using proper CQRS patterns with event sourcing.

#### InvoiceCoordinatorActor

The coordinator that routes invoice commands to aggregate instances and coordinates with WalletManager for address generation:

```dart
class InvoiceCoordinatorActor extends Actor {
  final ActorRef _walletManager;
  final ReadModelStorage _storage;
  final EventStore _eventStore;
  final Map<String, ActorRef> _invoiceAggregates = {}; // invoiceId -> ActorRef
  final Map<String, _PendingInvoiceRequest> _pendingInvoiceRequests = {};
  Timer? _expirationTimer;
  
  @override
  Future<void> onMessage(dynamic message) async {
    switch (message.runtimeType) {
      case CreateInvoiceMessage:
        await _handleCreateInvoice(message as CreateInvoiceMessage);
        break;
      case MarkInvoicePaidMessage:
        await _handleMarkInvoicePaid(message as MarkInvoicePaidMessage);
        break;
      case CheckInvoiceMessage:
        await _handleCheckInvoice(message as CheckInvoiceMessage);
        break;
      case ListInvoicesMessage:
        await _handleListInvoices(message as ListInvoicesMessage);
        break;
      case CancelInvoiceMessage:
        await _handleCancelInvoice(message as CancelInvoiceMessage);
        break;
      case AddressGeneratedResponse:
        await _handleAddressGenerated(message as AddressGeneratedResponse);
        break;
    }
  }
  
  // Request address from wallet, store pending request
  Future<void> _handleCreateInvoice(CreateInvoiceMessage msg) async {
    final invoiceId = _uuid.v4();
    
    // Store pending request
    _pendingInvoiceRequests[invoiceId] = _PendingInvoiceRequest(
      invoiceId: invoiceId,
      walletId: msg.walletId,
      amount: msg.amount,
      description: msg.description,
      expiresIn: msg.expiresIn,
      numberOfAddresses: msg.numberOfAddresses,
      originalSender: context.sender,
    );
    
    // Request address from wallet (with invoiceId in metadata)
    _walletManager.tell(
      WalletCommandMessage(
        msg.walletId,
        GenerateAddressCommand(
          walletId: msg.walletId,
          metadata: {'invoiceId': invoiceId},
        ),
      ),
      sender: context.self,
    );
  }
  
  // Receive address, spawn InvoiceAggregate, send CreateInvoiceCommand
  Future<void> _handleAddressGenerated(AddressGeneratedResponse msg) async {
    final invoiceId = msg.metadata['invoiceId'] as String?;
    if (invoiceId == null || !_pendingInvoiceRequests.containsKey(invoiceId)) {
      return;
    }
    
    final pending = _pendingInvoiceRequests.remove(invoiceId)!;
    
    // Spawn InvoiceAggregate actor
    final aggregateRef = await context.actorSystem.spawn(
      'Invoice_$invoiceId',
      () => InvoiceAggregate(
        persistenceId: 'Invoice_$invoiceId',
        eventStore: _eventStore,
      ),
    );
    _invoiceAggregates[invoiceId] = aggregateRef;
    
    // Allow recovery to complete
    await Future.delayed(Duration(milliseconds: 200));
    
    // Send CreateInvoiceCommand to aggregate
    aggregateRef.tell(CreateInvoiceCommand(
      invoiceId: invoiceId,
      walletId: pending.walletId,
      addresses: [msg.address], // Generated address(es)
      amount: pending.amount,
      description: pending.description,
      expiresIn: pending.expiresIn,
      invoiceMetadata: {},
    ));
    
    // Respond to original sender
    pending.originalSender?.tell(InvoiceCreatedMessage(
      invoiceId: invoiceId,
      walletId: pending.walletId,
      addresses: [msg.address],
      amount: pending.amount,
      description: pending.description,
      createdAt: DateTime.now(),
      expiresAt: pending.expiresIn != null 
          ? DateTime.now().add(pending.expiresIn!) 
          : null,
      success: true,
    ));
  }
  
  // Route command to InvoiceAggregate
  Future<void> _handleMarkInvoicePaid(MarkInvoicePaidMessage msg) async {
    var aggregateRef = _invoiceAggregates[msg.invoiceId];
    if (aggregateRef == null) {
      // Spawn aggregate to recover from events
      aggregateRef = await context.actorSystem.spawn(
        'Invoice_${msg.invoiceId}',
        () => InvoiceAggregate(
          persistenceId: 'Invoice_${msg.invoiceId}',
          eventStore: _eventStore,
        ),
      );
      _invoiceAggregates[msg.invoiceId] = aggregateRef;
      await Future.delayed(Duration(milliseconds: 200)); // Allow recovery
    }
    
    // Send command to aggregate
    aggregateRef.tell(MarkInvoicePaidCommand(
      invoiceId: msg.invoiceId,
      txid: msg.txid,
      amountReceived: msg.amountReceived,
      addressesPaidTo: msg.addressesPaidTo,
      paidAt: msg.paidAt,
    ));
    
    // Respond with status
    context.sender?.tell(InvoiceStatusMessage(
      invoiceId: msg.invoiceId,
      status: InvoiceStatus.paid,
      paidAt: msg.paidAt,
      txid: msg.txid,
      statusMessage: 'Invoice marked as paid',
    ));
  }
  
  // Query read model (NOT EventStore)
  Future<void> _handleCheckInvoice(CheckInvoiceMessage msg) async {
    final invoice = await _storage.getInvoice(msg.invoiceId);
    
    if (invoice != null) {
      context.sender?.tell(InvoiceDetailsResponse(
        invoiceId: invoice.invoiceId,
        walletId: invoice.walletId,
        addresses: invoice.addresses,
        amount: invoice.amount,
        description: invoice.description,
        status: invoice.status,
        createdAt: invoice.createdAt,
        expiresAt: invoice.expiresAt,
        paidAt: invoice.paidAt,
        paymentTxid: invoice.paymentTxid,
        found: true,
      ));
    } else {
      context.sender?.tell(InvoiceDetailsResponse(
        invoiceId: msg.invoiceId,
        addresses: [],
        amount: BigInt.zero,
        status: InvoiceStatus.pending,
        createdAt: DateTime.now(),
        found: false,
        error: 'Invoice not found',
      ));
    }
  }
  
  // Periodic expiration check
  void _startExpirationTimer() {
    _expirationTimer = Timer.periodic(const Duration(minutes: 5), (_) {
      _checkExpiredInvoices();
    });
  }
  
  Future<void> _checkExpiredInvoices() async {
    // Query read model for pending invoices
    final pendingInvoices = await _storage.listInvoicesByStatus(
      InvoiceStatus.pending,
    );
    
    final now = DateTime.now();
    for (final invoice in pendingInvoices) {
      if (invoice.expiresAt != null && invoice.expiresAt!.isBefore(now)) {
        // Get/spawn aggregate and send ExpireInvoiceCommand
        var aggregateRef = _invoiceAggregates[invoice.invoiceId];
        if (aggregateRef == null) {
          aggregateRef = await context.actorSystem.spawn(
            'Invoice_${invoice.invoiceId}',
            () => InvoiceAggregate(
              persistenceId: 'Invoice_${invoice.invoiceId}',
              eventStore: _eventStore,
            ),
          );
          _invoiceAggregates[invoice.invoiceId] = aggregateRef;
          await Future.delayed(Duration(milliseconds: 200));
        }
        
        aggregateRef.tell(ExpireInvoiceCommand(
          invoiceId: invoice.invoiceId,
        ));
      }
    }
  }
}
```

#### InvoiceAggregate

The event-sourced aggregate root for invoice business logic:

```dart
class InvoiceAggregate extends AggregateRoot<InvoiceState> {
  InvoiceAggregate({
    required String persistenceId,
    required EventStore eventStore,
  }) : super(persistenceId: persistenceId, eventStore: eventStore);
  
  @override
  InvoiceState createInitialState() => InvoiceState(
    invoiceId: persistenceId.replaceFirst('Invoice_', ''),
    walletId: '',
    addresses: [],
    amount: BigInt.zero,
    status: InvoiceStatus.pending,
    createdAt: DateTime.now(),
    metadata: {},
  );
  
  @override
  Future<List<Event>> handleCommand(InvoiceState currentState, Command command) async {
    return switch (command.runtimeType) {
      CreateInvoiceCommand => _handleCreateInvoice(currentState, command as CreateInvoiceCommand),
      MarkInvoicePaidCommand => _handleMarkInvoicePaid(currentState, command as MarkInvoicePaidCommand),
      CancelInvoiceCommand => _handleCancelInvoice(currentState, command as CancelInvoiceCommand),
      ExpireInvoiceCommand => _handleExpireInvoice(currentState, command as ExpireInvoiceCommand),
      _ => throw ArgumentError('Unknown command type: ${command.runtimeType}'),
    };
  }
  
  // Business logic: Validate and emit events
  List<Event> _handleCreateInvoice(InvoiceState state, CreateInvoiceCommand cmd) {
    if (cmd.amount <= BigInt.zero) {
      throw ArgumentError('Invoice amount must be positive');
    }
    if (cmd.addresses.isEmpty) {
      throw ArgumentError('Invoice must have at least one payment address');
    }
    
    return [InvoiceCreatedEvent(
      invoiceId: cmd.invoiceId,
      walletId: cmd.walletId,
      addresses: cmd.addresses,
      amount: cmd.amount,
      description: cmd.description,
      createdAt: DateTime.now(),
      expiresAt: cmd.expiresIn != null 
          ? DateTime.now().add(cmd.expiresIn!) 
          : null,
      metadata: cmd.invoiceMetadata ?? {},
    )];
  }
  
  List<Event> _handleMarkInvoicePaid(InvoiceState state, MarkInvoicePaidCommand cmd) {
    if (state.status != InvoiceStatus.pending) {
      throw StateError('Invoice is not pending (status: ${state.status})');
    }
    if (cmd.amountReceived < state.amount) {
      throw ArgumentError('Payment amount ${cmd.amountReceived} is less than invoice amount ${state.amount}');
    }
    
    return [InvoicePaidEvent(
      invoiceId: cmd.invoiceId,
      paidAt: cmd.paidAt ?? DateTime.now(),
      txid: cmd.txid,
      amountReceived: cmd.amountReceived,
      addressesPaidTo: cmd.addressesPaidTo,
    )];
  }
  
  List<Event> _handleExpireInvoice(InvoiceState state, ExpireInvoiceCommand cmd) {
    if (state.status != InvoiceStatus.pending) {
      return []; // Already paid/cancelled/expired
    }
    
    return [InvoiceExpiredEvent(
      invoiceId: cmd.invoiceId,
      expiredAt: DateTime.now(),
    )];
  }
  
  @override
  void eventHandler(Event event) {
    ensureStateInitialized(); // Critical for recovery!
    
    if (event is! InvoiceEvent) {
      throw ArgumentError('Expected InvoiceEvent, got ${event.runtimeType}');
    }
    
    switch (event.runtimeType) {
      case InvoiceCreatedEvent:
        _applyInvoiceCreated(event as InvoiceCreatedEvent);
        break;
      case InvoicePaidEvent:
        _applyInvoicePaid(event as InvoicePaidEvent);
        break;
      case InvoiceExpiredEvent:
        _applyInvoiceExpired(event as InvoiceExpiredEvent);
        break;
      case InvoiceCancelledEvent:
        _applyInvoiceCancelled(event as InvoiceCancelledEvent);
        break;
      default:
        throw ArgumentError('Unknown event type: ${event.runtimeType}');
    }
  }
  
  // Mutate currentState directly (new Eventador pattern)
  void _applyInvoiceCreated(InvoiceCreatedEvent event) {
    currentState.walletId = event.walletId;
    currentState.addresses = List.from(event.addresses);
    currentState.amount = event.amount;
    currentState.description = event.description;
    currentState.status = InvoiceStatus.pending;
    currentState.createdAt = event.createdAt;
    currentState.expiresAt = event.expiresAt;
    currentState.version++;
    currentState.lastModified = event.timestamp;
  }
  
  void _applyInvoicePaid(InvoicePaidEvent event) {
    currentState.status = InvoiceStatus.paid;
    currentState.paidAt = event.paidAt;
    currentState.paymentTxid = event.txid;
    currentState.amountReceived = event.amountReceived;
    currentState.version++;
    currentState.lastModified = event.timestamp;
  }
  
  void _applyInvoiceExpired(InvoiceExpiredEvent event) {
    currentState.status = InvoiceStatus.expired;
    currentState.version++;
    currentState.lastModified = event.timestamp;
  }
}
```

#### InvoiceProjection

Builds the invoice read model from events:

```dart
class InvoiceProjection extends Projection<InvoiceReadModel> {
  final ReadModelStorage _storage;
  final String _projectionId;
  late InvoiceReadModel _readModel;
  int _checkpoint = 0;
  
  InvoiceProjection({
    required String projectionId,
    required EventStore eventStore,
    required ReadModelStorage storage,
  }) : _projectionId = projectionId,
       _storage = storage;
  
  @override
  Future<bool> handle(Event event) async {
    if (event is! InvoiceEvent) return false;
    
    switch (event.runtimeType) {
      case InvoiceCreatedEvent:
        await _handleInvoiceCreated(event as InvoiceCreatedEvent);
        return true;
      case InvoicePaidEvent:
        await _handleInvoicePaid(event as InvoicePaidEvent);
        return true;
      case InvoiceExpiredEvent:
        await _handleInvoiceExpired(event as InvoiceExpiredEvent);
        return true;
      case InvoiceCancelledEvent:
        await _handleInvoiceCancelled(event as InvoiceCancelledEvent);
        return true;
      default:
        return false;
    }
  }
  
  // Update read model (idempotent for replay)
  Future<void> _handleInvoiceCreated(InvoiceCreatedEvent event) async {
    final existing = await _storage.getInvoice(event.invoiceId);
    if (existing == null) {
      final invoice = Invoice(
        invoiceId: event.invoiceId,
        walletId: event.walletId,
        addresses: event.addresses,
        amount: event.amount,
        description: event.description,
        status: InvoiceStatus.pending,
        createdAt: event.createdAt,
        expiresAt: event.expiresAt,
        metadata: event.metadata,
      );
      await _storage.storeInvoice(invoice);
    }
    // If exists, skip (idempotent replay)
  }
  
  Future<void> _handleInvoicePaid(InvoicePaidEvent event) async {
    await _storage.updateInvoiceStatus(
      event.invoiceId,
      InvoiceStatus.paid,
      paidAt: event.paidAt,
      txid: event.txid,
      amountReceived: event.amountReceived,
    );
  }
  
  Future<void> _handleInvoiceExpired(InvoiceExpiredEvent event) async {
    await _storage.updateInvoiceStatus(
      event.invoiceId,
      InvoiceStatus.expired,
    );
  }
}
```

#### Invoice State Machine

```
      ┌─────────┐
      │ PENDING │ (Initial state)
      └────┬────┘
           │
    ┌──────┼──────┐
    │      │      │
    ▼      ▼      ▼
┌──────┐ ┌────┐ ┌─────────┐
│ PAID │ │EXPI│ │CANCELLED│ (Terminal states)
└──────┘ │RED │ └─────────┘
         └────┘
```

**State Transitions:**
- **PENDING → PAID**: When payment received and validated
- **PENDING → EXPIRED**: When expiration time passes
- **PENDING → CANCELLED**: When user cancels invoice
- Terminal states cannot transition further

#### Invoice SPV Flow

Complete end-to-end invoice-based payment with SPV validation:

```dart
// 1. Receiver creates invoice
invoiceCoordinator.tell(CreateInvoiceMessage(
  walletId: 'bob-wallet',
  amount: BigInt.from(100000),
  description: 'Payment for services',
));

// 2. InvoiceCoordinator requests address from WalletManager
// 3. WalletManager routes to BitcoinWalletAggregate
// 4. Aggregate emits AddressGeneratedEvent
// 5. WalletProjection updates read model
// 6. InvoiceCoordinator spawns InvoiceAggregate with address
// 7. Aggregate emits InvoiceCreatedEvent
// 8. InvoiceProjection updates invoice read model

// 9. Sender broadcasts BEEF transaction to invoice address
spvActor.tell(ReceiveTransactionMessage(
  transactionId: 'txid',
  beef: beefData,
  fromCounterparty: 'alice',
  targetWalletId: 'bob-wallet',
  invoiceId: 'invoice-123',
));

// 10. SPVActor validates BEEF merkle proof
// 11. SPVActor extracts UTXOs and verifies payment to invoice address
// 12. SPVActor notifies InvoiceCoordinator
invoiceCoordinator.tell(MarkInvoicePaidMessage(
  invoiceId: 'invoice-123',
  txid: 'transaction-hex',
  amountReceived: BigInt.from(100000),
  addressesPaidTo: ['invoice-address'],
));

// 13. InvoiceCoordinator routes to InvoiceAggregate
// 14. Aggregate validates payment and emits InvoicePaidEvent
// 15. InvoiceProjection updates invoice status to PAID
// 16. SPVActor sends ReceiveUTXOCommand to WalletManager
// 17. WalletAggregate emits UTXOReceivedEvent
// 18. WalletProjection updates UTXO read model
```

**Key Benefits:**
- **Simplified SPV**: No need to monitor entire blockchain
- **Privacy**: Single-use addresses per invoice
- **Immediate Validation**: SPV validation completes in milliseconds
- **Audit Trail**: Complete event history for invoice lifecycle
- **Separation of Concerns**: Invoice domain separate from wallet domain

## Transaction Building Strategy

### UTXO Selection Algorithm

1. **Prefer funding UTXOs** (P2PKH) for general spending
2. **Sort by value** (smallest first) to minimize fragmentation
3. **Fall back to special UTXOs** only when insufficient funding UTXOs
4. **Never spend protocol outputs** (they're unspendable)

```dart
List<BitcoinUtxo> selectUTXOs(BigInt requiredAmount) {
  var selected = <BitcoinUtxo>[];
  var totalValue = BigInt.zero;
  
  // 1. Always prefer funding UTXOs (P2PKH) first
  var fundingUtxos = state.fundingUTXOs.values
    .where((utxo) => utxo.status == UTXOStatus.confirmed)
    .toList()
    ..sort((a, b) => a.value.compareTo(b.value)); // Smallest first
  
  for (var utxo in fundingUtxos) {
    selected.add(utxo);
    totalValue += utxo.value.getValue();
    if (totalValue >= requiredAmount) break;
  }
  
  // 2. Fall back to special UTXOs only if needed
  if (totalValue < requiredAmount) {
    var specialUtxos = state.specialUTXOs.values
      .where((utxo) => utxo.status == UTXOStatus.confirmed)
      .toList()
      ..sort((a, b) => a.value.compareTo(b.value));
    
    for (var utxo in specialUtxos) {
      selected.add(utxo);
      totalValue += utxo.value.getValue();
      if (totalValue >= requiredAmount) break;
    }
  }
  
  return selected;
}
```

### Registry-Driven Transaction Building

```dart
// In BitcoinWalletAggregate._handleCreateTransaction()
var builder = TransactionBuilder();

// Add inputs using registry factories
for (var utxo in selectedUtxos) {
  var unlockBuilder = registry.createUnlockingBuilder(
    utxo.scriptType,
    {
      'publicKey': derivedPublicKey,
      'signature': 'placeholder_for_signing',
      ...utxo.scriptMetadata  // Use cached metadata
    }
  );
  
  builder.spendFromOutpointWithSigner(
    signer,
    utxo.outpoint, 
    TransactionInput.MAX_SEQ_NUMBER,
    unlockBuilder
  );
}

// Add outputs using registry factories  
var lockBuilder = registry.createBuilder('P2PKH', {'address': toAddress});
builder.spendToLockBuilder(lockBuilder, amount);

// Change output
builder.sendChangeToPKH(changeAddress);

var transaction = builder.build(true);
```

## Protocol Support Architecture

### Protocol Registration

Custom Bitcoin protocols register their templates at wallet initialization:

```dart
// At wallet startup
registry.registerScriptType(AIPTemplate());       // Author Identity Protocol
registry.registerScriptType(BMAPTemplate());      // Bitcoin Metadata Protocol  
registry.registerScriptType(HodlTemplate());      // Time-locked outputs
registry.registerScriptType(TokenTemplate());     // Custom token protocol
registry.registerScriptType(ReceiptTemplate());   // Payment receipts
```

### Protocol Output Processing

When transactions are received via SPV:

```dart
List<Event> _handleUTXOReceived(WalletState currentState, UTXOReceivedCommand command) {
  var utxo = BitcoinUtxo.fromTransactionOutput(
    command.output,
    currentState.scriptRegistry,
    currentState.addresses,
    currentState.publicKeys
  );
  
  var events = <Event>[];
  
  // Spendable UTXOs
  if (utxo.spendable) {
    events.add(UTXOReceivedEvent(
      utxo: utxo,
      category: utxo.category,
    ));
  }
  
  // Protocol data outputs (unspendable but valuable)
  if (utxo.scriptType == 'opreturn' || !utxo.spendable) {
    events.add(ProtocolOutputReceivedEvent(
      scriptType: utxo.scriptType,
      protocolType: _identifyProtocol(utxo.scriptMetadata),
      protocolData: utxo.scriptMetadata,
      outputReference: '${utxo.txid}:${utxo.vout}',
    ));
  }
  
  return events;
}
```

### Domain Projections

Protocol-specific functionality is handled by projections that listen to wallet events:

```dart
// Token/NFT tracking
class TokenProjection extends Projection {
  Map<String, TokenRecord> _ownedTokens = {};
  Map<String, TokenBalance> _tokenBalances = {};
  
  @override
  void handleEvent(Event event) {
    if (event is ProtocolOutputReceivedEvent && event.protocolType == ProtocolType.token) {
      var tokenData = TokenRecord.fromProtocolData(event.protocolData);
      _ownedTokens[tokenData.tokenId] = tokenData;
      _updateTokenBalance(tokenData);
    }
  }
  
  List<TokenRecord> getOwnedTokens() => _ownedTokens.values.toList();
  TokenBalance? getTokenBalance(String tokenId) => _tokenBalances[tokenId];
}

// Social media / identity tracking  
class IdentityProjection extends Projection {
  Map<String, IdentityProof> _identityProofs = {};
  Map<String, SocialPost> _signedContent = {};
  
  @override
  void handleEvent(Event event) {
    if (event is ProtocolOutputReceivedEvent && event.protocolType == ProtocolType.aip) {
      var aipData = AIPRecord.fromProtocolData(event.protocolData);
      _identityProofs[aipData.identityKey] = IdentityProof(aipData);
    }
  }
  
  List<IdentityProof> getIdentityProofs() => _identityProofs.values.toList();
  List<SocialPost> getSignedContent(String identityKey) => 
    _signedContent.values.where((post) => post.signerKey == identityKey).toList();
}

// Cross-protocol relationships
class SocialMediaProjection extends Projection {
  Map<String, SocialPost> _posts = {};
  Map<String, List<String>> _socialGraph = {}; // follows/followers
  
  @override
  void handleEvent(Event event) {
    if (event is ProtocolOutputReceivedEvent) {
      switch (event.protocolType) {
        case ProtocolType.aip:
          _processIdentitySignature(event);
          break;
        case ProtocolType.bmap:
          _processSocialContent(event);
          break;
      }
    }
  }
  
  List<SocialPost> getSocialFeed(String userIdentity) => /* ... */;
  SocialGraph getUserSocialGraph(String identityKey) => /* ... */;
}
```

## Event Model

### Core Wallet Events

```dart
// UTXO lifecycle
class UTXOReceivedEvent extends WalletEvent {
  final BitcoinUtxo utxo;
  final UTXOCategory category;
}

class UTXOSpentEvent extends WalletEvent {
  final String txid;
  final int vout;
  final String spentInTxid;
}

// Transaction lifecycle
class TransactionCreatedEvent extends WalletEvent {
  final String txid;
  final String rawHex;
  final dartsv.Coin totalInput;
  final dartsv.Coin totalOutput;
  final dartsv.Coin fee;
  final bool isIncoming;
  final bool isOutgoing;
}

class TransactionSignedEvent extends WalletEvent {
  final String txid;
  final String signedRawHex;
}

class TransactionBroadcastEvent extends WalletEvent {
  final String txid;
  final Map<String, dynamic> broadcastResponse;
}
```

### Protocol Events

```dart
class ProtocolOutputReceivedEvent extends WalletEvent {
  final String scriptType;
  final ProtocolType protocolType;
  final Map<String, dynamic> protocolData;
  final String outputReference;
}

enum ProtocolType {
  aip,        // Author Identity Protocol  
  bmap,       // Bitcoin Metadata Protocol
  token,      // Custom tokens/NFTs
  receipt,    // Payment receipts
  hodl,       // Time-locked outputs
  general     // Other data outputs
}
```

### SPV Actor Messages

The SPV integration uses a comprehensive set of actor messages for communication between components:

```dart
// Block header synchronization messages
class BlockHeadersReceivedMessage extends Message {
  final List<BlockHeader> headers;
  final String source;
  final String? requestId;
}

class BlockHeaderStoredMessage extends Message {
  final String blockHash;
  final int height;
  final String merkleRoot;
}

class ChainTipEventMessage extends Message {
  final ChainTip chainTip;
  final ChainTipEventType eventType;
  final String source;
}

class RequestHeaderSyncMessage extends Message {
  final int? startHeight;
  final ActorRef requestor;
}

// SPV validation messages
class ValidateTransactionMessage extends Message {
  final BitcoinTransaction transaction;
  final MerkleProof merkleProof;
}

class TransactionValidationResult extends Message {
  final bool isValid;
  final int? blockHeight;
  final String? errorMessage;
}

class ValidateBEEFMessage extends Message {
  final String beefData;
}

class BEEFValidationResult extends Message {
  final bool isValid;
  final String? merkleRoot;
  final String? errorMessage;
}

class RetrieveMerkleProofMessage extends Message {
  final String txid;
}

class MerkleProofStoredMessage extends Message {
  final String txid;
  final MerkleProof proof;
}

// SPV control messages
class GetSPVStatusMessage extends Message {}

class SPVStatusMessage extends Message {
  final int storedHeaders;
  final int currentHeight;
  final String? currentTip;
  final bool isSyncing;
}

class SPVControlMessage extends Message {
  final SPVControlAction action;
  final Map<String, dynamic>? parameters;
}

enum SPVControlAction {
  startSync,
  stopSync,
  resync,
  validateChain
}

class SPVErrorMessage extends Message {
  final String error;
  final String? context;
  final DateTime timestamp;
}

// Configuration messages
class SPVConfigMessage extends Message {
  final Map<String, dynamic> config;
}
```

## Storage Architecture

### WalletStorage Interface

```dart
abstract class WalletStorage {
  // Event store operations
  Future<void> appendEvents(String aggregateId, List<Event> events, int expectedVersion);
  Future<List<Event>> getEvents(String aggregateId, {int? fromVersion});
  
  // UTXO queries
  Future<List<BitcoinUtxo>> getUTXOs(String walletId, {UTXOCategory? category});
  Future<List<BitcoinUtxo>> getSpendableUTXOs(String walletId, {BigInt? minimumAmount});
  
  // Transaction queries  
  Future<List<BitcoinTransaction>> getTransactions(String walletId, {int? limit, String? afterTxid});
  Future<BitcoinTransaction?> getTransaction(String txid);
  
  // Transaction history operations
  Future<void> storeTransactionHistory(String walletId, TransactionHistory history);
  Future<TransactionHistory?> getTransactionHistory(String walletId, String txid);
  Future<List<TransactionHistory>> getTransactionHistories(String walletId, {int? limit});
  
  // Block header operations
  Future<void> storeBlockHeader(BlockHeader header);
  Future<BlockHeader?> getBlockHeader(String blockHash);
  Future<List<BlockHeader>> getBlockHeaders({int? fromHeight, int? toHeight});
  Future<BlockHeader?> getLatestBlockHeader();
  Future<void> removeBlockHeader(String blockHash);
  
  // Merkle proof operations
  Future<void> storeMerkleProof(String txid, MerkleProof proof);
  Future<MerkleProof?> getMerkleProof(String txid);
  Future<List<MerkleProof>> getMerkleProofs(List<String> txids);
  Future<void> removeMerkleProof(String txid);
  
  // Protocol output queries
  Future<List<ProtocolOutput>> getProtocolOutputs(String walletId, {ProtocolType? type});
  
  // Balance queries
  Future<WalletBalances> getBalances(String walletId);
}

// Enhanced data models
class TransactionHistory {
  final String walletId;
  final String txid;
  final BigInt amount;
  final String direction; // 'incoming' or 'outgoing'
  final String? fromAddress;
  final String? toAddress;
  final DateTime timestamp;
  final int? blockHeight;
  final int confirmations;
  final String? memo;
  final Map<String, dynamic>? metadata;
}

class MerkleProof {
  final String txid;
  final String blockHash;
  final List<String> merkleNodes;
  final int transactionIndex;
  final String merkleRoot;
  final bool isValid;
}

class BlockHeaderEntity {
  final String blockHash;
  final String? parentHash;
  final String merkleRoot;
  final int? height;
  final int timestamp;
  final int bits;
  final int nonce;
  final int version;
}
```

### LibSpiffy Schema Integration

For developers using Isar, LibSpiffy provides pre-built schemas:

```dart
class LibSpiffySchemas {
  /// Get all LibSpiffy Isar schemas for integration
  static List<CollectionSchema> get walletSchemas => [
    BlockHeaderEntitySchema,
    MerkleProofEntitySchema,
    WalletEventEntitySchema,
    BitcoinUtxoEntitySchema,
    BitcoinTransactionEntitySchema,
    WalletMetadataEntitySchema,
  ];
  
  /// Helper to add LibSpiffy schemas to existing Isar configuration
  static List<CollectionSchema> addToSchemas(List<CollectionSchema> existingSchemas) {
    return [...existingSchemas, ...walletSchemas];
  }
}

// Usage example:
Future<Isar> initializeIsarWithLibSpiffy() async {
  var customSchemas = [
    UserEntitySchema,
    SettingsEntitySchema,
    // ... other app-specific schemas
  ];
  
  var allSchemas = LibSpiffySchemas.addToSchemas(customSchemas);
  
  return await Isar.open(
    allSchemas,
    directory: await getApplicationDocumentsDirectory(),
  );
}
```

### Secure Storage Interface

```dart
abstract class SecureStorage {
  // HD wallet secrets
  Future<void> storeMnemonic(String walletId, String mnemonic);
  Future<String?> getMnemonic(String walletId);
  Future<void> storeRootPrivateKey(String walletId, String rootPrivateKey);
  Future<String?> getRootPrivateKey(String walletId);
  
  // Account keys
  Future<void> storeAccountPrivateKey(String accountId, String privateKey);
  Future<String?> getAccountPrivateKey(String accountId);
  
  // Identity operations
  Future<void> storeIdentityKey(String identityId, String privateKey);
  Future<String?> getIdentityKey(String identityId);
}
```

### Storage Backends

LibSpiffy supports multiple storage backends behind the `WalletStorage` and `SecureStorage` interfaces:

- **Isar** (mobile/desktop): The default backend for on-device use. Provides fast indexed queries, CBOR event serialization, and schema migration support via `LibSpiffySchemas`.
- **PostgreSQL** (server): For server-side deployments. Includes SQL migrations for schema management and encrypted key storage columns for `SecureStorage` fields (mnemonic, root private key, identity keys).
- **In-memory** (dev/test): `InMemoryWalletStorage` for unit tests and rapid prototyping. All data is ephemeral and lost on process exit.

## Service Integration

### CryptoService (DartSV Integration)

```dart
abstract class CryptoService {
  // HD wallet operations
  String generateMnemonic({int strength = 128});
  String createHDPrivateKeyFromMnemonic(String mnemonic, {String passphrase = ''});
  String derivePrivateKey(String hdPrivateKey, String derivationPath);
  String derivePublicKey(String privateKey);
  
  // Address generation
  String generateP2PKHAddress(String publicKey, {NetworkType networkType = NetworkType.MAIN});
  String generateP2PKAddress(String publicKey, {NetworkType networkType = NetworkType.MAIN});
  bool isValidAddress(String address);
  
  // Transaction operations  
  Transaction buildTransaction(List<TransactionInput> inputs, List<TransactionOutput> outputs);
  String signTransactionInput(Transaction transaction, int inputIndex, String privateKey, String prevOutputScript, BigInt satoshis);
  bool validateTransactionSignature(Transaction transaction, int inputIndex, String publicKey, String signature);
  
  // Wallet creation
  WalletKeys createBSVWallet(String hdPrivateKey, int accountIndex);
  String generateReceivingAddress(String hdPrivateKey, int accountIndex, int addressIndex);
  String generateChangeAddress(String hdPrivateKey, int accountIndex, int addressIndex);
}
```

### ARC Service Integration

```dart
abstract class ARCService {
  // Transaction broadcasting
  Future<BroadcastResponse> broadcastTransaction(String rawTx);
  Future<BroadcastResponse> broadcastBEEF(String beefHex);
  
  // Merkle proof retrieval
  Future<MerkleProof> getMerkleProof(String txid);
  Future<List<MerkleProof>> getMerkleProofs(List<String> txids);
  
  // Fee estimation
  Future<FeeQuote> getFeeQuote();
  Future<BigInt> estimateFee(int inputCount, int outputCount);
  
  // BEEF/BUMP operations
  Future<String> createBEEF(Transaction transaction, List<MerkleProof> proofs);
  Future<Transaction> parseBEEF(String beefHex);
}
```

### SpiffyNode Integration

```dart
// Integration with SpiffyNode through LibSpiffyActorSystem bridge
class LibSpiffyActorSystem {
  final ActorSystem _actorSystem;
  final WalletStorage _walletStorage;
  final BlockHeaderChain _headerChain;
  SpiffyNodeBridge? _spiffyNodeBridge;
  
  // Actor references
  ActorRef? _walletManagerActor;
  ActorRef? _spvActor;
  ActorRef? _arcActor;
  ActorRef? _headerSyncActor;
  
  // Initialize the actor system and spawn core actors
  Future<void> initialize([WalletStorage? storage]) async {
    _walletStorage = storage ?? InMemoryWalletStorage();
    _headerChain = BlockHeaderChain(storage: _walletStorage);
    
    // Spawn core actors
    _walletManagerActor = await _actorSystem.spawn(
      'wallet-manager',
      () => WalletManagerActor(_walletStorage, _actorSystem),
    );
    
    _spvActor = await _actorSystem.spawn(
      'spv-actor',
      () => SPVActor(storage: _walletStorage),
    );
    
    _arcActor = await _actorSystem.spawn(
      'arc-actor',
      () => ARCActor(),
    );
    
    _headerSyncActor = await _actorSystem.spawn(
      'header-sync-actor',
      () => HeaderSyncActor(_headerChain, _spvActor),
    );
  }
  
  // P2P integration is now handled internally during initialize()
  // SpiffyNode PeerManager is created and managed automatically when enableP2P: true
  // This internal method is called by initialize() when P2P is enabled
  Future<void> _initializeP2P({
    required String networkType,
    int? startHeight,
    List<String>? peerAddresses,
    String? userAgent,
  }) async {
    // Create PeerManager internally
    // Connect to Bitcoin P2P network
    // Initialize SpiffyNodeBridge automatically
  }
  
  // Disconnect from SpiffyNode
  Future<void> disconnectFromSpiffyNode() async {
    _spiffyNodeBridge?.disconnectFromSpiffyNode();
    _spiffyNodeBridge = null;
  }
  
  // Getters for external access
  WalletStorage get walletStorage => _walletStorage;
  BlockHeaderChain get headerChain => _headerChain;
  ActorRef? get walletManagerActor => _walletManagerActor;
  ActorRef? get spvActor => _spvActor;
  ActorRef? get arcActor => _arcActor;
  ActorRef? get headerSyncActor => _headerSyncActor;
}

// Usage example:
class BitcoinWalletService {
  final LibSpiffyActorSystem _actorSystem;
  
  BitcoinWalletService(this._actorSystem);
  
  Future<void> startWalletService() async {
    // Initialize LibSpiffy with automatic P2P connectivity
    // No need to manage SpiffyNode PeerManager - it's all internal!
    await _actorSystem.initialize(
      networkType: 'test',        // 'test' or 'main'
      enableP2P: true,            // Automatic P2P sync (default)
      // Optional: custom configuration
      // peerAddresses: ['testnet-seed.bitcoinsv.io:18333'],
      // startHeight: 50000,
    );
    
    // That's it! P2P is connected and syncing automatically
  }
  
  Future<String> createWallet(String name, Map<String, dynamic> metadata) async {
    var walletManager = _actorSystem.walletManagerActor;
    if (walletManager == null) throw StateError('Wallet manager not available');
    
    var walletId = Uuid().v4();
    walletManager.tell(CreateWalletMessage(walletId, name, metadata));
    
    return walletId;
  }
  
  Future<void> stopWalletService() async {
    await _actorSystem.disconnectFromSpiffyNode();
    await _actorSystem.shutdown();
  }
}
```

## Key Benefits

### 1. **Universal Script Support**
- Can handle any Bitcoin script type through the registry system
- Extensible for new protocols without core changes
- Cached script analysis for performance

### 2. **Clean Protocol Separation**
- Core wallet handles Bitcoin mechanics only
- Domain experts build specialized projections
- No coupling between different protocols
- Cross-protocol relationships handled in projections

### 3. **Event Sourcing Advantages**
- Complete audit trail of all wallet operations
- Time travel debugging and analysis
- Reliable state reconstruction from events
- Multiple read models via projections

### 4. **SPV Security Model**
- Block header validation through SpiffyNode
- Merkle proof verification for transaction inclusion
- Lightweight operation without full blockchain download
- ARC integration for reliable broadcasting

### 5. **Performance Optimizations**
- UTXO categorization for efficient spending
- Cached script metadata to avoid re-parsing
- Indexed storage for fast queries
- Projection-based read models for UI

## Advanced Privacy Features: Benford's Law UTXO Management

### Overview

LibSpiffy implements **Benford's Law compliance** in UTXO management as an advanced privacy feature to resist blockchain statistical analysis. This makes wallet transaction patterns appear naturally distributed, preventing clustering and behavioral analysis attacks.

### The Privacy Problem

Blockchain analysts use statistical techniques to:
- Identify wallet clustering patterns through unnatural amount distributions
- Detect artificial vs. natural transaction behaviors
- Link related transactions based on statistical anomalies
- Flag wallets that don't follow expected mathematical distributions

### Benford's Law Solution

Benford's Law states that in naturally occurring datasets, the leading digit distribution follows a logarithmic pattern:
- Digit 1 appears ~30.1% of the time
- Digit 2 appears ~17.6% of the time  
- Digit 9 appears ~4.6% of the time

```dart
class BenfordUTXOManager {
  // Benford's Law probabilities for first digits 1-9
  static const Map<int, double> BENFORD_PROBABILITIES = {
    1: 0.301,  // 30.1%
    2: 0.176,  // 17.6% 
    3: 0.125,  // 12.5%
    4: 0.097,  // 9.7%
    5: 0.079,  // 7.9%
    6: 0.067,  // 6.7%
    7: 0.058,  // 5.8%
    8: 0.051,  // 5.1%
    9: 0.046,  // 4.6%
  };
  
  /// Generate Benford-compliant UTXO amounts
  BigInt generateBenfordAmount(BigInt targetAmount, {int precision = 8}) {
    var leadingDigit = _selectBenfordDigit();
    var magnitude = _calculateMagnitude(targetAmount);
    
    // Create amount like: 1.23456789 * 10^magnitude
    var mantissa = _generateRandomMantissa(leadingDigit, precision);
    return BigInt.from((mantissa * pow(10, magnitude)).round());
  }
  
  int _selectBenfordDigit() {
    var random = Random().nextDouble();
    var cumulative = 0.0;
    
    for (var entry in BENFORD_PROBABILITIES.entries) {
      cumulative += entry.value;
      if (random <= cumulative) return entry.key;
    }
    return 1; // fallback
  }
  
  /// Split amount into multiple Benford-compliant outputs
  List<BigInt> splitIntoBenfordAmounts(
    BigInt totalAmount, {
    int maxOutputs = 3,
    BigInt? minAmount,
    ConsolidationStrategy strategy = ConsolidationStrategy.PRIVACY_FOCUSED
  }) {
    var outputs = <BigInt>[];
    var remaining = totalAmount;
    var outputCount = Random().nextInt(maxOutputs) + 1;
    
    for (var i = 0; i < outputCount - 1; i++) {
      var maxChunk = remaining ~/ BigInt.from(outputCount - i);
      var chunkAmount = generateBenfordAmount(maxChunk);
      
      if (minAmount != null && chunkAmount < minAmount) {
        chunkAmount = minAmount;
      }
      
      outputs.add(chunkAmount);
      remaining -= chunkAmount;
    }
    
    // Add remaining amount as final output
    if (remaining > BigInt.zero) {
      outputs.add(remaining);
    }
    
    return outputs;
  }
}
```

### Enhanced Transaction Building

Integration with the core transaction building strategy:

```dart
// In BitcoinWalletAggregate._handleCreateTransaction()
List<Event> _handleCreateTransaction(WalletState currentState, CreateTransactionCommand command) {
  var selectedUtxos = selectUTXOs(command.amount);
  var totalInput = selectedUtxos.fold(BigInt.zero, (sum, utxo) => sum + utxo.value.getValue());
  var requiredOutput = command.amount;
  var estimatedFee = cryptoService.estimateFee(selectedUtxos.length, 2);
  
  var changeAmount = totalInput - requiredOutput - estimatedFee;
  
  if (changeAmount > DUST_LIMIT && currentState.benfordComplianceEnabled) {
    var benfordManager = BenfordUTXOManager();
    
    // Split change into multiple Benford-compliant outputs for privacy
    var changeOutputs = benfordManager.splitIntoBenfordAmounts(
      changeAmount, 
      maxOutputs: 3,
      minAmount: DUST_LIMIT * BigInt.from(10),
      strategy: currentState.consolidationStrategy
    );
    
    // Create events for each change output
    for (var amount in changeOutputs) {
      events.add(ChangeOutputCreatedEvent(
        amount: amount,
        benfordCompliant: true,
        privacyEnhanced: true,
      ));
    }
  }
  
  return events;
}
```

### Strategic UTXO Consolidation

```dart
class BenfordConsolidationStrategy {
  /// Plan UTXO consolidation while maintaining Benford compliance
  List<UTXOConsolidationPlan> planBenfordConsolidation(List<BitcoinUtxo> utxos) {
    var plans = <UTXOConsolidationPlan>[];
    var benfordManager = BenfordUTXOManager();
    
    // Group UTXOs based on privacy-optimal consolidation
    var groups = _groupUTXOsForPrivacy(utxos);
    
    for (var group in groups) {
      var totalValue = group.fold(BigInt.zero, (sum, utxo) => sum + utxo.value.getValue());
      
      // Create Benford-compliant outputs from consolidation
      var targetOutputs = benfordManager.splitIntoBenfordAmounts(
        totalValue,
        maxOutputs: _calculateOptimalOutputCount(totalValue),
        strategy: ConsolidationStrategy.PRIVACY_FOCUSED
      );
      
      plans.add(UTXOConsolidationPlan(
        inputUTXOs: group,
        outputAmounts: targetOutputs,
        benfordScore: _calculateBenfordScore(targetOutputs),
        privacyGain: _estimatePrivacyImprovement(group, targetOutputs),
      ));
    }
    
    return plans;
  }
  
  List<List<BitcoinUtxo>> _groupUTXOsForPrivacy(List<BitcoinUtxo> utxos) {
    // Group UTXOs to maximize privacy while minimizing fees
    // Consider: amount similarity, timing patterns, script types
    var groups = <List<BitcoinUtxo>>[];
    
    // Sort by amount to identify natural groupings
    var sortedUtxos = List<BitcoinUtxo>.from(utxos)
      ..sort((a, b) => a.value.getValue().compareTo(b.value.getValue()));
    
    // Use statistical clustering to find natural consolidation groups
    var currentGroup = <BitcoinUtxo>[];
    for (var utxo in sortedUtxos) {
      if (_shouldAddToGroup(currentGroup, utxo)) {
        currentGroup.add(utxo);
      } else {
        if (currentGroup.isNotEmpty) groups.add(currentGroup);
        currentGroup = [utxo];
      }
    }
    
    if (currentGroup.isNotEmpty) groups.add(currentGroup);
    return groups;
  }
}
```

### Privacy Analysis and Scoring

```dart
class WalletPrivacyAnalyzer {
  /// Analyze wallet's Benford compliance and privacy score
  BenfordAnalysis analyzeBenfordCompliance(List<BitcoinUtxo> utxos) {
    var amounts = utxos.map((utxo) => utxo.value.getValue()).toList();
    var digitFrequencies = _calculateFirstDigitFrequencies(amounts);
    
    var benfordScore = _calculateBenfordScore(digitFrequencies);
    var suspiciousPatterns = _detectArtificialPatterns(amounts);
    var clusteringRisk = _assessClusteringRisk(amounts);
    
    return BenfordAnalysis(
      benfordScore: benfordScore,           // How close to Benford's Law (0-1)
      suspiciousPatterns: suspiciousPatterns,
      clusteringRisk: clusteringRisk,
      recommendations: _generatePrivacyRecommendations(benfordScore, clusteringRisk),
      naturalness: _categorizeNaturalness(benfordScore),
      detectionRisk: _calculateDetectionRisk(benfordScore, suspiciousPatterns),
    );
  }
  
  double _calculateBenfordScore(Map<int, double> observed) {
    var chiSquared = 0.0;
    var sampleSize = observed.values.fold(0.0, (sum, freq) => sum + freq);
    
    for (var digit = 1; digit <= 9; digit++) {
      var expected = BenfordUTXOManager.BENFORD_PROBABILITIES[digit]! * sampleSize;
      var actualCount = observed[digit] ?? 0.0;
      var diff = actualCount - expected;
      
      if (expected > 0) {
        chiSquared += (diff * diff) / expected;
      }
    }
    
    // Convert chi-squared to 0-1 score (lower chi-squared = higher score)
    // Use chi-squared critical values for significance testing
    var maxExpectedChiSquared = 15.507; // 95% confidence, 8 degrees of freedom
    return Math.max(0.0, 1.0 - (chiSquared / maxExpectedChiSquared));
  }
  
  Map<int, double> _calculateFirstDigitFrequencies(List<BigInt> amounts) {
    var frequencies = <int, int>{};
    var total = 0;
    
    for (var amount in amounts) {
      if (amount > BigInt.zero) {
        var firstDigit = int.parse(amount.toString()[0]);
        frequencies[firstDigit] = (frequencies[firstDigit] ?? 0) + 1;
        total++;
      }
    }
    
    // Convert counts to frequencies
    var result = <int, double>{};
    for (var entry in frequencies.entries) {
      result[entry.key] = entry.value / total;
    }
    
    return result;
  }
  
  List<String> _detectArtificialPatterns(List<BigInt> amounts) {
    var patterns = <String>[];
    
    // Check for round numbers (too many zeros)
    var roundNumbers = amounts.where((amount) => 
      amount.toString().endsWith('00000')).length;
    if (roundNumbers / amounts.length > 0.3) {
      patterns.add('EXCESSIVE_ROUND_NUMBERS');
    }
    
    // Check for repeated amounts
    var amountCounts = <BigInt, int>{};
    for (var amount in amounts) {
      amountCounts[amount] = (amountCounts[amount] ?? 0) + 1;
    }
    var repeatedAmounts = amountCounts.values.where((count) => count > 3).length;
    if (repeatedAmounts > amounts.length * 0.1) {
      patterns.add('EXCESSIVE_AMOUNT_REPETITION');
    }
    
    // Check for arithmetic sequences
    var sortedAmounts = List<BigInt>.from(amounts)..sort();
    var sequenceCount = 0;
    for (var i = 2; i < sortedAmounts.length; i++) {
      var diff1 = sortedAmounts[i-1] - sortedAmounts[i-2];
      var diff2 = sortedAmounts[i] - sortedAmounts[i-1];
      if (diff1 == diff2 && diff1 > BigInt.zero) {
        sequenceCount++;
      }
    }
    if (sequenceCount > amounts.length * 0.2) {
      patterns.add('ARITHMETIC_SEQUENCES');
    }
    
    return patterns;
  }
}
```

### Enhanced Wallet State

```dart
class WalletState extends eventador.State {
  // Existing fields...
  
  // Privacy analytics
  final BenfordAnalysis? benfordAnalysis;
  final double privacyScore;              // Overall privacy rating (0-1)
  final List<String> privacyRecommendations;
  final DateTime? lastPrivacyAnalysis;
  
  // Privacy settings
  final bool benfordComplianceEnabled;
  final ConsolidationStrategy consolidationStrategy;
  final PrivacyLevel defaultPrivacyLevel;
  final bool autoPrivacyOptimization;     // Auto-apply privacy recommendations
  
  // Privacy metrics tracking
  final int benfordCompliantTransactions;
  final int totalTransactions;
  final double averageDetectionRisk;
}
```

### Privacy-Enhanced Commands

```dart
class CreatePrivateTransactionCommand extends WalletCommand {
  final BigInt amount;
  final String toAddress;
  final PrivacyLevel privacyLevel;
  final bool enforceBenfordCompliance;
  final bool enableDecoyOutputs;          // Create additional privacy outputs
  final Duration? timingDelay;            // Delay to resist timing analysis
  
  CreatePrivateTransactionCommand({
    required this.amount,
    required this.toAddress,
    this.privacyLevel = PrivacyLevel.MEDIUM,
    this.enforceBenfordCompliance = true,
    this.enableDecoyOutputs = false,
    this.timingDelay,
    required String commandId,
    Map<String, dynamic>? metadata,
  }) : super(commandId: commandId, metadata: metadata);
}

enum PrivacyLevel {
  LOW,      // Basic transaction, minimal privacy
  MEDIUM,   // Benford-compliant change outputs
  HIGH,     // Multiple change outputs, timing resistance
  PARANOID  // Full Benford compliance, decoy transactions, advanced obfuscation
}

enum ConsolidationStrategy {
  COST_FOCUSED,     // Minimize fees
  PRIVACY_FOCUSED,  // Maximize privacy, higher fees acceptable
  BALANCED,         // Balance between cost and privacy
  TIME_BASED        // Consolidate based on timing patterns
}
```

### Privacy Projections

```dart
class PrivacyProjection extends Projection {
  Map<String, WalletPrivacyMetrics> _walletMetrics = {};
  Map<String, List<PrivacyEvent>> _privacyHistory = {};
  
  @override
  void handleEvent(Event event) {
    if (event is TransactionCreatedEvent) {
      _updatePrivacyMetrics(event);
      _analyzeBenfordCompliance(event);
      _trackPrivacyTrends(event);
    }
    
    if (event is UTXOReceivedEvent) {
      _analyzeUTXOPrivacy(event);
    }
    
    if (event is PrivacyOptimizationEvent) {
      _recordPrivacyImprovement(event);
    }
  }
  
  WalletPrivacyReport generatePrivacyReport(String walletId) {
    var metrics = _walletMetrics[walletId];
    var history = _privacyHistory[walletId] ?? [];
    
    return WalletPrivacyReport(
      walletId: walletId,
      benfordScore: metrics?.benfordScore ?? 0.0,
      overallPrivacyScore: metrics?.overallPrivacyScore ?? 0.0,
      detectionRisk: _calculateDetectionRisk(metrics),
      clusteringRisk: _calculateClusteringRisk(metrics),
      recommendations: _generatePrivacyRecommendations(metrics),
      privacyTrends: _analyzePrivacyTrends(history),
      nextOptimizationSuggestion: _suggestNextOptimization(metrics),
    );
  }
  
  List<String> _generatePrivacyRecommendations(WalletPrivacyMetrics? metrics) {
    if (metrics == null) return ['Enable privacy analysis'];
    
    var recommendations = <String>[];
    
    if (metrics.benfordScore < 0.7) {
      recommendations.add('Enable Benford-compliant transaction amounts');
    }
    
    if (metrics.utxoFragmentation > 0.8) {
      recommendations.add('Consider privacy-focused UTXO consolidation');
    }
    
    if (metrics.roundNumberRatio > 0.3) {
      recommendations.add('Avoid round-number transaction amounts');
    }
    
    if (metrics.timingPatternRisk > 0.6) {
      recommendations.add('Vary transaction timing to resist analysis');
    }
    
    if (metrics.addressReuseRatio > 0.1) {
      recommendations.add('Minimize address reuse for better privacy');
    }
    
    return recommendations;
  }
}

class WalletPrivacyMetrics {
  final double benfordScore;              // Benford's Law compliance (0-1)
  final double overallPrivacyScore;       // Combined privacy score (0-1)
  final double clusteringRisk;            // Risk of address clustering (0-1)
  final double timingPatternRisk;         // Timing analysis vulnerability (0-1)
  final double utxoFragmentation;         // UTXO set fragmentation (0-1)
  final double roundNumberRatio;          // Proportion of round-number amounts
  final double addressReuseRatio;         // Address reuse frequency
  final int privacyOptimizationsApplied;  // Count of privacy improvements
  final DateTime lastAnalyzed;
  
  // Benford-specific metrics
  final Map<int, double> digitFrequencies;
  final List<String> detectedPatterns;
  final double chiSquaredStatistic;
}
```

### Advanced Privacy Features

#### 1. **Decoy Transactions**
Create additional transactions that contribute to network-wide Benford compliance:

```dart
class DecoyTransactionManager {
  /// Create decoy transactions to improve network privacy
  Future<List<Transaction>> createDecoyTransactions(
    WalletState walletState,
    PrivacyLevel privacyLevel
  ) async {
    if (privacyLevel != PrivacyLevel.PARANOID) return [];
    
    var decoys = <Transaction>[];
    var benfordManager = BenfordUTXOManager();
    
    // Create small self-transactions with Benford-compliant amounts
    var availableUTXOs = walletState.fundingUTXOs.values
      .where((utxo) => utxo.value.getValue() > BigInt.from(10000))
      .toList();
    
    if (availableUTXOs.isNotEmpty) {
      var utxo = availableUTXOs.first;
      var decoyAmount = benfordManager.generateBenfordAmount(
        utxo.value.getValue() ~/ BigInt.from(10)
      );
      
      // Create self-transaction that looks natural
      var decoyTx = await _createSelfTransaction(utxo, decoyAmount);
      decoys.add(decoyTx);
    }
    
    return decoys;
  }
}
```

#### 2. **Timing Analysis Resistance**
Use Benford-based delays to make transaction timing appear natural:

```dart
class TimingPrivacyManager {
  /// Calculate privacy-optimal transaction timing
  Duration calculatePrivacyDelay(WalletPrivacyMetrics metrics) {
    if (metrics.timingPatternRisk < 0.3) {
      return Duration.zero; // Low risk, no delay needed
    }
    
    // Use Benford distribution for delay timing
    var benfordMinutes = BenfordUTXOManager().generateBenfordAmount(
      BigInt.from(60), // Up to 60 minutes
      precision: 2
    );
    
    return Duration(minutes: benfordMinutes.toInt());
  }
}
```

#### 3. **Amount Obfuscation**
Split payments into Benford-compliant chunks:

```dart
class PaymentObfuscator {
  /// Split a payment into privacy-enhanced chunks
  List<PaymentChunk> obfuscatePayment(BigInt totalAmount, PrivacyLevel level) {
    var benfordManager = BenfordUTXOManager();
    var chunks = <PaymentChunk>[];
    
    switch (level) {
      case PrivacyLevel.HIGH:
      case PrivacyLevel.PARANOID:
        // Split into 2-4 Benford-compliant payments
        var chunkAmounts = benfordManager.splitIntoBenfordAmounts(
          totalAmount,
          maxOutputs: level == PrivacyLevel.PARANOID ? 4 : 2,
        );
        
        for (var i = 0; i < chunkAmounts.length; i++) {
          chunks.add(PaymentChunk(
            amount: chunkAmounts[i],
            sequence: i,
            benfordCompliant: true,
            delay: _calculateChunkDelay(i, level),
          ));
        }
        break;
        
      default:
        chunks.add(PaymentChunk(
          amount: totalAmount,
          sequence: 0,
          benfordCompliant: false,
        ));
    }
    
    return chunks;
  }
}
```

### Integration Benefits

1. **Statistical Resistance**: Transactions appear naturally distributed, resisting clustering analysis
2. **Behavioral Obfuscation**: Wallet patterns blend with natural economic activity
3. **Advanced Privacy**: Multiple layers of protection against sophisticated analysis
4. **Adaptive Protection**: Privacy level adjusts based on threat assessment
5. **Network Effect**: Contributes to overall Bitcoin network privacy

This makes LibSpiffy not just a universal script wallet, but a **privacy-first wallet** that's resistant to the most advanced blockchain analysis techniques used by chain analysis companies.

## Architectural Benefits Summary

### Layered Architecture Benefits

The **Dactor + Eventador layered architecture** provides several key advantages:

#### 1. **Clean Separation of Concerns**
- **Dactor Actors**: Handle coordination, concurrency, and external integrations
- **Eventador Aggregates**: Contain business logic, validation, and state consistency
- **Clear Boundaries**: No mixing of coordination logic with business rules

#### 2. **Scalability & Performance**
- **Concurrent Operations**: Multiple wallets can operate simultaneously
- **Actor Message Passing**: Non-blocking, asynchronous communication
- **Event Sourcing**: Optimized for high-throughput transaction processing
- **Horizontal Scaling**: Actors can be distributed across multiple nodes

#### 3. **Reliability & Consistency**
- **Event Store**: Single source of truth for all wallet state
- **Business Rules**: Centralized validation in aggregates prevents invalid states
- **Fault Tolerance**: Actor supervision handles failures gracefully
- **Replay Capability**: Complete wallet state can be rebuilt from events

#### 4. **Testability**
- **Pure Functions**: Event appliers are deterministic and easily tested
- **Mock Actors**: External integrations can be mocked for unit testing
- **Event Replay**: Test scenarios can be created by replaying event sequences
- **Isolated Testing**: Business logic tested separately from coordination logic

#### 5. **Maintainability**
- **Single Responsibility**: Each actor has a focused, well-defined role
- **Loose Coupling**: Changes to external services don't affect business logic
- **Extension Points**: New actors can be added without modifying existing code
- **Clear Data Flow**: Command → Event → State transitions are traceable

#### 6. **External Integration Benefits**
- **SpiffyNode Integration**: HeaderSyncActor handles all blockchain monitoring complexity
- **ARC Service Integration**: ARCActor manages transaction broadcasting and status
- **Service Abstraction**: Business logic independent of external service changes
- **Error Isolation**: External service failures don't corrupt wallet state
- **Bridge Pattern**: SpiffyNodeBridge provides clean translation between systems

### Why This Architecture Works

#### **Problem Solved**: 
The original question was how to integrate Dactor actors with the existing Eventador-based system without architectural conflicts, and specifically how to properly integrate SpiffyNode's P2P capabilities with LibSpiffy's SPV validation.

#### **Solution**: 
**Layered approach** with a **bridge pattern** where actors operate as a **coordination layer above** the business logic layer:

```
SpiffyNode P2P ↔ SpiffyNodeBridge ↔ Dactor Actors ↔ Eventador Aggregates ↔ Event Store
   (Network)        (Translation)     (Coordination)    (Business Logic)     (Persistence)
```

#### **Key Architectural Insights**: 
- **HeaderSyncActor**: Dedicated to block header chain management, separate from transaction validation
- **SPVActor**: Focused purely on SPV validation using stored headers, not header synchronization
- **SpiffyNodeBridge**: Clean translation layer between SpiffyNode events and LibSpiffy actor messages
- **Separation of Concerns**: Header sync, SPV validation, and wallet management are distinct responsibilities
- **Event-Driven Integration**: All components communicate through well-defined actor messages

#### **Integration Flow**:
1. **SpiffyNode** receives `MsgHeaders` from Bitcoin P2P network
2. **LibSpiffyPeerHandler** captures headers and forwards to **SpiffyNodeBridge**
3. **SpiffyNodeBridge** translates to `BlockHeadersReceivedMessage` and sends to **HeaderSyncActor**
4. **HeaderSyncActor** validates and stores headers in **BlockHeaderChain**
5. **HeaderSyncActor** notifies **SPVActor** of new headers via `BlockHeaderStoredMessage`
6. **SPVActor** uses stored headers for BEEF/transaction validation

### Production Readiness

This architecture is **production-ready** because it provides:

1. **Fault Tolerance**: Actor supervision + event sourcing
2. **Consistency**: Event sourcing ensures data integrity
3. **Performance**: Concurrent processing with consistent state
4. **Monitoring**: Actor metrics + event tracking
5. **Debugging**: Event replay + actor message tracing
6. **Evolution**: Can add new actors or modify aggregates independently

This architecture provides a **production-ready, extensible Bitcoin wallet** that can evolve with the Bitcoin SV ecosystem while maintaining clean separation of concerns and high performance. 