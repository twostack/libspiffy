import 'dart:typed_data';

import 'package:dartsv/dartsv.dart' as dartsv;

/// Cryptographic service interface for Bitcoin operations
/// Provides all cryptographic functionality needed by the wallet
abstract class CryptoService {
  /// Generate a new BIP39 mnemonic phrase
  /// Returns a 12-word mnemonic phrase for wallet creation
  Future<String> generateMnemonic({int strength = 128});

  /// Validate a BIP39 mnemonic phrase
  /// Returns true if the mnemonic is valid according to BIP39 specification
  Future<bool> validateMnemonic(String mnemonic);

  /// Convert mnemonic to HD private key (BIP32 root)
  /// Returns the root HD private key derived from the mnemonic
  Future<dartsv.HDPrivateKey> mnemonicToHDPrivateKey(
    String mnemonic, {
    String passphrase = '',
    dartsv.NetworkType network = dartsv.NetworkType.TEST,
  });

  /// Derive a child private key from HD private key using BIP44 path
  /// Standard Bitcoin path: m/44'/0'/0'/0/index
  Future<dartsv.SVPrivateKey> derivePrivateKey(
    dartsv.HDPrivateKey hdPrivateKey,
    int accountIndex,
    int addressIndex, {
    int coinType = 236, // 236 for Bitcoin SV testnet
    bool isChange = false,
  });

  /// Generate address from private key
  /// Returns the Bitcoin address (P2PKH) for the given private key
  String generateAddress(
    dartsv.SVPrivateKey privateKey, {
    dartsv.NetworkType network = dartsv.NetworkType.TEST,
  });

  /// Generate public key from private key
  /// Returns the public key corresponding to the private key
  dartsv.SVPublicKey getPublicKey(dartsv.SVPrivateKey privateKey);

  /// Sign a transaction hash with a private key
  /// Returns the signature for the given transaction hash
  Future<dartsv.SVSignature> signTransactionHash(
    dartsv.SVPrivateKey privateKey,
    Uint8List transactionHash,
    int sigHashType,
  );

  /// Sign raw data with a private key
  /// Returns the signature for arbitrary data
  Future<dartsv.SVSignature> signData(
    dartsv.SVPrivateKey privateKey,
    Uint8List data,
  );

  /// Verify a signature against data and public key
  /// Returns true if the signature is valid for the data and public key
  bool verifySignature(
    dartsv.SVPublicKey publicKey,
    dartsv.SVSignature signature,
    Uint8List data,
  );

  /// Hash data using double SHA-256 (Bitcoin standard)
  /// Returns the double SHA-256 hash of the input data
  Uint8List doubleSha256(Uint8List data);

  /// Hash data using single SHA-256
  /// Returns the SHA-256 hash of the input data
  Uint8List sha256(Uint8List data);

  /// Generate a random private key
  /// Returns a new random private key (not from mnemonic)
  dartsv.SVPrivateKey generateRandomPrivateKey({
    dartsv.NetworkType network = dartsv.NetworkType.TEST,
  });

  /// Convert private key to WIF (Wallet Import Format)
  /// Returns the WIF representation of the private key
  String privateKeyToWIF(
    dartsv.SVPrivateKey privateKey, {
    dartsv.NetworkType network = dartsv.NetworkType.TEST,
  });

  /// Import private key from WIF
  /// Returns the private key from WIF string
  dartsv.SVPrivateKey privateKeyFromWIF(
    String wif, {
    dartsv.NetworkType network = dartsv.NetworkType.TEST,
  });

  /// Derive extended public key from HD private key
  /// Returns the extended public key for receiving addresses
  dartsv.HDPublicKey deriveHDPublicKey(dartsv.HDPrivateKey hdPrivateKey);

  /// Generate receiving address from HD public key
  /// Returns a receiving address at the specified index
  String generateReceivingAddress(
    dartsv.HDPublicKey hdPublicKey,
    int addressIndex, {
    dartsv.NetworkType network = dartsv.NetworkType.TEST,
  });

  /// Generate change address from HD public key
  /// Returns a change address at the specified index
  String generateChangeAddress(
    dartsv.HDPublicKey hdPublicKey,
    int addressIndex, {
    dartsv.NetworkType network = dartsv.NetworkType.TEST,
  });
}

/// Exception thrown by cryptographic operations
class CryptoException implements Exception {
  final String message;
  final String? code;
  
  CryptoException(this.message, {this.code});
  
  @override
  String toString() => 'CryptoException${code != null ? ' ($code)' : ''}: $message';
} 