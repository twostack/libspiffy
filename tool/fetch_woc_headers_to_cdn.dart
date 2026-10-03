/// Builds the header CDN package for a network from WhatsOnChain.
///
/// WhatsOnChain publishes every block header as raw 80-byte binary files
/// (`/block/headers/resources`, plus `latest` for the newest blocks). This
/// downloads them, checks them, and writes the same layout
/// `export_headers_to_cdn.dart` produces and `CdnHeaderSyncService` reads:
/// `headers_SSSSSSS_EEEEEEE.bin` chunks from height 1 (genesis is built into
/// the app) and `manifest.json`.
///
/// Checks before anything is written: block 0 is the network's genesis
/// block, every header links to the one before it, and every header's hash
/// meets the target its own `bits` set. The newest [--reorg-margin] blocks
/// are left out, so a tip that is later reorganised away never reaches the
/// CDN; clients fetch the last blocks from peers.
///
/// The client still validates everything it imports (difficulty rules
/// included); these checks catch a bad download before it is published.
///
/// Usage:
///   dart run tool/fetch_woc_headers_to_cdn.dart \
///     --network mainnet \
///     --output /path/to/cdn/mainnet \
///     [--cache /path/to/cache] [--chunk-size 50000] [--reorg-margin 100]
///
/// Downloads are cached in --cache (default: <output>/.woc-cache), so a rerun
/// only fetches files that are new since the last run, plus `latest`.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

const _genesis = {
  'mainnet': '000000000019d6689c085ae165831e934ff763ae46a2a6c172b3f1b60a8ce26f',
  'testnet': '000000000933ea01ad0ee984209779baaec3ced90fa3f408719526f8d77f4943',
};

const _wocNetwork = {'mainnet': 'main', 'testnet': 'test'};

Future<void> main(List<String> args) async {
  final opts = _parseArgs(args);
  if (opts == null) {
    stderr.writeln(_usage);
    exit(64);
  }
  final network = opts['network']!;
  final output = Directory(opts['output']!);
  final cache = Directory(opts['cache'] ?? '${output.path}/.woc-cache');
  final chunkSize = int.parse(opts['chunk-size'] ?? '50000');
  final reorgMargin = int.parse(opts['reorg-margin'] ?? '100');
  final api = 'https://api.whatsonchain.com/v1/bsv/${_wocNetwork[network]}';
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 30);

  output.createSync(recursive: true);
  cache.createSync(recursive: true);

  // 1. The file list, and the network's view of its tip.
  final files = ((await _getJson(client, '$api/block/headers/resources'))['files'] as List).cast<String>();
  final chainInfo = await _getJson(client, '$api/chain/info');
  final wocTip = chainInfo['blocks'] as int;
  print('WhatsOnChain $network: ${files.length} header files, tip $wocTip');

  // 2. Download (or reuse) each file, in height order.
  final ranged = <({int start, int end, String url})>[];
  String? latestUrl;
  for (final url in files) {
    final m = RegExp(r'/(\d+)_(\d+)_headers\.bin$').firstMatch(url);
    if (m != null) {
      ranged.add((start: int.parse(m[1]!), end: int.parse(m[2]!), url: url));
    } else if (url.endsWith('/latest')) {
      latestUrl = url;
    } else {
      throw StateError('Unexpected header file URL: $url');
    }
  }
  ranged.sort((a, b) => a.start.compareTo(b.start));

  final all = BytesBuilder(copy: false);
  var nextHeight = 0;
  for (final f in ranged) {
    if (f.start != nextHeight) throw StateError('Gap: expected height $nextHeight, file starts at ${f.start}');
    final name = '${f.start}_${f.end}_headers.bin';
    final bytes = await _cached(client, f.url, File('${cache.path}/$name'));
    final count = f.end - f.start + 1;
    if (bytes.length != count * 80) {
      // A cached file from before WhatsOnChain finished it: fetch it again.
      File('${cache.path}/$name').deleteSync();
      throw StateError('$name has ${bytes.length} bytes, expected ${count * 80}; rerun to refetch');
    }
    all.add(bytes);
    nextHeight = f.end + 1;
    stdout.write('\r  downloaded through height ${f.end}      ');
  }
  if (latestUrl != null) {
    final latest = await _download(client, latestUrl); // never cached: it grows
    if (latest.length % 80 != 0) throw StateError('latest is not whole headers (${latest.length} bytes)');
    all.add(latest);
    nextHeight += latest.length ~/ 80;
  }
  print('');
  final raw = all.toBytes();
  final tip = raw.length ~/ 80 - 1;
  print('Downloaded headers 0..$tip');

  // 3. Check: genesis, linkage, proof of work.
  final hashes = List<String>.filled(tip + 1, '');
  Uint8List? prevHashLe;
  for (var h = 0; h <= tip; h++) {
    final header = Uint8List.sublistView(raw, h * 80, h * 80 + 80);
    final hashLe = Uint8List.fromList(sha256.convert(sha256.convert(header).bytes).bytes);
    if (h == 0) {
      if (_hex(hashLe.reversed) != _genesis[network]) throw StateError('Block 0 is not the $network genesis block');
    } else {
      final prev = Uint8List.sublistView(header, 4, 36);
      if (!_equal(prev, prevHashLe!)) throw StateError('Header $h does not link to header ${h - 1}');
    }
    final bits = ByteData.sublistView(header, 72, 76).getUint32(0, Endian.little);
    if (!_meetsTarget(hashLe, bits)) throw StateError('Header $h does not meet its target (bits 0x${bits.toRadixString(16)})');
    hashes[h] = _hex(hashLe.reversed);
    prevHashLe = hashLe;
    if (h % 50000 == 0) stdout.write('\r  checked through height $h      ');
  }
  print('\r  checked 0..$tip: genesis, linkage and proof of work OK');

  if (tip < wocTip - 10) throw StateError('Downloaded tip $tip is far below WhatsOnChain\'s $wocTip');
  final best = chainInfo['bestblockhash'] as String;
  if (tip == wocTip && hashes[tip] != best) {
    throw StateError('Tip $tip hash ${hashes[tip]} is not WhatsOnChain\'s best block $best');
  }

  // 4. Write chunks from height 1, leaving out the newest blocks.
  final last = tip - reorgMargin;
  for (final f in output.listSync().whereType<File>()) {
    final n = f.uri.pathSegments.last;
    if (n.startsWith('headers_') && n.endsWith('.bin')) f.deleteSync();
  }
  final chunks = <Map<String, Object>>[];
  final checkpoints = <String, String>{};
  for (var start = 1; start <= last; start += chunkSize) {
    final end = (start + chunkSize - 1).clamp(start, last);
    final data = Uint8List.sublistView(raw, start * 80, (end + 1) * 80);
    final filename = 'headers_${start.toString().padLeft(7, '0')}_${end.toString().padLeft(7, '0')}.bin';
    File('${output.path}/$filename').writeAsBytesSync(data);
    chunks.add({
      'filename': filename,
      'startHeight': start,
      'endHeight': end,
      'headerCount': end - start + 1,
      'sha256': sha256.convert(data).toString(),
      'sizeBytes': data.length,
    });
  }
  for (var h = 100000; h <= last; h += 100000) {
    checkpoints['$h'] = hashes[h];
  }

  final manifest = {
    'version': 1,
    'network': network,
    'generatedAt': DateTime.now().toUtc().toIso8601String(),
    'totalHeaders': last,
    'chunkSize': chunkSize,
    'headerSizeBytes': 80,
    'chunks': chunks,
    'checkpoints': checkpoints,
  };
  File('${output.path}/manifest.json').writeAsStringSync(const JsonEncoder.withIndent('  ').convert(manifest));
  client.close();

  final mb = chunks.fold<int>(0, (s, c) => s + (c['sizeBytes'] as int)) / 1024 / 1024;
  print('Wrote ${chunks.length} chunks (heights 1..$last, ${mb.toStringAsFixed(1)} MB) and manifest.json '
      'to ${output.path}');
  print('Upload the directory\'s .bin files and manifest.json (not .woc-cache) as /$network/ on the header CDN.');
}

