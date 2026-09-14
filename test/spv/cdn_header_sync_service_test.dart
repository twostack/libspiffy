import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' hide Hash;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:spiffynode/spiffy_node.dart';
import 'package:test/test.dart';

import 'package:libspiffy/src/spv/block_header_chain.dart';
import 'package:libspiffy/src/spv/cdn_header_sync_config.dart';
import 'package:libspiffy/src/spv/cdn_header_sync_service.dart';
import 'package:libspiffy/src/spv/cdn_manifest.dart';
import 'package:libspiffy/src/spv/network_params.dart';
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
          allowInsecureHttp: true,
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
          allowInsecureHttp: true,
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

  _spv04Tests();
}

// ---------------------------------------------------------------------------
// SPV-04: CDN header sync must be anchored to the in-code genesis, validate
// proof of work by default and refuse plaintext transport.
// ---------------------------------------------------------------------------

/// Builds a header on top of [prevBlock] and searches nonces until its hash is
/// at or below its own target ([valid] true) or strictly above it ([valid]
/// false). At regtest difficulty either search ends within a few nonces.
BlockHeader _mineHeader({
  required Hash prevBlock,
  required DateTime timestamp,
  required int bits,
  bool valid = true,
}) {
  final target = NetworkParams.bitsToTarget(bits);
  for (var nonce = 0; nonce < 1 << 24; nonce++) {
    final header = BlockHeader(
      version: 1,
      prevBlock: prevBlock,
      merkleRoot: Hash.zero(),
      timestamp: timestamp,
      bits: bits,
      nonce: nonce,
    );
    final meets =
        NetworkParams.hashToBigInt(header.blockHash().toString()) <= target;
    if (meets == valid) return header;
  }
  throw StateError('no nonce found for bits 0x${bits.toRadixString(16)}');
}

BlockHeader _mineOn(BlockHeader parent, {required int bits, bool valid = true}) =>
    _mineHeader(
      prevBlock: parent.blockHash(),
      timestamp: parent.timestamp.add(const Duration(minutes: 10)),
      bits: bits,
      valid: valid,
    );

/// [count] PoW-valid headers starting with [genesis].
List<BlockHeader> _mineChain(BlockHeader genesis, int count, {required int bits}) {
  final out = [genesis];
  while (out.length < count) {
    out.add(_mineOn(out.last, bits: bits));
  }
  return out;
}

Uint8List _chunkBytes(List<BlockHeader> headers) {
  final buffer = BytesBuilder(copy: false);
  for (final h in headers) {
    buffer.add(h.serialize());
  }
  return buffer.toBytes();
}

/// An in-memory CDN: a manifest plus the chunk files it names.
class _FakeCdn {
  final String network;
  final Map<String, dynamic> manifest;
  final Map<String, Uint8List> files;
  final List<String> requested = [];

  _FakeCdn(this.network, this.manifest, this.files);

  http.Client get client => http_testing.MockClient((request) async {
        requested.add(request.url.path);
        if (request.url.path == '/$network/manifest.json') {
          return http.Response(jsonEncode(manifest), 200);
        }
        final bytes = files[request.url.pathSegments.last];
        if (bytes == null) return http.Response('not found', 404);
        return http.Response.bytes(bytes, 200);
      });
}

/// Serves [chunks] as `(startHeight, headers)` pairs, with correct sizes and
/// SHA-256 digests so the only thing that can be wrong is the chain itself.
_FakeCdn _serve({
  required String network,
  required List<(int, List<BlockHeader>)> chunks,
  Map<int, String> checkpoints = const {},
}) {
  final files = <String, Uint8List>{};
  final chunkJson = <Map<String, dynamic>>[];
  var total = 0;
  for (var i = 0; i < chunks.length; i++) {
    final (start, headers) = chunks[i];
    final bytes = _chunkBytes(headers);
    final name = 'chunk_$i.bin';
    files[name] = bytes;
    total += headers.length;
    chunkJson.add({
      'filename': name,
      'startHeight': start,
      'endHeight': start + headers.length - 1,
      'headerCount': headers.length,
      'sha256': sha256.convert(bytes).toString(),
      'sizeBytes': bytes.length,
    });
  }
  return _FakeCdn(network, {
    'version': 1,
    'network': network,
    'generatedAt': '2026-01-01T00:00:00Z',
    'totalHeaders': total,
    'chunkSize': chunks.map((c) => c.$2.length).fold(0, (a, b) => a > b ? a : b),
    'chunks': chunkJson,
    'checkpoints': checkpoints.map((k, v) => MapEntry('$k', v)),
  }, files);
}

