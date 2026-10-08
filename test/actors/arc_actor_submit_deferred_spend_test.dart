/// ARCActor: the deferred spend when ARC's submit response already reports
/// the transaction on the network (bead libspiffy-09k).
///
/// A transaction recorded with deferSpend keeps its inputs reserved and its
/// wallet outputs pending until ARC reports it on the network. The submit
/// handlers forwarded ARC's submit status to the wallet
/// (UpdateTransactionStatusCommand) but applied no spend; the status scan
/// only applied it on a stored-status *transition* to SEEN_ON_NETWORK. ARC
/// commonly answers SEEN_ON_NETWORK on submit, so the stored status was
/// already SEEN_ON_NETWORK, every later scan saw "unchanged", and inputs stayed
/// reserved and change pending until the transaction was mined and its proof
/// verified. A submit answering MINED applied nothing either.
///
/// What the spend is, the wallet aggregate decides (ApplyDeferredSpendCommand,
/// bead libspiffy-3egy): this actor sends it the transaction on the first
/// report, whatever the read model shows, and afterwards only when the read
/// model still shows something outstanding.
///
/// Fixture: a real testnet transaction (spends 6af69a37…:0, output 1 is the
/// wallet's change), its real BRC-74 proof and the real header of its block.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:dactor/dactor.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:duraq_isar/duraq_isar.dart' as duraq_isar;
import 'package:isar_community/isar.dart';
import 'package:libspiffy/src/actors/arc_actor.dart';
import 'package:libspiffy/src/actors/wallet_messages.dart';
import 'package:libspiffy/src/core/wallet_commands.dart';
import 'package:libspiffy/src/models/bitcoin_transaction.dart';
import 'package:libspiffy/src/models/bitcoin_utxo.dart';
import 'package:libspiffy/src/services/arc_service.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';
import 'package:libspiffy/src/utils/beef.dart';
import 'package:test/test.dart';

import '../spv/testnet_proof_fixture.dart';

const _wallet = 'w';
const _fundingTxid = '6af69a37518c963234ab5b9e0c6afb6bc7273f1be58e98c42336c29067c0b665';
const _inputKey = '$_fundingTxid:0';
const _changeKey = '$kFixtureTxid:1';

