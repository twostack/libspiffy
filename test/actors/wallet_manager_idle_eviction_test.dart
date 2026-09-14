/// WalletManagerActor idle-aggregate eviction.
///
/// Covers the WalletManager half of audit finding A-M10 (libspiffy-rit,
/// doc/audit-2026-09-14.md): every wallet aggregate the manager loaded stayed
/// in `_walletActors` (and running in the actor system) for the life of the
/// process. Aggregates idle past the configured threshold are now stopped and
/// recovered from the journal on their next command.

import 'dart:async';

import 'package:dactor/dactor.dart';
import 'package:dactor_test/dactor_test.dart';
import 'package:test/test.dart';

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
        aggregateIdleTimeout: const Duration(milliseconds: 400),
        idleCheckInterval: const Duration(milliseconds: 50),
      ),
    );
  });

  tearDown(() async {
    await actorSystem.shutdown();
  });

  Future<AddressGeneratedResponse> generateAddress(String walletId) =>
      walletManager.ask<AddressGeneratedResponse>(
        WalletCommandMessage(
          walletId,
          GenerateAddressCommand(walletId: walletId, purpose: 'receive'),
        ),
        const Duration(seconds: 10),
      );

  Future<bool> waitUntil(bool Function() condition, Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) return false;
      await Future.delayed(const Duration(milliseconds: 20));
    }
    return true;
  }

  group('A-M10: idle wallet aggregates', () {
    test('an aggregate idle past the threshold is stopped and re-spawned '
        'transparently on the next command', () async {
      final created = await walletManager.ask<WalletCreatedMessage>(
        CreateWalletMessage('w1', 'Wallet 1', mnemonic: _mnemonic),
        const Duration(seconds: 10),
      );
      expect(created.success, isTrue, reason: created.error);
      final first = await generateAddress('w1');
      expect(first.success, isTrue, reason: first.error);
      expect(actorSystem.getActor('wallet-w1'), isNotNull);

      final evicted = await waitUntil(
          () => actorSystem.getActor('wallet-w1') == null,
          const Duration(seconds: 3));
      expect(evicted, isTrue,
          reason: 'the aggregate was still running 3 s after going idle');

      // Next command: recovered from the journal, state intact (the address
      // index continues rather than restarting).
      final second = await generateAddress('w1');
      expect(second.success, isTrue, reason: second.error);
      expect(second.derivationIndex, greaterThan(first.derivationIndex));
      expect(actorSystem.getActor('wallet-w1'), isNotNull);

      // An evicted wallet still exists: creating it again is refused.
      await waitUntil(() => actorSystem.getActor('wallet-w1') == null,
          const Duration(seconds: 3));
      final again = await walletManager.ask<WalletCreatedMessage>(
        CreateWalletMessage('w1', 'Wallet 1 again', mnemonic: _mnemonic),
        const Duration(seconds: 10),
      );
      expect(again.success, isFalse);
      expect(again.error, 'Wallet already exists');
    });

    test('an aggregate in use is not evicted', () async {
      final created = await walletManager.ask<WalletCreatedMessage>(
        CreateWalletMessage('w2', 'Wallet 2', mnemonic: _mnemonic),
        const Duration(seconds: 10),
      );
      expect(created.success, isTrue, reason: created.error);

      // Keep using it for well over the idle threshold.
      final until = DateTime.now().add(const Duration(milliseconds: 1000));
      while (DateTime.now().isBefore(until)) {
        final reply = await generateAddress('w2');
        expect(reply.success, isTrue, reason: reply.error);
        expect(actorSystem.getActor('wallet-w2'), isNotNull);
        await Future.delayed(const Duration(milliseconds: 100));
      }
    });
  });
}
