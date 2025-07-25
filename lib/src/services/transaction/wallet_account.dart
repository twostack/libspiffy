import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:dartsv/dartsv.dart';

import '../crypto_service.dart';


class WalletException implements Exception {
  final String message;

  WalletException(this.message) : super();

}

abstract class WalletAccount {

  final String networkType;
  BigInt _balance = BigInt.zero;
  BigInt get balance => _balance;


  set balance(BigInt value) {
    _balance = value;
  }

  WalletAccount(this.networkType);

  // static Future<List<int>> decrypt(SecretBox secretBox, String password, List<int> nonce) async {
  //   var encryptionSecret = await CryptoService.newPbSecret(password, nonce);
  //   return await CryptoService.aesDecrypt(secretBox, encryptionSecret);
  // }
  //
  // static Future<(SecretBox, List<int>)> encrypt(String message, String password) async {
  //
  //   var nonce = CryptoService.newNonce();
  //   var encryptionSecret = await CryptoService.newPbSecret(password, nonce);
  //   return (await CryptoService.aesEncrypt(utf8.encode(message), encryptionSecret), nonce);
  //
  // }

  String address();

  SVPrivateKey? get privateKey;

  SVPublicKey? get publicKey;

  String? get accountName;

  TransactionSigner? get signer;

  Future<Map> toMap({String password = ""});

}
