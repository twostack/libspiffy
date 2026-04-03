import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:test/test.dart';
import 'package:dactor/dactor.dart';
import 'package:isar/isar.dart';
import 'package:libspiffy/libspiffy.dart';
import 'package:libspiffy/coordinator.dart' as coord;
import 'package:libspiffy/src/storage/isar_wallet_storage.dart';
import 'package:libspiffy/src/services/blockchain_data_source.dart';
import 'package:libspiffy/src/models/blockchain_data_models.dart';
import 'package:libspiffy/src/utils/crypto_utils.dart';
import 'package:spiffynode/spiffy_node.dart' as spiffynode;

import 'isar_test_helper.dart';

// =============================================================================
// Real testnet fixtures (same as import_actor_test.dart)
// =============================================================================

const kTestXpriv =
    'tprv8ZgxMBicQKsPeMiDjtXBGAyFY1wEMGgomjwf54ZmiZfKTNYvVdBa6GqWUwnvtHm6NKVkQkhCKxaobd9JPxNEXgDfVgJ5RNHJ3ivogSG3V1R';
const kTestRootAddress = 'mqCnSf8i6kmaQaJ54HjQ8EUJnuK4AnCv12';

const kTx1Hex =
    '020000000165b6c06790c23623c4988ee51b3f27c76bfb6a0c9e5bab3432968c51379af66a000000006b483045022100b735fb60adca4fa42e37746aa602c3206bf98572ae83e396da4fd11cb716b26d022017bf9955bd8fc4d60f2829236c7864d5b5540062c88113daef137c0ee441736c41210222824a8530bc570b7bae7c7600529b450a65eab1203c5f561d8082cd97b3dba1feffffff02872ec735150000001976a9149d02ce72bbdc1713d5537a0705d8ec7d9702c81088ac00c2eb0b000000001976a9146a418bf9e2e2b670e1aa7b7da59391e212b4ba1988ac5cea1200';
const kTx1Id =
    'a05924fcc63712d3e4b94b0c88baad234c2c8ad3d369704f53765e21a53a2101';
const kTx1BlockHeight = 1239645;

Map<String, dynamic> _getTx1MerkleProof() => {
      'index': 2,
      'txOrId': kTx1Id,
      'target':
          '000000001539f91cede66262caa22d1b504d09aa1dc3221f7fac5b30c2f7d65d',
      'nodes': [
        '405649f55c4a98a3f83e6d780bb44297035d4a3652d9ddc9dc50799bed17b62b',
        '750e25837b6188f87387b1eb18604e9fe07aa32fb80221e7a1c7d7e04427c8e0',
        '3980d9a3572b903c74302a586c923ce0bf26d979a23290a28750cb2e1cc19199',
        '2b6da3206c7aed19f0bc6c68826f86638c1f9214a6b3eead3d7121381a82549d',
        '5d3e8be2af6e109196a14a81dc6f99e17d7420eddf1d31a1a50fb2ef6933e3a1',
        'c4f09f1a5fb1e66a95b66ca7502062292708597c7e15574fc6dd1f9bcc7d2f5a',
      ],
    };

// =============================================================================
// Minimal mock data source
// =============================================================================

class _MinimalDataSource implements BlockchainDataSource {
  @override
  String get networkType => 'test';

  @override
  Future<String> getRawTransaction(String txid) async =>
      throw DataSourceException('Not needed', txid: txid);

  @override
  Future<MerkleProofData> getMerkleProof(String txid) async =>
      throw DataSourceException('Not needed', txid: txid);

  @override
  Future<List<TransactionInfo>> getTransactionHistory(String address,
          {int? limit, int? offset}) async =>
      [];

  @override
  Future<List<UtxoInfo>> getUtxos(String address) async => [];

  @override
  Future<List<AddressScriptInfo>> getAddressScripts(String address) async => [];

  @override
  Future<List<TransactionInfo>> getScriptHistory(String scriptHash,
          {int? limit, int? offset}) async =>
      [];

  @override
  Future<int> getCurrentBlockHeight() async => kTx1BlockHeight + 100;

  @override
  Future<String> submitTransaction(String rawTxHex) async =>
      throw UnsupportedError('Not needed');
}

// =============================================================================
// Test infrastructure
// =============================================================================

Future<void> _storeBlockHeader(IsarWalletStorage storage) async {
  final header = spiffynode.BlockHeader(
    version: 536870912,
    prevBlock: spiffynode.Hash.fromHex(
        '0000000070ad42dbfbc9860b1c6d6f636515834a4407e86cdead84d158592bd3'),
    merkleRoot: spiffynode.Hash.fromHex(
        '4823b3e0a9801d019c49af6ecd923f5250cc828e7be4fb6b4c5afbb979e33b34'),
    timestamp: DateTime.fromMillisecondsSinceEpoch(1528803530 * 1000),
    bits: 0x1d00ffff,
    nonce: 2121538711,
  );
  await storage.storeBlockHeader(header, kTx1BlockHeight);
}

BEEF _createBeef() {
  final txBytes = Uint8List.fromList(hex.decode(kTx1Hex));
  final bump =
      CryptoUtils.createBumpFromTscProof(_getTx1MerkleProof(), kTx1BlockHeight);
  return BEEF.create(
    bumps: [bump],
    txs: [txBytes],
    hasMerkle: [true],
    bumpIndex: [0],
  );
}

// =============================================================================
// Tests
// =============================================================================

