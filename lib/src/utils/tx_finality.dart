import 'package:dartsv/dartsv.dart' as dartsv;

/// Whether [tx] can be mined in the next block as far as its own fields
/// say: every input's sequence final, no lock time, or a lock time already
/// past. A block height lock (below 500 000 000) is past when it is below
/// the next block, [bestHeight] + 1; a time lock when it is more than two
/// hours before [now] (the network compares it with the median time of the
/// last blocks, which lags). Wallets set the lock time to the current height
/// as a matter of course, so a lock time is common and mostly past. Unknown
/// [bestHeight] counts a height lock as not past.
///
/// A transaction that is not final is refused by the network until its lock
/// time, and can be replaced until then: it is no payment yet
/// (spiffyvault-bld, spiffyvault-95e).
bool isFinalTransaction(dartsv.Transaction tx, {required int? bestHeight, required DateTime now}) {
  final lockTime = tx.nLockTime;
  if (lockTime == 0) return true;
  if (tx.inputs.every((i) => i.sequenceNumber == dartsv.TransactionInput.MAX_SEQ_NUMBER)) return true;
  if (lockTime < 500000000) return bestHeight != null && lockTime < bestHeight + 1;
  final lockedUntil = DateTime.fromMillisecondsSinceEpoch(lockTime * 1000, isUtc: true);
  return lockedUntil.isBefore(now.toUtc().subtract(const Duration(hours: 2)));
}
