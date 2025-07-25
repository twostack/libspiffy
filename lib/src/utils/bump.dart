import 'dart:typed_data';
import 'package:crypto/crypto.dart';

/// Represents a BSV Universal Merkle Path for SPV validation
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
    final reader = ByteDataReader(bytes);
    
    // Read block height
    final blockHeight = reader.readVarInt();
    
    // Read tree height
    final treeHeight = reader.readUint8();
    
    // Initialize path array
    final path = <Level>[];
    
    // Parse each level
    for (var h = 0; h < treeHeight; h++) {
      final nLeaves = reader.readVarInt();
      final leaves = <Leaf>[];
      
      // Parse each leaf in this level
      for (var j = 0; j < nLeaves; j++) {
        // Read offset
        final offset = reader.readVarInt();
        
        // Read flags
        final flags = reader.readUint8();
        
        // Parse flags
        final duplicate = (flags & 0x01) != 0;
        final isTxid = (flags & 0x02) != 0;
        
        // Read hash if not duplicate
        Uint8List? hash;
        if (!duplicate) {
          hash = reader.readBytes(32);
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

  /// Parse a BUMP from a reader
  static BUMP parse(ByteDataReader reader) {
    // Read block height
    final blockHeight = reader.readVarInt();
    
    // Read tree height
    final treeHeight = reader.readUint8();
    
    // Initialize path array
    final path = <Level>[];
    
    // Parse each level
    for (var h = 0; h < treeHeight; h++) {
      final nLeaves = reader.readVarInt();
      final leaves = <Leaf>[];
      
      // Parse each leaf in this level
      for (var j = 0; j < nLeaves; j++) {
        // Read offset
        final offset = reader.readVarInt();
        
        // Read flags
        final flags = reader.readUint8();
        
        // Parse flags
        final duplicate = (flags & 0x01) != 0;
        final isTxid = (flags & 0x02) != 0;
        
        // Read hash if not duplicate
        Uint8List? hash;
        if (!duplicate) {
          hash = reader.readBytes(32);
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
    buffer.writeVarInt(blockHeight);
    
    // Write tree height
    buffer.writeUint8(path.length);
    
    // Write each level
    for (var h = 0; h < path.length; h++) {
      final level = path[h];
      
      // Write number of leaves
      buffer.writeVarInt(level.leaves.length);
      
      // Write each leaf
      for (var j = 0; j < level.leaves.length; j++) {
        final leaf = level.leaves[j];
        
        // Write offset
        buffer.writeVarInt(leaf.offset);
        
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
            throw BUMPException('Invalid hash length for level $h leaf $j: expected 32, got ${leaf.hash?.length}');
          }
          buffer.writeBytes(leaf.hash!);
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
        if (_listEquals(leaf.hash!, txid)) {
          txidIndex = leaf.offset;
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
        if (leaves[0].duplicate) {
          currentHash = _hashPair(currentHash!, currentHash);
        }
        continue;
      }
      
      // Check for duplicate leaf at current index
      bool hasDuplicate = false;
      for (final leaf in leaves) {
        if (leaf.offset == currentIndex && leaf.duplicate) {
          currentHash = _hashPair(currentHash!, currentHash);
          hasDuplicate = true;
          break;
        }
      }
      
      if (hasDuplicate) {
        currentIndex = currentIndex ~/ 2;
        continue;
      }
      
      // Find the sibling hash
      Uint8List? siblingHash;
      bool isLeftSibling = false;
      
      for (int i = 0; i < leaves.length; i++) {
        final leaf = leaves[i];
        
        if (leaf.offset == currentIndex || leaf.duplicate) {
          continue;
        }
        
        // Check if this is a sibling
        if ((leaf.offset ^ currentIndex) == 1) {
          siblingHash = leaf.hash;
          isLeftSibling = leaf.offset < currentIndex;
          break;
        }
      }
      
      // Handle duplicate siblings at tree edges
      if (siblingHash == null) {
        for (final leaf in leaves) {
          if (leaf.duplicate && ((leaf.offset ^ currentIndex) == 1)) {
            currentHash = _hashPair(currentHash!, currentHash);
            siblingHash = currentHash;
            break;
          }
        }
      }
      
      if (siblingHash == null) {
        return false;
      }
      
      // Compute parent hash
      if (!hasDuplicate) {
        if (isLeftSibling) {
          currentHash = _hashPair(siblingHash, currentHash!);
        } else {
          currentHash = _hashPair(currentHash!, siblingHash);
        }
      }
      
      currentIndex = currentIndex ~/ 2;
    }
    
    return currentHash != null;
  }
  
  /// Compute the merkle root for a given transaction ID
  /// Returns the merkle root as a Uint8List in internal byte order
  Uint8List computeMerkleRoot(Uint8List txid) {
    if (path.isEmpty) {
      throw BUMPException('Cannot compute merkle root: path is empty');
    }
    
    // Find the txid in the first level
    int? txidIndex;
    for (int i = 0; i < path[0].leaves.length; i++) {
      final leaf = path[0].leaves[i];
      if (leaf.isTxid && !leaf.duplicate && leaf.hash != null) {
        if (_listEquals(leaf.hash!, txid)) {
          txidIndex = leaf.offset;
          break;
        }
      }
    }
    
    if (txidIndex == null) {
      throw BUMPException('Transaction ID not found in merkle path');
    }
    
    // Extract sibling hashes from the path
    final List<Uint8List> siblingHashes = [];
    
    // Starting from level 1, extract sibling hashes
    for (int i = 1; i < path.length; i++) {
      final level = path[i];
      for (final leaf in level.leaves) {
        if (leaf.hash != null) {
          siblingHashes.add(leaf.hash!);
        }
      }
    }
    
    // Apply merkle path calculation with proper byte order handling
    Uint8List currentHash = txid;
    int currentIndex = txidIndex;
    
    for (int i = 0; i < siblingHashes.length; i++) {
      final siblingHash = siblingHashes[i];
      
      // Determine concatenation order based on index
      bool isLeftSide = (currentIndex % 2 == 0);
      
      Uint8List concatenated;
      if (isLeftSide) {
        concatenated = _concatenateHashes(currentHash, siblingHash);
      } else {
        concatenated = _concatenateHashes(siblingHash, currentHash);
      }
      
      // Double SHA-256 hash
      final firstHash = sha256.convert(concatenated);
      final secondHash = sha256.convert(firstHash.bytes);
      
      currentHash = Uint8List.fromList(secondHash.bytes);
      currentIndex = currentIndex ~/ 2;
    }
    
    return currentHash;
  }

  /// Hash two 32-byte values together using double SHA-256
  Uint8List _hashPair(Uint8List left, Uint8List right) {
    final concatenated = _concatenateHashes(left, right);
    final firstHash = sha256.convert(concatenated);
    final secondHash = sha256.convert(firstHash.bytes);
    return Uint8List.fromList(secondHash.bytes);
  }

  /// Concatenate two hash values
  Uint8List _concatenateHashes(Uint8List left, Uint8List right) {
    final result = Uint8List(left.length + right.length);
    result.setRange(0, left.length, left);
    result.setRange(left.length, result.length, right);
    return result;
  }

  /// Compare two Uint8List for equality
  bool _listEquals(Uint8List a, Uint8List b) {
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
  final List<Leaf> leaves;

  Level({required this.leaves});
}

/// Represents a leaf in a merkle tree level
class Leaf {
  final int offset;
  final bool duplicate;
  final bool isTxid;
  final Uint8List? hash;

  Leaf({
    required this.offset,
    required this.duplicate,
    required this.isTxid,
    this.hash,
  });
}

/// Helper class for reading binary data
class ByteDataReader {
  final Uint8List _data;
  int _position = 0;

  ByteDataReader(this._data);

  int readUint8() {
    return _data[_position++];
  }

  int readUint32() {
    final value = _data.buffer.asByteData().getUint32(_position, Endian.little);
    _position += 4;
    return value;
  }

  Uint8List readBytes(int length) {
    final bytes = _data.sublist(_position, _position + length);
    _position += length;
    return bytes;
  }

  int readVarInt() {
    final firstByte = readUint8();
    
    if (firstByte < 0xfd) {
      return firstByte;
    } else if (firstByte == 0xfd) {
      final value = _data.buffer.asByteData().getUint16(_position, Endian.little);
      _position += 2;
      return value;
    } else if (firstByte == 0xfe) {
      final value = _data.buffer.asByteData().getUint32(_position, Endian.little);
      _position += 4;
      return value;
    } else {
      final value = _data.buffer.asByteData().getUint64(_position, Endian.little);
      _position += 8;
      return value;
    }
  }
}

/// Helper class for writing binary data
class ByteDataWriter {
  final List<int> _buffer = [];

  void writeUint8(int value) {
    _buffer.add(value & 0xff);
  }

  void writeUint32(int value, {Endian endian = Endian.little}) {
    if (endian == Endian.little) {
      _buffer.add(value & 0xff);
      _buffer.add((value >> 8) & 0xff);
      _buffer.add((value >> 16) & 0xff);
      _buffer.add((value >> 24) & 0xff);
    } else {
      _buffer.add((value >> 24) & 0xff);
      _buffer.add((value >> 16) & 0xff);
      _buffer.add((value >> 8) & 0xff);
      _buffer.add(value & 0xff);
    }
  }

  void writeBytes(Uint8List bytes) {
    _buffer.addAll(bytes);
  }

  void writeVarInt(int value) {
    if (value < 0xfd) {
      writeUint8(value);
    } else if (value <= 0xffff) {
      writeUint8(0xfd);
      _buffer.add(value & 0xff);
      _buffer.add((value >> 8) & 0xff);
    } else if (value <= 0xffffffff) {
      writeUint8(0xfe);
      _buffer.add(value & 0xff);
      _buffer.add((value >> 8) & 0xff);
      _buffer.add((value >> 16) & 0xff);
      _buffer.add((value >> 24) & 0xff);
    } else {
      writeUint8(0xff);
      _buffer.add(value & 0xff);
      _buffer.add((value >> 8) & 0xff);
      _buffer.add((value >> 16) & 0xff);
      _buffer.add((value >> 24) & 0xff);
      _buffer.add((value >> 32) & 0xff);
      _buffer.add((value >> 40) & 0xff);
      _buffer.add((value >> 48) & 0xff);
      _buffer.add((value >> 56) & 0xff);
    }
  }

  Uint8List toBytes() {
    return Uint8List.fromList(_buffer);
  }
}

/// Exception thrown by BUMP operations
class BUMPException implements Exception {
  final String message;
  
  BUMPException(this.message);
  
  @override
  String toString() => 'BUMPException: $message';
} 