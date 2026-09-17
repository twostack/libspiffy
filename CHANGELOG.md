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
