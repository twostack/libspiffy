import 'dart:async';
import 'package:dactor/dactor.dart';
import 'package:eventador/eventador.dart';
import 'package:isar/isar.dart';

import '../storage/wallet_storage.dart';
import '../storage/in_memory_wallet_storage.dart';
import '../storage/isar_wallet_storage.dart';
import '../storage/isar_config.dart';
import '../storage/secure_storage.dart';
import '../storage/in_memory_secure_storage.dart';
import '../services/crypto_service.dart';
import '../services/dartsv_crypto_service.dart';
import '../services/arc_service_config.dart';
import '../spv/block_header_chain.dart';
import '../integration/spiffynode_bridge.dart';
import '../projections/wallet_projection.dart';
import '../projections/invoice_projection.dart';
import '../core/wallet_events.dart';
import '../core/invoice_events.dart';
import 'wallet_manager_actor.dart';
import 'spv_actor.dart';
import 'arc_actor.dart';
import 'header_sync_actor.dart';
import 'invoice_coordinator_actor.dart';

/// Initialization and management utilities for the LibSpiffy actor system
class LibSpiffyActorSystem {
  late ActorSystem _actorSystem;
  bool _ownsActorSystem = false;
  late IsarEventStore _eventStore;
  late ReadModelStorage _walletStorage;
  late WalletStorage _actorStorage; // For actors that need full WalletStorage
  late SecureStorage _secureStorage;
  late CryptoService _cryptoService;
  late BlockHeaderChain _headerChain;
  ArcServiceConfig? _arcConfig;
  
  // SpiffyNode integration (optional)
  SpiffyNodeBridge? _spiffyNodeBridge;
  
  // CQRS Projections (read-side event handlers)
  ProjectionManager? _projectionManager;
  WalletProjection? _walletProjection;
  InvoiceProjection? _invoiceProjection;
  
  // Actor references
  ActorRef? _walletManager;
  ActorRef? _invoiceCoordinator;
  ActorRef? _spvActor;
  ActorRef? _arcActor;
  ActorRef? _headerSyncActor;
  
  // Actor instances (kept for configuration after spawn)
  HeaderSyncActor? _headerSyncActorInstance;

