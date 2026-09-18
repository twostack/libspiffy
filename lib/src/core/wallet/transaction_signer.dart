/// Signing with the wallet's keys: transactions spending wallet UTXOs (P2PKH,
/// P2PK and bare multisig), one input of a payment channel's multisig
/// transaction, and a single input against a caller-supplied subscript (bead
/// libspiffy-dp4; part of `BitcoinWalletAggregate`).
library;

import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:dartsv/dartsv.dart' as dartsv;

import '../../models/bitcoin_utxo.dart';
import '../../models/wallet_state.dart';
import '../../models/wallet_type.dart';
import '../../services/script_type_registry.dart';
import '../../utils/network_name.dart';
import '../wallet_commands.dart';
import '../wallet_output_ownership.dart';
import 'utxo_ledger.dart';
import 'wallet_keys.dart';

/// The signature a [SignMultisigTransactionCommand] asks for.
typedef MultisigInputSignature = ({String txid, String txHex, String signatureHex});

/// The signature a [SignInputCommand] asks for, and the public key that
/// verifies it.
typedef InputSignature = ({String signatureHex, String publicKeyHex});

/// How the wallet unlocks one of its own UTXOs: the unlocking-script builder
/// the input carries and the private keys whose signatures it needs, in the
/// order the locking script expects them.
///
/// One signature for P2PKH and P2PK; `threshold` of them, in script key
/// order, for a bare multisig output the wallet can spend alone.
typedef WalletInputUnlock = ({
  dartsv.UnlockingScriptBuilder unlocker,
  List<dartsv.SVPrivateKey> signingKeys,
});

/// Signs with one wallet's keys. Replies and journaling stay with the
/// aggregate; every method here throws on refusal, with the aggregate's
/// error texts.
class WalletTransactionSigner {
  final WalletKeys keys;

  WalletTransactionSigner(this.keys);

  static final int _sighashAllForkId = dartsv.SighashType.SIGHASH_ALL.value | dartsv.SighashType.SIGHASH_FORKID.value;

  /// [SignTransactionCommand.rawTransaction] with the input spending each of
  /// [SignTransactionCommand.utxoKeys] signed (input i spends key i), each
  /// checked against its UTXO's script with the script interpreter.
  Future<dartsv.Transaction> signTransaction(WalletState currentState, SignTransactionCommand command) async {
    dartsv.Transaction? signedTx;

    // Business rule: Wallet must exist
    if (!currentState.isCreated) {
      throw StateError('Cannot sign transaction for non-existent wallet');
    }

    // Business rule: Watch-only wallets cannot sign
    if (currentState.walletType == WalletType.xpub) {
      throw StateError('Signing not supported for watch-only wallets');
    }

    // Parse unsigned transaction
    final unsignedTx = dartsv.Transaction.fromHex(command.rawTransaction);

    // For each UTXO being spent, sign the corresponding input
    for (int i = 0; i < command.utxoKeys.length; i++) {
      final utxoKey = command.utxoKeys[i];

      // Get UTXO details from state
      final utxo = currentState.utxos[utxoKey];
      if (utxo == null) {
        throw StateError('UTXO $utxoKey not found in wallet state');
      }

      // Watch-only funds (bead libspiffy-87a2): no key to derive. Before,
      // the key at the caller's derivation index (m/0/0 for a watch
      // address row) signed the input and the interpreter refused it.
      if (UtxoLedger.isWatchOnly(currentState, utxo)) {
        throw StateError('Cannot sign UTXO $utxoKey: it is at watch address ${utxo.address}, '
            'which the wallet holds no key for (watch-only funds)');
      }

      // Create TransactionOutput for the UTXO being spent
      final utxoScript = dartsv.SVScript.fromHex(utxo.scriptPubKey);
      final utxoOutput = dartsv.TransactionOutput(
        utxo.value.getValue(),
        utxoScript,
      );

      // Get private key for this UTXO's address
      // Use command-provided derivation index if available (from read model)
      final cmdDerivationIndex = (i < command.derivationIndices.length) ? command.derivationIndices[i] : null;
      // Chain flag is optional: absent means "resolve from aggregate state".
      final cmdIsChange = (i < command.isChangeFlags.length) ? command.isChangeFlags[i] : null;

      final sighashType = _sighashAllForkId;
      final unlock = await unlockFor(
        currentState,
        command.walletId,
        utxo,
        utxoKey: utxoKey,
        derivationIndex: cmdDerivationIndex,
        isChange: cmdIsChange,
      );
      if (unlock == null) {
        // A script type the wallet has no standard unlocking script for: sign
        // with the key at the UTXO's address and let the interpreter judge.
        final privateKey = await keys.privateKeyForAddress(
          utxo.address,
          command.walletId,
          currentState,
          derivationIndex: cmdDerivationIndex,
          isChange: cmdIsChange,
        );
        signedTx = dartsv.DefaultTransactionSigner(sighashType, privateKey).sign(unsignedTx, utxoOutput, i);
      } else {
        //overwrite the input with our defined unlocking script builder
        unsignedTx.inputs[i] = dartsv.TransactionInput(
          utxo.txid,
          utxo.vout,
          dartsv.TransactionInput.MAX_SEQ_NUMBER,
          scriptBuilder: unlock.unlocker,
        );
        for (final key in unlock.signingKeys) {
          dartsv.DefaultTransactionSigner(sighashType, key).sign(unsignedTx, utxoOutput, i);
        }
        signedTx = unsignedTx;
      }

      //perform a sanity check to see if we're correctly spending the utxo
      var scriptFlags = <dartsv.VerifyFlag>{}
        ..addAll([dartsv.VerifyFlag.SIGHASH_FORKID, dartsv.VerifyFlag.UTXO_AFTER_GENESIS]);
      final interpreter = dartsv.Interpreter();
      // Verify the input we just signed. With SIGHASH_FORKID the signature
      // commits to this input's own subscript and amount, so checking
      // input 0 against every UTXO (the previous behaviour) rejected any
      // multi-input transaction whose inputs differ in script or amount.
      final inputIndex = i;
      final scriptSig = signedTx.inputs[inputIndex].script;

      //run the input(s) through the interpreter to verify it
      interpreter.correctlySpends(
          scriptSig!, utxoScript, signedTx, inputIndex, scriptFlags, dartsv.Coin.ofSat(utxo.satoshis));
    }

    if (signedTx == null) {
      throw Exception("Failed to sign transaction");
    }
    return signedTx;
  }

