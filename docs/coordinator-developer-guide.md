# LibSpiffy Coordinator Developer Guide

## Who This Guide Is For

You are building an application that hosts LibSpiffy as its Bitcoin wallet engine. You want to create wallets, send and receive payments, validate transactions, and optionally use payment channels. You do not want to learn the internals of a 9-actor system to do it.

This guide covers the **Coordinator API** — the single, canonical interface that all host applications should use. If you find yourself importing internal message types (`CreateWalletMessage`, `PayInvoiceMessage`, `SPVValidationResult`) or telling individual actors directly, you are doing it wrong. The coordinator exists so that you do not have to.

## The Two Imports

LibSpiffy exposes two import paths. You will almost always use the first one.

```dart
// The public API — use this
import 'package:libspiffy/coordinator.dart';

// The internals — only if you need domain types (BigInt amounts, InvoiceOutputSpec, etc.)
import 'package:libspiffy/libspiffy.dart';
```

The coordinator import gives you command classes (what you send), event classes (what you receive), and the coordinator actor itself. The names are clean: `CreateWalletCommand`, `WalletCreatedEvent`, `PayInvoiceCommand`, `PaymentReadyEvent`.

The internal import gives you everything else: storage interfaces, crypto services, the actor system class, domain models. There is no naming collision between the two imports because the coordinator uses `Command`/`Event` suffixes while the internals use `Message`/`Response` suffixes.

## The Programming Model

Every interaction with LibSpiffy follows the same pattern:

1. **Send a command** to the coordinator via `tell()`
2. **Receive an event** on the coordinator's broadcast stream

There are no return values from `tell()`. There are no `Future`s to `await` on commands. There are no `Completer`s to wire up. You send a command, and sometime later — usually within milliseconds — an event appears on the stream.

```dart
// Send
coordinator.tell(CreateWalletCommand(walletId: 'w1', name: 'My Wallet'));

// Receive (sometime later)
coordinatorEvents.listen((event) {
  if (event is WalletCreatedEvent) {
    print('Created wallet ${event.walletId}, root address: ${event.rootAddress}');
  }
});
```

This is deliberate. Bitcoin wallet operations are inherently asynchronous — UTXO selection, ancestor chain collection, transaction signing, SPV validation, and network broadcasting all take variable time. The stream model matches the reality of the domain, and it eliminates the class of bugs that come from trying to make inherently async operations look synchronous.

### Queries Are Events Too

Even queries like "what is my balance" go through the same send-command/receive-event pattern. The coordinator reads directly from the CQRS read model (no actor routing for queries), so responses are fast — but they still arrive on the event stream.

```dart
coordinator.tell(GetBalanceQuery(walletId: 'w1'));

// On the stream:
if (event is BalanceResponse) {
  print('${event.confirmedBalance} confirmed, ${event.unconfirmedBalance} pending');
}
```

If you need to correlate a query response with a specific request, use the `queryId` field. It flows through to the response unchanged.

### Filtering the Stream

The event stream is a broadcast stream. Every event from every wallet appears on it. Filter by wallet ID or event type as needed:

```dart
// All events for one wallet
coordinatorEvents
    .where((e) => e.walletId == 'w1')
    .listen(handleWalletEvent);

// Just payment events
coordinatorEvents
    .whereType<PaymentReadyEvent>()
    .listen(handlePaymentReady);

// Just errors
coordinatorEvents
    .whereType<ErrorEvent>()
    .listen(handleError);
```

## Initialization

Before you can use the coordinator, you must initialize the `LibSpiffyActorSystem`. This creates the actor system, opens storage, spawns all internal actors, and optionally connects to the Bitcoin P2P network for header synchronization.

```dart
import 'package:libspiffy/libspiffy.dart';
import 'package:libspiffy/coordinator.dart';

final libspiffy = LibSpiffyActorSystem();

await libspiffy.initialize(
  dataDirectory: './wallet-data',
  networkType: 'test',              // 'main' for mainnet
  enableP2P: true,                  // Block header sync via P2P
  arcConfig: ArcServiceConfig.taalTestnet(),
  secureStorage: MyAppSecureStorage(), // You provide this
);

final coordinator = libspiffy.coordinator;
final events = libspiffy.coordinatorEvents;
```

### What the Host Application Must Provide

LibSpiffy handles Bitcoin mechanics. The host handles platform concerns:

**SecureStorage** (required for real wallets): An implementation of the `SecureStorage` interface that persists wallet private keys. LibSpiffy ships with `InMemorySecureStorage` for development, but production apps must provide platform-appropriate secure storage (iOS Keychain, Android Keystore, etc.).

