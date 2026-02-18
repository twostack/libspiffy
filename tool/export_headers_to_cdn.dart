/// CDN Header Export Tool
///
/// Reads block headers from a backup JSON file (overnode_backup format)
/// and exports them as binary 80-byte header chunks suitable for CDN hosting.
///
/// Usage:
///   dart run tool/export_headers_to_cdn.dart \
///     --source /path/to/block_headers.json \
///     --output /path/to/cdn/testnet \
///     --network testnet \
///     --chunk-size 50000
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' hide Hash;
import 'package:spiffynode/spiffy_node.dart';

void main(List<String> args) async {
  final config = _parseArgs(args);
  if (config == null) {
    _printUsage();
    exit(1);
  }

  print('CDN Header Export Tool');
  print('  Source: ${config.sourcePath}');
  print('  Output: ${config.outputDir}');
  print('  Network: ${config.network}');
  print('  Chunk size: ${config.chunkSize} headers');
  print('');

  // Ensure output directory exists
  final outDir = Directory(config.outputDir);
  if (!outDir.existsSync()) {
    outDir.createSync(recursive: true);
  }

  // Read and parse headers from backup JSON
  print('Reading headers from backup JSON...');
  final stopwatch = Stopwatch()..start();

  final file = File(config.sourcePath);
  if (!file.existsSync()) {
    print('ERROR: Source file not found: ${config.sourcePath}');
    exit(1);
  }

  // Stream-parse the JSON to handle large files
  final headers = await _parseHeadersFromJson(file);
  print('  Parsed ${headers.length} headers in ${stopwatch.elapsed.inSeconds}s');

  if (headers.isEmpty) {
    print('ERROR: No headers found in source file');
    exit(1);
  }

  // Sort by height
  headers.sort((a, b) => a.height.compareTo(b.height));
  print('  Height range: ${headers.first.height} - ${headers.last.height}');

  // Generate binary chunks
  print('');
  print('Generating binary chunks...');
  final chunks = <_ChunkResult>[];
  final checkpoints = <int, String>{};

  // Add checkpoints at regular intervals
  const checkpointInterval = 100000;

  for (var i = 0; i < headers.length; i += config.chunkSize) {
    final end = (i + config.chunkSize).clamp(0, headers.length);
    final batch = headers.sublist(i, end);
    final startHeight = batch.first.height;
    final endHeight = batch.last.height;

    // Serialize to binary
    final buffer = BytesBuilder(copy: false);
    for (final entry in batch) {
      final blockHeader = BlockHeader(
        version: entry.version,
        prevBlock: Hash.fromHex(entry.prevBlockHash),
        merkleRoot: Hash.fromHex(entry.merkleRoot),
        timestamp:
            DateTime.fromMillisecondsSinceEpoch(entry.timestamp * 1000),
        bits: entry.bits,
        nonce: entry.nonce,
      );
      buffer.add(blockHeader.serialize());
    }

    final data = buffer.toBytes();
    final chunkSha256 = sha256.convert(data).toString();

    // Write chunk file
    final startStr = startHeight.toString().padLeft(7, '0');
    final endStr = endHeight.toString().padLeft(7, '0');
    final filename = 'headers_${startStr}_$endStr.bin';
    final chunkFile = File('${config.outputDir}/$filename');
    await chunkFile.writeAsBytes(data);

    chunks.add(_ChunkResult(
      filename: filename,
      startHeight: startHeight,
      endHeight: endHeight,
      headerCount: batch.length,
      sha256: chunkSha256,
      sizeBytes: data.length,
    ));

    // Collect checkpoints
    for (final entry in batch) {
      if (entry.height % checkpointInterval == 0) {
        checkpoints[entry.height] = entry.hash;
      }
    }

    print(
        '  Wrote $filename (${batch.length} headers, ${data.length} bytes)');
  }

  // Generate manifest
  print('');
  print('Generating manifest.json...');
  final manifest = {
    'version': 1,
    'network': config.network,
    'generatedAt': DateTime.now().toUtc().toIso8601String(),
    'totalHeaders': headers.length,
    'chunkSize': config.chunkSize,
    'headerSizeBytes': 80,
    'chunks': chunks
        .map((c) => {
              'filename': c.filename,
              'startHeight': c.startHeight,
              'endHeight': c.endHeight,
              'headerCount': c.headerCount,
              'sha256': c.sha256,
              'sizeBytes': c.sizeBytes,
            })
        .toList(),
    'checkpoints':
        checkpoints.map((k, v) => MapEntry(k.toString(), v)),
  };

  final manifestFile = File('${config.outputDir}/manifest.json');
  final encoder = JsonEncoder.withIndent('  ');
  await manifestFile.writeAsString(encoder.convert(manifest));

  stopwatch.stop();

  // Summary
  final totalBytes =
      chunks.fold<int>(0, (sum, c) => sum + c.sizeBytes);
  print('');
  print('Export complete!');
  print('  Total headers: ${headers.length}');
  print('  Total chunks: ${chunks.length}');
  print('  Total size: ${(totalBytes / 1024 / 1024).toStringAsFixed(1)} MB');
  print('  Checkpoints: ${checkpoints.length}');
  print('  Elapsed: ${stopwatch.elapsed.inSeconds}s');
  print('');
  print('Files written to: ${config.outputDir}/');
}

