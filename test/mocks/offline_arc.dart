import 'package:libspiffy/src/models/fee_rate.dart';
import 'package:libspiffy/src/services/arc_service.dart';

/// An [ArcService] with no network behind it, which a test's fake of ARC
/// extends.
///
/// It publishes a policy (`GET /v1/policy`), because every transaction the
/// wallet builds pays ARC's published rate on its signed size (bead
/// libspiffy-bg7n) and a fake that did not answer would send the request to
/// a URL nothing serves. Everything else a fake needs it overrides itself.
class OfflineArc extends ArcService {
  OfflineArc({super.baseUrl = 'fake://arc'});

  /// The published mining fee, as ARC's `GET /v1/policy` returns it.
  FeeRate miningFee = const FeeRate(satoshis: 100, bytes: 1000);

  /// `GET /v1/policy` fails, as it does when ARC cannot be reached.
  bool policyUnavailable = false;

  @override
  Future<ArcPolicyResponse> getPolicy() async {
    if (policyUnavailable) throw ArcException('ARC unavailable');
    return ArcPolicyResponse(
      timestamp: DateTime.now().toIso8601String(),
      maxScriptSize: 500000,
      maxTxSigopsCount: 4294967295,
      maxTxSize: 10000000,
      miningFee: miningFee,
      standardFormatSupported: true,
    );
  }
}
