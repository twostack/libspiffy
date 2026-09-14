import 'dart:io';

import 'package:dactor/dactor.dart';
import 'package:isar/isar.dart';
import 'package:logging/logging.dart' as logging;
import 'package:test/test.dart';

import 'package:libspiffy/libspiffy.dart';

import '../integration/isar_test_helper.dart';

const _mnemonic = 'abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon abandon abandon about';

/// Top-level actors LibSpiffyActorSystem spawns (enableP2P: false, no
/// blockchain data source, so no import actor).
const _libspiffyActorIds = [
  'projection-wallet-projection',
  'projection-invoice-projection',
  'projection-channel-projection',
  'wallet-manager',
  'invoice-coordinator',
  'payment-coordinator',
  'spv-actor',
  'header-sync',
  'arc-actor',
  'transaction-lifecycle-coordinator',
  'benford-coordinator',
  'payment-channel-manager',
  'wallet-coordinator',
];

/// Audit finding A-M5 (libspiffy-9dv, doc/audit-2026-09-14.md):
/// LibSpiffyActorSystem lifecycle gaps.
/// - `initialize` had no guard: a second call built a second actor system
///   and storage stack over the first.
/// - `isInitialized` stayed true after `shutdown`.
/// - With a host-owned ActorSystem, `shutdown` stopped only the projections;
///   every other libspiffy actor (and the aggregates they spawned) kept
///   running in the host's system.
/// - A failed P2P start dropped its PeerManager without shutting it down
///   (health-check timer, peer sockets); a normal shutdown did the same.
void main() {
  setUpAll(() async {
    await ensureIsarInitialized();
  });

  late Directory tempDir;
  late Isar isar;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('libspiffy_am5_');
    isar = await Isar.open(
      LibSpiffySchemas.allSchemas,
      directory: tempDir.path,
      name: 'am5_${DateTime.now().microsecondsSinceEpoch}',
    );
  });

  tearDown(() async {
    if (isar.isOpen) await isar.close();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  group('A-M5: LibSpiffyActorSystem lifecycle', () {
    test('a second initialize throws StateError and leaves the first system '
        'running', () async {
      final libspiffy = LibSpiffyActorSystem();
      try {
        await libspiffy.initialize(
          isar: isar,
          dataDirectory: tempDir.path,
          secureStorage: InMemorySecureStorage(),
          enableP2P: false,
        );
        final walletManager = libspiffy.walletManager;

        await expectLater(
          libspiffy.initialize(
            isar: isar,
            dataDirectory: tempDir.path,
            secureStorage: InMemorySecureStorage(),
            enableP2P: false,
          ),
          throwsA(isA<StateError>().having(
              (e) => e.message, 'message', contains('already initialized'))),
        );

        expect(libspiffy.isInitialized, isTrue);
        expect(identical(libspiffy.walletManager, walletManager), isTrue);
      } finally {
        await libspiffy.shutdown();
      }
    });

    test('isInitialized is false after shutdown, and the system cannot be '
        're-initialized', () async {
      final libspiffy = LibSpiffyActorSystem();
      await libspiffy.initialize(
        isar: isar,
        dataDirectory: tempDir.path,
        secureStorage: InMemorySecureStorage(),
        enableP2P: false,
      );
      expect(libspiffy.isInitialized, isTrue);

      await libspiffy.shutdown();

      expect(libspiffy.isInitialized, isFalse);
      expect(() => libspiffy.walletManager, throwsStateError);
      await expectLater(
        libspiffy.initialize(
          isar: isar,
          dataDirectory: tempDir.path,
          secureStorage: InMemorySecureStorage(),
          enableP2P: false,
        ),
        throwsA(isA<StateError>()
            .having((e) => e.message, 'message', contains('shut down'))),
      );
      // A second shutdown is a no-op.
      await libspiffy.shutdown();
    });

    test('shutdown stops libspiffy\'s actors when the host owns the '
        'ActorSystem', () async {
      final hostSystem = LocalActorSystem(ActorSystemConfig());
      final libspiffy = LibSpiffyActorSystem();
      try {
        await libspiffy.initialize(
          actorSystem: hostSystem,
          isar: isar,
          dataDirectory: tempDir.path,
          secureStorage: InMemorySecureStorage(),
          enableP2P: false,
        );
        final created = await libspiffy.walletManager.ask<WalletCreatedMessage>(
          CreateWalletMessage('w1', 'Wallet 1', mnemonic: _mnemonic),
          const Duration(seconds: 10),
        );
        expect(created.success, isTrue, reason: created.error);

        for (final id in [..._libspiffyActorIds, 'wallet-w1']) {
          expect(hostSystem.getActor(id), isNotNull, reason: '$id before');
        }

        await libspiffy.shutdown();

        final stillRunning = [
          for (final id in [..._libspiffyActorIds, 'wallet-w1'])
            if (hostSystem.getActor(id) != null) id,
        ];
        expect(stillRunning, isEmpty,
            reason: 'libspiffy actors left running in the host system');

        // The host's own actors are untouched.
        final hostActor = await hostSystem.spawn('host-actor', () => _Noop());
        expect(hostActor.isAlive, isTrue);
      } finally {
        await hostSystem.shutdown();
      }
    });

    test('a failed P2P start shuts down the PeerManager it created', () async {
      final records = <logging.LogRecord>[];
      final previousLevel = logging.Logger.root.level;
      logging.Logger.root.level = logging.Level.ALL;
      final sub = logging.Logger.root.onRecord.listen(records.add);
      final libspiffy = LibSpiffyActorSystem();
      try {
        // Port 1 on loopback refuses immediately: no network involved.
        await expectLater(
          libspiffy.initialize(
            isar: isar,
            dataDirectory: tempDir.path,
            secureStorage: InMemorySecureStorage(),
            networkType: 'regtest',
            enableP2P: true,
            peerAddresses: ['127.0.0.1:1'],
          ),
          throwsA(isA<StateError>().having((e) => e.message, 'message',
              contains('P2P initialization failed'))),
        );

        expect(
          records.where((r) =>
              r.loggerName == 'LibSpiffy-SpiffyNode' &&
              r.message.contains('Shutting down peer manager')),
          isNotEmpty,
          reason: 'the PeerManager (health-check timer, sockets) was dropped '
              'without shutdown',
        );
      } finally {
        await sub.cancel();
        logging.Logger.root.level = previousLevel;
        await libspiffy.shutdown();
      }
    });
  });
}

class _Noop extends Actor {
  @override
  Future<void> onMessage(dynamic message) async {}
}
