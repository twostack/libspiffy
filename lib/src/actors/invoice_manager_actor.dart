import 'dart:async';
import 'package:dactor/dactor.dart';
import 'package:uuid/uuid.dart';
import '../storage/read_model_storage.dart';
import 'invoice_messages.dart';
import 'wallet_messages.dart';
import '../core/wallet_commands.dart';

/// Actor responsible for managing invoices/payment requests
/// 
/// Key responsibilities:
/// - Create and track invoices with generated addresses
/// - Coordinate with WalletManager for address generation
/// - Validate payments against invoice expectations
/// - Handle invoice lifecycle (pending, paid, expired, cancelled)
/// - Provide invoice lookup for SPV validation
class InvoiceManagerActor extends Actor {
  final ActorRef _walletManager;
  final ReadModelStorage? _storage; // Optional persistence for invoice read models
  
  // In-memory invoice tracking (for fast lookups)
  final Map<String, Invoice> _invoices = {};
  final Map<String, String> _addressToInvoice = {}; // address → invoiceId lookup
  
  // Track pending address generation requests
  final Map<String, _PendingInvoice> _pendingInvoices = {};
  
  final Uuid _uuid = const Uuid();
  Timer? _expirationTimer;

  InvoiceManagerActor({
    required ActorRef walletManager,
    ReadModelStorage? storage,
  })  : _walletManager = walletManager,
        _storage = storage;

  @override
  void preStart() {
    print('InvoiceManagerActor started');
    _loadInvoicesFromStorage();
    _startExpirationTimer();
  }

