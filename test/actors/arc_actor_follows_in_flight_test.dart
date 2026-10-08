/// A submission ARC answers in flight is answered with the status ARC gets
/// to, followed outside ARCActor's mailbox ([SubmissionWatcherActor]).
///
/// Arcade, the Teranode-era ARC, answers every submission RECEIVED at once
/// and takes it to the network afterwards: ACCEPTED_BY_NETWORK, then
/// SEEN_ON_NETWORK once a miner has it in a subtree. ARC itself waited for
/// the network before answering. ARCActor answered its caller with the
/// first answer, so a payment received over Arcade stayed "broadcasting"
/// and its invoice unpaid until a status scan came round; the callers that
/// followed in-flight answers themselves (a deferred payment's broadcast, a
/// channel's funding and settlement) each slept in their own mailbox to do
/// it (beads libspiffy-m715, libspiffy-ggsg).
library;

import 'dart:async';

import 'package:dactor/dactor.dart';
import 'package:libspiffy/src/actors/arc_actor.dart';
import 'package:libspiffy/src/actors/wallet_messages.dart';
import 'package:libspiffy/src/core/wallet_commands.dart';
import 'package:libspiffy/src/models/bitcoin_transaction.dart';
import 'package:libspiffy/src/models/deferred_payment.dart';
import 'package:libspiffy/src/services/arc_service.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';
import 'package:test/test.dart';

const _walletId = 'follow';
final _txid = 'cd' * 32;
const _wait = Duration(seconds: 10);
const _quick = [Duration(milliseconds: 10), Duration(milliseconds: 10), Duration(milliseconds: 10)];

