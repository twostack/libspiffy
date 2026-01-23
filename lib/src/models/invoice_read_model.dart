import '../actors/invoice_messages.dart';
import 'invoice_output_spec.dart';

/// Read model for invoice queries - optimized for UI/query needs
/// 
/// This is separate from InvoiceState (the write model) and is built by
/// InvoiceProjection from the event stream. It's denormalized and optimized
/// for fast queries.
class InvoiceReadModel {
  final String invoiceId;
  final String walletId;
  final List<String> addresses;
  final BigInt amount;

  /// Structured output specifications (P2PKH, P2MS, etc.)
  /// When present, this takes precedence over addresses/amount for payment construction
  final List<InvoiceOutputSpec>? outputs;

  final String? description;
  final InvoiceStatus status;
  final DateTime createdAt;
  final DateTime? expiresAt;
  final DateTime? paidAt;
  final String? paymentTxid;
  final BigInt? amountReceived;
  final DateTime lastUpdated;
  final Map<String, dynamic> metadata;
  
  InvoiceReadModel({
    required this.invoiceId,
    required this.walletId,
    required this.addresses,
    required this.amount,
    this.outputs,
    this.description,
    required this.status,
    required this.createdAt,
    this.expiresAt,
    this.paidAt,
    this.paymentTxid,
    this.amountReceived,
    required this.lastUpdated,
    required this.metadata,
  });

  /// Get total amount from outputs or fallback to amount field
  BigInt get totalAmount =>
      outputs?.fold<BigInt>(BigInt.zero, (sum, o) => sum + o.amount) ?? amount;

  /// Get all P2PKH addresses from outputs or fallback to addresses field
  List<String> get allAddresses =>
      outputs
          ?.whereType<P2PKHOutputSpec>()
          .map((o) => o.address)
          .toList() ??
      addresses;
  
  /// Create an empty read model
  factory InvoiceReadModel.empty(String invoiceId) {
    final now = DateTime.now();
    return InvoiceReadModel(
      invoiceId: invoiceId,
      walletId: '',
      addresses: [],
      amount: BigInt.zero,
      description: null,
      status: InvoiceStatus.pending,
      createdAt: now,
      expiresAt: null,
      paidAt: null,
      paymentTxid: null,
      amountReceived: null,
      lastUpdated: now,
      metadata: {},
    );
  }
  
  /// Create a copy with updated fields
  InvoiceReadModel copyWith({
    String? walletId,
    List<String>? addresses,
    BigInt? amount,
    List<InvoiceOutputSpec>? outputs,
    String? description,
    InvoiceStatus? status,
    DateTime? createdAt,
    DateTime? expiresAt,
    DateTime? paidAt,
    String? paymentTxid,
    BigInt? amountReceived,
    DateTime? lastUpdated,
    Map<String, dynamic>? metadata,
  }) {
    return InvoiceReadModel(
      invoiceId: invoiceId,
      walletId: walletId ?? this.walletId,
      addresses: addresses ?? this.addresses,
      amount: amount ?? this.amount,
      outputs: outputs ?? this.outputs,
      description: description ?? this.description,
      status: status ?? this.status,
      createdAt: createdAt ?? this.createdAt,
      expiresAt: expiresAt ?? this.expiresAt,
      paidAt: paidAt ?? this.paidAt,
      paymentTxid: paymentTxid ?? this.paymentTxid,
      amountReceived: amountReceived ?? this.amountReceived,
      lastUpdated: lastUpdated ?? this.lastUpdated,
      metadata: metadata ?? this.metadata,
    );
  }
  
  /// Check if invoice is expired
  bool get isExpired {
    if (expiresAt == null) return false;
    return DateTime.now().isAfter(expiresAt!);
  }
  
  /// Convert to map for storage
  Map<String, dynamic> toMap() {
    return {
      'invoiceId': invoiceId,
      'walletId': walletId,
      'addresses': addresses,
      'amount': amount.toString(),
      if (outputs != null) 'outputs': outputs!.map((o) => o.toMap()).toList(),
      'description': description,
      'status': status.name,
      'createdAt': createdAt.toIso8601String(),
      'expiresAt': expiresAt?.toIso8601String(),
      'paidAt': paidAt?.toIso8601String(),
      'paymentTxid': paymentTxid,
      'amountReceived': amountReceived?.toString(),
      'lastUpdated': lastUpdated.toIso8601String(),
      'metadata': metadata,
    };
  }
  
  /// Create from map
  factory InvoiceReadModel.fromMap(Map<String, dynamic> map) {
    return InvoiceReadModel(
      invoiceId: map['invoiceId'] as String,
      walletId: map['walletId'] as String,
      addresses: List<String>.from(map['addresses'] as List),
      amount: BigInt.parse(map['amount'] as String),
      outputs: map['outputs'] != null
          ? (map['outputs'] as List)
              .map((o) => InvoiceOutputSpec.fromMap(o as Map<String, dynamic>))
              .toList()
          : null,
      description: map['description'] as String?,
      status: InvoiceStatus.values.firstWhere(
        (s) => s.name == map['status'],
      ),
      createdAt: DateTime.parse(map['createdAt'] as String),
      expiresAt: map['expiresAt'] != null
          ? DateTime.parse(map['expiresAt'] as String)
          : null,
      paidAt: map['paidAt'] != null ? DateTime.parse(map['paidAt'] as String) : null,
      paymentTxid: map['paymentTxid'] as String?,
      amountReceived: map['amountReceived'] != null
          ? BigInt.parse(map['amountReceived'] as String)
          : null,
      lastUpdated: DateTime.parse(map['lastUpdated'] as String),
      metadata: Map<String, dynamic>.from(map['metadata'] as Map),
    );
  }
}

