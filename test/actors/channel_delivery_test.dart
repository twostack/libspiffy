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
  late StreamController<ChannelEvent> replayed;
  late ChannelP2PAdapter adapter;

  Future<void> spawn(String myPeerId) async {
    adapter = ChannelP2PAdapter(
      channelManager: await system.spawn('manager', () => manager),
      walletManager: await system.spawn('wallet', () => _Manager()),
      arcActor: await system.spawn('arc', () => PolicyRateArc(const FeeRate(satoshis: 100, bytes: 1000))),
      emitEvent: emitted.add,
      channelEvents: events.stream,
      replayedChannelEvents: replayed.stream,
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
    replayed = StreamController<ChannelEvent>.broadcast();
  });
  tearDown(() async {
    adapter.dispose();
    await events.close();
    await replayed.close();
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

  /// The app asks for a channel as request [requestId]; the channel's id,
  /// which the adapter makes.
  Future<String> requestOpen(String requestId, {int? lockTimeUnix}) async {
    await spawn(_client);
    adapter.handleOpenChannel(coord.OpenChannelCommand(
        walletId: 'w', serverPeerId: _server, fundingAmountSats: 100000,
        lockTimeDurationSeconds: 3600, requestId: requestId));
    await settle();
    final id = manager.received.whereType<InitiateChannelMessage>().single.channelId;
    events.add(ChannelRequestedEvent(
      channelId: id,
      walletId: 'w',
      clientPeerId: _client,
      serverPeerId: _server,
      clientPubKeyHex: '02' * 33,
      clientAddressB58: 'mqCnSf8i6kmaQaJ54HjQ8EUJnuK4AnCv12',
      derivationIndex: 7,
      fundingAmountSats: BigInt.from(100000),
      lockTimeUnix: lockTimeUnix ?? 1900000000,
    ));
    await settle();
    return id;
  }

  void fundingSent(String id) => events.add(FundingSentEvent(
      channelId: id, fundingTxId: 'f' * 64, fundingOutputIndex: 1, fundingTxHex: '0100', fundingBeefHex: 'beef'));

  /// The client's channel opens: the manager journaled it on the server's
  /// word, and answers.
  Future<void> openedHere(String id) async {
    events.add(ChannelOpenedEvent(
      channelId: id,
      fundingTxId: 'f' * 64,
      fundingOutputIndex: 1,
      fundingTxHex: '0100',
      fundingAncestorTxids: const [],
      initialClientBalanceSats: BigInt.from(100000),
      initialServerBalanceSats: BigInt.zero,
    ));
    adapter.handleServerOpenRecorded(ServerOpenRecordedResponse(channelId: id, success: true));
    await settle();
  }

  group('bead libspiffy-jark: opening', () {
    test('channel_open is resent until the server answers channel_opened, and the channel opens only then', () async {
      final id = await requestOpen('open-1');
      fundingSent(id);
      await settle();

      final first = sent('channel_open').single.payload;
      expect(first['fundingTxId'], 'f' * 64);
      expect(first['fundingOutputIndex'], 1);
      expect(first['fundingBeef'], 'beef');
      await settle(450);
      expect(sent('channel_open').length, greaterThanOrEqualTo(3), reason: 'resent while the server is silent');
      // Old code: open as soon as ARC took the funding.
      expect(emittedOf<coord.ChannelOpenedEvent>(), isEmpty);

      adapter.handleP2PMessage(_server, 'channel_opened', {'channelId': id, 'fundingTxId': 'f' * 64, 'fundingOutputIndex': 1});
      await settle();
      final told = manager.received.whereType<RecordServerOpenedMessage>().single;
      expect((told.channelId, told.fundingTxId, told.fundingOutputIndex), (id, 'f' * 64, 1));

      await openedHere(id);
      expect(emittedOf<coord.ChannelOpenedEvent>().single.requestId, 'open-1');
      final sends = sent('channel_open').length;
      await settle(400);
      expect(sent('channel_open'), hasLength(sends), reason: 'an answered channel_open is not resent');
    });

    test('a refused open answers the app with the reason, and channel_open is still resent', () async {
      final id = await requestOpen('open-1');
      fundingSent(id);
      await settle();

      adapter.handleP2PMessage(_server, 'channel_error', {
        'channelId': id,
        'error': 'ARC does not report the network holding the funding transaction yet (status SENT_TO_NETWORK)',
      });
      await settle();
      final refused = emittedOf<coord.ErrorEvent>().single;
      expect(refused.requestId, 'open-1');
      expect(refused.message, contains('SENT_TO_NETWORK'));
      expect(refused.stillSent, isTrue, reason: 'channel_open goes again');
      expect(emittedOf<coord.ChannelOpenedEvent>(), isEmpty);

      final sends = sent('channel_open').length;
      await settle(450);
      expect(sent('channel_open').length, greaterThan(sends), reason: 'the server looks at the network again each time');

      // The network catches up: the server opens on a later channel_open.
      adapter.handleP2PMessage(_server, 'channel_opened', {'channelId': id, 'fundingTxId': 'f' * 64, 'fundingOutputIndex': 1});
      await openedHere(id);
      final opened = emittedOf<coord.ChannelOpenedEvent>().single;
      expect(opened.channelId, id);
      expect(opened.requestId, isNull, reason: 'the request was answered by the refusal');
    });

    test('channel_open is sent no more once the settlement margin begins', () async {
      final soon = DateTime.now().add(const Duration(minutes: 5)).millisecondsSinceEpoch ~/ 1000;
      final id = await requestOpen('open-1', lockTimeUnix: soon);
      fundingSent(id);
      await settle(450);

      expect(sent('channel_open'), hasLength(1));
      expect(emittedOf<coord.ErrorEvent>().single.message, contains('settlement margin has begun'));
    });

    // libspiffy-4kfq: a funding spending a coin already spent elsewhere sat
    // at SENT_TO_NETWORK, and its channel_open went every resendAtMost for a
    // day; the server spent each one asking ARC, and other channels waited.
    test('a funding that can never be mined stops channel_open and fails the open for good', () async {
      final id = await requestOpen('open-1');
      fundingSent(id);
      await settle(150);
      expect(sent('channel_open'), isNotEmpty);

      events.add(FundingFailedEvent(channelId: id, fundingTxId: 'f' * 64, reason: 'INPUT_SPENT'));
      await settle();
      final failed = emittedOf<coord.ErrorEvent>().single;
      expect(failed.requestId, 'open-1');
      expect(failed.stillSent, isFalse);
      expect(failed.message, contains('can never be mined'));

      final sends = sent('channel_open').length;
      await settle(450);
      expect(sent('channel_open'), hasLength(sends), reason: 'nothing more is sent for a funding that never opens');
    });

    test('a channel_opened from anyone but the server is refused', () async {
      final id = await requestOpen('open-1');
      fundingSent(id);
      await settle();

      adapter.handleP2PMessage('someone-else', 'channel_opened', {'channelId': id, 'fundingTxId': 'f' * 64, 'fundingOutputIndex': 1});
      await settle();

      expect(manager.received.whereType<RecordServerOpenedMessage>(), isEmpty);
    });

    group('on the server', () {
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

      test('every channel_open it opens on is answered channel_opened, a repeat too', () async {
        await serverChannel();

        for (var i = 0; i < 2; i++) {
          adapter.handleChannelOpenedResponse(
              ChannelOpenedResponse(channelId: _channelId, success: true, fundingTxId: 'f' * 64, fundingOutputIndex: 1));
        }
        await settle();

        final answers = sent('channel_opened');
        expect(answers, hasLength(2));
        expect(answers.first.toPeerId, _client);
        expect(answers.first.payload, {'channelId': _channelId, 'fundingTxId': 'f' * 64, 'fundingOutputIndex': 1});
      });

      test('a refused channel_open is answered channel_error, not channel_opened', () async {
        await serverChannel();

        adapter.handleChannelOpenedResponse(ChannelOpenedResponse(
            channelId: _channelId, success: false, error: 'ARC does not report the network holding it yet'));
        await settle();

        expect(sent('channel_opened'), isEmpty);
        expect(sent('channel_error').single.payload['error'], contains('does not report the network'));
      });
    });
  });

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
      expect(failed.stillSent, isTrue);
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
      expect(refused.stillSent, isFalse, reason: 'a refused payment is final');
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

    // Bead overnode_v2-7pf: a server that refused the payment the close
    // carries answered every resend with channel_error, and each answer
    // started the wait again: the close went every resendAfter, forever.
    test('the payment it carries refused, it is resent waiting longer each time', () async {
      await clientChannel();
      await pay('r1', 1000, 1, 1000);
      closing();
      await settle();

      // The server answers each close at once, refusing its payment.
      var answered = 0;
      final until = DateTime.now().add(const Duration(milliseconds: 1000));
      while (DateTime.now().isBefore(until)) {
        final closes = sent('channel_close').length;
        while (answered < closes) {
          answered++;
          adapter.handleP2PMessage(_server, 'channel_error',
              {'channelId': _channelId, 'error': 'Channel not open: closing', 'sequenceNumber': 1});
        }
        await settle(10);
      }

      // At 0, 100, 300, 500, 700 and 900 ms; restarting the wait on each
      // refusal sent it every 100 ms.
      expect(sent('channel_close').length, inInclusiveRange(5, 7));
    });

    // Bead overnode_v2-7pf: a server that cannot be reached failed every
    // send at once, and each failure brought the next resend forward: the
    // close went every resendAfter for as long as it stayed away, and it
    // may never come back.
    group('to a server that cannot be reached', () {
      /// Fails every channel_close as the app's transport does when it
      /// finds no address for the server, for [ms].
      Future<void> unreachableFor(int ms) async {
        var failed = 0;
        final until = DateTime.now().add(Duration(milliseconds: ms));
        while (DateTime.now().isBefore(until)) {
          final closes = sent('channel_close');
          while (failed < closes.length) {
            adapter.handleSendFailed(coord.P2PSendFailed(
                toPeerId: _server,
                messageType: 'channel_close',
                payload: closes[failed].payload,
                error: 'No addresses found for peer'));
            failed++;
          }
          await settle(10);
        }
      }

      test('backs off, then stops resending and tells the app the server is away', () async {
        await clientChannel();
        await pay('r1', 1000, 1, 1000);
        closing();
        await settle(10);

        await unreachableFor(1200);

        // At 0, at 100 ms, at 200 ms (the one failure brought forward);
        // then at the longest wait, the last send failed, it waits for the
        // server instead. Bringing every resend forward sent it every
        // 100 ms, about a dozen times.
        expect(sent('channel_close').length, 3);
        final away = emittedOf<coord.ChannelPeerAwayEvent>().single;
        expect((away.channelId, away.peerId, away.walletId), (_channelId, _server, 'w'));
      });

      test('the server back, the close goes at once and stops on channel_closed', () async {
        await clientChannel();
        await pay('r1', 1000, 1, 1000);
        closing();
        await settle(10);
        await unreachableFor(600);
        final before = sent('channel_close').length;

        adapter.handlePeerReachable(_server);
        await settle(10);
        expect(sent('channel_close').length, before + 1);
        expect((sent('channel_close').last.payload['payment'] as Map)['proposedSequence'], 1,
            reason: 'the close kept its payment while it waited');

        adapter.handleP2PMessage(_server, 'channel_closed',
            {'channelId': _channelId, 'settlementTxId': 'ab' * 32, 'settlementTxHex': 'cafe'});
        await settle();
        final closes = sent('channel_close').length;
        await settle(400);
        expect(sent('channel_close'), hasLength(closes));
      });

      test('a message from the server resumes the close too', () async {
        await clientChannel();
        await pay('r1', 1000, 1, 1000);
        closing();
        await settle(10);
        await unreachableFor(600);
        final before = sent('channel_close').length;

        adapter.handleP2PMessage(_server, 'channel_error',
            {'channelId': _channelId, 'error': 'Channel not open: closing', 'sequenceNumber': 1});
        await settle(10);

        expect(sent('channel_close').length, greaterThan(before));
      });

      test('another peer back resumes nothing', () async {
        await clientChannel();
        await pay('r1', 1000, 1, 1000);
        closing();
        await settle(10);
        await unreachableFor(600);
        final before = sent('channel_close').length;

        adapter.handlePeerReachable('someone-else');
        await settle(300);

        expect(sent('channel_close'), hasLength(before));
      });
    });

    test('ended past its lock time, nothing more is sent', () async {
      await clientChannel();
      await pay('r1', 1000, 1, 1000);
      closing();
      await settle();

      events.add(ChannelExpiredEvent(channelId: _channelId, observedBy: 'client'));
      await settle();
      final closes = sent('channel_close').length;
      await settle(500);

      expect(sent('channel_close'), hasLength(closes),
          reason: 'only a close or a reject stopped the resends: an expired channel '
              'sent its close for ever, after the refund too');
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
      expect(failed.stillSent, isFalse);
    });
  });

  // Bead overnode_v2-7pf: the channel projection applies events again at
  // start (catching up from its checkpoint, or the events a restore copied
  // in). Handled as live, a restore re-sent every channel message of the
  // past to its peer and told the app of every channel again.
  group('replayed at start', () {
    FullChannelStateResponse state(String status, {required String role, bool fundingSent = false}) =>
        FullChannelStateResponse(
          channelId: _channelId,
          walletId: 'w',
          status: status,
          role: role,
          clientBalanceSats: BigInt.from(100000),
          serverBalanceSats: BigInt.zero,
          latestSequenceNumber: 1,
          fundingAmountSats: BigInt.from(100000),
          fundingTxId: 'f' * 64,
          fundingOutputIndex: 1,
          clientPubKeyHex: '02' * 33,
          clientAddressB58: 'mqCnSf8i6kmaQaJ54HjQ8EUJnuK4AnCv12',
          lockTimeUnix: 1900000000,
          fundingSent: fundingSent,
          clientPeerId: _client,
          serverPeerId: _server,
          latestPaymentTxHex: 'tx1',
          latestClientSignatureHex: 'sig1',
          success: true,
        );

    List<ChannelEvent> clientHistory({bool closed = true}) => [
          ChannelRequestedEvent(
            channelId: _channelId,
            walletId: 'w',
            clientPeerId: _client,
            serverPeerId: _server,
            clientPubKeyHex: '02' * 33,
            clientAddressB58: 'mqCnSf8i6kmaQaJ54HjQ8EUJnuK4AnCv12',
            derivationIndex: 7,
            fundingAmountSats: BigInt.from(100000),
            lockTimeUnix: 1900000000,
          ),
          FundingSentEvent(
              channelId: _channelId, fundingTxId: 'f' * 64, fundingOutputIndex: 1, fundingTxHex: '0100'),
          ChannelOpenedEvent(
            channelId: _channelId,
            fundingTxId: 'f' * 64,
            fundingOutputIndex: 1,
            fundingTxHex: '0100',
            fundingAncestorTxids: const [],
            initialClientBalanceSats: BigInt.from(100000),
            initialServerBalanceSats: BigInt.zero,
          ),
          PaymentRecordedEvent(
            channelId: _channelId,
            amountSats: BigInt.from(1000),
            newClientBalanceSats: BigInt.from(99000),
            newServerBalanceSats: BigInt.from(1000),
            sequenceNumber: 1,
            paymentTxHex: 'tx1',
            paymentTxId: 'id1',
            clientSignatureHex: 'sig1',
          ),
          ChannelClosingEvent(
            channelId: _channelId,
            reason: 'left the room',
            initiator: 'client',
            clientBalanceSats: BigInt.from(99000),
            serverBalanceSats: BigInt.from(1000),
          ),
          if (closed)
            ChannelClosedEvent(
              channelId: _channelId,
              settlementTxId: 'ab' * 32,
              finalClientBalanceSats: BigInt.from(99000),
              finalServerBalanceSats: BigInt.from(1000),
              settlementTxHex: 'cafe',
            ),
        ];

    test('a closed channel replayed sends nothing, tells the app nothing, and is not looked at', () async {
      await spawn(_client);
      clientHistory().forEach(replayed.add);
      await settle(300);

      expect(emitted, isEmpty, reason: 'every one of these was sent and announced when it was journaled');
      expect(manager.received.whereType<ChannelDetailsQueryMessage>(), isEmpty,
          reason: 'the replay showed the channel end');
    });

    test("a server's channel replayed sends nothing to its client", () async {
      await spawn(_server);
      for (final event in <ChannelEvent>[
        ChannelAcceptedEvent(
          channelId: _channelId,
          walletId: 'w',
          clientPeerId: _client,
          clientPubKeyHex: '02' * 33,
          clientAddressB58: 'mqCnSf8i6kmaQaJ54HjQ8EUJnuK4AnCv12',
          serverPubKeyHex: '03' * 33,
          serverAddressB58: 'mqCnSf8i6kmaQaJ54HjQ8EUJnuK4AnCv12',
          derivationIndex: 3,
          fundingAmountSats: BigInt.from(100000),
          lockTimeUnix: 1900000000,
        ),
        RefundCountersignedEvent(
            channelId: _channelId, serverSignatureHex: 'ss', signedRefundTxHex: 'rr'),
        ChannelClosingEvent(
          channelId: _channelId,
          reason: 'the space ended',
          initiator: 'server',
          clientBalanceSats: BigInt.from(100000),
          serverBalanceSats: BigInt.zero,
        ),
        ChannelClosedEvent(
          channelId: _channelId,
          settlementTxId: 'ab' * 32,
          finalClientBalanceSats: BigInt.from(100000),
          finalServerBalanceSats: BigInt.zero,
          settlementTxHex: 'cafe',
        ),
      ]) {
        replayed.add(event);
      }
      await settle(300);

      expect(emitted, isEmpty,
          reason: 'old code sent channel_accept, refund_signed, channel_close and channel_closed again');
    });

    test('a client channel left closing has its close go again, with its latest payment', () async {
      await spawn(_client);
      manager.states[_channelId] = state('closing', role: 'client');
      clientHistory(closed: false).forEach(replayed.add);
      await settle(20);
      expect(emitted, isEmpty, reason: 'nothing is sent for the events themselves');

      await settle(300);

      final close = sent('channel_close').first;
      expect(close.toPeerId, _server);
      expect((close.payload['payment'] as Map)['clientSignatureHex'], 'sig1');
      expect(sent('channel_close').length, greaterThan(1), reason: 'and is resent until channel_closed');
      expect(sent('payment_update'), isEmpty);
      expect(emitted.whereType<coord.P2PMessageToSendEvent>().length, emitted.length,
          reason: 'the app is told nothing');
    });

    test('a channel the coordinator hands over is looked at once', () async {
      await spawn(_client);
      manager.states[_channelId] = state('closing', role: 'client');

      adapter.resumeAfterRestart(_channelId);
      adapter.resumeAfterRestart(_channelId);
      await settle(50);

      expect(manager.received.whereType<ChannelDetailsQueryMessage>(), hasLength(1));
      expect(sent('channel_close'), hasLength(1));
    });

    test('a funding sent and not yet opened has channel_open go again from the journal', () async {
      await spawn(_client);
      manager.states[_channelId] = state('refundSigned', role: 'client', fundingSent: true);

      adapter.resumeAfterRestart(_channelId);
      await settle();

      expect(manager.received.whereType<ResendChannelOpenMessage>().single.channelId, _channelId);
    });

    test('an open client channel has nothing to send', () async {
      await spawn(_client);
      manager.states[_channelId] = state('open', role: 'client');

      adapter.resumeAfterRestart(_channelId);
      await settle();

      expect(emitted, isEmpty);
      expect(manager.received.whereType<ResendChannelOpenMessage>(), isEmpty);
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

  /// The journaled state each channel is answered with.
  final Map<String, FullChannelStateResponse> states = {};

  @override
  Future<void> onMessage(dynamic message) async {
    received.add(message);
    if (message is ChannelDetailsQueryMessage) {
      context.sender?.tell(states[message.channelId] ??
          FullChannelStateResponse(
            channelId: message.channelId,
            walletId: 'w',
            status: 'unknown',
            clientBalanceSats: BigInt.zero,
            serverBalanceSats: BigInt.zero,
            latestSequenceNumber: 0,
            fundingAmountSats: BigInt.zero,
            success: false,
          ));
    }
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
