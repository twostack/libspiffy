/// A wallet output spent by someone else, and what that spender pays the
/// wallet (bead libspiffy-zyfr).
///
/// A Listed NFT bought by a stranger: the purchase spends the token output
/// the wallet holds and pays the price to the listing's owner key, a key of
/// the selling wallet. `CheckForeignSpendsCommand` proves the purchase
/// against the local headers and receives it into the wallet as any mined
/// transaction of its: the token output is spent, the price is a UTXO,
/// available in the purchase's block, and the purchase is in the history.
///
/// Played here with two real testnet transactions: the wallet (kTestXpriv)
/// holds output 1 of the first; the second spends it and pays output 0 back
/// to the same key. A data source that knows who spent what names the
/// second as the spender and serves its bytes and its proof.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:dactor/dactor.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:isar_community/isar.dart';
import 'package:libspiffy/coordinator.dart' as coord;
import 'package:libspiffy/libspiffy.dart';
import 'package:test/test.dart';

import '../spv/testnet_proof_fixture.dart';
import 'isar_test_helper.dart';
import 'p2p_test_helpers.dart' show kTestRootAddress, kTestXpriv;
import 'receive_helpers.dart';

const _tokenKey = '$kFixtureTxid:1';

/// Knows that the second fixture transaction spent the first's output 1,
/// and serves its bytes and its proof. Nothing else is asked of it.
class _SpenderSource implements BlockchainDataSource, SpentOutputLookup {
  final spenders = <String, OutputSpender>{};
  var lookups = 0;

  @override
  String get networkType => 'test';

  @override
  Future<OutputSpender?> getOutputSpender(String txid, int vout) async {
    lookups++;
    return spenders['$txid:$vout'];
  }

  @override
  Future<String> getRawTransaction(String txid) async {
    if (txid == kFixture2Txid) return kFixture2TxHex;
    throw DataSourceException('Transaction not found', txid: txid, notFound: true);
  }

  @override
  Future<MerkleProofData> getMerkleProof(String txid) async {
    if (txid == kFixture2Txid) {
      return MerkleProofData(
          txid: txid,
          blockHeight: kFixture2Height,
          merkleRoot: '',
          index: kFixture2Index,
          nodes: kFixture2Nodes,
          format: 'tsc');
    }
    throw DataSourceException('unconfirmed', txid: txid);
  }

  @override
  Future<int> getCurrentBlockHeight() async => kFixture2Height + 10;

  @override
  Future<String> submitTransaction(String rawTxHex) async => throw UnsupportedError('nothing is broadcast');
  @override
  Future<List<TransactionInfo>> getTransactionHistory(String address, {int? limit, int? offset}) async => const [];
  @override
  Future<List<UtxoInfo>> getUtxos(String address) async => const [];
  @override
  Future<List<AddressScriptInfo>> getAddressScripts(String address) async => const [];
  @override
  Future<List<TransactionInfo>> getScriptHistory(String scriptHash, {int? limit, int? offset}) async => const [];
}

