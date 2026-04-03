import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:dactor/dactor.dart';
import 'package:logging/logging.dart';
import 'package:spiffynode/spiffy_node.dart' show BlockHeader, Hash;

import '../core/channel_events.dart';
import '../core/wallet_commands.dart' as domain;
import '../core/wallet_events.dart' as domain_events;
import '../models/wallet_event.dart' as wallet_event_model;
import '../models/address_metadata.dart';
import '../models/bitcoin_utxo.dart';
import '../models/invoice_output_spec.dart';
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

  // Direct storage access for CQRS read queries
  final ReadModelStorage _storage;

  // Channel P2P adapter (composed, not a separate actor)
  ChannelP2PAdapter? _channelAdapter;

  // Event broadcasting
  final StreamController<CoordinatorEvent> _eventStream =
      StreamController<CoordinatorEvent>.broadcast();

  // Correlation maps (absorbed from Overnode's WalletCoordinatorActor)
  final Map<String, String> _beefValidationCorrelation = {}; // walletId → invoiceId
  final Map<String, (String, String?)> _beefDataCorrelation =
      {}; // walletId → (beefHex, invoiceId)
  final Map<String, (String, String?, String)> _spvProcessingCorrelation =
      {}; // txid → (beefHex, invoiceId, walletId)
  final Map<String, String> _paymentInvoiceCorrelation = {}; // invoiceId → walletId
  final Map<String, String> _timestampCorrelation = {}; // invoiceId → archiveId
  final Map<String, CreateWalletCommand> _pendingCreateWallet = {}; // walletId → original cmd
  final Map<String, StreamSubscription> _eventSubscriptions = {}; // walletId → subscription

  // Wallet event broadcaster for import progress forwarding
  final void Function(wallet_event_model.WalletEvent)? _broadcastWalletEvent;

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

  // Wallet events stream for import monitoring
  final Stream<wallet_event_model.WalletEvent>? _walletEventsStream;

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
    ActorRef? importActor,
    required ReadModelStorage storage,
    Stream<ChannelEvent>? channelEvents,
    String peerId = '',
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
    Stream<wallet_event_model.WalletEvent>? walletEventsStream,
  })  : _walletManager = walletManager,
        _invoiceCoordinator = invoiceCoordinator,
        _paymentCoordinator = paymentCoordinator,
        _spvActor = spvActor,
        _arcActor = arcActor,
        _headerSyncActor = headerSyncActor,
        _benfordCoordinator = benfordCoordinator,
        _channelManager = channelManager,
        _importActor = importActor,
        _storage = storage,
        _peerId = peerId,
        _broadcastWalletEvent = broadcastWalletEvent,
        _importWalletFromXpriv = importWalletFromXpriv,
        _importWalletFromWif = importWalletFromWif,
        _walletEventsStream = walletEventsStream {
    // Initialize channel P2P adapter if channel events stream provided
    if (channelEvents != null) {
      _channelAdapter = ChannelP2PAdapter(
        channelManager: channelManager,
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
        await _handleRegisterWatchAddress(message);
      } else if (message is ReleaseUTXOsCommand) {
        await _handleReleaseUTXOs(message);
      } else if (message is SplitUTXOsCommand) {
        await _handleSplitUTXOs(message);
      } else if (message is ProvisionFundingCommand) {
        await _handleProvisionFunding(message);
      } else if (message is TimestampCommand) {
        await _handleTimestamp(message);
      } else if (message is RefreshWalletCommand) {
        await _handleRefreshWallet(message);
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
        await _handleSPVValidationResult(message);
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
      } else if (message is wm.BroadcastFailedMessage) {
        _log.warning('Broadcast failed for ${message.txid}: ${message.error}');
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
      // Subscribe to wallet events for progress/completion forwarding
      if (_walletEventsStream != null) {
        _eventSubscriptions[cmd.walletId] = _walletEventsStream!
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
      final tx = await _storage.getTransaction(query.txid);

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

    // Track correlations for the multi-step validation flow
    if (cmd.invoiceId != null) {
      _beefValidationCorrelation[cmd.walletId] = cmd.invoiceId!;
    }
    _beefDataCorrelation[cmd.walletId] = (cmd.beefHex, cmd.invoiceId);

    _spvActor.tell(
      wm.ValidateBEEFMessage(cmd.beefHex, targetWalletId: cmd.walletId),
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

  Future<void> _handleRegisterWatchAddress(RegisterWatchAddressCommand cmd) async {
    try {
      await _storage.upsertAddress(
        cmd.walletId,
        AddressMetadata(
          address: cmd.address,
          scriptType: cmd.scriptType,
          isChange: false,
          purpose: 'watch',
          label: cmd.label,
          usageCount: 0,
          balance: BigInt.zero,
          createdAt: DateTime.now(),
          isWatched: true,
        ),
      );

      _emitEvent(WatchAddressRegisteredEvent(
        walletId: cmd.walletId,
        address: cmd.address,
        success: true,
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
    _beefValidationCorrelation.clear();
    _beefDataCorrelation.clear();
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
  // INTERNAL ACTOR RESPONSE HANDLERS
  // ==========================================================================

  void _handleWalletCreatedResponse(wm.WalletCreatedMessage response) {
    _log.info('Wallet created: ${response.walletId} success=${response.success}');

    if (response.success) {
      _currentWalletId = response.walletId;
      _channelAdapter?.updateWalletId(response.walletId);
    }

    _pendingCreateWallet.remove(response.walletId);

    _emitEvent(WalletCreatedEvent(
      walletId: response.walletId,
      rootAddress: response.rootAddress,
      success: response.success,
      error: response.error,
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
        _arcActor.tell(wm.BroadcastBEEFMessage(
          walletId ?? '',
          base64Encode(response.beefBytes),
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
      // Regular payment — register inputs with ARCActor for deferred spend
      // and independent sender-side monitoring
      if (response.success && response.spentUtxoKeys.isNotEmpty && walletId != null) {
        _arcActor.tell(wm.RegisterTransactionInputsMessage(
          txid: response.txid,
          walletId: walletId,
          utxoKeys: response.spentUtxoKeys,
        ));
        // Also register outputs for status tracking
        _arcActor.tell(wm.RegisterTransactionOutputsMessage(
          txid: response.txid,
          walletId: walletId,
          vouts: [], // Output tracking will be populated by the receiver
        ));
      }

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

  Future<void> _handleBEEFValidationResult(wm.BEEFValidationResult result) async {
    _log.info('BEEF validation result: valid=${result.isValid} wallet=${result.targetWalletId}');

    final walletId = result.targetWalletId;
    if (walletId == null) {
      _emitEvent(BEEFValidationResultEvent(
        valid: result.isValid,
        error: result.error,
      ));
      return;
    }

    if (!result.isValid) {
      // Structural validation failed
      final invoiceId = _beefValidationCorrelation.remove(walletId);
      _beefDataCorrelation.remove(walletId);

      _emitEvent(BEEFValidationResultEvent(
        walletId: walletId,
        invoiceId: invoiceId,
        valid: false,
        error: result.error ?? 'BEEF structural validation failed',
      ));
      return;
    }

    // Structural validation passed - continue to full SPV validation
    final beefData = _beefDataCorrelation.remove(walletId);
    if (beefData != null) {
      final (beefHex, invoiceId) = beefData;

      try {
        final beefBytes = Uint8List.fromList(hex.decode(beefHex));
        final beef = BEEF.parse(beefBytes);
        final txid = beef.txs.isNotEmpty
            ? beef.calculateTxid(beef.txs.last).map((b) => b.toRadixString(16).padLeft(2, '0')).join()
            : 'unknown';

        // Track SPV processing correlation
        _spvProcessingCorrelation[txid] = (beefHex, invoiceId, walletId);

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
          valid: false,
          error: 'Failed to parse BEEF for SPV validation: $e',
        ));
      }
    }
  }

  Future<void> _handleSPVValidationResult(wm.SPVValidationResult result) async {
    _log.info('SPV validation result: txid=${result.txid} valid=${result.isValid}');

    final correlation = _spvProcessingCorrelation.remove(result.txid);

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
      ));

      // Emit TransactionImportedEvent so callers waiting on it get notified.
      if (result.targetWalletId != null) {
        BigInt totalReceived = BigInt.zero;
        for (final utxo in result.spendableUTXOs) {
          final sat = utxo['satoshis'];
          totalReceived += sat is BigInt ? sat : BigInt.from(sat ?? 0);
        }

        _emitEvent(TransactionImportedEvent(
          walletId: result.targetWalletId!,
          transactionId: result.txid,
          success: result.isValid,
          utxosCreated: result.spendableUTXOs.length,
          totalValueReceived: totalReceived.toString(),
          error: result.validationError,
        ));
      }
    }
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
