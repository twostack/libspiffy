/// Bead libspiffy-yyby: an invoice is paid by a payment the network holds,
/// whenever the network turns out to hold it.
///
/// A received payment is answered when ARC answers, and the invoice is
/// marked paid then (received_payment_is_submitted_test). But ARC's answer
/// is not always a verdict: a payment it calls DOUBLE_SPEND_ATTEMPTED (the
/// payer reclaimed first) or puts in the orphan mempool may still be mined,
/// and ARC follows it to its block either way — that is how the merkle
/// proof of our own outputs arrives. When it does, the invoice must settle,
/// including after a restart, where nothing in this process ever saw the
/// receive.
///
/// The coordinator hears it from the wallet read model: ARCActor makes a
/// held payment's outputs available (libspiffy-vj4j) and confirms it from a
/// verified proof, and both are journaled. The payment is matched to the
/// invoice as the receive matched it — an invoice's addresses are its own,
/// used once — and must cover it.
library;

import 'dart:async';

import 'package:dactor/dactor.dart';
import 'package:eventador/eventador.dart';
import 'package:test/test.dart';

import 'package:libspiffy/src/actors/invoice_messages.dart' as inv;
import 'package:libspiffy/src/actors/wallet_coordinator_actor.dart';
import 'package:libspiffy/src/core/wallet_events.dart' as domain;
import 'package:libspiffy/src/models/invoice_read_model.dart';
import 'package:libspiffy/src/models/transaction_address_link.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';

const _walletId = 'wallet-yyby';
const _invoiceAddress = 'mqCnSf8i6kmaQaJ54HjQ8EUJnuK4AnCv12';
const _otherAddress = 'muq9kAb9ri62VChAMRkuwK5bTve4iDLWBg';
const _txid = 'ab12';

void main() {
  late ActorSystem actorSystem;
  late InMemoryWalletStorage storage;
  late StreamController<Event> readModel;
  late _InvoiceProbe invoices;

  /// An invoice for 90,000 satoshis to [_invoiceAddress], still pending.
  Future<void> pendingInvoice({String invoiceId = 'inv-1', int amount = 90000}) =>
      storage.storeInvoice(InvoiceReadModel(
        invoiceId: invoiceId,
        walletId: _walletId,
        addresses: const [_invoiceAddress],
        amount: BigInt.from(amount),
        status: inv.InvoiceStatus.pending,
        createdAt: DateTime.now(),
        lastUpdated: DateTime.now(),
        metadata: const {},
      ));

  /// A received transaction paying [toInvoice] satoshis to the invoice's
  /// address, and something to an address of nobody's.
  Future<void> receivedPayment({int toInvoice = 90000}) =>
      storage.storeTransactionAddresses(_walletId, _txid, [
        TransactionAddressLink(
            address: _invoiceAddress, direction: 'output', amount: BigInt.from(toInvoice), vout: 0),
        TransactionAddressLink(
            address: _otherAddress, direction: 'output', amount: BigInt.from(1000), vout: 1),
      ]);

  Future<void> start() async {
    final probe = await actorSystem.spawn('invoices', () => invoices);
    final noop = await actorSystem.spawn('noop', () => _Noop());
    final coordinator = WalletCoordinatorActor(
      walletManager: noop,
      invoiceCoordinator: probe,
      paymentCoordinator: noop,
      spvActor: noop,
      arcActor: noop,
      headerSyncActor: noop,
      benfordCoordinator: noop,
      channelManager: noop,
      walletProjection: noop,
      storage: storage,
      readModelEvents: readModel.stream,
    );
    await actorSystem.spawn('coordinator', () => coordinator);
  }

  /// Waits for what the coordinator told the invoice coordinator, or
  /// nothing after [settle].
  Future<List<inv.MarkInvoicePaidMessage>> marks(
      {Duration settle = const Duration(milliseconds: 300)}) async {
    final deadline = DateTime.now().add(settle);
    while (invoices.marked.isEmpty && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    return invoices.marked;
  }

  setUp(() async {
    actorSystem = LocalActorSystem();
    storage = InMemoryWalletStorage();
    readModel = StreamController<Event>.broadcast();
    invoices = _InvoiceProbe();
  });

  tearDown(() async {
    await readModel.close();
    await actorSystem.shutdown();
  });

  test('the network holds the payment: its invoice is paid, for what it paid', () async {
    await pendingInvoice();
    await receivedPayment();
    await start();

    // ARCActor heard the network holds it and made its output available.
    readModel.add(domain.UTXOMarkedAvailableEvent(walletId: _walletId, txid: _txid, vout: 0));

    final mark = (await marks()).single;
    expect((mark.invoiceId, mark.txid, mark.amountReceived), ('inv-1', _txid, BigInt.from(90000)));
    expect(mark.addressesPaidTo, [_invoiceAddress]);
  });

  test('a block confirms the payment: its invoice is paid', () async {
    await pendingInvoice();
    await receivedPayment();
    await start();

    readModel.add(domain.TransactionConfirmedEvent(
        walletId: _walletId, txid: _txid, blockHeight: 15000));

    expect((await marks()).single.invoiceId, 'inv-1');
  });

  test('a payment that does not cover the invoice pays nothing', () async {
    await pendingInvoice();
    await receivedPayment(toInvoice: 89999);
    await start();

    readModel.add(domain.UTXOMarkedAvailableEvent(walletId: _walletId, txid: _txid, vout: 0));

    expect(await marks(), isEmpty);
  });

  test('an invoice that is not pending is left alone', () async {
    await storage.storeInvoice(InvoiceReadModel(
      invoiceId: 'inv-paid',
      walletId: _walletId,
      addresses: const [_invoiceAddress],
      amount: BigInt.from(90000),
      status: inv.InvoiceStatus.paid,
      createdAt: DateTime.now(),
      lastUpdated: DateTime.now(),
      paymentTxid: _txid,
      metadata: const {},
    ));
    await receivedPayment();
    await start();

    readModel.add(domain.UTXOMarkedAvailableEvent(walletId: _walletId, txid: _txid, vout: 0));

    expect(await marks(), isEmpty, reason: 'the invoice is paid; marking it again is refused');
  });

  test('a payment to nobody\'s invoice pays nothing', () async {
    await pendingInvoice();
    await storage.storeTransactionAddresses(_walletId, _txid, [
      TransactionAddressLink(
          address: _otherAddress, direction: 'output', amount: BigInt.from(90000), vout: 0),
    ]);
    await start();

    readModel.add(domain.UTXOMarkedAvailableEvent(walletId: _walletId, txid: _txid, vout: 0));

    expect(await marks(), isEmpty);
  });
}

/// Records what the coordinator asks the invoice coordinator to do.
class _InvoiceProbe extends Actor {
  final List<inv.MarkInvoicePaidMessage> marked = [];

  @override
  Future<void> onMessage(dynamic message) async {
    if (message is inv.MarkInvoicePaidMessage) marked.add(message);
  }
}

class _Noop extends Actor {
  @override
  Future<void> onMessage(dynamic message) async {}
}
