/// Audit 2026-09-14 SPV-16 (bead libspiffy-dq0): one merkle walk, one
/// double-SHA-256, one byte-order utility, one proof-of-work check, and parse
/// failures reported as the parser's own exception type.
///
/// The merkle group is characterization: every merkle-root computation in the
/// library is compared with an independent reference (the Bitcoin merkle tree
/// built from all leaves in this file) over trees of 1 to 9 transactions and
/// the two real testnet proofs. `CryptoUtils.computeMerkleRootFromTscProof`
/// was wrong on the base commit (display-order hashing and a doubled index
/// shift); its test is the bug reproduction.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:buffer/buffer.dart';
import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:libspiffy/src/services/node_rpc_data_source.dart';
import 'package:libspiffy/src/spv/merkle.dart' as merkle;
import 'package:libspiffy/src/spv/network_params.dart';
import 'package:libspiffy/src/utils/beef.dart';
import 'package:libspiffy/src/utils/bump.dart';
import 'package:libspiffy/src/utils/crypto_utils.dart';
import 'package:libspiffy/src/utils/hex_utils.dart' as hex_utils;
import 'package:test/test.dart';

import 'testnet_proof_fixture.dart';

Uint8List _sha256d(List<int> data) =>
    Uint8List.fromList(sha256.convert(sha256.convert(data).bytes).bytes);

String _display(List<int> internal) => hex.encode(internal.reversed.toList());

/// Reference merkle tree: every level, bottom first, odd levels padded by
/// duplicating the last node (internal byte order).
List<List<Uint8List>> _referenceTree(List<Uint8List> leaves) {
  final levels = <List<Uint8List>>[leaves];
  while (levels.last.length > 1) {
    final level = levels.last;
    final next = <Uint8List>[];
    for (var i = 0; i < level.length; i += 2) {
      final right = i + 1 < level.length ? level[i + 1] : level[i];
      next.add(_sha256d([...level[i], ...right]));
    }
    levels.add(next);
  }
  return levels;
}

/// Reference TSC path for leaf [index]: display hex, "*" for the padded copy.
List<String> _referencePath(List<List<Uint8List>> tree, int index) {
  final path = <String>[];
  var pos = index;
  for (var h = 0; h < tree.length - 1; h++) {
    final level = tree[h];
    final sib = pos ^ 1;
    path.add(sib >= level.length ? '*' : _display(level[sib]));
    pos >>= 1;
  }
  return path;
}

NodeRpcDataSource _node(List<String> txids, String merkleRoot) => NodeRpcDataSource(
      rpcUrl: 'http://node.test',
      rpcUser: 'u',
      rpcPassword: 'p',
      client: MockClient((request) async {
        final call = json.decode(request.body) as Map<String, dynamic>;
        final params = call['params'] as List;
        final Object result = switch (call['method']) {
          'getrawtransaction' => {'txid': params[0], 'blockhash': '00' * 32, 'blockheight': 900},
          'getblock' => {'hash': '00' * 32, 'height': 900, 'tx': txids, 'merkleroot': merkleRoot},
          _ => throw StateError('unexpected ${call['method']}'),
        };
        return http.Response(json.encode({'result': result, 'error': null, 'id': call['id']}), 200);
      }),
    );

/// A valid two-transaction BEEF: testnet tx a05924fc... with its BRC-74
/// BUMP, and its second real child proven by a second BUMP.
Uint8List _validBeefBytes() => BEEF.create(
      bumps: [fixtureBump(), BUMP.fromHex(fixture2BumpHex())],
      txs: [
        Uint8List.fromList(hex.decode(kFixtureTxHex)),
        Uint8List.fromList(hex.decode(kFixture2TxHex)),
      ],
      hasMerkle: [true, true],
      bumpIndex: [0, 1],
    ).serialize();

