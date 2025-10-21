import 'dart:async';
import 'package:dactor/dactor.dart';
import 'package:eventador/eventador.dart';
import 'package:uuid/uuid.dart';
import '../storage/read_model_storage.dart';
import '../core/invoice_aggregate.dart';
import '../core/invoice_commands.dart';
import '../core/wallet_commands.dart';
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
  final ActorRef _walletManager;
  final ReadModelStorage _storage;
  final EventStore _eventStore;
  
  // Track spawned aggregate actors (invoiceId → ActorRef)
  final Map<String, ActorRef> _invoiceAggregates = {};
  
  // Track pending address generation requests
  final Map<String, _PendingInvoiceRequest> _pendingRequests = {};
  
  final Uuid _uuid = const Uuid();
  Timer? _expirationTimer;

  InvoiceCoordinatorActor({
    required ActorRef walletManager,
    required ReadModelStorage storage,
    required EventStore eventStore,
  })  : _walletManager = walletManager,
        _storage = storage,
        _eventStore = eventStore;

  @override
  void preStart() {
    print('InvoiceCoordinatorActor started');
    _startExpirationTimer();
  }

  @override
  Future<void> onMessage(dynamic message) async {
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
          print('InvoiceCoordinatorActor received unknown message: ${message.runtimeType}');
      }
    } catch (e, stackTrace) {
      print('Error in InvoiceCoordinatorActor: $e');
      print('Stack trace: $stackTrace');
      
      // Send error response to sender if applicable
      if (context.sender != null) {
        _sendErrorResponse(message, e.toString());
      }
    }
  }

  /// Handle invoice creation request - Step 1: Request addresses
  Future<void> _handleCreateInvoice(CreateInvoiceMessage msg) async {
    print('Creating invoice for wallet ${msg.walletId}, amount: ${msg.amount}');
    
    try {
      // Generate invoice ID
      final invoiceId = _uuid.v4();
      
      // Calculate expiration
      final expiresAt = msg.expiresIn != null
          ? DateTime.now().add(msg.expiresIn!)
          : null;
      
      // Store the pending request
      _pendingRequests[invoiceId] = _PendingInvoiceRequest(
        invoiceId: invoiceId,
        walletId: msg.walletId,
        amount: msg.amount,
        description: msg.description,
        expiresIn: msg.expiresIn,
        expiresAt: expiresAt,
        originalSender: context.sender,
        metadata: msg.metadata,
      );
      
      // Request address generation from WalletManager
      // The number of addresses could be configurable, using 1 for now
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
      
      print('Requested address for invoice $invoiceId');
      
    } catch (e) {
      print('Failed to create invoice: $e');
      if (context.sender != null) {
        context.sender!.tell(InvoiceCreatedMessage(
          invoiceId: '',
          walletId: msg.walletId,
          addresses: [],
          amount: msg.amount,
          description: msg.description,
          createdAt: DateTime.now(),
          expiresAt: null,
          success: false,
          error: e.toString(),
        ));
      }
    }
  }

  /// Handle address generation response - Step 2: Create the aggregate
  Future<void> _handleAddressGenerated(AddressGeneratedResponse msg) async {
    // Find the pending invoice request
    final invoiceId = msg.metadata['invoiceId'] as String?;
    if (invoiceId == null) {
      print('AddressGeneratedResponse missing invoiceId in metadata');
      return;
    }
    
    final pendingRequest = _pendingRequests.remove(invoiceId);
    if (pendingRequest == null) {
      print('No pending invoice request found for $invoiceId');
      return;
    }
    
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
      
      // Send CreateInvoiceCommand to the aggregate
      final command = CreateInvoiceCommand(
        invoiceId: invoiceId,
        walletId: pendingRequest.walletId,
        addresses: [msg.address], // Use the generated address
        amount: pendingRequest.amount,
        description: pendingRequest.description,
        expiresIn: pendingRequest.expiresIn,
        invoiceMetadata: pendingRequest.metadata,
      );
      
      aggregateActor.tell(command, sender: context.self);
      
      print('Created InvoiceAggregate and sent CreateInvoiceCommand for $invoiceId');
      
      // Send success response to original sender
      if (pendingRequest.originalSender != null) {
        pendingRequest.originalSender!.tell(InvoiceCreatedMessage(
          invoiceId: invoiceId,
          walletId: pendingRequest.walletId,
          addresses: [msg.address],
          amount: pendingRequest.amount,
          description: pendingRequest.description,
          createdAt: DateTime.now(),
          expiresAt: pendingRequest.expiresAt,
          success: true,
          error: null,
        ));
      }
      
    } catch (e) {
      print('Failed to create InvoiceAggregate: $e');
      if (pendingRequest.originalSender != null) {
        pendingRequest.originalSender!.tell(InvoiceCreatedMessage(
          invoiceId: invoiceId,
          walletId: pendingRequest.walletId,
          addresses: [msg.address],
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

  /// Handle check invoice request - Query read model
  Future<void> _handleCheckInvoice(CheckInvoiceMessage msg) async {
    try {
      // Query read model storage (NOT the aggregate)
      final invoiceData = await _storage.getInvoice(msg.invoiceId);
      
      if (invoiceData == null) {
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
      
      // Convert to Invoice and send response
      final invoice = _invoiceFromMap(invoiceData);
      
      context.sender?.tell(InvoiceDetailsResponse(
        invoiceId: invoice.invoiceId,
        walletId: invoice.walletId,
        addresses: invoice.addresses,
        amount: invoice.amount,
        description: invoice.description,
        status: invoice.status,
        createdAt: invoice.createdAt,
        expiresAt: invoice.expiresAt,
        paidAt: invoice.paidAt,
        paymentTxid: invoice.paymentTxid,
        found: true,
        error: null,
      ));
      
    } catch (e) {
      print('Error checking invoice: $e');
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
    print('Marking invoice ${msg.invoiceId} as paid');
    
    // Get or spawn the aggregate
    ActorRef? aggregateActor = _invoiceAggregates[msg.invoiceId];
    
    if (aggregateActor == null) {
      // Aggregate not in memory, spawn it (it will recover from event store)
      try {
        aggregateActor = await context.system.spawn(
          'invoice-aggregate-${msg.invoiceId}',
          () => InvoiceAggregate(
            aggregateId: msg.invoiceId,
            aggregateType: 'Invoice',
            eventStore: _eventStore,
          ),
        );
        _invoiceAggregates[msg.invoiceId] = aggregateActor;
        
        // Wait for recovery to complete before sending commands
        // This prevents commands from being dropped during recovery
        await Future.delayed(Duration(milliseconds: 200));
      } catch (e) {
        print('Failed to spawn InvoiceAggregate: $e');
        context.sender?.tell(InvoiceStatusMessage(
          invoiceId: msg.invoiceId,
          status: InvoiceStatus.pending,
          statusMessage: 'Failed to load invoice: $e',
        ));
        return;
      }
    }
    
    // Send MarkInvoicePaidCommand to aggregate
    final command = MarkInvoicePaidCommand(
      invoiceId: msg.invoiceId,
      txid: msg.txid,
      amountReceived: msg.amountReceived,
      addressesPaidTo: msg.addressesPaidTo,
      paidAt: msg.paidAt,
    );
    
    aggregateActor.tell(command, sender: context.self);
    
    // Send confirmation response
    context.sender?.tell(InvoiceStatusMessage(
      invoiceId: msg.invoiceId,
      status: InvoiceStatus.paid,
      paidAt: msg.paidAt,
      txid: msg.txid,
      statusMessage: 'Invoice marked as paid',
    ));
  }

  /// Handle cancel invoice - Route to aggregate
  Future<void> _handleCancelInvoice(CancelInvoiceMessage msg) async {
    print('Cancelling invoice ${msg.invoiceId}');
    
    // Get or spawn the aggregate
    ActorRef? aggregateActor = _invoiceAggregates[msg.invoiceId];
    
    if (aggregateActor == null) {
      try {
        aggregateActor = await context.system.spawn(
          'invoice-aggregate-${msg.invoiceId}',
          () => InvoiceAggregate(
            aggregateId: msg.invoiceId,
            aggregateType: 'Invoice',
            eventStore: _eventStore,
          ),
        );
        _invoiceAggregates[msg.invoiceId] = aggregateActor;
        
        // Wait for recovery to complete before sending commands
        await Future.delayed(Duration(milliseconds: 200));
      } catch (e) {
        print('Failed to spawn InvoiceAggregate: $e');
        context.sender?.tell(InvoiceStatusMessage(
          invoiceId: msg.invoiceId,
          status: InvoiceStatus.pending,
          statusMessage: 'Failed to load invoice: $e',
        ));
        return;
      }
    }
    
    // Send CancelInvoiceCommand to aggregate
    final command = CancelInvoiceCommand(
      invoiceId: msg.invoiceId,
      reason: msg.reason,
    );
    
    aggregateActor.tell(command, sender: context.self);
    
    // Send confirmation response
    context.sender?.tell(InvoiceStatusMessage(
      invoiceId: msg.invoiceId,
      status: InvoiceStatus.cancelled,
      statusMessage: 'Invoice cancelled',
    ));
  }

  /// Handle list invoices - Query read model
  Future<void> _handleListInvoices(ListInvoicesMessage msg) async {
    try {
      List<dynamic> invoicesData;
      
      if (msg.filterStatus != null) {
        invoicesData = await _storage.getInvoicesByStatus(msg.filterStatus!);
      } else if (msg.walletId != null) {
        invoicesData = await _storage.getInvoicesByWallet(msg.walletId!);
      } else {
        // List all invoices
        invoicesData = await _storage.getInvoicesByStatus(InvoiceStatus.pending);
      }
      
      final invoices = invoicesData.map((data) {
        final inv = _invoiceFromMap(data);
        return InvoiceDetailsResponse(
          invoiceId: inv.invoiceId,
          walletId: inv.walletId,
          addresses: inv.addresses,
          amount: inv.amount,
          description: inv.description,
          status: inv.status,
          createdAt: inv.createdAt,
          expiresAt: inv.expiresAt,
          paidAt: inv.paidAt,
          paymentTxid: inv.paymentTxid,
          found: true,
        );
      }).toList();
      
      context.sender?.tell(InvoicesListMessage(invoices));
      
    } catch (e) {
      print('Error listing invoices: $e');
      context.sender?.tell(InvoicesListMessage([]));
    }
  }

  /// Start periodic expiration check
  void _startExpirationTimer() {
    _expirationTimer = Timer.periodic(const Duration(minutes: 5), (_) {
      _checkExpiredInvoices();
    });
  }

  /// Check and expire old invoices
  Future<void> _checkExpiredInvoices() async {
    try {
      // Query pending invoices from read model
      final pendingInvoicesData = await _storage.getInvoicesByStatus(InvoiceStatus.pending);
      final now = DateTime.now();
      
      for (final invoiceData in pendingInvoicesData) {
        final invoice = _invoiceFromMap(invoiceData);
        
        // Check if expired
        if (invoice.expiresAt != null && now.isAfter(invoice.expiresAt!)) {
          print('Expiring invoice ${invoice.invoiceId}');
          
          // Get or spawn the aggregate
          ActorRef? aggregateActor = _invoiceAggregates[invoice.invoiceId];
          
          if (aggregateActor == null) {
            try {
              aggregateActor = await context.system.spawn(
                'invoice-aggregate-${invoice.invoiceId}',
                () => InvoiceAggregate(
                  aggregateId: invoice.invoiceId,
                  aggregateType: 'Invoice',
                  eventStore: _eventStore,
                ),
              );
              _invoiceAggregates[invoice.invoiceId] = aggregateActor;
              
              // Wait for recovery to complete before sending commands
              await Future.delayed(Duration(milliseconds: 200));
            } catch (e) {
              print('Failed to spawn InvoiceAggregate for expiration: $e');
              continue;
            }
          }
          
          // Send ExpireInvoiceCommand
          final command = ExpireInvoiceCommand(invoiceId: invoice.invoiceId);
          aggregateActor.tell(command, sender: context.self);
        }
      }
    } catch (e) {
      print('Error checking expired invoices: $e');
    }
  }

  /// Convert map to Invoice object
  Invoice _invoiceFromMap(dynamic data) {
    if (data is Invoice) return data;
    
    final map = data as Map<String, dynamic>;
    return Invoice(
      invoiceId: map['invoiceId'] as String,
      walletId: map['walletId'] as String,
      addresses: List<String>.from(map['addresses']),
      amount: map['amount'] is BigInt ? map['amount'] as BigInt : BigInt.parse(map['amount'].toString()),
      description: map['description'] as String?,
      status: map['status'] is InvoiceStatus 
          ? map['status'] as InvoiceStatus
          : InvoiceStatus.values.firstWhere(
              (s) => s.toString().split('.').last == map['status'],
            ),
      createdAt: map['createdAt'] is DateTime ? map['createdAt'] as DateTime : DateTime.parse(map['createdAt'] as String),
      expiresAt: map['expiresAt'] != null 
          ? (map['expiresAt'] is DateTime ? map['expiresAt'] as DateTime : DateTime.parse(map['expiresAt'] as String))
          : null,
      paidAt: map['paidAt'] != null
          ? (map['paidAt'] is DateTime ? map['paidAt'] as DateTime : DateTime.parse(map['paidAt'] as String))
          : null,
      paymentTxid: map['paymentTxid'] as String?,
      amountReceived: map['amountReceived'] != null
          ? (map['amountReceived'] is BigInt ? map['amountReceived'] as BigInt : BigInt.parse(map['amountReceived'].toString()))
          : null,
      metadata: map['metadata'] as Map<String, dynamic>?,
    );
  }

  /// Send error response based on message type
  void _sendErrorResponse(dynamic message, String error) {
    if (message is CreateInvoiceMessage) {
      context.sender?.tell(InvoiceCreatedMessage(
        invoiceId: '',
        walletId: message.walletId,
        addresses: [],
        amount: message.amount,
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
    print('InvoiceCoordinatorActor stopped');
  }

  /// Get invoice by ID - Query read model
  Future<Invoice?> getInvoice(String invoiceId) async {
    try {
      final invoiceData = await _storage.getInvoice(invoiceId);
      if (invoiceData == null) return null;
      return _invoiceFromMap(invoiceData);
    } catch (e) {
      print('Error getting invoice: $e');
      return null;
    }
  }
}

/// Tracks a pending invoice creation request while waiting for address generation
class _PendingInvoiceRequest {
  final String invoiceId;
  final String walletId;
  final BigInt amount;
  final String? description;
  final Duration? expiresIn;
  final DateTime? expiresAt;
  final ActorRef? originalSender;
  final Map<String, dynamic>? metadata;

  _PendingInvoiceRequest({
    required this.invoiceId,
    required this.walletId,
    required this.amount,
    this.description,
    this.expiresIn,
    this.expiresAt,
    this.originalSender,
    this.metadata,
  });
}