  /// Initialize the LibSpiffy actor system
  /// 
  /// If [actorSystem] is provided, LibSpiffy will spawn its actors in the provided system.
  /// This allows integration with a host application's existing actor system.
  /// If [actorSystem] is null, LibSpiffy will create and manage its own actor system.
  ///
  /// If [isar] is provided, LibSpiffy will use it for read-model storage and optionally
  /// for event storage. The host application is responsible for including LibSpiffy's
  /// schemas when opening the Isar instance.
  ///
  /// If [readModelStorage] is provided, it will be used instead of creating IsarWalletStorage.
  /// Note: If providing custom storage, it's recommended to implement ReadModelStorage
  /// rather than the full WalletStorage interface.
  /// 
  /// Example with host actor system and Isar:
  /// ```dart
  /// final hostActorSystem = LocalActorSystem(ActorSystemConfig());
  /// final isar = await Isar.open([...LibSpiffySchemas.walletSchemas, ...hostSchemas]);
  /// 
  /// await libspiffy.initialize(
  ///   actorSystem: hostActorSystem,
  ///   isar: isar,
  ///   isolateConfig: IsolateConfig.defaultConfig(),
  /// );
  /// ```
  /// 
  /// Example with standalone system:
  /// ```dart
  /// await libspiffy.initialize(); // Creates its own actor system and uses in-memory storage
  /// ```
  Future<void> initialize({
    ActorSystem? actorSystem,
    String? dataDirectory,
    ActorSystemConfig? config,
    ReadModelStorage? readModelStorage,
    SecureStorage? secureStorage,
    CryptoService? cryptoService,
    ArcServiceConfig? arcConfig,
    Isar? isar,
    IsolateConfig? isolateConfig,
  }) async {
    print('Initializing LibSpiffy Actor System...');
    
    // 1. Initialize Dactor system (use provided or create new)
    if (actorSystem != null) {
      print('Using provided actor system');
      _actorSystem = actorSystem;
      _ownsActorSystem = false;
    } else {
      print('Creating new actor system');
      _actorSystem = LocalActorSystem(config ?? ActorSystemConfig());
      _ownsActorSystem = true;
    }
    
    // 2. Initialize Eventador storage
    if (isar != null) {
      // Use provided Isar instance for event store
      print('Using provided Isar instance for event store');
      _eventStore = IsarEventStore(isar);
    } else {
      // Create separate Isar instance for Eventador
      print('Creating Isar instance for event store');
      await Isar.initializeIsarCore(download: true);
      _eventStore = await IsarEventStore.create(directory: dataDirectory ?? './data');
    }
    
    // 3. Initialize read model storage (use provided or create based on Isar)
    if (readModelStorage != null) {
      print('Using provided read model storage');
      _walletStorage = readModelStorage;
      // For actors: if the provided storage is already WalletStorage, use it
      // Otherwise create a separate InMemoryWalletStorage for actors
      if (readModelStorage is WalletStorage) {
        _actorStorage = readModelStorage;
        print('Using same storage instance for actors (implements WalletStorage)');
      } else {
        _actorStorage = InMemoryWalletStorage();
        print('Using separate InMemoryWalletStorage for actors');
      }
    } else if (isar != null) {
      print('Creating Isar wallet storage with provided Isar instance');
      _walletStorage = IsarWalletStorage(isar, config: isolateConfig);
      // For actors, use InMemoryWalletStorage as they need full WalletStorage
      // TODO: Update actors to use ReadModelStorage instead of WalletStorage
      _actorStorage = InMemoryWalletStorage();
    } else {
      print('Using in-memory wallet storage (development mode)');
      final inMemoryStorage = InMemoryWalletStorage();
      _walletStorage = inMemoryStorage;
      _actorStorage = inMemoryStorage;
    }
    
    // 4. Initialize secure storage (use provided or default to in-memory)
    _secureStorage = secureStorage ?? InMemorySecureStorage();
    
    // 5. Initialize crypto service (use provided or default to DartSV)
    _cryptoService = cryptoService ?? DartSVCryptoService();
    
    // 6. Store ARC configuration for actors
    _arcConfig = arcConfig;
    
    // 7. Initialize block header chain for SPV validation
    _headerChain = BlockHeaderChain(_actorStorage);
    await _headerChain.initialize();
    
    // 7.5. Register event types for deserialization (BEFORE projections!)
    await _registerEventTypes();
    
    // 8. Initialize CQRS projections (read-side event handlers)
    await _initializeProjections();
    
    // 9. Spawn coordination actors
    await _spawnActors();
    
    print('LibSpiffy Actor System initialized successfully');
  }
  
