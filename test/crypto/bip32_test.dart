/// libspiffy-hvp: lib/src/utils/bip32.dart against the published BIP32 test
/// vectors 1-4, the independent reference in bip32_reference.dart, and
/// dartsv 3.0.0's own derivation for every key dartsv can derive (existing
/// wallets must keep their keys and addresses).
library;

import 'dart:math';

import 'package:convert/convert.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:libspiffy/src/utils/bip32.dart';
import 'package:pointycastle/ecc/api.dart';
import 'package:test/test.dart';

import 'bip32_reference.dart';
import 'hd_leading_zero_fixtures.dart';

/// A BIP32 test vector step: path from the master, xprv, xpub.
typedef _Step = (String path, String xprv, String xpub);

/// https://github.com/bitcoin/bips/blob/master/bip-0032.mediawiki#test-vectors
const _vector1Seed = '000102030405060708090a0b0c0d0e0f';
const List<_Step> _vector1 = [
  ('m', 'xprv9s21ZrQH143K3QTDL4LXw2F7HEK3wJUD2nW2nRk4stbPy6cq3jPPqjiChkVvvNKmPGJxWUtg6LnF5kejMRNNU3TGtRBeJgk33yuGBxrMPHi',
      'xpub661MyMwAqRbcFtXgS5sYJABqqG9YLmC4Q1Rdap9gSE8NqtwybGhePY2gZ29ESFjqJoCu1Rupje8YtGqsefD265TMg7usUDFdp6W1EGMcet8'),
  ("m/0'", 'xprv9uHRZZhk6KAJC1avXpDAp4MDc3sQKNxDiPvvkX8Br5ngLNv1TxvUxt4cV1rGL5hj6KCesnDYUhd7oWgT11eZG7XnxHrnYeSvkzY7d2bhkJ7',
      'xpub68Gmy5EdvgibQVfPdqkBBCHxA5htiqg55crXYuXoQRKfDBFA1WEjWgP6LHhwBZeNK1VTsfTFUHCdrfp1bgwQ9xv5ski8PX9rL2dZXvgGDnw'),
  ("m/0'/1", 'xprv9wTYmMFdV23N2TdNG573QoEsfRrWKQgWeibmLntzniatZvR9BmLnvSxqu53Kw1UmYPxLgboyZQaXwTCg8MSY3H2EU4pWcQDnRnrVA1xe8fs',
      'xpub6ASuArnXKPbfEwhqN6e3mwBcDTgzisQN1wXN9BJcM47sSikHjJf3UFHKkNAWbWMiGj7Wf5uMash7SyYq527Hqck2AxYysAA7xmALppuCkwQ'),
  ("m/0'/1/2'", 'xprv9z4pot5VBttmtdRTWfWQmoH1taj2axGVzFqSb8C9xaxKymcFzXBDptWmT7FwuEzG3ryjH4ktypQSAewRiNMjANTtpgP4mLTj34bhnZX7UiM',
      'xpub6D4BDPcP2GT577Vvch3R8wDkScZWzQzMMUm3PWbmWvVJrZwQY4VUNgqFJPMM3No2dFDFGTsxxpG5uJh7n7epu4trkrX7x7DogT5Uv6fcLW5'),
  ("m/0'/1/2'/2", 'xprvA2JDeKCSNNZky6uBCviVfJSKyQ1mDYahRjijr5idH2WwLsEd4Hsb2Tyh8RfQMuPh7f7RtyzTtdrbdqqsunu5Mm3wDvUAKRHSC34sJ7in334',
      'xpub6FHa3pjLCk84BayeJxFW2SP4XRrFd1JYnxeLeU8EqN3vDfZmbqBqaGJAyiLjTAwm6ZLRQUMv1ZACTj37sR62cfN7fe5JnJ7dh8zL4fiyLHV'),
  ("m/0'/1/2'/2/1000000000", 'xprvA41z7zogVVwxVSgdKUHDy1SKmdb533PjDz7J6N6mV6uS3ze1ai8FHa8kmHScGpWmj4WggLyQjgPie1rFSruoUihUZREPSL39UNdE3BBDu76',
      'xpub6H1LXWLaKsWFhvm6RVpEL9P4KfRZSW7abD2ttkWP3SSQvnyA8FSVqNTEcYFgJS2UaFcxupHiYkro49S8yGasTvXEYBVPamhGW6cFJodrTHy'),
];

