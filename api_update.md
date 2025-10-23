# LibSpiffy API Update Request

## Issue: Leaky Abstraction with SpiffyNode Dependency

### Current Problem

The current `LibSpiffyActorSystem` API requires application developers to directly manage SpiffyNode's `PeerManager`, which creates a **leaky abstraction** and forces unnecessary dependency coupling.

**Current API:**

```dart
// In application code (overnode_v2)
import 'package:libspiffy/libspiffy.dart';
import 'package:spiffynode/spiffy_node.dart';  // ❌ Application shouldn't need this!

// Application must create and manage SpiffyNode PeerManager
final peerManager = PeerManager(
  network: BitcoinNetwork.testnet,
  logger: Logger('MyApp-SpiffyNode'),
);

await peerManager.addPeerByAddress('testnet-seed.bitcoinsv.io', 18333);

// Then pass it to LibSpiffy
final libspiffy = LibSpiffyActorSystem();
await libspiffy.initialize();
await libspiffy.connectToSpiffyNode(peerManager);  // ❌ Exposes implementation detail
```

### Why This Is Problematic

1. **Dependency Pollution**: Applications must add `spiffynode` as a direct dependency in their `pubspec.yaml`, even though it's purely an internal implementation detail of LibSpiffy.

2. **Violated Encapsulation**: Applications need to understand SpiffyNode's API (`PeerManager`, `BitcoinNetwork`, `PeerConfig`, etc.) to use LibSpiffy.

3. **Tight Coupling**: If LibSpiffy later wants to switch to a different P2P implementation or add multiple P2P backends, all applications would need code changes.

4. **Increased Complexity**: Application developers have to manage two separate systems (LibSpiffy + SpiffyNode) instead of one unified wallet infrastructure.

### Desired Architecture

```
Application (overnode_v2)
    ↓ depends on
LibSpiffy  ← Clean abstraction boundary
    ↓ uses internally (hidden)
SpiffyNode ← Implementation detail
```

## Proposed Solution

### New Clean API

```dart
// In application code (overnode_v2)
import 'package:libspiffy/libspiffy.dart';  // ✅ Only LibSpiffy import needed!

final bitcoinWallet = LibSpiffyActorSystem();

await bitcoinWallet.initialize(
  networkType: 'test',              // Simple string: 'main' or 'test'
  enableP2P: true,                  // Enable block header synchronization
  startHeight: 50000,               // Optional: SPV start height
  peerAddresses: [                  // Optional: custom peers
    'testnet-seed.bitcoinsv.io:18333',
  ],
);

// That's it! SpiffyNode is managed internally
// Block headers sync automatically via P2P
// Application doesn't need to know about PeerManager
```

### Alternative: Builder Pattern

If more configuration is needed:

```dart
final bitcoinWallet = LibSpiffyActorSystem()
  .withNetwork('test')
  .withP2P(enabled: true)
  .withStartHeight(50000)
  .withCustomPeers(['testnet-seed.bitcoinsv.io:18333']);

await bitcoinWallet.initialize();
```

### Proposed API Signature

```dart
class LibSpiffyActorSystem {
  /// Initialize LibSpiffy with optional P2P connectivity
  ///
  /// Parameters:
  /// - [networkType]: 'main' for mainnet, 'test' for testnet
  /// - [enableP2P]: Enable SpiffyNode P2P for automatic block header sync
  /// - [startHeight]: Starting block height for SPV sync (default: 0)
  /// - [peerAddresses]: Custom peer addresses (optional, uses seed nodes by default)
  /// - [userAgent]: Custom user agent string (optional)
  ///
  /// When [enableP2P] is true:
  /// - SpiffyNode PeerManager is created internally
  /// - Connection to Bitcoin P2P network is established
  /// - Block headers sync automatically
  /// - Application doesn't need to manage SpiffyNode
  Future<void> initialize({
    String networkType = 'test',
    bool enableP2P = true,
    int? startHeight,
    List<String>? peerAddresses,
    String? userAgent,
  }) async {
    // Initialize actor system
    await _initializeActors();
    
    // Initialize P2P if enabled
    if (enableP2P) {
      await _initializeP2P(
        networkType: networkType,
        startHeight: startHeight,
        peerAddresses: peerAddresses,
        userAgent: userAgent,
      );
    }
  }
  
  /// Internal method to setup SpiffyNode P2P
  Future<void> _initializeP2P({
    required String networkType,
    int? startHeight,
    List<String>? peerAddresses,
    String? userAgent,
  }) async {
    // Create PeerManager internally
    final network = networkType == 'main' 
        ? BitcoinNetwork.mainnet 
        : BitcoinNetwork.testnet;
    
    _peerManager = PeerManager(
      network: network,
      logger: Logger('LibSpiffy-SpiffyNode'),
    );
    
    // Connect to peers
    final peers = peerAddresses ?? _getDefaultPeers(networkType);
    for (final peerAddr in peers) {
      final parts = peerAddr.split(':');
      await _peerManager!.addPeerByAddress(
        parts[0],
        int.parse(parts[1]),
        peerConfig: PeerConfig(
          startHeight: startHeight,
          userAgent: userAgent ?? '/LibSpiffy:1.0/',
        ),
      );
    }
    
    // Connect to SpiffyNode bridge
    await _connectSpiffyNodeBridge();
  }
  
  /// Get default seed nodes for network
  List<String> _getDefaultPeers(String networkType) {
    return networkType == 'main'
        ? ['seed.bitcoinsv.io:8333']
        : ['testnet-seed.bitcoinsv.io:18333'];
  }
}
```

