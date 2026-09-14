/// n0p (libspiffy-n0p): InvoiceAggregate accepted a payment only when it
/// went to one of the invoice's P2PKH addresses. An invoice whose outputs
/// are multisig outputs has none, so its payment (which SPVActor matches
/// against the invoice's keys and threshold and reports as 'p2ms:m-of-n')
/// was refused with "Payment was not made to any of the invoice addresses".
library;

import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:test/test.dart';

import 'package:libspiffy/src/actors/invoice_messages.dart' show InvoiceStatus;
import 'package:libspiffy/src/core/invoice_aggregate.dart';
import 'package:libspiffy/src/core/invoice_commands.dart';
import 'package:libspiffy/src/core/invoice_events.dart';
import 'package:libspiffy/src/models/invoice_output_spec.dart';

import '../actors/in_memory_event_store.dart';

const _invoiceId = 'n0p-invoice';

void main() {
  late InMemoryEventStore store;
  late InvoiceAggregate invoice;

  final keys = [
    for (final seed in ['11', '22', '33'])
      dartsv.SVPrivateKey.fromHex(seed * 32, dartsv.NetworkType.TEST).publicKey.toHex(),
  ];

  setUp(() async {
    store = InMemoryEventStore();
    invoice = InvoiceAggregate(aggregateId: _invoiceId, aggregateType: 'Invoice', eventStore: store);
    await invoice.preStart();
    await invoice.commandHandler(CreateInvoiceCommand(
      invoiceId: _invoiceId,
      walletId: 'wallet',
      addresses: const [],
      amount: BigInt.from(100000),
      outputs: [P2MSOutputSpec(publicKeys: keys, threshold: 2, amount: BigInt.from(100000))],
    ));
  });

  MarkInvoicePaidCommand paid(List<String> to) => MarkInvoicePaidCommand(
        invoiceId: _invoiceId,
        txid: 'ab' * 32,
        amountReceived: BigInt.from(100000),
        addressesPaidTo: to,
      );

  test('a payment to the invoice\'s 2-of-3 multisig output marks it paid', () async {
    await invoice.commandHandler(paid(['p2ms:2-of-3']));
    expect(invoice.currentState.status, InvoiceStatus.paid);
    expect(store.allEvents.whereType<InvoicePaidEvent>().single.addressesPaidTo, ['p2ms:2-of-3']);
  });

  test('a payment to a multisig output of another shape is refused', () async {
    await expectLater(invoice.commandHandler(paid(['p2ms:1-of-3'])), throwsA(isA<ArgumentError>()));
    expect(invoice.currentState.status, InvoiceStatus.pending);
    expect(store.allEvents.whereType<InvoicePaidEvent>(), isEmpty);
  });
}
