/// Bead overnode_v2-0o5.3.2: a channel message the transport loses is sent
/// again, and an app's payment is answered when the server acknowledges it.
///
/// The adapter handed each message to the app's transport once. A lost
/// `payment_update` was reported sent, and the server, whose balances no
/// longer followed, refused every later payment; a lost `channel_close` left
/// the channel open until its lock time.
library;

import 'dart:async';

import 'package:dactor/dactor.dart';
import 'package:test/test.dart';

import 'package:libspiffy/src/actors/channel_p2p_adapter.dart';
import 'package:libspiffy/src/actors/coordinator_messages.dart' as coord;
import 'package:libspiffy/src/actors/payment_channel_messages.dart';
import 'package:libspiffy/src/core/channel_events.dart';
import 'package:libspiffy/src/models/channel_timing.dart';
import 'package:libspiffy/src/models/fee_rate.dart';

import '../mocks/policy_rate_arc.dart';

const _channelId = 'chan-delivery';
const _client = 'client-peer';
const _server = 'server-peer';

final _timing = ChannelTiming(
  settlementMargin: const Duration(minutes: 10),
  minimumLifetime: const Duration(hours: 1),
  resendAfter: const Duration(milliseconds: 100),
  resendAtMost: const Duration(milliseconds: 200),
  confirmWithin: const Duration(milliseconds: 500),
);