**P2P Transport** (required for payment channels): If you use payment channels, the coordinator emits `ChannelP2PMessageToSendEvent` when it needs to send a protocol message to a peer. Your app must transmit this over whatever P2P layer you use (libp2p, WebSocket, HTTP, etc.) and feed incoming messages back via `ChannelP2PReceived`. The coordinator handles all protocol logic; you handle the transport.

**Isolate Management** (optional): If you want LibSpiffy to run in a separate isolate (recommended for mobile apps), you manage the isolate spawn and message serialization. The coordinator's commands and events are plain Dart objects — serialize them however you like for the isolate boundary.

### Storage Backend Options

LibSpiffy supports three storage backends:

```dart
// Mobile (default) — Isar embedded database
await libspiffy.initialize(storageBackend: StorageBackend.isar, ...);

// Server — PostgreSQL with connection pooling
await libspiffy.initialize(
  storageBackend: StorageBackend.postgres,
  postgresConfig: PostgresConfig(host: 'localhost', database: 'wallets', ...),
  ...
);

// Testing — in-memory, no persistence
await libspiffy.initialize(storageBackend: StorageBackend.inMemory, ...);
```

### Shared Isar Instance

If your app already uses Isar, share the instance to avoid opening multiple databases:

```dart
import 'package:libspiffy/libspiffy.dart';

final isar = await Isar.open([
  ...LibSpiffySchemas.walletSchemas, // LibSpiffy's schemas
  ...myAppSchemas,                    // Your app's schemas
]);

await libspiffy.initialize(isar: isar, ...);
```

## Wallet Lifecycle

### Creating a Wallet

```dart
coordinator.tell(CreateWalletCommand(
  walletId: 'primary',          // Your chosen ID (must be unique)
  name: 'Primary Wallet',
  // Provide ONE of: mnemonic, xpriv, wif, or xpub (watch-only)
  // If none provided, a new HD wallet is generated
));
```

The coordinator emits `WalletCreatedEvent` with `success`, `walletId`, and `rootAddress`. If creation fails (duplicate ID, invalid key material), `success` is false and `error` explains why.

### Importing an Existing Wallet

Import discovers addresses, fetches transaction history, and harvests UTXOs. It is a long-running operation.

```dart
coordinator.tell(ImportWalletCommand(
  walletId: 'imported',
  walletName: 'Restored Wallet',
  xpriv: 'xprv9s21ZrQH143K...',
  networkType: 'test',
  gapLimit: 20,                 // BIP44 gap limit for address discovery
));
```

During import, the coordinator emits `ImportProgressEvent` with phase, progress percentage, and counts. When finished, it emits `ImportCompleteEvent`.

```dart
events.listen((e) {
  if (e is ImportProgressEvent) {
    print('${e.phase}: ${(e.progress * 100).toInt()}%');
  } else if (e is ImportCompleteEvent) {
    if (e.success) {
      print('Imported ${e.addressCount} addresses, ${e.transactionCount} transactions');
    }
  }
});
```

Import requires a `blockchainDataSource` to be provided during initialization (e.g., `WhatsOnChainDataSource`). Without it, `ImportWalletCommand` will emit an error.

## Receiving Payments

LibSpiffy uses an invoice-based payment model. The receiver creates an invoice, shares it with the payer, and the payer sends a BEEF package to the invoice's addresses.

### Step 1: Create an Invoice

```dart
coordinator.tell(CreateInvoiceCommand(
  walletId: 'primary',
  amount: BigInt.from(50000),       // 50,000 satoshis
  description: 'Coffee order #42',
  expiresInSeconds: 3600,           // 1 hour
));
```

The coordinator generates a fresh address from the wallet, creates the invoice aggregate, and emits `InvoiceCreatedEvent`:

```dart
if (event is InvoiceCreatedEvent && event.success) {
  // Share these with the payer
  final paymentAddress = event.addresses.first;
  final amount = event.amount;
  final invoiceId = event.invoiceId;
}
```

### Step 2: Receive and Validate BEEF

When the payer sends you a BEEF package, validate it:

```dart
coordinator.tell(ValidateBEEFCommand(
  walletId: 'primary',
  beefHex: receivedBeefHexString,
  invoiceId: 'inv-123',            // Optional: correlate with invoice
));
```

This triggers a multi-step process that the coordinator manages internally:
1. Structural BEEF validation (correct format, valid transactions)
2. Full SPV validation (merkle proofs against stored block headers)
3. If valid, broadcast to the network via ARC
4. Update wallet UTXOs with received funds

