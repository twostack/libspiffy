/// The size of a transaction the wallet signs, known before it is signed
/// (bead libspiffy-bg7n).
library;

import '../wallet_output_ownership.dart';

/// Bytes of a signed transaction, from the locking scripts of the outputs it
/// spends and the locking scripts of the outputs it creates.
///
/// A fee is ARC's policy rate (`FeeRate`) on the size of the transaction the
/// network is given, which is the signed one, and the wallet has to know it
/// before signing: the fee decides the change output, which is part of what
/// is signed. dartsv's own estimate (`TransactionBuilder.withFeePerKb`)
/// counts each input's unlocking script as it is before signing — empty —
/// and leaves out every input's outpoint and sequence number, so a payment
/// paid 6 satoshis whatever its size. Here each input is sized by the
/// unlocking script the wallet writes for it
/// (`WalletTransactionSigner.unlockFor`, the one place that decides it):
///
/// * P2PKH: `<sig> <compressed key>`;
/// * P2PK: `<sig>`;
/// * an m-of-n bare multisig: `OP_0 <sig>...`, m signatures.
///
/// A signature is counted at its largest (a 71-byte low-S DER signature and
/// its sighash byte, pushed), so the estimate may exceed the signed size by
/// a byte or two per signature and never falls short of it.
abstract final class TransactionSize {
  /// Version and lock time.
  static const _versionAndLockTime = 4 + 4;

  /// The 36-byte outpoint and 4-byte sequence number every input carries.
  static const _outpointAndSequence = 36 + 4;

  /// One signature in an unlocking script: its push opcode, a DER signature
  /// of at most 71 bytes (low S) and the sighash byte.
  static const _signaturePush = 1 + 71 + 1;

  /// A compressed public key, pushed.
  static const _compressedKeyPush = 1 + 33;

  /// A P2PKH locking script: `OP_DUP OP_HASH160 <20 bytes> OP_EQUALVERIFY
  /// OP_CHECKSIG`, the change output every wallet transaction pays back to.
  static const p2pkhScriptBytes = 25;

  /// The bytes of the unlocking script the wallet writes to spend an output
  /// locked by [lockingScriptHex]. Throws [ArgumentError] for a locking
  /// script the wallet has no standard unlocking script for — no wallet
  /// transaction spends one, and there is no size to guess for it.
  static int unlockingScript(String lockingScriptHex) {
    final multisig = BareMultisigScript.parseHex(lockingScriptHex);
    if (multisig != null) return 1 + multisig.threshold * _signaturePush;
    if (p2pkPublicKeyHex(lockingScriptHex) != null) return _signaturePush;
    if (isP2pkhScript(lockingScriptHex)) return _signaturePush + _compressedKeyPush;
    throw ArgumentError.value(lockingScriptHex, 'lockingScriptHex',
        'not a P2PKH, P2PK or bare multisig script: the wallet writes no unlocking script for it');
  }

  /// The bytes a signed input spending an output locked by
  /// [lockingScriptHex] adds to a transaction.
  static int input(String lockingScriptHex) {
    final unlocking = unlockingScript(lockingScriptHex);
    return _outpointAndSequence + varIntSize(unlocking) + unlocking;
  }

  /// The bytes an output whose locking script is [scriptBytes] long adds: the
  /// 8-byte amount, the script's length and the script.
  static int output(int scriptBytes) => 8 + varIntSize(scriptBytes) + scriptBytes;

  /// The signed size of a transaction spending outputs locked by
  /// [inputLockingScripts] and creating outputs whose locking scripts are
  /// [outputScriptBytes] long.
  static int of({required Iterable<String> inputLockingScripts, required Iterable<int> outputScriptBytes}) =>
      _versionAndLockTime +
      varIntSize(inputLockingScripts.length) +
      inputLockingScripts.fold<int>(0, (sum, script) => sum + input(script)) +
      varIntSize(outputScriptBytes.length) +
      outputScriptBytes.fold<int>(0, (sum, bytes) => sum + output(bytes));

  /// The bytes of a Bitcoin variable-length integer holding [n].
  static int varIntSize(int n) => n < 0xfd
      ? 1
      : n <= 0xffff
          ? 3
          : n <= 0xffffffff
              ? 5
              : 9;
}
