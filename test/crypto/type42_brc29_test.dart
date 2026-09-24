/// BRC-29 destinations and anchor-key signatures, pinned to go-sdk (bead
/// libspiffy-zxkd).
///
/// The expected values were produced by bsv-blockchain/go-sdk v1.2.21: a
/// `wallet.KeyDeriver` for the payer key derived the destination for
/// protocol {2, "3241645161d8"} and key ID "<prefix> <suffix>" with the
/// payee's anchor key as counterparty; one for the anchor key derived the
/// spend key with the payer key as counterparty; and `PrivateKey.Sign` of
/// SHA-256 of a NodeCast registration message gave the signature. A payer
/// using libspiffy and a payee or broker using go-sdk (or the reverse) must
/// agree on every byte.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:libspiffy/libspiffy.dart';
import 'package:test/test.dart';

const _anchorPrivate = '6a1751169c111b4667a6539ee1be6b7cd9f6e9c8fe011a5f2fe31e03a15e0ede';
const _payerPrivate = 'cab2500e206f31bc18a8af9d6f44f0b9a208c32d5cca2b22acfe9d1a213b2f36';
const _anchorPublic = '02133b035cda4ba15f93b5fdde11c1f73eb9f1a79b60c6caa1c78e1c4c64ed72ce';
const _payerPublic = '02dfcbe35d95b55b5f3168ea8f12717e266ceddf88d04d2ff741272dfb0e542c2a';
const _prefix = 'SfKxPIJNgdI=';
const _suffix = 'NaGLC6fMH50=';
const _destination = '0311687dd083f8585e3e4efbb9e5bbe6ce8c6c495f1f6e6f16eff1b0d8393d05c2';
const _destinationTestnetAddress = 'mqAtCUB3FhfWaHpbcxigNZ1j4rsskWZvFj';
const _spendKey = '989db0606ebfab656abbaf31aa5abc7c52df6bf9ccd78847b8c3b74f1ccf59fc';
const _registration = 'overmedia:register_payment_pubkey:12D3KooWTestPeer:$_anchorPublic';
const _registrationSignature = '304402205a5827ef1a7855f4366ad31bb158f152a85157d9e7316aaf314b4030b9839ab1'
    '02206a7f40c0e67610e04aa9e7df75e0395f9fce578bb7d80366b308c07a7b6db60c';

dartsv.SVPrivateKey _key(String hex) => dartsv.SVPrivateKey.fromBigInt(BigInt.parse(hex, radix: 16));

void main() {
  test('the BRC-29 invoice number is spelled as go-sdk spells it', () {
    expect(Type42Derivation.brc29InvoiceNumber(_prefix, _suffix), '2-3241645161d8-$_prefix $_suffix');
  });

  test('the payer derives the destination go-sdk derives, and the payee its spend key', () {
    final invoice = Type42Derivation.brc29InvoiceNumber(_prefix, _suffix);
    final destination =
        Type42.deriveChildPublic(dartsv.SVPublicKey.fromHex(_anchorPublic), _key(_payerPrivate), invoice);
    expect(destination.toHex(), _destination);
    expect(destination.toAddress(dartsv.NetworkType.TEST).toBase58(), _destinationTestnetAddress);

    final spend = Type42.deriveChildPrivate(_key(_anchorPrivate), dartsv.SVPublicKey.fromHex(_payerPublic), invoice);
    expect(spend.privateKey.toRadixString(16).padLeft(64, '0'), _spendKey);
    expect(spend.publicKey.toHex(), _destination);
  });

  test('a signature by the anchor key over SHA-256 of a message is go-sdk\'s, byte for byte (RFC 6979, low S)',
      () async {
    final digest = Uint8List.fromList(dartsv.sha256(utf8.encode(_registration)));
    final signature = await DartSVCryptoService().signData(_key(_anchorPrivate), digest);
    expect(hex.encode(signature.toDER()), _registrationSignature);
  });

  group('Type42Derivation takes', () {
    test('a compressed public key and re-encodes it in lower case', () {
      final derivation = Type42Derivation(senderPublicKey: _payerPublic.toUpperCase().replaceFirst('0X', ''),
          invoiceNumber: 'x');
      expect(derivation.senderPublicKey, _payerPublic);
    });

    for (final (what, key) in [
      ('an uncompressed key', dartsv.SVPublicKey.fromHex(_payerPublic).getEncoded(false)),
      ('a point off the curve', '02${'00' * 31}07'),
      ('something that is not hex', 'zz' * 33),
      ('an empty key', ''),
    ]) {
      test('no $what', () {
        expect(() => Type42Derivation(senderPublicKey: key, invoiceNumber: 'x'), throwsArgumentError);
      });
    }

    test('no empty invoice number, and none longer than BRC-43 allows', () {
      expect(() => Type42Derivation(senderPublicKey: _payerPublic, invoiceNumber: ''), throwsArgumentError);
      expect(
          () => Type42Derivation(
              senderPublicKey: _payerPublic, invoiceNumber: 'x' * (Type42Derivation.maxInvoiceNumberLength + 1)),
          throwsArgumentError);
    });
  });
}