You receive a single `BEEFValidationResultEvent`:

```dart
if (event is BEEFValidationResultEvent) {
  if (event.valid) {
    print('Payment valid! TX: ${event.txid}, broadcasted: ${event.broadcasted}');
  } else {
    print('Payment invalid: ${event.error}');
  }
}
```

The coordinator tracks the correlation between BEEF data, wallet ID, invoice ID, and SPV validation internally. You never need to manage these intermediate states.

## Sending Payments

### Step 1: Pay an Invoice

Given an invoice from a counterparty (their addresses and amount):

```dart
coordinator.tell(PayInvoiceCommand(
  walletId: 'primary',
  invoiceId: 'their-invoice-id',
  addresses: ['mRecipientAddress1'],
  amount: BigInt.from(50000),
  // Optional: structured outputs for multi-output payments
  outputs: [
    P2PKHOutputSpec(address: 'mRecipientAddr', amount: BigInt.from(50000)),
  ],
));
```

The coordinator handles everything internally:
1. Select UTXOs from the wallet to fund the payment
2. Collect the ancestor transaction chain (recursively, back to confirmed UTXOs with merkle proofs)
3. Build the payment transaction with proper inputs, outputs, and change
4. Sign the transaction using the wallet's private keys
5. Construct the BEEF package with ancestors and merkle proofs
6. Record the outgoing transaction in the wallet

You receive `PaymentReadyEvent` containing the BEEF bytes:

```dart
if (event is PaymentReadyEvent) {
  if (event.success) {
    // Send this BEEF to the counterparty via your P2P layer
    final beefToSend = event.beefBytes;
    print('BEEF ready: ${event.txid}, paid ${event.amountPaid} sats');
  } else {
    print('Payment failed: ${event.error}');
  }
}
```

**The coordinator does NOT broadcast the payment.** It returns the BEEF to you. You transmit it to the counterparty. The counterparty validates and broadcasts. This is the SPV payment model — the receiver broadcasts, not the sender.

### Multi-Output Payments and Plugin Outputs

Payments can include multiple output types. Standard types are built-in:

```dart
outputs: [
  P2PKHOutputSpec(address: 'addr1', amount: BigInt.from(40000)),
  P2MSOutputSpec(
    publicKeys: ['pubkey1', 'pubkey2'],
    requiredSignatures: 2,
    amount: BigInt.from(10000),
  ),
  OPReturnOutputSpec(dataChunks: [myDataBytes]),
]
```

For token protocols and custom script types, use the plugin system. Register your plugin at startup, then include `PluginOutputSpec` in payments. See the [Script Plugin API Guide](docs/script-plugin-api-guide.md) for the full plugin interface.

```dart
// After registering your plugin (see plugin guide):
outputs: [
  PluginOutputSpec(
    pluginId: 'tstoken',
    pluginScriptType: 'pp1_nft',
    params: {'tokenId': 'abc123', 'ownerPKH': 'def456'},
    amount: BigInt.from(546),
  ),
]
```

## Payment Channels

Payment channels enable high-frequency, low-latency payments between two parties without broadcasting every transaction. The coordinator manages the full channel lifecycle; the host application is responsible only for P2P message transport.

### Host Responsibilities

The coordinator does not know how to send network messages. When it needs to send a P2P protocol message to a peer, it emits `ChannelP2PMessageToSendEvent`. Your app must:

1. Listen for `ChannelP2PMessageToSendEvent` on the coordinator stream
2. Transmit the `payload` to `toPeerId` via your P2P layer
3. When a message arrives from a peer, feed it back to the coordinator

```dart
// Outgoing: coordinator → your P2P layer → peer
events.whereType<ChannelP2PMessageToSendEvent>().listen((msg) {
  myP2PLayer.send(msg.toPeerId, msg.messageType, msg.payload);
});

// Incoming: peer → your P2P layer → coordinator
myP2PLayer.onMessage((fromPeerId, messageType, payload) {
  coordinator.tell(ChannelP2PReceived(
    fromPeerId: fromPeerId,
    messageType: messageType,
    payload: payload,
  ));
});
```

That is the entire P2P contract. The coordinator handles the 11-message channel protocol internally.

### Opening a Channel (Client Side)

```dart
coordinator.tell(OpenChannelCommand(
  walletId: 'primary',
  serverPeerId: 'peer-abc-123',
  fundingAmountSats: 100000,
  lockTimeDurationSeconds: 86400,   // 24 hours
));
```