void main() {
  late ActorSystem system;
  late _Manager manager;
  late List<coord.CoordinatorEvent> emitted;
  late StreamController<ChannelEvent> events;
  late ChannelP2PAdapter adapter;

  Future<void> spawn(String myPeerId) async {
    adapter = ChannelP2PAdapter(
      channelManager: await system.spawn('manager', () => manager),
      walletManager: await system.spawn('wallet', () => _Manager()),
      arcActor: await system.spawn('arc', () => PolicyRateArc(const FeeRate(satoshis: 100, bytes: 1000))),
      emitEvent: emitted.add,
      channelEvents: events.stream,
      walletId: 'w',
      myPeerId: myPeerId,
      timing: _timing,
    );
    adapter.updateReplyTo(await system.spawn('coordinator', () => _Manager()));
  }

  setUp(() {
    system = LocalActorSystem();
    manager = _Manager();
    emitted = [];
    events = StreamController<ChannelEvent>.broadcast();
  });
  tearDown(() async {
    adapter.dispose();
    await events.close();
    await system.shutdown();
  });

  Future<void> settle([int ms = 50]) => Future<void>.delayed(Duration(milliseconds: ms));

  List<coord.P2PMessageToSendEvent> sent(String type) =>
      emitted.whereType<coord.P2PMessageToSendEvent>().where((m) => m.messageType == type).toList();

  List<T> emittedOf<T>() => emitted.whereType<T>().toList();

  Future<void> clientChannel() async {
    await spawn(_client);
    events.add(ChannelRequestedEvent(
      channelId: _channelId,
      walletId: 'w',
      clientPeerId: _client,
      serverPeerId: _server,
      clientPubKeyHex: '02' * 33,
      clientAddressB58: 'mqCnSf8i6kmaQaJ54HjQ8EUJnuK4AnCv12',
      derivationIndex: 7,
      fundingAmountSats: BigInt.from(100000),
      lockTimeUnix: 1900000000,
    ));
    await settle();
  }

  /// The app pays [sats] as request [requestId]; the channel records it at
  /// [sequence], leaving the server [serverBalance].
  Future<void> pay(String requestId, int sats, int sequence, int serverBalance) async {
    adapter.handleMakePayment(coord.ChannelPayCommand(
        channelId: _channelId, walletId: 'w', amountSats: sats, requestId: requestId));
    await settle();
    events.add(PaymentRecordedEvent(
      channelId: _channelId,
      amountSats: BigInt.from(sats),
      newClientBalanceSats: BigInt.from(100000 - serverBalance),
      newServerBalanceSats: BigInt.from(serverBalance),
      sequenceNumber: sequence,
      paymentTxHex: 'tx$sequence',
      paymentTxId: 'id$sequence',
      clientSignatureHex: 'sig$sequence',
    ));
    await settle(20);
  }

  void ack(int sequence) =>
      adapter.handleP2PMessage(_server, 'payment_ack', {'channelId': _channelId, 'sequenceNumber': sequence});

  group('a payment', () {
    test('is answered when the server acknowledges it, and not before', () async {
      await clientChannel();
      await pay('r1', 1000, 1, 1000);

      expect(sent('payment_update').single.payload['proposedSequence'], 1);
      expect(emittedOf<coord.ChannelPaymentPendingEvent>().single.amountSats, 1000);
      // Old code: answered here, as soon as the transport had it.
      expect(emittedOf<coord.ChannelPaymentEvent>(), isEmpty);

      ack(1);
      await settle();

      final paid = emittedOf<coord.ChannelPaymentEvent>().single;
      expect(paid.requestId, 'r1');
      expect(paid.serverBalance, 1000);
      final sends = sent('payment_update').length;
      await settle(400);
      expect(sent('payment_update'), hasLength(sends), reason: 'an acknowledged payment is not resent');
    });

    test('is resent until acknowledged, waiting longer each time', () async {
      await clientChannel();
      await pay('r1', 1000, 1, 1000);

      await settle(450);

      // At 100, 300 and (capped) 500 ms.
      expect(sent('payment_update').length, inInclusiveRange(3, 4));
      expect(sent('payment_update').map((m) => m.payload['proposedSequence']).toSet(), {1});
      expect(sent('payment_update').every((m) => m.toPeerId == _server), isTrue);
    });

    test('a later payment replaces an unacknowledged one, and its ack confirms both', () async {
      await clientChannel();
      await pay('r1', 1000, 1, 1000);
      await pay('r2', 500, 2, 1500);
      emitted.removeWhere((e) => e is coord.P2PMessageToSendEvent);

      await settle(150);
      expect(sent('payment_update').map((m) => m.payload['proposedSequence']).toSet(), {2},
          reason: 'the later payment carries the balances of both');

      ack(2);
      await settle();
      expect(emittedOf<coord.ChannelPaymentEvent>().map((e) => (e.sequence, e.requestId)), [(1, 'r1'), (2, 'r2')]);
    });

    test('unacknowledged too long is reported failed, is still sent, and is confirmed late', () async {
      await clientChannel();
      await pay('r1', 1000, 1, 1000);

      await settle(600);
      final failed = emittedOf<coord.ErrorEvent>().single;
      expect(failed.requestId, 'r1');
      expect(failed.message, contains('not acknowledged'));
      final sends = sent('payment_update').length;
      await settle(250);
      expect(sent('payment_update').length, greaterThan(sends), reason: 'a failed payment is kept and resent');

      ack(1);
      await settle();
      final late = emittedOf<coord.ChannelPaymentEvent>().single;
      expect(late.requestId, isNull, reason: 'its request was already answered');
      expect(late.sequence, 1);
    });

    test('the server refuses is answered with the refusal and not resent', () async {
      await clientChannel();
      await pay('r1', 1000, 1, 1000);

      adapter.handleP2PMessage(_server, 'channel_error',
          {'channelId': _channelId, 'error': 'balances do not follow', 'sequenceNumber': 1});
      await settle();

      final refused = emittedOf<coord.ErrorEvent>().single;
      expect(refused.requestId, 'r1');
      expect(refused.message, contains('balances do not follow'));
      final sends = sent('payment_update').length;
      await settle(400);
      expect(sent('payment_update'), hasLength(sends));
      expect(emittedOf<coord.ErrorEvent>(), hasLength(1), reason: 'no second, timed-out failure');
    });

    test('a failed send is retried sooner than the next resend', () async {
      await clientChannel();
      await pay('r1', 1000, 1, 1000);
      await settle(320); // two resends: the next waits 200 ms
      final sends = sent('payment_update').length;

      adapter.handleSendFailed(coord.P2PSendFailed(
          toPeerId: _server, messageType: 'payment_update', payload: {'channelId': _channelId}, error: 'no route'));
      await settle(130);

      expect(sent('payment_update').length, sends + 1);
    });
  });

  group("the client's close", () {
    void closing() => events.add(ChannelClosingEvent(
          channelId: _channelId,
          reason: 'left the room',
          initiator: 'client',
          clientBalanceSats: BigInt.from(99000),
          serverBalanceSats: BigInt.from(1000),
        ));

    test('carries the latest payment and is resent until channel_closed', () async {
      await clientChannel();
      await pay('r1', 1000, 1, 1000);
      closing();
      await settle();

      final close = sent('channel_close').first;
      expect(close.toPeerId, _server);
      expect((close.payload['payment'] as Map)['proposedSequence'], 1);
      expect((close.payload['payment'] as Map)['clientSignatureHex'], 'sig1');

      await settle(250);
      expect(sent('channel_close').length, greaterThan(1));

      adapter.handleP2PMessage(_server, 'channel_closed',
          {'channelId': _channelId, 'settlementTxId': 'ab' * 32, 'settlementTxHex': 'cafe'});
      await settle();
      final closes = sent('channel_close').length + sent('payment_update').length;
      await settle(300);
      expect(sent('channel_close').length + sent('payment_update').length, closes,
          reason: 'nothing is resent once the server has closed');
      expect(manager.received.whereType<RecordSettlementMessage>().single.settlementTxHex, 'cafe');
    });

    test("confirms a payment the settlement paid, and fails one it did not", () async {
      await clientChannel();
      await pay('r1', 1000, 1, 1000);
      await pay('r2', 500, 2, 1500);
      closing();
      await settle();

      events.add(ChannelClosedEvent(
        channelId: _channelId,
        settlementTxId: 'ab' * 32,
        finalClientBalanceSats: BigInt.from(99000),
        finalServerBalanceSats: BigInt.from(1000),
        settlementTxHex: 'cafe',
      ));
      await settle();

      expect(emittedOf<coord.ChannelPaymentEvent>().single.requestId, 'r1');
      final failed = emittedOf<coord.ErrorEvent>().single;
      expect(failed.requestId, 'r2');
      expect(failed.message, contains('closed without the payment of 500 sats'));
    });
  });

  group('the server', () {
    Future<void> serverChannel() async {
      await spawn(_server);
      events.add(ChannelAcceptedEvent(
        channelId: _channelId,
        walletId: 'w',
        clientPeerId: _client,
        clientPubKeyHex: '02' * 33,
        clientAddressB58: 'mqCnSf8i6kmaQaJ54HjQ8EUJnuK4AnCv12',
        serverPubKeyHex: '03' * 33,
        serverAddressB58: 'mkHS9ne12qx9pS9VojpwU5xtRd4T7X7ZUt',
        derivationIndex: 3,
        fundingAmountSats: BigInt.from(100000),
        lockTimeUnix: 1900000000,
        serverPeerId: _server,
      ));
      await settle();
    }

    Map<String, dynamic> payment({int sequence = 2, int serverBalance = 1500, int amount = 500}) => {
          'channelId': _channelId,
          'amountSats': amount,
          'paymentTxHex': 'tx',
          'clientSignatureHex': 'sig',
          'proposedSequence': sequence,
          'proposedClientBalance': 100000 - serverBalance,
          'proposedServerBalance': serverBalance,
        };

    test('takes the payment a close carries before closing', () async {
      await serverChannel();

      adapter.handleP2PMessage(_client, 'channel_close',
          {'channelId': _channelId, 'reason': 'left', 'payment': payment()});
      await settle();

      final asked = manager.received.where((m) => m is! ChannelDetailsQueryMessage).toList();
      expect(asked.map((m) => m.runtimeType), [AcknowledgePaymentMessage, CloseChannelMessage]);
      expect((asked.first as AcknowledgePaymentMessage).proposedSequence, 2);
    });

    test('a close of nothing paid carries the payment of nothing, taken as closing', () async {
      await serverChannel();

      adapter.handleP2PMessage(_client, 'channel_close', {
        'channelId': _channelId,
        'payment': payment(sequence: 1, serverBalance: 0, amount: 0),
      });
      await settle();

      expect(manager.received.whereType<AcknowledgePaymentMessage>().single.closing, isTrue);
    });

    test('acknowledges a repeated payment again', () async {
      await serverChannel();

      adapter.handlePaymentAcknowledged(
          PaymentAcknowledgedResponse(channelId: _channelId, sequenceNumber: 4, repeat: true, success: true));
      await settle();

      final ack = sent('payment_ack').single;
      expect(ack.toPeerId, _client);
      expect(ack.payload['sequenceNumber'], 4);
    });

    test('a refused payment is named in the channel_error', () async {
      await serverChannel();

      adapter.handlePaymentAcknowledged(PaymentAcknowledgedResponse(
          channelId: _channelId, sequenceNumber: 2, success: false, error: 'balances do not follow'));
      await settle();

      expect(sent('channel_error').single.payload['sequenceNumber'], 2);
    });

    test('hands the settlement over again to a client that closes a closed channel', () async {
      await serverChannel();

      adapter.handleChannelCloseAnswered(ChannelClosedResponse(
        channelId: _channelId,
        success: true,
        finalized: true,
        alreadyClosed: true,
        settlementTxId: 'ab' * 32,
        settlementTxHex: 'cafe',
      ));
      await settle();

      final closed = sent('channel_closed').single;
      expect(closed.toPeerId, _client);
      expect(closed.payload['settlementTxHex'], 'cafe');
    });
  });
}

/// The channel manager, wallet and coordinator: records what it is sent,
/// and answers a payment as recorded.
class _Manager extends Actor {
  final List<dynamic> received = [];

  @override
  Future<void> onMessage(dynamic message) async {
    received.add(message);
    if (message is RecordPaymentMessage) {
      context.sender?.tell(PaymentRecordedResponse(
        channelId: message.channelId,
        amountSats: message.amountSats,
        sequenceNumber: 1,
        paymentTxHex: 'tx',
        clientSignatureHex: 'sig',
        newClientBalanceSats: BigInt.zero,
        newServerBalanceSats: BigInt.zero,
        success: true,
      ));
    }
  }
}
