# LibSpiffy Developer Guide

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

The coordinator import gives you command classes (what you send), event classes (what you receive), and `WalletCoordinator`, which you send them with. The names are clean: `CreateWalletCommand`, `WalletCreatedEvent`, `PayInvoiceCommand`, `PaymentReadyEvent`.

The internal import gives you everything else: storage interfaces, crypto services, the actor system class, domain models. The two import together without a name clash. `package:libspiffy/internals.dart`, which exports the aggregates' own commands and events, does clash with `coordinator.dart` (`CreateWalletCommand`, `WalletCreatedEvent` and others exist in both): import it with a prefix if you need it.

## The Programming Model

`libspiffy.coordinator` is a `WalletCoordinator`. It has three methods:

1. **`ask(request)`** sends a command or query and returns its own reply.
2. **`tell(command)`** sends without waiting. The reply, if there is one, arrives on the event stream.
3. **`on<E>()`** follows one kind of event: what happens without a request, such as a balance change, an invoice paid, or a channel request from a peer.

```dart
final created = await coordinator.ask(CreateWalletCommand(walletId: 'w1', name: 'My Wallet', mnemonic: mnemonic));
print('Created wallet ${created.walletId}, root address: ${created.rootAddress}');

coordinator.on<BalanceUpdatedEvent>(walletId: 'w1').listen((event) {
  print('Balance now ${event.totalBalance} sats');
});
```

### Requests and Their Replies

Every command or query with an answer is a `CoordinatorRequest<R>`. It names its reply type `R`, and the coordinator answers it with exactly one `R`, on success and on failure. The request's `requestId` is fixed when the request is made, generated unless you give one. The reply carries it back, and so does an `ErrorEvent` the request causes. `ask` returns the reply with that id, whatever else is on the stream, so two payments running at once each get their own.

A returned reply is a success. A failure throws `CoordinatorFailure`:

```dart
try {
  final payment = await coordinator.ask(PayInvoiceCommand(
    walletId: 'w1',
    invoiceId: invoice.invoiceId,
    addresses: invoice.addresses,
    amount: invoice.amount,
  ));
  send(payment.beefBytes);
} on CoordinatorFailure catch (failure) {
  // failure.message: why. failure.event: the reply that reported it
  // (a PaymentReadyEvent with success false here) or an ErrorEvent.
  // failure.closed: the coordinator stopped before it answered.
  showError(failure.message);
}
```

`ask` throws `TimeoutException` when no reply arrives within the request's `replyTimeout` (pass `timeout:` to change it). Each request has a default that covers its own work: a minute for most, longer for a payment, a receive, a broadcast, a split or an import. **A timeout does not cancel the request.** It may still finish (a payment it validated may already be broadcast), and its reply then arrives on the event stream only.

### The Event Stream

Replies are published on the event stream too, with everything else the coordinator reports. `coordinator.on<E>({walletId})` gives the events of one type, of one wallet when you name it. `libspiffy.coordinatorEvents` is the whole stream:

```dart
coordinator.on<InvoicePaidEvent>(walletId: 'w1').listen(handleInvoicePaid);
coordinator.on<ChannelRequestReceivedEvent>().listen(askTheUser);
libspiffy.coordinatorEvents!.listen(logEverything);
```

A reply type is also emitted without a request where something else caused it: a payment replayed when its block header arrived, a peer's batch of headers. Its `requestId` is null then.

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
```

### Ready Before the Headers Are

The coordinator takes commands before the block headers are synced: creating or importing a wallet needs no chain, and a received payment whose block header has not arrived yet waits for it, then completes. From far behind (a first start with no header CDN) the sync from peers can take minutes. To show it, or to wait for it, ask where it stands and listen for the change:

```dart
coordinator.on<HeaderSyncStatusEvent>().listen((event) {
  // event.status.synced: caught up with the peers, or fell behind them
});
coordinator.on<BlockHeadersStoredEvent>().listen((event) {
  // each batch stored: event.endHeight of event.source ('p2p' for peers)
});

