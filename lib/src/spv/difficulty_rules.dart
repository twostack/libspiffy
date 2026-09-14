import 'package:spiffynode/spiffy_node.dart';

import 'network_params.dart';

/// Read access to the ancestors of the header being validated, on the
/// branch that header extends (which may be a side branch).
///
/// `headerAt(h)` must return the header at height [h] on that branch, or
/// null when it is not available (below the anchor, or not stored).
abstract class HeaderAncestry {
  Future<BlockHeader?> headerAt(int height);
}

/// Outcome of a difficulty check.
class DifficultyVerdict {
  /// Whether the header's `bits` are acceptable.
  final bool ok;

  /// Which rule produced the verdict (for logs and tests).
  final String rule;

  /// The exact `bits` the rule required, when it computes one.
  final int? expectedBits;

  const DifficultyVerdict(this.ok, this.rule, {this.expectedBits});

  @override
  String toString() =>
      'DifficultyVerdict(ok: $ok, rule: $rule'
      '${expectedBits == null ? '' : ', expected: 0x${expectedBits!.toRadixString(16)}'})';
}

/// Proof-of-work difficulty rules for Bitcoin SV header chains.
///
/// What is enforced, per network (see the audit report, SPV-02):
///
/// * Every network: `bits` must decode to a non-zero target at or below
///   [NetworkParams.powLimit], and the block hash must be at or below that
///   target. This is checked by [BlockHeaderChain], not here.
/// * Mainnet, height < [edaActivationHeight] (478559): the original Bitcoin
///   rule, exactly. Inside a 2016-block period `bits` equals the previous
///   header's `bits`; on a period boundary the target is retargeted from
///   the timespan of the previous 2015 blocks, clamped to 1/4 .. 4x
///   ([legacyRetargetBits]).
/// * Mainnet, [edaActivationHeight] <= height <= [daaActivationHeight]
///   (the Emergency Difficulty Adjustment months of 2017): only the
///   4x-per-step bound ([withinStepBound]). The EDA could lower the target
///   by 25% at any height, so exact equality is not required, and the bound
///   still holds for every EDA and legacy step.
/// * Mainnet, height > [daaActivationHeight] (504031): the BSV/BCH cw-144
///   difficulty adjustment algorithm, exactly ([daaBits]): the target is the
///   work-weighted average of the last 144 blocks scaled by the clamped
///   timespan between the median-of-three "suitable" blocks at each end.
///   When fewer than 147 ancestors are available (a chain anchored at a
///   checkpoint) the 4x bound is applied instead.
/// * Testnet: only the pow-limit and hash-below-target checks. Testnet
///   allows minimum-difficulty blocks after a 20-minute gap, which makes
///   any header-only bound on consecutive `bits` unsound, and its DAA
///   history is not modelled here.
/// * Regtest: only the pow-limit and hash-below-target checks. Regtest
///   never retargets and carries no value; allowing harder-than-required
///   blocks lets tests mine branches of different work cheaply.
class DifficultyRules {
  DifficultyRules._();

  /// First mainnet height at which the 2017 Emergency Difficulty Adjustment
  /// could alter `bits` inside a retarget period.
  static const int edaActivationHeight = 478559;

  /// Mainnet height of the last block whose `bits` were produced by the
  /// pre-DAA rules; the block after it is the first cw-144 block.
  static const int daaActivationHeight = 504031;

  /// Testnet equivalent of [daaActivationHeight] (unused: testnet difficulty
  /// is not enforced beyond the pow limit, see the class comment).
  static const int testnetDaaActivationHeight = 1188697;

  /// Legacy retarget parameters.
  static const int targetTimespanSeconds = 14 * 24 * 60 * 60; // 1209600
  static const int targetSpacingSeconds = 10 * 60;

  /// cw-144 window and clamps.
  static const int daaWindow = 144;
  static const int daaMinTimespan = 72 * targetSpacingSeconds;
  static const int daaMaxTimespan = 288 * targetSpacingSeconds;

  static final BigInt _two256 = BigInt.one << 256;

  /// Work contributed by one block: `2^256 / (target + 1)`, the same
  /// quantity Bitcoin's `GetBlockProof` computes. Zero for an invalid
  /// target.
  static BigInt blockWork(int bits) {
    final target = NetworkParams.bitsToTarget(bits);
    if (target <= BigInt.zero) return BigInt.zero;
    return _two256 ~/ (target + BigInt.one);
  }

  static int _seconds(DateTime t) => t.millisecondsSinceEpoch ~/ 1000;

  /// The original Bitcoin retarget (`CalculateNextWorkRequired`).
  ///
  /// [lastBits] and [lastTime] belong to the last block of the period,
  /// [firstTime] to the block 2015 heights below it.
  static int legacyRetargetBits(
    NetworkParams params, {
    required int lastBits,
    required int firstTime,
    required int lastTime,
  }) {
    var actual = lastTime - firstTime;
    if (actual < targetTimespanSeconds ~/ 4) actual = targetTimespanSeconds ~/ 4;
    if (actual > targetTimespanSeconds * 4) actual = targetTimespanSeconds * 4;

    var target = NetworkParams.bitsToTarget(lastBits);
    target = target * BigInt.from(actual) ~/ BigInt.from(targetTimespanSeconds);
    if (target > params.powLimit) target = params.powLimit;
    return NetworkParams.targetToBits(target);
  }

