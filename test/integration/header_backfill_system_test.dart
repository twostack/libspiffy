/// spiffyvault-emk.3 through LibSpiffyActorSystem: a fresh install started
/// at a built-in checkpoint fills in the headers below it from the header
/// CDN in the background, down to genesis, only while the app allows it.
///
/// The CDN is a local HTTPS server (the CDN client takes https only) with
/// a self-signed certificate made for this test, trusted through
/// HttpOverrides for 127.0.0.1 alone.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dactor/dactor.dart';
import 'package:isar_community/isar.dart';
import 'package:libspiffy/libspiffy.dart';
import 'package:libspiffy/src/actors/libspiffy_actor_system.dart';
import 'package:libspiffy/src/spv/header_checkpoint.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';
import 'package:libspiffy/src/storage/in_memory_secure_storage.dart';
import 'package:test/test.dart';

import '../spv/regtest_chain_builder.dart';
import 'isar_test_helper.dart';

const _chunkSize = 50;
const _checkpoint = 175;

void main() {
  final regtest = NetworkParams.regtest;
  final chain = [regtest.genesisHeader, ...RegtestMiner.mineChain(regtest.genesisHeader, 249, seed: 'emk3-sys')];

  late HttpServer cdn;
  late Directory dir;
  final served = <String>[];
  HttpOverrides? before;

  Uint8List chunk(int start) {
    final out = BytesBuilder();
    for (var h = start; h < start + _chunkSize; h++) {
      out.add(chain[h].serialize());
    }
    return out.toBytes();
  }

  setUpAll(() async {
    await ensureIsarInitialized();
  });

  setUp(() async {
    served.clear();
    dir = await Directory.systemTemp.createTemp('emk3_system_');
    final context = SecurityContext()
      // A self-signed certificate for 127.0.0.1 made for this test only.
      // It lives under test/data/, which is not published (.pubignore).
      ..useCertificateChain('test/data/loopback_tls/cert.pem')
      ..usePrivateKey('test/data/loopback_tls/key.pem');
    cdn = await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, context);
    cdn.listen((request) async {
      final name = request.uri.pathSegments.last;
      served.add(name);
      if (name == 'manifest.json') {
        request.response.write(jsonEncode({
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
                'sha256': sha256.convert(chunk(start)).toString(),
                'sizeBytes': _chunkSize * 80,
              },
          ],
          'checkpoints': <String, String>{},
        }));
      } else {
        request.response.add(chunk(int.parse(name.substring(1, name.length - 4))));
      }
      await request.response.close();
    });
    before = HttpOverrides.current;
    HttpOverrides.global = _TrustLoopback();
  });

  tearDown(() async {
    HttpOverrides.global = before;
    await cdn.close(force: true);
    await dir.delete(recursive: true);
  });

  Future<(LibSpiffyActorSystem, InMemoryWalletStorage, Isar)> start({
    required Future<bool> Function() mayBackfill,
    required void Function(int, int) onProgress,
  }) async {
    final isar = await Isar.open(LibSpiffySchemas.allSchemas,
        directory: dir.path, name: 'emk3_${DateTime.now().microsecondsSinceEpoch}');
    final storage = InMemoryWalletStorage();
    final system = LibSpiffyActorSystem();
    await system.initialize(
      actorSystem: LocalActorSystem(ActorSystemConfig()),
      isar: isar,
      readModelStorage: storage,
      secureStorage: InMemorySecureStorage(),
      dataDirectory: dir.path,
      networkType: 'regtest',
      enableP2P: false,
      cdnBaseUrl: 'https://127.0.0.1:${cdn.port}',
      headerCheckpoint: HeaderCheckpoint.encode('regtest', _checkpoint, chain.sublist(_checkpoint)),
      mayBackfillHeaders: mayBackfill,
      onHeaderBackfillProgress: onProgress,
    );
    return (system, storage, isar);
  }

  test('a fresh install fills in every header below its checkpoint, newest first', () async {
    final progress = <int>[];
    final done = Completer<void>();
    final (system, storage, isar) = await start(
      mayBackfill: () async => true,
      onProgress: (lowest, checkpoint) {
        expect(checkpoint, _checkpoint);
        progress.add(lowest);
        if (lowest == 0 && !done.isCompleted) done.complete();
      },
    );
    try {
      await done.future.timeout(const Duration(seconds: 30));
      expect(progress, [_checkpoint, 150, 100, 50, 0]);
      expect([for (final n in served) if (n != 'manifest.json') n], ['h150.bin', 'h100.bin', 'h50.bin', 'h0.bin']);
      expect((await storage.getBlockHeaderByHeight(0))?.blockHash().toString(), regtest.genesisHash);
      expect(await storage.getBestHeight(), 249);
    } finally {
      await system.shutdown();
      await isar.close();
    }
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('nothing is downloaded while the app says no, and shutdown ends the wait', () async {
    var asked = 0;
    final firstAsk = Completer<void>();
    final (system, storage, isar) = await start(
      mayBackfill: () async {
        asked++;
        if (!firstAsk.isCompleted) firstAsk.complete();
        return false;
      },
      onProgress: (_, __) {},
    );
    try {
      await firstAsk.future.timeout(const Duration(seconds: 30));
      expect([for (final n in served) if (n != 'manifest.json') n], isEmpty);
      expect(await storage.getBlockHeaderByHeight(_checkpoint - 1), isNull);
    } finally {
      final stopwatch = Stopwatch()..start();
      await system.shutdown();
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 15)),
          reason: 'shutdown does not wait out the five-minute wait');
      await isar.close();
    }
    expect(asked, 1);
  }, timeout: const Timeout(Duration(seconds: 60)));
}

class _TrustLoopback extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) => super.createHttpClient(context)
    ..badCertificateCallback = (cert, host, port) => host == '127.0.0.1';
}
