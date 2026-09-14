/// WalletManagerActor reply-shape and unknown-wallet tests.
///
/// Covers audit findings (doc/audit-2026-09-14.md):
/// - A-M8: failure replies to ask() callers must be LocalMessage-wrapped,
///   otherwise dactor's temporary reply ref rejects them with a StateError.
/// - A-M4: a command for a wallet with no journal is answered
///   "Wallet not found" instead of spawning an empty aggregate (which never
///   replied, so the ask hung until its timeout).

import 'dart:async';
import 'package:test/test.dart';
import 'package:dactor/dactor.dart';
import 'package:dactor_test/dactor_test.dart';

import 'package:libspiffy/src/actors/wallet_manager_actor.dart';
import 'package:libspiffy/src/actors/wallet_messages.dart';
import 'package:libspiffy/src/core/wallet_commands.dart';
import 'package:libspiffy/src/services/dartsv_crypto_service.dart';
import 'package:libspiffy/src/storage/in_memory_secure_storage.dart';

import 'in_memory_event_store.dart';

const _mnemonic = 'abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon abandon abandon about';

void main() {
  late TestActorSystem actorSystem;
  late InMemoryEventStore eventStore;
  late ActorRef walletManager;

  setUp(() async {
    actorSystem = TestActorSystem();
    eventStore = InMemoryEventStore();
    walletManager = await actorSystem.spawn(
      'wallet-manager',
      () => WalletManagerActor(
        eventStore: eventStore,
        cryptoService: DartSVCryptoService(),
        secureStorage: InMemorySecureStorage(),
      ),
    );
  });

  tearDown(() async {
    await actorSystem.shutdown();
  });

  group('A-M8: failure replies are LocalMessage-wrapped for ask() callers', () {
    test('duplicate CreateWalletMessage answers the ask with an error message',
        () async {
      final first = await walletManager.ask<WalletCreatedMessage>(
        CreateWalletMessage('w1', 'Wallet 1', mnemonic: _mnemonic),
        const Duration(seconds: 10),
      );
      expect(first.success, isTrue);

      // Old code sent a bare WalletCreatedMessage here; dactor's ask reply
      // ref only accepts LocalMessage, so the caller got a StateError
      // instead of the "Wallet already exists" reply.
      final second = await walletManager.ask<WalletCreatedMessage>(
        CreateWalletMessage('w1', 'Wallet 1 again', mnemonic: _mnemonic),
        const Duration(seconds: 10),
      );
      expect(second.success, isFalse);
      expect(second.error, 'Wallet already exists');
    });

    test('spawn failure during CreateWalletMessage answers the ask with an error',
        () async {
      // Occupy the aggregate's actor id so context.system.spawn throws and
      // the manager takes its catch path.
      await actorSystem.spawn('wallet-w2', () => _NoopActor());

      final reply = await walletManager.ask<WalletCreatedMessage>(
        CreateWalletMessage('w2', 'Wallet 2', mnemonic: _mnemonic),
        const Duration(seconds: 10),
      );
      expect(reply.success, isFalse);
      expect(reply.error, contains('already exists'));
    });
  });

  group('A-M4: commands for an unknown wallet', () {
    test('are answered "Wallet not found" without spawning an aggregate',
        () async {
      final stopwatch = Stopwatch()..start();
      final reply = await walletManager.ask<dynamic>(
        WalletCommandMessage(
          'ghost',
          GenerateAddressCommand(walletId: 'ghost'),
        ),
        const Duration(seconds: 10),
      );
      stopwatch.stop();

      expect(reply, isA<Map>());
      expect((reply as Map)['error'], 'Wallet not found');
      expect(reply['walletId'], 'ghost');

      // The old code spawned an empty aggregate for the unknown id and
      // forwarded the command to it; the aggregate rejected it without
      // replying, so the ask hung until its timeout.
      expect(actorSystem.getActor('wallet-ghost'), isNull,
          reason: 'no aggregate may be spawned for a wallet with no journal');
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 5)));
    });
  });
}

class _NoopActor extends Actor {
  @override
  Future<void> onMessage(dynamic message) async {}
}
