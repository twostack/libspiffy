/// Callback tokens for the broadcast-bridge, checked byte for byte against
/// the bridge's own vectors (broadcast-bridge
/// internal/token/testdata/token_vectors.json, copied to test/data).
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:libspiffy/src/services/arc_service.dart' show ArcTransactionStatus;
import 'package:libspiffy/src/services/broadcast_callback.dart';
import 'package:test/test.dart';

Uint8List _hex(String s) =>
    Uint8List.fromList([for (var i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)]);
String _toHex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

/// The libp2p peer ID bytes of an Ed25519 public key.
Uint8List _peerIdBytes(List<int> pub) => Uint8List.fromList([0x00, 0x24, 0x08, 0x01, 0x12, 0x20, ...pub]);

class _SeedSigner implements CallbackTokenSigner {
  final SimpleKeyPair keyPair;
  @override
  final Uint8List peerIdBytes;
  _SeedSigner(this.keyPair, this.peerIdBytes);

  static Future<_SeedSigner> fromSeed(List<int> seed) async {
    final kp = await Ed25519().newKeyPairFromSeed(seed);
    return _SeedSigner(kp, _peerIdBytes((await kp.extractPublicKey()).bytes));
  }

  @override
  Future<Uint8List> sign(Uint8List message) async =>
      Uint8List.fromList((await Ed25519().sign(message, keyPair: keyPair)).bytes);
}

void main() {
  final vectors = (jsonDecode(File('test/data/broadcast_token_vectors.json').readAsStringSync()) as List)
      .cast<Map<String, dynamic>>();

  for (final v in vectors) {
    test('vector "${v['name']}": peer IDs, body and token match the bridge exactly', () async {
      final user = await _SeedSigner.fromSeed(_hex(v['userSeedHex'] as String));
      final bridge = await _SeedSigner.fromSeed(_hex(v['bridgeSeedHex'] as String));
      expect(_toHex(user.peerIdBytes), _toHex(decodePeerId(v['userPeerId'] as String)));
      expect(_toHex(bridge.peerIdBytes), _toHex(decodePeerId(v['bridgePeerId'] as String)));

      final txid = (v['txid'] as String).isEmpty ? null : v['txid'] as String;
      final body = callbackTokenBody(
        peerIdBytes: user.peerIdBytes,
        folder: v['folder'] as String,
        txid: txid,
        exp: v['exp'] as int,
        bridgePeerIdBytes: decodePeerId(v['bridgePeerId'] as String),
        net: v['net'] as String,
      );
      expect(_toHex(body), v['bodyHex']);

      final config = BroadcastCallbackConfig(
        callbackUrl: 'https://bridge.example/v1/callback/bsva',
        bridgePeerId: v['bridgePeerId'] as String,
        bridgeX25519PubHex: v['bridgeX25519PubHex'] as String,
        net: v['net'] as String,
        folder: v['folder'] as String,
      );
      // exp = now + ttl, so "now" is exp minus the default 30 days.
      final now = DateTime.fromMillisecondsSinceEpoch((v['exp'] as int) * 1000).subtract(config.tokenTtl);
      final token = await mintCallbackToken(
          config: config, signer: user, txid: txid, now: now, random: _hex(v['randHex'] as String));
      expect(token, v['token']);
    });
  }

  test('a token minted without test inputs differs every time', () async {
    final user = await _SeedSigner.fromSeed(List.filled(32, 7));
    final config = BroadcastCallbackConfig.bridgeTestnet();
    final a = await mintCallbackToken(config: config, signer: user, txid: 'ab' * 32);
    final b = await mintCallbackToken(config: config, signer: user, txid: 'ab' * 32);
    expect(a, startsWith('bb1.'));
    expect(a, isNot(b));
  });

  group('the envelope', () {
    List<int> envelope(Map<String, dynamic> m) => utf8.encode(jsonEncode(m));
    final item = {
      'txid': 'ab' * 32,
      'txStatus': 'MINED',
      'status': 200,
      'timestamp': '2026-11-08T14:03:11Z',
      'blockHash': '00' * 32,
      'blockHeight': 921034,
      'merklePath': 'fe00',
      'extraInfo': '',
      'competingTxs': <String>[],
      'source': 'https://arcade-v2-us-1.bsvblockchain.tech',
    };

    test('every item is read, with its Broadcaster', () {
      final items = parseBroadcastStatusEnvelope(
          envelope({'v': 1, 'type': 'bsv.tx-status', 'net': 'main', 'items': [item, item]}), net: 'main');
      expect(items, hasLength(2));
      expect(items!.first.status.txid, 'ab' * 32);
      expect(items.first.status.status, ArcTransactionStatus.mined);
      expect(items.first.source, 'https://arcade-v2-us-1.bsvblockchain.tech');
    });

    test('another version, type or network, or not JSON, is refused', () {
      for (final bad in [
        envelope({'v': 2, 'type': 'bsv.tx-status', 'net': 'main', 'items': [item]}),
        envelope({'v': 1, 'type': 'other', 'net': 'main', 'items': [item]}),
        envelope({'v': 1, 'type': 'bsv.tx-status', 'net': 'test', 'items': [item]}),
        utf8.encode('not json'),
      ]) {
        expect(parseBroadcastStatusEnvelope(bad, net: 'main'), isNull);
      }
    });
  });
}
