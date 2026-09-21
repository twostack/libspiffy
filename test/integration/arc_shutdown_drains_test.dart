/// Bead libspiffy-vr89: shutdown waits for what ARCActor has in flight.
///
/// ARCActor's handlers are asynchronous: a submission awaits ARC, and when
/// it fails it queues its retry in the Isar store. `shutdown()` stopped the
/// projections and then the actors and returned, and the host then closed
/// Isar -- while a submission could still be waiting on ARC. When it failed,
/// its enqueue wrote into a closed store, and the process died with SEGV in
/// libisar (seen in the V-124 full suite). Now shutdown asks ARCActor to
/// stop its work first ([StopArcWorkMessage]) and returns only when nothing
/// of ARCActor's can write the store; the retry the failed submission
/// queued is kept, not dropped.
library;

import 'dart:async';
import 'dart:io';

import 'package:dactor/dactor.dart';
import 'package:duraq/duraq.dart' as duraq;
import 'package:duraq_isar/duraq_isar.dart' as duraq_isar;
import 'package:isar/isar.dart';
import 'package:libspiffy/libspiffy.dart';
import 'package:libspiffy/src/actors/wallet_messages.dart';
import 'package:test/test.dart';

import '../spv/testnet_proof_fixture.dart';
import 'isar_test_helper.dart';

void main() {
  late Directory dir;
  late Isar isar;
  late _GatedArc arc;
  late LibSpiffyActorSystem system;

  setUpAll(() async {
    await ensureIsarInitialized();
  });

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('vr89_');
    isar = await Isar.open(LibSpiffySchemas.allSchemas,
        directory: dir.path, name: 'vr89_${DateTime.now().microsecondsSinceEpoch}');
    arc = _GatedArc();
    system = LibSpiffyActorSystem();
    await system.initialize(
      actorSystem: LocalActorSystem(ActorSystemConfig()),
      isar: isar,
      readModelStorage: InMemoryWalletStorage(),
      secureStorage: InMemorySecureStorage(),
      dataDirectory: dir.path,
      networkType: 'regtest',
      enableP2P: false,
      arcService: arc,
    );
  });

  tearDown(() async {
    arc.release();
    try {
      await isar.close(deleteFromDisk: true);
    } catch (_) {}
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  });

  test('vr89: shutdown returns only after a submission in flight has finished, and its queued retry is kept',
      () async {
    system.arcActor.tell(BroadcastTransactionMessage('w', kFixtureTxHex, kFixtureTxid));
    await arc.submitting.future.timeout(const Duration(seconds: 5));

    var returned = false;
    final shutdown = system.shutdown().then((_) => returned = true);
    await Future<void>.delayed(const Duration(milliseconds: 500));

    // Old code: shutdown had returned, and the host would close Isar under
    // the submission.
    expect(returned, isFalse, reason: 'shutdown returned while ARC work was in flight');

    arc.release(); // the submission fails: ARC is unreachable
    await shutdown.timeout(const Duration(seconds: 10));

    // Nothing of ARCActor's writes the store any more; the retry is in it.
    final queue = duraq.Queue<Map<String, dynamic>>('arc_broadcast_retry', duraq_isar.IsarStorage(isar));
    expect(await queue.length, 1, reason: 'the failed submission\'s retry was dropped');
  });
}

/// ARC whose submission waits until [release], then fails as an unreachable
/// ARC does.
class _GatedArc extends ArcService {
  _GatedArc() : super(baseUrl: 'fake://arc');

  final Completer<void> submitting = Completer<void>();
  final Completer<void> _gate = Completer<void>();

  void release() {
    if (!_gate.isCompleted) _gate.complete();
  }

  @override
  Future<ArcSubmitResponse> submitTransaction(String rawTx, {String? callbackUrl}) async {
    if (!submitting.isCompleted) submitting.complete();
    await _gate.future;
    throw ArcException('ARC unavailable');
  }

  @override
  Future<ArcTransactionResponse> getTransaction(String txid) async =>
      throw ArcException('Failed to get transaction: {"status":404}', statusCode: 404);
}
