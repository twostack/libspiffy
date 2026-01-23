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
/// - Explicit rejection of private key storage
library;

import 'dart:typed_data';

import 'package:postgres/postgres.dart';

import '../../crypto/encryption_service.dart';
import '../secure_storage.dart';
import 'package:convert/convert.dart';

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

  /// Prefix for xpub keys.
  static const String _xpubKeyPrefix = 'wallet_xpub_';

  /// Prefix for HD public keys (used for address derivation).
  static const String _hdPubKeyPrefix = 'wallet_hdpubkey_';

  /// Creates a new PostgreSQL secure storage.
  ///
  /// Parameters:
  /// - [pool]: PostgreSQL connection pool.
  /// - [encryptionService]: Service for encrypting/decrypting data.
  PostgresSecureStorage({
    required Pool pool,
    required EncryptionService encryptionService,
  })  : _pool = pool,
        _encryptionService = encryptionService;

  /// Creates a PostgreSQL secure storage from configuration.
  ///
  /// The master key is loaded from the `LIBSPIFFY_MASTER_KEY` environment
  /// variable, which must contain a base64-encoded 32-byte key.
  ///
  /// Throws [StateError] if the environment variable is not set.
  /// Throws [ArgumentError] if the key is not 32 bytes.
  static Future<PostgresSecureStorage> create({
    required Pool pool,
    required String masterKeyBase64,
    int keyVersion = 1,
  }) async {
    final encryptionService = EncryptionService.fromBase64(
      masterKeyBase64: masterKeyBase64,
      keyVersion: keyVersion,
    );

    return PostgresSecureStorage(
      pool: pool,
      encryptionService: encryptionService,
    );
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
          SELECT encrypted_value, nonce
          FROM secure_secrets
          WHERE key_name = @key_name
        '''),
        parameters: {'key_name': key},
      );

      if (result.isEmpty) {
        return null;
      }

      final row = result.first;
      final encryptedValue = row[0] as Uint8List;
      final nonce = row[1] as Uint8List;


      return await _encryptionService.decrypt(
        ciphertext: encryptedValue,
        nonce: nonce,
        context: key,
      );
    } catch (e) {
      throw SecureStorageException('Failed to retrieve secret: $e');
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

  @override
  Future<Map<String, String>> getAll() async {
    // Only return xpub-related keys
    try {
      final result = await _pool.execute(
        Sql.named('''
          SELECT key_name, encrypted_value, nonce
          FROM secure_secrets
          WHERE key_name LIKE @xpub_pattern
             OR key_name LIKE @hdpubkey_pattern
        '''),
        parameters: {
          'xpub_pattern': '$_xpubKeyPrefix%',
          'hdpubkey_pattern': '$_hdPubKeyPrefix%',
        },
      );

      final secrets = <String, String>{};
      for (final row in result) {
        final keyName = row[0] as String;
        final encryptedValue = row[1] as Uint8List;
        final nonce = row[2] as Uint8List;

        try {
          final decrypted = await _encryptionService.decrypt(
            ciphertext: encryptedValue,
            nonce: nonce,
            context: keyName,
          );
          secrets[keyName] = decrypted;
        } catch (e) {
          // Skip secrets that fail to decrypt (e.g., wrong key version)
        }
      }

      return secrets;
    } catch (e) {
      throw SecureStorageException('Failed to retrieve all secrets: $e');
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