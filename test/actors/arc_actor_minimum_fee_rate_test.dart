/// Bead libspiffy-23j2 (ruggerbot report #4): the app sets a minimum fee
/// rate under ARC's published one. GorillaPool's testnet ARC publishes
/// 0 sat/kB, and nothing paying 0 is mined there. The owner's ruling: the
/// rate is ARC's, the app may set a floor, libspiffy hardcodes none.
library;

import 'package:dactor/dactor.dart';
import 'package:libspiffy/src/actors/arc_actor.dart';
import 'package:libspiffy/src/actors/wallet_messages.dart';
import 'package:libspiffy/src/models/fee_rate.dart';
import 'package:libspiffy/src/services/arc_service.dart';
import 'package:libspiffy/src/services/arc_service_config.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';
import 'package:test/test.dart';

const _ask = Duration(seconds: 5);

void main() {
  late LocalActorSystem system;

  setUp(() => system = LocalActorSystem(ActorSystemConfig()));
  tearDown(() => system.shutdown());

  Future<FeeRateQuote> quote(ArcService service, {FeeRate? floor}) async {
    final walletManager = await system.spawn('wallet-manager', () => _Silent());
    final arc = await system.spawn(
      'arc',
      () => ARCActor(
        walletManager: walletManager,
        storage: InMemoryWalletStorage(),
        arcConfig: ArcServiceConfig(baseUrl: 'fake://arc', minimumFeeRate: floor),
        arcService: service,
        statusCheckInterval: const Duration(minutes: 30),
        failedCheckInterval: const Duration(minutes: 30),
      ),
    );
    return arc.ask<FeeRateQuote>(GetFeeRateMessage(), _ask);
  }

  test('a floor above the published rate is the rate paid', () async {
    final reply = await quote(_PolicyArc(const FeeRate(satoshis: 0, bytes: 1000)),
        floor: const FeeRate(satoshis: 1, bytes: 1000));
    expect(reply.success, isTrue, reason: reply.error);
    // Old code: 0 sat/1000 bytes, which no miner mines.
    expect(reply.rate, const FeeRate(satoshis: 1, bytes: 1000));
  });

  test('a published rate above the floor is the rate paid', () async {
    final reply = await quote(_PolicyArc(const FeeRate(satoshis: 100, bytes: 1000)),
        floor: const FeeRate(satoshis: 1, bytes: 1000));
    expect(reply.rate, const FeeRate(satoshis: 100, bytes: 1000));
  });

  test('without a floor the published rate is paid, zero included', () async {
    final reply = await quote(_PolicyArc(const FeeRate(satoshis: 0, bytes: 1000)));
    expect(reply.rate, const FeeRate(satoshis: 0, bytes: 1000));
  });

  test('a floor is no rate in place of a policy ARC could not be asked for', () async {
    final reply = await quote(_ThrowingArc(), floor: const FeeRate(satoshis: 1, bytes: 1000));
    expect(reply.success, isFalse);
    expect(reply.rate, isNull);
  });

  test('rates are compared per byte, exactly', () {
    const fiftyPerKb = FeeRate(satoshis: 50, bytes: 1000);
    expect(const FeeRate(satoshis: 1, bytes: 10).isAbove(fiftyPerKb), isTrue); // 100/kB
    expect(const FeeRate(satoshis: 1, bytes: 20).isAbove(fiftyPerKb), isFalse); // equal
    expect(const FeeRate(satoshis: 1, bytes: 30).isAbove(fiftyPerKb), isFalse);
    expect(const FeeRate(satoshis: 1, bytes: 1000).isAbove(const FeeRate(satoshis: 0, bytes: 1000)), isTrue);
  });
}

class _PolicyArc extends ArcService {
  final FeeRate rate;
  _PolicyArc(this.rate) : super(baseUrl: 'fake://arc');

  @override
  Future<ArcPolicyResponse> getPolicy() async => ArcPolicyResponse.fromJson({
        'timestamp': '2026-10-09T08:00:00Z',
        'policy': {
          'maxscriptsizepolicy': 100000,
          'maxtxsigopscountspolicy': 4294967295,
          'maxtxsizepolicy': 100000000,
          'miningFee': {'satoshis': rate.satoshis, 'bytes': rate.bytes},
        },
      });
}

class _ThrowingArc extends ArcService {
  _ThrowingArc() : super(baseUrl: 'fake://arc');

  @override
  Future<ArcPolicyResponse> getPolicy() async => throw ArcException('no policy');
}

class _Silent extends Actor {
  @override
  Future<void> onMessage(dynamic message) async {}
}
