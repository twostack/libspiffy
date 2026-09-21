/// Bead libspiffy-zj20: the channel server countersigns a payment's
/// transaction only when that transaction pays what the payment says.
///
/// A payment reaches the server as balances and a transaction: "the client
/// now has X, the server Y, and here is the transaction that pays that,
/// signed by me". The server's aggregate checked the balances as numbers
/// (`_checkPaymentInvariants`), and the manager had the wallet sign the
/// transaction over the 2-of-2 funding output without looking at it. The
/// signature then went back to the client in `payment_ack`, so a client
/// could send a transaction that returned the whole funding output to
/// itself, get it countersigned, and broadcast it — taking back every
/// payment it had made. The refund was already checked before its
/// signature was released (bead libspiffy-fsy); the payment was not.
library;

import 'package:dactor/dactor.dart';
import 'package:dactor_test/dactor_test.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:eventador/eventador.dart' show Event;
import 'package:test/test.dart';

import 'package:libspiffy/src/actors/libspiffy_actor_system.dart';
import 'package:libspiffy/src/actors/payment_channel_manager_actor.dart';
import 'package:libspiffy/src/actors/payment_channel_messages.dart';
import 'package:libspiffy/src/core/channel_events.dart';
import 'package:libspiffy/src/services/dartsv_crypto_service.dart';
import 'package:libspiffy/src/services/payment_channel_builder.dart';

import 'channel_test_fixtures.dart';
import 'in_memory_event_store.dart';

const _channelId = 'chan-zj20';
const _walletId = 'wallet';
const _timeout = Duration(seconds: 10);

