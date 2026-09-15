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
import '../models/wallet_event.dart' as wallet_event_model;
import '../models/bitcoin_transaction.dart';
import '../models/bitcoin_utxo.dart';
import '../models/invoice_output_spec.dart';
import '../services/ancestor_chain_service.dart';
import '../storage/read_model_storage.dart';
import '../utils/beef.dart';
import 'channel_p2p_adapter.dart';
import 'coordinator_messages.dart';
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
  final ActorRef _headerSyncActor;
  final ActorRef _benfordCoordinator;
  final ActorRef _channelManager;
  final ActorRef? _importActor;
  final ActorRef _walletProjection;

  // Direct storage access for CQRS read queries
  final ReadModelStorage _storage;

  // Channel P2P adapter (composed, not a separate actor)
  ChannelP2PAdapter? _channelAdapter;

  // Event broadcasting
  final StreamController<CoordinatorEvent> _eventStream =
      StreamController<CoordinatorEvent>.broadcast();

  // Correlation maps (absorbed from Overnode's WalletCoordinatorActor)

  /// In-flight structural BEEF validations, keyed by the per-request id sent
  /// as [wm.ValidateBEEFMessage.requestId] and echoed by SPVActor. Keying by
  /// walletId (as before) let two validations for one wallet overwrite each
  /// other (A-M1).
  final Map<String, _PendingBeefValidation> _beefValidations = {};
  int _beefRequestSeq = 0;

  /// Full-SPV stage of a BEEF validation, keyed by txid. SPVActor's
  /// ReceiveTransaction reply carries only the txid, and it answers in
  /// mailbox order, so several validations of one txid queue up FIFO.
  final Map<String, List<(String, String?, String)>> _spvProcessingCorrelation =
      {}; // txid → [(beefHex, invoiceId, walletId)]
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

  /// Current wallet ID (set after first wallet created)
  String? _currentWalletId;

  /// Current peer ID for P2P channels
  String _peerId;

  WalletCoordinatorActor({
    required ActorRef walletManager,
    required ActorRef invoiceCoordinator,
    required ActorRef paymentCoordinator,
    required ActorRef spvActor,
    required ActorRef arcActor,
    required ActorRef headerSyncActor,
    required ActorRef benfordCoordinator,
    required ActorRef channelManager,
    required ActorRef walletProjection,
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
        _headerSyncActor = headerSyncActor,
        _benfordCoordinator = benfordCoordinator,
        _channelManager = channelManager,
        _walletProjection = walletProjection,
        _importActor = importActor,
        _storage = storage,
        _peerId = peerId,
        _importWalletFromXpriv = importWalletFromXpriv,
        _importWalletFromWif = importWalletFromWif,
        _importNotifications = importNotifications {
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
    if (!_eventStream.isClosed) {
      _eventStream.add(event);
    }
  }

  @override
  void preStart() {
    // The adapter is built in the constructor, before this actor has a
    // context; wallet command replies it triggers must come back here.
    _channelAdapter?.updateReplyTo(context.self);
  }

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
      } else if (message is ReceiveTransactionCommand) {
        await _handleReceiveTransaction(message);
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
      } else if (message is AcceptChannelCommand) {
        _channelAdapter?.handleAcceptRequest(message);
      } else if (message is RejectChannelCommand) {
        _channelAdapter?.handleRejectRequest(message);
      } else if (message is ChannelP2PReceived) {
        _channelAdapter?.handleP2PMessage(
            message.fromPeerId, message.messageType, message.payload);
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
      } else if (message is wm.UTXOReceivedResponse) {
        _handleUTXOReceivedResponse(message);
      } else if (message is wm.TransactionRecordedResponse) {
        _handleTransactionRecordedResponse(message);
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
      final utxos = await _storage.getPaymentUTXOs(query.walletId);
      BigInt confirmed = BigInt.zero;
      BigInt unconfirmed = BigInt.zero;

      for (final utxo in utxos) {
        final amount = utxo.satoshis;
        if (utxo.blockHeight != null && utxo.blockHeight! > 0) {
          confirmed += amount;
        } else {
          unconfirmed += amount;
        }
      }

      _emitEvent(BalanceResponse(
        walletId: query.walletId,
        queryId: query.correlationId,
        confirmedBalance: confirmed,
        unconfirmedBalance: unconfirmed,
        totalBalance: confirmed + unconfirmed,
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
        feeEstimateSats: cmd.feeEstimateSats,
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

  Future<void> _handleReceiveTransaction(ReceiveTransactionCommand cmd) async {
    _log.info('Receiving transaction for wallet ${cmd.walletId}');

    try {
      final beefBytes = Uint8List.fromList(hex.decode(cmd.beefHex));
      final beef = BEEF.parse(beefBytes);

      // The last transaction in BEEF is typically the payment tx
      final paymentTxid = beef.txs.isNotEmpty
          ? hex.encode(beef.calculateTxid(beef.txs.last))
          : 'unknown';

      _spvActor.tell(
        wm.ReceiveTransactionMessage(
          transactionId: paymentTxid,
          beef: beef,
          fromCounterparty: cmd.fromCounterparty ?? 'unknown',
          targetWalletId: cmd.walletId,
          invoiceId: cmd.invoiceId,
          receivedAt: DateTime.now(),
        ),
        sender: context.self,
      );
    } catch (e) {
      _emitEvent(ErrorEvent(
        walletId: cmd.walletId,
        source: 'receiveTransaction',
        message: 'Failed to parse BEEF: $e',
      ));
    }
  }

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
        ),
      ),
    );
  }

  Future<void> _handleImportTransaction(ImportTransactionCommand cmd) async {
    _log.info('Importing transaction ${cmd.transactionId} for wallet ${cmd.walletId}');

    try {
      final beefBytes = Uint8List.fromList(cmd.beef);
      final beef = BEEF.parse(beefBytes);

      _spvActor.tell(
        wm.ReceiveTransactionMessage(
          transactionId: cmd.transactionId,
          beef: beef,
          fromCounterparty: cmd.fromCounterparty ?? 'import',
          targetWalletId: cmd.walletId,
          receivedAt: DateTime.now(),
        ),
        sender: context.self,
      );
    } catch (e) {
      _emitEvent(TransactionImportedEvent(
        walletId: cmd.walletId,
        transactionId: cmd.transactionId,
        success: false,
        error: 'Failed to parse BEEF: $e',
      ));
    }
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

  Future<void> _handleReleaseUTXOs(ReleaseUTXOsCommand cmd) async {
    _walletManager.tell(
      wm.WalletCommandMessage(
        cmd.walletId,
        domain.ReleaseUTXOsCommand(
          walletId: cmd.walletId,
          reservationId: cmd.reservationId,
        ),
      ),
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
    _spvProcessingCorrelation.clear();
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
      _emitEvent(DeferredPaymentBroadcastEvent(
        walletId: cmd.walletId,
        txid: cmd.txid,
        requestId: requestId,
        success: result.success && !rejected,
        networkStatus: result.networkStatus,
        source: result.source,
        confirmed: result.confirmed,
        willRetry: result.willRetry,
        error: rejected ? (result.error ?? 'The network rejected ${cmd.txid} (${result.networkStatus})') : result.error,
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

  // ==========================================================================
  // INTERNAL ACTOR RESPONSE HANDLERS
  // ==========================================================================

  void _handleWalletCreatedResponse(wm.WalletCreatedMessage response) {
    _log.info('Wallet created: ${response.walletId} success=${response.success}');

    if (response.success) {
      _currentWalletId = response.walletId;
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
        final txid = beef.txs.isNotEmpty
            ? beef.calculateTxid(beef.txs.last).map((b) => b.toRadixString(16).padLeft(2, '0')).join()
            : 'unknown';

        // Track SPV processing correlation
        _spvProcessingCorrelation
            .putIfAbsent(txid, () => [])
            .add((beefHex, invoiceId, walletId));

        _spvActor.tell(
          wm.ReceiveTransactionMessage(
            transactionId: txid,
            beef: beef,
            fromCounterparty: 'counterparty',
            targetWalletId: walletId,
            invoiceId: invoiceId,
            receivedAt: DateTime.now(),
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

    final queued = _spvProcessingCorrelation[result.txid];
    final correlation =
        queued == null || queued.isEmpty ? null : queued.removeAt(0);
    if (queued != null && queued.isEmpty) {
      _spvProcessingCorrelation.remove(result.txid);
    }

    if (correlation != null) {
      final (beefHex, invoiceId, walletId) = correlation;

      if (result.isValid) {
        // Broadcast the BEEF
        _arcActor.tell(wm.BroadcastBEEFMessage(
          walletId,
          beefHex,
          result.txid,
        ));

        _emitEvent(BEEFValidationResultEvent(
          walletId: walletId,
          invoiceId: invoiceId,
          txid: result.txid,
          valid: true,
          broadcasted: true,
          spendableUTXOs: result.spendableUTXOs,
        ));
      } else {
        _emitEvent(BEEFValidationResultEvent(
          walletId: walletId,
          invoiceId: invoiceId,
          txid: result.txid,
          valid: false,
          error: result.validationError ?? 'SPV validation failed',
        ));
      }
    } else {
      // No correlation - this is a standalone import (not a payment validation)
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
    _emitEvent(UTXOSplitCompleteEvent(
      walletId: response.walletId,
      transactionCount: response.splitCount ?? 0,
      newUtxoCount: response.splitCount ?? 0,
      totalFeePaid: BigInt.zero,
      success: response.success,
      error: response.error,
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

  void _handleUTXOReceivedResponse(wm.UTXOReceivedResponse response) {
    if (response.success) {
      _emitEvent(TransactionReceivedEvent(
        walletId: response.walletId,
        txid: response.txid,
        amountSatoshis: BigInt.zero, // Amount not available in response
        isIncoming: true,
      ));
    }
  }

  void _handleTransactionRecordedResponse(wm.TransactionRecordedResponse response) {
    if (response.success) {
      _emitEvent(TransactionReceivedEvent(
        walletId: response.walletId,
        txid: response.txid,
        amountSatoshis: BigInt.zero,
        isIncoming: false,
      ));
    }
  }
}

/// A structural BEEF validation awaiting SPVActor's reply (A-M1).
class _PendingBeefValidation {
  final String walletId;
  final String beefHex;
  final String? invoiceId;

  _PendingBeefValidation({
    required this.walletId,
    required this.beefHex,
    required this.invoiceId,
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
