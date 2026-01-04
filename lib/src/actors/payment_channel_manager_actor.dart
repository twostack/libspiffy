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

import '../core/payment_channel_aggregate.dart';
import '../core/channel_commands.dart';
import '../core/wallet_commands.dart';
import '../core/wallet_events.dart';
import '../services/crypto_service.dart';
import '../services/payment_channel_builder.dart';
import 'payment_channel_messages.dart';
import 'wallet_messages.dart';

/// Payment Channel Manager - Orchestrates all channel operations
class PaymentChannelManagerActor extends Actor {
  final ActorRef _walletManager;
  final EventStore _eventStore;
  final CryptoService _cryptoService;
  final dartsv.NetworkType _networkType;
  
  /// Map of active channel aggregates: channelId -> ActorRef
  final Map<String, ActorRef> _channelAggregates = {};
  
  /// Track pending multisig signing requests: channelId -> context
  final Map<String, ({ActorRef? sender, String refundTxHex, int lockTimeUnix})> _pendingSignatures = {};

  PaymentChannelManagerActor({
    required ActorRef walletManager,
    required EventStore eventStore,
    required CryptoService cryptoService,
    dartsv.NetworkType networkType = dartsv.NetworkType.TEST,
  }  )  : _walletManager = walletManager,
        _eventStore = eventStore,
        _cryptoService = cryptoService,
        _networkType = networkType;

  @override
  void preStart() {
    print('[PaymentChannelManager] Started');
  }

  @override
  Future<void> onMessage(dynamic message) async {
    print('[PaymentChannelManager] Received: ${message.runtimeType}');
    
    try {
      switch (message.runtimeType) {
        case InitiateChannelMessage:
          await _handleInitiateChannel(message as InitiateChannelMessage);
          break;
        case AcceptChannelMessage:
          await _handleAcceptChannel(message as AcceptChannelMessage);
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
          print('[PaymentChannelManager] Unknown message type: ${message.runtimeType}');
      }
    } catch (e, stack) {
      print('[PaymentChannelManager] Error handling message: $e');
      print('[PaymentChannelManager] Stack: $stack');
      
      // Send error response to sender if available
      if (context.sender != null) {
        _sendErrorResponse(message, e.toString());
      }
    }
  }

