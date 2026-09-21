import 'dart:async';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:dactor/dactor.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:eventador/eventador.dart';
import 'package:logging/logging.dart';
import 'package:spiffynode/spiffy_node.dart' show BlockHeader, Hash;

import '../core/channel_events.dart';
import '../core/wallet_commands.dart' as domain;
import '../core/wallet_events.dart' as domain_events;
import '../core/wallet/transaction_size.dart';
import '../models/wallet_event.dart' as wallet_event_model;
import '../models/bitcoin_transaction.dart';
import '../models/bitcoin_utxo.dart';
import '../models/invoice_output_spec.dart';
import '../models/payment_channel.dart' show PaymentChannelRole, PaymentChannelState;
import '../models/wallet_balances.dart' show BalanceBucket, WalletBalances;
import '../services/ancestor_chain_service.dart';
import '../services/watch_only_funds.dart';
import '../storage/read_model_storage.dart';
import '../utils/beef.dart';
import 'aggregate_signing_client.dart';
import 'channel_p2p_adapter.dart';
import 'coordinator_messages.dart';
import 'proof_p2p_adapter.dart';
import 'invoice_messages.dart' as inv;
import 'payment_messages.dart' as pay;
import 'wallet_messages.dart' as wm;
import 'payment_channel_messages.dart' as ch;

/// The canonical public interface for third-party apps using LibSpiffy.
///
/// Receives coordinator commands, delegates to internal actors, tracks
/// correlations, and emits events on a broadcast stream.
///
/// Apps interact with LibSpiffy exclusively through this actor:
/// - Send commands via `coordinator.tell(CreateWalletCommand(...))`
/// - Subscribe to events via `libspiffy.coordinatorEvents.listen(...)`
class WalletCoordinatorActor extends Actor {
  static final _log = Logger('WalletCoordinatorActor');

  // Internal actor refs
  final ActorRef _walletManager;
  final ActorRef _invoiceCoordinator;
  final ActorRef _paymentCoordinator;
  final ActorRef _spvActor;
  final ActorRef _arcActor;
  final ActorRef _walletProjection;

  // Direct storage access for CQRS read queries
  final ReadModelStorage _storage;

  // Channel P2P adapter (composed, not a separate actor)
  ChannelP2PAdapter? _channelAdapter;

  /// Merkle-proof request/response over the app's transport (bead
  /// libspiffy-a2v3). Composed like the channel adapter, but always present:
  /// it needs nothing but storage and the SPV actor.
  late final ProofP2PAdapter _proofAdapter;

  // Event broadcasting
  late final StreamController<CoordinatorEvent> _eventStream =
      StreamController<CoordinatorEvent>.broadcast(onListen: _flushStartupEvents);

  /// Events emitted before anything was listening, kept for the first
  /// listener (bead libspiffy-4gy8).
  ///
  /// [events] is a broadcast stream, so an event emitted with no listener is
  /// dropped. Two of the things this coordinator reports happen at STARTUP,
  /// from [preStart] -- the channels that never finished opening
  /// (libspiffy-29jd) and the receives replayed because their block headers
  /// arrived while the node was down (libspiffy-4gy8) -- and an app using
  /// `LibSpiffyActorSystem` can only reach this stream after `initialize()`
  /// returns. So whether a startup report arrived depended on how quickly
  /// the app got to `.listen`, which is not a guarantee to build a wallet
  /// on: a credited receive nobody was told about is found only by polling
  /// the read model, which is the defect this whole bead is about.
  ///
  /// Null once anything has listened: this is a startup window, not a replay
  /// log, and events after it behave exactly as before.
  List<CoordinatorEvent>? _beforeFirstListener = [];

  /// The most startup events kept. Beyond this the oldest are dropped with a
  /// warning rather than growing without bound while nobody listens.
  static const int _maxBufferedStartupEvents = 256;

  void _flushStartupEvents() {
    final buffered = _beforeFirstListener;
    _beforeFirstListener = null;
    if (buffered == null || buffered.isEmpty) return;
    // Not inside onListen: the subscription is not set up yet.
    scheduleMicrotask(() {
      for (final event in buffered) {
        if (_eventStream.isClosed) return;
        _eventStream.add(event);
      }
    });
  }

  // Correlation maps (absorbed from Overnode's WalletCoordinatorActor)

  /// In-flight structural BEEF validations, keyed by the per-request id sent
  /// as [wm.ValidateBEEFMessage.requestId] and echoed by SPVActor. Keying by
  /// walletId (as before) let two validations for one wallet overwrite each
  /// other (A-M1).
  final Map<String, _PendingBeefValidation> _beefValidations = {};
  int _beefRequestSeq = 0;

  /// The receives this coordinator asked SPVActor for, by the requestId it
  /// sent and SPVActor echoes (bead libspiffy-xggs): a payment
  /// ([ValidateBEEFCommand]) or an import. This used to be keyed by txid, as
  /// a FIFO of payments only, and a payment parked for a header lost its
  /// entry to the first reply, which is not a verdict.
  final Map<String, _Receive> _receives = {};
  int _receiveSeq = 0;

  /// How long a received payment's submission waits for ARC's answer.
  static const _paymentSubmitTimeout = Duration(minutes: 2);
  final Map<String, String> _paymentInvoiceCorrelation = {}; // invoiceId → walletId
  final Map<String, String> _timestampCorrelation = {}; // invoiceId → archiveId
  final Map<String, CreateWalletCommand> _pendingCreateWallet = {}; // walletId → original cmd
  final Map<String, StreamSubscription> _eventSubscriptions = {}; // walletId → subscription

  // BEEF settlement correlation — tracks in-flight SettleBEEFCommand operations
  // so we can aggregate per-tx BroadcastSuccess/Failed responses from ARCActor
  // before emitting BEEFSettledEvent. See SettleBEEFCommand handler.
  final Map<String, _PendingSettlement> _pendingSettlements = {}; // parentTxid → entry
  final Map<String, String> _childToParentSettlement = {}; // childTxid → parentTxid

  // Import wallet functionality
  final dynamic Function({
    required String walletId,
    required String xpriv,
    required String walletName,
    String networkType,
    int addressGapLimit,
  })? _importWalletFromXpriv;
  final dynamic Function({
    required String walletId,
    required String wif,
    required String walletName,
    String networkType,
  })? _importWalletFromWif;

  // Import notifications (ImportActor progress), forwarded as CoordinatorEvents
  final Stream<domain_events.WalletImportNotification>? _importNotifications;

  WalletCoordinatorActor({
    required ActorRef walletManager,
    required ActorRef invoiceCoordinator,
    required ActorRef paymentCoordinator,
    required ActorRef spvActor,
    required ActorRef arcActor,
    @Deprecated('Unused: the coordinator never sends the header-sync actor a '
        'message. Kept so existing callers still compile; will be removed in '
        'a future release.')
    required ActorRef headerSyncActor,
    @Deprecated('Unused: UTXO splitting is driven through WalletManager, not '
        'from here. Kept so existing callers still compile; will be removed '
        'in a future release.')
    required ActorRef benfordCoordinator,
    required ActorRef channelManager,
    required ActorRef walletProjection,
    @Deprecated('Unused: import progress arrives on importNotifications, and '
        'imports run through importWalletFromXpriv/importWalletFromWif. Kept '
        'so existing callers still compile; will be removed in a future '
        'release.')
    ActorRef? importActor,
    required ReadModelStorage storage,
    Stream<ChannelEvent>? channelEvents,
    String peerId = '',
    /// Unused; accepted for compatibility with existing callers.
    void Function(wallet_event_model.WalletEvent)? broadcastWalletEvent,
    dynamic Function({
      required String walletId,
      required String xpriv,
      required String walletName,
      String networkType,
      int addressGapLimit,
    })?
        importWalletFromXpriv,
    dynamic Function({
      required String walletId,
      required String wif,
      required String walletName,
      String networkType,
    })?
        importWalletFromWif,
    Stream<domain_events.WalletImportNotification>? importNotifications,
  })  : _walletManager = walletManager,
        _invoiceCoordinator = invoiceCoordinator,
        _paymentCoordinator = paymentCoordinator,
        _spvActor = spvActor,
        _arcActor = arcActor,
        _walletProjection = walletProjection,
        _storage = storage,
        _importWalletFromXpriv = importWalletFromXpriv,
        _importWalletFromWif = importWalletFromWif,
        _importNotifications = importNotifications {
    _proofAdapter = ProofP2PAdapter(
      storage: storage,
      spvActor: spvActor,
      emitEvent: _emitEvent,
    );
    // Initialize channel P2P adapter if channel events stream provided
    if (channelEvents != null) {
      _channelAdapter = ChannelP2PAdapter(
        channelManager: channelManager,
        walletManager: walletManager,
        emitEvent: _emitEvent,
        channelEvents: channelEvents,
        walletId: '',
        myPeerId: peerId,
      );
    }
  }

  /// Get the coordinator's event stream
  Stream<CoordinatorEvent> get events => _eventStream.stream;

  void _emitEvent(CoordinatorEvent event) {
    if (_eventStream.isClosed) return;
    final buffered = _beforeFirstListener;
    if (buffered != null) {
      if (buffered.length >= _maxBufferedStartupEvents) {
        _log.warning('More than $_maxBufferedStartupEvents coordinator events '
            'were emitted before anything listened to the event stream; the '
            'oldest is dropped. Listen to `coordinatorEvents` as soon as the '
            'actor system is initialized');
        buffered.removeAt(0);
      }
      buffered.add(event);
      return;
    }
    _eventStream.add(event);
  }

  @override
  void preStart() {
    // The adapter is built in the constructor, before this actor has a
    // context; wallet command replies it triggers must come back here.
    _channelAdapter?.updateReplyTo(context.self);
    _proofAdapter.updateReplyTo(context.self);
    // A receive parked for a block header outlives the process that took it,
    // so a replay has no caller to answer: SPVActor answers this coordinator
    // instead, and the app hears about funds it would otherwise find only by
    // polling the read model. Registering is also what replays the receives
    // whose headers arrived while the node was down -- SPVActor's own
    // preStart ran before this actor existed, so doing it there credited the
    // wallet silently (bead libspiffy-4gy8).
    _spvActor.tell(wm.SetCoordinatorForSPVMessage(context.self));
    // Off the mailbox: it only reads the read model and emits, so it must
    // not delay the actor becoming able to serve commands.
    unawaited(_reportUnfinishedChannels());
  }

  /// Tells the app, once at startup, about channels that started opening and
  /// never reached `open` (bead libspiffy-29jd).
  ///
  /// Restart recovery is otherwise reactive — the channel adapter rebuilds a
  /// record when an inbound stimulus names a channel — and a channel whose
  /// funding failed or whose `channel_open` was lost is exactly the case
  /// where the counterparty has gone silent, so nothing ever arrives to
  /// trigger it.
  ///
  /// **Reports only.** Nothing is retried, nothing is journaled: a funding
  /// broadcast whose outcome was lost may already be in a mempool, and BSV
  /// is first-seen-wins, so re-driving channels on startup would be the
  /// library deciding policy. Failures here are logged and swallowed — a
  /// report that cannot be made must not stop the coordinator starting.
  Future<void> _reportUnfinishedChannels() async {
    try {
      for (final walletId in await _storage.listWallets()) {
        final unfinished = [
          for (final channel in await _storage.getPaymentChannelsForWallet(walletId))
            if (_isUnfinished(channel.state))
              UnfinishedChannel(
                channelId: channel.channelId,
                state: channel.state.name,
                fundingAmountSats: channel.fundingAmountSats,
                lockTimeUnix: channel.lockTimeUnix,
                counterpartyPeerId: channel.role == PaymentChannelRole.client
                    ? channel.serverPeerId
                    : channel.clientPeerId,
              ),
        ];
        if (unfinished.isEmpty) continue;
        _log.info('Wallet $walletId has ${unfinished.length} channel(s) that '
            'never finished opening: ${unfinished.map((c) => c.channelId).join(', ')}. '
            'Reported, not retried.');
        _emitEvent(UnfinishedChannelsFoundEvent(
          walletId: walletId,
          channels: unfinished,
        ));
      }
    } catch (e, stackTrace) {
      _log.warning('Could not look for unfinished channels at startup: $e',
          e, stackTrace);
    }
  }

