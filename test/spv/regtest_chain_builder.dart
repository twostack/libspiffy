import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:libspiffy/src/spv/network_params.dart';
import 'package:libspiffy/src/utils/hex_utils.dart' as hex_utils;
import 'package:spiffynode/spiffy_node.dart';

/// Mines headers with real (but cheap) proof of work on top of any parent.
///
/// At the regtest pow limit (`0x207fffff`) roughly every second nonce
/// qualifies, so a header costs microseconds; harder targets are used to
/// give branches different amounts of work.
class RegtestMiner {
  RegtestMiner._();

  static const Duration spacing = Duration(minutes: 10);

  /// Mine one header on [parent].
  static BlockHeader mine({
    required BlockHeader parent,
    int? bits,
    DateTime? timestamp,
    int version = 1,
    String seed = '',
  }) {
    final b = bits ?? NetworkParams.regtest.powLimitBits;
    final target = NetworkParams.bitsToTarget(b);
    final ts = timestamp ?? parent.timestamp.add(spacing);
    final merkle = merkleRootFor('${parent.blockHash()}:$seed');
    var nonce = 0;
    while (true) {
      final h = BlockHeader(
        version: version,
        prevBlock: parent.blockHash(),
        merkleRoot: merkle,
        timestamp: ts,
        bits: b,
        nonce: nonce,
      );
      if (NetworkParams.hashToBigInt(h.blockHash().toString()) <= target) return h;
      nonce++;
    }
  }

  /// Mine [count] linked headers on [parent], spaced [spacing] apart.
  static List<BlockHeader> mineChain(
    BlockHeader parent,
    int count, {
    int? bits,
    Duration? spacing,
    String seed = '',
  }) {
    final out = <BlockHeader>[];
    var prev = parent;
    for (var i = 0; i < count; i++) {
      final h = mine(
        parent: prev,
        bits: bits,
        timestamp: prev.timestamp.add(spacing ?? RegtestMiner.spacing),
        seed: '$seed/$i',
      );
      out.add(h);
      prev = h;
    }
    return out;
  }

  /// A deterministic 32-byte merkle root derived from [seed].
  static Hash merkleRootFor(String seed) =>
      Hash.fromBytes(Uint8List.fromList(sha256.convert(utf8.encode(seed)).bytes));

  /// Compact bits for a target [shift] bits harder than the regtest limit
  /// (each extra bit doubles the work per block).
  static int harderBits(int shift) =>
      NetworkParams.targetToBits(NetworkParams.regtest.powLimit >> shift);
}

/// Loads `test/data/*_headers.json` fixtures (`{height, hash, hex}` rows,
/// fetched from WhatsOnChain; each `hex` is the raw 80-byte header) as
/// (height, header) pairs in file order.
List<(int, BlockHeader)> loadHeaderFixture(String path) {
  final rows = json.decode(File(path).readAsStringSync()) as List<dynamic>;
  return rows.map((row) {
    final m = row as Map<String, dynamic>;
    final header = BlockHeader.deserialize(
        Uint8List.fromList(hex_utils.hexToBytes(m['hex'] as String)));
    if (header.blockHash().toString() != m['hash']) {
      throw StateError('fixture $path: header at ${m['height']} does not hash to ${m['hash']}');
    }
    return (m['height'] as int, header);
  }).toList();
}

/// The first seven mainnet headers from `test/data/first_7_headers.json`.
List<BlockHeader> loadFirstMainnetHeaders() {
  final rows = json.decode(File('test/data/first_7_headers.json').readAsStringSync()) as List;
  return rows.map((row) {
    final m = row as Map<String, dynamic>;
    final prev = (m['previousblockhash'] as String).isEmpty ? Hash.zero() : Hash.fromHex(m['previousblockhash'] as String);
    return BlockHeader(
      version: m['version'] as int,
      prevBlock: prev,
      merkleRoot: Hash.fromHex(m['merkleroot'] as String),
      timestamp: DateTime.fromMillisecondsSinceEpoch((m['time'] as int) * 1000),
      bits: int.parse(m['bits'] as String, radix: 16),
      nonce: m['nonce'] as int,
    );
  }).toList();
}
