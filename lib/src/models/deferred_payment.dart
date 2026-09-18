/// Deferred payments (bead libspiffy-7p2): outgoing transactions the wallet
/// signed and recorded with a deferred spend, whose inputs it holds until the
/// network settles them.
///
/// In the BSV peer-to-peer model (spv-understanding.md) the sender hands the
/// signed transaction (BEEF) to the recipient, who normally broadcasts it.
/// Until the network has it, the payment's inputs must not be used for
/// anything else: a later payment spending them would double-spend the one
/// the recipient holds. A [DeferredPayment] is the read-model view of such a
/// payment; the wallet aggregate is the source of truth for the hold.
library;

import 'dart:convert';

/// Lifecycle of a deferred payment.
///
/// ```text
///               recorded (deferSpend)
///                        |
///                        v
///                  +-----------+  ARC/data source SEEN_ON_NETWORK or MINED,
///                  |outstanding|  or an input spent by the transaction
///                  +-----------+ -------------------------------------+
///                   |         |                                       |
///  ARC REJECTED     |         | CancelDeferredSpendCommand            v
///                   |         | (network does not know it, or ARC +------+
///                   v         v  reports DOUBLE_SPEND_ATTEMPTED)  | seen |
///              +------+   +---------+   network reports it later  +------+
///              |failed|   |cancelled| --------------------------->   |  ^
///              +------+   +---------+                                 |  |
///                 |                                verified proof     |  | confirmation
///                 +-------------- (network reports it later) ------>  v  | reverted
///                                                                   +-----+
///                                                                   |mined|
///                                                                   +-----+
///
///                  +-----------+  ReclaimDeferredSpendCommand: the wallet's
///                  |outstanding|  own self-spend of the held inputs is
///                  +-----------+  recorded and broadcast; once the network
///                        |        has THAT transaction (it is seen or mined)
///                        v
///                  +---------+
///                  |reclaimed|  terminal; the inputs are back in the wallet
///                  +---------+
/// ```
///
/// Inputs are held only while [outstanding]. [failed] and [cancelled]
/// released them; [seen] and [mined] spent them. Evidence from the network
/// wins: a failed or cancelled payment the network later reports is [seen].
///
/// [reclaimed] is the one resolution that spends the held inputs elsewhere:
/// the wallet built and broadcast its own transaction paying them back to
/// itself (bead libspiffy-87a). It is reached only once that self-spend is
/// on the network, so until then the payment is still [outstanding] with the
/// reclaim in flight. The original payment, its signed transaction and its
/// raw hex are kept; the reclaim's own record names it (its purpose is
/// `reclaim:<txid>`, see [DeferredPaymentPurpose]).
///
/// ARC's DOUBLE_SPEND_ATTEMPTED (a competing transaction spends an input) is
/// not final: either transaction may still be mined. The payment stays
/// [outstanding] with its inputs held and the status recorded (bead
/// libspiffy-ey2); ARC keeps being polled. Journals written before that,
/// where DOUBLE_SPEND_ATTEMPTED failed the payment, replay as they were.
enum DeferredPaymentState {
  /// Signed and handed over; not yet known to be on the network. Inputs held.
  outstanding,

  /// On the network (ARC SEEN_ON_NETWORK / MINED, a data source knows the
  /// transaction, or one of its inputs was spent by it). Not a confirmation.
  seen,

  /// Confirmed by a merkle proof checked against the local header chain.
  mined,

  /// ARC reported REJECTED (or, in a journal written before bead
  /// libspiffy-ey2, DOUBLE_SPEND_ATTEMPTED); inputs released.
  failed,

  /// Cancelled by the user while the network did not know the transaction;
  /// inputs released. The recipient still holds the signed transaction.
  cancelled,

  /// The wallet spent the held inputs back to itself and the network has
  /// that self-spend (bead libspiffy-87a). Terminal: the signed transaction
  /// the recipient holds can no longer be mined, because its inputs are
  /// gone. Reached only when the self-spend is seen or mined, never at
  /// broadcast time.
  ///
  /// Appended after [cancelled]: states are journaled and stored by name,
  /// so a journal or a row written before this state replays unchanged.
  reclaimed,
}

