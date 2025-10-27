import 'dart:convert';
import 'dart:typed_data';
import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart';
import 'package:libspiffy/libspiffy.dart';
import 'package:libspiffy/src/utils/crypto_utils.dart';
import 'package:test/test.dart';

/// Reverses bytes in a hex string (for Bitcoin's little-endian format)
String reverseBytes(String hexString) {
  if (hexString.length % 2 != 0) {
    throw Exception('Hex string must have an even number of characters');
  }

  final result = StringBuffer();
  for (int i = hexString.length - 2; i >= 0; i -= 2) {
    result.write(hexString.substring(i, i + 2));
  }
  return result.toString();
}

/// Computes double SHA256 hash (Bitcoin's standard hash function)
Uint8List doubleSha256(Uint8List data) {
  final firstHash = sha256.convert(data);
  final secondHash = sha256.convert(firstHash.bytes);
  return Uint8List.fromList(secondHash.bytes);
}

/// Computes merkle root from TSC proof format
/// 
/// Algorithm matches BUMP.computeMerkleRoot:
/// - Work with hashes in display format (big-endian)
/// - Reverse to internal format (little-endian) only for hashing
/// - Reverse result back to display format after each hash
/// 
/// Returns the computed merkle root in display format (big-endian)
String computeMerkleRootFromTsc(String txId, List<String> nodes, int index) {
  // Start with the transaction hash in display format (big-endian)
  String currentHash = txId;
  int currentIndex = index;
  
  // Process each sibling node, moving up the merkle tree
  for (final node in nodes) {
    // Both currentHash and node are in display format (big-endian)
    // Determine if current hash is on left or right
    bool isLeftSide = (currentIndex % 2 == 0);
    
    // Reverse both hashes to internal format (little-endian) for hashing
    String reversedCurrentHash = reverseBytes(currentHash);
    String reversedNode = reverseBytes(node);
    
    // Concatenate based on position
    String concatenated;
    if (isLeftSide) {
      // Our hash is on the left, sibling on the right
      concatenated = reversedCurrentHash + reversedNode;
    } else {
      // Our hash is on the right, sibling on the left
      concatenated = reversedNode + reversedCurrentHash;
    }
    
    // Convert to bytes and double SHA256
    final bytes = hex.decode(concatenated);
    final hashed = doubleSha256(Uint8List.fromList(bytes));
    
    // Reverse result back to display format (big-endian) for next iteration
    currentHash = reverseBytes(hex.encode(hashed));
    
    // Move up to the next level
    currentIndex = currentIndex ~/ 2;
  }
  
  // Return the final merkle root reversed (to match BUMP.computeMerkleRoot format)
  // BUMP returns bytes in big-endian, then test reverses them
  return reverseBytes(currentHash);
}

BUMP buildBUMPFromMerkleProof(MerkleProof proof) {
  final levels = <Level>[];

  // Level 0: Transaction ID at its position in the block
  // IMPORTANT: Reverse bytes from display format (big-endian) to internal format (little-endian)
  levels.add(Level(leaves: [
    Leaf(
      offset: proof.position,
      duplicate: false,
      isTxid: true,
      hash: Uint8List.fromList(hex.decode(reverseBytes(proof.txid))),
    ),
  ]));

  // Subsequent levels: merkle path siblings with calculated offsets
  // Each hash in the merkleProof list is a sibling at the next level up
  // Sibling offset calculation matches CryptoUtils.createBumpFromTscProof()
  for (int i = 0; i < proof.merkleProof.length; i++) {
    // Calculate sibling offset using bit manipulation
    // In a Merkle tree, if index bit at level i is 0, then sibling is at (index | (1 << i))
    // If index bit at level i is 1, then sibling is at (index & ~(1 << i))
    final indexBit = (proof.position >> i) & 1;
    final siblingOffset = indexBit == 0
        ? (proof.position | (1 << i))
        : (proof.position & ~(1 << i));

    levels.add(Level(leaves: [
      Leaf(
        offset: siblingOffset,
        duplicate: false,
        isTxid: false,
        hash:
            Uint8List.fromList(hex.decode(reverseBytes(proof.merkleProof[i]))),
      ),
    ]));
  }

  return BUMP(
    blockHeight: proof.blockHeight,
    path: levels,
  );
}

