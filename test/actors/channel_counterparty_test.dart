/// Bead libspiffy-i0e6: a channel message is acted on only when it comes
/// from the channel's counterparty, in the role that sends it.
///
/// ChannelP2PAdapter took a message's channel id as its authority. Channel
/// ids travel between the parties and through whatever relays their
/// messages, so knowing one proves nothing, and a third peer could end the
/// client's channel (`channel_closed`, `channel_reject`), close ours
/// (`channel_close`), accept a request in the server's place — the client
/// would fund a 2-of-2 with the intruder's key and send it the refund to
/// sign — or replace a pending request with its own keys before the app
/// accepted it.
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

const _channelId = 'chan-i0e6';
const _client = 'client-peer';
const _server = 'server-peer';
const _intruder = 'intruder-peer';

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

  /// Lets the adapter handle what it was just given (it answers in order).
  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 50));

  List<T> told<T>() => manager.received.whereType<T>().toList();

  Map<String, dynamic> request({String pubKey = '02aa'}) => {
        'channelId': _channelId,
        'clientPubKey': pubKey,
        'clientAddress': 'mqCnSf8i6kmaQaJ54HjQ8EUJnuK4AnCv12',
        'fundingAmountSats': 100000,
        'lockTimeUnix': 1900000000,
      };

  Map<String, dynamic> paymentUpdate() => {
        'channelId': _channelId,
        'amountSats': 1000,
        'paymentTxHex': '00',
        'clientSignatureHex': '30',
        'proposedSequence': 1,
        'proposedClientBalance': 99000,
        'proposedServerBalance': 1000,
      };

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

    test('does not let a third peer end its channel', () async {
      adapter.handleP2PMessage(_intruder, 'channel_closed', {'channelId': _channelId, 'settlementTxId': 'ab' * 32});
      adapter.handleP2PMessage(_intruder, 'channel_reject', {'channelId': _channelId, 'reason': 'gone'});
      await settle();

      // Old code: a ChannelClosedEvent and a rejection ErrorEvent for a
      // channel its server never ended.
      expect(emitted.whereType<coord.ChannelClosedEvent>(), isEmpty);
      expect(emitted.whereType<coord.ErrorEvent>(), isEmpty);
    });

    test('does not let a third peer accept its request in the server\'s place', () async {
      adapter.handleP2PMessage(_intruder, 'channel_accept',
          {'channelId': _channelId, 'serverPubKey': '03' * 33, 'serverAddress': 'x', 'derivationIndex': 0});
      await settle();

      expect(told<RecordServerAcceptanceMessage>(), isEmpty);
    });

    test('does not let a third peer close its channel or answer its refund', () async {
      adapter.handleP2PMessage(_intruder, 'channel_close', {'channelId': _channelId});
      adapter.handleP2PMessage(_intruder, 'refund_signed', {'channelId': _channelId, 'serverSignatureHex': '30'});
      await settle();

      expect(told<CloseChannelMessage>(), isEmpty);
      expect(told<RecordRefundSignatureMessage>(), isEmpty);
    });

    test('does not take from its own server what only a client sends', () async {
      adapter.handleP2PMessage(_server, 'payment_update', paymentUpdate());
      await settle();

      expect(told<AcknowledgePaymentMessage>(), isEmpty);
    });

    test('acts on its server', () async {
      adapter.handleP2PMessage(_server, 'channel_accept',
          {'channelId': _channelId, 'serverPubKey': '03' * 33, 'serverAddress': 'x', 'derivationIndex': 0});
      adapter.handleP2PMessage(_server, 'channel_close', {'channelId': _channelId});
      await settle();

      expect(told<RecordServerAcceptanceMessage>(), hasLength(1));
      expect(told<CloseChannelMessage>(), hasLength(1));
    });
  });

  group('the server', () {
    setUp(() => spawn(_server));

    test('keeps the request it was asked to accept when a third peer re-sends its id', () async {
      adapter.handleP2PMessage(_client, 'channel_request', request(pubKey: '02aa'));
      adapter.handleP2PMessage(_intruder, 'channel_request', request(pubKey: '02bb'));
      await settle();
      adapter.handleAcceptRequest(coord.AcceptChannelCommand(
        channelId: _channelId,
        walletId: 'w',
        clientPeerId: _client,
        clientPubKey: '02aa',
        clientAddress: 'mqCnSf8i6kmaQaJ54HjQ8EUJnuK4AnCv12',
        fundingAmountSats: 100000,
        lockTimeUnix: 1900000000,
      ));
      await settle();

      expect(emitted.whereType<coord.ChannelRequestReceivedEvent>(), hasLength(1));
      final accepted = told<AcceptChannelMessage>().single;
      // Old code: the intruder's peer and key.
      expect(accepted.clientPeerId, _client);
      expect(accepted.clientPubKeyHex, '02aa');
    });

    group('with an accepted channel', () {
      setUp(() async {
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
      });

      test('does not let a third peer pay into, open or close the channel', () async {
        adapter.handleP2PMessage(_intruder, 'payment_update', paymentUpdate());
        adapter.handleP2PMessage(_intruder, 'channel_open',
            {'channelId': _channelId, 'fundingTxId': 'ab' * 32, 'fundingOutputIndex': 0, 'fundingTxHex': '00'});
        adapter.handleP2PMessage(_intruder, 'channel_close', {'channelId': _channelId});
        await settle();

        expect(told<AcknowledgePaymentMessage>(), isEmpty);
        expect(told<OpenChannelMessage>(), isEmpty);
        expect(told<CloseChannelMessage>(), isEmpty);
      });

      test('acts on its client', () async {
        adapter.handleP2PMessage(_client, 'payment_update', paymentUpdate());
        await settle();

        expect(told<AcknowledgePaymentMessage>(), hasLength(1));
      });
    });
  });
}

class _Probe extends Actor {
  final List<dynamic> received = [];
  @override
  Future<void> onMessage(dynamic message) async => received.add(message);
}
