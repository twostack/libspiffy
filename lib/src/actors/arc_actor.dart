import 'dart:async';
import 'dart:typed_data';
import 'package:dactor/dactor.dart';
import 'package:convert/convert.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:duraq/duraq.dart' as duraq;
import 'package:duraq_isar/duraq_isar.dart' as duraq_isar;
import 'package:isar/isar.dart';
import 'package:logging/logging.dart';

import '../core/wallet_commands.dart';
import '../models/bitcoin_transaction.dart';
import '../models/bitcoin_utxo.dart' show UTXOStatus;
import '../models/deferred_payment.dart';
import '../models/blockchain_data_models.dart' show MerkleProofData;
import '../services/blockchain_data_source.dart';
import '../utils/tsc_converter.dart';

import '../services/arc_service.dart';
import '../services/arc_service_config.dart';
import '../spv/merkle_proof_header_check.dart';
import '../storage/read_model_storage.dart';
import '../storage/transaction_row_rules.dart';
import '../utils/beef.dart';
import 'spv_messages.dart' show BlockHeaderStoredMessage;
import 'wallet_messages.dart';

/// A MINED report whose block header is not stored yet (SPV-09), with every
/// wallet whose scan met it (each is confirmed once the header arrives).
class _PendingProof {
  final Set<String> walletIds;
  final String bumpHex;
  final int? claimedHeight;

  _PendingProof(this.walletIds, this.bumpHex, this.claimedHeight);
}

/// Back-off state of a pending transaction ARC does not report progress on.
class _Backoff {
  final DateTime due;
  final int misses;

  _Backoff(this.due, this.misses);
}

/// What one status check of a transaction found.
enum _CheckOutcome { changed, unchanged, unknown }

/// One status check of a transaction: the scan uses [outcome], an explicit
/// deferred-payment check the rest.
class _StatusCheck {
  final _CheckOutcome outcome;

  /// ARC's wire status, `NOT_FOUND`, or null when ARC could not be asked.
  final String? status;
  final int? blockHeight;
  final ProofHeaderStatus? proofStatus;
  final String? error;

  /// The competing transactions ARC named with [status] (bead libspiffy-pkum).
  final List<String> competingTxids;

  const _StatusCheck(this.outcome,
      {this.status, this.blockHeight, this.proofStatus, this.error, this.competingTxids = const []});
}

/// Actor that handles ARC service integration for transaction broadcasting and monitoring
///
/// Confirmation (SPV-09): a MINED report is only acted on after the BRC-74
/// `merklePath` ARC returns walks to the merkle root of the locally stored
/// header at that height. If no header is stored yet the proof is held and
/// re-checked whenever headers arrive (CheckStoragePendingUTXOsMessage or
/// BlockHeaderStoredMessage); a root mismatch is logged SEVERE and never
/// confirmed.
///
/// Proof retention (bead libspiffy-9ek): the actor never writes proofs to the
/// read model. The verified BUMP travels in ConfirmTransactionCommand (one
/// per wallet holding the transaction) and is journaled in
/// TransactionConfirmedEvent; WalletProjection stores the proof from the
/// event, so a read model rebuilt from the journal has it.
///
/// Status monitoring (A-M3): one scan at a time. A timer tick that finds a
/// scan running is skipped; header notifications are debounced by
/// [headerTriggerDebounce] and, if a scan is running, fold into a single
/// follow-up scan. Scans run outside the mailbox. Pending transactions that
/// ARC does not know (or reports no progress on) are re-queried with
/// exponential back-off instead of on every scan.
class ARCActor extends Actor {
  final _log = Logger('ARCActor');
  final ActorRef _walletManager;
  final ArcServiceConfig? _arcConfig;
  final ReadModelStorage _storage;
  final Isar? _isar;

  /// Optional fallback for explicit deferred-payment checks and broadcasts
  /// ([DeferredPaymentNetworkSource.dataSource]); never used by the scan.
  final BlockchainDataSource? _dataSource;

  // ARC service client (dynamic to allow mock services in tests)
  dynamic _arcService;

  // Orphan remediation tracking (transient — OK to lose on restart)
  final Map<String, int> _orphanRemediationAttempts = {}; // txid -> attempt count
  static const int _maxOrphanRemediationAttempts = 3;

  // Periodic status checking
  Timer? _statusCheckTimer;

  /// Interval of the periodic status scan (and base of the pending back-off).
  final Duration statusCheckInterval;

  /// Header notifications within this window coalesce into one scan.
  final Duration headerTriggerDebounce;

  /// How soon a deferred spend is applied again when the network reported
  /// the transaction before the read model held it (bead libspiffy-onh).
  final Duration deferredSpendRecheckDelay;

  /// How often the recently failed transactions are polled
  /// ([_checkRecentFailedTransactions], bead libspiffy-5bju). Deliberately
  /// much longer than [statusCheckInterval]: this is speculative work on a
  /// terminal state.
  final Duration failedCheckInterval;

  /// How far back that poll looks: only rows whose status last changed
  /// within this window are read.
  final Duration failedCheckWindow;

  /// The most rows that poll reads (and so the most ARC queries it makes) in
  /// one pass. Zero or less turns the poll off.
  final int failedCheckLimit;

  /// Time source of the poll's interval (injectable for tests). The window
  /// itself is measured with the wall clock, since storage stamps
  /// `updatedAt` with it.
  final DateTime Function() _clock;

  /// When ([_clock]) the last failed-transaction poll ran.
  DateTime? _lastFailedCheck;

  static const Duration _maxPendingBackoff = Duration(minutes: 30);
  static const Duration _minReconfirmWindow = Duration(minutes: 2);

  bool _scanInFlight = false;

  /// Completes when the running status scan ends; null when none runs.
  Completer<void>? _scanDone;
  bool _rescanRequested = false;
  bool _stopped = false;
  Timer? _headerDebounceTimer;
  final Map<String, _Backoff> _pendingBackoff = {};

  /// MINED reports waiting for their block header, by txid.
  final Map<String, _PendingProof> _pendingProofs = {};

  /// When this actor last confirmed a txid in a wallet, so a scan racing a
  /// header re-check does not confirm twice. Keyed per wallet: another
  /// wallet holding the same transaction still gets its own confirmation.
  /// Entries expire (the confirmation command may have been lost; the
  /// projection moves a confirmed transaction out of the scanned states
  /// anyway).
  final Map<(String, String), DateTime> _recentlyConfirmed = {};

  Duration get _reconfirmWindow =>
      statusCheckInterval * 2 > _minReconfirmWindow ? statusCheckInterval * 2 : _minReconfirmWindow;

  bool _confirmedRecently(String walletId, String txid) {
    final key = (walletId, txid);
    final at = _recentlyConfirmed[key];
    if (at == null) return false;
    if (DateTime.now().difference(at) < _reconfirmWindow) return true;
    _recentlyConfirmed.remove(key);
    return false;
  }

  /// Deferred-spend commands this actor sent recently, keyed by wallet and
  /// `spend:<utxoKey>` / `available:<utxoKey>` (bead libspiffy-09k). The
  /// read model lags the commands; this keeps a submit response, a status
  /// scan and a MINED report arriving close together from sending the same
  /// command twice. Entries expire after [_reconfirmWindow]: a command the
  /// read model still does not reflect by then is sent again (the aggregate
  /// ignores a UTXO already made available and refuses to spend one twice).
  final Map<(String, String), DateTime> _deferredSpendIssued = {};

  /// Claims [action] on [utxoKey] in [walletId]; false if it was sent recently.
  bool _claimDeferredSpend(String walletId, String action, String utxoKey, DateTime now) {
    final key = (walletId, '$action:$utxoKey');
    final at = _deferredSpendIssued[key];
    if (at != null && now.difference(at) < _reconfirmWindow) return false;
    _deferredSpendIssued[key] = now;
    return true;
  }

  /// Deferred spends waiting for the read model to hold their transaction
  /// (bead libspiffy-onh): the recheck timer, by wallet and txid.
  final Map<(String, String), Timer> _spendRechecks = {};

  // Durable broadcast retry queue (persisted via Isar)
  duraq.Queue<Map<String, dynamic>>? _broadcastQueue;

  ARCActor({
    required ActorRef walletManager,
    required ReadModelStorage storage,
    ArcServiceConfig? arcConfig,
    dynamic arcService,  // ← Allow injecting mock service for testing (dynamic for test mocks)
    Isar? isar,
    this.statusCheckInterval = const Duration(seconds: 30),
    this.headerTriggerDebounce = const Duration(milliseconds: 500),
    this.deferredSpendRecheckDelay = const Duration(seconds: 1),
    this.failedCheckInterval = const Duration(minutes: 30),
    this.failedCheckWindow = const Duration(days: 7),
    this.failedCheckLimit = 25,
    DateTime Function()? clock,
    BlockchainDataSource? dataSource,
  })  : _walletManager = walletManager,
        _storage = storage,
        _arcConfig = arcConfig,
        _arcService = arcService,
        _isar = isar,
        _clock = clock ?? DateTime.now,
        _dataSource = dataSource;

  @override
  void preStart() {
    _initializeARCService();
    _initializeBroadcastQueue();
    _startStatusMonitoring();
  }

