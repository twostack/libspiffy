import 'package:dactor/dactor.dart';
import 'package:eventador/eventador.dart';
import 'package:dartsv/dartsv.dart' as dartsv;

import '../actors/payment_channel_messages.dart';
import '../services/payment_channel_builder.dart';
import '../services/crypto_service.dart';
import 'channel_commands.dart';
import 'channel_events.dart';
import 'channel_state.dart';

/// Payment Channel Aggregate Root
/// 
/// One instance per payment channel, identified by channelId.
/// Handles all channel commands and emits events as the source of truth.
class PaymentChannelAggregate extends AggregateRoot<ChannelState> {
  late final PaymentChannelBuilder _channelBuilder;
  final dartsv.NetworkType _networkType;
  
  // Capture sender for responses (same pattern as BitcoinWalletAggregate)
  final Map<String, ActorRef> _capturedSenders = {};

  PaymentChannelAggregate({
    required String aggregateId, // This is the channelId
    required EventStore eventStore,
    required CryptoService cryptoService,
    dartsv.NetworkType networkType = dartsv.NetworkType.TEST,
  }) : _networkType = networkType,
        super(
          aggregateId: aggregateId,
          aggregateType: 'PaymentChannel',
          eventStore: eventStore,
        ) {
    _channelBuilder = PaymentChannelBuilder(cryptoService: cryptoService);
    registerHandlers();
  }

  @override
  ChannelState createInitialState() => ChannelState.empty(aggregateId);

  @override
  void registerHandlers() {
    // Using override pattern (same as BitcoinWalletAggregate)
  }
  
  @override
  Future<void> onMessage(dynamic message) async {
    // Handle state query before passing to base class
    if (message is ChannelStateQuery) {
      _handleStateQuery(message);
      return;
    }
    
    // Capture sender at start of message processing
    if (message is Command) {
      final sender = context.sender;
      if (sender != null) {
        _capturedSenders[message.commandId] = sender;
      }
    }
    await super.onMessage(message);
  }
  
  /// Handle state query (non-command message)
  void _handleStateQuery(ChannelStateQuery query) {
    final sender = context.sender;
    if (sender == null) {
      return;
    }
    
    
    sender.tell(FullChannelStateResponse(
      channelId: currentState.channelId,
      walletId: currentState.walletId ?? '',
      status: currentState.status.name,
      role: currentState.role?.name,
      clientBalanceSats: currentState.clientBalanceSats,
      serverBalanceSats: currentState.serverBalanceSats,
      latestSequenceNumber: currentState.latestSequenceNumber,
      fundingAmountSats: currentState.fundingAmountSats,
      fundingTxId: currentState.fundingTxId,
      fundingTxHex: currentState.fundingTxHex,
      fundingOutputIndex: currentState.fundingOutputIndex,
      clientPubKeyHex: currentState.clientPubKeyHex,
      serverPubKeyHex: currentState.serverPubKeyHex,
      clientAddressB58: currentState.clientAddressB58,
      serverAddressB58: currentState.serverAddressB58,
      derivationIndex: currentState.derivationIndex,
      lockTimeUnix: currentState.lockTimeUnix,
      success: true,
    ));
  }
  
  @override
  Future<void> onCommandProcessed(Command command, List<Event> events) async {
    await super.onCommandProcessed(command, events);
    
    // Send events back to sender if running in actor system
    final sender = _capturedSenders[command.commandId];
    if (sender != null) {
      // Send the list of events as response wrapped in LocalMessage
      sender.tell(LocalMessage(payload: events));
      // Clean up captured sender
      _capturedSenders.remove(command.commandId);
    }
  }
  
  @override
  Future<void> onCommandFailure(Command command, dynamic error) async {
    await super.onCommandFailure(command, error);
    
    // Send error response to sender if running in actor system
    final sender = _capturedSenders[command.commandId];
    if (sender != null) {
      // Send error wrapped in LocalMessage
      sender.tell(LocalMessage(payload: {
        'success': false,
        'error': error.toString(),
        'commandId': command.commandId,
      }));
      // Clean up captured sender
      _capturedSenders.remove(command.commandId);
    }
  }

