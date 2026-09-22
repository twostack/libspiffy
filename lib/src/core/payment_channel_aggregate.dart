import '../models/channel_timing.dart';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:dactor/dactor.dart';
import 'package:eventador/eventador.dart';
import 'package:dartsv/dartsv.dart' as dartsv;

import '../actors/payment_channel_messages.dart';
import '../models/fee_rate.dart';
import '../services/payment_channel_builder.dart';
import '../services/crypto_service.dart';
import '../utils/beef.dart';
import 'channel_commands.dart';
import 'channel_events.dart';
import 'channel_state.dart';
import 'aggregate_command_failures.dart';

/// Payment Channel Aggregate Root
/// 
/// One instance per payment channel, identified by channelId.
/// Handles all channel commands and emits events as the source of truth.
class PaymentChannelAggregate extends AggregateRoot<ChannelState>
    with CommandFailureContainment<ChannelState> {
  late final PaymentChannelBuilder _channelBuilder;
  final CryptoService _cryptoService;
  final dartsv.NetworkType _networkType;
  
  // Capture sender for responses (same pattern as BitcoinWalletAggregate)
  final Map<String, ActorRef> _capturedSenders = {};

  PaymentChannelAggregate({
    required String aggregateId, // This is the channelId
    required EventStore eventStore,
    required CryptoService cryptoService,
    dartsv.NetworkType networkType = dartsv.NetworkType.TEST,
  }) : _networkType = networkType,
        _cryptoService = cryptoService,
        super(
          aggregateId: aggregateId,
          aggregateType: 'PaymentChannel',
          eventStore: eventStore,
        ) {
    _channelBuilder = const PaymentChannelBuilder();
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
        'fundingBeefHex': s.fundingBeefHex,
        'fundingInputSats': s.fundingInputSats,
        'fundingBroadcastAttempts': s.fundingBroadcastAttempts,
        'fundingBroadcastInFlight': s.fundingBroadcastInFlight,
        'fundingBroadcastError': s.fundingBroadcastError,
        'fundingRecordedInWallet': s.fundingRecordedInWallet,
        'returnLegRecordedInWallet': s.returnLegRecordedInWallet,
        'lockTimeUnix': s.lockTimeUnix,
        'refundTxHex': s.refundTxHex,
        'refundClientSigHex': s.refundClientSigHex,
        'refundServerSigHex': s.refundServerSigHex,
        'signedRefundTxHex': s.signedRefundTxHex,
        'clientBalanceSats': s.clientBalanceSats.toString(),
        'serverBalanceSats': s.serverBalanceSats.toString(),
        'latestSequenceNumber': s.latestSequenceNumber,
        'latestPaymentTxHex': s.latestPaymentTxHex,
        'latestPaymentTxId': s.latestPaymentTxId,
        'latestClientSignatureHex': s.latestClientSignatureHex,
        'context': s.context,
        'counterpartyMarker': s.counterpartyMarker,
        'createdAt': s.createdAt?.toIso8601String(),
        'refundClaimedTxId': s.refundClaimedTxId,
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
      // Snapshots written before libspiffy-b83/9f7 have no funding broadcast
      // or signed refund keys.
      fundingBeefHex: map['fundingBeefHex'] as String?,
      fundingInputSats: map['fundingInputSats'] as int?,
      fundingBroadcastAttempts: map['fundingBroadcastAttempts'] as int? ?? 0,
      fundingBroadcastInFlight: map['fundingBroadcastInFlight'] as bool? ?? false,
      fundingBroadcastError: map['fundingBroadcastError'] as String?,
      fundingRecordedInWallet: map['fundingRecordedInWallet'] as bool? ?? false,
      returnLegRecordedInWallet:
          map['returnLegRecordedInWallet'] as bool? ?? false,
      lockTimeUnix: map['lockTimeUnix'] as int?,
      refundTxHex: map['refundTxHex'] as String?,
      refundClientSigHex: map['refundClientSigHex'] as String?,
      refundServerSigHex: map['refundServerSigHex'] as String?,
      signedRefundTxHex: map['signedRefundTxHex'] as String?,
      clientBalanceSats: BigInt.parse(map['clientBalanceSats'] as String),
      serverBalanceSats: BigInt.parse(map['serverBalanceSats'] as String),
      latestSequenceNumber: map['latestSequenceNumber'] as int,
      latestPaymentTxHex: map['latestPaymentTxHex'] as String?,
      latestPaymentTxId: map['latestPaymentTxId'] as String?,
      latestClientSignatureHex: map['latestClientSignatureHex'] as String?,
      context: map['context'] as String?,
      // Snapshots written before libspiffy-bps1 have no marker key.
      counterpartyMarker: map['counterpartyMarker'] as String?,
      createdAt: date(map['createdAt']),
      // Snapshots written before libspiffy-07mx have no claim key; a
      // channel whose claim predates this reads back as unclaimed, which is
      // what the journal said at the time.
      refundClaimedTxId: map['refundClaimedTxId'] as String?,
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
    if (message is ChannelCommandCheck) {
      await _handleCommandCheck(message);
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
  
  /// Answers whether this channel would take [check]'s command, by running
  /// it through [handleCommand] and journaling nothing (bead
  /// libspiffy-1a5k).
  Future<void> _handleCommandCheck(ChannelCommandCheck check) async {
    final sender = context.sender;
    if (sender == null) return;
    if (!isInitialized || currentState.version == 0) {
      sender.tell(ChannelCommandCheckResponse(
          error: 'Channel not found: $aggregateId has no events'));
      return;
    }
    try {
      await handleCommand(currentState, check.command);
      sender.tell(ChannelCommandCheckResponse());
    } catch (e) {
      sender.tell(ChannelCommandCheckResponse(error: e.toString()));
    }
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
      signedRefundTxHex: currentState.signedRefundTxHex,
      fundingInputSats: currentState.fundingInputSats,
      fundingRecordedInWallet: currentState.fundingRecordedInWallet,
      returnLegRecordedInWallet: currentState.returnLegRecordedInWallet,
      fundingBroadcastInFlight: currentState.fundingBroadcastInFlight,
      clientPeerId: currentState.clientPeerId,
      serverPeerId: currentState.serverPeerId,
      context: currentState.context,
      counterpartyMarker: currentState.counterpartyMarker,
      refundTxHex: currentState.refundTxHex,
      fundingBeefHex: currentState.fundingBeefHex,
      latestPaymentTxHex: currentState.latestPaymentTxHex,
      latestClientSignatureHex: currentState.latestClientSignatureHex,
      refundClaimedTxId: currentState.refundClaimedTxId,
      success: true,
    ));
  }
  
  @override
  Future<void> onCommandProcessed(Command command, List<Event> events) async {
    await super.onCommandProcessed(command, events);
    
    // Send events back to sender if running in actor system
    final sender = _capturedSenders[command.commandId];
    if (sender != null) {
      sender.tell(ChannelCommandResult(
        commandId: command.commandId,
        events: events,
        success: true,
      ));
      _capturedSenders.remove(command.commandId);
    }
  }
  
  @override
  Future<void> onCommandFailure(Command command, dynamic error) async {
    await super.onCommandFailure(command, error);
    
    // Send error response to sender if running in actor system
    final sender = _capturedSenders[command.commandId];
    if (sender != null) {
      sender.tell(ChannelCommandResult.failed(
        commandId: command.commandId,
        error: error.toString(),
      ));
      _capturedSenders.remove(command.commandId);
    }
  }

  @override
  Future<List<Event>> handleCommand(ChannelState currentState, Command command) async {
    if (command is RequestChannelCommand) {
      return await _handleRequestChannel(currentState, command);
    } else if (command is AcceptChannelCommand) {
      return _handleAcceptChannel(currentState, command);
    } else if (command is RejectChannelCommand) {
      return _handleRejectChannel(currentState, command);
    } else if (command is RecordServerAcceptanceCommand) {
      return _handleRecordServerAcceptance(currentState, command);
    } else if (command is RecordRefundBuiltCommand) {
      return _handleRecordRefundBuilt(currentState, command);
    } else if (command is StartFundingBroadcastCommand) {
      return _handleStartFundingBroadcast(currentState, command);
    } else if (command is RecordFundingBroadcastFailedCommand) {
      return _handleRecordFundingBroadcastFailed(currentState, command);
    } else if (command is RecordFundingInWalletCommand) {
      return _handleRecordFundingInWallet(currentState, command);
    } else if (command is RequestRefundSignatureCommand) {
      return _handleRequestRefundSignature(currentState, command);
    } else if (command is ProvideRefundSignatureCommand) {
      return _handleProvideRefundSignature(currentState, command);
    } else if (command is OpenChannelCommand) {
      return _handleOpenChannel(currentState, command);
    } else if (command is RecordPaymentCommand) {
      return _handleRecordPayment(currentState, command);
    } else if (command is AcknowledgePaymentCommand) {
      return _handleAcknowledgePayment(currentState, command);
    } else if (command is RecordReturnLegInWalletCommand) {
      return _handleRecordReturnLegInWallet(currentState, command);
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

  /// Applies [event] to [state] and returns the next state (bead
  /// libspiffy-mmb). [state] is never modified; eventador's `eventHandler`
  /// replaces the aggregate's state with the result once the event has
  /// applied, so an event that fails midway changes nothing.
  @override
  ChannelState applyEvent(ChannelState state, Event event) {
    if (event is! ChannelEvent) {
      throw ArgumentError('Expected ChannelEvent, got ${event.runtimeType}');
    }

    return switch (event) {
      final ChannelRequestedEvent evt => _applyChannelRequested(state, evt),
      final ChannelAcceptedEvent evt => _applyChannelAccepted(state, evt),
      final ChannelRejectedEvent evt => _applyChannelRejected(state, evt),
      final ServerAcceptanceRecordedEvent evt => _applyServerAcceptanceRecorded(state, evt),
      final RefundBuiltEvent evt => _applyRefundBuilt(state, evt),
      final RefundCountersignedEvent evt => _applyRefundCountersigned(state, evt),
      final FundingBroadcastStartedEvent evt => _applyFundingBroadcastStarted(state, evt),
      final FundingBroadcastFailedEvent evt => _applyFundingBroadcastFailed(state, evt),
      final FundingRecordedInWalletEvent evt => _applyFundingRecordedInWallet(state, evt),
      final ChannelOpenedEvent evt => _applyChannelOpened(state, evt),
      final PaymentRecordedEvent evt => _applyPaymentRecorded(state, evt),
      final PaymentAcknowledgedEvent evt => _applyPaymentAcknowledged(state, evt),
      final PaymentCountersignedEvent evt => _applyPaymentCountersigned(state, evt),
      final ReturnLegRecordedInWalletEvent evt =>
        _applyReturnLegRecordedInWallet(state, evt),
      final ChannelClosingEvent evt => _applyChannelClosing(state, evt),
      final ChannelClosedEvent evt => _applyChannelClosed(state, evt),
      final RefundClaimedEvent evt => _applyRefundClaimed(state, evt),
      final ChannelExpiredEvent evt => _applyChannelExpired(state, evt),
      _ => throw ArgumentError('Unknown event type: ${event.runtimeType}'),
    };
  }

  /// Nothing printed: the error is rethrown to the caller.
  @override
  void onEventApplicationFailure(Event event, dynamic error) {}

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
    // A channel shorter than the minimum lifetime settles almost as soon as
    // it opens (bead libspiffy-ywbk): the server would refuse it anyway.
    if (Duration(seconds: cmd.lockTimeDurationSeconds) < cmd.timing.minimumLifetime) {
      throw ArgumentError('A channel of ${cmd.lockTimeDurationSeconds} s is shorter than the minimum '
          'lifetime of ${cmd.timing.minimumLifetime.inSeconds} s');
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
        counterpartyMarker: cmd.counterpartyMarker,
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
    // The amount comes from the client's request: the same rule its own
    // side journals under (_handleRequestChannel).
    if (cmd.fundingAmountSats <= BigInt.zero) {
      throw ArgumentError('Funding amount must be positive');
    }
    // The lock time comes from the client too, and it is when the client can
    // take everything back (bead libspiffy-ywbk). Below 500,000,000 an
    // nLockTime is a block height, not a time.
    if (cmd.lockTimeUnix < _lockTimeThreshold) {
      throw ArgumentError('Lock time ${cmd.lockTimeUnix} is a block height, not a time');
    }
    final lifetime = cmd.lockTimeUnix - _nowUnix();
    if (Duration(seconds: lifetime) < cmd.timing.minimumLifetime) {
      throw ArgumentError('A channel locked until ${cmd.lockTimeUnix} runs $lifetime s, less than the '
          'minimum lifetime of ${cmd.timing.minimumLifetime.inSeconds} s');
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
        serverPeerId: cmd.serverPeerId,
        counterpartyMarker: cmd.counterpartyMarker,
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
    if (currentState.role != ChannelRole.client) {
      throw StateError('Only client can record server acceptance');
    }

    // A repeated `channel_accept` naming the SAME acceptance is a repeat,
    // not a second acceptance: the server is unsure the first one arrived,
    // which is the very reason the re-send exists (bead libspiffy-y8x3, the
    // peer-facing half of what V-100 did for `channel_open`). Journal
    // nothing and answer. One naming DIFFERENT keys is not a repeat — it is
    // a different server, or a different offer — and is still refused.
    if (currentState.serverPubKeyHex != null) {
      if (currentState.serverPubKeyHex == cmd.serverPubKeyHex &&
          currentState.serverAddressB58 == cmd.serverAddressB58) {
        return const [];
      }
      throw StateError('Channel ${cmd.channelId} was already accepted by '
          '${currentState.serverPubKeyHex} paying to '
          '${currentState.serverAddressB58}; this acceptance names '
          '${cmd.serverPubKeyHex} paying to ${cmd.serverAddressB58}');
    }

    // Business rule: Channel must be in pending state
    if (currentState.status != ChannelStatus.pending) {
      throw StateError('Channel not in pending state');
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

    // The server's signature lets the client take the funding output back
    // once the lockTime has passed: it is journaled only for a refund of the
    // funding output the client named, locked until the channel lockTime
    // (libspiffy-fsy).
    final refund = _parseRefund(cmd.refundTxHex);
    _checkRefundSpends(currentState, refund,
        fundingTxId: cmd.fundingTxId, fundingOutputIndex: cmd.fundingOutputIndex);
    final fundingTxHex = cmd.fundingTxHex;
    if (fundingTxHex != null) {
      _checkFundingOutput(currentState,
          fundingTxHex: fundingTxHex,
          fundingTxId: cmd.fundingTxId,
          outputIndex: cmd.fundingOutputIndex);
    }

    // Use pre-computed signature from command (generated by WalletManager)
    return [
      RefundCountersignedEvent(
        channelId: cmd.channelId,
        serverSignatureHex: cmd.serverSignatureHex,
        refundTxHex: cmd.refundTxHex,
        fundingTxId: cmd.fundingTxId,
        fundingOutputIndex: cmd.fundingOutputIndex,
        fundingTxHex: fundingTxHex,
        version: currentState.version + 1,
      ),
    ];
  }

  dartsv.Transaction _parseRefund(String refundTxHex) {
    try {
      return dartsv.Transaction.fromHex(refundTxHex);
    } catch (e) {
      throw StateError('Invalid refund transaction: $e');
    }
  }

  /// Checks [refund] spends exactly [fundingTxId]:[fundingOutputIndex], with
  /// the channel lockTime as nLockTime and a non-final input sequence (so
  /// that nLockTime is enforced).
  void _checkRefundSpends(
    ChannelState state,
    dartsv.Transaction refund, {
    required String fundingTxId,
    required int fundingOutputIndex,
  }) {
    final lockTimeUnix = state.lockTimeUnix;
    if (lockTimeUnix == null) {
      throw StateError('Channel ${state.channelId} has no lockTime');
    }
    if (refund.inputs.length != 1 ||
        refund.inputs.single.prevTxnId != fundingTxId ||
        refund.inputs.single.prevTxnOutputIndex != fundingOutputIndex) {
      throw StateError('Refund transaction does not spend exactly the funding '
          'output $fundingTxId:$fundingOutputIndex');
    }
    if (refund.nLockTime != lockTimeUnix) {
      throw StateError('Refund nLockTime ${refund.nLockTime} is not the channel '
          'lockTime $lockTimeUnix');
    }
    if (refund.inputs.single.sequenceNumber ==
        dartsv.TransactionInput.MAX_SEQ_NUMBER) {
      throw StateError('Refund input sequence is final: its nLockTime would '
          'not be enforced');
    }
  }

  /// Checks [beefHex] parses as a BEEF that carries [fundingTxId] exactly as
  /// [fundingTxHex]. Whether the BEEF proves it is for SPV validation (the
  /// manager asks the SPV actor before opening).
  void _checkBeefCarriesFunding(
    String beefHex, {
    required String fundingTxId,
    required String fundingTxHex,
  }) {
    final BEEF beef;
    try {
      beef = BEEF.parse(Uint8List.fromList(hex.decode(beefHex)));
    } catch (e) {
      throw StateError('Invalid funding BEEF: $e');
    }
    final entry =
        beef.findTransactionByTxid(Uint8List.fromList(hex.decode(fundingTxId)));
    if (entry == null) {
      throw StateError('The funding BEEF does not carry $fundingTxId');
    }
    if (hex.encode(entry['txData'] as List<int>) != fundingTxHex.toLowerCase()) {
      throw StateError('The funding BEEF carries another $fundingTxId');
    }
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
    // A repeated `refund_signed` records nothing: the client already holds a
    // refund it verified against the funding output, and that is all this
    // message is for (bead libspiffy-y8x3). Answered rather than refused —
    // the old refusal came from the status guard below, and the adapter
    // reported it to the peer as `channel_error`, so a server re-sending
    // because it was unsure was told the channel had failed.
    //
    // Deliberately not compared byte for byte: ECDSA signing is not
    // deterministic, so a server that re-signed produces different bytes for
    // the same fact, and a second signature has nothing to add to a refund
    // that already verifies. A signature that does NOT verify equally cannot
    // destroy the good one, because nothing is journaled here at all.
    if (currentState.signedRefundTxHex != null) {
      return const [];
    }

    if (currentState.status != ChannelStatus.accepted) {
      throw StateError('Channel not in accepted state '
          '(status=${currentState.status.name})');
    }

    // The signature is only worth journaling if it completes the refund the
    // client built: a server that returns a bad signature would otherwise
    // leave the client funding a 2-of-2 it cannot recover (libspiffy-b83).
    final template = currentState.refundTxHex;
    final clientSigHex = currentState.refundClientSigHex;
    if (template == null || clientSigHex == null) {
      throw StateError('No refund transaction built for channel '
          '${cmd.channelId}: nothing for the server signature to complete');
    }
    final dartsv.SVSignature serverSignature;
    try {
      serverSignature = dartsv.SVSignature.fromTxFormat(cmd.serverSignatureHex);
    } catch (e) {
      throw StateError('Server refund signature is malformed: $e');
    }
    final keys = _channelKeys(currentState);
    final signed = _channelBuilder.applyMultisigSignatures(
      transaction: dartsv.Transaction.fromHex(template),
      inputIndex: 0,
      clientSignature: dartsv.SVSignature.fromTxFormat(clientSigHex),
      serverSignature: serverSignature,
      clientPubKey: keys.client,
      serverPubKey: keys.server,
    );
    try {
      _channelBuilder.verifyMultisigSpend(
        signedTx: signed,
        redeemScript: keys.redeemScript,
        inputValueSats: currentState.fundingAmountSats,
      );
    } on ScriptVerificationException catch (e) {
      throw StateError('Server refund signature does not verify: the fully '
          'signed refund fails the script check against the funding output '
          '(${e.message})');
    }

    return [
      RefundCountersignedEvent(
        channelId: cmd.channelId,
        serverSignatureHex: cmd.serverSignatureHex,
        signedRefundTxHex: signed.serialize(),
        version: currentState.version + 1,
      ),
    ];
  }

  /// The channel's two public keys and their 2-of-2 script (BIP67 order).
  ({dartsv.SVPublicKey client, dartsv.SVPublicKey server, dartsv.SVScript redeemScript})
      _channelKeys(ChannelState state) {
    final clientHex = state.clientPubKeyHex;
    final serverHex = state.serverPubKeyHex;
    if (clientHex == null || serverHex == null) {
      throw StateError('Channel ${state.channelId} has no '
          '${clientHex == null ? 'client' : 'server'} public key yet');
    }
    final client = dartsv.SVPublicKey.fromHex(clientHex);
    final server = dartsv.SVPublicKey.fromHex(serverHex);
    return (
      client: client,
      server: server,
      redeemScript: _channelBuilder.buildMultisigRedeemScript(
          clientPubKey: client, serverPubKey: server),
    );
  }

  /// Parses [fundingTxHex] and checks it is transaction [fundingTxId] whose
  /// output [outputIndex] locks exactly the channel's funding amount in the
  /// channel's 2-of-2.
  dartsv.Transaction _checkFundingOutput(
    ChannelState state, {
    required String fundingTxHex,
    required String fundingTxId,
    required int outputIndex,
  }) {
    final dartsv.Transaction funding;
    try {
      funding = dartsv.Transaction.fromHex(fundingTxHex);
    } catch (e) {
      throw StateError('Invalid funding transaction: $e');
    }
    if (funding.id != fundingTxId) {
      throw StateError('Funding transaction is ${funding.id}, not $fundingTxId');
    }
    if (outputIndex < 0 || outputIndex >= funding.outputs.length) {
      throw StateError('Funding transaction $fundingTxId has no output $outputIndex');
    }
    final output = funding.outputs[outputIndex];
    if (output.script.toHex() != _channelKeys(state).redeemScript.toHex()) {
      throw StateError('Funding output $fundingTxId:$outputIndex is not the '
          'channel 2-of-2');
    }
    if (output.satoshis != state.fundingAmountSats) {
      throw StateError('Funding output $fundingTxId:$outputIndex holds '
          '${output.satoshis} sats, not the agreed ${state.fundingAmountSats}');
    }
    return funding;
  }

  /// Throws unless [signatureHex] is the client's valid signature of the
  /// funding input of [tx]: without it, [tx] can never be completed whatever
  /// the server signs.
  void _checkClientSignature(
      ChannelState state, dartsv.Transaction tx, String signatureHex, String what) {
    final keys = _channelKeys(state);
    final bool valid;
    try {
      final signature = dartsv.SVSignature.fromTxFormat(signatureHex);
      final sighash = dartsv.Sighash()
          .hash(tx, signature.nhashtype, 0, keys.redeemScript, state.fundingAmountSats);
      valid = _cryptoService.verifySignature(
          keys.client, signature, Uint8List.fromList(hex.decode(sighash).reversed.toList()));
    } catch (e) {
      throw StateError('Client $what signature is malformed: $e');
    }
    if (!valid) {
      throw StateError('Client $what signature does not verify');
    }
  }

  /// Client records the refund it built (libspiffy-b83).
  List<Event> _handleRecordRefundBuilt(
    ChannelState currentState,
    RecordRefundBuiltCommand cmd,
  ) {
    if (currentState.role != ChannelRole.client) {
      throw StateError('Only the client records its refund transaction');
    }
    if (currentState.status != ChannelStatus.accepted) {
      throw StateError('Channel not in accepted state '
          '(status=${currentState.status.name})');
    }
    final lockTimeUnix = currentState.lockTimeUnix;
    final clientAddress = currentState.clientAddressB58;
    if (lockTimeUnix == null || clientAddress == null) {
      throw StateError('Channel ${cmd.channelId} has no lockTime or client address');
    }
    _checkFundingOutput(currentState,
        fundingTxHex: cmd.fundingTxHex,
        fundingTxId: cmd.fundingTxId,
        outputIndex: cmd.fundingOutputIndex);

    final refund = _parseRefund(cmd.refundTxHex);
    _checkRefundSpends(currentState, refund,
        fundingTxId: cmd.fundingTxId, fundingOutputIndex: cmd.fundingOutputIndex);
    final clientScript = dartsv.P2PKHLockBuilder.fromAddress(
            dartsv.Address.fromBase58(clientAddress))
        .getScriptPubkey()
        .toHex();
    if (refund.outputs.isEmpty ||
        refund.outputs.any((o) => o.script.toHex() != clientScript)) {
      throw StateError('Refund transaction does not pay the client address '
          '$clientAddress');
    }

    // The client's own signature must be valid, or the refund can never be
    // completed whatever the server signs.
    _checkClientSignature(currentState, refund, cmd.clientSignatureHex, 'refund');

    return [
      RefundBuiltEvent(
        channelId: cmd.channelId,
        fundingTxId: cmd.fundingTxId,
        fundingOutputIndex: cmd.fundingOutputIndex,
        fundingTxHex: cmd.fundingTxHex,
        refundTxHex: cmd.refundTxHex,
        clientSignatureHex: cmd.clientSignatureHex,
        fundingInputSats: cmd.fundingInputSats,
        version: currentState.version + 1,
      ),
    ];
  }

  /// The client may broadcast its funding transaction only once its journal
  /// holds the verified, fully signed refund of that transaction
  /// (libspiffy-9f7).
  List<Event> _handleStartFundingBroadcast(
    ChannelState currentState,
    StartFundingBroadcastCommand cmd,
  ) {
    if (currentState.role != ChannelRole.client) {
      throw StateError('Only the client broadcasts the funding transaction');
    }
    if (currentState.status != ChannelStatus.refundSigned) {
      throw StateError('Refund not signed yet: funding is not broadcast before '
          'the client holds the countersigned refund '
          '(status=${currentState.status.name})');
    }
    final signedRefund = currentState.signedRefundTxHex;
    if (signedRefund == null) {
      throw StateError('No fully signed refund retained for channel '
          '${cmd.channelId}: refusing to broadcast its funding');
    }
    if (cmd.fundingTxId != currentState.fundingTxId ||
        (currentState.fundingTxHex ?? '').isEmpty) {
      throw StateError('Funding transaction ${cmd.fundingTxId} is not the one '
          'the refund spends (${currentState.fundingTxId})');
    }
    final refundInput = dartsv.Transaction.fromHex(signedRefund).inputs.single;
    if (refundInput.prevTxnId != cmd.fundingTxId ||
        refundInput.prevTxnOutputIndex != currentState.fundingOutputIndex) {
      throw StateError('The retained refund does not spend funding output '
          '${cmd.fundingTxId}:${currentState.fundingOutputIndex}');
    }
    // A start while one is still in flight is a retry after the broadcast's
    // outcome was lost (a crash mid-broadcast): it is the next attempt of
    // the same transaction, which ARC accepts again. The manager's mailbox
    // runs one broadcast at a time.

    return [
      FundingBroadcastStartedEvent(
        channelId: cmd.channelId,
        fundingTxId: cmd.fundingTxId,
        attempt: currentState.fundingBroadcastAttempts + 1,
        version: currentState.version + 1,
      ),
    ];
  }

  List<Event> _handleRecordFundingBroadcastFailed(
    ChannelState currentState,
    RecordFundingBroadcastFailedCommand cmd,
  ) {
    if (currentState.role != ChannelRole.client) {
      throw StateError('Only the client broadcasts the funding transaction');
    }
    if (currentState.status != ChannelStatus.refundSigned ||
        !currentState.fundingBroadcastInFlight ||
        cmd.fundingTxId != currentState.fundingTxId) {
      throw StateError('No funding broadcast of ${cmd.fundingTxId} in progress '
          '(status=${currentState.status.name})');
    }
    return [
      FundingBroadcastFailedEvent(
        channelId: cmd.channelId,
        fundingTxId: cmd.fundingTxId,
        error: cmd.error,
        walletRecorded: cmd.walletRecorded,
        version: currentState.version + 1,
      ),
    ];
  }

  /// The client wallet holds the funding transaction of the broadcast in
  /// progress (libspiffy-fsy).
  List<Event> _handleRecordFundingInWallet(
    ChannelState currentState,
    RecordFundingInWalletCommand cmd,
  ) {
    if (currentState.role != ChannelRole.client) {
      throw StateError('Only the client records its funding transaction');
    }
    if (currentState.status != ChannelStatus.refundSigned ||
        !currentState.fundingBroadcastInFlight ||
        cmd.fundingTxId != currentState.fundingTxId) {
      throw StateError('No funding broadcast of ${cmd.fundingTxId} in progress '
          '(status=${currentState.status.name})');
    }
    if (currentState.fundingRecordedInWallet) {
      throw StateError('Funding transaction ${cmd.fundingTxId} is already '
          'recorded in the wallet');
    }
    return [
      FundingRecordedInWalletEvent(
        channelId: cmd.channelId,
        fundingTxId: cmd.fundingTxId,
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

    var fundingTxHex = cmd.fundingTxHex;
    if (currentState.role == ChannelRole.client) {
      // The client opens only a channel whose verified refund it holds and
      // whose funding broadcast it started and did not see fail
      // (libspiffy-b83, libspiffy-9f7).
      if (currentState.signedRefundTxHex == null) {
        throw StateError('No fully signed refund retained for channel '
            '${cmd.channelId}');
      }
      if (cmd.fundingTxId != currentState.fundingTxId) {
        throw StateError('Funding transaction ${cmd.fundingTxId} is not the one '
            'the refund spends (${currentState.fundingTxId})');
      }
      if (!currentState.fundingBroadcastInFlight) {
        throw StateError('Funding transaction ${cmd.fundingTxId} has not been '
            'broadcast');
      }
      fundingTxHex = currentState.fundingTxHex ?? fundingTxHex;
    } else {
      // The server accepts only a funding transaction that locks the agreed
      // amount in the channel's 2-of-2: its refund signature and every
      // payment it acknowledges rely on that output (libspiffy-9f7).
      _checkFundingOutput(currentState,
          fundingTxHex: cmd.fundingTxHex,
          fundingTxId: cmd.fundingTxId,
          outputIndex: cmd.fundingOutputIndex);
      // ...that is the output whose refund it signed, when journaled (rows
      // from before libspiffy-fsy have none)...
      final signedFor = currentState.fundingTxId;
      if (signedFor != null &&
          (cmd.fundingTxId != signedFor ||
              cmd.fundingOutputIndex != currentState.fundingOutputIndex)) {
        throw StateError('Funding output ${cmd.fundingTxId}:'
            '${cmd.fundingOutputIndex} is not the one the signed refund spends '
            '($signedFor:${currentState.fundingOutputIndex})');
      }
      // ...and that came with its BEEF, which the manager SPV-validated
      // (libspiffy-fsy). A channel_open without one is refused.
      final beefHex = cmd.fundingBeefHex;
      if (beefHex == null || beefHex.isEmpty) {
        throw StateError('No BEEF for funding transaction ${cmd.fundingTxId}: '
            'the server opens a channel only for a funding transaction it '
            'SPV-validated');
      }
      _checkBeefCarriesFunding(beefHex,
          fundingTxId: cmd.fundingTxId, fundingTxHex: cmd.fundingTxHex);
    }

    return [
      ChannelOpenedEvent(
        channelId: cmd.channelId,
        fundingTxId: cmd.fundingTxId,
        fundingOutputIndex: cmd.fundingOutputIndex,
        fundingTxHex: fundingTxHex,
        fundingAncestorTxids: cmd.fundingAncestorTxids,
        fundingBeefHex: cmd.fundingBeefHex,
        initialClientBalanceSats: currentState.fundingAmountSats,
        initialServerBalanceSats: BigInt.zero,
        version: currentState.version + 1,
      ),
    ];
  }

  /// nLockTime values below this are block heights, not Unix times.
  static const int _lockTimeThreshold = 500000000;

  static int _nowUnix() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  /// Throws once [state] is within [timing]'s settlement margin of its lock
  /// time (bead libspiffy-ywbk). The server settles from then on, and a
  /// payment after it is one the refund may take back: the server
  /// acknowledged payments until the second the refund became valid.
  static void _checkBeforeSettlement(ChannelState state, ChannelTiming timing) {
    final lockTimeUnix = state.lockTimeUnix;
    if (lockTimeUnix == null) return;
    final settleBy = timing.settleByUnix(lockTimeUnix);
    if (_nowUnix() >= settleBy) {
      throw StateError('Channel ${state.channelId} settles from $settleBy, '
          '${timing.settlementMargin.inSeconds} s before its lock time $lockTimeUnix: '
          'it takes no more payments');
    }
  }

  /// What must be true of ANY payment on an open channel, whichever side
  /// journals it (bead libspiffy-ubl0).
  ///
  /// The two halves of one protocol used to disagree about this: the server
  /// checked non-negativity and the sum against the funding amount, the
  /// client checked neither. The client's own arithmetic made both true
  /// inductively — its expected balances are derived from the current ones —
  /// but that induction rests on the opening state being right, and a rule
  /// two handlers enforce differently is a rule that will diverge. Stated
  /// once, checked in both.
  ///
  /// Throws a [StateError] naming the invariant that does not hold.
  static void _checkPaymentInvariants(
    ChannelState currentState, {
    required BigInt amountSats,
    required BigInt newClientBalanceSats,
    required BigInt newServerBalanceSats,
  }) {
    // A payment moves a POSITIVE amount from the client to the server. A
    // zero payment burns a sequence number for nothing, and a negative one
    // is a payment backwards that no balance check would catch.
    if (amountSats <= BigInt.zero) {
      throw StateError('Payment amount must be positive');
    }
    if (newClientBalanceSats < BigInt.zero ||
        newServerBalanceSats < BigInt.zero) {
      throw StateError('Proposed balances must not be negative: client '
          '$newClientBalanceSats, server $newServerBalanceSats');
    }
    // The channel never holds more or less than it was funded with: the
    // 2-of-2 output is the only money there is.
    if (newClientBalanceSats + newServerBalanceSats !=
        currentState.fundingAmountSats) {
      throw StateError('Proposed balances '
          '$newClientBalanceSats + $newServerBalanceSats '
          'do not sum to the funding amount '
          '${currentState.fundingAmountSats}');
    }
    // Both sides at once: a payment that moves the wrong amount usually has
    // both balances wrong, and naming only the first one checked told half
    // the story (and made the answer depend on which handler asked).
    final expectedClient = currentState.clientBalanceSats - amountSats;
    final expectedServer = currentState.serverBalanceSats + amountSats;
    if (newClientBalanceSats != expectedClient ||
        newServerBalanceSats != expectedServer) {
      throw StateError('Proposed balances do not follow from a payment of '
          '$amountSats: proposed client $newClientBalanceSats / server '
          '$newServerBalanceSats, expected client $expectedClient / server '
          '$expectedServer');
    }
  }

  static dartsv.Transaction _parsePaymentTransaction(String paymentTxHex) {
    try {
      return dartsv.Transaction.fromHex(paymentTxHex);
    } catch (e) {
      throw StateError('Invalid payment transaction: $e');
    }
  }

  /// Checks [payment], the transaction a payment's balances are signed as,
  /// pays those balances (bead libspiffy-zj20): it spends exactly the
  /// funding output, is final now (lock time 0, so the server can broadcast
  /// the latest payment whenever it chooses), pays the server
  /// [serverBalanceSats] at the server's address, and pays nothing to
  /// anyone but the two parties. The client's output may be less than
  /// [clientBalanceSats]: the fee comes out of the client's share.
  ///
  /// The server's balance may go unpaid only while it is at or below the
  /// dust threshold, where the builder leaves the output out.
  ///
  /// The server used to countersign whatever transaction came with the
  /// balances, and the signature went back to the client: a transaction
  /// returning the whole funding output to the client was countersigned
  /// like any other, and every payment the client had made could be taken
  /// back. The refund is checked the same way before its signature is
  /// released ([_checkRefundSpends]).
  static void _checkPaymentTransaction(
    ChannelState state,
    dartsv.Transaction payment, {
    required BigInt clientBalanceSats,
    required BigInt serverBalanceSats,
    required FeeRate feeRate,
  }) {
    final fundingTxId = state.fundingTxId;
    final fundingOutputIndex = state.fundingOutputIndex;
    final clientAddress = state.clientAddressB58;
    final serverAddress = state.serverAddressB58;
    if (fundingTxId == null || fundingOutputIndex == null || clientAddress == null || serverAddress == null) {
      throw StateError('Channel ${state.channelId} has no funding output or party addresses journaled');
    }
    if (payment.inputs.length != 1 ||
        payment.inputs.single.prevTxnId != fundingTxId ||
        payment.inputs.single.prevTxnOutputIndex != fundingOutputIndex) {
      throw StateError('Payment transaction does not spend exactly the funding output '
          '$fundingTxId:$fundingOutputIndex');
    }
    if (payment.nLockTime != 0) {
      throw StateError('Payment transaction has lock time ${payment.nLockTime}: the server could not '
          'broadcast it until then');
    }

    final network = dartsv.Address.fromBase58(serverAddress).networkType;
    String p2pkh(String address) =>
        dartsv.P2PKHLockBuilder.fromAddress(dartsv.Address.fromBase58(address)).getScriptPubkey().toHex();
    final serverScript = p2pkh(serverAddress);
    final clientScript = p2pkh(clientAddress);
    var toServer = BigInt.zero;
    var toClient = BigInt.zero;
    for (final output in payment.outputs) {
      final script = output.script.toHex();
      if (script == serverScript) {
        toServer += output.satoshis;
      } else if (script == clientScript) {
        toClient += output.satoshis;
      } else {
        final isP2pkh = script.length == 50 && script.startsWith('76a914') && script.endsWith('88ac');
        final payee = isP2pkh
            ? dartsv.Address.fromPubkeyHash(script.substring(6, 46), network).toBase58()
            : 'script $script';
        throw StateError('Payment transaction pays ${output.satoshis} sats to $payee, '
            'which is neither party of channel ${state.channelId}');
      }
    }
    final serverUnpaidAsDust =
        toServer == BigInt.zero && serverBalanceSats <= BigInt.from(PaymentChannelBuilder.dustThreshold);
    if (toServer != serverBalanceSats && !serverUnpaidAsDust) {
      throw StateError('Payment transaction pays the server $toServer sats, not its balance of '
          '$serverBalanceSats');
    }
    if (toClient > clientBalanceSats) {
      throw StateError('Payment transaction pays the client $toClient sats, more than its balance of '
          '$clientBalanceSats');
    }
    // And it pays enough fee to be mined (bead libspiffy-zs4l): ARC's
    // policy rate on its signed size, the same fee the client's builder
    // pays ([PaymentChannelBuilder.paymentFee]). A payment below it is one
    // the server holds but could never get mined.
    final clientPubKeyHex = state.clientPubKeyHex;
    final serverPubKeyHex = state.serverPubKeyHex;
    if (clientPubKeyHex == null || serverPubKeyHex == null) {
      throw StateError('Channel ${state.channelId} has no channel keys journaled');
    }
    final multisigScript = dartsv.P2MSLockBuilder(
      [dartsv.SVPublicKey.fromHex(clientPubKeyHex), dartsv.SVPublicKey.fromHex(serverPubKeyHex)],
      2,
      sorting: true,
    ).getScriptPubkey();
    final fee = state.fundingAmountSats - toServer - toClient;
    final required = PaymentChannelBuilder.paymentFee(multisigScript, feeRate);
    if (fee < required) {
      throw StateError('Payment transaction pays a $fee sat fee; ARC\'s policy rate of $feeRate on its signed size '
          'asks $required');
    }
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

    // Business rule: Sufficient balance. Checked before the shared
    // invariants so the client keeps the answer that names its own problem
    // rather than the derived balance mismatch that follows from it.
    if (currentState.clientBalanceSats < cmd.amountSats) {
      throw StateError('Insufficient balance');
    }

    // Business rule: Channel not expired
    if (currentState.isExpired) {
      throw StateError('Channel has expired');
    }
    _checkBeforeSettlement(currentState, cmd.timing);

    // Business rule: Sequence must be incrementing
    if (cmd.sequenceNumber <= currentState.latestSequenceNumber) {
      throw StateError('Sequence number must be incrementing');
    }

    _checkPaymentInvariants(
      currentState,
      amountSats: cmd.amountSats,
      newClientBalanceSats: cmd.newClientBalanceSats,
      newServerBalanceSats: cmd.newServerBalanceSats,
    );
    // The same rule the server countersigns under (bead libspiffy-zj20), so
    // the client journals as its latest payment only a transaction that pays
    // the balances it records.
    _checkPaymentTransaction(
      currentState,
      _parsePaymentTransaction(cmd.paymentTxHex),
      clientBalanceSats: cmd.newClientBalanceSats,
      serverBalanceSats: cmd.newServerBalanceSats,
      feeRate: cmd.feeRate,
    );

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
    _checkBeforeSettlement(currentState, cmd.timing);

    // The same invariants the client journals under (audit M10, bead
    // libspiffy-ubl0): one statement of the rule, checked on both sides.
    _checkPaymentInvariants(
      currentState,
      amountSats: cmd.amountSats,
      newClientBalanceSats: cmd.proposedClientBalance,
      newServerBalanceSats: cmd.proposedServerBalance,
    );

    // And the transaction the server's signature is on pays those balances
    // (bead libspiffy-zj20). The manager releases the signature only once
    // this command is journaled, so a transaction refused here is one the
    // client never gets countersigned.
    final payment = _parsePaymentTransaction(cmd.paymentTxHex);
    _checkPaymentTransaction(
      currentState,
      payment,
      clientBalanceSats: cmd.proposedClientBalance,
      serverBalanceSats: cmd.proposedServerBalance,
      feeRate: cmd.feeRate,
    );
    // ...and the client signed it (bead libspiffy-c5zw). Without the
    // client's half the server holds a payment it can never broadcast, and
    // the acknowledgement is the server saying it was paid.
    _checkClientSignature(currentState, payment, cmd.clientSignatureHex, 'payment');

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

  /// This side's wallet now holds the transaction that ended the channel and
  /// paid it back (bead libspiffy-lfrv).
  ///
  /// Journaled so an interrupted ending can be resumed. The write itself is
  /// idempotent, but without this record the channel cannot tell a write that
  /// happened from one that was lost to a crash, and the aggregate's refusal
  /// to re-terminate a terminated channel means nothing would retry it.
  List<Event> _handleRecordReturnLegInWallet(
    ChannelState currentState,
    RecordReturnLegInWalletCommand cmd,
  ) {
    // The return leg is recorded as a channel ends: while a cooperative close
    // is in flight, or once it has expired or closed.
    if (currentState.status != ChannelStatus.closing &&
        currentState.status != ChannelStatus.closed &&
        currentState.status != ChannelStatus.expired) {
      throw StateError('Channel ${cmd.channelId} is not ending '
          '(status=${currentState.status.name})');
    }
    // Recorded once. A re-delivered ending re-reaches this with the write
    // already journaled.
    if (currentState.returnLegRecordedInWallet) {
      return const [];
    }

    return [
      ReturnLegRecordedInWalletEvent(
        channelId: cmd.channelId,
        txId: cmd.txId,
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
        settlementTxHex: cmd.settlementTxHex,
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
    // Business rule: the refund is final on the network. A node holds a
    // time lock to the chain's median time past, which trails the clock (by
    // about an hour on mainnet), not to the clock. Between the two ARC
    // accepts the refund and the node keeps it as non-final, dropping it for
    // any final spend of the funding output — the server's settlement —
    // while ARC still reports it seen: a claim journaled then may be a
    // refund that never happens (bead libspiffy-lpjh, seen on the localnet
    // regtest node).
    final lockTime = currentState.lockTimeUnix;
    if (lockTime == null || cmd.medianTimePastUnix <= lockTime) {
      throw StateError('Channel not yet expired on the network: the chain\'s '
          'median time past ${cmd.medianTimePastUnix} has not passed the lock '
          'time $lockTime');
    }

    // Business rule: Only client can claim refund
    if (currentState.role != ChannelRole.client) {
      throw StateError('Only client can claim refund');
    }

    // Business rule: a channel that ended cooperatively, or was never
    // accepted, has no refund to claim. Exactly one transaction can ever
    // spend the 2-of-2 funding output (BSV, first seen wins), and for a
    // closed channel that transaction is the settlement: journaling a refund
    // claim over it would say the channel ended in a way it did not, and the
    // broadcast behind it is a double spend the network refuses. `expired`
    // is deliberately NOT refused: an expiry observed first and the claim
    // that follows it are the same ending, and the claim is what carries the
    // broadcast (bead libspiffy-cqc).
    if (currentState.status == ChannelStatus.closed ||
        currentState.status == ChannelStatus.rejected) {
      throw StateError('Channel already terminated '
          '(status=${currentState.status.name}): no refund to claim');
    }

    // The journal records the txid of the actual refund transaction (audit
    // L4): the one the command carries (typically the fully signed refund)
    // or else the refund transaction this channel built.
    final refundTxHex = cmd.refundTxHex ??
        currentState.signedRefundTxHex ??
        currentState.refundTxHex;
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

    // Business rule: a channel's refund is claimed ONCE (bead
    // libspiffy-07mx). A repeat naming the same transaction is the same
    // ending told twice — the app did not hear the answer, and BSV is
    // first-seen-wins so re-broadcasting it is harmless — so it is answered
    // without journaling a second ending. A repeat naming a DIFFERENT
    // transaction is not a repeat: exactly one transaction can ever spend
    // the funding output, so the journal would be asserting two endings only
    // one of which can be true. `refundTxHex` is caller-supplied, which is
    // what makes that reachable.
    final claimed = currentState.refundClaimedTxId;
    if (claimed != null) {
      if (claimed == refundTxId) return const [];
      throw StateError('Channel ${cmd.channelId} already claimed its refund '
          'with $claimed; $refundTxId is a different transaction and only one '
          'of the two can spend the funding output');
    }

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
  // EVENT HANDLERS (each returns the next state)
  // ==========================================================================

  ChannelState _applyChannelRequested(ChannelState state, ChannelRequestedEvent event) {
    return state.copyWith(
      walletId: event.walletId,
      status: ChannelStatus.pending,
      role: ChannelRole.client,
      clientPeerId: event.clientPeerId,
      serverPeerId: event.serverPeerId,
      clientPubKeyHex: event.clientPubKeyHex,
      clientAddressB58: event.clientAddressB58,
      derivationIndex: event.derivationIndex,
      fundingAmountSats: event.fundingAmountSats,
      lockTimeUnix: event.lockTimeUnix,
      context: event.context,
      counterpartyMarker: event.counterpartyMarker,
      createdAt: event.timestamp,
      clientBalanceSats: event.fundingAmountSats,
      serverBalanceSats: BigInt.zero,
      version: event.version,
      lastModified: event.timestamp,
    );
  }

  ChannelState _applyChannelAccepted(ChannelState state, ChannelAcceptedEvent event) {
    return state.copyWith(
      walletId: state.walletId ?? event.walletId,
      status: ChannelStatus.accepted,
      role: state.role ?? ChannelRole.server,
      clientPeerId: state.clientPeerId ?? event.clientPeerId,
      clientPubKeyHex: state.clientPubKeyHex ?? event.clientPubKeyHex,
      clientAddressB58: state.clientAddressB58 ?? event.clientAddressB58,
      serverPubKeyHex: event.serverPubKeyHex,
      serverAddressB58: event.serverAddressB58,
      derivationIndex: state.derivationIndex ?? event.derivationIndex,
      // Set funding amount (server's aggregate needs this from the event)
      fundingAmountSats: state.fundingAmountSats == BigInt.zero ? event.fundingAmountSats : null,
      lockTimeUnix: state.lockTimeUnix ?? event.lockTimeUnix,
      context: state.context ?? event.context,
      counterpartyMarker:
          state.counterpartyMarker ?? event.counterpartyMarker,
      // Set initial balances (server's aggregate needs this from the event)
      clientBalanceSats: state.clientBalanceSats == BigInt.zero ? event.fundingAmountSats : null,
      version: event.version,
      lastModified: event.timestamp,
    );
  }

  ChannelState _applyChannelRejected(ChannelState state, ChannelRejectedEvent event) {
    return state.copyWith(
      status: ChannelStatus.rejected,
      version: event.version,
      lastModified: event.timestamp,
    );
  }

  ChannelState _applyServerAcceptanceRecorded(ChannelState state, ServerAcceptanceRecordedEvent event) {
    return state.copyWith(
      serverPubKeyHex: event.serverPubKeyHex,
      serverAddressB58: event.serverAddressB58,
      status: ChannelStatus.accepted,
      version: event.version,
      lastModified: event.timestamp,
    );
  }

  ChannelState _applyRefundBuilt(ChannelState state, RefundBuiltEvent event) {
    return state.copyWith(
      fundingTxId: event.fundingTxId,
      fundingOutputIndex: event.fundingOutputIndex,
      fundingTxHex: event.fundingTxHex,
      fundingInputSats: event.fundingInputSats,
      refundTxHex: event.refundTxHex,
      refundClientSigHex: event.clientSignatureHex,
      version: event.version,
      lastModified: event.timestamp,
    );
  }

  ChannelState _applyRefundCountersigned(ChannelState state, RefundCountersignedEvent event) {
    // Server side: the refund it signed and the funding output it spends.
    final serverFunding = event.fundingTxId != null;
    return state.copyWith(
      status: ChannelStatus.refundSigned,
      refundServerSigHex: event.serverSignatureHex,
      signedRefundTxHex: event.signedRefundTxHex ?? state.signedRefundTxHex,
      fundingTxId: serverFunding ? event.fundingTxId : state.fundingTxId,
      fundingOutputIndex: serverFunding ? event.fundingOutputIndex : state.fundingOutputIndex,
      fundingTxHex: serverFunding ? event.fundingTxHex ?? state.fundingTxHex : state.fundingTxHex,
      refundTxHex: event.refundTxHex ?? state.refundTxHex,
      version: event.version,
      lastModified: event.timestamp,
    );
  }

  ChannelState _applyFundingBroadcastStarted(ChannelState state, FundingBroadcastStartedEvent event) {
    return state.copyWith(
      fundingBroadcastAttempts: event.attempt,
      fundingBroadcastInFlight: true,
      fundingBroadcastError: null,
      version: event.version,
      lastModified: event.timestamp,
    );
  }

  ChannelState _applyFundingBroadcastFailed(ChannelState state, FundingBroadcastFailedEvent event) {
    return state.copyWith(
      fundingBroadcastInFlight: false,
      fundingBroadcastError: event.error,
      fundingRecordedInWallet: state.fundingRecordedInWallet || event.walletRecorded,
      version: event.version,
      lastModified: event.timestamp,
    );
  }

  ChannelState _applyFundingRecordedInWallet(ChannelState state, FundingRecordedInWalletEvent event) {
    return state.copyWith(
      fundingRecordedInWallet: true,
      version: event.version,
      lastModified: event.timestamp,
    );
  }

  ChannelState _applyChannelOpened(ChannelState state, ChannelOpenedEvent event) {
    return state.copyWith(
      status: ChannelStatus.open,
      fundingBroadcastInFlight: false,
      fundingRecordedInWallet: state.role == ChannelRole.client ? true : null,
      fundingTxId: event.fundingTxId,
      fundingOutputIndex: event.fundingOutputIndex,
      fundingTxHex: event.fundingTxHex,
      fundingAncestorTxids: event.fundingAncestorTxids,
      fundingBeefHex: event.fundingBeefHex,
      clientBalanceSats: event.initialClientBalanceSats,
      serverBalanceSats: event.initialServerBalanceSats,
      version: event.version,
      lastModified: event.timestamp,
    );
  }

  ChannelState _applyPaymentRecorded(ChannelState state, PaymentRecordedEvent event) {
    return state.copyWith(
      clientBalanceSats: event.newClientBalanceSats,
      serverBalanceSats: event.newServerBalanceSats,
      latestSequenceNumber: event.sequenceNumber,
      latestPaymentTxHex: event.paymentTxHex,
      latestPaymentTxId: event.paymentTxId,
      // Half of the 2-of-2 signature; the server's half arrives later in
      // `payment_ack` and cannot be combined without this one (libspiffy-z2px).
      latestClientSignatureHex: event.clientSignatureHex,
      version: event.version,
      lastModified: event.timestamp,
    );
  }

  ChannelState _applyPaymentAcknowledged(ChannelState state, PaymentAcknowledgedEvent event) {
    return state.copyWith(
      clientBalanceSats: event.newClientBalanceSats,
      serverBalanceSats: event.newServerBalanceSats,
      latestSequenceNumber: event.sequenceNumber,
      latestPaymentTxHex: event.fullySignedPaymentTxHex,
      version: event.version,
      lastModified: event.timestamp,
    );
  }

  ChannelState _applyPaymentCountersigned(
      ChannelState state, PaymentCountersignedEvent event) {
    // Balances and sequence are untouched: they were settled by the payment
    // this countersigns. What changes is that the channel now holds a
    // settlement it could broadcast, in place of a template it could not.
    return state.copyWith(
      latestPaymentTxHex: event.fullySignedPaymentTxHex,
      latestPaymentTxId: event.fullySignedPaymentTxId,
      version: event.version,
      lastModified: event.timestamp,
    );
  }

  ChannelState _applyReturnLegRecordedInWallet(
      ChannelState state, ReturnLegRecordedInWalletEvent event) {
    return state.copyWith(
      returnLegRecordedInWallet: true,
      version: event.version,
      lastModified: event.timestamp,
    );
  }

  ChannelState _applyChannelClosing(ChannelState state, ChannelClosingEvent event) {
    return state.copyWith(
      status: ChannelStatus.closing,
      version: event.version,
      lastModified: event.timestamp,
    );
  }

  ChannelState _applyChannelClosed(ChannelState state, ChannelClosedEvent event) {
    return state.copyWith(
      status: ChannelStatus.closed,
      clientBalanceSats: event.finalClientBalanceSats,
      serverBalanceSats: event.finalServerBalanceSats,
      closedAt: event.timestamp,
      version: event.version,
      lastModified: event.timestamp,
    );
  }

  ChannelState _applyRefundClaimed(ChannelState state, RefundClaimedEvent event) {
    return state.copyWith(
      status: ChannelStatus.expired,
      // What the status cannot say: `expired` is also what an expiry
      // observed before any claim leaves behind, and that state must stay
      // claimable (V-86). Recording the transaction is what lets a second
      // claim be told apart from the first (bead libspiffy-07mx). A replay
      // of two claims journaled by the old code keeps the FIRST, which is
      // the one that was broadcast and the one the projection kept.
      refundClaimedTxId: state.refundClaimedTxId ?? event.refundTxId,
      closedAt: event.timestamp,
      version: event.version,
      lastModified: event.timestamp,
    );
  }

  ChannelState _applyChannelExpired(ChannelState state, ChannelExpiredEvent event) {
    return state.copyWith(
      status: ChannelStatus.expired,
      closedAt: event.timestamp,
      version: event.version,
      lastModified: event.timestamp,
    );
  }

  // Helper to get next derivation index
}

