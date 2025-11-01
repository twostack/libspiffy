import 'package:dartsv/dartsv.dart' as dartsv;


enum BitcoinScriptType {
  /// Pay to Public Key Hash (standard address)
  p2pkh,

  /// Pay to Public Key
  p2pk,

  /// Pay to Multi-Signature
  p2ms,

  /// OP_RETURN (data carrier)
  opReturn,

  /// Pay to Script Hash
  p2sh,

  /// Custom script type
  custom,

  /// Unknown script type
  unknown
}

/// Represents the direction of a Bitcoin transaction
enum BitcoinTransactionDirection {
  incoming,
  outgoing,
  self,
  unknown;

  String toJson(){
    return name;
  }
}



/// Enumeration of transaction statuses
enum TransactionStatus {
  /// Transaction has been created but not yet signed
  created,
  /// Transaction has been signed but not yet broadcast
  signed,
  /// Transaction has been broadcast to the network
  broadcast,
  /// Transaction is pending confirmation (0 confirmations)
  pending,
  /// Transaction has been confirmed (1+ confirmations)
  confirmed,
  /// Transaction has failed or been rejected
  failed,
}

/// Represents a Bitcoin transaction in the wallet.
/// 
/// Based on the BitcoinTransaction model from speculative code, adapted for
/// the event-sourced wallet architecture with DartSV integration.
class BitcoinTransaction {
  /// Wallet ID this transaction belongs to (optional for backward compatibility)
  final String? walletId;
  
  /// Bitcoin transaction ID (hash)
  final String txid;
  
  /// Raw transaction hex data
  final String rawHex;
  
  /// Current status of this transaction
  final TransactionStatus status;
  
  /// Block height where this transaction was confirmed (null if unconfirmed)
  final int? blockHeight;
  
  /// Number of confirmations (null if unconfirmed)
  final int? confirmations;
  
  /// Total input value in satoshis
  final BigInt inputValue;
  
  /// Total output value in satoshis
  final BigInt outputValue;
  
  /// Transaction fee in satoshis
  final BigInt fee;
  
  /// Addresses that received funds in this transaction
  final List<String> receivingAddresses;
  
  /// Addresses that sent funds in this transaction
  final List<String> sendingAddresses;
  
  /// Net amount for this wallet (positive = received, negative = sent)
  final BigInt netAmount;
  
  /// Timestamp when this transaction was first created
  final DateTime createdAt;
  
  /// Timestamp when this transaction was last updated
  final DateTime updatedAt;
  
  /// Optional memo or label for this transaction
  final String? memo;
  
  /// Lock time for the transaction
  final int lockTime;
  
  /// Transaction version
  final int version;
  
  const BitcoinTransaction({
    this.walletId,
    required this.txid,
    required this.rawHex,
    required this.status,
    this.blockHeight,
    this.confirmations,
    required this.inputValue,
    required this.outputValue,
    required this.fee,
    required this.receivingAddresses,
    required this.sendingAddresses,
    required this.netAmount,
    required this.createdAt,
    required this.updatedAt,
    this.memo,
    required this.lockTime,
    required this.version,
  });
  
  /// Create a transaction from a DartSV Transaction object
  factory BitcoinTransaction.fromDartSvTransaction({
    String? walletId,
    required dartsv.Transaction transaction,
    required TransactionStatus status,
    required List<String> receivingAddresses,
    required List<String> sendingAddresses,
    required BigInt netAmount,
    int? blockHeight,
    int? confirmations,
    String? memo,
    BigInt? inputValue, // Must be provided since TransactionInput.satoshis is not available
  }) {
    final now = DateTime.now();
    
    // Calculate output value from transaction outputs (this works correctly)
    final outputValue = transaction.outputs
        .fold<BigInt>(BigInt.zero, (sum, output) => sum + output.satoshis);
    
    // Input value must be provided externally since TransactionInput doesn't expose satoshis
    final totalInputValue = inputValue ?? BigInt.zero;
    
    return BitcoinTransaction(
      walletId: walletId,
      txid: transaction.id,
      rawHex: transaction.serialize(),
      status: status,
      blockHeight: blockHeight,
      confirmations: confirmations,
      inputValue: totalInputValue,
      outputValue: outputValue,
      fee: totalInputValue - outputValue,
      receivingAddresses: List.from(receivingAddresses),
      sendingAddresses: List.from(sendingAddresses),
      netAmount: netAmount,
      createdAt: now,
      updatedAt: now,
      memo: memo,
      lockTime: transaction.nLockTime,
      version: transaction.version,
    );
  }
  
  /// Get total amount using DartSV's Coin class
  dartsv.Coin get inputCoin => dartsv.Coin.ofSat(inputValue);
  dartsv.Coin get outputCoin => dartsv.Coin.ofSat(outputValue);
  dartsv.Coin get feeCoin => dartsv.Coin.ofSat(fee);
  dartsv.Coin get netCoin => dartsv.Coin.ofSat(netAmount);
  
