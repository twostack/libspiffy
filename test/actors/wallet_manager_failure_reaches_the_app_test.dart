/// A wallet manager failure reaches the app as its reason.
///
/// The coordinator asks the wallet manager for a specific reply type. When
/// the manager can't serve the request (here: no such wallet) it answers
/// with a `WalletManagerFailure` instead, and the ask used to fail with
/// dactor's "Ask response type mismatch" text, which the app showed as is.
library;

import 'dart:async';

import 'package:dactor/dactor.dart';
import 'package:test/test.dart';

import 'package:libspiffy/src/actors/coordinator_messages.dart';
import 'package:libspiffy/src/actors/wallet_coordinator_actor.dart';
import 'package:libspiffy/src/actors/wallet_messages.dart' as wm;
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';

void main() {
  test('an unknown wallet is reported as such, not as a type mismatch', () async {
    final actorSystem = LocalActorSystem();
    final noop = await actorSystem.spawn('noop', () => _Noop());
    final manager = await actorSystem.spawn('manager', () => _NoWallets());
    final coordinator = WalletCoordinatorActor(
      walletManager: manager,
      invoiceCoordinator: noop,
      paymentCoordinator: noop,
      spvActor: noop,
      arcActor: noop,
      headerSyncActor: noop,
      benfordCoordinator: noop,
      channelManager: noop,
      walletProjection: noop,
      storage: InMemoryWalletStorage(),
    );
    final answer = coordinator.events.where((e) => e is AnchorPublicKeyEvent).cast<AnchorPublicKeyEvent>().first;
    final ref = await actorSystem.spawn('coordinator', () => coordinator);

    ref.tell(IssueAnchorKeyCommand(walletId: 'gone', anchorContext: const [1, 2, 3], requestId: 'r1'));
    final event = await answer.timeout(const Duration(seconds: 10));

    expect(event.success, isFalse);
    expect(event.requestId, 'r1');
    expect(event.error, contains('Wallet not found'));
    expect(event.error, isNot(contains('mismatch')));
    await actorSystem.shutdown();
  });
}

class _Noop extends Actor {
  @override
  Future<void> onMessage(dynamic message) async {}
}

/// A wallet manager that knows no wallets.
class _NoWallets extends Actor {
  @override
  Future<void> onMessage(dynamic message) async {
    if (message is wm.WalletCommandMessage) {
      context.sender?.tell(wm.WalletManagerFailure(
        error: 'Wallet not found',
        request: 'WalletCommandMessage',
        walletId: message.walletId,
      ));
    }
  }
}
