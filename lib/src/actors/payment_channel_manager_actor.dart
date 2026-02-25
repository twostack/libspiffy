/// Payment Channel Manager Actor
/// 
/// Orchestrates payment channel operations by coordinating between:
/// - WalletManager (for cryptographic operations and key management)
/// - PaymentChannelAggregate (for domain logic and event sourcing)
/// - PaymentChannelBuilder (for transaction construction)
/// 
/// This actor provides a high-level interface for payment channel operations,
/// hiding the complexity of the multi-step coordination required.

import 'dart:async';

import 'package:dactor/dactor.dart';
import 'package:eventador/eventador.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:logging/logging.dart';

import '../core/payment_channel_aggregate.dart';
import '../core/channel_commands.dart';
import '../core/channel_events.dart';
import '../core/wallet_commands.dart';
import '../services/crypto_service.dart';
import '../services/payment_channel_builder.dart';
import 'payment_channel_messages.dart';
import 'wallet_messages.dart';

/// Payment Channel Manager - Orchestrates all channel operations
class PaymentChannelManagerActor extends Actor {
  final _log = Logger('PaymentChannelManagerActor');
  final ActorRef _walletManager;
  final EventStore _eventStore;
  final CryptoService _cryptoService;
  final dartsv.NetworkType _networkType;
  late final PaymentChannelBuilder _channelBuilder;
  
  /// Optional callback to broadcast channel events to external subscribers
  /// (e.g., P2P adapters that need to react to channel state changes)
  final void Function(ChannelEvent)? _eventBroadcaster;
  
  /// Map of active channel aggregates: channelId -> ActorRef
  final Map<String, ActorRef> _channelAggregates = {};
  
  /// Track pending refund signing requests: channelId -> context
  final Map<String, ({ActorRef? sender, String refundTxHex, int lockTimeUnix})> _pendingRefundSignatures = {};
  
  /// Track pending payment signing requests: correlationId -> context
  final Map<String, _PaymentSignatureContext> _pendingPaymentSignatures = {};

  PaymentChannelManagerActor({
    required ActorRef walletManager,
    required EventStore eventStore,
    required CryptoService cryptoService,
    dartsv.NetworkType networkType = dartsv.NetworkType.TEST,
    void Function(ChannelEvent)? eventBroadcaster,
  })  : _walletManager = walletManager,
        _eventStore = eventStore,
        _cryptoService = cryptoService,
        _networkType = networkType,
        _eventBroadcaster = eventBroadcaster {
    _channelBuilder = PaymentChannelBuilder(cryptoService: cryptoService);
  }

  @override
  void preStart() {
  }

  /// Broadcast events to external subscribers (e.g., P2P adapters)
  void _broadcastEvents(dynamic response) {
    if (_eventBroadcaster == null) return;
    
    if (response is List) {
      for (final event in response) {
        if (event is ChannelEvent) {
          _eventBroadcaster(event);
        }
      }
    } else if (response is ChannelEvent) {
      _eventBroadcaster(response);
    }
  }

  @override
  Future<void> onMessage(dynamic message) async {
    
    try {
      switch (message.runtimeType) {
        case InitiateChannelMessage:
          await _handleInitiateChannel(message as InitiateChannelMessage);
          break;
        case AcceptChannelMessage:
          await _handleAcceptChannel(message as AcceptChannelMessage);
          break;
        case RecordServerAcceptanceMessage:
          await _handleRecordServerAcceptance(message as RecordServerAcceptanceMessage);
          break;
        case BuildRefundTransactionMessage:
          await _handleBuildRefundTransaction(message as BuildRefundTransactionMessage);
          break;
        case SignRefundTransactionMessage:
          await _handleSignRefundTransaction(message as SignRefundTransactionMessage);
          break;
        case MultisigTransactionSignedResponse:
          await _handleMultisigSignedResponse(message as MultisigTransactionSignedResponse);
          break;
        case RecordRefundSignatureMessage:
          await _handleRecordRefundSignature(message as RecordRefundSignatureMessage);
          break;
        case OpenChannelMessage:
          await _handleOpenChannel(message as OpenChannelMessage);
          break;
        case RecordPaymentMessage:
          await _handleRecordPayment(message as RecordPaymentMessage);
          break;
        case AcknowledgePaymentMessage:
          await _handleAcknowledgePayment(message as AcknowledgePaymentMessage);
          break;
        case CloseChannelMessage:
          await _handleCloseChannel(message as CloseChannelMessage);
          break;
        case QueryChannelStateMessage:
          await _handleQueryChannelState(message as QueryChannelStateMessage);
          break;
        default:
      }
    } catch (e, stack) {
      
      // Send error response to sender if available
      if (context.sender != null) {
        _sendErrorResponse(message, e.toString());
      }
    }
  }

