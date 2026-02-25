import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:cryptography/cryptography.dart' as cryptography;
import 'package:dartsv/dartsv.dart';
import 'package:logging/logging.dart' hide Level;
import 'package:unorm_dart/unorm_dart.dart';
import 'package:crypto/crypto.dart' as crypto;
import '../storage/read_model_storage.dart' show MerkleProof;
import 'bump.dart'; // Correct import for BUMP class
import 'hex_utils.dart' as hex_utils;

final _cryptoLog = Logger('CryptoUtils');

class CryptoUtils {
  static Future<String> Function(Wordlist? wordlist, String wordListName)
      loadWordResource = (wordlist, wordListName) async {
    try {
      // Resolve the package URI to absolute URI
      final packageUri = Uri.parse('package:dartsv/src/bip39/wordlists/english.txt');
      final resolvedUri = await Isolate.resolvePackageUri(packageUri);

      if (resolvedUri == null) {
        throw Exception('Could not resolve package URI');
      }

      // Read based on platform
      String content = "";
      if (resolvedUri.scheme == 'file') {
        // Dart VM
        final file = File.fromUri(resolvedUri);
        content = await file.readAsString();
      }

      if (content.isEmpty) {
        throw Exception('Word list is empty');
      }
      return content;
    } catch (e) {
      throw Exception('Failed to load word list: $e');
    }
  };

  static String salt(String? password) {
    return 'mnemonic${password ?? ""}';
  }

  static Future<List<int>> toPbkdf2Seed(String mnemonic,
      [String password = '']) async {
    final mnemonicBuffer = nfkd(mnemonic);
    final saltBuffer = utf8.encode(salt(nfkd(password)));

    final pbkdf2 = cryptography.Pbkdf2(
        macAlgorithm: cryptography.Hmac.sha256(), iterations: 10000, bits: 256);

    final secret = await pbkdf2.deriveKeyFromPassword(
        password: mnemonicBuffer, nonce: saltBuffer);

    return await secret.extractBytes();
  }

  // For testing purposes
  static Future<bool> Function(String) validateWordsImpl = defaultValidateWords;
  static Future<String> Function(int strength) generateMnemonicImpl =
      defaultGenerateMnemonic;

  static Future<bool> defaultValidateWords(String text) async {
    try {
      return await Mnemonic().validateMnemonic2(text, loadWordResource);
    } catch (e) {
      throw Exception('Failed to validate mnemonic: $e');
    }
  }

  static Future<String> defaultGenerateMnemonic(int strength) async {
    try {
      return await Mnemonic().generateMnemonic2(strength: strength, loadWordResource);
    } catch (e) {
      throw Exception('Failed to generate mnemonic: $e');
    }
  }

  static Future<bool> validateWords(String text) => validateWordsImpl(text);
  static Future<String> generateMnemonic(int strength) => generateMnemonicImpl(strength);

  /// Convert a TSC format merkle proof to BRC-71 format merkle path
  ///
  /// The TSC format is returned by WhatsOnChain API, while BRC-71 is used by ARC service.
  /// This function converts between the two formats to ensure compatibility.
  ///
  /// According to BRC-71 spec (https://bsv.brc.dev/transactions/0071), the format should be:
  /// {
  ///   "index": <transaction index in block>,
  ///   "path": [<array of 32-byte hashes as hex strings>]
  /// }
  ///
  /// Expected TSC proof format:
  /// {
  ///   "index": <transaction index in block>,
  ///   "txOrId": "<transaction id>",
  ///   "target": "<target hash>",
  ///   "nodes": [<array of hashes as hex strings>]
  /// }
  ///
  /// @param tscProof The merkle proof in TSC format (from WhatsOnChain API)
  /// @returns A map containing the merkle path in BRC-71 format
  static Map<String, dynamic> convertTscProofToBrc71Path(
      Map<String, dynamic> tscProof) {
    // Initialize with default values
    int index = 0;
    List<String> path = [];

    try {
      // Extract the index from the proof
      if (tscProof.containsKey('index')) {
        index = tscProof['index'] as int;
      }

      // Extract the nodes from the proof
      if (tscProof.containsKey('nodes')) {
        final nodes = tscProof['nodes'] as List<dynamic>;

        // Convert the nodes to a path format (excluding duplicates marked with "*")
        for (final node in nodes) {
          // Skip duplicated nodes (marked with "*" in TSC format)
          if (node is String && node != "*") {
            path.add(node);
          }
        }
      } else {
      }
    } catch (e) {
      _cryptoLog.warning('Failed to convert TSC proof to BRC-71 path: $e');
    }

    // Create the BRC-71 format object according to spec
    return {
      'index': index,
      'path': path,
    };
  }

