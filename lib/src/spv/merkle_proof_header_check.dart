import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:spiffynode/spiffy_node.dart';

import '../utils/bump.dart';

/// Outcome of checking a merkle proof against the local header chain.
enum ProofHeaderStatus {
  /// The BUMP walks from the txid to the merkle root of the active header at
  /// the BUMP's height.
  verified,

  /// A header is known at that height and its merkle root is different: the
  /// proof is forged, for another block, or for a block our chain does not
  /// contain. Never treat the transaction as confirmed.
  rootMismatch,

  /// No header is known at that height yet (headers still syncing). The
  /// proof may be genuine; check again when headers arrive.
  headerUnknown,

  /// The proof cannot be evaluated: the txid is not in the BUMP, a sibling is
  /// missing, the hex does not parse, or the claimed height disagrees with
  /// the BUMP's own height.
  malformed,
}

/// Looks up the active-chain header at a height (for example
/// `ReadModelStorage.getBlockHeaderByHeight` or
/// `BlockHeaderChain.getHeaderByHeight`).
typedef HeaderAtHeight = Future<BlockHeader?> Function(int height);

/// Result of [checkBumpAgainstHeaders].
class ProofHeaderCheck {
  final ProofHeaderStatus status;

  /// The header the proof was compared with (verified / rootMismatch).
  final BlockHeader? header;

  /// The BUMP's height.
  final int? blockHeight;

  /// The txid's position in the block (its level-0 offset), when found.
  final int? txIndex;

  /// Human-readable reason for anything but [ProofHeaderStatus.verified].
  final String? detail;

  const ProofHeaderCheck._(this.status, {this.header, this.blockHeight, this.txIndex, this.detail});

  bool get isVerified => status == ProofHeaderStatus.verified;

  /// Display hash of [header], when there is one.
  String? get blockHash => header?.blockHash().toString();

  @override
  String toString() =>
      'ProofHeaderCheck(${status.name}, height: $blockHeight, index: $txIndex${detail == null ? '' : ', $detail'})';
}

/// Check that [bump] proves [txid] (display hex) inside the block whose
/// header [headerAt] returns for the BUMP's height.
///
/// [claimedHeight], when given (the height a data source or ARC reported),
/// must equal the BUMP's own height. Errors thrown by [headerAt] are
/// reported as [ProofHeaderStatus.headerUnknown].
Future<ProofHeaderCheck> checkBumpAgainstHeaders({
  required String txid,
  required BUMP bump,
  required HeaderAtHeight headerAt,
  int? claimedHeight,
}) async {
  final Uint8List txidInternal;
  try {
    txidInternal = Uint8List.fromList(hex.decode(txid).reversed.toList());
  } catch (_) {
    return ProofHeaderCheck._(ProofHeaderStatus.malformed, detail: 'txid is not hex: $txid');
  }
  if (txidInternal.length != 32) {
    return ProofHeaderCheck._(ProofHeaderStatus.malformed, detail: 'txid is not 32 bytes');
  }
  if (claimedHeight != null && claimedHeight != bump.blockHeight) {
    return ProofHeaderCheck._(ProofHeaderStatus.malformed,
        blockHeight: bump.blockHeight,
        detail: 'claimed height $claimedHeight differs from BUMP height ${bump.blockHeight}');
  }

  // Only the internal byte order counts: BUMP.findTxidLeaf also accepts the
  // reversed form, which must not let a leaf holding the display bytes pass.
  final leaf = bump.path.isEmpty
      ? null
      : bump.path[0].leaves.where((l) => !l.duplicate && l.hash != null && _equal(l.hash!, txidInternal)).firstOrNull;
  if (leaf == null) {
    return ProofHeaderCheck._(ProofHeaderStatus.malformed,
        blockHeight: bump.blockHeight, detail: 'txid $txid is not proved by the BUMP');
  }

  final Uint8List root;
  try {
    root = bump.computeMerkleRoot(txidInternal);
  } on BUMPException catch (e) {
    return ProofHeaderCheck._(ProofHeaderStatus.malformed,
        blockHeight: bump.blockHeight, txIndex: leaf.offset, detail: e.message);
  }

  BlockHeader? header;
  try {
    header = await headerAt(bump.blockHeight);
  } catch (e) {
    return ProofHeaderCheck._(ProofHeaderStatus.headerUnknown,
        blockHeight: bump.blockHeight, txIndex: leaf.offset, detail: 'header lookup failed: $e');
  }
  if (header == null) {
    return ProofHeaderCheck._(ProofHeaderStatus.headerUnknown,
        blockHeight: bump.blockHeight, txIndex: leaf.offset, detail: 'no header at height ${bump.blockHeight}');
  }

  if (!_equal(root, header.merkleRoot.bytes)) {
    return ProofHeaderCheck._(ProofHeaderStatus.rootMismatch,
        header: header,
        blockHeight: bump.blockHeight,
        txIndex: leaf.offset,
        detail: 'computed root ${hex.encode(root.reversed.toList())} != header root ${header.merkleRoot}');
  }
  return ProofHeaderCheck._(ProofHeaderStatus.verified,
      header: header, blockHeight: bump.blockHeight, txIndex: leaf.offset);
}

/// [checkBumpAgainstHeaders] for a raw BUMP hex string (ARC's `merklePath`,
/// the stored `MerkleProof.merkleProof[0]`).
Future<ProofHeaderCheck> checkBumpHexAgainstHeaders({
  required String txid,
  required String bumpHex,
  required HeaderAtHeight headerAt,
  int? claimedHeight,
}) async {
  final BUMP bump;
  try {
    bump = BUMP.fromHex(bumpHex);
  } catch (e) {
    return ProofHeaderCheck._(ProofHeaderStatus.malformed, detail: 'BUMP does not parse: $e');
  }
  return checkBumpAgainstHeaders(
      txid: txid, bump: bump, headerAt: headerAt, claimedHeight: claimedHeight);
}

bool _equal(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
