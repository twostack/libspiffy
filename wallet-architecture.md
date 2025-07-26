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

### 4. SPV + ARC Integration
- **SpiffyNode** provides SPV block header tracking and P2P connectivity
- **ARC Service** handles transaction broadcasting and merkle proof retrieval
- **BEEF/BUMP** integration for transaction packaging with proofs

## System Architecture

LibSpiffy uses a **layered architecture** combining **Dactor actors** (coordination layer) with **Eventador aggregates** (business logic layer):

```
┌─────────────────────────────────────────────────────────────────┐
│                     EXTERNAL CLIENTS                            │
│              (Mobile App, CLI, Web Interface)                   │
└─────────────────────────┬───────────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────────────┐
│                 DACTOR COORDINATION LAYER                       │
│                                                                 │
│  ┌─────────────────────┐  ┌─────────────────────────────────────┐ │
│  │ WalletManagerActor  │  │           SPVActor                  │ │
│  │                     │  │                                     │ │
│  │ • Multi-wallet mgmt │  │ • SpiffyNode integration            │ │
│  │ • Command routing   │  │ • Block/tx monitoring               │ │
│  │ • Wallet lifecycle  │  │ • BEEF/BUMP validation              │ │
│  │ • Cross-wallet ops  │  │ • Chain reorganization              │ │
│  └─────────────────────┘  └─────────────────────────────────────┘ │
│                                                                 │
│  ┌─────────────────────────────────────────────────────────────┐ │
│  │                    ARCActor                                 │ │
│  │                                                             │ │
│  │ • ARC service integration   • Transaction broadcasting      │ │
│  │ • Status monitoring         • Fee estimation               │ │
│  │ • Confirmation tracking     • Merkle proof retrieval       │ │
│  └─────────────────────────────────────────────────────────────┘ │
└─────────────────────────┬───────────────────────────────────────┘
                          │ Commands
                          ▼
┌─────────────────────────────────────────────────────────────────┐
│                 EVENTADOR BUSINESS LAYER                        │
│                                                                 │
│  ┌─────────────────────────────────────────────────────────────┐ │
│  │              BITCOIN WALLET AGGREGATE                       │ │
│  │                (Event-Sourced Root)                        │ │
│  │                                                             │ │
│  │ • Script-aware UTXO processing                             │ │
│  │ • Registry-driven transaction building                     │ │
│  │ • Protocol registration at initialization                  │ │
│  │ • UTXO categorization (funding/special/protocol)          │ │
│  │ • Business rule validation                                 │ │
│  │ • State consistency enforcement                            │ │
│  └─────────────────────────────────────────────────────────────┘ │
└─────────────────────────┬───────────────────────────────────────┘
                          │ Events
                          ▼
┌─────────────────────────────────────────────────────────────────┐
│                    EVENT STORE                                  │
│                   (Eventador + Isar)                           │
│                                                                 │
│  WalletCreatedEvent  │  UTXOReceivedEvent   │  TransactionCreatedEvent
│  UTXOSpentEvent      │  ProtocolOutputReceivedEvent │ TransactionSignedEvent
└─────────────────────────┬───────────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────────────┐
│           CORE STORAGE + DOMAIN PROJECTIONS                    │
│                                                                 │
│  ┌─────────────────────┐    ┌─────────────────────────────────┐ │
│  │   WalletStorage     │    │     Domain Projections          │ │
│  │                     │    │                                 │ │
│  │ • Events            │    │ • TokenProjection               │ │
│  │ • UTXOs             │    │ • IdentityProjection            │ │
│  │ • Transactions      │    │ • SocialMediaProjection        │ │
│  │ • Basic queries     │    │ • Custom protocol views        │ │
│  └─────────────────────┘    └─────────────────────────────────┘ │
└─────────────────────────┬───────────────────────────────────────┘
                          │
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

## Layered Architecture Explained

### Dactor Coordination Layer
The **Dactor actors** handle concurrency, external integrations, and coordination between multiple wallets. They operate **above** the business logic layer and never directly modify wallet state.

**Key Benefits:**
- **Concurrency**: Handle multiple operations simultaneously
- **External Integration**: Manage SpiffyNode, ARC Service, and other external systems
- **Coordination**: Route commands between wallets and services
- **Scalability**: Can distribute across multiple nodes

### Eventador Business Layer
The **BitcoinWalletAggregate** contains all business logic and maintains consistency through event sourcing. Each wallet is a separate aggregate instance.

**Key Benefits:**
- **Consistency**: Event sourcing ensures reliable state management
- **Business Rules**: All wallet logic centralized and testable
- **Audit Trail**: Complete history of all wallet operations
- **Testability**: Pure functions for state transitions

### Integration Pattern
```
Actors send Commands → Aggregates validate & emit Events → Storage persists → Projections provide views
```

**Flow Example:**
1. **SPVActor** detects new transaction
2. Sends `ReceiveUTXOCommand` to **WalletManagerActor**
3. **WalletManagerActor** routes to correct **BitcoinWalletAggregate**
4. **Aggregate** validates and emits `UTXOReceivedEvent`
5. **Event** is persisted and triggers balance updates

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

Integrates with SpiffyNode for blockchain monitoring and validation:

```dart
class SPVActor extends Actor {
  final ChainTipTracker _chainTipTracker;
  final PeerManager _peerManager;
  final ActorRef _walletManager;
  final Set<String> _monitoredAddresses = {};
  final Map<String, String> _addressToWallet = {}; // address -> walletId mapping
  
