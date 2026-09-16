/// A received BEEF that could not be judged yet, kept so the receive can be
/// replayed without the counterparty sending it again (bead libspiffy-vfai).
library;

/// A receive parked until the block header(s) its merkle proof(s) need arrive.
///
/// Bead libspiffy-68mz retains the BEEF's *evidence* durably (its
/// transactions in the ancestor store, its BUMPs as `pendingHeader` proofs),
/// but the receive itself waited in an in-memory queue: a restart credited
/// the wallet with nothing when the header finally landed, although nothing
/// could hand the BEEF to us again (no block scanning, no indexer, and ARC
/// knows only what we broadcast ourselves). This row is that queue, durable.
///
/// Keyed by ([walletId], [txid]). A receive that names no wallet has an empty
/// [walletId]. Rows are never deleted: a replay that settles the receive
/// stamps [resolvedAt] and [resolution], so the row stays as the record of
/// what was handed to us and what became of it (it is also what stops the
/// same receive being replayed on every later header).
class PendingReceive {
  /// The wallet the receive is for; empty when it names none.
  final String walletId;

  /// The subject transaction of the BEEF (display format).
  final String txid;

  /// The BEEF exactly as it was handed to us, hex encoded.
  final String beefHex;

  /// Who handed it to us (`ReceiveTransactionMessage.fromCounterparty`).
  final String fromCounterparty;

  /// The invoice the payment is for, if any.
  final String? invoiceId;

  /// The highest block height a proof in the BEEF needs before the receive
  /// can be judged. The replay runs when headers reach it.
  final int neededHeight;

  /// When the receive was first parked.
  final DateTime createdAt;

  /// When it was last parked or replayed.
  final DateTime updatedAt;

  /// When the receive stopped waiting (it was recorded, or it failed for a
  /// reason more headers cannot change). Null while it is still waiting.
  final DateTime? resolvedAt;

  /// What happened to it, once [resolvedAt] is set.
  final String? resolution;

  const PendingReceive({
    required this.walletId,
    required this.txid,
    required this.beefHex,
    required this.fromCounterparty,
    required this.neededHeight,
    required this.createdAt,
    required this.updatedAt,
    this.invoiceId,
    this.resolvedAt,
    this.resolution,
  });

  /// Whether the receive is still waiting for headers.
  bool get isWaiting => resolvedAt == null;

  PendingReceive copyWith({
    String? beefHex,
    String? fromCounterparty,
    String? invoiceId,
    int? neededHeight,
    DateTime? createdAt,
    DateTime? updatedAt,
    DateTime? resolvedAt,
    String? resolution,
  }) =>
      PendingReceive(
        walletId: walletId,
        txid: txid,
        beefHex: beefHex ?? this.beefHex,
        fromCounterparty: fromCounterparty ?? this.fromCounterparty,
        invoiceId: invoiceId ?? this.invoiceId,
        neededHeight: neededHeight ?? this.neededHeight,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        resolvedAt: resolvedAt ?? this.resolvedAt,
        resolution: resolution ?? this.resolution,
      );

  @override
  String toString() => 'PendingReceive($walletId, $txid, needs height $neededHeight, '
      '${isWaiting ? 'waiting' : 'resolved: $resolution'})';
}
