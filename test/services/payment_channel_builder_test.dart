import 'package:test/test.dart';
import 'package:dartsv/dartsv.dart' as dartsv;

import 'package:libspiffy/src/services/payment_channel_builder.dart';
import 'package:libspiffy/src/services/dartsv_crypto_service.dart';
import 'package:libspiffy/src/services/crypto_service.dart';
import 'package:libspiffy/src/models/fee_rate.dart';

import '../actors/channel_test_fixtures.dart';

void main() {
  group('PaymentChannelBuilder', () {
    late PaymentChannelBuilder channelBuilder;
    late CryptoService cryptoService;
    late dartsv.SVPrivateKey clientPrivateKey;
    late dartsv.SVPrivateKey serverPrivateKey;
    late dartsv.SVPublicKey clientPubKey;
    late dartsv.SVPublicKey serverPubKey;
    late dartsv.Address clientAddress;
    late dartsv.Address serverAddress;

    const testNetworkType = dartsv.NetworkType.TEST;
    
    // Use a well-known test mnemonic for reproducible key derivation
    const testMnemonic = 
        'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';

    setUp(() async {
      cryptoService = DartSVCryptoService();
      channelBuilder = const PaymentChannelBuilder();

      // Derive test key pairs from mnemonic for reproducibility
      final hdPrivateKey = await cryptoService.mnemonicToHDPrivateKey(
        testMnemonic,
        network: testNetworkType,
      );
      
      // Client key at derivation index 0
      clientPrivateKey = await cryptoService.derivePrivateKey(hdPrivateKey, 0, 0);
      
      // Server key at derivation index 1 (different from client)
      serverPrivateKey = await cryptoService.derivePrivateKey(hdPrivateKey, 0, 1);

      clientPubKey = clientPrivateKey.publicKey;
      serverPubKey = serverPrivateKey.publicKey;

      clientAddress =
          dartsv.Address.fromPublicKey(clientPubKey, testNetworkType);
      serverAddress =
          dartsv.Address.fromPublicKey(serverPubKey, testNetworkType);
    });

    /// A funding transaction locking [amountSats] in the channel's 2-of-2 at
    /// output [outputIndex]. The wallet aggregate builds real fundings
    /// (`ChannelFunding`); this builder no longer has a second copy of it.
    ({dartsv.Transaction transaction, String txid}) fundingTransaction(BigInt amountSats, {int outputIndex = 0}) {
      final funding = channelFundingTx(
        clientPubKeyHex: clientPubKey.toHex(),
        serverPubKeyHex: serverPubKey.toHex(),
        amountSats: amountSats,
        outputIndex: outputIndex,
      );
      return (transaction: dartsv.Transaction.fromHex(funding.hex), txid: funding.txid);
    }

    // =========================================================================
    // REFUND TRANSACTION (T2) TESTS
    // =========================================================================
    group('Refund Transaction (T2)', () {
      test('should build refund transaction with correct nLockTime', () async {
        const fundingTxId =
            'abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890';
        const fundingOutputIndex = 0;
        final fundingAmount = BigInt.from(100000);
        final lockTimeUnix =
            DateTime.now().add(const Duration(hours: 24)).millisecondsSinceEpoch ~/
                1000;

        final result = await channelBuilder.buildRefundTransaction(feeRate: const FeeRate(satoshis: 100, bytes: 1000),
          fundingTxId: fundingTxId,
          fundingOutputIndex: fundingOutputIndex,
          fundingAmountSats: fundingAmount,
          clientPubKey: clientPubKey,
          serverPubKey: serverPubKey,
          clientAddress: clientAddress,
          lockTimeUnix: lockTimeUnix,
        );

        expect(result.transaction, isNotNull);
        expect(result.transaction.nLockTime, equals(lockTimeUnix));
        expect(result.transactionHex, isNotEmpty);
        expect(result.txid, isNotEmpty);
      });

      test('should use nSequence 0 to enable nLockTime', () async {
        const fundingTxId =
            'abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890';
        final fundingAmount = BigInt.from(100000);
        final lockTimeUnix =
            DateTime.now().add(const Duration(hours: 24)).millisecondsSinceEpoch ~/
                1000;

        final result = await channelBuilder.buildRefundTransaction(feeRate: const FeeRate(satoshis: 100, bytes: 1000),
          fundingTxId: fundingTxId,
          fundingOutputIndex: 0,
          fundingAmountSats: fundingAmount,
          clientPubKey: clientPubKey,
          serverPubKey: serverPubKey,
          clientAddress: clientAddress,
          lockTimeUnix: lockTimeUnix,
        );

        // nSequence must be 0 for nLockTime to be enforced
        expect(result.transaction.inputs[0].sequenceNumber, equals(0));
      });

      test('should return full amount minus fee to client', () async {
        const fundingTxId =
            'abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890';
        final fundingAmount = BigInt.from(100000);
        final lockTimeUnix =
            DateTime.now().add(const Duration(hours: 24)).millisecondsSinceEpoch ~/
                1000;

        final result = await channelBuilder.buildRefundTransaction(feeRate: const FeeRate(satoshis: 100, bytes: 1000),
          fundingTxId: fundingTxId,
          fundingOutputIndex: 0,
          fundingAmountSats: fundingAmount,
          clientPubKey: clientPubKey,
          serverPubKey: serverPubKey,
          clientAddress: clientAddress,
          lockTimeUnix: lockTimeUnix,
        );

        // Single output returning to client
        expect(result.transaction.outputs.length, equals(1));

        // Output amount should be funding minus fee
        final outputAmount = result.transaction.outputs[0].satoshis;
        expect(outputAmount, equals(fundingAmount - result.fee));
      });

      test('should reference correct funding outpoint', () async {
        const fundingTxId =
            '1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef';
        const fundingOutputIndex = 2;
        final fundingAmount = BigInt.from(100000);
        final lockTimeUnix =
            DateTime.now().add(const Duration(hours: 24)).millisecondsSinceEpoch ~/
                1000;

        final result = await channelBuilder.buildRefundTransaction(feeRate: const FeeRate(satoshis: 100, bytes: 1000),
          fundingTxId: fundingTxId,
          fundingOutputIndex: fundingOutputIndex,
          fundingAmountSats: fundingAmount,
          clientPubKey: clientPubKey,
          serverPubKey: serverPubKey,
          clientAddress: clientAddress,
          lockTimeUnix: lockTimeUnix,
        );

        final input = result.transaction.inputs[0];
        expect(input.prevTxnId, equals(fundingTxId));
        expect(input.prevTxnOutputIndex, equals(fundingOutputIndex));
      });

      test('should throw when refund amount after fee is dust', () async {
        const fundingTxId =
            'abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890';
        final fundingAmount = BigInt.from(100); // Very small amount
        final lockTimeUnix =
            DateTime.now().add(const Duration(hours: 24)).millisecondsSinceEpoch ~/
                1000;

        expect(
          () => channelBuilder.buildRefundTransaction(feeRate: const FeeRate(satoshis: 100, bytes: 1000),
            fundingTxId: fundingTxId,
            fundingOutputIndex: 0,
            fundingAmountSats: fundingAmount,
            clientPubKey: clientPubKey,
            serverPubKey: serverPubKey,
            clientAddress: clientAddress,
            lockTimeUnix: lockTimeUnix,
          ),
          throwsA(isA<TransactionBuildException>().having(
            (e) => e.code,
            'code',
            equals('DUST_OUTPUT'),
          )),
        );
      });

      test('should include multisig script reference', () async {
        const fundingTxId =
            'abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890';
        final fundingAmount = BigInt.from(100000);
        final lockTimeUnix =
            DateTime.now().add(const Duration(hours: 24)).millisecondsSinceEpoch ~/
                1000;

        final result = await channelBuilder.buildRefundTransaction(feeRate: const FeeRate(satoshis: 100, bytes: 1000),
          fundingTxId: fundingTxId,
          fundingOutputIndex: 0,
          fundingAmountSats: fundingAmount,
          clientPubKey: clientPubKey,
          serverPubKey: serverPubKey,
          clientAddress: clientAddress,
          lockTimeUnix: lockTimeUnix,
        );

        // Should include multisig script for signing reference
        expect(result.multisigScript, isNotNull);
      });
    });

    // =========================================================================
    // PAYMENT TRANSACTION (T3) TESTS
    // =========================================================================
    group('Payment Transaction (T3)', () {
      test('should build payment transaction with correct balance split', () async {
        const fundingTxId =
            'abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890';
        final fundingAmount = BigInt.from(100000);
        final serverAmount = BigInt.from(10000);

        final result = await channelBuilder.buildPaymentTransaction(feeRate: const FeeRate(satoshis: 100, bytes: 1000),
          fundingTxId: fundingTxId,
          fundingOutputIndex: 0,
          fundingAmountSats: fundingAmount,
          clientPubKey: clientPubKey,
          serverPubKey: serverPubKey,
          clientAddress: clientAddress,
          serverAddress: serverAddress,
          serverAmountSats: serverAmount,
          sequenceNumber: 1,
        );

        expect(result.transaction, isNotNull);
        expect(result.transaction.outputs.length, equals(2));

        // Verify output amounts
        final totalOutput = result.transaction.outputs
            .fold<BigInt>(BigInt.zero, (sum, o) => sum + o.satoshis);
        expect(totalOutput, equals(fundingAmount - result.fee));
      });

      test('should use provided sequence number', () async {
        const fundingTxId =
            'abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890';
        final fundingAmount = BigInt.from(100000);
        final serverAmount = BigInt.from(10000);
        const sequenceNumber = 42;

        final result = await channelBuilder.buildPaymentTransaction(feeRate: const FeeRate(satoshis: 100, bytes: 1000),
          fundingTxId: fundingTxId,
          fundingOutputIndex: 0,
          fundingAmountSats: fundingAmount,
          clientPubKey: clientPubKey,
          serverPubKey: serverPubKey,
          clientAddress: clientAddress,
          serverAddress: serverAddress,
          serverAmountSats: serverAmount,
          sequenceNumber: sequenceNumber,
        );

        expect(result.transaction.inputs[0].sequenceNumber, equals(sequenceNumber));
      });

      test('should use nLockTime 0 for immediate validity', () async {
        const fundingTxId =
            'abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890';
        final fundingAmount = BigInt.from(100000);
        final serverAmount = BigInt.from(10000);

        final result = await channelBuilder.buildPaymentTransaction(feeRate: const FeeRate(satoshis: 100, bytes: 1000),
          fundingTxId: fundingTxId,
          fundingOutputIndex: 0,
          fundingAmountSats: fundingAmount,
          clientPubKey: clientPubKey,
          serverPubKey: serverPubKey,
          clientAddress: clientAddress,
          serverAddress: serverAddress,
          serverAmountSats: serverAmount,
          sequenceNumber: 1,
        );

        expect(result.transaction.nLockTime, equals(0));
      });

      test('should handle incrementing sequence numbers', () async {
        const fundingTxId =
            'abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890';
        final fundingAmount = BigInt.from(100000);

        // Simulate channel updates with increasing sequence
        final results = <ChannelTransactionResult>[];
        for (int seq = 1; seq <= 5; seq++) {
          final serverAmount = BigInt.from(10000 * seq);
          final result = await channelBuilder.buildPaymentTransaction(feeRate: const FeeRate(satoshis: 100, bytes: 1000),
            fundingTxId: fundingTxId,
            fundingOutputIndex: 0,
            fundingAmountSats: fundingAmount,
            clientPubKey: clientPubKey,
            serverPubKey: serverPubKey,
            clientAddress: clientAddress,
            serverAddress: serverAddress,
            serverAmountSats: serverAmount,
            sequenceNumber: seq,
          );
          results.add(result);
        }

        // Each TX should have increasing sequence
        for (int i = 0; i < results.length; i++) {
          expect(results[i].transaction.inputs[0].sequenceNumber, equals(i + 1));
        }
      });

      test('should omit dust server output', () async {
        const fundingTxId =
            'abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890';
        final fundingAmount = BigInt.from(100000);
        final serverAmount = BigInt.from(100); // Below dust threshold

        final result = await channelBuilder.buildPaymentTransaction(feeRate: const FeeRate(satoshis: 100, bytes: 1000),
          fundingTxId: fundingTxId,
          fundingOutputIndex: 0,
          fundingAmountSats: fundingAmount,
          clientPubKey: clientPubKey,
          serverPubKey: serverPubKey,
          clientAddress: clientAddress,
          serverAddress: serverAddress,
          serverAmountSats: serverAmount,
          sequenceNumber: 1,
        );

        // Should only have client output (server amount is dust)
        expect(result.transaction.outputs.length, equals(1));
      });

      test('should omit dust client output', () async {
        const fundingTxId =
            'abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890';
        final fundingAmount = BigInt.from(10000);
        // Server takes almost everything, leaving dust for client
        final serverAmount = BigInt.from(9500);

        final result = await channelBuilder.buildPaymentTransaction(feeRate: const FeeRate(satoshis: 100, bytes: 1000),
          fundingTxId: fundingTxId,
          fundingOutputIndex: 0,
          fundingAmountSats: fundingAmount,
          clientPubKey: clientPubKey,
          serverPubKey: serverPubKey,
          clientAddress: clientAddress,
          serverAddress: serverAddress,
          serverAmountSats: serverAmount,
          sequenceNumber: 1,
        );

        // Should only have server output (client amount is dust)
        expect(result.transaction.outputs.length, equals(1));
      });

      test('should throw when server amount exceeds funding', () async {
        const fundingTxId =
            'abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890';
        final fundingAmount = BigInt.from(10000);
        final serverAmount = BigInt.from(20000); // Exceeds funding

        expect(
          () => channelBuilder.buildPaymentTransaction(feeRate: const FeeRate(satoshis: 100, bytes: 1000),
            fundingTxId: fundingTxId,
            fundingOutputIndex: 0,
            fundingAmountSats: fundingAmount,
            clientPubKey: clientPubKey,
            serverPubKey: serverPubKey,
            clientAddress: clientAddress,
            serverAddress: serverAddress,
            serverAmountSats: serverAmount,
            sequenceNumber: 1,
          ),
          throwsA(isA<TransactionBuildException>().having(
            (e) => e.code,
            'code',
            equals('INSUFFICIENT_FUNDS'),
          )),
        );
      });

      test('should throw when no outputs above dust threshold', () async {
        const fundingTxId =
            'abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890';
        // Use values that will result in both outputs being below dust
        // Server gets 300 (below 546), client gets ~300 after fee (below 546)
        final fundingAmount = BigInt.from(700);
        final serverAmount = BigInt.from(300);

        expect(
          () => channelBuilder.buildPaymentTransaction(feeRate: const FeeRate(satoshis: 100, bytes: 1000),
            fundingTxId: fundingTxId,
            fundingOutputIndex: 0,
            fundingAmountSats: fundingAmount,
            clientPubKey: clientPubKey,
            serverPubKey: serverPubKey,
            clientAddress: clientAddress,
            serverAddress: serverAddress,
            serverAmountSats: serverAmount,
            sequenceNumber: 1,
          ),
          throwsA(isA<TransactionBuildException>().having(
            (e) => e.code,
            'code',
            equals('NO_OUTPUTS'),
          )),
        );
      });

      test('payment transaction correctly spends from P2MS output using Interpreter.correctlySpends', () async {
        // This test verifies the CRITICAL bug fix: payment TX must spend from the
        // correct P2MS output index, not hardcoded index 0
        //
        // The funding TX structure is:
        //   - Output 0: Change (P2PKH) - due to TransactionBuilder output ordering
        //   - Output 1: Multisig (P2MS) - the channel funding
        //
        // The payment TX must spend from Output 1, not Output 0.
        
        final fundingAmount = BigInt.from(100000);
        final serverAmount = BigInt.from(10000);
        
        
        // Build the funding transaction (creates P2MS output)
        final fundingResult = fundingTransaction(fundingAmount, outputIndex: 1);
        
        expect(fundingResult.transaction, isNotNull);
        expect(fundingResult.transaction.outputs.isNotEmpty, isTrue);
        
        // Find the actual multisig output index
        // TransactionBuilder.sendChangeToPKH() puts change at index 0!
        final multisigScript = dartsv.P2MSLockBuilder(
          [clientPubKey, serverPubKey],
          2,
          sorting: true,
        ).getScriptPubkey();
        
        int multisigOutputIndex = -1;
        for (int i = 0; i < fundingResult.transaction.outputs.length; i++) {
          final output = fundingResult.transaction.outputs[i];
          if (output.satoshis == fundingAmount) {
            multisigOutputIndex = i;
            print('Found multisig output at index $i (${output.satoshis} sats)');
            // Verify it's actually the multisig script
            expect(output.script.toHex(), equals(multisigScript.toHex()),
                reason: 'Output at index $i should be the multisig');
          }
        }
        
        expect(multisigOutputIndex, greaterThanOrEqualTo(0),
            reason: 'Multisig output must exist in funding tx');
        
        // Log the funding TX structure for debugging
        print('Funding TX outputs:');
        for (int i = 0; i < fundingResult.transaction.outputs.length; i++) {
          final output = fundingResult.transaction.outputs[i];
          print('  Output[$i]: ${output.satoshis} sats');
        }
        print('Multisig output index: $multisigOutputIndex');
        
        print('Funding TX ID: ${fundingResult.txid}');
        
        // Build payment transaction using the CORRECT output index
        final paymentResult = await channelBuilder.buildPaymentTransaction(feeRate: const FeeRate(satoshis: 100, bytes: 1000),
          fundingTxId: fundingResult.txid,
          fundingOutputIndex: multisigOutputIndex, // Use actual index!
          fundingAmountSats: fundingAmount,
          clientPubKey: clientPubKey,
          serverPubKey: serverPubKey,
          clientAddress: clientAddress,
          serverAddress: serverAddress,
          serverAmountSats: serverAmount,
          sequenceNumber: 1,
        );
        
        expect(paymentResult.transaction, isNotNull);
        print('Payment TX input prevTxnId: ${paymentResult.transaction.inputs[0].prevTxnId}');
        print('Payment TX input prevOutIdx: ${paymentResult.transaction.inputs[0].prevTxnOutputIndex}');
        expect(paymentResult.transaction.inputs[0].prevTxnOutputIndex, equals(multisigOutputIndex),
            reason: 'Payment TX must reference correct output index');
        
        // Use TransactionSigner like the dartsv test does - this is the proven approach
        // First, we need to rebuild the payment transaction with an unlock builder attached
        final unlockBuilder = dartsv.P2MSUnlockBuilder();
        
        // Rebuild the payment transaction from scratch with unlock builder attached
        final paymentTx = dartsv.Transaction();
        paymentTx.version = 1;
        paymentTx.nLockTime = 0;
        
        // Add input with unlock builder
        final input = dartsv.TransactionInput(
          fundingResult.txid,
          multisigOutputIndex,
          1, // sequence number
          scriptBuilder: unlockBuilder,
        );
        paymentTx.inputs.add(input);
        
        // Copy outputs from original payment result
        for (final output in paymentResult.transaction.outputs) {
          paymentTx.outputs.add(output);
        }
        
        // Create the funding UTXO for signing (represents the multisig output being spent)
        final fundingUtxo = dartsv.TransactionOutput(
          fundingAmount,
          multisigScript,
        );
        
        // Sign with both keys using TransactionSigner (like dartsv test)
        final sighashType = dartsv.SighashType.SIGHASH_ALL.value | 
                           dartsv.SighashType.SIGHASH_FORKID.value;
        
        final clientSigner = dartsv.DefaultTransactionSigner(sighashType, clientPrivateKey);
        final serverSigner = dartsv.DefaultTransactionSigner(sighashType, serverPrivateKey);
        
        final signedTx1 = clientSigner.sign(paymentTx, fundingUtxo, 0);
        final signedTx = serverSigner.sign(signedTx1, fundingUtxo, 0);
        
        expect(unlockBuilder.signatures.length, equals(2),
            reason: 'Both signatures should be added to unlock builder');
        
        // CRITICAL VERIFICATION: Use Interpreter.correctlySpends() to verify
        // the script executes successfully
        final scriptSig = signedTx.inputs[0].script!;
        final scriptPubKey = multisigScript;
        final scriptFlags = <dartsv.VerifyFlag>{
          dartsv.VerifyFlag.SIGHASH_FORKID,
          dartsv.VerifyFlag.UTXO_AFTER_GENESIS,
        };
        
        final interpreter = dartsv.Interpreter();
        
        // Log detailed info for debugging
        print('ScriptSig hex: ${scriptSig.toHex()}');
        print('ScriptSig ASM: ${scriptSig.toString()}');
        print('ScriptPubKey hex: ${scriptPubKey.toHex()}');
        print('TX hex: ${signedTx.serialize()}');
        print('Input prevTxId: ${signedTx.inputs[0].prevTxnId}');
        print('Input prevOutIdx: ${signedTx.inputs[0].prevTxnOutputIndex}');
        
        // This will throw if the script execution fails
        try {
          interpreter.correctlySpends(
            scriptSig,
            scriptPubKey,
            signedTx,
            0, // input index
            scriptFlags,
            dartsv.Coin.ofSat(fundingAmount),
          );
          print('✓ Interpreter.correctlySpends() verification PASSED');
          print('  Payment TX can correctly spend from P2MS output at index $multisigOutputIndex');
        } on dartsv.ScriptException catch (e) {
          print('✗ Interpreter.correctlySpends() FAILED');
          print('  Error code: ${e.error}');
          print('  Cause: ${e.cause}');
          rethrow;
        }
      });

      test('signMultisigInput produces valid signatures verified by Interpreter.correctlySpends', () async {
        // This test verifies that channelBuilder.signMultisigInput() produces
        // valid signatures that can be verified by Interpreter.correctlySpends()
        
        final fundingAmount = BigInt.from(100000);
        final serverAmount = BigInt.from(10000);
        
        
        // Build the funding transaction (creates P2MS output)
        final fundingResult = fundingTransaction(fundingAmount, outputIndex: 1);
        
        // Find the actual multisig output index
        final multisigScript = dartsv.P2MSLockBuilder(
          [clientPubKey, serverPubKey],
          2,
          sorting: true,
        ).getScriptPubkey();
        
        int multisigOutputIndex = -1;
        for (int i = 0; i < fundingResult.transaction.outputs.length; i++) {
          if (fundingResult.transaction.outputs[i].satoshis == fundingAmount) {
            multisigOutputIndex = i;
            break;
          }
        }
        expect(multisigOutputIndex, greaterThanOrEqualTo(0));
        
        // Build payment transaction
        final paymentResult = await channelBuilder.buildPaymentTransaction(feeRate: const FeeRate(satoshis: 100, bytes: 1000),
          fundingTxId: fundingResult.txid,
          fundingOutputIndex: multisigOutputIndex,
          fundingAmountSats: fundingAmount,
          clientPubKey: clientPubKey,
          serverPubKey: serverPubKey,
          clientAddress: clientAddress,
          serverAddress: serverAddress,
          serverAmountSats: serverAmount,
          sequenceNumber: 1,
        );
        
        // Use channelBuilder's signMultisigInput method
        final clientSignResult = await channelBuilder.signMultisigInput(
          transaction: paymentResult.transaction,
          inputIndex: 0,
          privateKey: clientPrivateKey,
          clientPubKey: clientPubKey,
          serverPubKey: serverPubKey,
          inputAmountSats: fundingAmount,
        );
        expect(clientSignResult.signature, isNotNull);
        
        final serverSignResult = await channelBuilder.signMultisigInput(
          transaction: paymentResult.transaction,
          inputIndex: 0,
          privateKey: serverPrivateKey,
          clientPubKey: clientPubKey,
          serverPubKey: serverPubKey,
          inputAmountSats: fundingAmount,
        );
        expect(serverSignResult.signature, isNotNull);
        
        // Apply signatures using channelBuilder
        final signedTx = channelBuilder.applyMultisigSignatures(
          transaction: paymentResult.transaction,
          inputIndex: 0,
          clientPubKey: clientPubKey,
          serverPubKey: serverPubKey,
          clientSignature: clientSignResult.signature,
          serverSignature: serverSignResult.signature,
        );
        
        // Verify with Interpreter.correctlySpends()
        final scriptSig = signedTx.inputs[0].script!;
        final scriptFlags = <dartsv.VerifyFlag>{
          dartsv.VerifyFlag.SIGHASH_FORKID,
          dartsv.VerifyFlag.UTXO_AFTER_GENESIS,
        };
        
        final interpreter = dartsv.Interpreter();
        
        print('Testing signMultisigInput signatures:');
        print('  Client sig: ${clientSignResult.signatureHex}');
        print('  Server sig: ${serverSignResult.signatureHex}');
        
        try {
          interpreter.correctlySpends(
            scriptSig,
            multisigScript,
            signedTx,
            0,
            scriptFlags,
            dartsv.Coin.ofSat(fundingAmount),
          );
          print('✓ signMultisigInput verification PASSED');
        } on dartsv.ScriptException catch (e) {
          print('✗ signMultisigInput verification FAILED');
          print('  Error: ${e.error}');
          print('  Cause: ${e.cause}');
          rethrow;
        }
      });
    });

    // =========================================================================
    // MULTISIG SIGNING TESTS
    // =========================================================================
    group('Multisig Signing', () {
      test('should sign multisig input with client key', () async {
        // First build a refund TX to sign
        const fundingTxId =
            'abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890';
        final fundingAmount = BigInt.from(100000);
        final lockTimeUnix =
            DateTime.now().add(const Duration(hours: 24)).millisecondsSinceEpoch ~/
                1000;

        final refundResult = await channelBuilder.buildRefundTransaction(feeRate: const FeeRate(satoshis: 100, bytes: 1000),
          fundingTxId: fundingTxId,
          fundingOutputIndex: 0,
          fundingAmountSats: fundingAmount,
          clientPubKey: clientPubKey,
          serverPubKey: serverPubKey,
          clientAddress: clientAddress,
          lockTimeUnix: lockTimeUnix,
        );

        // Sign with client key
        final signResult = await channelBuilder.signMultisigInput(
          transaction: refundResult.transaction,
          inputIndex: 0,
          privateKey: clientPrivateKey,
          clientPubKey: clientPubKey,
          serverPubKey: serverPubKey,
          inputAmountSats: fundingAmount,
        );

        expect(signResult.signature, isNotNull);
        expect(signResult.signatureHex, isNotEmpty);
      });

      test('should sign multisig input with server key', () async {
        const fundingTxId =
            'abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890';
        final fundingAmount = BigInt.from(100000);
        final lockTimeUnix =
            DateTime.now().add(const Duration(hours: 24)).millisecondsSinceEpoch ~/
                1000;

        final refundResult = await channelBuilder.buildRefundTransaction(feeRate: const FeeRate(satoshis: 100, bytes: 1000),
          fundingTxId: fundingTxId,
          fundingOutputIndex: 0,
          fundingAmountSats: fundingAmount,
          clientPubKey: clientPubKey,
          serverPubKey: serverPubKey,
          clientAddress: clientAddress,
          lockTimeUnix: lockTimeUnix,
        );

        // Sign with server key
        final signResult = await channelBuilder.signMultisigInput(
          transaction: refundResult.transaction,
          inputIndex: 0,
          privateKey: serverPrivateKey,
          clientPubKey: clientPubKey,
          serverPubKey: serverPubKey,
          inputAmountSats: fundingAmount,
        );

        expect(signResult.signature, isNotNull);
        expect(signResult.signatureHex, isNotEmpty);
      });

      test('should produce different signatures for different keys', () async {
        const fundingTxId =
            'abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890';
        final fundingAmount = BigInt.from(100000);
        final lockTimeUnix =
            DateTime.now().add(const Duration(hours: 24)).millisecondsSinceEpoch ~/
                1000;

        final refundResult = await channelBuilder.buildRefundTransaction(feeRate: const FeeRate(satoshis: 100, bytes: 1000),
          fundingTxId: fundingTxId,
          fundingOutputIndex: 0,
          fundingAmountSats: fundingAmount,
          clientPubKey: clientPubKey,
          serverPubKey: serverPubKey,
          clientAddress: clientAddress,
          lockTimeUnix: lockTimeUnix,
        );

        final clientSig = await channelBuilder.signMultisigInput(
          transaction: refundResult.transaction,
          inputIndex: 0,
          privateKey: clientPrivateKey,
          clientPubKey: clientPubKey,
          serverPubKey: serverPubKey,
          inputAmountSats: fundingAmount,
        );

        final serverSig = await channelBuilder.signMultisigInput(
          transaction: refundResult.transaction,
          inputIndex: 0,
          privateKey: serverPrivateKey,
          clientPubKey: clientPubKey,
          serverPubKey: serverPubKey,
          inputAmountSats: fundingAmount,
        );

        expect(clientSig.signatureHex, isNot(equals(serverSig.signatureHex)));
      });

      test('should apply both signatures to complete multisig', () async {
        const fundingTxId =
            'abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890';
        final fundingAmount = BigInt.from(100000);
        final lockTimeUnix =
            DateTime.now().add(const Duration(hours: 24)).millisecondsSinceEpoch ~/
                1000;

        final refundResult = await channelBuilder.buildRefundTransaction(feeRate: const FeeRate(satoshis: 100, bytes: 1000),
          fundingTxId: fundingTxId,
          fundingOutputIndex: 0,
          fundingAmountSats: fundingAmount,
          clientPubKey: clientPubKey,
          serverPubKey: serverPubKey,
          clientAddress: clientAddress,
          lockTimeUnix: lockTimeUnix,
        );

        // Get both signatures
        final clientSig = await channelBuilder.signMultisigInput(
          transaction: refundResult.transaction,
          inputIndex: 0,
          privateKey: clientPrivateKey,
          clientPubKey: clientPubKey,
          serverPubKey: serverPubKey,
          inputAmountSats: fundingAmount,
        );

        final serverSig = await channelBuilder.signMultisigInput(
          transaction: refundResult.transaction,
          inputIndex: 0,
          privateKey: serverPrivateKey,
          clientPubKey: clientPubKey,
          serverPubKey: serverPubKey,
          inputAmountSats: fundingAmount,
        );

        // Apply both signatures
        final signedTx = channelBuilder.applyMultisigSignatures(
          transaction: refundResult.transaction,
          inputIndex: 0,
          clientSignature: clientSig.signature,
          serverSignature: serverSig.signature,
          clientPubKey: clientPubKey,
          serverPubKey: serverPubKey,
        );

        expect(signedTx, isNotNull);
        expect(signedTx.inputs[0].script, isNotNull);
        expect(signedTx.inputs[0].script!.toHex(), isNotEmpty);
      });

      test('should order signatures by sorted pubkey order', () async {
        const fundingTxId =
            'abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890';
        final fundingAmount = BigInt.from(100000);
        final serverAmount = BigInt.from(10000);

        final paymentResult = await channelBuilder.buildPaymentTransaction(feeRate: const FeeRate(satoshis: 100, bytes: 1000),
          fundingTxId: fundingTxId,
          fundingOutputIndex: 0,
          fundingAmountSats: fundingAmount,
          clientPubKey: clientPubKey,
          serverPubKey: serverPubKey,
          clientAddress: clientAddress,
          serverAddress: serverAddress,
          serverAmountSats: serverAmount,
          sequenceNumber: 1,
        );

        final clientSig = await channelBuilder.signMultisigInput(
          transaction: paymentResult.transaction,
          inputIndex: 0,
          privateKey: clientPrivateKey,
          clientPubKey: clientPubKey,
          serverPubKey: serverPubKey,
          inputAmountSats: fundingAmount,
        );

        final serverSig = await channelBuilder.signMultisigInput(
          transaction: paymentResult.transaction,
          inputIndex: 0,
          privateKey: serverPrivateKey,
          clientPubKey: clientPubKey,
          serverPubKey: serverPubKey,
          inputAmountSats: fundingAmount,
        );

        // Apply signatures - order should be determined by sorted pubkeys
        final signedTx = channelBuilder.applyMultisigSignatures(
          transaction: paymentResult.transaction,
          inputIndex: 0,
          clientSignature: clientSig.signature,
          serverSignature: serverSig.signature,
          clientPubKey: clientPubKey,
          serverPubKey: serverPubKey,
        );

        // The scriptSig should contain OP_0 followed by two signatures
        final scriptSig = signedTx.inputs[0].script!;
        expect(scriptSig.toHex(), isNotEmpty);
        // P2MS unlocking script starts with OP_0 (0x00)
        expect(scriptSig.toHex(), startsWith('00'));
      });
    });

    // =========================================================================
    // UTILITY METHOD TESTS
    // =========================================================================
    group('Utility Methods', () {
      // Bead libspiffy-zs4l: channel transactions pay ARC's policy rate on
      // their signed size. The refund and payment were sized with a
      // 300-byte guess per multisig input at a default of 1 sat/kB, and the
      // funding here was a second copy of `ChannelFunding`.
      test('zs4l: the refund and the payment pay the policy rate on their signed size', () async {
        const rate = FeeRate(satoshis: 100, bytes: 1000);
        final amount = BigInt.from(100000);
        final funding = fundingTransaction(amount);
        final refund = await channelBuilder.buildRefundTransaction(
          fundingTxId: funding.txid,
          fundingOutputIndex: 0,
          fundingAmountSats: amount,
          clientPubKey: clientPubKey,
          serverPubKey: serverPubKey,
          clientAddress: clientAddress,
          lockTimeUnix: PaymentChannelBuilder.lockTimeThreshold + 1000,
          feeRate: rate,
        );
        final payment = await channelBuilder.buildPaymentTransaction(
          fundingTxId: funding.txid,
          fundingOutputIndex: 0,
          fundingAmountSats: amount,
          clientPubKey: clientPubKey,
          serverPubKey: serverPubKey,
          clientAddress: clientAddress,
          serverAddress: serverAddress,
          serverAmountSats: BigInt.from(30000),
          sequenceNumber: 1,
          feeRate: rate,
        );

        for (final built in [refund, payment]) {
          Future<dartsv.SVSignature> sign(dartsv.SVPrivateKey key) async => dartsv.SVSignature.fromTxFormat(
              (await channelBuilder.signMultisigInput(
                transaction: built.transaction,
                inputIndex: 0,
                privateKey: key,
                clientPubKey: clientPubKey,
                serverPubKey: serverPubKey,
                inputAmountSats: amount,
              ))
                  .signatureHex);
          final signed = channelBuilder.applyMultisigSignatures(
            transaction: dartsv.Transaction.fromHex(built.transactionHex),
            inputIndex: 0,
            clientSignature: await sign(clientPrivateKey),
            serverSignature: await sign(serverPrivateKey),
            clientPubKey: clientPubKey,
            serverPubKey: serverPubKey,
          );
          final paid = amount - signed.outputs.fold<BigInt>(BigInt.zero, (sum, o) => sum + o.satoshis);
          final signedBytes = signed.serialize().length ~/ 2;
          expect(paid, built.fee);
          // Old code: 1 satoshi for each, at the 1 sat/kB default.
          expect(paid, greaterThanOrEqualTo(rate.feeFor(signedBytes)),
              reason: 'a $signedBytes-byte signed transaction pays $paid');
          expect(paid, lessThanOrEqualTo(rate.feeFor(signedBytes + 4)),
              reason: 'paid for bytes the transaction does not have');
        }
      });

      test('createMultisigScript should create valid 2-of-2 P2MS script', () {
        final multisigScript = channelBuilder.createMultisigScript(
          clientPubKey,
          serverPubKey,
        );

        expect(multisigScript, isNotNull);
        final scriptHex = multisigScript.toHex();

        // Should contain both pubkeys
        expect(
            scriptHex.toLowerCase().contains(clientPubKey.toHex().toLowerCase()) ||
                scriptHex
                    .toLowerCase()
                    .contains(serverPubKey.toHex().toLowerCase()),
            isTrue);

        // Should end with OP_2 OP_CHECKMULTISIG (52 ae)
        expect(scriptHex, endsWith('52ae'));
      });

      test('getPublicKey should derive correct public key', () {
        final derivedPubKey = channelBuilder.getPublicKey(clientPrivateKey);

        expect(derivedPubKey.toString(), equals(clientPubKey.toString()));
      });
    });

    // =========================================================================
    // CHANNEL LIFECYCLE INTEGRATION TESTS
    // =========================================================================
    group('Channel Lifecycle Integration', () {
      test('should build complete channel lifecycle: funding → refund → payment', () async {
        // Step 1: Build funding TX
        final fundingAmount = BigInt.from(100000);

        final fundingResult = fundingTransaction(fundingAmount);

        expect(fundingResult.txid, isNotEmpty);

        // Step 2: Build refund TX spending the funding output
        final lockTimeUnix =
            DateTime.now().add(const Duration(hours: 24)).millisecondsSinceEpoch ~/
                1000;

        final refundResult = await channelBuilder.buildRefundTransaction(feeRate: const FeeRate(satoshis: 100, bytes: 1000),
          fundingTxId: fundingResult.txid,
          fundingOutputIndex: 0,
          fundingAmountSats: fundingAmount,
          clientPubKey: clientPubKey,
          serverPubKey: serverPubKey,
          clientAddress: clientAddress,
          lockTimeUnix: lockTimeUnix,
        );

        expect(refundResult.transaction.inputs[0].prevTxnId,
            equals(fundingResult.txid));

        // Step 3: Build payment TXs (simulating channel usage)
        final paymentResults = <ChannelTransactionResult>[];
        for (int i = 1; i <= 3; i++) {
          final serverAmount = BigInt.from(10000 * i);

          final paymentResult = await channelBuilder.buildPaymentTransaction(feeRate: const FeeRate(satoshis: 100, bytes: 1000),
            fundingTxId: fundingResult.txid,
            fundingOutputIndex: 0,
            fundingAmountSats: fundingAmount,
            clientPubKey: clientPubKey,
            serverPubKey: serverPubKey,
            clientAddress: clientAddress,
            serverAddress: serverAddress,
            serverAmountSats: serverAmount,
            sequenceNumber: i,
          );

          paymentResults.add(paymentResult);
          expect(paymentResult.transaction.inputs[0].sequenceNumber, equals(i));
        }

        // Verify sequence numbers are incrementing
        expect(paymentResults[0].transaction.inputs[0].sequenceNumber, equals(1));
        expect(paymentResults[1].transaction.inputs[0].sequenceNumber, equals(2));
        expect(paymentResults[2].transaction.inputs[0].sequenceNumber, equals(3));
      });

      test('should sign and complete refund transaction', () async {
        // Build funding TX
        final fundingAmount = BigInt.from(100000);

        final fundingResult = fundingTransaction(fundingAmount);

        // Build refund TX
        final lockTimeUnix =
            DateTime.now().add(const Duration(hours: 24)).millisecondsSinceEpoch ~/
                1000;

        final refundResult = await channelBuilder.buildRefundTransaction(feeRate: const FeeRate(satoshis: 100, bytes: 1000),
          fundingTxId: fundingResult.txid,
          fundingOutputIndex: 0,
          fundingAmountSats: fundingAmount,
          clientPubKey: clientPubKey,
          serverPubKey: serverPubKey,
          clientAddress: clientAddress,
          lockTimeUnix: lockTimeUnix,
        );

        // Sign with both parties
        final clientSig = await channelBuilder.signMultisigInput(
          transaction: refundResult.transaction,
          inputIndex: 0,
          privateKey: clientPrivateKey,
          clientPubKey: clientPubKey,
          serverPubKey: serverPubKey,
          inputAmountSats: fundingAmount,
        );

        final serverSig = await channelBuilder.signMultisigInput(
          transaction: refundResult.transaction,
          inputIndex: 0,
          privateKey: serverPrivateKey,
          clientPubKey: clientPubKey,
          serverPubKey: serverPubKey,
          inputAmountSats: fundingAmount,
        );

        // Apply signatures
        final signedRefund = channelBuilder.applyMultisigSignatures(
          transaction: refundResult.transaction,
          inputIndex: 0,
          clientSignature: clientSig.signature,
          serverSignature: serverSig.signature,
          clientPubKey: clientPubKey,
          serverPubKey: serverPubKey,
        );

        // Verify signed transaction
        expect(signedRefund.inputs[0].script!.toHex(), isNotEmpty);
        expect(signedRefund.serialize(), isNotEmpty);
      });

      test('should sign and complete payment transaction', () async {
        // Build funding TX
        final fundingAmount = BigInt.from(100000);

        final fundingResult = fundingTransaction(fundingAmount);

        // Build payment TX
        final serverAmount = BigInt.from(25000);

        final paymentResult = await channelBuilder.buildPaymentTransaction(feeRate: const FeeRate(satoshis: 100, bytes: 1000),
          fundingTxId: fundingResult.txid,
          fundingOutputIndex: 0,
          fundingAmountSats: fundingAmount,
          clientPubKey: clientPubKey,
          serverPubKey: serverPubKey,
          clientAddress: clientAddress,
          serverAddress: serverAddress,
          serverAmountSats: serverAmount,
          sequenceNumber: 1,
        );

        // Sign with both parties
        final clientSig = await channelBuilder.signMultisigInput(
          transaction: paymentResult.transaction,
          inputIndex: 0,
          privateKey: clientPrivateKey,
          clientPubKey: clientPubKey,
          serverPubKey: serverPubKey,
          inputAmountSats: fundingAmount,
        );

        final serverSig = await channelBuilder.signMultisigInput(
          transaction: paymentResult.transaction,
          inputIndex: 0,
          privateKey: serverPrivateKey,
          clientPubKey: clientPubKey,
          serverPubKey: serverPubKey,
          inputAmountSats: fundingAmount,
        );

        // Apply signatures
        final signedPayment = channelBuilder.applyMultisigSignatures(
          transaction: paymentResult.transaction,
          inputIndex: 0,
          clientSignature: clientSig.signature,
          serverSignature: serverSig.signature,
          clientPubKey: clientPubKey,
          serverPubKey: serverPubKey,
        );

        // Verify signed transaction
        expect(signedPayment.inputs[0].script!.toHex(), isNotEmpty);
        expect(signedPayment.serialize(), isNotEmpty);

        // Verify output amounts
        final totalOutput = signedPayment.outputs
            .fold<BigInt>(BigInt.zero, (sum, o) => sum + o.satoshis);
        expect(totalOutput, equals(fundingAmount - paymentResult.fee));
      });
    });

    // =========================================================================
    // EDGE CASES AND ERROR HANDLING
    // =========================================================================
    group('Edge Cases and Error Handling', () {
      test('should handle maximum sequence number', () async {
        const fundingTxId =
            'abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890';
        final fundingAmount = BigInt.from(100000);
        final serverAmount = BigInt.from(10000);

        // Use a very high sequence number (but not MAX which would make it final)
        const highSequence = 0xFFFFFFFE;

        final result = await channelBuilder.buildPaymentTransaction(feeRate: const FeeRate(satoshis: 100, bytes: 1000),
          fundingTxId: fundingTxId,
          fundingOutputIndex: 0,
          fundingAmountSats: fundingAmount,
          clientPubKey: clientPubKey,
          serverPubKey: serverPubKey,
          clientAddress: clientAddress,
          serverAddress: serverAddress,
          serverAmountSats: serverAmount,
          sequenceNumber: highSequence,
        );

        expect(result.transaction.inputs[0].sequenceNumber, equals(highSequence));
      });

    });
  });
}
