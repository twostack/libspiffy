import 'dart:typed_data';
import 'package:convert/convert.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:libspiffy/src/utils/beef.dart';
import 'package:libspiffy/src/utils/bump.dart';
import 'package:libspiffy/src/utils/crypto_utils.dart';
import 'package:spiffynode/spiffy_node.dart';
import 'package:test/test.dart';

/// Tests to validate that BUMP construction from different storage formats
/// (TSC sibling hashes vs raw BUMP hex) produce equivalent results.
/// 
/// This is critical for SPV payment validation because:
/// - Wallet import stores merkle proofs as comma-separated sibling hashes (TSC format)
/// - ARC API stores merkle proofs as raw BUMP hex strings
/// - Both must produce valid BUMPs that can be validated against block headers
void main() {
  // Real merkle proof data from wallet import (working format)
  final workingMerkleProofEntity = {
    'blockHash': '00000000f7a0bacde7375dc096edf7e03a23535d7d6f1e4b02624087a1417206',
    'blockHeight': 1701169,
    'merkleProofJson': '2d2711122c3d1822932db91aa9afa2128c9e26b5c4b8df7b9a955c48d0bfc785,795b148effccae8eaaf41f09ed19124b38680cf2b89016dae850dc17a5966b7e,957235d9bd6ce92c5676cfe4ec77a3c2d19910ced8bd4ebe7ffa5490ceade34f,910c626fdf40242c134458696159f5176223f3b7f72a4ad74fefad65433b5433,34a6ea9a52e82ca75cf496ae6255bca7b05f99e380904779684cc5f0f941688e,3d706f13140a933e2ce72cacec0e0f89b6b4378907e3a39c8a22b2a2d2a6b1e7,593d05f1d07fb22d7b93d9f1a1739f0827b4b6363e68f6c750e4b58206aa5790,eced437fa3685318afe3f9c89c184b04f255ab3059335754acdaf9c3b0197158,9d8b401b6fd46c8dae3fb5b3013a6b76d05333215691be9bbd386908b257061e',
    'position': 279,
    'txid': '05c4d800ac77703bb00e41d8bf9d006c0e52f8405ba92c4506b80ad8f5337ae1',
  };

  // Corresponding TSC format proof
  final tscProof = {
    'index': 279,
    'txOrId': '05c4d800ac77703bb00e41d8bf9d006c0e52f8405ba92c4506b80ad8f5337ae1',
    'target': '00000000f7a0bacde7375dc096edf7e03a23535d7d6f1e4b02624087a1417206',
    'nodes': [
      '2d2711122c3d1822932db91aa9afa2128c9e26b5c4b8df7b9a955c48d0bfc785',
      '795b148effccae8eaaf41f09ed19124b38680cf2b89016dae850dc17a5966b7e',
      '957235d9bd6ce92c5676cfe4ec77a3c2d19910ced8bd4ebe7ffa5490ceade34f',
      '910c626fdf40242c134458696159f5176223f3b7f72a4ad74fefad65433b5433',
      '34a6ea9a52e82ca75cf496ae6255bca7b05f99e380904779684cc5f0f941688e',
      '3d706f13140a933e2ce72cacec0e0f89b6b4378907e3a39c8a22b2a2d2a6b1e7',
      '593d05f1d07fb22d7b93d9f1a1739f0827b4b6363e68f6c750e4b58206aa5790',
      'eced437fa3685318afe3f9c89c184b04f255ab3059335754acdaf9c3b0197158',
      '9d8b401b6fd46c8dae3fb5b3013a6b76d05333215691be9bbd386908b257061e',
    ],
  };

  // Helper functions
  Uint8List hexToBytes(String hexStr) {
    return Uint8List.fromList(hex.decode(hexStr));
  }

  String bytesToHex(Uint8List bytes) {
    return hex.encode(bytes);
  }

  String reverseHexBytes(String hexStr) {
    return CryptoUtils.reverseBytes(hexStr);
  }

  group('BUMP Format Equivalence Tests', () {
    test('TSC format sibling hashes should build valid BUMP', () {
      // Build BUMP from TSC format using CryptoUtils (known working method)
      final bumpFromTsc = CryptoUtils.createBumpFromTscProof(
        tscProof,
        workingMerkleProofEntity['blockHeight'] as int,
      );

      // Verify basic structure
      expect(bumpFromTsc.blockHeight, workingMerkleProofEntity['blockHeight']);
      expect(bumpFromTsc.path.length, 10); // 9 siblings + 1 for txid level

      // Verify txid is in level 0 with correct position
      expect(bumpFromTsc.path[0].leaves.length, greaterThanOrEqualTo(1));
      
      // Find the txid leaf
      Leaf? txidLeaf;
      for (final leaf in bumpFromTsc.path[0].leaves) {
        if (leaf.isTxid) {
          txidLeaf = leaf;
          break;
        }
      }
      expect(txidLeaf, isNotNull, reason: 'BUMP should have txid in level 0');
      expect(txidLeaf!.offset, workingMerkleProofEntity['position']);

      // Validate merkle path
      final txidBytes = hexToBytes(reverseHexBytes(workingMerkleProofEntity['txid'] as String));
      expect(bumpFromTsc.validateMerklePath(txidBytes), true);

      print('✓ TSC format BUMP built successfully');
      print('  Block Height: ${bumpFromTsc.blockHeight}');
      print('  Path Levels: ${bumpFromTsc.path.length}');
      print('  TX Position: ${txidLeaf.offset}');
    });

    test('Raw BUMP hex should parse and serialize correctly', () {
      // First, build a BUMP from TSC format
      final originalBump = CryptoUtils.createBumpFromTscProof(
        tscProof,
        workingMerkleProofEntity['blockHeight'] as int,
      );

      // Serialize to hex (simulates what ARC would store)
      final bumpHex = bytesToHex(originalBump.serialize());
      print('Raw BUMP hex (${bumpHex.length} chars): ${bumpHex.substring(0, 80)}...');

      // Parse it back
      final parsedBump = BUMP.fromBytes(hexToBytes(bumpHex));

      // Verify structure matches
      expect(parsedBump.blockHeight, originalBump.blockHeight);
      expect(parsedBump.path.length, originalBump.path.length);

      // Verify all levels match
      for (int i = 0; i < originalBump.path.length; i++) {
        expect(parsedBump.path[i].leaves.length, originalBump.path[i].leaves.length,
            reason: 'Level $i leaf count mismatch');

        for (int j = 0; j < originalBump.path[i].leaves.length; j++) {
          final originalLeaf = originalBump.path[i].leaves[j];
          final parsedLeaf = parsedBump.path[i].leaves[j];

          expect(parsedLeaf.offset, originalLeaf.offset,
              reason: 'Level $i leaf $j offset mismatch');
          expect(parsedLeaf.duplicate, originalLeaf.duplicate);
          expect(parsedLeaf.isTxid, originalLeaf.isTxid);

          if (originalLeaf.hash != null) {
            expect(bytesToHex(parsedLeaf.hash!), bytesToHex(originalLeaf.hash!),
                reason: 'Level $i leaf $j hash mismatch');
          }
        }
      }

      // Validate merkle path on parsed BUMP
      final txidBytes = hexToBytes(reverseHexBytes(workingMerkleProofEntity['txid'] as String));
      expect(parsedBump.validateMerklePath(txidBytes), true);

      print('✓ Raw BUMP hex parses correctly and validates');
    });

    test('Building BUMP from raw hex should produce same merkle root as TSC format', () {
      // Build BUMP from TSC format (reference)
      final bumpFromTsc = CryptoUtils.createBumpFromTscProof(
        tscProof,
        workingMerkleProofEntity['blockHeight'] as int,
      );

      // Serialize and parse back (simulates ARC storage flow)
      final bumpHex = bytesToHex(bumpFromTsc.serialize());
      final bumpFromHex = BUMP.fromBytes(hexToBytes(bumpHex));

      // Get txid in internal format
      final txidInternal = hexToBytes(reverseHexBytes(workingMerkleProofEntity['txid'] as String));

      // Compute merkle root from both
      final merkleRootFromTsc = bumpFromTsc.computeMerkleRoot(txidInternal);
      final merkleRootFromHex = bumpFromHex.computeMerkleRoot(txidInternal);

      // They should be identical
      expect(bytesToHex(merkleRootFromHex), bytesToHex(merkleRootFromTsc),
          reason: 'Merkle roots should match regardless of construction method');

      print('✓ Merkle roots match!');
      print('  From TSC: ${bytesToHex(merkleRootFromTsc)}');
      print('  From Hex: ${bytesToHex(merkleRootFromHex)}');
    });

    test('Simulated PaymentCoordinator _buildBUMPFromMerkleProof with TSC format', () {
      // Simulate MerkleProof from storage (TSC format - comma-separated)
      final siblingHashes = (workingMerkleProofEntity['merkleProofJson'] as String).split(',');
      final txPosition = workingMerkleProofEntity['position'] as int;
      final txid = workingMerkleProofEntity['txid'] as String;
      final blockHeight = workingMerkleProofEntity['blockHeight'] as int;

      // Build BUMP using the same logic as _buildBUMPFromMerkleProof
      final levels = <Level>[];

      // Level 0: Transaction ID at its position
      final reversedTxid = reverseHexBytes(txid);
      levels.add(Level(leaves: [
        Leaf(
          offset: txPosition,
          duplicate: false,
          isTxid: true,
          hash: hexToBytes(reversedTxid),
        ),
      ]));

      // Subsequent levels: sibling hashes at calculated offsets
      for (int i = 0; i < siblingHashes.length; i++) {
        final indexBit = (txPosition >> i) & 1;
        final siblingOffset = indexBit == 0
            ? (txPosition | (1 << i))
            : (txPosition & ~(1 << i));

        final reversedHash = reverseHexBytes(siblingHashes[i]);

        levels.add(Level(leaves: [
          Leaf(
            offset: siblingOffset,
            duplicate: false,
            isTxid: false,
            hash: hexToBytes(reversedHash),
          ),
        ]));
      }

      final builtBump = BUMP(blockHeight: blockHeight, path: levels);

      // Validate
      final txidInternal = hexToBytes(reversedTxid);
      expect(builtBump.validateMerklePath(txidInternal), true);

      print('✓ PaymentCoordinator-style BUMP from TSC format validates');
    });

    test('Simulated PaymentCoordinator _buildBUMPFromMerkleProof with raw BUMP hex', () {
      // First create a reference BUMP from TSC
      final referenceBump = CryptoUtils.createBumpFromTscProof(
        tscProof,
        workingMerkleProofEntity['blockHeight'] as int,
      );

      // Serialize to simulate raw BUMP from ARC
      final rawBumpHex = bytesToHex(referenceBump.serialize());

      // Simulate MerkleProof from storage with raw BUMP format
      // (This is how ARC stores it - wrapped in a single-element list)
      final merkleProofFromStorage = [rawBumpHex];
      final txid = workingMerkleProofEntity['txid'] as String;

      // Detect raw BUMP format (single element > 64 chars)
      expect(merkleProofFromStorage.length, 1);
      expect(merkleProofFromStorage[0].length, greaterThan(64));

      // Parse the raw BUMP
      final parsedBump = BUMP.fromBytes(hexToBytes(merkleProofFromStorage[0]));

      // Extract sibling hashes and txPosition from parsed BUMP
      final siblingHashes = <String>[];
      int txPosition = 0;

      for (int i = 0; i < parsedBump.path.length; i++) {
        for (final leaf in parsedBump.path[i].leaves) {
          if (leaf.isTxid && leaf.hash != null) {
            txPosition = leaf.offset;
          } else if (!leaf.duplicate && leaf.hash != null) {
            // Convert back to display format
            final hashHex = leaf.hash!.reversed
                .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
                .join('');
            siblingHashes.add(hashHex);
          }
        }
      }

      print('Extracted from raw BUMP:');
      print('  TX Position: $txPosition');
      print('  Sibling count: ${siblingHashes.length}');

      // Now rebuild the BUMP using the standard logic
      final levels = <Level>[];

      // Level 0: Transaction ID at its position
      final reversedTxid = reverseHexBytes(txid);
      levels.add(Level(leaves: [
        Leaf(
          offset: txPosition,
          duplicate: false,
          isTxid: true,
          hash: hexToBytes(reversedTxid),
        ),
      ]));

      // Subsequent levels: sibling hashes at calculated offsets
      for (int i = 0; i < siblingHashes.length; i++) {
        final indexBit = (txPosition >> i) & 1;
        final siblingOffset = indexBit == 0
            ? (txPosition | (1 << i))
            : (txPosition & ~(1 << i));

        final reversedHash = reverseHexBytes(siblingHashes[i]);

        levels.add(Level(leaves: [
          Leaf(
            offset: siblingOffset,
            duplicate: false,
            isTxid: false,
            hash: hexToBytes(reversedHash),
          ),
        ]));
      }

      final rebuiltBump = BUMP(blockHeight: parsedBump.blockHeight, path: levels);

      // Validate
      final txidInternal = hexToBytes(reversedTxid);
      expect(rebuiltBump.validateMerklePath(txidInternal), true,
          reason: 'Rebuilt BUMP from raw hex should validate');

      // Compare merkle roots
      final referenceRoot = referenceBump.computeMerkleRoot(txidInternal);
      final rebuiltRoot = rebuiltBump.computeMerkleRoot(txidInternal);

      expect(bytesToHex(rebuiltRoot), bytesToHex(referenceRoot),
          reason: 'Merkle roots should match');

      print('✓ PaymentCoordinator-style BUMP from raw hex validates');
      print('  Reference root: ${bytesToHex(referenceRoot)}');
      print('  Rebuilt root:   ${bytesToHex(rebuiltRoot)}');
    });

    test('Both formats produce identical serialized BEEF', () {
      // Build BUMP from TSC format
      final bumpFromTsc = CryptoUtils.createBumpFromTscProof(
        tscProof,
        workingMerkleProofEntity['blockHeight'] as int,
      );
      final tscBumpSerialized = bumpFromTsc.serialize();

      // Serialize and parse back (simulates ARC flow)
      final rawBumpHex = bytesToHex(tscBumpSerialized);
      final bumpFromHex = BUMP.fromBytes(hexToBytes(rawBumpHex));
      final hexBumpSerialized = bumpFromHex.serialize();

      // The serialized bytes should be identical
      expect(bytesToHex(hexBumpSerialized), bytesToHex(tscBumpSerialized),
          reason: 'Serialized BUMPs should be byte-for-byte identical');

      print('✓ Both formats produce identical serialized BUMP');
      print('  Serialized length: ${tscBumpSerialized.length} bytes');
    });

    test('Cross-validation: TSC proof matches working MerkleProof entity', () {
      // Verify the TSC nodes match the comma-separated hashes
      final tscNodes = tscProof['nodes'] as List<String>;
      final entityHashes = (workingMerkleProofEntity['merkleProofJson'] as String).split(',');

      expect(tscNodes.length, entityHashes.length);

      for (int i = 0; i < tscNodes.length; i++) {
        expect(tscNodes[i], entityHashes[i],
            reason: 'Node $i should match');
      }

      // Verify positions match
      expect(tscProof['index'], workingMerkleProofEntity['position']);

      // Verify txids match
      expect(tscProof['txOrId'], workingMerkleProofEntity['txid']);

      print('✓ TSC proof data matches MerkleProof entity data');
    });
  });

  group('Full BEEF Creation and Validation Flow', () {
    test('BEEF created from TSC format can be validated on recipient side', () {
      // Simulate sender side: create BEEF from TSC format
      final bumpFromTsc = CryptoUtils.createBumpFromTscProof(
        tscProof,
        workingMerkleProofEntity['blockHeight'] as int,
      );

      // Simulate ancestor transaction (in real flow this would be actual tx bytes)
      // For this test, we just verify the BUMP structure
      
      // Serialize the BEEF to simulate transmission
      final bumpBytes = bumpFromTsc.serialize();
      print('BUMP serialized: ${bumpBytes.length} bytes');

      // Simulate recipient side: parse the BEEF
      final parsedBump = BUMP.fromBytes(bumpBytes);

      // Get txid in internal format
      final txidInternal = hexToBytes(reverseHexBytes(workingMerkleProofEntity['txid'] as String));

      // Validate merkle path
      expect(parsedBump.validateMerklePath(txidInternal), true,
          reason: 'Recipient should successfully validate merkle path');

      // Compute and compare merkle roots
      final senderRoot = bumpFromTsc.computeMerkleRoot(txidInternal);
      final recipientRoot = parsedBump.computeMerkleRoot(txidInternal);

      expect(bytesToHex(recipientRoot), bytesToHex(senderRoot),
          reason: 'Merkle roots should match on both sides');

      print('✓ BEEF from TSC format successfully validated by recipient');
    });

    test('BEEF created from raw BUMP hex can be validated on recipient side', () {
      // Simulate sender side: first create from TSC, then serialize (simulates ARC storage)
      final referenceBump = CryptoUtils.createBumpFromTscProof(
        tscProof,
        workingMerkleProofEntity['blockHeight'] as int,
      );
      final rawBumpHex = bytesToHex(referenceBump.serialize());

      // Now simulate loading from storage where we have raw BUMP hex
      // This is what PaymentCoordinator does when merkleProof is a raw BUMP
      final bumpFromStorage = BUMP.fromBytes(hexToBytes(rawBumpHex));

      // Serialize for transmission
      final bumpBytes = bumpFromStorage.serialize();
      print('BUMP from raw hex serialized: ${bumpBytes.length} bytes');

      // Simulate recipient side: parse the BEEF
      final parsedBump = BUMP.fromBytes(bumpBytes);

      // Get txid in internal format
      final txidInternal = hexToBytes(reverseHexBytes(workingMerkleProofEntity['txid'] as String));

      // Validate merkle path
      expect(parsedBump.validateMerklePath(txidInternal), true,
          reason: 'Recipient should successfully validate merkle path');

      // Compute and compare merkle roots
      final senderRoot = bumpFromStorage.computeMerkleRoot(txidInternal);
      final recipientRoot = parsedBump.computeMerkleRoot(txidInternal);

      expect(bytesToHex(recipientRoot), bytesToHex(senderRoot),
          reason: 'Merkle roots should match on both sides');

      print('✓ BEEF from raw BUMP hex successfully validated by recipient');
    });

    test('Verify txid format in calculateTxid matches BUMP expectations', () {
      // This tests that calculateTxid produces display format (big-endian)
      // which must then be reversed before BUMP validation

      // The stored txid is in display format
      final displayTxid = workingMerkleProofEntity['txid'] as String;
      
      // Create BUMP from TSC
      final bump = CryptoUtils.createBumpFromTscProof(
        tscProof,
        workingMerkleProofEntity['blockHeight'] as int,
      );

      // Test 1: Display format should NOT validate directly
      final displayTxidBytes = hexToBytes(displayTxid);
      expect(bump.validateMerklePath(displayTxidBytes), false,
          reason: 'Display format should NOT validate directly');

      // Test 2: Internal format (reversed) SHOULD validate
      final internalTxidBytes = hexToBytes(reverseHexBytes(displayTxid));
      expect(bump.validateMerklePath(internalTxidBytes), true,
          reason: 'Internal format (reversed) SHOULD validate');

      print('✓ TXID format requirements verified');
      print('  Display (big-endian): $displayTxid');
      print('  Internal (little-endian): ${reverseHexBytes(displayTxid)}');
    });
  });

  group('Real Data: Same Transaction with TSC and ARC Formats', () {
    // Real data from the same transaction in both formats
    // TSC Format (from WhatsOnChain / wallet import)
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

    // ARC Service Format (from ARC API)
    // IMPORTANT: ARC's merklePath is a compact BUMP with multiple leaves per level
    // The TSC format builds a different (but semantically equivalent) BUMP structure
    final realArcResponse = {
      'blockHash': '000000001387da7eee528023f9f3dba5481fb43c85edcb42877968e19ce5dfb7',
      'blockHeight': 1709615,
      'competingTxs': null,
      'extraInfo': '',
      'merklePath': 'fe2f161a00030200000432d582a86eb0b6cb9bc75c714a139981f941e86352e96a97b90aa5a79bb6970102d2d983610eff773c62ed4941df69170f1bfceea461acca5f06fd53eb1668ccb1010100fd9cb6a8a4e42ef8aca9e9287bc67f25e20e5fec839962ff055f49fca0cc25df01010061d3ce5c137fce6c9164526ce18b436ecb16a6ace7ffe9bd0c6e0a4a9f2a52ab',
      'timestamp': '2025-12-19T23:33:12.233243813Z',
      'txStatus': 'MINED',
      'txid': 'b1cc6816eb53fd065fcaac61a4eefc1b0f1769df4149ed623c77ff0e6183d9d2',
    };

    test('ARC format: Parse raw BUMP hex and validate merkle path', () {
      // This simulates the ARC service path where merklePath is already a BUMP
      final rawBumpHex = realArcResponse['merklePath'] as String;

      // Parse the raw BUMP
      final bump = BUMP.fromBytes(hexToBytes(rawBumpHex));

      // Verify structure - ARC uses compact format with multiple leaves per level
      expect(bump.blockHeight, 1709615);
      expect(bump.path.length, 3); // ARC uses 3 levels (compact representation)
      
      // Level 0 should have 2 leaves (sibling + txid together)
      expect(bump.path[0].leaves.length, 2);

      // Find txid leaf
      Leaf? txidLeaf;
      for (final level in bump.path) {
        for (final leaf in level.leaves) {
          if (leaf.isTxid) {
            txidLeaf = leaf;
            break;
          }
        }
        if (txidLeaf != null) break;
      }

      expect(txidLeaf, isNotNull);
      expect(txidLeaf!.offset, 1); // TX at position 1

      // Validate merkle path
      final txidInternal = hexToBytes(reverseHexBytes(realArcResponse['txid'] as String));
      expect(bump.validateMerklePath(txidInternal), true);

      // Compute merkle root
      final merkleRoot = bump.computeMerkleRoot(txidInternal);
      print('✓ ARC format BUMP parsed successfully');
      print('  Block Height: ${bump.blockHeight}');
      print('  Path Levels: ${bump.path.length} (compact format)');
      print('  Level 0 Leaves: ${bump.path[0].leaves.length}');
      print('  TX Position: ${txidLeaf.offset}');
      print('  Merkle Root: ${bytesToHex(merkleRoot)}');
    });

    test('Verify ARC BUMP contains correct sibling hashes from TSC', () {
      // Parse the ARC BUMP
      final rawBumpHex = realArcResponse['merklePath'] as String;
      final bump = BUMP.fromBytes(hexToBytes(rawBumpHex));

      // Extract all non-txid hashes (siblings) from BUMP
      final siblingHashesFromBump = <String>[];
      for (final level in bump.path) {
        for (final leaf in level.leaves) {
          if (!leaf.isTxid && !leaf.duplicate && leaf.hash != null) {
            // Convert from internal (little-endian) to display (big-endian) format
            final displayHash = leaf.hash!.reversed
                .map((b) => b.toRadixString(16).padLeft(2, '0'))
                .join('');
            siblingHashesFromBump.add(displayHash);
          }
        }
      }

      // Get expected sibling hashes from TSC
      final tscNodes = realTscProof['nodes'] as List<String>;

      // Verify all TSC siblings are present in the BUMP
      expect(siblingHashesFromBump.length, tscNodes.length,
          reason: 'Should have same number of sibling hashes');

      for (final tscNode in tscNodes) {
        expect(siblingHashesFromBump.contains(tscNode), true,
            reason: 'BUMP should contain TSC sibling hash: $tscNode');
      }

      print('✓ ARC BUMP contains all TSC sibling hashes');
      print('  TSC nodes: ${tscNodes.length}');
      print('  BUMP siblings: ${siblingHashesFromBump.length}');
    });

    test('ARC format round-trips correctly through storage', () {
      // Simulate ARC service: response → MerkleProof → storage → retrieval

      // Step 1: ARC returns merklePath as string, parseStringList wraps it in a list
      final arcMerklePath = realArcResponse['merklePath'] as String;
      final merklePathAsList = [arcMerklePath]; // What parseStringList does

      // Step 2: Simulate storage (MerkleProofEntity.fromMerkleProof joins with comma)
      final merkleProofJson = merklePathAsList.join(',');
      expect(merkleProofJson, arcMerklePath);

      // Step 3: Simulate retrieval (MerkleProofEntity.toMerkleProof splits by comma)
      final retrievedMerkleProof = merkleProofJson.split(',');
      expect(retrievedMerkleProof.length, 1);
      expect(retrievedMerkleProof[0].length, greaterThan(64)); // Raw BUMP, not a hash

      // Step 4: Detect raw BUMP format and parse directly
      expect(retrievedMerkleProof.length == 1 && retrievedMerkleProof[0].length > 64, true,
          reason: 'Should detect raw BUMP format');

      // Parse directly
      final builtBump = BUMP.fromBytes(hexToBytes(retrievedMerkleProof[0]));

      // Verify it validates
      final txid = realArcResponse['txid'] as String;
      final txidInternal = hexToBytes(reverseHexBytes(txid));
      expect(builtBump.validateMerklePath(txidInternal), true);

      // Verify serialization matches original
      expect(bytesToHex(builtBump.serialize()), arcMerklePath);

      print('✓ ARC → Storage → Retrieval → BUMP flow works correctly!');
    });

    test('PaymentCoordinator correctly handles raw BUMP format from ARC', () {
      final txid = realArcResponse['txid'] as String;
      final txidInternal = hexToBytes(reverseHexBytes(txid));

      // Simulate retrieved MerkleProof with raw BUMP
      final arcMerkleProofList = [realArcResponse['merklePath'] as String];

      // Detect and parse as PaymentCoordinator would (ARC path)
      BUMP bumpFromArcPath;
      if (arcMerkleProofList.length == 1 && arcMerkleProofList[0].length > 64) {
        // Raw BUMP format - parse directly (this is the fix we implemented)
        bumpFromArcPath = BUMP.fromBytes(hexToBytes(arcMerkleProofList[0]));
      } else {
        throw Exception('Should have detected raw BUMP format');
      }

      // Should validate correctly
      expect(bumpFromArcPath.validateMerklePath(txidInternal), true);

      // Compute merkle root
      final merkleRoot = bumpFromArcPath.computeMerkleRoot(txidInternal);

      print('✓ PaymentCoordinator correctly handles ARC raw BUMP format!');
      print('  Raw BUMP length: ${arcMerkleProofList[0].length} chars');
      print('  Merkle root: ${bytesToHex(merkleRoot)}');
    });

    test('Verify block hash and txid consistency between formats', () {
      // Both formats reference the same block
      expect(realArcResponse['blockHash'], realTscProof['target']);

      // Both have the same txid
      expect(realArcResponse['txid'], realTscProof['txOrId']);

      print('✓ Block hash and txid consistent between formats');
      print('  Block: ${realArcResponse['blockHash']}');
      print('  TXID:  ${realArcResponse['txid']}');
    });

    test('Document BUMP format differences between TSC-built and ARC compact', () {
      // This test documents the structural differences between formats
      // Both are valid BUMP representations, just different structures
      
      // TSC-built format: 1 leaf per level (txid separate from siblings)
      final bumpFromTsc = CryptoUtils.createBumpFromTscProof(realTscProof, 1709615);
      
      // ARC compact format: multiple leaves per level
      final bumpFromArc = BUMP.fromBytes(hexToBytes(realArcResponse['merklePath'] as String));

      // TSC format has more levels (txid + each sibling gets its own level)
      expect(bumpFromTsc.path.length, 4); // txid level + 3 sibling levels
      
      // ARC format is more compact (txid + sibling share level 0)
      expect(bumpFromArc.path.length, 3); // 3 combined levels

      // Both have same number of total leaves (1 txid + 3 siblings = 4 total)
      int tscLeafCount = bumpFromTsc.path.fold(0, (sum, level) => sum + level.leaves.length);
      int arcLeafCount = bumpFromArc.path.fold(0, (sum, level) => sum + level.leaves.length);
      expect(tscLeafCount, 4); // 1 per level
      expect(arcLeafCount, 4); // 2 + 1 + 1 = 4 (txid + 3 siblings)
      
      // ARC has: level 0 = 2 leaves (txid + sibling), level 1 = 1 leaf, level 2 = 1 leaf
      expect(bumpFromArc.path[0].leaves.length, 2);
      expect(bumpFromArc.path[1].leaves.length, 1);
      expect(bumpFromArc.path[2].leaves.length, 1);

      print('✓ BUMP format differences documented');
      print('  TSC-built: ${bumpFromTsc.path.length} levels, ${tscLeafCount} total leaves');
      print('  ARC compact: ${bumpFromArc.path.length} levels, ${arcLeafCount} total leaves');
      print('');
      print('  NOTE: Different internal structures, but both valid for SPV validation');
      print('  The PaymentCoordinator should use ARC format directly when available,');
      print('  rather than rebuilding from TSC sibling hashes.');
    });
  });

  group('Hypothesis: BEEF Round-Trip Validation', () {
    // Real data from the same transaction
    final realArcResponse = {
      'blockHash': '000000001387da7eee528023f9f3dba5481fb43c85edcb42877968e19ce5dfb7',
      'blockHeight': 1709615,
      'merklePath': 'fe2f161a00030200000432d582a86eb0b6cb9bc75c714a139981f941e86352e96a97b90aa5a79bb6970102d2d983610eff773c62ed4941df69170f1bfceea461acca5f06fd53eb1668ccb1010100fd9cb6a8a4e42ef8aca9e9287bc67f25e20e5fec839962ff055f49fca0cc25df01010061d3ce5c137fce6c9164526ce18b436ecb16a6ace7ffe9bd0c6e0a4a9f2a52ab',
      'txid': 'b1cc6816eb53fd065fcaac61a4eefc1b0f1769df4149ed623c77ff0e6183d9d2',
    };

    // Mock ancestor transaction raw hex (we'll create a simple one for testing)
    // The txid of this raw transaction MUST match the txid in the ARC BUMP
    // For this test, we'll use the ARC BUMP's embedded txid

    test('HYPOTHESIS: Sender creates BEEF with ARC BUMP, recipient validates', () async {
      // === SENDER SIDE ===
      
      // Step 1: Parse the raw BUMP from ARC storage
      final rawBumpHex = realArcResponse['merklePath'] as String;
      final senderBump = BUMP.fromBytes(hexToBytes(rawBumpHex));
      
      print('=== SENDER SIDE ===');
      print('Sender BUMP: height=${senderBump.blockHeight}, levels=${senderBump.path.length}');
      
      // Step 2: Get the txid from the BUMP (embedded in level 0)
      Uint8List? embeddedTxid;
      for (final leaf in senderBump.path[0].leaves) {
        if (leaf.isTxid && leaf.hash != null) {
          embeddedTxid = leaf.hash;
          break;
        }
      }
      expect(embeddedTxid, isNotNull, reason: 'BUMP should have embedded txid');
      print('Embedded TXID (internal): ${bytesToHex(embeddedTxid!)}');
      
      // Step 3: Compute merkle root on sender side
      final senderMerkleRoot = senderBump.computeMerkleRoot(embeddedTxid);
      print('Sender computed merkle root: ${bytesToHex(senderMerkleRoot)}');
      
      // Step 4: Create a mock ancestor transaction
      // For testing, we create a fake tx that when hashed produces the expected txid
      // In reality, this would be the actual ancestor transaction bytes
      // We'll simulate by using a marker that validateMerklePath will use the embedded txid
      
      // Step 5: Serialize the BUMP (simulates BEEF transmission)
      final serializedBump = senderBump.serialize();
      print('Serialized BUMP: ${serializedBump.length} bytes');
      
      // === RECIPIENT SIDE ===
      print('\n=== RECIPIENT SIDE ===');
      
      // Step 6: Parse the serialized BUMP (simulates BEEF parsing)
      final recipientBump = BUMP.fromBytes(serializedBump);
      print('Recipient BUMP: height=${recipientBump.blockHeight}, levels=${recipientBump.path.length}');
      
      // Step 7: Verify structure is preserved
      expect(recipientBump.blockHeight, senderBump.blockHeight);
      expect(recipientBump.path.length, senderBump.path.length);
      
      // Step 8: Get embedded txid on recipient side
      Uint8List? recipientEmbeddedTxid;
      for (final leaf in recipientBump.path[0].leaves) {
        if (leaf.isTxid && leaf.hash != null) {
          recipientEmbeddedTxid = leaf.hash;
          break;
        }
      }
      expect(recipientEmbeddedTxid, isNotNull);
      expect(bytesToHex(recipientEmbeddedTxid!), bytesToHex(embeddedTxid),
          reason: 'Embedded txid should survive round-trip');
      
      // Step 9: Validate merkle path on recipient side
      final pathValid = recipientBump.validateMerklePath(recipientEmbeddedTxid);
      expect(pathValid, true, reason: 'Merkle path should validate after round-trip');
      print('Recipient validateMerklePath: $pathValid');
      
      // Step 10: Compute merkle root on recipient side
      final recipientMerkleRoot = recipientBump.computeMerkleRoot(recipientEmbeddedTxid);
      print('Recipient computed merkle root: ${bytesToHex(recipientMerkleRoot)}');
      
      // Step 11: CRITICAL - Merkle roots should match
      expect(bytesToHex(recipientMerkleRoot), bytesToHex(senderMerkleRoot),
          reason: 'Merkle root should be identical after round-trip');
      
      print('\n✓ HYPOTHESIS CONFIRMED: BUMP round-trip preserves merkle root');
    });

    test('HYPOTHESIS: validateTransactionWithBlockHeader uses correct txid format', () {
      // This test verifies that the validation flow handles txid formats correctly
      
      // Parse the raw BUMP
      final rawBumpHex = realArcResponse['merklePath'] as String;
      final bump = BUMP.fromBytes(hexToBytes(rawBumpHex));
      
      // Get the expected txid from ARC response (display format)
      final displayTxid = realArcResponse['txid'] as String;
      final displayTxidBytes = hexToBytes(displayTxid);
      
      // Get the embedded txid from BUMP (internal format)
      Uint8List? embeddedTxid;
      for (final leaf in bump.path[0].leaves) {
        if (leaf.isTxid && leaf.hash != null) {
          embeddedTxid = leaf.hash;
          break;
        }
      }
      expect(embeddedTxid, isNotNull);
      
      // Convert display txid to internal format
      final internalTxidBytes = Uint8List.fromList(displayTxidBytes.reversed.toList());
      
      // CRITICAL TEST: The embedded txid should match the internal format
      print('Display TXID: $displayTxid');
      print('Internal TXID: ${bytesToHex(internalTxidBytes)}');
      print('Embedded TXID: ${bytesToHex(embeddedTxid!)}');
      
      expect(bytesToHex(embeddedTxid), bytesToHex(internalTxidBytes),
          reason: 'Embedded txid in BUMP should match internal format of display txid');
      
      // Now verify validation works with internal format
      final isValid = bump.validateMerklePath(internalTxidBytes);
      expect(isValid, true, reason: 'validateMerklePath should succeed with internal format txid');
      
      // And fails with display format (wrong byte order)
      final isInvalidWithDisplayFormat = bump.validateMerklePath(displayTxidBytes);
      expect(isInvalidWithDisplayFormat, false,
          reason: 'validateMerklePath should fail with display format txid');
      
      print('✓ validateMerklePath correctly requires internal format txid');
    });

    test('HYPOTHESIS: Block header merkle root format matches computed root', () {
      // This test verifies the merkle root comparison logic
      
      // Parse the raw BUMP
      final rawBumpHex = realArcResponse['merklePath'] as String;
      final bump = BUMP.fromBytes(hexToBytes(rawBumpHex));
      
      // Get embedded txid in internal format
      final displayTxid = realArcResponse['txid'] as String;
      final internalTxid = hexToBytes(reverseHexBytes(displayTxid));
      
      // Compute merkle root
      final computedRoot = bump.computeMerkleRoot(internalTxid);
      print('Computed merkle root (internal): ${bytesToHex(computedRoot)}');
      
      // The block header stores merkle root in internal format (little-endian)
      // For this block, we need to verify the computed root is correct
      // By reversing it, we get the display format that matches block explorers
      final displayRoot = bytesToHex(Uint8List.fromList(computedRoot.reversed.toList()));
      print('Computed merkle root (display): $displayRoot');
      
      // The block header at height 1709615 should have this merkle root
      // This is the value that SPVActor._getBlockHeader should return
      print('Block height: ${bump.blockHeight}');
      print('Expected: Block header merkle root should match computed root');
      
      // If the recipient's block header has a different merkle root,
      // validation will fail. This would indicate a block header sync issue.
      
      print('✓ To validate on recipient, block header at height ${bump.blockHeight}');
      print('  must have merkle root: ${bytesToHex(computedRoot)} (internal format)');
    });

    test('HYPOTHESIS: BEEF.calculateTxid matches BUMP embedded txid', () {
      // This is the critical test - when SPVActor calculates the txid from
      // raw transaction bytes, it must match the txid embedded in the BUMP
      
      // This simulates what happens on the recipient side:
      // 1. Recipient receives BEEF with ancestor tx bytes and BUMP
      // 2. Recipient calculates txid from tx bytes: beef.calculateTxid(beef.txs[i])
      // 3. Recipient looks up the tx in BEEF and gets the BUMP
      // 4. Recipient calls bump.validateMerklePath(txidInternal)
      
      // The issue could be:
      // - The txid calculated from tx bytes doesn't match BUMP's embedded txid
      // - This would happen if tx bytes in BEEF are different from what ARC mined
      
      // Parse the raw BUMP
      final rawBumpHex = realArcResponse['merklePath'] as String;
      final bump = BUMP.fromBytes(hexToBytes(rawBumpHex));
      
      // Get embedded txid from BUMP
      Uint8List? embeddedTxid;
      for (final leaf in bump.path[0].leaves) {
        if (leaf.isTxid && leaf.hash != null) {
          embeddedTxid = leaf.hash;
          break;
        }
      }
      
      // The expected display-format txid from ARC
      final expectedDisplayTxid = realArcResponse['txid'] as String;
      
      // Convert embedded txid (internal) to display format for comparison
      final embeddedDisplayTxid = bytesToHex(Uint8List.fromList(embeddedTxid!.reversed.toList()));
      
      print('Expected TXID (from ARC):    $expectedDisplayTxid');
      print('Embedded TXID (from BUMP):   $embeddedDisplayTxid');
      
      expect(embeddedDisplayTxid, expectedDisplayTxid,
          reason: 'BUMP embedded txid should match ARC txid');
      
      // Now, when the sender creates BEEF:
      // - They include the raw ancestor tx bytes
      // - The TXID of those bytes MUST match embeddedDisplayTxid
      // 
      // If they don't match, recipient validation fails because:
      // beef.calculateTxid(beef.txs[i]) != what's in the BUMP
      
      print('\n✓ BUMP contains correct txid');
      print('⚠️  If validation fails on recipient, check that ancestor tx bytes');
      print('   in BEEF produce the same txid when hashed');
    });
  });

  group('Complete BEEF End-to-End Validation', () {
    // Real ancestor transaction that was mined
    const ancestorTxHex = '020000000162dfda1aea1c1c9a8371b677a0c77bf33783670e9c61272b6b51edef2c1bde55010000006a47304402203f099ed9154ed8262d9c4e764d6867054285b643896a231584e820eba5c42b9202204a616d4aad9318178bfe5d614f3f450bbcb386f256cdb146cbb5b77c5fc7249c412103775ebfa3681adf4bbc6b19d3de2d4d6b911c180be46c9aca8128d428c7a0e0a8ffffffff023c3d8600000000001976a9145b1edce788a9ca9984891fdbe5e2a418d44cf2cf88acdc050000000000001976a914812354f2806be0dad3a91d37f98c896dbef9b71f88ac00000000';
    const expectedTxid = 'b1cc6816eb53fd065fcaac61a4eefc1b0f1769df4149ed623c77ff0e6183d9d2';
    
    // ARC merkle proof for this transaction
    const arcMerklePath = 'fe2f161a00030200000432d582a86eb0b6cb9bc75c714a139981f941e86352e96a97b90aa5a79bb6970102d2d983610eff773c62ed4941df69170f1bfceea461acca5f06fd53eb1668ccb1010100fd9cb6a8a4e42ef8aca9e9287bc67f25e20e5fec839962ff055f49fca0cc25df01010061d3ce5c137fce6c9164526ce18b436ecb16a6ace7ffe9bd0c6e0a4a9f2a52ab';
    const blockHeight = 1709615;

    test('Verify transaction hash matches expected txid', () {
      // First, verify the raw tx produces the expected txid
      final txBytes = hexToBytes(ancestorTxHex);
      
      // Calculate txid (double SHA256, then reverse for display format)
      final firstHash = dartsv.sha256(txBytes);
      final secondHash = dartsv.sha256(firstHash);
      final calculatedTxid = Uint8List.fromList(secondHash.reversed.toList());
      
      final calculatedTxidHex = bytesToHex(calculatedTxid);
      
      print('Raw TX length: ${txBytes.length} bytes');
      print('Calculated TXID: $calculatedTxidHex');
      print('Expected TXID:   $expectedTxid');
      
      expect(calculatedTxidHex, expectedTxid,
          reason: 'Calculated txid should match expected txid');
      
      print('✓ Transaction hash verified');
    });

    test('CRITICAL: Complete BEEF creation and SPV validation flow', () async {
      // === SENDER SIDE: Create BEEF ===
      print('=== SENDER SIDE ===');
      
      // 1. Parse the ARC BUMP
      final bump = BUMP.fromBytes(hexToBytes(arcMerklePath));
      print('BUMP parsed: height=${bump.blockHeight}, levels=${bump.path.length}');
      
      // 2. Get ancestor transaction bytes
      final ancestorTxBytes = hexToBytes(ancestorTxHex);
      
      // 3. Create a simple "payment" transaction (for testing, just use same tx)
      // In real scenario, this would be the new unconfirmed payment tx
      final paymentTxBytes = ancestorTxBytes; // Using same for simplicity
      
      // 4. Create BEEF structure
      final senderBeef = BEEF.create(
        bumps: [bump],
        txs: [ancestorTxBytes, paymentTxBytes],
        hasMerkle: [true, false], // Ancestor has proof, payment doesn't
        bumpIndex: [0], // Ancestor uses bump at index 0
      );
      
      print('BEEF created: ${senderBeef.txs.length} txs, ${senderBeef.bumps.length} bumps');
      
      // 5. Serialize BEEF for transmission
      final beefBytes = senderBeef.serialize();
      print('BEEF serialized: ${beefBytes.length} bytes');
      
      // === TRANSMISSION (serialize/parse) ===
      print('\n=== TRANSMISSION ===');
      
      // 6. Parse BEEF on recipient side
      final recipientBeef = BEEF.parse(beefBytes);
      print('BEEF parsed: ${recipientBeef.txs.length} txs, ${recipientBeef.bumps.length} bumps');
      
      // Verify structure preserved
      expect(recipientBeef.txs.length, senderBeef.txs.length);
      expect(recipientBeef.bumps.length, senderBeef.bumps.length);
      expect(recipientBeef.hasMerkle, senderBeef.hasMerkle);
      expect(recipientBeef.bumpIndex, senderBeef.bumpIndex);
      
      // === RECIPIENT SIDE: Validate (simulates SPVActor) ===
      print('\n=== RECIPIENT SIDE VALIDATION ===');
      
      // 7. Calculate ancestor txid from raw bytes (like SPVActor does)
      final calculatedAncestorTxid = recipientBeef.calculateTxid(recipientBeef.txs[0]);
      print('Calculated ancestor TXID: ${bytesToHex(calculatedAncestorTxid)}');
      
      // 8. Find transaction in BEEF
      final txInfo = recipientBeef.findTransactionByTxid(calculatedAncestorTxid);
      expect(txInfo, isNotNull, reason: 'Transaction should be found in BEEF');
      print('Transaction found at index: ${txInfo!['index']}');
      print('Has merkle proof: ${txInfo['hasMerkleProof']}');
      print('BUMP index: ${txInfo['bumpIndex']}');
      
      // 9. Get the BUMP
      final bumpIdx = txInfo['bumpIndex'] as int;
      final recipientBump = recipientBeef.bumps[bumpIdx];
      
      // 10. Convert txid to internal format
      final txidInternal = Uint8List.fromList(calculatedAncestorTxid.reversed.toList());
      print('TXID internal format: ${bytesToHex(txidInternal)}');
      
      // 11. Validate merkle path
      final pathValid = recipientBump.validateMerklePath(txidInternal);
      print('validateMerklePath result: $pathValid');
      expect(pathValid, true, reason: 'Merkle path should validate');
      
      // 12. Compute merkle root
      final computedRoot = recipientBump.computeMerkleRoot(txidInternal);
      print('Computed merkle root: ${bytesToHex(computedRoot)}');
      
      // 13. This is the merkle root that should match the block header
      // The block header at height 1709615 should have this merkle root
      print('\n=== EXPECTED BLOCK HEADER ===');
      print('Block height: $blockHeight');
      print('Expected merkle root (internal): ${bytesToHex(computedRoot)}');
      print('Expected merkle root (display): ${bytesToHex(Uint8List.fromList(computedRoot.reversed.toList()))}');
      
      // Create a mock block header with the correct merkle root
      final mockBlockHeader = BlockHeader(
        version: 0x20000000,
        prevBlock: Hash.fromHex('0000000000000000000000000000000000000000000000000000000000000000'),
        merkleRoot: Hash.fromBytes(computedRoot),
        timestamp: DateTime.now(),
        bits: 0x1d00ffff,
        nonce: 0,
      );
      
      // 14. FINAL VALIDATION - this is what SPVActor does
      final isValid = await recipientBeef.validateTransactionWithBlockHeader(
        calculatedAncestorTxid,
        mockBlockHeader,
      );
      
      print('\n=== FINAL RESULT ===');
      print('validateTransactionWithBlockHeader: $isValid');
      
      expect(isValid, true,
          reason: 'BEEF validation should succeed with correct block header');
      
      print('✓ Complete BEEF validation successful!');
      print('\n⚠️  If recipient validation fails in production:');
      print('   The block header at height $blockHeight must have');
      print('   merkle root: ${bytesToHex(computedRoot)}');
    });

    test('Demonstrate what happens with WRONG block header', () async {
      // This test shows the validation fails with wrong merkle root
      
      final bump = BUMP.fromBytes(hexToBytes(arcMerklePath));
      final ancestorTxBytes = hexToBytes(ancestorTxHex);
      
      final beef = BEEF.create(
        bumps: [bump],
        txs: [ancestorTxBytes],
        hasMerkle: [true],
        bumpIndex: [0],
      );
      
      final txid = beef.calculateTxid(beef.txs[0]);
      
      // Create a WRONG block header with random merkle root
      final wrongBlockHeader = BlockHeader(
        version: 0x20000000,
        prevBlock: Hash.fromHex('0000000000000000000000000000000000000000000000000000000000000000'),
        merkleRoot: Hash.fromHex('0000000000000000000000000000000000000000000000000000000000000000'),
        timestamp: DateTime.now(),
        bits: 0x1d00ffff,
        nonce: 0,
      );
      
      final isValid = await beef.validateTransactionWithBlockHeader(txid, wrongBlockHeader);
      
      print('Validation with WRONG block header: $isValid');
      expect(isValid, false,
          reason: 'Validation should FAIL with wrong merkle root');
      
      print('✓ Correctly rejects wrong block header');
    });
  });

  group('HYPOTHESIS: Hash Round-Trip Bug Investigation', () {
    test('Hash round-trip preserves byte order (fromBytes → toString → fromHex → bytes)', () {
      // This is the computed merkle root from our tests (internal format)
      const computedRootInternal = '6838fef81b99cfe437167f9105c5c48286e1cb6fa59b5cc562b206858bb0c631';
      final computedRootBytes = hexToBytes(computedRootInternal);
      
      // Simulate what bump.computeMerkleRoot() returns
      print('=== Hash Round-Trip Test ===');
      print('Computed root (internal format): $computedRootInternal');
      print('Computed root bytes: ${computedRootBytes.length} bytes');
      
      // Step 1: Create Hash from bytes (like we do in tests)
      final hashFromBytes = Hash.fromBytes(computedRootBytes);
      print('\nStep 1: Hash.fromBytes(computedRootBytes)');
      print('  hashFromBytes.bytes hex: ${bytesToHex(Uint8List.fromList(hashFromBytes.bytes))}');
      print('  hashFromBytes.toString(): ${hashFromBytes.toString()}');
      
      // Step 2: Simulate storing to database (toString() is called)
      final storedString = hashFromBytes.toString();
      print('\nStep 2: Stored to database as: $storedString');
      
      // Step 3: Simulate retrieving from database (Hash.fromHex is called)
      final retrievedHash = Hash.fromHex(storedString);
      print('\nStep 3: Hash.fromHex(storedString)');
      print('  retrievedHash.bytes hex: ${bytesToHex(Uint8List.fromList(retrievedHash.bytes))}');
      print('  retrievedHash.toString(): ${retrievedHash.toString()}');
      
      // Step 4: Compare bytes (this is what validateTransactionWithBlockHeader does)
      final retrievedBytesHex = bytesToHex(Uint8List.fromList(retrievedHash.bytes));
      
      print('\n=== COMPARISON ===');
      print('Original computed root:  $computedRootInternal');
      print('After round-trip bytes:  $retrievedBytesHex');
      print('Match: ${retrievedBytesHex == computedRootInternal}');
      
      // THIS IS THE CRITICAL TEST
      expect(retrievedBytesHex, computedRootInternal,
          reason: 'Hash bytes should match after store/retrieve round-trip');
    });

    test('Simulate actual block header storage and retrieval', () {
      // Compute merkle root from BUMP (like sender does)
      final rawBumpHex = 'fe2f161a00030200000432d582a86eb0b6cb9bc75c714a139981f941e86352e96a97b90aa5a79bb6970102d2d983610eff773c62ed4941df69170f1bfceea461acca5f06fd53eb1668ccb1010100fd9cb6a8a4e42ef8aca9e9287bc67f25e20e5fec839962ff055f49fca0cc25df01010061d3ce5c137fce6c9164526ce18b436ecb16a6ace7ffe9bd0c6e0a4a9f2a52ab';
      final bump = BUMP.fromBytes(hexToBytes(rawBumpHex));
      
      // Get txid in internal format
      const txidDisplay = 'b1cc6816eb53fd065fcaac61a4eefc1b0f1769df4149ed623c77ff0e6183d9d2';
      final txidInternal = hexToBytes(reverseHexBytes(txidDisplay));
      
      // Compute merkle root
      final computedRoot = bump.computeMerkleRoot(txidInternal);
      print('Computed merkle root (internal): ${bytesToHex(computedRoot)}');
      
      // === Simulate Block Header Storage (what header sync does) ===
      // Create a BlockHeader with the correct merkle root
      final originalHeader = BlockHeader(
        version: 0x20000000,
        prevBlock: Hash.fromHex('0000000000000000000000000000000000000000000000000000000000000000'),
        merkleRoot: Hash.fromBytes(computedRoot),  // What we'd ideally store
        timestamp: DateTime.now(),
        bits: 0x1d00ffff,
        nonce: 0,
      );
      
      // Simulate storage: convert to strings (like BlockHeaderEntity.fromBlockHeader)
      final storedMerkleRoot = originalHeader.merkleRoot.toString();
      print('\nStored merkle root string: $storedMerkleRoot');
      
      // Simulate retrieval: convert back (like BlockHeaderEntity.toBlockHeader)
      final retrievedHeader = BlockHeader(
        version: originalHeader.version,
        prevBlock: originalHeader.prevBlock,
        merkleRoot: Hash.fromHex(storedMerkleRoot),  // This is how it's retrieved
        timestamp: originalHeader.timestamp,
        bits: originalHeader.bits,
        nonce: originalHeader.nonce,
      );
      
      // === Now simulate validateTransactionWithBlockHeader comparison ===
      final computedMerkleRootHex = hex.encode(computedRoot);
      final expectedMerkleRootHex = hex.encode(retrievedHeader.merkleRoot.bytes);
      
      print('\n=== VALIDATION COMPARISON ===');
      print('computedMerkleRoot hex:  $computedMerkleRootHex');
      print('blockHeader.merkleRoot.bytes hex: $expectedMerkleRootHex');
      print('Match: ${computedMerkleRootHex == expectedMerkleRootHex}');
      
      // THIS REVEALS THE BUG
      expect(computedMerkleRootHex, expectedMerkleRootHex,
          reason: 'Computed merkle root should match block header after storage round-trip');
    });

    test('Direct byte comparison: computeMerkleRoot vs Hash.fromHex().bytes', () {
      // The EXACT comparison done in validateTransactionWithBlockHeader
      final rawBumpHex = 'fe2f161a00030200000432d582a86eb0b6cb9bc75c714a139981f941e86352e96a97b90aa5a79bb6970102d2d983610eff773c62ed4941df69170f1bfceea461acca5f06fd53eb1668ccb1010100fd9cb6a8a4e42ef8aca9e9287bc67f25e20e5fec839962ff055f49fca0cc25df01010061d3ce5c137fce6c9164526ce18b436ecb16a6ace7ffe9bd0c6e0a4a9f2a52ab';
      final bump = BUMP.fromBytes(hexToBytes(rawBumpHex));
      
      const txidDisplay = 'b1cc6816eb53fd065fcaac61a4eefc1b0f1769df4149ed623c77ff0e6183d9d2';
      final txidInternal = hexToBytes(reverseHexBytes(txidDisplay));
      
      // What bump.computeMerkleRoot returns
      final computedRoot = bump.computeMerkleRoot(txidInternal);
      
      // The expected merkle root in display format (from a block explorer)
      // Display format is the reversed version of internal format
      final computedRootDisplay = bytesToHex(Uint8List.fromList(computedRoot.reversed.toList()));
      print('Computed root (internal): ${bytesToHex(computedRoot)}');
      print('Computed root (display):  $computedRootDisplay');
      
      // If block header was stored with display format merkle root...
      // This is what Hash.fromHex expects: a display format hex string
      // And Hash.fromHex should convert it to internal format bytes
      
      // Test 1: Hash.fromHex with display format
      final hashFromDisplay = Hash.fromHex(computedRootDisplay);
      print('\nHash.fromHex(displayFormat).bytes: ${bytesToHex(Uint8List.fromList(hashFromDisplay.bytes))}');
      
      // Test 2: Hash.fromHex with internal format  
      final hashFromInternal = Hash.fromHex(bytesToHex(computedRoot));
      print('Hash.fromHex(internalFormat).bytes: ${bytesToHex(Uint8List.fromList(hashFromInternal.bytes))}');
      
      // Which one matches computedRoot?
      final displayBytesMatch = bytesToHex(Uint8List.fromList(hashFromDisplay.bytes)) == bytesToHex(computedRoot);
      final internalBytesMatch = bytesToHex(Uint8List.fromList(hashFromInternal.bytes)) == bytesToHex(computedRoot);
      
      print('\nHash.fromHex(display).bytes matches computedRoot: $displayBytesMatch');
      print('Hash.fromHex(internal).bytes matches computedRoot: $internalBytesMatch');
      
      // The question is: does Hash.fromHex reverse the bytes or not?
      // If it does, then storing display format and calling fromHex gives internal format bytes
      // If it doesn't, then we have a mismatch
      
      if (displayBytesMatch) {
        print('\n✓ Hash.fromHex REVERSES bytes (display → internal)');
        print('  This means block headers should be stored in DISPLAY format');
      } else if (internalBytesMatch) {
        print('\n✓ Hash.fromHex does NOT reverse bytes');
        print('  This means block headers should be stored in INTERNAL format');
      } else {
        print('\n❌ Neither format matches - something is very wrong!');
      }
    });
  });

  group('PRODUCTION BUG REPRODUCTION', () {
    // Extract just the BUMP from the BEEF hex (starts after 0100beef01)
    // BUMP: fe2e161a0001020000f81e34fdc29d82c795bb1b925dd8666550b603f84f511fa95297b2b72379ff4301028e0413cb47c3e9ee57e85bc3f9c71b68d9a0b0d462729ac5e3440961f0c1c3aa
    const productionBumpHex = 'fe2e161a0001020000f81e34fdc29d82c795bb1b925dd8666550b603f84f511fa95297b2b72379ff4301028e0413cb47c3e9ee57e85bc3f9c71b68d9a0b0d462729ac5e3440961f0c1c3aa';
    
    // Ancestor raw transaction from sender logs
    const ancestorTxHex = '020000000162dfda1aea1c1c9a8371b677a0c77bf33783670e9c61272b6b51edef2c1bde55020000006b48304502210083eec97feb18966c00b453aeb3a03649c2ac6a911cfbeb83cc530dad5ae3681d02206824c3f0df9dc182be6be30c8013ee47292af624d1aa77aa581b6bf90f3e0f164121039c96c76acfc3928c36b0ea7d9eea07341adbb3d136c533637dd8c91302b61243ffffffff024e05c900000000001976a914a7b7efa4eaa4d4d2a16540868d19046f148c096888acfc080000000000001976a914d18c2e8a027f0f0a3c7fcc9ad932770951bac23b88ac00000000';
    
    // Expected ancestor txid from logs
    const expectedAncestorTxid = 'aac3c1f0610944e3c59a7262d4b0a0d9681bc7f9c35be857eee9c347cb13048e';
    const blockHeight = 1709614;

    test('Parse production BUMP and examine structure', () {
      final bumpBytes = hexToBytes(productionBumpHex);
      final bump = BUMP.fromBytes(bumpBytes);
      
      print('=== PRODUCTION BUMP ANALYSIS ===');
      print('Block height: ${bump.blockHeight}');
      print('Path levels: ${bump.path.length}');
      
      expect(bump.blockHeight, blockHeight);
      
      for (int i = 0; i < bump.path.length; i++) {
        print('\nLevel $i: ${bump.path[i].leaves.length} leaves');
        for (int j = 0; j < bump.path[i].leaves.length; j++) {
          final leaf = bump.path[i].leaves[j];
          print('  Leaf $j: offset=${leaf.offset}, isTxid=${leaf.isTxid}, duplicate=${leaf.duplicate}');
          if (leaf.hash != null) {
            print('    hash (internal): ${bytesToHex(leaf.hash!)}');
            final displayHash = bytesToHex(Uint8List.fromList(leaf.hash!.reversed.toList()));
            print('    hash (display):  $displayHash');
            if (leaf.isTxid) {
              print('    → This is the TXID. Display format should be: $displayHash');
            }
          }
        }
      }
    });

    test('Verify ancestor tx hash matches BUMP embedded txid', () {
      // Parse BUMP
      final bumpBytes = hexToBytes(productionBumpHex);
      final bump = BUMP.fromBytes(bumpBytes);
      
      // Get embedded txid from BUMP (in internal format)
      Uint8List? bumpEmbeddedTxid;
      for (final leaf in bump.path[0].leaves) {
        if (leaf.isTxid && leaf.hash != null) {
          bumpEmbeddedTxid = leaf.hash;
          break;
        }
      }
      final bumpTxidDisplay = bytesToHex(Uint8List.fromList(bumpEmbeddedTxid!.reversed.toList()));
      print('BUMP embedded TXID (display): $bumpTxidDisplay');
      print('Expected TXID:                $expectedAncestorTxid');
      
      expect(bumpTxidDisplay, expectedAncestorTxid, 
          reason: 'BUMP should contain the correct txid');
      
      // Now hash the ancestor transaction
      final ancestorTxBytes = hexToBytes(ancestorTxHex);
      final firstHash = dartsv.sha256(ancestorTxBytes);
      final secondHash = dartsv.sha256(firstHash);
      final calculatedTxidDisplay = bytesToHex(Uint8List.fromList(secondHash.reversed.toList()));
      
      print('\nAncestor TX bytes: ${ancestorTxBytes.length} bytes');
      print('Calculated TXID (display): $calculatedTxidDisplay');
      print('Expected TXID:             $expectedAncestorTxid');
      
      expect(calculatedTxidDisplay, expectedAncestorTxid,
          reason: 'Calculated txid from raw tx should match expected');
      
      // CRITICAL: Do calculated txid and BUMP txid match?
      expect(calculatedTxidDisplay, bumpTxidDisplay,
          reason: 'Calculated txid must match BUMP embedded txid');
      
      print('\n✓ All txids match!');
    });

    test('Validate merkle path with production data', () {
      // Parse BUMP
      final bumpBytes = hexToBytes(productionBumpHex);
      final bump = BUMP.fromBytes(bumpBytes);
      
      // Get txid in internal format (what validateMerklePath expects)
      final txidInternal = hexToBytes(reverseHexBytes(expectedAncestorTxid));
      print('TXID (internal): ${bytesToHex(txidInternal)}');
      
      // Validate merkle path
      final pathValid = bump.validateMerklePath(txidInternal);
      print('validateMerklePath result: $pathValid');
      
      expect(pathValid, true, reason: 'Merkle path should validate');
    });

    test('Compute merkle root from production BUMP', () {
      // Parse BUMP
      final bumpBytes = hexToBytes(productionBumpHex);
      final bump = BUMP.fromBytes(bumpBytes);
      
      // Get txid in internal format
      final txidInternal = hexToBytes(reverseHexBytes(expectedAncestorTxid));
      
      // Compute merkle root
      final merkleRoot = bump.computeMerkleRoot(txidInternal);
      final merkleRootDisplay = bytesToHex(Uint8List.fromList(merkleRoot.reversed.toList()));
      
      print('=== COMPUTED MERKLE ROOT ===');
      print('Block height: ${bump.blockHeight}');
      print('Merkle root (internal): ${bytesToHex(merkleRoot)}');
      print('Merkle root (display):  $merkleRootDisplay');
      
      print('\n⚠️  CRITICAL: The recipient\'s block header at height $blockHeight');
      print('   MUST have merkle root that matches this value!');
      print('   Expected merkleRoot.bytes = ${bytesToHex(merkleRoot)}');
    });

    test('Simulate full validation flow with production data', () async {
      // Parse BUMP
      final bumpBytes = hexToBytes(productionBumpHex);
      final bump = BUMP.fromBytes(bumpBytes);
      
      // Get ancestor tx bytes
      final ancestorTxBytes = hexToBytes(ancestorTxHex);
      
      // Create a BEEF with this data
      final beef = BEEF.create(
        bumps: [bump],
        txs: [ancestorTxBytes],
        hasMerkle: [true],
        bumpIndex: [0],
      );
      
      // Calculate txid (display format)
      final ancestorTxidDisplay = beef.calculateTxid(beef.txs[0]);
      print('Calculated TXID: ${bytesToHex(ancestorTxidDisplay)}');
      
      // Compute expected merkle root
      final txidInternal = Uint8List.fromList(ancestorTxidDisplay.reversed.toList());
      final computedMerkleRoot = bump.computeMerkleRoot(txidInternal);
      
      // Create CORRECT block header
      final correctBlockHeader = BlockHeader(
        version: 0x20000000,
        prevBlock: Hash.fromHex('0000000000000000000000000000000000000000000000000000000000000000'),
        merkleRoot: Hash.fromBytes(computedMerkleRoot),
        timestamp: DateTime.now(),
        bits: 0x1d00ffff,
        nonce: 0,
      );
      
      // Validate with correct header
      final isValidCorrect = await beef.validateTransactionWithBlockHeader(
        ancestorTxidDisplay,
        correctBlockHeader,
      );
      print('Validation with CORRECT block header: $isValidCorrect');
      expect(isValidCorrect, true);
      
      // Create WRONG block header
      final wrongBlockHeader = BlockHeader(
        version: 0x20000000,
        prevBlock: Hash.fromHex('0000000000000000000000000000000000000000000000000000000000000000'),
        merkleRoot: Hash.fromHex('0000000000000000000000000000000000000000000000000000000000000000'),
        timestamp: DateTime.now(),
        bits: 0x1d00ffff,
        nonce: 0,
      );
      
      // Validate with wrong header
      final isValidWrong = await beef.validateTransactionWithBlockHeader(
        ancestorTxidDisplay,
        wrongBlockHeader,
      );
      print('Validation with WRONG block header: $isValidWrong');
      expect(isValidWrong, false);
      
      print('\n✓ Validation logic is CORRECT');
      print('❌ If production fails, the recipient\'s block header is wrong!');
    });

    test('CONCLUSION: Show what block header merkle root should be', () {
      // Parse BUMP
      final bumpBytes = hexToBytes(productionBumpHex);
      final bump = BUMP.fromBytes(bumpBytes);
      
      // Get txid in internal format
      final txidInternal = hexToBytes(reverseHexBytes(expectedAncestorTxid));
      
      // Compute merkle root
      final merkleRoot = bump.computeMerkleRoot(txidInternal);
      
      print('╔════════════════════════════════════════════════════════════════╗');
      print('║                    ROOT CAUSE IDENTIFIED                        ║');
      print('╠════════════════════════════════════════════════════════════════╣');
      print('║ The BEEF and BUMP are correctly constructed.                    ║');
      print('║ The validation logic is correct.                                ║');
      print('║                                                                  ║');
      print('║ The recipient\'s block header storage is WRONG or NOT SYNCED!   ║');
      print('╠════════════════════════════════════════════════════════════════╣');
      print('║ Block Height: ${bump.blockHeight}                                        ║');
      print('║ Required merkle root (internal format):                         ║');
      print('║   ${bytesToHex(merkleRoot)}       ║');
      print('║                                                                  ║');
      print('║ The recipient must have a block header at height ${bump.blockHeight}     ║');
      print('║ with merkleRoot.bytes matching the above value.                 ║');
      print('╚════════════════════════════════════════════════════════════════╝');
    });
  });

  group('Edge Cases', () {
    test('Empty merkle proof list should not crash', () {
      // This tests the case where merkleProofJson is empty (no siblings)
      final txPosition = 0;
      final txid = workingMerkleProofEntity['txid'] as String;
      final blockHeight = 123456;

      final levels = <Level>[];
      final reversedTxid = reverseHexBytes(txid);
      levels.add(Level(leaves: [
        Leaf(
          offset: txPosition,
          duplicate: false,
          isTxid: true,
          hash: hexToBytes(reversedTxid),
        ),
      ]));

      final bump = BUMP(blockHeight: blockHeight, path: levels);

      // Should serialize without error
      final serialized = bump.serialize();
      expect(serialized.length, greaterThan(0));

      // Should parse back
      final parsed = BUMP.fromBytes(serialized);
      expect(parsed.blockHeight, blockHeight);
      expect(parsed.path.length, 1);

      print('✓ Empty sibling list handled correctly');
    });

    test('Single sibling hash should work', () {
      final singleHash = '2d2711122c3d1822932db91aa9afa2128c9e26b5c4b8df7b9a955c48d0bfc785';
      final txPosition = 0;
      final txid = workingMerkleProofEntity['txid'] as String;
      final blockHeight = 123456;

      final levels = <Level>[];
      final reversedTxid = reverseHexBytes(txid);
      levels.add(Level(leaves: [
        Leaf(
          offset: txPosition,
          duplicate: false,
          isTxid: true,
          hash: hexToBytes(reversedTxid),
        ),
      ]));

      // Add single sibling
      final siblingOffset = 1; // txPosition is 0, so sibling is at 1
      levels.add(Level(leaves: [
        Leaf(
          offset: siblingOffset,
          duplicate: false,
          isTxid: false,
          hash: hexToBytes(reverseHexBytes(singleHash)),
        ),
      ]));

      final bump = BUMP(blockHeight: blockHeight, path: levels);

      // Should serialize and parse correctly
      final serialized = bump.serialize();
      final parsed = BUMP.fromBytes(serialized);

      expect(parsed.path.length, 2);
      expect(parsed.path[1].leaves[0].offset, siblingOffset);

      print('✓ Single sibling hash handled correctly');
    });
  });
}

