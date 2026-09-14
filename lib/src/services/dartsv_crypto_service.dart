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

/// [CryptoService] backed by dartsv.
///
/// ## Key derivation and its trust boundary (audit 2026-09-14 KM-10)
///
/// HD wallets use a two-level, entirely non-hardened scheme directly under
/// the wallet's root key: receive keys are `m/0/i`, change keys `m/1/i`
/// (see [derivePrivateKey], [generateReceivingAddress],
/// [generateChangeAddress]). For a mnemonic wallet the root is the BIP32
/// master key; for an xpriv wallet it is the imported key. The matching
/// extended public key is what the wallet stores as its xpub
/// (`wallet_hdpubkey_<walletId>` in secure storage) and what watch-only
/// wallets are created from.
///
/// Because no level is hardened, **that xpub together with any single
/// derived child private key yields the root extended private key**, and
/// with it every key of the wallet (the standard BIP32 non-hardened parent
/// recovery). Consequences:
///
/// * The stored xpub is not "just public data". It reveals every address
///   and the balance, and it is one leaked child key away from full spend
///   authority. Keep it in secure storage and out of logs and the event
///   journal.
/// * **Per-address private-key export (for example handing out the WIF of a
///   receive address, or a sweep/"export key" feature) must never be offered
///   under this scheme.** It would require a hardened level between the root
///   and the exported keys (for example `m/44'/236'/0'/0/i`), which changes
///   every derived address and therefore needs a wallet migration.
/// * The same applies to any component that receives child private keys
///   (plugins, signing callbacks, remote signers): it must be trusted with
///   the whole wallet, not just the one address.
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

  /// Derives the private key for an address produced by
  /// [generateReceivingAddress] (m/0/{index}) or [generateChangeAddress]
  /// (m/1/{index}).
  ///
  /// This service uses a simplified two-level scheme, m/{chain}/{index},
  /// rather than full BIP44; the first path component is the chain. The
  /// chain is 1 when [isChange] is true, otherwise [accountIndex] (every
  /// in-tree caller passes 0, so receive keys are m/0/{index}). Before the
  /// 2026-09 audit (H3) [isChange] was ignored and change-chain keys could
  /// never be derived. [coinType] is unused in this scheme.
  ///
  /// The returned key is a non-hardened child of the wallet root: together
  /// with the wallet xpub it recovers the root xpriv. Use it to sign inside
  /// the wallet; never export it (see the class documentation, KM-10).
  @override
  Future<dartsv.SVPrivateKey> derivePrivateKey(
    dartsv.HDPrivateKey hdPrivateKey,
    int accountIndex,
    int addressIndex, {
    int coinType = 0,
    bool isChange = false,
  }) async {
    final chain = isChange ? 1 : accountIndex;
    final privKey = hdPrivateKey.deriveChildKey("m/$chain/$addressIndex");

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