/// Which transaction outputs are the wallet's own UTXOs (bead libspiffy-viy).
///
/// A wallet UTXO is an output the wallet can spend with its own signatures.
/// For P2PKH and P2PK that is an output locked to a wallet key. A bare
/// multisig output (`OP_m <key>... OP_n OP_CHECKMULTISIG`) is the wallet's
/// only when the wallet holds at least m of its keys: a payment channel's
/// 2-of-2 funding output holds one wallet key but also needs the other
/// party's signature, so it is not spendable balance.
library;

import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:hex/hex.dart';

/// A bare multisig locking script.
class BareMultisigScript {
  /// Signatures the script requires (m).
  final int threshold;

  /// The script's public keys (n of them), in script order, as hex.
  final List<String> publicKeysHex;

  const BareMultisigScript._(this.threshold, this.publicKeysHex);

  /// [script] as a bare multisig script, or null when it is not one
  /// (malformed ones included).
  static BareMultisigScript? parse(dartsv.SVScript script) {
    final chunks = script.chunks;
    if (chunks.length < 4) return null;
    if (chunks.last.opcodenum != dartsv.OpCodes.OP_CHECKMULTISIG) return null;
    final m = _smallInt(chunks.first);
    final n = _smallInt(chunks[chunks.length - 2]);
    if (m == null || n == null || m > n || chunks.length != n + 3) return null;
    final keys = <String>[];
    for (var i = 1; i <= n; i++) {
      final buf = chunks[i].buf;
      if (buf == null || (buf.length != 33 && buf.length != 65)) return null;
      keys.add(HEX.encode(buf));
    }
    return BareMultisigScript._(m, keys);
  }

  /// [scriptHex] as a bare multisig script, or null when it is not one or
  /// is not valid hex.
  static BareMultisigScript? parseHex(String scriptHex) {
    if (scriptHex.isEmpty) return null;
    try {
      return parse(dartsv.SVScript.fromHex(scriptHex));
    } catch (_) {
      return null;
    }
  }

  static int? _smallInt(dartsv.ScriptChunk chunk) {
    final op = chunk.opcodenum;
    if (op >= dartsv.OpCodes.OP_1 && op <= dartsv.OpCodes.OP_16) {
      return op - dartsv.OpCodes.OP_1 + 1;
    }
    return null;
  }

  /// The address (on [network]) of each key, in script order; null for a
  /// key that does not parse.
  List<String?> keyAddresses(dartsv.NetworkType network) => [
        for (final keyHex in publicKeysHex)
          () {
            try {
              return dartsv.Address.fromPublicKey(dartsv.SVPublicKey.fromHex(keyHex), network)
                  .toBase58();
            } catch (_) {
              return null;
            }
          }(),
      ];

  /// The wallet address the output is attributed to when the wallet can
  /// spend it alone: the address of the first wallet key in the script,
  /// provided at least [threshold] of the script's key positions hold a
  /// wallet key (a key listed twice can sign for both positions). Null when
  /// the wallet cannot spend the output without someone else's signature.
  String? spendableAloneBy(bool Function(String address) isWalletAddress, dartsv.NetworkType network) {
    String? first;
    var held = 0;
    for (final address in keyAddresses(network)) {
      if (address == null || !isWalletAddress(address)) continue;
      first ??= address;
      held++;
    }
    return held >= threshold ? first : null;
  }
}

/// The public key of the P2PK script (`<key> OP_CHECKSIG`) [scriptHex] locks
/// with, as hex, or null when it is not one (malformed ones included).
String? p2pkPublicKeyHex(String scriptHex) {
  if (scriptHex.isEmpty) return null;
  try {
    final chunks = dartsv.SVScript.fromHex(scriptHex).chunks;
    if (chunks.length != 2) return null;
    if (chunks.last.opcodenum != dartsv.OpCodes.OP_CHECKSIG) return null;
    final key = chunks.first.buf;
    if (key == null || (key.length != 33 && key.length != 65)) return null;
    return HEX.encode(key);
  } catch (_) {
    return null;
  }
}

/// The address (on [network]) of the key a P2PK script locks to, or null when
/// [scriptHex] is not a P2PK script or its key does not parse.
String? p2pkAddress(String scriptHex, dartsv.NetworkType network) {
  final keyHex = p2pkPublicKeyHex(scriptHex);
  if (keyHex == null) return null;
  try {
    return dartsv.Address.fromPublicKey(dartsv.SVPublicKey.fromHex(keyHex), network).toBase58();
  } catch (_) {
    return null;
  }
}

/// Whether [scriptHex] locks an output that a P2PKH unlocking script cannot
/// spend although it can be a wallet UTXO: a bare multisig script or a P2PK
/// script (`<key> OP_CHECKSIG`).
///
/// The wallet signs such outputs with their own unlocking scripts wherever it
/// builds the whole transaction itself ([WalletTransactionSigner.unlockFor]:
/// `SignTransactionCommand` and channel funding, bead libspiffy-8egy). It
/// still selects them out where a third-party `TransactionBuilderPlugin`
/// builds the input — the plugin gets one public key per funding UTXO and
/// unlocks it as P2PKH, and libspiffy cannot make it emit any other
/// unlocking script (bead libspiffy-nlp).
bool needsNonP2pkhUnlock(String scriptHex) =>
    BareMultisigScript.parseHex(scriptHex) != null || p2pkPublicKeyHex(scriptHex) != null;

/// Whether the wallet cannot sign for the output locked by [scriptHex] and
/// attributed to [address] because the key it needs belongs to a watch
/// address (bead libspiffy-87a2): watch-only funds.
///
/// A watch address is attributed to the wallet (it is credited with the
/// payments it receives) but the wallet holds no key for it.
/// [isWatchAddress] names the wallet's watch addresses and [hasKeyFor] the
/// addresses the wallet derives keys for.
///
/// * A bare multisig output is watch-only when at least one of its keys is a
///   watch address and the keys the wallet holds do not meet the threshold. The address it is attributed to does not
///   matter: a 1-of-2 over a watch address and a wallet key is attributed
///   to the watch address when that key comes first, yet the wallet signs
///   it alone.
/// * Any other output is watch-only when [address] is a watch address the
///   wallet has no key for.
bool isWatchOnlyOutput({
  required String scriptHex,
  required String address,
  required bool Function(String address) isWatchAddress,
  required bool Function(String address) hasKeyFor,
  required dartsv.NetworkType network,
}) {
  final multisig = BareMultisigScript.parseHex(scriptHex);
  if (multisig != null) {
    final keyAddresses = multisig.keyAddresses(network);
    if (!keyAddresses.any((a) => a != null && isWatchAddress(a))) return false;
    return multisig.spendableAloneBy(hasKeyFor, network) == null;
  }
  return isWatchAddress(address) && !hasKeyFor(address);
}
