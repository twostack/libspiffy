import 'package:convert/convert.dart';
import 'package:test/test.dart';
import 'package:mockito/mockito.dart';
import 'package:mockito/annotations.dart';
import 'package:libspiffy/libspiffy.dart';
import 'package:spiffynode/src/spv/chain_tip_tracker.dart';
import 'package:spiffynode/src/chaincfg/hash.dart';
import 'dart:typed_data';

// Generate mocks for external dependencies
@GenerateMocks([ArcService, ChainTipTracker, BlockHeaderService])
import 'spv_service_test.mocks.dart';


void main() {
  group('SPVService', () {
    late SPVService service;
    late MockArcService mockArcService;
    late MockChainTipTracker mockChainTipTracker;
    late MockBlockHeaderService mockBlockHeaderService;

    setUp(() {
      mockArcService = MockArcService();
      mockChainTipTracker = MockChainTipTracker();
      mockBlockHeaderService = MockBlockHeaderService();
      
      // Setup default mock stubs for ChainTipTracker
      when(mockChainTipTracker.tipEvents)
          .thenAnswer((_) => Stream<ChainTipEvent>.empty());
      when(mockChainTipTracker.networkHeight).thenReturn(750000);
      when(mockChainTipTracker.isLikelySynced).thenReturn(true);
      
      // Setup default mock stubs for ArcService
      when(mockArcService.getMerkleProof(any)).thenAnswer((_) async => 
        ArcMerkleProofResponse(
          txid: 'test_txid',
          merklePath: [],
          merkleRoot: '4a5e1e4baab89f3a32518a88c31bc87f618f76673e2cc77ab2127b7afdeda33b',
          blockHeight: 100,
          blockHash: 'test_block_hash',
        ));
      
      service = SPVService(
        arcService: mockArcService,
        chainTipTracker: mockChainTipTracker,
        blockHeaderService: mockBlockHeaderService,
      );
    });

    group('Confirmation Tracking', () {
      test('should track transaction confirmations correctly', () async {
        // Arrange
        const txId = 'test_tx_id';
        final mockStream = Stream<ChainTipEvent>.fromIterable([
          ChainTipEvent(
            newTip: ChainTip(
              blockHash: Hash.fromHex('000000000000000000000000000000000000000000000000000000000000000a'),
              height: 101,
              lastUpdated: DateTime.now(),
              peerCount: 1,
              confidence: 1.0,
              reportingPeers: ['peer1'],
            ),
            oldTip: ChainTip(
              blockHash: Hash.fromHex('0000000000000000000000000000000000000000000000000000000000000009'),
              height: 100,
              lastUpdated: DateTime.now().subtract(Duration(minutes: 1)),
              peerCount: 1,
              confidence: 1.0,
              reportingPeers: ['peer1'],
            ),
            type: ChainTipEventType.heightIncrease,
            description: 'Height increased from 100 to 101',
          ),
        ]);
        
        when(mockChainTipTracker.tipEvents).thenAnswer((_) => mockStream);
        when(mockChainTipTracker.bestTip).thenReturn(ChainTip(
          blockHash: Hash.fromHex('000000000000000000000000000000000000000000000000000000000000000b'),
          height: 102,
          lastUpdated: DateTime.now(),
          peerCount: 1,
          confidence: 1.0,
          reportingPeers: ['peer1'],
        ));
        
        // Start tracking
        await service.trackConfirmations(txId);
        
        // Act & Assert
        final confirmationStream = service.confirmationUpdates
            .where((update) => update.txid == txId);
        await expectLater(
          confirmationStream.take(1),
          emits(predicate<TransactionConfirmationUpdate>((update) =>
            update.txid == txId && update.confirmations >= 1)),
        );
      });

      test('should handle chain reorganizations', () async {
        // Arrange
        const txId = 'reorg_tx_id';
        final reorgEvent = ChainTipEvent(
          newTip: ChainTip(
            blockHash: Hash.fromHex('000000000000000000000000000000000000000000000000000000000000000c'),
            height: 100,
            lastUpdated: DateTime.now(),
            peerCount: 1,
            confidence: 1.0,
            reportingPeers: ['peer1'],
          ),
          oldTip: ChainTip(
            blockHash: Hash.fromHex('000000000000000000000000000000000000000000000000000000000000000d'),
            height: 100,
            lastUpdated: DateTime.now().subtract(Duration(minutes: 1)),
            peerCount: 1,
            confidence: 1.0,
            reportingPeers: ['peer1'],
          ),
          type: ChainTipEventType.reorganization,
          description: 'Chain reorganization detected',
        );
        
        when(mockChainTipTracker.tipEvents)
            .thenAnswer((_) => Stream.fromIterable([reorgEvent]));
            
        // Mock re-validation after reorg
        when(mockArcService.getMerkleProof(txId))
            .thenAnswer((_) async => ArcMerkleProofResponse(
              txid: txId,
              merklePath: ['path1', 'path2'],
              merkleRoot: '4a5e1e4baab89f3a32518a88c31bc87f618f76673e2cc77ab2127b7afdeda33b',
              blockHeight: 99,
              blockHash: 'reorg_block_hash',
            ));
        
        await service.trackConfirmations(txId);
        
        // Act & Assert
        final confirmationStream = service.confirmationUpdates
            .where((update) => update.txid == txId);
        await expectLater(
          confirmationStream.take(1),
          emits(predicate<TransactionConfirmationUpdate>((update) =>
            update.reorgDetected == true)),
        );
      });
    });

    group('Network Statistics', () {
      test('should provide accurate network statistics', () {
        // Arrange
        when(mockChainTipTracker.bestTip).thenReturn(ChainTip(
          blockHash: Hash.fromHex('000000000000000000000000000000000000000000000000000000000000000e'),
          height: 750000,
          lastUpdated: DateTime.now(),
          peerCount: 3,
          confidence: 1.0,
          reportingPeers: ['peer1', 'peer2', 'peer3'],
        ));
        when(mockChainTipTracker.isLikelySynced).thenReturn(true);
        
        // Act
        final stats = service.getNetworkStatistics();
        
        // Assert
        expect(stats['networkHeight'], equals(750000));
        expect(stats['activePeers'], equals(3));
        expect(stats['isNetworkSynced'], isTrue);
      });

      test('should handle no connected peers', () {
        // Arrange
        when(mockChainTipTracker.bestTip).thenReturn(null);
        when(mockChainTipTracker.isLikelySynced).thenReturn(false);
        
        // Act
        final stats = service.getNetworkStatistics();
        
        // Assert
        expect(stats['networkHeight'], equals(0));
        expect(stats['activePeers'], equals(0));
        expect(stats['isNetworkSynced'], isFalse);
      });
    });

    group('Transaction Inclusion Verification', () {
      test('should verify transaction inclusion against block headers', () async {
        // Arrange
        const txId = 'inclusion_test_tx';
        const blockHeight = 500;
        
        when(mockBlockHeaderService.getMerkleRoot(blockHeight))
            .thenReturn('valid_merkle_root');
            
        when(mockArcService.getMerkleProof(txId))
            .thenAnswer((_) async => ArcMerkleProofResponse(
              txid: txId,
              merklePath: ['path1', 'path2'],
              merkleRoot: 'valid_merkle_root',
              blockHeight: blockHeight,
              blockHash: 'block_hash',
            ));
        
        // Act
        final isIncluded = await service.verifyTransactionInclusion(txId, blockHeight);
        
        // Assert
        expect(isIncluded, isTrue);
        verify(mockArcService.getMerkleProof(txId)).called(1);
        verify(mockBlockHeaderService.getMerkleRoot(blockHeight)).called(1);
      });

      test('should reject verification for missing block header', () async {
        // Arrange
        const txId = 'missing_header_tx';
        const blockHeight = 999999;
        
        when(mockBlockHeaderService.getMerkleRoot(blockHeight))
            .thenReturn(null);
        
        // Act
        final isIncluded = await service.verifyTransactionInclusion(txId, blockHeight);
        
        // Assert
        expect(isIncluded, isFalse);
        verifyNever(mockArcService.getMerkleProof(any));
      });
    });

    group('Error Handling', () {
      test('should handle ARC service failures gracefully', () async {
        // Arrange
        const txId = 'failing_tx';
        when(mockArcService.getMerkleProof(txId))
            .thenThrow(ArcException('Service unavailable'));
        
        // Act & Assert
        expect(
          () => service.verifyTransactionInclusion(txId, 100),
          throwsA(isA<SPVException>()),
        );
      });

      test('should handle malformed BEEF data', () async {
        // Arrange
        final invalidBeef = Uint8List.fromList([0xFF, 0xFF, 0xFF]);
        
        // Act & Assert
        expect(
          () => BEEF.parse(invalidBeef),
          throwsA(isA<BEEFException>()),
        );
      });

      test('should handle malformed BUMP data', () async {
        // Arrange
        final invalidBump = Uint8List.fromList([0x00, 0x01]);
        
        // Act & Assert
        expect(
          () => BUMP.fromBytes(invalidBump),
          throwsA(isA<BUMPException>()),
        );
      });
    });
  });
}


