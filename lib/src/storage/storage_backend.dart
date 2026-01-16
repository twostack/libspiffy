/// Storage backend configuration for libspiffy.
///
/// Defines the available storage backends and provides factory methods
/// for creating the appropriate storage implementations.
library;

import 'package:isar/isar.dart';
import 'package:eventador/eventador.dart';

import 'read_model_storage.dart';
import 'isar_wallet_storage.dart';
import 'in_memory_wallet_storage.dart';
import 'isar_config.dart';
import 'postgres/postgres_config.dart';
import 'postgres/postgres_wallet_storage.dart';
import 'postgres/postgres_event_store.dart';

/// Available storage backend options for libspiffy.
///
/// - [isar]: Embedded database for mobile/desktop applications (default)
/// - [postgres]: PostgreSQL for server-side deployments
/// - [inMemory]: In-memory storage for testing only
enum StorageBackend {
  /// Isar embedded database - suitable for mobile and desktop apps.
  /// This is the default backend.
  isar,

  /// PostgreSQL database - suitable for server-side deployments.
  /// Requires a PostgreSQL server and connection configuration.
  postgres,

  /// In-memory storage - for testing purposes only.
  /// Data is lost when the application terminates.
  inMemory,
}

/// Factory for creating storage instances based on the selected backend.
///
/// This class provides methods to create both read model storage and
/// event store implementations for the specified backend.
class StorageFactory {
  /// Creates a [ReadModelStorage] instance for the specified backend.
  ///
  /// Parameters:
  /// - [backend]: The storage backend to use
  /// - [isar]: Required for [StorageBackend.isar] - the Isar database instance
  /// - [isolateConfig]: Optional Isar-specific configuration for isolate support
  /// - [postgresConfig]: Required for [StorageBackend.postgres] - PostgreSQL connection config
  ///
  /// Throws [ArgumentError] if required configuration is missing for the backend.
  static Future<ReadModelStorage> createReadModelStorage({
    required StorageBackend backend,
    Isar? isar,
    IsolateConfig? isolateConfig,
    PostgresConfig? postgresConfig,
  }) async {
    switch (backend) {
      case StorageBackend.isar:
        if (isar == null) {
          throw ArgumentError('Isar instance required for Isar backend');
        }
        return IsarWalletStorage(isar, config: isolateConfig);

      case StorageBackend.postgres:
        if (postgresConfig == null) {
          throw ArgumentError('PostgresConfig required for PostgreSQL backend');
        }
        final storage = PostgresWalletStorage(postgresConfig);
        await storage.initialize();
        return storage;

      case StorageBackend.inMemory:
        return InMemoryWalletStorage();
    }
  }

  /// Creates an [EventStore] instance for the specified backend.
  ///
  /// Parameters:
  /// - [backend]: The storage backend to use
  /// - [isar]: Required for [StorageBackend.isar] - the Isar database instance
  /// - [postgresConfig]: Required for [StorageBackend.postgres] - PostgreSQL connection config
  ///
  /// Throws [ArgumentError] if required configuration is missing.
  /// Throws [UnsupportedError] for [StorageBackend.inMemory].
  static Future<EventStore> createEventStore({
    required StorageBackend backend,
    Isar? isar,
    PostgresConfig? postgresConfig,
  }) async {
    switch (backend) {
      case StorageBackend.isar:
        if (isar == null) {
          throw ArgumentError('Isar instance required for Isar backend');
        }
        return IsarEventStore(isar);

      case StorageBackend.postgres:
        if (postgresConfig == null) {
          throw ArgumentError('PostgresConfig required for PostgreSQL backend');
        }
        final eventStore = PostgresEventStore(postgresConfig);
        await eventStore.initialize();
        return eventStore;

      case StorageBackend.inMemory:
        throw UnsupportedError(
          'In-memory EventStore is not supported. '
          'Use Isar or PostgreSQL backend for event sourcing.',
        );
    }
  }

  /// Creates both read model storage and event store for the specified backend.
  ///
  /// This is a convenience method that creates both storage types at once.
  ///
  /// Returns a record containing both storage instances.
  static Future<({ReadModelStorage readModel, EventStore eventStore})>
      createStorages({
    required StorageBackend backend,
    Isar? isar,
    IsolateConfig? isolateConfig,
    PostgresConfig? postgresConfig,
  }) async {
    final readModel = await createReadModelStorage(
      backend: backend,
      isar: isar,
      isolateConfig: isolateConfig,
      postgresConfig: postgresConfig,
    );

    final eventStore = await createEventStore(
      backend: backend,
      isar: isar,
      postgresConfig: postgresConfig,
    );

    return (readModel: readModel, eventStore: eventStore);
  }
}