  /// The cw-144 DAA (`GetNextCashWorkRequired`) for the block after
  /// [window].last.
  ///
  /// [window] holds 147 consecutive headers ending with the previous
  /// block; `window[i]` is at height `prevHeight - 146 + i`. The
  /// "suitable" block at each end is the median-by-time of three
  /// consecutive headers, the work between them is scaled by the target
  /// spacing over the clamped actual timespan, and the target is
  /// `2^256 / work - 1` capped at the pow limit. The min-difficulty
  /// exception for testnet is not applied here (see the class comment).
  static int daaBits(NetworkParams params, List<BlockHeader> window) {
    if (window.length != daaWindow + 3) {
      throw ArgumentError('DAA window must hold ${daaWindow + 3} headers, got ${window.length}');
    }
    final lastIdx = _suitableIndex(window, window.length - 1);
    final firstIdx = _suitableIndex(window, window.length - 1 - daaWindow);

    var work = BigInt.zero;
    for (var i = firstIdx + 1; i <= lastIdx; i++) {
      work += blockWork(window[i].bits);
    }
    work *= BigInt.from(targetSpacingSeconds);

    var actual = _seconds(window[lastIdx].timestamp) - _seconds(window[firstIdx].timestamp);
    if (actual > daaMaxTimespan) actual = daaMaxTimespan;
    if (actual < daaMinTimespan) actual = daaMinTimespan;
    work = work ~/ BigInt.from(actual);
    if (work <= BigInt.zero) return params.powLimitBits;

    // (-work) / work in 256-bit arithmetic == (2^256 - work) / work.
    var target = (_two256 - work) ~/ work;
    if (target > params.powLimit) target = params.powLimit;
    return NetworkParams.targetToBits(target);
  }

  /// `GetSuitableBlock`: index of the median-by-time of `window[i-2..i]`.
  static int _suitableIndex(List<BlockHeader> window, int i) {
    final idx = [i - 2, i - 1, i];
    int t(int k) => _seconds(window[idx[k]].timestamp);
    void swap(int a, int b) {
      final tmp = idx[a];
      idx[a] = idx[b];
      idx[b] = tmp;
    }

    // The same three-element sorting network as the reference code.
    if (t(0) > t(2)) swap(0, 2);
    if (t(0) > t(1)) swap(0, 1);
    if (t(1) > t(2)) swap(1, 2);
    return idx[1];
  }

  /// The bound every legacy, EDA and cw-144 step respects: the new target
  /// lies between the previous target divided by four (as the compact
  /// encoding of that quotient) and four times the previous target, capped
  /// at the pow limit.
  static bool withinStepBound(NetworkParams params, int prevBits, int bits) {
    final prev = NetworkParams.bitsToTarget(prevBits);
    final next = NetworkParams.bitsToTarget(bits);
    if (prev <= BigInt.zero || next <= BigInt.zero) return false;
    var upper = prev << 2;
    if (upper > params.powLimit) upper = params.powLimit;
    final lower = NetworkParams.bitsToTarget(NetworkParams.targetToBits(prev >> 2));
    return next <= upper && next >= lower;
  }

  /// Checks [header]'s `bits` at [height] against the network's rule, using
  /// [ancestry] for the previous blocks on the branch being extended.
  /// [prev] is the header at `height - 1`.
  static Future<DifficultyVerdict> check(
    NetworkParams params,
    int height,
    BlockHeader header,
    BlockHeader prev,
    HeaderAncestry ancestry,
  ) async {
    if (params.name != 'mainnet') {
      // Testnet's min-difficulty blocks and regtest's fixed difficulty:
      // only the pow-limit and hash-vs-target checks apply.
      return const DifficultyVerdict(true, 'pow-limit-only');
    }

    if (height < edaActivationHeight) {
      if (height % NetworkParams.difficultyAdjustmentInterval != 0) {
        return DifficultyVerdict(header.bits == prev.bits, 'legacy-same-period',
            expectedBits: prev.bits);
      }
      final first = await ancestry.headerAt(height - NetworkParams.difficultyAdjustmentInterval);
      if (first == null) {
        return DifficultyVerdict(withinStepBound(params, prev.bits, header.bits),
            'legacy-retarget-bound (period start unavailable)');
      }
      final expected = legacyRetargetBits(params,
          lastBits: prev.bits, firstTime: _seconds(first.timestamp), lastTime: _seconds(prev.timestamp));
      return DifficultyVerdict(header.bits == expected, 'legacy-retarget', expectedBits: expected);
    }

    if (height <= daaActivationHeight) {
      // EDA era: the per-step bound only.
      return DifficultyVerdict(withinStepBound(params, prev.bits, header.bits), 'eda-bound');
    }

    final window = <BlockHeader>[];
    for (var h = height - 1 - (daaWindow + 2); h <= height - 1; h++) {
      final a = h == height - 1 ? prev : await ancestry.headerAt(h);
      if (a == null) {
        return DifficultyVerdict(withinStepBound(params, prev.bits, header.bits),
            'daa-bound (window unavailable)');
      }
      window.add(a);
    }
    final expected = daaBits(params, window);
    return DifficultyVerdict(header.bits == expected, 'daa', expectedBits: expected);
  }
}
