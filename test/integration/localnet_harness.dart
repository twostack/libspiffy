/// The pieces every localnet test shares: the regtest Teranode, Arcade's
/// view of a transaction, and [LocalnetNode], a complete
/// LibSpiffyActorSystem that syncs headers from Teranode over P2P and
/// broadcasts through Arcade.
///
/// The stack is `../localnet-teranode` (its CONSUMING.md): Arcade :23011
/// (the ARC API, no `/v1`), Teranode's RPC :19292, its DataHub :18090 and
/// its wire protocol :18444; coins come from its faucet, sent through
/// Arcade so that Arcade has their proofs. `LOCALNET_TERANODE` names
/// another checkout. Tests that use it are tagged `localnet`, skipped by
/// default (dart_test.yaml), and run with
///   `dart test -P localnet test/integration/localnet_<flow>_e2e_test.dart`
/// They mine blocks on the shared regtest chain, as its scripts do.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dactor/dactor.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:http/http.dart' as http;
import 'package:isar_community/isar.dart';
import 'package:logging/logging.dart' as logging;
import 'package:test/test.dart';

import 'package:libspiffy/coordinator.dart';
import 'package:libspiffy/libspiffy.dart';

const arcUrl = 'http://127.0.0.1:23011';
const _arcHealthUrl = 'http://127.0.0.1:23012/health';
const _rpcUrl = 'http://127.0.0.1:19292';
const _dataHub = 'http://127.0.0.1:18090/api/v1';
const _nodePeer = '127.0.0.1:18444';

/// The localnet-teranode checkout: its `.env` holds the RPC credentials and
/// the faucet's address, and its faucet sends coins.
final _stackDir = Platform.environment['LOCALNET_TERANODE'] ?? '../localnet-teranode';

/// A fixed mnemonic, so a test's second wallet is deterministic.
const bobMnemonic = 'abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon abandon abandon about';

// ---------------------------------------------------------------------------
// Teranode and Arcade
// ---------------------------------------------------------------------------

/// `KEY=value` lines of the stack's [name] file.
Map<String, String> _envFile(String name) {
  final file = File('$_stackDir/$name');
  if (!file.existsSync()) return const {};
  return {
    for (final line in file.readAsLinesSync())
      if (RegExp(r'^[A-Za-z_][A-Za-z0-9_]*=').hasMatch(line))
        line.substring(0, line.indexOf('=')): line.substring(line.indexOf('=') + 1),
  };
}

final Map<String, String> _env = {..._envFile('.env'), ..._envFile('miner.env')};

/// Calls Teranode's JSON-RPC [method].
Future<dynamic> rpc(String method, [List<dynamic> params = const []]) async {
  final auth = base64Encode(utf8.encode('${_env['rpc_user']}:${_env['rpc_pass']}'));
  final response = await http.post(
    Uri.parse(_rpcUrl),
    headers: {'Content-Type': 'application/json', 'Authorization': 'Basic $auth'},
    body: jsonEncode({'jsonrpc': '1.0', 'id': 1, 'method': method, 'params': params}),
  );
  final body = jsonDecode(response.body) as Map<String, dynamic>;
  if (body['error'] != null) throw StateError('RPC $method: ${body['error']}');
  return body['result'];
}

/// A DataHub JSON answer, or null on 404.
Future<Map<String, dynamic>?> _dataHubJson(String path) async {
  final response = await http.get(Uri.parse('$_dataHub/$path'));
  if (response.statusCode == 404) return null;
  if (response.statusCode != 200) {
    throw StateError('DataHub $path: ${response.statusCode} ${response.body}');
  }
  return jsonDecode(response.body) as Map<String, dynamic>;
}

/// The chain's tip height. From the DataHub, which has a block as soon as it
/// is mined (Teranode's `getblockchaininfo` trails it by a few seconds, and
/// its `getblockcount` is not implemented).
Future<int> tipHeight() async =>
    (await _dataHubJson('bestblockheader/json'))!['height'] as int;

