/// Bead libspiffy-29jd: channels that started opening and never finished are
/// reported at startup.
///
/// Restart recovery is otherwise reactive -- `ChannelP2PAdapter` rebuilds a
/// record only when an inbound stimulus names a channel. A channel whose
/// funding broadcast failed, or whose `channel_open` the peer never
/// received, is exactly the case where the counterparty has gone silent, so
/// nothing ever arrives to trigger it. V-100 gave the host levers
/// (`RetryChannelFundingCommand`, `ResendChannelOpenCommand`); what was
/// missing is any way to learn a channel needs one without polling.
///
/// The sweep REPORTS. It must not retry or journal anything: a funding
/// broadcast whose outcome was lost may already be in a mempool, and BSV is
/// first-seen-wins.
library;

import 'dart:async';

import 'package:dactor/dactor.dart';
import 'package:test/test.dart';

import 'package:libspiffy/src/actors/coordinator_messages.dart' as coord;
import 'package:libspiffy/src/actors/wallet_coordinator_actor.dart';
import 'package:libspiffy/src/models/payment_channel.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';

const _wallet = 'sweep-wallet';

void main() {
  late ActorSystem system;
  late InMemoryWalletStorage storage;
  late ActorRef noop;

  setUp(() async {
    system = LocalActorSystem();
    storage = InMemoryWalletStorage();
    noop = await system.spawn('noop', () => _Noop());
  });

  tearDown(() async => system.shutdown());

  PaymentChannel channel(String id, PaymentChannelState state,
          {PaymentChannelRole role = PaymentChannelRole.client}) =>
      PaymentChannel(
        channelId: id,
        walletId: _wallet,
        role: role,
        clientPeerId: 'client-peer',
        serverPeerId: 'server-peer',
        clientPubKeyHex: '02${'ab' * 32}',
        serverPubKeyHex: '03${'cd' * 32}',
        fundingAmountSats: BigInt.from(50000),
        lockTimeUnix: 1900000000,
        state: state,
      );

  /// Starts a coordinator over [storage] and collects what it tells the app.
  Future<List<coord.CoordinatorEvent>> startAndCollect() async {
    final coordinator = WalletCoordinatorActor(
      walletManager: noop,
      invoiceCoordinator: noop,
      paymentCoordinator: noop,
      spvActor: noop,
      arcActor: noop,
      headerSyncActor: noop,
      benfordCoordinator: noop,
      channelManager: noop,
      walletProjection: noop,
      storage: storage,
    );
    final events = <coord.CoordinatorEvent>[];
    final sub = coordinator.events.listen(events.add);
    addTearDown(sub.cancel);
    await system.spawn('coordinator-${DateTime.now().microsecondsSinceEpoch}',
        () => coordinator);
    // The sweep runs off the mailbox.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    return events;
  }

  test('a channel that never finished opening is reported; an open one is not',
      () async {
    await storage.storeWallet(_wallet, 'Sweep');
    // The two the bead names: a refund signed and awaiting funding
    // (`opening`), and a funding broadcast started (`funding`).
    await storage
        .storePaymentChannel(channel('refund-signed', PaymentChannelState.opening));
    await storage
        .storePaymentChannel(channel('funding-inflight', PaymentChannelState.funding));
    // And a healthy one, which is not stuck and must not be reported.
    await storage.storePaymentChannel(channel('healthy', PaymentChannelState.open));

    final events = await startAndCollect();

    final found =
        events.whereType<coord.UnfinishedChannelsFoundEvent>().toList();
    expect(found, hasLength(1),
        reason: 'one report per wallet that has any: '
            '${events.map((e) => e.runtimeType).toList()}');
    expect(found.single.walletId, _wallet);
    expect(found.single.channels.map((c) => c.channelId),
        unorderedEquals(['refund-signed', 'funding-inflight']));
    expect(found.single.channels.map((c) => c.state),
        unorderedEquals(['opening', 'funding']));
  });

  test('the report carries what the app needs to decide', () async {
    await storage.storeWallet(_wallet, 'Sweep');
    await storage
        .storePaymentChannel(channel('stuck', PaymentChannelState.funding));

    final events = await startAndCollect();

    final stuck = events
        .whereType<coord.UnfinishedChannelsFoundEvent>()
        .single
        .channels
        .single;
    expect(stuck.fundingAmountSats, BigInt.from(50000),
        reason: 'how much is tied up');
    expect(stuck.lockTimeUnix, 1900000000,
        reason: 'when the client can take it back with a refund claim');
    expect(stuck.counterpartyPeerId, 'server-peer',
        reason: 'who this side was talking to; a client reports the server');
  });

  test('a server-side channel reports the client as the counterparty',
      () async {
    await storage.storeWallet(_wallet, 'Sweep');
    await storage.storePaymentChannel(channel('server-side',
        PaymentChannelState.opening, role: PaymentChannelRole.server));

    final events = await startAndCollect();

    expect(
        events
            .whereType<coord.UnfinishedChannelsFoundEvent>()
            .single
            .channels
            .single
            .counterpartyPeerId,
        'client-peer');
  });

  test('nothing is reported when no channel is stuck', () async {
    await storage.storeWallet(_wallet, 'Sweep');
    await storage.storePaymentChannel(channel('a', PaymentChannelState.open));
    await storage.storePaymentChannel(channel('b', PaymentChannelState.closed));
    await storage.storePaymentChannel(channel('c', PaymentChannelState.expired));

    final events = await startAndCollect();

    expect(events.whereType<coord.UnfinishedChannelsFoundEvent>(), isEmpty,
        reason: 'no event means nothing needs attention; a terminal channel '
            'has nothing to resume');
  });

  test('the sweep retries nothing and tells no peer', () async {
    await storage.storeWallet(_wallet, 'Sweep');
    await storage
        .storePaymentChannel(channel('stuck', PaymentChannelState.funding));

    final events = await startAndCollect();

    // A funding broadcast whose outcome was lost may already be in a
    // mempool, and BSV is first-seen-wins: re-driving it is the app's call.
    expect(events.whereType<coord.ChannelP2PMessageToSendEvent>(), isEmpty,
        reason: 'the sweep must not talk to the counterparty');
    expect(events.whereType<coord.ChannelFundingRetriedEvent>(), isEmpty,
        reason: 'the sweep must not retry');
    expect(events.whereType<coord.ChannelOpenResentEvent>(), isEmpty);
  });

  test('a storage that throws does not stop the coordinator starting',
      () async {
    final coordinator = WalletCoordinatorActor(
      walletManager: noop,
      invoiceCoordinator: noop,
      paymentCoordinator: noop,
      spvActor: noop,
      arcActor: noop,
      headerSyncActor: noop,
      benfordCoordinator: noop,
      channelManager: noop,
      walletProjection: noop,
      storage: _ThrowingStorage(),
    );
    final events = <coord.CoordinatorEvent>[];
    final sub = coordinator.events.listen(events.add);
    addTearDown(sub.cancel);

    final ref = await system.spawn('coordinator-throws', () => coordinator);
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(ref.isAlive, isTrue,
        reason: 'a report that cannot be made must not stop the coordinator');
    expect(events.whereType<coord.UnfinishedChannelsFoundEvent>(), isEmpty);
  });
}

class _Noop extends Actor {
  @override
  Future<void> onMessage(dynamic message) async {}
}

/// A read model whose wallet list fails.
class _ThrowingStorage extends InMemoryWalletStorage {
  @override
  Future<List<String>> listWallets() async =>
      throw StateError('the read model is unavailable');
}
