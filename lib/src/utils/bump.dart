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

/// A BSV Universal Merkle Path (BRC-74).
///
/// Layout, as mandated by BRC-74:
///
/// * `path[0]` (level 0) holds every transaction being proved (flag `0x02`)
///   AND, for each of them, its sibling at offset `index ^ 1` — either a
///   32-byte hash, or a leaf flagged `0x01` ("duplicate": the working hash is
///   paired with itself, which is how Bitcoin pads an odd level).
/// * `path[h]` for `h >= 1` holds, for each proved transaction, the sibling
///   of the working hash at offset `(index >> h) ^ 1`.
/// * Transactions of the same block share the upper levels, so one BUMP can
///   prove many txids; `path.length` is the tree height.
/// * All hashes are stored in internal (little-endian) byte order.
///
/// The merkle root is computed by walking up: at every level the working
/// hash is paired with the leaf at the sibling offset (hash on the left when
/// the working position is odd, on the right when even, or with itself for a
/// duplicate), and the position is halved.
///
/// Use [BUMP.fromMerklePath] / [BUMP.fromTscProof] to build one; every
/// builder in the library funnels through them so all emitted BUMPs share
/// this layout.
class BUMP {
  /// The block height in which the transactions are encapsulated
  final int blockHeight;

  /// The path of levels in the merkle tree (level 0 first)
  final List<Level> path;

  /// Creates a new BUMP instance
  BUMP({
    required this.blockHeight,
    required this.path,
  });

  // ---------------------------------------------------------------------------
  // Builders
  // ---------------------------------------------------------------------------

  /// Build a BRC-74 BUMP proving one transaction.
  ///
  /// [txid] is the transaction hash in internal (little-endian) byte order,
  /// [index] its position in the block, and [siblings] the merkle path from
  /// the bottom up in internal byte order, `null` meaning "duplicate" (the
  /// working hash is paired with itself at that level). An empty [siblings]
  /// list is the single-transaction block, whose root is the txid itself.
  factory BUMP.fromMerklePath({
    required int blockHeight,
    required Uint8List txid,
    required int index,
    required List<Uint8List?> siblings,
  }) {
    if (index < 0) {
      throw BUMPException('Transaction index must not be negative: $index');
    }
    if (txid.length != 32) {
      throw BUMPException('Transaction ID must be 32 bytes, got ${txid.length}');
    }
    final txidLeaf = Leaf(offset: index, duplicate: false, isTxid: true, hash: txid);

    if (siblings.isEmpty) {
      if (index != 0) {
        throw BUMPException(
            'A merkle path with no siblings is a single-transaction block; index must be 0, got $index');
      }
      return BUMP(blockHeight: blockHeight, path: [Level(leaves: [txidLeaf])]);
    }

    Leaf siblingLeaf(int height) {
      final hash = siblings[height];
      if (hash != null && hash.length != 32) {
        throw BUMPException(
            'Sibling at height $height must be 32 bytes, got ${hash.length}');
      }
      return Leaf(
        offset: (index >> height) ^ 1,
        duplicate: hash == null,
        isTxid: false,
        hash: hash,
      );
    }

    final level0 = [txidLeaf, siblingLeaf(0)]..sort((a, b) => a.offset.compareTo(b.offset));
    final path = <Level>[Level(leaves: level0)];
    for (var height = 1; height < siblings.length; height++) {
      path.add(Level(leaves: [siblingLeaf(height)]));
    }
    return BUMP(blockHeight: blockHeight, path: path);
  }

  /// Build a BRC-74 BUMP from a TSC-style proof: [txid] and [nodes] in
  /// display (big-endian) hex, bottom-up, with `"*"` marking a duplicate.
  factory BUMP.fromTscProof({
    required int blockHeight,
    required String txid,
    required int index,
    required List<String> nodes,
  }) {
    Uint8List internal(String displayHex, String what) {
      final List<int> bytes;
      try {
        bytes = hex.decode(displayHex);
      } catch (e) {
        throw BUMPException('Invalid hex for $what: $displayHex');
      }
      return Uint8List.fromList(bytes.reversed.toList());
    }

    return BUMP.fromMerklePath(
      blockHeight: blockHeight,
      txid: internal(txid, 'txid'),
      index: index,
      siblings: [
        for (var h = 0; h < nodes.length; h++)
          nodes[h] == '*' ? null : internal(nodes[h], 'sibling at height $h'),
      ],
    );
  }

