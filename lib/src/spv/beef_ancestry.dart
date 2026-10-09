/// What a BEEF proves about the transactions it carries: the BUMP of a
/// proven one, and the ancestry of its subject that a wallet must keep to
/// spend the subject's outputs before it is mined. Read the same way for a
/// BEEF received (SPVActor) and one this wallet settled (SettleBEEFCommand).
library;

import 'package:convert/convert.dart';
import 'package:dartsv/dartsv.dart' as dartsv;

import '../core/wallet_events.dart' show BeefAncestor;
import '../utils/beef.dart';
import '../utils/bump.dart';

extension BeefAncestry on BEEF {
  /// The BUMP proving the proven transaction at [txIndex].
  ///
  /// BRC-62 gives every proven transaction an explicit index into the BUMP
  /// list (`bumpIndex`, one entry per proven transaction in order). BUMPs
  /// need not be listed in transaction order, and several transactions of
  /// one block share a BUMP, so counting the proven transactions before
  /// [txIndex] picked the wrong block's proof for BEEFs not built by this
  /// library.
  BUMP bumpOf(int txIndex) {
    var ordinal = 0;
    for (var i = 0; i < txIndex; i++) {
      if (hasMerkle[i]) ordinal++;
    }
    if (!hasMerkle[txIndex] || ordinal >= bumpIndex.length) {
      throw StateError('Transaction $txIndex has no BUMP index in the BEEF');
    }
    final index = bumpIndex[ordinal];
    if (index < 0 || index >= bumps.length) {
      throw StateError('BUMP index $index of transaction $txIndex is out of range (${bumps.length} BUMPs)');
    }
    return bumps[index];
  }

  /// The txids of the transactions this BEEF carries a BUMP for.
  Set<String> get provenTxids => {
        for (var i = 0; i < txs.length; i++)
          if (i < hasMerkle.length && hasMerkle[i]) hex.encode(calculateTxid(txs[i])),
      };

  /// The transactions of this BEEF that an outgoing BEEF spending outputs
  /// of the unproven [subjectTxid] must carry (bead libspiffy-zsh): every
  /// in-BEEF ancestor reached by walking inputs back from the subject,
  /// stopping at proven transactions ([provenTxids]), each proven one with
  /// its BUMP. In the BEEF's order; transactions of the BEEF that the
  /// subject does not descend from are left out.
  ///
  /// We cannot fetch these again (no block scanning, no indexer, and ARC
  /// knows only transactions it mined or we broadcast), so they are
  /// journaled with the transaction.
  ///
  /// Every BUMP the BEEF carries is kept, [provenTxids] or not (bead
  /// libspiffy-fggl): a proof for a block whose header we have not synced
  /// cannot be fetched again either, and the projection stores it
  /// pendingHeader until the header arrives. Only [provenTxids] stops the
  /// walk, so an ancestor that could not be verified is still followed back.
  List<BeefAncestor> ancestorsOf(String subjectTxid, Set<String> provenTxids) {
    final indexByTxid = <String, int>{};
    for (var i = 0; i < txs.length; i++) {
      indexByTxid.putIfAbsent(hex.encode(calculateTxid(txs[i])), () => i);
    }

    final needed = <String>{};
    final pending = <String>[subjectTxid];
    while (pending.isNotEmpty) {
      final index = indexByTxid[pending.removeLast()];
      if (index == null) continue;
      final tx = dartsv.Transaction.fromHex(hex.encode(txs[index]));
      for (final input in tx.inputs) {
        final parent = input.prevTxnId;
        if (parent == subjectTxid || !indexByTxid.containsKey(parent) || !needed.add(parent)) continue;
        if (!provenTxids.contains(parent)) pending.add(parent);
      }
    }

    return [
      for (final entry in indexByTxid.entries.toList()..sort((a, b) => a.value.compareTo(b.value)))
        if (needed.contains(entry.key))
          BeefAncestor(
            txid: entry.key,
            rawHex: hex.encode(txs[entry.value]),
            bumpHex: hasMerkle[entry.value] ? bumpOf(entry.value).toHex() : '',
          ),
    ];
  }
}