final status = (await coordinator.ask(GetHeaderSyncStatusQuery())).status;
// HeaderSyncStatus(height, networkHeight, synced, peerCount)
```

`synced` turns true when a peer answers header sync with less than a full batch: it had nothing more. `networkHeight` is the best height the connected peers reported, for a progress bar; 0 while no peer has reported one. `peerCount` is 0 when P2P is off or every peer has dropped.

### What the Host Application Must Provide

LibSpiffy handles Bitcoin mechanics. The host handles platform concerns:

**SecureStorage** (required for real wallets): An implementation of the `SecureStorage` interface that persists wallet private keys. LibSpiffy ships with `InMemorySecureStorage` for development, but production apps must provide platform-appropriate secure storage (iOS Keychain, Android Keystore, etc.).

**P2P Transport** (required for payment channels and merkle-proof requests): the coordinator emits `P2PMessageToSendEvent` when it needs to send a protocol message to a peer: a payment channel message, or a `proof_request`/`proof_response` asking a counterparty for a fresh proof or answering one. Your app must transmit this over whatever P2P layer you use (libp2p, WebSocket, HTTP, etc.) and feed incoming messages back via `P2PMessageReceived`. The coordinator handles all protocol logic; you handle the transport.

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

// Testing — read models in memory; the event journal is still an Isar store
// in dataDirectory, and the projections rebuild from it on start
await libspiffy.initialize(storageBackend: StorageBackend.inMemory, dataDirectory: tempDir, ...);
```

### Shared Isar Instance

If your app already uses Isar, share the instance to avoid opening multiple databases:

```dart
import 'package:isar_community/isar.dart';
import 'package:libspiffy/libspiffy.dart';

final isar = await Isar.open(
  [
    ...LibSpiffySchemas.allSchemas, // LibSpiffy read models + event store + queue collections
    ...myAppSchemas,                 // Your app's schemas
  ],
  directory: dataDirectory,
);

await libspiffy.initialize(isar: isar, ...);
```

## Wallet Lifecycle

### Creating a Wallet

```dart
final created = await coordinator.ask(CreateWalletCommand(
  walletId: 'primary',          // Your chosen ID (must be unique)
  name: 'Primary Wallet',
  mnemonic: mnemonic,           // ONE of: mnemonic, xpriv, wif, or xpub (watch-only)
));
```

libspiffy generates no keys: the app supplies the key material and backs it up. `DartSVCryptoService().generateMnemonic()` makes a new mnemonic.

The reply, `WalletCreatedEvent`, comes once the read model holds the wallet, with its `rootAddress`. A creation that fails (duplicate ID, invalid key material) throws `CoordinatorFailure` saying why.

### Importing an Existing Wallet

Import discovers addresses, fetches transaction history, and harvests UTXOs. It is a long-running operation.

```dart
final progress = coordinator.on<ImportProgressEvent>(walletId: 'imported').listen((e) {
  print('${e.phase}: ${(e.progress * 100).toInt()}%');
});
final imported = await coordinator.ask(ImportWalletCommand(
  walletId: 'imported',
  walletName: 'Restored Wallet',
  xpriv: 'xprv9s21ZrQH143K...',  // or mnemonic:, or wif:
  networkType: 'test',
  gapLimit: 20,                 // BIP44 gap limit for address discovery
));
await progress.cancel();
print('Imported ${imported.addressCount} addresses, ${imported.transactionCount} transactions');
```

The import ends with `ImportCompleteEvent`; `ImportProgressEvent` reports the phases on the way. A successful import with `transactionsFailed` above zero is incomplete: send it again with `resume: true`. A mnemonic wallet is created from the mnemonic and then imported, as an xpriv is.

