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
    show OpenChannelMessage, SignRefundTransactionMessage;
import 'package:libspiffy/src/core/channel_commands.dart'
    show ClaimRefundCommand;
import 'package:libspiffy/src/core/payment_channel_aggregate.dart';
import 'package:libspiffy/src/models/payment_channel.dart';
import 'package:eventador/eventador.dart' show Event;

import 'isar_test_helper.dart';
import 'p2p_test_helpers.dart';
import '../spv/testnet_proof_fixture.dart';

const _alicePeer = 'alice-peer';

/// Fixed mnemonics for the wallets that sign channel transactions, so the
/// test is deterministic. (They were introduced when dartsv's HD derivation
/// failed with 'Too few elements' for 1 in 256 keys and random mnemonics made
/// channel opens fail at random; libspiffy now derives through Bip32,
/// libspiffy-hvp.)
const _bobMnemonic = 'abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon abandon abandon about';
const _otherMnemonic = 'legal winner thank year wave sausage worth useful '
    'legal winner thank yellow';
const _bobPeer = 'bob-peer';

class _Node {
  final String peerId;
  final Directory dir;
  final Isar isar;
  final InMemorySecureStorage secureStorage;

  /// The ARC service this node broadcasts through (no network).
  final _RecordingArc arc = _RecordingArc();

  /// Boot with this node's own channel peer id passed to
  /// LibSpiffyActorSystem.initialize (`channelPeerId`, libspiffy-36f).
  bool announcePeerId = false;

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

  /// False while this node's system is shut down (between [_halt] and
  /// [_boot], and after [stop]).
  bool running = false;

  /// The current incarnation's coordinator events (closed by a restart).
  Stream<CoordinatorEvent> get stream => system.coordinatorEvents!;

  /// Coordinator events of every incarnation of [system], across restarts.
  final StreamController<CoordinatorEvent> _allEvents =
      StreamController<CoordinatorEvent>.broadcast();
  Stream<CoordinatorEvent> get allEvents => _allEvents.stream;

