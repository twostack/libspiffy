import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:convert/convert.dart';
import 'package:dartsv/dartsv.dart' as dartsv;

import '../lib/src/services/crypto_service.dart';
import '../lib/src/services/dartsv_crypto_service.dart';

void main() {
  group('DartSVCryptoService Tests', () {
    late CryptoService cryptoService;

    setUp(() {
      cryptoService = DartSVCryptoService(
        networkType: dartsv.NetworkType.TEST,
      );
    });

    group('Mnemonic Operations', () {
      test('should generate valid mnemonic phrases', () async {
        // Test default 128-bit entropy
        final mnemonic128 = await cryptoService.generateMnemonic();
        expect(mnemonic128, isNotEmpty);
        expect(mnemonic128.split(' ').length, equals(12)); // 128 bits = 12 words

        // Test 256-bit entropy  
        final mnemonic256 = await cryptoService.generateMnemonic(strength: 256);
        expect(mnemonic256, isNotEmpty);
        expect(mnemonic256.split(' ').length, equals(24)); // 256 bits = 24 words

        // Ensure different calls generate different mnemonics
        final mnemonic2 = await cryptoService.generateMnemonic();
        expect(mnemonic128, isNot(equals(mnemonic2)));
      });

      test('should validate correct mnemonic phrases', () async {
        final mnemonic = await cryptoService.generateMnemonic();
        final isValid = await cryptoService.validateMnemonic(mnemonic);
        expect(isValid, isTrue);
      });

      test('should reject invalid mnemonic phrases', () async {
        final invalidMnemonics = [
          'invalid mnemonic phrase test',
          'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon wrong', // invalid checksum
          'not a mnemonic at all',
          'single',
          '',
        ];

        for (final invalid in invalidMnemonics) {
          final isValid = await cryptoService.validateMnemonic(invalid);
          expect(isValid, isFalse, reason: 'Should reject: $invalid');
        }
      });
    });

    group('HD Key Derivation', () {
      test('should create HD private key from mnemonic', () async {
        final mnemonic = await cryptoService.generateMnemonic();
        
        final hdPrivateKey = await cryptoService.mnemonicToHDPrivateKey(
          mnemonic,
          network: dartsv.NetworkType.TEST,
        );
        
        expect(hdPrivateKey, isNotNull);
        expect(hdPrivateKey, isA<dartsv.HDPrivateKey>());
      });

      test('should create different keys with different passphrases', () async {
        final mnemonic = await cryptoService.generateMnemonic();
        
        final hdKey1 = await cryptoService.mnemonicToHDPrivateKey(
          mnemonic,
          passphrase: '',
        );
        
        final hdKey2 = await cryptoService.mnemonicToHDPrivateKey(
          mnemonic,
          passphrase: 'test-passphrase',
        );
        
        // Keys with different passphrases should be different
        final childKey1 = await cryptoService.derivePrivateKey(hdKey1, 0, 0);
        final childKey2 = await cryptoService.derivePrivateKey(hdKey2, 0, 0);
        expect(childKey1.toWIF(), isNot(equals(childKey2.toWIF())));
      });

      test('should derive child private keys with BIP44 paths', () async {
        final mnemonic = await cryptoService.generateMnemonic();
        final hdKey = await cryptoService.mnemonicToHDPrivateKey(mnemonic);
        
        // Test receiving address derivation (isChange: false)
        final receivingKey = await cryptoService.derivePrivateKey(
          hdKey,
          0, // account index
          0, // address index
          isChange: false,
        );
        
        // Test change address derivation (isChange: true)
        final changeKey = await cryptoService.derivePrivateKey(
          hdKey,
          0, // account index
          0, // address index
          isChange: true,
        );
        
        expect(receivingKey, isNotNull);
        expect(changeKey, isNotNull);
        expect(receivingKey.toWIF(), isNot(equals(changeKey.toWIF())));
      });

      test('should derive different keys for different indices', () async {
        final mnemonic = await cryptoService.generateMnemonic();
        final hdKey = await cryptoService.mnemonicToHDPrivateKey(mnemonic);
        
        final key0 = await cryptoService.derivePrivateKey(hdKey, 0, 0);
        final key1 = await cryptoService.derivePrivateKey(hdKey, 0, 1);
        final key2 = await cryptoService.derivePrivateKey(hdKey, 1, 0);
        
        expect(key0.toWIF(), isNot(equals(key1.toWIF())));
        expect(key0.toWIF(), isNot(equals(key2.toWIF())));
        expect(key1.toWIF(), isNot(equals(key2.toWIF())));
      });
    });

    group('Address Generation', () {
      //somewhat redundant since our DartSV library is very capable
      test('should generate valid Bitcoin addresses', () async {

        final mnemonic = await cryptoService.generateMnemonic();
        final hdKey = await cryptoService.mnemonicToHDPrivateKey(mnemonic);
        final privateKey = await cryptoService.derivePrivateKey(hdKey, 0, 0);
        
        final address = cryptoService.generateAddress(
          privateKey,
          network: dartsv.NetworkType.TEST,
        );
        
        expect(address, isNotEmpty);
        expect(address.length, greaterThan(25)); // Valid address length
      });

      test('should generate different addresses for mainnet vs testnet', () async {
        final privateKey = cryptoService.generateRandomPrivateKey();
        
        final testnetAddress = cryptoService.generateAddress(
          privateKey,
          network: dartsv.NetworkType.TEST,
        );
        
        final mainnetAddress = cryptoService.generateAddress(
          privateKey,
          network: dartsv.NetworkType.MAIN,
        );
        
        expect(testnetAddress, isNot(equals(mainnetAddress)));
        expect(testnetAddress.startsWith('m') || testnetAddress.startsWith('n'), isTrue); // Testnet prefixes
        expect(mainnetAddress, startsWith('1')); // Mainnet P2PKH prefix
      });
    });

    group('Signing and Verification', () {
      test('should sign and verify transaction hashes', () async {
        final privateKey = cryptoService.generateRandomPrivateKey();
        final publicKey = cryptoService.getPublicKey(privateKey);
        
        // Create a sample transaction hash
        final transactionHash = Uint8List.fromList(List.generate(32, (i) => i));
        const sigHashType = 0x41; // SIGHASH_ALL | SIGHASH_FORKID
        
        final signature = await cryptoService.signTransactionHash(
          privateKey,
          transactionHash,
          sigHashType,
        );
        
        expect(signature, isNotNull);
        expect(signature, isA<dartsv.SVSignature>());
        
        // Verify the signature
        final isValid = cryptoService.verifySignature(
          publicKey,
          signature,
          transactionHash,
        );
        
        expect(isValid, isTrue);
      });

      test('should sign and verify arbitrary data', () async {
        final privateKey = cryptoService.generateRandomPrivateKey();
        final publicKey = cryptoService.getPublicKey(privateKey);
        
        final testData = Uint8List.fromList('Hello, Bitcoin SV!'.codeUnits);
        
        final signature = await cryptoService.signData(privateKey, testData);
        expect(signature, isNotNull);
        
        final isValid = cryptoService.verifySignature(publicKey, signature, testData);
        expect(isValid, isTrue);
      });

      test('should fail verification with wrong public key', () async {
        final privateKey1 = cryptoService.generateRandomPrivateKey();
        final privateKey2 = cryptoService.generateRandomPrivateKey();
        final publicKey2 = cryptoService.getPublicKey(privateKey2);
        
        final testData = Uint8List.fromList('test data'.codeUnits);
        final signature = await cryptoService.signData(privateKey1, testData);
        
        // Try to verify with wrong public key
        final isValid = cryptoService.verifySignature(publicKey2, signature, testData);
        expect(isValid, isFalse);
      });
    });

    group('Hash Functions', () {
      test('should compute SHA-256 correctly', () {
        final testData = Uint8List.fromList('Hello, World!'.codeUnits);
        final hash = cryptoService.sha256(testData);
        
        expect(hash.length, equals(32)); // SHA-256 produces 32 bytes
        expect(hash, isA<Uint8List>());
        
        // Test known hash value
        final expectedHex = 'dffd6021bb2bd5b0af676290809ec3a53191dd81c7f70a4b28688a362182986f';
        final actualHex = hex.encode(hash);
        expect(actualHex, equals(expectedHex));
      });

      test('should compute double SHA-256 correctly', () {
        final testData = Uint8List.fromList('Hello, World!'.codeUnits);
        final doubleHash = cryptoService.doubleSha256(testData);
        
        expect(doubleHash.length, equals(32)); // Double SHA-256 produces 32 bytes
        expect(doubleHash, isA<Uint8List>());
        
        // Verify it's different from single SHA-256
        final singleHash = cryptoService.sha256(testData);
        expect(doubleHash, isNot(equals(singleHash)));
      });
    });

    group('WIF Conversion', () {
      test('should convert private key to WIF and back', () {
        final originalKey = cryptoService.generateRandomPrivateKey();
        
        final wif = cryptoService.privateKeyToWIF(originalKey);
        expect(wif, isNotEmpty);
        expect(wif, isA<String>());
        
        final restoredKey = cryptoService.privateKeyFromWIF(wif);
        expect(restoredKey.toWIF(), equals(originalKey.toWIF()));
      });

      test('should handle different network types in WIF', () {
        final testnetKey = cryptoService.generateRandomPrivateKey(
          network: dartsv.NetworkType.TEST,
        );
        final mainnetKey = cryptoService.generateRandomPrivateKey(
          network: dartsv.NetworkType.MAIN,
        );
        
        final testnetWIF = cryptoService.privateKeyToWIF(testnetKey);
        final mainnetWIF = cryptoService.privateKeyToWIF(mainnetKey);
        
        // WIF formats should be different for different networks
        expect(testnetWIF.substring(0, 1), isNot(equals(mainnetWIF.substring(0, 1))));
      });
    });

    group('HD Public Key Operations', () {
      test('should derive HD public key from HD private key', () async {
        final mnemonic = await cryptoService.generateMnemonic();
        final hdPrivateKey = await cryptoService.mnemonicToHDPrivateKey(mnemonic);
        
        final hdPublicKey = cryptoService.deriveHDPublicKey(hdPrivateKey);
        expect(hdPublicKey, isNotNull);
        expect(hdPublicKey, isA<dartsv.HDPublicKey>());
      });

      test('should generate receiving addresses from HD public key', () async {
        final mnemonic = await cryptoService.generateMnemonic();
        final hdPrivateKey = await cryptoService.mnemonicToHDPrivateKey(mnemonic);
        final hdPublicKey = cryptoService.deriveHDPublicKey(hdPrivateKey);
        
        final address0 = cryptoService.generateReceivingAddress(hdPublicKey, 0);
        final address1 = cryptoService.generateReceivingAddress(hdPublicKey, 1);
        
        expect(address0, isNotEmpty);
        expect(address1, isNotEmpty);
        expect(address0, isNot(equals(address1)));
      });

      test('should generate change addresses from HD public key', () async {
        final mnemonic = await cryptoService.generateMnemonic();
        final hdPrivateKey = await cryptoService.mnemonicToHDPrivateKey(mnemonic);
        final hdPublicKey = cryptoService.deriveHDPublicKey(hdPrivateKey);
        
        final changeAddress0 = cryptoService.generateChangeAddress(hdPublicKey, 0);
        final changeAddress1 = cryptoService.generateChangeAddress(hdPublicKey, 1);
        
        expect(changeAddress0, isNotEmpty);
        expect(changeAddress1, isNotEmpty);
        expect(changeAddress0, isNot(equals(changeAddress1)));
      });
    });

    group('Random Key Generation', () {
      test('should generate different random private keys', () {
        final key1 = cryptoService.generateRandomPrivateKey();
        final key2 = cryptoService.generateRandomPrivateKey();
        
        expect(key1, isNotNull);
        expect(key2, isNotNull);
        expect(key1.toWIF(), isNot(equals(key2.toWIF())));
      });

      test('should generate keys for different networks', () {
        final testnetKey = cryptoService.generateRandomPrivateKey(
          network: dartsv.NetworkType.TEST,
        );
        final mainnetKey = cryptoService.generateRandomPrivateKey(
          network: dartsv.NetworkType.MAIN,
        );
        
        expect(testnetKey, isNotNull);
        expect(mainnetKey, isNotNull);
        
        // Generate addresses to verify network difference
        final testnetAddr = cryptoService.generateAddress(testnetKey);
        final mainnetAddr = cryptoService.generateAddress(
          mainnetKey,
          network: dartsv.NetworkType.MAIN,
        );
        
        expect(testnetAddr.startsWith('m') || testnetAddr.startsWith('n'), isTrue);
        expect(mainnetAddr, startsWith('1'));
      });
    });

    group('Integration Tests', () {
      test('should perform complete wallet key derivation flow', () async {
        // Generate mnemonic
        final mnemonic = await cryptoService.generateMnemonic();
        expect(await cryptoService.validateMnemonic(mnemonic), isTrue);
        
        // Create HD key
        final hdKey = await cryptoService.mnemonicToHDPrivateKey(mnemonic);
        
        // Derive child keys
        final receivingKey = await cryptoService.derivePrivateKey(hdKey, 0, 0, isChange: false);
        final changeKey = await cryptoService.derivePrivateKey(hdKey, 0, 0, isChange: true);
        
        // Generate addresses
        final receivingAddr = cryptoService.generateAddress(receivingKey);
        final changeAddr = cryptoService.generateAddress(changeKey);
        
        expect(receivingAddr, isNot(equals(changeAddr)));
        expect(receivingAddr.startsWith('m') || receivingAddr.startsWith('n'), isTrue);
        expect(changeAddr.startsWith('m') || changeAddr.startsWith('n'), isTrue);
        
        // Test signing capability
        final testData = Uint8List.fromList('test transaction'.codeUnits);
        final signature = await cryptoService.signData(receivingKey, testData);
        final publicKey = cryptoService.getPublicKey(receivingKey);
        
        expect(cryptoService.verifySignature(publicKey, signature, testData), isTrue);
      });

      test('should maintain consistency across operations', () async {
        final mnemonic = 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
        
        // Same mnemonic should always produce same keys
        final hdKey1 = await cryptoService.mnemonicToHDPrivateKey(mnemonic);
        final hdKey2 = await cryptoService.mnemonicToHDPrivateKey(mnemonic);
        
        // Verify consistency by deriving same child key from both
        final testKey1 = await cryptoService.derivePrivateKey(hdKey1, 0, 0);
        final testKey2 = await cryptoService.derivePrivateKey(hdKey2, 0, 0);
        expect(testKey1.toWIF(), equals(testKey2.toWIF()));
        
        // Same derivation paths should produce same results
        final childKey1 = await cryptoService.derivePrivateKey(hdKey1, 0, 0);
        final childKey2 = await cryptoService.derivePrivateKey(hdKey2, 0, 0);
        
        expect(childKey1.toWIF(), equals(childKey2.toWIF()));
        
        // Same keys should produce same addresses
        final addr1 = cryptoService.generateAddress(childKey1);
        final addr2 = cryptoService.generateAddress(childKey2);
        
        expect(addr1, equals(addr2));
      });
    });

    group('Error Handling', () {
      test('should handle invalid mnemonic lengths gracefully', () async {
        expect(() => cryptoService.generateMnemonic(strength: 64), 
               throwsA(isA<CryptoException>()));
        expect(() => cryptoService.generateMnemonic(strength: 512), 
               throwsA(isA<CryptoException>()));
      });

      test('should handle invalid WIF strings', () {
        expect(() => cryptoService.privateKeyFromWIF('invalid-wif'), 
               throwsA(isA<Exception>()));
        expect(() => cryptoService.privateKeyFromWIF(''), 
               throwsA(isA<Exception>()));
      });
    });
  });
} 