  @override
  Future<void> onMessage(dynamic message) async {
    try {
      switch (message) {
        case final BroadcastTransactionMessage msg:
          await _handleBroadcastTransaction(msg);
          break;

        case final BroadcastBEEFMessage msg:
          await _handleBroadcastBEEF(msg);
          break;

        case final CheckTransactionStatusMessage msg:
          await _handleCheckTransactionStatus(msg);
          break;

        case final RetrieveMerkleProofMessage msg:
          await _handleRetrieveMerkleProof(msg);
          break;

        case final GetFeeQuoteMessage msg:
          await _handleGetFeeQuote(msg);
          break;

        case final EstimateFeeMessage msg:
          await _handleEstimateFee(msg);
          break;

        case final EstimatePolicyFeeMessage msg:
          context.sender?.tell(await _quotePolicyFee(msg));
          break;

        case final CheckStoragePendingUTXOsMessage msg:
          await _handleCheckStoragePendingUTXOs(msg);
          break;

        case BlockHeaderStoredMessage():
          await _onHeadersArrived();
          break;

        case final TransactionConfirmationsRevertedMessage msg:
          _handleConfirmationsReverted(msg);
          break;

        case final CheckDeferredPaymentStatusMessage check:
          context.sender?.tell(await _checkDeferredPayment(check.walletId, check.txid, check.via));
          break;

        case final BroadcastDeferredPaymentMessage msg:
          context.sender?.tell(await _broadcastDeferredPayment(msg));
          break;

        case StopArcWorkMessage():
          await _stopWork();
          context.sender?.tell(ArcWorkStoppedMessage());
          break;

        default:
      }
    } catch (e) {

      // Send error response for messages that expect responses
      if (context.sender != null) {
        _sendErrorResponse(message, e.toString());
      }
    }
  }

  /// Initialize ARC service integration.
  ///
  /// **No configuration means no ARC** (bead libspiffy-8743). This used to
  /// fall back to `ArcServiceConfig.taalMainnet()`, so an actor built with
  /// no ARC endpoint silently acquired a **mainnet** one — the last copy of
  /// the defect audit V-2 fixed in `LibSpiffyActorSystem`, which resolves
  /// the endpoint from the wallet's network and so never passes null here.
  /// A wallet with no ARC is a reasonable configuration: it holds, records
  /// and proves transactions, and asks nobody to broadcast them. Every
  /// handler already answers "ARC service not available" for it; those
  /// branches were unreachable while this manufactured a service, and are
  /// the supported behaviour now.
  void _initializeARCService() {
    // Skip if ARC service was already provided (e.g., mock for testing)
    if (_arcService != null) {
      return;
    }
    if (_arcConfig == null) {
      _log.info('No ARC configuration: broadcasts, status checks, fee quotes and '
          'merkle proof retrieval will report that ARC is not available');
      return;
    }
    _arcService = ArcService.fromConfig(_arcConfig);
  }

  /// Initialize durable broadcast retry queue via duraq
  void _initializeBroadcastQueue() {
    if (_isar == null) {
      _log.warning('No Isar instance provided — broadcast retry queue disabled');
      return;
    }

    try {
      final isarStorage = duraq_isar.IsarStorage(_isar!);
      _broadcastQueue = duraq.Queue<Map<String, dynamic>>(
        'arc_broadcast_retry',
        isarStorage,
        retryPolicy: duraq.ExponentialBackoff(
          baseDelay: Duration(seconds: 10),
          maxDelay: Duration(minutes: 5),
          maxAttempts: 10,
        ),
      );
      _log.info('Broadcast retry queue initialized');
    } catch (e) {
      _log.warning('Failed to initialize broadcast retry queue: $e');
    }
  }

  /// Start periodic transaction status monitoring
  void _startStatusMonitoring() {
    _statusCheckTimer = Timer.periodic(statusCheckInterval, (timer) {
      unawaited(_runScan(fromTimer: true));
    });
  }

  /// Run one status scan unless one is already running.
  ///
  /// A timer tick that finds a scan running is dropped (the next tick
  /// comes soon enough). Any other trigger asks the running scan for one
  /// follow-up pass, so N triggers during a scan cost one extra scan.
  Future<void> _runScan({bool fromTimer = false}) async {
    if (_stopped) return;
    if (_scanInFlight) {
      if (!fromTimer) _rescanRequested = true;
      _log.fine('Status scan already running; ${fromTimer ? 'timer tick skipped' : 'follow-up scheduled'}');
      return;
    }
    _scanInFlight = true;
    final done = _scanDone = Completer<void>();
    try {
      do {
        _rescanRequested = false;
        await _checkNonTerminalTransactions();
        await _checkRecentFailedTransactions();
        if (fromTimer) await _processRetryQueue();
      } while (_rescanRequested && !_stopped);
    } finally {
      _scanInFlight = false;
      _scanDone = null;
      done.complete();
    }
  }

  /// Headers were stored: re-check held proofs now (storage only), and
  /// schedule one debounced ARC scan for the whole batch.
  Future<void> _onHeadersArrived() async {
    await _recheckPendingProofs();
    if (_stopped) return;
    _headerDebounceTimer?.cancel();
    _headerDebounceTimer = Timer(headerTriggerDebounce, () {
      _headerDebounceTimer = null;
      unawaited(_runScan());
    });
  }

  /// SPVActor took back these confirmations (reorganization, or a proof
  /// that does not match its header): forget that they were confirmed or
  /// held, and poll them again soon (audit 3b0). The read model moves them
  /// back to pending once the revert is projected; the debounced scan, or
  /// the next periodic one, picks them up from there.
  void _handleConfirmationsReverted(TransactionConfirmationsRevertedMessage msg) {
    final txids = msg.txids.toSet();
    _recentlyConfirmed.removeWhere((key, _) => txids.contains(key.$2));
    for (final txid in txids) {
      _pendingProofs.remove(txid);
      _pendingBackoff.remove(txid);
    }
    _log.info('${msg.txids.length} confirmation(s) reverted; re-polling ARC');
    if (_stopped) return;
    _headerDebounceTimer?.cancel();
    _headerDebounceTimer = Timer(headerTriggerDebounce, () {
      _headerDebounceTimer = null;
      unawaited(_runScan());
    });
  }

  /// Handle transaction broadcast requests
  Future<void> _handleBroadcastTransaction(BroadcastTransactionMessage msg) async {

    if (_arcService == null) {
      context.sender?.tell(BroadcastFailedMessage(msg.txid, 'ARC service not available'));
      return;
    }

    try {
      // Broadcast transaction via ARC service
      final response = await _arcService!.submitTransaction(msg.txHex);

      // Notify wallet of successful broadcast
      final command = BroadcastTransactionCommand(
        walletId: msg.walletId,
        transactionId: msg.txid,
        signedTransaction: msg.txHex,
        broadcastResponse: response.status.wireName,
      );
      _walletManager.tell(WalletCommandMessage(msg.walletId, command));

      // Update transaction status based on ARC's initial response
      _updateTransactionStatusFromArc(msg.walletId, msg.txid, response.status);
      await _onSubmitResponse(msg.walletId, msg.txid, msg.txHex, response);

      context.sender?.tell(_submitReply(msg.txid, response));

    } catch (e) {
      _log.warning('Broadcast failed for ${msg.txid}${msg.retryOnFailure ? ', queueing for retry' : ''}: $e');
      final queued = msg.retryOnFailure && await _enqueueForRetry(msg.txid, msg.walletId, msg.txHex);
      context.sender?.tell(BroadcastFailedMessage(msg.txid, e.toString(), willRetry: queued));
    }
  }

  /// Handle BEEF broadcast requests
  Future<void> _handleBroadcastBEEF(BroadcastBEEFMessage msg) async {

    if (_arcService == null) {
      context.sender?.tell(BroadcastFailedMessage(msg.txid, 'ARC service not available'));
      return;
    }

    // Extract raw payment tx hex before try block so it's available in catch
    String? paymentTxHex;

    try {
      // 1. Extract the payment transaction (last tx) and ancestors from BEEF
      final beef = BEEF.parse(Uint8List.fromList(hex.decode(msg.beefHex)));

      if (beef.txs.isEmpty) {
        throw Exception('BEEF contains no transactions');
      }

      // The payment transaction is the last one in the BEEF
      final paymentTxData = beef.txs.last;
      paymentTxHex = hex.encode(paymentTxData);
      final paymentTx = dartsv.Transaction.fromHex(paymentTxHex);


      // 2. Build a map of ancestor transactions for UTXO lookup
      final ancestorTxMap = <String, dartsv.Transaction>{};
      for (int i = 0; i < beef.txs.length - 1; i++) {
        final ancestorTxHex = hex.encode(beef.txs[i]);
        final ancestorTx = dartsv.Transaction.fromHex(ancestorTxHex);
        final ancestorTxid = ancestorTx.id;
        ancestorTxMap[ancestorTxid] = ancestorTx;
      }


      // // 3. Convert payment transaction to Extended Format (EF)
      // final extendedFormatTxHex = _convertToExtendedFormat(
      //   paymentTx,
      //   ancestorTxMap,
      // );
      //

      // 4a (deferred) Broadcast Extended Format transaction via ARC service
      // 4b (deferred) Broadcast Raw Format transaction via ARC service. Extended format seems still not supported by Arc API

      final response = await _arcService!.submitTransaction(paymentTxHex);

      final command = BroadcastTransactionCommand(
        walletId: msg.walletId,
        transactionId: msg.txid,
        signedTransaction: msg.beefHex,
        broadcastResponse: response.status.wireName,
      );
      _walletManager.tell(WalletCommandMessage(msg.walletId, command));

      // Update transaction status based on ARC's initial response
      _updateTransactionStatusFromArc(msg.walletId, msg.txid, response.status);
      await _onSubmitResponse(msg.walletId, msg.txid, paymentTxHex, response);

      context.sender?.tell(_submitReply(msg.txid, response));

    } catch (e) {
      _log.warning('BEEF broadcast failed for ${msg.txid}, queueing for retry: $e');
      final queued = paymentTxHex != null && await _enqueueForRetry(msg.txid, msg.walletId, paymentTxHex);
      context.sender?.tell(BroadcastFailedMessage(msg.txid, e.toString(), willRetry: queued));
    }
  }

