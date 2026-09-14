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
import '../core/wallet_events.dart' show TransactionRecordedEvent, UTXOSpentEvent;
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

  /// How long the channel's 2-of-2 output stays reserved in the client
  /// wallet: it is never spendable by the wallet alone (it needs the server
  /// signature, or the refund after the lockTime).
  static const Duration channelOutputReservation = Duration(days: 365 * 100);

  static const Duration _walletPersistTimeout = Duration(seconds: 10);

  /// Map of active channel aggregates: channelId -> ActorRef
  final Map<String, ActorRef> _channelAggregates = {};

  /// Track pending refund signing requests: channelId -> context
  final Map<String, ({ActorRef? sender, String refundTxHex, int lockTimeUnix})> _pendingRefundSignatures = {};

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
  })  : _walletManager = walletManager,
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
    if (response is! List || response.isEmpty) {
      throw StateError('Command failed: no events emitted');
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
        case ExpireChannelMessage:
          await _handleExpireChannel(message as ExpireChannelMessage);
          break;
        case QueryChannelStateMessage:
          await _handleQueryChannelState(message as QueryChannelStateMessage);
          break;
        default:
      }
    } catch (e, stackTrace) {
      _log.warning('Failed to handle ${message.runtimeType}: $e', e, stackTrace);
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
  Future<void> _handleSignRefundTransaction(SignRefundTransactionMessage msg) async {
    
    // Capture sender immediately
    final originalSender = context.sender;
    
    try {
      // Step 1: The channel must exist (loaded, or recoverable from its journal)
      await _channelAggregate(msg.channelId);
      
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
      final pending = (
        sender: originalSender,
        refundTxHex: msg.refundTxHex,
        lockTimeUnix: msg.lockTimeUnix,
      );
      _pendingRefundSignatures[msg.channelId] = pending;

      await _signAndContinue(
        walletId: msg.walletId,
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
        fundingTxId: 'pending',
        fundingOutputIndex: 0,
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
        
        final events = await _askAggregate(pending.channelId, aggregateRef, ackCmd);
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
      final aggregateRef = await _channelAggregate(msg.channelId);

      // Client: the funding transaction reaches the network (and the wallet)
      // before the channel is open, and only once the verified refund is
      // journaled (libspiffy-9f7). A failure is journaled and rethrown.
      final state = _stateOrThrow(await aggregateRef
          .ask(ChannelStateQuery(channelId: msg.channelId)));
      if (state.role == 'client') {
        await _fundClientChannel(msg, aggregateRef, state);
      }

      final openCmd = OpenChannelCommand(
        channelId: msg.channelId,
        fundingTxId: msg.fundingTxId,
        fundingOutputIndex: msg.fundingOutputIndex,
        fundingTxHex: msg.fundingTxHex,
      );

      // Register projection-applied awaiter BEFORE telling the aggregate.
      // Same pattern as PaymentCoordinatorActor._recordOutgoingTransaction:
      // if the projection processes the event very fast, registering after
      // would miss the resolution window.
      final applied = _channelProjection?.ask<dynamic>(
        AwaitEventApplied(
          (e) => e is ChannelOpenedEvent && e.channelId == msg.channelId,
          timeout: const Duration(seconds: 10),
        ),
        // Ask timeout must outlast the awaiter's own window, otherwise dactor's
        // default (5 s) fires first and a slow projection looks like a failure.
        const Duration(seconds: 12),
      );

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
        final result = await applied;
        if (result is AwaitFailed) {
          _log.warning(
              'ChannelProjection apply timeout for ${msg.channelId}: ${result.reason}');
        }
      }

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

  /// Broadcasts the client's funding transaction and records it in the
  /// client wallet (libspiffy-9f7).
  ///
  /// Order: [StartFundingBroadcastCommand] is journaled first (the aggregate
  /// refuses it unless the verified, fully signed refund of this funding
  /// transaction is journaled); then the transaction is recorded in the
  /// wallet (inputs kept reserved, change credited pending, the 2-of-2
  /// output reserved for the channel); then ARC broadcasts it; then its
  /// inputs are marked spent. Any failure journals
  /// [RecordFundingBroadcastFailedCommand] and is rethrown, leaving the
  /// channel unopened and its inputs reserved for a retry of the same
  /// transaction.
  Future<void> _fundClientChannel(
    OpenChannelMessage msg,
    ActorRef aggregateRef,
    FullChannelStateResponse state,
  ) async {
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
      if (!walletRecorded) {
        await _recordFundingInWallet(msg.channelId, state, funding);
        walletRecorded = true;
      }

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
      _channelProjection?.ask<dynamic>(
        AwaitEventApplied(predicate, timeout: const Duration(seconds: 10)),
        const Duration(seconds: 12),
      ) ??
      Future<dynamic>.value();

  /// Records the funding transaction as an outgoing transaction of the
  /// client wallet, with its inputs left reserved (they are marked spent
  /// once ARC accepts the transaction), and reserves the channel's 2-of-2
  /// output so it never counts as spendable wallet balance.
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
    );

    final applied = _walletProjection?.ask<dynamic>(
      AwaitEventApplied(
        (e) => e is TransactionRecordedEvent && e.txid == txid,
        timeout: _walletPersistTimeout,
      ),
      _walletPersistTimeout + const Duration(seconds: 2),
    );
    _walletManager.tell(WalletCommandMessage(walletId, command));
    if (applied != null) {
      final result = await applied;
      if (result is AwaitFailed) {
        throw StateError('Recording funding transaction $txid in wallet '
            '$walletId failed: ${result.reason}');
      }
    }

    // The wallet treats an output locked to one of its keys as its own; the
    // channel output needs the server's signature too, so it is reserved
    // for the channel instead of counting as spendable balance.
    final utxoKey = '$txid:$channelVout';
    final reserved = await _askWallet<UTXOReservedResponse>(
      walletId,
      ReserveUTXOCommand(
        walletId: walletId,
        utxoKey: utxoKey,
        reservedByTxId: 'channel:$channelId',
        reservationReason: 'Payment channel $channelId 2-of-2 funding output '
            '(not spendable by this wallet alone)',
        reservationDuration: channelOutputReservation,
        priority: 1000,
      ),
      'Reserving channel output $utxoKey',
    );
    // A wallet that does not hold the output has nothing to reserve.
    if (!reserved.success && !(reserved.error ?? '').contains('not found')) {
      throw StateError('Reserving channel output $utxoKey failed: '
          '${reserved.error}');
    }
  }

  /// Marks the funding inputs spent by the broadcast funding transaction,
  /// consuming their reservation, and waits for the wallet read model.
  Future<void> _spendFundingInputs(
      String walletId, dartsv.Transaction funding) async {
    final txid = funding.id;
    final waits = <Future<dynamic>>[];
    for (final input in funding.inputs) {
      final applied = _walletProjection?.ask<dynamic>(
        AwaitEventApplied(
          (e) =>
              e is UTXOSpentEvent &&
              e.txid == input.prevTxnId &&
              e.vout == input.prevTxnOutputIndex,
          timeout: _walletPersistTimeout,
        ),
        _walletPersistTimeout + const Duration(seconds: 2),
      );
      if (applied != null) waits.add(applied);
      _walletManager.tell(WalletCommandMessage(
        walletId,
        SpendUTXOCommand(
          walletId: walletId,
          utxoKey: '${input.prevTxnId}:${input.prevTxnOutputIndex}',
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

  /// Close a channel
  Future<void> _handleCloseChannel(CloseChannelMessage msg) async {
    
    // Capture sender immediately (context.sender changes with each new message)
    final originalSender = context.sender;
    
    try {
      final aggregateRef = await _channelAggregate(msg.channelId);
      
      final closeCmd = CloseChannelCommand(
        channelId: msg.channelId,
        reason: msg.reason,
      );
      
      // Send command and wait for its events (a rejection throws)
      final response = await _askAggregate(msg.channelId, aggregateRef, closeCmd);

      // Broadcast events to external subscribers (P2P adapter)
      _broadcastEvents(response);
      
      originalSender?.tell(ChannelClosedResponse(
        channelId: msg.channelId,
        success: true,
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

  /// Record that a channel has expired (lockTime elapsed).
  ///
  /// Issues [ExpireChannelCommand] to the channel aggregate so the read model
  /// transitions to `expired` via the projection rather than direct Isar
  /// mutation (closes overnode_v2-m4t).
  Future<void> _handleExpireChannel(ExpireChannelMessage msg) async {
    final originalSender = context.sender;

    try {
      // Spawn aggregate if it hasn't been hydrated this session (the expiry
      // monitor runs against persisted channels that may not have an active
      // aggregate actor yet).
      final aggregateRef = await _getOrSpawnChannelAggregate(msg.channelId);

      final expireCmd = ExpireChannelCommand(
        channelId: msg.channelId,
        observedBy: msg.observedBy,
        settlementOrRefundTxId: msg.settlementOrRefundTxId,
      );

      // Register projection-applied awaiter BEFORE telling the aggregate
      // (same pattern as _handleOpenChannel — closes the read-after-write race).
      final applied = _channelProjection?.ask<dynamic>(
        AwaitEventApplied(
          (e) => e is ChannelExpiredEvent && e.channelId == msg.channelId,
          timeout: const Duration(seconds: 10),
        ),
        // Ask timeout must outlast the awaiter's own window, otherwise dactor's
        // default (5 s) fires first and a slow projection looks like a failure.
        const Duration(seconds: 12),
      );

      final response = await _askAggregate(msg.channelId, aggregateRef, expireCmd);

      _broadcastEvents(response);

      if (applied != null) {
        final result = await applied;
        if (result is AwaitFailed) {
          _log.warning(
              'ChannelProjection apply timeout for ${msg.channelId}: ${result.reason}');
        }
      }

      originalSender?.tell(ChannelExpiredResponse(
        channelId: msg.channelId,
        success: true,
      ));
    } catch (e, stackTrace) {
      _log.warning('Expiring channel ${msg.channelId} failed: $e', e, stackTrace);
      originalSender?.tell(ChannelExpiredResponse(
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
  /// longer alive (it stops itself when a journal write fails) is replaced.
  Future<ActorRef> _getOrSpawnChannelAggregate(String channelId) async {
    final cached = _channelAggregates[channelId];
    if (cached != null) {
      if (cached.isAlive) return cached;
      _channelAggregates.remove(channelId);
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