  /// The unlocking script and the signing keys for [utxo], one of the
  /// wallet's own UTXOs, or null when its locking script is not one the
  /// wallet has a standard unlocking script for.
  ///
  /// The one place that decides how the wallet spends its own output (bead
  /// libspiffy-8egy). Both paths that build a whole transaction with the
  /// wallet's keys use it — [signTransaction] and `ChannelFunding.build` —
  /// so a bare multisig or P2PK wallet UTXO is spendable by either:
  ///
  /// * P2PKH: `<sig> <key>`, the key at the UTXO's address, which must be the
  ///   one the script locks to ([requireKeyForP2pkh]).
  /// * bare multisig the wallet can spend alone (beads viy, n0p):
  ///   `OP_0 <sig>...`, one signature per required key, in script key order
  ///   ([_multisigSigningKeys]).
  /// * P2PK: `<sig>` alone ([SignatureOnlyUnlockBuilder]; dartsv's
  ///   `P2PKUnlockBuilder` adds the public key as well, which no node
  ///   accepts).
  ///
  /// [utxoKey] names the UTXO in error texts (defaults to [BitcoinUtxo.key]).
  Future<WalletInputUnlock?> unlockFor(
    WalletState currentState,
    String walletId,
    BitcoinUtxo utxo, {
    String? utxoKey,
    int? derivationIndex,
    bool? isChange,
  }) async {
    // ScriptTypeRegistry is a singleton pinned to the first network it
    // is built with; the default (testnet) threw for mainnet wallets
    // once output scanning had initialised it for mainnet.
    final registry = ScriptTypeRegistry(
      networkType: NetworkName.toDartsv(currentState.networkType),
    );
    final utxoScript = dartsv.SVScript.fromHex(utxo.scriptPubKey);
    final scriptType = registry.identifyScriptType(utxoScript)?.toLowerCase();
    final multisig = scriptType == 'p2ms' ? BareMultisigScript.parse(utxoScript) : null;

    // A multisig UTXO may be attributed to a watch address among its
    // keys; its signing keys are then all resolved from the wallet's own
    // address records (see _multisigSigningKeys).
    final privateKey = multisig != null && !currentState.addresses.containsKey(utxo.address)
        ? null
        : await keys.privateKeyForAddress(
            utxo.address,
            walletId,
            currentState,
            derivationIndex: derivationIndex,
            isChange: isChange,
          );

    if (multisig != null) {
      return (
        unlocker: dartsv.P2MSUnlockBuilder(),
        signingKeys: await _multisigSigningKeys(multisig, utxo, walletId, currentState, privateKey),
      );
    }
    if (scriptType == 'p2pk') {
      return (unlocker: SignatureOnlyUnlockBuilder(), signingKeys: [privateKey!]);
    }
    if (scriptType == 'p2pkh') {
      final publicKey = privateKey!.publicKey;
      requireKeyForP2pkh(utxoKey ?? utxo.key, utxo.address, utxoScript, publicKey);
      return (unlocker: dartsv.P2PKHUnlockBuilder(publicKey), signingKeys: [privateKey]);
    }
    return null;
  }