  /// Register all LibSpiffy event types with Eventador's EventRegistry
  /// 
  /// This is REQUIRED for event deserialization from CBOR storage after restart.
  /// During live operation, events flow through memory as objects, but after
  /// a restart, they must be reconstructed from CBOR bytes in the EventStore.
  /// 
  /// The EventRegistry provides the mapping from event type names to their
  /// fromMap() factory functions for deserialization.
  /// 
  /// MUST be called before _initializeProjections() because projections may
  /// need to deserialize events when catching up on startup.
  Future<void> _registerEventTypes() async {
    print('Registering event types with Eventador EventRegistry...');
    
    // =================================================================
    // WALLET EVENTS (16 total)
    // =================================================================
    
    // Wallet Lifecycle
    EventRegistry.register<WalletCreatedEvent>(
      'WalletCreatedEvent',
      (map) => WalletCreatedEvent.fromMap(map),
    );
    
    EventRegistry.register<WalletConfigurationUpdatedEvent>(
      'WalletConfigurationUpdatedEvent',
      (map) => WalletConfigurationUpdatedEvent.fromMap(map),
    );
    
    // Address Management
    EventRegistry.register<AddressGeneratedEvent>(
      'AddressGeneratedEvent',
      (map) => AddressGeneratedEvent.fromMap(map),
    );
    
    EventRegistry.register<AddressLabelUpdatedEvent>(
      'AddressLabelUpdatedEvent',
      (map) => AddressLabelUpdatedEvent.fromMap(map),
    );
    
    // UTXO Management
    EventRegistry.register<UTXOReceivedEvent>(
      'UTXOReceivedEvent',
      (map) => UTXOReceivedEvent.fromMap(map),
    );
    
    EventRegistry.register<UTXOSpentEvent>(
      'UTXOSpentEvent',
      (map) => UTXOSpentEvent.fromMap(map),
    );
    
    EventRegistry.register<UTXOConfirmationUpdatedEvent>(
      'UTXOConfirmationUpdatedEvent',
      (map) => UTXOConfirmationUpdatedEvent.fromMap(map),
    );
    
    // UTXO Reservation (Legacy)
    EventRegistry.register<UTXOReservedEvent>(
      'UTXOReservedEvent',
      (map) => UTXOReservedEvent.fromMap(map),
    );
    
    EventRegistry.register<UTXOReleasedEvent>(
      'UTXOReleasedEvent',
      (map) => UTXOReleasedEvent.fromMap(map),
    );
    
    EventRegistry.register<UTXOReservationRenewedEvent>(
      'UTXOReservationRenewedEvent',
      (map) => UTXOReservationRenewedEvent.fromMap(map),
    );
    
    // UTXO Reservation (New Pattern)
    EventRegistry.register<UTXOReservationPlacedEvent>(
      'UTXOReservationPlacedEvent',
      (map) => UTXOReservationPlacedEvent.fromMap(map),
    );
    
    EventRegistry.register<UTXOReservationReleasedEvent>(
      'UTXOReservationReleasedEvent',
      (map) => UTXOReservationReleasedEvent.fromMap(map),
    );
    
    EventRegistry.register<UTXOReservationExpiredEvent>(
      'UTXOReservationExpiredEvent',
      (map) => UTXOReservationExpiredEvent.fromMap(map),
    );
    
    // Transaction Management
    EventRegistry.register<TransactionCreatedEvent>(
      'TransactionCreatedEvent',
      (map) => TransactionCreatedEvent.fromMap(map),
    );
    
    EventRegistry.register<TransactionSignedEvent>(
      'TransactionSignedEvent',
      (map) => TransactionSignedEvent.fromMap(map),
    );
    
    EventRegistry.register<TransactionBroadcastEvent>(
      'TransactionBroadcastEvent',
      (map) => TransactionBroadcastEvent.fromMap(map),
    );
    
    // =================================================================
    // INVOICE EVENTS (5 total)
    // =================================================================
    
    EventRegistry.register<InvoiceCreatedEvent>(
      'InvoiceCreatedEvent',
      (map) => InvoiceCreatedEvent.fromMap(map),
    );
    
    EventRegistry.register<InvoiceStatusChangedEvent>(
      'InvoiceStatusChangedEvent',
      (map) => InvoiceStatusChangedEvent.fromMap(map),
    );
    
    EventRegistry.register<InvoicePaidEvent>(
      'InvoicePaidEvent',
      (map) => InvoicePaidEvent.fromMap(map),
    );
    
    EventRegistry.register<InvoiceExpiredEvent>(
      'InvoiceExpiredEvent',
      (map) => InvoiceExpiredEvent.fromMap(map),
    );
    
    EventRegistry.register<InvoiceCancelledEvent>(
      'InvoiceCancelledEvent',
      (map) => InvoiceCancelledEvent.fromMap(map),
    );
    
    print('✓ Registered 21 event types for deserialization');
  }
  
