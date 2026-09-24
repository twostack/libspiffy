import 'package:test/test.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:pointycastle/ecc/curves/secp256k1.dart';

import 'package:libspiffy/src/crypto/type42.dart';

/// BRC-42 (type-42) derivation — pinned to the official test vectors and the
/// Tier-0 soundness invariants (see overnode_v2's docs/nodecast/tier0). This sits on the money
/// path (R6): a change that breaks vector parity must fail this test.
void main() {
  final n = ECCurve_secp256k1().n;

  String big32(BigInt v) => v.toRadixString(16).padLeft(64, '0');

  dartsv.SVPrivateKey privFromHex(String h) =>
      dartsv.SVPrivateKey.fromBigInt(BigInt.parse(h, radix: 16));

  // Official BRC-42 vectors: [senderPubHex, recipientPrivHex, invoiceNumber, expectedChildPrivHex]
  const privVectors = [
    [
      '033f9160df035156f1c48e75eae99914fa1a1546bec19781e8eddb900200bff9d1',
      '6a1751169c111b4667a6539ee1be6b7cd9f6e9c8fe011a5f2fe31e03a15e0ede',
      'f3WCaUmnN9U=',
      '761656715bbfa172f8f9f58f5af95d9d0dfd69014cfdcacc9a245a10ff8893ef'
    ],
    [
      '027775fa43959548497eb510541ac34b01d5ee9ea768de74244a4a25f7b60fae8d',
      'cab2500e206f31bc18a8af9d6f44f0b9a208c32d5cca2b22acfe9d1a213b2f36',
      '2Ska++APzEc=',
      '09f2b48bd75f4da6429ac70b5dce863d5ed2b350b6f2119af5626914bdb7c276'
    ],
    [
      '0338d2e0d12ba645578b0955026ee7554889ae4c530bd7a3b6f688233d763e169f',
      '7a66d0896f2c4c2c9ac55670c71a9bc1bdbdfb4e8786ee5137cea1d0a05b6f20',
      'cN/yQ7+k7pg=',
      '7114cd9afd1eade02f76703cc976c241246a2f26f5c4b7a3a0150ecc745da9f0'
    ],
    [
      '02830212a32a47e68b98d477000bde08cb916f4d44ef49d47ccd4918d9aaabe9c8',
      '6e8c3da5f2fb0306a88d6bcd427cbfba0b9c7f4c930c43122a973d620ffa3036',
      'm2/QAsmwaA4=',
      'f1d6fb05da1225feeddd1cf4100128afe09c3c1aadbffbd5c8bd10d329ef8f40'
    ],
    [
      '03f20a7e71c4b276753969e8b7e8b67e2dbafc3958d66ecba98dedc60a6615336d',
      'e9d174eff5708a0a41b32624f9b9cc97ef08f8931ed188ee58d5390cad2bf68e',
      'jgpUIjWFlVQ=',
      'c5677c533f17c30f79a40744b18085632b262c0c13d87f3848c385f1389f79a6'
    ],
  ];

  // Official BRC-42 vectors: [senderPrivHex, recipientPubHex, invoiceNumber, expectedChildPubHex]
  const pubVectors = [
    [
      '583755110a8c059de5cd81b8a04e1be884c46083ade3f779c1e022f6f89da94c',
      '02c0c1e1a1f7d247827d1bcf399f0ef2deef7695c322fd91a01a91378f101b6ffc',
      'IBioA4D/OaE=',
      '03c1bf5baadee39721ae8c9882b3cf324f0bf3b9eb3fc1b8af8089ca7a7c2e669f'
    ],
    [
      '2c378b43d887d72200639890c11d79e8f22728d032a5733ba3d7be623d1bb118',
      '039a9da906ecb8ced5c87971e9c2e7c921e66ad450fd4fc0a7d569fdb5bede8e0f',
      'PWYuo9PDKvI=',
      '0398cdf4b56a3b2e106224ff3be5253afd5b72de735d647831be51c713c9077848'
    ],
    [
      'd5a5f70b373ce164998dff7ecd93260d7e80356d3d10abf928fb267f0a6c7be6',
      '02745623f4e5de046b6ab59ce837efa1a959a8f28286ce9154a4781ec033b85029',
      'X9pnS+bByrM=',
      '0273eec9380c1a11c5a905e86c2d036e70cbefd8991d9a0cfca671f5e0bbea4a3c'
    ],
    [
      '46cd68165fd5d12d2d6519b02feb3f4d9c083109de1bfaa2b5c4836ba717523c',
      '031e18bb0bbd3162b886007c55214c3c952bb2ae6c33dd06f57d891a60976003b1',
      '+ktmYRHv3uQ=',
      '034c5c6bf2e52e8de8b2eb75883090ed7d1db234270907f1b0d1c2de1ddee5005d'
    ],
    [
      '7c98b8abd7967485cfb7437f9c56dd1e48ceb21a4085b8cdeb2a647f62012db4',
      '03c8885f1e1ab4facd0f3272bb7a48b003d2e608e1619fb38b8be69336ab828f37',
      'PPfDTTcl1ao=',
      '03304b41cfa726096ffd9d8907fe0835f888869eda9653bca34eb7bcab870d3779'
    ],
  ];

  group('BRC-42 official test vectors', () {
    test('private-key derivation (5 vectors)', () {
      for (var i = 0; i < privVectors.length; i++) {
        final v = privVectors[i];
        final child = Type42.deriveChildPrivate(
          privFromHex(v[1]),
          dartsv.SVPublicKey.fromHex(v[0]),
          v[2],
        );
        expect(big32(child.privateKey), equals(v[3]),
            reason: 'priv vector ${i + 1}');
      }
    });

    test('public-key derivation (5 vectors)', () {
      for (var i = 0; i < pubVectors.length; i++) {
        final v = pubVectors[i];
        final child = Type42.deriveChildPublic(
          dartsv.SVPublicKey.fromHex(v[1]),
          privFromHex(v[0]),
          v[2],
        );
        expect(child.getEncoded(true), equals(v[3]),
            reason: 'pub vector ${i + 1}');
      }
    });
  });

  group('BRC-42 soundness invariants (Option-C triangle)', () {
    // Fixed test-only keys, mirroring the Tier-0 harness.
    final creatorPriv = privFromHex(
        '6a1751169c111b4667a6539ee1be6b7cd9f6e9c8fe011a5f2fe31e03a15e0ede');
    final payerPriv = privFromHex(
        '583755110a8c059de5cd81b8a04e1be884c46083ade3f779c1e022f6f89da94c');
    final creatorPub = creatorPriv.publicKey;
    final payerPub = payerPriv.publicKey;
    const invoiceA = 'nodecast:content=abc123|purchase=1';
    const invoiceB = 'nodecast:content=abc123|purchase=2';

    test('ECDH shared secret is symmetric (payer == creator)', () {
      final ssPayer = Type42.sharedSecret(payerPriv, creatorPub);
      final ssCreator = Type42.sharedSecret(creatorPriv, payerPub);
      expect(ssPayer, equals(ssCreator));
    });

    test('childPriv·G == childPub (creator can spend what payer paid)', () {
      final childPub =
          Type42.deriveChildPublic(creatorPub, payerPriv, invoiceA);
      final childPriv =
          Type42.deriveChildPrivate(creatorPriv, payerPub, invoiceA);
      expect(childPriv.publicKey.getEncoded(true),
          equals(childPub.getEncoded(true)));
    });

    test('c - t == creatorPriv (only the creator can spend C)', () {
      final t = Type42.tweak(
          Type42.sharedSecret(payerPriv, creatorPub), invoiceA);
      final childPriv =
          Type42.deriveChildPrivate(creatorPriv, payerPub, invoiceA);
      expect((childPriv.privateKey - t) % n, equals(creatorPriv.privateKey));
    });

    test('per-invoice scoping (CA != CB, tA != tB)', () {
      final ss = Type42.sharedSecret(payerPriv, creatorPub);
      final tA = Type42.tweak(ss, invoiceA);
      final tB = Type42.tweak(ss, invoiceB);
      final cA = Type42.deriveChildPublic(creatorPub, payerPriv, invoiceA);
      final cB = Type42.deriveChildPublic(creatorPub, payerPriv, invoiceB);
      expect(tA, isNot(equals(tB)));
      expect(cA.getEncoded(true), isNot(equals(cB.getEncoded(true))));
    });

    // Byte-for-byte parity with the Go-verified Tier-0 reference
    // (overnode_v2's docs/nodecast/tier0/out/triangle.json). Those values were independently
    // recomputed by the go-overmedia broker (go-sdk) in the Tier-0 harness, so
    // matching them here pins this port to the server implementation.
    test('matches the Go-verified Tier-0 triangle values', () {
      final ss = Type42.sharedSecret(payerPriv, creatorPub);
      expect(_hex(ss),
          equals('02489444c7557100b228a24515b23901a1d66f43c9d8ccf3ba315abc36bf44cf9c'));

      expect(big32(Type42.tweak(ss, invoiceA)),
          equals('ed9f45d0101bf4d985d9876bc6c83f0675034a3c23769e091bc78cffdb456577'));
      expect(
          Type42.deriveChildPublic(creatorPub, payerPriv, invoiceA)
              .getEncoded(true),
          equals('02536066eb530d6bef04b2f369364a8e2b34da273e779297f6457688d5a5906b67'));
      expect(
          big32(Type42.deriveChildPrivate(creatorPriv, payerPub, invoiceA)
              .privateKey),
          equals('57b696e6ac2d101fed7fdb0aa886aa84944b571e722f182c8bd84c76ac6d3314'));

      expect(big32(Type42.tweak(ss, invoiceB)),
          equals('a8cadffc2f629ae17443300f4928daf9ca3909cbf908e91a9680ab2675cdb192'));
      expect(
          Type42.deriveChildPublic(creatorPub, payerPriv, invoiceB)
              .getEncoded(true),
          equals('033e4d5e61543d2fbf18c9b8a1f6e2c290ea060622b2b49d9be559400861f81e40'));
    });
  });
}

String _hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