void main() {
  late Directory testDir;
  late LocalActorSystem actorSystem;
  late Isar isar;
  late LibSpiffyActorSystem libspiffy;
  late IsarWalletStorage storage;

  setUpAll(() async {
    await ensureIsarInitialized();
  });

  setUp(() async {
    testDir = Directory.systemTemp.createTempSync('import-tx-cmd-test-');
    actorSystem = LocalActorSystem(ActorSystemConfig());

    isar = await Isar.open(
      LibSpiffySchemas.allSchemas,
      directory: testDir.path,
      name: 'test_import_tx_${DateTime.now().millisecondsSinceEpoch}',
    );

    libspiffy = LibSpiffyActorSystem();
    await libspiffy.initialize(
      actorSystem: actorSystem,
      isar: isar,
      dataDirectory: testDir.path,
      blockchainDataSource: _MinimalDataSource(),
      enableP2P: false,
    );

    storage = libspiffy.walletStorage as IsarWalletStorage;
    await _storeBlockHeader(storage);
  });

  tearDown(() async {
    await libspiffy.shutdown();
    await isar.close(deleteFromDisk: true);
    try {
      testDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('ImportTransactionCommand', () {
    test('imports BEEF and creates spendable UTXO in read model', () async {
      final walletId = 'wallet-${DateTime.now().millisecondsSinceEpoch}';

      // Step 1: Create wallet from xpriv (so the root address is recognized)
      libspiffy.coordinator.tell(coord.CreateWalletCommand(
        walletId: walletId,
        name: 'Import Test Wallet',
        xpriv: kTestXpriv,
      ));

      await _waitForEvent<coord.WalletCreatedEvent>(
        libspiffy.coordinatorEvents!,
        where: (e) => e.walletId == walletId,
      );
      print('✓ Wallet created: $walletId');

      // Step 2: Import the testnet TX via BEEF
      final beef = _createBeef();
      libspiffy.coordinator.tell(coord.ImportTransactionCommand(
        walletId: walletId,
        transactionId: kTx1Id,
        beef: beef.serialize().toList(),
        fromCounterparty: 'test',
      ));

      // Step 3: Wait for TransactionImportedEvent
      final importEvent = await _waitForEvent<coord.TransactionImportedEvent>(
        libspiffy.coordinatorEvents!,
        where: (e) => e.transactionId == kTx1Id,
      );

      expect(importEvent.success, isTrue,
          reason: 'Import should succeed: ${importEvent.error}');
      expect(importEvent.transactionId, equals(kTx1Id));
      print('✓ TransactionImportedEvent: success=${importEvent.success}');
      print('  utxosCreated: ${importEvent.utxosCreated}');
      print('  totalValueReceived: ${importEvent.totalValueReceived}');

      // Step 4: Verify the UTXO exists in the read model
      // First check all UTXOs (any status) to understand what was persisted
      final allUtxos = await _retryUntil(
        () => storage.getUTXOs(walletId),
        (result) => result.isNotEmpty,
        timeout: Duration(seconds: 5),
        description: 'getUTXOs returns non-empty',
      );
      print('  All UTXOs: ${allUtxos.length}');
      for (final u in allUtxos) {
        print('    ${u.txid}:${u.vout} status=${u.status} sats=${u.satoshis} addr=${u.address} pluginMeta=${u.pluginMetadata}');
      }

      // Then check payment UTXOs (available, non-plugin)
      final utxos = await storage.getPaymentUTXOs(walletId);
      print('  Payment UTXOs: ${utxos.length}');

      expect(utxos, isNotEmpty,
          reason: 'Imported TX should create at least one UTXO in the read model');

      // Find the specific UTXO at vout=1 (200M sats to root address)
      final fundingUtxo =
          utxos.where((u) => u.txid == kTx1Id && u.vout == 1).toList();
      expect(fundingUtxo, isNotEmpty,
          reason: 'UTXO at $kTx1Id:1 should exist');
      expect(fundingUtxo.first.satoshis, equals(BigInt.from(200000000)),
          reason: 'UTXO should have 200M sats');
      expect(fundingUtxo.first.address, equals(kTestRootAddress),
          reason: 'UTXO should belong to root address');

      print('✓ UTXO verified in read model:');
      print('  txid: ${fundingUtxo.first.txid}');
      print('  vout: ${fundingUtxo.first.vout}');
      print('  sats: ${fundingUtxo.first.satoshis}');
      print('  address: ${fundingUtxo.first.address}');
    }, timeout: Timeout(Duration(minutes: 1)));
  });
}

// =============================================================================
// Test helpers
// =============================================================================

Future<T> _waitForEvent<T extends coord.CoordinatorEvent>(
  Stream<coord.CoordinatorEvent> events, {
  bool Function(T)? where,
  Duration timeout = const Duration(seconds: 15),
}) async {
  return events
      .where((e) => e is T && (where == null || where(e as T)))
      .cast<T>()
      .first
      .timeout(timeout);
}

Future<T> _retryUntil<T>(
  Future<T> Function() action,
  bool Function(T) predicate, {
  Duration timeout = const Duration(seconds: 5),
  Duration interval = const Duration(milliseconds: 200),
  String description = 'condition',
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final result = await action();
    if (predicate(result)) return result;
    await Future.delayed(interval);
  }
  final result = await action();
  if (!predicate(result)) {
    throw TimeoutException('Timed out waiting for: $description');
  }
  return result;
}
