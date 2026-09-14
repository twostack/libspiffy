/// PaymentChannelManagerActor error-reply handling.
///
/// Covers audit finding A-M6 (channel part, doc/audit-2026-09-14.md): the
/// WalletManager answers a wallet it cannot load with a
/// `{'error': ..., 'walletId': ...}` map. Both address-generation ask sites
/// in the channel manager must turn that into a clean failure reply that
/// carries the manager's error, rather than casting the map or dropping it.
///
/// Still open per the audit (libspiffy-y23, not covered here): the pending
/// signature maps and QueryChannelState.

import 'package:test/test.dart';
import 'package:dactor/dactor.dart';
import 'package:dactor_test/dactor_test.dart';
import 'package:dartsv/dartsv.dart' show NetworkType;

import 'package:libspiffy/src/actors/payment_channel_manager_actor.dart';
import 'package:libspiffy/src/actors/payment_channel_messages.dart';
import 'package:libspiffy/src/actors/wallet_manager_actor.dart';
import 'package:libspiffy/src/services/dartsv_crypto_service.dart';
import 'package:libspiffy/src/storage/in_memory_secure_storage.dart';

import 'in_memory_event_store.dart';

void main() {
  late TestActorSystem actorSystem;
  late ActorRef channelManager;

  setUp(() async {
    actorSystem = TestActorSystem();
    final eventStore = InMemoryEventStore();
    final cryptoService = DartSVCryptoService();

    // The real WalletManager with an empty journal: every wallet is unknown,
    // so each address request is answered with the error map (A-M4).
    final walletManager = await actorSystem.spawn(
      'wallet-manager',
      () => WalletManagerActor(
        eventStore: eventStore,
        cryptoService: cryptoService,
        secureStorage: InMemorySecureStorage(),
      ),
    );
    channelManager = await actorSystem.spawn(
      'channel-manager',
      () => PaymentChannelManagerActor(
        walletManager: walletManager,
        eventStore: eventStore,
        cryptoService: cryptoService,
        networkType: NetworkType.TEST,
      ),
    );
  });

  tearDown(() async {
    await actorSystem.shutdown();
  });

  group('A-M6: WalletManager error-map reply', () {
    test('InitiateChannel for an unknown wallet replies failure with the error',
        () async {
      final reply = await channelManager.ask<ChannelInitiatedResponse>(
        InitiateChannelMessage(
          channelId: 'chan-1',
          walletId: 'no-such-wallet',
          clientPeerId: 'client',
          serverPeerId: 'server',
          fundingAmountSats: BigInt.from(100000),
          lockTimeDurationSeconds: 3600,
        ),
        const Duration(seconds: 10),
      );

      expect(reply.success, isFalse);
      // Old code fell through to the type check and reported
      // "Unexpected response type: _Map<String, dynamic>", hiding the cause.
      expect(reply.error, contains('Wallet not found'));
    });

    test('AcceptChannel for an unknown wallet replies failure with the error',
        () async {
      final reply = await channelManager.ask<ChannelAcceptedResponse>(
        AcceptChannelMessage(
          channelId: 'chan-2',
          walletId: 'no-such-wallet',
          clientPeerId: 'client',
          clientPubKeyHex: '02' * 33,
          clientAddressB58: 'mkHS9ne12qx9pS9VojpwU5xtRd4T7X7ZUt',
          fundingAmountSats: BigInt.from(100000),
          lockTimeUnix: 1700000000,
        ),
        const Duration(seconds: 10),
      );

      expect(reply.success, isFalse);
      expect(reply.error, contains('Wallet not found'));
    });
  });
}
