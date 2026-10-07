/// A wallet output that another transaction spends
/// (`CheckForeignSpendsCommand`).
library;

/// One wallet output another transaction spends: found by
/// `CheckOutputSpendersMessage`, and recorded in the wallet by
/// `CheckForeignSpendsCommand` when the spender is [proven].
class ForeignSpend {
  /// `txid:vout` of the wallet's output.
  final String utxoKey;

  /// The transaction the data source names as spending it.
  final String spentBy;

  /// The data source says the spender is in a block.
  final bool confirmed;

  /// The spender's merkle proof checked out against the local headers, and
  /// its bytes spend [utxoKey].
  final bool proven;

  /// The spender's raw transaction, when [proven].
  final String? spenderRawHex;

  /// The spender with its merkle proof, as a BEEF, when [proven]: what the
  /// wallet records, and what another wallet can import.
  final String? spenderBeefHex;

  /// The spender is in the wallet's records: [utxoKey] is marked spent by
  /// it, its outputs that pay the wallet's addresses are received, as
  /// available, in the block its proof names, and it is in the wallet's
  /// transaction history. Only a [proven] spender is recorded; a proven one
  /// that is not says why in [recordError].
  final bool recorded;

  /// Why a [proven] spender is not [recorded].
  final String? recordError;

  const ForeignSpend({
    required this.utxoKey,
    required this.spentBy,
    required this.confirmed,
    required this.proven,
    this.spenderRawHex,
    this.spenderBeefHex,
    this.recorded = false,
    this.recordError,
  });

  /// This spend with its recording outcome.
  ForeignSpend recordedAs({required bool recorded, String? error}) => ForeignSpend(
        utxoKey: utxoKey,
        spentBy: spentBy,
        confirmed: confirmed,
        proven: proven,
        spenderRawHex: spenderRawHex,
        spenderBeefHex: spenderBeefHex,
        recorded: recorded,
        recordError: recorded ? null : error,
      );

  @override
  String toString() => '$utxoKey spent by $spentBy'
      '${proven ? recorded ? ' (proven, recorded)' : ' (proven, not recorded: $recordError)' : confirmed ? ' (confirmed, not proven)' : ' (unconfirmed)'}';
}
