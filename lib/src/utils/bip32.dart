import 'dart:convert';
import 'dart:typed_data';

import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:meta/meta.dart';
import 'package:pointycastle/digests/sha512.dart';
import 'package:pointycastle/ecc/api.dart';
import 'package:pointycastle/macs/hmac.dart';
import 'package:pointycastle/pointycastle.dart' show KeyParameter;

/// BIP32 child key derivation for libspiffy (libspiffy-hvp).
///
/// dartsv 3.0.0 serializes a derived child private key with
/// `encodeBigIntSV`, which drops leading zero bytes, and then copies it into a
/// fixed 33-byte buffer: `paddedKey.setRange(1, 33, encodeBigIntSV(childKey))`.
/// Whenever the child key is below 2^248 (probability 1/256 per derived key)
/// that throws `Bad state: Too few elements`, so roughly one address in 256 of
/// every wallet could not be signed for, and random keys failed at random.
///
/// Every libspiffy derivation goes through this class instead of
/// `HDPrivateKey.deriveChildKey` / `deriveChildNumber` and
/// `HDPublicKey.deriveChildKey` / `deriveChildNumber`. It implements BIP32
/// CKDpriv / CKDpub directly (HMAC-SHA512 and secp256k1 arithmetic) with
/// fixed-width `ser256` / `serP` encodings, and returns ordinary dartsv
/// [dartsv.HDPrivateKey] / [dartsv.HDPublicKey] objects so the rest of the
/// wallet keeps working with dartsv types.
///
/// For every key dartsv could derive, the resulting private key, public key
/// and chain code are bit-identical to dartsv's, so existing wallets keep
/// their addresses. Differences from dartsv, all BIP32-mandated:
///
/// * a child whose key has leading zero bytes is derived instead of throwing;
/// * the derived node's depth is parent depth + 1 (dartsv's `deriveChildKey`
///   on a private key restarts at depth 1 for any parent, which only affected
///   the serialized xpriv/xpub of a derived node, never a key);
/// * the invalid-child cases (I_L >= n, a zero private key, the point at
///   infinity) throw [dartsv.DerivationException] instead of producing an
///   invalid key. They occur with probability below 2^-127.
class Bip32 {
  Bip32._();

  static final ECDomainParameters _curve = ECDomainParameters('secp256k1');

  /// The bit that marks a hardened child index.
  static const int hardenedBit = 0x80000000;

  /// BIP32 master key generation from a hex-encoded [seedHex].
  static dartsv.HDPrivateKey masterFromSeed(
      String seedHex, dartsv.NetworkType network) {
    final i = hmacSha512(utf8.encode('Bitcoin seed'), _hexDecode(seedHex));
    final il = _toBigInt(i.sublist(0, 32));
    if (il == BigInt.zero || il >= _curve.n) {
      throw dartsv.DerivationException('Invalid master key was generated.');
    }
    // dartsv's master key generation is correct apart from accepting
    // I_L == n, which is rejected above.
    return dartsv.HDPrivateKey.fromSeed(seedHex, network);
  }

  /// Derives the private node at [path] (for example `m/0/5` or `m/44'/0'`)
  /// below [parent]. The path is relative to [parent].
  static dartsv.HDPrivateKey derivePrivatePath(
      dartsv.HDPrivateKey parent, String path) {
    var node = parent;
    for (final child in dartsv.HDUtils.parsePath(path)) {
      node = derivePrivateChild(node, child.i);
    }
    return node;
  }

  /// CKDpriv: the child of [parent] at [index]. Indexes at or above
  /// [hardenedBit] are hardened.
  static dartsv.HDPrivateKey derivePrivateChild(
      dartsv.HDPrivateKey parent, int index) {
    _checkIndex(index);
    final kpar = _toBigInt(parent.keyBuffer);
    final parentPub = _serP(_curve.G * kpar);
    final data = index >= hardenedBit
        ? <int>[0, ...ser256(kpar), ...ser32(index)]
        : <int>[...parentPub, ...ser32(index)];
    final i = hmacSha512(parent.chainCode, data);
    final ki = addPrivateTweak(_toBigInt(i.sublist(0, 32)), kpar);

    final child = dartsv.HDPrivateKey.fromXpriv(parent.xprivkey);
    child.networkType = parent.networkType;
    child.nodeDepth = _childDepth(parent.nodeDepth);
    child.parentFingerprint = dartsv.hash160(parentPub).sublist(0, 4);
    child.childNumber = ser32(index);
    child.chainCode = i.sublist(32, 64);
    child.keyBuffer = <int>[0, ...ser256(ki)];
    return child;
  }

  /// Derives the public node at [path] (for example `m/1/7`) below [parent].
  /// Hardened steps are rejected: they need the private key.
  static dartsv.HDPublicKey derivePublicPath(
      dartsv.HDPublicKey parent, String path) {
    var node = parent;
    for (final child in dartsv.HDUtils.parsePath(path)) {
      node = derivePublicChild(node, child.i);
    }
    return node;
  }

