import 'package:libspiffy/src/spv/block_header_chain.dart';
import 'package:libspiffy/src/spv/difficulty_rules.dart';
import 'package:libspiffy/src/spv/network_params.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';
import 'package:spiffynode/spiffy_node.dart';
import 'package:test/test.dart';

import 'regtest_chain_builder.dart';

/// Difficulty rules against real mainnet headers (fixtures fetched from
/// WhatsOnChain; each row's raw header is re-hashed on load).
void main() {
  final mainnet = NetworkParams.mainnet;
  int secs(BlockHeader h) => h.timestamp.millisecondsSinceEpoch ~/ 1000;

  group('legacy retarget (mainnet, pre-2017)', () {
    final byHeight = {
      for (final (h, b) in loadHeaderFixture('test/data/mainnet_legacy_retarget_headers.json')) h: b
    };

    for (final target in [32256, 34272, 36288]) {
      test('height $target: bits equal CalculateNextWorkRequired over the previous 2015 blocks', () {
        final prev = byHeight[target - 1]!;
        final first = byHeight[target - 2016]!;
        final expected = DifficultyRules.legacyRetargetBits(mainnet,
            lastBits: prev.bits, firstTime: secs(first), lastTime: secs(prev));
        expect(expected, equals(byHeight[target]!.bits),
            reason: 'computed 0x${expected.toRadixString(16)}');
      });
    }

    test('the retarget is clamped to a quarter and to four times the timespan', () {
      const twoWeeks = 14 * 24 * 3600;
      final base = NetworkParams.bitsToTarget(0x1b0404cb);
      // Compare through the compact encoding, which truncates to 3 bytes.
      final fast = DifficultyRules.legacyRetargetBits(mainnet,
          lastBits: 0x1b0404cb, firstTime: 0, lastTime: 1);
      expect(fast, equals(NetworkParams.targetToBits(base >> 2)));
      final slow = DifficultyRules.legacyRetargetBits(mainnet,
          lastBits: 0x1b0404cb, firstTime: 0, lastTime: twoWeeks * 100);
      expect(slow, equals(NetworkParams.targetToBits(base << 2)));
      final capped = DifficultyRules.legacyRetargetBits(mainnet,
          lastBits: mainnet.powLimitBits, firstTime: 0, lastTime: twoWeeks * 100);
      expect(capped, equals(mainnet.powLimitBits));
    });
  });

  group('cw-144 DAA (mainnet, from height 504032)', () {
    for (final fixture in [
      'test/data/mainnet_daa_activation_headers.json',
      'test/data/mainnet_daa_700000_headers.json',
    ]) {
      final rows = loadHeaderFixture(fixture);

      test('$fixture: every DAA-era header carries exactly the bits the DAA computes', () {
        var checked = 0;
        for (var i = 147; i < rows.length; i++) {
          final (height, header) = rows[i];
          if (height <= DifficultyRules.daaActivationHeight) continue;
          final window = rows.sublist(i - 147, i).map((r) => r.$2).toList();
          expect(DifficultyRules.daaBits(mainnet, window), equals(header.bits),
              reason: 'height $height');
          checked++;
        }
        expect(checked, greaterThan(3), reason: 'fixture must exercise the rule');
      });
    }

    test('pre-DAA headers at 504027-504031 do not match the DAA (it must not apply below 504032)',
        () {
      final rows = loadHeaderFixture('test/data/mainnet_daa_activation_headers.json');
      var mismatches = 0;
      for (var i = 147; i < rows.length; i++) {
        final (height, header) = rows[i];
        if (height > DifficultyRules.daaActivationHeight) continue;
        final window = rows.sublist(i - 147, i).map((r) => r.$2).toList();
        if (DifficultyRules.daaBits(mainnet, window) != header.bits) mismatches++;
      }
      expect(mismatches, greaterThan(0));
    });

    test('every consecutive real pair is within the 4x step bound', () {
      for (final fixture in [
        'test/data/mainnet_daa_activation_headers.json',
        'test/data/mainnet_daa_700000_headers.json',
      ]) {
        final rows = loadHeaderFixture(fixture);
        for (var i = 1; i < rows.length; i++) {
          expect(DifficultyRules.withinStepBound(mainnet, rows[i - 1].$2.bits, rows[i].$2.bits),
              isTrue,
              reason: '$fixture height ${rows[i].$1}');
        }
      }
      expect(DifficultyRules.withinStepBound(mainnet, 0x1b0404cb, 0x1b0404cb << 0), isTrue);
      expect(DifficultyRules.withinStepBound(mainnet, 0x18021abd, 0x1d00ffff), isFalse);
    });
  });

  group('DAA wired into BlockHeaderChain (anchored at a checkpoint)', () {
    final rows = loadHeaderFixture('test/data/mainnet_daa_700000_headers.json');

    test('real headers 700001-700199 are accepted; a wrong-bits header after the window is not',
        () async {
      final (anchorHeight, anchorHeader) = rows.first;
      final chain = BlockHeaderChain(
        InMemoryWalletStorage(),
        params: mainnet,
        anchor: BlockHeaderAnchor(anchorHeader, anchorHeight),
        clock: () => rows.last.$2.timestamp.add(const Duration(hours: 1)),
      );
      await chain.initialize();
      expect(chain.bestHeight, equals(anchorHeight));

      for (var i = 1; i < rows.length; i++) {
        final r = await chain.acceptHeader(rows[i].$2);
        expect(r.accepted, isTrue, reason: 'height ${rows[i].$1}: $r');
        expect(r.height, equals(rows[i].$1));
      }
      expect(chain.bestHeight, equals(rows.last.$1));

      // A header after 700199 whose bits are 1% easier than the DAA
      // requires. Its (unmined) hash is far above any mainnet target, so
      // the rejection must come from the difficulty rule, which runs first.
      final tip = rows.last.$2;
      final easier = NetworkParams.targetToBits(
          NetworkParams.bitsToTarget(tip.bits) * BigInt.from(101) ~/ BigInt.from(100));
      final wrong = BlockHeader(
        version: tip.version,
        prevBlock: tip.blockHash(),
        merkleRoot: tip.merkleRoot,
        timestamp: tip.timestamp.add(const Duration(minutes: 10)),
        bits: easier,
        nonce: 1,
      );
      final r = await chain.acceptHeader(wrong);
      expect(r.accepted, isFalse);
      expect(r.reason, equals(HeaderRejectReason.difficulty), reason: '$r');
      expect(r.detail, contains('daa'));
    });
  });
}