  /// Client initiates a new payment channel
  Future<void> _handleInitiateChannel(InitiateChannelMessage msg) async {
    
    // Capture sender immediately (context.sender changes with each new message)
    final originalSender = context.sender;
    
    try {
      // Step 1: Ask WalletManager to generate channel address (with public key)
      final addressCmd = GenerateAddressCommand(
        walletId: msg.walletId,
        purpose: 'receive',
        includePublicKey: true, // Required for multisig channel setup
        correlationId: msg.channelId,
        label: 'channel-${msg.channelId}',
        metadata: {'context': msg.context ?? 'payment-channel'},
      );
      
      // Use ask() pattern to wait for actual response
      final addressResponse = await _walletManager.ask(
        WalletCommandMessage(msg.walletId, addressCmd),
      );
      
      
      // Handle AddressGeneratedResponse from WalletManager
      if (addressResponse is! AddressGeneratedResponse) {
        throw StateError('Unexpected response type: ${addressResponse.runtimeType}');
      }
      
      if (!addressResponse.success) {
        throw StateError('Address generation failed: ${addressResponse.error}');
      }
      
      if (addressResponse.publicKeyHex == null) {
        throw StateError('Public key not included in address generation response');
      }
      
      
      // Step 2: Get or spawn channel aggregate
      final aggregateRef = await _getOrSpawnChannelAggregate(msg.channelId);
      
      // Step 3: Calculate lock time
      final lockTimeUnix = (DateTime.now().millisecondsSinceEpoch ~/ 1000) +
          msg.lockTimeDurationSeconds;
      
      // Step 4: Send RequestChannelCommand with pre-computed keys
      final requestCmd = RequestChannelCommand(
        channelId: msg.channelId,
        walletId: msg.walletId,
        clientPeerId: msg.clientPeerId,
        serverPeerId: msg.serverPeerId,
        clientPubKeyHex: addressResponse.publicKeyHex!,
        clientAddressB58: addressResponse.address,
        derivationIndex: addressResponse.derivationIndex,
        fundingAmountSats: msg.fundingAmountSats,
        lockTimeDurationSeconds: msg.lockTimeDurationSeconds,
        context: msg.context,
      );
      
      // Send command and wait for response (events)
      final response = await aggregateRef.ask(requestCmd);
      
      // Check if command succeeded
      if (response is! List || response.isEmpty) {
        throw StateError('Command failed: no events emitted');
      }
      
      // Broadcast events to external subscribers (P2P adapter)
      _broadcastEvents(response);
      
      
      // Send success response
      originalSender?.tell(ChannelInitiatedResponse(
        channelId: msg.channelId,
        clientPubKeyHex: addressResponse.publicKeyHex!,
        clientAddressB58: addressResponse.address,
        derivationIndex: addressResponse.derivationIndex,
        lockTimeUnix: lockTimeUnix,
        success: true,
      ));
      
    } catch (e, stack) {
      
      originalSender?.tell(ChannelInitiatedResponse(
        channelId: msg.channelId,
        clientPubKeyHex: '',
        clientAddressB58: '',
        derivationIndex: 0,
        lockTimeUnix: 0,
        success: false,
        error: e.toString(),
      ));
    }
  }

