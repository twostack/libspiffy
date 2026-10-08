/// ARCActor for deferred payments (bead libspiffy-7p2): check the network
/// status now, broadcast the payment ourselves, fall back to the configured
/// data source, and record every status the wallet acts on.
///
/// A MINED claim confirms only when its merkle proof walks to the stored
/// header, from ARC and from the data source alike. REJECTED and
/// DOUBLE_SPEND_ATTEMPTED reach the wallet as a recorded status (the
/// aggregate fails the payment); 404 and network errors do not.
///
/// Fixture: a real testnet transaction (spends 6af69a37…:0, output 1 is the
/// wallet's change), its real proof and header; a second real transaction
/// spending that change, for a BEEF with an unconfirmed parent.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:dactor/dactor.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:libspiffy/src/actors/arc_actor.dart';
import 'package:libspiffy/src/actors/wallet_messages.dart';
import 'package:libspiffy/src/core/wallet_commands.dart';
import 'package:libspiffy/src/models/bitcoin_transaction.dart';
import 'package:libspiffy/src/models/bitcoin_utxo.dart';
import 'package:libspiffy/src/models/blockchain_data_models.dart';
import 'package:libspiffy/src/models/deferred_payment.dart';
import 'package:libspiffy/src/models/fee_rate.dart';
import 'package:libspiffy/src/services/arc_service.dart';
import 'package:libspiffy/src/services/blockchain_data_source.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';
import 'package:libspiffy/src/utils/beef.dart';
import 'package:test/test.dart';

import '../spv/testnet_proof_fixture.dart';

const _wallet = 'w';
const _fundingTxid = '6af69a37518c963234ab5b9e0c6afb6bc7273f1be58e98c42336c29067c0b665';
const _inputKey = '$_fundingTxid:0';
final _rivalA = 'a1' * 32;
final _rivalB = 'b2' * 32;