## Benefits of Proposed Change

### For Application Developers

1. **Simpler Integration**: One import, one initialization call
2. **Less Boilerplate**: No need to manage PeerManager, network types, peer configs
3. **Better Defaults**: LibSpiffy can provide sensible defaults (seed nodes, user agent, etc.)
4. **Cleaner Dependencies**: Only `libspiffy` in pubspec.yaml

### For LibSpiffy

1. **Better Abstraction**: Can change P2P implementation without breaking applications
2. **More Flexibility**: Can add features like multiple P2P backends, automatic peer discovery
3. **Easier Testing**: Can mock P2P layer internally without exposing it
4. **Professional API**: Matches industry standards for wallet libraries

### For Maintenance

1. **Less Breaking Changes**: P2P implementation changes don't affect applications
2. **Better Documentation**: Simpler API = easier to document and understand
3. **Reduced Support**: Fewer questions about SpiffyNode configuration

## Migration Path

To maintain backward compatibility, you could:

1. **Keep existing `connectToSpiffyNode(PeerManager)` method** but mark it as deprecated
2. **Add new `initialize()` method** with clean API as shown above
3. **Update examples** to use new API
4. **Document migration** in changelog

```dart
// Deprecated (keep for backward compatibility)
@deprecated('Use initialize(enableP2P: true) instead')
Future<void> connectToSpiffyNode(dynamic peerManager) async {
  // Existing implementation
}

// New clean API
Future<void> initialize({
  String networkType = 'test',
  bool enableP2P = true,
  // ... other params
}) async {
  // New implementation
}
```

## Implementation Timeline

This is not urgent - the current API works, it just leaks implementation details. Suggested timeline:

- **Phase 1**: Add new `initialize()` method alongside existing API
- **Phase 2**: Update LibSpiffy examples and tests to use new API  
- **Phase 3**: Deprecate `connectToSpiffyNode()` in next major version
- **Phase 4**: Remove old API in future major version

## Example: Before and After

### Before (Current - Leaky Abstraction)

```dart
// pubspec.yaml
dependencies:
  libspiffy: ^1.0.0
  spiffynode: ^1.0.0  # ❌ Shouldn't need this

// main.dart
import 'package:libspiffy/libspiffy.dart';
import 'package:spiffynode/spiffy_node.dart';  // ❌ Leaky abstraction

initializeMessages();  // ❌ Application manages SpiffyNode details

final peerManager = PeerManager(
  network: BitcoinNetwork.testnet,
  logger: Logger('SpiffyNode'),
);

await peerManager.addPeerByAddress(
  'testnet-seed.bitcoinsv.io',
  18333,
  peerConfig: PeerConfig(
    userAgent: '/MyApp:1.0/',
    enablePingPong: true,
  ),
);

final libspiffy = LibSpiffyActorSystem();
await libspiffy.initialize();
await libspiffy.connectToSpiffyNode(peerManager);
```

### After (Proposed - Clean Abstraction)

```dart
// pubspec.yaml
dependencies:
  libspiffy: ^1.0.0  # ✅ Only dependency needed

// main.dart
import 'package:libspiffy/libspiffy.dart';  // ✅ Single import

final libspiffy = LibSpiffyActorSystem();
await libspiffy.initialize(
  networkType: 'test',
  enableP2P: true,
);

// ✅ That's it! SpiffyNode managed internally
// ✅ Block headers syncing automatically
// ✅ Clean, simple, professional API
```

## Questions for Discussion

1. Do you prefer the direct parameter approach or builder pattern?
2. Should `enableP2P` default to `true` or `false`?
3. Any other configuration options needed at initialization?
4. Timeline preference for implementing this change?

## Contact

For discussion about this proposal, please reach out to the OverNode development team.

---

*Document created: 2025-10-23*  
*LibSpiffy Version: 1.0.0*  
*Requesting Application: OverNode v2*

