/// Filling in the headers below a chain that started at a built-in
/// checkpoint, newest first, down to genesis (epic spiffyvault-emk, step
/// emk.3).
///
/// A regtest chain of 250 headers on the real regtest genesis block, served
/// by a fake CDN in chunks of 50, with the chain started at height 175 (in
/// the middle of a chunk). Every header is mined with real proof of work.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' hide Hash;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:libspiffy/src/spv/block_header_chain.dart';
import 'package:libspiffy/src/spv/cdn_header_sync_config.dart';
import 'package:libspiffy/src/spv/cdn_header_sync_service.dart';
import 'package:libspiffy/src/spv/cdn_manifest.dart';
import 'package:libspiffy/src/spv/header_backfill_runner.dart';
import 'package:libspiffy/src/spv/network_params.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';
import 'package:spiffynode/spiffy_node.dart';
import 'package:test/test.dart';

import 'regtest_chain_builder.dart';

const _checkpoint = 175;
const _chunkSize = 50;

void main() {
  final regtest = NetworkParams.regtest;
  final genesis = regtest.genesisHeader;
  DateTime clock() => DateTime.fromMillisecondsSinceEpoch(1296688602 * 1000).add(const Duration(days: 3650));

  /// Heights 0..249 (index = height).
  final chain = [genesis, ...RegtestMiner.mineChain(genesis, 249, seed: 'emk3')];

  /// A store holding the chain from the checkpoint up, as a fresh install
  /// that started at the checkpoint and stored its window.
  Future<(InMemoryWalletStorage, BlockHeaderChain)> startedAtCheckpoint(List<BlockHeader> headers) async {
    final storage = InMemoryWalletStorage();
    final headerChain = BlockHeaderChain(storage,
        params: regtest, anchor: BlockHeaderAnchor(headers[_checkpoint], _checkpoint), clock: clock);
    await headerChain.initialize();
    await headerChain.bulkImportHeaders(headers.sublist(_checkpoint + 1), _checkpoint + 1);
    return (storage, headerChain);
  }

  group('BlockHeaderChain', () {
    test('lowestHeldHeight finds the bottom of the held run', () async {
      final (_, headerChain) = await startedAtCheckpoint(chain);
      expect(await headerChain.lowestHeldHeight(), _checkpoint);
      await headerChain.storeBelow(chain.sublist(160, _checkpoint), 160);
      expect(await headerChain.lowestHeldHeight(), 160);
    });

    test('storeBelow keeps the tip where it is', () async {
      final (_, headerChain) = await startedAtCheckpoint(chain);
      await headerChain.storeBelow(chain.sublist(100, _checkpoint), 100);
      expect(headerChain.bestHeight, 249);
      expect(headerChain.chainTip!.blockHash().toString(), chain.last.blockHash().toString());
    });

    test('a run that does not end right below the lowest header held is refused', () async {
      final (storage, headerChain) = await startedAtCheckpoint(chain);
      await expectLater(headerChain.storeBelow(chain.sublist(100, 150), 100), throwsFormatException);
      expect(await storage.getBlockHeaderByHeight(120), isNull);
    });

    test('a run that does not link to the header above is refused, and nothing of it stored', () async {
      final (storage, headerChain) = await startedAtCheckpoint(chain);
      final elsewhere = [genesis, ...RegtestMiner.mineChain(genesis, 174, seed: 'other')];
      await expectLater(headerChain.storeBelow(elsewhere.sublist(150, _checkpoint), 150), throwsFormatException);
      expect(await storage.getBlockHeaderByHeight(174), isNull);
      expect(await headerChain.lowestHeldHeight(), _checkpoint);
    });

    test('a header without its proof of work is refused, though every hash links', () async {
      final weak = _weakChain(genesis, 249, weakAt: 160);
      final (storage, headerChain) = await startedAtCheckpoint(weak);
      await expectLater(headerChain.storeBelow(weak.sublist(150, _checkpoint), 150),
          throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('proof of work'))));
      expect(await storage.getBlockHeaderByHeight(174), isNull);
    });

    test('a chain that ends at another genesis block is refused at height 0', () async {
      final fakeGenesis = RegtestMiner.mine(parent: genesis, seed: 'fake-genesis');
      final fake = [fakeGenesis, ...RegtestMiner.mineChain(fakeGenesis, 249, seed: 'fake')];
      final (storage, headerChain) = await startedAtCheckpoint(fake);
      await headerChain.storeBelow(fake.sublist(1, _checkpoint), 1);
      await expectLater(headerChain.storeBelow(fake.sublist(0, 1), 0),
          throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('genesis'))));
      expect(await storage.getBlockHeaderByHeight(0), isNull);
    });
  });

  group('CdnHeaderSyncService.backfillNext', () {
    test('fills in chunk by chunk, newest first, down to genesis; the next start is anchored at genesis',
        () async {
      final cdn = _FakeCdn(chain);
      final (storage, headerChain) = await startedAtCheckpoint(chain);
      final service = cdn.service(headerChain);

      final steps = <(int?, int?, int)>[];
      while (true) {
        final step = await service.backfillNext();
        steps.add((step.fromHeight, step.toHeight, step.lowestHeight));
        if (step.complete) break;
      }
      expect(steps, [
        (150, 174, 150), // the chunk holding the checkpoint, cut at it
        (100, 149, 100),
        (50, 99, 50),
        (0, 49, 0),
      ]);
      expect(cdn.chunksServed, ['h150.bin', 'h100.bin', 'h50.bin', 'h0.bin']);
      expect(cdn.manifestsServed, 1);
      expect((await service.backfillNext()).headersStored, 0, reason: 'nothing left to do');

      for (var h = 0; h < 250; h++) {
        expect((await storage.getBlockHeaderByHeight(h))?.blockHash().toString(), chain[h].blockHash().toString());
      }
      expect(headerChain.bestHeight, 249);

      final anchor = await BlockHeaderChain.chooseAnchor(storage, regtest,
          checkpoint: BlockHeaderAnchor(chain[_checkpoint], _checkpoint));
      expect(anchor.height, 0, reason: 'a store holding height 0 is anchored at genesis');
      final reopened = BlockHeaderChain(storage, params: regtest, anchor: anchor, clock: clock);
      await reopened.initialize();
      expect(reopened.bestHeight, 249);
    });

    test('a fill stopped part way carries on after a restart', () async {
      final cdn = _FakeCdn(chain);
      final (storage, headerChain) = await startedAtCheckpoint(chain);
      await cdn.service(headerChain).backfillNext();
      await cdn.service(headerChain).backfillNext();

      final reopened = BlockHeaderChain(storage,
          params: regtest,
          anchor: await BlockHeaderChain.chooseAnchor(storage, regtest,
              checkpoint: BlockHeaderAnchor(chain[_checkpoint], _checkpoint)),
          clock: clock);
      await reopened.initialize();
      expect(reopened.anchor.height, _checkpoint);
      final step = await cdn.service(reopened).backfillNext();
      expect((step.fromHeight, step.toHeight), (50, 99));
    });

    test('a chunk the CDN changed is refused and nothing of it is stored', () async {
      final elsewhere = [genesis, ...RegtestMiner.mineChain(genesis, 249, seed: 'not-ours')];
      // The CDN serves another chain's headers 100..149, with a matching
      // SHA-256 in its manifest: only the link to our own header catches it.
      final cdn = _FakeCdn(chain, replace: {100: elsewhere});
      final (storage, headerChain) = await startedAtCheckpoint(chain);
      final service = cdn.service(headerChain);
      await service.backfillNext();
      await expectLater(service.backfillNext(), throwsA(predicate((e) => '$e'.contains('rejected'))));
      expect(await headerChain.lowestHeldHeight(), 150);
      expect(await storage.getBlockHeaderByHeight(149), isNull);
    });
  });

  group('HeaderBackfillRunner', () {
    CdnBackfillStep stepTo(int lowest, {int? from}) =>
        CdnBackfillStep(lowestHeight: lowest, fromHeight: lowest, toHeight: (from ?? lowest + 50) - 1);

    test('runs until complete, reporting every step', () async {
      final lowest = [150, 100, 50, 0];
      final reported = <int>[];
      final runner = HeaderBackfillRunner(
        step: () async => stepTo(lowest.removeAt(0)),
        onStored: (s) => reported.add(s.lowestHeight),
      );
      expect(await runner.run(), isTrue);
      expect(reported, [150, 100, 50, 0]);
    });

    test('downloads nothing while it is not allowed, and goes on once it is', () async {
      var allowed = false;
      var asked = 0;
      var steps = 0;
      final runner = HeaderBackfillRunner(
        step: () async {
          steps++;
          return stepTo(0);
        },
        mayDownload: () async {
          asked++;
          if (asked == 3) allowed = true;
          return allowed;
        },
        onStored: (_) {},
        notAllowedWait: const Duration(milliseconds: 5),
      );
      expect(await runner.run(), isTrue);
      expect((asked, steps), (3, 1));
    });

    test('a failed step is tried again after a growing wait', () async {
      var calls = 0;
      final runner = HeaderBackfillRunner(
        step: () async {
          calls++;
          if (calls < 3) throw Exception('CDN down');
          return stepTo(0);
        },
        onStored: (_) {},
        firstRetry: const Duration(milliseconds: 5),
        maxRetry: const Duration(milliseconds: 8),
      );
      expect(await runner.run(), isTrue);
      expect(calls, 3);
    });

    test('stop ends a wait at once', () async {
      final runner = HeaderBackfillRunner(
        step: () async => stepTo(100),
        mayDownload: () async => false,
        onStored: (_) {},
        notAllowedWait: const Duration(hours: 1),
      );
      final done = runner.run();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      runner.stop();
      expect(await done.timeout(const Duration(seconds: 2)), isFalse);
    });
  });
}

