/// Bitcoin double SHA-256 and merkle-tree primitives.
///
/// The one implementation in the library (audit SPV-16): the BUMP walk,
/// the BEEF txid, the TSC/BRC-71 helpers in `CryptoUtils` and the node-RPC
/// proof builder all hash through these functions.
///
/// Byte order: every hash here is in internal (little-endian) order, the
/// order in which Bitcoin hashes them. Display order (block explorers, RPC,
/// `Hash.toString()`) is the reverse; convert with `hex_utils.dart`.
library;

import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:meta/meta.dart';

import '../utils/hex_utils.dart';

/// Called once per [hash256] call when set. Tests use it to count hashing
/// work on hot paths; production code never sets it.
@visibleForTesting
void Function()? debugOnHash256;

/// Double SHA-256 of [data] (internal byte order).
Uint8List hash256(List<int> data) {
  debugOnHash256?.call();
  return Uint8List.fromList(crypto.sha256.convert(crypto.sha256.convert(data).bytes).bytes);
}

/// The txid of a raw transaction in internal byte order.
Uint8List txidInternalBytes(List<int> rawTx) => hash256(rawTx);

/// The txid of a raw transaction in display byte order (what explorers show
/// and `BEEF.calculateTxid` returns).
Uint8List txidDisplayBytes(List<int> rawTx) => reverseBytes(hash256(rawTx));

/// Parent of two merkle-tree nodes: `hash256(left || right)`, all in internal
/// byte order.
Uint8List merkleParent(List<int> left, List<int> right) {
  final combined = Uint8List(left.length + right.length)
    ..setRange(0, left.length, left)
    ..setRange(left.length, left.length + right.length, right);
  return hash256(combined);
}

/// Walk a merkle path from [leaf] at position [index] to the root.
///
/// [siblings] are bottom-up, internal byte order; `null` marks a level where
/// the working hash is paired with itself (Bitcoin's odd-level padding, `*`
/// in TSC proofs). At each level the working hash goes on the right when
/// its position is odd, on the left when even. An empty path is a
/// single-transaction block: the root is [leaf].
Uint8List merkleRootFromPath(List<int> leaf, int index, List<List<int>?> siblings) {
  var working = Uint8List.fromList(leaf);
  var position = index;
  for (final sibling in siblings) {
    if (sibling == null) {
      working = merkleParent(working, working);
    } else if (position.isOdd) {
      working = merkleParent(sibling, working);
    } else {
      working = merkleParent(working, sibling);
    }
    position >>= 1;
  }
  return working;
}

/// The merkle path of the leaf at [index] in a block whose transactions are
/// [leaves] (internal byte order, block order): bottom-up siblings, `null`
/// where the sibling is the padded copy of the working hash.
///
/// A single-transaction block has an empty path.
List<Uint8List?> merklePathForIndex(List<Uint8List> leaves, int index) {
  if (index < 0 || index >= leaves.length) {
    throw RangeError.index(index, leaves, 'index');
  }
  var level = List<Uint8List>.of(leaves);
  var position = index;
  final siblings = <Uint8List?>[];
  while (level.length > 1) {
    final padded = level.length.isOdd;
    if (padded) level.add(level.last);
    final siblingIndex = position ^ 1;
    siblings.add(padded && siblingIndex == level.length - 1 ? null : level[siblingIndex]);
    level = [
      for (var i = 0; i < level.length; i += 2) merkleParent(level[i], level[i + 1]),
    ];
    position >>= 1;
  }
  return siblings;
}