  @override
  Future<List<Event>> handleCommand(ChannelState currentState, Command command) async {
    if (command is RequestChannelCommand) {
      return await _handleRequestChannel(currentState, command);
    } else if (command is AcceptChannelCommand) {
      return await _handleAcceptChannel(currentState, command);
    } else if (command is RejectChannelCommand) {
      return _handleRejectChannel(currentState, command);
    } else if (command is RecordServerAcceptanceCommand) {
      return _handleRecordServerAcceptance(currentState, command);
    } else if (command is RequestRefundSignatureCommand) {
      return await _handleRequestRefundSignature(currentState, command);
    } else if (command is ProvideRefundSignatureCommand) {
      return _handleProvideRefundSignature(currentState, command);
    } else if (command is OpenChannelCommand) {
      return _handleOpenChannel(currentState, command);
    } else if (command is RecordPaymentCommand) {
      return await _handleRecordPayment(currentState, command);
    } else if (command is AcknowledgePaymentCommand) {
      return await _handleAcknowledgePayment(currentState, command);
    } else if (command is CloseChannelCommand) {
      return _handleCloseChannel(currentState, command);
    } else if (command is FinalizeCloseCommand) {
      return _handleFinalizeClose(currentState, command);
    } else if (command is ClaimRefundCommand) {
      return _handleClaimRefund(currentState, command);
    }
    throw ArgumentError('Unknown command type: ${command.runtimeType}');
  }

  @override
  void eventHandler(Event event) {
    // Ensure state is initialized before processing events
    ensureStateInitialized();

    if (event is! ChannelEvent) {
      throw ArgumentError('Expected ChannelEvent, got ${event.runtimeType}');
    }

    switch (event.runtimeType) {
      case ChannelRequestedEvent:
        _applyChannelRequested(event as ChannelRequestedEvent);
        break;
      case ChannelAcceptedEvent:
        _applyChannelAccepted(event as ChannelAcceptedEvent);
        break;
      case ChannelRejectedEvent:
        _applyChannelRejected(event as ChannelRejectedEvent);
        break;
      case ServerAcceptanceRecordedEvent:
        _applyServerAcceptanceRecorded(event as ServerAcceptanceRecordedEvent);
        break;
      case RefundBuiltEvent:
        _applyRefundBuilt(event as RefundBuiltEvent);
        break;
      case RefundCountersignedEvent:
        _applyRefundCountersigned(event as RefundCountersignedEvent);
        break;
      case ChannelOpenedEvent:
        _applyChannelOpened(event as ChannelOpenedEvent);
        break;
      case PaymentRecordedEvent:
        _applyPaymentRecorded(event as PaymentRecordedEvent);
        break;
      case PaymentAcknowledgedEvent:
        _applyPaymentAcknowledged(event as PaymentAcknowledgedEvent);
        break;
      case ChannelClosingEvent:
        _applyChannelClosing(event as ChannelClosingEvent);
        break;
      case ChannelClosedEvent:
        _applyChannelClosed(event as ChannelClosedEvent);
        break;
      case RefundClaimedEvent:
        _applyRefundClaimed(event as RefundClaimedEvent);
        break;
      default:
        throw ArgumentError('Unknown event type: ${event.runtimeType}');
    }
  }

  // ==========================================================================
  // COMMAND HANDLERS
  // ==========================================================================