/// Parse headers from the backup JSON format.
///
/// The backup JSON is an array of objects like:
/// ```json
/// [{"height":1,"hash":"...","prevBlockHash":"...","merkleRoot":"...",
///   "timestamp":1296688928,"version":1,"bits":486604799,"nonce":1924588547,
///   "isOrphaned":false,"storedAt":"..."},...]
/// ```
Future<List<_HeaderEntry>> _parseHeadersFromJson(File file) async {
  final headers = <_HeaderEntry>[];

  // For very large files, we stream-decode line by line
  // But since the backup is a single JSON array, we use decode
  final content = await file.readAsString();
  final jsonArray = jsonDecode(content) as List<dynamic>;

  for (final item in jsonArray) {
    final map = item as Map<String, dynamic>;

    // Skip orphaned headers
    if (map['isOrphaned'] == true) continue;

    headers.add(_HeaderEntry(
      height: map['height'] as int,
      hash: map['hash'] as String,
      prevBlockHash: map['prevBlockHash'] as String,
      merkleRoot: map['merkleRoot'] as String,
      timestamp: map['timestamp'] as int,
      version: map['version'] as int,
      bits: map['bits'] as int,
      nonce: map['nonce'] as int,
    ));
  }

  return headers;
}

class _HeaderEntry {
  final int height;
  final String hash;
  final String prevBlockHash;
  final String merkleRoot;
  final int timestamp;
  final int version;
  final int bits;
  final int nonce;

  const _HeaderEntry({
    required this.height,
    required this.hash,
    required this.prevBlockHash,
    required this.merkleRoot,
    required this.timestamp,
    required this.version,
    required this.bits,
    required this.nonce,
  });
}

class _ChunkResult {
  final String filename;
  final int startHeight;
  final int endHeight;
  final int headerCount;
  final String sha256;
  final int sizeBytes;

  const _ChunkResult({
    required this.filename,
    required this.startHeight,
    required this.endHeight,
    required this.headerCount,
    required this.sha256,
    required this.sizeBytes,
  });
}

class _ExportConfig {
  final String sourcePath;
  final String outputDir;
  final String network;
  final int chunkSize;

  const _ExportConfig({
    required this.sourcePath,
    required this.outputDir,
    required this.network,
    required this.chunkSize,
  });
}

_ExportConfig? _parseArgs(List<String> args) {
  String? source;
  String? output;
  String network = 'testnet';
  int chunkSize = 50000;

  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--source':
        if (i + 1 < args.length) source = args[++i];
        break;
      case '--output':
        if (i + 1 < args.length) output = args[++i];
        break;
      case '--network':
        if (i + 1 < args.length) network = args[++i];
        break;
      case '--chunk-size':
        if (i + 1 < args.length) chunkSize = int.parse(args[++i]);
        break;
      case '--help':
      case '-h':
        return null;
    }
  }

  if (source == null || output == null) return null;

  return _ExportConfig(
    sourcePath: source,
    outputDir: output,
    network: network,
    chunkSize: chunkSize,
  );
}

void _printUsage() {
  print('Usage: dart run tool/export_headers_to_cdn.dart [options]');
  print('');
  print('Options:');
  print('  --source <path>      Path to block_headers.json backup file (required)');
  print('  --output <path>      Output directory for CDN files (required)');
  print('  --network <name>     Network name: testnet or mainnet (default: testnet)');
  print('  --chunk-size <n>     Headers per chunk file (default: 50000)');
  print('  -h, --help           Show this help');
}
