import 'package:test/test.dart';
import 'package:dartsv/dartsv.dart' as dartsv;

import 'package:libspiffy/src/utils/network_name.dart';

/// Audit 2026-09-14 KM-3 / H1: 'main' and 'mainnet' were compared
/// inconsistently across the aggregate, projection, coordinators and
/// importer. NetworkName is the single place every comparison goes through,
/// so it must accept every spelling in use.
void main() {
  group('NetworkName', () {
    test('isMainnet accepts every mainnet spelling', () {
      expect(NetworkName.isMainnet('main'), isTrue);
      expect(NetworkName.isMainnet('mainnet'), isTrue);
      expect(NetworkName.isMainnet('livenet'), isTrue);
      expect(NetworkName.isMainnet(' MainNet '), isTrue,
          reason: 'case and whitespace insensitive');
    });

    test('isMainnet is false for testnet spellings, regtest, unknown and null', () {
      expect(NetworkName.isMainnet('test'), isFalse);
      expect(NetworkName.isMainnet('testnet'), isFalse);
      expect(NetworkName.isMainnet('regtest'), isFalse);
      expect(NetworkName.isMainnet('bogus'), isFalse);
      expect(NetworkName.isMainnet(''), isFalse);
      expect(NetworkName.isMainnet(null), isFalse);
    });

    test('toDartsv maps both mainnet spellings to MAIN and everything else to TEST', () {
      expect(NetworkName.toDartsv('main'), equals(dartsv.NetworkType.MAIN));
      expect(NetworkName.toDartsv('mainnet'), equals(dartsv.NetworkType.MAIN));
      expect(NetworkName.toDartsv('livenet'), equals(dartsv.NetworkType.MAIN));
      expect(NetworkName.toDartsv('test'), equals(dartsv.NetworkType.TEST));
      expect(NetworkName.toDartsv('testnet'), equals(dartsv.NetworkType.TEST));
      expect(NetworkName.toDartsv('regtest'), equals(dartsv.NetworkType.TEST),
          reason: 'regtest keys and addresses use the testnet encoding');
      expect(NetworkName.toDartsv(null), equals(dartsv.NetworkType.TEST));
    });

    // x27: regtest used to be persisted as 'testnet', which selected the
    // testnet genesis and CDN directory for a regtest wallet.
    test('canonical persists mainnet/testnet/regtest regardless of input spelling', () {
      expect(NetworkName.canonical('main'), equals('mainnet'));
      expect(NetworkName.canonical('mainnet'), equals('mainnet'));
      expect(NetworkName.canonical('livenet'), equals('mainnet'));
      expect(NetworkName.canonical('test'), equals('testnet'));
      expect(NetworkName.canonical('testnet'), equals('testnet'));
      expect(NetworkName.canonical(null), equals('testnet'));
      expect(NetworkName.canonical('regtest'), equals('regtest'));
      expect(NetworkName.canonical(' RegTest '), equals('regtest'));
    });

    test('isRegtest accepts regtest in any case and nothing else', () {
      expect(NetworkName.isRegtest('regtest'), isTrue);
      expect(NetworkName.isRegtest(' REGTEST '), isTrue);
      expect(NetworkName.isRegtest('testnet'), isFalse);
      expect(NetworkName.isRegtest('test'), isFalse);
      expect(NetworkName.isRegtest(null), isFalse);
    });
  });
}
