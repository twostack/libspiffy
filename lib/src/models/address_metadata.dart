import '../storage/libspiffy_schemas.dart';
import 'address_chain.dart';
import 'key_path.dart';

/// Domain model for address metadata
class AddressMetadata {
  final String address;
  final String scriptType;
  final String? derivationPath;
  final int? derivationIndex;

  /// The chain the address is on: its key is at m/{chain}/{derivationIndex}.
  /// Null for a type-42 address, which is not on the HD tree ([type42]).
  final AddressChain? chain;

  /// The type-42 derivation of an address a payer derived from the wallet's
  /// anchor key (bead libspiffy-zxkd); null for every other address.
  final Type42Derivation? type42;
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
    required this.chain,
    this.type42,
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

  /// Where the wallet's key for this address comes from; null for a watch
  /// address, which the wallet holds no key for.
  KeyPath? get keyPath {
    if (purpose == 'watch') return null;
    if (type42 case final derivation?) return Type42KeyPath(derivation);
    return HdKeyPath(derivationIndex ?? 0, chain: chain ?? AddressChain.receive);
  }

  /// Create from AddressEntity
  factory AddressMetadata.fromEntity(AddressEntity entity) {
    return AddressMetadata(
      address: entity.address,
      scriptType: entity.scriptType,
      derivationPath: entity.derivationPath,
      derivationIndex: entity.derivationIndex,
      chain: entity.type42SenderPublicKey != null
          ? null
          : AddressChain.fromRecord(chain: entity.chain, isChange: entity.isChange),
      type42: Type42Derivation.fromMap(
          {'senderPublicKey': entity.type42SenderPublicKey, 'invoiceNumber': entity.type42InvoiceNumber}),
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
      ..chain = chain?.index
      ..isChange = chain == AddressChain.change
      ..type42SenderPublicKey = type42?.senderPublicKey
      ..type42InvoiceNumber = type42?.invoiceNumber
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

