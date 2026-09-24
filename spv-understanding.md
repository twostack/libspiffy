# SPV Understanding - LibSpiffy Implementation Guide

## Overview

This document outlines the correct understanding of **Simplified Payment Verification (SPV)** as described in Section 8 of the Bitcoin whitepaper and specifically how it applies to Bitcoin SV.

### What this library is for

**libspiffy honestly records the state of UTXOs and transactions. That is the
whole job.** It keeps what it was told, it keeps the evidence, it reports what
the evidence supports, and it says "I do not know" rather than guessing.

Policy belongs to the application. How deep a block must be before the user
treats money as theirs, whether to warn someone before an irreversible action,
which counterparties to trust, what an identity means — all of that is the
app's to decide, and the library neither imposes it nor pretends to know it.

The corollary is the more useful half: **the library must not manufacture
state it cannot evidence.** It does not derive confirmation from a count, a
status string, a height a caller supplied, or the passage of time. It does not
fetch a proof from a party with no standing to give one. It does not invent a
fee, or a counterparty identity, or a confirmation depth. Where evidence is
missing the honest record is an absence — a null height, an output still
pending, a payment still outstanding — and an absence the app can see is worth
more than a plausible value it cannot check.

Most of the specific rules below are this principle applied to one place. If a
rule here ever seems arbitrary, check whether it is really this.

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

The exchange between two peers:

1. **The payer asks the payee — or the payee's agent — for an address**, usually by requesting an invoice (`CreateInvoiceCommand` on the payee's side).
2. **The payer builds the payment for that invoice**, paying the address from (1) (`PayInvoiceCommand`).
3. **The payer hands the payment to the payee**, usually as BEEF. The payer does not broadcast it.
4. **The payee broadcasts it** (`ValidateBEEFCommand`). It is the payee's payment now, like a cheque the payee deposits at their bank.
5. **The payer still has a stake in it.** The payer needs to know when the UTXOs it spent are spent on chain. Only then does its hold on those inputs end, and only once the transaction is mined can it get merkle proofs for the change outputs it put in the payment in (3).
6. **So both the payer and the payee follow how ARC settles that payment.** Each of them asks about one transaction it is a party to, and asks while that payment is active.

### Payment modes

All three modes follow the exchange above. They differ in who answers step (1), who broadcasts the payment, and who receives it:

- **Both parties online.** The payee answers the invoice request itself with a plain address from its own wallet. It checks the BEEF it receives and broadcasts it, and both parties follow the payment in ARC to its block.
- **A service acting for an offline payee.** A payee registers its xpub with a service that takes payments for its users. The service keeps that xpub as a watch-only wallet. It answers the invoice request with an address derived from the payee's xpub, then receives the BEEF, checks it and broadcasts it for the payee. It tells the payee about the payment out of band. The payee's own wallet takes the payment only once it is proven, with `ImportTransactionCommand`.
- **A payer paying an offline payee directly (type-42).** The payee publishes a public key, its anchor key A, bound to its identity. Nobody answers step (1): the payer derives the address itself from A with BRC-42 ("type-42") key derivation. The payee is not there to take the payment, so step (4) falls to the payer: it broadcasts its own payment and follows it to its block. It then hands the payment over, proven, with what the payee needs to find it. No service and no xpub are involved, and the payee's other addresses stay private.

How the second mode works in libspiffy:

1. **The two issuers use separate chains.** An address is on one of three chains of the wallet's HD tree (`AddressChain`, with key path `m/{chain}/{index}`): receive (`m/0/i`), change (`m/1/i`) and delegated (`m/2/i`). The payee's own wallet issues receive addresses. An xpub wallet, which has no private key, issues every address on the delegated chain. Each keeps its own counter and never sees the other's, so on one chain they would hand out the same address.
2. **The service's money is watch-only.** An xpub wallet holds no key, so everything it receives is reported as `watchOnlyBalance` and is never spendable.
3. **An invoice names its mode.** `InvoiceCreatedEvent.issuedAddresses` gives each address with its chain and derivation index: receive for a wallet that holds its keys, delegated for a service's xpub wallet.
4. **The service follows the payment to its block** like any payee, then exports it with its proof: `ExportTransactionQuery` answers with a `TransactionExportedEvent` carrying the BEEF and the delegated indices of the addresses it pays. It refuses while the transaction has no proof verified on our header chain.
5. **The hand-off is the BEEF and those delegated indices.** The payee's wallet imports it with `ImportTransactionCommand(delegatedIndices: [...])`. It derives each address from its own key, and never takes the address it is handed, records them (they do not move its own counter), and then imports the payment. From then on it signs for them like any other address.
6. **A restored wallet finds them too.** Address discovery scans all three chains.

