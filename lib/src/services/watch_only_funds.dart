/// Watch-only funds (bead libspiffy-87a2): wallet UTXOs at watch addresses.
///
/// A watch address is attributed to its wallet, so a payment to it is
/// recorded as a wallet UTXO (with its transaction and proof), but the wallet
/// holds no key for it. Such a UTXO is kept and reported, never selected to
/// fund a transaction and not counted as spendable balance.
library;

import 'package:dartsv/dartsv.dart' as dartsv;

import '../core/wallet_output_ownership.dart';
import '../models/bitcoin_utxo.dart';
import '../storage/read_model_storage.dart';
import '../utils/network_name.dart';

/// A wallet's UTXOs split into those it can sign for and watch-only ones.
class SignableUtxos {
  /// UTXOs the wallet holds the keys for, in their original order.
  final List<BitcoinUtxo> signable;

  /// UTXOs at watch addresses (see [isWatchOnlyOutput]), in their original
  /// order.
  final List<BitcoinUtxo> watchOnly;

  const SignableUtxos(this.signable, this.watchOnly);

  /// Total value of [watchOnly].
  BigInt get watchOnlySatoshis => watchOnly.fold(BigInt.zero, (sum, u) => sum + u.satoshis);

  /// ' (N satoshis in M UTXO(s) at watch addresses are watch-only: the
  /// wallet holds no key for them)', or '' when there are none. Appended to
  /// a funding failure so it names funds the wallet cannot spend.
  String get watchOnlyNote => watchOnly.isEmpty
      ? ''
      : ' ($watchOnlySatoshis satoshis in ${watchOnly.length} UTXO(s) at watch addresses '
          'are watch-only funds: the wallet holds no key for them)';
}

/// Splits [utxos], UTXOs of wallet [walletId] from [storage], into the ones
/// the wallet can sign for and the watch-only ones.
///
/// Watch addresses come from the read model's `watch` address rows. The row
/// is written from the wallet's WatchAddressAddedEvent, which precedes every
/// UTXO the wallet attributes to that address in the same journal, so a UTXO
/// row at a watch address never exists without its address row. Costs one
/// address query, plus one batch address check when a bare multisig UTXO
/// names a watch address.
Future<SignableUtxos> splitWatchOnlyUtxos(ReadModelStorage storage, String walletId, List<BitcoinUtxo> utxos) async {
  if (utxos.isEmpty) return const SignableUtxos([], []);
  final watch = {for (final row in await storage.getAddressesByPurpose(walletId, 'watch')) row.address};
  if (watch.isEmpty) return SignableUtxos(List.of(utxos), const []);

  // Wallet addresses named by multisig UTXOs that also name a watch address:
  // the only case that needs to know which other addresses hold keys.
  dartsv.NetworkType? network;
  final multisigKeyAddresses = <String>{};
  for (final utxo in utxos) {
    final multisig = BareMultisigScript.parseHex(utxo.scriptPubKey);
    if (multisig == null) continue;
    network ??= NetworkName.toDartsv(await _walletNetwork(storage, walletId));
    final addresses = multisig.keyAddresses(network).whereType<String>().toList();
    if (addresses.any(watch.contains)) multisigKeyAddresses.addAll(addresses.where((a) => !watch.contains(a)));
  }
  final keyed = multisigKeyAddresses.isEmpty
      ? const <String>{}
      : {
          for (final e in (await storage.checkAddresses(walletId, multisigKeyAddresses.toList())).entries)
            if (e.value) e.key,
        };

  final signable = <BitcoinUtxo>[];
  final watchOnly = <BitcoinUtxo>[];
  for (final utxo in utxos) {
    final isWatchOnly = isWatchOnlyOutput(
      scriptHex: utxo.scriptPubKey,
      address: utxo.address,
      isWatchAddress: watch.contains,
      hasKeyFor: (a) => !watch.contains(a) && keyed.contains(a),
      network: network ?? dartsv.NetworkType.TEST,
    );
    (isWatchOnly ? watchOnly : signable).add(utxo);
  }
  return SignableUtxos(signable, watchOnly);
}

Future<String?> _walletNetwork(ReadModelStorage storage, String walletId) async {
  final wallet = await storage.getWallet(walletId);
  return (wallet?['network'] ?? wallet?['networkType']) as String?;
}