  /// Server accepts a channel request
  Future<void> _handleAcceptChannel(AcceptChannelMessage msg) async {
    
    // Capture sender immediately (context.sender changes with each new message)
    final originalSender = context.sender;
    
    try{
      // Step 1: Ask WalletManager to generate server's channel address (with public key)
      final addressCmd = GenerateAddressCommand(
        walletId: msg.walletId,
        purpose: 'receive',
        includePublicKey: true, // Required for multisig channel setup
        correlationId: msg.channelId,
        label: 'channel-${msg.channelId}',
        metadata: {'context': msg.context ?? 'payment-channel'},
      );
      
      // Use ask() pattern to wait for actual response
      final addressResponse = await _walletManager.ask(
        WalletCommandMessage(msg.walletId, addressCmd),
      );
      
      
      // Handle AddressGeneratedResponse from WalletManager
      if (addressResponse is! AddressGeneratedResponse) {
        throw StateError('Unexpected response type: ${addressResponse.runtimeType}');
      }
      
      if (!addressResponse.success) {
        throw StateError('Address generation failed: ${addressResponse.error}');
      }
      
      if (addressResponse.publicKeyHex == null) {
        throw StateError('Public key not included in address generation response');
      }
      
      
      // Step 2: Get or spawn channel aggregate
      final aggregateRef = await _getOrSpawnChannelAggregate(msg.channelId);
      
      // Step 3: Send AcceptChannelCommand with pre-computed keys
      final acceptCmd = AcceptChannelCommand(
        channelId: msg.channelId,
        walletId: msg.walletId,
        clientPeerId: msg.clientPeerId,
        clientPubKeyHex: msg.clientPubKeyHex,
        clientAddressB58: msg.clientAddressB58,
        serverPubKeyHex: addressResponse.publicKeyHex!,
        serverAddressB58: addressResponse.address,
        derivationIndex: addressResponse.derivationIndex,
        fundingAmountSats: msg.fundingAmountSats,
        lockTimeUnix: msg.lockTimeUnix,
        context: msg.context,
      );
      
      // Send command and wait for response (events)
      final acceptResponse = await aggregateRef.ask(acceptCmd);
      
      // Check if command succeeded
      if (acceptResponse is! List || acceptResponse.isEmpty) {
        throw StateError('Command failed: no events emitted');
      }
      
      // Broadcast events to external subscribers (P2P adapter)
      _broadcastEvents(acceptResponse);
      
      
      // Return server's public key and address
      // Refund TX building and signing happens in separate steps
      originalSender?.tell(ChannelAcceptedResponse(
        channelId: msg.channelId,
        serverPubKeyHex: addressResponse.publicKeyHex!,
        serverAddressB58: addressResponse.address,
        derivationIndex: addressResponse.derivationIndex,
        success: true,
      ));
      
    } catch (e, stack) {
      
      originalSender?.tell(ChannelAcceptedResponse(
        channelId: msg.channelId,
        serverPubKeyHex: '',
        serverAddressB58: '',
        derivationIndex: 0,
        success: false,
        error: e.toString(),
      ));
    }
  }

  /// Client records server's acceptance (stores server pubkey/address in aggregate)
  Future<void> _handleRecordServerAcceptance(RecordServerAcceptanceMessage msg) async {
    
    try {
      // Get or spawn the channel aggregate
      final aggregateRef = await _getOrSpawnChannelAggregate(msg.channelId);
      
      // Send command to aggregate
      final cmd = RecordServerAcceptanceCommand(
        channelId: msg.channelId,
        serverPubKeyHex: msg.serverPubKeyHex,
        serverAddressB58: msg.serverAddressB58,
      );
      
      final response = await aggregateRef.ask(cmd);
      
      // Check if command succeeded
      if (response is Map && response['success'] == false) {
        throw StateError(response['error'] ?? 'Command failed');
      }
      
      // Broadcast events
      _broadcastEvents(response);
      
    } catch (e, stack) {
      _log.warning('Failed to record server acceptance: $e');
    }
  }

  /// Build refund transaction (client side, step 3)
  Future<void> _handleBuildRefundTransaction(BuildRefundTransactionMessage msg) async {
    
    // Capture sender immediately
    final originalSender = context.sender;
    
    try {
      // Step 1: Get the channel aggregate
      final aggregateRef = _channelAggregates[msg.channelId];
      if (aggregateRef == null) {
        throw StateError('Channel aggregate not found: ${msg.channelId}');
      }
      
      // Step 2: Build the refund transaction using PaymentChannelBuilder
      final builder = PaymentChannelBuilder(
        cryptoService: _cryptoService,
        networkType: _networkType,
      );
      
      // Convert hex strings to dartsv objects
      final clientPubKey = dartsv.SVPublicKey.fromHex(msg.clientPubKeyHex);
      final serverPubKey = dartsv.SVPublicKey.fromHex(msg.serverPubKeyHex);
      final clientAddress = dartsv.Address.fromBase58(msg.clientAddressB58);
      
      final refundTxResult = await builder.buildRefundTransaction(
        fundingTxId: msg.fundingTxId,
        fundingOutputIndex: msg.fundingOutputIndex,
        fundingAmountSats: msg.fundingAmountSats,
        clientPubKey: clientPubKey,
        serverPubKey: serverPubKey,
        clientAddress: clientAddress,
        lockTimeUnix: msg.lockTimeUnix,
      );
      
      
      // Step 3: Send RequestRefundSignatureCommand to aggregate
      // Note: We don't have the server signature yet - that comes from P2P
      // For now, we just return the unsigned refund TX
      
      originalSender?.tell(RefundTransactionBuiltResponse(
        channelId: msg.channelId,
        refundTxHex: refundTxResult.transactionHex,
        success: true,
      ));
      
    } catch (e, stack) {
      
      originalSender?.tell(RefundTransactionBuiltResponse(
        channelId: msg.channelId,
        refundTxHex: '',
        success: false,
        error: e.toString(),
      ));
    }
  }

