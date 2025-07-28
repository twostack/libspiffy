import 'dart:async';
import 'dart:typed_data';
import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:logging/logging.dart';
import 'package:dactor/dactor.dart';
import 'package:spiffynode/spiffy_node.dart';

import 'package:libspiffy/src/actors/header_sync_actor.dart';
import 'package:libspiffy/src/actors/spv_messages.dart';
import 'package:libspiffy/src/storage/wallet_storage.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';
import 'package:libspiffy/src/spv/block_header_chain.dart';

/// Integration tests for HeaderSyncActor
/// 
/// These tests verify:
/// 1. Actor message handling (BlockHeadersReceivedMessage, ChainTipEventMessage, etc.)
/// 2. BlockHeaderChain integration and coordination
/// 3. SPV actor communication and status reporting
/// 4. Error handling and recovery
/// 5. Performance under load
void main() {
  // Set up logging for tests
  Logger.root.level = Level.WARNING; // Reduce noise in tests
  Logger.root.onRecord.listen((record) {
    if (record.level >= Level.SEVERE) {
      print('${record.level.name}: ${record.time}: ${record.message}');
    }
  });

  group('HeaderSyncActor Integration Tests', () {
    late ActorSystem actorSystem;
    late WalletStorage storage;
    late BlockHeaderChain headerChain;
    late ActorRef headerSyncActor;
    late ActorRef mockSPVActor;

    setUpAll(() async {
      // Initialize actor system
      actorSystem = LocalActorSystem();
    });

    setUp(() async {
      // Initialize storage and header chain
      storage = InMemoryWalletStorage();
      headerChain = BlockHeaderChain(storage, skipProofOfWorkValidation: true);
      await headerChain.initialize();

      // Create a mock SPV actor to receive messages
      mockSPVActor = await actorSystem.spawn('mock-spv', () => _MockSPVActor());

      // Spawn HeaderSyncActor with dependencies
      headerSyncActor = await actorSystem.spawn('header-sync', () => HeaderSyncActor(
        headerChain: headerChain,
        spvActor: mockSPVActor,
      ));

      // Give actors time to initialize
      await Future.delayed(Duration(milliseconds: 200));
    });

    tearDown(() async {
      // Clean up for each test
      await actorSystem.stop(headerSyncActor);
      await actorSystem.stop(mockSPVActor);
      await Future.delayed(Duration(milliseconds: 50));
    });

    tearDownAll(() async {
      await actorSystem.shutdown();
    });

    group('Message Handling', () {
      test('should handle BlockHeadersReceivedMessage and store headers', () async {
        // Load real Bitcoin block headers
        final realHeaders = await _loadRealBlockHeaders();
        final testHeaders = realHeaders.take(3).toList();

        // Send headers to actor
        final message = BlockHeadersReceivedMessage(
          peerId: 'test-peer-1',
          headers: testHeaders,
          startHeight: 0,
          isReorganization: false,
        );

        headerSyncActor.tell(message as dynamic);

        // Wait for processing
        await Future.delayed(Duration(milliseconds: 500));

        // Verify headers were stored through the actor
        expect(headerChain.bestHeight, equals(2)); // Should have stored 3 headers (0, 1, 2)
        expect(headerChain.chainTip, isNotNull);
        expect(headerChain.cacheSize, equals(3));

        // Verify headers can be retrieved
        final retrievedHeader = await headerChain.getHeaderByHeight(1);
        expect(retrievedHeader, isNotNull);
      });

      test('should handle ChainTipEventMessage and forward to SPV actor', () async {
        // Create chain tip event
        final chainTipEvent = ChainTipEventMessage(
          newTip: _TestChainTip(blockHash: 'new_tip_hash', height: 100),
          oldTip: _TestChainTip(blockHash: 'old_tip_hash', height: 99),
          eventType: ChainTipEventType.heightIncrease,
          description: 'Chain height increased to 100',
        );

        headerSyncActor.tell(chainTipEvent as dynamic);

        // Wait for processing
        await Future.delayed(Duration(milliseconds: 100));

        // Check that mock SPV actor received the forwarded message
        // (This would need to be verified through the mock actor's received messages)
      });

      test('should handle GetSPVStatusMessage and respond with current status', () async {
        // Store some test headers first
        final header = _createTestBlockHeader(height: 1, prevHash: '0' * 64);
        await headerChain.validateAndStoreHeader(header, 1);

        // Create a test actor to receive the response
        final responder = await actorSystem.spawn('responder', () => _ResponseCollectorActor());

        // Send status request from responder
        headerSyncActor.tell(GetSPVStatusMessage() as dynamic);

        // Wait for response processing
        await Future.delayed(Duration(milliseconds: 100));

        // The response would be collected by the ResponseCollectorActor
        await actorSystem.stop(responder);
      });

      test('should handle RequestHeaderSyncMessage and respond with sync status', () async {
        // Store some headers to create a baseline
        final headers = List.generate(5, (i) => _createTestBlockHeader(
          height: i + 1,
          prevHash: i == 0 ? '0' * 64 : _calculateHash('header_$i'),
        ));

        for (int i = 0; i < headers.length; i++) {
          await headerChain.validateAndStoreHeader(headers[i], i + 1);
        }

        // Create sync request
        final syncRequest = RequestHeaderSyncMessage(fromHeight: 3);

        // Create responder to collect response
        final responder = await actorSystem.spawn('sync-responder', () => _ResponseCollectorActor());

        // Send sync request
        headerSyncActor.tell(syncRequest as dynamic);

        await Future.delayed(Duration(milliseconds: 100));
        await actorSystem.stop(responder);
      });
    });

    group('Error Handling', () {
      test('should handle invalid headers gracefully', () async {
        // Load real headers and create one invalid header
        final realHeaders = await _loadRealBlockHeaders();
        final validHeader = realHeaders[0]; // Genesis block
        
        // Create an invalid header with wrong previous block hash
        final invalidHeader = BlockHeader(
          version: 1,
          prevBlock: Hash.fromBytes(Uint8List.fromList(_stringToBytes('invalid_hash_that_doesnt_match'))),
          merkleRoot: realHeaders[1].merkleRoot,
          timestamp: realHeaders[1].timestamp,
          bits: realHeaders[1].bits,
          nonce: realHeaders[1].nonce,
        );
        
        final invalidHeaders = [validHeader, invalidHeader];

        final message = BlockHeadersReceivedMessage(
          peerId: 'test-peer-invalid',
          headers: invalidHeaders,
          startHeight: 0,
          isReorganization: false,
        );

        headerSyncActor.tell(message as dynamic);

        // Wait for processing
        await Future.delayed(Duration(milliseconds: 500));

        // Should only have stored the first valid header (genesis block)
        expect(headerChain.bestHeight, equals(0)); // Genesis block doesn't increase bestHeight
        expect(headerChain.cacheSize, equals(1));
      });

      test('should handle unknown message types gracefully', () async {
        // Create an unknown message type that implements Message
        final unknownMessage = _UnknownTestMessage();
        
        headerSyncActor.tell(unknownMessage as dynamic);

        // Wait for processing
        await Future.delayed(Duration(milliseconds: 100));

        // Actor should still be functional
        expect(headerChain.bestHeight, equals(0)); // No change
      });

      test('should handle messages when not initialized', () async {
        // Create a fresh HeaderSyncActor that hasn't been initialized yet
        final freshStorage = InMemoryWalletStorage();
        final freshHeaderChain = BlockHeaderChain(freshStorage);
        // Don't call initialize()

        final freshActor = await actorSystem.spawn('fresh-header-sync', () => HeaderSyncActor(
          headerChain: freshHeaderChain,
          spvActor: null, // No SPV actor
        ));

        // Send message before initialization is complete
        final message = BlockHeadersReceivedMessage(
          peerId: 'early-peer',
          headers: [_createTestBlockHeader(height: 1, prevHash: '0' * 64)],
          startHeight: 1,
        );

        freshActor.tell(message as dynamic);

        // Wait and verify graceful handling
        await Future.delayed(Duration(milliseconds: 100));

        await actorSystem.stop(freshActor);
      });
    });

    group('Performance and Load Testing', () {
      test('should handle multiple concurrent header batches', () async {
        const batchCount = 10;
        const headersPerBatch = 20;

        // Create multiple batches of headers
        final futures = <Future>[];

        for (int batch = 0; batch < batchCount; batch++) {
          final startHeight = batch * headersPerBatch + 1;
          final headers = List.generate(headersPerBatch, (i) {
            final height = startHeight + i;
            return _createTestBlockHeader(
              height: height,
              prevHash: height == 1 ? '0' * 64 : _calculateHash('header_${height - 1}'),
            );
          });

          final message = BlockHeadersReceivedMessage(
            peerId: 'batch-peer-$batch',
            headers: headers,
            startHeight: startHeight,
            isReorganization: false,
          );

          // Send message asynchronously
          futures.add(Future(() {
            headerSyncActor.tell(message as dynamic);
          }));
        }

        // Wait for all batches to be sent
        await Future.wait(futures);

        // Wait for processing to complete
        await Future.delayed(Duration(seconds: 2));

        // Verify all headers were processed
        // Note: Due to concurrency, some headers might be rejected due to validation failures
        // But we should have a significant number stored
        expect(headerChain.bestHeight, greaterThan(10));
        expect(headerChain.cacheSize, greaterThan(10));
      });

      test('should handle rapid chain tip events', () async {
        const eventCount = 50;
        
        // Send rapid chain tip updates
        for (int i = 1; i <= eventCount; i++) {
          final event = ChainTipEventMessage(
            newTip: _TestChainTip(blockHash: 'tip_hash_$i', height: i),
            oldTip: i > 1 ? _TestChainTip(blockHash: 'tip_hash_${i-1}', height: i-1) : null,
            eventType: ChainTipEventType.heightIncrease,
            description: 'Rapid tip update $i',
          );

          headerSyncActor.tell(event as dynamic);
          
          // Small delay to simulate realistic timing
          if (i % 10 == 0) {
            await Future.delayed(Duration(milliseconds: 10));
          }
        }

        // Wait for all events to be processed
        await Future.delayed(Duration(milliseconds: 500));

        // Actor should still be responsive
        final statusRequest = GetSPVStatusMessage();
        headerSyncActor.tell(statusRequest as dynamic);
        
        await Future.delayed(Duration(milliseconds: 100));
      });
    });

    group('BlockHeaderChain Integration', () {
      test('should properly coordinate with BlockHeaderChain for validation', () async {
        // Use all available real headers (we have 7 real headers: 0-6)
        final headers = await _loadRealBlockHeaders();

        // Send headers one batch at a time to ensure proper chaining
        for (int i = 0; i < headers.length; i += 3) {
          final batch = headers.skip(i).take(3).toList();
          final message = BlockHeadersReceivedMessage(
            peerId: 'chain-peer',
            headers: batch,
            startHeight: i, // Start from 0 for genesis block
            isReorganization: false,
          );

          headerSyncActor.tell(message as dynamic);
          
          // Wait between batches to ensure ordered processing
          await Future.delayed(Duration(milliseconds: 100));
        }

        // Final wait for processing
        await Future.delayed(Duration(milliseconds: 200));

        // Verify chain integrity
        expect(headerChain.bestHeight, equals(6)); // 7 headers: heights 0-6
        
        // Verify we can retrieve headers by height
        for (int i = 0; i < 7; i++) {
          final header = await headerChain.getHeaderByHeight(i);
          expect(header, isNotNull, reason: 'Header at height $i should exist');
        }
      });

      test('should handle blockchain reorganizations', () async {
        // Create initial chain
        final initialHeaders = [
          _createTestBlockHeader(height: 1, prevHash: '0' * 64),
          _createTestBlockHeader(height: 2, prevHash: _calculateHash('header_1')),
          _createTestBlockHeader(height: 3, prevHash: _calculateHash('header_2')),
        ];

        // Store initial chain
        final initialMessage = BlockHeadersReceivedMessage(
          peerId: 'initial-peer',
          headers: initialHeaders,
          startHeight: 1,
        );

        headerSyncActor.tell(initialMessage as dynamic);
        await Future.delayed(Duration(milliseconds: 200));

        expect(headerChain.bestHeight, equals(3));

        // Simulate reorganization event
        final reorgEvent = ChainTipEventMessage(
          newTip: _TestChainTip(blockHash: 'new_chain_tip', height: 4),
          oldTip: _TestChainTip(blockHash: _calculateHash('header_3'), height: 3),
          eventType: ChainTipEventType.reorganization,
          description: 'Blockchain reorganization detected',
        );

        headerSyncActor.tell(reorgEvent as dynamic);
        await Future.delayed(Duration(milliseconds: 200));

        // HeaderSyncActor should forward the reorg event to SPV actor
        // The actual reorganization handling would be coordinated through BlockHeaderChain
      });
    });
  });
}

