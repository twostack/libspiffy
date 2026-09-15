import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:eventador/eventador.dart';
import 'package:meta/meta.dart';
import 'bitcoin_utxo.dart';
import 'persistent_map.dart';
import 'wallet_type.dart';

/// Represents the current state of a wallet at a specific point in time.
///
/// This class is used for event sourcing and represents the complete
/// wallet state derived from applying a sequence of wallet events via eventHandler.
///
/// Immutable (bead libspiffy-mmb): every field is final and every collection
/// is an unmodifiable [PersistentMap] whose nested maps and lists are
/// unmodifiable too. Applying an event produces a new state that shares the
/// collections the event did not change, so a state someone holds never
/// changes underneath them. The maps a constructor or [copyWithWallet] is
/// given are copied, not shared.
/// This is the write model - projections create separate read models for queries.
class WalletState extends State {
  /// Unique identifier for this wallet
  final String walletId;

  /// Human-readable name for the wallet
  final String name;

  /// Root address derived from the wallet's mnemonic/wif/xpriv
  final String? rootAddress;

  /// Whether the wallet has been created (initialized)
  final bool isCreated;

  /// Whether the wallet has been deleted
  final bool isDeleted;

  /// Network type (mainnet, testnet)
  final String networkType;

  /// Type of wallet (hd, wif, xpriv)
  final WalletType walletType;

  /// Timestamp when this state was created
  final DateTime timestamp;

  /// All UTXOs currently tracked by this wallet (unmodifiable; each UTXO's
  /// plugin metadata is unmodifiable too)
  final PersistentMap<String, BitcoinUtxo> utxos;

  /// Generated addresses for this wallet (unmodifiable: address -> label)
  final PersistentMap<String, String?> addresses;

  /// Watch addresses (unmodifiable: address -> script type): addresses the
  /// wallet holds no key for whose payments it attributes to itself (bead
  /// libspiffy-p4kv). Kept apart from [addresses], whose entries the wallet
  /// derives signing keys for.
  final PersistentMap<String, String> watchAddresses;

  /// Next address derivation index
  final int nextDerivationIndex;

  /// Additional wallet metadata (unmodifiable, nested maps and lists
  /// included)
  final PersistentMap<String, dynamic> metadata;

  /// Cached balance calculations
  final dartsv.Coin confirmedBalance;
  final dartsv.Coin unconfirmedBalance;
  final dartsv.Coin reservedBalance;

  @override
  final int version;

  @override
  final DateTime lastModified;

  WalletState({
    required this.walletId,
    required this.name,
    this.rootAddress,
    required this.isCreated,
    this.isDeleted = false,
    required this.networkType,
    required this.walletType,
    required this.timestamp,
    required Map<String, BitcoinUtxo> utxos,
    required Map<String, String?> addresses,
    required this.nextDerivationIndex,
    required Map<String, dynamic> metadata,
    required this.confirmedBalance,
    required this.unconfirmedBalance,
    required this.reservedBalance,
    this.version = 0,
    DateTime? lastModified,
    Map<String, String>? watchAddresses,
  }) : lastModified = lastModified ?? DateTime.now(),
       utxos = _frozenUtxos(utxos),
       addresses = PersistentMap.of(addresses),
       watchAddresses = watchAddresses == null ? PersistentMap.empty() : PersistentMap.of(watchAddresses),
       metadata = freezeMap(metadata),
       super(version: version, lastModified: lastModified ?? DateTime.now());

  /// [utxos] as a persistent map whose UTXOs carry unmodifiable plugin
  /// metadata. A persistent map is already frozen and is shared.
  static PersistentMap<String, BitcoinUtxo> _frozenUtxos(Map<String, BitcoinUtxo> utxos) {
    if (utxos is PersistentMap<String, BitcoinUtxo>) return utxos;
    return PersistentMap.of({
      for (final entry in utxos.entries) entry.key: frozenUtxo(entry.value),
    });
  }

  /// [utxo] with unmodifiable plugin metadata that no caller shares.
  @internal
  static BitcoinUtxo frozenUtxo(BitcoinUtxo utxo) {
    final pluginMetadata = utxo.pluginMetadata;
    if (pluginMetadata == null) return utxo;
    return utxo.copyWith(pluginMetadata: unmodifiableDeepCopy(pluginMetadata));
  }

