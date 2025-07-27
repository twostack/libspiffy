import 'dart:async';
import 'dart:typed_data';
import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart';
import 'package:dactor/dactor.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:spiffynode/spiffy_node.dart';

import '../core/wallet_commands.dart';
import '../storage/wallet_storage.dart';
import '../utils/beef.dart';
import '../utils/bump.dart';
import 'wallet_messages.dart';

/// Actor that handles true SPV validation - receives transactions from counterparties
/// and validates them using merkle proofs against the block header chain
/// 
/// This actor is responsible for:
/// - Direct transaction validation (NOT discovery)
/// - Merkle proof validation against stored block headers
/// - BEEF/BUMP transaction processing  
/// - Coordinating with WalletManagerActor for validated transactions
/// 
/// Note: Block header synchronization is handled by SpiffyNode, which stores
/// headers in WalletStorage. This actor consumes those stored headers for validation.
class SPVActor extends Actor {
  final ActorRef _walletManager;
  final WalletStorage _storage;
  
  int _currentHeight = 0;
  dynamic _currentTip;

  SPVActor({
    required ActorRef walletManager,
    required WalletStorage storage,
  }) : _walletManager = walletManager,
       _storage = storage;

  @override
  void preStart() {
    print('SPVActor started - True SPV Mode');
    _loadInitialState();
  }

  @override
  Future<void> onMessage(dynamic message) async {
    try {
      switch (message.runtimeType) {
        case ReceiveTransactionMessage:
          await _handleReceiveTransaction(message as ReceiveTransactionMessage);
          break;
          
        case BlockHeaderUpdateMessage:
          await _handleBlockHeaderUpdate(message as BlockHeaderUpdateMessage);
          break;
          
        case ValidateBEEFMessage:
          await _handleValidateBEEF(message as ValidateBEEFMessage);
          break;
          
        default:
          print('SPVActor received unknown message: ${message.runtimeType}');
      }
    } catch (e, stackTrace) {
      print('Error in SPVActor: $e');
      
      // Send error response for validation messages
      if (context.sender != null) {
        _sendErrorResponse(message, e.toString());
      }
    }
  }

  /// Load initial SPV state from storage
  /// 
  /// Note: Block header synchronization is handled by SpiffyNode, not the SPV actor.
  /// The SPV actor only consumes headers that SpiffyNode has already stored.
  void _loadInitialState() {
    print('Loading initial SPV state from storage...');
    
    // Load current chain state from storage (async)
    _loadCurrentChainState().then((_) {
      print('SPV Actor ready - current height: $_currentHeight');
      print('Ready to validate transactions using stored block headers');
    }).catchError((e) {
      print('Failed to load initial SPV state: $e');
      print('SPV Actor will start with empty state');
    });
  }
  
  /// Load current chain state from storage
  Future<void> _loadCurrentChainState() async {
    try {
      _currentHeight = await _storage.getBestHeight();
      final tip = await _storage.getChainTip();
      _currentTip = tip;
      print('Loaded chain state: height $_currentHeight');
    } catch (e) {
      print('Failed to load chain state: $e');
      _currentHeight = 0;
      _currentTip = null;
    }
  }

  /// Handle transaction received directly from counterparty (CORE SPV)
  Future<void> _handleReceiveTransaction(ReceiveTransactionMessage msg) async {
    print('Validating transaction from ${msg.fromCounterparty} for wallet ${msg.targetWalletId}');
    
    try {
      // This is the core SPV process
      final validationResult = await _validateReceivedTransaction(
        msg.transactionId,
        msg.beef,
        msg.targetWalletId,
      );
      
      // Send validation result to WalletManager
      _walletManager.tell(validationResult);
      
      // Also respond to sender if this was a request
      if (context.sender != null) {
        context.sender!.tell(validationResult);
      }
      
      print('Transaction validation complete: ${validationResult.isValid ? 'VALID' : 'INVALID'}');
      
    } catch (e) {
      print('Error validating transaction: $e');
      
      final errorResult = SPVValidationResult(
        txid: msg.transactionId, // Placeholder
        isValid: false,
        validationError: e.toString(),
        targetWalletId: msg.targetWalletId,
      );
      
      _walletManager.tell(errorResult);
      context.sender?.tell(errorResult);
    }
  }

