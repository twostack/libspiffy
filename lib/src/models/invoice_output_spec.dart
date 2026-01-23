import 'package:dartsv/dartsv.dart';

import 'bitcoin_transaction.dart';

/// Specification for a single invoice output (distinct UTXO)
/// Supports both P2PKH (address-based) and P2MS (multisig) outputs
sealed class InvoiceOutputSpec {
  /// Amount in satoshis for this output
  final BigInt amount;

  /// Human-readable label for this output (optional)
  final String? label;

  const InvoiceOutputSpec({
    required this.amount,
    this.label,
  });

  /// Get the script type for this output
  BitcoinScriptType get scriptType;

  /// Serialize to map for event storage
  Map<String, dynamic> toMap();

  /// Deserialize from map
  static InvoiceOutputSpec fromMap(Map<String, dynamic> map) {
    final type = map['type'] as String;
    return switch (type) {
      'p2pkh' => P2PKHOutputSpec.fromMap(map),
      'p2ms' => P2MSOutputSpec.fromMap(map),
      _ => throw ArgumentError('Unknown output type: $type'),
    };
  }
}

/// P2PKH (Pay-to-Public-Key-Hash) output specification
class P2PKHOutputSpec extends InvoiceOutputSpec {
  /// Bitcoin address for the output
  final String address;

  const P2PKHOutputSpec({
    required this.address,
    required super.amount,
    super.label,
  });

  @override
  BitcoinScriptType get scriptType => BitcoinScriptType.p2pkh;

  @override
  Map<String, dynamic> toMap() => {
        'type': 'p2pkh',
        'address': address,
        'amount': amount.toString(),
        if (label != null) 'label': label,
      };

  factory P2PKHOutputSpec.fromMap(Map<String, dynamic> map) => P2PKHOutputSpec(
        address: map['address'] as String,
        amount: BigInt.parse(map['amount'] as String),
        label: map['label'] as String?,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is P2PKHOutputSpec &&
          runtimeType == other.runtimeType &&
          address == other.address &&
          amount == other.amount &&
          label == other.label;

  @override
  int get hashCode => Object.hash(address, amount, label);

  @override
  String toString() =>
      'P2PKHOutputSpec(address: $address, amount: $amount, label: $label)';
}

/// P2MS (Pay-to-Multisig) output specification
class P2MSOutputSpec extends InvoiceOutputSpec {
  /// Public keys for the multisig (in hex format)
  final List<String> publicKeys;

  /// Number of required signatures (threshold)
  final int threshold;

  /// Total number of keys (n in m-of-n)
  int get totalKeys => publicKeys.length;

  const P2MSOutputSpec({
    required this.publicKeys,
    required this.threshold,
    required super.amount,
    super.label,
  });

  @override
  BitcoinScriptType get scriptType => BitcoinScriptType.p2ms;

  /// Validate the multisig configuration
  bool get isValid =>
      threshold > 0 &&
      threshold <= totalKeys &&
      totalKeys <= 16 && // Bitcoin script limit
      publicKeys.every((pk){
          try {
            SVPublicKey.fromHex(pk, strict: true);
          }catch(ex){
            return false;
          }
          return true;
      }); // Compressed or uncompressed

  @override
  Map<String, dynamic> toMap() => {
        'type': 'p2ms',
        'publicKeys': publicKeys,
        'threshold': threshold,
        'amount': amount.toString(),
        if (label != null) 'label': label,
      };

  factory P2MSOutputSpec.fromMap(Map<String, dynamic> map) => P2MSOutputSpec(
        publicKeys: List<String>.from(map['publicKeys']),
        threshold: map['threshold'] as int,
        amount: BigInt.parse(map['amount'] as String),
        label: map['label'] as String?,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is P2MSOutputSpec &&
          runtimeType == other.runtimeType &&
          _listEquals(publicKeys, other.publicKeys) &&
          threshold == other.threshold &&
          amount == other.amount &&
          label == other.label;

  @override
  int get hashCode => Object.hash(Object.hashAll(publicKeys), threshold, amount, label);

  @override
  String toString() =>
      'P2MSOutputSpec(threshold: $threshold, totalKeys: $totalKeys, amount: $amount, label: $label)';
}

bool _listEquals<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