  /// Initialize CQRS projections for read-side persistence
  /// 
  /// Projections listen to events from the EventStore and build denormalized
  /// read models in Isar for efficient queries. This separates write concerns
  /// (aggregates) from read concerns (queries).
  Future<void> _initializeProjections() async {
    print('Initializing CQRS projections...');
    
    // Create ProjectionManager with EventStream from EventStore
    _projectionManager = ProjectionManager(_eventStore);
    
    // Create and register WalletProjection
    _walletProjection = WalletProjection(
      projectionId: 'wallet-projection',
      eventStore: _eventStore,
      storage: _walletStorage,
    );
    await _projectionManager!.registerProjection(_walletProjection!);
    
    // Create and register InvoiceProjection
    _invoiceProjection = InvoiceProjection(
      projectionId: 'invoice-projection',
      eventStore: _eventStore,
      storage: _walletStorage,
    );
    await _projectionManager!.registerProjection(_invoiceProjection!);
    
    // Start streaming events to projections
    await _projectionManager!.start();
    
    print('✓ ProjectionManager started with 2 projections');
  }

  /// Spawn all coordination actors
  Future<void> _spawnActors() async {
    print('Spawning LibSpiffy actors...');
    
    // Spawn WalletManagerActor first
    _walletManager = await _actorSystem.spawn('wallet-manager', () => WalletManagerActor(
      eventStore: _eventStore,
      cryptoService: _cryptoService,
      secureStorage: _secureStorage,
    ));
    
    // Spawn InvoiceCoordinatorActor (needed for invoice-based payments)
    // Coordinator routes commands to InvoiceAggregate instances
    _invoiceCoordinator = await _actorSystem.spawn('invoice-coordinator', () => InvoiceCoordinatorActor(
      walletManager: _walletManager!,
      storage: _walletStorage,
      eventStore: _eventStore,
    ));
    
    // Wire up InvoiceCoordinator reference in WalletManager
    // We'll send a message to set the reference
    _walletManager!.tell(SetInvoiceManagerMessage(_invoiceCoordinator!));
    
    // Spawn HeaderSyncActor early (other actors may need to communicate with it)
    _headerSyncActorInstance = HeaderSyncActor(
      headerChain: _headerChain,
      spvActor: null, // Will be set after SPVActor is spawned
      spiffyNodeBridge: null, // Will be set after SpiffyNode connection
    );
    _headerSyncActor = await _actorSystem.spawn('header-sync', () => _headerSyncActorInstance!);
    
    // Spawn SPVActor with reference to WalletManager, InvoiceCoordinator and storage
    _spvActor = await _actorSystem.spawn('spv-actor', () => SPVActor(
      walletManager: _walletManager!,
      invoiceCoordinator: _invoiceCoordinator!,
      storage: _actorStorage,
    ));
    
    // Now update HeaderSyncActor with SPVActor reference
    // Note: This is a limitation of the current design - we need a way to update references
    
    // Spawn ARCActor with reference to WalletManager and ARC config
    _arcActor = await _actorSystem.spawn('arc-actor', () => ARCActor(
      walletManager: _walletManager!,
      arcConfig: _arcConfig,
    ));
    
    print('All LibSpiffy actors spawned successfully');
  }

  /// Get reference to the WalletManager actor
  ActorRef get walletManager {
    if (_walletManager == null) {
      throw StateError('LibSpiffy actor system not initialized');
    }
    return _walletManager!;
  }

  /// Get reference to the SPV actor
  ActorRef get spvActor {
    if (_spvActor == null) {
      throw StateError('LibSpiffy actor system not initialized');
    }
    return _spvActor!;
  }

  /// Get reference to the ARC actor
  ActorRef get arcActor {
    if (_arcActor == null) {
      throw StateError('LibSpiffy actor system not initialized');
    }
    return _arcActor!;
  }

