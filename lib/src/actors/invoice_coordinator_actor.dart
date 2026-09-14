import 'dart:async';
import 'package:dactor/dactor.dart';
import 'package:eventador/eventador.dart';
import 'package:logging/logging.dart';
import 'package:uuid/uuid.dart';
import '../storage/read_model_storage.dart';
import '../core/invoice_aggregate.dart';
import '../core/invoice_commands.dart';
import '../core/invoice_events.dart';
import '../core/wallet_commands.dart';
import '../models/invoice_output_spec.dart';
import '../models/invoice_read_model.dart';
import 'invoice_messages.dart';
import 'wallet_messages.dart';

/// Coordinator actor for invoice management using CQRS pattern
/// 
/// This actor coordinates invoice operations by:
/// - Spawning InvoiceAggregate actors (one per invoice)
/// - Routing commands to appropriate aggregates
/// - Coordinating with WalletManager for address generation
/// - Querying read models for invoice lookups
/// 
/// NOTE: This actor does NOT write to storage directly.
/// Projections handle read-model persistence by listening to events.
class InvoiceCoordinatorActor extends Actor {
  final _log = Logger('InvoiceCoordinatorActor');
  final ActorRef _walletManager;
  final ReadModelStorage _storage;
  final EventStore _eventStore;

  /// Optional reference to the invoice ProjectionActor. When supplied,
  /// command handlers register `AwaitEventApplied` against this projection
  /// before responding to the original sender, so callers that
  /// synchronously query the read model after the response (via
  /// `CheckInvoiceMessage` → `_storage.getInvoice`) see the row.
  /// Without this, the response races the projection's async write —
  /// see overnode_v2-dmx.
  final ActorRef? _invoiceProjection;

  // Track spawned aggregate actors (invoiceId → ActorRef)
  final Map<String, ActorRef> _invoiceAggregates = {};

  // Track pending address generation requests
  final Map<String, _PendingInvoiceRequest> _pendingRequests = {};


  final Uuid _uuid = const Uuid();
  Timer? _expirationTimer;

  /// How often pending invoices are checked for expiry.
  final Duration _expirySweepInterval;

  /// True from the moment a sweep starts querying storage until its
  /// expirations have been dispatched from the mailbox; ticks that fire in
  /// between are skipped (A-M10).
  bool _expirySweepInFlight = false;

  InvoiceCoordinatorActor({
    required ActorRef walletManager,
    required ReadModelStorage storage,
    required EventStore eventStore,
    ActorRef? invoiceProjection,
    Duration expirySweepInterval = const Duration(minutes: 5),
  })  : _walletManager = walletManager,
        _storage = storage,
        _eventStore = eventStore,
        _invoiceProjection = invoiceProjection,
        _expirySweepInterval = expirySweepInterval;

  @override
  void preStart() {
    _startExpirationTimer();
  }

  @override
  Future<void> onMessage(dynamic message) async {
    if (message is _ExpireInvoices) {
      await _expireInvoices(message.invoiceIds);
      return;
    }
    try {
      switch (message.runtimeType) {
        case CreateInvoiceMessage:
          await _handleCreateInvoice(message as CreateInvoiceMessage);
          break;

        case CheckInvoiceMessage:
          await _handleCheckInvoice(message as CheckInvoiceMessage);
          break;

        case MarkInvoicePaidMessage:
          await _handleMarkInvoicePaid(message as MarkInvoicePaidMessage);
          break;
          
        case CancelInvoiceMessage:
          await _handleCancelInvoice(message as CancelInvoiceMessage);
          break;
          
        case ListInvoicesMessage:
          await _handleListInvoices(message as ListInvoicesMessage);
          break;
          
        case AddressGeneratedResponse:
          await _handleAddressGenerated(message as AddressGeneratedResponse);
          break;
          
        default:
          if (message is Map && message['error'] != null) {
            _handleWalletManagerError(message);
          }
      }
    } catch (e, stackTrace) {
      
      // Send error response to sender if applicable
      if (context.sender != null) {
        _sendErrorResponse(message, e.toString());
      }
    }
  }