/// The `purpose` a deferred payment carries, for the values the wallet
/// itself sets and reads back.
///
/// A reclaim's self-spend is recorded with `reclaim:<txid of the payment it
/// reclaims>`: that is how the payment it resolves stays queryable from the
/// read model without a schema change, and how the projection finds the
/// payment to resolve when the self-spend reaches the network.
abstract final class DeferredPaymentPurpose {
  /// Purpose prefix of a reclaim's self-spend.
  static const String reclaimPrefix = 'reclaim:';

  /// The purpose of the self-spend that reclaims [txid].
  static String reclaimOf(String txid) => '$reclaimPrefix$txid';

  /// The payment [purpose] reclaims, or null when it is not a reclaim.
  static String? reclaimedTxid(String? purpose) =>
      purpose != null && purpose.startsWith(reclaimPrefix) && purpose.length > reclaimPrefix.length
          ? purpose.substring(reclaimPrefix.length)
          : null;
}

/// Where a network check or a broadcast of a deferred payment goes.
enum DeferredPaymentNetworkSource {
  /// The ARC service only (default).
  arc,

  /// The configured `BlockchainDataSource` only (a node or WhatsOnChain).
  /// A MINED answer from it is never trusted alone: its merkle proof is
  /// checked against the local headers before anything is confirmed.
  dataSource,

  /// ARC first; the data source when ARC fails or does not know the
  /// transaction.
  arcThenDataSource,
}

/// Network status strings recorded for deferred payments.
///
/// ARC statuses keep ARC's wire names (`SEEN_ON_NETWORK`, `MINED`, ...). The
/// values below are the ones the wallet acts on, plus the two it adds.
abstract final class DeferredNetworkStatus {
  static const String seenOnNetwork = 'SEEN_ON_NETWORK';
  static const String mined = 'MINED';
  static const String rejected = 'REJECTED';
  static const String doubleSpendAttempted = 'DOUBLE_SPEND_ATTEMPTED';
  static const String seenInOrphanMempool = 'SEEN_IN_ORPHAN_MEMPOOL';

  /// The source answered that it does not know the transaction (ARC 404,
  /// data source "not found"). Not a failure: the recipient may broadcast
  /// later.
  static const String notFound = 'NOT_FOUND';

  /// Filter value matching payments never checked (no recorded status).
  static const String unchecked = 'UNCHECKED';

  /// Statuses that settle a deferred payment as failed: REJECTED only.
  /// Everything else (404, network errors, orphan mempool, in-flight
  /// statuses, DOUBLE_SPEND_ATTEMPTED) is not.
  static bool isDefinitiveFailure(String? status) => status == rejected;

  /// ARC saw a competing transaction spending an input (bead libspiffy-ey2).
  /// Not final: ARC documents that the payment may still be mined. The
  /// payment stays outstanding with its inputs held, the status is recorded
  /// and ARC keeps being polled.
  static bool isContested(String? status) => status == doubleSpendAttempted;

  /// Statuses that mean the network has the transaction (the deferred spend
  /// applies).
  static bool isOnNetwork(String? status) => status == seenOnNetwork || status == mined;

  /// Whether a payment with this status may be cancelled: when the source
  /// said it does not know the transaction, or when ARC reports it contested
  /// (DOUBLE_SPEND_ATTEMPTED, bead libspiffy-ey2: the user may give it up;
  /// if it is mined anyway, the wallet records it as seen). Any other status
  /// ARC reports for a transaction it holds (queued, stored, sent, seen,
  /// mined, orphan mempool, ...) means it is on its way to miners.
  static bool allowsCancel(String? status) => status == notFound || status == doubleSpendAttempted;
}

/// One input a deferred payment holds.
class DeferredPaymentInput {
  /// `txid:vout` of the wallet UTXO.
  final String utxoKey;

  /// Its amount (0 when the wallet did not know the UTXO's amount).
  final BigInt satoshis;

  const DeferredPaymentInput({required this.utxoKey, required this.satoshis});

  Map<String, dynamic> toMap() => {'utxoKey': utxoKey, 'satoshis': satoshis.toString()};

  factory DeferredPaymentInput.fromMap(Map<dynamic, dynamic> map) => DeferredPaymentInput(
        utxoKey: map['utxoKey'].toString(),
        satoshis: BigInt.tryParse(map['satoshis']?.toString() ?? '') ?? BigInt.zero,
      );

  @override
  bool operator ==(Object other) =>
      other is DeferredPaymentInput && other.utxoKey == utxoKey && other.satoshis == satoshis;

