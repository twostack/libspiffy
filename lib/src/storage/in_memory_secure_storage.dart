import 'secure_storage.dart';

/// In-memory implementation of SecureStorage for development and testing.
/// 
/// ⚠️ **WARNING**: This implementation stores sensitive data in plain memory.
/// It is NOT secure and should ONLY be used for:
/// - Development and testing
/// - Demos and prototypes
/// - Unit testing
/// 
/// **DO NOT USE IN PRODUCTION** - sensitive data will be stored in plain text
/// and can be accessed by any code with memory access.
/// 
/// For production use, implement platform-specific secure storage:
/// - Flutter: Use FlutterSecureStorage
/// - Desktop: Use OS keychain/credential manager  
/// - Web: Use encrypted IndexedDB
/// - Server: Use encrypted configuration files
class InMemorySecureStorage implements SecureStorage {
  /// In-memory storage map
  final Map<String, String> _storage = <String, String>{};
  
  /// Flag to track if storage has been initialized
  bool _isInitialized = true;
  
  /// Get storage statistics for debugging
  Map<String, dynamic> get debugInfo => {
    'totalKeys': _storage.length,
    'storageSize': _calculateStorageSize(),
    'keyTypes': _analyzeKeyTypes(),
    'initialized': _isInitialized,
  };
  
  /// Calculate approximate storage size in bytes
  int _calculateStorageSize() {
    return _storage.entries.fold<int>(
      0,
      (size, entry) => size + entry.key.length + entry.value.length,
    );
  }
  
  /// Analyze key types for debugging
  Map<String, int> _analyzeKeyTypes() {
    final types = <String, int>{};
    
    for (final key in _storage.keys) {
      String keyType;
      if (key.startsWith('wallet_private_key_')) {
        keyType = 'wallet_private_keys';
      } else if (key.startsWith('wallet_mnemonic_')) {
        keyType = 'wallet_mnemonics';
      } else if (key.startsWith('wallet_wif_')) {
        keyType = 'wallet_wifs';
      } else if (key.startsWith('wallet_xpriv_')) {
        keyType = 'wallet_xprivs';
      } else if (key.startsWith('identity_private_key_')) {
        keyType = 'identity_keys';
      } else if (key.startsWith('account_metadata_')) {
        keyType = 'account_metadata';
      } else {
        keyType = 'other';
      }
      
      types[keyType] = (types[keyType] ?? 0) + 1;
    }
    
    return types;
  }
  
  // ========================================
  // Required Abstract Method Implementations
  // ========================================
  
  @override
  Future<String?> getString(String key) async {
    _ensureInitialized();
    return _storage[key];
  }
  
  @override
  Future<void> setString(String key, String value) async {
    _ensureInitialized();
    _storage[key] = value;
  }
  
  @override
  Future<bool> containsKey(String key) async {
    _ensureInitialized();
    return _storage.containsKey(key);
  }
  
  @override
  Future<void> delete(String key) async {
    _ensureInitialized();
    _storage.remove(key);
  }
  
  @override
  Future<void> deleteAll() async {
    _ensureInitialized();
    _storage.clear();
  }
  
  @override
  Future<Map<String, String>> getAll() async {
    _ensureInitialized();
    return Map<String, String>.from(_storage);
  }
  
  // ========================================
  // Wallet-Specific Operations (inherited implementations)
  // ========================================
  
  @override
  Future<String?> getPrivateKey(String walletId) async {
    return await getString('wallet_private_key_$walletId');
  }
  
  @override
  Future<void> setPrivateKey(String walletId, String privateKey) async {
    await setString('wallet_private_key_$walletId', privateKey);
  }
  
  @override
  Future<String?> getMnemonic(String walletId) async {
    return await getString('wallet_mnemonic_$walletId');
  }
  
  @override
  Future<void> setMnemonic(String walletId, String mnemonic) async {
    await setString('wallet_mnemonic_$walletId', mnemonic);
  }
  
  @override
  Future<String?> getWIF(String walletId) async {
    return await getString('wallet_wif_$walletId');
  }
  
  @override
  Future<void> setWIF(String walletId, String wif) async {
    await setString('wallet_wif_$walletId', wif);
  }
  
  @override
  Future<String?> getXPriv(String walletId) async {
    return await getString('wallet_xpriv_$walletId');
  }
  
  @override
  Future<void> setXPriv(String walletId, String xpriv) async {
    await setString('wallet_xpriv_$walletId', xpriv);
  }
  
  // ========================================
  // Identity Operations (inherited implementations)
  // ========================================
  
  @override
  Future<String?> getIdentityKey(String identityId) async {
    return await getString('identity_private_key_$identityId');
  }
  
  @override
  Future<void> setIdentityKey(String identityId, String privateKey) async {
    await setString('identity_private_key_$identityId', privateKey);
  }
  
  @override
  Future<List<String>> getIdentityIds() async {
    final allKeys = await getAll();
    const prefix = 'identity_private_key_';
    
    return allKeys.keys
        .where((key) => key.startsWith(prefix))
        .map((key) => key.substring(prefix.length))
        .toList();
  }
  
  // ========================================
  // Account Metadata Operations (inherited implementations) 
  // ========================================
  
  @override
  Future<void> setAccountMetadata(String accountId, Map<String, String> metadata) async {
    for (final entry in metadata.entries) {
      await setString('account_metadata_${accountId}_${entry.key}', entry.value);
    }
  }
  
  @override
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
  
  @override
  Future<void> deleteAccountMetadata(String accountId) async {
    final allKeys = await getAll();
    final prefix = 'account_metadata_${accountId}_';
    
    for (final key in allKeys.keys) {
      if (key.startsWith(prefix)) {
        await delete(key);
      }
    }
  }
  
  // ========================================
  // Additional Helper Methods
  // ========================================
  
  /// Ensure storage is initialized (throws exception if not)
  void _ensureInitialized() {
    if (!_isInitialized) {
      throw SecureStorageException('Storage not initialized');
    }
  }
  
  /// Clear all data and mark as uninitialized (for testing)
  void reset() {
    _storage.clear();
    _isInitialized = false;
  }
  
  /// Reinitialize storage (for testing)
  void initialize() {
    _isInitialized = true;
  }
  
  /// Get all wallet IDs that have stored private keys
  Future<List<String>> getWalletIds() async {
    final allKeys = await getAll();
    const prefix = 'wallet_private_key_';
    
    return allKeys.keys
        .where((key) => key.startsWith(prefix))
        .map((key) => key.substring(prefix.length))
        .toList();
  }
  
  /// Delete all data for a specific wallet
  Future<void> deleteWalletData(String walletId) async {
    await delete('wallet_private_key_$walletId');
    await delete('wallet_mnemonic_$walletId');
    await delete('wallet_wif_$walletId');
    await delete('wallet_xpriv_$walletId');
    await deleteAccountMetadata(walletId);
  }
} 