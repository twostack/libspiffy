/// Bead libspiffy-kyw (c): a rejected channel command left a projection
/// awaiter registered until it timed out.
///
/// `PaymentChannelManagerActor` registers an awaiter on the channel
/// projection BEFORE it sends the command, because the aggregate publishes
/// its event to the projection's mailbox before it answers — registering
/// afterwards can miss the resolution window (overnode_v2-8gh). When the
/// command is then rejected, nothing awaits that registration, and until
/// eventador gained `CancelEventAwait` there was no way to take it back: the
/// projection held the closure, the reply target and a timer for the full
/// 10 s window. On a path a peer can drive with repeated bad messages, that
/// is a cost the peer imposes at will.
///
/// The other half of this — that a cancel actually frees the registration —
/// is eventador's own `projection_actor_test.dart`.
library;

import 'dart:async';

import 'package:dactor/dactor.dart';
import 'package:dactor_test/dactor_test.dart';
import 'package:dartsv/dartsv.dart' show NetworkType;
import 'package:eventador/eventador.dart';
import 'package:test/test.dart';

import 'package:libspiffy/src/actors/payment_channel_manager_actor.dart';
import 'package:libspiffy/src/actors/payment_channel_messages.dart';
import 'package:libspiffy/src/actors/wallet_messages.dart';
import 'package:libspiffy/src/core/wallet_commands.dart';
import 'package:libspiffy/src/services/dartsv_crypto_service.dart';

import 'channel_test_fixtures.dart';
import 'in_memory_event_store.dart';
import '../mocks/policy_rate_arc.dart';

const _walletId = 'kyw-wallet';
const _channelId = 'chan-kyw';
const _mnemonic = 'abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon abandon abandon about';
const _timeout = Duration(seconds: 10);
final _funding = BigInt.from(100000);

void main() {
  late TestActorSystem actorSystem;
  late DartSVCryptoService cryptoService;
  late ActorRef managerRef;
  late _SpyProjection projection;
  late int lockTime;

  late String clientPubKeyHex;
  late String clientAddressB58;
  late String serverPubKeyHex;
  late String serverAddressB58;
  late ({String hex, String txid, String beefHex}) fundingTx;

  setUp(() async {
    lockTime =
        DateTime.now().add(const Duration(days: 1)).millisecondsSinceEpoch ~/ 1000;
    actorSystem = TestActorSystem();
    cryptoService = DartSVCryptoService();
    final hd = await cryptoService.mnemonicToHDPrivateKey(_mnemonic);
    final client = hd.deriveChildKey('m/0/1').privateKey.publicKey;
    final server = hd.deriveChildKey('m/0/2').privateKey.publicKey;
    clientPubKeyHex = client.toString();
    clientAddressB58 = client.toAddress(NetworkType.TEST).toString();
    serverPubKeyHex = server.toString();
    serverAddressB58 = server.toAddress(NetworkType.TEST).toString();
    fundingTx = channelFundingWithBeef(
      clientPubKeyHex: clientPubKeyHex,
      serverPubKeyHex: serverPubKeyHex,
      amountSats: _funding,
    );

    final walletRef = await actorSystem.spawn(
      'wallet-manager',
      () => _SigningWalletManager(
          pubKeyHex: serverPubKeyHex, addressB58: serverAddressB58),
    );
    final spvRef = await actorSystem.spawn('spv', () => ScriptedSpvActor());
    projection = _SpyProjection();
    final projectionRef = await actorSystem.spawn('channel-projection', () => projection);
    final policyArc1 = await actorSystem.spawn('policy-arc-${DateTime.now().microsecondsSinceEpoch}', () => PolicyRateArc());
    managerRef = await actorSystem.spawn(
      'channel-manager',
      () => PaymentChannelManagerActor(
            arcActor: policyArc1,
        walletManager: walletRef,
        eventStore: InMemoryEventStore(),
        cryptoService: cryptoService,
        networkType: NetworkType.TEST,
        channelProjection: projectionRef,
        spvActor: spvRef,
      ),
    );
  });

  tearDown(() async => actorSystem.shutdown());

  /// Server side: accepted, refund countersigned, opened.
  Future<void> openServerChannel() async {
    final accepted = await managerRef.ask<ChannelAcceptedResponse>(
      AcceptChannelMessage(
        channelId: _channelId,
        walletId: _walletId,
        clientPeerId: 'client-peer',
        clientPubKeyHex: clientPubKeyHex,
        clientAddressB58: clientAddressB58,
        fundingAmountSats: _funding,
        lockTimeUnix: lockTime,
      ),
      _timeout,
    );
    expect(accepted.success, isTrue, reason: accepted.error);

    final built = await managerRef.ask<RefundTransactionBuiltResponse>(
      BuildRefundTransactionMessage(
        channelId: _channelId,
        walletId: _walletId,
        fundingTxId: fundingTx.txid,
        fundingOutputIndex: 0,
        fundingAmountSats: _funding,
        clientPubKeyHex: clientPubKeyHex,
        clientAddressB58: clientAddressB58,
        serverPubKeyHex: serverPubKeyHex,
        serverAddressB58: serverAddressB58,
        lockTimeUnix: lockTime,
      ),
      _timeout,
    );
    expect(built.success, isTrue, reason: built.error);

    final signed = await managerRef.ask<RefundTransactionSignedResponse>(
      SignRefundTransactionMessage(
        channelId: _channelId,
        walletId: _walletId,
        refundTxHex: built.refundTxHex,
        clientPubKeyHex: clientPubKeyHex,
        serverPubKeyHex: serverPubKeyHex,
        serverAddressB58: serverAddressB58,
        derivationIndex: 2,
        fundingAmountSats: _funding,
        lockTimeUnix: lockTime,
      ),
      _timeout,
    );
    expect(signed.success, isTrue, reason: signed.error);

    final opened = await managerRef.ask<ChannelOpenedResponse>(
      OpenChannelMessage(
        channelId: _channelId,
        fundingTxId: fundingTx.txid,
        fundingOutputIndex: 0,
        fundingTxHex: fundingTx.hex,
        fundingBeefHex: fundingTx.beefHex,
      ),
      _timeout,
    );
    expect(opened.success, isTrue, reason: opened.error);
  }

  test('a rejected open takes back the awaiter it registered', () async {
    await openServerChannel();
    projection.clear();

    // The channel is open, so the aggregate refuses to open it on another
    // funding output — after the manager has already registered its awaiter.
    //
    // Output 1 of the funding transaction, not 0: a repeat naming the SAME
    // output is the channel_open a client re-sent because the first was
    // lost, and the manager answers that without journaling or registering
    // anything (bead libspiffy-1n3). A different output is a different
    // claim about the channel, and still goes to the aggregate.
    final again = await managerRef.ask<ChannelOpenedResponse>(
      OpenChannelMessage(
        channelId: _channelId,
        fundingTxId: fundingTx.txid,
        fundingOutputIndex: 1,
        fundingTxHex: fundingTx.hex,
        fundingBeefHex: fundingTx.beefHex,
      ),
      _timeout,
    );
    expect(again.success, isFalse, reason: 'the aggregate must refuse a second open');

    expect(projection.registered, hasLength(1),
        reason: 'the awaiter is registered before the command, deliberately');
    expect(projection.cancelled, equals(projection.registered),
        reason: 'a registration nobody will await was left on the projection '
            'until it timed out (bead libspiffy-kyw)');
  });

  test('a rejected expire takes back the awaiter it registered', () async {
    await openServerChannel();
    projection.clear();

    // The lock time is a day away, so the aggregate refuses to expire it.
    final expired = await managerRef.ask<ChannelExpiredResponse>(
      ExpireChannelMessage(channelId: _channelId, observedBy: 'server'),
      _timeout,
    );
    expect(expired.success, isFalse, reason: 'the aggregate must refuse an early expiry');

    expect(projection.registered, hasLength(1));
    expect(projection.cancelled, equals(projection.registered),
        reason: 'the expire path leaks the same way the open path did');
  });

  test('a successful open cancels nothing: the event resolves the awaiter', () async {
    await openServerChannel();

    expect(projection.registered, isNotEmpty);
    expect(projection.cancelled, isEmpty,
        reason: 'a registration that was awaited must not also be cancelled');
  });
}

