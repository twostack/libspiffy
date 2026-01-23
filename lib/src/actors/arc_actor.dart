import 'dart:async';
import 'dart:typed_data';
import 'package:dactor/dactor.dart';
import 'package:convert/convert.dart';
import 'package:dartsv/dartsv.dart' as dartsv;

import '../core/wallet_commands.dart';
import '../models/bitcoin_utxo.dart';
import '../services/arc_service.dart';
import '../services/arc_service_config.dart';
import '../storage/read_model_storage.dart';
import '../utils/beef.dart';
import 'wallet_messages.dart';

/// Actor that handles ARC service integration for transaction broadcasting and monitoring
class ARCActor extends Actor {
  final ActorRef _walletManager;
  final ArcServiceConfig? _arcConfig;
  final ReadModelStorage _storage;
  
  // ARC service client (dynamic to allow mock services in tests)
  dynamic _arcService;
  
  // Transaction status tracking
  final Map<String, String> _transactionStatus = {}; // txid -> status
  final Map<String, String> _transactionToWallet = {}; // txid -> walletId
  final Map<String, List<int>> _transactionOutputs = {}; // txid -> [vout, vout, ...]
  
  // Periodic status checking
  Timer? _statusCheckTimer;

  ARCActor({
    required ActorRef walletManager,
    required ReadModelStorage storage,
    ArcServiceConfig? arcConfig,
    dynamic arcService,  // ← Allow injecting mock service for testing (dynamic for test mocks)
  })  : _walletManager = walletManager,
        _storage = storage,
        _arcConfig = arcConfig,
        _arcService = arcService;  // ← Use provided service if available (no cast needed)

