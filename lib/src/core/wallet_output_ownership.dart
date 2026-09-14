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
