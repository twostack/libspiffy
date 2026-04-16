import 'dart:async';
import 'dart:io';
import 'package:test/test.dart';
import 'package:dactor/dactor.dart';
import 'package:isar/isar.dart';
import 'package:libspiffy/libspiffy.dart';
import 'package:libspiffy/internals.dart';
import 'package:libspiffy/src/storage/isar_wallet_storage.dart';
import 'package:libspiffy/src/services/blockchain_data_source.dart';
import 'package:libspiffy/src/models/blockchain_data_models.dart';
import 'package:libspiffy/src/models/wallet_event.dart';
import 'package:spiffynode/spiffy_node.dart' as spiffynode;
import 'isar_test_helper.dart';

// =============================================================================
// TEST DATA — Real Testnet Fixtures (same as import_actor_test.dart)
// =============================================================================

/// WIF for m/0/0 derived from the standard test xpriv
/// Address: mqCnSf8i6kmaQaJ54HjQ8EUJnuK4AnCv12
const kTestWif = 'cVGBPvF5SgvcCqur3iEbPCjycgWkzN29r3RMdFPdWGxDGdTTkYJh';
const kTestAddress = 'mqCnSf8i6kmaQaJ54HjQ8EUJnuK4AnCv12';

/// TX1: pays 200,000,000 sats to kTestAddress at vout 1  (block 1239645)
const kTx1Hex = '020000000165b6c06790c23623c4988ee51b3f27c76bfb6a0c9e5bab3432968c51379af66a000000006b483045022100b735fb60adca4fa42e37746aa602c3206bf98572ae83e396da4fd11cb716b26d022017bf9955bd8fc4d60f2829236c7864d5b5540062c88113daef137c0ee441736c41210222824a8530bc570b7bae7c7600529b450a65eab1203c5f561d8082cd97b3dba1feffffff02872ec735150000001976a9149d02ce72bbdc1713d5537a0705d8ec7d9702c81088ac00c2eb0b000000001976a9146a418bf9e2e2b670e1aa7b7da59391e212b4ba1988ac5cea1200';
const kTx1Id = 'a05924fcc63712d3e4b94b0c88baad234c2c8ad3d369704f53765e21a53a2101';
const kTx1BlockHeight = 1239645;

/// TX2: spends from TX1, pays back to kTestAddress at vout 0  (block 1701169)
const kTx2Hex = '020000000101213aa5215e76534f7069d3d38a2c4c23adba880c4bb9e4d31237c6fc2459a0010000006b483045022100b17a54d3b7f232c4c375d6c656001cac54e674aa3bc8cab3eb176668fbf0a15c02207e35eed554edba90e030e46d90f8d9569a4d6a7139d55eafd9e875c9d3ec2c364121033a69d0acd6e9500844ca078fbc4d81b6c95d7967b3106e31618d5987633d41a9ffffffff02affeea0b000000001976a9146a418bf9e2e2b670e1aa7b7da59391e212b4ba1988ac50c30000000000001976a914c8e0448aa60d8335ef57c1d0e2bdec3aa15f257588ac00000000';
const kTx2Id = '05c4d800ac77703bb00e41d8bf9d006c0e52f8405ba92c4506b80ad8f5337ae1';
const kTx2BlockHeight = 1701169;

/// Expected balance after import:
/// TX1 vout 1 → 200,000,000 sats to our address (received)
/// TX2 spends TX1:vout1, TX2 vout 0 → 199,949,999 sats back to our address
/// So unspent UTXO = TX2:vout0 = 199,949,999 sats (fee = 50,001)
const kExpectedBalanceSats = 199949999;

// =============================================================================
// MOCK BLOCKCHAIN DATA SOURCE
// =============================================================================

