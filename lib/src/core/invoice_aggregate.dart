import 'package:dactor/dactor.dart';
import 'package:eventador/eventador.dart';
import '../models/invoice_state.dart';
import '../models/invoice_output_spec.dart';
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
  // Capture sender at start of message processing for use in onCommandProcessed
  final Map<String, ActorRef> _capturedSenders = {};

  InvoiceAggregate({
    required String aggregateId,
    required String aggregateType,
    required EventStore eventStore,
  }) : super(aggregateId: aggregateId, aggregateType: aggregateType, eventStore: eventStore) {
    registerHandlers();
  }

  @override
  Future<void> onMessage(dynamic message) async {
    // Capture sender keyed by command ID for response routing
    String? commandKey;
    if (message is Command && _isInActorSystem()) {
      final sender = context.sender;
      if (sender != null) {
        commandKey = message.commandId;
        _capturedSenders[commandKey] = sender;
      }
    }

    try {
      await super.onMessage(message);
    } finally {
      if (commandKey != null) {
        _capturedSenders.remove(commandKey);
      }
    }
  }

  @override
  InvoiceState createInitialState() {
    return InvoiceState.empty(aggregateId);
  }

  @override
  void registerHandlers() {
    // Intentionally empty - using override pattern instead of registry pattern
  }

  /// Send response after successful command processing
  @override
  Future<void> onCommandProcessed(Command command, List<Event> events) async {
    await super.onCommandProcessed(command, events);

    if (!_isInActorSystem()) return;

    final sender = _capturedSenders[command.commandId];
    if (sender == null) return;

    for (final event in events) {
      if (event is InvoicePaidEvent) {
        sender.tell(InvoiceStatusMessage(
          invoiceId: event.invoiceId,
          status: InvoiceStatus.paid,
          paidAt: event.paidAt,
          txid: event.txid,
          statusMessage: 'Invoice marked as paid',
        ));
      } else if (event is InvoiceCancelledEvent) {
        sender.tell(InvoiceStatusMessage(
          invoiceId: event.invoiceId,
          status: InvoiceStatus.cancelled,
          statusMessage: 'Invoice cancelled',
        ));
      } else if (event is InvoiceExpiredEvent) {
        sender.tell(InvoiceStatusMessage(
          invoiceId: event.invoiceId,
          status: InvoiceStatus.expired,
          statusMessage: 'Invoice expired',
        ));
      }
    }
  }

  /// Send error response when command processing fails
  @override
  Future<void> onCommandFailure(Command command, dynamic error) async {
    await super.onCommandFailure(command, error);

    if (!_isInActorSystem()) return;

    final sender = _capturedSenders[command.commandId];
    if (sender == null) return;

    final invoiceId = command is InvoiceCommand ? command.invoiceId : aggregateId;
    sender.tell(InvoiceStatusMessage(
      invoiceId: invoiceId,
      status: InvoiceStatus.pending, // Status unchanged on failure
      statusMessage: 'Command failed: $error',
    ));
  }

  /// Check if we're running in an actor system
  bool _isInActorSystem() {
    try {
      final _ = context;
      return true;
    } catch (e) {
      return false;
    }
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

    // Validate outputs if provided
    if (command.outputs != null && command.outputs!.isNotEmpty) {
      _validateOutputs(command.outputs!);
    } else {
      // Legacy validation for addresses/amount
      // Business rule: Must have at least one address
      if (command.addresses.isEmpty) {
        throw ArgumentError('Invoice must have at least one address');
      }

      // Business rule: Amount must be positive
      if (command.amount <= BigInt.zero) {
        throw ArgumentError('Invoice amount must be positive');
      }
    }

    final now = DateTime.now();
    final expiresAt = command.expiresIn != null ? now.add(command.expiresIn!) : null;

    final event = InvoiceCreatedEvent(
      invoiceId: command.invoiceId,
      walletId: command.walletId,
      addresses: command.addresses,
      amount: command.amount,
      outputs: command.outputs,
      description: command.description,
      expiresAt: expiresAt,
      invoiceMetadata: command.invoiceMetadata,
      version: currentState.version + 1,
      timestamp: now,
    );

    return [event];
  }

  /// Validate output specifications
  void _validateOutputs(List<InvoiceOutputSpec> outputs) {
    if (outputs.isEmpty) {
      throw ArgumentError('Invoice must have at least one output');
    }

    for (int i = 0; i < outputs.length; i++) {
      final output = outputs[i];

      // Validate amount is positive (skip for data-only outputs like OP_RETURN)
      if (output is! OPReturnOutputSpec && output.amount <= BigInt.zero) {
        throw ArgumentError('Output $i: amount must be positive');
      }

      // Type-specific validation
      switch (output) {
        case P2PKHOutputSpec p2pkh:
          if (p2pkh.address.isEmpty) {
            throw ArgumentError('Output $i: P2PKH address cannot be empty');
          }
        case P2MSOutputSpec p2ms:
          if (!p2ms.isValid) {
            throw ArgumentError(
                'Output $i: Invalid P2MS configuration - '
                'threshold: ${p2ms.threshold}, totalKeys: ${p2ms.totalKeys}');
          }
          if (p2ms.threshold < 1) {
            throw ArgumentError('Output $i: P2MS threshold must be at least 1');
          }
          if (p2ms.threshold > p2ms.totalKeys) {
            throw ArgumentError(
                'Output $i: P2MS threshold (${p2ms.threshold}) cannot exceed '
                'total keys (${p2ms.totalKeys})');
          }
          if (p2ms.totalKeys > 16) {
            throw ArgumentError(
                'Output $i: P2MS cannot have more than 16 keys (has ${p2ms.totalKeys})');
          }
          for (int j = 0; j < p2ms.publicKeys.length; j++) {
            final pk = p2ms.publicKeys[j];
            if (pk.length != 66 && pk.length != 130) {
              throw ArgumentError(
                  'Output $i: Public key $j has invalid length ${pk.length} '
                  '(expected 66 for compressed or 130 for uncompressed)');
            }
          }
        case OPReturnOutputSpec opReturn:
          if (!opReturn.isValid) {
            throw ArgumentError(
                'Output $i: Invalid OP_RETURN configuration - '
                'must have non-empty data within ${OPReturnOutputSpec.maxTotalDataSize} bytes');
          }
      }
    }
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
    currentState.outputs = event.outputs != null ? List.from(event.outputs!) : null;
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