  /// The reply to a submission of [txid] that ARC answered with [response].
  ///
  /// ARC answers REJECTED with an HTTP 200, like any other status, so an
  /// answer is not a success by arriving (bead libspiffy-pq5e): this used to
  /// reply [BroadcastSuccessMessage] to every one, and a channel whose
  /// funding the network refused went on to mark the funding inputs spent.
  /// A definitive failure is a [BroadcastFailedMessage]; every other status
  /// is a success that says which status it is.
  ActorResponse _submitReply(String txid, ArcSubmitResponse response) {
    final status = response.status.wireName;
    if (DeferredNetworkStatus.isDefinitiveFailure(status)) {
      final detail = response.message;
      return BroadcastFailedMessage(
        txid,
        'ARC rejected $txid${detail == null || detail.isEmpty ? '' : ': $detail'}',
        networkStatus: status,
      );
    }
    return BroadcastSuccessMessage(txid, response.txid, networkStatus: status);
  }

  /// Stops starting work and waits for the work in flight (bead
  /// libspiffy-vr89): the host closes the retry queue's Isar store after
  /// shutdown, and a write into a closed store crashes the process (SEGV in
  /// libisar), not merely fails. Handlers run one at a time, so every
  /// submission received before this is finished, its enqueue included; the
  /// status scan runs off the mailbox on a timer, so it is awaited.
  Future<void> _stopWork() async {
    _stopped = true;
    _statusCheckTimer?.cancel();
    _headerDebounceTimer?.cancel();
    for (final timer in _spendRechecks.values) {
      timer.cancel();
    }
    _spendRechecks.clear();
    await _scanDone?.future;
    _log.info('ARC work stopped: nothing in flight, nothing more will be started');
  }

  /// Enqueue a failed broadcast for durable retry; whether it was queued.
  /// Nothing is queued once the actor is stopping: the store may be closed
  /// next, and the caller is told `willRetry: false` rather than promised a
  /// retry that could crash the process.
  Future<bool> _enqueueForRetry(String txid, String walletId, String rawTxHex) async {
    if (_stopped) {
      _log.warning('Not queueing transaction $txid for retry: ARCActor is stopping');
      return false;
    }
    if (_broadcastQueue == null) {
      _log.warning('Broadcast retry queue not available — transaction $txid will not be retried');
      return false;
    }

    try {
      await _broadcastQueue!.enqueue({
        'txid': txid,
        'walletId': walletId,
        'rawTxHex': rawTxHex,
      });
      _log.info('Queued transaction $txid for broadcast retry');
      return true;
    } catch (e) {
      _log.warning('Failed to enqueue transaction $txid for retry: $e');
      return false;
    }
  }

  /// Process the durable broadcast retry queue
  ///
  /// Called from the 30-second status check timer. Duraq handles backoff timing —
  /// entries whose nextRetryAt hasn't arrived yet are skipped by processNext().
  /// After maxAttempts, duraq moves entries to the dead letter queue.
  Future<void> _processRetryQueue() async {
    if (_broadcastQueue == null || _arcService == null) return;

    try {
      final queueLength = await _broadcastQueue!.length;
      if (queueLength == 0) return;

      // Process up to 5 entries per cycle to avoid blocking; none once
      // stopping (the store may be closed next).
      for (int i = 0; i < 5 && !_stopped; i++) {
        final processed = await _broadcastQueue!.processNext((data) async {
          final txid = data['txid'] as String;
          final rawTxHex = data['rawTxHex'] as String;
          final walletId = data['walletId'] as String;

          _log.info('Retrying broadcast for transaction $txid');
          final response = await _arcService!.submitTransaction(rawTxHex);

          // Notify wallet aggregate of successful broadcast
          _walletManager.tell(WalletCommandMessage(walletId, BroadcastTransactionCommand(
            walletId: walletId,
            transactionId: txid,
            signedTransaction: rawTxHex,
            broadcastResponse: response.status.wireName,
          )));

          _log.info('Retry broadcast succeeded for $txid (status: ${_arcStatusToString(response.status)})');
          // As for a first submission: record ARC's answer and apply the
          // deferred spend if the transaction is already on the network.
          _updateTransactionStatusFromArc(walletId, txid, response.status);
          await _onSubmitResponse(walletId, txid, rawTxHex, response);
          // If this callback throws, duraq auto-retries with exponential backoff
        });

        // No more entries to process
        if (!processed) break;
      }
    } catch (e) {
      _log.warning('Error processing broadcast retry queue: $e');
    }
  }

  /// Handle transaction status check requests
  Future<void> _handleCheckTransactionStatus(CheckTransactionStatusMessage msg) async {

    if (_arcService == null) {
      context.sender?.tell(TransactionStatusMessage.failed(
        txid: msg.txid,
        error: 'ARC service not available',
      ));
      return;
    }

    try {
      // Query ARC service for transaction status
      final response = await _arcService!.getTransaction(msg.txid);

      final status = _arcStatusToString(response.status);

      // No confirmation count is reported (bead libspiffy-jc3h). ARC answers
      // with a status and a block height; it says nothing about depth, and
      // "6 because there is a height" was a fabricated number an app could
      // have thresholded on. The height below is the evidence, and a depth,
      // if one is wanted, is `tip height - blockHeight + 1`.
      final proofAvailable = response.status == ArcTransactionStatus.mined;

      context.sender?.tell(TransactionStatusMessage(
        txid: msg.txid,
        status: status,
        confirmations: null,
        blockHeight: response.blockHeight,
        proofAvailable: proofAvailable,
      ));

    } catch (e) {
      context.sender?.tell(TransactionStatusMessage.failed(
        txid: msg.txid,
        error: e.toString(),
      ));
    }
  }

  /// Handle merkle proof retrieval requests (NEW for SPV)
  Future<void> _handleRetrieveMerkleProof(RetrieveMerkleProofMessage msg) async {

    if (_arcService == null) {
      context.sender?.tell(MerkleProofMessage(
        txid: msg.txid,
        success: false,
        error: 'ARC service not available',
      ));
      return;
    }

    try {
      // Retrieve merkle proof from ARC service
      final proofResponse = await _arcService!.getMerkleProof(msg.txid);

      if (proofResponse != null) {
        // Never hand out a proof that contradicts our own header chain.
        final check = await checkBumpHexAgainstHeaders(
          txid: msg.txid,
          bumpHex: proofResponse.merklePath.length == 1 ? proofResponse.merklePath.single : '',
          headerAt: _storage.getBlockHeaderByHeight,
          claimedHeight: proofResponse.blockHeight,
        );
        if (check.status == ProofHeaderStatus.rootMismatch ||
            check.status == ProofHeaderStatus.malformed) {
          _log.severe('ARC proof for ${msg.txid} rejected: $check');
          context.sender?.tell(MerkleProofMessage(
            txid: msg.txid,
            success: false,
            error: 'Merkle proof from ARC does not match the local header chain: ${check.detail}',
          ));
          return;
        }

        // Convert to proof map format
        final proof = {
          'txid': proofResponse.txid,
          'blockHeight': proofResponse.blockHeight,
          'merkleRoot': proofResponse.merkleRoot,
          'merklePath': proofResponse.merklePath,
          'blockHash': check.blockHash ?? proofResponse.blockHash,
          'position': check.txIndex,
          'headerVerified': check.isVerified,
        };

        context.sender?.tell(MerkleProofMessage(
          txid: msg.txid,
          merkleProof: proof,
          success: true,
        ));

      } else {
        context.sender?.tell(MerkleProofMessage(
          txid: msg.txid,
          success: false,
          error: 'Transaction not confirmed yet - proof not available',
        ));

      }

    } catch (e) {
      context.sender?.tell(MerkleProofMessage(
        txid: msg.txid,
        success: false,
        error: e.toString(),
      ));
    }
  }

  /// Handle fee quote requests
  Future<void> _handleGetFeeQuote(GetFeeQuoteMessage msg) async {

    if (_arcService == null) {
      context.sender?.tell(FeeQuoteMessage.failed('ARC service not available'));
      return;
    }

    try {
      // Get policy from ARC service (includes fee rates)
      final policy = await _arcService!.getPolicy();

      // ARC publishes a single miningFee {satoshis, bytes}; it serves as
      // both the mining and the relay rate.
      final feeData = {
        'mining': {
          'satoshis': policy.miningFee.satoshis,
          'bytes': policy.miningFee.bytes,
        },
        'relay': {
          'satoshis': policy.miningFee.satoshis,
          'bytes': policy.miningFee.bytes,
        },
        'timestamp': DateTime.now().toIso8601String(),
      };

      context.sender?.tell(FeeQuoteMessage(feeData));

    } catch (e) {
      context.sender?.tell(FeeQuoteMessage.failed(e.toString()));
    }
  }