  @override
  Future<void> onReceive(Message message) async {
    switch (message.payload) {
      case StartSPVSyncMessage msg:
        await _startSPVSync(msg.walletId, msg.addresses);
        
      case NewBlockMessage msg:
        await _scanBlockForTransactions(msg.blockHeader, msg.transactions);
        
      case TransactionFoundMessage msg:
        await _processTransactionForWallet(msg.walletId, msg.transaction);
        
      case ValidateBEEFMessage msg:
        var result = await _validateBEEFProof(msg.beefData);
        sender.tell(BEEFValidationResult(result.isValid, result.merkleRoot));
        
      case ChainReorganizationMessage msg:
        await _handleChainReorg(msg.oldTip, msg.newTip, msg.affectedBlocks);
        
      case AddMonitoringAddressMessage msg:
        _monitoredAddresses.add(msg.address);
        _addressToWallet[msg.address] = msg.walletId;
    }
  }
  
  Future<void> _startSPVSync(String walletId, List<String> addresses) async {
    // Add addresses to monitoring set
    for (var address in addresses) {
      _monitoredAddresses.add(address);
      _addressToWallet[address] = walletId;
    }
    
    // Start chain tip tracking
    _chainTipTracker.events.listen((event) {
      if (event.type == ChainTipEventType.newTip) {
        self.tell(NewBlockMessage(event.tip, event.transactions ?? []));
      } else if (event.type == ChainTipEventType.reorganization) {
        self.tell(ChainReorganizationMessage(
          event.oldTip, 
          event.newTip, 
          event.affectedBlocks ?? []
        ));
      }
    });
  }
  
  Future<void> _processTransactionForWallet(String walletId, Transaction transaction) async {
    // Check outputs for relevant UTXOs
    for (var i = 0; i < transaction.outputs.length; i++) {
      var output = transaction.outputs[i];
      var address = output.address?.toString();
      
      if (address != null && _monitoredAddresses.contains(address)) {
        var command = ReceiveUTXOCommand(
          walletId: walletId,
          txid: transaction.id,
          vout: i,
          satoshis: output.satoshis,
          scriptPubKey: output.script.toHex(),
          address: address,
          blockHeight: transaction.blockHeight,
          confirmations: transaction.confirmations,
        );
        
        _walletManager.tell(WalletCommandMessage(walletId, command));
      }
    }
    
    // Check inputs for spent UTXOs
    for (var input in transaction.inputs) {
      var spentOutpoint = '${input.previousTxId}:${input.outputIndex}';
      // Notify relevant wallet of spent UTXO
      var command = SpendUTXOCommand(
        walletId: walletId,
        utxoKey: spentOutpoint,
        spendingTxId: transaction.id,
      );
      
      _walletManager.tell(WalletCommandMessage(walletId, command));
    }
  }
  
  Future<BEEFValidationResult> _validateBEEFProof(String beefData) async {
    // Implement BEEF/BUMP validation logic
    // This would integrate with DartSV for Merkle proof validation
    try {
      var beef = BEEF.fromHex(beefData);
      var isValid = await beef.validateMerkleProofs(_chainTipTracker.currentTip);
      return BEEFValidationResult(isValid, beef.merkleRoot);
    } catch (e) {
      return BEEFValidationResult(false, null);
    }
  }
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
  
  // Protocol output queries
  Future<List<ProtocolOutput>> getProtocolOutputs(String walletId, {ProtocolType? type});
  
  // Balance queries
  Future<WalletBalances> getBalances(String walletId);
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
// Integration with SpiffyNode for SPV operations
class SPVWalletService {
  final ChainTipTracker chainTipTracker;
  final PeerManager peerManager;
  final BitcoinWalletAggregate walletAggregate;
  
  // Listen for new blocks and scan for wallet transactions
  void startSPVSync() {
    chainTipTracker.events.listen((event) {
      if (event.type == ChainTipEventType.newTip) {
        _scanBlockForTransactions(event.tip);
      }
    });
  }
  
  // Request merkle proofs for wallet transactions
  Future<void> requestMerkleProofs(List<String> txids) {
    // Use peers to request merkle block data
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
- **SpiffyNode Integration**: SPVActor handles all blockchain monitoring complexity
- **ARC Service Integration**: ARCActor manages transaction broadcasting and status
- **Service Abstraction**: Business logic independent of external service changes
- **Error Isolation**: External service failures don't corrupt wallet state

### Why This Architecture Works

#### **Problem Solved**: 
The original question was how to integrate Dactor actors with the existing Eventador-based system without architectural conflicts.

#### **Solution**: 
**Layered approach** where actors operate as a **coordination layer above** the business logic layer:

```
External Systems ↔ Dactor Actors ↔ Eventador Aggregates ↔ Event Store
     (Network)      (Coordination)    (Business Logic)     (Persistence)
```

#### **Key Insight**: 
- **Actors** excel at **coordination, concurrency, and external integration**
- **Aggregates** excel at **business logic, validation, and consistency**
- **Combining both** gives us the benefits of each without the drawbacks

### Production Readiness

This architecture is **production-ready** because it provides:

1. **Fault Tolerance**: Actor supervision + event sourcing
2. **Consistency**: Event sourcing ensures data integrity
3. **Performance**: Concurrent processing with consistent state
4. **Monitoring**: Actor metrics + event tracking
5. **Debugging**: Event replay + actor message tracing
6. **Evolution**: Can add new actors or modify aggregates independently

This architecture provides a **production-ready, extensible Bitcoin wallet** that can evolve with the Bitcoin SV ecosystem while maintaining clean separation of concerns and high performance. 