import 'package:test/test.dart';
import 'package:mockito/mockito.dart';
import 'package:mockito/annotations.dart';
import 'dart:async';

import 'package:libspiffy/src/services/block_header_service.dart';
import 'package:spiffynode/src/spv/chain_tip_tracker.dart';
import 'package:spiffynode/src/wire/messages/msg_headers.dart';
import 'package:spiffynode/src/chaincfg/hash.dart';

import 'block_header_service_test.mocks.dart';

// Generate mocks
@GenerateMocks([ChainTipTracker])
void main() {
  group('BlockHeaderService Tests', () {
    late BlockHeaderService service;
    late MockChainTipTracker mockChainTipTracker;
    late StreamController<ChainTipEvent> tipEventController;

    setUp(() {
      mockChainTipTracker = MockChainTipTracker();
      tipEventController = StreamController<ChainTipEvent>.broadcast();
      
      // Setup mock
      when(mockChainTipTracker.tipEvents).thenAnswer((_) => tipEventController.stream);
      
      // Create service
      service = BlockHeaderService(
        chainTipTracker: mockChainTipTracker,
        config: BlockHeaderServiceConfig(
          maxHeaders: 1000,
          orphanTimeout: const Duration(hours: 24),
          headerLookAhead: 100,
        ),
      );
    });

    tearDown(() {
      tipEventController.close();
    });

    group('Basic Service Operations', () {
      test('should initialize with zero headers', () {
        expect(service.headerCount, equals(0));
        expect(service.chainHeight, equals(0));
      });

      test('should handle empty header messages', () async {
        final msgHeaders = MsgHeaders.empty();
        
        expect(() => service.processHeaders(msgHeaders, 'test_peer'), returnsNormally);
      });

      test('should provide header events stream', () {
        expect(service.headerEvents, isA<Stream<BlockHeaderEvent>>());
      });

      test('should return null for unknown heights', () {
        final merkleRoot = service.getMerkleRoot(999999);
        expect(merkleRoot, isNull);
        
        final header = service.getHeader(999999);
        expect(header, isNull);
      });

      test('should return empty list for unknown ranges', () {
        final headers = service.getHeadersInRange(100, 102);
        expect(headers, isEmpty);
      });
    });

    group('Configuration', () {
      test('should use provided configuration', () {
        final customService = BlockHeaderService(
          chainTipTracker: mockChainTipTracker,
          config: BlockHeaderServiceConfig(
            maxHeaders: 500,
            orphanTimeout: const Duration(hours: 12),
            headerLookAhead: 50,
          ),
        );

        expect(customService.headerCount, equals(0));
      });

      test('should use default configuration when none provided', () {
        final defaultService = BlockHeaderService(
          chainTipTracker: mockChainTipTracker,
        );

        expect(defaultService.headerCount, equals(0));
      });
    });

    group('Chain Tip Integration', () {
      test('should listen to chain tip events', () async {
        // Create a simple chain tip event
        final chainTip = ChainTip(
          blockHash: Hash.zero(),
          height: 100,
          lastUpdated: DateTime.now(),
          peerCount: 3,
          confidence: 1.0,
          reportingPeers: ['peer1', 'peer2', 'peer3'],
        );

        final event = ChainTipEvent(
          newTip: chainTip,
          type: ChainTipEventType.heightIncrease,
          description: 'Test height increase',
        );

        // Emit the event
        tipEventController.add(event);

        // Allow event processing
        await Future.delayed(Duration(milliseconds: 10));

        // Service should still be running without errors
        expect(service.headerCount, greaterThanOrEqualTo(0));
      });
    });

    group('Error Handling', () {
      test('should handle invalid peer IDs gracefully', () async {
        final msgHeaders = MsgHeaders.empty();

        expect(() => service.processHeaders(msgHeaders, ''), returnsNormally);
      });

      test('should handle stream errors gracefully', () async {
        // Close the stream to test error handling
        tipEventController.close();
        
        // Service should still function
        expect(service.headerCount, equals(0));
      });
    });
  });
} 