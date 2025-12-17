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

import '../models/bitcoin_utxo.dart';
import 'crypto_service.dart';
import 'transaction_builder_service.dart';

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
  final CryptoService _cryptoService;
  final dartsv.NetworkType _networkType;

  /// Default fee rate in satoshis per kilobyte
  static const int defaultFeePerKb = 1;

  /// Dust threshold in satoshis
  static const int dustThreshold = 546;

  /// Estimated size of a P2MS 2-of-2 input (with signatures)
  static const int multisigInputSize = 300;

  /// Estimated size of a P2PKH output
  static const int p2pkhOutputSize = 34;

  /// Transaction overhead
  static const int txOverhead = 10;

  PaymentChannelBuilder({
    required CryptoService cryptoService,
    dartsv.NetworkType networkType = dartsv.NetworkType.TEST,
  })  : _cryptoService = cryptoService,
        _networkType = networkType;

  /// Build a 2-of-2 multisig funding transaction (T1)
  ///
  /// Creates a transaction that:
  /// - Spends client's UTXOs
  /// - Creates a 2-of-2 multisig output locked to client + server pubkeys
  /// - Returns change to client
  /// - Uses nSequence = MAX (final, no replacement)
  /// - Uses nLockTime = 0
  Future<ChannelTransactionResult> buildFundingTransaction({
    required dartsv.SVPublicKey clientPubKey,
    required dartsv.SVPublicKey serverPubKey,
    required BigInt fundingAmountSats,
    required List<BitcoinUtxo> clientUtxos,
    required dartsv.Address changeAddress,
    required dartsv.SVPrivateKey clientPrivateKey,
    int feePerKb = defaultFeePerKb,
  }) async {
    // Create 2-of-2 multisig locking script
    final lockBuilder = dartsv.P2MSLockBuilder(
      [clientPubKey, serverPubKey],
      2,
      sorting: true,
    );
    final multisigScript = lockBuilder.getScriptPubkey();

    // Calculate total input
    final totalInput = clientUtxos.fold<BigInt>(
      BigInt.zero,
      (sum, utxo) => sum + utxo.value.getValue(),
    );

    // Estimate fee
    final estimatedSize = txOverhead +
        (clientUtxos.length * 148) +
        p2pkhOutputSize +
        p2pkhOutputSize;
    final fee = BigInt.from((estimatedSize * feePerKb) ~/ 1000);

    if (totalInput < fundingAmountSats + fee) {
      throw TransactionBuildException(
        'Insufficient funds: need ${fundingAmountSats + fee}, have $totalInput',
        code: 'INSUFFICIENT_FUNDS',
      );
    }

    final changeAmount = totalInput - fundingAmountSats - fee;

    // Build transaction
    final txBuilder = dartsv.TransactionBuilder();
    txBuilder.spendToLockBuilder(lockBuilder, fundingAmountSats);

    if (changeAmount > BigInt.from(dustThreshold)) {
      txBuilder.sendChangeToPKH(changeAddress);
    }

    for (final utxo in clientUtxos) {
      final utxoAddress = dartsv.Address.fromBase58(utxo.address);
      final lockingScript =
          dartsv.P2PKHLockBuilder.fromAddress(utxoAddress).getScriptPubkey();

      final outpoint = dartsv.TransactionOutpoint(
        utxo.txid,
        utxo.vout,
        utxo.value.getValue(),
        lockingScript,
      );

      final signer = dartsv.TransactionSigner(
        dartsv.SighashType.SIGHASH_ALL.value |
            dartsv.SighashType.SIGHASH_FORKID.value,
        clientPrivateKey,
      );

      txBuilder.spendFromOutpointWithSigner(
        signer,
        outpoint,
        dartsv.TransactionInput.MAX_SEQ_NUMBER,
        dartsv.P2PKHUnlockBuilder(clientPrivateKey.publicKey),
      );
    }

    txBuilder
        .withFeePerKb(feePerKb)
        .withOption(dartsv.TransactionOption.DISABLE_DUST_OUTPUTS);

    final transaction = txBuilder.build(false);
    final transactionHex = transaction.serialize();

    return ChannelTransactionResult(
      transaction: transaction,
      transactionHex: transactionHex,
      txid: transaction.id,
      multisigScript: multisigScript,
      fee: fee,
    );
  }

  /// Build a refund transaction (T2)
  ///
  /// Creates a transaction that:
  /// - Spends the funding output (2-of-2 multisig)
  /// - Returns all funds to client (minus fee)
  /// - Uses nSequence = 0 (enables nLockTime check)
  /// - Uses nLockTime = channel expiry time
  Future<ChannelTransactionResult> buildRefundTransaction({
    required String fundingTxId,
    required int fundingOutputIndex,
    required BigInt fundingAmountSats,
    required dartsv.SVPublicKey clientPubKey,
    required dartsv.SVPublicKey serverPubKey,
    required dartsv.Address clientAddress,
    required int lockTimeUnix,
    int feePerKb = defaultFeePerKb,
  }) async {
    final lockBuilder = dartsv.P2MSLockBuilder(
      [clientPubKey, serverPubKey],
      2,
      sorting: true,
    );
    final multisigScript = lockBuilder.getScriptPubkey();

    final estimatedSize = txOverhead + multisigInputSize + p2pkhOutputSize;
    final fee = BigInt.from((estimatedSize * feePerKb) ~/ 1000);
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
  /// - Uses nSequence = sequenceNumber (incrementing enables replacement)
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
    int feePerKb = defaultFeePerKb,
  }) async {
    final lockBuilder = dartsv.P2MSLockBuilder(
      [clientPubKey, serverPubKey],
      2,
      sorting: true,
    );
    final multisigScript = lockBuilder.getScriptPubkey();

    final estimatedSize =
        txOverhead + multisigInputSize + (2 * p2pkhOutputSize);
    final fee = BigInt.from((estimatedSize * feePerKb) ~/ 1000);
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

  /// Sign a multisig input
  Future<MultisigSignatureResult> signMultisigInput({
    required dartsv.Transaction transaction,
    required int inputIndex,
    required dartsv.SVPrivateKey privateKey,
    required dartsv.SVPublicKey clientPubKey,
    required dartsv.SVPublicKey serverPubKey,
    required BigInt inputAmountSats,
  }) async {
    final lockBuilder = dartsv.P2MSLockBuilder(
      [clientPubKey, serverPubKey],
      2,
      sorting: true,
    );
    final redeemScript = lockBuilder.getScriptPubkey();

    final sighashType = dartsv.SighashType.SIGHASH_ALL.value |
        dartsv.SighashType.SIGHASH_FORKID.value;

    final sighash = dartsv.Sighash();
    final preimage = sighash.hash(
      transaction,
      sighashType,
      inputIndex,
      redeemScript,
      inputAmountSats,
    );

    final signature = await _cryptoService.signTransactionHash(
      privateKey,
      Uint8List.fromList(hex.decode(preimage)),
      sighashType,
    );

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

  /// Estimate fee for a payment channel transaction
  BigInt estimateFee({
    required int inputCount,
    required int outputCount,
    bool isMultisigInput = true,
    int feePerKb = defaultFeePerKb,
  }) {
    final inputSize = isMultisigInput ? multisigInputSize : 148;
    final estimatedSize =
        txOverhead + (inputCount * inputSize) + (outputCount * p2pkhOutputSize);
    return BigInt.from((estimatedSize * feePerKb) ~/ 1000);
  }

  /// Parse a transaction from hex
  dartsv.Transaction parseTransaction(String txHex) {
    return dartsv.Transaction.fromHex(txHex);
  }

  /// Get public key from private key
  dartsv.SVPublicKey getPublicKey(dartsv.SVPrivateKey privateKey) {
    return privateKey.publicKey;
  }
}
