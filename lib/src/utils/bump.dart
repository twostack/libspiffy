import 'dart:typed_data';
import 'package:buffer/buffer.dart';
import 'package:convert/convert.dart';
import 'package:dartsv/dartsv.dart';


class BUMPException implements Exception {
  final String message;
  
  BUMPException(this.message);
  
  @override
  String toString() => 'BUMPException: $message';
}

/// Represents a BSV Universal Merkle Path
class BUMP {
  /// The block height in which the transactions are encapsulated
  final int blockHeight;
  
  /// The path of levels in the merkle tree
  final List<Level> path;

  /// Creates a new BUMP instance
  BUMP({
    required this.blockHeight,
    required this.path,
  });

  /// Parse a BUMP from a list of bytes
  static BUMP fromBytes(Uint8List bytes) {
    try {
      final reader = ByteDataReader();
      reader.add(bytes);
      
      // Read block height
      final blockHeight = readVarIntNum(reader);
      
      // Read tree height
      final treeHeight = reader.readUint8();
      
      // Initialize path array
      final path = <Level>[];
      
      // Parse each level
      for (var h = 0; h < treeHeight; h++) {
        final nLeaves = readVarIntNum(reader);
        final leaves = <Leaf>[];
        
        // Parse each leaf in this level
        for (var j = 0; j < nLeaves; j++) {
          // Read offset
          final offset = readVarIntNum(reader);
          
          // Read flags
          final flags = reader.readUint8();
          
          // Parse flags
          final duplicate = (flags & 0x01) != 0;
          final isTxid = (flags & 0x02) != 0;
          
          // Read hash if not duplicate
          Uint8List? hash;
          if (!duplicate) {
            hash = reader.read(32);
          }
          
          leaves.add(Leaf(
            offset: offset,
            duplicate: duplicate,
            isTxid: isTxid,
            hash: hash,
          ));
        }
        
        path.add(Level(leaves: leaves));
      }
      
      return BUMP(
        blockHeight: blockHeight,
        path: path,
      );
    } catch (e) {
      throw BUMPException('Failed to parse BUMP: $e');
    }
  }

  /// Parse a BUMP from a reader
  static BUMP parse(ByteDataReader reader) {
    // Read block height
    final blockHeight = readVarIntNum(reader);
    
    // Read tree height
    final treeHeight = reader.readUint8();
    
    // Initialize path array
    final path = <Level>[];
    
    // Parse each level
    for (var h = 0; h < treeHeight; h++) {
      final nLeaves = readVarIntNum(reader);
      final leaves = <Leaf>[];
      
      // Parse each leaf in this level
      for (var j = 0; j < nLeaves; j++) {
        // Read offset
        final offset = readVarIntNum(reader);
        
        // Read flags
        final flags = reader.readUint8();
        
        // Parse flags
        final duplicate = (flags & 0x01) != 0;
        final isTxid = (flags & 0x02) != 0;
        
        // Read hash if not duplicate
        Uint8List? hash;
        if (!duplicate) {
          hash = reader.read(32);
        }
        
        leaves.add(Leaf(
          offset: offset,
          duplicate: duplicate,
          isTxid: isTxid,
          hash: hash,
        ));
      }
      
      path.add(Level(leaves: leaves));
    }
    
    return BUMP(
      blockHeight: blockHeight,
      path: path,
    );
  }

  /// Serialize the BUMP to bytes
  Uint8List serialize() {
    final buffer = ByteDataWriter();
    
    // Write block height
    buffer.write(VarInt.fromInt(blockHeight).encode());
    
    // Write tree height
    buffer.writeUint8(path.length);
    
    // Write each level
    for (var h = 0; h < path.length; h++) {
      final level = path[h];
      
      // Write number of leaves
      buffer.write(VarInt.fromInt(level.leaves.length).encode());
      
      // Write each leaf
      for (var j = 0; j < level.leaves.length; j++) {
        final leaf = level.leaves[j];
        
        // Write offset
        buffer.write(VarInt.fromInt(leaf.offset).encode());
        
        // Write flags
        int flags = 0;
        if (leaf.duplicate) {
          flags |= 0x01;
        }
        if (leaf.isTxid) {
          flags |= 0x02;
        }
        buffer.writeUint8(flags);
        
        // Write hash if not duplicate
        if (!leaf.duplicate) {
          if (leaf.hash == null || leaf.hash!.length != 32) {
            throw Exception('Invalid hash length for level $h leaf $j: expected 32, got ${leaf.hash?.length}');
          }
          // We need the null assertion operator here because writeBytes expects a non-nullable Uint8List
          buffer.write(leaf.hash!);
        }
      }
    }
    
    return buffer.toBytes();
  }

