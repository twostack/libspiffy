import 'package:convert/convert.dart';
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
      'op_return' => OPReturnOutputSpec.fromMap(map),
      'plugin' => PluginOutputSpec.fromMap(map),
      _ => throw ArgumentError('Unknown output type: $type'),
    };
  }
}

/// Plugin-delegated output specification.
///
/// Represents an output whose locking script is built by a registered
/// [ScriptPlugin]. This allows external token/script libraries to
/// participate in libspiffy's payment flow without compile-time coupling.
class PluginOutputSpec extends InvoiceOutputSpec {
  /// ID of the registered plugin that handles this output.
  final String pluginId;

  /// Script type identifier within the plugin (e.g., 'pp1_nft', 'pp1_ft').
  final String pluginScriptType;

  /// Plugin-specific parameters for building the locking script
  /// (e.g., tokenId, ownerPKH, recipientAddress).
  final Map<String, dynamic> params;

  const PluginOutputSpec({
    required this.pluginId,
    required this.pluginScriptType,
    required this.params,
    required super.amount,
    super.label,
  });

  @override
  BitcoinScriptType get scriptType => BitcoinScriptType.custom;

  @override
  Map<String, dynamic> toMap() => {
        'type': 'plugin',
        'pluginId': pluginId,
        'pluginScriptType': pluginScriptType,
        'params': params,
        'amount': amount.toString(),
        if (label != null) 'label': label,
      };

  factory PluginOutputSpec.fromMap(Map<String, dynamic> map) =>
      PluginOutputSpec(
        pluginId: map['pluginId'] as String,
        pluginScriptType: map['pluginScriptType'] as String,
        params: Map<String, dynamic>.from(map['params'] as Map),
        amount: BigInt.parse(map['amount'] as String),
        label: map['label'] as String?,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PluginOutputSpec &&
          runtimeType == other.runtimeType &&
          pluginId == other.pluginId &&
          pluginScriptType == other.pluginScriptType &&
          amount == other.amount &&
          label == other.label;

  @override
  int get hashCode => Object.hash(pluginId, pluginScriptType, amount, label);

  @override
  String toString() =>
      'PluginOutputSpec(pluginId: $pluginId, pluginScriptType: $pluginScriptType, amount: $amount, label: $label)';
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

/// OP_RETURN (data carrier) output specification
/// OP_RETURN outputs are unspendable and carry arbitrary data on-chain
class OPReturnOutputSpec extends InvoiceOutputSpec {
  /// Data chunks to embed in the OP_RETURN output.
  /// Each chunk becomes a separate data push in the script:
  /// OP_FALSE OP_RETURN <chunk1> <chunk2> ...
  final List<List<int>> dataChunks;

  /// When true, each data chunk becomes its own separate transaction output
  /// (one OP_RETURN output per chunk). When false (default), all chunks are
  /// concatenated into a single OP_RETURN output.
  final bool separateOutputs;

  /// Maximum total data size (100KB script limit minus overhead)
  static const int maxTotalDataSize = 99000;

  OPReturnOutputSpec({
    required this.dataChunks,
    this.separateOutputs = false,
    super.label,
  }) : super(amount: BigInt.zero);

  @override
  BitcoinScriptType get scriptType => BitcoinScriptType.opReturn;

  /// Validate the OP_RETURN configuration
  bool get isValid {
    if (dataChunks.isEmpty) return false;
    final totalSize = dataChunks.fold<int>(0, (sum, chunk) => sum + chunk.length);
    return totalSize > 0 && totalSize <= maxTotalDataSize;
  }

  @override
  Map<String, dynamic> toMap() => {
        'type': 'op_return',
        'dataChunks': dataChunks.map((chunk) => hex.encode(chunk)).toList(),
        if (separateOutputs) 'separateOutputs': true,
        if (label != null) 'label': label,
      };

  factory OPReturnOutputSpec.fromMap(Map<String, dynamic> map) =>
      OPReturnOutputSpec(
        dataChunks: (map['dataChunks'] as List)
            .map<List<int>>((chunk) => hex.decode(chunk as String))
            .toList(),
        separateOutputs: map['separateOutputs'] as bool? ?? false,
        label: map['label'] as String?,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is OPReturnOutputSpec &&
          runtimeType == other.runtimeType &&
          _deepListEquals(dataChunks, other.dataChunks) &&
          separateOutputs == other.separateOutputs &&
          label == other.label;

  @override
  int get hashCode => Object.hash(
        Object.hashAll(dataChunks.map((c) => Object.hashAll(c))),
        separateOutputs,
        label,
      );

  @override
  String toString() {
    final totalSize = dataChunks.fold<int>(0, (sum, c) => sum + c.length);
    return 'OPReturnOutputSpec(chunks: ${dataChunks.length}, totalBytes: $totalSize, separateOutputs: $separateOutputs, label: $label)';
  }
}

bool _deepListEquals(List<List<int>> a, List<List<int>> b) {
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if (!_listEquals(a[i], b[i])) return false;
  }
  return true;
}

bool _listEquals<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
