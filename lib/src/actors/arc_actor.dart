import 'dart:async';
import 'dart:typed_data';
import 'package:dactor/dactor.dart';
import 'package:convert/convert.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:duraq/duraq.dart' as duraq;
import 'package:isar/isar.dart';
import 'package:logging/logging.dart';

import '../core/wallet_commands.dart';
import '../models/bitcoin_transaction.dart';

import '../services/arc_service.dart';
import '../services/arc_service_config.dart';
import '../storage/read_model_storage.dart';
import '../utils/beef.dart';
import 'wallet_messages.dart';

/// Actor that handles ARC service integration for transaction broadcasting and monitoring
class ARCActor extends Actor {
  final _log = Logger('ARCActor');
  final ActorRef _walletManager;
  final ArcServiceConfig? _arcConfig;
  final ReadModelStorage _storage;
  final Isar? _isar;

  // ARC service client (dynamic to allow mock services in tests)
  dynamic _arcService;

  // Orphan remediation tracking (transient — OK to lose on restart)
  final Map<String, int> _orphanRemediationAttempts = {}; // txid -> attempt count
  static const int _maxOrphanRemediationAttempts = 3;

  // Periodic status checking
  Timer? _statusCheckTimer;

  // Durable broadcast retry queue (persisted via Isar)
  duraq.Queue<Map<String, dynamic>>? _broadcastQueue;

  ARCActor({
    required ActorRef walletManager,
    required ReadModelStorage storage,
    ArcServiceConfig? arcConfig,
    dynamic arcService,  // ← Allow injecting mock service for testing (dynamic for test mocks)
    Isar? isar,
  })  : _walletManager = walletManager,
        _storage = storage,
        _arcConfig = arcConfig,
        _arcService = arcService,
        _isar = isar;

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

        case RegisterTransactionOutputsMessage:
          _handleRegisterOutputs(message as RegisterTransactionOutputsMessage);
          break;

        case RegisterTransactionInputsMessage:
          _handleRegisterInputs(message as RegisterTransactionInputsMessage);
          break;