  /// Load existing invoices from storage on startup
  Future<void> _loadInvoicesFromStorage() async {
    if (_storage == null) return;
    
    try {
      // Load all invoices from storage (across all wallets)
      // Note: This could be optimized to load on-demand per wallet
      final allInvoices = await _storage.getInvoicesByStatus(InvoiceStatus.pending);
      
      for (final invoiceData in allInvoices) {
        final invoice = _invoiceFromMap(invoiceData);
        _invoices[invoice.invoiceId] = invoice;
        
        // Rebuild address lookup index
        for (final address in invoice.addresses) {
          _addressToInvoice[address] = invoice.invoiceId;
        }
      }
      
      print('Loaded ${allInvoices.length} pending invoices from storage');
    } catch (e) {
      print('Warning: Failed to load invoices from storage: $e');
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
          : InvoiceStatus.values.firstWhere((s) => s.name == map['status']),
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
          print('InvoiceManagerActor received unknown message: ${message.runtimeType}');
      }
    } catch (e, stackTrace) {
      print('Error in InvoiceManagerActor: $e');
      print('Stack trace: $stackTrace');
      
      // Send error response to sender if applicable
      if (context.sender != null) {
        _sendErrorResponse(message, e.toString());
      }
    }
  }

  /// Handle invoice creation request
  Future<void> _handleCreateInvoice(CreateInvoiceMessage msg) async {
    print('Creating invoice for wallet ${msg.walletId}, amount: ${msg.amount}');
    
    try {
      // Generate invoice ID
      final invoiceId = _uuid.v4();
      
      // Calculate expiration
      final createdAt = DateTime.now();
      final expiresAt = msg.expiresIn != null 
          ? createdAt.add(msg.expiresIn!)
          : null;
      
      // Track pending invoice creation
      _pendingInvoices[invoiceId] = _PendingInvoice(
        invoiceId: invoiceId,
        walletId: msg.walletId,
        amount: msg.amount,
        description: msg.description,
        createdAt: createdAt,
        expiresAt: expiresAt,
        numberOfAddresses: msg.numberOfAddresses,
        originalSender: context.sender,
        metadata: msg.invoiceMetadata,
      );
      
      // Request address generation from wallet
      for (int i = 0; i < msg.numberOfAddresses; i++) {
        final generateCmd = GenerateAddressCommand(
          walletId: msg.walletId,
        );
        
        _walletManager.tell(
          WalletCommandMessage(msg.walletId, generateCmd),
          sender: context.self,
        );
      }
      
      print('Invoice $invoiceId: Requested ${msg.numberOfAddresses} address(es) from wallet');
      
    } catch (e) {
      print('Error creating invoice: $e');
      context.sender?.tell(InvoiceCreatedMessage(
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

  /// Handle address generation response from wallet
  Future<void> _handleAddressGenerated(AddressGeneratedResponse msg) async {
    if (!msg.success) {
      print('Address generation failed: ${msg.error}');
      return;
    }
    
    // Find the pending invoice for this wallet
    final pending = _pendingInvoices.values.firstWhere(
      (p) => p.walletId == msg.walletId && p.addresses.length < p.numberOfAddresses,
      orElse: () => throw Exception('No pending invoice found for wallet ${msg.walletId}'),
    );
    
    // Add generated address to pending invoice
    pending.addresses.add(msg.address);
    
    print('Invoice ${pending.invoiceId}: Generated address ${msg.address} (${pending.addresses.length}/${pending.numberOfAddresses})');
    
    // Check if we have all addresses
    if (pending.addresses.length >= pending.numberOfAddresses) {
      await _finalizeInvoice(pending);
    }
  }

  /// Finalize invoice after all addresses are generated
  Future<void> _finalizeInvoice(_PendingInvoice pending) async {
    // Create invoice record
    final invoice = Invoice(
      invoiceId: pending.invoiceId,
      walletId: pending.walletId,
      addresses: List.from(pending.addresses),
      amount: pending.amount,
      description: pending.description,
      status: InvoiceStatus.pending,
      createdAt: pending.createdAt,
      expiresAt: pending.expiresAt,
      metadata: pending.metadata,
    );
    
    // Store invoice
    _invoices[invoice.invoiceId] = invoice;
    
    // Build address lookup index
    for (final address in invoice.addresses) {
      _addressToInvoice[address] = invoice.invoiceId;
    }
    
    // Persist invoice to storage
    if (_storage != null) {
      try {
        await _storage.storeInvoice(invoice);
      } catch (e) {
        print('Warning: Failed to persist invoice: $e');
      }
    }
    
    // Remove from pending
    _pendingInvoices.remove(pending.invoiceId);
    
    // Send success response to original requester
    pending.originalSender?.tell(InvoiceCreatedMessage(
      invoiceId: invoice.invoiceId,
      walletId: invoice.walletId,
      addresses: invoice.addresses,
      amount: invoice.amount,
      description: invoice.description,
      createdAt: invoice.createdAt,
      expiresAt: invoice.expiresAt,
      success: true,
      error: null,
    ));
    
    print('Invoice ${invoice.invoiceId} finalized with ${invoice.addresses.length} address(es)');
  }

  /// Handle invoice lookup request
  Future<void> _handleCheckInvoice(CheckInvoiceMessage msg) async {
    final invoice = _invoices[msg.invoiceId];
    
    if (invoice == null) {
      context.sender?.tell(InvoiceDetailsResponse(
        invoiceId: msg.invoiceId,
        amount: BigInt.zero,
        status: InvoiceStatus.cancelled,
        createdAt: DateTime.now(),
        found: false,
        error: 'Invoice not found',
      ));
      return;
    }
    
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
  }

  /// Mark invoice as paid
  Future<void> _handleMarkInvoicePaid(MarkInvoicePaidMessage msg) async {
    final invoice = _invoices[msg.invoiceId];
    
    if (invoice == null) {
      print('Cannot mark non-existent invoice ${msg.invoiceId} as paid');
      return;
    }
    
    if (invoice.status == InvoiceStatus.paid) {
      print('Invoice ${msg.invoiceId} already marked as paid');
      return;
    }
    
    // Update invoice status
    invoice.status = InvoiceStatus.paid;
    invoice.paidAt = msg.paidAt;
    invoice.paymentTxid = msg.txid;
    invoice.amountReceived = msg.amountReceived;
    
    // Persist update to storage
    if (_storage != null) {
      try {
        await _storage.updateInvoiceStatus(
          msg.invoiceId,
          InvoiceStatus.paid,
          txid: msg.txid,
          amountReceived: msg.amountReceived,
          paidAt: msg.paidAt,
        );
      } catch (e) {
        print('Warning: Failed to persist invoice update: $e');
      }
    }
    
    // Notify sender
    context.sender?.tell(InvoiceStatusMessage(
      invoiceId: invoice.invoiceId,
      status: InvoiceStatus.paid,
      paidAt: invoice.paidAt,
      txid: invoice.paymentTxid,
      statusMessage: 'Payment received: ${msg.amountReceived} satoshis',
    ));
    
    print('Invoice ${msg.invoiceId} marked as paid: ${msg.txid}');
  }

  /// Cancel an invoice
  Future<void> _handleCancelInvoice(CancelInvoiceMessage msg) async {
    final invoice = _invoices[msg.invoiceId];
    
    if (invoice == null) {
      print('Cannot cancel non-existent invoice ${msg.invoiceId}');
      return;
    }
    
    if (invoice.status == InvoiceStatus.paid) {
      print('Cannot cancel paid invoice ${msg.invoiceId}');
      context.sender?.tell(InvoiceStatusMessage(
        invoiceId: invoice.invoiceId,
        status: invoice.status,
        statusMessage: 'Cannot cancel paid invoice',
      ));
      return;
    }
    
    invoice.status = InvoiceStatus.cancelled;
    
    // Persist update to storage
    if (_storage != null) {
      try {
        await _storage.updateInvoiceStatus(msg.invoiceId, InvoiceStatus.cancelled);
      } catch (e) {
        print('Warning: Failed to persist invoice cancellation: $e');
      }
    }
    
    context.sender?.tell(InvoiceStatusMessage(
      invoiceId: invoice.invoiceId,
      status: InvoiceStatus.cancelled,
      statusMessage: msg.reason ?? 'Invoice cancelled',
    ));
    
    print('Invoice ${msg.invoiceId} cancelled: ${msg.reason ?? "no reason"}');
  }

  /// List invoices
  Future<void> _handleListInvoices(ListInvoicesMessage msg) async {
    var invoices = _invoices.values;
    
    // Filter by wallet if specified
    if (msg.walletId != null) {
      invoices = invoices.where((inv) => inv.walletId == msg.walletId);
    }
    
    // Filter by status if specified
    if (msg.filterStatus != null) {
      invoices = invoices.where((inv) => inv.status == msg.filterStatus);
    }
    
    final results = invoices.map((inv) => InvoiceDetailsResponse(
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
    )).toList();
    
    context.sender?.tell(InvoicesListMessage(results));
  }

  /// Check if an address belongs to any invoice
  String? getInvoiceIdForAddress(String address) {
    return _addressToInvoice[address];
  }

  /// Get invoice by ID
  Invoice? getInvoice(String invoiceId) {
    return _invoices[invoiceId];
  }

  /// Start periodic expiration check
  void _startExpirationTimer() {
    _expirationTimer = Timer.periodic(const Duration(minutes: 5), (_) {
      _checkExpiredInvoices();
    });
  }

  /// Check and expire old invoices
  Future<void> _checkExpiredInvoices() async {
    final now = DateTime.now();
    final expiredIds = <String>[];
    
    for (final invoice in _invoices.values) {
      if (invoice.status == InvoiceStatus.pending &&
          invoice.expiresAt != null &&
          now.isAfter(invoice.expiresAt!)) {
        expiredIds.add(invoice.invoiceId);
      }
    }
    
    for (final invoiceId in expiredIds) {
      final invoice = _invoices[invoiceId]!;
      invoice.status = InvoiceStatus.expired;
      
      // Persist update to storage
      if (_storage != null) {
        try {
          await _storage.updateInvoiceStatus(invoiceId, InvoiceStatus.expired);
        } catch (e) {
          print('Warning: Failed to persist invoice expiration: $e');
        }
      }
      
      print('Invoice $invoiceId expired');
    }
  }

  /// Send error response based on message type
  void _sendErrorResponse(dynamic message, String error) {
    if (message is CreateInvoiceMessage) {
      context.sender?.tell(InvoiceCreatedMessage(
        invoiceId: '',
        walletId: message.walletId,
        addresses: [],
        amount: message.amount,
        createdAt: DateTime.now(),
        success: false,
        error: error,
      ));
    }
  }

  @override
  void postStop() {
    _expirationTimer?.cancel();
    print('InvoiceManagerActor stopped');
  }
}

/// Internal class to track invoices being created
class _PendingInvoice {
  final String invoiceId;
  final String walletId;
  final BigInt amount;
  final String? description;
  final DateTime createdAt;
  final DateTime? expiresAt;
  final int numberOfAddresses;
  final ActorRef? originalSender;
  final Map<String, dynamic>? metadata;
  final List<String> addresses = [];

  _PendingInvoice({
    required this.invoiceId,
    required this.walletId,
    required this.amount,
    this.description,
    required this.createdAt,
    this.expiresAt,
    required this.numberOfAddresses,
    this.originalSender,
    this.metadata,
  });
}

/// Invoice data model
class Invoice {
  final String invoiceId;
  final String walletId;
  final List<String> addresses;
  final BigInt amount;
  final String? description;
  InvoiceStatus status;
  final DateTime createdAt;
  final DateTime? expiresAt;
  DateTime? paidAt;
  String? paymentTxid;
  BigInt? amountReceived;
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

  Map<String, dynamic> toJson() => {
    'invoiceId': invoiceId,
    'walletId': walletId,
    'addresses': addresses,
    'amount': amount.toString(),
    'description': description,
    'status': status.toString(),
    'createdAt': createdAt.toIso8601String(),
    'expiresAt': expiresAt?.toIso8601String(),
    'paidAt': paidAt?.toIso8601String(),
    'paymentTxid': paymentTxid,
    'amountReceived': amountReceived?.toString(),
    'metadata': metadata,
  };
}

