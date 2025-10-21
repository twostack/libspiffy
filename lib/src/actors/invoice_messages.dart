import 'package:dactor/dactor.dart';

/// Messages for invoice/payment request management

/// Status of an invoice
enum InvoiceStatus {
  pending,
  paid,
  expired,
  cancelled,
}

/// Invoice data class for storage
class Invoice {
  final String invoiceId;
  final String walletId;
  final List<String> addresses;
  final BigInt amount;
  final String? description;
  final InvoiceStatus status;
  final DateTime createdAt;
  final DateTime? expiresAt;
  final DateTime? paidAt;
  final String? paymentTxid;
  final BigInt? amountReceived;
  final Map<String, dynamic>? metadata;
  
  Invoice({
    required this.invoiceId,
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
    this.metadata,
  });
  
  Map<String, dynamic> toMap() {
    return {
      'invoiceId': invoiceId,
      'walletId': walletId,
      'addresses': addresses,
      'amount': amount.toString(),
      'description': description,
      'status': status,
      'createdAt': createdAt.toIso8601String(),
      'expiresAt': expiresAt?.toIso8601String(),
      'paidAt': paidAt?.toIso8601String(),
      'paymentTxid': paymentTxid,
      'amountReceived': amountReceived?.toString(),
      'metadata': metadata,
    };
  }
}

/// Request to create a new invoice/payment request
class CreateInvoiceMessage implements Message {
  final String walletId;
  final BigInt amount;
  final String? description;
  final Duration? expiresIn;
  final Map<String, dynamic>? invoiceMetadata;
  final int numberOfAddresses; // How many addresses to generate for this invoice

  CreateInvoiceMessage({
    required this.walletId,
    required this.amount,
    this.description,
    this.expiresIn = const Duration(hours: 24),
    this.invoiceMetadata,
    this.numberOfAddresses = 1,
  });

  @override
  String get correlationId => 'create-invoice-$walletId-${DateTime.now().millisecondsSinceEpoch}';
  
  @override
  Map<String, dynamic> get metadata => invoiceMetadata ?? {};
  
  @override
  ActorRef? get replyTo => null;
  
  @override
  DateTime get timestamp => DateTime.now();
}

/// Response when an invoice is successfully created
class InvoiceCreatedMessage implements Message {
  final String invoiceId;
  final String walletId;
  final List<String> addresses; // Addresses to pay to
  final BigInt amount;
  final String? description;
  final DateTime createdAt;
  final DateTime? expiresAt;
  final bool success;
  final String? error;

  InvoiceCreatedMessage({
    required this.invoiceId,
    required this.walletId,
    required this.addresses,
    required this.amount,
    this.description,
    required this.createdAt,
    this.expiresAt,
    required this.success,
    this.error,
  });

  @override
  String get correlationId => 'invoice-created-$invoiceId';
  
  @override
  Map<String, dynamic> get metadata => {'invoiceId': invoiceId, 'walletId': walletId};
  
  @override
  ActorRef? get replyTo => null;
  
  @override
  DateTime get timestamp => createdAt;
}

/// Request to check/lookup invoice details
class CheckInvoiceMessage implements Message {
  final String invoiceId;

  CheckInvoiceMessage(this.invoiceId);

  @override
  String get correlationId => 'check-invoice-$invoiceId';
  
  @override
  Map<String, dynamic> get metadata => {'invoiceId': invoiceId};
  
  @override
  ActorRef? get replyTo => null;
  
  @override
  DateTime get timestamp => DateTime.now();
}

/// Response with invoice details
class InvoiceDetailsResponse implements Message {
  final String invoiceId;
  final String? walletId;
  final List<String> addresses;
  final BigInt amount;
  final String? description;
  final InvoiceStatus status;
  final DateTime createdAt;
  final DateTime? expiresAt;
  final DateTime? paidAt;
  final String? paymentTxid;
  final bool found;
  final String? error;

  InvoiceDetailsResponse({
    required this.invoiceId,
    this.walletId,
    this.addresses = const [],
    required this.amount,
    this.description,
    required this.status,
    required this.createdAt,
    this.expiresAt,
    this.paidAt,
    this.paymentTxid,
    required this.found,
    this.error,
  });

  @override
  String get correlationId => 'invoice-details-$invoiceId';
  
  @override
  Map<String, dynamic> get metadata => {'invoiceId': invoiceId};
  
  @override
  ActorRef? get replyTo => null;
  
  @override
  DateTime get timestamp => DateTime.now();
}

/// Mark an invoice as paid
class MarkInvoicePaidMessage implements Message {
  final String invoiceId;
  final String txid;
  final BigInt amountReceived;
  final List<String> addressesPaidTo; // Which addresses received payment
  final DateTime paidAt;

  MarkInvoicePaidMessage({
    required this.invoiceId,
    required this.txid,
    required this.amountReceived,
    required this.addressesPaidTo,
    DateTime? paidAt,
  }) : paidAt = paidAt ?? DateTime.now();

  @override
  String get correlationId => 'mark-invoice-paid-$invoiceId';
  
  @override
  Map<String, dynamic> get metadata => {'invoiceId': invoiceId, 'txid': txid};
  
  @override
  ActorRef? get replyTo => null;
  
  @override
  DateTime get timestamp => paidAt;
}

/// Invoice status update notification
class InvoiceStatusMessage implements Message {
  final String invoiceId;
  final InvoiceStatus status;
  final DateTime? paidAt;
  final String? txid;
  final String? statusMessage;

  InvoiceStatusMessage({
    required this.invoiceId,
    required this.status,
    this.paidAt,
    this.txid,
    this.statusMessage,
  });

  @override
  String get correlationId => 'invoice-status-$invoiceId';
  
  @override
  Map<String, dynamic> get metadata => {'invoiceId': invoiceId, 'status': status.toString()};
  
  @override
  ActorRef? get replyTo => null;
  
  @override
  DateTime get timestamp => DateTime.now();
}

/// Cancel an invoice
class CancelInvoiceMessage implements Message {
  final String invoiceId;
  final String? reason;

  CancelInvoiceMessage({
    required this.invoiceId,
    this.reason,
  });

  @override
  String get correlationId => 'cancel-invoice-$invoiceId';
  
  @override
  Map<String, dynamic> get metadata => {'invoiceId': invoiceId};
  
  @override
  ActorRef? get replyTo => null;
  
  @override
  DateTime get timestamp => DateTime.now();
}

/// List all invoices for a wallet
class ListInvoicesMessage implements Message {
  final String? walletId; // null = all invoices
  final InvoiceStatus? filterStatus; // null = all statuses

  ListInvoicesMessage({
    this.walletId,
    this.filterStatus,
  });

  @override
  String get correlationId => 'list-invoices-${walletId ?? "all"}-${DateTime.now().millisecondsSinceEpoch}';
  
  @override
  Map<String, dynamic> get metadata => {};
  
  @override
  ActorRef? get replyTo => null;
  
  @override
  DateTime get timestamp => DateTime.now();
}

/// Response with list of invoices
class InvoicesListMessage implements Message {
  final List<InvoiceDetailsResponse> invoices;

  InvoicesListMessage(this.invoices);

  @override
  String get correlationId => 'invoices-list-${DateTime.now().millisecondsSinceEpoch}';
  
  @override
  Map<String, dynamic> get metadata => {'count': invoices.length};
  
  @override
  ActorRef? get replyTo => null;
  
  @override
  DateTime get timestamp => DateTime.now();
}

