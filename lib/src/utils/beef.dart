import 'dart:typed_data';
import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart';

import 'bump.dart';

/// BeefMagicAndVersion is the magic bytes and version for BEEF format (0100BEEF)
const int beefMagicAndVersion = 0x0100BEEF;

/// Represents a Background Evaluation Extended Format transaction package
/// Used for SPV validation of Bitcoin SV transactions with merkle proofs
class BEEF {
  /// The version of the BEEF format
  final int version;
  
  /// List of BSV Universal Merkle Paths
  final List<BUMP> bumps;
  
  /// List of raw transactions
  final List<Uint8List> txs;
  
  /// Whether each transaction has a merkle proof
  final List<bool> hasMerkle;
  
  /// The BUMP index for each transaction that has a merkle proof
  final List<int> bumpIndex;

  /// Creates a new BEEF instance
  BEEF({
    required this.version,
    required this.bumps,
    required this.txs,
    required this.hasMerkle,
    required this.bumpIndex,
  });

  /// Parse a BEEF format byte array
  static BEEF parse(Uint8List data) {
    if (data.length < 4) {
      throw BEEFException('Invalid BEEF format: data too short');
    }

    final reader = ByteDataReader(data);

    // Read and validate magic and version
    final b0 = reader.readUint8();
    final b1 = reader.readUint8();
    final b2 = reader.readUint8();
    final b3 = reader.readUint8();
    
    // Combine bytes in big-endian order
    final version = (b0 << 24) | (b1 << 16) | (b2 << 8) | b3;
    
    if (version != beefMagicAndVersion) {
      throw BEEFException('Invalid BEEF version: expected ${beefMagicAndVersion.toRadixString(16)}, got ${version.toRadixString(16)}');
    }

    // Read number of BUMPs
    final nBumps = reader.readVarInt();

    // Read BUMPs
    final bumps = <BUMP>[];
    for (var i = 0; i < nBumps; i++) {
      final bump = BUMP.parse(reader);
      bumps.add(bump);
    }

    // Read number of transactions
    final nTxs = reader.readVarInt();

    // Read transactions and their merkle flags
    final txs = <Uint8List>[];
    final hasMerkle = <bool>[];
    final bumpIndex = <int>[];

    for (var i = 0; i < nTxs; i++) {
      // Read transaction size and data
      final txSize = reader.readVarInt();
      final tx = reader.readBytes(txSize);
      txs.add(tx);

      // Read Has BUMP flag
      final hasBump = reader.readUint8() == 1;
      hasMerkle.add(hasBump);

      // If has merkle proof, read BUMP index
      if (hasBump) {
        final idx = reader.readVarInt();
        if (idx >= nBumps) {
          throw BEEFException('Invalid BUMP index $idx for tx $i: exceeds number of BUMPs');
        }
        bumpIndex.add(idx);
      }
    }

    return BEEF(
      version: version,
      bumps: bumps,
      txs: txs,
      hasMerkle: hasMerkle,
      bumpIndex: bumpIndex,
    );
  }

  /// Serialize a BEEF into bytes
  Uint8List serialize() {
    final buffer = ByteDataWriter();

    // Write version - handle endianness manually
    buffer.writeUint8((version >> 24) & 0xFF);
    buffer.writeUint8((version >> 16) & 0xFF);
    buffer.writeUint8((version >> 8) & 0xFF);
    buffer.writeUint8(version & 0xFF);

    // Write number of BUMPs
    buffer.writeVarInt(bumps.length);

    // Write BUMPs
    for (var i = 0; i < bumps.length; i++) {
      final bumpBytes = bumps[i].serialize();
      buffer.writeBytes(bumpBytes);
    }

    // Write number of transactions
    buffer.writeVarInt(txs.length);

    // Write transactions and their merkle flags
    var bumpIndexCount = 0;
    for (var i = 0; i < txs.length; i++) {
      // Write transaction
      buffer.writeVarInt(txs[i].length);
      buffer.writeBytes(txs[i]);

      // Write Has BUMP flag
      buffer.writeUint8(hasMerkle[i] ? 1 : 0);

      // If has merkle proof, write BUMP index
      if (hasMerkle[i]) {
        if (bumpIndexCount >= bumpIndex.length) {
          throw BEEFException('Missing BUMP index for tx $i');
        }
        buffer.writeVarInt(bumpIndex[bumpIndexCount]);
        bumpIndexCount++;
      }
    }

    return buffer.toBytes();
  }

