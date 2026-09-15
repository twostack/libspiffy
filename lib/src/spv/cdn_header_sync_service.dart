import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:meta/meta.dart';
import 'package:spiffynode/spiffy_node.dart';

import 'block_header_chain.dart';
import 'cdn_header_sync_config.dart';
import 'cdn_manifest.dart';
import 'network_params.dart';

/// Downloads and imports block headers from a CDN for fast initial sync.
///
/// This service is used during first wallet setup to bypass the slow P2P
/// header sync (2,000 headers per round-trip). It downloads pre-built binary
/// header chunks from a CDN, validates them, and bulk-inserts into storage.
///
/// Chunks are processed one at a time (download → validate → import) to
/// minimize memory usage and enable resumability. Optional disk caching
/// allows crash-resilient sync across app restarts.
///
/// The CDN is not trusted (audit finding SPV-04). Every chunk must pass,
/// before anything from it is written:
///
/// * integrity: its SHA-256 matches the manifest (a transport check only);
/// * anchoring: on an empty database the first header must be the in-code
///   genesis block of the configured network ([NetworkParams.genesisHash]);
///   on a non-empty database the first new header must link to the stored
///   tip. A chunk that starts anywhere else is rejected;
/// * continuity: every header's `prevBlock` is the hash of the one before;
/// * proof of work (on by default): every header's hash is at or below its
///   own target, and that target is no easier than [NetworkParams.powLimit].
///
/// Manifest checkpoints are advisory and are compared only after the above.
class CdnHeaderSyncService {
  final CdnHeaderSyncConfig config;
  final BlockHeaderChain headerChain;

  /// Consensus constants the downloaded headers are checked against,
  /// derived from [CdnHeaderSyncConfig.network].
  final NetworkParams networkParams;

  final Logger _logger;
  final http.Client _httpClient;

  /// Throws an [ArgumentError] if [config.baseUrl] is not https (unless
  /// [CdnHeaderSyncConfig.allowInsecureHttp] is set).
  CdnHeaderSyncService({
    required this.config,
    required this.headerChain,
    http.Client? httpClient,
    Logger? logger,
  })  : networkParams = NetworkParams.forNetwork(config.network),
        _logger = logger ?? Logger('CdnHeaderSyncService'),
        _httpClient = httpClient ?? http.Client() {
    config.checkBaseUrl();
  }

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

      // Phase 2: Determine which chunks we need.
      //
      // An empty database reports bestHeight 0 just like one holding only
      // the genesis block, so the tip (null when empty) decides whether the
      // next height needed is 0 or bestHeight + 1.
      final tip = headerChain.chainTip;
      final nextHeight = tip == null ? 0 : headerChain.bestHeight + 1;
      final neededChunks = _determineNeededChunks(manifest, nextHeight);
      if (neededChunks.isEmpty) {
        _logger.info(
            'No CDN chunks needed, already at height ${headerChain.bestHeight}');
        stopwatch.stop();
        return CdnSyncResult(
          success: true,
          headersImported: 0,
          finalHeight: headerChain.bestHeight,
          elapsed: stopwatch.elapsed,
        );
      }

      _logger.info(
          'Need ${neededChunks.length} chunks (next height: $nextHeight)');

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

      // The hash every accepted header must extend. Null only while the
      // database is empty, in which case the next header must be the
      // in-code genesis block rather than link to anything.
      String? expectedPrevHash = tip?.blockHash().toString();
      var expectedHeight = nextHeight;

