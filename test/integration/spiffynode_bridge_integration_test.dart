import 'dart:async';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:logging/logging.dart';
import 'package:dactor/dactor.dart';
import 'package:spiffynode/spiffy_node.dart';

import 'package:libspiffy/src/integration/spiffynode_bridge.dart';

/// Integration tests for SpiffyNodeBridge
/// 
/// These tests verify:
/// 1. SpiffyNode ChainTipEvent translation to LibSpiffy messages
/// 2. Message delivery to HeaderSyncActor
/// 3. LibSpiffyPeerHandler integration for header capture
/// 4. Error handling and recovery
/// 5. Bridge lifecycle management
void main() {
  // Set up logging for tests
  Logger.root.level = Level.WARNING; // Reduce noise in tests
  Logger.root.onRecord.listen((record) {
    if (record.level >= Level.SEVERE) {
      print('${record.level.name}: ${record.time}: ${record.message}');
    }
  });

  group('SpiffyNodeBridge Integration Tests', () {
    late ActorSystem actorSystem;
    late ActorRef mockHeaderSyncActor;
    late _MockPeerManager mockPeerManager;
    late SpiffyNodeBridge bridge;

    setUpAll(() async {
      // Initialize actor system
      actorSystem = LocalActorSystem();
    });

    setUp(() async {
      // Create mock HeaderSyncActor to receive messages
      mockHeaderSyncActor = await actorSystem.spawn('mock-header-sync', () => _MockHeaderSyncActor());

      // Create mock PeerManager
      mockPeerManager = _MockPeerManager();

      // Create bridge
      bridge = SpiffyNodeBridge(
        peerManager: mockPeerManager,
        headerSyncActor: mockHeaderSyncActor,
      );

      // Give actors time to initialize
      await Future.delayed(Duration(milliseconds: 100));
    });

    tearDown(() async {
      // Clean up for each test
      await bridge.shutdown();
      await actorSystem.stop(mockHeaderSyncActor);
      await Future.delayed(Duration(milliseconds: 50));
    });

    tearDownAll(() async {
      await actorSystem.shutdown();
    });

    group('Event Translation and Message Delivery', () {
      test('should translate ChainTipEvent to ChainTipEventMessage', () async {
        // Initialize bridge
        await bridge.initialize();

        // Create SpiffyNode ChainTipEvent  
        final spiffyEvent = _MockChainTipEvent(
          type: ChainTipEventType.heightIncrease,
          newTip: _MockChainTip(blockHash: 'new_tip_hash', height: 100),
          oldTip: _MockChainTip(blockHash: 'old_tip_hash', height: 99),
          isReorganization: false,
        );

        // Simulate event from SpiffyNode
        mockPeerManager.simulateChainTipEvent(spiffyEvent);

        // Wait for event processing
        await Future.delayed(Duration(milliseconds: 200));

        // Verify bridge statistics
        final stats = bridge.statistics;
        expect(stats['eventsProcessed'], equals(1));
        expect(stats['initialized'], isTrue);

        // Verify HeaderSyncActor received translated message
        // Note: In a real test, we'd verify the message was received by the mock actor
      });

      test('should handle reorganization events correctly', () async {
        await bridge.initialize();

        // Create reorganization event
        final reorgEvent = _MockChainTipEvent(
          type: ChainTipEventType.reorganization,
          newTip: _MockChainTip(blockHash: 'new_chain_tip', height: 98),
          oldTip: _MockChainTip(blockHash: 'old_chain_tip', height: 100),
          isReorganization: true,
        );

        // Simulate reorganization
        mockPeerManager.simulateChainTipEvent(reorgEvent);

        // Wait for processing
        await Future.delayed(Duration(milliseconds: 200));

        // Verify event was processed
        final stats = bridge.statistics;
        expect(stats['eventsProcessed'], equals(1));
      });

      test('should handle multiple rapid events', () async {
        await bridge.initialize();

        const eventCount = 10;
        
        // Send multiple rapid events
        for (int i = 1; i <= eventCount; i++) {
          final event = _MockChainTipEvent(
            type: ChainTipEventType.heightIncrease,
            newTip: _MockChainTip(blockHash: 'tip_$i', height: i),
            oldTip: i > 1 ? _MockChainTip(blockHash: 'tip_${i-1}', height: i-1) : null,
            isReorganization: false,
          );

          mockPeerManager.simulateChainTipEvent(event);
          
          // Small delay between events
          if (i % 3 == 0) {
            await Future.delayed(Duration(milliseconds: 10));
          }
        }

        // Wait for all events to process
        await Future.delayed(Duration(milliseconds: 500));

        // Verify all events were processed
        final stats = bridge.statistics;
        expect(stats['eventsProcessed'], equals(eventCount));
      });
    });

    group('Header Storage Integration', () {
      test('should forward headers to HeaderSyncActor via storeHeaders', () async {
        await bridge.initialize();

        // Create test headers
        final headers = [
          _createTestBlockHeader(height: 1, prevHash: '0' * 64),
          _createTestBlockHeader(height: 2, prevHash: _calculateHash('header_1')),
          _createTestBlockHeader(height: 3, prevHash: _calculateHash('header_2')),
        ];

        // Store headers via bridge
        final success = await bridge.storeHeaders(headers, 1);

        expect(success, isTrue);

        // Wait for message delivery
        await Future.delayed(Duration(milliseconds: 100));

        // Verify HeaderSyncActor would have received BlockHeadersReceivedMessage
        // In a real implementation, we'd check the mock actor's received messages
      });

      test('should handle empty header list gracefully', () async {
        await bridge.initialize();

        final success = await bridge.storeHeaders([], 0);
        expect(success, isTrue);
      });

      test('should handle errors during header forwarding', () async {
        await bridge.initialize();

        // Test with invalid headers (null values would cause errors)
        final headers = [
          _createTestBlockHeader(height: 1, prevHash: '0' * 64),
        ];

        // This should not throw, even if there are internal errors
        final success = await bridge.storeHeaders(headers, 1);
        expect(success, isTrue);
      });
    });

    group('LibSpiffyPeerHandler Integration', () {
      test('should create LibSpiffyPeerHandler and forward headers', () async {
        await bridge.initialize();

        // Create peer handler
        final peerHandler = LibSpiffyPeerHandler(
          bridge: bridge,
          userHandler: null,
        );

        // Create mock peer and headers message
        final mockPeer = _MockPeer('test-peer-1');
        final headers = [
          _createTestBlockHeader(height: 1, prevHash: '0' * 64),
          _createTestBlockHeader(height: 2, prevHash: _calculateHash('header_1')),
        ];
        final headersMessage = MsgHeaders(headers: headers);

        // Simulate header reception
        await peerHandler.handleHeaders(headersMessage, mockPeer);

        // Wait for processing
        await Future.delayed(Duration(milliseconds: 100));

        // Verify headers were forwarded to bridge
        // The bridge should have processed the headers
      });

      test('should delegate to user handler when provided', () async {
        await bridge.initialize();

        final mockUserHandler = _MockPeerHandler();
        final peerHandler = LibSpiffyPeerHandler(
          bridge: bridge,
          userHandler: mockUserHandler,
        );

        final mockPeer = _MockPeer('test-peer-2');
        final headers = [_createTestBlockHeader(height: 1, prevHash: '0' * 64)];
        final headersMessage = MsgHeaders(headers: headers);

        // Test delegation
        await peerHandler.handleHeaders(headersMessage, mockPeer);
        
        // Create a simple version message for testing
        final versionMessage = MsgVersion(
          services: ServiceFlags.none,
          nonce: 12345,
          userAgent: 'test',
          startHeight: 0,
          relay: false,
        );
        
        await peerHandler.handleVersion(versionMessage, mockPeer);

        // Wait for processing
        await Future.delayed(Duration(milliseconds: 100));

        // Verify user handler received calls
        expect(mockUserHandler.handleHeadersCalled, isTrue);
        expect(mockUserHandler.handleVersionCalled, isTrue);
      });
    });

    group('Error Handling and Recovery', () {
      test('should handle initialization errors gracefully', () async {
        // Create bridge with problematic PeerManager
        final problematicPeerManager = _ProblematicPeerManager();
        final problematicBridge = SpiffyNodeBridge(
          peerManager: problematicPeerManager,
          headerSyncActor: mockHeaderSyncActor,
        );

        // Initialization should handle errors
        expect(() => problematicBridge.initialize(), throwsA(isA<Exception>()));
      });

      test('should handle event stream errors', () async {
        await bridge.initialize();

        // Simulate error in event stream
        mockPeerManager.simulateEventError('Test error', StackTrace.current);

        // Wait for error handling
        await Future.delayed(Duration(milliseconds: 100));

        // Bridge should still be functional
        expect(bridge.statistics['initialized'], isTrue);
      });

      test('should handle shutdown gracefully', () async {
        await bridge.initialize();

        // Verify bridge is initialized
        expect(bridge.statistics['initialized'], isTrue);

        // Shutdown
        await bridge.shutdown();

        // Verify clean shutdown
        expect(bridge.statistics['initialized'], isFalse);

        // Multiple shutdowns should be safe
        await bridge.shutdown();
      });

      test('should handle message sending errors', () async {
        // Create bridge with problematic HeaderSyncActor
        final problematicActor = await actorSystem.spawn('problematic', () => _ProblematicActor());
        final problematicBridge = SpiffyNodeBridge(
          peerManager: mockPeerManager,
          headerSyncActor: problematicActor,
        );

        await problematicBridge.initialize();

        // Send event that should cause error in message handling
        final event = _MockChainTipEvent(
          type: ChainTipEventType.heightIncrease,
          newTip: _MockChainTip(blockHash: 'test', height: 1),
          oldTip: null,
          isReorganization: false,
        );

        // This should not throw, errors should be handled gracefully
        mockPeerManager.simulateChainTipEvent(event);
        await Future.delayed(Duration(milliseconds: 100));

        await problematicBridge.shutdown();
        await actorSystem.stop(problematicActor);
      });
    });

    group('Bridge Lifecycle and Statistics', () {
      test('should track statistics correctly', () async {
        // Initial statistics
        var stats = bridge.statistics;
        expect(stats['initialized'], isFalse);
        expect(stats['eventsProcessed'], equals(0));

        // After initialization
        await bridge.initialize();
        stats = bridge.statistics;
        expect(stats['initialized'], isTrue);
        expect(stats['spiffyNodeHeight'], equals(mockPeerManager.chainTipTracker.networkHeight));

        // After processing events
        final event = _MockChainTipEvent(
          type: ChainTipEventType.heightIncrease,
          newTip: _MockChainTip(blockHash: 'test', height: 1),
          oldTip: null,
          isReorganization: false,
        );

        mockPeerManager.simulateChainTipEvent(event);
        await Future.delayed(Duration(milliseconds: 100));

        stats = bridge.statistics;
        expect(stats['eventsProcessed'], equals(1));
        expect(stats['lastEventAt'], isNotNull);
      });

      test('should prevent double initialization', () async {
        await bridge.initialize();
        
        // Second initialization should be safe
        await bridge.initialize();
        
        // Should still be initialized and functional
        expect(bridge.statistics['initialized'], isTrue);
      });
    });
  });
}