/// Mines [count] blocks, paying the faucet, and returns the height of the
/// last one mined.
///
/// Not the tip: the chain is shared, and anything else on it can mine
/// between the block this asks for and the answer.
Future<int> mine([int count = 1]) async {
  final mined = await rpc('generatetoaddress', [count, _env['MINER_ADDRESS']]) as List;
  return heightOf(mined.last as String);
}

/// The height of the block [hash].
Future<int> heightOf(String hash) async =>
    (await rpc('getblockheader', [hash]) as Map<String, dynamic>)['height']
        as int;

/// Why the localnet stack cannot run a test, or null when it can.
Future<String?> localnetProblem() async {
  try {
    if (_env['rpc_user'] == null || _env['MINER_ADDRESS'] == null) {
      return 'no RPC credentials or faucet address in $_stackDir/.env and miner.env';
    }
    final health = await http.get(Uri.parse(_arcHealthUrl)).timeout(const Duration(seconds: 3));
    if (health.statusCode != 200) return 'Arcade is not healthy: ${health.body.trim()}';
    final chain = await rpc('getblockchaininfo') as Map<String, dynamic>;
    if (chain['chain'] != 'regtest') return 'the node runs ${chain['chain']}';
    return null;
  } catch (e) {
    return 'localnet-teranode is not reachable: $e';
  }
}

/// Sends [satoshis] from the stack's faucet to [address] through Arcade, so
/// that Arcade follows it to its proof. Returns its txid and raw hex.
Future<({String txid, String rawHex})> faucetSend(String address, int satoshis) async {
  final result = await Process.run('go', ['run', '.', 'send', address, '$satoshis', '--arcade'],
      workingDirectory: '$_stackDir/faucet');
  final out = '${result.stdout}';
  final txid = RegExp(r'^txid ([0-9a-f]{64})$', multiLine: true).firstMatch(out)?.group(1);
  final rawHex = RegExp(r'^hex\s+([0-9a-f]+)$', multiLine: true).firstMatch(out)?.group(1);
  if (result.exitCode != 0 || txid == null || rawHex == null) {
    throw StateError('faucet send failed (${result.exitCode}): $out ${result.stderr}');
  }
  return (txid: txid, rawHex: rawHex);
}

/// A mined transaction as a BEEF carrying the merkle proof Arcade built for
/// it. Arcade has proofs only of transactions submitted to it.
Future<List<int>> minedBeef(String txid, String rawHex,
    {Duration timeout = const Duration(seconds: 30)}) async {
  final deadline = DateTime.now().add(timeout);
  while (true) {
    final response = await http.get(Uri.parse('$arcUrl/tx/$txid'));
    if (response.statusCode == 200) {
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final path = body['merklePath'] as String?;
      if (body['txStatus'] == 'MINED' && path != null && path.isNotEmpty) {
        return BEEF.create(
          bumps: [BUMP.fromHex(path)],
          txs: [_bytes(rawHex)],
          hasMerkle: [true],
          bumpIndex: [0],
        ).serialize();
      }
    }
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Arcade has no merkle path for $txid: ${response.body}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
}

Uint8List _bytes(String hex) => Uint8List.fromList([
      for (var i = 0; i < hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16)
    ]);

/// Arcade's status of [txid], or null when Arcade has never been given it.
Future<String?> arcStatus(String txid) async {
  final response = await http.get(Uri.parse('$arcUrl/tx/$txid'));
  if (response.statusCode == 404) return null;
  return (jsonDecode(response.body) as Map)['txStatus'] as String?;
}

/// Waits until Arcade reports [txid] as [status].
Future<void> arcReports(String txid, String status,
    {Duration timeout = const Duration(seconds: 20)}) async {
  final deadline = DateTime.now().add(timeout);
  var last = await arcStatus(txid);
  while (last != status && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 200));
    last = await arcStatus(txid);
  }
  expect(last, status, reason: 'Arcade\'s status of $txid');
}

