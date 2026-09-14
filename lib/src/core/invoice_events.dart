import 'package:eventador/eventador.dart';
import 'package:uuid/uuid.dart';
import '../actors/invoice_messages.dart';
import '../models/invoice_output_spec.dart';

const _uuid = Uuid();

/// Base class for all invoice-related domain events
abstract class InvoiceEvent extends AggregateEventBase with SerializableEvent {
  final String invoiceId;
  final String walletId;

  InvoiceEvent({
    required this.invoiceId,
    required this.walletId,
    String? eventId,
    DateTime? timestamp,
    int? version,
    Map<String, dynamic>? metadata,
  }) : super(
          aggregateId: invoiceId,
          aggregateType: 'Invoice',
          eventId: eventId ?? _uuid.v4(),
          timestamp: timestamp ?? DateTime.now(),
          version: version ?? 1,
          metadata: metadata ?? {},
        );

  /// Get event-specific data for serialization
  Map<String, dynamic> getInvoiceEventData();

  /// Implementation of SerializableEvent.getEventData
  @override
  Map<String, dynamic> getEventData() {
    final data = getInvoiceEventData();
    data['invoiceId'] = invoiceId;
    data['walletId'] = walletId;
    return data;
  }
  
  // Note: toMap() is inherited from SerializableEvent mixin, which properly
  // chains through Event.toMap() to include the 'type' field required by
  // CborSerializer.deserializeEvent(). Do not override toMap() here.
}

// =============================================================================
// INVOICE LIFECYCLE EVENTS
// =============================================================================

/// Event fired when an invoice is created
class InvoiceCreatedEvent extends InvoiceEvent {
  /// Journal identifier of this event type. Stored with every event and
  /// independent of the class name; never change it (audit 2026-09-14 M8).
  static const String stableTypeName = 'invoice.created';

  @override
  String get typeName => stableTypeName;

  /// Legacy: P2PKH addresses for the invoice
  final List<String> addresses;

  /// Legacy: Total amount for the invoice
  final BigInt amount;

  /// Structured output specifications (P2PKH, P2MS, etc.)
  /// When present, this takes precedence over addresses/amount
  final List<InvoiceOutputSpec>? outputs;

  final String? description;
  final DateTime? expiresAt;
  final Map<String, dynamic>? invoiceMetadata;

  InvoiceCreatedEvent({
    required String invoiceId,
    required String walletId,
    required this.addresses,
    required this.amount,
    this.outputs,
    this.description,
    this.expiresAt,
    this.invoiceMetadata,
    String? eventId,
    DateTime? timestamp,
    int? version,
    Map<String, dynamic>? metadata,
  }) : super(
          invoiceId: invoiceId,
          walletId: walletId,
          eventId: eventId,
          timestamp: timestamp,
          version: version,
          metadata: metadata,
        );

  @override
  Map<String, dynamic> getInvoiceEventData() {
    return {
      'addresses': addresses,
      'amount': amount.toString(),
      if (outputs != null) 'outputs': outputs!.map((o) => o.toMap()).toList(),
      'description': description,
      'expiresAt': expiresAt?.toIso8601String(),
      'invoiceMetadata': invoiceMetadata,
    };
  }

  static InvoiceCreatedEvent fromMap(Map<String, dynamic> map) {
    return InvoiceCreatedEvent(
      invoiceId: map['invoiceId'] as String,
      walletId: map['walletId'] as String,
      addresses: List<String>.from(map['addresses']),
      amount: BigInt.parse(map['amount'] as String),
      outputs: map['outputs'] != null
          ? (map['outputs'] as List)
              .map((o) => InvoiceOutputSpec.fromMap(o as Map<String, dynamic>))
              .toList()
          : null,
      description: map['description'] as String?,
      expiresAt: map['expiresAt'] != null
          ? (map['expiresAt'] is String
              ? DateTime.parse(map['expiresAt'] as String)
              : map['expiresAt'] as DateTime)
          : null,
      invoiceMetadata: map['invoiceMetadata'] as Map<String, dynamic>?,
      eventId: map['eventId'] as String?,
      timestamp: map['timestamp'] != null
          ? (map['timestamp'] is String
              ? DateTime.parse(map['timestamp'] as String)
              : map['timestamp'] as DateTime)
          : null,
      version: map['version'] as int?,
      metadata: map['metadata'] as Map<String, dynamic>?,
    );
  }
}