/// [bits] as a target, compared with the header hash (little-endian bytes).
bool _meetsTarget(Uint8List hashLe, int bits) {
  final exponent = bits >> 24;
  final mantissa = bits & 0x007fffff;
  if (bits & 0x00800000 != 0 || mantissa == 0) return false;
  final target = exponent <= 3
      ? BigInt.from(mantissa >> (8 * (3 - exponent)))
      : BigInt.from(mantissa) << (8 * (exponent - 3));
  var value = BigInt.zero;
  for (var i = hashLe.length - 1; i >= 0; i--) {
    value = (value << 8) | BigInt.from(hashLe[i]);
  }
  return value <= target;
}

Future<Uint8List> _cached(HttpClient client, String url, File file) async {
  if (file.existsSync()) return file.readAsBytesSync();
  final bytes = await _download(client, url);
  file.writeAsBytesSync(bytes);
  return bytes;
}

Future<Uint8List> _download(HttpClient client, String url) async {
  for (var attempt = 1;; attempt++) {
    try {
      // WhatsOnChain's free tier allows a few requests a second.
      await Future<void>.delayed(const Duration(milliseconds: 400));
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close();
      final builder = BytesBuilder(copy: false);
      await response.forEach(builder.add);
      if (response.statusCode == 200) return builder.toBytes();
      throw HttpException('HTTP ${response.statusCode}', uri: Uri.parse(url));
    } catch (e) {
      if (attempt >= 5) rethrow;
      stderr.writeln('\n  $url failed ($e); retrying');
      await Future<void>.delayed(Duration(seconds: 2 * attempt));
    }
  }
}

Future<Map<String, dynamic>> _getJson(HttpClient client, String url) async =>
    jsonDecode(utf8.decode(await _download(client, url))) as Map<String, dynamic>;

String _hex(Iterable<int> bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

bool _equal(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

Map<String, String>? _parseArgs(List<String> args) {
  final opts = <String, String>{};
  for (var i = 0; i < args.length; i++) {
    if (!args[i].startsWith('--') || i + 1 >= args.length) return null;
    opts[args[i].substring(2)] = args[++i];
  }
  if (!_genesis.containsKey(opts['network']) || opts['output'] == null) return null;
  return opts;
}

const _usage = '''
Usage: dart run tool/fetch_woc_headers_to_cdn.dart --network mainnet|testnet --output DIR
         [--cache DIR] [--chunk-size 50000] [--reorg-margin 100]''';
