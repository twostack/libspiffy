/// Abstract interface for secure storage operations.
/// 
/// This interface provides platform-agnostic secure storage for sensitive
/// wallet data like private keys, mnemonics, and identity information.
/// 
/// Platform-specific implementations should provide:
/// - Flutter: Use FlutterSecureStorage
/// - Desktop: Use OS keychain/credential manager
/// - Web: Use encrypted IndexedDB
/// - Server: Use encrypted configuration files
/// - Enterprise: Hardware Security Module (HSM) integration
abstract class SecureStorage {
  // ========================================
  // Basic Secure Storage Operations
  // ========================================
  
  /// Get a string value by key.
  /// 
  /// Returns null if the key doesn't exist.
  /// 
  /// Parameters:
  /// - [key]: The key to retrieve
  /// 
  /// Returns: The stored value or null
  /// 
  /// Throws [SecureStorageException] if the operation fails
  Future<String?> getString(String key);
  
  /// Store a string value with the given key.
  /// 
  /// Parameters:
  /// - [key]: The key to store under
  /// - [value]: The value to store
  /// 
  /// Throws [SecureStorageException] if the operation fails
  Future<void> setString(String key, String value);
  
  /// Check if a key exists in secure storage.  
  /// 
  /// Parameters:
  /// - [key]: The key to check
  /// 
  /// Returns: true if the key exists, false otherwise
  /// 
  /// Throws [SecureStorageException] if the operation fails
  Future<bool> containsKey(String key);
  
  /// Delete a key-value pair from secure storage.
  /// 
  /// Parameters:
  /// - [key]: The key to delete
  /// 
  /// Throws [SecureStorageException] if the operation fails
  Future<void> delete(String key);
  
  /// Delete all data from secure storage.
  /// 
  /// ⚠️ **WARNING**: This will remove ALL secure data. Use with extreme caution.
  /// 
  /// Throws [SecureStorageException] if the operation fails
  Future<void> deleteAll();
  
  /// Get all key-value pairs from secure storage.
  /// 
  /// This should be used sparingly for debugging or migration purposes.
  /// 
  /// Returns: Map of all stored key-value pairs
  /// 
  /// Throws [SecureStorageException] if the operation fails
  Future<Map<String, String>> getAll();
  
  // ========================================
  // Wallet-Specific Operations
  // ========================================
  
  /// Get the private key for a specific wallet.
  /// 
  /// Parameters:
  /// - [walletId]: Unique identifier for the wallet
  /// 
  /// Returns: The private key or null if not found
  /// 
  /// Throws [SecureStorageException] if the operation fails
  Future<String?> getPrivateKey(String walletId) async {
    return await getString('wallet_private_key_$walletId');
  }
  
  /// Store the private key for a specific wallet.
  /// 
  /// Parameters:
  /// - [walletId]: Unique identifier for the wallet  
  /// - [privateKey]: The private key to store
  /// 
  /// Throws [SecureStorageException] if the operation fails
  Future<void> setPrivateKey(String walletId, String privateKey) async {
    await setString('wallet_private_key_$walletId', privateKey);
  }
  
  /// Get the mnemonic phrase for a specific wallet.
  /// 
  /// Parameters:
  /// - [walletId]: Unique identifier for the wallet
  /// 
  /// Returns: The mnemonic phrase or null if not found
  /// 
  /// Throws [SecureStorageException] if the operation fails
  Future<String?> getMnemonic(String walletId) async {
    return await getString('wallet_mnemonic_$walletId');
  }
  
  /// Store the mnemonic phrase for a specific wallet.
  /// 
  /// Parameters:
  /// - [walletId]: Unique identifier for the wallet
  /// - [mnemonic]: The mnemonic phrase to store
  /// 
  /// Throws [SecureStorageException] if the operation fails
  Future<void> setMnemonic(String walletId, String mnemonic) async {
    await setString('wallet_mnemonic_$walletId', mnemonic);
  }
  
  // ========================================
  // Identity Operations
  // ========================================
  
  /// Get the private key for a specific identity.
  /// 
  /// Parameters:
  /// - [identityId]: Unique identifier for the identity
  /// 
  /// Returns: The identity private key or null if not found
  /// 
  /// Throws [SecureStorageException] if the operation fails
  Future<String?> getIdentityKey(String identityId) async {
    return await getString('identity_private_key_$identityId');
  }
  
  /// Store the private key for a specific identity.
  /// 
  /// Parameters:
  /// - [identityId]: Unique identifier for the identity
  /// - [privateKey]: The identity private key to store
  /// 
  /// Throws [SecureStorageException] if the operation fails
  Future<void> setIdentityKey(String identityId, String privateKey) async {
    await setString('identity_private_key_$identityId', privateKey);
  }
  
  /// Get all identity IDs that have stored keys.
  /// 
  /// Returns: List of identity identifiers
  /// 
  /// Throws [SecureStorageException] if the operation fails
  Future<List<String>> getIdentityIds() async {
    final allKeys = await getAll();
    const prefix = 'identity_private_key_';
    
    return allKeys.keys
        .where((key) => key.startsWith(prefix))
        .map((key) => key.substring(prefix.length))
        .toList();
  }
  
  // ========================================
  // Account Metadata Operations
  // ========================================
  
  /// Store metadata for a specific account.
  /// 
  /// This is used for non-sensitive account information that still
  /// needs to be stored securely (e.g., account names, preferences).
  /// 
  /// Parameters:
  /// - [accountId]: Unique identifier for the account
  /// - [metadata]: Key-value pairs of metadata
  /// 
  /// Throws [SecureStorageException] if the operation fails
  Future<void> setAccountMetadata(String accountId, Map<String, String> metadata) async {
    for (final entry in metadata.entries) {
      await setString('account_metadata_${accountId}_${entry.key}', entry.value);
    }
  }
  
  /// Get metadata for a specific account.
  /// 
  /// Parameters:
  /// - [accountId]: Unique identifier for the account
  /// 
  /// Returns: Map of account metadata
  /// 
  /// Throws [SecureStorageException] if the operation fails
  Future<Map<String, String>> getAccountMetadata(String accountId) async {
    final allKeys = await getAll();
    final prefix = 'account_metadata_${accountId}_';
    final metadata = <String, String>{};
    
    for (final entry in allKeys.entries) {
      if (entry.key.startsWith(prefix)) {
        final metaKey = entry.key.substring(prefix.length);
        metadata[metaKey] = entry.value;
      }
    }
    
    return metadata;
  }
  
  /// Delete all metadata for a specific account.
  /// 
  /// Parameters:
  /// - [accountId]: Unique identifier for the account
  /// 
  /// Throws [SecureStorageException] if the operation fails
  Future<void> deleteAccountMetadata(String accountId) async {
    final allKeys = await getAll();
    final prefix = 'account_metadata_${accountId}_';
    
    for (final key in allKeys.keys) {
      if (key.startsWith(prefix)) {
        await delete(key);
      }
    }
  }
}

/// Exception thrown when secure storage operations fail.
class SecureStorageException implements Exception {
  final String message;
  final Object? cause;
  
  const SecureStorageException(this.message, [this.cause]);
  
  @override
  String toString() {
    if (cause != null) {
      return 'SecureStorageException: $message (caused by: $cause)';
    }
    return 'SecureStorageException: $message';
  }
} 