  /// Sign refund transaction (server side, step 4)
  Future<void> _handleSignRefundTransaction(SignRefundTransactionMessage msg) async {
    
    // Capture sender immediately
    final originalSender = context.sender;
    
    try {
      // Step 1: Get the channel aggregate
      final aggregateRef = _channelAggregates[msg.channelId];
      if (aggregateRef == null) {
        throw StateError('Channel aggregate not found: ${msg.channelId}');
      }
      
      // Step 2: Build the redeem script (2-of-2 multisig)
      final clientPubKey = dartsv.SVPublicKey.fromHex(msg.clientPubKeyHex);
      final serverPubKey = dartsv.SVPublicKey.fromHex(msg.serverPubKeyHex);
      
      final lockBuilder = dartsv.P2MSLockBuilder(
        [clientPubKey, serverPubKey],
        2,
        sorting: true, // BIP67 lexicographical sorting
      );
      final redeemScript = lockBuilder.getScriptPubkey();
      
      
      // Step 3: Ask WalletManager to sign the refund transaction
      
      final signCmd = SignMultisigTransactionCommand(
        walletId: msg.walletId,
        transactionId: 'refund-${msg.channelId}',
        rawTransaction: msg.refundTxHex,
        derivationIndex: msg.derivationIndex,
        inputIndex: 0, // Refund TX has one input (the funding UTXO)
        prevOutValue: msg.fundingAmountSats.toInt(),
        redeemScriptHex: redeemScript.toHex(),
        sighashType: 0x41, // SIGHASH_ALL | SIGHASH_FORKID
      );
      
      // Store pending signature context for when the response arrives
      _pendingRefundSignatures[msg.channelId] = (
        sender: originalSender,
        refundTxHex: msg.refundTxHex,
        lockTimeUnix: msg.lockTimeUnix,
      );
      
      // Send signing command - response will arrive via MultisigTransactionSignedResponse
      _walletManager.tell(
        WalletCommandMessage(msg.walletId, signCmd),
        sender: context.self,
      );
      
    } catch (e, stack) {
      
      originalSender?.tell(RefundTransactionSignedResponse(
        channelId: msg.channelId,
        serverSignatureHex: '',
        success: false,
        error: e.toString(),
      ));
    }
  }

  /// Handle multisig signature response from WalletManager
  Future<void> _handleMultisigSignedResponse(MultisigTransactionSignedResponse response) async {
    
    final transactionId = response.originalTransactionId ?? '';
    
    // Check if this is a refund signature (format: "refund-{channelId}")
    if (transactionId.startsWith('refund-')) {
      await _handleRefundSignatureResponse(response);
      return;
    }
    
    // Check if this is a payment signature (format: "payment-{channelId}-{sequence}")
    if (transactionId.startsWith('payment-')) {
      final paymentPending = _pendingPaymentSignatures.remove(transactionId);
      if (paymentPending != null) {
        await _handlePaymentSignatureResponse(response, paymentPending);
        return;
      }
    }
    
    // Check if this is a payment acknowledgment (format: "ack-{channelId}-{sequence}")
    if (transactionId.startsWith('ack-')) {
      final ackPending = _pendingPaymentSignatures.remove(transactionId);
      if (ackPending != null) {
        await _handlePaymentSignatureResponse(response, ackPending);
        return;
      }
    }
    
  }
  
  /// Handle refund signature response
  Future<void> _handleRefundSignatureResponse(MultisigTransactionSignedResponse response) async {
    final channelId = response.originalTransactionId?.replaceFirst('refund-', '');
    if (channelId == null || channelId.isEmpty) {
      return;
    }
    
    // Look up pending refund signature request
    final pending = _pendingRefundSignatures.remove(channelId);
    if (pending == null) {
      return;
    }
    
    try {
      if (!response.success) {
        throw StateError(response.error ?? 'Signature failed');
      }
      
      
      // Get channel aggregate and events
      final aggregateRef = _channelAggregates[channelId];
      if (aggregateRef == null) {
        throw StateError('Channel aggregate not found: $channelId');
      }
      
      // Send RequestRefundSignatureCommand to aggregate
      final requestRefundSigCmd = RequestRefundSignatureCommand(
        channelId: channelId,
        fundingTxId: 'pending',
        fundingOutputIndex: 0,
        refundTxHex: pending.refundTxHex,
        lockTimeUnix: pending.lockTimeUnix,
        serverSignatureHex: response.signatureHex,
      );
      
      // Use ask() to get the events back and broadcast them
      final events = await aggregateRef.ask(requestRefundSigCmd);
      
      // Broadcast events to external subscribers (P2P adapter needs RefundCountersignedEvent)
      _broadcastEvents(events);
      
      // Send success response to original sender
      pending.sender?.tell(RefundTransactionSignedResponse(
        channelId: channelId,
        serverSignatureHex: response.signatureHex,
        success: true,
      ));
      
    } catch (e, stack) {
      
      pending.sender?.tell(RefundTransactionSignedResponse(
        channelId: channelId,
        serverSignatureHex: '',
        success: false,
        error: e.toString(),
      ));
    }
  }
  