      // Phase 3-5: Process each chunk sequentially (download → validate → import)
      for (var chunkIndex = 0; chunkIndex < neededChunks.length; chunkIndex++) {
        final chunk = neededChunks[chunkIndex];

        if (chunk.startHeight < 0 ||
            chunk.headerCount != chunk.endHeight - chunk.startHeight + 1) {
          throw Exception(
              'Manifest chunk ${chunk.filename} is inconsistent: heights '
              '${chunk.startHeight}..${chunk.endHeight} but headerCount '
              '${chunk.headerCount}');
        }

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

        // Line the chunk up with the next height we need.
        //
        // A chunk that starts below it overlaps what is already stored
        // (resume after a partial import): trim the overlap so headers[0]
        // is the header for expectedHeight, which must then link to the
        // stored tip. A chunk that starts above it leaves a gap, which on an
        // empty database means it does not begin with the genesis block;
        // either way nothing in it can be anchored, so it is rejected.
        var importStartHeight = chunk.startHeight;
        if (chunk.startHeight < expectedHeight) {
          final skipCount = expectedHeight - chunk.startHeight;
          if (skipCount >= headers.length) {
            // Entire chunk already imported — skip it. What we already hold
            // stays the anchor; the chunk's own contents are not consulted.
            _logger.fine('Skipping fully imported chunk ${chunk.filename}');
            await _deleteCachedChunk(chunk);
            continue;
          }
          _logger.info(
              'Resuming chunk ${chunk.filename}: skipping $skipCount '
              'already-imported headers');
          headers = headers.sublist(skipCount);
          importStartHeight = expectedHeight;
        } else if (chunk.startHeight > expectedHeight) {
          throw Exception(
              'Chunk ${chunk.filename} starts at height ${chunk.startHeight} '
              'but the next height needed is $expectedHeight'
              '${expectedHeight == 0 ? '; the first chunk on an empty database must begin with the genesis block' : ''}');
        }

        // Anchor: an empty database accepts only the in-code genesis block
        // of this network as its first header. Nothing the manifest says
        // (checkpoints included) can substitute for this.
        if (expectedPrevHash == null) {
          final firstHash = headers.first.blockHash().toString();
          if (firstHash != networkParams.genesisHash) {
            throw Exception(
                'Genesis mismatch in ${chunk.filename}: the first header is '
                '$firstHash but the ${networkParams.name} genesis block is '
                '${networkParams.genesisHash}; refusing an unanchored chain');
          }
        }

        // Validate linkage to the previous chunk / DB tip, intra-chunk
        // continuity, and proof of work.
        final failure =
            _validateChunk(headers, importStartHeight, expectedPrevHash);
        if (failure != null) {
          throw Exception(
              'Chunk ${chunk.filename} rejected: $failure');
        }

        // Compare against the manifest's (advisory) checkpoints. A mismatch
        // means the CDN contradicts itself, so the chunk is rejected; a
        // match adds nothing to the checks above.
        if (config.verifyCheckpoints && manifest.checkpoints.isNotEmpty) {
          _verifyCheckpoints(headers, importStartHeight, manifest.checkpoints);
        }

        // Import into DB
        _reportProgress(progressCurrent, totalNeeded, CdnSyncPhase.importingHeaders);
        await headerChain.bulkImportHeaders(headers, importStartHeight);
        headersImportedThisRun += headers.length;

        // The next chunk must extend what was just written.
        expectedPrevHash = headers.last.blockHash().toString();
        expectedHeight = importStartHeight + headers.length;

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

  /// Chunks that contain at least one header at or above [nextHeight], in
  /// ascending order.
  List<CdnChunkInfo> _determineNeededChunks(
      CdnManifest manifest, int nextHeight) {
    return manifest.chunks
        .where((chunk) => chunk.endHeight >= nextHeight)
        .toList()
      ..sort((a, b) => a.startHeight.compareTo(b.startHeight));
  }

  /// Path of [chunk]'s on-disk cache file.
  ///
  /// The filename comes from the CDN manifest, i.e. from the network. It is
  /// only ever used as a single path segment inside [config.cacheDirectory];
  /// anything that could name another directory (separators, `..`, an
  /// absolute path) is rejected rather than joined.
  @visibleForTesting
  String cacheFilePath(CdnChunkInfo chunk) {
    final name = chunk.filename;
    if (name.isEmpty ||
        name == '.' ||
        name == '..' ||
        name.contains('/') ||
        name.contains('\\') ||
        name.contains('\u0000')) {
      throw FormatException('Unsafe chunk filename in CDN manifest: "$name"');
    }
    return '${config.cacheDirectory}/$name';
  }

  /// Load a chunk from disk cache or download it with retry logic.
  Future<Uint8List> _loadOrDownloadChunk(CdnChunkInfo chunk) async {
    // Check disk cache first
    if (config.cacheDirectory != null) {
      final cachedFile = File(cacheFilePath(chunk));
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
          await File(cacheFilePath(chunk))
              .writeAsBytes(data);
        }

        return data;
      } catch (e) {
        if (attempt == config.maxRetries) rethrow;
        _logger.warning(
            'Download attempt $attempt for ${chunk.filename} failed: $e');
        await Future.delayed(Duration(seconds: attempt)); // linear backoff
      }
    }
    throw StateError('unreachable'); // all retry paths either return or rethrow
  }

  /// Delete a cached chunk file if disk caching is enabled.
  Future<void> _deleteCachedChunk(CdnChunkInfo chunk) async {
    if (config.cacheDirectory != null) {
      final cachedFile = File(cacheFilePath(chunk));
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

  /// Validate a chunk's chain: linkage to [previousBlockHash] (the last
  /// header of the previous chunk, or the stored tip), intra-chunk
  /// continuity, and proof of work when enabled.
  ///
  /// [previousBlockHash] is null only when the database is empty, in which
  /// case the caller has already checked that `headers[0]` is the in-code
  /// genesis block.
  ///
  /// Returns null when the chunk is acceptable, otherwise a description of
  /// the first failure.
  String? _validateChunk(
      List<BlockHeader> headers, int startHeight, String? previousBlockHash) {
    if (headers.isEmpty) return null;

    // Validate linkage to previous chunk / DB tip
    if (previousBlockHash != null) {
      final firstPrevHash = headers[0].prevBlock.toString();
      if (firstPrevHash != previousBlockHash) {
        return 'chain continuity break at height $startHeight: '
            'expected prevBlock $previousBlockHash, got $firstPrevHash';
      }
    }

    // Each header is hashed once for continuity and proof of work.
    final hashes = [for (final h in headers) h.blockHash().toString()];

    // Validate intra-chunk continuity
    for (var i = 1; i < headers.length; i++) {
      final prevHash = hashes[i - 1];
      final headerPrevHash = headers[i].prevBlock.toString();

      if (prevHash != headerPrevHash) {
        return 'chain continuity break at height ${startHeight + i}: '
            'expected prevBlock $prevHash, got $headerPrevHash';
      }
    }

    // Validate proof-of-work
    if (config.validateProofOfWork) {
      for (var i = 0; i < headers.length; i++) {
        final failure = _proofOfWorkFailure(headers[i], hashes[i]);
        if (failure != null) {
          return 'proof-of-work validation failed at height ${startHeight + i}: '
              '$failure';
        }
      }
    }

    _logger.fine(
        'Chain continuity validated for ${headers.length} headers '
        'starting at height $startHeight');
    return null;
  }

  /// Verify that block hashes at checkpoint heights match expected values.
  ///
  /// The checkpoints are the manifest's own and are advisory: a mismatch
  /// rejects the chunk, a match proves nothing beyond what the anchor,
  /// continuity and proof-of-work checks already established.
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

    _logger.fine('All applicable manifest checkpoints matched');
  }

  /// Proof-of-work check for a single header against its own target and
  /// the network's [NetworkParams.powLimit].
  ///
  /// Returns null if the header is acceptable, otherwise the reason.
  String? _proofOfWorkFailure(BlockHeader header, String blockHash) {
    final bits = header.bits;
    switch (networkParams.checkProofOfWork(bits, blockHash).failure) {
      case null:
        return null;
      case ProofOfWorkFailure.noTarget:
        return 'bits 0x${bits.toRadixString(16)} encode no valid target';
      case ProofOfWorkFailure.aboveLimit:
        return 'bits 0x${bits.toRadixString(16)} are easier than the '
            '${networkParams.name} powLimit '
            '0x${networkParams.powLimitBits.toRadixString(16)}';
      case ProofOfWorkFailure.hashAboveTarget:
        return 'hash $blockHash exceeds target for bits '
            '0x${bits.toRadixString(16)}';
    }
  }

  void _reportProgress(int current, int total, CdnSyncPhase phase) {
    config.onProgress?.call(current, total, phase);
  }
}