  /// Handle fee estimation requests.
  ///
  /// A policy ARC could not be asked for is answered as a failure, exactly
  /// as [_quotePolicyFee] answers one (bead libspiffy-8743). This used to
  /// catch the policy failure itself and fall back to an invented
  /// 1 sat/1000 bytes, so a caller was told **success** with a rate nothing
  /// published and could build a transaction at a fee no miner had quoted —
  /// and the honest failure reply bead libspiffy-97zj added was unreachable.
  /// A rate nobody published is not an estimate (spv-understanding.md: the
  /// library must not manufacture state it cannot evidence).
  Future<void> _handleEstimateFee(EstimateFeeMessage msg) async {
    if (_arcService == null) {
      context.sender?.tell(FeeEstimateMessage.failed('ARC service not available'));
      return;
    }
    try {
      // Estimate transaction size (P2PKH inputs: ~148 bytes, outputs: ~34 bytes, overhead: ~10 bytes)
      final estimatedSize = (msg.inputCount * 148) + (msg.outputCount * 34) + 10;
      final fee = (await _arcService!.getPolicy()).miningFee;

      // Rounded up: a truncated fee undercuts the policy.
      context.sender?.tell(FeeEstimateMessage(fee.feeFor(estimatedSize)));
    } catch (e) {
      context.sender?.tell(FeeEstimateMessage.failed("ARC's policy could not be read: $e"));
    }
  }

  /// ARC's policy fee for a transaction of [msg]'s shape (bead
  /// libspiffy-87a). Unlike [_handleEstimateFee] it does not fall back to a
  /// guessed rate: a policy ARC could not be asked for is answered as a
  /// failure, so a caller never builds a transaction at a fee nobody quoted.
  ///
  /// The policy fee is the whole fee. There is no replace-by-fee on this
  /// network, so nothing is ever added to outbid a conflicting transaction.
  Future<PolicyFeeQuote> _quotePolicyFee(EstimatePolicyFeeMessage msg) async {
    final sizeBytes = (msg.inputCount * 148) + (msg.outputCount * 34) + 10 + msg.dataSize;
    if (_arcService == null) {
      return PolicyFeeQuote(sizeBytes: sizeBytes, success: false, error: 'ARC service not available');
    }
    try {
      final fee = (await _arcService!.getPolicy()).miningFee;
      return PolicyFeeQuote(
        fee: fee.feeFor(sizeBytes),
        sizeBytes: sizeBytes,
        success: true,
        feeSatoshis: fee.satoshis,
        feeBytes: fee.bytes,
      );
    } catch (e) {
      return PolicyFeeQuote(
          sizeBytes: sizeBytes, success: false, error: "ARC's policy could not be read: $e");
    }
  }

  /// Check all non-terminal transactions against ARC.
  /// Queries storage for transactions in pending/broadcast/seenOnNetwork/orphaned states.
  Future<void> _checkNonTerminalTransactions() async {
    if (_arcService == null) return;

    try {
      // Query storage for all transactions that need monitoring
      final transactions = <BitcoinTransaction>[];
      for (final status in [
        TransactionStatus.pending,
        TransactionStatus.broadcast,
        TransactionStatus.seenOnNetwork,
        TransactionStatus.orphaned,
      ]) {
        transactions.addAll(await _storage.getTransactionsByStatus(status));
      }
      if (transactions.isEmpty) return;

      final now = DateTime.now();
      final pendingIds = <String>{};
      var checked = 0;
      for (final tx in transactions) {
        final walletId = tx.walletId;
        if (walletId == null || walletId.isEmpty) continue;
        if (_stopped) return;

        // Incremental: a pending transaction ARC knows nothing about (never
        // broadcast by us, or not yet by the counterparty) is re-queried
        // with back-off, not on every scan.
        final isPending = tx.status == TransactionStatus.pending;
        if (isPending) {
          pendingIds.add(tx.txid);
          final backoff = _pendingBackoff[tx.txid];
          if (backoff != null && now.isBefore(backoff.due)) continue;
        }

        checked++;
        _log.fine('  Checking tx ${tx.txid.substring(0, 8)}... stored=${tx.status.name} wallet=$walletId');
        final outcome = (await _checkAndUpdateTransactionStatus(tx.txid, walletId, tx.status)).outcome;

        if (isPending) {
          if (outcome == _CheckOutcome.changed) {
            _pendingBackoff.remove(tx.txid);
          } else {
            final misses = (_pendingBackoff[tx.txid]?.misses ?? 0) + 1;
            var wait = statusCheckInterval * (1 << (misses.clamp(1, 10)));
            if (wait > _maxPendingBackoff) wait = _maxPendingBackoff;
            _pendingBackoff[tx.txid] = _Backoff(DateTime.now().add(wait), misses);
          }
        }
      }
      // Forget back-off state of transactions that are no longer pending.
      _pendingBackoff.removeWhere((txid, _) => !pendingIds.contains(txid));
      if (checked > 0) {
        _log.info('Checked $checked of ${transactions.length} non-terminal transaction(s)');
      }
    } catch (e) {
      _log.warning('Failed to check non-terminal transactions: $e');
    }
  }

  /// Poll the recently failed transactions (bead libspiffy-5bju).
  ///
  /// ARC's REJECTED is not the last word: a competing spend can lose, the
  /// report can be stale, and a transaction of ours can be mined anyway. The
  /// main scan walks only the non-terminal states, so nothing ever asked
  /// about a failed row again — it took a proof arriving through SPV proof
  /// revival or an explicit CheckDeferredPaymentStatusCommand.
  ///
  /// Bounded three ways, because this is speculative work on a terminal
  /// state: it runs at most once per [failedCheckInterval] (much longer than
  /// [statusCheckInterval]), and each pass issues ONE indexed storage query
  /// that reads only the rows whose status changed within
  /// [failedCheckWindow], at most [failedCheckLimit] of them
  /// ([ReadModelStorage.getTransactionsByStatusSince]). It never reads a
  /// wallet's whole failed history, and never makes more than
  /// [failedCheckLimit] ARC queries per pass.
  ///
  /// A MINED answer confirms nothing by itself (V-55): [_handleMinedReport]
  /// confirms only on a merkle path that matches our own headers.
  Future<void> _checkRecentFailedTransactions() async {
    if (_arcService == null || failedCheckLimit <= 0 || _stopped) return;
    final now = _clock();
    final last = _lastFailedCheck;
    if (last != null && now.difference(last) < failedCheckInterval) return;
    _lastFailedCheck = now;

    try {
      final rows = await _storage.getTransactionsByStatusSince(
        TransactionStatus.failed,
        DateTime.now().subtract(failedCheckWindow),
        limit: failedCheckLimit,
      );
      var checked = 0;
      for (final tx in rows) {
        if (_stopped) return;
        final walletId = tx.walletId;
        if (walletId == null || walletId.isEmpty) continue;
        checked++;
        await _checkAndUpdateTransactionStatus(tx.txid, walletId, tx.status);
      }
      if (checked > 0) {
        _log.info('Re-checked $checked recently failed transaction(s) against ARC '
            '(window ${failedCheckWindow.inHours}h, cap $failedCheckLimit)');
      }
    } catch (e) {
      // The next pass reads the same window again.
      _log.warning('Failed to re-check recently failed transactions: $e');
    }
  }

  /// Check and update status for a specific transaction.
  /// Compares the current stored status with ARC's reported status and takes
  /// appropriate action on transitions (deferred spend, confirmation, orphan remediation).
  ///
  /// Deferred payments (bead libspiffy-7p2): the status is recorded in the
  /// wallet when it changed, or always when [explicit] (a user-requested
  /// check). REJECTED fails an outstanding deferred payment and releases its
  /// inputs; ARC not knowing the transaction (404) or failing to answer
  /// leaves the hold in place. DOUBLE_SPEND_ATTEMPTED is not final (bead
  /// libspiffy-ey2): recorded, the hold stays, and the transaction keeps
  /// being polled (a pending one moves to broadcast: ARC has it).
  Future<_StatusCheck> _checkAndUpdateTransactionStatus(String txid, String walletId, TransactionStatus currentStatus,
      {bool explicit = false}) async {
    if (_arcService == null) {
      return const _StatusCheck(_CheckOutcome.unknown, error: 'ARC service not available');
    }

    try {
      final ArcTransactionResponse response = await _arcService!.getTransaction(txid);
      final arcTxStatus = _arcStatusToTransactionStatus(response.status);
      final wireStatus = response.status.wireName;
      final competing = response.doubleSpendTxids ?? const <String>[];
      _log.info('  ARC reports: ${response.status} (mapped: ${arcTxStatus?.name}) for ${txid.substring(0, 8)}... (stored: ${currentStatus.name})');
      await _recordNetworkStatus(walletId, txid, wireStatus,
          explicit: explicit, blockHeight: response.blockHeight, detail: response.message, competingTxids: competing);

      // SEEN_IN_ORPHAN_MEMPOOL: Attempt remediation on every poll cycle
      if (response.status == ArcTransactionStatus.seenInOrphanMempool) {
        if (currentStatus != TransactionStatus.orphaned) {
          _updateTransactionStatusFromArc(walletId, txid, response.status);
        }
        _handleOrphanedTransaction(txid);
        return _StatusCheck(_CheckOutcome.changed, status: wireStatus);
      }

      // MINED: the transaction is on the network, so its deferred spend
      // applies now; confirm only once the proof checks out against our
      // headers.
      if (response.status == ArcTransactionStatus.mined) {
        _orphanRemediationAttempts.remove(txid);
        await _applyDeferredSpend(txid, walletId);
        final proofStatus = await _handleMinedReport(txid, walletId, response);
        return _StatusCheck(_CheckOutcome.changed,
            status: wireStatus, blockHeight: response.blockHeight, proofStatus: proofStatus);
      }

      // DOUBLE_SPEND_ATTEMPTED: a competing transaction spends an input, and
      // either may still be mined (bead libspiffy-ey2). Nothing is spent or
      // released; the transaction stays in the scan until ARC reports ours
      // on the network or rejected. A pending one is broadcast now (ARC has
      // it, so no back-off); a status past that is left as it is.
      if (response.status == ArcTransactionStatus.doubleSpendAttempted) {
        _log.warning('ARC reports a double spend attempt on $txid (competing: $competing); '
            'still polling, nothing released');
        final promote = currentStatus == TransactionStatus.pending;
        if (promote) _updateTransactionStatusFromArc(walletId, txid, response.status);
        return _StatusCheck(promote ? _CheckOutcome.changed : _CheckOutcome.unchanged,
            status: wireStatus, competingTxids: competing);
      }

      if (arcTxStatus == null) {
        return _StatusCheck(_CheckOutcome.unknown, status: wireStatus, competingTxids: competing);
      }
      // A report the stored row does not take is no change (bead
      // libspiffy-pkum, 7dj rule): e.g. ARC's status endpoint still answering
      // STORED for a transaction already seen on the network. Sending it
      // anyway journaled a status update the projection ignores on every
      // scan, and counted as progress for the pending back-off.
      final changed = arcTxStatus != currentStatus && TransactionRowRules.setsStatus(currentStatus, arcTxStatus);
      if (changed) {
        // Update the transaction status in the wallet
        _updateTransactionStatusFromArc(walletId, txid, response.status);
      }

      // SEEN_ON_NETWORK: mark inputs spent and outputs available. Also when
      // the stored status already is SEEN_ON_NETWORK (the submit response
      // said so, 09k): the spend is applied from what the read model still
      // shows outstanding, not from a status transition.
      if (response.status == ArcTransactionStatus.seenOnNetwork) {
        _orphanRemediationAttempts.remove(txid);
        await _applyDeferredSpend(txid, walletId);
      }

      return _StatusCheck(changed ? _CheckOutcome.changed : _CheckOutcome.unchanged,
          status: wireStatus, competingTxids: competing);
    } catch (e) {
      if (e is ArcException && e.isNotFound) {
        // Not known to ARC (yet): the recipient may broadcast later. Not a
        // failure; the hold stays.
        await _recordNetworkStatus(walletId, txid, DeferredNetworkStatus.notFound, explicit: explicit);
        return const _StatusCheck(_CheckOutcome.unknown, status: DeferredNetworkStatus.notFound);
      }
      _log.warning('Failed to check transaction $txid: $e');
      return _StatusCheck(_CheckOutcome.unknown, error: e.toString());
    }
  }

