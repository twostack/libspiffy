/// Ids generated back to back must not collide (A-L1, libspiffy-95n,
/// doc/audit-2026-09-14.md).
///
/// SPVActor named its temporary invoice-query actor
/// `invoice-query-<milliseconds>` and ChannelP2PAdapter derived channel ids
/// as `ch-<milliseconds>-<walletId hash>`. Two ids made within one
/// millisecond were equal: the second actor spawn threw "already exists"
/// (the invoice lookup then failed), and a second channel opened by the same
/// wallet overwrote the first one's peer routing and journal.
import 'dart:async';

import 'package:dactor/dactor.dart';
import 'package:test/test.dart';

import 'package:libspiffy/src/actors/channel_p2p_adapter.dart';
import 'package:libspiffy/src/actors/coordinator_messages.dart' as coord;
import 'package:libspiffy/src/actors/payment_channel_messages.dart';
import 'package:libspiffy/src/core/channel_events.dart' as ch;
import 'package:libspiffy/src/utils/unique_id.dart';

void main() {
  test('uniqueId: ids made synchronously back to back are distinct', () {
    final ids = [for (var i = 0; i < 50; i++) uniqueId('invoice-query')];
    expect(ids.toSet(), hasLength(ids.length));
    expect(ids.every((id) => id.startsWith('invoice-query-')), isTrue);
  });

  test('ChannelP2PAdapter: channels opened in the same millisecond get '
      'distinct ids', () async {
    final actorSystem = LocalActorSystem();
    final channelEvents = StreamController<ch.ChannelEvent>.broadcast();
    final probe = _ProbeActor();
    final channelManager = await actorSystem.spawn('channel-manager', () => probe);
    final walletManager =
        await actorSystem.spawn('wallet-manager', () => _ProbeActor());
    final adapter = ChannelP2PAdapter(
      channelManager: channelManager,
      walletManager: walletManager,
      emitEvent: (_) {},
      channelEvents: channelEvents.stream,
      walletId: 'client-wallet',
      myPeerId: 'client-peer',
    );
    addTearDown(() async {
      adapter.dispose();
      await channelEvents.close();
      await actorSystem.shutdown();
    });

    // Synchronously, so all of them fall in (at most a couple of)
    // milliseconds.
    const count = 20;
    for (var i = 0; i < count; i++) {
      adapter.handleOpenChannel(coord.OpenChannelCommand(
        walletId: 'client-wallet',
        serverPeerId: 'server-peer-$i',
        fundingAmountSats: 10000,
        lockTimeDurationSeconds: 3600,
      ));
    }

    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (probe.received.whereType<InitiateChannelMessage>().length < count) {
      if (DateTime.now().isAfter(deadline)) fail('channel manager not told');
      await Future.delayed(const Duration(milliseconds: 5));
    }
    final ids = probe.received
        .whereType<InitiateChannelMessage>()
        .map((m) => m.channelId)
        .toList();
    expect(ids.toSet(), hasLength(count),
        reason: 'channel ids collided: $ids');
  });
}

class _ProbeActor extends Actor {
  final List<dynamic> received = [];

  @override
  Future<void> onMessage(dynamic message) async {
    received.add(message);
  }
}
