import 'package:libspiffy/src/spv/block_header_chain.dart';
import 'package:libspiffy/src/spv/network_params.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';
import 'package:spiffynode/spiffy_node.dart';
import 'package:test/test.dart';

import 'regtest_chain_builder.dart';

/// SPV-02 (anchor, difficulty, fork choice) and SPV-03 (reorganization)
/// at the BlockHeaderChain level. Every header carries real proof of work
/// mined at regtest difficulty, or is a real mainnet header.
void main() {
  final regtest = NetworkParams.regtest;
  final genesis = regtest.genesisHeader;
  // A fixed "now" well after the mined timestamps (regtest genesis is 2011;
  // chains here run ten minutes per block from there).
  DateTime clock() => DateTime.fromMillisecondsSinceEpoch(1296688602 * 1000)
      .add(const Duration(days: 365));

  BlockHeaderChain newChain(InMemoryWalletStorage storage, {NetworkParams? params}) =>
      BlockHeaderChain(storage, params: params ?? regtest, clock: clock);

  group('SPV-02 anchor', () {
    test('an empty chain rejects a non-genesis first header', () async {
      final chain = newChain(InMemoryWalletStorage());
      // Valid regtest proof of work, but it does not link to genesis.
      final foreignParent = BlockHeader(
        version: 1,
        prevBlock: Hash.zero(),
        merkleRoot: RegtestMiner.merkleRootFor('foreign'),
        timestamp: genesis.timestamp,
        bits: regtest.powLimitBits,
        nonce: 0,
      );
      final rogue = RegtestMiner.mine(parent: foreignParent);

      expect(await chain.validateAndStoreHeader(rogue, 0), isFalse,
          reason: 'a header that is not the network genesis must not start the chain');
      expect(await chain.validateAndStoreHeader(rogue, 1), isFalse);
      expect(chain.chainTip, isNull);
      expect(chain.bestHeight, equals(0));
    });

    test('an empty chain accepts genesis at height 0', () async {
      final chain = newChain(InMemoryWalletStorage());
      expect(await chain.validateAndStoreHeader(genesis, 0), isTrue);
      expect(chain.chainTip!.blockHash().toString(), equals(regtest.genesisHash));
      expect(chain.bestHeight, equals(0));
    });

    test('an empty chain accepts a child of genesis and seeds genesis beneath it', () async {
      final chain = newChain(InMemoryWalletStorage());
      final h1 = RegtestMiner.mine(parent: genesis);
      expect(await chain.validateAndStoreHeader(h1, 1), isTrue);
      expect(chain.bestHeight, equals(1));
      expect((await chain.getHeaderByHeight(0))!.blockHash().toString(),
          equals(regtest.genesisHash));
    });

    test('initialize() seeds genesis into an empty store', () async {
      final storage = InMemoryWalletStorage();
      final chain = newChain(storage);
      await chain.initialize();
      expect(chain.chainTip!.blockHash().toString(), equals(regtest.genesisHash));
      expect((await storage.getBlockHeaderByHeight(0))!.blockHash().toString(),
          equals(regtest.genesisHash));
    });

    test('initialize() accepts a store written by the old code (heights from 1) and back-fills genesis',
        () async {
      final storage = InMemoryWalletStorage();
      final headers = RegtestMiner.mineChain(genesis, 3);
      for (var i = 0; i < headers.length; i++) {
        await storage.storeBlockHeader(headers[i], i + 1);
      }
      final chain = newChain(storage);
      await chain.initialize();
      expect(chain.bestHeight, equals(3));
      expect((await chain.getHeaderByHeight(0))!.blockHash().toString(),
          equals(regtest.genesisHash));
      // And the chain can be extended from it.
      final h4 = RegtestMiner.mine(parent: headers.last);
      expect(await chain.validateAndStoreHeader(h4, 4), isTrue);
    });

    test('initialize() refuses a store whose first header does not link to genesis', () async {
      final storage = InMemoryWalletStorage();
      final foreign = RegtestMiner.mineChain(NetworkParams.testnet.genesisHeader, 2);
      await storage.storeBlockHeader(foreign[0], 1);
      await storage.storeBlockHeader(foreign[1], 2);
      final chain = newChain(storage);
      await expectLater(chain.initialize(), throwsA(isA<StateError>()));
    });

    test('initialize() refuses a store whose height-0 header is not genesis', () async {
      final storage = InMemoryWalletStorage();
      await storage.storeBlockHeader(NetworkParams.testnet.genesisHeader, 0);
      final chain = newChain(storage);
      await expectLater(chain.initialize(), throwsA(isA<StateError>()));
    });

    test('a header whose parent is unknown is rejected, not stored at the caller\'s height',
        () async {
      final chain = newChain(InMemoryWalletStorage());
      await chain.initialize();
      final orphan = RegtestMiner.mine(parent: RegtestMiner.mine(parent: genesis));
      expect(await chain.validateAndStoreHeader(orphan, 2), isFalse);
      expect(chain.bestHeight, equals(0));
    });
  });

  group('SPV-02 proof of work and difficulty', () {
    test('rejects bits easier than the pow limit', () async {
      final chain = newChain(InMemoryWalletStorage());
      await chain.initialize();
      // Target 0xffff << 8*30: above the regtest limit, so almost any hash passes it.
      final tooEasy = RegtestMiner.mine(parent: genesis, bits: 0x2100ffff);
      expect(NetworkParams.bitsToTarget(0x2100ffff) > regtest.powLimit, isTrue);
      expect(await chain.validateAndStoreHeader(tooEasy, 1), isFalse);
      expect(chain.bestHeight, equals(0));
    });

    test('rejects a compact target whose sign bit is set', () async {
      final chain = newChain(InMemoryWalletStorage());
      await chain.initialize();
      final h1 = BlockHeader(
        version: 1,
        prevBlock: genesis.blockHash(),
        merkleRoot: RegtestMiner.merkleRootFor('neg'),
        timestamp: genesis.timestamp.add(const Duration(minutes: 10)),
        bits: 0x2080ffff,
        nonce: 7,
      );
      expect(await chain.validateAndStoreHeader(h1, 1), isFalse);
    });

    test('rejects a header whose hash exceeds its target', () async {
      final chain = newChain(InMemoryWalletStorage());
      await chain.initialize();
      final mined = RegtestMiner.mine(parent: genesis);
      // Same header, re-labelled with a mainnet-difficulty target it cannot meet.
      final relabelled = BlockHeader(
        version: mined.version,
        prevBlock: mined.prevBlock,
        merkleRoot: mined.merkleRoot,
        timestamp: mined.timestamp,
        bits: 0x1d00ffff,
        nonce: mined.nonce,
      );
      final result = await chain.acceptHeader(relabelled);
      expect(result.accepted, isFalse);
      expect(result.reason, equals(HeaderRejectReason.insufficientWork));
    });

    test('rejects a timestamp more than two hours in the future', () async {
      final chain = newChain(InMemoryWalletStorage());
      await chain.initialize();
      final future = RegtestMiner.mine(
          parent: genesis, timestamp: clock().add(const Duration(hours: 2, minutes: 1)));
      expect(await chain.validateAndStoreHeader(future, 1), isFalse);
      final edge = RegtestMiner.mine(
          parent: genesis, timestamp: clock().add(const Duration(hours: 1, minutes: 59)));
      expect(await chain.validateAndStoreHeader(edge, 1), isTrue);
    });

    test('rejects a timestamp at or below the median of the previous eleven', () async {
      final chain = newChain(InMemoryWalletStorage());
      await chain.initialize();
      final headers = RegtestMiner.mineChain(genesis, 12);
      for (var i = 0; i < headers.length; i++) {
        expect(await chain.validateAndStoreHeader(headers[i], i + 1), isTrue, reason: 'h${i + 1}');
      }
      // Median of heights 2..12 is height 7's timestamp.
      final mtp = headers[6].timestamp;
      final stale = RegtestMiner.mine(parent: headers.last, timestamp: mtp);
      expect(await chain.validateAndStoreHeader(stale, 13), isFalse);
      final justAfter = RegtestMiner.mine(parent: headers.last, timestamp: mtp.add(const Duration(seconds: 1)));
      expect(await chain.validateAndStoreHeader(justAfter, 13), isTrue);
    });

    test('mainnet: real headers 0-6 are accepted and a bits change inside a period is rejected',
        () async {
      final chain = BlockHeaderChain(InMemoryWalletStorage(), params: NetworkParams.mainnet);
      final real = loadFirstMainnetHeaders();
      expect(real, hasLength(7));
      for (var i = 0; i < real.length; i++) {
        final r = await chain.acceptHeader(real[i]);
        expect(r.accepted, isTrue, reason: 'height $i: $r');
        expect(r.height, equals(i));
      }
      expect(chain.bestHeight, equals(6));

      // Height 7 with bits != previous bits inside the first retarget
      // period. The difficulty rule fires before the (unmeetable) PoW check.
      final wrongBits = BlockHeader(
        version: 1,
        prevBlock: real[6].blockHash(),
        merkleRoot: RegtestMiner.merkleRootFor('x'),
        timestamp: real[6].timestamp.add(const Duration(minutes: 10)),
        bits: 0x1d00fffe,
        nonce: 0,
      );
      final r = await chain.acceptHeader(wrongBits);
      expect(r.accepted, isFalse);
      expect(r.reason, equals(HeaderRejectReason.difficulty));
    });
  });

  group('SPV-02 fork choice by chainwork', () {
    test('the higher-work branch is the tip even when it is shorter', () async {
      final chain = newChain(InMemoryWalletStorage());
      await chain.initialize();
      final a = RegtestMiner.mineChain(genesis, 3, seed: 'A');
      for (var i = 0; i < a.length; i++) {
        expect(await chain.validateAndStoreHeader(a[i], i + 1), isTrue);
      }
      expect(chain.bestHeight, equals(3));

      // Branch B: two blocks, each 16x the work of an A block.
      final b = RegtestMiner.mineChain(genesis, 2, bits: RegtestMiner.harderBits(4), seed: 'B');
      expect(await chain.validateAndStoreHeader(b[0], 1), isTrue);
      expect(chain.chainTip!.blockHash(), equals(b[0].blockHash()),
          reason: 'one 16x block outweighs three 1x blocks');
      expect(chain.bestHeight, equals(1));

      expect(await chain.validateAndStoreHeader(b[1], 2), isTrue);
      expect(chain.chainTip!.blockHash(), equals(b[1].blockHash()));
      expect(chain.bestHeight, equals(2));
      expect((await chain.getHeaderByHeight(1))!.blockHash(), equals(b[0].blockHash()));
      expect(await chain.getHeaderByHash(a[2].blockHash().toString()), isNull,
          reason: 'the outworked branch is orphaned');
    });

    test('a lower-work competing branch is kept but does not become the tip', () async {
      final chain = newChain(InMemoryWalletStorage());
      await chain.initialize();
      final a = RegtestMiner.mineChain(genesis, 3, seed: 'A');
      for (var i = 0; i < a.length; i++) {
        await chain.validateAndStoreHeader(a[i], i + 1);
      }
      final c = RegtestMiner.mineChain(genesis, 2, seed: 'C');
      for (var i = 0; i < c.length; i++) {
        final r = await chain.acceptHeader(c[i]);
        expect(r.accepted, isTrue);
        expect(r.isNewTip, isFalse);
        expect(r.height, equals(i + 1));
      }
      expect(chain.chainTip!.blockHash(), equals(a[2].blockHash()));
      expect(chain.bestHeight, equals(3));
      expect(await chain.hasHeader(c[1].blockHash().toString()), isTrue);
      expect(chain.sideHeaderCount, equals(2));
      // Active-chain lookups never see it.
      expect(await chain.getHeaderByHash(c[1].blockHash().toString()), isNull);
    });

    test('an equal-work competing branch does not replace the tip', () async {
      final chain = newChain(InMemoryWalletStorage());
      await chain.initialize();
      final a = RegtestMiner.mineChain(genesis, 2, seed: 'A');
      for (var i = 0; i < a.length; i++) {
        await chain.validateAndStoreHeader(a[i], i + 1);
      }
      final d = RegtestMiner.mineChain(genesis, 2, seed: 'D');
      for (final h in d) {
        expect((await chain.acceptHeader(h)).accepted, isTrue);
      }
      expect(chain.chainTip!.blockHash(), equals(a[1].blockHash()));
    });
  });

  group('SPV-03 reorganization', () {
    test('a 2-block reorg replaces the tip and orphans the old branch', () async {
      final storage = InMemoryWalletStorage();
      final chain = newChain(storage);
      await chain.initialize();
      final a = RegtestMiner.mineChain(genesis, 3, seed: 'A'); // heights 1..3
      for (var i = 0; i < a.length; i++) {
        await chain.validateAndStoreHeader(a[i], i + 1);
      }
      // B forks at height 1 and grows to height 4.
      final b = RegtestMiner.mineChain(a[0], 3, seed: 'B'); // heights 2..4
      final r2 = await chain.acceptHeader(b[0]);
      expect(r2.accepted && !r2.isNewTip, isTrue, reason: '$r2');
      final r3 = await chain.acceptHeader(b[1]);
      expect(r3.accepted && !r3.isNewTip, isTrue, reason: 'equal work keeps A: $r3');
      final r4 = await chain.acceptHeader(b[2]);
      expect(r4.accepted, isTrue);
      expect(r4.reorganized, isTrue);
      expect(r4.forkHeight, equals(1));
      expect(r4.orphaned.map((h) => h.blockHash()).toList(),
          equals([a[1].blockHash(), a[2].blockHash()]));

      expect(chain.bestHeight, equals(4));
      expect(chain.chainTip!.blockHash(), equals(b[2].blockHash()));
      expect((await chain.getHeaderByHeight(2))!.blockHash(), equals(b[0].blockHash()));
      expect((await chain.getHeaderByHeight(3))!.blockHash(), equals(b[1].blockHash()));
      expect(await chain.getHeaderByHash(a[1].blockHash().toString()), isNull);
      expect(await chain.getHeightByHash(a[2].blockHash().toString()), isNull);
      expect(await storage.getBlockHeaderByHash(a[1].blockHash().toString()), isNull,
          reason: 'orphaned in storage');
      expect((await storage.getBlockHeaderByHeight(2))!.blockHash(), equals(b[0].blockHash()));
    });

    test('getChainTip after a restart reflects the reorg', () async {
      final storage = InMemoryWalletStorage();
      final chain = newChain(storage);
      await chain.initialize();
      final a = RegtestMiner.mineChain(genesis, 3, seed: 'A');
      for (var i = 0; i < a.length; i++) {
        await chain.validateAndStoreHeader(a[i], i + 1);
      }
      final b = RegtestMiner.mineChain(a[0], 3, seed: 'B');
      for (final h in b) {
        await chain.acceptHeader(h);
      }
      expect(chain.bestHeight, equals(4));

      final restarted = newChain(storage);
      await restarted.initialize();
      expect(restarted.bestHeight, equals(4));
      expect(restarted.chainTip!.blockHash(), equals(b[2].blockHash()));
      expect((await restarted.getHeaderByHeight(2))!.blockHash(), equals(b[0].blockHash()));
      expect(await restarted.getHeaderByHash(a[2].blockHash().toString()), isNull);
      // The restarted chain extends the new branch, and rejects the old one.
      final b5 = RegtestMiner.mine(parent: b[2]);
      expect(await restarted.validateAndStoreHeader(b5, 5), isTrue);
      final a4 = RegtestMiner.mine(parent: a[2]);
      expect(await restarted.validateAndStoreHeader(a4, 4), isFalse,
          reason: 'the orphaned branch is unknown after a restart');
    });

    test('handleReorganization stores the new branch and moves the tip only on more work',
        () async {
      final chain = newChain(InMemoryWalletStorage());
      await chain.initialize();
      final a = RegtestMiner.mineChain(genesis, 3, seed: 'A');
      for (var i = 0; i < a.length; i++) {
        await chain.validateAndStoreHeader(a[i], i + 1);
      }
      final shortB = RegtestMiner.mineChain(a[0], 2, seed: 'B');
      await chain.handleReorganization([a[1], a[2]], shortB);
      expect(chain.chainTip!.blockHash(), equals(a[2].blockHash()),
          reason: 'equal work: the tip stays');

      final b3 = RegtestMiner.mine(parent: shortB.last, seed: 'B3');
      final last = await chain.handleReorganization([], [b3]);
      expect(last!.reorganized, isTrue);
      expect(chain.bestHeight, equals(4));
      expect(chain.chainTip!.blockHash(), equals(b3.blockHash()));
    });

    test('validateAndStoreHeader rejects a height that disagrees with the parent', () async {
      final chain = newChain(InMemoryWalletStorage());
      await chain.initialize();
      final a = RegtestMiner.mineChain(genesis, 2);
      expect(await chain.validateAndStoreHeader(a[0], 1), isTrue);
      expect(await chain.validateAndStoreHeader(a[1], 3), isFalse);
      expect(await chain.validateAndStoreHeader(a[1], 2), isTrue);
    });

    test('block locator lists recent tips densely, then sparsely, ending at genesis', () async {
      final chain = newChain(InMemoryWalletStorage());
      await chain.initialize();
      final a = RegtestMiner.mineChain(genesis, 40);
      for (var i = 0; i < a.length; i++) {
        await chain.validateAndStoreHeader(a[i], i + 1);
      }
      final locator = await chain.buildBlockLocator();
      expect(locator.first, equals(a.last.blockHash()));
      expect(locator.last, equals(genesis.blockHash()));
      expect(locator.length, lessThan(a.length));
      expect(locator.length, greaterThan(10));
    });
  });

  // Bead libspiffy-lpjh: a refund claim waits for the chain's median time
  // past, the time the network holds a time lock to.
  group('median time past', () {
    test('is unknown while the chain holds no header', () async {
      expect(await newChain(InMemoryWalletStorage()).medianTimePast(), isNull);
    });

    test('is the median timestamp of the last eleven headers, not the tip\'s',
        () async {
      final chain = newChain(InMemoryWalletStorage());
      await chain.initialize();
      final headers = RegtestMiner.mineChain(genesis, 12); // heights 1..12
      for (var i = 0; i < headers.length; i++) {
        expect(await chain.validateAndStoreHeader(headers[i], i + 1), isTrue);
      }

      // Heights 2..12; the median is height 7, fifty minutes before the tip.
      expect(await chain.medianTimePast(), headers[6].timestamp);
      expect(headers.last.timestamp.difference(headers[6].timestamp),
          const Duration(minutes: 50));
    });

    test('counts every header there is on a chain shorter than eleven',
        () async {
      final chain = newChain(InMemoryWalletStorage());
      await chain.initialize();
      final headers = RegtestMiner.mineChain(genesis, 4); // heights 1..4
      for (var i = 0; i < headers.length; i++) {
        expect(await chain.validateAndStoreHeader(headers[i], i + 1), isTrue);
      }

      // Heights 0..4: the median is height 2.
      expect(await chain.medianTimePast(), headers[1].timestamp);
    });
  });
}