  /// Whether [state] is a channel that started opening and has not reached
  /// `open`. `open` is not unfinished, and the terminal states
  /// (`closed`, `closing`, `expired`, `failed`) have nothing to resume.
  static bool _isUnfinished(PaymentChannelState state) =>
      state == PaymentChannelState.negotiating ||
      state == PaymentChannelState.opening ||
      state == PaymentChannelState.funding;

  /// Release subscriptions, timers and the event stream when the actor is
  /// stopped without a [ShutdownCommand] (e.g. LibSpiffyActorSystem.shutdown
  /// in a host-owned actor system).
  @override
  void postStop() {
    for (final sub in _eventSubscriptions.values) {
      unawaited(sub.cancel());
    }
    _eventSubscriptions.clear();
    for (final entry in _pendingSettlements.values) {
      entry.timeout?.cancel();
    }
    _pendingSettlements.clear();
    _childToParentSettlement.clear();
    _channelAdapter?.dispose();
    _proofAdapter.dispose();
    if (!_eventStream.isClosed) {
      unawaited(_eventStream.close());
    }
  }

  @override
  Future<void> onMessage(dynamic message) async {
    try {
      // === COMMANDS FROM APP ===
      if (message is CreateWalletCommand) {
        await _handleCreateWallet(message);
      } else if (message is DeleteWalletCommand) {
        await _handleDeleteWallet(message);
      } else if (message is ImportWalletCommand) {
        await _handleImportWallet(message);
      } else if (message is GetBalanceQuery) {
        await _handleGetBalance(message);
      } else if (message is GetTransactionsQuery) {
        await _handleGetTransactions(message);
      } else if (message is GetTransactionDetailQuery) {
        await _handleGetTransactionDetail(message);
      } else if (message is CreateInvoiceCommand) {
        await _handleCreateInvoice(message);
      } else if (message is PayInvoiceCommand) {
        await _handlePayInvoice(message);
      } else if (message is ValidateBEEFCommand) {
        await _handleValidateBEEF(message);
      } else if (message is RecordOutgoingCommand) {
        await _handleRecordOutgoing(message);
      } else if (message is ImportTransactionCommand) {
        await _handleImportTransaction(message);
      } else if (message is StoreHeadersCommand) {
        await _handleStoreHeaders(message);
      } else if (message is RegisterWatchAddressCommand) {
        unawaited(_handleRegisterWatchAddress(message)); // off the mailbox: wallet and projection round trips
      } else if (message is ReleaseUTXOsCommand) {
        await _handleReleaseUTXOs(message);
      } else if (message is SplitUTXOsCommand) {
        await _handleSplitUTXOs(message);
      } else if (message is ProvisionFundingCommand) {
        await _handleProvisionFunding(message);
      } else if (message is TimestampCommand) {
        await _handleTimestamp(message);
      } else if (message is SettleBEEFCommand) {
        await _handleSettleBEEF(message);
      } else if (message is RefreshWalletCommand) {
        await _handleRefreshWallet(message);
      }
      // Deferred payments (bead libspiffy-7p2): answered off the mailbox
      // (storage reads, BEEF rebuilds, network round trips).
      else if (message is GetDeferredPaymentsQuery) {
        unawaited(_handleGetDeferredPayments(message));
      } else if (message is BroadcastDeferredPaymentCommand) {
        unawaited(_handleBroadcastDeferredPayment(message));
      } else if (message is CheckDeferredPaymentStatusCommand) {
        unawaited(_handleCheckDeferredPaymentStatus(message));
      } else if (message is CancelDeferredPaymentCommand) {
        unawaited(_handleCancelDeferredPayment(message));
      } else if (message is ReclaimDeferredPaymentCommand) {
        unawaited(_handleReclaimDeferredPayment(message));
      } else if (message is ShutdownCommand) {
        await _handleShutdown();
      }
      // Channel commands
      else if (message is OpenChannelCommand) {
        _channelAdapter?.handleOpenChannel(message);
      } else if (message is ChannelPayCommand) {
        _channelAdapter?.handleMakePayment(message);
      } else if (message is CloseChannelCommand) {
        _channelAdapter?.handleCloseChannel(message);
      } else if (message is ExpireChannelCommand) {
        _channelAdapter?.handleExpireChannel(message);
      } else if (message is ClaimChannelRefundCommand) {
        _channelAdapter?.handleClaimRefund(message);
      } else if (message is RetryChannelFundingCommand) {
        _channelAdapter?.handleRetryChannelFunding(message);
      } else if (message is ResendChannelOpenCommand) {
        _channelAdapter?.handleResendChannelOpen(message);
      } else if (message is AcceptChannelCommand) {
        _channelAdapter?.handleAcceptRequest(message);
      } else if (message is RejectChannelCommand) {
        _channelAdapter?.handleRejectRequest(message);
      }
      // Inbound P2P, routed by message type (bead libspiffy-a2v3).
      // ChannelP2PReceived is a P2PMessageReceived, so an app that already
      // wraps everything its transport delivers in the channel-named class
      // reaches the proof protocol too. Proof work is storage reads, a BEEF
      // rebuild and a receive round trip, so it goes off the mailbox.
      else if (message is P2PMessageReceived) {
        if (ProofP2PAdapter.handles(message.messageType)) {
          unawaited(_proofAdapter.handleP2PMessage(
              message.fromPeerId, message.messageType, message.payload));
        } else {
          _channelAdapter?.handleP2PMessage(
              message.fromPeerId, message.messageType, message.payload);
        }
      } else if (message is RequestAncestorProofCommand) {
        unawaited(_proofAdapter.handleRequestProof(message));
      }
      // === RESPONSES FROM INTERNAL ACTORS ===
      else if (message is wm.WalletCreatedMessage) {
        _handleWalletCreatedResponse(message);
      } else if (message is wm.WalletCreatedResponse) {
        _handleWalletCreatedResponseAlt(message);
      } else if (message is inv.InvoiceCreatedMessage) {
        _handleInvoiceCreatedResponse(message);
      } else if (message is inv.InvoiceDetailsResponse) {
        _handleInvoiceDetailsResponse(message);
      } else if (message is pay.BEEFPaymentResponse) {
        await _handleBEEFPaymentResponse(message);
      } else if (message is wm.BEEFValidationResult) {
        await _handleBEEFValidationResult(message);
      } else if (message is wm.SPVValidationResult) {
        _handleSPVValidationResult(message);
      } else if (message is wm.SplitUTXOsResponse) {
        _handleSplitUTXOsResponse(message);
      } else if (message is wm.TransactionRecordedResponse) {
        // Off the mailbox: the announcement waits for the projection.
        unawaited(_handleTransactionRecorded(message));
      } else if (message is pay.ProvisionFundingResponse) {
        _handleProvisionFundingResponse(message);
      } else if (message is wm.FundingTransactionBuiltResponse) {
        _channelAdapter?.handleFundingTransactionBuilt(message);
      } else if (message is ch.RefundTransactionBuiltResponse) {
        _channelAdapter?.handleRefundTransactionBuilt(message);
      } else if (message is ch.RefundSignatureRecordedResponse) {
        _channelAdapter?.handleRefundSignatureRecorded(message);
      } else if (message is ch.ChannelOpenedResponse) {
        _channelAdapter?.handleChannelOpenedResponse(message);
      } else if (message is ch.PaymentAcknowledgedResponse) {
        _channelAdapter?.handlePaymentAcknowledged(message);
      } else if (message is ch.ChannelRefundClaimedResponse) {
        _channelAdapter?.handleChannelRefundClaimed(message);
      } else if (message is ch.ChannelFundingRetriedResponse) {
        _channelAdapter?.handleChannelFundingRetried(message);
      } else if (message is ch.ChannelOpenResentResponse) {
        _channelAdapter?.handleChannelOpenResent(message);
      } else if (message is wm.BroadcastSuccessMessage) {
        // Route to settlement tracking if this txid belongs to an in-flight
        // SettleBEEFCommand; otherwise ignore (e.g., retries from duraq).
        final parentTxid = _childToParentSettlement[message.txid];
        if (parentTxid != null) {
          final entry = _pendingSettlements[parentTxid];
          if (entry != null) {
            entry.pending.remove(message.txid);
            _completeSettlementIfDone(parentTxid);
          }
        }
      } else if (message is wm.BroadcastFailedMessage) {
        _log.warning('Broadcast failed for ${message.txid}: ${message.error}');
        // Route to settlement tracking if this txid belongs to an in-flight
        // SettleBEEFCommand; otherwise emit the generic failure event as
        // before (preserves behavior for duraq retries and any direct
        // callers of BroadcastTransactionMessage outside the settle path).
        final parentTxid = _childToParentSettlement[message.txid];
        if (parentTxid != null) {
          final entry = _pendingSettlements[parentTxid];
          if (entry != null) {
            entry.failures[message.txid] = message.error;
            entry.pending.remove(message.txid);
            _completeSettlementIfDone(parentTxid);
            return;
          }
        }
        _emitEvent(BroadcastFailureEvent(
          txid: message.txid,
          error: message.error,
          willRetry: true,
        ));
      }
      // === THE WALLET COULD NOT ANSWER ===
      // WalletManagerActor and the wallet aggregate report a failure they
      // have no reply of their own for as a FailureResponse. Before this
      // arm existed those replies were bare maps that fell through to
      // "Unhandled message type" below, so a delete, a recording, a
      // release or a split that the wallet refused left the app waiting
      // for an answer that never came (bead libspiffy-kl4i).
      else if (message is wm.FailureResponse) {
        _handleWalletFailure(message);
      } else {
        _log.fine('Unhandled message type: ${message.runtimeType}');
      }
    } catch (e, stackTrace) {
      _log.severe('Error handling message: $e', e, stackTrace);
      _emitEvent(ErrorEvent(
        source: 'WalletCoordinatorActor',
        message: e.toString(),
        stackTrace: stackTrace.toString(),
      ));
    }
  }

  // ==========================================================================
  // COMMAND HANDLERS
  // ==========================================================================

  Future<void> _handleCreateWallet(CreateWalletCommand cmd) async {
    _log.info('Creating wallet ${cmd.walletId}');
    _pendingCreateWallet[cmd.walletId] = cmd;

    _walletManager.tell(
      wm.CreateWalletMessage(
        cmd.walletId,
        cmd.name,
        mnemonic: cmd.mnemonic,
        wif: cmd.wif,
        xpriv: cmd.xpriv,
        xpub: cmd.xpub,
        walletMetadata: cmd.walletMetadata,
      ),
      sender: context.self,
    );
  }