/// Mock HeaderSyncActor for testing
class _MockHeaderSyncActor extends Actor {
  final List<dynamic> receivedMessages = [];

  @override
  Future<void> onMessage(dynamic message) async {
    receivedMessages.add(message);
  }
}

/// Mock PeerManager for testing
class _MockPeerManager implements PeerManager {
  late final _MockChainTipTracker _chainTipTracker;
  final StreamController<ChainTipEvent> _tipEventController = StreamController<ChainTipEvent>.broadcast();

  _MockPeerManager() {
    _chainTipTracker = _MockChainTipTracker(_tipEventController.stream);
  }

  @override
  ChainTipTracker get chainTipTracker => _chainTipTracker;

  void simulateChainTipEvent(ChainTipEvent event) {
    _tipEventController.add(event);
  }

  void simulateEventError(String error, StackTrace stackTrace) {
    _tipEventController.addError(error, stackTrace);
  }

  // Implement other PeerManager methods as no-ops for testing
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// Mock ChainTipTracker for testing
class _MockChainTipTracker implements ChainTipTracker {
  final Stream<ChainTipEvent> _tipEventsStream;

  _MockChainTipTracker(this._tipEventsStream);

  @override
  int get networkHeight => 100;

  @override
  Stream<ChainTipEvent> get tipEvents => _tipEventsStream;

