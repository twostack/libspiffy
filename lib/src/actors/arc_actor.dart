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

  const _StatusCheck(this.outcome, {this.status, this.blockHeight, this.proofStatus, this.error});
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

  static const Duration _maxPendingBackoff = Duration(minutes: 30);
  static const Duration _minReconfirmWindow = Duration(minutes: 2);

  bool _scanInFlight = false;
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
    BlockchainDataSource? dataSource,
  })  : _walletManager = walletManager,
        _storage = storage,
        _arcConfig = arcConfig,
        _arcService = arcService,
        _isar = isar,
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
      switch (message.runtimeType) {
        case BroadcastTransactionMessage:
          await _handleBroadcastTransaction(message as BroadcastTransactionMessage);
          break;

        case BroadcastBEEFMessage:
          await _handleBroadcastBEEF(message as BroadcastBEEFMessage);
          break;

        case CheckTransactionStatusMessage:
          await _handleCheckTransactionStatus(message as CheckTransactionStatusMessage);
          break;

        case RetrieveMerkleProofMessage:
          await _handleRetrieveMerkleProof(message as RetrieveMerkleProofMessage);
          break;

        case GetFeeQuoteMessage:
          await _handleGetFeeQuote(message as GetFeeQuoteMessage);
          break;

        case EstimateFeeMessage:
          await _handleEstimateFee(message as EstimateFeeMessage);
          break;

        case CheckStoragePendingUTXOsMessage:
          await _handleCheckStoragePendingUTXOs(message as CheckStoragePendingUTXOsMessage);
          break;

        case BlockHeaderStoredMessage:
          await _onHeadersArrived();
          break;

        case TransactionConfirmationsRevertedMessage:
          _handleConfirmationsReverted(message as TransactionConfirmationsRevertedMessage);
          break;

        case CheckDeferredPaymentStatusMessage:
          final check = message as CheckDeferredPaymentStatusMessage;
          context.sender?.tell(await _checkDeferredPayment(check.walletId, check.txid, check.via));
          break;

        case BroadcastDeferredPaymentMessage:
          context.sender?.tell(await _broadcastDeferredPayment(message as BroadcastDeferredPaymentMessage));
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

  /// Initialize ARC service integration
  void _initializeARCService() {
    // Skip if ARC service was already provided (e.g., mock for testing)
    if (_arcService != null) {
      return;
    }

    if (_arcConfig != null) {
      _arcService = ArcService.fromConfig(_arcConfig);
    } else {
      _arcService = ArcService.fromConfig(ArcServiceConfig.taalMainnet());
    }
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
    try {
      do {
        _rescanRequested = false;
        await _checkNonTerminalTransactions();
        if (fromTimer) await _processRetryQueue();
      } while (_rescanRequested && !_stopped);
    } finally {
      _scanInFlight = false;
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
      );
      _walletManager.tell(WalletCommandMessage(msg.walletId, command));

      // Update transaction status based on ARC's initial response
      _updateTransactionStatusFromArc(msg.walletId, msg.txid, response.status);
      await _onSubmitResponse(msg.walletId, msg.txid, msg.txHex, response);

      // Send success response
      context.sender?.tell(BroadcastSuccessMessage(msg.txid, response.txid));

    } catch (e) {
      _log.warning('Broadcast failed for ${msg.txid}, queueing for retry: $e');
      await _enqueueForRetry(msg.txid, msg.walletId, msg.txHex);
      context.sender?.tell(BroadcastFailedMessage(msg.txid, e.toString()));
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
      );
      _walletManager.tell(WalletCommandMessage(msg.walletId, command));

      // Update transaction status based on ARC's initial response
      _updateTransactionStatusFromArc(msg.walletId, msg.txid, response.status);
      await _onSubmitResponse(msg.walletId, msg.txid, paymentTxHex, response);

      context.sender?.tell(BroadcastSuccessMessage(msg.txid, response.txid));

    } catch (e) {
      _log.warning('BEEF broadcast failed for ${msg.txid}, queueing for retry: $e');
      if (paymentTxHex != null) {
        await _enqueueForRetry(msg.txid, msg.walletId, paymentTxHex);
      }
      context.sender?.tell(BroadcastFailedMessage(msg.txid, e.toString()));
    }
  }

  /// Enqueue a failed broadcast for durable retry
  Future<void> _enqueueForRetry(String txid, String walletId, String rawTxHex) async {
    if (_broadcastQueue == null) {
      _log.warning('Broadcast retry queue not available — transaction $txid will not be retried');
      return;
    }

    try {
      await _broadcastQueue!.enqueue({
        'txid': txid,
        'walletId': walletId,
        'rawTxHex': rawTxHex,
      });
      _log.info('Queued transaction $txid for broadcast retry');
    } catch (e) {
      _log.warning('Failed to enqueue transaction $txid for retry: $e');
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

      // Process up to 5 entries per cycle to avoid blocking
      for (int i = 0; i < 5; i++) {
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
      context.sender?.tell(TransactionStatusMessage(
        txid: msg.txid,
        status: 'error',
      ));
      return;
    }

    try {
      // Query ARC service for transaction status
      final response = await _arcService!.getTransaction(msg.txid);

      final status = _arcStatusToString(response.status);

      // Determine confirmations based on status and block height
      final confirmations = response.blockHeight != null ? 6 : 0; // Simplified
      final proofAvailable = response.status == ArcTransactionStatus.mined;

      context.sender?.tell(TransactionStatusMessage(
        txid: msg.txid,
        status: status,
        confirmations: confirmations,
        blockHeight: response.blockHeight,
        proofAvailable: proofAvailable,
      ));

    } catch (e) {
      context.sender?.tell(TransactionStatusMessage(
        txid: msg.txid,
        status: 'error',
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
      context.sender?.tell(FeeQuoteMessage({'error': 'ARC service not available'}));
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
      context.sender?.tell(FeeQuoteMessage({'error': e.toString()}));
    }
  }

  /// Handle fee estimation requests
  Future<void> _handleEstimateFee(EstimateFeeMessage msg) async {

    try {
      // Estimate transaction size (P2PKH inputs: ~148 bytes, outputs: ~34 bytes, overhead: ~10 bytes)
      final estimatedSize = (msg.inputCount * 148) + (msg.outputCount * 34) + 10;

      // ARC policy miningFee; fall back to 1 sat per 1000 bytes
      ArcFeeAmount fee = const ArcFeeAmount(satoshis: 1, bytes: 1000);

      try {
        if (_arcService != null) {
          final policy = await _arcService!.getPolicy();
          fee = policy.miningFee;
        }
      } catch (e) {
        _log.warning('Failed to get fee rate from Arc policy, using 1 sat/1000 bytes: $e');
      }

      // Rounded up: a truncated fee undercuts the policy.
      final estimatedFee = fee.feeFor(estimatedSize);

      context.sender?.tell(FeeEstimateMessage(estimatedFee));

    } catch (e) {
      context.sender?.tell(FeeEstimateMessage(BigInt.zero));
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

  /// Check and update status for a specific transaction.
  /// Compares the current stored status with ARC's reported status and takes
  /// appropriate action on transitions (deferred spend, confirmation, orphan remediation).
  ///
  /// Deferred payments (bead libspiffy-7p2): the status is recorded in the
  /// wallet when it changed, or always when [explicit] (a user-requested
  /// check). REJECTED and DOUBLE_SPEND_ATTEMPTED fail an outstanding deferred
  /// payment and release its inputs; ARC not knowing the transaction (404)
  /// or failing to answer leaves the hold in place.
  Future<_StatusCheck> _checkAndUpdateTransactionStatus(String txid, String walletId, TransactionStatus currentStatus,
      {bool explicit = false}) async {
    if (_arcService == null) {
      return const _StatusCheck(_CheckOutcome.unknown, error: 'ARC service not available');
    }

    try {
      final ArcTransactionResponse response = await _arcService!.getTransaction(txid);
      final arcTxStatus = _arcStatusToTransactionStatus(response.status);
      final wireStatus = arcWireStatus(response.status);
      _log.info('  ARC reports: ${response.status} (mapped: ${arcTxStatus?.name}) for ${txid.substring(0, 8)}... (stored: ${currentStatus.name})');
      await _recordNetworkStatus(walletId, txid, wireStatus,
          explicit: explicit, blockHeight: response.blockHeight, detail: response.message);

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

      if (arcTxStatus == null) return _StatusCheck(_CheckOutcome.unknown, status: wireStatus);
      final changed = arcTxStatus != currentStatus;
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

      return _StatusCheck(changed ? _CheckOutcome.changed : _CheckOutcome.unchanged, status: wireStatus);
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
  /// user-requested broadcast); REJECTED or DOUBLE_SPEND_ATTEMPTED fails it
  /// (bead libspiffy-7p2). Returns the proof check of a MINED answer.
  Future<ProofHeaderStatus?> _onSubmitResponse(String walletId, String txid, String txHex, ArcSubmitResponse response,
      {bool explicit = false}) async {
    await _recordNetworkStatus(walletId, txid, arcWireStatus(response.status),
        explicit: explicit, blockHeight: response.blockHeight, detail: response.message);
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
  Future<void> _applyDeferredSpend(String txid, String walletId, {String? rawHex}) async {
    try {
      var txHex = rawHex;
      if (txHex == null || txHex.isEmpty) {
        txHex = (await _storage.getTransaction(txid, walletId: walletId))?.rawHex;
      }
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


  // ==========================================================================
  // DEFERRED PAYMENTS (bead libspiffy-7p2)
  // ==========================================================================

  /// Records [status] of [txid] in [walletId]'s aggregate
  /// (RecordTransactionNetworkStatusCommand) when [txid] is a deferred
  /// payment there. A definitive failure is always sent (the aggregate
  /// ignores a txid that is not a deferred payment, and one recorded before
  /// holds were journaled has no read-model row yet); any other status only
  /// when the read model has the payment, and, unless [explicit], only when
  /// it changed, so a scan of a wallet's other transactions does not load
  /// its aggregate.
  Future<void> _recordNetworkStatus(String walletId, String txid, String status,
      {String source = 'arc', bool explicit = false, int? blockHeight, String? detail}) async {
    try {
      if (!DeferredNetworkStatus.isDefinitiveFailure(status)) {
        final row = await _storage.getDeferredPayment(walletId, txid);
        if (row == null) return;
        if (!explicit && row.lastNetworkStatus == status && row.lastNetworkStatusSource == source) return;
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
  /// like any submit answer (spend, proof check, failure on REJECTED /
  /// DOUBLE_SPEND_ATTEMPTED). A failed ARC submission is queued for retry.
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
        )));
        _updateTransactionStatusFromArc(msg.walletId, msg.txid, response.status);
        final proofStatus = await _onSubmitResponse(msg.walletId, msg.txid, msg.rawTxHex, response, explicit: true);
        return DeferredPaymentNetworkResult(
          walletId: msg.walletId,
          txid: msg.txid,
          success: true,
          networkStatus: arcWireStatus(response.status),
          source: 'arc',
          blockHeight: response.blockHeight,
          proofStatus: proofStatus?.name,
          confirmed: proofStatus == ProofHeaderStatus.verified,
          error: DeferredNetworkStatus.isDefinitiveFailure(arcWireStatus(response.status)) ? response.message : null,
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

  /// ARC's wire name of [status] (`SEEN_ON_NETWORK`, ...), as recorded for
  /// deferred payments.
  static String arcWireStatus(ArcTransactionStatus status) {
    switch (status) {
      case ArcTransactionStatus.queued:
        return 'QUEUED';
      case ArcTransactionStatus.received:
        return 'RECEIVED';
      case ArcTransactionStatus.stored:
        return 'STORED';
      case ArcTransactionStatus.announcedToNetwork:
        return 'ANNOUNCED_TO_NETWORK';
      case ArcTransactionStatus.requestedByNetwork:
        return 'REQUESTED_BY_NETWORK';
      case ArcTransactionStatus.sentToNetwork:
        return 'SENT_TO_NETWORK';
      case ArcTransactionStatus.acceptedByNetwork:
        return 'ACCEPTED_BY_NETWORK';
      case ArcTransactionStatus.seenInOrphanMempool:
        return DeferredNetworkStatus.seenInOrphanMempool;
      case ArcTransactionStatus.seenOnNetwork:
        return DeferredNetworkStatus.seenOnNetwork;
      case ArcTransactionStatus.doubleSpendAttempted:
        return DeferredNetworkStatus.doubleSpendAttempted;
      case ArcTransactionStatus.minedInStaleBlock:
        return 'MINED_IN_STALE_BLOCK';
      case ArcTransactionStatus.rejected:
        return DeferredNetworkStatus.rejected;
      case ArcTransactionStatus.mined:
        return DeferredNetworkStatus.mined;
      case ArcTransactionStatus.unknown:
        return 'UNKNOWN';
    }
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
      case ArcTransactionStatus.rejected:
      case ArcTransactionStatus.doubleSpendAttempted:
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
      case ArcTransactionStatus.rejected:
      case ArcTransactionStatus.doubleSpendAttempted:
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
    switch (message.runtimeType) {
      case BroadcastTransactionMessage:
        final msg = message as BroadcastTransactionMessage;
        context.sender?.tell(BroadcastFailedMessage(msg.txid, error));
        break;
      case BroadcastBEEFMessage:
        final msg = message as BroadcastBEEFMessage;
        context.sender?.tell(BroadcastFailedMessage(msg.txid, error));
        break;
      case CheckTransactionStatusMessage:
        final msg = message as CheckTransactionStatusMessage;
        context.sender?.tell(TransactionStatusMessage(
          txid: msg.txid,
          status: 'error',
        ));
        break;
      case GetFeeQuoteMessage:
        context.sender?.tell(FeeQuoteMessage({'error': error}));
        break;
      case EstimateFeeMessage:
        context.sender?.tell(FeeEstimateMessage(BigInt.zero));
        break;
    }
  }

  @override
  void postStop() {
    _stopped = true;
    _statusCheckTimer?.cancel();
    _headerDebounceTimer?.cancel();
  }

}