  Future<void> _handleDeleteWallet(DeleteWalletCommand cmd) async {
    _log.info('Deleting wallet ${cmd.walletId}');
    final deleteCommand = domain.DeleteWalletCommand(
      walletId: cmd.walletId,
      reason: cmd.reason,
    );
    _walletManager.tell(
      wm.WalletCommandMessage(cmd.walletId, deleteCommand),
      sender: context.self,
    );
  }

  Future<void> _handleImportWallet(ImportWalletCommand cmd) async {
    _log.info('Importing wallet ${cmd.walletId}');

    try {
      // Subscribe to import notifications for progress/completion forwarding
      if (_importNotifications != null) {
        _eventSubscriptions[cmd.walletId] = _importNotifications!
            .where((e) => e.walletId == cmd.walletId)
            .listen((event) {
          if (event is domain_events.WalletImportProgressEvent) {
            _emitEvent(ImportProgressEvent(
              walletId: cmd.walletId,
              phase: event.phase,
              progress: event.progress,
              message: event.message,
              addressesFound: event.addressesFound,
              totalAddresses: event.totalAddresses,
              transactionsProcessed: event.transactionsProcessed,
              totalTransactions: event.totalTransactions,
            ));
          } else if (event is domain_events.WalletImportCompletedEvent) {
            _eventSubscriptions.remove(cmd.walletId)?.cancel();
            _emitEvent(ImportCompleteEvent(
              walletId: cmd.walletId,
              success: true,
              addressCount: event.totalAddresses,
              transactionCount: event.totalTransactions,
            ));
          } else if (event is domain_events.WalletImportFailedEvent) {
            _eventSubscriptions.remove(cmd.walletId)?.cancel();
            _emitEvent(ImportCompleteEvent(
              walletId: cmd.walletId,
              success: false,
              error: event.error,
            ));
          } else if (event is domain_events.WalletImportUTXOConfirmedEvent) {
            _emitEvent(ImportUTXOConfirmedEvent(
              walletId: cmd.walletId,
              txid: event.txid,
              vout: event.vout,
              success: event.success,
              error: event.error,
            ));
          } else if (event is domain_events.WalletImportTransactionConfirmedEvent) {
            _emitEvent(ImportTransactionConfirmedEvent(
              walletId: cmd.walletId,
              txid: event.txid,
              success: event.success,
              error: event.error,
            ));
          }
        });
      }

      if (cmd.xpriv != null && _importWalletFromXpriv != null) {
        _importWalletFromXpriv!(
          walletId: cmd.walletId,
          xpriv: cmd.xpriv!,
          walletName: cmd.walletName,
          networkType: cmd.networkType,
          addressGapLimit: cmd.gapLimit,
        );
      } else if (cmd.wif != null && _importWalletFromWif != null) {
        _importWalletFromWif!(
          walletId: cmd.walletId,
          wif: cmd.wif!,
          walletName: cmd.walletName,
          networkType: cmd.networkType,
        );
      } else if (cmd.mnemonic != null) {
        // For mnemonic import, create wallet with mnemonic
        _walletManager.tell(
          wm.CreateWalletMessage(
            cmd.walletId,
            cmd.walletName,
            mnemonic: cmd.mnemonic,
          ),
          sender: context.self,
        );
      } else {
        _emitEvent(ErrorEvent(
          walletId: cmd.walletId,
          source: 'import',
          message: 'No import key provided (xpriv, wif, or mnemonic required)',
        ));
      }
    } catch (e) {
      _emitEvent(ImportCompleteEvent(
        walletId: cmd.walletId,
        success: false,
        error: e.toString(),
      ));
    }
  }

  Future<void> _handleGetBalance(GetBalanceQuery query) async {
    try {
      // The wallet's own unspent funds: UTXOs at watch addresses are
      // reported apart, as watch-only (bead libspiffy-87a2); a bare multisig
      // UTXO the wallet cannot spend alone counts nowhere (bead
      // libspiffy-0k8). The same split as ReadModelStorage.getBalance.
      //
      // Reserved UTXOs are read here too (bead libspiffy-a5h8). They are the
      // wallet's money, committed rather than gone — an in-flight payment's
      // inputs, or a deferred payment's held ones — and getPaymentUTXOs,
      // whose contract is `isAvailable && !isPluginManaged`, filters them
      // out before this handler can see them, so through this API they used
      // to vanish from every number. Taken from the same rows as the rest,
      // in one read, so no bucket here can be a moment older than another;
      // the read model's wallet row computes its own `reservedBalance` from
      // these rows by the same rule (WalletProjection).
      final counted = [
        for (final utxo in await _storage.getUTXOs(query.walletId))
          if (!utxo.isPluginManaged && (utxo.isAvailable || utxo.isReserved)) utxo,
      ];
      final paymentUtxos = await splitBalanceUtxos(_storage, query.walletId, counted);
      BigInt confirmed = BigInt.zero;
      BigInt unconfirmed = BigInt.zero;
      BigInt reserved = BigInt.zero;

      for (final utxo in paymentUtxos.spendable) {
        // WalletBalances.bucketOf, asked rather than restated: reserved
        // first, then a verified proof putting the UTXO in a block on our
        // active chain, and nothing else, as confirmed (beads libspiffy-8oaq,
        // libspiffy-jc3h; spv-understanding.md, "Balances"). The wallet
        // aggregate's balances and the read model's wallet row are the same
        // three buckets over the same rule, so the layers cannot drift.
        switch (WalletBalances.bucketOf(utxo)) {
          case BalanceBucket.reserved:
            reserved += utxo.satoshis;
          case BalanceBucket.confirmed:
            confirmed += utxo.satoshis;
          case BalanceBucket.unconfirmed:
            unconfirmed += utxo.satoshis;
          case null:
            break;
        }
      }

      _emitEvent(BalanceResponse(
        walletId: query.walletId,
        queryId: query.correlationId,
        confirmedBalance: confirmed,
        unconfirmedBalance: unconfirmed,
        totalBalance: confirmed + unconfirmed,
        watchOnlyBalance: paymentUtxos.watchOnlySatoshis,
        reservedBalance: reserved,
      ));
    } catch (e) {
      _emitEvent(ErrorEvent(
        walletId: query.walletId,
        source: 'getBalance',
        message: e.toString(),
      ));
    }
  }

  Future<void> _handleGetTransactions(GetTransactionsQuery query) async {
    try {
      final transactions = await _storage.getTransactionHistory(
        query.walletId,
        limit: query.limit,
        offset: query.offset,
      );

      _emitEvent(TransactionsResponse(
        walletId: query.walletId,
        queryId: query.correlationId,
        transactions: transactions,
      ));
    } catch (e) {
      _emitEvent(ErrorEvent(
        walletId: query.walletId,
        source: 'getTransactions',
        message: e.toString(),
      ));
    }
  }

  Future<void> _handleGetTransactionDetail(GetTransactionDetailQuery query) async {
    try {
      final tx = await _storage.getTransaction(query.txid, walletId: query.walletId);

      _emitEvent(TransactionDetailResponse(
        walletId: query.walletId,
        queryId: query.correlationId,
        transaction: tx,
        found: tx != null,
      ));
    } catch (e) {
      _emitEvent(ErrorEvent(
        walletId: query.walletId,
        source: 'getTransactionDetail',
        message: e.toString(),
      ));
    }
  }

  Future<void> _handleCreateInvoice(CreateInvoiceCommand cmd) async {
    _log.info('Creating invoice for wallet ${cmd.walletId}');

    _invoiceCoordinator.tell(
      inv.CreateInvoiceMessage(
        walletId: cmd.walletId,
        amount: cmd.amount,
        outputs: cmd.outputs,
        description: cmd.description,
        expiresIn: cmd.effectiveExpiresIn,
        invoiceMetadata: cmd.invoiceMetadata,
        numberOfAddresses: cmd.numberOfAddresses,
      ),
      sender: context.self,
    );
  }

  Future<void> _handlePayInvoice(PayInvoiceCommand cmd) async {
    _log.info('Paying invoice ${cmd.invoiceId} from wallet ${cmd.walletId}');

    // Track correlation
    _paymentInvoiceCorrelation[cmd.invoiceId] = cmd.walletId;

    _paymentCoordinator.tell(
      pay.PayInvoiceMessage(
        walletId: cmd.walletId,
        invoiceId: cmd.invoiceId,
        addresses: cmd.addresses,
        amount: cmd.amount,
        outputs: cmd.outputs,
        changeAddress: cmd.changeAddress,
        paymentMetadata: cmd.paymentMetadata,
        // Who we are paying, as the app names them (bead libspiffy-cq16).
        counterpartyMarker: cmd.counterpartyMarker,
      ),
      sender: context.self,
    );
  }

  Future<void> _handleValidateBEEF(ValidateBEEFCommand cmd) async {
    _log.info('Validating BEEF for wallet ${cmd.walletId}');

    // Track this request under its own id for the multi-step validation flow.
    final requestId = 'beef-validation-${++_beefRequestSeq}';
    _beefValidations[requestId] = _PendingBeefValidation(
      walletId: cmd.walletId,
      beefHex: cmd.beefHex,
      invoiceId: cmd.invoiceId,
      fromCounterparty: cmd.fromCounterparty,
    );

    _spvActor.tell(
      wm.ValidateBEEFMessage(
        cmd.beefHex,
        targetWalletId: cmd.walletId,
        requestId: requestId,
      ),
      sender: context.self,
    );
  }

  /// Records an outgoing transaction in the wallet.
  ///
  /// Sent with this actor as the sender so a refusal comes back here
  /// (libspiffy-kl4i): without one the wallet had nobody to answer, and a
  /// recording the aggregate refused was invisible to the app. A successful
  /// recording is still not announced: the handler that would have done so
  /// was dead (nothing ever reached it) and published a manufactured
  /// `amountSatoshis: BigInt.zero`, so it was removed rather than made live
  /// with that number in it (bead libspiffy-5ml6).
  Future<void> _handleRecordOutgoing(RecordOutgoingCommand cmd) async {
    _walletManager.tell(
      wm.WalletCommandMessage(
        cmd.walletId,
        domain.RecordOutgoingTransactionCommand(
          walletId: cmd.walletId,
          txid: cmd.txid,
          rawHex: cmd.rawHex,
          totalInputSats: cmd.totalInputSats,
          totalOutputSats: cmd.totalOutputSats,
          fee: cmd.fee,
          numInputs: cmd.numInputs,
          numOutputs: cmd.numOutputs,
          txVersion: cmd.txVersion,
          txLockTime: cmd.txLockTime,
          spentUtxoKeys: cmd.spentUtxoKeys,
          recipientAddresses: cmd.recipientAddresses,
          paymentAmount: BigInt.from(cmd.paymentAmount),
          changeAddress: cmd.changeAddress,
          changeAmount: cmd.changeAmount != null ? BigInt.from(cmd.changeAmount!) : null,
          // Who we paid, as the app names them (bead libspiffy-cq16).
          counterpartyMarker: cmd.counterpartyMarker,
        ),
      ),
      sender: context.self,
    );
  }

