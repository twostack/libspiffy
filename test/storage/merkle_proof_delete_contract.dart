/// `ReadModelStorage.deleteMerkleProof` (audit 3b0), run against every
/// backend: a confirmation taken back after a reorganization drops exactly
/// the orphaned proof, never a newer one stored in the meantime.
library;

import 'package:test/test.dart';

import 'package:libspiffy/src/storage/read_model_storage.dart';

Future<void> runMerkleProofDeleteContract(ReadModelStorage storage, {String suffix = ''}) async {
  final txid = 'ab' * 31 + (suffix.isEmpty ? '01' : suffix);
  final otherTxid = 'cd' * 31 + (suffix.isEmpty ? '01' : suffix);
  MerkleProof proof(String id, String blockHash, String bumpHex) => MerkleProof(
        txid: id,
        blockHash: blockHash,
        blockHeight: 7,
        merkleProof: [bumpHex],
        position: 0,
      );

  await storage.storeMerkleProof(txid, proof(txid, 'orphaned-block', 'aa01'));
  await storage.storeMerkleProof(otherTxid, proof(otherTxid, 'orphaned-block', 'bb01'));

  // A different proof than the one named is kept.
  expect(await storage.deleteMerkleProof(txid, onlyIfMerkleProof: ['ffff']), isFalse);
  expect(await storage.getMerkleProof(txid), isNotNull);

  // The named proof is deleted, and only for that txid.
  expect(await storage.deleteMerkleProof(txid, onlyIfMerkleProof: ['aa01']), isTrue);
  expect(await storage.getMerkleProof(txid), isNull);
  expect((await storage.getMerkleProofsForBlock('orphaned-block')).map((p) => p.txid), [otherTxid]);
  expect(await storage.getMerkleProof(otherTxid), isNotNull);

  // Idempotent.
  expect(await storage.deleteMerkleProof(txid, onlyIfMerkleProof: ['aa01']), isFalse);

  // A newer proof (re-mined on the active chain) survives a stale delete.
  await storage.storeMerkleProof(txid, proof(txid, 'active-block', 'aa02'));
  expect(await storage.deleteMerkleProof(txid, onlyIfMerkleProof: ['aa01']), isFalse);
  expect((await storage.getMerkleProof(txid))!.blockHash, 'active-block');

  // Unconditional delete.
  expect(await storage.deleteMerkleProof(otherTxid), isTrue);
  expect(await storage.getMerkleProof(otherTxid), isNull);
  expect(await storage.getMerkleProofsForBlock('orphaned-block'), isEmpty);
}