  /// Handle payment signature response
  Future<void> _handlePaymentSignatureResponse(
    MultisigTransactionSignedResponse response,
    _PaymentSignatureContext pending,
  ) async {
    try {
      if (!response.success) {
        throw StateError(response.error ?? 'Payment signature failed');
      }
      
      
      final aggregateRef = _channelAggregates[pending.channelId];
      if (aggregateRef == null) {
        throw StateError('Channel aggregate not found: ${pending.channelId}');
      }
      
      if (pending.isAcknowledgment) {
        // Server acknowledging payment - combine signatures and send command
        
        final ackCmd = AcknowledgePaymentCommand(
          channelId: pending.channelId,
          amountSats: pending.amountSats,
          paymentTxHex: pending.paymentTxHex,
          clientSignatureHex: pending.clientSignatureHex!,
          serverSignatureHex: response.signatureHex,
          fullySignedPaymentTxHex: '', // Would need to combine sigs - simplified for now
          proposedSequence: pending.sequenceNumber,
          proposedClientBalance: pending.newClientBalance,
          proposedServerBalance: pending.newServerBalance,
        );
        
        final events = await aggregateRef.ask(ackCmd);
        _broadcastEvents(events);
        
        pending.originalSender?.tell(PaymentAcknowledgedResponse(
          channelId: pending.channelId,
          sequenceNumber: pending.sequenceNumber,
          serverSignatureHex: response.signatureHex,
          fullySignedPaymentTxHex: '', // Would need to combine signatures
          success: true,
        ));
        
      } else {
        // Client recording payment - send command with signature
        
        final recordCmd = RecordPaymentCommand(
          channelId: pending.channelId,
          amountSats: pending.amountSats,
          sequenceNumber: pending.sequenceNumber,
          paymentTxHex: pending.paymentTxHex,
          paymentTxId: pending.paymentTxId,
          clientSignatureHex: response.signatureHex,
          newClientBalanceSats: pending.newClientBalance,
          newServerBalanceSats: pending.newServerBalance,
          purpose: pending.purpose,
          invoiceId: pending.invoiceId,
        );
        
        final events = await aggregateRef.ask(recordCmd);
        _broadcastEvents(events);
        
        pending.originalSender?.tell(PaymentRecordedResponse(
          channelId: pending.channelId,
          amountSats: pending.amountSats,
          sequenceNumber: pending.sequenceNumber,
          paymentTxHex: pending.paymentTxHex,
          clientSignatureHex: response.signatureHex,
          newClientBalanceSats: pending.newClientBalance,
          newServerBalanceSats: pending.newServerBalance,
          success: true,
        ));
        
      }
    } catch (e, stack) {
      
      if (pending.isAcknowledgment) {
        pending.originalSender?.tell(PaymentAcknowledgedResponse(
          channelId: pending.channelId,
          success: false,
          error: e.toString(),
        ));
      } else {
        pending.originalSender?.tell(PaymentRecordedResponse(
          channelId: pending.channelId,
          amountSats: pending.amountSats,
          sequenceNumber: 0,
          paymentTxHex: '',
          clientSignatureHex: '',
          newClientBalanceSats: BigInt.zero,
          newServerBalanceSats: BigInt.zero,
          success: false,
          error: e.toString(),
        ));
      }
    }
  }

  /// Record server's refund signature (client receives via P2P)
  Future<void> _handleRecordRefundSignature(RecordRefundSignatureMessage msg) async {
    
    // Capture sender immediately
    final originalSender = context.sender;
    
    try {
      final aggregateRef = _channelAggregates[msg.channelId];
      if (aggregateRef == null) {
        throw StateError('Channel aggregate not found: ${msg.channelId}');
      }
      
      // Send ProvideRefundSignatureCommand to aggregate
      final provideCmd = ProvideRefundSignatureCommand(
        channelId: msg.channelId,
        serverSignatureHex: msg.serverSignatureHex,
      );
      
      // Send command and wait for response
      final response = await aggregateRef.ask(provideCmd);
      
      // Check if command failed
      if (response is Map && response['success'] == false) {
        throw StateError(response['error'] ?? 'Command failed');
      }
      
      // Check if command succeeded (aggregate sends List<Event> on success)
      if (response is! List || response.isEmpty) {
        throw StateError('Command failed: no events emitted');
      }
      
      // Broadcast events to external subscribers (P2P adapter)
      _broadcastEvents(response);
      
      originalSender?.tell(RefundSignatureRecordedResponse(
        channelId: msg.channelId,
        success: true,
      ));
      
    } catch (e) {
      
      originalSender?.tell(RefundSignatureRecordedResponse(
        channelId: msg.channelId,
        success: false,
        error: e.toString(),
      ));
    }
  }

