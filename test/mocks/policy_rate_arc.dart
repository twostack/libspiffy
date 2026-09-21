import 'package:dactor/dactor.dart';
import 'package:libspiffy/src/actors/wallet_messages.dart';
import 'package:libspiffy/src/models/fee_rate.dart';

/// An ARCActor stand-in that answers [GetFeeRateMessage] with [rate], ARC's
/// published policy rate, for a unit test of an actor that builds a
/// transaction (bead libspiffy-bg7n: every fee is that rate on the signed
/// size).
class PolicyRateArc extends Actor {
  PolicyRateArc([this.rate = const FeeRate(satoshis: 100, bytes: 1000)]);

  final FeeRate rate;

  @override
  Future<void> onMessage(dynamic message) async {
    if (message is GetFeeRateMessage) context.sender?.tell(FeeRateQuote(rate));
  }
}
