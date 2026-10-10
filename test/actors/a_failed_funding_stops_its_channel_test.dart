/// Bead libspiffy-4kfq: a channel whose funding the wallet failed stops
/// sending `channel_open`.
///
/// A funding spending a coin already spent elsewhere sat at SENT_TO_NETWORK
/// for ever. The wallet failed it (INPUT_SPENT) but nothing told the
/// channel, so the client sent `channel_open` every `resendAtMost` until the
/// settlement margin, a day later, and the server spent each one asking ARC
/// while other channels' requests waited. The coordinator, which hears what
/// the wallet read model applies, tells the channel manager.
library;

import 'dart:async';

import 'package:dactor/dactor.dart';
import 'package:eventador/eventador.dart';
import 'package:test/test.dart';

import 'package:libspiffy/src/actors/payment_channel_messages.dart';
import 'package:libspiffy/src/actors/wallet_coordinator_actor.dart';
import 'package:libspiffy/src/core/wallet_events.dart' as domain;
import 'package:libspiffy/src/models/deferred_payment.dart';
import 'package:libspiffy/src/models/payment_channel.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';

const _walletId = 'wallet-4kfq';
const _channelId = 'ch-4kfq';
final _funding = 'f' * 64;

void main() {
  late ActorSystem actorSystem;
  late StreamController<Event> readModel;
  late InMemoryWalletStorage storage;
  late _Recorder manager;

  setUp(() {
    actorSystem = LocalActorSystem();
    readModel = StreamController<Event>.broadcast();
    storage = InMemoryWalletStorage();
    manager = _Recorder();
  });

  tearDown(() async {
    await readModel.close();
    await actorSystem.shutdown();
  });

  Future<void> start() async {
    final noop = await actorSystem.spawn('noop', () => _Recorder());
    final coordinator = WalletCoordinatorActor(
      walletManager: noop,
      invoiceCoordinator: noop,
      paymentCoordinator: noop,
      spvActor: noop,
      arcActor: noop,
      headerSyncActor: noop,
      benfordCoordinator: noop,
      channelManager: await actorSystem.spawn('manager', () => manager),
      walletProjection: noop,
      storage: storage,
      readModelEvents: readModel.stream,
    );
    await actorSystem.spawn('coordinator', () => coordinator);
  }

  Future<List<RecordFundingFailedMessage>> told() async {
    final deadline = DateTime.now().add(const Duration(milliseconds: 500));
    while (manager.received.isEmpty && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
    return manager.received.whereType<RecordFundingFailedMessage>().toList();
  }

  Future<void> deferred(String txid, {String? purpose, List<String> to = const [], DeferredPaymentState? state}) =>
      storage.storeDeferredPayment(DeferredPayment(
        walletId: _walletId,
        txid: txid,
        purpose: purpose,
        recipientAddresses: to,
        amount: BigInt.from(1000),
        fee: BigInt.from(50),
        state: state ?? DeferredPaymentState.failed,
        lastNetworkStatus: 'INPUT_SPENT',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ));

  test("a channel's funding the wallet fails: the channel manager is told", () async {
    await deferred(_funding, purpose: 'channel-funding', to: ['channel:$_channelId']);
    await start();
    readModel.add(domain.DeferredTransactionFailedEvent(
        walletId: _walletId, txid: _funding, networkStatus: 'INPUT_SPENT', reason: 'Input a:0 is already spent'));

    final message = (await told()).single;
    expect((message.channelId, message.fundingTxId, message.reason), (_channelId, _funding, 'Input a:0 is already spent'));
  });

  test('any other failed payment tells the channel manager nothing', () async {
    await deferred('b' * 64, purpose: 'invoice-payment', to: ['mxyz']);
    await start();
    readModel.add(domain.DeferredTransactionFailedEvent(walletId: _walletId, txid: 'b' * 64, networkStatus: 'REJECTED'));
    expect(await told(), isEmpty);
  });

  test('a funding failed before the channel heard of it is told at startup', () async {
    await storage.storeWallet(_walletId, 'w');
    await storage.storePaymentChannel(PaymentChannel(
      channelId: _channelId,
      walletId: _walletId,
      role: PaymentChannelRole.client,
      clientPeerId: 'me',
      serverPeerId: 'host',
      clientPubKeyHex: '02aa',
      fundingAmountSats: BigInt.from(1000),
      lockTimeUnix: 2000000000,
      state: PaymentChannelState.funding,
      fundingTxId: _funding,
    ));
    await deferred(_funding, purpose: 'channel-funding', to: ['channel:$_channelId']);
    await start();

    final message = (await told()).single;
    expect((message.channelId, message.fundingTxId, message.reason), (_channelId, _funding, 'INPUT_SPENT'));
  });

  test('a funding still outstanding at startup is left alone', () async {
    await storage.storeWallet(_walletId, 'w');
    await storage.storePaymentChannel(PaymentChannel(
      channelId: _channelId,
      walletId: _walletId,
      role: PaymentChannelRole.client,
      clientPeerId: 'me',
      serverPeerId: 'host',
      clientPubKeyHex: '02aa',
      fundingAmountSats: BigInt.from(1000),
      lockTimeUnix: 2000000000,
      state: PaymentChannelState.funding,
      fundingTxId: _funding,
    ));
    await deferred(_funding,
        purpose: 'channel-funding', to: ['channel:$_channelId'], state: DeferredPaymentState.outstanding);
    await start();
    expect(await told(), isEmpty);
  });
}

class _Recorder extends Actor {
  final received = <Object?>[];

  @override
  Future<void> onMessage(dynamic message) async => received.add(message);
}
