/// Bead libspiffy-wdch: follow-ups of the Benford split fixes (ypp, V-49).
///
/// * BenfordCoordinatorActor answered a split as a success as soon as it had
///   told ARCActor to broadcast it, before ARC answered: a split ARC
///   REJECTED (its source released) or reported DOUBLE_SPEND_ATTEMPTED (its
///   source held, contested) was reported to the caller as a success.
/// * When the wallet did not acknowledge the split's recording in time the
///   split was not broadcast, but a recording the wallet journaled after all
///   kept the source held by a transaction nobody would ever broadcast.
///
/// Now the reply follows ARC's answer to the broadcast (asked outside the
/// coordinator's mailbox), and a recording that timed out is cancelled in
/// the wallet's command order.
library;

// The ARCActor stand-in answers its sender through dactor's @internal
// `Actor.context`.
// ignore_for_file: invalid_use_of_internal_member

import 'dart:async';

import 'package:dactor/dactor.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:eventador/eventador.dart';
import 'package:libspiffy/src/actors/arc_actor.dart';
import 'package:libspiffy/src/actors/coordinator_messages.dart' as coord;
import 'package:libspiffy/src/actors/wallet_coordinator_actor.dart';
import 'package:libspiffy/src/actors/benford_coordinator_actor.dart';
import 'package:libspiffy/src/actors/wallet_manager_actor.dart';
import 'package:libspiffy/src/actors/wallet_messages.dart';
import 'package:libspiffy/src/core/wallet_commands.dart';
import 'package:libspiffy/src/core/wallet_events.dart';
import 'package:libspiffy/src/models/bitcoin_utxo.dart';
import 'package:libspiffy/src/services/arc_service.dart';
import 'package:libspiffy/src/services/dartsv_crypto_service.dart';
import 'package:libspiffy/src/storage/in_memory_secure_storage.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';
import 'package:test/test.dart';

import 'in_memory_event_store.dart';

const _xpriv =
    'tprv8ZgxMBicQKsPeMiDjtXBGAyFY1wEMGgomjwf54ZmiZfKTNYvVdBa6GqWUwnvtHm6NKVkQkhCKxaobd9JPxNEXgDfVgJ5RNHJ3ivogSG3V1R';
const _walletId = 'benford-wdch';
final _sourceTxid = 'b2' * 32;
final _sourceKey = '$_sourceTxid:0';
const _wait = Duration(seconds: 10);

