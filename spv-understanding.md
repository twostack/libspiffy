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

**ARC is asked only about transactions we broadcast ourselves.** An ARC instance answers for the transactions submitted through it and no others, so it has no standing to prove a counterparty's transaction, and a `NOT_FOUND` from it means nothing about whether that transaction was mined. A transaction reaching us from a counterparty arrives with the proofs its ancestry needs, or we reject it: supplying them is the sender's obligation, not something we go and fetch. When a proof we hold later leaves the active chain, we say which output is blocked and on which ancestor — and wait for the counterparty or for the block to return. We never fill the gap from a service.

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

5. **A Counterparty Marker On Every Payment, In Both Directions**
   - Every payment the wallet records, incoming and outgoing, carries a marker
     identifying the counterparty it was with.
   - The marker is an **opaque string chosen by the app**: an Ed25519 identity
     key, an email address, a peer id, an internal account id — libspiffy does
     not interpret it and does not validate its form.
   - It is a **marker, not an identity record**. Names, contact details,
     key material, verification state and every other piece of identity
     metadata stay with the app. The wallet stores exactly enough to trace a
     payment back to whoever the app says it was with.
   - It is retained like everything else: never deleted, never overwritten
     (see Data Retention). It is what makes it possible, later, to ask the
     right counterparty for a fresh merkle proof when an ancestor's block is
     orphaned — the only recovery route there is besides the block returning.

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
- `GetDeferredPaymentsQuery`, `BroadcastDeferredPaymentCommand`, `CheckDeferredPaymentStatusCommand`, `CancelDeferredPaymentCommand`, `ReclaimDeferredPaymentCommand` (payments handed to a recipient that the network has not settled yet)

**Key Events (emitted on stream):**
- `WalletCreatedEvent`, `BalanceResponse`, `TransactionsResponse`
- `InvoiceCreatedEvent`, `PaymentReadyEvent` (BEEF ready for transmission)
- `SPVValidationResultEvent`, `TransactionReceivedEvent`, `TransactionConfirmedEvent`
- `UTXOSplitCompleteEvent`, `TimestampCompleteEvent`
- `ChannelOpenedEvent`, `ChannelPaymentEvent`, `ChannelClosedEvent`
- `DeferredPaymentsResponse`, `DeferredPaymentBroadcastEvent`, `DeferredPaymentStatusEvent`, `DeferredPaymentCancelledEvent`

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

**Deferred payments.** The payment is recorded with a deferred spend: the wallet aggregate holds its inputs (reserved by the txid, no expiry) until exactly one of: ARC (or, on an explicit check, the configured data source) reports it `SEEN_ON_NETWORK`/`MINED` and the spend applies; ARC reports it `REJECTED` and it fails, releasing the inputs; or the user cancels it. `DOUBLE_SPEND_ATTEMPTED` (a competing transaction spends an input) is not final, since either transaction may still be mined: the status is journaled and listed, the payment stays outstanding with its inputs held (a third spend of them would conflict anyway), and ARC keeps being polled until it reports ours on the network or rejected. Journals written before this rule, where `DOUBLE_SPEND_ATTEMPTED` failed the payment, replay unchanged. Reservation expiry and cleanup never release a held input, so a later payment cannot double-spend the one the recipient holds. `GetDeferredPaymentsQuery` lists them (e.g. `olderThan` to find recipients who have not broadcast); `BroadcastDeferredPaymentCommand` broadcasts one yourself; `CheckDeferredPaymentStatusCommand` asks the network now (a MINED claim confirms only with a merkle proof that matches our headers); `CancelDeferredPaymentCommand` releases the inputs of a payment the network does not know, or one ARC reports contested (`DOUBLE_SPEND_ATTEMPTED`). Cancelling does not revoke the signed transaction the recipient holds: if it still reaches miners, it spends those inputs. `ReclaimDeferredPaymentCommand` does revoke it, by broadcasting a self-spend of exactly those inputs back to the wallet; the payment resolves as `reclaimed` once the network has the self-spend, and the recipient's copy is then rejected as a double spend. The self-spend pays ARC's published policy fee and nothing else: there is no replace-by-fee here, so first seen wins and no fee changes the outcome (see Critical Implementation Note 3). If the recipient reached the network first, ours is the one rejected — an ordering fact, not a fee question. A reclaim is immediate and irreversible: libspiffy does not own the confirmation UX, so the app decides whether to warn the user first.

### Confirmation Flow

