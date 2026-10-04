/// The actors take commands before the header sync is done
/// (spiffyvault-cfh): on a first install the CDN sync runs for minutes, and
/// creating a wallet must not wait for it.

import 'dart:async';
import 'dart:io';

import 'package:dactor/dactor.dart';
import 'package:isar_community/isar.dart';
import 'package:libspiffy/libspiffy.dart';
import 'package:libspiffy/src/actors/libspiffy_actor_system.dart';
import 'package:libspiffy/src/actors/wallet_messages.dart';
import 'package:test/test.dart';

import 'isar_test_helper.dart';

void main() {
  setUpAll(() async {
    await ensureIsarInitialized();
  });

  test('ready completes and a wallet is created while the CDN sync still runs', () async {
    // A header CDN that takes connections and never answers, not even the
    // TLS handshake (the CDN client takes https only).
    final cdn = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final stalled = <Socket>[];
    cdn.listen(stalled.add);

    final dir = await Directory.systemTemp.createTemp('ready_test_');
    final isar = await Isar.open(LibSpiffySchemas.allSchemas,
        directory: dir.path, name: 'ready_${DateTime.now().microsecondsSinceEpoch}');
    final actorSystem = LocalActorSystem(ActorSystemConfig());
    final libspiffy = LibSpiffyActorSystem();

    var initialized = false;
    final init = libspiffy
        .initialize(
          actorSystem: actorSystem,
          isar: isar,
          dataDirectory: dir.path,
          enableP2P: false,
          cdnBaseUrl: 'https://127.0.0.1:${cdn.port}',
        )
        .then((_) => initialized = true, onError: (_) => initialized = true);

    try {
      await libspiffy.ready.timeout(const Duration(seconds: 10));
      expect(libspiffy.isReady, isTrue);
      expect(initialized, isFalse, reason: 'the CDN sync is still waiting on the server');

      final created = Completer<WalletCreatedMessage>();
      final receiver = await actorSystem.spawn('receiver', () => _Receiver(created));
      final mnemonic = await DartSVCryptoService().generateMnemonic();
      libspiffy.walletManager.tell(CreateWalletMessage('w-ready', 'Ready', mnemonic: mnemonic), sender: receiver);
      final response = await created.future.timeout(const Duration(seconds: 10));
      expect(response.success, isTrue);
      expect(initialized, isFalse, reason: 'the wallet did not wait for the header sync');
    } finally {
      for (final socket in stalled) {
        socket.destroy();
      }
      await cdn.close();
      await init.timeout(const Duration(seconds: 60), onTimeout: () => true);
      await libspiffy.shutdown();
      await actorSystem.shutdown();
      await isar.close();
      await dir.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(seconds: 90)));
}

class _Receiver extends Actor {
  final Completer<WalletCreatedMessage> created;
  _Receiver(this.created);

  @override
  Future<void> onMessage(dynamic message) async {
    if (message is WalletCreatedMessage && !created.isCompleted) created.complete(message);
  }
}