const _vector2Seed = 'fffcf9f6f3f0edeae7e4e1dedbd8d5d2cfccc9c6c3c0bdbab7b4b1aeaba8a5a29f9c999693908d8a8784817e7b7875726f6c696663605d5a5754514e4b484542';
const List<_Step> _vector2 = [
  ('m', 'xprv9s21ZrQH143K31xYSDQpPDxsXRTUcvj2iNHm5NUtrGiGG5e2DtALGdso3pGz6ssrdK4PFmM8NSpSBHNqPqm55Qn3LqFtT2emdEXVYsCzC2U',
      'xpub661MyMwAqRbcFW31YEwpkMuc5THy2PSt5bDMsktWQcFF8syAmRUapSCGu8ED9W6oDMSgv6Zz8idoc4a6mr8BDzTJY47LJhkJ8UB7WEGuduB'),
  ('m/0', 'xprv9vHkqa6EV4sPZHYqZznhT2NPtPCjKuDKGY38FBWLvgaDx45zo9WQRUT3dKYnjwih2yJD9mkrocEZXo1ex8G81dwSM1fwqWpWkeS3v86pgKt',
      'xpub69H7F5d8KSRgmmdJg2KhpAK8SR3DjMwAdkxj3ZuxV27CprR9LgpeyGmXUbC6wb7ERfvrnKZjXoUmmDznezpbZb7ap6r1D3tgFxHmwMkQTPH'),
  ("m/0/2147483647'", 'xprv9wSp6B7kry3Vj9m1zSnLvN3xH8RdsPP1Mh7fAaR7aRLcQMKTR2vidYEeEg2mUCTAwCd6vnxVrcjfy2kRgVsFawNzmjuHc2YmYRmagcEPdU9',
      'xpub6ASAVgeehLbnwdqV6UKMHVzgqAG8Gr6riv3Fxxpj8ksbH9ebxaEyBLZ85ySDhKiLDBrQSARLq1uNRts8RuJiHjaDMBU4Zn9h8LZNnBC5y4a'),
  ("m/0/2147483647'/1", 'xprv9zFnWC6h2cLgpmSA46vutJzBcfJ8yaJGg8cX1e5StJh45BBciYTRXSd25UEPVuesF9yog62tGAQtHjXajPPdbRCHuWS6T8XA2ECKADdw4Ef',
      'xpub6DF8uhdarytz3FWdA8TvFSvvAh8dP3283MY7p2V4SeE2wyWmG5mg5EwVvmdMVCQcoNJxGoWaU9DCWh89LojfZ537wTfunKau47EL2dhHKon'),
  ("m/0/2147483647'/1/2147483646'", 'xprvA1RpRA33e1JQ7ifknakTFpgNXPmW2YvmhqLQYMmrj4xJXXWYpDPS3xz7iAxn8L39njGVyuoseXzU6rcxFLJ8HFsTjSyQbLYnMpCqE2VbFWc',
      'xpub6ERApfZwUNrhLCkDtcHTcxd75RbzS1ed54G1LkBUHQVHQKqhMkhgbmJbZRkrgZw4koxb5JaHWkY4ALHY2grBGRjaDMzQLcgJvLJuZZvRcEL'),
  ("m/0/2147483647'/1/2147483646'/2", 'xprvA2nrNbFZABcdryreWet9Ea4LvTJcGsqrMzxHx98MMrotbir7yrKCEXw7nadnHM8Dq38EGfSh6dqA9QWTyefMLEcBYJUuekgW4BYPJcr9E7j',
      'xpub6FnCn6nSzZAw5Tw7cgR9bi15UV96gLZhjDstkXXxvCLsUXBGXPdSnLFbdpq8p9HmGsApME5hQTZ3emM2rnY5agb9rXpVGyy3bdW6EEgAtqt'),
];