This initiates a multi-step protocol. The coordinator:
1. Generates a key pair and address for the channel
2. Emits a `ChannelP2PMessageToSendEvent` with the channel request (your app transmits it)
3. Waits for the server's acceptance (arrives via `ChannelP2PReceived`)
4. Builds the funding transaction
5. Builds the refund transaction (safety net)
6. Exchanges refund signatures with the server
7. Opens the channel

You receive `ChannelOpenedEvent` when the channel is ready:

```dart
if (event is ChannelOpenedEvent) {
  print('Channel ${event.channelId} open, funded with ${event.fundingAmountSats} sats');
}
```

### Accepting a Channel (Server Side)

When someone requests a channel with you, the coordinator emits `ChannelRequestReceivedEvent`. Present this to the user for approval:

```dart
if (event is ChannelRequestReceivedEvent) {
  // Show UI: "Peer ${event.clientPeerId} wants to open a channel for ${event.fundingAmountSats} sats"
  if (userApproves) {
    coordinator.tell(AcceptChannelCommand(
      channelId: event.channelId,
      walletId: 'primary',
      clientPeerId: event.clientPeerId,
      clientPubKey: event.clientPubKey,
      clientAddress: event.clientAddress,
      fundingAmountSats: event.fundingAmountSats,
      lockTimeUnix: event.lockTimeUnix,
    ));
  } else {
    coordinator.tell(RejectChannelCommand(
      channelId: event.channelId,
      reason: 'User declined',
    ));
  }
}
```

### Making Channel Payments

```dart
coordinator.tell(ChannelPayCommand(
  channelId: 'channel-abc',
  walletId: 'primary',
  amountSats: 1000,
  purpose: 'Stream payment',
));
```

Each payment emits `ChannelPaymentEvent` with updated balances.

### Closing a Channel

```dart
coordinator.tell(CloseChannelCommand(channelId: 'channel-abc'));
```

Emits `ChannelClosedEvent` with the settlement transaction ID.

## Utility Operations

### Benford UTXO Splitting

Split large UTXOs into smaller ones following Benford's Law distribution for privacy:

```dart
coordinator.tell(SplitUTXOsCommand(walletId: 'primary'));
```

Emits `UTXOSplitStartedEvent` followed by `UTXOSplitCompleteEvent`.

### Timestamp Archives

Embed data hashes on-chain via OP_RETURN:

```dart
coordinator.tell(TimestampCommand(
  archiveId: 'archive-001',
  walletId: 'primary',
  fileHashes: ['sha256-hash-of-document-1', 'sha256-hash-of-document-2'],
  archiveTitle: 'Q1 Financial Audit',
));
```

The coordinator creates an OP_RETURN transaction, broadcasts it, and emits `TimestampCompleteEvent` with the on-chain transaction ID.

### Watch Addresses

Monitor an external address for activity:

```dart
coordinator.tell(RegisterWatchAddressCommand(
  walletId: 'primary',
  address: 'mExternalAddress',
  scriptType: 'p2pkh',
  label: 'Partner deposit address',
));
```

## Error Handling

All errors arrive as `ErrorEvent` on the coordinator stream. The `source` field tells you which operation failed, and `walletId` (when present) tells you which wallet was affected.

```dart
events.whereType<ErrorEvent>().listen((error) {
  log.severe('[${error.source}] ${error.message}', error.walletId);
});
```

Additionally, most response events carry a `success` boolean and optional `error` string. Always check `success` before using the result:

```dart
if (event is PaymentReadyEvent) {
  if (!event.success) {
    showError('Payment failed: ${event.error}');
    return;
  }
  // Use event.beefBytes...
}
```

## Shutdown

Always shut down cleanly to flush pending operations and close storage:

```dart
coordinator.tell(ShutdownCommand());

// Then shut down the actor system
await libspiffy.shutdown();
```

## What Not To Do

These are the patterns we see from developers who bypass the coordinator. Each one leads to bugs, race conditions, or broken correlation tracking.

**Do not tell internal actors directly.** The coordinator tracks multi-step correlations (BEEF validation → SPV validation → broadcast → UTXO update). If you bypass it and tell the SPV actor directly, the coordinator loses track and your app will not receive the correct events.

```dart
// WRONG
libspiffy.spvActor.tell(ValidateBEEFMessage(...));

// RIGHT
coordinator.tell(ValidateBEEFCommand(...));
```

**Do not spawn receiver actors for responses.** The old API required spawning a `TestReceiverActor` with a `Completer` for every single operation. The coordinator eliminates this entirely — responses come on the event stream.

