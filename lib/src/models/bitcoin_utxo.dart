import 'package:dartsv/dartsv.dart' as dartsv;

/// Sentinel value for copyWith to distinguish between null and not provided
const _sentinel = Object();

/// Enumeration of UTXO statuses
enum UTXOStatus {
  /// UTXO is pending network confirmation (not yet spendable)
  pending,
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
  
  /// When the reservation expires (if status is reserved)
  final DateTime? reservationExpiresAt;
  
  /// Priority of the reservation (higher numbers = higher priority)
  final int? reservationPriority;
  
  /// Reason for the reservation (if status is reserved)
  final String? reservationReason;
  
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
    this.reservationExpiresAt,
    this.reservationPriority,
    this.reservationReason,
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
    UTXOStatus status = UTXOStatus.pending,
  }) {
    final now = DateTime.now();
    return BitcoinUtxo(
      txid: txid,
      vout: vout,
      value: dartsv.Coin.ofSat(satoshis),
      scriptPubKey: scriptPubKey,
      address: address,
      status: status,
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
    Object? reservationExpiresAt = _sentinel,
    Object? reservationPriority = _sentinel,
    Object? reservationReason = _sentinel,
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
      reservationExpiresAt: reservationExpiresAt == _sentinel ? this.reservationExpiresAt : reservationExpiresAt as DateTime?,
      reservationPriority: reservationPriority == _sentinel ? this.reservationPriority : reservationPriority as int?,
      reservationReason: reservationReason == _sentinel ? this.reservationReason : reservationReason as String?,
      derivationIndex: derivationIndex ?? this.derivationIndex,
    );
  }
  
  /// Reserve this UTXO for a transaction
  BitcoinUtxo reserve(String transactionId, {
    Duration? duration,
    int priority = 0,
    String? reason,
  }) {
    final expiresAt = duration != null 
        ? DateTime.now().add(duration)
        : null;
    
    return copyWith(
      status: UTXOStatus.reserved,
      reservedByTxId: transactionId,
      reservationExpiresAt: expiresAt,
      reservationPriority: priority,
      reservationReason: reason,
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
  
  /// Mark this UTXO as available for spending
  BitcoinUtxo markAvailable() {
    return copyWith(
      status: UTXOStatus.available,
      updatedAt: DateTime.now(),
    );
  }
  
  /// Release reservation on this UTXO
  BitcoinUtxo releaseReservation() {
    return copyWith(
      status: UTXOStatus.available,
      reservedByTxId: null,
      reservationExpiresAt: null,
      reservationPriority: null,
      reservationReason: null,
      updatedAt: DateTime.now(),
    );
  }

  /// Renew/extend the reservation on this UTXO
  BitcoinUtxo renewReservation(Duration extension, {String? reason}) {
    if (status != UTXOStatus.reserved) {
      throw StateError('Cannot renew reservation on non-reserved UTXO');
    }
    
    final currentExpiry = reservationExpiresAt ?? DateTime.now();
    final newExpiry = currentExpiry.add(extension);
    
    return copyWith(
      reservationExpiresAt: newExpiry,
      reservationReason: reason ?? reservationReason,
      updatedAt: DateTime.now(),
    );
  }

  /// Check if this UTXO's reservation has expired
  bool get isReservationExpired {
    if (status != UTXOStatus.reserved || reservationExpiresAt == null) {
      return false;
    }
    return DateTime.now().isAfter(reservationExpiresAt!);
  }

  /// Check if this UTXO is effectively available (either truly available or reservation expired)
  bool get isEffectivelyAvailable {
    return status == UTXOStatus.available || 
           (status == UTXOStatus.reserved && isReservationExpired);
  }

  /// Get time remaining on reservation (null if not reserved or no expiry)
  Duration? get reservationTimeRemaining {
    if (status != UTXOStatus.reserved || reservationExpiresAt == null) {
      return null;
    }
    final remaining = reservationExpiresAt!.difference(DateTime.now());
    return remaining.isNegative ? Duration.zero : remaining;
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