Import requires a `blockchainDataSource` to be provided during initialization (e.g., `WhatsOnChainDataSource`). Without it, `ImportWalletCommand` fails.

## Receiving Payments

LibSpiffy uses an invoice-based payment model. The receiver creates an invoice, shares it with the payer, and the payer sends a BEEF package to the invoice's addresses.

### Step 1: Create an Invoice

```dart
final invoice = await coordinator.ask(CreateInvoiceCommand(
  walletId: 'primary',
  amount: BigInt.from(50000),       // 50,000 satoshis
  description: 'Coffee order #42',
  expiresInSeconds: 3600,           // 1 hour
));

// Share these with the payer
final paymentAddress = invoice.addresses.first;
final amount = invoice.amount;
final invoiceId = invoice.invoiceId;
```

The coordinator generates a fresh address from the wallet and creates the invoice; the reply is `InvoiceCreatedEvent`.

### Step 2: Receive and Validate BEEF

When the payer sends you a BEEF package, validate it:

```dart
final request = ValidateBEEFCommand(
  walletId: 'primary',
  beefHex: receivedBeefHexString,
  invoiceId: 'inv-123',            // Optional: correlate with invoice
);
final verdict = await coordinator.ask(request);
```

This triggers a multi-step process that the coordinator manages internally:
1. Structural BEEF validation (correct format, valid transactions)
2. Full SPV validation (merkle proofs against stored block headers)
3. If valid, broadcast to the network via ARC
4. Update wallet UTXOs with received funds

The reply is one `BEEFValidationResultEvent`; an invalid payment throws `CoordinatorFailure` instead. A payment whose block header has not arrived yet is not decided: the reply says `awaitingHeader`, and the verdict follows as a second `BEEFValidationResultEvent` with the same `requestId` once the header arrives:

```dart
if (verdict.awaitingHeader) {
  final decided = await coordinator
      .on<BEEFValidationResultEvent>()
      .firstWhere((e) => e.requestId == request.requestId && !e.awaitingHeader);
  // decided.valid, or decided.failure says why not
} else {
  print('Payment valid! TX: ${verdict.txid}, broadcasted: ${verdict.broadcasted}');
}
```

A restart while it waits replays the payment from storage when the header arrives; that verdict carries no `requestId`.

The coordinator tracks the correlation between BEEF data, wallet ID, invoice ID, and SPV validation internally. You never need to manage these intermediate states.

### Receiving for an Offline Payee

A service can take payments for users who are offline (spv-understanding.md, "Payment modes"). The user registers their xpub, and the service keeps it as a watch-only wallet:

```dart
await coordinator.ask(CreateWalletCommand(walletId: 'carol-at-service', name: 'Carol', xpub: carolXpub));
```

Invoices on that wallet get addresses on the user's **delegated chain** (`m/2/i`), never on the receive chain (`m/0/i`) the user's own wallet issues from. The invoice says which it is: `InvoiceCreatedEvent.issuedAddresses` gives each address with its chain and derivation index.

```dart
final issued = invoiceCreated.issuedAddresses.single;
issued.chain;            // AddressChain.delegated: a payment to hand over later
issued.derivationIndex;  // the index the user's wallet will need
```

The service receives the payment with `ValidateBEEFCommand` as usual. The money appears as `watchOnlyBalance`: the service holds no key for it and can never spend it. Once the payment is mined, the service exports it with its proof and the delegated indices it pays:

```dart
final exported = await coordinator.ask(ExportTransactionQuery(walletId: 'carol-at-service', txid: txid));
// TransactionExportedEvent(beef, delegatedIndices); refused while the
// transaction has no proof on our header chain
```

It hands both to the user. The user's wallet imports the BEEF with those indices. It derives the addresses from its own key, records them, and can then spend the payment like any other:

```dart
await coordinator.ask(ImportTransactionCommand(
  walletId: 'carol',
  beef: exported.beef!,
  delegatedIndices: exported.delegatedIndices,
));
// TransactionImportedEvent
```