  /// CKDpub: the non-hardened child of [parent] at [index].
  static dartsv.HDPublicKey derivePublicChild(
      dartsv.HDPublicKey parent, int index) {
    _checkIndex(index);
    if (index >= hardenedBit) {
      throw dartsv.DerivationException(
          "Can't derive hardened public keys without private keys");
    }
    final parentPub = parent.keyBuffer;
    final parentPoint = _curve.curve.decodePoint(Uint8List.fromList(parentPub));
    if (parentPoint == null || parentPoint.isInfinity) {
      throw dartsv.DerivationException('Invalid parent public key');
    }
    final i = hmacSha512(parent.chainCode, <int>[...parentPub, ...ser32(index)]);
    final point = addPublicTweak(_toBigInt(i.sublist(0, 32)), parentPoint);
    return dartsv.HDPublicKey(
      dartsv.SVPublicKey.fromHex(_hex(_serP(point))),
      parent.networkType!,
      _childDepth(parent.nodeDepth),
      dartsv.hash160(parentPub).sublist(0, 4),
      ser32(index),
      i.sublist(32, 64),
      parent.versionBytes,
    );
  }

  /// `parse256(I_L) + k_par (mod n)`, rejecting the invalid cases of BIP32.
  @visibleForTesting
  static BigInt addPrivateTweak(BigInt il, BigInt kpar) {
    if (il >= _curve.n) {
      throw dartsv.DerivationException(
          'Invalid child key: I_L >= n; use the next index');
    }
    final ki = (il + kpar) % _curve.n;
    if (ki == BigInt.zero) {
      throw dartsv.DerivationException(
          'Invalid child key: zero; use the next index');
    }
    return ki;
  }

  /// `point(parse256(I_L)) + K_par`, rejecting the invalid cases of BIP32.
  @visibleForTesting
  static ECPoint addPublicTweak(BigInt il, ECPoint parentPoint) {
    if (il >= _curve.n) {
      throw dartsv.DerivationException(
          'Invalid child key: I_L >= n; use the next index');
    }
    final point = il == BigInt.zero ? parentPoint : (_curve.G * il)! + parentPoint;
    if (point == null || point.isInfinity) {
      throw dartsv.DerivationException(
          'Invalid child key: point at infinity; use the next index');
    }
    return point;
  }

  /// `ser256(p)`: [value] as exactly 32 big-endian bytes, leading zeros kept.
  static Uint8List ser256(BigInt value) {
    if (value.isNegative || value.bitLength > 256) {
      throw ArgumentError.value(value, 'value', 'not a 256-bit unsigned integer');
    }
    final out = Uint8List(32);
    var v = value;
    for (var j = 31; j >= 0; j--) {
      out[j] = (v & _byteMask).toInt();
      v = v >> 8;
    }
    return out;
  }

  /// `ser32(i)`: [index] as 4 big-endian bytes.
  static Uint8List ser32(int index) => Uint8List.fromList(<int>[
        (index >> 24) & 0xff,
        (index >> 16) & 0xff,
        (index >> 8) & 0xff,
        index & 0xff,
      ]);

  /// HMAC-SHA512 of [data] under [key].
  static Uint8List hmacSha512(List<int> key, List<int> data) {
    final mac = HMac(SHA512Digest(), 128)
      ..init(KeyParameter(Uint8List.fromList(key)));
    return mac.process(Uint8List.fromList(data));
  }

  static final BigInt _byteMask = BigInt.from(0xff);

  static void _checkIndex(int index) {
    if (index < 0 || index > 0xffffffff) {
      throw dartsv.DerivationException('Child index out of range: $index');
    }
  }

  static int _childDepth(int? parentDepth) {
    final depth = (parentDepth ?? 0) + 1;
    if (depth > 255) {
      throw dartsv.DerivationException('BIP32 depth exceeds 255');
    }
    return depth;
  }

  /// `serP(P)`: the 33-byte compressed encoding.
  static Uint8List _serP(ECPoint? point) => point!.getEncoded(true);

  static BigInt _toBigInt(List<int> bytes) {
    var result = BigInt.zero;
    for (final b in bytes) {
      result = (result << 8) | BigInt.from(b & 0xff);
    }
    return result;
  }

  static List<int> _hexDecode(String hex) {
    if (hex.length.isOdd) {
      throw ArgumentError.value(hex, 'seedHex', 'odd-length hex string');
    }
    return <int>[
      for (var j = 0; j < hex.length; j += 2)
        int.parse(hex.substring(j, j + 2), radix: 16),
    ];
  }

  static String _hex(List<int> bytes) =>
      bytes.map((b) => (b & 0xff).toRadixString(16).padLeft(2, '0')).join();
}