  Future<List<Event>> _handleRequestChannel(
    ChannelState currentState,
    RequestChannelCommand cmd,
  ) async {
    // Business rule: Amount must be positive
    if (cmd.fundingAmountSats <= BigInt.zero) {
      throw ArgumentError('Funding amount must be positive');
    }

    // Use pre-computed keys from command (generated by WalletManager)
    final lockTimeUnix = (DateTime.now().millisecondsSinceEpoch ~/ 1000) +
        cmd.lockTimeDurationSeconds;

    return [
      ChannelRequestedEvent(
        channelId: cmd.channelId,
        walletId: cmd.walletId,
        clientPeerId: cmd.clientPeerId,
        serverPeerId: cmd.serverPeerId,
        clientPubKeyHex: cmd.clientPubKeyHex,
        clientAddressB58: cmd.clientAddressB58,
        derivationIndex: cmd.derivationIndex,
        fundingAmountSats: cmd.fundingAmountSats,
        lockTimeUnix: lockTimeUnix,
        context: cmd.context,
        version: currentState.version + 1,
      ),
    ];
  }

  List<Event> _handleAcceptChannel(
    ChannelState currentState,
    AcceptChannelCommand cmd,
  ) {
    // Business rule: Channel must be in pending state
    // Note: For server, fresh aggregate defaults to pending status
    if (currentState.status != ChannelStatus.pending) {
      throw StateError('Channel not in pending state');
    }

    // Use pre-computed server keys from command (generated by WalletManager)
    return [
      ChannelAcceptedEvent(
        channelId: cmd.channelId,
        walletId: cmd.walletId,
        clientPeerId: cmd.clientPeerId,
        clientPubKeyHex: cmd.clientPubKeyHex,
        clientAddressB58: cmd.clientAddressB58,
        serverPubKeyHex: cmd.serverPubKeyHex,
        serverAddressB58: cmd.serverAddressB58,
        derivationIndex: cmd.derivationIndex,
        fundingAmountSats: cmd.fundingAmountSats,
        lockTimeUnix: cmd.lockTimeUnix,
        context: cmd.context,
        version: currentState.version + 1,
      ),
    ];
  }

  List<Event> _handleRejectChannel(
    ChannelState currentState,
    RejectChannelCommand cmd,
  ) {
    // Business rule: Channel must be in pending state
    if (currentState.status != ChannelStatus.pending) {
      throw StateError('Channel not in pending state');
    }

    return [
      ChannelRejectedEvent(
        channelId: cmd.channelId,
        reason: cmd.reason,
        version: currentState.version + 1,
      ),
    ];
  }

  /// Client records that server accepted the channel
  List<Event> _handleRecordServerAcceptance(
    ChannelState currentState,
    RecordServerAcceptanceCommand cmd,
  ) {
    // Business rule: Channel must be in pending state and we must be client
    if (currentState.status != ChannelStatus.pending) {
      throw StateError('Channel not in pending state');
    }
    if (currentState.role != ChannelRole.client) {
      throw StateError('Only client can record server acceptance');
    }

    return [
      ServerAcceptanceRecordedEvent(
        channelId: cmd.channelId,
        serverPubKeyHex: cmd.serverPubKeyHex,
        serverAddressB58: cmd.serverAddressB58,
        version: currentState.version + 1,
      ),
    ];
  }

  List<Event> _handleRequestRefundSignature(
    ChannelState currentState,
    RequestRefundSignatureCommand cmd,
  ) {
    // Business rule: Only server can sign refund
    if (currentState.role != ChannelRole.server) {
      throw StateError('Only server can sign refund');
    }

    // Business rule: Channel must be accepted
    if (currentState.status != ChannelStatus.accepted) {
      throw StateError('Channel not in accepted state');
    }

    // Use pre-computed signature from command (generated by WalletManager)
    return [
      RefundCountersignedEvent(
        channelId: cmd.channelId,
        serverSignatureHex: cmd.serverSignatureHex,
        version: currentState.version + 1,
      ),
    ];
  }

  List<Event> _handleProvideRefundSignature(
    ChannelState currentState,
    ProvideRefundSignatureCommand cmd,
  ) {
    // Client receives server's signature
    return [
      RefundCountersignedEvent(
        channelId: cmd.channelId,
        serverSignatureHex: cmd.serverSignatureHex,
        version: currentState.version + 1,
      ),
    ];
  }

