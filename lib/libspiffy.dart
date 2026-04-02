/// LibSpiffy - Actor-Based Bitcoin SPV Wallet Library
/// 
/// A comprehensive SPV wallet library built on the Dactor/Eventador stack
/// with SpiffyNode integration for robust P2P functionality and chain tracking.
library libspiffy;

// ✅ CORE MODELS - Complete domain models with DartSV integration
export 'src/models/wallet_event.dart';          // Event sourcing base class
export 'src/models/bitcoin_utxo.dart';          // UTXO tracking with reservations
export 'src/models/wallet_state.dart';          // Write model for wallet aggregate
export 'src/models/wallet_type.dart';           // Wallet type enum (HD, WIF, XPRIV)
export 'src/models/wallet_read_model.dart';     // Read model for wallet queries (CQRS)
export 'src/models/bitcoin_transaction.dart';   // Transaction tracking
export 'src/models/invoice_state.dart';         // Write model for invoice aggregate
export 'src/models/invoice_read_model.dart';    // Read model for invoice queries (CQRS)
export 'src/models/address_metadata.dart';      // Address metadata with script type support
export 'src/models/transaction_address_link.dart'; // Transaction-address junction models
export 'src/models/invoice_output_spec.dart';   // Multi-output invoice specifications (P2PKH, P2MS)

// ✅ STORAGE INTERFACES - Platform-agnostic storage abstraction
export 'src/storage/event_storage.dart';        // Event storage interface
export 'src/storage/read_model_storage.dart';   // Read model storage interface
export 'src/storage/wallet_storage.dart';       // Combined interface (backward compat)
export 'src/storage/secure_storage.dart';       // Secure key storage interface
export 'src/storage/in_memory_wallet_storage.dart';  // Development implementation
export 'src/storage/in_memory_secure_storage.dart';  // Development implementation
export 'src/storage/isar_config.dart';          // Isolate configuration
export 'src/storage/libspiffy_schemas.dart';    // Isar schemas for host integration
export 'src/storage/isar_wallet_storage.dart';  // Production Isar storage
export 'src/storage/storage_backend.dart';      // Storage backend enum and factory

// ✅ POSTGRESQL STORAGE - Server-side deployment support
export 'src/storage/postgres/postgres_config.dart';        // PostgreSQL connection configuration
export 'src/storage/postgres/postgres_wallet_storage.dart'; // PostgreSQL read model storage
export 'src/storage/postgres/postgres_event_store.dart';   // PostgreSQL event store
export 'src/storage/postgres/postgres_migrations.dart';    // Schema migration infrastructure
export 'src/storage/postgres/postgres_secure_storage.dart'; // Encrypted xpub storage for server-side

// ✅ CRYPTOGRAPHY - Encryption services for secure storage
export 'src/crypto/encryption_service.dart';               // AES-256-GCM encryption with HKDF

// ✅ PAYMENT CHANNEL READ MODEL - Channel entity for queries
export 'src/storage/payment_channel_entity.dart'; // Channel read model entity

// ✅ PROJECTIONS - Read-side event handlers for CQRS
export 'src/projections/wallet_projection.dart';   // Wallet read model projection
export 'src/projections/invoice_projection.dart';  // Invoice read model projection
export 'src/projections/channel_projection.dart';  // Channel read model projection

// 🎭 ACTOR COORDINATION LAYER - Dactor-based multi-wallet coordination
export 'src/actors/actors.dart';                // Complete actor system: WalletManager, SPV, ARC actors

// 🚀 CRYPTO SERVICES - Real Bitcoin cryptographic operations
export 'src/services/crypto_service.dart';      // Comprehensive crypto service interface
export 'src/services/dartsv_crypto_service.dart'; // DartSV-based implementation with HD wallets

// 🚀 ARC SERVICE INTEGRATION - Production-ready transaction broadcasting
export 'src/services/arc_service_config.dart';  // ARC node configuration (TAAL testnet/mainnet)
export 'src/services/arc_service.dart';         // Complete ARC API with BEEF support

// 🚀 SCRIPT ANALYSIS - Universal Bitcoin script support
export 'src/services/script_type_registry.dart'; // Script type identification and categorization

// 🔌 PLUGIN SYSTEM - Extensible script/token integration
export 'src/plugin/script_plugin.dart';              // Core plugin interface
export 'src/plugin/plugin_registry.dart';            // Plugin registration singleton
export 'src/plugin/plugin_types.dart';               // PluginUnlockSpec, PluginTransactionRequest
export 'src/plugin/transaction_builder_plugin.dart'; // Multi-output transaction builder interface

// SECURE SIGNING - Callback-based transaction signing for plugin isolation
export 'src/services/callback_transaction_signer.dart';

// 🚀 CDN HEADER SYNC - Fast initial block header synchronization via CDN
export 'src/spv/cdn_header_sync_config.dart';
export 'src/spv/cdn_header_sync_service.dart';
export 'src/spv/cdn_manifest.dart';

// 🚀 SPV VALIDATION - BEEF/BUMP utilities for SPV transaction validation
export 'src/utils/bump.dart';                   // BSV Universal Merkle Path (BUMP) implementation
export 'src/utils/beef.dart';                   // Background Evaluation Extended Format (BEEF) implementation
export 'src/utils/benford_distribution.dart';   // Benford's Law distribution for privacy
export 'src/services/block_header_service.dart'; // Block header management with reorganization handling
export 'src/services/spv_service.dart';         // Enhanced SPV validation with ChainTipTracker integration
export 'src/services/wallet_balance_service.dart'; // BEEF-based multi-tier balance tracking with reorganization handling

// TRANSACTION BUILDING - Production-ready transaction construction
export 'src/services/transaction_builder_service.dart'; // Comprehensive transaction building with UTXO selection
export 'src/services/payment_channel_builder.dart'; // Payment channel transactions (funding, refund, payment)

// 🎯 TRANSACTION IMPORT - Hybrid event sourcing for historical data
export 'src/services/transaction_import_service.dart'; // Import historical transactions with UTXO harvesting
export 'src/services/transaction_import_models.dart'; // Import data structures (ImportableTransaction, TransactionImportResult)
export 'src/services/transaction_analyzer.dart';     // Two-phase UTXO harvesting and dependency sorting

// 🎯 BLOCKCHAIN DATA SOURCES - External blockchain APIs for wallet imports
export 'src/services/blockchain_data_source.dart';    // Abstract blockchain data source interface
export 'src/services/whatsonchain_data_source.dart';  // WhatsOnChain API implementation
export 'src/services/node_rpc_data_source.dart';      // BSV node RPC implementation (regtest)
export 'src/models/blockchain_data_models.dart';      // Data models for blockchain imports

