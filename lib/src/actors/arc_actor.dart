import 'dart:async';
import 'dart:typed_data';
import 'package:dactor/dactor.dart';
import 'package:convert/convert.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:buffer/buffer.dart';

import '../core/wallet_commands.dart';
import '../services/arc_service.dart';
import '../services/arc_service_config.dart';
import '../utils/beef.dart';
import 'wallet_messages.dart';

/// Actor that handles ARC service integration for transaction broadcasting and monitoring
class ARCActor extends Actor {
  final ActorRef _walletManager;
  final ArcServiceConfig? _arcConfig;
  
  // ARC service client
  ArcService? _arcService;
  
  // Transaction status tracking
  final Map<String, String> _transactionStatus = {}; // txid -> status
  final Map<String, String> _transactionToWallet = {}; // txid -> walletId
  
  // Periodic status checking
  Timer? _statusCheckTimer;

  ARCActor({
    required ActorRef walletManager,
    ArcServiceConfig? arcConfig,
  })  : _walletManager = walletManager,
        _arcConfig = arcConfig;

  @override
  void preStart() {
    print('ARCActor started');
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
          
        default:
          print('ARCActor received unknown message: ${message.runtimeType}');
      }
    } catch (e) {
      print('Error in ARCActor: $e');
      
      // Send error response for messages that expect responses
      if (context.sender != null) {
        _sendErrorResponse(message, e.toString());
      }
    }
  }

  /// Initialize ARC service integration
  void _initializeARCService() {
    print('Initializing ARC service integration...');
    
    if (_arcConfig != null) {
      _arcService = ArcService.fromConfig(_arcConfig);
      print('ARC service initialized with endpoint: ${_arcConfig.baseUrl}');
    } else {
      print('WARNING: ARC service not configured - using TAAL testnet default');
      _arcService = ArcService.fromConfig(ArcServiceConfig.taalTestnet);
      print('ARC service initialized with TAAL testnet (with API key)');
    }
  }

  /// Start periodic transaction status monitoring
  void _startStatusMonitoring() {
    _statusCheckTimer = Timer.periodic(Duration(seconds: 30), (timer) {
      _checkPendingTransactions();
    });
    
    print('Transaction status monitoring started');
  }

  /// Handle transaction broadcast requests
  Future<void> _handleBroadcastTransaction(BroadcastTransactionMessage msg) async {
    print('Broadcasting transaction ${msg.txid} for wallet ${msg.walletId}');
    
    if (_arcService == null) {
      print('ERROR: ARC service not initialized');
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
      
      print('Transaction ${msg.txid} broadcast successfully with status: ${response.status}');
      
    } catch (e) {
      print('Error broadcasting transaction ${msg.txid}: $e');
      context.sender?.tell(BroadcastFailedMessage(msg.txid, e.toString()));
    }
  }

  /// Handle BEEF broadcast requests
  Future<void> _handleBroadcastBEEF(BroadcastBEEFMessage msg) async {
    print('Broadcasting BEEF transaction ${msg.txid} for wallet ${msg.walletId}');
    
    if (_arcService == null) {
      print('ERROR: ARC service not initialized');
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
      
      print('Extracted payment transaction: ${msg.txid}');
      print('  Inputs: ${paymentTx.inputs.length}, Outputs: ${paymentTx.outputs.length}');
      
      // 2. Build a map of ancestor transactions for UTXO lookup
      final ancestorTxMap = <String, dartsv.Transaction>{};
      for (int i = 0; i < beef.txs.length - 1; i++) {
        final ancestorTxHex = hex.encode(beef.txs[i]);
        final ancestorTx = dartsv.Transaction.fromHex(ancestorTxHex);
        final ancestorTxid = ancestorTx.id;
        ancestorTxMap[ancestorTxid] = ancestorTx;
      }
      
      print('Built ancestor map with ${ancestorTxMap.length} transactions');
      
      // // 3. Convert payment transaction to Extended Format (EF)
      // final extendedFormatTxHex = _convertToExtendedFormat(
      //   paymentTx,
      //   ancestorTxMap,
      // );
      //
      // print('Converted to Extended Format: ${extendedFormatTxHex.length} chars');
      
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
      print('Transaction ${msg.txid} broadcast successfully with status: ${response.status}');
      
    } catch (e) {
      print('Error broadcasting transaction ${msg.txid}: $e');
      context.sender?.tell(BroadcastFailedMessage(msg.txid, e.toString()));
    }
  }

  /// Handle transaction status check requests
  Future<void> _handleCheckTransactionStatus(CheckTransactionStatusMessage msg) async {
    print('Checking status for transaction ${msg.txid}');
    
    if (_arcService == null) {
      print('ERROR: ARC service not initialized');
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
      print('Error checking status for ${msg.txid}: $e');
      context.sender?.tell(TransactionStatusMessage(
        txid: msg.txid,
        status: 'error',
      ));
    }
  }

  /// Handle merkle proof retrieval requests (NEW for SPV)
  Future<void> _handleRetrieveMerkleProof(RetrieveMerkleProofMessage msg) async {
    print('Retrieving merkle proof for transaction ${msg.txid}');
    
    if (_arcService == null) {
      print('ERROR: ARC service not initialized');
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
        
        print('Merkle proof retrieved successfully for ${msg.txid}');
      } else {
        context.sender?.tell(MerkleProofMessage(
          txid: msg.txid,
          success: false,
          error: 'Transaction not confirmed yet - proof not available',
        ));
        
        print('Merkle proof not available for ${msg.txid}');
      }
      
    } catch (e) {
      print('Error retrieving merkle proof for ${msg.txid}: $e');
      context.sender?.tell(MerkleProofMessage(
        txid: msg.txid,
        success: false,
        error: e.toString(),
      ));
    }
  }

  /// Handle fee quote requests
  Future<void> _handleGetFeeQuote(GetFeeQuoteMessage msg) async {
    print('Getting fee quote from ARC service');
    
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
      print('Error getting fee quote: $e');
      context.sender?.tell(FeeQuoteMessage({'error': e.toString()}));
    }
  }

  /// Handle fee estimation requests
  Future<void> _handleEstimateFee(EstimateFeeMessage msg) async {
    print('Estimating fee for ${msg.inputCount} inputs, ${msg.outputCount} outputs');
    
    try {
      // Estimate transaction size (P2PKH inputs: ~148 bytes, outputs: ~34 bytes, overhead: ~10 bytes)
      final estimatedSize = (msg.inputCount * 148) + (msg.outputCount * 34) + 10;
      
      // Try to get fee rate from Arc policy, fall back to 1 sat/KB default
      double feeRatePerKb = 1.0; // Default: 1 satoshi per kilobyte (current network standard)
      
      try {
        if (_arcService != null) {
          final policy = await _arcService!.getPolicy();
          feeRatePerKb = policy.standardFeePerKb;
          print('Using Arc policy fee rate: $feeRatePerKb sat/KB');
        }
      } catch (e) {
        print('Could not fetch Arc policy, using default fee rate: $feeRatePerKb sat/KB');
      }
      
      // Calculate fee: (size_in_bytes * fee_rate_per_kb) / 1000
      final estimatedFee = BigInt.from((estimatedSize * feeRatePerKb) ~/ 1000);
      
      context.sender?.tell(FeeEstimateMessage(estimatedFee));
      
    } catch (e) {
      print('Error estimating fee: $e');
      context.sender?.tell(FeeEstimateMessage(BigInt.zero));
    }
  }

  /// Periodically check status of pending transactions
  void _checkPendingTransactions() {
    final pendingTxids = _transactionStatus.entries
        .where((entry) => entry.value == 'broadcasted' || entry.value == 'pending')
        .map((entry) => entry.key)
        .toList();
    
    if (pendingTxids.isEmpty) return;
    
    print('Checking status of ${pendingTxids.length} pending transactions');
    
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
        print('Transaction $txid status changed: $previousStatus -> $newStatus');
        
        final walletId = _transactionToWallet[txid];
        if (walletId != null && response.status == ArcTransactionStatus.mined && response.blockHeight != null) {
          final command = UpdateUTXOConfirmationsCommand(
            walletId: walletId,
            utxoKey: txid,
            confirmations: 6, // Simplified - assume 6 confirmations when mined
            blockHeight: response.blockHeight!,
          );
          
          _walletManager.tell(WalletCommandMessage(walletId, command));
        }
      }
      
    } catch (e) {
      print('Error checking status for transaction $txid: $e');
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

  /// Convert a transaction to Extended Format (EF)
  /// 
  /// Extended Format adds the previous output script and value for each input,
  /// allowing nodes to validate without UTXO lookup.
  /// 
  /// Format: [version] [EF_MARKER] [for each input: prevOutScript + value] [rest of tx]
  /// EF_MARKER = 0x00000000EF (5 bytes)
  String _convertToExtendedFormat(
    dartsv.Transaction tx,
    Map<String, dartsv.Transaction> ancestorTxMap,
  ) {
    final buffer = ByteDataWriter();
    
    // 1. Write version (4 bytes, little endian)
    buffer.writeUint32(tx.version, Endian.little);
    
    // 2. Write EF marker: 0x00000000EF (5 bytes)
    buffer.writeUint8(0x00);
    buffer.writeUint8(0x00);
    buffer.writeUint8(0x00);
    buffer.writeUint8(0x00);
    buffer.writeUint8(0xEF);
    
    // 3. Write input count
    final inputCountVarint = dartsv.VarInt.fromInt(tx.inputs.length);
    buffer.write(inputCountVarint.encode());
    
    // 4. For each input, write: prevOutScript, value, and then standard input data
    for (final input in tx.inputs) {
      final prevTxid = input.prevTxnId;
      final prevVout = input.prevTxnOutputIndex;
      
      // Find the previous output from ancestor transactions
      final prevTx = ancestorTxMap[prevTxid];
      if (prevTx == null) {
        throw Exception('Previous transaction $prevTxid not found in ancestors');
      }
      
      if (prevVout >= prevTx.outputs.length) {
        throw Exception('Invalid output index $prevVout for transaction $prevTxid');
      }
      
      final prevOutput = prevTx.outputs[prevVout];
      
      // Write previous output script length and script
      final scriptHex = prevOutput.script.toHex();
      final scriptBytes = hex.decode(scriptHex);
      final scriptLengthVarint = dartsv.VarInt.fromInt(scriptBytes.length);
      buffer.write(scriptLengthVarint.encode());
      buffer.write(scriptBytes);
      
      // Write previous output value (8 bytes, little endian)
      buffer.writeUint64(prevOutput.satoshis.toInt(), Endian.little);
      
      // Write standard input data: prev txid (32 bytes) + prev vout (4 bytes)
      final prevTxidBytes = hex.decode(prevTxid);
      buffer.write(Uint8List.fromList(prevTxidBytes.reversed.toList())); // Reverse for little endian
      buffer.writeUint32(prevVout, Endian.little);
      
      // Write scriptSig length and scriptSig
      final scriptSigBytes = input.script?.buffer ?? Uint8List(0);
      final scriptSigLengthVarint = dartsv.VarInt.fromInt(scriptSigBytes.length);
      buffer.write(scriptSigLengthVarint.encode());
      buffer.write(scriptSigBytes);
      
      // Write sequence (4 bytes)
      buffer.writeUint32(input.sequenceNumber, Endian.little);
    }
    
    // 5. Write output count
    final outputCountVarint = dartsv.VarInt.fromInt(tx.outputs.length);
    buffer.write(outputCountVarint.encode());
    
    // 6. Write each output
    for (final output in tx.outputs) {
      // Write value (8 bytes, little endian)
      buffer.writeUint64(output.satoshis.toInt(), Endian.little);
      
      // Write scriptPubKey length and scriptPubKey
      final scriptPubKeyHex = output.script.toHex();
      final scriptPubKeyBytes = hex.decode(scriptPubKeyHex);
      final scriptPubKeyLengthVarint = dartsv.VarInt.fromInt(scriptPubKeyBytes.length);
      buffer.write(scriptPubKeyLengthVarint.encode());
      buffer.write(scriptPubKeyBytes);
    }
    
    // 7. Write locktime (4 bytes)
    buffer.writeUint32(tx.nLockTime, Endian.little);
    
    // Convert to hex string
    final efBytes = buffer.toBytes();
    return hex.encode(efBytes);
  }

  @override
  void postStop() {
    print('ARCActor stopped');
    _statusCheckTimer?.cancel();
  }

  // Helper methods
  int get trackedTransactionCount => _transactionStatus.length;
  String? getTransactionStatus(String txid) => _transactionStatus[txid];
} 