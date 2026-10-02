import 'dart:convert';
import 'dart:io';

import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:libspiffy/src/crypto/brc100_keys.dart';
import 'package:test/test.dart';

/// Pins [Brc100Keys] to the published BRC-100 conformance vectors
/// (`bsv-blockchain/ts-stack` `conformance/vectors`, commit 022f1a2),
/// copied into `test/data/brc100/`.
///
/// Not run: `hashToDirectlySign`/`hashToDirectlyVerify` vectors (no
/// caller of ours signs a digest it chose), and the expected bytes of
/// `encrypt.json` (the reference encrypts under a random IV, so those
/// bytes cannot be reproduced; `decrypt.json` pins the scheme instead).
void main() {
  List<Map<String, dynamic>> vectors(String file) =>
      (jsonDecode(File('test/data/brc100/$file').readAsStringSync())['vectors'] as List)
          .cast<Map<String, dynamic>>();

  Brc100Keys keysOf(Map<String, dynamic> input) =>
      Brc100Keys(dartsv.SVPrivateKey.fromHex(input['root_key'] as String, dartsv.NetworkType.MAIN));

  Brc43Protocol protocolOf(Map<String, dynamic> args) {
    final id = args['protocolID'] as List;
    return Brc43Protocol(id[0] as int, id[1] as String);
  }

  Brc100Counterparty counterpartyOf(Map<String, dynamic> args, String fallback) =>
      Brc100Counterparty.parse(args['counterparty'] as String? ?? fallback);

  List<int> bytesOf(Object? value) =>
      value is String ? utf8.encode(value) : (value as List).cast<int>();

  String hexOf(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

  /// Runs [body] for each vector of [file], expecting a throw where the
  /// vector expects an error carrying a message (an invalid argument).
  void forEachVector(String file, void Function(Map<String, dynamic> args, Map<String, dynamic> expected, Brc100Keys keys) body,
      {bool Function(Map<String, dynamic> args)? skip}) {
    group(file, () {
      for (final v in vectors(file)) {
        final input = v['input'] as Map<String, dynamic>;
        final args = input['args'] as Map<String, dynamic>;
        final expected = v['expected'] as Map<String, dynamic>;
        if (skip?.call(args) ?? false) continue;
        test('${v['id']}: ${v['description']}', () {
          final keys = keysOf(input);
          // The reference throws on a malformed signature; ours answers
          // false, which is the same verdict.
          if (expected['message'] == 'Signature is not valid') {
            body(args, {'valid': false}, keys);
          } else if (expected['error'] == true && expected['message'] != null) {
            expect(() => body(args, expected, keys), throwsArgumentError);
          } else {
            body(args, expected, keys);
          }
        });
      }
    });
  }

  forEachVector('getpublickey.json', (args, expected, keys) {
    final key = keys.derivePublicKey(protocolOf(args), args['keyID'] as String, counterpartyOf(args, 'self'),
        forSelf: args['forSelf'] as bool? ?? false);
    expect(key.toHex(), expected['publicKey']);
  });

  forEachVector('payment-derivation.json', (args, expected, keys) {
    final key = keys.derivePublicKey(protocolOf(args), args['keyID'] as String, counterpartyOf(args, 'self'),
        forSelf: args['forSelf'] as bool? ?? false);
    expect(key.toHex(), expected['publicKey']);
  });

  forEachVector('createsignature.json', (args, expected, keys) {
    final signature = keys.createSignature(protocolOf(args), args['keyID'] as String, bytesOf(args['data']),
        counterparty: counterpartyOf(args, 'anyone'));
    expect(hexOf(signature), hexOf((expected['signature'] as List).cast<int>()));
  }, skip: (args) => args.containsKey('hashToDirectlySign'));

  forEachVector('verifysignature.json', (args, expected, keys) {
    final valid = keys.verifySignature(protocolOf(args), args['keyID'] as String, bytesOf(args['data']),
        bytesOf(args['signature']),
        counterparty: counterpartyOf(args, 'self'), forSelf: args['forSelf'] as bool? ?? false);
    expect(valid, expected['valid'] == true);
  }, skip: (args) => args.containsKey('hashToDirectlyVerify'));

  forEachVector('decrypt.json', (args, expected, keys) {
    Object? plaintext;
    try {
      plaintext = keys.decrypt(protocolOf(args), args['keyID'] as String, bytesOf(args['ciphertext']),
          counterparty: counterpartyOf(args, 'self'));
    } on ArgumentError {
      if (expected['error'] == true && expected['message'] == null) return; // undecryptable, as expected
      rethrow;
    }
    expect(expected['error'], isNot(true), reason: 'decrypted what should not decrypt');
    expect(plaintext, bytesOf(expected['plaintext']));
  });

  forEachVector('encrypt.json', (args, expected, keys) {
    final protocol = protocolOf(args);
    final keyID = args['keyID'] as String;
    final counterparty = counterpartyOf(args, 'self');
    final data = bytesOf(args['data']);
    final ciphertext = keys.encrypt(protocol, keyID, data, counterparty: counterparty);
    expect(ciphertext.length, 32 + data.length + 16);
    expect(keys.decrypt(protocol, keyID, ciphertext, counterparty: counterparty), data);
  });

  forEachVector('createhmac.json', (args, expected, keys) {
    final hmac = keys.createHmac(protocolOf(args), args['keyID'] as String, bytesOf(args['data']),
        counterparty: counterpartyOf(args, 'self'));
    expect(hexOf(hmac), hexOf((expected['hmac'] as List).cast<int>()));
  });

  forEachVector('verifyhmac.json', (args, expected, keys) {
    final valid = keys.verifyHmac(protocolOf(args), args['keyID'] as String, bytesOf(args['data']),
        bytesOf(args['hmac']),
        counterparty: counterpartyOf(args, 'self'));
    expect(valid, expected['valid'] == true);
  });

  group('between two parties', () {
    final alice = Brc100Keys(dartsv.SVPrivateKey.fromHex(
        '6a1751169c111b4667a6539ee1be6b7cd9f6e9c8fe011a5f2fe31e03a15e0ede', dartsv.NetworkType.MAIN));
    final bob = Brc100Keys(dartsv.SVPrivateKey.fromHex(
        '583755110a8c059de5cd81b8a04e1be884c46083ade3f779c1e022f6f89da94c', dartsv.NetworkType.MAIN));
    final toBob = Brc100Counterparty.key(bob.identityKey);
    final toAlice = Brc100Counterparty.key(alice.identityKey);

    test('what one encrypts to the other, the other decrypts (message box bodies)', () {
      final body = utf8.encode('{"amount":1000}');
      final sealed = alice.encrypt(Brc43Protocol.messageBox, '1', body, counterparty: toBob);
      expect(bob.decrypt(Brc43Protocol.messageBox, '1', sealed, counterparty: toAlice), body);
      expect(() => bob.decrypt(Brc43Protocol.messageBox, '2', sealed, counterparty: toAlice), throwsArgumentError);
    });

    test('what one signs for the other, the other verifies (BRC-103)', () {
      final data = utf8.encode('nonces');
      final signature = alice.createSignature(Brc43Protocol.authMessageSignature, 'a b', data, counterparty: toBob);
      expect(bob.verifySignature(Brc43Protocol.authMessageSignature, 'a b', data, signature, counterparty: toAlice),
          isTrue);
      expect(bob.verifySignature(Brc43Protocol.authMessageSignature, 'a c', data, signature, counterparty: toAlice),
          isFalse);
    });

    test('the BRC-29 key a payer derives is the one the payee spends with', () {
      final payTo = alice.derivePublicKey(Brc43Protocol.brc29, 'p s', toBob);
      expect(bob.derivePrivateKey(Brc43Protocol.brc29, 'p s', toAlice).publicKey.toHex(), payTo.toHex());
    });
  });

  test('protocol names are normalised as BRC-43 has them', () {
    expect(Brc43Protocol(2, '  Auth Message Signature ').invoiceNumber('x y'), '2-auth message signature-x y');
    expect(() => Brc43Protocol(3, 'wallet'), throwsArgumentError);
    expect(() => Brc43Protocol(0, 'my protocol'), throwsArgumentError);
    expect(() => Brc43Protocol(0, 'two  spaces'), throwsArgumentError);
    expect(() => Brc43Protocol.brc29.invoiceNumber(''), throwsArgumentError);
  });
}
