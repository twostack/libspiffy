/// The header window an app ships, and a chain that starts at its
/// checkpoint (epic spiffyvault-emk, step emk.1).
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:libspiffy/src/spv/block_header_chain.dart';
import 'package:libspiffy/src/spv/header_checkpoint.dart';
import 'package:libspiffy/src/spv/network_params.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';
import 'package:spiffynode/spiffy_node.dart';
import 'package:test/test.dart';

import 'regtest_chain_builder.dart';

void main() {
  final regtest = NetworkParams.regtest;
  final genesis = regtest.genesisHeader;
  DateTime clock() => DateTime.fromMillisecondsSinceEpoch(1296688602 * 1000).add(const Duration(days: 3650));

  // Heights 1..60; the window is 41..60.
  final chain = RegtestMiner.mineChain(genesis, 60, seed: 'emk1');
  const windowStart = 41;
  List<BlockHeader> window() => chain.sublist(windowStart - 1);
  Uint8List encoded() => HeaderCheckpoint.encode('regtest', windowStart, window());

  group('the file', () {
    test('a window is read back as it was written, 48 bytes a header after the first', () {
      final bytes = encoded();
      expect(bytes.length, 6 + 'regtest'.length + 8 + 80 + 48 * 19 + 32);

      final decoded = HeaderCheckpoint.decode(bytes, regtest);
      expect(decoded.startHeight, windowStart);
      expect(decoded.tipHeight, 60);
      expect([for (final h in decoded.headers) h.blockHash().toString()],
          [for (final h in window()) h.blockHash().toString()]);
      expect(decoded.anchor.hash, chain[windowStart - 1].blockHash().toString());

      final cheap = HeaderCheckpoint.readAnchor(bytes, regtest);
      expect((cheap.anchor.height, cheap.anchor.hash, cheap.tipHeight), (windowStart, decoded.anchor.hash, 60));
    });

    test('a changed byte, a cut file, or another network is refused', () {
      final changed = encoded();
      changed[changed.length - 32 - 10] ^= 0x01; // a nonce near the end
      expect(() => HeaderCheckpoint.decode(changed, regtest), throwsFormatException);

      final cut = Uint8List.sublistView(encoded(), 0, encoded().length - 48);
      expect(() => HeaderCheckpoint.decode(cut, regtest), throwsFormatException);

      expect(() => HeaderCheckpoint.decode(encoded(), NetworkParams.mainnet), throwsFormatException);
      expect(() => HeaderCheckpoint.readAnchor(encoded(), NetworkParams.mainnet), throwsFormatException);
    });

    test('a header without its proof of work is refused', () {
      final weak = BlockHeader(
        version: 1,
        prevBlock: chain.last.blockHash(),
        merkleRoot: RegtestMiner.merkleRootFor('weak'),
        timestamp: chain.last.timestamp.add(RegtestMiner.spacing),
        bits: 0x1d00ffff, // a mainnet-sized target no nonce of ours meets
        nonce: 0,
      );
      final bytes = HeaderCheckpoint.encode('regtest', windowStart, [...window(), weak]);
      expect(() => HeaderCheckpoint.decode(bytes, regtest), throwsFormatException);
    });

    test('headers that do not link are never written', () {
      expect(() => HeaderCheckpoint.encode('regtest', windowStart, [chain[40], chain[42]]), throwsArgumentError);
    });

    test('decoding runs on another isolate', () async {
      final loaded = await HeaderCheckpoint.load(encoded(), regtest);
      expect(loaded.headers, hasLength(20));
    });
  });

  group('a chain started at the checkpoint', () {
    test('a fresh store is anchored at the checkpoint and holds the whole window', () async {
      final storage = InMemoryWalletStorage();
      final bytes = encoded();
      final checkpoint = HeaderCheckpoint.readAnchor(bytes, regtest).anchor;
      final anchor = await BlockHeaderChain.chooseAnchor(storage, regtest, checkpoint: checkpoint);
      expect(anchor.height, windowStart);

      final headerChain = BlockHeaderChain(storage, params: regtest, anchor: anchor, clock: clock);
      await headerChain.initialize();
      expect(headerChain.bestHeight, windowStart, reason: 'the start stores the checkpoint only');
      expect(await headerChain.extendFromWindow(await HeaderCheckpoint.load(bytes, regtest)), 19);
      expect(headerChain.bestHeight, 60);
      expect((await storage.getBlockHeaderByHeight(windowStart))?.blockHash().toString(), checkpoint.hash);
      expect(await storage.getBlockHeaderByHeight(windowStart - 1), isNull,
          reason: 'nothing below the checkpoint until it is filled in');

      // New blocks extend it as they extend any chain.
      final next = RegtestMiner.mineChain(chain.last, 3, seed: 'emk1-next');
      final results = await headerChain.acceptHeaders(next);
      expect(results.every((r) => r.accepted), isTrue, reason: '${results.map((r) => r.detail)}');
      expect(headerChain.bestHeight, 63);

      // The next start keeps it: same anchor, and the window adds nothing.
      final again = await BlockHeaderChain.chooseAnchor(storage, regtest, checkpoint: checkpoint);
      expect(again.height, windowStart);
      final reopened = BlockHeaderChain(storage, params: regtest, anchor: again, clock: clock);
      await reopened.initialize();
      expect(reopened.bestHeight, 63);
      expect(await reopened.extendFromWindow(HeaderCheckpoint.decode(bytes, regtest)), 0);
    });

    test('a start stopped part way through the window carries on from its tip', () async {
      final storage = InMemoryWalletStorage();
      final window = HeaderCheckpoint.decode(encoded(), regtest);
      final first = BlockHeaderChain(storage, params: regtest, anchor: window.anchor, clock: clock);
      await first.initialize();
      await first.bulkImportHeaders(window.headers.sublist(1, 8), windowStart + 1); // up to 48

      final reopened = BlockHeaderChain(storage, params: regtest,
          anchor: await BlockHeaderChain.chooseAnchor(storage, regtest, checkpoint: window.anchor), clock: clock);
      await reopened.initialize();
      expect(reopened.bestHeight, 48);
      expect(await reopened.extendFromWindow(window), 12);
      expect(reopened.bestHeight, 60);
    });

    test('an install that synced from genesis keeps the genesis anchor, and catches up from the window '
        'when it fell behind', () async {
      final storage = InMemoryWalletStorage();
      final fromGenesis = BlockHeaderChain(storage, params: regtest, clock: clock);
      await fromGenesis.initialize();
      await fromGenesis.acceptHeaders(chain.sublist(0, 50)); // up to 50

      final window = HeaderCheckpoint.decode(encoded(), regtest);
      final anchor = await BlockHeaderChain.chooseAnchor(storage, regtest, checkpoint: window.anchor);
      expect(anchor.height, 0);
      final reopened = BlockHeaderChain(storage, params: regtest, anchor: anchor, clock: clock);
      await reopened.initialize();
      expect(reopened.bestHeight, 50);
      expect(await reopened.extendFromWindow(window), 10);
      expect(reopened.bestHeight, 60);
    });

    test('a tip on another branch is not extended from the window', () async {
      final storage = InMemoryWalletStorage();
      final window = HeaderCheckpoint.decode(encoded(), regtest);
      final headerChain = BlockHeaderChain(storage, params: regtest, clock: clock);
      await headerChain.initialize();
      await headerChain.acceptHeaders(RegtestMiner.mineChain(genesis, 45, seed: 'elsewhere'));
      expect(await headerChain.extendFromWindow(window), 0);
      expect(headerChain.bestHeight, 45);
    });
  });

  // The window built for the next release, when it is on this machine
  // (tool/build_header_checkpoint.dart writes it; build/ is not tracked).
  final built = File('build/checkpoint/mainnet.svhc');
  test('the built mainnet window decodes', () async {
    final stopwatch = Stopwatch()..start();
    final window = await HeaderCheckpoint.load(built.readAsBytesSync(), NetworkParams.mainnet);
    expect(window.headers, hasLength(200000));
    // ignore: avoid_print
    print('decoded ${window.headers.length} mainnet headers (${window.startHeight}-${window.tipHeight}) '
        'in ${stopwatch.elapsedMilliseconds} ms');
  }, skip: built.existsSync() ? false : 'no build/checkpoint/mainnet.svhc on this machine');
}
