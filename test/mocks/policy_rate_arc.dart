import 'package:dactor/dactor.dart';
import 'package:libspiffy/src/actors/wallet_messages.dart';
import 'package:libspiffy/src/models/fee_rate.dart';

/// An ARCActor stand-in that answers [GetFeeRateMessage] with [rate], ARC's
/// published policy rate, for a unit test of an actor that builds or checks
/// a transaction (beads libspiffy-bg7n, libspiffy-zs4l: every fee is that
/// rate on the signed size). A null [rate] is a policy ARC could not read.
class PolicyRateArc extends Actor {
  PolicyRateArc([this.rate = const FeeRate(satoshis: 100, bytes: 1000)]);

  FeeRate? rate;

  @override
  Future<void> onMessage(dynamic message) async {
    if (message is! GetFeeRateMessage) return;
    final rate = this.rate;
    context.sender?.tell(rate == null ? FeeRateQuote.failed("ARC's policy could not be read") : FeeRateQuote(rate));
  }
}
