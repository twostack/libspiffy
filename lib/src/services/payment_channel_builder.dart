/// Payment Channel Transaction Builder
///
/// Builds Bitcoin transactions for nLockTime-based payment channels:
/// - T1 (Funding TX): Creates 2-of-2 multisig output
/// - T2 (Refund TX): Time-locked return to client
/// - T3 (Payment TX): Updated balance distribution with incrementing nSequence
///
/// Uses dartsv's P2MSLockBuilder/P2MSUnlockBuilder for multisig operations.

import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:dartsv/dartsv.dart' as dartsv;

import '../models/bitcoin_transaction.dart';
import '../core/wallet/transaction_size.dart';
import '../models/fee_rate.dart';
import '../storage/read_model_storage.dart';
import 'ancestor_chain_service.dart';
import '../utils/beef.dart';

/// Thrown when a payment channel transaction cannot be built (insufficient
/// funds, invalid parameters, missing keys).
class TransactionBuildException implements Exception {
  final String message;
  final String? code;

  TransactionBuildException(this.message, {this.code});

  @override
  String toString() => 'TransactionBuildException${code != null ? ' ($code)' : ''}: $message';
}

/// Result of a payment channel transaction build
class ChannelTransactionResult {
  /// The built transaction
  final dartsv.Transaction transaction;

  /// Transaction hex for serialization/broadcast
  final String transactionHex;

  /// Transaction ID
  final String txid;

  /// The multisig locking script (for reference)
  final dartsv.SVScript? multisigScript;

  /// Total fee paid
  final BigInt fee;

  ChannelTransactionResult({
    required this.transaction,
    required this.transactionHex,
    required this.txid,
    this.multisigScript,
    required this.fee,
  });
}

/// Result of signing a multisig input
class MultisigSignatureResult {
  /// The signature in DER format
  final dartsv.SVSignature signature;

  /// Signature in transaction format (DER + sighash byte)
  final String signatureHex;

  MultisigSignatureResult({
    required this.signature,
    required this.signatureHex,
  });
}

/// Payment Channel Builder Service
///
/// Builds and signs transactions for payment channel operations using
/// dartsv's P2MSLockBuilder and P2MSUnlockBuilder.
class PaymentChannelBuilder {

  /// Dust threshold in satoshis
  static const int dustThreshold = 546;

  /// nLockTime values below this are block heights; values at or above it
  /// are Unix timestamps (consensus LOCKTIME_THRESHOLD).
  static const int lockTimeThreshold = 500000000;

  const PaymentChannelBuilder();

  // =============================================================================
  // SCRIPT VERIFICATION
  // =============================================================================

  /// Standard script verification flags for BSV
  static final Set<dartsv.VerifyFlag> _scriptFlags = {
    dartsv.VerifyFlag.SIGHASH_FORKID,
    dartsv.VerifyFlag.UTXO_AFTER_GENESIS,
  };

  /// Verify a fully-signed multisig transaction correctly spends its input
  ///
  /// This is a critical safety check that ensures:
  /// - Both signatures are valid
  /// - The redeem script matches the expected 2-of-2 multisig
  /// - The scriptSig correctly unlocks the UTXO
  ///
  /// Throws [ScriptVerificationException] if verification fails.
  void verifyMultisigSpend({
    required dartsv.Transaction signedTx,
    required dartsv.SVScript redeemScript,
    required BigInt inputValueSats,
    int inputIndex = 0,
  }) {
    final interpreter = dartsv.Interpreter();

    try {
      final input = signedTx.inputs[inputIndex];
      final scriptSig = input.script;

      if (scriptSig == null) {
        throw ScriptVerificationException(
          'Input $inputIndex has no scriptSig',
          code: 'MISSING_SCRIPTSIG',
        );
      }

      interpreter.correctlySpends(
        scriptSig,
        redeemScript,
        signedTx,
        inputIndex,
        _scriptFlags,
        dartsv.Coin.ofSat(inputValueSats),
      );

    } on dartsv.ScriptException catch (e) {
      throw ScriptVerificationException(
        'Multisig script verification failed: $e',
        code: 'SCRIPT_EXECUTION_FAILED',
      );
    }
  }