  /// Retrieve Block header from storage (populated by SpiffyNode)
  Future<BlockHeader> _getBlockHeader(int blockHeight) async {
    try {
      final header = await _storage.getBlockHeaderByHeight(blockHeight);
      
      if (header == null) {
        throw Exception('Block header not found at height $blockHeight');
      }
      
      return header;
    } catch (e) {
      throw Exception('Failed to retrieve block header at height $blockHeight: $e');
    }
  }

  /// Validate received transaction using SPV principles
  /// Received transactions will be assumed as having a BEEF structure that
  /// links to (some) blockheader's merkle root
  Future<SPVValidationResult> _validateReceivedTransaction(
    String txidHex, //The TxId in the BEEF that should be validated
    BEEF beef,  //The BEEF containing the Transaction that should be validated
    String? walletId,
  ) async {
    print('Performing SPV validation...');


    final txid = Uint8List.fromList(hex.decode(txidHex));

    try {
      // Step 1: Validate each input UTXO has valid merkle proof
      // This should rely on the BEEF + block headers

      final txMap= beef.findTransactionByTxid(txid);

      if (txMap!= null){

        final bump = beef.bumps[txMap['index']];
        final blockHeader = await _getBlockHeader(bump.blockHeight);

        //check transaction's validatity against block header
        final isValidTx = await beef.validateTransactionWithBlockHeader(txid, blockHeader);

        if (!isValidTx) {
          return SPVValidationResult(
            txid: txidHex,
            isValid: false,
            validationError: 'Transaction not connected to existing blockheader',
            targetWalletId: walletId,
          );

        }

        // Step 2: Validate transaction structure and scripts
        final isTransactionValid = await _validateTransactionSpendsCorrectly(beef, txid);

        if (!isTransactionValid) {
          return SPVValidationResult(
            txid: txidHex,
            isValid: false,
            validationError: 'Invalid transaction structure',
            targetWalletId: walletId,
          );
        }

        // Step 3: Extract spendable UTXOs for the target wallet
        final transaction = dartsv.Transaction.fromHex(txMap['txData']);
        final spendableUTXOs = await _extractSpendableUTXOs(transaction, walletId);
        final spentUTXOs = await _extractSpentUTXOs(transaction, walletId);

        print('SPV Validation SUCCESS: ${spendableUTXOs.length} new UTXOs, ${spentUTXOs.length} spent UTXOs');

        return SPVValidationResult(
          txid: txidHex,
          isValid: true,
          spendableUTXOs: spendableUTXOs,
          spentUTXOs: spentUTXOs,
          targetWalletId: walletId,
        );


      }else{
        return SPVValidationResult(
          txid: txidHex,
          isValid: false,
          validationError: 'The referenced txid was not found in the BEEF structure',
          targetWalletId: walletId,
        );
      }

    } catch (e) {
      return SPVValidationResult(
        txid: txidHex,
        isValid: false,
        validationError: 'SPV validation failed: $e',
        targetWalletId: walletId,
      );
    }
  }

  /// Validate merkle proof against block header chain
  Future<bool> _validateMerkleProof(BEEF beef, String txid, BlockHeader blockHeader) async {
    print('Validating merkle proof for $txid');
    
    try {

      return await beef.validateTransactionWithBlockHeader(Uint8List.fromList(hex.decode(txid)), blockHeader);

    } catch (e) {
      print('Merkle proof validation failed: $e');
      return false;
    }
  }

