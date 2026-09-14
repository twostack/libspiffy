## Unreleased

Test-coverage and follow-up fixes for the 2.0.0 audit. Every finding marked
fixed in `doc/audit-2026-09-14.md` now has a regression test that was shown
to fail with the fix reverted and pass with it applied (report section 2,
`Test` rows). Writing those tests found five more defects (report section
11), all fixed here:

- **Mainnet wallets could not sign after output scanning, and the wallet
  projection threw on imported mainnet transactions.** Both sites built the
  process-wide `ScriptTypeRegistry` with the testnet default (V-1).
- **`networkType: 'mainnet'` still selected testnet** for the default ARC
  endpoint, the CDN, P2P magic and seed peers, and for key derivation in
  the importer and address discovery. All remaining literal `'main'`
  comparisons go through `NetworkName` (V-2).
- **An address generated without a label could not be signed for** via the
  aggregate state lookup (V-3).
- The Postgres test suite is re-runnable after the uint32-nonce test (V-4).

API additions (no behaviour change): `PaymentCoordinatorActor(reservationReplyTimeout:)`
(default 10 s), `LibSpiffyActorSystem.arcConfig`,
`CdnHeaderSyncService.cacheFilePath` (`@visibleForTesting`),
`PostgresEventStore.beforeReplayQuery` / `afterReplayQuery` (`@visibleForTesting`).

### Audit backlog, wave 1

Fixes for the open P0/P1 audit findings, each with a regression test shown
to fail on the previous code (report `Test` rows).

- **S-01 (Critical) and S-07**: the payment-channel and invoice read
  models are typed on the domain `PaymentChannel` and `InvoiceReadModel`
  across Isar, Postgres and in-memory. The Postgres channel read model
  previously failed on every channel event with a type cast error.
  **Postgres migration v004** adds `payment_channels.latest_payment_tx_id`,
  `settlement_tx_id`, `error_message`, `invoices.outputs_json`, and drops
  NOT NULL on the funding and address columns of a requested channel.
- **H3**: change-chain addresses are now signable. `derivePrivateKey`
  honours `isChange` (m/1/i); the aggregate records each address's chain
  in state (rebuilt from the journal, older events mean receive).
- **H4**: key material is written to secure storage before the
  `WalletCreatedEvent` is persisted; a failed write fails the command.
- **A-H7**: `ImportActor` no longer sleeps between steps or blocks its
  mailbox; progress queries are answered and `CancelImportMessage` works
  mid-import. A 30-transaction import takes milliseconds instead of
  seconds.
- **A-H3**: `SPVActor` derives output addresses for the configured
  network instead of always testnet.
- **SPV-02, SPV-03**: the header chain is anchored to the network genesis
  (or a configured checkpoint), validates the proof-of-work limit, the
  mainnet difficulty rules (legacy retarget, EDA bound, cw-144 DAA verified
  against real headers) and timestamps, and chooses the tip by cumulative
  chainwork. Reorganizations are real: heights come from the parent header,
  the old branch is orphaned, and unconnected batches trigger a
  locator-based re-request.
- **SPV-04**: CDN header sync is anchored to the in-code genesis header,
  validates proof of work by default, and refuses plain http.
- **SPV-06, SPV-07, SPV-08, SPV-14**: one BRC-74 compliant BUMP builder
  and merkle walk; library-built BUMPs are byte-identical to ARC's; TSC
  `*` duplicate markers are honoured; node-RPC single-transaction proofs
  are correct.
- New `NetworkParams` (genesis header and hash, proof-of-work limit,
  compact-target codec) for mainnet, testnet and regtest.

#### Breaking changes in this wave