  /// Create an empty wallet state (before wallet creation)
  factory WalletState.empty(String walletId) {
    final now = DateTime.now();
    return WalletState(
      walletId: walletId,
      name: '',
      rootAddress: null,
      isCreated: false,
      isDeleted: false,
      networkType: 'mainnet',
      walletType: WalletType.hd, // Default to HD
      timestamp: now,
      utxos: PersistentMap.empty(),
      addresses: PersistentMap.empty(),
      nextDerivationIndex: 0,
      metadata: PersistentMap.empty(),
      confirmedBalance: dartsv.Coin.ofSat(BigInt.zero),
      unconfirmedBalance: dartsv.Coin.ofSat(BigInt.zero),
      reservedBalance: dartsv.Coin.ofSat(BigInt.zero),
      version: 0,
      lastModified: now,
    );
  }

  /// Create an initial wallet state after creation
  factory WalletState.initial({
    required String walletId,
    required String name,
    required String rootAddress,
    required String networkType,
    WalletType walletType = WalletType.hd,
  }) {
    final now = DateTime.now();
    return WalletState(
      walletId: walletId,
      name: name,
      rootAddress: rootAddress,
      isCreated: true,
      networkType: networkType,
      walletType: walletType,
      timestamp: now,
      utxos: PersistentMap.empty(),
      addresses: PersistentMap.empty(),
      nextDerivationIndex: 0,
      metadata: PersistentMap.empty(),
      confirmedBalance: dartsv.Coin.ofSat(BigInt.zero),
      unconfirmedBalance: dartsv.Coin.ofSat(BigInt.zero),
      reservedBalance: dartsv.Coin.ofSat(BigInt.zero),
      version: 1,
      lastModified: now,
    );
  }

  /// Override the base State copyWith method (only version and lastModified).
  ///
  /// Delegates to [copyWithWallet] so every other field is carried over from
  /// one place: this copy used to list the fields itself and dropped
  /// [isDeleted], so a copy of a deleted wallet's state (e.g. through
  /// `nextVersion`) was not deleted (bead libspiffy-bn03).
  @override
  WalletState copyWith({
    int? version,
    DateTime? lastModified,
  }) =>
      copyWithWallet(version: version, lastModified: lastModified);

  /// Create a copy of this state with updated wallet-specific fields. The
  /// collections not replaced are shared (they are immutable); the ones
  /// given are copied.
  WalletState copyWithWallet({
    String? walletId,
    String? name,
    String? rootAddress,
    bool? isCreated,
    bool? isDeleted,
    String? networkType,
    WalletType? walletType,
    DateTime? timestamp,
    Map<String, BitcoinUtxo>? utxos,
    Map<String, String?>? addresses,
    Map<String, String>? watchAddresses,
    int? nextDerivationIndex,
    Map<String, dynamic>? metadata,
    dartsv.Coin? confirmedBalance,
    dartsv.Coin? unconfirmedBalance,
    dartsv.Coin? reservedBalance,
    int? version,
    DateTime? lastModified,
  }) {
    return WalletState(
      walletId: walletId ?? this.walletId,
      name: name ?? this.name,
      rootAddress: rootAddress ?? this.rootAddress,
      isCreated: isCreated ?? this.isCreated,
      isDeleted: isDeleted ?? this.isDeleted,
      networkType: networkType ?? this.networkType,
      walletType: walletType ?? this.walletType,
      timestamp: timestamp ?? this.timestamp,
      utxos: utxos ?? this.utxos,
      addresses: addresses ?? this.addresses,
      watchAddresses: watchAddresses ?? this.watchAddresses,
      nextDerivationIndex: nextDerivationIndex ?? this.nextDerivationIndex,
      metadata: metadata ?? this.metadata,
      confirmedBalance: confirmedBalance ?? this.confirmedBalance,
      unconfirmedBalance: unconfirmedBalance ?? this.unconfirmedBalance,
      reservedBalance: reservedBalance ?? this.reservedBalance,
      version: version ?? this.version,
      lastModified: lastModified ?? this.lastModified,
    );
  }

