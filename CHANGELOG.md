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