  @override
  int get hashCode => Object.hash(utxoKey, satoshis);

  @override
  String toString() => '$utxoKey ($satoshis sat)';
}

/// Read model of a deferred payment. Never deleted (only a wallet deletion
/// removes it): resolved payments stay listable with their state.
class DeferredPayment {
  final String walletId;
  final String txid;

  /// Invoice the payment paid, when it came from `PayInvoiceCommand`.
  final String? invoiceId;

  /// What recorded it: `invoice-payment`, `provisioning-split`,
  /// `provisioning-earmark`, `channel-funding`, `legacy` (inferred from a
  /// journal written before holds existed), or null.
  final String? purpose;

  final List<String> recipientAddresses;

  /// Amount paid to the recipients.
  final BigInt amount;
  final BigInt fee;

  /// The inputs the payment held when it was recorded. They stay listed
  /// after resolution (as history); [state] says whether they are still held.
  final List<DeferredPaymentInput> heldInputs;

  final DeferredPaymentState state;

  /// Last network status recorded (ARC's wire name, or
  /// [DeferredNetworkStatus.notFound]); null if never checked.
  final String? lastNetworkStatus;

  /// `arc` or `dataSource`.
  final String? lastNetworkStatusSource;

  /// When [lastNetworkStatus] was observed. The periodic status scan records
  /// a status only when it changes; explicit checks and broadcasts always.
  final DateTime? lastCheckedAt;

  /// The competing transactions ARC named (`competingTxs`) when it reported
  /// DOUBLE_SPEND_ATTEMPTED for this payment (bead libspiffy-pkum): every
  /// txid reported so far, in the order first reported. Kept when a later
  /// status names none and after the payment resolves; empty when ARC named
  /// none, or for a status journaled before they were recorded.
  final List<String> competingTxids;

  /// When the payment was recorded (handed over).
  final DateTime createdAt;
  final DateTime updatedAt;

  /// When it left [DeferredPaymentState.outstanding].
  final DateTime? resolvedAt;

  /// Why it was failed or cancelled.
  final String? resolutionReason;

  /// True for a payment inferred from a journal written before deferred
  /// holds were journaled.
  final bool inferred;

  const DeferredPayment({
    required this.walletId,
    required this.txid,
    this.invoiceId,
    this.purpose,
    this.recipientAddresses = const [],
    required this.amount,
    required this.fee,
    this.heldInputs = const [],
    this.state = DeferredPaymentState.outstanding,
    this.lastNetworkStatus,
    this.lastNetworkStatusSource,
    this.lastCheckedAt,
    this.competingTxids = const [],
    required this.createdAt,
    required this.updatedAt,
    this.resolvedAt,
    this.resolutionReason,
    this.inferred = false,
  });

  bool get isOutstanding => state == DeferredPaymentState.outstanding;

  /// Total of [heldInputs].
  BigInt get heldSatoshis => heldInputs.fold(BigInt.zero, (sum, i) => sum + i.satoshis);

  static const _unset = Object();

  DeferredPayment copyWith({
    DeferredPaymentState? state,
    Object? lastNetworkStatus = _unset,
    Object? lastNetworkStatusSource = _unset,
    Object? lastCheckedAt = _unset,
    List<String>? competingTxids,
    DateTime? updatedAt,
    Object? resolvedAt = _unset,
    Object? resolutionReason = _unset,
    List<DeferredPaymentInput>? heldInputs,
  }) =>
      DeferredPayment(
        walletId: walletId,
        txid: txid,
        invoiceId: invoiceId,
        purpose: purpose,
        recipientAddresses: recipientAddresses,
        amount: amount,
        fee: fee,
        heldInputs: heldInputs ?? this.heldInputs,
        state: state ?? this.state,
        lastNetworkStatus:
            identical(lastNetworkStatus, _unset) ? this.lastNetworkStatus : lastNetworkStatus as String?,
        lastNetworkStatusSource: identical(lastNetworkStatusSource, _unset)
            ? this.lastNetworkStatusSource
            : lastNetworkStatusSource as String?,
        lastCheckedAt: identical(lastCheckedAt, _unset) ? this.lastCheckedAt : lastCheckedAt as DateTime?,
        competingTxids: competingTxids ?? this.competingTxids,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        resolvedAt: identical(resolvedAt, _unset) ? this.resolvedAt : resolvedAt as DateTime?,
        resolutionReason:
            identical(resolutionReason, _unset) ? this.resolutionReason : resolutionReason as String?,
        inferred: inferred,
      );