  /// Imports a transaction the wallet knows to be mined (bead
  /// libspiffy-ckr4): the BEEF must carry the proof of the transaction it
  /// imports, its last. Without one it is refused here, before SPV: a
  /// counterparty's unproven payment is received with [ValidateBEEFCommand],
  /// which submits it and follows it to its block, and an import is
  /// submitted nowhere. The txid is read off the BEEF.
  Future<void> _handleImportTransaction(ImportTransactionCommand cmd) async {
    final BEEF beef;
    final String txid;
    try {
      beef = BEEF.parse(Uint8List.fromList(cmd.beef));
      if (beef.txs.isEmpty) throw const FormatException('it holds no transaction');
      txid = hex.encode(beef.calculateTxid(beef.txs.last));
    } catch (e) {
      _emitEvent(TransactionImportedEvent(
        walletId: cmd.walletId,
        transactionId: '',
        success: false,
        error: 'Failed to parse BEEF: $e',
      ));
      return;
    }
    if (!beef.carriesProofOf(txid)) {
      _emitEvent(TransactionImportedEvent(
        walletId: cmd.walletId,
        transactionId: txid,
        success: false,
        error: 'An import must carry the merkle proof of the transaction it imports, and $txid has none. '
            'A payment from a counterparty is received with ValidateBEEFCommand.',
      ));
      return;
    }
    _log.info('Importing transaction $txid for wallet ${cmd.walletId}');
    final requestId = 'receive-${++_receiveSeq}';
    _receives[requestId] = _Receive(walletId: cmd.walletId, payment: false);
    _spvActor.tell(
      wm.ReceiveTransactionMessage(
        transactionId: txid,
        beef: beef,
        // No placeholder: a stored 'import' would name a counterparty
        // nobody can be asked anything (bead libspiffy-cq16).
        fromCounterparty: cmd.fromCounterparty ?? '',
        targetWalletId: cmd.walletId,
        receivedAt: DateTime.now(),
        requestId: requestId,
      ),
      sender: context.self,
    );
  }

  Future<void> _handleStoreHeaders(StoreHeadersCommand cmd) async {
    try {
      int startHeight = 0;
      int endHeight = 0;
      int stored = 0;

      for (final headerData in cmd.headers) {
        final height = headerData['height'] as int;
        if (stored == 0) startHeight = height;
        endHeight = height;

        final prevBlockHashStr = headerData['prevBlockHash'] as String;
        final merkleRootStr = headerData['merkleRoot'] as String;
        final timestampInt = headerData['timestamp'] as int;

        final header = BlockHeader(
          version: headerData['version'] as int,
          prevBlock: Hash.fromBytes(Uint8List.fromList(hex.decode(prevBlockHashStr))),
          merkleRoot: Hash.fromBytes(Uint8List.fromList(hex.decode(merkleRootStr))),
          timestamp: DateTime.fromMillisecondsSinceEpoch(timestampInt * 1000),
          bits: headerData['bits'] as int,
          nonce: headerData['nonce'] as int,
        );

        await _storage.storeBlockHeader(header, height);
        stored++;
      }

      _emitEvent(BlockHeadersStoredEvent(
        headersStored: stored,
        startHeight: startHeight,
        endHeight: endHeight,
        success: true,
      ));
    } catch (e) {
      _emitEvent(BlockHeadersStoredEvent(
        headersStored: 0,
        startHeight: 0,
        endHeight: 0,
        success: false,
        error: e.toString(),
      ));
    }
  }

  /// Journals the watch address in the wallet (bead libspiffy-p4kv; it was
  /// written to the read model only, so a rebuild lost it) and reports
  /// success once the read model has its row. Runs off the mailbox.
  Future<void> _handleRegisterWatchAddress(RegisterWatchAddressCommand cmd) async {
    try {
      final applied = _awaitProjectionApplied(
        matches: (e) =>
            e is domain_events.WatchAddressAddedEvent && e.walletId == cmd.walletId && e.address == cmd.address,
        alreadyApplied: () async => (await _storage.getAddressMetadata(cmd.walletId, cmd.address))?.purpose == 'watch',
      );
      final response = await _walletManager.ask<wm.WatchAddressAddedResponse>(
        wm.WalletCommandMessage(
          cmd.walletId,
          domain.AddWatchAddressCommand(
            walletId: cmd.walletId,
            address: cmd.address,
            scriptType: cmd.scriptType,
            label: cmd.label,
          ),
        ),
        const Duration(seconds: 30),
      );
      // Nothing journaled (already watched, or an address the wallet
      // derived): no projection work to wait for.
      final notApplied = response.success && response.journaled ? await applied : null;
      if (!response.success || !response.journaled) unawaited(applied.catchError((_) => null));

      _emitEvent(WatchAddressRegisteredEvent(
        walletId: cmd.walletId,
        address: cmd.address,
        success: response.success,
        error: !response.success
            ? response.error ?? 'The wallet refused the watch address'
            : notApplied == null
                ? null
                : 'Registered and journaled, but the read model has not applied it yet: $notApplied',
      ));
    } catch (e) {
      _emitEvent(WatchAddressRegisteredEvent(
        walletId: cmd.walletId,
        address: cmd.address,
        success: false,
        error: e.toString(),
      ));
    }
  }

  /// Releases a reservation's UTXOs.
  ///
  /// Sent with this actor as the sender so a refusal comes back here
  /// (libspiffy-kl4i): without one the wallet had nobody to answer, and a
  /// release the aggregate refused was invisible to the app.
  Future<void> _handleReleaseUTXOs(ReleaseUTXOsCommand cmd) async {
    _walletManager.tell(
      wm.WalletCommandMessage(
        cmd.walletId,
        domain.ReleaseUTXOsCommand(
          walletId: cmd.walletId,
          reservationId: cmd.reservationId,
        ),
      ),
      sender: context.self,
    );
  }

  Future<void> _handleSplitUTXOs(SplitUTXOsCommand cmd) async {
    _log.info('Splitting UTXOs for wallet ${cmd.walletId}');

    _walletManager.tell(
      wm.WalletCommandMessage(
        cmd.walletId,
        domain.SplitUTXOsToBenfordCommand(
          walletId: cmd.walletId,
          targetUtxoCount: cmd.targetUtxoCount ?? 5,
          feeRate: cmd.feeRateSatsPerByte != null ? BigInt.from(cmd.feeRateSatsPerByte!) : null,
          maxUtxosToSplit: cmd.maxUtxosToSplit,
        ),
      ),
      sender: context.self,
    );
  }

  Future<void> _handleTimestamp(TimestampCommand cmd) async {
    _log.info('Creating timestamp archive ${cmd.archiveId} for wallet ${cmd.walletId}');

    // Build OP_RETURN outputs from file hashes
    final outputs = <InvoiceOutputSpec>[];
    for (final hash in cmd.fileHashes) {
      outputs.add(OPReturnOutputSpec(
        dataChunks: [hash.codeUnits],
        label: cmd.archiveTitle,
      ));
    }

    // Create an ephemeral invoice for the timestamp
    final invoiceId = 'timestamp-${cmd.archiveId}-${DateTime.now().millisecondsSinceEpoch}';
    _timestampCorrelation[invoiceId] = cmd.archiveId;
    _paymentInvoiceCorrelation[invoiceId] = cmd.walletId;

    // Pay the timestamp invoice directly
    _paymentCoordinator.tell(
      pay.PayInvoiceMessage(
        walletId: cmd.walletId,
        invoiceId: invoiceId,
        addresses: [],
        amount: BigInt.zero,
        outputs: outputs,
      ),
      sender: context.self,
    );
  }

  Future<void> _handleRefreshWallet(RefreshWalletCommand cmd) async {
    _emitEvent(WalletStatusEvent(
      walletId: cmd.walletId,
      status: 'refreshed',
      message: 'Wallet ${cmd.walletId} refreshed',
    ));
  }

  Future<void> _handleShutdown() async {
    _log.info('Coordinator shutting down');

    // Cancel all event subscriptions
    for (final sub in _eventSubscriptions.values) {
      await sub.cancel();
    }
    _eventSubscriptions.clear();

    // Dispose channel adapter
    _channelAdapter?.dispose();

    // Clear correlation maps
    _beefValidations.clear();
    _receives.clear();
    _paymentInvoiceCorrelation.clear();
    _timestampCorrelation.clear();
    _pendingCreateWallet.clear();

    _emitEvent(WalletStatusEvent(
      status: 'shutdown',
      message: 'Coordinator shut down',
    ));

    await _eventStream.close();
  }


  // ==========================================================================
  // DEFERRED PAYMENTS (bead libspiffy-7p2)
  // ==========================================================================

  /// How long a broadcast or status check through ARCActor may take (ARC
  /// requests time out after 30 s each; a broadcast submits ancestors too).
  static const _deferredNetworkTimeout = Duration(minutes: 2);

  Future<void> _handleGetDeferredPayments(GetDeferredPaymentsQuery query) async {
    try {
      final page = await _storage.listDeferredPayments(query.walletId, query: query.toStorageQuery());
      final details = <DeferredPaymentDetail>[];
      for (final payment in page.payments) {
        final tx = await _storage.getTransaction(payment.txid, walletId: query.walletId);
        Uint8List? beef;
        String? beefError;
        if (query.includeBeef) {
          if (tx == null || tx.rawHex.isEmpty) {
            beefError = 'The transaction row of ${payment.txid} is missing';
          } else {
            (beef, beefError) = await _rebuildDeferredBeef(tx);
          }
        }
        details.add(DeferredPaymentDetail(
          payment: payment,
          rawTxHex: tx?.rawHex,
          beef: beef,
          beefError: beefError,
        ));
      }
      _emitEvent(DeferredPaymentsResponse(
        walletId: query.walletId,
        queryId: query.correlationId,
        payments: details,
        nextCursor: page.nextCursor,
      ));
    } catch (e) {
      _emitEvent(ErrorEvent(
        walletId: query.walletId,
        source: 'getDeferredPayments',
        message: e.toString(),
      ));
    }
  }

  /// The BEEF of the stored transaction [tx]: its ancestors back to proven
  /// ones, from the read model. (null, reason) when the chain is incomplete.
  Future<(Uint8List?, String?)> _rebuildDeferredBeef(BitcoinTransaction tx) async {
    try {
      final parsed = dartsv.Transaction.fromHex(tx.rawHex);
      final parents = {for (final input in parsed.inputs) input.prevTxnId}.toList();
      final service = AncestorChainService(storage: _storage);
      final chain = await service.collectAncestorChainForUtxos(parents);
      if (!chain.isValid) return (null, 'Incomplete transaction chain: ${chain.error}');
      final result = await service.createBeefWithAncestry(
        newTransaction: tx,
        ancestorTransactions: chain.ancestorTransactions,
        merkleProofs: chain.merkleProofs,
      );
      return result.success ? (result.beefBytes, null) : (null, result.error);
    } catch (e) {
      return (null, 'BEEF could not be rebuilt: $e');
    }
  }

