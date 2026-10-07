import 'package:libspiffy/src/spv/block_header_chain.dart';
import 'package:libspiffy/src/spv/network_params.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';
import 'package:spiffynode/spiffy_node.dart';
import 'package:test/test.dart';

import 'regtest_chain_builder.dart';

/// BlockHeaderChain.acceptHeaders: a peer's batch of headers is validated
/// header by header and written in one storage transaction per run of
/// headers extending the tip. A transaction per header made P2P sync from
/// localnet about 2 ms a header.
void main() {
  final regtest = NetworkParams.regtest;
  final genesis = regtest.genesisHeader;
  DateTime clock() => DateTime.fromMillisecondsSinceEpoch(1296688602 * 1000)
      .add(const Duration(days: 3650));

  BlockHeaderChain newChain(InMemoryWalletStorage storage) =>
      BlockHeaderChain(storage, params: regtest, clock: clock);

  test('a batch extending the tip is written in one storage call', () async {
    final storage = _CountingStorage();
    final chain = newChain(storage);
    await chain.initialize();
    storage.reset();

    final headers = RegtestMiner.mineChain(genesis, 500);
    final results = await chain.acceptHeaders(headers);

    expect(results.every((r) => r.accepted && !r.alreadyKnown), isTrue);
    expect(results.map((r) => r.height), [for (var h = 1; h <= 500; h++) h]);
    expect(storage.singleWrites, 0);
    expect(storage.bulkWrites, [500]);
    expect(chain.bestHeight, 500);
    expect((await storage.getBlockHeaderByHeight(500))!.blockHash(), headers.last.blockHash());
    expect(await storage.getBestHeight(), 500);
  });

  test('headers already held are accepted as known and not written again', () async {
    final storage = _CountingStorage();
    final chain = newChain(storage);
    await chain.initialize();
    final headers = RegtestMiner.mineChain(genesis, 20);
    await chain.acceptHeaders(headers.take(10).toList());
    storage.reset();

    final results = await chain.acceptHeaders(headers);

    expect(results.take(10).every((r) => r.accepted && r.alreadyKnown), isTrue);
    expect(results.skip(10).every((r) => r.accepted && !r.alreadyKnown), isTrue);
    expect(storage.bulkWrites, [10]);
    expect(chain.bestHeight, 20);
  });

  test('a failed write leaves the chain where the run began', () async {
    final storage = _CountingStorage();
    final chain = newChain(storage);
    await chain.initialize();
    final headers = RegtestMiner.mineChain(genesis, 30);
    await chain.acceptHeaders(headers.take(10).toList());

    storage.failBulk = true;
    final results = await chain.acceptHeaders(headers.skip(10).toList());

    expect(results, hasLength(20));
    expect(results.every((r) => !r.accepted && r.reason == HeaderRejectReason.storage), isTrue,
        reason: '$results');
    expect(chain.bestHeight, 10);
    expect(chain.chainTip!.blockHash(), headers[9].blockHash());
    expect(await chain.getHeaderByHeight(11), isNull, reason: 'not cached either');
    expect(await chain.getHeightByHash(headers[10].blockHash().toString()), isNull);

    storage.failBulk = false;
    final retried = await chain.acceptHeaders(headers.skip(10).toList());
    expect(retried.every((r) => r.accepted && !r.alreadyKnown), isTrue);
    expect(chain.bestHeight, 30);
  });

  test('a batch carrying a reorganization is decided on what storage holds', () async {
    final storage = _CountingStorage();
    final chain = newChain(storage);
    await chain.initialize();
    final a = RegtestMiner.mineChain(genesis, 5, seed: 'A'); // heights 1..5
    await chain.acceptHeaders(a);
    storage.reset();

    // One batch: B forks at height 2 and outgrows A, then extends its tip.
    final b = RegtestMiner.mineChain(a[1], 6, seed: 'B'); // heights 3..8
    final results = await chain.acceptHeaders(b);

    expect(results.every((r) => r.accepted), isTrue, reason: '$results');
    final reorg = results.singleWhere((r) => r.reorganized);
    expect(reorg.forkHeight, 2);
    expect(reorg.orphaned.map((h) => h.blockHash()),
        [a[2].blockHash(), a[3].blockHash(), a[4].blockHash()]);
    expect(chain.bestHeight, 8);
    for (var i = 0; i < b.length; i++) {
      expect((await storage.getBlockHeaderByHeight(i + 3))!.blockHash(), b[i].blockHash(),
          reason: 'height ${i + 3}');
    }
    expect(await storage.getBlockHeaderByHash(a[3].blockHash().toString()), isNull,
        reason: 'the outworked branch is orphaned in storage');
    expect(storage.bulkWrites.last, 2, reason: 'the run after the reorganization: heights 7 and 8');
  });

  test('a rejected header in a batch is reported, and the run before it is kept', () async {
    final storage = _CountingStorage();
    final chain = newChain(storage);
    await chain.initialize();
    final headers = RegtestMiner.mineChain(genesis, 6);
    final future = RegtestMiner.mine(
        parent: headers[5], timestamp: clock().add(const Duration(hours: 3)));

    final results = await chain.acceptHeaders([...headers, future]);

    expect(results.take(6).every((r) => r.accepted), isTrue);
    expect(results.last.reason, HeaderRejectReason.timestampTooFar);
    expect(chain.bestHeight, 6);
    expect(await storage.getBestHeight(), 6);
  });

  test('the cache stays bounded and keeps the newest headers (bead libspiffy-j1yc)', () async {
    final storage = InMemoryWalletStorage();
    final chain = newChain(storage);
    await chain.initialize();
    final headers = RegtestMiner.mineChain(genesis, 3000);

    await chain.acceptHeaders(headers.take(2000).toList());
    await chain.acceptHeaders(headers.skip(2000).toList());
    // One at a time, as a block announcement delivers them.
    final more = RegtestMiner.mineChain(headers.last, 50);
    for (final h in more) {
      expect((await chain.acceptHeader(h)).accepted, isTrue);
    }

    expect(chain.cacheSize, 2016);
    expect(chain.bestHeight, 3050);
    // Evicted headers are still read from storage.
    expect((await chain.getHeaderByHeight(1))!.blockHash(), headers.first.blockHash());
    expect((await chain.getHeaderByHeight(3050))!.blockHash(), more.last.blockHash());
  });
}

/// In-memory storage that counts header writes and can fail bulk ones.
class _CountingStorage extends InMemoryWalletStorage {
  int singleWrites = 0;
  final List<int> bulkWrites = [];
  bool failBulk = false;

  void reset() {
    singleWrites = 0;
    bulkWrites.clear();
  }

  @override
  Future<void> storeBlockHeader(BlockHeader header, int height) {
    singleWrites++;
    return super.storeBlockHeader(header, height);
  }

  @override
  Future<void> storeBlockHeadersBulk(List<(BlockHeader, int)> headers) {
    if (failBulk) throw StateError('disk full');
    bulkWrites.add(headers.length);
    return super.storeBlockHeadersBulk(headers);
  }
}
