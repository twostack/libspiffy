/// Bead libspiffy-97zj: when ARC cannot answer, the reply says so instead of
/// carrying a number nobody measured.
///
/// Three of ARCActor's replies encoded failure as data:
///
/// * `FeeEstimateMessage(BigInt.zero)` — zero is a plausible fee, and a
///   caller that did not know to distrust it would build a transaction with
///   no fee at all.
/// * `FeeQuoteMessage({'error': ...})` — an error smuggled into the map that
///   otherwise holds the mining and relay rates, so `feeData['mining']` was
///   simply absent and a caller reading it got null.
/// * `TransactionStatusMessage(status: 'error')` — a status string that is
///   not a status, indistinguishable from one ARC really reported.
///
/// None of the three had a test. Each reply now carries `success` and
/// `error`, and the value it could not measure is absent rather than zero,
/// empty or 'error'.
///
/// Two limits found while writing this, both filed as libspiffy-8743 and
/// pinned below as they are: `ARCActor.preStart` builds a TAAL mainnet
/// service when it is handed none, so `_arcService == null` is false for
/// every message and those branches are dead; and `_handleEstimateFee`
/// catches a policy failure itself and falls back to an invented
/// 1 sat/1000 bytes, so a fee estimate reports success with a rate nothing
/// published.
library;

import 'package:dactor/dactor.dart';
import 'package:test/test.dart';

import 'package:libspiffy/src/actors/arc_actor.dart';
import 'package:libspiffy/src/actors/wallet_messages.dart';
import 'package:libspiffy/src/services/arc_service.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';

const _ask = Duration(seconds: 5);
const _txid = 'ab';

void main() {
  late LocalActorSystem system;
  late ActorRef arcActor;

  Future<void> spawn(ArcService? service) async {
    final walletManager = await system.spawn('wallet-manager', () => _Silent());
    arcActor = await system.spawn(
      'arc',
      () => ARCActor(
        walletManager: walletManager,
        storage: InMemoryWalletStorage(),
        arcService: service,
        statusCheckInterval: const Duration(minutes: 30),
        failedCheckInterval: const Duration(minutes: 30),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }

  setUp(() => system = LocalActorSystem(ActorSystemConfig()));
  tearDown(() => system.shutdown());

  group('when ARC throws', () {
    setUp(() => spawn(_ThrowingArc()));

    test('a fee quote reports the failure outside the fee data', () async {
      final reply =
          await arcActor.ask<FeeQuoteMessage>(GetFeeQuoteMessage(), _ask);

      expect(reply.success, isFalse);
      expect(reply.error, isNotNull);
      expect(reply.feeData, isEmpty,
          reason: 'an error does not belong in the map that holds fee rates');
      expect(reply.feeData.containsKey('error'), isFalse);
    });

    test('a status check reports no status rather than the status "error"',
        () async {
      final reply = await arcActor.ask<TransactionStatusMessage>(
          CheckTransactionStatusMessage(_txid), _ask);

      expect(reply.success, isFalse);
      expect(reply.error, isNotNull);
      expect(reply.status, isNull,
          reason: "'error' is not a status ARC ever reports");
      expect(reply.txid, _txid);
    });

    test('a fee estimate still reports success, with a rate libspiffy '
        'invented (libspiffy-8743)', () async {
      final reply =
          await arcActor.ask<FeeEstimateMessage>(EstimateFeeMessage(1, 2), _ask);

      // Characterization, not an endorsement: _handleEstimateFee catches the
      // policy failure itself and falls back to 1 sat/1000 bytes, so the
      // honest failure reply this bead added is unreachable here. The fee
      // below is the fallback, not a measurement.
      expect(reply.success, isTrue);
      expect(reply.estimatedFee, isNotNull);
    });
  });

  test('a failed reply carries no value in place of the one it could not '
      'measure', () {
    // The types themselves, not a path through the actor: whatever reaches
    // these constructors, the absent value must stay absent. Zero, an empty
    // rate map read as rates, and the status 'error' are all values a
    // caller can act on without noticing that nothing measured them.
    expect(FeeEstimateMessage.failed('boom').estimatedFee, isNull);
    expect(FeeQuoteMessage.failed('boom').feeData, isEmpty);
    expect(TransactionStatusMessage.failed(txid: _txid, error: 'boom').status,
        isNull);
  });

  test('a fee estimate ARC can make is reported as a success with the fee',
      () async {
    await spawn(_PolicyArc());

    final reply =
        await arcActor.ask<FeeEstimateMessage>(EstimateFeeMessage(1, 2), _ask);

    expect(reply.success, isTrue, reason: reply.error);
    expect(reply.estimatedFee, isNotNull);
    expect(reply.estimatedFee! > BigInt.zero, isTrue);
  });
}

/// An ARC whose every call fails.
class _ThrowingArc extends ArcService {
  _ThrowingArc() : super(baseUrl: 'fake://arc');

  @override
  Future<ArcPolicyResponse> getPolicy() async => throw ArcException('no policy');

  @override
  Future<ArcTransactionResponse> getTransaction(String txid) async =>
      throw ArcException('no transaction');
}

/// An ARC that publishes a mining fee.
class _PolicyArc extends ArcService {
  _PolicyArc() : super(baseUrl: 'fake://arc');

  @override
  Future<ArcPolicyResponse> getPolicy() async => ArcPolicyResponse.fromJson({
        'timestamp': '2026-09-20T08:00:00Z',
        'policy': {
          'maxscriptsizepolicy': 100000,
          'maxtxsigopscountspolicy': 4294967295,
          'maxtxsizepolicy': 100000000,
          'miningFee': {'satoshis': 1, 'bytes': 1000},
        },
      });
}

class _Silent extends Actor {
  @override
  Future<void> onMessage(dynamic message) async {}
}
