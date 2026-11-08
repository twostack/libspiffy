/// Transaction status pushed to the device instead of polled (the
/// broadcast-bridge, spiffyvault-js `broadcast-bridge/doc/LIBSPIFFY_HANDOFF.md`).
///
/// The Broadcaster (Arcade) calls a webhook when a transaction is mined or
/// rejected. The webhook is the broadcast-bridge, which puts the update into
/// the user's Ricochet mailbox; the app's Ricochet push hands it to
/// [parseBroadcastStatusEnvelope]. Each submission carries a callback token
/// ([mintCallbackToken]) that tells the bridge whose mailbox to deliver to,
/// signed by the user's Ricochet identity key and encrypted to the bridge.
///
/// Nothing in a callback is trusted: a MINED status is applied only when its
/// merkle path checks against our own block header (ARCActor).
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cbor/cbor.dart';
import 'package:cryptography/cryptography.dart';

import 'arc_service.dart' show ArcTransactionResponse;

/// Signs callback tokens with the user's Ricochet identity key. The app
/// implements it over the key its Ricochet client uses: libspiffy never
/// holds that key.
abstract interface class CallbackTokenSigner {
  /// The user's Ricochet peer ID as multihash bytes (38 bytes for an
  /// Ed25519 key: `00 24 08 01 12 20` then the 32-byte public key).
  Uint8List get peerIdBytes;

  /// An Ed25519 signature of [message] by the user's Ricochet identity key.
  Future<Uint8List> sign(Uint8List message);
}

/// Where status callbacks go for one network.
class BroadcastCallbackConfig {
  /// The bridge's callback endpoint; its last path segment names the
  /// Broadcaster submitted to (`…/v1/callback/bsva`).
  final String callbackUrl;

  /// The bridge's Ricochet peer ID: the only sender whose messages are
  /// accepted, and the peer the mailbox grants write access.
  final String bridgePeerId;

  /// The bridge's X25519 public key, hex: tokens are encrypted to it.
  final String bridgeX25519PubHex;

  /// `main` or `test`: must match the bridge's network.
  final String net;

  /// The mailbox folder the bridge delivers to.
  final String folder;

  /// How long a token is valid; at most 30 days.
  final Duration tokenTtl;

  BroadcastCallbackConfig({
    required this.callbackUrl,
    required this.bridgePeerId,
    required this.bridgeX25519PubHex,
    required this.net,
    this.folder = 'bsv/tx-status',
    this.tokenTtl = const Duration(days: 30),
  }) {
    if (tokenTtl > const Duration(days: 30) || tokenTtl <= Duration.zero) {
      throw ArgumentError.value(tokenTtl, 'tokenTtl', 'must be positive and at most 30 days');
    }
    if (net != 'main' && net != 'test') throw ArgumentError.value(net, 'net', 'must be main or test');
    if (_hexDecode(bridgeX25519PubHex).length != 32) {
      throw ArgumentError.value(bridgeX25519PubHex, 'bridgeX25519PubHex', 'is not 32 bytes of hex');
    }
    if (!callbackUrl.startsWith('https://')) {
      throw ArgumentError.value(callbackUrl, 'callbackUrl', 'must be https');
    }
    decodePeerId(bridgePeerId);
  }

  /// The testnet bridge while it is being verified (handoff §7 config).
  static BroadcastCallbackConfig bridgeTestnet() => BroadcastCallbackConfig(
        callbackUrl: 'https://bridge-us-west.overnode.net/v1/callback/bsva',
        bridgePeerId: '12D3KooWSuFiHw5WRBPy3JyUurXnEYshzZUj1VVDhPk1ZyNYmpZ9',
        bridgeX25519PubHex: 'd3a165edd7395a4faf7c514c704446351d8a7dc1e88df6aa5e0bec36dc28ee51',
        net: 'test',
      );
}

final _domain = utf8.encode('broadcast-bridge/token/v1');

/// The token body (handoff §2.2): a CBOR map with integer keys 0–6, in
/// order. [txid] is the txid as displayed (hex), or null for a token a
/// batch shares.
Uint8List callbackTokenBody({
  required Uint8List peerIdBytes,
  required String folder,
  required String? txid,
  required int exp,
  required Uint8List bridgePeerIdBytes,
  required String net,
}) {
  final txidBytes = txid == null ? null : _hexDecode(txid);
  if (txidBytes != null && txidBytes.length != 32) throw ArgumentError.value(txid, 'txid', 'is not 32 bytes');
  final body = CborMap({
    CborSmallInt(0): CborSmallInt(1),
    CborSmallInt(1): CborBytes(peerIdBytes),
    CborSmallInt(2): CborString(folder),
    CborSmallInt(3): txidBytes == null ? const CborNull() : CborBytes(txidBytes),
    CborSmallInt(4): CborInt(BigInt.from(exp)),
    CborSmallInt(5): CborBytes(bridgePeerIdBytes),
    CborSmallInt(6): CborString(net),
  });
  return Uint8List.fromList(cbor.encode(body));
}