  /// The fee of a channel payment transaction spending the funding output
  /// locked by [multisigScript]: [feeRate] on its signed size, the 2-of-2
  /// input with both signatures and both parties' P2PKH outputs. The one
  /// statement of it: the client pays it and the server requires it
  /// (bead libspiffy-zs4l).
  static BigInt paymentFee(dartsv.SVScript multisigScript, FeeRate feeRate) => feeRate.feeFor(TransactionSize.of(
        inputLockingScripts: [multisigScript.toHex()],
        outputScriptBytes: const [TransactionSize.p2pkhScriptBytes, TransactionSize.p2pkhScriptBytes],
      ));

  /// Build multisig redeem script for verification
  ///
  /// Creates the 2-of-2 multisig script used as the locking script
  /// for the funding output.
  dartsv.SVScript buildMultisigRedeemScript({
    required dartsv.SVPublicKey clientPubKey,
    required dartsv.SVPublicKey serverPubKey,
  }) {
    final lockBuilder = dartsv.P2MSLockBuilder(
      [clientPubKey, serverPubKey],
      2,
      sorting: true,
    );
    return lockBuilder.getScriptPubkey();
  }
  
  /// Build a refund transaction (T2)
  ///
  /// Creates a transaction that:
  /// - Spends the funding output (2-of-2 multisig)
  /// - Returns all funds to client (minus fee)
  /// - Uses nSequence = 0 (enables nLockTime check)
  /// - Uses nLockTime = channel expiry time
  ///
  /// [lockTimeUnix] must be a Unix timestamp that consensus reads as one:
  /// nLockTime values below [lockTimeThreshold] are block heights, so a
  /// smaller value would make the refund valid at a block height rather than
  /// at the channel expiry. Values outside
  /// [lockTimeThreshold]..0xFFFFFFFF throw a [TransactionBuildException]
  /// with code `INVALID_LOCKTIME`.
  Future<ChannelTransactionResult> buildRefundTransaction({
    required String fundingTxId,
    required int fundingOutputIndex,
    required BigInt fundingAmountSats,
    required dartsv.SVPublicKey clientPubKey,
    required dartsv.SVPublicKey serverPubKey,
    required dartsv.Address clientAddress,
    required int lockTimeUnix,
    required FeeRate feeRate,
  }) async {
    if (lockTimeUnix < lockTimeThreshold || lockTimeUnix > 0xFFFFFFFF) {
      throw TransactionBuildException(
        'Refund lockTimeUnix $lockTimeUnix is not a Unix timestamp nLockTime '
        '(must be in $lockTimeThreshold..${0xFFFFFFFF}; smaller values are '
        'block heights)',
        code: 'INVALID_LOCKTIME',
      );
    }

    final lockBuilder = dartsv.P2MSLockBuilder(
      [clientPubKey, serverPubKey],
      2,
      sorting: true,
    );
    final multisigScript = lockBuilder.getScriptPubkey();

    // ARC's policy rate on the refund's signed size: the 2-of-2 input with
    // both signatures, and one P2PKH output (bead libspiffy-zs4l).
    final fee = feeRate.feeFor(TransactionSize.of(
      inputLockingScripts: [multisigScript.toHex()],
      outputScriptBytes: const [TransactionSize.p2pkhScriptBytes],
    ));
    final outputAmount = fundingAmountSats - fee;

    if (outputAmount <= BigInt.from(dustThreshold)) {
      throw TransactionBuildException(
        'Refund amount after fee is below dust threshold',
        code: 'DUST_OUTPUT',
      );
    }

    final transaction = dartsv.Transaction();
    transaction.version = 1;
    transaction.nLockTime = lockTimeUnix;

    final input = dartsv.TransactionInput(
      fundingTxId,
      fundingOutputIndex,
      0,
    );
    transaction.inputs.add(input);

    final outputScript =
        dartsv.P2PKHLockBuilder.fromAddress(clientAddress).getScriptPubkey();
    final output = dartsv.TransactionOutput(outputAmount, outputScript);
    transaction.outputs.add(output);

    final transactionHex = transaction.serialize();

    return ChannelTransactionResult(
      transaction: transaction,
      transactionHex: transactionHex,
      txid: transaction.id,
      multisigScript: multisigScript,
      fee: fee,
    );
  }