```dart
// WRONG (old pattern)
final completer = Completer<InvoiceCreatedMessage>();
final receiver = await actorSystem.spawn('recv', () => ReceiverActor(completer));
libspiffy.invoiceCoordinator.tell(CreateInvoiceMessage(...), sender: receiver);
final result = await completer.future;

// RIGHT (coordinator pattern)
coordinator.tell(CreateInvoiceCommand(...));
// Listen on events stream
```

**Do not manage BEEF/SPV correlation yourself.** The multi-step validation flow (structural validation → SPV validation → broadcast) involves correlation maps that the coordinator maintains. If you try to manage this yourself, you will lose track of which BEEF data belongs to which invoice.

**Do not import `package:libspiffy/coordinator.dart` and `package:libspiffy/libspiffy.dart` in the same file** if you reference any of the colliding names (`WalletCreatedEvent`, `InvoiceCreatedEvent`, `ChannelOpenedEvent`, etc.). Use one import per file, or prefix one of them:

```dart
import 'package:libspiffy/coordinator.dart';
import 'package:libspiffy/libspiffy.dart' as spiffy; // prefix to avoid collisions
```

## Integration with the Plugin System

The coordinator works transparently with registered plugins. When you include a `PluginOutputSpec` in a `PayInvoiceCommand`, the coordinator's internal payment flow calls the plugin's `createLockBuilder()` to produce the correct locking script. No special coordinator handling is needed — the plugin API is orthogonal to the coordinator API.

For the full plugin integration guide, including how to implement `ScriptPlugin` and `TransactionBuilderPlugin`, see the [Script Plugin API Guide](script-plugin-api-guide.md).

Key points for coordinator users:
- Register plugins **before** initializing LibSpiffy (or at least before creating transactions)
- Plugin-identified UTXOs carry `pluginMetadata` that you can query via `ReadModelStorage.getUTXOsByPlugin()`
- Use `PluginOutputSpec` in the `outputs` list of `PayInvoiceCommand` to include plugin outputs in payments
- The `ScriptTypeRegistry` (available via `libspiffy.dart`) delegates to your plugins for script identification

## Complete Event Reference

### Wallet Events
| Event | When Emitted |
|---|---|
| `WalletCreatedEvent` | Wallet creation completes (success or failure) |
| `ImportProgressEvent` | During wallet import (address discovery, TX fetch) |
| `ImportCompleteEvent` | Wallet import finishes |
| `WalletStatusEvent` | Status changes (refreshed, shutdown) |

### Query Responses
| Event | When Emitted |
|---|---|
| `BalanceResponse` | In response to `GetBalanceQuery` |
| `TransactionsResponse` | In response to `GetTransactionsQuery` |
| `TransactionDetailResponse` | In response to `GetTransactionDetailQuery` |

### Transaction Events
| Event | When Emitted |
|---|---|
| `TransactionReceivedEvent` | New transaction detected (incoming or outgoing) |
| `TransactionConfirmedEvent` | Transaction confirmed on-chain |
| `TransactionImportedEvent` | Transaction imported via `ImportTransactionCommand` |

### Payment Events
| Event | When Emitted |
|---|---|
| `InvoiceCreatedEvent` | Invoice created with payment addresses |
| `InvoicePaidEvent` | Invoice marked as paid |
| `PaymentReadyEvent` | BEEF constructed, ready to send to counterparty |

### Validation Events
| Event | When Emitted |
|---|---|
| `BEEFValidationResultEvent` | BEEF validation + SPV validation + broadcast complete |
| `SPVValidationResultEvent` | Standalone SPV validation result (no BEEF correlation) |

### Channel Events
| Event | When Emitted |
|---|---|
| `ChannelRequestReceivedEvent` | Peer wants to open a channel (show UI for approval) |
| `ChannelOpenedEvent` | Channel is open and ready for payments |
| `ChannelPaymentEvent` | Payment made or received on a channel |
| `ChannelClosedEvent` | Channel closed with settlement |
| `ChannelP2PMessageToSendEvent` | App must transmit this P2P message to a peer |

### Utility Events
| Event | When Emitted |
|---|---|
| `UTXOSplitStartedEvent` | Benford split operation started |
| `UTXOSplitCompleteEvent` | Benford split operation finished |
| `TimestampCompleteEvent` | OP_RETURN timestamp archive committed on-chain |
| `BlockHeadersStoredEvent` | Block headers stored |
| `WatchAddressRegisteredEvent` | Watch address registered |
| `HeaderSyncProgressEvent` | Block header sync progress (CDN or P2P) |

### Error Events
| Event | When Emitted |
|---|---|
| `ErrorEvent` | Any unhandled error in the coordinator |
