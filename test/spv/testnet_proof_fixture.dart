/// A real testnet transaction, its WhatsOnChain TSC merkle proof and the real
/// (proof-of-work carrying) header of the block that contains it. The
/// header's merkle root is independent evidence: a proof is genuine only if
/// walking it from the txid ends at that root.
///
/// Same fixture as test/integration/import_actor_test.dart (tx1).
library;

import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:libspiffy/src/utils/bump.dart';
import 'package:spiffynode/spiffy_node.dart';

const kFixtureTxHex =
    '020000000165b6c06790c23623c4988ee51b3f27c76bfb6a0c9e5bab3432968c51379af66a000000006b483045022100b735fb60adca4fa42e37746aa602c3206bf98572ae83e396da4fd11cb716b26d022017bf9955bd8fc4d60f2829236c7864d5b5540062c88113daef137c0ee441736c41210222824a8530bc570b7bae7c7600529b450a65eab1203c5f561d8082cd97b3dba1feffffff02872ec735150000001976a9149d02ce72bbdc1713d5537a0705d8ec7d9702c81088ac00c2eb0b000000001976a9146a418bf9e2e2b670e1aa7b7da59391e212b4ba1988ac5cea1200';
const kFixtureTxid = 'a05924fcc63712d3e4b94b0c88baad234c2c8ad3d369704f53765e21a53a2101';
const kFixtureHeight = 1239645;
const kFixtureIndex = 2;
const kFixtureBlockHash = '000000001539f91cede66262caa22d1b504d09aa1dc3221f7fac5b30c2f7d65d';
const kFixtureNodes = [
  '405649f55c4a98a3f83e6d780bb44297035d4a3652d9ddc9dc50799bed17b62b',
  '750e25837b6188f87387b1eb18604e9fe07aa32fb80221e7a1c7d7e04427c8e0',
  '3980d9a3572b903c74302a586c923ce0bf26d979a23290a28750cb2e1cc19199',
  '2b6da3206c7aed19f0bc6c68826f86638c1f9214a6b3eead3d7121381a82549d',
  '5d3e8be2af6e109196a14a81dc6f99e17d7420eddf1d31a1a50fb2ef6933e3a1',
  'c4f09f1a5fb1e66a95b66ca7502062292708597c7e15574fc6dd1f9bcc7d2f5a',
];

/// Testnet block 1239645 (hashes to [kFixtureBlockHash]).
BlockHeader fixtureHeader() => BlockHeader(
      version: 536870912,
      prevBlock: Hash.fromHex('0000000070ad42dbfbc9860b1c6d6f636515834a4407e86cdead84d158592bd3'),
      merkleRoot: Hash.fromHex('4823b3e0a9801d019c49af6ecd923f5250cc828e7be4fb6b4c5afbb979e33b34'),
      timestamp: DateTime.fromMillisecondsSinceEpoch(1528803530 * 1000),
      bits: 0x1d00ffff,
      nonce: 2121538711,
    );

/// A header at the same height whose merkle root is something else (what a
/// competing block, or our own chain disagreeing with ARC, looks like).
BlockHeader otherHeaderAtFixtureHeight() {
  final real = fixtureHeader();
  return BlockHeader(
    version: real.version,
    prevBlock: real.prevBlock,
    merkleRoot: Hash.fromHex('11' * 32),
    timestamp: real.timestamp,
    bits: real.bits,
    nonce: real.nonce,
  );
}

/// The genuine proof as nodes, optionally with sibling [tamperLevel] altered
/// (last hex digit flipped).
List<String> fixtureNodes({int? tamperLevel}) {
  final nodes = List<String>.of(kFixtureNodes);
  if (tamperLevel != null) {
    final n = nodes[tamperLevel];
    final last = n.substring(n.length - 1) == '0' ? '1' : '0';
    nodes[tamperLevel] = n.substring(0, n.length - 1) + last;
  }
  return nodes;
}

