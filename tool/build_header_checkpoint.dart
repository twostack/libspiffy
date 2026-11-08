/// Builds the header window an app ships (epic spiffyvault-emk): the newest
/// [--window] headers of a network in the HeaderCheckpoint (.svhc) format.
///
/// Reads a header CDN package — the directory `fetch_woc_headers_to_cdn.dart`
/// writes and `headers.overnode.net` serves: `manifest.json` and
/// `headers_SSSSSSS_EEEEEEE.bin` chunks from height 1. Before anything is
/// written, the WHOLE chain is checked from the in-code genesis block: each
/// chunk's SHA-256 matches the manifest, every header links to the one
/// before it, and every header meets its own proof of work. The window is
/// then the newest headers of that checked chain, so a fresh install trusts
/// exactly what an install that synced from genesis would have.
///
/// The package leaves out the newest blocks (its --reorg-margin), so the
/// window's top is already buried; the app catches up from it over P2P.
///
/// Usage:
///   dart run tool/build_header_checkpoint.dart \
///     --cdn build/cdn/mainnet --network mainnet \
///     --output build/checkpoint/mainnet.svhc [--window 200000]
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:libspiffy/src/spv/header_checkpoint.dart';
import 'package:libspiffy/src/spv/network_params.dart';
import 'package:spiffynode/spiffy_node.dart';

Future<void> main(List<String> args) async {
  final options = _parse(args);
  if (options == null) {
    stderr.writeln('Usage: dart run tool/build_header_checkpoint.dart --cdn <dir> --network mainnet|testnet '
        '--output <file.svhc> [--window 200000]');
    exit(64);
  }
  final cdn = options['cdn']!;
  final params = NetworkParams.forNetwork(options['network']!);
  final window = int.parse(options['window'] ?? '200000');
  final output = File(options['output']!);
  final stopwatch = Stopwatch()..start();

  final manifest = jsonDecode(File('$cdn/manifest.json').readAsStringSync()) as Map<String, dynamic>;
  if (manifest['network'] != params.name) {
    stderr.writeln('The package is for ${manifest['network']}, not ${params.name}');
    exit(1);
  }
  final chunks = [for (final c in manifest['chunks'] as List) c as Map<String, dynamic>]
    ..sort((a, b) => (a['startHeight'] as int).compareTo(b['startHeight'] as int));

  // Check the whole chain from genesis, keeping only the window's headers.
  final tipHeight = chunks.last['endHeight'] as int;
  final windowStart = tipHeight - window + 1;
  if (windowStart < 1) {
    stderr.writeln('The package holds $tipHeight headers above genesis, fewer than the window of $window');
    exit(1);
  }
  final kept = <BlockHeader>[];
  var previousHash = Uint8List.fromList(params.genesisHeader.blockHash().bytes);
  var expected = 1;
  for (final chunk in chunks) {
    final name = chunk['filename'] as String;
    final bytes = File('$cdn/$name').readAsBytesSync();
    if (crypto.sha256.convert(bytes).toString() != chunk['sha256']) {
      stderr.writeln('$name does not match the SHA-256 in the manifest');
      exit(1);
    }
    if (chunk['startHeight'] != expected || bytes.length % 80 != 0 ||
        bytes.length ~/ 80 != (chunk['endHeight'] as int) - expected + 1) {
      stderr.writeln('$name does not hold heights $expected-${chunk['endHeight']}');
      exit(1);
    }
    for (var at = 0; at < bytes.length; at += 80) {
      final raw = Uint8List.sublistView(bytes, at, at + 80);
      if (!_equal(Uint8List.sublistView(raw, 4, 36), previousHash)) {
        stderr.writeln('The header at height $expected does not link to the one before it');
        exit(1);
      }
      final hash = _sha256d(raw);
      final header = BlockHeader.deserialize(Uint8List.fromList(raw));
      final pow = params.checkProofOfWork(header.bits, Hash.fromBytes(hash).toString());
      if (pow.failure != null) {
        stderr.writeln('The header at height $expected fails its proof of work (${pow.failure!.name})');
        exit(1);
      }
      if (expected >= windowStart) kept.add(header);
      previousHash = hash;
      expected++;
    }
    stdout.writeln('  checked $name (${stopwatch.elapsed.inSeconds}s)');
  }

  final encoded = HeaderCheckpoint.encode(params.name, windowStart, kept);
  // Read it back exactly as the app will.
  final decoded = HeaderCheckpoint.decode(encoded, params);
  output.parent.createSync(recursive: true);
  output.writeAsBytesSync(encoded);
  stdout.writeln('Wrote ${output.path}: ${params.name} heights $windowStart-${decoded.tipHeight} '
      '(${decoded.headers.length} headers, ${encoded.length} bytes)');
  stdout.writeln('  checkpoint ${decoded.anchor.hash}');
  stdout.writeln('  newest     ${decoded.headers.last.blockHash()} '
      '(${decoded.headers.last.timestamp.toUtc().toIso8601String()})');
  stdout.writeln('  built from the package generated ${manifest['generatedAt']}, in ${stopwatch.elapsed.inSeconds}s');
}

Map<String, String>? _parse(List<String> args) {
  final options = <String, String>{};
  for (var i = 0; i + 1 < args.length; i += 2) {
    if (!args[i].startsWith('--')) return null;
    options[args[i].substring(2)] = args[i + 1];
  }
  for (final required in ['cdn', 'network', 'output']) {
    if (!options.containsKey(required)) return null;
  }
  return options;
}

Uint8List _sha256d(List<int> data) =>
    Uint8List.fromList(crypto.sha256.convert(crypto.sha256.convert(data).bytes).bytes);

bool _equal(List<int> a, List<int> b) {
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return a.length == b.length;
}
