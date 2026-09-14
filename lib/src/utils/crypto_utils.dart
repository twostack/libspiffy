import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:dartsv/dartsv.dart';
import 'package:logging/logging.dart' hide Level;
import 'package:crypto/crypto.dart' as crypto;
import '../storage/read_model_storage.dart' show MerkleProof;
import 'bump.dart';

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

        // Keep every node, including the "*" duplicate marker: dropping it
        // shortens the path and yields a wrong root (audit SPV-08).
        for (final node in nodes) {
          if (node is String) {
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
    // Path hashes are display format (big-endian), "*" marks a duplicate;
    // BUMP.fromTscProof is the single BRC-74 builder.
    return BUMP.fromTscProof(
      blockHeight: blockHeight,
      txid: txid,
      index: brc71Path['index'] as int,
      nodes: (brc71Path['path'] as List).cast<String>(),
    );
  }

  /// Convert a BUMP format to BRC-71 format for a specific transaction
  ///
  /// @param bump The BUMP instance
  /// @param txid The transaction ID to extract the path for (in hex string format)
  /// @returns A Map containing the BRC-71 format merkle path
  static Map<String, dynamic> convertBumpToBrc71Path(BUMP bump, String txid) {
    // Accepts the txid in display hex (internal order is matched as well).
    final txidLeaf = bump.findTxidLeaf(Uint8List.fromList(hex.decode(reverseBytes(txid))));
    if (txidLeaf == null) {
      throw Exception('Transaction ID not found in BUMP');
    }
    final index = txidLeaf.offset;

    // Single-transaction block: no siblings, root == txid.
    if (bump.path.length == 1 && bump.path[0].leaves.length == 1) {
      return {'index': index, 'path': <String>[]};
    }

    // BRC-74 walk: the sibling at height h is at offset (index >> h) ^ 1.
    // Path hashes are display format; "*" marks a duplicate.
    final List<String> path = [];
    for (int h = 0; h < bump.path.length; h++) {
      final siblingOffset = (index >> h) ^ 1;
      Leaf? sibling;
      for (final leaf in bump.path[h].leaves) {
        if (leaf.offset == siblingOffset) {
          sibling = leaf;
          break;
        }
      }
      if (sibling == null) {
        throw Exception('BUMP is missing the sibling at height $h for txid $txid');
      }
      path.add(sibling.duplicate ? '*' : hex.encode(sibling.hash!.reversed.toList()));
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
      // A "*" node is a duplicate: the working hash is paired with itself.
      String reversedCurrentHash = reverseBytes(currentHash);
      String reversedNode = node == '*' ? reversedCurrentHash : reverseBytes(node);

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
    // BRC-74 walk; result in display (block explorer) hex.
    return bump.computeMerkleRootForBlockHeader(
        Uint8List.fromList(hex.decode(reverseBytes(txid))));
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
      return computeMerkleRootFromBump(bump, txid);
    } catch (e) {
      _cryptoLog.warning('Failed to extract merkle root from BUMP: $e');
      return null;
    }
  }

  /// Combine multiple BUMP objects into a single BUMP
  ///
  /// This is useful for merging proofs for multiple transactions in the same block.
  ///
  /// @param bumps List of BUMP objects to combine
  /// @returns A combined BUMP object
  static BUMP combineBumps(List<BUMP> bumps) => BUMP.merge(bumps);

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
    // Reverse bytes for Bitcoin's little-endian format ("*" = duplicate)
    String reversedTxid = reverseBytes(txid);
    List<String> reversedNodes =
        merkleProof.map((node) => node == '*' ? '*' : reverseBytes(node)).toList();
    String reversedMerkleRoot = reverseBytes(merkleRoot);

    // Start with the transaction hash
    String currentHash = reversedTxid;
    int currentIndex = index;

    // Apply each proof step
    for (int i = 0; i < reversedNodes.length; i++) {
      final node = reversedNodes[i] == '*' ? currentHash : reversedNodes[i];

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
    // txOrId and nodes are display format; "*" marks a duplicate sibling.
    // BUMP.fromTscProof is the single BRC-74 builder.
    return BUMP.fromTscProof(
      blockHeight: blockHeight,
      txid: tscProof['txOrId'] as String,
      index: tscProof['index'] as int,
      nodes: (tscProof['nodes'] as List<dynamic>).cast<String>(),
    );
  }

  /// Build a BUMP from a MerkleProof.
  ///
  /// Converts the [MerkleProof] storage format to the BUMP structure needed
  /// for BEEF packaging.
  ///
  /// Supports two storage formats:
  /// 1. Raw BUMP hex string (single element > 64 chars) — parsed verbatim.
  ///    This is what ARCActor and WalletProjection store; it preserves
  ///    multi-txid BUMPs and duplicate flags exactly as received.
  /// 2. List of sibling hashes (display hex, bottom-up, "*" = duplicate) with
  ///    `position` as the index — built with the BRC-74 builder.
  static BUMP buildBUMPFromMerkleProof(MerkleProof proof) {
    if (proof.merkleProof.length == 1 && proof.merkleProof[0].length > 64) {
      return BUMP.fromHex(proof.merkleProof[0]);
    }

    return BUMP.fromTscProof(
      blockHeight: proof.blockHeight,
      txid: proof.txid,
      index: proof.position,
      nodes: proof.merkleProof,
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
      // Determine if sibling is left or right ("*" = pair with self)
      final isRight = ((currentIndex >> i) & 1) == 0;
      final siblingHash = nodes[i] == '*' ? currentHash : nodes[i];
      
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
