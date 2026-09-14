/// End-to-end payment channel open through the public coordinator API
/// (libspiffy-9fo).
///
/// Two complete LibSpiffyActorSystem instances (client Alice, server Bob) are
/// wired together by a loopback "transport": every
/// [ChannelP2PMessageToSendEvent] one coordinator emits is JSON round-tripped
/// and delivered to the other coordinator as [ChannelP2PReceived]. Nothing
/// below the coordinator is touched except funding Alice's wallet.
///
/// Client open, hop by hop:
///   OpenChannelCommand -> adapter -> InitiateChannelMessage (manager)
///   -> ChannelRequestedEvent (projection) -> channel_request -> Bob
///   Bob: ChannelRequestReceivedEvent -> AcceptChannelCommand
///   -> AcceptChannelMessage -> ChannelAcceptedEvent -> channel_accept -> Alice
///   Alice: RecordServerAcceptanceMessage + BuildFundingTransactionCommand
///   (wallet manager, sender = coordinator) -> FundingTransactionBuiltResponse
///   -> BuildRefundTransactionMessage (sender = coordinator): the refund is
///   signed by Alice and journaled with the funding transaction
///   (RefundBuiltEvent, libspiffy-b83)
///   -> RefundTransactionBuiltResponse -> refund_sign_request -> Bob
///   Bob: SignRefundTransactionMessage -> RefundCountersignedEvent
///   -> refund_signed -> Alice
///   Alice: RecordRefundSignatureMessage -> the signature is verified and the
///   fully signed refund journaled (RefundCountersignedEvent)
///   -> OpenChannelMessage -> FundingBroadcastStartedEvent -> funding recorded
///   in the wallet -> ARC broadcast -> inputs spent (libspiffy-9f7)
///   -> ChannelOpenedEvent -> channel_open -> Bob
///   Bob: OpenChannelMessage (funding output checked) -> ChannelOpenedEvent
///
/// Each node's ARC service is a [_RecordingArc]: nothing reaches a network.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:dactor/dactor.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:isar/isar.dart';
import 'package:test/test.dart';

import 'package:libspiffy/libspiffy.dart';
import 'package:libspiffy/coordinator.dart';
import 'package:libspiffy/src/actors/payment_channel_messages.dart'
    show OpenChannelMessage;
import 'package:libspiffy/src/core/channel_commands.dart'
    show ClaimRefundCommand;
import 'package:libspiffy/src/core/payment_channel_aggregate.dart';
import 'package:libspiffy/src/models/payment_channel.dart';
import 'package:eventador/eventador.dart' show Event;

import 'isar_test_helper.dart';
import 'p2p_test_helpers.dart';

const _alicePeer = 'alice-peer';
const _bobPeer = 'bob-peer';

class _Node {
  final String peerId;
  final Directory dir;
  final Isar isar;
  final InMemorySecureStorage secureStorage;

  /// The ARC service this node broadcasts through (no network).
  final _RecordingArc arc = _RecordingArc();

  /// Rewrites this node's outgoing channel messages (see [_link]).
  Future<Map<String, dynamic>> Function(
      String messageType, Map<String, dynamic> payload)? tamper;
  late LocalActorSystem actorSystem;
  late LibSpiffyActorSystem system;
  final List<CoordinatorEvent> events = [];
  final List<StreamSubscription> subs = [];

  /// Re-applied to every incarnation of [system] (see [restart]).
  final List<void Function()> _wiring = [];

  _Node(this.peerId, this.dir, this.isar, this.secureStorage);

  ActorRef get coordinator => system.coordinator;
  Stream<CoordinatorEvent> get stream => system.coordinatorEvents!;

  Future<T> next<T extends CoordinatorEvent>(bool Function(T) test,
          {Duration timeout = const Duration(seconds: 20)}) =>
      stream.where((e) => e is T && test(e)).cast<T>().first.timeout(timeout);

  /// Subscribes [wire] now and again after every [restart].
  void wire(void Function() wire) {
    _wiring.add(wire);
    wire();
  }

  /// What happened on this node, for failure messages.
  String trace() => events
      .where((e) =>
          e is ChannelP2PMessageToSendEvent ||
          e is ErrorEvent ||
          e is ChannelOpenedEvent ||
          e is ChannelRequestReceivedEvent)
      .map((e) => switch (e) {
            ChannelP2PMessageToSendEvent m => 'sent ${m.messageType}',
            ErrorEvent m => 'error ${m.source}: ${m.message}',
            ChannelOpenedEvent m => 'opened ${m.channelId} (${m.walletId})',
            ChannelRequestReceivedEvent m => 'request ${m.channelId}',
            _ => '$e',
          })
      .join('\n  ');

