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
      headerChain = BlockHeaderChain(storage, skipProofOfWorkValidation: true);
      await headerChain.initialize();
    });

    tearDownAll(() async {
      await actorSystem.shutdown();
    });

    group('Block Header Chain Integration', () {
      // A reorganization across the whole system is covered by
      // header_sync_e2e_test ('should handle blockchain reorganization
      // across full system') and by the chain's own fork-choice tests; the
      // test that used to sit here built a message and asserted its own
      // getters, and said so in a comment.
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

        // The proof's siblings are not hashes of anything in this header,
        // so it does not verify: the chain says so rather than taking the
        // claim (it used to assert only that a bool came back).
        expect(await headerChain.validateMerkleProof(merkleProof), isFalse);
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
        expect(statusResponse.syncProgress, closeTo(headerChain.bestHeight / 1000, 1e-9),
            reason: 'progress is how far the headers we hold reach towards the network height');
        expect(statusResponse.connectedPeers.length, equals(2));
      });

    });

    group('Configuration and Performance', () {
      test('a chain of headers arriving in batches is accepted in order', () async {
        // One chain, delivered twenty at a time as a peer would. It used to
        // be five separate twenty-header chains stored at made-up heights
        // (0..99), which the chain accepted while heights came from the
        // caller; each header's height is derived from its parent now, so
        // only the first batch ever linked and the rest were rejected.
        const totalHeaders = 100;
        final chain = _createTestBlockHeaders(totalHeaders);

        for (var batch = 0; batch < 5; batch++) {
          for (var i = 0; i < 20; i++) {
            final height = (batch * 20) + i;
            expect(await headerChain.validateAndStoreHeader(chain[height], height), isTrue,
                reason: 'header $height was not accepted');
          }
        }

        expect(headerChain.bestHeight, equals(totalHeaders - 1));
        expect(headerChain.chainTip?.blockHash().toString(),
            equals(chain.last.blockHash().toString()));
        expect(await storage.getBlockHeaderByHeight(totalHeaders - 1), isNotNull);
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
    // Assume it's a hex string - convert and reverse for Bitcoin's little-endian format
    final bytes = <int>[];
    for (int i = 0; i < input.length; i += 2) {
      bytes.add(int.parse(input.substring(i, i + 2), radix: 16));
    }
    return bytes.reversed.toList(); // Reverse for little-endian
  } else {
    // Use string bytes, padded to 32 bytes
    final bytes = input.codeUnits.take(32).toList();
    while (bytes.length < 32) {
      bytes.add(0);
    }
    return bytes;
  }
} 