  /// Handle invoice creation request - Step 1: Check if addresses needed
  Future<void> _handleCreateInvoice(CreateInvoiceMessage msg) async {
    try {
      // Generate invoice ID
      final invoiceId = _uuid.v4();

      // Calculate expiration
      final expiresAt = msg.expiresIn != null
          ? DateTime.now().add(msg.expiresIn!)
          : null;

      // Check if we have outputs with all addresses filled in (or P2MS outputs)
      final outputs = msg.outputs;
      final needsAddressGeneration = _needsAddressGeneration(outputs, msg.numberOfAddresses);

      if (needsAddressGeneration) {
        // Store the pending request - will complete when addresses arrive
        _pendingRequests[invoiceId] = _PendingInvoiceRequest(
          invoiceId: invoiceId,
          walletId: msg.walletId,
          amount: msg.effectiveAmount,
          outputs: outputs,
          description: msg.description,
          expiresIn: msg.expiresIn,
          expiresAt: expiresAt,
          originalSender: context.sender,
          metadata: msg.metadata,
          numberOfAddressesNeeded: _countAddressesNeeded(outputs, msg.numberOfAddresses),
        );

        // Request address generation from WalletManager
        _walletManager.tell(
          WalletCommandMessage(
            msg.walletId,
            GenerateAddressCommand(
              walletId: msg.walletId,
              label: 'invoice-$invoiceId',
              metadata: {
                'invoiceId': invoiceId,
                'purpose': 'invoice',
              },
            ),
          ),
          sender: context.self,
        );
      } else {
        // All outputs have addresses (or are P2MS) - create invoice directly
        await _createInvoiceDirectly(
          invoiceId: invoiceId,
          walletId: msg.walletId,
          outputs: outputs!,
          description: msg.description,
          expiresIn: msg.expiresIn,
          expiresAt: expiresAt,
          metadata: msg.metadata,
          originalSender: context.sender,
        );
      }
    } catch (e) {
      if (context.sender != null) {
        context.sender!.tell(InvoiceCreatedMessage(
          invoiceId: '',
          walletId: msg.walletId,
          addresses: [],
          amount: msg.effectiveAmount,
          description: msg.description,
          createdAt: DateTime.now(),
          expiresAt: null,
          success: false,
          error: e.toString(),
        ));
      }
    }
  }

  /// Check if we need to generate addresses for this invoice
  bool _needsAddressGeneration(List<InvoiceOutputSpec>? outputs, int legacyAddressCount) {
    if (outputs == null || outputs.isEmpty) {
      // Legacy mode - always need to generate addresses
      return true;
    }
    // Check if any P2PKH output lacks an address
    for (final output in outputs) {
      if (output is P2PKHOutputSpec && output.address.isEmpty) {
        return true;
      }
    }
    return false;
  }

  /// Count how many addresses we need to generate
  int _countAddressesNeeded(List<InvoiceOutputSpec>? outputs, int legacyAddressCount) {
    if (outputs == null || outputs.isEmpty) {
      return legacyAddressCount;
    }
    return outputs.whereType<P2PKHOutputSpec>().where((o) => o.address.isEmpty).length;
  }

