/// Bead libspiffy-zs4l: the refund and the payments a channel manager builds
/// pay ARC's published policy rate on their signed size.
///
/// They were built by `PaymentChannelBuilder` at its default of 1 sat/kB,
/// with a 300-byte guess for the 2-of-2 input: a 1-satoshi fee each. The
/// owner's rule (21 Sep) is that every fee is ARC's policy rate, so the
/// manager asks its ARC for the rate, and a channel with no ARC to ask
/// builds nothing.
library;

import 'package:dactor/dactor.dart';
import 'package:dactor_test/dactor_test.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:test/test.dart';

import 'package:libspiffy/src/actors/libspiffy_actor_system.dart';
import 'package:libspiffy/src/actors/payment_channel_manager_actor.dart';
import 'package:libspiffy/src/actors/payment_channel_messages.dart';
import 'package:libspiffy/src/core/wallet/transaction_size.dart';
import 'package:libspiffy/src/models/fee_rate.dart';
import 'package:libspiffy/src/services/dartsv_crypto_service.dart';
import 'package:libspiffy/src/services/payment_channel_builder.dart';

import '../mocks/policy_rate_arc.dart';
import 'channel_test_fixtures.dart';
import 'in_memory_event_store.dart';

const _channelId = 'chan-zs4l';
const _walletId = 'wallet';
const _timeout = Duration(seconds: 10);

/// Not the 1 sat/kB the builder defaulted to, nor the 100 hardcoded
/// elsewhere: the rate is ARC's.
const _rate = FeeRate(satoshis: 500, bytes: 1000);

void main() {
  late TestActorSystem system;
  late InMemoryEventStore store;
  late ChannelRefundFixture f;
  late ActorRef managerRef;

  setUpAll(LibSpiffyActorSystem.registerEventTypes);

  setUp(() async {
    system = TestActorSystem();
    store = InMemoryEventStore();
    f = await ChannelRefundFixture.create(channelId: _channelId);
  });

  tearDown(() => system.shutdown());

  /// A client-side manager whose ARC publishes [rate] (none when [withArc]
  /// is false), over the fixture channel: open on the client, or only
  /// accepted by the server when [accepted] (the state a refund is built in).
  Future<void> spawnClient({FeeRate? rate = _rate, bool withArc = true, bool accepted = false}) async {
    await store.persistEvents(
        'PaymentChannel_$_channelId',
        accepted
            ? [f.requested(version: 1, walletId: _walletId), f.serverAcceptance(version: 2)]
            : f.openClientJournal(walletId: _walletId),
        0);
    final walletRef = await system.spawn('wallet', () => FixtureWalletManager(f.clientKey));
    final arcRef = withArc ? await system.spawn('arc', () => PolicyRateArc(rate)) : null;
    managerRef = await system.spawn(
      'manager',
      () => PaymentChannelManagerActor(
        walletManager: walletRef,
        eventStore: store,
        cryptoService: DartSVCryptoService(),
        arcActor: arcRef,
        signingTimeout: const Duration(seconds: 2),
      ),
    );
  }

  dartsv.SVScript multisig() => const PaymentChannelBuilder()
      .buildMultisigRedeemScript(clientPubKey: f.clientKey.publicKey, serverPubKey: f.serverKey.publicKey);

  Future<RefundTransactionBuiltResponse> buildRefund() => managerRef.ask<RefundTransactionBuiltResponse>(
        BuildRefundTransactionMessage(
          channelId: _channelId,
          walletId: _walletId,
          fundingTxId: f.fundingTxId,
          fundingTxHex: f.fundingTxHex,
          fundingOutputIndex: 0,
          fundingAmountSats: f.amountSats,
          clientPubKeyHex: f.clientPubKeyHex,
          clientAddressB58: f.clientAddressB58,
          serverPubKeyHex: f.serverPubKeyHex,
          serverAddressB58: f.serverAddressB58,
          lockTimeUnix: f.lockTimeUnix,
        ),
        _timeout,
      );

  Future<PaymentRecordedResponse> pay(int sats) => managerRef.ask<PaymentRecordedResponse>(
        RecordPaymentMessage(channelId: _channelId, walletId: _walletId, amountSats: BigInt.from(sats)),
        _timeout,
      );

  BigInt feeOf(String txHex) =>
      f.amountSats - dartsv.Transaction.fromHex(txHex).outputs.fold<BigInt>(BigInt.zero, (sum, o) => sum + o.satoshis);

  test('zs4l: the refund pays the rate ARC publishes on its signed size', () async {
    await spawnClient(accepted: true);

    final built = await buildRefund();

    expect(built.success, isTrue, reason: built.error);
    // Old code: 1 satoshi, at the builder's 1 sat/kB default.
    expect(
        feeOf(built.refundTxHex),
        _rate.feeFor(TransactionSize.of(
          inputLockingScripts: [multisig().toHex()],
          outputScriptBytes: const [TransactionSize.p2pkhScriptBytes],
        )));
  });

  test('zs4l: a payment pays the rate ARC publishes on its signed size', () async {
    await spawnClient();

    final paid = await pay(30000);

    expect(paid.success, isTrue, reason: paid.error);
    expect(feeOf(paid.paymentTxHex), PaymentChannelBuilder.paymentFee(multisig(), _rate));
    expect(dartsv.Transaction.fromHex(paid.paymentTxHex).outputs.map((o) => o.satoshis),
        containsAll([BigInt.from(30000), f.amountSats - BigInt.from(30000) - PaymentChannelBuilder.paymentFee(multisig(), _rate)]),
        reason: 'the fee comes out of the client\'s share');
  });

  test('zs4l: with no rate from ARC, no refund is built', () async {
    await spawnClient(rate: null, accepted: true);

    final refund = await buildRefund();

    expect(refund.success, isFalse);
    expect(refund.error, contains('policy'));
  });

  test('zs4l: with no rate from ARC, no payment is built', () async {
    await spawnClient(rate: null);

    final paid = await pay(30000);

    expect(paid.success, isFalse);
    expect(paid.error, contains('policy'));
  });

  test('zs4l: a channel with no ARC builds no refund: there is no rate to pay', () async {
    await spawnClient(withArc: false, accepted: true);

    final refund = await buildRefund();

    expect(refund.success, isFalse);
    expect(refund.error, contains('ARC'));
  });
}
