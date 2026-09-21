/// Bead libspiffy-7p2 end to end through the coordinator facade: list the
/// payments handed to recipients, check one now, broadcast it ourselves,
/// cancel one, and see ARC's REJECTED fail one; journaled, so a read model
/// rebuilt from the journal agrees. ARC is the no-network stand-in: a
/// transaction nobody submitted is unknown (404).
import 'dart:async';
import 'dart:io';

import 'package:dactor/dactor.dart';
import 'package:eventador/eventador.dart' show Event;
import 'package:isar/isar.dart';
import 'package:test/test.dart';

import 'package:libspiffy/libspiffy.dart';
import 'package:libspiffy/coordinator.dart';
import 'package:libspiffy/src/core/wallet_events.dart' as we;
import 'package:libspiffy/src/storage/isar_wallet_storage.dart';
import 'package:libspiffy/src/utils/beef.dart';

import '../mocks/network_arc.dart';
import 'isar_test_helper.dart';
import 'p2p_test_helpers.dart';

const _fundingKey = 'a05924fcc63712d3e4b94b0c88baad234c2c8ad3d369704f53765e21a53a2101:1';
const _recipient = 'muq9kAb9ri62VChAMRkuwK5bTve4iDLWBg';

void main() {
  late Directory dir;
  late LibSpiffyActorSystem libspiffy;
  late LocalActorSystem actorSystem;
  late NetworkArc arc;
  late String walletId;
  late Stream<CoordinatorEvent> events;

  setUpAll(() async {
    await ensureIsarInitialized();
  });

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('deferred_coordinator_');
    actorSystem = LocalActorSystem(ActorSystemConfig());
    final isar = await Isar.open(
      LibSpiffySchemas.allSchemas,
      directory: dir.path,
      name: 'deferred_coordinator_${DateTime.now().microsecondsSinceEpoch}',
    );
    arc = NetworkArc();
    libspiffy = LibSpiffyActorSystem();
    await libspiffy.initialize(
      actorSystem: actorSystem,
      isar: isar,
      dataDirectory: dir.path,
      enableP2P: false,
      arcService: arc,
      secureStorage: InMemorySecureStorage(),
    );
    await setupTestHeaders(libspiffy.walletStorage as IsarWalletStorage);
    events = libspiffy.coordinatorEvents!;
    walletId = 'deferred-${DateTime.now().microsecondsSinceEpoch}';
    await createWallet(
      walletManager: libspiffy.walletManager,
      actorSystem: actorSystem,
      walletId: walletId,
      walletName: 'Deferred',
      xpriv: kTestXpriv,
    );
    await fundWallet(
      walletManager: libspiffy.walletManager,
      actorSystem: actorSystem,
      walletId: walletId,
      amount: BigInt.from(1000000),
    );
  });

  tearDown(() async {
    await libspiffy.shutdown();
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  });

  ReadModelStorage storage() => libspiffy.walletStorage;

  /// Sends [command] and returns the first coordinator event of type [T]
  /// matching [where].
  Future<T> send<T extends CoordinatorEvent>(Message command, [bool Function(T e)? where]) async {
    final result = events
        .where((e) => e is T && (where == null || where(e)))
        .cast<T>()
        .first
        .timeout(const Duration(seconds: 30));
    libspiffy.coordinator.tell(command);
    return result;
  }

  Future<void> until(Future<bool> Function() condition, String what) async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (!await condition()) {
      if (DateTime.now().isAfter(deadline)) fail('Timed out waiting for $what');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  Future<BitcoinUtxo> funding() async =>
      (await storage().getUTXOs(walletId, includeSpent: true)).firstWhere((u) => u.key == _fundingKey);

  Future<PaymentReadyEvent> pay(String invoiceId, {int amount = 100000}) async {
    final ready = await send<PaymentReadyEvent>(
      PayInvoiceCommand(
        walletId: walletId,
        invoiceId: invoiceId,
        addresses: const [_recipient],
        amount: BigInt.from(amount),
      ),
      (e) => e.invoiceId == invoiceId,
    );
    expect(ready.success, isTrue, reason: ready.error);
    // The hold is projected right after the recording the payment waited for.
    await until(() async => (await storage().getDeferredPayment(walletId, ready.txid)) != null,
        'the deferred payment row');
    return ready;
  }

  Future<DeferredPaymentsResponse> list(GetDeferredPaymentsQuery query) =>
      send<DeferredPaymentsResponse>(query, (e) => e.queryId == query.correlationId);

  /// Every wallet journal event replayed into a fresh read model.
  Future<InMemoryWalletStorage> rebuildFromJournal() async {
    final fresh = InMemoryWalletStorage();
    final projection = WalletProjection(
      projectionId: 'rebuild-${DateTime.now().microsecondsSinceEpoch}',
      eventStore: libspiffy.eventStore,
      storage: fresh,
    );
    final List<Event> journal = await libspiffy.eventStore.getEvents('BitcoinWallet_$walletId');
    for (final event in journal) {
      await projection.handle(event);
    }
    return fresh;
  }

  test('list and search, check now, broadcast ourselves: outstanding -> seen, the input spent once', () async {
    final ready = await pay('inv-list');

    final listed = await list(GetDeferredPaymentsQuery(walletId: walletId, queryId: 'q1'));
    expect(listed.nextCursor, isNull);
    final detail = listed.payments.single;
    expect(detail.txid, ready.txid);
    expect(detail.invoiceId, 'inv-list');
    expect(detail.state, DeferredPaymentState.outstanding);
    expect(detail.recipientAddresses, [_recipient]);
    expect(detail.amount, BigInt.from(100000));
    expect(detail.heldInputs.single.utxoKey, _fundingKey);
    expect(detail.heldInputs.single.satoshis, BigInt.from(1000000));
    expect(detail.lastNetworkStatus, isNull);
    expect(detail.rawTxHex, isNotEmpty);
    expect(detail.beef, isNotNull, reason: detail.beefError);
    expect(BEEF.parse(detail.beef!).txs, hasLength(2), reason: 'the payment and its proven parent');

    // Search: not older than an hour; by invoice and recipient; not checked yet.
    expect((await list(GetDeferredPaymentsQuery(
            walletId: walletId, olderThan: const Duration(hours: 1), queryId: 'q2')))
        .payments, isEmpty);
    expect((await list(GetDeferredPaymentsQuery(
            walletId: walletId,
            invoiceId: 'inv-list',
            recipientAddress: _recipient,
            lastNetworkStatuses: const {DeferredNetworkStatus.unchecked},
            includeBeef: false,
            queryId: 'q3')))
        .payments
        .single
        .beef, isNull);

    // Check now: the recipient has not broadcast it, ARC does not know it.
    final checked = await send<DeferredPaymentStatusEvent>(
        CheckDeferredPaymentStatusCommand(walletId: walletId, txid: ready.txid, requestId: 'c1'),
        (e) => e.requestId == 'c1');
    expect(checked.success, isTrue, reason: checked.error);
    expect(checked.networkStatus, DeferredNetworkStatus.notFound);
    await until(() async => (await storage().getDeferredPayment(walletId, ready.txid))!.lastCheckedAt != null,
        'the status projected');
    final notFound = (await list(GetDeferredPaymentsQuery(
            walletId: walletId, lastNetworkStatuses: const {DeferredNetworkStatus.notFound}, queryId: 'q4')))
        .payments
        .single;
    expect(notFound.state, DeferredPaymentState.outstanding);
    expect((await funding()).status, UTXOStatus.reserved);

    // Broadcast ourselves.
    final broadcast = await send<DeferredPaymentBroadcastEvent>(
        BroadcastDeferredPaymentCommand(walletId: walletId, txid: ready.txid, requestId: 'b1'),
        (e) => e.requestId == 'b1');
    expect(broadcast.success, isTrue, reason: broadcast.error);
    expect(broadcast.networkStatus, DeferredNetworkStatus.seenOnNetwork);
    expect(arc.seen, contains(ready.txid));
    await until(() async => (await funding()).status == UTXOStatus.spent, 'the input spent');
    expect((await funding()).spentInTxId, ready.txid);
    await until(
        () async => (await storage().getDeferredPayment(walletId, ready.txid))!.state == DeferredPaymentState.seen,
        'the payment seen');

    // Again: idempotent.
    final again = await send<DeferredPaymentBroadcastEvent>(
        BroadcastDeferredPaymentCommand(walletId: walletId, txid: ready.txid, requestId: 'b2'),
        (e) => e.requestId == 'b2');
    expect(again.success, isTrue);

    expect((await list(GetDeferredPaymentsQuery(walletId: walletId, queryId: 'q5'))).payments, isEmpty,
        reason: 'no longer outstanding');
    final resolved = await list(GetDeferredPaymentsQuery(walletId: walletId, includeResolved: true, queryId: 'q6'));
    expect(resolved.payments.single.state, DeferredPaymentState.seen);

    // Cancelling a payment the network has is refused.
    final refused = await send<DeferredPaymentCancelledEvent>(
        CancelDeferredPaymentCommand(walletId: walletId, txid: ready.txid, requestId: 'x1'),
        (e) => e.requestId == 'x1');
    expect(refused.success, isFalse);

    final rebuilt = await rebuildFromJournal();
    final rebuiltPayment = (await rebuilt.getDeferredPayment(walletId, ready.txid))!;
    expect(rebuiltPayment.state, DeferredPaymentState.seen);
    expect(rebuiltPayment.lastNetworkStatus, DeferredNetworkStatus.seenOnNetwork);
  });

  test('cancel: checks the network, then journals the cancellation and releases the input', () async {
    final ready = await pay('inv-cancel');

    final cancelled = await send<DeferredPaymentCancelledEvent>(
        CancelDeferredPaymentCommand(
            walletId: walletId, txid: ready.txid, reason: 'recipient never answered', requestId: 'x2'),
        (e) => e.requestId == 'x2');

    expect(cancelled.success, isTrue, reason: cancelled.error);
    expect(cancelled.networkStatus, DeferredNetworkStatus.notFound);
    expect(cancelled.releasedUtxoKeys, [_fundingKey]);
    expect(cancelled.error, isNull, reason: 'the read model applied the cancellation before the event');
    expect((await funding()).status, UTXOStatus.available);
    final row = (await storage().getDeferredPayment(walletId, ready.txid))!;
    expect(row.state, DeferredPaymentState.cancelled);
    expect(row.resolutionReason, 'recipient never answered');

    // The input can pay again (another amount: the same payment would be the
    // same transaction).
    final next = await pay('inv-after-cancel-2', amount: 90000);
    expect(next.txid, isNot(ready.txid));

    final rebuilt = await rebuildFromJournal();
    expect((await rebuilt.getDeferredPayment(walletId, ready.txid))!.state, DeferredPaymentState.cancelled);
  });

  /// Pays [invoiceId] like [pay], but waits no longer than 10 s (the
  /// coordinator waited 30 s for a recording that never came) and does not
  /// expect success.
  Future<PaymentReadyEvent> payAgain(String invoiceId, {int amount = 100000}) async {
    final ready = events
        .where((e) => e is PaymentReadyEvent && e.invoiceId == invoiceId)
        .cast<PaymentReadyEvent>()
        .first
        .timeout(const Duration(seconds: 10));
    libspiffy.coordinator.tell(PayInvoiceCommand(
      walletId: walletId,
      invoiceId: invoiceId,
      addresses: const [_recipient],
      amount: BigInt.from(amount),
    ));
    return ready;
  }

  Future<List<Type>> journalOf(String txid) async => [
        for (final e in await libspiffy.eventStore.getEvents('BitcoinWallet_$walletId'))
          if (e is we.TransactionRecordedEvent && e.txid == txid ||
              e is we.TransactionSpendDeferredEvent && e.txid == txid ||
              e is we.DeferredTransactionCancelledEvent && e.txid == txid ||
              e is we.DeferredTransactionFailedEvent && e.txid == txid)
            e.runtimeType,
      ];

  test(
      '4r0: paying the same invoice again after cancelling re-activates the payment at once: '
      'outstanding, its input held again, the cancellation kept in the journal', () async {
    final first = await pay('inv-repay');
    final cancelled = await send<DeferredPaymentCancelledEvent>(
        CancelDeferredPaymentCommand(walletId: walletId, txid: first.txid, reason: 'changed my mind', requestId: 'r1'),
        (e) => e.requestId == 'r1');
    expect(cancelled.success, isTrue, reason: cancelled.error);
    expect((await funding()).status, UTXOStatus.available);

    // The same payment again: the same input, a byte-identical transaction.
    final second = await payAgain('inv-repay');

    expect(second.success, isTrue, reason: second.error);
    expect(second.txid, first.txid, reason: 'deterministic signing over the same input');
    expect(second.beefBytes, first.beefBytes);
    await until(
        () async =>
            (await storage().getDeferredPayment(walletId, first.txid))!.state == DeferredPaymentState.outstanding,
        'the payment outstanding again');
    final row = (await storage().getDeferredPayment(walletId, first.txid))!;
    expect(row.heldInputs.single.utxoKey, _fundingKey);
    expect(row.resolvedAt, isNull);
    expect(row.resolutionReason, isNull);
    final held = await funding();
    expect(held.status, UTXOStatus.reserved);
    expect(held.reservedByTxId, first.txid);
    expect(held.reservationExpiresAt, isNull, reason: 'a hold, not an expiring reservation');
    final listed = await list(GetDeferredPaymentsQuery(walletId: walletId, queryId: 'r2'));
    expect(listed.payments.map((p) => p.txid), [first.txid]);

    // History: recorded once, held, cancelled, held again.
    expect(await journalOf(first.txid), [
      we.TransactionRecordedEvent,
      we.TransactionSpendDeferredEvent,
      we.DeferredTransactionCancelledEvent,
      we.TransactionSpendDeferredEvent,
    ]);

    final rebuilt = await rebuildFromJournal();
    expect((await rebuilt.getDeferredPayment(walletId, first.txid))!.state, DeferredPaymentState.outstanding);
    final rebuiltInput = (await rebuilt.getUTXOs(walletId)).singleWhere((u) => u.key == _fundingKey);
    expect(rebuiltInput.status, UTXOStatus.reserved);
    expect(rebuiltInput.reservedByTxId, first.txid);

    // It can be cancelled again.
    final cancelledAgain = await send<DeferredPaymentCancelledEvent>(
        CancelDeferredPaymentCommand(walletId: walletId, txid: first.txid, requestId: 'r3'),
        (e) => e.requestId == 'r3');
    expect(cancelledAgain.success, isTrue, reason: cancelledAgain.error);
    expect(cancelledAgain.releasedUtxoKeys, [_fundingKey]);
    expect((await funding()).status, UTXOStatus.available);
  });

  test(
      '4r0: paying the same invoice again after the network rejected the payment fails at once '
      'with the reason, and the input stays available', () async {
    final first = await pay('inv-repay-rejected');
    arc.statusOverrides[first.txid] = 'REJECTED';
    final checked = await send<DeferredPaymentStatusEvent>(
        CheckDeferredPaymentStatusCommand(walletId: walletId, txid: first.txid, requestId: 'r4'),
        (e) => e.requestId == 'r4');
    expect(checked.networkStatus, DeferredNetworkStatus.rejected);
    await until(() async => (await funding()).status == UTXOStatus.available, 'the input released');

    final second = await payAgain('inv-repay-rejected');

    expect(second.success, isFalse);
    expect(second.error, allOf(contains(first.txid), contains('failed')));
    expect((await storage().getDeferredPayment(walletId, first.txid))!.state, DeferredPaymentState.failed);
    await until(() async => (await funding()).status == UTXOStatus.available, 'the input available');
    expect(await journalOf(first.txid), [
      we.TransactionRecordedEvent,
      we.TransactionSpendDeferredEvent,
      we.DeferredTransactionFailedEvent,
    ], reason: 'nothing held again');
  });

  test('cancel is refused while ARC knows the transaction (any status but not found)', () async {
    final ready = await pay('inv-stored');
    arc.statusOverrides[ready.txid] = 'STORED';

    final refused = await send<DeferredPaymentCancelledEvent>(
        CancelDeferredPaymentCommand(walletId: walletId, txid: ready.txid, requestId: 'x3'),
        (e) => e.requestId == 'x3');

    expect(refused.success, isFalse);
    expect(refused.networkStatus, 'STORED');
    expect((await funding()).status, UTXOStatus.reserved);
  });

  test('ey2: ARC DOUBLE_SPEND_ATTEMPTED on a status check: listed as outstanding with the status, the input held; '
      'the user may still cancel it', () async {
    final ready = await pay('inv-contested');
    arc.statusOverrides[ready.txid] = 'DOUBLE_SPEND_ATTEMPTED';

    final checked = await send<DeferredPaymentStatusEvent>(
        CheckDeferredPaymentStatusCommand(walletId: walletId, txid: ready.txid, requestId: 'ds1'),
        (e) => e.requestId == 'ds1');
    expect(checked.networkStatus, DeferredNetworkStatus.doubleSpendAttempted);

    await until(
        () async =>
            (await storage().getDeferredPayment(walletId, ready.txid))!.lastNetworkStatus ==
            DeferredNetworkStatus.doubleSpendAttempted,
        'the status recorded');
    final listed = await list(GetDeferredPaymentsQuery(walletId: walletId, queryId: 'ds2'));
    // Old code: failed (not listed as outstanding) and its input released.
    expect(listed.payments.map((p) => (p.txid, p.state, p.lastNetworkStatus)),
        [(ready.txid, DeferredPaymentState.outstanding, DeferredNetworkStatus.doubleSpendAttempted)]);
    expect((await funding()).status, UTXOStatus.reserved);
    expect((await funding()).reservedByTxId, ready.txid);
    expect(await journalOf(ready.txid), [we.TransactionRecordedEvent, we.TransactionSpendDeferredEvent]);

    final cancelled = await send<DeferredPaymentCancelledEvent>(
        CancelDeferredPaymentCommand(walletId: walletId, txid: ready.txid, reason: 'lost the race', requestId: 'ds3'),
        (e) => e.requestId == 'ds3');
    expect(cancelled.success, isTrue, reason: cancelled.error);
    expect(cancelled.networkStatus, DeferredNetworkStatus.doubleSpendAttempted);
    expect(cancelled.releasedUtxoKeys, [_fundingKey]);
    expect((await funding()).status, UTXOStatus.available);
  });

  test('ey2: broadcasting a payment ARC answers DOUBLE_SPEND_ATTEMPTED: reported unsuccessful, still held', () async {
    final ready = await pay('inv-contested-broadcast');
    arc.statusOverrides[ready.txid] = 'DOUBLE_SPEND_ATTEMPTED';

    final broadcast = await send<DeferredPaymentBroadcastEvent>(
        BroadcastDeferredPaymentCommand(walletId: walletId, txid: ready.txid, requestId: 'ds4'),
        (e) => e.requestId == 'ds4');

    expect(broadcast.success, isFalse);
    expect(broadcast.networkStatus, DeferredNetworkStatus.doubleSpendAttempted);
    expect(broadcast.error, contains('DOUBLE_SPEND_ATTEMPTED'));
    await until(
        () async =>
            (await storage().getDeferredPayment(walletId, ready.txid))!.lastNetworkStatus ==
            DeferredNetworkStatus.doubleSpendAttempted,
        'the status recorded');
    expect((await storage().getDeferredPayment(walletId, ready.txid))!.state, DeferredPaymentState.outstanding);
    expect((await funding()).status, UTXOStatus.reserved);
  });

  test('pkum: ARC DOUBLE_SPEND_ATTEMPTED naming the competing transactions: reported, listed with them and '
      'journaled (a read model rebuilt from the journal has them)', () async {
    final ready = await pay('inv-competing');
    final rival = 'c7' * 32;
    arc.statusOverrides[ready.txid] = 'DOUBLE_SPEND_ATTEMPTED';
    arc.competingTxs[ready.txid] = [rival];

    final checked = await send<DeferredPaymentStatusEvent>(
        CheckDeferredPaymentStatusCommand(walletId: walletId, txid: ready.txid, requestId: 'pk1'),
        (e) => e.requestId == 'pk1');
    expect(checked.networkStatus, DeferredNetworkStatus.doubleSpendAttempted);
    expect(checked.competingTxids, [rival]);

    await until(
        () async => (await storage().getDeferredPayment(walletId, ready.txid))!.competingTxids.isNotEmpty,
        'the competing txids recorded');
    final listed = await list(GetDeferredPaymentsQuery(walletId: walletId, queryId: 'pk2'));
    expect(listed.payments.single.txid, ready.txid);
    expect(listed.payments.single.state, DeferredPaymentState.outstanding);
    expect(listed.payments.single.competingTxids, [rival]);
    expect((await funding()).status, UTXOStatus.reserved);

    final broadcast = await send<DeferredPaymentBroadcastEvent>(
        BroadcastDeferredPaymentCommand(walletId: walletId, txid: ready.txid, requestId: 'pk3'),
        (e) => e.requestId == 'pk3');
    expect(broadcast.success, isFalse);
    expect(broadcast.competingTxids, [rival]);

    final rebuilt = await rebuildFromJournal();
    final row = (await rebuilt.getDeferredPayment(walletId, ready.txid))!;
    expect(row.lastNetworkStatus, DeferredNetworkStatus.doubleSpendAttempted);
    expect(row.competingTxids, [rival]);
  });

  test('ARC REJECTED on a status check: the payment fails and its input is released, journaled', () async {
    final ready = await pay('inv-rejected');
    arc.statusOverrides[ready.txid] = 'REJECTED';

    final checked = await send<DeferredPaymentStatusEvent>(
        CheckDeferredPaymentStatusCommand(walletId: walletId, txid: ready.txid, requestId: 'c2'),
        (e) => e.requestId == 'c2');
    expect(checked.networkStatus, DeferredNetworkStatus.rejected);

    await until(() async => (await funding()).status == UTXOStatus.available, 'the input released');
    await until(
        () async => (await storage().getDeferredPayment(walletId, ready.txid))!.state == DeferredPaymentState.failed,
        'the payment failed');
    final failed = await list(GetDeferredPaymentsQuery(
        walletId: walletId, states: const {DeferredPaymentState.failed}, queryId: 'q7'));
    expect(failed.payments.single.lastNetworkStatus, DeferredNetworkStatus.rejected);

    final rebuilt = await rebuildFromJournal();
    expect((await rebuilt.getDeferredPayment(walletId, ready.txid))!.state, DeferredPaymentState.failed);
    expect((await rebuilt.getUTXOs(walletId)).where((u) => u.key == _fundingKey).single.status,
        UTXOStatus.available);
  });

  // Bead libspiffy-87a. Cancelling releases the hold but leaves the signed
  // transaction the recipient holds spendable. A reclaim spends its inputs
  // back to us, so their copy can no longer be mined.
  //
  // This is Bitcoin SV: first seen wins, so the reclaim pays the standard
  // ARC policy rate on its signed size and nothing more (NetworkArc
  // publishes 100 sat/1000 bytes
  // and rejects the later of two spends of one input, whatever it pays).
  test('87a: reclaim an outstanding payment: the self-spend pays the ARC policy fee, the payment is '
      'reclaimed once the network has it, the recipient\'s copy is then rejected as a double spend, '
      'and the balance is restored less the fee', () async {
    final ready = await pay('inv-reclaim');
    expect((await funding()).status, UTXOStatus.reserved);
    // One P2PKH input (148 bytes signed), one P2PKH output (34), and the
    // version, lock time and counts (10): 192 bytes (bead libspiffy-bg7n).
    final policyFee = (await arc.getPolicy()).miningFee.feeFor(192);
    expect(policyFee, BigInt.from(20), reason: '100 sat/1000 bytes on 192 bytes, rounded up');

    final reclaimed = await send<DeferredPaymentReclaimedEvent>(
        ReclaimDeferredPaymentCommand(
            walletId: walletId, txid: ready.txid, reason: 'recipient never broadcast it', requestId: 'rc1'),
        (e) => e.requestId == 'rc1');

    expect(reclaimed.success, isTrue, reason: reclaimed.error);
    expect(reclaimed.txid, ready.txid);
    expect(reclaimed.reclaimTxid, isNot(ready.txid));
    expect(reclaimed.reclaimedUtxoKeys, [_fundingKey]);
    expect(reclaimed.fee, policyFee, reason: 'the standard policy fee, not raised to outbid anything');
    expect(reclaimed.reclaimedSatoshis, BigInt.from(1000000) - policyFee);
    expect(reclaimed.networkStatus, DeferredNetworkStatus.seenOnNetwork);
    expect(arc.seen, contains(reclaimed.reclaimTxid));
    final reclaimTxid = reclaimed.reclaimTxid!;
    final reclaimHex = (await storage().getTransaction(reclaimTxid))!.rawHex;
    expect(reclaimHex.length ~/ 2, lessThanOrEqualTo(192), reason: 'the fee was paid on the signed size');

    // The network has the self-spend: the input is spent by it and the
    // payment is reclaimed. Not before: that is the one resolution point.
    await until(() async => (await funding()).status == UTXOStatus.spent, 'the held input spent');
    expect((await funding()).spentInTxId, reclaimTxid);
    await until(
        () async =>
            (await storage().getDeferredPayment(walletId, ready.txid))!.state == DeferredPaymentState.reclaimed,
        'the payment reclaimed');
    final row = (await storage().getDeferredPayment(walletId, ready.txid))!;
    expect(row.resolutionReason, contains(reclaimTxid));
    expect(row.resolvedAt, isNotNull);
    expect(row.heldInputs.single.utxoKey, _fundingKey, reason: 'its record is kept as it was');

    // Retention: the reclaimed payment's signed transaction is still stored,
    // with its raw hex, and both txids stay listable.
    final original = (await storage().getTransaction(ready.txid, walletId: walletId))!;
    expect(original.rawHex, isNotEmpty);
    final listed = await list(
        GetDeferredPaymentsQuery(walletId: walletId, includeResolved: true, queryId: 'rc2'));
    expect(listed.payments.map((p) => (p.txid, p.state)).toSet(), {
      (ready.txid, DeferredPaymentState.reclaimed),
      (reclaimTxid, DeferredPaymentState.seen),
    });
    expect(listed.payments.firstWhere((p) => p.txid == reclaimTxid).payment.purpose, 'reclaim:${ready.txid}');

    // The link between the two rows is on the detail object itself (bead
    // libspiffy-fzjv): an app reads it without reaching through `.payment`.
    final selfSpend = listed.payments.firstWhere((p) => p.txid == reclaimTxid);
    expect((selfSpend.purpose, selfSpend.reclaimsTxid, selfSpend.isReclaim),
        ('reclaim:${ready.txid}', ready.txid, true));
    final reclaimedPayment = listed.payments.firstWhere((p) => p.txid == ready.txid);
    expect((reclaimedPayment.reclaimsTxid, reclaimedPayment.isReclaim), (null, false));
    expect(reclaimedPayment.resolutionReason, contains(reclaimTxid),
        reason: 'and the payment names the self-spend that reclaimed it');

    // Balance restored less the fee.
    await until(
        () async => (await storage().getPaymentUTXOs(walletId))
            .any((u) => u.satoshis == BigInt.from(1000000) - policyFee),
        'the reclaimed output spendable');
    expect((await storage().getPaymentUTXOs(walletId)).map((u) => u.satoshis),
        [BigInt.from(1000000) - policyFee]);

    // The recipient broadcasts their copy now: it spends an input the
    // network already saw spent, so it is rejected. First seen wins.
    final late_ = await send<DeferredPaymentBroadcastEvent>(
        BroadcastDeferredPaymentCommand(walletId: walletId, txid: ready.txid, requestId: 'rc3'),
        (e) => e.requestId == 'rc3');
    expect(late_.success, isFalse);
    expect(late_.networkStatus, DeferredNetworkStatus.rejected);
    expect(late_.competingTxids, [reclaimTxid]);
    expect((await storage().getDeferredPayment(walletId, ready.txid))!.state, DeferredPaymentState.reclaimed,
        reason: 'a rejection does not take a reclaimed payment back');

    // Journaled: a read model rebuilt from the journal agrees.
    final rebuilt = await rebuildFromJournal();
    expect((await rebuilt.getDeferredPayment(walletId, ready.txid))!.state, DeferredPaymentState.reclaimed);
    expect((await rebuilt.getDeferredPayment(walletId, reclaimTxid))!.purpose, 'reclaim:${ready.txid}');
    expect((await rebuilt.getUTXOs(walletId, includeSpent: true)).firstWhere((u) => u.key == _fundingKey).status,
        UTXOStatus.spent);
  });

  test('87a: reclaiming is refused for a payment that is not outstanding, and cancelling one being '
      'reclaimed is refused', () async {
    final ready = await pay('inv-reclaim-refused');
    final reclaimed = await send<DeferredPaymentReclaimedEvent>(
        ReclaimDeferredPaymentCommand(walletId: walletId, txid: ready.txid, requestId: 'rf1'),
        (e) => e.requestId == 'rf1');
    expect(reclaimed.success, isTrue, reason: reclaimed.error);

    // While the reclaim is in flight the payment stays outstanding, but it
    // can no longer be cancelled: its inputs are the reclaim's now.
    final refusedCancel = await send<DeferredPaymentCancelledEvent>(
        CancelDeferredPaymentCommand(walletId: walletId, txid: ready.txid, requestId: 'rf2'),
        (e) => e.requestId == 'rf2');
    expect(refusedCancel.success, isFalse);
    expect(refusedCancel.error, contains('reclaim'));

    await until(
        () async =>
            (await storage().getDeferredPayment(walletId, ready.txid))!.state == DeferredPaymentState.reclaimed,
        'the payment reclaimed');
    final again = await send<DeferredPaymentReclaimedEvent>(
        ReclaimDeferredPaymentCommand(walletId: walletId, txid: ready.txid, requestId: 'rf3'),
        (e) => e.requestId == 'rf3');
    expect(again.success, isFalse);
    expect(again.error, contains('reclaimed'));

    final unknown = await send<DeferredPaymentReclaimedEvent>(
        ReclaimDeferredPaymentCommand(walletId: walletId, txid: 'ab' * 32, requestId: 'rf4'),
        (e) => e.requestId == 'rf4');
    expect(unknown.success, isFalse);
    expect(unknown.error, contains('not a deferred payment'));
  });
}
