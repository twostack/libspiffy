/// A single transaction in a funding provision batch.
///
/// Provisioning produces a tree: a split TX (level 1) fans out into
/// earmark TXs (level 2). Each earmark places the target funding amount
/// at vout=1 (satisfying PP1/PP3 hardcoded constraints).
///
/// Results are ordered for sequential broadcast (split TX first).
class ProvisionedTransaction {
  /// Transaction ID (hex).
  final String txid;

  /// Raw transaction hex.
  final String rawHex;

  /// Fee paid by this transaction in satoshis.
  final int feeSats;

  /// Role in the provision tree: "split" (level 1) or "earmark" (level 2).
  final String role;

  /// Earmark purpose. Null for split TX.
  /// Values: "issuance-witness", "transfer", "transfer-witness".
  final String? purpose;

  /// Output index where earmarked sats sit.
  /// Always 1 for earmarks (protocol constraint), -1 for split.
  final int fundingVout;

  /// Satoshis at [fundingVout]. -1 for split.
  final int fundingSats;

  const ProvisionedTransaction({
    required this.txid,
    required this.rawHex,
    required this.feeSats,
    required this.role,
    this.purpose,
    required this.fundingVout,
    required this.fundingSats,
  });
}
