import 'dart:async';

import 'package:dactor/dactor.dart';
import 'package:logging/logging.dart';

import '../core/channel_events.dart' as ch;
import '../core/wallet_commands.dart';
import '../models/fee_rate.dart';
import 'coordinator_messages.dart' as coord;
import 'payment_channel_messages.dart';
import 'wallet_messages.dart';
import '../utils/unique_id.dart';

final _log = Logger('ChannelP2PAdapter');

/// Transport-agnostic adapter that translates between P2P protocol messages
/// (as raw maps) and LibSpiffy's PaymentChannelManagerActor messages.
///
/// Unlike the Overnode version, this adapter:
/// - Uses raw `String messageType` / `Map<String, dynamic> payload` for P2P
/// - Emits [coord.CoordinatorEvent]s instead of sending WalletIsolateMessages
/// - Takes walletId and peerId as updatable constructor parameters
/// - Tells the channel manager directly instead of using request callbacks
///
/// Its per-channel records (peers, keys, funding transaction) are a cache of
/// the channel journal: a message, event or response for a channel it has
/// no record of (after a restart) first rebuilds the record from the channel
/// manager ([ChannelDetailsQueryMessage]), so a restarted node carries on
/// with a channel in mid-open (libspiffy-fsy, libspiffy-36f). Work for other
/// channels waits meanwhile, so everything is still handled in arrival
/// order.
class ChannelP2PAdapter {
  final ActorRef _channelManager;
  final void Function(coord.CoordinatorEvent) _emitEvent;

  String _walletId;
  String _myPeerId;

  StreamSubscription? _eventSubscription;

  // Correlation maps
  final Map<String, PeerInfo> _channelPeers = {};
  final Map<String, PendingRequest> _pendingRequests = {};
  final Map<String, ClientChannelInfo> _clientChannelInfo = {};
  final Map<String, ServerChannelInfo> _serverChannelInfo = {};
  final Set<String> _closingChannels = {};

  /// Work waiting behind a channel record being rebuilt (see [_sequenced]).
  Future<void> _queue = Future<void>.value();
  int _queued = 0;
  bool _disposed = false;

  /// How long rebuilding a channel record may wait for the channel manager
  /// (which may be busy broadcasting a funding transaction).
  static const Duration _restoreTimeout = Duration(seconds: 60);

  ChannelP2PAdapter({
    required ActorRef channelManager,
    required ActorRef walletManager,
    required ActorRef arcActor,
    required void Function(coord.CoordinatorEvent) emitEvent,
    required Stream<ch.ChannelEvent> channelEvents,
    required String walletId,
    required String myPeerId,
  })  : _channelManager = channelManager,
        _walletManager = walletManager,
        _arcActor = arcActor,
        _emitEvent = emitEvent,
        _walletId = walletId,
        _myPeerId = myPeerId {
    _eventSubscription = channelEvents.listen(_handleEvent);
  }

  /// Wallet manager that routes wallet commands to the owning aggregate.
  final ActorRef _walletManager;

  /// ARCActor, asked for the policy rate a channel's funding pays (bead
  /// libspiffy-zs4l).
  final ActorRef _arcActor;

  /// How long ARCActor may take to give its policy rate.
  static const Duration _feeRateTimeout = Duration(seconds: 30);

  /// Actor that receives wallet command responses on the adapter's behalf
  /// (the coordinator that owns this adapter); set once its context exists.
  ActorRef? _replyTo;

  void updateWalletId(String walletId) => _walletId = walletId;
  void updatePeerId(String peerId) => _myPeerId = peerId;
  void updateReplyTo(ActorRef replyTo) => _replyTo = replyTo;

  void dispose() {
    _disposed = true;
    _eventSubscription?.cancel();
  }

  // ===========================================================================
  // CHANNEL RECORDS AFTER A RESTART
  // ===========================================================================

  bool _knows(String channelId) =>
      _clientChannelInfo.containsKey(channelId) ||
      _serverChannelInfo.containsKey(channelId);

  /// Runs [body] now, or, when work is already waiting or [channelId] names
  /// a channel this adapter has no record of, after the waiting work and
  /// after rebuilding that record from the channel journal.
  void _sequenced(String? channelId, void Function() body) {
    if (_queued == 0 && (channelId == null || _knows(channelId))) {
      body();
      return;
    }
    _queued++;
    _queue = _queue.then((_) async {
      try {
        if (_disposed) return;
        if (channelId != null && !_knows(channelId)) {
          await _restore(channelId);
        }
        if (!_disposed) body();
      } catch (e, stackTrace) {
        _log.warning('Channel ${channelId ?? ''} work failed: $e', e, stackTrace);
      } finally {
        _queued--;
      }
    });
  }

  /// Rebuilds the records of [channelId] from its journaled state, if the
  /// channel exists.
  Future<void> _restore(String channelId) async {
    final dynamic reply;
    try {
      reply = await _channelManager.ask<dynamic>(
          ChannelDetailsQueryMessage(channelId: channelId), _restoreTimeout);
    } catch (e) {
      _log.warning('Cannot restore channel $channelId: $e');
      return;
    }
    if (reply is! FullChannelStateResponse || !reply.success) {
      _log.fine('No journaled channel $channelId to restore');
      return;
    }
    _adopt(reply);
  }

  void _adopt(FullChannelStateResponse state) {
    final channelId = state.channelId;
    if (state.role == 'client') {
      _clientChannelInfo[channelId] = ClientChannelInfo(
        channelId: channelId,
        walletId: state.walletId,
        clientPubKeyHex: state.clientPubKeyHex ?? '',
        clientAddressB58: state.clientAddressB58 ?? '',
        clientDerivationIndex: state.derivationIndex ?? 0,
        serverPubKeyHex: state.serverPubKeyHex,
        serverAddressB58: state.serverAddressB58,
        fundingAmountSats: state.fundingAmountSats.toInt(),
        lockTimeUnix: state.lockTimeUnix ?? 0,
        fundingTxId: state.fundingTxId,
        fundingTxHex: state.fundingTxHex,
        fundingOutputIndex: state.fundingOutputIndex,
      );
      final serverPeerId = state.serverPeerId;
      if (serverPeerId != null) {
        _channelPeers[channelId] = PeerInfo(
          clientPeerId: state.clientPeerId ?? _myPeerId,
          serverPeerId: serverPeerId,
        );
      }
    } else if (state.role == 'server') {
      final clientPeerId = state.clientPeerId ?? '';
      _serverChannelInfo[channelId] = ServerChannelInfo(
        channelId: channelId,
        walletId: state.walletId,
        clientPeerId: clientPeerId,
        clientPubKeyHex: state.clientPubKeyHex ?? '',
        clientAddressB58: state.clientAddressB58 ?? '',
        serverPubKeyHex: state.serverPubKeyHex ?? '',
        serverAddressB58: state.serverAddressB58 ?? '',
        derivationIndex: state.derivationIndex ?? 0,
        fundingAmountSats: state.fundingAmountSats.toInt(),
        lockTimeUnix: state.lockTimeUnix ?? 0,
        fundingTxId: state.fundingTxId,
        fundingTxHex: state.fundingTxHex,
        fundingOutputIndex: state.fundingOutputIndex,
      );
      _channelPeers[channelId] = PeerInfo(
        clientPeerId: clientPeerId,
        serverPeerId: state.serverPeerId ?? _myPeerId,
      );
    }
    if (state.status == 'closing') _closingChannels.add(channelId);
  }

