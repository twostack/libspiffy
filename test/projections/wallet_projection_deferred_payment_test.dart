/// Bead libspiffy-7p2: WalletProjection builds the deferred-payment read
/// model from the journal, and a replay leaves it unchanged.
library;

import 'package:test/test.dart';

import 'package:libspiffy/src/core/wallet_events.dart';
import 'package:libspiffy/src/models/bitcoin_utxo.dart';
import 'package:libspiffy/src/models/deferred_payment.dart';
import 'package:libspiffy/src/models/wallet_event.dart';
import 'package:libspiffy/src/models/wallet_type.dart';
import 'package:libspiffy/src/projections/wallet_projection.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';

import 'package:eventador/eventador.dart' show EventStore;

class _NoStore implements EventStore {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('${invocation.memberName}');
}

const _w = 'proj-wallet';
final _t0 = DateTime.utc(2026, 9, 1);
final _input = '${'a1' * 32}:0';
final _pending = '${'b2' * 32}:1';
final _txid = 'dd' * 32;

class _Journal {
  final List<WalletEvent> events = [];
  DateTime _clock = _t0;

  T add<T extends WalletEvent>(T Function(int version, DateTime at) make) {
    _clock = _clock.add(const Duration(minutes: 1));
    final e = make(events.length + 1, _clock);
    events.add(e);
    return e;
  }
}

