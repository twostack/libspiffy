/// HODLocker outputs: coins time-locked to a wallet key until a block height
/// (bead spiffyvault-mnz.1).
///
/// The HODLocker script (the hodlocker.com sCrypt contract, dartsv's
/// `HODLockerTemplate`) locks an output to the hash of one public key and a
/// block height. It is spent by `<signature> <public key> <preimage>`: the
/// contract reads the spending transaction from the preimage and requires
/// its nLockTime to be a block height of at least the lock height, with a
/// non-final input sequence, so the network's finality rule keeps the coin
/// where it is until that height.
///
/// Such an output is the wallet's when its key hash is a wallet address's,
/// as for P2PKH. It is recorded as plugin-managed ([metadata] names
/// [pluginId]), so it is never selected for a payment and never counted as
/// available or pending balance on either layer: it is locked balance.
library;

import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:hex/hex.dart';

import '../models/bitcoin_utxo.dart';

/// A HODLocker locking script: the owner's key hash and the lock height.
final class HodlockerLock {
  /// The `pluginId` a HODLocker UTXO's metadata names: what makes it
  /// plugin-managed ([BitcoinUtxo.isPluginManaged]) and how
  /// `getUtxosByPlugin` lists the wallet's locks.
  static const String pluginId = 'hodlocker';

  /// The script type, as dartsv names its template in lower case.
  static const String scriptType = 'hodlocker';

  /// The metadata key of the lock height.
  static const String lockHeightKey = 'lockHeight';

  /// The owner's public key hash, 20 bytes as hex.
  final String pubKeyHashHex;

  /// The block height from which the coin can be spent.
  final int lockHeight;

  const HodlockerLock(this.pubKeyHashHex, this.lockHeight);

  // The script is <three constants> 0 0 <key hash> <lock height> <code>:
  // everything but the key hash and the height is fixed.
  static const String _head =
      '2097dfd76851bf465e8f715593b217714858bbe9570ff3bd5e33840a34e20ff026'
      '2102ba79df5f8ae7604a9830f03c7933028186aede0675a16f025dc4f8be8eec0382'
      '201008ce7480da41702918d1ec8e6849ba32b4d65b1e40dc669c31a1e6306b266c'
      '0000'
      '14';

  /// The fixed code after the lock height, cut from a script dartsv builds.
  static final String _tail = () {
    const height = 0x7fffff; // a three-byte push
    final built = dartsv.HODLockerLockingScriptBuilder(List.filled(20, 0), BigInt.from(height))
        .getScriptPubkey()
        .toHex();
    return built.substring(_head.length + 40 + 8);
  }();

  /// Whether [scriptHex] begins as a HODLocker script does: the cheap test
  /// before [parseHex].
  static bool looksLike(String scriptHex) => scriptHex.toLowerCase().startsWith(_head);

  /// [scriptHex] as a HODLocker script, or null when it is not one.
  ///
  /// Every fixed byte is compared, not only the shape: dartsv's
  /// `ScriptPattern.isHODLocker` checks the lengths of the three leading
  /// constants, so a script that differs from the contract anywhere else
  /// would pass it.
  static HodlockerLock? parseHex(String scriptHex) {
    final script = scriptHex.toLowerCase();
    if (!script.startsWith(_head)) return null;
    var at = _head.length;
    if (script.length < at + 40 + 2) return null;
    final pubKeyHash = script.substring(at, at + 40);
    at += 40;
    final pushLength = int.tryParse(script.substring(at, at + 2), radix: 16);
    if (pushLength == null) return null;
    // Heights 1 to 16 are the opcodes OP_1 to OP_16, as a script number is
    // written minimally (a regtest chain's heights).
    if (pushLength >= 0x51 && pushLength <= 0x60) {
      if (script.substring(at + 2) != _tail) return null;
      return HodlockerLock(pubKeyHash, pushLength - 0x50);
    }
    if (pushLength < 1 || pushLength > 4) return null;
    at += 2;
    if (script.length < at + pushLength * 2) return null;
    final heightBytes = HEX.decode(script.substring(at, at + pushLength * 2));
    at += pushLength * 2;
    if (script.substring(at) != _tail) return null;
    // A script number: little-endian, minimally encoded, the top bit a sign.
    if (heightBytes.last & 0x80 != 0) return null;
    if (heightBytes.last == 0 && (heightBytes.length == 1 || heightBytes[heightBytes.length - 2] & 0x80 == 0)) {
      return null;
    }
    var height = 0;
    for (var i = heightBytes.length - 1; i >= 0; i--) {
      height = (height << 8) | heightBytes[i];
    }
    return HodlockerLock(pubKeyHash, height);
  }