  // ===========================================================================
  // P2P MESSAGE HANDLING (incoming from peer)
  // ===========================================================================

  /// Handle an incoming P2P message from a peer.
  void handleP2PMessage(String fromPeerId, String messageType, Map<String, dynamic> payload) {
    _log.fine('Received P2P message: $messageType from $fromPeerId');

    // Every message but a request is about an existing channel, and is
    // checked against this adapter's record of it (bead libspiffy-i0e6).
    final channelId = payload['channelId'];
    _sequenced(
      messageType != 'channel_request' && channelId is String ? channelId : null,
      () {
        if (_fromCounterparty(fromPeerId, messageType, channelId)) {
          _dispatchP2PMessage(fromPeerId, messageType, payload);
        }
      },
    );
  }

  /// Messages only the server of a channel sends, to its client.
  static const _fromServer = {
    'channel_accept',
    'channel_reject',
    'refund_signed',
    'payment_ack',
  };

  /// Messages only the client of a channel sends, to its server.
  static const _fromClient = {
    'refund_sign_request',
    'channel_open',
    'payment_update',
  };

  /// Whether [fromPeerId] may send [messageType] about [channelId]: the
  /// channel's counterparty on record, in the role that sends it (bead
  /// libspiffy-i0e6).
  ///
  /// Channel ids travel between the two parties and through whatever relays
  /// them, so knowing one proves nothing. The adapter used to act on a
  /// message from any peer: a third party could end the client's channel
  /// (`channel_closed`, `channel_reject`), close ours (`channel_close`), or
  /// accept a request in the server's place, overwriting the peer the
  /// client funds and sends its refund to. A request naming a channel this
  /// side already has with someone else is refused the same way.
  bool _fromCounterparty(String fromPeerId, String messageType, Object? channelId) {
    if (channelId is! String) {
      // channel_error may name no channel: it is reported, and changes nothing.
      return messageType == 'channel_error';
    }
    final isNew = messageType == 'channel_request' &&
        !_knows(channelId) &&
        !_channelPeers.containsKey(channelId) &&
        !_pendingRequests.containsKey(channelId);
    if (isNew) return true;
    final wrongDirection = (_clientChannelInfo.containsKey(channelId) && _fromClient.contains(messageType)) ||
        (_serverChannelInfo.containsKey(channelId) && _fromServer.contains(messageType));
    final counterparty = wrongDirection ? null : _counterpartyPeer(channelId);
    if (counterparty != fromPeerId) {
      _log.warning('Refused $messageType for channel $channelId from $fromPeerId: '
          '${counterparty == null ? 'this side has no counterparty on record who sends it' : 'its counterparty is $counterparty'}');
      return false;
    }
    return true;
  }

  void _dispatchP2PMessage(
      String fromPeerId, String messageType, Map<String, dynamic> payload) {
    switch (messageType) {
      case 'channel_request':
        _handleChannelRequest(fromPeerId, payload);
        break;
      case 'channel_accept':
        _handleChannelAccept(fromPeerId, payload);
        break;
      case 'channel_reject':
        _handleChannelReject(fromPeerId, payload);
        break;
      case 'refund_sign_request':
        _handleRefundSignRequest(fromPeerId, payload);
        break;
      case 'refund_signed':
        _handleRefundSigned(fromPeerId, payload);
        break;
      case 'channel_open':
        _handleChannelOpen(fromPeerId, payload);
        break;
      case 'payment_update':
        _handlePaymentUpdate(fromPeerId, payload);
        break;
      case 'payment_ack':
        _handlePaymentAck(fromPeerId, payload);
        break;
      case 'channel_close':
        _handleChannelClose(fromPeerId, payload);
        break;
      case 'channel_closed':
        _handleChannelClosed(fromPeerId, payload);
        break;
      case 'channel_error':
        _handleChannelError(fromPeerId, payload);
        break;
      default:
        _log.warning('Unknown P2P message type: $messageType');
    }
  }

  void _handleChannelRequest(String fromPeerId, Map<String, dynamic> payload) {
    final channelId = payload['channelId'] as String;
    final clientPubKey = payload['clientPubKey'] as String;
    final clientAddress = payload['clientAddress'] as String;
    final fundingAmountSats = payload['fundingAmountSats'] as int;
    final lockTimeUnix = payload['lockTimeUnix'] as int;
    final context = payload['context'] as String?;

    _pendingRequests[channelId] = PendingRequest(
      channelId: channelId,
      clientPeerId: fromPeerId,
      clientPubKey: clientPubKey,
      clientAddress: clientAddress,
      fundingAmountSats: fundingAmountSats,
      lockTimeUnix: lockTimeUnix,
      context: context,
    );

    _emitEvent(coord.ChannelRequestReceivedEvent(
      channelId: channelId,
      clientPeerId: fromPeerId,
      clientPubKey: clientPubKey,
      clientAddress: clientAddress,
      fundingAmountSats: fundingAmountSats,
      lockTimeUnix: lockTimeUnix,
      context: context,
    ));
  }

  void _handleChannelAccept(String fromPeerId, Map<String, dynamic> payload) {
    final channelId = payload['channelId'] as String;
    final serverPubKey = payload['serverPubKey'] as String;
    final serverAddress = payload['serverAddress'] as String;
    final derivationIndex = payload['derivationIndex'] as int;

    final clientInfo = _clientChannelInfo[channelId];
    if (clientInfo == null) {
      _log.warning('Received channel_accept for unknown channel: $channelId');
      return;
    }

    _channelPeers[channelId] = PeerInfo(
      clientPeerId: _myPeerId,
      serverPeerId: fromPeerId,
    );

    // Record server acceptance on the aggregate
    _channelManager.tell(RecordServerAcceptanceMessage(
      channelId: channelId,
      serverPubKeyHex: serverPubKey,
      serverAddressB58: serverAddress,
    ));

    // Update client info with server details
    _clientChannelInfo[channelId] = ClientChannelInfo(
      channelId: channelId,
      walletId: clientInfo.walletId,
      clientPubKeyHex: clientInfo.clientPubKeyHex,
      clientAddressB58: clientInfo.clientAddressB58,
      clientDerivationIndex: clientInfo.clientDerivationIndex,
      serverPubKeyHex: serverPubKey,
      serverAddressB58: serverAddress,
      serverDerivationIndex: derivationIndex,
      fundingAmountSats: clientInfo.fundingAmountSats,
      lockTimeUnix: clientInfo.lockTimeUnix,
      fundingTxId: clientInfo.fundingTxId,
      fundingTxHex: clientInfo.fundingTxHex,
      fundingOutputIndex: clientInfo.fundingOutputIndex,
    );

    unawaited(_buildFunding(clientInfo.walletId, channelId, clientInfo, serverPubKey));
  }

