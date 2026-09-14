/// PostgreSQL-based secure storage for server-side xpub-only wallets.
///
/// This implementation ONLY supports xpub storage. All private key methods
/// throw [UnimplementedError] to prevent accidental private key storage
/// on server-side deployments.
///
/// Security features:
/// - AES-256-GCM encryption for data at rest
/// - HKDF-derived per-secret encryption keys
/// - Master key from environment variable
/// - Key rotation: every row records the key version it was encrypted under,
///   and reads pick the matching key
/// - Explicit rejection of private key storage
library;

import 'dart:typed_data';

import 'package:postgres/postgres.dart';

import '../../crypto/encryption_service.dart';
import '../secure_storage.dart';

/// PostgreSQL-based secure storage that ONLY supports xpub storage.
///
/// This implementation is designed for server-side xpub-only wallets.
/// It encrypts xpubs using AES-256-GCM before storing them in PostgreSQL.
///
/// **Security Constraint**: All private key methods throw [UnimplementedError].
/// This prevents accidental private key storage on server-side deployments.
///
/// Example:
/// ```dart
/// final storage = PostgresSecureStorage(
///   pool: postgresPool,
///   encryptionService: EncryptionService.fromBase64(
///     masterKeyBase64: Platform.environment['LIBSPIFFY_MASTER_KEY']!,
///   ),
/// );
///
/// // This works
/// await storage.setXPub('wallet123', 'xpub6...');
/// final xpub = await storage.getXPub('wallet123');
///
/// // This throws UnimplementedError
/// await storage.setPrivateKey('wallet123', '...'); // THROWS!
/// ```
class PostgresSecureStorage implements SecureStorage {
  final Pool _pool;
  final EncryptionService _encryptionService;

  /// Every key this storage can decrypt with, by key version: the current
  /// [_encryptionService] plus any previous keys.
  final Map<int, EncryptionService> _keysByVersion;

  /// Prefix for xpub keys.
  static const String _xpubKeyPrefix = 'wallet_xpub_';

  /// Prefix for HD public keys (used for address derivation).
  static const String _hdPubKeyPrefix = 'wallet_hdpubkey_';

  /// Creates a new PostgreSQL secure storage.
  ///
  /// Parameters:
  /// - [pool]: PostgreSQL connection pool.
  /// - [encryptionService]: The current key. Every write is encrypted with it
  ///   and tagged with its [EncryptionService.keyVersion].
  /// - [previousKeys]: Retired keys, still used to read rows tagged with their
  ///   versions. Keep them until [reencryptToCurrentKey] has moved every row
  ///   onto the current key.
  ///
  /// Throws [ArgumentError] if two keys share a key version.
  PostgresSecureStorage({
    required Pool pool,
    required EncryptionService encryptionService,
    Iterable<EncryptionService> previousKeys = const [],
  })  : _pool = pool,
        _encryptionService = encryptionService,
        _keysByVersion = _indexKeys(encryptionService, previousKeys);

  static Map<int, EncryptionService> _indexKeys(
    EncryptionService current,
    Iterable<EncryptionService> previous,
  ) {
    final keys = {current.keyVersion: current};
    for (final key in previous) {
      if (keys.containsKey(key.keyVersion)) {
        throw ArgumentError(
          'Duplicate key version ${key.keyVersion}: each key needs its own version',
        );
      }
      keys[key.keyVersion] = key;
    }
    return keys;
  }

  /// Creates a PostgreSQL secure storage from configuration.
  ///
  /// The master key is loaded from the `LIBSPIFFY_MASTER_KEY` environment
  /// variable, which must contain a base64-encoded 32-byte key.
  ///
  /// Throws [StateError] if the environment variable is not set.
  /// Throws [ArgumentError] if the key is not 32 bytes.
  ///
  /// [previousMasterKeysBase64] maps retired key versions to their base64
  /// master keys, so rows written before a rotation stay readable.
  static Future<PostgresSecureStorage> create({
    required Pool pool,
    required String masterKeyBase64,
    int keyVersion = 1,
    Map<int, String> previousMasterKeysBase64 = const {},
  }) async {
    final encryptionService = EncryptionService.fromBase64(
      masterKeyBase64: masterKeyBase64,
      keyVersion: keyVersion,
    );

    return PostgresSecureStorage(
      pool: pool,
      encryptionService: encryptionService,
      previousKeys: [
        for (final entry in previousMasterKeysBase64.entries)
          EncryptionService.fromBase64(
            masterKeyBase64: entry.value,
            keyVersion: entry.key,
          ),
      ],
    );
  }

