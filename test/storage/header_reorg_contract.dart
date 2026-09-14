/// Reorganization back onto a previously orphaned branch, driven through
/// [BlockHeaderChain] against a real [ReadModelStorage] backend (bead
/// libspiffy-0v3).
///
/// The chain reorganizes A -> B -> A. The second reorg re-stores headers of
/// A that the first one orphaned. Before the storage upsert, Isar refused
/// the duplicate hash and Postgres kept the orphan flag, so the tip was
/// right in memory but a restarted chain lost the re-activated headers.
library;

import 'package:test/test.dart';

import 'package:libspiffy/src/spv/block_header_chain.dart';
import 'package:libspiffy/src/spv/network_params.dart';
import 'package:libspiffy/src/storage/read_model_storage.dart';

import '../spv/regtest_chain_builder.dart';

Future<void> runReorgBackOntoOrphanedBranchContract(ReadModelStorage storage) async {
  final regtest = NetworkParams.regtest;
  final genesis = regtest.genesisHeader;
  DateTime clock() => DateTime.fromMillisecondsSinceEpoch(1296688602 * 1000)
      .add(const Duration(days: 365));
  BlockHeaderChain newChain() =>
      BlockHeaderChain(storage, params: regtest, clock: clock);

  final chain = newChain();
  await chain.initialize();

  final a = RegtestMiner.mineChain(genesis, 3, seed: 'A'); // heights 1..3
  for (var i = 0; i < a.length; i++) {
    expect(await chain.validateAndStoreHeader(a[i], i + 1), isTrue);
  }

  // B forks at height 1 and overtakes A at height 4.
  final b = RegtestMiner.mineChain(a[0], 3, seed: 'B'); // heights 2..4
  for (final h in b) {
    expect((await chain.acceptHeader(h)).accepted, isTrue);
  }
  expect(chain.chainTip!.blockHash(), equals(b[2].blockHash()));

  // A grows to height 5 and takes the lead back: a[1] and a[2] were
  // orphaned by the first reorg and must be re-activated.
  final aMore = RegtestMiner.mineChain(a[2], 2, seed: 'A2'); // heights 4..5
  final r4 = await chain.acceptHeader(aMore[0]);
  expect(r4.accepted, isTrue, reason: '$r4');
  final r5 = await chain.acceptHeader(aMore[1]);
  expect(r5.accepted && r5.reorganized, isTrue, reason: '$r5');
  expect(chain.chainTip!.blockHash(), equals(aMore[1].blockHash()));

  // Storage agrees with the in-memory chain.
  expect((await storage.getBlockHeaderByHeight(2))?.blockHash(), equals(a[1].blockHash()),
      reason: 'a[1] was orphaned by the first reorg and must be active again in storage');
  expect((await storage.getBlockHeaderByHeight(3))?.blockHash(), equals(a[2].blockHash()));
  expect(await storage.getBlockHeaderByHash(b[0].blockHash().toString()), isNull);
  expect(await storage.getBestHeight(), equals(5));

  // And a restarted chain sees branch A.
  final restarted = newChain();
  await restarted.initialize();
  expect(restarted.bestHeight, equals(5));
  expect(restarted.chainTip!.blockHash(), equals(aMore[1].blockHash()));
  expect((await restarted.getHeaderByHeight(2))?.blockHash(), equals(a[1].blockHash()));
  expect((await restarted.getHeaderByHeight(3))?.blockHash(), equals(a[2].blockHash()));
  final a6 = RegtestMiner.mine(parent: aMore[1]);
  expect(await restarted.validateAndStoreHeader(a6, 6), isTrue,
      reason: 'the restarted chain extends the re-activated branch');
}