void main() {
  // Real WhatsOnChain API proof for transaction:
  // a05924fcc63712d3e4b94b0c88baad234c2c8ad3d369704f53765e21a53a2101
  // From: https://api.whatsonchain.com/v1/bsv/test/tx/{txid}/proof
  final whatsOnChainProof = '''
      {
        "blockHash": "000000001539f91cede66262caa22d1b504d09aa1dc3221f7fac5b30c2f7d65d",
        "branches": [
          {"hash": "405649f55c4a98a3f83e6d780bb44297035d4a3652d9ddc9dc50799bed17b62b", "pos": "R"},
          {"hash": "750e25837b6188f87387b1eb18604e9fe07aa32fb80221e7a1c7d7e04427c8e0", "pos": "L"},
          {"hash": "3980d9a3572b903c74302a586c923ce0bf26d979a23290a28750cb2e1cc19199", "pos": "R"},
          {"hash": "2b6da3206c7aed19f0bc6c68826f86638c1f9214a6b3eead3d7121381a82549d", "pos": "R"},
          {"hash": "5d3e8be2af6e109196a14a81dc6f99e17d7420eddf1d31a1a50fb2ef6933e3a1", "pos": "R"},
          {"hash": "c4f09f1a5fb1e66a95b66ca7502062292708597c7e15574fc6dd1f9bcc7d2f5a", "pos": "R"}
        ],
        "hash": "a05924fcc63712d3e4b94b0c88baad234c2c8ad3d369704f53765e21a53a2101",
        "merkleRoot": "4823b3e0a9801d019c49af6ecd923f5250cc828e7be4fb6b4c5afbb979e33b34"
      }
      ''';

  // Convert WhatsOnChain format to TSC format for testing
  final tscFormatProof = '''
      {"index":2,
      "txOrId":"a05924fcc63712d3e4b94b0c88baad234c2c8ad3d369704f53765e21a53a2101",
      "target":"4823b3e0a9801d019c49af6ecd923f5250cc828e7be4fb6b4c5afbb979e33b34",
      "nodes":[
      "405649f55c4a98a3f83e6d780bb44297035d4a3652d9ddc9dc50799bed17b62b",
      "750e25837b6188f87387b1eb18604e9fe07aa32fb80221e7a1c7d7e04427c8e0",
      "3980d9a3572b903c74302a586c923ce0bf26d979a23290a28750cb2e1cc19199",
      "2b6da3206c7aed19f0bc6c68826f86638c1f9214a6b3eead3d7121381a82549d",
      "5d3e8be2af6e109196a14a81dc6f99e17d7420eddf1d31a1a50fb2ef6933e3a1",
      "c4f09f1a5fb1e66a95b66ca7502062292708597c7e15574fc6dd1f9bcc7d2f5a"]}
      ''';

  const blockHeight = 1239645;

  test('TSC format merkle proof verification', () {
    // Parse TSC proof
    final tscProof = json.decode(tscFormatProof);
    final txId = tscProof['txOrId'] as String;
    final expectedTarget = tscProof['target'] as String;
    final nodes = (tscProof['nodes'] as List).cast<String>();
    final index = tscProof['index'] as int;

    print('\n=== TSC Proof Debug Info ===');
    print('Transaction ID: $txId');
    print('Index: $index');
    print('Number of nodes: ${nodes.length}');
    print('Expected target: $expectedTarget');
    print('\nNodes:');
    for (int i = 0; i < nodes.length; i++) {
      print('  [$i] ${nodes[i]}');
    }

    // Compute merkle root from TSC proof with step-by-step output
    String currentHash = txId;
    int currentIndex = index;
    
    print('\nStep-by-step computation:');
    print('Level 0: hash=$currentHash, index=$currentIndex');
    
    for (int i = 0; i < nodes.length; i++) {
      final node = nodes[i];
      bool isLeftSide = (currentIndex % 2 == 0);
      
      String reversedCurrentHash = reverseBytes(currentHash);
      String reversedNode = reverseBytes(node);
      
      String concatenated;
      if (isLeftSide) {
        concatenated = reversedCurrentHash + reversedNode;
        print('Level ${i + 1}: LEFT  - hash($currentHash | $node)');
      } else {
        concatenated = reversedNode + reversedCurrentHash;
        print('Level ${i + 1}: RIGHT - hash($node | $currentHash)');
      }
      
      final bytes = hex.decode(concatenated);
      final hashed = doubleSha256(Uint8List.fromList(bytes));
      currentHash = reverseBytes(hex.encode(hashed));
      currentIndex = currentIndex ~/ 2;
      
      print('         Result: $currentHash, next index=$currentIndex');
    }
    
    final computedRoot = currentHash;
    print('\nFinal computed root: $computedRoot');
    print('Expected target:     $expectedTarget');
    print('Match: ${computedRoot == expectedTarget}');

    // Verify the computed merkle root matches the expected target (merkle root from WhatsOnChain)
    expect(computedRoot, equals(expectedTarget),
        reason: 'Computed merkle root should match TSC proof target');

    print('\n✅ TSC proof verified successfully!');
    print('   Algorithm correctly computes merkle root from TSC format');
  });

  test('WhatsOnChain proof format verification', () {
    // Parse WhatsOnChain proof
    final wocProof = json.decode(whatsOnChainProof);
    final txId = wocProof['hash'] as String;
    final expectedMerkleRoot = wocProof['merkleRoot'] as String;
    final blockHash = wocProof['blockHash'] as String;
    final branches = wocProof['branches'] as List;
    
    // Extract nodes from branches (ignoring position for now, we compute it from index)
    final nodes = branches.map((b) => b['hash'] as String).toList();
    
    // Compute merkle root (index 2 based on the position pattern)
    // Note: computeMerkleRootFromTsc returns in BUMP format (reversed), so reverse back
    final computedRootReversed = computeMerkleRootFromTsc(txId, nodes, 2);
    final computedRoot = reverseBytes(computedRootReversed);
    
    // Verify the computed merkle root matches WhatsOnChain's merkleRoot
    expect(computedRoot, equals(expectedMerkleRoot),
        reason: 'Computed merkle root should match WhatsOnChain merkleRoot field');
    
    print('\n✅ WhatsOnChain proof verification passed!');
    print('   Transaction: $txId');
    print('   Computed merkle root: $computedRoot');
    print('   WhatsOnChain merkleRoot: $expectedMerkleRoot');
    print('   Block hash: $blockHash');
    print('\n   Note: Block hash ≠ Merkle root');
    print('   Block hash is the hash of the block header (which includes the merkle root)');
  });

  test('Implementation consistency check', () {
    // Parse TSC proof
    final tscProof = json.decode(tscFormatProof);
    final txId = tscProof['txOrId'] as String;
    final nodes = (tscProof['nodes'] as List).cast<String>();
    final index = tscProof['index'] as int;

    // Compute using my direct implementation
    final myComputedRoot = computeMerkleRootFromTsc(txId, nodes, index);

    // Compute using CryptoUtils -> BUMP -> computeMerkleRoot
    final brc71Path = CryptoUtils.convertTscProofToBrc71Path(tscProof);
    final cUtilBump =
        CryptoUtils.convertBrc71PathToBump(brc71Path, blockHeight, txId);
    final cUtilRoot =
        cUtilBump.computeMerkleRoot(Uint8List.fromList(hex.decode(txId)));
    final cryptoUtilsRoot = hex.encode(cUtilRoot.reversed.toList());

    // Both implementations should produce the same result
    expect(myComputedRoot, equals(cryptoUtilsRoot),
        reason: 'My implementation should match CryptoUtils implementation');

    print('\n✅ Implementation consistency verified');
    print('   Direct TSC computation:  $myComputedRoot');
    print('   CryptoUtils via BUMP:    $cryptoUtilsRoot');
    print('\n✅ Both implementations produce identical results');
  });
}