  Future<void> _handleBroadcastDeferredPayment(BroadcastDeferredPaymentCommand cmd) async {
    final requestId = cmd.correlationId;
    DeferredPaymentBroadcastEvent failure(String error) => DeferredPaymentBroadcastEvent(
        walletId: cmd.walletId, txid: cmd.txid, requestId: requestId, success: false, error: error);
    try {
      final payment = await _storage.getDeferredPayment(cmd.walletId, cmd.txid);
      if (payment == null) {
        _emitEvent(failure('Transaction ${cmd.txid} is not a deferred payment of wallet ${cmd.walletId}'));
        return;
      }
      final tx = await _storage.getTransaction(cmd.txid, walletId: cmd.walletId);
      if (tx == null || tx.rawHex.isEmpty) {
        _emitEvent(failure('The signed transaction ${cmd.txid} is not stored'));
        return;
      }
      final (beef, beefError) = await _rebuildDeferredBeef(tx);
      if (beefError != null) {
        _log.info('Broadcasting deferred payment ${cmd.txid} without ancestors: $beefError');
      }
      final result = await _arcActor.ask<wm.DeferredPaymentNetworkResult>(
        wm.BroadcastDeferredPaymentMessage(
          walletId: cmd.walletId,
          txid: cmd.txid,
          rawTxHex: tx.rawHex,
          beefHex: beef == null ? null : hex.encode(beef),
          via: cmd.via,
        ),
        _deferredNetworkTimeout,
      );
      final rejected = DeferredNetworkStatus.isDefinitiveFailure(result.networkStatus);
      // A competing transaction contests it (bead libspiffy-ey2): not
      // accepted, not failed either; the payment stays held.
      final contested = DeferredNetworkStatus.isContested(result.networkStatus);
      _emitEvent(DeferredPaymentBroadcastEvent(
        walletId: cmd.walletId,
        txid: cmd.txid,
        requestId: requestId,
        success: result.success && !rejected && !contested,
        networkStatus: result.networkStatus,
        source: result.source,
        confirmed: result.confirmed,
        willRetry: result.willRetry,
        error: rejected
            ? (result.error ?? 'The network rejected ${cmd.txid} (${result.networkStatus})')
            : contested
                ? 'ARC reports ${result.networkStatus} for ${cmd.txid}: a competing transaction spends an input; '
                    'the payment stays outstanding with its inputs held${result.error != null ? ' (${result.error})' : ''}'
                : result.error,
        competingTxids: result.competingTxids,
      ));
    } catch (e) {
      _emitEvent(failure('Broadcast of deferred payment ${cmd.txid} failed: $e'));
    }
  }

  Future<void> _handleCheckDeferredPaymentStatus(CheckDeferredPaymentStatusCommand cmd) async {
    final requestId = cmd.correlationId;
    try {
      final payment = await _storage.getDeferredPayment(cmd.walletId, cmd.txid);
      if (payment == null) {
        _emitEvent(DeferredPaymentStatusEvent(
          walletId: cmd.walletId,
          txid: cmd.txid,
          requestId: requestId,
          success: false,
          error: 'Transaction ${cmd.txid} is not a deferred payment of wallet ${cmd.walletId}',
        ));
        return;
      }
      final result = await _arcActor.ask<wm.DeferredPaymentNetworkResult>(
        wm.CheckDeferredPaymentStatusMessage(walletId: cmd.walletId, txid: cmd.txid, via: cmd.via),
        _deferredNetworkTimeout,
      );
      _emitEvent(DeferredPaymentStatusEvent(
        walletId: cmd.walletId,
        txid: cmd.txid,
        requestId: requestId,
        success: result.success,
        networkStatus: result.networkStatus,
        source: result.source,
        blockHeight: result.blockHeight,
        proofStatus: result.proofStatus,
        confirmed: result.confirmed,
        error: result.error,
        competingTxids: result.competingTxids,
      ));
    } catch (e) {
      _emitEvent(DeferredPaymentStatusEvent(
        walletId: cmd.walletId,
        txid: cmd.txid,
        requestId: requestId,
        success: false,
        error: 'Status check of deferred payment ${cmd.txid} failed: $e',
      ));
    }
  }

  Future<void> _handleCancelDeferredPayment(CancelDeferredPaymentCommand cmd) async {
    final requestId = cmd.correlationId;
    String? networkStatus;
    DeferredPaymentCancelledEvent refused(String error) => DeferredPaymentCancelledEvent(
          walletId: cmd.walletId,
          txid: cmd.txid,
          requestId: requestId,
          success: false,
          networkStatus: networkStatus,
          error: error,
        );
    try {
      final payment = await _storage.getDeferredPayment(cmd.walletId, cmd.txid);
      if (payment == null) {
        _emitEvent(refused('Transaction ${cmd.txid} is not a deferred payment of wallet ${cmd.walletId}'));
        return;
      }
      if (!payment.isOutstanding) {
        _emitEvent(refused('Deferred payment ${cmd.txid} is ${payment.state.name}; only an outstanding '
            'payment can be cancelled'));
        return;
      }

      // The network first: a transaction it knows may still be mined.
      final check = await _arcActor.ask<wm.DeferredPaymentNetworkResult>(
        wm.CheckDeferredPaymentStatusMessage(walletId: cmd.walletId, txid: cmd.txid, via: cmd.via),
        _deferredNetworkTimeout,
      );
      networkStatus = check.networkStatus;
      if (check.success) {
        if (!DeferredNetworkStatus.allowsCancel(check.networkStatus)) {
          _emitEvent(refused('Deferred payment ${cmd.txid} is known to the network '
              '(${check.networkStatus} from ${check.source}); it cannot be cancelled'));
          return;
        }
      } else if (!cmd.force) {
        _emitEvent(refused('The network status of ${cmd.txid} could not be checked (${check.error}); '
            'not cancelled (set force to cancel anyway)'));
        return;
      }

      final applied = _awaitProjectionApplied(
        matches: (e) => e is domain_events.DeferredTransactionCancelledEvent && e.txid == cmd.txid,
        alreadyApplied: () async =>
            (await _storage.getDeferredPayment(cmd.walletId, cmd.txid))?.state == DeferredPaymentState.cancelled,
      );
      final response = await _walletManager.ask<wm.DeferredSpendCancelledResponse>(
        wm.WalletCommandMessage(
          cmd.walletId,
          domain.CancelDeferredSpendCommand(
            walletId: cmd.walletId,
            txid: cmd.txid,
            reason: cmd.reason,
            networkStatus: check.success ? check.networkStatus : null,
          ),
        ),
        const Duration(seconds: 30),
      );
      if (!response.success) {
        unawaited(applied.catchError((_) => null));
        _emitEvent(refused(response.error ?? 'The wallet refused to cancel ${cmd.txid}'));
        return;
      }
      final notApplied = await applied;
      _emitEvent(DeferredPaymentCancelledEvent(
        walletId: cmd.walletId,
        txid: cmd.txid,
        requestId: requestId,
        success: true,
        networkStatus: networkStatus,
        releasedUtxoKeys: response.releasedUtxoKeys,
        error: notApplied == null
            ? null
            : 'Cancelled and journaled, but the read model has not applied it yet: $notApplied',
      ));
    } catch (e) {
      _emitEvent(refused('Cancellation of deferred payment ${cmd.txid} failed: $e'));
    }
  }

  /// Reclaims an outstanding deferred payment (bead libspiffy-87a): builds
  /// and signs a transaction spending exactly the inputs it holds back into
  /// this wallet, has the wallet journal it (the hold moves to it), and
  /// broadcasts it. One shot: there is no build-then-confirm step.
  ///
  /// The fee is ARC's published policy rate on the transaction's signed
  /// size ([TransactionSize]). It is not
  /// raised, and there is no caller override: this is Bitcoin SV, where a
  /// conflicting transaction cannot be displaced by paying more and the
  /// transaction that reached the network first is the one that is mined.
  ///
  /// The payment is not resolved here. It becomes
  /// [DeferredPaymentState.reclaimed] when the network reports the
  /// self-spend, which is also when its outputs become spendable.
  Future<void> _handleReclaimDeferredPayment(ReclaimDeferredPaymentCommand cmd) async {
    final requestId = cmd.correlationId;
    DeferredPaymentReclaimedEvent failure(String error, {String? reclaimTxid}) =>
        DeferredPaymentReclaimedEvent(
          walletId: cmd.walletId,
          txid: cmd.txid,
          reclaimTxid: reclaimTxid,
          requestId: requestId,
          success: false,
          error: error,
        );
    try {
      final payment = await _storage.getDeferredPayment(cmd.walletId, cmd.txid);
      if (payment == null) {
        _emitEvent(failure('Transaction ${cmd.txid} is not a deferred payment of wallet ${cmd.walletId}'));
        return;
      }
      if (!payment.isOutstanding) {
        _emitEvent(failure('Deferred payment ${cmd.txid} is ${payment.state.name}; only an outstanding '
            'payment can be reclaimed'));
        return;
      }
      if (payment.heldInputs.isEmpty) {
        _emitEvent(failure('Deferred payment ${cmd.txid} holds no inputs; there is nothing to reclaim'));
        return;
      }

      // The inputs it holds, as the wallet has them now.
      final rows = {for (final u in await _storage.getUTXOs(cmd.walletId)) u.key: u};
      final inputs = <BitcoinUtxo>[];
      for (final held in payment.heldInputs) {
        final utxo = rows[held.utxoKey];
        if (utxo == null || utxo.status == UTXOStatus.spent) {
          _emitEvent(failure('Input ${held.utxoKey} of deferred payment ${cmd.txid} is spent or unknown; '
              'it cannot be reclaimed'));
          return;
        }
        inputs.add(utxo);
      }
      final total = inputs.fold(BigInt.zero, (sum, u) => sum + u.satoshis);

      // ARC's published policy rate on the reclaim's signed size: the held
      // inputs, each by the unlocking script the wallet writes for it, and
      // one P2PKH output back to the wallet (bead libspiffy-bg7n). No bump,
      // no override: there is no fee auction on this network, and no fee
      // makes a conflicting transaction go away.
      final wm.FeeRateQuote quote;
      try {
        quote = await _arcActor.ask<wm.FeeRateQuote>(wm.GetFeeRateMessage(), _deferredNetworkTimeout);
      } catch (e) {
        _emitEvent(failure('The policy fee for the reclaim of ${cmd.txid} could not be quoted ($e); '
            'nothing was built or broadcast'));
        return;
      }
      final rate = quote.rate;
      if (!quote.success || rate == null) {
        _emitEvent(failure('The policy fee for the reclaim of ${cmd.txid} could not be quoted '
            '(${quote.error}); nothing was built or broadcast'));
        return;
      }
      final fee = rate.feeFor(TransactionSize.of(
        inputLockingScripts: [for (final utxo in inputs) utxo.scriptPubKey],
        outputScriptBytes: const [TransactionSize.p2pkhScriptBytes],
      ));
      final amount = total - fee;
      if (amount <= BigInt.zero) {
        _emitEvent(failure('The $total satoshi(s) deferred payment ${cmd.txid} holds do not cover the '
            '$fee satoshi policy fee of the reclaim'));
        return;
      }

      // Back to an address of ours.
      final wm.AddressGeneratedResponse address;
      try {
        address = await _walletManager.ask<wm.AddressGeneratedResponse>(
          wm.WalletCommandMessage(
            cmd.walletId,
            domain.GenerateAddressCommand(
              walletId: cmd.walletId,
              label: 'reclaim of ${cmd.txid}',
              commandId: 'reclaim-address-${cmd.txid}-${DateTime.now().microsecondsSinceEpoch}',
            ),
          ),
          const Duration(seconds: 30),
        );
      } catch (e) {
        _emitEvent(failure('No address to reclaim ${cmd.txid} to: $e'));
        return;
      }
      if (!address.success || address.address.isEmpty) {
        _emitEvent(failure('No address to reclaim ${cmd.txid} to: ${address.error ?? 'the wallet gave none'}'));
        return;
      }

      final unsigned = dartsv.Transaction();
      for (final utxo in inputs) {
        unsigned.addInput(
            dartsv.TransactionInput(utxo.txid, utxo.vout, dartsv.TransactionInput.MAX_SEQ_NUMBER));
      }
      unsigned.addOutput(dartsv.TransactionOutput(
        amount,
        dartsv.P2PKHLockBuilder.fromAddress(dartsv.Address.fromBase58(address.address)).getScriptPubkey(),
      ));
      final unsignedHex = unsigned.serialize();

      final String signedHex;
      try {
        signedHex = await AggregateSigningClient(
          system: context.system,
          walletManager: _walletManager,
          storage: _storage,
          replyTimeout: const Duration(seconds: 30),
        ).signTransaction(
          walletId: cmd.walletId,
          transactionId: dartsv.Transaction.fromHex(unsignedHex).id,
          unsignedTxHex: unsignedHex,
          utxos: inputs,
        );
      } catch (e) {
        _emitEvent(failure('The reclaim of ${cmd.txid} could not be signed: $e'));
        return;
      }
      final reclaimTxid = dartsv.Transaction.fromHex(signedHex).id;

      // Journal it before anything reaches the network: a self-spend that is
      // broadcast is always in the journal first.
      final applied = _awaitProjectionApplied(
        matches: (e) => e is domain_events.DeferredSpendReclaimedEvent && e.txid == cmd.txid,
        alreadyApplied: () async =>
            (await _storage.getDeferredPayment(cmd.walletId, reclaimTxid)) != null,
      );
      final wm.DeferredSpendReclaimedResponse response;
      try {
        response = await _walletManager.ask<wm.DeferredSpendReclaimedResponse>(
          wm.WalletCommandMessage(
            cmd.walletId,
            domain.ReclaimDeferredSpendCommand(
              walletId: cmd.walletId,
              txid: cmd.txid,
              reclaimTxid: reclaimTxid,
              rawHex: signedHex,
              recipientAddresses: [address.address],
              reason: cmd.reason,
            ),
          ),
          const Duration(seconds: 30),
        );
      } catch (e) {
        unawaited(applied.catchError((_) => null));
        _emitEvent(failure('The wallet did not answer the reclaim of ${cmd.txid}: $e', reclaimTxid: reclaimTxid));
        return;
      }
      if (!response.success) {
        unawaited(applied.catchError((_) => null));
        _emitEvent(failure(response.error ?? 'The wallet refused to reclaim ${cmd.txid}', reclaimTxid: reclaimTxid));
        return;
      }
      final notApplied = await applied;

      // Its ancestry, so a counterparty-funded input can be proved to ARC.
      Uint8List? beef;
      final stored = await _storage.getTransaction(reclaimTxid, walletId: cmd.walletId);
      if (stored != null && stored.rawHex.isNotEmpty) {
        final (bytes, beefError) = await _rebuildDeferredBeef(stored);
        beef = bytes;
        if (beefError != null) {
          _log.info('Broadcasting the reclaim $reclaimTxid without ancestors: $beefError');
        }
      }

      final result = await _arcActor.ask<wm.DeferredPaymentNetworkResult>(
        wm.BroadcastDeferredPaymentMessage(
          walletId: cmd.walletId,
          txid: reclaimTxid,
          rawTxHex: signedHex,
          beefHex: beef == null ? null : hex.encode(beef),
          via: cmd.via,
        ),
        _deferredNetworkTimeout,
      );
      final rejected = DeferredNetworkStatus.isDefinitiveFailure(result.networkStatus);
      final contested = DeferredNetworkStatus.isContested(result.networkStatus);
      _emitEvent(DeferredPaymentReclaimedEvent(
        walletId: cmd.walletId,
        txid: cmd.txid,
        reclaimTxid: reclaimTxid,
        requestId: requestId,
        success: result.success && !rejected && !contested,
        reclaimedUtxoKeys: response.reclaimedUtxoKeys,
        reclaimedSatoshis: amount,
        fee: fee,
        toAddress: address.address,
        networkStatus: result.networkStatus,
        source: result.source,
        competingTxids: result.competingTxids,
        error: rejected
            ? (result.error ?? 'The network rejected the reclaim $reclaimTxid (${result.networkStatus}); '
                'deferred payment ${cmd.txid} stays outstanding, its inputs now held by the reclaim')
            : contested
                ? 'The network reports ${result.networkStatus} for the reclaim $reclaimTxid: another '
                    'transaction spends the same inputs. Of two spends of one input the one that reached '
                    'the network first is mined; deferred payment ${cmd.txid} stays outstanding until that '
                    'is settled'
                : result.error ??
                    (notApplied == null
                        ? null
                        : 'Reclaimed and journaled, but the read model has not applied it yet: $notApplied'),
      ));
    } catch (e) {
      _emitEvent(failure('The reclaim of deferred payment ${cmd.txid} failed: $e'));
    }
  }