  Future<T> next<T extends CoordinatorEvent>(bool Function(T) test,
          {Duration timeout = const Duration(seconds: 20)}) =>
      allEvents
          .where((e) => e is T && test(e))
          .cast<T>()
          .first
          .timeout(timeout);

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
    // Called through Function.apply so this file also compiles against a
    // LibSpiffyActorSystem without the `channelPeerId` parameter (where a
    // node that announces its peer id then fails to boot).
    await Function.apply(system.initialize, const [], {
      #actorSystem: actorSystem,
      #isar: isar,
      #dataDirectory: dir.path,
      #enableP2P: false,
      #secureStorage: secureStorage,
      #arcService: arc,
      if (announcePeerId) #channelPeerId: peerId,
    });
    // setupTestHeaders stores the real header of block 1239645, which the
    // fundWallet proof of [_parentTxid] leads to: the server SPV-validates
    // funding BEEFs against it (libspiffy-fsy).
    final storage = system.walletStorage as IsarWalletStorage;
    await setupTestHeaders(storage);
    subs.add(stream.listen((e) {
      events.add(e);
      _allEvents.add(e);
    }));
    for (final w in _wiring) {
      w();
    }
    running = true;
  }

  Future<void> _halt() async {
    running = false;
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
    await _allEvents.close();
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
        // A message still in flight when [to] is stopped is lost, as on a
        // wire; tearDown stops one node while the other may still be
        // sending (it failed the test after it had passed).
        if (!to.running) return;
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
  ArcTransactionStatus submitStatus = ArcTransactionStatus.seenOnNetwork;

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

// ---------------------------------------------------------------------------
// A raw channel client (libspiffy-fsy, libspiffy-36f)
// ---------------------------------------------------------------------------

/// The transaction fundWallet credits: output 1 (200000000 sats to
/// [kTestRootAddress]) of this real testnet transaction, mined in block
/// 1239645 (a header [setupTestHeaders] stores).
const _parentTxid =
    'a05924fcc63712d3e4b94b0c88baad234c2c8ad3d369704f53765e21a53a2101';
const _parentTxHex =
    '020000000165b6c06790c23623c4988ee51b3f27c76bfb6a0c9e5bab3432968c51379af66a000000006b483045022100b735fb60adca4fa42e37746aa602c3206bf98572ae83e396da4fd11cb716b26d022017bf9955bd8fc4d60f2829236c7864d5b5540062c88113daef137c0ee441736c41210222824a8530bc570b7bae7c7600529b450a65eab1203c5f561d8082cd97b3dba1feffffff02872ec735150000001976a9149d02ce72bbdc1713d5537a0705d8ec7d9702c81088ac00c2eb0b000000001976a9146a418bf9e2e2b670e1aa7b7da59391e212b4ba1988ac5cea1200';
const _parentValue = 200000000;

/// The BUMP of [_parentTxid] in block 1239645 (the real testnet proof);
/// [corrupt] alters one sibling hash, so the path no longer leads to the
/// header's merkle root.
BUMP _parentBump({bool corrupt = false}) =>
    fixtureBump(tamperLevel: corrupt ? 0 : null);

/// What is wrong with the funding a [_RawClient] hands the server.
enum _Defect {
  /// A valid funding transaction and BEEF.
  none,

  /// The BEEF holds only the funding transaction: its parent is neither in
  /// the BEEF nor proven.
  missingAncestor,

  /// The parent's BUMP does not lead to the merkle root of block 1239645.
  badMerkleRoot,

  /// The funding input is signed by a key that does not own the parent
  /// output.
  invalidInputScript,

  /// Validly signed, but the outputs are worth more than the input.
  overspends,

  /// channel_open carries no BEEF at all (a client from before
  /// libspiffy-fsy).
  noBeef,
}

/// A channel client speaking the wire protocol to [server] directly (as
/// [_alicePeer]), funding from [_parentTxid] output 1 with the key of
/// [kTestRootAddress]: it can hand the server any funding transaction and
/// BEEF.
class _RawClient {
  final _Node server;
  final dartsv.SVPrivateKey channelKey =
      dartsv.SVPrivateKey(networkType: dartsv.NetworkType.TEST);
  final String channelId = 'raw-${DateTime.now().microsecondsSinceEpoch}';
  final int amount = 100000;
  final int lockTimeUnix =
      DateTime.now().add(const Duration(days: 1)).millisecondsSinceEpoch ~/
          1000;

  /// channel_accept from the server, once [request] returned.
  late Map<String, dynamic> accept;
  late dartsv.Transaction funding;
  late String refundTxHex;

  _RawClient(this.server);

  dartsv.SVPublicKey get clientPub => channelKey.publicKey;
  dartsv.SVPublicKey get serverPub =>
      dartsv.SVPublicKey.fromHex(accept['serverPubKey'] as String);
  String get clientAddress =>
      clientPub.toAddress(dartsv.NetworkType.TEST).toString();

  void _send(String type, Map<String, dynamic> payload) =>
      server.coordinator.tell(ChannelP2PReceived(
        fromPeerId: _alicePeer,
        messageType: type,
        payload:
            (jsonDecode(jsonEncode(payload)) as Map).cast<String, dynamic>(),
      ));

  Future<Map<String, dynamic>> _sent(String type) => server
      .next<ChannelP2PMessageToSendEvent>((m) =>
          m.messageType == type && m.payload['channelId'] == channelId)
      .then((m) => m.payload);

  /// Sends channel_request and waits for channel_accept.
  Future<void> request() async {
    final accepted = _sent('channel_accept');
    _send('channel_request', {
      'channelId': channelId,
      'clientPeerId': _alicePeer,
      'clientPubKey': clientPub.toString(),
      'clientAddress': clientAddress,
      'fundingAmountSats': amount,
      'lockTimeUnix': lockTimeUnix,
    });
    accept = await accepted;
  }

  /// Builds the funding transaction (with [defect]) and the refund template.
  Future<void> build(_Defect defect) async {
    final payer = dartsv.HDPrivateKey.fromXpriv(kTestXpriv)
        .deriveChildKey('m/0/0')
        .privateKey;
    expect(payer.publicKey.toAddress(dartsv.NetworkType.TEST).toString(),
        kTestRootAddress);
    final payerScript = dartsv.P2PKHLockBuilder.fromAddress(
            dartsv.Address.fromBase58(kTestRootAddress))
        .getScriptPubkey();
    final multisig =
        dartsv.P2MSLockBuilder([clientPub, serverPub], 2, sorting: true)
            .getScriptPubkey();
    final tx = dartsv.Transaction()..version = 1;
    tx.inputs.add(dartsv.TransactionInput(
        _parentTxid, 1, dartsv.TransactionInput.MAX_SEQ_NUMBER,
        scriptBuilder: dartsv.P2PKHUnlockBuilder(payer.publicKey)));
    tx.outputs.add(dartsv.TransactionOutput(BigInt.from(amount), multisig));
    tx.outputs.add(dartsv.TransactionOutput(
        BigInt.from(defect == _Defect.overspends
            ? _parentValue
            : _parentValue - amount - 500),
        payerScript));
    final signingKey = defect == _Defect.invalidInputScript
        ? dartsv.SVPrivateKey(networkType: dartsv.NetworkType.TEST)
        : payer;
    dartsv.DefaultTransactionSigner(0x41, signingKey).sign(tx,
        dartsv.TransactionOutput(BigInt.from(_parentValue), payerScript), 0);
    funding = dartsv.Transaction.fromHex(tx.serialize());

    refundTxHex =
        (await PaymentChannelBuilder(cryptoService: DartSVCryptoService())
                .buildRefundTransaction(
      fundingTxId: funding.id,
      fundingOutputIndex: 0,
      fundingAmountSats: BigInt.from(amount),
      clientPubKey: clientPub,
      serverPubKey: serverPub,
      clientAddress: clientPub.toAddress(dartsv.NetworkType.TEST),
      lockTimeUnix: lockTimeUnix,
    ))
            .transactionHex;
  }

  /// Sends refund_sign_request and waits for refund_signed.
  Future<Map<String, dynamic>> requestRefundSignature() {
    final signed = _sent('refund_signed');
    _send('refund_sign_request', {
      'channelId': channelId,
      'refundTxHex': refundTxHex,
      'fundingTxId': funding.id,
      'fundingOutputIndex': 0,
      'fundingTxHex': funding.serialize(),
    });
    return signed;
  }

  /// The BEEF of the funding transaction, with [defect].
  String? beefHex(_Defect defect) {
    final fundingBytes = Uint8List.fromList(hex.decode(funding.serialize()));
    final BEEF beef;
    switch (defect) {
      case _Defect.noBeef:
        return null;
      case _Defect.missingAncestor:
        beef = BEEF.create(
            bumps: const [],
            txs: [fundingBytes],
            hasMerkle: [false],
            bumpIndex: const []);
      default:
        beef = BEEF.create(
          bumps: [_parentBump(corrupt: defect == _Defect.badMerkleRoot)],
          txs: [Uint8List.fromList(hex.decode(_parentTxHex)), fundingBytes],
          hasMerkle: [true, false],
          bumpIndex: [0],
        );
    }
    return hex.encode(beef.serialize());
  }

  /// Sends channel_open for the funding (with [defect]) and returns the
  /// server's first outcome: its ChannelOpenedEvent or an ErrorEvent about
  /// this channel.
  Future<CoordinatorEvent> open(_Defect defect) {
    final outcome = server.allEvents
        .where((e) =>
            (e is ChannelOpenedEvent && e.channelId == channelId) ||
            (e is ErrorEvent && e.message.contains(channelId)))
        .first
        .timeout(const Duration(seconds: 40));
    final beef = beefHex(defect);
    _send('channel_open', {
      'channelId': channelId,
      'fundingTxId': funding.id,
      'fundingOutputIndex': 0,
      'fundingTxHex': funding.serialize(),
      if (beef != null) 'fundingBeef': beef,
    });
    return outcome;
  }
}

/// How many times [walletId]'s journal records transaction [txid].
Future<int> _walletRecordings(_Node node, String walletId, String txid) async =>
    (await node.system.eventStore.getEvents('BitcoinWallet_$walletId'))
        .where((e) =>
            e.typeName == 'wallet.transaction.recorded' &&
            e.toMap()['txid'] == txid)
        .length;

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
        mnemonic: _bobMnemonic);
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
        mnemonic: _bobMnemonic);
    // Each side creates another (empty) wallet afterwards.
    await _createWallet(alice, 'alice-other-$ts',
        mnemonic: _otherMnemonic);
    await _createWallet(bob, 'bob-other-$ts',
        mnemonic: _otherMnemonic);
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
        mnemonic: _bobMnemonic);

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
        mnemonic: _bobMnemonic);
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
  Future<CoordinatorEvent> firstOutcome() => alice.allEvents
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
      // Pending, or already available: ARC answered the submission
      // SEEN_ON_NETWORK, which applies the deferred spend (libspiffy-09k).
      expect(changeUtxo.status,
          isIn([UTXOStatus.pending, UTXOStatus.available]));
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

  group('libspiffy-36f: the refund is signed by the channel wallet', () {
    /// A raw client's channel accepted by Bob's [bobWalletId], with Bob's
    /// [otherWalletId] created as well, and the refund to sign built.
    Future<_RawClient> acceptedWithTwoBobWallets(
        String bobWalletId, String otherWalletId) async {
      await _createWallet(bob, bobWalletId,
          mnemonic: _bobMnemonic);
      await _createWallet(bob, otherWalletId,
          mnemonic: _otherMnemonic);
      autoAccept(bobWalletId);
      final raw = _RawClient(bob);
      await raw.request();
      await raw.build(_Defect.none);
      return raw;
    }

    /// Whether [signatureHex] signs input 0 of [raw]'s refund with Bob's
    /// channel key (the one channel_accept announced).
    bool signedByChannelKey(_RawClient raw, String signatureHex) {
      final signature = dartsv.SVSignature.fromTxFormat(signatureHex);
      final redeemScript =
          dartsv.P2MSLockBuilder([raw.clientPub, raw.serverPub], 2, sorting: true)
              .getScriptPubkey();
      final sighash = dartsv.Sighash().hash(
          dartsv.Transaction.fromHex(raw.refundTxHex),
          signature.nhashtype,
          0,
          redeemScript,
          BigInt.from(raw.amount));
      return DartSVCryptoService().verifySignature(raw.serverPub, signature,
          Uint8List.fromList(hex.decode(sighash).reversed.toList()));
    }

    SignRefundTransactionMessage signRequest(_RawClient raw,
            {required String walletId, int? derivationIndex}) =>
        SignRefundTransactionMessage(
          channelId: raw.channelId,
          walletId: walletId,
          refundTxHex: raw.refundTxHex,
          clientPubKeyHex: raw.clientPub.toString(),
          serverPubKeyHex: raw.serverPub.toString(),
          serverAddressB58: raw.accept['serverAddress'] as String,
          derivationIndex:
              derivationIndex ?? raw.accept['derivationIndex'] as int,
          fundingAmountSats: BigInt.from(raw.amount),
          lockTimeUnix: raw.lockTimeUnix,
        );

    test('a sign request naming another wallet does not get that wallet\'s '
        'key used', () async {
      final ts = DateTime.now().microsecondsSinceEpoch;
      final raw = await acceptedWithTwoBobWallets('bob-$ts', 'bob-other-$ts');

      final dynamic reply = await bob.system.channelManager.ask<dynamic>(
          signRequest(raw, walletId: 'bob-other-$ts'),
          const Duration(seconds: 20));

      if (reply.success == true) {
        expect(signedByChannelKey(raw, reply.serverSignatureHex as String),
            isTrue,
            reason: 'the refund was signed with a key of wallet bob-other-$ts, '
                'not with the key of the wallet that owns the channel');
      }
      expect(reply.success, isFalse,
          reason: 'a request naming a wallet that does not own the channel '
              'must be refused');
      expect(reply.error as String, contains('bob-other-$ts'));
      expect(
          _indexOfType(await _journal(bob, raw.channelId),
              'channel.refund.countersigned'),
          -1);
    }, timeout: const Timeout(Duration(seconds: 90)));

    test('a sign request with another key index is signed with the channel '
        'key', () async {
      final ts = DateTime.now().microsecondsSinceEpoch;
      final raw = await acceptedWithTwoBobWallets('bob-$ts', 'bob-other-$ts');

      final dynamic reply = await bob.system.channelManager.ask<dynamic>(
          signRequest(raw, walletId: 'bob-$ts', derivationIndex: 977),
          const Duration(seconds: 20));

      expect(reply.success, isTrue, reason: reply.error as String?);
      expect(signedByChannelKey(raw, reply.serverSignatureHex as String),
          isTrue,
          reason: 'the refund must be signed with the channel key the server '
              'journaled, whatever key index the request names');
    }, timeout: const Timeout(Duration(seconds: 90)));
  });

  group('libspiffy-36f: channel_open carries the node peer id', () {
    test('a node given channelPeerId sends and journals it', () async {
      final (aliceWalletId, bobWalletId) = await fundedPair();
      alice.announcePeerId = true;
      bob.announcePeerId = true;
      await alice.restart();
      await bob.restart();

      await openAndVerify(aliceWalletId, bobWalletId);

      final request = _sentPayload(alice, 'channel_request');
      expect(request['clientPeerId'], _alicePeer);
      final channelId = request['channelId'] as String;
      final aliceJournal = await _journal(alice, channelId);
      expect(aliceJournal.first.toMap()['clientPeerId'], _alicePeer);
      expect(aliceJournal.first.toMap()['serverPeerId'], _bobPeer);
      final bobJournal = await _journal(bob, channelId);
      expect(bobJournal.first.toMap()['clientPeerId'], _alicePeer);
      expect(bobJournal.first.toMap()['serverPeerId'], _bobPeer);
      final bobRow = await bob.system.walletStorage.getPaymentChannel(channelId);
      expect(bobRow?.serverPeerId, _bobPeer);
    }, timeout: const Timeout(Duration(seconds: 90)));
  });

  group('libspiffy-fsy: the server SPV-validates the funding transaction', () {
    /// A raw client's channel with Bob, up to the countersigned refund of a
    /// funding transaction with [defect]; then channel_open. Returns Bob's
    /// first outcome.
    Future<(_RawClient, CoordinatorEvent)> openRaw(_Defect defect) async {
      final ts = DateTime.now().microsecondsSinceEpoch;
      await _createWallet(bob, 'bob-$ts',
          mnemonic: _bobMnemonic);
      autoAccept('bob-$ts');
      final raw = _RawClient(bob);
      await raw.request();
      await raw.build(defect);
      await raw.requestRefundSignature();
      return (raw, await raw.open(defect));
    }

    Future<void> expectRefused(_Defect defect, String reason) async {
      final (raw, outcome) = await openRaw(defect);
      expect(outcome, isA<ErrorEvent>(),
          reason: 'Bob opened a channel funded by a transaction with defect '
              '${defect.name}.\nBob:\n  ${bob.trace()}');
      expect((outcome as ErrorEvent).message, contains(reason));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(
          bob.events
              .whereType<ChannelOpenedEvent>()
              .where((e) => e.channelId == raw.channelId),
          isEmpty);
      final journal = await _journal(bob, raw.channelId);
      expect(_indexOfType(journal, 'channel.opened'), -1);
      final row = await bob.system.walletStorage.getPaymentChannel(raw.channelId);
      expect(row?.state, isNot(PaymentChannelState.open));
    }

    test('a funding transaction with a valid BEEF opens, and the BEEF is '
        'journaled', () async {
      final (raw, outcome) = await openRaw(_Defect.none);

      expect(outcome, isA<ChannelOpenedEvent>(),
          reason: 'Bob:\n  ${bob.trace()}');
      final journal = await _journal(bob, raw.channelId);
      final opened = journal[_indexOfType(journal, 'channel.opened')].toMap();
      expect(opened['fundingBeefHex'], raw.beefHex(_Defect.none),
          reason: 'the counterparty BEEF cannot be fetched again: it is kept');
    }, timeout: const Timeout(Duration(seconds: 90)));

    test('refused when an ancestor is missing and unproven', () async {
      await expectRefused(_Defect.missingAncestor, 'neither in the BEEF');
    }, timeout: const Timeout(Duration(seconds: 90)));

    test('refused when the ancestor proof does not match the header merkle '
        'root', () async {
      await expectRefused(_Defect.badMerkleRoot, 'merkle proof');
    }, timeout: const Timeout(Duration(seconds: 90)));

    test('refused when an input script does not verify', () async {
      await expectRefused(_Defect.invalidInputScript, 'Invalid transaction');
    }, timeout: const Timeout(Duration(seconds: 90)));

    test('refused when the outputs are worth more than the inputs', () async {
      await expectRefused(_Defect.overspends, 'fee');
    }, timeout: const Timeout(Duration(seconds: 90)));

    test('refused without a BEEF', () async {
      await expectRefused(_Defect.noBeef, 'BEEF');
    }, timeout: const Timeout(Duration(seconds: 90)));

    test('the client sends the BEEF of its funding transaction', () async {
      final row = await openFunded();
      final open = _sentPayload(alice, 'channel_open');
      final beef = BEEF.parse(
          Uint8List.fromList(hex.decode(open['fundingBeef'] as String)));
      final funding = beef.findTransactionByTxid(
          Uint8List.fromList(hex.decode(row.fundingTxId!)));
      expect(funding, isNotNull);
      expect(hex.encode(funding!['txData'] as List<int>), row.fundingTxHex);
      expect(beef.findTransactionByTxid(
              Uint8List.fromList(hex.decode(_parentTxid))),
          isNotNull,
          reason: 'the proven parent travels with the funding transaction');
    }, timeout: const Timeout(Duration(seconds: 90)));
  });

  group('libspiffy-fsy/36f: channel state survives a restart', () {
    test('a retried open after a restart sends channel_open and opens both '
        'sides', () async {
      final (aliceWalletId, bobWalletId) = await fundedPair();
      alice.arc.failWith = 'ARC unavailable';
      final outcome = firstOutcome();
      alice.coordinator.tell(OpenChannelCommand(
        walletId: aliceWalletId,
        serverPeerId: _bobPeer,
        fundingAmountSats: 100000,
        lockTimeDurationSeconds: 86400,
      ));
      expect(await outcome, isA<ErrorEvent>());
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final channelId =
          _sentPayload(alice, 'channel_request')['channelId'] as String;
      final row = (await alice.system.walletStorage.getPaymentChannel(channelId))!;
      // The failed open told Bob its step was abandoned (libspiffy-kyw).
      final errorsBefore = alice.events
          .whereType<ChannelP2PMessageToSendEvent>()
          .where((m) => m.messageType == 'channel_error')
          .length;

      await alice.restart();
      await bob.restart();
      alice.arc.failWith = null;

      final aliceOpened =
          alice.next<ChannelOpenedEvent>((e) => e.channelId == channelId);
      final bobOpened = bob.next<ChannelOpenedEvent>(
          (e) => e.channelId == channelId,
          timeout: const Duration(seconds: 30));
      // The public seam (bead libspiffy-1n3): the channel id and nothing
      // else. This used to reach past the coordinator
      // (`channelManager.tell(OpenChannelMessage(...))`) with the funding
      // transaction read out of the storage row, because no public command
      // carried it — which is exactly what a host could not do.
      final retried = alice.next<ChannelFundingRetriedEvent>(
          (e) => e.channelId == channelId,
          timeout: const Duration(seconds: 40));
      alice.coordinator
          .tell(RetryChannelFundingCommand(channelId: channelId));
      final retriedEvent = await retried;
      expect(retriedEvent.success, isTrue, reason: retriedEvent.error);
      expect(retriedEvent.fundingTxId, row.fundingTxId,
          reason: 'the funding transaction is the channel\'s own, read from '
              'its state and never supplied by the caller');

      final ChannelOpenedEvent bobEvent;
      try {
        bobEvent = await bobOpened;
      } on TimeoutException {
        fail('Bob never opened after the retried open.\nAlice:\n  '
            '${alice.trace()}\nBob:\n  ${bob.trace()}');
      }
      expect(bobEvent.walletId, bobWalletId);
      expect((await aliceOpened).walletId, aliceWalletId);
      expect(
          alice.events
              .whereType<ChannelP2PMessageToSendEvent>()
              .where((m) => m.messageType == 'channel_open'),
          hasLength(1));

      // The retry re-broadcast the SAME transaction (there is no
      // replace-by-fee here), recorded it in the wallet once, and is the
      // second attempt of the one funding the refund spends.
      expect(alice.arc.submitted, [row.fundingTxHex, row.fundingTxHex]);
      expect(await _walletRecordings(alice, aliceWalletId, row.fundingTxId!), 1,
          reason: 'the retry recorded the funding transaction again');
      expect(
          (await _journal(alice, channelId))
              .where((e) => e.typeName == 'channel.funding.broadcast_started')
              .map((e) => e.toMap()['attempt']),
          [1, 2]);
      expect(
          alice.events
              .whereType<ChannelP2PMessageToSendEvent>()
              .where((m) => m.messageType == 'channel_error'),
          hasLength(errorsBefore),
          reason: 'a repair never tells the counterparty the channel failed');
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('an interrupted funding broadcast resumes after a restart without '
        'recording the funding in the wallet twice', () async {
      final (aliceWalletId, bobWalletId) = await fundedPair();
      final submitted = Completer<String>();
      final crashed = Completer<void>();
      alice.arc.onSubmit = (rawTx) async {
        if (submitted.isCompleted) return;
        submitted.complete(rawTx);
        // The process dies while ARC has the transaction: the stopped
        // incarnation gets its answer only once the new one runs.
        await crashed.future;
        throw ArcException('process stopped');
      };
      alice.coordinator.tell(OpenChannelCommand(
        walletId: aliceWalletId,
        serverPeerId: _bobPeer,
        fundingAmountSats: 100000,
        lockTimeDurationSeconds: 86400,
      ));
      final funding = dartsv.Transaction.fromHex(
          await submitted.future.timeout(const Duration(seconds: 30)));
      final channelId =
          _sentPayload(alice, 'channel_request')['channelId'] as String;
      final types =
          (await _journal(alice, channelId)).map((e) => e.typeName).toList();
      expect(types, contains('channel.funding.broadcast_started'));
      expect(types, isNot(contains('channel.funding.broadcast_failed')));
      expect(types, isNot(contains('channel.opened')));
      expect(await _walletRecordings(alice, aliceWalletId, funding.id), 1);
      final row = (await alice.system.walletStorage.getPaymentChannel(channelId))!;

      await alice.restart();
      alice.arc.onSubmit = null;
      crashed.complete();

      final bobOpened = bob.next<ChannelOpenedEvent>(
          (e) => e.channelId == channelId,
          timeout: const Duration(seconds: 40));
      // Driven through the public command (bead libspiffy-1n3), which used
      // to be an internal OpenChannelMessage carrying the funding
      // transaction the test had to dig out of a storage row.
      final retried = alice.next<ChannelFundingRetriedEvent>(
          (e) => e.channelId == channelId,
          timeout: const Duration(seconds: 60));
      alice.coordinator
          .tell(RetryChannelFundingCommand(channelId: channelId));
      final reply = await retried;
      expect(await _walletRecordings(alice, aliceWalletId, funding.id), 1,
          reason: 'the resumed broadcast recorded the funding transaction in '
              'the wallet again');
      expect(reply.success, isTrue, reason: reply.error);
      expect(reply.fundingTxId, funding.id);
      expect(row.fundingTxId, funding.id,
          reason: 'the channel row and the submitted transaction agree');
      expect((await bobOpened).walletId, bobWalletId);
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('the server countersigns after a restart mid-open', () async {
      final (aliceWalletId, bobWalletId) = await fundedPair();
      var restarted = false;
      alice.tamper = (type, payload) async {
        if (type == 'refund_sign_request' && !restarted) {
          restarted = true;
          await bob.restart();
        }
        return payload;
      };
      await openAndVerify(aliceWalletId, bobWalletId);
      expect(restarted, isTrue);
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('the server opens for the channel wallet after a restart before '
        'channel_open', () async {
      final (aliceWalletId, bobWalletId) = await fundedPair();
      var restarted = false;
      alice.tamper = (type, payload) async {
        if (type == 'channel_open' && !restarted) {
          restarted = true;
          await bob.restart();
        }
        return payload;
      };
      await openAndVerify(aliceWalletId, bobWalletId);
      expect(restarted, isTrue);
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('the client builds its funding after a restart before '
        'channel_accept', () async {
      final (aliceWalletId, bobWalletId) = await fundedPair();
      var restarted = false;
      bob.tamper = (type, payload) async {
        if (type == 'channel_accept' && !restarted) {
          restarted = true;
          await alice.restart();
        }
        return payload;
      };
      await openAndVerify(aliceWalletId, bobWalletId);
      expect(restarted, isTrue);
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('the client funds and opens after a restart before refund_signed',
        () async {
      final (aliceWalletId, bobWalletId) = await fundedPair();
      var restarted = false;
      bob.tamper = (type, payload) async {
        if (type == 'refund_signed' && !restarted) {
          restarted = true;
          await alice.restart();
        }
        return payload;
      };
      await openAndVerify(aliceWalletId, bobWalletId);
      expect(restarted, isTrue);
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('the server accepts a request received before a restart', () async {
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
          mnemonic: _bobMnemonic);

      final received = bob.next<ChannelRequestReceivedEvent>((_) => true);
      final aliceOpened = alice.next<ChannelOpenedEvent>((_) => true,
          timeout: const Duration(seconds: 40));
      final bobOpened = bob.next<ChannelOpenedEvent>((_) => true,
          timeout: const Duration(seconds: 40));
      alice.coordinator.tell(OpenChannelCommand(
        walletId: aliceWalletId,
        serverPeerId: _bobPeer,
        fundingAmountSats: 100000,
        lockTimeDurationSeconds: 86400,
      ));
      final r = await received;

      await bob.restart();
      bob.coordinator.tell(AcceptChannelCommand(
        channelId: r.channelId,
        walletId: bobWalletId,
        clientPeerId: r.clientPeerId,
        clientPubKey: r.clientPubKey,
        clientAddress: r.clientAddress,
        fundingAmountSats: r.fundingAmountSats,
        lockTimeUnix: r.lockTimeUnix,
      ));
      try {
        expect((await aliceOpened).walletId, aliceWalletId);
        expect((await bobOpened).walletId, bobWalletId);
      } on TimeoutException {
        fail('The accepted request never opened.\nAlice:\n  '
            '${alice.trace()}\nBob:\n  ${bob.trace()}');
      }
    }, timeout: const Timeout(Duration(seconds: 120)));
  });

  /// Bead libspiffy-1n3: a host can ask for the two repairs an unfinished
  /// open needs, and neither of them tells the counterparty the channel
  /// failed.
  group('libspiffy-1n3: repairing an open that did not finish', () {
    List<ChannelP2PMessageToSendEvent> sent(_Node node, String type) => node
        .events
        .whereType<ChannelP2PMessageToSendEvent>()
        .where((m) => m.messageType == type)
        .toList();

    /// A channel whose funding broadcast failed: refund countersigned and
    /// journaled, funding built and signed, ARC unreachable. Returns the
    /// channel id and the two wallet ids.
    Future<(String, String, String)> fundingFailed() async {
      final (aliceWalletId, bobWalletId) = await fundedPair();
      alice.arc.failWith = 'ARC unavailable';
      final outcome = firstOutcome();
      alice.coordinator.tell(OpenChannelCommand(
        walletId: aliceWalletId,
        serverPeerId: _bobPeer,
        fundingAmountSats: 100000,
        lockTimeDurationSeconds: 86400,
      ));
      expect(await outcome, isA<ErrorEvent>());
      // The failure's own channel_error to Bob (libspiffy-kyw) follows the
      // ErrorEvent on the same stream: let it land before anything counts
      // the messages sent so far.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final channelId =
          _sentPayload(alice, 'channel_request')['channelId'] as String;
      return (channelId, aliceWalletId, bobWalletId);
    }

    test('a failed funding broadcast is retried through the public command '
        'and the channel opens on both sides', () async {
      final (channelId, aliceWalletId, bobWalletId) = await fundingFailed();
      final row =
          (await alice.system.walletStorage.getPaymentChannel(channelId))!;
      expect(row.state, isNot(PaymentChannelState.open));
      // The failed open told Bob its step was abandoned (libspiffy-kyw).
      final errorsBefore = sent(alice, 'channel_error').length;
      alice.arc.failWith = null;

      final aliceOpened =
          alice.next<ChannelOpenedEvent>((e) => e.channelId == channelId);
      final bobOpened = bob.next<ChannelOpenedEvent>(
          (e) => e.channelId == channelId,
          timeout: const Duration(seconds: 40));
      final retried = alice.next<ChannelFundingRetriedEvent>(
          (e) => e.channelId == channelId,
          timeout: const Duration(seconds: 40));

      // The whole command: a channel id. The funding transaction is the
      // channel's own.
      alice.coordinator
          .tell(RetryChannelFundingCommand(channelId: channelId));

      final outcome = await retried;
      expect(outcome.success, isTrue, reason: outcome.error);
      expect(outcome.fundingTxId, row.fundingTxId);
      expect(outcome.walletId, aliceWalletId);
      try {
        expect((await aliceOpened).walletId, aliceWalletId);
        expect((await bobOpened).walletId, bobWalletId);
      } on TimeoutException {
        fail('The retried funding never opened.\nAlice:\n  '
            '${alice.trace()}\nBob:\n  ${bob.trace()}');
      }

      // The same transaction, twice; recorded in the wallet once; the
      // second attempt of the one the refund spends.
      expect(alice.arc.submitted, [row.fundingTxHex, row.fundingTxHex]);
      expect(await _walletRecordings(alice, aliceWalletId, row.fundingTxId!), 1);
      expect(
          (await _journal(alice, channelId))
              .where((e) => e.typeName == 'channel.funding.broadcast_started')
              .map((e) => e.toMap()['attempt']),
          [1, 2]);
      expect(sent(alice, 'channel_open'), hasLength(1));
      expect(sent(alice, 'channel_error'), hasLength(errorsBefore),
          reason: 'the retry told Bob the channel had failed');
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('re-sending channel_open repeats the same message, journals nothing '
        'and sends no channel_error', () async {
      final row = await openFunded();
      final channelId = row.channelId;
      final journalBefore =
          (await _journal(alice, channelId)).map((e) => e.typeName).toList();
      final firstOpen = _sentPayload(alice, 'channel_open');
      expect(sent(alice, 'channel_open'), hasLength(1));

      final resent = alice.next<ChannelOpenResentEvent>(
          (e) => e.channelId == channelId,
          timeout: const Duration(seconds: 30));
      alice.coordinator.tell(ResendChannelOpenCommand(channelId: channelId));

      // THE REGRESSION THIS BEAD IS REALLY ABOUT, asserted before anything
      // else so a repair that goes wrong is caught here rather than by a
      // timeout: repairing a lost message must never tell the counterparty
      // the channel failed. Driving the resend through the open command
      // instead makes the aggregate throw 'Refund not signed yet' for an
      // already-open channel, and the adapter sends channel_error.
      await Future<void>.delayed(const Duration(seconds: 2));
      expect(sent(alice, 'channel_error'), isEmpty,
          reason: 'Alice told Bob the channel failed.\nAlice:\n  '
              '${alice.trace()}');
      expect(sent(bob, 'channel_error'), isEmpty,
          reason: 'Bob answered a repeated channel_open with channel_error.'
              '\nBob:\n  ${bob.trace()}');

      final outcome = await resent;
      expect(outcome.success, isTrue, reason: outcome.error);
      expect(outcome.toPeerId, _bobPeer);
      expect(outcome.fundingTxId, row.fundingTxId);

      final opens = sent(alice, 'channel_open');
      expect(opens, hasLength(2),
          reason: 'the message the server never received, again');
      expect(opens[1].toPeerId, _bobPeer);
      expect(opens[1].payload, firstOpen,
          reason: 'byte for byte the payload the first channel_open carried');

      // A re-send is not a new fact about the channel.
      expect((await _journal(alice, channelId)).map((e) => e.typeName),
          journalBefore);
      expect(
          (await _journal(bob, channelId))
              .where((e) => e.typeName == 'channel.opened'),
          hasLength(1),
          reason: 'the server journaled a second opening');
      final bobRow = await bob.system.walletStorage.getPaymentChannel(channelId);
      expect(bobRow?.state, PaymentChannelState.open);
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('re-sending channel_open for a channel that is not open is refused, '
        'and nothing reaches the peer', () async {
      final (channelId, aliceWalletId, _) = await fundingFailed();
      final before = sent(alice, 'channel_open').length;
      final errorsBefore = sent(alice, 'channel_error').length;

      final resent = alice.next<ChannelOpenResentEvent>(
          (e) => e.channelId == channelId,
          timeout: const Duration(seconds: 30));
      alice.coordinator.tell(ResendChannelOpenCommand(channelId: channelId));
      final outcome = await resent;

      expect(outcome.success, isFalse);
      expect(outcome.error, contains('is not open here'));
      expect(outcome.error, contains('status=refundSigned'));
      expect(outcome.error, contains('RetryChannelFundingCommand'),
          reason: 'the refusal names the command the host wanted');
      expect(outcome.walletId, aliceWalletId);
      expect(outcome.toPeerId, isNull);
      expect(sent(alice, 'channel_open'), hasLength(before));
      // The failed open itself told Bob (bead libspiffy-kyw, correctly: it
      // abandoned a step Bob was waiting on). The refused repair adds
      // nothing to that.
      expect(sent(alice, 'channel_error'), hasLength(errorsBefore),
          reason: alice.trace());
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('retrying the funding of an open channel is refused, and nothing '
        'reaches the peer', () async {
      final row = await openFunded();
      final channelId = row.channelId;
      final broadcastsBefore = alice.arc.submitted.length;
      final journalBefore =
          (await _journal(alice, channelId)).map((e) => e.typeName).toList();

      final retried = alice.next<ChannelFundingRetriedEvent>(
          (e) => e.channelId == channelId,
          timeout: const Duration(seconds: 30));
      alice.coordinator
          .tell(RetryChannelFundingCommand(channelId: channelId));
      final outcome = await retried;

      expect(outcome.success, isFalse);
      expect(outcome.error, contains('is not waiting for its funding'));
      expect(outcome.error, contains('ResendChannelOpenCommand'),
          reason: 'the refusal names the command the host wanted');
      expect(alice.arc.submitted, hasLength(broadcastsBefore),
          reason: 'an open channel is not funded again');
      expect((await _journal(alice, channelId)).map((e) => e.typeName),
          journalBefore);
      expect(sent(alice, 'channel_error'), isEmpty, reason: alice.trace());
      expect(sent(alice, 'channel_open'), hasLength(1));
    }, timeout: const Timeout(Duration(seconds: 120)));
  });
}
