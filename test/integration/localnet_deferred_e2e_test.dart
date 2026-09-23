/// Deferred payments and double spends run end to end on the real BSV
/// regtest network, against a real ARC (see localnet_harness.dart).
///
/// A payment Alice hands Bob is deferred: her inputs stay held for it, and
/// her change is not hers to spend, until the network has it. Bob may
/// broadcast it, or not. Alice can check what the network knows, broadcast
/// it herself, cancel it while nobody has it, or reclaim it by spending
/// its inputs back to herself. When both copies reach the network, the
/// first one seen wins (spv-understanding.md): the other is a double spend,
/// and each wallet records the winner.
///
/// Tagged `localnet` and skipped by default; run with
///   dart test -P localnet test/integration/localnet_deferred_e2e_test.dart
@Tags(['localnet'])
library;

import 'package:convert/convert.dart';
import 'package:dactor/dactor.dart' show Message;
import 'package:test/test.dart';

import 'package:libspiffy/coordinator.dart';
import 'package:libspiffy/libspiffy.dart';

import 'isar_test_helper.dart';
import 'localnet_harness.dart';
import 'p2p_test_helpers.dart' show kTestXpriv, kTestRootAddress;

void main() {
  late LocalnetNode alice;
  late LocalnetNode bob;
  late String aliceWallet;
  late String bobWallet;
  String? unavailable;
  var requests = 0;

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
    final ts = DateTime.now().microsecondsSinceEpoch;
    aliceWallet = 'alice-$ts';
    bobWallet = 'bob-$ts';
    await alice.createWallet(aliceWallet, xpriv: kTestXpriv);
    await bob.createWallet(bobWallet, mnemonic: bobMnemonic);
    await alice.receiveMined(aliceWallet, kTestRootAddress);
    await bob.headersAt(await rpc('getblockcount') as int);
  });

  tearDown(() async {
    if (unavailable != null) return;
    await alice.stop();
    await bob.stop();
  });

  /// Bob invoices [amount] and Alice pays it: the payment she hands him,
  /// deferred until the network has it.
  Future<(String, PaymentReadyEvent)> handOver(int amount) async {
    final created = bob.next<InvoiceCreatedEvent>((e) => e.walletId == bobWallet);
    bob.coordinator.tell(CreateInvoiceCommand(
      walletId: bobWallet,
      amount: BigInt.from(amount),
      description: 'localnet deferred',
      expiresInSeconds: 3600,
    ));
    final invoice = await created;
    expect(invoice.success, isTrue, reason: invoice.error);
    final ready = alice.next<PaymentReadyEvent>((e) => e.invoiceId == invoice.invoiceId);
    alice.coordinator.tell(PayInvoiceCommand(
      walletId: aliceWallet,
      invoiceId: invoice.invoiceId,
      addresses: [invoice.addresses.first],
      amount: BigInt.from(amount),
    ));
    final payment = await ready;
    expect(payment.success, isTrue, reason: payment.error);
    return (invoice.invoiceId, payment);
  }

  /// Bob validates the BEEF Alice handed him and submits it.
  Future<BEEFValidationResultEvent> bobReceives(String invoiceId, PaymentReadyEvent payment) {
    final result = bob.next<BEEFValidationResultEvent>(
        (e) => e.walletId == bobWallet && e.txid == payment.txid);
    bob.coordinator.tell(ValidateBEEFCommand(
      walletId: bobWallet,
      beefHex: hex.encode(payment.beefBytes),
      invoiceId: invoiceId,
    ));
    return result;
  }

  /// Alice's deferred payments, every state.
  Future<Map<String, DeferredPaymentDetail>> deferred() async {
    final queryId = 'deferred-${requests++}';
    final answer = alice.next<DeferredPaymentsResponse>((e) => e.queryId == queryId);
    alice.coordinator.tell(GetDeferredPaymentsQuery(
        walletId: aliceWallet, includeResolved: true, includeBeef: false, queryId: queryId));
    return {for (final p in (await answer).payments) p.txid: p};
  }

  /// Alice's deferred payment [txid], which must be in [state] now: every
  /// answer about it comes once her read model shows it. A payment seen on
  /// the network may be mined already by the stack's autominer.
  Future<DeferredPaymentDetail> deferredIn(String txid, DeferredPaymentState state) async {
    final payment = (await deferred())[txid];
    expect(payment, isNotNull, reason: 'Alice has no deferred payment $txid');
    expect(payment!.state,
        state == DeferredPaymentState.seen ? isIn([state, DeferredPaymentState.mined]) : state);
    return payment;
  }

  Future<T> ask<T extends CoordinatorEvent>(
      Message Function(String requestId) command, String Function(T) requestIdOf) {
    final requestId = 'request-${requests++}';
    final answer = alice.next<T>((e) => requestIdOf(e) == requestId);
    alice.coordinator.tell(command(requestId));
    return answer;
  }

  Future<DeferredPaymentStatusEvent> check(String txid) => ask<DeferredPaymentStatusEvent>(
      (id) => CheckDeferredPaymentStatusCommand(walletId: aliceWallet, txid: txid, requestId: id),
      (e) => e.requestId);

  Future<DeferredPaymentBroadcastEvent> broadcast(String txid) => ask<DeferredPaymentBroadcastEvent>(
      (id) => BroadcastDeferredPaymentCommand(walletId: aliceWallet, txid: txid, requestId: id),
      (e) => e.requestId);

  Future<DeferredPaymentCancelledEvent> cancel(String txid) => ask<DeferredPaymentCancelledEvent>(
      (id) => CancelDeferredPaymentCommand(
          walletId: aliceWallet, txid: txid, reason: 'Bob never took it', requestId: id),
      (e) => e.requestId);

  Future<DeferredPaymentReclaimedEvent> reclaim(String txid) => ask<DeferredPaymentReclaimedEvent>(
      (id) => ReclaimDeferredPaymentCommand(
          walletId: aliceWallet, txid: txid, reason: 'Bob never took it', requestId: id),
      (e) => e.requestId);

  /// Mines a block and waits until [node] confirms each of [txids], at the
  /// height the chain holds it at: ours, or an earlier block anything else
  /// mining this shared chain took it in first.
  Future<int> mineAndConfirm(Map<LocalnetNode, List<String>> txids) async {
    final confirmations = [
      for (final MapEntry(key: node, value: ids) in txids.entries)
        for (final txid in ids)
          node.next<TransactionConfirmedEvent>((e) => e.txid == txid,
              timeout: const Duration(minutes: 2)),
    ];
    final height = await mine();
    for (final confirmed in await Future.wait(confirmations)) {
      expect(confirmed.blockHeight, await minedAt(confirmed.txid));
    }
    return height;
  }

  final funded = BigInt.from(1000000);

  test('Bob never broadcasts the payment: ARC does not know it, Alice broadcasts it herself, '
      'and a block confirms it for both', () async {
    if (unavailable != null) return;
    final (invoiceId, payment) = await handOver(50000);

    final held = (await deferred())[payment.txid]!;
    expect(held.state, DeferredPaymentState.outstanding);
    expect(held.payment.heldSatoshis, funded);
    expect((await alice.balance(aliceWallet)).reservedBalance, funded);

    final checked = await check(payment.txid);
    expect(checked.success, isTrue, reason: checked.error);
    expect(checked.networkStatus, DeferredNetworkStatus.notFound);
    expect((await deferredIn(payment.txid, DeferredPaymentState.outstanding)).lastNetworkStatus,
        DeferredNetworkStatus.notFound);

    final sent = await broadcast(payment.txid);
    expect(sent.success, isTrue, reason: sent.error);
    expect(DeferredNetworkStatus.isOnNetwork(sent.networkStatus), isTrue, reason: sent.networkStatus);
    await arcHolds(payment.txid);
    expect(await onNode(payment.txid), isNotNull);
    await deferredIn(payment.txid, DeferredPaymentState.seen);
    final aliceHeld = await alice.balance(aliceWallet);
    expect(aliceHeld.reservedBalance, BigInt.zero, reason: 'the network has it: her input is spent');
    expect(aliceHeld.totalBalance, payment.changeAmount);

    // Bob is handed it late, after the network has it: he takes it as paid.
    final received = await bobReceives(invoiceId, payment);
    expect(received.valid, isTrue, reason: received.error);
    expect((await bob.balance(bobWallet)).totalBalance, BigInt.from(50000));

    await mineAndConfirm({alice: [payment.txid], bob: [payment.txid]});
    await deferredIn(payment.txid, DeferredPaymentState.mined);
    expect((await alice.balance(aliceWallet)).confirmedBalance, payment.changeAmount);
    expect((await bob.balance(bobWallet)).confirmedBalance, BigInt.from(50000));
    expect(alice.events.whereType<ErrorEvent>(), isEmpty, reason: alice.trace());
    expect(bob.events.whereType<ErrorEvent>(), isEmpty, reason: bob.trace());
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('Alice cancels a payment nobody broadcast: her funds are back; when Bob broadcasts his copy '
      'anyway, the network has it and her wallet records it paid', () async {
    if (unavailable != null) return;
    final (invoiceId, payment) = await handOver(40000);

    final cancelled = await cancel(payment.txid);
    expect(cancelled.success, isTrue, reason: cancelled.error);
    expect(cancelled.networkStatus, DeferredNetworkStatus.notFound);
    expect(cancelled.releasedUtxoKeys, hasLength(1));
    expect((await deferred())[payment.txid]!.state, DeferredPaymentState.cancelled);
    final restored = await alice.balance(aliceWallet);
    expect(restored.confirmedBalance, funded);
    expect(restored.reservedBalance, BigInt.zero);

    // Cancelling revokes nothing: Bob's signed copy still spends her coins.
    final received = await bobReceives(invoiceId, payment);
    expect(received.valid, isTrue, reason: received.error);
    expect(received.broadcasted, isTrue, reason: received.broadcastError);
    await arcHolds(payment.txid);

    final checked = await check(payment.txid);
    expect(DeferredNetworkStatus.isOnNetwork(checked.networkStatus), isTrue, reason: checked.networkStatus);
    await deferredIn(payment.txid, DeferredPaymentState.seen);
    final paid = await alice.balance(aliceWallet);
    expect(paid.reservedBalance, BigInt.zero);
    expect(paid.totalBalance, payment.changeAmount,
        reason: 'her coins are spent by the payment the network has');

    await mineAndConfirm({alice: [payment.txid], bob: [payment.txid]});
    expect((await alice.balance(aliceWallet)).confirmedBalance, payment.changeAmount);
    expect((await bob.balance(bobWallet)).confirmedBalance, BigInt.from(40000));
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('Alice reclaims a payment nobody broadcast; Bob\'s copy, submitted after, is a double spend '
      'and he is not paid; a block confirms the reclaim', () async {
    if (unavailable != null) return;
    final (invoiceId, payment) = await handOver(30000);

    final reclaimed = await reclaim(payment.txid);
    expect(reclaimed.success, isTrue, reason: reclaimed.error);
    expect(DeferredNetworkStatus.isOnNetwork(reclaimed.networkStatus), isTrue, reason: reclaimed.networkStatus);
    final reclaimTxid = reclaimed.reclaimTxid!;
    await arcHolds(reclaimTxid);
    expect(reclaimed.reclaimedSatoshis, funded - reclaimed.fee!);
    final resolved = await deferredIn(payment.txid, DeferredPaymentState.reclaimed);
    expect(resolved.resolutionReason, contains(reclaimTxid));

    // Bob submits his copy now: the network already saw its input spent.
    // ARC keeps it, contested, in case it is mined after all; Bob holds it
    // as pending, not as money, and his invoice is not paid (bead
    // libspiffy-yyby).
    final received = await bobReceives(invoiceId, payment);
    expect(received.valid, isTrue, reason: received.error);
    expect(received.networkStatus, DeferredNetworkStatus.doubleSpendAttempted);
    final bobBalance = await bob.balance(bobWallet);
    expect(bobBalance.totalBalance, BigInt.zero, reason: 'Bob counted a payment the network refused');
    expect(bob.events.whereType<InvoicePaidEvent>(), isEmpty,
        reason: 'Bob\'s invoice was paid by a double spend (bead libspiffy-yyby)');

    await mineAndConfirm({alice: [reclaimTxid]});
    expect(await onNode(payment.txid), isNull);
    final after = await alice.balance(aliceWallet);
    expect(after.confirmedBalance, funded - reclaimed.fee!);
    expect(after.reservedBalance, BigInt.zero);
    expect((await deferred())[payment.txid]!.state, DeferredPaymentState.reclaimed);
    expect((await bob.balance(bobWallet)).totalBalance, BigInt.zero);
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('Bob gets his copy out first; Alice\'s reclaim loses the race: first seen wins, and both '
      'wallets record the payment', () async {
    if (unavailable != null) return;
    final (invoiceId, payment) = await handOver(20000);

    final received = await bobReceives(invoiceId, payment);
    expect(received.broadcasted, isTrue, reason: received.broadcastError);
    await arcHolds(payment.txid);

    final reclaimed = await reclaim(payment.txid);
    expect(reclaimed.success, isFalse, reason: 'the reclaim spends inputs the network saw spent');
    expect(reclaimed.networkStatus,
        isIn([DeferredNetworkStatus.doubleSpendAttempted, DeferredNetworkStatus.rejected]));
    expect(reclaimed.competingTxids, contains(payment.txid));

    // ARC now flags Bob's copy too: two spends of one input are both
    // contested until a block settles it (the first seen is the one mined).
    final checked = await check(payment.txid);
    expect(checked.networkStatus,
        isIn([DeferredNetworkStatus.seenOnNetwork, DeferredNetworkStatus.doubleSpendAttempted]));
    expect((await alice.balance(aliceWallet)).confirmedBalance, BigInt.zero,
        reason: 'neither the payment\'s change nor the reclaim is Alice\'s to spend yet');

    // The block: Bob's copy is mined, and each wallet records it.
    await mineAndConfirm({alice: [payment.txid], bob: [payment.txid]});
    expect(await onNode(reclaimed.reclaimTxid!), isNull);
    await deferredIn(payment.txid, DeferredPaymentState.mined);
    final aliceAfter = await alice.balance(aliceWallet);
    expect(aliceAfter.confirmedBalance, payment.changeAmount);
    expect(aliceAfter.unconfirmedBalance, BigInt.zero);
    expect(aliceAfter.reservedBalance, BigInt.zero, reason: 'the reclaim that lost still holds her input');
    expect((await bob.balance(bobWallet)).confirmedBalance, BigInt.from(20000));
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('Bob submits his copy after the reclaim is mined: its input is spent in a block, and '
      'neither wallet counts it', () async {
    if (unavailable != null) return;
    final (invoiceId, payment) = await handOver(25000);

    final reclaimed = await reclaim(payment.txid);
    expect(reclaimed.success, isTrue, reason: reclaimed.error);
    await mineAndConfirm({alice: [reclaimed.reclaimTxid!]});

    final received = await bobReceives(invoiceId, payment);
    expect(received.networkStatus, DeferredNetworkStatus.seenInOrphanMempool);
    expect((await bob.balance(bobWallet)).totalBalance, BigInt.zero);
    expect(bob.events.whereType<InvoicePaidEvent>(), isEmpty,
        reason: 'Bob\'s invoice was paid by a payment spending an output already spent in a block');

    final checked = await check(payment.txid);
    expect(checked.success, isTrue, reason: checked.error);
    expect((await deferred())[payment.txid]!.state, DeferredPaymentState.reclaimed,
        reason: 'what ARC says of the losing copy does not take the reclaim back');
    final after = await alice.balance(aliceWallet);
    expect(after.confirmedBalance, funded - reclaimed.fee!);
    expect(after.reservedBalance, BigInt.zero);
  }, timeout: const Timeout(Duration(minutes: 5)));
}
