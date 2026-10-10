import 'dart:async';

import 'package:dactor/dactor.dart';
import 'package:logging/logging.dart';

import '../core/channel_events.dart' as ch;
import '../core/wallet_commands.dart';
import '../models/channel_timing.dart';
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

  /// The app's channel requests still to be answered, by what they ask and
  /// the channel, oldest first: the channel manager answers a channel's
  /// messages in the order it gets them (bead libspiffy-xc78.2).
  final Map<(_Request, String), List<String>> _requests = {};

  void _awaiting(_Request request, String channelId, String requestId) =>
      (_requests[(request, channelId)] ??= []).add(requestId);

  /// The oldest [request] for [channelId] still to be answered, now
  /// answered; null when there is none (the step was not the app's request:
  /// a peer's message, the settlement timer, the server's side of an open).
  String? _answering(_Request request, String channelId) {
    final waiting = _requests[(request, channelId)];
    if (waiting == null || waiting.isEmpty) return null;
    final requestId = waiting.removeAt(0);
    if (waiting.isEmpty) _requests.remove((request, channelId));
    return requestId;
  }

  /// How long the channel manager may take to answer a request it handles
  /// itself (it may be busy broadcasting a funding transaction).
  static const Duration _managerTimeout = Duration(seconds: 60);

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
    ChannelTiming? timing,
  })  : _channelManager = channelManager,
        _timing = timing,
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

  /// The node's channel timing (bead libspiffy-ywbk); null for a node that
  /// does no channels, which then settles nothing by itself.
  final ChannelTiming? _timing;

  /// The settlement armed for each channel this node serves, by channel id.
  final Map<String, Timer> _settlements = {};

  /// What each channel this node is the client of still has to get to its
  /// server, by channel id (bead overnode_v2-0o5.3.2): the latest payment
  /// not yet acknowledged, and the close until `channel_closed` arrives.
  /// Nothing else resends a message the transport lost.
  final Map<String, _Outbox> _outboxes = {};

  /// The app's payments not yet acknowledged, by channel id and sequence.
  final Map<String, Map<int, _Unconfirmed>> _unconfirmed = {};

  /// The latest payment of each channel this node is the client of, as
  /// `payment_update` sends it: what its close carries, so the server is
  /// paid it even when its `payment_update` was lost.
  final Map<String, Map<String, dynamic>> _latestPayment = {};

  Duration get _resendAfter => _timing?.resendAfter ?? const Duration(seconds: 2);
  Duration get _resendAtMost => _timing?.resendAtMost ?? const Duration(seconds: 30);
  Duration get _confirmWithin => _timing?.confirmWithin ?? const Duration(seconds: 20);

  /// Closes [channelId], a channel this node serves locked until
  /// [lockTimeUnix], when its settlement margin begins — or [now] (bead
  /// libspiffy-ywbk).
  ///
  /// The server's payments exist only once its settlement is on the network
  /// before the client's refund becomes valid, and nothing used to settle a
  /// channel unless the app remembered to close it. The close is the
  /// ordinary one: the settlement is broadcast before the channel is
  /// journaled closed (V-140), and a failure reaches the host as an
  /// [coord.ErrorEvent]. Re-armed at startup by the coordinator.
  void settleBeforeLockTime(String channelId, int lockTimeUnix, {bool now = false}) {
    final timing = _timing;
    if (timing == null || _disposed) return;
    _settlements.remove(channelId)?.cancel();
    final settleBy = DateTime.fromMillisecondsSinceEpoch(timing.settleByUnix(lockTimeUnix) * 1000);
    final wait = now ? Duration.zero : settleBy.difference(DateTime.now());
    _settlements[channelId] = Timer(wait.isNegative ? Duration.zero : wait, () {
      _settlements.remove(channelId);
      if (_disposed) return;
      // No app request: nothing waits for this close's answer.
      _close(channelId, 'settling ${timing.settlementMargin.inSeconds} s before the lock time');
    });
  }

  void dispose() {
    for (final timer in _settlements.values) {
      timer.cancel();
    }
    _settlements.clear();
    for (final outbox in _outboxes.values) {
      outbox.timer?.cancel();
    }
    _outboxes.clear();
    for (final waiting in _unconfirmed.values) {
      for (final payment in waiting.values) {
        payment.deadline.cancel();
      }
    }
    _unconfirmed.clear();
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
      final latestHex = state.latestPaymentTxHex;
      final signature = state.latestClientSignatureHex;
      if (state.latestSequenceNumber > 0 && latestHex != null && signature != null) {
        _latestPayment[channelId] = _paymentUpdate(
          channelId: channelId,
          // The amount of the latest payment alone is not journaled in the
          // state; the server reads the payment from the balances.
          amountSats: 0,
          paymentTxHex: latestHex,
          clientSignatureHex: signature,
          sequence: state.latestSequenceNumber,
          clientBalance: state.clientBalanceSats.toInt(),
          serverBalance: state.serverBalanceSats.toInt(),
        );
      }
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
    'channel_opened',
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
      case 'channel_opened':
        _handleChannelOpenedByServer(payload);
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
      requestId: _answering(_Request.open, channelId),
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

  /// The server opened the channel (bead libspiffy-jark): the client opens
  /// it too, answered in [handleServerOpenRecorded].
  void _handleChannelOpenedByServer(Map<String, dynamic> payload) {
    _channelManager.tell(RecordServerOpenedMessage(
      channelId: payload['channelId'] as String,
      fundingTxId: payload['fundingTxId'] as String,
      fundingOutputIndex: payload['fundingOutputIndex'] as int,
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
      // The one payment of nothing is a client's with no payment, closing
      // (bead libspiffy-w4l2); the aggregate refuses it on any other channel.
      closing: amountSats == 0 && proposedServerBalance == 0,
    ), sender: _replyTo);
  }

  /// The server acknowledged a payment. It sends no signature (bead
  /// libspiffy-pkg5): the client needs none until the server settles, and
  /// then it is handed the settlement the server broadcast
  /// (`channel_closed`). A `payment_ack` from an older server that carries
  /// one is not acted on.
  ///
  /// It acknowledges every payment up to [sequenceNumber]: each payment
  /// carries the channel's balances, so the server holding a later one
  /// holds the earlier ones' money. Each such payment of the app's is now
  /// confirmed, answering its request unless that was already told it
  /// failed.
  void _handlePaymentAck(String fromPeerId, Map<String, dynamic> payload) {
    final channelId = payload['channelId'] as String;
    final sequenceNumber = payload['sequenceNumber'] as int;
    _log.fine('Payment acknowledged for channel $channelId, sequence $sequenceNumber');
    final outbox = _outboxes[channelId];
    if (outbox != null && outbox.paymentSequence <= sequenceNumber) {
      outbox.payment = null;
      _rearm(channelId, outbox, reset: true);
    }
    _confirmUpTo(channelId, sequenceNumber);
  }

  /// Confirms the app's payments on [channelId] up to [sequence].
  void _confirmUpTo(String channelId, int sequence) {
    final waiting = _unconfirmed[channelId];
    if (waiting == null) return;
    for (final seq in waiting.keys.where((s) => s <= sequence).toList()..sort()) {
      final payment = waiting.remove(seq)!;
      payment.deadline.cancel();
      _emitEvent(coord.ChannelPaymentEvent(
        walletId: _walletFor(channelId),
        channelId: channelId,
        amountSats: payment.amountSats,
        sequence: seq,
        clientBalance: payment.clientBalance,
        serverBalance: payment.serverBalance,
        // A payment already reported failed is confirmed late, answering
        // no request.
        requestId: payment.failed ? null : payment.requestId,
      ));
    }
    if (waiting.isEmpty) _unconfirmed.remove(channelId);
  }

  /// The counterparty closes the channel.
  ///
  /// From the client it carries the client's latest payment, which the
  /// server takes first: its `payment_update` may have been lost, and the
  /// server settles with the latest payment it holds. A repeat (the client
  /// resends its close until `channel_closed` arrives) goes to the manager
  /// too, which answers a closed channel with the settlement it closed
  /// with, handed over again in [handleChannelCloseAnswered].
  void _handleChannelClose(String fromPeerId, Map<String, dynamic> payload) {
    final channelId = payload['channelId'] as String;
    final reason = payload['reason'] as String?;
    final payment = payload['payment'];
    if (_serverChannelInfo.containsKey(channelId) && payment is Map) {
      _handlePaymentUpdate(fromPeerId, Map<String, dynamic>.from(payment));
    }
    _channelManager.tell(
        CloseChannelMessage(channelId: channelId, reason: reason),
        sender: _replyTo);
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
    _stopResending(channelId);
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
    final sequence = payload['sequenceNumber'];
    if (channelId != null && sequence is int && _refusedPayment(channelId, sequence, error)) return;

    _emitEvent(coord.ErrorEvent(
      source: 'ChannelP2PAdapter',
      message: 'Channel error${channelId != null ? ' ($channelId)' : ''}: $error',
      // The counterparty refused the open this side is waiting for; while
      // the funding is sent, channel_open goes again.
      requestId: channelId == null ? null : _answering(_Request.open, channelId),
      stillSent: channelId != null && _resendingOpen(channelId),
    ));
  }

  /// The server refused the payment at [sequence] on [channelId]: it is
  /// not resent, and the app's request for it, if not yet told it failed,
  /// is answered with the refusal. False when no payment of the app's is
  /// waiting at that sequence.
  bool _refusedPayment(String channelId, int sequence, String error) {
    final outbox = _outboxes[channelId];
    if (outbox != null && outbox.paymentSequence == sequence) {
      outbox.payment = null;
      _rearm(channelId, outbox, reset: true);
    }
    final payment = _unconfirmed[channelId]?.remove(sequence);
    if (payment == null) return false;
    payment.deadline.cancel();
    if (!payment.failed) {
      _emitEvent(coord.ErrorEvent(
        walletId: _walletFor(channelId),
        source: 'ChannelP2PAdapter',
        message: 'Channel $channelId: the server refused the payment of ${payment.amountSats} sats: $error',
        requestId: payment.requestId,
      ));
    }
    return true;
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
        event is ch.FundingSentEvent ||
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
    } else if (event is ch.FundingSentEvent) {
      _onFundingSent(event);
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

  /// ARC took the client's funding: `channel_open` goes to the server, and
  /// again until it answers `channel_opened` (bead libspiffy-jark). The
  /// server opens only on a funding the network holds, and refuses until
  /// then; each `channel_open` has it look again.
  void _onFundingSent(ch.FundingSentEvent event) {
    final peers = _channelPeers[event.channelId];
    if (!_clientChannelInfo.containsKey(event.channelId) || peers == null) return;
    final open = {
      'channelId': event.channelId,
      'fundingTxId': event.fundingTxId,
      'fundingOutputIndex': event.fundingOutputIndex,
      'fundingTxHex': event.fundingTxHex,
      // The funding transaction with its ancestors and their merkle
      // proofs, for the server to SPV-validate (libspiffy-fsy).
      'fundingBeef': event.fundingBeefHex,
    };
    _sendOpen(event.channelId, peers.serverPeerId, open);
  }

  void _sendOpen(String channelId, String serverPeerId, Map<String, dynamic> open) {
    final outbox = _outboxes[channelId] ??= _Outbox(serverPeerId, _resendAfter);
    outbox.open = open;
    _emitP2PMessage(serverPeerId, 'channel_open', open);
    _rearm(channelId, outbox, reset: true);
  }

  /// The server answered the client's `channel_open`: it is sent no more.
  void _openAnswered(String channelId) {
    final outbox = _outboxes[channelId];
    if (outbox == null || outbox.open == null) return;
    outbox.open = null;
    _rearm(channelId, outbox, reset: true);
  }

  void _onChannelOpened(ch.ChannelOpenedEvent event) {
    final clientInfo = _clientChannelInfo[event.channelId];

    // The server settles by itself when the margin begins (bead
    // libspiffy-ywbk).
    final serverInfo = _serverChannelInfo[event.channelId];
    if (serverInfo != null) {
      settleBeforeLockTime(event.channelId, serverInfo.lockTimeUnix);
    }

    // The client opens on the server's channel_opened (bead libspiffy-jark).
    if (clientInfo != null) _openAnswered(event.channelId);

    // Emit coordinator event for both client and server
    _emitEvent(coord.ChannelOpenedEvent(
      walletId: _walletFor(event.channelId),
      channelId: event.channelId,
      fundingTxId: event.fundingTxId,
      fundingAmountSats: event.initialClientBalanceSats.toInt() +
          event.initialServerBalanceSats.toInt(),
      requestId: _answering(_Request.open, event.channelId),
    ));
  }

  void _onPaymentRecorded(ch.PaymentRecordedEvent event) {
    final peers = _channelPeers[event.channelId];
    if (peers == null) {
      _log.warning('No peer info for channel ${event.channelId}');
      return;
    }

    final payment = _paymentUpdate(
      channelId: event.channelId,
      amountSats: event.amountSats.toInt(),
      paymentTxHex: event.paymentTxHex,
      clientSignatureHex: event.clientSignatureHex,
      sequence: event.sequenceNumber,
      clientBalance: event.newClientBalanceSats.toInt(),
      serverBalance: event.newServerBalanceSats.toInt(),
      purpose: event.purpose,
      invoiceId: event.invoiceId,
    );
    _latestPayment[event.channelId] = payment;

    // The app's payment is answered when the server acknowledges it, not
    // when it is handed to the transport (bead overnode_v2-0o5.3.2): a
    // payment lost on the way was reported sent, and the server then
    // refused every later one. The payment of nothing a close makes was no
    // request of the app's.
    if (event.amountSats > BigInt.zero) {
      final unconfirmed = _Unconfirmed(
        requestId: _answering(_Request.pay, event.channelId),
        amountSats: event.amountSats.toInt(),
        clientBalance: event.newClientBalanceSats.toInt(),
        serverBalance: event.newServerBalanceSats.toInt(),
        deadline: Timer(_confirmWithin, () => _unconfirmedTooLong(event.channelId, event.sequenceNumber)),
      );
      (_unconfirmed[event.channelId] ??= {})[event.sequenceNumber] = unconfirmed;
      _emitEvent(coord.ChannelPaymentPendingEvent(
        walletId: _walletFor(event.channelId),
        channelId: event.channelId,
        amountSats: unconfirmed.amountSats,
        sequence: event.sequenceNumber,
        clientBalance: unconfirmed.clientBalance,
        serverBalance: unconfirmed.serverBalance,
      ));
    }

    final outbox = _outboxes[event.channelId] ??= _Outbox(peers.serverPeerId, _resendAfter);
    outbox.payment = payment;
    outbox.paymentSequence = event.sequenceNumber;
    _emitP2PMessage(peers.serverPeerId, 'payment_update', payment);
    _rearm(event.channelId, outbox, reset: true);
  }

  /// The payment at [sequence] on [channelId] has gone unacknowledged for
  /// `confirmWithin`: the app is told it failed. It is kept: the client
  /// signed it and the server may hold it, so it is still resent and goes
  /// with the close, and an acknowledgement confirms it late.
  void _unconfirmedTooLong(String channelId, int sequence) {
    final payment = _unconfirmed[channelId]?[sequence];
    if (payment == null || payment.failed) return;
    payment.failed = true;
    _emitEvent(coord.ErrorEvent(
      walletId: _walletFor(channelId),
      source: 'ChannelP2PAdapter',
      message: 'Channel $channelId: the server has not acknowledged the payment of '
          '${payment.amountSats} sats within ${_confirmWithin.inSeconds} s. It is still sent, '
          'and goes with the close.',
      requestId: payment.requestId,
      stillSent: true,
    ));
  }

  static Map<String, dynamic> _paymentUpdate({
    required String channelId,
    required int amountSats,
    required String paymentTxHex,
    required String clientSignatureHex,
    required int sequence,
    required int clientBalance,
    required int serverBalance,
    String? purpose,
    String? invoiceId,
  }) =>
      {
        'channelId': channelId,
        'amountSats': amountSats,
        'paymentTxHex': paymentTxHex,
        'clientSignatureHex': clientSignatureHex,
        'proposedSequence': sequence,
        'proposedClientBalance': clientBalance,
        'proposedServerBalance': serverBalance,
        'purpose': purpose,
        'invoiceId': invoiceId,
      };

  // ===========================================================================
  // RESENDING (bead overnode_v2-0o5.3.2)
  // ===========================================================================

  /// Arms [outbox]'s resend for [channelId], or stops it when nothing is
  /// left to send. [reset] starts the wait again from `resendAfter`.
  void _rearm(String channelId, _Outbox outbox, {bool reset = false}) {
    outbox.timer?.cancel();
    outbox.timer = null;
    if (reset) outbox.wait = _resendAfter;
    if (outbox.open == null && outbox.payment == null && outbox.close == null) {
      _outboxes.remove(channelId);
      return;
    }
    if (_disposed) return;
    outbox.timer = Timer(outbox.wait, () => _resend(channelId));
  }

  void _resend(String channelId) {
    final outbox = _outboxes[channelId];
    if (outbox == null || _disposed) return;
    final open = outbox.open;
    final payment = outbox.payment;
    final close = outbox.close;
    if (open != null && _tooLateToOpen(channelId)) {
      // The server would settle the channel as it opened it: the client's
      // refund is the way back (bead libspiffy-jark).
      outbox.open = null;
      _emitEvent(coord.ErrorEvent(
        walletId: _walletFor(channelId),
        source: 'ChannelP2PAdapter',
        message: 'Channel $channelId: the server has not opened it, and its settlement '
            'margin has begun. channel_open is sent no more; the refund returns the funding '
            'after the lock time.',
      ));
    } else if (open != null) {
      _log.fine('Channel $channelId: resending channel_open');
      _emitP2PMessage(outbox.peerId, 'channel_open', open);
    }
    // The close carries the latest payment: sending both would only make
    // the server take it twice.
    if (close != null) {
      _log.fine('Channel $channelId: resending channel_close');
      _emitP2PMessage(outbox.peerId, 'channel_close', close);
    } else if (payment != null) {
      _log.fine('Channel $channelId: resending payment_update ${outbox.paymentSequence}');
      _emitP2PMessage(outbox.peerId, 'payment_update', payment);
    }
    final doubled = outbox.wait * 2;
    outbox.wait = doubled > _resendAtMost ? _resendAtMost : doubled;
    _rearm(channelId, outbox);
  }

  /// Whether [channelId]'s settlement margin has begun: a server would
  /// settle it as soon as it opened.
  /// Whether `channel_open` for [channelId] is in the outbox.
  bool _resendingOpen(String channelId) => _outboxes[channelId]?.open != null;

  bool _tooLateToOpen(String channelId) {
    final timing = _timing;
    final lockTimeUnix = _clientChannelInfo[channelId]?.lockTimeUnix;
    if (timing == null || lockTimeUnix == null || lockTimeUnix == 0) return false;
    return DateTime.now().millisecondsSinceEpoch ~/ 1000 >= timing.settleByUnix(lockTimeUnix);
  }

  void _stopResending(String channelId) {
    final outbox = _outboxes.remove(channelId);
    outbox?.timer?.cancel();
  }

  /// The app's transport could not deliver [failed] (bead
  /// overnode_v2-0o5.3.2): a channel message still waiting for its answer
  /// is sent again after `resendAfter`, sooner than its resend would come.
  void handleSendFailed(coord.P2PSendFailed failed) {
    final channelId = failed.payload['channelId'];
    if (channelId is! String) return;
    final outbox = _outboxes[channelId];
    if (outbox == null) return;
    _log.fine('Channel $channelId: sending ${failed.messageType} to ${failed.toPeerId} failed: ${failed.error}');
    if (outbox.wait > _resendAfter) {
      outbox.timer?.cancel();
      outbox.timer = Timer(_resendAfter, () => _resend(channelId));
    }
  }

  void _onPaymentAcknowledged(ch.PaymentAcknowledgedEvent event) {
    final peers = _channelPeers[event.channelId];
    final serverInfo = _serverChannelInfo[event.channelId];

    if (serverInfo != null && peers != null) {
      // We are the server - send ack back to client
      // No signature (bead libspiffy-pkg5). With the server's half of every
      // payment, the client held a fully signed spend of every state and,
      // with no replacement on BSV and first seen winning, could broadcast
      // the one that paid the server least.
      _emitP2PMessage(peers.clientPeerId, 'payment_ack', {
        'channelId': event.channelId,
        'sequenceNumber': event.sequenceNumber,
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
    if (peers == null) return;
    if (event.initiator != 'client') {
      // The server's close: channel_closed with the settlement follows.
      _emitP2PMessage(peers.clientPeerId, 'channel_close', {
        'channelId': event.channelId,
        'reason': event.reason,
      });
      return;
    }
    // The client's close carries its latest payment, so the server settles
    // with it even if its payment_update was lost, and is resent until the
    // server's channel_closed arrives (bead overnode_v2-0o5.3.2).
    final close = {
      'channelId': event.channelId,
      'reason': event.reason,
      if (_latestPayment[event.channelId] case final payment?) 'payment': payment,
    };
    final outbox = _outboxes[event.channelId] ??= _Outbox(peers.serverPeerId, _resendAfter);
    outbox.close = close;
    _emitP2PMessage(peers.serverPeerId, 'channel_close', close);
    _rearm(event.channelId, outbox, reset: true);
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
    _settleUnconfirmed(event.channelId, event.finalServerBalanceSats.toInt());
    _cleanupChannel(event.channelId);

    _emitEvent(coord.ChannelClosedEvent(
      walletId: walletId,
      channelId: event.channelId,
      settlementTxId: event.settlementTxId,
      finalClientBalance: event.finalClientBalanceSats.toInt(),
      finalServerBalance: event.finalServerBalanceSats.toInt(),
      requestId: _answering(_Request.close, event.channelId),
    ));
  }

  /// The channel closed paying the server [finalServerBalance]: each of the
  /// app's payments still unconfirmed is confirmed if the settlement paid
  /// it, and reported failed if it did not (and was not already).
  void _settleUnconfirmed(String channelId, int finalServerBalance) {
    final waiting = _unconfirmed.remove(channelId);
    if (waiting == null) return;
    for (final seq in waiting.keys.toList()..sort()) {
      final payment = waiting[seq]!;
      payment.deadline.cancel();
      if (payment.serverBalance <= finalServerBalance) {
        _emitEvent(coord.ChannelPaymentEvent(
          walletId: _walletFor(channelId),
          channelId: channelId,
          amountSats: payment.amountSats,
          sequence: seq,
          clientBalance: payment.clientBalance,
          serverBalance: payment.serverBalance,
          requestId: payment.failed ? null : payment.requestId,
        ));
      } else if (!payment.failed) {
        _emitEvent(coord.ErrorEvent(
          walletId: _walletFor(channelId),
          source: 'ChannelP2PAdapter',
          message: 'Channel $channelId closed without the payment of ${payment.amountSats} sats: '
              'the settlement pays the server $finalServerBalance sats',
          requestId: payment.requestId,
        ));
      }
    }
  }

  // ===========================================================================
  // HIGH-LEVEL COMMAND HANDLERS
  // ===========================================================================

  /// Handle a request to open a new payment channel as client.
  void handleOpenChannel(coord.OpenChannelCommand command) =>
      _sequenced(null, () => _openChannel(command));

  /// Answered by the channel's [coord.ChannelOpenedEvent] once the server
  /// accepted it and its funding is on the network, or by an
  /// [coord.ErrorEvent] naming the request when a step fails.
  void _openChannel(coord.OpenChannelCommand command) {
    // A timestamp-derived id repeated within one millisecond (A-L1).
    final channelId = uniqueId('ch');

    _channelPeers[channelId] = PeerInfo(
      clientPeerId: _myPeerId,
      serverPeerId: command.serverPeerId,
    );
    _awaiting(_Request.open, channelId, command.requestId);

    // Asked, so a request the manager refuses (an unknown wallet, a key it
    // cannot derive) is reported; told with no sender, its answer went
    // nowhere and the app waited for a channel never requested.
    unawaited(_askManager<ChannelInitiatedResponse>(
      InitiateChannelMessage(
        channelId: channelId,
        walletId: command.walletId,
        clientPeerId: _myPeerId,
        serverPeerId: command.serverPeerId,
        fundingAmountSats: BigInt.from(command.fundingAmountSats),
        lockTimeDurationSeconds: command.lockTimeDurationSeconds,
        context: command.context,
        counterpartyMarker: command.counterpartyMarker,
      ),
    ).then((error) {
      if (error != null) _reportFailure(channelId, 'requesting the channel', error, answers: _Request.open);
    }));
  }

  /// Asks the channel manager, and resolves with why the answer is not a
  /// success, or null.
  Future<String?> _askManager<T extends ActorResponse>(Message message) async {
    try {
      final reply = await _channelManager.ask<Object>(message, _managerTimeout);
      if (reply is ActorResponse && !reply.success) return reply.error ?? 'refused';
      if (reply is! T) return 'answered with ${reply.runtimeType}';
      return null;
    } catch (e) {
      return '$e';
    }
  }

  /// Handle a request to make a payment over an open channel.
  ///
  /// Answered by the payment's [coord.ChannelPaymentEvent] once the server
  /// acknowledges it, or by an [coord.ErrorEvent] naming the request when
  /// the channel refuses it, the server refuses it, or no acknowledgement
  /// comes within `ChannelTiming.confirmWithin` (bead
  /// overnode_v2-0o5.3.2). Meanwhile [coord.ChannelPaymentPendingEvent] says
  /// it is signed and on its way, and `payment_update` is resent until it is
  /// acknowledged.
  void handleMakePayment(coord.ChannelPayCommand command) {
    _awaiting(_Request.pay, command.channelId, command.requestId);
    unawaited(_askManager<PaymentRecordedResponse>(RecordPaymentMessage(
      channelId: command.channelId,
      walletId: command.walletId,
      amountSats: BigInt.from(command.amountSats),
      purpose: command.purpose,
      invoiceId: command.invoiceId,
    )).then((error) {
      if (error == null) return;
      final message = 'Channel ${command.channelId}: the payment was refused: $error';
      _log.warning(message);
      _emitEvent(coord.ErrorEvent(
        walletId: command.walletId,
        source: 'ChannelP2PAdapter',
        message: message,
        requestId: _answering(_Request.pay, command.channelId),
      ));
    }));
  }

  /// Handle a request to close a channel.
  ///
  /// Answered by the channel's [coord.ChannelClosedEvent], or by an
  /// [coord.ErrorEvent] naming the request when the close fails.
  void handleCloseChannel(coord.CloseChannelCommand command) {
    _awaiting(_Request.close, command.channelId, command.requestId);
    _close(command.channelId, command.reason);
  }

  void _close(String channelId, String? reason) => _channelManager.tell(
      CloseChannelMessage(channelId: channelId, reason: reason),
      // A close that fails — a settlement ARC did not take — is reported
      // (bead libspiffy-u6q6); see [handleChannelCloseAnswered].
      sender: _replyTo);

  /// The manager's answer to a close, or to a settlement handed over: a
  /// failure is reported to the host, whose channel stays `closing` until
  /// it closes again (bead libspiffy-u6q6). A close that succeeded is
  /// reported by its [ch.ChannelClosedEvent].
  ///
  /// A close of a channel already closed is a repeat: on the server the
  /// client's close, resent because `channel_closed` was lost, which is
  /// handed the settlement again; on either side the app's close is
  /// answered with the channel's [coord.ChannelClosedEvent].
  void handleChannelCloseAnswered(ChannelClosedResponse response) {
    if (!response.success) {
      _reportFailure(response.channelId, 'closing the channel', response.error, answers: _Request.close);
      return;
    }
    if (!response.alreadyClosed) return;
    final channelId = response.channelId;
    _sequenced(channelId, () {
      final settlementTxHex = response.settlementTxHex;
      final clientPeerId = _serverChannelInfo.containsKey(channelId) ? _counterpartyPeer(channelId) : null;
      if (clientPeerId != null && settlementTxHex != null && settlementTxHex.isNotEmpty) {
        _emitP2PMessage(clientPeerId, 'channel_closed', {
          'channelId': channelId,
          'settlementTxId': response.settlementTxId,
          'settlementTxHex': settlementTxHex,
        });
      }
      final requestId = _answering(_Request.close, channelId);
      if (requestId != null) {
        _emitEvent(coord.ChannelClosedEvent(
          walletId: _walletFor(channelId),
          channelId: channelId,
          settlementTxId: response.settlementTxId,
          requestId: requestId,
        ));
      }
    });
  }

  /// The manager's answer to an expiry, which answers the
  /// [coord.ExpireChannelCommand]; a failure (a server whose settlement ARC
  /// did not take, bead libspiffy-u6q6) says why.
  void handleChannelExpiryAnswered(ChannelExpiredResponse response) {
    if (!response.success) {
      _log.warning('Channel ${response.channelId}: recording the expiry failed: ${response.error}');
    }
    _emitEvent(coord.ChannelExpiredEvent(
      walletId: _walletFor(response.channelId),
      channelId: response.channelId,
      success: response.success,
      error: response.error,
      requestId: _answering(_Request.expire, response.channelId),
    ));
  }

  /// Handle a request to record channel expiry (lockTime elapsed).
  void handleExpireChannel(coord.ExpireChannelCommand command) {
    _awaiting(_Request.expire, command.channelId, command.requestId);
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
    _awaiting(_Request.refund, command.channelId, command.requestId);
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
      requestId: _answering(_Request.refund, response.channelId),
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
  void handleRetryChannelFunding(coord.RetryChannelFundingCommand command) {
    _awaiting(_Request.retry, command.channelId, command.requestId);
    _sequenced(
        command.channelId,
        () => _channelManager.tell(
            RetryChannelFundingMessage(channelId: command.channelId),
            sender: _replyTo));
  }

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
  void handleResendChannelOpen(coord.ResendChannelOpenCommand command) {
    _awaiting(_Request.resend, command.channelId, command.requestId);
    _sequenced(
        command.channelId,
        () => _channelManager.tell(
            ResendChannelOpenMessage(channelId: command.channelId),
            sender: _replyTo));
  }

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

    // Asked, and answered with the manager's answer: told with no sender, a
    // refused acceptance (an unknown wallet) went nowhere.
    unawaited(_askManager<ChannelAcceptedResponse>(AcceptChannelMessage(
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
    )).then((error) => _emitEvent(coord.ChannelAcceptedEvent(
          walletId: command.walletId,
          channelId: command.channelId,
          success: error == null,
          error: error,
          requestId: command.requestId,
        ))));
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
    _emitEvent(coord.ChannelRejectedEvent(
        channelId: command.channelId, clientTold: pending != null, requestId: command.requestId));
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
          response.error, tellPeer: true, answers: _Request.open);
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
          response.error, tellPeer: true, answers: _Request.open);
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
              tellPeer: true,
              answers: _Request.open));
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
  ///
  /// A repeat — a payment the server already holds, resent because its
  /// `payment_ack` was lost — is acknowledged again, at the latest payment
  /// the server holds (bead overnode_v2-0o5.3.2).
  void handlePaymentAcknowledged(PaymentAcknowledgedResponse response) {
    if (response.success) {
      if (!response.repeat) return;
      _sequenced(response.channelId, () {
        final clientPeerId = _counterpartyPeer(response.channelId);
        if (clientPeerId == null) return;
        _emitP2PMessage(clientPeerId, 'payment_ack', {
          'channelId': response.channelId,
          'sequenceNumber': response.sequenceNumber,
        });
      });
      return;
    }
    _sequenced(
        response.channelId,
        () => _reportFailure(response.channelId,
            'acknowledging the payment', response.error,
            tellPeer: true, sequenceNumber: response.sequenceNumber));
  }

  /// The manager's answer to opening a channel: on the client a failed
  /// funding broadcast (the channel stays unopened, awaiting funding), on
  /// the server a funding transaction that was refused, or opened on, which
  /// it tells the client with `channel_opened`.
  void handleChannelOpenedResponse(ChannelOpenedResponse response) {
    if (response.success) {
      // The server opened, on this channel_open or an earlier one: the
      // client opens when it hears so (bead libspiffy-jark).
      final fundingTxId = response.fundingTxId;
      if (fundingTxId == null) return;
      _sequenced(response.channelId, () {
        if (!_serverChannelInfo.containsKey(response.channelId)) return;
        final peer = _counterpartyPeer(response.channelId);
        if (peer == null) return;
        _emitP2PMessage(peer, 'channel_opened', {
          'channelId': response.channelId,
          'fundingTxId': fundingTxId,
          'fundingOutputIndex': response.fundingOutputIndex ?? 0,
        });
      });
      return;
    }
    _sequenced(
        response.channelId,
        () => _reportFailure(
            response.channelId, 'opening the channel', response.error,
            // The server refused the funding transaction, or the client
            // could not broadcast it: either way the counterparty is
            // waiting for a channel that is not coming (libspiffy-kyw).
            tellPeer: true,
            answers: _Request.open));
  }


  /// The client's open on the server's word (bead libspiffy-jark). A
  /// failure answers the app's open; `channel_open` is still resent.
  void handleServerOpenRecorded(ServerOpenRecordedResponse response) {
    _sequenced(response.channelId, () {
      if (response.success) {
        _openAnswered(response.channelId);
        return;
      }
      _log.warning('Channel ${response.channelId}: opening on the server\'s word failed: ${response.error}');
      _emitEvent(coord.ErrorEvent(
        walletId: _walletFor(response.channelId),
        source: 'ChannelP2PAdapter',
        message: 'Channel ${response.channelId}: the server opened it, and opening it here failed: ${response.error}',
        requestId: _answering(_Request.open, response.channelId),
        stillSent: _resendingOpen(response.channelId),
      ));
    });
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
      requestId: _answering(_Request.retry, response.channelId),
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
        requestId: _answering(_Request.resend, channelId),
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

    // Resent until the server answers channel_opened (bead libspiffy-jark).
    _sendOpen(channelId, peerId, {
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
      requestId: _answering(_Request.resend, channelId),
    ));
  }

  // ===========================================================================
  // HELPERS
  // ===========================================================================

  void _emitP2PMessage(String targetPeerId, String messageType, Map<String, dynamic> payload) {
    _emitEvent(coord.P2PMessageToSendEvent(
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
  ///
  /// [answers] is the kind of app request the failed step ends, if one is
  /// waiting for this channel: the error then carries its id.
  ///
  /// [sequenceNumber] names the payment the failure is about, for the
  /// client to match the `channel_error` to it.
  void _reportFailure(String channelId, String step, String? error,
      {bool tellPeer = false, _Request? answers, int? sequenceNumber}) {
    final message =
        'Channel $channelId: $step failed: ${error ?? 'unknown error'}';
    _log.warning(message);
    _emitEvent(coord.ErrorEvent(
      walletId: _walletFor(channelId),
      source: 'ChannelP2PAdapter',
      message: message,
      requestId: answers == null ? null : _answering(answers, channelId),
    ));
    if (tellPeer) _tellPeerChannelError(channelId, message, sequenceNumber: sequenceNumber);
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
  void _tellPeerChannelError(String channelId, String message, {int? sequenceNumber}) {
    final peer = _counterpartyPeer(channelId);
    if (peer == null) {
      _log.warning(
          'Channel $channelId: no counterparty to tell that it failed');
      return;
    }
    _emitP2PMessage(peer, 'channel_error', {
      'channelId': channelId,
      'error': message,
      if (sequenceNumber != null && sequenceNumber > 0) 'sequenceNumber': sequenceNumber,
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
    _settlements.remove(channelId)?.cancel();
    _stopResending(channelId);
    _latestPayment.remove(channelId);
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

/// What an app's channel request asks, for matching its answer to it.
enum _Request { open, pay, close, expire, refund, retry, resend }

/// What a client channel still has to get to its server.
class _Outbox {
  final String peerId;

  /// `channel_open`, until the server answers `channel_opened` (bead
  /// libspiffy-jark).
  Map<String, dynamic>? open;

  /// The latest payment not yet acknowledged, as `payment_update` sends it.
  Map<String, dynamic>? payment;
  int paymentSequence = 0;

  /// The close, until `channel_closed` arrives.
  Map<String, dynamic>? close;

  Duration wait;
  Timer? timer;

  _Outbox(this.peerId, this.wait);
}

/// An app's payment the server has not acknowledged yet.
class _Unconfirmed {
  final String? requestId;
  final int amountSats;
  final int clientBalance;
  final int serverBalance;
  final Timer deadline;

  /// Already reported failed: a later acknowledgement answers no request.
  bool failed = false;

  _Unconfirmed({
    required this.requestId,
    required this.amountSats,
    required this.clientBalance,
    required this.serverBalance,
    required this.deadline,
  });
}

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