  /// Merge BUMPs of the same block into one BUMP proving all their txids.
  ///
  /// Leaves are unioned per level by offset; a leaf present in several BUMPs
  /// must agree on its hash. Throws [BUMPException] when the block heights
  /// or tree heights differ.
  static BUMP merge(List<BUMP> bumps) {
    if (bumps.isEmpty) {
      throw BUMPException('Cannot merge an empty list of BUMPs');
    }
    final blockHeight = bumps.first.blockHeight;
    final treeHeight = bumps.first.path.length;
    for (final bump in bumps) {
      if (bump.blockHeight != blockHeight) {
        throw BUMPException('Cannot merge BUMPs of different blocks '
            '($blockHeight vs ${bump.blockHeight})');
      }
      if (bump.path.length != treeHeight) {
        throw BUMPException('Cannot merge BUMPs of different tree heights '
            '($treeHeight vs ${bump.path.length})');
      }
    }

    final merged = <Level>[];
    for (var height = 0; height < treeHeight; height++) {
      final byOffset = <int, Leaf>{};
      for (final bump in bumps) {
        for (final leaf in bump.path[height].leaves) {
          final existing = byOffset[leaf.offset];
          if (existing == null) {
            byOffset[leaf.offset] = leaf;
            continue;
          }
          if (!existing.duplicate &&
              !leaf.duplicate &&
              !_bytesEqual(existing.hash!, leaf.hash!)) {
            throw BUMPException(
                'Conflicting hashes at height $height offset ${leaf.offset}');
          }
          // Prefer the leaf carrying a hash; a txid flag from either wins.
          final withHash = existing.duplicate ? leaf : existing;
          byOffset[leaf.offset] = Leaf(
            offset: leaf.offset,
            duplicate: withHash.duplicate,
            isTxid: existing.isTxid || leaf.isTxid,
            hash: withHash.hash,
          );
        }
      }
      final leaves = byOffset.values.toList()..sort((a, b) => a.offset.compareTo(b.offset));
      merged.add(Level(leaves: leaves));
    }
    return BUMP(blockHeight: blockHeight, path: merged);
  }

  // ---------------------------------------------------------------------------
  // Serialization
  // ---------------------------------------------------------------------------

  /// Parse a BUMP from a list of bytes
  static BUMP fromBytes(Uint8List bytes) {
    try {
      final reader = ByteDataReader();
      reader.add(bytes);
      return parse(reader);
    } catch (e) {
      throw BUMPException('Failed to parse BUMP: $e');
    }
  }

  /// Parse a BUMP from its hex encoding
  static BUMP fromHex(String bumpHex) => fromBytes(Uint8List.fromList(hex.decode(bumpHex)));

  /// Parse a BUMP from a reader
  static BUMP parse(ByteDataReader reader) {
    final blockHeight = readVarIntNum(reader);
    final treeHeight = reader.readUint8();
    final path = <Level>[];

    for (var h = 0; h < treeHeight; h++) {
      final nLeaves = readVarIntNum(reader);
      final leaves = <Leaf>[];

      for (var j = 0; j < nLeaves; j++) {
        final offset = readVarIntNum(reader);
        final flags = reader.readUint8();
        final duplicate = (flags & 0x01) != 0;
        final isTxid = (flags & 0x02) != 0;
        final hash = duplicate ? null : reader.read(32);
        leaves.add(Leaf(
          offset: offset,
          duplicate: duplicate,
          isTxid: isTxid,
          hash: hash,
        ));
      }

      path.add(Level(leaves: leaves));
    }

    return BUMP(blockHeight: blockHeight, path: path);
  }

  /// Serialize the BUMP to bytes
  Uint8List serialize() {
    final buffer = ByteDataWriter();

    buffer.write(VarInt.fromInt(blockHeight).encode());
    buffer.writeUint8(path.length);

    for (var h = 0; h < path.length; h++) {
      final level = path[h];
      buffer.write(VarInt.fromInt(level.leaves.length).encode());

      for (var j = 0; j < level.leaves.length; j++) {
        final leaf = level.leaves[j];
        buffer.write(VarInt.fromInt(leaf.offset).encode());

        int flags = 0;
        if (leaf.duplicate) flags |= 0x01;
        if (leaf.isTxid) flags |= 0x02;
        buffer.writeUint8(flags);

        if (!leaf.duplicate) {
          if (leaf.hash == null || leaf.hash!.length != 32) {
            throw Exception(
                'Invalid hash length for level $h leaf $j: expected 32, got ${leaf.hash?.length}');
          }
          buffer.write(leaf.hash!);
        }
      }
    }

    return buffer.toBytes();
  }