  /// Finalize channel opening after funding TX is broadcast
  Future<void> _handleOpenChannel(OpenChannelMessage msg) async {
    
    // Capture sender immediately (context.sender changes with each new message)
    final originalSender = context.sender;
    
    try {
      final aggregateRef = _channelAggregates[msg.channelId];
      if (aggregateRef == null) {
        throw StateError('Channel aggregate not found: ${msg.channelId}');
      }
      
      final openCmd = OpenChannelCommand(
        channelId: msg.channelId,
        fundingTxId: msg.fundingTxId,
        fundingOutputIndex: msg.fundingOutputIndex,
        fundingTxHex: msg.fundingTxHex,
      );
      
      // Send command and wait for response
      final response = await aggregateRef.ask(openCmd);
      
      // Check if command failed (aggregate sends Map with error on failure)
      if (response is Map && response['success'] == false) {
        throw StateError(response['error'] ?? 'Command failed');
      }
      
      // Check if command succeeded (aggregate sends List<Event> on success)
      if (response is! List || response.isEmpty) {
        throw StateError('Command failed: no events emitted');
      }
      
      // Broadcast events to external subscribers (P2P adapter)
      _broadcastEvents(response);
      
      originalSender?.tell(ChannelOpenedResponse(
        channelId: msg.channelId,
        success: true,
      ));
      
    } catch (e) {
      
      originalSender?.tell(ChannelOpenedResponse(
        channelId: msg.channelId,
        success: false,
        error: e.toString(),
      ));
    }
  }

  /// Client records a payment
  Future<void> _handleRecordPayment(RecordPaymentMessage msg) async {
    
    final originalSender = context.sender;
    
    try {
      // Step 1: Get aggregate reference
      final aggregateRef = _channelAggregates[msg.channelId];
      if (aggregateRef == null) {
        throw StateError('Channel aggregate not found: ${msg.channelId}');
      }
      
      // Step 2: Query current channel state
      final stateResponse = await aggregateRef.ask(ChannelStateQuery(channelId: msg.channelId));
      
      if (stateResponse is! FullChannelStateResponse || !stateResponse.success) {
        throw StateError('Failed to query channel state');
      }
      
      // Validate channel is open
      if (stateResponse.status != 'open') {
        throw StateError('Channel not open: ${stateResponse.status}');
      }
      
      // Validate sufficient balance
      if (msg.amountSats > stateResponse.clientBalanceSats) {
        throw StateError('Insufficient balance: ${stateResponse.clientBalanceSats} < ${msg.amountSats}');
      }
      
      
      // Step 3: Build payment transaction
      
      // Validate required state fields are present
      if (stateResponse.clientPubKeyHex == null) {
        throw StateError('Channel state missing clientPubKeyHex');
      }
      if (stateResponse.serverPubKeyHex == null) {
        throw StateError('Channel state missing serverPubKeyHex');
      }
      if (stateResponse.clientAddressB58 == null) {
        throw StateError('Channel state missing clientAddressB58');
      }
      if (stateResponse.serverAddressB58 == null) {
        throw StateError('Channel state missing serverAddressB58');
      }
      if (stateResponse.fundingTxId == null) {
        throw StateError('Channel state missing fundingTxId');
      }
      if (stateResponse.fundingOutputIndex == null) {
        throw StateError('Channel state missing fundingOutputIndex');
      }
      if (stateResponse.derivationIndex == null) {
        throw StateError('Channel state missing derivationIndex');
      }
      
      final clientPubKey = dartsv.SVPublicKey.fromHex(stateResponse.clientPubKeyHex!);
      final serverPubKey = dartsv.SVPublicKey.fromHex(stateResponse.serverPubKeyHex!);
      final clientAddress = dartsv.Address.fromBase58(stateResponse.clientAddressB58!);
      final serverAddress = dartsv.Address.fromBase58(stateResponse.serverAddressB58!);
      
      final newSequence = stateResponse.latestSequenceNumber + 1;
      final newClientBalance = stateResponse.clientBalanceSats - msg.amountSats;
      final newServerBalance = stateResponse.serverBalanceSats + msg.amountSats;
      
      final paymentTxResult = await _channelBuilder.buildPaymentTransaction(
        fundingTxId: stateResponse.fundingTxId!,
        fundingOutputIndex: stateResponse.fundingOutputIndex!,
        fundingAmountSats: stateResponse.fundingAmountSats,
        clientPubKey: clientPubKey,
        serverPubKey: serverPubKey,
        clientAddress: clientAddress,
        serverAddress: serverAddress,
        serverAmountSats: newServerBalance,
        sequenceNumber: newSequence,
      );
      
      
      // Step 4: Sign payment transaction using WalletManager
      
      // Use correlation ID as transaction ID for response matching
      final correlationId = 'payment-${msg.channelId}-$newSequence';
      
      final signCmd = SignMultisigTransactionCommand(
        walletId: stateResponse.walletId, // Use wallet ID from channel state, not from message
        transactionId: correlationId, // Correlation ID encoded in transaction ID
        rawTransaction: paymentTxResult.transactionHex,
        inputIndex: 0,
        derivationIndex: stateResponse.derivationIndex!,
        redeemScriptHex: paymentTxResult.multisigScript!.toHex(),
        prevOutValue: stateResponse.fundingAmountSats.toInt(),
        sighashType: dartsv.SighashType.SIGHASH_ALL.value | dartsv.SighashType.SIGHASH_FORKID.value,
      );
      
      // Store pending signature request
      _pendingPaymentSignatures[correlationId] = _PaymentSignatureContext(
        channelId: msg.channelId,
        originalSender: originalSender,
        paymentTxHex: paymentTxResult.transactionHex,
        paymentTxId: paymentTxResult.txid,
        sequenceNumber: newSequence,
        newClientBalance: newClientBalance,
        newServerBalance: newServerBalance,
        amountSats: msg.amountSats,
        purpose: msg.purpose,
        invoiceId: msg.invoiceId,
      );
      
      _walletManager.tell(
        WalletCommandMessage(stateResponse.walletId, signCmd), // Use wallet ID from channel state
        sender: context.self,
      );
      
      
    } catch (e) {
      
      originalSender?.tell(PaymentRecordedResponse(
        channelId: msg.channelId,
        amountSats: msg.amountSats,
        sequenceNumber: 0,
        paymentTxHex: '',
        clientSignatureHex: '',
        newClientBalanceSats: BigInt.zero,
        newServerBalanceSats: BigInt.zero,
        success: false,
        error: e.toString(),
      ));
    }
  }

