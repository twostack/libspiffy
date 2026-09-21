/// Payment-channel seam, pass 2: what the inbound protocol path tells the
/// counterparty.
///
/// * Bead libspiffy-fg06. `_handlePaymentUpdate` told `AcknowledgePaymentMessage`
///   with NO sender, so a payment the server refused answered nobody: no
///   `payment_ack`, no `channel_error`. The client waited forever, unable to
///   tell a refusal from a lost message.
/// * Bead libspiffy-y8x3. V-100 made an inbound `channel_open` idempotent for
///   a repeat naming the same funding output. `channel_accept` and
///   `refund_signed` had no such treatment: both forward to the aggregate,
///   which refuses a duplicate on a state guard, and that refusal reaches
///   the peer as `channel_error`. A counterparty re-sending for exactly the
///   reason V-100 exists -- it is not sure the first one arrived -- was told
///   the channel had failed.
library;

import 'dart:async';

import 'package:dactor/dactor.dart';
import 'package:test/test.dart';

import 'package:libspiffy/src/actors/channel_p2p_adapter.dart';
import 'package:libspiffy/src/actors/coordinator_messages.dart' as coord;
import 'package:libspiffy/src/actors/payment_channel_messages.dart';
import 'package:libspiffy/src/actors/wallet_coordinator_actor.dart';
import 'package:libspiffy/src/core/channel_events.dart' as ch;
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';
import '../mocks/policy_rate_arc.dart';

