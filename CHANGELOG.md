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

### Two APIs that could never deliver anything are gone

Both are breaking at compile time only: neither ever fired, so nothing can
depend on their behaviour.

- **Removed `HeaderSyncProgressEvent`.** Nothing in the library ever
  constructed it. Header progress is reported by the two mechanisms that
  work: `LibSpiffyActorSystem.initialize(onHeaderSyncProgress:)` for the
  initial CDN download (downloaded, total, `CdnSyncPhase`), and
  `BlockHeadersStoredEvent` for every batch stored afterwards, with its
  count and the heights it spans. Its own `currentHeight` / `totalHeight`
  fields could only ever have carried header counts.
- **Removed `LibSpiffyActorSystem.subscribeToWalletEvents`, the
  `walletEvents` getter and `broadcastWalletEvent`**, with the controller
  behind them and `WalletCoordinatorActor(broadcastWalletEvent:)`. They
  were three faces on a stream nothing ever added to: an application could
  wire a listener and wait forever, with no error. What it offered was also
  the journal's own `WalletEvent` (`AggregateEventBase`), a second public
  event contract parallel to `coordinatorEvents`. Use `coordinatorEvents`,
  whose events say what the read model holds.
- New guard test: every `CoordinatorEvent` subclass declared in
  `coordinator_messages.dart` must be constructed somewhere in `lib/`, with
  no exemptions, so the next public event nothing emits arrives red.

### An app hears a UTXO split start, not only finish

- `UTXOSplitStartedEvent` is emitted. It was exported beside
  `UTXOSplitCompleteEvent`, which was emitted, and nothing in the library
  ever constructed it — so an application heard a Benford split finish and
  never heard one start, through a wait that builds, signs and broadcasts
  one transaction per source UTXO and waits for ARC's answer to each.
