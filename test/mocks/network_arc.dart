import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:libspiffy/src/services/arc_service.dart';

/// One ARC service shared by every party in a test (no network).
///
/// A submitted transaction is SEEN_ON_NETWORK from then on; a transaction
/// nobody submitted is unknown (404), as the real service answers. Parties
/// that did not submit a transaction learn its status only through their
/// ARCActor's status scan, as in the peer-to-peer SPV flow where the
/// recipient broadcasts.
class NetworkArc extends ArcService {
  NetworkArc() : super(baseUrl: 'fake://arc');

  /// Txids of the transactions submitted so far.
  final Set<String> seen = {};

  /// ARC's `txStatus` for a txid, overriding the behaviour above for both
  /// submissions and status queries (e.g. `REJECTED`).
  final Map<String, String> statusOverrides = {};

  @override
  Future<ArcSubmitResponse> submitTransaction(String rawTx, {String? callbackUrl}) async {
    final txid = dartsv.Transaction.fromHex(rawTx).id;
    final override = statusOverrides[txid];
    if (override != null) {
      return ArcSubmitResponse.fromJson({'txid': txid, 'txStatus': override});
    }
    seen.add(txid);
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
      return ArcTransactionResponse.fromJson({'txid': txid, 'txStatus': override});
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