  /// The wallet keys that sign [utxo], a bare [multisig] output: the first
  /// `threshold` script key positions holding a wallet key, in script order
  /// (a key listed twice signs for both positions). [utxoAddressKey] is the
  /// key already resolved for the UTXO's attributed address (null when that
  /// address is not one the wallet derives keys for, e.g. a watch address);
  /// every other key comes from the aggregate's own address records. Throws
  /// when the wallet holds fewer than `threshold` of the keys.
  Future<List<dartsv.SVPrivateKey>> _multisigSigningKeys(BareMultisigScript multisig, BitcoinUtxo utxo,
      String walletId, WalletState currentState, dartsv.SVPrivateKey? utxoAddressKey) async {
    final network = NetworkName.toDartsv(currentState.networkType);
    final addresses = multisig.keyAddresses(network);
    final signingKeys = <dartsv.SVPrivateKey>[];
    for (var j = 0; j < addresses.length && signingKeys.length < multisig.threshold; j++) {
      final address = addresses[j];
      if (address == null || !currentState.addresses.containsKey(address)) continue;
      final key = address == utxo.address && utxoAddressKey != null
          ? utxoAddressKey
          : await keys.privateKeyForAddress(address, walletId, currentState);
      if (key.publicKey.toHex().toLowerCase() != multisig.publicKeysHex[j].toLowerCase()) {
        throw StateError('The wallet key for $address does not match key ${j + 1} of multisig UTXO ${utxo.key}');
      }
      signingKeys.add(key);
    }
    if (signingKeys.length < multisig.threshold) {
      throw StateError('UTXO ${utxo.key} is a ${multisig.threshold}-of-${addresses.length} multisig output; '
          'the wallet holds ${signingKeys.length} of the keys it needs');
    }
    return signingKeys;
  }

  /// Throws unless [publicKey] (compressed or not) hashes to the key hash
  /// [p2pkhScript] locks to: the key resolved for [address] is not the one
  /// that controls the UTXO, so the wallet holds no key for it.
  static void requireKeyForP2pkh(
      String utxoKey, String address, dartsv.SVScript p2pkhScript, dartsv.SVPublicKey publicKey) {
    final chunks = p2pkhScript.chunks;
    final lockedHash = chunks.length == 5 ? chunks[2].buf : null;
    if (lockedHash == null) return; // Not a standard P2PKH script; the interpreter checks the spend.
    final locked = hex.encode(lockedHash);
    bool hashesTo(bool compressed) =>
        hex.encode(dartsv.hash160(hex.decode(publicKey.getEncoded(compressed)))) == locked;
    if (!hashesTo(true) && !hashesTo(false)) {
      throw StateError('Cannot sign UTXO $utxoKey at $address: the wallet holds no key for it '
          '(the key derived for $address does not control its script)');
    }
  }