  /// Asks the channel's wallet to build and sign its funding transaction,
  /// at ARC's published policy rate (bead libspiffy-zs4l).
  ///
  /// BuildFundingTransactionCommand is a wallet command: only the wallet
  /// aggregate handles it, reached through the wallet manager. It used to
  /// be told to the channel manager, which has no case for it and dropped
  /// it, so the client side never progressed past channel_accept. The
  /// FundingTransactionBuiltResponse comes back to the coordinator, which
  /// forwards it to handleFundingTransactionBuilt.
  ///
  /// The channel's own wallet funds it, not the adapter's last-created
  /// wallet: that is '' after a restart and another wallet once a second
  /// one is created (libspiffy-9fo).
  ///
  /// The aggregate cannot ask ARC, so the rate is asked for here. A rate
  /// ARC cannot give is a failed build, reported as one — to the host and
  /// to the server waiting for the refund — never a guessed rate.
  Future<void> _buildFunding(
      String walletId, String channelId, ClientChannelInfo clientInfo, String serverPubKey) async {
    final FeeRate feeRate;
    try {
      final quote = await _arcActor.ask<FeeRateQuote>(GetFeeRateMessage(), _feeRateTimeout);
      final rate = quote.rate;
      if (!quote.success || rate == null) throw StateError(quote.error ?? 'ARC gave no rate');
      feeRate = rate;
    } catch (e) {
      handleFundingTransactionBuilt(FundingTransactionBuiltResponse(
        walletId: walletId,
        correlationId: channelId,
        channelId: channelId,
        fundingTxHex: '',
        fundingTxId: '',
        fundingOutputIndex: -1,
        success: false,
        error: "ARC's policy fee rate could not be read ($e); no funding was built",
      ));
      return;
    }
    if (_disposed) return;
    _walletManager.tell(
      WalletCommandMessage(
        walletId,
        BuildFundingTransactionCommand(
          walletId: walletId,
          correlationId: channelId,
          channelId: channelId,
          clientPubKeyHex: clientInfo.clientPubKeyHex,
          serverPubKeyHex: serverPubKey,
          fundingAmountSats: clientInfo.fundingAmountSats,
          changeAddressBase58: clientInfo.clientAddressB58,
          derivationIndex: clientInfo.clientDerivationIndex,
          feeRate: feeRate,
        ),
      ),
      sender: _replyTo,
    );
  }

  void _handleChannelReject(String fromPeerId, Map<String, dynamic> payload) {
    final channelId = payload['channelId'] as String;
    final reason = payload['reason'] as String? ?? 'Rejected by peer';

    _cleanupChannel(channelId);

    _emitEvent(coord.ErrorEvent(
      source: 'ChannelP2PAdapter',
      message: 'Channel $channelId rejected: $reason',
    ));
  }

  void _handleRefundSignRequest(String fromPeerId, Map<String, dynamic> payload) {
    final channelId = payload['channelId'] as String;
    final refundTxHex = payload['refundTxHex'] as String;
    final fundingTxId = payload['fundingTxId'] as String;
    final fundingOutputIndex = payload['fundingOutputIndex'] as int;
    final fundingTxHex = payload['fundingTxHex'] as String;
    // No clientSignatureHex is read: the client does not sign the refund
    // before the server does (handleRefundTransactionBuilt sends none), and
    // the server signs the refund on its own. Casting the absent field to
    // String threw here, so the server never countersigned and every
    // client-side open stalled after refund_sign_request (libspiffy-9fo).

    final serverInfo = _serverChannelInfo[channelId];
    if (serverInfo == null) {
      _log.warning('Received refund_sign_request for unknown channel: $channelId');
      return;
    }

    // Store funding info on server side
    _serverChannelInfo[channelId] = ServerChannelInfo(
      channelId: channelId,
      walletId: serverInfo.walletId,
      clientPeerId: serverInfo.clientPeerId,
      clientPubKeyHex: serverInfo.clientPubKeyHex,
      clientAddressB58: serverInfo.clientAddressB58,
      serverPubKeyHex: serverInfo.serverPubKeyHex,
      serverAddressB58: serverInfo.serverAddressB58,
      derivationIndex: serverInfo.derivationIndex,
      fundingAmountSats: serverInfo.fundingAmountSats,
      lockTimeUnix: serverInfo.lockTimeUnix,
      fundingTxId: fundingTxId,
      fundingTxHex: fundingTxHex,
      fundingOutputIndex: fundingOutputIndex,
    );

    _channelManager.tell(SignRefundTransactionMessage(
      channelId: channelId,
      // The accepting wallet's key signs (libspiffy-9fo); the manager takes
      // it, and the key index, from the channel journal (libspiffy-36f).
      walletId: serverInfo.walletId,
      // The funding output the refund must spend (libspiffy-fsy).
      fundingTxId: fundingTxId,
      fundingOutputIndex: fundingOutputIndex,
      fundingTxHex: fundingTxHex,
      refundTxHex: refundTxHex,
      clientPubKeyHex: serverInfo.clientPubKeyHex,
      serverPubKeyHex: serverInfo.serverPubKeyHex,
      serverAddressB58: serverInfo.serverAddressB58,
      derivationIndex: serverInfo.derivationIndex,
      fundingAmountSats: BigInt.from(serverInfo.fundingAmountSats),
      lockTimeUnix: serverInfo.lockTimeUnix,
    ));
  }

  void _handleRefundSigned(String fromPeerId, Map<String, dynamic> payload) {
    final channelId = payload['channelId'] as String;
    final serverSignatureHex = payload['serverSignatureHex'] as String;

    // The manager answers with RefundSignatureRecordedResponse; a signature
    // that does not complete a valid refund is refused and reported
    // (libspiffy-b83), see handleRefundSignatureRecorded.
    _channelManager.tell(RecordRefundSignatureMessage(
      channelId: channelId,
      serverSignatureHex: serverSignatureHex,
    ), sender: _replyTo);
  }

  void _handleChannelOpen(String fromPeerId, Map<String, dynamic> payload) {
    final channelId = payload['channelId'] as String;
    final fundingTxId = payload['fundingTxId'] as String;
    final fundingOutputIndex = payload['fundingOutputIndex'] as int;
    final fundingTxHex = payload['fundingTxHex'] as String;

    // Server side: a funding transaction that does not lock the agreed
    // amount in the channel 2-of-2 is refused and reported (libspiffy-9f7),
    // and so is one whose BEEF does not pass SPV validation (libspiffy-fsy).
    _channelManager.tell(OpenChannelMessage(
      channelId: channelId,
      fundingTxId: fundingTxId,
      fundingOutputIndex: fundingOutputIndex,
      fundingTxHex: fundingTxHex,
      fundingBeefHex: payload['fundingBeef'] as String?,
    ), sender: _replyTo);
  }

  void _handlePaymentUpdate(String fromPeerId, Map<String, dynamic> payload) {
    final channelId = payload['channelId'] as String;
    final amountSats = payload['amountSats'] as int;
    final paymentTxHex = payload['paymentTxHex'] as String;
    final clientSignatureHex = payload['clientSignatureHex'] as String;
    final proposedSequence = payload['proposedSequence'] as int;
    final proposedClientBalance = payload['proposedClientBalance'] as int;
    final proposedServerBalance = payload['proposedServerBalance'] as int;

    // With a reply target, so a payment the aggregate refuses is answered
    // (bead libspiffy-fg06). Told with none, the refusal went nowhere: no
    // `payment_ack`, no `channel_error`, and a client that could not tell a
    // refusal from a lost message. See [handlePaymentAcknowledged].
    _channelManager.tell(AcknowledgePaymentMessage(
      channelId: channelId,
      walletId: _walletFor(channelId),
      amountSats: BigInt.from(amountSats),
      paymentTxHex: paymentTxHex,
      clientSignatureHex: clientSignatureHex,
      proposedSequence: proposedSequence,
      proposedClientBalance: BigInt.from(proposedClientBalance),
      proposedServerBalance: BigInt.from(proposedServerBalance),
    ), sender: _replyTo);
  }

