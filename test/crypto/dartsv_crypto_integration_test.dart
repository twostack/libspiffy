import 'package:test/test.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'dart:typed_data';

import 'package:libspiffy/src/services/crypto_service.dart';
import 'package:libspiffy/src/services/dartsv_crypto_service.dart';

void main() {
  group('DartSVCryptoService Integration Tests', () {
    late CryptoService cryptoService;

    setUp(() {
      cryptoService = DartSVCryptoService();
    });

    group('Mnemonic Operations', () {
      test('should generate valid 12-word mnemonic', () async {
        final mnemonic = await cryptoService.generateMnemonic();
        final words = mnemonic.split(' ');
        
        expect(words.length, equals(12));
        expect(words.every((word) => word.trim().isNotEmpty), isTrue);
        
        // Verify it's a valid mnemonic
        expect(await cryptoService.validateMnemonic(mnemonic), isTrue);
      });

      test('should generate valid 24-word mnemonic', () async {
        final mnemonic = await cryptoService.generateMnemonic(strength: 256);
        final words = mnemonic.split(' ');
        
        expect(words.length, equals(24));
        expect(words.every((word) => word.trim().isNotEmpty), isTrue);
        
        // Verify it's a valid mnemonic
        expect(await cryptoService.validateMnemonic(mnemonic), isTrue);
      });

      test('should validate correct mnemonics', () async {
        final validMnemonics = [
          'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about',
          'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon agent',
          'legal winner thank year wave sausage worth useful legal winner thank yellow',
        ];

        for (final mnemonic in validMnemonics) {
          expect(await cryptoService.validateMnemonic(mnemonic), isTrue,
              reason: 'Mnemonic should be valid: $mnemonic');
        }
      });

      test('should reject invalid mnemonics', () async {
        final invalidMnemonics = [
          'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon wrong',
          'single',
          'invalid mnemonic phrase with wrong word count',
          '',
          'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon',
        ];

        for (final mnemonic in invalidMnemonics) {
          expect(await cryptoService.validateMnemonic(mnemonic), isFalse,
              reason: 'Mnemonic should be invalid: $mnemonic');
        }
      });

      test('should handle invalid mnemonic lengths gracefully', () async {
        expect(
          () => cryptoService.generateMnemonic(strength: 99),
          throwsA(isA<CryptoException>()),
        );

        expect(
          () => cryptoService.generateMnemonic(strength: 512),
          throwsA(isA<CryptoException>()),
        );
      });
    });

    group('HD Wallet Operations', () {
      test('should derive HD private key from mnemonic', () async {
        const testMnemonic = 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
        
        final hdPrivateKey = await cryptoService.mnemonicToHDPrivateKey(testMnemonic);
        
        expect(hdPrivateKey, isNotNull);
        expect(hdPrivateKey, isA<dartsv.HDPrivateKey>());
      });

      test('should derive testnet HD key from mnemonic', () async {
        const testMnemonic = 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
        
        final testnetHDKey = await cryptoService.mnemonicToHDPrivateKey(
          testMnemonic, 
          network: dartsv.NetworkType.TEST,
        );
        
        expect(testnetHDKey, isNotNull);
        expect(testnetHDKey, isA<dartsv.HDPrivateKey>());
      });

      test('should derive consistent HD keys from same mnemonic', () async {
        const testMnemonic = 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
        
        final hdKey1 = await cryptoService.mnemonicToHDPrivateKey(testMnemonic);
        final hdKey2 = await cryptoService.mnemonicToHDPrivateKey(testMnemonic);
        
        expect(hdKey1.toString(), equals(hdKey2.toString()));
      });

      test('should derive different HD keys for different mnemonics', () async {
        const mnemonic1 = 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
        const mnemonic2 = 'legal winner thank year wave sausage worth useful legal winner thank yellow';
        
        final hdKey1 = await cryptoService.mnemonicToHDPrivateKey(mnemonic1);
        final hdKey2 = await cryptoService.mnemonicToHDPrivateKey(mnemonic2);
        
        expect(hdKey1.toString(), isNot(equals(hdKey2.toString())));
      });
    });

    group('Private Key Derivation', () {
      late dartsv.HDPrivateKey hdPrivateKey;

      setUp(() async {
        const testMnemonic = 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
        hdPrivateKey = await cryptoService.mnemonicToHDPrivateKey(testMnemonic);
      });

      test('should derive private key for account 0, address 0', () async {
        final privateKey = await cryptoService.derivePrivateKey(hdPrivateKey, 0, 0);
        
        expect(privateKey, isNotNull);
        expect(privateKey, isA<dartsv.SVPrivateKey>());
      });

      test('should derive different private keys for different addresses', () async {
        final privateKey1 = await cryptoService.derivePrivateKey(hdPrivateKey, 0, 0);
        final privateKey2 = await cryptoService.derivePrivateKey(hdPrivateKey, 0, 1);
        final privateKey3 = await cryptoService.derivePrivateKey(hdPrivateKey, 1, 0);
        
        expect(privateKey1.toWIF(), isNot(equals(privateKey2.toWIF())));
        expect(privateKey1.toWIF(), isNot(equals(privateKey3.toWIF())));
        expect(privateKey2.toWIF(), isNot(equals(privateKey3.toWIF())));
      });

      test('should derive consistent private keys for same path', () async {
        final privateKey1 = await cryptoService.derivePrivateKey(hdPrivateKey, 0, 5);
        final privateKey2 = await cryptoService.derivePrivateKey(hdPrivateKey, 0, 5);
        
        expect(privateKey1.toWIF(), equals(privateKey2.toWIF()));
      });

      test('should derive change and receiving addresses differently', () async {
        final receivingKey = await cryptoService.derivePrivateKey(hdPrivateKey, 0, 0, isChange: false);
        final changeKey = await cryptoService.derivePrivateKey(hdPrivateKey, 0, 0, isChange: true);
        
        expect(receivingKey.toWIF(), isNot(equals(changeKey.toWIF())));
      });
    });

    group('Address Generation', () {
      late dartsv.HDPrivateKey hdPrivateKey;

      setUp(() async {
        const testMnemonic = 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
        hdPrivateKey = await cryptoService.mnemonicToHDPrivateKey(testMnemonic);
      });

      test('should generate address from private key', () async {
        final privateKey = await cryptoService.derivePrivateKey(hdPrivateKey, 0, 0);
        final address = cryptoService.generateAddress(privateKey);
        
        expect(address, isNotNull);
        expect(address.length, greaterThan(25));
        expect(address, anyOf(startsWith('m'), startsWith('n'))); // Testnet addresses
      });

      test('should generate mainnet address from private key', () async {
        const testMnemonic = 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
        final mainnetHDKey = await cryptoService.mnemonicToHDPrivateKey(
          testMnemonic, 
          network: dartsv.NetworkType.MAIN,
        );
        final privateKey = await cryptoService.derivePrivateKey(mainnetHDKey, 0, 0);
        final address = cryptoService.generateAddress(privateKey, network: dartsv.NetworkType.MAIN);
        
        expect(address, isNotNull);
        expect(address, startsWith('1')); // Mainnet P2PKH address
      });

      test('should generate consistent addresses from same private key', () async {
        final privateKey = await cryptoService.derivePrivateKey(hdPrivateKey, 0, 0);
        
        final address1 = cryptoService.generateAddress(privateKey);
        final address2 = cryptoService.generateAddress(privateKey);
        
        expect(address1, equals(address2));
      });

      test('should generate different addresses for different private keys', () async {
        final privateKey1 = await cryptoService.derivePrivateKey(hdPrivateKey, 0, 0);
        final privateKey2 = await cryptoService.derivePrivateKey(hdPrivateKey, 0, 1);
        
        final address1 = cryptoService.generateAddress(privateKey1);
        final address2 = cryptoService.generateAddress(privateKey2);
        
        expect(address1, isNot(equals(address2)));
      });
    });

    group('Public Key Operations', () {
      late dartsv.HDPrivateKey hdPrivateKey;

      setUp(() async {
        const testMnemonic = 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
        hdPrivateKey = await cryptoService.mnemonicToHDPrivateKey(testMnemonic);
      });

      test('should generate public key from private key', () async {
        final privateKey = await cryptoService.derivePrivateKey(hdPrivateKey, 0, 0);
        final publicKey = cryptoService.getPublicKey(privateKey);
        
        expect(publicKey, isNotNull);
        expect(publicKey, isA<dartsv.SVPublicKey>());
      });

      test('should generate consistent public keys from same private key', () async {
        final privateKey = await cryptoService.derivePrivateKey(hdPrivateKey, 0, 0);
        
        final publicKey1 = cryptoService.getPublicKey(privateKey);
        final publicKey2 = cryptoService.getPublicKey(privateKey);
        
        expect(publicKey1.toString(), equals(publicKey2.toString()));
      });

      test('should generate different public keys for different private keys', () async {
        final privateKey1 = await cryptoService.derivePrivateKey(hdPrivateKey, 0, 0);
        final privateKey2 = await cryptoService.derivePrivateKey(hdPrivateKey, 0, 1);
        
        final publicKey1 = cryptoService.getPublicKey(privateKey1);
        final publicKey2 = cryptoService.getPublicKey(privateKey2);
        
        expect(publicKey1.toString(), isNot(equals(publicKey2.toString())));
      });
    });

    group('Data Signing and Verification', () {
      late dartsv.HDPrivateKey hdPrivateKey;
      late dartsv.SVPrivateKey privateKey;
      late dartsv.SVPublicKey publicKey;

      setUp(() async {
        const testMnemonic = 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
        hdPrivateKey = await cryptoService.mnemonicToHDPrivateKey(testMnemonic);
        privateKey = await cryptoService.derivePrivateKey(hdPrivateKey, 0, 0);
        publicKey = cryptoService.getPublicKey(privateKey);
      });

      test('should sign data correctly', () async {
        final testData = Uint8List.fromList('Hello Bitcoin SV'.codeUnits);
        final signature = await cryptoService.signData(privateKey, testData);
        
        expect(signature, isNotNull);
        expect(signature, isA<dartsv.SVSignature>());
      });

      test('should verify signature correctly', () async {
        final testData = Uint8List.fromList('Hello Bitcoin SV'.codeUnits);
        final signature = await cryptoService.signData(privateKey, testData);
        
        final isValid = cryptoService.verifySignature(publicKey, signature, testData);
        expect(isValid, isTrue);
      });

      test('should reject invalid signatures', () async {
        final testData = Uint8List.fromList('Hello Bitcoin SV'.codeUnits);
        final wrongData = Uint8List.fromList('Wrong data'.codeUnits);
        final signature = await cryptoService.signData(privateKey, testData);
        
        // Verify with wrong data
        final isValidWrongData = cryptoService.verifySignature(publicKey, signature, wrongData);
        expect(isValidWrongData, isFalse);
      });

      test('should sign and verify with different key pairs', () async {
        final privateKey2 = await cryptoService.derivePrivateKey(hdPrivateKey, 0, 1);
        final publicKey2 = cryptoService.getPublicKey(privateKey2);
        
        final testData = Uint8List.fromList('Cross-key verification test'.codeUnits);
        final signature = await cryptoService.signData(privateKey, testData);
        
        // Verify with correct key
        expect(cryptoService.verifySignature(publicKey, signature, testData), isTrue);
        
        // Verify with wrong key
        expect(cryptoService.verifySignature(publicKey2, signature, testData), isFalse);
      });
    });

    group('Transaction Hash Signing', () {
      late dartsv.HDPrivateKey hdPrivateKey;
      late dartsv.SVPrivateKey privateKey;

      setUp(() async {
        const testMnemonic = 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
        hdPrivateKey = await cryptoService.mnemonicToHDPrivateKey(testMnemonic);
        privateKey = await cryptoService.derivePrivateKey(hdPrivateKey, 0, 0);
      });

      test('should sign transaction hash correctly', () async {
        final txHash = Uint8List.fromList(List.filled(32, 0xaa)); // Mock transaction hash
        const sigHashType = 0x01; // SIGHASH_ALL
        
        final signature = await cryptoService.signTransactionHash(privateKey, txHash, sigHashType);
        
        expect(signature, isNotNull);
        expect(signature, isA<dartsv.SVSignature>());
      });

      test('should produce different signatures for different hash types', () async {
        final txHash = Uint8List.fromList(List.filled(32, 0xaa));
        
        final sig1 = await cryptoService.signTransactionHash(privateKey, txHash, 0x01); // SIGHASH_ALL
        final sig2 = await cryptoService.signTransactionHash(privateKey, txHash, 0x02); // SIGHASH_NONE
        
        expect(sig1.toString(), isNot(equals(sig2.toString())));
      });

      test('should produce different signatures for different transaction hashes', () async {
        final txHash1 = Uint8List.fromList(List.filled(32, 0xaa));
        final txHash2 = Uint8List.fromList(List.filled(32, 0xbb));
        const sigHashType = 0x01;
        
        final sig1 = await cryptoService.signTransactionHash(privateKey, txHash1, sigHashType);
        final sig2 = await cryptoService.signTransactionHash(privateKey, txHash2, sigHashType);
        
        expect(sig1.toString(), isNot(equals(sig2.toString())));
      });
    });

    group('Hashing Operations', () {
      test('should compute SHA256 hash correctly', () async {
        final testData = Uint8List.fromList('Hello Bitcoin SV'.codeUnits);
        final hash = cryptoService.sha256(testData);
        
        expect(hash, isNotNull);
        expect(hash.length, equals(32)); // 32 bytes
        expect(hash, isA<Uint8List>());
      });

      test('should compute double SHA256 hash correctly', () async {
        final testData = Uint8List.fromList('Hello Bitcoin SV'.codeUnits);
        final hash = cryptoService.doubleSha256(testData);
        
        expect(hash, isNotNull);
        expect(hash.length, equals(32)); // 32 bytes
        expect(hash, isA<Uint8List>());
      });

      test('should produce different hashes for different inputs', () async {
        final data1 = Uint8List.fromList('Input 1'.codeUnits);
        final data2 = Uint8List.fromList('Input 2'.codeUnits);
        
        final hash1 = cryptoService.sha256(data1);
        final hash2 = cryptoService.sha256(data2);
        
        expect(hash1, isNot(equals(hash2)));
      });

      test('should produce consistent hashes for same input', () async {
        final testData = Uint8List.fromList('Consistent input test'.codeUnits);
        
        final hash1 = cryptoService.sha256(testData);
        final hash2 = cryptoService.sha256(testData);
        
        expect(hash1, equals(hash2));
      });
    });

    group('Random Key Generation', () {
      test('should generate random private key', () async {
        final randomKey = cryptoService.generateRandomPrivateKey();
        
        expect(randomKey, isNotNull);
        expect(randomKey, isA<dartsv.SVPrivateKey>());
      });

      test('should generate different random keys', () async {
        final key1 = cryptoService.generateRandomPrivateKey();
        final key2 = cryptoService.generateRandomPrivateKey();
        
        expect(key1.toWIF(), isNot(equals(key2.toWIF())));
      });

      test('should generate mainnet and testnet random keys', () async {
        final testnetKey = cryptoService.generateRandomPrivateKey(network: dartsv.NetworkType.TEST);
        final mainnetKey = cryptoService.generateRandomPrivateKey(network: dartsv.NetworkType.MAIN);
        
        expect(testnetKey, isA<dartsv.SVPrivateKey>());
        expect(mainnetKey, isA<dartsv.SVPrivateKey>());
        expect(testnetKey.toWIF(), isNot(equals(mainnetKey.toWIF())));
      });
    });

    group('WIF Operations', () {
      late dartsv.SVPrivateKey privateKey;

      setUp(() async {
        privateKey = cryptoService.generateRandomPrivateKey();
      });

      test('should convert private key to WIF', () async {
        final wif = cryptoService.privateKeyToWIF(privateKey);
        
        expect(wif, isNotNull);
        expect(wif.length, greaterThan(50)); // WIF is typically 51-52 characters
        expect(wif, isA<String>());
      });

      test('should import private key from WIF', () async {
        final wif = cryptoService.privateKeyToWIF(privateKey);
        final importedKey = cryptoService.privateKeyFromWIF(wif);
        
        expect(importedKey.toWIF(), equals(privateKey.toWIF()));
      });

      test('should handle mainnet and testnet WIF', () async {
        final testnetKey = cryptoService.generateRandomPrivateKey(network: dartsv.NetworkType.TEST);
        final mainnetKey = cryptoService.generateRandomPrivateKey(network: dartsv.NetworkType.MAIN);
        
        final testnetWIF = cryptoService.privateKeyToWIF(testnetKey, network: dartsv.NetworkType.TEST);
        final mainnetWIF = cryptoService.privateKeyToWIF(mainnetKey, network: dartsv.NetworkType.MAIN);
        
        expect(testnetWIF, isNot(equals(mainnetWIF)));
        
        final importedTestnet = cryptoService.privateKeyFromWIF(testnetWIF, network: dartsv.NetworkType.TEST);
        final importedMainnet = cryptoService.privateKeyFromWIF(mainnetWIF, network: dartsv.NetworkType.MAIN);
        
        expect(importedTestnet.toWIF(), equals(testnetKey.toWIF()));
        expect(importedMainnet.toWIF(), equals(mainnetKey.toWIF()));
      });
    });

    group('HD Public Key Operations', () {
      late dartsv.HDPrivateKey hdPrivateKey;

      setUp(() async {
        const testMnemonic = 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
        hdPrivateKey = await cryptoService.mnemonicToHDPrivateKey(testMnemonic);
      });

      test('should derive HD public key from HD private key', () async {
        final hdPublicKey = cryptoService.deriveHDPublicKey(hdPrivateKey);
        
        expect(hdPublicKey, isNotNull);
        expect(hdPublicKey, isA<dartsv.HDPublicKey>());
      });

      test('should generate receiving addresses from HD public key', () async {
        final hdPublicKey = cryptoService.deriveHDPublicKey(hdPrivateKey);
        
        final address1 = cryptoService.generateReceivingAddress(hdPublicKey, 0);
        final address2 = cryptoService.generateReceivingAddress(hdPublicKey, 1);
        
        expect(address1, isNotNull);
        expect(address2, isNotNull);
        expect(address1, isNot(equals(address2)));
        expect(address1, anyOf(startsWith('m'), startsWith('n'))); // Testnet
        expect(address2, anyOf(startsWith('m'), startsWith('n'))); // Testnet
      });

      test('should generate change addresses from HD public key', () async {
        final hdPublicKey = cryptoService.deriveHDPublicKey(hdPrivateKey);
        
        final changeAddress1 = cryptoService.generateChangeAddress(hdPublicKey, 0);
        final changeAddress2 = cryptoService.generateChangeAddress(hdPublicKey, 1);
        
        expect(changeAddress1, isNotNull);
        expect(changeAddress2, isNotNull);
        expect(changeAddress1, isNot(equals(changeAddress2)));
      });

      test('should generate different receiving and change addresses', () async {
        final hdPublicKey = cryptoService.deriveHDPublicKey(hdPrivateKey);
        
        final receivingAddress = cryptoService.generateReceivingAddress(hdPublicKey, 0);
        final changeAddress = cryptoService.generateChangeAddress(hdPublicKey, 0);
        
        expect(receivingAddress, isNot(equals(changeAddress)));
      });
    });

    group('Error Handling and Edge Cases', () {
      test('should handle empty data gracefully', () async {
        final emptyData = Uint8List(0);
        
        expect(() => cryptoService.sha256(emptyData), returnsNormally);
        expect(() => cryptoService.doubleSha256(emptyData), returnsNormally);
      });

      test('should handle large data', () async {
        final largeData = Uint8List(10000); // 10KB of zeros
        
        expect(() => cryptoService.sha256(largeData), returnsNormally);
        expect(() => cryptoService.doubleSha256(largeData), returnsNormally);
      });

      test('should handle invalid WIF gracefully', () async {
        const invalidWIF = 'invalid_wif_string';
        
        expect(
          () => cryptoService.privateKeyFromWIF(invalidWIF),
          throwsA(isA<Exception>()),
        );
      });
    });

    group('Integration and Performance Tests', () {
      test('should handle multiple concurrent operations', () async {
        const testMnemonic = 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
        
        // Run multiple operations concurrently
        final futures = <Future>[];
        
        for (int i = 0; i < 10; i++) {
          futures.add(cryptoService.mnemonicToHDPrivateKey(testMnemonic));
          futures.add(cryptoService.generateMnemonic());
          final data = Uint8List.fromList('test data $i'.codeUnits);
          futures.add(Future.value(cryptoService.sha256(data)));
        }
        
        final results = await Future.wait(futures);
        expect(results.length, equals(30));
        expect(results.every((result) => result != null), isTrue);
      });

      test('should handle rapid successive operations', () async {
        final results = <Uint8List>[];
        
        for (int i = 0; i < 100; i++) {
          final data = Uint8List.fromList('test $i'.codeUnits);
          final hash = cryptoService.sha256(data);
          results.add(hash);
        }
        
        expect(results.length, equals(100));
        // Verify all hashes are unique (different inputs should produce different hashes)
        final hashStrings = results.map((h) => h.toString()).toSet();
        expect(hashStrings.length, equals(100));
      });
    });
  });
} 