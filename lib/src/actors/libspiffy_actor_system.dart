import 'dart:async';
import 'package:dactor/dactor.dart';
import 'package:eventador/eventador.dart';

import 'package:isar/isar.dart';
import 'package:libspiffy/libspiffy.dart';
import '../core/wallet_commands.dart';
import '../utils/network_name.dart';
import 'package:logging/logging.dart';
import 'package:spiffynode/spiffy_node.dart';

import '../storage/wallet_storage.dart';
import '../storage/in_memory_wallet_storage.dart';
import '../storage/isar_wallet_storage.dart';
import '../storage/isar_config.dart';
import '../storage/secure_storage.dart';
import '../storage/storage_backend.dart';
import '../storage/postgres/postgres_config.dart';
import '../storage/postgres/postgres_wallet_storage.dart';
import '../storage/postgres/postgres_event_store.dart';
import '../storage/postgres/postgres_migrations.dart';
import '../storage/in_memory_secure_storage.dart';
import '../services/crypto_service.dart';
import '../services/dartsv_crypto_service.dart';
import '../services/arc_service_config.dart';
import '../spv/block_header_chain.dart';
import '../spv/network_params.dart';
import '../spv/cdn_header_sync_config.dart';
import '../spv/cdn_header_sync_service.dart';
import '../integration/spiffynode_bridge.dart';
import '../projections/wallet_projection.dart';
import '../projections/invoice_projection.dart';
import '../projections/channel_projection.dart';
import '../core/wallet_events.dart';
import '../core/invoice_events.dart';
import '../core/channel_events.dart';
import 'wallet_manager_actor.dart';
import 'spv_actor.dart';
import 'arc_actor.dart';
import 'header_sync_actor.dart';
import 'invoice_coordinator_actor.dart';
import 'payment_coordinator_actor.dart';
import 'benford_coordinator_actor.dart';
import 'payment_channel_manager_actor.dart';
import 'import_actor.dart';
import 'wallet_coordinator_actor.dart';
import 'coordinator_messages.dart' show CoordinatorEvent;

// The actor wiring messages moved to internal_messages.dart.
export 'internal_messages.dart' show SetInvoiceManagerMessage, SetArcActorMessage;
import '../services/transaction_import_service.dart';

/// Lifecycle of a [LibSpiffyActorSystem] instance.
enum _Lifecycle { uninitialized, initializing, initialized, shutDown }

/// Initialization and management utilities for the LibSpiffy actor system
class LibSpiffyActorSystem {
  late ActorSystem _actorSystem;
  bool _ownsActorSystem = false;
  _Lifecycle _lifecycle = _Lifecycle.uninitialized;
  bool _ownsIsar = false; // Track if we created the Isar instance
  StorageBackend _storageBackend = StorageBackend.isar;
  late EventStore _eventStore;
  late EventStream _eventStream; // Separate reference for LSP compliance
  late ReadModelStorage _walletStorage;
  late ReadModelStorage _actorStorage; // For actors (headers, UTXOs, etc.)
  late SecureStorage _secureStorage;
  late CryptoService _cryptoService;
  late BlockHeaderChain _headerChain;
  ArcServiceConfig? _arcConfig;
  dynamic _arcService;  // ← Mock service for testing (dynamic for test mocks)
  Isar? _isarInstance; // Stored for duraq queue initialization in ARCActor
  
  // Transaction import service
  TransactionImportService? _transactionImportService;
  
  // SpiffyNode integration (optional)
  SpiffyNodeBridge? _spiffyNodeBridge;
  PeerManager? _peerManager;
  
  // CQRS Projections (read-side event handlers)
  //
  // Each projection runs inside a ProjectionActor (eventador 2.1.0+) so
  // coordinators can `ask` the actor to confirm when the read model has
  // applied an event (via AwaitEventApplied). The actor system itself is
  // the registry — there is no separate ProjectionManager.
  WalletProjection? _walletProjection;

  /// Network passed to [initialize]; actors that derive addresses need it.
  String _networkType = 'test';

  /// This node's own channel transport peer id ([initialize]'s
  /// `channelPeerId`, libspiffy-36f).
  String _channelPeerId = '';

  /// This node's own peer id on the payment-channel transport, as given to
  /// [initialize] (or [initializeLibSpiffy]). Empty when none was given.
  String get channelPeerId => _channelPeerId;
  InvoiceProjection? _invoiceProjection;
  ChannelProjection? _channelProjection;
  ActorRef? _walletProjectionRef;
  ActorRef? _invoiceProjectionRef;
  ActorRef? _channelProjectionRef;

  /// Direct reference to the channel ProjectionActor instance (in addition
  /// to the ActorRef above). Needed because subscribing to
  /// [ProjectionActor.appliedEvents] requires the instance — the actor ref
  /// only exposes message-based operations. Used by the channel-event
  /// broadcaster wiring to re-broadcast post-applied events.
  ProjectionActor? _channelProjectionActor;
  StreamSubscription<ChannelEvent>? _channelProjectionAppliedSub;
  
  // Actor references
  ActorRef? _walletManager;
  ActorRef? _invoiceCoordinator;
  ActorRef? _paymentCoordinator;
  ActorRef? _benfordCoordinator;
  ActorRef? _channelManager;
  ActorRef? _spvActor;
  ActorRef? _arcActor;
  ActorRef? _headerSyncActor;
  ActorRef? _importActor;
  ActorRef? _coordinatorActor;
  WalletCoordinatorActor? _coordinatorInstance;

  // Actor instances (kept for configuration after spawn)
  HeaderSyncActor? _headerSyncActorInstance;
  
  // Blockchain data source for imports (optional)
  dynamic _blockchainDataSource;
  
