import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as cr;
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:pointycastle/export.dart' as pc;

import '../models/brc100_key_request.dart';
import 'type42.dart';

/// A BRC-43 protocol ID: a security level (0, 1 or 2) and a protocol name,
/// held as the reference SDK normalises it (lowercased and trimmed).
///
/// The level is part of the invoice number and nothing else here: who may
/// use a protocol is the host's business, as it is the BRC-100 wallet's.
class Brc43Protocol {
  final int securityLevel;
  final String name;

  /// Throws [ArgumentError] when [securityLevel] is not 0, 1 or 2, or the
  /// normalised [name] breaks BRC-43: 5 to 400 characters of `[a-z0-9 ]`,
  /// no double space, not ending in ` protocol`. The 430-character
  /// allowance the reference makes for `specific linkage revelation`
  /// names is not taken: no linkage is revealed here.
  factory Brc43Protocol(int securityLevel, String name) {
    if (securityLevel < 0 || securityLevel > 2) {
      throw ArgumentError.value(securityLevel, 'securityLevel', 'must be 0, 1 or 2');
    }
    final normalised = name.toLowerCase().trim();
    String? problem;
    if (normalised.length > 400) {
      problem = 'must be 400 characters or less';
    } else if (normalised.length < 5) {
      problem = 'must be 5 characters or more';
    } else if (normalised.contains('  ')) {
      problem = 'cannot contain two consecutive spaces';
    } else if (!RegExp(r'^[a-z0-9 ]+$').hasMatch(normalised)) {
      problem = 'can only contain letters, numbers and spaces';
    } else if (normalised.endsWith(' protocol')) {
      problem = 'must not end in " protocol"';
    }
    if (problem != null) throw ArgumentError.value(name, 'name', problem);
    return Brc43Protocol._(securityLevel, normalised);
  }

  const Brc43Protocol._(this.securityLevel, this.name);

  /// BRC-29 payments, `[2, '3241645161d8']`.
  static const Brc43Protocol brc29 = Brc43Protocol._(2, '3241645161d8');

  /// BRC-103 mutual authentication, `[2, 'auth message signature']`.
  static const Brc43Protocol authMessageSignature = Brc43Protocol._(2, 'auth message signature');

  /// BRC-33 message box bodies, `[1, 'messagebox']`.
  static const Brc43Protocol messageBox = Brc43Protocol._(1, 'messagebox');

  /// The BRC-43 invoice number for [keyID] under this protocol:
  /// `<securityLevel>-<name>-<keyID>`. Throws [ArgumentError] unless
  /// [keyID] is 1 to 800 characters.
  String invoiceNumber(String keyID) {
    if (keyID.isEmpty || keyID.length > 800) {
      throw ArgumentError.value(keyID, 'keyID', 'must be 1 to 800 characters');
    }
    return '$securityLevel-$name-$keyID';
  }

  @override
  bool operator ==(Object other) =>
      other is Brc43Protocol && other.securityLevel == securityLevel && other.name == name;

  @override
  int get hashCode => Object.hash(securityLevel, name);

  @override
  String toString() => '[$securityLevel, $name]';
}

/// The other party of a BRC-42 derivation: the root key's own public key
/// ([self]), the public key of private key 1 ([anyone]), or a [key].
sealed class Brc100Counterparty {
  const Brc100Counterparty();

  static const Brc100Counterparty self = _Self();
  static const Brc100Counterparty anyone = _Anyone();

  /// [publicKeyHex], a compressed public key, as a counterparty.
  static Brc100Counterparty key(String publicKeyHex) => _Key(dartsv.SVPublicKey.fromHex(publicKeyHex));

  /// `self`, `anyone`, or a public key in hex, as BRC-100 spells them.
  static Brc100Counterparty parse(String value) => switch (value) {
        'self' => self,
        'anyone' => anyone,
        _ => key(value),
      };
}

