import 'dart:async';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:logging/logging.dart';
import 'package:dactor/dactor.dart';
import 'package:spiffynode/spiffy_node.dart';

import 'package:libspiffy/src/actors/header_sync_actor.dart';
import 'package:libspiffy/src/actors/spv_messages.dart';
import 'package:libspiffy/src/actors/wallet_messages.dart' show HeaderChainReorganizedMessage;
import 'package:libspiffy/src/spv/network_params.dart';
import 'package:libspiffy/src/storage/wallet_storage.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';
import 'package:libspiffy/src/spv/block_header_chain.dart';

import '../spv/regtest_chain_builder.dart';

/// Integration tests for HeaderSyncActor
///
/// These tests verify:
/// 1. Actor message handling (BlockHeadersReceivedMessage, ChainTipEventMessage, etc.)
/// 2. BlockHeaderChain integration and coordination
/// 3. SPV actor communication and status reporting
/// 4. Error handling and recovery
/// 5. Reorganization handling (SPV-03)
///
/// The chain runs with regtest consensus rules; every synthetic header is
/// mined with real (cheap) proof of work on top of the regtest genesis.
void main() {
  // Set up logging for tests
  Logger.root.level = Level.WARNING; // Reduce noise in tests
  Logger.root.onRecord.listen((record) {
    if (record.level >= Level.SEVERE) {
      print('${record.level.name}: ${record.time}: ${record.message}');
    }
  });

  final regtest = NetworkParams.regtest;
  final genesis = regtest.genesisHeader;
  DateTime clock() => genesis.timestamp.add(const Duration(days: 365));

  group('HeaderSyncActor Integration Tests', () {
    late ActorSystem actorSystem;
    late WalletStorage storage;
    late BlockHeaderChain headerChain;
    late ActorRef headerSyncActor;
    late ActorRef mockSPVActor;
    late _MockSPVActor spvInstance;

    setUpAll(() async {
      // Initialize actor system
      actorSystem = LocalActorSystem();
    });

    setUp(() async {
      // Initialize storage and header chain
      storage = InMemoryWalletStorage();
      headerChain = BlockHeaderChain(storage, params: regtest, clock: clock);
      await headerChain.initialize();

      // Create a mock SPV actor to receive messages
      spvInstance = _MockSPVActor();
      mockSPVActor = await actorSystem.spawn('mock-spv', () => spvInstance);

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
        final headers = RegtestMiner.mineChain(genesis, 3);

        // Send headers to actor
        final message = BlockHeadersReceivedMessage(
          peerId: 'test-peer-1',
          headers: headers,
          startHeight: 1,
          isReorganization: false,
        );

        headerSyncActor.tell(message as dynamic);

        // Wait for processing
        await Future.delayed(Duration(milliseconds: 500));

        // Verify headers were stored through the actor
        expect(headerChain.bestHeight, equals(3));
        expect(headerChain.chainTip!.blockHash(), equals(headers.last.blockHash()));
        expect(headerChain.cacheSize, equals(4)); // genesis + 3

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

        expect(spvInstance.receivedMessages.whereType<ChainTipEventMessage>(), isNotEmpty);
      });

      test('should handle GetSPVStatusMessage and respond with current status', () async {
        final header = RegtestMiner.mine(parent: genesis);
        await headerChain.validateAndStoreHeader(header, 1);

        // SPVStatusMessage is not a LocalMessage, so it cannot be awaited
        // with ask; the reply goes to the sender via tell.
        headerSyncActor.tell(GetSPVStatusMessage() as dynamic);
        await Future.delayed(Duration(milliseconds: 100));
        expect(headerChain.bestHeight, equals(1));
      });

      test('should handle RequestHeaderSyncMessage and respond with sync status', () async {
        final headers = RegtestMiner.mineChain(genesis, 5);
        for (int i = 0; i < headers.length; i++) {
          await headerChain.validateAndStoreHeader(headers[i], i + 1);
        }

        // HeaderSyncStatusMessage is not a LocalMessage (no ask); the actor
        // must stay responsive after the request.
        headerSyncActor.tell(RequestHeaderSyncMessage(fromHeight: 3) as dynamic);
        await Future.delayed(Duration(milliseconds: 100));
        expect(headerChain.bestHeight, equals(5));
      });
    });

    group('Specific header requests', () {
      test('is answered when the requested header arrives in a later batch', () async {
        final headers = RegtestMiner.mineChain(genesis, 6);

        // Heights 1-3 are synced; 4+ are not.
        headerSyncActor.tell(BlockHeadersReceivedMessage(
          peerId: 'test-peer-1',
          headers: headers.take(3).toList(),
          startHeight: 1,
          isReorganization: false,
        ) as dynamic);
        await Future.delayed(Duration(milliseconds: 300));
        expect(headerChain.bestHeight, equals(3));

        // A peer that answers getHeaders by delivering the rest through the
        // actor's own mailbox, exactly as the SpiffyNode bridge does.
        final peerManager = _FakePeerManager(onGetHeaders: (_) {
          headerSyncActor.tell(BlockHeadersReceivedMessage(
            peerId: 'fake-peer',
            headers: headers.skip(3).take(3).toList(),
            startHeight: 4,
            isReorganization: false,
          ) as dynamic);
        });
        headerSyncActor.tell(SetPeerManagerMessage(peerManager));

        // Before the fix this polled storage from inside the handler and could
        // never observe the batch, so it always timed out.
        final response = await headerSyncActor.ask<SpecificHeaderResponseMessage>(
          RequestSpecificHeaderMessage(
            blockHeight: 5,
            timeout: const Duration(seconds: 5),
          ),
          const Duration(seconds: 8),
        );

        expect(response.success, isTrue, reason: response.error);
        expect(response.blockHeight, equals(5));
        expect(response.header, isNotNull);
        expect(peerManager.getHeadersRequests, equals(1));
      });

      test('fails with a timeout when no peer delivers the header', () async {
        final headers = RegtestMiner.mineChain(genesis, 3);
        headerSyncActor.tell(BlockHeadersReceivedMessage(
          peerId: 'test-peer-1',
          headers: headers,
          startHeight: 1,
          isReorganization: false,
        ) as dynamic);
        await Future.delayed(Duration(milliseconds: 300));

        headerSyncActor.tell(SetPeerManagerMessage(_FakePeerManager(onGetHeaders: (_) {})));

        final pendingFuture = headerSyncActor.ask<SpecificHeaderResponseMessage>(
          RequestSpecificHeaderMessage(
            blockHeight: 5,
            timeout: const Duration(milliseconds: 500),
          ),
          const Duration(seconds: 5),
        );

        // The actor must not be blocked while the request is parked: a
        // request for a header it already has is answered immediately.
        final stopwatch = Stopwatch()..start();
        final synced = await headerSyncActor.ask<SpecificHeaderResponseMessage>(
          RequestSpecificHeaderMessage(blockHeight: 2),
          const Duration(seconds: 5),
        );
        stopwatch.stop();
        expect(synced.success, isTrue, reason: synced.error);
        expect(stopwatch.elapsedMilliseconds, lessThan(400));

        final response = await pendingFuture;
        expect(response.success, isFalse);
        expect(response.error, contains('Timeout'));
      });
    });

    group('Sync in-progress flag', () {
      test('a sync attempt with no connected peers does not block later syncs', () async {
        // First attempt: peer manager is set but has no connected peers.
        final noPeers = _FakePeerManager(onGetHeaders: (_) {}, hasPeers: false);
        headerSyncActor.tell(SetPeerManagerMessage(noPeers));
        headerSyncActor.tell(InitiateHeaderSyncMessage());
        await Future.delayed(Duration(milliseconds: 200));
        expect(noPeers.getHeadersRequests, equals(0));

        // A peer connects and sync is requested again. Before the fix the
        // first attempt had already set _syncInProgress = true before it
        // discovered there were no peers, so this (and every later) request
        // was skipped as a "duplicate" and getHeaders was never sent.
        final withPeer = _FakePeerManager(onGetHeaders: (_) {});
        headerSyncActor.tell(SetPeerManagerMessage(withPeer));
        headerSyncActor.tell(InitiateHeaderSyncMessage());
        await Future.delayed(Duration(milliseconds: 200));

        expect(withPeer.getHeadersRequests, equals(1),
            reason: 'getHeaders must be sent once a peer is available');
      });

      // Bead libspiffy-3pyc: one request at a time, until it is answered.
      test('a request in flight holds off another until its answer, even an empty one, arrives', () async {
        final peer = _FakePeerManager(onGetHeaders: (_) {});
        headerSyncActor.tell(SetPeerManagerMessage(peer));
        headerSyncActor.tell(InitiateHeaderSyncMessage());
        headerSyncActor.tell(InitiateHeaderSyncMessage());
        await Future.delayed(Duration(milliseconds: 200));
        expect(peer.getHeadersRequests, 1);

        headerSyncActor.tell(BlockHeadersReceivedMessage(peerId: 'peer', headers: const [], startHeight: 0));
        headerSyncActor.tell(InitiateHeaderSyncMessage());
        await Future.delayed(Duration(milliseconds: 200));
        expect(peer.getHeadersRequests, 2, reason: 'the empty answer ended the first request');
      });

      test('a request never answered expires, and the next sync asks again', () async {
        await actorSystem.stop(headerSyncActor);
        headerSyncActor = await actorSystem.spawn('header-sync-expiring', () => HeaderSyncActor(
          headerChain: headerChain,
          spvActor: mockSPVActor,
          syncRequestTimeout: const Duration(milliseconds: 300),
        ));
        final peer = _FakePeerManager(onGetHeaders: (_) {});
        headerSyncActor.tell(SetPeerManagerMessage(peer));
        headerSyncActor.tell(InitiateHeaderSyncMessage());
        await Future.delayed(Duration(milliseconds: 100));
        headerSyncActor.tell(InitiateHeaderSyncMessage());
        await Future.delayed(Duration(milliseconds: 100));
        expect(peer.getHeadersRequests, 1, reason: 'still waiting for the first answer');

        await Future.delayed(Duration(milliseconds: 300));
        headerSyncActor.tell(InitiateHeaderSyncMessage());
        await Future.delayed(Duration(milliseconds: 100));
        expect(peer.getHeadersRequests, 2, reason: 'the unanswered request held off every later sync');
      });
    });

    group('Error Handling', () {
      test('should handle invalid headers gracefully', () async {
        final valid = RegtestMiner.mine(parent: genesis);
        // A header whose parent is not known.
        final invalidHeader = RegtestMiner.mine(parent: RegtestMiner.mine(parent: valid, seed: 'x'));

        final message = BlockHeadersReceivedMessage(
          peerId: 'test-peer-invalid',
          headers: [valid, invalidHeader],
          startHeight: 1,
          isReorganization: false,
        );

        headerSyncActor.tell(message as dynamic);

        // Wait for processing
        await Future.delayed(Duration(milliseconds: 500));

        // Only the first (valid) header is stored.
        expect(headerChain.bestHeight, equals(1));
        expect(headerChain.cacheSize, equals(2));
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
        final freshHeaderChain = BlockHeaderChain(freshStorage, params: regtest, clock: clock);
        // Don't call initialize()

        final freshActor = await actorSystem.spawn('fresh-header-sync', () => HeaderSyncActor(
          headerChain: freshHeaderChain,
          spvActor: null, // No SPV actor
        ));

        // Send message before initialization is complete
        final message = BlockHeadersReceivedMessage(
          peerId: 'early-peer',
          headers: [RegtestMiner.mine(parent: genesis)],
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

        final chain = RegtestMiner.mineChain(genesis, batchCount * headersPerBatch);

        // Create multiple batches of headers
        final futures = <Future>[];

        for (int batch = 0; batch < batchCount; batch++) {
          final startHeight = batch * headersPerBatch + 1;
          final headers = chain.sublist(batch * headersPerBatch, (batch + 1) * headersPerBatch);

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

        // The mailbox serializes the batches, so every header is stored.
        expect(headerChain.bestHeight, equals(batchCount * headersPerBatch));
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

        // Actor should still be responsive: a header it already holds is
        // answered through the ask-capable SpecificHeaderResponseMessage.
        final response = await headerSyncActor.ask<SpecificHeaderResponseMessage>(
          RequestSpecificHeaderMessage(blockHeight: 0),
          const Duration(seconds: 5),
        );
        expect(response.success, isTrue, reason: response.error);
      });
    });

    group('BlockHeaderChain Integration', () {
      test('should properly coordinate with BlockHeaderChain for validation', () async {
        // Real mainnet headers 0-6 on a mainnet-anchored chain.
        final mainStorage = InMemoryWalletStorage();
        final mainChain = BlockHeaderChain(mainStorage, params: NetworkParams.mainnet);
        await mainChain.initialize();
        final mainActor = await actorSystem.spawn('header-sync-main', () => HeaderSyncActor(
          headerChain: mainChain,
          spvActor: mockSPVActor,
        ));
        await Future.delayed(Duration(milliseconds: 100));

        final headers = loadFirstMainnetHeaders();

        // Send headers one batch at a time to ensure proper chaining
        for (int i = 0; i < headers.length; i += 3) {
          final batch = headers.skip(i).take(3).toList();
          final message = BlockHeadersReceivedMessage(
            peerId: 'chain-peer',
            headers: batch,
            startHeight: i, // Start from 0 for genesis block
            isReorganization: false,
          );

          mainActor.tell(message as dynamic);

          // Wait between batches to ensure ordered processing
          await Future.delayed(Duration(milliseconds: 100));
        }

        // Final wait for processing
        await Future.delayed(Duration(milliseconds: 200));

        // Verify chain integrity
        expect(mainChain.bestHeight, equals(6)); // 7 headers: heights 0-6

        // Verify we can retrieve headers by height
        for (int i = 0; i < 7; i++) {
          final header = await mainChain.getHeaderByHeight(i);
          expect(header, isNotNull, reason: 'Header at height $i should exist');
          expect(header!.blockHash(), equals(headers[i].blockHash()));
        }
        await actorSystem.stop(mainActor);
      });
    });

    group('SPV-03 reorganization', () {
      test('a batch arriving after a reorg is stored at the heights its parents dictate, '
          'not at bestHeight + 1', () async {
        final a = RegtestMiner.mineChain(genesis, 3, seed: 'A'); // heights 1..3
        headerSyncActor.tell(BlockHeadersReceivedMessage(
          peerId: 'peer-a',
          headers: a,
          startHeight: 1,
        ) as dynamic);
        await Future.delayed(Duration(milliseconds: 300));
        expect(headerChain.bestHeight, equals(3));

        // The peer reorganized onto B, which forks at height 1. Its reply
        // to getHeaders starts at the fork point. The old bridge labelled
        // every batch bestHeight + 1 = 4, and the old chain then compared
        // B2's parent with the header at height 3 and dropped the batch.
        final b = RegtestMiner.mineChain(a[0], 3, seed: 'B'); // heights 2..4
        headerSyncActor.tell(BlockHeadersReceivedMessage(
          peerId: 'peer-b',
          headers: b,
          startHeight: 4, // what the old bridge would have sent
        ) as dynamic);
        await Future.delayed(Duration(milliseconds: 300));

        expect(headerChain.bestHeight, equals(4));
        expect(headerChain.chainTip!.blockHash(), equals(b[2].blockHash()));
        expect((await headerChain.getHeaderByHeight(2))!.blockHash(), equals(b[0].blockHash()));
        expect((await headerChain.getHeaderByHeight(3))!.blockHash(), equals(b[1].blockHash()));
        expect(await headerChain.getHeaderByHash(a[2].blockHash().toString()), isNull,
            reason: 'A2/A3 are orphaned');

        // The SPV actor is told the stored header was part of a reorg.
        final stored = spvInstance.receivedMessages.whereType<BlockHeaderStoredMessage>().toList();
        expect(stored.last.isReorg, isTrue);
        expect(stored.last.height, equals(4));
      });

      // A-L2 / 3b0: the reorganization used to stop at the header chain;
      // SPVActor was only told `isReorg` and did nothing with it.
      test('a reorganizing batch tells the SPV actor the fork height and the orphaned blocks, '
          'before the stored-header notification', () async {
        final a = RegtestMiner.mineChain(genesis, 3, seed: 'A'); // heights 1..3
        headerSyncActor.tell(BlockHeadersReceivedMessage(
          peerId: 'peer-a', headers: a, startHeight: 1) as dynamic);
        await Future.delayed(Duration(milliseconds: 300));
        expect(spvInstance.receivedMessages.whereType<HeaderChainReorganizedMessage>(), isEmpty,
            reason: 'extending the chain is not a reorganization');

        final b = RegtestMiner.mineChain(a[0], 3, seed: 'B'); // heights 2..4
        headerSyncActor.tell(BlockHeadersReceivedMessage(
          peerId: 'peer-b', headers: b, startHeight: 2) as dynamic);
        await Future.delayed(Duration(milliseconds: 300));

        final reorgs = spvInstance.receivedMessages.whereType<HeaderChainReorganizedMessage>().toList();
        expect(reorgs, hasLength(1));
        expect(reorgs.single.forkHeight, equals(1));
        expect(reorgs.single.newTipHeight, equals(4));
        expect(reorgs.single.orphanedBlockHashes.toSet(),
            equals({a[1].blockHash().toString(), a[2].blockHash().toString()}));

        final messages = spvInstance.receivedMessages;
        final reorgAt = messages.indexOf(reorgs.single);
        final storedAt = messages.lastIndexWhere((m) => m is BlockHeaderStoredMessage);
        expect(reorgAt, lessThan(storedAt),
            reason: 'confirmations are re-checked before ARC is prompted by the stored-header notification');
      });

      test('a lower-work competing branch delivered by a peer does not move the tip', () async {
        final a = RegtestMiner.mineChain(genesis, 3, seed: 'A');
        headerSyncActor.tell(BlockHeadersReceivedMessage(
          peerId: 'peer-a', headers: a, startHeight: 1) as dynamic);
        await Future.delayed(Duration(milliseconds: 300));

        final c = RegtestMiner.mineChain(genesis, 2, seed: 'C');
        headerSyncActor.tell(BlockHeadersReceivedMessage(
          peerId: 'peer-c', headers: c, startHeight: 1) as dynamic);
        await Future.delayed(Duration(milliseconds: 300));

        expect(headerChain.bestHeight, equals(3));
        expect(headerChain.chainTip!.blockHash(), equals(a[2].blockHash()));
        expect(await headerChain.hasHeader(c[1].blockHash().toString()), isTrue);
      });

      test('a reorg chain-tip event requests headers with a full block locator', () async {
        final a = RegtestMiner.mineChain(genesis, 15, seed: 'A');
        for (var i = 0; i < a.length; i++) {
          await headerChain.validateAndStoreHeader(a[i], i + 1);
        }
        final sent = <MsgGetHeaders>[];
        headerSyncActor.tell(SetPeerManagerMessage(_FakePeerManager(onGetHeaders: sent.add)));

        headerSyncActor.tell(ChainTipEventMessage(
          newTip: _TestChainTip(blockHash: 'ab' * 32, height: 16),
          oldTip: _TestChainTip(blockHash: a.last.blockHash().toString(), height: 15),
          eventType: ChainTipEventType.reorganization,
          description: 'Blockchain reorganization detected',
        ) as dynamic);
        await Future.delayed(Duration(milliseconds: 300));

        expect(sent, hasLength(1));
        final locator = sent.single.blockLocatorHashes;
        expect(locator.first, equals(a.last.blockHash()));
        expect(locator.last, equals(genesis.blockHash()));
        expect(locator.length, greaterThan(10));
        expect(locator.length, lessThan(16));
      });

      test('a batch that does not connect to any known header triggers a re-request', () async {
        final sent = <MsgGetHeaders>[];
        headerSyncActor.tell(SetPeerManagerMessage(_FakePeerManager(onGetHeaders: sent.add)));

        final foreign = RegtestMiner.mineChain(NetworkParams.testnet.genesisHeader, 2);
        headerSyncActor.tell(BlockHeadersReceivedMessage(
          peerId: 'peer-x', headers: foreign, startHeight: 1) as dynamic);
        await Future.delayed(Duration(milliseconds: 300));

        expect(headerChain.bestHeight, equals(0));
        expect(sent, hasLength(1));
        expect(sent.single.blockLocatorHashes, equals([genesis.blockHash()]));
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

/// Stand-in for spiffynode's PeerManager (HeaderSyncActor holds it as
/// `dynamic`). [onGetHeaders] runs whenever a getHeaders message is written.
class _FakePeerManager {
  final void Function(MsgGetHeaders) onGetHeaders;
  final bool hasPeers;
  int getHeadersRequests = 0;

  _FakePeerManager({required this.onGetHeaders, this.hasPeers = true});

  List<_FakePeer> getPeers() => hasPeers ? [_FakePeer(this)] : [];
}

class _FakePeer {
  final _FakePeerManager manager;
  _FakePeer(this.manager);

  String get state => 'connected';

  Future<void> writeMessage(dynamic message) async {
    manager.getHeadersRequests++;
    manager.onGetHeaders(message as MsgGetHeaders);
  }

  @override
  String toString() => 'fake-peer';
}