```
1. HeaderSyncActor receives new block headers from SpiffyNode
2. ARCActor periodic status check (every 30s) queries ARC for tx status
3. On confirmation → WalletManagerActor receives update
4. Aggregate emits TransactionConfirmedEvent
5. WalletProjection updates UTXOs to confirmed status
6. Coordinator emits TransactionConfirmedEvent on public stream
```

A merkle proof that verifies against the active header chain is authoritative: the transaction is mined, so it is confirmed even when it is marked failed (ARC's REJECTED can be stale, or a competing spend can lose), for example when a reorganization makes its block active again. The confirmation spends the inputs a failed or cancelled deferred payment had released; an input another transaction spent meanwhile is a double spend, logged and left as recorded.

A proof does not have to come from ARC. A counterparty spending what we paid them hands our own payment back as a proven ancestor of their new transaction, and that BUMP is how the peer-to-peer model settles it: no scanning, no polling, and better evidence than any status string. One rule covers every transaction in a received BEEF, subject and ancestor alike — a BUMP that verifies against our active header chain confirms that txid if the wallet recorded it. Confirming spends the inputs the deferred payment held, moves it to `mined`, and makes the transaction's own pending outputs available, so its change is spendable from the moment the proof arrives. The subject's own new outputs stay pending: a BEEF proves the funding history behind a transaction, never that the transaction itself is settled. The rest of the BEEF is retained whether or not the subject carries its own proof, since nothing can hand those transactions and proofs to us again; a member we cannot verify is kept unproven rather than failing the receive. Receiving an outpoint the wallet already holds is a no-op — the stored row, with its reservation and spending history, is never overwritten.

"Recorded" means either direction. A payment we *received* is a transaction the wallet recorded, and a counterparty often hands it to us before it is mined: the row is pending and its output is a pending UTXO until a proof arrives. That proof reaches us the same three ways — in the BEEF that paid us, in a re-delivery of the same transaction once it is mined, or as a proven ancestor of a later transaction that spends it — and it confirms the receipt in the write model, journaled, not only in a read-model row. Only the second half of an outgoing confirmation applies: a received transaction creates wallet outputs and spends none of our inputs, so its pending outputs become spendable and no UTXO is marked spent. A re-delivery that carries no proof never lowers the block height a proof established, and a reverted confirmation takes the record back to pending so a proof on the new chain can confirm it again.

A proof can also outrun its block header. A BUMP we cannot check yet is kept as `pendingHeader`, never discarded, and so is the BEEF that carried it: its transactions go to the ancestor store and the receive is replayed once the headers reach that height, so the counterparty never has to send it again. When the header arrives and the proof verifies, it confirms — waiting for ARC would invert the model. A header we hold that *contradicts* a proof is different, and still fatal: that proof is rejected, and the row is kept as evidence.

A confirmation must rest on at least one proof that is verified on the active header chain. When its last supporting proof leaves that chain — rejected, or orphaned by a reorganization — the confirmation is reverted, and the proof row is kept, because a later reorganization can put its block back and restore the confirmation. ARC is polled again for transactions it once reported rejected, since a proof on our chain outranks any status string; that poll is bounded in interval, window and row count, and a MINED answer still confirms only through a merkle path that matches our headers.

Nothing a counterparty hands us is thrown away, not even when we refuse it. A BEEF whose proof a header we hold contradicts still fails the receive, but its transactions and that contradicted BUMP are kept as a `rejected` row: it is the record of what we were given, and no one can hand it to us again. A receive parked until its headers arrive is kept the same way — the BEEF exactly as it reached us, replayed when the headers land and after a restart, so the counterparty never has to send it twice.

When an output cannot be walked back to a proof because an ancestor's block left the chain, the wallet says so rather than holding an unspendable output in silence: it names the ancestor and what its last proof said. A fresh proof arrives one of two ways, neither of them scanning and neither of them a question to a service: the block comes back and the kept row is restored, or the counterparty hands us a new BEEF carrying a fresh BUMP. The obligation is the counterparty's, and the wallet's job is to make the gap visible so it can be asked.

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

### Balances

Each balance API has one rule, documented where it is defined. The write model answers "what can this aggregate fund", the read side "what does the wallet show"; both leave out the same UTXOs from what they call spendable.

Three judgements are shared by every layer:

- **Plugin-managed**: the UTXO's plugin metadata names a `pluginId` (`BitcoinUtxo.isPluginManaged`). Metadata without one (the read model's script analysis of a plain output, a label) does not count. A script a registered plugin claims gets its `pluginId` on both layers even when the plugin's metadata omits it.
- **Watch-only**: a key the UTXO needs is a watch address the wallet holds no key for (`isWatchOnlyOutput`). Kept with its transaction and proof, reported apart, never spent.
- **Cannot spend alone**: a bare multisig UTXO whose threshold the wallet's own keys do not meet. The wallet no longer takes one as a UTXO, but a journal written before can hold one (a channel's 2-of-2 funding output, an escrow); it is kept, with its row, and counts in no spendable balance. Derived from the script and the wallet's keys, so no corrective event is needed.

