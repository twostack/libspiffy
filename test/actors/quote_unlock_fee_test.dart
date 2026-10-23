/// Bead spiffyvault-mnz.7: the coordinator quotes the fee of unlocking a
/// HODLocker coin, ARC's policy rate on the unlock's size, so an app can
/// tell a lock worth unlocking from one that costs more than it holds.
library;

import 'dart:async';

import 'package:dactor/dactor.dart';
import 'package:test/test.dart';

import 'package:libspiffy/src/actors/coordinator_messages.dart' as coord;
import 'package:libspiffy/src/actors/wallet_coordinator_actor.dart';
import 'package:libspiffy/src/core/hodlocker_lock.dart';
import 'package:libspiffy/src/core/spiffy_error.dart';
import 'package:libspiffy/src/models/fee_rate.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';

import '../mocks/policy_rate_arc.dart';

class _Noop extends Actor {
  @override
  Future<void> onMessage(dynamic message) async {}
}

void main() {
  late ActorSystem system;
  late PolicyRateArc arc;
  late List<coord.CoordinatorEvent> events;
  late ActorRef ref;

  setUp(() async {
    system = LocalActorSystem();
    arc = PolicyRateArc(const FeeRate(satoshis: 100, bytes: 1000));
    final noop = await system.spawn('noop', () => _Noop());
    final arcRef = await system.spawn('arc', () => arc);
    final coordinator = WalletCoordinatorActor(
      walletManager: noop,
      invoiceCoordinator: noop,
      paymentCoordinator: noop,
      spvActor: noop,
      arcActor: arcRef,
      headerSyncActor: noop,
      benfordCoordinator: noop,
      channelManager: noop,
      walletProjection: noop,
      storage: InMemoryWalletStorage(),
    );
    events = [];
    final sub = coordinator.events.listen(events.add);
    addTearDown(sub.cancel);
    ref = await system.spawn('coordinator', () => coordinator);
  });

  tearDown(() => system.shutdown());

  Future<coord.UnlockFeeQuotedEvent> quote(String requestId) async {
    ref.tell(coord.QuoteUnlockFeeCommand(lockingScriptLength: 934, requestId: requestId));
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (DateTime.now().isBefore(deadline)) {
      final answered = events.whereType<coord.UnlockFeeQuotedEvent>().where((e) => e.requestId == requestId);
      if (answered.isNotEmpty) return answered.first;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('no UnlockFeeQuotedEvent within 5s');
  }

  test('the fee is ARC\'s rate on the unlock\'s size', () async {
    final quoted = await quote('q1');
    expect(quoted.success, isTrue);
    expect(quoted.fee, const FeeRate(satoshis: 100, bytes: 1000).feeFor(HodlockerLock.unlockSize(934)));
    expect(quoted.fee, BigInt.from(130));
  });

  test('without ARC\'s rate there is no quote, and the reply says why', () async {
    arc.rate = null;
    final quoted = await quote('q2');
    expect(quoted.success, isFalse);
    expect(quoted.fee, isNull);
    expect(quoted.errorCode, SpiffyErrorCode.feeRateUnavailable);
    expect(quoted.failure, contains('could not be read'));
  });
}