  List<Event> _handleOpenChannel(
    ChannelState currentState,
    OpenChannelCommand cmd,
  ) {
    // Business rule: Refund must be signed
    if (currentState.status != ChannelStatus.refundSigned) {
      throw StateError('Refund not signed yet');
    }

    return [
      ChannelOpenedEvent(
        channelId: cmd.channelId,
        fundingTxId: cmd.fundingTxId,
        fundingOutputIndex: cmd.fundingOutputIndex,
        fundingTxHex: cmd.fundingTxHex,
        fundingAncestorTxids: cmd.fundingAncestorTxids,
        initialClientBalanceSats: currentState.fundingAmountSats,
        initialServerBalanceSats: BigInt.zero,
        version: currentState.version + 1,
      ),
    ];
  }

  List<Event> _handleRecordPayment(
    ChannelState currentState,
    RecordPaymentCommand cmd,
  ) {
    // Business rule: Channel must be open
    if (currentState.status != ChannelStatus.open) {
      throw StateError('Channel not open');
    }

    // Business rule: Only client can initiate payments
    if (currentState.role != ChannelRole.client) {
      throw StateError('Only client can initiate payments');
    }

    // Business rule: Sufficient balance
    if (currentState.clientBalanceSats < cmd.amountSats) {
      throw StateError('Insufficient balance');
    }

    // Business rule: Channel not expired
    if (currentState.isExpired) {
      throw StateError('Channel has expired');
    }

    // Business rule: Sequence must be incrementing
    if (cmd.sequenceNumber <= currentState.latestSequenceNumber) {
      throw StateError('Sequence number must be incrementing');
    }

    // Business rule: Balances must match
    final expectedClientBalance = currentState.clientBalanceSats - cmd.amountSats;
    final expectedServerBalance = currentState.serverBalanceSats + cmd.amountSats;
    
    if (cmd.newClientBalanceSats != expectedClientBalance) {
      throw StateError('Client balance mismatch');
    }
    if (cmd.newServerBalanceSats != expectedServerBalance) {
      throw StateError('Server balance mismatch');
    }

    // Use pre-computed payment TX and signature from command (generated by WalletManager)
    return [
      PaymentRecordedEvent(
        channelId: cmd.channelId,
        amountSats: cmd.amountSats,
        newClientBalanceSats: cmd.newClientBalanceSats,
        newServerBalanceSats: cmd.newServerBalanceSats,
        sequenceNumber: cmd.sequenceNumber,
        paymentTxHex: cmd.paymentTxHex,
        paymentTxId: cmd.paymentTxId,
        clientSignatureHex: cmd.clientSignatureHex,
        purpose: cmd.purpose,
        invoiceId: cmd.invoiceId,
        version: currentState.version + 1,
      ),
    ];
  }

  List<Event> _handleAcknowledgePayment(
    ChannelState currentState,
    AcknowledgePaymentCommand cmd,
  ) {
    // Business rule: Channel must be open
    if (currentState.status != ChannelStatus.open) {
      throw StateError('Channel not open');
    }

    // Business rule: Only server can acknowledge payments
    if (currentState.role != ChannelRole.server) {
      throw StateError('Only server can acknowledge payments');
    }

    // Business rule: Sequence must be incrementing
    if (cmd.proposedSequence <= currentState.latestSequenceNumber) {
      throw StateError('Sequence number must be incrementing');
    }

    // Business rule: Channel not expired
    if (currentState.isExpired) {
      throw StateError('Channel has expired');
    }

    // Use pre-computed fully signed TX and signatures from command (generated by WalletManager)
    return [
      PaymentAcknowledgedEvent(
        channelId: cmd.channelId,
        amountSats: cmd.amountSats,
        sequenceNumber: cmd.proposedSequence,
        newClientBalanceSats: cmd.proposedClientBalance,
        newServerBalanceSats: cmd.proposedServerBalance,
        fullySignedPaymentTxHex: cmd.fullySignedPaymentTxHex,
        serverSignatureHex: cmd.serverSignatureHex,
        version: currentState.version + 1,
      ),
    ];
  }

