/// Bead libspiffy-pq5e: what ARCActor tells the caller of a submission.
///
/// ARC answers a submission with the status the transaction reached, and it
/// answers REJECTED with an HTTP 200 like any other. ARCActor replied
/// [BroadcastSuccessMessage] to every 200, carrying no status, so no caller
/// could tell a rejected transaction from an accepted one:
///
/// * PaymentChannelManagerActor took a rejected funding as broadcast and
///   marked the funding inputs spent — coins gone from the balance for a
///   transaction the network refused. A refund likewise.
/// * SettleBEEFCommand counted a rejected child as submitted.
///
/// And a submission that failed and was queued for another attempt was
/// reported only as failed, so the caller could not know one was coming.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:dactor/dactor.dart';
import 'package:duraq_isar/duraq_isar.dart' as duraq_isar;
import 'package:isar/isar.dart';
import 'package:test/test.dart';

import 'package:libspiffy/src/actors/arc_actor.dart';
import 'package:libspiffy/src/actors/wallet_messages.dart';
import 'package:libspiffy/src/services/arc_service.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';
import 'package:libspiffy/src/utils/beef.dart';

import '../spv/testnet_proof_fixture.dart';

const _wallet = 'w-pq5e';

void main() {
  late LocalActorSystem system;
  late _SubmitArc arc;
  late ActorRef arcActor;

  Future<void> spawn({Isar? isar}) async {
    final walletManager = await system.spawn('wallet-manager', () => _Silent());
    arcActor = await system.spawn(
      'arc',
      () => ARCActor(
        walletManager: walletManager,
        storage: InMemoryWalletStorage(),
        arcService: arc,
        isar: isar,
        statusCheckInterval: const Duration(minutes: 30),
        failedCheckInterval: const Duration(minutes: 30),
      ),
    );
  }

  ArcSubmitResponse answer(String txStatus, {String? message}) => ArcSubmitResponse.fromJson({
        'timestamp': '2026-09-21T08:00:00Z',
        'txid': kFixtureTxid,
        'txStatus': txStatus,
        if (message != null) 'extraInfo': message,
      });

  String beefHex() => hex.encode(BEEF.create(
        bumps: const [],
        txs: [Uint8List.fromList(hex.decode(kFixtureTxHex))],
        hasMerkle: const [false],
        bumpIndex: const [],
      ).serialize());

  final submissions = <String, dynamic Function()>{
    'BroadcastTransactionMessage': () => BroadcastTransactionMessage(_wallet, kFixtureTxHex, kFixtureTxid),
    'BroadcastBEEFMessage': () => BroadcastBEEFMessage(_wallet, beefHex(), kFixtureTxid),
  };

  Future<dynamic> submit(dynamic message) async {
    final probe = _ReplyProbe();
    final probeRef = await system.spawn('probe-${DateTime.now().microsecondsSinceEpoch}', () => probe);
    arcActor.tell(message, sender: probeRef);
    return probe.reply.future.timeout(const Duration(seconds: 5));
  }

  setUp(() {
    system = LocalActorSystem(ActorSystemConfig());
    arc = _SubmitArc();
  });
  tearDown(() => system.shutdown());

  for (final MapEntry(key: name, value: message) in submissions.entries) {
    group('pq5e $name:', () {
      test('a submission ARC answered REJECTED is a failure, with the status and ARC\'s reason', () async {
        arc.answer = answer('REJECTED', message: 'missing inputs');
        await spawn();

        final reply = await submit(message());

        // Old code: BroadcastSuccessMessage, with no status at all.
        expect(reply, isA<BroadcastFailedMessage>());
        reply as BroadcastFailedMessage;
        expect(reply.txid, kFixtureTxid);
        expect(reply.networkStatus, 'REJECTED');
        expect(reply.error, allOf(contains('rejected'), contains('missing inputs')));
        expect(reply.willRetry, isFalse,
            reason: 'a refusal is ARC\'s answer, not an outage: nothing resubmits it');
      });

      for (final status in ['SEEN_ON_NETWORK', 'STORED', 'DOUBLE_SPEND_ATTEMPTED', 'MINED']) {
        test('a submission ARC answered $status is a success that says so', () async {
          arc.answer = answer(status);
          await spawn();

          final reply = await submit(message());

          expect(reply, isA<BroadcastSuccessMessage>());
          expect((reply as BroadcastSuccessMessage).networkStatus, status,
              reason: 'ARC holds it; the caller is told how far it got');
        });
      }

      test('a submission that did not reach ARC, with no retry queue, says nothing will retry it', () async {
        arc.unreachable = true;
        await spawn();

        final reply = await submit(message());

        expect(reply, isA<BroadcastFailedMessage>());
        reply as BroadcastFailedMessage;
        expect(reply.networkStatus, isNull, reason: 'ARC gave no answer');
        expect(reply.willRetry, isFalse);
      });
    });
  }

  test('pq5e: a submission that did not reach ARC and was queued says it will be retried', () async {
    await Isar.initializeIsarCore(download: true);
    final dir = await Directory.systemTemp.createTemp('arc_pq5e_');
    final isar = await Isar.open(duraq_isar.IsarStorage.requiredSchemas,
        directory: dir.path, name: 'arc_pq5e_${DateTime.now().microsecondsSinceEpoch}');
    addTearDown(() async {
      await isar.close(deleteFromDisk: true);
      await dir.delete(recursive: true);
    });
    arc.unreachable = true;
    await spawn(isar: isar);

    final reply = await submit(BroadcastTransactionMessage(_wallet, kFixtureTxHex, kFixtureTxid));

    // Old code: a bare failure, although the transaction was queued.
    expect(reply, isA<BroadcastFailedMessage>());
    reply as BroadcastFailedMessage;
    expect(reply.willRetry, isTrue);
    expect(reply.networkStatus, isNull);
  });
}

/// ARC without a network: every submission gets [answer], or throws when
/// [unreachable].
class _SubmitArc extends ArcService {
  _SubmitArc() : super(baseUrl: 'fake://arc');

  ArcSubmitResponse? answer;
  bool unreachable = false;

  @override
  Future<ArcSubmitResponse> submitTransaction(String rawTx, {String? callbackUrl}) async {
    if (unreachable) throw ArcException('ARC unavailable');
    return answer!;
  }

  @override
  Future<ArcTransactionResponse> getTransaction(String txid) async =>
      throw ArcException('Failed to get transaction: {"status":404}', statusCode: 404);
}

class _ReplyProbe extends Actor {
  final Completer<dynamic> reply = Completer<dynamic>();

  @override
  Future<void> onMessage(dynamic message) async {
    if (!reply.isCompleted) reply.complete(message);
  }
}

class _Silent extends Actor {
  @override
  Future<void> onMessage(dynamic message) async {}
}
