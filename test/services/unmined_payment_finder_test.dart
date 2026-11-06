/// spiffyvault-bld: a named-address scan finds payments still in the
/// mempool and hands each to the wallet as a BEEF, back to mined ancestors.
library;

import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:libspiffy/src/models/bitcoin_transaction.dart';
import 'package:libspiffy/src/models/blockchain_data_models.dart';
import 'package:libspiffy/src/services/blockchain_data_source.dart';
import 'package:libspiffy/src/services/transaction_import_service.dart';
import 'package:libspiffy/src/services/unmined_payment_finder.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';
import 'package:libspiffy/src/utils/beef.dart';
import 'package:test/test.dart';

import '../spv/testnet_proof_fixture.dart';

const _wallet = 'w';
const _address = 'mrootaddress0000000000000000000000';

/// A transaction spending [inputs] (`txid:vout`), unsigned: the finder reads
/// it, the wallet's own check is not run here.
String _spending(List<String> inputs, {int lockTime = 0, int sequence = 0xffffffff}) {
  final tx = dartsv.Transaction();
  for (final key in inputs) {
    final parts = key.split(':');
    tx.addInput(dartsv.TransactionInput(parts[0], int.parse(parts[1]), sequence));
  }
  tx.addOutput(dartsv.TransactionOutput(
      BigInt.from(1000), dartsv.SVScript.fromHex('76a9149d02ce72bbdc1713d5537a0705d8ec7d9702c81088ac')));
  tx.nLockTime = lockTime;
  return tx.serialize();
}

String _id(String raw) => dartsv.Transaction.fromHex(raw).id;

class _Source extends BlockchainDataSource {
  final Map<String, String> raw = {kFixtureTxid: kFixtureTxHex};
  final Map<String, MerkleProofData> proofs = {
    kFixtureTxid: MerkleProofData(
        txid: kFixtureTxid,
        blockHeight: kFixtureHeight,
        merkleRoot: '',
        index: kFixtureIndex,
        nodes: fixtureNodes(),
        format: 'tsc'),
  };
  final List<UtxoInfo> utxos = [];

  @override
  String get networkType => 'test';

  @override
  Future<String> getRawTransaction(String txid) async =>
      raw[txid] ?? (throw DataSourceException('not found', txid: txid, notFound: true));

  @override
  Future<MerkleProofData> getMerkleProof(String txid) async =>
      proofs[txid] ?? (throw DataSourceException('unconfirmed', txid: txid));

  @override
  Future<List<UtxoInfo>> getUtxos(String address) async => utxos.where((u) => u.address == address).toList();

  @override
  Future<List<TransactionInfo>> getTransactionHistory(String address, {int? limit, int? offset}) async => const [];
  @override
  Future<List<AddressScriptInfo>> getAddressScripts(String address) async => const [];
  @override
  Future<List<TransactionInfo>> getScriptHistory(String scriptHash, {int? limit, int? offset}) async => const [];
}

void main() {
  late _Source source;
  late InMemoryWalletStorage storage;
  late UnminedPaymentFinder finder;

  setUp(() async {
    source = _Source();
    storage = InMemoryWalletStorage();
    await storage.storeWallet(_wallet, 'W');
    await storage.storeBlockHeader(fixtureHeader(), kFixtureHeight);
    finder = UnminedPaymentFinder(
      dataSource: source,
      importService: TransactionImportService(dataSource: source, headerAtHeight: storage.getBlockHeaderByHeight),
      storage: storage,
    );
  });

  String unmined(String raw, {bool toWallet = true}) {
    final txid = _id(raw);
    source.raw[txid] = raw;
    if (toWallet) source.utxos.add(UtxoInfo(txid: txid, vout: 0, value: 1000, address: _address));
    return txid;
  }

  BEEF beefOf(UnminedPayment p) => BEEF.parse(Uint8List.fromList(hex.decode(p.beefHex)));
  List<String> txidsOf(BEEF beef) => [for (final tx in beef.txs) hex.encode(beef.calculateTxid(tx))];

  test('a payment spending a mined coin: the parent with its proof, then the payment', () async {
    final payment = unmined(_spending(['$kFixtureTxid:0']));

    final found = await finder.find(_wallet, [_address]);

    expect(found.single.txid, payment);
    final beef = beefOf(found.single);
    expect(txidsOf(beef), [kFixtureTxid, payment]);
    expect(beef.hasMerkle, [true, false]);
    expect(beef.bumps, hasLength(1));
  });

  test('an unmined parent comes before the payment, back to the mined one', () async {
    final parent = unmined(_spending(['$kFixtureTxid:1']), toWallet: false);
    final payment = unmined(_spending(['$parent:0']));

    final beef = beefOf((await finder.find(_wallet, [_address])).single);

    expect(txidsOf(beef), [kFixtureTxid, parent, payment]);
    expect(beef.hasMerkle, [true, false, false]);
  });

  test('a mined coin of the address is no unmined payment', () async {
    source.utxos.add(UtxoInfo(txid: kFixtureTxid, vout: 0, value: 1000, height: kFixtureHeight, address: _address));
    expect(await finder.find(_wallet, [_address]), isEmpty);
  });

  test('a payment the wallet holds already is not offered again', () async {
    final raw = _spending(['$kFixtureTxid:0']);
    unmined(raw);
    await storage.storeTransaction(
        _wallet,
        BitcoinTransaction(
          walletId: _wallet,
          txid: _id(raw),
          rawHex: raw,
          status: TransactionStatus.pending,
          inputValue: BigInt.zero,
          outputValue: BigInt.zero,
          fee: BigInt.zero,
          receivingAddresses: const [],
          sendingAddresses: const [],
          netAmount: BigInt.from(1000),
          createdAt: DateTime.utc(2026),
          updatedAt: DateTime.utc(2026),
        ));
    expect(await finder.find(_wallet, [_address]), isEmpty);
  });

  test('a payment whose lock time is still to come is not taken', () async {
    unmined(_spending(['$kFixtureTxid:0'], lockTime: kFixtureHeight + 10, sequence: 0xfffffffe));
    expect(await finder.find(_wallet, [_address]), isEmpty);
  });

  test('a lock time already past (as wallets set it) is no obstacle', () async {
    unmined(_spending(['$kFixtureTxid:0'], lockTime: kFixtureHeight - 1, sequence: 0xfffffffe));
    expect(await finder.find(_wallet, [_address]), hasLength(1));
  });

  test('a payment whose parent the source cannot deliver is left for a later scan', () async {
    unmined(_spending(['${'ee' * 32}:0']));
    expect(await finder.find(_wallet, [_address]), isEmpty);
  });
}