  /// Convert a TSC format merkle proof to BRC-71 binary format
  ///
  /// The TSC format is returned by WhatsOnChain API, while BRC-71 is used by ARC service.
  /// This function converts the TSC format to a binary representation of BRC-71.
  ///
  /// According to BRC-71 spec (https://bsv.brc.dev/transactions/0071), the binary format is:
  /// - VarInt for index (transaction index in block)
  /// - VarInt for nLeaves (number of hashes in the path)
  /// - 32 bytes for each leaf hash
  ///
  /// @param tscProof The merkle proof in TSC format (from WhatsOnChain API)
  /// @returns A Uint8List containing the binary BRC-71 format
  static Uint8List convertTscProofToBrc71Binary(Map<String, dynamic> tscProof) {
    try {
      // First convert to BRC-71 JSON format
      final brc71Json = convertTscProofToBrc71Path(tscProof);

      // Extract the values
      final int index = brc71Json['index'] as int;
      final List<String> path = brc71Json['path'].cast<String>();

      // Calculate the total size needed for the binary format
      // We need:
      // - 1-9 bytes for index VarInt
      // - 1-9 bytes for nLeaves VarInt
      // - 32 bytes for each leaf
      final int maxSize = 18 + (path.length * 32);
      final ByteData buffer = ByteData(maxSize);
      int offset = 0;

      // Write the index as VarInt
      offset += _writeVarInt(buffer, offset, index);

      // Write the number of leaves as VarInt
      offset += _writeVarInt(buffer, offset, path.length);

      // Write each leaf (32 bytes each)
      for (final leaf in path) {
        if (leaf.length != 64) {
          continue;
        }

        // Convert hex string to bytes
        final List<int> leafBytes = hex.decode(leaf);

        // According to BRC-71 spec, we don't need to reverse the bytes
        // Write the leaf bytes to the buffer
        for (int i = 0; i < leafBytes.length; i++) {
          buffer.setUint8(offset + i, leafBytes[i]);
        }
        offset += 32;
      }

      // Create a Uint8List with the exact size needed
      return Uint8List.view(buffer.buffer, 0, offset);
    } catch (e) {
      _cryptoLog.warning('Failed to convert TSC proof to BRC-71 binary: $e');
      // Return empty array in case of error
      return Uint8List(0);
    }
  }

  /// Helper method to write a VarInt to a ByteData buffer
  ///
  /// @param buffer The ByteData buffer to write to
  /// @param offset The current offset in the buffer
  /// @param value The integer value to write as a VarInt
  /// @returns The number of bytes written
  static int _writeVarInt(ByteData buffer, int offset, int value) {
    if (value < 0xFD) {
      // Single byte for values 0-252
      buffer.setUint8(offset, value);
      return 1;
    } else if (value <= 0xFFFF) {
      // 0xFD marker + 2 bytes for values up to 65,535
      buffer.setUint8(offset, 0xFD);
      buffer.setUint16(offset + 1, value, Endian.little);
      return 3;
    } else if (value <= 0xFFFFFFFF) {
      // 0xFE marker + 4 bytes for values up to 4,294,967,295
      buffer.setUint8(offset, 0xFE);
      buffer.setUint32(offset + 1, value, Endian.little);
      return 5;
    } else {
      // 0xFF marker + 8 bytes for larger values
      buffer.setUint8(offset, 0xFF);
      buffer.setUint32(offset + 1, value & 0xFFFFFFFF, Endian.little);
      buffer.setUint32(offset + 5, (value >> 32) & 0xFFFFFFFF, Endian.little);
      return 9;
    }
  }

