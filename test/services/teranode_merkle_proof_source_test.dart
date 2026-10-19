/// The Teranode asset service as a merkle proof source (spiffyvault-ri8):
/// what an answer counts as. The proof itself is checked by the caller.
library;

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:libspiffy/src/services/teranode_merkle_proof_source.dart';
import 'package:test/test.dart';

void main() {
  final txid = '15' * 32;

  TeranodeMerkleProofSource node(http.Response Function(http.Request) answer, {List<Uri>? asked}) =>
      TeranodeMerkleProofSource(
        baseUrl: 'https://node.example/api/v1/',
        client: MockClient((request) async {
          asked?.add(request.url);
          return answer(request);
        }),
      );

  test('asks /merkle_proof/{txid}/hex and answers the BUMP hex', () async {
    final asked = <Uri>[];
    final source = node((_) => http.Response('FE1FE81A0009\n', 200), asked: asked);
    expect(await source.merkleProofHex(txid), 'fe1fe81a0009');
    expect(asked.single.toString(), 'https://node.example/api/v1/merkle_proof/$txid/hex');
  });

  test('a transaction the node does not hold (500, 404) is no proof', () async {
    for (final code in [500, 404, 400]) {
      expect(await node((_) => http.Response('{"message":"NOT_FOUND"}', code)).merkleProofHex(txid), isNull);
    }
  });

  test('a body that is not hex is no proof', () async {
    expect(await node((_) => http.Response('{"blockHeight":1}', 200)).merkleProofHex(txid), isNull);
    expect(await node((_) => http.Response('abc', 200)).merkleProofHex(txid), isNull);
  });

  test('a node that cannot be reached throws', () async {
    final source = node((_) => throw http.ClientException('offline'));
    expect(source.merkleProofHex(txid), throwsA(isA<http.ClientException>()));
  });
}
