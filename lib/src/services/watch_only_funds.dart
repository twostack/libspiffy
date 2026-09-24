/// Watch-only funds: wallet UTXOs the wallet holds no key for. Either a
/// watch address received them (bead libspiffy-87a2), or they belong to a
/// watch-only (xpub) wallet, which holds no key at all (bead libspiffy-bfs1).
///
/// A watch address is attributed to its wallet, so a payment to it is
/// recorded as a wallet UTXO (with its transaction and proof), but the wallet
/// holds no key for it. An xpub wallet derives its addresses from the
/// payee's extended public key and records what they receive, for instance a
/// service taking payments for an offline payee (spv-understanding.md,
/// "Payment modes"). Such a UTXO is kept and reported, never selected to
/// fund a transaction and not counted as spendable balance.
library;

import '../core/wallet_output_ownership.dart';
import '../models/bitcoin_utxo.dart';
import '../models/wallet_type.dart';
import '../storage/read_model_storage.dart';
import '../utils/network_name.dart';

/// A wallet's UTXOs split into those it can sign for, watch-only ones, and
/// ones it cannot unlock alone.
class SignableUtxos {
  /// UTXOs the wallet can spend with its own keys, in their original order.
  final List<BitcoinUtxo> signable;

  /// Watch-only UTXOs ([BalanceUtxos.watchOnly]), in their original order.
  final List<BitcoinUtxo> watchOnly;

  /// UTXOs the wallet cannot unlock on its own
  /// ([BalanceUtxos.notSpendableAlone], bead libspiffy-wdch), in their
  /// original order.
  final List<BitcoinUtxo> notSpendableAlone;

  const SignableUtxos(this.signable, this.watchOnly, [this.notSpendableAlone = const []]);

  /// Total value of [watchOnly].
  BigInt get watchOnlySatoshis => watchOnly.fold(BigInt.zero, (sum, u) => sum + u.satoshis);

  /// ' (N satoshis in M UTXO(s) are watch-only funds: the wallet holds no
  /// key for them)', or '' when there are none. Appended to a funding
  /// failure so it names funds the wallet cannot spend.
  String get watchOnlyNote => watchOnly.isEmpty
      ? ''
      : ' ($watchOnlySatoshis satoshis in ${watchOnly.length} UTXO(s) '
          'are watch-only funds: the wallet holds no key for them)';

  /// [watchOnlyNote], followed by ' (N satoshis in M UTXO(s) need a
  /// signature the wallet does not hold)' when [notSpendableAlone] is not
  /// empty. Appended to a funding failure.
  String get excludedNote {
    if (notSpendableAlone.isEmpty) return watchOnlyNote;
    final sats = notSpendableAlone.fold(BigInt.zero, (sum, u) => sum + u.satoshis);
    return '$watchOnlyNote ($sats satoshis in ${notSpendableAlone.length} UTXO(s) '
        'need signatures the wallet does not hold: it cannot spend them alone)';
  }
}

/// Splits [utxos], UTXOs of wallet [walletId] from [storage], into the ones
/// the wallet can sign for, the watch-only ones and the ones it cannot
/// unlock alone: the read side's rule, [splitBalanceUtxos] (bead
/// libspiffy-wdch; before, a multisig UTXO the wallet cannot spend alone was
/// listed as signable, and a funding selection that picked it failed later).
Future<SignableUtxos> splitWatchOnlyUtxos(ReadModelStorage storage, String walletId, List<BitcoinUtxo> utxos) async {
  final split = await splitBalanceUtxos(storage, walletId, utxos);
  return SignableUtxos(split.spendable, split.watchOnly, split.notSpendableAlone);
}

/// A wallet's UTXOs as the read side's balances count them (beads
/// libspiffy-vsap, libspiffy-0k8, libspiffy-kfvv): spendable, watch-only,
/// and UTXOs the wallet cannot unlock alone.
class BalanceUtxos {
  /// UTXOs the wallet can spend with its own keys, in their original order.
  final List<BitcoinUtxo> spendable;

  /// UTXOs the wallet holds no key for: every UTXO of a watch-only (xpub)
  /// wallet (bead libspiffy-bfs1), and otherwise those for which a key they
  /// need is a watch address ([isWatchOnlyOutput]). In their original order.
  final List<BitcoinUtxo> watchOnly;

  /// UTXOs the wallet cannot build the whole unlocking script for
  /// ([unlocksAlone]) and that need no watch address: a bare multisig whose
  /// threshold its keys do not meet, recorded by a journal written before
  /// bead viy (a channel's 2-of-2 funding output, an escrow), or a P2PK
  /// output locked to a key that is not the wallet's (bead libspiffy-kfvv).
  /// Kept, and counted in no balance.
  final List<BitcoinUtxo> notSpendableAlone;