void main() {
  group('SPV-16 every merkle-root computation agrees with the reference tree', () {
    for (var size = 1; size <= 9; size++) {
      test('tree of $size transaction(s), every position', () async {
        final leaves = List.generate(size, (i) => _sha256d(utf8.encode('spv16-$size-$i')));
        final tree = _referenceTree(leaves);
        final rootDisplay = _display(tree.last.single);
        final txids = leaves.map(_display).toList();

        for (var index = 0; index < size; index++) {
          final txid = txids[index];
          final path = _referencePath(tree, index);
          final reason = 'size $size index $index';

          // The node-RPC source derives the same path from the block's txids.
          final proof = await _node(txids, rootDisplay).getMerkleProof(txid);
          expect(proof.nodes, path, reason: reason);
          expect(proof.index, index, reason: reason);

          final bump = BUMP.fromTscProof(blockHeight: 900, txid: txid, index: index, nodes: path);
          expect(_display(bump.computeMerkleRoot(leaves[index])), rootDisplay, reason: reason);
          expect(bump.computeMerkleRootForBlockHeader(leaves[index]), rootDisplay, reason: reason);
          expect(CryptoUtils.computeMerkleRootFromBump(bump, txid), rootDisplay, reason: reason);
          expect(CryptoUtils.computeMerkleRootFromBrc71(txid, {'index': index, 'path': path}), rootDisplay,
              reason: reason);
          expect(CryptoUtils.validateMerkleProofWithByteReversal(txid, path, rootDisplay, index), isTrue,
              reason: reason);
          expect(CryptoUtils.validateMerkleProof(txid, rootDisplay, {'index': index, 'path': path}), isTrue,
              reason: reason);
          expect(CryptoUtils.convertBumpToBrc71Path(bump, txid), {'index': index, 'path': path}, reason: reason);
        }
      });
    }

    test('the real testnet proofs walk to their block headers\' merkle roots', () {
      for (final (txid, index, nodes, header) in [
        (kFixtureTxid, kFixtureIndex, kFixtureNodes, fixtureHeader()),
        (kFixture2Txid, kFixture2Index, kFixture2Nodes, fixture2Header()),
      ]) {
        final root = header.merkleRoot.toString();
        final bump = BUMP.fromTscProof(blockHeight: 1, txid: txid, index: index, nodes: nodes);
        expect(CryptoUtils.computeMerkleRootFromBump(bump, txid), root);
        expect(CryptoUtils.computeMerkleRootFromBrc71(txid, {'index': index, 'path': nodes}), root);
        expect(CryptoUtils.validateMerkleProofWithByteReversal(txid, nodes, root, index), isTrue);
        final tampered = List<String>.of(nodes)..[1] = nodes[1].replaceRange(0, 1, nodes[1][0] == '0' ? '1' : '0');
        expect(CryptoUtils.validateMerkleProofWithByteReversal(txid, tampered, root, index), isFalse);
      }
    });

    test('a single-transaction block: the root is the txid, as given', () {
      final txid = _display(_sha256d(utf8.encode('only')));
      expect(CryptoUtils.computeMerkleRootFromBrc71(txid, {'index': 0, 'path': <String>[]}), txid);
      expect(CryptoUtils.validateMerkleProofWithByteReversal(txid, const [], txid, 0), isTrue);
      final upper = txid.toUpperCase();
      expect(CryptoUtils.computeMerkleRootFromBrc71(upper, {'index': 0, 'path': <String>[]}), upper);
      // String comparison, as before: an upper-case root does not match.
      final bump = fixtureBump();
      expect(
          CryptoUtils.validateMerkleProofWithByteReversal(
              kFixtureTxid, kFixtureNodes, fixtureHeader().merkleRoot.toString().toUpperCase(), kFixtureIndex),
          isFalse);
      expect(CryptoUtils.computeMerkleRootFromBump(bump, kFixtureTxid), fixtureHeader().merkleRoot.toString());
    });

    test('CryptoUtils.computeMerkleRootFromTscProof returns the block merkle root (was wrong)', () {
      for (final (txid, index, nodes, header) in [
        (kFixtureTxid, kFixtureIndex, kFixtureNodes, fixtureHeader()),
        (kFixture2Txid, kFixture2Index, kFixture2Nodes, fixture2Header()),
      ]) {
        final result = CryptoUtils.computeMerkleRootFromTscProof({'txOrId': txid, 'index': index, 'nodes': nodes});
        final root = header.merkleRoot.toString();
        expect(result['merkleRoot'], root, reason: 'txid $txid');
        expect(result['internalMerkleRoot'], hex_utils.reverseHexBytes(root));
        expect(result['txIndex'], index);
      }
    });

    test('CryptoUtils.computeMerkleRootFromTscProof handles "*" and every position of a 5-tx tree', () {
      final leaves = List.generate(5, (i) => _sha256d(utf8.encode('tsc-$i')));
      final tree = _referenceTree(leaves);
      for (var index = 0; index < 5; index++) {
        final result = CryptoUtils.computeMerkleRootFromTscProof(
            {'txOrId': _display(leaves[index]), 'index': index, 'nodes': _referencePath(tree, index)});
        expect(result['merkleRoot'], _display(tree.last.single), reason: 'index $index');
      }
    });
  });

  group('SPV-16 one proof-of-work check', () {
    test('NetworkParams.checkProofOfWork: genesis headers pass', () {
      for (final params in [NetworkParams.mainnet, NetworkParams.testnet, NetworkParams.regtest]) {
        final g = params.genesisHeader;
        final check = params.checkProofOfWork(g.bits, g.blockHash().toString());
        expect(check.ok, isTrue, reason: params.name);
        expect(check.target, NetworkParams.bitsToTarget(g.bits));
      }
    });

    test('NetworkParams.checkProofOfWork names the first failed rule, target before hash', () {
      final regtest = NetworkParams.regtest;
      const hashAboveEverything = 'ff00000000000000000000000000000000000000000000000000000000000000';
      final noTarget = regtest.checkProofOfWork(0x20800000, hashAboveEverything); // sign bit set
      expect(noTarget.failure, ProofOfWorkFailure.noTarget);
      expect(noTarget.invalidTarget, isTrue);
      final aboveLimit = regtest.checkProofOfWork(0x2100ffff, hashAboveEverything);
      expect(aboveLimit.failure, ProofOfWorkFailure.aboveLimit);
      expect(aboveLimit.invalidTarget, isTrue);
      final main = NetworkParams.mainnet;
      final g = main.genesisHeader;
      final hashAbove = main.checkProofOfWork(g.bits, hashAboveEverything);
      expect(hashAbove.failure, ProofOfWorkFailure.hashAboveTarget);
      expect(hashAbove.invalidTarget, isFalse);
      expect(hashAbove.ok, isFalse);
      // A hash exactly at the target passes.
      final target = NetworkParams.bitsToTarget(g.bits);
      expect(main.checkProofOfWork(g.bits, target.toRadixString(16).padLeft(64, '0')).ok, isTrue);
    });
  });

  group('SPV-16 hash and byte-order helpers', () {
    test('merkle.dart: hash256, merkleParent, merkleRootFromPath and merklePathForIndex', () {
      expect(merkle.hash256([1, 2, 3]), _sha256d([1, 2, 3]));
      expect(hex.encode(merkle.txidDisplayBytes(hex.decode(kFixtureTxHex))), kFixtureTxid);
      expect(hex.encode(merkle.txidInternalBytes(hex.decode(kFixtureTxHex))), hex_utils.reverseHexBytes(kFixtureTxid));
      final a = _sha256d([1]), b = _sha256d([2]), c = _sha256d([3]);
      expect(merkle.merkleParent(a, b), _sha256d([...a, ...b]));
      final tree = _referenceTree([a, b, c]);
      for (var i = 0; i < 3; i++) {
        final path = merkle.merklePathForIndex([a, b, c], i);
        expect(merkle.merkleRootFromPath([a, b, c][i], i, path), tree.last.single);
      }
      expect(merkle.merklePathForIndex([a, b, c], 2).first, isNull, reason: 'the padded copy is a duplicate');
      expect(merkle.merklePathForIndex([a], 0), isEmpty);
      expect(merkle.merkleRootFromPath(a, 0, const []), a);
      expect(() => merkle.merklePathForIndex([a, b], 2), throwsRangeError);
    });

    test('hex_utils: reverseBytes, displayToInternal, internalToDisplay, bytesEqual', () {
      expect(hex_utils.reverseBytes([1, 2, 3]), [3, 2, 1]);
      expect(hex_utils.reverseBytes(const []), isEmpty);
      expect(hex_utils.displayToInternal('0a0b'), [0x0b, 0x0a]);
      expect(hex_utils.internalToDisplay([0x0b, 0x0a]), '0a0b');
      expect(() => hex_utils.displayToInternal('zz'), throwsFormatException);
      expect(hex_utils.bytesEqual([1, 2], [1, 2]), isTrue);
      expect(hex_utils.bytesEqual([1, 2], [1, 2, 3]), isFalse);
      expect(hex_utils.bytesEqual([1, 2], [1, 3]), isFalse);
    });

    test('CryptoUtils.doubleSha256 is double SHA-256 of the decoded hex', () {
      expect(CryptoUtils.doubleSha256('00ff'), hex.encode(_sha256d([0x00, 0xff])));
    });

    test('CryptoUtils.reverseBytes and reverseHexBytes agree; odd length is rejected', () {
      expect(CryptoUtils.reverseBytes('0a0b0c'), '0c0b0a');
      expect(hex_utils.reverseHexBytes('0a0b0c'), '0c0b0a');
      expect(() => CryptoUtils.reverseBytes('abc'),
          throwsA(predicate((e) => '$e'.contains('Hex string must have an even number of characters'))));
    });

    test('BEEF.calculateTxid is the display-order double SHA-256', () {
      final raw = Uint8List.fromList(hex.decode(kFixtureTxHex));
      final beef = BEEF.create(bumps: [], txs: [raw], hasMerkle: [false], bumpIndex: []);
      expect(hex.encode(beef.calculateTxid(raw)), kFixtureTxid);
      expect(beef.listEquals(Uint8List.fromList([1, 2]), Uint8List.fromList([1, 2])), isTrue);
      expect(beef.listEquals(Uint8List.fromList([1, 2]), Uint8List.fromList([2, 1])), isFalse);
    });

    test('BUMP.fromTscProof keeps its error for bad hex', () {
      expect(
          () => BUMP.fromTscProof(blockHeight: 1, txid: 'zz' * 32, index: 0, nodes: const []),
          throwsA(isA<BUMPException>()
              .having((e) => e.message, 'message', startsWith('Invalid hex for txid'))));
    });
  });

  group('SPV-16 BEEF.parse reports every malformed input as BEEFException', () {
    test('the valid fixture parses and round-trips byte for byte', () {
      final bytes = _validBeefBytes();
      final beef = BEEF.parse(bytes);
      expect(beef.txs.length, 2);
      expect(hex.encode(beef.serialize()), hex.encode(bytes));
    });

    test('every truncation of a valid BEEF', () {
      final bytes = _validBeefBytes();
      for (var cut = 0; cut < bytes.length; cut++) {
        expect(() => BEEF.parse(Uint8List.sublistView(bytes, 0, cut)), throwsA(isA<BEEFException>()),
            reason: 'truncated to $cut of ${bytes.length} bytes');
      }
    });

    test('truncation right after the magic keeps the reader\'s reason in the message', () {
      expect(() => BEEF.parse(Uint8List.fromList(hex.decode('0100beef'))),
          throwsA(isA<BEEFException>().having((e) => '$e', 'text', contains('Not enough bytes to read'))));
    });

    test('garbage after a valid magic', () {
      for (final body in ['ff', 'fdffff', 'ffffffffffffffffff', '01ff00', '00ff${'ab' * 40}']) {
        expect(() => BEEF.parse(Uint8List.fromList(hex.decode('0100beef$body'))),
            throwsA(isA<BEEFException>()),
            reason: 'body $body');
      }
    });

    test('a BUMP index beyond the BUMP list', () {
      final raw = hex.decode(kFixtureTxHex);
      final bytes = Uint8List.fromList([...hex.decode('0100beef0001'), ...raw, 0x01, 0x00]);
      expect(() => BEEF.parse(bytes),
          throwsA(isA<BEEFException>().having((e) => e.message, 'message', contains('Invalid BUMP index 0'))));
    });

    test('trailing bytes after the last transaction', () {
      final bytes = _validBeefBytes();
      expect(() => BEEF.parse(Uint8List.fromList([...bytes, 0x00])),
          throwsA(isA<BEEFException>().having((e) => e.message, 'message', contains('trailing'))));
    });

    test('a wrong version', () {
      final bytes = _validBeefBytes();
      for (final magic in ['0200beef', 'deadbeef', '00000000', 'efbe0001']) {
        final wrong = Uint8List.fromList([...hex.decode(magic), ...bytes.sublist(4)]);
        expect(() => BEEF.parse(wrong),
            throwsA(isA<BEEFException>().having((e) => e.message, 'message', startsWith('Invalid BEEF version'))),
            reason: magic);
      }
    });

    test('an empty BEEF (no BUMPs, no transactions) still parses', () {
      final beef = BEEF.parse(Uint8List.fromList(hex.decode('0100beef0000')));
      expect(beef.txs, isEmpty);
      expect(beef.bumps, isEmpty);
    });
  });

  group('SPV-16 BUMP.parse reports malformed input as BUMPException', () {
    for (final (name, input) in [
      ('empty', ''),
      ('truncated inside the block height', 'fe636d0c'),
      ('truncated after the tree height', '0a01'),
      ('truncated inside a hash', '0a0101000201020304'),
    ]) {
      test('BUMP.parse on $name input', () {
        final reader = ByteDataReader()..add(hex.decode(input));
        expect(() => BUMP.parse(reader),
            throwsA(isA<BUMPException>().having((e) => '$e', 'text', contains('Not enough bytes to read'))));
      });

      test('BUMP.fromBytes on $name input', () {
        expect(() => BUMP.fromBytes(Uint8List.fromList(hex.decode(input))),
            throwsA(isA<BUMPException>().having((e) => e.message, 'message', startsWith('Failed to parse BUMP'))));
      });
    }
  });
}
