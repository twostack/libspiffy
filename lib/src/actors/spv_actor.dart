import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';
import 'package:convert/convert.dart';
import 'package:dactor/dactor.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:spiffynode/spiffy_node.dart';

import '../core/wallet_commands.dart';
import '../utils/beef.dart';
import '../utils/bump.dart';
import 'wallet_messages.dart';

/// Actor that handles true SPV validation - receives transactions from counterparties
/// and validates them using merkle proofs against the block header chain
/// 
/// This actor is responsible for:
/// - Block header synchronization with SpiffyNode
/// - Direct transaction validation (NOT discovery)
/// - Merkle proof validation against block headers
/// - BEEF/BUMP transaction processing
/// - Coordinating with WalletManagerActor for validated transactions
class SPVActor extends Actor {
  final ActorRef _walletManager;
  
  // Block header chain management
  final Map<int, dynamic> _blockHeadersByHeight = {}; // height -> BlockHeader
  final Map<String, dynamic> _blockHeadersByHash = {}; // hash -> BlockHeader
  int _currentHeight = 0;
  dynamic _currentTip;
  
  // SpiffyNode integration for block header sync
  dynamic _chainTipTracker;
  StreamSubscription? _headerSyncSubscription;

  SPVActor({
    required ActorRef walletManager,
  }) : _walletManager = walletManager;

  @override
  void preStart() {
    print('SPVActor started - True SPV Mode');
    _initializeBlockHeaderSync();
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

  /// Initialize block header synchronization with SpiffyNode
  void _initializeBlockHeaderSync() {
    print('Initializing block header synchronization...');
    
    // TODO: Initialize actual SpiffyNode ChainTipTracker
    // _chainTipTracker = ChainTipTracker();
    // _headerSyncSubscription = _chainTipTracker.events.listen(_onHeaderUpdate);
    
    print('Block header sync initialized (placeholder)');
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

  //Retrieve Block header from SpiffyNode
  Future<BlockHeader> _getBlockHeader(int blockHeight){

    //we probably need to send a message to a coordinating actor that knows
    //how to get hold of the spiffyNode
    throw UnimplementedError();
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
  Future<List<Map<String, dynamic>>> _extractSpendableUTXOs(dynamic transaction, String? walletId) async {
    // TODO: Implement UTXO extraction:
    // 1. Check each output to see if we can spend it
    // 2. Use script analysis to determine spendability
    // 3. Create UTXO records with merkle proof requirements
    
    return []; // Placeholder
  }

  /// Extract UTXOs that were spent in this transaction
  Future<List<Map<String, dynamic>>> _extractSpentUTXOs(dynamic transaction, String? walletId) async {
    // TODO: Implement spent UTXO detection:
    // 1. Check each input to see if it spends our UTXOs
    // 2. Match against known wallet UTXOs
    
    return []; // Placeholder
  }

  /// Handle block header updates from SpiffyNode
  Future<void> _handleBlockHeaderUpdate(BlockHeaderUpdateMessage msg) async {
    print('Updating block header chain: height ${msg.height}, reorg: ${msg.isReorganization}');
    
    try {
      if (msg.isReorganization) {
        await _handleBlockchainReorganization(msg.orphanedHeaders ?? []);
      }
      
      // Add new header to chain
      _blockHeadersByHeight[msg.height] = msg.blockHeader;
      // TODO: Extract hash from blockHeader
      // _blockHeadersByHash[msg.blockHeader.hash] = msg.blockHeader;
      
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
    
    // TODO: Implement reorganization handling:
    // 1. Remove orphaned headers from chain
    // 2. Invalidate merkle proofs for transactions in orphaned blocks
    // 3. Notify WalletManager of affected transactions
    // 4. Request re-validation of affected transactions
    
    print('Blockchain reorganization handled (placeholder)');
  }

  /// Handle BEEF validation (enhanced transaction format)
  Future<void> _handleValidateBEEF(ValidateBEEFMessage msg) async {
    print('Validating BEEF data: ${msg.beefData.length} bytes');
    
    try {

      final beef = BEEF.parse(Uint8List.fromList(hex.decode(msg.beefData)));
      final isValid = beef.validate();

      if (!isValid){
        context.sender?.tell(BEEFValidationResult(
          isValid: false,
          error: 'BEEF data failed validation check',
          targetWalletId: msg.targetWalletId,
        ));
      }

      final extractedTransactions = <Map<String, dynamic>>[];
      
      final result = BEEFValidationResult(
        isValid: isValid,
        merkleRoot: isValid ? 'placeholder_merkle_root' : null,
        error: isValid ? null : 'Invalid BEEF data',
        targetWalletId: msg.targetWalletId,
        extractedTransactions: extractedTransactions,
      );
      
      context.sender?.tell(result);
      
      // If valid, process extracted transactions
      if (isValid && extractedTransactions.isNotEmpty) {
        for (final txData in extractedTransactions) {
          // Convert to ReceiveTransactionMessage and process
          final receiveMsg = ReceiveTransactionMessage(
            transactionId: txData['transaction'],
            beef: beef,
            fromCounterparty: 'beef_bundle', //FIXME: beef_bundle should be updated to PeerId of sending side
            targetWalletId: msg.targetWalletId,
          );
          
          await _handleReceiveTransaction(receiveMsg);
        }
      }
      
      print('BEEF validation result: $isValid');
      
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
    _headerSyncSubscription?.cancel();
  }

  // ==========================================================================
  // HELPER METHODS FOR SPV
  // ==========================================================================

  /// Get block header by height
  dynamic getBlockHeaderByHeight(int height) => _blockHeadersByHeight[height];

  /// Get block header by hash
  dynamic getBlockHeaderByHash(String hash) => _blockHeadersByHash[hash];

  /// Get current chain tip
  dynamic get currentTip => _currentTip;

  /// Get current chain height
  int get currentHeight => _currentHeight;

  /// Check if we have block header for given height
  bool hasBlockHeader(int height) => _blockHeadersByHeight.containsKey(height);

  /// Get chain length (number of headers we have)
  int get chainLength => _blockHeadersByHeight.length;
} 