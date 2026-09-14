import 'dart:convert';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:libspiffy/src/services/node_rpc_data_source.dart';
import 'package:libspiffy/src/utils/tsc_converter.dart';
import 'package:test/test.dart';

/// Audit 2026-09-14 SPV-14: for a single-transaction block the node-RPC data
/// source reported the txid as its own sibling, so the converted proof
/// computed hash(txid || txid) instead of the real root, which is the txid.
/// Also covers the "*" duplicate marker the source must emit for odd levels
/// (SPV-08) so the TSC proof reaches the block's merkle root.
void main() {
  Uint8List sha256d(List<int> data) =>
      Uint8List.fromList(sha256.convert(sha256.convert(data).bytes).bytes);
  Uint8List hashPair(Uint8List l, Uint8List r) => sha256d([...l, ...r]);
  String display(Uint8List internal) => hex.encode(internal.reversed.toList());

  final blockHash = '00' * 32;

  /// A mock node whose block [blockHash] at height 900 holds [txids] (display
  /// hex, in order) with merkle root [merkleRoot].
  NodeRpcDataSource node(List<String> txids, String merkleRoot) => NodeRpcDataSource(
        rpcUrl: 'http://node.test',
        rpcUser: 'u',
        rpcPassword: 'p',
        client: MockClient((request) async {
          final call = json.decode(request.body) as Map<String, dynamic>;
          final params = call['params'] as List;
          dynamic result;
          switch (call['method']) {
            case 'getrawtransaction':
              result = {'txid': params[0], 'blockhash': blockHash, 'blockheight': 900};
              break;
            case 'getblock':
              result = {'hash': blockHash, 'height': 900, 'tx': txids, 'merkleroot': merkleRoot};
              break;
            default:
              return http.Response('unknown method', 500);
          }
          return http.Response(json.encode({'result': result, 'error': null, 'id': call['id']}), 200);
        }),
      );

  test('single-transaction block: empty path, root is the txid', () async {
    final txid = sha256d(utf8.encode('node-rpc-only-tx'));
    final proof = await node([display(txid)], display(txid)).getMerkleProof(display(txid));

    expect(proof.index, 0);
    expect(proof.nodes, isEmpty, reason: 'the txid must not be its own sibling');

    final bump = TscConverter().convertToBump(proof);
    expect(bump.path.length, 1);
    expect(bump.path[0].leaves.single.isTxid, isTrue);
    expect(hex.encode(bump.computeMerkleRoot(txid)), hex.encode(txid));
    expect(bump.validateMerklePath(txid, expectedMerkleRoot: txid), isTrue);
  });

  test('three-transaction block: the last tx gets a "*" duplicate sibling', () async {
    final leaves = List.generate(3, (i) => sha256d(utf8.encode('node-rpc-tx-$i')));
    final l1 = [hashPair(leaves[0], leaves[1]), hashPair(leaves[2], leaves[2])];
    final root = hashPair(l1[0], l1[1]);
    final txids = leaves.map(display).toList();

    final proof = await node(txids, display(root)).getMerkleProof(txids[2]);
    expect(proof.index, 2);
    expect(proof.nodes, ['*', display(l1[0])]);

    final bump = TscConverter().convertToBump(proof);
    expect(hex.encode(bump.computeMerkleRoot(leaves[2])), hex.encode(root));
  });
}