  /// Server acknowledges a payment
  Future<void> _handleAcknowledgePayment(AcknowledgePaymentMessage msg) async {
    
    final originalSender = context.sender;
    
    try {
      // Step 1: Get aggregate reference
      final aggregateRef = _channelAggregates[msg.channelId];
      if (aggregateRef == null) {
        throw StateError('Channel aggregate not found: ${msg.channelId}');
      }
      
      // Step 2: Query current channel state for validation
      final stateResponse = await aggregateRef.ask(ChannelStateQuery(channelId: msg.channelId));
      
      if (stateResponse is! FullChannelStateResponse || !stateResponse.success) {
        throw StateError('Failed to query channel state');
      }
      
      // Validate channel is open
      if (stateResponse.status != 'open') {
        throw StateError('Channel not open: ${stateResponse.status}');
      }
      
      // Validate sequence is incrementing
      if (msg.proposedSequence != stateResponse.latestSequenceNumber + 1) {
        throw StateError('Invalid sequence: expected ${stateResponse.latestSequenceNumber + 1}, got ${msg.proposedSequence}');
      }
      
      // Step 3: Sign the payment TX as server
      
      // Build redeem script for signing
      final clientPubKey = dartsv.SVPublicKey.fromHex(stateResponse.clientPubKeyHex!);
      final serverPubKey = dartsv.SVPublicKey.fromHex(stateResponse.serverPubKeyHex!);
      final lockBuilder = dartsv.P2MSLockBuilder([clientPubKey, serverPubKey], 2, sorting: true);
      final redeemScript = lockBuilder.getScriptPubkey();
      
      // Use correlation ID as transaction ID for response matching
      final correlationId = 'ack-${msg.channelId}-${msg.proposedSequence}';
      
      final signCmd = SignMultisigTransactionCommand(
        walletId: stateResponse.walletId, // Use wallet ID from channel state, not from message
        transactionId: correlationId, // Correlation ID encoded in transaction ID
        rawTransaction: msg.paymentTxHex,
        inputIndex: 0,
        derivationIndex: stateResponse.derivationIndex!,
        redeemScriptHex: redeemScript.toHex(),
        prevOutValue: stateResponse.fundingAmountSats.toInt(),
        sighashType: dartsv.SighashType.SIGHASH_ALL.value | dartsv.SighashType.SIGHASH_FORKID.value,
      );
      
      // Store pending signature request for acknowledgment
      _pendingPaymentSignatures[correlationId] = _PaymentSignatureContext(
        channelId: msg.channelId,
        originalSender: originalSender,
        paymentTxHex: msg.paymentTxHex,
        paymentTxId: '', // Will be derived
        sequenceNumber: msg.proposedSequence,
        newClientBalance: msg.proposedClientBalance,
        newServerBalance: msg.proposedServerBalance,
        amountSats: msg.proposedServerBalance - stateResponse.serverBalanceSats,
        clientSignatureHex: msg.clientSignatureHex,
        isAcknowledgment: true,
      );
      
      _walletManager.tell(
        WalletCommandMessage(stateResponse.walletId, signCmd), // Use wallet ID from channel state
        sender: context.self,
      );
      
      
    } catch (e) {
      
      originalSender?.tell(PaymentAcknowledgedResponse(
        channelId: msg.channelId,
        success: false,
        error: e.toString(),
      ));
    }
  }