Map<String, dynamic> _getTx1MerkleProof() => {
  "index": 2,
  "txOrId": kTx1Id,
  "target": "000000001539f91cede66262caa22d1b504d09aa1dc3221f7fac5b30c2f7d65d",
  "nodes": [
    "405649f55c4a98a3f83e6d780bb44297035d4a3652d9ddc9dc50799bed17b62b",
    "750e25837b6188f87387b1eb18604e9fe07aa32fb80221e7a1c7d7e04427c8e0",
    "3980d9a3572b903c74302a586c923ce0bf26d979a23290a28750cb2e1cc19199",
    "2b6da3206c7aed19f0bc6c68826f86638c1f9214a6b3eead3d7121381a82549d",
    "5d3e8be2af6e109196a14a81dc6f99e17d7420eddf1d31a1a50fb2ef6933e3a1",
    "c4f09f1a5fb1e66a95b66ca7502062292708597c7e15574fc6dd1f9bcc7d2f5a"
  ]
};

Map<String, dynamic> _getTx2MerkleProof() => {
  "index": 279,
  "txOrId": kTx2Id,
  "target": "00000000f7a0bacde7375dc096edf7e03a23535d7d6f1e4b02624087a1417206",
  "nodes": [
    "2d2711122c3d1822932db91aa9afa2128c9e26b5c4b8df7b9a955c48d0bfc785",
    "795b148effccae8eaaf41f09ed19124b38680cf2b89016dae850dc17a5966b7e",
    "957235d9bd6ce92c5676cfe4ec77a3c2d19910ced8bd4ebe7ffa5490ceade34f",
    "910c626fdf40242c134458696159f5176223f3b7f72a4ad74fefad65433b5433",
    "34a6ea9a52e82ca75cf496ae6255bca7b05f99e380904779684cc5f0f941688e",
    "3d706f13140a933e2ce72cacec0e0f89b6b4378907e3a39c8a22b2a2d2a6b1e7",
    "593d05f1d07fb22d7b93d9f1a1739f0827b4b6363e68f6c750e4b58206aa5790",
    "eced437fa3685318afe3f9c89c184b04f255ab3059335754acdaf9c3b0197158",
    "9d8b401b6fd46c8dae3fb5b3013a6b76d05333215691be9bbd386908b257061e"
  ]
};

class WifTestDataSource implements BlockchainDataSource {
  final Map<String, String> _rawTransactions = {};
  final Map<String, MerkleProofData> _merkleProofs = {};
  final Map<String, List<TransactionInfo>> _addressHistory = {};

  WifTestDataSource() {
    _rawTransactions[kTx1Id] = kTx1Hex;
    _rawTransactions[kTx2Id] = kTx2Hex;

    final tx1Proof = _getTx1MerkleProof();
    _merkleProofs[kTx1Id] = MerkleProofData(
      txid: kTx1Id,
      blockHeight: kTx1BlockHeight,
      merkleRoot: '4823b3e0a9801d019c49af6ecd923f5250cc828e7be4fb6b4c5afbb979e33b34',
      index: tx1Proof['index'] as int,
      nodes: (tx1Proof['nodes'] as List).cast<String>(),
    );

    final tx2Proof = _getTx2MerkleProof();
    _merkleProofs[kTx2Id] = MerkleProofData(
      txid: kTx2Id,
      blockHeight: kTx2BlockHeight,
      merkleRoot: '750cfb89611c186c935980567ad1a4b1cec0e033ba2373151a51a7e87b122612',
      index: tx2Proof['index'] as int,
      nodes: (tx2Proof['nodes'] as List).cast<String>(),
    );

    _addressHistory[kTestAddress] = [
      TransactionInfo(
        txid: kTx1Id,
        blockHeight: kTx1BlockHeight,
        blockHash: '000000001539f91cede66262caa22d1b504d09aa1dc3221f7fac5b30c2f7d65d',
        blockIndex: 2,
      ),
      TransactionInfo(
        txid: kTx2Id,
        blockHeight: kTx2BlockHeight,
        blockHash: '00000000f7a0bacde7375dc096edf7e03a23535d7d6f1e4b02624087a1417206',
        blockIndex: 279,
      ),
    ];
  }

  @override
  String get networkType => 'test';

  @override
  Future<String> getRawTransaction(String txid) async {
    await Future.delayed(Duration(milliseconds: 10));
    if (!_rawTransactions.containsKey(txid)) {
      throw DataSourceException('Transaction not found: $txid', txid: txid);
    }
    return _rawTransactions[txid]!;
  }