  static Future<_Node> start(String peerId) async {
    final dir = await Directory.systemTemp.createTemp('chan_e2e_${peerId}_');
    final isar = await Isar.open(
      LibSpiffySchemas.allSchemas,
      directory: dir.path,
      name: '${peerId}_${DateTime.now().microsecondsSinceEpoch}',
    );
    final node = _Node(peerId, dir, isar, InMemorySecureStorage());
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
      enableP2P: false,
      secureStorage: secureStorage,
      arcService: arc,
    );
    await setupTestHeaders(system.walletStorage as IsarWalletStorage);
    subs.add(stream.listen(events.add));
    for (final w in _wiring) {
      w();
    }
  }

  Future<void> _halt() async {
    for (final s in subs) {
      await s.cancel();
    }
    subs.clear();
    await system.shutdown();
  }

  /// A process restart: a new LibSpiffyActorSystem over the same journal,
  /// read models and key store.
  Future<void> restart() async {
    await _halt();
    await _boot();
  }

  Future<void> stop() async {
    await _halt();
    await isar.close();
    if (await dir.exists()) await dir.delete(recursive: true);
  }
}

/// Delivers [from]'s outgoing channel messages to [to], as a wire would
/// (JSON encoded and decoded).
///
/// [_Node.tamper] of [from], when set, may replace a payload in flight (a
/// misbehaving peer); messages are still delivered in the order sent.
void _link(_Node from, _Node to) {
  from.wire(() {
    var delivery = Future<void>.value();
    from.subs.add(from.stream
        .where((e) => e is ChannelP2PMessageToSendEvent)
        .cast<ChannelP2PMessageToSendEvent>()
        .listen((m) {
      expect(m.toPeerId, to.peerId,
          reason: '${from.peerId} addressed ${m.messageType} to ${m.toPeerId}');
      var payload =
          (jsonDecode(jsonEncode(m.payload)) as Map).cast<String, dynamic>();
      delivery = delivery.then((_) async {
        final tamper = from.tamper;
        if (tamper != null) payload = await tamper(m.messageType, payload);
        to.coordinator.tell(ChannelP2PReceived(
          fromPeerId: from.peerId,
          messageType: m.messageType,
          payload: payload,
        ));
      });
    }));
  });
}

Future<void> _createWallet(_Node node, String walletId,
    {String? xpriv, String? mnemonic}) async {
  final created = node.next<WalletCreatedEvent>((e) => e.walletId == walletId,
      timeout: const Duration(seconds: 10));
  node.coordinator.tell(CreateWalletCommand(
    walletId: walletId,
    name: walletId,
    xpriv: xpriv,
    mnemonic: mnemonic,
  ));
  final event = await created;
  expect(event.success, isTrue, reason: event.error);
}

/// The payload of the first [messageType] message [node] sent.
Map<String, dynamic> _sentPayload(_Node node, String messageType) => node.events
    .whereType<ChannelP2PMessageToSendEvent>()
    .firstWhere((m) => m.messageType == messageType)
    .payload;

/// Whether the server's refund signature (from `refund_signed`) is a valid
/// signature by the server's channel key (from `channel_accept`) over input 0
/// of the refund the client built (from `refund_sign_request`), spending the
/// 2-of-2 funding output.
bool _serverRefundSignatureValid(_Node client, _Node server, int amountSats) {
  final clientPub = dartsv.SVPublicKey.fromHex(
      _sentPayload(client, 'channel_request')['clientPubKey'] as String);
  final serverPub = dartsv.SVPublicKey.fromHex(
      _sentPayload(server, 'channel_accept')['serverPubKey'] as String);
  final refund = dartsv.Transaction.fromHex(
      _sentPayload(client, 'refund_sign_request')['refundTxHex'] as String);
  final signature = dartsv.SVSignature.fromTxFormat(
      _sentPayload(server, 'refund_signed')['serverSignatureHex'] as String);
  final redeemScript =
      dartsv.P2MSLockBuilder([clientPub, serverPub], 2, sorting: true)
          .getScriptPubkey();
  final sighash = dartsv.Sighash().hash(
      refund, signature.nhashtype, 0, redeemScript, BigInt.from(amountSats));
  return DartSVCryptoService().verifySignature(serverPub, signature,
      Uint8List.fromList(hex.decode(sighash).reversed.toList()));
}

/// An ARC service without a network: records every submitted transaction
/// and answers status queries from [statuses].
class _RecordingArc extends ArcService {
  _RecordingArc() : super(baseUrl: 'mock://arc');

  /// Raw hex of every submission, in order (failed ones included).
  final List<String> submitted = [];

