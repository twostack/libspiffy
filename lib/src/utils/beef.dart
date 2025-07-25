import 'dart:typed_data';
import 'package:buffer/buffer.dart';
import 'package:convert/convert.dart';
import 'package:dartsv/dartsv.dart' as dartsv hide BlockHeader;
import 'package:spiffynode/spiffy_node.dart';
import '../services/block_header_service.dart';
import 'bump.dart';

/// BeefMagicAndVersion is the magic bytes and version for BEEF format (0100BEEF)
const int beefMagicAndVersion = 0x0100BEEF;



class BEEFException implements Exception {
  final String message;
  
  BEEFException(this.message);
  
  @override
  String toString() => 'BEEFException: $message';
}

/// Represents a Background Evaluation Extended Format transaction
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

    final reader = ByteDataReader();
    reader.add(data);

    // Read and validate magic and version
    // We need to handle endianness manually since ByteDataReader doesn't support it
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
    final nBumps = dartsv.readVarIntNum(reader);

    // Read BUMPs
    final bumps = <BUMP>[];
    for (var i = 0; i < nBumps; i++) {
      final bump = BUMP.parse(reader);
      bumps.add(bump);
    }

    // Read number of transactions
    final nTxs = dartsv.readVarIntNum(reader);

    // Read transactions and their merkle flags
    final txs = <Uint8List>[];
    final hasMerkle = <bool>[];
    final bumpIndex = <int>[];

    for (var i = 0; i < nTxs; i++) {
      // Read transaction
      // For simplicity, we'll read the transaction as a raw byte array
      // In a real implementation, you would parse this into a Transaction object
      final tx = dartsv.Transaction.fromBufferReader(reader);
      // final txSize = readVarIntNum(reader);
      // final tx = reader.readBytes(txSize);
      txs.add(Uint8List.fromList(hex.decode(tx.serialize())));

      // Read Has BUMP flag
      final hasBump = reader.readUint8() == 1;
      hasMerkle.add(hasBump);

      // If has merkle proof, read BUMP index
      if (hasBump) {
        final idx = dartsv.readVarIntNum(reader);
        if (idx >= nBumps) {
          throw Exception('Invalid BUMP index $idx for tx $i: exceeds number of BUMPs');
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
    final nBumps = dartsv.VarInt.fromInt(bumps.length).encode();
    buffer.write(nBumps);

    // Write BUMPs
    for (var i = 0; i < bumps.length; i++) {
      final bumpBytes = bumps[i].serialize();
      buffer.write(bumpBytes);
    }

    // Write number of transactions
    final nTxs = dartsv.VarInt.fromInt(txs.length);
    buffer.write(nTxs.encode());

    // Write transactions and their merkle flags
    var bumpIndexCount = 0;
    for (var i = 0; i < txs.length; i++) {
      // Write transaction
      // final txLength = dartsv.VarInt.fromInt(txs[i].length);
      // buffer.write(txLength.encode());
      buffer.write(txs[i]);

      // Write Has BUMP flag
      buffer.writeUint8(hasMerkle[i] ? 1 : 0);

      // If has merkle proof, write BUMP index
      if (hasMerkle[i]) {
        if (bumpIndexCount >= bumpIndex.length) {
          throw Exception('Missing BUMP index for tx $i');
        }
        final bumpNdx = dartsv.VarInt.fromInt(bumpIndex[bumpIndexCount]);
        buffer.write(bumpNdx.encode());
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
    final firstHash = dartsv.sha256(txData);
    final secondHash = dartsv.sha256(firstHash);
    
    // Bitcoin uses little-endian for TXIDs, so we need to reverse the bytes
    final txid = Uint8List.fromList(secondHash.reversed.toList());
    return txid;
  }
  
  /// Find a transaction by its TXID
  /// Returns the transaction data and its index, or null if not found
  Map<String, dynamic>? findTransactionByTxid(Uint8List txid) {
    for (int i = 0; i < txs.length; i++) {
      final calculatedTxid = calculateTxid(txs[i]);
      if (listEquals(calculatedTxid, txid)) {
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
  
  /// Get all transactions that have merkle proofs
  List<Map<String, dynamic>> getVerifiedTransactions() {
    final result = <Map<String, dynamic>>[];
    int bumpIndexCounter = 0;
    
    for (int i = 0; i < txs.length; i++) {
      if (hasMerkle[i]) {
        final txid = calculateTxid(txs[i]);
        result.add({
          'txid': txid,
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


  Future<bool> validateTransactionWithBlockHeader( Uint8List txid, BlockHeader blockHeader ) async {

    // First, check if the transaction is included in this BEEF
    final txInfo = findTransactionByTxid(txid);
    if (txInfo == null || !txInfo['hasMerkleProof']) {
      return false; // Transaction not found or doesn't have a merkle proof
    }

    // Get the BUMP index and the corresponding BUMP
    final bumpIdx = txInfo['bumpIndex'] as int;
    if (bumpIdx >= bumps.length) {
      return false; // Invalid BUMP index
    }

    final bump = bumps[bumpIdx];

    // Validate the merkle path for this transaction
    if (!bump.validateMerklePath(txid)) {
      return false; // Invalid merkle path
    }


    // Compute the merkle root from the transaction and its merkle path
    final computedMerkleRoot = bump.computeMerkleRoot(txid);

    // Convert the computed merkle root to a hex string for comparison
    final computedMerkleRootHex = hex.encode(computedMerkleRoot);

    // Compare with the merkle root in the block header
    return computedMerkleRootHex == hex.encode(blockHeader.merkleRoot.bytes.reversed.toList());

  }

  /// Validate a transaction against the block header database
  /// Returns a Future that resolves to true if the transaction is valid, false otherwise
  Future<bool> validateTransactionWithBlockHeaderService(
    Uint8List txid, 
    BlockHeaderService blockHeaderService
  ) async {
    // First, check if the transaction is included in this BEEF
    final txInfo = findTransactionByTxid(txid);
    if (txInfo == null || !txInfo['hasMerkleProof']) {
      return false; // Transaction not found or doesn't have a merkle proof
    }

    // Get the BUMP index and the corresponding BUMP
    final bumpIdx = txInfo['bumpIndex'] as int;
    if (bumpIdx >= bumps.length) {
      return false; // Invalid BUMP index
    }

    final bump = bumps[bumpIdx];

    // Validate the merkle path for this transaction
    if (!bump.validateMerklePath(txid)) {
      return false; // Invalid merkle path
    }

    // Get the block header for the block height
    final blockHeight = bump.blockHeight;

    try {
      // Get the header at this specific height
      final blockHeader = await blockHeaderService.getHeader(blockHeight);
      
      if (blockHeader == null) {
        return false; // No header found at this height
      }
      
      // Compute the merkle root from the transaction and its merkle path
      final computedMerkleRoot = bump.computeMerkleRoot(txid);
      
      // Convert the computed merkle root to a hex string for comparison
      final computedMerkleRootHex = bytesToHex(computedMerkleRoot);
      
      // Compare with the merkle root in the block header
      if (computedMerkleRootHex != hex.encode(blockHeader.merkleRoot.bytes)) {
          return false; // No matching merkle root found in any header at this height
      }
      
      // All checks passed, the transaction is valid
      return true;
    } catch (e) {
      print('Error validating transaction with block header: $e');
      return false;
    }
  }
  
  /// Helper method to convert bytes to hex string
  /// This is made public for testing purposes
  String bytesToHex(Uint8List bytes) {
    return bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join('');
  }
  
  /// Get all transactions that have been validated against the block header database
  /// Returns a Future that resolves to a list of validated transactions
  Future<List<Map<String, dynamic>>> getBlockHeaderValidatedTransactions(
    BlockHeaderService blockHeaderService
  ) async {
    final result = <Map<String, dynamic>>[];
    final verifiedTxs = getVerifiedTransactions();
    
    for (final tx in verifiedTxs) {
      final txid = tx['txid'] as Uint8List;
      final isValid = await validateTransactionWithBlockHeaderService(txid, blockHeaderService);
      
      if (isValid) {
        result.add({
          ...tx,
          'validatedWithBlockHeader': true,
        });
      }
    }
    
    return result;
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
