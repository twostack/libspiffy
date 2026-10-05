/// The order an import records transactions in: oldest block first, and
/// inside one block every parent before the transactions that spend it.
///
/// Recording a transaction marks as spent the wallet outputs its inputs
/// spend, and only outputs the wallet already holds can be marked. A child
/// recorded before its parent therefore marks nothing, and the parent then
/// leaves the spent output available for ever. Sorting by height alone left
/// the order inside one block to chance: a parent and its children mined in
/// the same block were recorded in whatever order the sort produced.
///
/// [heightOf] is the block height (an import records only transactions with
/// a proof, so every one has a height). [parentsOf] names the txids an item's
/// inputs spend; a parent outside [items] is ignored. Items of equal height
/// with no dependency between them keep their input order, so the result is
/// deterministic. A dependency cycle (which no valid chain contains) does not
/// loop: the item reached again is placed where it stands.
List<T> orderForImport<T>(
  List<T> items, {
  required String Function(T) txidOf,
  required int Function(T) heightOf,
  required Iterable<String> Function(T) parentsOf,
}) {
  final indexed = [for (var i = 0; i < items.length; i++) (i, items[i])];
  indexed.sort((a, b) {
    final byHeight = heightOf(a.$2).compareTo(heightOf(b.$2));
    return byHeight != 0 ? byHeight : a.$1.compareTo(b.$1);
  });

  final byTxid = {for (final (_, item) in indexed) txidOf(item): item};
  final placed = <String>{};
  final visiting = <String>{};
  final result = <T>[];

  void place(T item) {
    final txid = txidOf(item);
    if (placed.contains(txid) || !visiting.add(txid)) return;
    for (final parentTxid in parentsOf(item)) {
      final parent = byTxid[parentTxid];
      if (parent != null && parentTxid != txid) place(parent);
    }
    visiting.remove(txid);
    if (placed.add(txid)) result.add(item);
  }

  for (final (_, item) in indexed) {
    place(item);
  }
  return result;
}
