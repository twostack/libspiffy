import '../models/wallet_event.dart';

/// Abstract interface for event storage operations.
///
/// This interface handles event sourcing operations for wallet aggregates.
/// In production, Eventador's IsarEventStore typically provides this functionality.
abstract class EventStorage {
  /// Save a list of events for a specific wallet.
  ///
  /// Events should be saved atomically - either all events are saved
  /// or none are saved. The implementation should handle concurrency
  /// and ensure event ordering is maintained.
  ///
  /// Parameters:
  /// - [walletId]: Unique identifier for the wallet
  /// - [events]: List of events to save
  ///
  /// Throws [StorageException] if the save operation fails
  Future<void> saveEvents(String walletId, List<WalletEvent> events);

  /// Load events for a specific wallet, optionally starting from a version.
  ///
  /// Events should be returned in the order they were saved.
  /// If [fromVersion] is provided, only events after that version
  /// should be returned.
  ///
  /// Parameters:
  /// - [walletId]: Unique identifier for the wallet
  /// - [fromVersion]: Optional version number to start loading from
  ///
  /// Returns: List of events in chronological order
  ///
  /// Throws [StorageException] if the load operation fails
  Future<List<WalletEvent>> loadEvents(String walletId, {int? fromVersion});
}

/// Exception thrown when event storage operations fail.
class StorageException implements Exception {
  final String message;
  final Object? cause;

  const StorageException(this.message, [this.cause]);

  @override
  String toString() {
    if (cause != null) {
      return 'StorageException: $message (caused by: $cause)';
    }
    return 'StorageException: $message';
  }
}