  /// Runs at the moment of each submission, before it is answered.
  Future<void> Function(String rawTx)? onSubmit;

  /// Submissions fail while this is set.
  String? failWith;

  /// What a submission reports.
  ArcTransactionStatus submitStatus = ArcTransactionStatus.stored;

  /// What status queries report, by txid (unknown txids fail).
  final Map<String, ArcTransactionStatus> statuses = {};

  @override
  Future<ArcSubmitResponse> submitTransaction(String rawTx,
      {String? callbackUrl}) async {
    submitted.add(rawTx);
    await onSubmit?.call(rawTx);
    if (failWith != null) throw ArcException(failWith!);
    return ArcSubmitResponse(
        txid: dartsv.Transaction.fromHex(rawTx).id, status: submitStatus);
  }

  @override
  Future<ArcTransactionResponse> getTransaction(String txid) async {
    final status = statuses[txid];
    if (status == null) throw ArcException('unknown transaction $txid');
    return ArcTransactionResponse(txid: txid, status: status);
  }
}

/// Why [refundHex] is not a complete refund of the channel's funding
/// output, or null when it is: it spends output [fundingOutputIndex] of
/// [fundingTxHex] (a 2-of-2 of the two keys holding [amountSats]), carries
/// nLockTime [lockTimeUnix] with a non-final input sequence, and both
/// signatures satisfy the script interpreter.
String? _refundProblem({
  required String refundHex,
  required String fundingTxHex,
  required int fundingOutputIndex,
  required String clientPubKeyHex,
  required String serverPubKeyHex,
  required int amountSats,
  required int lockTimeUnix,
}) {
  try {
    final redeemScript = dartsv.P2MSLockBuilder([
      dartsv.SVPublicKey.fromHex(clientPubKeyHex),
      dartsv.SVPublicKey.fromHex(serverPubKeyHex),
    ], 2, sorting: true)
        .getScriptPubkey();
    final funding = dartsv.Transaction.fromHex(fundingTxHex);
    final fundingOutput = funding.outputs[fundingOutputIndex];
    if (fundingOutput.script.toHex() != redeemScript.toHex()) {
      return 'funding output $fundingOutputIndex is not the 2-of-2';
    }
    if (fundingOutput.satoshis != BigInt.from(amountSats)) {
      return 'funding output holds ${fundingOutput.satoshis}, not $amountSats';
    }
    final refund = dartsv.Transaction.fromHex(refundHex);
    if (refund.inputs.length != 1) return '${refund.inputs.length} inputs';
    final input = refund.inputs.single;
    if (input.prevTxnId != funding.id ||
        input.prevTxnOutputIndex != fundingOutputIndex) {
      return 'spends ${input.prevTxnId}:${input.prevTxnOutputIndex}';
    }
    if (refund.nLockTime != lockTimeUnix) {
      return 'nLockTime ${refund.nLockTime}, channel lockTime $lockTimeUnix';
    }
    if (input.sequenceNumber == dartsv.TransactionInput.MAX_SEQ_NUMBER) {
      return 'final input sequence: nLockTime is not enforced';
    }
    PaymentChannelBuilder(cryptoService: DartSVCryptoService())
        .verifyMultisigSpend(
      signedTx: refund,
      redeemScript: redeemScript,
      inputValueSats: BigInt.from(amountSats),
    );
    return null;
  } catch (e) {
    return '$e';
  }
}

/// [node]'s journal of [channelId], oldest first.
Future<List<Event>> _journal(_Node node, String channelId) =>
    node.system.eventStore.getEvents('PaymentChannel_$channelId');

/// Index of the first journaled event holding a complete refund of the
/// channel (any string field that passes [_refundProblem]), or -1.
int _completeRefundIndex(List<Event> journal, PaymentChannel row) {
  for (var i = 0; i < journal.length; i++) {
    for (final value in journal[i].toMap().values) {
      if (value is! String || value.length < 200) continue;
      if (_refundProblem(
            refundHex: value,
            fundingTxHex: row.fundingTxHex!,
            fundingOutputIndex: row.fundingOutputIndex!,
            clientPubKeyHex: row.clientPubKeyHex,
            serverPubKeyHex: row.serverPubKeyHex!,
            amountSats: row.fundingAmountSats.toInt(),
            lockTimeUnix: row.lockTimeUnix,
          ) ==
          null) {
        return i;
      }
    }
  }
  return -1;
}

/// Index of the first event of type [typeName] in [journal], or -1.
int _indexOfType(List<Event> journal, String typeName) =>
    journal.indexWhere((e) => e.typeName == typeName);

