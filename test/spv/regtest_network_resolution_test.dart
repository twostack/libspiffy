/// x27 (libspiffy-x27): `NetworkName.canonical('regtest')` returned
/// 'testnet'. A regtest wallet was persisted as a testnet wallet, and the
/// CDN configuration (`network: NetworkName.canonical(networkType)` in
/// LibSpiffyActorSystem) pointed at the testnet directory and testnet
/// consensus constants, so a regtest header chain failed closed with a
/// genesis mismatch.
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:eventador/eventador.dart';
import 'package:test/test.dart';

import 'package:libspiffy/src/core/wallet_events.dart';
import 'package:libspiffy/src/models/wallet_type.dart';
import 'package:libspiffy/src/projections/wallet_projection.dart';
import 'package:libspiffy/src/spv/block_header_chain.dart';
import 'package:libspiffy/src/spv/cdn_header_sync_config.dart';
import 'package:libspiffy/src/spv/cdn_header_sync_service.dart';
import 'package:libspiffy/src/spv/network_params.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';
import 'package:libspiffy/src/utils/network_name.dart';

void main() {
  const regtestGenesis = '0f9188f13cb7b2c71f2a335e3a4fc328bf5beb436012afca590b1a11466e2206';

  test('a regtest wallet is persisted as regtest and resolves the regtest consensus constants', () async {
    final storage = InMemoryWalletStorage();
    final projection = WalletProjection(
      projectionId: 'x27',
      eventStore: _NoopEventStore(),
      storage: storage,
    );
    await projection.handle(WalletCreatedEvent(
      walletId: 'regtest-wallet',
      walletName: 'Regtest',
      rootAddress: 'mzBc4XEFSdzCDcTxAgf6EZXgsZWpztRhef',
      walletType: WalletType.hd,
      walletMetadata: {'network': 'regtest'},
      version: 1,
      timestamp: DateTime.utc(2026, 1, 1),
    ));

    final stored = (await storage.getWallet('regtest-wallet'))!['network'] as String?;
    expect(stored, equals('regtest'));
    final params = NetworkParams.forNetwork(stored);
    expect(params, same(NetworkParams.regtest));
    expect(params.genesisHash, equals(regtestGenesis));
    expect(NetworkName.toDartsv(stored), equals(dartsv.NetworkType.TEST),
        reason: 'regtest addresses and keys use the testnet encoding');
  });

  test("the CDN configuration built for networkType 'regtest' uses the regtest directory and genesis", () {
    // The expression LibSpiffyActorSystem uses to configure CDN sync.
    final config = CdnHeaderSyncConfig(
      baseUrl: 'https://cdn.example.test',
      network: NetworkName.canonical('regtest'),
    );
    final service = CdnHeaderSyncService(
      config: config,
      headerChain: BlockHeaderChain(InMemoryWalletStorage(), params: NetworkParams.regtest),
    );
    expect(config.network, equals('regtest'));
    expect(service.networkParams.genesisHash, equals(regtestGenesis));
  });

  test('every regtest spelling is canonical regtest; other names keep their mapping', () {
    for (final n in ['regtest', ' RegTest ', 'REGTEST']) {
      expect(NetworkName.canonical(n), equals('regtest'), reason: n);
      expect(NetworkParams.forNetwork(n), same(NetworkParams.regtest), reason: n);
    }
    expect(NetworkName.canonical('main'), equals('mainnet'));
    expect(NetworkName.canonical('test'), equals('testnet'));
    expect(NetworkName.canonical(null), equals('testnet'));
  });
}

class _NoopEventStore implements EventStore {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