- `ReadModelStorage`: `storePaymentChannel(PaymentChannel)`,
  `getPaymentChannel` returns `PaymentChannel?`,
  `getPaymentChannelsForWallet` returns `List<PaymentChannel>`;
  `storeInvoice(InvoiceReadModel)`, `getInvoice` returns
  `InvoiceReadModel?`, `getInvoicesByWallet` / `getInvoicesByStatus`
  return `List<InvoiceReadModel>`, `updateInvoiceStatus` takes
  `InvoiceStatus`; new required `listInvoices({walletId, status})`.
  External implementers must update. `InvoiceEntity.toDomain()` returns
  `InvoiceReadModel`.
- `ListInvoicesMessage` with no filters returns all invoices (previously
  only pending); `walletId` and `filterStatus` now combine.
- `BlockHeaderChain.initialize()` seeds the genesis header into an empty
  store (`bestHeight` 0, `chainTip` non-null on a fresh install) and throws
  `StateError` on a non-empty store that is not anchored to the network
  genesis (an old store that starts at height 1 and links to genesis is
  back-filled). `validateAndStoreHeader` rejects headers whose parent is
  unknown or whose given height disagrees with the parent;
  `getHeaderByHash` / `getHeaderByHeight` return active-chain headers only;
  `handleReorganization` returns `HeaderAcceptResult?`.
- `CdnHeaderSyncConfig.validateProofOfWork` defaults to `true`; new
  `allowInsecureHttp` (default `false`), an `http://` base URL makes
  `CdnHeaderSyncService` throw `ArgumentError`. A first chunk that does
  not start at the network genesis is rejected.
- `BUMP.computeMerkleRoot` throws `BUMPException` and rejects the old
  non-standard layouts; every BUMP builder emits different (compliant)
  bytes; `convertBumpToBrc71Path` returns display-order hex with `*`;
  stored `MerkleProof.merkleProof` is `[rawBumpHex]`. Journaled proofs
  produced by the old builder fail the strict walk on replay and are not
  stored (re-import fixes).
- `CryptoService.derivePrivateKey(isChange: true)` returns the change-chain
  key (it previously returned the receive key).
- A duplicate `CreateWalletCommand` replies
  `WalletCreatedResponse(success: false)` instead of being dropped; an
  unacknowledged import step fails the import instead of continuing.
- `CancelImportMessage` and `ImportProgressQuery` implement `Message`;
  `ImportProgressMessage` extends `LocalMessage` with additional fields.

Additive API: `BlockHeaderChain({params, anchor, clock})`, `acceptHeader`, `buildBlockLocator`, `BlockHeaderAnchor`, `HeaderAcceptResult`, `DifficultyRules`; `SignTransactionCommand.isChangeFlags`,
`SignMultisigTransactionCommand.isChange`,
`BuildFundingTransactionCommand.isChange`, `SPVActor(networkType:)`,
`ImportActor(walletProjection:, ackTimeout:)`, `ImportCancelResponse`,
`BUMP.fromMerklePath` / `fromTscProof` / `merge` / `fromHex` / `toHex`,
`CdnHeaderSyncConfig.checkBaseUrl()`, `CdnHeaderSyncService.networkParams`.

### Audit backlog, wave 2

Every fix below has a regression test shown to fail on the previous code
(report `Test` rows).

- **Signing moved into the wallet aggregate (A-H8, KM-4, KM-5).** The
  payment and Benford coordinators no longer read secure storage or derive
  keys. Plugin payments funded from several addresses now sign each input
  with its own key; mnemonic wallets with a passphrase can pay, provision
  and split; change-address UTXOs sign with the change key.
- **Wallet-scoped storage keys (S-05).** Two wallets in one store can both
  record the same transaction and outpoint. **Postgres migration v005**.
- **Storage consistency (S-12, S-13, S-17, S-18, reorg re-activation).**
  Header stores are upserts, so a reorg back onto a previously orphaned
  branch persists; one merkle proof per transaction; Postgres junction
  rows no longer duplicate on replay; the in-memory backend implements the
  address APIs.
- **UTXO status (M1, M3, M4, M9).** Group reserve/release commands work;
  releasing a reservation restores the previous status (a pending UTXO
  stays pending) in the aggregate and the read model; confirmations no
  longer reset reserved or spent UTXOs; an already-known outpoint is never
  overwritten.