  /// The server's countersignature of a payment, and the only copy of it the
  /// client will ever be sent (bead libspiffy-z2px).
  ///
  /// This used to log the acknowledgement and drop the signature, so the
  /// client's channel went on holding the UNSIGNED payment template — whose
  /// txid is not the txid the signed transaction will have — and a client
  /// cooperative close had nothing it could record in the wallet. The manager
  /// combines it with the client's own half, verifies the result against the
  /// funding output, and journals the settlement.
  void _handlePaymentAck(String fromPeerId, Map<String, dynamic> payload) {
    final channelId = payload['channelId'] as String;
    final sequenceNumber = payload['sequenceNumber'] as int;
    final serverSignatureHex = payload['serverSignatureHex'] as String?;
    _log.fine('Payment acknowledged for channel $channelId, sequence $sequenceNumber');

    if (serverSignatureHex == null || serverSignatureHex.isEmpty) {
      _log.warning('Payment ack for channel $channelId carries no server '
          'signature: this side keeps the unsigned payment template and a '
          'cooperative close will have no settlement to record');
      return;
    }

    _channelManager.tell(RecordPaymentCountersignatureMessage(
      channelId: channelId,
      sequenceNumber: sequenceNumber,
      serverSignatureHex: serverSignatureHex,
    ));
  }

  void _handleChannelClose(String fromPeerId, Map<String, dynamic> payload) {
    final channelId = payload['channelId'] as String;
    final reason = payload['reason'] as String?;

    if (_closingChannels.contains(channelId)) {
      _log.fine('Already closing channel $channelId, ignoring duplicate close');
      return;
    }

    _channelManager.tell(CloseChannelMessage(
      channelId: channelId,
      reason: reason,
    ));
  }

  /// The server closed the channel with the settlement it broadcast (bead
  /// libspiffy-u6q6). The client checks and records it, and the channel's
  /// own [ch.ChannelClosedEvent] then tells the host.
  ///
  /// This used to drop the channel's records and tell the host it had
  /// closed, journaling nothing: the client's channel stayed open, its
  /// return leg never reached the wallet, and the settlement it was told of
  /// was one nobody had broadcast.
  void _handleChannelClosed(String fromPeerId, Map<String, dynamic> payload) {
    final channelId = payload['channelId'] as String;
    final settlementTxHex = payload['settlementTxHex'] as String?;
    if (settlementTxHex == null || settlementTxHex.isEmpty) {
      _log.warning('channel_closed for $channelId carries no settlement: nothing '
          'is recorded and the channel is not closed on this side');
      return;
    }
    _channelManager.tell(
        RecordSettlementMessage(channelId: channelId, settlementTxHex: settlementTxHex),
        sender: _replyTo);
  }

  void _handleChannelError(String fromPeerId, Map<String, dynamic> payload) {
    final channelId = payload['channelId'] as String?;
    final error = payload['error'] as String? ?? 'Unknown channel error';

    _emitEvent(coord.ErrorEvent(
      source: 'ChannelP2PAdapter',
      message: 'Channel error${channelId != null ? ' ($channelId)' : ''}: $error',
    ));
  }

  // ===========================================================================
  // LIBSPIFFY EVENT HANDLING (from channel manager aggregate)
  // ===========================================================================

  void _handleEvent(ch.ChannelEvent event) {
    _log.fine('Handling channel event: ${event.runtimeType} for ${event.channelId}');

    // Requested and accepted events create the channel's record; the other
    // events the adapter acts on read it. The rest need nothing.
    final createsRecord =
        event is ch.ChannelRequestedEvent || event is ch.ChannelAcceptedEvent;
    final readsRecord = event is ch.ChannelRejectedEvent ||
        event is ch.RefundCountersignedEvent ||
        event is ch.ChannelOpenedEvent ||
        event is ch.PaymentRecordedEvent ||
        event is ch.PaymentAcknowledgedEvent ||
        event is ch.ChannelClosingEvent ||
        event is ch.ChannelClosedEvent;
    if (!createsRecord && !readsRecord) {
      _log.fine('Unhandled channel event type: ${event.runtimeType}');
      return;
    }
    _sequenced(readsRecord ? event.channelId : null, () => _dispatchEvent(event));
  }

  void _dispatchEvent(ch.ChannelEvent event) {
    if (event is ch.ChannelRequestedEvent) {
      _onChannelRequested(event);
    } else if (event is ch.ChannelAcceptedEvent) {
      _onChannelAccepted(event);
    } else if (event is ch.ChannelRejectedEvent) {
      _onChannelRejected(event);
    } else if (event is ch.RefundBuiltEvent) {
      _onRefundBuilt(event);
    } else if (event is ch.RefundCountersignedEvent) {
      _onRefundCountersigned(event);
    } else if (event is ch.ChannelOpenedEvent) {
      _onChannelOpened(event);
    } else if (event is ch.PaymentRecordedEvent) {
      _onPaymentRecorded(event);
    } else if (event is ch.PaymentAcknowledgedEvent) {
      _onPaymentAcknowledged(event);
    } else if (event is ch.ChannelClosingEvent) {
      _onChannelClosing(event);
    } else if (event is ch.ChannelClosedEvent) {
      _onChannelClosed(event);
    } else {
      _log.fine('Unhandled channel event type: ${event.runtimeType}');
    }
  }

  void _onChannelRequested(ch.ChannelRequestedEvent event) {
    // Store client channel info (we are the client)
    _clientChannelInfo[event.channelId] = ClientChannelInfo(
      channelId: event.channelId,
      walletId: event.walletId,
      clientPubKeyHex: event.clientPubKeyHex,
      clientAddressB58: event.clientAddressB58,
      clientDerivationIndex: event.derivationIndex,
      fundingAmountSats: event.fundingAmountSats.toInt(),
      lockTimeUnix: event.lockTimeUnix,
    );
    // The journal names both parties: the peer every later message about
    // this channel must come from is the one it records (libspiffy-i0e6).
    final peers = _channelPeers[event.channelId] =
        PeerInfo(clientPeerId: event.clientPeerId, serverPeerId: event.serverPeerId);

    _emitP2PMessage(peers.serverPeerId, 'channel_request', {
      'channelId': event.channelId,
      'clientPeerId': _myPeerId,
      'clientPubKey': event.clientPubKeyHex,
      'clientAddress': event.clientAddressB58,
      'fundingAmountSats': event.fundingAmountSats.toInt(),
      'lockTimeUnix': event.lockTimeUnix,
      'context': event.context,
    });
  }

  void _onChannelAccepted(ch.ChannelAcceptedEvent event) {
    // Store server channel info (we are the server)
    _serverChannelInfo[event.channelId] = ServerChannelInfo(
      channelId: event.channelId,
      walletId: event.walletId,
      clientPeerId: event.clientPeerId,
      clientPubKeyHex: event.clientPubKeyHex,
      clientAddressB58: event.clientAddressB58,
      serverPubKeyHex: event.serverPubKeyHex,
      serverAddressB58: event.serverAddressB58,
      derivationIndex: event.derivationIndex,
      fundingAmountSats: event.fundingAmountSats.toInt(),
      lockTimeUnix: event.lockTimeUnix,
    );

    _emitP2PMessage(event.clientPeerId, 'channel_accept', {
      'channelId': event.channelId,
      'serverPubKey': event.serverPubKeyHex,
      'serverAddress': event.serverAddressB58,
      'derivationIndex': event.derivationIndex,
    });
  }