  /// Hex encoding of [serialize]
  String toHex() => hex.encode(serialize());

  // ---------------------------------------------------------------------------
  // Root computation
  // ---------------------------------------------------------------------------

  /// The level-0 leaf carrying [txid], or null if this BUMP does not prove it.
  ///
  /// [txid] is matched in internal byte order first; the display (reversed)
  /// order is accepted too, so callers holding a display-format txid resolve
  /// to the same leaf.
  Leaf? findTxidLeaf(Uint8List txid) {
    if (path.isEmpty || txid.length != 32) return null;
    final reversed = Uint8List.fromList(txid.reversed.toList());
    for (final leaf in path[0].leaves) {
      if (leaf.duplicate || leaf.hash == null) continue;
      if (_bytesEqual(leaf.hash!, txid) || _bytesEqual(leaf.hash!, reversed)) {
        return leaf;
      }
    }
    return null;
  }

  /// Every txid this BUMP proves (level-0 leaves flagged as txids).
  List<Leaf> get txidLeaves =>
      path.isEmpty ? const [] : path[0].leaves.where((l) => l.isTxid && l.hash != null).toList();

  /// Compute the merkle root for [txid] by the BRC-74 walk.
  ///
  /// Returns the root in internal byte order (compare directly with
  /// `BlockHeader.merkleRoot.bytes`; reverse for the display form). Throws
  /// [BUMPException] when the txid is not in the path or the path is missing
  /// a sibling the walk needs.
  Uint8List computeMerkleRoot(Uint8List txid) {
    if (path.isEmpty) {
      throw BUMPException('Cannot compute merkle root: path is empty');
    }
    final txidLeaf = findTxidLeaf(txid);
    if (txidLeaf == null) {
      throw BUMPException('Transaction ID not found in merkle path');
    }

    final index = txidLeaf.offset;
    var working = txidLeaf.hash!;

    // Single-transaction block: the sole leaf is the root.
    if (path.length == 1 && path[0].leaves.length == 1 && index == 0) {
      return working;
    }

    for (var height = 0; height < path.length; height++) {
      final position = index >> height;
      final siblingOffset = position ^ 1;

      Leaf? sibling;
      for (final leaf in path[height].leaves) {
        if (leaf.offset == siblingOffset) {
          sibling = leaf;
          break;
        }
      }
      if (sibling == null) {
        throw BUMPException(
            'Missing sibling at height $height (offset $siblingOffset) for txid position $index');
      }

      if (sibling.duplicate) {
        working = _hashPair(working, working);
      } else {
        final siblingHash = sibling.hash;
        if (siblingHash == null || siblingHash.length != 32) {
          throw BUMPException('Sibling at height $height offset $siblingOffset has no 32-byte hash');
        }
        working = position.isOdd ? _hashPair(siblingHash, working) : _hashPair(working, siblingHash);
      }
    }

    return working;
  }

  /// Compute the merkle root for [txid] and return it as display-format hex
  /// (the byte-reversed form shown by block explorers).
  String computeMerkleRootForBlockHeader(Uint8List txid) =>
      hex.encode(computeMerkleRoot(txid).reversed.toList());

  /// Validate the merkle path for [txid].
  ///
  /// The path is walked to the root; a txid that is not in the BUMP, or a
  /// level that lacks the sibling the walk needs, makes this false. With
  /// [expectedMerkleRoot] (internal byte order) the computed root must also
  /// match; without it only the structure is checked, which cannot detect a
  /// tampered sibling hash — compare against a block header for that.
  bool validateMerklePath(Uint8List txid, {Uint8List? expectedMerkleRoot}) {
    final Uint8List root;
    try {
      root = computeMerkleRoot(txid);
    } on BUMPException {
      return false;
    }
    if (expectedMerkleRoot != null) {
      return _bytesEqual(root, expectedMerkleRoot);
    }
    return true;
  }

  /// Hash a pair of hashes as per Bitcoin merkle tree algorithm
  Uint8List _hashPair(Uint8List left, Uint8List right) {
    final combined = Uint8List(64);
    combined.setRange(0, 32, left);
    combined.setRange(32, 64, right);
    return Uint8List.fromList(sha256(sha256(combined)));
  }

  static bool _bytesEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Compare two Uint8List for equality
  bool listEquals(Uint8List a, Uint8List b) => _bytesEqual(a, b);
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