/// [count] headers on [genesis], with the one at [weakAt] lacking proof of
/// work (its hash is above its own target); the rest are mined properly
/// and every hash links. Heights 0..count.
List<BlockHeader> _weakChain(BlockHeader genesis, int count, {required int weakAt}) {
  final out = [genesis];
  for (var h = 1; h <= count; h++) {
    final parent = out.last;
    if (h != weakAt) {
      out.add(RegtestMiner.mine(parent: parent, seed: 'weak/$h'));
      continue;
    }
    final bits = NetworkParams.regtest.powLimitBits;
    final target = NetworkParams.bitsToTarget(bits);
    for (var nonce = 0;; nonce++) {
      final header = BlockHeader(
        version: 1,
        prevBlock: parent.blockHash(),
        merkleRoot: RegtestMiner.merkleRootFor('weak/$h'),
        timestamp: parent.timestamp.add(RegtestMiner.spacing),
        bits: bits,
        nonce: nonce,
      );
      if (NetworkParams.hashToBigInt(header.blockHash().toString()) > target) {
        out.add(header);
        break;
      }
    }
  }
  return out;
}

/// A header CDN serving [chain] in chunks of [_chunkSize]; [replace] serves
/// another chain's headers for the chunk starting at a height.
class _FakeCdn {
  final List<BlockHeader> chain;
  final Map<int, List<BlockHeader>> replace;
  final chunksServed = <String>[];
  var manifestsServed = 0;

