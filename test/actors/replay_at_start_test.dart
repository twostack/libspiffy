/// Bead overnode_v2-7pf: events the channel projection applies again at
/// start were handled as if journaled now.
///
/// A projection catches up from its checkpoint (saved every 100 events, so
/// an app the OS stops replays up to 99), and a restore copies a backup's
/// journal in for the projections to apply. Every applied channel event went
/// to the channel adapter, which acts on each: a restore re-sent every
/// channel message of the past to its peer, and the app was told of every
/// channel again. Replay itself is untouched: the read model is still built
/// from it. What changes is that an event at or before the journal head
/// this start found is not acted on again.
library;

import 'dart:async';
import 'dart:io';

import 'package:dactor/dactor.dart';
import 'package:eventador/eventador.dart';
import 'package:isar_community/isar.dart';
import 'package:test/test.dart';

import 'package:libspiffy/libspiffy.dart';
import 'package:libspiffy/src/actors/coordinator_messages.dart' as coord;
import 'package:libspiffy/src/core/channel_events.dart';
import 'package:libspiffy/src/models/payment_channel.dart';

import '../integration/isar_test_helper.dart';

const _client = 'client-peer';
const _server = 'server-peer';

/// A client channel's history, from its request to its close.
List<ChannelEvent> _closedClientChannel(String channelId) => [
      ChannelRequestedEvent(
        channelId: channelId,
        walletId: 'w',
        clientPeerId: _client,
        serverPeerId: _server,
        clientPubKeyHex: '02${'ab' * 32}',
        clientAddressB58: 'mqCnSf8i6kmaQaJ54HjQ8EUJnuK4AnCv12',
        derivationIndex: 7,
        fundingAmountSats: BigInt.from(100000),
        lockTimeUnix: 1900000000,
        version: 1,
      ),
      ChannelOpenedEvent(
        channelId: channelId,
        fundingTxId: 'f' * 64,
        fundingOutputIndex: 0,
        fundingTxHex: '0100',
        fundingAncestorTxids: const [],
        initialClientBalanceSats: BigInt.from(100000),
        initialServerBalanceSats: BigInt.zero,
        version: 2,
      ),
      ChannelClosingEvent(
        channelId: channelId,
        reason: 'left the room',
        initiator: 'client',
        clientBalanceSats: BigInt.from(100000),
        serverBalanceSats: BigInt.zero,
        version: 3,
      ),
      ChannelClosedEvent(
        channelId: channelId,
        settlementTxId: 'ab' * 32,
        finalClientBalanceSats: BigInt.from(100000),
        finalServerBalanceSats: BigInt.zero,
        settlementTxHex: 'cafe',
        version: 4,
      ),
    ];

void main() {
  late Directory dir;
  late Isar isar;
  ActorSystem? actorSystem;
  LibSpiffyActorSystem? started;

  setUpAll(ensureIsarInitialized);

  setUp(() async {
    EventRegistry.clear();
    LibSpiffyActorSystem.registerEventTypes();
    dir = await Directory.systemTemp.createTemp('replay_at_start_');
    isar = await Isar.open(
      LibSpiffySchemas.allSchemas,
      directory: dir.path,
      name: 'replay_${DateTime.now().microsecondsSinceEpoch}',
    );
  });

  tearDown(() async {
    await started?.shutdown();
    await actorSystem?.shutdown();
    started = null;
    actorSystem = null;
    await isar.close(deleteFromDisk: true);
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  });

  /// Journals [events] under their channel, as a run before this one (or a
  /// restore) left them.
  Future<void> journal(List<ChannelEvent> events) async {
    final store = IsarEventStore(isar);
    for (final event in events) {
      await store.persistEvent('PaymentChannel_${event.channelId}', event, event.version - 1);
    }
  }

  /// Starts libspiffy on the journal, collecting what it tells the app and
  /// what its live channel stream carries.
  Future<({List<coord.CoordinatorEvent> told, List<ChannelEvent> live})> start() async {
    final system = actorSystem = LocalActorSystem(ActorSystemConfig());
    started = LibSpiffyActorSystem();
    await started!.initialize(
      actorSystem: system,
      isar: isar,
      dataDirectory: dir.path,
      storageBackend: StorageBackend.isar,
      secureStorage: InMemorySecureStorage(),
      enableP2P: false,
      channelPeerId: _client,
    );
    final told = <coord.CoordinatorEvent>[];
    final live = <ChannelEvent>[];
    final toldSub = started!.coordinatorEvents!.listen(told.add);
    final liveSub = started!.channelEvents.listen(live.add);
    addTearDown(toldSub.cancel);
    addTearDown(liveSub.cancel);
    return (told: told, live: live);
  }

  Future<void> waitFor(Future<bool> Function() done) async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (!await done()) {
      if (DateTime.now().isAfter(deadline)) fail('timed out');
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  test('a journal from before this start builds the read model, and nothing is sent or announced', () async {
    await journal(_closedClientChannel('restored'));

    final seen = await start();

    // The replay still builds the read model.
    await waitFor(() async =>
        (await started!.walletStorage.getPaymentChannel('restored'))?.state == PaymentChannelState.closed);
    // Past the adapter's resend wait, so a resumed channel would have sent.
    await Future<void>.delayed(const Duration(seconds: 3));

    expect(seen.told.whereType<coord.P2PMessageToSendEvent>(), isEmpty,
        reason: 'old code re-sent channel_request, channel_close and so on to the peer');
    expect(seen.told.whereType<coord.ChannelOpenedEvent>(), isEmpty);
    expect(seen.told.whereType<coord.ChannelClosedEvent>(), isEmpty,
        reason: 'old code told the app the channel closed again');
    expect(seen.live, isEmpty, reason: 'channelEvents carries only events journaled since the start');
  });

  test('an event journaled after the start is acted on as before', () async {
    await journal(_closedClientChannel('restored'));
    final seen = await start();
    await waitFor(() async =>
        (await started!.walletStorage.getPaymentChannel('restored'))?.state == PaymentChannelState.closed);

    // Journaled through libspiffy's own store, as a channel actor does.
    final now = _closedClientChannel('new').first;
    await started!.eventStore.persistEvent('PaymentChannel_new', now, 0);
    await waitFor(() async => seen.live.isNotEmpty);

    expect(seen.live.single.channelId, 'new');
    final sent = seen.told.whereType<coord.P2PMessageToSendEvent>().toList();
    expect(sent.map((m) => (m.messageType, m.toPeerId)), [('channel_request', _server)],
        reason: 'the adapter still acts on a live event');
  });
}
