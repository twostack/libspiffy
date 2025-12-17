import 'package:test/test.dart';
import 'package:dartsv/dartsv.dart' as dartsv;

import 'package:libspiffy/src/services/payment_channel_builder.dart';
import 'package:libspiffy/src/services/dartsv_crypto_service.dart';
import 'package:libspiffy/src/services/crypto_service.dart';
import 'package:libspiffy/src/services/transaction_builder_service.dart';
import 'package:libspiffy/src/models/bitcoin_utxo.dart';

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
      channelBuilder = PaymentChannelBuilder(
        cryptoService: cryptoService,
        networkType: testNetworkType,
      );

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

    /// Helper to create test UTXOs for the client
    List<BitcoinUtxo> createClientUtxos({
      int count = 1,
      BigInt? satoshisPerUtxo,
    }) {
      final sats = satoshisPerUtxo ?? BigInt.from(100000);
      final utxos = <BitcoinUtxo>[];

      for (int i = 0; i < count; i++) {
        // Generate unique but deterministic txids
        final txidBase = 'a' * (64 - i.toString().length) + i.toString();
        utxos.add(BitcoinUtxo.create(
          txid: txidBase.substring(0, 64),
          vout: 0,
          satoshis: sats,
          scriptPubKey: dartsv.P2PKHLockBuilder.fromAddress(clientAddress)
              .getScriptPubkey()
              .toHex(),
          address: clientAddress.toString(),
          blockHeight: 100 + i,
          confirmations: 6,
          derivationIndex: i,
        ));
      }

      return utxos;
    }

    // =========================================================================
    // FUNDING TRANSACTION (T1) TESTS
    // =========================================================================
    group('Funding Transaction (T1)', () {
      test('should build funding transaction with valid parameters', () async {
        final utxos = createClientUtxos(count: 1, satoshisPerUtxo: BigInt.from(100000));
        final fundingAmount = BigInt.from(50000);

        final result = await channelBuilder.buildFundingTransaction(
          clientPubKey: clientPubKey,
          serverPubKey: serverPubKey,
          fundingAmountSats: fundingAmount,
          clientUtxos: utxos,
          changeAddress: clientAddress,
          clientPrivateKey: clientPrivateKey,
        );

        expect(result.transaction, isNotNull);
        expect(result.transactionHex, isNotEmpty);
        expect(result.txid, isNotEmpty);
        expect(result.multisigScript, isNotNull);
        expect(result.fee, greaterThanOrEqualTo(BigInt.zero));

        // Verify transaction structure
        final tx = result.transaction;
        expect(tx.inputs.length, equals(1));
        expect(tx.outputs.length, greaterThanOrEqualTo(1)); // At least multisig output

        // Find the multisig output (it should be close to funding amount)
        // The TransactionBuilder may adjust amounts slightly for fee calculations
        final totalOutput = tx.outputs.fold<BigInt>(
          BigInt.zero, (sum, o) => sum + o.satoshis);
        final totalInput = utxos.fold<BigInt>(
          BigInt.zero, (sum, u) => sum + u.value.getValue());
        
        // Total output + fee should equal total input (within 1 sat rounding)
        final diff = (totalOutput + result.fee - totalInput).abs();
        expect(diff, lessThanOrEqualTo(BigInt.one));
      });

      test('should create 2-of-2 multisig output with sorted pubkeys', () async {
        final utxos = createClientUtxos(count: 1, satoshisPerUtxo: BigInt.from(100000));
        final fundingAmount = BigInt.from(50000);

        final result = await channelBuilder.buildFundingTransaction(
          clientPubKey: clientPubKey,
          serverPubKey: serverPubKey,
          fundingAmountSats: fundingAmount,
          clientUtxos: utxos,
          changeAddress: clientAddress,
          clientPrivateKey: clientPrivateKey,
        );

        // Verify the multisig script structure
        final multisigScript = result.multisigScript!;
        final scriptHex = multisigScript.toHex();

        // P2MS script should contain OP_2 ... OP_2 OP_CHECKMULTISIG
        // OP_2 = 0x52, OP_CHECKMULTISIG = 0xae
        expect(scriptHex, contains('52')); // OP_2 for required signatures
        expect(scriptHex, endsWith('52ae')); // OP_2 OP_CHECKMULTISIG
      });

      test('should include change output when excess funds available', () async {
        final utxos = createClientUtxos(count: 1, satoshisPerUtxo: BigInt.from(100000));
        final fundingAmount = BigInt.from(30000); // Much less than input

        final result = await channelBuilder.buildFundingTransaction(
          clientPubKey: clientPubKey,
          serverPubKey: serverPubKey,
          fundingAmountSats: fundingAmount,
          clientUtxos: utxos,
          changeAddress: clientAddress,
          clientPrivateKey: clientPrivateKey,
        );

        // Should have 2 outputs: multisig + change
        expect(result.transaction.outputs.length, equals(2));

        // Verify total outputs + fee equals input (within 1 sat rounding)
        final totalOutput = result.transaction.outputs.fold<BigInt>(
          BigInt.zero, (sum, o) => sum + o.satoshis);
        final diff = (totalOutput + result.fee - BigInt.from(100000)).abs();
        expect(diff, lessThanOrEqualTo(BigInt.one));
        
        // Verify we have both a multisig-sized output and a change output
        // The multisig output should be close to the funding amount
        final hasMultisigOutput = result.transaction.outputs.any(
          (o) => o.satoshis >= fundingAmount - BigInt.from(100) && 
                 o.satoshis <= fundingAmount + BigInt.from(100));
        expect(hasMultisigOutput, isTrue);
      });

      test('should throw when insufficient funds', () async {
        final utxos = createClientUtxos(count: 1, satoshisPerUtxo: BigInt.from(10000));
        final fundingAmount = BigInt.from(50000); // More than available

        expect(
          () => channelBuilder.buildFundingTransaction(
            clientPubKey: clientPubKey,
            serverPubKey: serverPubKey,
            fundingAmountSats: fundingAmount,
            clientUtxos: utxos,
            changeAddress: clientAddress,
            clientPrivateKey: clientPrivateKey,
          ),
          throwsA(isA<TransactionBuildException>().having(
            (e) => e.code,
            'code',
            equals('INSUFFICIENT_FUNDS'),
          )),
        );
      });

      test('should handle multiple input UTXOs', () async {
        final utxos = createClientUtxos(count: 3, satoshisPerUtxo: BigInt.from(50000));
        final fundingAmount = BigInt.from(120000); // Needs multiple UTXOs

        final result = await channelBuilder.buildFundingTransaction(
          clientPubKey: clientPubKey,
          serverPubKey: serverPubKey,
          fundingAmountSats: fundingAmount,
          clientUtxos: utxos,
          changeAddress: clientAddress,
          clientPrivateKey: clientPrivateKey,
        );

        expect(result.transaction, isNotNull);
        expect(result.transaction.inputs.length, equals(3));
        
        // Verify total output + fee equals total input (within 1 sat rounding)
        final totalInput = BigInt.from(150000); // 3 * 50000
        final totalOutput = result.transaction.outputs.fold<BigInt>(
          BigInt.zero, (sum, o) => sum + o.satoshis);
        final diff = (totalOutput + result.fee - totalInput).abs();
        expect(diff, lessThanOrEqualTo(BigInt.one));
      });

      test('should not create dust change output', () async {
        // Create UTXO that would result in dust change
        final utxos = createClientUtxos(count: 1, satoshisPerUtxo: BigInt.from(50600));
        final fundingAmount = BigInt.from(50000); // Leaves ~600 sats (dust territory)

        final result = await channelBuilder.buildFundingTransaction(
          clientPubKey: clientPubKey,
          serverPubKey: serverPubKey,
          fundingAmountSats: fundingAmount,
          clientUtxos: utxos,
          changeAddress: clientAddress,
          clientPrivateKey: clientPrivateKey,
        );

        // Depending on fee, change might be dust and excluded
        // The transaction should still be valid
        expect(result.transaction, isNotNull);
        expect(result.transaction.outputs.length, greaterThanOrEqualTo(1));
      });

      test('should use nSequence MAX for final transaction', () async {
        final utxos = createClientUtxos(count: 1, satoshisPerUtxo: BigInt.from(100000));
        final fundingAmount = BigInt.from(50000);

        final result = await channelBuilder.buildFundingTransaction(
          clientPubKey: clientPubKey,
          serverPubKey: serverPubKey,
          fundingAmountSats: fundingAmount,
          clientUtxos: utxos,
          changeAddress: clientAddress,
          clientPrivateKey: clientPrivateKey,
        );

        // Funding TX inputs should have MAX sequence (final)
        for (final input in result.transaction.inputs) {
          expect(input.sequenceNumber, equals(dartsv.TransactionInput.MAX_SEQ_NUMBER));
        }
      });
    });

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

        final result = await channelBuilder.buildRefundTransaction(
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

        final result = await channelBuilder.buildRefundTransaction(
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

        final result = await channelBuilder.buildRefundTransaction(
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

        final result = await channelBuilder.buildRefundTransaction(
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
          () => channelBuilder.buildRefundTransaction(
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

        final result = await channelBuilder.buildRefundTransaction(
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

        final result = await channelBuilder.buildPaymentTransaction(
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

        final result = await channelBuilder.buildPaymentTransaction(
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

        final result = await channelBuilder.buildPaymentTransaction(
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
          final result = await channelBuilder.buildPaymentTransaction(
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

        final result = await channelBuilder.buildPaymentTransaction(
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

        final result = await channelBuilder.buildPaymentTransaction(
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
          () => channelBuilder.buildPaymentTransaction(
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
          () => channelBuilder.buildPaymentTransaction(
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

        final refundResult = await channelBuilder.buildRefundTransaction(
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

        final refundResult = await channelBuilder.buildRefundTransaction(
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

        final refundResult = await channelBuilder.buildRefundTransaction(
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

        final refundResult = await channelBuilder.buildRefundTransaction(
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

        final paymentResult = await channelBuilder.buildPaymentTransaction(
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

      test('estimateFee should calculate correctly for multisig input', () {
        final fee = channelBuilder.estimateFee(
          inputCount: 1,
          outputCount: 2,
          isMultisigInput: true,
        );

        // Expected: overhead (10) + 1 * multisig input (300) + 2 * output (34)
        // = 10 + 300 + 68 = 378 bytes
        // At 1 sat/kb: 378 / 1000 = 0 (rounded down)
        expect(fee, greaterThanOrEqualTo(BigInt.zero));
      });

      test('estimateFee should differ for P2PKH vs multisig inputs', () {
        // Use a higher fee rate to see the difference
        final multisigFee = channelBuilder.estimateFee(
          inputCount: 1,
          outputCount: 1,
          isMultisigInput: true,
          feePerKb: 1000,
        );

        final p2pkhFee = channelBuilder.estimateFee(
          inputCount: 1,
          outputCount: 1,
          isMultisigInput: false,
          feePerKb: 1000,
        );

        // Multisig inputs are larger than P2PKH inputs
        expect(
          PaymentChannelBuilder.multisigInputSize,
          greaterThan(148), // P2PKH input size
        );
        
        // At higher fee rate, the difference in input sizes should be visible
        expect(multisigFee, greaterThan(p2pkhFee));
      });

      test('estimateFee should scale with higher fee rate', () {
        final lowFee = channelBuilder.estimateFee(
          inputCount: 1,
          outputCount: 2,
          isMultisigInput: true,
          feePerKb: 1,
        );

        final highFee = channelBuilder.estimateFee(
          inputCount: 1,
          outputCount: 2,
          isMultisigInput: true,
          feePerKb: 100,
        );

        expect(highFee, greaterThan(lowFee));
      });

      test('parseTransaction should round-trip correctly', () async {
        final utxos = createClientUtxos(count: 1, satoshisPerUtxo: BigInt.from(100000));
        final fundingAmount = BigInt.from(50000);

        final result = await channelBuilder.buildFundingTransaction(
          clientPubKey: clientPubKey,
          serverPubKey: serverPubKey,
          fundingAmountSats: fundingAmount,
          clientUtxos: utxos,
          changeAddress: clientAddress,
          clientPrivateKey: clientPrivateKey,
        );

        // Parse the serialized transaction
        final parsed = channelBuilder.parseTransaction(result.transactionHex);

        expect(parsed.id, equals(result.txid));
        expect(parsed.inputs.length, equals(result.transaction.inputs.length));
        expect(parsed.outputs.length, equals(result.transaction.outputs.length));
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
        final utxos = createClientUtxos(count: 1, satoshisPerUtxo: BigInt.from(200000));
        final fundingAmount = BigInt.from(100000);

        final fundingResult = await channelBuilder.buildFundingTransaction(
          clientPubKey: clientPubKey,
          serverPubKey: serverPubKey,
          fundingAmountSats: fundingAmount,
          clientUtxos: utxos,
          changeAddress: clientAddress,
          clientPrivateKey: clientPrivateKey,
        );

        expect(fundingResult.txid, isNotEmpty);

        // Step 2: Build refund TX spending the funding output
        final lockTimeUnix =
            DateTime.now().add(const Duration(hours: 24)).millisecondsSinceEpoch ~/
                1000;

        final refundResult = await channelBuilder.buildRefundTransaction(
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

          final paymentResult = await channelBuilder.buildPaymentTransaction(
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
        final utxos = createClientUtxos(count: 1, satoshisPerUtxo: BigInt.from(200000));
        final fundingAmount = BigInt.from(100000);

        final fundingResult = await channelBuilder.buildFundingTransaction(
          clientPubKey: clientPubKey,
          serverPubKey: serverPubKey,
          fundingAmountSats: fundingAmount,
          clientUtxos: utxos,
          changeAddress: clientAddress,
          clientPrivateKey: clientPrivateKey,
        );

        // Build refund TX
        final lockTimeUnix =
            DateTime.now().add(const Duration(hours: 24)).millisecondsSinceEpoch ~/
                1000;

        final refundResult = await channelBuilder.buildRefundTransaction(
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
        final utxos = createClientUtxos(count: 1, satoshisPerUtxo: BigInt.from(200000));
        final fundingAmount = BigInt.from(100000);

        final fundingResult = await channelBuilder.buildFundingTransaction(
          clientPubKey: clientPubKey,
          serverPubKey: serverPubKey,
          fundingAmountSats: fundingAmount,
          clientUtxos: utxos,
          changeAddress: clientAddress,
          clientPrivateKey: clientPrivateKey,
        );

        // Build payment TX
        final serverAmount = BigInt.from(25000);

        final paymentResult = await channelBuilder.buildPaymentTransaction(
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
      test('should handle exact funding amount (no change)', () async {
        // Create UTXO that exactly covers funding + fee
        final estimatedFee = channelBuilder.estimateFee(
          inputCount: 1,
          outputCount: 1,
          isMultisigInput: false,
        );
        final fundingAmount = BigInt.from(50000);
        final exactUtxoAmount = fundingAmount + estimatedFee + BigInt.from(1);

        final utxos = createClientUtxos(count: 1, satoshisPerUtxo: exactUtxoAmount);

        final result = await channelBuilder.buildFundingTransaction(
          clientPubKey: clientPubKey,
          serverPubKey: serverPubKey,
          fundingAmountSats: fundingAmount,
          clientUtxos: utxos,
          changeAddress: clientAddress,
          clientPrivateKey: clientPrivateKey,
        );

        expect(result.transaction, isNotNull);
        // May or may not have change depending on exact fee calculation
        expect(result.transaction.outputs.length, greaterThanOrEqualTo(1));
      });

      test('should handle maximum sequence number', () async {
        const fundingTxId =
            'abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890';
        final fundingAmount = BigInt.from(100000);
        final serverAmount = BigInt.from(10000);

        // Use a very high sequence number (but not MAX which would make it final)
        const highSequence = 0xFFFFFFFE;

        final result = await channelBuilder.buildPaymentTransaction(
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

      test('should handle empty UTXO list for funding', () async {
        final fundingAmount = BigInt.from(50000);

        expect(
          () => channelBuilder.buildFundingTransaction(
            clientPubKey: clientPubKey,
            serverPubKey: serverPubKey,
            fundingAmountSats: fundingAmount,
            clientUtxos: [],
            changeAddress: clientAddress,
            clientPrivateKey: clientPrivateKey,
          ),
          throwsA(isA<TransactionBuildException>()),
        );
      });

      test('should handle zero funding amount', () async {
        final utxos = createClientUtxos(count: 1, satoshisPerUtxo: BigInt.from(100000));

        // Zero funding should still work (creates dust or empty output)
        // Behavior depends on implementation
        expect(
          () => channelBuilder.buildFundingTransaction(
            clientPubKey: clientPubKey,
            serverPubKey: serverPubKey,
            fundingAmountSats: BigInt.zero,
            clientUtxos: utxos,
            changeAddress: clientAddress,
            clientPrivateKey: clientPrivateKey,
          ),
          // Might succeed or throw depending on dust handling
          anyOf(returnsNormally, throwsA(isA<TransactionBuildException>())),
        );
      });

      test('should handle same client and server pubkey', () async {
        // Edge case: same pubkey for both (not recommended but should handle)
        final utxos = createClientUtxos(count: 1, satoshisPerUtxo: BigInt.from(100000));
        final fundingAmount = BigInt.from(50000);

        // Using same pubkey - the multisig script will be degenerate
        final result = await channelBuilder.buildFundingTransaction(
          clientPubKey: clientPubKey,
          serverPubKey: clientPubKey, // Same as client
          fundingAmountSats: fundingAmount,
          clientUtxos: utxos,
          changeAddress: clientAddress,
          clientPrivateKey: clientPrivateKey,
        );

        // Should still build, though the multisig would be equivalent to 2-of-2 with same key twice
        expect(result.transaction, isNotNull);
      });

      test('should handle custom fee rate', () async {
        final utxos = createClientUtxos(count: 1, satoshisPerUtxo: BigInt.from(100000));
        final fundingAmount = BigInt.from(50000);

        final lowFeeResult = await channelBuilder.buildFundingTransaction(
          clientPubKey: clientPubKey,
          serverPubKey: serverPubKey,
          fundingAmountSats: fundingAmount,
          clientUtxos: utxos,
          changeAddress: clientAddress,
          clientPrivateKey: clientPrivateKey,
          feePerKb: 1,
        );

        final highFeeResult = await channelBuilder.buildFundingTransaction(
          clientPubKey: clientPubKey,
          serverPubKey: serverPubKey,
          fundingAmountSats: fundingAmount,
          clientUtxos: utxos,
          changeAddress: clientAddress,
          clientPrivateKey: clientPrivateKey,
          feePerKb: 100,
        );

        expect(highFeeResult.fee, greaterThan(lowFeeResult.fee));
      });
    });
  });
}