  void _onChannelRejected(ch.ChannelRejectedEvent event) {
    final peers = _channelPeers[event.channelId];
    final pending = _pendingRequests[event.channelId];
    final targetPeerId = pending?.clientPeerId ?? peers?.clientPeerId;

    if (targetPeerId != null) {
      _emitP2PMessage(targetPeerId, 'channel_reject', {
        'channelId': event.channelId,
        'reason': event.reason,
      });
    }

    _cleanupChannel(event.channelId);
  }

  /// The client journals its refund before asking the server to sign it
  /// (libspiffy-b83); the request itself is sent from
  /// [handleRefundTransactionBuilt], once, when the build is answered.
  void _onRefundBuilt(ch.RefundBuiltEvent event) {
    _log.fine('Refund of channel ${event.channelId} journaled');
  }

  void _onRefundCountersigned(ch.RefundCountersignedEvent event) {
    final serverInfo = _serverChannelInfo[event.channelId];
    final clientInfo = _clientChannelInfo[event.channelId];

    if (serverInfo != null) {
      // We are the server - send refund_signed back to client
      _emitP2PMessage(serverInfo.clientPeerId, 'refund_signed', {
        'channelId': event.channelId,
        'serverSignatureHex': event.serverSignatureHex,
      });
    } else if (clientInfo != null) {
      // We are the client - the refund is fully signed and verified: fund
      // and open the channel. The manager broadcasts the funding
      // transaction first; a failure comes back as ChannelOpenedResponse
      // (handleChannelOpenedResponse) and the channel does not open.
      if (clientInfo.fundingTxId != null) {
        _channelManager.tell(OpenChannelMessage(
          channelId: event.channelId,
          fundingTxId: clientInfo.fundingTxId!,
          fundingOutputIndex: clientInfo.fundingOutputIndex ?? 0,
          fundingTxHex: clientInfo.fundingTxHex ?? '',
        ), sender: _replyTo);
      } else {
        _log.warning('No funding tx info for client channel ${event.channelId}');
      }
    } else {
      _log.warning('RefundCountersigned for unknown channel: ${event.channelId}');
    }
  }

  void _onChannelOpened(ch.ChannelOpenedEvent event) {
    final clientInfo = _clientChannelInfo[event.channelId];
    final peers = _channelPeers[event.channelId];

    if (clientInfo != null && peers != null) {
      // We are the client - notify server that channel is open
      _emitP2PMessage(peers.serverPeerId, 'channel_open', {
        'channelId': event.channelId,
        'fundingTxId': event.fundingTxId,
        'fundingOutputIndex': event.fundingOutputIndex,
        'fundingTxHex': event.fundingTxHex,
        // The funding transaction with its ancestors and their merkle
        // proofs, for the server to SPV-validate (libspiffy-fsy).
        'fundingBeef': event.fundingBeefHex,
      });
    }

    // Emit coordinator event for both client and server
    _emitEvent(coord.ChannelOpenedEvent(
      walletId: _walletFor(event.channelId),
      channelId: event.channelId,
      fundingTxId: event.fundingTxId,
      fundingAmountSats: event.initialClientBalanceSats.toInt() +
          event.initialServerBalanceSats.toInt(),
    ));
  }

  void _onPaymentRecorded(ch.PaymentRecordedEvent event) {
    final peers = _channelPeers[event.channelId];
    if (peers == null) {
      _log.warning('No peer info for channel ${event.channelId}');
      return;
    }

    _emitP2PMessage(peers.serverPeerId, 'payment_update', {
      'channelId': event.channelId,
      'amountSats': event.amountSats.toInt(),
      'paymentTxHex': event.paymentTxHex,
      'clientSignatureHex': event.clientSignatureHex,
      'proposedSequence': event.sequenceNumber,
      'proposedClientBalance': event.newClientBalanceSats.toInt(),
      'proposedServerBalance': event.newServerBalanceSats.toInt(),
      'purpose': event.purpose,
      'invoiceId': event.invoiceId,
    });

    _emitEvent(coord.ChannelPaymentEvent(
      walletId: _walletFor(event.channelId),
      channelId: event.channelId,
      amountSats: event.amountSats.toInt(),
      sequence: event.sequenceNumber,
      clientBalance: event.newClientBalanceSats.toInt(),
      serverBalance: event.newServerBalanceSats.toInt(),
    ));
  }

  void _onPaymentAcknowledged(ch.PaymentAcknowledgedEvent event) {
    final peers = _channelPeers[event.channelId];
    final serverInfo = _serverChannelInfo[event.channelId];

    if (serverInfo != null && peers != null) {
      // We are the server - send ack back to client
      _emitP2PMessage(peers.clientPeerId, 'payment_ack', {
        'channelId': event.channelId,
        'sequenceNumber': event.sequenceNumber,
        'serverSignatureHex': event.serverSignatureHex,
      });
    }

    _emitEvent(coord.ChannelPaymentEvent(
      walletId: _walletFor(event.channelId),
      channelId: event.channelId,
      amountSats: event.amountSats.toInt(),
      sequence: event.sequenceNumber,
      clientBalance: event.newClientBalanceSats.toInt(),
      serverBalance: event.newServerBalanceSats.toInt(),
    ));
  }

  void _onChannelClosing(ch.ChannelClosingEvent event) {
    _closingChannels.add(event.channelId);

    final peers = _channelPeers[event.channelId];
    if (peers != null) {
      final targetPeerId = event.initiator == 'client'
          ? peers.serverPeerId
          : peers.clientPeerId;
      _emitP2PMessage(targetPeerId, 'channel_close', {
        'channelId': event.channelId,
        'reason': event.reason,
      });
    }
  }

  void _onChannelClosed(ch.ChannelClosedEvent event) {
    // The server closes with the settlement it broadcast and hands it to
    // the client, which records its return leg from it (bead
    // libspiffy-u6q6). The client, closing with what it was handed, has
    // nothing to tell.
    final serverInfo = _serverChannelInfo[event.channelId];
    final clientPeerId = serverInfo == null ? null : _counterpartyPeer(event.channelId);
    if (clientPeerId != null) {
      _emitP2PMessage(clientPeerId, 'channel_closed', {
        'channelId': event.channelId,
        'settlementTxId': event.settlementTxId,
        'settlementTxHex': event.settlementTxHex,
      });
    }

    final walletId = _walletFor(event.channelId);
    _cleanupChannel(event.channelId);

    _emitEvent(coord.ChannelClosedEvent(
      walletId: walletId,
      channelId: event.channelId,
      settlementTxId: event.settlementTxId,
    ));
  }

  // ===========================================================================
  // HIGH-LEVEL COMMAND HANDLERS
  // ===========================================================================

  /// Handle a request to open a new payment channel as client.
  void handleOpenChannel(coord.OpenChannelCommand command) =>
      _sequenced(null, () => _openChannel(command));

  void _openChannel(coord.OpenChannelCommand command) {
    // A timestamp-derived id repeated within one millisecond (A-L1).
    final channelId = uniqueId('ch');

    _channelPeers[channelId] = PeerInfo(
      clientPeerId: _myPeerId,
      serverPeerId: command.serverPeerId,
    );

    _channelManager.tell(InitiateChannelMessage(
      channelId: channelId,
      walletId: command.walletId,
      clientPeerId: _myPeerId,
      serverPeerId: command.serverPeerId,
      fundingAmountSats: BigInt.from(command.fundingAmountSats),
      lockTimeDurationSeconds: command.lockTimeDurationSeconds,
      context: command.context,
      counterpartyMarker: command.counterpartyMarker,
    ));
  }

