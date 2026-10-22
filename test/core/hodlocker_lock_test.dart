import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:hex/hex.dart';
import 'package:libspiffy/libspiffy.dart';
import 'package:test/test.dart';

/// Output 0 of mainnet transaction 5ddb6de9…c06a (block 810334): 0.1 BSV
/// locked by hodlocker.com until block 810477, unlocked at block 820369.
const _mainnetLock = '2097dfd76851bf465e8f715593b217714858bbe9570ff3bd5e33840a34e20ff0262102ba79df5f8ae7604a9830f03c7933028186aede0675a16f025dc4f8be8eec0382201008ce7480da41702918d1ec8e6849ba32b4d65b1e40dc669c31a1e6306b266c000014cbed023da0a2eec2a500df00d9a78e5fe49c17f903ed5d0c610079040065cd1d9f690079547a75537a537a537a5179537a75527a527a7575615579014161517957795779210ac407f0e4bd44bfc207355a778b046225a7068fc59ee7eda43ad905aadbffc800206c266b30e6a1319c66dc401e5bd6b432ba49688eecd118297041da8074ce081059795679615679aa0079610079517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e01007e81517a75615779567956795679567961537956795479577995939521414136d08c5ed2bf3ba048afe6dcaebafeffffffffffffffffffffffffffffff00517951796151795179970079009f63007952799367007968517a75517a75517a7561527a75517a517951795296a0630079527994527a75517a6853798277527982775379012080517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e01205279947f7754537993527993013051797e527e54797e58797e527e53797e52797e57797e0079517a75517a75517a75517a75517a75517a75517a75517a75517a75517a75517a75517a75517a756100795779ac517a75517a75517a75517a75517a75517a75517a75517a75517a7561517a75517a756169557961007961007982775179517954947f75517958947f77517a75517a756161007901007e81517a7561517a7561040065cd1d9f6955796100796100798277517951790128947f755179012c947f77517a75517a756161007901007e81517a7561517a756105ffffffff009f69557961007961007982775179517954947f75517958947f77517a75517a756161007901007e81517a7561517a75615279a2695679a95179876957795779ac7777777777777777';

void main() {
  group('HodlockerLock', () {
    test('reads the key hash and the lock height of a real mainnet lock', () {
      final lock = HodlockerLock.parseHex(_mainnetLock);
      expect(lock, const HodlockerLock('cbed023da0a2eec2a500df00d9a78e5fe49c17f9', 810477));
      expect(lock!.ownerAddress(dartsv.NetworkType.MAIN), '1KbG6bi6C55CVtZE6p6a4i4oxUwZTZyhCy');
      expect(HodlockerLock.looksLike(_mainnetLock), isTrue);
    });

    test('reads back what dartsv builds, for heights of every push size and the small-number opcodes', () {
      for (final height in [1, 10, 16, 17, 200, 40000, 810477, 499999999]) {
        final pkh = List.generate(20, (i) => i + height % 7);
        final script = dartsv.HODLockerLockingScriptBuilder(pkh, BigInt.from(height)).getScriptPubkey().toHex();
        final lock = HodlockerLock.parseHex(script);
        expect(lock?.lockHeight, height, reason: 'height $height');
        expect(lock?.pubKeyHashHex, HEX.encode(pkh));
      }
    });

    test('a script that differs anywhere in the fixed code is not a lock', () {
      final i = _mainnetLock.length - 10;
      final flipped = _mainnetLock[i] == '0' ? '1' : '0';
      final altered = '${_mainnetLock.substring(0, i)}$flipped${_mainnetLock.substring(i + 1)}';
      expect(HodlockerLock.parseHex(altered), isNull);
      expect(HodlockerLock.parseHex(_mainnetLock.substring(0, _mainnetLock.length - 2)), isNull);
      expect(HodlockerLock.parseHex('76a914cbed023da0a2eec2a500df00d9a78e5fe49c17f988ac'), isNull);
    });

    test('the metadata names the plugin, the height and the owner', () {
      final meta = HodlockerLock.parseHex(_mainnetLock)!.metadata(dartsv.NetworkType.MAIN);
      expect(meta, {
        'pluginId': 'hodlocker',
        'scriptType': 'hodlocker',
        'lockHeight': 810477,
        'ownerAddress': '1KbG6bi6C55CVtZE6p6a4i4oxUwZTZyhCy',
      });
    });

    test('spendable from the lock height on', () {
      const lock = HodlockerLock('00', 100);
      expect(lock.isSpendableAt(99), isFalse);
      expect(lock.isSpendableAt(100), isTrue);
    });
  });
}