  @override
  Future<MerkleProofData> getMerkleProof(String txid) async {
    await Future.delayed(Duration(milliseconds: 10));
    if (!_merkleProofs.containsKey(txid)) {
      throw DataSourceException('Merkle proof not found: $txid', txid: txid);
    }
    return _merkleProofs[txid]!;
  }

  @override
  Future<List<TransactionInfo>> getTransactionHistory(
    String address, {
    int? limit,
    int? offset,
  }) async {
    await Future.delayed(Duration(milliseconds: 10));
    if (!_addressHistory.containsKey(address)) return [];
    var history = _addressHistory[address]!;
    if (offset != null && offset > 0) history = history.skip(offset).toList();
    if (limit != null && limit > 0) history = history.take(limit).toList();
    return history;
  }

  @override
  Future<List<UtxoInfo>> getUtxos(String address) async => [];

  @override
  Future<int> getCurrentBlockHeight() async => 1701454;

  @override
  Future<String> submitTransaction(String rawHex) async {
    throw UnimplementedError();
  }

  @override
  Future<List<AddressScriptInfo>> getAddressScripts(String address) {
    throw UnimplementedError();
  }

  @override
  Future<List<TransactionInfo>> getScriptHistory(String scriptHash, {int? limit, int? offset}) {
    throw UnimplementedError();
  }
}

// =============================================================================
// TEST SETUP
// =============================================================================

Future<void> _setupBlockHeaders(IsarWalletStorage storage) async {
  final header1 = spiffynode.BlockHeader(
    version: 536870912,
    prevBlock: spiffynode.Hash.fromHex('0000000070ad42dbfbc9860b1c6d6f636515834a4407e86cdead84d158592bd3'),
    merkleRoot: spiffynode.Hash.fromHex('4823b3e0a9801d019c49af6ecd923f5250cc828e7be4fb6b4c5afbb979e33b34'),
    timestamp: DateTime.fromMillisecondsSinceEpoch(1528803530 * 1000),
    bits: 0x1d00ffff,
    nonce: 2121538711,
  );
  await storage.storeBlockHeader(header1, kTx1BlockHeight);

  final header2 = spiffynode.BlockHeader(
    version: 536870912,
    prevBlock: spiffynode.Hash.fromHex('000000003eb61d855e28f2d1f7913f64988c6c3bd89e00608bc7ac9b175922c3'),
    merkleRoot: spiffynode.Hash.fromHex('750cfb89611c186c935980567ad1a4b1cec0e033ba2373151a51a7e87b122612'),
    timestamp: DateTime.fromMillisecondsSinceEpoch(1761722800 * 1000),
    bits: 0x1d00ffff,
    nonce: 1259571457,
  );
  await storage.storeBlockHeader(header2, kTx2BlockHeight);
}

// =============================================================================
// TESTS
// =============================================================================

