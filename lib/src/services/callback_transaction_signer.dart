import 'dart:typed_data';

import 'package:dartsv/dartsv.dart';
import 'package:hex/hex.dart';

/// A synchronous function that signs a sighash and returns a DER-encoded signature.
///
/// The sighash is the double-SHA256 hash of the transaction preimage for a
/// specific input. The returned bytes must be a valid DER-encoded ECDSA
/// signature (without the sighash type byte — that is appended by the caller).
///
/// This function executes within the secure context that holds the private key.
/// The key never crosses this boundary. Must be synchronous because dartsv's
/// TransactionBuilder.build() is synchronous.
typedef SigningCallback = Uint8List Function(Uint8List sighash, int inputIndex);

/// A [TransactionSigner] that delegates ECDSA signing to a callback.
///
/// The private key never leaves the secure context. The coordinator retrieves
/// the key from SecureStorage, creates a closure that signs with it, and
/// passes this signer to plugins. The plugin calls [sign] which invokes the
/// closure — but cannot access the key itself.
///
/// ```dart
/// // Coordinator retrieves key from SecureStorage, creates closure:
/// final privateKey = SVPrivateKey.fromWIF(await secureStorage.getWIF(walletId));
/// final signer = CallbackTransactionSigner(
///   sigHashType: SighashType.SIGHASH_ALL.value | SighashType.SIGHASH_FORKID.value,
///   onSign: (sighash, inputIndex) {
///     final sig = SVSignature.fromPrivateKey(privateKey);
///     sig.nhashtype = sigHashType;
///     sig.sign(HEX.encode(sighash));
///     return Uint8List.fromList(sig.toDER());
///   },
/// );
/// // Plugin receives signer — can sign, cannot extract key
/// plugin.buildTransaction(PluginTransactionRequest(signer: signer, ...));
/// ```
class CallbackTransactionSigner extends TransactionSigner {
  @override
  final int sigHashType;
  final SigningCallback _onSign;

  CallbackTransactionSigner({
    required this.sigHashType,
    required SigningCallback onSign,
  }) : _onSign = onSign;

  @override
  Transaction sign(Transaction unsignedTxn, TransactionOutput utxo, int inputIndex) {
    SVScript subscript = utxo.script;
    var sigHash = Sighash();

    var hash = sigHash.hash(unsignedTxn, sigHashType, inputIndex, subscript, utxo.satoshis);
    var hashBytes = Uint8List.fromList(HEX.decode(hash).reversed.toList());

    // Delegate signing to the callback
    var derBytes = _onSign(hashBytes, inputIndex);

    var sig = SVSignature.fromDER(HEX.encode(derBytes));
    sig.nhashtype = sigHashType;

    TransactionInput input = unsignedTxn.inputs[inputIndex];
    if (input != null) {
      UnlockingScriptBuilder scriptBuilder = input.scriptBuilder!;
      scriptBuilder.signatures.add(sig);
    } else {
      throw TransactionException(
          "Trying to sign a Transaction Input that is missing a SignedUnlockBuilder");
    }

    return unsignedTxn;
  }

  @override
  SVSignature signPreimage(Uint8List preImage) {
    var sighash = Uint8List.fromList(sha256Twice(preImage.toList()));
    var derBytes = _onSign(sighash, -1);
    var sig = SVSignature.fromDER(HEX.encode(derBytes));
    sig.nhashtype = sigHashType;
    return sig;
  }
}