  _FakeCdn(this.chain, {this.replace = const {}});

  Uint8List _bytes(int start) {
    final source = replace[start] ?? chain;
    final out = BytesBuilder();
    for (var h = start; h < start + _chunkSize; h++) {
      out.add(source[h].serialize());
    }
    return out.toBytes();
  }

  Map<String, dynamic> get _manifest => {
        'version': 1,
        'network': 'regtest',
        'generatedAt': '2026-11-10T00:00:00Z',
        'totalHeaders': chain.length,
        'chunkSize': _chunkSize,
        'chunks': [
          for (var start = 0; start < chain.length; start += _chunkSize)
            {
              'filename': 'h$start.bin',
              'startHeight': start,
              'endHeight': start + _chunkSize - 1,
              'headerCount': _chunkSize,
              'sha256': sha256.convert(_bytes(start)).toString(),
              'sizeBytes': _chunkSize * 80,
            },
        ],
        'checkpoints': <String, String>{},
      };

  CdnHeaderSyncService service(BlockHeaderChain headerChain) => CdnHeaderSyncService(
        config: CdnHeaderSyncConfig(baseUrl: 'http://cdn.test', allowInsecureHttp: true, network: 'regtest', maxRetries: 1),
        headerChain: headerChain,
        httpClient: http_testing.MockClient((request) async {
          final name = request.url.pathSegments.last;
          if (name == 'manifest.json') {
            manifestsServed++;
            return http.Response(jsonEncode(_manifest), 200);
          }
          chunksServed.add(name);
          return http.Response.bytes(_bytes(int.parse(name.substring(1, name.length - 4))), 200);
        }),
      );
}
