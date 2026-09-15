/// Audit 2026-09-14 SPV-15 (bead libspiffy-780): repeated hashing and parsing,
/// and repeated lookups, on the BEEF and header-chain hot paths.
///
/// The work tests observe work done (hash calls, storage reads), never time.
/// The characterization tests pin the results on real fixtures (txids, BEEF
/// round-trip bytes, lookups, heights, tips, reorg outcomes) so the
/// optimisations are shown not to change them.
library;

import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart' show sha256;
import 'package:libspiffy/src/spv/block_header_chain.dart';
import 'package:libspiffy/src/spv/merkle.dart' as merkle;
import 'package:libspiffy/src/spv/network_params.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';
import 'package:libspiffy/src/utils/beef.dart';
import 'package:libspiffy/src/utils/bump.dart';
import 'package:spiffynode/spiffy_node.dart';
import 'package:test/test.dart';

import 'regtest_chain_builder.dart';
import 'testnet_proof_fixture.dart';

/// Real BEEF from the Go SDK test vectors (two transactions, one BUMP).
const _goSdkBeefHex =
    '0100beef01fe636d0c0007021400fe507c0c7aa754cef1f7889d5fd395cf1f785dd7de98eed895dbedfe4e5bc70d1502ac4e164f5bc16746bb0868404292ac8318bbac3800e4aad13a014da427adce3e010b00bc4ff395efd11719b277694cface5aa50d085a0bb81f613f70313acd28cf4557010400574b2d9142b8d28b61d88e3b2c3f44d858411356b49a28a4643b6d1a6a092a5201030051a05fc84d531b5d250c23f4f886f6812f9fe3f402d61607f977b4ecd2701c19010000fd781529d58fc2523cf396a7f25440b409857e7e221766c57214b1d38c7b481f01010062f542f45ea3660f86c013ced80534cb5fd4c19d66c56e7e8c5d4bf2d40acc5e010100b121e91836fd7cd5102b654e9f72f3cf6fdbfd0b161c53a9c54b12c841126331020100000001cd4e4cac3c7b56920d1e7655e7e260d31f29d9a388d04910f1bbd72304a79029010000006b483045022100e75279a205a547c445719420aa3138bf14743e3f42618e5f86a19bde14bb95f7022064777d34776b05d816daf1699493fcdf2ef5a5ab1ad710d9c97bfb5b8f7cef3641210263e2dee22b1ddc5e11f6fab8bcd2378bdd19580d640501ea956ec0e786f93e76ffffffff013e660000000000001976a9146bfd5c7fbe21529d45803dbcf0c87dd3c71efbc288ac0000000001000100000001ac4e164f5bc16746bb0868404292ac8318bbac3800e4aad13a014da427adce3e000000006a47304402203a61a2e931612b4bda08d541cfb980885173b8dcf64a3471238ae7abcd368d6402204cbf24f04b9aa2256d8901f0ed97866603d2be8324c2bfb7a37bf8fc90edd5b441210263e2dee22b1ddc5e11f6fab8bcd2378bdd19580d640501ea956ec0e786f93e76ffffffff013c660000000000001976a9146bfd5c7fbe21529d45803dbcf0c87dd3c71efbc288ac0000000000';

/// The testnet fixture transaction (proven) and an unproven child.
const _testnetBeefHex =
    '0100beef01fe5dea12000602020201213aa5215e76534f7069d3d38a2c4c23adba880c4bb9e4d31237c6fc2459a003002bb617ed9b7950dcc9ddd952364a5d039742b40b786d3ef8a3984a5cf5495640010000e0c82744e0d7c7a1e72102b82fa37ae09f4e6018ebb18773f888617b83250e750101009991c11c2ecb5087a29032a279d926bfe03c926c582a30743c902b57a3d980390101009d54821a3821713dadeeb3a614921f8c63866f82686cbcf019ed7a6c20a36d2b010100a1e33369efb20fa5a1311ddfed20747de1996fdc814aa19691106eafe28b3e5d0101005a2f7dcc9b1fddc64f57157e7c59082729622050a76cb6956ae6b15f1a9ff0c402020000000165b6c06790c23623c4988ee51b3f27c76bfb6a0c9e5bab3432968c51379af66a000000006b483045022100b735fb60adca4fa42e37746aa602c3206bf98572ae83e396da4fd11cb716b26d022017bf9955bd8fc4d60f2829236c7864d5b5540062c88113daef137c0ee441736c41210222824a8530bc570b7bae7c7600529b450a65eab1203c5f561d8082cd97b3dba1feffffff02872ec735150000001976a9149d02ce72bbdc1713d5537a0705d8ec7d9702c81088ac00c2eb0b000000001976a9146a418bf9e2e2b670e1aa7b7da59391e212b4ba1988ac5cea12000100020000000101213aa5215e76534f7069d3d38a2c4c23adba880c4bb9e4d31237c6fc2459a00100000000ffffffff0164000000000000001976a914c0be1d0305c0a7451bf9a8e69b38ecdb3d981a2888ac0000000000';