  /// Handle a request to make a payment over an open channel.
  void handleMakePayment(coord.ChannelPayCommand command) {
    _channelManager.tell(RecordPaymentMessage(
      channelId: command.channelId,
      walletId: command.walletId,
      amountSats: BigInt.from(command.amountSats),
      purpose: command.purpose,
      invoiceId: command.invoiceId,
    ));
  }

  /// Handle a request to close a channel.
  void handleCloseChannel(coord.CloseChannelCommand command) {
    _channelManager.tell(
        CloseChannelMessage(
          channelId: command.channelId,
          reason: command.reason,
        ),
        // A close that fails — a settlement ARC did not take — is reported
        // (bead libspiffy-u6q6); see [handleChannelCloseAnswered].
        sender: _replyTo);
  }

  /// The manager's answer to a close, or to a settlement handed over: a
  /// failure is reported to the host, whose channel stays `closing` until
  /// it closes again (bead libspiffy-u6q6). A close that succeeded is
  /// reported by its [ch.ChannelClosedEvent].
  void handleChannelCloseAnswered(ChannelClosedResponse response) {
    if (!response.success) {
      _reportFailure(response.channelId, 'closing the channel', response.error);
    }
  }

  /// The manager's answer to an expiry: a failure (a server whose
  /// settlement ARC did not take, bead libspiffy-u6q6) is reported.
  void handleChannelExpiryAnswered(ChannelExpiredResponse response) {
    if (!response.success) {
      _reportFailure(response.channelId, 'recording the expiry', response.error);
    }
  }

  /// Handle a request to record channel expiry (lockTime elapsed).
  void handleExpireChannel(coord.ExpireChannelCommand command) {
    _channelManager.tell(
        ExpireChannelMessage(
          channelId: command.channelId,
          observedBy: command.observedBy,
          settlementOrRefundTxId: command.settlementOrRefundTxId,
        ),
        sender: _replyTo);
  }

  /// Handle a request to claim the refund of an expired channel.
  ///
  /// Not [_sequenced], for the same reason close and expire are not: the
  /// claim needs nothing from this adapter's per-channel cache (peers, keys,
  /// funding transaction). The channel manager reads the channel's own state
  /// from its journal, so there is nothing here to rebuild first, and making
  /// it wait behind a rebuild would only delay a transaction that is already
  /// past its lockTime.
  void handleClaimRefund(coord.ClaimChannelRefundCommand command) {
    _channelManager.tell(
        ClaimRefundMessage(
          channelId: command.channelId,
          refundTxHex: command.refundTxHex,
        ),
        // Without a reply target the manager's
        // [ChannelRefundClaimedResponse] goes nowhere and the host never
        // learns whether its money came back (the V-99 follow-up).
        sender: _replyTo);
  }

  /// The manager's answer to a refund claim, reported to the host.
  ///
  /// The peer is told nothing either way. A refund the network refused —
  /// most likely because the counterparty's settlement reached it first —
  /// has abandoned no channel, and there is no counterparty to negotiate
  /// with on a channel being claimed unilaterally.
  void handleChannelRefundClaimed(ChannelRefundClaimedResponse response) {
    if (!response.success) {
      _log.warning('Channel ${response.channelId}: claiming the refund '
          'failed: ${response.error ?? 'unknown error'}');
    }
    _emitEvent(coord.ChannelRefundClaimedEvent(
      walletId: _walletFor(response.channelId),
      channelId: response.channelId,
      refundTxId: response.refundTxId,
      success: response.success,
      error: response.error,
    ));
  }

  /// Handle a request to retry a failed funding broadcast (bead
  /// libspiffy-1n3).
  ///
  /// [_sequenced] on the channel: a successful retry opens the channel, and
  /// [_onChannelOpened] needs this adapter's record of it to know where to
  /// send `channel_open`. Rebuilding that record first also keeps the
  /// rebuild ([ChannelDetailsQueryMessage]) out of the window in which the
  /// manager's mailbox is busy broadcasting.
  ///
  /// The reply target is the coordinator, so
  /// [handleChannelFundingRetried] reports the outcome. The retry never
  /// sends the peer a `channel_error`: the counterparty was told when the
  /// original attempt failed, and a repair that fails again has abandoned
  /// nothing.
  void handleRetryChannelFunding(coord.RetryChannelFundingCommand command) =>
      _sequenced(
          command.channelId,
          () => _channelManager.tell(
              RetryChannelFundingMessage(channelId: command.channelId),
              sender: _replyTo));

  /// Handle a request to send `channel_open` again (bead libspiffy-1n3).
  ///
  /// [_sequenced] on the channel, because the send needs this adapter's
  /// record of who the counterparty is; after a restart that record is
  /// rebuilt from the journal first.
  ///
  /// Deliberately NOT an [OpenChannelMessage]: the channel is already open,
  /// so the aggregate would refuse that ('Refund not signed yet'), and the
  /// refusal would reach [handleChannelOpenedResponse], which tells the
  /// counterparty the channel failed. The manager only reads state here and
  /// journals nothing.
  void handleResendChannelOpen(coord.ResendChannelOpenCommand command) =>
      _sequenced(
          command.channelId,
          () => _channelManager.tell(
              ResendChannelOpenMessage(channelId: command.channelId),
              sender: _replyTo));

  /// Handle acceptance of an incoming channel request (we are server).
  ///
  /// The request itself is not journaled (no channel exists before it is
  /// accepted): a request received before a restart is accepted from what
  /// [command] repeats of it (libspiffy-36f).
  void handleAcceptRequest(coord.AcceptChannelCommand command) =>
      _sequenced(null, () => _acceptRequest(command));

  void _acceptRequest(coord.AcceptChannelCommand command) {
    final pending = _pendingRequests.remove(command.channelId) ??
        PendingRequest(
          channelId: command.channelId,
          clientPeerId: command.clientPeerId,
          clientPubKey: command.clientPubKey,
          clientAddress: command.clientAddress,
          fundingAmountSats: command.fundingAmountSats,
          lockTimeUnix: command.lockTimeUnix,
        );

    _channelPeers[command.channelId] = PeerInfo(
      clientPeerId: pending.clientPeerId,
      serverPeerId: _myPeerId,
    );

    _channelManager.tell(AcceptChannelMessage(
      channelId: command.channelId,
      walletId: command.walletId,
      clientPeerId: pending.clientPeerId,
      clientPubKeyHex: pending.clientPubKey,
      clientAddressB58: pending.clientAddress,
      fundingAmountSats: BigInt.from(pending.fundingAmountSats),
      lockTimeUnix: pending.lockTimeUnix,
      context: pending.context,
      counterpartyMarker: command.counterpartyMarker,
      serverPeerId: _myPeerId.isEmpty ? null : _myPeerId,
    ));
  }

  /// Handle rejection of an incoming channel request.
  void handleRejectRequest(coord.RejectChannelCommand command) =>
      _sequenced(null, () => _rejectRequest(command));

  void _rejectRequest(coord.RejectChannelCommand command) {
    final pending = _pendingRequests.remove(command.channelId);
    if (pending != null) {
      _emitP2PMessage(pending.clientPeerId, 'channel_reject', {
        'channelId': command.channelId,
        'reason': command.reason ?? 'Rejected',
      });
    }

    _cleanupChannel(command.channelId);
  }

  /// Handle a funding transaction that has been built by the wallet.
  void handleFundingTransactionBuilt(FundingTransactionBuiltResponse response) =>
      _sequenced(response.channelId, () => _fundingTransactionBuilt(response));