  /// Get reference to the HeaderSync actor
  ActorRef get headerSyncActor {
    if (_headerSyncActor == null) {
      throw StateError('LibSpiffy actor system not initialized');
    }
    return _headerSyncActor!;
  }

  /// Get reference to the Invoice Coordinator actor
  ActorRef get invoiceCoordinator {
    if (_invoiceCoordinator == null) {
      throw StateError('LibSpiffy actor system not initialized');
    }
    return _invoiceCoordinator!;
  }

  /// Get reference to the wallet storage
  ReadModelStorage get walletStorage {
    if (!isInitialized) {
      throw StateError('LibSpiffy actor system not initialized');
    }
    return _walletStorage;
  }

  /// Get reference to the block header chain
  BlockHeaderChain get headerChain {
    if (!isInitialized) {
      throw StateError('LibSpiffy actor system not initialized');
    }
    return _headerChain;
  }

  /// Get reference to the crypto service
  CryptoService get cryptoService {
    if (!isInitialized) {
      throw StateError('LibSpiffy actor system not initialized');
    }
    return _cryptoService;
  }

  /// Get reference to the secure storage
  SecureStorage get secureStorage {
    if (!isInitialized) {
      throw StateError('LibSpiffy actor system not initialized');
    }
    return _secureStorage;
  }

  /// Get reference to the SpiffyNode bridge (if connected)
  SpiffyNodeBridge? get spiffyNodeBridge => _spiffyNodeBridge;

  /// Get reference to the ProjectionManager (CQRS read-side)
  /// 
  /// The ProjectionManager routes events from the EventStore to registered
  /// projections which build denormalized read models for queries.
  ProjectionManager? get projectionManager => _projectionManager;

  /// Get reference to the WalletProjection
  /// 
  /// The WalletProjection listens to wallet events and maintains wallet
  /// read models in Isar for efficient queries.
  WalletProjection? get walletProjection => _walletProjection;

  /// Get reference to the InvoiceProjection
  /// 
  /// The InvoiceProjection listens to invoice events and maintains invoice
  /// read models in Isar for efficient queries.
  InvoiceProjection? get invoiceProjection => _invoiceProjection;

  /// Get reference to the underlying actor system
  /// 
  /// This is useful for host applications that need to interact with
  /// the actor system directly (e.g., spawning additional actors).
  ActorSystem get actorSystem {
    if (!isInitialized) {
      throw StateError('LibSpiffy actor system not initialized');
    }
    return _actorSystem;
  }

  /// Check if LibSpiffy owns and manages its own actor system
  /// 
  /// Returns true if LibSpiffy created its own actor system.
  /// Returns false if a host application provided the actor system.
  bool get ownsActorSystem => _ownsActorSystem;

  /// Connect to SpiffyNode for automatic block header synchronization
  /// 
  /// This creates a bridge between SpiffyNode's ChainTipTracker and LibSpiffy's
  /// BlockHeaderChain to enable automatic header storage for SPV validation.
  Future<void> connectToSpiffyNode(dynamic peerManager) async {
    if (!isInitialized) {
      throw StateError('LibSpiffy actor system not initialized');
    }

    if (_spiffyNodeBridge != null) {
      print('Already connected to SpiffyNode');
      return;
    }

    try {
      print('Connecting LibSpiffy to SpiffyNode...');
      
      _spiffyNodeBridge = SpiffyNodeBridge(
        peerManager: peerManager,
        headerSyncActor: _headerSyncActor!,
      );
      
      await _spiffyNodeBridge!.initialize();
      
      // Set the bridge reference in HeaderSyncActor
      _headerSyncActorInstance?.setSpiffyNodeBridge(_spiffyNodeBridge);
      
      print('LibSpiffy-SpiffyNode integration active');
      print('Bridge statistics: ${_spiffyNodeBridge!.statistics}');
      
    } catch (e) {
      print('Failed to connect to SpiffyNode: $e');
      _spiffyNodeBridge = null;
      rethrow;
    }
  }