void main() {
  late LocalActorSystem system;
  late _ScriptedArc arc;
  late _RecordingWalletManager wallet;
  late ActorRef walletManager;

  setUp(() async {
    system = LocalActorSystem(ActorSystemConfig());
    arc = _ScriptedArc();
    wallet = _RecordingWalletManager();
    walletManager = await system.spawn('wallet-manager', () => wallet);
  });

  tearDown(() => system.shutdown());

  Future<ActorRef> spawnArc({List<Duration> delays = _quick}) => system.spawn(
        'arc-${DateTime.now().microsecondsSinceEpoch}',
        () => ARCActor(
          walletManager: walletManager,
          storage: InMemoryWalletStorage(),
          arcService: arc,
          statusCheckInterval: const Duration(minutes: 10),
          inFlightFollowDelays: delays,
        ),
      );

  Future<dynamic> broadcast(ActorRef arcActor, {String? txid}) =>
      arcActor.ask<dynamic>(BroadcastTransactionMessage(_walletId, '00', txid ?? _txid), _wait);

  List<TransactionStatus> statusUpdates() => [
        for (final c in wallet.commands)
          if (c is UpdateTransactionStatusCommand) c.newStatus,
      ];

  test('a submission answered RECEIVED is answered with the status ARC gets to', () async {
    arc
      ..submitStatus = 'RECEIVED'
      ..later.addAll(['ACCEPTED_BY_NETWORK', 'SEEN_ON_NETWORK']);
    final reply = await broadcast(await spawnArc());

    expect(reply, isA<BroadcastSuccessMessage>());
    expect((reply as BroadcastSuccessMessage).networkStatus, 'SEEN_ON_NETWORK');
    expect(arc.queries, 2, reason: 'followed until it left flight, and no further');
    expect(statusUpdates(), [TransactionStatus.broadcast, TransactionStatus.seenOnNetwork],
        reason: 'the wallet hears the first answer at once and the one ARC got to after');
  });

  test("Arcade's SEEN_MULTIPLE_NODES is on the network", () async {
    arc
      ..submitStatus = 'RECEIVED'
      ..later.add('SEEN_MULTIPLE_NODES');
    final reply = await broadcast(await spawnArc()) as BroadcastSuccessMessage;

    expect(reply.networkStatus, 'SEEN_MULTIPLE_NODES');
    expect(DeferredNetworkStatus.isOnNetwork(reply.networkStatus), isTrue);
    expect(statusUpdates().last, TransactionStatus.seenOnNetwork);
  });

  test('a submission that turns out contested is answered contested', () async {
    arc
      ..submitStatus = 'STORED'
      ..later.addAll(['RECEIVED', 'DOUBLE_SPEND_ATTEMPTED']);
    final reply = await broadcast(await spawnArc()) as BroadcastSuccessMessage;

    expect(reply.networkStatus, 'DOUBLE_SPEND_ATTEMPTED');
    expect(DeferredNetworkStatus.isContested(reply.networkStatus), isTrue);
  });

  test('a submission that turns out rejected is answered as a failure', () async {
    arc
      ..submitStatus = 'RECEIVED'
      ..later.add('REJECTED');
    final reply = await broadcast(await spawnArc());

    expect(reply, isA<BroadcastFailedMessage>());
    expect((reply as BroadcastFailedMessage).networkStatus, 'REJECTED');
    expect(statusUpdates().last, TransactionStatus.failed);
  });

  test('a status query that fails leaves the answer in hand, and the follow goes on', () async {
    arc
      ..submitStatus = 'RECEIVED'
      ..later.addAll([_ScriptedArc.notFound, 'SEEN_ON_NETWORK']);
    final reply = await broadcast(await spawnArc()) as BroadcastSuccessMessage;

    expect(reply.networkStatus, 'SEEN_ON_NETWORK');
    expect(arc.queries, 2);
  });

  test('still in flight when the follow runs out: answered with the latest status', () async {
    arc
      ..submitStatus = 'RECEIVED'
      ..later.add('ACCEPTED_BY_NETWORK');
    final reply = await broadcast(await spawnArc()) as BroadcastSuccessMessage;

    expect(reply.networkStatus, 'ACCEPTED_BY_NETWORK');
    expect(arc.queries, _quick.length, reason: 'one query after each delay');
  });

  test('an answer that is not in flight is answered at once, unfollowed', () async {
    arc.submitStatus = 'SEEN_ON_NETWORK';
    final reply = await broadcast(await spawnArc()) as BroadcastSuccessMessage;

    expect(reply.networkStatus, 'SEEN_ON_NETWORK');
    expect(arc.queries, 0);
  });

  test('a deferred payment broadcast is answered with the status ARC gets to', () async {
    arc
      ..submitStatus = 'RECEIVED'
      ..later.add('SEEN_ON_NETWORK');
    final arcActor = await spawnArc();
    final result = await arcActor.ask<DeferredPaymentNetworkResult>(
      BroadcastDeferredPaymentMessage(walletId: _walletId, txid: _txid, rawTxHex: '00'),
      _wait,
    );

    expect(result.success, isTrue, reason: result.error);
    expect(result.networkStatus, 'SEEN_ON_NETWORK');
    expect(result.source, 'arc');
  });

  test('ARCActor is not held while it follows a submission, and stopping answers it', () async {
    arc
      ..submitStatus = 'RECEIVED'
      ..later.add('RECEIVED');
    final arcActor = await spawnArc(delays: const [Duration(minutes: 5)]);
    final followed = broadcast(arcActor);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    // Another submission while the first is followed: answered at once.
    arc.submitStatus = 'SEEN_ON_NETWORK';
    final other = await broadcast(arcActor, txid: 'ef' * 32).timeout(const Duration(seconds: 2));
    expect((other as BroadcastSuccessMessage).networkStatus, 'SEEN_ON_NETWORK');

    var answered = false;
    unawaited(followed.then((_) => answered = true));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(answered, isFalse, reason: 'the first submission is still followed');

    await arcActor.ask<ArcWorkStoppedMessage>(StopArcWorkMessage(), _wait);
    final reply = await followed.timeout(const Duration(seconds: 2)) as BroadcastSuccessMessage;
    expect(reply.networkStatus, 'RECEIVED', reason: 'stopping answers it with what ARC said so far');
  });
}

/// An ARC whose submission answers [submitStatus] and whose status queries
/// answer [later] in turn, its last repeated. [notFound] there answers 404.
class _ScriptedArc extends ArcService {
  _ScriptedArc() : super(baseUrl: 'fake://arc');

  static const notFound = 'NOT_FOUND';

  String submitStatus = 'SEEN_ON_NETWORK';
  final List<String> later = [];
  int queries = 0;

  @override
  Future<ArcSubmitResponse> submitTransaction(String rawTx, {String? callbackUrl}) async =>
      ArcSubmitResponse.fromJson({'txid': _txid, 'txStatus': submitStatus});

  @override
  Future<ArcTransactionResponse> getTransaction(String txid) async {
    queries++;
    final status = later.length > 1 ? later.removeAt(0) : later.single;
    if (status == notFound) {
      throw ArcException('Failed to get transaction: {"error":"transaction not found"}', statusCode: 404);
    }
    return ArcTransactionResponse.fromJson({'txid': txid, 'txStatus': status});
  }
}

/// Records the wallet commands ARCActor sends; answers nothing.
class _RecordingWalletManager extends Actor {
  final List<WalletCommand> commands = [];

  @override
  Future<void> onMessage(dynamic message) async {
    if (message is WalletCommandMessage) commands.add(message.command);
  }
}