How the third mode works in libspiffy (bead libspiffy-zxkd):

1. **The payee's anchor keys, one per context.** A wallet that holds its keys issues an anchor key for an opaque *anchor context* (bead libspiffy-fdal), at `m/3'/0'/k1'/k2'`, where k1 and k2 are the first two 31-bit halves of `SHA-256("libspiffy/type42-anchor" ‖ context)`. One anchor per wallet would be a fingerprint: two identities sharing a wallet would publish the same A, and anyone holding both records would know they are one person. With one per context, identities sharing a wallet publish unrelated anchors. The anchors are off the three address chains, on hardened paths, and never appear in a locking script. `IssueAnchorKeyCommand(anchorContext)` answers A for the app to publish, and journals it the first time. `SignWithAnchorKeyCommand` signs SHA-256 of a message with it, to bind A to an identity (NodeCast's registration, for example). An empty context is refused rather than given a default anchor. An xpub wallet has no private key and so no anchor key. A WIF wallet has no HD tree to put one on. Both refuse.
   - **Rotation.** The payer knows t, so a leaked child key c = a + t gives away that anchor's a. An app that puts an epoch in the context (overnode uses `identityKey ‖ epoch`) retires an anchor by bumping the epoch and publishing the new anchor with its epoch. The new anchor is unrelated to the old one, and the old one stays derivable for the payments made to it.
