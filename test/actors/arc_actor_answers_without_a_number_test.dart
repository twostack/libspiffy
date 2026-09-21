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
/// Bead libspiffy-8743 closed the two limits this file first pinned as
/// characterizations:
///
/// * `_handleEstimateFee` caught the policy failure itself and fell back to
///   an invented 1 sat/1000 bytes, so a caller was told **success** with a
///   rate nothing published — and 97zj's honest failure reply was
///   unreachable. It now answers a policy it could not read as a failure,
///   exactly as its sibling `_quotePolicyFee` already did.
/// * `preStart` built a TAAL **mainnet** service when handed no
///   configuration, so `_arcService == null` was false for every message and
///   seven honest "ARC service not available" branches were dead — and an
///   actor given no ARC endpoint silently acquired a mainnet one, the last
///   copy of the defect audit V-2 fixed. No configuration now means no ARC,
///   which is a supported way to run a wallet: it records and proves
///   transactions and asks nobody to broadcast them.
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

    test('a fee estimate reports the failure and no fee, rather than a rate '
        'libspiffy invented', () async {
      final reply =
          await arcActor.ask<FeeEstimateMessage>(EstimateFeeMessage(1, 2), _ask);

      // Old code: success, with a fee computed from a hard-coded
      // 1 sat/1000 bytes that no miner published.
      expect(reply.success, isFalse);
      expect(reply.error, contains("policy could not be read"));
      expect(reply.estimatedFee, isNull,
          reason: 'a rate nobody published is not an estimate');
    });

    test('a policy fee quote carries no fee when it failed', () async {
      final reply = await arcActor.ask<PolicyFeeQuote>(
          EstimatePolicyFeeMessage(inputCount: 1, outputCount: 1), _ask);

      expect(reply.success, isFalse);
      expect(reply.fee, isNull,
          reason: 'zero is a fee a caller can build a transaction with');
      expect(reply.sizeBytes, greaterThan(0), reason: 'the size was measured, the fee was not');
    });
  });

  /// An ARCActor with neither a configuration nor a service. It used to
  /// build `ArcServiceConfig.taalMainnet()` here — so this actor would have
  /// been talking to mainnet — and every branch below was unreachable.
  group('when the wallet has no ARC at all', () {
    setUp(() => spawn(null));

    test('a broadcast is refused rather than sent to a mainnet endpoint '
        'nobody asked for', () async {
      final reply = await arcActor.ask<BroadcastFailedMessage>(
          BroadcastTransactionMessage('w', '00', _txid), _ask);

      expect(reply.success, isFalse);
      expect(reply.error, contains('ARC service not available'));
      expect(reply.txid, _txid);
    });

    test('a fee estimate has no fee, and a fee quote no rates', () async {
      final estimate =
          await arcActor.ask<FeeEstimateMessage>(EstimateFeeMessage(1, 2), _ask);
      expect(estimate.success, isFalse);
      expect(estimate.estimatedFee, isNull);
      expect(estimate.error, contains('ARC service not available'));

      final quote = await arcActor.ask<FeeQuoteMessage>(GetFeeQuoteMessage(), _ask);
      expect(quote.success, isFalse);
      expect(quote.feeData, isEmpty);
      expect(quote.error, contains('ARC service not available'));
    });

    test('a status check reports no status', () async {
      final reply = await arcActor.ask<TransactionStatusMessage>(
          CheckTransactionStatusMessage(_txid), _ask);

      expect(reply.success, isFalse);
      expect(reply.status, isNull);
      expect(reply.error, contains('ARC service not available'));
    });

    test('a merkle proof request is refused', () async {
      final reply = await arcActor.ask<MerkleProofMessage>(
          RetrieveMerkleProofMessage(txid: _txid, walletId: 'w'), _ask);

      expect(reply.success, isFalse);
      expect(reply.error, contains('ARC service not available'));
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
