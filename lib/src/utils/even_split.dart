/// [amount] split over [parts] outputs as evenly as whole satoshis allow:
/// each part is `amount ~/ parts`, and the last also takes the remainder,
/// so the parts add up to [amount] (spiffyvault-bnb, spiffyvault-2ct.7).
/// The remainder used to be dropped, and went to the fee: a payee that
/// asked for 1001 sats over two addresses was paid 1000 and refused it as
/// short.
///
/// Payer and payee both split with this, so an invoice's legacy addresses
/// expect exactly what the payer sends.
List<BigInt> evenSplit(BigInt amount, int parts) {
  if (parts < 1) throw ArgumentError.value(parts, 'parts', 'must be at least 1');
  final n = BigInt.from(parts);
  final each = amount ~/ n;
  final remainder = amount - each * n;
  return [for (var i = 0; i < parts; i++) i == parts - 1 ? each + remainder : each];
}