        case CheckStoragePendingUTXOsMessage:
          await _handleCheckStoragePendingUTXOs(message as CheckStoragePendingUTXOsMessage);
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
      final isarStorage = duraq.IsarStorage(_isar!);
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
    _statusCheckTimer = Timer.periodic(Duration(seconds: 30), (timer) {
      _checkNonTerminalTransactions();
      _processRetryQueue();
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
        // Convert to proof map format
        final proof = {
          'txid': proofResponse.txid,
          'blockHeight': proofResponse.blockHeight,
          'merkleRoot': proofResponse.merkleRoot,
          'merklePath': proofResponse.merklePath,
          'blockHash': proofResponse.blockHash,
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

      final feeData = {
        'mining': {
          'satoshis': policy.standardFeePerKb.toInt(),
          'bytes': 1000
        },
        'relay': {
          'satoshis': policy.minFeePerKb.toInt(),
          'bytes': 1000
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

      // Try to get fee rate from Arc policy, fall back to 1 sat/KB default
      double feeRatePerKb = 1.0; // Default: 1 satoshi per kilobyte (current network standard)

      try {
        if (_arcService != null) {
          final policy = await _arcService!.getPolicy();
          feeRatePerKb = policy.standardFeePerKb;
        }
      } catch (e) {
        _log.warning('Failed to get fee rate from Arc policy: $e');
      }

      // Calculate fee: (size_in_bytes * fee_rate_per_kb) / 1000
      final estimatedFee = BigInt.from((estimatedSize * feeRatePerKb) ~/ 1000);

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

      _log.info('Checking ${transactions.length} non-terminal transaction(s)');
      for (final tx in transactions) {
        final walletId = tx.walletId;
        if (walletId == null || walletId.isEmpty) continue;
        _log.info('  Checking tx ${tx.txid.substring(0, 8)}... stored=${tx.status.name} wallet=$walletId');
        await _checkAndUpdateTransactionStatus(tx.txid, walletId, tx.status);
      }
    } catch (e) {
      _log.warning('Failed to check non-terminal transactions: $e');
    }
  }

  /// Check and update status for a specific transaction.
  /// Compares the current stored status with ARC's reported status and takes
  /// appropriate action on transitions (deferred spend, confirmation, orphan remediation).
  Future<void> _checkAndUpdateTransactionStatus(String txid, String walletId, TransactionStatus currentStatus) async {
    if (_arcService == null) return;

    try {
      final response = await _arcService!.getTransaction(txid);
      final arcTxStatus = _arcStatusToTransactionStatus(response.status);
      _log.info('  ARC reports: ${response.status} (mapped: ${arcTxStatus?.name}) for ${txid.substring(0, 8)}... (stored: ${currentStatus.name})');

      // SEEN_IN_ORPHAN_MEMPOOL: Attempt remediation on every poll cycle
      if (response.status == ArcTransactionStatus.seenInOrphanMempool) {
        if (currentStatus != TransactionStatus.orphaned) {
          _updateTransactionStatusFromArc(walletId, txid, response.status);
        }
        _handleOrphanedTransaction(txid);
        return;
      }

      // Only act on status changes (comparing stored status with ARC status)
      if (arcTxStatus == null || arcTxStatus == currentStatus) return;

      // Update the transaction status in the wallet
      _updateTransactionStatusFromArc(walletId, txid, response.status);

      // SEEN_ON_NETWORK: Parse tx to mark inputs as spent and outputs as available
      if (response.status == ArcTransactionStatus.seenOnNetwork) {
        _orphanRemediationAttempts.remove(txid);

        final tx = await _storage.getTransaction(txid);
        if (tx != null && tx.rawHex.isNotEmpty) {
          final parsed = dartsv.Transaction.fromHex(tx.rawHex);

          // Mark input UTXOs as spent (deferred spend)
          for (final input in parsed.inputs) {
            if (input.prevTxnId.isNotEmpty) {
              final utxoKey = '${input.prevTxnId}:${input.prevTxnOutputIndex}';
              _walletManager.tell(WalletCommandMessage(walletId, SpendUTXOCommand(
                walletId: walletId,
                utxoKey: utxoKey,
                spendingTxId: txid,
                fee: BigInt.zero,
              )));
            }
          }

          // Mark output UTXOs as available for spending
          for (int i = 0; i < parsed.outputs.length; i++) {
            _walletManager.tell(WalletCommandMessage(walletId, MarkUTXOAvailableCommand(
              walletId: walletId,
              txid: txid,
              vout: i,
            )));
          }

          _log.info('Transaction $txid seen on network: marked ${parsed.inputs.length} input(s) spent, '
              '${parsed.outputs.length} output(s) available');
        }
      }

      // MINED: Confirm transaction and store merkle proof
      if (response.status == ArcTransactionStatus.mined && response.blockHeight != null) {
        _orphanRemediationAttempts.remove(txid);

        _walletManager.tell(WalletCommandMessage(walletId, ConfirmTransactionCommand(
          walletId: walletId,
          txid: txid,
          blockHeight: response.blockHeight,
          blockHash: response.blockHash,
        )));

        // Store merkle proof if available
        if (response.merklePath != null &&
            response.merklePath!.isNotEmpty &&
            response.blockHash != null) {
          try {
            await _storage.storeMerkleProof(txid, MerkleProof(
              txid: txid,
              blockHash: response.blockHash!,
              blockHeight: response.blockHeight!,
              merkleProof: response.merklePath!,
              position: 0,
            ));
          } catch (e) {
            _log.warning('Failed to store merkle proof for $txid: $e');
          }
        }
      }
    } catch (e) {
      _log.warning('Failed to check transaction $txid: $e');
    }
  }

  /// Handle registration of transaction outputs for tracking.
  /// Now a no-op — transaction monitoring is storage-backed.
  void _handleRegisterOutputs(RegisterTransactionOutputsMessage msg) {
    // No-op: outputs are parsed on demand from rawHex when needed
  }

  /// Handle registration of transaction inputs for deferred spending.
  /// Now a no-op — inputs are parsed on demand from rawHex when needed.
  void _handleRegisterInputs(RegisterTransactionInputsMessage msg) {
    // No-op: inputs are parsed on demand from rawHex when needed
  }

  /// Handle request to check all pending UTXOs from storage against Arc
  ///
  /// This is triggered when new block headers are received, to check if any
  /// pending UTXOs have been mined and need merkle proofs fetched.
  Future<void> _handleCheckStoragePendingUTXOs(CheckStoragePendingUTXOsMessage msg) async {

    // Delegate to the storage-backed check which covers all non-terminal transactions
    await _checkNonTerminalTransactions();
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
        txStatus = TransactionStatus.confirmed;
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
    _statusCheckTimer?.cancel();
  }

}