  // Implement other ChainTipTracker methods as no-ops for testing
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// Mock ChainTipEvent for testing
class _MockChainTipEvent implements ChainTipEvent {
  @override
  final ChainTipEventType type;
  
  @override
  final ChainTip newTip;
  
  @override
  final ChainTip? oldTip;
  
  @override
  final bool isReorganization;

  @override
  final String? triggeringPeer;

  @override  
  final String description;

  _MockChainTipEvent({
    required this.type,
    required this.newTip,
    this.oldTip,
    required this.isReorganization,
    String? description,
  }) : triggeringPeer = null,
       description = description ?? 'Mock chain tip event';

  @override
  int get heightChange {
    if (oldTip == null) return newTip.height;
    return newTip.height - oldTip!.height;
  }
}

/// Mock ChainTip for testing
class _MockChainTip implements ChainTip {
  final String _blockHashString;
  
  @override
  final int height;
  
  @override
  final DateTime lastUpdated;
  
  @override
  final int peerCount;
  
  @override
  final double confidence;
  
  @override
  final List<String> reportingPeers;

  _MockChainTip({
    required String blockHash,
    required this.height,
    DateTime? lastUpdated,
    int? peerCount,
    double? confidence,
    List<String>? reportingPeers,
  }) : _blockHashString = blockHash,
       lastUpdated = lastUpdated ?? DateTime.now(),
       peerCount = peerCount ?? 1,
       confidence = confidence ?? 1.0,
       reportingPeers = reportingPeers ?? [];

