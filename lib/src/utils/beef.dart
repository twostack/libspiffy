import 'dart:typed_data';
import 'package:buffer/buffer.dart';
import 'package:convert/convert.dart';
import 'package:dartsv/dartsv.dart' as dartsv hide BlockHeader;
import 'package:logging/logging.dart';
import 'package:spiffynode/spiffy_node.dart';
import '../spv/merkle.dart' as merkle;
import 'bump.dart';
import 'hex_utils.dart' as hex_utils;

/// BeefMagicAndVersion is the magic bytes and version for BEEF format (0100BEEF)
const int beefMagicAndVersion = 0x0100BEEF;

final _beefLog = Logger('BEEF');

class BEEFException implements Exception {
  final String message;

  BEEFException(this.message);

  @override
  String toString() => 'BEEFException: $message';
}

/// The BUMPs of a BEEF: one per block, not one per proven transaction.
///
/// A BUMP is a merkle path inside a single block and BRC-74 lets one BUMP
/// carry the paths of several transactions of that block — level 0 holds a
/// txid leaf (flag `0x02`) for each of them and the levels above are shared
/// instead of repeated. [of] groups the per-transaction BUMPs by block,
/// merges each group and keeps the BEEF's BUMP index for every transaction
/// ([indexFor]), so an outgoing BEEF never repeats a block's merkle path
/// (audit finding libspiffy-0lx).
///
/// Merging is only done where it is provably safe: every source BUMP must
/// prove its own transaction, all of a group must compute the same merkle
/// root (two blocks at the same height do not), and the merged BUMP must
/// still walk every one of those transactions to that root with its leaf
/// still flagged as a txid. A group that fails any of these keeps one BUMP
/// per transaction, exactly as before — a bigger BEEF is always better than
/// one the recipient cannot verify.
class BeefBumps {
  /// The BUMPs to put in the BEEF, in BEEF order.
  final List<BUMP> bumps;

  final Map<String, int> _indexByTxid;

  const BeefBumps._(this.bumps, this._indexByTxid);

  /// The BUMP index for [txid] (hex, either byte order as the caller keyed
  /// it), or null when no BUMP proves it.
  int? indexFor(String txid) => _indexByTxid[txid.toLowerCase()];

  /// Whether [txid] is proven by one of [bumps].
  bool proves(String txid) => _indexByTxid.containsKey(txid.toLowerCase());

  /// Group [bumpByTxid] (txid hex to the BUMP proving it, in the order the
  /// BEEF should carry them) into one BUMP per block where that is safe.
  static BeefBumps of(Map<String, BUMP> bumpByTxid) {
    // Group by the block itself — height AND merkle root — so that two
    // blocks at one height (a fork) never land in the same BUMP, and a BUMP
    // that does not prove its own transaction is left alone.
    final byBlock = <String, List<String>>{};
    var ungrouped = 0;
    for (final entry in bumpByTxid.entries) {
      final key = _blockKey(entry.key, entry.value) ?? 'unkeyed:${ungrouped++}';
      byBlock.putIfAbsent(key, () => <String>[]).add(entry.key);
    }

    final bumps = <BUMP>[];
    final indexByTxid = <String, int>{};
    for (final group in byBlock.values) {
      if (group.length > 1) {
        final merged = _mergeGroup(group, bumpByTxid);
        if (merged != null) {
          final index = bumps.length;
          bumps.add(merged);
          for (final txid in group) {
            indexByTxid[txid.toLowerCase()] = index;
          }
          continue;
        }
      }
      for (final txid in group) {
        indexByTxid[txid.toLowerCase()] = bumps.length;
        bumps.add(bumpByTxid[txid]!);
      }
    }
    return BeefBumps._(bumps, indexByTxid);
  }

  /// The block [bump] proves [txid] into — its height and merkle root — or
  /// null when it does not prove [txid] at all (such a BUMP is never
  /// merged; it is passed through untouched).
  ///
  /// Leaves are stored in internal byte order; findTxidLeaf (used by
  /// computeMerkleRoot) accepts either order, so a caller keying by display
  /// hex and one keying by internal hex both resolve.
  static String? _blockKey(String txid, BUMP bump) {
    try {
      final root = bump.computeMerkleRoot(hex_utils.displayToInternal(txid));
      return '${bump.blockHeight}:${hex.encode(root)}';
    } catch (e) {
      _beefLog.warning('BUMP at height ${bump.blockHeight} does not prove $txid ($e); '
          'it is kept as its own BUMP');
      return null;
    }
  }

  /// The single BUMP proving every txid of [group], or null when merging
  /// them is not provably safe (the caller then keeps them separate).
  static BUMP? _mergeGroup(List<String> group, Map<String, BUMP> bumpByTxid) {
    try {
      final sources = [for (final txid in group) bumpByTxid[txid]!];
      final txids = [for (final txid in group) hex_utils.displayToInternal(txid)];
      // Every source proves its transaction into the same block: the group
      // key is (block height, merkle root).
      final root = sources.first.computeMerkleRoot(txids.first);

      final merged = BUMP.merge(sources);
      for (var i = 0; i < sources.length; i++) {
        final leaf = merged.findTxidLeaf(txids[i]);
        if (leaf == null || !leaf.isTxid) {
          _beefLog.warning('Not merging the BUMPs at height ${sources[i].blockHeight}: '
              'the merged path does not mark ${group[i]} as a txid');
          return null;
        }
        if (!hex_utils.bytesEqual(merged.computeMerkleRoot(txids[i]), root)) {
          _beefLog.warning('Not merging the BUMPs at height ${sources[i].blockHeight}: '
              'the merged path does not walk ${group[i]} to the block merkle root');
          return null;
        }
      }
      return merged;
    } catch (e) {
      _beefLog.warning('Not merging the BUMPs of ${group.length} transactions: $e');
      return null;
    }
  }
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

  /// Whether this BEEF carries a merkle proof (a BUMP) for the transaction
  /// [txid] itself (hex, display order) — not merely for its ancestors.
  /// False when it does not hold [txid] at all. Carrying a proof is not
  /// verifying one: that takes our header chain (SPVActor).
  bool carriesProofOf(String txid) {
    final Uint8List bytes;
    try {
      bytes = Uint8List.fromList(hex.decode(txid));
    } on FormatException {
      return false;
    }
    return findTransactionByTxid(bytes)?['hasMerkleProof'] == true;
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
