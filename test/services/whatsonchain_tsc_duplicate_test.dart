import 'dart:convert';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:libspiffy/src/services/whatsonchain_data_source.dart';
import 'package:libspiffy/src/utils/tsc_converter.dart';
import 'package:test/test.dart';

/// Audit 2026-09-14 SPV-08: WhatsOnChain TSC proofs mark "pair the working
/// hash with itself" with a "*" node. The data source dropped those entries,
/// so the proof handed to TscConverter described a different (shorter) path
/// and the computed root was wrong for every transaction whose path crosses
/// an odd level.
void main() {
  Uint8List sha256d(List<int> data) =>
      Uint8List.fromList(sha256.convert(sha256.convert(data).bytes).bytes);
  Uint8List hashPair(Uint8List l, Uint8List r) => sha256d([...l, ...r]);
  String display(Uint8List internal) => hex.encode(internal.reversed.toList());

  // 5-leaf block; the proved tx is leaf 4: level 0 sibling = duplicate,
  // level 1 sibling = duplicate, level 2 sibling = H(H(0,1), H(2,3)).
  final leaves = List.generate(5, (i) => sha256d(utf8.encode('woc-star-leaf-$i')));
  final l1 = [
    hashPair(leaves[0], leaves[1]),
    hashPair(leaves[2], leaves[3]),
    hashPair(leaves[4], leaves[4]),
  ];
  final l2 = [hashPair(l1[0], l1[1]), hashPair(l1[2], l1[2])];
  final root = hashPair(l2[0], l2[1]);
  final txid = display(leaves[4]);

  WhatsOnChainDataSource source(dynamic proofBody) => WhatsOnChainDataSource(
        networkType: 'test',
        client: MockClient((request) async {
          final path = request.url.path;
          if (path.endsWith('/tx/$txid/proof/tsc')) {
            return http.Response(json.encode(proofBody), 200);
          }
          if (path.endsWith('/tx/hash/$txid')) {
            return http.Response(json.encode({'txid': txid, 'blockheight': 77}), 200);
          }
          return http.Response('unexpected ${request.url}', 404);
        }),
      );

  final tscBody = [
    {
      'index': 4,
      'txOrId': txid,
      'target': display(root),
      'nodes': ['*', '*', display(l2[0])],
    }
  ];

  test('getMerkleProof keeps "*" duplicate markers in the node list', () async {
    final proof = await source(tscBody).getMerkleProof(txid);
    expect(proof.index, 4);
    expect(proof.blockHeight, 77);
    expect(proof.nodes, ['*', '*', display(l2[0])]);
  });

  test('the fetched proof converts to a BUMP that reaches the block merkle root', () async {
    final proof = await source(tscBody).getMerkleProof(txid);
    final bump = TscConverter().convertToBump(proof);
    expect(hex.encode(bump.computeMerkleRoot(leaves[4])), hex.encode(root));
  });

  test('"*" markers survive the map-shaped response too', () async {
    final proof = await source(tscBody.single).getMerkleProof(txid);
    expect(proof.nodes, ['*', '*', display(l2[0])]);
  });
}