- `BenfordCoordinatorActor` reports the start once the split cannot be
  refused any more, with the number of UTXOs it will actually take (which
  `maxUtxosToSplit` bounds and the wallet's holdings decide). A split that
  cannot start — no wallet, a watch-only wallet, nothing spendable, no fee
  rate from ARC — announces no start.
- New internal `SetCoordinatorForSplitsMessage`, sent by
  `WalletCoordinatorActor.preStart` as `SetCoordinatorForSPVMessage`
  already was. The start is never sent to the split command's sender: a
  caller that used `ask` holds a one-shot reply reference, and a second
  message told to it would resolve the ask in place of the
  `SplitUTXOsResponse` it asked for.
- `WalletCoordinatorActor(benfordCoordinator:)` is no longer deprecated: it
  is used again, for that registration.

### An app is told when its balance changes

- `BalanceUpdatedEvent` is emitted. It was public and nothing in the
  library ever constructed it, so the only way an application could learn
  that money had arrived, been spent, been reserved or lost its proof was
  to send `GetBalanceQuery` again and compare — and anything that happened
  between two polls was invisible. It is announced from the events the
  wallet read model applied, beside `TransactionConfirmedEvent` and
  `TransactionConfirmationRevertedEvent`.
- The event now carries `pendingBalance`, `watchOnlyBalance` and
  `reservedBalance` beside the confirmed, unconfirmed and total numbers it
  already declared, from the same computation that answers
  `GetBalanceQuery`, so the event and the query cannot report different
  money. Additive: the three new parameters are optional and default to
  zero.
- Announcements are made one at a time in the order the read model applied
  the events that caused them, and an event that leaves the numbers alone
  is silent.

### A wallet's unspendable money is reported, not lost

- New `BalanceResponse.pendingBalance`: the wallet's unspent outputs that
  cannot be spent yet, because the network is not known to hold the
  transaction that pays them or because a reorganization took its proof
  away. `_handleGetBalance` counted only available and reserved rows, so
  a pending output was in no bucket at all — after a reorganization an
  owner was shown zero until a fresh proof arrived. Reported apart and
  outside `totalBalance`, the treatment `reservedBalance` and
  `watchOnlyBalance` already have. No existing field changes.

### An app hears when the chain takes a confirmation back

- New public `TransactionConfirmationRevertedEvent`: the block a
  transaction was proven in left the active chain, or the header at its
  height contradicts the proof. It carries the height the confirmation was
  recorded at, the block that left, and the reason the wallet recorded.
  `TransactionConfirmedEvent` had no counterpart, so an application that
  acted on a confirmation could only learn it was gone by asking again.
  Both are announced from the events the wallet projection applied.

### Chain reorganizations are driven through the real stack

- New `localnet_reorg_e2e_test.dart`: the node drops the block a payment
  was confirmed in and builds a longer branch in its place, and both
  wallets take the confirmation back, keep the proof of the block that
  left marked `orphaned`, and record the block that replaces it - at the
  same height, and at another height when the branch moves it. Until now
  reorganizations were only covered by tests that hand headers to the
  actor directly.
- `arcProves` in the harness waits for ARC to catch up with the chain on
  its own. After a reorganization ARC goes on naming the block that left
  until its block processing catches up, and no wallet can re-prove a
  transaction before it does; waiting for it separately keeps a slow ARC
  from reading as a wallet defect.

### The localnet tests survive a chain anything can mine

- `mine()` in the localnet harness returned the chain tip rather than the
  block it had just mined. Those are the same number only while nothing
  else extends the chain, so every assertion that a wallet recorded "the
  height `mine()` returned" was a guess. It returns the height of the
  block `generatetoaddress` produced, and the new `minedAt(txid)` asks the
  node which block holds a transaction: the payment and deferred suites
  check a wallet's recorded height against the chain's own answer.
- The payment suite demanded `SEEN_ON_NETWORK` from ARC where a block can
  land inside ARC's five-second wait; it accepts a held payment the way
  the deferred suite already did.
- The two node-RPC tests were pinned to a key whose funds were on the node
  they no longer talk to, so four of them asserted that an address this
  chain has never seen should have transactions. They fund their own
  address first - watched before it is paid, since the import path never
  rescans - and test what they claim again.

### Duplicate SPV message classes are gone

- `spv_messages.dart` held a second `ValidateBEEFMessage` and
  `RetrieveMerkleProofMessage` that nothing sent; the live ones are in
  `wallet_messages.dart`. `SPVActor` no longer needs a `hide` clause and a
  second aliased import to tell them apart.
- `SPVControlMessage`, `SPVControlAction` and `SPVConfigMessage` are
  removed: nothing in the library ever sent or handled one.

### Three integration test files test what they claim again

- The CDN header sync tests built their chain with proof-of-work
  validation off, which also skips seeding the genesis anchor, so the
  service rightly refused the first chunk; they now build the chain as
  production does for testnet.
- The header sync end-to-end tests fed mainnet headers to a chain anchored
  to testnet, so every header was rejected as having an unknown parent.
- Hollow tests are gone or made real: a storage-error test that never
  failed the storage now does; two merkle-proof tests that asserted "a
  bool came back" assert the verdict; the tests that only checked a
  message constructor kept its arguments are deleted.

### An invoice is paid when the network holds the payment

- An invoice was marked paid as soon as a payment's BEEF validated, before
  it was submitted — so a payment ARC calls a double spend, or one
  spending an output already spent in a block, paid it too. Since a paid
  invoice refuses every other transaction, the payer's genuine replacement
  was then refused. An invoice is now paid when ARC says the network holds
  the payment (`SEEN_ON_NETWORK` or `MINED`), or when the payment arrives
  with its own verified proof.
- A payment the network turns out to hold after all — ARC follows every
  submission to its block — pays its invoice then, after a restart too.

### A failed payment's inputs are free when the failure is answered

- A payment that failed after reserving its inputs was answered before the
  wallet released them, so paying again on hearing it could find them
  still reserved. The failure is now answered once they are released.

### A deferred broadcast or reclaim succeeds only when the network holds it

- ARC answers with where it got to when its own wait for the network runs
  out. A reclaim answered so after the recipient's copy had reached the
  network was reported reclaimed, and ARC then rejected it. Broadcasting
  and reclaiming now follow such an answer for up to 30 s, and succeed
  only on `SEEN_ON_NETWORK` or `MINED`; the orphan mempool is no longer a
  success.

### A deferred payment's check, broadcast and reclaim answer what the wallet shows

- Checking, broadcasting or reclaiming a deferred payment was answered
  before the wallet showed the status, the spent inputs, the change or the
  reclaim. Each answer now waits for them.

### A deferred payment can be cancelled the moment it is answered

- A payment's answer (`PaymentReadyEvent`) came a moment before the wallet
  held the payment as deferred, so cancelling, reclaiming or listing it at
  once was told it was no deferred payment. The answer now waits for the
  hold.

### A received payment is spendable when the answer says it is on the network

- The answer to `ValidateBEEFCommand` said the payment was on the
  network a moment before the read model made its outputs spendable, so a
  balance read on hearing it showed nothing received. The answer now waits
  for the outputs.

### An app hears its payments confirm and its invoices paid

- The coordinator's `TransactionConfirmedEvent` and `InvoicePaidEvent` were
  never emitted. They are now emitted once the wallet's read model holds
  the confirmation or the payment, so a query made on hearing one sees it.
- A payment whose invoice refused to be marked paid (paid or expired
  between the check and the mark) is now logged as a warning. The invoice
  aggregate's refusal says `success: false` and gives the invoice's actual
  status. It used to claim success and a pending invoice.

### A node restarted at the chain tip follows the chain again — critical

- A node restarted with its headers already at the tip asked for headers,
  was answered with none, and dropped that empty answer. Its header sync
  then waited for an answer forever and skipped every later request, so
  it never learned another block, and nothing it received or sent was
  confirmed again. An empty answer now ends the request, and a request
  that is never answered expires after `syncRequestTimeout` (new
  `HeaderSyncActor` parameter, default 30 s).

### A payment handed over again is the same payment

- A payer that hears no answer hands its payment over again. The second
  delivery was refused ("Invoice ... is not pending (status: paid)") for
  the invoice the payment itself had paid, telling the payer it had
  failed. It is now answered as the payment it is: valid, counted once,
  and the invoice is not marked paid a second time. Another transaction
  for a paid invoice is still refused.

### A channel step waits for ARC's verdict on an answer still in flight

- ARC waits a few seconds for the network to show a transaction back and
  otherwise answers with where it got to (`ACCEPTED_BY_NETWORK`, `STORED`,
  ...). A server refused a channel open on such an answer for a funding
  the network went on to hold. The funding, the settlement and the refund
  claim now follow ARC until it says held, contested or orphaned, for up
  to `inFlightTimeout` (new `PaymentChannelManagerActor` parameter,
  default 30 s; `inFlightPollInterval`, default 1 s). Still in flight at
  that point fails the step as before.
- New: `DeferredNetworkStatus.inFlight` and `isInFlight`.
- Changed: `TransactionStatusMessage.status` carries ARC's status name
  (`SEEN_ON_NETWORK`, `MINED`, ...), as every other status in the library,
  instead of a lowercase name of its own.

### The channel state drops the client's payment signature

- `ChannelState.latestClientSignatureHex` and the state query's field of
  the same name are removed. They were kept for the client to assemble its
  settlement from the server's `payment_ack` signature, which the protocol
  no longer sends. The journal still holds the signature, and older
  snapshots restore.

### A channel transaction counts as on the network only when ARC says so — security

- Found by running channels against a real regtest node and ARC
  (`test/integration/localnet_channel_e2e_test.dart`, tag `localnet`).
- The settlement, the server's funding submission and the refund claim
  counted as on the network on any ARC answer but a failure or
  `DOUBLE_SPEND_ATTEMPTED`. ARC answers two more cases with HTTP 200:
  - `SEEN_IN_ORPHAN_MEMPOOL`, when the node cannot connect an input. That
    includes an output already spent in a block, so a refund claimed after
    the settlement was mined got this answer.
  - an in-flight status (`RECEIVED`, `STORED`, `SENT_TO_NETWORK`, ...),
    when ARC stops waiting or the same transaction arrives while it is
    still processing it. A server restarted after its client took the
    refund closed twice at once, and closed the channel on the second
    answer, for a settlement ARC then found to be a double spend.
- Now only `SEEN_ON_NETWORK` or `MINED` counts, which is also what ARC waits
  for by default. Anything else fails the step, records nothing and says
  why; repeating the step retries it.

### A refund is claimed when the network would take it — breaking

- **A refund was claimed on the clock.** The network holds a time lock to
  the median time past of the last eleven blocks, which trails the clock
  by about an hour on mainnet. In between, ARC accepts the refund and the
  node keeps it as non-final, then drops it for any final spend of the
  funding output, while ARC goes on reporting it seen. The claim was
  journaled and recorded all the same.
- Now a claim waits until the chain's median time past, read from the
  node's block headers, is after the lock time.
- New: `BlockHeaderChain.medianTimePast()`.
- Breaking:
  - `ClaimRefundCommand` takes a required `medianTimePastUnix`.
  - `PaymentChannelManagerActor` takes the node's `headerChain`. Without
    it, no refund can be claimed. `LibSpiffyActorSystem` passes it.

### A refund claim the network refused is not a claim — security

- A refund claim took ARC's `DOUBLE_SPEND_ATTEMPTED`, which comes with
  HTTP 200, as success. A client whose `channel_closed` was lost, claiming
  after its server settled, journaled the claim and recorded the whole
  funding amount as received. The claim now submits as the settlement
  does, and records nothing for a refund the network did not take.

### A refund claim is checked before it is broadcast

- A claim the channel refused, for example one before the lock time, was
  still broadcast first: the host was told it failed while the refund was
  on the network. The manager now asks the channel first
  (`ChannelCommandCheck`: the same command, run by the aggregate and
  journaled nowhere) and broadcasts only a claim the channel would take.

### A channel settles before its lock time, and runs long enough to — breaking

- **Nothing settled a channel before its refund became valid.** The server
  acknowledged payments until the second of the lock time, accepted any
  lock time the client proposed (even a block height), and settled only if
  the app remembered to close. A settlement broadcast at or after the lock
  time races the client's refund, and on BSV the first spend seen wins.
- New `ChannelTiming` (exported): `settlementMargin` and `minimumLifetime`,
  both required. There are no defaults: the operator chooses them.
  - `LibSpiffyActorSystem.initialize(channelTiming:)` and
    `initializeLibSpiffy(channelTiming:)` take it.
  - A node given none requests, accepts and pays no channels, and says why.
    Its existing channels can still be closed, expired and refunded.
- Within the margin of the lock time, no payment is made or acknowledged.
- The server settles each channel it serves when the margin begins, through
  the ordinary close. The timers are re-armed at startup, and a server
  channel left `closing` is settled at once.
- A channel is requested or accepted only with at least the minimum
  lifetime to run, and its lock time must be a time rather than a block
  height. Request comfortably more than your server's minimum: the server
  measures the remaining time when it accepts.
- Breaking:
  - `PaymentChannelManagerActor` takes a required `timing` (nullable).
  - `RequestChannelCommand`, `AcceptChannelCommand`, `RecordPaymentCommand`
    and `AcknowledgePaymentCommand` take a required `timing`.
- The README's channel section is rewritten for the protocol as it now
  stands. It documents one known risk: a settlement's fee is fixed when its
  payment is acknowledged, so a policy rate rise before the server settles
  can leave the settlement underpaying.

### A channel's server refuses a funding amount that is not positive

- The client journals a channel request only for a positive amount; the
  server accepted whatever amount a `channel_request` named. Now the
  server's acceptance applies the same rule.

### A channel's server opens only on a funding the network has — security

- **The server opened a channel on SPV validation alone.** The funding
  BEEF proves the funding's ancestry, not that the network has it. A client
  could send the BEEF of a funding it never broadcast, or double-spend it
  after the channel opened, and every payment would then be against an
  output that never exists.
- The receiver submits what it receives: the server now submits the
  funding transaction to ARC and opens only once ARC holds it uncontested.
  A funding ARC refuses, or reports `DOUBLE_SPEND_ATTEMPTED`, refuses the
  open (and the client is told, as for any refused open); a re-sent
  `channel_open` submits it again. The client broadcasts first, so ARC
  already knows the transaction.

### A channel's server keeps its signature — security, breaking

- **The client could broadcast any earlier state of the channel.**
  `payment_ack` carried the server's signature of each payment, and the
  client journaled it (bead z2px), so the client held a fully signed spend
  of every state. BSV has no replacement and the first spend seen wins:
  after paying the server 60,000 sats, a client could broadcast the state
  in which it had paid 30,000.
- In a one-way channel only the payee holds full signatures. `payment_ack`
  now carries the sequence and nothing else; the client needs no signature
  until the server settles, and then it is handed the settlement the server
  broadcast (`channel_closed`, previous entry).
- Removed: `RecordPaymentCountersignatureMessage`,
  `RecordPaymentCountersignatureCommand` and
  `PaymentAcknowledgedResponse.serverSignatureHex` (the response's
  `fullySignedPaymentTxHex` is the server's own settlement).
  `PaymentCountersignedEvent` is deprecated and kept, registered and applied
  so journals that hold it replay; a client never closes with the copy it
  records.

### A channel's server broadcasts its settlement — security

- **Nothing broadcast a channel's settlement.** A cooperative close
  recorded the server's latest fully signed payment in the wallet as a
  pending receive and journaled the channel `closed` — the state documented
  as "settlement broadcast" — but no code submitted it. At the lock time the
  client's refund became valid and returned the whole funding output: the
  server lost every payment while its wallet and channel said it had been
  paid. A server's expiry did the same.
- Now the server submits the settlement to ARC before the channel is
  journaled closed, and at expiry before its return leg is recorded. A
  settlement ARC does not take, or reports as contested
  (`DOUBLE_SPEND_ATTEMPTED`), leaves the channel `closing` (or expired with
  no return leg), and closing it again retries the broadcast.
- `channel_closed` now carries the settlement (`settlementTxHex`) as well
  as its txid. The client checks it is its latest payment with both
  signatures, records its return leg, and closes the channel — journaling
  the close first if `channel_close` did not arrive. It used to drop its
  records and tell the host the channel had closed, journaling nothing. A
  client never closes with a copy of its own, and a `channel_closed`
  without a settlement closes nothing.
- New `RecordSettlementMessage`; `FinalizeCloseCommand.settlementTxHex`
  (required) and `ChannelClosedEvent.settlementTxHex` (null in older
  journals).
- A close or expiry that fails is now reported to the host as an
  `ErrorEvent`: the adapter used to tell the manager with no reply target,
  so the failure reached only the log.

### A channel server acknowledges only a payment the client signed — security

- **The server acknowledged payments it could never claim.** It signed the
  client's transaction, combined the two halves of the 2-of-2 signature,
  and when the result did not verify it logged that and journaled the
  acknowledgement anyway. A client could send a payment signed over some
  other transaction, have it acknowledged (the app delivering what was paid
  for), and leave the server holding nothing it could broadcast.
- Now the acknowledgement is refused unless the client's signature verifies
  over the payment transaction against the funding output — the same check
  the client's refund already had, now one function for both.

### A channel acts only on messages from its counterparty — security

- **Any peer could steer someone else's channel.** `ChannelP2PAdapter`
  took a message's channel id as its authority, and channel ids travel
  between the parties and through whatever relays them. A third peer that
  knew one could end the client's channel (`channel_closed`,
  `channel_reject`), close ours (`channel_close`), accept a request in the
  server's place — the client would then fund a 2-of-2 with the intruder's
  key and send it the refund to sign — or replace a pending request with its
  own keys before the app accepted it.
- Now every message about a known channel must come from the counterparty
  the channel journal names, in the role that sends it: `channel_accept`,
  `channel_reject`, `refund_signed` and `payment_ack` from the server;
  `refund_sign_request`, `channel_open` and `payment_update` from the
  client; `channel_close`, `channel_closed` and `channel_error` from either.
  A `channel_request` naming a channel this side already has with another
  peer is refused. Refusals are logged and nothing is sent back.
- The client's record of a channel takes both peers from its journaled
  `ChannelRequestedEvent`, as a restored record already did.

### One way to read ARC's rate — breaking

- `ArcPolicyResponse.standardFeePerKb`, `minFeePerKb` and `dataFeePerKb`
  are removed: they were one number under three names (ARC publishes a
  single `miningFee`). Read `miningFee` — a `FeeRate` — or
  `miningFee.satoshisPerKb`.

### Plugins can spend any output the wallet can — breaking for plugin authors

- **`PluginTransactionRequest.fundingInputs`**: each funding UTXO as a
  `PluginFundingInput` — its outpoint over the **real** locking script, and
  a factory for the unlocking script the wallet writes (`<sig> <key>`,
  `<sig>`, or `OP_0` and m signatures for an m-of-n bare multisig). A
  factory, not an instance: libspiffy runs a plugin's build more than once
  while the wallet signs.
- **`TransactionBuilderPlugin.spendsAnyWalletOutput`** (default `false`): a
  plugin that spends its funding through `fundingInputs` overrides it to
  `true`, and is then funded — for payments and for `provisionFunding` —
  from the wallet's bare multisig and P2PK outputs too. A plugin that
  leaves it `false` still gets P2PKH funding only, as before.
- The signer handed to plugins now gives an m-of-n input all m signatures,
  one per wallet key in script order. It used to return the first key's
  signature for each of them.
- **`PluginTransactionRequest.feeRate`** (required): ARC's policy rate,
  which a plugin's transactions pay on their signed size like every other
  transaction the wallet builds. `fundingInputs` is required too; a plugin
  test that constructs a request must pass both.
- An earmark provisioned for a plugin is recorded with the P2PKH script it
  actually pays, not its source's script.

### The Benford split and plugin provisioning pay ARC's policy rate — breaking

- **The split took its own rate**, in satoshis per byte and defaulting to
  1 — ten times what everything else paid — on a `180 + 34n + 10` byte
  guess. It now asks ARC for the policy rate and pays it on the split's
  signed size; if ARC cannot give it, nothing is reserved or built.
  **`SplitUTXOsCommand.feeRateSatsPerByte` and
  `SplitUTXOsToBenfordCommand.feeRate` are removed**: there is no
  app-chosen rate.
- The split and earmark transactions the payment coordinator provisions
  for a plugin pay the rate the payment asked ARC for, on their signed size.
  They used 148-byte guesses at a hardcoded 100 sat/kB, and the split's fee
  counted a change output it never had.
- The wallet aggregate no longer handles `SplitUTXOsToBenfordCommand`: the
  wallet manager always sent it to the Benford coordinator, so that handler
  was reachable only by calling the aggregate directly.
  `UTXOSplitInitiatedEvent` is kept, for replaying older journals only.

### Channel transactions pay ARC's policy rate — breaking

- A channel's refund and payment transactions paid **1 satoshi**:
  `PaymentChannelBuilder` defaulted to 1 sat/kB and sized the 2-of-2 input
  as a 300-byte guess. The funding paid a hardcoded 100 sat/kB, rounded
  down. All three now pay ARC's published policy rate on their signed
  size, like every other transaction the wallet builds.
- **The server requires it too.** A payment whose transaction pays less
  than the policy rate is refused: the server could never get it mined.
  When ARC cannot give the rate, the channel builds nothing and
  countersigns nothing — an open is reported as a failed funding build,
  to the host and to the server.
- `PaymentChannelBuilder` is `const PaymentChannelBuilder()`; its refund and
  payment builders take `feeRate:`; `PaymentChannelBuilder.paymentFee`.
  **Removed**: `buildFundingTransaction` (a second funding builder, never
  used, that took a raw private key — the wallet aggregate builds fundings),
  `verifyP2PKHSpend`, `estimateFee`, `calculateFee`, `defaultFeePerKb`,
  `minimumFeeSats`, `multisigInputSize`, `p2pkhOutputSize`, `txOverhead`.
- `BuildFundingTransactionCommand.feeRate`, `RecordPaymentCommand.feeRate`,
  `AcknowledgePaymentCommand.feeRate` (required). `ChannelP2PAdapter`
  takes `arcActor:`.

### A channel server countersigns only a payment that pays it — security

- **The server signed whatever transaction came with a channel payment.**
  It checked the proposed balances as numbers, then had the wallet sign the
  client's transaction over the 2-of-2 funding output without looking at
  it, and sent the signature back in `payment_ack`. A client could send a
  transaction returning the whole channel to itself, get it countersigned,
  and broadcast it — taking back every payment it had made.
- Now the transaction must spend exactly the funding output, have lock time
  0, pay the server its proposed balance at its address (the output may be
  absent only while that balance is dust), pay the client no more than its
  balance, and pay no one else. Anything else is refused, and no signature
  leaves the server. The client journals a payment only under the same
  rule.

### A payment pays ARC's policy rate on its signed size — breaking

- **Every payment underpaid.** Its fee was dartsv's estimate, which sizes a
  transaction as it is before signing and leaves out each input's outpoint
  and sequence number, so a payment paid 6 satoshis whatever its size — a
  226-byte one-input payment and a 521-byte three-input payment alike. The
  fee is now ARC's published policy rate on the signed size, with each
  input sized by the unlocking script the wallet writes for it (P2PKH, P2PK,
  or m signatures for an m-of-n bare multisig).
- **A payment asks ARC for the rate first.** If the policy cannot be read,
  the payment is refused and nothing is reserved; no rate is invented. A
  wallet with no ARC configured cannot build a payment.
- UTXO selection counts the real fee. It used to add a flat 1,000
  satoshis, which refused payments a UTXO covered and under-selected when
  the fee was larger. `PaymentReadyEvent.changeAmount` is the change output
  the transaction has; it was `inputs - amount - 1000`.
- The deferred-payment reclaim sizes its held inputs the same way; a
  bare-multisig input was sized as P2PKH.
- **`PayInvoiceCommand.feeEstimateSats` is removed.** It only changed the
  reported change amount.
- `FeeRate` (exported) replaces `ArcFeeAmount`; `ArcPolicyResponse.miningFee`
  is a `FeeRate`. `ArcService.estimateFee` is removed: it sized every input
  as P2PKH. ARCActor answers one fee question, `GetFeeRateMessage` →
  `FeeRateQuote`, in place of `GetFeeQuoteMessage`, `EstimateFeeMessage` and
  `EstimatePolicyFeeMessage`. `PaymentCoordinatorActor` takes `arcActor:`.

### Shutdown waits for ARC work in flight

- `LibSpiffyActorSystem.shutdown()` now returns only after `ARCActor` has
  finished the submissions and retry pass it had in flight. Before, a host
  that closed Isar right after shutdown could crash the process: a failed
  submission queued its retry into the closed store.
  `StopArcWorkMessage` / `ArcWorkStoppedMessage`.

### A channel's funding is retried by the channel, not also by ARC

- `BroadcastTransactionMessage.retryOnFailure` (default `true`): whether
  `ARCActor` queues a submission that did not reach ARC for another
  attempt. Payment channels send their funding and refund with `false` —
  they retry through their own commands — so ARC's queue can no longer put
  a funding on the network after the channel recorded it failed.

### A channel funding's inputs are held until the network has it

- The channel manager marked a funding's inputs spent on any successful
  submission, including one ARC had only stored (`STORED`) or reported
  contested (`DOUBLE_SPEND_ATTEMPTED`). It no longer spends anything: the
  funding is a deferred payment, and its inputs are spent when ARC reports
  it `SEEN_ON_NETWORK` or `MINED`, like every other deferred payment.

### The in-memory backend answers a status query from its index

- `InMemoryWalletStorage.getTransactionsByStatus` reads only the rows with
  that status. It filtered every row of every wallet, so `ARCActor`'s status
  scan, which asks for four statuses, read the whole history four times on
  every pass.

### Change from a broadcast is spendable as soon as the wallet has recorded it

- When ARC reported a transaction on the network before the wallet's read
  model held its recording, its change output became spendable only at the
  next status scan (30 s by default). `ARCActor` now applies the spend
  again from storage a second later, until the recording is there — without
  asking ARC again. `ARCActor(deferredSpendRecheckDelay:)`, default 1 s.
- `wallet-architecture.md`: the ARCActor and SPVActor sections describe the
  actors as they are. The old sketches drove spendability from a
  confirmation count and monitored addresses.

### A payment you receive is submitted, and you are told what ARC said — breaking

In the peer-to-peer model the receiver broadcasts the payment it cares
about. libspiffy now does that on every path a payment arrives by, and
reports ARC's real answer.

- **`ValidateBEEFCommand` is the way to receive a payment.** Once the
  payment validates and the wallet's read model holds it, it is submitted
  to ARC, and `BEEFValidationResultEvent` is emitted **after** ARC answers:
  `broadcasted` (ARC accepted it), `networkStatus` (e.g. `SEEN_ON_NETWORK`,
  `REJECTED`) and `broadcastError`. It used to say `broadcasted: true` the
  moment the payment was handed to ARC's mailbox — before ARC answered, and
  with no ARC configured. A payment carrying its own verified proof is
  already mined and is not submitted.
- **A payment waiting for a block header is no longer lost.** The first
  answer is `BEEFValidationResultEvent(awaitingHeader: true)`; when the
  header arrives the payment is checked again, submitted, and answered
  again — after a restart too. It used to be recorded as an import and
  never submitted.
- **`ReceiveTransactionCommand` is removed.** It was the same pipeline as
  the import and submitted nothing. Use `ValidateBEEFCommand`.
- **`ImportTransactionCommand` accepts only a BEEF carrying the proof of the
  transaction it imports** (recovery, your own history), and is refused
  otherwise. **Its `transactionId` parameter is removed**: the txid is the
  BEEF's.
- `BEEFValidationResultEvent.unreadableOutputs`: outputs of the payment
  the wallet could not read (and so did not credit), as the import's
  `SPVValidationResultEvent` already reported.
- `SPVValidationResult` carries `invoiceId`, `awaitingHeader` and
  `subjectCarriesProof`; `withCounterpartyMarker` is renamed `answering`.
  `BEEF.carriesProofOf(txid)`.

### A transaction ARC rejected is no longer reported as broadcast

- **A submission ARC answered `REJECTED` is now a `BroadcastFailedMessage`.**
  ARC answers every submission with HTTP 200, `REJECTED` included, and
  every 200 was replied to as `BroadcastSuccessMessage`. A payment channel
  whose funding the network refused therefore **marked its funding inputs
  spent**, a refused refund counted as claimed, and `SettleBEEFCommand`
  counted a rejected transaction as submitted. All three now see the
  failure, with ARC's reason.
- `BroadcastSuccessMessage.networkStatus` says how far ARC got
  (`SEEN_ON_NETWORK`, `STORED`, `MINED`, or `DOUBLE_SPEND_ATTEMPTED`, which
  is not final: either spend may still be mined).
  **`BroadcastSuccessMessage` now requires `networkStatus:`** — a breaking
  change for code that constructs one (test fakes).
- `BroadcastFailedMessage.networkStatus` (ARC's answer, when it gave one)
  and `.willRetry` (the transaction was queued for another submission).
- A rejection's reason is kept: submit responses now read ARC's
  `extraInfo`, as status responses already did.
- `ArcTransactionStatus` carries its wire name (`.wireName`,
  `ArcTransactionStatus.fromWire`). `ARCActor.arcWireStatus` is removed.

### Results are frozen too — behaviour change

- **Collections on the coordinator's outbound events are now unmodifiable.**
  `TransactionsResponse.transactions`, `SPVValidationResultEvent.spendableUTXOs`,
  `DeferredPaymentsResponse.payments`, `UTXOSplitCompleteEvent.txids` and the
  rest — 20 fields. **An app that sorts or filters a result list in place
  will now get `UnsupportedError`**; copy it first (`[...event.txids]..sort()`).
- Why this is not the app's own copy: `coordinatorEvents` is a broadcast
  stream, so every listener is handed the **same instance**. One listener
  sorting its result reordered it for every other listener.
- The internal actor messages (`wallet_messages.dart`, `spv_messages.dart`,
  `invoice_messages.dart`, `payment_messages.dart`, 51 fields) now copy and
  freeze what they are built from too, completing what the "Events and
  commands no longer hold the caller's lists and maps" note began: every
  collection on every message libspiffy defines is copied and frozen.

### ARC no longer invents a fee rate, or a mainnet endpoint

- **A fee estimate ARC cannot make is reported as a failure.**
  `_handleEstimateFee` caught the policy failure itself and fell back to a
  hard-coded 1 sat/1000 bytes, so a caller was told **success** with a rate
  no miner published and could build a transaction at a fee nobody quoted.
  It now answers exactly as its sibling `_quotePolicyFee` already did, and
  `FeeEstimateMessage.estimatedFee` is null rather than a guess.
- **No ARC configuration now means no ARC** — it used to mean TAAL
  **mainnet**. `ARCActor` built `ArcServiceConfig.taalMainnet()` whenever it
  was handed no config, so an actor constructed without one silently
  acquired a mainnet endpoint whatever network the wallet was on. (The
  supported entry point, `LibSpiffyActorSystem`, resolves the endpoint from
  the wallet's network and is unaffected.)
- A wallet with no ARC is a supported configuration: it records and proves
  transactions and asks nobody to broadcast them. Broadcasts, BEEF
  broadcasts, status checks, fee quotes, fee estimates, merkle proof
  retrieval and policy fee quotes all report `ARC service not available`
  — seven branches that already existed and could not be reached.
- **`PolicyFeeQuote.fee` is nullable** and null when `success` is false. It
  was documented as "zero when success is false", the same shape removed
  from `FeeEstimateMessage` in the previous release note.

### Recording your own payment is announced, and is no longer reported as a receive

- **Removed: `TransactionReceivedEvent`.** An app that recorded an outgoing
  payment was told, once per output of that payment paying its own wallet
  (change, settlement, self-transfer), that it had **received** the payment —
  `isIncoming: true`, `amountSatoshis: BigInt.zero`. Nothing else was
  announced, so that lie was the app's entire report of its own send. An
  incoming receive is reported by `SPVValidationResultEvent` and
  `TransactionImportedEvent`, which carry the UTXOs and the amount the
  wallet measured, and change from your own payment is not a receive.
- **New: `TransactionRecordedEvent`.** A successful `RecordOutgoingCommand`
  is announced, with the amount **read off the event the wallet journaled**
  rather than restated from the command. It is emitted only once the wallet
  projection has applied the recording — the promise `WalletCreatedEvent`
  and `TransactionImportedEvent` already make, so an app told its payment is
  recorded can query for it.
- `amountSatoshis` is **nullable and null, never zero**, when the command
  journaled nothing because the wallet had already recorded the transaction
  (recording is idempotent): there is no journaled event to read an amount
  off, and an absence is the honest report of one. The recording still
  stands, and `success` says so.
- A recording the wallet refuses is unchanged: it has no reply of its own,
  so it arrives as an `ErrorEvent` naming the request.
- **API:** `TransactionRecordedResponse` gains `paymentAmount` (`BigInt?`),
  the amount the outgoing recording journaled; null for an imported
  transaction and for a recording that journaled nothing.
- **Docs:** `spv-understanding.md`'s transaction receipt flow listed a step 9
  that never existed ("Coordinator emits TransactionReceivedEvent"). The
  wallet manager issues `ReceiveUTXOCommand` with no sender, so nothing on
  that path could answer the coordinator. Corrected to the events it emits.

### Reserved money is reported, and the wallet says what is holding it

- **`BalanceResponse.reservedBalance`** is new: the value of the wallet's
  reserved UTXOs — an application's own reservation, an in-flight payment's
  inputs, or a deferred payment's held ones. It used to be reported nowhere.
  `_handleGetBalance` read `getPaymentUTXOs`, whose contract is
  `isAvailable && !isPluginManaged`, so a reserved row was filtered out
  before the handler saw it and the money vanished from every number the
  coordinator gave out. A wallet whose only funds were a stuck channel
  funding reported zero everywhere.
- It is **reported apart from `totalBalance`**, the same treatment
  `watchOnlyBalance` already has: the wallet's money, and not spendable
  right now. All four numbers are computed from the same UTXO rows in one
  read, so no bucket can be a moment older than the one beside it.
- **A refusal now names the reservation that emptied the wallet.**
  `WalletBalances.noneSelectableReason` walked the available UTXOs alone,
  so a reserved one was dropped before any reason was computed and the
  caller got the bare headline — including the wallet frozen by a journaled
  deferred hold, which is the one case its "inputs of a deferred payment"
  branch existed for. Channel funding (`No available UTXOs for funding`)
  and the Benford split (`No available UTXOs to split`) both say it, and
  say the same thing about the same wallet.
- **A hold and a reservation are told apart**, because they are different
  answers: *"inputs of a deferred payment, held until it settles or is
  reclaimed"* has no expiry and ends only with the payment, while *"reserved
  for a payment in flight"* expires and cleanup releases it.
- **API:** `WalletBalances.isDeferredHeld` and
  `WalletBalances.deferredHoldReason` are new.
  `WalletBalances.noneSelectableReason` no longer takes `held:` — the walk
  asks `isDeferredHeld` itself, so the predicate channel funding used to
  pass, which was dead for every journaled hold, is gone.

### Every actor reply can be asked whether it worked

- Sixteen replies implemented `Message` only, so a caller holding one could
  not ask the question the other forty-three answer. They now extend
  `ActorResponse` and carry `success` and `error`:
  `TransactionStatusMessage`, `FeeQuoteMessage`, `FeeEstimateMessage`,
  `WalletListMessage`, `SPVValidationResult`, `SPVStatusMessage`,
  `SPVErrorMessage`, `HeaderSyncStatusMessage`,
  `BlockHeadersProcessedMessage`, `InvoiceDetailsResponse`,
  `InvoiceStatusMessage`, `InvoicesListMessage`, `BroadcastSuccessMessage`,
  `BroadcastFailedMessage`, `ImportCancelResponse`, `ImportProgressMessage`.
  Where a pair already existed under other names it was reused, not
  duplicated: `SPVValidationResult.isValid` is `success`,
  `InvoiceDetailsResponse.found` is `success`, and so on.
- **Three of them reported failure as a value you could act on, and no
  longer do:**
  - `FeeEstimateMessage.estimatedFee` is **nullable** and null when no
    estimate could be made. It used to be `BigInt.zero` — a fee an app
    would happily build a transaction with.
  - `FeeQuoteMessage.feeData` holds fee rates and nothing else. Three of
    the four sites that send it used to put `{'error': ...}` in the map.
  - `TransactionStatusMessage.status` is **nullable** and null when the
    status could not be read. It used to be the string `'error'`, which no
    caller could tell from a status ARC had really reported.
- **Removed:** `TransactionValidationResult` and the duplicate
  `BEEFValidationResult` in `spv_messages.dart`. Neither was sent or
  received anywhere; the live `BEEFValidationResult` is the one in
  `wallet_messages.dart`, which `spv_actor.dart` had to `hide` the other to
  reach.

### The wallet says when it could not do what you asked

- `WalletManagerActor` and `BitcoinWalletAggregate` answered failures they
  had no typed reply for with a bare `{'error': ...}` map, and
  `PaymentChannelAggregate` answered success with a raw `List<Event>`.
  Callers told success from failure by testing the runtime shape of the
  reply, and could not tell which actor had answered.
- **The bug this was hiding:** `WalletCoordinatorActor` did not recognise
  those maps at all. A **delete, recording, release or split the wallet
  refused produced no `CoordinatorEvent`** — an app that learns everything
  through `coordinatorEvents` waited for an answer that never came. It now
  emits an `ErrorEvent` naming the request, or fails a still-pending
  creation by name.
- Two of those commands were told to the wallet manager with **no sender**,
  so nothing was ever going to answer them. `RecordOutgoingCommand` and
  `ReleaseUTXOsCommand` now carry one.
- **New public types.** `FailureResponse` is the base of a reply that can
  only report failure: `success` is always false and `error` is never null.
  `WalletManagerFailure` (the manager could not route or handle a request)
  and `WalletCommandFailed` (the wallet aggregate refused a command it has
  no specific reply for) extend it. Match `FailureResponse` for "this
  failed, and why"; match the concrete type to tell which actor gave up.
- `PaymentChannelAggregate` answers `ChannelCommandResult`, which carries
  the events the command journaled — the manager forwards them to the P2P
  broadcaster and reads fields off them, so they are part of the reply, not
  diagnostics. An empty `events` on a success is still a success: an
  idempotent repeat journals nothing.
- **Breaking for code that matched the old shapes.** `payload is Map` no
  longer identifies a failure, and a channel command's reply is no longer a
  `List`. There is no silent fallback: the old shapes are gone.
- A successful `RecordOutgoingCommand` is still not announced. The handler
  that would have announced it was unreachable and reported
  `amountSatoshis: BigInt.zero` for an amount it did not hold, so it was
  removed rather than made live with that number in it.

### Events and commands no longer hold the caller's lists and maps

- An event or command built from a caller's `List` or `Map` kept **that
  object**, not a copy. The journal was safe (serialization copies), but an
  event is handed live to the projection, to every `coordinatorEvents`
  subscriber and to the P2P broadcaster, so an app that went on modifying
  the list it had passed changed what all three read.
- Every collection a caller hands in is now **copied and frozen** in the
  constructor: the 52 collection fields of the aggregate events and commands
  (`wallet_`, `invoice_`, `channel_events`/`commands`) and the 16 of the
  app → coordinator commands in `coordinator_messages.dart`. Nested maps and
  lists are copied too, as are the key list of a `P2MSOutputSpec`, the data
  chunks of an `OPReturnOutputSpec` and the params of a `PluginOutputSpec`.
- **Behaviour change for callers who mutate what they read back.** These
  collections now throw `UnsupportedError` on modification, as aggregate
  state already did. Nothing in libspiffy mutates one; an app that changed
  an event's or a command's list in place must copy it first.
- Replay is unaffected: `fromMap` already built fresh collections.
- The coordinator's **outbound** results (`WalletUTXOsResult.spendableUTXOs`
  and the other query results) are unchanged — they are still ordinary
  mutable lists, and freezing them is tracked separately.
- New in `persistent_map.dart`: `frozenList`, `frozenListOrNull`,
  `frozenMapList`, `frozenPlainMap`, `frozenPlainMapOrNull`, `frozenSet`,
  `frozenSetOrNull`. New in `invoice_output_spec.dart`: `frozenOutputSpec`,
  `frozenOutputSpecs`, `frozenOutputSpecsOrNull` (moved out of
  `InvoiceState`, which was the only place that knew an output spec hides
  mutable collections).

### A receive replayed after a restart reaches the app, not only the wallet

- A receive parked waiting for a block header outlives the process that took
  it, and the caller's `ActorRef` dies with that process. So when the header
  finally arrived the wallet was credited and **nothing appeared on
  `coordinatorEvents`**: an app restarted between the park and the header
  could learn of the funds only by polling the read model.
- `SPVActor` now answers the coordinator whenever no caller is waiting, so a
  replayed receive produces the same `SPVValidationResultEvent` and
  `TransactionImportedEvent` a fresh delivery does. Only a **verdict** is
  announced — a receive that goes back to waiting for a header is not an
  outcome, and announcing one would tell an app "import failed" about a
  receive that is fine.
- **The startup replay moved.** Receives whose headers arrived while the node
  was down were replayed in `SPVActor.preStart`, which runs before the
  coordinator exists — so that credit was silent by construction. The replay
  now runs when the coordinator registers itself
  (`SetCoordinatorForSPVMessage`), so the credit and the announcement happen
  together. A header notification still replays them too, as before.
- **A startup report is no longer lost to a late subscriber.**
  `coordinatorEvents` is a broadcast stream, so an event emitted with no
  listener was dropped — and an app using `LibSpiffyActorSystem` can only
  subscribe after `initialize()` returns. Events emitted before anything
  listens are now kept (bounded at 256) and delivered to the first listener,
  then the window closes. This also makes the startup report of unfinished
  channels reliable, which had the same race.

### A UTXO event no longer reads the wallet's spend history

- **New on `ReadModelStorage`:** `getUTXO(walletId, txid, vout)` for one
  outpoint, `getUTXOsByTxid(walletId, txid, {includeSpent})` for one
  transaction's outputs, and `countSpentUTXOs(walletId)`.
- Every UTXO event made the wallet projection load every row the wallet had
  ever held, spent ones included, because there was no way to ask the read
  model about a single outpoint. A spend history is never purged by design
  (`spv-understanding.md`, Data Retention), so the cost of every future event
  grew with every spend the wallet had ever made. **Measured**: four spends
  deep, an event read 7 UTXO rows; two hundred deep, 203. It now reads
  between 1 and 5 at either depth, and an event that decides it has nothing
  to do reads the one row it decided on.
- The balance recalculation wanted the spend history only for two counts it
  publishes, `spentUtxoCount` and `utxoCount`. Both now come from
  `countSpentUTXOs`, which counts through an index without deserialising a
  row; their meaning is unchanged.
- A confirmation, a reorganisation that takes one back, the voiding of a
  transaction's own change, and `SPVActor`'s restore of confirmations after a
  reorganisation all ask for that transaction's outputs now, instead of
  loading the wallet's rows and filtering them on `txid` in Dart.
- **No data migration.** Postgres answers all three through the
  `uk_utxo (wallet_id, txid, vout)` constraint and `idx_utxos_wallet_status`,
  both there since v001. Isar gains a composite `(walletId, txid)` index,
  which it builds on open — a schema addition, not a data change — because
  its plain `txid` index also covers other wallets' rows for the same
  transaction, and audit S-16 forbids a wallet-scoped query reading another
  wallet's rows.
- `getUTXOs(includeSpent: true)` stays: an app may legitimately want every
  row a wallet has ever held. Nothing inside libspiffy asks for them any
  more, and a test over `lib/` keeps it that way.

### One network default, everywhere

- A wallet row created without a `networkType` is **testnet** on all three
  storage backends. It was `'mainnet'`, while `NetworkName`, the wallet
  aggregate, the SPV parameters and the actor system all resolve an
  unspecified network to testnet. A caller of the exported
  `ReadModelStorage.storeWallet(id, name)` therefore created a row that read
  back as mainnet — `isMainnet`, MAIN address encoding — for a wallet the
  aggregate considered testnet: the mainnet/testnet disagreement between
  layers of V-1 and V-2, waiting in the public API.
- `storeWallet` now **canonicalises** the network it is given, so the
  `'main'` / `'test'` / `'regtest'` spelling the actor system, importer and
  P2P layer use is stored as the read model's own
  `'mainnet'` / `'testnet'` / `'regtest'` and never sits in a row beside it.
- A null `networkType` still means *keep the stored network*, as it does for
  `rootAddress` and `metadata`. The default applies only when the row is
  created.
- `WalletState.empty` and `WalletReadModel.empty` default to testnet for the
  same reason, and testnet is the safe direction to be wrong in: a wallet
  wrongly taken for testnet cannot encode an address that receives real
  coins.
- **Nothing to migrate, and no row is rewritten.** libspiffy's only insert
  path, `WalletProjection._handleWalletCreated`, has always canonicalised
  before storing, and its other three `storeWallet` calls are updates that
  resupply the row's own network — so no row libspiffy wrote ever took the
  old default. A row an external caller created with it keeps what it has;
  which network was meant is not something this library can know.
- The rule lives in one place, `WalletRowRules.defaultNetwork` and
  `WalletRowRules.canonicalNetwork`, called by all three backends. Neither
  it nor `NetworkName` is exported yet, so an app reading the `network` entry
  from the exported `ReadModelStorage` still has to compare strings by hand —
  the thing `NetworkName` exists to stop (libspiffy-47np).

### Payment channels: stuck channels are reported at startup

- **New:** `UnfinishedChannelsFoundEvent` on the coordinator event stream,
  emitted once at startup for each wallet that has channels which started
  opening and never reached `open`. It carries the channel id, its state,
  the funding amount, the lock time at which the client can reclaim it, and
  the counterparty's peer id.
- Recovery was reactive: a channel's record is rebuilt only when something
  arrives naming it, and a channel whose funding failed or whose
  `channel_open` was lost is exactly the case where the counterparty has
  gone quiet. An app that did not poll its own channel list never found out.
- **The sweep reports and nothing else** — it never retries, journals, or
  contacts a peer. A funding broadcast whose outcome was lost may already be
  in a mempool, and BSV is first-seen-wins, so re-driving a channel is the
  app's decision: `RetryChannelFundingCommand` and `ResendChannelOpenCommand`
  to carry on, or `CancelDeferredPaymentCommand` to take the inputs back.
- No event means no channel of that wallet needs attention.

### Payment channels: the manager says when it has no read model

- `PaymentChannelManagerActor` warns at startup when it is built without a
  read model, naming what stops working — most importantly that a client
  channel cannot open, because its funding is then sent with no BEEF and
  servers refuse it. The constructor documents each dropped guarantee.

### Payment channels: a refused payment is answered, and a re-send is a repeat

- **Fixed:** a `payment_update` the server refused produced no answer at all
  — no `payment_ack` and no `channel_error` — so the client waited forever
  with no way to tell a refusal from a lost message. A refusal now reaches
  the client as `channel_error`.
- **Fixed:** a repeated `channel_accept` or `refund_signed` was refused by a
  state guard, and the refusal reached the counterparty as `channel_error`
  — so a peer re-sending *because it was unsure the first arrived* was told
  its channel had failed. A repeat naming the same fact is now answered
  without journaling; one naming a different fact is still refused.
- **Fixed:** the channel manager treated "the aggregate accepted this and had
  nothing new to journal" as `Command failed: no events emitted`. That
  affected paths that already returned no events, including a re-delivered
  `payment_ack` and a resumed channel ending.

### Payment channels: one rule for a payment, and one refund claim

- **Fixed:** the client half of the payment protocol did not check that the
  proposed balances were non-negative or that they still summed to the
  funding amount; the server half did. Both now check one shared statement
  of the rule. The two balance-mismatch errors became one message naming
  both sides and both expected balances.
- **Fixed:** a repeated `ClaimChannelRefundCommand` journaled a second
  `RefundClaimedEvent`. A repeat naming the same refund transaction is now
  answered without journaling a second ending; one naming a **different**
  transaction is refused, because only one transaction can ever spend the
  funding output.
- `FullChannelStateResponse.refundClaimedTxId` tells a host whether a
  channel's refund has actually been claimed. The status does not: a claim
  and an expiry both leave the channel `expired`, and `expired` has to stay
  claimable because an expiry seen first records the refund without
  broadcasting it.

### The UTXO split reports what actually happened

- **Fixed (false success):** a Benford split that failed before it built a
  transaction — the source too small for the fee, the wallet refusing to
  reserve it, or the transaction failing to **build or sign** — was dropped
  from the answer entirely. When every source failed that way the caller was
  told `success: true` with an empty result. Every source the split attempts
  is now reported, with the reason it produced no transaction, under the new
  `SplitTransactionStatus.notBuilt`.
- **Breaking:** `SplitTransactionOutcome.txid` is now nullable. It is null
  exactly for `notBuilt`, where there is no transaction to name;
  `sourceUtxoKey` is always set, so a host can still say which UTXO it was.
- **Fixed (wrong number):** `UTXOSplitCompleteEvent.transactionCount` was fed
  from a UTXO count, so with the default `targetUtxoCount: 5` **one split
  transaction was reported as five**. It is the number of transactions now.
  `newUtxoCount` is unchanged and still counts outputs.
- **Fixed (invented number):** `totalFeePaid` was hard-coded to zero. The fee
  is carried through on the new `SplitTransactionOutcome.feePaid` — the
  source minus the signed transaction's outputs, null when nothing was built
  — and summed over the splits that succeeded. Zero now means no split
  succeeded rather than "not measured".
- The transaction builder was given the fee rate in satoshis per byte where
  it expects satoshis per kilobyte. It changed nothing, because split outputs
  are explicit and there is no change output, but the unit is correct now.
- The split no longer sleeps 10 microseconds per generated address; the
  command ids it was protecting are unique without it.

### A wallet that lost its account xpub can derive addresses again

- **Fixed:** a wallet whose `wallet_hdpubkey_<walletId>` was missing from
  secure storage could never generate another address — it threw
  `StateError: HD public key not found` for the life of the wallet, although
  the mnemonic or xpriv the xpub derives from was usually sitting beside it
  in the same secure storage. It could still *sign*, because the private-key
  lookup already fell back to the xpriv and the mnemonic. Address derivation
  now walks the same chain: the watch-only xpub, then the xpriv, then the
  mnemonic with its passphrase.
- **A recovered xpub is used only if it re-derives the wallet's root address.**
  A mnemonic wallet's xpub depends on its BIP39 passphrase, so a secure
  storage that lost the derived key may have lost the passphrase too — and
  the mnemonic alone then derives a *different* wallet. Addresses from that
  key could not be signed for, so a recovery that cannot be verified is
  refused, naming the passphrase as the likely cause.
- A verified recovery is written back to `wallet_hdpubkey_<walletId>`, so it
  happens once rather than on every address.
- When nothing can be recovered the error names every key that was looked
  for, so a host can tell a lost secret from a lost derived key, and says
  that the wallet's existing addresses and their coin are untouched.

### Wallet metadata is merged on every backend, not replaced on one

- **Fixed (data loss, Postgres only):** `storeWallet` REPLACED the whole
  `metadata_json` document on the Postgres backend, where Isar and in-memory
  merged it. Any caller that stored a partial map — which the documented
  contract says is safe — lost every key it did not resupply. The wallet
  projection's own `WalletCreated` handler writes a fresh map, so **replaying
  a Postgres journal wiped host metadata**. The column is already `JSONB`;
  there is no migration and nothing is stored differently.
- **Fixed:** `getWallet` returned `'metadata': null` on Postgres where the
  other backends return an empty map. It is now always a map. Rows already
  stored are covered, because the value is normalised on read.
- **Written down, because it was never true on any backend:** a store cannot
  remove a metadata key. Writing a key null blanks it and keeps it; the whole
  document goes only with `deleteWallet`. Postgres could remove keys before
  this release, but only as a side effect of the bug above.
- The merge rule now lives in the shared wallet lifecycle contract test that
  runs against all three backends, instead of a copy per backend — it diverged
  precisely because it was duplicated.

### Postgres: typed journal errors, a cheaper id scan, and private-CA TLS

- A failed append now throws **`EventStoreException`** naming the journal, the
  batch size and the SQLSTATE, instead of leaking the driver's own exception.
  The original is kept as `cause` and its stack trace is preserved. Concurrency
  conflicts still throw `ConcurrencyException`, unchanged. **If you catch
  `ServerException` around a persist call, catch `EventStoreException` now.**
- `currentPersistenceIds()` no longer runs an unbounded `SELECT DISTINCT` over
  the whole journal. It walks the existing index in pages, so the work follows
  the number of distinct ids rather than the journal's length. Nothing is
  stored differently and no row is trimmed. Note the read is now paged rather
  than a single snapshot.
- `PostgresConfig` gains `sslRootCertPath`, `sslRootCertBytes` and
  `securityContext`, so a server using a private certificate authority can be
  verified. Defaults are unchanged. Supplying a CA without an explicit
  `sslMode` selects `verify-full` rather than `require` — under `require` the
  driver ignores certificate problems, which would make the CA decorative.

### Dead code removed, and what must never be removed marked as such

- **Removed:** `TransactionLifecycleCoordinator` (its `onMessage` was empty and
  it subscribed to nothing), its getter on `LibSpiffyActorSystem`, and its
  spawn — so no actor named `transaction-lifecycle-coordinator` exists any
  more. Six unused fields on `WalletCoordinatorActor`. A generic error
  responder in the channel manager that could only ever duplicate a reply or
  send one to the wrong actor.
- **Deprecated, not removed:** two commands no aggregate handles, three
  constructor parameters that are now ignored, and the `isolateConfig`
  parameters.
- **Deprecated and kept permanently:** six event classes nothing emits. They
  are registered for replay, and a journal written by an earlier release may
  contain them — deleting a class would make that journal unreplayable. Each
  one now says so where a future reader will look.
- Three comments claiming unfinished work over finished code, deleted; and the
  unused `unorm_dart` dependency dropped.

### A funding whose money came back cannot be broadcast again

A channel funding that never reached the network holds its inputs through a
deferred payment. The app can already take that money back with
`CancelDeferredPaymentCommand` — the funding is recorded with
`purpose: 'channel-funding'`, and cancelling asks the network first, so a
transaction that did reach the mempool is never released out from under.

What was missing is that the channel did not know. A failed funding leaves
the channel waiting for its broadcast indefinitely, so after an app took its
money back the channel still looked retryable — and retrying re-broadcast a
transaction whose inputs the wallet had released and may since have spent.

A funding re-broadcast is now refused, in plain words, once the wallet's own
record of that payment says its inputs were cancelled, rejected by the
network, or reclaimed. The refusal covers every route to a re-broadcast, not
just the public retry command. A funding whose hold is intact is unaffected,
and a funding with no such record at all still proceeds: an absence is not
evidence that anything was released.

### An open that did not finish can be repaired

Restart recovery is reactive: it rebuilds what it needs when a peer's message
names a channel, and never sweeps channels whose funding broadcast failed. A
host had no lever over those at all — the only route was an internal message
that needs the funding transaction spelled out, which a host does not have.

Two new public commands, each with a public outcome event:

- **`RetryChannelFundingCommand(channelId)`** → `ChannelFundingRetriedEvent`
  re-broadcasts a client channel's funding transaction. The caller supplies
  only the channel id; the transaction is read from the channel's own state.
- **`ResendChannelOpenCommand(channelId)`** → `ChannelOpenResentEvent` sends
  `channel_open` again, rebuilt from journaled state. It journals nothing.

They are two commands rather than one because their preconditions are
mutually exclusive, and each refusal names the other.

**Neither can emit `channel_error`.** That matters: re-driving the open flow
for an already-open channel used to fail the aggregate's status guard and
route to the counterparty as `channel_error` — so a host repairing a lost
message would have told the peer the channel was abandoned instead.

Relatedly, a `channel_open` repeating a channel's **own** funding output is
now a no-op answered `success` rather than a rejection, so the peer does not
answer a repair with the message that says the channel failed. A repeat
naming a different funding output is still refused.

### A refund claim says whether the money came back

Fixes a gap in the refund-claim flow above: the adapter forwarded the command
with no reply target, so the manager's response went nowhere, and there was
no event for it either. A host that claimed a refund could not tell one that
landed from one the network refused as a double spend. There is now a
`ChannelRefundClaimedEvent` carrying the outcome and the refund txid. The
counterparty is told nothing either way — a refund the network refused has
abandoned no channel.

### A channel refund can actually be claimed

`ClaimRefundCommand` had an aggregate handler, tested guards, a journal
event and a projection arm — and nothing in the library ever built it. A
client whose counterparty had gone silent held a fully signed refund with no
way to broadcast it. The new public `ClaimChannelRefundCommand` runs the
expiry path plus the one thing expiry deliberately does not do: a broadcast.

It broadcasts first, then journals the claim, then records the money in the
wallet — a claim is a claim about the network, so nothing the network refused
is journaled as claimed. A rejected broadcast (most likely the counterparty's
settlement having reached the network first) is a terminal answer reported on
the response: **there is no replace-by-fee on BSV and nothing is retried at a
higher fee**. ARC is asked because the refund is our own transaction.

Expiry already recorded the return leg without broadcasting it, so two routes
can now record the same refund. Both orderings are pinned by tests and leave
exactly one wallet transaction row and one `RefundClaimedEvent`.

One guard was missing and is added: the aggregate accepted a refund claim on
a cooperatively **closed** channel, journaling a second ending for a funding
output the settlement had already spent. `ClaimRefundCommand` on a `closed`
or `rejected` channel now throws. `expired` stays claimable — that is the
convergence path.

API additions: `ClaimChannelRefundCommand` (public), `ClaimRefundMessage`,
`ChannelRefundClaimedResponse`, `ChannelP2PAdapter.handleClaimRefund`.

### Channel transactions name their counterparty

Every payment the wallet records should carry an opaque, app-chosen marker
naming the counterparty it was with. Payment-channel funding, settlement and
refund records passed none, so every row a channel wrote was blank.

The app supplies the marker; where it supplies none, the channel's
counterparty **peer id** is the fallback — a fact the channel holds, never an
invention. One helper resolves the rule and both recording sites call it, so
a channel's funding leg and its return leg can never be stamped differently.
The marker is taken from the local `AcceptChannelCommand`, never from an
inbound peer's payload: it is the app's own naming of its counterparty.

`counterpartyMarker` is a new optional field, deliberately **not** a reuse of
the existing `context`, which is already consumed as address-derivation
metadata — one field cannot carry two meanings.

Behaviour note: channel transactions recorded before this change keep their
blank marker, because a marker is set once and never replaced. Old journals
and snapshots replay unchanged (a missing key reads as null and falls back to
the peer id).

API additions (all optional, all defaulted null): `counterpartyMarker` on
`OpenChannelCommand`, `AcceptChannelCommand` (both the coordinator and the
core command), `InitiateChannelMessage`, `AcceptChannelMessage`,
`RequestChannelCommand`, `ChannelRequestedEvent`, `ChannelAcceptedEvent`,
`ChannelState` and `FullChannelStateResponse`.

### An output the wallet can never spend is not a wallet UTXO

Report section 11, V-97.

- **A P2PK output locked to a key the wallet neither holds nor watches is
  now refused at receive (V-97)**, as an unmeetable bare multisig already
  was. The guard reads the script, not the address the output is filed under.
- **A watch address is not refused.** The wallet holds no key for one and
  never will; tracking exactly that is what a watch address is for. Such an
  output is taken on, reported as watch-only funds, and never selected.
- **Replay is unchanged.** `applyReceived` still validates no script, so a
  journal written before this guard replays exactly as it did. Nothing
  already recorded is dropped, and V-93's rule is what keeps those rows out
  of the spendable balance.
- **A P2PK output pushing the uncompressed encoding of a key the wallet holds
  compressed was judged not the wallet's** — left out of the spendable
  balance on both layers while the signer signed it happily. Both layers now
  ask `p2pkAddresses`, which answers for both encodings. This matters for
  watch addresses in particular: the wallet derives its own addresses
  compressed, but a watch address is whatever the user handed us.

### The signer says which key it is missing

Report section 11, V-96.

- **A P2PK input the wallet holds no key for failed with a script-engine
  error instead of a reason (V-96).** `unlockFor`'s P2PK branch signed with
  whatever key the UTXO's attributed address named, while the P2PKH branch
  beside it checks that the key controls the script. It now has the same
  check, `requireKeyForP2pk`, and either encoding of the same key satisfies it.
- **Nothing invalid was escaping.** The bead was filed on the premise that
  this produced a silently invalid unlocking script; it did not.
  `signTransaction` runs every input it signs through the script interpreter,
  so the transaction was refused — just with
  `SCRIPT_ERR_EVAL_FALSE: Script resulted in a non-true stack`, which names
  neither the output nor the reason.
- **That interpreter check was pinned by no test at all** — deleting it left
  422 tests green. It is load-bearing by design: a script type the signer has
  no standard unlocking script for is signed with the address's key and left
  for the interpreter to judge. It is pinned now.

### One rule for what the wallet can spend alone

Report section 11, V-93 to V-95 — the rest of the V-85 sweep.

- **A P2PK output locked to someone else's key counted in the spendable
  balance (V-93).** The write side excluded it from spending and the read side
  counted it, the two layers disagreeing about the same output. Reported as
  low confidence because no path seemed to attribute such an output to a
  wallet; **it is reachable on both paths** — `ReceiveUTXOCommand`'s only
  script guard is for bare multisig, and replay validates no script at all, so
  any journal can carry such a row.
- Both layers now call one predicate, `unlocksAlone`: a bare multisig must
  meet its threshold, a P2PK must be to a key the wallet holds, everything
  else is true. `ChannelFunding`'s private copy is **deleted**, so there is no
  second rule to drift.
- **Breaking in effect, not in signature:** a wallet holding such an output
  will see its spendable balance drop to the honest figure. The output is
  reported under `notSpendableAlone` instead. Nothing is deleted or
  reclassified away — the row, its transaction and its proof are kept, and it
  is still listed by `getPaymentUTXOs`; it is only never selected.
- **A stored column named `isSpendable` held `status == available` alone
  (V-94).** Nothing read it, which is the only reason it was not a live bug.
  It is renamed to `isAvailable` / `is_available` (**Postgres migration
  v024**) rather than corrected: `isSpendable` depends on wallet-level state
  the row does not carry, so a stored copy would go stale as a **true** — the
  dangerous direction — the moment a watch address is added or a key derived.
  `fromJson` still accepts the old key, so existing backups restore unchanged.
- **Two hand-rolled copies of the plugin rule, one in a test (V-95).** The
  watch-only listing filtered on `hasPluginMetadata` rather than
  `isPluginManaged`; so did a helper in `token_utxo_filtering_test.dart`
  commented "Replicate the aggregate's logic for testing" — a duplicate of the
  very predicate that file exists to pin. It calls the real rule now.
- The Benford split's refusal names which exclusion emptied the wallet
  (plugin-managed, watch-only, deferred hold, cannot-unlock-alone) instead of
  saying only that it found nothing. One shared helper with channel funding,
  not a second copy.

### A delivery is journaled once

Report section 11, V-92.

- **The same delivery handed to a wallet twice journaled it twice (V-92).**
  `RecordImportedTransactionCommand` had no idempotency guard, so it depended
  on every caller checking a read model first — and the channel manager's
  check is a no-op when it is built without storage.
- **Only an exactly equivalent re-delivery is dropped.** "Already recorded"
  cannot mean "the wallet holds this txid": a delivery carries evidence the
  wallet's own record does not keep — the raw transaction, the BUMP, the BEEF
  ancestors, which of our addresses it pays, the counterparty marker — and the
  read model is built from these events. The imported record keeps a digest of
  the last delivery, and a command is dropped only when the event it would
  journal is identical to it.
- A proofless re-delivery of a transaction a proof already placed in a block
  is still journaled, and the established height is kept (V-80 unchanged). A
  delivery re-sent after a different one is journaled again rather than
  compared against a growing list of digests: a duplicate is recoverable,
  lost evidence is not.
- Records written before this change carry no digest and drop nothing.
- An identical re-delivery no longer refreshes `lastImportedAt`. The imported
  record gains a `delivery` key (64 hex characters per imported transaction)
  in the wallet's state metadata.

### An interrupted expiry can be resumed

Report section 11, V-91.

- **An expiry that journaled and then crashed lost the refund record for good
  (V-91).** `_handleExpireChannel` journaled `ChannelExpiredEvent` and *then*
  wrote the wallet. The aggregate refuses to expire an already-terminated
  channel, so a re-delivered expiry — what an app does after a restart, expiry
  being app-driven — was answered `success: false` and nothing retried the
  write. The money came back and the wallet never heard.
- Expiry now has the shape the funding path has had since `fsy`: a
  `RecordReturnLegInWalletCommand` → `ReturnLegRecordedInWalletEvent` sets
  `ChannelState.returnLegRecordedInWallet`, and the manager reads it first. A
  channel already `expired` with the write journaled does nothing; one already
  `expired` without it skips the doomed expire command and does the write that
  was lost.
- **The cooperative close journals the same event**, though its `closing`
  middle state already made it resumable: a flag only the expiry route set
  would read `false` on every closed channel whose return leg *is* recorded.
- A second record journals nothing rather than failing: the manager issues it
  straight after a wallet write that may itself have been a no-op on a resumed
  ending.
- New journal event type `channel.return_leg.wallet_recorded`.
  `FullChannelStateResponse.returnLegRecordedInWallet` is new (additive).

### A client's money comes back too

Report section 11, V-90. The second half of V-86, which reported this and
could not close it.

- **The client threw the server's countersignature away (V-90).** A channel's
  2-of-2 funding output needs both signatures. The client signs when it
  records a payment and keeps only its own half; the server's half comes back
  **once**, in the `payment_ack` message — and the adapter logged the
  acknowledgement and dropped the signature. The client went on holding the
  unsigned template, whose txid is not the signed transaction's, so a client
  cooperative close recorded nothing in the wallet and left the channel in
  `closing` for good. The client's return leg arrived only by the
  expiry/refund route.
- The client now journals it: `RecordPaymentCountersignatureCommand` →
  `PaymentCountersignedEvent`, which replaces the template in the write model
  and the read model. `ChannelState` keeps `latestClientSignatureHex` so the
  two halves can still be combined after a restart.
- **A settlement that does not verify is not recorded.** It is assembled and
  checked against the funding output before the command is issued, by the
  same code the server's acknowledgement path uses — one implementation, so
  the two sides cannot drift. A failure leaves the template and an absence,
  never an invented transaction.
- A countersignature for any sequence but the latest is refused: a signature
  for an earlier payment would replace the settlement with one paying the
  client more than it is now owed. A re-delivered `payment_ack` journals
  nothing.
- **`ChannelClosedResponse` gains `finalized` and `settlementTxId`
  (additive).** It used to answer `success: true` even when nothing was
  finalised and the channel stayed in `closing`, telling the caller a channel
  had closed when it had not. `success` still means the close was accepted
  and journaled; `finalized` says the channel actually reached `closed`.
- New journal event type `channel.payment.countersigned`.

### A transaction's lock time survives being stored

Report section 11, V-88 and V-89. Both found by the reachability sweep,
`doc/reachability-sweep-2026-09-18.md`.

- **`nLockTime` and `version` read back as `0` and `1` on Isar and
  PostgreSQL (V-88).** The write path carried both correctly and storage had
  no column for either, so both backends invented a value while the
  in-memory backend answered truthfully — the same wallet gave different
  answers depending on its backend. `0` is not a neutral default for an
  `nLockTime`: it means "no lock at all", so a channel refund locked until
  its deadline read back as spendable now.
- Both fields are now stored (Isar fields; **Postgres migration v023**,
  `BIGINT` for the unsigned 32-bit range, backfilled from `raw_hex` in paged
  batches). One shared rule serves all three backends and the migration, and
  it is **set once, never blanked and never revised** — the txid commits to
  both fields.
- **The raw hex outranks the record.** Hex that deserializes *and hashes to
  the row's own txid* is the transaction; a record naming something else is
  restating it wrongly, the defect V-83 fixed on the funding reply. The
  record answers only when the hex is absent, unreadable, or belongs to
  another transaction.
- **Breaking:** `BitcoinTransaction.lockTime` and `.version` are now `int?`
  and no longer required. A row whose record carried neither and whose raw
  hex cannot be read answers `null` — following V-80, an absence rather than
  a plausible value. Readers must handle `int?`.
- **`getTransactionAddresses` was blind to everything the wallet sent
  (V-89).** Address junctions were built only on the import route, so the
  whole outgoing side was missing from the address-centric index. Both routes
  that create a transaction row from its bytes now build them; the four that
  only move a status, height or marker rewrite nothing.
- **Input links no longer invent their address, index or amount.** They were
  paired to inputs *by position* against a deduplicated address list that
  skips unreadable scripts, with `amount: BigInt.zero`. Each link is now
  keyed to the input's own outpoint and carries the parent output's real
  address and amount, resolved from the event's BEEF ancestors, the ancestor
  store, our own transaction rows, or — for our own payments — the wallet's
  UTXO row. An input with no evidence is left **unlinked** and logged, not
  given a guess.
- Existing junction rows are rewritten the next time a transaction's event is
  projected; a projection rebuild corrects historical rows.

### The journal stops claiming every broadcast succeeded

Report section 11, V-87. Found by the reachability sweep,
`doc/reachability-sweep-2026-09-18.md`.

- **`TransactionBroadcastEvent.broadcastResponse` was the literal
  `'broadcast_success'` on every event the wallet ever journaled (V-87).**
  The aggregate wrote it with the comment "Placeholder - will be set by ARC
  service", and `BroadcastTransactionCommand` had no field for ARC's answer,
  so nothing could ever set it.
- Nothing downstream was wrong: all four ARC sites send the command only
  after a submission returns, and ARC's real status already reached the read
  model by another route. The defect was a fabricated field sitting
  permanently in an immutable journal.
- `BroadcastTransactionCommand` gains an optional `broadcastResponse`
  (additive), `ARCActor` passes ARC's wire status at all four sites, and the
  aggregate records what it was given.
- **Breaking:** `TransactionBroadcastEvent.broadcastResponse` is now
  `String?` and no longer a required constructor argument. Its serialized
  form omits the key entirely when null, so an absence is an absence rather
  than a stored placeholder. No consumer exists in the library; the field was
  write-only.
- **Old journals replay unchanged** and still read `'broadcast_success'`.
  That value is evidence of nothing. The event class, its stable type name
  and its replay registration are untouched, because a journal is permanent.

### A channel's money comes back into the wallet

Report section 11, V-86.

- **Closing or expiring a channel now records the return leg (V-86).** The
  manager wrote to the wallet only when funding a channel, so the settlement
  or refund never reached the transaction history, its outputs never became
  UTXOs, and the balance never showed the funds coming back. It is recorded
  as a **receive**: the 2-of-2 funding output is not a wallet UTXO, so a
  settlement spends no wallet input and only creates wallet outputs.
- **A cooperative close now completes.** `FinalizeCloseCommand` was
  constructed nowhere in the library, so a closing channel hung in `closing`
  forever and `ChannelClosedEvent` — and with it the peer's `channel_closed`
  message — was unreachable. Close is now two journaled steps, with
  `closing` as a resumable middle so a close re-delivered after a crash
  picks up instead of being refused.
- **The fully signed settlement is assembled.** The acknowledgement path
  carried `fullySignedPaymentTxHex: ''` with a "simplified for now" comment,
  so no side ever held a settlement transaction and its txid was unknowable.
  The server holds both signatures and now combines and verifies them; an
  assembly that fails records nothing rather than inventing a transaction.
- **Evidence:** the settlement is recorded with no height and no proof, so
  its row and its outputs are **pending** — not spendable — until a proof
  arrives. Nothing is asked of ARC: we did not broadcast it.
- **Known gap:** a client does not yet hold a cooperative settlement (the
  server's countersignature returns in `PaymentAcknowledgedResponse` but
  nothing journals it), so a client-side close records nothing and leaves the
  channel `closing`. Recording the unsigned template would create a UTXO at
  an outpoint that can never exist. The client's return leg is covered today
  by the expiry/refund route.
- `FullChannelStateResponse.latestPaymentTxHex` is new (additive).

### A plugin's outputs are not the wallet's spending money

Report section 11, V-85.

- **A plugin-managed UTXO can no longer fund a payment channel (V-85).**
  Channel funding selected with its own hand-rolled predicate instead of
  `WalletBalances.isSpendable`, and that predicate left out plugin-managed
  outputs — so a token output or a funding earmark could be picked as
  ordinary funding and spent as plain satoshis, destroying the token behind
  the plugin's state. Selection now uses the shared rule, narrowed by the two
  conditions funding adds on top, so the two cannot drift apart again.
- **Behaviour:** a wallet whose only funds are plugin-managed now refuses to
  fund a channel and says so, where it previously built the transaction. The
  "nothing to fund with" message names plugin-managed outputs alongside
  watch-only funds and outputs the wallet cannot unlock alone.

### A rejected channel command takes back its projection awaiter

Report section 11, V-84.

- **A rejected channel open or expiry no longer leaves an awaiter registered
  for 10 s (V-84).** The manager registers a projection awaiter *before*
  sending the command - the aggregate publishes its event before it answers,
  so registering afterwards can miss it - and when the command was rejected
  there was no way to take that registration back. It is a cost a peer could
  impose at will with repeated bad messages.
- **Requires an unreleased eventador.** The fix needed a cancel primitive
  that eventador's `ProjectionActor` did not have: `AwaitEventApplied` now
  takes an optional `awaitId` and `CancelEventAwait(awaitId)` drops the
  registrations carrying it, answering each `AwaitFailed(reason:
  'cancelled')`. Until that release is published, **libspiffy builds only
  alongside a sibling checkout of eventador at `../eventador`**
  (`dependency_overrides` in `pubspec.yaml`). `dart pub publish` refuses a
  package with overrides, so this cannot ship by accident.

### A wallet's own outputs can fund a channel, and the fee is the real one

Report section 11, V-83.

- **Bare-multisig and P2PK wallet UTXOs can fund a payment channel (V-83).**
  Channel funding signed every input as P2PKH and so excluded them outright -
  the wallet's own money, unusable for this purpose. The unlocking decision
  now lives in one place, `WalletTransactionSigner.unlockFor`, shared with
  `SignTransactionCommand`. Selection excludes only what the wallet cannot
  unlock alone: a bare multisig whose threshold its keys do not meet, or a
  P2PK to someone else's key.
- **Channel funding fees were underpaid, and are now correct.** Every input
  was sized as a 148-byte P2PKH input (an m-of-n input is `42 + 73m`, a P2PK
  input 114), the 2-of-2 funding output was counted as a 34-byte P2PKH
  output, and dartsv's own estimate - which counts only the unsigned
  unlocking script and omits the outpoint and sequence number - was used on
  top. Funding transactions now pay a little more than they did. Standard
  policy rate as before: there is no fee auction on this network.
- **`FundingTransactionBuiltResponse` describes the transaction that was
  built,** not the estimate: `fee`, `changeAmount` and `totalOutputSats` are
  read off the signed transaction, which is not what the estimate predicted.
- **`initializeLibSpiffy(channelPeerId:)` is forwarded** (new parameter,
  defaulted), with a `LibSpiffyActorSystem.channelPeerId` getter. A host
  booting through the free function previously got an empty channel peer id
  and its channels could not address it.
- Not done, deliberately: plugin-built funding transactions
  (`ProvisionFundingMessage`, TransactionBuilderPlugin payments) still accept
  P2PKH inputs only. The plugin chooses the unlocking script, so libspiffy
  cannot make it emit one for a multisig or P2PK input; dropping the guard
  would hand plugins outputs they would sign wrongly. It needs a plugin
  contract change, which is filed rather than guessed at.

### Judging a transaction is not receiving it

Report section 11, V-82.

- **A channel server no longer "receives" the funding transaction it is only
  judging (V-82).** `_verifyFundingBeef` sent SPVActor a receive with no
  target wallet, so every channel open told the WalletManager a result it
  logged and dropped. New internal `ValidateCounterpartyTransactionMessage`
  runs the same SPV validation and answers the sender only — nothing is
  credited, nothing is parked, and the BEEF's transactions and proofs are
  retained exactly as before. A verdict that cannot be reached yet no longer
  claims the receive "is retried automatically", which was never true on a
  path that does not park.
- **A channel payment of zero or a negative amount is rejected.**
  `RecordPaymentCommand` had no positivity guard, and none of the other
  guards catches a negative amount: the balance check cannot trigger and the
  arithmetic runs backwards, raising the client's balance and lowering the
  server's.
- **A refused or failed channel step now tells the counterparty.** The
  adapter raised a local error event and sent nothing on the wire, so the
  peer waited for a handshake message that was never coming. All four
  failure paths now send `channel_error`, which the inbound half has always
  understood.

### A channel's closing transaction, and channels that outlive 2038

Report section 11, V-81.

- **The transaction that claimed a refund is now in the read model (V-81).**
  `RefundClaimedEvent` carries the refund txid and the aggregate applied it,
  but the projection dropped it, so nothing could say which transaction
  reclaimed the funding output. It is recorded in the existing
  `settlementTxId` field: only one transaction can ever spend the 2-of-2
  funding output, so a channel has exactly one closing txid, and `state`
  distinguishes a cooperative settlement (`closed`) from a refund (`expired`).
- **A closing txid is written once and never replaced,** on all three closing
  routes. Previously a later observation could overwrite a refund txid the
  wallet had broadcast itself. A second, conflicting txid is logged rather
  than dropped in silence: two spends of one output cannot both be true, and
  the wallet cannot adjudicate between them without a proof.
- **Postgres migration v022:** `payment_channels.lock_time_unix` widens from
  `INTEGER` to `BIGINT`. A channel whose refund becomes spendable after
  2038-01-19 could not be stored at all (`22003: value out of range`). Isar
  and in-memory were already 64-bit and are unchanged. **An existing
  deployment must run `migrate()`.**

### A transaction nothing proves is in no block

Report section 11, V-80.

- **An import with no merkle proof no longer records the genesis block
  (V-80).** `TransactionImportedEvent.blockHeight` was a non-nullable `int`,
  so a transaction received without a BUMP was journaled at height 0 - block
  0 - because an absence could not be represented. Under V-79 a transaction's
  height *is* what says "confirmed", so this is the same defect V-78 and V-79
  fixed for UTXO rows, one level up. The height is now nullable end to end:
  on the event, on `RecordImportedTransactionCommand` (still `required`, so
  every caller states it), out of `SPVActor` and through `WalletManagerActor`,
  and the wallet's imported-transaction record carries no `blockHeight` key
  when nothing proves one.
- **A re-delivery carrying no proof no longer takes away a height an earlier
  proof established.** Previously a proofless re-delivery lowered the record
  to height 0 for any transaction that had not yet reached
  `status: confirmed`. An absence of evidence is not evidence the earlier
  proof was wrong.
- **Breaking:** `TransactionImportedEvent.blockHeight` and
  `RecordImportedTransactionCommand.blockHeight` are `int?`. Pass `null`, not
  `0`, for a transaction received without a proof.

### One meaning for "confirmed"

Report section 11, V-79.

- **"Confirmed" now means the same thing in every API (V-79).** There were
  four definitions and three different answers: the aggregate's balance
  buckets and the read model's wallet row required a stored count of six or
  more, `BalanceResponse` asked "has a block height", and
  `BitcoinUtxo.isConfirmed` wanted a height *and* a positive count - so the
  same output could read confirmed in one API and unconfirmed in another, and
  proof-confirmed funds read as unconfirmed until five more blocks arrived.
  The single rule, now in `spv-understanding.md` under "Balances": confirmed
  is evidenced by the transaction appearing in a block whose header we hold on
  our active chain, which is exactly `blockHeight != null`. **There is
  deliberately no depth threshold** - a proof confirms at depth one as at
  depth six, and waiting for depth is your application's policy, not this
  library's.
- **Breaking:** `WalletBalances.confirmedAt` is removed (no depth threshold
  exists to configure); `BitcoinUtxo.updateConfirmations` no longer takes a
  `blockHeight`; the coordinator `TransactionConfirmedEvent` no longer carries
  a `confirmations` field; `BitcoinUtxo.isConfirmed` and
  `BitcoinTransaction.isConfirmed` no longer read a count. Journaled snapshot
  totals (`confirmedBalance`/`unconfirmedBalance`) now split by proven height.
- **Fabricated confirmation counts are gone.** The library wrote
  `confirmations: 1` on a proven receive, `1`/`6` on confirmed transaction
  rows, and ARC's status check reported `6` whenever a height was present.
  Nothing measured or advanced any of them. `TransactionStatusMessage.confirmations`
  is now always `null`: ARC answers with a status and a height and says
  nothing about depth.

### A reported confirmation count is not evidence

Report section 11, V-78.

- **A caller-supplied confirmation count can no longer make funds spendable
  (V-78).** `BitcoinUtxo.updateConfirmations` promoted a UTXO from `pending`
  or `voided` to `available` whenever `confirmations > 0`, and
  `UpdateUTXOConfirmationsCommand` accepted both the count and the block
  height from the caller unvalidated - so one command, with no proof
  anywhere, made funds spendable, and un-voided outputs that are meant to be
  revivable only by a proof. The method now records the count and the height
  and changes no status. **`UpdateUTXOConfirmationsCommand` is deprecated**:
  nothing in the library sends it, and between the wallet deriving
  confirmation counts rather than storing them and a caller's height not
  being evidence, it has nothing correct left to do. Use
  `MarkUTXOAvailableCommand`, or a confirmation verified against your own
  header chain. **Breaking:** `UTXOConfirmationUpdatedEvent.blockHeight` and
  `BitcoinUtxo.updateConfirmations(blockHeight:)` are now nullable, so an
  absent height is recorded as absent instead of as height 0 - the genesis
  block - and no longer erases a height a proof established.

### Proven heights, voided change, and plugin guards

Report section 11, V-71 to V-77; each fix has a regression test shown to fail
on the previous code.

- **A UTXO confirmed from a merkle proof now carries its proven height
  (V-71).** The transaction row said height N while its own output said it was
  in no block, so `BalanceResponse.confirmedBalance` reported proof-confirmed
  funds as zero. The row stores the height and deliberately does **not** store
  a confirmation count: a count is stale at the next block, so it is derived
  (`tip height - blockHeight + 1`) wherever it is wanted. The height still
  comes only from a confirmation verified against our own header chain - never
  a caller's claim, never an ARC status string - and an output that is merely
  spendable still carries no block. The fix is in the apply path, so replaying
  an existing journal repairs affected wallets.
- **A faulty plugin can no longer abort a payment with its own stack trace
  (V-72).** Five `TransactionBuilderPlugin` calls in `PaymentCoordinatorActor`
  were unguarded. A plugin failure now fails the payment with a message naming
  the plugin, rather than propagating - the payment is not silently built
  without the plugin it was asked to use.
- **The change of a payment the network will not settle is now `voided`, not
  pending forever (V-73).** New `UTXOStatus.voided` (appended last; statuses
  are stored by name, so no migration and old rows read back unchanged).
  Nothing is deleted - only the status changes. Voided is **not** terminal
  against evidence: a cancelled payment can still be mined if the recipient's
  copy reaches the network, and a proof takes the output back to available.
  **Voided rows are still returned by unspent listings** - they are labelled,
  not hidden - so an app that treated everything non-spent as incoming should
  read the status.
- **A reclaim fails as soon as its inputs are seen spent (V-74)**, instead of
  waiting for an ARC poll. First seen wins, and no fee changes that; nothing
  retries at a higher fee.
- **Proof verdicts are correlated by request id (V-75)**, so a receive and a
  proof response for the same txid in flight together can no longer take each
  other's verdict.
- **`DeferredPaymentDetail` exposes the reclaim link (V-76)**: `purpose`,
  `resolutionReason`, `reclaimsTxid`, `isReclaim`. Additive.
- **`getOutputsAwaitingAncestorProof` is now contract-tested on all three
  backends (V-77)**, having had in-memory coverage only.

### Asking a counterparty for a fresh merkle proof

Report section 11, V-70.

- **An orphaned ancestor can now be recovered by asking the counterparty
  (V-70).** When a reorganization takes an ancestor's block off the active
  chain, a received output can no longer be walked back to a proof and cannot
  be spent. Until now the only recovery was the block returning. The other
  legitimate one - and there are only two, neither of them a lookup service -
  is the counterparty who handed us the transaction supplying a fresh BEEF,
  which is the sender's obligation. `RequestAncestorProofCommand` asks the
  peer named by the payment's `counterpartyMarker`, and `OutputAwaitingProof`
  now names who to ask. **libspiffy still owns no transport**: the request
  goes out as a `P2PMessageToSendEvent` for the app to deliver and comes back
  as a `P2PMessageReceived`, exactly like the channel protocol, whose
  `ChannelP2PReceived` / `ChannelP2PMessageToSendEvent` now extend the new
  generic base classes unchanged. Both halves are implemented, so a libspiffy
  wallet answers these requests as well as making them - but only from the
  counterparty actually recorded for that transaction, and every refusal reads
  the same on the wire so it discloses nothing. A response is verified against
  our own header chain through the ordinary receive path; one that does not
  verify is rejected and retained, never trusted because we asked for it.
  Apps wanting proof recovery must listen for the base
  `P2PMessageToSendEvent`, not only the channel subclass.

### Counterparty identity and reclaiming a deferred payment

Report section 11, V-68 to V-69; each fix has a regression test shown to fail
on the previous code.

- **Every payment records who it was with, in both directions (V-68).** The
  wallet could not say who a payment was with: `fromCounterparty` was
  persisted only on a parked receive, so a transaction that received cleanly
  kept no record of its sender, and the outgoing side had no such field at
  all. `counterpartyMarker` is an opaque string the app chooses - an Ed25519
  identity, an email address, a peer id, an account id - which libspiffy
  stores and returns but never parses, validates or interprets. It is a
  marker, not an identity record: names, contacts, key material and
  verification state stay with the app. It is deliberately **not** the
  existing `counterparty` / `primary_counterparty` columns, which are derived
  from bitcoin addresses and are untouched. Set once by the first record that
  carries one and never blanked or replaced thereafter, because no service
  can be asked for an identity we dropped. Postgres migration v021; existing
  rows keep a null marker, and no backfill is possible by design. The
  placeholder values `'unknown'`, `'import'` and a hardcoded `'counterparty'`
  are gone - a stored "unknown" on every transaction is worse than a null.
- **A deferred payment can be reclaimed, revoking the recipient's copy
  (V-69).** Cancelling released the held inputs but left the recipient
  holding a signed transaction that still spent them if it reached miners.
  `ReclaimDeferredPaymentCommand` broadcasts a self-spend of exactly those
  inputs back to the wallet, one shot, resolving the payment as `reclaimed`
  only once the network has the self-spend. **The fee is ARC's published
  policy fee and nothing else**: this is Bitcoin SV, there is no
  replace-by-fee, so no transaction displaces another by paying more. First
  seen wins; there is no race and no front-running, and the command has no
  fee parameter. If ARC's policy cannot be read the reclaim refuses to build
  anything rather than guess a rate. Cancel is now refused for a payment
  being reclaimed and for a reclaim's own self-spend. Nothing is deleted:
  both payments keep their records, raw hex and held-input lists.

### Retention, re-proof and imported confirmations

Report section 11, V-63 to V-67; each fix has a regression test shown to fail
on the previous code.

- **A receive parked for block headers survives a restart (V-63).** The
  evidence was already durable, but the parked receive itself was in memory,
  so a restart credited nothing and a 64-entry bound dropped the oldest
  retry outright. A durable `PendingReceive` row now holds the BEEF as it was
  handed to us; the replay runs on every header notification and at startup.
  Reconstructing the receive from the retained ancestor rows was rejected —
  it cannot recover the target wallet or the invoice, so it would guess at
  who was paid.
- **A BEEF refused because a header contradicts its proof is retained
  (V-64).** A rejected proof records that a counterparty handed us something
  that does not match our chain, and it cannot be re-fetched. One retention
  rule now serves the wait-for-headers path and both fatal paths. The receive
  still fails: this is retention, not acceptance.
- **An output whose ancestor's block was orphaned now says what it is waiting
  for (V-65).** `getOutputsAwaitingAncestorProof` names each unspent output
  that cannot be walked back to a proof and which ancestor blocks it. The
  wallet does not go looking for that proof: an ARC instance answers only for
  transactions submitted through it, so it has no standing to prove a
  counterparty's transaction. A fresh proof comes from the counterparty, in a
  new BEEF, or from the block returning to the active chain. Asking a
  counterparty for a re-proof needs a peer message the library does not have;
  that remains open. The recovery itself is verified end to end: a fresh
  verified proof from a re-sent BEEF supersedes the orphaned row, which is
  kept, and the output becomes spendable again.
- **Outgoing BEEFs merge the BUMPs of ancestors from the same block (V-66).**
  One multi-leaf BRC-74 BUMP per block instead of a repeated path per
  ancestor. Grouping is by height *and* computed merkle root, so a fork at
  one height never merges, and every merge is verified afterwards — any doubt
  falls back to separate BUMPs, because a bigger BEEF beats an unverifiable
  one.
- **A proof for a transaction the wallet received now confirms it in the
  journal (V-67).** The confirm gate looked only in the outgoing record map,
  so a received payment stayed unspendable even with a verified proof on our
  chain, and a read model rebuilt from the journal lost the confirmation.
  Confirming a receipt makes its outputs spendable and spends none of our
  inputs.

Breaking changes:

- `ReadModelStorage` gains five members — `storePendingReceive`,
  `getPendingReceive`, `getPendingReceivesUpToHeight`,
  `resolvePendingReceive`, `getOutputsAwaitingAncestorProof`. Third-party
  implementations of the interface must add them; all three in-tree backends
  do. **Postgres migration v020** adds `pending_receives`; Isar gains
  `PendingReceiveEntity` (hosts listing schemas by hand must add it).
- `beef.bumps.length` is no longer the number of proven transactions: several
  transactions now share a BUMP index. Code counting BUMPs to count proofs
  must change. The wire format is unchanged BRC-62/BRC-74.
- A merkle proof for a received transaction now journals a
  `TransactionConfirmedEvent` and a `UTXOMarkedAvailableEvent` per pending
  output where it previously journaled nothing, so journal event counts
  differ and received payments become spendable as soon as a proof arrives.
- A receive replayed after a restart credits the wallet but emits no
  coordinator event: the original reply target is gone with the process.

Additive API:

- `PendingReceive`, `OutputAwaitingProof`, `AwaitedAncestorProof`, and
  `outputsAwaitingAncestorProof(storage, walletId)`.
- `SPVActor(awaitingProofSweepInterval:)`.
- `BeefBumps` in `lib/src/utils/beef.dart`; `AncestorChainService.buildBeef`
  is now public and is the single outgoing BEEF builder.
- `OutgoingTransactions.importedRecord(state, txid)`.

### SPV proof lifecycle

Report section 11, V-57 to V-62; each fix has a regression test shown to fail
on the previous code.

- **A BEEF whose proof is above our chain tip is retained and retried, not
  dropped (V-57).** `_getBlockHeader` reported "we hold no header here" and
  "a header we hold contradicts this proof" identically, so the
  unproven-subject branch treated both as fatal and stored nothing — losing
  transactions and proofs nothing can hand us again. The two are now
  distinct: a contradicted proof still fails the receive; a missing header
  retains the whole BEEF (transactions to the ancestor store, BUMPs as
  `pendingHeader` proofs) and replays the receive once the headers arrive, so
  the wallet is credited without the counterparty re-sending.
- **A proof that arrives before its header now confirms when the header
  lands (V-58).** It was marked verified and left there; only the
  orphaned/rejected revival path issued a confirmation, so such a
  transaction waited for ARC.
- **A confirmation resting only on an orphaned proof is reverted (V-59).**
  One rule: a confirmation must rest on at least one proof verified on the
  active header chain. The orphaned proof row is kept — a reorganization can
  put its block back — and is re-checked read-only before the revert, since
  a header stored meanwhile may have restored it.
- **ARC re-polls recently failed transactions (V-59).** A transaction ARC
  reported REJECTED that was mined after all previously settled only if a
  proof happened to arrive another way. The poll is bounded three ways —
  interval, time window, row cap — and a MINED answer still confirms only
  through a merkle path that matches our headers, never on the status
  string.
- **`ReceiveUTXOCommand` no longer strands mined funds (V-60).** It took a
  block height and a confirmation count while defaulting the status to
  pending, so callers ended up with a wallet reporting nothing spendable and
  no explanation.
- **One faulty plugin no longer takes out the registry (V-61).**
  `identifyScript` did not catch a plugin's exception, so a script went
  unattributed and was reported unreadable. `extractMetadata`,
  `createLockBuilder` and `createUnlockBuilder` gained the same guard.
- **A failed specific-header request is answered with the right message
  type (V-62).** The caller's typed `ask` threw a cast error instead of
  taking its error path.

Breaking changes:

- `ReceiveUTXOCommand` throws `ArgumentError` when a `blockHeight` is passed
  with `initialStatus: pending` (the default). A height is recorded only
  from a merkle proof that verified against our active header chain, and a
  UTXO with such a proof is spendable, so the two cannot disagree. The
  status is never derived from a caller-supplied height — that would conjure
  spendable funds from a claim. Old journals replay unchanged: the check is
  on the command, not on `UTXOReceivedEvent`.
- A received BEEF whose proof sits above our chain tip is retained and
  retried. The immediate result is still `isValid: false` and says so, but a
  second `SPVValidationResult` (and `TransactionImportedEvent`) follows for
  the same txid when the header arrives. Code that consumes only the first
  verdict per txid will now see a later success.

Additive API:

- `ReadModelStorage.getTransactionsByStatusSince(status, since, {limit})`, a
  bounded recent-changes feed, implemented on all three backends.
  **Postgres migration v019** adds `idx_transactions_status_updated` on
  `bitcoin_transactions (status, updated_at DESC)`; Isar gains the matching
  composite index.
- `ARCActor(failedCheckInterval:, failedCheckWindow:, failedCheckLimit:,
  clock:)`, all defaulted.
- `PluginRegistry.extractMetadata`, `createLockBuilder`, `createUnlockBuilder`.

### A peer-delivered merkle proof settles our own payment

Report section 11, V-56; each fix has a regression test shown to fail on the
previous code.

- **A BEEF's proof now confirms a transaction this wallet recorded (V-56).**
  A counterparty spending what we paid them hands our own payment back as a
  proven ancestor of their new transaction. That BUMP is the strongest
  evidence there is that the payment was mined, and it is how the
  peer-to-peer model settles — no scanning, no polling. Nothing compared a
  BEEF member's txid against the wallet's own transactions, so the proof was
  filed in the ancestor store and the deferred payment stayed outstanding,
  marked `seen` at best by the weaker inference that its inputs were spent.
  `mined` was reachable only from ARC's MINED report or reorg revival, so
  only ARC could settle a payment. One rule now holds: a BUMP that verifies
  against our active header chain confirms that txid if the wallet recorded
  it, wherever it sits in the BEEF. The subject's own outputs stay pending —
  a BEEF proof proves funding history, not settlement.
- **A proven subject no longer discards the rest of the BEEF (V-56).** The
  validation loop short-circuited when the subject carried its own BUMP,
  dropping every other transaction and proof in the BEEF; nothing can hand
  those to us again. A member we cannot verify is retained unproven rather
  than failing the receive, since only the subject's own proof decides
  whether the receive is valid. This extends V-15, which retained ancestors
  only for an unproven subject.
- **The write model no longer lags the read model on a proven subject
  (V-56).** When the BEEF's subject was a transaction we had recorded, the
  read-model row flipped to `confirmed` while the aggregate journaled
  nothing, so the wallet displayed a confirmation its own journal did not
  hold until ARC caught up.
- **Confirming a transaction makes its own pending outputs available
  (V-56).** The change output of a deferred payment is spendable from the
  moment the proof reaches us. ARC and reorg revival already sent
  `MarkUTXOAvailableCommand` alongside the confirmation; the rule now lives
  in one place.

Breaking changes:

- `ReceiveUTXOCommand` for an outpoint the wallet already holds is a no-op
  instead of throwing `StateError`. It happens on the normal path — a
  counterparty hands back a BEEF holding a transaction of ours whose change
  we recorded when we built it — and the throw was observable nowhere, since
  its senders `tell()` it with no sender to reply to. The stored row is
  never overwritten: its reservation and spending history are not
  re-fetchable, and a proof arriving with the second delivery advances it
  through the confirmation path instead.

Additive API:

- `ProvenTransaction` and `SPVValidationResult.provenTransactions` (default
  `const []`): the BEEF members whose BUMP verified against our active
  header chain.
- `ConfirmTransactionCommand.onlyIfRecorded` (default `false`): journal
  nothing unless the wallet recorded the transaction itself and has not
  already confirmed it, so a counterparty's own ancestors journal nothing
  and the same BEEF delivered twice confirms once.
- `OutgoingTransactions.outgoingRecord(state, txid)`.

### Follow-ups of the P3 correctness wave

Report section 11, V-52 to V-55; each fix has a regression test shown to fail
on the previous code.

- **Benford splits (V-52).**
  - The reply now comes after ARC answers and carries a per-split
    `SplitTransactionOutcome`: accepted, queued, rejected, contested,
    notBroadcast, unanswered or notRecorded.
  - A recording the wallet did not acknowledge in time is cancelled, so it
    never holds the source for a split nobody broadcast.
  - `splitWatchOnlyUtxos` no longer lists multisig UTXOs the wallet cannot
    spend alone, so a payment is never funded from an escrow.
- **Read-model rows (V-53).**
  - `confirmedAt` is set by the first confirmation, from the record's time.
  - Wallet row balances follow a new key that makes a multisig UTXO
    spendable.
  - `storeWallet` converts derived metadata values, or rejects them with an
    `ArgumentError` naming the key, the same way on all three backends.
- **ARC (V-54).**
  - Competing txids reported with DOUBLE_SPEND_ATTEMPTED are journaled and
    listed with the deferred payment. **Postgres migration v017** adds the
    column, and Isar gains the property.
  - ARC scans no longer journal status updates the row would not take.
- **Proofs (V-55).**
  - A proof that verifies on the active chain re-confirms a failed
    transaction and spends the inputs its failure released.
  - The rejected-proof sweep reads only proofs whose status changed since the
    previous check, with an hourly full sweep. **Postgres migration v018** adds
    the index.

#### Breaking changes

- `ReadModelStorage` has a new method, `getMerkleProofsByStatusChangedSince`.
  Classes that `implements` it must add it.
- A Benford split reply is sent only after ARC answers. A split without an
  ARC service, or whose recording is refused or times out, is now reported
  as a failure.
- `ConfirmTransactionCommand` may journal `UTXOSpentEvent`s for recorded
  inputs that are still unspent, before `TransactionConfirmedEvent`.
- `storeWallet` rejects metadata values that are not JSON on every backend,
  including in-memory.
- Postgres `confirmedAt` is the confirming record's time, not the store time.

Additive API: `SplitTransactionStatus`, `SplitTransactionOutcome`,
`SplitUTXOsResponse.splits`, `UTXOSplitCompleteEvent.txids` / `splits`,
`BenfordCoordinatorActor(broadcastReplyTimeout:)`,
`SignableUtxos.notSpendableAlone` / `excludedNote`,
`TransactionRowRules.confirmedAtAfter`, `WalletRowRules`, `competingTxids` on
the deferred payment command, event, model and results,
`DeferredPayment.mergeCompetingTxids`,
`SPVActor(rejectedProofFullSweepInterval:, clock:)`.

### P3 correctness wave

Twelve P3 beads in four lanes, each fix with a regression test shown to fail
on the previous code (report section 11, V-44 to V-51).

- **Balances agree across layers (V-44 to V-46).**
  - `ReadModelStorage.getBalance`, the wallet row's balance fields and
    `BalanceResponse` leave out watch-only UTXOs and bare multisig UTXOs the
    wallet cannot spend alone. The new `getWatchOnlyBalance` reports the
    watch-only total.
  - Plugin-managed means the UTXO's metadata names a `pluginId`
    (`BitcoinUtxo.isPluginManaged`), on both layers.
  - Inputs of payments recorded before deferred holds existed are excluded
    from coin selection as soon as the wallet recovers, not only after the
    startup reconcile.
- **Stored transaction status (V-47).** A stale record (a late ARC status, or
  a BEEF re-sent without its proof) no longer lowers a stored transaction's
  status. Only the confirmation revert can take a confirmation back, through
  `storeRevertedTransaction`. Postgres stores the other party as the primary
  counterparty, as Isar does. **Postgres migration v015** recomputes it.
- **Proofs through reorganizations (V-48).**
  - An orphaned or rejected proof whose block becomes active again is
    verified again, and the transaction's confirmation is restored.
  - A pendingHeader proof whose header is still unknown is no longer marked
    orphaned.
  - pendingHeader proofs are re-checked when `SPVActor` starts.
  - An orphaned proof keeps the block hash it named.
  - **Postgres migration v016** replaces the proof status index with a
    (status, block height) index; opening an existing Isar store builds the
    same index.
- **Payment flows (V-49 to V-51).**
  - The Benford splitter records a split, holding its source, before it
    broadcasts, and reads the wallet from the aggregate.
  - ARC `DOUBLE_SPEND_ATTEMPTED` no longer fails a deferred payment: its
    inputs stay held while ARC is polled.
  - Commands queued to an aggregate that a journal failure took out of
    service are answered with `AggregateOutOfServiceException` instead of
    being dropped.
  - A rejected `MarkInvoicePaid` is answered at once, and invoice creation is
    answered only after its event is journaled.

#### Breaking changes

- `ReadModelStorage` has three new methods: `getWatchOnlyBalance`,
  `storeRevertedTransaction` and `getMerkleProofsByStatusBetweenHeights`.
  Classes that `implements` it must add them.
- `storeTransaction` never lowers a stored status. Code outside libspiffy
  that used it to take a confirmation back must call
  `storeRevertedTransaction`.
- `getBalance` and the wallet row balances report less for wallets with
  watch-only funds or multisig outputs they cannot spend alone.
  `WalletState.availableUtxos` returns only spendable UTXOs.
  `AggregateSigningClient.pathForAddress` throws for a watch address.
- A UTXO whose metadata carries no `pluginId` is spendable on the aggregate.
  A plugin-script UTXO received without metadata is plugin-managed.
- A deferred payment ARC answers `DOUBLE_SPEND_ATTEMPTED` stays outstanding
  with its inputs held, and its transaction status is `broadcast`, not
  `failed`. A broadcast answered that way is reported as unsuccessful.
- A Benford split is listed as a deferred payment (purpose `benford-split`)
  until ARC settles it.
- After a journal failure, the aggregate ref stays alive until its manager
  retires it. Check `CommandFailureContainment.isRetiring(ref)` instead of
  `isAlive`.
- `watchOnlyBalance` is a reserved wallet metadata key.

Additive API: `BalanceUtxos`, `splitBalanceUtxos`,
`WalletBalances.cannotSpendAlone`, `BitcoinUtxo.isPluginManaged`,
`TransactionRowRules`, `WalletSpendableUtxosQuery` / `Response`,
`BenfordCoordinatorActor(walletReplyTimeout:)`,
`DeferredNetworkStatus.isContested`, `AggregateOutOfServiceException`,
`CommandFailureContainment.isRetiring` / `retire`,
`ArcSubmitResponse` competing txids.

### After wave 4: follow-up fixes

Beads filed during wave 4, each with a regression test shown to fail on the
previous code (report section 11, V-40 to V-43).

- **Spendable balance agrees with coin selection (V-40, libspiffy-ad07).**
  `WalletState.availableBalance` and `hasSufficientBalance` are now the total
  of the UTXOs the aggregate's coin selection may pick: status available, no
  plugin metadata, not watch-only (`WalletBalances.isSpendable`). Before,
  reserved amounts were subtracted twice, and pending, plugin-managed and
  watch-only UTXOs were counted. The confirmed/unconfirmed/reserved buckets
  and the read-side balances are unchanged. `spv-understanding.md`
  ("Balances") gives the rule for each API.
- **Reserved wallet metadata keys (V-41, libspiffy-hfai).**
  `UpdateWalletConfigurationCommand.newMetadata` and
  `CreateWalletCommand.walletMetadata` could overwrite the wallet's own
  records (`address_indices`, `outgoingTransactions`, deferred holds, …) and
  the read model's derived values. Journaled events from before this change
  replay with those keys skipped; no event is dropped.
- **Invoice creation errors are correlated (V-42, libspiffy-q5jv).** A
  wallet-manager error fails only the invoice whose address request it
  answers. Before, an error without `walletId` failed every pending invoice.
- **SPV reorg and proof rechecks read only affected rows (V-43,
  libspiffy-ctkm).** `SPVActor` no longer lists every wallet's confirmed
  history on a reorganization, per failing proof, or when sweeping rejected
  proofs. **Postgres migration v014** adds a partial index on confirmed
  transactions' `block_height`. Opening an existing Isar store builds a new
  `(status, blockHeight)` index.

#### Breaking changes

- `availableBalance` / `hasSufficientBalance` report less for wallets holding
  pending, plugin-managed or watch-only UTXOs, and no longer under-report
  wallets with reservations. `availableBalance` is a `late final` field
  instead of a getter.
- Wallet creation and configuration updates throw `ArgumentError` when the
  metadata names a reserved key (`WalletMetadataKeys.reserved`, which includes
  read-model names such as `walletType` and `lastUpdated`). Creation may
  still pass `network`.
- An invoice whose address request gets no answer fails after
  `addressRequestTimeout` (default 60 s) instead of staying pending.
  `AddressGeneratedResponse` or error maps told to `InvoiceCoordinatorActor`
  directly are ignored.
- `ReadModelStorage` has two new methods, `getTransactionsByTxids` and
  `getConfirmedTransactionsFromHeight`. Classes that `extends` it inherit
  fallbacks; classes that `implements` it must add them.

Additive API: `WalletBalances.isSpendable` / `isWatchOnly` / `spendableTotal`,
`WalletMetadataKeys` (`addressIndices`, `addressChains`, `network`,
`readModel`, `reserved`, `creationInputs`, `reservedIn`,
`requireHostMetadata`, `hostEntries`),
`WalletLifecycle.requireHostCreationMetadata`,
`InvoiceCoordinatorActor(addressRequestTimeout:)`; test seams
`InMemoryWalletStorage.transactionRowsRead`,
`PostgresWalletStorage.onTransactionLookupQuery`.

### Wave 4: refactors

Structural work that keeps behaviour (the existing suite passes unchanged;
characterization tests pin reply shapes, merkle walks and header-chain
results). Defects found on the way are report section 11, V-35 to V-39.

- **Pattern-matching dispatch (A-L6, libspiffy-r1l).** Aggregates,
  projections and actors dispatch with type patterns instead of
  `runtimeType`; a subclass of a command, event or message now reaches its
  parent's handler. Header sync failures name their operation (V-35).
- **Reply convention (A-L6, partial, libspiffy-pgt).** Replies extend the new
  `ActorResponse` (`success`, `error`, payload is the reply); 14 replies that
  could not answer `ask()` now can. Wiring messages (`Set*Message`,
  `InitiateHeaderSyncMessage`) moved to `internal_messages.dart` and are
  re-exported from their old libraries. Without a Benford coordinator a split
  is answered with a failed `SplitUTXOsResponse`.
- **SPV primitives (SPV-16, libspiffy-dq0).** One merkle module, one
  byte-order utility, one proof-of-work check. `BEEF.parse` throws only
  `BEEFException`, including for trailing bytes after the last transaction;
  `BUMP.parse` throws only `BUMPException`.
  `CryptoUtils.computeMerkleRootFromTscProof` is correct (V-36).
- **SPV hot paths (SPV-15, libspiffy-780).** BEEF transactions keep their
  received bytes (V-37) and each txid is hashed once; bulk header imports no
  longer reload the header cache per chunk.
- **No polling (libspiffy-a5l).** `initialize()` returns once stored wallets
  are preloaded instead of sleeping 100 ms (V-38); the wallet manager waits
  on one shared load future per wallet.
- **Immutable aggregate state (libspiffy-mmb).** `WalletState`,
  `InvoiceState` and `ChannelState` are copy-on-write: each event yields a
  new state, exposed collections are unmodifiable, and a state you hold never
  changes (V-39). Replay copies only what each event touches.
- **Wallet aggregate decomposed (L5, libspiffy-dp4).** `BitcoinWalletAggregate`
  delegates to collaborators in `lib/src/core/wallet/` (keys, address book,
  UTXO ledger, reservations, deferred payments, outgoing transactions,
  signer, channel funding); one wallet is still one aggregate with the same
  journal. The write model's balances share one rule (`WalletBalances`).

#### Breaking changes in wave 4

- `BEEF.parse` rejects a BEEF with bytes after its last transaction, and
  throws `BEEFException` (not `StateError` / `Exception`) for malformed
  input; `BUMP.parse` throws `BUMPException`.
- A `BEEF`'s transactions hold the bytes as received; for a non-minimally
  encoded transaction the txid changes to the one the sender computed.
- Subclasses of commands, events and messages are handled like their parent
  instead of falling through to the unknown-message path.
- `WalletState` fields are final; `utxos`, `addresses`, `watchAddresses` and
  `metadata` are unmodifiable (`PersistentMap`, deep-frozen) and maps passed
  in are copied. `InvoiceState` fields are final with unmodifiable lists;
  `ChannelState` fields are final. Aggregates implement
  `applyEvent(state, event)` instead of overriding `eventHandler`.
- A `PreloadWalletCommand` sent with a sender is answered with
  `WalletPreloadedResponse`.

Additive API: `ActorResponse`, `lib/src/spv/merkle.dart` (`hash256`,
`txidInternalBytes`, `txidDisplayBytes`, `merkleParent`, `merkleRootFromPath`,
`merklePathForIndex`), `hex_utils` `reverseBytes` / `displayToInternal` /
`internalToDisplay` / `bytesEqual`, `NetworkParams.checkProofOfWork`,
`ProofOfWorkCheck`, `ProofOfWorkFailure`, `BUMP.siblingAt`,
`WalletPreloadedResponse`, `InvoiceState.copyWith` (every field),
`ChannelState.copyWith`. Deprecated:
`CdnHeaderSyncConfig.concurrentDownloads`.

### Follow-ups before wave 4

Defects found by the wave 3 lanes and this batch (report section 11, V-8 to V-34), each with
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
- **Multisig outputs and duplicate records (V-17).** A bare multisig output
  is a wallet UTXO only when the wallet holds at least as many of its keys
  as it requires, so a payment channel's 2-of-2 funding output is no longer
  spendable balance (recording, importing and `ReceiveUTXOCommand` alike).
  Recording an outgoing transaction that is already recorded has no further
  effect. UTXO reservations (holder, reason, expiry, priority, prior
  status), derivation index and spending txid persist on every read-model
  backend (**Postgres migration v011**; new nullable Isar fields).
- **Payment inputs spent (V-18).** The inputs of a standard invoice payment
  are marked spent once ARC reports the transaction on the network; before,
  that spend was rejected and the inputs went back to available when their
  reservation expired. The ten pre-existing test failures (T-1) are
  resolved; the test suite no longer calls testnet ARC.
- **Channel refund signing (V-19).** The server signs a refund only with the
  channel's own wallet, key and terms, and only a refund that spends the
  channel output with the channel lockTime; the countersigned refund is
  journaled.
- **Channel funding verified (V-20).** The client sends its funding
  transaction as BEEF; the server validates it (proofs against its headers,
  ancestors, input scripts, values) before the channel opens.
- **Channels survive a restart (V-21).** Channel open state is rebuilt from
  the channel journal, so an open interrupted by a restart continues on
  both sides, and a resumed funding broadcast does not record the funding
  in the wallet twice. `LibSpiffyActorSystem.initialize(channelPeerId:)`
  sets the node's channel peer id.
- **HD key derivation (V-22).** Keys whose derived child private key starts
  with a zero byte (1 in 256) are derived correctly; before, derivation
  threw and the wallet could not sign for addresses it had handed out.
  Existing wallets keep their addresses.
- **Multisig invoices (V-23).** An invoice paid to its multisig output is
  marked paid; the output is spendable balance only when the wallet holds
  enough of its keys.
- **Contradicted proofs (V-24).** A merkle proof that does not match the
  stored header at its height is kept with the new status `rejected`: it is
  never used in a BEEF or as a confirmation, and a confirmation resting
  only on it is reverted (**Postgres migration v012**).
- **Deferred payments (V-25).** The inputs of a payment handed to its
  recipient stay reserved until the network reports the transaction, ARC
  rejects it, or you cancel it; before, they were released after 2 minutes
  and could be spent again. New coordinator API to find and act on
  payments whose recipient has not broadcast them:
  `GetDeferredPaymentsQuery` (filter by state, age, network status, invoice,
  recipient; paged; raw hex and BEEF included), `BroadcastDeferredPaymentCommand`,
  `CheckDeferredPaymentStatusCommand` (ARC, or the configured blockchain
  data source; a mined answer is confirmed only with a proof that matches
  our headers) and `CancelDeferredPaymentCommand` (refused when the network
  already knows the transaction; it does not revoke the copy the recipient
  holds) (**Postgres migration v013**; new Isar collection
  `DeferredPaymentEntity`).
- **Receive attribution (V-26).** A received transaction's outputs and
  spent inputs are attributed by the wallet itself, not the read model, so a
  payment to a wallet created or an address generated moments earlier is
  credited. Receiving or importing a transaction for a wallet that does not
  exist (or does not answer within 30 s) now returns `isValid: false`
  ("Cannot tell which outputs of <txid> belong to wallet <id>") instead of
  a valid result with nothing recorded.
- **P2PK receives (V-27).** P2PK outputs received through SPV are credited;
  before, none was.
- **Invoice receives (V-28).** Receiving a transaction for an invoice that
  cannot be looked up, does not exist, or that no output pays now returns
  `isValid: false` naming the invoice, instead of a valid result with
  nothing recorded (and a BEEF broadcast).
- **Unreadable outputs (V-29).** Outputs whose locking script cannot be read
  are listed in `SPVValidationResult.unreadableOutputs` and
  `SPVValidationResultEvent.unreadableOutputs`; the transaction is still
  recorded.
- **Multisig and P2PK spends (V-30).** Payments and splits sign bare
  multisig and P2PK wallet UTXOs with their own unlocking scripts; before,
  they were signed as P2PKH and the payment failed. Plugin payments,
  funding provisioning and channel funding do not select them.
- **Paying again after a cancel (V-31).** Paying the same invoice again
  after cancelling its deferred payment re-activates that payment at once
  (same transaction, inputs held again); after a network rejection it fails
  at once.
- **Watch addresses journaled (V-32).** Watch address registration is
  recorded in the wallet's journal, so a rebuilt read model keeps it;
  addresses registered earlier are journaled when their wallet is loaded.
- **Watch-only funds (V-33).** UTXOs at watch addresses are no longer
  spent or counted as spendable balance; `BalanceResponse.watchOnlyBalance`
  reports them. Payments that only watch-only funds could cover fail with a
  message naming them.
- **Wallet state copies (V-34).** `WalletState.copyWith` keeps `isDeleted`.
- **Isar queries (S-16).** Isar queries read only the rows they need
  (address purpose, transaction status, invoices, deferred payments, plugin
  UTXOs). Two Isar indexes change (`AddressEntity` `(walletId, purpose)`,
  `BitcoinTransactionEntity` `(status, walletId)`); Isar rebuilds them on
  the first open.

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
- The server refuses a `channel_open` without a valid funding BEEF (clients
  from before this change cannot open channels with it); a server-role
  `PaymentChannelManagerActor` needs `spvActor:`, a client needs
  `storage:` to send the BEEF; a client that cannot build the BEEF does not
  broadcast. Refund sign requests naming another wallet, lockTime, sequence
  or output are refused. `PaymentChannelManagerActor.channelOutputReservation`
  is removed (the channel output is no longer reserved).
- `ReceiveUTXOCommand` rejects a bare multisig output attributed to a wallet
  address when the wallet cannot spend it alone; a `RecordOutgoingTransactionCommand`
  for a recorded txid emits no `TransactionRecordedEvent` (do not wait for
  one). A reserved or pending UTXO can be spent by a transaction the wallet
  recorded as spending it.
- Deferred-spend inputs are no longer freed by reservation expiry, cleanup,
  `ReleaseUTXOsCommand` or a higher-priority reservation; a failed channel
  funding broadcast keeps its inputs until cancelled. On first load after
  upgrade, wallets journal holds for outstanding deferred payments recorded
  earlier. `ReadModelStorage` gains `storeDeferredPayment`,
  `getDeferredPayment` and `listDeferredPayments` (abstract);
  `BlockchainDataSource` implementations should set
  `DataSourceException.notFound`. Hosts opening Isar with their own schema
  list must add `DeferredPaymentEntity`.
- `MerkleProofStatus.rejected` is a new enum value (exhaustive switches
  must handle it); `MerkleProof.isCurrent` excludes it; `getMerkleProof`
  and `getMerkleProofsBatch` no longer return a proof the stored header
  contradicts. `ReceiveUTXOCommand` rejects any bare multisig output the
  wallet cannot spend alone, whatever address it names. `InvoicePaidEvent.addressesPaidTo`
  may contain `p2ms:m-of-n`. A derived private HD node's depth is parent
  depth + 1 and a derived public node keeps its network (serialized
  extended keys of derived nodes change; master keys and all derived keys
  and addresses are unchanged).
- Hosts opening Isar with their own schema list must regenerate for the new
  `BitcoinUtxoEntity` fields.
- `ReadModelStorage.storeAncestorTransaction` and
  `getAncestorTransactionsBatch` added (abstract). Hosts opening Isar with
  their own schema list must add `AncestorTransactionEntity`.
- A receive or import for a target wallet asks that wallet which outputs
  and inputs are its own: SPVActor needs a wallet manager that answers
  `WalletOwnershipQuery` (a stand-in that ignores it gets a failed result
  after 30 s), and a transaction for a wallet that does not exist is
  reported invalid, not valid with nothing recorded; on the BEEF path it is
  then not broadcast.
- A receive with an invoice id that no output pays, or whose invoice cannot
  be looked up, is invalid. `RegisterWatchAddressCommand` goes through the
  wallet (fails for an unknown wallet; registering an address the wallet
  derives or already watches changes nothing, labels included); writing a
  row with `upsertAddress` no longer makes an address the wallet's.
  `ReadModelStorage.getAddressesByPurpose` is added (abstract). A wallet
  must be loaded once after upgrading before its read model is rebuilt
  from the journal, so its earlier watch addresses are journaled. Plugin
  payments, `ProvisionFundingMessage` and channel funding no longer spend
  bare multisig or P2PK UTXOs.
- `GetBalanceQuery` balances exclude watch-only UTXOs;
  `BitcoinWalletAggregate.getAvailableUTXOs` excludes them;
  `SignTransactionCommand` refuses an input at a watch address. Generated
  Isar where clauses renamed: `AddressEntity` `walletIdEqualTo` /
  `walletIdNotEqualTo` → `walletIdEqualToAnyPurpose` /
  `walletIdNotEqualToAnyPurpose`, `BitcoinTransactionEntity` `statusEqualTo`
  / `statusNotEqualTo` → `statusEqualToAnyWalletId` /
  `statusNotEqualToAnyWalletId` (the old names remain as deprecated
  extensions). Hosts opening Isar with their own schema list must rebuild.

Additive API: `MerkleProofStatus`, `MerkleProof.status` / `statusChangedAt`,
`PostgresEventStore(livePollInterval:)`, `ServerAcceptanceRecordedResponse`,
`RecordRefundBuiltCommand`, `StartFundingBroadcastCommand`,
`RecordFundingBroadcastFailedCommand`, `FundingBroadcastStartedEvent`,
`FundingBroadcastFailedEvent`, `RefundCountersignedEvent.signedRefundTxHex`,
`PaymentChannelManagerActor(arcActor:,
walletProjection:, broadcastTimeout:)`, `TransactionConfirmedEvent.bumpHex`,
`ConfirmTransactionCommand.bumpHex`, `BeefAncestor`,
`TransactionImportedEvent.ancestors`, `ArcSubmitResponse.merklePath` /
`merklePathHex`, `BareMultisigScript`, `LibSpiffyActorSystem.initialize(channelPeerId:)`,
`PaymentChannelManagerActor(spvActor:, storage:)`, `OpenChannelMessage.fundingBeefHex`,
`OpenChannelCommand.fundingBeefHex`, `ChannelOpenedEvent.fundingBeefHex`,
`SignRefundTransactionMessage.fundingTxId` / `fundingOutputIndex` / `fundingTxHex`,
`RequestRefundSignatureCommand.fundingTxHex`, `RefundCountersignedEvent.refundTxHex` /
`fundingTxId` / `fundingOutputIndex` / `fundingTxHex`, `AcceptChannelMessage.serverPeerId`,
`AcceptChannelCommand.serverPeerId`, `ChannelAcceptedEvent.serverPeerId`,
`RecordFundingInWalletCommand`, `FundingRecordedInWalletEvent`,
`ChannelDetailsQueryMessage`, new optional fields on `FullChannelStateResponse`,
`Bip32` (lib/src/utils/bip32.dart), `MerkleProofStatus.rejected`,
`GetDeferredPaymentsQuery` / `DeferredPaymentsResponse` / `DeferredPaymentDetail`,
`BroadcastDeferredPaymentCommand` / `DeferredPaymentBroadcastEvent`,
`CheckDeferredPaymentStatusCommand` / `DeferredPaymentStatusEvent`,
`CancelDeferredPaymentCommand` / `DeferredPaymentCancelledEvent`,
`DeferredPayment`, `DeferredPaymentState`, `DeferredPaymentNetworkSource`,
`ARCActor(dataSource:)`, `RecordOutgoingTransactionCommand.invoiceId` / `purpose`,
`ArcException.statusCode` / `isNotFound`, `DataSourceException.notFound`,
`WalletOwnershipQuery` / `WalletOwnershipResponse`,
`SPVValidationResult.unreadableOutputs`, `SPVValidationResultEvent.unreadableOutputs`,
`needsNonP2pkhUnlock`, `BareMultisigScript.parseHex`,
`TransactionSpendDeferredEvent.reactivated`, `WatchAddressAddedEvent`,
`AddWatchAddressCommand`, `ReconcileWatchAddressesCommand`, `LegacyWatchAddress`,
`WatchAddressAddedResponse`, `WalletState.watchAddresses`,
`WalletManagerActor(readModelStorage:)`, `BalanceResponse.watchOnlyBalance`,
`isWatchOnlyOutput`, `splitWatchOnlyUtxos` / `SignableUtxos`, `IsarWalletStorage.onQuery` (test seam).

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