  /// Convert a BRC-71 format merkle path to BUMP format
  ///
  /// This function converts a BRC-71 merkle path to the more efficient BUMP format
  /// which can represent multiple paths and includes block height information.
  ///
  /// @param brc71Path The merkle path in BRC-71 format
  /// @param blockHeight The block height for the transaction
  /// @param txid The transaction ID (in hex string format)
  /// @returns A BUMP instance that can be serialized
  static BUMP convertBrc71PathToBump(
      Map<String, dynamic> brc71Path, int blockHeight, String txid) {
    final int index = brc71Path['index'] as int;
    final List<String> path = brc71Path['path'].cast<String>();

    // CRITICAL: BUMP stores hashes in internal format (little-endian)
    // BRC-71 provides them in display format (big-endian), so we must reverse
    
    // Create leaves for level 0 (transaction level)
    final List<Leaf> level0Leaves = [
      Leaf(
        offset: index,
        duplicate: false,
        isTxid: true,
        hash: Uint8List.fromList(hex.decode(reverseBytes(txid))),
      )
    ];

    // Create the levels array
    final List<Level> levels = [Level(leaves: level0Leaves)];

    // Add the path elements as additional levels
    for (int i = 0; i < path.length; i++) {
      // Calculate the offset for this level
      // For a binary tree, the offset at level i+1 is index >> i
      final int offset = (index >> i) ^ 1; // Sibling offset

      final List<Leaf> levelLeaves = [
        Leaf(
          offset: offset,
          duplicate: false,
          isTxid: false,
          hash: Uint8List.fromList(hex.decode(reverseBytes(path[i]))),
        )
      ];

      levels.add(Level(leaves: levelLeaves));
    }

    return BUMP(
      blockHeight: blockHeight,
      path: levels,
    );
  }

  /// Convert a BUMP format to BRC-71 format for a specific transaction
  ///
  /// @param bump The BUMP instance
  /// @param txid The transaction ID to extract the path for (in hex string format)
  /// @returns A Map containing the BRC-71 format merkle path
  static Map<String, dynamic> convertBumpToBrc71Path(BUMP bump, String txid) {
    final txidBytes = Uint8List.fromList(hex.decode(txid));

    // Find the txid in the first level of the BUMP
    final level0 = bump.path[0];
    int? index;

    for (int i = 0; i < level0.leaves.length; i++) {
      final leaf = level0.leaves[i];
      if (leaf.isTxid && !leaf.duplicate && leaf.hash != null) {
        if (_compareBytes(leaf.hash!, txidBytes)) {
          index = leaf.offset;
          break;
        }
      }
    }

    if (index == null) {
      throw Exception('Transaction ID not found in BUMP');
    }

    // Extract the path for this txid
    final List<String> path = [];

    for (int i = 1; i < bump.path.length; i++) {
      final level = bump.path[i];
      final siblingOffset = (index >> (i - 1)) ^ 1;

      // Find the sibling hash
      for (final leaf in level.leaves) {
        if (leaf.offset == siblingOffset && leaf.hash != null) {
          path.add(hex.encode(leaf.hash!));
          break;
        }
      }
    }

    return {
      'index': index,
      'path': path,
    };
  }

  /// Validate a merkle proof directly
  ///
  /// This function validates that a transaction is included in a block by checking
  /// its merkle proof against the block's merkle root.
  ///
  /// @param txid The transaction ID (in hex string format)
  /// @param merkleRoot The merkle root of the block (in hex string format)
  /// @param brc71Path The merkle path in BRC-71 format
  /// @returns True if the proof is valid, false otherwise
  static bool validateMerkleProof(
      String txid, String merkleRoot, Map<String, dynamic> brc71Path) {
    // Extract the index and path from the BRC-71 format
    final index = brc71Path['index'] as int;
    final path = (brc71Path['path'] as List).map((node) => node.toString()).toList();
    
    // Use the byte-reversed validation method which handles Bitcoin's little-endian format correctly
    return validateMerkleProofWithByteReversal(txid, path, merkleRoot, index);
  }

