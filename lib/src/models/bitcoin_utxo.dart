import 'package:dartsv/dartsv.dart' as dartsv;

/// Sentinel value for copyWith to distinguish between null and not provided
const _sentinel = Object();

/// Enumeration of UTXO statuses
enum UTXOStatus {
  /// UTXO is available for spending
  available,
  /// UTXO is reserved for a pending transaction
  reserved,
  /// UTXO has been spent
  spent,
}

/// Represents a Bitcoin UTXO (Unspent Transaction Output) in the wallet.
/// 
/// Based on the BitcoinUtxo model from speculative code, adapted for
/// the event-sourced wallet architecture with DartSV integration.
class BitcoinUtxo {
  /// Transaction ID that created this UTXO
  final String txid;
  
  /// Output index within the transaction
  final int vout;
  
  /// Amount in satoshis (using DartSV's Coin for precision)
  final dartsv.Coin value;
  
  /// Script that locks this UTXO
  final String scriptPubKey;
  
  /// Address that owns this UTXO
  final String address;
  
  /// Current status of this UTXO
  final UTXOStatus status;
  
  /// Block height where this UTXO was confirmed (null if unconfirmed)
  final int? blockHeight;
  
  /// Number of confirmations (null if unconfirmed)
  final int? confirmations;
  
  /// Timestamp when this UTXO was first detected
  final DateTime createdAt;
  
  /// Timestamp when this UTXO was last updated
  final DateTime updatedAt;
  
  /// Transaction ID that reserved this UTXO (if status is reserved)
  final String? reservedByTxId;
  
  /// Derivation index used to generate the address (for HD wallets)
  final int? derivationIndex;
  
  const BitcoinUtxo({
    required this.txid,
    required this.vout,
    required this.value,
    required this.scriptPubKey,
    required this.address,
    required this.status,
    this.blockHeight,
    this.confirmations,
    required this.createdAt,
    required this.updatedAt,
    this.reservedByTxId,
    this.derivationIndex,
  });
  
  /// Create a new UTXO from transaction output
  factory BitcoinUtxo.create({
    required String txid,
    required int vout,
    required BigInt satoshis,
    required String scriptPubKey,
    required String address,
    int? blockHeight,
    int? confirmations,
    int? derivationIndex,
  }) {
    final now = DateTime.now();
    return BitcoinUtxo(
      txid: txid,
      vout: vout,
      value: dartsv.Coin.ofSat(satoshis),
      scriptPubKey: scriptPubKey,
      address: address,
      status: UTXOStatus.available,
      blockHeight: blockHeight,
      confirmations: confirmations,
      createdAt: now,
      updatedAt: now,
      derivationIndex: derivationIndex,
    );
  }
  
  /// Unique key for this UTXO (txid:vout)
  String get key => '$txid:$vout';
  
  /// Amount in satoshis as BigInt
  BigInt get satoshis => value.getValue();
  
  /// Check if this UTXO is confirmed
  bool get isConfirmed => blockHeight != null && (confirmations ?? 0) > 0;
  
  /// Check if this UTXO is available for spending
  bool get isAvailable => status == UTXOStatus.available;
  
  /// Check if this UTXO is reserved
  bool get isReserved => status == UTXOStatus.reserved;
  
  /// Check if this UTXO is spent
  bool get isSpent => status == UTXOStatus.spent;
  
  /// Create a copy with updated fields
  BitcoinUtxo copyWith({
    String? txid,
    int? vout,
    dartsv.Coin? value,
    String? scriptPubKey,
    String? address,
    UTXOStatus? status,
    int? blockHeight,
    int? confirmations,
    DateTime? createdAt,
    DateTime? updatedAt,
    Object? reservedByTxId = _sentinel,
    int? derivationIndex,
  }) {
    return BitcoinUtxo(
      txid: txid ?? this.txid,
      vout: vout ?? this.vout,
      value: value ?? this.value,
      scriptPubKey: scriptPubKey ?? this.scriptPubKey,
      address: address ?? this.address,
      status: status ?? this.status,
      blockHeight: blockHeight ?? this.blockHeight,
      confirmations: confirmations ?? this.confirmations,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      reservedByTxId: reservedByTxId == _sentinel ? this.reservedByTxId : reservedByTxId as String?,
      derivationIndex: derivationIndex ?? this.derivationIndex,
    );
  }
  
  /// Reserve this UTXO for a transaction
  BitcoinUtxo reserve(String transactionId) {
    return copyWith(
      status: UTXOStatus.reserved,
      reservedByTxId: transactionId,
      updatedAt: DateTime.now(),
    );
  }
  
  /// Mark this UTXO as spent
  BitcoinUtxo markSpent() {
    return copyWith(
      status: UTXOStatus.spent,
      updatedAt: DateTime.now(),
    );
  }
  
  /// Release reservation on this UTXO
  BitcoinUtxo releaseReservation() {
    return copyWith(
      status: UTXOStatus.available,
      reservedByTxId: null,
      updatedAt: DateTime.now(),
    );
  }
  
  /// Update confirmation information
  BitcoinUtxo updateConfirmations({
    required int blockHeight,
    required int confirmations,
  }) {
    return copyWith(
      blockHeight: blockHeight,
      confirmations: confirmations,
      updatedAt: DateTime.now(),
    );
  }
  
  /// Convert to map for serialization
  Map<String, dynamic> toMap() {
    return {
      'txid': txid,
      'vout': vout,
      'satoshis': satoshis.toString(),
      'scriptPubKey': scriptPubKey,
      'address': address,
      'status': status.name,
      'blockHeight': blockHeight,
      'confirmations': confirmations,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
      'reservedByTxId': reservedByTxId,
      'derivationIndex': derivationIndex,
    };
  }
  
  /// Create from map (deserialization)
  factory BitcoinUtxo.fromMap(Map<String, dynamic> map) {
    return BitcoinUtxo(
      txid: map['txid'] as String,
      vout: map['vout'] as int,
      value: dartsv.Coin.ofSat(BigInt.parse(map['satoshis'] as String)),
      scriptPubKey: map['scriptPubKey'] as String,
      address: map['address'] as String,
      status: UTXOStatus.values.firstWhere(
        (s) => s.name == map['status'],
        orElse: () => UTXOStatus.available,
      ),
      blockHeight: map['blockHeight'] as int?,
      confirmations: map['confirmations'] as int?,
      createdAt: DateTime.parse(map['createdAt'] as String),
      updatedAt: DateTime.parse(map['updatedAt'] as String),
      reservedByTxId: map['reservedByTxId'] as String?,
      derivationIndex: map['derivationIndex'] as int?,
    );
  }
  
  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is BitcoinUtxo &&
        other.txid == txid &&
        other.vout == vout;
  }
  
  @override
  int get hashCode => txid.hashCode ^ vout.hashCode;
  
  @override
  String toString() {
    return 'BitcoinUtxo(key: $key, value: $satoshis sats, status: ${status.name}, '
        'address: $address, confirmations: $confirmations)';
  }
} 