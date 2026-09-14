import 'dart:io';

import 'package:isar/isar.dart';
import 'package:spiffynode/spiffy_node.dart';
import 'package:test/test.dart';

import 'package:libspiffy/src/storage/isar_wallet_storage.dart';
import 'package:libspiffy/src/storage/libspiffy_schemas.dart';

import '../integration/isar_test_helper.dart';

/// Builds a syntactically valid header chained to [prev]; [nonce] makes the
/// hash unique so two headers can share a height (a reorg).
BlockHeader _header({required Hash prev, required int nonce}) => BlockHeader(
      version: 1,
      prevBlock: prev,
      merkleRoot: Hash.fromHex('4a5e1e4baab89f3a32518a88c31bc87f618f76673e2cc77ab2127b7afdeda33b'),
      timestamp: DateTime.fromMillisecondsSinceEpoch(1231006505 * 1000),
      bits: 0x1d00ffff,
      nonce: nonce,
    );

void main() {
  group('IsarWalletStorage block headers', () {
    late Directory tempDir;
    late Isar isar;
    late IsarWalletStorage storage;

    setUpAll(() async {
      await ensureIsarInitialized();
    });

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('isar_wallet_storage_test_');
      isar = await Isar.open(
        LibSpiffySchemas.allSchemas,
        directory: tempDir.path,
        name: 'headers_${DateTime.now().microsecondsSinceEpoch}',
      );
      storage = IsarWalletStorage(isar);
    });

    tearDown(() async {
      await isar.close();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    /// Audit 2026-09-14 S-04: getChainTip/getBestHeight ignored the orphan
    /// flag. After a reorganization the orphaned header at the old tip was
    /// still reported as the chain tip / best height.
    group('chain tip after a reorganization (audit S-04)', () {
      late BlockHeader h1;
      late BlockHeader h2;
      late BlockHeader h3;

      setUp(() async {
        h1 = _header(prev: Hash.fromHex('0' * 64), nonce: 1);
        h2 = _header(prev: h1.blockHash(), nonce: 2);
        h3 = _header(prev: h2.blockHash(), nonce: 3);
        await storage.storeBlockHeader(h1, 1);
        await storage.storeBlockHeader(h2, 2);
        await storage.storeBlockHeader(h3, 3);
        expect(await storage.getBestHeight(), equals(3));
        expect((await storage.getChainTip())!.blockHash(), equals(h3.blockHash()));
      });

      test('orphaning the tip lowers the best height and moves the tip back', () async {
        await storage.markHeaderAsOrphaned(h3.blockHash().toString());

        expect(await storage.getBestHeight(), equals(2),
            reason: 'best height must not count the orphaned header');
        final tip = await storage.getChainTip();
        expect(tip, isNotNull);
        expect(tip!.blockHash(), equals(h2.blockHash()));
      });

      test('a replacement header at the orphaned height becomes the tip', () async {
        await storage.markHeaderAsOrphaned(h3.blockHash().toString());
        final h3b = _header(prev: h2.blockHash(), nonce: 33);
        expect(h3b.blockHash(), isNot(equals(h3.blockHash())));
        await storage.storeBlockHeader(h3b, 3);

        expect(await storage.getBestHeight(), equals(3));
        final tip = await storage.getChainTip();
        expect(tip, isNotNull);
        expect(tip!.blockHash(), equals(h3b.blockHash()),
            reason: 'the orphaned header shares height 3 and must not be returned');
        expect(tip.nonce, equals(33));
      });
    });
  });
}