2. **The payer derives the destination.** `DeriveType42DestinationCommand(anchorPublicKey: A, anchorContext: ...)` takes the wallet's next payer key b at `m/3'/1'/n'`, which is never used twice, and an invoice number. The context is the one the payee published with A; the payer passes it through into the hand-off unchecked. Without an invoice number it makes up a BRC-29 one: `2-3241645161d8-<prefix> <suffix>`. It answers with the destination C = A + t·G, where t = HMAC-SHA256(ECDH(b, A), invoice number), and the hand-off (B and the invoice number). It journals that destination (`Type42DestinationDerivedEvent`), so the payer key is not reused after a restart and the hand-off can be given again.
3. **The payer pays and broadcasts.** It pays C with `PayInvoiceCommand` and broadcasts the payment with `BroadcastDeferredPaymentCommand`. Having broadcast it, it follows it in ARC to its block, as for any payment it is a party to.
4. **The payer exports it.** `ExportTransactionQuery` answers with the proven BEEF and `type42Derivations`, the hand-off for each type-42 destination the transaction pays: {A, context, B, invoice number}. The hand-off is delivered out of band.
5. **The payee takes it in.** `ImportTransactionCommand(type42Derivations: [...])` imports it once it is proven. `ValidateBEEFCommand(type42Derivations: [...])` takes it in unproven if the payee is online before it is mined, and submitting it again to ARC is harmless. The wallet first finds the anchor's context: among the anchors it issued, else the context in the hand-off, which must derive A — a context that gives another anchor is refused, as is an anchor the wallet never issued with no context to derive it from. An anchor is never taken on trust, just as an address is not. Then it derives C from its own anchor private key and never takes an address it is handed. With a wrong payer key or invoice number it derives an address the transaction does not pay, and the payment is refused as unrelated, like any transaction that is not the wallet's. The wallet journals only the derivation (`Type42AddressRecordedEvent`: A and its context, B and the invoice number). The spend key c = a + t is derived each time it signs and never stored: the payer knows t, so a leaked c gives away a. That is also why the anchors are on hardened paths. A leaked a then exposes the type-42 payments to that one anchor, but neither the wallet's other anchors nor the account key, whose xpub may be public. The outputs are ordinary spendable UTXOs.
6. **Recovery has a limit. Say so to users.** A type-42 output cannot be found from the seed. Finding it needs the payer's B and the invoice number. A wallet restored from its journal or a snapshot keeps the derivation and its outputs. A wallet restored from its seed alone, through address discovery, does not find them. The payment is then refused as unrelated, and the payee has no way to know it exists. The recovery route is the payer giving the hand-off again (its journal holds it) and the payee importing it with the derivations. The restored wallet has issued no anchors yet, so this works when the hand-off names the anchor's context — which is why a payer should pass the context it fetched with A. The app can also issue its anchors again for its identities first.

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

**ARC is asked only about payments we are a party to and still have a stake in.** A payee asks about a payment it broadcast. A payer asks about a payment it built and handed to the payee (a deferred payment), from the time it hands it over until the network settles it, fails it, or the payment is cancelled or reclaimed. In the type-42 mode the payer broadcasts its payment itself, so it asks about a payment it broadcast. ARC is never asked about any other transaction, including the ancestors of a counterparty's payment. An ARC instance can only answer for the transactions submitted through it, so it has no standing to prove a counterparty's history. A `NOT_FOUND` from it tells you nothing about whether a transaction was mined. That includes a payment the payee submitted through a different ARC, which is why a payer's check falls back to its configured data source. A transaction reaching us from a counterparty arrives with the proofs its ancestry needs, or we reject it: supplying them is the sender's obligation, not something we go and fetch. When a proof we hold later leaves the active chain, we say which output is blocked and on which ancestor — and wait for the counterparty or for the block to return. We never fill the gap from a service.

### 4. Broadcasting & Settlement

- **Primary**: Broadcast via **ARC Service**
- **Backup**: SpiffyNode for transaction broadcast  
- **Monitor**: Poll ARC for the lifecycle (pending → confirmed) of the payments we are a party to: the ones we broadcast, and our deferred payments until they settle
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
- `ValidateBEEFCommand` (a counterparty's payment: checked, recorded, submitted to ARC), `ImportTransactionCommand` (a transaction that carries its own proof: recovery, our own history, or a payment a service took on the delegated chain), `ExportTransactionQuery` (a proven transaction as BEEF, for the payee a service took it for), `RecordOutgoingCommand`
- `StoreHeadersCommand`, `SplitUTXOsCommand`, `TimestampCommand`
- `OpenChannelCommand`, `ChannelPayCommand`, `CloseChannelCommand`
- `GetDeferredPaymentsQuery`, `BroadcastDeferredPaymentCommand`, `CheckDeferredPaymentStatusCommand`, `CancelDeferredPaymentCommand`, `ReclaimDeferredPaymentCommand` (payments handed to a recipient that the network has not settled yet)

**Key Events (emitted on stream):**
- `WalletCreatedEvent`, `BalanceResponse`, `TransactionsResponse`
- `InvoiceCreatedEvent`, `PaymentReadyEvent` (BEEF ready for transmission)
- `SPVValidationResultEvent`, `TransactionImportedEvent`, `TransactionExportedEvent`, `TransactionRecordedEvent`, `TransactionConfirmedEvent`, `TransactionConfirmationRevertedEvent`
- `BalanceUpdatedEvent` (the balance changed; the app did not have to ask)
- `UTXOSplitStartedEvent`, `UTXOSplitCompleteEvent`, `TimestampCompleteEvent`
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
- ~~Address monitoring~~ — Transactions come directly from counterparties (Critical Implementation Note 2)
- ~~Block scanning~~ — We don't scan blocks for transactions
- ~~Transaction discovery~~ — Transactions are handed to us
- ~~Block header sync~~ — That's HeaderSyncActor's job
- ~~Transaction broadcasting~~ — That's ARCActor's job

### Transaction Receipt Flow

A counterparty's payment arrives as a BEEF: the payment itself, usually unproven, with the proofs of its ancestors. We check those against our headers (first-level SPV: the funding history is anchored in real blocks — this is not double-spend protection), and then **we submit the payment to ARC ourselves**, because we are the party that cares about being paid. From that submission it is our broadcast: ARC tracks it to network acceptance and to its block, and the merkle proof of our new outputs comes from ARC.

```
1. App sends ValidateBEEFCommand (BEEF, optional invoiceId) → WalletCoordinatorActor
2. SPVActor checks the BEEF's structure, then its proofs against our headers
   (ReceiveTransactionMessage). A proof naming a header we have not synced
   parks the receive -- stored, so it survives a restart -- and the app is
   told BEEFValidationResultEvent(awaitingHeader: true); the check runs again
   when the header arrives, and the verdict follows.
3. Valid → the wallet aggregate records it (UTXOReceivedEvent,
   TransactionImportedEvent) and WalletProjection writes the read model
4. Once the read model holds it, the coordinator submits the payment to ARC,
   unless it carried a proof of its own that verified (it is already mined)