  /// Create a BEEF from raw transactions and BUMPs
  static BEEF create({
    required List<BUMP> bumps,
    required List<Uint8List> txs,
    required List<bool> hasMerkle,
    required List<int> bumpIndex,
  }) {
    return BEEF(
      version: beefMagicAndVersion,
      bumps: bumps,
      txs: txs,
      hasMerkle: hasMerkle,
      bumpIndex: bumpIndex,
    );
  }

  /// Validate the BEEF format
  bool validate() {
    // Check that we have the correct number of bumpIndex entries
    int expectedBumpIndexCount = hasMerkle.where((has) => has).length;
    if (bumpIndex.length != expectedBumpIndexCount) {
      return false;
    }

    // Check that all bumpIndex values are valid
    for (var idx in bumpIndex) {
      if (idx >= bumps.length) {
        return false;
      }
    }

    return true;
  }
  
  /// Calculate the transaction ID (TXID) for a transaction
  /// TXID is the double SHA-256 hash of the transaction
  Uint8List calculateTxid(Uint8List txData) {
    final firstHash = sha256.convert(txData);
    final secondHash = sha256.convert(firstHash.bytes);
    
    // Bitcoin uses little-endian for TXIDs, so we need to reverse the bytes
    final txid = Uint8List.fromList(secondHash.bytes.reversed.toList());
    return txid;
  }
  
  /// Find a transaction by its TXID
  /// Returns the transaction data and its index, or null if not found
  Map<String, dynamic>? findTransactionByTxid(Uint8List txid) {
    for (int i = 0; i < txs.length; i++) {
      final calculatedTxid = calculateTxid(txs[i]);
      if (_listEquals(calculatedTxid, txid)) {
        return {
          'txData': txs[i],
          'index': i,
          'hasMerkleProof': hasMerkle[i],
          'bumpIndex': hasMerkle[i] ? bumpIndex[hasMerkle.sublist(0, i).where((has) => has).length] : null,
        };
      }
    }
    return null;
  }
  
  /// Find a transaction by its TXID (hex string)
  /// Returns the transaction data and its index, or null if not found
  Map<String, dynamic>? findTransactionByTxidHex(String txidHex) {
    try {
      final txidBytes = Uint8List.fromList(hex.decode(txidHex));
      // Bitcoin TXIDs are displayed in reverse byte order
      final reversedTxid = Uint8List.fromList(txidBytes.reversed.toList());
      return findTransactionByTxid(reversedTxid);
    } catch (e) {
      return null;
    }
  }
  
  /// Validate that a transaction with the given TXID is included in this BEEF
  /// and has a valid merkle proof
  bool validateTransaction(Uint8List txid) {
    final txInfo = findTransactionByTxid(txid);
    if (txInfo == null) {
      return false; // Transaction not found
    }
    
    if (!txInfo['hasMerkleProof']) {
      return false; // Transaction doesn't have a merkle proof
    }
    
    final bumpIdx = txInfo['bumpIndex'] as int;
    if (bumpIdx >= bumps.length) {
      return false; // Invalid BUMP index
    }
    
    // Validate the merkle path for this transaction
    return bumps[bumpIdx].validateMerklePath(txid);
  }

  /// Validate a transaction by TXID hex string
  bool validateTransactionHex(String txidHex) {
    try {
      final txidBytes = Uint8List.fromList(hex.decode(txidHex));
      final reversedTxid = Uint8List.fromList(txidBytes.reversed.toList());
      return validateTransaction(reversedTxid);
    } catch (e) {
      return false;
    }
  }
  