  /// Decrypts one stored row with the key its [keyVersion] names.
  ///
  /// Throws [SecureStorageException] naming the key and version when no key
  /// for that version is configured or decryption fails (wrong key, tampered
  /// data).
  Future<String> _decryptRow(
    String keyName,
    Uint8List encryptedValue,
    Uint8List nonce,
    int keyVersion,
  ) async {
    final key = _keysByVersion[keyVersion];
    if (key == null) {
      final known = _keysByVersion.keys.toList()..sort();
      throw SecureStorageException(
        'Secret $keyName is encrypted under key version $keyVersion, but no '
        'key for that version is configured (known versions: $known)',
      );
    }
    try {
      return await key.decrypt(
        ciphertext: encryptedValue,
        nonce: nonce,
        context: keyName,
      );
    } on EncryptionException catch (e) {
      throw SecureStorageException(
        'Failed to decrypt secret $keyName with key version $keyVersion: '
        '${e.message}',
        e,
      );
    }
  }

  // ========================================
  // XPub Operations (IMPLEMENTED)
  // ========================================

  @override
  Future<String?> getXPub(String walletId) async {
    return await getString('$_xpubKeyPrefix$walletId');
  }

  @override
  Future<void> setXPub(String walletId, String xpub) async {
    await setString('$_xpubKeyPrefix$walletId', xpub);
  }

  /// Deletes the xpub for a wallet.
  Future<void> deleteXPub(String walletId) async {
    await delete('$_xpubKeyPrefix$walletId');
  }

  // ========================================
  // Generic String Operations (LIMITED)
  // ========================================

  @override
  Future<String?> getString(String key) async {
    // Only allow xpub and hdpubkey keys
    _validateAllowedKey(key);

    try {
      final result = await _pool.execute(
        Sql.named('''
          SELECT encrypted_value, nonce, key_version
          FROM secure_secrets
          WHERE key_name = @key_name
        '''),
        parameters: {'key_name': key},
      );

      if (result.isEmpty) {
        return null;
      }

      final row = result.first;
      return await _decryptRow(
        key,
        row[0] as Uint8List,
        row[1] as Uint8List,
        row[2] as int,
      );
    } on SecureStorageException {
      rethrow;
    } catch (e) {
      throw SecureStorageException('Failed to retrieve secret: $e', e);
    }
  }

  @override
  Future<void> setString(String key, String value) async {
    // Only allow xpub and hdpubkey keys
    _validateAllowedKey(key);

    try {
      final result = await _encryptionService.encrypt(
        plaintext: value,
        context: key,
      );

      // Upsert the encrypted value
      // Note: Must use TypedValue.bytea() for Uint8List to ensure proper BYTEA encoding
      await _pool.execute(
        Sql.named('''
          INSERT INTO secure_secrets (key_name, encrypted_value, nonce, key_version, updated_at)
          VALUES (@key_name, @encrypted_value, @nonce, @key_version, NOW())
          ON CONFLICT (key_name)
          DO UPDATE SET
            encrypted_value = @encrypted_value,
            nonce = @nonce,
            key_version = @key_version,
            updated_at = NOW()
        '''),
        parameters: {
          'key_name': key,
          'encrypted_value': TypedValue(Type.byteArray, result.ciphertext),
          'nonce': TypedValue(Type.byteArray, result.nonce),
          'key_version': _encryptionService.keyVersion,
        },
      );
    } catch (e) {
      throw SecureStorageException('Failed to store secret: $e');
    }
  }