void main() {
  late TestActorSystem system;
  late InMemoryEventStore store;
  late ChannelRefundFixture f;
  late FixtureWalletManager wallet;
  late ActorRef managerRef;

  /// What the client says the payment leaves each side with: 30,000 to the
  /// server.
  final paid = BigInt.from(30000);

  setUpAll(LibSpiffyActorSystem.registerEventTypes);

  setUp(() async {
    system = TestActorSystem();
    store = InMemoryEventStore();
    f = await ChannelRefundFixture.create(channelId: _channelId);
    await store.persistEvents('PaymentChannel_$_channelId', <Event>[
      f.serverAccepted(version: 1),
      RefundCountersignedEvent(
        channelId: _channelId,
        serverSignatureHex: f.serverSignatureHex,
        signedRefundTxHex: f.signedRefundTxHex(),
        version: 2,
      ),
      ChannelOpenedEvent(
        channelId: _channelId,
        fundingTxId: f.fundingTxId,
        fundingOutputIndex: 0,
        fundingTxHex: f.fundingTxHex,
        initialClientBalanceSats: f.amountSats,
        initialServerBalanceSats: BigInt.zero,
        version: 3,
      ),
    ], 0);
    wallet = FixtureWalletManager(f.serverKey);
    final walletRef = await system.spawn('wallet', () => wallet);
    managerRef = await system.spawn(
      'manager',
      () => PaymentChannelManagerActor(
        walletManager: walletRef,
        eventStore: store,
        cryptoService: DartSVCryptoService(),
        signingTimeout: const Duration(seconds: 2),
      ),
    );
  });

  tearDown(() => system.shutdown());

  List<Event> journal() => store.journal['PaymentChannel_$_channelId'] ?? [];

  /// The transaction an honest client sends for a payment of [paid]: the
  /// builder's, spending the funding output and paying both sides.
  Future<dartsv.Transaction> honest() async => (await PaymentChannelBuilder(cryptoService: DartSVCryptoService())
          .buildPaymentTransaction(
        fundingTxId: f.fundingTxId,
        fundingOutputIndex: 0,
        fundingAmountSats: f.amountSats,
        clientPubKey: f.clientKey.publicKey,
        serverPubKey: f.serverKey.publicKey,
        clientAddress: dartsv.Address.fromBase58(f.clientAddressB58),
        serverAddress: dartsv.Address.fromBase58(f.serverAddressB58),
        serverAmountSats: paid,
        sequenceNumber: 1,
      ))
          .transaction;

  dartsv.SVScript p2pkh(String address) =>
      dartsv.P2PKHLockBuilder.fromAddress(dartsv.Address.fromBase58(address)).getScriptPubkey();

  /// Sends [tx] as the transaction of a payment of [paid], signed by the
  /// client, and returns the server's answer.
  Future<PaymentAcknowledgedResponse> send(dartsv.Transaction tx) async {
    final clientSignature = (await PaymentChannelBuilder(cryptoService: DartSVCryptoService()).signMultisigInput(
      transaction: tx,
      inputIndex: 0,
      privateKey: f.clientKey,
      clientPubKey: f.clientKey.publicKey,
      serverPubKey: f.serverKey.publicKey,
      inputAmountSats: f.amountSats,
    ))
        .signatureHex;
    return managerRef.ask<PaymentAcknowledgedResponse>(
      AcknowledgePaymentMessage(
        channelId: _channelId,
        walletId: _walletId,
        amountSats: paid,
        paymentTxHex: tx.serialize(),
        clientSignatureHex: clientSignature,
        proposedSequence: 1,
        proposedClientBalance: f.amountSats - paid,
        proposedServerBalance: paid,
      ),
      _timeout,
    );
  }

  /// The server refused: no signature left it and nothing was journaled.
  void expectRefused(PaymentAcknowledgedResponse reply, Matcher reason) {
    expect(reply.success, isFalse, reason: 'the server countersigned it');
    expect(reply.error, reason);
    expect(reply.serverSignatureHex, anyOf(isNull, isEmpty));
    expect(reply.fullySignedPaymentTxHex, anyOf(isNull, isEmpty));
    expect(journal().whereType<PaymentAcknowledgedEvent>(), isEmpty);
  }

  test('zj20: the transaction an honest client builds for the payment is countersigned', () async {
    final reply = await send(await honest());

    expect(reply.success, isTrue, reason: reply.error);
    expect(reply.serverSignatureHex, isNotEmpty);
    expect(journal().whereType<PaymentAcknowledgedEvent>(), hasLength(1));
  });

  test('zj20: a transaction returning the whole channel to the client is refused, not countersigned', () async {
    final theft = await honest();
    theft.outputs
      ..clear()
      ..add(dartsv.TransactionOutput(f.amountSats - BigInt.from(100), p2pkh(f.clientAddressB58)));

    // Old code: success, with the server's signature on a transaction that
    // pays the server nothing.
    expectRefused(await send(theft), contains('server'));
  });

  test('zj20: a transaction paying the server less than the payment says is refused', () async {
    final short = await honest();
    final server = short.outputs.indexWhere((o) => o.script.toHex() == p2pkh(f.serverAddressB58).toHex());
    short.outputs[server] = dartsv.TransactionOutput(paid - BigInt.one, p2pkh(f.serverAddressB58));

    expectRefused(await send(short), contains('server'));
  });

  test('zj20: a transaction paying out more than the channel holds is refused: the server could never mine it',
      () async {
    // The server's output is exactly right; the client's is larger than its
    // balance, so the outputs exceed the funding output. No node accepts
    // that, so the server would hold a payment it cannot claim, while the
    // refund returns everything to the client at the lock time.
    final unminable = await honest();
    final client = unminable.outputs.indexWhere((o) => o.script.toHex() == p2pkh(f.clientAddressB58).toHex());
    unminable.outputs[client] = dartsv.TransactionOutput(f.amountSats - paid + BigInt.one, p2pkh(f.clientAddressB58));

    expectRefused(await send(unminable), contains('client'));
  });

  test('zj20: a transaction with an output to anyone else is refused', () async {
    final other = dartsv.SVPrivateKey.fromHex('55' * 32, dartsv.NetworkType.TEST)
        .publicKey
        .toAddress(dartsv.NetworkType.TEST)
        .toBase58();
    final diverted = await honest();
    final client = diverted.outputs.indexWhere((o) => o.script.toHex() == p2pkh(f.clientAddressB58).toHex());
    final clientSats = diverted.outputs[client].satoshis;
    diverted.outputs[client] = dartsv.TransactionOutput(clientSats - BigInt.from(1000), p2pkh(f.clientAddressB58));
    diverted.outputs.add(dartsv.TransactionOutput(BigInt.from(1000), p2pkh(other)));

    expectRefused(await send(diverted), contains(other));
  });

  test('zj20: a transaction the server could not broadcast until a lock time is refused', () async {
    final locked = await honest();
    locked.nLockTime = f.lockTimeUnix;

    expectRefused(await send(locked), contains('lock time'));
  });

  test('zj20: a transaction that spends anything but the funding output is refused', () async {
    final elsewhere = await honest();
    elsewhere.inputs.add(dartsv.TransactionInput('cd' * 32, 0, dartsv.TransactionInput.MAX_SEQ_NUMBER));

    expectRefused(await send(elsewhere), contains('funding output'));
  });
}
