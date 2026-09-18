import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:dactor/dactor.dart';
import 'package:eventador/eventador.dart';
import 'package:dartsv/dartsv.dart' as dartsv;

import '../actors/payment_channel_messages.dart';
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
        'fundingBeefHex': s.fundingBeefHex,
        'fundingInputSats': s.fundingInputSats,
        'fundingBroadcastAttempts': s.fundingBroadcastAttempts,
        'fundingBroadcastInFlight': s.fundingBroadcastInFlight,
        'fundingBroadcastError': s.fundingBroadcastError,
        'fundingRecordedInWallet': s.fundingRecordedInWallet,
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
      // Snapshots written before libspiffy-b83/9f7 have no funding broadcast
      // or signed refund keys.
      fundingBeefHex: map['fundingBeefHex'] as String?,
      fundingInputSats: map['fundingInputSats'] as int?,
      fundingBroadcastAttempts: map['fundingBroadcastAttempts'] as int? ?? 0,
      fundingBroadcastInFlight: map['fundingBroadcastInFlight'] as bool? ?? false,
      fundingBroadcastError: map['fundingBroadcastError'] as String?,
      fundingRecordedInWallet: map['fundingRecordedInWallet'] as bool? ?? false,
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
      signedRefundTxHex: currentState.signedRefundTxHex,
      fundingInputSats: currentState.fundingInputSats,
      fundingRecordedInWallet: currentState.fundingRecordedInWallet,
      fundingBroadcastInFlight: currentState.fundingBroadcastInFlight,
      clientPeerId: currentState.clientPeerId,
      serverPeerId: currentState.serverPeerId,
      context: currentState.context,
      refundTxHex: currentState.refundTxHex,
      fundingBeefHex: currentState.fundingBeefHex,
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
    } else if (command is RecordRefundBuiltCommand) {
      return _handleRecordRefundBuilt(currentState, command);
    } else if (command is StartFundingBroadcastCommand) {
      return _handleStartFundingBroadcast(currentState, command);
    } else if (command is RecordFundingBroadcastFailedCommand) {
      return _handleRecordFundingBroadcastFailed(currentState, command);
    } else if (command is RecordFundingInWalletCommand) {
      return _handleRecordFundingInWallet(currentState, command);
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
        serverPeerId: cmd.serverPeerId,
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
    final keys = _channelKeys(currentState);
    final bool clientSignatureValid;
    try {
      final signature =
          dartsv.SVSignature.fromTxFormat(cmd.clientSignatureHex);
      final sighash = dartsv.Sighash().hash(refund, signature.nhashtype, 0,
          keys.redeemScript, currentState.fundingAmountSats);
      clientSignatureValid = _cryptoService.verifySignature(keys.client,
          signature, Uint8List.fromList(hex.decode(sighash).reversed.toList()));
    } catch (e) {
      throw StateError('Client refund signature is malformed: $e');
    }
    if (!clientSignatureValid) {
      throw StateError('Client refund signature does not verify');
    }

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

    // Business rule: a payment moves a positive amount from the client to
    // the server, as the server's own handler requires (bead libspiffy-kyw;
    // the mirror is _handleAcknowledgePayment). Without this, a zero payment
    // burned a sequence number for nothing, and a negative one passed every
    // other guard — 'Insufficient balance' is never true for a negative
    // amount — and journaled a "payment" that moved the amount back from the
    // server to the client, taking the server's balance below zero if it
    // held less than was clawed back.
    if (cmd.amountSats <= BigInt.zero) {
      throw StateError('Payment amount must be positive');
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