- **Replies after persistence (M5).** Signed and funding transaction
  replies are sent only after their events are journaled.
- **Projection robustness (M2).** Missing read-model rows are logged and
  skipped instead of stopping the projection; replay is idempotent
  (address balances are recomputed from UTXO rows).
- **Proofs checked against the local header chain (SPV-09).** Imports and
  ARC confirmations compare the BUMP's merkle root with the stored header
  at that height; mismatches are rejected and unknown headers deferred.
- **BRC-62 order (SPV-10).** Library-built BEEFs list parents before
  children.
- **Real ARC API (SPV-11).** Merkle proofs come from `GET /v1/tx/{txid}`;
  the fee comes from `policy.miningFee`; batch submit posts to `/txs`.
- **Actors (A-M1, A-M2, A-M3, A-M5, A-M6, A-M7, A-M10).** Concurrent BEEF
  validations for one wallet are correlated per request; the coordinator
  no longer misses projection events or blocks its mailbox while waiting;
  ARC status scans do not overlap; `LibSpiffyActorSystem` refuses a second
  `initialize`, reports `isInitialized` false after shutdown, stops its
  actors on a host-owned system and closes P2P sockets; channel signing
  failures reach the caller and `QueryChannelState` works; reservations
  are released on every payment failure; idle wallet aggregates are
  evicted and reloaded on demand.
- **Dead code removed (SPV-12).** The unused parallel SPV, balance and
  transaction-builder services are gone.

#### Breaking changes in wave 2

- Removed from the package exports: `SPVService`, `BlockHeaderService`,
  `WalletBalanceService`, `TransactionBuilderService` and their companion
  types (`TrackedTransaction`, `StoredBlockHeader`, `WalletBalance`,
  `TransactionBuildConfig`, `UTXOSelectionStrategy`, ...);
  `BEEF.validateTransactionWithBlockHeaderService` and
  `BEEF.getBlockHeaderValidatedTransactions`;
  `BitcoinWalletAggregate.transactionBuilder`. `TransactionBuildException`
  is still exported.
- `ReadModelStorage.getTransaction(txid, {walletId})`; without `walletId`
  it returns the first wallet's row. Isar's generated `getByTxid`,
  `putByTxid`, `getByUtxoKey` and `getByAddress` are gone.
- Postgres v005 replaces the global unique keys on transactions and UTXOs
  with wallet-scoped ones; its down migration keeps only the first-stored
  row per txid / outpoint.
- `ArcPolicyResponse` takes `miningFee` and the real policy fields;
  `standardFeePerKb` / `minFeePerKb` / `dataFeePerKb` are derived getters;
  `getPolicy` throws when `miningFee` is absent.
- Imports are rejected when the proof's root does not match the stored
  header, or the raw transaction does not hash to the txid. ARC
  confirmations wait until the header at that height is stored.
- `LibSpiffyActorSystem.initialize` throws `StateError` when called twice
  or after `shutdown`.
- Wallet aggregates idle for 30 minutes are stopped
  (`WalletManagerActor(aggregateIdleTimeout:)`, `null` disables); a
  `CreateWalletMessage` for a wallet that exists in the journal is refused
  even if it is not loaded.
- `PaymentCoordinatorActor` / `BenfordCoordinatorActor` `secureStorage` is
  deprecated and unused. A plugin's `buildTransaction` /
  `provisionFunding` may be called several times per payment and must be
  side-effect free; the plugin signer's `signPreimage` throws
  `UnsupportedError`.
- Group reserve/release commands now change UTXO status; release restores
  the pre-reservation status.