  @override
  Future<bool> containsKey(String key) async {
    _validateAllowedKey(key);

    try {
      final result = await _pool.execute(
        Sql.named('''
          SELECT 1 FROM secure_secrets WHERE key_name = @key_name LIMIT 1
        '''),
        parameters: {'key_name': key},
      );

      return result.isNotEmpty;
    } catch (e) {
      throw SecureStorageException('Failed to check key existence: $e');
    }
  }

  @override
  Future<void> delete(String key) async {
    _validateAllowedKey(key);

    try {
      await _pool.execute(
        Sql.named('DELETE FROM secure_secrets WHERE key_name = @key_name'),
        parameters: {'key_name': key},
      );
    } catch (e) {
      throw SecureStorageException('Failed to delete secret: $e');
    }
  }

  @override
  Future<void> deleteAll() async {
    // Only delete xpub-related keys
    try {
      await _pool.execute(
        Sql.named('''
          DELETE FROM secure_secrets
          WHERE key_name LIKE @xpub_pattern
             OR key_name LIKE @hdpubkey_pattern
        '''),
        parameters: {
          'xpub_pattern': '$_xpubKeyPrefix%',
          'hdpubkey_pattern': '$_hdPubKeyPrefix%',
        },
      );
    } catch (e) {
      throw SecureStorageException('Failed to delete all secrets: $e');
    }
  }

  /// Returns every xpub and hdpubkey secret, decrypted.
  ///
  /// All or nothing: if any row cannot be decrypted (no key for its version,
  /// wrong key, tampered data) this throws a [SecureStorageException] naming
  /// every such row, rather than returning a partial map that looks complete.
  @override
  Future<Map<String, String>> getAll() async {
    final Result result;
    try {
      result = await _pool.execute(
        Sql.named('''
          SELECT key_name, encrypted_value, nonce, key_version
          FROM secure_secrets
          WHERE key_name LIKE @xpub_pattern
             OR key_name LIKE @hdpubkey_pattern
        '''),
        parameters: {
          'xpub_pattern': '$_xpubKeyPrefix%',
          'hdpubkey_pattern': '$_hdPubKeyPrefix%',
        },
      );
    } catch (e) {
      throw SecureStorageException('Failed to retrieve all secrets: $e', e);
    }

    final secrets = <String, String>{};
    final failures = <SecureStorageException>[];
    for (final row in result) {
      try {
        final keyName = row[0] as String;
        secrets[keyName] = await _decryptRow(
          keyName,
          row[1] as Uint8List,
          row[2] as Uint8List,
          row[3] as int,
        );
      } on SecureStorageException catch (e) {
        failures.add(e);
      }
    }

    if (failures.isNotEmpty) {
      throw SecureStorageException(
        'Failed to decrypt ${failures.length} of ${result.length} secrets: '
        '${failures.map((e) => e.message).join('; ')}',
        failures,
      );
    }
    return secrets;
  }

  /// Re-encrypts every xpub and hdpubkey row that is not under the current
  /// key version with the current key, and returns how many rows changed.
  ///
  /// Completes a key rotation: once it returns, [previousKeys] are no longer
  /// needed. Runs in one transaction; throws [SecureStorageException] (and
  /// changes nothing) if any row cannot be decrypted.
  Future<int> reencryptToCurrentKey() async {
    try {
      return await _pool.runTx((session) async {
        final rows = await session.execute(
          Sql.named('''
            SELECT key_name, encrypted_value, nonce, key_version
            FROM secure_secrets
            WHERE key_version <> @current
              AND (key_name LIKE @xpub_pattern OR key_name LIKE @hdpubkey_pattern)
            FOR UPDATE
          '''),
          parameters: {
            'current': _encryptionService.keyVersion,
            'xpub_pattern': '$_xpubKeyPrefix%',
            'hdpubkey_pattern': '$_hdPubKeyPrefix%',
          },
        );
        for (final row in rows) {
          final keyName = row[0] as String;
          final plaintext = await _decryptRow(
            keyName,
            row[1] as Uint8List,
            row[2] as Uint8List,
            row[3] as int,
          );
          final encrypted = await _encryptionService.encrypt(
            plaintext: plaintext,
            context: keyName,
          );
          await session.execute(
            Sql.named('''
              UPDATE secure_secrets
              SET encrypted_value = @encrypted_value,
                  nonce = @nonce,
                  key_version = @key_version,
                  updated_at = NOW()
              WHERE key_name = @key_name
            '''),
            parameters: {
              'key_name': keyName,
              'encrypted_value':
                  TypedValue(Type.byteArray, encrypted.ciphertext),
              'nonce': TypedValue(Type.byteArray, encrypted.nonce),
              'key_version': _encryptionService.keyVersion,
            },
          );
        }
        return rows.length;
      });
    } on SecureStorageException {
      rethrow;
    } catch (e) {
      throw SecureStorageException('Failed to re-encrypt secrets: $e', e);
    }
  }

