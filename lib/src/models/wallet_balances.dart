import 'bitcoin_utxo.dart';

/// The balance a wallet UTXO counts towards in the wallet's write model
/// ([WalletState.confirmedBalance], [WalletState.unconfirmedBalance],
/// [WalletState.reservedBalance]).
enum BalanceBucket { confirmed, unconfirmed, reserved }

/// The wallet write model's balance rule, in one place (bead libspiffy-dp4).
///
/// Both balance computations of the wallet aggregate use it: the full
/// recomputation ([WalletState.recalculateBalances], and the aggregate's
/// snapshot restore) and the incremental update that moves one UTXO's amount
/// between buckets as each event applies (`WalletStateBuilder.putUtxo`).
///
/// The rule counts every unspent UTXO the state holds, plugin-managed and
/// watch-only UTXOs included. The read model's balances
/// (`WalletProjection`) leave plugin-managed UTXOs out, and the coordinator's
/// `BalanceResponse` counts payment UTXOs by block height and reports
/// watch-only funds apart; those are separate read-side rules.
abstract final class WalletBalances {
  /// Confirmations from which an unreserved UTXO is confirmed balance.
  static const int confirmedAt = 6;

  /// The bucket [utxo] counts towards, or null when it counts towards none
  /// (spent): reserved when reserved, confirmed with [confirmedAt] or more
  /// confirmations, unconfirmed otherwise.
  static BalanceBucket? bucketOf(BitcoinUtxo utxo) {
    if (utxo.status == UTXOStatus.spent) return null;
    if (utxo.status == UTXOStatus.reserved) return BalanceBucket.reserved;
    if ((utxo.confirmations ?? 0) >= confirmedAt) return BalanceBucket.confirmed;
    return BalanceBucket.unconfirmed;
  }

  /// The confirmed, unconfirmed and reserved totals of [utxos].
  static ({BigInt confirmed, BigInt unconfirmed, BigInt reserved}) totals(Iterable<BitcoinUtxo> utxos) {
    var confirmed = BigInt.zero;
    var unconfirmed = BigInt.zero;
    var reserved = BigInt.zero;
    for (final utxo in utxos) {
      switch (bucketOf(utxo)) {
        case BalanceBucket.confirmed:
          confirmed += utxo.satoshis;
        case BalanceBucket.unconfirmed:
          unconfirmed += utxo.satoshis;
        case BalanceBucket.reserved:
          reserved += utxo.satoshis;
        case null:
          break;
      }
    }
    return (confirmed: confirmed, unconfirmed: unconfirmed, reserved: reserved);
  }
}