  /// ARC says [txid] is MINED: verify its merkle path against the stored
  /// header at that height before confirming (SPV-09).
  Future<ProofHeaderStatus?> _handleMinedReport(String txid, String walletId, ArcTransactionResponse response) =>
      _handleMinedProof(txid, walletId, response.merklePathHex, response.blockHeight, response.blockHash);

  /// The result of the proof check, or null without a proof ([bumpHex]
  /// null). A confirmation issued within the reconfirm window counts as
  /// verified.
  Future<ProofHeaderStatus?> _handleMinedProof(
      String txid, String walletId, String? bumpHex, int? blockHeight, String? blockHash) async {
    if (_confirmedRecently(walletId, txid)) return ProofHeaderStatus.verified;
    if (bumpHex == null) {
      _log.warning('ARC reports $txid MINED without a merklePath; not confirming until a proof is available');
      return null;
    }
    return _applyProofCheck(txid, _PendingProof({walletId}, bumpHex, blockHeight), arcBlockHash: blockHash);
  }

  /// ARC answered a submission of [txid] (raw [txHex]) for [walletId] with
  /// [response]; the status command is already sent.
  ///
  /// SEEN_ON_NETWORK or MINED: the transaction is on the network, so its
  /// deferred spend applies now (09k). The status scan acts on transitions
  /// of the stored status, and a submit answer of SEEN_ON_NETWORK already
  /// set it. A MINED answer carrying a merkle path is checked against the
  /// headers like a MINED status report; without one the scan that
  /// [_updateTransactionStatusFromArc] scheduled fetches the proof.
  /// Any other status (rejected, double spend, orphan, still in flight)
  /// spends nothing.
  ///
  /// The status is recorded for a deferred payment ([explicit] for a
  /// user-requested broadcast); REJECTED fails it (bead libspiffy-7p2),
  /// DOUBLE_SPEND_ATTEMPTED keeps it held (bead libspiffy-ey2). Returns the
  /// proof check of a MINED answer.
  Future<ProofHeaderStatus?> _onSubmitResponse(String walletId, String txid, String txHex, ArcSubmitResponse response,
      {bool explicit = false}) async {
    await _recordNetworkStatus(walletId, txid, response.status.wireName,
        explicit: explicit,
        blockHeight: response.blockHeight,
        detail: response.message,
        competingTxids: response.doubleSpendTxids ?? const []);
    switch (response.status) {
      case ArcTransactionStatus.seenOnNetwork:
        await _applyDeferredSpend(txid, walletId, rawHex: txHex);
        return null;
      case ArcTransactionStatus.mined:
        await _applyDeferredSpend(txid, walletId, rawHex: txHex);
        if (response.merklePathHex != null) {
          return _handleMinedProof(txid, walletId, response.merklePathHex, response.blockHeight, response.blockHash);
        }
        return null;
      default:
        return null;
    }
  }

  /// Check a held or fresh proof against the headers and act on the result.
  Future<ProofHeaderStatus> _applyProofCheck(String txid, _PendingProof proof, {String? arcBlockHash}) async {
    final check = await checkBumpHexAgainstHeaders(
      txid: txid,
      bumpHex: proof.bumpHex,
      headerAt: _storage.getBlockHeaderByHeight,
      claimedHeight: proof.claimedHeight,
    );
    switch (check.status) {
      case ProofHeaderStatus.verified:
        if (arcBlockHash != null && arcBlockHash != check.blockHash) {
          _log.warning('ARC block hash $arcBlockHash for $txid differs from the local header '
              '${check.blockHash} at height ${check.blockHeight}; the local chain is used');
        }
        await _confirmVerified(txid, proof, check);
        break;
      case ProofHeaderStatus.headerUnknown:
        final held = _pendingProofs[txid];
        if (held == null) {
          _log.info('ARC reports $txid MINED at height ${check.blockHeight}; header not stored yet, '
              'confirmation deferred until it arrives');
        } else if (!identical(held, proof)) {
          // Another wallet's scan met the same transaction: confirm every
          // wallet once the header arrives, with the latest report.
          proof.walletIds.addAll(held.walletIds);
        }
        _pendingProofs[txid] = proof;
        break;
      case ProofHeaderStatus.rootMismatch:
        _pendingProofs.remove(txid);
        _log.severe('ARC proof for $txid does not match the local header at height '
            '${check.blockHeight}: ${check.detail}. Not confirming.');
        break;
      case ProofHeaderStatus.malformed:
        _pendingProofs.remove(txid);
        _log.severe('ARC proof for $txid is invalid: ${check.detail}. Not confirming.');
        break;
    }
    return check.status;
  }

  Future<void> _confirmVerified(String txid, _PendingProof proof, ProofHeaderCheck check) async {
    // Claim each (wallet, txid) synchronously so a concurrent scan / re-check
    // cannot confirm it a second time.
    final walletIds = [
      for (final walletId in proof.walletIds)
        if (!_confirmedRecently(walletId, txid)) walletId,
    ];
    final now = DateTime.now();
    for (final walletId in walletIds) {
      _recentlyConfirmed[(walletId, txid)] = now;
    }
    _recentlyConfirmed.removeWhere((_, at) => now.difference(at) > _minReconfirmWindow * 10);
    _pendingProofs.remove(txid);

    // The proof checked out against the local header just now. It is not
    // written to the read model here: it is journaled with the confirmation
    // (TransactionConfirmedEvent.bumpHex) and WalletProjection stores it from
    // the event, so the journal holds it (bead libspiffy-9ek). A proof of an
    // earlier block (orphaned by a reorganization) stays stored as orphaned.
    for (final walletId in walletIds) {
      _walletManager.tell(WalletCommandMessage(walletId, ConfirmTransactionCommand(
        walletId: walletId,
        txid: txid,
        blockHeight: check.blockHeight,
        blockHash: check.blockHash,
        bumpHex: proof.bumpHex,
      )));
      _log.info('Transaction $txid confirmed in wallet $walletId at height ${check.blockHeight} '
          '(proof verified against local header)');
    }
    // The deferred spend was applied when the MINED report arrived (the
    // scan or the submit response that carried this proof).
  }

