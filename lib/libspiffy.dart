/// LibSpiffy - Actor-Based Bitcoin SPV Wallet Library
/// 
/// A comprehensive SPV wallet library built on the Dactor/Eventador stack
/// with SpiffyNode integration for robust P2P functionality and chain tracking.
library libspiffy;

// Core Models
export 'src/models/wallet_event.dart';
export 'src/models/bitcoin_utxo.dart';
export 'src/models/wallet_state.dart';
export 'src/models/bitcoin_transaction.dart';

// Storage Interfaces
export 'src/storage/wallet_storage.dart';
export 'src/storage/secure_storage.dart';

// Storage Implementations
export 'src/storage/in_memory_wallet_storage.dart';
export 'src/storage/in_memory_secure_storage.dart';

// Core Wallet Components
export 'src/core/wallet_commands.dart';
export 'src/core/wallet_events.dart';
export 'src/core/bitcoin_wallet_aggregate.dart';