  // ==========================================================================
  // INTERNAL ACTOR RESPONSE HANDLERS
  // ==========================================================================

  /// The wallet manager, or a wallet aggregate, gave up on a request this
  /// coordinator made.
  ///
  /// These replies answer a request whose success would have been reported
  /// by someone else — a routed command is answered by the aggregate — so
  /// there is no success path here to fail. A creation or import still
  /// pending for the wallet is failed by name, because its
  /// `WalletCreatedMessage` is never coming; everything else becomes an
  /// [ErrorEvent], which is what the app can act on.
  void _handleWalletFailure(wm.FailureResponse failure) {
    final walletId = switch (failure) {
      wm.WalletManagerFailure(walletId: final id) => id,
      wm.WalletCommandFailed(walletId: final id) => id,
      _ => null,
    };
    final source = switch (failure) {
      wm.WalletManagerFailure() => 'WalletManagerActor',
      wm.WalletCommandFailed() => 'BitcoinWalletAggregate',
      _ => failure.runtimeType.toString(),
    };
    _log.warning('$source gave up on ${failure.request}'
        '${walletId != null ? ' for wallet $walletId' : ''}: ${failure.error}');

    if (walletId != null && _pendingCreateWallet.remove(walletId) != null) {
      _emitEvent(WalletCreatedEvent(
        walletId: walletId,
        rootAddress: '',
        success: false,
        error: failure.error,
      ));
      return;
    }

    _emitEvent(ErrorEvent(
      walletId: walletId,
      source: source,
      message: '${failure.request}: ${failure.error}',
    ));
  }

  void _handleWalletCreatedResponse(wm.WalletCreatedMessage response) {
    _log.info('Wallet created: ${response.walletId} success=${response.success}');

    if (response.success) {
      _channelAdapter?.updateWalletId(response.walletId);
    }

    _pendingCreateWallet.remove(response.walletId);

    if (!response.success) {
      _emitEvent(WalletCreatedEvent(
        walletId: response.walletId,
        rootAddress: response.rootAddress,
        success: false,
        error: response.error,
      ));
      return;
    }

    // Callers act on this event straight away (import a transaction, which
    // makes SPVActor look up the root address in the read model), so it is
    // emitted only once the projection has written the wallet row and its
    // root address (libspiffy-p56). The wait runs off the mailbox (A-M2).
    unawaited(_emitWalletCreated(response));
  }

  /// Waits (off the mailbox) until the wallet read model holds the wallet
  /// created by [response], then emits the coordinator-level
  /// WalletCreatedEvent. If the projection does not apply the creation, the
  /// event reports failure with the reason, as imports do.
  Future<void> _emitWalletCreated(wm.WalletCreatedMessage response) async {
    final walletId = response.walletId;
    String? awaitError;
    try {
      final reason = await _awaitProjectionApplied(
        matches: (e) =>
            e is domain_events.WalletCreatedEvent && e.walletId == walletId,
        alreadyApplied: () async => await _storage.getWallet(walletId) != null,
      );
      if (reason != null) {
        awaitError = 'Wallet $walletId was created but the wallet read model '
            'failed to apply it: $reason';
        _log.warning(awaitError);
      }
    } catch (e, stackTrace) {
      awaitError =
          'Unexpected error awaiting projection persistence for wallet '
          '$walletId: $e';
      _log.warning(awaitError, e, stackTrace);
    }

    _emitEvent(WalletCreatedEvent(
      walletId: walletId,
      rootAddress: response.rootAddress,
      success: awaitError == null,
      error: awaitError,
    ));
  }

  void _handleWalletCreatedResponseAlt(wm.WalletCreatedResponse response) {
    _handleWalletCreatedResponse(wm.WalletCreatedMessage(
      response.walletId,
      response.rootAddress,
      response.success,
      error: response.error,
    ));
  }

  void _handleInvoiceCreatedResponse(inv.InvoiceCreatedMessage response) {
    _log.info('Invoice created: ${response.invoiceId} success=${response.success}');

    _emitEvent(InvoiceCreatedEvent(
      walletId: response.walletId,
      invoiceId: response.invoiceId,
      addresses: response.addresses,
      amount: response.amount,
      outputs: response.outputs,
      description: response.description,
      expiresAt: response.expiresAt,
      success: response.success,
      error: response.error,
    ));
  }

  void _handleInvoiceDetailsResponse(inv.InvoiceDetailsResponse response) {
    _emitEvent(InvoiceCreatedEvent(
      walletId: response.walletId ?? '',
      invoiceId: response.invoiceId,
      addresses: response.addresses,
      amount: response.amount,
      outputs: response.outputs,
      description: response.description,
      expiresAt: response.expiresAt,
      success: response.found,
      error: response.error,
    ));
  }

  Future<void> _handleBEEFPaymentResponse(pay.BEEFPaymentResponse response) async {
    _log.info('BEEF payment response: ${response.invoiceId} success=${response.success}');

    final walletId = _paymentInvoiceCorrelation.remove(response.invoiceId);
    final archiveId = _timestampCorrelation.remove(response.invoiceId);

    if (archiveId != null) {
      // This is a timestamp archive payment
      if (response.success) {
        // Broadcast the BEEF
        // ARCActor hex-decodes beefHex (see _handleBroadcastBEEF); the
        // SPV path at _handleBEEFValidated encodes the same way.
        _arcActor.tell(wm.BroadcastBEEFMessage(
          walletId ?? '',
          hex.encode(response.beefBytes),
          response.txid,
        ));

        _emitEvent(TimestampCompleteEvent(
          walletId: walletId,
          archiveId: archiveId,
          transactionId: response.txid,
          success: true,
        ));
      } else {
        _emitEvent(TimestampCompleteEvent(
          walletId: walletId,
          archiveId: archiveId,
          success: false,
          error: response.error,
        ));
      }
    } else {
      _emitEvent(PaymentReadyEvent(
        walletId: walletId,
        invoiceId: response.invoiceId,
        beefBytes: response.beefBytes,
        txid: response.txid,
        amountPaid: response.amountPaid,
        changeAmount: response.changeAmount,
        ancestorCount: response.ancestorCount,
        success: response.success,
        error: response.error,
        witnessTxid: response.witnessTxid,
        witnessBeefBytes: response.witnessBeefBytes,
      ));
    }
  }

