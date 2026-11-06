import 'package:libspiffy/src/core/invoice_commands.dart';
import 'package:libspiffy/src/models/invoice_output_spec.dart';
import 'package:libspiffy/src/utils/even_split.dart';
import 'package:test/test.dart';

void main() {
  test('the parts add up to the amount: the last takes the remainder (spiffyvault-bnb, 2ct.7)', () {
    expect(evenSplit(BigInt.from(1001), 2), [BigInt.from(500), BigInt.from(501)]);
    expect(evenSplit(BigInt.from(10), 3), [BigInt.from(3), BigInt.from(3), BigInt.from(4)]);
    expect(evenSplit(BigInt.from(900), 3), [BigInt.from(300), BigInt.from(300), BigInt.from(300)]);
    expect(evenSplit(BigInt.from(7), 1), [BigInt.from(7)]);
    expect(() => evenSplit(BigInt.one, 0), throwsArgumentError);
  });

  test('an invoice with several addresses and no outputs list expects every satoshi', () {
    final invoice = CreateInvoiceCommand(
        invoiceId: 'i', walletId: 'w', addresses: const ['a', 'b', 'c'], amount: BigInt.from(1000));
    final amounts = [for (final o in invoice.effectiveOutputs) (o as P2PKHOutputSpec).amount.toInt()];
    expect(amounts, [333, 333, 334]);
  });
}
