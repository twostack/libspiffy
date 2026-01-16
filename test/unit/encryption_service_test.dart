import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:libspiffy/src/crypto/encryption_service.dart';

void main() {
  group('EncryptionService', () {
    late EncryptionService service;
    late Uint8List masterKey;

    setUp(() async {
      // Generate a random master key for testing
      masterKey = await EncryptionService.generateMasterKey();
      service = EncryptionService(masterKey: masterKey);
    });

    group('constructor validation', () {
      test('accepts 32-byte master key', () {
        expect(
          () => EncryptionService(masterKey: Uint8List(32)),
          returnsNormally,
        );
      });

      test('rejects master key that is too short', () {
        expect(
          () => EncryptionService(masterKey: Uint8List(16)),
          throwsA(isA<ArgumentError>()),
        );
      });

      test('rejects master key that is too long', () {
        expect(
          () => EncryptionService(masterKey: Uint8List(64)),
          throwsA(isA<ArgumentError>()),
        );
      });

      test('accepts custom key version', () {
        final svc = EncryptionService(masterKey: Uint8List(32), keyVersion: 2);
        expect(svc.keyVersion, equals(2));
      });
    });

    group('fromBase64 factory', () {
      test('creates service from valid base64 key', () {
        final keyBase64 = base64.encode(Uint8List(32));
        expect(
          () => EncryptionService.fromBase64(masterKeyBase64: keyBase64),
          returnsNormally,
        );
      });

      test('rejects invalid base64', () {
        expect(
          () => EncryptionService.fromBase64(masterKeyBase64: 'not-valid-base64!!!'),
          throwsA(isA<FormatException>()),
        );
      });

      test('rejects base64 with wrong length', () {
        final keyBase64 = base64.encode(Uint8List(16));
        expect(
          () => EncryptionService.fromBase64(masterKeyBase64: keyBase64),
          throwsA(isA<ArgumentError>()),
        );
      });
    });

    group('encrypt/decrypt roundtrip', () {
      test('encrypts and decrypts simple string', () async {
        const plaintext = 'Hello, World!';
        const context = 'test_context';

        final encrypted = await service.encrypt(
          plaintext: plaintext,
          context: context,
        );

        final decrypted = await service.decrypt(
          ciphertext: encrypted.ciphertext,
          nonce: encrypted.nonce,
          context: context,
        );

        expect(decrypted, equals(plaintext));
      });

      test('encrypts and decrypts xpub-like string', () async {
        const xpub = 'xpub6BsS7tTVG8ALqf8YNzEJQ7HS45Q7y9pQ4XYfKqt8xh3F3pZmPwrPq9Y8tKwBSbDCTBvJbXRnLqQ8Jn9c3zVvYj';
        const context = 'wallet_xpub_abc123';

        final encrypted = await service.encrypt(
          plaintext: xpub,
          context: context,
        );

        final decrypted = await service.decrypt(
          ciphertext: encrypted.ciphertext,
          nonce: encrypted.nonce,
          context: context,
        );

        expect(decrypted, equals(xpub));
      });

      test('encrypts and decrypts empty string', () async {
        const plaintext = '';
        const context = 'empty_test';

        final encrypted = await service.encrypt(
          plaintext: plaintext,
          context: context,
        );

        final decrypted = await service.decrypt(
          ciphertext: encrypted.ciphertext,
          nonce: encrypted.nonce,
          context: context,
        );

        expect(decrypted, equals(plaintext));
      });

      test('encrypts and decrypts unicode string', () async {
        const plaintext = '🔐 Secure Storage 日本語';
        const context = 'unicode_test';

        final encrypted = await service.encrypt(
          plaintext: plaintext,
          context: context,
        );

        final decrypted = await service.decrypt(
          ciphertext: encrypted.ciphertext,
          nonce: encrypted.nonce,
          context: context,
        );

        expect(decrypted, equals(plaintext));
      });

      test('different contexts produce different ciphertexts', () async {
        const plaintext = 'same plaintext';

        final encrypted1 = await service.encrypt(
          plaintext: plaintext,
          context: 'context_1',
        );

        final encrypted2 = await service.encrypt(
          plaintext: plaintext,
          context: 'context_2',
        );

        // Ciphertexts should be different due to different derived keys
        expect(encrypted1.ciphertext, isNot(equals(encrypted2.ciphertext)));
      });

      test('same context produces different nonces', () async {
        const plaintext = 'same plaintext';
        const context = 'same_context';

        final encrypted1 = await service.encrypt(
          plaintext: plaintext,
          context: context,
        );

        final encrypted2 = await service.encrypt(
          plaintext: plaintext,
          context: context,
        );

        // Nonces should be different (random)
        expect(encrypted1.nonce, isNot(equals(encrypted2.nonce)));
      });
    });

    group('decryption failures', () {
      test('fails with wrong context', () async {
        const plaintext = 'secret data';

        final encrypted = await service.encrypt(
          plaintext: plaintext,
          context: 'correct_context',
        );

        expect(
          () => service.decrypt(
            ciphertext: encrypted.ciphertext,
            nonce: encrypted.nonce,
            context: 'wrong_context',
          ),
          throwsA(isA<EncryptionException>()),
        );
      });

      test('fails with wrong master key', () async {
        const plaintext = 'secret data';
        const context = 'test_context';

        final encrypted = await service.encrypt(
          plaintext: plaintext,
          context: context,
        );

        // Create a new service with a different master key
        final differentKey = await EncryptionService.generateMasterKey();
        final differentService = EncryptionService(masterKey: differentKey);

        expect(
          () => differentService.decrypt(
            ciphertext: encrypted.ciphertext,
            nonce: encrypted.nonce,
            context: context,
          ),
          throwsA(isA<EncryptionException>()),
        );
      });

      test('fails with tampered ciphertext', () async {
        const plaintext = 'secret data';
        const context = 'test_context';

        final encrypted = await service.encrypt(
          plaintext: plaintext,
          context: context,
        );

        // Tamper with the ciphertext
        encrypted.ciphertext[0] ^= 0xFF;

        expect(
          () => service.decrypt(
            ciphertext: encrypted.ciphertext,
            nonce: encrypted.nonce,
            context: context,
          ),
          throwsA(isA<EncryptionException>()),
        );
      });

      test('fails with wrong nonce', () async {
        const plaintext = 'secret data';
        const context = 'test_context';

        final encrypted = await service.encrypt(
          plaintext: plaintext,
          context: context,
        );

        // Use a different nonce
        final wrongNonce = Uint8List(encrypted.nonce.length);

        expect(
          () => service.decrypt(
            ciphertext: encrypted.ciphertext,
            nonce: wrongNonce,
            context: context,
          ),
          throwsA(isA<EncryptionException>()),
        );
      });

      test('fails with truncated ciphertext', () async {
        expect(
          () => service.decrypt(
            ciphertext: Uint8List(8), // Too short
            nonce: Uint8List(12),
            context: 'test',
          ),
          throwsA(isA<EncryptionException>()),
        );
      });
    });

    group('key generation', () {
      test('generateMasterKey returns 32 bytes', () async {
        final key = await EncryptionService.generateMasterKey();
        expect(key.length, equals(32));
      });

      test('generateMasterKey returns random keys', () async {
        final key1 = await EncryptionService.generateMasterKey();
        final key2 = await EncryptionService.generateMasterKey();
        expect(key1, isNot(equals(key2)));
      });

      test('generateMasterKeyBase64 returns valid base64', () async {
        final keyBase64 = await EncryptionService.generateMasterKeyBase64();
        final decoded = base64.decode(keyBase64);
        expect(decoded.length, equals(32));
      });
    });
  });
}