  /// Settle a BEEF by broadcasting all unsettled TXs (hasMerkle=false) to ARC
  /// in dependency order. TXs with merkle proofs are already on-chain and
  /// skipped.
  ///
  /// This handler DOES NOT emit BEEFSettledEvent synchronously. Instead it
  /// registers a pending settlement, tells ARCActor to broadcast each TX,
  /// and waits for BroadcastSuccessMessage/BroadcastFailedMessage responses.
  /// See `_completeSettlementIfDone` for the completion path. A 60s timeout
  /// ensures we never hang forever if ARC responses are lost.
  Future<void> _handleSettleBEEF(SettleBEEFCommand cmd) async {
    _log.info('Settling BEEF: txid=${cmd.txid} walletId=${cmd.walletId}');

    // Guard against duplicate in-flight settlements for the same parent txid
    if (_pendingSettlements.containsKey(cmd.txid)) {
      _log.warning('[settle] already in progress for ${cmd.txid}');
      _emitEvent(BEEFSettledEvent(
        walletId: cmd.walletId,
        txid: cmd.txid,
        success: false,
        error: 'Settlement already in progress for txid ${cmd.txid}',
      ));
      return;
    }

    late final BEEF beef;
    try {
      final beefBytes = Uint8List.fromList(hex.decode(cmd.beefHex));
      beef = BEEF.parse(beefBytes);
    } catch (e) {
      _log.warning('[settle] BEEF parse failed for txid=${cmd.txid}: $e');
      _emitEvent(BEEFSettledEvent(
        walletId: cmd.walletId,
        txid: cmd.txid,
        success: false,
        error: 'BEEF parse failed: $e',
      ));
      return;
    }

    // Partition TXs into "already on chain (skip)" and "needs broadcast"
    int skipped = 0;
    final pending = <String, String>{}; // childTxid → txHex
    for (int i = 0; i < beef.txs.length; i++) {
      final hasMerkle = i < beef.hasMerkle.length && beef.hasMerkle[i];
      if (hasMerkle) {
        skipped++;
        continue;
      }
      final txHex = hex.encode(beef.txs[i]);
      final childTxid = dartsv.Transaction.fromHex(txHex).id;
      pending[childTxid] = txHex;
    }

    // Degenerate case: nothing to broadcast (e.g., all ancestors already
    // on chain). Emit success immediately.
    if (pending.isEmpty) {
      _log.info('[settle] nothing to broadcast for ${cmd.txid} '
          '(skipped=$skipped)');
      _emitEvent(BEEFSettledEvent(
        walletId: cmd.walletId,
        txid: cmd.txid,
        success: true,
        submittedCount: 0,
        skippedCount: skipped,
      ));
      return;
    }

    // Register pending settlement + per-child routing
    final entry = _PendingSettlement(
      parentTxid: cmd.txid,
      walletId: cmd.walletId,
      pending: pending.keys.toSet(),
      skippedCount: skipped,
    );
    _pendingSettlements[cmd.txid] = entry;
    for (final childTxid in pending.keys) {
      _childToParentSettlement[childTxid] = cmd.txid;
    }

    // Timeout safety net. 60s covers typical ARC latency with headroom.
    entry.timeout = Timer(const Duration(seconds: 60), () {
      if (_pendingSettlements[cmd.txid] != entry) return;
      _log.warning('[settle] timeout for ${cmd.txid} — '
          'still waiting on ${entry.pending}');
      // Mark each still-pending child as failed-by-timeout
      for (final stillPending in entry.pending.toList()) {
        entry.failures[stillPending] = 'settlement timeout (60s)';
      }
      entry.pending.clear();
      _completeSettlementIfDone(cmd.txid);
    });

    // Fire broadcasts. ARCActor processes its mailbox serially so these
    // will be submitted in the order we .tell, which matches the BEEF's
    // dependency order (split first, earmarks next, primary last).
    //
    // NOTE: we pass `sender: context.self` explicitly so ARCActor's
    // responses (BroadcastSuccessMessage / BroadcastFailedMessage) route
    // back to THIS coordinator. Without an explicit sender, dactor's
    // tell() defaults to sender=null and ARCActor's
    // `context.sender?.tell(...)` silently drops the response.
    for (final entryTx in pending.entries) {
      final childTxid = entryTx.key;
      final txHex = entryTx.value;
      _log.info('[settle] broadcasting txid=$childTxid '
          '(${(txHex.length / 2).toInt()} bytes)');
      _arcActor.tell(
        wm.BroadcastTransactionMessage(cmd.walletId, txHex, childTxid),
        sender: context.self,
      );
    }
  }

  /// Check whether a pending settlement has received all expected responses
  /// and emit BEEFSettledEvent if so. Safe to call multiple times.
  void _completeSettlementIfDone(String parentTxid) {
    final entry = _pendingSettlements[parentTxid];
    if (entry == null) return;
    if (entry.pending.isNotEmpty) return;

    entry.timeout?.cancel();

    final submitted = entry.initialPendingCount - entry.failures.length;
    final failedTxids = entry.failures.keys.toList();
    final failureErrors = failedTxids.map((t) => entry.failures[t] ?? '').toList();

    // Build aggregated error string if any failures occurred
    String? aggregatedError;
    if (entry.failures.isNotEmpty) {
      aggregatedError = entry.failures.entries
          .map((e) => 'tx ${e.key}: ${e.value}')
          .join('; ');
    }

    _log.info('[settle] complete for $parentTxid: '
        'submitted=$submitted failed=${entry.failures.length} '
        'skipped=${entry.skippedCount}');

    _emitEvent(BEEFSettledEvent(
      walletId: entry.walletId,
      txid: parentTxid,
      success: entry.failures.isEmpty,
      error: aggregatedError,
      submittedCount: submitted,
      skippedCount: entry.skippedCount,
      failedCount: entry.failures.length,
      failedTxids: failedTxids,
      failureErrors: failureErrors,
    ));

    // Clean up routing tables
    for (final childTxid in entry.initialPending) {
      _childToParentSettlement.remove(childTxid);
    }
    _pendingSettlements.remove(parentTxid);
  }

  Future<void> _handleBEEFValidationResult(wm.BEEFValidationResult result) async {
    _log.info('BEEF validation result: valid=${result.isValid} wallet=${result.targetWalletId}');

    final requestId = result.requestId;
    final pending =
        requestId == null ? null : _beefValidations.remove(requestId);
    if (pending == null) {
      // Not one of ours (or already answered): report it uncorrelated.
      _emitEvent(BEEFValidationResultEvent(
        walletId: result.targetWalletId,
        valid: result.isValid,
        error: result.error,
      ));
      return;
    }
    final walletId = pending.walletId;

    if (!result.isValid) {
      // Structural validation failed
      _emitEvent(BEEFValidationResultEvent(
        walletId: walletId,
        invoiceId: pending.invoiceId,
        valid: false,
        error: result.error ?? 'BEEF structural validation failed',
      ));
      return;
    }

    // Structural validation passed - continue to full SPV validation
    {
      final beefHex = pending.beefHex;
      final invoiceId = pending.invoiceId;

      try {
        final beefBytes = Uint8List.fromList(hex.decode(beefHex));
        final beef = BEEF.parse(beefBytes);
        final txid = beef.txs.isNotEmpty ? hex.encode(beef.calculateTxid(beef.txs.last)) : 'unknown';

        final receiveId = 'receive-${++_receiveSeq}';
        _receives[receiveId] = _Receive(walletId: walletId, payment: true, invoiceId: invoiceId);

        _spvActor.tell(
          wm.ReceiveTransactionMessage(
            transactionId: txid,
            beef: beef,
            // The marker the ValidateBEEFCommand carried, if any: the
            // literal 'counterparty' that stood here named nobody and is
            // now persisted evidence, so it is gone (bead libspiffy-cq16).
            fromCounterparty: pending.fromCounterparty ?? '',
            targetWalletId: walletId,
            invoiceId: invoiceId,
            receivedAt: DateTime.now(),
            requestId: receiveId,
          ),
          sender: context.self,
        );
      } catch (e) {
        _emitEvent(BEEFValidationResultEvent(
          walletId: walletId,
          invoiceId: invoiceId,
          valid: false,
          error: 'Failed to parse BEEF for SPV validation: $e',
        ));
      }
    }
  }

  void _handleSPVValidationResult(wm.SPVValidationResult result) {
    _log.info('SPV validation result: txid=${result.txid} valid=${result.isValid}');

    // A proof response this coordinator put through the receive path (bead
    // libspiffy-a2v3) waits for its verdict here; the ordinary import events
    // below are emitted for it too, as for any other standalone receive.
    _proofAdapter.handleReceiveResult(result);

    // Which kind of receive this answers (bead libspiffy-xggs). A request of
    // ours names itself by its id. Anything else — a receive parked for a
    // header and replayed, in this process or after a restart, which carries
    // no caller's id — is classified by what it received: an import always
    // carries its subject's proof (ckr4), so one without it, or one naming an
    // invoice, is a payment.
    final requestId = result.requestId;
    final request = requestId == null ? null : _receives.remove(requestId);
    final walletId = request?.walletId ?? result.targetWalletId;
    final payment = request?.payment ?? (result.invoiceId != null || !result.subjectCarriesProof);

    if (payment) {
      if (walletId == null) return;
      // Off the mailbox: it waits for the read model and for ARC.
      unawaited(_answerPayment(result, walletId, request?.invoiceId ?? result.invoiceId));
      return;
    }

    // An import. Nobody is told of a receive parked for a header; its
    // verdict arrives when the header does.
    if (result.awaitingHeader) return;
    _emitEvent(SPVValidationResultEvent(
      walletId: result.targetWalletId,
      txid: result.txid,
      isValid: result.isValid,
      validationError: result.validationError,
      spendableUTXOs: result.spendableUTXOs,
      spentUTXOs: result.spentUTXOs,
      unreadableOutputs: result.unreadableOutputs,
    ));

    // Emit TransactionImportedEvent so callers waiting on it get notified.
    //
    // WalletManagerActor processes the same SPVValidationResult in parallel
    // and dispatches RecordImportedTransactionCommand to the wallet aggregate,
    // which ultimately produces the aggregate-level TransactionImportedEvent
    // that the projection persists into bitcoinTransactionEntitys. If we
    // emitted this coord-level event immediately, callers (e.g., overnode's
    // `_handleWalletImportTokenBeef` waiting on `_waitForWalletEvent
    // <TransactionImportedEvent>`) could be told "success" before the read
    // model contained the txid — exactly the gap Phase 1 closed for outbound
    // recording. We close it here for inbound by waiting on the wallet
    // projection actor before emitting.
    //
    // The wait runs off the mailbox (A-M2): awaiting it inside onMessage
    // blocked every other public command for up to 32 s.
    if (result.targetWalletId != null) {
      unawaited(_emitTransactionImported(result));
    }
  }