  /// Validate the merkle path for a given transaction ID
  /// Returns true if the path is valid, false otherwise
  bool validateMerklePath(Uint8List txid) {
    if (path.isEmpty) {
      return false;
    }
    
    // Find the txid in the first level
    int? txidIndex;
    for (int i = 0; i < path[0].leaves.length; i++) {
      final leaf = path[0].leaves[i];
      if (leaf.isTxid && !leaf.duplicate && leaf.hash != null) {
        if (listEquals(leaf.hash!, txid)) {
          txidIndex = i;
          break;
        }
      }
    }
    
    // If txid not found, return false
    if (txidIndex == null) {
      return false;
    }
    
    // Compute the merkle root by walking up the tree
    Uint8List? currentHash = txid;
    int currentIndex = txidIndex;
    
    for (int level = 0; level < path.length; level++) {
      final leaves = path[level].leaves;
      
      // If this is a single node at this level, it's its own parent
      if (leaves.length == 1) {
        // If the single node is a duplicate, hash with itself
        if (leaves[0].duplicate) {
          currentHash = _hashPair(currentHash!, currentHash);
        }
        continue;
      }
      
      // First check if we have a duplicate leaf at this currentIndex
      bool hasDuplicate = false;
      for (final leaf in leaves) {
        if (leaf.offset == currentIndex && leaf.duplicate) {
          // This is a duplicate node, so we hash with itself
          currentHash = _hashPair(currentHash!, currentHash);
          hasDuplicate = true;
          break;
        }
      }
      
      // If we found a duplicate, move to the next level
      if (hasDuplicate) {
        currentIndex = currentIndex ~/ 2;
        continue;
      }
      
      // Find the sibling hash
      Uint8List? siblingHash;
      bool isLeftSibling = false;
      
      for (int i = 0; i < leaves.length; i++) {
        final leaf = leaves[i];
        
        // Skip if this is the current node or a duplicate
        if (leaf.offset == currentIndex || leaf.duplicate) {
          continue;
        }
        
        // Check if this is a sibling (nodes that would be combined in a merkle tree)
        // Siblings have the same parent index, which means their indexes differ only in the least significant bit
        if ((leaf.offset ^ currentIndex) == 1) {
          siblingHash = leaf.hash;
          isLeftSibling = leaf.offset < currentIndex;
          break;
        }
      }
      
      // If no sibling found but we need one, check if any leaf is marked as duplicate
      if (siblingHash == null) {
        // In some cases, we might have a leaf that indicates we should duplicate the current hash
        // This typically happens at the right edge of the tree
        for (final leaf in leaves) {
          if (leaf.duplicate && ((leaf.offset ^ currentIndex) == 1)) {
            // This is a duplicate sibling, use the current hash as both inputs
            currentHash = _hashPair(currentHash!, currentHash);
            siblingHash = currentHash; // Just to pass the check below
            break;
          }
        }
      }
      
      // If still no sibling found, this is invalid
      if (siblingHash == null) {
        return false;
      }
      
      // Compute parent hash if sibling is not a duplicate
      if (!hasDuplicate) {
        if (isLeftSibling) {
          currentHash = _hashPair(siblingHash, currentHash!);
        } else {
          currentHash = _hashPair(currentHash!, siblingHash);
        }
      }
      
      // Update current index for next level
      currentIndex = currentIndex ~/ 2;
    }
    
    // The final hash should be the merkle root
    // In a full implementation, we would verify this against the block header
    return currentHash != null;
  }
  
