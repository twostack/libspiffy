/// Bead libspiffy-u6q6: the server closes a channel with the settlement it
/// broadcast and hands it to the client, which records its return leg from
/// it.
///
/// `channel_closed` carried only a txid. The client's adapter dropped the
/// channel's records and told the host it had closed, journaling nothing:
/// the client's channel stayed open, its share never reached the wallet, and
/// the settlement it was told of was one nobody had broadcast.
library;

import 'dart:async';

import 'package:dactor/dactor.dart';
import 'package:test/test.dart';

import 'package:libspiffy/src/actors/channel_p2p_adapter.dart';
import 'package:libspiffy/src/actors/coordinator_messages.dart' as coord;
import 'package:libspiffy/src/actors/payment_channel_messages.dart';
import 'package:libspiffy/src/core/channel_events.dart';
import 'package:libspiffy/src/models/fee_rate.dart';

import '../mocks/policy_rate_arc.dart';

const _channelId = 'chan-u6q6';
const _client = 'client-peer';
const _server = 'server-peer';

void main() {
  late ActorSystem system;
  late _Probe manager;
  late List<coord.CoordinatorEvent> emitted;
  late StreamController<ChannelEvent> events;
  late ChannelP2PAdapter adapter;

  Future<void> spawn(String myPeerId) async {
    adapter = ChannelP2PAdapter(
      channelManager: await system.spawn('manager', () => manager),
      walletManager: await system.spawn('wallet', () => _Probe()),
      arcActor: await system.spawn('arc', () => PolicyRateArc(const FeeRate(satoshis: 100, bytes: 1000))),
      emitEvent: emitted.add,
      channelEvents: events.stream,
      walletId: 'w',
      myPeerId: myPeerId,
    );
    adapter.updateReplyTo(await system.spawn('coordinator', () => _Probe()));
  }

  setUp(() {
    system = LocalActorSystem();
    manager = _Probe();
    emitted = [];
    events = StreamController<ChannelEvent>.broadcast();
  });
  tearDown(() async {
    adapter.dispose();
    await events.close();
    await system.shutdown();
  });

  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 50));

  List<coord.ChannelP2PMessageToSendEvent> sent(String type) =>
      emitted.whereType<coord.ChannelP2PMessageToSendEvent>().where((m) => m.messageType == type).toList();

  ChannelClosedEvent closed() => ChannelClosedEvent(
        channelId: _channelId,
        settlementTxId: 'ab' * 32,
        finalClientBalanceSats: BigInt.from(70000),
        finalServerBalanceSats: BigInt.from(30000),
        settlementTxHex: 'cafe',
      );

  test('the server hands the client the settlement it closed with', () async {
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

    events.add(closed());
    await settle();

    final message = sent('channel_closed').single;
    expect(message.toPeerId, _client);
    // Old code: the txid alone.
    expect(message.payload['settlementTxHex'], 'cafe');
    expect(message.payload['settlementTxId'], 'ab' * 32);
  });

  // Bead libspiffy-pkg5: with the server's half of each payment's
  // signature, the client held a spend of every state and could broadcast
  // the one paying the server least.
  test('the server acknowledges a payment without its signature', () async {
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
    adapter.handleAcceptRequest(coord.AcceptChannelCommand(
      channelId: _channelId,
      walletId: 'w',
      clientPeerId: _client,
      clientPubKey: '02' * 33,
      clientAddress: 'mqCnSf8i6kmaQaJ54HjQ8EUJnuK4AnCv12',
      fundingAmountSats: 100000,
      lockTimeUnix: 1900000000,
    ));
    await settle();

    events.add(PaymentAcknowledgedEvent(
      channelId: _channelId,
      amountSats: BigInt.from(1000),
      sequenceNumber: 1,
      newClientBalanceSats: BigInt.from(99000),
      newServerBalanceSats: BigInt.from(1000),
      fullySignedPaymentTxHex: 'cafe',
      serverSignatureHex: '30' * 36,
    ));
    await settle();

    final ack = sent('payment_ack').single;
    expect(ack.toPeerId, _client);
    expect(ack.payload['sequenceNumber'], 1);
    // Old code: the server's signature.
    expect(ack.payload.containsKey('serverSignatureHex'), isFalse);
    expect(ack.payload.values, isNot(contains('cafe')));
  });

  group('the client', () {
    setUp(() async {
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
      emitted.clear();
    });

    test('records the settlement it is handed, and closes only when that is journaled', () async {
      adapter.handleP2PMessage(_server, 'channel_closed',
          {'channelId': _channelId, 'settlementTxId': 'ab' * 32, 'settlementTxHex': 'cafe'});
      await settle();

      final record = manager.received.whereType<RecordSettlementMessage>().single;
      expect(record.settlementTxHex, 'cafe');
      // Old code: a ChannelClosedEvent to the host, and nothing journaled.
      expect(emitted.whereType<coord.ChannelClosedEvent>(), isEmpty);

      events.add(closed());
      await settle();

      expect(emitted.whereType<coord.ChannelClosedEvent>(), hasLength(1));
      expect(sent('channel_closed'), isEmpty, reason: 'the client has nothing to hand back');
    });

    test('a channel_closed with no settlement closes nothing', () async {
      adapter.handleP2PMessage(_server, 'channel_closed', {'channelId': _channelId, 'settlementTxId': 'ab' * 32});
      await settle();

      expect(manager.received.whereType<RecordSettlementMessage>(), isEmpty);
      expect(emitted.whereType<coord.ChannelClosedEvent>(), isEmpty);
    });
  });

  test('a close that failed is reported to the host', () async {
    await spawn(_client);

    adapter.handleChannelCloseAnswered(
        ChannelClosedResponse(channelId: _channelId, success: false, error: 'Settlement broadcast failed: x'));

    // Old code: the close was told with no reply target, and a failure went
    // nowhere but the log.
    expect(emitted.whereType<coord.ErrorEvent>().single.message, contains('Settlement broadcast failed'));
  });

  test('a close is asked with a reply target, so its answer reaches the adapter', () async {
    await spawn(_client);

    adapter.handleCloseChannel(coord.CloseChannelCommand(channelId: _channelId));
    await settle();

    expect(manager.senders.whereType<ActorRef>(), hasLength(1));
  });
}

class _Probe extends Actor {
  final List<dynamic> received = [];
  final List<ActorRef?> senders = [];
  @override
  Future<void> onMessage(dynamic message) async {
    received.add(message);
    senders.add(context.sender);
  }
}