  List<Event> _handleCloseChannel(
    ChannelState currentState,
    CloseChannelCommand cmd,
  ) {
    // Business rule: Channel must be open
    if (currentState.status != ChannelStatus.open) {
      throw StateError('Channel not open');
    }

    return [
      ChannelClosingEvent(
        channelId: cmd.channelId,
        reason: cmd.reason,
        initiator: currentState.role?.name ?? 'unknown',
        clientBalanceSats: currentState.clientBalanceSats,
        serverBalanceSats: currentState.serverBalanceSats,
        version: currentState.version + 1,
      ),
    ];
  }

  List<Event> _handleFinalizeClose(
    ChannelState currentState,
    FinalizeCloseCommand cmd,
  ) {
    // Business rule: Channel must be closing
    if (currentState.status != ChannelStatus.closing) {
      throw StateError('Channel not in closing state');
    }

    return [
      ChannelClosedEvent(
        channelId: cmd.channelId,
        settlementTxId: cmd.settlementTxId,
        finalClientBalanceSats: cmd.finalClientBalanceSats,
        finalServerBalanceSats: cmd.finalServerBalanceSats,
        version: currentState.version + 1,
      ),
    ];
  }

  List<Event> _handleClaimRefund(
    ChannelState currentState,
    ClaimRefundCommand cmd,
  ) {
    // Business rule: Channel must be expired
    if (!currentState.isExpired) {
      throw StateError('Channel not yet expired');
    }

    // Business rule: Only client can claim refund
    if (currentState.role != ChannelRole.client) {
      throw StateError('Only client can claim refund');
    }

    // TODO: Broadcast refund TX and get txid
    final refundTxId = 'pending-broadcast';

    return [
      RefundClaimedEvent(
        channelId: cmd.channelId,
        refundTxId: refundTxId,
        refundAmountSats: currentState.fundingAmountSats,
        version: currentState.version + 1,
      ),
    ];
  }

  // ==========================================================================
  // EVENT HANDLERS (Apply to State)
  // ==========================================================================

  void _applyChannelRequested(ChannelRequestedEvent event) {
    currentState.walletId = event.walletId;
    currentState.status = ChannelStatus.pending;
    currentState.role = ChannelRole.client;
    currentState.clientPeerId = event.clientPeerId;
    currentState.serverPeerId = event.serverPeerId;
    currentState.clientPubKeyHex = event.clientPubKeyHex;
    currentState.clientAddressB58 = event.clientAddressB58;
    currentState.derivationIndex = event.derivationIndex;
    currentState.fundingAmountSats = event.fundingAmountSats;
    currentState.lockTimeUnix = event.lockTimeUnix;
    currentState.context = event.context;
    currentState.createdAt = event.timestamp;
    currentState.clientBalanceSats = event.fundingAmountSats;
    currentState.serverBalanceSats = BigInt.zero;
    currentState.version = event.version;
    currentState.lastModified = event.timestamp;
  }

  void _applyChannelAccepted(ChannelAcceptedEvent event) {
    currentState.walletId ??= event.walletId;
    currentState.status = ChannelStatus.accepted;
    currentState.role ??= ChannelRole.server;
    currentState.clientPeerId ??= event.clientPeerId;
    currentState.clientPubKeyHex ??= event.clientPubKeyHex;
    currentState.clientAddressB58 ??= event.clientAddressB58;
    currentState.serverPubKeyHex = event.serverPubKeyHex;
    currentState.serverAddressB58 = event.serverAddressB58;
    currentState.derivationIndex ??= event.derivationIndex;
    // Set funding amount (server's aggregate needs this from the event)
    if (currentState.fundingAmountSats == BigInt.zero) {
      currentState.fundingAmountSats = event.fundingAmountSats;
    }
    currentState.lockTimeUnix ??= event.lockTimeUnix;
    currentState.context ??= event.context;
    // Set initial balances (server's aggregate needs this from the event)
    if (currentState.clientBalanceSats == BigInt.zero) {
      currentState.clientBalanceSats = event.fundingAmountSats;
    }
    if (currentState.serverBalanceSats == BigInt.zero) {
      currentState.serverBalanceSats = BigInt.zero;
    }
    currentState.version = event.version;
    currentState.lastModified = event.timestamp;
  }