void main() {
  late LocalActorSystem system;
  late InMemoryWalletStorage storage;
  late _RecordingWalletManager walletManager;
  late _FakeArc arc;
  late _FakeDataSource dataSource;
  late ActorRef arcActor;

  Future<void> storeTx(String txid, String rawHex, {TransactionStatus status = TransactionStatus.pending}) =>
      storage.storeTransaction(
        _wallet,
        BitcoinTransaction(
          walletId: _wallet,
          txid: txid,
          rawHex: rawHex,
          status: status,
          inputValue: BigInt.zero,
          outputValue: BigInt.zero,
          fee: BigInt.zero,
          receivingAddresses: const [],
          sendingAddresses: const [],
          netAmount: BigInt.zero,
          createdAt: DateTime.utc(2026),
          updatedAt: DateTime.utc(2026),
          lockTime: 0,
          version: 1,
        ),
      );

  Future<void> storeUtxo(String key, UTXOStatus status, {String? reservedBy}) {
    final parts = key.split(':');
    return storage.upsertUTXO(
      _wallet,
      BitcoinUtxo.create(
        txid: parts[0],
        vout: int.parse(parts[1]),
        satoshis: BigInt.from(1000),
        scriptPubKey: '76a914${'00' * 20}88ac',
        address: 'addr-$key',
        status: status,
      ).copyWith(reservedByTxId: reservedBy),
    );
  }

  Future<void> storeDeferred(String txid, List<String> inputs) => storage.storeDeferredPayment(DeferredPayment(
        walletId: _wallet,
        txid: txid,
        amount: BigInt.from(100),
        fee: BigInt.from(10),
        heldInputs: [for (final k in inputs) DeferredPaymentInput(utxoKey: k, satoshis: BigInt.from(1000))],
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
      ));

  /// The fixture transaction handed over: recorded, input held, change pending.
  Future<void> handedOver() async {
    await storeTx(kFixtureTxid, kFixtureTxHex);
    await storeUtxo(_inputKey, UTXOStatus.reserved, reservedBy: kFixtureTxid);
    await storeUtxo('$kFixtureTxid:1', UTXOStatus.pending);
    await storeDeferred(kFixtureTxid, [_inputKey]);
  }

  ArcTransactionResponse status(String txStatus, {String? bumpHex}) => ArcTransactionResponse.fromJson({
        'txid': kFixtureTxid,
        'txStatus': txStatus,
        if (txStatus == 'MINED') ...{
          'blockHash': kFixtureBlockHash,
          'blockHeight': kFixtureHeight,
          if (bumpHex != null) 'merklePath': bumpHex,
        },
      });

  Future<void> spawnActor({bool withDataSource = true}) async {
    final wm = await system.spawn('wallet-manager', () => walletManager);
    arcActor = await system.spawn(
      'arc',
      () => ARCActor(
        walletManager: wm,
        storage: storage,
        arcService: arc,
        statusCheckInterval: const Duration(minutes: 10),
        headerTriggerDebounce: const Duration(milliseconds: 10),
        dataSource: withDataSource ? dataSource : null,
      ),
    );
  }

  Future<DeferredPaymentNetworkResult> ask(Message message) async {
    final result = await arcActor.ask<DeferredPaymentNetworkResult>(message, const Duration(seconds: 10));
    await Future<void>.delayed(const Duration(milliseconds: 100)); // commands reach the probe
    return result;
  }

  Future<DeferredPaymentNetworkResult> check({DeferredPaymentNetworkSource via = DeferredPaymentNetworkSource.arc}) =>
      ask(CheckDeferredPaymentStatusMessage(walletId: _wallet, txid: kFixtureTxid, via: via));

  /// The transactions whose deferred spend the wallet was sent.
  List<String> applied() => [for (final c in walletManager.commands.whereType<ApplyDeferredSpendCommand>()) c.txid];

  List<ConfirmTransactionCommand> confirms() => walletManager.commands.whereType<ConfirmTransactionCommand>().toList();
  List<String> statuses() => [
        for (final c in walletManager.commands.whereType<RecordTransactionNetworkStatusCommand>())
          '${c.networkStatus}/${c.source}${c.explicit ? '!' : ''}',
      ];

  setUp(() {
    system = LocalActorSystem(ActorSystemConfig());
    storage = InMemoryWalletStorage();
    walletManager = _RecordingWalletManager();
    arc = _FakeArc();
    dataSource = _FakeDataSource();
  });

  tearDown(() => system.shutdown());

  // Bead libspiffy-87a: what a transaction the wallet builds pays. There is
  // no replace-by-fee on this network, so the published policy rate is the
  // whole fee; and a policy ARC could not be asked for is an error, not a
  // licence to guess a rate. Since bead libspiffy-bg7n ARC answers the rate
  // and the wallet sizes the transaction (`TransactionSize`).
  group('policy fee rate (87a)', () {
    Future<FeeRateQuote> quote() => arcActor.ask<FeeRateQuote>(GetFeeRateMessage(), const Duration(seconds: 10));

    test("ARC's published miningFee", () async {
      arc.miningFee = const FeeRate(satoshis: 50, bytes: 1000);
      await spawnActor();

      final answer = await quote();

      expect(answer.success, isTrue, reason: answer.error);
      expect(answer.rate, const FeeRate(satoshis: 50, bytes: 1000));
      expect(answer.rate!.feeFor(192), BigInt.from(10), reason: '192 bytes at 50 sat/1000 bytes, rounded up');
    });

    test('a policy ARC cannot be asked for is a failure, not a guessed rate', () async {
      arc.unreachable = true;
      await spawnActor();

      final answer = await quote();

      expect(answer.success, isFalse);
      // Null since bead libspiffy-8743: a rate nobody published is no rate.
      expect(answer.rate, isNull);
      expect(answer.error, contains('policy'));
    });
  });

  group('check status now (ARC)', () {
    test('SEEN_ON_NETWORK: recorded (explicit) and the deferred spend applies', () async {
      await handedOver();
      arc.statuses[kFixtureTxid] = status('SEEN_ON_NETWORK');
      await spawnActor();

      final result = await check();

      expect(result.success, isTrue);
      expect(result.networkStatus, 'SEEN_ON_NETWORK');
      expect(result.source, 'arc');
      expect(statuses(), ['SEEN_ON_NETWORK/arc!']);
      expect(applied(), [kFixtureTxid]);
      expect(confirms(), isEmpty);
    });

    test('MINED with a proof matching the stored header: confirmed with the proof', () async {
      await handedOver();
      await storage.storeBlockHeader(fixtureHeader(), kFixtureHeight);
      arc.statuses[kFixtureTxid] = status('MINED', bumpHex: fixtureBumpHex());
      await spawnActor();

      final result = await check();

      expect(result.networkStatus, 'MINED');
      expect(result.proofStatus, 'verified');
      expect(result.confirmed, isTrue);
      expect(confirms().single.bumpHex, fixtureBumpHex());
      expect(applied(), [kFixtureTxid]);
    });

    test('MINED with a proof the stored header contradicts: not confirmed (a status string is not proof)',
        () async {
      await handedOver();
      await storage.storeBlockHeader(fixtureHeader(), kFixtureHeight);
      arc.statuses[kFixtureTxid] = status('MINED', bumpHex: fixtureBumpHex(tamperLevel: 1));
      await spawnActor();

      final result = await check();

      expect(result.networkStatus, 'MINED');
      expect(result.proofStatus, 'rootMismatch');
      expect(result.confirmed, isFalse);
      expect(confirms(), isEmpty);
    });

    for (final failure in ['REJECTED', 'DOUBLE_SPEND_ATTEMPTED']) {
      test('$failure: recorded for the wallet to fail the payment; nothing spent', () async {
        await handedOver();
        arc.statuses[kFixtureTxid] = status(failure);
        await spawnActor();

        final result = await check();

        expect(result.networkStatus, failure);
        expect(statuses(), ['$failure/arc!']);
        expect(applied(), isEmpty);
      });
    }

    test('404: NOT_FOUND recorded, nothing spent', () async {
      await handedOver();
      await spawnActor();

      final result = await check();

      expect(result.success, isTrue);
      expect(result.networkStatus, DeferredNetworkStatus.notFound);
      expect(statuses(), ['NOT_FOUND/arc!']);
      expect(applied(), isEmpty);
    });

    test('pkum: DOUBLE_SPEND_ATTEMPTED with ARC\'s competing txids: the recorded status and the result carry them',
        () async {
      await handedOver();
      arc.statuses[kFixtureTxid] = ArcTransactionResponse.fromJson({
        'txid': kFixtureTxid,
        'txStatus': 'DOUBLE_SPEND_ATTEMPTED',
        'competingTxs': [_rivalA, _rivalB],
      });
      await spawnActor();

      final result = await check();

      expect(result.networkStatus, DeferredNetworkStatus.doubleSpendAttempted);
      expect(result.competingTxids, [_rivalA, _rivalB]);
      final recorded = walletManager.commands.whereType<RecordTransactionNetworkStatusCommand>().single;
      expect(recorded.competingTxids, [_rivalA, _rivalB]);
      expect(applied(), isEmpty);
    });

    test('pkum: a status without competing txids records none', () async {
      await handedOver();
      arc.statuses[kFixtureTxid] = status('SEEN_ON_NETWORK');
      await spawnActor();

      final result = await check();

      expect(result.competingTxids, isEmpty);
      expect(walletManager.commands.whereType<RecordTransactionNetworkStatusCommand>().single.competingTxids, isEmpty);
    });

    test('ARC unreachable: no status, nothing recorded, an error', () async {
      await handedOver();
      arc.unreachable = true;
      await spawnActor();

      final result = await check();

      expect(result.success, isFalse);
      expect(result.error, contains('unreachable'));
      expect(statuses(), isEmpty);
      expect(applied(), isEmpty);
    });
  });

  group('periodic scan records what the wallet acts on', () {
    Future<void> scan() async {
      final calls = arc.getTransactionCalls;
      arcActor.tell(CheckStoragePendingUTXOsMessage(triggerBlockHeight: kFixtureHeight));
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (arc.getTransactionCalls <= calls && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }

    test('REJECTED reported by the scan reaches the wallet as a status (part 1b)', () async {
      await handedOver();
      arc.statuses[kFixtureTxid] = status('REJECTED');
      await spawnActor();

      await scan();

      expect(statuses(), ['REJECTED/arc']);
      expect(applied(), isEmpty);
    });

    test('pkum: a contested payment the scan meets reaches the wallet with ARC\'s competing txids', () async {
      await handedOver();
      arc.statuses[kFixtureTxid] = ArcTransactionResponse.fromJson(
          {'txid': kFixtureTxid, 'txStatus': 'DOUBLE_SPEND_ATTEMPTED', 'competingTxs': [_rivalA]});
      await spawnActor();

      await scan();

      final recorded = walletManager.commands.whereType<RecordTransactionNetworkStatusCommand>().single;
      expect((recorded.networkStatus, recorded.explicit), (DeferredNetworkStatus.doubleSpendAttempted, false));
      expect(recorded.competingTxids, [_rivalA]);
    });

    test('pkum (7dj rule): ARC reporting an earlier status (STORED) for a row already seenOnNetwork sends no '
        'status command, scan after scan; a later status still does', () async {
      List<String> updates(String txid) => [
            for (final c in walletManager.commands.whereType<UpdateTransactionStatusCommand>())
              if (c.txid == txid) c.newStatus.name,
          ];
      // Seen on the network already (e.g. the submit answer); ARC's status
      // endpoint still answers STORED.
      await storeTx(kFixture2Txid, kFixture2TxHex, status: TransactionStatus.seenOnNetwork);
      arc.statuses[kFixture2Txid] = ArcTransactionResponse.fromJson({'txid': kFixture2Txid, 'txStatus': 'STORED'});
      // Pending: STORED moves it on (the probe does not project, so every
      // scan finds it pending again).
      await storeTx(kFixtureTxid, kFixtureTxHex);
      arc.statuses[kFixtureTxid] = status('STORED');
      await spawnActor();

      await scan();
      await scan();

      expect(arc.getTransactionCalls, greaterThanOrEqualTo(4), reason: 'both rows checked on both scans');
      // Old code: [broadcast, broadcast], a command (and a journaled
      // TransactionStatusUpdatedEvent) the projection ignores on every pass.
      expect(updates(kFixture2Txid), isEmpty);
      expect(updates(kFixtureTxid), ['broadcast', 'broadcast']);
    });

    test('an unchanged status is not sent again; a transaction that is not a deferred payment sends none',
        () async {
      await handedOver();
      await storage.storeDeferredPayment((await storage.getDeferredPayment(_wallet, kFixtureTxid))!
          .copyWith(lastNetworkStatus: 'STORED', lastNetworkStatusSource: 'arc'));
      await storeTx(kFixture2Txid, kFixture2TxHex); // recorded, not deferred
      arc.statuses[kFixtureTxid] = status('STORED');
      arc.statuses[kFixture2Txid] = ArcTransactionResponse.fromJson({'txid': kFixture2Txid, 'txStatus': 'STORED'});
      await spawnActor();

      await scan();

      expect(statuses(), isEmpty);
    });
  });

  group('data source fallback', () {
    MerkleProofData proof({int? tamperLevel}) => MerkleProofData(
          txid: kFixtureTxid,
          blockHeight: kFixtureHeight,
          merkleRoot: '',
          index: kFixtureIndex,
          nodes: fixtureNodes(tamperLevel: tamperLevel),
          format: 'tsc',
        );

    test('known with a proof matching the header: spend applied and confirmed', () async {
      await handedOver();
      await storage.storeBlockHeader(fixtureHeader(), kFixtureHeight);
      dataSource.raw[kFixtureTxid] = kFixtureTxHex;
      dataSource.proofs[kFixtureTxid] = proof();
      await spawnActor();

      final result = await check(via: DeferredPaymentNetworkSource.dataSource);

      expect(result.source, 'dataSource');
      expect(result.networkStatus, 'MINED');
      expect(result.proofStatus, 'verified');
      expect(confirms().single.bumpHex, fixtureBumpHex());
      expect(applied(), [kFixtureTxid]);
      expect(arc.getTransactionCalls, 0);
    });

    test('known with a proof the header contradicts: seen (spend applied), never confirmed', () async {
      await handedOver();
      await storage.storeBlockHeader(fixtureHeader(), kFixtureHeight);
      dataSource.raw[kFixtureTxid] = kFixtureTxHex;
      dataSource.proofs[kFixtureTxid] = proof(tamperLevel: 0);
      await spawnActor();

      final result = await check(via: DeferredPaymentNetworkSource.dataSource);

      expect(result.proofStatus, 'rootMismatch');
      expect(result.confirmed, isFalse);
      expect(confirms(), isEmpty);
      expect(applied(), [kFixtureTxid]);
    });

    test('ARC does not know it, then the data source does (arcThenDataSource)', () async {
      await handedOver();
      dataSource.raw[kFixtureTxid] = kFixtureTxHex;
      await spawnActor();

      final result = await check(via: DeferredPaymentNetworkSource.arcThenDataSource);

      expect(result.networkStatus, 'SEEN_ON_NETWORK');
      expect(result.source, 'dataSource');
      expect(statuses(), ['NOT_FOUND/arc!', 'SEEN_ON_NETWORK/dataSource!']);
      expect(applied(), [kFixtureTxid]);
    });

    test('a data source returning another transaction for the txid is not believed', () async {
      await handedOver();
      dataSource.raw[kFixtureTxid] = kFixture2TxHex;
      await spawnActor();

      final result = await check(via: DeferredPaymentNetworkSource.dataSource);

      expect(result.success, isFalse);
      expect(applied(), isEmpty);
    });

    test('without a configured data source: an error', () async {
      await handedOver();
      await spawnActor(withDataSource: false);
      final result = await check(via: DeferredPaymentNetworkSource.dataSource);
      expect(result.success, isFalse);
      expect(result.error, contains('No blockchain data source'));
    });
  });

  group('broadcast ourselves', () {
    /// fixture2 spends the fixture transaction's change: a payment with an
    /// unconfirmed parent, as a BEEF.
    Future<String> beefWithUnconfirmedParent() async {
      await storeTx(kFixture2Txid, kFixture2TxHex);
      await storeUtxo('$kFixtureTxid:1', UTXOStatus.reserved, reservedBy: kFixture2Txid);
      await storeDeferred(kFixture2Txid, ['$kFixtureTxid:1']);
      final beef = BEEF(
        version: 0x0100BEEF,
        bumps: const [],
        txs: [Uint8List.fromList(hex.decode(kFixtureTxHex)), Uint8List.fromList(hex.decode(kFixture2TxHex))],
        hasMerkle: const [false, false],
        bumpIndex: const [],
      );
      return hex.encode(beef.serialize());
    }

    BroadcastDeferredPaymentMessage broadcast(String beefHex,
            {DeferredPaymentNetworkSource via = DeferredPaymentNetworkSource.arc}) =>
        BroadcastDeferredPaymentMessage(
            walletId: _wallet, txid: kFixture2Txid, rawTxHex: kFixture2TxHex, beefHex: beefHex, via: via);

    test('ARC: the unconfirmed parent first, then the payment; SEEN applies the spend (idempotent)', () async {
      final beefHex = await beefWithUnconfirmedParent();
      arc.submitStatus = 'SEEN_ON_NETWORK';
      await spawnActor();

      final first = await ask(broadcast(beefHex));
      final second = await ask(broadcast(beefHex));

      expect(arc.submitted, [kFixtureTxHex, kFixture2TxHex, kFixtureTxHex, kFixture2TxHex]);
      for (final result in [first, second]) {
        expect(result.success, isTrue);
        expect(result.networkStatus, 'SEEN_ON_NETWORK');
      }
      expect(applied(), [kFixture2Txid], reason: 'spent once');
      expect(statuses(), ['SEEN_ON_NETWORK/arc!', 'SEEN_ON_NETWORK/arc!']);
    });

    group('a plain broadcast with its BEEF (a channel funding)', () {
      Future<Message> broadcastPlain({String? beefHex}) => arcActor.ask<Message>(
          BroadcastTransactionMessage(_wallet, kFixture2TxHex, kFixture2Txid, retryOnFailure: false, beefHex: beefHex),
          const Duration(seconds: 10));

      test('the unconfirmed parent first, then the transaction: ARC can build its extended format', () async {
        final beefHex = await beefWithUnconfirmedParent();
        arc.submitStatus = 'SEEN_ON_NETWORK';
        await spawnActor();

        final reply = await broadcastPlain(beefHex: beefHex);

        expect(reply, isA<BroadcastSuccessMessage>());
        expect(arc.submitted, [kFixtureTxHex, kFixture2TxHex]);
      });

      test('a proven parent is not submitted again', () async {
        await storeTx(kFixture2Txid, kFixture2TxHex);
        final proven = BEEF(
          version: 0x0100BEEF,
          bumps: const [],
          txs: [Uint8List.fromList(hex.decode(kFixtureTxHex)), Uint8List.fromList(hex.decode(kFixture2TxHex))],
          hasMerkle: const [true, false],
          bumpIndex: const [0],
        );
        await spawnActor();

        await broadcastPlain(beefHex: hex.encode(proven.serialize()));

        expect(arc.submitted, [kFixture2TxHex]);
      });

      test('without a BEEF the transaction goes alone, as before', () async {
        await storeTx(kFixture2Txid, kFixture2TxHex);
        await spawnActor();

        await broadcastPlain();

        expect(arc.submitted, [kFixture2TxHex]);
      });
    });

    test('ARC answers REJECTED: recorded for the wallet to fail the payment, nothing spent', () async {
      final beefHex = await beefWithUnconfirmedParent();
      arc.submitStatus = 'REJECTED';
      await spawnActor();

      final result = await ask(broadcast(beefHex));

      expect(result.networkStatus, 'REJECTED');
      expect(statuses(), ['REJECTED/arc!']);
      expect(applied(), isEmpty);
    });

    test('pkum: ARC answers DOUBLE_SPEND_ATTEMPTED with competing txids: recorded and reported with them', () async {
      final beefHex = await beefWithUnconfirmedParent();
      arc.submitStatus = 'DOUBLE_SPEND_ATTEMPTED';
      arc.submitCompetingTxs = [_rivalB];
      await spawnActor();

      final result = await ask(broadcast(beefHex));

      expect(result.networkStatus, DeferredNetworkStatus.doubleSpendAttempted);
      expect(result.competingTxids, [_rivalB]);
      final recorded = walletManager.commands.whereType<RecordTransactionNetworkStatusCommand>().single;
      expect((recorded.txid, recorded.explicit), (kFixture2Txid, true));
      expect(recorded.competingTxids, [_rivalB]);
      expect(applied(), isEmpty);
    });

    test('ARC unreachable: failure reported, nothing recorded', () async {
      final beefHex = await beefWithUnconfirmedParent();
      arc.unreachable = true;
      await spawnActor();

      final result = await ask(broadcast(beefHex));

      expect(result.success, isFalse);
      expect(result.willRetry, isFalse, reason: 'no retry queue without Isar');
      expect(statuses(), isEmpty);
    });

    test('data source: a submission refused because the node already has it still reports it known', () async {
      final beefHex = await beefWithUnconfirmedParent();
      dataSource.rejectSubmissions = true;
      dataSource.raw[kFixture2Txid] = kFixture2TxHex;
      await spawnActor();

      final result = await ask(broadcast(beefHex, via: DeferredPaymentNetworkSource.dataSource));

      expect(dataSource.submitted, [kFixtureTxHex, kFixture2TxHex]);
      expect(result.success, isTrue);
      expect(result.networkStatus, 'SEEN_ON_NETWORK');
      expect(applied(), [kFixture2Txid]);
      expect(arc.submitted, isEmpty);
    });
  });

  // A payment the network keeps in flight for ever because a coin it spends
  // is already spent by a confirmed transaction (the TAAL testnet ARC left
  // one at SENT_TO_NETWORK for a day). The rival here is the fixture
  // transaction: it spends the same coin, and its proof walks to the
  // stored header.
  group('in flight for ever, an input already spent by a confirmed transaction', () {
    late String stuckHex;
    late String stuck;

    setUp(() {
      final tx = dartsv.Transaction()
        ..addInput(dartsv.TransactionInput(_fundingTxid, 0, dartsv.TransactionInput.MAX_SEQ_NUMBER))
        ..addOutput(dartsv.TransactionOutput(
            BigInt.from(900), dartsv.SVScript.fromHex('76a9149d02ce72bbdc1713d5537a0705d8ec7d9702c81088ac')));
      stuckHex = tx.serialize();
      stuck = tx.id;
    });

    MerkleProofData rivalProof({int? tamperLevel}) => MerkleProofData(
          txid: kFixtureTxid,
          blockHeight: kFixtureHeight,
          merkleRoot: '',
          index: kFixtureIndex,
          nodes: fixtureNodes(tamperLevel: tamperLevel),
          format: 'tsc',
        );

    Future<void> stuckFor(Duration age, {bool deferred = true, bool rivalConfirmed = true, int? tamper}) async {
      final lookup = _LookupDataSource()
        ..spenders['$_fundingTxid:0'] = OutputSpender(txid: kFixtureTxid, vin: 0, confirmed: rivalConfirmed);
      lookup.raw[kFixtureTxid] = kFixtureTxHex;
      lookup.proofs[kFixtureTxid] = rivalProof(tamperLevel: tamper);
      dataSource = lookup;
      await storage.storeBlockHeader(fixtureHeader(), kFixtureHeight);
      final at = DateTime.now().subtract(age);
      await storage.storeTransaction(
        _wallet,
        BitcoinTransaction(
          walletId: _wallet,
          txid: stuck,
          rawHex: stuckHex,
          status: TransactionStatus.broadcast,
          inputValue: BigInt.zero,
          outputValue: BigInt.from(900),
          fee: BigInt.zero,
          receivingAddresses: const [],
          sendingAddresses: const [],
          netAmount: BigInt.zero,
          createdAt: at,
          updatedAt: at,
        ),
      );
      if (deferred) {
        await storeUtxo(_inputKey, UTXOStatus.reserved, reservedBy: stuck);
        await storage.storeDeferredPayment(DeferredPayment(
          walletId: _wallet,
          txid: stuck,
          amount: BigInt.from(900),
          fee: BigInt.from(100),
          heldInputs: [DeferredPaymentInput(utxoKey: _inputKey, satoshis: BigInt.from(1000))],
          createdAt: at,
          updatedAt: at,
        ));
      }
      arc.statuses[stuck] = ArcTransactionResponse.fromJson({'txid': stuck, 'txStatus': 'SENT_TO_NETWORK'});
      await spawnActor();
    }

    Future<void> scan() async {
      final calls = arc.getTransactionCalls;
      arcActor.tell(CheckStoragePendingUTXOsMessage(triggerBlockHeight: kFixtureHeight));
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (arc.getTransactionCalls <= calls && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }

    List<String> failedRows() => [
          for (final c in walletManager.commands.whereType<UpdateTransactionStatusCommand>())
            if (c.newStatus == TransactionStatus.failed) c.txid,
        ];

    test('the payer\'s deferred payment fails (INPUT_SPENT) and its row fails', () async {
      await stuckFor(const Duration(hours: 2));
      await scan();
      expect(statuses(), contains('INPUT_SPENT/dataSource!'));
      final failure =
          walletManager.commands.whereType<RecordTransactionNetworkStatusCommand>().singleWhere((c) => c.networkStatus == 'INPUT_SPENT');
      expect(failure.txid, stuck);
      expect(failure.detail, contains(kFixtureTxid));
      expect(failedRows(), [stuck]);
      expect(walletManager.commands.whereType<VoidUnsettledTransactionCommand>(), isEmpty);
    });

    test('an explicit check of the payment answers INPUT_SPENT', () async {
      await stuckFor(const Duration(hours: 2));
      final result = await ask(CheckDeferredPaymentStatusMessage(walletId: _wallet, txid: stuck));
      expect(result.networkStatus, 'INPUT_SPENT');
      expect(result.competingTxids, [kFixtureTxid]);
    });

    test('on the payee\'s side the received transaction is voided', () async {
      await stuckFor(const Duration(hours: 2), deferred: false);
      await scan();
      final voided = walletManager.commands.whereType<VoidUnsettledTransactionCommand>().single;
      expect((voided.txid, voided.spentInput, voided.spentBy), (stuck, _inputKey, kFixtureTxid));
    });

    test('a transaction younger than the limit is not checked', () async {
      await stuckFor(const Duration(minutes: 5));
      await scan();
      expect(statuses(), isNot(contains('INPUT_SPENT/dataSource!')));
      expect(failedRows(), isEmpty);
    });

    test('a rival the source calls unconfirmed changes nothing (either may still be mined)', () async {
      await stuckFor(const Duration(hours: 2), rivalConfirmed: false);
      await scan();
      expect(statuses(), isNot(contains('INPUT_SPENT/dataSource!')));
      expect(failedRows(), isEmpty);
    });

    test('a rival whose proof the stored header contradicts changes nothing', () async {
      await stuckFor(const Duration(hours: 2), tamper: 0);
      await scan();
      expect(statuses(), isNot(contains('INPUT_SPENT/dataSource!')));
      expect(failedRows(), isEmpty);
    });
  });

  // A token the wallet holds can be spent without it (a Voucher NFT forced
  // back by its issuer, a listing bought): the wallet asks about what it
  // holds, output by output (CheckOutputSpendersMessage). ARCActor finds
  // and proves the spender and hands it back with its proof; the
  // coordinator receives it into the wallet (bead libspiffy-zyfr), so
  // nothing here reaches the wallet manager.
  group('outputs the wallet holds, spent by someone else', () {
    Future<OutputSpendersResult> checkSpenders(List<String> keys, {bool confirmed = true, int? tamper, bool lookup = true}) async {
      if (lookup) {
        final l = _LookupDataSource()..spenders['$_fundingTxid:0'] = OutputSpender(txid: kFixtureTxid, vin: 0, confirmed: confirmed);
        l.raw[kFixtureTxid] = kFixtureTxHex;
        l.proofs[kFixtureTxid] = MerkleProofData(
            txid: kFixtureTxid, blockHeight: kFixtureHeight, merkleRoot: '', index: kFixtureIndex,
            nodes: fixtureNodes(tamperLevel: tamper), format: 'tsc');
        dataSource = l;
      }
      await storage.storeBlockHeader(fixtureHeader(), kFixtureHeight);
      await storeUtxo(_inputKey, UTXOStatus.available);
      await spawnActor();
      final r = await arcActor.ask<OutputSpendersResult>(
          CheckOutputSpendersMessage(walletId: _wallet, utxoKeys: keys), const Duration(seconds: 10));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      return r;
    }

    test('a mined spender proven against the local headers comes back with its bytes and its proof as a BEEF', () async {
      final r = await checkSpenders([_inputKey, '${'0f' * 32}:3']);
      expect(r.success, isTrue);
      final s = r.spends.single;
      expect((s.utxoKey, s.spentBy, s.confirmed, s.proven, s.recorded), (_inputKey, kFixtureTxid, true, true, false));
      expect(s.spenderRawHex, kFixtureTxHex);
      final beef = BEEF.parse(Uint8List.fromList(hex.decode(s.spenderBeefHex!)));
      expect(hex.encode(beef.txs.single), kFixtureTxHex);
      expect(beef.carriesProofOf(kFixtureTxid), isTrue);
      expect(beef.bumps.single.toHex(), fixtureBumpHex());
      expect(walletManager.commands, isEmpty, reason: 'the coordinator receives the spender into the wallet');
    });

    test('an unconfirmed spender is a lead: reported, no proof, nothing sent', () async {
      final r = await checkSpenders([_inputKey], confirmed: false);
      expect((r.spends.single.confirmed, r.spends.single.proven), (false, false));
      expect(r.spends.single.spenderBeefHex, isNull);
      expect(walletManager.commands, isEmpty);
    });

    test('a spender whose proof the stored header contradicts is not proven', () async {
      final r = await checkSpenders([_inputKey], tamper: 0);
      expect(r.spends.single.proven, isFalse);
      expect(r.spends.single.spenderBeefHex, isNull);
      expect(walletManager.commands, isEmpty);
    });

    test('a data source that cannot look up spenders: refused, nothing sent', () async {
      final r = await checkSpenders([_inputKey], lookup: false);
      expect(r.success, isFalse);
      expect(r.error, contains('cannot look up'));
      expect(walletManager.commands, isEmpty);
    });
  });
}

/// Records every wallet command.
class _RecordingWalletManager extends Actor {
  final List<WalletCommand> commands = [];

  @override
  Future<void> onMessage(dynamic message) async {
    if (message is WalletCommandMessage) commands.add(message.command);
  }
}

class _FakeArc extends ArcService {
  _FakeArc() : super(baseUrl: 'fake://arc');

  final Map<String, ArcTransactionResponse> statuses = {};
  final List<String> submitted = [];
  FeeRate miningFee = const FeeRate(satoshis: 1, bytes: 1000);
  String submitStatus = 'SEEN_ON_NETWORK';
  List<String>? submitCompetingTxs;
  bool unreachable = false;
  int getTransactionCalls = 0;

  @override
  Future<ArcSubmitResponse> submitTransaction(String rawTx, {String? callbackUrl}) async {
    if (unreachable) throw ArcException('ARC unreachable');
    submitted.add(rawTx);
    return ArcSubmitResponse.fromJson(
        {'txid': 'x', 'txStatus': submitStatus, if (submitCompetingTxs != null) 'competingTxs': submitCompetingTxs});
  }

  @override
  Future<ArcPolicyResponse> getPolicy() async {
    if (unreachable) throw ArcException('ARC unreachable');
    return ArcPolicyResponse(
      maxScriptSize: 500000,
      maxTxSigopsCount: 4294967295,
      maxTxSize: 10000000,
      miningFee: miningFee,
      standardFormatSupported: true,
    );
  }

  @override
  Future<ArcTransactionResponse> getTransaction(String txid) async {
    getTransactionCalls++;
    if (unreachable) throw ArcException('ARC unreachable');
    final response = statuses[txid];
    if (response == null) throw ArcException('Failed to get transaction: {"status":404}', statusCode: 404);
    return response;
  }
}

class _FakeDataSource extends BlockchainDataSource {
  final Map<String, String> raw = {};
  final Map<String, MerkleProofData> proofs = {};
  final List<String> submitted = [];
  bool rejectSubmissions = false;

  @override
  String get networkType => 'test';

  @override
  Future<String> getRawTransaction(String txid) async {
    final hex = raw[txid];
    if (hex == null) throw DataSourceException('Transaction not found', txid: txid, notFound: true);
    return hex;
  }

  @override
  Future<MerkleProofData> getMerkleProof(String txid) async {
    final proof = proofs[txid];
    if (proof == null) throw DataSourceException('unconfirmed', txid: txid);
    return proof;
  }

  @override
  Future<String> submitTransaction(String rawTxHex) async {
    submitted.add(rawTxHex);
    if (rejectSubmissions) throw DataSourceException('RPC error in sendrawtransaction: txn-already-known');
    return 'ok';
  }

  @override
  Future<List<TransactionInfo>> getTransactionHistory(String address, {int? limit, int? offset}) async => const [];
  @override
  Future<List<UtxoInfo>> getUtxos(String address) async => const [];
  @override
  Future<List<AddressScriptInfo>> getAddressScripts(String address) async => const [];
  @override
  Future<List<TransactionInfo>> getScriptHistory(String scriptHash, {int? limit, int? offset}) async => const [];
}

class _LookupDataSource extends _FakeDataSource implements SpentOutputLookup {
  final Map<String, OutputSpender> spenders = {};

  @override
  Future<OutputSpender?> getOutputSpender(String txid, int vout) async => spenders['$txid:$vout'];
}