  /// Check if this transaction is confirmed
  bool get isConfirmed => status == TransactionStatus.confirmed && (confirmations ?? 0) > 0;
  
  /// Check if this transaction is pending
  bool get isPending => status == TransactionStatus.pending;
  
  /// Check if this transaction has failed
  bool get isFailed => status == TransactionStatus.failed;
  
  /// Check if this is an incoming transaction (net positive)
  bool get isIncoming => netAmount > BigInt.zero;
  
  /// Check if this is an outgoing transaction (net negative)
  bool get isOutgoing => netAmount < BigInt.zero;
  
  /// Create a copy with updated fields
  BitcoinTransaction copyWith({
    String? walletId,
    String? txid,
    String? rawHex,
    TransactionStatus? status,
    int? blockHeight,
    int? confirmations,
    BigInt? inputValue,
    BigInt? outputValue,
    BigInt? fee,
    List<String>? receivingAddresses,
    List<String>? sendingAddresses,
    BigInt? netAmount,
    DateTime? createdAt,
    DateTime? updatedAt,
    String? memo,
    int? lockTime,
    int? version,
  }) {
    return BitcoinTransaction(
      walletId: walletId ?? this.walletId,
      txid: txid ?? this.txid,
      rawHex: rawHex ?? this.rawHex,
      status: status ?? this.status,
      blockHeight: blockHeight ?? this.blockHeight,
      confirmations: confirmations ?? this.confirmations,
      inputValue: inputValue ?? this.inputValue,
      outputValue: outputValue ?? this.outputValue,
      fee: fee ?? this.fee,
      receivingAddresses: receivingAddresses ?? this.receivingAddresses,
      sendingAddresses: sendingAddresses ?? this.sendingAddresses,
      netAmount: netAmount ?? this.netAmount,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      memo: memo ?? this.memo,
      lockTime: lockTime ?? this.lockTime,
      version: version ?? this.version,
    );
  }
  
  /// Update confirmation information
  BitcoinTransaction updateConfirmations({
    required TransactionStatus status,
    required int blockHeight,
    required int confirmations,
  }) {
    return copyWith(
      status: status,
      blockHeight: blockHeight,
      confirmations: confirmations,
      updatedAt: DateTime.now(),
    );
  }
  
  /// Mark transaction as failed
  BitcoinTransaction markFailed() {
    return copyWith(
      status: TransactionStatus.failed,
      updatedAt: DateTime.now(),
    );
  }
  
  /// Convert to map for serialization
  Map<String, dynamic> toMap() {
    return {
      'walletId': walletId,
      'txid': txid,
      'rawHex': rawHex,
      'status': status.name,
      'blockHeight': blockHeight,
      'confirmations': confirmations,
      'inputValue': inputValue.toString(),
      'outputValue': outputValue.toString(),
      'fee': fee.toString(),
      'receivingAddresses': receivingAddresses,
      'sendingAddresses': sendingAddresses,
      'netAmount': netAmount.toString(),
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
      'memo': memo,
      'lockTime': lockTime,
      'version': version,
    };
  }
  
  /// Create from map (deserialization)
  factory BitcoinTransaction.fromMap(Map<String, dynamic> map) {
    return BitcoinTransaction(
      walletId: map['walletId'] as String?,
      txid: map['txid'] as String,
      rawHex: map['rawHex'] as String,
      status: TransactionStatus.values.firstWhere(
        (s) => s.name == map['status'],
        orElse: () => TransactionStatus.created,
      ),
      blockHeight: map['blockHeight'] as int?,
      confirmations: map['confirmations'] as int?,
      inputValue: BigInt.parse(map['inputValue'] as String),
      outputValue: BigInt.parse(map['outputValue'] as String),
      fee: BigInt.parse(map['fee'] as String),
      receivingAddresses: List<String>.from(map['receivingAddresses'] ?? []),
      sendingAddresses: List<String>.from(map['sendingAddresses'] ?? []),
      netAmount: BigInt.parse(map['netAmount'] as String),
      createdAt: DateTime.parse(map['createdAt'] as String),
      updatedAt: DateTime.parse(map['updatedAt'] as String),
      memo: map['memo'] as String?,
      lockTime: map['lockTime'] as int,
      version: map['version'] as int,
    );
  }
  
  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is BitcoinTransaction && other.txid == txid;
  }
  
  @override
  int get hashCode => txid.hashCode;
  
  @override
  String toString() {
    return 'BitcoinTransaction(txid: $txid, status: ${status.name}, '
        'net: ${netCoin.getValue()} sats, confirmations: $confirmations)';
  }
} 