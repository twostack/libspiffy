/// A payment channel run end to end on a real BSV regtest network, against a
/// real ARC: the localnet stack in `../localnet` (node RPC :18332, node P2P
/// :18333, ARC :9090).
///
/// Two complete LibSpiffyActorSystem instances, client Alice and server Bob,
/// sync their headers from the regtest node over P2P and broadcast through
/// ARC. Their channel messages travel through an in-process relay, JSON
/// encoded as a wire would carry them. Nothing is mocked below the
/// coordinator: every transaction the channel makes is accepted or refused
/// by the node, and every answer the library acts on is ARC's own.
///
/// Tagged `localnet` and skipped by default (dart_test.yaml); run with
///   dart test -P localnet test/integration/localnet_channel_e2e_test.dart
/// It mines blocks on the shared regtest chain, as `../localnet/scripts`
/// do.
@Tags(['localnet'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dactor/dactor.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:http/http.dart' as http;
import 'package:isar/isar.dart';
import 'package:test/test.dart';

import 'package:libspiffy/coordinator.dart';
import 'package:libspiffy/libspiffy.dart';
import 'package:libspiffy/src/core/channel_events.dart' show RefundClaimedEvent;
import 'package:libspiffy/src/models/payment_channel.dart' show PaymentChannelState;

import 'isar_test_helper.dart';
import 'p2p_test_helpers.dart' show kTestXpriv, kTestRootAddress;

const _arcUrl = 'http://localhost:9090/v1';
const _rpcUrl = 'http://localhost:18332';
const _nodePeer = '127.0.0.1:18333';

/// Bob's wallet: a fixed mnemonic, so the test is deterministic.
const _bobMnemonic = 'abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon abandon abandon about';

// ---------------------------------------------------------------------------
// The regtest node
// ---------------------------------------------------------------------------

final _rpcAuth = 'Basic ${base64Encode(utf8.encode('bitcoin:bitcoin'))}';

/// Calls the regtest node's JSON-RPC [method].
Future<dynamic> _rpc(String method, [List<dynamic> params = const []]) async {
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
Future<int> _mine([int count = 1]) async {
  final address = await _rpc('getnewaddress') as String;
  await _rpc('generatetoaddress', [count, address]);
  return await _rpc('getblockcount') as int;
}

/// Why the localnet stack cannot run this test, or null when it can.
Future<String?> _localnetProblem() async {
  try {
    final health = await http
        .get(Uri.parse('$_arcUrl/health'))
        .timeout(const Duration(seconds: 3));
    if (health.statusCode != 200 ||
        (jsonDecode(health.body) as Map)['healthy'] != true) {
      return 'ARC at $_arcUrl is not healthy: ${health.body}';
    }
    final chain = await _rpc('getblockchaininfo') as Map<String, dynamic>;
    if (chain['chain'] != 'regtest') return 'the node runs ${chain['chain']}';
    return null;
  } catch (e) {
    return 'localnet is not reachable: $e';
  }
}

/// A mined transaction of the regtest chain as a BEEF carrying its merkle
/// proof, taken from the node.
Future<List<int>> _minedBeef(String txid) async {
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

// ---------------------------------------------------------------------------
// A libspiffy node on the regtest network
// ---------------------------------------------------------------------------

class _Node {
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
  /// [_link]).
  final Set<String> drop = {};

  _Node(this.peerId, this.dir, this.isar, this.timing);

  ActorRef get coordinator => system.coordinator;

  static Future<_Node> start(String peerId, ChannelTiming timing) async {
    final dir = await Directory.systemTemp.createTemp('localnet_${peerId}_');
    final isar = await Isar.open(
      LibSpiffySchemas.allSchemas,
      directory: dir.path,
      name: '${peerId}_${DateTime.now().microsecondsSinceEpoch}',
    );
    final node = _Node(peerId, dir, isar, timing);
    await node._boot();
    return node;
  }

  Future<void> _boot() async {
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
      arcConfig: const ArcServiceConfig(baseUrl: _arcUrl),
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

/// Delivers [from]'s outgoing channel messages to [to], JSON encoded and
/// decoded as a wire would carry them, in the order sent.
void _link(_Node from, _Node to) {
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

Future<void> _createWallet(_Node node, String walletId,
    {String? xpriv, String? mnemonic}) async {
  final created = node.next<WalletCreatedEvent>((e) => e.walletId == walletId);
  node.coordinator.tell(CreateWalletCommand(
    walletId: walletId,
    name: walletId,
    xpriv: xpriv,
    mnemonic: mnemonic,
  ));
  final event = await created;
  expect(event.success, isTrue, reason: event.error);
}

/// ARC's status of [txid], or null when ARC has never seen it.
Future<String?> _arcStatus(String txid) async {
  final response = await http.get(Uri.parse('$_arcUrl/tx/$txid'));
  if (response.statusCode == 404) return null;
  return (jsonDecode(response.body) as Map)['txStatus'] as String?;
}

/// Mines blocks until the chain's median time past (what the network holds
/// a time lock to) is at or after [unix].
Future<int> _mineUntilMedianTime(int unix) async {
  while (true) {
    final info = await _rpc('getblockchaininfo') as Map<String, dynamic>;
    if ((info['mediantime'] as int) >= unix) return info['blocks'] as int;
    await _mine();
    await Future<void>.delayed(const Duration(milliseconds: 1100));
  }
}

/// Waits until the wall clock is past [unix].
Future<void> _until(int unix) async {
  final wait = unix * 1000 - DateTime.now().millisecondsSinceEpoch + 1000;
  if (wait > 0) await Future<void>.delayed(Duration(milliseconds: wait));
}

void main() {
  late _Node alice;
  late _Node bob;
  String? unavailable;

  /// A short but real channel timing: payments stop and the server settles
  /// 30 seconds before the lock time; a channel must run two minutes.
  final timing = ChannelTiming(
    settlementMargin: Duration(seconds: 30),
    minimumLifetime: Duration(minutes: 2),
  );

  setUpAll(() async {
    unavailable = await _localnetProblem();
    if (unavailable != null) return;
    await ensureIsarInitialized();
  });

  setUp(() async {
    if (unavailable != null) markTestSkipped(unavailable!);
    if (unavailable != null) return;
    alice = await _Node.start('alice-peer', timing);
    bob = await _Node.start('bob-peer', timing);
    _link(alice, bob);
    _link(bob, alice);
  });

  tearDown(() async {
    if (unavailable != null) return;
    await alice.stop();
    await bob.stop();
  });

  /// Bob accepts every channel request, for [bobWallet].
  void autoAccept(String bobWallet) {
    bob.wire(() => bob.subs.add(bob.system.coordinatorEvents!
        .where((e) => e is ChannelRequestReceivedEvent)
        .cast<ChannelRequestReceivedEvent>()
        .listen((r) => bob.coordinator.tell(AcceptChannelCommand(
              channelId: r.channelId,
              walletId: bobWallet,
              clientPeerId: r.clientPeerId,
              clientPubKey: r.clientPubKey,
              clientAddress: r.clientAddress,
              fundingAmountSats: r.fundingAmountSats,
              lockTimeUnix: r.lockTimeUnix,
            )))));
  }

  /// Creates Alice's and Bob's wallets, sends Alice [bsv] on the regtest
  /// chain, mines it and imports it into her wallet with its proof. Returns
  /// the two wallet ids.
  Future<(String, String)> fundedWallets({double bsv = 0.01}) async {
    final ts = DateTime.now().microsecondsSinceEpoch;
    final aliceWallet = 'alice-$ts';
    final bobWallet = 'bob-$ts';
    await _createWallet(alice, aliceWallet, xpriv: kTestXpriv);
    await _createWallet(bob, bobWallet, mnemonic: _bobMnemonic);

    final txid = await _rpc('sendtoaddress', [kTestRootAddress, bsv]) as String;
    final height = await _mine();
    await alice.headersAt(height);
    await bob.headersAt(height);

    final imported =
        alice.next<TransactionImportedEvent>((e) => e.walletId == aliceWallet);
    alice.coordinator.tell(ImportTransactionCommand(
        walletId: aliceWallet, beef: await _minedBeef(txid)));
    final event = await imported;
    expect(event.success, isTrue, reason: event.error);
    expect(event.transactionId, txid);
    return (aliceWallet, bobWallet);
  }

  /// Opens a channel of [amount] from [aliceWallet] to Bob and returns its
  /// id once both sides report it open.
  Future<String> openChannel(String aliceWallet, int amount,
      {int lockTimeDurationSeconds = 3600}) async {
    final aliceOpened = alice.next<ChannelOpenedEvent>((_) => true);
    final bobOpened = bob.next<ChannelOpenedEvent>((_) => true);
    alice.coordinator.tell(OpenChannelCommand(
      walletId: aliceWallet,
      serverPeerId: bob.peerId,
      fundingAmountSats: amount,
      lockTimeDurationSeconds: lockTimeDurationSeconds,
    ));
    try {
      final (a, b) = (await aliceOpened, await bobOpened);
      expect(b.channelId, a.channelId);
      expect(b.fundingTxId, a.fundingTxId);
      return a.channelId;
    } on TimeoutException {
      fail('The open stalled.\nAlice:\n  ${alice.trace()}\n'
          'Bob:\n  ${bob.trace()}');
    }
  }

  /// Alice pays [amount] over [channelId]; returns once both sides
  /// recorded payment [sequence].
  Future<void> pay(String channelId, String aliceWallet, int amount,
      int sequence) async {
    final alicePaid = alice.next<ChannelPaymentEvent>(
        (e) => e.channelId == channelId && e.sequence == sequence);
    final bobPaid = bob.next<ChannelPaymentEvent>(
        (e) => e.channelId == channelId && e.sequence == sequence);
    alice.coordinator.tell(ChannelPayCommand(
        channelId: channelId, walletId: aliceWallet, amountSats: amount));
    try {
      await alicePaid;
      await bobPaid;
    } on TimeoutException {
      fail('Payment $sequence stalled.\nAlice:\n  ${alice.trace()}\n'
          'Bob:\n  ${bob.trace()}');
    }
  }

  /// The regtest node's view of [txid]: verbose, with `confirmations` once
  /// mined; null when the node has never seen it.
  Future<Map<String, dynamic>?> onNode(String txid) async {
    try {
      return await _rpc('getrawtransaction', [txid, 1]) as Map<String, dynamic>;
    } on StateError {
      return null;
    }
  }

  test('alice syncs regtest headers and imports a mined payment with its proof',
      () async {
    if (unavailable != null) return;
    final tip = await _rpc('getblockcount') as int;
    await alice.headersAt(tip);
    await fundedWallets();
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('open, pay three times, close: the settlement Bob broadcasts is mined and pays each side its balance',
      () async {
    if (unavailable != null) return;
    final (aliceWallet, bobWallet) = await fundedWallets();
    autoAccept(bobWallet);

    const funding = 100000;
    final channelId = await openChannel(aliceWallet, funding);
    final aliceRow = (await alice.system.walletStorage.getPaymentChannel(channelId))!;
    final fundingTxId = aliceRow.fundingTxId!;
    expect(await onNode(fundingTxId), isNotNull,
        reason: 'the funding transaction ARC accepted is not on the node');

    await pay(channelId, aliceWallet, 10000, 1);
    await pay(channelId, aliceWallet, 5000, 2);
    await pay(channelId, aliceWallet, 2500, 3);

    final aliceClosed = alice.next<ChannelClosedEvent>((e) => e.channelId == channelId);
    final bobClosed = bob.next<ChannelClosedEvent>((e) => e.channelId == channelId);
    alice.coordinator.tell(CloseChannelCommand(channelId: channelId));
    final ChannelClosedEvent a, b;
    try {
      (a, b) = (await aliceClosed, await bobClosed);
    } on TimeoutException {
      fail('The close stalled.\nAlice:\n  ${alice.trace()}\n'
          'Bob:\n  ${bob.trace()}');
    }
    final settlementTxId = b.settlementTxId!;
    expect(a.settlementTxId, settlementTxId);

    // The node has the settlement Bob broadcast: it spends the funding
    // output and pays Bob 17,500 and Alice what is left after the fee.
    final settlement = (await onNode(settlementTxId))!;
    final input = (settlement['vin'] as List).single as Map;
    expect(input['txid'], fundingTxId);
    final bobRow = (await bob.system.walletStorage.getPaymentChannel(channelId))!;
    final paid = <String, int>{
      for (final o in (settlement['vout'] as List).cast<Map>())
        ((o['scriptPubKey'] as Map)['addresses'] as List).single as String:
            ((o['value'] as num) * 1e8).round(),
    };
    expect(paid[bobRow.serverAddressB58], 17500, reason: '$paid');
    expect(paid[aliceRow.clientAddressB58], lessThan(funding - 17500));
    expect(paid[aliceRow.clientAddressB58], greaterThan(funding - 17500 - 1000));

    final height = await _mine();
    expect((await onNode(fundingTxId))!['confirmations'], greaterThan(0));
    expect((await onNode(settlementTxId))!['confirmations'], greaterThan(0));
    await alice.headersAt(height);

    expect(alice.events.whereType<ErrorEvent>(), isEmpty, reason: alice.trace());
    expect(bob.events.whereType<ErrorEvent>(), isEmpty, reason: bob.trace());
  }, timeout: const Timeout(Duration(minutes: 5)));

  /// The refund Alice holds for [channelId]: its txid and lock time.
  Future<(String, int)> aliceRefund(String channelId) async {
    final row = (await alice.system.walletStorage.getPaymentChannel(channelId))!;
    return (dartsv.Transaction.fromHex(row.refundTxHex!).id, row.lockTimeUnix);
  }

  Future<ChannelRefundClaimedEvent> claimRefund(String channelId) {
    final claimed =
        alice.next<ChannelRefundClaimedEvent>((e) => e.channelId == channelId);
    alice.coordinator.tell(ClaimChannelRefundCommand(channelId: channelId));
    return claimed;
  }

  test('Bob settles by himself at the margin before the lock time, and the settlement is mined',
      () async {
    if (unavailable != null) return;
    final (aliceWallet, bobWallet) = await fundedWallets();
    autoAccept(bobWallet);

    final channelId =
        await openChannel(aliceWallet, 50000, lockTimeDurationSeconds: 150);
    await pay(channelId, aliceWallet, 7000, 1);
    final (_, lockTime) = await aliceRefund(channelId);

    // Nobody closes: Bob's timer settles at lockTime - 30 s.
    final aliceClosed = alice.next<ChannelClosedEvent>(
        (e) => e.channelId == channelId, timeout: const Duration(minutes: 3));
    final bobClosed = bob.next<ChannelClosedEvent>(
        (e) => e.channelId == channelId, timeout: const Duration(minutes: 3));
    final (a, b) = (await aliceClosed, await bobClosed);
    final settledAt = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    expect(settledAt, lessThan(lockTime - 20),
        reason: 'settled ${lockTime - settledAt} s before the lock time');
    expect(a.settlementTxId, b.settlementTxId);

    final settlement = (await onNode(b.settlementTxId!))!;
    expect(settlement['locktime'], 0);
    await _mine();
    expect((await onNode(b.settlementTxId!))!['confirmations'], greaterThan(0));
    expect(bob.events.whereType<ErrorEvent>(), isEmpty, reason: bob.trace());
  }, timeout: const Timeout(Duration(minutes: 6)));

  test('with Bob gone, Alice claims her refund only once the network would take it, and it is mined',
      () async {
    if (unavailable != null) return;
    final (aliceWallet, bobWallet) = await fundedWallets();
    autoAccept(bobWallet);
    final channelId =
        await openChannel(aliceWallet, 40000, lockTimeDurationSeconds: 150);
    await pay(channelId, aliceWallet, 4000, 1);
    await bob.halt();
    final (refundTxId, lockTime) = await aliceRefund(channelId);

    // Before the lock time the claim is refused, and the refund is not
    // handed to the network at all.
    final early = await claimRefund(channelId);
    expect(early.success, isFalse);
    expect(await _arcStatus(refundTxId), isNull,
        reason: 'the refund went to ARC before its lock time');

    // Past the lock time on the clock, the chain's median time still trails
    // it: the node would hold the refund as non-final, and drop it for any
    // final spend of the funding output. Refused, and nothing broadcast.
    await _until(lockTime);
    final tooSoon = await claimRefund(channelId);
    expect(tooSoon.success, isFalse);
    expect(tooSoon.error, contains('median time past'));
    expect(await _arcStatus(refundTxId), isNull);

    // Once the median time has passed the lock time, and Alice's headers
    // show it, the claim goes through and the refund is mined.
    await alice.headersAt(await _mineUntilMedianTime(lockTime + 1));
    final claimed = await claimRefund(channelId);
    expect(claimed.success, isTrue, reason: claimed.error);
    expect(claimed.refundTxId, refundTxId);
    await _mine();
    expect((await onNode(refundTxId))!['confirmations'], greaterThan(0));
  }, timeout: const Timeout(Duration(minutes: 6)));

  test('a refund claimed after Bob\'s settlement was mined is refused as the orphan the network holds it as, and nothing is recorded as claimed',
      () async {
    if (unavailable != null) return;
    final (aliceWallet, bobWallet) = await fundedWallets();
    autoAccept(bobWallet);
    final channelId =
        await openChannel(aliceWallet, 30000, lockTimeDurationSeconds: 150);
    await pay(channelId, aliceWallet, 3000, 1);

    // Bob settles at the margin; Alice never hears of it.
    bob.drop.add('channel_closed');
    final bobClosed = await bob.next<ChannelClosedEvent>(
        (e) => e.channelId == channelId, timeout: const Duration(minutes: 3));
    final (refundTxId, lockTime) = await aliceRefund(channelId);
    await _until(lockTime);
    await alice.headersAt(await _mineUntilMedianTime(lockTime + 1));

    final claimed = await claimRefund(channelId);
    expect(claimed.success, isFalse,
        reason: 'the settlement ${bobClosed.settlementTxId} spent the funding '
            'output in a block; the node cannot connect the refund');
    expect(claimed.error, contains('orphan'));
    final row = (await alice.system.walletStorage.getPaymentChannel(channelId))!;
    expect(row.state, isNot(PaymentChannelState.closed));
    final journal = await alice.system.eventStore
        .getEvents('PaymentChannel_$channelId');
    expect(journal.map((e) => e.typeName), isNot(contains(RefundClaimedEvent.stableTypeName)));
    expect(await onNode(refundTxId), isNull);
  }, timeout: const Timeout(Duration(minutes: 6)));

  test('Bob, back only after Alice claimed her refund, finds his settlement contested and records no close',
      () async {
    if (unavailable != null) return;
    final (aliceWallet, bobWallet) = await fundedWallets();
    autoAccept(bobWallet);
    final channelId =
        await openChannel(aliceWallet, 20000, lockTimeDurationSeconds: 150);
    await pay(channelId, aliceWallet, 2000, 1);

    // Bob is down through his margin and the lock time; Alice takes her
    // refund once the network would take it.
    await bob.halt();
    final (refundTxId, lockTime) = await aliceRefund(channelId);
    await _until(lockTime);
    await alice.headersAt(await _mineUntilMedianTime(lockTime + 1));
    final claimed = await claimRefund(channelId);
    expect(claimed.success, isTrue, reason: claimed.error);

    // Bob comes back: his startup settles the channel he still holds open,
    // and his app closes it too, at once. The refund was first. ARC answers
    // the first submission of his settlement DOUBLE_SPEND_ATTEMPTED and the
    // second, which arrives while it is still deciding, with an in-flight
    // status: neither is a settlement the network holds, and Bob records no
    // close (bead libspiffy-jh6a; he used to close on the second answer).
    await bob.restart();
    bob.coordinator.tell(CloseChannelCommand(channelId: channelId));
    bool contested() => bob.events
        .whereType<ErrorEvent>()
        .any((e) => e.message.contains('contested'));
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (!contested() && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    expect(contested(), isTrue, reason: 'Bob:\n  ${bob.trace()}');
    // Both closes answered; neither closed.
    await Future<void>.delayed(const Duration(seconds: 5));
    expect(bob.events.whereType<ChannelClosedEvent>(), isEmpty,
        reason: 'Bob:\n  ${bob.trace()}');
    expect(bob.events.whereType<ErrorEvent>(), hasLength(2),
        reason: 'Bob:\n  ${bob.trace()}');
    final row = (await bob.system.walletStorage.getPaymentChannel(channelId))!;
    expect(row.state, PaymentChannelState.closing);

    await _mine();
    expect((await onNode(refundTxId))!['confirmations'], greaterThan(0));
  }, timeout: const Timeout(Duration(minutes: 6)));
}