Future<BlockHeaderChain> _emptyChain() async {
  final chain =
      BlockHeaderChain(InMemoryWalletStorage(), skipProofOfWorkValidation: true);
  await chain.initialize();
  return chain;
}

/// A service on the library defaults: nothing about PoW or transport is
/// passed explicitly, so these tests exercise the defaults a caller gets.
CdnHeaderSyncService _service(_FakeCdn cdn, BlockHeaderChain chain) =>
    CdnHeaderSyncService(
      config: CdnHeaderSyncConfig(
        baseUrl: 'https://cdn.example.test',
        network: cdn.network,
        maxRetries: 1,
      ),
      headerChain: chain,
      httpClient: cdn.client,
    );

Future<void> _expectNothingWritten(BlockHeaderChain chain) async {
  expect(chain.chainTip, isNull, reason: 'a rejected chunk must not become the tip');
  expect(chain.bestHeight, equals(0));
  expect(await chain.getHeaderByHeight(0), isNull,
      reason: 'a rejected chunk must write nothing');
  expect(await chain.getHeaderByHeight(1), isNull,
      reason: 'a rejected chunk must write nothing');
}

void _spv04Tests() {
  final regtest = NetworkParams.regtest;
  final regBits = regtest.powLimitBits; // 0x207fffff: mineable in microseconds
  final genesis = regtest.genesisHeader;

  group('CdnHeaderSyncService anchoring and proof of work (SPV-04)', () {
    test('an empty database imports the genesis chunk and ends with the tip at n-1',
        () async {
      const n = 10;
      final chain = await _emptyChain();
      final headers = _mineChain(genesis, n, bits: regBits);
      final cdn = _serve(network: 'regtest', chunks: [(0, headers)]);

      final result = await _service(cdn, chain).synchronize();

      expect(result.success, isTrue, reason: result.error);
      expect(result.headersImported, equals(n),
          reason: 'the genesis header (height 0) must be imported too');
      expect(chain.bestHeight, equals(n - 1));
      final stored0 = await chain.getHeaderByHeight(0);
      expect(stored0, isNotNull, reason: 'height 0 must hold the genesis block');
      expect(stored0!.blockHash().toString(), equals(regtest.genesisHash));
      expect(chain.chainTip!.blockHash().toString(),
          equals(headers.last.blockHash().toString()));
    });

    test('the first chunk on an empty database must start at height 0; nothing is written otherwise',
        () async {
      final chain = await _emptyChain();
      // A perfectly valid-looking chain, PoW and all, but labelled as
      // heights 5..9 so nothing ties it to the genesis block.
      final headers = _mineChain(genesis, 5, bits: regBits);
      final cdn = _serve(network: 'regtest', chunks: [(5, headers)]);

      final result = await _service(cdn, chain).synchronize();

      expect(result.success, isFalse,
          reason: 'an unanchored first chunk must be rejected');
      expect(result.headersImported, equals(0));
      await _expectNothingWritten(chain);
      expect(await chain.getHeaderByHeight(5), isNull);
    });

    test('a chunk whose first header is a fake genesis with the wrong hash is rejected',
        () async {
      final chain = await _emptyChain();
      // Same shape as the regtest genesis (prev = 0, valid PoW) but not it.
      final fakeGenesis = _mineHeader(
        prevBlock: Hash.zero(),
        timestamp: genesis.timestamp.add(const Duration(seconds: 1)),
        bits: regBits,
      );
      expect(fakeGenesis.blockHash().toString(), isNot(regtest.genesisHash));
      final headers = _mineChain(fakeGenesis, 6, bits: regBits);
      final cdn = _serve(network: 'regtest', chunks: [(0, headers)]);

      final result = await _service(cdn, chain).synchronize();

      expect(result.success, isFalse, reason: 'a fake genesis must be rejected');
      expect(result.error, contains(regtest.genesisHash),
          reason: 'the rejection names the in-code genesis it was checked against');
      await _expectNothingWritten(chain);
    });

    test('a manifest checkpoint that agrees with a fake genesis does not override the in-code anchor',
        () async {
      final chain = await _emptyChain();
      final fakeGenesis = _mineHeader(
        prevBlock: Hash.zero(),
        timestamp: genesis.timestamp.add(const Duration(seconds: 2)),
        bits: regBits,
      );
      final headers = _mineChain(fakeGenesis, 6, bits: regBits);
      // The CDN vouches for its own fake genesis via the manifest checkpoint.
      final cdn = _serve(
        network: 'regtest',
        chunks: [(0, headers)],
        checkpoints: {0: fakeGenesis.blockHash().toString()},
      );

      final result = await _service(cdn, chain).synchronize();

      expect(result.success, isFalse,
          reason: 'manifest checkpoints are advisory; the in-code genesis wins');
      await _expectNothingWritten(chain);
    });

    test('a header whose bits are easier than the network powLimit is rejected',
        () async {
      final testnet = NetworkParams.testnet;
      final chain = await _emptyChain();
      // Real testnet genesis, then a block claiming regtest difficulty, which
      // is far easier than testnet's powLimit (0x1d00ffff).
      final easy = _mineOn(testnet.genesisHeader, bits: regBits);
      expect(NetworkParams.bitsToTarget(easy.bits), greaterThan(testnet.powLimit));
      final cdn = _serve(
          network: 'testnet', chunks: [(0, [testnet.genesisHeader, easy])]);

      final result = await _service(cdn, chain).synchronize();

      expect(result.success, isFalse,
          reason: 'bits above powLimit must fail proof-of-work validation');
      await _expectNothingWritten(chain);
    });

    test('a header whose hash exceeds its own target is rejected', () async {
      final chain = await _emptyChain();
      final bad = _mineOn(genesis, bits: regBits, valid: false);
      expect(NetworkParams.hashToBigInt(bad.blockHash().toString()),
          greaterThan(NetworkParams.bitsToTarget(bad.bits)));
      final cdn = _serve(network: 'regtest', chunks: [(0, [genesis, bad])]);

      final result = await _service(cdn, chain).synchronize();

      expect(result.success, isFalse,
          reason: 'a hash above its target must fail proof-of-work validation');
      await _expectNothingWritten(chain);
    });

    test('a later chunk that does not link to the previous one is rejected and nothing from it is written',
        () async {
      final chain = await _emptyChain();
      final good = _mineChain(genesis, 5, bits: regBits);
      final other = _mineChain(
          _mineHeader(
              prevBlock: Hash.zero(), timestamp: genesis.timestamp, bits: regBits),
          10,
          bits: regBits);
      final cdn = _serve(
          network: 'regtest', chunks: [(0, good), (5, other.sublist(5))]);

      final result = await _service(cdn, chain).synchronize();

      expect(result.success, isFalse);
      expect(result.headersImported, equals(5), reason: 'the first chunk is fine');
      expect(chain.bestHeight, equals(4));
      expect(await chain.getHeaderByHeight(5), isNull,
          reason: 'nothing from the unlinked chunk may be written');
    });

    test('a non-empty database resumes from its stored tip and links the new headers to it',
        () async {
      final chain = await _emptyChain();
      final headers = _mineChain(genesis, 10, bits: regBits);
      await chain.bulkImportHeaders(headers.sublist(0, 4), 0);
      expect(chain.bestHeight, equals(3));
      final cdn = _serve(network: 'regtest', chunks: [(0, headers)]);

      final result = await _service(cdn, chain).synchronize();

      expect(result.success, isTrue, reason: result.error);
      expect(result.headersImported, equals(6));
      expect(chain.bestHeight, equals(9));
      expect(chain.chainTip!.blockHash().toString(),
          equals(headers.last.blockHash().toString()));
    });

    test('a non-empty database rejects a chunk that does not link to its stored tip',
        () async {
      final chain = await _emptyChain();
      final stored = _mineChain(genesis, 4, bits: regBits);
      await chain.bulkImportHeaders(stored, 0);
      // A different branch from the same genesis (different timestamp, so a
      // different block 1): heights 1..9 differ from what is stored.
      final fork = [
        genesis,
        ..._mineChain(
            _mineHeader(
                prevBlock: genesis.blockHash(),
                timestamp: genesis.timestamp.add(const Duration(minutes: 11)),
                bits: regBits),
            9,
            bits: regBits)
      ];
      expect(fork[3].blockHash().toString(), isNot(stored[3].blockHash().toString()));
      final cdn = _serve(network: 'regtest', chunks: [(4, fork.sublist(4))]);

      final result = await _service(cdn, chain).synchronize();

      expect(result.success, isFalse);
      expect(chain.bestHeight, equals(3));
      expect(await chain.getHeaderByHeight(4), isNull);
    });

    test('proof-of-work validation is on by default', () {
      expect(
          const CdnHeaderSyncConfig(baseUrl: 'https://x', network: 'mainnet')
              .validateProofOfWork,
          isTrue);
    });

    test('an http base URL is refused when the service is constructed', () async {
      final chain = await _emptyChain();
      expect(
        () => CdnHeaderSyncService(
          config: const CdnHeaderSyncConfig(
              baseUrl: 'http://cdn.example.test', network: 'mainnet'),
          headerChain: chain,
          httpClient: http_testing.MockClient((_) async => http.Response('', 500)),
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('an https base URL is accepted', () async {
      final chain = await _emptyChain();
      expect(
        () => CdnHeaderSyncService(
          config: const CdnHeaderSyncConfig(
              baseUrl: 'https://cdn.example.test', network: 'mainnet'),
          headerChain: chain,
          httpClient: http_testing.MockClient((_) async => http.Response('', 500)),
        ),
        returnsNormally,
      );
    });

    test('allowInsecureHttp defaults to false', () {
      expect(
          const CdnHeaderSyncConfig(baseUrl: 'https://x', network: 'mainnet')
              .allowInsecureHttp,
          isFalse);
    });

    test('an http base URL is accepted only with allowInsecureHttp: true', () async {
      final chain = await _emptyChain();
      expect(
        () => CdnHeaderSyncService(
          config: const CdnHeaderSyncConfig(
              baseUrl: 'http://localhost:8080',
              network: 'regtest',
              allowInsecureHttp: true),
          headerChain: chain,
          httpClient: http_testing.MockClient((_) async => http.Response('', 500)),
        ),
        returnsNormally,
      );
    });

    test('a base URL with no scheme or host is refused', () async {
      final chain = await _emptyChain();
      for (final bad in ['cdn.example.test', 'ftp://cdn.example.test', '']) {
        expect(
          () => CdnHeaderSyncService(
            config: CdnHeaderSyncConfig(baseUrl: bad, network: 'mainnet'),
            headerChain: chain,
            httpClient: http_testing.MockClient((_) async => http.Response('', 500)),
          ),
          throwsA(isA<ArgumentError>()),
          reason: 'baseUrl "$bad" must be refused',
        );
      }
    });

    test('a valid chunk at regtest difficulty is imported when PoW is on (default)',
        () async {
      // Guards the miner and the PoW path together: real work at regtest
      // difficulty passes, so the rejections above are not false positives.
      final chain = await _emptyChain();
      final headers = _mineChain(genesis, 3, bits: regBits);
      final cdn = _serve(network: 'regtest', chunks: [(0, headers)]);
      final result = await _service(cdn, chain).synchronize();
      expect(result.success, isTrue, reason: result.error);
      expect(chain.bestHeight, equals(2));
    });
  });
}