  /// Create invoice directly when all outputs are ready
  Future<void> _createInvoiceDirectly({
    required String invoiceId,
    required String walletId,
    required List<InvoiceOutputSpec> outputs,
    required String? description,
    required Duration? expiresIn,
    required DateTime? expiresAt,
    required Map<String, dynamic>? metadata,
    required ActorRef? originalSender,
  }) async {
    try {
      // Spawn the InvoiceAggregate actor
      final aggregateActor = await context.system.spawn(
        'invoice-aggregate-$invoiceId',
        () => InvoiceAggregate(
          aggregateId: invoiceId,
          aggregateType: 'Invoice',
          eventStore: _eventStore,
        ),
      );

      _invoiceAggregates[invoiceId] = aggregateActor;
      // spawn() returns once recovery has completed (dactor 1.3 awaits
      // preStart), so no settle delay is needed before sending commands.

      // Extract P2PKH addresses for legacy compatibility
      final addresses = outputs
          .whereType<P2PKHOutputSpec>()
          .map((o) => o.address)
          .toList();
      final totalAmount = outputs.fold(BigInt.zero, (sum, o) => sum + o.amount);

      // Register projection-applied awaiter BEFORE telling the aggregate.
      // Resolves only after the InvoiceProjection has written the row to
      // _storage, so callers that synchronously query via CheckInvoiceMessage
      // after receiving InvoiceCreatedMessage see the row.
      final applied = _invoiceProjection?.ask<dynamic>(
        AwaitEventApplied(
          (e) => e is InvoiceCreatedEvent && e.invoiceId == invoiceId,
          timeout: const Duration(seconds: 10),
        ),
        // Ask timeout must outlast the awaiter's own window, otherwise dactor's
        // default (5 s) fires first and a slow projection looks like a failure.
        const Duration(seconds: 12),
      );

      // Send CreateInvoiceCommand to the aggregate
      final command = CreateInvoiceCommand(
        invoiceId: invoiceId,
        walletId: walletId,
        addresses: addresses,
        amount: totalAmount,
        outputs: outputs,
        description: description,
        expiresIn: expiresIn,
        invoiceMetadata: metadata,
      );

      aggregateActor.tell(command, sender: context.self);

      // Wait for the projection to apply InvoiceCreatedEvent before
      // responding. If no projection was wired (legacy test setup), this
      // is skipped — same back-compat shape as PaymentChannelManagerActor.
      if (applied != null) {
        final result = await applied;
        if (result is AwaitFailed) {
          _log.warning(
              'InvoiceProjection apply timeout for $invoiceId: ${result.reason}');
        }
      }

      // Send success response
      if (originalSender != null) {
        originalSender.tell(InvoiceCreatedMessage(
          invoiceId: invoiceId,
          walletId: walletId,
          addresses: addresses,
          amount: totalAmount,
          outputs: outputs,
          description: description,
          createdAt: DateTime.now(),
          expiresAt: expiresAt,
          success: true,
          error: null,
          customMetadata: metadata,
        ));
      }
    } catch (e) {
      if (originalSender != null) {
        originalSender.tell(InvoiceCreatedMessage(
          invoiceId: invoiceId,
          walletId: walletId,
          addresses: [],
          amount: outputs.fold(BigInt.zero, (sum, o) => sum + o.amount),
          outputs: outputs,
          description: description,
          createdAt: DateTime.now(),
          expiresAt: expiresAt,
          success: false,
          error: e.toString(),
        ));
      }
    }
  }

  /// WalletManager replies `{'error': ..., 'walletId': ...}` when a wallet
  /// cannot be loaded. Any invoice waiting on an address from that wallet
  /// will never get one, so fail it now instead of leaking the pending
  /// request and leaving the caller without a reply.
  void _handleWalletManagerError(Map<dynamic, dynamic> reply) {
    final walletId = reply['walletId']?.toString();
    final error = reply['error'].toString();
    final affected = _pendingRequests.entries
        .where((e) => walletId == null || e.value.walletId == walletId)
        .toList();
    for (final entry in affected) {
      _pendingRequests.remove(entry.key);
      final request = entry.value;
      _log.warning('Invoice ${entry.key} failed: wallet manager reported "$error"');
      request.originalSender?.tell(InvoiceCreatedMessage(
        invoiceId: entry.key,
        walletId: request.walletId,
        addresses: request.collectedAddresses,
        amount: request.amount,
        description: request.description,
        createdAt: DateTime.now(),
        expiresAt: request.expiresAt,
        success: false,
        error: error,
      ));
    }
  }

