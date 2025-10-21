import 'package:eventador/eventador.dart';
import '../actors/invoice_messages.dart';

/// Represents the current state of an invoice aggregate (write model)
/// 
/// This is the internal state of the InvoiceAggregate, rebuilt from events.
/// It's separate from InvoiceReadModel which is optimized for queries.
class InvoiceState extends State {
  final String invoiceId;
  
  // Mutable fields for eventHandler pattern
  bool isCreated;
  String walletId;
  List<String> addresses;
  BigInt amount;
  String? description;
  InvoiceStatus status;
  DateTime createdAt;
  DateTime? expiresAt;
  DateTime? paidAt;
  String? paymentTxid;
  BigInt? amountReceived;
  Map<String, dynamic> metadata;
  
  /// Override parent State version/lastModified with mutable fields
  @override
  int version;
  
  @override
  DateTime lastModified;
  
  InvoiceState({
    required this.invoiceId,
    required this.isCreated,
    required this.walletId,
    required this.addresses,
    required this.amount,
    this.description,
    required this.status,
    required this.createdAt,
    this.expiresAt,
    this.paidAt,
    this.paymentTxid,
    this.amountReceived,
    required this.metadata,
    this.version = 0,
    DateTime? lastModified,
  })  : lastModified = lastModified ?? DateTime.now(),
        super(version: version, lastModified: lastModified ?? DateTime.now());
  
  /// Create an empty invoice state (before creation)
  factory InvoiceState.empty(String invoiceId) {
    final now = DateTime.now();
    return InvoiceState(
      invoiceId: invoiceId,
      isCreated: false,
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
      metadata: {},
      version: 0,
      lastModified: now,
    );
  }
  
  /// Check if invoice is expired
  bool get isExpired {
    if (expiresAt == null) return false;
    return DateTime.now().isAfter(expiresAt!);
  }
  
  /// Check if invoice can be paid
  bool get canBePaid {
    return status == InvoiceStatus.pending && !isExpired;
  }
  
  /// Check if invoice can be cancelled
  bool get canBeCancelled {
    return status == InvoiceStatus.pending;
  }
  
  @override
  InvoiceState copyWith({int? version, DateTime? lastModified}) {
    return InvoiceState(
      invoiceId: invoiceId,
      isCreated: isCreated,
      walletId: walletId,
      addresses: addresses,
      amount: amount,
      description: description,
      status: status,
      createdAt: createdAt,
      expiresAt: expiresAt,
      paidAt: paidAt,
      paymentTxid: paymentTxid,
      amountReceived: amountReceived,
      metadata: metadata,
      version: version ?? this.version,
      lastModified: lastModified ?? this.lastModified,
    );
  }
}

