/// Helpers for the records the wallet aggregate keeps in
/// `WalletState.metadata` (bead libspiffy-dp4).
library;

import '../../models/persistent_map.dart';

/// The keys of `WalletState.metadata`, and of the wallet row's metadata in
/// the read model, that belong to the wallet rather than the host. Part of
/// the snapshot and read-model formats: do not rename.
///
/// Host wallet metadata (`CreateWalletCommand.walletMetadata`,
/// `UpdateWalletConfigurationCommand.newMetadata`) shares both maps with
/// these records, so a command naming one of them is rejected, and a
/// journaled event written before that rule applies only its other keys
/// (bead libspiffy-hfai). A new internal key belongs in [reserved], or a
/// host can overwrite it.
abstract final class WalletMetadataKeys {
  // --- Records of the wallet aggregate (WalletState.metadata) --------------

  /// txid -> imported transaction record.
  static const String importedTransactions = 'importedTransactions';

  /// txid -> outgoing transaction record (a list of records in states built
  /// before audit 2026-09-14 M7).
  static const String outgoingTransactions = 'outgoingTransactions';

  /// txid -> deferred payment record (state, held keys, last network status).
  static const String deferredSpends = 'deferredSpends';

  /// utxoKey -> txid of the outstanding deferred payment holding it.
  static const String deferredHolds = 'deferredHolds';

  /// address -> derivation index (signing key lookup).
  static const String addressIndices = 'address_indices';

  /// address -> derivation chain (true = change chain m/1/i).
  static const String addressChains = 'address_chains';

  /// Canonical network name. A wallet's network is given under this key in
  /// `CreateWalletCommand.walletMetadata` ([creationInputs]) and is fixed
  /// from then on.
  static const String network = 'network';

  // --- Derived values of the wallet row (WalletProjection, storage) --------

  /// Written into the wallet row's metadata by the wallet projection, or
  /// read from the metadata a storage backend's `storeWallet` is given (the
  /// Isar backend takes its wallet type, derivation index, aggregate version,
  /// balance and JSON columns from there).
  static const Set<String> readModel = {
    'walletType',
    'confirmedBalance',
    'unconfirmedBalance',
    'reservedBalance',
    'totalBalance',
    'addressCount',
    'utxoCount',
    'availableUtxoCount',
    'reservedUtxoCount',
    'spentUtxoCount',
    'lastUpdated',
    'derivationIndex',
    'aggregateVersion',
    'addressesJson',
    'publicKeysJson',
  };

  /// Every key host wallet metadata may not name.
  static const Set<String> reserved = {
    importedTransactions,
    outgoingTransactions,
    deferredSpends,
    deferredHolds,
    addressIndices,
    addressChains,
    network,
    ...readModel,
  };

  /// Reserved keys a wallet creation takes as input.
  static const Set<String> creationInputs = {network};

  /// The reserved keys [metadata] names, in its order; [creationInputs] are
  /// allowed when [creation].
  static List<String> reservedIn(Map<String, dynamic>? metadata, {bool creation = false}) => [
        for (final key in metadata?.keys ?? const <String>[])
          if (reserved.contains(key) && !(creation && creationInputs.contains(key))) key,
      ];

  /// Rejects host wallet metadata [metadata] (the command field [field])
  /// that names a reserved key, with an [ArgumentError].
  static void requireHostMetadata(Map<String, dynamic>? metadata, String field, {bool creation = false}) {
    final names = reservedIn(metadata, creation: creation);
    if (names.isEmpty) return;
    throw ArgumentError('$field names wallet metadata keys reserved for the wallet: '
        '${names.join(', ')}; use other keys');
  }

  /// The entries of journaled host metadata [metadata] that may be applied:
  /// all but its reserved keys ([creationInputs] kept when [creation]).
  /// [metadata] itself when it names none.
  static Map<String, dynamic> hostEntries(Map<String, dynamic> metadata, {bool creation = false}) {
    final names = reservedIn(metadata, creation: creation);
    if (names.isEmpty) return metadata;
    return {
      for (final entry in metadata.entries)
        if (!names.contains(entry.key)) entry.key: entry.value,
    };
  }
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
