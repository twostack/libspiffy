/// Beads libspiffy-3arz and libspiffy-wfvi in the read model: what the
/// wallet aggregate decides about a resolved deferred payment's own outputs
/// and about a reclaim that lost the race, WalletProjection writes to the
/// read-model rows the same way.
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

const _w = 'resolution-outputs-wallet';
final _t0 = DateTime.utc(2026, 9, 1);
final _input = '${'a1' * 32}:0';
final _txid = 'dd' * 32;
final _reclaimTxid = 'ee' * 32;
const _changeVout = 1;

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
      projectionId: 'resolution-outputs-test',
      eventStore: _NoStore(),
      storage: storage,
    );
  });

  Future<void> project(List<WalletEvent> events) async {
    for (final e in events) {
      await projection.handle(e);
    }
  }

  Future<Map<String, BitcoinUtxo>> utxos() async =>
      {for (final u in await storage.getUTXOs(_w, includeSpent: true)) u.key: u};

  /// A wallet holding one available input, that recorded a deferred payment
  /// spending it with change back to itself.
  _Journal handedOver({String purpose = 'invoice-payment'}) {
    final txid = _txid;
    final j = _Journal();
    j.add((v, at) => WalletCreatedEvent(
        walletId: _w, walletName: 'w', rootAddress: 'mroot', walletType: WalletType.hd,
        walletMetadata: {'network': 'testnet'}, version: v, timestamp: at));
    j.add((v, at) => UTXOReceivedEvent(
        walletId: _w, txid: 'a1' * 32, vout: 0, satoshis: 20000,
        scriptPubKey: '76a914${'00' * 20}88ac', address: 'mroot',
        initialStatus: UTXOStatus.available, version: v, timestamp: at));
    j.add((v, at) => TransactionRecordedEvent(
        walletId: _w, txid: txid, rawHex: '00', totalInputSats: 20000, totalOutputSats: 19900, fee: 100,
        numInputs: 1, numOutputs: 2, txVersion: 1, txLockTime: 0, spentUtxoKeys: [_input],
        recipientAddresses: const ['mrecipient'], paymentAmount: '1000', version: v, timestamp: at));
    // The payment's own change output, as the aggregate creates it.
    j.add((v, at) => UTXOReceivedEvent(
        walletId: _w, txid: txid, vout: _changeVout, satoshis: 18900,
        scriptPubKey: '76a914${'00' * 20}88ac', address: 'mroot',
        initialStatus: UTXOStatus.pending, version: v, timestamp: at));
    j.add((v, at) => TransactionSpendDeferredEvent(
        walletId: _w, txid: txid,
        heldInputs: [
          {'utxoKey': _input, 'satoshis': '20000'},
        ],
        recipientAddresses: const ['mrecipient'], paymentAmount: '1000', fee: 100, invoiceId: 'inv',
        purpose: purpose, recordedAt: at, version: v, timestamp: at));
    return j;
  }

  test('3arz: a cancellation voids the change row; the row is kept and stops counting as incoming',
      () async {
    final j = handedOver();
    await project(j.events);
    expect((await utxos())['$_txid:$_changeVout']!.status, UTXOStatus.pending);

    j.add((v, at) => DeferredTransactionCancelledEvent(
        walletId: _w, txid: _txid, reason: 'recipient vanished',
        releasedInputs: [ReleasedDeferredInput(utxoKey: _input, restoredStatus: UTXOStatus.available)],
        version: v, timestamp: at));
    await project(j.events.sublist(j.events.length - 1));

    final change = (await utxos())['$_txid:$_changeVout']!;
    expect(change.status, UTXOStatus.voided);
    expect(change.satoshis, BigInt.from(18900), reason: 'RETENTION: the row is kept whole');
    final wallet = (await storage.getWallet(_w))!['metadata'] as Map<String, dynamic>;
    expect(wallet['unconfirmedBalance'], '20000',
        reason: 'the released input only; the change is not funds on the way');
    expect((await storage.getDeferredPayment(_w, _txid))!.state, DeferredPaymentState.cancelled);
  });

  test('3arz: a confirmation after the cancellation makes the change row available again', () async {
    final j = handedOver();
    j.add((v, at) => DeferredTransactionCancelledEvent(
        walletId: _w, txid: _txid,
        releasedInputs: [ReleasedDeferredInput(utxoKey: _input, restoredStatus: UTXOStatus.available)],
        version: v, timestamp: at));
    await project(j.events);
    expect((await utxos())['$_txid:$_changeVout']!.status, UTXOStatus.voided);

    // The recipient's copy was mined after all: the aggregate spends the
    // inputs, promotes the transaction's own outputs and confirms it.
    j.add((v, at) => UTXOSpentEvent(
        walletId: _w, txid: 'a1' * 32, vout: 0, spentInTxId: _txid, version: v, timestamp: at));
    j.add((v, at) =>
        UTXOMarkedAvailableEvent(walletId: _w, txid: _txid, vout: _changeVout, version: v, timestamp: at));
    j.add((v, at) => TransactionConfirmedEvent(
        walletId: _w, txid: _txid, blockHeight: 900001, blockHash: 'h', version: v, timestamp: at));
    await project(j.events.sublist(j.events.length - 3));

    expect((await utxos())['$_txid:$_changeVout']!.status, UTXOStatus.available,
        reason: 'a proof outranks the cancellation');
    expect((await storage.getDeferredPayment(_w, _txid))!.state, DeferredPaymentState.mined);
  });

  test('3arz: the same payment handed out again has pending change again', () async {
    final j = handedOver();
    j.add((v, at) => DeferredTransactionCancelledEvent(
        walletId: _w, txid: _txid,
        releasedInputs: [ReleasedDeferredInput(utxoKey: _input, restoredStatus: UTXOStatus.available)],
        version: v, timestamp: at));
    await project(j.events);
    expect((await utxos())['$_txid:$_changeVout']!.status, UTXOStatus.voided);

    j.add((v, at) => TransactionSpendDeferredEvent(
        walletId: _w, txid: _txid,
        heldInputs: [
          {'utxoKey': _input, 'satoshis': '20000'},
        ],
        recipientAddresses: const ['mrecipient'], paymentAmount: '1000', fee: 100, invoiceId: 'inv',
        purpose: 'invoice-payment', reactivated: true, recordedAt: at, version: v, timestamp: at));
    await project(j.events.sublist(j.events.length - 1));

    expect((await storage.getDeferredPayment(_w, _txid))!.state, DeferredPaymentState.outstanding);
    expect((await utxos())['$_txid:$_changeVout']!.status, UTXOStatus.pending);
  });

  test('wfvi: a reclaim whose held input another transaction spent fails at once, with no ARC poll',
      () async {
    final j = handedOver();
    // The reclaim: the self-spend takes over the hold and names the payment
    // it reclaims in its purpose.
    j.add((v, at) => TransactionRecordedEvent(
        walletId: _w, txid: _reclaimTxid, rawHex: '00', totalInputSats: 20000, totalOutputSats: 19900,
        fee: 100, numInputs: 1, numOutputs: 1, txVersion: 1, txLockTime: 0, spentUtxoKeys: [_input],
        recipientAddresses: const ['mroot'], paymentAmount: '19900', version: v, timestamp: at));
    j.add((v, at) => TransactionSpendDeferredEvent(
        walletId: _w, txid: _reclaimTxid,
        heldInputs: [
          {'utxoKey': _input, 'satoshis': '20000'},
        ],
        recipientAddresses: const ['mroot'], paymentAmount: '19900', fee: 100,
        purpose: DeferredPaymentPurpose.reclaimOf(_txid), supersedes: _txid, recordedAt: at,
        version: v, timestamp: at));
    j.add((v, at) => DeferredSpendReclaimedEvent(
        walletId: _w, txid: _txid, reclaimTxid: _reclaimTxid, reclaimedUtxoKeys: [_input],
        reason: 'recipient vanished', version: v, timestamp: at));
    await project(j.events);
    expect((await storage.getDeferredPayment(_w, _reclaimTxid))!.state, DeferredPaymentState.outstanding);

    // The recipient's copy reached the network first: the held input is spent
    // by the payment, not by our self-spend.
    j.add((v, at) => UTXOSpentEvent(
        walletId: _w, txid: 'a1' * 32, vout: 0, spentInTxId: _txid, version: v, timestamp: at));
    await project(j.events.sublist(j.events.length - 1));

    final selfSpend = (await storage.getDeferredPayment(_w, _reclaimTxid))!;
    expect(selfSpend.state, DeferredPaymentState.failed,
        reason: 'the self-spend can never be mined; it does not wait for ARC to say so');
    expect(selfSpend.resolutionReason, allOf(contains(_txid), contains('first seen wins')));
    expect(selfSpend.lastNetworkStatus, isNull, reason: 'nothing was asked of ARC');
    expect((await storage.getDeferredPayment(_w, _txid))!.state, DeferredPaymentState.seen,
        reason: "the recipient's copy is the one on the network");
    expect((await utxos())['$_txid:$_changeVout']!.status, UTXOStatus.pending,
        reason: "the payment's own change is still on the way: its copy is the one on the network");
  });

  test('wfvi: an ordinary deferred payment whose input another transaction spends stays outstanding',
      () async {
    final j = handedOver();
    await project(j.events);

    j.add((v, at) => UTXOSpentEvent(
        walletId: _w, txid: 'a1' * 32, vout: 0, spentInTxId: 'ff' * 32, version: v, timestamp: at));
    await project(j.events.sublist(j.events.length - 1));

    expect((await storage.getDeferredPayment(_w, _txid))!.state, DeferredPaymentState.outstanding,
        reason: 'bead libspiffy-ey2: either transaction may still be mined');
    expect((await utxos())['$_txid:$_changeVout']!.status, UTXOStatus.pending);
  });
}
