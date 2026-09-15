/// Deferred-payment read model contract (bead libspiffy-7p2), run against
/// every [ReadModelStorage] backend: in-memory and Isar in
/// deferred_payment_storage_test.dart, PostgreSQL in
/// postgres/postgres_deferred_payment_test.dart.
library;

import 'package:test/test.dart';

import 'package:libspiffy/src/storage/read_model_storage.dart';

/// A txid unique to [tag].
String contractTxid(String tag) {
  var h = 0;
  for (final c in tag.codeUnits) {
    h = (h * 131 + c) & 0x7fffffff;
  }
  final hex = h.toRadixString(16).padLeft(8, '0');
  return (hex * 8).substring(0, 64);
}

final _base = DateTime.utc(2026, 9, 1, 12);

DeferredPayment contractDeferredPayment({
  required String walletId,
  required String txid,
  int minutesAfterBase = 0,
  DeferredPaymentState state = DeferredPaymentState.outstanding,
  String? invoiceId,
  List<String> recipients = const ['mkHS9ne12qx9pS9VojpwU5xtRd4T7X7ZUt'],
  String? lastNetworkStatus,
}) {
  final created = _base.add(Duration(minutes: minutesAfterBase));
  return DeferredPayment(
    walletId: walletId,
    txid: txid,
    invoiceId: invoiceId,
    purpose: 'invoice-payment',
    recipientAddresses: recipients,
    amount: BigInt.from(15000),
    fee: BigInt.from(113),
    heldInputs: [
      DeferredPaymentInput(utxoKey: '${'ab' * 32}:1', satoshis: BigInt.from(20000)),
      DeferredPaymentInput(utxoKey: '${'cd' * 32}:0', satoshis: BigInt.from(546)),
    ],
    state: state,
    lastNetworkStatus: lastNetworkStatus,
    lastNetworkStatusSource: lastNetworkStatus == null ? null : 'arc',
    lastCheckedAt: lastNetworkStatus == null ? null : created.add(const Duration(seconds: 30)),
    createdAt: created,
    updatedAt: created.add(const Duration(seconds: 31)),
    resolvedAt: state == DeferredPaymentState.outstanding ? null : created.add(const Duration(hours: 1)),
    resolutionReason: state == DeferredPaymentState.failed ? 'arc reported REJECTED' : null,
  );
}