/// Event fired when invoice status changes
class InvoiceStatusChangedEvent extends InvoiceEvent {
  /// Journal identifier of this event type. Stored with every event and
  /// independent of the class name; never change it (audit 2026-09-14 M8).
  static const String stableTypeName = 'invoice.status_changed';

  @override
  String get typeName => stableTypeName;

  final InvoiceStatus oldStatus;
  final InvoiceStatus newStatus;
  final String? reason;

  InvoiceStatusChangedEvent({
    required String invoiceId,
    required String walletId,
    required this.oldStatus,
    required this.newStatus,
    this.reason,
    String? eventId,
    DateTime? timestamp,
    int? version,
    Map<String, dynamic>? metadata,
  }) : super(
          invoiceId: invoiceId,
          walletId: walletId,
          eventId: eventId,
          timestamp: timestamp,
          version: version,
          metadata: metadata,
        );

  @override
  Map<String, dynamic> getInvoiceEventData() {
    return {
      'oldStatus': oldStatus.name,
      'newStatus': newStatus.name,
      'reason': reason,
    };
  }

  /// Reads an [InvoiceStatus] stored by name.
  ///
  /// An unknown name throws a [FormatException] rather than being mapped to
  /// a default: replaying a status this build does not know (a corrupt row,
  /// or a journal written by a newer release) as, say, `pending` would
  /// silently reopen the invoice (audit 2026-09-14 L2).
  static InvoiceStatus _parseStatus(Map<String, dynamic> map, String field) {
    final name = map[field];
    for (final status in InvoiceStatus.values) {
      if (status.name == name) return status;
    }
    throw FormatException(
        'InvoiceStatusChangedEvent ${map['eventId']}: unknown $field "$name"; '
        'expected one of ${InvoiceStatus.values.map((s) => s.name).join(', ')}');
  }

  static InvoiceStatusChangedEvent fromMap(Map<String, dynamic> map) {
    return InvoiceStatusChangedEvent(
      invoiceId: map['invoiceId'] as String,
      walletId: map['walletId'] as String,
      oldStatus: _parseStatus(map, 'oldStatus'),
      newStatus: _parseStatus(map, 'newStatus'),
      reason: map['reason'] as String?,
      eventId: map['eventId'] as String?,
      timestamp: map['timestamp'] != null
          ? (map['timestamp'] is String
              ? DateTime.parse(map['timestamp'] as String)
              : map['timestamp'] as DateTime)
          : null,
      version: map['version'] as int?,
      metadata: map['metadata'] as Map<String, dynamic>?,
    );
  }
}

/// Event fired when an invoice is paid
class InvoicePaidEvent extends InvoiceEvent {
  /// Journal identifier of this event type. Stored with every event and
  /// independent of the class name; never change it (audit 2026-09-14 M8).
  static const String stableTypeName = 'invoice.paid';

  @override
  String get typeName => stableTypeName;

  final String txid;
  final BigInt amountReceived;
  final List<String> addressesPaidTo;
  final DateTime paidAt;

  InvoicePaidEvent({
    required String invoiceId,
    required String walletId,
    required this.txid,
    required this.amountReceived,
    required this.addressesPaidTo,
    DateTime? paidAt,
    String? eventId,
    DateTime? timestamp,
    int? version,
    Map<String, dynamic>? metadata,
  })  : paidAt = paidAt ?? DateTime.now(),
        super(
          invoiceId: invoiceId,
          walletId: walletId,
          eventId: eventId,
          timestamp: timestamp,
          version: version,
          metadata: metadata,
        );