  ///validate that the transaction's inputs are spending properly from their corresponding UTXOs
  ///The BEEF should have all input/funding transactions available or this method will fail
  Future<bool> _validateTransactionSpendsCorrectly(BEEF beef, Uint8List txid) async {

    // Validate basic BEEF structure
    if (!beef.validate()) {
      return false;
    } else {
      //verify the script execution first
      //setup the flags needed for script verification
      var scriptFlags = <dartsv.VerifyFlag>{}..addAll([
        dartsv.VerifyFlag.SIGHASH_FORKID,
        dartsv.VerifyFlag.UTXO_AFTER_GENESIS
      ]);

      final txMap = await beef.findTransactionByTxid(txid);

      if (txMap == null) return false;

      final txToBeValidated = dartsv.Transaction.fromHex(txMap['txData']);

      var interpreter = dartsv.Interpreter();
      try {
        final broadcastTxn = txToBeValidated;

        for (final input in broadcastTxn.inputs) {
          var inputIndex = 0;
          final scriptSig = input.script;

          final fundingTxMap = beef.findTransactionByTxid(Uint8List.fromList(hex.decode(input.prevTxnId)));

          if (fundingTxMap != null) {

            final fundingTxHex = hex.encode(fundingTxMap['txData']);

            final fundingTx = dartsv.Transaction.fromHex(fundingTxHex);
            final scriptPubKey = fundingTx.outputs[input.prevTxnOutputIndex].script;
            final lockedValue = fundingTx.outputs[input.prevTxnOutputIndex].satoshis;

            //run the input(s) through the interpreter to verify it
            interpreter.correctlySpends(
                scriptSig!, scriptPubKey, broadcastTxn, inputIndex, scriptFlags,
                dartsv.Coin.ofSat(lockedValue));
          }
          inputIndex++;
        }

        return true;

      } on dartsv.ScriptException catch (ex) {
        print(ex);
        return false;
      }
    }

  }

  /// Extract UTXOs we can spend from this transaction
  /// 
  /// This method analyzes transaction outputs to identify those that belong
  /// to the specified wallet and can be spent by it.
  Future<List<Map<String, dynamic>>> _extractSpendableUTXOs(dartsv.Transaction transaction, String? walletId) async {
    final spendableUTXOs = <Map<String, dynamic>>[];
    
    if (walletId == null) {
      return spendableUTXOs;
    }

    try {
      final templateRegistry = dartsv.ScriptTemplateRegistry();
      
      for (int outputIndex = 0; outputIndex < transaction.outputs.length; outputIndex++) {
        final output = transaction.outputs[outputIndex];
        final script = output.script;
        
        // Analyze script to determine if it belongs to our wallet
        final scriptInfo = templateRegistry.extractScriptInfo(script);
        final scriptType = templateRegistry.identifyScriptType(script);
        
        if (scriptInfo == null || scriptType == null) {
          // Skip unrecognized script types
          continue;
        }

        String? pubkeyHash;

        switch (scriptType) {
          case 'p2pkh':
          case 'p2pk': 
          case 'p2sh':
            pubkeyHash = scriptInfo['pubKeyHash'];
            break;
          case 'p2ms':
            // Multi-sig handling would require more complex logic
            // TODO: Implement multi-sig UTXO recognition
            continue;
          default:
            // Skip unknown script types
            continue;
        }

        if (pubkeyHash != null) {
          // TODO: Check if pubkeyHash belongs to walletId
          // This requires wallet key management integration
          final belongsToWallet = await _checkPubkeyHashOwnership(pubkeyHash, walletId);
          
          if (belongsToWallet) {
            spendableUTXOs.add({
              'txid': transaction.id,
              'outputIndex': outputIndex,
              'satoshis': output.satoshis.toInt(),
              'script': output.script?.toString(),
              'scriptType': scriptType,
              'pubkeyHash': pubkeyHash,
            });
          }
        }
      }
    } catch (e) {
      print('Error extracting spendable UTXOs: $e');
    }

    return spendableUTXOs;
  }
  