Additive API: `BitcoinUtxo.statusBeforeReservation`,
`UTXOReleasedEvent.restoredStatus`, `ValidateBEEFMessage.requestId`,
`BEEFValidationResult.requestId`, `TransactionImportService({headerAtHeight,
requireVerifiedHeader})`, `ImportedTransaction.headerVerified`,
`AncestorChainService.orderParentsFirst`, `ARCActor(statusCheckInterval:,
headerTriggerDebounce:)`, `PaymentChannelManagerActor(signingTimeout:)`,
`WalletManagerActor(aggregateIdleTimeout:, idleCheckInterval:)`,
`InvoiceCoordinatorActor(expirySweepInterval:)`,
`PaymentCoordinatorActor(signingReplyTimeout:)`, `ArcFeeAmount`,
`ArcTransactionResponse.merklePathHex`.

### Audit backlog, wave 3

Every fix below has a regression test shown to fail on the previous code
(report `Test` rows). Data retention follows `spv-understanding.md`: no
code path deletes transactions, raw transactions, merkle proofs or spent
UTXO history; the purge suggestions in S-16 and M7 were rejected by design.

- **Postgres event store (S-09, S-10, S-11, S-23).** Concurrent writers to
  one aggregate get `ConcurrencyException` instead of a unique-violation;
  batches are one INSERT; journal replay is paged; `eventsByTag` honours the
  `EventTags` mixin; snapshot upserts update `schema_version`; database
  errors surface as `EventStoreException`.
- **Postgres operations (S-14, S-22, V-6).** SSL is required by default and
  `sslmode=verify-full` is honoured; `schema` and `idleTimeout` are applied;
  migrations take an advisory lock, so instances can start together;
  `reset()` works on a fresh database; connection errors are no longer
  reported as schema version 0.
- **Secret key rotation (KM-9).** `PostgresSecureStorage` decrypts with the
  key for each row's `key_version` and can re-encrypt to the current key;
  `getAll` reports undecryptable rows instead of dropping them.
- **Wallet storage (S-08, S-15, S-16, S-19, S-20, V-7).** Bulk header
  imports use multi-row upserts; wallet existence, deletion and unknown
  wallets behave the same on every backend; Isar queries use indexes; list
  queries are newest-first everywhere (**Postgres migration v006**); updates
  no longer wipe stored raw transactions, block heights, spend history or
  plugin metadata; Postgres rows keep `updatedAt`, `spent_at` and `walletId`.
- **Event journal (M8, L2, L4, KM-8).** Events are stored under stable type
  ids (`wallet.utxo.received`, ...) with the old class names as aliases, so
  existing journals load and obfuscated builds work; channel events persist
  only persistable metadata; import progress is an in-process notification,
  not an event; new wallets no longer journal the xpub.
- **Aggregate state (M6, M7, L1).** Snapshots restore the complete state
  (wallet, invoice, channel); balances are maintained incrementally, so
  recovery is linear; replayed timestamps equal live ones.
- **Signing (5sr).** `SignInputCommand` signs one input for plugin payments.
- **Payment channels (M10, L3, SPV-13, L4, y3b, 32t).** The aggregate
  enforces server-side balance and refund-signature invariants; state
  queries on unknown channels reply; refund locktimes below 500,000,000 are
  rejected; signing does not mutate the caller's transaction; the refund
  event journals the real refund txid; a requested channel has a null server
  key (**Postgres migration v007**); `PaymentChannel` is immutable.
- **Reorgs and proofs (3b0, zvj, A-L2).** A header reorganization takes back
  confirmations whose proofs no longer verify against the active chain: the
  transaction returns to pending, its outputs stop counting as confirmed,
  the orphaned proof row is removed from the read model (the BUMP stays in
  the journal event) and ARC is polled for a new proof. Proofs stored before
  their header was known are verified when it arrives. BEEF BUMPs are chosen
  by `bumpIndex`; a transaction confirmed straight from broadcast marks its
  inputs spent.
- **Actors (p56, A-L1, A-L3, A-L4, A-L5).** `WalletCreatedEvent` is emitted
  after the read model has the wallet; ids are UUIDs; SPV results without a
  target wallet are rejected; every caught error is logged with its stack.
- **Regtest (x27).** Regtest wallets resolve regtest consensus parameters,
  CDN directory and genesis instead of testnet.
