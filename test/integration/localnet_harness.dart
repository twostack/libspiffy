/// The pieces every localnet test shares: the regtest node's RPC, ARC's
/// view of a transaction, and [LocalnetNode], a complete
/// LibSpiffyActorSystem that syncs headers from the regtest node over P2P
/// and broadcasts through the real ARC.
///
/// The localnet stack lives in `../localnet` (node RPC :18332, node P2P
/// :18333, ARC :9090). Tests that use it are tagged `localnet`, skipped by
/// default (dart_test.yaml), and run with
///   dart test -P localnet test/integration/localnet_<flow>_e2e_test.dart
/// They mine blocks on the shared regtest chain, as `../localnet/scripts`
/// do.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dactor/dactor.dart';
import 'package:http/http.dart' as http;
import 'package:isar/isar.dart';
import 'package:logging/logging.dart' as logging;
import 'package:test/test.dart';

import 'package:libspiffy/coordinator.dart';
import 'package:libspiffy/libspiffy.dart';

const arcUrl = 'http://localhost:9090/v1';
const _rpcUrl = 'http://localhost:18332';
const _nodePeer = '127.0.0.1:18333';

/// A fixed mnemonic, so a test's second wallet is deterministic.
const bobMnemonic = 'abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon abandon abandon about';

// ---------------------------------------------------------------------------
// The regtest node and ARC
// ---------------------------------------------------------------------------

final _rpcAuth = 'Basic ${base64Encode(utf8.encode('bitcoin:bitcoin'))}';

/// Calls the regtest node's JSON-RPC [method].
Future<dynamic> rpc(String method, [List<dynamic> params = const []]) async {
  final response = await http.post(
    Uri.parse(_rpcUrl),
    headers: {'Content-Type': 'application/json', 'Authorization': _rpcAuth},
    body: jsonEncode({'jsonrpc': '1.0', 'id': 1, 'method': method, 'params': params}),
  );
  final body = jsonDecode(response.body) as Map<String, dynamic>;
  if (body['error'] != null) throw StateError('RPC $method: ${body['error']}');
  return body['result'];
}

/// Mines [count] blocks and returns the new height.
Future<int> mine([int count = 1]) async {
  final address = await rpc('getnewaddress') as String;
  await rpc('generatetoaddress', [count, address]);
  return await rpc('getblockcount') as int;
}

/// Why the localnet stack cannot run a test, or null when it can.
Future<String?> localnetProblem() async {
  try {
    final health = await http
        .get(Uri.parse('$arcUrl/health'))
        .timeout(const Duration(seconds: 3));
    if (health.statusCode != 200 ||
        (jsonDecode(health.body) as Map)['healthy'] != true) {
      return 'ARC at $arcUrl is not healthy: ${health.body}';
    }
    final chain = await rpc('getblockchaininfo') as Map<String, dynamic>;
    if (chain['chain'] != 'regtest') return 'the node runs ${chain['chain']}';
    return null;
  } catch (e) {
    return 'localnet is not reachable: $e';
  }
}

/// A mined transaction of the regtest chain as a BEEF carrying its merkle
/// proof, taken from the node.
Future<List<int>> minedBeef(String txid) async {
  final source = NodeRpcDataSource(
      rpcUrl: _rpcUrl, rpcUser: 'bitcoin', rpcPassword: 'bitcoin');
  final proof = await source.getMerkleProof(txid);
  final raw = await source.getRawTransaction(txid);
  final bump = BUMP.fromTscProof(
    blockHeight: proof.blockHeight,
    txid: txid,
    index: proof.index,
    nodes: proof.nodes,
  );
  return BEEF.create(
    bumps: [bump],
    txs: [_bytes(raw)],
    hasMerkle: [true],
    bumpIndex: [0],
  ).serialize();
}

Uint8List _bytes(String hex) => Uint8List.fromList([
      for (var i = 0; i < hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16)
    ]);

/// ARC's status of [txid], or null when ARC has never seen it.
Future<String?> arcStatus(String txid) async {
  final response = await http.get(Uri.parse('$arcUrl/tx/$txid'));
  if (response.statusCode == 404) return null;
  return (jsonDecode(response.body) as Map)['txStatus'] as String?;
}