  /// Our signature for one input of a payment channel's 2-of-2 multisig
  /// transaction, with the transaction as given (the channel coordinator
  /// applies the signatures).
  ///
  /// Uses dartsv's TransactionSigner which correctly handles sighash
  /// computation and ECDSA signing for multisig transactions.
  Future<MultisigInputSignature> signMultisigInput(
      WalletState currentState, SignMultisigTransactionCommand command) async {
    // Business rule: Wallet must exist
    if (!currentState.isCreated) {
      throw StateError('Cannot sign multisig transaction for non-existent wallet');
    }

    // Business rule: Watch-only wallets cannot sign
    if (currentState.walletType == WalletType.xpub) {
      throw StateError('Signing not supported for watch-only wallets');
    }

    // Parse the transaction to sign
    final txToSign = dartsv.Transaction.fromHex(command.rawTransaction);

    // Get private key at the specified derivation index and chain
    final privateKey = await keys.privateKeyAtIndex(
      command.walletId,
      command.derivationIndex,
      currentState,
      isChange: command.isChange,
    );

    // Parse the redeem script (2-of-2 multisig locking script)
    final redeemScript = dartsv.SVScript.fromHex(command.redeemScriptHex);

    // Create the UTXO that we're spending from (multisig output)
    final utxo = dartsv.TransactionOutput(
      BigInt.from(command.prevOutValue),
      redeemScript,
    );

    // IMPORTANT: Replace the input with one that has a P2MSUnlockBuilder
    // The default parser creates a DefaultUnlockBuilder which doesn't properly
    // build multisig scriptSigs from signatures.
    // (This is what TransactionBuilder.spendFromUtxoMap() does internally)
    final unlockBuilder = dartsv.P2MSUnlockBuilder();
    final originalInput = txToSign.inputs[command.inputIndex];
    final newInput = dartsv.TransactionInput(
      originalInput.prevTxnId,
      originalInput.prevTxnOutputIndex,
      originalInput.sequenceNumber,
      scriptBuilder: unlockBuilder,
    );
    txToSign.inputs[command.inputIndex] = newInput;

    // Use TransactionSigner - this handles sighash computation and signing correctly
    // This is the same method used in dartsv's multisig tests
    final signer = dartsv.DefaultTransactionSigner(command.sighashType, privateKey);
    signer.sign(txToSign, utxo, command.inputIndex); // Signature added to unlockBuilder

    // Extract our signature from the unlock builder (TransactionSigner added it there)
    if (unlockBuilder.signatures.isEmpty) {
      throw StateError('No signature added by TransactionSigner');
    }

    final ourSignature = unlockBuilder.signatures.last;
    final signatureHex = ourSignature.toTxFormat();

    // NOTE: Individual signature verification is not possible here because:
    // - The signature is created for a 2-of-2 multisig (sighash includes full redeem script)
    // - A 1-of-1 test would use a different sighash and always fail
    // The full 2-of-2 verification happens in PaymentChannelCoordinator after both signatures
    // are combined using Interpreter.correctlySpends()

    // Return the unsigned transaction hex (coordinator applies signatures)
    final txHex = dartsv.Transaction.fromHex(command.rawTransaction).serialize();
    final txid = dartsv.Transaction.fromHex(command.rawTransaction).id;
    return (txid: txid, txHex: txHex, signatureHex: signatureHex);
  }

  /// Signs one input of [SignInputCommand.rawTransaction] against a
  /// caller-supplied subscript and amount with the key at an explicit path:
  /// the per-input signing primitive for plugin-built transactions
  /// (AggregateSigningClient).
  Future<InputSignature> signInput(WalletState currentState, SignInputCommand command) async {
    if (!currentState.isCreated) {
      throw StateError('Cannot sign an input for non-existent wallet ${command.walletId}');
    }
    if (currentState.walletType == WalletType.xpub) {
      throw StateError('Signing not supported for watch-only wallets');
    }

    final tx = dartsv.Transaction.fromHex(command.rawTransaction);
    if (command.inputIndex < 0 || command.inputIndex >= tx.inputs.length) {
      throw ArgumentError('Input index ${command.inputIndex} out of range '
          '(transaction has ${tx.inputs.length} inputs)');
    }
    if (command.satoshis < BigInt.zero) {
      throw ArgumentError('Spent amount must not be negative');
    }

    final privateKey = await keys.privateKeyAtIndex(
      command.walletId,
      command.derivationIndex,
      currentState,
      isChange: command.isChange,
    );

    // What dartsv's DefaultTransactionSigner does, without needing an
    // unlocking-script builder on the input.
    final digest = dartsv.Sighash().hash(
      tx,
      command.sighashType,
      command.inputIndex,
      dartsv.SVScript.fromHex(command.subscriptHex),
      command.satoshis,
    );
    final signature = dartsv.SVSignature.fromPrivateKey(privateKey)..nhashtype = command.sighashType;
    signature.sign(hex.encode(hex.decode(digest).reversed.toList()));

    return (signatureHex: signature.toTxFormat(), publicKeyHex: privateKey.publicKey.toHex());
  }
}

/// The unlocking script `<sig>` of a P2PK output.
class SignatureOnlyUnlockBuilder extends dartsv.UnlockingScriptBuilder {
  @override
  dartsv.SVScript getScriptSig() => signatures.isEmpty
      ? dartsv.ScriptBuilder().build()
      : dartsv.ScriptBuilder().addData(Uint8List.fromList(hex.decode(signatures.first.toTxFormat()))).build();

  @override
  void parse(dartsv.SVScript script) {}
}
