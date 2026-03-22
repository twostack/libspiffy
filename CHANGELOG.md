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
