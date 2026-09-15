import '../core/wallet_output_ownership.dart' show isWatchOnlyOutput;
import '../utils/network_name.dart';
import 'bitcoin_utxo.dart';
import 'wallet_state.dart';

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
/// Two rules live here, and they answer different questions:
///
/// * The buckets ([bucketOf], [totals]) say where each unspent UTXO's amount
///   is reported: reserved when reserved (a deferred payment's hold
///   included), confirmed from [confirmedAt] confirmations, unconfirmed
///   otherwise (pending UTXOs included). They count every unspent UTXO the
///   state holds, plugin-managed and watch-only UTXOs included, so
///   confirmed + unconfirmed + reserved is everything the wallet holds.
///   These totals are journaled in snapshots.
/// * The spendable rule ([isSpendable], [spendableTotal]) says which UTXOs
///   the aggregate's coin selection may pick (`UtxoLedger.available`,
///   `BitcoinWalletAggregate.selectUTXOsForAmount`), and so what
///   [WalletState.availableBalance] and
///   `BitcoinWalletAggregate.hasSufficientBalance` count: status available,
///   no plugin metadata, not watch-only, with any number of confirmations.
///   It is not derived from the buckets (bead libspiffy-ad07: subtracting
///   the reserved bucket from the other two subtracted reserved UTXOs twice
///   and counted pending, plugin-managed and watch-only UTXOs).
///
/// The read side keeps separate rules (spv-understanding.md, "Balances"):
/// the read model's balances (`WalletProjection`) use the same buckets but
/// leave out UTXOs whose plugin metadata names a `pluginId`, and count
/// watch-only UTXOs; the coordinator's `BalanceResponse` counts payment
/// UTXOs (available, no `pluginId`, not watch-only) as confirmed when they
/// have a block height and reports watch-only funds apart;
/// `ReadModelStorage.getBalance` sums the payment UTXOs.
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

  /// Whether the wallet aggregate's coin selection may pick [utxo] from
  /// [state]: it is available (not pending, reserved, held by a deferred
  /// payment or spent), carries no plugin metadata (plugin-managed UTXOs
  /// such as tokens are spent by their plugin), and is not watch-only
  /// ([isWatchOnly]). Confirmations do not matter.
  ///
  /// Selection does not look at the script type: a bare multisig or P2PK
  /// UTXO the wallet can spend alone counts, although the paths that sign
  /// every input as P2PKH (channel funding, the payment coordinator) leave
  /// it out.
  static bool isSpendable(WalletState state, BitcoinUtxo utxo) =>
      utxo.status == UTXOStatus.available && !utxo.hasPluginMetadata && !isWatchOnly(state, utxo);

  /// Whether [utxo] is watch-only funds: attributed to the wallet through a
  /// watch address the wallet holds no key for (bead libspiffy-87a2). Such a
  /// UTXO is kept (with its transaction and proof) but never funds a
  /// transaction. A bare multisig UTXO over a watch address is not
  /// watch-only when the wallet's own keys meet its threshold.
  static bool isWatchOnly(WalletState state, BitcoinUtxo utxo) =>
      state.watchAddresses.isNotEmpty &&
      isWatchOnlyOutput(
        scriptHex: utxo.scriptPubKey,
        address: utxo.address,
        isWatchAddress: state.watchAddresses.containsKey,
        hasKeyFor: state.addresses.containsKey,
        network: NetworkName.toDartsv(state.networkType),
      );

  /// The total of [state]'s UTXOs that [isSpendable] accepts.
  static BigInt spendableTotal(WalletState state) {
    var total = BigInt.zero;
    for (final utxo in state.utxos.values) {
      if (isSpendable(state, utxo)) total += utxo.satoshis;
    }
    return total;
  }
}
