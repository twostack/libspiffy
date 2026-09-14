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
///   -> BuildRefundTransactionMessage (sender = coordinator)
///   -> RefundTransactionBuiltResponse -> refund_sign_request -> Bob
///   Bob: SignRefundTransactionMessage -> RefundCountersignedEvent
///   -> refund_signed -> Alice
///   Alice: RecordRefundSignatureMessage -> RefundCountersignedEvent
///   -> OpenChannelMessage -> ChannelOpenedEvent -> channel_open -> Bob
///   Bob: OpenChannelMessage -> ChannelOpenedEvent
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
import 'package:libspiffy/src/models/payment_channel.dart';

import 'isar_test_helper.dart';
import 'p2p_test_helpers.dart';

const _alicePeer = 'alice-peer';
const _bobPeer = 'bob-peer';

class _Node {
  final String peerId;
  final Directory dir;
  final Isar isar;
  final InMemorySecureStorage secureStorage;
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
void _link(_Node from, _Node to) {
  from.wire(() => from.subs.add(from.stream
          .where((e) => e is ChannelP2PMessageToSendEvent)
          .cast<ChannelP2PMessageToSendEvent>()
          .listen((m) {
        expect(m.toPeerId, to.peerId,
            reason:
                '${from.peerId} addressed ${m.messageType} to ${m.toPeerId}');
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
      String aliceWalletId, int amount) async {
    final aliceOpened = alice.next<ChannelOpenedEvent>((_) => true);
    final bobOpened = bob.next<ChannelOpenedEvent>((_) => true);
    alice.coordinator.tell(OpenChannelCommand(
      walletId: aliceWalletId,
      serverPeerId: _bobPeer,
      fundingAmountSats: amount,
      lockTimeDurationSeconds: 86400,
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
}