void main() {
  late LocalActorSystem system;
  late InMemoryEventStore eventStore;
  late InMemoryWalletStorage readModel;
  late _GatedArc arc;
  late ActorRef walletManager;

  setUp(() async {
    system = LocalActorSystem(ActorSystemConfig());
    eventStore = InMemoryEventStore();
    readModel = InMemoryWalletStorage();
    arc = _GatedArc();
    walletManager = await system.spawn(
      'wallet-manager',
      () => WalletManagerActor(
        eventStore: eventStore,
        cryptoService: DartSVCryptoService(),
        secureStorage: InMemorySecureStorage(),
        aggregateIdleTimeout: null,
        readModelStorage: readModel,
      ),
    );
  });

  tearDown(() async {
    arc.release();
    await system.shutdown();
  });

  List<Event> journal() => eventStore.journal['BitcoinWallet_$_walletId'] ?? const [];

  /// ARCActor over [arc] (an ARC without a network).
  Future<ActorRef> realArcActor() => system.spawn(
        'arc',
        () => ARCActor(
          walletManager: walletManager,
          storage: readModel,
          arcService: arc,
          statusCheckInterval: const Duration(minutes: 10),
        ),
      );

  Future<ActorRef> benfordWith(ActorRef arcActor,
          {ActorRef? wallet, Duration? walletReplyTimeout}) =>
      system.spawn(
        'benford-${DateTime.now().microsecondsSinceEpoch}',
        () => BenfordCoordinatorActor(
          walletManager: wallet ?? walletManager,
          arcActor: arcActor,
          storage: readModel,
          walletReplyTimeout: walletReplyTimeout ?? const Duration(seconds: 30),
        ),
      );

  /// Creates the wallet and gives it [count] 100 000 sat UTXOs (outputs of
  /// one transaction) at a generated address, each step acknowledged by the
  /// wallet aggregate. The read model shows the wallet and the UTXOs, as a
  /// projection that caught up would.
  Future<void> walletWithOneUtxo({int count = 1}) async {
    final created = await walletManager.ask<WalletCreatedMessage>(
      CreateWalletMessage(_walletId, 'Benford', xpriv: _xpriv),
      _wait,
    );
    expect(created.success, isTrue, reason: created.error);
    final generated = await walletManager.ask<AddressGeneratedResponse>(
      WalletCommandMessage(_walletId, GenerateAddressCommand(walletId: _walletId)),
      _wait,
    );
    expect(generated.success, isTrue, reason: generated.error);
    final address = generated.address;
    final script = dartsv.P2PKHLockBuilder.fromAddress(dartsv.Address(address)).getScriptPubkey().toHex();
    await readModel.storeWallet(_walletId, 'Benford', networkType: 'testnet', metadata: {'walletType': 'hd'});
    for (var vout = 0; vout < count; vout++) {
      final received = await walletManager.ask<UTXOReceivedResponse>(
        WalletCommandMessage(
          _walletId,
          ReceiveUTXOCommand(
            walletId: _walletId,
            txid: _sourceTxid,
            vout: vout,
            satoshis: BigInt.from(100000),
            scriptPubKey: script,
            address: address,
            blockHeight: 100,
            confirmations: 6,
            initialStatus: UTXOStatus.available,
          ),
        ),
        _wait,
      );
      expect(received.success, isTrue, reason: received.error);
      await readModel.upsertUTXO(
        _walletId,
        BitcoinUtxo.create(
          txid: _sourceTxid,
          vout: vout,
          satoshis: BigInt.from(100000),
          scriptPubKey: script,
          address: address,
          status: UTXOStatus.available,
        ),
      );
    }
  }

  Future<SplitUTXOsResponse> split(ActorRef benford) => benford.ask<SplitUTXOsResponse>(
        SplitUTXOsToBenfordCommand(walletId: _walletId, targetUtxoCount: 3, feeRate: BigInt.one),
        const Duration(seconds: 40),
      );

  Future<void> until(bool Function() condition, String what) async {
    final deadline = DateTime.now().add(_wait);
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) fail('Timed out waiting for $what');
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  /// Whether a new payment could take the source now.
  Future<UTXOReservedResponse> reserveSource() => walletManager.ask<UTXOReservedResponse>(
        WalletCommandMessage(
          _walletId,
          ReserveUTXOCommand(walletId: _walletId, utxoKey: _sourceKey, reservedByTxId: 'next-payment'),
        ),
        _wait,
      );

  group('the reply follows ARC\'s answer to the broadcast', () {
    test('no reply before ARC has answered', () async {
      await walletWithOneUtxo();
      final benford = await benfordWith(await realArcActor());
      arc.gate = Completer<void>();

      var answered = false;
      final reply = split(benford).whenComplete(() => answered = true);
      await until(() => arc.submitted.isNotEmpty, 'the broadcast');
      await Future<void>.delayed(const Duration(milliseconds: 300));

      // Old code: the split was answered as soon as the broadcast was told.
      expect(answered, isFalse, reason: 'the split was answered before ARC answered its broadcast');
      arc.release();
      final response = await reply;
      expect(response.success, isTrue, reason: response.error);
      expect(response.txids, [arc.submitted.single]);
      expect(response.splits.single.status, SplitTransactionStatus.accepted);
      expect(response.splits.single.networkStatus, 'SEEN_ON_NETWORK');
      expect(response.splits.single.sourceUtxoKey, _sourceKey);
    });

    test('a split ARC rejects is answered with a failure naming ARC\'s reason', () async {
      await walletWithOneUtxo();
      final benford = await benfordWith(await realArcActor());
      arc.status = 'REJECTED';
      arc.message = 'mandatory-script-verify-flag-failed';

      final response = await split(benford);

      // Old code: success: true.
      expect(response.success, isFalse, reason: 'ARC rejected the split');
      final txid = arc.submitted.single;
      expect(response.error, contains(txid));
      expect(response.error, contains('REJECTED'));
      expect(response.error, contains('mandatory-script-verify-flag-failed'));
      expect(response.txids ?? const [], isEmpty);
      expect(response.splits.single.status, SplitTransactionStatus.rejected);
      // ARC's answer settled the hold: the source is free again.
      await until(() => journal().any((e) => e is DeferredTransactionFailedEvent && e.txid == txid), 'the failure');
      final reserved = await reserveSource();
      expect(reserved.success, isTrue, reason: reserved.error);
    });

    test('a contested split (DOUBLE_SPEND_ATTEMPTED) is not a success and its source stays held', () async {
      await walletWithOneUtxo();
      final benford = await benfordWith(await realArcActor());
      arc.status = 'DOUBLE_SPEND_ATTEMPTED';

      final response = await split(benford);

      // Old code: success: true.
      expect(response.success, isFalse, reason: 'ARC reports the split contested');
      final txid = arc.submitted.single;
      expect(response.error, contains(txid));
      expect(response.error, contains('DOUBLE_SPEND_ATTEMPTED'));
      expect(response.splits.single.status, SplitTransactionStatus.contested);
      await until(
          () => journal().any((e) => e is TransactionNetworkStatusCheckedEvent && e.txid == txid),
          'the contested status');
      expect(journal().whereType<DeferredTransactionFailedEvent>(), isEmpty);
      final reserved = await reserveSource();
      expect(reserved.success, isFalse, reason: 'the contested split still holds its source (ey2)');
    });

    test('the coordinator answers other requests while ARC has not answered', () async {
      await walletWithOneUtxo();
      final benford = await benfordWith(await realArcActor());
      arc.gate = Completer<void>();

      final reply = split(benford);
      await until(() => arc.submitted.isNotEmpty, 'the broadcast');
      final other = await benford.ask<SplitUTXOsResponse>(
        SplitUTXOsToBenfordCommand(walletId: 'no-such-wallet', targetUtxoCount: 3),
        const Duration(seconds: 5),
      );
      expect(other.success, isFalse);
      expect(other.error, contains('Wallet not found'));

      arc.release();
      expect((await reply).success, isTrue);
    });
  });

  group('ARCActor\'s answer, reported per split', () {
    Future<(ActorRef, _ScriptedArcActor)> scriptedArc(
        DeferredPaymentNetworkResult? Function(BroadcastDeferredPaymentMessage) answer) async {
      final actor = _ScriptedArcActor(answer);
      return (await system.spawn('scripted-arc', () => actor), actor);
    }

    test('ARC unreachable with the broadcast queued for a retry: a success, reported queued', () async {
      await walletWithOneUtxo();
      final (arcRef, _) = await scriptedArc((m) => DeferredPaymentNetworkResult(
          walletId: m.walletId, txid: m.txid, success: false, willRetry: true, error: 'connection refused'));
      final response = await split(await benfordWith(arcRef));

      expect(response.success, isTrue, reason: response.error);
      final outcome = response.splits.single;
      expect(outcome.status, SplitTransactionStatus.queued);
      expect(response.txids, [outcome.txid]);
      expect(response.splitCount, 3);
    });

    test('recorded but neither broadcast nor queued: not a success, and the source stays held', () async {
      await walletWithOneUtxo();
      final (arcRef, _) = await scriptedArc((m) => DeferredPaymentNetworkResult(
          walletId: m.walletId, txid: m.txid, success: false, error: 'ARC service not available'));
      final response = await split(await benfordWith(arcRef));

      expect(response.success, isFalse);
      final outcome = response.splits.single;
      expect(outcome.status, SplitTransactionStatus.notBroadcast);
      expect(response.error, allOf(contains('ARC service not available'), contains('CancelDeferredPaymentCommand')));
      expect(journal().whereType<TransactionSpendDeferredEvent>().single.txid, outcome.txid);
      expect((await reserveSource()).success, isFalse, reason: 'the recorded split holds its source');
    });

    test('no answer from ARCActor in time: not a success, reported unanswered', () async {
      await walletWithOneUtxo();
      final (arcRef, arcActor) = await scriptedArc((_) => null);
      final benford = await system.spawn(
        'benford-unanswered',
        () => BenfordCoordinatorActor(
          walletManager: walletManager,
          arcActor: arcRef,
          storage: readModel,
          broadcastReplyTimeout: const Duration(milliseconds: 300),
        ),
      );
      final response = await split(benford);

      expect(response.success, isFalse);
      expect(response.splits.single.status, SplitTransactionStatus.unanswered);
      expect(arcActor.received.single.txid, response.splits.single.txid);
    });

    test('several splits: each is reported in split order, whatever order ARC answers in', () async {
      await walletWithOneUtxo(count: 2);
      late _ScriptedArcActor arcActor;
      final (arcRef, actor) = await scriptedArc((m) {
        // Hold the first broadcast; once the second arrives, answer both,
        // the second first.
        if (arcActor.received.length == 1) return null;
        final first = arcActor.received.first;
        arcActor.answerHeld(m, DeferredPaymentNetworkResult(
            walletId: m.walletId, txid: m.txid, success: true, networkStatus: 'SEEN_ON_NETWORK'));
        arcActor.answerHeld(first, DeferredPaymentNetworkResult(
            walletId: first.walletId, txid: first.txid, success: true, networkStatus: 'REJECTED', error: 'bad'));
        return null;
      });
      arcActor = actor;
      final response = await split(await benfordWith(arcRef));

      expect(response.success, isFalse);
      expect(response.splits.map((o) => o.sourceUtxoKey), ['$_sourceTxid:0', '$_sourceTxid:1']);
      expect(response.splits.map((o) => o.status), [SplitTransactionStatus.rejected, SplitTransactionStatus.accepted]);
      expect(response.txids, [response.splits[1].txid]);
      expect(response.error, contains(response.splits[0].txid));
      expect(response.error, isNot(contains(response.splits[1].txid)));
    });
  });

  test('the public UTXOSplitCompleteEvent carries each split\'s outcome', () async {
    final noop = await system.spawn('noop', () => _ScriptedWalletManager(null));
    final outcome = SplitTransactionOutcome(
      txid: 'c3' * 32,
      sourceUtxoKey: _sourceKey,
      status: SplitTransactionStatus.queued,
      error: 'connection refused',
    );
    final wallet = await system.spawn(
      'split-wallet-manager',
      () => _ScriptedWalletManager(SplitUTXOsResponse(
        walletId: _walletId,
        success: true,
        splitCount: 3,
        txids: [outcome.txid],
        splits: [outcome],
      )),
    );
    final coordinator = WalletCoordinatorActor(
      walletManager: wallet,
      invoiceCoordinator: noop,
      paymentCoordinator: noop,
      spvActor: noop,
      arcActor: noop,
      headerSyncActor: noop,
      benfordCoordinator: noop,
      channelManager: noop,
      walletProjection: noop,
      storage: readModel,
    );
    final completed = coordinator.events.firstWhere((e) => e is coord.UTXOSplitCompleteEvent);
    final ref = await system.spawn('coordinator', () => coordinator);

    ref.tell(coord.SplitUTXOsCommand(walletId: _walletId, targetUtxoCount: 3));
    final event = await completed.timeout(_wait) as coord.UTXOSplitCompleteEvent;

    expect(event.success, isTrue);
    expect(event.txids, [outcome.txid]);
    expect(event.splits.single.status, SplitTransactionStatus.queued);
  });

  test('a recording the wallet journals after the timeout does not leave the source held by an unbroadcast split',
      () async {
    await walletWithOneUtxo();
    final lateWallet = await system.spawn('late-wallet', () => _LateRecordingWallet(walletManager));
    final benford = await benfordWith(
      await realArcActor(),
      wallet: lateWallet,
      walletReplyTimeout: const Duration(milliseconds: 1500),
    );

    final response = await split(benford);
    expect(response.success, isFalse, reason: 'the wallet did not acknowledge the recording in time');
    expect(arc.submitted, isEmpty, reason: 'an unacknowledged recording is not broadcast');
    expect(response.splits.single.status, SplitTransactionStatus.notRecorded);

    // The wallet journals the recording late after all.
    await until(() => journal().any((e) => e is TransactionRecordedEvent), 'the late recording');
    final txid = journal().whereType<TransactionRecordedEvent>().single.txid;
    await until(
        () => journal().any((e) => e is DeferredTransactionCancelledEvent && e.txid == txid),
        'the unbroadcast split to be cancelled');

    // Old code: 'UTXO ... is held by deferred payment ...' for good.
    final reserved = await reserveSource();
    expect(reserved.success, isTrue, reason: reserved.error);
    expect(arc.submitted, isEmpty);
  });
}

