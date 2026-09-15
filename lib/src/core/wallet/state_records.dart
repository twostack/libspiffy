/// Helpers for the records the wallet aggregate keeps in
/// `WalletState.metadata` (bead libspiffy-dp4).
library;

import '../../models/persistent_map.dart';

/// The keys under which the wallet aggregate keeps its records in
/// `WalletState.metadata`. Part of the snapshot format: do not rename.
abstract final class WalletMetadataKeys {
  /// txid -> imported transaction record.
  static const String importedTransactions = 'importedTransactions';

  /// txid -> outgoing transaction record (a list of records in states built
  /// before audit 2026-09-14 M7).
  static const String outgoingTransactions = 'outgoingTransactions';

  /// txid -> deferred payment record (state, held keys, last network status).
  static const String deferredSpends = 'deferredSpends';

  /// utxoKey -> txid of the outstanding deferred payment holding it.
  static const String deferredHolds = 'deferredHolds';
}

/// [record] (a frozen map in the state's metadata) as a [PersistentMap].
PersistentMap<String, dynamic> frozenRecord(Map record) =>
    record is PersistentMap<String, dynamic> ? record : freezeMap(record);

/// A `PersistentMap<String, T>` of the entries of [value] whose values are
/// [T] (snapshot data arrives as untyped maps); [value] itself when it is
/// one already.
PersistentMap<String, T> typedEntries<T>(Object? value) {
  if (value is PersistentMap<String, T>) return value;
  var map = PersistentMap<String, T>.empty();
  if (value is Map) {
    value.forEach((k, v) {
      if (v is T) map = map.put(k.toString(), v);
    });
  }
  return map;
}
