import 'package:eventador/eventador.dart';
import '../core/invoice_events.dart';
import '../models/invoice_read_model.dart';
import '../actors/invoice_messages.dart';
import '../storage/read_model_storage.dart';

/// Invoice projection that builds read models from invoice events
///
/// This projection subscribes to invoice events from the EventStore and
/// maintains denormalized read models in storage for fast queries.
/// Separates write concerns (aggregate) from read concerns (queries).
class InvoiceProjection extends Projection<InvoiceReadModel> {
  final ReadModelStorage _storage;
  final String _projectionId;
  int _checkpoint = 0;

  InvoiceProjection({
    required String projectionId,
    required EventStore eventStore,
    required ReadModelStorage storage,
  })  : _storage = storage,
        _projectionId = projectionId,
        super();

  @override
  String get projectionId => _projectionId;

  @override
  InvoiceReadModel get readModel => InvoiceReadModel.empty(projectionId);

  @override
  List<Type> get interestedEventTypes => [
        InvoiceCreatedEvent,
        InvoiceStatusChangedEvent,
        InvoicePaidEvent,
        InvoiceExpiredEvent,
        InvoiceCancelledEvent,
      ];

  @override
  Future<int> getCheckpoint() async {
    return _checkpoint;
  }

  @override
  Future<void> updateCheckpoint(int checkpoint) async {
    _checkpoint = checkpoint;
  }

  @override
  Future<void> rebuild() async {
    await reset();
    // Projection manager will replay events after rebuild
  }

  @override
  Future<bool> handle(Event event) async {
    if (event is! InvoiceEvent) return false;

    try {
      switch (event) {
        case final InvoiceCreatedEvent evt:
          await _handleInvoiceCreated(evt);
          return true;
        case final InvoiceStatusChangedEvent evt:
          await _handleInvoiceStatusChanged(evt);
          return true;
        case final InvoicePaidEvent evt:
          await _handleInvoicePaid(evt);
          return true;
        case final InvoiceExpiredEvent evt:
          await _handleInvoiceExpired(evt);
          return true;
        case final InvoiceCancelledEvent evt:
          await _handleInvoiceCancelled(evt);
          return true;
        default:
          return false;
      }
    } catch (e) {
      rethrow;
    }
  }

  Future<void> _handleInvoiceCreated(InvoiceCreatedEvent event) async {
    final readModel = InvoiceReadModel(
      invoiceId: event.invoiceId,
      walletId: event.walletId,
      addresses: List.from(event.addresses),
      amount: event.amount,
      outputs: event.outputs,
      description: event.description,
      status: InvoiceStatus.pending,
      createdAt: event.timestamp,
      expiresAt: event.expiresAt,
      paidAt: null,
      paymentTxid: null,
      amountReceived: null,
      lastUpdated: event.timestamp,
      metadata: event.invoiceMetadata ?? {},
    );

    // Check if invoice already exists (for idempotent projection replay)
    final existing = await _storage.getInvoice(event.invoiceId);

    if (existing == null) {
      // Store the InvoiceReadModel we just created
      await _storage.storeInvoice(readModel);
    }
    // If invoice already exists, skip insert (idempotent replay)
    // The invoice will be updated by subsequent events (paid, expired, etc.)
  }

  Future<void> _handleInvoiceStatusChanged(InvoiceStatusChangedEvent event) async {
    await _storage.updateInvoiceStatus(
      event.invoiceId,
      event.newStatus,
    );
  }

  Future<void> _handleInvoicePaid(InvoicePaidEvent event) async {
    await _storage.updateInvoiceStatus(
      event.invoiceId,
      InvoiceStatus.paid,
      txid: event.txid,
      amountReceived: event.amountReceived,
      paidAt: event.paidAt,
    );
  }

  Future<void> _handleInvoiceExpired(InvoiceExpiredEvent event) async {
    await _storage.updateInvoiceStatus(
      event.invoiceId,
      InvoiceStatus.expired,
    );
  }

  Future<void> _handleInvoiceCancelled(InvoiceCancelledEvent event) async {
    await _storage.updateInvoiceStatus(
      event.invoiceId,
      InvoiceStatus.cancelled,
    );
  }

  /// Get an invoice read model by ID from storage
  Future<InvoiceReadModel?> getInvoice(String invoiceId) =>
      _storage.getInvoice(invoiceId);

  @override
  Future<void> reset() async {
    _checkpoint = 0;
  }
}
