import 'dart:async';
import 'package:dactor/dactor.dart';
import 'package:eventador/eventador.dart';
import 'package:isar/isar.dart';
import 'package:libspiffy/libspiffy.dart';
import 'package:logging/logging.dart';
import 'package:spiffynode/spiffy_node.dart';

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
import 'payment_coordinator_actor.dart';
import 'benford_coordinator_actor.dart';
import 'import_actor.dart';
import '../services/transaction_import_service.dart';

/// Initialization and management utilities for the LibSpiffy actor system
class LibSpiffyActorSystem {
  late ActorSystem _actorSystem;
  bool _ownsActorSystem = false;
  bool _ownsIsar = false; // Track if we created the Isar instance
  late IsarEventStore _eventStore;
  late ReadModelStorage _walletStorage;
  late ReadModelStorage _actorStorage; // For actors (headers, UTXOs, etc.)
  late SecureStorage _secureStorage;
  late CryptoService _cryptoService;
  late BlockHeaderChain _headerChain;
  ArcServiceConfig? _arcConfig;
  dynamic _arcService;  // ← Mock service for testing (dynamic for test mocks)
  
  // Transaction import service
  TransactionImportService? _transactionImportService;
  
  // SpiffyNode integration (optional)
  SpiffyNodeBridge? _spiffyNodeBridge;
  PeerManager? _peerManager;
  
  // CQRS Projections (read-side event handlers)
  ProjectionManager? _projectionManager;
  WalletProjection? _walletProjection;
  InvoiceProjection? _invoiceProjection;
  
  // Actor references
  ActorRef? _walletManager;
  ActorRef? _invoiceCoordinator;
  ActorRef? _paymentCoordinator;
  ActorRef? _benfordCoordinator;
  ActorRef? _spvActor;
  ActorRef? _arcActor;
  ActorRef? _headerSyncActor;
  ActorRef? _importActor;
  
  // Actor instances (kept for configuration after spawn)
  HeaderSyncActor? _headerSyncActorInstance;
  
  // Blockchain data source for imports (optional)
  dynamic _blockchainDataSource;
  