- **Key management docs and cleanup (KM-10, KM-11).**

#### Breaking changes in wave 3

- `PostgresConfig` requires SSL by default: a local server without TLS
  needs `enableSsl: false` or `?sslmode=disable`. An unknown `sslmode`
  throws. `toConnectionString()` omits the password unless
  `includePassword: true`. `PostgresMigrations.withPool` takes a non-null
  `Pool`; `getCurrentVersion` / `getAppliedMigrations` throw on connection
  errors.
- `PostgresSecureStorage.getAll()` throws when any row cannot be decrypted.
- The journal `eventType` column holds stable ids for new events. Readers
  outside libspiffy that match class names must accept both.
- `WalletImport*Event` classes are `WalletImportNotification`s (no `fromMap`,
  `eventId`, `version`); import progress is on
  `LibSpiffyActorSystem.importNotifications` /
  `subscribeToImportNotifications`, no longer on `walletEvents`.
  `WalletCoordinatorActor(walletEventsStream:)` is now `importNotifications:`.
- `WalletCreatedEvent.hdPublicKeyXpub` is deprecated and not journaled; the
  xpub lives only in secure storage for new wallets.
- `PaymentChannel` fields are final (use `copyWith`); `serverPubKeyHex`,
  `myPubKeyHex` and `counterpartyPubKeyHex` are nullable. The client must
  record the server's acceptance before the refund signature.
- `ReadModelStorage.deleteMerkleProof` added (implementers outside the
  package must add it). In-memory reads return empty results for unknown
  wallets instead of throwing; Isar deletes wallets outright and
  `walletExists` no longer counts wallets that only have UTXO rows. List
  queries are newest-first.
- `RegisterTransactionOutputsMessage`, `RegisterTransactionInputsMessage`
  and `ArcService.getRawTransaction` removed; `TransactionLifecycleCoordinator`
  does nothing; channel ids are `ch-<uuid>`.
- An aggregate whose snapshot cannot be restored fails recovery.
- After a reorg, UTXOs confirmed only by an orphaned proof are pending until
  ARC confirms them again. Regtest wallets report network `regtest`.
- `metadata['importedTransactions' / 'outgoingTransactions']` in wallet
  state are maps keyed by txid.
- `CryptoUtils.toPbkdf2Seed` removed (internal).

Additive API: `PostgresConfig.sslMode`, `toPoolSettings()`,
`toConnectionSettings()`; `PostgresSecureStorage(previousKeys:)`,
`reencryptToCurrentKey()`; `LibSpiffyActorSystem.registerEventTypes()`;
`stableTypeName` on every event; `SignInputCommand`, `InputSignedResponse`;
`BitcoinUtxo.spentInTxId`; `ClaimRefundCommand.refundTxHex`;
`TransactionConfirmationRevertedEvent`, `RevertTransactionConfirmationCommand`,
`HeaderChainReorganizedMessage`; `NetworkName.isRegtest`;
`BitcoinUtxoEntity` / `BitcoinTransactionEntity` `applyDomain`. Deprecated:
`IsolateConfig` and the `isolateConfig:` / `config:` parameters that carry it.

### Follow-ups before wave 4

Defects found by the wave 3 lanes and this batch (report section 11, V-8 to V-16), each with
a regression test shown to fail on the previous code.

- **Rejected commands (V-8, V-11).** A command an aggregate rejects is
  answered with the aggregate's error and no longer stops the wallet,
  invoice or channel aggregate; the channel manager no longer reports
  rejected payments and refund countersignatures as successful. A journal
  write failure still takes the aggregate out of service; managers replace
  dead aggregate refs. Invoice failures are answered once, not twice.
- **Postgres journal ordering (V-9).** Replays, `eventsByTag` and live
  streams deliver every committed event even when concurrent writers commit
  out of id order, and live streams now receive appends from other
  processes (**Postgres migration v008**).
