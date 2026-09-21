import 'package:dactor/dactor.dart';
import 'internal_messages.dart';
import '../models/invoice_output_spec.dart';
import '../models/persistent_map.dart';

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

  /// Structured output specifications (P2PKH, P2MS, etc.)
  final List<InvoiceOutputSpec>? outputs;

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
    required List<String> addresses,
    required this.amount,
    List<InvoiceOutputSpec>? outputs,
    this.description,
    required this.status,
    required this.createdAt,
    this.expiresAt,
    this.paidAt,
    this.paymentTxid,
    this.amountReceived,
    Map<String, dynamic>? metadata,
  })  : addresses = frozenList(addresses),
        outputs = frozenOutputSpecsOrNull(outputs),
        metadata = frozenPlainMapOrNull(metadata);

  /// Get total amount from outputs or fallback to amount field
  BigInt get totalAmount =>
      outputs?.fold<BigInt>(BigInt.zero, (sum, o) => sum + o.amount) ?? amount;

  Map<String, dynamic> toMap() {
    return {
      'invoiceId': invoiceId,
      'walletId': walletId,
      'addresses': addresses,
      'amount': amount.toString(),
      if (outputs != null) 'outputs': outputs!.map((o) => o.toMap()).toList(),
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

  /// Legacy: Total amount for the invoice (used when outputs is null)
  final BigInt? amount;

  /// Structured output specifications (P2PKH, P2MS, etc.)
  /// When provided, this takes precedence over amount/numberOfAddresses
  final List<InvoiceOutputSpec>? outputs;

  final String? description;
  final Duration? expiresIn;
  final Map<String, dynamic>? invoiceMetadata;

  /// Legacy: How many addresses to generate for this invoice (used when outputs is null)
  final int numberOfAddresses;

  CreateInvoiceMessage({
    required this.walletId,
    this.amount,
    List<InvoiceOutputSpec>? outputs,
    this.description,
    this.expiresIn = const Duration(hours: 24),
    Map<String, dynamic>? invoiceMetadata,
    this.numberOfAddresses = 1,
  })  : outputs = frozenOutputSpecsOrNull(outputs),
        invoiceMetadata = frozenPlainMapOrNull(invoiceMetadata),
        assert(
            outputs != null || amount != null,
            'Either outputs or amount must be provided');

  /// Get the effective total amount
  BigInt get effectiveAmount {
    if (outputs != null && outputs!.isNotEmpty) {
      return outputs!.fold(BigInt.zero, (sum, o) => sum + o.amount);
    }
    return amount ?? BigInt.zero;
  }

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
class InvoiceCreatedMessage extends ActorResponse {
  final String invoiceId;
  final String walletId;

  /// Legacy: P2PKH addresses to pay to (for backward compatibility)
  final List<String> addresses;

  /// Legacy: Total amount for the invoice
  final BigInt amount;

  /// Structured output specifications (P2PKH, P2MS, etc.)
  final List<InvoiceOutputSpec>? outputs;

  final String? description;
  final DateTime createdAt;
  final DateTime? expiresAt;
  @override
  final bool success;
  @override
  final String? error;
  final Map<String, dynamic>? customMetadata;

  InvoiceCreatedMessage({
    required this.invoiceId,
    required this.walletId,
    required List<String> addresses,
    required this.amount,
    List<InvoiceOutputSpec>? outputs,
    this.description,
    required this.createdAt,
    this.expiresAt,
    required this.success,
    this.error,
    Map<String, dynamic>? customMetadata,
  })  : addresses = frozenList(addresses),
        outputs = frozenOutputSpecsOrNull(outputs),
        customMetadata = frozenPlainMapOrNull(customMetadata);

  /// Get effective total amount
  BigInt get effectiveAmount {
    if (outputs != null && outputs!.isNotEmpty) {
      return outputs!.fold(BigInt.zero, (sum, o) => sum + o.amount);
    }
    return amount;
  }

  @override
  String get correlationId => 'invoice-created-$invoiceId';

  @override
  Map<String, dynamic> get metadata => {
        'invoiceId': invoiceId,
        'walletId': walletId,
        ...?customMetadata,
      };

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
class InvoiceDetailsResponse extends ActorResponse {
  final String invoiceId;
  final String? walletId;
  final List<String> addresses;
  final BigInt amount;

  /// Structured output specifications (P2PKH, P2MS, etc.)
  final List<InvoiceOutputSpec>? outputs;

  final String? description;
  final InvoiceStatus status;
  final DateTime createdAt;
  final DateTime? expiresAt;
  final DateTime? paidAt;
  final String? paymentTxid;
  /// Whether the invoice was found. Also reported as [success], so a caller
  /// can ask any reply the same question (bead libspiffy-97zj).
  final bool found;

  @override
  final String? error;

  @override
  bool get success => found;

  InvoiceDetailsResponse({
    required this.invoiceId,
    this.walletId,
    List<String> addresses = const [],
    required this.amount,
    List<InvoiceOutputSpec>? outputs,
    this.description,
    required this.status,
    required this.createdAt,
    this.expiresAt,
    this.paidAt,
    this.paymentTxid,
    required this.found,
    this.error,
  })  : addresses = frozenList(addresses),
        outputs = frozenOutputSpecsOrNull(outputs);

  /// Get effective total amount
  BigInt get effectiveAmount {
    if (outputs != null && outputs!.isNotEmpty) {
      return outputs!.fold(BigInt.zero, (sum, o) => sum + o.amount);
    }
    return amount;
  }

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
    required List<String> addressesPaidTo,
    DateTime? paidAt,
  })  : addressesPaidTo = frozenList(addressesPaidTo),
        paidAt = paidAt ?? DateTime.now();

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
class InvoiceStatusMessage extends ActorResponse {
  final String invoiceId;
  final InvoiceStatus status;
  final DateTime? paidAt;
  final String? txid;
  final String? statusMessage;

  /// Whether the status could be read. [status] is the invoice's state;
  /// [success] says whether we could read it (bead libspiffy-97zj).
  @override
  final bool success;

  @override
  final String? error;

  InvoiceStatusMessage({
    required this.invoiceId,
    required this.status,
    this.paidAt,
    this.txid,
    this.statusMessage,
    this.success = true,
    this.error,
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
class InvoicesListMessage extends ActorResponse {
  final List<InvoiceDetailsResponse> invoices;

  @override
  final bool success;

  @override
  final String? error;

  InvoicesListMessage(List<InvoiceDetailsResponse> invoices, {this.success = true, this.error})
      : invoices = frozenList(invoices);

  @override
  String get correlationId => 'invoices-list-${DateTime.now().millisecondsSinceEpoch}';
  
  @override
  Map<String, dynamic> get metadata => {'count': invoices.length};
  
  @override
  ActorRef? get replyTo => null;
  
  @override
  DateTime get timestamp => DateTime.now();
}

