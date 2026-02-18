import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:spiffynode/spiffy_node.dart';

import 'block_header_chain.dart';
import 'cdn_header_sync_config.dart';
import 'cdn_manifest.dart';

/// Downloads and imports block headers from a CDN for fast initial sync.
///
/// This service is used during first wallet setup to bypass the slow P2P
/// header sync (2,000 headers per round-trip). It downloads pre-built binary
/// header chunks from a CDN, validates them, and bulk-inserts into storage.
class CdnHeaderSyncService {
  final CdnHeaderSyncConfig config;
  final BlockHeaderChain headerChain;
  final Logger _logger;
  final http.Client _httpClient;

  CdnHeaderSyncService({
    required this.config,
    required this.headerChain,
    http.Client? httpClient,
    Logger? logger,
  })  : _logger = logger ?? Logger('CdnHeaderSyncService'),
        _httpClient = httpClient ?? http.Client();

  /// Main entry point - downloads and imports CDN headers.
  ///
  /// Returns a [CdnSyncResult] with the outcome. On failure, returns
  /// a result with [success] = false so the caller can fall back to P2P.
  Future<CdnSyncResult> synchronize() async {
    final stopwatch = Stopwatch()..start();
    var headersImported = 0;

    try {
      // Phase 1: Fetch manifest
      _reportProgress(0, 0, CdnSyncPhase.fetchingManifest);
      final manifest = await _fetchManifest();
      _logger.info(
          'CDN manifest: ${manifest.totalHeaders} headers in ${manifest.chunks.length} chunks');

      // Phase 2: Determine which chunks we need
      final currentHeight = headerChain.bestHeight;
      final neededChunks = _determineNeededChunks(manifest, currentHeight);
      if (neededChunks.isEmpty) {
        _logger.info('No CDN chunks needed, already at height $currentHeight');
        stopwatch.stop();
        return CdnSyncResult(
          success: true,
          headersImported: 0,
          finalHeight: currentHeight,
          elapsed: stopwatch.elapsed,
        );
      }

      _logger.info(
          'Need ${neededChunks.length} chunks (current height: $currentHeight)');

      // Phase 3: Download chunks with concurrency control
      _reportProgress(0, manifest.totalHeaders, CdnSyncPhase.downloadingChunks);
      final chunkDataList = await _downloadChunks(neededChunks, manifest.totalHeaders);

      // Phase 4: Parse, validate, and import each chunk in order
      _reportProgress(0, manifest.totalHeaders, CdnSyncPhase.validatingChunks);

      // Collect all headers for chain continuity validation
      final allHeaders = <BlockHeader>[];
      var firstChunkStartHeight = neededChunks.first.startHeight;

      for (var i = 0; i < neededChunks.length; i++) {
        final chunk = neededChunks[i];
        final data = chunkDataList[i];

        // Verify SHA-256 integrity
        if (!_validateChunkIntegrity(data, chunk.sha256)) {
          throw Exception(
              'Chunk integrity check failed for ${chunk.filename}');
        }

        // Parse binary headers
        final headers = _parseChunkHeaders(data);
        if (headers.length != chunk.headerCount) {
          throw Exception(
              'Header count mismatch in ${chunk.filename}: '
              'expected ${chunk.headerCount}, got ${headers.length}');
        }

        allHeaders.addAll(headers);
      }

      // Validate chain continuity across all chunks
      if (!_validateChainContinuity(allHeaders, firstChunkStartHeight)) {
        throw Exception('Chain continuity validation failed');
      }

      // Verify checkpoints
      if (config.verifyCheckpoints && manifest.checkpoints.isNotEmpty) {
        _verifyCheckpoints(allHeaders, firstChunkStartHeight, manifest.checkpoints);
      }

      // Phase 5: Bulk import
      _reportProgress(0, allHeaders.length, CdnSyncPhase.importingHeaders);

      // Import in chunks to report progress
      const importBatchSize = 50000;
      for (var i = 0; i < allHeaders.length; i += importBatchSize) {
        final end = (i + importBatchSize).clamp(0, allHeaders.length);
        final batch = allHeaders.sublist(i, end);
        await headerChain.bulkImportHeaders(batch, firstChunkStartHeight + i);
        headersImported += batch.length;
        _reportProgress(headersImported, allHeaders.length, CdnSyncPhase.importingHeaders);
      }

      _reportProgress(headersImported, headersImported, CdnSyncPhase.complete);

      stopwatch.stop();
      final result = CdnSyncResult(
        success: true,
        headersImported: headersImported,
        finalHeight: headerChain.bestHeight,
        elapsed: stopwatch.elapsed,
      );
      _logger.info(
          'CDN sync complete: ${result.headersImported} headers imported '
          'in ${result.elapsed.inSeconds}s, tip at height ${result.finalHeight}');
      return result;
    } catch (e) {
      stopwatch.stop();
      _logger.warning('CDN header sync failed: $e');
      _reportProgress(headersImported, 0, CdnSyncPhase.fallbackToP2P);
      return CdnSyncResult(
        success: false,
        headersImported: headersImported,
        finalHeight: headerChain.bestHeight,
        elapsed: stopwatch.elapsed,
        error: e.toString(),
      );
    }
  }

