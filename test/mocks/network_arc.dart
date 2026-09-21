import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:libspiffy/src/services/arc_service.dart';

import 'offline_arc.dart';

/// One ARC service shared by every party in a test (no network).
///
/// A submitted transaction is SEEN_ON_NETWORK from then on; a transaction
/// nobody submitted is unknown (404), as the real service answers. Parties
/// that did not submit a transaction learn its status only through their
/// ARCActor's status scan, as in the peer-to-peer SPV flow where the
/// recipient broadcasts.
///
/// First seen wins (spv-understanding.md, Critical Implementation Note 3):
/// of two transactions spending the same input, the one submitted first is
/// the one the network keeps; the later one is rejected as a double spend,
/// whatever either pays. There is no replace-by-fee, so no fee this mock is
/// told about can change that.
class NetworkArc extends OfflineArc {
  /// Txids of the transactions submitted so far.
  final Set<String> seen = {};

  /// ARC's `txStatus` for a txid, overriding the behaviour above for both
  /// submissions and status queries (e.g. `REJECTED`).
  final Map<String, String> statusOverrides = {};

  /// ARC's `competingTxs` for a txid, answered with its status override.
  final Map<String, List<String>> competingTxs = {};

  /// Reject a submission spending an outpoint a transaction already
  /// submitted spends. Set false for a test that submits conflicting
  /// transactions deliberately.
  bool firstSeenWins = true;

  /// The transaction each spent outpoint (`txid:vout`) went to.
  final Map<String, String> spentOutpoints = {};

  @override
  Future<ArcSubmitResponse> submitTransaction(String rawTx, {String? callbackUrl}) async {
    final tx = dartsv.Transaction.fromHex(rawTx);
    final txid = tx.id;
    final override = statusOverrides[txid];
    if (override != null) {
      return ArcSubmitResponse.fromJson(
          {'txid': txid, 'txStatus': override, if (competingTxs[txid] != null) 'competingTxs': competingTxs[txid]});
    }
    final outpoints = [for (final i in tx.inputs) '${i.prevTxnId}:${i.prevTxnOutputIndex}'];
    if (firstSeenWins && !seen.contains(txid)) {
      final winners = <String>{
        for (final outpoint in outpoints)
          if (spentOutpoints[outpoint] case final winner? when winner != txid) winner,
      };
      if (winners.isNotEmpty) {
        return ArcSubmitResponse.fromJson({
          'txid': txid,
          'txStatus': 'REJECTED',
          'extraInfo': 'double spend attempted',
          'competingTxs': winners.toList(),
        });
      }
    }
    seen.add(txid);
    for (final outpoint in outpoints) {
      spentOutpoints.putIfAbsent(outpoint, () => txid);
    }
    return ArcSubmitResponse(
      txid: txid,
      status: ArcTransactionStatus.seenOnNetwork,
      timestamp: DateTime.now().toIso8601String(),
    );
  }

  @override
  Future<ArcTransactionResponse> getTransaction(String txid) async {
    final override = statusOverrides[txid];
    if (override != null) {
      return ArcTransactionResponse.fromJson(
          {'txid': txid, 'txStatus': override, if (competingTxs[txid] != null) 'competingTxs': competingTxs[txid]});
    }
    if (!seen.contains(txid)) {
      throw ArcException('Failed to get transaction: {"status":404}', statusCode: 404);
    }
    return ArcTransactionResponse.fromJson({
      'timestamp': DateTime.now().toIso8601String(),
      'txid': txid,
      'txStatus': 'SEEN_ON_NETWORK',
    });
  }
}
