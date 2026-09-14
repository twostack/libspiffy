import 'dart:convert';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart' show sha256;
import 'package:libspiffy/src/models/blockchain_data_models.dart';
import 'package:libspiffy/src/storage/read_model_storage.dart';
import 'package:libspiffy/src/utils/beef.dart';
import 'package:libspiffy/src/utils/bump.dart';
import 'package:libspiffy/src/utils/crypto_utils.dart';
import 'package:libspiffy/src/utils/tsc_converter.dart';
import 'package:spiffynode/spiffy_node.dart' show BlockHeader, Hash;
import 'package:test/test.dart';

/// Audit 2026-09-14 SPV-06 / SPV-07 / SPV-08: BRC-74 (BUMP) compliance.
///
/// The fixture is SELF-CONSTRUCTED (not the BRC-74 spec vector): a block of
/// N deterministic leaves, leaf i = sha256d("libspiffy-brc74-leaf-i"), whose
/// merkle root is computed here with the plain Bitcoin algorithm (pair up,
/// duplicate the last hash of an odd level). The library's BUMP builder and
/// root walk are then checked against that independent computation. A real
/// BRC-74 BUMP emitted by ARC (already in the repo's fixtures) is used as an
/// additional byte-for-byte cross-check of the builder's layout.
///
/// BRC-74 layout: level 0 holds the txid leaf (flag 0x02) AND its sibling at
/// offset index ^ 1 (a hash, or flag 0x01 "duplicate" meaning "pair the
/// working hash with itself"); level h >= 1 holds one leaf, the sibling of
/// the working hash at offset (index >> h) ^ 1. Hashes are in internal
/// (little-endian) byte order.
void main() {
  // ---------------------------------------------------------------------------
  // Fixture helpers (independent of the library's merkle code)
  // ---------------------------------------------------------------------------

  Uint8List sha256d(List<int> data) =>
      Uint8List.fromList(sha256.convert(sha256.convert(data).bytes).bytes);

  Uint8List hashPair(Uint8List left, Uint8List right) =>
      sha256d([...left, ...right]);

  Uint8List leaf(int i) => sha256d(utf8.encode('libspiffy-brc74-leaf-$i'));

  List<Uint8List> block(int n) => List.generate(n, leaf);

  Uint8List merkleRoot(List<Uint8List> leaves) {
    var level = List<Uint8List>.of(leaves);
    while (level.length > 1) {
      if (level.length.isOdd) level.add(level.last);
      final next = <Uint8List>[];
      for (var i = 0; i < level.length; i += 2) {
        next.add(hashPair(level[i], level[i + 1]));
      }
      level = next;
    }
    return level.single;
  }

  String display(Uint8List internal) => hex.encode(internal.reversed.toList());
  Uint8List internal(String displayHex) =>
      Uint8List.fromList(hex.decode(displayHex).reversed.toList());

  /// TSC-style sibling list for [index]: display-format hex, "*" where the
  /// sibling is a duplicate of the working hash (odd level, last element).
  List<String> tscNodes(List<Uint8List> leaves, int index) {
    var level = List<Uint8List>.of(leaves);
    var idx = index;
    final nodes = <String>[];
    while (level.length > 1) {
      final wasOdd = level.length.isOdd;
      if (wasOdd) level.add(level.last);
      final sib = idx ^ 1;
      if (wasOdd && sib == level.length - 1) {
        nodes.add('*');
      } else {
        nodes.add(display(level[sib]));
      }
      final next = <Uint8List>[];
      for (var i = 0; i < level.length; i += 2) {
        next.add(hashPair(level[i], level[i + 1]));
      }
      level = next;
      idx >>= 1;
    }
    return nodes;
  }

  Map<String, dynamic> tscProof(List<Uint8List> leaves, int index) => {
        'index': index,
        'txOrId': display(leaves[index]),
        'target': display(merkleRoot(leaves)),
        'nodes': tscNodes(leaves, index),
      };

  /// Hand-built BRC-74 BUMP for [index] (the layout the spec mandates).
  BUMP brc74Bump(List<Uint8List> leaves, int index, {int blockHeight = 100}) {
    final nodes = tscNodes(leaves, index);
    Leaf sibling(int offset, String node) => Leaf(
          offset: offset,
          duplicate: node == '*',
          isTxid: false,
          hash: node == '*' ? null : internal(node),
        );
    final level0 = [
      Leaf(offset: index, duplicate: false, isTxid: true, hash: leaves[index]),
      sibling(index ^ 1, nodes[0]),
    ]..sort((a, b) => a.offset.compareTo(b.offset));
    final path = [Level(leaves: level0)];
    for (var h = 1; h < nodes.length; h++) {
      path.add(Level(leaves: [sibling((index >> h) ^ 1, nodes[h])]));
    }
    return BUMP(blockHeight: blockHeight, path: path);
  }

  String bumpHex(BUMP b) => hex.encode(b.serialize());

  final eight = block(8);
  final five = block(5);
  final rootEight = merkleRoot(eight);
  final rootFive = merkleRoot(five);

  group('BRC-74 fixture sanity (independent computation)', () {
    test('8-leaf block: TSC nodes walk to the root for every position', () {
      for (var i = 0; i < 8; i++) {
        var working = eight[i];
        var idx = i;
        for (final node in tscNodes(eight, i)) {
          final sib = node == '*' ? working : internal(node);
          working = idx.isEven ? hashPair(working, sib) : hashPair(sib, working);
          idx >>= 1;
        }
        expect(hex.encode(working), hex.encode(rootEight), reason: 'position $i');
      }
    });

    test('5-leaf block: position 4 needs a duplicate at levels 0 and 1', () {
      final nodes = tscNodes(five, 4);
      expect(nodes.length, 3);
      expect(nodes[0], '*');
      expect(nodes[1], '*');
      expect(nodes[2], isNot('*'));
    });
  });

  group('SPV-06: the library builds BRC-74 compliant BUMPs', () {
    test('createBumpFromTscProof emits txid + sibling at level 0, one sibling per level above',
        () {
      for (final index in [0, 3, 6, 7]) {
        final built = CryptoUtils.createBumpFromTscProof(tscProof(eight, index), 100);
        final expected = brc74Bump(eight, index);
        expect(built.path.length, 3, reason: 'tree height of an 8-leaf block is 3');
        expect(built.path[0].leaves.length, 2,
            reason: 'level 0 must carry the txid and its sibling');
        expect(bumpHex(built), bumpHex(expected), reason: 'position $index');
      }
    });

    test('TscConverter.convertToBump emits the same BRC-74 bytes', () {
      final converter = TscConverter();
      for (final index in [0, 5]) {
        final proof = tscProof(eight, index);
        final built = converter.convertToBump(MerkleProofData(
          txid: proof['txOrId'] as String,
          blockHeight: 100,
          merkleRoot: proof['target'] as String,
          index: index,
          nodes: (proof['nodes'] as List).cast<String>(),
          format: 'tsc',
        ));
        expect(bumpHex(built), bumpHex(brc74Bump(eight, index)), reason: 'position $index');
      }
    });

    test('buildBUMPFromMerkleProof (sibling-list storage) emits the same BRC-74 bytes', () {
      final proof = tscProof(eight, 6);
      final built = CryptoUtils.buildBUMPFromMerkleProof(MerkleProof(
        txid: proof['txOrId'] as String,
        blockHash: 'unused',
        blockHeight: 100,
        position: 6,
        merkleProof: (proof['nodes'] as List).cast<String>(),
      ));
      expect(bumpHex(built), bumpHex(brc74Bump(eight, 6)));
    });

    test('buildBUMPFromMerkleProof (raw BUMP hex storage) returns the stored BUMP verbatim', () {
      final raw = bumpHex(brc74Bump(eight, 2));
      final built = CryptoUtils.buildBUMPFromMerkleProof(MerkleProof(
        txid: display(eight[2]),
        blockHash: 'unused',
        blockHeight: 100,
        position: 2,
        merkleProof: [raw],
      ));
      expect(bumpHex(built), raw);
    });

    test('built BUMP parses, round-trips through hex, and yields the independently computed root',
        () {
      for (final index in [0, 3, 7]) {
        final built = CryptoUtils.createBumpFromTscProof(tscProof(eight, index), 100);
        final parsed = BUMP.fromBytes(Uint8List.fromList(hex.decode(bumpHex(built))));
        expect(bumpHex(parsed), bumpHex(built), reason: 'hex round-trip, position $index');
        expect(hex.encode(parsed.computeMerkleRoot(eight[index])), hex.encode(rootEight),
            reason: 'root for position $index');
        expect(parsed.validateMerklePath(eight[index], expectedMerkleRoot: rootEight), isTrue);
      }
    });

    test('odd leaf count: duplicate siblings are encoded as flag 0x01 and hashed with self', () {
      final built = CryptoUtils.createBumpFromTscProof(tscProof(five, 4), 100);
      expect(bumpHex(built), bumpHex(brc74Bump(five, 4)));
      expect(built.path[0].leaves.where((l) => l.duplicate).single.offset, 5);
      expect(built.path[1].leaves.single.duplicate, isTrue);
      expect(hex.encode(built.computeMerkleRoot(five[4])), hex.encode(rootFive));
      final parsed = BUMP.fromBytes(built.serialize());
      expect(hex.encode(parsed.computeMerkleRoot(five[4])), hex.encode(rootFive));
    });

    test('a BUMP holding two txids of the same block yields the same root for both', () {
      final a = CryptoUtils.createBumpFromTscProof(tscProof(eight, 3), 100);
      final b = CryptoUtils.createBumpFromTscProof(tscProof(eight, 4), 100);
      final combined = CryptoUtils.combineBumps([a, b]);
      final parsed = BUMP.fromBytes(combined.serialize());
      expect(parsed.path[0].leaves.where((l) => l.isTxid).length, 2);
      expect(hex.encode(parsed.computeMerkleRoot(eight[3])), hex.encode(rootEight));
      expect(hex.encode(parsed.computeMerkleRoot(eight[4])), hex.encode(rootEight));
      expect(parsed.validateMerklePath(eight[3], expectedMerkleRoot: rootEight), isTrue);
      expect(parsed.validateMerklePath(eight[4], expectedMerkleRoot: rootEight), isTrue);
    });

    test('two txids that are siblings of each other share one level-0 pair', () {
      final a = CryptoUtils.createBumpFromTscProof(tscProof(eight, 2), 100);
      final b = CryptoUtils.createBumpFromTscProof(tscProof(eight, 3), 100);
      final combined = BUMP.fromBytes(CryptoUtils.combineBumps([a, b]).serialize());
      expect(combined.path[0].leaves.length, 2);
      expect(combined.path[0].leaves.every((l) => l.isTxid), isTrue);
      expect(hex.encode(combined.computeMerkleRoot(eight[2])), hex.encode(rootEight));
      expect(hex.encode(combined.computeMerkleRoot(eight[3])), hex.encode(rootEight));
    });

    test('real ARC BUMP: TSC-built bytes equal the BUMP ARC emitted for the same tx', () {
      // Production data already in test/bump_format_equivalence_test.dart:
      // the same transaction as a WhatsOnChain TSC proof and as ARC's merklePath.
      final realTscProof = {
        'index': 1,
        'txOrId': 'b1cc6816eb53fd065fcaac61a4eefc1b0f1769df4149ed623c77ff0e6183d9d2',
        'target': '000000001387da7eee528023f9f3dba5481fb43c85edcb42877968e19ce5dfb7',
        'nodes': [
          '97b69ba7a50ab9976ae95263e841f98199134a715cc79bcbb6b06ea882d53204',
          'df25cca0fc495f05ff629983ec5f0ee2257fc67b28e9a9acf82ee4a4a8b69cfd',
          'ab522a9f4a0a6e0cbde9ffe7aca616cb6e438be16c5264916cce7f135cced361',
        ],
      };
      const arcMerklePath =
          'fe2f161a00030200000432d582a86eb0b6cb9bc75c714a139981f941e86352e96a97b90aa5a79bb6970102d2d983610eff773c62ed4941df69170f1bfceea461acca5f06fd53eb1668ccb1010100fd9cb6a8a4e42ef8aca9e9287bc67f25e20e5fec839962ff055f49fca0cc25df01010061d3ce5c137fce6c9164526ce18b436ecb16a6ace7ffe9bd0c6e0a4a9f2a52ab';

      final built = CryptoUtils.createBumpFromTscProof(realTscProof, 1709615);
      expect(bumpHex(built), arcMerklePath);

      final txid = internal(realTscProof['txOrId'] as String);
      final arc = BUMP.fromBytes(Uint8List.fromList(hex.decode(arcMerklePath)));
      expect(hex.encode(built.computeMerkleRoot(txid)), hex.encode(arc.computeMerkleRoot(txid)));
    });
  });

  group('SPV-07: BRC-74 root walk and a real validateMerklePath', () {
    test('computeMerkleRoot follows offsets on a real-layout BUMP (txid listed second)', () {
      // Level 0 sorted by offset puts the sibling (6) before the txid (7).
      final bump = brc74Bump(eight, 7);
      expect(bump.path[0].leaves.first.isTxid, isFalse);
      expect(hex.encode(bump.computeMerkleRoot(eight[7])), hex.encode(rootEight));
    });

    test('validateMerklePath with the expected root accepts a valid real-layout BUMP', () {
      final bump = brc74Bump(eight, 5);
      expect(bump.validateMerklePath(eight[5], expectedMerkleRoot: rootEight), isTrue);
      expect(bump.validateMerklePath(eight[5], expectedMerkleRoot: rootFive), isFalse);
    });

    test('validateMerklePath rejects a BUMP whose level-1 sibling hash was tampered', () {
      final good = brc74Bump(eight, 5);
      final tamperedHash = Uint8List.fromList(good.path[1].leaves.single.hash!);
      tamperedHash[0] ^= 0x01;
      final tampered = BUMP(blockHeight: 100, path: [
        good.path[0],
        Level(leaves: [Leaf(offset: 3, duplicate: false, isTxid: false, hash: tamperedHash)]),
        good.path[2],
      ]);
      expect(tampered.validateMerklePath(eight[5], expectedMerkleRoot: rootEight), isFalse);
      expect(hex.encode(tampered.computeMerkleRoot(eight[5])), isNot(hex.encode(rootEight)));
    });

    test('validateMerklePath rejects a BUMP whose level-1 sibling sits at the wrong offset', () {
      // Structural tamper: the sibling for index 5 at level 1 must be at
      // offset (5 >> 1) ^ 1 = 3. Put it at offset 2 instead; there is then no
      // sibling to pair with, so the walk cannot complete.
      final good = brc74Bump(eight, 5);
      final misplaced = BUMP(blockHeight: 100, path: [
        good.path[0],
        Level(leaves: [
          Leaf(offset: 2, duplicate: false, isTxid: false, hash: good.path[1].leaves.single.hash)
        ]),
        good.path[2],
      ]);
      expect(misplaced.validateMerklePath(eight[5]), isFalse);
      expect(() => misplaced.computeMerkleRoot(eight[5]), throwsA(isA<BUMPException>()));
    });

    test('validateMerklePath rejects a BUMP with no sibling for the txid at level 0', () {
      final txidOnly = BUMP(blockHeight: 100, path: [
        Level(leaves: [Leaf(offset: 5, duplicate: false, isTxid: true, hash: eight[5])]),
        brc74Bump(eight, 5).path[1],
        brc74Bump(eight, 5).path[2],
      ]);
      expect(txidOnly.validateMerklePath(eight[5]), isFalse);
    });

    test('single-transaction block: the txid is the root', () {
      final coinbase = BUMP(blockHeight: 100, path: [
        Level(leaves: [Leaf(offset: 0, duplicate: false, isTxid: true, hash: eight[0])]),
      ]);
      expect(hex.encode(coinbase.computeMerkleRoot(eight[0])), hex.encode(eight[0]));
      expect(coinbase.validateMerklePath(eight[0], expectedMerkleRoot: eight[0]), isTrue);
    });

    test('BEEF.validateTransaction actually walks the path', () async {
      // A 1-input 1-output legacy transaction; its txid is whatever it hashes
      // to, so build the block around it.
      // version | 1 input (prev aa..aa:0, empty script, seq ffffffff) |
      // 1 output (0 sat, empty script) | locktime 0
      final rawTx = Uint8List.fromList(hex.decode(
          '0100000001${'aa' * 32}0000000000ffffffff01${'00' * 8}0000000000'));
      final txid = sha256d(rawTx); // internal byte order
      final leaves = [leaf(0), leaf(1), txid, leaf(3)];
      final root = merkleRoot(leaves);
      final good = brc74Bump(leaves, 2);
      final tamperedHash = Uint8List.fromList(good.path[1].leaves.single.hash!);
      tamperedHash[5] ^= 0x80;
      final tampered = BUMP(blockHeight: 100, path: [
        good.path[0],
        Level(leaves: [Leaf(offset: 0, duplicate: false, isTxid: false, hash: tamperedHash)]),
      ]);
      BEEF beefWith(BUMP b) =>
          BEEF.create(bumps: [b], txs: [rawTx], hasMerkle: [true], bumpIndex: [0]);
      final txidDisplay = Uint8List.fromList(txid.reversed.toList());
      final header = BlockHeader(
        version: 1,
        prevBlock: Hash.fromBytes(Uint8List(32)),
        merkleRoot: Hash.fromBytes(root),
        timestamp: DateTime.utc(2026, 1, 1),
        bits: 0x1d00ffff,
        nonce: 0,
      );

      expect(beefWith(good).validateTransaction(txidDisplay), isTrue);
      expect(await beefWith(good).validateTransactionWithBlockHeader(txidDisplay, header), isTrue);
      expect(await beefWith(tampered).validateTransactionWithBlockHeader(txidDisplay, header),
          isFalse);
    });
  });

  group('SPV-08: TSC "*" duplicate markers', () {
    test('createBumpFromTscProof maps "*" to a duplicate leaf and computes the right root', () {
      final proof = tscProof(five, 4);
      expect(proof['nodes'], contains('*'));
      final bump = CryptoUtils.createBumpFromTscProof(proof, 100);
      expect(hex.encode(bump.computeMerkleRoot(five[4])), hex.encode(rootFive));
    });

    test('TscConverter maps "*" to a duplicate leaf at offset index ^ 1', () {
      final proof = tscProof(five, 4);
      final bump = TscConverter().convertToBump(MerkleProofData(
        txid: proof['txOrId'] as String,
        blockHeight: 100,
        merkleRoot: proof['target'] as String,
        index: 4,
        nodes: (proof['nodes'] as List).cast<String>(),
        format: 'tsc',
      ));
      final dup = bump.path[0].leaves.where((l) => l.duplicate).single;
      expect(dup.offset, 5);
      expect(dup.hash, isNull);
      expect(hex.encode(bump.computeMerkleRoot(five[4])), hex.encode(rootFive));
    });

    test('a 3-leaf block: every position, including the duplicated one, reaches the root', () {
      final three = block(3);
      final root = merkleRoot(three);
      for (var i = 0; i < 3; i++) {
        final bump = CryptoUtils.createBumpFromTscProof(tscProof(three, i), 100);
        expect(hex.encode(bump.computeMerkleRoot(three[i])), hex.encode(root),
            reason: 'position $i');
      }
    });
  });
}