  const BalanceUtxos(this.spendable, this.watchOnly, this.notSpendableAlone);

  /// Total value of [spendable].
  BigInt get spendableSatoshis => _total(spendable);

  /// Total value of [watchOnly].
  BigInt get watchOnlySatoshis => _total(watchOnly);

  static BigInt _total(List<BitcoinUtxo> utxos) => utxos.fold(BigInt.zero, (sum, u) => sum + u.satoshis);
}

/// Splits [utxos], UTXOs of wallet [walletId] from [storage], the way every
/// read-side balance counts them ([BalanceUtxos]). The wallet aggregate's
/// rule is `WalletBalances.isSpendable`; spv-understanding.md, "Balances".
///
/// An xpub wallet's row names its type (`walletType`, written when the row
/// is created), and every UTXO of such a wallet is watch-only: the wallet
/// holds no private key. Watch addresses come from the read model's `watch`
/// address rows. The row is written from the wallet's WatchAddressAddedEvent,
/// which precedes every UTXO the wallet attributes to that address in the
/// same journal, so a UTXO row at a watch address never exists without its
/// address row. The keys the wallet holds come from its other address rows.
/// Costs one wallet read and one address query, plus one batch address check
/// when a bare multisig or P2PK UTXO is among [utxos]. Leaving out
/// plugin-managed UTXOs is the caller's part.
Future<BalanceUtxos> splitBalanceUtxos(ReadModelStorage storage, String walletId, List<BitcoinUtxo> utxos) async {
  if (utxos.isEmpty) return const BalanceUtxos([], [], []);
  final wallet = await storage.getWallet(walletId);
  if (wallet?['walletType'] == WalletType.xpub.toStorageString()) {
    return BalanceUtxos(const [], List.of(utxos), const []);
  }
  final network = NetworkName.toDartsv((wallet?['network'] ?? wallet?['networkType']) as String?);
  final watch = {for (final row in await storage.getAddressesByPurpose(walletId, 'watch')) row.address};

  // Every key address of a multisig UTXO and of a P2PK one: whether the
  // wallet can unlock the output alone depends on which of them are the
  // wallet's ([unlocksAlone], bead libspiffy-kfvv — the P2PK half used to be
  // asked on the write side only, by channel funding, so an output funding
  // refused to spend was counted here as spendable). A bare multisig script
  // ends with OP_CHECKMULTISIG and a P2PK one with OP_CHECKSIG, which P2PKH
  // is told apart from by its OP_DUP OP_HASH160 prefix; no other script is
  // parsed.
  var keyScripts = false;
  final keyAddresses = <String>{};
  for (final utxo in utxos) {
    final script = utxo.scriptPubKey.toLowerCase();
    final multisig = script.endsWith('ae') ? BareMultisigScript.parseHex(utxo.scriptPubKey) : null;
    if (multisig != null) {
      keyScripts = true;
      keyAddresses.addAll(multisig.keyAddresses(network).whereType<String>().where((a) => !watch.contains(a)));
      continue;
    }
    if (!script.endsWith('ac') || script.startsWith('76a914')) continue;
    keyScripts = true;
    // Both encodings of the key: the wallet may hold it under either
    // (bead libspiffy-abwk), and one batched lookup answers for both.
    keyAddresses.addAll(p2pkAddresses(utxo.scriptPubKey, network).where((a) => !watch.contains(a)));
  }
  if (watch.isEmpty && !keyScripts) return BalanceUtxos(List.of(utxos), const [], const []);
  final keyed = keyAddresses.isEmpty
      ? const <String>{}
      : {
          for (final e in (await storage.checkAddresses(walletId, keyAddresses.toList())).entries)
            if (e.value) e.key,
        };
  bool hasKeyFor(String address) => !watch.contains(address) && keyed.contains(address);

  final spendable = <BitcoinUtxo>[];
  final watchOnly = <BitcoinUtxo>[];
  final notSpendableAlone = <BitcoinUtxo>[];
  for (final utxo in utxos) {
    if (isWatchOnlyOutput(
      scriptHex: utxo.scriptPubKey,
      address: utxo.address,
      isWatchAddress: watch.contains,
      hasKeyFor: hasKeyFor,
      network: network,
    )) {
      watchOnly.add(utxo);
    } else if (!unlocksAlone(scriptHex: utxo.scriptPubKey, hasKeyFor: hasKeyFor, network: network)) {
      notSpendableAlone.add(utxo);
    } else {
      spendable.add(utxo);
    }
  }
  return BalanceUtxos(spendable, watchOnly, notSpendableAlone);
}