void main() {
  late InMemoryWalletStorage storage;
  late WalletProjection projection;

  setUp(() {
    storage = InMemoryWalletStorage();
    projection = WalletProjection(
      projectionId: 'deferred-test',
      eventStore: _NoStore(),
      storage: storage,
    );
  });

  _Journal handedOver() {
    final j = _Journal();
    j.add((v, at) => WalletCreatedEvent(
        walletId: _w, walletName: 'w', rootAddress: 'mroot', walletType: WalletType.hd,
        walletMetadata: {'network': 'testnet'}, version: v, timestamp: at));
    for (final (key, status) in [(_input, UTXOStatus.available), (_pending, UTXOStatus.pending)]) {
      final parts = key.split(':');
      j.add((v, at) => UTXOReceivedEvent(
          walletId: _w, txid: parts[0], vout: int.parse(parts[1]), satoshis: 5000,
          scriptPubKey: '76a914${'00' * 20}88ac', address: 'mroot', initialStatus: status,
          version: v, timestamp: at));
    }
    j.add((v, at) => UTXOReservedEvent(
        walletId: _w, txid: 'a1' * 32, vout: 0, reservedByTxId: 'payment-x',
        expiresAt: at.add(const Duration(minutes: 2)), version: v, timestamp: at));
    j.add((v, at) => TransactionRecordedEvent(
        walletId: _w, txid: _txid, rawHex: '00', totalInputSats: 10000, totalOutputSats: 9000, fee: 100,
        numInputs: 2, numOutputs: 1, txVersion: 1, txLockTime: 0, spentUtxoKeys: [_input, _pending],
        recipientAddresses: const ['mrecipient'], paymentAmount: '9000', version: v, timestamp: at));
    j.add((v, at) => TransactionSpendDeferredEvent(
        walletId: _w, txid: _txid,
        heldInputs: [
          {'utxoKey': _input, 'satoshis': '5000'},
          {'utxoKey': _pending, 'satoshis': '5000'},
        ],
        recipientAddresses: const ['mrecipient'], paymentAmount: '9000', fee: 100, invoiceId: 'inv',
        purpose: 'invoice-payment', recordedAt: at, version: v, timestamp: at));
    return j;
  }

  Future<void> project(List<WalletEvent> events) async {
    for (final e in events) {
      await projection.handle(e);
    }
  }

  Future<Map<String, BitcoinUtxo>> utxos() async =>
      {for (final u in await storage.getUTXOs(_w, includeSpent: true)) u.key: u};

  test('a hold: outstanding row with its inputs; inputs reserved by the transaction, no expiry', () async {
    final j = handedOver();
    await project(j.events);

    final row = (await storage.getDeferredPayment(_w, _txid))!;
    expect(row.state, DeferredPaymentState.outstanding);
    expect(row.invoiceId, 'inv');
    expect(row.amount, BigInt.from(9000));
    expect(row.heldInputs.map((i) => i.utxoKey), [_input, _pending]);
    expect(row.createdAt, j.events.last.timestamp);
    final rows = await utxos();
    for (final key in [_input, _pending]) {
      expect(rows[key]!.status, UTXOStatus.reserved);
      expect(rows[key]!.reservedByTxId, _txid);
      expect(rows[key]!.reservationExpiresAt, isNull);
    }
    expect(rows[_pending]!.statusBeforeReservation, UTXOStatus.pending);
    expect(await storage.getPaymentUTXOs(_w), isEmpty, reason: 'nothing selectable');
  });

  test('a spend by the transaction makes it seen; a verified confirmation mined; a revert seen again', () async {
    final j = handedOver();
    j.add((v, at) => UTXOSpentEvent(walletId: _w, txid: 'a1' * 32, vout: 0, spentInTxId: _txid, version: v, timestamp: at));
    await project(j.events);
    expect((await storage.getDeferredPayment(_w, _txid))!.state, DeferredPaymentState.seen);

    j.add((v, at) => TransactionConfirmedEvent(walletId: _w, txid: _txid, blockHeight: 5, blockHash: 'h', version: v, timestamp: at));
    await project([j.events.last]);
    expect((await storage.getDeferredPayment(_w, _txid))!.state, DeferredPaymentState.mined);

    j.add((v, at) => TransactionConfirmationRevertedEvent(walletId: _w, txid: _txid, reason: 'reorg', version: v, timestamp: at));
    await project([j.events.last]);
    expect((await storage.getDeferredPayment(_w, _txid))!.state, DeferredPaymentState.seen);
  });

  test('a network status is recorded; SEEN_ON_NETWORK makes it seen', () async {
    final j = handedOver();
    final checkedAt = DateTime.utc(2026, 9, 3);
    j.add((v, at) => TransactionNetworkStatusCheckedEvent(
        walletId: _w, txid: _txid, networkStatus: 'NOT_FOUND', source: 'arc', checkedAt: checkedAt, version: v, timestamp: at));
    await project(j.events);
    var row = (await storage.getDeferredPayment(_w, _txid))!;
    expect(row.state, DeferredPaymentState.outstanding);
    expect(row.lastNetworkStatus, 'NOT_FOUND');
    expect(row.lastCheckedAt, checkedAt);

    j.add((v, at) => TransactionNetworkStatusCheckedEvent(
        walletId: _w, txid: _txid, networkStatus: 'SEEN_ON_NETWORK', source: 'dataSource',
        checkedAt: DateTime.utc(2026, 9, 4), version: v, timestamp: at));
    await project([j.events.last]);
    row = (await storage.getDeferredPayment(_w, _txid))!;
    expect(row.state, DeferredPaymentState.seen);
    expect(row.lastNetworkStatusSource, 'dataSource');
  });

  for (final cancelled in [false, true]) {
    test('${cancelled ? 'a cancellation' : 'a failure'} releases the inputs to their recorded status', () async {
      final j = handedOver();
      final inputs = [
        ReleasedDeferredInput(utxoKey: _input, restoredStatus: UTXOStatus.available),
        ReleasedDeferredInput(utxoKey: _pending, restoredStatus: UTXOStatus.pending),
      ];
      j.add((v, at) => cancelled
          ? DeferredTransactionCancelledEvent(
              walletId: _w, txid: _txid, reason: 'user', releasedInputs: inputs, version: v, timestamp: at)
          : DeferredTransactionFailedEvent(
              walletId: _w, txid: _txid, networkStatus: 'REJECTED', reason: 'arc says no',
              releasedInputs: inputs, version: v, timestamp: at));
      await project(j.events);

      final row = (await storage.getDeferredPayment(_w, _txid))!;
      expect(row.state, cancelled ? DeferredPaymentState.cancelled : DeferredPaymentState.failed);
      expect(row.resolutionReason, cancelled ? 'user' : 'arc says no');
      final rows = await utxos();
      expect(rows[_input]!.status, UTXOStatus.available);
      expect(rows[_input]!.reservedByTxId, isNull);
      expect(rows[_pending]!.status, UTXOStatus.pending);
      expect((await storage.getPaymentUTXOs(_w)).map((u) => u.key), [_input]);
    });
  }

  // Bead libspiffy-87a: the wallet spends the held inputs back to itself.
  final _reclaimTxid = 'ee' * 32;

  /// [handedOver], then the reclaim: the self-spend's own record and hold
  /// (which takes over the payment's inputs) and the reclaim event.
  _Journal reclaimed() {
    final j = handedOver();
    j.add((v, at) => TransactionRecordedEvent(
        walletId: _w, txid: _reclaimTxid, rawHex: '00', totalInputSats: 10000, totalOutputSats: 9900,
        fee: 100, numInputs: 2, numOutputs: 1, txVersion: 1, txLockTime: 0,
        spentUtxoKeys: [_input, _pending], recipientAddresses: const ['mroot'], paymentAmount: '9900',
        version: v, timestamp: at));
    j.add((v, at) => TransactionSpendDeferredEvent(
        walletId: _w, txid: _reclaimTxid,
        heldInputs: [
          {'utxoKey': _input, 'satoshis': '5000'},
          {'utxoKey': _pending, 'satoshis': '5000'},
        ],
        recipientAddresses: const ['mroot'], paymentAmount: '9900', fee: 100,
        purpose: DeferredPaymentPurpose.reclaimOf(_txid), supersedes: _txid,
        recordedAt: at, version: v, timestamp: at));
    j.add((v, at) => DeferredSpendReclaimedEvent(
        walletId: _w, txid: _txid, reclaimTxid: _reclaimTxid, reclaimedUtxoKeys: [_input, _pending],
        reason: 'recipient vanished', version: v, timestamp: at));
    return j;
  }

  test('87a: the reclaim moves the hold to the self-spend and leaves the payment outstanding', () async {
    final j = reclaimed();
    await project(j.events);

    final payment = (await storage.getDeferredPayment(_w, _txid))!;
    expect(payment.state, DeferredPaymentState.outstanding, reason: 'not resolved at broadcast time');
    expect(payment.heldInputs.map((i) => i.utxoKey), [_input, _pending], reason: 'its record is kept');
    final selfSpend = (await storage.getDeferredPayment(_w, _reclaimTxid))!;
    expect(selfSpend.state, DeferredPaymentState.outstanding);
    expect(selfSpend.purpose, 'reclaim:$_txid');
    expect(DeferredPaymentPurpose.reclaimedTxid(selfSpend.purpose), _txid);
    final rows = await utxos();
    for (final key in [_input, _pending]) {
      expect(rows[key]!.status, UTXOStatus.reserved);
      expect(rows[key]!.reservedByTxId, _reclaimTxid);
      expect(rows[key]!.reservationExpiresAt, isNull);
    }
    expect(await storage.getPaymentUTXOs(_w), isEmpty);
  });

  for (final via in ['a spend by the self-spend', 'a SEEN_ON_NETWORK status', 'a confirmation']) {
    test('87a: $via reclaims the payment; both rows are kept', () async {
      final j = reclaimed();
      switch (via) {
        case 'a spend by the self-spend':
          j.add((v, at) => UTXOSpentEvent(
              walletId: _w, txid: 'a1' * 32, vout: 0, spentInTxId: _reclaimTxid, version: v, timestamp: at));
        case 'a SEEN_ON_NETWORK status':
          j.add((v, at) => TransactionNetworkStatusCheckedEvent(
              walletId: _w, txid: _reclaimTxid, networkStatus: 'SEEN_ON_NETWORK', source: 'arc',
              checkedAt: at, version: v, timestamp: at));
        default:
          j.add((v, at) => TransactionConfirmedEvent(
              walletId: _w, txid: _reclaimTxid, blockHeight: 5, blockHash: 'h', version: v, timestamp: at));
      }
      await project(j.events);

      final payment = (await storage.getDeferredPayment(_w, _txid))!;
      expect(payment.state, DeferredPaymentState.reclaimed);
      expect(payment.resolutionReason, contains(_reclaimTxid));
      expect(payment.resolvedAt, isNotNull);
      expect(payment.amount, BigInt.from(9000), reason: 'the reclaimed payment is not rewritten');
      expect((await storage.getDeferredPayment(_w, _reclaimTxid))!.state,
          via == 'a confirmation' ? DeferredPaymentState.mined : DeferredPaymentState.seen);

      // Replaying changes nothing.
      await project(j.events);
      expect((await storage.getDeferredPayment(_w, _txid))!.state, DeferredPaymentState.reclaimed);
    });
  }

  test('87a: the reclaim event replayed after the self-spend is already seen resolves the payment', () async {
    final j = reclaimed();
    final reclaimEvent = j.events.last;
    j.add((v, at) => TransactionNetworkStatusCheckedEvent(
        walletId: _w, txid: _reclaimTxid, networkStatus: 'SEEN_ON_NETWORK', source: 'arc',
        checkedAt: at, version: v, timestamp: at));
    await project(j.events);
    expect((await storage.getDeferredPayment(_w, _txid))!.state, DeferredPaymentState.reclaimed);

    await project([reclaimEvent]);

    expect((await storage.getDeferredPayment(_w, _txid))!.state, DeferredPaymentState.reclaimed);
  });

  test('replaying the whole journal again changes nothing', () async {
    final j = handedOver();
    j.add((v, at) => TransactionNetworkStatusCheckedEvent(
        walletId: _w, txid: _txid, networkStatus: 'REJECTED', source: 'arc', checkedAt: at, version: v, timestamp: at));
    j.add((v, at) => DeferredTransactionFailedEvent(
        walletId: _w, txid: _txid, networkStatus: 'REJECTED',
        releasedInputs: [ReleasedDeferredInput(utxoKey: _input, restoredStatus: UTXOStatus.available)],
        version: v, timestamp: at));
    await project(j.events);
    final row = await storage.getDeferredPayment(_w, _txid);
    final rows = await utxos();

    await project(j.events);

    expect(await storage.getDeferredPayment(_w, _txid), row);
    final again = await utxos();
    expect({for (final e in again.entries) e.key: e.value.status}, {for (final e in rows.entries) e.key: e.value.status});
    expect(again[_input]!.reservedByTxId, isNull, reason: 'the replayed hold does not re-reserve a released input');
  });
}