  // Event broadcast for UI subscriptions
  final StreamController<WalletEvent> _walletEventBroadcaster = StreamController<WalletEvent>.broadcast();
  final StreamController<WalletImportNotification> _importNotificationBroadcaster =
      StreamController<WalletImportNotification>.broadcast();
  final StreamController<ChannelEvent> _channelEventBroadcaster = StreamController<ChannelEvent>.broadcast();

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
  /// final isar = await Isar.open([...LibSpiffySchemas.allSchemas, ...hostSchemas]);
  /// 
  /// await libspiffy.initialize(
  ///   actorSystem: hostActorSystem,
  ///   isar: isar,
  ///   networkType: 'test',
  ///   enableP2P: true,
  /// );
  /// ```
  /// 
  /// Example with standalone system (P2P disabled):
  /// ```dart
  /// await libspiffy.initialize(enableP2P: false); // No P2P connectivity
  /// ```
  /// Verifies that a host-supplied [Isar] instance was opened with every
  /// collection LibSpiffy writes to.
  ///
  /// A host that lists collections by hand and forgets one used to get a
  /// system that *looked* healthy: projections replayed from sequence 0 on
  /// every start (eventador < 3.0 swallowed the missing checkpoint
  /// collection) and the ARC broadcast retry queue silently disabled itself
  /// (duraq's missing collection was caught and logged). Since eventador 3.0
  /// a projection whose checkpoint cannot be read enters
  /// `ProjectionStatus.error` and never subscribes, so the read models stop
  /// updating with no exception on the caller's side. Failing here names the
  /// problem and the fix instead.
  static void _checkHostIsarSchemas(Isar isar) {
    final missing = <String>[
      for (final schema in LibSpiffySchemas.allSchemas)
        // ignore: invalid_use_of_protected_member
        if (isar.getCollectionByNameInternal(schema.name) == null) schema.name,
    ];
    if (missing.isEmpty) return;
    throw ArgumentError(
      'The Isar instance passed to LibSpiffyActorSystem.initialize is missing '
      'the collection(s) ${missing.join(', ')}. Open it with '
      '[...LibSpiffySchemas.allSchemas, ...yourOwnSchemas] so the event store, '
      'projection checkpoints and the durable broadcast queue all have their '
      'collections.',
    );
  }

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
    @Deprecated('Ignored: libspiffy never runs storage operations in an '
        'isolate, and nothing has read this since audit 2026-09-14 S-21. '
        'Kept so existing callers still compile; will be removed together '
        'with IsolateConfig.')
    IsolateConfig? isolateConfig,
    String networkType = 'test',
    bool enableP2P = true,
    int? startHeight,
    List<String>? peerAddresses,
    String? userAgent,
    dynamic blockchainDataSource, // For wallet imports (WhatsOnChainDataSource, etc.)
    StorageBackend storageBackend = StorageBackend.isar, // NEW: Storage backend selection
    PostgresConfig? postgresConfig, // NEW: PostgreSQL configuration
    String? cdnBaseUrl, // CDN URL for fast initial header sync
    CdnSyncProgressCallback? onHeaderSyncProgress, // CDN sync progress callback
    // This node's own peer id on the transport that carries payment channel
    // messages (ChannelP2PMessageToSendEvent / ChannelP2PReceived): sent as
    // clientPeerId in channel_request and journaled with the channel
    // (libspiffy-36f). Empty when not given.
    String channelPeerId = '',
  }) async {
    // An instance is initialized once. A second call used to build a second
    // actor system and storage stack over the first (A-M5).
    switch (_lifecycle) {
      case _Lifecycle.initializing:
      case _Lifecycle.initialized:
        throw StateError('LibSpiffyActorSystem is already initialized; '
            'call shutdown() and create a new instance to restart.');
      case _Lifecycle.shutDown:
        throw StateError('LibSpiffyActorSystem has been shut down and cannot '
            'be re-initialized; create a new instance.');
      case _Lifecycle.uninitialized:
        break;
    }
    _lifecycle = _Lifecycle.initializing;
    _channelPeerId = channelPeerId;
    try {
      await _initialize(
        actorSystem: actorSystem,
        dataDirectory: dataDirectory,
        config: config,
        readModelStorage: readModelStorage,
        secureStorage: secureStorage,
        cryptoService: cryptoService,
        arcConfig: arcConfig,
        arcService: arcService,
        isar: isar,
        networkType: networkType,
        enableP2P: enableP2P,
        startHeight: startHeight,
        peerAddresses: peerAddresses,
        userAgent: userAgent,
        blockchainDataSource: blockchainDataSource,
        storageBackend: storageBackend,
        postgresConfig: postgresConfig,
        cdnBaseUrl: cdnBaseUrl,
        onHeaderSyncProgress: onHeaderSyncProgress,
      );
      _lifecycle = _Lifecycle.initialized;
    } catch (_) {
      // A failure after the actors are up (P2P could not connect) leaves a
      // usable API-only system, as before; anything earlier may be retried.
      _lifecycle = isInitialized
          ? _Lifecycle.initialized
          : _Lifecycle.uninitialized;
      rethrow;
    }
  }

  Future<void> _initialize({
    required ActorSystem? actorSystem,
    required String? dataDirectory,
    required ActorSystemConfig? config,
    required ReadModelStorage? readModelStorage,
    required SecureStorage? secureStorage,
    required CryptoService? cryptoService,
    required ArcServiceConfig? arcConfig,
    required dynamic arcService,
    required Isar? isar,
    required String networkType,
    required bool enableP2P,
    required int? startHeight,
    required List<String>? peerAddresses,
    required String? userAgent,
    required dynamic blockchainDataSource,
    required StorageBackend storageBackend,
    required PostgresConfig? postgresConfig,
    required String? cdnBaseUrl,
    required CdnSyncProgressCallback? onHeaderSyncProgress,
  }) async {
    _networkType = networkType;

    // 1. Initialize Dactor system (use provided or create new)
    if (actorSystem != null) {
      _actorSystem = actorSystem;
      _ownsActorSystem = false;
    } else {
      _actorSystem = LocalActorSystem(config ?? ActorSystemConfig());
      _ownsActorSystem = true;
    }
    
    // 2. Store the selected storage backend
    _storageBackend = storageBackend;

    // 3. Initialize storage based on selected backend
    switch (storageBackend) {
      case StorageBackend.postgres:
        if (postgresConfig == null) {
          throw ArgumentError(
            'postgresConfig is required when using StorageBackend.postgres',
          );
        }

        // Run migrations first
        final migrations = PostgresMigrations(postgresConfig);
        await migrations.migrate();

        // Initialize PostgreSQL event store (implements both EventStore AND EventStream)
        final postgresEventStore = PostgresEventStore(postgresConfig);
        await postgresEventStore.initialize();
        _eventStore = postgresEventStore;
        _eventStream = postgresEventStore; // Same instance, LSP-compliant

        // Initialize PostgreSQL wallet storage
        final postgresWalletStorage = PostgresWalletStorage(postgresConfig);
        await postgresWalletStorage.initialize();
        _walletStorage = postgresWalletStorage;
        _actorStorage = postgresWalletStorage;

        _ownsIsar = false; // Not using Isar
        break;

      case StorageBackend.isar:
        // Original Isar initialization logic
        if (isar != null) {
          _checkHostIsarSchemas(isar);
          _isarInstance = isar;
          final isarEventStore = IsarEventStore(isar);
          _eventStore = isarEventStore;
          _eventStream = isarEventStore; // Same instance, LSP-compliant
          _ownsIsar = false;
        } else {
          try { await Isar.initializeIsarCore(download: true); } catch (e) { Logger('LibSpiffyActorSystem').fine('Isar core init skipped (may already be initialized): $e'); }
          final isarEventStore = await IsarEventStore.create(directory: dataDirectory ?? './data');
          _eventStore = isarEventStore;
          _eventStream = isarEventStore; // Same instance, LSP-compliant
          _ownsIsar = true;
        }

        // Initialize read model storage
        if (readModelStorage != null) {
          _walletStorage = readModelStorage;
          if (readModelStorage is WalletStorage) {
            _actorStorage = readModelStorage;
          } else {
            _actorStorage = InMemoryWalletStorage();
          }
        } else if (isar != null) {
          final isarStorage = IsarWalletStorage(isar);
          _walletStorage = isarStorage;
          _actorStorage = isarStorage;
        } else {
          final inMemoryStorage = InMemoryWalletStorage();
          _walletStorage = inMemoryStorage;
          _actorStorage = inMemoryStorage;
        }
        break;

      case StorageBackend.inMemory:
        // Create Isar event store for in-memory mode (events need persistence)
        try { await Isar.initializeIsarCore(download: true); } catch (e) { Logger('LibSpiffyActorSystem').fine('Isar core init skipped (may already be initialized): $e'); }
        final inMemoryEventStore = await IsarEventStore.create(directory: dataDirectory ?? './data');
        _eventStore = inMemoryEventStore;
        _eventStream = inMemoryEventStore; // Same instance, LSP-compliant
        _ownsIsar = true;

        final inMemoryStorage = InMemoryWalletStorage();
        _walletStorage = inMemoryStorage;
        _actorStorage = inMemoryStorage;
        break;
    }
    
    // 4. Initialize secure storage (use provided or default to in-memory)
    if (secureStorage == null && storageBackend != StorageBackend.inMemory) {
      // Events and read models are durable but the keys would live in a
      // Dart Map: after a restart every wallet exists and none can sign.
      Logger('LibSpiffyActorSystem').severe(
        'No secureStorage supplied for the ${storageBackend.name} backend; '
        'falling back to InMemorySecureStorage. Mnemonics, WIFs and xprivs '
        'will be lost on restart and the wallets will be unable to sign. '
        'Pass a persistent SecureStorage in production.',
      );
    }
    _secureStorage = secureStorage ?? InMemorySecureStorage();
    
    // 5. Initialize crypto service (use provided or default to DartSV)
    _cryptoService = cryptoService ?? DartSVCryptoService();
    
    // 6. Store ARC configuration for actors
    // ARCActor used to fall back to TAAL *mainnet* whenever no config was
    // given, even though networkType defaults to 'test'.
    _arcConfig = arcConfig ??
        (NetworkName.isMainnet(networkType)
            ? ArcServiceConfig.taalMainnet()
            : ArcServiceConfig.taalTestnet());
    _arcService = arcService;  // ← Store mock service for testing
    
    // 6.5. Store blockchain data source for imports
    _blockchainDataSource = blockchainDataSource;
    
    // 7. Initialize block header chain for SPV validation
    // IMPORTANT: BlockHeaderChain uses _actorStorage which now points to Isar
    // Anchored to the configured network's genesis; initialize() refuses a
    // header store that is not anchored to it (SPV-02).
    _headerChain = BlockHeaderChain(
      _actorStorage,
      params: NetworkParams.forNetwork(networkType),
    );
    await _headerChain.initialize();

    // 7.1. Start CDN header sync concurrently with actor setup (independent operations)
    Future<void> cdnFuture = Future.value();
    if (cdnBaseUrl != null) {
      final cdnLogger = Logger('LibSpiffy-CDNSync');
      cdnFuture = () async {
        try {
          final cdnConfig = CdnHeaderSyncConfig(
            baseUrl: cdnBaseUrl,
            network: NetworkName.canonical(networkType),
            onProgress: onHeaderSyncProgress,
            cacheDirectory: dataDirectory,
          );
          final cdnSyncService = CdnHeaderSyncService(
            config: cdnConfig,
            headerChain: _headerChain,
          );
          final result = await cdnSyncService.synchronize();
          if (result.success) {
            cdnLogger.info('CDN sync complete: ${result.headersImported} headers, '
                'final height: ${result.finalHeight}, '
                'elapsed: ${result.elapsed.inSeconds}s');
          } else {
            cdnLogger.warning('CDN sync failed (will fall back to P2P): ${result.error}');
          }
        } catch (e) {
          cdnLogger.warning('CDN header sync failed, will fall back to P2P: $e');
        }
      }();
    }

    // 7.5. Register event types for deserialization (BEFORE projections!)
    // Runs concurrently with CDN sync
    await _registerEventTypes();

    // 8. Initialize CQRS projections (read-side event handlers)
    await _initializeProjections();

    // 9. Spawn coordination actors
    await _spawnActors();

    // 10. Wait for CDN sync to finish before P2P (P2P header sync starts from chain tip)
    await cdnFuture;

    // 11. Initialize P2P if enabled (needs actors from step 9)
    if (enableP2P) {
      await _initializeP2P(
        networkType: networkType,
        startHeight: startHeight,
        peerAddresses: peerAddresses,
        userAgent: userAgent,
      );
    }
    
  }
  
  /// Registers every LibSpiffy journal event type (see [registerEventTypes]).
  ///
  /// MUST run before _initializeProjections(): projections deserialize
  /// stored events when they catch up on startup.
  Future<void> _registerEventTypes() async => registerEventTypes();

  /// Register every event type LibSpiffy writes to the event journal with
  /// eventador's [EventRegistry].
  ///
  /// Events are stored under their [Event.typeName], a stable identifier
  /// such as `wallet.utxo.received` that each event class declares as its
  /// `stableTypeName`. It does not depend on the Dart class name, so the
  /// journal keeps loading after a class rename or in an app built with
  /// `--obfuscate` (audit 2026-09-14 M8).
  ///
  /// Journals written by earlier releases stored the class name (for
  /// example `UTXOReceivedEvent`). Each type registers that name as an
  /// alias, so those rows still deserialize. The aliases are string
  /// literals on purpose: they must keep matching what is already on disk.
  ///
  /// Idempotent. [initialize] calls it; call it yourself when reading a
  /// LibSpiffy journal without the actor system (tests, tools, a custom
  /// event store).
  static void registerEventTypes() {
    // WALLET EVENTS (25)
    EventRegistry.register<WalletCreatedEvent>(WalletCreatedEvent.stableTypeName, WalletCreatedEvent.fromMap,
        aliases: const ['WalletCreatedEvent']);
    EventRegistry.register<WalletConfigurationUpdatedEvent>(WalletConfigurationUpdatedEvent.stableTypeName, WalletConfigurationUpdatedEvent.fromMap,
        aliases: const ['WalletConfigurationUpdatedEvent']);
    EventRegistry.register<WalletDeletedEvent>(WalletDeletedEvent.stableTypeName, WalletDeletedEvent.fromMap,
        aliases: const ['WalletDeletedEvent']);
    EventRegistry.register<AddressGeneratedEvent>(AddressGeneratedEvent.stableTypeName, AddressGeneratedEvent.fromMap,
        aliases: const ['AddressGeneratedEvent']);
    EventRegistry.register<AddressLabelUpdatedEvent>(AddressLabelUpdatedEvent.stableTypeName, AddressLabelUpdatedEvent.fromMap,
        aliases: const ['AddressLabelUpdatedEvent']);
    EventRegistry.register<AddressDiscoveredEvent>(AddressDiscoveredEvent.stableTypeName, AddressDiscoveredEvent.fromMap,
        aliases: const ['AddressDiscoveredEvent']);
    // Watch addresses (bead libspiffy-p4kv)
    EventRegistry.register<WatchAddressAddedEvent>(WatchAddressAddedEvent.stableTypeName, WatchAddressAddedEvent.fromMap,
        aliases: const ['WatchAddressAddedEvent']);
    EventRegistry.register<UTXOReceivedEvent>(UTXOReceivedEvent.stableTypeName, UTXOReceivedEvent.fromMap,
        aliases: const ['UTXOReceivedEvent']);
    EventRegistry.register<UTXOMarkedAvailableEvent>(UTXOMarkedAvailableEvent.stableTypeName, UTXOMarkedAvailableEvent.fromMap,
        aliases: const ['UTXOMarkedAvailableEvent']);
    EventRegistry.register<UTXOSpentEvent>(UTXOSpentEvent.stableTypeName, UTXOSpentEvent.fromMap,
        aliases: const ['UTXOSpentEvent']);
    EventRegistry.register<UTXOConfirmationUpdatedEvent>(UTXOConfirmationUpdatedEvent.stableTypeName, UTXOConfirmationUpdatedEvent.fromMap,
        aliases: const ['UTXOConfirmationUpdatedEvent']);
    EventRegistry.register<UTXOReservedEvent>(UTXOReservedEvent.stableTypeName, UTXOReservedEvent.fromMap,
        aliases: const ['UTXOReservedEvent']);
    EventRegistry.register<UTXOReleasedEvent>(UTXOReleasedEvent.stableTypeName, UTXOReleasedEvent.fromMap,
        aliases: const ['UTXOReleasedEvent']);
    EventRegistry.register<UTXOReservationRenewedEvent>(UTXOReservationRenewedEvent.stableTypeName, UTXOReservationRenewedEvent.fromMap,
        aliases: const ['UTXOReservationRenewedEvent']);
    // Replay-only registrations. Nothing emits these three any more (audit
    // 2026-09-14 M3 replaced them with UTXOReservedEvent/UTXOReleasedEvent;
    // reachability sweep 2026-09-18, section 2), but journals written before
    // that change contain them. A journal is permanent, so these
    // registrations must NOT be removed: without them such a journal fails
    // to replay.
    // ignore: deprecated_member_use_from_same_package
    EventRegistry.register<UTXOReservationPlacedEvent>(UTXOReservationPlacedEvent.stableTypeName, UTXOReservationPlacedEvent.fromMap,
        aliases: const ['UTXOReservationPlacedEvent']);
    // ignore: deprecated_member_use_from_same_package
    EventRegistry.register<UTXOReservationReleasedEvent>(UTXOReservationReleasedEvent.stableTypeName, UTXOReservationReleasedEvent.fromMap,
        aliases: const ['UTXOReservationReleasedEvent']);
    // ignore: deprecated_member_use_from_same_package
    EventRegistry.register<UTXOReservationExpiredEvent>(UTXOReservationExpiredEvent.stableTypeName, UTXOReservationExpiredEvent.fromMap,
        aliases: const ['UTXOReservationExpiredEvent']);
    EventRegistry.register<TransactionSignedEvent>(TransactionSignedEvent.stableTypeName, TransactionSignedEvent.fromMap,
        aliases: const ['TransactionSignedEvent']);
    EventRegistry.register<TransactionBroadcastEvent>(TransactionBroadcastEvent.stableTypeName, TransactionBroadcastEvent.fromMap,
        aliases: const ['TransactionBroadcastEvent']);
    EventRegistry.register<TransactionImportedEvent>(TransactionImportedEvent.stableTypeName, TransactionImportedEvent.fromMap,
        aliases: const ['TransactionImportedEvent']);
    EventRegistry.register<TransactionRecordedEvent>(TransactionRecordedEvent.stableTypeName, TransactionRecordedEvent.fromMap,
        aliases: const ['TransactionRecordedEvent']);
    EventRegistry.register<TransactionConfirmedEvent>(TransactionConfirmedEvent.stableTypeName, TransactionConfirmedEvent.fromMap,
        aliases: const ['TransactionConfirmedEvent']);
    EventRegistry.register<TransactionStatusUpdatedEvent>(TransactionStatusUpdatedEvent.stableTypeName, TransactionStatusUpdatedEvent.fromMap,
        aliases: const ['TransactionStatusUpdatedEvent']);
    EventRegistry.register<TransactionConfirmationRevertedEvent>(TransactionConfirmationRevertedEvent.stableTypeName, TransactionConfirmationRevertedEvent.fromMap,
        aliases: const ['TransactionConfirmationRevertedEvent']);
    EventRegistry.register<UTXOSplitInitiatedEvent>(UTXOSplitInitiatedEvent.stableTypeName, UTXOSplitInitiatedEvent.fromMap,
        aliases: const ['UTXOSplitInitiatedEvent']);
    // Replay-only registrations: nothing emits these two any more
    // (reachability sweep 2026-09-18, section 2). Keep them — an older
    // journal contains them and a journal is never rewritten.
    // ignore: deprecated_member_use_from_same_package
    EventRegistry.register<UTXOSplitCompletedEvent>(UTXOSplitCompletedEvent.stableTypeName, UTXOSplitCompletedEvent.fromMap,
        aliases: const ['UTXOSplitCompletedEvent']);
    // ignore: deprecated_member_use_from_same_package
    EventRegistry.register<AllUTXOsSplitCompletedEvent>(AllUTXOsSplitCompletedEvent.stableTypeName, AllUTXOsSplitCompletedEvent.fromMap,
        aliases: const ['AllUTXOsSplitCompletedEvent']);
    // Deferred payments (bead libspiffy-7p2)
    EventRegistry.register<TransactionSpendDeferredEvent>(TransactionSpendDeferredEvent.stableTypeName, TransactionSpendDeferredEvent.fromMap,
        aliases: const ['TransactionSpendDeferredEvent']);
    EventRegistry.register<TransactionNetworkStatusCheckedEvent>(TransactionNetworkStatusCheckedEvent.stableTypeName, TransactionNetworkStatusCheckedEvent.fromMap,
        aliases: const ['TransactionNetworkStatusCheckedEvent']);
    EventRegistry.register<DeferredTransactionFailedEvent>(DeferredTransactionFailedEvent.stableTypeName, DeferredTransactionFailedEvent.fromMap,
        aliases: const ['DeferredTransactionFailedEvent']);
    EventRegistry.register<DeferredTransactionCancelledEvent>(DeferredTransactionCancelledEvent.stableTypeName, DeferredTransactionCancelledEvent.fromMap,
        aliases: const ['DeferredTransactionCancelledEvent']);
    EventRegistry.register<DeferredSpendReclaimedEvent>(DeferredSpendReclaimedEvent.stableTypeName, DeferredSpendReclaimedEvent.fromMap,
        aliases: const ['DeferredSpendReclaimedEvent']);

    // INVOICE EVENTS (5)
    EventRegistry.register<InvoiceCreatedEvent>(InvoiceCreatedEvent.stableTypeName, InvoiceCreatedEvent.fromMap,
        aliases: const ['InvoiceCreatedEvent']);
    // Replay-only registration: nothing emits InvoiceStatusChangedEvent any
    // more (reachability sweep 2026-09-18, section 2). Keep it — an older
    // journal contains it and a journal is never rewritten.
    // ignore: deprecated_member_use_from_same_package
    EventRegistry.register<InvoiceStatusChangedEvent>(InvoiceStatusChangedEvent.stableTypeName, InvoiceStatusChangedEvent.fromMap,
        aliases: const ['InvoiceStatusChangedEvent']);
    EventRegistry.register<InvoicePaidEvent>(InvoicePaidEvent.stableTypeName, InvoicePaidEvent.fromMap,
        aliases: const ['InvoicePaidEvent']);
    EventRegistry.register<InvoiceExpiredEvent>(InvoiceExpiredEvent.stableTypeName, InvoiceExpiredEvent.fromMap,
        aliases: const ['InvoiceExpiredEvent']);
    EventRegistry.register<InvoiceCancelledEvent>(InvoiceCancelledEvent.stableTypeName, InvoiceCancelledEvent.fromMap,
        aliases: const ['InvoiceCancelledEvent']);

    // PAYMENT CHANNEL EVENTS (16)
    EventRegistry.register<ChannelRequestedEvent>(ChannelRequestedEvent.stableTypeName, ChannelRequestedEvent.fromMap,
        aliases: const ['ChannelRequestedEvent']);
    EventRegistry.register<ChannelAcceptedEvent>(ChannelAcceptedEvent.stableTypeName, ChannelAcceptedEvent.fromMap,
        aliases: const ['ChannelAcceptedEvent']);
    EventRegistry.register<ChannelRejectedEvent>(ChannelRejectedEvent.stableTypeName, ChannelRejectedEvent.fromMap,
        aliases: const ['ChannelRejectedEvent']);
    EventRegistry.register<ServerAcceptanceRecordedEvent>(ServerAcceptanceRecordedEvent.stableTypeName, ServerAcceptanceRecordedEvent.fromMap,
        aliases: const ['ServerAcceptanceRecordedEvent']);
    EventRegistry.register<RefundBuiltEvent>(RefundBuiltEvent.stableTypeName, RefundBuiltEvent.fromMap,
        aliases: const ['RefundBuiltEvent']);
    EventRegistry.register<RefundCountersignedEvent>(RefundCountersignedEvent.stableTypeName, RefundCountersignedEvent.fromMap,
        aliases: const ['RefundCountersignedEvent']);
    EventRegistry.register<FundingBroadcastStartedEvent>(FundingBroadcastStartedEvent.stableTypeName, FundingBroadcastStartedEvent.fromMap,
        aliases: const ['FundingBroadcastStartedEvent']);
    EventRegistry.register<FundingBroadcastFailedEvent>(FundingBroadcastFailedEvent.stableTypeName, FundingBroadcastFailedEvent.fromMap,
        aliases: const ['FundingBroadcastFailedEvent']);
    EventRegistry.register<FundingRecordedInWalletEvent>(FundingRecordedInWalletEvent.stableTypeName, FundingRecordedInWalletEvent.fromMap,
        aliases: const ['FundingRecordedInWalletEvent']);
    EventRegistry.register<ChannelOpenedEvent>(ChannelOpenedEvent.stableTypeName, ChannelOpenedEvent.fromMap,
        aliases: const ['ChannelOpenedEvent']);
    EventRegistry.register<PaymentRecordedEvent>(PaymentRecordedEvent.stableTypeName, PaymentRecordedEvent.fromMap,
        aliases: const ['PaymentRecordedEvent']);
    EventRegistry.register<PaymentAcknowledgedEvent>(PaymentAcknowledgedEvent.stableTypeName, PaymentAcknowledgedEvent.fromMap,
        aliases: const ['PaymentAcknowledgedEvent']);
    EventRegistry.register<PaymentCountersignedEvent>(PaymentCountersignedEvent.stableTypeName, PaymentCountersignedEvent.fromMap,
        aliases: const ['PaymentCountersignedEvent']);
    EventRegistry.register<ReturnLegRecordedInWalletEvent>(ReturnLegRecordedInWalletEvent.stableTypeName, ReturnLegRecordedInWalletEvent.fromMap,
        aliases: const ['ReturnLegRecordedInWalletEvent']);
    EventRegistry.register<ChannelClosingEvent>(ChannelClosingEvent.stableTypeName, ChannelClosingEvent.fromMap,
        aliases: const ['ChannelClosingEvent']);
    EventRegistry.register<ChannelClosedEvent>(ChannelClosedEvent.stableTypeName, ChannelClosedEvent.fromMap,
        aliases: const ['ChannelClosedEvent']);
    EventRegistry.register<RefundClaimedEvent>(RefundClaimedEvent.stableTypeName, RefundClaimedEvent.fromMap,
        aliases: const ['RefundClaimedEvent']);
    EventRegistry.register<ChannelExpiredEvent>(ChannelExpiredEvent.stableTypeName, ChannelExpiredEvent.fromMap,
        aliases: const ['ChannelExpiredEvent']);
  }

  /// Initialize CQRS projections for read-side persistence
  /// 
  /// Projections listen to events from the EventStore and build denormalized
  /// read models in Isar for efficient queries. This separates write concerns
  /// (aggregates) from read concerns (queries).
  Future<void> _initializeProjections() async {

    // Get Isar instance for checkpoint persistence (if using IsarWalletStorage)
    final Isar? isar = _walletStorage is IsarWalletStorage
        ? (_walletStorage as IsarWalletStorage).isar
        : null;

    // Each projection runs inside a ProjectionActor. Spawning IS the
    // registration (Pekko-style); there is no ProjectionManager. The actor
    // owns the event-stream subscription and serves AwaitEventApplied queries
    // so coordinators can wait for the read model to reflect a command's
    // outcome before returning.

    _walletProjection = WalletProjection(
      projectionId: 'wallet-projection',
      eventStore: _eventStore,
      storage: _walletStorage,
    );
    _walletProjectionRef = await _actorSystem.spawn(
      'projection-wallet-projection',
      () => ProjectionActor(_walletProjection!, _eventStream, isar: isar),
    );

    _invoiceProjection = InvoiceProjection(
      projectionId: 'invoice-projection',
      eventStore: _eventStore,
      storage: _walletStorage,
    );
    _invoiceProjectionRef = await _actorSystem.spawn(
      'projection-invoice-projection',
      () => ProjectionActor(_invoiceProjection!, _eventStream, isar: isar),
    );

    _channelProjection = ChannelProjection(
      projectionId: 'channel-projection',
      eventStore: _eventStore,
      storage: _walletStorage,
    );
    _channelProjectionRef = await _actorSystem.spawn(
      'projection-channel-projection',
      () {
        _channelProjectionActor =
            ProjectionActor(_channelProjection!, _eventStream, isar: isar);
        return _channelProjectionActor!;
      },
    );

    // Re-broadcast the channel projection's applied-events stream as the
    // sole source of truth for channel-event consumers (ChannelP2PAdapter
    // and external listeners via the `channelEvents` getter). This closes
    // the projection-race issue (overnode_v2-8gh): consumers that fire on
    // these events were previously racing the projection's async Isar
    // write because the broadcaster was fed directly from
    // PaymentChannelManagerActor's `_eventBroadcaster` callback. Now the
    // events are only re-broadcast AFTER `ChannelProjection.handle()`
    // completes, so any downstream read of `paymentChannelEntitys` is
    // guaranteed to see the row.
    _channelProjectionAppliedSub = _channelProjectionActor!.appliedEvents
        .where((e) => e is ChannelEvent)
        .cast<ChannelEvent>()
        .listen((event) {
      if (!_channelEventBroadcaster.isClosed) {
        _channelEventBroadcaster.add(event);
      }
    });
  }

  /// Spawn all coordination actors
  Future<void> _spawnActors() async {
    
    // Spawn WalletManagerActor first
    _walletManager = await _actorSystem.spawn('wallet-manager', () => WalletManagerActor(
      eventStore: _eventStore,
      cryptoService: _cryptoService,
      secureStorage: _secureStorage,
      readModelStorage: _walletStorage,
    ));
    
    // Spawn InvoiceCoordinatorActor (needed for invoice-based payments).
    // Coordinator routes commands to InvoiceAggregate instances and uses
    // _invoiceProjectionRef to await projection apply before responding,
    // so callers querying via CheckInvoiceMessage immediately after see the
    // updated read model (closes overnode_v2-dmx).
    _invoiceCoordinator = await _actorSystem.spawn('invoice-coordinator', () => InvoiceCoordinatorActor(
      walletManager: _walletManager!,
      storage: _walletStorage,
      eventStore: _eventStore,
      invoiceProjection: _invoiceProjectionRef!,
    ));
    
    // Wire up InvoiceCoordinator reference in WalletManager
    // We'll send a message to set the reference
    _walletManager!.tell(SetInvoiceManagerMessage(_invoiceCoordinator!));
    
    // Spawn PaymentCoordinatorActor for BEEF-based payments
    _paymentCoordinator = await _actorSystem.spawn('payment-coordinator', () => PaymentCoordinatorActor(
      walletManager: _walletManager!,
      walletProjection: _walletProjectionRef!,
      storage: _walletStorage,
    ));


    // Spawn SPVActor with reference to WalletManager, InvoiceCoordinator and storage
    _spvActor = await _actorSystem.spawn('spv-actor', () => SPVActor(
      walletManager: _walletManager!,
      invoiceCoordinator: _invoiceCoordinator!,
      storage: _actorStorage,
      networkType: _networkType,
    ));

    // Spawn HeaderSyncActor early (other actors may need to communicate with it)
    _headerSyncActorInstance = HeaderSyncActor(
      headerChain: _headerChain,
      spvActor: _spvActor,
      spiffyNodeBridge: null, // Will be set after SpiffyNode connection
      peerManager: null, // Will be set after P2P initialization
      startHeight: null, // Will be set via _initializeP2P parameter
    );
    _headerSyncActor = await _actorSystem.spawn('header-sync', () => _headerSyncActorInstance!);
    

    // Now launch update HeaderSyncActor . Missing references will be wired up after P2P init completes.
    // Note: This is a limitation of the current design - we need a way to update references
    
    // Spawn ARCActor with reference to WalletManager and ARC config
    _arcActor = await _actorSystem.spawn('arc-actor', () => ARCActor(
      walletManager: _walletManager!,
      storage: _walletStorage,
      arcConfig: _arcConfig,
      arcService: _arcService,  // ← Pass mock service for testing
      isar: _isarInstance,  // For duraq broadcast retry queue
      // Explicit fallback for deferred payment checks and broadcasts.
      dataSource: _blockchainDataSource is BlockchainDataSource
          ? _blockchainDataSource as BlockchainDataSource
          : null,
    ));
    
    // Wire up ARC actor reference in WalletManager
    _walletManager!.tell(SetArcActorMessage(_arcActor!));
    
    // Wire up ARC actor reference in SPVActor for pending UTXO checking
    // This enables SPVActor to trigger Arc status checks when new block headers arrive
    _spvActor!.tell(SetArcActorForSPVMessage(_arcActor!));
    
    // Wire up HeaderSync actor reference in SPVActor for opportunistic header fetching
    // This enables SPVActor to fetch missing block headers from P2P network during BEEF validation
    _spvActor!.tell(SetHeaderSyncActorMessage(_headerSyncActor!));
    
    // Spawn Benford coordinator for privacy-focused UTXO splitting
    _benfordCoordinator = await _actorSystem.spawn('benford-coordinator', () => BenfordCoordinatorActor(
      walletManager: _walletManager!,
      arcActor: _arcActor!,
      storage: _walletStorage,
    ));
    
    // Wire up Benford coordinator reference in WalletManager
    _walletManager!.tell(SetBenfordCoordinatorMessage(_benfordCoordinator!));
    
    // Spawn PaymentChannelManagerActor for payment channel operations.
    //
    // Note: `eventBroadcaster` is intentionally NOT supplied. The channel-event
    // broadcaster is now fed exclusively by the channel projection's
    // `appliedEvents` stream (see _channelProjectionAppliedSub above), so
    // downstream consumers see events only after the projection's Isar write
    // has completed. Wiring PCMA's pre-projection callback in here would
    // double-emit and re-introduce the projection-race window.
    _channelManager =
        await _actorSystem.spawn('payment-channel-manager', () => PaymentChannelManagerActor(
      walletManager: _walletManager!,
      eventStore: _eventStore,
      cryptoService: _cryptoService,
      channelProjection: _channelProjectionRef!,
      // Funding broadcast and wallet bookkeeping (libspiffy-9f7).
      arcActor: _arcActor!,
      walletProjection: _walletProjectionRef!,
      // Funding BEEF: built from the read model (client), SPV-validated
      // (server) (libspiffy-fsy).
      spvActor: _spvActor!,
      storage: _walletStorage,
    ));
    
    // Spawn ImportActor if blockchain data source is provided
    if (_blockchainDataSource != null) {
      _importActor = await _actorSystem.spawn('import-actor', () => ImportActor(
        dataSource: _blockchainDataSource,
        storage: _walletStorage,
        walletManagerActor: _walletManager!,
        walletProjection: _walletProjectionRef,
        eventBroadcaster: broadcastImportNotification,
      ));
      
      // Initialize transaction import service
      _transactionImportService = TransactionImportService(
        dataSource: _blockchainDataSource,
        headerAtHeight: _walletStorage.getBlockHeaderByHeight,
      );
      
    }


    // Spawn WalletCoordinatorActor as the unified public interface
    _coordinatorInstance = WalletCoordinatorActor(
      walletManager: _walletManager!,
      invoiceCoordinator: _invoiceCoordinator!,
      paymentCoordinator: _paymentCoordinator!,
      spvActor: _spvActor!,
      arcActor: _arcActor!,
      headerSyncActor: _headerSyncActor!,
      benfordCoordinator: _benfordCoordinator!,
      channelManager: _channelManager!,
      walletProjection: _walletProjectionRef!,
      importActor: _importActor,
      storage: _walletStorage,
      channelEvents: _channelEventBroadcaster.stream,
      // This node's own peer id on the channel transport (libspiffy-36f).
      peerId: _channelPeerId,
      broadcastWalletEvent: broadcastWalletEvent,
      importWalletFromXpriv: _importActor != null ? ({
        required String walletId,
        required String xpriv,
        required String walletName,
        String networkType = 'test',
        int addressGapLimit = 20,
      }) {
        importWalletFromXpriv(
          walletId: walletId,
          xpriv: xpriv,
          walletName: walletName,
          networkType: networkType,
          addressGapLimit: addressGapLimit,
        );
      } : null,
      importWalletFromWif: _importActor != null ? ({
        required String walletId,
        required String wif,
        required String walletName,
        String networkType = 'test',
      }) {
        importWalletFromWif(
          walletId: walletId,
          wif: wif,
          walletName: walletName,
          networkType: networkType,
        );
      } : null,
      importNotifications: _importNotificationBroadcaster.stream,
    );
    _coordinatorActor = await _actorSystem.spawn('wallet-coordinator', () => _coordinatorInstance!);

    // Preload all wallet aggregates to eliminate race conditions
    await _preloadWalletAggregates();
  }

  /// Preload all wallet aggregates so commands don't need to wait for loading
  /// 
  /// This eliminates race conditions that can occur when multiple commands
  /// arrive for a wallet before it finishes loading.
  Future<void> _preloadWalletAggregates() async {
    try {
      
      // Query all wallet IDs from storage
      final walletIds = await _walletStorage.listWallets();
      
      if (walletIds.isEmpty) {
        return;
      }
      
      
      // Send PreloadWalletCommand for each wallet. The manager's mailbox is
      // FIFO, so a command sent after initialize() returns is handled after
      // the preloads whether or not they have finished.
      for (final walletId in walletIds.take(walletIds.length - 1)) {
        _walletManager!.tell(WalletCommandMessage(
          walletId,
          PreloadWalletCommand(walletId: walletId),
        ));
      }
      final lastWalletId = walletIds.last;

      // Give the preloads up to 100 ms, as before, but return as soon as the
      // manager has handled them (bead libspiffy-a5l): it answers the last
      // preload after the earlier ones. The ask's own timeout is well past
      // the cap, so an AskConfig with retries does not re-send the preload
      // while initialize() waits; a reply after the cap is ignored.
      final preloaded = _walletManager!.ask<WalletPreloadedResponse>(
        WalletCommandMessage(
          lastWalletId,
          PreloadWalletCommand(walletId: lastWalletId),
        ),
        const Duration(seconds: 30),
      );
      try {
        await preloaded.timeout(const Duration(milliseconds: 100));
      } on TimeoutException {
        // Still loading: commands queue behind the preloads.
      }

    } catch (e, stackTrace) {
      // Non-fatal - wallets will load on-demand if preload fails
      Logger('LibSpiffyActorSystem')
          .warning('Wallet aggregate preload failed: $e', e, stackTrace);
    }
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
    
    try {
      // 1. Initialize SpiffyNode message types
      initializeMessages();
      
      // 2. Map network type to BitcoinNetwork enum
      final network = NetworkName.isMainnet(networkType)
          ? BitcoinNetwork.mainnet
          : NetworkName.isRegtest(networkType)
              ? BitcoinNetwork.regtest
              : BitcoinNetwork.testnet;
      print('[LibSpiffy] P2P network: $networkType → ${network.name} (magic: 0x${network.magic.toRadixString(16)})');

      // 3. Create PeerManager
      _peerManager = PeerManager(
        network: network,
        logger: Logger('LibSpiffy-SpiffyNode'),
      );
      
      // 4. Create and initialize SpiffyNodeBridge (before adding peers)
      _spiffyNodeBridge = SpiffyNodeBridge(
        peerManager: _peerManager!,
        headerSyncActor: _headerSyncActor!,
      );
      
      await _spiffyNodeBridge!.initialize();
      
      // 5. Create LibSpiffyPeerHandler with BlockHeaderChain and HeaderSyncActor references
      // Handler will query actual bestHeight dynamically for each batch
      // and trigger header sync when new blocks are announced
      final peerHandler = LibSpiffyPeerHandler(
        bridge: _spiffyNodeBridge!,
        headerChain: _headerChain, // Pass BlockHeaderChain for dynamic height queries
        headerSyncActor: _headerSyncActor, // Pass HeaderSyncActor for triggering sync on block announcements
      );
      
      // 6. Get peer addresses (use provided or defaults)
      final peers = peerAddresses ?? _getDefaultPeers(networkType);
      
      // 7. Connect to peers IN PARALLEL with handler to capture headers
      // Try ALL peers concurrently, only fail if ALL are unreachable

      final failures = <String, String>{}; // peer -> error

      final peerConfig = startHeight != null
          ? PeerConfig(
              startHeight: startHeight,
              userAgent: userAgent ?? '/LibSpiffy:1.0/',
            )
          : PeerConfig(
              userAgent: userAgent ?? '/LibSpiffy:1.0/',
            );

      final connectionFutures = peers.map((peerAddr) async {
        final parts = peerAddr.split(':');
        if (parts.length != 2) {
          failures[peerAddr] = 'Invalid format (expected host:port)';
          return false;
        }

        final host = parts[0];
        final port = int.tryParse(parts[1]);
        if (port == null) {
          failures[peerAddr] = 'Invalid port number';
          return false;
        }

        try {
          await _peerManager!.addPeerByAddress(
            host,
            port,
            peerConfig: peerConfig,
            handler: peerHandler,
          );
          return true;
        } catch (e) {
          failures[peerAddr] = e.toString();
          return false;
        }
      }).toList();

      final results = await Future.wait(connectionFutures);
      final successCount = results.where((r) => r).length;
      
      // Check if we connected to at least one peer
      if (successCount == 0) {
        failures.forEach((peer, error) {
        });
        throw StateError(
          'P2P initialization failed: Could not connect to any of ${peers.length} peer(s). '
          'LibSpiffy will fall back to API-only mode. Failures: ${failures.keys.join(", ")}'
        );
      }
      
      // Log summary
      if (failures.isNotEmpty) {
        failures.forEach((peer, error) {
        });
      }
      
      // 8. Set bridge reference in HeaderSyncActor (via mailbox)
      _headerSyncActor?.tell(SetSpiffyNodeBridgeMessage(_spiffyNodeBridge));

      // 9. Set PeerManager and trigger initial header sync (via mailbox)
      _headerSyncActor?.tell(SetPeerManagerMessage(_peerManager));
      _headerSyncActor?.tell(InitiateHeaderSyncMessage(startHeight: startHeight));
      
      
    } catch (e) {
      // The PeerManager runs a health-check timer and may hold peer sockets;
      // dropping the reference without shutting it down leaked both (A-M5).
      await disconnectFromSpiffyNode();
      rethrow;
    }
  }
  
  /// Get default seed nodes for the specified network
  List<String> _getDefaultPeers(String networkType) {
    if (NetworkName.isMainnet(networkType)) return ['seed.bitcoinsv.io:8333'];
    if (NetworkName.isRegtest(networkType)) return []; // No default seeds for regtest
    return ['testnet-seed.bitcoinsv.io:18333'];
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

  /// Get reference to the event store
  /// 
  /// The EventStore is used for event sourcing and CQRS. Aggregates persist
  /// their events to this store, and projections consume events from it.
  EventStore get eventStore {
    if (!isInitialized) {
      throw StateError('LibSpiffy actor system not initialized');
    }
    return _eventStore;
  }

  /// Get reference to the PaymentChannelManager actor
  /// 
  /// The PaymentChannelManagerActor orchestrates payment channel operations,
  /// coordinating between WalletManager for cryptographic operations and
  /// PaymentChannelAggregate for domain logic.
  ActorRef get channelManager {
    if (!isInitialized) {
      throw StateError('LibSpiffy actor system not initialized');
    }
    if (_channelManager == null) {
      throw StateError('PaymentChannelManagerActor not spawned');
    }
    return _channelManager!;
  }

  /// Get stream of channel events for external subscribers
  /// 
  /// External components (like P2P adapters) can subscribe to this stream
  /// to receive payment channel events for protocol message translation.
  Stream<WalletEvent> get walletEvents => _walletEventBroadcaster.stream;

  Stream<ChannelEvent> get channelEvents => _channelEventBroadcaster.stream;

  /// Broadcast a channel event to external subscribers.
  ///
  /// Deprecated: the channel-event broadcaster is now fed exclusively by the
  /// channel projection's `appliedEvents` stream (see the `_channelProjectionAppliedSub`
  /// wiring in `_initializeProjections`). Calling this method out-of-band
  /// would re-introduce the projection-race window (overnode_v2-8gh) by
  /// surfacing channel events to consumers before the read model has been
  /// updated. Retained for binary compatibility with external callers; should
  /// not be invoked by libspiffy internals.
  @Deprecated('Channel events are now broadcast post-projection-apply. '
      'Do not call this directly from internal code.')
  void broadcastChannelEvent(ChannelEvent event) {
    _channelEventBroadcaster.add(event);
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

  /// THE canonical interface for third-party apps.
  ///
  /// Send coordinator commands to this actor:
  /// ```dart
  /// libspiffy.coordinator.tell(CreateWalletCommand(...));
  /// ```
  ActorRef get coordinator {
    if (_coordinatorActor == null) {
      throw StateError('LibSpiffy actor system not initialized');
    }
    return _coordinatorActor!;
  }

  /// Event stream from the coordinator. Subscribe for async results.
  ///
  /// ```dart
  /// libspiffy.coordinatorEvents.listen((event) {
  ///   if (event is WalletCreatedEvent) { ... }
  /// });
  /// ```
  Stream<CoordinatorEvent>? get coordinatorEvents =>
      _coordinatorInstance?.events;

  /// Reference to the wallet projection actor (CQRS read-side).
  ///
  /// Coordinators can `ask` this actor `AwaitEventApplied(predicate, timeout)`
  /// to be notified once the projection has applied a matching event — the
  /// canonical command-to-read-model bridge.
  ActorRef? get walletProjectionRef => _walletProjectionRef;

  /// Reference to the invoice projection actor (CQRS read-side).
  ActorRef? get invoiceProjectionRef => _invoiceProjectionRef;

  /// Reference to the channel projection actor (CQRS read-side).
  ActorRef? get channelProjectionRef => _channelProjectionRef;

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

  /// The ARC configuration resolved by [initialize] (explicit [arcConfig],
  /// otherwise the TAAL endpoint for [networkType]).
  ArcServiceConfig? get arcConfig => _arcConfig;

  /// Broadcast a wallet event to UI subscribers
  /// 
  /// Internal method used by actors to notify the UI of events
  void broadcastWalletEvent(WalletEvent event) {
    if (_walletEventBroadcaster.isClosed) return;
    _walletEventBroadcaster.add(event);
  }
  
  /// Subscribe to wallet events for a specific wallet
  ///
  /// Returns the events passed to [broadcastWalletEvent] for [walletId].
  /// Wallet import progress is not delivered here: it is a
  /// [WalletImportNotification], see [subscribeToImportNotifications].
  Stream<WalletEvent> subscribeToWalletEvents(String walletId) {
    if (!isInitialized) {
      throw StateError('LibSpiffy actor system not initialized');
    }

    // Return filtered broadcast stream
    return _walletEventBroadcaster.stream.where((event) => event.walletId == walletId);
  }

  /// Broadcast an import notification to [importNotifications] subscribers.
  ///
  /// Used by the ImportActor; notifications are in-process only and never
  /// journaled (audit 2026-09-14 L4).
  void broadcastImportNotification(WalletImportNotification notification) {
    if (_importNotificationBroadcaster.isClosed) return;
    _importNotificationBroadcaster.add(notification);
  }

  /// Progress, completion and failure notifications of every wallet import.
  Stream<WalletImportNotification> get importNotifications =>
      _importNotificationBroadcaster.stream;

  /// Import notifications for [walletId]: [WalletImportStartedEvent],
  /// [WalletImportProgressEvent], [WalletImportCompletedEvent],
  /// [WalletImportFailedEvent] and the per-UTXO / per-transaction
  /// confirmations. Use this to follow [importWalletFromXpriv] and
  /// [importWalletFromWif].
  Stream<WalletImportNotification> subscribeToImportNotifications(String walletId) {
    if (!isInitialized) {
      throw StateError('LibSpiffy actor system not initialized');
    }
    return _importNotificationBroadcaster.stream
        .where((notification) => notification.walletId == walletId);
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
  /// with [subscribeToImportNotifications].
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
  /// with [subscribeToImportNotifications].
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

  /// Disconnect from SpiffyNode: shut down the bridge and the PeerManager
  /// (its peer connections and health-check timer).
  Future<void> disconnectFromSpiffyNode() async {
    final bridge = _spiffyNodeBridge;
    final peerManager = _peerManager;
    _spiffyNodeBridge = null;
    _peerManager = null;
    try {
      await bridge?.shutdown();
    } catch (e) {
      Logger('LibSpiffyActorSystem').warning('SpiffyNode bridge shutdown failed: $e');
    }
    try {
      await peerManager?.shutdown();
    } catch (e) {
      Logger('LibSpiffyActorSystem').warning('PeerManager shutdown failed: $e');
    }
  }

  /// Shutdown the LibSpiffy actor system
  ///
  /// This will:
  /// - Disconnect from SpiffyNode if connected
  /// - Stop projection actors (flushes their checkpoints, cancels subscriptions)
  /// - Close the event store
  /// - Shutdown the actor system ONLY if LibSpiffy created it (not provided by host)
  ///
  /// If the host application provided its own actor system, it remains
  /// the host's responsibility to shut it down.
  /// How long shutdown waits for ARCActor's work in flight: an ARC request
  /// times out well within it.
  static const Duration _arcStopTimeout = Duration(seconds: 60);

  Future<void> shutdown() async {
    if (_lifecycle == _Lifecycle.shutDown) return;
    final wasStarted = _lifecycle != _Lifecycle.uninitialized;
    _lifecycle = _Lifecycle.shutDown;
    if (!wasStarted) {
      await _walletEventBroadcaster.close();
      await _importNotificationBroadcaster.close();
      await _channelEventBroadcaster.close();
      return;
    }

    try {
      // 1. Disconnect from SpiffyNode first
      await disconnectFromSpiffyNode();

      // 2. Stop projection actors via the canonical StopProjection protocol.
      //    Each actor cancels its event-stream subscription, flushes any
      //    pending checkpoint, replies with StoppedAck, and then terminates
      //    itself. Done in parallel since the three projections are
      //    independent.
      final stopFutures = <Future<StoppedAck>>[];
      for (final ref in [
        _walletProjectionRef,
        _invoiceProjectionRef,
        _channelProjectionRef,
      ]) {
        if (ref != null) {
          stopFutures.add(
            ref.ask<StoppedAck>(StopProjection(), const Duration(seconds: 5)),
          );
        }
      }
      if (stopFutures.isNotEmpty) {
        try {
          await Future.wait(stopFutures);
        } catch (e) {
          // Best-effort: a projection that fails to ack within the timeout
          // shouldn't block the rest of shutdown. The actor's postStop is
          // a safety net for checkpoint flushing.
          Logger('LibSpiffyActorSystem')
              .warning('Projection shutdown ack failed: $e');
        }
      }
      
      // 3. Let ARCActor finish what it has in flight (bead libspiffy-vr89):
      //    a submission that fails queues its retry in Isar, and the host
      //    closes Isar after this returns. Before this step a write could
      //    land in a closed store and crash the process.
      final arc = _arcActor;
      if (arc != null) {
        try {
          await arc.ask<ArcWorkStoppedMessage>(StopArcWorkMessage(), _arcStopTimeout);
        } catch (e) {
          Logger('LibSpiffyActorSystem').warning('ARCActor did not stop its work in time: $e');
        }
      }

      // 4. Shutdown actor system only if we own it. In a host-owned system,
      //    stop every actor libspiffy spawned instead (A-M5), public facade
      //    first; the managers' postStop stops the aggregates they spawned.
      if (_ownsActorSystem) {
        await _actorSystem.shutdown();
      } else {
        for (final ref in [
          _coordinatorActor,
          _importActor,
          _channelManager,
          _benfordCoordinator,
          _arcActor,
          _headerSyncActor,
          _spvActor,
          _paymentCoordinator,
          _invoiceCoordinator,
          _walletManager,
          // Normally already stopped by StopProjection above.
          _walletProjectionRef,
          _invoiceProjectionRef,
          _channelProjectionRef,
        ]) {
          if (ref == null || _actorSystem.getActor(ref.id) == null) continue;
          try {
            await _actorSystem.stop(ref);
          } catch (e) {
            Logger('LibSpiffyActorSystem')
                .warning('Failed to stop actor ${ref.id}: $e');
          }
        }
      }
      
      // 5. Close storage based on backend type
      switch (_storageBackend) {
        case StorageBackend.postgres:
          // Close event store (includes connection pool)
          await _eventStore.close();
          // Close wallet storage if it has a close method
          if (_walletStorage is PostgresWalletStorage) {
            await (_walletStorage as PostgresWalletStorage).close();
          }
          break;

        case StorageBackend.isar:
        case StorageBackend.inMemory:
          if (_ownsIsar) {
            await _eventStore.close();
          } else {
          }
          break;
      }
      
      // 6. Close event broadcasters and projection re-broadcast subscription
      await _channelProjectionAppliedSub?.cancel();
      _channelProjectionAppliedSub = null;
      await _walletEventBroadcaster.close();
      await _importNotificationBroadcaster.close();
      await _channelEventBroadcaster.close();

    } finally {
      _clearActorRefs();
    }
  }

  /// Drops every actor reference, so [isInitialized] is false and the
  /// accessors throw after shutdown.
  void _clearActorRefs() {
    _walletManager = null;
    _invoiceCoordinator = null;
    _paymentCoordinator = null;
    _benfordCoordinator = null;
    _channelManager = null;
    _spvActor = null;
    _arcActor = null;
    _headerSyncActor = null;
    _importActor = null;
    _coordinatorActor = null;
    _coordinatorInstance = null;
    _headerSyncActorInstance = null;
    _walletProjectionRef = null;
    _invoiceProjectionRef = null;
    _channelProjectionRef = null;
    _channelProjectionActor = null;
  }

  /// Check if the system is initialized (false again after [shutdown])
  bool get isInitialized => _lifecycle != _Lifecycle.shutDown && _walletManager != null && _invoiceCoordinator != null && _spvActor != null && _arcActor != null && _headerSyncActor != null;
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
/// opening the Isar instance using LibSpiffySchemas.allSchemas.
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
  @Deprecated('Ignored: libspiffy never runs storage operations in an '
      'isolate, and nothing has read this since audit 2026-09-14 S-21. Kept '
      'so existing callers still compile; will be removed together with '
      'IsolateConfig.')
  IsolateConfig? isolateConfig,
  String networkType = 'test',
  bool enableP2P = true,
  int? startHeight,
  List<String>? peerAddresses,
  String? userAgent,
  // This node's own peer id on the channel transport (libspiffy-36f). It was
  // not forwarded before (bead libspiffy-kp1): a host booting through this
  // free function got an empty channel peer id and its channels could not
  // address it.
  String channelPeerId = '',
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
    networkType: networkType,
    enableP2P: enableP2P,
    startHeight: startHeight,
    peerAddresses: peerAddresses,
    userAgent: userAgent,
    channelPeerId: channelPeerId,
  );
}

/// Shutdown the global LibSpiffy actor system instance
Future<void> shutdownLibSpiffy() async {
  if (_globalInstance != null) {
    await _globalInstance!.shutdown();
    _globalInstance = null;
  }
}
