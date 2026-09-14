import 'dart:async';

import 'package:dactor/dactor.dart';
import 'package:logging/logging.dart';

import '../core/channel_events.dart' as ch;
import '../core/wallet_commands.dart';
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

  ChannelP2PAdapter({
    required ActorRef channelManager,
    required ActorRef walletManager,
    required void Function(coord.CoordinatorEvent) emitEvent,
    required Stream<ch.ChannelEvent> channelEvents,
    required String walletId,
    required String myPeerId,
  })  : _channelManager = channelManager,
        _walletManager = walletManager,
        _emitEvent = emitEvent,
        _walletId = walletId,
        _myPeerId = myPeerId {
    _eventSubscription = channelEvents.listen(_handleEvent);
  }

  /// Wallet manager that routes wallet commands to the owning aggregate.
  final ActorRef _walletManager;

  /// Actor that receives wallet command responses on the adapter's behalf
  /// (the coordinator that owns this adapter); set once its context exists.
  ActorRef? _replyTo;

  void updateWalletId(String walletId) => _walletId = walletId;
  void updatePeerId(String peerId) => _myPeerId = peerId;
  void updateReplyTo(ActorRef replyTo) => _replyTo = replyTo;

  void dispose() {
    _eventSubscription?.cancel();
  }

  // ===========================================================================
  // P2P MESSAGE HANDLING (incoming from peer)
  // ===========================================================================

  /// Handle an incoming P2P message from a peer.
  void handleP2PMessage(String fromPeerId, String messageType, Map<String, dynamic> payload) {
    _log.fine('Received P2P message: $messageType from $fromPeerId');

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

    // BuildFundingTransactionCommand is a wallet command: only the wallet
    // aggregate handles it, reached through the wallet manager. It used to
    // be told to the channel manager, which has no case for it and dropped
    // it, so the client side never progressed past channel_accept. The
    // FundingTransactionBuiltResponse comes back to the coordinator, which
    // forwards it to handleFundingTransactionBuilt.
    //
    // The channel's own wallet funds it, not the adapter's last-created
    // wallet: that is '' after a restart and another wallet once a second
    // one is created (libspiffy-9fo).
    _walletManager.tell(
      WalletCommandMessage(
        clientInfo.walletId,
        BuildFundingTransactionCommand(
          walletId: clientInfo.walletId,
          correlationId: channelId,
          channelId: channelId,
          clientPubKeyHex: clientInfo.clientPubKeyHex,
          serverPubKeyHex: serverPubKey,
          fundingAmountSats: clientInfo.fundingAmountSats,
          changeAddressBase58: clientInfo.clientAddressB58,
          derivationIndex: clientInfo.clientDerivationIndex,
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
      // The accepting wallet's key signs (libspiffy-9fo).
      walletId: serverInfo.walletId,
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
    // amount in the channel 2-of-2 is refused and reported (libspiffy-9f7).
    _channelManager.tell(OpenChannelMessage(
      channelId: channelId,
      fundingTxId: fundingTxId,
      fundingOutputIndex: fundingOutputIndex,
      fundingTxHex: fundingTxHex,
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

    _channelManager.tell(AcknowledgePaymentMessage(
      channelId: channelId,
      walletId: _walletFor(channelId),
      amountSats: BigInt.from(amountSats),
      paymentTxHex: paymentTxHex,
      clientSignatureHex: clientSignatureHex,
      proposedSequence: proposedSequence,
      proposedClientBalance: BigInt.from(proposedClientBalance),
      proposedServerBalance: BigInt.from(proposedServerBalance),
    ));
  }

  void _handlePaymentAck(String fromPeerId, Map<String, dynamic> payload) {
    final channelId = payload['channelId'] as String;
    final sequenceNumber = payload['sequenceNumber'] as int;
    _log.fine('Payment acknowledged for channel $channelId, sequence $sequenceNumber');
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

  void _handleChannelClosed(String fromPeerId, Map<String, dynamic> payload) {
    final channelId = payload['channelId'] as String;
    final settlementTxId = payload['settlementTxId'] as String?;
    final walletId = _walletFor(channelId);

    _cleanupChannel(channelId);

    _emitEvent(coord.ChannelClosedEvent(
      walletId: walletId,
      channelId: channelId,
      settlementTxId: settlementTxId,
    ));
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

    final peers = _channelPeers[event.channelId];
    if (peers == null) {
      _log.warning('No peer info for channel ${event.channelId}');
      return;
    }

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
    final peers = _channelPeers[event.channelId];
    if (peers != null) {
      final serverInfo = _serverChannelInfo[event.channelId];
      final clientInfo = _clientChannelInfo[event.channelId];
      final targetPeerId = clientInfo != null
          ? peers.serverPeerId
          : serverInfo?.clientPeerId;

      if (targetPeerId != null) {
        _emitP2PMessage(targetPeerId, 'channel_closed', {
          'channelId': event.channelId,
          'settlementTxId': event.settlementTxId,
        });
      }
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
  void handleOpenChannel(coord.OpenChannelCommand command) {
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
    _channelManager.tell(CloseChannelMessage(
      channelId: command.channelId,
      reason: command.reason,
    ));
  }

  /// Handle a request to record channel expiry (lockTime elapsed).
  void handleExpireChannel(coord.ExpireChannelCommand command) {
    _channelManager.tell(ExpireChannelMessage(
      channelId: command.channelId,
      observedBy: command.observedBy,
      settlementOrRefundTxId: command.settlementOrRefundTxId,
    ));
  }

  /// Handle acceptance of an incoming channel request (we are server).
  void handleAcceptRequest(coord.AcceptChannelCommand command) {
    final pending = _pendingRequests.remove(command.channelId);
    if (pending == null) {
      _log.warning('No pending request for channel ${command.channelId}');
      return;
    }

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
    ));
  }

  /// Handle rejection of an incoming channel request.
  void handleRejectRequest(coord.RejectChannelCommand command) {
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
  void handleFundingTransactionBuilt(FundingTransactionBuiltResponse response) {
    final channelId = response.channelId;
    final clientInfo = _clientChannelInfo[channelId];

    if (clientInfo == null) {
      _log.warning('No client info for channel $channelId');
      return;
    }

    // A failed build has no funding transaction to refund (libspiffy-lhd).
    if (!response.success) {
      _reportFailure(channelId, 'building the funding transaction', response.error);
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
  void handleRefundTransactionBuilt(RefundTransactionBuiltResponse response) {
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
      _reportFailure(channelId, 'building the refund transaction', response.error);
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
      _reportFailure(response.channelId,
          'recording the server refund signature', response.error);
    }
  }

  /// The manager's answer to opening a channel: on the client a failed
  /// funding broadcast (the channel stays unopened, awaiting funding), on
  /// the server a funding transaction that was refused.
  void handleChannelOpenedResponse(ChannelOpenedResponse response) {
    if (!response.success) {
      _reportFailure(response.channelId, 'opening the channel', response.error);
    }
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
  void _reportFailure(String channelId, String step, String? error) {
    final message =
        'Channel $channelId: $step failed: ${error ?? 'unknown error'}';
    _log.warning(message);
    _emitEvent(coord.ErrorEvent(
      walletId: _walletFor(channelId),
      source: 'ChannelP2PAdapter',
      message: message,
    ));
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
