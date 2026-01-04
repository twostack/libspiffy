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
import '../models/bitcoin_utxo.dart';
import '../storage/read_model_storage.dart';
import '../utils/beef.dart';
import '../utils/bump.dart';
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
  
  /// Minimum fee in satoshis (ensures fee is never zero)
  static const int minimumFeeSats = 1;

  PaymentChannelBuilder({
    required CryptoService cryptoService,
    dartsv.NetworkType networkType = dartsv.NetworkType.TEST,
  })  : _cryptoService = cryptoService,
        _networkType = networkType;

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

      print('[PaymentChannelBuilder] ✓ Multisig script verification passed');
    } on dartsv.ScriptException catch (e) {
      print('[PaymentChannelBuilder] ✗ Multisig script verification failed: $e');
      throw ScriptVerificationException(
        'Multisig script verification failed: $e',
        code: 'SCRIPT_EXECUTION_FAILED',
      );
    }
  }

  /// Verify a P2PKH transaction correctly spends its inputs
  ///
  /// Used for validating funding transactions that spend from client UTXOs.
  void verifyP2PKHSpend({
    required dartsv.Transaction signedTx,
    required List<dartsv.SVScript> inputScripts,
    required List<BigInt> inputValues,
  }) {
    final interpreter = dartsv.Interpreter();

    for (int i = 0; i < signedTx.inputs.length; i++) {
      try {
        final input = signedTx.inputs[i];
        final scriptSig = input.script;

        if (scriptSig == null) {
          throw ScriptVerificationException(
            'Input $i has no scriptSig',
            code: 'MISSING_SCRIPTSIG',
          );
        }

        interpreter.correctlySpends(
          scriptSig,
          inputScripts[i],
          signedTx,
          i,
          _scriptFlags,
          dartsv.Coin.ofSat(inputValues[i]),
        );
      } on dartsv.ScriptException catch (e) {
        print('[PaymentChannelBuilder] ✗ P2PKH script verification failed for input $i: $e');
        throw ScriptVerificationException(
          'P2PKH script verification failed for input $i: $e',
          code: 'SCRIPT_EXECUTION_FAILED',
        );
      }
    }

    print('[PaymentChannelBuilder] ✓ P2PKH script verification passed for ${signedTx.inputs.length} inputs');
  }

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
  
  /// Calculate transaction fee with minimum guarantee
  /// 
  /// Ensures fee is never zero due to integer division rounding.
  /// With 1 sat/KB rate and sub-KB transactions, naive integer division
  /// would result in 0 fee which causes transaction rejection.
  static BigInt calculateFee(int estimatedSizeBytes, int feePerKb) {
    // Round up to ensure fee is never zero for valid transactions
    // Formula: ceiling of (size * rate / 1000)
    final calculatedFee = ((estimatedSizeBytes * feePerKb) + 999) ~/ 1000;
    // Ensure minimum fee
    return BigInt.from(calculatedFee < minimumFeeSats ? minimumFeeSats : calculatedFee);
  }

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

    // Estimate fee (with minimum guarantee to avoid zero-fee rejection)
    final estimatedSize = txOverhead +
        (clientUtxos.length * 148) +
        p2pkhOutputSize +
        p2pkhOutputSize;
    final fee = calculateFee(estimatedSize, feePerKb);

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

    // SAFETY CHECK: Verify the signed funding TX correctly spends all inputs
    final inputScripts = clientUtxos.map((utxo) {
      final utxoAddress = dartsv.Address.fromBase58(utxo.address);
      return dartsv.P2PKHLockBuilder.fromAddress(utxoAddress).getScriptPubkey();
    }).toList();
    final inputValues = clientUtxos.map((utxo) => utxo.value.getValue()).toList();
    
    verifyP2PKHSpend(
      signedTx: transaction,
      inputScripts: inputScripts,
      inputValues: inputValues,
    );

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

    // Calculate fee (with minimum guarantee to avoid zero-fee rejection)
    final estimatedSize = txOverhead + multisigInputSize + p2pkhOutputSize;
    final fee = calculateFee(estimatedSize, feePerKb);
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

    // Calculate fee (with minimum guarantee to avoid zero-fee rejection)
    final estimatedSize =
        txOverhead + multisigInputSize + (2 * p2pkhOutputSize);
    final fee = calculateFee(estimatedSize, feePerKb);
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
    
    // Save the original input's script builder (if any)
    final originalInput = transaction.inputs[inputIndex];
    
    // Replace the input with one that has our unlock builder attached
    // This is required because TransactionSigner adds signatures to the unlock builder
    final newInput = dartsv.TransactionInput(
      originalInput.prevTxnId,
      originalInput.prevTxnOutputIndex,
      originalInput.sequenceNumber,
      scriptBuilder: unlockBuilder,
    );
    transaction.inputs[inputIndex] = newInput;
    
    // Create the UTXO output that we're spending from
    final utxo = dartsv.TransactionOutput(inputAmountSats, redeemScript);
    
    // Use TransactionSigner - this correctly computes sighash and signs
    final signer = dartsv.TransactionSigner(sighashType, privateKey);
    signer.sign(transaction, utxo, inputIndex);
    
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
    print('[PaymentChannelBuilder] 🔏 Applying multisig signatures');
    print('[PaymentChannelBuilder]    Client pubkey: ${clientPubKey.toHex()}');
    print('[PaymentChannelBuilder]    Server pubkey: ${serverPubKey.toHex()}');
    print('[PaymentChannelBuilder]    Client sig (txFormat): ${clientSignature.toTxFormat()}');
    print('[PaymentChannelBuilder]    Server sig (txFormat): ${serverSignature.toTxFormat()}');
    
    final sortedPubKeys = [clientPubKey, serverPubKey]
      ..sort((a, b) => a.toString().compareTo(b.toString()));

    print('[PaymentChannelBuilder]    Sorted order:');
    print('[PaymentChannelBuilder]      [0]: ${sortedPubKeys[0].toHex()}');
    print('[PaymentChannelBuilder]      [1]: ${sortedPubKeys[1].toHex()}');
    
    final List<dartsv.SVSignature> orderedSigs;
    if (sortedPubKeys[0].toString() == clientPubKey.toString()) {
      orderedSigs = [clientSignature, serverSignature];
      print('[PaymentChannelBuilder]    Sig order: [client, server]');
    } else {
      orderedSigs = [serverSignature, clientSignature];
      print('[PaymentChannelBuilder]    Sig order: [server, client]');
    }

    final unlockBuilder = dartsv.P2MSUnlockBuilder.fromSignatures(orderedSigs);
    final scriptSig = unlockBuilder.getScriptSig();

    print('[PaymentChannelBuilder]    ScriptSig hex: ${scriptSig.toHex()}');
    print('[PaymentChannelBuilder]    ScriptSig: ${scriptSig.toString()}');
    
    transaction.inputs[inputIndex].script = scriptSig;

    print('[PaymentChannelBuilder] ✅ Signatures applied');
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
    return calculateFee(estimatedSize, feePerKb);
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
    print('  📦 Building payment with ancestry BEEF');
    print('    Payment TX: ${paymentTx.txid}');
    print('    Funding TX: ${fundingTransaction.txid}');
    print('    Ancestors: ${fundingAncestors.length}');
    print('    Proofs: ${ancestorProofs.length}');

    // 1. Order transactions correctly:
    //    - Ancestors (with proofs) first
    //    - Funding transaction (no proof yet)
    //    - Payment transaction (no proof)
    final txBytes = <Uint8List>[];

    // Add ancestors
    for (final ancestor in fundingAncestors) {
      txBytes.add(Uint8List.fromList(hex.decode(ancestor.rawHex)));
    }

    // Add funding transaction
    txBytes.add(Uint8List.fromList(hex.decode(fundingTransaction.rawHex)));

    // Add payment transaction
    txBytes.add(Uint8List.fromList(hex.decode(paymentTx.transactionHex)));

    // 2. Build BUMPs from merkle proofs
    final bumps = <BUMP>[];
    for (final proof in ancestorProofs) {
      bumps.add(_buildBUMPFromMerkleProof(proof));
    }

    // 3. Set hasMerkle flags
    final hasMerkle = <bool>[];

    // Ancestors: check which ones have proofs
    for (final ancestor in fundingAncestors) {
      final hasProof = ancestorProofs.any((p) => p.txid == ancestor.txid);
      hasMerkle.add(hasProof);
    }

    // Funding transaction: no proof yet (unconfirmed)
    hasMerkle.add(false);

    // Payment transaction: no proof (just created)
    hasMerkle.add(false);

    // 4. Build bumpIndex array
    final bumpIndex = <int>[];
    for (int i = 0; i < fundingAncestors.length; i++) {
      if (hasMerkle[i]) {
        final proofIdx =
            ancestorProofs.indexWhere((p) => p.txid == fundingAncestors[i].txid);
        if (proofIdx != -1) {
          bumpIndex.add(proofIdx);
        }
      }
    }

    print('  📊 BEEF structure:');
    print('    Total transactions: ${txBytes.length}');
    print('    Total BUMPs: ${bumps.length}');
    print('    hasMerkle flags: $hasMerkle');
    print('    bumpIndex: $bumpIndex');

    // 5. Create BEEF
    final beef = BEEF.create(
      bumps: bumps,
      txs: txBytes,
      hasMerkle: hasMerkle,
      bumpIndex: bumpIndex,
    );

    // 6. Serialize
    final serialized = beef.serialize();
    print('  ✓ BEEF created: ${serialized.length} bytes');

    // 7. Verify
    try {
      final parsed = BEEF.parse(serialized);
      print('  ✓ BEEF verification passed');
      print('    Parsed ${parsed.txs.length} transactions');
      print('    Parsed ${parsed.bumps.length} proofs');
    } catch (e) {
      print('  ❌ BEEF verification failed: $e');
      throw Exception('Created BEEF is invalid: $e');
    }

    return PaymentWithBEEF(
      paymentTx: paymentTx,
      beefBytes: serialized,
      ancestorCount: fundingAncestors.length + 1, // +1 for funding tx
      proofCount: ancestorProofs.length,
    );
  }

  /// Build BUMP from MerkleProof (helper method)
  BUMP _buildBUMPFromMerkleProof(MerkleProof proof) {
    // Check if raw BUMP format
    if (proof.merkleProof.length == 1 && proof.merkleProof[0].length > 64) {
      final bumpBytes = Uint8List.fromList(hex.decode(proof.merkleProof[0]));
      return BUMP.fromBytes(bumpBytes);
    }

    // Build from sibling hashes
    final levels = <Level>[];

    // Level 0: Transaction ID
    final reversedTxid = _reverseHexBytes(proof.txid);
    levels.add(Level(leaves: [
      Leaf(
        offset: proof.position,
        duplicate: false,
        isTxid: true,
        hash: Uint8List.fromList(hex.decode(reversedTxid)),
      ),
    ]));

    // Subsequent levels
    for (int i = 0; i < proof.merkleProof.length; i++) {
      final indexBit = (proof.position >> i) & 1;
      final siblingOffset =
          indexBit == 0 ? (proof.position | (1 << i)) : (proof.position & ~(1 << i));

      final siblingHashHex = proof.merkleProof[i];
      final reversedHash = _reverseHexBytes(siblingHashHex);

      levels.add(Level(leaves: [
        Leaf(
          offset: siblingOffset,
          duplicate: false,
          isTxid: false,
          hash: Uint8List.fromList(hex.decode(reversedHash)),
        ),
      ]));
    }

    return BUMP(
      blockHeight: proof.blockHeight,
      path: levels,
    );
  }

  /// Reverse hex bytes for Bitcoin's little-endian format
  String _reverseHexBytes(String hexString) {
    if (hexString.length % 2 != 0) {
      throw Exception('Hex string must have even number of characters');
    }

    final result = StringBuffer();
    for (int i = hexString.length - 2; i >= 0; i -= 2) {
      result.write(hexString.substring(i, i + 2));
    }
    return result.toString();
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
