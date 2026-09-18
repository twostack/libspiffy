import '../core/wallet_output_ownership.dart' show BareMultisigScript, isWatchOnlyOutput;
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
///   included), confirmed when a merkle proof put the UTXO's transaction in
///   a block on our own header chain (`blockHeight != null`), unconfirmed
///   otherwise (pending UTXOs included). They count every unspent UTXO the
///   state holds, plugin-managed and watch-only UTXOs included, so
///   confirmed + unconfirmed + reserved is everything the wallet holds.
///   These totals are journaled in snapshots.
/// * The spendable rule ([isSpendable], [spendableTotal]) says which UTXOs
///   the aggregate's coin selection may pick (`UtxoLedger.available`,
///   `BitcoinWalletAggregate.selectUTXOsForAmount`), and so what
///   [WalletState.availableBalance] and
///   `BitcoinWalletAggregate.hasSufficientBalance` count: status available,
///   not plugin-managed, not watch-only, not a bare multisig the wallet
///   cannot spend alone, not held by a legacy deferred payment, with any
///   number of confirmations. It is not derived from the buckets (bead
///   libspiffy-ad07: subtracting the reserved bucket from the other two
///   subtracted reserved UTXOs twice and counted pending, plugin-managed and
///   watch-only UTXOs).
///
/// The read side (spv-understanding.md, "Balances") leaves out the same
/// UTXOs from what it calls spendable: plugin-managed
/// ([BitcoinUtxo.isPluginManaged], the one rule for both layers, bead
/// libspiffy-ecy8), watch-only and multisig-not-spendable-alone UTXOs
/// (`splitBalanceUtxos`, bead libspiffy-vsap), and reports watch-only funds
/// apart. The read model's wallet row keeps the buckets' confirmed /
/// unconfirmed / reserved split over those UTXOs; the coordinator's
/// `BalanceResponse` and `ReadModelStorage.getBalance` count available
/// ones, `BalanceResponse` confirmed when mined.
abstract final class WalletBalances {
  /// The bucket [utxo] counts towards, or null when it counts towards none
  /// (spent, or voided): reserved when reserved, confirmed when
  /// [BitcoinUtxo.blockHeight] is set, unconfirmed otherwise.
  ///
  /// **Confirmed is a proven height and nothing else** (bead libspiffy-jc3h,
  /// spv-understanding.md "Balances"): the transaction is in a block whose
  /// header we hold on our active chain and we have the merkle proof that
  /// puts it there. A UTXO's `blockHeight` is exactly that evidence — it is
  /// written only by a confirmation verified against our own header chain
  /// (beads libspiffy-5ry, libspiffy-8oaq, libspiffy-4dja, libspiffy-pq8p)
  /// and `applyConfirmationReverted` takes it off again when the block
  /// leaves the active chain — so `blockHeight != null` is the confirmed
  /// test here and at every other layer.
  ///
  /// A confirmation *count* is deliberately not read. It is not evidence: it
  /// is a description of how deep a block now sits, stale at the next block,
  /// derivable as `tip height - blockHeight + 1`, and a caller can assert
  /// one without holding any proof. There is deliberately no
  /// six-confirmation threshold either (the rule this replaced): a proof on
  /// our active chain confirms at depth one exactly as it does at depth six,
  /// and a wallet that waits for depth is making a policy choice that
  /// belongs to the application, not to this library.
  ///
  /// A voided output ([UTXOStatus.voided], bead libspiffy-3arz) is the output
  /// of a transaction the network will not settle — a cancelled, failed or
  /// reclaimed deferred payment. The row is kept, but it is not money on the
  /// way, so it counts nowhere; it counted as unconfirmed balance for as long
  /// as it sat at pending.
  static BalanceBucket? bucketOf(BitcoinUtxo utxo) {
    if (utxo.status == UTXOStatus.spent || utxo.status == UTXOStatus.voided) return null;
    if (utxo.status == UTXOStatus.reserved) return BalanceBucket.reserved;
    if (utxo.blockHeight != null) return BalanceBucket.confirmed;
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
  /// payment or spent), is not plugin-managed ([BitcoinUtxo.isPluginManaged]:
  /// its plugin metadata names a `pluginId`; such UTXOs, e.g. tokens or
  /// funding earmarks, are spent by their plugin), is not watch-only
  /// ([isWatchOnly]), is not a bare multisig UTXO the wallet cannot spend
  /// alone ([cannotSpendAlone]), and is not held by a deferred payment
  /// recorded before holds were journaled
  /// ([WalletState.legacyDeferredHeldKeys], bead libspiffy-8j9w: such an
  /// input is available in the state until `ReconcileDeferredSpendsCommand`
  /// journals its hold). Confirmations do not matter.
  ///
  /// Selection does not otherwise look at the script type: a bare multisig
  /// or P2PK UTXO the wallet can spend alone counts, although the paths that
  /// sign every input as P2PKH (channel funding, the payment coordinator)
  /// leave it out.
  static bool isSpendable(WalletState state, BitcoinUtxo utxo) =>
      utxo.status == UTXOStatus.available &&
      !utxo.isPluginManaged &&
      !isWatchOnly(state, utxo) &&
      !cannotSpendAlone(state, utxo) &&
      !state.legacyDeferredHeldKeys.contains(utxo.key);

  /// Whether [utxo] is a bare multisig UTXO whose threshold the wallet's own
  /// keys ([WalletState.addresses]) do not meet (bead libspiffy-0k8).
  ///
  /// The wallet no longer takes such an output as a UTXO (beads viy, n0p),
  /// but a journal written before can hold one (a channel's 2-of-2 funding
  /// output recorded from the funding transaction, an escrow under a
  /// `p2ms:` pseudo-address). Replay keeps it, with its transaction and
  /// proof, and it never funds a transaction. Derived from the state, so
  /// replay, a snapshot restore and a later key the wallet derives all give
  /// the same answer with no corrective event. A bare multisig over a watch
  /// address is judged by [isWatchOnly] first on the read side; here both
  /// exclude it.
  static bool cannotSpendAlone(WalletState state, BitcoinUtxo utxo) {
    // Every bare multisig script ends with OP_CHECKMULTISIG: no parse for
    // any other UTXO.
    if (!utxo.scriptPubKey.toLowerCase().endsWith('ae')) return false;
    final multisig = BareMultisigScript.parseHex(utxo.scriptPubKey);
    return multisig != null &&
        multisig.spendableAloneBy(state.addresses.containsKey, NetworkName.toDartsv(state.networkType)) == null;
  }

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