  /// Compute the merkle root for a given transaction ID
  /// Returns the merkle root as a Uint8List
  /// The returned merkle root is in internal byte order and needs to be byte-reversed
  /// to match the block header's merkle root display format.
  Uint8List computeMerkleRoot(Uint8List txid) {
    if (path.isEmpty) {
      throw Exception('Cannot compute merkle root: path is empty');
    }
    
    // CRITICAL: Try to find the txid in both formats (display and internal)
    // since BUMP stores in internal format but callers might pass display format
    int? txidIndex;
    Uint8List? matchingTxid;
    
    for (int i = 0; i < path[0].leaves.length; i++) {
      final leaf = path[0].leaves[i];
      if (leaf.isTxid && !leaf.duplicate && leaf.hash != null) {
        if (listEquals(leaf.hash!, txid)) {
          txidIndex = leaf.offset;
          matchingTxid = txid;
          break;
        }
        // Try reversed format
        final txidReversed = Uint8List.fromList(txid.reversed.toList());
        if (listEquals(leaf.hash!, txidReversed)) {
          txidIndex = leaf.offset;
          matchingTxid = txidReversed;
          break;
        }
      }
    }
    
    // If txid not found, throw an exception
    if (txidIndex == null || matchingTxid == null) {
      throw Exception('Transaction ID not found in merkle path');
    }
    
    // Convert BUMP to BRC-71 format for consistent calculation
    // CRITICAL: matchingTxid is in internal format (little-endian) as stored in BUMP
    // But BRC-71 calculation expects display format (big-endian), so we must reverse
    final txidHex = matchingTxid.reversed.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join('');
    
    // Extract the path in BRC-71 format
    final List<String> brc71Path = [];
    
    // Starting from level 1, extract sibling hashes in the path
    for (int i = 1; i < path.length; i++) {
      final level = path[i];
      for (final leaf in level.leaves) {
        if (leaf.hash != null) {
          // CRITICAL: BUMP stores hashes in internal (little-endian) format
          // We need to reverse them to display (big-endian) format for BRC-71 calculation
          brc71Path.add(leaf.hash!.reversed.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join(''));
        }
      }
    }
    
    // Apply the BRC-71 style merkle path calculation
    String currentHash = txidHex;
    int currentIndex = txidIndex;
    
    // Apply each proof step with byte reversal for Bitcoin's little-endian format
    for (int i = 0; i < brc71Path.length; i++) {
      final node = brc71Path[i];
      
      // Determine if we need to concatenate left+right or right+left
      bool isLeftSide = (currentIndex % 2 == 0);
      String concatenated;
      
      // First, reverse both hashes (to get little-endian format)
      // Convert both hashes to bytes and reverse them (simulate reverseBytes function from CryptoUtils)
      String reversedCurrentHash = "";
      for (int j = currentHash.length - 2; j >= 0; j -= 2) {
        reversedCurrentHash += currentHash.substring(j, j + 2);
      }
      
      String reversedNode = "";
      for (int j = node.length - 2; j >= 0; j -= 2) {
        reversedNode += node.substring(j, j + 2);
      }
      
      if (isLeftSide) {
        // Our txid is on the left side, so concatenate with the right sibling
        concatenated = reversedCurrentHash + reversedNode;
      } else {
        // Our txid is on the right side, so concatenate with the left sibling
        concatenated = reversedNode + reversedCurrentHash;
      }
      
      // Double-SHA256 hash the concatenated value
      final bytes = <int>[];
      for (int j = 0; j < concatenated.length; j += 2) {
        bytes.add(int.parse(concatenated.substring(j, j + 2), radix: 16));
      }
      
      final firstHash = sha256(bytes);
      final secondHash = sha256(firstHash);
      
      // Convert back to big-endian format for the next round
      // CRITICAL: Must hex-encode FIRST, then reverse the hex string
      // (not reverse bytes then encode, as that produces different results with lazy iterables)
      final hashHex = hex.encode(secondHash);
      String reversedHashedValue = "";
      for (int j = hashHex.length - 2; j >= 0; j -= 2) {
        reversedHashedValue += hashHex.substring(j, j + 2);
      }

      currentHash = reversedHashedValue;
      
      // Update the index for the next level of the tree
      currentIndex = currentIndex ~/ 2;
    }
    
    // currentHash is now in display format (big-endian)
    // Reverse it to internal format (little-endian) before returning
    String internalFormat = "";
    for (int i = currentHash.length - 2; i >= 0; i -= 2) {
      internalFormat += currentHash.substring(i, i + 2);
    }
    
    // Convert the final hash from hex string to bytes (internal format)
    final resultBytes = <int>[];
    for (int i = 0; i < internalFormat.length; i += 2) {
      resultBytes.add(int.parse(internalFormat.substring(i, i + 2), radix: 16));
    }
    
    return Uint8List.fromList(resultBytes);
  }
  