/// ARCActor stand-in: answers a [BroadcastDeferredPaymentMessage] with what
/// [answer] returns; null holds the answer (see [answerHeld]).
class _ScriptedArcActor extends Actor {
  final DeferredPaymentNetworkResult? Function(BroadcastDeferredPaymentMessage) answer;
  _ScriptedArcActor(this.answer);

  final List<BroadcastDeferredPaymentMessage> received = [];
  final Map<String, ActorRef?> _held = {};

  void answerHeld(BroadcastDeferredPaymentMessage message, DeferredPaymentNetworkResult result) =>
      _held.remove(message.txid)?.tell(result);

  @override
  Future<void> onMessage(dynamic message) async {
    if (message is! BroadcastDeferredPaymentMessage) return;
    received.add(message);
    final sender = context.sender;
    _held[message.txid] = sender;
    final result = answer(message);
    if (result != null) {
      _held.remove(message.txid);
      sender?.tell(result);
    }
  }
}

/// A wallet manager that answers a Benford split with [reply].
class _ScriptedWalletManager extends Actor {
  final SplitUTXOsResponse? reply;
  _ScriptedWalletManager(this.reply);

  @override
  Future<void> onMessage(dynamic message) async {
    if (reply != null && message is WalletCommandMessage && message.command is SplitUTXOsToBenfordCommand) {
      context.sender?.tell(reply!);
    }
  }
}