/// Waits until ARC reports [txid] as [status]. ARC's status query reads
/// its store, which trails the status that answered a submission by a
/// moment.
Future<void> arcReports(String txid, String status,
    {Duration timeout = const Duration(seconds: 10)}) async {
  final deadline = DateTime.now().add(timeout);
  var last = await arcStatus(txid);
  while (last != status && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 200));
    last = await arcStatus(txid);
  }
  expect(last, status, reason: 'ARC\'s status of $txid');
}

/// The regtest node's view of [txid]: verbose, with `confirmations` once
/// mined; null when the node has never seen it.
Future<Map<String, dynamic>?> onNode(String txid) async {
  try {
    return await rpc('getrawtransaction', [txid, 1]) as Map<String, dynamic>;
  } on StateError {
    return null;
  }
}

/// Mines blocks until the chain's median time past (what the network holds
/// a time lock to) is at or after [unix].
Future<int> mineUntilMedianTime(int unix) async {
  while (true) {
    final info = await rpc('getblockchaininfo') as Map<String, dynamic>;
    if ((info['mediantime'] as int) >= unix) return info['blocks'] as int;
    await mine();
    await Future<void>.delayed(const Duration(milliseconds: 1100));
  }
}

/// Waits until the wall clock is past [unix].
Future<void> until(int unix) async {
  final wait = unix * 1000 - DateTime.now().millisecondsSinceEpoch + 1000;
  if (wait > 0) await Future<void>.delayed(Duration(milliseconds: wait));
}

// ---------------------------------------------------------------------------
// A libspiffy node on the regtest network
// ---------------------------------------------------------------------------

class LocalnetNode {
  final String peerId;
  final Directory dir;
  final Isar isar;
  final ChannelTiming timing;
  final InMemorySecureStorage secureStorage = InMemorySecureStorage();
  late LocalActorSystem actorSystem;
  late LibSpiffyActorSystem system;
  final List<CoordinatorEvent> events = [];
  final StreamController<CoordinatorEvent> _events =
      StreamController<CoordinatorEvent>.broadcast();
  final List<StreamSubscription> subs = [];
  bool running = false;

  /// Re-applied to every incarnation of [system] (see [restart]).
  final List<void Function()> _wiring = [];

  /// Outgoing channel messages of these types are lost on the way (see
  /// [link]).
  final Set<String> drop = {};

  var _queries = 0;

  LocalnetNode._(this.peerId, this.dir, this.isar, this.timing);

  ActorRef get coordinator => system.coordinator;

  static Future<LocalnetNode> start(String peerId, ChannelTiming timing) async {
    _printLogsWhenAsked();
    final dir = await Directory.systemTemp.createTemp('localnet_${peerId}_');
    final isar = await Isar.open(
      LibSpiffySchemas.allSchemas,
      directory: dir.path,
      name: '${peerId}_${DateTime.now().microsecondsSinceEpoch}',
    );
    final node = LocalnetNode._(peerId, dir, isar, timing);
    await node._boot();
    return node;
  }

