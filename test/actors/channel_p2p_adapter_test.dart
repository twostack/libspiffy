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

  test('channel_accept for an unknown channel sends nothing', () async {
    adapter.handleP2PMessage('server-peer', 'channel_accept', {
      'channelId': 'never-requested',
      'serverPubKey': '03' * 33,
      'serverAddress': 'mkHS9ne12qx9pS9VojpwU5xtRd4T7X7ZUt',
      'derivationIndex': 3,
    });
    await Future.delayed(const Duration(milliseconds: 100));

    expect(walletManagerProbe.received, isEmpty);
    expect(channelManagerProbe.received, isEmpty);
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