  @override
  void preStart() {
    _initializeARCService();
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
      _arcService = ArcService.fromConfig(ArcServiceConfig.taalTestnet);
    }
  }

  /// Start periodic transaction status monitoring
  void _startStatusMonitoring() {
    _statusCheckTimer = Timer.periodic(Duration(seconds: 30), (timer) {
      _checkPendingTransactions();
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
      
      // Track transaction status
      _transactionStatus[msg.txid] = _arcStatusToString(response.status);
      _transactionToWallet[msg.txid] = msg.walletId;
      
      // Notify wallet of successful broadcast
      final command = BroadcastTransactionCommand(
        walletId: msg.walletId,
        transactionId: msg.txid,
        signedTransaction: msg.txHex,
      );
      _walletManager.tell(WalletCommandMessage(msg.walletId, command));
      
      // Send success response
      context.sender?.tell(BroadcastSuccessMessage(msg.txid, response.txid));
      

    } catch (e) {
      context.sender?.tell(BroadcastFailedMessage(msg.txid, e.toString()));
    }
  }

  /// Handle BEEF broadcast requests
  Future<void> _handleBroadcastBEEF(BroadcastBEEFMessage msg) async {

    if (_arcService == null) {
      context.sender?.tell(BroadcastFailedMessage(msg.txid, 'ARC service not available'));
      return;
    }
    
    try {
      // 1. Extract the payment transaction (last tx) and ancestors from BEEF
      final beef = BEEF.parse(Uint8List.fromList(hex.decode(msg.beefHex)));
      
      if (beef.txs.isEmpty) {
        throw Exception('BEEF contains no transactions');
      }
      
      // The payment transaction is the last one in the BEEF
      final paymentTxData = beef.txs.last;
      final paymentTxHex = hex.encode(paymentTxData);
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
      
      _transactionStatus[msg.txid] = _arcStatusToString(response.status);
      _transactionToWallet[msg.txid] = msg.walletId;
      
      final command = BroadcastTransactionCommand(
        walletId: msg.walletId,
        transactionId: msg.txid,
        signedTransaction: msg.beefHex,
      );
      _walletManager.tell(WalletCommandMessage(msg.walletId, command));
      
      context.sender?.tell(BroadcastSuccessMessage(msg.txid, response.txid));
      
    } catch (e) {
      context.sender?.tell(BroadcastFailedMessage(msg.txid, e.toString()));
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
      _transactionStatus[msg.txid] = status; // Update cache
      
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
      }
      
      // Calculate fee: (size_in_bytes * fee_rate_per_kb) / 1000
      final estimatedFee = BigInt.from((estimatedSize * feeRatePerKb) ~/ 1000);
      
      context.sender?.tell(FeeEstimateMessage(estimatedFee));
      
    } catch (e) {
      context.sender?.tell(FeeEstimateMessage(BigInt.zero));
    }
  }

  /// Periodically check status of pending transactions
  void _checkPendingTransactions() {
    // Check all transactions NOT in terminal states (mined/rejected)
    final pendingTxids = _transactionStatus.entries
        .where((entry) => 
            entry.value != 'mined' && 
            entry.value != 'rejected' &&
            entry.value != 'double_spend')
        .map((entry) => entry.key)
        .toList();
    
    if (pendingTxids.isEmpty) return;
    
    
    for (final txid in pendingTxids) {
      _checkAndUpdateTransactionStatus(txid);
    }
  }

  /// Check and update status for a specific transaction
  Future<void> _checkAndUpdateTransactionStatus(String txid) async {
    if (_arcService == null) return;
    
    try {
      // Query ARC service for transaction status
      final response = await _arcService!.getTransaction(txid);
      
      final newStatus = _arcStatusToString(response.status);
      final previousStatus = _transactionStatus[txid];
      
      if (newStatus != previousStatus) {
        _transactionStatus[txid] = newStatus;
        
        final walletId = _transactionToWallet[txid];
        if (walletId != null) {
          // SEEN_ON_NETWORK: Mark outputs as available for spending
          if (response.status == ArcTransactionStatus.seenOnNetwork) {
            final outputs = _transactionOutputs[txid];
            if (outputs != null) {
              for (final vout in outputs) {
                final command = MarkUTXOAvailableCommand(
                  walletId: walletId,
                  txid: txid,
                  vout: vout,
                );
                _walletManager.tell(WalletCommandMessage(walletId, command));
              }
            }
          }
          
          // MINED: Update transaction status and confirmations
          if (response.status == ArcTransactionStatus.mined && response.blockHeight != null) {
            // First, confirm the transaction itself
            final confirmTxCommand = ConfirmTransactionCommand(
              walletId: walletId,
              txid: txid,
              blockHeight: response.blockHeight,
              blockHash: response.blockHash,
            );
            _walletManager.tell(WalletCommandMessage(walletId, confirmTxCommand));
            
            // Store merkle proof if available
            if (response.merklePath != null && 
                response.merklePath!.isNotEmpty && 
                response.blockHash != null) {
              final merkleProof = MerkleProof(
                txid: txid,
                blockHash: response.blockHash!,
                blockHeight: response.blockHeight!,
                merkleProof: response.merklePath!,
                position: 0, // Position is encoded in BUMP format, using 0 as default
              );
              
              try {
                await _storage.storeMerkleProof(txid, merkleProof);
              } catch (e) {
              }
            }
            
            // Then update confirmations for each registered output
            final outputs = _transactionOutputs[txid];
            if (outputs != null) {
              for (final vout in outputs) {
                final utxoKey = '$txid:$vout';
                final command = UpdateUTXOConfirmationsCommand(
                  walletId: walletId,
                  utxoKey: utxoKey,
                  confirmations: 6, // Simplified - assume 6 confirmations when mined
                  blockHeight: response.blockHeight!,
                );
                
                _walletManager.tell(WalletCommandMessage(walletId, command));
              }
            }
          }
        }
      }
      
    } catch (e) {
    }
  }

  /// Handle registration of transaction outputs for tracking
  void _handleRegisterOutputs(RegisterTransactionOutputsMessage msg) {
    _transactionOutputs[msg.txid] = msg.vouts;
    
    // Also ensure we're tracking this transaction's wallet mapping
    if (!_transactionToWallet.containsKey(msg.txid)) {
      _transactionToWallet[msg.txid] = msg.walletId;
    }
    
    // CRITICAL: Initialize status to 'pending' so _checkPendingTransactions() will pick it up
    // This is especially important for recovery scenarios where transactions are re-registered
    if (!_transactionStatus.containsKey(msg.txid)) {
      _transactionStatus[msg.txid] = 'pending';
    }
  }

  /// Handle request to check all pending UTXOs from storage against Arc
  /// 
  /// This is triggered when new block headers are received, to check if any
  /// pending UTXOs have been mined and need merkle proofs fetched.
  Future<void> _handleCheckStoragePendingUTXOs(CheckStoragePendingUTXOsMessage msg) async {
    
    if (_arcService == null) {
      return;
    }
    
    try {
      // Get all wallet IDs from storage
      final walletIds = await _storage.getWalletIds();
      
      if (walletIds.isEmpty) {
        return;
      }
      
      // Collect all pending UTXOs across all wallets
      final pendingTxidsToCheck = <String, String>{}; // txid -> walletId
      
      for (final walletId in walletIds) {
        // Get all UTXOs (including non-spent) for this wallet
        final utxos = await _storage.getUTXOs(walletId, includeSpent: false);
        
        // Filter for pending UTXOs and collect unique txids
        for (final utxo in utxos) {
          if (utxo.status == UTXOStatus.pending) {
            // Only add if we don't already have this txid from another wallet
            if (!pendingTxidsToCheck.containsKey(utxo.txid)) {
              pendingTxidsToCheck[utxo.txid] = walletId;
              
              // Also register outputs for this txid if not already tracked
              if (!_transactionOutputs.containsKey(utxo.txid)) {
                _transactionOutputs[utxo.txid] = [utxo.vout];
              } else if (!_transactionOutputs[utxo.txid]!.contains(utxo.vout)) {
                _transactionOutputs[utxo.txid]!.add(utxo.vout);
              }
              
              // Ensure wallet mapping exists
              if (!_transactionToWallet.containsKey(utxo.txid)) {
                _transactionToWallet[utxo.txid] = walletId;
              }
            } else {
              // Same txid but different vout - add vout to outputs list
              if (!_transactionOutputs[utxo.txid]!.contains(utxo.vout)) {
                _transactionOutputs[utxo.txid]!.add(utxo.vout);
              }
            }
          }
        }
      }
      
      if (pendingTxidsToCheck.isEmpty) {
        return;
      }
      
      
      // Check each pending transaction with Arc
      for (final txid in pendingTxidsToCheck.keys) {
        await _checkAndUpdateTransactionStatus(txid);
      }
      
      
    } catch (e) {
    }
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
      case ArcTransactionStatus.seenOnNetwork:
        return 'seen_on_network';
      case ArcTransactionStatus.mined:
        return 'mined';
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

  // Helper methods
  int get trackedTransactionCount => _transactionStatus.length;
  String? getTransactionStatus(String txid) => _transactionStatus[txid];
} 