/// A wallet manager in front of the real one that takes longer than the
/// coordinator waits to pass on a split's recording. Messages are passed on
/// in arrival order, as the wallet would process them.
class _LateRecordingWallet extends Actor {
  final ActorRef wallet;
  _LateRecordingWallet(this.wallet);

  @override
  Future<void> onMessage(dynamic message) async {
    if (message is WalletCommandMessage && message.command is RecordOutgoingTransactionCommand) {
      await Future<void>.delayed(const Duration(milliseconds: 2500));
    }
    wallet.tell(message, sender: context.sender);
  }
}

/// ARC without a network: answers a submission with [status] (and
/// [message]) once [gate], when set, is released.
class _GatedArc extends ArcService {
  _GatedArc() : super(baseUrl: 'fake://arc');

  final List<String> submitted = [];
  String status = 'SEEN_ON_NETWORK';
  String? message;
  Completer<void>? gate;

  void release() {
    if (gate != null && !gate!.isCompleted) gate!.complete();
  }

  @override
  Future<ArcSubmitResponse> submitTransaction(String rawTx, {String? callbackUrl}) async {
    final txid = dartsv.Transaction.fromHex(rawTx).id;
    submitted.add(txid);
    await gate?.future;
    return ArcSubmitResponse.fromJson({'txid': txid, 'txStatus': status, if (message != null) 'message': message});
  }

  @override
  Future<ArcTransactionResponse> getTransaction(String txid) async =>
      throw ArcException('Failed to get transaction: {"status":404}', statusCode: 404);
}