  /// Fetch and parse the CDN manifest.
  Future<CdnManifest> _fetchManifest() async {
    final url = '${config.baseUrl}/${config.network}/manifest.json';
    _logger.fine('Fetching manifest from $url');

    final response = await _httpClient
        .get(Uri.parse(url))
        .timeout(config.downloadTimeout);

    if (response.statusCode != 200) {
      throw Exception('Failed to fetch manifest: HTTP ${response.statusCode}');
    }

    final json = jsonDecode(response.body) as Map<String, dynamic>;
    return CdnManifest.fromJson(json);
  }

  /// Determine which chunks need to be downloaded based on current height.
  List<CdnChunkInfo> _determineNeededChunks(
      CdnManifest manifest, int currentHeight) {
    return manifest.chunks
        .where((chunk) => chunk.endHeight > currentHeight)
        .toList()
      ..sort((a, b) => a.startHeight.compareTo(b.startHeight));
  }

  /// Download chunks with concurrency control.
  Future<List<Uint8List>> _downloadChunks(
      List<CdnChunkInfo> chunks, int totalHeaders) async {
    final results = List<Uint8List?>.filled(chunks.length, null);
    var downloadedHeaders = 0;

    // Process chunks with a concurrency pool
    final semaphore = _Semaphore(config.concurrentDownloads);

    final futures = <Future<void>>[];
    for (var i = 0; i < chunks.length; i++) {
      final index = i;
      final chunk = chunks[i];

      futures.add(semaphore.run(() async {
        _logger.fine('Downloading ${chunk.filename} '
            '(${chunk.sizeBytes} bytes)');

        final url = '${config.baseUrl}/${config.network}/${chunk.filename}';
        final response = await _httpClient
            .get(Uri.parse(url))
            .timeout(config.downloadTimeout);

        if (response.statusCode != 200) {
          throw Exception(
              'Failed to download ${chunk.filename}: HTTP ${response.statusCode}');
        }

        results[index] = response.bodyBytes;
        downloadedHeaders += chunk.headerCount;
        _reportProgress(
            downloadedHeaders, totalHeaders, CdnSyncPhase.downloadingChunks);
      }));
    }

    await Future.wait(futures);

    // Verify all chunks were downloaded
    for (var i = 0; i < results.length; i++) {
      if (results[i] == null) {
        throw Exception('Chunk ${chunks[i].filename} was not downloaded');
      }
    }

    return results.cast<Uint8List>();
  }

  /// Verify SHA-256 hash of a chunk matches the expected value.
  bool _validateChunkIntegrity(Uint8List data, String expectedSha256) {
    final digest = sha256.convert(data);
    final actual = digest.toString();
    if (actual != expectedSha256) {
      _logger.warning(
          'Chunk integrity mismatch: expected $expectedSha256, got $actual');
      return false;
    }
    return true;
  }