  /// Build a payment transaction (T3)
  ///
  /// Creates a transaction that:
  /// - Spends the funding output (2-of-2 multisig)
  /// - Distributes funds: serverAmount to server, remainder to client
  /// - Uses nSequence = sequenceNumber, which orders payment versions
  ///   between the parties. With nLockTime = 0 the transaction is final as
  ///   soon as it is built, so nSequence gives no on-chain replacement: any
  ///   version either party holds can be broadcast. The server keeps (and
  ///   broadcasts) the latest one.
  /// - Uses nLockTime = 0 (immediately valid)
  Future<ChannelTransactionResult> buildPaymentTransaction({
    required String fundingTxId,
    required int fundingOutputIndex,
    required BigInt fundingAmountSats,
    required dartsv.SVPublicKey clientPubKey,
    required dartsv.SVPublicKey serverPubKey,
    required dartsv.Address clientAddress,
    required dartsv.Address serverAddress,
    required BigInt serverAmountSats,
    required int sequenceNumber,
    required FeeRate feeRate,
  }) async {
    final lockBuilder = dartsv.P2MSLockBuilder(
      [clientPubKey, serverPubKey],
      2,
      sorting: true,
    );
    final multisigScript = lockBuilder.getScriptPubkey();

    // ARC's policy rate on the payment's signed size: the 2-of-2 input with
    // both signatures, and both parties' P2PKH outputs (bead
    // libspiffy-zs4l). The fee comes out of the client's share.
    final fee = paymentFee(multisigScript, feeRate);
    final clientAmount = fundingAmountSats - serverAmountSats - fee;

    if (clientAmount < BigInt.zero) {
      throw TransactionBuildException(
        'Server amount + fee exceeds funding',
        code: 'INSUFFICIENT_FUNDS',
      );
    }

    final transaction = dartsv.Transaction();
    transaction.version = 1;
    transaction.nLockTime = 0;

    final input = dartsv.TransactionInput(
      fundingTxId,
      fundingOutputIndex,
      sequenceNumber,
    );
    transaction.inputs.add(input);

    if (serverAmountSats > BigInt.from(dustThreshold)) {
      final serverScript =
          dartsv.P2PKHLockBuilder.fromAddress(serverAddress).getScriptPubkey();
      transaction.outputs
          .add(dartsv.TransactionOutput(serverAmountSats, serverScript));
    }

    if (clientAmount > BigInt.from(dustThreshold)) {
      final clientScript =
          dartsv.P2PKHLockBuilder.fromAddress(clientAddress).getScriptPubkey();
      transaction.outputs
          .add(dartsv.TransactionOutput(clientAmount, clientScript));
    }

    if (transaction.outputs.isEmpty) {
      throw TransactionBuildException(
        'No outputs above dust threshold',
        code: 'NO_OUTPUTS',
      );
    }

    final transactionHex = transaction.serialize();

    return ChannelTransactionResult(
      transaction: transaction,
      transactionHex: transactionHex,
      txid: transaction.id,
      multisigScript: multisigScript,
      fee: fee,
    );
  }