  void _fundingTransactionBuilt(FundingTransactionBuiltResponse response) {
    final channelId = response.channelId;
    final clientInfo = _clientChannelInfo[channelId];

    if (clientInfo == null) {
      _log.warning('No client info for channel $channelId');
      return;
    }

    // A failed build has no funding transaction to refund (libspiffy-lhd).
    if (!response.success) {
      // The server accepted this channel and is waiting for the refund it
      // must sign; it never arrives (bead libspiffy-kyw).
      _reportFailure(channelId, 'building the funding transaction',
          response.error, tellPeer: true);
      return;
    }

    // Update client info with funding tx details
    _clientChannelInfo[channelId] = ClientChannelInfo(
      channelId: channelId,
      walletId: clientInfo.walletId,
      clientPubKeyHex: clientInfo.clientPubKeyHex,
      clientAddressB58: clientInfo.clientAddressB58,
      clientDerivationIndex: clientInfo.clientDerivationIndex,
      serverPubKeyHex: clientInfo.serverPubKeyHex,
      serverAddressB58: clientInfo.serverAddressB58,
      serverDerivationIndex: clientInfo.serverDerivationIndex,
      fundingAmountSats: clientInfo.fundingAmountSats,
      lockTimeUnix: clientInfo.lockTimeUnix,
      fundingTxId: response.fundingTxId,
      fundingTxHex: response.fundingTxHex,
      fundingOutputIndex: response.fundingOutputIndex,
    );

    // Now build the refund transaction. The RefundTransactionBuiltResponse
    // goes to the coordinator, which forwards it to
    // handleRefundTransactionBuilt; without a sender it was dropped.
    _channelManager.tell(BuildRefundTransactionMessage(
      channelId: channelId,
      walletId: clientInfo.walletId,
      fundingTxId: response.fundingTxId,
      fundingOutputIndex: response.fundingOutputIndex,
      fundingAmountSats: BigInt.from(clientInfo.fundingAmountSats),
      clientPubKeyHex: clientInfo.clientPubKeyHex,
      clientAddressB58: clientInfo.clientAddressB58,
      serverPubKeyHex: clientInfo.serverPubKeyHex ?? '',
      serverAddressB58: clientInfo.serverAddressB58 ?? '',
      lockTimeUnix: clientInfo.lockTimeUnix,
      // Journaled with the refund, broadcast once it is countersigned.
      fundingTxHex: response.fundingTxHex,
      fundingInputSats: response.totalInputSats,
    ), sender: _replyTo);
  }

  /// Handle a refund transaction that has been built.
  void handleRefundTransactionBuilt(RefundTransactionBuiltResponse response) =>
      _sequenced(response.channelId, () => _refundTransactionBuilt(response));

  void _refundTransactionBuilt(RefundTransactionBuiltResponse response) {
    final channelId = response.channelId;
    final clientInfo = _clientChannelInfo[channelId];
    final peers = _channelPeers[channelId];

    if (clientInfo == null || peers == null) {
      _log.warning('No client info or peers for channel $channelId');
      return;
    }

    // The channel manager failed: there is no refund for the server to sign,
    // so the peer is not asked to (libspiffy-lhd).
    if (!response.success) {
      _reportFailure(channelId, 'building the refund transaction',
          response.error, tellPeer: true);
      return;
    }

    _emitP2PMessage(peers.serverPeerId, 'refund_sign_request', {
      'channelId': channelId,
      'refundTxHex': response.refundTxHex,
      'fundingTxId': clientInfo.fundingTxId,
      'fundingOutputIndex': clientInfo.fundingOutputIndex,
      'fundingTxHex': clientInfo.fundingTxHex,
    });
  }

  /// The manager's answer to recording the server's refund signature: a
  /// signature that does not complete a valid refund stops the open.
  void handleRefundSignatureRecorded(RefundSignatureRecordedResponse response) {
    if (!response.success) {
      _sequenced(
          response.channelId,
          () => _reportFailure(response.channelId,
              'recording the server refund signature', response.error,
              // The server signed and waits for channel_open; this client
              // will not send one.
              tellPeer: true));
    }
  }

  /// The manager's answer to acknowledging a client's payment (bead
  /// libspiffy-fg06).
  ///
  /// A success needs nothing here: the channel's own
  /// [ch.PaymentAcknowledgedEvent] is what sends `payment_ack`, with the
  /// server signature the client cannot get anywhere else. A refusal has no
  /// such event, and used to produce nothing at all — so this sends
  /// `channel_error`, which is the client's only way to tell a payment the
  /// server rejected from one that never arrived.
  ///
  /// `tellPeer` is right here and is not everywhere: the client is blocked
  /// waiting on this exact payment, and its channel is still open — the
  /// error names the payment, not the channel's end.
  void handlePaymentAcknowledged(PaymentAcknowledgedResponse response) {
    if (response.success) return;
    _sequenced(
        response.channelId,
        () => _reportFailure(response.channelId,
            'acknowledging the payment', response.error,
            tellPeer: true));
  }

  /// The manager's answer to opening a channel: on the client a failed
  /// funding broadcast (the channel stays unopened, awaiting funding), on
  /// the server a funding transaction that was refused.
  void handleChannelOpenedResponse(ChannelOpenedResponse response) {
    if (!response.success) {
      _sequenced(
          response.channelId,
          () => _reportFailure(
              response.channelId, 'opening the channel', response.error,
              // The server refused the funding transaction, or the client
              // could not broadcast it: either way the counterparty is
              // waiting for a channel that is not coming (libspiffy-kyw).
              tellPeer: true));
    }
  }

  /// The manager's answer to a funding retry (bead libspiffy-1n3), reported
  /// on the coordinator stream and nowhere else.
  ///
  /// A failure is **not** [_reportFailure] with `tellPeer`: nothing here has
  /// been abandoned that the counterparty was not already told about when
  /// the original attempt failed, the channel's inputs are still reserved
  /// for the same transaction, and the host can retry again. On success the
  /// channel's own [ch.ChannelOpenedEvent] sends `channel_open` as it does
  /// on a first open, so there is nothing to send from here.
  void handleChannelFundingRetried(ChannelFundingRetriedResponse response) {
    if (!response.success) {
      _log.warning('Channel ${response.channelId}: retrying the funding '
          'broadcast failed: ${response.error ?? 'unknown error'}');
    }
    _emitEvent(coord.ChannelFundingRetriedEvent(
      walletId: _walletFor(response.channelId),
      channelId: response.channelId,
      fundingTxId: response.fundingTxId,
      success: response.success,
      error: response.error,
    ));
  }

  /// The manager's answer to a `channel_open` re-send (bead libspiffy-1n3):
  /// the payload of the message to repeat, rebuilt from the channel's
  /// journaled state.
  ///
  /// Sends exactly what [_onChannelOpened] sent the first time, to the
  /// counterparty [_counterpartyPeer] names — the one peer lookup in this
  /// file that survives a record rebuilt from a journal without a peer id.
  /// A failure, here or in the manager, is reported locally; the peer is
  /// never sent a `channel_error`, because a re-send that cannot happen has
  /// abandoned nothing.
  void handleChannelOpenResent(ChannelOpenResentResponse response) =>
      _sequenced(response.channelId, () => _resendChannelOpen(response));

