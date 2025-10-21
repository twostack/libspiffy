import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:eventador/eventador.dart';
import 'bitcoin_utxo.dart';

/// Represents the current state of a wallet at a specific point in time.
/// 
/// This class is used for event sourcing and represents the complete
/// wallet state derived from applying a sequence of wallet events via eventHandler.
/// 
/// NOTE: Fields are mutable to allow direct state updates in eventHandler.
/// This is the write model - projections create separate read models for queries.
class WalletState extends State {
  /// Unique identifier for this wallet
  final String walletId;
  
  /// Human-readable name for the wallet
  String name;
  
  /// Root address derived from the wallet's mnemonic
  String? rootAddress;
  
  /// Whether the wallet has been created (initialized)
  bool isCreated;
  
  /// Network type (mainnet, testnet)
  String networkType;
  
  /// Timestamp when this state was created
  DateTime timestamp;
  
  /// All UTXOs currently tracked by this wallet (mutable map)
  final Map<String, BitcoinUtxo> utxos;
  
  /// Generated addresses for this wallet (mutable map: address -> label)
  final Map<String, String?> addresses;
  
  /// Next address derivation index
  int nextDerivationIndex;
  
  /// Additional wallet metadata (mutable map)
  final Map<String, dynamic> metadata;
  
  /// Cached balance calculations
  dartsv.Coin confirmedBalance;
  dartsv.Coin unconfirmedBalance;
  dartsv.Coin reservedBalance;
  
  /// Override parent State version/lastModified with mutable fields
  @override
  int version;
  
  @override
  DateTime lastModified;
  
  WalletState({
    required this.walletId,
    required this.name,
    this.rootAddress,
    required this.isCreated,
    required this.networkType,
    required this.timestamp,
    required this.utxos,
    required this.addresses,
    required this.nextDerivationIndex,
    required this.metadata,
    required this.confirmedBalance,
    required this.unconfirmedBalance,
    required this.reservedBalance,
    this.version = 0,
    DateTime? lastModified,
  }) : lastModified = lastModified ?? DateTime.now(),
       super(version: version, lastModified: lastModified ?? DateTime.now());
  
  /// Create an empty wallet state (before wallet creation)
  factory WalletState.empty(String walletId) {
    final now = DateTime.now();
    return WalletState(
      walletId: walletId,
      name: '',
      rootAddress: null,
      isCreated: false,
      networkType: 'mainnet',
      timestamp: now,
      utxos: {},
      addresses: {},
      nextDerivationIndex: 0,
      metadata: {},
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
  }) {
    final now = DateTime.now();
    return WalletState(
      walletId: walletId,
      name: name,
      rootAddress: rootAddress,
      isCreated: true,
      networkType: networkType,
      timestamp: now,
      utxos: {},
      addresses: {},
      nextDerivationIndex: 0,
      metadata: {},
      confirmedBalance: dartsv.Coin.ofSat(BigInt.zero),
      unconfirmedBalance: dartsv.Coin.ofSat(BigInt.zero),
      reservedBalance: dartsv.Coin.ofSat(BigInt.zero),
      version: 1,
      lastModified: now,
    );
  }
  
  /// Override the base State copyWith method (only version and lastModified)
  @override
  WalletState copyWith({
    int? version,
    DateTime? lastModified,
  }) {
    return WalletState(
      walletId: walletId,
      name: name,
      rootAddress: rootAddress,
      isCreated: isCreated,
      networkType: networkType,
      timestamp: timestamp,
      utxos: utxos,
      addresses: addresses,
      nextDerivationIndex: nextDerivationIndex,
      metadata: metadata,
      confirmedBalance: confirmedBalance,
      unconfirmedBalance: unconfirmedBalance,
      reservedBalance: reservedBalance,
      version: version ?? this.version,
      lastModified: lastModified ?? this.lastModified,
    );
  }
  
  /// Create a copy of this state with updated wallet-specific fields
  WalletState copyWithWallet({
    String? walletId,
    String? name,
    String? rootAddress,
    bool? isCreated,
    String? networkType,
    DateTime? timestamp,
    Map<String, BitcoinUtxo>? utxos,
    Map<String, String?>? addresses,
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
      networkType: networkType ?? this.networkType,
      timestamp: timestamp ?? this.timestamp,
      utxos: utxos ?? this.utxos,
      addresses: addresses ?? this.addresses,
      nextDerivationIndex: nextDerivationIndex ?? this.nextDerivationIndex,
      metadata: metadata ?? this.metadata,
      confirmedBalance: confirmedBalance ?? this.confirmedBalance,
      unconfirmedBalance: unconfirmedBalance ?? this.unconfirmedBalance,
      reservedBalance: reservedBalance ?? this.reservedBalance,
      version: version ?? this.version,
      lastModified: lastModified ?? this.lastModified,
    );
  }
  
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
  
  /// Convert state to map for serialization
  Map<String, dynamic> toMap() {
    return {
      'walletId': walletId,
      'name': name,
      'rootAddress': rootAddress,
      'isCreated': isCreated,
      'networkType': networkType,
      'version': version,
      'timestamp': timestamp.toIso8601String(),
      'utxos': utxos.map((key, utxo) => MapEntry(key, utxo.toMap())),
      'addresses': addresses,
      'nextDerivationIndex': nextDerivationIndex,
      'metadata': metadata,
      'confirmedBalance': confirmedBalance.getValue().toString(),
      'unconfirmedBalance': unconfirmedBalance.getValue().toString(),
      'reservedBalance': reservedBalance.getValue().toString(),
      'lastModified': lastModified.toIso8601String(),
    };
  }
  
  /// Create state from map (deserialization)
  factory WalletState.fromMap(Map<String, dynamic> map) {
    final utxosMap = <String, BitcoinUtxo>{};
    if (map['utxos'] != null) {
      final utxosData = map['utxos'] as Map<String, dynamic>;
      for (final entry in utxosData.entries) {
        utxosMap[entry.key] = BitcoinUtxo.fromMap(entry.value as Map<String, dynamic>);
      }
    }
    
    return WalletState(
      walletId: map['walletId'] as String,
      name: map['name'] as String,
      rootAddress: map['rootAddress'] as String?,
      isCreated: map['isCreated'] as bool,
      networkType: map['networkType'] as String,
      timestamp: DateTime.parse(map['timestamp'] as String),
      utxos: utxosMap,
      addresses: Map<String, String?>.from(map['addresses'] ?? {}),
      nextDerivationIndex: map['nextDerivationIndex'] as int,
      metadata: Map<String, dynamic>.from(map['metadata'] ?? {}),
      confirmedBalance: dartsv.Coin.ofSat(BigInt.parse(map['confirmedBalance'] as String)),
      unconfirmedBalance: dartsv.Coin.ofSat(BigInt.parse(map['unconfirmedBalance'] as String)),
      reservedBalance: dartsv.Coin.ofSat(BigInt.parse(map['reservedBalance'] as String)),
      version: map['version'] as int,
      lastModified: map['lastModified'] != null 
          ? DateTime.parse(map['lastModified'] as String)
          : null,
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