  /// Handle address generation response - Step 2: Create the aggregate
  Future<void> _handleAddressGenerated(AddressGeneratedResponse msg) async {
    // Find the pending invoice request
    final invoiceId = msg.metadata['invoiceId'] as String?;
    if (invoiceId == null) {
      return;
    }

    final pendingRequest = _pendingRequests[invoiceId];
    if (pendingRequest == null) {
      return;
    }

    if (!msg.success || msg.address.isEmpty) {
      // Previously the empty address was appended and the invoice was
      // created with an unpayable output while reporting success.
      _pendingRequests.remove(invoiceId);
      _log.warning('Address generation failed for invoice $invoiceId: ${msg.error}');
      pendingRequest.originalSender?.tell(InvoiceCreatedMessage(
        invoiceId: invoiceId,
        walletId: pendingRequest.walletId,
        addresses: pendingRequest.collectedAddresses,
        amount: pendingRequest.amount,
        description: pendingRequest.description,
        createdAt: DateTime.now(),
        expiresAt: pendingRequest.expiresAt,
        success: false,
        error: 'Address generation failed: ${msg.error ?? 'unknown error'}',
      ));
      return;
    }

    // Add the generated address to collected addresses
    pendingRequest.collectedAddresses.add(msg.address);

    // Check if we have all addresses we need
    if (pendingRequest.collectedAddresses.length < pendingRequest.numberOfAddressesNeeded) {
      // Request more addresses
      _walletManager.tell(
        WalletCommandMessage(
          pendingRequest.walletId,
          GenerateAddressCommand(
            walletId: pendingRequest.walletId,
            label: 'invoice-$invoiceId-${pendingRequest.collectedAddresses.length}',
            metadata: {
              'invoiceId': invoiceId,
              'purpose': 'invoice',
            },
          ),
        ),
        sender: context.self,
      );
      return;
    }

    // All addresses collected - remove from pending
    _pendingRequests.remove(invoiceId);

    try {
      // Build final outputs with addresses filled in
      final finalOutputs = _buildFinalOutputs(pendingRequest);

      // Spawn the InvoiceAggregate actor
      final aggregateActor = await context.system.spawn(
        'invoice-aggregate-$invoiceId',
        () => InvoiceAggregate(
          aggregateId: invoiceId,
          aggregateType: 'Invoice',
          eventStore: _eventStore,
        ),
      );

      _invoiceAggregates[invoiceId] = aggregateActor;

      // Extract addresses for legacy compatibility
      final addresses = finalOutputs
          .whereType<P2PKHOutputSpec>()
          .map((o) => o.address)
          .toList();

      // Register projection-applied awaiter BEFORE telling the aggregate.
      final applied = _invoiceProjection?.ask<dynamic>(
        AwaitEventApplied(
          (e) => e is InvoiceCreatedEvent && e.invoiceId == invoiceId,
          timeout: const Duration(seconds: 10),
        ),
        // Ask timeout must outlast the awaiter's own window, otherwise dactor's
        // default (5 s) fires first and a slow projection looks like a failure.
        const Duration(seconds: 12),
      );

      // Send CreateInvoiceCommand to the aggregate
      final command = CreateInvoiceCommand(
        invoiceId: invoiceId,
        walletId: pendingRequest.walletId,
        addresses: addresses,
        amount: pendingRequest.amount,
        outputs: finalOutputs,
        description: pendingRequest.description,
        expiresIn: pendingRequest.expiresIn,
        invoiceMetadata: pendingRequest.metadata,
      );

      aggregateActor.tell(command, sender: context.self);

      // Wait for the projection to apply InvoiceCreatedEvent before responding.
      if (applied != null) {
        final result = await applied;
        if (result is AwaitFailed) {
          _log.warning(
              'InvoiceProjection apply timeout for $invoiceId: ${result.reason}');
        }
      }

      // Send success response to original sender
      if (pendingRequest.originalSender != null) {
        pendingRequest.originalSender!.tell(InvoiceCreatedMessage(
          invoiceId: invoiceId,
          walletId: pendingRequest.walletId,
          addresses: addresses,
          amount: pendingRequest.amount,
          outputs: finalOutputs,
          description: pendingRequest.description,
          createdAt: DateTime.now(),
          expiresAt: pendingRequest.expiresAt,
          success: true,
          error: null,
          customMetadata: pendingRequest.metadata,
        ));
      }
    } catch (e) {
      if (pendingRequest.originalSender != null) {
        pendingRequest.originalSender!.tell(InvoiceCreatedMessage(
          invoiceId: invoiceId,
          walletId: pendingRequest.walletId,
          addresses: pendingRequest.collectedAddresses,
          amount: pendingRequest.amount,
          description: pendingRequest.description,
          createdAt: DateTime.now(),
          expiresAt: pendingRequest.expiresAt,
          success: false,
          error: e.toString(),
        ));
      }
    }
  }

