import 'dart:typed_data';
import 'package:buffer/buffer.dart';
import 'package:convert/convert.dart';
import 'package:dartsv/dartsv.dart' as dartsv hide BlockHeader;
import 'package:spiffynode/spiffy_node.dart';
import '../spv/merkle.dart' as merkle;
import 'bump.dart';
import 'hex_utils.dart' as hex_utils;

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

  // Txid index (audit SPV-15): each transaction's display txid is hashed at
  // most once, on first use, and the txid -> position map is built on the
  // first lookup by txid. Rebuilt when transactions are appended; replacing
  // a list element in place after a lookup is not detected.
  List<Uint8List?> _txids = const [];
  Map<String, int>? _indexByTxid;
  Map<Uint8List, int> _indexByIdentity = Map.identity();
  List<int> _bumpOrdinal = const [];
  int _indexedTxCount = -1;
  int _indexedMerkleCount = -1;

  /// Creates a new BEEF instance
  BEEF({
    required this.version,
    required this.bumps,
    required this.txs,
    required this.hasMerkle,
    required this.bumpIndex,
  });

  /// Parse a BEEF (BRC-62, version 1) from [data].
  ///
  /// Every malformed input is reported as a [BEEFException]: too short, a
  /// wrong magic/version, truncated or garbage BUMPs or transactions, a BUMP
  /// index beyond the BUMP list, and bytes left over after the last
  /// transaction. The message keeps the underlying reason (for a truncation,
  /// the reader's `Not enough bytes to read`).
  static BEEF parse(Uint8List data) {
    try {
      return _parse(data);
    } on BEEFException {
      rethrow;
    } catch (e) {
      throw BEEFException('Malformed BEEF: $e');
    }
  }

  static BEEF _parse(Uint8List data) {
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
      // A BEEF transaction has no length prefix: parse it to find its end,
      // then keep the bytes exactly as sent (re-serialising would rewrite a
      // non-minimal encoding and change the txid, audit SPV-15).
      final start = data.length - reader.remainingLength;
      dartsv.Transaction.fromBufferReader(reader);
      txs.add(data.sublist(start, data.length - reader.remainingLength));

      // Read Has BUMP flag
      final hasBump = reader.readUint8() == 1;
      hasMerkle.add(hasBump);

      // If has merkle proof, read BUMP index
      if (hasBump) {
        final idx = dartsv.readVarIntNum(reader);
        if (idx >= nBumps) {
          throw BEEFException('Invalid BUMP index $idx for tx $i: exceeds number of BUMPs');
        }
        bumpIndex.add(idx);
      }
    }

    if (reader.remainingLength != 0) {
      throw BEEFException(
          'Invalid BEEF: ${reader.remainingLength} trailing byte(s) after the last transaction');
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
  ///
  /// For one of this BEEF's own transactions (the same [Uint8List] object as
  /// in [txs]) the txid comes from the index, hashed once per transaction.
  Uint8List calculateTxid(Uint8List txData) {
    _ensureLayout();
    final i = _indexByIdentity[txData];
    if (i != null) return Uint8List.fromList(_txidAt(i));
    return merkle.txidDisplayBytes(txData);
  }

  /// Find a transaction by its TXID
  /// Returns the transaction data and its index, or null if not found
  Map<String, dynamic>? findTransactionByTxid(Uint8List txid) {
    _ensureLayout();
    final byTxid = _indexByTxid ??= {
      for (var i = txs.length - 1; i >= 0; i--) hex.encode(_txidAt(i)): i,
    };
    final i = byTxid[hex.encode(txid)];
    if (i == null) return null;
    return {
      'txData': txs[i],
      'index': i,
      'hasMerkleProof': hasMerkle[i],
      'bumpIndex': hasMerkle[i] ? bumpIndex[_bumpOrdinal[i]] : null,
    };
  }

  /// Positions by identity and BUMP-index ordinals (no hashing); resets the
  /// txid caches when transactions or flags were added or removed.
  void _ensureLayout() {
    if (_indexedTxCount == txs.length && _indexedMerkleCount == hasMerkle.length) return;
    final byIdentity = Map<Uint8List, int>.identity();
    final ordinals = <int>[];
    var proven = 0;
    for (var i = 0; i < txs.length; i++) {
      byIdentity.putIfAbsent(txs[i], () => i);
      ordinals.add(proven);
      if (i < hasMerkle.length && hasMerkle[i]) proven++;
    }
    _indexByIdentity = byIdentity;
    _bumpOrdinal = ordinals;
    _txids = List<Uint8List?>.filled(txs.length, null);
    _indexByTxid = null;
    _indexedTxCount = txs.length;
    _indexedMerkleCount = hasMerkle.length;
  }

  Uint8List _txidAt(int i) => _txids[i] ??= merkle.txidDisplayBytes(txs[i]);
  
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

    // Walk the merkle path for this transaction. [txid] is display format
    // (what calculateTxid returns); BUMP leaves are internal byte order.
    // Without a block header this is a structural check only: the path must
    // contain the txid and every sibling the walk needs.
    return bumps[bumpIdx].validateMerklePath(hex_utils.reverseBytes(txid));
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

    // CRITICAL: This method receives TXID in display format (big-endian)
    // but BUMP stores TXIDs in internal format (little-endian)
    // We need to handle both formats correctly
    
    // First, check if the transaction is included in this BEEF (uses display format)
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

    // Convert TXID from display format (big-endian) to internal format (little-endian) for BUMP validation
    final txidInternal = hex_utils.reverseBytes(txid);

    // Validate the merkle path for this transaction (uses internal format)
    if (!bump.validateMerklePath(txidInternal)) {
      return false; // Invalid merkle path
    }


    // Compute the merkle root from the transaction and its merkle path
    // Returns bytes in internal format (little-endian)
    final computedMerkleRoot = bump.computeMerkleRoot(txidInternal);

    // Compare with the merkle root in the block header (both internal order)
    return hex_utils.bytesEqual(computedMerkleRoot, blockHeader.merkleRoot.bytes);

  }

  /// Compare two Uint8List for equality
  bool listEquals(Uint8List a, Uint8List b) => hex_utils.bytesEqual(a, b);
}
