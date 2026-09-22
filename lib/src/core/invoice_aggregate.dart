import 'package:dactor/dactor.dart';
import 'package:eventador/eventador.dart';
import '../models/invoice_state.dart';
import '../models/invoice_output_spec.dart';
import '../actors/invoice_messages.dart';
import 'invoice_commands.dart';
import 'invoice_events.dart';
import 'aggregate_command_failures.dart';

/// Invoice aggregate root implementing event sourcing
///
/// This aggregate manages invoice lifecycle through events:
/// pending → paid/expired/cancelled
///
/// Follows Eventador's AggregateRoot pattern: each event yields a new,
/// immutable [InvoiceState] (bead libspiffy-mmb).
class InvoiceAggregate extends AggregateRoot<InvoiceState>
    with CommandFailureContainment<InvoiceState> {
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

  // ==========================================================================
  // SNAPSHOTS (audit 2026-09-14 M6)
  // ==========================================================================
  //
  // InvoiceState inherits State.toMap (version and timestamp only), so the
  // snapshot is written here and read back by restoreStateFromMap. Dates are
  // ISO-8601 strings and amounts decimal strings, which survive the event
  // store's CBOR round trip unchanged.

  @override
  Future<dynamic> getSnapshotState() async =>
      isInitialized ? invoiceStateToMap(currentState) : null;

  /// Every field of [state], in the form [restoreStateFromMap] reads.
  static Map<String, dynamic> invoiceStateToMap(InvoiceState state) => {
        'type': state.typeName,
        'invoiceId': state.invoiceId,
        'isCreated': state.isCreated,
        'walletId': state.walletId,
        'addresses': List<String>.from(state.addresses),
        'amount': state.amount.toString(),
        if (state.outputs != null) 'outputs': [for (final o in state.outputs!) o.toMap()],
        'description': state.description,
        'status': state.status.name,
        'createdAt': state.createdAt.toIso8601String(),
        'expiresAt': state.expiresAt?.toIso8601String(),
        'paidAt': state.paidAt?.toIso8601String(),
        'paymentTxid': state.paymentTxid,
        'amountReceived': state.amountReceived?.toString(),
        'metadata': _detachedCopy(state.metadata),
        'version': state.version,
        'lastModified': state.lastModified.toIso8601String(),
      };

  @override
  Future<InvoiceState> restoreStateFromMap(Map<String, dynamic> map, int sequenceNumber) async {
    DateTime? date(Object? v) => v == null ? null : (v is DateTime ? v : DateTime.parse(v as String));
    final invoiceId = map['invoiceId'] as String;
    if (invoiceId != aggregateId) {
      throw StateError('Snapshot at $sequenceNumber belongs to invoice $invoiceId, not $aggregateId');
    }
    final outputs = map['outputs'] as List?;
    return InvoiceState(
      invoiceId: invoiceId,
      isCreated: map['isCreated'] as bool,
      walletId: map['walletId'] as String,
      addresses: [for (final a in map['addresses'] as List) a as String],
      amount: BigInt.parse(map['amount'] as String),
      outputs: outputs == null
          ? null
          : [
              for (final o in outputs)
                InvoiceOutputSpec.fromMap(Map<String, dynamic>.from(o as Map)),
            ],
      description: map['description'] as String?,
      status: InvoiceStatus.values.byName(map['status'] as String),
      createdAt: date(map['createdAt'])!,
      expiresAt: date(map['expiresAt']),
      paidAt: date(map['paidAt']),
      paymentTxid: map['paymentTxid'] as String?,
      amountReceived:
          map['amountReceived'] == null ? null : BigInt.parse(map['amountReceived'] as String),
      metadata: Map<String, dynamic>.from(map['metadata'] as Map? ?? const {}),
      version: map['version'] as int,
      lastModified: date(map['lastModified']),
    );
  }

  /// A snapshot that cannot be restored fails recovery instead of eventador's
  /// default (empty state plus only the events after the snapshot).
  @override
  Future<void> onSnapshotRestorationFailure(
      dynamic snapshotData, int sequenceNumber, dynamic error) async {
    throw StateError('Invoice $aggregateId: snapshot at $sequenceNumber cannot be restored '
        '(refusing to recover from the events after it alone): $error');
  }

  static dynamic _detachedCopy(dynamic value) => switch (value) {
        Map m => <String, dynamic>{
            for (final e in m.entries) e.key.toString(): _detachedCopy(e.value),
          },
        List l => [for (final v in l) _detachedCopy(v)],
        _ => value,
      };

  @override
  void registerHandlers() {
    // Intentionally empty - using override pattern instead of registry pattern
  }

  /// [InvoiceStatusMessage.statusMessage] of the reply to a
  /// [CreateInvoiceCommand] whose [InvoiceCreatedEvent] is journaled (a
  /// failed creation is answered 'Command failed: ...').
  static const String invoiceCreatedStatusMessage = 'Invoice created';

  /// Send response after successful command processing
  @override
  Future<void> onCommandProcessed(Command command, List<Event> events) async {
    await super.onCommandProcessed(command, events);

    if (!_isInActorSystem()) return;

    final sender = _capturedSenders[command.commandId];
    if (sender == null) return;

    for (final event in events) {
      if (event is InvoiceCreatedEvent) {
        // Sent once the creation is journaled (bead libspiffy-u0x): the
        // coordinator answers its caller only then.
        sender.tell(InvoiceStatusMessage(
          invoiceId: event.invoiceId,
          status: InvoiceStatus.pending,
          statusMessage: invoiceCreatedStatusMessage,
        ));
      } else if (event is InvoicePaidEvent) {
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

    // Removed on first use: eventador calls onCommandFailure twice for one
    // failed command (AggregateRoot and PersistentActor), and the caller
    // got every failure reply twice.
    final sender = _capturedSenders.remove(command.commandId);
    if (sender == null) return;

    final invoiceId = command is InvoiceCommand ? command.invoiceId : aggregateId;
    // A refusal, and the invoice's status as it stands: it used to say
    // "pending" and succeeded, whatever the invoice was, so a refused
    // payment of a paid invoice read as a pending invoice (bead
    // libspiffy-mu09).
    sender.tell(InvoiceStatusMessage(
      invoiceId: invoiceId,
      status: state?.status ?? InvoiceStatus.pending,
      statusMessage: 'Command failed: $error',
      success: false,
      error: '$error',
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
    return switch (command) {
      final CreateInvoiceCommand cmd => _handleCreateInvoice(currentState, cmd),
      final MarkInvoicePaidCommand cmd => _handleMarkInvoicePaid(currentState, cmd),
      final CancelInvoiceCommand cmd => _handleCancelInvoice(currentState, cmd),
      final ExpireInvoiceCommand cmd => _handleExpireInvoice(currentState, cmd),
      _ => throw ArgumentError('Unknown command type: ${command.runtimeType}'),
    };
  }
  
  /// Applies [event] to [state] and returns the next state (bead
  /// libspiffy-mmb). [state] is never modified; eventador's `eventHandler`
  /// replaces the aggregate's state with the result once the event has
  /// applied, so an event that fails midway changes nothing.
  @override
  InvoiceState applyEvent(InvoiceState state, Event event) {
    if (event is! InvoiceEvent) {
      throw ArgumentError('Expected InvoiceEvent, got ${event.runtimeType}');
    }

    return switch (event) {
      final InvoiceCreatedEvent evt => _applyInvoiceCreated(state, evt),
      // Replay-only: nothing emits InvoiceStatusChangedEvent any more
      // (reachability sweep 2026-09-18, section 2). The arm stays because a
      // journal written by an earlier release may contain the event and must
      // still replay to the same state.
      // ignore: deprecated_member_use_from_same_package
      final InvoiceStatusChangedEvent evt => _applyInvoiceStatusChanged(state, evt),
      final InvoicePaidEvent evt => _applyInvoicePaid(state, evt),
      final InvoiceExpiredEvent evt => _applyInvoiceExpired(state, evt),
      final InvoiceCancelledEvent evt => _applyInvoiceCancelled(state, evt),
      _ => throw ArgumentError('Unknown event type: ${event.runtimeType}'),
    };
  }

  /// Nothing printed: the error is rethrown to the caller.
  @override
  void onEventApplicationFailure(Event event, dynamic error) {}
  
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
        case PluginOutputSpec plugin:
          if (plugin.pluginId.isEmpty) {
            throw ArgumentError('Output $i: Plugin ID cannot be empty');
          }
          if (plugin.pluginScriptType.isEmpty) {
            throw ArgumentError('Output $i: Plugin script type cannot be empty');
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
    
    // Business rule: Payment must be to one of the invoice addresses, or to
    // one of its multisig outputs: SPVActor matches a multisig output
    // against the invoice's keys and threshold and reports it as
    // 'p2ms:m-of-n' (bead libspiffy-n0p).
    final multisigPaidTo = {
      for (final output in currentState.outputs ?? const <InvoiceOutputSpec>[])
        if (output is P2MSOutputSpec) 'p2ms:${output.threshold}-of-${output.totalKeys}',
    };
    final validAddress = command.addressesPaidTo
        .any((addr) => currentState.addresses.contains(addr) || multisigPaidTo.contains(addr));
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
  // EVENT HANDLERS (each returns the next state)
  // ==========================================================================

  InvoiceState _applyInvoiceCreated(InvoiceState state, InvoiceCreatedEvent event) {
    return state.copyWith(
      isCreated: true,
      walletId: event.walletId,
      addresses: event.addresses,
      amount: event.amount,
      outputs: event.outputs,
      description: event.description,
      status: InvoiceStatus.pending,
      createdAt: event.timestamp,
      expiresAt: event.expiresAt,
      metadata: event.invoiceMetadata ?? const <String, dynamic>{},
      version: event.version,
      lastModified: event.timestamp,
    );
  }

  /// Replay-only: nothing emits [InvoiceStatusChangedEvent] any more. Kept so
  /// a journal written by an earlier release still replays to the same state.
  // ignore: deprecated_member_use_from_same_package
  InvoiceState _applyInvoiceStatusChanged(InvoiceState state, InvoiceStatusChangedEvent event) {
    return state.copyWith(
      status: event.newStatus,
      version: event.version,
      lastModified: event.timestamp,
    );
  }

  InvoiceState _applyInvoicePaid(InvoiceState state, InvoicePaidEvent event) {
    return state.copyWith(
      status: InvoiceStatus.paid,
      paymentTxid: event.txid,
      amountReceived: event.amountReceived,
      paidAt: event.paidAt,
      version: event.version,
      lastModified: event.timestamp,
    );
  }

  InvoiceState _applyInvoiceExpired(InvoiceState state, InvoiceExpiredEvent event) {
    return state.copyWith(
      status: InvoiceStatus.expired,
      version: event.version,
      lastModified: event.timestamp,
    );
  }

  InvoiceState _applyInvoiceCancelled(InvoiceState state, InvoiceCancelledEvent event) {
    return state.copyWith(
      status: InvoiceStatus.cancelled,
      version: event.version,
      lastModified: event.timestamp,
    );
  }
}