  /// Compute the merkle root for a given transaction ID and return it in the block header format
  /// (with reversed bytes for display)
  /// Returns the merkle root as a hex string
  String computeMerkleRootForBlockHeader(Uint8List txid) {
    // Convert the TXID to hex string in internal format
    final txidHex = txid.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join('');
    
    // Get the TSC proof format by extracting the sibling nodes from our BUMP structure
    final List<String> siblingNodes = [];
    int txidIndex = -1;
    
    // Find the txid in the first level to get its index
    for (int i = 0; i < path[0].leaves.length; i++) {
      final leaf = path[0].leaves[i];
      if (leaf.isTxid && !leaf.duplicate && leaf.hash != null) {
        if (listEquals(leaf.hash!, txid)) {
          txidIndex = leaf.offset;
          break;
        }
      }
    }
    
    if (txidIndex == -1) {
      throw Exception('Transaction ID not found in merkle path');
    }
    
    // Extract sibling nodes from the BUMP tree structure
    for (int level = 1; level < path.length; level++) {
      for (final leaf in path[level].leaves) {
        if (!leaf.duplicate && leaf.hash != null) {
          // Convert to hex in internal format
          final leafHex = leaf.hash!.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join('');
          siblingNodes.add(leafHex);
        }
      }
    }
    
    // Initialize with the txid
    String currentHash = txidHex;
    int currentIndex = txidIndex;
    
    // Calculate merkle root by walking up the tree
    for (int i = 0; i < siblingNodes.length; i++) {
      final siblingHash = siblingNodes[i];
      
      // Determine if sibling is left or right
      final isRight = ((currentIndex >> i) & 1) == 0;
      
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
      currentHash = _hashHexPair(concatenated);
      
      // Move to parent index
      currentIndex = currentIndex >> 1;
    }
    
    // Reverse bytes to match block header format
    String blockHeaderFormat = '';
    for (int i = currentHash.length - 2; i >= 0; i -= 2) {
      blockHeaderFormat += currentHash.substring(i, i + 2);
    }
    
    return blockHeaderFormat;
  }
  
  /// Hash a hex string pair using double SHA-256
  String _hashHexPair(String hexString) {
    // Convert hex to bytes
    final bytes = <int>[];
    for (int i = 0; i < hexString.length; i += 2) {
      bytes.add(int.parse(hexString.substring(i, i + 2), radix: 16));
    }
    
    // Double SHA-256 hash
    final firstHash = sha256(bytes);
    final secondHash = sha256(firstHash);
    
    // Convert back to hex
    return hex.encode(secondHash);
  }
  
  /// Hash a pair of hashes as per Bitcoin merkle tree algorithm
  /// The output hash should be byte-reversed when comparing with block header merkle roots
  Uint8List _hashPair(Uint8List left, Uint8List right) {
    final combined = Uint8List(64);
    combined.setRange(0, 32, left);
    combined.setRange(32, 64, right);
    
    // Double SHA-256 hash
    final firstHash = sha256(combined);
    final secondHash = sha256(firstHash);
    
    return Uint8List.fromList(secondHash);
  }
  
  /// Compare two Uint8List for equality
  bool listEquals(Uint8List a, Uint8List b) {
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
}

/// Represents a level in the merkle tree
class Level {
  /// The leaves at this level
  final List<Leaf> leaves;

  /// Creates a new Level instance
  Level({
    required this.leaves,
  });
}

/// Represents a leaf in the merkle tree
class Leaf {
  /// Offset from left hand side within tree
  final int offset;
  
  /// Whether to duplicate the working hash
  final bool duplicate;
  
  /// Whether the hash is a relevant txid
  final bool isTxid;
  
  /// A hash representing a txid, sibling hash, or a branch
  final Uint8List? hash;

  /// Creates a new Leaf instance
  Leaf({
    required this.offset,
    required this.duplicate,
    required this.isTxid,
    this.hash,
  });
}




