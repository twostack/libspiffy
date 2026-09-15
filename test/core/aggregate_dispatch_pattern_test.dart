/// libspiffy-r1l: aggregates dispatch commands and events by type patterns
/// (`case final X x:`), not by `runtimeType ==`. A subtype of a known command
/// reaches that command's handler; an unknown command still fails with the
/// same `Unknown command type: <runtimeType>` text.
library;

import 'package:test/test.dart';

import 'package:libspiffy/src/core/invoice_aggregate.dart';
import 'package:libspiffy/src/core/invoice_commands.dart';
import 'package:libspiffy/src/models/invoice_state.dart';

import '../actors/in_memory_event_store.dart';

const _invoiceId = 'r1l-invoice';

void main() {
  late InvoiceAggregate invoice;

  setUp(() {
    invoice = InvoiceAggregate(
        aggregateId: _invoiceId, aggregateType: 'Invoice', eventStore: InMemoryEventStore());
  });

  test('a subtype of a known command reaches that command handler', () async {
    await expectLater(
      invoice.handleCommand(InvoiceState.empty(_invoiceId), _AuditCancelInvoiceCommand()),
      throwsA(isA<StateError>().having(
          (e) => e.message, 'message', 'Invoice $_invoiceId does not exist')),
    );
  });

  test('an unknown command keeps the Unknown command type error text', () async {
    await expectLater(
      invoice.handleCommand(InvoiceState.empty(_invoiceId), _NotAnInvoiceCommand()),
      throwsA(isA<ArgumentError>().having(
          (e) => e.message, 'message', 'Unknown command type: _NotAnInvoiceCommand')),
    );
  });
}

class _AuditCancelInvoiceCommand extends CancelInvoiceCommand {
  _AuditCancelInvoiceCommand() : super(invoiceId: _invoiceId, reason: 'audit');
}

class _NotAnInvoiceCommand extends InvoiceCommand {
  _NotAnInvoiceCommand() : super(invoiceId: _invoiceId);
}