  /// A draft of this state for applying one event (see [WalletStateBuilder]).
  @internal
  WalletStateBuilder toBuilder() => WalletStateBuilder._(this);

  /// Get total balance in satoshis (confirmed + unconfirmed)
  BigInt get balance {
    return confirmedBalance.getValue() + unconfirmedBalance.getValue();
  }

  /// Get total available balance (confirmed + unconfirmed - reserved)
  BigInt get availableBalance {
    final available = confirmedBalance.getValue() +
                     unconfirmedBalance.getValue() -
                     reservedBalance.getValue();
    return available > BigInt.zero ? available : BigInt.zero;
  }

  /// Get all available (spendable) UTXOs
  List<BitcoinUtxo> get availableUtxos {
    return utxos.values
        .where((utxo) => utxo.status == UTXOStatus.available)
        .toList();
  }

  /// Recalculate balances from UTXOs
  WalletState recalculateBalances() {
    BigInt confirmed = BigInt.zero;
    BigInt unconfirmed = BigInt.zero;
    BigInt reserved = BigInt.zero;

    for (final utxo in utxos.values) {
      if (utxo.status == UTXOStatus.spent) continue;

      final amount = utxo.value.getValue();

      if (utxo.status == UTXOStatus.reserved) {
        reserved += amount;
      } else if (utxo.confirmations != null && utxo.confirmations! >= 6) {
        confirmed += amount;
      } else {
        unconfirmed += amount;
      }
    }

    return copyWithWallet(
      confirmedBalance: dartsv.Coin.ofSat(confirmed),
      unconfirmedBalance: dartsv.Coin.ofSat(unconfirmed),
      reservedBalance: dartsv.Coin.ofSat(reserved),
      lastModified: DateTime.now(),
    );
  }

  /// Convert state to map for serialization.
  ///
  /// Complete (every field [WalletState.fromMap] reads) and detached: nested
  /// maps and lists are plain modifiable copies, so a snapshot taken from the
  /// map shares nothing with the state (audit 2026-09-14 M6).
  @override
  Map<String, dynamic> toMap() {
    return {
      'walletId': walletId,
      'name': name,
      'rootAddress': rootAddress,
      'isCreated': isCreated,
      'isDeleted': isDeleted,
      'networkType': networkType,
      'walletType': walletType.toStorageString(),
      'version': version,
      'timestamp': timestamp.toIso8601String(),
      'utxos': <String, dynamic>{
        for (final entry in utxos.entries) entry.key: _deepCopy(entry.value.toMap()),
      },
      'addresses': Map<String, String?>.from(addresses),
      'watchAddresses': Map<String, String>.from(watchAddresses),
      'nextDerivationIndex': nextDerivationIndex,
      'metadata': _deepCopy(metadata),
      'confirmedBalance': confirmedBalance.getValue().toString(),
      'unconfirmedBalance': unconfirmedBalance.getValue().toString(),
      'reservedBalance': reservedBalance.getValue().toString(),
      'lastModified': lastModified.toIso8601String(),
    };
  }

  static dynamic _deepCopy(dynamic value) => switch (value) {
        Map m => <String, dynamic>{
            for (final e in m.entries) e.key.toString(): _deepCopy(e.value),
          },
        List l => [for (final v in l) _deepCopy(v)],
        _ => value,
      };

  static DateTime _parseDate(Object? value) =>
      value is DateTime ? value : DateTime.parse(value as String);

