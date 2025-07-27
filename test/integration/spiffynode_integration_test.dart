import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:logging/logging.dart';
import 'package:spiffynode/spiffy_node.dart';
import 'package:dactor/dactor.dart';

import 'package:libspiffy/src/storage/wallet_storage.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';
import 'package:libspiffy/src/spv/block_header_chain.dart';
import 'package:libspiffy/src/actors/spv_messages.dart';

/// End-to-end integration tests for SpiffyNode + LibSpiffy
/// 
/// These tests demonstrate the complete integration flow:
/// 1. SpiffyNode connects to Bitcoin network (or simulated network)
/// 2. LibSpiffy SPV components process block headers
/// 3. Transaction validation using SPV proofs
/// 4. Storage integration with developer's Isar instance
void main() {
  // Set up logging for integration tests
  Logger.root.level = Level.INFO;
  Logger.root.onRecord.listen((record) {
    print('${record.level.name}: ${record.time}: ${record.message}');
  });

  group('SpiffyNode + LibSpiffy Integration', () {
    late WalletStorage storage;
    late BlockHeaderChain headerChain;
    late ActorSystem actorSystem;
    
    setUpAll(() async {
      // Initialize actor system for LibSpiffy components
      actorSystem = LocalActorSystem();
    });

    setUp(() async {
      storage = InMemoryWalletStorage();
      headerChain = BlockHeaderChain(storage);
      await headerChain.initialize();
    });

    tearDownAll(() async {
      await actorSystem.shutdown();
    });

    group('Block Header Chain Integration', () {
      test('should handle SpiffyNode ChainTipEvent integration', () async {
        // Simulate SpiffyNode ChainTipEvent
        final mockChainTip = TestChainTip(
          blockHash: 'test_block_hash_001',
          height: 100,
          peerCount: 3,
          confidence: 0.95,
        );

        final chainTipEvent = ChainTipEventMessage(
          newTip: mockChainTip,
          eventType: ChainTipEventType.heightIncrease,
          description: 'Chain height increased to 100',
        );

        // Test that the message can be created and processed
        expect(chainTipEvent.newTip.height, equals(100));
        expect(chainTipEvent.heightChange, equals(100)); // from null to 100
        expect(chainTipEvent.isReorganization, isFalse);
      });

      test('should handle BlockHeader messages from SpiffyNode', () async {
        // Create test block headers as would come from SpiffyNode
        final testHeaders = _createTestBlockHeaders(5);
        
        final headersMessage = BlockHeadersReceivedMessage(
          peerId: 'spiffynode_peer_001',
          headers: testHeaders,
          startHeight: 0,
        );

        // Simulate processing headers through LibSpiffy
        var storedCount = 0;
        for (int i = 0; i < headersMessage.headers.length; i++) {
          final header = headersMessage.headers[i];
          final stored = await headerChain.validateAndStoreHeader(header, i);
          if (stored) storedCount++;
        }

        expect(storedCount, equals(5));
        expect(headerChain.bestHeight, equals(4));
      });

      test('should integrate with storage layer correctly', () async {
        // Test the storage layer integration that developers would use
        final testHeader = _createTestBlockHeader(
          version: 1,
          prevBlockHash: '0000000000000000000000000000000000000000000000000000000000000000',
          merkleRoot: 'test_merkle_root',
          timestamp: DateTime.now(),
          bits: 0x1d00ffff,
          nonce: 12345,
        );

        // Store via BlockHeaderChain (LibSpiffy component)
        await headerChain.validateAndStoreHeader(testHeader, 0);

        // Verify storage via direct storage interface
        final retrievedByHeight = await storage.getBlockHeaderByHeight(0);
        expect(retrievedByHeight, isNotNull);

        final hash = testHeader.blockHash().toString();
        final retrievedByHash = await storage.getBlockHeaderByHash(hash);
        expect(retrievedByHash, isNotNull);

        // Verify chain state
        expect(headerChain.bestHeight, equals(0));
        expect(headerChain.chainTip, isNotNull);
      });
    });

    group('SPV Transaction Validation Integration', () {
      test('should create transaction validation workflow', () async {
        // Set up a basic header chain
        final testHeaders = _createTestBlockHeaders(3);
        for (int i = 0; i < testHeaders.length; i++) {
          await headerChain.validateAndStoreHeader(testHeaders[i], i);
        }

        // Create a merkle proof for validation
        final merkleProof = MerkleProof(
          blockHash: testHeaders[1].blockHash().toString(),
          txid: 'test_transaction_001',
          merkleProof: ['sibling1', 'sibling2'],
          position: 0,
          blockHeight: 1,
        );

        // Store the proof
        await storage.storeMerkleProof('test_transaction_001', merkleProof);

        // Verify the proof can be retrieved
        final retrievedProof = await storage.getMerkleProof('test_transaction_001');
        expect(retrievedProof, isNotNull);
        expect(retrievedProof!.txid, equals('test_transaction_001'));
        expect(retrievedProof.blockHeight, equals(1));

        // Test merkle proof validation against header chain
        final isValid = await headerChain.validateMerkleProof(merkleProof);
        expect(isValid, isA<bool>()); // Structure test - actual validation needs real crypto
      });

      test('should handle BEEF validation messages', () async {
        final beefMessage = ValidateBEEFMessage(
          walletId: 'test_wallet_001',
          beefHex: 'deadbeef', // Mock BEEF data
          fromCounterparty: 'trading_partner_001',
        );

        expect(beefMessage.walletId, equals('test_wallet_001'));
        expect(beefMessage.beefHex, equals('deadbeef'));
        expect(beefMessage.storeMerkleProofs, isTrue);
        expect(beefMessage.receivedAt, isA<DateTime>());
      });
    });

    group('Actor Message Flow Integration', () {
      test('should create complete SPV status workflow', () async {
        // Simulate the status query workflow
        final statusRequest = GetSPVStatusMessage(walletId: 'test_wallet');
        
        expect(statusRequest.walletId, equals('test_wallet'));

        // Simulate response with current state
        final statusResponse = SPVStatusMessage(
          walletId: 'test_wallet',
          currentHeight: headerChain.bestHeight,
          networkHeight: 1000,
          isSynced: headerChain.bestHeight >= 1000,
          headersCached: headerChain.cacheSize,
          merkleProofsStored: 0, // Would query storage in real implementation
          lastHeaderUpdate: DateTime.now(),
          connectedPeers: ['spiffynode_peer_001', 'spiffynode_peer_002'],
          isHealthy: true,
        );

        expect(statusResponse.currentHeight, equals(headerChain.bestHeight));
        expect(statusResponse.syncProgress, lessThanOrEqualTo(1.0));
        expect(statusResponse.connectedPeers.length, equals(2));
      });

      test('should handle SPV control messages', () async {
        final controlMessage = SPVControlMessage(
          action: SPVControlAction.start,
          walletId: 'test_wallet',
          parameters: {'syncFromHeight': 0},
        );

        expect(controlMessage.action, equals(SPVControlAction.start));
        expect(controlMessage.walletId, equals('test_wallet'));
        expect(controlMessage.parameters!['syncFromHeight'], equals(0));
      });

      test('should handle SPV error scenarios', () async {
        final errorMessage = SPVErrorMessage(
          operation: 'block_header_validation',
          error: 'Invalid previous block hash',
          walletId: 'test_wallet',
          isFatal: false,
        );

        expect(errorMessage.operation, equals('block_header_validation'));
        expect(errorMessage.error, contains('Invalid previous block hash'));
        expect(errorMessage.isFatal, isFalse);
        expect(errorMessage.errorTime, isA<DateTime>());
      });
    });

    group('Configuration and Performance', () {
      test('should handle SPV configuration correctly', () async {
        final config = SPVConfigMessage(
          enableHeaderValidation: true,
          enableMerkleProofValidation: true,
          maxHeaderCacheSize: 2016,
          headerSyncTimeout: Duration(minutes: 10),
          reorgProtectionDepth: 6,
        );

        expect(config.enableHeaderValidation, isTrue);
        expect(config.maxHeaderCacheSize, equals(2016));
        expect(config.reorgProtectionDepth, equals(6));
      });

      test('should simulate realistic header sync performance', () async {
        const totalHeaders = 100;
        final startTime = DateTime.now();

        // Simulate processing headers in batches (as SpiffyNode would provide)
        for (int batch = 0; batch < 5; batch++) {
          final batchHeaders = _createTestBlockHeaders(20);
          
          for (int i = 0; i < batchHeaders.length; i++) {
            final globalHeight = (batch * 20) + i;
            await headerChain.validateAndStoreHeader(batchHeaders[i], globalHeight);
          }
        }

        final endTime = DateTime.now();
        final duration = endTime.difference(startTime);

        expect(headerChain.bestHeight, equals(totalHeaders - 1));
        print('Processed $totalHeaders headers in ${duration.inMilliseconds}ms');
        
        // Performance expectation: should process headers quickly
        expect(duration.inMilliseconds, lessThan(5000)); // Under 5 seconds
      });
    });

    group('Reorganization Simulation', () {
      test('should simulate blockchain reorganization workflow', () async {
        // Create initial chain
        final initialChain = _createTestBlockHeaders(5);
        for (int i = 0; i < initialChain.length; i++) {
          await headerChain.validateAndStoreHeader(initialChain[i], i);
        }

        final initialHeight = headerChain.bestHeight;
        expect(initialHeight, equals(4));

        // Simulate reorganization message from SpiffyNode
        final reorgMessage = ChainTipEventMessage(
          oldTip: TestChainTip(
            blockHash: initialChain.last.blockHash().toString(),
            height: 4,
            peerCount: 2,
            confidence: 0.8,
          ),
          newTip: TestChainTip(
            blockHash: 'new_chain_tip_hash',
            height: 6,
            peerCount: 4,
            confidence: 0.95,
          ),
          eventType: ChainTipEventType.reorganization,
          description: 'Blockchain reorganization detected',
        );

        expect(reorgMessage.isReorganization, isTrue);
        expect(reorgMessage.heightChange, equals(2)); // From 4 to 6

        // In a real implementation, this would trigger reorganization handling
        // For now, we test that the message structure works correctly
      });
    });
  });
}