  /// Build final outputs by filling in generated addresses
  List<InvoiceOutputSpec> _buildFinalOutputs(_PendingInvoiceRequest request) {
    if (request.outputs == null || request.outputs!.isEmpty) {
      // Legacy mode - create P2PKH outputs from addresses
      final amountPerAddress = request.amount ~/ BigInt.from(request.collectedAddresses.length);
      return request.collectedAddresses
          .map((addr) => P2PKHOutputSpec(address: addr, amount: amountPerAddress))
          .toList();
    }

    // Fill in empty addresses in P2PKH outputs
    final addressIterator = request.collectedAddresses.iterator;
    return request.outputs!.map((output) {
      if (output is P2PKHOutputSpec && output.address.isEmpty) {
        if (addressIterator.moveNext()) {
          return P2PKHOutputSpec(
            address: addressIterator.current,
            amount: output.amount,
            label: output.label,
          );
        }
      }
      return output;
    }).toList();
  }

  /// Handle check invoice request - Query read model
  Future<void> _handleCheckInvoice(CheckInvoiceMessage msg) async {
    try {
      // Query read model storage (NOT the aggregate)
      final invoice = await _storage.getInvoice(msg.invoiceId);
      
      if (invoice == null) {
        context.sender?.tell(InvoiceDetailsResponse(
          invoiceId: msg.invoiceId,
          addresses: [],
          amount: BigInt.zero,
          status: InvoiceStatus.pending,
          createdAt: DateTime.now(),
          found: false,
          error: 'Invoice not found',
        ));
        return;
      }
      
      context.sender?.tell(_detailsFromReadModel(invoice));
      
    } catch (e) {
      context.sender?.tell(InvoiceDetailsResponse(
        invoiceId: msg.invoiceId,
        addresses: [],
        amount: BigInt.zero,
        status: InvoiceStatus.pending,
        createdAt: DateTime.now(),
        found: false,
        error: e.toString(),
      ));
    }
  }

  /// Handle mark invoice paid - Route to aggregate
  Future<void> _handleMarkInvoicePaid(MarkInvoicePaidMessage msg) async {
    final originalSender = context.sender;

    final ActorRef aggregateActor;
    try {
      aggregateActor = await _invoiceAggregate(msg.invoiceId);
    } catch (e) {
      originalSender?.tell(InvoiceStatusMessage(
        invoiceId: msg.invoiceId,
        status: InvoiceStatus.pending,
        statusMessage: 'Failed to load invoice: $e',
      ));
      return;
    }

    final command = MarkInvoicePaidCommand(
      invoiceId: msg.invoiceId,
      txid: msg.txid,
      amountReceived: msg.amountReceived,
      addressesPaidTo: msg.addressesPaidTo,
      paidAt: msg.paidAt,
    );

    if (_invoiceProjection == null) {
      // Legacy path: aggregate replies directly to original sender.
      // No projection wired → no race to coordinate against.
      aggregateActor.tell(command, sender: originalSender);
      return;
    }

    // Register projection-applied awaiter BEFORE telling the aggregate.
    // We can't await the aggregate's own InvoiceStatusMessage reply here
    // because that would deadlock (the coordinator's mailbox is blocked
    // inside this handler; the aggregate's reply can only be processed
    // once this handler returns). Instead we await on the InvoicePaidEvent
    // matched by the projection — same data, post-applied, no deadlock.
    final applied = _invoiceProjection!.ask<dynamic>(
      AwaitEventApplied(
        (e) => e is InvoicePaidEvent && e.invoiceId == msg.invoiceId,
        timeout: const Duration(seconds: 10),
      ),
      // Ask timeout must outlast the awaiter's own window, otherwise dactor's
      // default (5 s) fires first and a slow projection looks like a failure.
      const Duration(seconds: 12),
    );

    // Tell aggregate with a null/no sender so its onCommandProcessed reply
    // is dropped (we synthesise our own from the matched event below).
    // We intentionally do not pass `sender: originalSender` either: the
    // aggregate would race ahead and reply before the projection has
    // applied, re-introducing the bug we're fixing.
    aggregateActor.tell(command);

    final result = await applied;
    if (result is AwaitFailed) {
      _log.warning(
          'InvoiceProjection apply timeout for ${msg.invoiceId}: ${result.reason}');
      originalSender?.tell(InvoiceStatusMessage(
        invoiceId: msg.invoiceId,
        status: InvoiceStatus.pending,
        statusMessage: 'Mark-paid projection timeout: ${result.reason}',
      ));
      return;
    }

    // Construct the response from the matched event — same fields the
    // aggregate's onCommandProcessed would have populated.
    final paidEvent = (result as EventAppliedResponse).matchedEvent
        as InvoicePaidEvent;
    originalSender?.tell(InvoiceStatusMessage(
      invoiceId: paidEvent.invoiceId,
      status: InvoiceStatus.paid,
      paidAt: paidEvent.paidAt,
      txid: paidEvent.txid,
      statusMessage: 'Invoice marked as paid',
    ));
  }