void main() {
  late Directory dir;
  late LocalActorSystem actors;
  late Isar isar;
  late LibSpiffyActorSystem spiffy;
  late IsarWalletStorage storage;
  late _SpenderSource source;
  late String walletId;

  final purchase = dartsv.Transaction.fromHex(kFixture2TxHex);
  final price = purchase.outputs[0].satoshis;

  setUpAll(ensureIsarInitialized);

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('foreign-spend-credit-');
    actors = LocalActorSystem(ActorSystemConfig());
    isar = await Isar.open(LibSpiffySchemas.allSchemas,
        directory: dir.path, name: 'foreign_spend_${DateTime.now().microsecondsSinceEpoch}');
    source = _SpenderSource();
    spiffy = LibSpiffyActorSystem();
    await spiffy.initialize(
      actorSystem: actors,
      isar: isar,
      dataDirectory: dir.path,
      blockchainDataSource: source,
      enableP2P: false,
    );
    storage = spiffy.walletStorage as IsarWalletStorage;
    await storage.storeBlockHeader(fixtureHeader(), kFixtureHeight);
    await storage.storeBlockHeader(fixture2Header(), kFixture2Height);

    walletId = 'seller-${DateTime.now().microsecondsSinceEpoch}';
    final created = spiffy.coordinatorEvents!
        .where((e) => e is coord.WalletCreatedEvent && e.walletId == walletId)
        .first
        .timeout(const Duration(seconds: 15));
    spiffy.coordinator.tell(coord.CreateWalletCommand(walletId: walletId, name: 'seller', xpriv: kTestXpriv));
    await created;

    // The wallet holds output 1 of the first fixture transaction, proven.
    final held = await receiveBeef(
        spiffy,
        walletId,
        hex.encode(BEEF.create(
          bumps: [fixtureBump()],
          txs: [Uint8List.fromList(hex.decode(kFixtureTxHex))],
          hasMerkle: [true],
          bumpIndex: [0],
        ).serialize()),
        kFixtureTxid);
    expect(held.success, isTrue, reason: held.error);
    final token = (await storage.getUTXOs(walletId)).singleWhere((u) => u.key == _tokenKey);
    expect(token.isAvailable, isTrue);
  });

  tearDown(() async {
    await spiffy.shutdown();
    await isar.close(deleteFromDisk: true);
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<coord.ForeignSpendsCheckedEvent> check(String requestId) async {
    final checked = spiffy.coordinatorEvents!
        .where((e) => e is coord.ForeignSpendsCheckedEvent && e.requestId == requestId)
        .cast<coord.ForeignSpendsCheckedEvent>()
        .first
        .timeout(const Duration(seconds: 60));
    spiffy.coordinator.tell(coord.CheckForeignSpendsCommand(walletId: walletId, utxoKeys: [_tokenKey], requestId: requestId));
    return checked;
  }

  Future<BigInt> spendable() async {
    var total = BigInt.zero;
    for (final u in await storage.getPaymentUTXOs(walletId)) {
      total += u.satoshis;
    }
    return total;
  }

  test('a proven foreign spender is recorded: the output it spends is spent, what it pays the wallet is available',
      () async {
    source.spenders[_tokenKey] = OutputSpender(txid: kFixture2Txid, vin: 0, confirmed: true);
    final before = await spendable();
    expect(before, BigInt.from(200000000));

    final event = await check('sale');
    expect(event.success, isTrue, reason: event.error);
    expect(event.checked, [_tokenKey]);
    expect(event.unchecked, isEmpty);
    final spend = event.spends.single;
    expect((spend.utxoKey, spend.spentBy, spend.confirmed, spend.proven), (_tokenKey, kFixture2Txid, true, true));
    expect(spend.recorded, isTrue, reason: spend.recordError);
    expect(spend.recordError, isNull);
    expect(spend.spenderRawHex, kFixture2TxHex);
    expect(BEEF.parse(Uint8List.fromList(hex.decode(spend.spenderBeefHex!))).carriesProofOf(kFixture2Txid), isTrue);

    // The read model shows it by the time the event is heard: no polling.
    final utxos = {for (final u in await storage.getUTXOs(walletId, includeSpent: true)) u.key: u};
    final token = utxos[_tokenKey]!;
    expect(token.status, UTXOStatus.spent);
    expect(token.spentInTxId, kFixture2Txid);

    final paid = utxos['$kFixture2Txid:0']!;
    expect(paid.status, UTXOStatus.available);
    expect(paid.satoshis, price);
    expect(paid.address, kTestRootAddress);
    expect(paid.blockHeight, kFixture2Height, reason: 'received in the block its proof names');
    expect(utxos.containsKey('$kFixture2Txid:1'), isFalse, reason: 'output 1 pays someone else');

    final row = await storage.getTransaction(kFixture2Txid, walletId: walletId);
    expect(row, isNotNull, reason: 'the purchase is in the wallet\'s history');
    expect(row!.blockHeight, kFixture2Height);
    expect(row.rawHex, kFixture2TxHex);

    expect(await spendable(), price, reason: 'the token output is gone and the price is spendable');
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('checked again, the spender the wallet already holds is recorded already: nothing is received twice',
      () async {
    source.spenders[_tokenKey] = OutputSpender(txid: kFixture2Txid, vin: 0, confirmed: true);
    final first = await check('sale-1');
    expect(first.spends.single.recorded, isTrue, reason: first.spends.single.recordError);
    final imports = <coord.TransactionImportedEvent>[];
    final listening = spiffy.coordinatorEvents!
        .where((e) => e is coord.TransactionImportedEvent && e.transactionId == kFixture2Txid)
        .cast<coord.TransactionImportedEvent>()
        .listen(imports.add);

    final again = await check('sale-2');
    final spend = again.spends.single;
    expect((spend.proven, spend.recorded, spend.recordError), (true, true, null));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await listening.cancel();
    expect(imports, isEmpty, reason: 'the second check sends nothing through the receive path');
    final utxos = await storage.getUTXOs(walletId, includeSpent: true);
    expect(utxos.where((u) => u.txid == kFixture2Txid).length, 1);
    expect(await spendable(), price);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('a spender the data source only claims is mined, with no proof to fetch, is a lead: nothing changes',
      () async {
    source.spenders[_tokenKey] = OutputSpender(txid: 'ab' * 32, vin: 0, confirmed: true);
    final event = await check('claim');
    expect(event.success, isTrue, reason: event.error);
    final spend = event.spends.single;
    expect((spend.confirmed, spend.proven, spend.recorded), (true, false, false));
    expect(spend.spenderBeefHex, isNull);
    final token = (await storage.getUTXOs(walletId)).singleWhere((u) => u.key == _tokenKey);
    expect(token.isAvailable, isTrue);
    expect(await spendable(), BigInt.from(200000000));
  }, timeout: const Timeout(Duration(minutes: 2)));
}