/// Why [row]'s stored refund is not complete, or null.
String? _storedRefundProblem(PaymentChannel? row) {
  if (row == null) return 'no channel row';
  if (row.refundTxHex == null) return 'refundTxHex is null';
  if (row.fundingTxHex == null || row.fundingTxHex!.isEmpty) {
    return 'no funding transaction stored';
  }
  return _refundProblem(
    refundHex: row.refundTxHex!,
    fundingTxHex: row.fundingTxHex!,
    fundingOutputIndex: row.fundingOutputIndex ?? 0,
    clientPubKeyHex: row.clientPubKeyHex,
    serverPubKeyHex: row.serverPubKeyHex ?? '',
    amountSats: row.fundingAmountSats.toInt(),
    lockTimeUnix: row.lockTimeUnix,
  );
}

/// Polls [condition] until it holds or [timeout] passes.
Future<bool> _eventually(Future<bool> Function() condition,
    {Duration timeout = const Duration(seconds: 10)}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (await condition()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  return condition();
}

void main() {
  late _Node alice;
  late _Node bob;

  setUpAll(() async {
    await ensureIsarInitialized();
  });

  setUp(() async {
    alice = await _Node.start(_alicePeer);
    bob = await _Node.start(_bobPeer);
    _link(alice, bob);
    _link(bob, alice);
  });

  tearDown(() async {
    await alice.stop();
    await bob.stop();
  });

  /// Bob accepts every channel request for [bobWalletId].
  void autoAccept(String bobWalletId) {
    bob.wire(() => bob.subs.add(bob.stream
            .where((e) => e is ChannelRequestReceivedEvent)
            .cast<ChannelRequestReceivedEvent>()
            .listen((r) {
          bob.coordinator.tell(AcceptChannelCommand(
            channelId: r.channelId,
            walletId: bobWalletId,
            clientPeerId: r.clientPeerId,
            clientPubKey: r.clientPubKey,
            clientAddress: r.clientAddress,
            fundingAmountSats: r.fundingAmountSats,
            lockTimeUnix: r.lockTimeUnix,
          ));
        })));
  }

  Future<(ChannelOpenedEvent, ChannelOpenedEvent)> openChannel(
      String aliceWalletId, int amount,
      {int lockTimeDurationSeconds = 86400}) async {
    final aliceOpened = alice.next<ChannelOpenedEvent>((_) => true);
    final bobOpened = bob.next<ChannelOpenedEvent>((_) => true);
    alice.coordinator.tell(OpenChannelCommand(
      walletId: aliceWalletId,
      serverPeerId: _bobPeer,
      fundingAmountSats: amount,
      lockTimeDurationSeconds: lockTimeDurationSeconds,
    ));
    try {
      return (await aliceOpened, await bobOpened);
    } on TimeoutException {
      fail('Channel open stalled.\nAlice:\n  ${alice.trace()}\n'
          'Bob:\n  ${bob.trace()}');
    }
  }

  /// Opens a 100000 sat channel from [aliceWalletId] and checks both sides
  /// report it open, for the right wallets, with every protocol step
  /// exchanged and no error.
  Future<void> openAndVerify(String aliceWalletId, String bobWalletId) async {
    final (aliceOpened, bobOpened) = await openChannel(aliceWalletId, 100000);

    expect(aliceOpened.channelId, bobOpened.channelId);
    expect(aliceOpened.walletId, aliceWalletId);
    expect(bobOpened.walletId, bobWalletId);
    expect(aliceOpened.fundingTxId, isNotNull);
    expect(aliceOpened.fundingTxId, hasLength(64));
    expect(bobOpened.fundingTxId, aliceOpened.fundingTxId);
    expect(aliceOpened.fundingAmountSats, 100000);
    expect(bobOpened.fundingAmountSats, 100000);

    // Every step was exchanged, in protocol order, and nothing failed.
    List<String> sent(_Node n) => n.events
        .whereType<ChannelP2PMessageToSendEvent>()
        .map((m) => m.messageType)
        .toList();
    expect(sent(alice),
        ['channel_request', 'refund_sign_request', 'channel_open']);
    expect(sent(bob), ['channel_accept', 'refund_signed']);
    expect(alice.events.whereType<ErrorEvent>(), isEmpty,
        reason: alice.trace());
    expect(bob.events.whereType<ErrorEvent>(), isEmpty, reason: bob.trace());

    // The server signed the client's refund with the accepting wallet's
    // channel key, so the client holds a refund it can complete.
    expect(_serverRefundSignatureValid(alice, bob, 100000), isTrue,
        reason: 'server refund signature does not verify against the server '
            'channel key');

    // Both read models agree the channel is open.
    final aliceRow = await alice.system.walletStorage
        .getPaymentChannel(aliceOpened.channelId);
    final bobRow =
        await bob.system.walletStorage.getPaymentChannel(bobOpened.channelId);
    expect(aliceRow?.state, PaymentChannelState.open);
    expect(aliceRow?.role, PaymentChannelRole.client);
    expect(aliceRow?.walletId, aliceWalletId);
    expect(bobRow?.state, PaymentChannelState.open);
    expect(bobRow?.role, PaymentChannelRole.server);
    expect(bobRow?.walletId, bobWalletId);
  }

  test('client open through the coordinator reaches open on both sides',
      () async {
    final ts = DateTime.now().microsecondsSinceEpoch;
    final aliceWalletId = 'alice-$ts';
    final bobWalletId = 'bob-$ts';

    await _createWallet(alice, aliceWalletId, xpriv: kTestXpriv);
    await _createWallet(bob, bobWalletId,
        mnemonic: await DartSVCryptoService().generateMnemonic());
    await fundWallet(
      walletManager: alice.system.walletManager,
      actorSystem: alice.actorSystem,
      walletId: aliceWalletId,
      amount: BigInt.from(200000000),
    );
    autoAccept(bobWalletId);

    await openAndVerify(aliceWalletId, bobWalletId);
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('opens from a wallet that is not the last one created, on both sides',
      () async {
    final ts = DateTime.now().microsecondsSinceEpoch;
    final aliceWalletId = 'alice-$ts';
    final bobWalletId = 'bob-$ts';

    await _createWallet(alice, aliceWalletId, xpriv: kTestXpriv);
    await fundWallet(
      walletManager: alice.system.walletManager,
      actorSystem: alice.actorSystem,
      walletId: aliceWalletId,
      amount: BigInt.from(200000000),
    );
    await _createWallet(bob, bobWalletId,
        mnemonic: await DartSVCryptoService().generateMnemonic());
    // Each side creates another (empty) wallet afterwards.
    await _createWallet(alice, 'alice-other-$ts',
        mnemonic: await DartSVCryptoService().generateMnemonic());
    await _createWallet(bob, 'bob-other-$ts',
        mnemonic: await DartSVCryptoService().generateMnemonic());
    autoAccept(bobWalletId);

    await openAndVerify(aliceWalletId, bobWalletId);
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('opens after a restart, for wallets created before it', () async {
    final ts = DateTime.now().microsecondsSinceEpoch;
    final aliceWalletId = 'alice-$ts';
    final bobWalletId = 'bob-$ts';

    await _createWallet(alice, aliceWalletId, xpriv: kTestXpriv);
    await fundWallet(
      walletManager: alice.system.walletManager,
      actorSystem: alice.actorSystem,
      walletId: aliceWalletId,
      amount: BigInt.from(200000000),
    );
    await _createWallet(bob, bobWalletId,
        mnemonic: await DartSVCryptoService().generateMnemonic());

    await alice.restart();
    await bob.restart();
    autoAccept(bobWalletId);

    await openAndVerify(aliceWalletId, bobWalletId);
  }, timeout: const Timeout(Duration(seconds: 90)));

  /// Creates and funds Alice's wallet (one 200000000 sat UTXO), creates
  /// Bob's, and makes Bob accept every request. Returns the wallet ids.
  Future<(String, String)> fundedPair() async {
    final ts = DateTime.now().microsecondsSinceEpoch;
    final aliceWalletId = 'alice-$ts';
    final bobWalletId = 'bob-$ts';
    await _createWallet(alice, aliceWalletId, xpriv: kTestXpriv);
    await fundWallet(
      walletManager: alice.system.walletManager,
      actorSystem: alice.actorSystem,
      walletId: aliceWalletId,
      amount: BigInt.from(200000000),
    );
    await _createWallet(bob, bobWalletId,
        mnemonic: await DartSVCryptoService().generateMnemonic());
    autoAccept(bobWalletId);
    return (aliceWalletId, bobWalletId);
  }

  /// Opens a 100000 sat channel from a funded pair and returns Alice's
  /// read-model row of it.
  Future<PaymentChannel> openFunded(
      {int lockTimeDurationSeconds = 86400}) async {
    final (aliceWalletId, _) = await fundedPair();
    final (opened, _) = await openChannel(aliceWalletId, 100000,
        lockTimeDurationSeconds: lockTimeDurationSeconds);
    final row =
        await alice.system.walletStorage.getPaymentChannel(opened.channelId);
    expect(row, isNotNull);
    return row!;
  }

  /// A message ([ErrorEvent] or [ChannelOpenedEvent]) Alice emits for the
  /// open in flight, whichever comes first.
  Future<CoordinatorEvent> firstOutcome() => alice.stream
      .where((e) => e is ErrorEvent || e is ChannelOpenedEvent)
      .first
      .timeout(const Duration(seconds: 20));

  group('libspiffy-b83: the client retains the countersigned refund', () {
    test('a fully signed, valid refund is journaled before open and stored in '
        'the read model', () async {
      final row = await openFunded();

      expect(_storedRefundProblem(row), isNull,
          reason: 'read model refund after open');
      final journal = await _journal(alice, row.channelId);
      final refundAt = _completeRefundIndex(journal, row);
      expect(refundAt, isNot(-1),
          reason: 'no journaled event holds the complete refund; journal: '
              '${journal.map((e) => e.typeName).toList()}');
      expect(refundAt, lessThan(_indexOfType(journal, 'channel.opened')),
          reason: 'the refund must be journaled before the channel opens');
      // The unsigned template and the client signature are journaled too.
      expect(_indexOfType(journal, 'channel.refund.built'), isNot(-1));
    }, timeout: const Timeout(Duration(seconds: 90)));

    test('the refund survives a restart and a projection rebuild', () async {
      final row = await openFunded();

      await alice.restart();
      final afterRestart =
          await alice.system.walletStorage.getPaymentChannel(row.channelId);
      expect(_storedRefundProblem(afterRestart), isNull,
          reason: 'read model refund after restart');
      final journal = await _journal(alice, row.channelId);
      expect(_completeRefundIndex(journal, row), isNot(-1),
          reason: 'journal refund after restart');

      // Rebuild: the journal alone, projected into empty storage.
      final rebuilt = InMemoryWalletStorage();
      final projection = ChannelProjection(
        projectionId: 'rebuild',
        eventStore: alice.system.eventStore,
        storage: rebuilt,
      );
      for (final event in journal) {
        await projection.handle(event);
      }
      final rebuiltRow = await rebuilt.getPaymentChannel(row.channelId);
      expect(rebuiltRow?.state, PaymentChannelState.open);
      expect(_storedRefundProblem(rebuiltRow), isNull,
          reason: 'rebuilt read model refund');
      expect(rebuiltRow?.refundTxHex, afterRestart?.refundTxHex);
    }, timeout: const Timeout(Duration(seconds: 90)));

    test('a bad server refund signature blocks open and funding', () async {
      final (aliceWalletId, _) = await fundedPair();
      // Bob answers with a well-formed signature by a key that is not his
      // channel key, over the right sighash.
      bob.tamper = (type, payload) async {
        if (type != 'refund_signed') return payload;
        final request = _sentPayload(alice, 'refund_sign_request');
        final clientPub = dartsv.SVPublicKey.fromHex(
            _sentPayload(alice, 'channel_request')['clientPubKey'] as String);
        final serverPub = dartsv.SVPublicKey.fromHex(
            _sentPayload(bob, 'channel_accept')['serverPubKey'] as String);
        final forged = await PaymentChannelBuilder(
                cryptoService: DartSVCryptoService())
            .signMultisigInput(
          transaction:
              dartsv.Transaction.fromHex(request['refundTxHex'] as String),
          inputIndex: 0,
          privateKey: dartsv.SVPrivateKey(networkType: dartsv.NetworkType.TEST),
          clientPubKey: clientPub,
          serverPubKey: serverPub,
          inputAmountSats: BigInt.from(100000),
        );
        return {...payload, 'serverSignatureHex': forged.signatureHex};
      };

      final outcome = firstOutcome();
      alice.coordinator.tell(OpenChannelCommand(
        walletId: aliceWalletId,
        serverPeerId: _bobPeer,
        fundingAmountSats: 100000,
        lockTimeDurationSeconds: 86400,
      ));
      final first = await outcome;

      expect(first, isA<ErrorEvent>(),
          reason: 'Alice must refuse the forged refund.\nAlice:\n  '
              '${alice.trace()}');
      expect((first as ErrorEvent).message, contains('signature'));
      // Give a wrongly continuing flow time to show itself.
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(alice.events.whereType<ChannelOpenedEvent>(), isEmpty);
      expect(
          alice.events
              .whereType<ChannelP2PMessageToSendEvent>()
              .map((m) => m.messageType),
          isNot(contains('channel_open')));
      expect(alice.arc.submitted, isEmpty,
          reason: 'the funding transaction must not be broadcast');
      final channelId =
          _sentPayload(alice, 'channel_request')['channelId'] as String;
      final row =
          await alice.system.walletStorage.getPaymentChannel(channelId);
      expect(row?.state, isNot(PaymentChannelState.open));
      final journal = await _journal(alice, channelId);
      expect(_indexOfType(journal, 'channel.refund.countersigned'), -1,
          reason: 'the forged signature must not be journaled');
    }, timeout: const Timeout(Duration(seconds: 90)));

    test('ClaimRefundCommand uses the retained refund once the lockTime has '
        'passed, and is refused before', () async {
      final row = await openFunded(lockTimeDurationSeconds: 3);

      // A process restart: the claim runs on the journal alone.
      await alice.restart();
      final aggregate = await alice.actorSystem.spawn(
        'claim-${row.channelId}',
        () => PaymentChannelAggregate(
          aggregateId: row.channelId,
          eventStore: alice.system.eventStore,
          cryptoService: DartSVCryptoService(),
        ),
      );

      final early = await aggregate.ask<dynamic>(
          ClaimRefundCommand(channelId: row.channelId),
          const Duration(seconds: 5));
      final nowUnix = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      if (nowUnix < row.lockTimeUnix) {
        expect(early, isA<Map>(), reason: 'claimed before the lockTime');
        expect((early as Map)['error'], contains('not yet expired'));
        await Future<void>.delayed(
            Duration(seconds: row.lockTimeUnix - nowUnix + 1));
      }

      final claimed = await aggregate.ask<dynamic>(
          ClaimRefundCommand(channelId: row.channelId),
          const Duration(seconds: 5));
      expect(claimed, isA<List>(), reason: '$claimed');
      final event = (claimed as List).single as Event;
      expect(event.toMap()['refundTxId'],
          dartsv.Transaction.fromHex(row.refundTxHex!).id,
          reason: 'the claim records the fully signed refund');
    }, timeout: const Timeout(Duration(seconds: 90)));
  });

  group('libspiffy-9f7: the funding transaction is broadcast and recorded', () {
    test('broadcast exactly once, only after the verified refund is '
        'journaled', () async {
      final seenAtSubmit = <String>[];
      alice.arc.onSubmit = (rawTx) async {
        final txid = dartsv.Transaction.fromHex(rawTx).id;
        final channelId = _sentPayload(alice, 'channel_request')['channelId']
            as String;
        final journal = await _journal(alice, channelId);
        final row =
            await alice.system.walletStorage.getPaymentChannel(channelId);
        final refundAt = row == null || row.fundingTxId != txid
            ? -1
            : _completeRefundIndex(journal, row);
        seenAtSubmit.add(refundAt == -1
            ? 'no complete refund journaled when $txid was submitted '
                '(journal ${journal.map((e) => e.typeName).toList()})'
            : 'refund journaled');
      };

      final row = await openFunded();

      expect(alice.arc.submitted, hasLength(1),
          reason: 'the funding transaction is broadcast exactly once');
      expect(alice.arc.submitted.single, row.fundingTxHex);
      expect(seenAtSubmit.last, 'refund journaled');
      expect(bob.arc.submitted, isEmpty);
    }, timeout: const Timeout(Duration(seconds: 90)));

    test('the wallet records the funding: inputs spent, change credited, the '
        '2-of-2 output not spendable', () async {
      final row = await openFunded();
      final walletId = row.walletId;
      final storage = alice.system.walletStorage;
      final funding = dartsv.Transaction.fromHex(row.fundingTxHex!);
      const original = 200000000;

      final recorded = await storage.getTransaction(row.fundingTxId!,
          walletId: walletId);
      expect(recorded, isNotNull,
          reason: 'the funding transaction is in the wallet history');
      expect(recorded!.rawHex, row.fundingTxHex);

      final outputs = funding.outputs
          .fold<BigInt>(BigInt.zero, (sum, o) => sum + o.satoshis)
          .toInt();
      final fee = original - outputs;
      expect(fee, inInclusiveRange(1, 1000), reason: 'fee $fee');
      final change = original - 100000 - fee;

      final utxos = await storage.getUTXOs(walletId, includeSpent: true);
      final input = utxos.singleWhere((u) =>
          u.txid == funding.inputs.single.prevTxnId &&
          u.vout == funding.inputs.single.prevTxnOutputIndex);
      expect(input.status, UTXOStatus.spent);
      final changeVout = funding.outputs.indexWhere(
          (o) => o.satoshis == BigInt.from(change));
      expect(changeVout, isNot(-1), reason: 'no change output of $change');
      final changeUtxo = utxos.singleWhere(
          (u) => u.txid == row.fundingTxId && u.vout == changeVout);
      expect(changeUtxo.satoshis, BigInt.from(change));
      expect(changeUtxo.status, UTXOStatus.pending);
      final channelUtxo = utxos.where((u) =>
          u.txid == row.fundingTxId && u.vout == row.fundingOutputIndex);
      expect(channelUtxo.where((u) => u.status == UTXOStatus.available),
          isEmpty);

      // ARC reports the funding transaction seen on the network.
      alice.arc.statuses[row.fundingTxId!] =
          ArcTransactionStatus.seenOnNetwork;
      alice.system.arcActor
          .tell(CheckStoragePendingUTXOsMessage(triggerBlockHeight: 0));
      final credited = await _eventually(
          () async => await storage.getBalance(walletId) == BigInt.from(change));
      expect(credited, isTrue,
          reason: 'balance ${await storage.getBalance(walletId)}, expected '
              '$original - 100000 - $fee = $change');
      // Settled: the channel output never becomes spendable balance.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(await storage.getBalance(walletId), BigInt.from(change));
      expect(
          (await storage.getPaymentUTXOs(walletId)).map((u) => u.key),
          isNot(contains('${row.fundingTxId}:${row.fundingOutputIndex}')));
    }, timeout: const Timeout(Duration(seconds: 90)));

    test('a failed broadcast does not open the channel; a retry does', () async {
      final (aliceWalletId, bobWalletId) = await fundedPair();
      alice.arc.failWith = 'ARC unavailable';

      final outcome = firstOutcome();
      alice.coordinator.tell(OpenChannelCommand(
        walletId: aliceWalletId,
        serverPeerId: _bobPeer,
        fundingAmountSats: 100000,
        lockTimeDurationSeconds: 86400,
      ));
      final first = await outcome;
      expect(first, isA<ErrorEvent>(),
          reason: 'a channel whose funding was not broadcast must not open.'
              '\nAlice:\n  ${alice.trace()}');
      expect((first as ErrorEvent).message, contains('ARC unavailable'));
      await Future<void>.delayed(const Duration(milliseconds: 500));

      expect(alice.arc.submitted, hasLength(1));
      expect(alice.events.whereType<ChannelOpenedEvent>(), isEmpty);
      expect(bob.events.whereType<ChannelOpenedEvent>(), isEmpty);
      expect(
          alice.events
              .whereType<ChannelP2PMessageToSendEvent>()
              .map((m) => m.messageType),
          isNot(contains('channel_open')));
      final channelId =
          _sentPayload(alice, 'channel_request')['channelId'] as String;
      final storage = alice.system.walletStorage;
      final row = await storage.getPaymentChannel(channelId);
      expect(row?.state, PaymentChannelState.funding);
      expect(row?.errorMessage, contains('ARC unavailable'));
      expect(_storedRefundProblem(row), isNull,
          reason: 'the refund is kept for the unopened channel');
      // The inputs stay reserved for this funding transaction: not spent,
      // not spendable elsewhere.
      final utxos = await storage.getUTXOs(aliceWalletId, includeSpent: true);
      final input = dartsv.Transaction.fromHex(row!.fundingTxHex!)
          .inputs
          .single;
      final inputUtxo = utxos.singleWhere((u) =>
          u.txid == input.prevTxnId && u.vout == input.prevTxnOutputIndex);
      expect(inputUtxo.status, UTXOStatus.reserved);
      expect((await storage.getPaymentUTXOs(aliceWalletId)).map((u) => u.key),
          isNot(contains(inputUtxo.key)));

      // Retry the same funding transaction once ARC is back.
      alice.arc.failWith = null;
      final aliceOpened = alice.next<ChannelOpenedEvent>((_) => true);
      final bobOpened = bob.next<ChannelOpenedEvent>((_) => true);
      alice.system.channelManager.tell(OpenChannelMessage(
        channelId: channelId,
        fundingTxId: row.fundingTxId!,
        fundingOutputIndex: row.fundingOutputIndex!,
        fundingTxHex: row.fundingTxHex!,
      ));
      await aliceOpened;
      final bobEvent = await bobOpened;
      expect(bobEvent.walletId, bobWalletId);
      expect(alice.arc.submitted, hasLength(2));
      expect(alice.arc.submitted.toSet(), {row.fundingTxHex});
      final reopened = await storage.getPaymentChannel(channelId);
      expect(reopened?.state, PaymentChannelState.open);
      expect(reopened?.errorMessage, isNull,
          reason: 'the broadcast error is cleared once the channel opens');
      final spent = (await storage.getUTXOs(aliceWalletId, includeSpent: true))
          .singleWhere((u) =>
              u.txid == input.prevTxnId && u.vout == input.prevTxnOutputIndex);
      expect(spent.status, UTXOStatus.spent);
    }, timeout: const Timeout(Duration(seconds: 90)));
  });
}