  /// Answers a counterparty's payment (bead libspiffy-xggs).
  ///
  /// The receiver broadcasts the payment it cares about. So once a payment
  /// validates and the read model holds it — the status ARC reports lands
  /// on its row, and an app told of the payment can query it — a payment
  /// that carried no proof of its own is submitted to ARC, which then
  /// tracks it to its block (the status scan asks ARC about it: it is our
  /// broadcast). One that carried its proof, verified, is already mined and
  /// is submitted nowhere. The event says what ARC answered.
  ///
  /// This used to happen only on the invoice path's first reply, as a
  /// fire-and-forget tell answered `broadcasted: true` at once — before ARC
  /// answered and with no ARC at all — and a payment parked for a header,
  /// whose first reply is not a verdict, was never submitted: its verdict
  /// arrived with nobody correlated to it.
  Future<void> _answerPayment(wm.SPVValidationResult result, String walletId, String? invoiceId) async {
    BEEFValidationResultEvent answer({
      required bool valid,
      String? error,
      bool broadcasted = false,
      String? networkStatus,
      String? broadcastError,
    }) =>
        BEEFValidationResultEvent(
          walletId: walletId,
          invoiceId: invoiceId,
          txid: result.txid,
          valid: valid,
          error: error,
          broadcasted: broadcasted,
          networkStatus: networkStatus,
          broadcastError: broadcastError,
          awaitingHeader: result.awaitingHeader,
          spendableUTXOs: valid ? result.spendableUTXOs : null,
          unreadableOutputs: result.unreadableOutputs,
        );

    if (!result.isValid) {
      _emitEvent(answer(valid: false, error: result.validationError ?? 'SPV validation failed'));
      return;
    }

    String? notApplied;
    try {
      notApplied = await _awaitImportApplied(result.txid);
    } catch (e) {
      notApplied = '$e';
    }
    final applyError = notApplied == null
        ? null
        : 'Payment ${result.txid} was validated but the wallet read model failed to apply it: $notApplied';

    final mined = result.provenTransactions.any((p) => p.txid == result.txid);
    if (mined) {
      _emitEvent(answer(valid: applyError == null, error: applyError));
      return;
    }

    final row = await _storage.getTransaction(result.txid, walletId: walletId);
    if (row == null || row.rawHex.isEmpty) {
      _emitEvent(answer(
        valid: false,
        error: applyError ?? 'Payment ${result.txid} is not stored',
        broadcastError: 'not submitted: the wallet does not hold the transaction',
      ));
      return;
    }

    dynamic reply;
    try {
      reply = await _arcActor.ask<dynamic>(
          wm.BroadcastTransactionMessage(walletId, row.rawHex, result.txid), _paymentSubmitTimeout);
    } catch (e) {
      reply = wm.BroadcastFailedMessage(result.txid, 'ARC did not answer the submission: $e');
    }
    _emitEvent(switch (reply) {
      wm.BroadcastSuccessMessage(:final networkStatus) =>
        answer(valid: applyError == null, error: applyError, broadcasted: true, networkStatus: networkStatus),
      wm.BroadcastFailedMessage(:final error, :final networkStatus) => answer(
          valid: applyError == null, error: applyError, networkStatus: networkStatus, broadcastError: error),
      _ => answer(
          valid: applyError == null,
          error: applyError,
          broadcastError: 'ARC answered the submission with ${reply.runtimeType}'),
    });
  }

  /// Waits (off the mailbox) until the wallet read model holds [result]'s
  /// transaction, then emits the coordinator-level TransactionImportedEvent.
  Future<void> _emitTransactionImported(wm.SPVValidationResult result) async {
    BigInt totalReceived = BigInt.zero;
    for (final utxo in result.spendableUTXOs) {
      final sat = utxo['satoshis'];
      totalReceived += sat is BigInt ? sat : BigInt.from(sat ?? 0);
    }

    String? awaitError;
    if (result.isValid) {
      try {
        final reason = await _awaitImportApplied(result.txid);
        if (reason != null) {
          awaitError =
              'Imported transaction ${result.txid} was validated but the wallet '
              'read model failed to apply it: $reason';
          _log.warning(awaitError);
        }
      } catch (e) {
        awaitError =
            'Unexpected error awaiting projection persistence for '
            '${result.txid}: $e';
        _log.warning(awaitError);
      }
    }

    _emitEvent(TransactionImportedEvent(
      walletId: result.targetWalletId!,
      transactionId: result.txid,
      success: result.isValid && awaitError == null,
      utxosCreated: result.spendableUTXOs.length,
      totalValueReceived: totalReceived.toString(),
      error: awaitError ?? result.validationError,
    ));
  }

  /// Resolves with null once the wallet projection has applied the
  /// TransactionImportedEvent for [txid], or with the failure reason.
  ///
  /// The SPV result reaches this coordinator after WalletManagerActor was
  /// told to record the transaction, so the projection may already have
  /// applied the event by the time an awaiter could be registered, and an
  /// awaiter only matches events applied after it (A-M2). So:
  /// 1. register the awaiter;
  /// 2. send GetProjectionInfo behind it. The projection's mailbox is FIFO,
  ///    so its reply proves the awaiter is registered: every event applied
  ///    from then on resolves the awaiter, and every event applied before
  ///    has finished its read-model write;
  /// 3. then look for the row. Present means "already applied".
  Future<String?> _awaitImportApplied(String txid) => _awaitProjectionApplied(
        matches: (e) =>
            e is domain_events.TransactionImportedEvent && e.txid == txid,
        alreadyApplied: () async => await _storage.getTransaction(txid) != null,
      );

  /// Resolves with null once the wallet projection has applied an event
  /// satisfying [matches], or with the failure reason; [alreadyApplied]
  /// checks the read model for the effect of an event applied before the
  /// awaiter was registered. See [_awaitImportApplied] for the barrier.
  Future<String?> _awaitProjectionApplied({
    required bool Function(Event e) matches,
    required Future<bool> Function() alreadyApplied,
  }) async {
    final applied = _walletProjection.ask<dynamic>(
      AwaitEventApplied(
        matches,
        timeout: const Duration(seconds: 30),
      ),
      // Ask timeout must outlast the awaiter's own window, otherwise dactor's
      // default (5 s) fires first and a slow projection looks like a failure.
      const Duration(seconds: 32),
    );
    // Whichever branch loses must not surface as an unhandled error.
    final appliedOutcome = applied.then<String?>(
      (response) => response is AwaitFailed ? response.reason : null,
      onError: (Object e) => e.toString(),
    );

    final applyVisible = () async {
      try {
        await _walletProjection.ask<dynamic>(
            GetProjectionInfo(), const Duration(seconds: 30));
        return await alreadyApplied();
      } catch (_) {
        return false; // No barrier answer: rely on the awaiter alone.
      }
    }();

    final first = await Future.any<Object?>([
      appliedOutcome.then((reason) => _AwaiterOutcome(reason)),
      applyVisible,
    ]);
    if (first is _AwaiterOutcome) return first.reason;
    if (first == true) return null;
    return appliedOutcome;
  }

  void _handleSplitUTXOsResponse(wm.SplitUTXOsResponse response) {
    // Each number is read from what the split actually reports, not inferred
    // (bead libspiffy-q28i). `splitCount` is a UTXO count, so it answers
    // newUtxoCount and NOT transactionCount, which used to be inflated by
    // targetUtxoCount; and the fee is summed from the splits that succeeded
    // rather than stated as a zero nobody measured.
    final txids = response.txids ?? const <String>[];
    var totalFeePaid = BigInt.zero;
    for (final split in response.splits) {
      if (split.isSuccess && split.feePaid != null) {
        totalFeePaid += split.feePaid!;
      }
    }
    _emitEvent(UTXOSplitCompleteEvent(
      walletId: response.walletId,
      transactionCount: txids.length,
      newUtxoCount: response.splitCount ?? 0,
      totalFeePaid: totalFeePaid,
      success: response.success,
      error: response.error,
      txids: txids,
      splits: response.splits,
    ));
  }

  Future<void> _handleProvisionFunding(ProvisionFundingCommand cmd) async {
    _log.info('Provisioning funding for wallet ${cmd.walletId} via plugin ${cmd.pluginId}');

    _paymentCoordinator.tell(
      pay.ProvisionFundingMessage(
        walletId: cmd.walletId,
        pluginId: cmd.pluginId,
        pluginParams: cmd.pluginParams,
      ),
      sender: context.self,
    );
  }

  void _handleProvisionFundingResponse(pay.ProvisionFundingResponse response) {
    _log.info('Provisioning response: wallet=${response.walletId} '
        'success=${response.success} txs=${response.transactionCount} '
        'earmarks=${response.earmarkCount}');

    _emitEvent(ProvisioningCompleteEvent(
      walletId: response.walletId,
      transactionCount: response.transactionCount,
      earmarkCount: response.earmarkCount,
      success: response.success,
      error: response.error,
    ));
  }

  /// Reports an outgoing recording to the app once the read model holds it
  /// (bead libspiffy-5ml6).
  ///
  /// A successful recording used to be announced nowhere. The arm that would
  /// have announced it was dead — [_handleRecordOutgoing] told the wallet
  /// manager with no sender — and bead libspiffy-kl4i deleted it rather than
  /// let it go live, because it published a manufactured `BigInt.zero` for
  /// an amount it did not hold. Supplying that sender, which is what made a
  /// refused recording reach the app at all, turned on a different arm: the
  /// aggregate answers a recording with one `UTXOReceivedResponse` per
  /// change output of the transaction (`_addWalletOutputs` credits the
  /// wallet's own outputs), and the coordinator announced each of those as a
  /// `TransactionReceivedEvent` of zero satoshis, **incoming** — an app's own
  /// payment reported back to it as money arriving. That event is gone: an
  /// incoming receive is reported by `SPVValidationResultEvent` and
  /// `TransactionImportedEvent`, which carry the amount the wallet measured,
  /// and change is part of the payment this event announces.
  ///
  /// A refusal does not come this way: the aggregate has no reply of its own
  /// for a failed recording and answers `WalletCommandFailed`, which
  /// [_handleWalletFailure] turns into an `ErrorEvent` (bead libspiffy-kl4i).
  Future<void> _handleTransactionRecorded(wm.TransactionRecordedResponse response) async {
    if (!response.success) {
      _emitEvent(TransactionRecordedEvent(
        walletId: response.walletId,
        txid: response.txid,
        success: false,
        error: response.error ?? 'The wallet refused the recording',
      ));
      return;
    }
    // "Recorded" means queryable, the promise WalletCreatedEvent (bead
    // libspiffy-p56) and TransactionImportedEvent already make: an app told
    // its payment is recorded asks for it next.
    final notApplied = await _awaitProjectionApplied(
      matches: (e) => e is domain_events.TransactionRecordedEvent && e.txid == response.txid,
      alreadyApplied: () async => await _storage.getTransaction(response.txid) != null,
    );
    _emitEvent(TransactionRecordedEvent(
      walletId: response.walletId,
      txid: response.txid,
      amountSatoshis: response.paymentAmount,
      success: notApplied == null,
      error: notApplied == null
          ? null
          : 'Recorded and journaled, but the read model has not applied it yet: $notApplied',
    ));
  }
}

/// A structural BEEF validation awaiting SPVActor's reply (A-M1).
/// A receive this coordinator asked SPVActor for: a counterparty's payment
/// (answered with a [BEEFValidationResultEvent], and submitted) or an import.
class _Receive {
  final String walletId;
  final bool payment;
  final String? invoiceId;

  _Receive({required this.walletId, required this.payment, this.invoiceId});
}

class _PendingBeefValidation {
  final String walletId;
  final String beefHex;
  final String? invoiceId;

  /// The app's opaque counterparty marker the command carried, if any
  /// (bead libspiffy-cq16).
  final String? fromCounterparty;

  _PendingBeefValidation({
    required this.walletId,
    required this.beefHex,
    required this.invoiceId,
    this.fromCounterparty,
  });
}

/// The awaiter's result, distinguished from the "already applied" check in
/// [WalletCoordinatorActor._awaitImportApplied].
class _AwaiterOutcome {
  final String? reason;
  const _AwaiterOutcome(this.reason);
}

/// Tracks an in-flight SettleBEEFCommand. One of these lives in
/// [WalletCoordinatorActor._pendingSettlements] from the moment the settle
/// command is accepted until either (a) every child TX has reported back
/// via BroadcastSuccess/Failed, or (b) the timeout fires.
class _PendingSettlement {
  final String parentTxid;
  final String walletId;
  final Set<String> pending; // child txids still awaiting a response
  final Set<String> initialPending; // snapshot at registration time (for cleanup)
  final int initialPendingCount;
  final Map<String, String> failures = {}; // child txid → error message
  final int skippedCount;
  Timer? timeout;

  _PendingSettlement({
    required this.parentTxid,
    required this.walletId,
    required Set<String> pending,
    required this.skippedCount,
  })  : pending = pending,
        initialPending = Set.of(pending),
        initialPendingCount = pending.length;
}