  /// Compute the merkle root from a BRC-71 path
  ///
  /// @param txid The transaction ID (in hex string format)
  /// @param brc71Path The merkle path in BRC-71 format
  /// @returns The computed merkle root (in hex string format)
  static String computeMerkleRootFromBrc71(
      String txid, Map<String, dynamic> brc71Path) {
    // Extract the index and path from the BRC-71 format
    final index = brc71Path['index'] as int;
    final path = (brc71Path['path'] as List).map((node) => node.toString()).toList();
    
    // Start with the transaction hash
    String currentHash = txid;
    int currentIndex = index;
    
    // Apply each proof step with byte reversal for Bitcoin's little-endian format
    for (int i = 0; i < path.length; i++) {
      final node = path[i];
      
      // Determine if we need to concatenate left+right or right+left
      bool isLeftSide = (currentIndex % 2 == 0);
      String concatenated;
      
      // First, reverse both hashes (to get little-endian format)
      String reversedCurrentHash = reverseBytes(currentHash);
      String reversedNode = reverseBytes(node);
      
      if (isLeftSide) {
        // Our txid is on the left side, so concatenate with the right sibling
        concatenated = reversedCurrentHash + reversedNode;
      } else {
        // Our txid is on the right side, so concatenate with the left sibling
        concatenated = reversedNode + reversedCurrentHash;
      }
      
      // Double-SHA256 hash the concatenated value
      String hashedValue = doubleSha256(concatenated);
      
      // Convert back to big-endian format for the next round
      currentHash = reverseBytes(hashedValue);
      
      // Update the index for the next level of the tree
      currentIndex = currentIndex ~/ 2;
    }
    
    // Return the computed merkle root
    return currentHash;
  }

  /// Compute the merkle root from a BUMP format for a specific transaction
  ///
  /// @param bump The BUMP instance
  /// @param txid The transaction ID to compute the merkle root for (in hex string format)
  /// @returns The computed merkle root (in hex string format)
  static String computeMerkleRootFromBump(BUMP bump, String txid) {
    // Convert BUMP to BRC-71 format
    final brc71Path = convertBumpToBrc71Path(bump, txid);
    
    // Use the updated computeMerkleRootFromBrc71 method which handles byte reversal
    return computeMerkleRootFromBrc71(txid, brc71Path);
  }

  /// Extract the merkle root from a BUMP object
  ///
  /// This function computes the merkle root from a transaction ID and its merkle path
  /// represented as a BUMP object. This is useful for validating that a transaction
  /// is included in a block by comparing the computed merkle root with the one in the block header.
  ///
  /// @param bump The BUMP object containing the merkle path
  /// @param txid The transaction ID in hex string format
  /// @returns The computed merkle root in hex string format, or null if computation fails
  static String? extractMerkleRootFromBump(BUMP bump, String txid) {
    try {
      // Convert BUMP to BRC-71 format
      final brc71Path = convertBumpToBrc71Path(bump, txid);
      
      // If conversion failed, return null
      if (brc71Path.isEmpty) {
        return null;
      }
      
      // Use the updated computeMerkleRootFromBrc71 method which handles byte reversal
      return computeMerkleRootFromBrc71(txid, brc71Path);
    } catch (e) {
      _cryptoLog.warning('Failed to extract merkle root from BUMP: $e');
      return null;
    }
  }