final class _Self extends Brc100Counterparty {
  const _Self();
  @override
  String toString() => 'self';
}

final class _Anyone extends Brc100Counterparty {
  const _Anyone();
  @override
  String toString() => 'anyone';
}

final class _Key extends Brc100Counterparty {
  final dartsv.SVPublicKey publicKey;
  const _Key(this.publicKey);
  @override
  String toString() => publicKey.toHex();
}

/// BRC-100's key operations over one root private key: BRC-42 child keys
/// named by BRC-43 invoice numbers, BRC-3 signatures, BRC-2 encryption and
/// HMACs. The equivalent of the reference SDK's `KeyDeriver` and
/// `ProtoWallet`, byte for byte (pinned to the published conformance
/// vectors in `test/crypto/brc100_keys_test.dart`).
///
/// Pure: no isolate, no storage. The wallet aggregate builds one around an
/// anchor key for the call and drops it.
class Brc100Keys {
  final dartsv.SVPrivateKey rootKey;

  Brc100Keys(this.rootKey);

  static final BigInt _one = BigInt.one;

  /// The root's public key, compressed, lower-case hex: the BRC-100
  /// identity key when the root is the identity.
  String get identityKey => rootKey.publicKey.toHex().toLowerCase();

  dartsv.SVPublicKey _counterpartyKey(Brc100Counterparty counterparty) => switch (counterparty) {
        _Self() => rootKey.publicKey,
        _Anyone() => dartsv.SVPrivateKey.fromBigInt(_one).publicKey,
        _Key(:final publicKey) => publicKey,
      };

  /// The private child key for [keyID] under [protocol] with [counterparty]:
  /// `(root + HMAC(ECDH(root, counterparty), invoice)) mod n`.
  dartsv.SVPrivateKey derivePrivateKey(Brc43Protocol protocol, String keyID, Brc100Counterparty counterparty) =>
      Type42.deriveChildPrivate(rootKey, _counterpartyKey(counterparty), protocol.invoiceNumber(keyID));

  /// The public child key for [keyID] under [protocol] with [counterparty]:
  /// the key the counterparty owns, or with [forSelf] the root's own (the
  /// public key of [derivePrivateKey]).
  dartsv.SVPublicKey derivePublicKey(Brc43Protocol protocol, String keyID, Brc100Counterparty counterparty,
      {bool forSelf = false}) {
    final invoice = protocol.invoiceNumber(keyID);
    final other = _counterpartyKey(counterparty);
    return forSelf
        ? Type42.deriveChildPrivate(rootKey, other, invoice).publicKey
        : Type42.deriveChildPublic(other, rootKey, invoice);
  }

  /// The X coordinate of `ourChild · theirChild`, big-endian with leading
  /// zero bytes stripped (the reference's `SymmetricKey` value).
  Uint8List _sharedX(Brc43Protocol protocol, String keyID, Brc100Counterparty counterparty) {
    final theirs = derivePublicKey(protocol, keyID, counterparty);
    final ours = derivePrivateKey(protocol, keyID, counterparty);
    final point = theirs.point * ours.privateKey;
    if (point == null || point.isInfinity) {
      throw StateError('BRC-2 shared point is the point at infinity');
    }
    return _bigIntToBytes(point.x!.toBigInteger()!);
  }

  /// The BRC-2 AES-256 key for [keyID] under [protocol] with
  /// [counterparty]: the shared X coordinate, left-padded to 32 bytes.
  Uint8List deriveSymmetricKey(Brc43Protocol protocol, String keyID, Brc100Counterparty counterparty) =>
      _leftPad(_sharedX(protocol, keyID, counterparty), 32);