/// Waits until Arcade reports the network holding [txid]: `SEEN_ON_NETWORK`
/// (a miner put it in a subtree), or anything after it.
Future<void> arcHolds(String txid,
    {Duration timeout = const Duration(seconds: 20)}) async {
  const held = {'SEEN_ON_NETWORK', 'SEEN_MULTIPLE_NODES', 'MINED', 'IMMUTABLE'};
  final deadline = DateTime.now().add(timeout);
  var last = await arcStatus(txid);
  while (!held.contains(last) && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 200));
    last = await arcStatus(txid);
  }
  expect(last, isIn(held), reason: 'Arcade\'s status of $txid');
}

/// The hash of the block Arcade says [txid] is in; null when Arcade does
/// not have it in a block, or has never been given it.
Future<String?> arcBlock(String txid) async {
  final response = await http.get(Uri.parse('$arcUrl/tx/$txid'));
  if (response.statusCode == 404) return null;
  final hash = (jsonDecode(response.body) as Map)['blockHash'] as String?;
  return hash == null || hash.isEmpty ? null : hash;
}

/// Waits until Arcade answers for [txid] with [blockHash].
///
/// After a reorganization Arcade moves the transaction back to
/// SEEN_ON_NETWORK and proves it again once Merkle Service sees it in a
/// block of the new branch. With [mineWhileWaiting] the chain is kept
/// moving meanwhile, as a live one would be.
Future<void> arcProves(String txid, String blockHash,
    {Duration timeout = const Duration(minutes: 4),
    bool mineWhileWaiting = false}) async {
  final deadline = DateTime.now().add(timeout);
  const nudgeEvery = Duration(seconds: 15);
  var nudgeAt = DateTime.now().add(nudgeEvery);
  var last = await arcBlock(txid);
  while (last != blockHash && DateTime.now().isBefore(deadline)) {
    if (mineWhileWaiting && DateTime.now().isAfter(nudgeAt)) {
      await mine();
      nudgeAt = DateTime.now().add(nudgeEvery);
    }
    await Future<void>.delayed(const Duration(seconds: 1));
    last = await arcBlock(txid);
  }
  expect(last, blockHash,
      reason: 'Arcade has not caught up with the chain for $txid');
}

/// Teranode's view of [txid]: its raw transaction (`hex`), and `blockhash`
/// and `confirmations` of the active-chain block holding it (absent while
/// it is unmined); null when Teranode has never seen it. From the DataHub's transaction metadata,
/// which lists every block the transaction is in, of any branch.
Future<Map<String, dynamic>?> onNode(String txid) async {
  final meta = await _dataHubJson('txmeta/$txid/json');
  if (meta == null) return null;
  final hashes = (meta['blockHashes'] as List?)?.cast<String>() ?? const [];
  final heights = (meta['blockHeights'] as List?)?.cast<int>() ?? const [];
  for (var i = 0; i < hashes.length && i < heights.length; i++) {
    final active = await rpc('getblockhash', [heights[i]]) as String;
    if (active == hashes[i]) {
      return {
        'txid': txid,
        'hex': (meta['tx'] as Map)['hex'],
        'blockhash': hashes[i],
        'confirmations': await tipHeight() - heights[i] + 1,
      };
    }
  }
  return {'txid': txid, 'hex': (meta['tx'] as Map)['hex']};
}

/// [txid] as Teranode holds it; null when it has never seen it.
Future<dartsv.Transaction?> nodeTransaction(String txid) async {
  final rawHex = (await onNode(txid))?['hex'] as String?;
  return rawHex == null ? null : dartsv.Transaction.fromHex(rawHex);
}