  /// The deferred spend of [txid] in [walletId]: once a transaction is on
  /// the network (ARC reports SEEN_ON_NETWORK or MINED, on submit or in a
  /// status scan) its wallet inputs are spent and its wallet outputs become
  /// available. The one path for every such report (zvj part 3, 09k).
  ///
  /// Driven by what the read model still shows outstanding, not by a status
  /// transition, so it may run on every report: an input no longer unspent
  /// (or not the wallet's) and an output already available (or not the
  /// wallet's) are skipped, and a command sent within the last
  /// [_reconfirmWindow] is not repeated while the read model catches up.
  /// [rawHex] is the submitted transaction; otherwise the stored one is used.
  /// Nothing is deleted: spending is a status change of the UTXO row.
  ///
  /// The network can report a transaction before the read model holds its
  /// recording: ARC answers a submission in one round trip, the projection
  /// applies the recording when it gets to it. Its outputs are then not
  /// rows yet, and nothing here promotes them; the change used to wait for
  /// the next status scan, which asks ARC again for the answer it already
  /// gave (bead libspiffy-onh). So when the transaction's own row is
  /// missing, the spend is applied again from storage after
  /// [deferredSpendRecheckDelay], until the row appears -- the recording's
  /// outputs are journaled before its transaction row, so the row says they
  /// are there -- or until a periodic scan would have covered it anyway.
  Future<void> _applyDeferredSpend(String txid, String walletId, {String? rawHex, DateTime? reportedAt}) async {
    try {
      final stored = await _storage.getTransaction(txid, walletId: walletId);
      if (stored == null) _recheckSpendLater(txid, walletId, rawHex, reportedAt ?? DateTime.now());
      var txHex = rawHex;
      if (txHex == null || txHex.isEmpty) txHex = stored?.rawHex;
      if (txHex == null || txHex.isEmpty) return;
      final parsed = dartsv.Transaction.fromHex(txHex);
      // Unspent UTXOs only: a spent row needs nothing, and the unspent set
      // stays small while the spent history grows without bound.
      final unspent = {
        for (final u in await _storage.getUTXOs(walletId)) u.key: u,
      };
      final now = DateTime.now();
      _deferredSpendIssued.removeWhere((_, at) => now.difference(at) >= _reconfirmWindow);

      var spent = 0;
      for (final input in parsed.inputs) {
        final utxo = unspent['${input.prevTxnId}:${input.prevTxnOutputIndex}'];
        if (utxo == null || utxo.status == UTXOStatus.spent) continue;
        if (!_claimDeferredSpend(walletId, 'spend', utxo.key, now)) continue;
        _walletManager.tell(WalletCommandMessage(walletId, SpendUTXOCommand(
          walletId: walletId,
          utxoKey: utxo.key,
          spendingTxId: txid,
          fee: BigInt.zero,
        )));
        spent++;
      }

      var promoted = 0;
      for (var vout = 0; vout < parsed.outputs.length; vout++) {
        final utxo = unspent['$txid:$vout'];
        if (utxo == null || utxo.status == UTXOStatus.spent || utxo.status == UTXOStatus.available) continue;
        if (!_claimDeferredSpend(walletId, 'available', utxo.key, now)) continue;
        _walletManager.tell(WalletCommandMessage(walletId, MarkUTXOAvailableCommand(
          walletId: walletId,
          txid: txid,
          vout: vout,
        )));
        promoted++;
      }
      if (spent > 0 || promoted > 0) {
        _log.info('Transaction $txid on the network: marked $spent input(s) spent, '
            '$promoted output(s) available in wallet $walletId');
      }
    } catch (e) {
      _log.warning('Failed to apply the deferred spend of transaction $txid: $e');
    }
  }


  /// Applies the deferred spend of [txid] again after
  /// [deferredSpendRecheckDelay] ([_applyDeferredSpend]), unless one is
  /// already scheduled, the actor stopped, or a status scan has run since
  /// [reportedAt] would have: from then on the scan covers it.
  void _recheckSpendLater(String txid, String walletId, String? rawHex, DateTime reportedAt) {
    final key = (walletId, txid);
    if (_stopped || _spendRechecks.containsKey(key)) return;
    if (DateTime.now().difference(reportedAt) >= statusCheckInterval) return;
    _spendRechecks[key] = Timer(deferredSpendRecheckDelay, () {
      _spendRechecks.remove(key);
      if (_stopped) return;
      unawaited(_applyDeferredSpend(txid, walletId, rawHex: rawHex, reportedAt: reportedAt));
    });
  }

  // ==========================================================================
  // DEFERRED PAYMENTS (bead libspiffy-7p2)
  // ==========================================================================

  /// Records [status] of [txid] in [walletId]'s aggregate
  /// (RecordTransactionNetworkStatusCommand) when [txid] is a deferred
  /// payment there. A definitive failure or a contested status
  /// (DOUBLE_SPEND_ATTEMPTED) is always sent (the aggregate ignores a txid
  /// that is not a deferred payment, and one recorded before holds were
  /// journaled has no read-model row yet); any other status only
  /// when the read model has the payment, and, unless [explicit], only when
  /// it changed (or names a competing transaction the row does not list), so
  /// a scan of a wallet's other transactions does not load its aggregate.
  /// [competingTxids] are the ones ARC named with the status (bead
  /// libspiffy-pkum).
  Future<void> _recordNetworkStatus(String walletId, String txid, String status,
      {String source = 'arc',
      bool explicit = false,
      int? blockHeight,
      String? detail,
      List<String> competingTxids = const []}) async {
    try {
      if (!DeferredNetworkStatus.isDefinitiveFailure(status) && !DeferredNetworkStatus.isContested(status)) {
        final row = await _storage.getDeferredPayment(walletId, txid);
        if (row == null) return;
        if (!explicit &&
            row.lastNetworkStatus == status &&
            row.lastNetworkStatusSource == source &&
            row.competingTxids.toSet().containsAll(competingTxids)) {
          return;
        }
      }
      _walletManager.tell(WalletCommandMessage(walletId, RecordTransactionNetworkStatusCommand(
        walletId: walletId,
        txid: txid,
        networkStatus: status,
        source: source,
        checkedAt: DateTime.now(),
        blockHeight: blockHeight,
        explicit: explicit,
        detail: detail,
        competingTxids: competingTxids,
      )));
    } catch (e) {
      _log.warning('Could not record network status $status of $txid in wallet $walletId: $e');
    }
  }

  /// Checks [txid] now through [via] (see [CheckDeferredPaymentStatusMessage]).
  Future<DeferredPaymentNetworkResult> _checkDeferredPayment(
      String walletId, String txid, DeferredPaymentNetworkSource via) async {
    DeferredPaymentNetworkResult? arcResult;
    if (via != DeferredPaymentNetworkSource.dataSource) {
      final stored = (await _storage.getTransaction(txid, walletId: walletId))?.status ?? TransactionStatus.pending;
      final check = await _checkAndUpdateTransactionStatus(txid, walletId, stored, explicit: true);
      arcResult = DeferredPaymentNetworkResult(
        walletId: walletId,
        txid: txid,
        success: check.status != null,
        networkStatus: check.status,
        source: check.status != null ? 'arc' : null,
        blockHeight: check.blockHeight,
        proofStatus: check.proofStatus?.name,
        confirmed: check.proofStatus == ProofHeaderStatus.verified,
        error: check.error,
        competingTxids: check.competingTxids,
      );
      final arcKnows = arcResult.success && arcResult.networkStatus != DeferredNetworkStatus.notFound;
      if (via == DeferredPaymentNetworkSource.arc || arcKnows) return arcResult;
    }
    final fromDataSource = await _checkViaDataSource(walletId, txid);
    if (!fromDataSource.success && arcResult != null && arcResult.success) {
      // ARC answered (not found); the data source could not: ARC's answer stands.
      return DeferredPaymentNetworkResult(
        walletId: walletId,
        txid: txid,
        success: true,
        networkStatus: arcResult.networkStatus,
        source: 'arc',
        error: fromDataSource.error,
      );
    }
    if (!fromDataSource.success && arcResult?.error != null) {
      return DeferredPaymentNetworkResult(
        walletId: walletId,
        txid: txid,
        success: false,
        error: 'ARC: ${arcResult!.error}; data source: ${fromDataSource.error}',
      );
    }
    return fromDataSource;
  }

  /// Looks [txid] up in the configured data source. Known: the deferred
  /// spend applies; with a merkle proof, the proof is checked against the
  /// local headers like an ARC proof and confirms only when it matches (a
  /// data source's claim alone confirms nothing).
  Future<DeferredPaymentNetworkResult> _checkViaDataSource(String walletId, String txid) async {
    DeferredPaymentNetworkResult failure(String error) =>
        DeferredPaymentNetworkResult(walletId: walletId, txid: txid, success: false, error: error);
    final dataSource = _dataSource;
    if (dataSource == null) return failure('No blockchain data source is configured');

    final String rawHex;
    try {
      rawHex = await dataSource.getRawTransaction(txid);
    } catch (e) {
      if (e is DataSourceException && e.notFound) {
        await _recordNetworkStatus(walletId, txid, DeferredNetworkStatus.notFound,
            source: 'dataSource', explicit: true);
        return DeferredPaymentNetworkResult(
            walletId: walletId, txid: txid, success: true,
            networkStatus: DeferredNetworkStatus.notFound, source: 'dataSource');
      }
      return failure('Data source lookup failed: $e');
    }
    try {
      if (dartsv.Transaction.fromHex(rawHex).id != txid) {
        return failure('The data source returned a different transaction for $txid');
      }
    } catch (e) {
      return failure('The data source returned an unparseable transaction for $txid: $e');
    }

    // Known to the network: the spend applies (as for ARC SEEN_ON_NETWORK).
    await _applyDeferredSpend(txid, walletId, rawHex: rawHex);
    final stored = (await _storage.getTransaction(txid, walletId: walletId))?.status;
    if (stored != null && stored != TransactionStatus.seenOnNetwork && stored != TransactionStatus.confirmed) {
      _updateTransactionStatusFromArc(walletId, txid, ArcTransactionStatus.seenOnNetwork);
    }

    MerkleProofData? proofData;
    try {
      proofData = await dataSource.getMerkleProof(txid);
    } catch (e) {
      _log.fine('Data source has no merkle proof for $txid (unconfirmed or unavailable): $e');
    }
    if (proofData == null) {
      await _recordNetworkStatus(walletId, txid, DeferredNetworkStatus.seenOnNetwork,
          source: 'dataSource', explicit: true);
      return DeferredPaymentNetworkResult(
          walletId: walletId, txid: txid, success: true,
          networkStatus: DeferredNetworkStatus.seenOnNetwork, source: 'dataSource');
    }

    await _recordNetworkStatus(walletId, txid, DeferredNetworkStatus.mined,
        source: 'dataSource', explicit: true, blockHeight: proofData.blockHeight);
    ProofHeaderStatus? proofStatus;
    String? proofError;
    try {
      final bumpHex = TscConverter().convertToBump(proofData).toHex();
      proofStatus = await _handleMinedProof(txid, walletId, bumpHex, proofData.blockHeight, null);
    } catch (e) {
      proofStatus = ProofHeaderStatus.malformed;
      proofError = 'The data source merkle proof for $txid is invalid: $e';
      _log.severe(proofError);
    }
    return DeferredPaymentNetworkResult(
      walletId: walletId,
      txid: txid,
      success: true,
      networkStatus: DeferredNetworkStatus.mined,
      source: 'dataSource',
      blockHeight: proofData.blockHeight,
      proofStatus: proofStatus?.name,
      confirmed: proofStatus == ProofHeaderStatus.verified,
      error: proofError,
    );
  }