  @override
  Map<String, dynamic> getInvoiceEventData() {
    return {
      'txid': txid,
      'amountReceived': amountReceived.toString(),
      'addressesPaidTo': addressesPaidTo,
      'paidAt': paidAt.toIso8601String(),
    };
  }

  static InvoicePaidEvent fromMap(Map<String, dynamic> map) {
    return InvoicePaidEvent(
      invoiceId: map['invoiceId'] as String,
      walletId: map['walletId'] as String,
      txid: map['txid'] as String,
      amountReceived: BigInt.parse(map['amountReceived'] as String),
      addressesPaidTo: List<String>.from(map['addressesPaidTo']),
      paidAt: map['paidAt'] is String
          ? DateTime.parse(map['paidAt'] as String)
          : map['paidAt'] as DateTime,
      eventId: map['eventId'] as String?,
      timestamp: map['timestamp'] != null
          ? (map['timestamp'] is String
              ? DateTime.parse(map['timestamp'] as String)
              : map['timestamp'] as DateTime)
          : null,
      version: map['version'] as int?,
      metadata: map['metadata'] as Map<String, dynamic>?,
    );
  }
}

/// Event fired when an invoice expires
class InvoiceExpiredEvent extends InvoiceEvent {
  /// Journal identifier of this event type. Stored with every event and
  /// independent of the class name; never change it (audit 2026-09-14 M8).
  static const String stableTypeName = 'invoice.expired';

  @override
  String get typeName => stableTypeName;

  InvoiceExpiredEvent({
    required String invoiceId,
    required String walletId,
    String? eventId,
    DateTime? timestamp,
    int? version,
    Map<String, dynamic>? metadata,
  }) : super(
          invoiceId: invoiceId,
          walletId: walletId,
          eventId: eventId,
          timestamp: timestamp,
          version: version,
          metadata: metadata,
        );

  @override
  Map<String, dynamic> getInvoiceEventData() {
    return {};
  }

  static InvoiceExpiredEvent fromMap(Map<String, dynamic> map) {
    return InvoiceExpiredEvent(
      invoiceId: map['invoiceId'] as String,
      walletId: map['walletId'] as String,
      eventId: map['eventId'] as String?,
      timestamp: map['timestamp'] != null
          ? (map['timestamp'] is String
              ? DateTime.parse(map['timestamp'] as String)
              : map['timestamp'] as DateTime)
          : null,
      version: map['version'] as int?,
      metadata: map['metadata'] as Map<String, dynamic>?,
    );
  }
}

/// Event fired when an invoice is cancelled
class InvoiceCancelledEvent extends InvoiceEvent {
  /// Journal identifier of this event type. Stored with every event and
  /// independent of the class name; never change it (audit 2026-09-14 M8).
  static const String stableTypeName = 'invoice.cancelled';

  @override
  String get typeName => stableTypeName;

  final String? reason;

  InvoiceCancelledEvent({
    required String invoiceId,
    required String walletId,
    this.reason,
    String? eventId,
    DateTime? timestamp,
    int? version,
    Map<String, dynamic>? metadata,
  }) : super(
          invoiceId: invoiceId,
          walletId: walletId,
          eventId: eventId,
          timestamp: timestamp,
          version: version,
          metadata: metadata,
        );

  @override
  Map<String, dynamic> getInvoiceEventData() {
    return {
      'reason': reason,
    };
  }

  static InvoiceCancelledEvent fromMap(Map<String, dynamic> map) {
    return InvoiceCancelledEvent(
      invoiceId: map['invoiceId'] as String,
      walletId: map['walletId'] as String,
      reason: map['reason'] as String?,
      eventId: map['eventId'] as String?,
      timestamp: map['timestamp'] != null
          ? (map['timestamp'] is String
              ? DateTime.parse(map['timestamp'] as String)
              : map['timestamp'] as DateTime)
          : null,
      version: map['version'] as int?,
      metadata: map['metadata'] as Map<String, dynamic>?,
    );
  }
}

