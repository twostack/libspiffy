import 'package:eventador/eventador.dart';
import '../core/invoice_events.dart';
import '../models/invoice_read_model.dart';
import '../actors/invoice_messages.dart';
import '../storage/read_model_storage.dart';

/// Invoice projection that builds read models from invoice events
/// 
/// This projection subscribes to invoice events from the EventStore and
/// maintains denormalized read models in Isar for fast queries.
/// Separates write concerns (aggregate) from read concerns (queries).
class InvoiceProjection extends Projection<InvoiceReadModel> {
  final ReadModelStorage _storage;
  final String _projectionId;
  late InvoiceReadModel _readModel;
  int _checkpoint = 0;
  
  InvoiceProjection({
    required String projectionId,
    required EventStore eventStore,
    required ReadModelStorage storage,
  })  : _storage = storage,
        _projectionId = projectionId,
        super() {
    _readModel = InvoiceReadModel.empty(projectionId);
  }
  
  @override
  String get projectionId => _projectionId;
  
  @override
  InvoiceReadModel get readModel => _readModel;
  
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
      switch (event.runtimeType) {
        case InvoiceCreatedEvent:
          await _handleInvoiceCreated(event as InvoiceCreatedEvent);
          return true;
        case InvoiceStatusChangedEvent:
          await _handleInvoiceStatusChanged(event as InvoiceStatusChangedEvent);
          return true;
        case InvoicePaidEvent:
          await _handleInvoicePaid(event as InvoicePaidEvent);
          return true;
        case InvoiceExpiredEvent:
          await _handleInvoiceExpired(event as InvoiceExpiredEvent);
          return true;
        case InvoiceCancelledEvent:
          await _handleInvoiceCancelled(event as InvoiceCancelledEvent);
          return true;
        default:
          return false;
      }
    } catch (e) {
      print('Error handling event ${event.runtimeType} in InvoiceProjection: $e');
      rethrow;
    }
  }
  
  Future<void> _handleInvoiceCreated(InvoiceCreatedEvent event) async {
    _readModel = InvoiceReadModel(
      invoiceId: event.invoiceId,
      walletId: event.walletId,
      addresses: List.from(event.addresses),
      amount: event.amount,
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
      await _storage.storeInvoice(_readModel);
    }
    // If invoice already exists, skip insert (idempotent replay)
    // The invoice will be updated by subsequent events (paid, expired, etc.)
  }
  
  Future<void> _handleInvoiceStatusChanged(InvoiceStatusChangedEvent event) async {
    _readModel = _readModel.copyWith(
      status: event.newStatus,
      lastUpdated: event.timestamp,
    );
    
    await _storage.updateInvoiceStatus(
      event.invoiceId,
      event.newStatus,
    );
  }
  
  Future<void> _handleInvoicePaid(InvoicePaidEvent event) async {
    _readModel = _readModel.copyWith(
      status: InvoiceStatus.paid,
      paymentTxid: event.txid,
      amountReceived: event.amountReceived,
      paidAt: event.paidAt,
      lastUpdated: event.timestamp,
    );
    
    await _storage.updateInvoiceStatus(
      event.invoiceId,
      InvoiceStatus.paid,
      txid: event.txid,
      amountReceived: event.amountReceived,
      paidAt: event.paidAt,
    );
  }
  
  Future<void> _handleInvoiceExpired(InvoiceExpiredEvent event) async {
    _readModel = _readModel.copyWith(
      status: InvoiceStatus.expired,
      lastUpdated: event.timestamp,
    );
    
    await _storage.updateInvoiceStatus(
      event.invoiceId,
      InvoiceStatus.expired,
    );
  }
  
  Future<void> _handleInvoiceCancelled(InvoiceCancelledEvent event) async {
    _readModel = _readModel.copyWith(
      status: InvoiceStatus.cancelled,
      lastUpdated: event.timestamp,
    );
    
    await _storage.updateInvoiceStatus(
      event.invoiceId,
      InvoiceStatus.cancelled,
    );
  }
  
  @override
  Future<void> reset() async {
    _readModel = InvoiceReadModel.empty(projectionId);
  }
}

