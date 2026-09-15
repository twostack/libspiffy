import 'dart:typed_data';

import 'package:spiffynode/spiffy_node.dart';

import '../utils/hex_utils.dart' as hex_utils;
import '../utils/network_name.dart';

/// Consensus constants for one Bitcoin SV network.
///
/// This is the single place that hard-codes what the header chain must be
/// anchored to. Every header-sync path (P2P and CDN) must link its first
/// header to [genesisHash] and check every header's proof of work against
/// [powLimit]; see audit findings SPV-02 and SPV-04.
///
/// The genesis headers are stored as their 80 raw bytes and the hashes are
/// derived from them; `test/spv/network_params_test.dart` verifies that the
/// stored hash equals the double-SHA256 of the stored bytes, so a typo in
/// either is caught rather than trusted.
class NetworkParams {
  /// Canonical network name: `mainnet`, `testnet` or `regtest`.
  final String name;

  /// The 80-byte genesis block header, hex encoded, in wire byte order.
  final String genesisHeaderHex;

  /// Genesis block hash in display (RPC) byte order.
  final String genesisHash;

  /// Compact-encoded proof-of-work limit (`nBits` of the easiest allowed
  /// target).
  final int powLimitBits;

  /// Whether the network permits minimum-difficulty blocks after a 20-minute
  /// gap (testnet and regtest do; mainnet does not).
  final bool allowMinDifficultyBlocks;

  /// Whether the network retargets difficulty at all (regtest does not).
  final bool noRetargeting;

  const NetworkParams._({
    required this.name,
    required this.genesisHeaderHex,
    required this.genesisHash,
    required this.powLimitBits,
    required this.allowMinDifficultyBlocks,
    required this.noRetargeting,
  });

  /// Target block interval shared by every network.
  static const Duration targetSpacing = Duration(minutes: 10);

  /// Difficulty adjustment window used by the legacy (pre-DAA) rules.
  static const int difficultyAdjustmentInterval = 2016;

  /// Bitcoin SV mainnet.
  static const NetworkParams mainnet = NetworkParams._(
    name: 'mainnet',
    genesisHeaderHex:
        '01000000' // version
        '0000000000000000000000000000000000000000000000000000000000000000' // prev
        '3ba3edfd7a7b12b27ac72c3e67768f617fc81bc3888a51323a9fb8aa4b1e5e4a' // merkle
        '29ab5f49' // time 1231006505
        'ffff001d' // bits 0x1d00ffff
        '1dac2b7c', // nonce 2083236893
    genesisHash:
        '000000000019d6689c085ae165831e934ff763ae46a2a6c172b3f1b60a8ce26f',
    powLimitBits: 0x1d00ffff,
    allowMinDifficultyBlocks: false,
    noRetargeting: false,
  );

  /// Bitcoin SV testnet (testnet3).
  static const NetworkParams testnet = NetworkParams._(
    name: 'testnet',
    genesisHeaderHex:
        '01000000'
        '0000000000000000000000000000000000000000000000000000000000000000'
        '3ba3edfd7a7b12b27ac72c3e67768f617fc81bc3888a51323a9fb8aa4b1e5e4a'
        'dae5494d' // time 1296688602
        'ffff001d' // bits 0x1d00ffff
        '1aa4ae18', // nonce 414098458
    genesisHash:
        '000000000933ea01ad0ee984209779baaec3ced90fa3f408719526f8d77f4943',
    powLimitBits: 0x1d00ffff,
    allowMinDifficultyBlocks: true,
    noRetargeting: false,
  );

  /// Regression-test network.
  static const NetworkParams regtest = NetworkParams._(
    name: 'regtest',
    genesisHeaderHex:
        '01000000'
        '0000000000000000000000000000000000000000000000000000000000000000'
        '3ba3edfd7a7b12b27ac72c3e67768f617fc81bc3888a51323a9fb8aa4b1e5e4a'
        'dae5494d' // time 1296688602
        'ffff7f20' // bits 0x207fffff
        '02000000', // nonce 2
    genesisHash:
        '0f9188f13cb7b2c71f2a335e3a4fc328bf5beb436012afca590b1a11466e2206',
    powLimitBits: 0x207fffff,
    allowMinDifficultyBlocks: true,
    noRetargeting: true,
  );