/// The height of the block Teranode holds [txid] in on the active chain;
/// null when it is not in one. The chain's own answer, which is what a
/// wallet's recorded height has to agree with however the block was mined.
Future<int?> minedAt(String txid) async {
  final hash = (await onNode(txid))?['blockhash'] as String?;
  return hash == null ? null : await heightOf(hash);
}

/// Mines blocks until the chain's median time past (what the network holds
/// a time lock to) is at or after [unix]; returns the tip height.
Future<int> mineUntilMedianTime(int unix) async {
  while (true) {
    final info = await rpc('getblockchaininfo') as Map<String, dynamic>;
    if ((info['mediantime'] as int) >= unix) return tipHeight();
    await mine();
    await Future<void>.delayed(const Duration(milliseconds: 1100));
  }
}

/// Waits until the wall clock is past [unix].
Future<void> until(int unix) async {
  final wait = unix * 1000 - DateTime.now().millisecondsSinceEpoch + 1000;
  if (wait > 0) await Future<void>.delayed(Duration(milliseconds: wait));
}

/// [request]'s reply, also when it reports a failure: for a test that
/// asserts on a refusal's fields. A failure reported by an [ErrorEvent], a
/// coordinator that stopped, and a timeout still throw.
Future<R> answer<R extends CoordinatorReply>(WalletCoordinator coordinator, CoordinatorRequest<R> request,
        {Duration? timeout}) =>
    coordinator.ask(request, timeout: timeout).catchError(
        (Object failure) => (failure as CoordinatorFailure).event as R,
        test: (failure) => failure is CoordinatorFailure && failure.event is R);

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

  LocalnetNode._(this.peerId, this.dir, this.isar, this.timing);

  WalletCoordinator get coordinator => system.coordinator;

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
      arcConfig: ArcServiceConfig(baseUrl: arcUrl),
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
          {String? xpriv, String? mnemonic, String? xpub}) =>
      coordinator.ask(CreateWalletCommand(
        walletId: walletId,
        name: walletId,
        xpriv: xpriv,
        mnemonic: mnemonic,
        xpub: xpub,
      ));

  /// [walletId]'s balance, as the coordinator answers it.
  Future<BalanceResponse> balance(String walletId) =>
      coordinator.ask(GetBalanceQuery(walletId: walletId));

  /// [txid] as [walletId]'s history holds it, or null when it does not.
  Future<BitcoinTransaction?> transaction(String walletId, String txid) async =>
      (await coordinator.ask(GetTransactionDetailQuery(walletId: walletId, txid: txid)))
          .transaction;

  /// Sends [bsv] from the faucet to [address], mines it, and imports it
  /// into [walletId] with its merkle proof once this node holds the block's
  /// header. Returns the txid.
  Future<String> receiveMined(String walletId, String address,
      {double bsv = 0.01}) async {
    final sent = await faucetSend(address, (bsv * 100000000).round());
    final txid = sent.txid;
    // Mined only once a miner holds it: a block mined before it reaches a
    // subtree goes without it.
    await arcHolds(txid);
    await headersAt(await mine());
    final beef = await minedBeef(txid, sent.rawHex);
    final imported = await coordinator
        .ask(ImportTransactionCommand(walletId: walletId, beef: beef));
    expect(imported.transactionId, txid);
    return txid;
  }

  /// What happened on this node, for failure messages.
  String trace() => events
      .where((e) => e is P2PMessageToSendEvent || e is ErrorEvent)
      .map((e) => switch (e) {
            P2PMessageToSendEvent m => 'sent ${m.messageType}',
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
          .where((e) => e is P2PMessageToSendEvent)
          .cast<P2PMessageToSendEvent>()
          .listen((m) {
        if (!to.running || from.drop.contains(m.messageType)) return;
        to.coordinator.tell(P2PMessageReceived(
          fromPeerId: from.peerId,
          messageType: m.messageType,
          payload: (jsonDecode(jsonEncode(m.payload)) as Map)
              .cast<String, dynamic>(),
        ));
      })));
}