void main() {
  late ActorSystem actorSystem;
  late _ProbeActor channelManagerProbe;
  late ActorRef channelManager;
  late ActorRef walletManager;
  late ActorRef replyTo;
  late StreamController<ch.ChannelEvent> channelEvents;
  late List<coord.CoordinatorEvent> emitted;
  late ChannelP2PAdapter adapter;

  setUp(() async {
    actorSystem = LocalActorSystem();
    channelManagerProbe = _ProbeActor();
    channelManager =
        await actorSystem.spawn('channel-manager', () => channelManagerProbe);
    walletManager = await actorSystem.spawn('wallet-manager', () => _ProbeActor());
    replyTo = await actorSystem.spawn('coordinator', () => _ProbeActor());
    channelEvents = StreamController<ch.ChannelEvent>.broadcast();
    emitted = [];

    adapter = ChannelP2PAdapter(
      channelManager: channelManager,
      walletManager: walletManager,
      arcActor: await actorSystem.spawn('arc', () => PolicyRateArc()),
      emitEvent: emitted.add,
      channelEvents: channelEvents.stream,
      walletId: 'server-wallet',
      myPeerId: 'server-peer',
    );
    adapter.updateReplyTo(replyTo);
  });

  tearDown(() async {
    adapter.dispose();
    await channelEvents.close();
    await actorSystem.shutdown();
  });

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 50));

  /// Makes this node the SERVER of [channelId], which is the side that
  /// receives `payment_update`.
  Future<void> serverChannel(String channelId) async {
    channelEvents.add(ch.ChannelAcceptedEvent(
      channelId: channelId,
      walletId: 'server-wallet',
      clientPeerId: 'client-peer',
      clientPubKeyHex: '02${'ab' * 32}',
      clientAddressB58: 'mqCnSf8i6kmaQaJ54HjQ8EUJnuK4AnCv12',
      serverPubKeyHex: '03${'cd' * 32}',
      serverAddressB58: 'mkHS9ne12qx9pS9VojpwU5xtRd4T7X7ZUt',
      derivationIndex: 3,
      fundingAmountSats: BigInt.from(50000),
      lockTimeUnix: 1900000000,
    ));
    await settle();
  }

  List<Map<String, dynamic>> peerMessages(String type) => emitted
      .whereType<coord.ChannelP2PMessageToSendEvent>()
      .where((e) => e.messageType == type)
      .map((e) => e.payload)
      .toList();

  group('a refused payment_update is answered (libspiffy-fg06)', () {
    test('the acknowledgement carries a reply target at all', () async {
      const channelId = 'chan-fg06-target';
      await serverChannel(channelId);

      adapter.handleP2PMessage('client-peer', 'payment_update', {
        'channelId': channelId,
        'amountSats': 1000,
        'paymentTxHex': '0100000000',
        'clientSignatureHex': '30' * 36,
        'proposedSequence': 1,
        'proposedClientBalance': 49000,
        'proposedServerBalance': 1000,
      });
      await settle();

      final sent = channelManagerProbe.received
          .whereType<AcknowledgePaymentMessage>()
          .single;
      expect(channelManagerProbe.senderOf(sent), isNotNull,
          reason: 'told with no sender, the manager answers into the void '
              'and the client waits forever');
    });

    test('a refusal reaches the client as channel_error', () async {
      const channelId = 'chan-fg06-refused';
      await serverChannel(channelId);

      // What the manager answers when the aggregate refuses the payment.
      adapter.handlePaymentAcknowledged(PaymentAcknowledgedResponse(
        channelId: channelId,
        success: false,
        error: 'Proposed balances do not sum to the funding amount',
      ));
      await settle();

      final errors = peerMessages('channel_error');
      expect(errors, hasLength(1),
          reason: 'the client must be able to tell a refusal from a lost '
              'message');
      expect(errors.single['channelId'], channelId);
      expect(errors.single['error'], contains('sum'));
      expect(emitted.whereType<coord.ErrorEvent>(), isNotEmpty,
          reason: 'and the host is told too');
    });

    /// The leaf tests above call `adapter.handlePaymentAcknowledged` directly,
    /// so they stay green with the coordinator's dispatch arm deleted -- the
    /// wiring-vs-leaf hole that V-101 was written under and then fell into.
    /// The manager answers the COORDINATOR, because the adapter forwards with
    /// `sender: _replyTo`; only the coordinator's arm hands it back. This
    /// drives a real coordinator.
    test('the coordinator routes a refusal to the adapter, which tells the '
        'client', () async {
      const channelId = 'chan-fg06-routed';
      final coordinatorChannelEvents =
          StreamController<ch.ChannelEvent>.broadcast();
      addTearDown(coordinatorChannelEvents.close);
      final noop = await actorSystem.spawn('noop-2', () => _ProbeActor());
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
        storage: InMemoryWalletStorage(),
        // What makes the coordinator build its own adapter to route to.
        channelEvents: coordinatorChannelEvents.stream,
      );
      final hostEvents = <coord.CoordinatorEvent>[];
      final sub = coordinator.events.listen(hostEvents.add);
      addTearDown(sub.cancel);
      final coordinatorRef =
          await actorSystem.spawn('coordinator-ack', () => coordinator);

      // The coordinator's adapter has to know the channel to find the peer.
      coordinatorChannelEvents.add(ch.ChannelAcceptedEvent(
        channelId: channelId,
        walletId: 'server-wallet',
        clientPeerId: 'client-peer',
        clientPubKeyHex: '02${'ab' * 32}',
        clientAddressB58: 'mqCnSf8i6kmaQaJ54HjQ8EUJnuK4AnCv12',
        serverPubKeyHex: '03${'cd' * 32}',
        serverAddressB58: 'mkHS9ne12qx9pS9VojpwU5xtRd4T7X7ZUt',
        derivationIndex: 3,
        fundingAmountSats: BigInt.from(50000),
        lockTimeUnix: 1900000000,
      ));
      await settle();

      // What the manager sends back when the aggregate refuses the payment.
      coordinatorRef.tell(PaymentAcknowledgedResponse(
        channelId: channelId,
        success: false,
        error: 'Proposed balances do not sum to the funding amount',
      ));

      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (hostEvents
          .whereType<coord.ChannelP2PMessageToSendEvent>()
          .where((e) => e.messageType == 'channel_error')
          .isEmpty) {
        if (DateTime.now().isAfter(deadline)) {
          fail('the coordinator never routed the refusal to the adapter; '
              'events: ${hostEvents.map((e) => e.runtimeType).toList()}');
        }
        await Future.delayed(const Duration(milliseconds: 20));
      }
    });

    test('an accepted payment sends no channel_error', () async {
      const channelId = 'chan-fg06-ok';
      await serverChannel(channelId);

      adapter.handlePaymentAcknowledged(PaymentAcknowledgedResponse(
        channelId: channelId,
        sequenceNumber: 1,
        serverSignatureHex: '30' * 36,
        success: true,
      ));
      await settle();

      expect(peerMessages('channel_error'), isEmpty,
          reason: 'the payment_ack is sent by the channel event, and a '
              'success must not also look like a failure');
    });
  });
}

/// Records what it is told, and who told it.
class _ProbeActor extends Actor {
  final List<dynamic> received = [];
  final Map<dynamic, ActorRef?> _senders = {};

  ActorRef? senderOf(dynamic message) => _senders[message];

  @override
  Future<void> onMessage(dynamic message) async {
    received.add(message);
    // ignore: invalid_use_of_internal_member
    _senders[message] = context.sender;
  }
}
