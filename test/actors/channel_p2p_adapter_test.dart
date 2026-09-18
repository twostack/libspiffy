/// Regression tests for ChannelP2PAdapter (audit finding A-C2).
///
/// On `channel_accept` the client side must ask the *wallet* aggregate to
/// build the funding transaction. BuildFundingTransactionCommand is a wallet
/// command; it used to be told to the channel manager, whose default branch
/// dropped it, so a client-side channel open never progressed past accept.
import 'dart:async';

import 'package:dactor/dactor.dart';
import 'package:test/test.dart';

import 'package:libspiffy/src/actors/channel_p2p_adapter.dart';
import 'package:libspiffy/src/actors/coordinator_messages.dart' as coord;
import 'package:libspiffy/src/actors/payment_channel_messages.dart';
import 'package:libspiffy/src/actors/wallet_messages.dart';
import 'package:libspiffy/src/core/channel_events.dart' as ch;
import 'package:libspiffy/src/core/wallet_commands.dart';

void main() {
  late ActorSystem actorSystem;
  late _ProbeActor walletManagerProbe;
  late _ProbeActor channelManagerProbe;
  late ActorRef walletManager;
  late ActorRef channelManager;
  late ActorRef replyTo;
  late StreamController<ch.ChannelEvent> channelEvents;
  late List<coord.CoordinatorEvent> emitted;
  late ChannelP2PAdapter adapter;

  setUp(() async {
    actorSystem = LocalActorSystem();
    walletManagerProbe = _ProbeActor();
    channelManagerProbe = _ProbeActor();
    walletManager = await actorSystem.spawn('wallet-manager', () => walletManagerProbe);
    channelManager = await actorSystem.spawn('channel-manager', () => channelManagerProbe);
    replyTo = await actorSystem.spawn('coordinator', () => _ProbeActor());
    channelEvents = StreamController<ch.ChannelEvent>.broadcast();
    emitted = [];

    adapter = ChannelP2PAdapter(
      channelManager: channelManager,
      walletManager: walletManager,
      emitEvent: emitted.add,
      channelEvents: channelEvents.stream,
      walletId: 'client-wallet',
      myPeerId: 'client-peer',
    );
    adapter.updateReplyTo(replyTo);
  });

  tearDown(() async {
    adapter.dispose();
    await channelEvents.close();
    await actorSystem.shutdown();
  });

  test('channel_accept routes BuildFundingTransactionCommand to the wallet manager', () async {
    const channelId = 'chan-1';

    // We are the client: the channel aggregate emitted ChannelRequestedEvent
    // when we opened the channel, which the adapter records as client info.
    channelEvents.add(ch.ChannelRequestedEvent(
      channelId: channelId,
      walletId: 'client-wallet',
      clientPeerId: 'client-peer',
      serverPeerId: 'server-peer',
      clientPubKeyHex: '02' * 33,
      clientAddressB58: 'mqCnSf8i6kmaQaJ54HjQ8EUJnuK4AnCv12',
      derivationIndex: 7,
      fundingAmountSats: BigInt.from(50000),
      lockTimeUnix: 1700000000,
    ));
    await Future.delayed(const Duration(milliseconds: 50));

    // The server accepts.
    adapter.handleP2PMessage('server-peer', 'channel_accept', {
      'channelId': channelId,
      'serverPubKey': '03' * 33,
      'serverAddress': 'mkHS9ne12qx9pS9VojpwU5xtRd4T7X7ZUt',
      'derivationIndex': 3,
    });
    await Future.delayed(const Duration(milliseconds: 100));

    // The wallet manager must receive the command, wrapped for routing to
    // the wallet aggregate, with the coordinator as the reply target so the
    // FundingTransactionBuiltResponse comes back to it.
    final walletCommands = walletManagerProbe.received
        .map((r) => r.message)
        .whereType<WalletCommandMessage>()
        .toList();
    expect(walletCommands, hasLength(1),
        reason: 'wallet manager should receive exactly one WalletCommandMessage');
    final cmd = walletCommands.single.command;
    expect(cmd, isA<BuildFundingTransactionCommand>());
    final build = cmd as BuildFundingTransactionCommand;
    expect(walletCommands.single.walletId, equals('client-wallet'));
    expect(build.walletId, equals('client-wallet'));
    expect(build.channelId, equals(channelId));
    expect(build.clientPubKeyHex, equals('02' * 33));
    expect(build.serverPubKeyHex, equals('03' * 33));
    expect(build.fundingAmountSats, equals(50000));
    expect(build.changeAddressBase58, equals('mqCnSf8i6kmaQaJ54HjQ8EUJnuK4AnCv12'));
    expect(build.derivationIndex, equals(7));

    final sender = walletManagerProbe.received
        .firstWhere((r) => r.message is WalletCommandMessage)
        .sender;
    expect(sender, isNotNull, reason: 'reply target must be set');
    expect(sender!.id, equals(replyTo.id),
        reason: 'the response must be routed back to the coordinator');

    // The channel manager still gets the server acceptance recorded, but
    // never the wallet command (it has no handler for it).
    final channelMessages = channelManagerProbe.received.map((r) => r.message).toList();
    expect(channelMessages.whereType<BuildFundingTransactionCommand>(), isEmpty,
        reason: 'channel manager must not receive the wallet command');
    expect(channelMessages.whereType<WalletCommandMessage>(), isEmpty);
  });

  group('lhd: failed builds stop the client flow', () {
    const channelId = 'chan-2';

    /// Client side after channel_accept: client info and peers are known.
    Future<void> acceptedClientChannel() async {
      channelEvents.add(ch.ChannelRequestedEvent(
        channelId: channelId,
        walletId: 'client-wallet',
        clientPeerId: 'client-peer',
        serverPeerId: 'server-peer',
        clientPubKeyHex: '02' * 33,
        clientAddressB58: 'mqCnSf8i6kmaQaJ54HjQ8EUJnuK4AnCv12',
        derivationIndex: 7,
        fundingAmountSats: BigInt.from(50000),
        lockTimeUnix: 1700000000,
      ));
      await Future.delayed(const Duration(milliseconds: 50));
      adapter.handleP2PMessage('server-peer', 'channel_accept', {
        'channelId': channelId,
        'serverPubKey': '03' * 33,
        'serverAddress': 'mkHS9ne12qx9pS9VojpwU5xtRd4T7X7ZUt',
        'derivationIndex': 3,
      });
      await Future.delayed(const Duration(milliseconds: 50));
      channelManagerProbe.received.clear();
      emitted.clear();
    }

    FundingTransactionBuiltResponse funding({required bool success}) =>
        FundingTransactionBuiltResponse(
          walletId: 'client-wallet',
          correlationId: channelId,
          channelId: channelId,
          fundingTxHex: success ? 'ab' * 40 : '',
          fundingTxId: success ? 'f' * 64 : '',
          fundingOutputIndex: 0,
          success: success,
          error: success ? null : 'Insufficient funds',
        );

    test('a built funding transaction asks the channel manager to build the '
        'refund, with the coordinator as reply target', () async {
      await acceptedClientChannel();

      adapter.handleFundingTransactionBuilt(funding(success: true));
      await Future.delayed(const Duration(milliseconds: 100));

      final builds = channelManagerProbe.received
          .where((r) => r.message is BuildRefundTransactionMessage)
          .toList();
      expect(builds, hasLength(1));
      expect((builds.single.message as BuildRefundTransactionMessage).fundingTxId,
          equals('f' * 64));
      expect(builds.single.sender?.id, equals(replyTo.id),
          reason: 'RefundTransactionBuiltResponse must reach the coordinator, '
              'which forwards it to handleRefundTransactionBuilt');
    });

    test('a failed funding build builds no refund and reports the error',
        () async {
      await acceptedClientChannel();

      adapter.handleFundingTransactionBuilt(funding(success: false));
      await Future.delayed(const Duration(milliseconds: 100));

      expect(
          channelManagerProbe.received
              .where((r) => r.message is BuildRefundTransactionMessage),
          isEmpty);
      final errors = emitted.whereType<coord.ErrorEvent>().toList();
      expect(errors, hasLength(1));
      expect(errors.single.message, contains('Insufficient funds'));
    });

    test('a failed refund build sends the server no refund_sign_request',
        () async {
      await acceptedClientChannel();
      adapter.handleFundingTransactionBuilt(funding(success: true));
      await Future.delayed(const Duration(milliseconds: 50));
      emitted.clear();

      adapter.handleRefundTransactionBuilt(RefundTransactionBuiltResponse(
        channelId: channelId,
        refundTxHex: '',
        success: false,
        error: 'Bad state: Channel aggregate not found: $channelId',
      ));

      expect(
          emitted
              .whereType<coord.ChannelP2PMessageToSendEvent>()
              .where((e) => e.messageType == 'refund_sign_request'),
          isEmpty);
      final errors = emitted.whereType<coord.ErrorEvent>().toList();
      expect(errors, hasLength(1));
      expect(errors.single.message, contains('Channel aggregate not found'));
    });
  });

  group('kyw: a failed step tells the counterparty', () {
    const serverChannelId = 'chan-3';
    const clientChannelId = 'chan-4';

    /// Server side: the aggregate accepted a channel a client asked for, so
    /// the adapter holds the server record and the client's peer id.
    Future<void> acceptedServerChannel() async {
      channelEvents.add(ch.ChannelAcceptedEvent(
        channelId: serverChannelId,
        walletId: 'server-wallet',
        clientPeerId: 'the-client-peer',
        clientPubKeyHex: '02' * 33,
        clientAddressB58: 'mqCnSf8i6kmaQaJ54HjQ8EUJnuK4AnCv12',
        serverPubKeyHex: '03' * 33,
        serverAddressB58: 'mkHS9ne12qx9pS9VojpwU5xtRd4T7X7ZUt',
        derivationIndex: 3,
        fundingAmountSats: BigInt.from(50000),
        lockTimeUnix: 1700000000,
      ));
      await Future.delayed(const Duration(milliseconds: 50));
      channelManagerProbe.received.clear();
      emitted.clear();
    }

    /// Client side after channel_accept: the server peer is known.
    Future<void> acceptedClientChannel() async {
      channelEvents.add(ch.ChannelRequestedEvent(
        channelId: clientChannelId,
        walletId: 'client-wallet',
        clientPeerId: 'client-peer',
        serverPeerId: 'server-peer',
        clientPubKeyHex: '02' * 33,
        clientAddressB58: 'mqCnSf8i6kmaQaJ54HjQ8EUJnuK4AnCv12',
        derivationIndex: 7,
        fundingAmountSats: BigInt.from(50000),
        lockTimeUnix: 1700000000,
      ));
      await Future.delayed(const Duration(milliseconds: 50));
      adapter.handleP2PMessage('server-peer', 'channel_accept', {
        'channelId': clientChannelId,
        'serverPubKey': '03' * 33,
        'serverAddress': 'mkHS9ne12qx9pS9VojpwU5xtRd4T7X7ZUt',
        'derivationIndex': 3,
      });
      await Future.delayed(const Duration(milliseconds: 50));
      channelManagerProbe.received.clear();
      emitted.clear();
    }

    List<coord.ChannelP2PMessageToSendEvent> channelErrors() => emitted
        .whereType<coord.ChannelP2PMessageToSendEvent>()
        .where((e) => e.messageType == 'channel_error')
        .toList();

    test('the server that refuses to open a channel tells the client',
        () async {
      await acceptedServerChannel();

      adapter.handleChannelOpenedResponse(ChannelOpenedResponse(
        channelId: serverChannelId,
        success: false,
        error: 'Funding transaction f00 failed SPV validation: '
            'no merkle proof',
      ));
      await Future.delayed(const Duration(milliseconds: 100));

      final errors = channelErrors();
      expect(errors, hasLength(1),
          reason: 'the client is waiting for a channel that was refused '
              '(bead libspiffy-kyw)');
      expect(errors.single.toPeerId, 'the-client-peer');
      expect(errors.single.payload['channelId'], serverChannelId);
      expect(errors.single.payload['error'], contains('failed SPV validation'));
      // Still reported locally, as before.
      expect(emitted.whereType<coord.ErrorEvent>(), hasLength(1));
    });

    test('the client whose own open failed tells the server', () async {
      await acceptedClientChannel();

      adapter.handleChannelOpenedResponse(ChannelOpenedResponse(
        channelId: clientChannelId,
        success: false,
        error: 'Funding broadcast failed: ARC rejected the transaction',
      ));
      await Future.delayed(const Duration(milliseconds: 100));

      final errors = channelErrors();
      expect(errors, hasLength(1));
      expect(errors.single.toPeerId, 'server-peer',
          reason: 'the server accepted and waits for channel_open');
      expect(errors.single.payload['error'], contains('ARC rejected'));
    });

    test('a failed refund build tells the server too', () async {
      await acceptedClientChannel();

      adapter.handleRefundTransactionBuilt(RefundTransactionBuiltResponse(
        channelId: clientChannelId,
        refundTxHex: '',
        success: false,
        error: 'Bad state: Channel aggregate not found',
      ));
      await Future.delayed(const Duration(milliseconds: 100));

      final errors = channelErrors();
      expect(errors, hasLength(1));
      expect(errors.single.toPeerId, 'server-peer');
    });

    test('a step that fails on a channel this adapter has no record of '
        'sends nothing', () async {
      adapter.handleChannelOpenedResponse(ChannelOpenedResponse(
        channelId: 'never-heard-of',
        success: false,
        error: 'whatever',
      ));
      await Future.delayed(const Duration(milliseconds: 200));

      expect(channelErrors(), isEmpty);
    });
  });

  test('channel_accept for an unknown channel sends nothing', () async {
    adapter.handleP2PMessage('server-peer', 'channel_accept', {
      'channelId': 'never-requested',
      'serverPubKey': '03' * 33,
      'serverAddress': 'mkHS9ne12qx9pS9VojpwU5xtRd4T7X7ZUt',
      'derivationIndex': 3,
    });
    await Future.delayed(const Duration(milliseconds: 100));

    expect(walletManagerProbe.received, isEmpty);
    // The adapter looks the channel up in the journal (it may predate a
    // restart, libspiffy-fsy) and, finding none, sends nothing else.
    expect(
        channelManagerProbe.received
            .map((r) => r.message)
            .where((m) => m is! ChannelDetailsQueryMessage),
        isEmpty);
  });

  /// Bead libspiffy-z2px. The server acknowledges a payment by sending the
  /// client `payment_ack` carrying its countersignature — the second of the
  /// two signatures the 2-of-2 funding output needs. The adapter used to log
  /// that and drop it, so the client's channel went on holding the UNSIGNED
  /// payment template, whose txid is not the one the signed transaction will
  /// have. A client cooperative close therefore had nothing it could record,
  /// and the client's return leg never reached its wallet.
  test('payment_ack hands the server countersignature to the channel manager', () async {
    const channelId = 'chan-z2px';

    channelEvents.add(ch.ChannelRequestedEvent(
      channelId: channelId,
      walletId: 'client-wallet',
      clientPeerId: 'client-peer',
      serverPeerId: 'server-peer',
      clientPubKeyHex: '02' * 33,
      clientAddressB58: 'mqCnSf8i6kmaQaJ54HjQ8EUJnuK4AnCv12',
      derivationIndex: 7,
      fundingAmountSats: BigInt.from(50000),
      lockTimeUnix: 1700000000,
    ));
    await Future.delayed(const Duration(milliseconds: 50));
    channelManagerProbe.received.clear();

    adapter.handleP2PMessage('server-peer', 'payment_ack', {
      'channelId': channelId,
      'sequenceNumber': 3,
      'serverSignatureHex': '30' * 36,
    });
    await Future.delayed(const Duration(milliseconds: 100));

    final toManager = channelManagerProbe.received
        .map((r) => r.message)
        .where((m) => m is! ChannelDetailsQueryMessage)
        .toList();
    expect(toManager, isNotEmpty,
        reason: 'the countersignature is the only copy the client will ever '
            'get; dropping it leaves the client holding an unsigned template');
    final record = toManager.single as RecordPaymentCountersignatureMessage;
    expect(record.channelId, channelId);
    expect(record.sequenceNumber, 3);
    expect(record.serverSignatureHex, '30' * 36);
  });

  /// A `payment_ack` with no signature in it is not an acknowledgement we can
  /// act on. Sending the manager an empty one would have it try to assemble a
  /// settlement out of half a signature.
  test('payment_ack without a signature is not passed on as one', () async {
    const channelId = 'chan-z2px-empty';

    channelEvents.add(ch.ChannelRequestedEvent(
      channelId: channelId,
      walletId: 'client-wallet',
      clientPeerId: 'client-peer',
      serverPeerId: 'server-peer',
      clientPubKeyHex: '02' * 33,
      clientAddressB58: 'mqCnSf8i6kmaQaJ54HjQ8EUJnuK4AnCv12',
      derivationIndex: 7,
      fundingAmountSats: BigInt.from(50000),
      lockTimeUnix: 1700000000,
    ));
    await Future.delayed(const Duration(milliseconds: 50));
    channelManagerProbe.received.clear();

    adapter.handleP2PMessage('server-peer', 'payment_ack', {
      'channelId': channelId,
      'sequenceNumber': 3,
    });
    await Future.delayed(const Duration(milliseconds: 100));

    expect(
        channelManagerProbe.received
            .map((r) => r.message)
            .whereType<RecordPaymentCountersignatureMessage>(),
        isEmpty);
  });

}

class _Received {
  final dynamic message;
  final ActorRef? sender;
  _Received(this.message, this.sender);
}

/// Records every message delivered to it together with its sender.
class _ProbeActor extends Actor {
  final List<_Received> received = [];

  @override
  Future<void> onMessage(dynamic message) async {
    received.add(_Received(message, context.sender));
  }
}
