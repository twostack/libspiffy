import 'package:eventador/eventador.dart';
import '../models/invoice_state.dart';
import '../actors/invoice_messages.dart';
import 'invoice_commands.dart';
import 'invoice_events.dart';

/// Invoice aggregate root implementing event sourcing
/// 
/// This aggregate manages invoice lifecycle through events:
/// pending → paid/expired/cancelled
/// 
/// Follows Eventador's AggregateRoot pattern with imperative state management.
class InvoiceAggregate extends AggregateRoot<InvoiceState> {
  InvoiceAggregate({
    required String aggregateId,
    required String aggregateType,
    required EventStore eventStore,
  }) : super(aggregateId: aggregateId, aggregateType: aggregateType, eventStore: eventStore) {
    registerHandlers();
  }
  
  @override
  InvoiceState createInitialState() {
    return InvoiceState.empty(aggregateId);
  }
  
  @override
  void registerHandlers() {
    // Intentionally empty - using override pattern instead of registry pattern
  }
  
  // ==========================================================================
  // EVENTADOR AGGREGATE ROOT IMPLEMENTATION
  // ==========================================================================
  
  @override
  Future<List<Event>> handleCommand(InvoiceState currentState, Command command) async {
    return switch (command.runtimeType) {
      CreateInvoiceCommand => _handleCreateInvoice(currentState, command as CreateInvoiceCommand),
      MarkInvoicePaidCommand => _handleMarkInvoicePaid(currentState, command as MarkInvoicePaidCommand),
      CancelInvoiceCommand => _handleCancelInvoice(currentState, command as CancelInvoiceCommand),
      ExpireInvoiceCommand => _handleExpireInvoice(currentState, command as ExpireInvoiceCommand),
      _ => throw ArgumentError('Unknown command type: ${command.runtimeType}'),
    };
  }
  
  @override
  void eventHandler(Event event) {
    // Ensure state is initialized before processing events
    // This is critical during recovery when the first event is replayed
    ensureStateInitialized();
    
    if (event is! InvoiceEvent) {
      throw ArgumentError('Expected InvoiceEvent, got ${event.runtimeType}');
    }
    
    switch (event.runtimeType) {
      case InvoiceCreatedEvent:
        _applyInvoiceCreated(event as InvoiceCreatedEvent);
        break;
      case InvoiceStatusChangedEvent:
        _applyInvoiceStatusChanged(event as InvoiceStatusChangedEvent);
        break;
      case InvoicePaidEvent:
        _applyInvoicePaid(event as InvoicePaidEvent);
        break;
      case InvoiceExpiredEvent:
        _applyInvoiceExpired(event as InvoiceExpiredEvent);
        break;
      case InvoiceCancelledEvent:
        _applyInvoiceCancelled(event as InvoiceCancelledEvent);
        break;
      default:
        throw ArgumentError('Unknown event type: ${event.runtimeType}');
    }
  }
  
  // ==========================================================================
  // COMMAND HANDLERS
  // ==========================================================================
  
  List<Event> _handleCreateInvoice(InvoiceState currentState, CreateInvoiceCommand command) {
    // Business rule: Invoice must not already exist
    if (currentState.isCreated) {
      throw StateError('Invoice ${command.invoiceId} already exists');
    }
    
    // Business rule: Must have at least one address
    if (command.addresses.isEmpty) {
      throw ArgumentError('Invoice must have at least one address');
    }
    
    // Business rule: Amount must be positive
    if (command.amount <= BigInt.zero) {
      throw ArgumentError('Invoice amount must be positive');
    }
    
    final now = DateTime.now();
    final expiresAt = command.expiresIn != null ? now.add(command.expiresIn!) : null;
    
    final event = InvoiceCreatedEvent(
      invoiceId: command.invoiceId,
      walletId: command.walletId,
      addresses: command.addresses,
      amount: command.amount,
      description: command.description,
      expiresAt: expiresAt,
      invoiceMetadata: command.invoiceMetadata,
      version: currentState.version + 1,
      timestamp: now,
    );
    
    return [event];
  }
  