Without the index the import is refused: the payment pays none of the wallet's addresses, so it is not the wallet's transaction.

### Paying an Offline Payee Directly (Type-42)

A payer can pay a payee that is offline with no service in between (spv-understanding.md, "Payment modes"). The payee publishes a public key, its **anchor key**, and the payer derives a fresh address from it for every payment with BRC-42 ("type-42").

The payee's side, once per identity: issue the anchor for that identity and publish it, bound to the identity. The **anchor context** is opaque bytes of your choosing. A wallet issues one anchor per context, so identities sharing a wallet publish unrelated anchors. Put a rotation epoch in the context (`identityKey ‖ epoch`, say) to be able to retire an anchor: bump the epoch and publish the new anchor with it. An empty context is refused. An xpub wallet and a WIF wallet have no anchors.

```dart
final context = [...identityKey, ...epochBytes];
final anchor = await coordinator.ask(IssueAnchorKeyCommand(walletId: 'carol', anchorContext: context));
// anchor.publicKey; the same context always gives the same anchor

final signed = await coordinator.ask(SignWithAnchorKeyCommand(
  walletId: 'carol',
  anchorContext: context,
  message: utf8.encode('overmedia:register_payment_pubkey:$peerId:$anchorKey'),
));
// signed.signatureDer: ECDSA over SHA-256(message) by signed.publicKey
```

The payer's side: derive a destination, pay it, broadcast it yourself (the payee is not there to), and hand it over once it is mined.

```dart
final destination = (await coordinator.ask(DeriveType42DestinationCommand(
  walletId: 'alice',
  anchorPublicKey: anchorKey,
  anchorContext: publishedContext, // the context published with the anchor, when there is one
))).destination!;

final payment = await coordinator.ask(PayInvoiceCommand(
  walletId: 'alice',
  invoiceId: destination.derivation.invoiceNumber,
  addresses: [destination.address],
  amount: BigInt.from(40000),
));
await coordinator.ask(BroadcastDeferredPaymentCommand(walletId: 'alice', txid: payment.txid));
// ... TransactionConfirmedEvent once it is mined, then:
final exported = await coordinator.ask(ExportTransactionQuery(walletId: 'alice', txid: payment.txid));
// exported.beef, exported.type42Derivations
```

Hand `beef` and `type42Derivations` to the payee out of band. Each derivation names the anchor, its context (when the payer passed it), the payer key and the invoice number. The payee's wallet imports them. It finds the anchor among those it issued, or derives it from the context, and refuses a context that does not give that anchor. It then derives each address from its own anchor key, records the derivation (never a private key), and can spend the payment like any other:

```dart
await coordinator.ask(ImportTransactionCommand(
  walletId: 'carol',
  beef: exported.beef!,
  type42Derivations: exported.type42Derivations,
));
```

If the payee is online before the payment is mined, it can take it in unproven, as any payment handed to it: `ValidateBEEFCommand(..., type42Derivations: [destination.derivation])`.

**Recovery has a limit.** A type-42 output cannot be found from the seed. A wallet restored from its journal keeps it. A wallet restored from its seed alone does not see it: the import without the derivations is refused as unrelated. Keep the payer's hand-off, and give it again to recover the payment. A restored wallet has issued no anchors yet, so the hand-off must name the anchor's context, or the app issues its anchors again first.

## Sending Payments

### Step 1: Pay an Invoice

Given an invoice from a counterparty (their addresses and amount):