  /// JSON of [heldInputs] (storage backends keep it in one column).
  String get heldInputsJson => jsonEncode([for (final i in heldInputs) i.toMap()]);

  static List<DeferredPaymentInput> heldInputsFromJson(String? json) {
    if (json == null || json.isEmpty) return const [];
    final decoded = jsonDecode(json);
    if (decoded is! List) return const [];
    return [for (final e in decoded) if (e is Map) DeferredPaymentInput.fromMap(e)];
  }

  /// [known] followed by the txids of [reported] it does not hold, or null
  /// when [reported] adds none: how a new report of competing transactions
  /// joins the ones recorded (bead libspiffy-pkum).
  static List<String>? mergeCompetingTxids(List<Object?>? known, List<String> reported) {
    final merged = [for (final t in known ?? const []) t.toString()];
    final seen = merged.toSet();
    var added = false;
    for (final t in reported) {
      if (seen.add(t)) {
        merged.add(t);
        added = true;
      }
    }
    return added ? merged : null;
  }

  /// The resolution reason recorded when a payment is reclaimed by the
  /// wallet's own self-spend [reclaimTxid] (bead libspiffy-87a).
  static String reclaimedBy(String reclaimTxid) =>
      "Reclaimed by the wallet's own transaction $reclaimTxid, which spends its inputs back to the wallet";

  /// The resolution reason recorded when a reclaim's self-spend lost the
  /// race: [spentInTxId] — in practice the recipient's copy of the payment
  /// being reclaimed — spent the held input [utxoKey] first (bead
  /// libspiffy-wfvi).
  ///
  /// First seen wins on this network and there is no replace-by-fee, so this
  /// is an ordering fact and not a fee question: no fee would have changed
  /// the outcome, and nothing is retried.
  static String reclaimLostRace(String utxoKey, String spentInTxId) =>
      'The input $utxoKey it spends was spent by $spentInTxId first, so this reclaim can no longer be '
      'mined: first seen wins, and no fee changes that';

  static DeferredPaymentState stateFromName(String? name) => DeferredPaymentState.values
      .firstWhere((s) => s.name == name, orElse: () => DeferredPaymentState.outstanding);

  @override
  bool operator ==(Object other) =>
      other is DeferredPayment &&
      other.walletId == walletId &&
      other.txid == txid &&
      other.invoiceId == invoiceId &&
      other.purpose == purpose &&
      _listEquals(other.recipientAddresses, recipientAddresses) &&
      other.amount == amount &&
      other.fee == fee &&
      _listEquals(other.heldInputs, heldInputs) &&
      other.state == state &&
      other.lastNetworkStatus == lastNetworkStatus &&
      other.lastNetworkStatusSource == lastNetworkStatusSource &&
      _sameInstant(other.lastCheckedAt, lastCheckedAt) &&
      _listEquals(other.competingTxids, competingTxids) &&
      _sameInstant(other.createdAt, createdAt) &&
      _sameInstant(other.updatedAt, updatedAt) &&
      _sameInstant(other.resolvedAt, resolvedAt) &&
      other.resolutionReason == resolutionReason &&
      other.inferred == inferred;

  @override
  int get hashCode => Object.hash(walletId, txid, state);

  static bool _listEquals<T>(List<T> a, List<T> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static bool _sameInstant(DateTime? a, DateTime? b) =>
      a == null ? b == null : b != null && a.microsecondsSinceEpoch == b.microsecondsSinceEpoch;

  @override
  String toString() => 'DeferredPayment($walletId, $txid, ${state.name}, '
      'status: $lastNetworkStatus${competingTxids.isEmpty ? '' : ', competing: $competingTxids'}, inputs: $heldInputs)';
}

/// Filter and page of [ReadModelStorage.listDeferredPayments].
///
/// Results are ordered by [DeferredPayment.createdAt] (newest first unless
/// [oldestFirst]), ties by txid. [cursor] is the [DeferredPaymentPage.nextCursor]
/// of the previous page, for the same filter and order.
class DeferredPaymentQuery {
  /// States to include. Default: outstanding only.
  final Set<DeferredPaymentState> states;

