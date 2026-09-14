/// Shared invoice read-model contract for the three [ReadModelStorage]
/// backends (audit 2026-09-14 S-07).
///
/// Every backend must accept the [InvoiceReadModel] that [InvoiceProjection]
/// stores, apply a status update to it, and hand back a typed
/// [InvoiceReadModel] — outputs included — from both the single-invoice and
/// the listing queries.
library;

import 'package:test/test.dart';

import 'package:libspiffy/src/actors/invoice_messages.dart' show InvoiceStatus;
import 'package:libspiffy/src/models/invoice_output_spec.dart';
import 'package:libspiffy/src/models/invoice_read_model.dart';
import 'package:libspiffy/src/storage/read_model_storage.dart';

const contractInvoiceAddress1 = 'mkHS9ne12qx9pS9VojpwU5xtRd4T7X7ZUt';
const contractInvoiceAddress2 = 'n2eMqTT929pb1RDNuqEnxdaLau1rxy3efi';
final contractInvoiceAmount = BigInt.from(15000);
final contractInvoicePaidTxid = 'e5' * 32;
final contractInvoiceCreatedAt = DateTime.utc(2026, 9, 14, 12, 0, 0);
final contractInvoiceExpiresAt = DateTime.utc(2026, 9, 15, 12, 0, 0);
final contractInvoicePaidAt = DateTime.utc(2026, 9, 14, 12, 45, 0);

/// The read model exactly as `InvoiceProjection._handleInvoiceCreated`
/// builds it: two P2PKH outputs, metadata, an expiry, still pending.
InvoiceReadModel contractInvoice({
  required String invoiceId,
  required String walletId,
}) =>
    InvoiceReadModel(
      invoiceId: invoiceId,
      walletId: walletId,
      addresses: const [contractInvoiceAddress1, contractInvoiceAddress2],
      amount: contractInvoiceAmount,
      outputs: [
        P2PKHOutputSpec(
          address: contractInvoiceAddress1,
          amount: BigInt.from(10000),
          label: 'main',
        ),
        P2PKHOutputSpec(
          address: contractInvoiceAddress2,
          amount: BigInt.from(5000),
        ),
      ],
      description: 'contract invoice',
      status: InvoiceStatus.pending,
      createdAt: contractInvoiceCreatedAt,
      expiresAt: contractInvoiceExpiresAt,
      lastUpdated: contractInvoiceCreatedAt,
      metadata: const {'orderId': 'order-42'},
    );

/// Stores, updates and reads back an invoice through [storage].
Future<void> runInvoiceRoundTripContract(
  ReadModelStorage storage, {
  required String invoiceId,
  required String walletId,
}) async {
  await storage.storeInvoice(
    contractInvoice(invoiceId: invoiceId, walletId: walletId),
  );

  Future<InvoiceReadModel> read() async {
    final dynamic raw = await storage.getInvoice(invoiceId);
    expect(raw, isNotNull, reason: 'invoice $invoiceId must be stored');
    expect(raw, isA<InvoiceReadModel>(),
        reason: 'getInvoice must return InvoiceReadModel, '
            'got ${raw.runtimeType}');
    return raw as InvoiceReadModel;
  }

  var invoice = await read();
  expect(invoice.status, equals(InvoiceStatus.pending));
  expectContractOutputs(invoice);

  await storage.updateInvoiceStatus(
    invoiceId,
    InvoiceStatus.paid,
    txid: contractInvoicePaidTxid,
    amountReceived: contractInvoiceAmount,
    paidAt: contractInvoicePaidAt,
  );

  invoice = await read();
  expectPaidContractInvoice(invoice, invoiceId: invoiceId, walletId: walletId);

  final dynamic byWallet = await storage.getInvoicesByWallet(walletId);
  expect(byWallet, isA<List>());
  for (final item in byWallet as List) {
    expect(item, isA<InvoiceReadModel>(),
        reason: 'getInvoicesByWallet must return typed read models');
  }
  final listed =
      byWallet.cast<InvoiceReadModel>().where((i) => i.invoiceId == invoiceId);
  expect(listed, hasLength(1));
  expectPaidContractInvoice(listed.single,
      invoiceId: invoiceId, walletId: walletId);

  final dynamic byStatus =
      await storage.getInvoicesByStatus(InvoiceStatus.paid, walletId: walletId);
  expect(byStatus, isA<List>());
  final paid = (byStatus as List)
      .cast<InvoiceReadModel>()
      .where((i) => i.invoiceId == invoiceId);
  expect(paid, hasLength(1),
      reason: 'getInvoicesByStatus(paid) must include the paid invoice');
  expectContractOutputs(paid.single);
}

/// Asserts the two output specs survived the round trip.
void expectContractOutputs(InvoiceReadModel invoice) {
  expect(invoice.outputs, isNotNull, reason: 'outputs must be persisted');
  expect(invoice.outputs, hasLength(2));
  final first = invoice.outputs![0];
  expect(first, isA<P2PKHOutputSpec>());
  expect((first as P2PKHOutputSpec).address, equals(contractInvoiceAddress1));
  expect(first.amount, equals(BigInt.from(10000)));
  expect(first.label, equals('main'));
  final second = invoice.outputs![1];
  expect(second, isA<P2PKHOutputSpec>());
  expect((second as P2PKHOutputSpec).address, equals(contractInvoiceAddress2));
  expect(second.amount, equals(BigInt.from(5000)));
  expect(invoice.totalAmount, equals(contractInvoiceAmount));
}

/// Asserts every field after the paid status update.
void expectPaidContractInvoice(
  InvoiceReadModel invoice, {
  required String invoiceId,
  required String walletId,
}) {
  expect(invoice.invoiceId, equals(invoiceId));
  expect(invoice.walletId, equals(walletId));
  expect(invoice.addresses,
      equals([contractInvoiceAddress1, contractInvoiceAddress2]));
  expect(invoice.amount, equals(contractInvoiceAmount));
  expect(invoice.description, equals('contract invoice'));
  expect(invoice.status, equals(InvoiceStatus.paid));
  expect(invoice.paymentTxid, equals(contractInvoicePaidTxid));
  expect(invoice.amountReceived, equals(contractInvoiceAmount));
  expect(invoice.paidAt, isNotNull);
  expect(invoice.paidAt!.toUtc(), equals(contractInvoicePaidAt));
  expect(invoice.createdAt.toUtc(), equals(contractInvoiceCreatedAt));
  expect(invoice.expiresAt, isNotNull);
  expect(invoice.expiresAt!.toUtc(), equals(contractInvoiceExpiresAt));
  expect(invoice.metadata, equals({'orderId': 'order-42'}));
  expectContractOutputs(invoice);
}