```dart
final payment = await coordinator.ask(PayInvoiceCommand(
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

The reply, `PaymentReadyEvent`, carries the BEEF bytes; a payment that could not be built throws `CoordinatorFailure` saying why:

```dart
// Send this BEEF to the counterparty via your P2P layer
final beefToSend = payment.beefBytes;
print('BEEF ready: ${payment.txid}, paid ${payment.amountPaid} sats');
```

**The coordinator does NOT broadcast the payment.** It returns the BEEF to you. You transmit it to the counterparty. The counterparty validates and broadcasts. This is the SPV payment model — the receiver broadcasts, not the sender.

### Multi-Output Payments and Plugin Outputs

Payments can include multiple output types. Standard types are built-in:

```dart
outputs: [
  P2PKHOutputSpec(address: 'addr1', amount: BigInt.from(40000)),
  P2MSOutputSpec(
    publicKeys: ['pubkey1', 'pubkey2'],
    threshold: 2,
    amount: BigInt.from(10000),
  ),
  OPReturnOutputSpec(dataChunks: [myDataBytes]),
]
```

For token protocols and custom script types, use the plugin system. Register your plugin at startup, then include `PluginOutputSpec` in payments. See the [Script Plugin API Guide](script-plugin-api-guide.md) for the full plugin interface.

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

The coordinator does not know how to send network messages. When it needs to send a P2P protocol message to a peer, it emits `P2PMessageToSendEvent`. Your app must:

1. Listen for `P2PMessageToSendEvent` on the coordinator stream
2. Transmit the `payload` to `toPeerId` via your P2P layer
3. When a message arrives from a peer, feed it back to the coordinator

```dart
// Outgoing: coordinator → your P2P layer → peer
coordinator.on<P2PMessageToSendEvent>().listen((msg) {
  myP2PLayer.send(msg.toPeerId, msg.messageType, msg.payload);
});