  /// The node runs in a zone that names it, so its log records say whose
  /// they are (see [_printLogsWhenAsked]).
  Future<void> _boot() => runZoned(_bootInZone, zoneValues: {#localnetNode: peerId});

  Future<void> _bootInZone() async {
    actorSystem = LocalActorSystem(ActorSystemConfig());
    system = LibSpiffyActorSystem();
    await system.initialize(
      actorSystem: actorSystem,
      isar: isar,
      dataDirectory: dir.path,
      secureStorage: secureStorage,
      networkType: 'regtest',
      enableP2P: true,
      peerAddresses: [_nodePeer],
      arcConfig: const ArcServiceConfig(baseUrl: arcUrl),
      channelPeerId: peerId,
      channelTiming: timing,
    );
    subs.add(system.coordinatorEvents!.listen((e) {
      events.add(e);
      _events.add(e);
    }));
    for (final w in _wiring) {
      w();
    }
    running = true;
  }

  /// Subscribes [wire] now and again after every [restart].
  void wire(void Function() wire) {
    _wiring.add(wire);
    wire();
  }

  /// This node's process stops; its journal and key store remain.
  Future<void> halt() async {
    if (!running) return;
    running = false;
    for (final s in subs) {
      await s.cancel();
    }
    subs.clear();
    await system.shutdown();
  }

  /// A process restart over the same journal, read models and key store.
  Future<void> restart() async {
    await halt();
    await _boot();
  }

  /// The next event of type [T] that passes [test].
  Future<T> next<T extends CoordinatorEvent>(bool Function(T) test,
          {Duration timeout = const Duration(seconds: 60)}) =>
      _events.stream
          .where((e) => e is T && test(e))
          .cast<T>()
          .first
          .timeout(timeout);

  /// Waits until this node's header chain reaches [height].
  Future<void> headersAt(int height,
      {Duration timeout = const Duration(seconds: 120)}) async {
    final deadline = DateTime.now().add(timeout);
    while (system.headerChain.bestHeight < height) {
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException('$peerId has headers to '
            '${system.headerChain.bestHeight}, not $height');
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }

  Future<void> createWallet(String walletId,
      {String? xpriv, String? mnemonic}) async {
    final created = next<WalletCreatedEvent>((e) => e.walletId == walletId);
    coordinator.tell(CreateWalletCommand(
      walletId: walletId,
      name: walletId,
      xpriv: xpriv,
      mnemonic: mnemonic,
    ));
    final event = await created;
    expect(event.success, isTrue, reason: event.error);
  }

  /// [walletId]'s balance, as the coordinator answers it.
  Future<BalanceResponse> balance(String walletId) {
    final queryId = '$peerId-balance-${_queries++}';
    final answer = next<BalanceResponse>((e) => e.queryId == queryId);
    coordinator.tell(GetBalanceQuery(walletId: walletId, queryId: queryId));
    return answer;
  }

  /// [txid] as [walletId]'s history holds it, or null when it does not.
  Future<BitcoinTransaction?> transaction(String walletId, String txid) async {
    final queryId = '$peerId-tx-${_queries++}';
    final answer = next<TransactionDetailResponse>((e) => e.queryId == queryId);
    coordinator.tell(GetTransactionDetailQuery(
        walletId: walletId, txid: txid, queryId: queryId));
    return (await answer).transaction;
  }

  /// Sends [bsv] from the node's wallet to [address], mines it, and imports
  /// it into [walletId] with its merkle proof once this node holds the
  /// block's header. Returns the txid.
  Future<String> receiveMined(String walletId, String address,
      {double bsv = 0.01}) async {
    final txid = await rpc('sendtoaddress', [address, bsv]) as String;
    await headersAt(await mine());
    final imported =
        next<TransactionImportedEvent>((e) => e.walletId == walletId);
    coordinator.tell(
        ImportTransactionCommand(walletId: walletId, beef: await minedBeef(txid)));
    final event = await imported;
    expect(event.success, isTrue, reason: event.error);
    expect(event.transactionId, txid);
    return txid;
  }

  /// What happened on this node, for failure messages.
  String trace() => events
      .where((e) => e is ChannelP2PMessageToSendEvent || e is ErrorEvent)
      .map((e) => switch (e) {
            ChannelP2PMessageToSendEvent m => 'sent ${m.messageType}',
            ErrorEvent m => 'error ${m.source}: ${m.message}',
            _ => '$e',
          })
      .join('\n  ');

  Future<void> stop() async {
    await halt();
    await _events.close();
    await isar.close();
    if (await dir.exists()) await dir.delete(recursive: true);
  }
}

/// With `LOCALNET_LOG=1` in the environment, the library's log records
/// (INFO and above) are printed, for reading what a failing run did.
void _printLogsWhenAsked() {
  if (_printingLogs || Platform.environment['LOCALNET_LOG'] != '1') return;
  _printingLogs = true;
  logging.Logger.root.level = logging.Level.INFO;
  logging.Logger.root.onRecord.listen((r) =>
      print('${r.time.toIso8601String().substring(11, 23)} '
          '[${r.zone?[#localnetNode] ?? '-'}] ${r.level.name} '
          '${r.loggerName}: ${r.message}'));
}

var _printingLogs = false;

/// Delivers [from]'s outgoing channel messages to [to], JSON encoded and
/// decoded as a wire would carry them, in the order sent.
void link(LocalnetNode from, LocalnetNode to) {
  from.wire(() => from.subs.add(from.system.coordinatorEvents!
          .where((e) => e is ChannelP2PMessageToSendEvent)
          .cast<ChannelP2PMessageToSendEvent>()
          .listen((m) {
        if (!to.running || from.drop.contains(m.messageType)) return;
        to.coordinator.tell(ChannelP2PReceived(
          fromPeerId: from.peerId,
          messageType: m.messageType,
          payload: (jsonDecode(jsonEncode(m.payload)) as Map)
              .cast<String, dynamic>(),
        ));
      })));
}
