/// A wallet output that another transaction spends
/// (`CheckForeignSpendsCommand`).
library;

/// One wallet output another transaction spends, found by
/// `CheckOutputSpendersMessage`.
class ForeignSpend {
  /// `txid:vout` of the wallet's output.
  final String utxoKey;

  /// The transaction the data source names as spending it.
  final String spentBy;

  /// The data source says the spender is in a block.
  final bool confirmed;

  /// The spender's merkle proof checked out against the local headers, and
  /// its bytes spend [utxoKey]: the output was marked spent by [spentBy].
  final bool proven;

  /// The spender's raw transaction, when [proven].
  final String? spenderRawHex;

  const ForeignSpend({
    required this.utxoKey,
    required this.spentBy,
    required this.confirmed,
    required this.proven,
    this.spenderRawHex,
  });

  @override
  String toString() => '$utxoKey spent by $spentBy${proven ? ' (proven)' : confirmed ? ' (confirmed, not proven)' : ' (unconfirmed)'}';
}