  /// Sign a multisig input using TransactionSigner
  /// 
  /// This method uses dartsv's TransactionSigner which correctly computes
  /// the sighash for multisig inputs. The previous implementation using
  /// Sighash.hash() directly produced invalid signatures.
  ///
  /// [transaction] is not modified: the signer works on a copy.
  Future<MultisigSignatureResult> signMultisigInput({
    required dartsv.Transaction transaction,
    required int inputIndex,
    required dartsv.SVPrivateKey privateKey,
    required dartsv.SVPublicKey clientPubKey,
    required dartsv.SVPublicKey serverPubKey,
    required BigInt inputAmountSats,
  }) async {
    // Create the multisig locking script (scriptPubKey being spent)
    final lockBuilder = dartsv.P2MSLockBuilder(
      [clientPubKey, serverPubKey],
      2,
      sorting: true,
    );
    final redeemScript = lockBuilder.getScriptPubkey();

    final sighashType = dartsv.SighashType.SIGHASH_ALL.value |
        dartsv.SighashType.SIGHASH_FORKID.value;

    // Create a P2MSUnlockBuilder to collect signatures
    final unlockBuilder = dartsv.P2MSUnlockBuilder();
    
    // Sign a copy: the signer needs our unlock builder attached to the input,
    // and the caller's transaction must not be modified (audit SPV-13). The
    // FORKID sighash commits to outpoints, sequences, outputs, version and
    // nLockTime, all of which the serialized copy preserves.
    final signingTx = dartsv.Transaction.fromHex(transaction.serialize());
    final originalInput = signingTx.inputs[inputIndex];

    // Replace the input with one that has our unlock builder attached
    // This is required because TransactionSigner adds signatures to the unlock builder
    final newInput = dartsv.TransactionInput(
      originalInput.prevTxnId,
      originalInput.prevTxnOutputIndex,
      originalInput.sequenceNumber,
      scriptBuilder: unlockBuilder,
    );
    signingTx.inputs[inputIndex] = newInput;
    
    // Create the UTXO output that we're spending from
    final utxo = dartsv.TransactionOutput(inputAmountSats, redeemScript);
    
    // Use TransactionSigner - this correctly computes sighash and signs
    final signer = dartsv.DefaultTransactionSigner(sighashType, privateKey);
    signer.sign(signingTx, utxo, inputIndex);
    
    // Extract our signature from the unlock builder
    if (unlockBuilder.signatures.isEmpty) {
      throw StateError('TransactionSigner did not add signature to unlock builder');
    }
    
    final signature = unlockBuilder.signatures.last;

    return MultisigSignatureResult(
      signature: signature,
      signatureHex: signature.toTxFormat(),
    );
  }

  /// Apply both signatures to create a complete multisig scriptSig
  dartsv.Transaction applyMultisigSignatures({
    required dartsv.Transaction transaction,
    required int inputIndex,
    required dartsv.SVSignature clientSignature,
    required dartsv.SVSignature serverSignature,
    required dartsv.SVPublicKey clientPubKey,
    required dartsv.SVPublicKey serverPubKey,
  }) {
    
    final sortedPubKeys = [clientPubKey, serverPubKey]
      ..sort((a, b) => a.toString().compareTo(b.toString()));

    
    final List<dartsv.SVSignature> orderedSigs;
    if (sortedPubKeys[0].toString() == clientPubKey.toString()) {
      orderedSigs = [clientSignature, serverSignature];
    } else {
      orderedSigs = [serverSignature, clientSignature];
    }

    final unlockBuilder = dartsv.P2MSUnlockBuilder.fromSignatures(orderedSigs);
    final scriptSig = unlockBuilder.getScriptSig();

    
    transaction.inputs[inputIndex].script = scriptSig;

    return transaction;
  }

  /// Create a 2-of-2 multisig locking script
  dartsv.SVScript createMultisigScript(
    dartsv.SVPublicKey clientPubKey,
    dartsv.SVPublicKey serverPubKey,
  ) {
    final lockBuilder = dartsv.P2MSLockBuilder(
      [clientPubKey, serverPubKey],
      2,
      sorting: true,
    );
    return lockBuilder.getScriptPubkey();
  }

