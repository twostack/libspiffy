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
import 'package:libspiffy/src/actors/arc_actor.dart';
import 'package:libspiffy/src/actors/wallet_messages.dart';
import 'package:libspiffy/src/core/wallet_commands.dart';
import 'package:libspiffy/src/models/bitcoin_transaction.dart';
import 'package:libspiffy/src/models/bitcoin_utxo.dart';
import 'package:libspiffy/src/models/blockchain_data_models.dart';
import 'package:libspiffy/src/models/deferred_payment.dart';
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

  List<String> spends() =>
      [for (final c in walletManager.commands.whereType<SpendUTXOCommand>()) '${c.utxoKey}>${c.spendingTxId}'];
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
      expect(spends(), ['$_inputKey>$kFixtureTxid']);
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
      expect(spends(), ['$_inputKey>$kFixtureTxid']);
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
        expect(spends(), isEmpty);
      });
    }

    test('404: NOT_FOUND recorded, nothing spent', () async {
      await handedOver();
      await spawnActor();

      final result = await check();

      expect(result.success, isTrue);
      expect(result.networkStatus, DeferredNetworkStatus.notFound);
      expect(statuses(), ['NOT_FOUND/arc!']);
      expect(spends(), isEmpty);
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
      expect(spends(), isEmpty);
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
      expect(spends(), isEmpty);
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
      expect(spends(), isEmpty);
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
      expect(spends(), ['$_inputKey>$kFixtureTxid']);
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
      expect(spends(), ['$_inputKey>$kFixtureTxid']);
    });

    test('ARC does not know it, then the data source does (arcThenDataSource)', () async {
      await handedOver();
      dataSource.raw[kFixtureTxid] = kFixtureTxHex;
      await spawnActor();

      final result = await check(via: DeferredPaymentNetworkSource.arcThenDataSource);

      expect(result.networkStatus, 'SEEN_ON_NETWORK');
      expect(result.source, 'dataSource');
      expect(statuses(), ['NOT_FOUND/arc!', 'SEEN_ON_NETWORK/dataSource!']);
      expect(spends(), ['$_inputKey>$kFixtureTxid']);
    });

    test('a data source returning another transaction for the txid is not believed', () async {
      await handedOver();
      dataSource.raw[kFixtureTxid] = kFixture2TxHex;
      await spawnActor();

      final result = await check(via: DeferredPaymentNetworkSource.dataSource);

      expect(result.success, isFalse);
      expect(spends(), isEmpty);
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
      expect(spends(), ['$kFixtureTxid:1>$kFixture2Txid'], reason: 'spent once');
      expect(statuses(), ['SEEN_ON_NETWORK/arc!', 'SEEN_ON_NETWORK/arc!']);
    });

    test('ARC answers REJECTED: recorded for the wallet to fail the payment, nothing spent', () async {
      final beefHex = await beefWithUnconfirmedParent();
      arc.submitStatus = 'REJECTED';
      await spawnActor();

      final result = await ask(broadcast(beefHex));

      expect(result.networkStatus, 'REJECTED');
      expect(statuses(), ['REJECTED/arc!']);
      expect(spends(), isEmpty);
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
      expect(spends(), isEmpty);
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
      expect(spends(), ['$kFixtureTxid:1>$kFixture2Txid']);
      expect(arc.submitted, isEmpty);
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