  /// Handle cancel invoice - Route to aggregate
  Future<void> _handleCancelInvoice(CancelInvoiceMessage msg) async {
    
    final ActorRef aggregateActor;
    try {
      aggregateActor = await _invoiceAggregate(msg.invoiceId);
    } catch (e) {
      context.sender?.tell(InvoiceStatusMessage(
        invoiceId: msg.invoiceId,
        status: InvoiceStatus.pending,
        statusMessage: 'Failed to load invoice: $e',
      ));
      return;
    }
    
    // Send CancelInvoiceCommand to aggregate
    // The aggregate will respond directly to the original sender via onCommandProcessed
    final command = CancelInvoiceCommand(
      invoiceId: msg.invoiceId,
      reason: msg.reason,
    );

    aggregateActor.tell(command, sender: context.sender);
  }

  /// Handle list invoices - Query read model
  Future<void> _handleListInvoices(ListInvoicesMessage msg) async {
    try {
      // null walletId = every wallet; null filterStatus = every status.
      final readModels = await _storage.listInvoices(
        walletId: msg.walletId,
        status: msg.filterStatus,
      );
      
      context.sender?.tell(InvoicesListMessage(
        readModels.map(_detailsFromReadModel).toList(),
      ));
      
    } catch (e) {
      context.sender?.tell(InvoicesListMessage([]));
    }
  }

  /// Start periodic expiration check
  void _startExpirationTimer() {
    final self = context.self;
    _expirationTimer = Timer.periodic(_expirySweepInterval, (_) {
      _checkExpiredInvoices(self);
    });
  }

  /// Timer tick: find expired invoices without blocking the mailbox, then
  /// hand them to the mailbox ([_ExpireInvoices]) so spawning aggregates and
  /// touching [_invoiceAggregates] stays serialized with the handlers. At
  /// most one sweep is in flight; overlapping ticks are skipped.
  Future<void> _checkExpiredInvoices(ActorRef self) async {
    if (_expirySweepInFlight) return;
    _expirySweepInFlight = true;
    try {
      // Query pending invoices from read model
      final pendingInvoices =
          await _storage.listInvoices(status: InvoiceStatus.pending);
      final now = DateTime.now();
      final expired = [
        for (final invoice in pendingInvoices)
          if (invoice.expiresAt != null && now.isAfter(invoice.expiresAt!))
            invoice.invoiceId,
      ];
      // The mailbox handler clears the in-flight flag.
      self.tell(LocalMessage(payload: _ExpireInvoices(expired)));
    } catch (e) {
      _log.warning('Failed to check expired invoices: $e');
      _expirySweepInFlight = false;
    }
  }

  /// Mailbox half of the expiry sweep: expire each invoice via its aggregate.
  Future<void> _expireInvoices(List<String> invoiceIds) async {
    try {
      for (final invoiceId in invoiceIds) {
        final ActorRef aggregateActor;
        try {
          aggregateActor = await _invoiceAggregate(invoiceId);
        } catch (e) {
          continue;
        }

        // Send ExpireInvoiceCommand
        final command = ExpireInvoiceCommand(invoiceId: invoiceId);
        aggregateActor.tell(command, sender: context.self);
      }
    } catch (e) {
      _log.warning('Failed to expire invoices: $e');
    } finally {
      _expirySweepInFlight = false;
    }
  }