  /// Close a channel
  Future<void> _handleCloseChannel(CloseChannelMessage msg) async {
    
    // Capture sender immediately (context.sender changes with each new message)
    final originalSender = context.sender;
    
    try {
      final aggregateRef = _channelAggregates[msg.channelId];
      if (aggregateRef == null) {
        throw StateError('Channel aggregate not found: ${msg.channelId}');
      }
      
      final closeCmd = CloseChannelCommand(
        channelId: msg.channelId,
        reason: msg.reason,
      );
      
      // Send command and wait for response
      final response = await aggregateRef.ask(closeCmd);
      
      // Check if command failed
      if (response is Map && response['success'] == false) {
        throw StateError(response['error'] ?? 'Command failed');
      }
      
      // Check if command succeeded (aggregate sends List<Event> on success)
      if (response is! List || response.isEmpty) {
        throw StateError('Command failed: no events emitted');
      }
      
      // Broadcast events to external subscribers (P2P adapter)
      _broadcastEvents(response);
      
      originalSender?.tell(ChannelClosedResponse(
        channelId: msg.channelId,
        success: true,
      ));
      
    } catch (e) {
      
      originalSender?.tell(ChannelClosedResponse(
        channelId: msg.channelId,
        success: false,
        error: e.toString(),
      ));
    }
  }

  /// Query channel state
  Future<void> _handleQueryChannelState(QueryChannelStateMessage msg) async {
    
    // For Phase 1, this is simplified - full implementation requires projections
    throw UnimplementedError(
      'QueryChannelState requires projections. '
      'Will be implemented in Phase 2.',
    );
  }

  /// Get or spawn a channel aggregate actor
  Future<ActorRef> _getOrSpawnChannelAggregate(String channelId) async {
    if (_channelAggregates.containsKey(channelId)) {
      return _channelAggregates[channelId]!;
    }
    
    final aggregateRef = await context.system.spawn(
      'channel-$channelId',
      () => PaymentChannelAggregate(
        aggregateId: channelId,
        eventStore: _eventStore,
        cryptoService: _cryptoService,
        networkType: _networkType,
      ),
    );
    
    _channelAggregates[channelId] = aggregateRef;
    return aggregateRef;
  }


  /// Send generic error response based on message type
  void _sendErrorResponse(dynamic message, String error) {
    if (message is InitiateChannelMessage) {
      context.sender?.tell(ChannelInitiatedResponse(
        channelId: message.channelId,
        clientPubKeyHex: '',
        clientAddressB58: '',
        derivationIndex: 0,
        lockTimeUnix: 0,
        success: false,
        error: error,
      ));
    } else if (message is AcceptChannelMessage) {
      context.sender?.tell(ChannelAcceptedResponse(
        channelId: message.channelId,
        serverPubKeyHex: '',
        serverAddressB58: '',
        derivationIndex: 0,
        success: false,
        error: error,
      ));
    }
    // Add other message types as needed
  }
}

/// Context for pending payment signature requests
class _PaymentSignatureContext {
  final String channelId;
  final ActorRef? originalSender;
  final String paymentTxHex;
  final String paymentTxId;
  final int sequenceNumber;
  final BigInt newClientBalance;
  final BigInt newServerBalance;
  final BigInt amountSats;
  final String? purpose;
  final String? invoiceId;
  final String? clientSignatureHex; // For acknowledgments
  final bool isAcknowledgment;

  _PaymentSignatureContext({
    required this.channelId,
    this.originalSender,
    required this.paymentTxHex,
    required this.paymentTxId,
    required this.sequenceNumber,
    required this.newClientBalance,
    required this.newServerBalance,
    required this.amountSats,
    this.purpose,
    this.invoiceId,
    this.clientSignatureHex,
    this.isAcknowledgment = false,
  });
}