| API | Counts | Confirmed means |
|-----|--------|-----------------|
| `WalletState.availableBalance`, `availableUtxos`, `BitcoinWalletAggregate.hasSufficientBalance` | Exactly the UTXOs the aggregate's coin selection (`selectUTXOsForAmount`) may pick, one predicate (`WalletBalances.isSpendable`): status available, not plugin-managed, not watch-only, not a multisig the wallet cannot spend alone, not an input of a deferred payment recorded before holds were journaled (inferred from the state until `ReconcileDeferredSpendsCommand` journals the hold), any confirmations. Pending, reserved, deferred-held and spent UTXOs are out. A selection of up to `availableBalance` succeeds; one satoshi more fails. | n/a |
| `WalletState.confirmedBalance` / `unconfirmedBalance` / `reservedBalance` (`WalletBalances.bucketOf`, journaled in snapshots) | Every unspent UTXO in exactly one bucket, pending, plugin-managed, watch-only and cannot-spend-alone included: everything the wallet holds. Not a spendable amount. | Unreserved with 6+ confirmations (`WalletBalances.confirmedAt`) |
| Read model wallet row (`WalletProjection`: `confirmedBalance`, `unconfirmedBalance`, `reservedBalance`, `totalBalance`, `watchOnlyBalance`) | The same buckets over unspent UTXOs, leaving out plugin-managed, watch-only and cannot-spend-alone UTXOs (`splitBalanceUtxos`); `watchOnlyBalance` is the unspent watch-only UTXOs, any status. | 6+ confirmations |
| `BalanceResponse` (`GetBalanceQuery`) | Payment UTXOs (`getPaymentUTXOs`: available, not plugin-managed) the wallet can spend alone; watch-only UTXOs reported apart in `watchOnlyBalance`. `totalBalance` equals `getBalance`. | Has a block height (mined) |
| `ReadModelStorage.getBalance` / `getWatchOnlyBalance` | Sum of the payment UTXOs the wallet can spend alone / of the watch-only payment UTXOs. | n/a |

The read side learns of a hold when it is journaled: the inputs of a deferred payment recorded before holds were journaled stay available rows until the wallet manager reconciles the wallet at spawn.

Script type is not otherwise part of any balance rule: a bare multisig or P2PK UTXO the wallet can spend alone counts everywhere, although the paths that sign every input as P2PKH (channel funding, the payment coordinator) do not select it.

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

### 3. This Is BSV: No Replace-By-Fee, First Seen Wins

LibSpiffy targets **Bitcoin SV**, and several habits carried over from BTC and
Ethereum are simply wrong here:

- ❌ There is **no replace-by-fee**. A transaction cannot be displaced from the
  mempool by a later conflicting one paying a higher fee.
- ❌ There is therefore **no fee auction and no front-running**. Paying more does
  not buy priority over a conflicting spend that miners already hold.
- ✅ **First seen wins.** Of two transactions spending the same input, the one
  that reached the network first is the one that gets mined; the later one is
  rejected as a double spend, whatever fee it carries.

The consequence for design: where two spends of the same input compete, the
question is only *which was broadcast first*, never *which pays more*. Do not
add fee bumping, fee escalation, priority fees, or "win the race" logic — a
standard policy fee is correct in every case, including a reclaim or any other
deliberate double spend of our own held inputs. Fees are for getting a
transaction accepted at all, not for outbidding anyone.

If a design of yours turns on outpacing a competing transaction by fee, stop:
that is a BTC model, and it does not describe this network.

### 4. Full Transaction History Required

Unlike traditional SPV descriptions, LibSpiffy needs complete history:
- Store every transaction ever processed
- Maintain merkle proofs for all transactions
- Enable spending from any historical UTXO
- Support wallet restoration from transaction history

### 5. Offline Capability

As noted in the BSV Wiki:
> "By storing Transaction₀ locally, a user will be able to sign Transaction₁ offline"

LibSpiffy must enable:
- Offline transaction creation
- Offline transaction signing  
- Online transaction validation and broadcasting

This document captures the SPV model and how it maps to LibSpiffy's current actor architecture, plugin system, and CQRS/event-sourced storage layer.