/// Vector 3: retention of leading zeros (bitpay/bitcore-lib#47).
const _vector3Seed = '4b381541583be4423346c643850da4b320e46a87ae3d2a4e6da11eba819cd4acba45d239319ac14f863b8d5ab5a0d0c64d2e8a1e7d1457df2e5a3c51c73235be';
const List<_Step> _vector3 = [
  ('m', 'xprv9s21ZrQH143K25QhxbucbDDuQ4naNntJRi4KUfWT7xo4EKsHt2QJDu7KXp1A3u7Bi1j8ph3EGsZ9Xvz9dGuVrtHHs7pXeTzjuxBrCmmhgC6',
      'xpub661MyMwAqRbcEZVB4dScxMAdx6d4nFc9nvyvH3v4gJL378CSRZiYmhRoP7mBy6gSPSCYk6SzXPTf3ND1cZAceL7SfJ1Z3GC8vBgp2epUt13'),
  ("m/0'", 'xprv9uPDJpEQgRQfDcW7BkF7eTya6RPxXeJCqCJGHuCJ4GiRVLzkTXBAJMu2qaMWPrS7AANYqdq6vcBcBUdJCVVFceUvJFjaPdGZ2y9WACViL4L',
      'xpub68NZiKmJWnxxS6aaHmn81bvJeTESw724CRDs6HbuccFQN9Ku14VQrADWgqbhhTHBaohPX4CjNLf9fq9MYo6oDaPPLPxSb7gwQN3ih19Zm4Y'),
];

/// Vector 4: retention of leading zeros in hardened derivation (btcsuite).
const _vector4Seed = '3ddd5602285899a946114506157c7997e5444528f3003f6134712147db19b678';
const List<_Step> _vector4 = [
  ('m', 'xprv9s21ZrQH143K48vGoLGRPxgo2JNkJ3J3fqkirQC2zVdk5Dgd5w14S7fRDyHH4dWNHUgkvsvNDCkvAwcSHNAQwhwgNMgZhLtQC63zxwhQmRv',
      'xpub661MyMwAqRbcGczjuMoRm6dXaLDEhW1u34gKenbeYqAix21mdUKJyuyu5F1rzYGVxyL6tmgBUAEPrEz92mBXjByMRiJdba9wpnN37RLLAXa'),
  ("m/0'", 'xprv9vB7xEWwNp9kh1wQRfCCQMnZUEG21LpbR9NPCNN1dwhiZkjjeGRnaALmPXCX7SgjFTiCTT6bXes17boXtjq3xLpcDjzEuGLQBM5ohqkao9G',
      'xpub69AUMk3qDBi3uW1sXgjCmVjJ2G6WQoYSnNHyzkmdCHEhSZ4tBok37xfFEqHd2AddP56Tqp4o56AePAgCjYdvpW2PU2jbUPFKsav5ut6Ch1m'),
  ("m/0'/1'", 'xprv9xJocDuwtYCMNAo3Zw76WENQeAS6WGXQ55RCy7tDJ8oALr4FWkuVoHJeHVAcAqiZLE7Je3vZJHxspZdFHfnBEjHqU5hG1Jaj32dVoS6XLT1',
      'xpub6BJA1jSqiukeaesWfxe6sNK9CCGaujFFSJLomWHprUL9DePQ4JDkM5d88n49sMGJxrhpjazuXYWdMf17C9T5XnxkopaeS7jGk1GyyVziaMt'),
];

/// Derives [step] from [master] one level at a time through Bip32 (from the
/// previous step's node, as a wallet does) and checks both serializations;
/// every non-hardened step is also derived from the parent xpub.
void _checkVector(dartsv.HDPrivateKey master, List<_Step> steps) {
  expect(master.xprivkey, steps.first.$2, reason: 'master xprv');
  expect(master.xpubkey, steps.first.$3, reason: 'master xpub');
  var parent = master;
  for (final (path, xprv, xpub) in steps.skip(1)) {
    final last = path.split('/').last;
    final child = Bip32.derivePrivatePath(parent, 'm/$last');
    expect(child.xprivkey, xprv, reason: '$path xprv');
    expect(child.xpubkey, xpub, reason: '$path xpub');
    expect(Bip32.derivePrivatePath(master, path).xprivkey, xprv,
        reason: '$path xprv derived from the master in one call');
    if (!last.endsWith("'")) {
      final pub = Bip32.derivePublicPath(dartsv.HDPublicKey.fromXpub(parent.xpubkey), 'm/$last');
      expect(pub.xpubkey, xpub, reason: '$path xpub via CKDpub');
    }
    parent = child;
  }
}