  void _resendChannelOpen(ChannelOpenResentResponse response) {
    final channelId = response.channelId;

    void refuse(String error) {
      _log.warning('Channel $channelId: channel_open was not re-sent: $error');
      _emitEvent(coord.ChannelOpenResentEvent(
        walletId: response.walletId ?? _walletFor(channelId),
        channelId: channelId,
        success: false,
        error: error,
      ));
    }

    if (!response.success) {
      refuse(response.error ?? 'unknown error');
      return;
    }
    final peerId = _counterpartyPeer(channelId);
    if (peerId == null) {
      refuse('no counterparty peer is known for this channel, so there is '
          'nowhere to send it');
      return;
    }

    _emitP2PMessage(peerId, 'channel_open', {
      'channelId': channelId,
      'fundingTxId': response.fundingTxId,
      'fundingOutputIndex': response.fundingOutputIndex,
      'fundingTxHex': response.fundingTxHex,
      // The funding transaction with its ancestors and their merkle
      // proofs, for the server to SPV-validate (libspiffy-fsy).
      'fundingBeef': response.fundingBeefHex,
    });
    _emitEvent(coord.ChannelOpenResentEvent(
      walletId: response.walletId ?? _walletFor(channelId),
      channelId: channelId,
      toPeerId: peerId,
      fundingTxId: response.fundingTxId,
      success: true,
    ));
  }

  // ===========================================================================
  // HELPERS
  // ===========================================================================

  void _emitP2PMessage(String targetPeerId, String messageType, Map<String, dynamic> payload) {
    _emitEvent(coord.ChannelP2PMessageToSendEvent(
      toPeerId: targetPeerId,
      messageType: messageType,
      payload: payload,
    ));
  }

  /// Logs a failed channel step and surfaces it as a coordinator
  /// [coord.ErrorEvent].
  ///
  /// With [tellPeer], the counterparty is also sent a `channel_error`: every
  /// step this reports is one this side has abandoned, and the peer is
  /// waiting for what comes next (bead libspiffy-kyw). A failure the peer
  /// cannot be waiting for reports locally only.
  void _reportFailure(String channelId, String step, String? error,
      {bool tellPeer = false}) {
    final message =
        'Channel $channelId: $step failed: ${error ?? 'unknown error'}';
    _log.warning(message);
    _emitEvent(coord.ErrorEvent(
      walletId: _walletFor(channelId),
      source: 'ChannelP2PAdapter',
      message: message,
    ));
    if (tellPeer) _tellPeerChannelError(channelId, message);
  }

  /// The peer on the other side of [channelId]: the client of a channel this
  /// node is the server of, the server of one it is the client of. Null when
  /// the channel is known to neither side's records.
  String? _counterpartyPeer(String channelId) {
    final peers = _channelPeers[channelId];
    final serverInfo = _serverChannelInfo[channelId];
    if (serverInfo != null) {
      for (final candidate in [
        serverInfo.clientPeerId,
        peers?.clientPeerId,
        _pendingRequests[channelId]?.clientPeerId,
      ]) {
        if (candidate != null && candidate.isNotEmpty) return candidate;
      }
      return null;
    }
    if (_clientChannelInfo.containsKey(channelId)) {
      final serverPeerId = peers?.serverPeerId;
      return (serverPeerId == null || serverPeerId.isEmpty)
          ? null
          : serverPeerId;
    }
    final pending = _pendingRequests[channelId]?.clientPeerId;
    return (pending == null || pending.isEmpty) ? null : pending;
  }

  /// Tells the counterparty that this side has given up on [channelId], with
  /// the reason (bead libspiffy-kyw).
  ///
  /// The inbound half of this message has always existed
  /// ([_handleChannelError]); nothing sent it. A server that refuses a
  /// channel open — the funding transaction failed SPV validation, say —
  /// left the client waiting for a channel that will never open, and a
  /// client whose own step failed left the server waiting for the next
  /// message of the handshake. The local records are kept: this says the
  /// step failed, not that the channel is gone.
  void _tellPeerChannelError(String channelId, String message) {
    final peer = _counterpartyPeer(channelId);
    if (peer == null) {
      _log.warning(
          'Channel $channelId: no counterparty to tell that it failed');
      return;
    }
    _emitP2PMessage(peer, 'channel_error', {
      'channelId': channelId,
      'error': message,
    });
  }

  /// The wallet a channel belongs to (the one that requested or accepted
  /// it), falling back to the last wallet set via [updateWalletId] for a
  /// channel this adapter has no record of.
  String _walletFor(String channelId) =>
      _clientChannelInfo[channelId]?.walletId ??
      _serverChannelInfo[channelId]?.walletId ??
      _walletId;

  void _cleanupChannel(String channelId) {
    _channelPeers.remove(channelId);
    _pendingRequests.remove(channelId);
    _clientChannelInfo.remove(channelId);
    _serverChannelInfo.remove(channelId);
    _closingChannels.remove(channelId);
  }
}

// =============================================================================
// HELPER CLASSES
// =============================================================================

/// Tracks which peers are involved in a channel.
class PeerInfo {
  final String clientPeerId;
  final String serverPeerId;

  PeerInfo({
    required this.clientPeerId,
    required this.serverPeerId,
  });
}

/// A pending incoming channel request awaiting accept/reject.
class PendingRequest {
  final String channelId;
  final String clientPeerId;
  final String clientPubKey;
  final String clientAddress;
  final int fundingAmountSats;
  final int lockTimeUnix;
  final String? context;

  PendingRequest({
    required this.channelId,
    required this.clientPeerId,
    required this.clientPubKey,
    required this.clientAddress,
    required this.fundingAmountSats,
    required this.lockTimeUnix,
    this.context,
  });
}

/// Tracks state for a channel we initiated (client role).
class ClientChannelInfo {
  final String channelId;
  final String walletId;
  final String clientPubKeyHex;
  final String clientAddressB58;
  final int clientDerivationIndex;
  final String? serverPubKeyHex;
  final String? serverAddressB58;
  final int? serverDerivationIndex;
  final int fundingAmountSats;
  final int lockTimeUnix;
  final String? fundingTxId;
  final String? fundingTxHex;
  final int? fundingOutputIndex;

  ClientChannelInfo({
    required this.channelId,
    required this.walletId,
    required this.clientPubKeyHex,
    required this.clientAddressB58,
    required this.clientDerivationIndex,
    this.serverPubKeyHex,
    this.serverAddressB58,
    this.serverDerivationIndex,
    required this.fundingAmountSats,
    required this.lockTimeUnix,
    this.fundingTxId,
    this.fundingTxHex,
    this.fundingOutputIndex,
  });
}

/// Tracks state for a channel we accepted (server role).
class ServerChannelInfo {
  final String channelId;
  final String walletId;
  final String clientPeerId;
  final String clientPubKeyHex;
  final String clientAddressB58;
  final String serverPubKeyHex;
  final String serverAddressB58;
  final int derivationIndex;
  final int fundingAmountSats;
  final int lockTimeUnix;
  final String? fundingTxId;
  final String? fundingTxHex;
  final int? fundingOutputIndex;

  ServerChannelInfo({
    required this.channelId,
    required this.walletId,
    required this.clientPeerId,
    required this.clientPubKeyHex,
    required this.clientAddressB58,
    required this.serverPubKeyHex,
    required this.serverAddressB58,
    required this.derivationIndex,
    required this.fundingAmountSats,
    required this.lockTimeUnix,
    this.fundingTxId,
    this.fundingTxHex,
    this.fundingOutputIndex,
  });
}
