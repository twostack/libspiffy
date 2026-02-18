import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' hide Hash;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:logging/logging.dart';
import 'package:spiffynode/spiffy_node.dart';
import 'package:test/test.dart';

import 'package:libspiffy/src/spv/block_header_chain.dart';
import 'package:libspiffy/src/spv/cdn_header_sync_config.dart';
import 'package:libspiffy/src/spv/cdn_header_sync_service.dart';
import 'package:libspiffy/src/spv/cdn_manifest.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';

/// Integration tests for CdnHeaderSyncService using real testnet CDN data.
///
/// These tests use the pre-generated CDN data in test/cdn/testnet/ which
/// contains 1,719,437 real BSV testnet block headers.
void main() {
  // Reduce test noise
  Logger.root.level = Level.WARNING;
  Logger.root.onRecord.listen((record) {
    if (record.level >= Level.SEVERE) {
      print('${record.level.name}: ${record.message}');
    }
  });

  /// Path to the test CDN data directory.
  final cdnDir = '${Directory.current.path}/test/cdn';

  /// Creates a mock HTTP client that serves files from the local CDN directory.
  http.Client createLocalCdnClient() {
    return http_testing.MockClient((request) async {
      // Map URL path to local file
      // URL: http://localhost/testnet/manifest.json -> test/cdn/testnet/manifest.json
      final pathSegments = request.url.pathSegments;
      final relativePath = pathSegments.join('/');
      final localPath = '$cdnDir/$relativePath';
      final file = File(localPath);

      if (!file.existsSync()) {
        return http.Response('Not found: $localPath', 404);
      }

      if (localPath.endsWith('.json')) {
        return http.Response(await file.readAsString(), 200);
      } else {
        return http.Response.bytes(await file.readAsBytes(), 200);
      }
    });
  }

  group('CdnHeaderSyncService Integration - Real Testnet Data', () {
    late InMemoryWalletStorage storage;
    late BlockHeaderChain headerChain;

    setUp(() async {
      storage = InMemoryWalletStorage();
      headerChain = BlockHeaderChain(storage, skipProofOfWorkValidation: true);
      await headerChain.initialize();
    });

    test('should fetch and parse the real testnet manifest', () async {
      final client = createLocalCdnClient();

      // Verify the manifest is fetchable and parseable via the CDN client
      final response = await client.get(
          Uri.parse('http://localhost/testnet/manifest.json'));
      expect(response.statusCode, equals(200));

      final manifest = CdnManifest.fromJson(
          jsonDecode(response.body) as Map<String, dynamic>);
      expect(manifest.version, equals(1));
      expect(manifest.network, equals('testnet'));
      expect(manifest.totalHeaders, equals(1719437));
      expect(manifest.chunkSize, equals(50000));
      expect(manifest.chunks.length, equals(35));
      expect(manifest.checkpoints.length, equals(17));

      // Verify first and last chunks
      expect(manifest.chunks.first.startHeight, equals(1));
      expect(manifest.chunks.first.endHeight, equals(50000));
      expect(manifest.chunks.last.startHeight, equals(1700001));
      expect(manifest.chunks.last.endHeight, equals(1719437));
      expect(manifest.chunks.last.headerCount, equals(19437));
    });

    test('should verify SHA-256 integrity of first real chunk', () async {
      final client = createLocalCdnClient();

      // Download first chunk
      final response = await client.get(
          Uri.parse('http://localhost/testnet/headers_0000001_0050000.bin'));
      expect(response.statusCode, equals(200));
      expect(response.bodyBytes.length, equals(4000000)); // 50000 * 80

      // Verify SHA-256 matches manifest
      final digest = sha256.convert(response.bodyBytes).toString();
      expect(digest,
          equals('fd20ca4ceb4a58cc9544918cfa99e888c0ae0e737742bb5a4e4ce38b5127a415'));
    });

    test('should parse real binary headers from first chunk', () async {
      final client = createLocalCdnClient();

      final response = await client.get(
          Uri.parse('http://localhost/testnet/headers_0000001_0050000.bin'));
      final data = response.bodyBytes;

      // Parse first 10 headers
      final headers = <BlockHeader>[];
      for (var i = 0; i < 10; i++) {
        final offset = i * 80;
        final headerBytes = Uint8List.sublistView(data, offset, offset + 80);
        headers.add(BlockHeader.deserialize(headerBytes));
      }

      // Verify chain continuity of first 10 headers
      for (var i = 1; i < headers.length; i++) {
        final prevHash = headers[i - 1].blockHash().toString();
        final headerPrevHash = headers[i].prevBlock.toString();
        expect(prevHash, equals(headerPrevHash),
            reason: 'Chain break at header index $i');
      }

      // Verify first header is block 1 (its version and timestamp should be reasonable)
      expect(headers[0].version, greaterThan(0));
      expect(headers[0].timestamp.year, greaterThanOrEqualTo(2011));
    });

    test('should sync first chunk and update chain state', () async {
      final client = createLocalCdnClient();

      // Create a manifest with just the first chunk for a fast test
      final fullManifestResponse = await client.get(
          Uri.parse('http://localhost/testnet/manifest.json'));
      final fullManifest = CdnManifest.fromJson(
          jsonDecode(fullManifestResponse.body) as Map<String, dynamic>);

      final singleChunkManifest = CdnManifest(
        version: fullManifest.version,
        network: fullManifest.network,
        generatedAt: fullManifest.generatedAt,
        totalHeaders: fullManifest.chunks.first.headerCount,
        chunkSize: fullManifest.chunkSize,
        chunks: [fullManifest.chunks.first],
        checkpoints: {},
      );

      // Create a mock client that serves our single-chunk manifest
      final singleChunkClient = http_testing.MockClient((request) async {
        final path = request.url.pathSegments.join('/');
        if (path.endsWith('manifest.json')) {
          return http.Response(
              jsonEncode(singleChunkManifest.toJson()), 200);
        }
        // Delegate to the real file client for binary data
        final localPath = '$cdnDir/$path';
        final file = File(localPath);
        if (!file.existsSync()) {
          return http.Response('Not found', 404);
        }
        return http.Response.bytes(await file.readAsBytes(), 200);
      });

      final config = CdnHeaderSyncConfig(
        baseUrl: 'http://localhost',
        network: 'testnet',
        verifyCheckpoints: false, // No checkpoints in single-chunk manifest
      );

      final service = CdnHeaderSyncService(
        config: config,
        headerChain: headerChain,
        httpClient: singleChunkClient,
      );

      final result = await service.synchronize();

      expect(result.success, isTrue);
      expect(result.headersImported, equals(50000));
      expect(result.finalHeight, equals(50000));
      expect(result.error, isNull);
      expect(headerChain.bestHeight, equals(50000));
      expect(headerChain.chainTip, isNotNull);
    }, timeout: Timeout(Duration(minutes: 2)));

    test('should report progress during sync', () async {
      final client = createLocalCdnClient();

      // Use first chunk only
      final fullManifestResponse = await client.get(
          Uri.parse('http://localhost/testnet/manifest.json'));
      final fullManifest = CdnManifest.fromJson(
          jsonDecode(fullManifestResponse.body) as Map<String, dynamic>);

      final singleChunkManifest = CdnManifest(
        version: 1,
        network: 'testnet',
        generatedAt: fullManifest.generatedAt,
        totalHeaders: 50000,
        chunkSize: 50000,
        chunks: [fullManifest.chunks.first],
        checkpoints: {},
      );

      final singleChunkClient = http_testing.MockClient((request) async {
        final path = request.url.pathSegments.join('/');
        if (path.endsWith('manifest.json')) {
          return http.Response(jsonEncode(singleChunkManifest.toJson()), 200);
        }
        final localPath = '$cdnDir/$path';
        final file = File(localPath);
        if (!file.existsSync()) return http.Response('Not found', 404);
        return http.Response.bytes(await file.readAsBytes(), 200);
      });

      final phases = <CdnSyncPhase>[];
      final config = CdnHeaderSyncConfig(
        baseUrl: 'http://localhost',
        network: 'testnet',
        verifyCheckpoints: false,
        onProgress: (current, total, phase) {
          if (!phases.contains(phase)) phases.add(phase);
        },
      );

      final service = CdnHeaderSyncService(
        config: config,
        headerChain: headerChain,
        httpClient: singleChunkClient,
      );

      await service.synchronize();

      // Verify all phases were reported
      expect(phases, contains(CdnSyncPhase.fetchingManifest));
      expect(phases, contains(CdnSyncPhase.downloadingChunks));
      expect(phases, contains(CdnSyncPhase.validatingChunks));
      expect(phases, contains(CdnSyncPhase.importingHeaders));
      expect(phases, contains(CdnSyncPhase.complete));
    }, timeout: Timeout(Duration(minutes: 2)));

    test('should skip chunks when already partially synced', () async {
      final client = createLocalCdnClient();

      // First, sync chunk 1 (heights 1-50000)
      final fullManifestResponse = await client.get(
          Uri.parse('http://localhost/testnet/manifest.json'));
      final fullManifest = CdnManifest.fromJson(
          jsonDecode(fullManifestResponse.body) as Map<String, dynamic>);

      // Import first chunk directly
      final chunk1Response = await client.get(
          Uri.parse('http://localhost/testnet/headers_0000001_0050000.bin'));
      final chunk1Data = chunk1Response.bodyBytes;
      final chunk1Headers = <BlockHeader>[];
      for (var i = 0; i < 50000; i++) {
        final offset = i * 80;
        chunk1Headers.add(BlockHeader.deserialize(
            Uint8List.sublistView(chunk1Data, offset, offset + 80)));
      }
      await headerChain.bulkImportHeaders(chunk1Headers, 1);
      expect(headerChain.bestHeight, equals(50000));

      // Now create a 2-chunk manifest and sync - should skip chunk 1
      final twoChunkManifest = CdnManifest(
        version: 1,
        network: 'testnet',
        generatedAt: fullManifest.generatedAt,
        totalHeaders: 100000,
        chunkSize: 50000,
        chunks: [fullManifest.chunks[0], fullManifest.chunks[1]],
        checkpoints: {},
      );

      var chunk1Downloaded = false;
      final smartClient = http_testing.MockClient((request) async {
        final path = request.url.pathSegments.join('/');
        if (path.endsWith('manifest.json')) {
          return http.Response(jsonEncode(twoChunkManifest.toJson()), 200);
        }
        if (path.contains('headers_0000001_0050000')) {
          chunk1Downloaded = true;
        }
        final localPath = '$cdnDir/$path';
        final file = File(localPath);
        if (!file.existsSync()) return http.Response('Not found', 404);
        return http.Response.bytes(await file.readAsBytes(), 200);
      });

      final config = CdnHeaderSyncConfig(
        baseUrl: 'http://localhost',
        network: 'testnet',
        verifyCheckpoints: false,
      );

      final service = CdnHeaderSyncService(
        config: config,
        headerChain: headerChain,
        httpClient: smartClient,
      );

      final result = await service.synchronize();
      expect(result.success, isTrue);
      expect(result.headersImported, equals(50000)); // Only chunk 2
      expect(headerChain.bestHeight, equals(100000));
      expect(chunk1Downloaded, isFalse, reason: 'Should not re-download chunk 1');
    }, timeout: Timeout(Duration(minutes: 3)));

    test('should gracefully handle CDN failure', () async {
      // Client that always returns 500
      final failClient = http_testing.MockClient((request) async {
        return http.Response('Internal Server Error', 500);
      });

      final config = CdnHeaderSyncConfig(
        baseUrl: 'http://localhost',
        network: 'testnet',
        maxRetries: 1, // Skip retries for faster test
      );

      final service = CdnHeaderSyncService(
        config: config,
        headerChain: headerChain,
        httpClient: failClient,
      );

      final result = await service.synchronize();

      expect(result.success, isFalse);
      expect(result.error, isNotNull);
      expect(result.headersImported, equals(0));
      expect(headerChain.bestHeight, equals(0)); // Unchanged
    });

    test('should detect chunk with wrong SHA-256', () async {
      final client = createLocalCdnClient();

      final fullManifestResponse = await client.get(
          Uri.parse('http://localhost/testnet/manifest.json'));
      final fullManifest = CdnManifest.fromJson(
          jsonDecode(fullManifestResponse.body) as Map<String, dynamic>);

      // Create manifest with wrong SHA-256 for first chunk
      final badChunk = CdnChunkInfo(
        filename: fullManifest.chunks.first.filename,
        startHeight: fullManifest.chunks.first.startHeight,
        endHeight: fullManifest.chunks.first.endHeight,
        headerCount: fullManifest.chunks.first.headerCount,
        sha256: 'badhash_0000000000000000000000000000000000000000000000000000000',
        sizeBytes: fullManifest.chunks.first.sizeBytes,
      );

      final badManifest = CdnManifest(
        version: 1,
        network: 'testnet',
        generatedAt: fullManifest.generatedAt,
        totalHeaders: 50000,
        chunkSize: 50000,
        chunks: [badChunk],
        checkpoints: {},
      );

      final badClient = http_testing.MockClient((request) async {
        final path = request.url.pathSegments.join('/');
        if (path.endsWith('manifest.json')) {
          return http.Response(jsonEncode(badManifest.toJson()), 200);
        }
        final localPath = '$cdnDir/$path';
        final file = File(localPath);
        if (!file.existsSync()) return http.Response('Not found', 404);
        return http.Response.bytes(await file.readAsBytes(), 200);
      });

      final config = CdnHeaderSyncConfig(
        baseUrl: 'http://localhost',
        network: 'testnet',
        verifyCheckpoints: false,
        maxRetries: 1, // Skip retries for faster test
      );

      final service = CdnHeaderSyncService(
        config: config,
        headerChain: headerChain,
        httpClient: badClient,
      );

      final result = await service.synchronize();

      expect(result.success, isFalse);
      expect(result.error, contains('integrity'));
      expect(headerChain.bestHeight, equals(0)); // No import happened
    });

    test('should return success with 0 imports when already fully synced', () async {
      // Pretend we're already at height 2000000
      // We need to set up headerChain with a high bestHeight.
      // Since we can't easily fake bestHeight, we'll use a manifest
      // where all chunk endHeights are below currentHeight.

      // Import one chunk to get bestHeight > 0
      final client = createLocalCdnClient();
      final chunk1Response = await client.get(
          Uri.parse('http://localhost/testnet/headers_0000001_0050000.bin'));
      final chunk1Data = chunk1Response.bodyBytes;
      final chunk1Headers = <BlockHeader>[];
      for (var i = 0; i < 50000; i++) {
        final offset = i * 80;
        chunk1Headers.add(BlockHeader.deserialize(
            Uint8List.sublistView(chunk1Data, offset, offset + 80)));
      }
      await headerChain.bulkImportHeaders(chunk1Headers, 1);

      // Create manifest with only chunks that are below our height
      final smallManifest = CdnManifest(
        version: 1,
        network: 'testnet',
        generatedAt: DateTime.now(),
        totalHeaders: 40000,
        chunkSize: 50000,
        chunks: [
          CdnChunkInfo(
            filename: 'headers_0000001_0040000.bin',
            startHeight: 1,
            endHeight: 40000,
            headerCount: 40000,
            sha256: 'doesntmatter',
            sizeBytes: 3200000,
          ),
        ],
        checkpoints: {},
      );

      final smartClient = http_testing.MockClient((request) async {
        final path = request.url.pathSegments.join('/');
        if (path.endsWith('manifest.json')) {
          return http.Response(jsonEncode(smallManifest.toJson()), 200);
        }
        return http.Response('Should not be called', 500);
      });

      final config = CdnHeaderSyncConfig(
        baseUrl: 'http://localhost',
        network: 'testnet',
        verifyCheckpoints: false,
      );

      final service = CdnHeaderSyncService(
        config: config,
        headerChain: headerChain,
        httpClient: smartClient,
      );

      final result = await service.synchronize();
      expect(result.success, isTrue);
      expect(result.headersImported, equals(0));
    }, timeout: Timeout(Duration(minutes: 2)));
  });
}
