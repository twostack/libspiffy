import 'package:libspiffy/src/services/import_order.dart';
import 'package:test/test.dart';

typedef _Tx = ({String txid, int height, List<String> parents});

List<String> _order(List<_Tx> txs) => orderForImport<_Tx>(
      txs,
      txidOf: (t) => t.txid,
      heightOf: (t) => t.height,
      parentsOf: (t) => t.parents,
    ).map((t) => t.txid).toList();

void main() {
  group('orderForImport', () {
    test('a parent and the children that spend it in one block: the parent comes first', () {
      // The shape of the stuck payment's coin: 14cac42f and both spends of
      // its outputs were mined in block 1730300.
      final order = _order([
        (txid: 'child-a', height: 1730300, parents: ['parent']),
        (txid: 'child-b', height: 1730300, parents: ['parent']),
        (txid: 'parent', height: 1730300, parents: ['funding']),
      ]);
      expect(order.indexOf('parent'), lessThan(order.indexOf('child-a')));
      expect(order.indexOf('parent'), lessThan(order.indexOf('child-b')));
    });

    test('a chain inside one block is recorded from its root', () {
      expect(
        _order([
          (txid: 'c', height: 5, parents: ['b']),
          (txid: 'b', height: 5, parents: ['a']),
          (txid: 'a', height: 5, parents: []),
        ]),
        ['a', 'b', 'c'],
      );
    });

    test('older blocks come first, whatever the input order', () {
      expect(
        _order([
          (txid: 'new', height: 9, parents: []),
          (txid: 'old', height: 2, parents: []),
          (txid: 'mid', height: 5, parents: []),
        ]),
        ['old', 'mid', 'new'],
      );
    });

    test('unrelated transactions of one block keep their input order', () {
      expect(
        _order([
          (txid: 'x', height: 3, parents: ['elsewhere']),
          (txid: 'y', height: 3, parents: []),
          (txid: 'z', height: 3, parents: ['other']),
        ]),
        ['x', 'y', 'z'],
      );
    });

    test('every item appears once, even with a cycle', () {
      final order = _order([
        (txid: 'p', height: 1, parents: ['q']),
        (txid: 'q', height: 1, parents: ['p']),
        (txid: 'r', height: 1, parents: ['r']),
      ]);
      expect(order..sort(), ['p', 'q', 'r']);
    });
  });
}