  /// Client initiates a new payment channel
  Future<void> _handleInitiateChannel(InitiateChannelMessage msg) async {
    print('[PaymentChannelManager] Initiating channel: ${msg.channelId}');
    
    // Capture sender immediately (context.sender changes with each new message)
    final originalSender = context.sender;
    
    try {
      // Step 1: Ask WalletManager to generate channel address (with public key)
      print('[PaymentChannelManager]   Step 1: Requesting client address from WalletManager');
      final addressCmd = GenerateAddressCommand(
        walletId: msg.walletId,
        purpose: 'receive',
        includePublicKey: true, // Required for multisig channel setup
        correlationId: msg.channelId,
        label: 'channel-${msg.channelId}',
        metadata: {'context': msg.context ?? 'payment-channel'},
      );
      
      _walletManager.tell(
        WalletCommandMessage(msg.walletId, addressCmd),
        sender: context.self,
      );
      
      // Wait for address generation to complete and events to be persisted
      // Note: In Phase 2 with projections, this will query the read model instead
      await _waitForAggregateResponse();
      
      // Query the event store for the address generation event
      final walletEvents = await _eventStore.getEvents('BitcoinWallet_${msg.walletId}');
      final addressEvent = walletEvents.whereType<AddressGeneratedEvent>().lastWhere(
        (e) => e.getCorrelationId() == msg.channelId,
        orElse: () => throw StateError('Address generation event not found'),
      );
      
      if (addressEvent.publicKeyHex == null) {
        throw StateError('Public key not included in address generation event');
      }
      
      print('[PaymentChannelManager]   ✓ Client address generated');
      print('[PaymentChannelManager]     Address: ${addressEvent.address}');
      print('[PaymentChannelManager]     PubKey: ${addressEvent.publicKeyHex}');
      print('[PaymentChannelManager]     Index: ${addressEvent.derivationIndex}');
      
      // Step 2: Get or spawn channel aggregate
      final aggregateRef = await _getOrSpawnChannelAggregate(msg.channelId);
      
      // Step 3: Calculate lock time
      final lockTimeUnix = (DateTime.now().millisecondsSinceEpoch ~/ 1000) +
          msg.lockTimeDurationSeconds;
      
      // Step 4: Send RequestChannelCommand with pre-computed keys
      print('[PaymentChannelManager]   Step 2: Sending RequestChannelCommand to aggregate');
      final requestCmd = RequestChannelCommand(
        channelId: msg.channelId,
        walletId: msg.walletId,
        clientPeerId: msg.clientPeerId,
        serverPeerId: msg.serverPeerId,
        clientPubKeyHex: addressEvent.publicKeyHex!,
        clientAddressB58: addressEvent.address,
        derivationIndex: addressEvent.derivationIndex,
        fundingAmountSats: msg.fundingAmountSats,
        lockTimeDurationSeconds: msg.lockTimeDurationSeconds,
        context: msg.context,
      );
      
      aggregateRef.tell(requestCmd, sender: context.self);
      
      // Wait for ChannelRequestedEvent
      await _waitForAggregateResponse();
      
      print('[PaymentChannelManager]   ✓ Channel request recorded');
      
      // Send success response
      originalSender?.tell(ChannelInitiatedResponse(
        channelId: msg.channelId,
        clientPubKeyHex: addressEvent.publicKeyHex!,
        clientAddressB58: addressEvent.address,
        derivationIndex: addressEvent.derivationIndex,
        lockTimeUnix: lockTimeUnix,
        success: true,
      ));
      
      print('[PaymentChannelManager] ✓ Channel initiated: ${msg.channelId}');
    } catch (e, stack) {
      print('[PaymentChannelManager] ✗ Failed to initiate channel: $e');
      print('[PaymentChannelManager] Stack: $stack');
      
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
    print('[PaymentChannelManager] Accepting channel: ${msg.channelId}');
    
    // Capture sender immediately (context.sender changes with each new message)
    final originalSender = context.sender;
    
    try{
      // Step 1: Ask WalletManager to generate server's channel address (with public key)
      print('[PaymentChannelManager]   Step 1: Requesting server address from WalletManager');
      final addressCmd = GenerateAddressCommand(
        walletId: msg.walletId,
        purpose: 'receive',
        includePublicKey: true, // Required for multisig channel setup
        correlationId: msg.channelId,
        label: 'channel-${msg.channelId}',
        metadata: {'context': msg.context ?? 'payment-channel'},
      );
      
      _walletManager.tell(
        WalletCommandMessage(msg.walletId, addressCmd),
        sender: context.self,
      );
      
      // Wait for address generation
      await _waitForAggregateResponse();
      
      // Query the event store for the address generation event
      final walletEvents = await _eventStore.getEvents('BitcoinWallet_${msg.walletId}');
      final addressEvent = walletEvents.whereType<AddressGeneratedEvent>().lastWhere(
        (e) => e.getCorrelationId() == msg.channelId,
        orElse: () => throw StateError('Address generation event not found'),
      );
      
      if (addressEvent.publicKeyHex == null) {
        throw StateError('Public key not included in address generation event');
      }
      
      print('[PaymentChannelManager]   ✓ Server address generated');
      print('[PaymentChannelManager]     Address: ${addressEvent.address}');
      print('[PaymentChannelManager]     PubKey: ${addressEvent.publicKeyHex}');
      
      // Step 2: Get or spawn channel aggregate
      final aggregateRef = await _getOrSpawnChannelAggregate(msg.channelId);
      
      // Step 3: Send AcceptChannelCommand with pre-computed keys
      print('[PaymentChannelManager]   Step 2: Sending AcceptChannelCommand to aggregate');
      final acceptCmd = AcceptChannelCommand(
        channelId: msg.channelId,
        walletId: msg.walletId,
        clientPeerId: msg.clientPeerId,
        clientPubKeyHex: msg.clientPubKeyHex,
        clientAddressB58: msg.clientAddressB58,
        serverPubKeyHex: addressEvent.publicKeyHex!,
        serverAddressB58: addressEvent.address,
        derivationIndex: addressEvent.derivationIndex,
        fundingAmountSats: msg.fundingAmountSats,
        lockTimeUnix: msg.lockTimeUnix,
        context: msg.context,
      );
      
      aggregateRef.tell(acceptCmd, sender: context.self);
      
      await _waitForAggregateResponse();
      
      print('[PaymentChannelManager]   ✓ Channel accepted');
      
      // Return server's public key and address
      // Refund TX building and signing happens in separate steps
      originalSender?.tell(ChannelAcceptedResponse(
        channelId: msg.channelId,
        serverPubKeyHex: addressEvent.publicKeyHex!,
        serverAddressB58: addressEvent.address,
        derivationIndex: addressEvent.derivationIndex,
        success: true,
      ));
      
      print('[PaymentChannelManager] ✓ Channel accepted: ${msg.channelId}');
    } catch (e, stack) {
      print('[PaymentChannelManager] ✗ Failed to accept channel: $e');
      print('[PaymentChannelManager] Stack: $stack');
      
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

  /// Build refund transaction (client side, step 3)
  Future<void> _handleBuildRefundTransaction(BuildRefundTransactionMessage msg) async {
    print('[PaymentChannelManager] Building refund transaction for: ${msg.channelId}');
    
    // Capture sender immediately
    final originalSender = context.sender;
    
    try {
      // Step 1: Get the channel aggregate
      final aggregateRef = _channelAggregates[msg.channelId];
      if (aggregateRef == null) {
        throw StateError('Channel aggregate not found: ${msg.channelId}');
      }
      
      // Step 2: Build the refund transaction using PaymentChannelBuilder
      print('[PaymentChannelManager]   Building refund TX...');
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
      
      print('[PaymentChannelManager]   ✓ Refund TX built');
      print('[PaymentChannelManager]     TX ID: ${refundTxResult.transaction.id}');
      
      // Step 3: Send RequestRefundSignatureCommand to aggregate
      // Note: We don't have the server signature yet - that comes from P2P
      // For now, we just return the unsigned refund TX
      
      originalSender?.tell(RefundTransactionBuiltResponse(
        channelId: msg.channelId,
        refundTxHex: refundTxResult.transactionHex,
        success: true,
      ));
      
      print('[PaymentChannelManager] ✓ Refund transaction built: ${msg.channelId}');
    } catch (e, stack) {
      print('[PaymentChannelManager] ✗ Failed to build refund transaction: $e');
      print('[PaymentChannelManager] Stack: $stack');
      
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
    print('[PaymentChannelManager] Signing refund transaction for: ${msg.channelId}');
    
    // Capture sender immediately
    final originalSender = context.sender;
    
    try {
      // Step 1: Get the channel aggregate
      final aggregateRef = _channelAggregates[msg.channelId];
      if (aggregateRef == null) {
        throw StateError('Channel aggregate not found: ${msg.channelId}');
      }
      
      // Step 2: Build the redeem script (2-of-2 multisig)
      print('[PaymentChannelManager]   Building multisig redeem script...');
      final clientPubKey = dartsv.SVPublicKey.fromHex(msg.clientPubKeyHex);
      final serverPubKey = dartsv.SVPublicKey.fromHex(msg.serverPubKeyHex);
      
      final lockBuilder = dartsv.P2MSLockBuilder(
        [clientPubKey, serverPubKey],
        2,
        sorting: true, // BIP67 lexicographical sorting
      );
      final redeemScript = lockBuilder.getScriptPubkey();
      
      print('[PaymentChannelManager]   Redeem script: ${redeemScript.toHex()}');
      
      // Step 3: Ask WalletManager to sign the refund transaction
      print('[PaymentChannelManager]   Requesting signature from WalletManager...');
      
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
      _pendingSignatures[msg.channelId] = (
        sender: originalSender,
        refundTxHex: msg.refundTxHex,
        lockTimeUnix: msg.lockTimeUnix,
      );
      
      // Send signing command - response will arrive via MultisigTransactionSignedResponse
      _walletManager.tell(
        WalletCommandMessage(msg.walletId, signCmd),
        sender: context.self,
      );
      
      print('[PaymentChannelManager]   Signature request sent to WalletManager');
    } catch (e, stack) {
      print('[PaymentChannelManager] ✗ Failed to sign refund transaction: $e');
      print('[PaymentChannelManager] Stack: $stack');
      
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
    print('[PaymentChannelManager] Received multisig signature response');
    
    // Extract channel ID from transaction ID (format: "refund-{channelId}")
    final channelId = response.originalTransactionId?.replaceFirst('refund-', '');
    if (channelId == null || channelId.isEmpty) {
      print('[PaymentChannelManager] ✗ Invalid transaction ID in response');
      return;
    }
    
    // Look up pending signature request
    final pending = _pendingSignatures.remove(channelId);
    if (pending == null) {
      print('[PaymentChannelManager] ✗ No pending signature found for channel: $channelId');
      return;
    }
    
    try {
      if (!response.success) {
        throw StateError(response.error ?? 'Signature failed');
      }
      
      print('[PaymentChannelManager]   ✓ Signature received: ${response.signatureHex}');
      
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
      
      aggregateRef.tell(requestRefundSigCmd, sender: context.self);
      await _waitForAggregateResponse();
      
      // Send success response to original sender
      pending.sender?.tell(RefundTransactionSignedResponse(
        channelId: channelId,
        serverSignatureHex: response.signatureHex,
        success: true,
      ));
      
      print('[PaymentChannelManager] ✓ Refund transaction signed: $channelId');
    } catch (e, stack) {
      print('[PaymentChannelManager] ✗ Failed to complete refund signing: $e');
      print('[PaymentChannelManager] Stack: $stack');
      
      pending.sender?.tell(RefundTransactionSignedResponse(
        channelId: channelId,
        serverSignatureHex: '',
        success: false,
        error: e.toString(),
      ));
    }
  }

  /// Record server's refund signature (client receives via P2P)
  Future<void> _handleRecordRefundSignature(RecordRefundSignatureMessage msg) async {
    print('[PaymentChannelManager] Recording refund signature for channel: ${msg.channelId}');
    
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
      
      originalSender?.tell(RefundSignatureRecordedResponse(
        channelId: msg.channelId,
        success: true,
      ));
      
      print('[PaymentChannelManager] ✓ Refund signature recorded: ${msg.channelId}');
    } catch (e) {
      print('[PaymentChannelManager] ✗ Failed to record refund signature: $e');
      
      originalSender?.tell(RefundSignatureRecordedResponse(
        channelId: msg.channelId,
        success: false,
        error: e.toString(),
      ));
    }
  }

  /// Finalize channel opening after funding TX is broadcast
  Future<void> _handleOpenChannel(OpenChannelMessage msg) async {
    print('[PaymentChannelManager] Opening channel: ${msg.channelId}');
    
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
      
      originalSender?.tell(ChannelOpenedResponse(
        channelId: msg.channelId,
        success: true,
      ));
      
      print('[PaymentChannelManager] ✓ Channel opened: ${msg.channelId}');
    } catch (e) {
      print('[PaymentChannelManager] ✗ Failed to open channel: $e');
      
      originalSender?.tell(ChannelOpenedResponse(
        channelId: msg.channelId,
        success: false,
        error: e.toString(),
      ));
    }
  }

  /// Client records a payment
  Future<void> _handleRecordPayment(RecordPaymentMessage msg) async {
    print('[PaymentChannelManager] Recording payment on channel: ${msg.channelId}');
    print('[PaymentChannelManager]   Amount: ${msg.amountSats} sats');
    
    // For Phase 1, this is simplified - full implementation requires:
    // 1. Query current channel state
    // 2. Build payment transaction
    // 3. Sign transaction
    // 4. Send RecordPaymentCommand
    
    throw UnimplementedError(
      'RecordPayment requires channel state query and TX building. '
      'Will be implemented in Phase 2 with projections.',
    );
  }

  /// Server acknowledges a payment
  Future<void> _handleAcknowledgePayment(AcknowledgePaymentMessage msg) async {
    print('[PaymentChannelManager] Acknowledging payment on channel: ${msg.channelId}');
    
    // For Phase 1, this is simplified - full implementation requires:
    // 1. Verify payment TX
    // 2. Sign payment TX as server
    // 3. Combine signatures
    // 4. Send AcknowledgePaymentCommand
    
    throw UnimplementedError(
      'AcknowledgePayment requires TX signing and combination. '
      'Will be implemented in Phase 2 with projections.',
    );
  }

  /// Close a channel
  Future<void> _handleCloseChannel(CloseChannelMessage msg) async {
    print('[PaymentChannelManager] Closing channel: ${msg.channelId}');
    
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
      
      originalSender?.tell(ChannelClosedResponse(
        channelId: msg.channelId,
        success: true,
      ));
      
      print('[PaymentChannelManager] ✓ Channel closed: ${msg.channelId}');
    } catch (e) {
      print('[PaymentChannelManager] ✗ Failed to close channel: $e');
      
      originalSender?.tell(ChannelClosedResponse(
        channelId: msg.channelId,
        success: false,
        error: e.toString(),
      ));
    }
  }

  /// Query channel state
  Future<void> _handleQueryChannelState(QueryChannelStateMessage msg) async {
    print('[PaymentChannelManager] Querying channel state: ${msg.channelId}');
    
    // For Phase 1, this is simplified - full implementation requires projections
    throw UnimplementedError(
      'QueryChannelState requires projections. '
      'Will be implemented in Phase 2.',
    );
  }

  /// Get or spawn a channel aggregate actor
  Future<ActorRef> _getOrSpawnChannelAggregate(String channelId) async {
    if (_channelAggregates.containsKey(channelId)) {
      print('[PaymentChannelManager]   Using existing aggregate for: $channelId');
      return _channelAggregates[channelId]!;
    }
    
    print('[PaymentChannelManager]   Spawning new aggregate for: $channelId');
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

  /// Wait for aggregate response (simplified - just a delay for event propagation)
  Future<void> _waitForAggregateResponse() async {
    // Simple delay to allow events to propagate and be persisted
    // In production with projections, this would query the read model
    await Future.delayed(Duration(milliseconds: 100));
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

