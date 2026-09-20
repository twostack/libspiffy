/// Rules every [ReadModelStorage] backend applies to a wallet row it stores,
/// in one place: the value types of the row's metadata (bead libspiffy-k7na)
/// and the network it writes (bead libspiffy-sxk5).
library;

import 'dart:convert';

import '../utils/network_name.dart';

/// The rules, shared by the in-memory, Isar and Postgres backends.
abstract final class WalletRowRules {
  /// Balances: decimal strings of satoshis.
  static const Set<String> balanceKeys = {
    'confirmedBalance',
    'unconfirmedBalance',
    'reservedBalance',
    'totalBalance',
    'watchOnlyBalance',
  };

  /// Counts, the derivation index and the aggregate version: integers.
  static const Set<String> integerKeys = {
    'derivationIndex',
    'aggregateVersion',
    'addressCount',
    'utxoCount',
    'availableUtxoCount',
    'reservedUtxoCount',
    'spentUtxoCount',
    'notSpendableAloneUtxoCount',
  };

  /// Plain strings.
  static const Set<String> stringKeys = {'walletType', 'lastUpdated'};

  /// JSON documents stored as strings.
  static const Set<String> jsonKeys = {'addressesJson', 'publicKeysJson'};

  static final _integer = RegExp(r'^-?\d+$');

  /// The network a wallet row gets when it is created without one (bead
  /// libspiffy-sxk5).
  ///
  /// It is [NetworkName.canonical] of nothing, so the backends, the wallet
  /// aggregate ([NetworkName.canonical] in `wallet_keys.dart` and
  /// `wallet_lifecycle.dart`) and the actor system (whose own default is
  /// `'test'`, the same network spelled the P2P layer's way) all resolve an
  /// unspecified network to the SAME one. They used to disagree: the
  /// backends defaulted to `'mainnet'` while everything else defaulted to
  /// testnet, so an external caller of the exported
  /// `ReadModelStorage.storeWallet` created a row that read back
  /// [NetworkName.isMainnet] and MAIN address encoding on a wallet the
  /// aggregate considered testnet.
  ///
  /// Testnet is also the safe direction to be wrong in: a wallet wrongly
  /// taken for testnet cannot encode an address that receives real coins.
  static final String defaultNetwork = NetworkName.canonical(null);

  /// The network a store writes, or null to keep the stored one.
  ///
  /// Canonicalised, so the spellings the actor system, importer and P2P
  /// layer use (`'main'`, `'test'`, `'regtest'`) never land in a row beside
  /// the read model's own (`'mainnet'`, `'testnet'`, `'regtest'`). A null
  /// means "keep what is stored", as it does for `rootAddress` and
  /// `metadata`, and on an insert the backend writes [defaultNetwork].
  static String? canonicalNetwork(String? networkType) =>
      networkType == null ? null : NetworkName.canonical(networkType);

  /// [metadata] as a backend stores it: each value of a typed key above
  /// converted to its type, every value checked to be JSON (the persistent
  /// backends store the metadata as a JSON document).
  ///
  /// Conversions, the only readings that are unambiguous: a balance from an
  /// int, a BigInt or a string of an integer; an integer from a string of an
  /// integer or an integral double; `lastUpdated` from a DateTime (ISO 8601);
  /// a JSON column from a list or map (encoded). A null value is kept.
  ///
  /// Throws an [ArgumentError] whose `name` is the offending key when a value
  /// has no such reading or is not JSON. Backends call this before writing,
  /// so a rejected store writes nothing. Returns [metadata] itself when
  /// nothing is converted.
  static Map<String, dynamic>? normalizeMetadata(Map<String, dynamic>? metadata) {
    if (metadata == null) return null;
    Map<String, dynamic>? converted;
    for (final entry in metadata.entries) {
      final key = entry.key;
      final value = entry.value;
      final normalized = value == null ? null : _normalize(key, value);
      if (!identical(normalized, value)) {
        (converted ??= Map<String, dynamic>.of(metadata))[key] = normalized;
      }
      try {
        jsonEncode(normalized);
      } on JsonUnsupportedObjectError {
        throw ArgumentError.value(value, key, 'Wallet metadata value is not JSON (${value.runtimeType})');
      }
    }
    return converted ?? metadata;
  }

  static Object _normalize(String key, Object value) {
    if (balanceKeys.contains(key)) {
      return switch (value) {
        final String s when _integer.hasMatch(s) => _canonical(s),
        final int i => i.toString(),
        final BigInt b => b.toString(),
        _ => throw ArgumentError.value(
            value, key, 'Wallet metadata balance must be an integer number of satoshis (${value.runtimeType})'),
      };
    }
    if (integerKeys.contains(key)) {
      return switch (value) {
        final int i => i,
        final String s when _integer.hasMatch(s) && int.tryParse(s) != null => int.parse(s),
        final double d when d.isFinite && d == d.truncateToDouble() => d.toInt(),
        _ => throw ArgumentError.value(value, key, 'Wallet metadata value must be an integer (${value.runtimeType})'),
      };
    }
    if (stringKeys.contains(key)) {
      return switch (value) {
        final String s => s,
        final DateTime t when key == 'lastUpdated' => t.toIso8601String(),
        _ => throw ArgumentError.value(value, key, 'Wallet metadata value must be a string (${value.runtimeType})'),
      };
    }
    if (jsonKeys.contains(key)) {
      return switch (value) {
        final String s => s,
        final List<dynamic> l => _encode(key, l),
        final Map<dynamic, dynamic> m => _encode(key, m),
        _ => throw ArgumentError.value(
            value, key, 'Wallet metadata JSON column must be a JSON string, list or map (${value.runtimeType})'),
      };
    }
    return value;
  }

  /// [digits] as BigInt prints it (no leading zeros, no '-0'); [digits]
  /// itself when it already is.
  static String _canonical(String digits) {
    final canonical = BigInt.parse(digits).toString();
    return canonical == digits ? digits : canonical;
  }

  static String _encode(String key, Object value) {
    try {
      return jsonEncode(value);
    } on JsonUnsupportedObjectError {
      throw ArgumentError.value(value, key, 'Wallet metadata value is not JSON (${value.runtimeType})');
    }
  }
}