  // Event broadcast for UI subscriptions
  final StreamController<WalletEvent> _walletEventBroadcaster = StreamController<WalletEvent>.broadcast();

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
  /// P2P Configuration:
  /// - [networkType]: 'main' for mainnet, 'test' for testnet (default: 'test')
  /// - [enableP2P]: Enable automatic P2P block header synchronization (default: true)
  /// - [startHeight]: Optional starting block height for SPV sync
  /// - [peerAddresses]: Optional custom peer addresses in 'host:port' format
  /// - [userAgent]: Optional custom user agent string (default: '/LibSpiffy:1.0/')
  /// 
  /// When [enableP2P] is true, LibSpiffy automatically:
  /// - Initializes SpiffyNode for P2P connectivity (no application setup needed)
  /// - Connects to Bitcoin network seed nodes (or custom peers if provided)
  /// - Synchronizes block headers for SPV validation
  /// - Manages all P2P resources internally
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
  ///   networkType: 'test',
  ///   enableP2P: true,
  /// );
  /// ```
  /// 
  /// Example with standalone system (P2P disabled):
  /// ```dart
  /// await libspiffy.initialize(enableP2P: false); // No P2P connectivity
  /// ```
  Future<void> initialize({
    ActorSystem? actorSystem,
    String? dataDirectory,
    ActorSystemConfig? config,
    ReadModelStorage? readModelStorage,
    SecureStorage? secureStorage,
    CryptoService? cryptoService,
    ArcServiceConfig? arcConfig,
    dynamic arcService,  // ← Allow injecting mock service for testing (dynamic for test mocks)
    Isar? isar,
    IsolateConfig? isolateConfig,
    String networkType = 'test',
    bool enableP2P = true,
    int? startHeight,
    List<String>? peerAddresses,
    String? userAgent,
    dynamic blockchainDataSource, // For wallet imports (WhatsOnChainDataSource, etc.)
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
      _ownsIsar = false; // Isar instance owned by host application
    } else {
      // Create separate Isar instance for Eventador
      print('Creating Isar instance for event store');
      await Isar.initializeIsarCore(download: true);
      _eventStore = await IsarEventStore.create(directory: dataDirectory ?? './data');
      _ownsIsar = true; // We created and own this Isar instance
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
      final isarStorage = IsarWalletStorage(isar, config: isolateConfig);
      _walletStorage = isarStorage;
      // Block headers MUST be persisted to Isar for SPV validation!
      // Use Isar storage for actors that need persistent storage (headers, etc.)
      _actorStorage = isarStorage;
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
    _arcService = arcService;  // ← Store mock service for testing
    
    // 6.5. Store blockchain data source for imports
    _blockchainDataSource = blockchainDataSource;
    
    // 7. Initialize block header chain for SPV validation
    // IMPORTANT: BlockHeaderChain uses _actorStorage which now points to Isar
    _headerChain = BlockHeaderChain(_actorStorage);
    await _headerChain.initialize();
    
    // 7.5. Register event types for deserialization (BEFORE projections!)
    await _registerEventTypes();
    
    // 8. Initialize CQRS projections (read-side event handlers)
    await _initializeProjections();
    
    // 9. Spawn coordination actors
    await _spawnActors();
    
    // 10. Transaction import service will be created on-demand by ImportActor
    // No longer initialized here - uses dependency injection via BlockchainDataSource
    print('✓ Transaction import service ready (on-demand)');
    
    // 11. Initialize P2P if enabled
    if (enableP2P) {
      await _initializeP2P(
        networkType: networkType,
        startHeight: startHeight,
        peerAddresses: peerAddresses,
        userAgent: userAgent,
      );
    }
    
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
    
    EventRegistry.register<UTXOMarkedAvailableEvent>(
      'UTXOMarkedAvailableEvent',
      (map) => UTXOMarkedAvailableEvent.fromMap(map),
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
    
    EventRegistry.register<TransactionImportedEvent>(
      'TransactionImportedEvent',
      (map) => TransactionImportedEvent.fromMap(map),
    );
    
    EventRegistry.register<TransactionRecordedEvent>(
      'TransactionRecordedEvent',
      (map) => TransactionRecordedEvent.fromMap(map),
    );
    
    EventRegistry.register<TransactionConfirmedEvent>(
      'TransactionConfirmedEvent',
      (map) => TransactionConfirmedEvent.fromMap(map),
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
    
    // =================================================================
    // BENFORD SPLIT EVENTS (3 total)
    // =================================================================
    
    EventRegistry.register<UTXOSplitInitiatedEvent>(
      'UTXOSplitInitiatedEvent',
      (map) => UTXOSplitInitiatedEvent.fromMap(map),
    );
    
    EventRegistry.register<UTXOSplitCompletedEvent>(
      'UTXOSplitCompletedEvent',
      (map) => UTXOSplitCompletedEvent.fromMap(map),
    );
    
    EventRegistry.register<AllUTXOsSplitCompletedEvent>(
      'AllUTXOsSplitCompletedEvent',
      (map) => AllUTXOsSplitCompletedEvent.fromMap(map),
    );
    
    print('✓ Registered 25 event types for deserialization');
  }
  
  /// Initialize CQRS projections for read-side persistence
  /// 
  /// Projections listen to events from the EventStore and build denormalized
  /// read models in Isar for efficient queries. This separates write concerns
  /// (aggregates) from read concerns (queries).
  Future<void> _initializeProjections() async {
    print('Initializing CQRS projections...');
    
    // Get Isar instance for checkpoint persistence (if using IsarWalletStorage)
    final Isar? isar = _walletStorage is IsarWalletStorage 
        ? (_walletStorage as IsarWalletStorage).isar 
        : null;
    
    // Create ProjectionManager with EventStream and optional Isar for automatic checkpoint persistence
    _projectionManager = ProjectionManager(_eventStore, isar: isar);
    
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
    
    // TODO: Subscribe to event store for real-time UI broadcasting
    // For now, events will be manually broadcast by actors
    
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
    
    // Spawn PaymentCoordinatorActor for BEEF-based payments
    _paymentCoordinator = await _actorSystem.spawn('payment-coordinator', () => PaymentCoordinatorActor(
      walletManager: _walletManager!,
      storage: _walletStorage,
      secureStorage: _secureStorage,
    ));
    
    // Spawn HeaderSyncActor early (other actors may need to communicate with it)
    _headerSyncActorInstance = HeaderSyncActor(
      headerChain: _headerChain,
      spvActor: null, // Will be set after SPVActor is spawned
      spiffyNodeBridge: null, // Will be set after SpiffyNode connection
      peerManager: null, // Will be set after P2P initialization
      startHeight: null, // Will be set via _initializeP2P parameter
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
      arcService: _arcService,  // ← Pass mock service for testing
    ));
    
    // Wire up ARC actor reference in WalletManager
    _walletManager!.tell(SetArcActorMessage(_arcActor!));
    
    // Spawn Benford coordinator for privacy-focused UTXO splitting
    _benfordCoordinator = await _actorSystem.spawn('benford-coordinator', () => BenfordCoordinatorActor(
      walletManager: _walletManager!,
      arcActor: _arcActor!,
      cryptoService: _cryptoService,
      secureStorage: _secureStorage,
      storage: _walletStorage,
    ));
    
    // Wire up Benford coordinator reference in WalletManager
    _walletManager!.tell(SetBenfordCoordinatorMessage(_benfordCoordinator!));
    
    // Spawn ImportActor if blockchain data source is provided
    if (_blockchainDataSource != null) {
      _importActor = await _actorSystem.spawn('import-actor', () => ImportActor(
        dataSource: _blockchainDataSource,
        storage: _walletStorage,
        walletManagerActor: _walletManager!,
        eventBroadcaster: broadcastWalletEvent,
      ));
      
      // Initialize transaction import service
      _transactionImportService = TransactionImportService(
        dataSource: _blockchainDataSource,
      );
      
      print('✓ ImportActor spawned with blockchain data source');
    }
    
    print('All LibSpiffy actors spawned successfully');
  }

  /// Initialize P2P connectivity with SpiffyNode (internal method)
  /// 
  /// This method:
  /// - Initializes SpiffyNode message types
  /// - Creates PeerManager with appropriate network configuration
  /// - Connects to Bitcoin P2P network via seed nodes or custom peers
  /// - Sets up SpiffyNodeBridge for automatic header synchronization
  Future<void> _initializeP2P({
    required String networkType,
    int? startHeight,
    List<String>? peerAddresses,
    String? userAgent,
  }) async {
    print('Initializing P2P connectivity...');
    
    try {
      // 1. Initialize SpiffyNode message types
      initializeMessages();
      print('✓ SpiffyNode message types initialized');
      
      // 2. Map network type to BitcoinNetwork enum
      final network = networkType == 'main' 
          ? BitcoinNetwork.mainnet 
          : BitcoinNetwork.testnet;
      
      // 3. Create PeerManager
      _peerManager = PeerManager(
        network: network,
        logger: Logger('LibSpiffy-SpiffyNode'),
      );
      print('✓ PeerManager created for ${networkType == 'main' ? 'mainnet' : 'testnet'}');
      
      // 4. Create and initialize SpiffyNodeBridge (before adding peers)
      _spiffyNodeBridge = SpiffyNodeBridge(
        peerManager: _peerManager!,
        headerSyncActor: _headerSyncActor!,
      );
      
      await _spiffyNodeBridge!.initialize();
      print('✓ SpiffyNodeBridge initialized');
      
      // 5. Create LibSpiffyPeerHandler with BlockHeaderChain and HeaderSyncActor references
      // Handler will query actual bestHeight dynamically for each batch
      // and trigger header sync when new blocks are announced
      final peerHandler = LibSpiffyPeerHandler(
        bridge: _spiffyNodeBridge!,
        headerChain: _headerChain, // Pass BlockHeaderChain for dynamic height queries
        headerSyncActor: _headerSyncActor, // Pass HeaderSyncActor for triggering sync on block announcements
      );
      print('✓ LibSpiffyPeerHandler created for header capture and block announcement handling');
      
      // 6. Get peer addresses (use provided or defaults)
      final peers = peerAddresses ?? _getDefaultPeers(networkType);
      
      // 7. Connect to peers WITH handler to capture headers
      // Try ALL peers, only fail if ALL are unreachable
      print('🌐 Attempting to connect to ${peers.length} Bitcoin P2P node(s)...');
      
      int successCount = 0;
      final failures = <String, String>{}; // peer -> error
      
      for (final peerAddr in peers) {
        final parts = peerAddr.split(':');
        if (parts.length != 2) {
          print('⚠️  Invalid peer address format: $peerAddr (expected host:port)');
          failures[peerAddr] = 'Invalid format (expected host:port)';
          continue;
        }
        
        final host = parts[0];
        final port = int.tryParse(parts[1]);
        if (port == null) {
          print('⚠️  Invalid port in peer address: $peerAddr');
          failures[peerAddr] = 'Invalid port number';
          continue;
        }
        
        final peerConfig = startHeight != null
            ? PeerConfig(
                startHeight: startHeight,
                userAgent: userAgent ?? '/LibSpiffy:1.0/',
              )
            : PeerConfig(
                userAgent: userAgent ?? '/LibSpiffy:1.0/',
              );
        
        // Try to connect to this peer
        try {
          print('   → Connecting to $peerAddr...');
          await _peerManager!.addPeerByAddress(
            host,
            port,
            peerConfig: peerConfig,
            handler: peerHandler, // ✨ NEW: Custom handler for header capture!
          );
          successCount++;
          print('   ✅ Connected to peer: $peerAddr with header capture enabled');
        } catch (e) {
          print('   ⚠️  Failed to connect to $peerAddr: $e');
          failures[peerAddr] = e.toString();
          // Don't throw - try the next peer
        }
      }
      
      // Check if we connected to at least one peer
      if (successCount == 0) {
        print('❌ Failed to connect to ANY Bitcoin P2P nodes');
        print('Attempted ${peers.length} peer(s):');
        failures.forEach((peer, error) {
          print('   • $peer: $error');
        });
        _peerManager = null;
        _spiffyNodeBridge = null;
        throw StateError(
          'P2P initialization failed: Could not connect to any of ${peers.length} peer(s). '
          'LibSpiffy will fall back to API-only mode. Failures: ${failures.keys.join(", ")}'
        );
      }
      
      // Log summary
      print('✅ P2P connectivity established: $successCount/${peers.length} peer(s) connected');
      if (failures.isNotEmpty) {
        print('⚠️  Failed to connect to ${failures.length} peer(s):');
        failures.forEach((peer, error) {
          print('   • $peer: $error');
        });
      }
      
      // 8. Set bridge reference in HeaderSyncActor
      _headerSyncActorInstance?.setSpiffyNodeBridge(_spiffyNodeBridge);
      
      // 9. Set PeerManager reference and startHeight in HeaderSyncActor
      _headerSyncActorInstance?.setPeerManager(_peerManager);
      _headerSyncActorInstance?.startHeight = startHeight;
      
      // 10. Trigger initial header sync (PeerManager and handler are set)
      _headerSyncActorInstance?.initiateSyncAfterP2PSetup();
      
      print('✓ Custom handler installed: LibSpiffyPeerHandler will capture MsgHeaders');
      print('Bridge statistics: ${_spiffyNodeBridge!.statistics}');
      
    } catch (e, stackTrace) {
      print('Failed to initialize P2P connectivity: $e');
      print('Stack trace: $stackTrace');
      _peerManager = null;
      _spiffyNodeBridge = null;
      rethrow;
    }
  }
  
  /// Get default seed nodes for the specified network
  List<String> _getDefaultPeers(String networkType) {
    return networkType == 'main'
        ? ['seed.bitcoinsv.io:8333']
        : ['testnet-seed.bitcoinsv.io:18333'];
  }

  /// Get reference to the WalletManager actor
  ActorRef get walletManager {
    if (_walletManager == null) {
      throw StateError('LibSpiffy actor system not initialized');
    }
    return _walletManager!;
  }

  /// Get reference to the PaymentCoordinator actor
  ActorRef get paymentCoordinator {
    if (_paymentCoordinator == null) {
      throw StateError('LibSpiffy actor system not initialized');
    }
    return _paymentCoordinator!;
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
  
  /// Get header sync statistics
  /// Returns current sync progress including stored header count and height
  Map<String, dynamic> getHeaderSyncStats() {
    if (_headerSyncActorInstance == null) {
      return {
        'blockHeight': 0,
        'headerCount': 0,
        'isInitialized': false,
      };
    }
    
    final stats = _headerSyncActorInstance!.statistics;
    return {
      'blockHeight': stats['currentHeight'] ?? 0,
      'headerCount': stats['headersProcessed'] ?? 0,
      'isInitialized': stats['initialized'] ?? false,
      'lastHeaderAt': stats['lastHeaderAt'],
    };
  }

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

  /// Get reference to the transaction import service
  /// 
  /// The TransactionImportService imports historical transactions and
  /// harvests UTXOs using a hybrid event sourcing approach.
  TransactionImportService get transactionImportService {
    if (_transactionImportService == null) {
      throw StateError('LibSpiffy actor system not initialized');
    }
    return _transactionImportService!;
  }

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

  /// Broadcast a wallet event to UI subscribers
  /// 
  /// Internal method used by actors to notify the UI of events
  void broadcastWalletEvent(WalletEvent event) {
    if (_walletEventBroadcaster.isClosed) return;
    _walletEventBroadcaster.add(event);
  }
  
  /// Subscribe to wallet events for a specific wallet
  /// 
  /// Returns a stream of events for the given wallet ID. Useful for
  /// monitoring real-time progress of operations like wallet imports.
  /// 
  /// The stream emits all events from the event store filtered by aggregateId (walletId).
  Stream<WalletEvent> subscribeToWalletEvents(String walletId) {
    if (!isInitialized) {
      throw StateError('LibSpiffy actor system not initialized');
    }
    
    // Return filtered broadcast stream
    return _walletEventBroadcaster.stream.where((event) => event.walletId == walletId);
  }

  /// Import wallet from extended private key (xpriv)
  /// 
  /// This triggers the ImportActor to perform the complete wallet import flow:
  /// 1. Create wallet from xpriv
  /// 2. Discover used addresses (BIP44 gap limit scanning)
  /// 3. Import transactions with merkle proofs
  /// 4. Import UTXOs into the wallet
  /// 
  /// The import runs asynchronously in the ImportActor. Progress can be monitored
  /// by subscribing to wallet events from the event store.
  /// 
  /// Returns immediately after sending the import message to the actor.
  /// Check wallet events or query the wallet projection for completion status.
  void importWalletFromXpriv({
    required String walletId,
    required String xpriv,
    required String walletName,
    String networkType = 'test',
    int addressGapLimit = 20,
  }) {
    if (_importActor == null) {
      throw StateError('ImportActor not available. Did you provide a blockchainDataSource during initialization?');
    }
    
    final importMessage = ImportWalletMessage(
      walletId: walletId,
      xpriv: xpriv,
      walletName: walletName,
      networkType: networkType,
      addressGapLimit: addressGapLimit,
    );
    
    _importActor!.tell(importMessage);
  }

  /// Import wallet from WIF (Wallet Import Format) private key
  /// 
  /// This triggers the ImportActor to perform a single-address wallet import:
  /// 1. Create wallet from WIF
  /// 2. Discover the single address associated with the WIF key
  /// 3. Import transaction history for that address
  /// 4. Import UTXOs into the wallet
  /// 
  /// The import runs asynchronously in the ImportActor. Progress can be monitored
  /// by subscribing to wallet events from the event store.
  /// 
  /// Returns immediately after sending the import message to the actor.
  /// Check wallet events or query the wallet projection for completion status.
  void importWalletFromWif({
    required String walletId,
    required String wif,
    required String walletName,
    String networkType = 'test',
  }) {
    if (_importActor == null) {
      throw StateError('ImportActor not available. Did you provide a blockchainDataSource during initialization?');
    }
    
    final importMessage = ImportWalletMessage(
      walletId: walletId,
      wif: wif,
      walletName: walletName,
      networkType: networkType,
      addressGapLimit: 1, // Not used for WIF, but required by message
    );
    
    _importActor!.tell(importMessage);
  }

  /// Disconnect from SpiffyNode
  Future<void> disconnectFromSpiffyNode() async {
    if (_spiffyNodeBridge != null) {
      print('Disconnecting from SpiffyNode...');
      await _spiffyNodeBridge!.shutdown();
      _spiffyNodeBridge = null;
      _peerManager = null;
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
      
      // 4. Close event store only if we own the Isar instance
      if (_ownsIsar) {
        print('Closing LibSpiffy-owned Isar instance');
        await _eventStore.close();
      } else {
        print('Isar instance owned by host application - not closing event store');
        // Note: We cannot close the event stream controller without closing Isar
        // This is acceptable since the host owns the Isar instance and will close it
      }
      
      // 5. Close event broadcaster
      await _walletEventBroadcaster.close();
      
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
/// 
/// P2P Parameters:
/// - [networkType]: 'main' for mainnet, 'test' for testnet (default: 'test')
/// - [enableP2P]: Enable automatic P2P block header synchronization (default: true)
/// - [startHeight]: Optional starting block height for SPV sync
/// - [peerAddresses]: Optional custom peer addresses (format: 'host:port')
/// - [userAgent]: Optional custom user agent string (default: '/LibSpiffy:1.0/')
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
  String networkType = 'test',
  bool enableP2P = true,
  int? startHeight,
  List<String>? peerAddresses,
  String? userAgent,
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
    networkType: networkType,
    enableP2P: enableP2P,
    startHeight: startHeight,
    peerAddresses: peerAddresses,
    userAgent: userAgent,
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

/// Internal message to set ARC actor reference in WalletManager
class SetArcActorMessage implements Message {
  final ActorRef arcActor;
  
  SetArcActorMessage(this.arcActor);

  @override
  String get correlationId => 'set-arc-actor-${DateTime.now().millisecondsSinceEpoch}';
  
  @override
  Map<String, dynamic> get metadata => {};
  
  @override
  ActorRef? get replyTo => null;
  
  @override
  DateTime get timestamp => DateTime.now();
} 