  /// Create state from map (deserialization). Accepts the output of
  /// [toMap] after a CBOR round trip (untyped nested maps).
  ///
  /// Metadata values keep the shape the round trip gives them (e.g.
  /// `Map<String, dynamic>` where the live state held `Map<String, int>`);
  /// [BitcoinWalletAggregate] normalises the entries it reads.
  factory WalletState.fromMap(Map<String, dynamic> map) {
    final utxosMap = <String, BitcoinUtxo>{};
    if (map['utxos'] != null) {
      final utxosData = map['utxos'] as Map;
      for (final entry in utxosData.entries) {
        utxosMap[entry.key.toString()] =
            BitcoinUtxo.fromMap(Map<String, dynamic>.from(entry.value as Map));
      }
    }

    return WalletState(
      walletId: map['walletId'] as String,
      name: map['name'] as String,
      rootAddress: map['rootAddress'] as String?,
      isCreated: map['isCreated'] as bool,
      isDeleted: map['isDeleted'] as bool? ?? false,
      networkType: map['networkType'] as String,
      walletType: WalletTypeExtension.fromStorageString(
        map['walletType'] as String? ?? 'hd', // Default to HD for backwards compatibility
      ),
      timestamp: _parseDate(map['timestamp']),
      utxos: utxosMap,
      addresses: Map<String, String?>.from(map['addresses'] ?? {}),
      // Absent from snapshots written before watch addresses were journaled.
      watchAddresses: {
        for (final e in (map['watchAddresses'] as Map? ?? const {}).entries) e.key.toString(): e.value.toString(),
      },
      nextDerivationIndex: map['nextDerivationIndex'] as int,
      metadata: Map<String, dynamic>.from(map['metadata'] ?? {}),
      confirmedBalance: dartsv.Coin.ofSat(BigInt.parse(map['confirmedBalance'] as String)),
      unconfirmedBalance: dartsv.Coin.ofSat(BigInt.parse(map['unconfirmedBalance'] as String)),
      reservedBalance: dartsv.Coin.ofSat(BigInt.parse(map['reservedBalance'] as String)),
      version: map['version'] as int,
      lastModified: map['lastModified'] != null ? _parseDate(map['lastModified']) : null,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is WalletState &&
        other.walletId == walletId &&
        other.version == version;
  }

  @override
  int get hashCode => walletId.hashCode ^ version.hashCode;

  @override
  String toString() {
    return 'WalletState(walletId: $walletId, name: $name, version: $version, '
        'isCreated: $isCreated, utxos: ${utxos.length}, balance: $balance sats)';
  }
}

/// A draft of a [WalletState] that [BitcoinWalletAggregate] fills in while it
/// applies one event, then turns into the next state with [build] (bead
/// libspiffy-mmb).
///
/// The draft starts from the state's own immutable collections; replacing
/// one (e.g. `utxos = utxos.put(key, utxo)`) never touches the state it came
/// from, and [build] shares every collection the event did not replace. The
/// state is replaced only when the whole event applied, so an event that
/// fails midway changes nothing. Values put into [metadata] must be frozen
/// ([freezeDeep]).
@internal
class WalletStateBuilder {
  final String walletId;
  String name;
  String? rootAddress;
  bool isCreated;
  bool isDeleted;
  String networkType;
  WalletType walletType;
  DateTime timestamp;
  PersistentMap<String, BitcoinUtxo> utxos;
  PersistentMap<String, String?> addresses;
  PersistentMap<String, String> watchAddresses;
  int nextDerivationIndex;
  PersistentMap<String, dynamic> metadata;
  dartsv.Coin confirmedBalance;
  dartsv.Coin unconfirmedBalance;
  dartsv.Coin reservedBalance;
  int version;
  DateTime lastModified;

  WalletStateBuilder._(WalletState state)
      : walletId = state.walletId,
        name = state.name,
        rootAddress = state.rootAddress,
        isCreated = state.isCreated,
        isDeleted = state.isDeleted,
        networkType = state.networkType,
        walletType = state.walletType,
        timestamp = state.timestamp,
        utxos = state.utxos,
        addresses = state.addresses,
        watchAddresses = state.watchAddresses,
        nextDerivationIndex = state.nextDerivationIndex,
        metadata = state.metadata,
        confirmedBalance = state.confirmedBalance,
        unconfirmedBalance = state.unconfirmedBalance,
        reservedBalance = state.reservedBalance,
        version = state.version,
        lastModified = state.lastModified;

  WalletState build() => WalletState(
        walletId: walletId,
        name: name,
        rootAddress: rootAddress,
        isCreated: isCreated,
        isDeleted: isDeleted,
        networkType: networkType,
        walletType: walletType,
        timestamp: timestamp,
        utxos: utxos,
        addresses: addresses,
        watchAddresses: watchAddresses,
        nextDerivationIndex: nextDerivationIndex,
        metadata: metadata,
        confirmedBalance: confirmedBalance,
        unconfirmedBalance: unconfirmedBalance,
        reservedBalance: reservedBalance,
        version: version,
        lastModified: lastModified,
      );
}
