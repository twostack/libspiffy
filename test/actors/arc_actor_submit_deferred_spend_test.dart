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
/// Fixture: a real testnet transaction (spends 6af69a37…:0, output 1 is the
/// wallet's change), its real BRC-74 proof and the real header of its block.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:dactor/dactor.dart';
import 'package:duraq_isar/duraq_isar.dart' as duraq_isar;
import 'package:isar/isar.dart';
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
  late _CountingStorage storage;
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

  List<String> spends() =>
      [for (final c in walletManager.commands.whereType<SpendUTXOCommand>()) '${c.utxoKey}>${c.spendingTxId}'];
  List<String> promoted() =>
      [for (final c in walletManager.commands.whereType<MarkUTXOAvailableCommand>()) '${c.txid}:${c.vout}'];
  List<ConfirmTransactionCommand> confirms() =>
      walletManager.commands.whereType<ConfirmTransactionCommand>().toList();

  setUp(() {
    system = LocalActorSystem(ActorSystemConfig());
    storage = _CountingStorage();
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

      expect(spends(), ['$_inputKey>$kFixtureTxid'],
          reason: 'the input is spent once ARC accepted the transaction on the network');
      expect(promoted(), [_changeKey], reason: 'only the wallet change output becomes available');
      final stored = {for (final u in await storage.getUTXOs(_wallet, includeSpent: true)) u.key: u.status};
      expect(stored[_inputKey], UTXOStatus.spent);
      expect(stored[_changeKey], UTXOStatus.available);

      // Mined, header stored: confirmation with the proof, no second spend.
      await storage.storeBlockHeader(fixtureHeader(), kFixtureHeight);
      arc.statusResponses[kFixtureTxid] = statusResponse('MINED');
      await scan();

      expect(confirms(), hasLength(1));
      expect(confirms().single.bumpHex, fixtureBumpHex(), reason: 'the proof is journaled with the confirmation');
      expect(spends(), ['$_inputKey>$kFixtureTxid'], reason: 'no second spend command');
      expect(promoted(), [_changeKey], reason: 'no second available command');
    });

    test('exactly once also when the read model has not caught up with the commands yet', () async {
      await recordDeferredSpendPayment();
      walletManager.projectUtxoCommands = false; // read model lags behind the aggregate
      arc.submitResponses.add(submitResponse('SEEN_ON_NETWORK'));
      arc.statusResponses[kFixtureTxid] = statusResponse('SEEN_ON_NETWORK');
      await spawnActor();

      await broadcast();
      await scan();
      expect(spends(), ['$_inputKey>$kFixtureTxid']);
      expect(promoted(), [_changeKey]);

      await scan(); // SEEN_ON_NETWORK again; the read model still shows the input reserved
      await storage.storeBlockHeader(fixtureHeader(), kFixtureHeight);
      arc.statusResponses[kFixtureTxid] = statusResponse('MINED');
      await scan();

      expect(confirms(), hasLength(1));
      expect(spends(), ['$_inputKey>$kFixtureTxid'], reason: 'no second spend command');
      expect(promoted(), [_changeKey], reason: 'no second available command');
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

      expect(spends(), ['$_inputKey>$kFixtureTxid']);
      expect(promoted(), [_changeKey]);
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

      expect(spends(), ['$_inputKey>$kFixtureTxid']);
      expect(promoted(), [_changeKey]);
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

      expect(spends(), ['$_inputKey>$kFixtureTxid']);
      expect(promoted(), [_changeKey]);
      expect((await storage.getTransaction(kFixtureTxid, walletId: _wallet))!.status,
          TransactionStatus.seenOnNetwork);
    });
  });

  // Bead libspiffy-onh: ARC answered before the read model held the
  // recording. The deferred spend is driven by what the read model shows
  // outstanding, and at that moment it showed no change output at all, so
  // the change waited for the next status scan (statusCheckInterval, 30 s
  // by default) -- which asks ARC again for an answer it already gave.
  group('onh: ARC answers before the read model holds the recording', () {
    for (final status in ['SEEN_ON_NETWORK', 'MINED']) {
      test('$status: the change becomes available once the recording is projected, '
          'without waiting for a scan or asking ARC again', () async {
        // Only the reservation of the input is projected; the recording
        // (transaction row, change output) is not, yet.
        await storeUtxo(_fundingTxid, 0, UTXOStatus.reserved);
        arc.submitResponses.add(submitResponse(status));
        await spawnActor(); // status scan every 10 minutes

        await broadcast();
        expect(spends(), ['$_inputKey>$kFixtureTxid'], reason: 'the input was projected: spent at once');
        expect(promoted(), isEmpty, reason: 'precondition: no change output to promote yet');

        // The projection catches up.
        await storeTx(TransactionStatus.seenOnNetwork);
        await storeUtxo(kFixtureTxid, 1, UTXOStatus.pending);

        final deadline = DateTime.now().add(const Duration(seconds: 5));
        while (promoted().isEmpty && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        // Old code: nothing until the next scan, ten minutes away.
        expect(promoted(), [_changeKey]);
        expect(arc.getTransactionCalls, 0, reason: 'ARC already answered; it is not asked again');
        expect(spends(), ['$_inputKey>$kFixtureTxid'], reason: 'the input is not spent twice');
      });
    }

    test('a recording the read model never shows is rechecked only until a scan would have covered it', () async {
      await storeUtxo(_fundingTxid, 0, UTXOStatus.reserved);
      arc.submitResponses.add(submitResponse('SEEN_ON_NETWORK'));
      await spawnActor(statusCheckInterval: const Duration(seconds: 2));

      await broadcast();
      await Future<void>.delayed(const Duration(seconds: 4));
      final looks = storage.transactionLookups[kFixtureTxid] ?? 0;
      await Future<void>.delayed(const Duration(seconds: 3));

      // One look per second while a scan was still to come, then none: the
      // scan's own storage query reads no row for it (there is none).
      expect(looks, inInclusiveRange(2, 4));
      expect(storage.transactionLookups[kFixtureTxid], looks, reason: 'the recheck never stops');
      expect(promoted(), isEmpty);
      expect(arc.getTransactionCalls, 0, reason: 'a transaction the read model does not hold is not polled');
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

      expect(spends(), ['$_inputKey>$kFixtureTxid']);
      expect(promoted(), [_changeKey]);
      expect(confirms(), hasLength(1));
      expect(confirms().single.blockHash, kFixtureBlockHash);
      expect(confirms().single.bumpHex, fixtureBumpHex());

      // A later MINED status report changes nothing.
      arc.statusResponses[kFixtureTxid] = statusResponse('MINED');
      await scan();
      expect(spends(), hasLength(1));
      expect(promoted(), hasLength(1));
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

      expect(spends(), ['$_inputKey>$kFixtureTxid'], reason: 'a mined transaction is on the network');
      expect(promoted(), [_changeKey]);
      expect(confirms(), isEmpty, reason: 'no header at that height yet');

      await storage.storeBlockHeader(fixtureHeader(), kFixtureHeight);
      await scan();

      expect(confirms(), hasLength(1));
      expect(confirms().single.bumpHex, fixtureBumpHex());
      expect(spends(), ['$_inputKey>$kFixtureTxid'], reason: 'no second spend command');
      expect(promoted(), [_changeKey], reason: 'no second available command');
    });

    test('with a merklePath, header not stored yet: spend applied, confirmation held', () async {
      await recordDeferredSpendPayment();
      arc.submitResponses.add(submitResponse('MINED', withProof: true));
      await spawnActor();

      await broadcast();
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(spends(), ['$_inputKey>$kFixtureTxid'], reason: 'a mined transaction is on the network');
      expect(promoted(), [_changeKey]);
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

        expect(spends(), isEmpty);
        expect(promoted(), isEmpty);
        final stored = {for (final u in await storage.getUTXOs(_wallet, includeSpent: true)) u.key: u.status};
        expect(stored[_inputKey], UTXOStatus.reserved);
        expect(stored[_changeKey], UTXOStatus.pending);
      });
    }
  });
}

