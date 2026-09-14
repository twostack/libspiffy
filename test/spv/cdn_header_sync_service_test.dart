import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' hide Hash;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:test/test.dart';

import 'package:libspiffy/src/spv/block_header_chain.dart';
import 'package:libspiffy/src/spv/cdn_header_sync_config.dart';
import 'package:libspiffy/src/spv/cdn_header_sync_service.dart';
import 'package:libspiffy/src/spv/cdn_manifest.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';

/// Unit tests for [CdnHeaderSyncService] that need no CDN data.
///
/// Audit finding SPV-05: the chunk filename comes from the network-supplied
/// manifest and used to be joined straight into the cache directory, so a
/// manifest naming `../../x` wrote outside the cache directory.
void main() {
  CdnChunkInfo chunkNamed(String filename) => CdnChunkInfo(
        filename: filename,
        startHeight: 0,
        endHeight: 0,
        headerCount: 1,
        sha256: '',
        sizeBytes: 80,
      );

  group('CdnHeaderSyncService.cacheFilePath (SPV-05)', () {
    late Directory tempDir;
    late CdnHeaderSyncService service;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('cdn_cache_path_');
      service = CdnHeaderSyncService(
        config: CdnHeaderSyncConfig(
          baseUrl: 'http://localhost',
          network: 'testnet',
          cacheDirectory: tempDir.path,
        ),
        headerChain: BlockHeaderChain(InMemoryWalletStorage(),
            skipProofOfWorkValidation: true),
        httpClient: http_testing.MockClient(
            (_) async => http.Response('unexpected request', 500)),
      );
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    for (final unsafe in [
      '../../x',
      '..',
      '.',
      '',
      'a/b',
      'a\\b',
      '/etc/passwd',
      'a\u0000b',
    ]) {
      test('rejects manifest filename ${jsonEncode(unsafe)} before any I/O',
          () {
        expect(
          () => service.cacheFilePath(chunkNamed(unsafe)),
          throwsA(isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('Unsafe chunk filename'),
          )),
        );
        // Nothing may have been created anywhere near the cache directory.
        expect(tempDir.listSync(), isEmpty);
        expect(tempDir.parent.listSync().where((e) => e.path.endsWith('/x')),
            isEmpty);
      });
    }

    test('accepts a plain chunk filename and resolves it under the cache directory',
        () {
      final path = service.cacheFilePath(chunkNamed('chunk_000001.bin'));
      expect(path, equals('${tempDir.path}/chunk_000001.bin'));
      expect(File(path).parent.absolute.path, equals(tempDir.absolute.path));
    });

    test('a filename with a space is a single path segment and is accepted', () {
      final path = service.cacheFilePath(chunkNamed('a b'));
      expect(path, equals('${tempDir.path}/a b'));
      expect(File(path).parent.absolute.path, equals(tempDir.absolute.path));
    });
  });

  group('CdnHeaderSyncService.synchronize (SPV-05)', () {
    late Directory root;
    late Directory cacheDir;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('cdn_traversal_');
      // Two levels deep so `../../escaped.bin` lands inside [root], where the
      // test can observe it, rather than somewhere in the system temp dir.
      cacheDir = await Directory('${root.path}/inner/cache').create(recursive: true);
    });

    tearDown(() async {
      await root.delete(recursive: true);
    });

    test('a traversal filename in the manifest never writes outside the cache directory',
        () async {
      final chunkBytes = Uint8List(80); // one all-zero 80-byte header
      final manifest = {
        'version': 1,
        'network': 'testnet',
        'generatedAt': '2026-01-01T00:00:00Z',
        'totalHeaders': 2,
        'chunkSize': 2,
        'chunks': [
          {
            'filename': '../../escaped.bin',
            // endHeight must exceed the (empty) chain's bestHeight of 0 or the
            // chunk is not considered needed at all.
            'startHeight': 0,
            'endHeight': 1,
            // Claims two headers while the served chunk holds one, so the sync
            // fails *after* the download is cached and *before* the cache file
            // is cleaned up on the old code, leaving the escaped file behind.
            'headerCount': 2,
            'sha256': sha256.convert(chunkBytes).toString(),
            'sizeBytes': chunkBytes.length,
          },
        ],
        'checkpoints': <String, String>{},
      };

      final requested = <String>[];
      final client = http_testing.MockClient((request) async {
        requested.add(request.url.path);
        if (request.url.path.endsWith('manifest.json')) {
          return http.Response(jsonEncode(manifest), 200);
        }
        return http.Response.bytes(chunkBytes, 200);
      });

      final headerChain = BlockHeaderChain(InMemoryWalletStorage(),
          skipProofOfWorkValidation: true);
      await headerChain.initialize();

      final service = CdnHeaderSyncService(
        config: CdnHeaderSyncConfig(
          baseUrl: 'http://localhost',
          network: 'testnet',
          cacheDirectory: cacheDir.path,
          maxRetries: 1,
        ),
        headerChain: headerChain,
        httpClient: client,
      );

      final result = await service.synchronize();

      // The symptom first: the network-supplied name must not have named a
      // file outside the cache directory.
      expect(File('${root.path}/escaped.bin').existsSync(), isFalse,
          reason: 'the manifest filename escaped the cache directory');
      expect(cacheDir.listSync(), isEmpty);
      expect(result.success, isFalse);
      expect(result.error, contains('Unsafe chunk filename'));
      expect(requested, equals(['/testnet/manifest.json']),
          reason: 'the chunk must be rejected before it is even downloaded');
    });
  });
}