  /// Resolve the parameters for any accepted network spelling
  /// (`main`, `mainnet`, `livenet`, `test`, `testnet`, `regtest`, null).
  /// Unknown or null names resolve to testnet, matching [NetworkName].
  static NetworkParams forNetwork(String? network) {
    if (NetworkName.isRegtest(network)) return regtest;
    return NetworkName.isMainnet(network) ? mainnet : testnet;
  }

  /// The genesis header, parsed from [genesisHeaderHex].
  BlockHeader get genesisHeader =>
      BlockHeader.deserialize(Uint8List.fromList(hex_utils.hexToBytes(genesisHeaderHex)));

  /// The easiest allowed target as a 256-bit integer.
  BigInt get powLimit => bitsToTarget(powLimitBits);

  /// Decode a compact `nBits` value into its 256-bit target.
  ///
  /// Follows `CBigNum::SetCompact`: the top byte is the size in bytes, the
  /// low 23 bits are the mantissa, and bit 23 is the sign (a negative or
  /// overflowing encoding yields zero, which no hash can satisfy).
  static BigInt bitsToTarget(int bits) {
    final size = bits >> 24;
    final negative = (bits & 0x00800000) != 0;
    var mantissa = BigInt.from(bits & 0x007fffff);
    if (negative || mantissa == BigInt.zero) return BigInt.zero;
    final BigInt target;
    if (size <= 3) {
      target = mantissa >> (8 * (3 - size));
    } else {
      target = mantissa << (8 * (size - 3));
    }
    // A target above 2^256 - 1 is an overflow and cannot be met.
    if (target.bitLength > 256) return BigInt.zero;
    return target;
  }

  /// Encode a 256-bit target as compact `nBits` (inverse of [bitsToTarget]).
  static int targetToBits(BigInt target) {
    if (target <= BigInt.zero) return 0;
    var size = (target.bitLength + 7) ~/ 8;
    BigInt compact;
    if (size <= 3) {
      compact = target << (8 * (3 - size));
    } else {
      compact = target >> (8 * (size - 3));
    }
    // The mantissa must not have its sign bit set; shift once more if so.
    if ((compact & BigInt.from(0x00800000)) != BigInt.zero) {
      compact = compact >> 8;
      size += 1;
    }
    return (size << 24) | compact.toInt();
  }

  /// Interpret a display-order block hash as the 256-bit number that must
  /// be at or below the target.
  static BigInt hashToBigInt(String displayHexHash) => BigInt.parse(displayHexHash, radix: 16);

  /// The proof-of-work check every header-sync path applies (audit SPV-16:
  /// the P2P chain and the CDN import used to carry their own copies).
  ///
  /// `bits` must decode to a non-zero target no easier than [powLimit], and
  /// the header hash ([blockHash], display order) must be at or below that
  /// target. The target is checked first; the verdict names the first rule
  /// that fails. Difficulty-adjustment rules are separate
  /// (`DifficultyRules`).
  ProofOfWorkCheck checkProofOfWork(int bits, String blockHash) {
    final target = bitsToTarget(bits);
    if (target <= BigInt.zero) {
      return ProofOfWorkCheck._(target, ProofOfWorkFailure.noTarget);
    }
    if (target > powLimit) {
      return ProofOfWorkCheck._(target, ProofOfWorkFailure.aboveLimit);
    }
    if (hashToBigInt(blockHash) > target) {
      return ProofOfWorkCheck._(target, ProofOfWorkFailure.hashAboveTarget);
    }
    return ProofOfWorkCheck._(target, null);
  }
}

/// Why a header fails [NetworkParams.checkProofOfWork].
enum ProofOfWorkFailure {
  /// `bits` encode no usable target (zero, negative or overflowing).
  noTarget,

  /// The target is easier than the network's `powLimit`.
  aboveLimit,

  /// The block hash is above the header's own target.
  hashAboveTarget,
}

/// Result of [NetworkParams.checkProofOfWork].
class ProofOfWorkCheck {
  /// The decoded target (zero when `bits` encode none).
  final BigInt target;

  /// The first failed rule, or null when the header passes.
  final ProofOfWorkFailure? failure;

  const ProofOfWorkCheck._(this.target, this.failure);

  bool get ok => failure == null;

  /// Whether the failure is about `bits` rather than the hash.
  bool get invalidTarget =>
      failure == ProofOfWorkFailure.noTarget || failure == ProofOfWorkFailure.aboveLimit;
}