  List<Event> _handleMarkInvoicePaid(InvoiceState currentState, MarkInvoicePaidCommand command) {
    // Business rule: Invoice must exist
    if (!currentState.isCreated) {
      throw StateError('Invoice ${command.invoiceId} does not exist');
    }
    
    // Business rule: Invoice must be in pending state
    if (currentState.status != InvoiceStatus.pending) {
      throw StateError('Invoice ${command.invoiceId} is not pending (current status: ${currentState.status})');
    }
    
    // Business rule: Invoice must not be expired
    if (currentState.isExpired) {
      throw StateError('Invoice ${command.invoiceId} has expired');
    }
    
    // Business rule: Payment must cover invoice amount
    if (command.amountReceived < currentState.amount) {
      throw ArgumentError('Payment amount ${command.amountReceived} is less than invoice amount ${currentState.amount}');
    }
    
    // Business rule: Payment must be to one of the invoice addresses
    final validAddress = command.addressesPaidTo.any((addr) => currentState.addresses.contains(addr));
    if (!validAddress) {
      throw ArgumentError('Payment was not made to any of the invoice addresses');
    }
    
    final paidAt = command.paidAt ?? DateTime.now();
    
    final events = <Event>[
      InvoicePaidEvent(
        invoiceId: command.invoiceId,
        walletId: currentState.walletId,
        txid: command.txid,
        amountReceived: command.amountReceived,
        addressesPaidTo: command.addressesPaidTo,
        paidAt: paidAt,
        version: currentState.version + 1,
        timestamp: DateTime.now(),
      ),
    ];
    
    return events;
  }
  
  List<Event> _handleCancelInvoice(InvoiceState currentState, CancelInvoiceCommand command) {
    // Business rule: Invoice must exist
    if (!currentState.isCreated) {
      throw StateError('Invoice ${command.invoiceId} does not exist');
    }
    
    // Business rule: Can only cancel pending invoices
    if (!currentState.canBeCancelled) {
      throw StateError('Invoice ${command.invoiceId} cannot be cancelled (current status: ${currentState.status})');
    }
    
    final event = InvoiceCancelledEvent(
      invoiceId: command.invoiceId,
      walletId: currentState.walletId,
      reason: command.reason,
      version: currentState.version + 1,
      timestamp: DateTime.now(),
    );
    
    return [event];
  }
  
  List<Event> _handleExpireInvoice(InvoiceState currentState, ExpireInvoiceCommand command) {
    // Business rule: Invoice must exist
    if (!currentState.isCreated) {
      throw StateError('Invoice ${command.invoiceId} does not exist');
    }
    
    // Business rule: Invoice must be pending
    if (currentState.status != InvoiceStatus.pending) {
      throw StateError('Invoice ${command.invoiceId} is not pending (current status: ${currentState.status})');
    }
    
    // Business rule: Invoice must have expiration date
    if (currentState.expiresAt == null) {
      throw StateError('Invoice ${command.invoiceId} does not have an expiration date');
    }
    
    // Business rule: Current time must be past expiration
    if (!currentState.isExpired) {
      throw StateError('Invoice ${command.invoiceId} has not yet expired');
    }
    
    final event = InvoiceExpiredEvent(
      invoiceId: command.invoiceId,
      walletId: currentState.walletId,
      version: currentState.version + 1,
      timestamp: DateTime.now(),
    );
    
    return [event];
  }
  
  // ==========================================================================
  // EVENT HANDLERS (IMPERATIVE STATE MUTATIONS)
  // ==========================================================================
  
  void _applyInvoiceCreated(InvoiceCreatedEvent event) {
    currentState.isCreated = true;
    currentState.walletId = event.walletId;
    currentState.addresses = List.from(event.addresses);
    currentState.amount = event.amount;
    currentState.description = event.description;
    currentState.status = InvoiceStatus.pending;
    currentState.createdAt = event.timestamp;
    currentState.expiresAt = event.expiresAt;
    currentState.metadata.clear();
    if (event.invoiceMetadata != null) {
      currentState.metadata.addAll(event.invoiceMetadata!);
    }
    currentState.version = event.version;
    currentState.lastModified = event.timestamp;
  }
  
  void _applyInvoiceStatusChanged(InvoiceStatusChangedEvent event) {
    currentState.status = event.newStatus;
    currentState.version = event.version;
    currentState.lastModified = event.timestamp;
  }
  
  void _applyInvoicePaid(InvoicePaidEvent event) {
    currentState.status = InvoiceStatus.paid;
    currentState.paymentTxid = event.txid;
    currentState.amountReceived = event.amountReceived;
    currentState.paidAt = event.paidAt;
    currentState.version = event.version;
    currentState.lastModified = event.timestamp;
  }
  
  void _applyInvoiceExpired(InvoiceExpiredEvent event) {
    currentState.status = InvoiceStatus.expired;
    currentState.version = event.version;
    currentState.lastModified = event.timestamp;
  }
  
  void _applyInvoiceCancelled(InvoiceCancelledEvent event) {
    currentState.status = InvoiceStatus.cancelled;
    currentState.version = event.version;
    currentState.lastModified = event.timestamp;
  }
}