  /// Parse a transaction from hex
  dartsv.Transaction parseTransaction(String txHex) {
    return dartsv.Transaction.fromHex(txHex);
  }

  /// Get public key from private key
  dartsv.SVPublicKey getPublicKey(dartsv.SVPrivateKey privateKey) {
    return privateKey.publicKey;
  }

  /// Build payment transaction with extended BEEF for unconfirmed funding
  ///
  /// This method creates a BEEF package that includes:
  /// 1. Ancestor transactions (with merkle proofs)
  /// 2. Funding transaction (no proof yet if unconfirmed)
  /// 3. Payment transaction (no proof)
  ///
  /// This allows the receiver to validate the entire chain back to confirmed
  /// transactions even when the funding transaction is unconfirmed.
  Future<PaymentWithBEEF> buildPaymentWithAncestry({
    required ChannelTransactionResult paymentTx,
    required BitcoinTransaction fundingTransaction,
    required List<BitcoinTransaction> fundingAncestors,
    required List<MerkleProof> ancestorProofs,
  }) async {

    // 1. Assemble the BEEF with the library's one BEEF builder:
    //    - Ancestors (with proofs) first, parents before children
    //    - Funding transaction (no proof yet)
    //    - Payment transaction (no proof)
    //    Ancestors mined in the same block share one BRC-74 multi-leaf BUMP
    //    instead of repeating that block's merkle path (libspiffy-0lx).
    final serialized = AncestorChainService.buildBeef(
      fundingAncestors,
      [fundingTransaction, _paymentRecord(paymentTx)],
      ancestorProofs,
    ).serialize();

    // 2. Verify
    try {
      BEEF.parse(serialized);
    } catch (e) {
      throw Exception('Created BEEF is invalid: $e');
    }

    return PaymentWithBEEF(
      paymentTx: paymentTx,
      beefBytes: serialized,
      ancestorCount: fundingAncestors.length + 1, // +1 for funding tx
      proofCount: ancestorProofs.length,
    );
  }

  /// The just-built channel transaction as the record the BEEF builder
  /// takes; only [BitcoinTransaction.txid] and `rawHex` are read.
  static BitcoinTransaction _paymentRecord(ChannelTransactionResult paymentTx) {
    final now = DateTime.now();
    return BitcoinTransaction(
      txid: paymentTx.txid,
      rawHex: paymentTx.transactionHex,
      status: TransactionStatus.pending,
      inputValue: BigInt.zero,
      outputValue: BigInt.zero,
      fee: paymentTx.fee,
      receivingAddresses: const [],
      sendingAddresses: const [],
      netAmount: BigInt.zero,
      createdAt: now,
      updatedAt: now,
      lockTime: paymentTx.transaction.nLockTime,
      version: paymentTx.transaction.version,
    );
  }
}

/// Result of building a payment transaction with BEEF ancestry
class PaymentWithBEEF {
  /// The payment transaction result
  final ChannelTransactionResult paymentTx;

  /// BEEF bytes containing the payment + ancestry chain
  final Uint8List beefBytes;

  /// BEEF hex string
  final String beefHex;

  /// Number of ancestor transactions included
  final int ancestorCount;

  /// Number of merkle proofs included
  final int proofCount;

  PaymentWithBEEF({
    required this.paymentTx,
    required this.beefBytes,
    required this.ancestorCount,
    required this.proofCount,
  }) : beefHex = hex.encode(beefBytes);
}

/// Exception thrown when script verification fails
class ScriptVerificationException implements Exception {
  final String message;
  final String? code;

  ScriptVerificationException(this.message, {this.code});

  @override
  String toString() =>
      'ScriptVerificationException${code != null ? ' ($code)' : ''}: $message';
}