/// Defines the contract tests. [storage] is read in each test; [unique]
/// returns a fresh tag per call (wallet ids must not collide across tests on
/// a shared database).
void defineDeferredPaymentContract(
  ReadModelStorage Function() storage, {
  required String Function() unique,
}) {
  group('deferred payments (7p2)', () {
    test('a stored payment reads back with every field', () async {
      final walletId = 'w-${unique()}';
      final payment = contractDeferredPayment(
        walletId: walletId,
        txid: contractTxid('round-${unique()}'),
        invoiceId: 'inv-1',
        recipients: const ['mkHS9ne12qx9pS9VojpwU5xtRd4T7X7ZUt', 'n2eMqTT929pb1RDNuqEnxdaLau1rxy3efi'],
        lastNetworkStatus: DeferredNetworkStatus.notFound,
      );
      await storage().storeDeferredPayment(payment);

      final read = await storage().getDeferredPayment(walletId, payment.txid);
      expect(read, payment);
      expect(read!.heldInputs, payment.heldInputs);
      expect(read.heldSatoshis, BigInt.from(20546));
      expect(await storage().getDeferredPayment('other-$walletId', payment.txid), isNull);
    });

    test('storing again replaces the row; resolved payments stay listable with their state', () async {
      final walletId = 'w-${unique()}';
      final txid = contractTxid('replace-${unique()}');
      final outstanding = contractDeferredPayment(walletId: walletId, txid: txid);
      await storage().storeDeferredPayment(outstanding);
      expect([for (final p in (await storage().listDeferredPayments(walletId)).payments) p.txid], [txid]);

      final failed = outstanding.copyWith(
        state: DeferredPaymentState.failed,
        lastNetworkStatus: DeferredNetworkStatus.rejected,
        lastNetworkStatusSource: 'arc',
        lastCheckedAt: DateTime.utc(2026, 9, 2),
        resolvedAt: DateTime.utc(2026, 9, 2),
        resolutionReason: 'arc reported REJECTED',
        updatedAt: DateTime.utc(2026, 9, 2),
      );
      await storage().storeDeferredPayment(failed);

      expect(await storage().getDeferredPayment(walletId, txid), failed);
      expect((await storage().listDeferredPayments(walletId)).payments, isEmpty,
          reason: 'the default listing is outstanding only');
      final all = await storage().listDeferredPayments(walletId,
          query: const DeferredPaymentQuery(states: DeferredPaymentQuery.allStates));
      expect(all.payments, [failed]);
    });

    test('filters: states, created before/after, last network status (and unchecked), invoice, recipient',
        () async {
      final walletId = 'w-${unique()}';
      final t = unique();
      final a = contractDeferredPayment(
          walletId: walletId, txid: contractTxid('a$t'), minutesAfterBase: 0, invoiceId: 'inv-a');
      final b = contractDeferredPayment(
          walletId: walletId,
          txid: contractTxid('b$t'),
          minutesAfterBase: 10,
          lastNetworkStatus: DeferredNetworkStatus.notFound,
          recipients: const ['n2eMqTT929pb1RDNuqEnxdaLau1rxy3efi']);
      final c = contractDeferredPayment(
          walletId: walletId,
          txid: contractTxid('c$t'),
          minutesAfterBase: 20,
          state: DeferredPaymentState.seen,
          lastNetworkStatus: DeferredNetworkStatus.seenOnNetwork);
      final d = contractDeferredPayment(
          walletId: walletId, txid: contractTxid('d$t'), minutesAfterBase: 30, state: DeferredPaymentState.cancelled);
      // Another wallet's payment never shows up.
      await storage().storeDeferredPayment(
          contractDeferredPayment(walletId: 'other-$walletId', txid: contractTxid('a$t')));
      for (final p in [a, b, c, d]) {
        await storage().storeDeferredPayment(p);
      }

      Future<List<String>> txids(DeferredPaymentQuery q) async =>
          [for (final p in (await storage().listDeferredPayments(walletId, query: q)).payments) p.txid];

      expect(await txids(const DeferredPaymentQuery()), [b.txid, a.txid], reason: 'outstanding, newest first');
      expect(await txids(const DeferredPaymentQuery(states: DeferredPaymentQuery.allStates)),
          [d.txid, c.txid, b.txid, a.txid]);
      expect(await txids(const DeferredPaymentQuery(
              states: {DeferredPaymentState.seen, DeferredPaymentState.cancelled})),
          [d.txid, c.txid]);
      expect(
          await txids(DeferredPaymentQuery(
              states: DeferredPaymentQuery.allStates, createdBefore: _base.add(const Duration(minutes: 20)))),
          [b.txid, a.txid],
          reason: 'createdBefore is exclusive');
      expect(
          await txids(DeferredPaymentQuery(
              states: DeferredPaymentQuery.allStates, createdAfter: _base.add(const Duration(minutes: 20)))),
          [d.txid, c.txid],
          reason: 'createdAfter is inclusive');
      expect(
          await txids(const DeferredPaymentQuery(
              states: DeferredPaymentQuery.allStates,
              lastNetworkStatuses: {DeferredNetworkStatus.notFound, DeferredNetworkStatus.seenOnNetwork})),
          [c.txid, b.txid]);
      expect(
          await txids(const DeferredPaymentQuery(
              states: DeferredPaymentQuery.allStates, lastNetworkStatuses: {DeferredNetworkStatus.unchecked})),
          [d.txid, a.txid]);
      expect(await txids(const DeferredPaymentQuery(invoiceId: 'inv-a')), [a.txid]);
      expect(await txids(const DeferredPaymentQuery(recipientAddress: 'n2eMqTT929pb1RDNuqEnxdaLau1rxy3efi')),
          [b.txid]);
      expect(await txids(const DeferredPaymentQuery(recipientAddress: 'nobody')), isEmpty);
    });

    for (final oldestFirst in [false, true]) {
      test('paging with limit and cursor (${oldestFirst ? 'oldest' : 'newest'} first) visits every row once, '
          'ties on createdAt ordered by txid', () async {
        final walletId = 'w-${unique()}';
        final t = unique();
        final payments = [
          for (var i = 0; i < 7; i++)
            contractDeferredPayment(
              walletId: walletId,
              txid: contractTxid('page$i-$t'),
              // Two pairs share a creation time.
              minutesAfterBase: const [0, 5, 5, 9, 12, 12, 40][i],
            ),
        ];
        for (final p in payments) {
          await storage().storeDeferredPayment(p);
        }
        final expected = List.of(payments)..sort(DeferredPaymentQuery(oldestFirst: oldestFirst).compare);

        final seen = <String>[];
        String? cursor;
        var pages = 0;
        do {
          final page = await storage().listDeferredPayments(walletId,
              query: DeferredPaymentQuery(limit: 3, cursor: cursor, oldestFirst: oldestFirst));
          expect(page.payments.length, lessThanOrEqualTo(3));
          seen.addAll(page.payments.map((p) => p.txid));
          cursor = page.nextCursor;
          pages++;
        } while (cursor != null && pages < 10);

        expect(pages, 3);
        expect(seen, [for (final p in expected) p.txid]);
      });
    }

    test('a cursor the API did not produce is refused', () async {
      expect(
        () => storage().listDeferredPayments('w-${unique()}', query: const DeferredPaymentQuery(cursor: 'garbage')),
        throwsA(isA<FormatException>()),
      );
    });

    test('only an explicit wallet deletion removes the rows', () async {
      final walletId = 'w-${unique()}';
      final keep = 'keep-$walletId';
      final txid = contractTxid('delete-${unique()}');
      await storage().storeDeferredPayment(contractDeferredPayment(walletId: walletId, txid: txid));
      await storage().storeDeferredPayment(contractDeferredPayment(walletId: keep, txid: txid));

      await storage().deleteWallet(walletId);

      expect(await storage().getDeferredPayment(walletId, txid), isNull);
      expect((await storage().listDeferredPayments(walletId)).payments, isEmpty);
      expect(await storage().getDeferredPayment(keep, txid), isNotNull);
    });
  });
}
