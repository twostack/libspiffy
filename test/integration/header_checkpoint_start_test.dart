/// A fresh install given a built-in header window starts its chain at the
/// window's checkpoint and holds the whole window, through
/// LibSpiffyActorSystem (epic spiffyvault-emk, step emk.1).
library;

import 'dart:io';

import 'package:dactor/dactor.dart';
import 'package:isar_community/isar.dart';
import 'package:libspiffy/libspiffy.dart';
import 'package:libspiffy/src/spv/header_checkpoint.dart';
import 'package:libspiffy/src/spv/network_params.dart';
import 'package:test/test.dart';

import '../spv/regtest_chain_builder.dart';
import 'isar_test_helper.dart';

void main() {
  final regtest = NetworkParams.regtest;
  final chain = RegtestMiner.mineChain(regtest.genesisHeader, 40, seed: 'emk1-start');
  final window = HeaderCheckpoint.encode('regtest', 21, chain.sublist(20)); // heights 21..40

  late Directory dir;
  late Isar isar;

  setUpAll(ensureIsarInitialized);

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('emk1_start_');
    isar = await Isar.open(LibSpiffySchemas.allSchemas, directory: dir.path,
        name: 'emk1_${DateTime.now().microsecondsSinceEpoch}');
  });

  tearDown(() async {
    try {
      await isar.close(deleteFromDisk: true);
    } catch (_) {}
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  });

  Future<LibSpiffyActorSystem> boot(InMemoryWalletStorage readModel) async {
    final system = LibSpiffyActorSystem();
    await system.initialize(
      actorSystem: LocalActorSystem(ActorSystemConfig()),
      isar: isar,
      readModelStorage: readModel,
      secureStorage: InMemorySecureStorage(),
      dataDirectory: dir.path,
      networkType: 'regtest',
      enableP2P: false,
      headerCheckpoint: window,
    );
    return system;
  }

  test('the chain starts at the checkpoint, holds the window, and a restart keeps it', () async {
    final readModel = InMemoryWalletStorage();
    final first = await boot(readModel);
    expect(first.headerChain.anchor.height, 21);
    expect(first.headerChain.bestHeight, 40);
    expect(await readModel.getBlockHeaderByHeight(20), isNull);
    await first.shutdown();

    final second = await boot(readModel);
    expect(second.headerChain.anchor.height, 21);
    expect(second.headerChain.bestHeight, 40);
    await second.shutdown();
  });
}