5. ARC's answer, followed while it is in flight (ARC answers with where it
   got to when its own wait for the network runs out). The invoice the
   payment pays is marked paid when the network holds it -- SEEN_ON_NETWORK
   or MINED -- and not before
6. Coordinator emits BEEFValidationResultEvent: valid, broadcasted, and
   ARC's networkStatus or the broadcastError -- what ARC actually said
7. ARCActor's status scan follows it to its block (SEEN_ON_NETWORK makes its
   outputs spendable; MINED confirms it only with a merkle path that matches
   our headers), whatever ARC said first: a payment it called
   DOUBLE_SPEND_ATTEMPTED, or put in the orphan mempool, may still be mined.
   When the network turns out to hold a payment after all, the invoice it
   pays is marked paid then -- after a restart too
```

**When an invoice is paid.** A valid BEEF says the payment's funding history
is anchored in real blocks; it says nothing about the network having taken
this payment. So the invoice is paid when ARC reports the network holding it
(`SEEN_ON_NETWORK`, or `MINED` for a payment that arrived with its own
verified proof), never on validation alone. This matters because the payment
may be a double spend the payer reclaimed, or spend an output already spent
in a block (ARC: `DOUBLE_SPEND_ATTEMPTED`, `SEEN_IN_ORPHAN_MEMPOOL`), and a
paid invoice refuses every other transaction -- so an invoice paid by a
payment the network refuses turns the payer's genuine replacement away. The
received outputs stay pending until the network holds it either way (bead
libspiffy-vj4j), so no balance counts what the network has not taken.

Either way in, the transaction must be the wallet's: an output paying one of its addresses or an invoice of it, or an input spending one of its outputs. One with none of these is refused, not recorded in the wallet's history with nothing in it, and not submitted for it.

`ImportTransactionCommand` is not a way to receive a payment. It brings in a transaction the wallet knows to be mined — recovering a wallet, importing its own history — and so accepts only a BEEF carrying the proof of the transaction it imports; one without is refused and names `ValidateBEEFCommand`. It is submitted nowhere, and answered with `SPVValidationResultEvent`, then `TransactionImportedEvent` once the projection has applied it. There is no `TransactionReceivedEvent` (bead libspiffy-5ml6), and no `ReceiveTransactionCommand`: it was the same pipeline as the import, and submitted nothing (bead libspiffy-ckr4).

### Payment Flow (Outgoing)

```
1. App sends PayInvoiceCommand → WalletCoordinatorActor
2. Coordinator routes to PaymentCoordinatorActor
3. PaymentCoordinator selects UTXOs, collects ancestor proofs, builds BEEF
4. PaymentCoordinator returns BEEFPaymentResponse → Coordinator
5. The payment is recorded as a deferred payment: its inputs are held
6. Coordinator emits PaymentReadyEvent (contains BEEF bytes)
7. App hands the BEEF to the payee, who broadcasts it
8. ARCActor follows the payment until the network settles it or fails it
   (see Deferred payments below)
