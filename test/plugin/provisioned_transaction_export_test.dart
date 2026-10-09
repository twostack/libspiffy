// A plugin that implements TransactionBuilderPlugin.provisionFunding returns
// ProvisionedTransactions; it names the type through the public API, not by
// importing lib/src.
import 'package:libspiffy/libspiffy.dart';
import 'package:test/test.dart';

void main() {
  test('ProvisionedTransaction is part of the public API', () {
    const split = ProvisionedTransaction(
        txid: 'aa', rawHex: '00', feeSats: 10, role: 'split', fundingVout: -1, fundingSats: -1);
    expect(split.role, 'split');
  });
}
