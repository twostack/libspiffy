/// Rules every [ReadModelStorage] backend applies when it stores a
/// transaction row (bead libspiffy-7dj), in one place.
library;

import '../models/bitcoin_transaction.dart';

/// How a stored transaction row takes a new record of the same transaction.
abstract final class TransactionRowRules {
  /// Stage of a status along the lifecycle; null for the side states
  /// ([TransactionStatus.failed], [TransactionStatus.orphaned]) that ARC may
  /// report at any stage and that later reports may leave.
  static int? _stage(TransactionStatus status) => switch (status) {
        TransactionStatus.created => 0,
        TransactionStatus.signed => 1,
        // A recorded transaction is pending; ARC's first answer (queued,
        // stored, ...) is broadcast. Neither is later than the other.
        TransactionStatus.broadcast || TransactionStatus.pending => 2,
        TransactionStatus.seenOnNetwork => 3,
        TransactionStatus.confirmed => 4,
        TransactionStatus.failed || TransactionStatus.orphaned => null,
      };

  /// Whether an ordinary store of a record with status [incoming] sets the
  /// status of a row stored with status [stored].
  ///
  /// * A confirmed row stays confirmed: a later record that is not a
  ///   confirmation (a stale ARC report of SEEN_ON_NETWORK, REJECTED or an
  ///   orphan mempool, a BEEF re-delivered without its proof, an import
  ///   replay) is older news than the verified proof. Only a reorganization
  ///   or a rejected proof takes a confirmation back, through
  ///   `ReadModelStorage.storeRevertedTransaction`.
  /// * Otherwise a row does not go back along created, signed,
  ///   broadcast / pending, seenOnNetwork.
  /// * failed and orphaned may follow any status but confirmed, and any
  ///   status may follow them (a rebroadcast after orphan remediation, a
  ///   transaction mined after all).
  ///
  /// A row whose status is kept also keeps its block height and
  /// confirmations; the record's other fields are stored.
  static bool setsStatus(TransactionStatus stored, TransactionStatus incoming) {
    if (stored == incoming) return true;
    if (stored == TransactionStatus.confirmed) return false;
    final from = _stage(stored);
    final to = _stage(incoming);
    if (from == null || to == null) return true;
    return to >= from;
  }

  /// The confirmation time (`confirmedAt`) a row stores after a record with
  /// status [incoming] and update time [recordedAt] (bead libspiffy-hccp).
  ///
  /// [stored] and [storedConfirmedAt] are the row's status and confirmation
  /// time before the store (null for a new row); [statusSet] is whether the
  /// store sets the status ([setsStatus], or a revert).
  ///
  /// * A record that confirms a row not yet confirmed (a new row, a pending
  ///   one, one a reorganization reverted) sets it to [recordedAt], the
  ///   confirming record's own time, so a replay stores the same value.
  /// * A later confirmed record (a confirmation count update, the
  ///   confirmation replayed) keeps it: it is the time of the first
  ///   confirmation. A confirmed row stored without one gets [recordedAt].
  /// * Every other record keeps it, a revert included: nothing is blanked. A
  ///   row confirmed again after a revert gets the new confirmation's time;
  ///   the orphaned confirmation stays on record in the merkle proof history.
  static DateTime? confirmedAtAfter({
    required TransactionStatus? stored,
    required DateTime? storedConfirmedAt,
    required TransactionStatus incoming,
    required DateTime recordedAt,
    required bool statusSet,
  }) {
    if (!statusSet || incoming != TransactionStatus.confirmed) return storedConfirmedAt;
    if (stored != TransactionStatus.confirmed) return recordedAt;
    return storedConfirmedAt ?? recordedAt;
  }

  /// The statuses of a stored row whose status a record with status
  /// [incoming] sets ([setsStatus]), for backends that apply the rule in a
  /// query.
  static List<TransactionStatus> statusesSetBy(TransactionStatus incoming) => [
        for (final stored in TransactionStatus.values)
          if (setsStatus(stored, incoming)) stored,
      ];

  /// The opaque counterparty marker a row stores after a record carrying
  /// [incoming], given the [stored] one (bead libspiffy-cq16).
  ///
  /// Set once, by the first record that carries one, and kept from then on:
  /// no later record blanks it (a status update, a confirmation, a stale ARC
  /// report, a re-delivered BEEF, an import replay, a reorganization) and
  /// none replaces it with a different value. It is wallet data like any
  /// other, and no service can be asked for an identity we dropped
  /// (spv-understanding.md, Data Retention).
  ///
  /// A blank string is not a marker: it is what an actor message carries
  /// when the app supplied nothing, and it is read as absent. The value is
  /// otherwise opaque — never parsed, validated or interpreted.
  static String? counterpartyMarkerAfter(String? stored, String? incoming) {
    if (stored != null && stored.isNotEmpty) return stored;
    if (incoming != null && incoming.isNotEmpty) return incoming;
    return null;
  }

  /// The other party of [tx] from the wallet's perspective: the first
  /// sending address of an incoming transaction, the first receiving
  /// address of an outgoing one, null otherwise. Stored as the primary
  /// counterparty (and, on insert, the counterparty) of a row.
  static String? primaryCounterpartyOf(BitcoinTransaction tx) {
    final net = tx.netAmount;
    if (net > BigInt.zero) {
      return tx.sendingAddresses.isNotEmpty ? tx.sendingAddresses.first : null;
    } else if (net < BigInt.zero) {
      return tx.receivingAddresses.isNotEmpty ? tx.receivingAddresses.first : null;
    }
    return null;
  }
}