/// Three proven transactions of two blocks plus an unproven one, in an
/// order where a proven transaction follows an unproven one (so bumpIndex
/// positions are not transaction positions).
Uint8List _mixedBeefBytes() => BEEF.create(
      bumps: [fixtureBump(), BUMP.fromHex(fixture2BumpHex())],
      txs: [
        Uint8List.fromList(hex.decode(kFixtureTxHex)),
        BEEF.parse(Uint8List.fromList(hex.decode(_testnetBeefHex))).txs[1],
        Uint8List.fromList(hex.decode(kFixture2TxHex)),
      ],
      hasMerkle: [true, false, true],
      bumpIndex: [0, 1],
    ).serialize();

/// Counts the header reads [BlockHeaderChain] makes.
class _CountingStorage extends InMemoryWalletStorage {
  int recentHeaderLoads = 0;
  int heightByHashReads = 0;
  int headerByHeightReads = 0;

  @override
  Future<List<BlockHeader>> getRecentHeaders(int count) {
    recentHeaderLoads++;
    return super.getRecentHeaders(count);
  }

  @override
  Future<int?> getHeightByBlockHash(String hash) {
    heightByHashReads++;
    return super.getHeightByBlockHash(hash);
  }

  @override
  Future<BlockHeader?> getBlockHeaderByHeight(int height) {
    headerByHeightReads++;
    return super.getBlockHeaderByHeight(height);
  }
}

