/// Regression test for the default ARC endpoint (audit finding A-M9).
///
/// LibSpiffyActorSystem.initialize defaults networkType to 'test', but the
/// ARC configuration used to fall back to TAAL *mainnet* whenever no
/// explicit config was given. The default must follow networkType.
import 'dart:io';

import 'package:dactor/dactor.dart';
import 'package:isar_community/isar.dart';
import 'package:test/test.dart';

import 'package:libspiffy/libspiffy.dart';

import '../integration/isar_test_helper.dart';

const _arcadeTestnet = 'https://arcade-v2-testnet-us-1.bsvblockchain.tech';
// Both networks default to the BSV Association's Arcade, which needs no API key.
const _arcadeMainnet = 'https://arcade-v2-us-1.bsvblockchain.tech';

void main() {
  setUpAll(() async {
    await ensureIsarInitialized();
  });

  Future<String> resolvedArcBaseUrl(String networkType) async {
    final testDir = await Directory.systemTemp.createTemp('arc_config_');
    final isar = await Isar.open(
      LibSpiffySchemas.allSchemas,
      directory: testDir.path,
      name: 'test_${DateTime.now().microsecondsSinceEpoch}',
    );
    final libspiffy = LibSpiffyActorSystem();
    try {
      await libspiffy.initialize(
        actorSystem: LocalActorSystem(ActorSystemConfig()),
        isar: isar,
        dataDirectory: testDir.path,
        enableP2P: false,
        networkType: networkType,
        secureStorage: InMemorySecureStorage(),
      );
      // ARCActor falls back to TAAL mainnet when it is handed no config
      // (see ARCActor.preStart), so a null here means mainnet in practice.
      final config = libspiffy.arcConfig ?? ArcServiceConfig.taalMainnet();
      return config.baseUrl;
    } finally {
      await libspiffy.shutdown();
      if (await testDir.exists()) {
        await testDir.delete(recursive: true);
      }
    }
  }

  test("networkType 'test' defaults to the testnet Arcade", () async {
    expect(await resolvedArcBaseUrl('test'), equals(_arcadeTestnet));
  });

  test("networkType 'main' defaults to the mainnet Arcade", () async {
    expect(await resolvedArcBaseUrl('main'), equals(_arcadeMainnet));
  });

  test("networkType 'mainnet' is treated like 'main'", () async {
    expect(await resolvedArcBaseUrl('mainnet'), equals(_arcadeMainnet));
  });

  test('an explicit arcConfig is used as given', () async {
    final testDir = await Directory.systemTemp.createTemp('arc_config_');
    final isar = await Isar.open(
      LibSpiffySchemas.allSchemas,
      directory: testDir.path,
      name: 'test_${DateTime.now().microsecondsSinceEpoch}',
    );
    final libspiffy = LibSpiffyActorSystem();
    try {
      await libspiffy.initialize(
        actorSystem: LocalActorSystem(ActorSystemConfig()),
        isar: isar,
        dataDirectory: testDir.path,
        enableP2P: false,
        networkType: 'test',
        arcConfig: const ArcServiceConfig(baseUrl: 'https://arc.example/v1'),
        secureStorage: InMemorySecureStorage(),
      );
      expect(libspiffy.arcConfig?.baseUrl, equals('https://arc.example/v1'));
    } finally {
      await libspiffy.shutdown();
      if (await testDir.exists()) {
        await testDir.delete(recursive: true);
      }
    }
  });
}