  /// BRC-3: an ECDSA signature over `SHA-256(data)` with the private child
  /// key, low-S, DER encoded. [counterparty] defaults to `anyone`, as in
  /// BRC-100's `createSignature`.
  Uint8List createSignature(Brc43Protocol protocol, String keyID, List<int> data,
      {Brc100Counterparty counterparty = Brc100Counterparty.anyone}) {
    final key = derivePrivateKey(protocol, keyID, counterparty);
    final signature = dartsv.SVSignature.fromPrivateKey(key);
    signature.sign(_hex(cr.sha256.convert(data).bytes));
    return Uint8List.fromList(signature.toDER());
  }

  /// Whether [signatureDer] is a BRC-3 signature over `SHA-256(data)` by the
  /// child key [counterparty] owns for [keyID] under [protocol] (with
  /// [forSelf], the root's own child). [counterparty] defaults to `self`, as
  /// in BRC-100's `verifySignature`. False for a malformed signature.
  bool verifySignature(Brc43Protocol protocol, String keyID, List<int> data, List<int> signatureDer,
      {Brc100Counterparty counterparty = Brc100Counterparty.self, bool forSelf = false}) {
    final key = derivePublicKey(protocol, keyID, counterparty, forSelf: forSelf);
    final dartsv.SVSignature signature;
    try {
      signature = dartsv.SVSignature.fromDER(_hex(signatureDer));
    } catch (_) {
      return false;
    }
    final verifier = pc.ECDSASigner()
      ..init(false, pc.PublicKeyParameter(pc.ECPublicKey(key.point, pc.ECCurve_secp256k1())));
    return verifier.verifySignature(
        Uint8List.fromList(cr.sha256.convert(data).bytes), pc.ECSignature(signature.r, signature.s));
  }

  static final Random _random = Random.secure();

  /// BRC-2: AES-256-GCM with the symmetric key, a random 32-byte IV and no
  /// associated data, as `IV ‖ ciphertext ‖ tag`. [counterparty] defaults to
  /// `self`, as in BRC-100's `encrypt`. [iv] is for tests only.
  Uint8List encrypt(Brc43Protocol protocol, String keyID, List<int> plaintext,
      {Brc100Counterparty counterparty = Brc100Counterparty.self, List<int>? iv}) {
    final nonce = Uint8List.fromList(iv ?? [for (var i = 0; i < 32; i++) _random.nextInt(256)]);
    final gcm = pc.GCMBlockCipher(pc.AESEngine())
      ..init(true, pc.AEADParameters(pc.KeyParameter(deriveSymmetricKey(protocol, keyID, counterparty)), 128, nonce,
          Uint8List(0)));
    return Uint8List.fromList([...nonce, ...gcm.process(Uint8List.fromList(plaintext))]);
  }

  /// The plaintext of [ciphertext] ([encrypt]'s output). Throws
  /// [ArgumentError] when it is too short or does not authenticate.
  Uint8List decrypt(Brc43Protocol protocol, String keyID, List<int> ciphertext,
      {Brc100Counterparty counterparty = Brc100Counterparty.self}) {
    if (ciphertext.length < 32 + 16) {
      throw ArgumentError.value(ciphertext.length, 'ciphertext', 'is shorter than an IV and a tag');
    }
    final bytes = Uint8List.fromList(ciphertext);
    final gcm = pc.GCMBlockCipher(pc.AESEngine())
      ..init(false, pc.AEADParameters(pc.KeyParameter(deriveSymmetricKey(protocol, keyID, counterparty)), 128,
          bytes.sublist(0, 32), Uint8List(0)));
    try {
      return gcm.process(bytes.sublist(32));
    } on pc.InvalidCipherTextException {
      throw ArgumentError('The ciphertext does not decrypt under this key');
    }
  }

  /// HMAC-SHA256 of [data] keyed with the shared X coordinate, leading zero
  /// bytes stripped as the reference does. [counterparty] defaults to
  /// `self`, as in BRC-100's `createHmac`.
  Uint8List createHmac(Brc43Protocol protocol, String keyID, List<int> data,
      {Brc100Counterparty counterparty = Brc100Counterparty.self}) =>
      Uint8List.fromList(cr.Hmac(cr.sha256, _sharedX(protocol, keyID, counterparty)).convert(data).bytes);