void main() {
  group('WIF Import — Balance E2E', () {
    test('imported WIF wallet has correct balance after import completes', () async {
      await ensureIsarInitialized();

      final testDir = Directory.systemTemp.createTempSync('wif-import-balance-');
      final actorSystem = LocalActorSystem(ActorSystemConfig());

      final isar = await Isar.open(
        LibSpiffySchemas.allSchemas,
        directory: testDir.path,
        name: 'test_wif_import_${DateTime.now().microsecondsSinceEpoch}',
      );

      final dataSource = WifTestDataSource();
      final libspiffy = LibSpiffyActorSystem();
      await libspiffy.initialize(
        actorSystem: actorSystem,
        isar: isar,
        dataDirectory: testDir.path,
        blockchainDataSource: dataSource,
        enableP2P: false,
      );

      final storage = libspiffy.walletStorage as IsarWalletStorage;
      await _setupBlockHeaders(storage);

      final walletId = 'wif-test-${DateTime.now().millisecondsSinceEpoch}';

      try {
        // Wait for import completed event
        final completer = Completer<WalletImportCompletedEvent>();
        final events = <WalletEvent>[];

        libspiffy.subscribeToWalletEvents(walletId).listen((event) {
          events.add(event);
          print('📢 ${event.runtimeType}');
          if (event is WalletImportCompletedEvent && !completer.isCompleted) {
            completer.complete(event);
          }
        });

        // Trigger WIF import
        print('Starting WIF import for $kTestAddress ...');
        libspiffy.importWalletFromWif(
          walletId: walletId,
          wif: kTestWif,
          walletName: 'WIF Balance Test',
          networkType: 'test',
        );

        // Wait for completion
        final completed = await completer.future.timeout(
          const Duration(seconds: 30),
          onTimeout: () => throw TimeoutException('Import did not complete within 30s'),
        );
        print('Import completed: ${completed.totalAddresses} addr, ${completed.totalTransactions} tx');

        // Short settle for projections
        await Future.delayed(const Duration(seconds: 2));

        // --- ASSERTIONS ---

        // 1. Wallet exists
        final wallet = await storage.getWallet(walletId);
        expect(wallet, isNotNull, reason: 'Wallet should exist after import');

        // 2. Address registered
        final addresses = await storage.getWalletAddresses(walletId);
        expect(addresses, contains(kTestAddress),
          reason: 'WIF address should be registered');

        // 3. Transactions imported
        final txHistory = await storage.getTransactionHistory(walletId);
        print('Transactions: ${txHistory.length}');
        for (final tx in txHistory) {
          print('  ${tx.txid} (block ${tx.blockHeight})');
        }
        expect(txHistory.any((tx) => tx.txid == kTx1Id), isTrue,
          reason: 'TX1 should be imported');
        expect(txHistory.any((tx) => tx.txid == kTx2Id), isTrue,
          reason: 'TX2 should be imported');

        // 4. UTXOs — TX1:vout1 should be spent, TX2:vout0 should be unspent
        final allUtxos = await storage.getUTXOs(walletId, includeSpent: true);
        print('All UTXOs (including spent):');
        for (final utxo in allUtxos) {
          print('  ${utxo.txid}:${utxo.vout} — ${utxo.satoshis} sats (${utxo.status})');
        }

        final availableUtxos = await storage.getUTXOs(walletId);
        print('Available UTXOs:');
        for (final utxo in availableUtxos) {
          print('  ${utxo.txid}:${utxo.vout} — ${utxo.satoshis} sats');
        }
        expect(availableUtxos.length, equals(1),
          reason: 'Should have exactly 1 unspent UTXO (TX2:vout0)');
        expect(availableUtxos.first.txid, equals(kTx2Id));
        expect(availableUtxos.first.vout, equals(0));

        // 5. Balance (direct UTXO sum)
        final balance = await storage.getBalance(walletId);
        print('Balance (from UTXOs): $balance sats');
        expect(balance, equals(BigInt.from(kExpectedBalanceSats)),
          reason: 'Balance should equal $kExpectedBalanceSats sats (TX2:vout0)');

        // 6. WalletMetadataEntity balance — this is what the UI actually reads
        final walletMeta = await storage.getWallet(walletId);
        final confirmedStr = walletMeta!['confirmedBalance'] as String;
        final unconfirmedStr = walletMeta['unconfirmedBalance'] as String;
        final metaMap = walletMeta['metadata'] as Map<String, dynamic>?;
        print('WalletMetadataEntity confirmedBalance: $confirmedStr');
        print('WalletMetadataEntity unconfirmedBalance: $unconfirmedStr');
        print('WalletMetadataEntity metadata: $metaMap');

        final metaTotal = BigInt.parse(confirmedStr) + BigInt.parse(unconfirmedStr);
        print('WalletMetadataEntity total: $metaTotal sats');
        expect(metaTotal, equals(BigInt.from(kExpectedBalanceSats)),
          reason: 'WalletMetadataEntity balance should match UTXO balance');
      } finally {
        await libspiffy.shutdown();
        await isar.close(deleteFromDisk: true);
        testDir.deleteSync(recursive: true);
      }
    });
  });
}