// Incoming: peer → your P2P layer → coordinator
myP2PLayer.onMessage((fromPeerId, messageType, payload) {
  coordinator.tell(P2PMessageReceived(
    fromPeerId: fromPeerId,
    messageType: messageType,
    payload: payload,
  ));
});
```

That is the entire P2P contract. The coordinator routes each incoming message by `messageType` and handles the 11-message channel protocol and the proof protocol internally.

A node takes part in channels only when `initialize()` is given `channelTiming` (when a channel stops taking payments and settles, and how long it must run; the library supplies no default) and `channelPeerId` (this node's own peer id on your transport):

```dart
await libspiffy.initialize(
  channelTiming: ChannelTiming(
    settlementMargin: Duration(hours: 1),
    minimumLifetime: Duration(hours: 2),
  ),
  channelPeerId: myPeerId,
  ...
);
```

### Opening a Channel (Client Side)

```dart
final channel = await coordinator.ask(OpenChannelCommand(
  walletId: 'primary',
  serverPeerId: 'peer-abc-123',
  fundingAmountSats: 100000,
  lockTimeDurationSeconds: 86400,   // 24 hours
));
```

This initiates a multi-step protocol. The coordinator:
1. Generates a key pair and address for the channel
2. Emits a `P2PMessageToSendEvent` with the channel request (your app transmits it)
3. Waits for the server's acceptance (arrives via `P2PMessageReceived`)
4. Builds the funding transaction
5. Builds the refund transaction (safety net)
6. Exchanges refund signatures with the server
7. Opens the channel

The reply is the channel's `ChannelOpenedEvent`, once it is ready; a step that fails, or the server's refusal, throws `CoordinatorFailure`. The default timeout is five minutes, since the open waits for the server:

```dart
print('Channel ${channel.channelId} open, funded with ${channel.fundingAmountSats} sats');
```

### Accepting a Channel (Server Side)

When someone requests a channel with you, the coordinator emits `ChannelRequestReceivedEvent`. Present this to the user for approval:

```dart
coordinator.on<ChannelRequestReceivedEvent>().listen((event) async {
  // Show UI: "Peer ${event.clientPeerId} wants to open a channel for ${event.fundingAmountSats} sats"
  if (await userApproves(event)) {
    await coordinator.ask(AcceptChannelCommand(
      channelId: event.channelId,
      walletId: 'primary',
      clientPeerId: event.clientPeerId,
      clientPubKey: event.clientPubKey,
      clientAddress: event.clientAddress,
      fundingAmountSats: event.fundingAmountSats,
      lockTimeUnix: event.lockTimeUnix,
    ));
    // ChannelAcceptedEvent: accepted; the channel opens when the client
    // funds it (a ChannelOpenedEvent on this side too)
  } else {
    await coordinator.ask(RejectChannelCommand(
      channelId: event.channelId,
      reason: 'User declined',
    ));
  }
});
```

### Making Channel Payments

```dart
final paid = await coordinator.ask(ChannelPayCommand(
  channelId: channel.channelId,
  walletId: 'primary',
  amountSats: 1000,
  purpose: 'Stream payment',
));
```

The reply is the payment's `ChannelPaymentEvent`, with the updated balances, once the channel has journaled it and handed `payment_update` to your transport. A payment the channel refuses (more than the client's balance) throws. The server's own payments arrive as `ChannelPaymentEvent`s on its stream.

### Closing a Channel

```dart
final closed = await coordinator.ask(CloseChannelCommand(channelId: channel.channelId));
```

The reply is `ChannelClosedEvent`, with the settlement transaction ID, once the server's settlement is recorded.

## Utility Operations

### Benford UTXO Splitting

Split large UTXOs into smaller ones following Benford's Law distribution for privacy:

```dart
final split = await coordinator.ask(SplitUTXOsCommand(walletId: 'primary'));
```

The reply is `UTXOSplitCompleteEvent`; `UTXOSplitStartedEvent` announces the start on the stream.

### Timestamp Archives

Embed data hashes on-chain via OP_RETURN:

```dart
final stamp = await coordinator.ask(TimestampCommand(
  archiveId: 'archive-001',
  walletId: 'primary',
  fileHashes: ['sha256-hash-of-document-1', 'sha256-hash-of-document-2'],
  archiveTitle: 'Q1 Financial Audit',
));
```

The coordinator creates an OP_RETURN transaction, broadcasts it, and answers with ARC's answer: `TimestampCompleteEvent` with the transaction ID, or a failure when ARC refused it.

### Watch Addresses

Label outputs paying an address the wallet holds no key for. This is not monitoring: nothing is fetched from the network. It only changes how the wallet records outputs to that address in transactions it receives. They are kept, reported as `watchOnlyBalance`, and never spent:

```dart
await coordinator.ask(RegisterWatchAddressCommand(
  walletId: 'primary',
  address: 'mExternalAddress',
  scriptType: 'p2pkh',
  label: 'Partner deposit address',
));
```

## Error Handling

A request's failure is its own: `ask` throws `CoordinatorFailure`, whose `event` is the reply that reported it or an `ErrorEvent` naming the request. With `tell`, read the reply's `failure` (`CoordinatorReply.failure`): the reason, or null when it succeeded. A request whose failure is reported as an `ErrorEvent` (a channel step, for one) has that event carry its `requestId`.

Failures no request caused (a channel step the counterparty started, a broadcast retried later) arrive as `ErrorEvent` with no `requestId`. The `source` field tells you what failed, and `walletId` (when present) which wallet:

```dart
coordinator.on<ErrorEvent>().listen((error) {
  log.severe('[${error.source}] ${error.message}', error.walletId);
});
```

## Shutdown

Always shut down cleanly to flush pending operations and close storage:

```dart
await libspiffy.shutdown();
```

A request still waiting when the coordinator stops fails with `CoordinatorFailure` (`closed`).

## What Not To Do

These are the patterns we see from developers who bypass the coordinator. Each one leads to bugs, race conditions, or broken correlation tracking.

**Do not tell internal actors directly.** The coordinator tracks multi-step correlations (BEEF validation → SPV validation → broadcast → UTXO update). If you bypass it and tell the SPV actor directly, the coordinator loses track and your app will not receive the correct events.

```dart
// WRONG
libspiffy.spvActor.tell(ValidateBEEFMessage(...));

