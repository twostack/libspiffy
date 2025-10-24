# LibSpiffy Application Developer Guide

**Version:** 1.0.0  
**Audience:** Application developers building Bitcoin SV applications with LibSpiffy

---

## Table of Contents

1. [Introduction](#introduction)
2. [Quick Start](#quick-start)
3. [🟢 Public APIs](#-public-apis)
   - [System Initialization](#system-initialization)
   - [Wallet Management](#wallet-management)
   - [Invoice Management](#invoice-management)
   - [SPV Payments with BEEF](#spv-payments-with-beef)
   - [Transaction Building](#transaction-building)
   - [Read Model Queries](#read-model-queries)
4. [🟡 Internal APIs (Advanced)](#-internal-apis-advanced)
   - [UTXO Management](#utxo-management)
   - [SPV Operations](#spv-operations)
   - [Direct Actor Messaging](#direct-actor-messaging)
   - [Event Store Access](#event-store-access)
5. [Common Patterns](#common-patterns)
6. [Error Handling](#error-handling)
7. [Testing Your Application](#testing-your-application)
8. [Complete API Reference](#complete-api-reference)

---

## Introduction

LibSpiffy is a CQRS-based Bitcoin SV wallet library built on the Eventador and Dactor frameworks. This guide focuses on the **APIs** you'll use to build applications, clearly marking which are intended for general use (PUBLIC) and which are internal implementation details (INTERNAL).

### API Classification

Throughout this guide, APIs are marked with color-coded indicators:

- **🟢 PUBLIC API:** Intended for application developers. These are the primary interfaces you should use for wallet, invoice, and transaction operations. Stable and well-documented.

- **🟡 INTERNAL API:** Used internally by LibSpiffy. These APIs are typically called automatically by the system (e.g., SPV validation, projection updates). Use only when building custom integrations or advanced features like blockchain sync.

### Key Concepts for Developers

- **Event Sourcing:** All state changes are persisted as immutable events
- **CQRS:** Commands change state, queries read from optimized read models
- **Actor Model:** Asynchronous message passing for concurrency
- **Eventual Consistency:** Read models update asynchronously after commands

### When to Use Internal APIs

Internal APIs should only be used when:
- Building custom blockchain synchronization logic
- Importing wallets from external systems
- Implementing advanced UTXO management strategies
- Debugging or auditing event history

**For most applications:** Use the PUBLIC APIs for wallet creation, address generation, invoice management, transaction building, and read model queries.

---

## Quick Start

### Installation

Add to your `pubspec.yaml`:

```yaml
dependencies:
  libspiffy:
    path: ../libspiffy  # Or your package location
```

### Minimal Setup

```dart
import 'package:libspiffy/libspiffy.dart';
import 'package:isar/isar.dart';
import 'package:dactor/dactor.dart';

Future<void> main() async {
  // 1. Initialize Isar (required for persistence)
  await Isar.initializeIsarCore(download: true);
  final isar = await Isar.open(
    LibSpiffySchemas.walletSchemas,
    directory: './data',
  );

  // 2. Create actor system
  final actorSystem = LocalActorSystem(ActorSystemConfig());

  // 3. Initialize LibSpiffy
  final libspiffy = LibSpiffyActorSystem();
  await libspiffy.initialize(
    actorSystem: actorSystem,
    isar: isar,
    dataDirectory: './data',
  );

  print('✓ LibSpiffy initialized');

  // 4. Use the APIs (see below)
  // ...

  // 5. Cleanup on shutdown
  await libspiffy.shutdown();
}
```

---

## 🟢 Public APIs

These are the primary APIs application developers should use. They handle common wallet, invoice, and transaction operations.

---

## System Initialization

**Description:** Core system setup and lifecycle management.

### LibSpiffyActorSystem

**Type:** 🟢 PUBLIC  
**Description:** Main entry point for all LibSpiffy operations. Manages actor system, storage, and CQRS infrastructure.

#### Key Properties

```dart
// Query interface (PUBLIC - use for all read operations)
ReadModelStorage walletStorage

// Actor references (for actor messaging pattern - see Advanced section)
ActorRef walletManager
ActorRef invoiceCoordinator
```

#### Core Methods

```dart
// 🟢 PUBLIC: Initialize the LibSpiffy system
Future<void> initialize({
  LocalActorSystem? actorSystem,
  Isar? isar,
  String? dataDirectory,
  // P2P Configuration (automatic blockchain sync)
  String networkType = 'test',      // 'test' or 'main'
  bool enableP2P = true,            // Enable automatic P2P sync
  int? startHeight,                 // Optional SPV start height
  List<String>? peerAddresses,      // Optional custom peers ('host:port')
  String? userAgent,                // Optional user agent
})

// 🟢 PUBLIC: Clean shutdown (always call this!)
Future<void> shutdown()

// 🟡 INTERNAL: SpiffyNode integration (managed automatically if enableP2P: true)
Future<void> disconnectFromSpiffyNode()
```

**P2P Notes:**
- When `enableP2P: true` (default), LibSpiffy automatically manages SpiffyNode for blockchain sync
- No need to import or configure SpiffyNode directly - it's handled internally
- Custom peers can be specified with `peerAddresses: ['host:port']`
- To disable P2P (e.g., using alternative header sources), set `enableP2P: false`

---

## Wallet Management

**Description:** Create and manage Bitcoin wallets with support for three wallet types: HD (mnemonic), WIF (single private key), and XPRIV (extended private key).

### Wallet Types

LibSpiffy supports three wallet types:

1. **HD (Hierarchical Deterministic)** - Default type. Create from mnemonic seed phrase. Supports unlimited address generation via BIP32/44 derivation.

2. **WIF (Wallet Import Format)** - Import a single private key. Single address only - calling `GenerateAddressCommand` always returns the same address.

3. **XPRIV (Extended Private Key)** - Import from extended private key (xpriv). Supports HD address generation like mnemonic wallets.

### 🟢 CreateWalletMessage

**Type:** PUBLIC  
**Description:** Creates a new event-sourced wallet. Specify one of: `mnemonic`, `wif`, or `xpriv`.

**Usage - HD Wallet (Default):**

```dart
import 'package:dactor/dactor.dart';

// Create a receiver actor to get the response
final completer = Completer<WalletCreatedMessage>();
final receiver = await actorSystem.spawn(
  'wallet-create-receiver',
  () => TestReceiverActor<WalletCreatedMessage>(completer),
);

// Create HD wallet (generates new mnemonic if not provided)
libspiffy.walletManager.tell(
  CreateWalletMessage(
    'my-wallet-id', 
    'My Bitcoin Wallet',
    // Optional: mnemonic: 'your twelve word seed phrase here',
  ),
  sender: receiver,
);

// Wait for response
final response = await completer.future.timeout(Duration(seconds: 5));
if (response.success) {
  print('✓ Wallet created: ${response.walletId}');
  print('  Root address: ${response.rootAddress}');
} else {
  print('✗ Error: ${response.error}');
}
```

**Usage - WIF Wallet (Single Address):**

```dart
// Import from WIF private key
libspiffy.walletManager.tell(
  CreateWalletMessage(
    'imported-wallet-id',
    'Imported Wallet',
    wif: 'cPBBhyEvTZXSZhLJ8AuotbAmzR2bM8eQJV7fiBAQGcGsaSAaPfBf',
  ),
  sender: receiver,
);
// Note: WIF wallets are single-address. GenerateAddressCommand will always 
// return the same address derived from the private key.
```

**Usage - XPRIV Wallet (HD from Extended Key):**

```dart
// Import from extended private key
libspiffy.walletManager.tell(
  CreateWalletMessage(
    'xpriv-wallet-id',
    'XPRIV Wallet',
    xpriv: 'xprv9s21ZrQH143K3QTDL4LXw2F7HEK3wJUD2nW2nRk4stbPy6cq3jPPqjiChkVvvNKmPGJxWUtg6LnF5kejMRNNU3TGtRBeJgk33yuGBxrMPHi',
  ),
  sender: receiver,
);
// XPRIV wallets support unlimited address generation like HD wallets
```

**Parameters:**
- `walletId` (String, required) - Unique identifier for the wallet
- `walletName` (String, required) - Human-readable name
- `mnemonic` (String?, optional) - For HD wallets. Auto-generated if null.
- `wif` (String?, optional) - For WIF wallets. Single-address import.
- `xpriv` (String?, optional) - For XPRIV wallets. HD derivation from extended key.
- `walletMetadata` (Map?, optional) - Custom metadata (e.g., `{'network': 'testnet'}`)

**Validation:** Exactly one of `mnemonic`, `wif`, or `xpriv` must be specified (or none for auto-generated HD wallet).

**Returns:** `WalletCreatedMessage` with `success`, `walletId`, `name`, `rootAddress`, and optional `error`.

---

### 🟢 GenerateAddressCommand

**Type:** PUBLIC  
**Description:** Generates a new address for receiving payments. Behavior depends on wallet type:
- **HD/XPRIV wallets:** Derives new addresses sequentially (BIP32/44)
- **WIF wallets:** Always returns the same single address

**Usage:**

```dart
final completer = Completer<AddressGeneratedResponse>();
final receiver = await actorSystem.spawn(
  'address-receiver',
  () => TestReceiverActor<AddressGeneratedResponse>(completer),
);

libspiffy.walletManager.tell(
  WalletCommandMessage(
    'my-wallet-id',
    GenerateAddressCommand(
      walletId: 'my-wallet-id',
      metadata: {'purpose': 'receive_payment'}, // Optional correlation metadata
    ),
  ),
  sender: receiver,
);

final response = await completer.future.timeout(Duration(seconds: 5));
if (response.success) {
  print('✓ Address: ${response.address}');
  print('  Derivation index: ${response.derivationIndex}');
  // Note: For WIF wallets, address and index are always the same
} else {
  print('✗ Error: ${response.error}');
}
```

**Wallet Type Behavior:**
- **HD/XPRIV:** Each call generates a new address at `derivationIndex` (incrementing)
- **WIF:** Each call returns the root address at `derivationIndex = 0`

**Returns:** `AddressGeneratedResponse` with `walletId`, `address`, `derivationIndex`, `success`, `error`, and `metadata`.

---

## Invoice Management

**Description:** Create payment requests with automatic address generation, expiration tracking, and SPV validation.

### 🟢 CreateInvoiceMessage

**Type:** PUBLIC  
**Description:** Creates a payment invoice with one or more addresses. Automatically coordinates with wallet for address generation.

**Usage:**

```dart
final completer = Completer<InvoiceCreatedMessage>();
final receiver = await actorSystem.spawn(
  'invoice-receiver',
  () => TestReceiverActor<InvoiceCreatedMessage>(completer),
);

libspiffy.invoiceCoordinator.tell(
  CreateInvoiceMessage(
    walletId: 'my-wallet-id',
    amount: BigInt.from(100000),  // satoshis
    description: 'Payment for services',
    expiresIn: Duration(hours: 24),
    numberOfAddresses: 1, // 1 or more for multi-address invoices
    invoiceMetadata: {'order_id': '12345'}, // Optional metadata
  ),
  sender: receiver,
);

final invoice = await completer.future.timeout(Duration(seconds: 5));
print('✓ Invoice created: ${invoice.invoiceId}');
print('  Pay to: ${invoice.addresses.first}');
print('  Amount: ${invoice.amount} satoshis');
print('  Expires: ${invoice.expiresAt}');
```

**Returns:** `InvoiceCreatedMessage` with `invoiceId`, `walletId`, `addresses`, `amount`, `description`, `createdAt`, `expiresAt`, `success`, and optional `error`.

---

### 🟢 CheckInvoiceMessage

**Type:** PUBLIC  
**Description:** Queries invoice status from the read model. Returns current status (pending/paid/expired/cancelled).

**Usage:**

```dart
final completer = Completer<InvoiceDetailsResponse>();
final receiver = await actorSystem.spawn(
  'invoice-check',
  () => TestReceiverActor<InvoiceDetailsResponse>(completer),
);

libspiffy.invoiceCoordinator.tell(
  CheckInvoiceMessage(invoiceId),
  sender: receiver,
);

final details = await completer.future.timeout(Duration(seconds: 5));
if (details.found) {
  print('Invoice status: ${details.status}');
  if (details.status == InvoiceStatus.paid) {
    print('  Paid at: ${details.paidAt}');
    print('  Payment TX: ${details.paymentTxid}');
  }
} else {
  print('Invoice not found');
}
```

**Returns:** `InvoiceDetailsResponse` with `found`, `invoiceId`, `walletId`, `addresses`, `amount`, `status`, `createdAt`, `expiresAt`, `paidAt`, `paymentTxid`, and optional `error`.

---

### 🟢 ListInvoicesMessage

**Type:** PUBLIC  
**Description:** Lists all invoices, optionally filtered by wallet ID.

**Usage:**

```dart
final completer = Completer<InvoicesListMessage>();
final receiver = await actorSystem.spawn(
  'invoice-list',
  () => TestReceiverActor<InvoicesListMessage>(completer),
);

libspiffy.invoiceCoordinator.tell(
  ListInvoicesMessage(
    walletId: 'my-wallet-id', // Optional: filter by wallet
  ),
  sender: receiver,
);

final list = await completer.future.timeout(Duration(seconds: 5));
for (final invoice in list.invoices) {
  print('${invoice.invoiceId}: ${invoice.status}');
}
```

**Returns:** `InvoicesListMessage` containing a list of `InvoiceDetailsResponse` objects.

---

## SPV Payments with BEEF

**Description:** Simplified API for creating SPV-validated payments. Automatically handles UTXO selection, transaction building, ancestor chain collection, and BEEF package construction.

---

### Understanding SPV Payments

**What is SPV (Simplified Payment Verification)?**

Traditional Bitcoin wallets broadcast transactions to miners first and hope they get confirmed. LibSpiffy implements **true peer-to-peer SPV payments** where:

1. **Payer (Alice)** creates a transaction with complete proof chain (BEEF)
2. **Direct transfer** - Alice sends BEEF directly to Bob via p2p channel (libp2p, websocket, HTTP, etc.)
3. **Receiver validates** - Bob validates against his SPV block headers (no miner trust required)
4. **Receiver broadcasts** - Bob broadcasts to network only after validation passes

**Why SPV Payments?**

- ✅ **Instant finality** - Bob knows payment is valid immediately upon receipt
- ✅ **No third-party trust** - Validation uses cryptographic merkle proofs against known headers
- ✅ **Privacy** - Direct peer-to-peer exchange, no broadcast until receiver validates
- ✅ **Unconfirmed chain support** - Can spend recently received UTXOs before confirmation
- ✅ **True micropayments** - No need to wait for miner confirmation before accepting small amounts

**How is this different from traditional wallets?**

| Traditional Broadcast-First | LibSpiffy SPV Payments |
|----------------------------|------------------------|
| Send TX → Wait for miners → Hope it confirms | Create BEEF → Send to receiver → Receiver validates & broadcasts |
| Trust miners/nodes to include TX | Trust cryptographic proofs (SPV) |
| Can't spend unconfirmed UTXOs reliably | Can chain unconfirmed transactions |
| Receiver must monitor mempool | Receiver gets complete proof package |
| Privacy leak (broadcast to all) | Private peer-to-peer transfer |

**What is BEEF (Background Evaluation Extended Format)?**

BEEF is a self-contained package that includes everything needed for SPV validation:

```
BEEF Package Contents:
├── Payment Transaction (the actual payment to Bob)
├── Ancestor Transactions (all parent TXs back to confirmed UTXOs)
├── Merkle Proofs (SPV proof that ancestors were mined)
└── Block Headers (optional - for header validation)
```

This allows Bob to validate that Alice's payment is backed by real confirmed UTXOs without trusting any third party or querying the blockchain.

**Example Chain:**

```
[Confirmed TX with Merkle Proof] ← Block 100,000
         ↓
[Unconfirmed TX 1] (Alice received funds)
         ↓
[Unconfirmed TX 2] (Alice spending to Bob)

BEEF includes ALL of these transactions + merkle proof for the confirmed one.
Bob validates the entire chain and confirms Alice owns the UTXOs.
```

**Critical Prerequisite: Transaction History Import**

For Alice to create BEEF, she **must have**:

1. ✅ All transactions in the ancestor chain stored in LibSpiffy
2. ✅ At least one merkle proof per UTXO chain (confirmed transaction)
3. ✅ Complete transaction history with no gaps

**How to ensure transaction history exists:**

```dart
// Import historical transactions with merkle proofs
import 'package:libspiffy/libspiffy.dart';

final importResult = await libspiffy.transactionImportService.importTransactions(
  walletId: 'alice-wallet',
  transactions: [
    ImportableTransaction(
      txid: 'abc123...',
      rawHex: '0200000001...',
      blockHeight: 100000,
      merkleProof: MerkleProof(...), // Critical!
    ),
    // ... more transactions
  ],
  walletAddresses: ['aliceAddress1', 'aliceAddress2'],
);

// Wait for projection to update
await Future.delayed(Duration(seconds: 1));

// Now Alice can create BEEF payments
```

Without transaction import, `PayInvoiceMessage` will fail with:
- **"Transaction X not found in storage"** - Missing ancestor
- **"No merkle proof found"** - Chain doesn't terminate at confirmed TX
- **"Incomplete transaction chain"** - Gap in ancestor chain

See [TransactionImportService](#-transactionimportservice-public) for detailed import guide.

---

### 🟢 PayInvoiceMessage

**Type:** PUBLIC  
**Description:** Pay an invoice using the SPV model. Automatically selects UTXOs, collects ancestor transactions back to merkle proofs, builds the payment transaction, and creates a BEEF package ready to send to the receiver.

**How it works:**
1. Selects UTXOs to fund payment
2. Recursively collects ancestor transactions back to first merkle proof
3. Validates complete chain exists (fails if any ancestor missing)
4. Builds payment transaction
5. Creates BEEF package with all ancestors and proofs
6. Returns BEEF (does NOT broadcast - pure SPV model)

**Usage:**

```dart
import 'package:libspiffy/libspiffy.dart';
import 'package:dactor/dactor.dart';

// Alice pays Bob's invoice
final completer = Completer<BEEFPaymentResponse>();
final receiver = await aliceActorSystem.spawn(
  'payment-receiver',
  () => TestReceiverActor<BEEFPaymentResponse>(completer),
);

aliceLibSpiffy.paymentCoordinator.tell(
  PayInvoiceMessage(
    walletId: 'alice-wallet-id',
    invoiceId: bobInvoice.invoiceId,
    addresses: bobInvoice.addresses,
    amount: bobInvoice.amount,
  ),
  sender: receiver,
);

final payment = await completer.future.timeout(Duration(seconds: 30));

if (payment.success) {
  print('✓ BEEF created with ${payment.ancestorCount} ancestor transactions');
  print('  Transaction ID: ${payment.txid}');
  print('  Amount paid: ${payment.amountPaid} satoshis');
  print('  Change: ${payment.changeAmount} satoshis');
  
  // Send BEEF to Bob via your p2p channel (libp2p, websocket, etc.)
  await yourP2PChannel.send({
    'type': 'payment',
    'invoiceId': payment.invoiceId,
    'beef': payment.beefBytes,
  });
} else {
  print('✗ Payment failed: ${payment.error}');
}
```

**Parameters:**
- `walletId` (String): Payer's wallet ID
- `invoiceId` (String): Invoice identifier for correlation
- `addresses` (List\<String\>): Payment addresses from the invoice
- `amount` (BigInt): Amount to pay in satoshis
- `changeAddress` (String?, optional): Change address (auto-generated if null)
- `paymentMetadata` (Map?, optional): Additional metadata for correlation

**Returns:** `BEEFPaymentResponse` with:
- `success` (bool): Whether BEEF creation succeeded
- `beefBytes` (Uint8List): Serialized BEEF package ready to send
- `txid` (String): Transaction ID
- `amountPaid` (BigInt): Total amount paid
- `changeAmount` (BigInt): Change amount
- `ancestorCount` (int): Number of ancestor transactions included
- `error` (String?): Error message if failed

**Requirements:**
- All ancestor transactions must be stored in LibSpiffy
- At least one transaction in each chain must have a merkle proof
- Fails with clear error if chain is incomplete

**Common Errors:**
- **"Insufficient funds"** - Not enough available UTXOs in wallet
- **"Transaction X not found"** - Missing ancestor (may need historical import)
- **"No merkle proof found"** - Chain doesn't terminate at confirmed transaction
- **"Incomplete transaction chain"** - Ancestor chain is broken

**⚠️ Important Notes:**

1. **Does NOT broadcast** - Returns BEEF only. Receiver validates and broadcasts.
2. **Requires transaction history** - Payer must have all ancestor transactions stored.
3. **Merkle proofs required** - At least one confirmed transaction with proof in each chain.
4. **Pure SPV model** - Payer sends BEEF, receiver validates against block headers.

**Complete SPV Payment Flow:**

```dart
// --- RECEIVER (Bob) ---
// 1. Bob creates invoice
final bobInvoice = await createInvoice(
  walletId: bobWalletId,
  amount: BigInt.from(100000),
  description: 'Payment for services',
);

// 2. Bob sends invoice to Alice via p2p
await p2pChannel.send({
  'type': 'invoice',
  'invoice': bobInvoice,
});

// --- PAYER (Alice) ---
// 3. Alice receives invoice and creates BEEF payment
final payment = await sendPayInvoiceMessage(
  aliceLibSpiffy.paymentCoordinator,
  PayInvoiceMessage(
    walletId: aliceWalletId,
    invoiceId: bobInvoice.invoiceId,
    addresses: bobInvoice.addresses,
    amount: bobInvoice.amount,
  ),
);

// 4. Alice sends BEEF to Bob
await p2pChannel.send({
  'type': 'payment',
  'beef': payment.beefBytes,
});

// --- RECEIVER (Bob) ---
// 5. Bob receives BEEF, validates, and broadcasts
final beefBytes = message['beef'] as Uint8List;

// Validate BEEF against Bob's block headers
bobLibSpiffy.spvActor.tell(ValidateBEEFMessage(
  walletId: bobWalletId,
  beefBytes: beefBytes,
));

// If valid, broadcast to network
bobLibSpiffy.arcActor.tell(BroadcastBEEFMessage(
  beefBytes: beefBytes,
));

// Mark invoice as paid
bobLibSpiffy.invoiceCoordinator.tell(MarkInvoicePaidMessage(
  invoiceId: bobInvoice.invoiceId,
  txid: payment.txid,
  amountReceived: payment.amountPaid,
  addressesPaidTo: bobInvoice.addresses,
));
```

**Why BEEF?**

BEEF (Background Evaluation Extended Format) allows:
- Receiver validates transactions without blockchain query
- Supports unconfirmed (0-conf) payments
- Scales to high transaction volumes
- True peer-to-peer payments

---

## Transaction Building

**Description:** Script-centric transaction builder supporting P2PKH and custom script types.

### 🟢 TransactionBuilder

**Type:** PUBLIC  
**Description:** Fluent API for building Bitcoin transactions with inputs, outputs, and change calculation.

**Usage:**

```dart
import 'package:libspiffy/libspiffy.dart';

final builder = TransactionBuilder()
  ..addInput(
    utxo: myUtxo,
    unlockingScriptBuilder: P2PKHUnlockingScriptBuilder(
      privateKey: myPrivateKey,
    ),
  )
  ..addOutput(
    address: recipientAddress,
    amount: BigInt.from(50000),
  )
  ..addChangeOutput(
    address: myChangeAddress,
    feeRate: 50, // satoshis per byte
  );

final tx = builder.build();
print('Transaction ready: ${tx.toHex()}');
```

**Key Methods:**
- `addInput()` - Add UTXO to spend with unlocking script builder
- `addOutput()` - Add payment output with address or script
- `addChangeOutput()` - Automatically calculate and add change output
- `build()` - Construct final BitcoinTransaction

---

### 🟢 Custom Script Types

**Type:** PUBLIC  
**Description:** Register and use custom Bitcoin script types beyond P2PKH.

**Usage:**

```dart
// Register a custom script type
ScriptTypeRegistry.register(MyCustomScriptType());

// Use it in transactions
final builder = TransactionBuilder()
  ..addInput(
    utxo: customUtxo,
    unlockingScriptBuilder: MyCustomUnlockingScriptBuilder(...),
  )
  ..addOutput(
    scriptPubKey: myCustomLockingScript,
    amount: amount,
  );
```

---

### 🟢 BEEF (Background Evaluation Extended Format)

**Type:** PUBLIC  
**Description:** Parse and validate BEEF-encoded transactions with merkle proofs.

**Usage:**

```dart
import 'package:libspiffy/libspiffy.dart';

// Parse BEEF
final beef = BEEF.deserialize(beefBytes);

// Extract transactions
for (final tx in beef.transactions) {
  print('TX: ${tx.txid}');
}

// Validate merkle proofs
final isValid = beef.verifyMerkleProofs();
print('BEEF valid: $isValid');
```

---

## Read Model Queries

**Description:** Query optimized read models for wallet, invoice, and transaction data. Always prefer read model queries over EventStore access.

### 🟢 Wallet Queries

**Type:** PUBLIC  
**Description:** Query wallet balances, addresses, UTXOs, and transactions from the read model.

**Usage:**

```dart
// Get wallet balance
final balance = await libspiffy.walletStorage.getBalance('my-wallet-id');
print('Balance: $balance satoshis');

// Get all addresses
final addresses = await libspiffy.walletStorage.getAddresses('my-wallet-id');

// Get all UTXOs
final utxos = await libspiffy.walletStorage.getUTXOs('my-wallet-id');
print('Wallet has ${utxos.length} UTXOs');

// Get unspent UTXOs only
final unspent = await libspiffy.walletStorage.getUnspentUTXOs('my-wallet-id');

// Get specific UTXO
final utxo = await libspiffy.walletStorage.getUTXO('my-wallet-id', 'txid', 0);

// Get transaction history
final transactions = await libspiffy.walletStorage.getWalletTransactions('my-wallet-id');
```

---

### 🟢 Address Management Queries

**Type:** PUBLIC  
**Description:** Efficiently manage and query wallet addresses with support for all Bitcoin script types (P2PKH, P2PK, P2MS, P2SH, custom scripts).

**Key Features:**
- **O(1) Address Lookups:** Hash-indexed address checking for optimal performance
- **Script Type Support:** Works with any Bitcoin script type, not just standard scripts
- **Address Metadata Tracking:** Track usage statistics, balances, derivation paths, and labels
- **Transaction-Address Relationships:** Query all transactions for a given address

**Usage:**

```dart
// Check if address belongs to wallet (O(1) hash lookup)
final belongs = await libspiffy.walletStorage.isWalletAddress('my-wallet-id', 'address123...');
if (belongs) {
  print('This address belongs to the wallet');
}

// Get address metadata (usage stats, balance, derivation info)
final metadata = await libspiffy.walletStorage.getAddressMetadata('my-wallet-id', 'address123...');
if (metadata != null) {
  print('Script Type: ${metadata.scriptType}'); // p2pkh, p2pk, p2ms, p2sh, custom
  print('Usage Count: ${metadata.usageCount}');
  print('Balance: ${metadata.balance} satoshis');
  print('First Used: ${metadata.firstUsedAt}');
  print('Last Used: ${metadata.lastUsedAt}');
  print('Derivation Path: ${metadata.derivationPath}');
  print('Derivation Index: ${metadata.derivationIndex}');
  print('Purpose: ${metadata.purpose}'); // receive, change, invoice, import
}

// Batch check multiple addresses (efficient for large lists)
final checkResults = await libspiffy.walletStorage.checkAddresses(
  'my-wallet-id',
  ['addr1', 'addr2', 'addr3', ...],
);
// Returns: {'addr1': true, 'addr2': false, 'addr3': true}

// Get all addresses with metadata (supports filtering and pagination)
final addresses = await libspiffy.walletStorage.getAddressesWithMetadata(
  'my-wallet-id',
  includeUnused: false,  // Only addresses that have been used
  isChange: false,        // Only receiving addresses
  limit: 50,
  offset: 0,
);
for (final addr in addresses) {
  print('${addr.address}: ${addr.usageCount} uses, ${addr.balance} sats');
}

// Get addresses by derivation index range (efficient for HD wallets)
final rangeAddresses = await libspiffy.walletStorage.getAddressRange(
  'my-wallet-id',
  startIndex: 0,
  count: 20,
  isChange: false,  // false = receiving addresses, true = change addresses
);

// Get all transactions for a specific address
final txids = await libspiffy.walletStorage.getTransactionsByAddress(
  'my-wallet-id',
  'address123...',
  direction: 'output',  // 'output' (received), 'input' (sent), or null (both)
  limit: 100,
);
print('Address involved in ${txids.length} transactions');

// Get transaction count for an address
final txCount = await libspiffy.walletStorage.getAddressTransactionCount(
  'my-wallet-id',
  'address123...',
);
print('Address has been used in $txCount transactions');

// Get all addresses and their transaction details for a specific transaction
final txAddresses = await libspiffy.walletStorage.getTransactionAddresses(
  'my-wallet-id',
  'txid123...',
);
print('Inputs from ${txAddresses.inputs.length} addresses');
print('Outputs to ${txAddresses.outputs.length} addresses');
for (final input in txAddresses.inputs) {
  print('  Input from ${input.address}: ${input.amount} sats (vin: ${input.vin})');
}
for (final output in txAddresses.outputs) {
  print('  Output to ${output.address}: ${output.amount} sats (vout: ${output.vout})');
}
```

**Address Payment Destinations:**

LibSpiffy treats addresses as generic "payment destinations" that support all Bitcoin script types:

- **P2PKH/P2PK:** Standard base58 addresses (e.g., `1A1zP1...`)
- **P2MS (Multisig):** Deterministic identifier using sorted public keys (e.g., `multisig:pubkey1:pubkey2:pubkey3`)
- **P2SH:** Script hash identifier (e.g., `scripthash:a9b8c7d6...`)
- **Custom Scripts:** Script-based identifier (e.g., `script:1a2b3c4d`)
- **OP_RETURN:** Automatically skipped (unspendable outputs)

This design embraces BSV's philosophy of allowing any script type without restrictions to "standard" scripts.

**Performance Notes:**
- `isWalletAddress()` uses hash indexing for O(1) lookups (vs O(N) linear search)
- `checkAddresses()` is optimized for batch operations with a single database query
- `getAddressRange()` is efficient for HD wallets scanning sequential derivation indexes
- Address metadata is automatically tracked and updated by the wallet projection

---

### 🟢 Invoice Queries

**Type:** PUBLIC  
**Description:** Query invoice data from the read model (faster than actor messages).

**Usage:**

```dart
// Get single invoice
final invoice = await libspiffy.walletStorage.getInvoice(invoiceId);
if (invoice != null) {
  print('Invoice amount: ${invoice.amount}');
  print('Status: ${invoice.status}');
}

// List all invoices for a wallet
final invoices = await libspiffy.walletStorage.listInvoices('my-wallet-id');
```

---

## 🟡 Internal APIs (Advanced)

**⚠️ Warning:** These APIs are primarily used internally by LibSpiffy. Application developers should typically use the invoice flow for receiving payments and transaction builder for sending. Only use these APIs if you need fine-grained control or are building custom blockchain sync logic.

---

## UTXO Management

**Description:** Low-level UTXO tracking and reservation. Typically handled automatically by invoice and transaction flows.

### 🟡 ReceiveUTXOCommand

**Type:** INTERNAL  
**Description:** Records a received UTXO in the wallet. Usually called automatically by SPV validation flow when payments are detected.

**⚠️ When to use:** Only when importing external UTXOs or implementing custom blockchain sync.

**Usage:**

```dart
libspiffy.walletManager.tell(
  WalletCommandMessage(
    'my-wallet-id',
    ReceiveUTXOCommand(
      walletId: 'my-wallet-id',
      txid: 'abc123...',
      vout: 0,
      satoshis: BigInt.from(100000),
      scriptPubKey: 'hex-encoded-script',
      address: 'my-address',
      blockHeight: 800000,  // null for unconfirmed
      confirmations: 1,
    ),
  ),
);
```

**What it does:**
1. Validates wallet exists and UTXO is not a duplicate
2. Emits `UTXOReceivedEvent` to EventStore
3. Updates wallet state (adds UTXO, recalculates balances)
4. Projection updates read model asynchronously

---

### 🟡 SpendUTXOCommand

**Type:** INTERNAL  
**Description:** Marks a UTXO as spent. Usually called automatically when transactions are broadcast.

**Usage:**

```dart
libspiffy.walletManager.tell(
  WalletCommandMessage(
    'my-wallet-id',
    SpendUTXOCommand(
      walletId: 'my-wallet-id',
      utxoKey: 'txid:vout',
      spendingTxId: 'def456...',
      fee: BigInt.from(500),
      blockHeight: 800001,  // null for unconfirmed
    ),
  ),
);
```

---

### 🟡 ReserveUTXOsCommand

**Type:** INTERNAL  
**Description:** Temporarily reserves UTXOs for a pending transaction to prevent double-spending.

**Usage:**

```dart
libspiffy.walletManager.tell(
  WalletCommandMessage(
    'my-wallet-id',
    ReserveUTXOsCommand(
      walletId: 'my-wallet-id',
      utxoKeys: ['txid1:0', 'txid2:1'],
      reservationId: 'tx-build-12345',
      reservationDuration: Duration(minutes: 15),  // Auto-expires
    ),
  ),
);
```

---

### 🟡 MarkInvoicePaidMessage

**Type:** INTERNAL  
**Description:** Marks an invoice as paid. Usually called automatically by SPV validation flow.

**Usage:**

```dart
libspiffy.invoiceCoordinator.tell(
  MarkInvoicePaidMessage(
    invoiceId: invoiceId,
    txid: paymentTxid,
    amountReceived: amountPaid,
    addressesPaidTo: [invoiceAddress],
    paidAt: DateTime.now(),
  ),
  sender: receiver,
);
```

---

## SPV Operations

**Description:** Low-level SPV validation and header sync. Typically handled automatically when connected to SpiffyNode.

### 🟡 ValidateTransactionMessage

**Type:** INTERNAL  
**Description:** Validates a transaction against block headers using merkle proof. Called automatically by invoice payment detection.

**Usage:**

```dart
libspiffy.spvActor.tell(
  ValidateTransactionMessage(
    tx: bitcoinTransaction,
    merkleProof: bumpProofData,
    blockHeight: blockHeight,
  ),
  sender: receiver,
);
```

---

### 🟡 GetSPVStatusMessage

**Type:** INTERNAL  
**Description:** Queries SPV sync status and connected peers.

**Usage:**

```dart
final completer = Completer<SPVStatusMessage>();
final receiver = await actorSystem.spawn(
  'spv-status',
  () => TestReceiverActor<SPVStatusMessage>(completer),
);

libspiffy.spvActor.tell(
  GetSPVStatusMessage(),
  sender: receiver,
);

final status = await completer.future.timeout(Duration(seconds: 5));
print('Headers synced: ${status.headersSynced}');
print('Best height: ${status.bestHeight}');
print('Connected peers: ${status.connectedPeers.length}');
```

---

### 🟡 StoreHeaderMessage

**Type:** INTERNAL  
**Description:** Manually stores a block header. Usually handled automatically by SpiffyNode sync.

**Usage:**

```dart
libspiffy.headerSyncActor.tell(
  StoreHeaderMessage(
    header: blockHeader,
    height: blockHeight,
  ),
);
```

---

## Direct Actor Messaging

**Description:** Low-level actor messaging pattern. Most applications should use the higher-level APIs above.

### 🟡 TestReceiverActor Pattern

**Type:** INTERNAL  
**Description:** Helper pattern for receiving actor responses in synchronous-style code.

**Usage:**

```dart
import 'package:dactor/dactor.dart';

// 1. Define receiver actor
class TestReceiverActor<T> extends Actor {
  final Completer<T> completer;

  TestReceiverActor(this.completer);

  @override
  Future<void> onMessage(dynamic message) async {
    if (message is T && !completer.isCompleted) {
      completer.complete(message);
    }
  }
}

// 2. Create completer and receiver
final completer = Completer<MyResponseType>();
final receiver = await actorSystem.spawn(
  'my-receiver-${DateTime.now().millisecondsSinceEpoch}',
  () => TestReceiverActor<MyResponseType>(completer),
);

// 3. Send message to LibSpiffy actor
libspiffy.someActor.tell(
  MyRequestMessage(...),
  sender: receiver,
);

// 4. Wait for response
final response = await completer.future.timeout(Duration(seconds: 5));
```

---

## Event Store Access

**Description:** Direct EventStore access for debugging and auditing. Application code should query read models instead.

### 🟡 EventStore.loadEvents()

**Type:** INTERNAL  
**Description:** Loads event history for an aggregate. Use only for debugging or audit trails.

**⚠️ Warning:** Never query EventStore for business logic. Use read models.

**Usage:**

```dart
// Only for debugging or advanced audit scenarios
final events = await libspiffy.eventStore.loadEvents(
  'BitcoinWallet_my-wallet-id',
  fromSequence: 0,
);

print('Wallet has ${events.length} events in history');
for (final event in events) {
  print('  ${event.runtimeType} at ${event.timestamp}');
}
```

---

### 🟡 Direct Isar Queries

**Type:** INTERNAL  
**Description:** Custom Isar queries for complex read model filtering not covered by `ReadModelStorage` interface.

**Usage:**

```dart
import 'package:isar/isar.dart';

final isar = libspiffy.walletStorage as IsarWalletStorage;

// Example: Find large UTXOs
final richUtxos = await isar.isar.bitcoinUtxoEntitys
  .filter()
  .walletIdEqualTo(walletId)
  .spentEqualTo(false)
  .satoshisGreaterThan(BigInt.from(1000000))
  .sortBySatoshisDesc()
  .findAll();

print('Found ${richUtxos.length} UTXOs > 1M sats');
```

---

## Common Patterns

### Pattern 1: Payment Flow

```dart
// 1. Create invoice
final invoice = await createInvoice(
  walletId: sellerWalletId,
  amount: BigInt.from(50000),
  description: 'Widget purchase',
);

// 2. Buyer pays to invoice address
// (External: buyer constructs and broadcasts transaction)

// 3. Monitor for payment
Timer.periodic(Duration(seconds: 5), (timer) async {
  final status = await checkInvoiceStatus(invoice.invoiceId);
  if (status == InvoiceStatus.paid) {
    print('✓ Payment received!');
    timer.cancel();
  }
});
```

### Pattern 2: Multi-Address Invoice

```dart
// Create invoice with multiple addresses for privacy
final invoice = await createInvoice(
  walletId: walletId,
  amount: BigInt.from(100000),
  numberOfAddresses: 5, // 5 addresses, split payment
);

print('Pay to any of these addresses:');
for (final address in invoice.addresses) {
  print('  - $address');
}
```

### Pattern 3: UTXO Reservation

```dart
// Reserve UTXOs for a pending transaction
final reserveCommand = ReserveUTXOsCommand(
  walletId: walletId,
  utxoKeys: [
    UtxoKey(txid: 'abc123', vout: 0),
    UtxoKey(txid: 'def456', vout: 1),
  ],
  duration: Duration(minutes: 15),
  purpose: 'tx-building',
);

libspiffy.walletManager.tell(
  WalletCommandMessage(walletId, reserveCommand),
);

// Build transaction with reserved UTXOs
// ...

// Release if transaction fails
final releaseCommand = ReleaseUTXOsCommand(
  walletId: walletId,
  utxoKeys: [...],
);

libspiffy.walletManager.tell(
  WalletCommandMessage(walletId, releaseCommand),
);
```

### Pattern 4: Waiting for Projections

Since projections update asynchronously, use retry logic:

```dart
Future<Invoice?> waitForInvoiceInDatabase({
  required String invoiceId,
  Duration timeout = const Duration(seconds: 5),
}) async {
  final startTime = DateTime.now();
  while (DateTime.now().difference(startTime) < timeout) {
    final invoice = await libspiffy.walletStorage.getInvoice(invoiceId);
    if (invoice != null) {
      return invoice;
    }
    await Future.delayed(Duration(milliseconds: 100));
  }
  return null;
}
```

---

## Error Handling

### Command Failures

Commands can fail for business logic reasons:

```dart
final response = await completer.future.timeout(Duration(seconds: 5));

if (!response.success) {
  switch (response.error) {
    case 'Insufficient balance':
      showInsufficientFundsDialog();
      break;
    case 'Address already generated':
      // Handle idempotency
      break;
    default:
      showGenericError(response.error);
  }
}
```

### Timeout Handling

```dart
try {
  final response = await completer.future.timeout(Duration(seconds: 5));
  // Process response
} on TimeoutException {
  print('⚠️ Command timed out - actor may be busy or message lost');
  // Retry logic or fallback
}
```

### Event Store Failures

```dart
try {
  await libspiffy.initialize(...);
} on EventStoreException catch (e) {
  print('Failed to initialize event store: $e');
  // Handle database corruption or migration issues
}
```

### Aggregate Recovery Failures

```dart
// If an aggregate fails to recover, you may see:
// "Bad state: Aggregate <id> has not been initialized"

// This usually means:
// 1. Events are corrupted in storage
// 2. Event deserialization failed (missing EventRegistry entry)
// 3. Race condition - command sent before recovery completed

// For #3, LibSpiffy includes delays after aggregate spawn
// For #1-2, check your event store integrity and EventRegistry
```

---

## Testing Your Application

### Test Setup

```dart
import 'package:test/test.dart';
import 'package:libspiffy/libspiffy.dart';
import 'dart:io';

void main() {
  late LibSpiffyActorSystem libspiffy;
  late LocalActorSystem actorSystem;
  late Isar isar;
  late Directory testDir;

  setUp(() async {
    // Initialize Isar core
    await Isar.initializeIsarCore(download: true);

    // Create temp directory for test
    testDir = Directory.systemTemp.createTempSync('libspiffy_test_');

    // Open Isar with unique name per test
    isar = await Isar.open(
      [
        ...LibSpiffySchemas.walletSchemas,
        EventEnvelopeSchema,
        SnapshotEnvelopeSchema,
      ],
      directory: testDir.path,
      name: 'test_db_${DateTime.now().millisecondsSinceEpoch}',
    );

    // Create actor system
    actorSystem = LocalActorSystem(ActorSystemConfig());

    // Initialize LibSpiffy
    libspiffy = LibSpiffyActorSystem();
    await libspiffy.initialize(
      actorSystem: actorSystem,
      isar: isar,
      dataDirectory: testDir.path,
    );
  });

  tearDown(() async {
    await libspiffy.shutdown();
    testDir.deleteSync(recursive: true);
  });

  test('creates wallet and generates address', () async {
    // Your test here
  });
}
```

### Mocking External Services

```dart
// Mock ARC service for broadcasting
class MockArcService extends ArcService {
  @override
  Future<String> broadcastTransaction(String txHex) async {
    return 'mock-txid-${DateTime.now().millisecondsSinceEpoch}';
  }
}

// Use in tests
final mockArc = MockArcService();
// Pass to LibSpiffy or test actors
```

### Testing Projections

```dart
test('invoice projection updates read model', () async {
  // 1. Create invoice (command)
  final invoice = await createInvoice(...);

  // 2. Wait for projection to process
  await Future.delayed(Duration(milliseconds: 500));

  // 3. Verify read model updated
  final readModel = await libspiffy.walletStorage.getInvoice(invoice.invoiceId);
  expect(readModel, isNotNull);
  expect(readModel!.status, equals(InvoiceStatus.pending));
});
```

### Testing Event Sourcing

```dart
test('wallet recovers from events after restart', () async {
  // 1. Create wallet and perform operations
  await createWallet('test-wallet', 'Test');
  await generateAddress('test-wallet');

  // 2. Shutdown LibSpiffy
  await libspiffy.shutdown();

  // 3. Restart with same database
  final newIsar = await Isar.open(
    [...LibSpiffySchemas.walletSchemas, EventEnvelopeSchema, SnapshotEnvelopeSchema],
    directory: testDir.path,
    name: 'test_db', // Same name
  );

  final newActorSystem = LocalActorSystem(ActorSystemConfig());
  final newLibspiffy = LibSpiffyActorSystem();
  await newLibspiffy.initialize(
    actorSystem: newActorSystem,
    isar: newIsar,
    dataDirectory: testDir.path,
  );

  // 4. Verify state recovered
  final addresses = await newLibspiffy.walletStorage.getAddresses('test-wallet');
  expect(addresses, isNotEmpty);
});
```

---

## Complete API Reference

### Core Message Types

#### 🟢 Public Wallet Messages

- **`CreateWalletMessage(String walletId, String name)`**  
  Creates a new event-sourced wallet

- **`GenerateAddressCommand`** (via `WalletCommandMessage`)  
  Generates a new HD-derived receive address

#### 🟢 Public Invoice Messages

- **`CreateInvoiceMessage`**  
  Creates a payment invoice with addresses
  - `walletId`: Target wallet
  - `amount`: Payment amount in satoshis
  - `description`: Invoice description (optional)
  - `expiresIn`: Expiration duration (optional)
  - `numberOfAddresses`: Number of payment addresses (default: 1)
  - `invoiceMetadata`: Custom metadata map (optional)

- **`CheckInvoiceMessage(String invoiceId)`**  
  Queries invoice status from read model

- **`ListInvoicesMessage(String? walletId)`**  
  Lists all invoices, optionally filtered by wallet

#### 🟡 Internal UTXO Commands (via `WalletCommandMessage`)

- **`ReceiveUTXOCommand`** - Records received UTXO (usually auto-called by SPV)
- **`SpendUTXOCommand`** - Marks UTXO as spent (usually auto-called on broadcast)
- **`ReserveUTXOsCommand`** - Reserves UTXOs for pending transaction
- **`ReleaseUTXOsCommand`** - Releases UTXO reservation
- **`CleanupExpiredReservationsCommand`** - Cleans up expired reservations (auto-called)

#### 🟡 Internal Invoice Commands

- **`MarkInvoicePaidMessage`** - Marks invoice as paid (usually auto-called by SPV)
  - `invoiceId`
  - `txid`: Payment transaction ID
  - `amountReceived`: Actual amount received
  - `addressesPaidTo`: List of paid addresses
  
- **`CancelInvoiceMessage(String invoiceId)`** - Cancels an invoice

#### 🟡 Internal SPV Messages

- **`ValidateTransactionMessage`** - Validates transaction with merkle proof
  - `tx`: BitcoinTransaction
  - `merkleProof`: BUMP or merkle path
  - `blockHeight`: Block height

- **`GetSPVStatusMessage()`** - Queries SPV sync status

- **`StoreHeaderMessage`** - Stores block header (usually auto-called)

---

### Response Message Types

#### 🟢 Public Responses

- **`WalletCreatedMessage`**  
  Fields: `walletId`, `name`, `success`, `error`

- **`AddressGeneratedResponse`**  
  Fields: `walletId`, `address`, `derivationIndex`, `success`, `error`, `metadata`

- **`InvoiceCreatedMessage`**  
  Fields: `invoiceId`, `walletId`, `addresses`, `amount`, `description`, `createdAt`, `expiresAt`, `success`, `error`

- **`InvoiceDetailsResponse`**  
  Fields: `invoiceId`, `walletId`, `addresses`, `amount`, `description`, `status`, `createdAt`, `expiresAt`, `paidAt`, `paymentTxid`, `found`, `error`

- **`InvoicesListMessage`**  
  Contains: `List<InvoiceDetailsResponse> invoices`

#### 🟡 Internal Responses

- **`InvoiceStatusMessage`**  
  Fields: `invoiceId`, `status`, `paidAt`, `txid`, `statusMessage`

- **`SPVStatusMessage`**  
  Fields: `headersSynced`, `bestHeight`, `bestHash`, `connectedPeers`

### Storage Interfaces

#### 🟢 ReadModelStorage (PUBLIC - Query Methods)

```dart
// Wallet queries
Future<List<BitcoinUtxo>> getUTXOs(String walletId)
Future<BigInt> getBalance(String walletId)
Future<List<String>> getAddresses(String walletId)
Future<List<BitcoinTransaction>> getWalletTransactions(String walletId)

// UTXO queries
Future<BitcoinUtxo?> getUTXO(String walletId, String txid, int vout)
Future<List<BitcoinUtxo>> getUnspentUTXOs(String walletId)

// Transaction queries
Future<BitcoinTransaction?> getTransaction(String walletId, String txid)

// Invoice queries
Future<Invoice?> getInvoice(String invoiceId)
Future<List<Invoice>> listInvoices(String walletId)
```

#### 🟡 ReadModelStorage (INTERNAL - Write Methods)

**⚠️ Only projections should write to read models**

CQRS Architecture ensures data integrity:
- **Commands** → Aggregates → **Events** (write side)
- **Events** → Projections → **Read Models** (read side)

The following write methods are **projection-only** and handle eventual consistency automatically:

```dart
// Wallet operations (projection use only)
Future<void> storeWallet(String walletId, String name, ...)
Future<void> deleteWallet(String walletId)

// UTXO operations (projection use only)  
// WalletProjection calls these after processing UTXOReceivedEvent
Future<void> upsertUTXO(String walletId, BitcoinUtxo utxo)  // ✅ NEW
Future<void> deleteUTXO(String walletId, String txid, int vout)  // ✅ NEW

// Transaction operations (import service and projection use)
Future<void> storeTransaction(String walletId, BitcoinTransaction tx)  // ✅ HYBRID

// Invoice operations (projection use only)
Future<void> storeInvoice(Invoice invoice)
Future<void> updateInvoiceStatus(String invoiceId, InvoiceStatus status, ...)
Future<void> deleteInvoice(String invoiceId)
```

**Eventual Consistency Timing:**
- UTXOs typically appear in read model within 100-300ms after command
- For critical flows, add delays: `await Future.delayed(Duration(milliseconds: 500))`
- Transaction imports: Wait longer for projection updates

---

### 🟢 Transaction Builder (PUBLIC)

```dart
class TransactionBuilder {
  // Input management
  void addInput({
    required BitcoinUtxo utxo,
    required UnlockingScriptBuilder unlockingScriptBuilder,
  })
  
  // Output management
  void addOutput({
    String? address,
    String? scriptPubKey,
    required BigInt amount,
  })
  
  void addChangeOutput({
    required String address,
    required int feeRate,
  })
  
  // Build final transaction
  BitcoinTransaction build()
}

// Script builders (PUBLIC)
class P2PKHUnlockingScriptBuilder extends UnlockingScriptBuilder {
  P2PKHUnlockingScriptBuilder({required SVPrivateKey privateKey});
}

// Extend for custom scripts (PUBLIC)
abstract class UnlockingScriptBuilder {
  String buildUnlockingScript(BitcoinTransaction tx, int inputIndex);
}
```

---

### 🟢 TransactionImportService (PUBLIC)

**Description:** Import historical transactions and harvest UTXOs using hybrid event sourcing approach. Essential for BEEF (SPV payment) construction.

**Architecture - Hybrid Event Sourcing:**

LibSpiffy uses a **hybrid approach** for historical transaction import:

1. **Reference Data (Transactions)** 
   - Raw transaction hex + merkle proofs stored directly in `ReadModelStorage`
   - Enables BEEF ancestor chain collection without event replay
   - Stored via `storeTransaction()` during import
   - Retrieved via `getTransaction(txid)` for payment construction

2. **Event-Sourced State (UTXOs)**
   - UTXOs harvested and sent as `ReceiveUTXOCommand` to `BitcoinWalletAggregate`
   - Aggregate emits `UTXOReceivedEvent` for full event sourcing integrity
   - Projections update read model asynchronously
   - Wallet state fully recoverable from event replay

**Why Hybrid?**
- ✅ Wallet state remains fully event-sourced and recoverable
- ✅ Transaction history available for BEEF without replaying thousands of events
- ✅ SPV validation works with confirmed historical transactions
- ✅ Eventual consistency: UTXOs appear in read model after projection updates

**Critical Flow:**
```
Import → Store TX + Merkle → Harvest UTXOs → Commands → Events → Projections → Read Model
         ↓                                     ↓
     Reference Data                    Event Sourcing
```

#### Import from Raw Transactions

```dart
// Prepare transactions with merkle proofs
final transactions = [
  ImportableTransaction(
    txid: '5e0ae9db2586ac8ea89b0f0eb628e1624ccfbdafff860052b67069a401d8ed71',
    rawHex: '0200000001...', // Full transaction hex
    blockHeight: 1291860,
    merkleProof: MerkleProof(
      blockHash: '',
      txid: '5e0ae9db...',
      merkleProof: ['a7026883...', '378e4682...', '04586929...'],
      position: 2,
      blockHeight: 1291860,
    ),
  ),
  // ... more transactions
];

// Import transactions
final result = await libspiffy.transactionImportService.importTransactions(
  walletId: walletId,
  transactions: transactions,
  walletAddresses: [address1, address2], // Addresses to check for outputs
);

// Check result
if (result.success) {
  print('✓ Imported ${result.transactionsImported} transactions');
  print('✓ Harvested ${result.utxosHarvested} UTXOs');
  print('Imported TXIDs: ${result.importedTxids}');
  print('Harvested UTXOs: ${result.harvestedUtxoIds}');
} else {
  print('✗ Import failed: ${result.error}');
}
```

#### Import from BEEF Package

```dart
// Import from received BEEF (e.g., from SPV payment)
final result = await libspiffy.transactionImportService.importFromBEEF(
  walletId: walletId,
  beefBytes: beefBytes, // Uint8List from BEEF.serialize()
  walletAddresses: [address1, address2],
);

if (result.success) {
  print('✓ Imported ${result.transactionsImported} transactions from BEEF');
}
```

#### Two-Phase UTXO Harvesting Algorithm

The `TransactionAnalyzer` uses a two-phase algorithm to correctly identify unspent outputs:

**Phase 1:** Identify ALL wallet outputs across all transactions
```dart
// Scans all transaction outputs
// Checks if output belongs to wallet (P2PKH address matching)
// Records: txid -> {vout -> satoshis}
```

**Phase 2:** Track which outputs are spent
```dart
// Scans all transaction inputs
// Marks outputs that are spent by subsequent transactions
// Records: txid -> {spent vout indexes}
```

**Result:** Only unspent outputs are harvested as UTXOs

This prevents:
- ❌ Double-counting (output received and spent in same import)
- ❌ Incorrect balance (showing already-spent UTXOs)
- ✅ Correct UTXO set after import

#### Dependency Sorting

Transactions are automatically sorted by dependency order (parents before children) using topological sort:

```dart
// Automatically handles chains like:
// TX1 (confirmed) → TX2 (spends TX1) → TX3 (spends TX2)

// Result: Processes TX1, then TX2, then TX3
// This ensures UTXOs are created before they're marked as spent
```

#### Event Sourcing Flow

```
ImportableTransaction (raw hex + merkle proof)
  ↓ Store
ReadModelStorage (merkle proofs - reference data)
  ↓ Parse & Analyze
TransactionAnalyzer (two-phase UTXO harvesting)
  ↓ Issue Commands
ReceiveUTXOCommand → BitcoinWalletAggregate
  ↓ Emit Events
UTXOReceivedEvent → EventStore (event-sourced state)
  ↓ Projection
WalletProjection → ReadModelStorage (UTXO records)
```

#### Get Wallet Addresses for Import

```dart
// Get addresses from wallet for import
final addresses = await libspiffy.walletStorage.getWalletAddresses(walletId);

// This queries existing UTXOs to extract unique addresses
// Alternatively, track addresses during address generation
```

#### Recovery Scenario

```dart
// 1. User loses device but has backup of xpriv
// 2. Restore wallet with seed
// 3. Fetch transaction history from blockchain API
// 4. Import transactions with merkle proofs
// 5. UTXOs harvested → wallet fully recovered

final transactions = await blockchainApi.getTransactionHistory(addresses);
final importable = transactions.map((tx) => ImportableTransaction(
  txid: tx.txid,
  rawHex: tx.hex,
  blockHeight: tx.blockHeight,
  merkleProof: tx.merkleProof,
)).toList();

final result = await libspiffy.transactionImportService.importTransactions(
  walletId: walletId,
  transactions: importable,
  walletAddresses: addresses,
);

// Wallet state fully recovered and event-sourced!
```

#### Integration with Payment Flow

```dart
// Receive BEEF payment from counterparty
final beefBytes = await receiveFromCounterparty();

// Import ancestor chain from BEEF
final importResult = await libspiffy.transactionImportService.importFromBEEF(
  walletId: walletId,
  beefBytes: beefBytes,
  walletAddresses: await libspiffy.walletStorage.getWalletAddresses(walletId),
);

// Now have full transaction history for SPV validation
// Can construct BEEF for own payments with complete ancestor chain
```

---

### Enums

```dart
// 🟢 PUBLIC
enum InvoiceStatus {
  pending,  // Invoice created, awaiting payment
  paid,     // Payment received and validated
  expired,  // Invoice expired without payment
  cancelled, // Invoice manually cancelled
}
```

---

## Best Practices

### 1. Always Use Actor Messaging for Commands

❌ **Don't** call internal methods directly:
```dart
// DON'T DO THIS
final wallet = BitcoinWalletAggregate(...);
wallet.onMessage(command);
```

✅ **Do** use actor messaging:
```dart
libspiffy.walletManager.tell(
  WalletCommandMessage(walletId, command),
  sender: receiver,
);
```

### 2. Query Read Models, Not Event Store

❌ **Don't** query EventStore:
```dart
// DON'T DO THIS
final events = await eventStore.loadEvents('BitcoinWallet_id');
// ... reconstruct state from events
```

✅ **Do** query read models:
```dart
final balance = await libspiffy.walletStorage.getBalance(walletId);
final utxos = await libspiffy.walletStorage.getUTXOs(walletId);
```

### 3. Handle Eventual Consistency

Projections update asynchronously. Use polling or event listeners:

```dart
// Wait for projection with retry
Future<T?> waitForReadModel<T>(
  Future<T?> Function() query,
  Duration timeout,
) async {
  final start = DateTime.now();
  while (DateTime.now().difference(start) < timeout) {
    final result = await query();
    if (result != null) return result;
    await Future.delayed(Duration(milliseconds: 100));
  }
  return null;
}
```

### 4. Use Unique Actor Names

Avoid actor name collisions in tests:

```dart
// Generate unique names
final receiver = await actorSystem.spawn(
  'receiver-${DateTime.now().millisecondsSinceEpoch}',
  () => TestReceiverActor(completer),
);
```

### 5. Clean Up Resources

Always call `shutdown()` in production and tests:

```dart
try {
  // Use LibSpiffy
} finally {
  await libspiffy.shutdown();
}
```

### 6. Use Metadata for Correlation

Track requests across async flows:

```dart
libspiffy.walletManager.tell(
  WalletCommandMessage(
    walletId,
    GenerateAddressCommand(
      walletId: walletId,
      metadata: {
        'requestId': myRequestId,
        'userId': currentUserId,
        'invoiceId': invoiceId, // For invoice-address correlation
      },
    ),
  ),
  sender: receiver,
);

// Response includes metadata
final response = await completer.future;
final invoiceId = response.metadata['invoiceId'];
```

---

## Support & Resources

- **Architecture:** See `wallet-architecture.md`
- **README:** See `README.md` for system overview
- **Eventador Docs:** See `eventador/README.md` for CQRS/Event Sourcing patterns
- **Issues:** Report bugs via GitHub issues
- **Examples:** See `example/` directory for full application samples

---

## Quick Reference Cheat Sheet

### 🟢 Most Common Operations

```dart
// Initialize LibSpiffy
await libspiffy.initialize(actorSystem: actorSystem, isar: isar, dataDirectory: './data');

// Create wallet
libspiffy.walletManager.tell(CreateWalletMessage(walletId, name), sender: receiver);

// Generate receive address
libspiffy.walletManager.tell(
  WalletCommandMessage(walletId, GenerateAddressCommand(walletId: walletId)),
  sender: receiver,
);

// Create invoice for payment
libspiffy.invoiceCoordinator.tell(
  CreateInvoiceMessage(walletId: walletId, amount: amount, description: desc),
  sender: receiver,
);

// Check invoice status
libspiffy.invoiceCoordinator.tell(CheckInvoiceMessage(invoiceId), sender: receiver);

// Query wallet balance
final balance = await libspiffy.walletStorage.getBalance(walletId);

// Get UTXOs
final utxos = await libspiffy.walletStorage.getUTXOs(walletId);

// Get invoice from read model
final invoice = await libspiffy.walletStorage.getInvoice(invoiceId);

// Build and sign transaction
final tx = TransactionBuilder()
  ..addInput(utxo: myUtxo, unlockingScriptBuilder: P2PKHUnlockingScriptBuilder(privateKey: key))
  ..addOutput(address: recipientAddress, amount: amount)
  ..addChangeOutput(address: changeAddress, feeRate: 50)
  ..build();

// Shutdown
await libspiffy.shutdown();
```

---

**Happy Building! 🚀**

