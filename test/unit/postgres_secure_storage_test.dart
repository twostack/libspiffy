import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:mockito/mockito.dart';
import 'package:mockito/annotations.dart';
import 'package:postgres/postgres.dart';

import 'package:libspiffy/src/crypto/encryption_service.dart';
import 'package:libspiffy/src/storage/postgres/postgres_secure_storage.dart';
import 'package:libspiffy/src/storage/secure_storage.dart';

@GenerateMocks([Pool, Result])
import 'postgres_secure_storage_test.mocks.dart';

void main() {
  group('PostgresSecureStorage', () {
    late PostgresSecureStorage storage;
    late MockPool mockPool;
    late EncryptionService encryptionService;

    setUp(() async {
      mockPool = MockPool();
      final masterKey = await EncryptionService.generateMasterKey();
      encryptionService = EncryptionService(masterKey: masterKey);
      storage = PostgresSecureStorage(
        pool: mockPool,
        encryptionService: encryptionService,
      );
    });

    group('xpub operations', () {
      test('setXPub and getXPub use correct key format', () async {
        const walletId = 'test-wallet-123';
        const xpub = 'xpub6ABC123...';

        // Mock the upsert call
        when(mockPool.execute(any, parameters: anyNamed('parameters')))
            .thenAnswer((_) async => MockResult());

        // This verifies the key format without actually hitting the database
        // The actual database interaction is tested in integration tests
        await storage.setXPub(walletId, xpub);

        verify(mockPool.execute(
          argThat(isA<Sql>()),
          parameters: argThat(
            predicate<Map<String, Object?>>((params) =>
                params['key_name'] == 'wallet_xpub_$walletId'),
            named: 'parameters',
          ),
        )).called(1);
      });
    });

    group('private key operations throw UnimplementedError', () {
      test('getPrivateKey throws UnimplementedError', () {
        expect(
          () => storage.getPrivateKey('wallet123'),
          throwsA(isA<UnimplementedError>()),
        );
      });

      test('setPrivateKey throws UnimplementedError', () {
        expect(
          () => storage.setPrivateKey('wallet123', 'privatekey'),
          throwsA(isA<UnimplementedError>()),
        );
      });

      test('getMnemonic throws UnimplementedError', () {
        expect(
          () => storage.getMnemonic('wallet123'),
          throwsA(isA<UnimplementedError>()),
        );
      });

      test('setMnemonic throws UnimplementedError', () {
        expect(
          () => storage.setMnemonic('wallet123', 'word1 word2 ...'),
          throwsA(isA<UnimplementedError>()),
        );
      });

      test('getWIF throws UnimplementedError', () {
        expect(
          () => storage.getWIF('wallet123'),
          throwsA(isA<UnimplementedError>()),
        );
      });

      test('setWIF throws UnimplementedError', () {
        expect(
          () => storage.setWIF('wallet123', 'wif'),
          throwsA(isA<UnimplementedError>()),
        );
      });

      test('getXPriv throws UnimplementedError', () {
        expect(
          () => storage.getXPriv('wallet123'),
          throwsA(isA<UnimplementedError>()),
        );
      });

      test('setXPriv throws UnimplementedError', () {
        expect(
          () => storage.setXPriv('wallet123', 'xpriv'),
          throwsA(isA<UnimplementedError>()),
        );
      });
    });

    group('identity operations throw UnimplementedError', () {
      test('getIdentityKey throws UnimplementedError', () {
        expect(
          () => storage.getIdentityKey('identity123'),
          throwsA(isA<UnimplementedError>()),
        );
      });

      test('setIdentityKey throws UnimplementedError', () {
        expect(
          () => storage.setIdentityKey('identity123', 'key'),
          throwsA(isA<UnimplementedError>()),
        );
      });

      test('getIdentityIds throws UnimplementedError', () {
        expect(
          () => storage.getIdentityIds(),
          throwsA(isA<UnimplementedError>()),
        );
      });
    });

    group('account metadata operations throw UnimplementedError', () {
      test('setAccountMetadata throws UnimplementedError', () {
        expect(
          () => storage.setAccountMetadata('account123', {'key': 'value'}),
          throwsA(isA<UnimplementedError>()),
        );
      });

      test('getAccountMetadata throws UnimplementedError', () {
        expect(
          () => storage.getAccountMetadata('account123'),
          throwsA(isA<UnimplementedError>()),
        );
      });

      test('deleteAccountMetadata throws UnimplementedError', () {
        expect(
          () => storage.deleteAccountMetadata('account123'),
          throwsA(isA<UnimplementedError>()),
        );
      });
    });

    group('key validation', () {
      test('getString rejects non-xpub keys', () {
        expect(
          () => storage.getString('some_other_key'),
          throwsA(isA<UnimplementedError>()),
        );
      });

      test('getString accepts wallet_xpub_ keys', () async {
        // Mock empty result
        final mockResult = MockResult();
        when(mockResult.isEmpty).thenReturn(true);
        when(mockPool.execute(any, parameters: anyNamed('parameters')))
            .thenAnswer((_) async => mockResult);

        // Should not throw
        await storage.getString('wallet_xpub_test123');
      });

      test('getString accepts wallet_hdpubkey_ keys', () async {
        // Mock empty result
        final mockResult = MockResult();
        when(mockResult.isEmpty).thenReturn(true);
        when(mockPool.execute(any, parameters: anyNamed('parameters')))
            .thenAnswer((_) async => mockResult);

        // Should not throw
        await storage.getString('wallet_hdpubkey_test123');
      });

      test('setString rejects non-xpub keys', () {
        expect(
          () => storage.setString('private_key_test', 'value'),
          throwsA(isA<UnimplementedError>()),
        );
      });

      test('containsKey rejects non-xpub keys', () {
        expect(
          () => storage.containsKey('private_key_test'),
          throwsA(isA<UnimplementedError>()),
        );
      });

      test('delete rejects non-xpub keys', () {
        expect(
          () => storage.delete('private_key_test'),
          throwsA(isA<UnimplementedError>()),
        );
      });
    });

    group('error messages', () {
      test('private key error message mentions xpub-only', () {
        try {
          storage.setPrivateKey('wallet', 'key');
          fail('Should have thrown');
        } on UnimplementedError catch (e) {
          expect(e.message, contains('xpub-only'));
        }
      });

      test('private key error message mentions server-side', () {
        try {
          storage.getPrivateKey('wallet');
          fail('Should have thrown');
        } on UnimplementedError catch (e) {
          expect(e.message, contains('Server-side'));
        }
      });

      test('invalid key error message is descriptive', () async {
        try {
          await storage.getString('wallet_private_key_123');
          fail('Should have thrown');
        } on UnimplementedError catch (e) {
          expect(e.message, contains('xpub'));
          expect(e.message, contains('hdpubkey'));
        }
      });
    });
  });
}