// RIGHT
await coordinator.ask(ValidateBEEFCommand(...));
```

**Do not spawn receiver actors, or match replies on the stream yourself.** The old API required spawning a `TestReceiverActor` with a `Completer` for every single operation, and apps then wrote their own "send, then find the reply on the stream" helpers. `ask` does both.

```dart
// WRONG (old pattern)
final completer = Completer<InvoiceCreatedMessage>();
final receiver = await actorSystem.spawn('recv', () => ReceiverActor(completer));
libspiffy.invoiceCoordinator.tell(CreateInvoiceMessage(...), sender: receiver);
final result = await completer.future;

// RIGHT (coordinator pattern)
final invoice = await coordinator.ask(CreateInvoiceCommand(...));
```

**Do not manage BEEF/SPV correlation yourself.** The multi-step validation flow (structural validation → SPV validation → broadcast) involves correlation maps that the coordinator maintains. If you try to manage this yourself, you will lose track of which BEEF data belongs to which invoice.

## Integration with the Plugin System

The coordinator works transparently with registered plugins. When you include a `PluginOutputSpec` in a `PayInvoiceCommand`, the coordinator's internal payment flow calls the plugin's `createLockBuilder()` to produce the correct locking script. No special coordinator handling is needed — the plugin API is orthogonal to the coordinator API.

For the full plugin integration guide, including how to implement `ScriptPlugin` and `TransactionBuilderPlugin`, see the [Script Plugin API Guide](script-plugin-api-guide.md).

Key points for coordinator users:
- Register plugins **before** initializing LibSpiffy (or at least before creating transactions)
- Plugin-identified UTXOs carry `pluginMetadata` that you can query via `ReadModelStorage.getUTXOsByPlugin()`
- Use `PluginOutputSpec` in the `outputs` list of `PayInvoiceCommand` to include plugin outputs in payments
- The `ScriptTypeRegistry` (available via `libspiffy.dart`) delegates to your plugins for script identification

## Complete Event Reference

### Requests and Their Replies

Every command and query below is answered with one reply of the type named, carrying its `requestId`: what `ask` returns.

| Request | Reply |
|---|---|
| `CreateWalletCommand` | `WalletCreatedEvent` |
| `DeleteWalletCommand` | `WalletDeletedEvent` |
| `ImportWalletCommand` | `ImportCompleteEvent` (progress: `ImportProgressEvent`) |
| `GetBalanceQuery` | `BalanceResponse` |
| `GetTransactionsQuery` | `TransactionsResponse` |
| `GetTransactionDetailQuery` | `TransactionDetailResponse` |
| `ExportTransactionQuery` | `TransactionExportedEvent`: a proven transaction as BEEF, with its delegated indices and type-42 derivations |
| `CreateInvoiceCommand` | `InvoiceCreatedEvent` |
| `PayInvoiceCommand` | `PaymentReadyEvent` |
| `ProvisionFundingCommand` | `ProvisioningCompleteEvent` |
| `ValidateBEEFCommand` | `BEEFValidationResultEvent` |
| `RecordOutgoingCommand` | `TransactionRecordedEvent` |
| `ImportTransactionCommand` | `TransactionImportedEvent` |
| `SettleBEEFCommand` | `BEEFSettledEvent` |
| `IssueAnchorKeyCommand` | `AnchorPublicKeyEvent` |
| `SignWithAnchorKeyCommand` | `AnchorSignedEvent` |
| `Brc100KeyOperationCommand` | `Brc100KeyOperationEvent` |
| `DeriveType42DestinationCommand` | `Type42DestinationEvent`: an address to pay and its hand-off |
| `GenerateAddressCommand` | `AddressGeneratedEvent` |
| `RegisterWatchAddressCommand` | `WatchAddressRegisteredEvent` |
| `ReleaseUTXOsCommand` | `UTXOsReleasedEvent` |
| `SplitUTXOsCommand` | `UTXOSplitCompleteEvent` |
| `TimestampCommand` | `TimestampCompleteEvent` |
| `StoreHeadersCommand` | `BlockHeadersStoredEvent` |
| `GetHeaderSyncStatusQuery` | `HeaderSyncStatusResponse` |
| `GetDeferredPaymentsQuery` | `DeferredPaymentsResponse` |
| `BroadcastDeferredPaymentCommand` | `DeferredPaymentBroadcastEvent` |
| `CheckDeferredPaymentStatusCommand` | `DeferredPaymentStatusEvent` |
| `CancelDeferredPaymentCommand` | `DeferredPaymentCancelledEvent` |
| `ReclaimDeferredPaymentCommand` | `DeferredPaymentReclaimedEvent` |
| `CompleteDeferredPaymentCommand` | `DeferredPaymentCompletedEvent` |
| `CheckForeignSpendsCommand` | `ForeignSpendsCheckedEvent` |
| `RequestAncestorProofCommand` | `AncestorProofRequestedEvent` |
| `OpenChannelCommand` | `ChannelOpenedEvent` |
| `AcceptChannelCommand` | `ChannelAcceptedEvent` |
| `RejectChannelCommand` | `ChannelRejectedEvent` |
| `ChannelPayCommand` | `ChannelPaymentEvent` |
| `CloseChannelCommand` | `ChannelClosedEvent` |
| `ExpireChannelCommand` | `ChannelExpiredEvent` |
| `ClaimChannelRefundCommand` | `ChannelRefundClaimedEvent` |
| `RetryChannelFundingCommand` | `ChannelFundingRetriedEvent` |
| `ResendChannelOpenCommand` | `ChannelOpenResentEvent` |

`ShutdownCommand` and `P2PMessageReceived` are told; they have no reply.

The tables below are the events the coordinator emits without a request, and the replies' types when they are emitted that way.

### Wallet Events
| Event | When Emitted |
|---|---|
| `ImportProgressEvent` | During wallet import (address discovery, TX fetch) |
| `WalletStatusEvent` | The coordinator shut down |

### Transaction Events
| Event | When Emitted |
|---|---|
| `TransactionConfirmedEvent` | Transaction confirmed on-chain |
| `TransactionConfirmationRevertedEvent` | A reorganization took the proof of a confirmation away |
| `TransactionImportedEvent` | A transaction received that nobody requested: a proven foreign spender, a proof response |
| `BalanceUpdatedEvent` | A wallet's balance changed |

### Payment Events
| Event | When Emitted |
|---|---|
| `InvoicePaidEvent` | Invoice marked as paid |

### Validation Events
| Event | When Emitted |
|---|---|
| `BEEFValidationResultEvent` | A payment that waited for its block header is decided |
| `SPVValidationResultEvent` | Standalone SPV validation result (no BEEF correlation) |

### Channel Events
| Event | When Emitted |
|---|---|
| `ChannelRequestReceivedEvent` | Peer wants to open a channel (show UI for approval) |
| `ChannelOpenedEvent` | A channel this node serves is open |
| `ChannelPaymentEvent` | A payment received on a channel this node serves |
| `ChannelClosedEvent` | A channel closed by the counterparty or the settlement timer |
| `P2PMessageToSendEvent` | App must transmit this P2P message to a peer |

### Utility Events
| Event | When Emitted |
|---|---|
| `UTXOSplitStartedEvent` | Benford split operation started |
| `BlockHeadersStoredEvent` | A batch of block headers a peer sent, stored |
| `HeaderSyncStatusEvent` | Header sync caught up with its peers, or fell behind them |

### Error Events
| Event | When Emitted |
|---|---|
| `ErrorEvent` | A failure with no reply of its own; `requestId` names the request that caused it, if one did |
