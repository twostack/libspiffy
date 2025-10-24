import '../storage/libspiffy_schemas.dart';

/// Domain model for address metadata
class AddressMetadata {
  final String address;
  final String scriptType;
  final String? derivationPath;
  final int? derivationIndex;
  final bool isChange;
  final String? label;
  final String purpose;
  final DateTime? firstUsedAt;
  final DateTime? lastUsedAt;
  final int usageCount;
  final BigInt balance;
  final DateTime createdAt;
  final bool isWatched;

  AddressMetadata({
    required this.address,
    required this.scriptType,
    this.derivationPath,
    this.derivationIndex,
    required this.isChange,
    this.label,
    required this.purpose,
    this.firstUsedAt,
    this.lastUsedAt,
    required this.usageCount,
    required this.balance,
    required this.createdAt,
    required this.isWatched,
  });

  /// Check if address has never been used
  bool get isUnused => usageCount == 0 && firstUsedAt == null;

  /// Check if address has been used multiple times (reused)
  bool get isReused => usageCount > 1;

  /// Create from AddressEntity
  factory AddressMetadata.fromEntity(AddressEntity entity) {
    return AddressMetadata(
      address: entity.address,
      scriptType: entity.scriptType,
      derivationPath: entity.derivationPath,
      derivationIndex: entity.derivationIndex,
      isChange: entity.isChange,
      label: entity.label,
      purpose: entity.purpose,
      firstUsedAt: entity.firstUsedAt,
      lastUsedAt: entity.lastUsedAt,
      usageCount: entity.usageCount,
      balance: BigInt.parse(entity.balance),
      createdAt: entity.createdAt,
      isWatched: entity.isWatched,
    );
  }

  /// Convert to AddressEntity
  AddressEntity toEntity(String walletId) {
    return AddressEntity()
      ..walletId = walletId
      ..address = address
      ..scriptType = scriptType
      ..derivationPath = derivationPath
      ..derivationIndex = derivationIndex
      ..isChange = isChange
      ..label = label
      ..purpose = purpose
      ..firstUsedAt = firstUsedAt
      ..lastUsedAt = lastUsedAt
      ..usageCount = usageCount
      ..balance = balance.toString()
      ..createdAt = createdAt
      ..isWatched = isWatched;
  }
}