void _expectSamePublicNode(dartsv.HDPublicKey a, dartsv.HDPublicKey b, String reason) {
  expect(a.keyBuffer, b.keyBuffer, reason: '$reason: public key');
  expect(a.chainCode, b.chainCode, reason: '$reason: chain code');
  expect(a.nodeDepth, b.nodeDepth, reason: '$reason: depth');
  expect(a.parentFingerprint, b.parentFingerprint, reason: '$reason: parent fingerprint');
  expect(a.childNumber, b.childNumber, reason: '$reason: child number');
}

void main() {
  group('BIP32 test vectors', () {
    test('vector 1', () {
      _checkVector(Bip32.masterFromSeed(_vector1Seed, dartsv.NetworkType.MAIN), _vector1);
    });
    test('vector 2', () {
      _checkVector(Bip32.masterFromSeed(_vector2Seed, dartsv.NetworkType.MAIN), _vector2);
    });
    test('vector 3 (leading zeros)', () {
      _checkVector(Bip32.masterFromSeed(_vector3Seed, dartsv.NetworkType.MAIN), _vector3);
    });
    test('vector 4 (leading zeros, hardened)', () {
      _checkVector(Bip32.masterFromSeed(_vector4Seed, dartsv.NetworkType.MAIN), _vector4);
    });
  });

  group('the failing inputs of libspiffy-hvp', () {
    Future<void> check(String mnemonic, List<String> paths) async {
      final seed = dartsv.Mnemonic().toSeedHex(mnemonic, '');
      final root = Bip32.masterFromSeed(seed, dartsv.NetworkType.TEST);
      final ref = refMaster(seed);
      for (final path in paths) {
        final expected = refDerive(ref, path);
        expect(() => root.deriveChildKey(path), throwsA(isA<StateError>()),
            reason: 'fixture: dartsv 3.0.0 throws for $path');
        final node = Bip32.derivePrivatePath(root, path);
        expect(hex.encode(node.keyBuffer), '00${expected.keyHex}', reason: path);
        expect(hex.encode(node.chainCode), refChainHex(expected), reason: path);
        final pub = Bip32.derivePublicPath(root.hdPublicKey, path);
        expect(hex.encode(pub.keyBuffer), expected.publicKeyHex, reason: path);
        expect(pub.xpubkey, node.xpubkey, reason: '$path: CKDpub and CKDpriv agree');
      }
    }

    test('short m/0/0', () => check(kShortReceive00Mnemonic, ['m/0/0']));
    test('short m/0', () => check(kShortReceiveChainMnemonic, ['m/0/0', 'm/0/5']));
    test('short m/1', () => check(kShortChangeChainMnemonic, ['m/1/0', 'm/1/5']));
    test('fixed test mnemonic', () =>
        check(kAbandonMnemonic, [for (final i in kAbandonShortReceiveIndexes) 'm/0/$i']));

    test('near misses dartsv derived correctly stay identical', () {
      for (final (seed, path) in [
        (kShortChainPubXSeed, 'm/0/0'),
        (kShortMasterSeed, "m/0'"),
        (kShortMasterSeed, "m/0'/1/2'"),
      ]) {
        final root = dartsv.HDPrivateKey.fromSeed(seed, dartsv.NetworkType.TEST);
        final legacy = root.deriveChildKey(path);
        final node = Bip32.derivePrivatePath(root, path);
        final expected = refDerive(refMaster(seed), path);
        expect(hex.encode(node.keyBuffer), '00${expected.keyHex}', reason: path);
        expect(node.keyBuffer, legacy.keyBuffer, reason: '$path: same key as dartsv');
        expect(node.chainCode, legacy.chainCode, reason: '$path: same chain code as dartsv');
      }
    });
  });

  test('seeded random roots: keys, chain codes, xpubs and addresses match dartsv and the reference',
      () {
    final random = Random(0x68767020); // "hvp "
    var compared = 0;
    for (var s = 0; s < 12; s++) {
      final seed = hex.encode(List<int>.generate(32, (_) => random.nextInt(256)));
      final network = s.isEven ? dartsv.NetworkType.TEST : dartsv.NetworkType.MAIN;
      // Mnemonic roots and imported xprivs (network from the version bytes).
      final root = s % 3 == 0
          ? dartsv.HDPrivateKey.fromXpriv(dartsv.HDPrivateKey.fromSeed(seed, network).xprivkey)
          : Bip32.masterFromSeed(seed, network);
      expect(root.xprivkey, dartsv.HDPrivateKey.fromSeed(seed, network).xprivkey);
      final ref = refMaster(seed);
      final xpub = root.hdPublicKey;
      final index = random.nextInt(0x7fffffff);
      for (final path in ['m/0/0', 'm/1/0', 'm/0/$index', 'm/1/${index % 1000}']) {
        final expected = refDerive(ref, path);
        final node = Bip32.derivePrivatePath(root, path);
        expect(hex.encode(node.keyBuffer), '00${expected.keyHex}', reason: '$seed $path');
        expect(hex.encode(node.chainCode), refChainHex(expected), reason: '$seed $path');
        expect(node.networkType, root.networkType);
        final pub = Bip32.derivePublicPath(xpub, path);
        expect(hex.encode(pub.keyBuffer), expected.publicKeyHex, reason: '$seed $path');

        final dartsv.HDPrivateKey legacy;
        try {
          legacy = root.deriveChildKey(path);
        } on StateError {
          continue; // the dartsv bug itself; covered above
        }
        compared++;
        expect(node.keyBuffer, legacy.keyBuffer, reason: '$seed $path: dartsv key');
        expect(node.chainCode, legacy.chainCode, reason: '$seed $path: dartsv chain code');
        expect(node.privateKey.toWIF(), legacy.privateKey.toWIF());
        final legacyPub = xpub.deriveChildKey(path);
        // dartsv's derived HDPublicKey drops the parent's network (always
        // serializes as mainnet xpub), so compare the fields, not the string.
        _expectSamePublicNode(pub, legacyPub, '$seed $path');
        expect(pub.publicKey.toAddress(network).toBase58(),
            legacyPub.publicKey.toAddress(network).toBase58());
        // Chain-level public nodes, as AddressDiscoveryService derives them.
        final chain = path.substring(0, 3);
        _expectSamePublicNode(Bip32.derivePublicChild(xpub, int.parse(chain.substring(2))),
            xpub.deriveChildNumber(int.parse(chain.substring(2))), '$seed $chain');
      }
    }
    expect(compared, greaterThan(40), reason: 'most derivations compared with dartsv');
  });

  group('Bip32 edge cases', () {
    final n = ECDomainParameters('secp256k1').n;
    final g = ECDomainParameters('secp256k1').G;

    test('I_L >= n and a zero child private key are rejected', () {
      final k = BigInt.from(12345);
      expect(() => Bip32.addPrivateTweak(n, k), throwsA(isA<dartsv.DerivationException>()));
      expect(() => Bip32.addPrivateTweak(n - k, k), throwsA(isA<dartsv.DerivationException>()));
      expect(Bip32.addPrivateTweak(n - BigInt.one, BigInt.two), BigInt.one);
    });

    test('I_L >= n and the point at infinity are rejected for public derivation', () {
      final k = BigInt.from(777);
      final parent = (g * k)!;
      expect(() => Bip32.addPublicTweak(n, parent), throwsA(isA<dartsv.DerivationException>()));
      expect(() => Bip32.addPublicTweak(n - k, parent),
          throwsA(isA<dartsv.DerivationException>()));
      expect(Bip32.addPublicTweak(BigInt.one, parent), (g * (k + BigInt.one))!);
    });

    test('hardened public derivation is refused', () {
      final root = Bip32.masterFromSeed(_vector1Seed, dartsv.NetworkType.TEST);
      expect(() => Bip32.derivePublicPath(root.hdPublicKey, "m/0'"),
          throwsA(isA<dartsv.DerivationException>()));
    });

    test('ser256 keeps leading zeros', () {
      expect(hex.encode(Bip32.ser256(BigInt.one)), '${'00' * 31}01');
      expect(Bip32.ser256(n - BigInt.one).length, 32);
    });

    test('depth follows the parent and the network is preserved', () {
      final root = Bip32.masterFromSeed(_vector1Seed, dartsv.NetworkType.REGTEST);
      final account = Bip32.derivePrivatePath(root, "m/44'/236'/0'");
      expect(account.nodeDepth, 3);
      final leaf = Bip32.derivePrivatePath(account, 'm/0/1');
      expect(leaf.nodeDepth, 5);
      expect(leaf.networkType, dartsv.NetworkType.REGTEST);
      expect(Bip32.derivePublicPath(account.hdPublicKey, 'm/0/1').nodeDepth, 5);
    });
  });
}