  /// Helper function to compare two byte arrays
  static bool _compareBytes(Uint8List a, Uint8List b) {
    if (a.length != b.length) {
      return false;
    }

    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) {
        return false;
      }
    }

    return true;
  }

  /// Combine multiple BUMP objects into a single BUMP
  ///
  /// This is useful for merging proofs for multiple transactions in the same block.
  ///
  /// @param bumps List of BUMP objects to combine
  /// @returns A combined BUMP object
  static BUMP combineBumps(List<BUMP> bumps) {
    if (bumps.isEmpty) {
      throw Exception('Cannot combine empty list of BUMPs');
    }

    final int blockHeight = bumps[0].blockHeight;

    // Check that all BUMPs are for the same block height
    for (final bump in bumps) {
      if (bump.blockHeight != blockHeight) {
        throw Exception('Cannot combine BUMPs with different block heights');
      }
    }

    // Initialize the combined BUMP with the first BUMP's structure
    final List<Level> combinedPath = [];
    for (int h = 0; h < bumps[0].path.length; h++) {
      combinedPath.add(Level(leaves: []));
    }

    // Merge all BUMPs
    for (final bump in bumps) {
      for (int h = 0; h < bump.path.length; h++) {
        final level = bump.path[h];

        for (final leaf in level.leaves) {
          // Check if this leaf already exists in the combined BUMP
          bool exists = false;
          for (final existingLeaf in combinedPath[h].leaves) {
            if (existingLeaf.offset == leaf.offset) {
              exists = true;

              // If the existing leaf doesn't have txid flag but the new one does,
              // replace the existing leaf with a new one that has isTxid set to true
              if (leaf.isTxid && !existingLeaf.isTxid) {
                // Create a new leaf with the updated isTxid value
                final updatedLeaf = Leaf(
                  offset: existingLeaf.offset,
                  duplicate: existingLeaf.duplicate,
                  isTxid: true, // Set to true
                  hash: existingLeaf.hash,
                );

                // Replace the existing leaf in the list
                final int leafIndex =
                    combinedPath[h].leaves.indexOf(existingLeaf);
                combinedPath[h].leaves[leafIndex] = updatedLeaf;
              }

              break;
            }
          }

          // If the leaf doesn't exist, add it
          if (!exists) {
            combinedPath[h].leaves.add(Leaf(
                  offset: leaf.offset,
                  duplicate: leaf.duplicate,
                  isTxid: leaf.isTxid,
                  hash: leaf.hash,
                ));
          }
        }
      }
    }

    return BUMP(
      blockHeight: blockHeight,
      path: combinedPath,
    );
  }

  /// Double SHA-256 hash of a hex string
  static String doubleSha256(String hexString) {
    final bytes = hex.decode(hexString);
    final hash1 = crypto.sha256.convert(bytes);
    final hash2 = crypto.sha256.convert(hash1.bytes);
    return hex.encode(hash2.bytes);
  }

  /// Reverses bytes in a hex string (for Bitcoin's little-endian format)
  static String reverseBytes(String hexString) {
    if (hexString.length % 2 != 0) {
      throw Exception('Hex string must have an even number of characters');
    }
    
    final result = StringBuffer();
    for (int i = hexString.length - 2; i >= 0; i -= 2) {
      result.write(hexString.substring(i, i + 2));
    }
    
    return result.toString();
  }

  /// Validates a merkle proof using Bitcoin's little-endian byte order
  /// 
  /// This method handles the byte reversal required for Bitcoin merkle trees
  /// - txid: The transaction ID to verify (in regular hex format)
  /// - merkleProof: List of merkle proof nodes (in regular hex format)
  /// - merkleRoot: The merkle root to validate against (in regular hex format)
  /// - index: The index of the transaction in the block
  /// 
  /// Returns true if the proof is valid
  static bool validateMerkleProofWithByteReversal(
    String txid, 
    List<String> merkleProof, 
    String merkleRoot, 
    int index
  ) {
    // Reverse bytes for Bitcoin's little-endian format
    String reversedTxid = reverseBytes(txid);
    List<String> reversedNodes = merkleProof.map((node) => reverseBytes(node)).toList();
    String reversedMerkleRoot = reverseBytes(merkleRoot);

    // Start with the transaction hash
    String currentHash = reversedTxid;
    int currentIndex = index;
    
    // Apply each proof step
    for (int i = 0; i < reversedNodes.length; i++) {
      final node = reversedNodes[i];
      
      // Determine if we need to concatenate left+right or right+left
      bool isLeftSide = (currentIndex % 2 == 0);
      String concatenated;
      
      if (isLeftSide) {
        // Our txid is on the left side, so concatenate with the right sibling
        concatenated = currentHash + node;
      } else {
        // Our txid is on the right side, so concatenate with the left sibling
        concatenated = node + currentHash;
      }
      
      // Double-SHA256 hash the concatenated value
      currentHash = doubleSha256(concatenated);
      
      // Update the index for the next level of the tree
      currentIndex = currentIndex ~/ 2;
    }
    
    // Check if our computed merkle root matches the expected merkle root
    return currentHash == reversedMerkleRoot;
  }

  /// Create a BUMP directly from a TSC proof
  ///
  /// This is a convenient method for creating a BUMP from a TSC proof without
  /// needing to convert to BRC-71 format as an intermediate step.
  ///
  /// @param tscProof The merkle proof in TSC format (from WhatsOnChain API)
  /// @param blockHeight The block height for the transaction
  /// @returns A BUMP instance that can be serialized
  static BUMP createBumpFromTscProof(Map<String, dynamic> tscProof, int blockHeight) {
    // Extract data from the TSC proof - no need to reverse txOrId as it's already in display format
    final txid = Uint8List.fromList(hex.decode(reverseBytes(tscProof['txOrId'] as String)));
    
    // Convert nodes to internal format (reversed from display format)
    final nodesList = (tscProof['nodes'] as List<dynamic>).map(
        (node) => Uint8List.fromList(hex.decode(reverseBytes(node as String)))
    ).toList();
    
    // Calculate tree height based on number of nodes
    final treeHeight = nodesList.length + 1;
    
    // Create path array with leaves
    final path = <Level>[];
    
    // Level 0: Transaction ID
    final level0 = Level(leaves: [
      Leaf(
        offset: tscProof['index'] as int,
        duplicate: false,
        isTxid: true,
        hash: txid,
      ),
    ]);
    path.add(level0);
    
    // Add nodes as subsequent levels
    for (int i = 0; i < nodesList.length; i++) {
      final nodeHash = nodesList[i];
      
      // Determine the position of this node based on the transaction index
      // In a Merkle tree, if index bit at level i is 0, then sibling is at (index | (1 << i))
      // If index bit at level i is 1, then sibling is at (index & ~(1 << i))
      final indexBit = ((tscProof['index'] as int) >> i) & 1;
      final siblingOffset = indexBit == 0 
          ? ((tscProof['index'] as int) | (1 << i)) 
          : ((tscProof['index'] as int) & ~(1 << i));
      
      final level = Level(leaves: [
        Leaf(
          offset: siblingOffset,
          duplicate: false,
          isTxid: false,
          hash: nodeHash,
        ),
      ]);
      path.add(level);
    }
    
    return BUMP(
      blockHeight: blockHeight,
      path: path,
    );
  }

  /// Build a BUMP from a MerkleProof.
  ///
  /// Converts the [MerkleProof] storage format to the BUMP structure needed
  /// for BEEF packaging.
  ///
  /// Supports two storage formats:
  /// 1. Raw BUMP hex string (single element > 64 chars) - parse directly
  /// 2. List of sibling hashes (each 64 chars) - build BUMP from scratch
  static BUMP buildBUMPFromMerkleProof(MerkleProof proof) {
    // Check if merkleProof contains a raw BUMP serialization (single element > 64 chars)
    // or a list of sibling hashes (each exactly 64 chars for a 32-byte hash)
    if (proof.merkleProof.length == 1 && proof.merkleProof[0].length > 64) {
      // This is a raw BUMP hex string - parse it directly
      try {
        final bumpBytes = Uint8List.fromList(hex.decode(proof.merkleProof[0]));
        final bump = BUMP.fromBytes(bumpBytes);
        return bump;
      } catch (e) {
        rethrow;
      }
    }

    // Otherwise, build BUMP from sibling hashes (original logic)
    final levels = <Level>[];

    // Level 0: Transaction ID at its position in the block
    // CRITICAL: proof.txid is in display format (big-endian) from database
    // but BUMP stores txids in internal format (little-endian)
    final reversedTxid = hex_utils.reverseHexBytes(proof.txid);
    levels.add(Level(leaves: [
      Leaf(
        offset: proof.position,
        duplicate: false,
        isTxid: true,
        hash: Uint8List.fromList(hex.decode(reversedTxid)),
      ),
    ]));

    // Subsequent levels: merkle path siblings with calculated offsets
    // Each hash in the merkleProof list is a sibling at the next level up
    for (int i = 0; i < proof.merkleProof.length; i++) {
      // Calculate sibling offset using bit manipulation
      // In a Merkle tree, if index bit at level i is 0, then sibling is at (index | (1 << i))
      // If index bit at level i is 1, then sibling is at (index & ~(1 << i))
      final indexBit = (proof.position >> i) & 1;
      final siblingOffset = indexBit == 0
          ? (proof.position | (1 << i))
          : (proof.position & ~(1 << i));

      // CRITICAL: proof.merkleProof[i] is in display format (big-endian) from database
      // but BUMP stores hashes in internal format (little-endian)
      final siblingHashHex = proof.merkleProof[i];
      final reversedHash = hex_utils.reverseHexBytes(siblingHashHex);

      levels.add(Level(leaves: [
        Leaf(
          offset: siblingOffset,
          duplicate: false,
          isTxid: false,
          hash: Uint8List.fromList(hex.decode(reversedHash)),
        ),
      ]));
    }

    return BUMP(
      blockHeight: proof.blockHeight,
      path: levels,
    );
  }

  /// Compute a merkle root from a TSC proof for verification
  ///
  /// This method manually calculates the merkle root by walking up the merkle tree
  /// using the transaction hash and the sibling hashes provided in the proof.
  /// This is useful for verifying that a proof is valid by comparing the computed
  /// root with the one in the block header.
  ///
  /// @param tscProof The merkle proof in TSC format (from WhatsOnChain API)
  /// @returns A Map containing the computed merkle root and the transaction index
  static Map<String, dynamic> computeMerkleRootFromTscProof(Map<String, dynamic> tscProof) {
    // Use the TSC proof directly without byte reversal for the calculation
    final txid = tscProof['txOrId'] as String;
    final txIndex = tscProof['index'] as int;
    final nodes = (tscProof['nodes'] as List<dynamic>).cast<String>();
    
    // Start with the transaction hash - already in correct format for calculation
    String currentHash = txid;
    int currentIndex = txIndex;
    
    for (int i = 0; i < nodes.length; i++) {
      // Determine if sibling is left or right
      final isRight = ((currentIndex >> i) & 1) == 0;
      final siblingHash = nodes[i];
      
      // Combine current hash with sibling hash in correct order
      String concatenated;
      if (isRight) {
        // Current hash is on left, sibling on right
        concatenated = currentHash + siblingHash;
      } else {
        // Sibling on left, current hash on right
        concatenated = siblingHash + currentHash;
      }
      
      // Double-SHA256 hash the concatenated value
      currentHash = doubleSha256(concatenated);
      
      // Move to parent index
      currentIndex = currentIndex >> 1;
    }
    
    // The block header merkle root is in a specific byte order (display format)
    // Our computation gives the internal format, which needs to be byte-reversed to match
    // the block header format for direct comparison
    final blockHeaderFormatRoot = reverseBytes(currentHash);
    
    return {
      'merkleRoot': blockHeaderFormatRoot, // Return in block header format for direct comparison
      'internalMerkleRoot': currentHash,   // Also include internal format for reference
      'txIndex': txIndex
    };
  }
}
