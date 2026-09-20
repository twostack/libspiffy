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
import 'dart:typed_data';

import 'package:convert/convert.dart';

import 'package:dactor/dactor.dart';
import 'package:eventador/eventador.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:logging/logging.dart';

import '../core/aggregate_command_failures.dart';
import '../core/payment_channel_aggregate.dart';
import '../core/channel_commands.dart';
import '../core/channel_events.dart';
import '../core/channel_state.dart' show ChannelStatus;
import '../core/wallet_commands.dart';
import '../core/wallet_events.dart'
    show
        BeefAncestor,
        TransactionImportedEvent,
        TransactionRecordedEvent,
        UTXOSpentEvent;
import '../models/bitcoin_transaction.dart';
import '../models/bitcoin_utxo.dart' show UTXOStatus;
import '../services/ancestor_chain_service.dart';
import '../services/crypto_service.dart';
import '../services/payment_channel_builder.dart';
import '../storage/read_model_storage.dart';
import '../utils/beef.dart';
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
  /// (e.g., P2P adapters that need to react to channel state changes).
  ///
  /// In production (via LibSpiffyActorSystem), this is left null: the
  /// channel-event broadcaster is fed by the channel projection's
  /// `appliedEvents` stream, so consumers see events only after the read
  /// model has been updated. Tests may still pass a broadcaster directly
  /// if they don't run a projection.
  final void Function(ChannelEvent)? _eventBroadcaster;

  /// Optional reference to the channel ProjectionActor. When supplied,
  /// command handlers register `AwaitEventApplied` against this projection
  /// before responding to the original sender, so callers that synchronously
  /// query the read model after the response see the updated row. Without
  /// this, the response can race the projection's async Isar write
  /// (overnode_v2-8gh).
  final ActorRef? _channelProjection;

  /// ARCActor that broadcasts the client's funding transaction
  /// (libspiffy-9f7). Without one a client channel cannot be funded, so it
  /// cannot open.
  final ActorRef? _arcActor;

  /// Wallet ProjectionActor: when supplied, the funding transaction's wallet
  /// bookkeeping is awaited in the read model before the channel opens.
  final ActorRef? _walletProjection;

  /// How long a funding broadcast may take before it counts as failed.
  final Duration _broadcastTimeout;

  /// SPVActor that validates the BEEF of a funding transaction a client
  /// hands this node as server (libspiffy-fsy), with the same checks as a
  /// received payment. Without one a server channel cannot open.
  final ActorRef? _spvActor;

  /// Read model the client builds its funding BEEF from (the ancestors and
  /// merkle proofs of the wallet's UTXOs) and checks whether its wallet
  /// already holds the funding transaction (libspiffy-fsy). Without one the
  /// client sends no BEEF, which servers refuse.
  final ReadModelStorage? _storage;

  /// How long SPV validation of a funding BEEF may take.
  static const Duration _spvTimeout = Duration(seconds: 30);

  static const Duration _walletPersistTimeout = Duration(seconds: 10);

  /// How long the funding input spend waits for ARC's own deferred spend.
  static const Duration _arcSpendGrace = Duration(seconds: 1);

  /// Map of active channel aggregates: channelId -> ActorRef
  final Map<String, ActorRef> _channelAggregates = {};

  /// Track pending refund signing requests: channelId -> context
  final Map<
      String,
      ({
        ActorRef? sender,
        String refundTxHex,
        int lockTimeUnix,
        String fundingTxId,
        int fundingOutputIndex,
        String? fundingTxHex,
      })> _pendingRefundSignatures = {};

  /// Track pending payment signing requests: correlationId -> context
  final Map<String, _PaymentSignatureContext> _pendingPaymentSignatures = {};

  /// How long a multisig signing request may wait for WalletManager's reply
  /// before the caller is failed and its pending entry dropped.
  final Duration _signingTimeout;

  int _signRequestSeq = 0;

  PaymentChannelManagerActor({
    required ActorRef walletManager,
    required EventStore eventStore,
    required CryptoService cryptoService,
    dartsv.NetworkType networkType = dartsv.NetworkType.TEST,
    void Function(ChannelEvent)? eventBroadcaster,
    ActorRef? channelProjection,
    ActorRef? arcActor,
    ActorRef? walletProjection,
    Duration signingTimeout = const Duration(seconds: 30),
    Duration broadcastTimeout = const Duration(seconds: 45),
    ActorRef? spvActor,
    ReadModelStorage? storage,
  })  : _walletManager = walletManager,
        _spvActor = spvActor,
        _storage = storage,
        _eventStore = eventStore,
        _cryptoService = cryptoService,
        _networkType = networkType,
        _eventBroadcaster = eventBroadcaster,
        _channelProjection = channelProjection,
        _arcActor = arcActor,
        _walletProjection = walletProjection,
        _broadcastTimeout = broadcastTimeout,
        _signingTimeout = signingTimeout {
    _channelBuilder = PaymentChannelBuilder(cryptoService: cryptoService);
  }

  @override
  void preStart() {
  }

  /// Number of signing requests (refund, payment, acknowledgment) still
  /// awaiting WalletManager's reply. Every request leaves this map on
  /// success, failure and timeout alike.
  int get pendingSignatureCount =>
      _pendingRefundSignatures.length + _pendingPaymentSignatures.length;

  /// Stop the channel aggregates this manager spawned, so a host-owned actor
  /// system does not keep them running after libspiffy shuts down.
  @override
  void postStop() {
    final system = context.system;
    for (final ref in _channelAggregates.values) {
      unawaited(system.stop(ref));
    }
    _channelAggregates.clear();
  }

  /// Sends [command] to WalletManager and waits for its reply on a dedicated
  /// receiver actor, so every outcome reaches this call: the signed response,
  /// WalletManager's `{'error': ...}` map (unknown wallet, load failure), or
  /// silence (timeout).
  Future<MultisigTransactionSignedResponse> _requestMultisigSignature(
    String walletId,
    SignMultisigTransactionCommand command,
  ) =>
      _askWallet<MultisigTransactionSignedResponse>(
          walletId, command, 'Signing ${command.transactionId}');

  /// Sends [command] to WalletManager and waits for its reply of type [T]
  /// (see [_request]). WalletManager's `{'error': ...}` map fails the call;
  /// silence times out after the signing timeout ('[what] timed out').
  Future<T> _askWallet<T>(
    String walletId,
    WalletCommand command,
    String what,
  ) async =>
      await _request(
        _walletManager,
        WalletCommandMessage(walletId, command),
        accept: (reply) => reply is T,
        what: what,
        timeout: _signingTimeout,
      ) as T;

  /// Tells [message] to [target] and waits on a dedicated receiver actor for
  /// the first reply [accept] takes. Replies of wallet and ARC actors are
  /// not all LocalMessages, so `ask` cannot carry them. An `{'error': ...}`
  /// map fails the call; silence times out ('[what] timed out').
  Future<dynamic> _request(
    ActorRef target,
    dynamic message, {
    required bool Function(dynamic reply) accept,
    required String what,
    required Duration timeout,
  }) async {
    final completer = Completer<dynamic>();
    final receiver = await context.system.spawn(
      'channel-request-${++_signRequestSeq}-${DateTime.now().microsecondsSinceEpoch}',
      () => _ReplyReceiver(completer, accept),
    );
    try {
      target.tell(message, sender: receiver);
      return await completer.future.timeout(
        timeout,
        onTimeout: () => throw TimeoutException(
          '$what timed out after ${timeout.inMilliseconds} ms',
          timeout,
        ),
      );
    } finally {
      await context.system.stop(receiver);
    }
  }

  /// Requests the signature and hands the reply to
  /// [_handleMultisigSignedResponse], which consumes the pending entry. If
  /// signing fails, or the reply does not consume the entry, the entry is
  /// removed here and [onFailure] answers the caller.
  Future<void> _signAndContinue({
    required String walletId,
    required SignMultisigTransactionCommand command,
    required bool Function() removePending,
    required void Function(String error) onFailure,
  }) async {
    try {
      final response = await _requestMultisigSignature(walletId, command);
      await _handleMultisigSignedResponse(response);
      if (removePending()) {
        onFailure('Signing reply for ${command.transactionId} did not match '
            'the request (got ${response.originalTransactionId})');
      }
    } catch (e, stackTrace) {
      _log.warning('Signing ${command.transactionId} failed: $e', e, stackTrace);
      if (removePending()) onFailure(e.toString());
    }
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

  /// Sends [command] to the channel aggregate and returns the events it
  /// emitted, or throws a [StateError] carrying the aggregate's own error text
  /// when it rejected the command.
  ///
  /// The aggregate answers a command with its `List<Event>`, or, when a
  /// business rule throws, with `{'success': false, 'error': ...}` (audit
  /// M10). Every command goes through here, so a rejection is never forwarded
  /// to a caller as success or broadcast (libspiffy-lhd).
  ///
  /// A rejection leaves the aggregate running with its state untouched
  /// (libspiffy-201), so an existing channel keeps its aggregate and a bad
  /// command costs no journal recovery. An aggregate that rejected the
  /// command creating its channel holds no channel and is forgotten, so the
  /// channel keeps reading as not found.
  ///
  /// **An EMPTY list is a success, not a failure** (bead libspiffy-y8x3).
  /// The aggregate answers an idempotent repeat — a re-delivered
  /// `payment_ack`, a second `channel_accept` naming the same server, a
  /// return leg already recorded — with no events, because there is nothing
  /// new to journal. Treating that as `Command failed: no events emitted`
  /// turned every such repeat into a failure the caller saw, and on the
  /// peer-facing paths into a `channel_error` telling a counterparty its
  /// channel had failed. Only a shape that is neither a rejection nor a list
  /// is a failure here.
  Future<List<dynamic>> _askAggregate(
    String channelId,
    ActorRef aggregateRef,
    Command command,
  ) async {
    final response = await aggregateRef.ask(command);
    if (response is Map && response['success'] == false) {
      await _forgetAggregateWithoutJournal(channelId, aggregateRef);
      throw StateError(response['error']?.toString() ?? 'Command failed');
    }
    if (response is! List) {
      throw StateError('Command failed: the aggregate answered '
          '${response.runtimeType}, which is neither its events nor a '
          'rejection');
    }
    return response;
  }

  /// Forgets and stops [aggregateRef] when [channelId] has no journal (the
  /// command that would have created the channel was rejected). An aggregate
  /// of an existing channel is kept.
  Future<void> _forgetAggregateWithoutJournal(
      String channelId, ActorRef aggregateRef) async {
    if (await _eventStore.getHighestSequenceNumber('PaymentChannel_$channelId') > 0) {
      return;
    }
    if (identical(_channelAggregates[channelId], aggregateRef)) {
      _channelAggregates.remove(channelId);
    }
    if (aggregateRef.isAlive) {
      await context.system.stop(aggregateRef);
    }
  }

  /// The aggregate's answer to [ChannelStateQuery], or a [StateError] with
  /// its error text (e.g. a channel with no journal, audit L3).
  FullChannelStateResponse _stateOrThrow(dynamic state) {
    if (state is! FullChannelStateResponse) {
      throw StateError('Unexpected response type: ${state.runtimeType}');
    }
    if (!state.success) {
      throw StateError(state.error ?? 'Channel state query failed');
    }
    return state;
  }

  @override
  Future<void> onMessage(dynamic message) async {
    
    try {
      switch (message) {
        case final InitiateChannelMessage msg:
          await _handleInitiateChannel(msg);
          break;
        case final AcceptChannelMessage msg:
          await _handleAcceptChannel(msg);
          break;
        case final RecordServerAcceptanceMessage msg:
          await _handleRecordServerAcceptance(msg);
          break;
        case final BuildRefundTransactionMessage msg:
          await _handleBuildRefundTransaction(msg);
          break;
        case final SignRefundTransactionMessage msg:
          await _handleSignRefundTransaction(msg);
          break;
        case final MultisigTransactionSignedResponse msg:
          await _handleMultisigSignedResponse(msg);
          break;
        case final RecordRefundSignatureMessage msg:
          await _handleRecordRefundSignature(msg);
          break;
        case final OpenChannelMessage msg:
          await _handleOpenChannel(msg);
          break;
        case final RetryChannelFundingMessage msg:
          await _handleRetryChannelFunding(msg);
          break;
        case final ResendChannelOpenMessage msg:
          await _handleResendChannelOpen(msg);
          break;
        case final RecordPaymentMessage msg:
          await _handleRecordPayment(msg);
          break;
        case final AcknowledgePaymentMessage msg:
          await _handleAcknowledgePayment(msg);
          break;
        case final RecordPaymentCountersignatureMessage msg:
          await _handleRecordPaymentCountersignature(msg);
          break;
        case final CloseChannelMessage msg:
          await _handleCloseChannel(msg);
          break;
        case final ExpireChannelMessage msg:
          await _handleExpireChannel(msg);
          break;
        case final ClaimRefundMessage msg:
          await _handleClaimRefund(msg);
          break;
        case final QueryChannelStateMessage msg:
          await _handleQueryChannelState(msg);
          break;
        case final ChannelDetailsQueryMessage msg:
          await _handleChannelDetailsQuery(msg);
          break;
        default:
      }
    } catch (e, stackTrace) {
      // Every request-shaped handler owns its own failure reply: each wraps
      // its whole body in try/catch and answers the sender it captured
      // before its first await, in the response type that matches the
      // request (ChannelInitiatedResponse for InitiateChannelMessage,
      // ChannelClosedResponse for CloseChannelMessage, and so on), with
      // `success: false` and the error text. So nothing generic is answered
      // from here.
      //
      // This used to call a `_sendErrorResponse(dynamic, String)` that knew
      // only two of the twenty message types and replied to `context.sender`
      // — which, after the handler's awaits, is the sender of whatever
      // message arrived next, not of `message`. For those two types it could
      // only ever duplicate the reply the handler had already sent, and for
      // the other eighteen it did nothing at all. Removed (bead
      // libspiffy-q7a).
      //
      // Reaching this point therefore means a handler's own catch escaped,
      // which is a defect in that handler: log it loudly rather than guess a
      // response type and a recipient.
      _log.severe(
          'Unhandled error in ${message.runtimeType}; the handler failed to '
          'answer its sender: $e',
          e,
          stackTrace);
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

      // WalletManager answers an unknown wallet (or a load failure) with a
      // {'error': ..., 'walletId': ...} map rather than a typed response.
      if (addressResponse is Map && addressResponse['error'] != null) {
        throw StateError(addressResponse['error'].toString());
      }

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
      
      // Step 3: Send RequestChannelCommand with pre-computed keys
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
        counterpartyMarker: msg.counterpartyMarker,
      );
      
      // Send command and wait for its events (a rejection throws)
      final response = await _askAggregate(msg.channelId, aggregateRef, requestCmd);

      // Broadcast events to external subscribers (P2P adapter)
      _broadcastEvents(response);

      // The lock time is the one the aggregate journaled: computing it here
      // as well could differ by a second, and a refund built with that value
      // is refused (its nLockTime must be the channel's).
      final requested = response.whereType<ChannelRequestedEvent>().single;

      // Send success response
      originalSender?.tell(ChannelInitiatedResponse(
        channelId: msg.channelId,
        clientPubKeyHex: addressResponse.publicKeyHex!,
        clientAddressB58: addressResponse.address,
        derivationIndex: addressResponse.derivationIndex,
        lockTimeUnix: requested.lockTimeUnix,
        success: true,
      ));
      
    } catch (e, stackTrace) {
      _log.warning('Initiating channel ${msg.channelId} failed: $e', e, stackTrace);
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

      // WalletManager answers an unknown wallet (or a load failure) with a
      // {'error': ..., 'walletId': ...} map rather than a typed response.
      if (addressResponse is Map && addressResponse['error'] != null) {
        throw StateError(addressResponse['error'].toString());
      }

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
        serverPeerId: msg.serverPeerId,
        counterpartyMarker: msg.counterpartyMarker,
      );
      
      // Send command and wait for its events (a rejection throws)
      final acceptResponse = await _askAggregate(msg.channelId, aggregateRef, acceptCmd);

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
      
    } catch (e, stackTrace) {
      _log.warning('Accepting channel ${msg.channelId} failed: $e', e, stackTrace);
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

  /// Client records server's acceptance (stores server pubkey/address in
  /// aggregate). A sender, if any, gets [ServerAcceptanceRecordedResponse];
  /// a rejection used to be logged only.
  Future<void> _handleRecordServerAcceptance(RecordServerAcceptanceMessage msg) async {
    final originalSender = context.sender;

    try {
      // Get or spawn the channel aggregate
      final aggregateRef = await _getOrSpawnChannelAggregate(msg.channelId);
      
      // Send command to aggregate
      final cmd = RecordServerAcceptanceCommand(
        channelId: msg.channelId,
        serverPubKeyHex: msg.serverPubKeyHex,
        serverAddressB58: msg.serverAddressB58,
      );
      
      final response = await _askAggregate(msg.channelId, aggregateRef, cmd);

      // Broadcast events
      _broadcastEvents(response);

      originalSender?.tell(ServerAcceptanceRecordedResponse(
        channelId: msg.channelId,
        success: true,
      ));
    } catch (e, stackTrace) {
      _log.warning('Failed to record server acceptance: $e', e, stackTrace);
      originalSender?.tell(ServerAcceptanceRecordedResponse(
        channelId: msg.channelId,
        success: false,
        error: e.toString(),
      ));
    }
  }

  /// Build refund transaction (client side, step 3)
  Future<void> _handleBuildRefundTransaction(BuildRefundTransactionMessage msg) async {
    
    // Capture sender immediately
    final originalSender = context.sender;
    
    try {
      // Step 1: The channel must exist (loaded, or recoverable from its journal)
      final aggregateRef = await _channelAggregate(msg.channelId);

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
      
      
      // Step 3 (client): sign the refund with the channel key and journal it
      // with the funding transaction, so the countersigned refund can be
      // completed, verified and kept (libspiffy-b83). A server-side build
      // only returns the refund.
      final state = _stateOrThrow(await aggregateRef
          .ask(ChannelStateQuery(channelId: msg.channelId)));
      if (state.role == 'client') {
        await _journalClientRefund(msg, aggregateRef, state, refundTxResult);
      }

      originalSender?.tell(RefundTransactionBuiltResponse(
        channelId: msg.channelId,
        refundTxHex: refundTxResult.transactionHex,
        success: true,
      ));
      
    } catch (e, stackTrace) {
      _log.warning('Building the refund transaction for channel ${msg.channelId} failed: $e', e, stackTrace);
      originalSender?.tell(RefundTransactionBuiltResponse(
        channelId: msg.channelId,
        refundTxHex: '',
        success: false,
        error: e.toString(),
      ));
    }
  }

  /// Signs the client's refund with the channel key and journals it
  /// ([RecordRefundBuiltCommand]) with the funding transaction it spends.
  Future<void> _journalClientRefund(
    BuildRefundTransactionMessage msg,
    ActorRef aggregateRef,
    FullChannelStateResponse state,
    ChannelTransactionResult refund,
  ) async {
    final fundingTxHex = msg.fundingTxHex;
    if (fundingTxHex == null || fundingTxHex.isEmpty) {
      throw StateError('The client refund of channel ${msg.channelId} needs '
          'the signed funding transaction (fundingTxHex)');
    }
    final derivationIndex = state.derivationIndex;
    if (derivationIndex == null) {
      throw StateError('Channel ${msg.channelId} has no client key index');
    }
    final signed = await _requestMultisigSignature(
      state.walletId,
      SignMultisigTransactionCommand(
        walletId: state.walletId,
        transactionId: 'client-refund-${msg.channelId}',
        rawTransaction: refund.transactionHex,
        derivationIndex: derivationIndex,
        inputIndex: 0,
        prevOutValue: msg.fundingAmountSats.toInt(),
        redeemScriptHex: refund.multisigScript!.toHex(),
        sighashType: 0x41, // SIGHASH_ALL | SIGHASH_FORKID
      ),
    );
    if (!signed.success) {
      throw StateError('Signing the client refund failed: ${signed.error}');
    }
    final events = await _askAggregate(
      msg.channelId,
      aggregateRef,
      RecordRefundBuiltCommand(
        channelId: msg.channelId,
        fundingTxId: msg.fundingTxId,
        fundingOutputIndex: msg.fundingOutputIndex,
        fundingTxHex: fundingTxHex,
        refundTxHex: refund.transactionHex,
        clientSignatureHex: signed.signatureHex,
        fundingInputSats: msg.fundingInputSats,
      ),
    );
    _broadcastEvents(events);
  }

  /// Sign refund transaction (server side, step 4)
  ///
  /// Signs with the wallet that accepted the channel, at the channel key
  /// index, over the 2-of-2 of the journaled keys and funding amount
  /// (libspiffy-36f): nothing the request names selects a key. A request
  /// naming another wallet is refused. The signature is journaled (and
  /// returned) only for a refund of the funding output the request names,
  /// locked until the channel lockTime (libspiffy-fsy).
  Future<void> _handleSignRefundTransaction(SignRefundTransactionMessage msg) async {

    // Capture sender immediately
    final originalSender = context.sender;

    try {
      // Step 1: The channel must exist (loaded, or recoverable from its journal)
      final aggregateRef = await _channelAggregate(msg.channelId);
      final state = _stateOrThrow(await aggregateRef
          .ask(ChannelStateQuery(channelId: msg.channelId)));
      if (state.role != 'server') {
        throw StateError('Only the server of channel ${msg.channelId} signs '
            'its refund (role=${state.role})');
      }
      if (state.status != 'accepted') {
        throw StateError('Channel not in accepted state '
            '(channel ${msg.channelId}, status=${state.status})');
      }
      final walletId = state.walletId;
      if (walletId.isEmpty) {
        throw StateError('Channel ${msg.channelId} has no wallet');
      }
      if (msg.walletId.isNotEmpty && msg.walletId != walletId) {
        throw StateError('Refund signing request for channel ${msg.channelId} '
            'names wallet ${msg.walletId}, but the channel belongs to wallet '
            '$walletId: refused');
      }
      final derivationIndex = state.derivationIndex;
      final clientPubKeyHex = state.clientPubKeyHex;
      final serverPubKeyHex = state.serverPubKeyHex;
      final lockTimeUnix = state.lockTimeUnix;
      if (derivationIndex == null ||
          clientPubKeyHex == null ||
          serverPubKeyHex == null ||
          lockTimeUnix == null) {
        throw StateError('Channel ${msg.channelId} has no channel keys or '
            'lockTime journaled');
      }
      // The funding output the refund spends: the one the request names or,
      // when it names none, the refund's own input. The aggregate refuses a
      // refund that spends anything else, and the channel then opens only
      // for that output.
      String? fundingTxId = msg.fundingTxId;
      int? fundingOutputIndex = msg.fundingOutputIndex;
      if (fundingTxId == null || fundingOutputIndex == null) {
        final dartsv.Transaction refund;
        try {
          refund = dartsv.Transaction.fromHex(msg.refundTxHex);
        } catch (e) {
          throw StateError('Invalid refund transaction: $e');
        }
        if (refund.inputs.length != 1) {
          throw StateError('Refund transaction of channel ${msg.channelId} '
              'has ${refund.inputs.length} inputs, not the funding output');
        }
        fundingTxId = refund.inputs.single.prevTxnId;
        fundingOutputIndex = refund.inputs.single.prevTxnOutputIndex;
      }

      // Step 2: Build the redeem script (2-of-2 multisig) of the channel keys
      final redeemScript = dartsv.P2MSLockBuilder(
        [
          dartsv.SVPublicKey.fromHex(clientPubKeyHex),
          dartsv.SVPublicKey.fromHex(serverPubKeyHex),
        ],
        2,
        sorting: true, // BIP67 lexicographical sorting
      ).getScriptPubkey();

      // Step 3: Ask WalletManager to sign the refund transaction
      final signCmd = SignMultisigTransactionCommand(
        walletId: walletId,
        transactionId: 'refund-${msg.channelId}',
        rawTransaction: msg.refundTxHex,
        derivationIndex: derivationIndex,
        inputIndex: 0, // Refund TX has one input (the funding UTXO)
        prevOutValue: state.fundingAmountSats.toInt(),
        redeemScriptHex: redeemScript.toHex(),
        sighashType: 0x41, // SIGHASH_ALL | SIGHASH_FORKID
      );

      // Store pending signature context for when the response arrives
      final pending = (
        sender: originalSender,
        refundTxHex: msg.refundTxHex,
        lockTimeUnix: lockTimeUnix,
        fundingTxId: fundingTxId,
        fundingOutputIndex: fundingOutputIndex,
        fundingTxHex: msg.fundingTxHex,
      );
      _pendingRefundSignatures[msg.channelId] = pending;

      await _signAndContinue(
        walletId: walletId,
        command: signCmd,
        removePending: () {
          if (!identical(_pendingRefundSignatures[msg.channelId], pending)) {
            return false;
          }
          _pendingRefundSignatures.remove(msg.channelId);
          return true;
        },
        onFailure: (error) => originalSender?.tell(RefundTransactionSignedResponse(
          channelId: msg.channelId,
          serverSignatureHex: '',
          success: false,
          error: error,
        )),
      );

    } catch (e, stackTrace) {
      _log.warning('Signing the refund transaction for channel ${msg.channelId} failed: $e', e, stackTrace);
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
      final aggregateRef = await _channelAggregate(channelId);
      
      // Send RequestRefundSignatureCommand to aggregate
      final requestRefundSigCmd = RequestRefundSignatureCommand(
        channelId: channelId,
        fundingTxId: pending.fundingTxId,
        fundingOutputIndex: pending.fundingOutputIndex,
        fundingTxHex: pending.fundingTxHex,
        refundTxHex: pending.refundTxHex,
        lockTimeUnix: pending.lockTimeUnix,
        serverSignatureHex: response.signatureHex,
      );
      
      // Use ask() to get the events back and broadcast them. A rejection
      // (e.g. the channel is no longer `accepted`) fails the caller.
      final events = await _askAggregate(channelId, aggregateRef, requestRefundSigCmd);

      // Broadcast events to external subscribers (P2P adapter needs RefundCountersignedEvent)
      _broadcastEvents(events);
      
      // Send success response to original sender
      pending.sender?.tell(RefundTransactionSignedResponse(
        channelId: channelId,
        serverSignatureHex: response.signatureHex,
        success: true,
      ));
      
    } catch (e, stackTrace) {
      _log.warning('Completing the refund signature for channel $channelId failed: $e', e, stackTrace);
      pending.sender?.tell(RefundTransactionSignedResponse(
        channelId: channelId,
        serverSignatureHex: '',
        success: false,
        error: e.toString(),
      ));
    }
  }
  
  /// The payment transaction of [pending] with both signatures applied, or
  /// `''` when it cannot be assembled or does not verify against the funding
  /// output (bead libspiffy-f5p2).
  ///
  /// The acknowledgment itself is unchanged either way: the aggregate's
  /// balance and sequence rules decide whether the payment stands. What this
  /// decides is whether the channel ends up HOLDING a settlement transaction
  /// it could broadcast — and therefore whether a later cooperative close
  /// has anything to record in the wallet. A settlement that does not verify
  /// is not held: an absence, not an invented transaction.
  String _fullySignedPayment(
          _PaymentSignatureContext pending, String serverSignatureHex) =>
      _combineSignatures(
        channelId: pending.channelId,
        sequenceNumber: pending.sequenceNumber,
        paymentTxHex: pending.paymentTxHex,
        clientSignatureHex: pending.clientSignatureHex,
        serverSignatureHex: serverSignatureHex,
        clientPubKeyHex: pending.clientPubKeyHex,
        serverPubKeyHex: pending.serverPubKeyHex,
        fundingAmountSats: pending.fundingAmountSats,
      );

  /// Combines the two halves of the 2-of-2 signature over [paymentTxHex] and
  /// returns the settlement, or `''` when it cannot be assembled or does not
  /// verify against the funding output.
  ///
  /// Used by both sides (bead libspiffy-z2px): the server reaches it holding
  /// both halves at acknowledgement, the client when the server's half comes
  /// back in `payment_ack`. One implementation so the two cannot drift.
  String _combineSignatures({
    required String channelId,
    required int sequenceNumber,
    required String paymentTxHex,
    required String? clientSignatureHex,
    required String serverSignatureHex,
    required String? clientPubKeyHex,
    required String? serverPubKeyHex,
    required BigInt? fundingAmountSats,
  }) {
    if (clientPubKeyHex == null ||
        serverPubKeyHex == null ||
        fundingAmountSats == null ||
        clientSignatureHex == null ||
        clientSignatureHex.isEmpty ||
        serverSignatureHex.isEmpty ||
        paymentTxHex.isEmpty) {
      return '';
    }
    try {
      final clientPubKey = dartsv.SVPublicKey.fromHex(clientPubKeyHex);
      final serverPubKey = dartsv.SVPublicKey.fromHex(serverPubKeyHex);
      final signed = _channelBuilder.applyMultisigSignatures(
        transaction: dartsv.Transaction.fromHex(paymentTxHex),
        inputIndex: 0,
        clientSignature: dartsv.SVSignature.fromTxFormat(clientSignatureHex),
        serverSignature: dartsv.SVSignature.fromTxFormat(serverSignatureHex),
        clientPubKey: clientPubKey,
        serverPubKey: serverPubKey,
      );
      _channelBuilder.verifyMultisigSpend(
        signedTx: signed,
        redeemScript: _channelBuilder.buildMultisigRedeemScript(
            clientPubKey: clientPubKey, serverPubKey: serverPubKey),
        inputValueSats: fundingAmountSats,
      );
      return signed.serialize();
    } catch (e) {
      _log.warning('Channel $channelId: the payment at sequence '
          '$sequenceNumber was acknowledged, but no fully signed '
          'settlement could be assembled from the two signatures, so the '
          'channel holds none: $e');
      return '';
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
      
      
      final aggregateRef = await _channelAggregate(pending.channelId);
      
      if (pending.isAcknowledgment) {
        // Server acknowledging payment: both signatures are in hand here, so
        // this is where the fully signed settlement is assembled (bead
        // libspiffy-f5p2). It is journaled on PaymentAcknowledgedEvent and
        // becomes the transaction a cooperative close records in the wallet.
        final fullySigned = _fullySignedPayment(pending, response.signatureHex);

        final ackCmd = AcknowledgePaymentCommand(
          channelId: pending.channelId,
          amountSats: pending.amountSats,
          paymentTxHex: pending.paymentTxHex,
          clientSignatureHex: pending.clientSignatureHex!,
          serverSignatureHex: response.signatureHex,
          fullySignedPaymentTxHex: fullySigned,
          proposedSequence: pending.sequenceNumber,
          proposedClientBalance: pending.newClientBalance,
          proposedServerBalance: pending.newServerBalance,
        );

        final events = await _askAggregate(pending.channelId, aggregateRef, ackCmd);
        _broadcastEvents(events);

        pending.originalSender?.tell(PaymentAcknowledgedResponse(
          channelId: pending.channelId,
          sequenceNumber: pending.sequenceNumber,
          serverSignatureHex: response.signatureHex,
          fullySignedPaymentTxHex: fullySigned,
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
        
        final events = await _askAggregate(pending.channelId, aggregateRef, recordCmd);
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
    } catch (e, stackTrace) {
      _log.warning('Completing the payment signature for channel ${pending.channelId} failed: $e', e, stackTrace);
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
      final aggregateRef = await _channelAggregate(msg.channelId);
      
      // Send ProvideRefundSignatureCommand to aggregate
      final provideCmd = ProvideRefundSignatureCommand(
        channelId: msg.channelId,
        serverSignatureHex: msg.serverSignatureHex,
      );
      
      // Send command and wait for its events (a rejection throws)
      final response = await _askAggregate(msg.channelId, aggregateRef, provideCmd);

      // Broadcast events to external subscribers (P2P adapter)
      _broadcastEvents(response);
      
      originalSender?.tell(RefundSignatureRecordedResponse(
        channelId: msg.channelId,
        success: true,
      ));
      
    } catch (e, stackTrace) {
      _log.warning('Recording the refund signature for channel ${msg.channelId} failed: $e', e, stackTrace);
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
      await _openChannelFlow(msg);
      originalSender?.tell(ChannelOpenedResponse(
        channelId: msg.channelId,
        success: true,
      ));
    } catch (e, stackTrace) {
      _log.warning('Opening channel ${msg.channelId} failed: $e', e, stackTrace);
      originalSender?.tell(ChannelOpenedResponse(
        channelId: msg.channelId,
        success: false,
        error: e.toString(),
      ));
    }
  }

  /// Funds (client) or verifies (server) the channel's funding transaction
  /// and journals [ChannelOpenedEvent], throwing whatever went wrong.
  ///
  /// Split out of [_handleOpenChannel] so a retried funding (bead
  /// libspiffy-1n3) runs exactly this and answers in its own words: the
  /// caller decides what to tell whom, and a retry tells the counterparty
  /// nothing.
  Future<void> _openChannelFlow(OpenChannelMessage msg) async {
    // Declared out here so the catch below can abandon it (bead
    // libspiffy-kyw): a registration nobody will await is a closure, a reply
    // target and a timer the projection holds for the full window.
    ({Future<dynamic> done, void Function() cancel})? applied;

    try {
      final aggregateRef = await _channelAggregate(msg.channelId);

      // Client: the funding transaction reaches the network (and the wallet)
      // before the channel is open, and only once the verified refund is
      // journaled (libspiffy-9f7). A failure is journaled and rethrown.
      // Server: the funding transaction's BEEF must pass SPV validation
      // (libspiffy-fsy).
      final state = _stateOrThrow(await aggregateRef
          .ask(ChannelStateQuery(channelId: msg.channelId)));

      // This channel is already open on this funding output: the message is
      // a repeat, not a second open (bead libspiffy-1n3). A `channel_open`
      // the client re-sends because the first one was lost arrives here on
      // the server, and the server may well have got the first one after
      // all. Journaling nothing and answering success is the honest
      // response — the fact is already recorded, and opening twice is not a
      // thing that happened.
      //
      // Without this the aggregate throws 'Refund not signed yet' (its
      // guard is `status == refundSigned`), the failure comes back as a
      // failed open, and the adapter tells the *client* its channel failed:
      // a repair would be answered by the very message that says the
      // channel was abandoned. A repeat naming a DIFFERENT funding output
      // is not a repeat and still goes to the aggregate, which refuses it.
      if (state.status == ChannelStatus.open.name &&
          state.fundingTxId == msg.fundingTxId &&
          (state.fundingOutputIndex ?? 0) == msg.fundingOutputIndex) {
        _log.info('Channel ${msg.channelId} is already open on funding '
            'output ${msg.fundingTxId}:${msg.fundingOutputIndex}: the open '
            'is a repeat and nothing is journaled again');
        return;
      }

      final String? fundingBeefHex;
      if (state.role == 'client') {
        fundingBeefHex = await _fundClientChannel(msg, aggregateRef, state);
      } else {
        fundingBeefHex = msg.fundingBeefHex;
        await _verifyFundingBeef(msg, state);
      }

      final openCmd = OpenChannelCommand(
        channelId: msg.channelId,
        fundingTxId: msg.fundingTxId,
        fundingOutputIndex: msg.fundingOutputIndex,
        fundingTxHex: msg.fundingTxHex,
        fundingAncestorTxids:
            _beefAncestorTxids(fundingBeefHex, msg.fundingTxId),
        fundingBeefHex: fundingBeefHex,
      );

      // Register projection-applied awaiter BEFORE telling the aggregate.
      // Same pattern as PaymentCoordinatorActor._recordOutgoingTransaction:
      // if the projection processes the event very fast, registering after
      // would miss the resolution window.
      applied = _awaitApplied(_channelProjection,
          (e) => e is ChannelOpenedEvent && e.channelId == msg.channelId,
          const Duration(seconds: 10));

      // Send command and wait for its events (a rejection throws)
      final response = await _askAggregate(msg.channelId, aggregateRef, openCmd);

      // Broadcast events to external subscribers (P2P adapter).
      // In production wiring this is a no-op (eventBroadcaster is null —
      // the channel-event stream is fed from the projection's appliedEvents).
      // Tests that supply their own broadcaster still get events here.
      _broadcastEvents(response);

      // Wait for the channel projection to apply the ChannelOpenedEvent
      // before responding, so a caller that synchronously queries the
      // read model after receiving ChannelOpenedResponse sees the updated
      // row (closes overnode_v2-8gh). If no projection was wired (legacy
      // test setup), this is skipped.
      if (applied != null) {
        final result = await applied.done;
        if (result is AwaitFailed) {
          _log.warning(
              'ChannelProjection apply timeout for ${msg.channelId}: ${result.reason}');
        }
        // Awaited: the catch below must not also cancel it.
        applied = null;
      }
    } catch (_) {
      // Nothing will await the registration now (bead libspiffy-kyw).
      applied?.cancel();
      rethrow;
    }
  }

  /// Broadcast the funding transaction of a channel whose funding broadcast
  /// failed, so the open can finish (bead libspiffy-1n3).
  ///
  /// The gap this closes: restart recovery is reactive, so a client whose
  /// funding broadcast failed — ARC unreachable, or the process gone before
  /// the answer arrived — had no way to ask for another attempt. The only
  /// route was the internal [OpenChannelMessage], which needs the funding
  /// transaction spelled out; a host does not have it, which is why the
  /// end-to-end tests used to read it out of a storage row.
  ///
  /// So the funding transaction is **read from the channel's own state**,
  /// never taken from the caller. The aggregate refuses a broadcast naming a
  /// different transaction from the one the countersigned refund spends, so
  /// a retry can only ever re-broadcast that one.
  ///
  /// Only the client of a channel still in `refundSigned` can retry: that is
  /// exactly the state the aggregate will accept a funding broadcast in.
  /// Every other state is refused **here**, before anything is told the
  /// aggregate, because driving the open flow for (say) an already-open
  /// channel makes the aggregate throw 'Refund not signed yet', which the
  /// adapter would report to the counterparty as a failed channel. A repair
  /// command must never do that: the refusal is answered locally and the
  /// peer is told nothing.
  ///
  /// Retrying is safe at the aggregate and in the wallet. A second start is
  /// deliberately permitted (it is the next attempt of the same
  /// transaction); the funding is recorded in the wallet once, guarded by
  /// the journal, the wallet read model and the aggregate alike; and the
  /// inputs of a failed broadcast are left **reserved**, marked spent only
  /// once ARC accepts, so no retry can double-spend them. This is BSV:
  /// re-broadcasting the identical transaction is the whole repair, and no
  /// fee is touched.
  Future<void> _handleRetryChannelFunding(
      RetryChannelFundingMessage msg) async {
    final originalSender = context.sender;
    String? fundingTxId;

    try {
      final aggregateRef =
          await _channelAggregate(msg.channelId, notFound: 'Channel not found');
      final state = _stateOrThrow(
          await aggregateRef.ask(ChannelStateQuery(channelId: msg.channelId)));

      if (state.role != 'client') {
        throw StateError('Only the client of channel ${msg.channelId} '
            'broadcasts its funding transaction; this node is its '
            '${state.role ?? 'unknown role'}');
      }
      if (state.status != ChannelStatus.refundSigned.name) {
        throw StateError(
            'Channel ${msg.channelId} is not waiting for its funding '
            'broadcast (status=${state.status}): there is nothing to retry'
            '${state.status == ChannelStatus.open.name ? '. The channel is already open here; ResendChannelOpenCommand re-sends the channel_open the server may have missed' : ''}');
      }
      fundingTxId = state.fundingTxId;
      final fundingTxHex = state.fundingTxHex;
      if (fundingTxId == null ||
          fundingTxId.isEmpty ||
          fundingTxHex == null ||
          fundingTxHex.isEmpty) {
        throw StateError('Channel ${msg.channelId} holds no funding '
            'transaction to broadcast: an absence, not one to invent');
      }

      await _openChannelFlow(OpenChannelMessage(
        channelId: msg.channelId,
        fundingTxId: fundingTxId,
        fundingOutputIndex: state.fundingOutputIndex ?? 0,
        fundingTxHex: fundingTxHex,
      ));

      originalSender?.tell(ChannelFundingRetriedResponse(
        channelId: msg.channelId,
        fundingTxId: fundingTxId,
        success: true,
      ));
    } catch (e, stackTrace) {
      _log.warning(
          'Retrying the funding of channel ${msg.channelId} failed: $e',
          e,
          stackTrace);
      originalSender?.tell(ChannelFundingRetriedResponse(
        channelId: msg.channelId,
        fundingTxId: fundingTxId,
        success: false,
        error: e.toString(),
      ));
    }
  }

  /// The `channel_open` payload of an open channel, so the adapter can send
  /// it to the server again (bead libspiffy-1n3).
  ///
  /// A question about state, not a command: **nothing is journaled**. A
  /// re-send is not a new fact about the channel, and a second
  /// `ChannelOpenedEvent` would be a lie about how many times it opened.
  /// The payload is rebuilt from the funding transaction, output index and
  /// BEEF the opening journaled, so the repeat is byte-for-byte the message
  /// that was lost.
  ///
  /// Refused for anything but a client-side channel that is `open` here.
  /// In particular this never runs the open flow: that path throws for a
  /// channel that is already open, and the adapter reports a failed open to
  /// the counterparty as `channel_error` — a host repairing a lost message
  /// would tell the server the channel had failed.
  Future<void> _handleResendChannelOpen(ResendChannelOpenMessage msg) async {
    final originalSender = context.sender;

    try {
      final aggregateRef =
          await _channelAggregate(msg.channelId, notFound: 'Channel not found');
      final state = _stateOrThrow(
          await aggregateRef.ask(ChannelStateQuery(channelId: msg.channelId)));

      if (state.role != 'client') {
        throw StateError('Only the client of channel ${msg.channelId} sends '
            'channel_open; this node is its ${state.role ?? 'unknown role'}');
      }
      if (state.status != ChannelStatus.open.name) {
        throw StateError('Channel ${msg.channelId} is not open here '
            '(status=${state.status}): there is no channel_open to re-send'
            '${state.status == ChannelStatus.refundSigned.name ? '. Its funding has not reached the network; RetryChannelFundingCommand broadcasts it again' : ''}');
      }
      final fundingTxId = state.fundingTxId;
      final fundingTxHex = state.fundingTxHex;
      if (fundingTxId == null ||
          fundingTxId.isEmpty ||
          fundingTxHex == null ||
          fundingTxHex.isEmpty) {
        throw StateError('Channel ${msg.channelId} is open but holds no '
            'funding transaction: there is no channel_open to rebuild');
      }

      originalSender?.tell(ChannelOpenResentResponse(
        channelId: msg.channelId,
        walletId: state.walletId,
        fundingTxId: fundingTxId,
        fundingOutputIndex: state.fundingOutputIndex ?? 0,
        fundingTxHex: fundingTxHex,
        fundingBeefHex: state.fundingBeefHex,
        success: true,
      ));
    } catch (e, stackTrace) {
      _log.warning(
          'Re-sending channel_open of channel ${msg.channelId} failed: $e',
          e,
          stackTrace);
      originalSender?.tell(ChannelOpenResentResponse(
        channelId: msg.channelId,
        success: false,
        error: e.toString(),
      ));
    }
  }

  /// Server side (libspiffy-fsy): [msg] must carry the BEEF of its funding
  /// transaction, and the SPVActor must accept it as it accepts a received
  /// payment (merkle proofs against our headers, every input covered back to
  /// proven transactions, input scripts); the transaction must also not pay
  /// out more than its inputs hold. No block scanning, no address
  /// monitoring: the client hands us the proof.
  Future<void> _verifyFundingBeef(
      OpenChannelMessage msg, FullChannelStateResponse state) async {
    final beefHex = msg.fundingBeefHex;
    if (beefHex == null || beefHex.isEmpty) {
      throw StateError('channel_open of channel ${msg.channelId} carries no '
          'BEEF of funding transaction ${msg.fundingTxId}: the server opens a '
          'channel only for a funding transaction it SPV-validated');
    }
    final spvActor = _spvActor;
    if (spvActor == null) {
      throw StateError('No SPV actor configured: cannot validate funding '
          'transaction ${msg.fundingTxId} of channel ${msg.channelId}');
    }
    final BEEF beef;
    try {
      beef = BEEF.parse(Uint8List.fromList(hex.decode(beefHex)));
    } catch (e) {
      throw StateError('Invalid funding BEEF for channel ${msg.channelId}: $e');
    }
    final entry = beef
        .findTransactionByTxid(Uint8List.fromList(hex.decode(msg.fundingTxId)));
    if (entry == null ||
        hex.encode(entry['txData'] as List<int>) !=
            msg.fundingTxHex.toLowerCase()) {
      throw StateError('The funding BEEF of channel ${msg.channelId} does not '
          'carry funding transaction ${msg.fundingTxId}');
    }

    final reply = await _request(
      spvActor,
      // A question, not a receive (bead libspiffy-6e5): the server owns
      // nothing in the client's funding transaction, so there is no wallet
      // to credit. ValidateCounterpartyTransactionMessage runs the same
      // checks and answers this actor only; the receive path told the
      // WalletManager a result naming no wallet, which it logged and dropped
      // on every channel open.
      ValidateCounterpartyTransactionMessage(
        transactionId: msg.fundingTxId,
        beef: beef,
        fromCounterparty: state.clientPeerId ?? '',
      ),
      accept: (r) => r is SPVValidationResult && r.txid == msg.fundingTxId,
      what: 'SPV validation of funding transaction ${msg.fundingTxId}',
      timeout: _spvTimeout,
    ) as SPVValidationResult;
    if (!reply.isValid) {
      throw StateError('Funding transaction ${msg.fundingTxId} failed SPV '
          'validation: ${reply.validationError}');
    }

    // Fee sanity: the script checks do not compare values. A mined funding
    // transaction was already accepted by miners.
    if (entry['hasMerkleProof'] != true) {
      final funding = dartsv.Transaction.fromHex(msg.fundingTxHex);
      var inputSats = BigInt.zero;
      for (final input in funding.inputs) {
        final parent = beef.findTransactionByTxid(
            Uint8List.fromList(hex.decode(input.prevTxnId)));
        final parentTx = parent == null
            ? null
            : dartsv.Transaction.fromHex(
                hex.encode(parent['txData'] as List<int>));
        if (parentTx == null ||
            input.prevTxnOutputIndex >= parentTx.outputs.length) {
          throw StateError('Funding transaction ${msg.fundingTxId}: the value '
              'of input ${input.prevTxnId}:${input.prevTxnOutputIndex} is not '
              'in its BEEF');
        }
        inputSats += parentTx.outputs[input.prevTxnOutputIndex].satoshis;
      }
      final outputSats = funding.outputs
          .fold<BigInt>(BigInt.zero, (sum, o) => sum + o.satoshis);
      if (outputSats > inputSats) {
        throw StateError('Funding transaction ${msg.fundingTxId} pays out '
            '$outputSats sats from $inputSats sats of inputs: negative fee');
      }
    }
  }

  /// The txids of [beefHex] other than [fundingTxId] (none without a BEEF).
  List<String> _beefAncestorTxids(String? beefHex, String fundingTxId) {
    if (beefHex == null || beefHex.isEmpty) return const [];
    try {
      final beef = BEEF.parse(Uint8List.fromList(hex.decode(beefHex)));
      return [
        for (final tx in beef.txs)
          if (hex.encode(beef.calculateTxid(tx)) != fundingTxId)
            hex.encode(beef.calculateTxid(tx)),
      ];
    } catch (_) {
      return const [];
    }
  }

  /// Client side (libspiffy-fsy): the BEEF of [funding] built from the read
  /// model, the ancestors of its inputs back to transactions with merkle
  /// proofs. Null (with a warning) when no read model is configured.
  Future<String?> _buildFundingBeef(
      String channelId, dartsv.Transaction funding) async {
    final storage = _storage;
    if (storage == null) {
      _log.warning('No read model configured: the funding transaction of '
          'channel $channelId is sent without a BEEF, which servers refuse');
      return null;
    }
    final service = AncestorChainService(storage: storage);
    final chain = await service.collectAncestorChainForUtxos(
        {for (final input in funding.inputs) input.prevTxnId}.toList());
    if (!chain.isValid) {
      throw StateError('Cannot build the BEEF of funding transaction '
          '${funding.id}: ${chain.error}');
    }
    final epoch = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    final result = await service.createBeefWithAncestry(
      newTransaction: BitcoinTransaction(
        txid: funding.id,
        rawHex: funding.serialize(),
        status: TransactionStatus.pending,
        inputValue: BigInt.zero,
        outputValue: BigInt.zero,
        fee: BigInt.zero,
        receivingAddresses: const [],
        sendingAddresses: const [],
        netAmount: BigInt.zero,
        createdAt: epoch,
        updatedAt: epoch,
        lockTime: funding.nLockTime,
        version: funding.version,
      ),
      ancestorTransactions: chain.ancestorTransactions,
      merkleProofs: chain.merkleProofs,
    );
    if (!result.success || result.beefHex == null) {
      throw StateError('Cannot build the BEEF of funding transaction '
          '${funding.id}: ${result.error}');
    }
    return result.beefHex;
  }

  /// Why wallet [walletId] no longer holds the inputs of funding
  /// transaction [txid], or null while it still does (bead libspiffy-z5uo).
  ///
  /// The funding is recorded as a deferred payment (`deferSpend: true`,
  /// purpose `channel-funding`) before it is ever broadcast, so the wallet's
  /// own record of that payment is the authoritative answer to "are the
  /// inputs still ours to spend". `cancelled` and `failed` released them;
  /// `reclaimed` spent them back to the wallet with a transaction the
  /// network has. In all three the funding transaction can no longer be
  /// broadcast honestly: its inputs are free, and re-broadcasting it would
  /// try to spend money the wallet has already given back to itself or to
  /// another payment.
  ///
  /// `outstanding` (the hold is intact), `seen` and `mined` (this very
  /// transaction spent them) are all fine. **An absent record is fine too**:
  /// a funding recorded before holds were journaled, or one never recorded
  /// at all, is an absence, not evidence that anything was released — the
  /// refusal rests on a positive record, never on a missing one.
  ///
  /// Reading the deferred-payment record rather than the UTXO rows is
  /// deliberate: a UTXO that is `available` again says only that nothing
  /// holds it *now*, which is also true of an input some other payment has
  /// since taken and spent. The payment record says who released it and
  /// why, which is what a refusal has to be able to state.
  Future<String?> _fundingHoldReleased(String walletId, String txid) async {
    final storage = _storage;
    if (storage == null) return null;
    final DeferredPaymentState state;
    final String? reason;
    try {
      final payment = await storage.getDeferredPayment(walletId, txid);
      if (payment == null) return null;
      state = payment.state;
      reason = payment.resolutionReason;
    } catch (e) {
      // An unreadable read model is not evidence either.
      _log.warning('Reading the deferred payment $txid of wallet $walletId '
          'failed: $e');
      return null;
    }
    final detail = reason == null || reason.isEmpty ? '' : ' ($reason)';
    // Exhaustive on purpose: a state added later must be classified here,
    // not fall into a silent "still held".
    return switch (state) {
      DeferredPaymentState.cancelled => 'it was cancelled$detail',
      DeferredPaymentState.failed => 'the network rejected it$detail',
      DeferredPaymentState.reclaimed =>
        'the wallet reclaimed its inputs$detail',
      DeferredPaymentState.outstanding ||
      DeferredPaymentState.seen ||
      DeferredPaymentState.mined =>
        null,
    };
  }

  /// Whether [walletId]'s read model already holds transaction [txid].
  Future<bool> _walletHoldsTransaction(String walletId, String txid) async {
    final storage = _storage;
    if (storage == null) return false;
    try {
      return await storage.getTransaction(txid, walletId: walletId) != null;
    } catch (e) {
      _log.warning('Looking up $txid in wallet $walletId failed: $e');
      return false;
    }
  }

  /// Broadcasts the client's funding transaction and records it in the
  /// client wallet (libspiffy-9f7), returning its BEEF (libspiffy-fsy).
  ///
  /// Order: [StartFundingBroadcastCommand] is journaled first (the aggregate
  /// refuses it unless the verified, fully signed refund of this funding
  /// transaction is journaled); then the transaction is recorded in the
  /// wallet (inputs kept reserved, change credited pending, the 2-of-2
  /// output reserved for the channel) and that is journaled
  /// ([RecordFundingInWalletCommand]); then its BEEF is built; then ARC
  /// broadcasts it; then its inputs are marked spent. Any failure journals
  /// [RecordFundingBroadcastFailedCommand] and is rethrown, leaving the
  /// channel unopened and its inputs reserved for a retry of the same
  /// transaction.
  ///
  /// A retry, also one after a restart that interrupted a broadcast, does
  /// not record the transaction in the wallet again when the channel journal
  /// or the wallet read model shows it recorded.
  Future<String?> _fundClientChannel(
    OpenChannelMessage msg,
    ActorRef aggregateRef,
    FullChannelStateResponse state,
  ) async {
    // The wallet may have given the funding inputs back since the last
    // attempt (bead libspiffy-z5uo). A failed broadcast leaves the channel
    // in `refundSigned` for good, so nothing in the channel's own status
    // says the money is gone; the wallet's deferred-payment record does.
    // Checked here, before anything is journaled, so a channel whose
    // funding was abandoned is refused in plain words rather than failing
    // obscurely at signing or at ARC — and so the refusal covers every
    // route to a re-broadcast, the public retry and the internal
    // OpenChannelMessage alike.
    final released =
        await _fundingHoldReleased(state.walletId, msg.fundingTxId);
    if (released != null) {
      throw StateError(
          'The funding transaction ${msg.fundingTxId} of channel '
          '${msg.channelId} can no longer be broadcast: wallet '
          '${state.walletId} no longer holds its inputs, because $released. '
          'Broadcasting it now would spend inputs the wallet has released '
          'and may have spent elsewhere. Open a new channel instead');
    }

    final started = await _askAggregate(
      msg.channelId,
      aggregateRef,
      StartFundingBroadcastCommand(
          channelId: msg.channelId, fundingTxId: msg.fundingTxId),
    );
    _broadcastEvents(started);

    final fundingTxId = msg.fundingTxId;
    final fundingTxHex = state.fundingTxHex!;
    var walletRecorded = state.fundingRecordedInWallet;
    try {
      final arcActor = _arcActor;
      if (arcActor == null) {
        throw StateError('No transaction broadcaster (ARC actor) configured');
      }
      final funding = dartsv.Transaction.fromHex(fundingTxHex);
      if (!walletRecorded &&
          await _walletHoldsTransaction(state.walletId, funding.id)) {
        // An attempt interrupted before its record was journaled.
        walletRecorded = true;
      }
      if (!walletRecorded) {
        await _recordFundingInWallet(msg.channelId, state, funding);
        walletRecorded = true;
      }
      if (!state.fundingRecordedInWallet) {
        _broadcastEvents(await _askAggregate(
          msg.channelId,
          aggregateRef,
          RecordFundingInWalletCommand(
              channelId: msg.channelId, fundingTxId: fundingTxId),
        ));
      }
      final fundingBeefHex = await _buildFundingBeef(msg.channelId, funding);

      final reply = await _request(
        arcActor,
        BroadcastTransactionMessage(state.walletId, fundingTxHex, fundingTxId),
        accept: (r) => r is BroadcastSuccessMessage || r is BroadcastFailedMessage,
        what: 'Broadcasting funding transaction $fundingTxId',
        timeout: _broadcastTimeout,
      );
      if (reply is BroadcastFailedMessage) {
        throw StateError('Funding broadcast failed: ${reply.error}');
      }
      if (reply is! BroadcastSuccessMessage) {
        throw StateError('Funding broadcast failed: unexpected reply '
            '${reply.runtimeType}');
      }

      await _spendFundingInputs(state.walletId, funding);
      return fundingBeefHex;
    } catch (e, stackTrace) {
      _log.warning('Funding channel ${msg.channelId} failed: $e', e, stackTrace);
      final applied = _awaitChannelEvent((event) =>
          event is FundingBroadcastFailedEvent &&
          event.channelId == msg.channelId);
      final failed = await _askAggregate(
        msg.channelId,
        aggregateRef,
        RecordFundingBroadcastFailedCommand(
          channelId: msg.channelId,
          fundingTxId: fundingTxId,
          error: e is StateError ? e.message : e.toString(),
          walletRecorded: walletRecorded,
        ),
      );
      _broadcastEvents(failed);
      await applied;
      rethrow;
    }
  }

  /// Registers an awaiter on the channel projection (if any) for the first
  /// applied event matching [predicate]; completes with null without one.
  Future<dynamic> _awaitChannelEvent(bool Function(Event) predicate) =>
      _awaitApplied(_channelProjection, predicate, const Duration(seconds: 10))
          ?.done ??
      Future<dynamic>.value();

  /// Ids for the awaiter registrations this actor makes, so it can abandon
  /// one (bead libspiffy-kyw). Unique within the actor, which is all
  /// [CancelEventAwait] matches on.
  int _awaitIdSeq = 0;

  /// Registers an awaiter on [projection] (null without one) for the first
  /// applied event matching [predicate], and the means to abandon it.
  ///
  /// [ProjectionAwait.done] never fails: a projection that cannot be asked
  /// (e.g. stopped) completes it with [AwaitFailed], so an awaiter registered
  /// before a step that throws does not surface as an unhandled error.
  ///
  /// [ProjectionAwait.cancel] drops the registration. It must be called on
  /// every path that will not await [ProjectionAwait.done] — a rejected
  /// command, in practice — because the registration is made BEFORE the
  /// command is sent (the aggregate publishes its event to the projection's
  /// mailbox before it answers, so registering afterwards can miss the
  /// resolution window). Without the cancel the projection holds the
  /// closure, the reply target and a timer for the whole 10 s window, on a
  /// path a peer can drive with repeated bad messages.
  ({Future<dynamic> done, void Function() cancel})? _awaitApplied(
    ActorRef? projection,
    bool Function(Event) predicate,
    Duration timeout,
  ) {
    if (projection == null) return null;
    final awaitId = 'pcma-${++_awaitIdSeq}';
    final done = projection
        .ask<dynamic>(
          AwaitEventApplied(predicate, timeout: timeout, awaitId: awaitId),
          // The ask must outlast the awaiter's own window, otherwise
          // dactor's default (5 s) fires first and a slow projection looks
          // like a failure.
          timeout + const Duration(seconds: 2),
        )
        .catchError((Object e) => AwaitFailed(reason: '$e'));
    return (
      done: done,
      cancel: () => projection.tell(CancelEventAwait(awaitId)),
    );
  }

  /// The counterparty marker to stamp on the wallet transactions of
  /// [state]'s channel (bead libspiffy-bps1, spv-understanding.md "Core Data
  /// Management" requirement 5).
  ///
  /// The app's own marker when it supplied one; otherwise the peer id of the
  /// side we are dealing with — the server peer for a client, the client
  /// peer for a server. The fallback is a fact the channel holds, not one it
  /// invents: the marker means the same thing on a channel transaction as on
  /// any other, so the library does not mint a channel-specific meaning for
  /// it. Null when the app supplied none and no peer id was journaled
  /// either, which is an honest absence.
  ///
  /// One rule, one place: both recording sites call this, so the funding leg
  /// and the return leg of a channel can never be stamped differently.
  String? _counterpartyMarkerFor(FullChannelStateResponse state) {
    final supplied = state.counterpartyMarker;
    if (supplied != null && supplied.isNotEmpty) return supplied;
    final peerId = switch (state.role) {
      'client' => state.serverPeerId,
      'server' => state.clientPeerId,
      _ => null,
    };
    return peerId == null || peerId.isEmpty ? null : peerId;
  }

  /// Records the funding transaction as an outgoing transaction of the
  /// client wallet, with its inputs left reserved (they are marked spent
  /// once ARC accepts the transaction). The channel's 2-of-2 output is not a
  /// wallet UTXO: the wallet cannot spend it alone (libspiffy-viy).
  Future<void> _recordFundingInWallet(
    String channelId,
    FullChannelStateResponse state,
    dartsv.Transaction funding,
  ) async {
    final walletId = state.walletId;
    final txid = funding.id;
    final channelVout = state.fundingOutputIndex ?? 0;
    final totalOutput = funding.outputs
        .fold<BigInt>(BigInt.zero, (sum, o) => sum + o.satoshis)
        .toInt();
    final totalInput = state.fundingInputSats ?? totalOutput;
    var change = BigInt.zero;
    for (var i = 0; i < funding.outputs.length; i++) {
      if (i != channelVout) change += funding.outputs[i].satoshis;
    }

    final command = RecordOutgoingTransactionCommand(
      walletId: walletId,
      txid: txid,
      rawHex: funding.serialize(),
      totalInputSats: totalInput,
      totalOutputSats: totalOutput,
      fee: totalInput - totalOutput,
      numInputs: funding.inputs.length,
      numOutputs: funding.outputs.length,
      txVersion: funding.version,
      txLockTime: funding.nLockTime,
      spentUtxoKeys: [
        for (final input in funding.inputs)
          '${input.prevTxnId}:${input.prevTxnOutputIndex}',
      ],
      recipientAddresses: ['channel:$channelId'],
      paymentAmount: state.fundingAmountSats,
      changeAddress: change > BigInt.zero ? state.clientAddressB58 : null,
      changeAmount: change > BigInt.zero ? change : null,
      // The inputs stay reserved by this transaction until ARC accepts it.
      deferSpend: true,
      purpose: 'channel-funding',
      counterpartyMarker: _counterpartyMarkerFor(state),
    );

    final applied = _awaitApplied(
      _walletProjection,
      (e) => e is TransactionRecordedEvent && e.txid == txid,
      _walletPersistTimeout,
    );
    _walletManager.tell(WalletCommandMessage(walletId, command));
    if (applied != null) {
      final result = await applied.done;
      // A wallet that already held the transaction (recorded before a
      // restart, applied to the read model only since) records nothing new.
      if (result is AwaitFailed &&
          !await _walletHoldsTransaction(walletId, txid)) {
        throw StateError('Recording funding transaction $txid in wallet '
            '$walletId failed: ${result.reason}');
      }
    }

    // The channel's 2-of-2 output is not the wallet's: the wallet does not
    // count an output it cannot spend alone (libspiffy-viy).
  }

  /// Marks the funding inputs spent by the broadcast funding transaction,
  /// consuming their reservation, and waits for the wallet read model.
  ///
  /// ARC applies the deferred spend itself when it answers the submission
  /// SEEN_ON_NETWORK or MINED (before answering), so inputs the read model
  /// already shows spent are skipped, and the others get a moment for that
  /// spend to arrive before this one is issued: an input is not spent twice
  /// (the second spend would be rejected by the wallet).
  Future<void> _spendFundingInputs(
      String walletId, dartsv.Transaction funding) async {
    final txid = funding.id;

    /// Keys of [walletId]'s unspent UTXOs, or null without a read model.
    Future<Set<String>?> unspentKeys() async {
      final storage = _storage;
      if (storage == null) return null;
      try {
        return {for (final u in await storage.getUTXOs(walletId)) u.key};
      } catch (e) {
        _log.warning('Reading the UTXOs of wallet $walletId failed: $e');
        return null;
      }
    }

    final unspent = await unspentKeys();
    final waitsByKey = <String, Future<dynamic>>{};
    final notApplied = <String>{};
    for (final input in funding.inputs) {
      final key = '${input.prevTxnId}:${input.prevTxnOutputIndex}';
      if (unspent != null && !unspent.contains(key)) continue;
      notApplied.add(key);
      final applied = _awaitApplied(
        _walletProjection,
        (e) =>
            e is UTXOSpentEvent &&
            e.txid == input.prevTxnId &&
            e.vout == input.prevTxnOutputIndex,
        _walletPersistTimeout,
      );
      if (applied != null) {
        waitsByKey[key] = applied.done.then((result) {
          if (result is! AwaitFailed) notApplied.remove(key);
          return result;
        });
      }
    }
    if (waitsByKey.isNotEmpty) {
      await Future.any<void>([
        Future.wait(waitsByKey.values),
        Future<void>.delayed(_arcSpendGrace),
      ]);
      // A spend applied before the awaiters were registered shows in the
      // read model instead.
      final unspentNow = await unspentKeys();
      if (unspentNow != null) notApplied.retainWhere(unspentNow.contains);
    }
    final waits = [
      for (final key in notApplied)
        if (waitsByKey[key] != null) waitsByKey[key]!,
    ];
    for (final key in List<String>.of(notApplied)) {
      _walletManager.tell(WalletCommandMessage(
        walletId,
        SpendUTXOCommand(
          walletId: walletId,
          utxoKey: key,
          spendingTxId: txid,
          fee: BigInt.zero,
        ),
      ));
    }
    for (final result in await Future.wait(waits)) {
      if (result is AwaitFailed) {
        // The broadcast went through; the spend is also applied when ARC
        // reports the transaction seen or mined.
        _log.warning('Funding $txid: an input spend was not applied in the '
            'wallet read model: ${result.reason}');
      }
    }
  }

  // ===========================================================================
  // THE RETURN LEG (bead libspiffy-f5p2)
  // ===========================================================================
  //
  // Funding records what left the wallet (_recordFundingInWallet). The other
  // half is the transaction that ends the channel and pays us back: the
  // settlement of a cooperative close, the refund of an expiry. It is a
  // RECEIVE on both sides — the 2-of-2 funding output is not a wallet UTXO
  // (bead libspiffy-viy), so nothing of ours is spent and our share arrives
  // as a fresh output — and it is recorded unproven: no BUMP, no block
  // height, a pending row and pending outputs. Nothing has shown it mined,
  // and only a merkle proof against our own header chain ever will (V-79,
  // V-80). ARC is not asked: we did not broadcast it.

  /// The transaction that ends [state]'s channel and pays this wallet, or
  /// null when this side holds none.
  ///
  /// Only transactions we HOLD count, and only fully signed ones that spend
  /// the channel's funding output:
  ///
  /// * the countersigned settlement — the latest payment transaction, which
  ///   the server assembles when it acknowledges a payment; and
  /// * the fully signed refund — [allowRefund] — which only the client holds
  ///   and which spends the same output after the lock time.
  ///
  /// The refund is a candidate on the expiry route only. A cooperative close
  /// is settled by the transaction the parties agreed on; the refund takes
  /// the whole funding amount back to the client and is not valid before the
  /// lock time, so recording it as the settlement of a close would misstate
  /// both who was paid and what ended the channel.
  ///
  /// [preferTxId] (the txid an expiry observer named) chooses between them.
  /// A txid we do not hold chooses nothing: being told about a transaction
  /// is not holding it, and the counterparty's own copy has to reach us as a
  /// transaction before the wallet can record one.
  ({dartsv.Transaction tx, String hex, String ourAddress})? _returnLeg(
    FullChannelStateResponse state, {
    String? preferTxId,
    bool allowRefund = false,
  }) {
    final ourAddress = switch (state.role) {
      'client' => state.clientAddressB58,
      'server' => state.serverAddressB58,
      _ => null,
    };
    final fundingTxId = state.fundingTxId;
    if (ourAddress == null || fundingTxId == null) return null;

    /// [hex] when it parses, spends the funding output and carries an
    /// unlocking script for it (an unsigned template does not, and its txid
    /// is not the one the signed transaction will have).
    dartsv.Transaction? signedSpendOfFunding(String? hex) {
      if (hex == null || hex.isEmpty) return null;
      final dartsv.Transaction tx;
      try {
        tx = dartsv.Transaction.fromHex(hex);
      } catch (e) {
        _log.warning('Channel ${state.channelId}: a candidate settlement '
            'transaction does not parse: $e');
        return null;
      }
      for (final input in tx.inputs) {
        if (input.prevTxnId == fundingTxId &&
            input.prevTxnOutputIndex == (state.fundingOutputIndex ?? 0)) {
          final script = input.script;
          return script == null || script.buffer.isEmpty ? null : tx;
        }
      }
      return null;
    }

    final candidates = <dartsv.Transaction>[
      for (final hex in [
        state.latestPaymentTxHex,
        if (allowRefund) state.signedRefundTxHex,
      ])
        if (signedSpendOfFunding(hex) case final tx?) tx,
    ];
    final chosen = preferTxId == null || preferTxId.isEmpty
        ? (candidates.isEmpty ? null : candidates.first)
        : candidates.where((tx) => tx.id == preferTxId).firstOrNull;
    return chosen == null
        ? null
        : (tx: chosen, hex: chosen.serialize(), ourAddress: ourAddress);
  }

  /// Records [leg] in the wallet as an unproven receive and returns its txid.
  ///
  /// The transaction row goes in with no BUMP and no block height, so the
  /// read model holds it `pending`; every output of it that pays our own
  /// channel address becomes a `pending` UTXO with no height. Nothing of
  /// ours is marked spent: the funding output the settlement spends was
  /// never a wallet UTXO, and the wallet's own funding inputs were spent on
  /// the funding path.
  ///
  /// The funding transaction rides along as an unproven ancestor: without it
  /// no BEEF can be built for spending these outputs later, and nobody can
  /// hand it to us again (Data Retention).
  ///
  /// A transaction the wallet already holds is not recorded again, so a
  /// re-delivered close or expiry records nothing new — the same three-layer
  /// rule the funding path follows (the channel journal's terminal event,
  /// this read-model check, and the wallet's own per-outpoint no-op).
  Future<String> _recordReturnLegInWallet(
    String channelId,
    FullChannelStateResponse state,
    ({dartsv.Transaction tx, String hex, String ourAddress}) leg,
  ) async {
    final walletId = state.walletId;
    final txid = leg.tx.id;
    if (await _walletHoldsTransaction(walletId, txid)) return txid;

    final ourOutputs = <int>[];
    var receivedSats = 0;
    var totalOutputSats = 0;
    for (var i = 0; i < leg.tx.outputs.length; i++) {
      final output = leg.tx.outputs[i];
      totalOutputSats += output.satoshis.toInt();
      String? address;
      try {
        address = dartsv.P2PKHLockBuilder.fromScript(output.script,
                networkType: _networkType)
            .address
            ?.toBase58();
      } catch (_) {
        // Not a P2PKH output; it is not one of ours.
      }
      if (address == leg.ourAddress) {
        ourOutputs.add(i);
        receivedSats += output.satoshis.toInt();
      }
    }

    final marker = _counterpartyMarkerFor(state);
    final fundingTxHex = state.fundingTxHex;
    final applied = _awaitApplied(
      _walletProjection,
      (e) => e is TransactionImportedEvent && e.txid == txid,
      _walletPersistTimeout,
    );
    _walletManager.tell(WalletCommandMessage(
      walletId,
      RecordImportedTransactionCommand(
        walletId: walletId,
        txid: txid,
        rawHex: leg.hex,
        // No proof: an absence, not a block (beads libspiffy-nys0, V-79).
        blockHeight: null,
        bumpProofHex: '',
        totalOutputSats: totalOutputSats,
        numInputs: leg.tx.inputs.length,
        numOutputs: leg.tx.outputs.length,
        txVersion: leg.tx.version,
        txLockTime: leg.tx.nLockTime,
        walletReceivingAddresses: ourOutputs.isEmpty ? const [] : [leg.ourAddress],
        walletReceivedSats: receivedSats,
        // The only input is the channel's funding output.
        totalInputSats: state.fundingAmountSats.toInt(),
        // The counterpart of the funding record's recipient (that one paid
        // `channel:<id>`; this one comes back from it). A channel is not an
        // address, and neither record pretends otherwise.
        sendingAddresses: ['channel:$channelId'],
        ancestors: [
          if (state.fundingTxId != null &&
              fundingTxHex != null &&
              fundingTxHex.isNotEmpty)
            BeefAncestor(txid: state.fundingTxId!, rawHex: fundingTxHex),
        ],
        counterpartyMarker: marker,
      ),
    ));

    for (final vout in ourOutputs) {
      final output = leg.tx.outputs[vout];
      _walletManager.tell(WalletCommandMessage(
        walletId,
        ReceiveUTXOCommand(
          walletId: walletId,
          txid: txid,
          vout: vout,
          satoshis: output.satoshis,
          scriptPubKey: output.script.toHex(),
          address: leg.ourAddress,
          derivationIndex: state.derivationIndex,
          // Unproven: pending, with no height and no count to go with it.
          initialStatus: UTXOStatus.pending,
          counterpartyMarker: marker,
        ),
      ));
    }

    if (applied != null) {
      final result = await applied.done;
      if (result is AwaitFailed &&
          !await _walletHoldsTransaction(walletId, txid)) {
        throw StateError('Recording the settlement $txid of channel '
            '$channelId in wallet $walletId failed: ${result.reason}');
      }
    }
    _log.info('Channel $channelId: settlement $txid recorded in wallet '
        '$walletId ($receivedSats sats to ${leg.ourAddress}, unproven)');
    return txid;
  }

  /// Client records a payment
  Future<void> _handleRecordPayment(RecordPaymentMessage msg) async {
    
    final originalSender = context.sender;
    
    try {
      // Step 1: Get aggregate reference
      final aggregateRef = await _channelAggregate(msg.channelId);
      
      // Step 2: Query current channel state
      final stateResponse = _stateOrThrow(
          await aggregateRef.ask(ChannelStateQuery(channelId: msg.channelId)));

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
      final pending = _PaymentSignatureContext(
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
      _pendingPaymentSignatures[correlationId] = pending;

      await _signAndContinue(
        walletId: stateResponse.walletId, // Use wallet ID from channel state
        command: signCmd,
        removePending: () => _removePendingPayment(correlationId, pending),
        onFailure: (error) => originalSender?.tell(PaymentRecordedResponse(
          channelId: msg.channelId,
          amountSats: msg.amountSats,
          sequenceNumber: 0,
          paymentTxHex: '',
          clientSignatureHex: '',
          newClientBalanceSats: BigInt.zero,
          newServerBalanceSats: BigInt.zero,
          success: false,
          error: error,
        )),
      );

      
    } catch (e, stackTrace) {
      _log.warning('Recording a payment on channel ${msg.channelId} failed: $e', e, stackTrace);
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
      final aggregateRef = await _channelAggregate(msg.channelId);
      
      // Step 2: Query current channel state for validation
      final stateResponse = _stateOrThrow(
          await aggregateRef.ask(ChannelStateQuery(channelId: msg.channelId)));

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
      final pending = _PaymentSignatureContext(
        channelId: msg.channelId,
        originalSender: originalSender,
        paymentTxHex: msg.paymentTxHex,
        paymentTxId: '', // Will be derived
        sequenceNumber: msg.proposedSequence,
        newClientBalance: msg.proposedClientBalance,
        newServerBalance: msg.proposedServerBalance,
        amountSats: msg.proposedServerBalance - stateResponse.serverBalanceSats,
        clientSignatureHex: msg.clientSignatureHex,
        clientPubKeyHex: stateResponse.clientPubKeyHex,
        serverPubKeyHex: stateResponse.serverPubKeyHex,
        fundingAmountSats: stateResponse.fundingAmountSats,
        isAcknowledgment: true,
      );
      _pendingPaymentSignatures[correlationId] = pending;

      await _signAndContinue(
        walletId: stateResponse.walletId, // Use wallet ID from channel state
        command: signCmd,
        removePending: () => _removePendingPayment(correlationId, pending),
        onFailure: (error) => originalSender?.tell(PaymentAcknowledgedResponse(
          channelId: msg.channelId,
          success: false,
          error: error,
        )),
      );

      
    } catch (e, stackTrace) {
      _log.warning('Acknowledging a payment on channel ${msg.channelId} failed: $e', e, stackTrace);
      originalSender?.tell(PaymentAcknowledgedResponse(
        channelId: msg.channelId,
        success: false,
        error: e.toString(),
      ));
    }
  }

  /// Close a channel cooperatively, in two journaled steps.
  ///
  /// [CloseChannelCommand] records the decision (`closing`); then the
  /// settlement transaction this side holds is recorded in the wallet (bead
  /// libspiffy-f5p2) and [FinalizeCloseCommand] closes the channel with that
  /// txid and the final balances. `closing` is the resumable middle: a close
  /// re-delivered after the first step (a restart, a failed wallet write)
  /// picks up there instead of being refused, and a channel already `closed`
  /// answers without recording anything again.
  ///
  /// A side that holds no fully signed settlement records nothing and does
  /// not finalise: the channel stays `closing`, which is the honest state —
  /// the parties agreed to close and we do not have the transaction that
  /// ends it. Today that is every client, because the server's
  /// countersignature is dropped where the acknowledgment reaches the
  /// client (see the report for bead libspiffy-f5p2).
  /// The client records the server's countersignature of the latest payment
  /// (bead libspiffy-z2px).
  ///
  /// The 2-of-2 funding output needs both signatures. The client signs when
  /// it records the payment and keeps only that half; the server's half comes
  /// back once, in `payment_ack`, and the adapter used to log it and drop it.
  /// The client therefore went on holding the UNSIGNED template, whose txid
  /// is not the txid the signed transaction will have, so a client
  /// cooperative close had nothing it could record and the client's return
  /// leg never reached its wallet.
  ///
  /// The settlement is assembled and verified against the funding output
  /// here, before the command is issued, exactly as the server's
  /// acknowledgement path does it. One that does not verify is not recorded:
  /// the channel keeps the template and an absence, never an invented
  /// transaction.
  ///
  /// Nothing replies: the channel's own state is the record, and the peer is
  /// not waiting on us.
  Future<void> _handleRecordPaymentCountersignature(
      RecordPaymentCountersignatureMessage msg) async {
    try {
      final aggregateRef = await _channelAggregate(msg.channelId);
      final state = _stateOrThrow(
          await aggregateRef.ask(ChannelStateQuery(channelId: msg.channelId)));

      final settlementHex = _combineSignatures(
        channelId: msg.channelId,
        sequenceNumber: msg.sequenceNumber,
        paymentTxHex: state.latestPaymentTxHex ?? '',
        clientSignatureHex: state.latestClientSignatureHex,
        serverSignatureHex: msg.serverSignatureHex,
        clientPubKeyHex: state.clientPubKeyHex,
        serverPubKeyHex: state.serverPubKeyHex,
        fundingAmountSats: state.fundingAmountSats,
      );
      if (settlementHex.isEmpty) {
        // _combineSignatures has logged why. An absence, not a guess.
        return;
      }

      _broadcastEvents(await _askAggregate(
        msg.channelId,
        aggregateRef,
        RecordPaymentCountersignatureCommand(
          channelId: msg.channelId,
          sequenceNumber: msg.sequenceNumber,
          serverSignatureHex: msg.serverSignatureHex,
          fullySignedPaymentTxHex: settlementHex,
          fullySignedPaymentTxId:
              dartsv.Transaction.fromHex(settlementHex).id,
        ),
      ));
    } catch (e, stackTrace) {
      _log.warning(
          'Channel ${msg.channelId}: the server countersignature for sequence '
          '${msg.sequenceNumber} was not recorded, so this side still holds '
          'only the unsigned payment template: $e',
          e,
          stackTrace);
    }
  }

  Future<void> _handleCloseChannel(CloseChannelMessage msg) async {

    // Capture sender immediately (context.sender changes with each new message)
    final originalSender = context.sender;

    try {
      final aggregateRef = await _channelAggregate(msg.channelId);

      var state = _stateOrThrow(
          await aggregateRef.ask(ChannelStateQuery(channelId: msg.channelId)));

      String? settlementTxId;
      if (state.status != 'closed') {
        if (state.status != 'closing') {
          final closeCmd = CloseChannelCommand(
            channelId: msg.channelId,
            reason: msg.reason,
          );

          // Send command and wait for its events (a rejection throws)
          final response =
              await _askAggregate(msg.channelId, aggregateRef, closeCmd);

          // Broadcast events to external subscribers (P2P adapter)
          _broadcastEvents(response);

          state = _stateOrThrow(await aggregateRef
              .ask(ChannelStateQuery(channelId: msg.channelId)));
        }

        settlementTxId =
            await _finalizeClose(msg.channelId, aggregateRef, state);
      }

      // `success` says the close was accepted and journaled; `finalized` says
      // the channel actually reached `closed`, which it does not when this
      // side holds no settlement to record (bead libspiffy-z2px). Answering
      // only `success: true` told the caller a channel had closed when it was
      // still in `closing`.
      originalSender?.tell(ChannelClosedResponse(
        channelId: msg.channelId,
        success: true,
        finalized: state.status == 'closed' || settlementTxId != null,
        settlementTxId: settlementTxId,
      ));

    } catch (e, stackTrace) {
      _log.warning('Closing channel ${msg.channelId} failed: $e', e, stackTrace);
      originalSender?.tell(ChannelClosedResponse(
        channelId: msg.channelId,
        success: false,
        error: e.toString(),
      ));
    }
  }

  /// Records the settlement of a channel in `closing` in the wallet and
  /// closes it with [FinalizeCloseCommand]; does neither when this side
  /// holds no settlement transaction.
  /// Returns the settlement txid it recorded, or null when this side holds
  /// no settlement and the channel therefore stays in `closing`.
  Future<String?> _finalizeClose(String channelId, ActorRef aggregateRef,
      FullChannelStateResponse state) async {
    final leg = _returnLeg(state);
    if (leg == null) {
      _log.warning('Channel $channelId is closing and this side holds no '
          'fully signed settlement transaction: nothing is recorded in '
          'wallet ${state.walletId} and the channel is not finalised. The '
          'settlement reaches the wallet when the counterparty hands it '
          'over, as any other payment does.');
      return null;
    }
    final settlementTxId =
        await _recordReturnLegInWallet(channelId, state, leg);
    await _journalReturnLegRecorded(channelId, aggregateRef, settlementTxId);
    final applied = _awaitApplied(
        _channelProjection,
        (e) => e is ChannelClosedEvent && e.channelId == channelId,
        const Duration(seconds: 10));
    try {
      _broadcastEvents(await _askAggregate(
        channelId,
        aggregateRef,
        FinalizeCloseCommand(
          channelId: channelId,
          settlementTxId: settlementTxId,
          finalClientBalanceSats: state.clientBalanceSats,
          finalServerBalanceSats: state.serverBalanceSats,
        ),
      ));
    } catch (e) {
      // Nothing will await the registration now (bead libspiffy-kyw).
      applied?.cancel();
      rethrow;
    }
    if (applied != null) {
      final result = await applied.done;
      if (result is AwaitFailed) {
        _log.warning('ChannelProjection apply timeout for the close of '
            '$channelId: ${result.reason}');
      }
    }
    return settlementTxId;
  }

  /// Journals that this side's wallet now holds [txId], the transaction that
  /// ended the channel and paid it back (bead libspiffy-lfrv).
  ///
  /// Without this record the channel cannot tell a wallet write that happened
  /// from one a crash lost, and since the aggregate refuses to re-terminate a
  /// terminated channel, nothing would ever retry it. The aggregate answers a
  /// second call with no event, so a resumed ending journals nothing new.
  Future<void> _journalReturnLegRecorded(
      String channelId, ActorRef aggregateRef, String txId) async {
    try {
      _broadcastEvents(await _askAggregate(
        channelId,
        aggregateRef,
        RecordReturnLegInWalletCommand(channelId: channelId, txId: txId),
      ));
    } catch (e) {
      // The wallet holds the transaction either way; what is lost is the
      // channel's record that it does, so a later ending will write it again
      // — which the wallet ignores, as it already holds it.
      _log.warning('Channel $channelId: the wallet holds $txId but the '
          'channel could not journal that it does: $e');
    }
  }

  /// Record that a channel has expired (lockTime elapsed).
  ///
  /// Issues [ExpireChannelCommand] to the channel aggregate so the read model
  /// transitions to `expired` via the projection rather than direct Isar
  /// mutation (closes overnode_v2-m4t).
  ///
  /// Then the transaction that ends the channel and pays this side — the
  /// fully signed refund the client holds, or a countersigned settlement —
  /// is recorded in the wallet as an unproven receive, exactly as a
  /// cooperative close records its settlement (bead libspiffy-f5p2). The two
  /// routes share [_returnLeg] and [_recordReturnLegInWallet]; they differ
  /// only in which transaction they can choose, and in that an expiry
  /// observer may name the txid it saw ([ExpireChannelMessage.settlementOrRefundTxId]),
  /// which picks between the two. The aggregate's own guard — it refuses to
  /// expire a channel that is already terminated — is what makes the
  /// recording happen once.
  Future<void> _handleExpireChannel(ExpireChannelMessage msg) async {
    final originalSender = context.sender;

    // Declared out here so the catch below can abandon it (bead
    // libspiffy-kyw), as on the open path.
    ({Future<dynamic> done, void Function() cancel})? applied;

    try {
      // Spawn aggregate if it hasn't been hydrated this session (the expiry
      // monitor runs against persisted channels that may not have an active
      // aggregate actor yet).
      final aggregateRef = await _getOrSpawnChannelAggregate(msg.channelId);

      // The transaction fields of the state do not change with the expiry;
      // read before it so the aggregate's guard is the only gate.
      final state = _stateOrThrow(
          await aggregateRef.ask(ChannelStateQuery(channelId: msg.channelId)));

      // An expiry already journaled, whose wallet write did not happen: the
      // crash window this bead is about (libspiffy-lfrv). The aggregate
      // refuses to expire a terminated channel, so re-sending the command
      // would only fail; what is left to do is the write itself.
      final alreadyExpired = state.status == 'expired';
      if (alreadyExpired && state.returnLegRecordedInWallet) {
        originalSender?.tell(ChannelExpiredResponse(
          channelId: msg.channelId,
          success: true,
        ));
        return;
      }

      if (!alreadyExpired) {
        // Register projection-applied awaiter BEFORE telling the aggregate
        // (same pattern as _handleOpenChannel — closes the read-after-write race).
        applied = _awaitApplied(_channelProjection,
            (e) => e is ChannelExpiredEvent && e.channelId == msg.channelId,
            const Duration(seconds: 10));

        final response = await _askAggregate(
            msg.channelId,
            aggregateRef,
            ExpireChannelCommand(
              channelId: msg.channelId,
              observedBy: msg.observedBy,
              settlementOrRefundTxId: msg.settlementOrRefundTxId,
            ));

        _broadcastEvents(response);

        if (applied != null) {
          final result = await applied.done;
          if (result is AwaitFailed) {
            _log.warning(
                'ChannelProjection apply timeout for ${msg.channelId}: ${result.reason}');
          }
          // Awaited: the catch below must not also cancel it.
          applied = null;
        }
      }

      final leg = _returnLeg(state,
          preferTxId: msg.settlementOrRefundTxId, allowRefund: true);
      if (leg == null) {
        _log.warning('Channel ${msg.channelId} expired and this side holds no '
            'fully signed transaction spending its funding output'
            '${msg.settlementOrRefundTxId == null ? '' : ' with txid ${msg.settlementOrRefundTxId}'}'
            ': nothing is recorded in wallet ${state.walletId}.');
      } else {
        final txId = await _recordReturnLegInWallet(msg.channelId, state, leg);
        await _journalReturnLegRecorded(msg.channelId, aggregateRef, txId);
      }

      originalSender?.tell(ChannelExpiredResponse(
        channelId: msg.channelId,
        success: true,
      ));
    } catch (e, stackTrace) {
      // Nothing will await the registration now (bead libspiffy-kyw).
      applied?.cancel();
      _log.warning('Expiring channel ${msg.channelId} failed: $e', e, stackTrace);
      originalSender?.tell(ChannelExpiredResponse(
        channelId: msg.channelId,
        success: false,
        error: e.toString(),
      ));
    }
  }

  /// Claim the refund of an expired channel (bead libspiffy-cqc (b)).
  ///
  /// The client holds a fully signed refund from the server's
  /// countersignature on, valid from the channel's lockTime. Nothing in the
  /// library used to use it: [ClaimRefundCommand] and [RefundClaimedEvent]
  /// existed, were guarded and were projected, but no code path ever built
  /// the command, so a client whose counterparty had gone silent had no way
  /// to take its money back.
  ///
  /// It is the expiry path plus the one thing expiry deliberately does not
  /// do — a broadcast. The refund is OUR transaction, so ARC has standing to
  /// answer for it (spv-understanding.md); an expiry observer may hold no
  /// transaction at all, which is why [_handleExpireChannel] only records.
  ///
  /// Order: broadcast, then journal the claim, then record the wallet.
  /// A claim is a claim about the network, so nothing is journaled as
  /// claimed for a transaction the network refused. **There is no
  /// replace-by-fee on BSV**: a rejection (a double spend, most likely the
  /// counterparty's settlement having got there first) is a terminal answer,
  /// recorded honestly on the response and never retried at a higher fee.
  ///
  /// Convergence with expiry: [_recordReturnLegInWallet] no-ops on a
  /// transaction the wallet already holds and [ChannelState.returnLegRecordedInWallet]
  /// says whether the write happened, so expire-then-claim and
  /// claim-then-expire both leave exactly one wallet transaction row. The
  /// aggregate refuses to expire a terminated channel, which is what stops
  /// the second of the two journaling anything about the channel's ending.
  Future<void> _handleClaimRefund(ClaimRefundMessage msg) async {
    final originalSender = context.sender;

    // Declared out here so the catch below can abandon it (bead
    // libspiffy-kyw), as on the open and expiry paths.
    ({Future<dynamic> done, void Function() cancel})? applied;

    try {
      final aggregateRef = await _getOrSpawnChannelAggregate(msg.channelId);

      // Read before the command: the aggregate's own guards (past lockTime,
      // client role, the refund spends the funding output) are the only gate.
      final state = _stateOrThrow(
          await aggregateRef.ask(ChannelStateQuery(channelId: msg.channelId)));

      final refundTxHex = msg.refundTxHex ?? state.signedRefundTxHex;
      if (refundTxHex == null || refundTxHex.isEmpty) {
        throw StateError('Channel ${msg.channelId} holds no fully signed '
            'refund to claim: an absence, not a transaction to invent');
      }
      final dartsv.Transaction refund;
      try {
        refund = dartsv.Transaction.fromHex(refundTxHex);
      } catch (e) {
        throw StateError('The refund of channel ${msg.channelId} does not '
            'parse: $e');
      }
      final refundTxId = refund.id;

      final arcActor = _arcActor;
      if (arcActor == null) {
        throw StateError('No transaction broadcaster (ARC actor) configured');
      }

      final reply = await _request(
        arcActor,
        BroadcastTransactionMessage(state.walletId, refundTxHex, refundTxId),
        accept: (r) =>
            r is BroadcastSuccessMessage || r is BroadcastFailedMessage,
        what: 'Broadcasting refund $refundTxId of channel ${msg.channelId}',
        timeout: _broadcastTimeout,
      );
      if (reply is BroadcastFailedMessage) {
        throw StateError('Refund broadcast failed: ${reply.error}');
      }
      if (reply is! BroadcastSuccessMessage) {
        throw StateError('Refund broadcast failed: unexpected reply '
            '${reply.runtimeType}');
      }

      // Registered BEFORE the command: the aggregate publishes its event to
      // the projection's mailbox before it answers, so registering after
      // could miss the window (the read-after-write race).
      applied = _awaitApplied(
          _channelProjection,
          (e) => e is RefundClaimedEvent && e.channelId == msg.channelId,
          const Duration(seconds: 10));
      try {
        _broadcastEvents(await _askAggregate(
          msg.channelId,
          aggregateRef,
          ClaimRefundCommand(
              channelId: msg.channelId, refundTxHex: refundTxHex),
        ));
      } catch (e) {
        // Nothing will await the registration now (bead libspiffy-kyw).
        applied?.cancel();
        applied = null;
        rethrow;
      }
      if (applied != null) {
        final result = await applied.done;
        if (result is AwaitFailed) {
          _log.warning('ChannelProjection apply timeout for the refund claim '
              'of ${msg.channelId}: ${result.reason}');
        }
        // Awaited: the catch below must not also cancel it.
        applied = null;
      }

      // The money coming back. An expiry may already have recorded it
      // without broadcasting (V-86); the journaled record of that write is
      // what keeps the two routes to one wallet row.
      if (!state.returnLegRecordedInWallet) {
        final leg =
            _returnLeg(state, preferTxId: refundTxId, allowRefund: true);
        if (leg == null) {
          _log.warning('Channel ${msg.channelId}: refund $refundTxId is '
              'broadcast and the claim is journaled, but this side holds no '
              'copy of it that pays an address of ours, so nothing is '
              'recorded in wallet ${state.walletId}.');
        } else {
          final txId =
              await _recordReturnLegInWallet(msg.channelId, state, leg);
          await _journalReturnLegRecorded(msg.channelId, aggregateRef, txId);
        }
      }

      originalSender?.tell(ChannelRefundClaimedResponse(
        channelId: msg.channelId,
        refundTxId: refundTxId,
        success: true,
      ));
    } catch (e, stackTrace) {
      // Nothing will await the registration now (bead libspiffy-kyw).
      applied?.cancel();
      _log.warning('Claiming the refund of channel ${msg.channelId} failed: $e',
          e, stackTrace);
      originalSender?.tell(ChannelRefundClaimedResponse(
        channelId: msg.channelId,
        success: false,
        error: e.toString(),
      ));
    }
  }

  /// Removes the pending payment/ack entry for [correlationId] if it is still
  /// [pending]; returns whether it was.
  bool _removePendingPayment(
      String correlationId, _PaymentSignatureContext pending) {
    if (!identical(_pendingPaymentSignatures[correlationId], pending)) {
      return false;
    }
    _pendingPaymentSignatures.remove(correlationId);
    return true;
  }

  /// Query channel state: asks the channel aggregate (recovered from the
  /// journal if it is not loaded) and replies with [ChannelStateResponse].
  /// A channel with no journal is answered `success: false` without spawning
  /// an aggregate for it.
  Future<void> _handleQueryChannelState(QueryChannelStateMessage msg) async {
    final originalSender = context.sender;

    try {
      final aggregateRef = await _channelAggregate(msg.channelId,
          notFound: 'Channel not found');

      final state = _stateOrThrow(await aggregateRef.ask<dynamic>(
        ChannelStateQuery(channelId: msg.channelId),
        const Duration(seconds: 10),
      ));

      originalSender?.tell(ChannelStateResponse(
        channelId: msg.channelId,
        status: state.status,
        clientBalanceSats: state.clientBalanceSats,
        serverBalanceSats: state.serverBalanceSats,
        latestSequenceNumber: state.latestSequenceNumber,
        success: true,
      ));
    } catch (e, stackTrace) {
      _log.warning('Querying state of channel ${msg.channelId} failed: $e', e, stackTrace);
      originalSender?.tell(ChannelStateResponse(
        channelId: msg.channelId,
        status: 'unknown',
        success: false,
        error: e.toString(),
      ));
    }
  }

  /// Answers [ChannelDetailsQueryMessage] with the aggregate's
  /// [FullChannelStateResponse] (`success: false` for an unknown channel).
  Future<void> _handleChannelDetailsQuery(ChannelDetailsQueryMessage msg) async {
    final originalSender = context.sender;
    try {
      final aggregateRef = await _channelAggregate(msg.channelId,
          notFound: 'Channel not found');
      originalSender?.tell(_stateOrThrow(await aggregateRef.ask<dynamic>(
        ChannelStateQuery(channelId: msg.channelId),
        const Duration(seconds: 10),
      )));
    } catch (e) {
      originalSender?.tell(FullChannelStateResponse(
        channelId: msg.channelId,
        walletId: '',
        status: 'unknown',
        clientBalanceSats: BigInt.zero,
        serverBalanceSats: BigInt.zero,
        latestSequenceNumber: 0,
        fundingAmountSats: BigInt.zero,
        success: false,
        error: e.toString(),
      ));
    }
  }

  /// The aggregate of an existing channel: the loaded one while it is alive,
  /// otherwise one recovered from the channel's journal. A channel that was
  /// never loaded and has no journal is a [StateError] ('[notFound]: id').
  Future<ActorRef> _channelAggregate(
    String channelId, {
    String notFound = 'Channel aggregate not found',
  }) async {
    if (!_channelAggregates.containsKey(channelId)) {
      final journalLength = await _eventStore
          .getHighestSequenceNumber('PaymentChannel_$channelId');
      if (journalLength == 0) {
        throw StateError('$notFound: $channelId');
      }
    }
    return _getOrSpawnChannelAggregate(channelId);
  }

  /// Get or spawn a channel aggregate actor. A cached aggregate that is no
  /// longer alive, or that a journal write failure took out of service, is
  /// replaced; an out-of-service one first answers what is queued to it and
  /// stops (bead libspiffy-u0x).
  Future<ActorRef> _getOrSpawnChannelAggregate(String channelId) async {
    final cached = _channelAggregates[channelId];
    if (cached != null) {
      if (cached.isAlive && !CommandFailureContainment.isRetiring(cached)) return cached;
      _channelAggregates.remove(channelId);
      if (cached.isAlive) {
        await CommandFailureContainment.retire(cached).timeout(const Duration(seconds: 30),
            // ignore: invalid_use_of_internal_member
            onTimeout: () => context.system.stop(cached));
      }
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

}

/// Receives the reply to one request (see
/// PaymentChannelManagerActor._request).
class _ReplyReceiver extends Actor {
  final Completer<dynamic> completer;
  final bool Function(dynamic reply) accept;

  _ReplyReceiver(this.completer, this.accept);

  @override
  Future<void> onMessage(dynamic message) async {
    if (completer.isCompleted) return;
    if (accept(message)) {
      completer.complete(message);
      return;
    }
    // WalletManager's failure shape: {'error': ..., 'walletId': ...}.
    final payload = message is LocalMessage ? message.payload : message;
    if (payload is Map && payload['error'] != null) {
      completer.completeError(StateError(payload['error'].toString()));
    }
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

  /// The channel's two public keys and the value of the funding output it
  /// spends: what the server needs to combine both signatures into the fully
  /// signed settlement and check that it spends the funding output (bead
  /// libspiffy-f5p2). Null on the client's own recording path.
  final String? clientPubKeyHex;
  final String? serverPubKeyHex;
  final BigInt? fundingAmountSats;

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
    this.clientPubKeyHex,
    this.serverPubKeyHex,
    this.fundingAmountSats,
    this.isAcknowledgment = false,
  });
}


