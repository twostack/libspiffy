/// The rate a transaction's fee is paid at (bead libspiffy-bg7n).
library;

/// A fee rate: [satoshis] per [bytes], as ARC publishes it in its policy
/// (`GET /v1/policy`, `miningFee`, schema `FeeAmount`).
///
/// Every transaction the wallet builds pays ARC's published rate on its
/// signed size (`TransactionSize`), and nothing else: this is Bitcoin SV,
/// there is no replace-by-fee and no fee auction, so paying above the policy
/// buys nothing, and a rate nobody published is not one to pay at.
class FeeRate {
  final int satoshis;
  final int bytes;

  const FeeRate({required this.satoshis, required this.bytes});

  /// Satoshis per 1000 bytes.
  double get satoshisPerKb => bytes <= 0 ? 0 : satoshis * 1000 / bytes;

  /// The fee for a transaction of [sizeBytes], rounded up: a truncated fee
  /// undercuts the policy.
  BigInt feeFor(int sizeBytes) =>
      bytes <= 0 ? BigInt.zero : BigInt.from((sizeBytes * satoshis + bytes - 1) ~/ bytes);

  @override
  bool operator ==(Object other) => other is FeeRate && other.satoshis == satoshis && other.bytes == bytes;

  @override
  int get hashCode => Object.hash(satoshis, bytes);

  @override
  String toString() => '$satoshis sat/$bytes bytes';
}