  /// Validates that the key is allowed for this storage implementation.
  ///
  /// Only xpub and hdpubkey keys are allowed.
  void _validateAllowedKey(String key) {
    if (!key.startsWith(_xpubKeyPrefix) && !key.startsWith(_hdPubKeyPrefix)) {
      throw UnimplementedError(
        'PostgresSecureStorage only supports xpub and hdpubkey keys. '
        'Attempted to access key: $key. '
        'Server-side wallets must be xpub-only.',
      );
    }
  }

  // ========================================
  // Private Key Operations (NOT IMPLEMENTED)
  // ========================================

  static const String _notSupportedMessage =
      'PostgresSecureStorage does not support private key storage. '
      'Server-side wallets must be xpub-only.';

  @override
  Future<String?> getPrivateKey(String walletId) {
    throw UnimplementedError(_notSupportedMessage);
  }

  @override
  Future<void> setPrivateKey(String walletId, String privateKey) {
    throw UnimplementedError(_notSupportedMessage);
  }

  @override
  Future<String?> getMnemonic(String walletId) {
    throw UnimplementedError(_notSupportedMessage);
  }

  @override
  Future<void> setMnemonic(String walletId, String mnemonic) {
    throw UnimplementedError(_notSupportedMessage);
  }

  @override
  Future<String?> getWIF(String walletId) {
    throw UnimplementedError(_notSupportedMessage);
  }

  @override
  Future<void> setWIF(String walletId, String wif) {
    throw UnimplementedError(_notSupportedMessage);
  }

  @override
  Future<String?> getXPriv(String walletId) {
    throw UnimplementedError(_notSupportedMessage);
  }

  @override
  Future<void> setXPriv(String walletId, String xpriv) {
    throw UnimplementedError(_notSupportedMessage);
  }

  // ========================================
  // Identity Operations (NOT IMPLEMENTED)
  // ========================================

  @override
  Future<String?> getIdentityKey(String identityId) {
    throw UnimplementedError(
      'PostgresSecureStorage does not support identity key storage. '
      'Server-side deployments should not store identity keys.',
    );
  }

  @override
  Future<void> setIdentityKey(String identityId, String privateKey) {
    throw UnimplementedError(
      'PostgresSecureStorage does not support identity key storage. '
      'Server-side deployments should not store identity keys.',
    );
  }

  @override
  Future<List<String>> getIdentityIds() {
    throw UnimplementedError(
      'PostgresSecureStorage does not support identity operations. '
      'Server-side deployments should not store identity keys.',
    );
  }

  // ========================================
  // Account Metadata Operations (NOT IMPLEMENTED)
  // ========================================

  @override
  Future<void> setAccountMetadata(String accountId, Map<String, String> metadata) {
    throw UnimplementedError(
      'PostgresSecureStorage does not support account metadata. '
      'Use the read model storage for non-sensitive metadata.',
    );
  }

  @override
  Future<Map<String, String>> getAccountMetadata(String accountId) {
    throw UnimplementedError(
      'PostgresSecureStorage does not support account metadata. '
      'Use the read model storage for non-sensitive metadata.',
    );
  }

  @override
  Future<void> deleteAccountMetadata(String accountId) {
    throw UnimplementedError(
      'PostgresSecureStorage does not support account metadata. '
      'Use the read model storage for non-sensitive metadata.',
    );
  }
}