  /// Whether [hmac] is [createHmac]'s output for [data], in constant time.
  bool verifyHmac(Brc43Protocol protocol, String keyID, List<int> data, List<int> hmac,
      {Brc100Counterparty counterparty = Brc100Counterparty.self}) {
    final expected = createHmac(protocol, keyID, data, counterparty: counterparty);
    if (hmac.length != expected.length) return false;
    var diff = 0;
    for (var i = 0; i < expected.length; i++) {
      diff |= expected[i] ^ hmac[i];
    }
    return diff == 0;
  }

  /// Runs [request] with this root key. Throws [ArgumentError] for a
  /// malformed request (a protocol, key ID or counterparty BRC-43 does not
  /// take). Applies no policy: the wallet decides what it runs
  /// (`WalletKeys.brc100KeyOperation`).
  Brc100KeyResult run(Brc100KeyRequest request) {
    final protocol = Brc43Protocol(request.securityLevel, request.protocolName);
    final keyID = request.keyID;
    final counterparty = requestCounterparty(request);
    final data = request.data;
    final proof = request.proof ?? const <int>[];
    return switch (request.operation) {
      Brc100KeyOperation.getPublicKey => Brc100KeyResult(
          identityKey: identityKey,
          publicKey: derivePublicKey(protocol, keyID, counterparty, forSelf: request.forSelf).toHex().toLowerCase()),
      Brc100KeyOperation.createSignature => Brc100KeyResult(
          identityKey: identityKey, bytes: createSignature(protocol, keyID, data, counterparty: counterparty)),
      Brc100KeyOperation.verifySignature => Brc100KeyResult(
          identityKey: identityKey,
          valid: verifySignature(protocol, keyID, data, proof, counterparty: counterparty, forSelf: request.forSelf)),
      Brc100KeyOperation.encrypt =>
        Brc100KeyResult(identityKey: identityKey, bytes: encrypt(protocol, keyID, data, counterparty: counterparty)),
      Brc100KeyOperation.decrypt =>
        Brc100KeyResult(identityKey: identityKey, bytes: decrypt(protocol, keyID, data, counterparty: counterparty)),
      Brc100KeyOperation.createHmac =>
        Brc100KeyResult(identityKey: identityKey, bytes: createHmac(protocol, keyID, data, counterparty: counterparty)),
      Brc100KeyOperation.verifyHmac => Brc100KeyResult(
          identityKey: identityKey, valid: verifyHmac(protocol, keyID, data, proof, counterparty: counterparty)),
    };
  }

  /// [request]'s counterparty, or BRC-100's default for its operation
  /// (`anyone` for a signature, `self` otherwise). Throws [ArgumentError]
  /// when it is not `self`, `anyone` or a public key.
  static Brc100Counterparty requestCounterparty(Brc100KeyRequest request) {
    final value =
        request.counterparty ?? (request.operation == Brc100KeyOperation.createSignature ? 'anyone' : 'self');
    try {
      return Brc100Counterparty.parse(value);
    } catch (_) {
      throw ArgumentError.value(request.counterparty, 'counterparty', 'is not self, anyone or a public key');
    }
  }

  /// [text] as UTF-8, for callers holding strings.
  static Uint8List utf8Bytes(String text) => Uint8List.fromList(utf8.encode(text));

  static Uint8List _bigIntToBytes(BigInt value) {
    var hexString = value.toRadixString(16);
    if (hexString.length.isOdd) hexString = '0$hexString';
    return Uint8List.fromList([
      for (var i = 0; i < hexString.length; i += 2) int.parse(hexString.substring(i, i + 2), radix: 16)
    ]);
  }

  static Uint8List _leftPad(Uint8List bytes, int length) =>
      bytes.length >= length ? bytes : Uint8List.fromList([...List.filled(length - bytes.length, 0), ...bytes]);

  static String _hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
}