  /// Check if a pubkey hash belongs to the specified wallet
  /// TODO: This needs integration with wallet key management
  Future<bool> _checkPubkeyHashOwnership(String pubkeyHash, String walletId) async {
    // Placeholder implementation
    // In a real implementation, this would query the wallet's keys/addresses
    return false;
  }

  /// Extract UTXOs that were spent in this transaction
  /// 
  /// This method analyzes transaction inputs to identify UTXOs that belonged
  /// to the specified wallet and are being spent by this transaction.
  Future<List<Map<String, dynamic>>> _extractSpentUTXOs(dartsv.Transaction transaction, String? walletId) async {
    final spentUTXOs = <Map<String, dynamic>>[];
    
    if (walletId == null) {
      return spentUTXOs;
    }

    try {
      // For each input, we need to:
      // 1. Get the previous transaction output being spent
      // 2. Check if that output belongs to our wallet
      for (int inputIndex = 0; inputIndex < transaction.inputs.length; inputIndex++) {
        final input = transaction.inputs[inputIndex];
        final prevTxId = input.prevTxnId;
        final prevOutputIndex = input.prevTxnOutputIndex;

        try {
          // TODO: Retrieve the previous transaction to analyze the spent output
          // This requires either:
          // 1. Access to the BEEF data containing the funding transaction
          // 2. A transaction cache/storage lookup
          // 3. Network query (not recommended for SPV)
          
          final belongsToWallet = await _checkSpentUTXOOwnership(
            prevTxId, 
            prevOutputIndex, 
            walletId
          );
          
          if (belongsToWallet) {
            spentUTXOs.add({
              'prevTxId': prevTxId,
              'prevOutputIndex': prevOutputIndex,
              'inputIndex': inputIndex,
              'sequence': input.sequenceNumber,
            });
          }
        } catch (e) {
          print('Error analyzing input $inputIndex: $e');
          continue;
        }
      }
    } catch (e) {
      print('Error extracting spent UTXOs: $e');
    }

    return spentUTXOs;
  }
  
  /// Check if a spent UTXO belongs to the specified wallet
  /// TODO: This needs integration with UTXO storage and wallet management
  Future<bool> _checkSpentUTXOOwnership(String prevTxId, int prevOutputIndex, String walletId) async {
    // Placeholder implementation
    // In a real implementation, this would:
    // 1. Look up the UTXO in wallet storage
    // 2. Check if it belongs to the specified wallet
    return false;
  }

  /// Calculate transaction ID (TXID) from raw transaction data
  /// 
  /// Bitcoin transaction IDs are calculated as the double SHA256 hash
  /// of the raw transaction data, with bytes reversed (little-endian).
  String _calculateTransactionId(Uint8List transactionData) {
    // First SHA256
    final firstHash = sha256.convert(transactionData);
    
    // Second SHA256 (double hash)
    final secondHash = sha256.convert(firstHash.bytes);
    
    // Reverse bytes for little-endian representation
    final reversedBytes = secondHash.bytes.reversed.toList();

    // Convert to hex string
    return hex.encode(reversedBytes);
  }

  /// Handle block header updates from SpiffyNode
  Future<void> _handleBlockHeaderUpdate(BlockHeaderUpdateMessage msg) async {
    print('Updating block header chain: height ${msg.height}, reorg: ${msg.isReorganization}');

    //NOTE: BlockHeader-specific work is done by SpiffyNode. We handle
    //Transaction-related and wallet-related mitigations

    try {
      if (msg.isReorganization) {
        await _handleBlockchainReorganization(msg.orphanedHeaders ?? []);
      }
      
      // Update chain tip
      if (msg.height > _currentHeight) {
        _currentHeight = msg.height;
        _currentTip = msg.blockHeader;
      }
      
      print('Block header chain updated: current height $_currentHeight');
      
    } catch (e) {
      print('Error updating block header chain: $e');
    }
  }

