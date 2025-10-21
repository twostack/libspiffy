import 'event_storage.dart';
import 'read_model_storage.dart';

export 'event_storage.dart';
export 'read_model_storage.dart';

/// Combined storage interface for backward compatibility.
///
/// This interface inherits from both EventStorage and ReadModelStorage,
/// providing a unified interface for implementations that handle both
/// event sourcing and read model operations.
///
/// **Recommended Approach:**
/// - New implementations should implement `EventStorage` OR `ReadModelStorage` separately
/// - Use `EventStorage` for event store implementations (e.g., Eventador)
/// - Use `ReadModelStorage` for query/projection implementations (e.g., IsarWalletStorage)
/// - Only implement `WalletStorage` if you need both capabilities in one class
///
/// **Example:**
/// ```dart
/// // Separate concerns (recommended)
/// class IsarWalletStorage implements ReadModelStorage { ... }
/// class EventadorStorage implements EventStorage { ... }
///
/// // Combined implementation (for testing/in-memory)
/// class InMemoryWalletStorage implements WalletStorage { ... }
/// ```
abstract class WalletStorage implements EventStorage, ReadModelStorage {
  // All methods inherited from EventStorage and ReadModelStorage
} 