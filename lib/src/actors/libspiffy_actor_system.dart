import 'dart:async';
import 'package:dactor/dactor.dart';
import 'package:eventador/eventador.dart';
import 'package:isar/isar.dart';

import 'wallet_manager_actor.dart';
import 'spv_actor.dart';
import 'arc_actor.dart';

/// Initialization and management utilities for the LibSpiffy actor system
class LibSpiffyActorSystem {
  late LocalActorSystem _actorSystem;
  late IsarEventStore _eventStore;
  
  // Actor references
  ActorRef? _walletManager;
  ActorRef? _spvActor;
  ActorRef? _arcActor;

  /// Initialize the LibSpiffy actor system
  Future<void> initialize({
    String? dataDirectory,
    ActorSystemConfig? config,
  }) async {
    print('Initializing LibSpiffy Actor System...');
    
    // 1. Initialize Dactor system
    _actorSystem = LocalActorSystem(config ?? ActorSystemConfig());
    
    // 2. Initialize Eventador storage  
    await Isar.initializeIsarCore(download: true);
    _eventStore = await IsarEventStore.create(directory: dataDirectory ?? './data');
    
    // 3. Spawn coordination actors
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
    
    // Spawn SPVActor with reference to WalletManager
    _spvActor = await _actorSystem.spawn('spv-actor', () => SPVActor(
      walletManager: _walletManager!,
    ));
    
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

  /// Shutdown the entire actor system
  Future<void> shutdown() async {
    print('Shutting down LibSpiffy Actor System...');
    
    try {
      await _actorSystem.shutdown();
      await _eventStore.close();
      print('LibSpiffy Actor System shutdown complete');
    } catch (e) {
      print('Error during shutdown: $e');
      rethrow;
    }
  }

  /// Check if the system is initialized
  bool get isInitialized => _walletManager != null && _spvActor != null && _arcActor != null;
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
}) async {
  final system = getLibSpiffySystem();
  await system.initialize(dataDirectory: dataDirectory, config: config);
}

/// Shutdown the global LibSpiffy actor system instance
Future<void> shutdownLibSpiffy() async {
  if (_globalInstance != null) {
    await _globalInstance!.shutdown();
    _globalInstance = null;
  }
} 