void main() {
  group('SPV-15 BEEF characterization on real fixtures', () {
    for (final (name, beefHex) in [
      ('Go SDK vector', _goSdkBeefHex),
      ('testnet proven + unproven child', _testnetBeefHex),
      ('two blocks, unproven in the middle', hex.encode(_mixedBeefBytes())),
    ]) {
      test('$name: round trip, txids, lookups and validation are unchanged', () {
        final bytes = Uint8List.fromList(hex.decode(beefHex));
        final beef = BEEF.parse(bytes);
        expect(hex.encode(beef.serialize()), beefHex, reason: 'parse/serialize round trip');

        var proven = 0;
        for (var i = 0; i < beef.txs.length; i++) {
          final txid = beef.calculateTxid(beef.txs[i]);
          final info = beef.findTransactionByTxid(txid);
          expect(info, isNotNull);
          expect(info!['index'], i);
          expect(identical(info['txData'], beef.txs[i]), isTrue);
          expect(info['hasMerkleProof'], beef.hasMerkle[i]);
          expect(info['bumpIndex'], beef.hasMerkle[i] ? beef.bumpIndex[proven] : null);
          if (beef.hasMerkle[i]) proven++;
          // Looked up by the internal byte order, the txid is not found.
          expect(beef.findTransactionByTxid(Uint8List.fromList(txid.reversed.toList())), isNull);
        }
        expect(beef.findTransactionByTxid(Uint8List(32)), isNull);

        final verified = beef.getVerifiedTransactions();
        expect(verified.length, proven);
        for (final v in verified) {
          expect(hex.encode(v['txid'] as Uint8List), hex.encode(beef.calculateTxid(v['txData'] as Uint8List)));
          expect(beef.validateTransaction(v['txid'] as Uint8List), isTrue);
        }
      });
    }

    test('the testnet BEEF validates against its real block header, and not against another', () async {
      final beef = BEEF.parse(Uint8List.fromList(hex.decode(_testnetBeefHex)));
      final txid = Uint8List.fromList(hex.decode(kFixtureTxid));
      expect(hex.encode(beef.calculateTxid(beef.txs[0])), kFixtureTxid);
      expect(await beef.validateTransactionWithBlockHeader(txid, fixtureHeader()), isTrue);
      expect(await beef.validateTransactionWithBlockHeader(txid, otherHeaderAtFixtureHeight()), isFalse);
      final child = beef.calculateTxid(beef.txs[1]);
      expect(await beef.validateTransactionWithBlockHeader(child, fixtureHeader()), isFalse);
      expect(beef.validateTransaction(child), isFalse);
    });
  });

  group('SPV-15 BEEF txid lookups hash each transaction once', () {
    tearDown(() => merkle.debugOnHash256 = null);

    test('parse hashes nothing; repeated lookups of every txid hash each transaction once in total', () {
      // Eight transactions: the fixtures and the Go SDK vector's, repeated
      // under distinct version bytes so every txid differs.
      final base = [
        ...BEEF.parse(Uint8List.fromList(hex.decode(_goSdkBeefHex))).txs,
        ...BEEF.parse(Uint8List.fromList(hex.decode(_testnetBeefHex))).txs,
      ];
      final txs = [
        for (var v = 0; v < 2; v++)
          for (final tx in base) Uint8List.fromList([v + 1, ...tx.sublist(1)]),
      ];
      final bytes = BEEF.create(bumps: [], txs: txs, hasMerkle: List.filled(txs.length, false), bumpIndex: [])
          .serialize();
      final expected = [
        for (final tx in txs) Uint8List.fromList(sha256.convert(sha256.convert(tx).bytes).bytes.reversed.toList()),
      ];

      var hashes = 0;
      merkle.debugOnHash256 = () => hashes++;

      final beef = BEEF.parse(bytes);
      expect(hashes, 0, reason: 'parsing does not hash');

      for (var round = 0; round < 3; round++) {
        for (var i = 0; i < txs.length; i++) {
          expect(beef.findTransactionByTxid(expected[i])!['index'], i);
          expect(hex.encode(beef.calculateTxid(beef.txs[i])), hex.encode(expected[i]));
        }
        expect(beef.findTransactionByTxid(Uint8List(32)), isNull);
      }
      expect(hashes, txs.length,
          reason: '3 rounds of lookups over ${txs.length} transactions must hash each one once');

      // A transaction that is not in the BEEF is still hashed on request.
      expect(hex.encode(beef.calculateTxid(Uint8List.fromList(hex.decode(kFixtureTxHex)))), kFixtureTxid);
      expect(hashes, txs.length + 1);
    });

    test('a transaction appended after the first lookup is found', () {
      final raw1 = Uint8List.fromList(hex.decode(kFixtureTxHex));
      final raw2 = Uint8List.fromList(hex.decode(kFixture2TxHex));
      final beef = BEEF(version: beefMagicAndVersion, bumps: [], txs: [raw1], hasMerkle: [false], bumpIndex: []);
      expect(beef.findTransactionByTxid(Uint8List.fromList(hex.decode(kFixtureTxid)))!['index'], 0);
      expect(beef.findTransactionByTxid(Uint8List.fromList(hex.decode(kFixture2Txid))), isNull);
      beef.txs.add(raw2);
      beef.hasMerkle.add(false);
      expect(beef.findTransactionByTxid(Uint8List.fromList(hex.decode(kFixture2Txid)))!['index'], 1);
    });
  });

  group('SPV-15 BEEF.parse keeps the transaction bytes it was given', () {
    test('a transaction with a non-minimal length prefix keeps its bytes and its txid', () {
      // The scriptSig length 0x6b written as the three-byte varint fd6b00:
      // valid to parse, but re-serialising writes 6b and changes the txid.
      final nonMinimal = kFixtureTxHex.replaceFirst('000000006b48', '00000000fd6b0048');
      expect(nonMinimal, isNot(kFixtureTxHex));
      final beef = BEEF.parse(Uint8List.fromList(hex.decode('0100beef0001${nonMinimal}00')));
      expect(hex.encode(beef.txs.single), nonMinimal);
      expect(hex.encode(beef.calculateTxid(beef.txs.single)), isNot(kFixtureTxid),
          reason: 'the txid is the hash of the bytes as sent');
    });
  });

  group('SPV-15 header chain', () {
    final regtest = NetworkParams.regtest;
    final genesis = regtest.genesisHeader;
    DateTime clock() => DateTime.fromMillisecondsSinceEpoch(1296688602 * 1000).add(const Duration(days: 3650));

    Future<void> expectLookups(BlockHeaderChain chain, List<BlockHeader> active, {int firstHeight = 1}) async {
      for (var i = 0; i < active.length; i++) {
        final hash = active[i].blockHash().toString();
        expect(await chain.getHeightByHash(hash), firstHeight + i, reason: 'height of $hash');
        expect((await chain.getHeaderByHeight(firstHeight + i))!.blockHash().toString(), hash);
        expect((await chain.getHeaderByHash(hash))!.blockHash().toString(), hash);
      }
    }

    test('bulk importing consecutive chunks does not reload the header cache per chunk', () async {
      final storage = _CountingStorage();
      final chain = BlockHeaderChain(storage, params: regtest, clock: clock);
      await chain.initialize();
      final headers = RegtestMiner.mineChain(genesis, 40, seed: 'bulk');

      final loadsBefore = storage.recentHeaderLoads;
      for (var start = 0; start < headers.length; start += 5) {
        await chain.bulkImportHeaders(headers.sublist(start, start + 5), start + 1);
      }
      expect(storage.recentHeaderLoads - loadsBefore, 0,
          reason: '8 chunks extending the tip must not re-read recent headers from storage');

      expect(chain.bestHeight, 40);
      expect(chain.chainTip!.blockHash(), headers.last.blockHash());
      final readsBefore = storage.heightByHashReads + storage.headerByHeightReads;
      await expectLookups(chain, headers);
      expect(storage.heightByHashReads + storage.headerByHeightReads, readsBefore,
          reason: 'every imported header is served from the in-memory maps');

      // A restart sees the same chain.
      final restarted = BlockHeaderChain(storage, params: regtest, clock: clock);
      await restarted.initialize();
      expect(restarted.bestHeight, 40);
      expect(restarted.chainTip!.blockHash(), headers.last.blockHash());
      await expectLookups(restarted, headers);
    });

    test('a bulk import that does not extend the tip still leaves consistent lookups', () async {
      final storage = _CountingStorage();
      final chain = BlockHeaderChain(storage, params: regtest, clock: clock);
      await chain.initialize();
      final headers = RegtestMiner.mineChain(genesis, 12, seed: 'overlap');
      await chain.bulkImportHeaders(headers.sublist(0, 8), 1);
      // Overlaps heights 5..8 with the same headers and extends to 12.
      await chain.bulkImportHeaders(headers.sublist(4), 5);
      expect(chain.bestHeight, 12);
      await expectLookups(chain, headers);
      // Re-importing the genesis chunk from height 0 skips the stored anchor.
      await chain.bulkImportHeaders([genesis, ...headers.sublist(0, 2)], 0);
      expect(chain.bestHeight, 12);
      await expectLookups(chain, headers);
    });

    test('getHeightByHash answers cached active headers without touching storage', () async {
      final storage = _CountingStorage();
      final chain = BlockHeaderChain(storage, params: regtest, clock: clock);
      await chain.initialize();
      final headers = RegtestMiner.mineChain(genesis, 30, seed: 'map');
      for (final h in headers) {
        expect((await chain.acceptHeader(h)).accepted, isTrue);
      }
      final before = storage.heightByHashReads;
      for (var i = 0; i < headers.length; i++) {
        expect(await chain.getHeightByHash(headers[i].blockHash().toString()), i + 1);
      }
      expect(storage.heightByHashReads, before);
    });

    test('the hash-to-height map follows a reorg, a reorg back, and a restart', () async {
      final storage = _CountingStorage();
      final chain = BlockHeaderChain(storage, params: regtest, clock: clock);
      await chain.initialize();
      final a = RegtestMiner.mineChain(genesis, 4, seed: 'A'); // heights 1..4
      for (final h in a) {
        expect((await chain.acceptHeader(h)).accepted, isTrue);
      }
      // B forks at height 2 and overtakes A at height 5.
      final b = RegtestMiner.mineChain(a[1], 3, seed: 'B'); // heights 3..5
      HeaderAcceptResult? last;
      for (final h in b) {
        last = await chain.acceptHeader(h);
        expect(last.accepted, isTrue);
      }
      expect(last!.reorganized, isTrue);
      expect(last.forkHeight, 2);
      expect(last.orphaned.map((h) => h.blockHash()).toList(), [a[2].blockHash(), a[3].blockHash()]);

      Future<void> expectActive(BlockHeaderChain c, List<BlockHeader> active, List<BlockHeader> orphaned) async {
        await expectLookups(c, active);
        for (final o in orphaned) {
          final hash = o.blockHash().toString();
          expect(await c.getHeightByHash(hash), isNull, reason: 'orphaned $hash must leave the map');
          expect(await c.getHeaderByHash(hash), isNull);
        }
        expect(c.chainTip!.blockHash(), active.last.blockHash());
        expect(c.bestHeight, active.length);
      }

      await expectActive(chain, [a[0], a[1], ...b], [a[2], a[3]]);

      // A comes back: two more A blocks give A more work than B.
      final a2 = RegtestMiner.mineChain(a[3], 2, seed: 'A2'); // heights 5..6
      for (final h in a2) {
        last = await chain.acceptHeader(h);
        expect(last.accepted, isTrue);
      }
      expect(last!.reorganized, isTrue);
      await expectActive(chain, [...a, ...a2], b);

      final restarted = BlockHeaderChain(storage, params: regtest, clock: clock);
      await restarted.initialize();
      await expectActive(restarted, [...a, ...a2], b);
    });
  });
}
