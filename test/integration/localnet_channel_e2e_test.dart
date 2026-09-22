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
/// Tagged `localnet` and skipped by default (see localnet_harness.dart);
/// run with
///   dart test -P localnet test/integration/localnet_channel_e2e_test.dart
@Tags(['localnet'])
library;

import 'dart:async';

import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:test/test.dart';

import 'package:libspiffy/coordinator.dart';
import 'package:libspiffy/libspiffy.dart';
import 'package:libspiffy/src/core/channel_events.dart' show RefundClaimedEvent;
import 'package:libspiffy/src/models/payment_channel.dart' show PaymentChannelState;

import 'isar_test_helper.dart';
import 'localnet_harness.dart';
import 'p2p_test_helpers.dart' show kTestXpriv, kTestRootAddress;

void main() {
  late LocalnetNode alice;
  late LocalnetNode bob;
  String? unavailable;

  /// A short but real channel timing: payments stop and the server settles
  /// 30 seconds before the lock time; a channel must run two minutes.
  final timing = ChannelTiming(
    settlementMargin: Duration(seconds: 30),
    minimumLifetime: Duration(minutes: 2),
  );

  setUpAll(() async {
    unavailable = await localnetProblem();
    if (unavailable != null) return;
    await ensureIsarInitialized();
  });

  setUp(() async {
    if (unavailable != null) markTestSkipped(unavailable!);
    if (unavailable != null) return;
    alice = await LocalnetNode.start('alice-peer', timing);
    bob = await LocalnetNode.start('bob-peer', timing);
    link(alice, bob);
    link(bob, alice);
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
    await alice.createWallet(aliceWallet, xpriv: kTestXpriv);
    await bob.createWallet(bobWallet, mnemonic: bobMnemonic);

    await alice.receiveMined(aliceWallet, kTestRootAddress, bsv: bsv);
    await bob.headersAt(await rpc('getblockcount') as int);
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

  test('alice syncs regtest headers and imports a mined payment with its proof',
      () async {
    if (unavailable != null) return;
    final tip = await rpc('getblockcount') as int;
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

    final height = await mine();
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
    await mine();
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
    expect(await arcStatus(refundTxId), isNull,
        reason: 'the refund went to ARC before its lock time');

    // Past the lock time on the clock, the chain's median time still trails
    // it: the node would hold the refund as non-final, and drop it for any
    // final spend of the funding output. Refused, and nothing broadcast.
    await until(lockTime);
    final tooSoon = await claimRefund(channelId);
    expect(tooSoon.success, isFalse);
    expect(tooSoon.error, contains('median time past'));
    expect(await arcStatus(refundTxId), isNull);

    // Once the median time has passed the lock time, and Alice's headers
    // show it, the claim goes through and the refund is mined.
    await alice.headersAt(await mineUntilMedianTime(lockTime + 1));
    final claimed = await claimRefund(channelId);
    expect(claimed.success, isTrue, reason: claimed.error);
    expect(claimed.refundTxId, refundTxId);
    await mine();
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
    await until(lockTime);
    await alice.headersAt(await mineUntilMedianTime(lockTime + 1));

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
    await until(lockTime);
    await alice.headersAt(await mineUntilMedianTime(lockTime + 1));
    final claimed = await claimRefund(channelId);
    expect(claimed.success, isTrue, reason: claimed.error);

    // Bob comes back: his startup settles the channel he still holds open,
    // and his app closes it too, at once. The refund was first. ARC answers
    // the first submission of his settlement DOUBLE_SPEND_ATTEMPTED, and the
    // second, which arrives while it is still deciding, with an in-flight
    // status that Bob follows to the same verdict (bead libspiffy-m715).
    // Neither is a settlement the network holds, and Bob records no close
    // (bead libspiffy-jh6a; he used to close on the second answer).
    await bob.restart();
    bob.coordinator.tell(CloseChannelCommand(channelId: channelId));
    Iterable<ErrorEvent> contested() => bob.events
        .whereType<ErrorEvent>()
        .where((e) => e.message.contains('contested'));
    final deadline = DateTime.now().add(const Duration(seconds: 60));
    while (contested().length < 2 && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    expect(contested(), hasLength(2), reason: 'Bob:\n  ${bob.trace()}');
    expect(bob.events.whereType<ChannelClosedEvent>(), isEmpty,
        reason: 'Bob:\n  ${bob.trace()}');
    expect(bob.events.whereType<ErrorEvent>(), hasLength(2),
        reason: 'Bob:\n  ${bob.trace()}');
    final row = (await bob.system.walletStorage.getPaymentChannel(channelId))!;
    expect(row.state, PaymentChannelState.closing);

    await mine();
    expect((await onNode(refundTxId))!['confirmations'], greaterThan(0));
  }, timeout: const Timeout(Duration(minutes: 6)));
}
