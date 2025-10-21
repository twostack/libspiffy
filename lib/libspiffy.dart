/// LibSpiffy - Actor-Based Bitcoin SPV Wallet Library
/// 
/// A comprehensive SPV wallet library built on the Dactor/Eventador stack
/// with SpiffyNode integration for robust P2P functionality and chain tracking.
library libspiffy;

// ✅ CORE MODELS - Complete domain models with DartSV integration
export 'src/models/wallet_event.dart';          // Event sourcing base class
export 'src/models/bitcoin_utxo.dart';          // UTXO tracking with reservations
export 'src/models/wallet_state.dart';          // Immutable wallet state
export 'src/models/bitcoin_transaction.dart';   // Transaction tracking

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

// ✅ CORE WALLET SYSTEM - Production-ready event-sourced wallet
export 'src/core/wallet_commands.dart';         // 13 wallet commands extending eventador.Command
export 'src/core/wallet_events.dart';           // 13 wallet events extending AggregateEventBase  
export 'src/core/bitcoin_wallet_aggregate.dart'; // Complete aggregate root with business logic

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

// 🚀 SPV VALIDATION - BEEF/BUMP utilities for SPV transaction validation
export 'src/utils/bump.dart';                   // BSV Universal Merkle Path (BUMP) implementation
export 'src/utils/beef.dart';                   // Background Evaluation Extended Format (BEEF) implementation
export 'src/services/block_header_service.dart'; // Block header management with reorganization handling
export 'src/services/spv_service.dart';         // Enhanced SPV validation with ChainTipTracker integration
export 'src/services/wallet_balance_service.dart'; // BEEF-based multi-tier balance tracking with reorganization handling

// TRANSACTION BUILDING - Production-ready transaction construction
export 'src/services/transaction_builder_service.dart'; // Comprehensive transaction building with UTXO selection

