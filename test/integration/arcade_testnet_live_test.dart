/// ArcService against the BSV Association's public testnet Arcade.
///
/// Arcade is the Teranode-era successor to ARC and serves an ARC-compatible
/// API. This checks that the calls ARCActor makes work against it. The
/// transaction it submits is one already mined on testnet, sent in Extended
/// Format with its parents read from WhatsOnChain, so nothing is spent.
///
///   dart test -P arcade test/integration/arcade_testnet_live_test.dart
@Tags(['arcade'])
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import 'package:libspiffy/src/services/arc_service.dart';
import 'package:libspiffy/src/services/arc_service_config.dart';
import 'package:libspiffy/src/utils/extended_format.dart';

const _woc = 'https://api.whatsonchain.com/v1/bsv/test';

Future<dynamic> _wocJson(String path) async {
  final response = await http.get(Uri.parse('$_woc$path'));
  if (response.statusCode != 200) {
    throw StateError('WhatsOnChain $path: ${response.statusCode} ${response.body}');
  }
  return jsonDecode(response.body);
}

Future<Uint8List> _wocRaw(String txid) async {
  final response = await http.get(Uri.parse('$_woc/tx/$txid/hex'));
  if (response.statusCode != 200) {
    throw StateError('WhatsOnChain tx $txid: ${response.statusCode}');
  }
  return Uint8List.fromList(hex.decode(response.body.trim()));
}

/// A small non-coinbase transaction from a recent testnet block, with the
/// transactions it spends.
Future<({String txid, Uint8List raw, Map<String, Uint8List> sources})> _recentTransaction() async {
  final info = await _wocJson('/chain/info') as Map<String, dynamic>;
  final tip = info['blocks'] as int;
  for (var height = tip - 1; height > tip - 6; height--) {
    final block = await _wocJson('/block/height/$height') as Map<String, dynamic>;
    final txids = (block['tx'] as List).cast<String>().skip(1);
    for (final txid in txids.take(10)) {
      final raw = await _wocRaw(txid);
      if (raw.length > 4000) continue;
      final sources = <String, Uint8List>{
        for (final parent in ExtendedFormat.spentTxids(raw).toSet()) parent: await _wocRaw(parent),
      };
      return (txid: txid, raw: raw, sources: sources);
    }
  }
  throw StateError('no small transaction in the last five testnet blocks');
}

void main() {
  late ArcService arc;

  setUp(() => arc = ArcService.fromConfig(ArcServiceConfig.bsvaArcadeTestnet()));
  tearDown(() => arc.dispose());

  test('health reports a healthy instance on testnet', () async {
    final health = await arc.getHealth();
    expect(health.healthy, isTrue);
  });

  test('policy parses, with a mining fee', () async {
    final policy = await arc.getPolicy();
    expect(policy.miningFee.satoshis, greaterThan(0));
    expect(policy.miningFee.bytes, greaterThan(0));
  });

  test('an unknown transaction is a 404 ARCActor reads as not found', () async {
    await expectLater(
      arc.getTransaction('00' * 32),
      throwsA(isA<ArcException>().having((e) => e.isNotFound, 'isNotFound', isTrue)),
    );
  });

  test('a transaction submitted in Extended Format is accepted and then known', () async {
    final tx = await _recentTransaction();
    final extended = ExtendedFormat.encode(tx.raw, tx.sources);
    expect(extended, isNotNull, reason: 'parents of ${tx.txid} were read');

    final submitted = await arc.submitTransaction(hex.encode(extended!));
    expect(submitted.txid, tx.txid);
    expect(submitted.status, isNot(ArcTransactionStatus.rejected), reason: submitted.message);

    final status = await arc.getTransaction(tx.txid);
    expect(status.txid, tx.txid);
    expect(status.status, isNot(ArcTransactionStatus.rejected), reason: status.message);
  });

  // Arcade's POST /txs takes only application/octet-stream (concatenated
  // transactions) and answers with counts, {submitted, duplicates, total},
  // not one status per transaction. submitBatchTransactions sends a JSON
  // array and expects that list. Nothing in libspiffy calls it.
  test('a batch submission is accepted', skip: 'Arcade /txs takes octet-stream and returns counts', () async {
    final tx = await _recentTransaction();
    final extended = ExtendedFormat.encode(tx.raw, tx.sources)!;
    final responses = await arc.submitBatchTransactions([hex.encode(extended)]);
    expect(responses.single.txid, tx.txid);
  });
}