/// Stands in for the channel projection: records what the manager registers
/// and cancels, and answers every registration at once so the success path
/// does not wait.
class _SpyProjection extends Actor {
  final List<String> registered = [];
  final List<String> cancelled = [];

  void clear() {
    registered.clear();
    cancelled.clear();
  }

  @override
  Future<void> onMessage(dynamic message) async {
    switch (message) {
      case final AwaitEventApplied msg:
        // A registration with no id cannot be cancelled: record it as such so
        // the test sees it rather than silently passing.
        registered.add(msg.awaitId ?? '<no awaitId>');
        context.sender?.tell(EventAppliedResponse());
      case final CancelEventAwait msg:
        cancelled.add(msg.awaitId);
      default:
    }
  }
}

/// Answers address generation with a fixed key and signs every multisig
/// request, so each command reaches the aggregate. Same stub as
/// payment_channel_manager_rejection_test.dart.
class _SigningWalletManager extends Actor {
  final String pubKeyHex;
  final String addressB58;
  int signRequests = 0;

  _SigningWalletManager({required this.pubKeyHex, required this.addressB58});

  @override
  Future<void> onMessage(dynamic message) async {
    if (message is! WalletCommandMessage) return;
    final command = message.command;
    if (command is GenerateAddressCommand) {
      context.sender?.tell(AddressGeneratedResponse(
        walletId: command.walletId,
        address: addressB58,
        derivationIndex: 2,
        success: true,
        publicKeyHex: pubKeyHex,
      ));
    } else if (command is SignMultisigTransactionCommand) {
      signRequests++;
      context.sender?.tell(MultisigTransactionSignedResponse(
        walletId: command.walletId,
        txid: 'c' * 64,
        originalTransactionId: command.transactionId,
        signedHex: command.rawTransaction,
        signatureHex: '30${signRequests.toRadixString(16).padLeft(2, '0')}',
        success: true,
      ));
    }
  }
}