  /// Handle blockchain reorganization
  Future<void> _handleBlockchainReorganization(List<dynamic> orphanedHeaders) async {
    print('Handling blockchain reorganization: ${orphanedHeaders.length} orphaned headers');

    //NOTE: BlockHeader-specific work is done by SpiffyNode. We handle
    //Transaction-related and wallet-related mitigations
    // TODO: Implement reorganization handling:
    // 1. Invalidate merkle proofs for transactions in orphaned blocks
    // 2. Notify WalletManager of affected transactions
    // 3. Request re-validation of affected transactions
    
    print('Blockchain reorganization handled (placeholder)');
  }

  /// Handle BEEF validation (enhanced transaction format)
  Future<void> _handleValidateBEEF(ValidateBEEFMessage msg) async {
    print('Validating BEEF data: ${msg.beefData.length} bytes');
    
    try {
      final beef = BEEF.parse(Uint8List.fromList(hex.decode(msg.beefData)));
      final isValid = beef.validate();

      if (!isValid) {
        context.sender?.tell(BEEFValidationResult(
          isValid: false,
          error: 'BEEF data failed validation check',
          targetWalletId: msg.targetWalletId,
        ));
        return; // Early return for invalid BEEF
      }

      // Extract transaction metadata from valid BEEF
      final extractedTransactions = <Map<String, dynamic>>[];
      
      // Parse BEEF structure to extract transaction information
      for (int i = 0; i < beef.txs.length; i++) {
        final txData = beef.txs[i];
        final txHex = hex.encode(txData);
        
        // Calculate transaction ID (double SHA256 of raw transaction data)
        final txid = _calculateTransactionId(txData);
        
        extractedTransactions.add({
          'transactionId': txid,           // The TXID for ReceiveTransactionMessage
          'transactionHex': txHex,         // The full transaction data
          'transactionIndex': i,           // Index in BEEF structure
          'dataSize': txData.length,       // Size in bytes
        });
      }
      
      final result = BEEFValidationResult(
        isValid: true,
        merkleRoot: 'placeholder_merkle_root', // TODO: Extract actual merkle root
        error: null,
        targetWalletId: msg.targetWalletId,
        extractedTransactions: extractedTransactions,
      );
      
      context.sender?.tell(result);
      
      // If valid, process extracted transactions
      if (extractedTransactions.isNotEmpty) {
        for (final txData in extractedTransactions) {
          // Convert to ReceiveTransactionMessage and process
          final receiveMsg = ReceiveTransactionMessage(
            transactionId: txData['transactionId'], // Now correctly uses transactionId
            beef: beef,
            fromCounterparty: 'beef_bundle', // TODO: Update to actual peer ID
            targetWalletId: msg.targetWalletId,
          );
          
          await _handleReceiveTransaction(receiveMsg);
        }
      }
      
      print('BEEF validation result: VALID');
      
    } catch (e) {
      print('BEEF validation error: $e');
      context.sender?.tell(BEEFValidationResult(
        isValid: false,
        error: e.toString(),
        targetWalletId: msg.targetWalletId,
      ));
    }
  }

  /// Send error response based on message type
  void _sendErrorResponse(dynamic message, String error) {
    switch (message.runtimeType) {
      case ReceiveTransactionMessage:
        final msg = message as ReceiveTransactionMessage;
        context.sender?.tell(SPVValidationResult(
          txid: msg.transactionId,
          isValid: false,
          validationError: error,
          targetWalletId: msg.targetWalletId,
        ));
        break;
      case ValidateBEEFMessage:
        final msg = message as ValidateBEEFMessage;
        context.sender?.tell(BEEFValidationResult(
          isValid: false,
          error: error,
          targetWalletId: msg.targetWalletId,
        ));
        break;
    }
  }

  @override
  void postStop() {
    print('SPVActor stopped');
    // No cleanup needed - SPV actor doesn't manage any subscriptions
  }

  /// Get current chain tip
  dynamic get currentTip => _currentTip;

  /// Get current chain height
  int get currentHeight => _currentHeight;

}