  void _applyChannelRejected(ChannelRejectedEvent event) {
    currentState.status = ChannelStatus.rejected;
    currentState.version = event.version;
    currentState.lastModified = event.timestamp;
  }

  void _applyServerAcceptanceRecorded(ServerAcceptanceRecordedEvent event) {
    currentState.serverPubKeyHex = event.serverPubKeyHex;
    currentState.serverAddressB58 = event.serverAddressB58;
    currentState.status = ChannelStatus.accepted;
    currentState.version = event.version;
    currentState.lastModified = event.timestamp;
  }

  void _applyRefundBuilt(RefundBuiltEvent event) {
    currentState.fundingTxId = event.fundingTxId;
    currentState.fundingOutputIndex = event.fundingOutputIndex;
    currentState.fundingTxHex = event.fundingTxHex;
    currentState.refundTxHex = event.refundTxHex;
    currentState.refundClientSigHex = event.clientSignatureHex;
    currentState.version = event.version;
    currentState.lastModified = event.timestamp;
  }

  void _applyRefundCountersigned(RefundCountersignedEvent event) {
    currentState.status = ChannelStatus.refundSigned;
    currentState.refundServerSigHex = event.serverSignatureHex;
    currentState.version = event.version;
    currentState.lastModified = event.timestamp;
  }

  void _applyChannelOpened(ChannelOpenedEvent event) {
    currentState.status = ChannelStatus.open;
    currentState.fundingTxId = event.fundingTxId;
    currentState.fundingOutputIndex = event.fundingOutputIndex;
    currentState.fundingTxHex = event.fundingTxHex;
    currentState.fundingAncestorTxids = event.fundingAncestorTxids;
    currentState.clientBalanceSats = event.initialClientBalanceSats;
    currentState.serverBalanceSats = event.initialServerBalanceSats;
    currentState.version = event.version;
    currentState.lastModified = event.timestamp;
  }

  void _applyPaymentRecorded(PaymentRecordedEvent event) {
    currentState.clientBalanceSats = event.newClientBalanceSats;
    currentState.serverBalanceSats = event.newServerBalanceSats;
    currentState.latestSequenceNumber = event.sequenceNumber;
    currentState.latestPaymentTxHex = event.paymentTxHex;
    currentState.latestPaymentTxId = event.paymentTxId;
    currentState.version = event.version;
    currentState.lastModified = event.timestamp;
  }

  void _applyPaymentAcknowledged(PaymentAcknowledgedEvent event) {
    currentState.clientBalanceSats = event.newClientBalanceSats;
    currentState.serverBalanceSats = event.newServerBalanceSats;
    currentState.latestSequenceNumber = event.sequenceNumber;
    currentState.latestPaymentTxHex = event.fullySignedPaymentTxHex;
    currentState.version = event.version;
    currentState.lastModified = event.timestamp;
  }

  void _applyChannelClosing(ChannelClosingEvent event) {
    currentState.status = ChannelStatus.closing;
    currentState.version = event.version;
    currentState.lastModified = event.timestamp;
  }

  void _applyChannelClosed(ChannelClosedEvent event) {
    currentState.status = ChannelStatus.closed;
    currentState.clientBalanceSats = event.finalClientBalanceSats;
    currentState.serverBalanceSats = event.finalServerBalanceSats;
    currentState.closedAt = event.timestamp;
    currentState.version = event.version;
    currentState.lastModified = event.timestamp;
  }

  void _applyRefundClaimed(RefundClaimedEvent event) {
    currentState.status = ChannelStatus.expired;
    currentState.closedAt = event.timestamp;
    currentState.version = event.version;
    currentState.lastModified = event.timestamp;
  }

  // Helper to get next derivation index
}

