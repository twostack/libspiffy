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

  // ==========================================================================
  // SNAPSHOTS (audit 2026-09-14 M6)
  // ==========================================================================
  //
  // ChannelState inherits State.toMap (version and timestamp only), so the
  // snapshot is written here and read back by restoreStateFromMap. Amounts
  // are decimal strings and dates ISO-8601 strings, which survive the event
  // store's CBOR round trip unchanged.

  @override
  Future<dynamic> getSnapshotState() async =>
      isInitialized ? channelStateToMap(currentState) : null;

  /// Every field of [s], in the form [restoreStateFromMap] reads.
  static Map<String, dynamic> channelStateToMap(ChannelState s) => {
        'type': s.typeName,
        'channelId': s.channelId,
        'walletId': s.walletId,
        'status': s.status.name,
        'role': s.role?.name,
        'clientPeerId': s.clientPeerId,
        'serverPeerId': s.serverPeerId,
        'clientPubKeyHex': s.clientPubKeyHex,
        'serverPubKeyHex': s.serverPubKeyHex,
        'clientAddressB58': s.clientAddressB58,
        'serverAddressB58': s.serverAddressB58,
        'derivationIndex': s.derivationIndex,
        'fundingAmountSats': s.fundingAmountSats.toString(),
        'fundingTxId': s.fundingTxId,
        'fundingTxHex': s.fundingTxHex,
        'fundingOutputIndex': s.fundingOutputIndex,
        'fundingAncestorTxids': List<String>.from(s.fundingAncestorTxids),
        'lockTimeUnix': s.lockTimeUnix,
        'refundTxHex': s.refundTxHex,
        'refundClientSigHex': s.refundClientSigHex,
        'refundServerSigHex': s.refundServerSigHex,
        'clientBalanceSats': s.clientBalanceSats.toString(),
        'serverBalanceSats': s.serverBalanceSats.toString(),
        'latestSequenceNumber': s.latestSequenceNumber,
        'latestPaymentTxHex': s.latestPaymentTxHex,
        'latestPaymentTxId': s.latestPaymentTxId,
        'context': s.context,
        'createdAt': s.createdAt?.toIso8601String(),
        'closedAt': s.closedAt?.toIso8601String(),
        'version': s.version,
        'lastModified': s.lastModified.toIso8601String(),
      };

  @override
  Future<ChannelState> restoreStateFromMap(Map<String, dynamic> map, int sequenceNumber) async {
    DateTime? date(Object? v) => v == null ? null : (v is DateTime ? v : DateTime.parse(v as String));
    final channelId = map['channelId'] as String;
    if (channelId != aggregateId) {
      throw StateError('Snapshot at $sequenceNumber belongs to channel $channelId, not $aggregateId');
    }
    final role = map['role'] as String?;
    return ChannelState(
      channelId: channelId,
      walletId: map['walletId'] as String?,
      status: ChannelStatus.values.byName(map['status'] as String),
      role: role == null ? null : ChannelRole.values.byName(role),
      clientPeerId: map['clientPeerId'] as String?,
      serverPeerId: map['serverPeerId'] as String?,
      clientPubKeyHex: map['clientPubKeyHex'] as String?,
      serverPubKeyHex: map['serverPubKeyHex'] as String?,
      clientAddressB58: map['clientAddressB58'] as String?,
      serverAddressB58: map['serverAddressB58'] as String?,
      derivationIndex: map['derivationIndex'] as int?,
      fundingAmountSats: BigInt.parse(map['fundingAmountSats'] as String),
      fundingTxId: map['fundingTxId'] as String?,
      fundingTxHex: map['fundingTxHex'] as String?,
      fundingOutputIndex: map['fundingOutputIndex'] as int?,
      fundingAncestorTxids: [
        for (final t in map['fundingAncestorTxids'] as List? ?? const []) t as String,
      ],
      lockTimeUnix: map['lockTimeUnix'] as int?,
      refundTxHex: map['refundTxHex'] as String?,
      refundClientSigHex: map['refundClientSigHex'] as String?,
      refundServerSigHex: map['refundServerSigHex'] as String?,
      clientBalanceSats: BigInt.parse(map['clientBalanceSats'] as String),
      serverBalanceSats: BigInt.parse(map['serverBalanceSats'] as String),
      latestSequenceNumber: map['latestSequenceNumber'] as int,
      latestPaymentTxHex: map['latestPaymentTxHex'] as String?,
      latestPaymentTxId: map['latestPaymentTxId'] as String?,
      context: map['context'] as String?,
      createdAt: date(map['createdAt']),
      closedAt: date(map['closedAt']),
      version: map['version'] as int,
      lastModified: date(map['lastModified']),
    );
  }

  /// A snapshot that cannot be restored fails recovery instead of eventador's
  /// default (empty state plus only the events after the snapshot).
  @override
  Future<void> onSnapshotRestorationFailure(
      dynamic snapshotData, int sequenceNumber, dynamic error) async {
    throw StateError('Channel $aggregateId: snapshot at $sequenceNumber cannot be restored '
        '(refusing to recover from the events after it alone): $error');
  }

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

    // A channel with no journaled events has no state to report (audit L3):
    // reading currentState would throw inside the actor and the ask would
    // time out instead of getting an answer.
    if (!isInitialized || currentState.version == 0) {
      sender.tell(FullChannelStateResponse(
        channelId: aggregateId,
        walletId: '',
        status: 'unknown',
        clientBalanceSats: BigInt.zero,
        serverBalanceSats: BigInt.zero,
        latestSequenceNumber: 0,
        fundingAmountSats: BigInt.zero,
        success: false,
        error: 'Channel not found: $aggregateId has no events',
      ));
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
    } else if (command is ExpireChannelCommand) {
      return _handleExpireChannel(currentState, command);
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
      case ChannelExpiredEvent:
        _applyChannelExpired(event as ChannelExpiredEvent);
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
    // Client receives server's signature. Only the client of a channel the
    // server has accepted is waiting for it (audit M10).
    if (currentState.role != ChannelRole.client) {
      throw StateError('Only client can record the server refund signature');
    }
    if (currentState.status != ChannelStatus.accepted) {
      throw StateError('Channel not in accepted state '
          '(status=${currentState.status.name})');
    }

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

    // Business rules mirroring the client side (audit M10): a payment moves a
    // positive amount from the client to the server, and the channel never
    // holds more or less than it was funded with.
    if (cmd.amountSats <= BigInt.zero) {
      throw StateError('Payment amount must be positive');
    }
    if (cmd.proposedClientBalance < BigInt.zero ||
        cmd.proposedServerBalance < BigInt.zero) {
      throw StateError('Proposed balances must not be negative');
    }
    if (cmd.proposedClientBalance + cmd.proposedServerBalance !=
        currentState.fundingAmountSats) {
      throw StateError('Proposed balances '
          '${cmd.proposedClientBalance} + ${cmd.proposedServerBalance} '
          'do not sum to the funding amount ${currentState.fundingAmountSats}');
    }
    final expectedServerBalance =
        currentState.serverBalanceSats + cmd.amountSats;
    if (cmd.proposedServerBalance != expectedServerBalance) {
      throw StateError('Server balance mismatch: proposed '
          '${cmd.proposedServerBalance}, expected $expectedServerBalance');
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

  List<Event> _handleExpireChannel(
    ChannelState currentState,
    ExpireChannelCommand cmd,
  ) {
    // Business rule: Channel must be past its lockTime.
    if (!currentState.isExpired) {
      throw StateError('Channel not yet past lockTime');
    }

    // Business rule: Don't re-emit expiry for already-terminated channels.
    if (currentState.status == ChannelStatus.expired ||
        currentState.status == ChannelStatus.closed ||
        currentState.status == ChannelStatus.rejected) {
      throw StateError('Channel already terminated (status=${currentState.status.name})');
    }

    return [
      ChannelExpiredEvent(
        channelId: cmd.channelId,
        observedBy: cmd.observedBy,
        settlementOrRefundTxId: cmd.settlementOrRefundTxId,
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

    // The journal records the txid of the actual refund transaction (audit
    // L4): the one the command carries (typically the fully signed refund)
    // or else the refund transaction this channel built.
    final refundTxHex = cmd.refundTxHex ?? currentState.refundTxHex;
    if (refundTxHex == null || refundTxHex.isEmpty) {
      throw StateError('No refund transaction known for channel '
          '${cmd.channelId}');
    }
    final dartsv.Transaction refundTx;
    try {
      refundTx = dartsv.Transaction.fromHex(refundTxHex);
    } catch (e) {
      throw StateError('Invalid refund transaction: $e');
    }
    final fundingTxId = currentState.fundingTxId;
    if (fundingTxId != null) {
      final spendsFunding = refundTx.inputs.any((input) =>
          input.prevTxnId == fundingTxId &&
          input.prevTxnOutputIndex == (currentState.fundingOutputIndex ?? 0));
      if (!spendsFunding) {
        throw StateError('Refund transaction does not spend the funding output '
            '$fundingTxId:${currentState.fundingOutputIndex ?? 0}');
      }
    }
    final refundTxId = refundTx.id;

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

  void _applyChannelExpired(ChannelExpiredEvent event) {
    currentState.status = ChannelStatus.expired;
    currentState.closedAt = event.timestamp;
    currentState.version = event.version;
    currentState.lastModified = event.timestamp;
  }

  // Helper to get next derivation index
}

