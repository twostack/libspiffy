# SPV Understanding - LibSpiffy Implementation Guide

## Overview

This document outlines the correct understanding of **Simplified Payment Verification (SPV)** as described in Section 8 of the Bitcoin whitepaper and specifically how it applies to Bitcoin SV.

## Fundamental SPV Concepts

### What SPV Actually Is

SPV allows transaction recipients to **prove that the sender has control of source funds** without downloading the entire blockchain, by utilizing Merkle proofs. It does **NOT** guarantee funds haven't been previously spent - that assurance comes from submitting the transaction to Bitcoin miners.

### Key Data Requirements

Based on the [BSV Wiki on SPV](https://wiki.bitcoinsv.io/index.php/Simplified_Payment_Verification):

- **Block Headers Only**: ~50MB covers entire blockchain (80 bytes × ~620,000 blocks as of 2020)
- **Linear Growth**: ~4MB per year (80 bytes per block regardless of block size)
- **Merkle Paths**: Maximum 64×log₂(n) bytes where n = transactions in block
- **No Full Blocks**: Never need to download or store complete blocks

## The Real SPV Transaction Flow

### 1. Peer-to-Peer Transaction Negotiation

**Key Insight**: Transactions are **negotiated peer-to-peer** and **settled on the ledger** through network nodes.

**Analogy**: Like receiving a cheque - the customer hands you the signed cheque (transaction), you then bank/cash it (settle on-chain).

### 2. What the Receiver Gets

When receiving a transaction, the sender provides:

1. **Transaction₀** - the transaction containing the UTXO as output
2. **Merkle Path** of Transaction₀  
3. **Block Header** containing the Merkle root (or block identifier)
4. **Transaction₁** - the new transaction spending the UTXO

### 3. SPV Validation Process

The receiver validates by:

1. **Computing Merkle Root** from the Merkle path of Transaction₀
2. **Comparing** with Merkle root in the block header
3. **If match**: Accept that Transaction₀ is in the chain
4. **Validate** Transaction₁ can legitimately spend from Transaction₀

### 4. Broadcasting & Settlement

- **Primary**: Broadcast via **ARC Service**
- **Backup**: SpiffyNode for transaction broadcast  
- **Monitor**: Poll ARC for transaction lifecycle (pending → confirmed)
- **Proof Retrieval**: Get merkle proof from ARC once transaction is mined

## LibSpiffy Implementation Requirements

### Core Data Management

LibSpiffy must maintain:

1. **Full Transaction History**
   - All transactions ever received/sent by the wallet
   - Complete transaction data (not just references)
   - Transaction metadata and status

2. **Complete UTXO Management**  
   - Track all UTXOs (available, reserved, spent)
   - UTXO genealogy and spending history
   - Confirmation status and block heights

3. **Merkle Proof Storage**
   - **Every UTXO must have its merkle proof**
   - Proofs for both incoming and outgoing UTXOs
   - Proof validation against block header chain

4. **Block Header Chain**
   - Full chain of block headers (~50MB)
   - Kept in sync via SpiffyNode integration
   - Used for merkle proof validation

## Current Architecture (Implemented)

### Public API: WalletCoordinatorActor

All third-party interaction flows through a single unified facade — **WalletCoordinatorActor**. Applications send commands via `coordinator.tell(command)` and receive results on `coordinator.events` (a broadcast stream of `CoordinatorEvent`).

**Key Commands:**
- `CreateWalletCommand`, `ImportWalletCommand`
- `GetBalanceQuery`, `GetTransactionsQuery`, `GetTransactionDetailQuery`
- `CreateInvoiceCommand`, `PayInvoiceCommand`
- `ReceiveTransactionCommand` (BEEF from counterparty)
- `ValidateBEEFCommand`, `RecordOutgoingCommand`
- `StoreHeadersCommand`, `SplitUTXOsCommand`, `TimestampCommand`
- `OpenChannelCommand`, `ChannelPayCommand`, `CloseChannelCommand`

**Key Events (emitted on stream):**
- `WalletCreatedEvent`, `BalanceResponse`, `TransactionsResponse`
- `InvoiceCreatedEvent`, `PaymentReadyEvent` (BEEF ready for transmission)
- `SPVValidationResultEvent`, `TransactionReceivedEvent`, `TransactionConfirmedEvent`
- `UTXOSplitCompleteEvent`, `TimestampCompleteEvent`
- `ChannelOpenedEvent`, `ChannelPaymentEvent`, `ChannelClosedEvent`

### Actor Responsibilities

| Actor | Responsibility |
|-------|---------------|
| **WalletCoordinatorActor** | Public API facade; command dispatch; event emission; correlation tracking |
| **WalletManagerActor** | Multi-wallet routing; spawns BitcoinWalletAggregate per wallet |
| **SPVActor** | BEEF/BUMP validation; merkle proof validation against block headers |
| **ARCActor** | ARC service integration; transaction broadcast; fee estimation; status polling |
| **HeaderSyncActor** | Block header synchronization via SpiffyNode P2P |
| **PaymentCoordinatorActor** | UTXO selection; BEEF construction; does **NOT** broadcast |
| **InvoiceCoordinatorActor** | Invoice lifecycle; spawns InvoiceAggregate per invoice |
| **BenfordCoordinatorActor** | UTXO splitting with Benford's Law distribution |
| **PaymentChannelManagerActor** | Payment channel operations (fund, pay, close) |
| **ImportActor** | Wallet import from blockchain data sources |
| **TransactionLifecycleCoordinatorActor** | Transaction lifecycle tracking |

**What SPVActor does NOT do (corrected from earlier assumptions):**
- ~~Address monitoring~~ — Transactions come directly from counterparties
- ~~Block scanning~~ — We don't scan blocks for transactions
- ~~Transaction discovery~~ — Transactions are handed to us
- ~~Block header sync~~ — That's HeaderSyncActor's job
- ~~Transaction broadcasting~~ — That's ARCActor's job

### Transaction Receipt Flow

```
1. App sends ReceiveTransactionCommand (BEEF) → WalletCoordinatorActor
2. Coordinator parses BEEF, extracts txid
3. Coordinator sends ReceiveTransactionMessage → SPVActor
4. SPVActor validates BEEF structure + merkle proofs against block headers
5. If valid → SPVActor sends ReceiveUTXOCommand → WalletManagerActor
6. WalletManagerActor routes to BitcoinWalletAggregate
7. Aggregate emits UTXOReceivedEvent (event sourced)
8. WalletProjection updates read model
9. Coordinator emits TransactionReceivedEvent on public stream
```

### Payment Flow (Outgoing)

```
1. App sends PayInvoiceCommand → WalletCoordinatorActor
2. Coordinator routes to PaymentCoordinatorActor
3. PaymentCoordinator selects UTXOs, collects ancestor proofs, builds BEEF
4. PaymentCoordinator returns BEEFPaymentResponse → Coordinator
5. Coordinator emits PaymentReadyEvent (contains BEEF bytes)
6. App transmits BEEF to counterparty (pure SPV peer-to-peer model)
7. Optionally: App calls RecordOutgoingCommand to record in wallet
8. Optionally: App triggers ARC broadcast for on-chain settlement
```

**Key insight**: PaymentCoordinatorActor builds the BEEF but does **not** auto-broadcast. The app decides whether to transmit peer-to-peer, broadcast via ARC, or both.

### Confirmation Flow

```
1. HeaderSyncActor receives new block headers from SpiffyNode
2. ARCActor periodic status check (every 30s) queries ARC for tx status
3. On confirmation → WalletManagerActor receives update
4. Aggregate emits TransactionConfirmedEvent
5. WalletProjection updates UTXOs to confirmed status
6. Coordinator emits TransactionConfirmedEvent on public stream
```

## Data Models (Current Implementation)

### BitcoinUtxo

```dart
class BitcoinUtxo {
  final String txid;
  final int vout;
  final Coin value;                       // DartSV's Coin type
  final String scriptPubKey;
  final String address;
  final UTXOStatus status;                // pending, available, reserved, spent
  final int? blockHeight;
  final int? confirmations;
  final DateTime createdAt, updatedAt;
  final String? reservedByTxId;
  final DateTime? reservationExpiresAt;
  final int? reservationPriority;
  final String? reservationReason;
  final int? derivationIndex;
  final Map<String, dynamic>? pluginMetadata;  // Plugin-specific data
}

enum UTXOStatus { pending, available, reserved, spent }
```

### BitcoinTransaction

```dart
class BitcoinTransaction {
  final String? walletId;
  final String txid;
  final String rawHex;
  final TransactionStatus status;        // created, signed, broadcast, pending, confirmed, failed
  final int? blockHeight;
  final int? confirmations;
  final BigInt inputValue, outputValue, fee;
  final List<String> receivingAddresses, sendingAddresses;
  final BigInt netAmount;
  final DateTime createdAt;
}

enum TransactionStatus { created, signed, broadcast, pending, confirmed, failed }
```

### Storage Architecture (CQRS + Event Sourcing)

LibSpiffy uses **event sourcing** for the write model and **CQRS** for read/write separation:

- **Write Side**: `BitcoinWalletAggregate` applies commands, emits domain events (`UTXOReceivedEvent`, `UTXOSpentEvent`, `TransactionConfirmedEvent`, etc.) persisted to an append-only `EventStore`
- **Read Side**: `WalletProjection` listens to domain events, updates `ReadModelStorage` (denormalized `WalletReadModel` with balances, UTXO counts, etc.)
- **Block Headers**: Stored via `ReadModelStorage.storeBlockHeader()` / `getBlockHeader()`
- **Secure Storage**: `SecureStorage` interface for xpriv/WIF/mnemonic (never exposed to plugins)

**Storage backends**: Isar (mobile/local), PostgreSQL (server), In-Memory (testing).

## Plugin System

LibSpiffy supports external token and script protocols through a plugin architecture:

### ScriptPlugin (Interface)

Allows external libraries to teach LibSpiffy about custom script types:

```dart
abstract class ScriptPlugin {
  String get pluginId;                    // 'tstoken', 'ordinals', etc.
  String get displayName;
  List<String> get scriptTypes;
  String? identifyScript(SVScript script);
  Map<String, dynamic>? extractMetadata(SVScript script);
  LockingScriptBuilder? createLockBuilder(PluginOutputSpec spec);
  UnlockingScriptBuilder? createUnlockBuilder(PluginUnlockSpec spec);
}
```

### TransactionBuilderPlugin (Extended)

For multi-output transaction protocols (e.g., token issuance with 5-output structure):

```dart
abstract class TransactionBuilderPlugin extends ScriptPlugin {
  Future<Transaction> buildTransaction(PluginTransactionRequest request);
  List<String> get supportedActions;  // 'issuance', 'transfer', 'burn', 'witness'
  bool validateTransactionStructure(Transaction tx, String action);
}
```

### Secure Signing via CallbackTransactionSigner

Plugins **never** access private keys directly. Instead, they receive a `CallbackTransactionSigner` that signs on their behalf:

```dart
class CallbackTransactionSigner extends TransactionSigner {
  final SigningCallback _onSign;  // (sighash, inputIndex) → signature bytes
  Transaction sign(Transaction unsignedTxn, TransactionOutput utxo, int inputIndex);
}
```

### PluginRegistry

Singleton registry where plugins register themselves. The coordinator and payment actors consult the registry to handle custom script types in invoices and transactions:

```dart
PluginRegistry.instance.register(myTokenPlugin);
```

Plugins participate in the payment flow via `PluginOutputSpec` in invoices and `PluginTransactionRequest` for UTXO funding and signing.

## Critical Implementation Notes

### 1. Every UTXO Needs Its Proof

This is **non-negotiable** for SPV wallets:
- Cannot spend UTXOs without proving their existence
- Must validate the entire chain of UTXOs back to coinbase
- Proofs must be stored permanently with each UTXO

### 2. No Address Monitoring

The fundamental paradigm shift:
- ❌ Don't monitor addresses on the network
- ❌ Don't scan blocks for transactions  
- ✅ Receive transactions directly from counterparties
- ✅ Validate received transactions using proofs

### 3. Full Transaction History Required

Unlike traditional SPV descriptions, LibSpiffy needs complete history:
- Store every transaction ever processed
- Maintain merkle proofs for all transactions
- Enable spending from any historical UTXO
- Support wallet restoration from transaction history

### 4. Offline Capability

As noted in the BSV Wiki:
> "By storing Transaction₀ locally, a user will be able to sign Transaction₁ offline"

LibSpiffy must enable:
- Offline transaction creation
- Offline transaction signing  
- Online transaction validation and broadcasting

This document captures the SPV model and how it maps to LibSpiffy's current actor architecture, plugin system, and CQRS/event-sourced storage layer.