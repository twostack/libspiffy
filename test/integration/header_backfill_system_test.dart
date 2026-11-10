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
      ..useCertificateChainBytes(utf8.encode(_certPem))
      ..usePrivateKeyBytes(utf8.encode(_keyPem));
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

// A self-signed certificate for 127.0.0.1 made for this test only.
const _certPem = '''
-----BEGIN CERTIFICATE-----
MIIC+zCCAeOgAwIBAgIUK9M9CCVGuL/0mnyp+bZQZ+gS5ZEwDQYJKoZIhvcNAQEL
BQAwFDESMBAGA1UEAwwJMTI3LjAuMC4xMCAXDTI2MTExMDA5MDA1MFoYDzIxMjYx
MDE3MDkwMDUwWjAUMRIwEAYDVQQDDAkxMjcuMC4wLjEwggEiMA0GCSqGSIb3DQEB
AQUAA4IBDwAwggEKAoIBAQCbZnNxULpnVbfKWGvCDtZuqO4G3z4A5TVcvCyHCJnl
2yOn0MPlZyKTFax9RcdF6X/pAc+nvFrjjuirbQd0RTBpavQRLnFTbS8n14b6LW8T
phnqSp46vjqidTM4dVWexi8wXv77f5u3Eh3HuOvNj9guQFPuPLmt6Fu9mKVX+n7s
UQ8tGVcCihsDgHw8xQW//h+y946z4WbtDe+fDL8r7YXX+P73G0vTzjK7XRUX5Gwi
7ygBL9zxmy39A6KH+S+vetB4BVW+SkhN/WfJ9/BEc8xaOOCPxasEdKcaBWwX//vU
QVerbaqdiJju4A33J5hFBM4xugJnvn6/y526E9TOJfzlAgMBAAGjQzBBMB0GA1Ud
DgQWBBQYtUErAVJfkurYRcxTWCifyvCXATAPBgNVHRMBAf8EBTADAQH/MA8GA1Ud
EQQIMAaHBH8AAAEwDQYJKoZIhvcNAQELBQADggEBAAWjp9dVx6/C4IH8D1LqL6gW
fCCTivKPF38NBeGq4J/PMBrZi1XSW9orDTcHDNpHcLFxxOUfAZHxTpQTnVJSwfTO
8KmMwQU915vqI5EcWT/M94KSWvmqg00frbi4DqmuFrwKr6p/1xGiIJg57wNN94nS
lTZimPqrg3Pj0GaPtlYx8qRfi4bCWCBxMCF25aw9754b747Mv3fmFYZ8Xau5xjqm
mBRaxJxVTATF5OdxBpxN8TBbVbhy7anSQfP7D6p0bDVJa15HVLgQsvyEXxepCc2H
+3X7CU2iORH41stWR1OS1HRO1x2WbWgKvpJ20aFYRVNryW5QFHfrw8uSFlh9KBE=
-----END CERTIFICATE-----
''';

const _keyPem = '''
-----BEGIN PRIVATE KEY-----
MIIEvAIBADANBgkqhkiG9w0BAQEFAASCBKYwggSiAgEAAoIBAQCbZnNxULpnVbfK
WGvCDtZuqO4G3z4A5TVcvCyHCJnl2yOn0MPlZyKTFax9RcdF6X/pAc+nvFrjjuir
bQd0RTBpavQRLnFTbS8n14b6LW8TphnqSp46vjqidTM4dVWexi8wXv77f5u3Eh3H
uOvNj9guQFPuPLmt6Fu9mKVX+n7sUQ8tGVcCihsDgHw8xQW//h+y946z4WbtDe+f
DL8r7YXX+P73G0vTzjK7XRUX5Gwi7ygBL9zxmy39A6KH+S+vetB4BVW+SkhN/WfJ
9/BEc8xaOOCPxasEdKcaBWwX//vUQVerbaqdiJju4A33J5hFBM4xugJnvn6/y526
E9TOJfzlAgMBAAECggEABBHqAvlydbBQmd3JtpOktPPY9SVRc9ZZw3eCEl+0MgUd
Kz/4UPHBQeT8MOQjhurrwUKdcyzjRwn+CfLOo3jEB1OUE5SWpIHzQKcuHi81tU5m
eOPGrXT77Wq4/QB0XvrhefqtFc0ZfSzd/c2tW99DR1sYJpQWG2ScsbElzdn5xvQs
4pDSni4LoCpnRv7vrMVjbpJyFrCGLowI4Q4MNm0XLMYws59mMfZzZUNKqj3U7mk6
1WJJBNzZ3MDMuZjft6wLIkJwO9lsNwZEAWksKx8qF+Wu0UIVyhTlyfC3ZDOiR7gG
pKmI62UjS1ARTJuvpSb9hrhStYbyLs09syIULqJmgwKBgQDKZ+zRJqkFiqO1rIDL
w2btuDlVdLkWyLohawSr2pdJbbTOmTG+zk2PluX9O7gx3D3JvlU5W/K8z9S+Uv55
ztmm5o3yqp2bxbBDZx5CwnCrvi1IjoEGMZcw2gSgwHWRtC4XlPrJ4HdLsHRDova4
jWfmVp5wFRMwd8FLy4ec+EDRrwKBgQDEjD5ZLJpQI8UenBtR6yu5jLDzUlNrsEds
JBf+ho/SQL/KTIvrRJMc4PVchvDlcLF9pkMqV1vmv4Bkr+p9t4pge8eVhmZFrxUS
0LHrHHaiVTvszG4dSMmGguJ0A5UUy7J4SbBVfGduMpl1C6nE4UtH8IIBifgspY/B
l3qtG4EjqwKBgD3RX9LBK/41SarC9NNG6rjP+zLOY3lB9RcfyF10daBHkWFICJlu
COJCBBxDkQ4pZfWn2/+YxZpFH4TBdFdfhboj0Fa9JUXeKudrJyLcn+zUOKBgZaeu
na6d56vxG/dUQH+TUMU3eTf0vI2ryA61oXYIHnu89A9pg+/SSaj3aVShAoGAN+br
lNFq0oBaAGrGGnaY6R1q9snjkC2DIu7hJDOBlHt2EUPUSAYpEX2qS7bVrWxwDxzK
3bAbI3Y0Pm8KctdRNEAAdDbVv9wcUk2pTQW7eFBlyuQaLZoWN3vijLy4GkIVcMEE
tku730vk+bVng+fQUZXGZEmpnIk6agV7juDTyiECgYAPXscRmgWhjgSn8cjkKJE3
2QQChCmuLqAtHKrtf5RqKEXQeE/MmSnY9HCQoP0KmTP/niv/iuadcJxAxLOhIUjb
1ex/pkoLuzOfrFFt7z/c9oVhwC/pOvk4lwH9R7Pe1FN7GlWemnwgtqzy4n6lU8d/
vmM6jV5SvBLPNtCmgQZUOg==
-----END PRIVATE KEY-----
''';
