import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:isar/isar.dart';
import 'package:test/test.dart';

import 'package:libspiffy/libspiffy.dart';

import '../integration/isar_test_helper.dart';

/// Starting P2P from peer entries (libspiffy 3.0.1): a name is dialled at
/// every address it holds, the start goes on at the first peer that answers
/// rather than waiting out a dead one, and a start that reaches no one names
/// every address and why.
///
/// Everything runs on loopback: a node that completes the version handshake,
/// and one that accepts a connection and never says anything, which is what
/// half of `testnet-seed.bitcoinsv.io`'s addresses did on 2026-09-25.
void main() {
  setUpAll(() async {
    await ensureIsarInitialized();
  });

  late Directory tempDir;
  late Isar isar;
  late _Node node;
  late ServerSocket silent;
  final held = <Socket>[];

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('libspiffy_p2p_start_');
    isar = await Isar.open(
      LibSpiffySchemas.allSchemas,
      directory: tempDir.path,
      name: 'p2p_start_${DateTime.now().microsecondsSinceEpoch}',
    );
    node = await _Node.start();
    silent = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    silent.listen(held.add);
  });

  tearDown(() async {
    await node.close();
    for (final s in held) {
      s.destroy();
    }
    held.clear();
    await silent.close();
    if (isar.isOpen) await isar.close();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  Future<LibSpiffyActorSystem> start(List<String> peers) async {
    final libspiffy = LibSpiffyActorSystem();
    await libspiffy.initialize(
      isar: isar,
      dataDirectory: tempDir.path,
      secureStorage: InMemorySecureStorage(),
      networkType: 'regtest',
      enableP2P: true,
      peerAddresses: peers,
    );
    return libspiffy;
  }

  test('the start goes on at the first peer, not after a silent one times out', () async {
    final sw = Stopwatch()..start();
    final libspiffy = await start(['127.0.0.1:${silent.port}', '127.0.0.1:${node.port}']);
    sw.stop();
    try {
      expect(node.handshakes, 1);
      // spiffynode's handshake timeout is 10 s; waiting for every dial took
      // at least that
      expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
      expect(held, isNotEmpty, reason: 'the silent node was dialled too');
    } finally {
      await libspiffy.shutdown();
    }
  });

  test('a name is dialled at every address it holds', () async {
    // localhost holds 127.0.0.1, where the node listens, and on most
    // machines ::1 as well, where nothing does
    final libspiffy = await start(['localhost:${node.port}']);
    try {
      expect(node.handshakes, 1);
    } finally {
      await libspiffy.shutdown();
    }
  });

  test('a start that reaches no one names every address, and why', () async {
    final libspiffy = LibSpiffyActorSystem();
    try {
      await expectLater(
        libspiffy.initialize(
          isar: isar,
          dataDirectory: tempDir.path,
          secureStorage: InMemorySecureStorage(),
          networkType: 'regtest',
          enableP2P: true,
          peerAddresses: ['127.0.0.1:1', '127.0.0.1:2', 'no-such-host.invalid:18444', 'no-port'],
        ),
        throwsA(isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('any of 2 address(es) from 4 peer(s)'),
              contains('127.0.0.1:1: '),
              contains('127.0.0.1:2: '),
              contains('no-such-host.invalid:18444: the name does not resolve'),
              contains('no-port: not host:port'),
            ))),
      );
    } finally {
      await libspiffy.shutdown();
    }
  });
}

/// A regtest node that answers the version handshake, and nothing else.
class _Node {
  static const _magic = [0xda, 0xb5, 0xbf, 0xfa];

  final ServerSocket _server;
  final List<Socket> _sockets = [];
  int handshakes = 0;

  _Node._(this._server) {
    _server.listen((socket) {
      _sockets.add(socket);
      var answered = false;
      socket.listen((_) {
        if (answered) return;
        answered = true;
        handshakes++;
        // then a ping, as a real node follows its verack with more: spiffynode
        // 1.1.0 completes a message with no payload only when bytes follow it
        socket
          ..add(_message('version', _version()))
          ..add(_message('verack', Uint8List(0)))
          ..add(_message('ping', Uint8List(8)));
      }, onError: (_) {});
    });
  }

  static Future<_Node> start() async => _Node._(await ServerSocket.bind(InternetAddress.loopbackIPv4, 0));

  int get port => _server.port;

  Future<void> close() async {
    for (final s in _sockets) {
      s.destroy();
    }
    await _server.close();
  }

  static Uint8List _message(String command, Uint8List payload) {
    final checksum = sha256.convert(sha256.convert(payload).bytes).bytes.sublist(0, 4);
    final b = BytesBuilder()
      ..add(_magic)
      ..add([...command.codeUnits, ...List.filled(12 - command.length, 0)])
      ..add((ByteData(4)..setUint32(0, payload.length, Endian.little)).buffer.asUint8List())
      ..add(checksum)
      ..add(payload);
    return b.toBytes();
  }

  static Uint8List _version() {
    Uint8List le(int value, int bytes) {
      final d = ByteData(8)..setUint64(0, value, Endian.little);
      return d.buffer.asUint8List(0, bytes);
    }

    final address = [...le(0, 8), ...List.filled(10, 0), 0xff, 0xff, 0, 0, 0, 0, 0, 0];
    const agent = '/fake-node:0.1/';
    return Uint8List.fromList([
      ...le(70016, 4), // protocol version
      ...le(0, 8), // services
      ...le(DateTime.now().millisecondsSinceEpoch ~/ 1000, 8),
      ...address, // receiver
      ...address, // sender
      ...le(1, 8), // nonce
      agent.length, ...agent.codeUnits,
      ...le(0, 4), // start height
      0, // relay
    ]);
  }
}