/// BRC-74 BUMP for the fixture transaction.
BUMP fixtureBump({int? tamperLevel}) => BUMP.fromTscProof(
      blockHeight: kFixtureHeight,
      txid: kFixtureTxid,
      index: kFixtureIndex,
      nodes: fixtureNodes(tamperLevel: tamperLevel),
    );

/// Raw BUMP hex, the form ARC returns as `merklePath` and the projection
/// stores in `MerkleProof.merkleProof`.
String fixtureBumpHex({int? tamperLevel}) => fixtureBump(tamperLevel: tamperLevel).toHex();

/// A second real testnet transaction, mined in a later block; it spends
/// output 1 of the first fixture transaction and pays output 0 to the same
/// key. Proof and header as for the first.
const kFixture2TxHex =
    '020000000101213aa5215e76534f7069d3d38a2c4c23adba880c4bb9e4d31237c6fc2459a0010000006b483045022100b17a54d3b7f232c4c375d6c656001cac54e674aa3bc8cab3eb176668fbf0a15c02207e35eed554edba90e030e46d90f8d9569a4d6a7139d55eafd9e875c9d3ec2c364121033a69d0acd6e9500844ca078fbc4d81b6c95d7967b3106e31618d5987633d41a9ffffffff02affeea0b000000001976a9146a418bf9e2e2b670e1aa7b7da59391e212b4ba1988ac50c30000000000001976a914c8e0448aa60d8335ef57c1d0e2bdec3aa15f257588ac00000000';
const kFixture2Txid = '05c4d800ac77703bb00e41d8bf9d006c0e52f8405ba92c4506b80ad8f5337ae1';
const kFixture2Height = 1701169;
const kFixture2Index = 279;
const kFixture2BlockHash = '00000000f7a0bacde7375dc096edf7e03a23535d7d6f1e4b02624087a1417206';
const kFixture2Nodes = [
  '2d2711122c3d1822932db91aa9afa2128c9e26b5c4b8df7b9a955c48d0bfc785',
  '795b148effccae8eaaf41f09ed19124b38680cf2b89016dae850dc17a5966b7e',
  '957235d9bd6ce92c5676cfe4ec77a3c2d19910ced8bd4ebe7ffa5490ceade34f',
  '910c626fdf40242c134458696159f5176223f3b7f72a4ad74fefad65433b5433',
  '34a6ea9a52e82ca75cf496ae6255bca7b05f99e380904779684cc5f0f941688e',
  '3d706f13140a933e2ce72cacec0e0f89b6b4378907e3a39c8a22b2a2d2a6b1e7',
  '593d05f1d07fb22d7b93d9f1a1739f0827b4b6363e68f6c750e4b58206aa5790',
  'eced437fa3685318afe3f9c89c184b04f255ab3059335754acdaf9c3b0197158',
  '9d8b401b6fd46c8dae3fb5b3013a6b76d05333215691be9bbd386908b257061e',
];

/// Testnet block 1701169 (hashes to [kFixture2BlockHash]).
BlockHeader fixture2Header() => BlockHeader(
      version: 536870912,
      prevBlock: Hash.fromHex('000000003eb61d855e28f2d1f7913f64988c6c3bd89e00608bc7ac9b175922c3'),
      merkleRoot: Hash.fromHex('750cfb89611c186c935980567ad1a4b1cec0e033ba2373151a51a7e87b122612'),
      timestamp: DateTime.fromMillisecondsSinceEpoch(1761722800 * 1000),
      bits: 0x1d00ffff,
      nonce: 1259571457,
    );

String fixture2BumpHex() => BUMP.fromTscProof(
      blockHeight: kFixture2Height,
      txid: kFixture2Txid,
      index: kFixture2Index,
      nodes: kFixture2Nodes,
    ).toHex();

Uint8List displayHexToInternal(String displayHex) =>
    Uint8List.fromList(hex.decode(displayHex).reversed.toList());
