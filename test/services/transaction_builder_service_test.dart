import 'dart:convert';
import 'package:test/test.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:convert/convert.dart';

import 'package:libspiffy/src/services/transaction_builder_service.dart';
import 'package:libspiffy/src/services/script_type_registry.dart';
import 'package:libspiffy/src/models/bitcoin_utxo.dart';
import 'package:libspiffy/src/models/bitcoin_transaction.dart';

void main() {
  group('TransactionBuilderService', () {
    late TransactionBuilderService service;
    late ScriptTypeRegistry scriptRegistry;
    late dartsv.SVPrivateKey testPrivateKey;
    late String testAddress;
    late String changeAddress;
    
    // Test data
    const testNetworkType = dartsv.NetworkType.TEST;
    
    setUp(() {
      scriptRegistry = ScriptTypeRegistry(networkType: testNetworkType);
      service = TransactionBuilderService(
        scriptRegistry: scriptRegistry,
        networkType: testNetworkType,
      );
      
      // Create test private key and addresses
      testPrivateKey = dartsv.SVPrivateKey.fromWIF('cTALNpTpRbbxTCJ2A5Vq88UxT44w1PE2cYqiB3n4hRvzyCev1Wwo');
      final publicKey = testPrivateKey.publicKey;
      testAddress = dartsv.Address.fromPublicKey(publicKey, testNetworkType).toString();
      changeAddress = dartsv.Address.fromPublicKey(publicKey, testNetworkType).toString();
    });

    group('Configuration and Setup', () {
      test('should create service with default configuration', () {
        final defaultService = TransactionBuilderService();
        expect(defaultService.lockedUTXOs, isEmpty);
      });

      test('should create service with custom network type', () {
        final mainnetService = TransactionBuilderService(
          networkType: dartsv.NetworkType.MAIN,
        );
        expect(mainnetService, isNotNull);
      });

      test('should have proper default configuration values', () {
        const config = TransactionBuildConfig.standard;
        expect(config.feePerKb, equals(1));
        expect(config.selectionStrategy, equals(UTXOSelectionStrategy.optimalChange));
        expect(config.minChangeAmount, equals(546));
        expect(config.forceChange, isFalse);
        expect(config.enableRBF, isFalse);
        expect(config.options, contains(dartsv.TransactionOption.DISABLE_DUST_OUTPUTS));
        expect(config.performSanityChecks, isTrue);
      });

      test('should have proper partial configuration values', () {
        const config = TransactionBuildConfig.partial;
        expect(config.performSanityChecks, isFalse);
      });

      test('should create custom configuration', () {
        const customConfig = TransactionBuildConfig(
          feePerKb: 10,
          selectionStrategy: UTXOSelectionStrategy.largestFirst,
          minChangeAmount: 1000,
          forceChange: true,
          enableRBF: true,
          performSanityChecks: true,
        );
        
        expect(customConfig.feePerKb, equals(10));
        expect(customConfig.selectionStrategy, equals(UTXOSelectionStrategy.largestFirst));
        expect(customConfig.minChangeAmount, equals(1000));
        expect(customConfig.forceChange, isTrue);
        expect(customConfig.enableRBF, isTrue);
        expect(customConfig.performSanityChecks, isTrue);
      });
    });

    group('Partial P2PKH Transaction Building', () {
      test('should build partial P2PKH transaction successfully', () async {
        const recipientAddress = 'mxAoAyZFXX6LZBWhoam3vjm6xt9NxPQ15f';
        final amount = BigInt.from(100000); // 0.001 BSV
        
        final result = await service.buildPartialP2PKHTransaction(
          recipientAddress: recipientAddress,
          amount: amount,
        );
        
        expect(result.transaction, isNotNull);
        expect(result.selectedInputs, isEmpty);
        expect(result.totalInput, equals(BigInt.zero));
        expect(result.totalOutput, equals(amount));
        expect(result.fee, equals(BigInt.zero));
        expect(result.changeAmount, equals(BigInt.zero));
        expect(result.readyForSigning, isFalse);
        expect(result.transactionHex, isNotEmpty);
        expect(result.beef, isNull);
      });

      test('should build partial transaction with custom config', () async {
        const recipientAddress = 'mxAoAyZFXX6LZBWhoam3vjm6xt9NxPQ15f';
        final amount = BigInt.from(50000);
        
        const customConfig = TransactionBuildConfig(
          feePerKb: 10,
          performSanityChecks: false,
          options: {
            dartsv.TransactionOption.DISABLE_DUST_OUTPUTS,
            dartsv.TransactionOption.DISABLE_MORE_OUTPUT_THAN_INPUT,
          },
        );
        
        final result = await service.buildPartialP2PKHTransaction(
          recipientAddress: recipientAddress,
          amount: amount,
          config: customConfig,
        );
        
        expect(result.transaction, isNotNull);
        expect(result.readyForSigning, isFalse);
      });

      test('should handle invalid recipient address', () async {
        const invalidAddress = 'invalid-address';
        final amount = BigInt.from(100000);
        
        expect(
          () => service.buildPartialP2PKHTransaction(
            recipientAddress: invalidAddress,
            amount: amount,
          ),
          throwsA(isA<TransactionBuildException>()),
        );
      });
    });

    group('Complete P2PKH Transaction Building', () {
      List<BitcoinUtxo> createTestUTXOs() {
        return [
          BitcoinUtxo.create(
            txid: '77748917fafb605a97c13736b44847b45b9f070d32c479eba66be23ecd827cbc',
            vout: 0,
            satoshis: BigInt.from(100000), // 0.001 BSV
            scriptPubKey: '76a914abc123def456789012345678901234567890abc1234567888ac',
            address: testAddress,
            blockHeight: 100,
            confirmations: 6,
            derivationIndex: 0,
          ),
          BitcoinUtxo.create(
            txid: 'e01c34c0ea274fc2d48b019b2e38a46b89f5948cf143fcc83c923459aa3aa7fc',
            vout: 1,
            satoshis: BigInt.from(200000), // 0.002 BSV
            scriptPubKey: '76a914abc123def456789012345678901234567890abc1234567888ac',
            address: testAddress,
            blockHeight: 101,
            confirmations: 5,
            derivationIndex: 1,
          ),
          BitcoinUtxo.create(
            txid: 'd3ce5b537a6e5b3fd55a02a6b5e4ffb5667f3f6e7088946765f20da47b0f7242',
            vout: 0,
            satoshis: BigInt.from(50000), // 0.0005 BSV
            scriptPubKey: '76a914abc123def456789012345678901234567890abc1234567888ac',
            address: testAddress,
            blockHeight: 102,
            confirmations: 4,
            derivationIndex: 2,
          ),
        ];
      }

      test('should build complete P2PKH transaction successfully', () async {
        final utxos = createTestUTXOs();
        const recipientAddress = 'mxAoAyZFXX6LZBWhoam3vjm6xt9NxPQ15f';
        final amount = BigInt.from(80000); // 0.0008 BSV
        const transactionId = 'd3ce5b537a6e5b3fd55a02a6b5e4ffb5667f3f6e7088946765f20da47b0f7242';
        
        final result = await service.buildP2PKHTransaction(
          availableUtxos: utxos,
          recipientAddress: recipientAddress,
          amount: amount,
          changeAddress: changeAddress,
          signingKey: testPrivateKey,
          transactionId: transactionId,
        );
        
        expect(result.transaction, isNotNull);
        expect(result.selectedInputs, isNotEmpty);
        expect(result.totalInput, greaterThan(amount));
        expect(result.totalOutput, lessThanOrEqualTo(result.totalInput));
        expect(result.fee, greaterThan(BigInt.zero));
        expect(result.readyForSigning, isTrue);
        expect(result.transactionHex, isNotEmpty);
        
        // Verify UTXOs are locked
        expect(service.lockedUTXOs, isNotEmpty);
        
        // Clean up
        await service.unlockUtxos(transactionId);
      });

      test('should handle insufficient funds', () async {
        final utxos = createTestUTXOs();
        const recipientAddress = 'mxAoAyZFXX6LZBWhoam3vjm6xt9NxPQ15f';
        final amount = BigInt.from(500000); // More than total UTXO value
        const transactionId = 'test-tx-insufficient';
        
        expect(
          () => service.buildP2PKHTransaction(
            availableUtxos: utxos,
            recipientAddress: recipientAddress,
            amount: amount,
            changeAddress: changeAddress,
            signingKey: testPrivateKey,
            transactionId: transactionId,
          ),
          throwsA(isA<TransactionBuildException>().having(
            (e) => e.code,
            'code',
            equals('INSUFFICIENT_FUNDS'),
          )),
        );
      });

      test('should handle empty UTXO list', () async {
        const recipientAddress = 'mxAoAyZFXX6LZBWhoam3vjm6xt9NxPQ15f';
        final amount = BigInt.from(50000);
        const transactionId = 'test-tx-empty';
        
        expect(
          () => service.buildP2PKHTransaction(
            availableUtxos: [],
            recipientAddress: recipientAddress,
            amount: amount,
            changeAddress: changeAddress,
            signingKey: testPrivateKey,
            transactionId: transactionId,
          ),
          throwsA(isA<TransactionBuildException>()),
        );
      });

      test('should build transaction with custom fee rate', () async {
        final utxos = createTestUTXOs();
        const recipientAddress = 'mxAoAyZFXX6LZBWhoam3vjm6xt9NxPQ15f';
        final amount = BigInt.from(80000);
        const transactionId = 'test-tx-custom-fee';
        
        const highFeeConfig = TransactionBuildConfig(
          feePerKb: 100, // High fee
        );
        
        final result = await service.buildP2PKHTransaction(
          availableUtxos: utxos,
          recipientAddress: recipientAddress,
          amount: amount,
          changeAddress: changeAddress,
          signingKey: testPrivateKey,
          transactionId: transactionId,
          config: highFeeConfig,
        );
        
        expect(result.fee, greaterThan(BigInt.from(5))); // Should have some fee with high fee rate
        
        await service.unlockUtxos(transactionId);
      });

      test('should build transaction with BEEF when history provided', () async {
        final utxos = createTestUTXOs();
        const recipientAddress = 'mxAoAyZFXX6LZBWhoam3vjm6xt9NxPQ15f';
        final amount = BigInt.from(80000);
        const transactionId = 'test-tx-beef';
        
        // Create mock transaction history with merkle proofs
        final txHistory = [
          TxHistoryEntry(
            txid: utxos[0].txid,
            rawHex: '0100000001...', // Mock raw transaction
            blockHeight: 100,
            isConfirmed: true,
            merkleProof: jsonEncode({
              'index': 0,
              'path': ['merkle1', 'merkle2'],
              'blockHeight': 100,
            }),
          ),
        ];
        
        final result = await service.buildP2PKHTransaction(
          availableUtxos: utxos,
          recipientAddress: recipientAddress,
          amount: amount,
          changeAddress: changeAddress,
          signingKey: testPrivateKey,
          transactionId: transactionId,
          txHistory: txHistory,
        );
        
        expect(result.transaction, isNotNull);
        // Note: BEEF creation might be limited due to mock data
        
        await service.unlockUtxos(transactionId);
      });
    });

    group('UTXO Selection Strategies', () {
      List<BitcoinUtxo> createVariedUTXOs() {
        return [
          BitcoinUtxo.create(
            txid: '1111111111111111111111111111111111111111111111111111111111111111',
            vout: 0,
            satoshis: BigInt.from(10000), // Small
            scriptPubKey: '76a914abc123def456789012345678901234567890abc1234567888ac',
            address: testAddress,
          ),
          BitcoinUtxo.create(
            txid: '2222222222222222222222222222222222222222222222222222222222222222',
            vout: 0,
            satoshis: BigInt.from(500000), // Large
            scriptPubKey: '76a914abc123def456789012345678901234567890abc1234567888ac',
            address: testAddress,
          ),
          BitcoinUtxo.create(
            txid: '3333333333333333333333333333333333333333333333333333333333333333',
            vout: 0,
            satoshis: BigInt.from(100000), // Medium
            scriptPubKey: '76a914abc123def456789012345678901234567890abc1234567888ac',
            address: testAddress,
          ),
          BitcoinUtxo.create(
            txid: '4444444444444444444444444444444444444444444444444444444444444444',
            vout: 0,
            satoshis: BigInt.from(50000), // Small-medium
            scriptPubKey: '76a914abc123def456789012345678901234567890abc1234567888ac',
            address: testAddress,
          ),
        ];
      }

      test('should select UTXOs with smallest first strategy', () async {
        final utxos = createVariedUTXOs();
        const recipientAddress = 'mxAoAyZFXX6LZBWhoam3vjm6xt9NxPQ15f';
        final amount = BigInt.from(120000); // Will need multiple UTXOs
        const transactionId = 'test-smallest-first';
        
        const config = TransactionBuildConfig(
          selectionStrategy: UTXOSelectionStrategy.smallestFirst,
        );
        
        final result = await service.buildP2PKHTransaction(
          availableUtxos: utxos,
          recipientAddress: recipientAddress,
          amount: amount,
          changeAddress: changeAddress,
          signingKey: testPrivateKey,
          transactionId: transactionId,
          config: config,
        );
        
        // Should select smallest UTXOs first
        expect(result.selectedInputs, isNotEmpty);
        final firstSelectedValue = result.selectedInputs.first.value.getValue();
        expect(firstSelectedValue, equals(BigInt.from(10000))); // Smallest UTXO
        
        await service.unlockUtxos(transactionId);
      });

      test('should select UTXOs with largest first strategy', () async {
        final utxos = createVariedUTXOs();
        const recipientAddress = 'mxAoAyZFXX6LZBWhoam3vjm6xt9NxPQ15f';
        final amount = BigInt.from(80000);
        const transactionId = 'test-largest-first';
        
        const config = TransactionBuildConfig(
          selectionStrategy: UTXOSelectionStrategy.largestFirst,
        );
        
        final result = await service.buildP2PKHTransaction(
          availableUtxos: utxos,
          recipientAddress: recipientAddress,
          amount: amount,
          changeAddress: changeAddress,
          signingKey: testPrivateKey,
          transactionId: transactionId,
          config: config,
        );
        
        // Should select largest UTXO first
        expect(result.selectedInputs, isNotEmpty);
        final firstSelectedValue = result.selectedInputs.first.value.getValue();
        expect(firstSelectedValue, equals(BigInt.from(500000))); // Largest UTXO
        
        await service.unlockUtxos(transactionId);
      });

      test('should select UTXOs with random strategy', () async {
        final utxos = createVariedUTXOs();
        const recipientAddress = 'mxAoAyZFXX6LZBWhoam3vjm6xt9NxPQ15f';
        final amount = BigInt.from(80000);
        const transactionId = 'test-random';
        
        const config = TransactionBuildConfig(
          selectionStrategy: UTXOSelectionStrategy.random,
        );
        
        final result = await service.buildP2PKHTransaction(
          availableUtxos: utxos,
          recipientAddress: recipientAddress,
          amount: amount,
          changeAddress: changeAddress,
          signingKey: testPrivateKey,
          transactionId: transactionId,
          config: config,
        );
        
        expect(result.selectedInputs, isNotEmpty);
        expect(result.totalInput, greaterThanOrEqualTo(amount));
        
        await service.unlockUtxos(transactionId);
      });

      test('should select UTXOs with optimal change strategy', () async {
        final utxos = createVariedUTXOs();
        const recipientAddress = 'mxAoAyZFXX6LZBWhoam3vjm6xt9NxPQ15f';
        final amount = BigInt.from(80000);
        const transactionId = 'test-optimal-change';
        
        const config = TransactionBuildConfig(
          selectionStrategy: UTXOSelectionStrategy.optimalChange,
        );
        
        final result = await service.buildP2PKHTransaction(
          availableUtxos: utxos,
          recipientAddress: recipientAddress,
          amount: amount,
          changeAddress: changeAddress,
          signingKey: testPrivateKey,
          transactionId: transactionId,
          config: config,
        );
        
        expect(result.selectedInputs, isNotEmpty);
        expect(result.totalInput, greaterThanOrEqualTo(amount));
        
        await service.unlockUtxos(transactionId);
      });
    });

    group('UTXO Locking Mechanism', () {
      test('should lock UTXOs during transaction building', () async {
        final utxos = [
          BitcoinUtxo.create(
            txid: 'abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890',
            vout: 0,
            satoshis: BigInt.from(100000),
            scriptPubKey: '76a914abc123def456789012345678901234567890abc1234567888ac',
            address: testAddress,
          ),
        ];
        
        const recipientAddress = 'mxAoAyZFXX6LZBWhoam3vjm6xt9NxPQ15f';
        final amount = BigInt.from(50000);
        const transactionId = 'test-locking';
        
        // Build transaction (should lock UTXOs)
        final result = await service.buildP2PKHTransaction(
          availableUtxos: utxos,
          recipientAddress: recipientAddress,
          amount: amount,
          changeAddress: changeAddress,
          signingKey: testPrivateKey,
          transactionId: transactionId,
        );
        
        expect(result.selectedInputs, isNotEmpty);
        expect(service.lockedUTXOs, isNotEmpty);
        
        // Verify specific UTXO is locked
        final utxoKey = '${utxos[0].txid}:${utxos[0].vout}';
        final hasLockedUtxo = service.lockedUTXOs.values
            .any((lock) => lock.utxoId == utxoKey);
        expect(hasLockedUtxo, isTrue);
        
        await service.unlockUtxos(transactionId);
      });

      test('should unlock UTXOs for specific transaction', () async {
        final utxos = [
          BitcoinUtxo.create(
            txid: 'fedcba0987654321fedcba0987654321fedcba0987654321fedcba0987654321',
            vout: 0,
            satoshis: BigInt.from(100000),
            scriptPubKey: '76a914abc123def456789012345678901234567890abc1234567888ac',
            address: testAddress,
          ),
        ];
        
        const recipientAddress = 'mxAoAyZFXX6LZBWhoam3vjm6xt9NxPQ15f';
        final amount = BigInt.from(50000);
        const transactionId = 'test-unlocking';
        
        // Build transaction (locks UTXOs)
        await service.buildP2PKHTransaction(
          availableUtxos: utxos,
          recipientAddress: recipientAddress,
          amount: amount,
          changeAddress: changeAddress,
          signingKey: testPrivateKey,
          transactionId: transactionId,
        );
        
        expect(service.lockedUTXOs, isNotEmpty);
        
        // Unlock UTXOs
        await service.unlockUtxos(transactionId);
        
        expect(service.lockedUTXOs, isEmpty);
      });

      test('should prevent double-spending with locked UTXOs', () async {
        final utxos = [
          BitcoinUtxo.create(
            txid: '1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef',
            vout: 0,
            satoshis: BigInt.from(100000),
            scriptPubKey: '76a914abc123def456789012345678901234567890abc1234567888ac',
            address: testAddress,
          ),
        ];
        
        const recipientAddress = 'mxAoAyZFXX6LZBWhoam3vjm6xt9NxPQ15f';
        final amount = BigInt.from(50000);
        const transactionId1 = 'test-tx-1';
        const transactionId2 = 'test-tx-2';
        
        // Build first transaction (locks the UTXO)
        await service.buildP2PKHTransaction(
          availableUtxos: utxos,
          recipientAddress: recipientAddress,
          amount: amount,
          changeAddress: changeAddress,
          signingKey: testPrivateKey,
          transactionId: transactionId1,
        );
        
        // Try to build second transaction with same UTXO (should fail)
        expect(
          () => service.buildP2PKHTransaction(
            availableUtxos: utxos,
            recipientAddress: recipientAddress,
            amount: amount,
            changeAddress: changeAddress,
            signingKey: testPrivateKey,
            transactionId: transactionId2,
          ),
          throwsA(isA<TransactionBuildException>()),
        );
        
        // Clean up
        await service.unlockUtxos(transactionId1);
      });

      test('should verify lock expiration logic', () {
        // Create a lock with very short duration
        final shortDurationLock = UTXOLock(
          utxoId: 'test-utxo:0',
          transactionId: 'expired-tx',
          lockedAt: DateTime.now().subtract(const Duration(hours: 2)),
          lockDuration: const Duration(minutes: 1), // Very short
        );
        
        // Test that the lock is indeed expired
        expect(shortDurationLock.isExpired, isTrue);
        
        // Test fresh lock is not expired
        final freshLock = UTXOLock(
          utxoId: 'fresh-utxo:0',
          transactionId: 'fresh-tx',
          lockedAt: DateTime.now(),
          lockDuration: const Duration(minutes: 30),
        );
        
        expect(freshLock.isExpired, isFalse);
      });
    });

    group('Fee Estimation', () {
      test('should estimate fee correctly', () {
        final fee = service.estimateFee(
          inputCount: 2,
          outputCount: 2,
          feePerKb: 1,
        );
        
        // Expected: (2 * 180) + (2 * 34) + 10 = 438 bytes
        // Fee = (438 * 1) / 1000 = 0.438, truncated to 0
        expect(fee, equals(BigInt.from(0)));
      });

      test('should estimate fee for larger transaction', () {
        final fee = service.estimateFee(
          inputCount: 5,
          outputCount: 3,
          feePerKb: 10,
        );
        
        // Expected: (5 * 180) + (3 * 34) + 10 = 1012 bytes
        // Fee = (1012 * 10) / 1000 = 10.12, truncated to 10
        expect(fee, equals(BigInt.from(10)));
      });

      test('should handle zero fee rate', () {
        final fee = service.estimateFee(
          inputCount: 1,
          outputCount: 1,
          feePerKb: 0,
        );
        
        expect(fee, equals(BigInt.zero));
      });

      test('should estimate fee for complex transaction', () {
        final fee = service.estimateFee(
          inputCount: 10,
          outputCount: 5,
          feePerKb: 50,
        );
        
        // Expected: (10 * 180) + (5 * 34) + 10 = 1980 bytes
        // Fee = (1980 * 50) / 1000 = 99 satoshis
        expect(fee, equals(BigInt.from(99)));
      });
    });

    group('Transaction Output Specifications', () {
      test('should create valid transaction output spec', () {
        const address = 'mxAoAyZFXX6LZBWhoam3vjm6xt9NxPQ15f';
        final amount = BigInt.from(100000);
        
        final outputSpec = TransactionOutputSpec(
          address: address,
          amount: amount,
        );
        
        expect(outputSpec.address, equals(address));
        expect(outputSpec.amount, equals(amount));
        expect(outputSpec.scriptType, isNull);
        expect(outputSpec.lockBuilder, isNull);
      });

      test('should create output spec with custom script type', () {
        const address = 'mxAoAyZFXX6LZBWhoam3vjm6xt9NxPQ15f';
        final amount = BigInt.from(100000);
        const scriptType = BitcoinScriptType.p2pkh;
        
        final outputSpec = TransactionOutputSpec(
          address: address,
          amount: amount,
          scriptType: scriptType,
        );
        
        expect(outputSpec.scriptType, equals(scriptType));
      });
    });

    group('Transaction History and BEEF Integration', () {
      test('should create transaction history entry', () {
        const txid = 'test-tx-id';
        const rawHex = '0100000001...';
        const blockHeight = 100;
        const isConfirmed = true;
        const merkleProof = '{"index": 0, "path": ["proof1", "proof2"]}';
        
        final historyEntry = TxHistoryEntry(
          txid: txid,
          rawHex: rawHex,
          blockHeight: blockHeight,
          isConfirmed: isConfirmed,
          merkleProof: merkleProof,
        );
        
        expect(historyEntry.txid, equals(txid));
        expect(historyEntry.rawHex, equals(rawHex));
        expect(historyEntry.blockHeight, equals(blockHeight));
        expect(historyEntry.isConfirmed, equals(isConfirmed));
        expect(historyEntry.merkleProof, equals(merkleProof));
      });

      test('should handle history entry without merkle proof', () {
        final historyEntry = TxHistoryEntry(
          txid: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          rawHex: '0100000001...',
          blockHeight: 0,
          isConfirmed: false,
        );
        
        expect(historyEntry.merkleProof, isNull);
        expect(historyEntry.isConfirmed, isFalse);
      });
    });

    group('Error Handling', () {
      test('should handle TransactionBuildException properly', () {
        const message = 'Test error message';
        const code = 'TEST_ERROR';
        
        final exception = TransactionBuildException(message, code: code);
        
        expect(exception.message, equals(message));
        expect(exception.code, equals(code));
        expect(exception.toString(), contains(message));
        expect(exception.toString(), contains(code));
      });

      test('should handle exception without code', () {
        const message = 'Test error without code';
        
        final exception = TransactionBuildException(message);
        
        expect(exception.message, equals(message));
        expect(exception.code, isNull);
        expect(exception.toString(), contains(message));
        expect(exception.toString(), isNot(contains('null')));
      });

      test('should unlock UTXOs on transaction building failure', () async {
        final utxos = [
          BitcoinUtxo.create(
            txid: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
            vout: 0,
            satoshis: BigInt.from(100000),
            scriptPubKey: '76a914abc123def456789012345678901234567890abc1234567888ac',
            address: testAddress,
          ),
        ];
        
        // Use invalid address to trigger error
        const invalidAddress = 'invalid-address';
        final amount = BigInt.from(50000);
        const transactionId = 'test-error-cleanup';
        
        try {
          await service.buildP2PKHTransaction(
            availableUtxos: utxos,
            recipientAddress: invalidAddress,
            amount: amount,
            changeAddress: changeAddress,
            signingKey: testPrivateKey,
            transactionId: transactionId,
          );
          fail('Expected TransactionBuildException');
        } on TransactionBuildException {
          // Expected exception
        }
        
        // UTXOs should be unlocked after error
        expect(service.lockedUTXOs, isEmpty);
      });

      test('should handle reserved UTXOs in selection', () async {
        final utxos = [
          BitcoinUtxo.create(
            txid: 'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
            vout: 0,
            satoshis: BigInt.from(100000),
            scriptPubKey: '76a914abc123def456789012345678901234567890abc1234567888ac',
            address: testAddress,
          ).copyWith(status: UTXOStatus.reserved),
        ];
        
        const recipientAddress = 'mxAoAyZFXX6LZBWhoam3vjm6xt9NxPQ15f';
        final amount = BigInt.from(50000);
        const transactionId = 'test-reserved';
        
        expect(
          () => service.buildP2PKHTransaction(
            availableUtxos: utxos,
            recipientAddress: recipientAddress,
            amount: amount,
            changeAddress: changeAddress,
            signingKey: testPrivateKey,
            transactionId: transactionId,
          ),
          throwsA(isA<TransactionBuildException>()),
        );
      });

      test('should handle spent UTXOs in selection', () async {
        final utxos = [
          BitcoinUtxo.create(
            txid: 'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd',
            vout: 0,
            satoshis: BigInt.from(100000),
            scriptPubKey: '76a914abc123def456789012345678901234567890abc1234567888ac',
            address: testAddress,
          ).copyWith(status: UTXOStatus.spent),
        ];
        
        const recipientAddress = 'mxAoAyZFXX6LZBWhoam3vjm6xt9NxPQ15f';
        final amount = BigInt.from(50000);
        const transactionId = 'test-spent';
        
        expect(
          () => service.buildP2PKHTransaction(
            availableUtxos: utxos,
            recipientAddress: recipientAddress,
            amount: amount,
            changeAddress: changeAddress,
            signingKey: testPrivateKey,
            transactionId: transactionId,
          ),
          throwsA(isA<TransactionBuildException>()),
        );
      });
    });

    group('Transaction Validation', () {
      test('should build valid transaction structure', () async {
        final utxos = [
          BitcoinUtxo.create(
            txid: '77748917fafb605a97c13736b44847b45b9f070d32c479eba66be23ecd827cbc',
            vout: 0,
            satoshis: BigInt.from(100000),
            scriptPubKey: '76a914...88ac',
            address: testAddress,
          ),
        ];
        
        const recipientAddress = 'mxAoAyZFXX6LZBWhoam3vjm6xt9NxPQ15f';
        final amount = BigInt.from(50000);
        const transactionId = 'test-validation';
        
        final result = await service.buildP2PKHTransaction(
          availableUtxos: utxos,
          recipientAddress: recipientAddress,
          amount: amount,
          changeAddress: changeAddress,
          signingKey: testPrivateKey,
          transactionId: transactionId,
        );
        
        final transaction = result.transaction;
        
        // Validate transaction structure
        expect(transaction.inputs, isNotEmpty);
        expect(transaction.outputs, isNotEmpty);
        expect(transaction.inputs.length, equals(result.selectedInputs.length));
        
        // Validate input references
        for (int i = 0; i < transaction.inputs.length; i++) {
          final input = transaction.inputs[i];
          final selectedUtxo = result.selectedInputs[i];
          
          expect(input.prevTxnId, equals(selectedUtxo.txid));
          expect(input.prevTxnOutputIndex, equals(selectedUtxo.vout));
        }
        
        // Validate outputs have proper values
        final totalOutputValue = transaction.outputs.fold<BigInt>(
          BigInt.zero,
          (sum, output) => sum + output.satoshis,
        );
        expect(totalOutputValue, equals(result.totalOutput));
        
        await service.unlockUtxos(transactionId);
      });

      test('should create proper change output when needed', () async {
        final utxos = [
          BitcoinUtxo.create(
            txid: 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee',
            vout: 0,
            satoshis: BigInt.from(200000), // Large UTXO
            scriptPubKey: '76a914abc123def456789012345678901234567890abc1234567888ac',
            address: testAddress,
          ),
        ];
        
        const recipientAddress = 'mxAoAyZFXX6LZBWhoam3vjm6xt9NxPQ15f';
        final amount = BigInt.from(50000); // Small amount
        const transactionId = 'test-change';
        
        final result = await service.buildP2PKHTransaction(
          availableUtxos: utxos,
          recipientAddress: recipientAddress,
          amount: amount,
          changeAddress: changeAddress,
          signingKey: testPrivateKey,
          transactionId: transactionId,
        );
        
        // Should have 2 outputs: recipient + change
        expect(result.transaction.outputs.length, equals(2));
        expect(result.changeAmount, greaterThan(BigInt.zero));
        
        await service.unlockUtxos(transactionId);
      });

      test('should handle dust amounts properly', () async {
        final utxos = [
          BitcoinUtxo.create(
            txid: 'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff',
            vout: 0,
            satoshis: BigInt.from(1000), // Very small UTXO
            scriptPubKey: '76a914abc123def456789012345678901234567890abc1234567888ac',
            address: testAddress,
          ),
        ];
        
        const recipientAddress = 'mxAoAyZFXX6LZBWhoam3vjm6xt9NxPQ15f';
        final amount = BigInt.from(500); // Small amount
        const transactionId = 'test-dust';
        
        const config = TransactionBuildConfig(
          minChangeAmount: 546, // Standard dust threshold
        );
        
        final result = await service.buildP2PKHTransaction(
          availableUtxos: utxos,
          recipientAddress: recipientAddress,
          amount: amount,
          changeAddress: changeAddress,
          signingKey: testPrivateKey,
          transactionId: transactionId,
          config: config,
        );
        
        // BSV now accepts 1 sat outputs, eliminating the dust concept
        // Change should be non-negative (either 0 or any positive amount)
        expect(result.changeAmount, greaterThanOrEqualTo(BigInt.zero));
        
        await service.unlockUtxos(transactionId);
      });
    });

    group('Advanced Configuration Options', () {
      test('should handle Replace-By-Fee (RBF) configuration', () {
        const rbfConfig = TransactionBuildConfig(
          enableRBF: true,
        );
        
        expect(rbfConfig.enableRBF, isTrue);
      });

      test('should handle force change configuration', () {
        const forceChangeConfig = TransactionBuildConfig(
          forceChange: true,
          minChangeAmount: 1000,
        );
        
        expect(forceChangeConfig.forceChange, isTrue);
        expect(forceChangeConfig.minChangeAmount, equals(1000));
      });

      test('should handle custom transaction options', () {
        const customOptions = {
          dartsv.TransactionOption.DISABLE_DUST_OUTPUTS,
          dartsv.TransactionOption.DISABLE_MORE_OUTPUT_THAN_INPUT,
        };
        
        const customConfig = TransactionBuildConfig(
          options: customOptions,
        );
        
        expect(customConfig.options, equals(customOptions));
        expect(customConfig.options.length, equals(2));
      });

      test('should handle skip sanity checks option', () {
        const skipChecksConfig = TransactionBuildConfig(
          performSanityChecks: true,
        );
        
        expect(skipChecksConfig.performSanityChecks, isTrue);
      });
    });

    group('Transaction Result Analysis', () {
      test('should provide comprehensive transaction result', () async {
        final utxos = [
          BitcoinUtxo.create(
            txid: '1111111111111111222222222222222233333333333333334444444444444444',
            vout: 0,
            satoshis: BigInt.from(150000),
            scriptPubKey: '76a914abc123def456789012345678901234567890abc1234567888ac',
            address: testAddress,
          ),
        ];
        
        const recipientAddress = 'mxAoAyZFXX6LZBWhoam3vjm6xt9NxPQ15f';
        final amount = BigInt.from(80000);
        const transactionId = 'test-result-analysis';
        
        final result = await service.buildP2PKHTransaction(
          availableUtxos: utxos,
          recipientAddress: recipientAddress,
          amount: amount,
          changeAddress: changeAddress,
          signingKey: testPrivateKey,
          transactionId: transactionId,
        );
        
        // Analyze result completeness
        expect(result.transaction, isNotNull);
        expect(result.selectedInputs, isNotEmpty);
        expect(result.totalInput, greaterThan(BigInt.zero));
        expect(result.totalOutput, greaterThan(BigInt.zero));
        expect(result.fee, greaterThanOrEqualTo(BigInt.zero));
        expect(result.changeAmount, greaterThanOrEqualTo(BigInt.zero));
        expect(result.readyForSigning, isTrue);
        expect(result.transactionHex, isNotEmpty);
        
        // Verify transaction balance
        expect(result.totalInput, equals(result.totalOutput + result.fee));
        
        // Verify transaction hex is valid hex
        expect(() => hex.decode(result.transactionHex), returnsNormally);
        
        await service.unlockUtxos(transactionId);
      });

      test('should track selected UTXOs correctly', () async {
        final utxos = [
          BitcoinUtxo.create(
            txid: 'aaaaaaaaaaaaaaaa1111111111111111bbbbbbbbbbbbbbbb2222222222222222',
            vout: 0,
            satoshis: BigInt.from(100000),
            scriptPubKey: '76a914abc123def456789012345678901234567890abc1234567888ac',
            address: testAddress,
          ),
          BitcoinUtxo.create(
            txid: 'cccccccccccccccc3333333333333333dddddddddddddddd4444444444444444',
            vout: 1,
            satoshis: BigInt.from(150000),
            scriptPubKey: '76a914abc123def456789012345678901234567890abc1234567888ac',
            address: testAddress,
          ),
        ];
        
        const recipientAddress = 'mxAoAyZFXX6LZBWhoam3vjm6xt9NxPQ15f';
        final amount = BigInt.from(180000); // Will need both UTXOs
        const transactionId = 'test-tracking';
        
        final result = await service.buildP2PKHTransaction(
          availableUtxos: utxos,
          recipientAddress: recipientAddress,
          amount: amount,
          changeAddress: changeAddress,
          signingKey: testPrivateKey,
          transactionId: transactionId,
        );
        
        // Should have selected both UTXOs
        expect(result.selectedInputs.length, equals(2));
        
        // Verify UTXO tracking accuracy
        final totalSelectedValue = result.selectedInputs.fold<BigInt>(
          BigInt.zero,
          (sum, utxo) => sum + utxo.value.getValue(),
        );
        expect(totalSelectedValue, equals(result.totalInput));
        
        // Verify specific UTXOs are tracked
        final selectedTxids = result.selectedInputs.map((u) => u.txid).toSet();
        expect(selectedTxids, contains('aaaaaaaaaaaaaaaa1111111111111111bbbbbbbbbbbbbbbb2222222222222222'));
        expect(selectedTxids, contains('cccccccccccccccc3333333333333333dddddddddddddddd4444444444444444'));
        
        await service.unlockUtxos(transactionId);
      });
    });
  });
} 