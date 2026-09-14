/// libspiffy-aao: BlockHeaderChain.validateMerkleProof walked
/// MerkleProof.merkleProof as a list of sibling hashes (hex-string hashing,
/// no byte-order handling), but since SPV-06 every stored proof is
/// `[rawBumpHex]`. A genuine stored proof therefore never validated.
///
/// Fixture: a real testnet transaction, its real proof and the real header
/// of its block (test/spv/testnet_proof_fixture.dart).
import 'package:libspiffy/src/spv/block_header_chain.dart';
import 'package:libspiffy/src/spv/network_params.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';
import 'package:libspiffy/src/storage/read_model_storage.dart';
import 'package:test/test.dart';

import 'testnet_proof_fixture.dart';

void main() {
  late InMemoryWalletStorage storage;
  late BlockHeaderChain chain;

  MerkleProof stored(List<String> merkleProof, {int height = kFixtureHeight}) => MerkleProof(
        blockHash: kFixtureBlockHash,
        txid: kFixtureTxid,
        merkleProof: merkleProof,
        position: kFixtureIndex,
        blockHeight: height,
      );

  setUp(() {
    storage = InMemoryWalletStorage();
    chain = BlockHeaderChain(storage, params: NetworkParams.testnet);
  });

  group('validateMerkleProof on stored [rawBumpHex] proofs (libspiffy-aao)', () {
    test('a genuine BUMP proof validates against the header at its height', () async {
      await storage.storeBlockHeader(fixtureHeader(), kFixtureHeight);
      expect(await chain.validateMerkleProof(stored([fixtureBumpHex()])), isTrue);
    });

    test('a BUMP with a tampered sibling does not validate', () async {
      await storage.storeBlockHeader(fixtureHeader(), kFixtureHeight);
      expect(await chain.validateMerkleProof(stored([fixtureBumpHex(tamperLevel: 3)])), isFalse);
    });

    test('a genuine BUMP does not validate against a different header at that height', () async {
      await storage.storeBlockHeader(otherHeaderAtFixtureHeight(), kFixtureHeight);
      expect(await chain.validateMerkleProof(stored([fixtureBumpHex()])), isFalse);
    });

    test('no header at the proof height: not valid', () async {
      expect(await chain.validateMerkleProof(stored([fixtureBumpHex()])), isFalse);
    });

    test('a proof whose blockHeight disagrees with the BUMP height is rejected', () async {
      await storage.storeBlockHeader(fixtureHeader(), kFixtureHeight);
      await storage.storeBlockHeader(fixtureHeader(), kFixtureHeight + 1);
      expect(
          await chain.validateMerkleProof(stored([fixtureBumpHex()], height: kFixtureHeight + 1)),
          isFalse);
    });

    test('the legacy sibling-list form is rejected, not misread', () async {
      await storage.storeBlockHeader(fixtureHeader(), kFixtureHeight);
      expect(await chain.validateMerkleProof(stored(fixtureNodes())), isFalse);
      expect(await chain.validateMerkleProof(stored([])), isFalse);
      expect(await chain.validateMerkleProof(stored([fixtureBumpHex(), fixtureBumpHex()])), isFalse);
    });
  });
}
