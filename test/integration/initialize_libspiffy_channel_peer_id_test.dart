/// kp1 (libspiffy-kp1): `initializeLibSpiffy()` did not forward
/// `channelPeerId` to `LibSpiffyActorSystem.initialize`, so a host that boots
/// through the free function got an empty channel peer id and its payment
/// channels could not address it (the id is the ChannelP2PAdapter's own
/// `myPeerId`, sent as `clientPeerId` in channel_request, libspiffy-36f).
library;

import 'dart:io';

import 'package:dactor/dactor.dart';
import 'package:isar/isar.dart';
import 'package:libspiffy/libspiffy.dart';
import 'package:libspiffy/src/actors/libspiffy_actor_system.dart';
import 'package:test/test.dart';

import 'isar_test_helper.dart';

void main() {
  setUpAll(() async {
    await ensureIsarInitialized();
  });

  late Directory testDir;
  late Isar isar;

  setUp(() async {
    testDir = await Directory.systemTemp.createTemp('init_channel_peer_id_');
    isar = await Isar.open(
      LibSpiffySchemas.allSchemas,
      directory: testDir.path,
      name: 'init_peer_${DateTime.now().microsecondsSinceEpoch}',
    );
  });

  tearDown(() async {
    await shutdownLibSpiffy();
    await isar.close();
    if (testDir.existsSync()) testDir.deleteSync(recursive: true);
  });

  test('kp1: initializeLibSpiffy forwards channelPeerId to the system', () async {
    await initializeLibSpiffy(
      actorSystem: LocalActorSystem(ActorSystemConfig()),
      isar: isar,
      dataDirectory: testDir.path,
      enableP2P: false,
      channelPeerId: 'peer-kp1',
    );

    // The same field the ChannelP2PAdapter is built from (myPeerId).
    expect(getLibSpiffySystem().channelPeerId, 'peer-kp1');
  });

  test('kp1: without channelPeerId the system still reports the empty default', () async {
    await initializeLibSpiffy(
      actorSystem: LocalActorSystem(ActorSystemConfig()),
      isar: isar,
      dataDirectory: testDir.path,
      enableP2P: false,
    );

    expect(getLibSpiffySystem().channelPeerId, isEmpty);
  });
}