  /// Get all transactions that have merkle proofs
  List<Map<String, dynamic>> getVerifiedTransactions() {
    final result = <Map<String, dynamic>>[];
    int bumpIndexCounter = 0;
    
    for (int i = 0; i < txs.length; i++) {
      if (hasMerkle[i]) {
        final txid = calculateTxid(txs[i]);
        result.add({
          'txid': txid,
          'txidHex': hex.encode(txid.reversed.toList()), // Display format
          'txData': txs[i],
          'index': i,
          'bumpIndex': bumpIndex[bumpIndexCounter],
          'blockHeight': bumps[bumpIndex[bumpIndexCounter]].blockHeight,
        });
        bumpIndexCounter++;
      }
    }
    
    return result;
  }

  /// Get all transactions (verified and unverified)
  List<Map<String, dynamic>> getAllTransactions() {
    final result = <Map<String, dynamic>>[];
    int bumpIndexCounter = 0;
    
    for (int i = 0; i < txs.length; i++) {
      final txid = calculateTxid(txs[i]);
      final hasProof = hasMerkle[i];
      
      result.add({
        'txid': txid,
        'txidHex': hex.encode(txid.reversed.toList()), // Display format
        'txData': txs[i],
        'index': i,
        'hasMerkleProof': hasProof,
        'bumpIndex': hasProof ? bumpIndex[bumpIndexCounter] : null,
        'blockHeight': hasProof ? bumps[bumpIndex[bumpIndexCounter]].blockHeight : null,
      });
      
      if (hasProof) {
        bumpIndexCounter++;
      }
    }
    
    return result;
  }

  /// Validate transactions against block headers using SpiffyNode integration
  /// Returns true if all transactions with merkle proofs are valid
  Future<bool> validateWithBlockHeaders(Future<String?> Function(int blockHeight) getMerkleRoot) async {
    final verifiedTxs = getVerifiedTransactions();
    
    for (final tx in verifiedTxs) {
      final txid = tx['txid'] as Uint8List;
      final blockHeight = tx['blockHeight'] as int;
      final bumpIdx = tx['bumpIndex'] as int;
      
      // Get the merkle root from block header
      final blockMerkleRoot = await getMerkleRoot(blockHeight);
      if (blockMerkleRoot == null) {
        return false; // Block header not found
      }
      
      // Compute merkle root from BUMP
      final computedMerkleRoot = bumps[bumpIdx].computeMerkleRoot(txid);
      final computedMerkleRootHex = hex.encode(computedMerkleRoot.reversed.toList());
      
      // Compare merkle roots
      if (computedMerkleRootHex != blockMerkleRoot) {
        return false; // Merkle root mismatch
      }
    }
    
    return true;
  }

  /// Get BEEF statistics for debugging
  Map<String, dynamic> getStatistics() {
    final verifiedTxs = getVerifiedTransactions();
    final allTxs = getAllTransactions();
    
    return {
      'version': version.toRadixString(16),
      'totalTransactions': txs.length,
      'verifiedTransactions': verifiedTxs.length,
      'unverifiedTransactions': allTxs.length - verifiedTxs.length,
      'totalBumps': bumps.length,
      'blockHeights': bumps.map((bump) => bump.blockHeight).toSet().toList()..sort(),
      'beefSizeBytes': serialize().length,
    };
  }

  /// Convert BEEF to hex string for transmission
  String toHex() {
    return hex.encode(serialize());
  }

  /// Create BEEF from hex string
  static BEEF fromHex(String hexString) {
    try {
      final bytes = Uint8List.fromList(hex.decode(hexString));
      return BEEF.parse(bytes);
    } catch (e) {
      throw BEEFException('Failed to parse BEEF from hex: $e');
    }
  }

  /// Helper method to convert bytes to hex string
  String bytesToHex(Uint8List bytes) {
    return bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join('');
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

/// Exception thrown by BEEF operations
class BEEFException implements Exception {
  final String message;
  
  BEEFException(this.message);
  
  @override
  String toString() => 'BEEFException: $message';
} 