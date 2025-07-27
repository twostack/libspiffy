import 'dart:async';
import 'package:dactor/dactor.dart';
import 'package:eventador/eventador.dart';
import 'package:isar/isar.dart';

import '../storage/wallet_storage.dart';
import '../storage/in_memory_wallet_storage.dart';
import '../spv/block_header_chain.dart';
import '../integration/spiffynode_bridge.dart';
import 'wallet_manager_actor.dart';
import 'spv_actor.dart';
import 'arc_actor.dart';
import 'header_sync_actor.dart';

/// Initialization and management utilities for the LibSpiffy actor system
class LibSpiffyActorSystem {
  late LocalActorSystem _actorSystem;
  late IsarEventStore _eventStore;
  late WalletStorage _walletStorage;
  late BlockHeaderChain _headerChain;
  
  // SpiffyNode integration (optional)
  SpiffyNodeBridge? _spiffyNodeBridge;
  
  // Actor references
  ActorRef? _walletManager;
  ActorRef? _spvActor;
  ActorRef? _arcActor;
  ActorRef? _headerSyncActor;

  /// Initialize the LibSpiffy actor system
  Future<void> initialize({
    String? dataDirectory,
    ActorSystemConfig? config,
    WalletStorage? walletStorage,
  }) async {
    print('Initializing LibSpiffy Actor System...');
    
    // 1. Initialize Dactor system
    _actorSystem = LocalActorSystem(config ?? ActorSystemConfig());
    
    // 2. Initialize Eventador storage  
    await Isar.initializeIsarCore(download: true);
    _eventStore = await IsarEventStore.create(directory: dataDirectory ?? './data');
    
    // 3. Initialize wallet storage (use provided or default to in-memory)
    _walletStorage = walletStorage ?? InMemoryWalletStorage();
    
    // 4. Initialize block header chain for SPV validation
    _headerChain = BlockHeaderChain(_walletStorage);
    await _headerChain.initialize();
    
    // 5. Spawn coordination actors
    await _spawnActors();
    
    print('LibSpiffy Actor System initialized successfully');
  }

  /// Spawn all coordination actors
  Future<void> _spawnActors() async {
    print('Spawning LibSpiffy actors...');
    
    // Spawn WalletManagerActor first
    _walletManager = await _actorSystem.spawn('wallet-manager', () => WalletManagerActor(
      eventStore: _eventStore,
    ));
    
    // Spawn HeaderSyncActor early (other actors may need to communicate with it)
    _headerSyncActor = await _actorSystem.spawn('header-sync', () => HeaderSyncActor(
      headerChain: _headerChain,
      spvActor: null, // Will be set after SPVActor is spawned
    ));
    
    // Spawn SPVActor with reference to WalletManager and storage
    _spvActor = await _actorSystem.spawn('spv-actor', () => SPVActor(
      walletManager: _walletManager!,
      storage: _walletStorage,
    ));
    
    // Now update HeaderSyncActor with SPVActor reference
    // Note: This is a limitation of the current design - we need a way to update references
    
    // Spawn ARCActor with reference to WalletManager  
    _arcActor = await _actorSystem.spawn('arc-actor', () => ARCActor(
      walletManager: _walletManager!,
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

  /// Get reference to the wallet storage
  WalletStorage get walletStorage {
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

  /// Get reference to the SpiffyNode bridge (if connected)
  SpiffyNodeBridge? get spiffyNodeBridge => _spiffyNodeBridge;

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

  /// Shutdown the entire actor system
  Future<void> shutdown() async {
    print('Shutting down LibSpiffy Actor System...');
    
    try {
      // Disconnect from SpiffyNode first
      await disconnectFromSpiffyNode();
      
      // Shutdown actor system and storage
      await _actorSystem.shutdown();
      await _eventStore.close();
      
      print('LibSpiffy Actor System shutdown complete');
    } catch (e) {
      print('Error during shutdown: $e');
      rethrow;
    }
  }

  /// Check if the system is initialized
  bool get isInitialized => _walletManager != null && _spvActor != null && _arcActor != null && _headerSyncActor != null;
}

/// Global instance for easy access
LibSpiffyActorSystem? _globalInstance;

/// Get or create the global LibSpiffy actor system instance
LibSpiffyActorSystem getLibSpiffySystem() {
  _globalInstance ??= LibSpiffyActorSystem();
  return _globalInstance!;
}

/// Initialize the global LibSpiffy actor system instance
Future<void> initializeLibSpiffy({
  String? dataDirectory,
  ActorSystemConfig? config,
  WalletStorage? walletStorage,
}) async {
  final system = getLibSpiffySystem();
  await system.initialize(
    dataDirectory: dataDirectory, 
    config: config,
    walletStorage: walletStorage,
  );
}

/// Shutdown the global LibSpiffy actor system instance
Future<void> shutdownLibSpiffy() async {
  if (_globalInstance != null) {
    await _globalInstance!.shutdown();
    _globalInstance = null;
  }
} 