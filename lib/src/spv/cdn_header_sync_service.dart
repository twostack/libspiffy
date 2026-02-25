import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:spiffynode/spiffy_node.dart';

import '../utils/hex_utils.dart' as hex_utils;
import 'block_header_chain.dart';
import 'cdn_header_sync_config.dart';
import 'cdn_manifest.dart';

/// Downloads and imports block headers from a CDN for fast initial sync.
///
/// This service is used during first wallet setup to bypass the slow P2P
/// header sync (2,000 headers per round-trip). It downloads pre-built binary
/// header chunks from a CDN, validates them, and bulk-inserts into storage.
///
/// Chunks are processed one at a time (download → validate → import) to
/// minimize memory usage and enable resumability. Optional disk caching
/// allows crash-resilient sync across app restarts.
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
  /// Processes chunks one at a time to minimize memory usage (~8MB peak
  /// instead of ~270MB). Each chunk is validated and imported before the
  /// next is downloaded, so progress is durable across restarts.
  ///
  /// Returns a [CdnSyncResult] with the outcome. On failure, returns
  /// a result with [success] = false so the caller can fall back to P2P.
  Future<CdnSyncResult> synchronize() async {
    final stopwatch = Stopwatch()..start();
    var headersImportedThisRun = 0;
    // progressOffset tracks already-imported headers for accurate UI progress
    var progressOffset = 0;

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

      // Ensure cache directory exists
      if (config.cacheDirectory != null) {
        await Directory(config.cacheDirectory!).create(recursive: true);
      }

      // Use manifest.totalHeaders as the denominator so progress reflects
      // the full sync. progressOffset accounts for already-imported headers
      // so the UI resumes from the right point instead of starting at 0.
      final totalNeeded = manifest.totalHeaders;
      progressOffset = totalNeeded -
          neededChunks.fold<int>(0, (sum, c) => sum + c.headerCount);

      // Track the last header's hash for chain continuity across chunks.
      // For the first chunk, use the DB chain tip.
      String? previousBlockHash = headerChain.chainTip?.blockHash().toString();

      // Phase 3-5: Process each chunk sequentially (download → validate → import)
      for (var chunkIndex = 0; chunkIndex < neededChunks.length; chunkIndex++) {
        final chunk = neededChunks[chunkIndex];

        final progressCurrent = progressOffset + headersImportedThisRun;

        // Download (or load from cache)
        _reportProgress(progressCurrent, totalNeeded, CdnSyncPhase.downloadingChunks);
        final data = await _loadOrDownloadChunk(chunk);

        // Validate integrity
        _reportProgress(progressCurrent, totalNeeded, CdnSyncPhase.validatingChunks);
        if (!_validateChunkIntegrity(data, chunk.sha256)) {
          // Delete corrupted cache file if present
          await _deleteCachedChunk(chunk);
          throw Exception('Chunk integrity check failed for ${chunk.filename}');
        }

        // Parse binary headers
        var headers = _parseChunkHeaders(data);
        if (headers.length != chunk.headerCount) {
          throw Exception(
              'Header count mismatch in ${chunk.filename}: '
              'expected ${chunk.headerCount}, got ${headers.length}');
        }

        // Handle partially-imported chunks on resume: if the chunk's start
        // is at or below the current DB height, trim already-imported headers.
        // After trimming, the chain tip hash correctly links to headers[0].
        var importStartHeight = chunk.startHeight;
        if (chunk.startHeight <= currentHeight) {
          final skipCount = currentHeight - chunk.startHeight + 1;
          if (skipCount >= headers.length) {
            // Entire chunk already imported — skip it
            _logger.fine('Skipping fully imported chunk ${chunk.filename}');
            previousBlockHash = headers.last.blockHash().toString();
            await _deleteCachedChunk(chunk);
            continue;
          }
          _logger.info(
              'Resuming chunk ${chunk.filename}: skipping $skipCount '
              'already-imported headers');
          headers = headers.sublist(skipCount);
          importStartHeight = currentHeight + 1;
        }

        // Validate chain continuity against the previous chunk (or DB tip)
        if (!_validateChunkContinuity(
            headers, importStartHeight, previousBlockHash)) {
          throw Exception(
              'Chain continuity validation failed at chunk ${chunk.filename}');
        }

        // Verify checkpoints within this chunk's range
        if (config.verifyCheckpoints && manifest.checkpoints.isNotEmpty) {
          _verifyCheckpoints(headers, importStartHeight, manifest.checkpoints);
        }

        // Import into DB
        _reportProgress(progressCurrent, totalNeeded, CdnSyncPhase.importingHeaders);
        await headerChain.bulkImportHeaders(headers, importStartHeight);
        headersImportedThisRun += headers.length;

        // Track last header hash for next chunk's continuity check
        previousBlockHash = headers.last.blockHash().toString();

        // Clean up cache file after successful import
        await _deleteCachedChunk(chunk);

        _logger.fine(
            'Chunk ${chunkIndex + 1}/${neededChunks.length} imported: '
            '${chunk.filename} (${headers.length} headers)');
      }

      _reportProgress(totalNeeded, totalNeeded, CdnSyncPhase.complete);

      stopwatch.stop();
      final result = CdnSyncResult(
        success: true,
        headersImported: headersImportedThisRun,
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
      _reportProgress(headersImportedThisRun, 0, CdnSyncPhase.fallbackToP2P);
      return CdnSyncResult(
        success: false,
        headersImported: headersImportedThisRun,
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

  /// Load a chunk from disk cache or download it with retry logic.
  Future<Uint8List> _loadOrDownloadChunk(CdnChunkInfo chunk) async {
    // Check disk cache first
    if (config.cacheDirectory != null) {
      final cachedFile = File('${config.cacheDirectory}/${chunk.filename}');
      if (await cachedFile.exists()) {
        final data = await cachedFile.readAsBytes();
        if (_validateChunkIntegrity(data, chunk.sha256)) {
          _logger.fine('Using cached chunk ${chunk.filename}');
          return data;
        }
        _logger.warning('Cached chunk ${chunk.filename} failed integrity check, re-downloading');
        await cachedFile.delete();
      }
    }

    // Download with retry
    for (var attempt = 1; attempt <= config.maxRetries; attempt++) {
      try {
        final url = '${config.baseUrl}/${config.network}/${chunk.filename}';
        _logger.fine('Downloading ${chunk.filename} '
            '(${chunk.sizeBytes} bytes, attempt $attempt/${config.maxRetries})');

        final response = await _httpClient
            .get(Uri.parse(url))
            .timeout(config.downloadTimeout);

        if (response.statusCode != 200) {
          throw Exception(
              'Failed to download ${chunk.filename}: HTTP ${response.statusCode}');
        }

        final data = response.bodyBytes;

        // Cache to disk for crash resilience
        if (config.cacheDirectory != null) {
          await File('${config.cacheDirectory}/${chunk.filename}')
              .writeAsBytes(data);
        }

        return data;
      } catch (e) {
        if (attempt == config.maxRetries) rethrow;
        _logger.warning(
            'Chunk ${chunk.filename} attempt $attempt/${config.maxRetries} failed: $e');
        await Future.delayed(Duration(seconds: attempt)); // linear backoff
      }
    }
    throw StateError('unreachable'); // all retry paths either return or rethrow
  }

  /// Delete a cached chunk file if disk caching is enabled.
  Future<void> _deleteCachedChunk(CdnChunkInfo chunk) async {
    if (config.cacheDirectory != null) {
      final cachedFile = File('${config.cacheDirectory}/${chunk.filename}');
      if (await cachedFile.exists()) {
        await cachedFile.delete();
      }
    }
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

  /// Validate chain continuity within a chunk, and linkage to previous chunk.
  ///
  /// [previousBlockHash] is the block hash of the last header from the
  /// previous chunk, or the DB chain tip for the first chunk. If null
  /// (no previous data), only intra-chunk continuity is validated.
  bool _validateChunkContinuity(
      List<BlockHeader> headers, int startHeight, String? previousBlockHash) {
    if (headers.isEmpty) return true;

    // Validate linkage to previous chunk / DB tip
    if (previousBlockHash != null) {
      final firstPrevHash = headers[0].prevBlock.toString();
      if (firstPrevHash != previousBlockHash) {
        _logger.warning(
            'Chain continuity break at height $startHeight: '
            'expected prevBlock $previousBlockHash, got $firstPrevHash');
        return false;
      }
    }

    // Validate intra-chunk continuity
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
        'Chain continuity validated for ${headers.length} headers '
        'starting at height $startHeight');
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

    final hashBytes = hex_utils.hexToBytes(blockHash.toString());
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