- **Merkle proof retention (V-10).** Proofs carry a status (`verified`,
  `pendingHeader`, `orphaned`); a reorg marks a proof orphaned instead of
  deleting it, and BEEFs use only a transaction's current proof
  (**Postgres migration v009**).
- **Channel open (V-12).** A client-side channel open no longer stalls on
  the server's refund countersignature; channel funding and refund signing
  use the channel's wallet instead of the last one created.
- **Channel refund and funding (V-13).** The client journals the fully
  signed refund transaction and verifies the server's signature before
  anything goes on-chain; only then is the funding transaction recorded as
  an outgoing wallet transaction and broadcast through ARC. The 2-of-2
  output is reserved for the channel, so it does not count as spendable
  balance. A failed broadcast keeps the channel in `funding`. The server
  refuses a `channel_open` whose funding output does not match. Claiming the
  refund works after its locktime.
- **ARC proofs journaled (V-14).** `TransactionConfirmedEvent` carries the
  BUMP, so rebuilding the read model from the journal keeps ARC-supplied
  proofs; every wallet holding a mined transaction is confirmed in the same
  scan.
- **Received ancestors retained (V-15).** The ancestor transactions and
  BUMPs of a received unproven payment are journaled and stored (outside
  wallet history and balance), so its output can be spent before it is
  mined (**Postgres migration v010**).
- **Deferred spend on submit (V-16).** When ARC answers a broadcast with
  SEEN_ON_NETWORK or MINED, the transaction's inputs are marked spent and
  its change becomes spendable at once, also for BEEF broadcasts, the
  durable retry queue and channel funding. Previously this waited for ARC
  to report MINED with a verified proof, and an input's reservation could
  expire in the meantime. Every SEEN_ON_NETWORK or MINED report applies the
  spend exactly once, including after a restart; a MINED answer carrying a
  merkle path confirms the transaction after the header check.

#### Breaking changes

- PostgreSQL 13 or newer is required. `PostgresEventStore` polls for live
  events (`livePollInterval`, default 1 s; `null` disables); an open writing
  transaction anywhere on the server delays live delivery until it ends;
  overlapping appends may be delivered with the higher id first.
- `ReadModelStorage.deleteMerkleProof` is replaced by
  `markMerkleProofOrphaned`; `getMerkleProofHistory` and
  `getMerkleProofsByStatus` are new (all abstract). `MerkleProof.blockHash`
  is nullable; the `'pending'` block hash is gone; a transaction may have
  several proof rows; `getMerkleProofCount` counts orphaned rows.
- Channel manager error texts are the aggregate's messages;
  `RecordServerAcceptanceMessage` gets a `ServerAcceptanceRecordedResponse`.
  Mark-paid, cancel and expire for an unknown invoice fail at once with
  "not found". A `CreateWalletMessage` rejected earlier can be retried.
- Coordinator channel events carry the channel's wallet id.
- A client channel cannot open without an ARC actor; a client refund build
  needs the funding transaction hex; refund-signature and `channel_open`
  failures reach the coordinator as `ErrorEvent`s.
- `ReadModelStorage.storeAncestorTransaction` and
  `getAncestorTransactionsBatch` added (abstract). Hosts opening Isar with
  their own schema list must add `AncestorTransactionEntity`.

Additive API: `MerkleProofStatus`, `MerkleProof.status` / `statusChangedAt`,
`PostgresEventStore(livePollInterval:)`, `ServerAcceptanceRecordedResponse`,
`RecordRefundBuiltCommand`, `StartFundingBroadcastCommand`,
`RecordFundingBroadcastFailedCommand`, `FundingBroadcastStartedEvent`,
`FundingBroadcastFailedEvent`, `RefundCountersignedEvent.signedRefundTxHex`,
`PaymentChannelManagerActor(arcActor:,
walletProjection:, broadcastTimeout:)`, `TransactionConfirmedEvent.bumpHex`,
`ConfirmTransactionCommand.bumpHex`, `BeefAncestor`,
`TransactionImportedEvent.ancestors`, `ArcSubmitResponse.merklePath` /
`merklePathHex`.

