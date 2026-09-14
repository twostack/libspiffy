/// A minimal, deliberately independent BIP32 reference implementation for
/// tests (libspiffy-hvp).
///
/// It shares no code with dartsv's HD key classes or with
/// lib/src/utils/bip32.dart: HMAC-SHA512 comes from package:crypto, curve
/// arithmetic from pointycastle's secp256k1 domain, and every integer is
/// serialized through a zero-padded hex string. It implements the spec
/// literally (https://github.com/bitcoin/bips/blob/master/bip-0032.mediawiki)
/// and is only fast enough for tests.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:pointycastle/ecc/api.dart';

final ECDomainParameters _secp256k1 = ECDomainParameters('secp256k1');

/// A BIP32 private node: key k and chain code c.
class RefNode {
  final BigInt key;
  final List<int> chainCode;
  const RefNode(this.key, this.chainCode);

  /// ser256(k) as 64 lowercase hex characters.
  String get keyHex => key.toRadixString(16).padLeft(64, '0');

  /// serP(point(k)): the compressed public key as 66 hex characters.
  String get publicKeyHex => refSerP(key);
}

List<int> _hexToBytes(String hex) => <int>[
      for (var i = 0; i < hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16),
    ];

String _bytesToHex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

BigInt _parse256(List<int> bytes) =>
    BigInt.parse(_bytesToHex(bytes), radix: 16);

List<int> _ser256(BigInt v) => _hexToBytes(v.toRadixString(16).padLeft(64, '0'));

List<int> _ser32(int i) => _hexToBytes(i.toRadixString(16).padLeft(8, '0'));

/// serP(point(k)) in hex, built from the affine coordinates.
String refSerP(BigInt k) {
  final p = (_secp256k1.G * k)!;
  final x = p.x!.toBigInteger()!;
  final y = p.y!.toBigInteger()!;
  final prefix = y.isEven ? '02' : '03';
  return prefix + x.toRadixString(16).padLeft(64, '0');
}

List<int> _hmacSha512(List<int> key, List<int> data) =>
    crypto.Hmac(crypto.sha512, key).convert(data).bytes;

/// Master node from a hex seed.
RefNode refMaster(String seedHex) {
  final i = _hmacSha512(utf8.encode('Bitcoin seed'), _hexToBytes(seedHex));
  return RefNode(_parse256(i.sublist(0, 32)), i.sublist(32));
}

/// CKDpriv((k, c), i).
RefNode refChild(RefNode parent, int index) {
  final data = index >= 0x80000000
      ? <int>[0, ..._ser256(parent.key), ..._ser32(index)]
      : <int>[..._hexToBytes(parent.publicKeyHex), ..._ser32(index)];
  final i = _hmacSha512(parent.chainCode, data);
  final il = _parse256(i.sublist(0, 32));
  if (il >= _secp256k1.n) throw StateError('I_L >= n');
  final k = (il + parent.key) % _secp256k1.n;
  if (k == BigInt.zero) throw StateError('zero key');
  return RefNode(k, i.sublist(32));
}

/// Derives [path] ("m/0/5", "m/0'/1") from [root].
RefNode refDerive(RefNode root, String path) {
  var node = root;
  for (final part in path.split('/').skip(1)) {
    final hardened = part.endsWith("'") || part.endsWith('H');
    final n = int.parse(hardened ? part.substring(0, part.length - 1) : part);
    node = refChild(node, hardened ? n + 0x80000000 : n);
  }
  return node;
}

/// The chain code as hex.
String refChainHex(RefNode node) => _bytesToHex(node.chainCode);