void main() {
  late LocalActorSystem system;
  late InMemoryWalletStorage storage;
  late _ProjectingWalletManager walletManager;
  late _SubmitArc arc;
  late ActorRef arcActor;

  Future<void> storeTx(TransactionStatus status) => storage.storeTransaction(
        _wallet,
        BitcoinTransaction(
          walletId: _wallet,
          txid: kFixtureTxid,
          rawHex: kFixtureTxHex,
          status: status,
          inputValue: BigInt.zero,
          outputValue: BigInt.zero,
          fee: BigInt.zero,
          receivingAddresses: const [],
          sendingAddresses: const [],
          netAmount: BigInt.zero,
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
          lockTime: 0,
          version: 1,
        ),
      );

  Future<void> storeUtxo(String txid, int vout, UTXOStatus status) => storage.upsertUTXO(
        _wallet,
        BitcoinUtxo.create(
          txid: txid,
          vout: vout,
          satoshis: BigInt.from(1000),
          scriptPubKey: '76a914${'00' * 20}88ac',
          address: 'addr-$txid-$vout',
          status: status,
        ),
      );

  /// What the payment coordinator leaves behind before broadcasting a
  /// deferSpend transaction: the transaction recorded pending, its input
  /// reserved, its change output pending.
  Future<void> recordDeferredSpendPayment() async {
    await storeTx(TransactionStatus.pending);
    await storeUtxo(_fundingTxid, 0, UTXOStatus.reserved);
    await storeUtxo(kFixtureTxid, 1, UTXOStatus.pending);
  }

  ArcTransactionResponse statusResponse(String txStatus, {bool withProof = true}) =>
      ArcTransactionResponse.fromJson({
        'timestamp': '2026-09-14T08:00:00Z',
        'txid': kFixtureTxid,
        'txStatus': txStatus,
        if (txStatus == 'MINED') ...{
          'blockHash': kFixtureBlockHash,
          'blockHeight': kFixtureHeight,
          if (withProof) 'merklePath': fixtureBumpHex(),
        },
      });

  ArcSubmitResponse submitResponse(String txStatus, {bool withProof = false}) => ArcSubmitResponse.fromJson({
        'timestamp': '2026-09-14T08:00:00Z',
        'txid': kFixtureTxid,
        'txStatus': txStatus,
        if (txStatus == 'MINED') ...{
          'blockHash': kFixtureBlockHash,
          'blockHeight': kFixtureHeight,
          if (withProof) 'merklePath': fixtureBumpHex(),
        },
      });

  /// The ARC actor's clock: the wall clock plus [clockAhead].
  var clockAhead = Duration.zero;

  Future<void> spawnActor({Isar? isar, Duration statusCheckInterval = const Duration(minutes: 10)}) async {
    final wm = await system.spawn('wallet-manager', () => walletManager);
    arcActor = await system.spawn(
      'arc',
      () => ARCActor(
        walletManager: wm,
        storage: storage,
        arcService: arc,
        isar: isar,
        statusCheckInterval: statusCheckInterval,
        headerTriggerDebounce: const Duration(milliseconds: 10),
        clock: () => DateTime.now().add(clockAhead),
        // An answer still in flight is followed briefly, then reported.
        inFlightFollowDelays: const [Duration(milliseconds: 10)],
      ),
    );
  }

  /// Send [message] to the ARC actor and wait for its broadcast reply.
  Future<dynamic> request(dynamic message) async {
    final probe = _ReplyProbe();
    final probeRef = await system.spawn('probe-${DateTime.now().microsecondsSinceEpoch}', () => probe);
    arcActor.tell(message, sender: probeRef);
    final reply = await probe.reply.future.timeout(const Duration(seconds: 5));
    await Future<void>.delayed(const Duration(milliseconds: 200));
    return reply;
  }

  /// Broadcast the fixture transaction and wait for the reply.
  Future<dynamic> broadcast() => request(BroadcastTransactionMessage(_wallet, kFixtureTxHex, kFixtureTxid));

  /// One status scan (header notification), waited for.
  Future<void> scan({bool queriesArc = true}) async {
    final calls = arc.getTransactionCalls;
    arcActor.tell(CheckStoragePendingUTXOsMessage(triggerBlockHeight: kFixtureHeight));
    final deadline = DateTime.now().add(Duration(milliseconds: queriesArc ? 5000 : 300));
    while (arc.getTransactionCalls <= calls && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }

  /// The transactions whose deferred spend the wallet was sent.
  List<String> applied() => [for (final c in walletManager.commands.whereType<ApplyDeferredSpendCommand>()) c.txid];
  Future<Map<String, UTXOStatus>> rows() async =>
      {for (final u in await storage.getUTXOs(_wallet, includeSpent: true)) u.key: u.status};
  List<ConfirmTransactionCommand> confirms() =>
      walletManager.commands.whereType<ConfirmTransactionCommand>().toList();

  setUp(() {
    clockAhead = Duration.zero;
    system = LocalActorSystem(ActorSystemConfig());
    storage = InMemoryWalletStorage();
    walletManager = _ProjectingWalletManager(storage);
    arc = _SubmitArc();
  });

  tearDown(() => system.shutdown());

  group('submit reports SEEN_ON_NETWORK: the deferred spend is applied (09k)', () {
    test('BroadcastTransactionMessage: inputs spent and change available once; a later SEEN_ON_NETWORK '
        'and MINED report neither repeats them nor skips the proof', () async {
      await recordDeferredSpendPayment();
      arc.submitResponses.add(submitResponse('SEEN_ON_NETWORK'));
      arc.statusResponses[kFixtureTxid] = statusResponse('SEEN_ON_NETWORK');
      await spawnActor();

      expect(await broadcast(), isA<BroadcastSuccessMessage>());
      await scan(); // ARC still reports SEEN_ON_NETWORK

      expect(applied(), [kFixtureTxid], reason: 'sent once ARC accepted the transaction on the network');
      expect(walletManager.commands.whereType<ApplyDeferredSpendCommand>().single.rawHex, kFixtureTxHex);
      final stored = await rows();
      expect(stored[_inputKey], UTXOStatus.spent);
      expect(stored[_changeKey], UTXOStatus.available);

      // Mined, header stored: confirmation with the proof, no second spend.
      await storage.storeBlockHeader(fixtureHeader(), kFixtureHeight);
      arc.statusResponses[kFixtureTxid] = statusResponse('MINED');
      await scan();

      expect(confirms(), hasLength(1));
      expect(confirms().single.bumpHex, fixtureBumpHex(), reason: 'the proof is journaled with the confirmation');
      expect(applied(), [kFixtureTxid], reason: 'not sent a second time');
    });

    test('exactly once also when the read model has not caught up with the commands yet', () async {
      await recordDeferredSpendPayment();
      walletManager.projectUtxoCommands = false; // read model lags behind the aggregate
      arc.submitResponses.add(submitResponse('SEEN_ON_NETWORK'));
      arc.statusResponses[kFixtureTxid] = statusResponse('SEEN_ON_NETWORK');
      await spawnActor();

      await broadcast();
      await scan();
      expect(applied(), [kFixtureTxid]);

      await scan(); // SEEN_ON_NETWORK again; the read model still shows the input reserved
      await storage.storeBlockHeader(fixtureHeader(), kFixtureHeight);
      arc.statusResponses[kFixtureTxid] = statusResponse('MINED');
      await scan();

      expect(confirms(), hasLength(1));
      expect(applied(), [kFixtureTxid], reason: 'not sent again while the read model catches up');
    });

    test('after a restart: a transaction stored SEEN_ON_NETWORK with its spend outstanding gets it from the '
        'next SEEN_ON_NETWORK status report', () async {
      // The submit status was journaled, the process stopped before the
      // spend reached the wallet.
      await recordDeferredSpendPayment();
      await storeTx(TransactionStatus.seenOnNetwork);
      arc.statusResponses[kFixtureTxid] = statusResponse('SEEN_ON_NETWORK');
      await spawnActor();

      await scan();
      await scan();

      expect(applied(), [kFixtureTxid]);
      final stored = await rows();
      expect(stored[_inputKey], UTXOStatus.spent);
      expect(stored[_changeKey], UTXOStatus.available);
    });

    test('BroadcastBEEFMessage: inputs spent and change available', () async {
      await recordDeferredSpendPayment();
      arc.submitResponses.add(submitResponse('SEEN_ON_NETWORK'));
      arc.statusResponses[kFixtureTxid] = statusResponse('SEEN_ON_NETWORK');
      await spawnActor();

      final beef = BEEF(
        version: 0x0100BEEF,
        bumps: const [],
        txs: [Uint8List.fromList(hex.decode(kFixtureTxHex))],
        hasMerkle: const [false],
        bumpIndex: const [],
      );
      final reply = await request(BroadcastBEEFMessage(_wallet, hex.encode(beef.serialize()), kFixtureTxid));
      expect(reply, isA<BroadcastSuccessMessage>());
      expect(arc.submitted, [kFixtureTxHex]);
      await scan();

      expect(applied(), [kFixtureTxid]);
      final stored = await rows();
      expect(stored[_inputKey], UTXOStatus.spent);
      expect(stored[_changeKey], UTXOStatus.available);
    });

    // The retry path discarded the submit status altogether, so the spend
    // waited for a status query to report the transaction (ARC's status
    // endpoint answers 404 here throughout).
    test('durable retry queue: a retried submit answered SEEN_ON_NETWORK applies the spend', () async {
      await Isar.initializeIsarCore(download: true);
      final dir = await Directory.systemTemp.createTemp('arc_retry_09k_');
      final isar = await Isar.open(duraq_isar.IsarStorage.requiredSchemas,
          directory: dir.path, name: 'arc_retry_${DateTime.now().microsecondsSinceEpoch}');
      addTearDown(() async {
        await isar.close(deleteFromDisk: true);
        await dir.delete(recursive: true);
      });

      await recordDeferredSpendPayment();
      // The first submission fails; its retry (from the periodic tick) is
      // answered SEEN_ON_NETWORK.
      arc.failSubmissions = 1;
      arc.submitResponses.add(submitResponse('SEEN_ON_NETWORK'));
      await spawnActor(isar: isar, statusCheckInterval: const Duration(milliseconds: 100));

      expect(await broadcast(), isA<BroadcastFailedMessage>());
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (arc.submitted.length < 2 && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(arc.submitted, hasLength(2), reason: 'the queued transaction was retried');
      await Future<void>.delayed(const Duration(milliseconds: 400)); // several more ticks and scans

      expect(applied(), [kFixtureTxid]);
      final stored = await rows();
      expect(stored[_inputKey], UTXOStatus.spent);
      expect(stored[_changeKey], UTXOStatus.available);
      expect((await storage.getTransaction(kFixtureTxid, walletId: _wallet))!.status,
          TransactionStatus.seenOnNetwork);
    });
  });

  // Beads libspiffy-onh and libspiffy-3egy: ARC answered before the read
  // model held the recording, or held all of it. The deferred spend used to
  // be worked out from the read model, which at that moment showed no
  // change output, so the change waited for the next status scan
  // (statusCheckInterval, 30 s by default). The projection applies a
  // recording one event at a time, the transaction row before its outputs.
  group('ARC answers before the read model holds the recording', () {
    for (final status in ['SEEN_ON_NETWORK', 'MINED']) {
      test('$status, nothing of the recording projected: the wallet is sent the spend at once, '
          'with the transaction', () async {
        await storeUtxo(_fundingTxid, 0, UTXOStatus.reserved);
        arc.submitResponses.add(submitResponse(status));
        await spawnActor(); // status scan every 10 minutes

        await broadcast();

        final sent = walletManager.commands.whereType<ApplyDeferredSpendCommand>().single;
        expect((sent.txid, sent.rawHex), (kFixtureTxid, kFixtureTxHex));
        expect(arc.getTransactionCalls, 0, reason: 'ARC already answered; it is not asked again');
      });

      // The reported case: the row is there, its outputs are not.
      test('$status, the transaction row projected and its outputs not yet: sent at once all the same', () async {
        await storeUtxo(_fundingTxid, 0, UTXOStatus.reserved);
        await storeTx(TransactionStatus.pending);
        arc.submitResponses.add(submitResponse(status));
        await spawnActor();

        await broadcast();

        // Old code: the input spent, no output to promote, and no recheck
        // (the row was there): nothing more until the next scan.
        expect(applied(), [kFixtureTxid]);
      });
    }
  });

  group('a later report of a transaction the wallet was sent', () {
    Future<void> reportedOnce() async {
      await recordDeferredSpendPayment();
      arc.submitResponses.add(submitResponse('SEEN_ON_NETWORK'));
      arc.statusResponses[kFixtureTxid] = statusResponse('SEEN_ON_NETWORK');
      await spawnActor();
      await broadcast();
      expect(applied(), [kFixtureTxid]);
      expect(await rows(), {_inputKey: UTXOStatus.spent, _changeKey: UTXOStatus.available});
    }

    test('is not sent while the read model shows nothing outstanding, however long ago the last was', () async {
      await reportedOnce();

      clockAhead = const Duration(hours: 1);
      await scan();
      await scan();

      expect(applied(), [kFixtureTxid], reason: 'a wallet is not woken for a spend that is applied');
    });

    test('is sent when an output of the transaction has become pending since', () async {
      await reportedOnce();
      await storeUtxo(kFixtureTxid, 0, UTXOStatus.pending); // received another way, after the first report

      await scan();
      expect(applied(), [kFixtureTxid], reason: 'not within the reconfirm window: the read model may only be late');

      clockAhead = const Duration(hours: 1);
      await scan();
      expect(applied(), [kFixtureTxid, kFixtureTxid]);
      expect((await rows())['$kFixtureTxid:0'], UTXOStatus.available);
    });

    test('is sent when the read model still shows an input unspent', () async {
      await reportedOnce();
      await storeUtxo(_fundingTxid, 0, UTXOStatus.reserved); // a reservation held it back

      clockAhead = const Duration(hours: 1);
      await scan();

      expect(applied(), [kFixtureTxid, kFixtureTxid]);
      expect((await rows())[_inputKey], UTXOStatus.spent);
    });

    test('is sent once more after a day, whatever the read model shows', () async {
      await reportedOnce();

      clockAhead = const Duration(days: 1, minutes: 1);
      await scan();
      await scan();

      expect(applied(), [kFixtureTxid, kFixtureTxid]);
    });
  });

  group('submit reports MINED: spend applied once and confirmation handled (09k)', () {
    test('with a merklePath in the submit response: confirmed from it, spend applied once', () async {
      await recordDeferredSpendPayment();
      await storage.storeBlockHeader(fixtureHeader(), kFixtureHeight);
      arc.submitResponses.add(submitResponse('MINED', withProof: true));
      // ARC's status endpoint does not know the transaction (yet).
      await spawnActor();

      await broadcast();
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(applied(), [kFixtureTxid]);
      expect(confirms(), hasLength(1));
      expect(confirms().single.blockHash, kFixtureBlockHash);
      expect(confirms().single.bumpHex, fixtureBumpHex());

      // A later MINED status report changes nothing.
      arc.statusResponses[kFixtureTxid] = statusResponse('MINED');
      await scan();
      expect(applied(), hasLength(1));
      expect(confirms(), hasLength(1));
    });

    test('without a merklePath, header not stored yet: spend applied at once; confirmed once the header '
        'arrives, from the status query\'s proof, without a second spend', () async {
      await recordDeferredSpendPayment();
      arc.submitResponses.add(submitResponse('MINED'));
      arc.statusResponses[kFixtureTxid] = statusResponse('MINED');
      await spawnActor();

      await broadcast();
      await scan();

      expect(applied(), [kFixtureTxid], reason: 'a mined transaction is on the network');
      expect(confirms(), isEmpty, reason: 'no header at that height yet');

      await storage.storeBlockHeader(fixtureHeader(), kFixtureHeight);
      await scan();

      expect(confirms(), hasLength(1));
      expect(confirms().single.bumpHex, fixtureBumpHex());
      expect(applied(), [kFixtureTxid], reason: 'not sent a second time');
    });

    test('with a merklePath, header not stored yet: spend applied, confirmation held', () async {
      await recordDeferredSpendPayment();
      arc.submitResponses.add(submitResponse('MINED', withProof: true));
      await spawnActor();

      await broadcast();
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(applied(), [kFixtureTxid], reason: 'a mined transaction is on the network');
      expect(confirms(), isEmpty, reason: 'the proof is not checked against a header yet');
    });
  });

  group('submit rejected: inputs are not spent (09k guard)', () {
    for (final status in ['REJECTED', 'DOUBLE_SPEND_ATTEMPTED', 'SEEN_IN_ORPHAN_MEMPOOL', 'STORED']) {
      test(status, () async {
        await recordDeferredSpendPayment();
        arc.submitResponses.add(submitResponse(status));
        arc.statusResponses[kFixtureTxid] = statusResponse(status);
        await spawnActor();

        await broadcast();
        // A failed transaction is terminal and no longer polled.
        await scan(queriesArc: !['REJECTED', 'DOUBLE_SPEND_ATTEMPTED'].contains(status));

        expect(applied(), isEmpty);
        final stored = await rows();
        expect(stored[_inputKey], UTXOStatus.reserved);
        expect(stored[_changeKey], UTXOStatus.pending);
      });
    }
  });
}

/// Records every wallet command and applies the ones ARCActor sends to the
/// read model, as the wallet aggregate and WalletProjection would.
class _ProjectingWalletManager extends Actor {
  _ProjectingWalletManager(this.storage);

  final InMemoryWalletStorage storage;
  final List<WalletCommand> commands = [];
  bool projectUtxoCommands = true;

  @override
  Future<void> onMessage(dynamic message) async {
    if (message is! WalletCommandMessage) return;
    final command = message.command;
    commands.add(command);
    if (command is UpdateTransactionStatusCommand) {
      final tx = await storage.getTransaction(command.txid, walletId: command.walletId);
      if (tx != null) {
        await storage.storeTransaction(command.walletId, tx.copyWith(status: command.newStatus));
      }
    } else if (command is ConfirmTransactionCommand) {
      final tx = await storage.getTransaction(command.txid, walletId: command.walletId);
      if (tx != null) {
        await storage.storeTransaction(command.walletId, tx.copyWith(status: TransactionStatus.confirmed));
      }
    } else if (projectUtxoCommands && command is ApplyDeferredSpendCommand) {
      final inputs = {
        for (final i in dartsv.Transaction.fromHex(command.rawHex!).inputs) '${i.prevTxnId}:${i.prevTxnOutputIndex}',
      };
      for (final utxo in await storage.getUTXOs(command.walletId)) {
        if (inputs.contains(utxo.key)) {
          await storage.upsertUTXO(command.walletId, utxo.markSpent(spentInTxId: command.txid));
        } else if (utxo.txid == command.txid && utxo.awaitsPromotion) {
          await storage.upsertUTXO(command.walletId, utxo.copyWith(status: UTXOStatus.available));
        }
      }
    }
  }
}

/// Receives the ARC actor's reply to one broadcast request.
class _ReplyProbe extends Actor {
  final Completer<dynamic> reply = Completer<dynamic>();

  @override
  Future<void> onMessage(dynamic message) async {
    if (!reply.isCompleted) reply.complete(message);
  }
}

/// ARC without a network: submissions answer from [submitResponses] in order
/// (the last one repeats), status queries from [statusResponses].
class _SubmitArc extends ArcService {
  _SubmitArc() : super(baseUrl: 'fake://arc');

  final List<ArcSubmitResponse> submitResponses = [];
  final Map<String, ArcTransactionResponse> statusResponses = {};
  final List<String> submitted = [];
  /// This many submissions fail (ARC unreachable) before any is answered.
  int failSubmissions = 0;
  int getTransactionCalls = 0;

  @override
  Future<ArcSubmitResponse> submitTransaction(String rawTx, {String? callbackUrl}) async {
    submitted.add(rawTx);
    if (submitted.length <= failSubmissions) throw ArcException('ARC unavailable');
    return submitResponses.length > 1 ? submitResponses.removeAt(0) : submitResponses.single;
  }

  @override
  Future<ArcTransactionResponse> getTransaction(String txid) async {
    getTransactionCalls++;
    final response = statusResponses[txid];
    if (response == null) throw ArcException('Failed to get transaction: {"status":404}');
    return response;
  }
}
