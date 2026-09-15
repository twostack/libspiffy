/// LibSpiffyActorSystem wallet preload at initialize (bead libspiffy-a5l).
///
/// initialize() told the wallet manager to preload each stored wallet and then
/// slept a fixed 100 ms "to let the actor message pump process preload
/// commands". Every initialize with at least one wallet took that 100 ms,
/// however quickly the preloads finished, and a preload slower than 100 ms was
/// not waited for anyway. initialize() now returns as soon as the manager has
/// processed the preloads, still capped at 100 ms.
///
/// The test runs initialize() in a zone whose one-shot timers of 50 ms or
/// more never fire. The old fixed sleep then never ends; the new code needs
/// no timer to return. This observes the dependency on the sleep, not
/// wall-clock time.
library;

import 'dart:async';
import 'dart:io';

import 'package:eventador/eventador.dart';
import 'package:isar/isar.dart';
import 'package:test/test.dart';

import 'package:libspiffy/internals.dart';
import 'package:libspiffy/libspiffy.dart';

import '../integration/isar_test_helper.dart';

const _mnemonic = 'abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon abandon abandon about';

/// A timer that never fires. It stays active until cancelled, like a real
/// pending timer (Future.timeout drops a result once its timer is inactive).
class _InertTimer implements Timer {
  bool _active = true;
  @override
  void cancel() => _active = false;
  @override
  bool get isActive => _active;
  @override
  int get tick => 0;
}

void main() {
  setUpAll(() async {
    await ensureIsarInitialized();
  });

  late Directory tempDir;
  late Isar isar;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('libspiffy_a5l_');
    isar = await Isar.open(
      LibSpiffySchemas.allSchemas,
      directory: tempDir.path,
      name: 'a5l_${DateTime.now().microsecondsSinceEpoch}',
    );
  });

  tearDown(() async {
    if (isar.isOpen) await isar.close();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  test('initialize returns once the stored wallets are preloaded, without '
      'waiting on a fixed sleep', () async {
    final secureStorage = InMemorySecureStorage();

    // A first system journals wallet w1 and its read-model row.
    final first = LibSpiffyActorSystem();
    try {
      await first.initialize(
        isar: isar,
        dataDirectory: tempDir.path,
        secureStorage: secureStorage,
        enableP2P: false,
      );
      final projected = first.walletProjectionRef!.ask<dynamic>(
        AwaitEventApplied(
          (e) => e is WalletCreatedEvent && e.walletId == 'w1',
          timeout: const Duration(seconds: 10),
        ),
        const Duration(seconds: 12),
      );
      final created = await first.walletManager.ask<WalletCreatedMessage>(
        CreateWalletMessage('w1', 'Wallet 1', mnemonic: _mnemonic),
        const Duration(seconds: 10),
      );
      expect(created.success, isTrue, reason: created.error);
      expect(await projected, isA<EventAppliedResponse>());
    } finally {
      await first.shutdown();
    }
    expect(await IsarWalletStorage(isar).listWallets(), contains('w1'));

    // A second system over the same data preloads w1 during initialize.
    final second = LibSpiffyActorSystem();
    try {
      final initialized = runZoned(
        () => second.initialize(
          isar: isar,
          dataDirectory: tempDir.path,
          secureStorage: secureStorage,
          enableP2P: false,
        ),
        zoneSpecification: ZoneSpecification(
          createTimer: (self, parent, zone, duration, callback) =>
              duration >= const Duration(milliseconds: 50)
                  ? _InertTimer()
                  : parent.createTimer(zone, duration, callback),
        ),
      );
      // The bound only turns a hang into a failure; the timer is created
      // outside the zone above, so it fires.
      await initialized.timeout(
        const Duration(seconds: 30),
        onTimeout: () => fail('initialize() did not return: it waits on a '
            'timer of 50 ms or more'),
      );

      expect(second.isInitialized, isTrue);
      expect(second.actorSystem.getActor('wallet-w1'), isNotNull,
          reason: 'initialize() returns after the preload was processed');
    } finally {
      await second.shutdown();
    }
  });

  test('a preload asked with a sender is answered once handled', () async {
    final libspiffy = LibSpiffyActorSystem();
    try {
      await libspiffy.initialize(
        isar: isar,
        dataDirectory: tempDir.path,
        secureStorage: InMemorySecureStorage(),
        enableP2P: false,
      );
      final manager = libspiffy.walletManager;
      final created = await manager.ask<WalletCreatedMessage>(
        CreateWalletMessage('w1', 'Wallet 1', mnemonic: _mnemonic),
        const Duration(seconds: 10),
      );
      expect(created.success, isTrue, reason: created.error);

      final known = await manager.ask<WalletPreloadedResponse>(
        WalletCommandMessage('w1', PreloadWalletCommand(walletId: 'w1')),
        const Duration(seconds: 10),
      );
      expect(known.walletId, 'w1');
      expect(known.success, isTrue);
      expect(known.error, isNull);

      final ghost = await manager.ask<WalletPreloadedResponse>(
        WalletCommandMessage('ghost', PreloadWalletCommand(walletId: 'ghost')),
        const Duration(seconds: 10),
      );
      expect(ghost.walletId, 'ghost');
      expect(ghost.success, isFalse);
      expect(ghost.error, 'Wallet ghost not loaded');
      expect(libspiffy.actorSystem.getActor('wallet-ghost'), isNull);
    } finally {
      await libspiffy.shutdown();
    }
  });
}