  /// Disconnect from SpiffyNode
  Future<void> disconnectFromSpiffyNode() async {
    if (_spiffyNodeBridge != null) {
      print('Disconnecting from SpiffyNode...');
      await _spiffyNodeBridge!.shutdown();
      _spiffyNodeBridge = null;
      print('Disconnected from SpiffyNode');
    }
  }

  /// Shutdown the LibSpiffy actor system
  /// 
  /// This will:
  /// - Disconnect from SpiffyNode if connected
  /// - Stop projection manager
  /// - Close the event store
  /// - Shutdown the actor system ONLY if LibSpiffy created it (not provided by host)
  /// 
  /// If the host application provided its own actor system, it remains
  /// the host's responsibility to shut it down.
  Future<void> shutdown() async {
    print('Shutting down LibSpiffy Actor System...');
    
    try {
      // 1. Disconnect from SpiffyNode first
      await disconnectFromSpiffyNode();
      
      // 2. Stop projection manager
      if (_projectionManager != null) {
        await _projectionManager!.stop();
      }
      
      // 3. Shutdown actor system only if we own it
      if (_ownsActorSystem) {
        print('Shutting down LibSpiffy-owned actor system');
        await _actorSystem.shutdown();
      } else {
        print('Actor system owned by host application - not shutting down');
      }
      
      // 4. Always close event store
      await _eventStore.close();
      
      print('LibSpiffy Actor System shutdown complete');
    } catch (e) {
      print('Error during shutdown: $e');
      rethrow;
    }
  }

  /// Check if the system is initialized
  bool get isInitialized => _walletManager != null && _invoiceCoordinator != null && _spvActor != null && _arcActor != null && _headerSyncActor != null;
}

/// Global instance for easy access
LibSpiffyActorSystem? _globalInstance;

/// Get or create the global LibSpiffy actor system instance
LibSpiffyActorSystem getLibSpiffySystem() {
  _globalInstance ??= LibSpiffyActorSystem();
  return _globalInstance!;
}

/// Initialize the global LibSpiffy actor system instance
/// 
/// If [actorSystem] is provided, LibSpiffy will integrate with the host's actor system.
/// Otherwise, it creates its own isolated system.
///
/// If [isar] is provided, LibSpiffy will use it for read-model storage and optionally
/// for event storage. The host application must include LibSpiffy's schemas when
/// opening the Isar instance using LibSpiffySchemas.walletSchemas.
Future<void> initializeLibSpiffy({
  ActorSystem? actorSystem,
  String? dataDirectory,
  ActorSystemConfig? config,
  ReadModelStorage? readModelStorage,
  SecureStorage? secureStorage,
  CryptoService? cryptoService,
  ArcServiceConfig? arcConfig,
  Isar? isar,
  IsolateConfig? isolateConfig,
}) async {
  final system = getLibSpiffySystem();
  await system.initialize(
    actorSystem: actorSystem,
    dataDirectory: dataDirectory,
    config: config,
    readModelStorage: readModelStorage,
    secureStorage: secureStorage,
    cryptoService: cryptoService,
    arcConfig: arcConfig,
    isar: isar,
    isolateConfig: isolateConfig,
  );
}

/// Shutdown the global LibSpiffy actor system instance
Future<void> shutdownLibSpiffy() async {
  if (_globalInstance != null) {
    await _globalInstance!.shutdown();
    _globalInstance = null;
  }
}

/// Internal message to set InvoiceManager reference in WalletManager
class SetInvoiceManagerMessage implements Message {
  final ActorRef invoiceManager;
  
  SetInvoiceManagerMessage(this.invoiceManager);

  @override
  String get correlationId => 'set-invoice-manager-${DateTime.now().millisecondsSinceEpoch}';
  
  @override
  Map<String, dynamic> get metadata => {};
  
  @override
  ActorRef? get replyTo => null;
  
  @override
  DateTime get timestamp => DateTime.now();
} 