  /// Broadcasts a deferred payment through [BroadcastDeferredPaymentMessage.via]:
  /// the BEEF's unproven ancestors first (a failure there is logged, the
  /// source may know them already), then the payment. The answer is handled
  /// like any submit answer (spend, proof check, failure on REJECTED; the
  /// hold kept on DOUBLE_SPEND_ATTEMPTED). A failed ARC submission is queued
  /// for retry.
  Future<DeferredPaymentNetworkResult> _broadcastDeferredPayment(BroadcastDeferredPaymentMessage msg) async {
    final ancestors = <String>[];
    if (msg.beefHex != null && msg.beefHex!.isNotEmpty) {
      try {
        final beef = BEEF.parse(Uint8List.fromList(hex.decode(msg.beefHex!)));
        for (var i = 0; i < beef.txs.length; i++) {
          final proven = i < beef.hasMerkle.length && beef.hasMerkle[i];
          final txHex = hex.encode(beef.txs[i]);
          if (!proven && txHex != msg.rawTxHex) ancestors.add(txHex);
        }
      } catch (e) {
        _log.warning('BEEF of deferred payment ${msg.txid} does not parse; broadcasting the transaction alone: $e');
      }
    }

    String? arcError;
    if (msg.via != DeferredPaymentNetworkSource.dataSource && _arcService != null) {
      for (final ancestor in ancestors) {
        try {
          await _arcService!.submitTransaction(ancestor);
        } catch (e) {
          _log.info('Ancestor of deferred payment ${msg.txid} not accepted by ARC (it may know it already): $e');
        }
      }
      try {
        final response = await _arcService!.submitTransaction(msg.rawTxHex);
        _walletManager.tell(WalletCommandMessage(msg.walletId, BroadcastTransactionCommand(
          walletId: msg.walletId,
          transactionId: msg.txid,
          signedTransaction: msg.rawTxHex,
          broadcastResponse: response.status.wireName,
        )));
        _updateTransactionStatusFromArc(msg.walletId, msg.txid, response.status);
        final proofStatus = await _onSubmitResponse(msg.walletId, msg.txid, msg.rawTxHex, response, explicit: true);
        return DeferredPaymentNetworkResult(
          walletId: msg.walletId,
          txid: msg.txid,
          success: true,
          networkStatus: response.status.wireName,
          source: 'arc',
          blockHeight: response.blockHeight,
          proofStatus: proofStatus?.name,
          confirmed: proofStatus == ProofHeaderStatus.verified,
          error: DeferredNetworkStatus.isDefinitiveFailure(response.status.wireName) ||
                  DeferredNetworkStatus.isContested(response.status.wireName)
              ? response.message
              : null,
          competingTxids: response.doubleSpendTxids ?? const [],
        );
      } catch (e) {
        arcError = e.toString();
        _log.warning('ARC broadcast of deferred payment ${msg.txid} failed: $e');
      }
      if (msg.via == DeferredPaymentNetworkSource.arc) {
        await _enqueueForRetry(msg.txid, msg.walletId, msg.rawTxHex);
        return DeferredPaymentNetworkResult(
          walletId: msg.walletId,
          txid: msg.txid,
          success: false,
          willRetry: _broadcastQueue != null,
          error: arcError,
        );
      }
    } else if (msg.via == DeferredPaymentNetworkSource.arc) {
      return DeferredPaymentNetworkResult(
          walletId: msg.walletId, txid: msg.txid, success: false, error: 'ARC service not available');
    }

    final dataSource = _dataSource;
    if (dataSource == null) {
      return DeferredPaymentNetworkResult(
        walletId: msg.walletId,
        txid: msg.txid,
        success: false,
        error: [if (arcError != null) 'ARC: $arcError', 'No blockchain data source is configured'].join('; '),
      );
    }
    for (final ancestor in ancestors) {
      try {
        await dataSource.submitTransaction(ancestor);
      } catch (e) {
        _log.info('Ancestor of deferred payment ${msg.txid} not accepted by the data source: $e');
      }
    }
    String? dataSourceError;
    try {
      await dataSource.submitTransaction(msg.rawTxHex);
    } catch (e) {
      dataSourceError = e.toString();
    }
    // Accepted, or refused because the source already has it: the lookup
    // tells (and applies the spend and any proof exactly like a check).
    final check = await _checkViaDataSource(msg.walletId, msg.txid);
    final known = check.success && check.networkStatus != DeferredNetworkStatus.notFound;
    if (known) return check;
    return DeferredPaymentNetworkResult(
      walletId: msg.walletId,
      txid: msg.txid,
      success: false,
      networkStatus: check.networkStatus,
      source: check.source,
      error: [
        if (arcError != null) 'ARC: $arcError',
        'data source: ${dataSourceError ?? check.error ?? 'transaction not known after submission'}',
      ].join('; '),
    );
  }

  /// Re-check held MINED proofs against the headers stored since.
  Future<void> _recheckPendingProofs() async {
    if (_pendingProofs.isEmpty) return;
    for (final entry in List.of(_pendingProofs.entries)) {
      if (_stopped) return;
      // Skip entries a concurrent scan already resolved.
      if (!identical(_pendingProofs[entry.key], entry.value)) continue;
      await _applyProofCheck(entry.key, entry.value);
    }
  }

  /// Handle request to check all pending UTXOs from storage against Arc
  ///
  /// This is triggered when new block headers are received, to check if any
  /// pending UTXOs have been mined and need merkle proofs fetched.
  ///
  /// SPVActor sends one per stored header; the scan is debounced and runs
  /// outside the mailbox (A-M3).
  Future<void> _handleCheckStoragePendingUTXOs(CheckStoragePendingUTXOsMessage msg) async {
    await _onHeadersArrived();
  }

  /// Map an ARC status to a TransactionStatus enum value (for comparison).
  TransactionStatus? _arcStatusToTransactionStatus(ArcTransactionStatus arcStatus) {
    switch (arcStatus) {
      case ArcTransactionStatus.queued:
      case ArcTransactionStatus.received:
      case ArcTransactionStatus.stored:
      case ArcTransactionStatus.announcedToNetwork:
      case ArcTransactionStatus.requestedByNetwork:
      case ArcTransactionStatus.sentToNetwork:
      case ArcTransactionStatus.acceptedByNetwork:
        return TransactionStatus.broadcast;
      case ArcTransactionStatus.seenOnNetwork:
        return TransactionStatus.seenOnNetwork;
      case ArcTransactionStatus.mined:
        return TransactionStatus.confirmed;
      case ArcTransactionStatus.seenInOrphanMempool:
        return TransactionStatus.orphaned;
      case ArcTransactionStatus.doubleSpendAttempted:
        // Not final (bead libspiffy-ey2): ARC holds the transaction.
        return TransactionStatus.broadcast;
      case ArcTransactionStatus.rejected:
        return TransactionStatus.failed;
      default:
        return null;
    }
  }

  /// Map an ARC status to a TransactionStatus and send an update command to the wallet.
  void _updateTransactionStatusFromArc(String walletId, String txid, ArcTransactionStatus arcStatus) {
    final TransactionStatus? txStatus;
    switch (arcStatus) {
      case ArcTransactionStatus.queued:
      case ArcTransactionStatus.received:
      case ArcTransactionStatus.stored:
      case ArcTransactionStatus.announcedToNetwork:
      case ArcTransactionStatus.requestedByNetwork:
      case ArcTransactionStatus.sentToNetwork:
      case ArcTransactionStatus.acceptedByNetwork:
        txStatus = TransactionStatus.broadcast;
        break;
      case ArcTransactionStatus.seenOnNetwork:
        txStatus = TransactionStatus.seenOnNetwork;
        break;
      case ArcTransactionStatus.mined:
        // Not from ARC's word alone: confirmation goes through the verified
        // merkle-path check (_handleMinedReport) on the next scan (SPV-09).
        txStatus = null;
        unawaited(_runScan());
        break;
      case ArcTransactionStatus.seenInOrphanMempool:
        txStatus = TransactionStatus.orphaned;
        break;
      case ArcTransactionStatus.doubleSpendAttempted:
        // Not final (bead libspiffy-ey2): ARC holds the transaction and may
        // still mine it, so it stays in the status scan (a failed one is not
        // polled).
        txStatus = TransactionStatus.broadcast;
        break;
      case ArcTransactionStatus.rejected:
        txStatus = TransactionStatus.failed;
        break;
      default:
        txStatus = null;
    }

    if (txStatus != null) {
      _walletManager.tell(WalletCommandMessage(walletId, UpdateTransactionStatusCommand(
        walletId: walletId,
        txid: txid,
        newStatus: txStatus,
      )));
    }
  }