  /// [script] as a HODLocker script, or null when it is not one.
  static HodlockerLock? parse(dartsv.SVScript script) => parseHex(script.toHex());

  /// The P2PKH address of the owner's key: how the wallet knows the key.
  String ownerAddress(dartsv.NetworkType network) =>
      dartsv.Address.fromPubkeyHash(pubKeyHashHex, network).toBase58();

  /// The plugin metadata a wallet's HODLocker UTXO is recorded with.
  Map<String, dynamic> metadata(dartsv.NetworkType network) => {
        'pluginId': pluginId,
        'scriptType': scriptType,
        lockHeightKey: lockHeight,
        'ownerAddress': ownerAddress(network),
      };

  /// Whether [utxo] is a HODLocker coin the wallet recorded with its lock.
  static bool isLockedCoin(BitcoinUtxo utxo) => utxo.pluginMetadata?['pluginId'] == pluginId;

  /// The value of the HODLocker coins among [utxos] that are not spent or
  /// voided, mined or not: the wallet's locked balance.
  static BigInt lockedSatoshis(Iterable<BitcoinUtxo> utxos) => utxos
      .where((u) => isLockedCoin(u) && u.status != UTXOStatus.spent && u.status != UTXOStatus.voided)
      .fold(BigInt.zero, (sum, u) => sum + u.satoshis);

  /// Whether a transaction with nLockTime [height] can spend the coin.
  bool isSpendableAt(int height) => height >= lockHeight;

  /// The signed size, in bytes, of the transaction that unlocks a coin
  /// locked by a script of [lockingScriptLength] bytes: the coin as its one
  /// input, unlocked with `<signature> <public key> <preimage>` at the
  /// signature's largest (73 bytes), and one P2PKH output. The preimage
  /// holds the whole locking script, so it is most of the size; an unlock
  /// costs that rate's fee on this size (bead spiffyvault-mnz.7).
  static int unlockSize(int lockingScriptLength) {
    // version, 1 input with an empty script, 1 P2PKH output, nLockTime
    const unsigned = 4 + 1 + (32 + 4 + 1 + 4) + 1 + (8 + 1 + 25) + 4;
    // BIP143: version, prevouts, sequences, outpoint, script code, amount,
    // sequence, outputs, nLockTime, sighash type
    final preimage = 4 + 32 + 32 + 36 + _varIntSize(lockingScriptLength) + lockingScriptLength + 8 + 4 + 32 + 4 + 4;
    final unlocking = (1 + 73) + (1 + 33) + _pushPrefix(preimage) + preimage;
    return unsigned + unlocking + _varIntSize(unlocking) - 1;
  }

  /// The bytes of the push opcode for [length] bytes of data.
  static int _pushPrefix(int length) => length < 0x4c ? 1 : length <= 0xff ? 2 : length <= 0xffff ? 3 : 5;

  /// The bytes of a Bitcoin varint holding [value].
  static int _varIntSize(int value) => value < 0xfd ? 1 : value <= 0xffff ? 3 : value <= 0xffffffff ? 5 : 9;

  @override
  bool operator ==(Object other) =>
      other is HodlockerLock && other.pubKeyHashHex == pubKeyHashHex && other.lockHeight == lockHeight;

  @override
  int get hashCode => Object.hash(pubKeyHashHex, lockHeight);

  @override
  String toString() => 'HodlockerLock($pubKeyHashHex until $lockHeight)';
}