```

**Key insight**: PaymentCoordinatorActor builds the BEEF but does **not** broadcast it. Broadcasting is the payee's job. The payer follows the payment in ARC because its inputs and its change depend on the outcome. If the payee never broadcasts, `BroadcastDeferredPaymentCommand` lets the payer broadcast it instead.

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

**What "confirmed" means, everywhere, without exception: the transaction is in a
block whose header we hold on our active chain, and we have the merkle proof
that puts it there.** Nothing else confirms anything. Not a confirmation count,
not a depth threshold, not a height a caller handed us, not an ARC status
string, not the passage of time. A UTXO's `blockHeight` is exactly this
evidence — it is written only by a confirmation verified against our own
header chain (Critical Implementation Note 1, beads libspiffy-5ry and
libspiffy-8oaq), and a reorganization that takes the block off the active
chain takes the height off the output again. So `blockHeight != null` **is**
the confirmed test, at every layer, and every balance API answers it the same
way.

A confirmation *count* is not evidence and no rule may turn on one. A count
is a description of how deep a block now sits — stale at the next block,
derivable as `tip height - blockHeight + 1` from the height and our chain
tip, and never a reason to call something confirmed that a proof has not
placed in a block. There is deliberately no "six confirmations" threshold: a
proof on our active chain confirms at depth one exactly as it does at depth
six, and a wallet that waits for depth is making a policy choice that belongs
to the application, not to this library.

Three judgements are shared by every layer:

- **Plugin-managed**: the UTXO's plugin metadata names a `pluginId` (`BitcoinUtxo.isPluginManaged`). Metadata without one (the read model's script analysis of a plain output, a label) does not count. A script a registered plugin claims gets its `pluginId` on both layers even when the plugin's metadata omits it.
- **Watch-only**: the wallet holds no key for the UTXO. Either it belongs to a watch-only (xpub) wallet, which holds no private key at all (for example, a service's copy of a payee's wallet, see "Payment modes"), or a key it needs is a watch address (`isWatchOnlyOutput`). Kept with its transaction and proof, reported apart, never spent. The write side reads the wallet type from its state, the read side from the wallet row's `walletType`.
- **Cannot spend alone**: a bare multisig UTXO whose threshold the wallet's own keys do not meet. The wallet no longer takes one as a UTXO, but a journal written before can hold one (a channel's 2-of-2 funding output, an escrow); it is kept, with its row, and counts in no spendable balance. Derived from the script and the wallet's keys, so no corrective event is needed.

| API | Counts | Confirmed means |
|-----|--------|-----------------|
| `WalletState.availableBalance`, `availableUtxos`, `BitcoinWalletAggregate.hasSufficientBalance` | Exactly the UTXOs the aggregate's coin selection (`selectUTXOsForAmount`) may pick, one predicate (`WalletBalances.isSpendable`): status available, not plugin-managed, not watch-only, not a multisig the wallet cannot spend alone, not an input of a deferred payment recorded before holds were journaled (inferred from the state until `ReconcileDeferredSpendsCommand` journals the hold), any confirmations. Pending, reserved, deferred-held and spent UTXOs are out. A selection of up to `availableBalance` succeeds; one satoshi more fails. | n/a |
| `WalletState.confirmedBalance` / `unconfirmedBalance` / `reservedBalance` (`WalletBalances.bucketOf`, journaled in snapshots) | Every unspent UTXO in exactly one bucket, pending, plugin-managed, watch-only and cannot-spend-alone included: everything the wallet holds. Not a spendable amount. | Unreserved and `blockHeight != null`: a proof puts it in a block on our active chain |
| Read model wallet row (`WalletProjection`: `confirmedBalance`, `unconfirmedBalance`, `reservedBalance`, `totalBalance`, `watchOnlyBalance`) | The same buckets over unspent UTXOs, leaving out plugin-managed, watch-only and cannot-spend-alone UTXOs (`splitBalanceUtxos`); `watchOnlyBalance` is the unspent watch-only UTXOs, any status. | `blockHeight != null`: a proof puts it in a block on our active chain |
| `BalanceResponse` (`GetBalanceQuery`) | Payment UTXOs the wallet can spend alone, not plugin-managed. `confirmedBalance` + `unconfirmedBalance` = `totalBalance` is the spendable money, and equals `getBalance`. Three kinds of the wallet's own money that cannot be spent are reported apart and are in none of those totals: `reservedBalance` (committed to a payment or held by a deferred one, bead libspiffy-a5h8), `watchOnlyBalance` (no key for it, bead libspiffy-87a2), and `pendingBalance` (the network is not known to hold it, or a reorganization took its proof away, bead libspiffy-z84j). | `blockHeight != null`: a proof puts it in a block on our active chain |
| `BalanceUpdatedEvent` (announced, not asked for) | The same six numbers as `BalanceResponse`, from the same computation (`WalletCoordinatorActor._balancesOf`), announced when an event the wallet read model applied moved any of them (bead libspiffy-7ye4). An application does not have to poll `GetBalanceQuery` to notice a change, and cannot be told one balance by the event and another by the query. | `blockHeight != null`: a proof puts it in a block on our active chain |
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

No address monitoring, whether on the blockchain directly or in ARC. We do not follow payments we are not a party to, or payments whose state has no bearing on a payment of ours that is still active.

- ❌ Don't monitor addresses on the network or through any service
- ❌ Don't scan blocks for transactions
- ❌ Don't ask ARC about a transaction just because it touches an address we know
- ✅ Receive transactions directly from counterparties
- ✅ Validate received transactions using proofs
- ✅ Follow in ARC each payment we are a party to, while it is active, whether we are its payer or its payee (see "The Real SPV Transaction Flow", step 6)

A watch address (`RegisterWatchAddressCommand`) is not address monitoring. It only labels outputs in transactions that already reach the wallet. The wallet holds no key for those outputs, so it keeps them apart and never spends them.

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