  /// Handle an orphaned transaction by finding and rebroadcasting its missing parent(s),
  /// then rebroadcasting the child once parents are accepted.
  ///
  /// When ARC reports SEEN_IN_ORPHAN_MEMPOOL, the child tx is valid but its parent
  /// wasn't found by the node. We:
  /// 1. Parse the child's inputs to discover parent txids
  /// 2. Rebroadcast each parent and verify it reaches at least SEEN_ON_NETWORK
  /// 3. Rebroadcast the child so ARC re-evaluates it with parents now available
  Future<void> _handleOrphanedTransaction(String txid) async {
    final attempts = _orphanRemediationAttempts[txid] ?? 0;
    if (attempts >= _maxOrphanRemediationAttempts) {
      _log.warning('Orphan remediation: giving up on $txid after $attempts attempts');
      return;
    }
    _orphanRemediationAttempts[txid] = attempts + 1;

    try {
      // 1. Get the orphaned child transaction from storage
      final childTx = await _storage.getTransaction(txid);
      if (childTx == null || childTx.rawHex.isEmpty) {
        _log.warning('Orphan remediation: child tx $txid not found in storage');
        return;
      }

      // 2. Parse to extract parent txids from inputs
      final parsed = dartsv.Transaction.fromHex(childTx.rawHex);
      final parentTxids = <String>{};
      _log.info('Orphan remediation: $txid has ${parsed.inputs.length} input(s)');
      for (int i = 0; i < parsed.inputs.length; i++) {
        final input = parsed.inputs[i];
        _log.info('Orphan remediation: $txid input[$i] = ${input.prevTxnId}:${input.prevTxnOutputIndex}');
        if (input.prevTxnId.isNotEmpty) {
          parentTxids.add(input.prevTxnId);
        }
      }

      if (parentTxids.isEmpty) {
        _log.warning('Orphan remediation: no parent txids found for $txid');
        return;
      }

      _log.info('Orphan remediation: $txid (attempt ${attempts + 1}/$_maxOrphanRemediationAttempts) '
          '— ${parentTxids.length} unique parent(s): $parentTxids');

      // 3. Check each parent's status; only broadcast if not yet accepted
      bool allParentsAccepted = true;
      for (final parentTxid in parentTxids) {
        try {
          // First check if parent is already accepted by the network
          bool parentAlreadyAccepted = false;
          try {
            final parentStatus = await _arcService!.getTransaction(parentTxid);
            _log.info('Orphan remediation: parent $parentTxid current status: '
                '${_arcStatusToString(parentStatus.status)}');
            if (_isAcceptedStatus(parentStatus.status)) {
              parentAlreadyAccepted = true;
              _log.info('Orphan remediation: parent $parentTxid already accepted — no rebroadcast needed');
            }
          } catch (e) {
            _log.info('Orphan remediation: parent $parentTxid not known to ARC ($e)');
          }

          if (!parentAlreadyAccepted) {
            // Parent not yet accepted — look up rawHex and broadcast
            final parentTx = await _storage.getTransaction(parentTxid);
            if (parentTx == null || parentTx.rawHex.isEmpty) {
              _log.info('Orphan remediation: parent $parentTxid not in local storage — skipping');
              allParentsAccepted = false;
              continue;
            }

            try {
              final submitResponse = await _arcService!.submitTransaction(parentTx.rawHex);
              _log.info('Orphan remediation: broadcast parent $parentTxid — '
                  'response: ${_arcStatusToString(submitResponse.status)}');
            } catch (e) {
              _log.warning('Orphan remediation: parent $parentTxid broadcast error: $e');
            }

            // Poll parent status until accepted or timeout
            final parentAccepted = await _waitForParentAcceptance(parentTxid);
            if (!parentAccepted) {
              _log.warning('Orphan remediation: parent $parentTxid not yet accepted by network');
              allParentsAccepted = false;
            }
          }
        } catch (e) {
          _log.warning('Orphan remediation: failed processing parent $parentTxid: $e');
          allParentsAccepted = false;
        }
      }

      // 4. Rebroadcast the child once all parents are accepted
      if (allParentsAccepted) {
        _log.info('Orphan remediation: all parents accepted, rebroadcasting child $txid');
        try {
          final response = await _arcService!.submitTransaction(childTx.rawHex);
          final newStatus = _arcStatusToString(response.status);
          _log.info('Orphan remediation: child $txid submit response — '
              'status: $newStatus, txid: ${response.txid}, message: ${response.message}');

          if (response.status != ArcTransactionStatus.seenInOrphanMempool) {
            _orphanRemediationAttempts.remove(txid);
            _log.info('Orphan remediation: $txid resolved');
          }
        } catch (e) {
          _log.warning('Orphan remediation: child $txid submit threw — $e');
          // Submit threw but parent is accepted; check child status directly
          try {
            final statusResp = await _arcService!.getTransaction(txid);
            final fallbackStatus = _arcStatusToString(statusResp.status);
            _log.info('Orphan remediation: child $txid status query — '
                'status: $fallbackStatus, blockHeight: ${statusResp.blockHeight}');
            if (_isAcceptedStatus(statusResp.status)) {
              _orphanRemediationAttempts.remove(txid);
              _log.info('Orphan remediation: $txid resolved via status check');
            }
          } catch (e2) {
            _log.warning('Orphan remediation: child $txid status query also failed — $e2');
          }
        }
      } else {
        _log.warning('Orphan remediation: not all parents accepted for $txid — '
            'deferring child rebroadcast to next cycle');
      }
    } catch (e) {
      _log.warning('Orphan remediation failed for $txid: $e');
    }
  }

  /// Poll ARC for a parent transaction's status until it reaches at least SEEN_ON_NETWORK.
  ///
  /// Returns true if parent is accepted (seen_on_network or mined), false on timeout.
  /// Polls up to 5 times with 2-second intervals (10 seconds max).
  Future<bool> _waitForParentAcceptance(String parentTxid) async {
    const maxPolls = 5;
    const pollInterval = Duration(seconds: 2);

    for (int i = 0; i < maxPolls; i++) {
      try {
        final response = await _arcService!.getTransaction(parentTxid);
        if (_isAcceptedStatus(response.status)) {
          _log.info('Orphan remediation: parent $parentTxid accepted (${response.status})');
          return true;
        }
        _log.info('Orphan remediation: parent $parentTxid status: ${response.status}, '
            'waiting... (${i + 1}/$maxPolls)');
      } catch (e) {
        _log.warning('Orphan remediation: failed to check parent $parentTxid status: $e');
      }
      await Future.delayed(pollInterval);
    }
    return false;
  }

  /// Whether a status indicates the transaction is accepted by the network
  bool _isAcceptedStatus(ArcTransactionStatus status) {
    return status == ArcTransactionStatus.seenOnNetwork ||
           status == ArcTransactionStatus.mined ||
           status == ArcTransactionStatus.acceptedByNetwork;
  }

  /// Convert ARC transaction status to string
  String _arcStatusToString(ArcTransactionStatus status) {
    switch (status) {
      case ArcTransactionStatus.queued:
        return 'queued';
      case ArcTransactionStatus.received:
        return 'received';
      case ArcTransactionStatus.stored:
        return 'stored';
      case ArcTransactionStatus.announcedToNetwork:
        return 'announced';
      case ArcTransactionStatus.requestedByNetwork:
        return 'requested';
      case ArcTransactionStatus.sentToNetwork:
        return 'sent';
      case ArcTransactionStatus.acceptedByNetwork:
        return 'accepted';
      case ArcTransactionStatus.seenInOrphanMempool:
        return 'seen_in_orphan_mempool';
      case ArcTransactionStatus.seenOnNetwork:
        return 'seen_on_network';
      case ArcTransactionStatus.mined:
        return 'mined';
      case ArcTransactionStatus.minedInStaleBlock:
        return 'mined_in_stale_block';
      case ArcTransactionStatus.rejected:
        return 'rejected';
      case ArcTransactionStatus.doubleSpendAttempted:
        return 'double_spend';
      default:
        return 'unknown';
    }
  }

  /// Send error response based on message type
  void _sendErrorResponse(dynamic message, String error) {
    switch (message) {
      case final BroadcastTransactionMessage msg:
        context.sender?.tell(BroadcastFailedMessage(msg.txid, error));
        break;
      case final BroadcastBEEFMessage msg:
        context.sender?.tell(BroadcastFailedMessage(msg.txid, error));
        break;
      case final CheckTransactionStatusMessage msg:
        context.sender?.tell(TransactionStatusMessage.failed(
          txid: msg.txid,
          error: error,
        ));
        break;
      case GetFeeQuoteMessage():
        context.sender?.tell(FeeQuoteMessage.failed(error));
        break;
      case EstimateFeeMessage():
        context.sender?.tell(FeeEstimateMessage.failed(error));
      case final EstimatePolicyFeeMessage msg:
        context.sender?.tell(PolicyFeeQuote(
            sizeBytes: (msg.inputCount * 148) + (msg.outputCount * 34) + 10 + msg.dataSize,
            success: false,
            error: error));
        break;
    }
  }

  @override
  void postStop() {
    _stopped = true;
    _statusCheckTimer?.cancel();
    _headerDebounceTimer?.cancel();
    for (final timer in _spendRechecks.values) {
      timer.cancel();
    }
    _spendRechecks.clear();
  }

}