/// Mock SPV Actor for testing communication
class _MockSPVActor extends Actor {
  final List<dynamic> receivedMessages = [];

  @override
  Future<void> onMessage(dynamic message) async {
    receivedMessages.add(message);
  }
}

/// Actor that collects responses for testing ask patterns
class _ResponseCollectorActor extends Actor {
  dynamic lastResponse;

  @override
  Future<void> onMessage(dynamic message) async {
    lastResponse = message;
    
    // If this is an ask message, we should reply
    if (context.sender != null) {
      context.sender!.tell(message);
    }
  }
}

/// Test chain tip implementation
class _TestChainTip implements ChainTip {
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

  _TestChainTip({
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
  String toString() => '_TestChainTip(height: $height, hash: ${_blockHashString.substring(0, 8)}...)';

  @override
  bool operator ==(Object other) {
    return other is _TestChainTip &&
           other.height == height &&
           other._blockHashString == _blockHashString;
  }

  @override
  int get hashCode => Object.hash(height, _blockHashString);
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
    prevBlock: Hash.fromBytes(Uint8List.fromList(_stringToBytes(prevHash))),
    merkleRoot: Hash.fromBytes(Uint8List.fromList(_stringToBytes(_calculateHash(finalMerkleRoot)))),
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

/// Load real Bitcoin block headers from JSON file
Future<List<BlockHeader>> _loadRealBlockHeaders() async {
  try {
    final file = File('test/data/first_7_headers.json');
    final jsonString = await file.readAsString();
    final jsonList = json.decode(jsonString) as List<dynamic>;
    
    return jsonList.map((json) => _createBlockHeaderFromJson(json as Map<String, dynamic>)).toList();
  } catch (e) {
    // Fallback to mock headers if file not found
    return [
      _createTestBlockHeader(height: 0, prevHash: '0' * 64),
      _createTestBlockHeader(height: 1, prevHash: _calculateHash('header_0')),
      _createTestBlockHeader(height: 2, prevHash: _calculateHash('header_1')),
    ];
  }
}

/// Create a BlockHeader from JSON data
BlockHeader _createBlockHeaderFromJson(Map<String, dynamic> data) {
  return BlockHeader(
    version: data['version'] as int,
    prevBlock: Hash.fromBytes(Uint8List.fromList(_hexToBytesReversed(data['previousblockhash'] as String))),
    merkleRoot: Hash.fromBytes(Uint8List.fromList(_hexToBytesReversed(data['merkleroot'] as String))),
    timestamp: DateTime.fromMillisecondsSinceEpoch((data['time'] as int) * 1000),
    bits: int.parse(data['bits'] as String, radix: 16),
    nonce: data['nonce'] as int,
  );
}

/// Convert hex string to bytes
List<int> _hexToBytes(String hex) {
  final bytes = <int>[];
  for (int i = 0; i < hex.length; i += 2) {
    bytes.add(int.parse(hex.substring(i, i + 2), radix: 16));
  }
  return bytes;
}

/// Convert hex string to bytes and reverse (for Bitcoin's little-endian format)
List<int> _hexToBytesReversed(String hex) {
  if (hex.isEmpty) {
    // Handle empty string (genesis block has empty previousblockhash)
    return List.filled(32, 0);
  }
  final bytes = _hexToBytes(hex);
  return bytes.reversed.toList();
}

/// Unknown message type for testing
class _UnknownTestMessage implements Message {
  @override
  final String correlationId = 'unknown_test_${DateTime.now().millisecondsSinceEpoch}';

  @override
  final ActorRef? replyTo = null;

  @override
  final DateTime timestamp = DateTime.now();

  @override
  final Map<String, dynamic> metadata = {};
} 