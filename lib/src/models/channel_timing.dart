/// When a payment channel stops taking payments and settles, and how long a
/// channel must run (bead libspiffy-ywbk).
library;

/// The timing a node holds its payment channels to.
///
/// A channel's refund becomes valid at its lock time and returns the whole
/// funding output to the client. The server's payments exist only once its
/// settlement is on the network before then: BSV has no replacement and the
/// first spend seen wins. So:
///
/// * no payment is made or acknowledged within [settlementMargin] of the
///   lock time, and the server settles the channel when that margin begins;
/// * a channel is requested or accepted only with at least
///   [minimumLifetime] to run.
///
/// The margin must cover the broadcast, clock skew between the parties, and
/// that nLockTime is judged by the median time of the last eleven blocks
/// rather than by the clock. Both are the operator's to choose: the library
/// supplies no default.
class ChannelTiming {
  /// How long before the lock time payments stop and the server settles.
  final Duration settlementMargin;

  /// The least time from now to the lock time a channel is opened with.
  final Duration minimumLifetime;

  ChannelTiming({required this.settlementMargin, required this.minimumLifetime}) {
    if (settlementMargin <= Duration.zero) {
      throw ArgumentError.value(settlementMargin, 'settlementMargin', 'must be positive');
    }
    if (minimumLifetime <= settlementMargin) {
      throw ArgumentError.value(minimumLifetime, 'minimumLifetime',
          'must be longer than the settlement margin ($settlementMargin): a shorter channel settles before it opens');
    }
  }

  /// The Unix time from which a channel locked until [lockTimeUnix] takes no
  /// payment and is settled.
  int settleByUnix(int lockTimeUnix) => lockTimeUnix - settlementMargin.inSeconds;

  @override
  String toString() => 'ChannelTiming(settlementMargin: $settlementMargin, minimumLifetime: $minimumLifetime)';
}
