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

  /// The statuses of a stored row whose status a record with status
  /// [incoming] sets ([setsStatus]), for backends that apply the rule in a
  /// query.
  static List<TransactionStatus> statusesSetBy(TransactionStatus incoming) => [
        for (final stored in TransactionStatus.values)
          if (setsStatus(stored, incoming)) stored,
      ];

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
