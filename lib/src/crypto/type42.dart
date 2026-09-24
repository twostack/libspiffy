import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as cr;
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:pointycastle/ecc/api.dart';
import 'package:pointycastle/ecc/curves/secp256k1.dart';

/// BRC-42 (BSV "type-42") key derivation.
///
/// Pure crypto — no isolate, no UI, no key storage. This is the shared primitive
/// behind NodeCast's broker-as-verifier pay-per-view gate (see
/// overnode_v2's `docs/nodecast/ARCHITECTURE.md` §6): the payer derives a per-invoice payment
/// destination `C` from the creator's public key without the creator's private
/// key, and the creator later recomputes the matching spend key.
///
/// Construction — **must** match `bitcoin-sv`/`bsv-blockchain/go-sdk` and the
/// Tier-0 harness (overnode_v2's `docs/nodecast/tier0`) byte-for-byte:
///
/// ```
/// sharedSecret = (priv · pub) point, serialized COMPRESSED (33 bytes)
/// t            = HMAC-SHA256(key = sharedSecretCompressed, msg = utf8(invoiceNumber))
/// childPub  C  = recipientPub + t·G
/// childPriv c  = (recipientPriv + t) mod N
/// ```
///
/// Verified against the official BRC-42 test vectors — see
/// `test/crypto/type42_test.dart`. This is net-new crypto we own and it sits on
/// the money path (R6): keep it test-vector-pinned.
///
/// All elliptic-curve math is routed through dartsv's own secp256k1 instance
/// (`t·G` is computed via a private key, never a foreign generator) to avoid
/// silent cross-instance curve mismatches.
class Type42 {
  Type42._();

  static final ECDomainParameters _dp = ECCurve_secp256k1();
  static final BigInt _n = _dp.n;

  /// ECDH shared secret between [priv] and [pub], serialized as a COMPRESSED
  /// secp256k1 point (33 bytes).
  ///
  /// Symmetric by construction: `sharedSecret(a, B) == sharedSecret(b, A)` when
  /// `A = a·G` and `B = b·G`.
  static Uint8List sharedSecret(dartsv.SVPrivateKey priv, dartsv.SVPublicKey pub) {
    final s = pub.point * priv.privateKey;
    if (s == null || s.isInfinity) {
      throw ArgumentError('Invalid ECDH shared secret (point at infinity)');
    }
    return Uint8List.fromList(s.getEncoded(true));
  }

  /// Per-invoice tweak scalar
  /// `t = HMAC-SHA256(key = sharedSecretCompressed, msg = utf8(invoiceNumber))`,
  /// interpreted as a big-endian integer.
  ///
  /// Not reduced mod N here — reduction happens where the scalar is applied,
  /// matching the reference construction. `t` is the value the payer discloses to
  /// the broker (it exposes exactly one destination; the shared secret is never
  /// disclosed).
  static BigInt tweak(List<int> sharedSecretCompressed, String invoiceNumber) {
    final mac = cr.Hmac(cr.sha256, sharedSecretCompressed);
    final digest = mac.convert(utf8.encode(invoiceNumber)).bytes;
    return _beToBigInt(digest);
  }

  /// Child public key `C = recipientPub + t·G`.
  ///
  /// The tweak `t` is derived from the ECDH secret of ([senderPriv],
  /// [recipientPub]) and [invoiceNumber], so the sender (payer) computes the
  /// destination for the recipient (creator) without the recipient's private key.
  static dartsv.SVPublicKey deriveChildPublic(
    dartsv.SVPublicKey recipientPub,
    dartsv.SVPrivateKey senderPriv,
    String invoiceNumber,
  ) {
    final t = _nonZero(tweak(sharedSecret(senderPriv, recipientPub), invoiceNumber));
    final c = recipientPub.point + _scalarBaseMult(t);
    if (c == null || c.isInfinity) {
      throw StateError('Derived child public key is the point at infinity');
    }
    // Round-trip through dartsv's own curve to avoid cross-instance mismatches.
    return dartsv.SVPublicKey.fromHex(_hex(c.getEncoded(true)));
  }

  /// Child private key `c = (recipientPriv + t) mod N` — the spend key matching
  /// [deriveChildPublic].
  ///
  /// The tweak `t` is derived from the ECDH secret of ([recipientPriv],
  /// [senderPub]) and [invoiceNumber]. Only the recipient (creator) can compute
  /// this, and `c·G` equals the `C` the payer paid.
  static dartsv.SVPrivateKey deriveChildPrivate(
    dartsv.SVPrivateKey recipientPriv,
    dartsv.SVPublicKey senderPub,
    String invoiceNumber,
  ) {
    final t = _nonZero(tweak(sharedSecret(recipientPriv, senderPub), invoiceNumber));
    final c = (recipientPriv.privateKey + t) % _n;
    return dartsv.SVPrivateKey.fromBigInt(c);
  }

  // A tweak of 0 mod N would make the child the anchor key itself
  // (PAYMENT_SCHEME.md §11): refused, although HMAC output hits it with
  // probability 2^-256.
  static BigInt _nonZero(BigInt t) {
    if (t % _n == BigInt.zero) {
      throw StateError('The type-42 tweak is 0 mod N: the child key would be the anchor key');
    }
    return t;
  }

  // t·G, computed as the public key of the scalar t — keeps all point math on
  // dartsv's single secp256k1 instance.
  static ECPoint _scalarBaseMult(BigInt k) =>
      dartsv.SVPublicKey.fromPrivateKey(dartsv.SVPrivateKey.fromBigInt(k % _n))
          .point;

  static BigInt _beToBigInt(List<int> b) {
    var r = BigInt.zero;
    for (final x in b) {
      r = (r << 8) + BigInt.from(x);
    }
    return r;
  }

  static String _hex(List<int> b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
}