## 2.0.0

Dependency upgrade and audit release. libspiffy now tracks **dactor 1.3.0**,
**eventador 3.0.0**, **duraq 3.0.0** and **duraq_isar 2.0.0**. A full
correctness, security, performance and architecture audit accompanies the
upgrade; its report is `doc/audit-2026-09-14.md` and every open finding is
a beads issue labelled `audit-2026-09`.

### Upgrading from 1.x

1. **Bump the dependencies together**: `dactor: ^1.3.0`, `eventador: ^3.0.0`,
   `duraq: ^3.0.0`, `duraq_isar: ^2.0.0`. `IsarStorage` now comes from
   `package:duraq_isar/duraq_isar.dart`. Read the duraq 2.0.0/3.0.0 notes:
   the broadcast-retry queue database is migrated in place on first open and
   cannot be reopened by duraq 1.x.
2. **Open a shared Isar instance with `LibSpiffySchemas.allSchemas`.**
   `LibSpiffyActorSystem.initialize` now throws an `ArgumentError` naming
   any missing collection. Under eventador 3.0 a projection whose checkpoint
   collection is missing stops in `ProjectionStatus.error` instead of
   replaying from 0, so the old partial-schema setup would leave read models
   silently frozen. `walletSchemas` alone is no longer enough.
3. **`BitcoinWalletAggregate.preStart` returns `Future<void>`.** Recovery
   runs inside it and `spawn()` awaits it. Await `preStart()` if you call it
   directly; no settle delay is needed before sending commands.
4. **Reservation replies**: `ReserveUTXOCommand` now answers with
   `UTXOReservedResponse` on success as well as failure. Callers that relied
   on "no reply within 2 s means reserved" must handle the reply.
5. **`ArcServiceConfig.requestTimeout`** (default 30 s) bounds every ARC
   request. With no `arcConfig`, the ARC endpoint now follows `networkType`
   (testnet ARC for `'test'`) instead of always using TAAL mainnet.
6. **`ChannelP2PAdapter`** takes a `walletManager` and the coordinator sets
   its reply target in `preStart`; hosts constructing it directly must pass
   the wallet manager.
7. **Postgres migration v003** runs on first start: block header integer
   columns become `BIGINT` and `bitcoin_utxos.plugin_metadata JSONB` is added.
8. Wallet metadata network names are normalised: `'main'`/`'mainnet'` and
   `'test'`/`'testnet'` are accepted everywhere and persisted canonically.
   A BIP39 passphrase given at creation is now stored (secure storage key
   `wallet_passphrase_<walletId>`) and used for signing.

### Fixed

Critical: unproven BEEF payments were accepted when any transaction in the
BEEF had a valid proof (inputs are now required to chain back to proven
ancestors); `HeaderSyncActor` deadlocked on opportunistic header fetches;
client-side channel open never progressed past `channel_accept`; deferred
spends could never mark UTXOs spent and the expiry returned spent coins to
`available`; on Postgres, token UTXOs were spendable as ordinary funding and
about half of all block headers failed to store.

High: BIP39 passphrase wallets could not spend what they received; mainnet
key imports were rejected and mainnet change outputs were never detected
(network-name mismatch); multi-input signing failed its own sanity check;
timestamp BEEFs were never broadcast (base64 vs hex); `AwaitEventApplied`
asks timed out at dactor's 5 s default; UTXO reservation treated a slow
rejection as success; header sync stuck "in progress" forever with no
peers; invoices were created with empty addresses on address-generation
failure; the Isar chain tip pointed at an orphaned header after a reorg;
Postgres reset a wallet's network to mainnet on every balance update; the
wallet projection double-counted address balances; CDN chunk filenames
could escape the cache directory; ARC HTTP requests had no timeout.

