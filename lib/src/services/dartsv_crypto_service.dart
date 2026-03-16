import 'dart:convert';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:dartsv/dartsv.dart';
import 'package:pointycastle/api.dart';
import 'package:pointycastle/digests/sha256.dart';
import 'package:pointycastle/ecc/api.dart';
import 'package:pointycastle/macs/hmac.dart';
import 'package:pointycastle/signers/ecdsa_signer.dart';
import 'package:spiffynode/spiffy_node.dart';

import '../utils/crypto_utils.dart';
import 'crypto_service.dart';

class DartSVCryptoService implements CryptoService {
  final dartsv.NetworkType _networkType;
  static final SHA256Digest _sha256Digest = SHA256Digest();
  static final ECDSASigner _dsaSigner = ECDSASigner(null, HMac(_sha256Digest, 64));
  static final ECDomainParameters _domainParams = ECDomainParameters('secp256k1');

  DartSVCryptoService({
    dartsv.NetworkType networkType = dartsv.NetworkType.TEST,
  }) : _networkType = networkType;

  @override
  Future<String> generateMnemonic({int strength = 128}) async {
    // Validate strength parameter
    if (![128, 160, 192, 224, 256].contains(strength)) {
      throw CryptoException('Invalid mnemonic strength: $strength. Must be 128, 160, 192, 224, or 256');
    }
    
    try {
      return await CryptoUtils.defaultGenerateMnemonic(strength);
    } catch (e) {
      throw CryptoException('Failed to generate mnemonic: $e');
    }
  }

  @override
  Future<bool> validateMnemonic(String mnemonic) async {
    return CryptoUtils.defaultValidateWords(mnemonic);
  }

  @override
  Future<dartsv.HDPrivateKey> mnemonicToHDPrivateKey(
    String mnemonic, {
    String passphrase = '',
    dartsv.NetworkType network = dartsv.NetworkType.TEST,
  }) async {

    final privKey = dartsv.HDPrivateKey.fromSeed(
      Mnemonic().toSeedHex(mnemonic, passphrase),
      network
    );

    return privKey;
  }

 /*
   /// Derives a child private key at the specified index.
  ///
  /// This implements BIP32 key derivation, allowing access to any address
  /// in the HD wallet hierarchy. The derivation follows the path:
  /// m/44'/236'/0'/0/[index]
  ///
  /// Parameters:
  /// - [index]: The index of the child key to derive (0 to 2^31-1)
  ///
  /// Returns the derived private key, or null if derivation fails.
  */
  @override
  Future<dartsv.SVPrivateKey> derivePrivateKey(
    dartsv.HDPrivateKey hdPrivateKey,
    int accountIndex,
    int addressIndex, {
    int coinType = 0,
    bool isChange = false,
  }) async {
    // Simplified derivation path: m/{accountIndex}/{addressIndex}
    // This intentionally uses a simplified path rather than full BIP44
    // (m/44'/236'/{account}'/{change}/{index}) for compatibility with
    // the current wallet infrastructure.
    final privKey = hdPrivateKey.deriveChildKey("m/${accountIndex}/${addressIndex}");

    return privKey.privateKey;
  }

  String generateAddress(
    dartsv.SVPrivateKey privateKey, {
    dartsv.NetworkType network = dartsv.NetworkType.TEST,
  }) {
    final address = dartsv.Address.fromPublicKey(privateKey.publicKey, network);

    return address.toBase58();
  }

  @override
  dartsv.SVPublicKey getPublicKey(dartsv.SVPrivateKey privateKey) {
    return privateKey.publicKey;
  }

  @override
  Future<dartsv.SVSignature> signTransactionHash(
    dartsv.SVPrivateKey privateKey,
    Uint8List transactionHash,
    int sigHashType,
  ) async {
    var sig = SVSignature.fromPrivateKey(privateKey);
    sig.nhashtype = sigHashType;
    sig.sign(hex.encode(transactionHash));

    return sig;
  }

  @override
  Future<dartsv.SVSignature> signData(
    dartsv.SVPrivateKey privateKey,
    Uint8List data,
  ) async {

    SVSignature signature = SVSignature.fromPrivateKey(privateKey);
    signature.sign(hex.encode(data));

    return signature;

  }

  @override
  bool verifySignature(
    dartsv.SVPublicKey publicKey,
    dartsv.SVSignature signature,
    Uint8List data,
  ) {

    var ecPubKey=  ECPublicKey(publicKey.point, _domainParams);
    _dsaSigner.init(false, PublicKeyParameter(ecPubKey));

    final sigValid = _dsaSigner.verifySignature(data, ECSignature(signature.r, signature.s));

    return sigValid;

  }

  @override
  Uint8List doubleSha256(Uint8List data) {
    return Uint8List.fromList(dartsv.sha256Twice(data));
  }

  @override
  Uint8List sha256(Uint8List data) {
    return Uint8List.fromList(dartsv.sha256(data));
  }

  @override
  dartsv.SVPrivateKey generateRandomPrivateKey({
    dartsv.NetworkType network = dartsv.NetworkType.TEST,
  }) {
    return dartsv.SVPrivateKey.new(networkType: network);
  }

  @override
  String privateKeyToWIF(
    dartsv.SVPrivateKey privateKey, {
    dartsv.NetworkType network = dartsv.NetworkType.TEST, //redundant. SVPrivateKey tracks network type internally
  }) {
    return privateKey.toWIF();
  }

  @override
  dartsv.SVPrivateKey privateKeyFromWIF(
    String wif, {
    dartsv.NetworkType network = dartsv.NetworkType.TEST, //redundant. SVPrivateKey will detect network from WIF
  }) {
    return dartsv.SVPrivateKey.fromWIF(wif);
  }

  @override
  dartsv.HDPublicKey deriveHDPublicKey(dartsv.HDPrivateKey hdPrivateKey) {
    return hdPrivateKey.hdPublicKey;
  }

  @override
  String generateReceivingAddress(
    dartsv.HDPublicKey hdPublicKey,
    int addressIndex, {
    dartsv.NetworkType network = dartsv.NetworkType.TEST,
  }) {
    final childKey= hdPublicKey.deriveChildKey("m/0/${addressIndex}");
    final address = Address.fromPublicKey(childKey.publicKey, network);
    return address.toBase58();
  }

  @override
  String generateChangeAddress(
    dartsv.HDPublicKey hdPublicKey,
    int addressIndex, {
    dartsv.NetworkType network = dartsv.NetworkType.TEST,
  }) {
    // final childKey = hdPublicKey.deriveChildNumber(addressIndex);
    final childKey= hdPublicKey.deriveChildKey("m/1/${addressIndex}");
    final address = Address.fromPublicKey(childKey.publicKey, network);
    return address.toBase58();

  }


  /// Get network type
  dartsv.NetworkType get networkType => _networkType;

}