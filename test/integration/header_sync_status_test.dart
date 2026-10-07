/// Header sync as an application sees it, through the coordinator (bead
/// libspiffy-ndfr): the actor system is ready before its headers are, so
/// the application asks where sync stands (GetHeaderSyncStatusQuery), hears
/// when it catches up (HeaderSyncStatusEvent), and hears every batch stored
/// (BlockHeadersStoredEvent), whether a peer sent it or a
/// StoreHeadersCommand did. A StoreHeadersCommand's headers are validated
/// into the header chain like a peer's.
import 'dart:async';
import 'dart:io';

import 'package:convert/convert.dart';
import 'package:dactor/dactor.dart';
import 'package:isar_community/isar.dart';
import 'package:libspiffy/coordinator.dart';
import 'package:libspiffy/libspiffy.dart';
import 'package:libspiffy/src/actors/spv_messages.dart' show BlockHeadersReceivedMessage;
import 'package:libspiffy/src/spv/network_params.dart';
import 'package:spiffynode/spiffy_node.dart';
import 'package:test/test.dart';

import '../spv/regtest_chain_builder.dart';
import 'isar_test_helper.dart';

void main() {
  final genesis = NetworkParams.regtest.genesisHeader;

  late Directory dir;
  late LibSpiffyActorSystem libspiffy;
  late List<CoordinatorEvent> events;
  late StreamController<CoordinatorEvent> stream;

  setUpAll(ensureIsarInitialized);

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('header_sync_status_');
    final isar = await Isar.open(
      LibSpiffySchemas.allSchemas,
      directory: dir.path,
      name: 'hss_${DateTime.now().microsecondsSinceEpoch}',
    );
    libspiffy = LibSpiffyActorSystem();
    await libspiffy.initialize(
      actorSystem: LocalActorSystem(ActorSystemConfig()),
      isar: isar,
      dataDirectory: dir.path,
      networkType: 'regtest',
      enableP2P: false,
    );
    events = [];
    stream = StreamController<CoordinatorEvent>.broadcast();
    libspiffy.coordinatorEvents!.listen((e) {
      events.add(e);
      stream.add(e);
    });
  });

  tearDown(() async {
    await libspiffy.shutdown();
    await stream.close();
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  });

  Future<T> next<T extends CoordinatorEvent>([bool Function(T)? test]) => stream.stream
      .where((e) => e is T && (test == null || test(e)))
      .cast<T>()
      .first
      .timeout(const Duration(seconds: 10));

  Future<HeaderSyncStatus> status() async {
    final queryId = 'q-${DateTime.now().microsecondsSinceEpoch}';
    final answer = next<HeaderSyncStatusResponse>((r) => r.queryId == queryId);
    libspiffy.coordinator.tell(GetHeaderSyncStatusQuery(queryId: queryId));
    return (await answer).status;
  }

  /// A batch of headers as a peer's answer to getheaders.
  void fromPeer(List<BlockHeader> headers) => libspiffy.headerSyncActor.tell(
      BlockHeadersReceivedMessage(peerId: 'peer', headers: headers, startHeight: 0));

  Map<String, dynamic> asCommandRow(BlockHeader h, int height) => {
        'height': height,
        'version': h.version,
        'prevBlockHash': hex.encode(h.prevBlock.bytes),
        'merkleRoot': hex.encode(h.merkleRoot.bytes),
        'timestamp': h.timestamp.millisecondsSinceEpoch ~/ 1000,
        'bits': h.bits,
        'nonce': h.nonce,
      };

  test('ready before synced: the status says so, and says when sync catches up', () async {
    expect(await status(), const HeaderSyncStatus(height: 0, networkHeight: 0, synced: false, peerCount: 0));

    final headers = RegtestMiner.mineChain(genesis, 2300);
    final firstBatch = next<BlockHeadersStoredEvent>();
    fromPeer(headers.take(2000).toList());
    final stored = await firstBatch;
    expect(stored.source, BlockHeadersStoredEvent.peerSource);
    expect(stored.success, isTrue);
    expect((stored.headersStored, stored.startHeight, stored.endHeight), (2000, 1, 2000));
    expect((await status()).synced, isFalse, reason: 'a full batch: the peer has more');

    final caughtUp = next<HeaderSyncStatusEvent>();
    fromPeer(headers.skip(2000).toList());
    final event = await caughtUp;
    expect(event.status.synced, isTrue);
    expect(event.status.height, 2300);
    expect(await status(), const HeaderSyncStatus(height: 2300, networkHeight: 0, synced: true, peerCount: 0));

    // One more block keeps it caught up: no second status event.
    final block = next<BlockHeadersStoredEvent>();
    fromPeer([RegtestMiner.mine(parent: headers.last)]);
    expect((await block).endHeight, 2301);
    expect(events.whereType<HeaderSyncStatusEvent>(), hasLength(1));
  });

  test('StoreHeadersCommand validates its headers into the header chain', () async {
    final headers = RegtestMiner.mineChain(genesis, 3);
    final answer = next<BlockHeadersStoredEvent>();
    libspiffy.coordinator.tell(StoreHeadersCommand(
      headers: [for (var i = 0; i < headers.length; i++) asCommandRow(headers[i], i + 1)],
      source: 'bundle',
    ));
    final stored = await answer;
    expect(stored.success, isTrue, reason: stored.error);
    expect(stored.source, 'bundle');
    expect((stored.headersStored, stored.startHeight, stored.endHeight), (3, 1, 3));
    expect(libspiffy.headerChain.bestHeight, 3);
    expect((await status()).synced, isFalse, reason: 'the app\'s headers do not say the peers have no more');

    // A header that does not connect to the chain is refused, not stored.
    final stranger = RegtestMiner.mineChain(NetworkParams.testnet.genesisHeader, 1).single;
    final refused = next<BlockHeadersStoredEvent>();
    libspiffy.coordinator.tell(StoreHeadersCommand(headers: [asCommandRow(stranger, 4)], source: 'bundle'));
    final r = await refused;
    expect(r.success, isFalse);
    expect(r.headersStored, 0);
    expect(r.error, contains('unknownParent'));
    expect(libspiffy.headerChain.bestHeight, 3);
    expect(await libspiffy.walletStorage.getBlockHeaderByHash(stranger.blockHash().toString()), isNull);
  });

  test('a malformed StoreHeadersCommand is answered with the reason', () async {
    final answer = next<BlockHeadersStoredEvent>();
    libspiffy.coordinator.tell(StoreHeadersCommand(headers: [
      {'height': 1, 'version': 1}
    ], source: 'bundle'));
    final r = await answer;
    expect(r.success, isFalse);
    expect(r.error, contains('malformed header'));
  });
}