/// Records every wallet command and applies the ones ARCActor sends to the
/// read model, as WalletProjection would.
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
    } else if (projectUtxoCommands && command is SpendUTXOCommand) {
      final utxo = await _utxo(command.walletId, command.utxoKey);
      if (utxo != null && utxo.status != UTXOStatus.spent) {
        await storage.upsertUTXO(command.walletId, utxo.markSpent(spentInTxId: command.spendingTxId));
      }
    } else if (projectUtxoCommands && command is MarkUTXOAvailableCommand) {
      final utxo = await _utxo(command.walletId, '${command.txid}:${command.vout}');
      if (utxo != null && utxo.status == UTXOStatus.pending) {
        await storage.upsertUTXO(command.walletId, utxo.copyWith(status: UTXOStatus.available));
      }
    }
  }

  Future<BitcoinUtxo?> _utxo(String walletId, String key) async {
    for (final u in await storage.getUTXOs(walletId, includeSpent: true)) {
      if (u.key == key) return u;
    }
    return null;
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

/// The read model, counting lookups of one transaction by txid.
class _CountingStorage extends InMemoryWalletStorage {
  final Map<String, int> transactionLookups = {};

  @override
  Future<BitcoinTransaction?> getTransaction(String txid, {String? walletId}) {
    transactionLookups[txid] = (transactionLookups[txid] ?? 0) + 1;
    return super.getTransaction(txid, walletId: walletId);
  }
}
