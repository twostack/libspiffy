import 'package:dactor/dactor.dart';
import 'package:libspiffy/src/actors/header_sync_actor.dart';
import 'package:libspiffy/src/integration/spiffynode_bridge.dart';
import 'package:libspiffy/src/spv/block_header_chain.dart';
import 'package:libspiffy/src/spv/network_params.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';
import 'package:logging/logging.dart';
import 'package:spiffynode/spiffy_node.dart';
import 'package:test/test.dart';

import 'regtest_chain_builder.dart';

/// SPV-03 at the peer-handler level: headers arriving through
/// LibSpiffyPeerHandler.handleHeaders (the real P2P entry point) after a
/// reorganization are placed by their parents, not at bestHeight + 1.
/// No network: the PeerManager is constructed offline and never connects.
void main() {
  Logger.root.level = Level.SEVERE;

  final regtest = NetworkParams.regtest;
  final genesis = regtest.genesisHeader;

  late LocalActorSystem actorSystem;
  late BlockHeaderChain chain;
  late ActorRef actor;
  late PeerManager peerManager;
  late SpiffyNodeBridge bridge;
  late LibSpiffyPeerHandler handler;
  final peer = _FakePeer();

  setUp(() async {
    actorSystem = LocalActorSystem();
    chain = BlockHeaderChain(
      InMemoryWalletStorage(),
      params: regtest,
      clock: () => genesis.timestamp.add(const Duration(days: 365)),
    );
    await chain.initialize();
    actor = await actorSystem.spawn('header-sync', () => HeaderSyncActor(headerChain: chain));
    peerManager = PeerManager(
      network: BitcoinNetwork.regtest,
      config: const PeerManagerConfig(enableHealthMonitoring: false),
    );
    bridge = SpiffyNodeBridge(peerManager: peerManager, headerSyncActor: actor);
    await bridge.initialize();
    handler = LibSpiffyPeerHandler(bridge: bridge, headerChain: chain, headerSyncActor: actor);
    await Future.delayed(const Duration(milliseconds: 100));
  });

  tearDown(() async {
    await bridge.shutdown();
    await peerManager.shutdown();
    await actorSystem.shutdown();
  });

  test('a headers message from the fork point is stored at the correct heights after a reorg',
      () async {
    final a = RegtestMiner.mineChain(genesis, 3, seed: 'A'); // heights 1..3
    await handler.handleHeaders(MsgHeaders(headers: a), peer);
    await Future.delayed(const Duration(milliseconds: 300));
    expect(chain.bestHeight, equals(3));

    // The peer's reply after it reorganized: from the fork point (height 2).
    final b = RegtestMiner.mineChain(a[0], 3, seed: 'B'); // heights 2..4
    await handler.handleHeaders(MsgHeaders(headers: b), peer);
    await Future.delayed(const Duration(milliseconds: 300));

    expect(chain.bestHeight, equals(4));
    expect(chain.chainTip!.blockHash(), equals(b[2].blockHash()));
    expect((await chain.getHeaderByHeight(2))!.blockHash(), equals(b[0].blockHash()));
    expect((await chain.getHeaderByHeight(3))!.blockHash(), equals(b[1].blockHash()));
    expect((await chain.getHeaderByHeight(4))!.blockHash(), equals(b[2].blockHash()));
    expect(await chain.getHeaderByHash(a[2].blockHash().toString()), isNull);
  });

  test('a headers message that does not connect leaves the chain untouched', () async {
    final foreign = RegtestMiner.mineChain(NetworkParams.testnet.genesisHeader, 2);
    await handler.handleHeaders(MsgHeaders(headers: foreign), peer);
    await Future.delayed(const Duration(milliseconds: 300));
    expect(chain.bestHeight, equals(0));
    expect(chain.chainTip!.blockHash().toString(), equals(regtest.genesisHash));
  });
}

/// Minimal PeerI: the handler only calls toString() on it.
class _FakePeer implements PeerI {
  @override
  String toString() => 'fake-peer';

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