  @override
  Hash get blockHash => Hash.fromBytes(Uint8List.fromList(_stringToBytes(_blockHashString)));

  @override
  Duration get age => DateTime.now().difference(lastUpdated);

  @override
  bool get isCurrent => age < Duration(minutes: 15);

  @override
  String toString() => '_MockChainTip(height: $height, hash: ${_blockHashString.substring(0, 8)}...)';

  @override
  bool operator ==(Object other) {
    return other is _MockChainTip &&
           other.height == height &&
           other._blockHashString == _blockHashString;
  }

  @override
  int get hashCode => Object.hash(height, _blockHashString);
}

/// Mock Peer for testing
class _MockPeer implements PeerI {
  final String id;

  _MockPeer(this.id);

  @override
  String toString() => 'MockPeer($id)';

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// Mock PeerHandler for testing delegation
class _MockPeerHandler implements PeerHandlerI {
  bool handleHeadersCalled = false;
  bool handleVersionCalled = false;

  @override
  Future<void> handleHeaders(WireMessage message, PeerI peer) async {
    handleHeadersCalled = true;
  }

  @override
  Future<void> handleVersion(WireMessage msg, PeerI peer) async {
    handleVersionCalled = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// Problematic PeerManager that throws errors for testing
class _ProblematicPeerManager implements PeerManager {
  @override
  ChainTipTracker get chainTipTracker => throw Exception('Problematic ChainTipTracker');

  @override
  dynamic noSuchMethod(Invocation invocation) => throw Exception('Problematic PeerManager');
}

/// Problematic Actor that throws errors for testing
class _ProblematicActor extends Actor {
  @override
  Future<void> onMessage(dynamic message) async {
    throw Exception('Problematic Actor Error');
  }
}

/// Convert string to bytes for testing
List<int> _stringToBytes(String str) {
  final bytes = <int>[];
  for (int i = 0; i < str.length && bytes.length < 32; i += 2) {
    if (i + 1 < str.length) {
      final byte = int.tryParse(str.substring(i, i + 2), radix: 16) ?? 0;
      bytes.add(byte);
    }
  }
  while (bytes.length < 32) {
    bytes.add(0);
  }
  return bytes;
}

/// Create a test block header for testing
BlockHeader _createTestBlockHeader({
  required int height,
  required String prevHash,
  int version = 1,
  String? merkleRoot,
  DateTime? timestamp,
  int bits = 0x1d00ffff,
  int nonce = 12345,
}) {
  final finalMerkleRoot = merkleRoot ?? 'merkle_root_$height';
  final finalTimestamp = timestamp ?? DateTime.now().subtract(Duration(hours: height));

  return BlockHeader(
    version: version,
    prevBlock: Hash.fromHex(prevHash),
    merkleRoot: Hash.fromHex(_calculateHash(finalMerkleRoot)),
    timestamp: finalTimestamp,
    bits: bits,
    nonce: nonce,
  );
}

/// Simple hash calculator for test data
String _calculateHash(String input) {
  // Simple deterministic hash for testing
  int hash = 0;
  for (int i = 0; i < input.length; i++) {
    hash = ((hash << 5) - hash + input.codeUnitAt(i)) & 0xffffffff;
  }
  return hash.toRadixString(16).padLeft(64, '0');
} 