Also: PostgresEventStore live streams no longer miss events persisted during
a projection's replay and honour the eventador 3.0 `typeName` /
`persistableMetadata` contracts; wallet-manager error replies are handled by
the invoice and channel coordinators; `ask()` failure replies are
`LocalMessage`-wrapped; commands for an unknown wallet are answered "Wallet
not found" instead of spawning an empty aggregate; recovery sleeps and the
`RecoveryStatusQuery` poll are gone; xpubs are no longer logged; a SEVERE
warning is logged when `InMemorySecureStorage` backs a persistent backend;
the `example/` directory compiles again.

## 1.1.0

### WalletCoordinatorActor (Unified Public API)
- Added `WalletCoordinatorActor` as the canonical public interface for third-party apps
- Single entry point: send commands via `coordinator.tell()`, receive events on `coordinator.events`
- Clean import via `package:libspiffy/coordinator.dart` with no internal type collisions
- Correlation tracking for multi-step async flows (BEEF validation, SPV, payments)
- Channel P2P adapter for payment channel communication

### Plugin System
- Added `ScriptPlugin` interface for custom Bitcoin script types
- Added `TransactionBuilderPlugin` for multi-output protocol transactions (e.g., token issuance, transfer, burn)
- Added `PluginRegistry` singleton for plugin discovery and management
- Added `CallbackTransactionSigner` for secure plugin signing (private keys stay in wallet aggregate)
- Plugin metadata stored on UTXOs for script identification and display

### Payment Channels
- Added `PaymentChannelAggregate` (event-sourced) for off-chain micropayment channels
- Added `ChannelProjection` for channel read model updates
- Channel lifecycle: open, fund, pay, close with on-chain settlement
- Payment channel builder for funding, refund, and payment transactions

### Multi-Output Invoices
- Added `InvoiceOutputSpec` sealed class hierarchy:
  - `P2PKHOutputSpec` for standard address-based outputs
  - `P2MSOutputSpec` for m-of-n multisig outputs
  - `OPReturnOutputSpec` for metadata/timestamp outputs
  - `PluginOutputSpec` for plugin-delegated locking scripts

### PostgreSQL Storage Backend
- Added `PostgresWalletStorage` (read model store) for server-side deployments
- Added `PostgresEventStore` for event sourcing on PostgreSQL
- Added `PostgresSecureStorage` with AES-256-GCM encryption for xpub/xpriv keys
- Migration infrastructure with versioned schema migrations
- Connection pooling, SSL support, and connection string parsing

### CDN Block Header Sync
- Added `CdnHeaderSyncService` for fast initial header synchronization via static CDN
- Chunked binary downloads with SHA-256 integrity verification
- Concurrent download support with configurable parallelism
- Checkpoint verification for chain continuity

### Additional Coordinators
- Added `PaymentCoordinatorActor` for multi-step payment flow orchestration
- Added `BenfordCoordinatorActor` for privacy-preserving UTXO splitting
- Added `TransactionLifecycleCoordinatorActor` for pending transaction recovery on restart
- Added `ImportActor` for wallet import from blockchain via address discovery

### Wallet Import
- Added wallet import support for xpub (watch-only) and WIF private keys
- Hierarchical address discovery via blockchain data sources
- WhatsOnChain blockchain data source implementation
- Transaction import with UTXO harvesting and dependency sorting

### Other Improvements
- Removed `generateAddress` from public `CryptoService` interface (internal only)
- Added `AddressMetadata` model with script type and usage tracking
- Added `TransactionAddressLink` junction model for transaction-address relationships
- Added `WalletType` enum (HD, WIF, XPRIV, XPUB)
- ARC service configuration presets: `taalTestnet()` and `taalMainnet()`
- Lock/unlock script builders for HODL, AIP, B://, BMAP, PP1, PP2, partial witness scripts

## 1.0.0

- Initial version: event-sourced Bitcoin SPV wallet with CQRS architecture, actor model (Dactor/Eventador/DuraQ), HD wallet management, invoice system, SPV validation with BEEF/BUMP, ARC service integration, Isar storage, and SpiffyNode P2P connectivity.