  /// Only payments created strictly before / at-or-after these instants.
  final DateTime? createdBefore;
  final DateTime? createdAfter;

  /// Only payments whose last recorded network status is one of these
  /// ([DeferredNetworkStatus.unchecked] matches never-checked payments).
  final Set<String>? lastNetworkStatuses;

  final String? invoiceId;

  /// Only payments paying this address.
  final String? recipientAddress;

  /// Page size (1 to 1000).
  final int limit;
  final String? cursor;
  final bool oldestFirst;

  const DeferredPaymentQuery({
    this.states = const {DeferredPaymentState.outstanding},
    this.createdBefore,
    this.createdAfter,
    this.lastNetworkStatuses,
    this.invoiceId,
    this.recipientAddress,
    this.limit = 50,
    this.cursor,
    this.oldestFirst = false,
  });

  /// Every state.
  static const Set<DeferredPaymentState> allStates = {
    DeferredPaymentState.outstanding,
    DeferredPaymentState.seen,
    DeferredPaymentState.mined,
    DeferredPaymentState.failed,
    DeferredPaymentState.cancelled,
    DeferredPaymentState.reclaimed,
  };

  int get effectiveLimit => limit < 1 ? 1 : (limit > 1000 ? 1000 : limit);

  /// Whether [p] passes every filter except the cursor.
  bool matches(DeferredPayment p) {
    if (!states.contains(p.state)) return false;
    if (createdBefore != null && !p.createdAt.isBefore(createdBefore!)) return false;
    if (createdAfter != null && p.createdAt.isBefore(createdAfter!)) return false;
    final statuses = lastNetworkStatuses;
    if (statuses != null &&
        !statuses.contains(p.lastNetworkStatus ?? DeferredNetworkStatus.unchecked)) {
      return false;
    }
    if (invoiceId != null && p.invoiceId != invoiceId) return false;
    if (recipientAddress != null && !p.recipientAddresses.contains(recipientAddress)) return false;
    return true;
  }

  /// Orders [a] before [b] in this query's order.
  int compare(DeferredPayment a, DeferredPayment b) {
    final byTime = a.createdAt.microsecondsSinceEpoch.compareTo(b.createdAt.microsecondsSinceEpoch);
    final c = byTime != 0 ? byTime : a.txid.compareTo(b.txid);
    return oldestFirst ? c : -c;
  }

  /// Whether [p] comes after the decoded [cursor] in this query's order.
  bool isAfterCursor(DeferredPayment p) {
    final c = decodeCursor(cursor);
    if (c == null) return true;
    final micros = p.createdAt.microsecondsSinceEpoch;
    final cmp = micros != c.$1 ? micros.compareTo(c.$1) : p.txid.compareTo(c.$2);
    return oldestFirst ? cmp > 0 : cmp < 0;
  }

  /// The cursor that continues after [p].
  static String cursorAfter(DeferredPayment p) => '${p.createdAt.microsecondsSinceEpoch}_${p.txid}';

  /// (createdAt micros, txid) of [cursor], or null for none. Throws
  /// [FormatException] for a cursor this class did not produce.
  static (int, String)? decodeCursor(String? cursor) {
    if (cursor == null || cursor.isEmpty) return null;
    final sep = cursor.indexOf('_');
    final micros = sep > 0 ? int.tryParse(cursor.substring(0, sep)) : null;
    if (micros == null) throw FormatException('Invalid deferred payment cursor', cursor);
    return (micros, cursor.substring(sep + 1));
  }

  /// The page of [sortedMatches] (already filtered by [matches], sorted by
  /// [compare]) after [cursor].
  DeferredPaymentPage page(Iterable<DeferredPayment> sortedMatches) {
    final rows = sortedMatches.where(isAfterCursor).take(effectiveLimit + 1).toList();
    final hasMore = rows.length > effectiveLimit;
    final payments = hasMore ? rows.sublist(0, effectiveLimit) : rows;
    return DeferredPaymentPage(
      payments: payments,
      nextCursor: hasMore ? cursorAfter(payments.last) : null,
    );
  }
}

/// One page of deferred payments.
class DeferredPaymentPage {
  final List<DeferredPayment> payments;

  /// Pass as [DeferredPaymentQuery.cursor] for the next page; null when this
  /// is the last page.
  final String? nextCursor;

  const DeferredPaymentPage({required this.payments, this.nextCursor});
}