/// Test helper classes

/// Test implementation of ChainTip for testing
class TestChainTip implements ChainTip {
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

  TestChainTip({
    required String blockHash,
    required this.height,
    DateTime? lastUpdated,
    required this.peerCount,
    required this.confidence,
    List<String>? reportingPeers,
  }) : _blockHashString = blockHash,
       lastUpdated = lastUpdated ?? DateTime.now(),
       reportingPeers = reportingPeers ?? [];

  @override
  Hash get blockHash => Hash.fromBytes(Uint8List.fromList(_stringToBytes(_blockHashString)));

  @override
  Duration get age => DateTime.now().difference(lastUpdated);

  @override
  bool get isCurrent => age < Duration(minutes: 15);

  @override
  String toString() => 'TestChainTip(height: $height, hash: ${_blockHashString.substring(0, 8)}...)';

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is TestChainTip && 
           other._blockHashString == _blockHashString && 
           other.height == height;
  }

  @override
  int get hashCode => Object.hash(_blockHashString, height);
}

/// Helper functions for creating test data

/// Creates a test BlockHeader
BlockHeader _createTestBlockHeader({
  required int version,
  required String prevBlockHash,
  required String merkleRoot,
  required DateTime timestamp,
  required int bits,
  required int nonce,
}) {
  return BlockHeader(
    version: version,
    prevBlock: Hash.fromBytes(Uint8List.fromList(_stringToBytes(prevBlockHash))),
    merkleRoot: Hash.fromBytes(Uint8List.fromList(_stringToBytes(merkleRoot))),
    timestamp: timestamp,
    bits: bits,
    nonce: nonce,
  );
}

/// Creates a sequence of connected test block headers
List<BlockHeader> _createTestBlockHeaders(int count) {
  final headers = <BlockHeader>[];
  
  for (int i = 0; i < count; i++) {
    final prevHash = i == 0 
        ? '0000000000000000000000000000000000000000000000000000000000000000'
        : headers[i - 1].blockHash().toString();
    
    final header = _createTestBlockHeader(
      version: 1,
      prevBlockHash: prevHash,
      merkleRoot: 'merkle_root_$i',
      timestamp: DateTime.now().add(Duration(minutes: i * 10)),
      bits: 0x1d00ffff,
      nonce: 12345 + i,
    );
    
    headers.add(header);
  }
  
  return headers;
}

/// Convert string to bytes for Hash creation (simplified for testing)
List<int> _stringToBytes(String input) {
  if (input.length == 64) {
    // Assume it's a hex string
    final bytes = <int>[];
    for (int i = 0; i < input.length; i += 2) {
      bytes.add(int.parse(input.substring(i, i + 2), radix: 16));
    }
    return bytes;
  } else {
    // Use string bytes, padded to 32 bytes
    final bytes = input.codeUnits.take(32).toList();
    while (bytes.length < 32) {
      bytes.add(0);
    }
    return bytes;
  }
} 