  /// Parse raw 80-byte block headers from a binary chunk.
  List<BlockHeader> _parseChunkHeaders(Uint8List data) {
    const headerSize = 80;
    if (data.length % headerSize != 0) {
      throw Exception(
          'Invalid chunk size: ${data.length} is not a multiple of $headerSize');
    }

    final count = data.length ~/ headerSize;
    final headers = <BlockHeader>[];

    for (var i = 0; i < count; i++) {
      final offset = i * headerSize;
      final headerBytes = Uint8List.sublistView(data, offset, offset + headerSize);
      headers.add(BlockHeader.deserialize(headerBytes));
    }

    return headers;
  }

  /// Validate that headers form a continuous chain.
  bool _validateChainContinuity(List<BlockHeader> headers, int startHeight) {
    if (headers.isEmpty) return true;

    for (var i = 1; i < headers.length; i++) {
      final prevHash = headers[i - 1].blockHash().toString();
      final headerPrevHash = headers[i].prevBlock.toString();

      if (prevHash != headerPrevHash) {
        _logger.warning(
            'Chain continuity break at height ${startHeight + i}: '
            'expected prevBlock $prevHash, got $headerPrevHash');
        return false;
      }
    }

    // Optionally validate proof-of-work
    if (config.validateProofOfWork) {
      for (var i = 0; i < headers.length; i++) {
        if (!_validateProofOfWork(headers[i])) {
          _logger.warning(
              'PoW validation failed at height ${startHeight + i}');
          return false;
        }
      }
    }

    _logger.fine(
        'Chain continuity validated for ${headers.length} headers');
    return true;
  }

  /// Verify that block hashes at checkpoint heights match expected values.
  void _verifyCheckpoints(
      List<BlockHeader> headers, int startHeight, Map<int, String> checkpoints) {
    for (final entry in checkpoints.entries) {
      final height = entry.key;
      final expectedHash = entry.value;

      final index = height - startHeight;
      if (index < 0 || index >= headers.length) continue;

      final actualHash = headers[index].blockHash().toString();
      if (actualHash != expectedHash) {
        throw Exception(
            'Checkpoint mismatch at height $height: '
            'expected $expectedHash, got $actualHash');
      }
    }

    _logger.fine('All applicable checkpoints verified');
  }

  /// Validate proof-of-work for a single header.
  bool _validateProofOfWork(BlockHeader header) {
    final blockHash = header.blockHash();
    final target = _bitsToTarget(header.bits);

    final hashBytes = _hexToBytes(blockHash.toString());
    final hashBigInt = _bytesToBigInt(hashBytes.reversed.toList());

    return hashBigInt <= target;
  }

  BigInt _bitsToTarget(int bits) {
    final exponent = bits >> 24;
    final mantissa = bits & 0x00ffffff;

    if (exponent <= 3) {
      return BigInt.from(mantissa >> (8 * (3 - exponent)));
    } else {
      return BigInt.from(mantissa) << (8 * (exponent - 3));
    }
  }

  Uint8List _hexToBytes(String hex) {
    final cleanHex = hex.replaceAll('0x', '');
    final bytes = <int>[];
    for (var i = 0; i < cleanHex.length; i += 2) {
      bytes.add(int.parse(cleanHex.substring(i, i + 2), radix: 16));
    }
    return Uint8List.fromList(bytes);
  }

  BigInt _bytesToBigInt(List<int> bytes) {
    var result = BigInt.zero;
    for (var i = 0; i < bytes.length; i++) {
      result += BigInt.from(bytes[i]) << (8 * i);
    }
    return result;
  }

  void _reportProgress(int current, int total, CdnSyncPhase phase) {
    config.onProgress?.call(current, total, phase);
  }
}

/// Simple concurrency limiter for parallel downloads.
class _Semaphore {
  final int _maxConcurrency;
  int _running = 0;
  final _waiting = <Completer<void>>[];

  _Semaphore(this._maxConcurrency);

  Future<T> run<T>(Future<T> Function() task) async {
    await _acquire();
    try {
      return await task();
    } finally {
      _release();
    }
  }

  Future<void> _acquire() async {
    if (_running < _maxConcurrency) {
      _running++;
      return;
    }
    final completer = Completer<void>();
    _waiting.add(completer);
    await completer.future;
  }

  void _release() {
    if (_waiting.isNotEmpty) {
      final next = _waiting.removeAt(0);
      next.complete();
    } else {
      _running--;
    }
  }
}