/// A callback token for one submission (handoff §2): `bb1.` and the
/// unpadded base64url of `01 ‖ ephemeral X25519 key ‖ nonce ‖ ciphertext`.
///
/// [txid] binds the token to one transaction; null for a batch. [now] and
/// [random] are for tests: [random] is 44 bytes, the ephemeral X25519 seed
/// then the nonce. A fresh token per submission is what keeps tokens
/// unlinkable to each other.
Future<String> mintCallbackToken({
  required BroadcastCallbackConfig config,
  required CallbackTokenSigner signer,
  required String? txid,
  DateTime? now,
  Uint8List? random,
}) async {
  final exp = (now ?? DateTime.now()).add(config.tokenTtl).millisecondsSinceEpoch ~/ 1000;
  final body = callbackTokenBody(
    peerIdBytes: signer.peerIdBytes,
    folder: config.folder,
    txid: txid,
    exp: exp,
    bridgePeerIdBytes: decodePeerId(config.bridgePeerId),
    net: config.net,
  );
  final sig = await signer.sign(Uint8List.fromList([..._domain, ...body]));
  if (sig.length != 64) throw StateError('the signer returned ${sig.length} bytes, not an Ed25519 signature');
  final plain = cbor.encode(CborList([CborBytes(body), CborBytes(sig)]));

  final rand = random ?? _secureRandom(44);
  if (rand.length != 44) throw ArgumentError.value(random, 'random', 'must be 44 bytes');
  final bridgePub = _hexDecode(config.bridgeX25519PubHex);
  final x25519 = X25519();
  final eph = await x25519.newKeyPairFromSeed(rand.sublist(0, 32));
  final ephPub = (await eph.extractPublicKey()).bytes;
  final shared = await x25519.sharedSecretKey(
    keyPair: eph,
    remotePublicKey: SimplePublicKey(bridgePub, type: KeyPairType.x25519),
  );
  final key = await Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
    secretKey: shared,
    nonce: [...ephPub, ...bridgePub],
    info: _domain,
  );
  final nonce = rand.sublist(32, 44);
  final box = await Chacha20.poly1305Aead().encrypt(plain, secretKey: key, nonce: nonce, aad: const [0x01]);

  final raw = <int>[0x01, ...ephPub, ...nonce, ...box.cipherText, ...box.mac.bytes];
  return 'bb1.${base64Url.encode(raw).replaceAll('=', '')}';
}

/// One status the bridge delivered: an `ArcTransactionResponse` and the
/// Broadcaster that answered.
typedef BroadcastStatusItem = ({ArcTransactionResponse status, String? source});

/// The envelope the bridge delivers (handoff §5.2), or null when it is not
/// one this wallet takes: another version or type, another network, or not
/// JSON at all. [net] is the wallet's network (`main` or `test`).
List<BroadcastStatusItem>? parseBroadcastStatusEnvelope(List<int> payload, {required String net}) {
  final Object? decoded;
  try {
    decoded = jsonDecode(utf8.decode(payload));
  } catch (_) {
    return null;
  }
  if (decoded is! Map || decoded['v'] != 1 || decoded['type'] != 'bsv.tx-status' || decoded['net'] != net) {
    return null;
  }
  final items = decoded['items'];
  if (items is! List) return null;
  final out = <BroadcastStatusItem>[];
  for (final item in items) {
    if (item is! Map) continue;
    final map = Map<String, dynamic>.from(item);
    if (map['txid'] is! String) continue;
    try {
      out.add((status: ArcTransactionResponse.fromJson(map), source: map['source'] as String?));
    } catch (_) {
      continue;
    }
  }
  return out;
}

/// The multihash bytes of a base58btc libp2p peer ID (`12D3KooW…`).
Uint8List decodePeerId(String peerId) {
  const alphabet = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';
  var value = BigInt.zero;
  for (final char in peerId.split('')) {
    final digit = alphabet.indexOf(char);
    if (digit < 0) throw ArgumentError.value(peerId, 'peerId', 'is not base58');
    value = value * BigInt.from(58) + BigInt.from(digit);
  }
  final bytes = <int>[];
  while (value > BigInt.zero) {
    bytes.insert(0, (value & BigInt.from(0xff)).toInt());
    value >>= 8;
  }
  for (final char in peerId.split('')) {
    if (char != '1') break;
    bytes.insert(0, 0);
  }
  if (bytes.length < 2) throw ArgumentError.value(peerId, 'peerId', 'is too short');
  return Uint8List.fromList(bytes);
}

Uint8List _hexDecode(String hex) {
  if (hex.length.isOdd) throw FormatException('odd-length hex: $hex');
  return Uint8List.fromList([
    for (var i = 0; i < hex.length; i += 2) int.parse(hex.substring(i, i + 2), radix: 16),
  ]);
}

Uint8List _secureRandom(int length) {
  final random = Random.secure();
  return Uint8List.fromList([for (var i = 0; i < length; i++) random.nextInt(256)]);
}