// Helper methods for creating test data


Uint8List _createInvalidBEEF() {
  // Create intentionally invalid BEEF for testing error cases
  return Uint8List.fromList([0x00, 0x00, 0x00, 0xFF]);
}

Uint8List _createTestBUMP() {
  // Create a minimal valid BUMP structure for testing
  final writer = ByteDataWriter();
  
  // Block height (VarInt format)
  writer.writeVarInt(100);
  
  // Tree height (single byte)
  writer.writeUint8(2);
  
  // Level 0
  writer.writeVarInt(1); // Number of leaves
  writer.writeVarInt(0); // Offset
  writer.writeUint8(0x02); // Flags (isTxid = true)
  writer.writeBytes(Uint8List.fromList(hex.decode('a1b2c3d4e5f6789012345678901234567890123456789012345678901234567890'))); // 32-byte txid
  
  // Level 1
  writer.writeVarInt(1); // Number of leaves
  writer.writeVarInt(0); // Offset
  writer.writeUint8(0x00); // Flags (normal hash)
  writer.writeBytes(Uint8List.fromList(hex.decode('4a5e1e4baab89f3a32518a88c31bc87f618f76673e2cc77ab2127b7afdeda33b'))); // 32-byte merkle root
  
  return writer.takeBytes();
}

Uint8List _createInvalidBUMP() {
  // Create intentionally invalid BUMP for testing error cases
  return Uint8List.fromList([0xFF, 0xFF]);
}


