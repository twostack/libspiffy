import 'dart:async';
import 'dart:typed_data';
import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart';
import 'package:dactor/dactor.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:spiffynode/spiffy_node.dart';

import '../storage/wallet_storage.dart';
import '../utils/beef.dart';
import 'wallet_messages.dart';
import 'invoice_messages.dart';

/// Actor that handles true SPV validation - receives transactions from counterparties
/// and validates them using merkle proofs against the block header chain
/// 
/// This actor is responsible for:
/// - Direct transaction validation (NOT discovery)
/// - Merkle proof validation against stored block headers
/// - BEEF/BUMP transaction processing
/// - Invoice-based payment verification
/// - Coordinating with WalletManagerActor for validated transactions
/// 
/// Note: Block header synchronization is handled by SpiffyNode, which stores
/// headers in storage. This actor consumes those stored headers for validation.
class SPVActor extends Actor {
  final ActorRef _walletManager;
  final ActorRef _invoiceCoordinator;
  final ReadModelStorage _storage;
  
  int _currentHeight = 0;
  dynamic _currentTip;

  SPVActor({
    required ActorRef walletManager,
    required ActorRef invoiceCoordinator,
    required ReadModelStorage storage,
  }) : _walletManager = walletManager,
       _invoiceCoordinator = invoiceCoordinator,
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
    } catch (e) {
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
    print('Validating transaction from ${msg.fromCounterparty} for wallet ${msg.targetWalletId}${msg.invoiceId != null ? ' (invoice: ${msg.invoiceId})' : ''}');
    
    try {
      // This is the core SPV process
      final validationResult = await _validateReceivedTransaction(
        msg.transactionId,
        msg.beef,
        msg.targetWalletId,
        msg.invoiceId,
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

  /// Validate received transaction using SPV principles with invoice-based payment verification
  /// Received transactions will be assumed as having a BEEF structure that
  /// links to (some) blockheader's merkle root
  Future<SPVValidationResult> _validateReceivedTransaction(
    String txidHex, //The TxId in display format (big-endian)
    BEEF beef,  //The BEEF containing the Transaction that should be validated
    String? walletId,
    String? invoiceId, // Invoice ID for payment matching
  )   async {
    print('Performing SPV validation${invoiceId != null ? ' for invoice $invoiceId' : ''}...');

    // CRITICAL: beef.validateTransactionWithBlockHeader() expects TXID in display format (big-endian)
    // It handles the internal conversion to BUMP's internal format internally
    final txid = Uint8List.fromList(hex.decode(txidHex));

    print('Debug: Looking for TXID: $txidHex');
    print('Debug: BEEF has ${beef.txs.length} transaction(s)');

    try {
      // Step 1: Validate each input UTXO has valid merkle proof
      // This should rely on the BEEF + block headers

      final txMap= beef.findTransactionByTxid(txid);

      // Debug: Print what TXIDs are actually in the BEEF
      if (txMap == null) {
        print('Debug: Transaction not found. TXIDs in BEEF:');
        for (int i = 0; i < beef.txs.length; i++) {
          final calculatedTxid = beef.calculateTxid(beef.txs[i]);
          print('  [$i]: ${hex.encode(calculatedTxid)}');
        }
      }

      if (txMap!= null){
        final txIndex = txMap['index'] as int;
        final transaction = dartsv.Transaction.fromHex(hex.encode(txMap['txData']));
        
        // Check if this transaction has a merkle proof
        final hasProof = beef.hasMerkle[txIndex];
        
        if (hasProof) {
          // This transaction has a proof - validate it directly via SPV
          print('Debug: Transaction has merkle proof - performing direct SPV validation');
          
          // Calculate BUMP index by counting how many transactions before this have proofs
          int bumpIndex = 0;
          for (int i = 0; i < txIndex; i++) {
            if (beef.hasMerkle[i]) {
              bumpIndex++;
            }
          }
          
          final bump = beef.bumps[bumpIndex];
          final blockHeader = await _getBlockHeader(bump.blockHeight);
          
          print('Debug: BUMP block height: ${bump.blockHeight}');
          print('Debug: Block header merkle root: ${hex.encode(blockHeader.merkleRoot.bytes)}');
          print('Debug: Bump Merkle Root ${hex.encode(bump.computeMerkleRoot(Uint8List.fromList(hex.decode(txidHex))))}');

          // Validate this transaction's merkle proof
          final isValidTx = await beef.validateTransactionWithBlockHeader(txid, blockHeader);

          if (!isValidTx) {
            print('Debug: Merkle proof validation FAILED');
            return SPVValidationResult(
              txid: txidHex,
              isValid: false,
              validationError: 'Transaction not connected to existing blockheader',
              targetWalletId: walletId,
            );
          }
          
          print('Debug: Merkle proof validation PASSED');
          
        } else {
          // This transaction has NO proof (unconfirmed payment transaction)
          // Validate that all its ancestors (inputs) have valid merkle proofs
          print('Debug: Transaction has no merkle proof (unconfirmed)');
          print('Debug: Validating all ancestor transactions have valid proofs...');
          
          // Validate ALL transactions in BEEF that have proofs
          for (int i = 0; i < beef.txs.length; i++) {
            if (!beef.hasMerkle[i]) {
              continue; // Skip transactions without proofs (like this payment tx)
            }
            
            // Calculate BUMP index for this ancestor
            int bumpIndex = 0;
            for (int j = 0; j < i; j++) {
              if (beef.hasMerkle[j]) {
                bumpIndex++;
              }
            }
            
            final ancestorTxid = beef.calculateTxid(beef.txs[i]);
            final bump = beef.bumps[bumpIndex];
            final blockHeader = await _getBlockHeader(bump.blockHeight);
            
            print('Debug: Validating ancestor $i (txid: ${hex.encode(ancestorTxid)})');
            
            final isValid = await beef.validateTransactionWithBlockHeader(ancestorTxid, blockHeader);
            
            if (!isValid) {
              print('Debug: Ancestor $i merkle proof validation FAILED');
              return SPVValidationResult(
                txid: txidHex,
                isValid: false,
                validationError: 'Ancestor transaction at index $i failed merkle proof validation',
                targetWalletId: walletId,
              );
            }
          }
          
          print('Debug: All ancestor merkle proofs validated successfully');
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
        
        print('Debug: Transaction spends correctly');

        // Step 3: Extract spendable UTXOs for the target wallet
        // If invoice ID is provided, validate outputs match invoice addresses
        final spendableUTXOs = await _extractSpendableUTXOs(transaction, walletId, invoiceId);
        final spentUTXOs = await _extractSpentUTXOs(transaction, walletId);
        
        // Step 3.5: Calculate transaction fee (if there are spent UTXOs)
        BigInt? transactionFee;
        if (spentUTXOs.isNotEmpty) {
          transactionFee = await _calculateTransactionFee(transaction, beef);
          if (transactionFee != null) {
            print('Transaction fee calculated: $transactionFee satoshis');
          }
        }

        // Step 4: If invoice-based, verify payment matches invoice expectations
        if (invoiceId != null && spendableUTXOs.isNotEmpty) {
          final invoiceValidation = await _validateInvoicePayment(invoiceId, spendableUTXOs);
          if (!invoiceValidation.isValid) {
            return SPVValidationResult(
              txid: txidHex,
              isValid: false,
              validationError: invoiceValidation.error ?? 'Payment does not match invoice',
              targetWalletId: walletId,
            );
          }
          
          // Mark invoice as paid
          _invoiceCoordinator.tell(MarkInvoicePaidMessage(
            invoiceId: invoiceId,
            txid: txidHex,
            amountReceived: invoiceValidation.totalReceived,
            addressesPaidTo: spendableUTXOs.map((u) => u['address'] as String).toList(),
          ), sender: context.self);
        }

        print('SPV Validation SUCCESS: ${spendableUTXOs.length} new UTXOs, ${spentUTXOs.length} spent UTXOs');

        // Build complete transaction data for recording in transaction history
        final transactionData = await _buildTransactionData(
          transaction,
          beef,
          txIndex,
          spendableUTXOs,
          spentUTXOs,
        );

        return SPVValidationResult(
          txid: txidHex,
          isValid: true,
          spendableUTXOs: spendableUTXOs,
          spentUTXOs: spentUTXOs,
          targetWalletId: walletId,
          transactionFee: transactionFee,
          transactionData: transactionData,
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

      final txToBeValidated = dartsv.Transaction.fromHex(hex.encode(txMap['txData']));

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
  /// to the specified wallet (via invoice matching if invoiceId provided).
  Future<List<Map<String, dynamic>>> _extractSpendableUTXOs(
    dartsv.Transaction transaction, 
    String? walletId,
    String? invoiceId,
  ) async {
    final spendableUTXOs = <Map<String, dynamic>>[];
    
    if (walletId == null) {
      return spendableUTXOs;
    }

    // Get invoice details if invoice-based payment
    InvoiceDetailsResponse? invoice;
    if (invoiceId != null) {
      invoice = await _getInvoiceDetails(invoiceId);
      if (invoice == null || !invoice.found) {
        print('Warning: Invoice $invoiceId not found for transaction ${transaction.id}');
        return spendableUTXOs;
      }
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

        String? address;

        switch (scriptType.toLowerCase()) {
          case 'p2pkh':
            // Extract address from pubkey hash
            final pubkeyHash = scriptInfo['pubKeyHash'];
            if (pubkeyHash != null) {
              try {
                // Create Address from pubkeyhash
                address = dartsv.Address.fromPubkeyHash(hex.encode(pubkeyHash), dartsv.NetworkType.TEST).toBase58();
              } catch (e) {
                print('Could not create address from pubkey hash: $e');
              }
            }
            break;
          case 'p2pk':
            // For P2PK, we'd need to derive address from pubkey
            final pubkey = scriptInfo['pubKey'];
            if (pubkey != null) {
              try {
                final pubKeyObj = dartsv.SVPublicKey.fromHex(pubkey);
                address = dartsv.Address.fromPublicKey(pubKeyObj, dartsv.NetworkType.TEST).toBase58();
              } catch (e) {
                print('Could not derive address from P2PK pubkey: $e');
              }
            }
            break;
          case 'p2sh':
            // P2SH address extraction
            final scriptHash = scriptInfo['scriptHash'];
            if (scriptHash != null) {
              // Note: dartsv may not have direct P2SH address support
              // This is a simplified approach
              address = 'p2sh:$scriptHash'; // Placeholder
            }
            break;
          case 'p2ms':
            // Multi-sig handling would require more complex logic
            // Skip for now
            continue;
          default:
            // Skip unknown script types
            continue;
        }

        if (address != null) {
          // Check if address matches invoice (if invoice-based) or wallet
          final belongsToUs = await _checkOutputOwnership(address, walletId, invoice);
          
          if (belongsToUs) {
            spendableUTXOs.add({
              'txid': transaction.id,
              'outputIndex': outputIndex,
              'satoshis': output.satoshis.toInt(),
              'script': output.script.toString(),
              'scriptType': scriptType,
              'address': address,
            });
          }
        }
      }
    } catch (e) {
      print('Error extracting spendable UTXOs: $e');
    }

    return spendableUTXOs;
  }
  
  /// Calculate the transaction fee from BEEF data
  /// Fee = Sum of input values - Sum of output values
  Future<BigInt?> _calculateTransactionFee(
    dartsv.Transaction transaction,
    BEEF beef,
  ) async {
    try {
      // Calculate total input value by looking up parent transactions in BEEF
      BigInt totalInputValue = BigInt.zero;
      
      for (final input in transaction.inputs) {
        final prevTxid = input.prevTxnId;
        final prevVout = input.prevTxnOutputIndex;
        
        // Look up the parent transaction in BEEF
        final prevTxidBytes = Uint8List.fromList(hex.decode(prevTxid));
        final parentTxInfo = beef.findTransactionByTxid(prevTxidBytes);
        
        if (parentTxInfo == null) {
          print('Warning: Parent transaction $prevTxid not found in BEEF');
          return null; // Can't calculate fee without all inputs
        }
        
        // Parse parent transaction to get output value
        final parentTx = dartsv.Transaction.fromHex(hex.encode(parentTxInfo['txData'] as Uint8List));
        
        if (prevVout >= parentTx.outputs.length) {
          print('Warning: Invalid vout index $prevVout for parent tx $prevTxid');
          return null;
        }
        
        final parentOutput = parentTx.outputs[prevVout];
        totalInputValue += BigInt.from(parentOutput.satoshis.toInt());
      }
      
      // Calculate total output value
      BigInt totalOutputValue = BigInt.zero;
      for (final output in transaction.outputs) {
        totalOutputValue += BigInt.from(output.satoshis.toInt());
      }
      
      // Fee is the difference
      final fee = totalInputValue - totalOutputValue;
      
      if (fee < BigInt.zero) {
        print('Warning: Calculated negative fee: $fee');
        return null;
      }
      
      return fee;
    } catch (e) {
      print('Error calculating transaction fee: $e');
      return null;
    }
  }
  
  /// Check if an output address belongs to us
  /// For invoice-based payments, check against invoice addresses
  /// Otherwise, query wallet storage for address ownership
  Future<bool> _checkOutputOwnership(
    String address, 
    String walletId,
    InvoiceDetailsResponse? invoice,
  ) async {
    // Invoice-based matching (primary flow - most reliable)
    if (invoice != null) {
      final matchesInvoice = invoice.addresses.contains(address);
      if (matchesInvoice) {
        print('✅ Address $address matches invoice address');
      }
      return matchesInvoice;
    }
    
    // Fallback: Query wallet storage to check if address belongs to wallet
    // This handles cases where invoice is not found or not provided
    print('⚠️  No invoice provided - checking wallet storage for address $address');
    try {
      final belongsToWallet = await _storage.isWalletAddress(walletId, address);
      if (belongsToWallet) {
        print('✅ Address $address belongs to wallet $walletId');
      } else {
        print('❌ Address $address does NOT belong to wallet $walletId');
      }
      return belongsToWallet;
    } catch (e) {
      print('Error checking wallet address ownership: $e');
      return false;
    }
  }
  
  /// Get invoice details from InvoiceManager
  Future<InvoiceDetailsResponse?> _getInvoiceDetails(String invoiceId) async {
    try {
      // Create a completer to wait for response
      final completer = Completer<InvoiceDetailsResponse?>();
      
      // Create a temporary actor to receive the response
      final responseReceiver = await context.system.spawn(
        'invoice-query-${DateTime.now().millisecondsSinceEpoch}',
        () => _InvoiceQueryReceiver(completer),
      );
      
      // Send query
      _invoiceCoordinator.tell(
        CheckInvoiceMessage(invoiceId),
        sender: responseReceiver,
      );
      
      // Wait for response with timeout
      final response = await completer.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => null,
      );
      
      // Stop the temporary actor
      await context.system.stop(responseReceiver);
      
      return response;
    } catch (e) {
      print('Error querying invoice $invoiceId: $e');
      return null;
    }
  }

  /// Extract UTXOs that were spent in this transaction
  /// 
  /// This method analyzes transaction inputs to identify UTXOs that belonged
  /// to the specified wallet and are being spent by this transaction.
  /// 
  /// CRITICAL: Only returns inputs that the wallet actually owns. When receiving
  /// a payment, this will return empty list since inputs belong to the sender.
  Future<List<Map<String, dynamic>>> _extractSpentUTXOs(dartsv.Transaction transaction, String? walletId) async {
    final spentUTXOs = <Map<String, dynamic>>[];
    
    if (walletId == null) {
      return spentUTXOs;
    }

    try {
      // Get wallet's current UTXOs to check ownership
      final walletUtxos = await _storage.getUTXOs(walletId, includeSpent: false);
      
      // Build a set of UTXO keys for O(1) lookup
      final walletUtxoKeys = walletUtxos.map((utxo) => '${utxo.txid}:${utxo.vout}').toSet();
      
      print('Debug: Wallet $walletId has ${walletUtxoKeys.length} UTXOs');
      
      // Check each transaction input to see if it belongs to this wallet
      for (int inputIndex = 0; inputIndex < transaction.inputs.length; inputIndex++) {
        final input = transaction.inputs[inputIndex];
        final prevTxId = input.prevTxnId;
        final prevOutputIndex = input.prevTxnOutputIndex;
        final utxoKey = '$prevTxId:$prevOutputIndex';

        // Only add to spentUTXOs if this wallet actually owns the UTXO being spent
        if (walletUtxoKeys.contains(utxoKey)) {
          spentUTXOs.add({
            'txid': prevTxId,
            'vout': prevOutputIndex,
            'inputIndex': inputIndex,
          });
          print('Debug: Wallet owns UTXO $utxoKey being spent in this transaction');
        }
      }
      
      print('Debug: Found ${spentUTXOs.length} UTXOs owned by wallet $walletId being spent (out of ${transaction.inputs.length} total inputs)');
    } catch (e) {
      print('Error extracting spent UTXOs: $e');
    }

    return spentUTXOs;
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
    //Transaction-related and wallet-related mitigations.
    //
    // The actual reorg handling (merkle proof invalidation, transaction revalidation,
    // UTXO recalculation) is implemented in the service layer:
    // - SPVService: Revalidates transactions and fetches fresh merkle proofs
    // - WalletBalanceService: Revalidates UTXOs and recalculates balances
    // - BlockHeaderService: Handles header chain reorganization
    //
    // These services listen to ChainTipEvents directly from SpiffyNode.
    // The SPVActor's role here is coordination and notification at the actor layer.
    
    if (orphanedHeaders.isEmpty) {
      print('No orphaned headers to process');
      return;
    }
    
    // Notify WalletManager about the reorganization so it can coordinate
    // any wallet-specific actions if needed
    _walletManager.tell(BlockchainReorganizationNotification(
      orphanedHeaderCount: orphanedHeaders.length,
      newHeight: _currentHeight,
    ));
    
    print('Blockchain reorganization handled: notified WalletManager about ${orphanedHeaders.length} orphaned headers');
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
      
      // Extract merkle root from first BUMP if available
      String? merkleRoot;
      if (beef.bumps.isNotEmpty && beef.bumps.first.path.isNotEmpty) {
        // Get the merkle root from the last level of the first BUMP
        final topLevel = beef.bumps.first.path.last;
        if (topLevel.leaves.isNotEmpty && topLevel.leaves.first.hash != null) {
          merkleRoot = hex.encode(topLevel.leaves.first.hash!);
        }
      }
      
      final result = BEEFValidationResult(
        isValid: true,
        merkleRoot: merkleRoot,
        error: null,
        targetWalletId: msg.targetWalletId,
        extractedTransactions: extractedTransactions,
      );
      
      context.sender?.tell(result);
      
      print('BEEF validation result: VALID (${extractedTransactions.length} transactions extracted)');
      
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

  /// Validate that payment matches invoice expectations
  Future<_InvoiceValidationResult> _validateInvoicePayment(
    String invoiceId,
    List<Map<String, dynamic>> spendableUTXOs,
  ) async {
    // Get invoice details
    final invoice = await _getInvoiceDetails(invoiceId);
    
    if (invoice == null || !invoice.found) {
      return _InvoiceValidationResult(
        isValid: false,
        error: 'Invoice $invoiceId not found',
        totalReceived: BigInt.zero,
      );
    }
    
    if (invoice.status != InvoiceStatus.pending) {
      return _InvoiceValidationResult(
        isValid: false,
        error: 'Invoice $invoiceId is not pending (status: ${invoice.status})',
        totalReceived: BigInt.zero,
      );
    }
    
    // Calculate total received
    BigInt totalReceived = BigInt.zero;
    for (final utxo in spendableUTXOs) {
      totalReceived += BigInt.from(utxo['satoshis'] as int);
    }
    
    // Check if amount meets or exceeds invoice amount
    if (totalReceived < invoice.amount) {
      return _InvoiceValidationResult(
        isValid: false,
        error: 'Payment amount ($totalReceived sats) is less than invoice amount (${invoice.amount} sats)',
        totalReceived: totalReceived,
      );
    }
    
    return _InvoiceValidationResult(
      isValid: true,
      totalReceived: totalReceived,
    );
  }
  
  /// Build complete transaction data for recording in transaction history
  Future<Map<String, dynamic>> _buildTransactionData(
    dartsv.Transaction transaction,
    BEEF beef,
    int txIndex,
    List<Map<String, dynamic>> spendableUTXOs,
    List<Map<String, dynamic>> spentUTXOs,
  ) async {
    try {
      // Extract basic transaction info
      final rawHex = hex.encode(beef.txs[txIndex]);
      final numInputs = transaction.inputs.length;
      final numOutputs = transaction.outputs.length;
      final txVersion = transaction.version;
      final txLockTime = transaction.nLockTime;
      
      // Calculate total output value
      BigInt totalOutputSats = BigInt.zero;
      for (final output in transaction.outputs) {
        totalOutputSats += output.satoshis;
      }
      
      // Extract wallet receiving addresses and received amount from spendable UTXOs
      final walletReceivingAddresses = <String>[];
      BigInt walletReceivedSats = BigInt.zero;
      
      for (final utxo in spendableUTXOs) {
        final address = utxo['address'] as String?;
        if (address != null && !walletReceivingAddresses.contains(address)) {
          walletReceivingAddresses.add(address);
        }
        final satoshis = utxo['satoshis'];
        if (satoshis is BigInt) {
          walletReceivedSats += satoshis;
        } else if (satoshis != null) {
          walletReceivedSats += BigInt.from(satoshis);
        }
      }
      
      // Calculate total input value and extract sending addresses from parent transactions
      BigInt totalInputSats = BigInt.zero;
      final sendingAddresses = <String>[];
      
      // Build a map of all transactions in the BEEF for lookups
      final txMap = <String, dartsv.Transaction>{};
      for (int i = 0; i < beef.txs.length; i++) {
        final tx = dartsv.Transaction.fromHex(hex.encode(beef.txs[i]));
        txMap[tx.id] = tx;
      }
      
      // For each input, find the parent transaction and extract the output being spent
      for (final input in transaction.inputs) {
        final prevTxid = input.prevTxnId;
        final prevVout = input.prevTxnOutputIndex;
        
        final parentTx = txMap[prevTxid];
        if (parentTx != null && prevVout < parentTx.outputs.length) {
          final prevOutput = parentTx.outputs[prevVout];
          totalInputSats += prevOutput.satoshis;
          
          // Try to extract address from scriptPubKey
          try {
            // For P2PKH scripts, extract the pubkey hash and convert to address
            final scriptHex = prevOutput.script.toHex();
            if (scriptHex.length >= 50 && scriptHex.startsWith('76a914') && scriptHex.endsWith('88ac')) {
              // Standard P2PKH: OP_DUP OP_HASH160 <20 bytes> OP_EQUALVERIFY OP_CHECKSIG
              final pubKeyHash = scriptHex.substring(6, 46); // Extract the 20-byte hash
              final address = dartsv.Address(pubKeyHash).toString();
              if (!sendingAddresses.contains(address)) {
                sendingAddresses.add(address);
              }
            }
          } catch (e) {
            // If we can't extract address (e.g., non-standard script), skip
            print('Could not extract address from input $prevTxid:$prevVout: $e');
          }
        }
      }
      
      // Get block height from BUMP if transaction has merkle proof
      int? blockHeight;
      String bumpProof = '';
      
      if (beef.hasMerkle[txIndex]) {
        // Calculate BUMP index
        int bumpIndex = 0;
        for (int i = 0; i < txIndex; i++) {
          if (beef.hasMerkle[i]) {
            bumpIndex++;
          }
        }
        
        if (bumpIndex < beef.bumps.length) {
          final bump = beef.bumps[bumpIndex];
          blockHeight = bump.blockHeight;
          // Serialize BUMP for storage
          bumpProof = hex.encode(bump.serialize());
        }
      }
      
      return {
        'rawHex': rawHex,
        'blockHeight': blockHeight ?? 0,
        'bumpProof': bumpProof,
        'totalOutputSats': totalOutputSats.toInt(),
        'numInputs': numInputs,
        'numOutputs': numOutputs,
        'txVersion': txVersion,
        'txLockTime': txLockTime,
        'walletReceivingAddresses': walletReceivingAddresses,
        'walletReceivedSats': walletReceivedSats.toInt(),
        'totalInputSats': totalInputSats.toInt(),
        'sendingAddresses': sendingAddresses,
      };
    } catch (e) {
      print('Error building transaction data: $e');
      // Return minimal data on error
      return {
        'rawHex': hex.encode(beef.txs[txIndex]),
        'blockHeight': 0,
        'bumpProof': '',
        'totalOutputSats': 0,
        'numInputs': transaction.inputs.length,
        'numOutputs': transaction.outputs.length,
        'txVersion': transaction.version,
        'txLockTime': transaction.nLockTime,
        'walletReceivingAddresses': <String>[],
        'walletReceivedSats': 0,
        'totalInputSats': 0,
        'sendingAddresses': <String>[],
      };
    }
  }
}

/// Helper result for invoice validation
class _InvoiceValidationResult {
  final bool isValid;
  final String? error;
  final BigInt totalReceived;
  
  _InvoiceValidationResult({
    required this.isValid,
    this.error,
    required this.totalReceived,
  });
}

/// Temporary actor to receive invoice query responses
class _InvoiceQueryReceiver extends Actor {
  final Completer<InvoiceDetailsResponse?> completer;
  
  _InvoiceQueryReceiver(this.completer);
  
  @override
  Future<void> onMessage(dynamic message) async {
    if (message is InvoiceDetailsResponse) {
      if (!completer.isCompleted) {
        completer.complete(message);
      }
    }
  }
}