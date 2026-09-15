/// Bead libspiffy-hfai at the actor boundary: wallet metadata naming a key
/// the wallet reserves for its own records is answered as a rejected command
/// through WalletManagerActor (configuration update) and
/// WalletCoordinatorActor (wallet creation), nothing is journaled, and the
/// aggregate keeps serving.
library;

import 'dart:async';

import 'package:dactor/dactor.dart';
import 'package:dactor_test/dactor_test.dart';
import 'package:test/test.dart';

import 'package:libspiffy/src/actors/coordinator_messages.dart' as coord;
import 'package:libspiffy/src/actors/wallet_coordinator_actor.dart';
import 'package:libspiffy/src/actors/wallet_manager_actor.dart';
import 'package:libspiffy/src/actors/wallet_messages.dart';
import 'package:libspiffy/src/core/wallet_commands.dart';
import 'package:libspiffy/src/core/wallet_events.dart';
import 'package:libspiffy/src/services/dartsv_crypto_service.dart';
import 'package:libspiffy/src/storage/in_memory_secure_storage.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';

import 'in_memory_event_store.dart';

const _mnemonic = 'abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon abandon abandon about';
const _walletId = 'w-hfai';
const _walletPid = 'BitcoinWallet_$_walletId';
const _wait = Duration(seconds: 5);

void main() {
  late TestActorSystem system;
  late InMemoryEventStore store;
  late ActorRef manager;

  setUp(() async {
    system = TestActorSystem();
    store = InMemoryEventStore();
    manager = await system.spawn(
      'wallet-manager',
      () => WalletManagerActor(
        eventStore: store,
        cryptoService: DartSVCryptoService(),
        secureStorage: InMemorySecureStorage(),
      ),
    );
  });

  tearDown(() async {
    await system.shutdown();
  });

  test('WalletManagerActor answers an update naming address_indices with an error; '
      'nothing journaled, the aggregate serves the next update', () async {
    final created = await manager.ask<WalletCreatedMessage>(
      CreateWalletMessage(_walletId, 'hfai', mnemonic: _mnemonic, walletMetadata: {'network': 'testnet'}),
      const Duration(seconds: 10),
    );
    expect(created.success, isTrue, reason: created.error);
    final recorder = _Recorder();
    final recorderRef = await system.spawn('recorder', () => recorder);
    final aggregate = system.getActor('wallet-$_walletId');
    final journalLength = store.journal[_walletPid]!.length;

    manager.tell(
      WalletCommandMessage(
          _walletId, UpdateWalletConfigurationCommand(walletId: _walletId, newMetadata: {'address_indices': {}})),
      sender: recorderRef,
    );
    // Old code: the update was journaled and no reply came.
    final reply = await recorder.waitFor<Map>((_) => true);
    expect(reply['error'], allOf(contains('address_indices'), contains('reserved')));
    expect(reply['command'], 'UpdateWalletConfigurationCommand');
    expect(store.journal[_walletPid], hasLength(journalLength));

    manager.tell(
      WalletCommandMessage(_walletId, UpdateWalletConfigurationCommand(walletId: _walletId, newMetadata: {'theme': 'dark'})),
      sender: recorderRef,
    );
    await _eventually(() => store.journal[_walletPid]!.length == journalLength + 1);
    final update = store.journal[_walletPid]!.last as WalletConfigurationUpdatedEvent;
    expect(update.newMetadata, {'theme': 'dark'});
    expect(identical(system.getActor('wallet-$_walletId'), aggregate), isTrue);
    expect(aggregate!.isAlive, isTrue);
  });

  test('WalletCoordinatorActor reports a creation naming outgoingTransactions as failed', () async {
    final noop = await system.spawn('noop', () => _Recorder());
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
    final events = <coord.CoordinatorEvent>[];
    final sub = coordinator.events.listen(events.add);
    addTearDown(sub.cancel);
    final ref = await system.spawn('coordinator', () => coordinator);

    ref.tell(coord.CreateWalletCommand(
      walletId: _walletId,
      name: 'hfai',
      mnemonic: _mnemonic,
      walletMetadata: {'network': 'testnet', 'outgoingTransactions': {}},
    ));

    // Old code: the wallet was created (with the seeded record) and the
    // coordinator waited on the projection to report success.
    await _eventually(() => events.whereType<coord.WalletCreatedEvent>().isNotEmpty);
    final reported = events.whereType<coord.WalletCreatedEvent>().single;
    expect(reported.success, isFalse);
    expect(reported.error, contains('outgoingTransactions'));
    expect(store.journal[_walletPid], anyOf(isNull, isEmpty));
  });
}

Future<void> _eventually(bool Function() condition) async {
  final deadline = DateTime.now().add(_wait);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('condition not met within $_wait');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

class _Recorder extends Actor {
  final List<dynamic> received = [];

  @override
  Future<void> onMessage(dynamic message) async {
    received.add(message);
  }

  Future<T> waitFor<T>(bool Function(T) match) async {
    final deadline = DateTime.now().add(_wait);
    while (DateTime.now().isBefore(deadline)) {
      for (final m in received.whereType<T>()) {
        if (match(m)) return m;
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('no matching $T within $_wait; received: $received');
  }
}