  /// The loaded aggregate of an existing invoice, or one recovered from its
  /// journal now. An aggregate stops itself when a journal write fails (a
  /// rejected command leaves it running, libspiffy-201), so a cached ref that
  /// is no longer alive is replaced rather than told commands that would go
  /// to dead letters. An invoice with no journal is a [StateError]: no
  /// aggregate is spawned (and kept running) for an unknown id.
  Future<ActorRef> _invoiceAggregate(String invoiceId) async {
    final cached = _invoiceAggregates[invoiceId];
    if (cached != null) {
      if (cached.isAlive) return cached;
      _invoiceAggregates.remove(invoiceId);
    }
    if (await _eventStore.getHighestSequenceNumber('Invoice_$invoiceId') == 0) {
      throw StateError('Invoice $invoiceId not found');
    }
    final aggregateActor = await context.system.spawn(
      'invoice-aggregate-$invoiceId',
      () => InvoiceAggregate(
        aggregateId: invoiceId,
        aggregateType: 'Invoice',
        eventStore: _eventStore,
      ),
    );
    _invoiceAggregates[invoiceId] = aggregateActor;
    return aggregateActor;
  }

  /// Build the query reply for a stored invoice read model.
  InvoiceDetailsResponse _detailsFromReadModel(InvoiceReadModel invoice) {
    return InvoiceDetailsResponse(
      invoiceId: invoice.invoiceId,
      walletId: invoice.walletId,
      addresses: invoice.addresses,
      amount: invoice.amount,
      outputs: invoice.outputs,
      description: invoice.description,
      status: invoice.status,
      createdAt: invoice.createdAt,
      expiresAt: invoice.expiresAt,
      paidAt: invoice.paidAt,
      paymentTxid: invoice.paymentTxid,
      found: true,
      error: null,
    );
  }

  /// Send error response based on message type
  void _sendErrorResponse(dynamic message, String error) {
    if (message is CreateInvoiceMessage) {
      context.sender?.tell(InvoiceCreatedMessage(
        invoiceId: '',
        walletId: message.walletId,
        addresses: [],
        amount: message.effectiveAmount,
        description: message.description,
        createdAt: DateTime.now(),
        success: false,
        error: error,
      ));
    } else if (message is CheckInvoiceMessage) {
      context.sender?.tell(InvoiceDetailsResponse(
        invoiceId: message.invoiceId,
        addresses: [],
        amount: BigInt.zero,
        status: InvoiceStatus.pending,
        createdAt: DateTime.now(),
        found: false,
        error: error,
      ));
    } else if (message is MarkInvoicePaidMessage) {
      context.sender?.tell(InvoiceStatusMessage(
        invoiceId: message.invoiceId,
        status: InvoiceStatus.pending,
        statusMessage: error,
      ));
    }
  }

  @override
  void postStop() {
    _expirationTimer?.cancel();
    // Stop the aggregates this coordinator spawned, so a host-owned actor
    // system does not keep them running after libspiffy shuts down (A-M5).
    final system = context.system;
    for (final ref in _invoiceAggregates.values) {
      unawaited(system.stop(ref));
    }
    _invoiceAggregates.clear();
  }

  /// Get invoice by ID - Query read model
  Future<InvoiceReadModel?> getInvoice(String invoiceId) async {
    try {
      return await _storage.getInvoice(invoiceId);
    } catch (e) {
      return null;
    }
  }
}

/// Mailbox half of an expiry sweep: the invoices found expired.
class _ExpireInvoices {
  final List<String> invoiceIds;
  const _ExpireInvoices(this.invoiceIds);
}

/// Tracks a pending invoice creation request while waiting for address generation
class _PendingInvoiceRequest {
  final String invoiceId;
  final String walletId;
  final BigInt amount;
  final List<InvoiceOutputSpec>? outputs;
  final String? description;
  final Duration? expiresIn;
  final DateTime? expiresAt;
  final ActorRef? originalSender;
  final Map<String, dynamic>? metadata;
  final int numberOfAddressesNeeded;
  final List<String> collectedAddresses = [];

  _PendingInvoiceRequest({
    required this.invoiceId,
    required this.walletId,
    required this.amount,
    this.outputs,
    this.description,
    this.expiresIn,
    this.expiresAt,
    this.originalSender,
    this.metadata,
    this.numberOfAddressesNeeded = 1,
  });
}