// Helper class for creating BEEF/BUMP test data
class ByteDataWriter {
  final List<int> _buffer = <int>[];

  void writeUint8(int value) {
    _buffer.add(value & 0xFF);
  }

  void writeUint16(int value, Endian endian) {
    if (endian == Endian.little) {
      _buffer.add(value & 0xFF);
      _buffer.add((value >> 8) & 0xFF);
    } else {
      _buffer.add((value >> 8) & 0xFF);
      _buffer.add(value & 0xFF);
    }
  }

  void writeUint32(int value, Endian endian) {
    if (endian == Endian.little) {
      _buffer.add(value & 0xFF);
      _buffer.add((value >> 8) & 0xFF);
      _buffer.add((value >> 16) & 0xFF);
      _buffer.add((value >> 24) & 0xFF);
    } else {
      _buffer.add((value >> 24) & 0xFF);
      _buffer.add((value >> 16) & 0xFF);
      _buffer.add((value >> 8) & 0xFF);
      _buffer.add(value & 0xFF);
    }
  }

  void writeBytes(Uint8List bytes) {
    _buffer.addAll(bytes);
  }

  void writeVarInt(int value) {
    if (value < 0xFD) {
      writeUint8(value);
    } else if (value <= 0xFFFF) {
      writeUint8(0xFD);
      writeUint16(value, Endian.little);
    } else if (value <= 0xFFFFFFFF) {
      writeUint8(0xFE);
      writeUint32(value, Endian.little);
    } else {
      writeUint8(0xFF);
      writeUint64(value, Endian.little);
    }
  }

  void writeUint64(int value, Endian endian) {
    if (endian == Endian.little) {
      _buffer.add(value & 0xFF);
      _buffer.add((value >> 8) & 0xFF);
      _buffer.add((value >> 16) & 0xFF);
      _buffer.add((value >> 24) & 0xFF);
      _buffer.add((value >> 32) & 0xFF);
      _buffer.add((value >> 40) & 0xFF);
      _buffer.add((value >> 48) & 0xFF);
      _buffer.add((value >> 56) & 0xFF);
    } else {
      _buffer.add((value >> 56) & 0xFF);
      _buffer.add((value >> 48) & 0xFF);
      _buffer.add((value >> 40) & 0xFF);
      _buffer.add((value >> 32) & 0xFF);
      _buffer.add((value >> 24) & 0xFF);
      _buffer.add((value >> 16) & 0xFF);
      _buffer.add((value >> 8) & 0xFF);
      _buffer.add(value & 0xFF);
    }
  }

  Uint8List takeBytes() {
    return Uint8List.fromList(_buffer);
  }
} 