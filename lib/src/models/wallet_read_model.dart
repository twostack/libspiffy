/// Read model for wallet queries - optimized for UI/query needs
/// 
/// This is separate from WalletState (the write model) and is built by
/// WalletProjection from the event stream. It's denormalized and optimized
/// for fast queries.
class WalletReadModel {
  final String walletId;
  final String name;
  final String? rootAddress;
  final String networkType;
  final DateTime createdAt;
  final DateTime lastUpdated;
  
  // Balance information (denormalized for fast access)
  final BigInt confirmedBalance;
  final BigInt unconfirmedBalance;
  final BigInt reservedBalance;
  final BigInt totalBalance;
  
  // Address count
  final int addressCount;
  
  // UTXO statistics
  final int utxoCount;
  final int availableUtxoCount;
  final int reservedUtxoCount;
  final int spentUtxoCount;
  
  // Metadata
  final Map<String, dynamic> metadata;
  
  WalletReadModel({
    required this.walletId,
    required this.name,
    this.rootAddress,
    required this.networkType,
    required this.createdAt,
    required this.lastUpdated,
    required this.confirmedBalance,
    required this.unconfirmedBalance,
    required this.reservedBalance,
    required this.totalBalance,
    required this.addressCount,
    required this.utxoCount,
    required this.availableUtxoCount,
    required this.reservedUtxoCount,
    required this.spentUtxoCount,
    required this.metadata,
  });
  
  /// Create an empty read model
  factory WalletReadModel.empty(String walletId) {
    final now = DateTime.now();
    return WalletReadModel(
      walletId: walletId,
      name: '',
      rootAddress: null,
      networkType: 'mainnet',
      createdAt: now,
      lastUpdated: now,
      confirmedBalance: BigInt.zero,
      unconfirmedBalance: BigInt.zero,
      reservedBalance: BigInt.zero,
      totalBalance: BigInt.zero,
      addressCount: 0,
      utxoCount: 0,
      availableUtxoCount: 0,
      reservedUtxoCount: 0,
      spentUtxoCount: 0,
      metadata: {},
    );
  }
  
  /// Create a copy with updated fields
  WalletReadModel copyWith({
    String? name,
    String? rootAddress,
    String? networkType,
    DateTime? createdAt,
    DateTime? lastUpdated,
    BigInt? confirmedBalance,
    BigInt? unconfirmedBalance,
    BigInt? reservedBalance,
    BigInt? totalBalance,
    int? addressCount,
    int? utxoCount,
    int? availableUtxoCount,
    int? reservedUtxoCount,
    int? spentUtxoCount,
    Map<String, dynamic>? metadata,
  }) {
    return WalletReadModel(
      walletId: walletId,
      name: name ?? this.name,
      rootAddress: rootAddress ?? this.rootAddress,
      networkType: networkType ?? this.networkType,
      createdAt: createdAt ?? this.createdAt,
      lastUpdated: lastUpdated ?? this.lastUpdated,
      confirmedBalance: confirmedBalance ?? this.confirmedBalance,
      unconfirmedBalance: unconfirmedBalance ?? this.unconfirmedBalance,
      reservedBalance: reservedBalance ?? this.reservedBalance,
      totalBalance: totalBalance ?? this.totalBalance,
      addressCount: addressCount ?? this.addressCount,
      utxoCount: utxoCount ?? this.utxoCount,
      availableUtxoCount: availableUtxoCount ?? this.availableUtxoCount,
      reservedUtxoCount: reservedUtxoCount ?? this.reservedUtxoCount,
      spentUtxoCount: spentUtxoCount ?? this.spentUtxoCount,
      metadata: metadata ?? this.metadata,
    );
  }
  
  /// Convert to map for storage
  Map<String, dynamic> toMap() {
    return {
      'walletId': walletId,
      'name': name,
      'rootAddress': rootAddress,
      'networkType': networkType,
      'createdAt': createdAt.toIso8601String(),
      'lastUpdated': lastUpdated.toIso8601String(),
      'confirmedBalance': confirmedBalance.toString(),
      'unconfirmedBalance': unconfirmedBalance.toString(),
      'reservedBalance': reservedBalance.toString(),
      'totalBalance': totalBalance.toString(),
      'addressCount': addressCount,
      'utxoCount': utxoCount,
      'availableUtxoCount': availableUtxoCount,
      'reservedUtxoCount': reservedUtxoCount,
      'spentUtxoCount': spentUtxoCount,
      'metadata': metadata,
    };
  }
  
  /// Create from map
  factory WalletReadModel.fromMap(Map<String, dynamic> map) {
    return WalletReadModel(
      walletId: map['walletId'] as String,
      name: map['name'] as String,
      rootAddress: map['rootAddress'] as String?,
      networkType: map['networkType'] as String,
      createdAt: DateTime.parse(map['createdAt'] as String),
      lastUpdated: DateTime.parse(map['lastUpdated'] as String),
      confirmedBalance: BigInt.parse(map['confirmedBalance'] as String),
      unconfirmedBalance: BigInt.parse(map['unconfirmedBalance'] as String),
      reservedBalance: BigInt.parse(map['reservedBalance'] as String),
      totalBalance: BigInt.parse(map['totalBalance'] as String),
      addressCount: map['addressCount'] as int,
      utxoCount: map['utxoCount'] as int,
      availableUtxoCount: map['availableUtxoCount'] as int,
      reservedUtxoCount: map['reservedUtxoCount'] as int,
      spentUtxoCount: map['spentUtxoCount'] as int,
      metadata: Map<String, dynamic>.from(map['metadata'] as Map),
    );
  }
}

