import 'dart:async';
import 'dart:typed_data';
import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart';
import 'package:dactor/dactor.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:logging/logging.dart';
import 'package:spiffynode/spiffy_node.dart';

import '../plugin/plugin_registry.dart';
import '../storage/wallet_storage.dart';
import '../utils/beef.dart';
import '../utils/bump.dart';
import '../models/invoice_output_spec.dart';
import 'spv_messages.dart' hide ValidateBEEFMessage, BEEFValidationResult;
import 'wallet_messages.dart';
import 'invoice_messages.dart';
import '../utils/network_name.dart';
import '../utils/unique_id.dart';
import '../core/wallet_commands.dart' show RevertTransactionConfirmationCommand;
import '../models/bitcoin_transaction.dart' show TransactionStatus;
import '../spv/merkle_proof_header_check.dart';

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
  final _log = Logger('SPVActor');
  final ActorRef _walletManager;
  final ActorRef _invoiceCoordinator;
  final ReadModelStorage _storage;

  /// Network the wallet runs on ('main', 'test', 'regtest'...). Output
  /// addresses are derived with this network's version byte; a mismatch means
  /// the wallet's own addresses never match and received UTXOs are dropped.
  final String _networkType;
  
  /// Optional reference to ARCActor for triggering pending UTXO checks
  ActorRef? _arcActor;
  
  /// Optional reference to HeaderSyncActor for opportunistic header fetching
  ActorRef? _headerSyncActor;
  
  int _currentHeight = 0;
  dynamic _currentTip;

  SPVActor({
    required ActorRef walletManager,
    required ActorRef invoiceCoordinator,
    required ReadModelStorage storage,
    ActorRef? arcActor,
    ActorRef? headerSyncActor,
    String networkType = 'test',
  }) : _walletManager = walletManager,
       _invoiceCoordinator = invoiceCoordinator,
       _storage = storage,
       _networkType = networkType,
       _arcActor = arcActor,
       _headerSyncActor = headerSyncActor;
  
  /// Set the ARC actor reference (called after actor system initialization)
  void setArcActor(ActorRef arcActor) {
    _arcActor = arcActor;
  }
  
  /// Set the HeaderSync actor reference (called after actor system initialization)
  void setHeaderSyncActor(ActorRef headerSyncActor) {
    _headerSyncActor = headerSyncActor;
  }
  
  /// Handle SetArcActorForSPVMessage
  void _handleSetArcActor(SetArcActorForSPVMessage msg) {
    _arcActor = msg.arcActor;
  }
  
  /// Handle SetHeaderSyncActorMessage
  void _handleSetHeaderSyncActor(SetHeaderSyncActorMessage msg) {
    _headerSyncActor = msg.headerSyncActor;
  }

  @override
  void preStart() {
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
          
        case BlockHeaderStoredMessage:
          await _handleBlockHeaderStored(message as BlockHeaderStoredMessage);
          break;

        case HeaderChainReorganizedMessage:
          await _handleHeaderChainReorganized(message as HeaderChainReorganizedMessage);
          break;
          
        case SetArcActorForSPVMessage:
          _handleSetArcActor(message as SetArcActorForSPVMessage);
          break;
          
        case SetHeaderSyncActorMessage:
          _handleSetHeaderSyncActor(message as SetHeaderSyncActorMessage);
          break;
          
        case ValidateBEEFMessage:
          await _handleValidateBEEF(message as ValidateBEEFMessage);
          break;
          
        default:
      }
    } catch (e) {
      
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
    
    // Load current chain state from storage (async)
    _loadCurrentChainState().then((_) {
    }).catchError((e) {
    });
  }
  
  /// Load current chain state from storage
  Future<void> _loadCurrentChainState() async {
    try {
      _currentHeight = await _storage.getBestHeight();
      final tip = await _storage.getChainTip();
      _currentTip = tip;
    } catch (e) {
      _currentHeight = 0;
      _currentTip = null;
    }
  }

  /// Handle transaction received directly from counterparty (CORE SPV)
  Future<void> _handleReceiveTransaction(ReceiveTransactionMessage msg) async {
    
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
      
      
    } catch (e) {
      
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

  /// Retrieve Block header from storage with opportunistic P2P fetch fallback
  /// 
  /// First tries to retrieve the header from local storage. If not found and
  /// HeaderSyncActor is available, attempts to fetch the header from the Bitcoin
  /// P2P network. This enables SPV validation to succeed even when the counterparty
  /// references block headers we haven't synced yet.
  Future<BlockHeader> _getBlockHeader(int blockHeight) async {
    try {
      // Try local storage first
      final header = await _storage.getBlockHeaderByHeight(blockHeight);
      
      if (header != null) {
        return header;
      }
      
      // Header not found locally - try opportunistic fetch from P2P network
      
      if (_headerSyncActor == null) {
        throw Exception('Block header not found at height $blockHeight and HeaderSyncActor not available for opportunistic fetch');
      }
      
      // Request specific header from HeaderSyncActor
      final response = await _headerSyncActor!.ask<SpecificHeaderResponseMessage>(
        RequestSpecificHeaderMessage(
          blockHeight: blockHeight,
          timeout: Duration(seconds: 10),
        ),
        Duration(seconds: 15),
      );
      
      if (response.success && response.header != null) {
        return response.header!;
      } else {
        throw Exception('Failed to fetch block header from P2P network: ${response.error}');
      }
      
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

    // CRITICAL: beef.validateTransactionWithBlockHeader() expects TXID in display format (big-endian)
    // It handles the internal conversion to BUMP's internal format internally
    final txid = Uint8List.fromList(hex.decode(txidHex));


    try {
      // Step 1: Validate each input UTXO has valid merkle proof
      // This should rely on the BEEF + block headers

      final txMap= beef.findTransactionByTxid(txid);

      // Debug: Print what TXIDs are actually in the BEEF
      if (txMap == null) {
        for (int i = 0; i < beef.txs.length; i++) {
          final calculatedTxid = beef.calculateTxid(beef.txs[i]);
        }
      }

      if (txMap!= null){
        final txIndex = txMap['index'] as int;
        final transaction = dartsv.Transaction.fromHex(hex.encode(txMap['txData']));
        
        // Check if this transaction has a merkle proof
        final hasProof = beef.hasMerkle[txIndex];
        
        if (hasProof) {
          // This transaction has a proof - validate it directly via SPV
          
          final bump = _bumpFor(beef, txIndex);
          final blockHeader = await _getBlockHeader(bump.blockHeight);
          

          // Validate this transaction's merkle proof
          final isValidTx = await beef.validateTransactionWithBlockHeader(txid, blockHeader);

          if (!isValidTx) {
            return SPVValidationResult(
              txid: txidHex,
              isValid: false,
              validationError: 'Transaction not connected to existing blockheader',
              targetWalletId: walletId,
            );
          }
          
          
        } else {
          // This transaction has NO proof (unconfirmed payment transaction)
          // Validate that all its ancestors (inputs) have valid merkle proofs
          
          // Validate ALL transactions in BEEF that have proofs
          final provenTxids = <String>{};
          for (int i = 0; i < beef.txs.length; i++) {
            if (!beef.hasMerkle[i]) {
              continue; // Skip transactions without proofs (like this payment tx)
            }
            
            final ancestorTxid = beef.calculateTxid(beef.txs[i]);
            final bump = _bumpFor(beef, i);
            final blockHeader = await _getBlockHeader(bump.blockHeight);
            
            
            final isValid = await beef.validateTransactionWithBlockHeader(ancestorTxid, blockHeader);
            
            if (!isValid) {
              return SPVValidationResult(
                txid: txidHex,
                isValid: false,
                validationError: 'Ancestor transaction at index $i failed merkle proof validation',
                targetWalletId: walletId,
              );
            }
            provenTxids.add(hex.encode(ancestorTxid));
          }

          // A valid proof somewhere in the BEEF says nothing about *this*
          // transaction unless its inputs chain back to proven transactions.
          // Without this check a BEEF holding one real mined transaction plus
          // a self-signed payment spending non-existent outpoints validated.
          final coverageError = _checkAncestorCoverage(beef, txid, provenTxids);
          if (coverageError != null) {
            return SPVValidationResult(
              txid: txidHex,
              isValid: false,
              validationError: coverageError,
              targetWalletId: walletId,
            );
          }
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
        // If invoice ID is provided, validate outputs match invoice addresses
        final spendableUTXOs = await _extractSpendableUTXOs(transaction, walletId, invoiceId);
        final spentUTXOs = await _extractSpentUTXOs(transaction, walletId);
        
        // Step 3.5: Calculate transaction fee (if there are spent UTXOs)
        BigInt? transactionFee;
        if (spentUTXOs.isNotEmpty) {
          transactionFee = await _calculateTransactionFee(transaction, beef);
          if (transactionFee != null) {
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

  /// The BUMP proving the proven transaction at [txIndex].
  ///
  /// BRC-62 gives every proven transaction an explicit index into the BUMP
  /// list (`beef.bumpIndex`, one entry per proven transaction in order).
  /// BUMPs need not be listed in transaction order, and several
  /// transactions of one block share a BUMP, so counting the proven
  /// transactions before [txIndex] picked the wrong block's proof for
  /// BEEFs not built by this library.
  BUMP _bumpFor(BEEF beef, int txIndex) {
    var ordinal = 0;
    for (var i = 0; i < txIndex; i++) {
      if (beef.hasMerkle[i]) ordinal++;
    }
    if (!beef.hasMerkle[txIndex] || ordinal >= beef.bumpIndex.length) {
      throw StateError('Transaction $txIndex has no BUMP index in the BEEF');
    }
    final index = beef.bumpIndex[ordinal];
    if (index < 0 || index >= beef.bumps.length) {
      throw StateError('BUMP index $index of transaction $txIndex is out of range (${beef.bumps.length} BUMPs)');
    }
    return beef.bumps[index];
  }

  /// BRC-62 ancestor coverage: every input of an unproven transaction must
  /// be spent from a transaction that either has a validated merkle proof
  /// ([provenTxids]) or is itself in the BEEF and covered recursively.
  ///
  /// Returns a description of the first gap, or null when [subjectTxid] is
  /// fully covered.
  String? _checkAncestorCoverage(BEEF beef, Uint8List subjectTxid, Set<String> provenTxids) {
    final visited = <String>{};

    String? visit(Uint8List txidBytes) {
      final txidHex = hex.encode(txidBytes);
      if (provenTxids.contains(txidHex)) return null;
      if (!visited.add(txidHex)) return null;

      final txMap = beef.findTransactionByTxid(txidBytes);
      if (txMap == null) {
        return 'Input transaction $txidHex is neither in the BEEF nor proven';
      }
      final tx = dartsv.Transaction.fromHex(hex.encode(txMap['txData'] as List<int>));
      if (tx.inputs.isEmpty) {
        return 'Unproven transaction $txidHex has no inputs';
      }
      for (final input in tx.inputs) {
        final err = visit(Uint8List.fromList(hex.decode(input.prevTxnId)));
        if (err != null) return err;
      }
      return null;
    }

    return visit(subjectTxid);
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
      // A transaction with a validated merkle proof is already mined; its
      // funding transactions need not travel in the BEEF. An unproven one
      // must be fully checkable, so a missing funding transaction fails it.
      final subjectProven = txMap['hasMerkleProof'] == true;

      var interpreter = dartsv.Interpreter();
      try {
        final broadcastTxn = txToBeValidated;

        var inputIndex = 0;
        for (final input in broadcastTxn.inputs) {
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
          } else if (!subjectProven) {
            // An input whose funding transaction is absent cannot be checked
            // at all; silently accepting it let unverifiable spends through.
            _log.warning('Input $inputIndex of ${hex.encode(txid)} spends '
                '${input.prevTxnId}:${input.prevTxnOutputIndex}, which is not in the BEEF');
            return false;
          }
          inputIndex++;
        }

        return true;

      } on dartsv.ScriptException catch (ex) {
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
        return spendableUTXOs;
      }
    }

    try {
      // Ensure templates are registered (P2PKH, P2PK, P2SH, etc.)
      // This is idempotent - safe to call multiple times
      dartsv.TemplateRegistry.initialize();
      final templateRegistry = dartsv.ScriptTemplateRegistry();
      
      for (int outputIndex = 0; outputIndex < transaction.outputs.length; outputIndex++) {
        final output = transaction.outputs[outputIndex];
        final script = output.script;
        
        // Analyze script to determine if it belongs to our wallet
        final scriptInfo = templateRegistry.extractScriptInfo(script);
        final scriptType = templateRegistry.identifyScriptType(script);
        
        if (scriptInfo == null || scriptType == null) {
          // Fall back to registered plugins before skipping
          final pluginResult = PluginRegistry().identifyScript(script);
          if (pluginResult != null) {
            final plugin = PluginRegistry().getPlugin(pluginResult.pluginId);
            final metadata = plugin?.extractMetadata(script);
            final ownerAddress = metadata?['ownerAddress'] as String?;
            if (ownerAddress != null) {
              final belongsToUs = await _checkOutputOwnership(
                  ownerAddress, walletId, invoice);
              if (belongsToUs) {
                spendableUTXOs.add({
                  'txid': transaction.id,
                  'vout': outputIndex,
                  'satoshis': output.satoshis.toInt(),
                  'script': output.script.toHex(),
                  'scriptType':
                      '${pluginResult.pluginId}:${pluginResult.scriptType}',
                  'address': ownerAddress,
                  'pluginMetadata': metadata,
                });
              }
            }
          }
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
                address = dartsv.Address.fromPubkeyHash(hex.encode(pubkeyHash), NetworkName.toDartsv(_networkType)).toBase58();
              } catch (e) {
                _log.warning('Failed to derive P2PKH address from pubkey hash: $e');
              }
            }
            break;
          case 'p2pk':
            // For P2PK, we'd need to derive address from pubkey
            final pubkey = scriptInfo['pubKey'];
            if (pubkey != null) {
              try {
                final pubKeyObj = dartsv.SVPublicKey.fromHex(pubkey);
                address = dartsv.Address.fromPublicKey(pubKeyObj, NetworkName.toDartsv(_networkType)).toBase58();
              } catch (e) {
                _log.warning('Failed to derive P2PK address from public key: $e');
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
            // Multi-sig handling: extract public keys and match against invoice
            final pubKeys = scriptInfo['pubKeys'] as List<Uint8List>?;
            final threshold = scriptInfo['threshold'] as int?;
            if (pubKeys != null && threshold != null && invoice?.outputs != null) {
              // Check if this P2MS output matches any P2MSOutputSpec in the invoice
              final pubKeyHexList = pubKeys.map((pk) => hex.encode(pk)).toList();
              final matchesInvoice = _matchesP2MSInvoiceOutput(
                pubKeyHexList,
                threshold,
                invoice!.outputs!,
              );

              if (matchesInvoice) {
                spendableUTXOs.add({
                  'txid': transaction.id,
                  'vout': outputIndex,
                  'satoshis': output.satoshis.toInt(),
                  'script': output.script.toHex(),
                  'scriptType': scriptType,
                  'address': 'p2ms:${threshold}-of-${pubKeys.length}', // Pseudo-address for P2MS
                  'publicKeys': pubKeyHexList,
                  'threshold': threshold,
                });
              }
            }
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
              'vout': outputIndex,  // Use 'vout' to match WalletManagerActor expectation
              'satoshis': output.satoshis.toInt(),
              'script': output.script.toHex(),
              'scriptType': scriptType,
              'address': address,
            });
          }
        }
      }
    } catch (e) {
      _log.warning('Failed to extract spendable UTXOs: $e');
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
          return null; // Can't calculate fee without all inputs
        }
        
        // Parse parent transaction to get output value
        final parentTx = dartsv.Transaction.fromHex(hex.encode(parentTxInfo['txData'] as Uint8List));
        
        if (prevVout >= parentTx.outputs.length) {
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
        return null;
      }
      
      return fee;
    } catch (e) {
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
      }
      return matchesInvoice;
    }
    
    // Fallback: Query wallet storage to check if address belongs to wallet
    // This handles cases where invoice is not found or not provided
    try {
      final belongsToWallet = await _storage.isWalletAddress(walletId, address);
      if (belongsToWallet) {
      } else {
      }
      return belongsToWallet;
    } catch (e) {
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
        uniqueId('invoice-query'), // ms timestamps collided (A-L1)
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
      _log.warning('Failed to get invoice details: $e');
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
        }
      }
      
    } catch (e) {
      _log.warning('Failed to extract spent UTXOs: $e');
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
      
      
    } catch (e) {
      _log.warning('Failed to handle block header update: $e');
    }
  }

  /// Handle block header stored notifications from HeaderSyncActor
  /// 
  /// When new block headers are stored, we need to:
  /// 1. Update our chain height tracking
  /// 2. Trigger checking of pending UTXOs to see if they've been mined
  Future<void> _handleBlockHeaderStored(BlockHeaderStoredMessage msg) async {

    try {
      // Confirmations resting on orphaned blocks are handled by
      // HeaderChainReorganizedMessage, which HeaderSyncActor sends before
      // this notification. Proofs accepted before their header was known are
      // checked now that headers have arrived (zvj).
      await _recheckUnverifiedProofs(msg.height);
      
      // Update chain tip if this is a new highest block
      if (msg.height > _currentHeight) {
        _currentHeight = msg.height;
        _currentTip = msg.header;
      }
      
      // CRITICAL: Trigger check of pending UTXOs with Arc
      // This is the key link between receiving block headers and checking
      // if pending UTXOs have been mined
      if (_arcActor != null) {
        _arcActor!.tell(CheckStoragePendingUTXOsMessage(
          triggerBlockHeight: msg.height,
        ));
      } else {
      }
      
    } catch (e) {
      _log.warning('Failed to handle block header stored: $e');
    }
  }

  /// Handle blockchain reorganization reported through the legacy
  /// BlockHeaderUpdateMessage (no sender in the library emits it).
  Future<void> _handleBlockchainReorganization(List<dynamic> orphanedHeaders) async {
    if (orphanedHeaders.isEmpty) {
      return;
    }
    _walletManager.tell(BlockchainReorganizationNotification(
      orphanedHeaderCount: orphanedHeaders.length,
      newHeight: _currentHeight,
    ));
  }

  /// The active header chain moved to another branch (audit 3b0).
  ///
  /// Every confirmed transaction whose block may have changed (its height is
  /// above the fork point, or its stored proof names an orphaned block) has
  /// its proof checked again against the active chain
  /// (MerkleProofHeaderCheck). A proof that still verifies is kept (its block
  /// hash refreshed if needed); otherwise the confirmation is reverted in
  /// each wallet holding the transaction, which journals
  /// TransactionConfirmationRevertedEvent: the transaction returns to
  /// pending, its UTXOs lose their confirmations, and the read model drops
  /// exactly that proof. Nothing else is deleted. ARCActor is then told to
  /// poll the transactions again; a new proof it obtains is verified against
  /// the active chain before the transaction is confirmed again.
  Future<void> _handleHeaderChainReorganized(HeaderChainReorganizedMessage msg) async {
    _currentHeight = msg.newTipHeight;
    try {
      final orphaned = msg.orphanedBlockHashes.toSet();
      final onOrphanedBlocks = <String>{};
      for (final hash in orphaned) {
        for (final proof in await _storage.getMerkleProofsForBlock(hash)) {
          onOrphanedBlocks.add(proof.txid);
        }
      }

      final candidates = <String, List<String>>{}; // txid -> wallet ids
      for (final tx in await _storage.getTransactionsByStatus(TransactionStatus.confirmed)) {
        final walletId = tx.walletId;
        if (walletId == null || walletId.isEmpty) continue;
        final height = tx.blockHeight;
        if (onOrphanedBlocks.contains(tx.txid) || height == null || height > msg.forkHeight) {
          candidates.putIfAbsent(tx.txid, () => []).add(walletId);
        }
      }

      final reverted = <String>[];
      for (final entry in candidates.entries) {
        final proof = await _storage.getMerkleProof(entry.key);
        final String reason;
        if (proof == null) {
          // Nothing to re-verify. Only a confirmation recorded above the fork
          // point can rest on a changed block; one with no height is left
          // alone rather than reverted on every reorganization.
          final heights = await _confirmedHeights(entry.key, entry.value);
          if (!heights.any((h) => h > msg.forkHeight)) continue;
          reason = 'reorganization at height ${msg.forkHeight}: confirmed above the fork point with no stored proof';
        } else {
          final outcome = await _recheckProof(proof);
          if (outcome == null) continue; // still proven on the active chain
          if (proof.blockHeight <= msg.forkHeight && !orphaned.contains(proof.blockHash) &&
              outcome.status == ProofHeaderStatus.headerUnknown) {
            continue;
          }
          reason = 'reorganization at height ${msg.forkHeight}: ${outcome.status.name}'
              '${outcome.detail == null ? '' : ' (${outcome.detail})'}';
        }
        _revertConfirmation(entry.key, entry.value, proof, reason);
        reverted.add(entry.key);
      }

      if (reverted.isNotEmpty) {
        _log.warning('Reorganization at height ${msg.forkHeight} (${orphaned.length} block(s) orphaned): '
            'reverted ${reverted.length} confirmation(s)');
        _arcActor?.tell(TransactionConfirmationsRevertedMessage(reverted));
      }
    } catch (e, st) {
      _log.severe('Failed to re-check confirmations after the reorganization at height ${msg.forkHeight}: $e', e, st);
    }
  }

  /// Proofs stored before their block header was known carry the block hash
  /// `'pending'` (WalletProjection). Once headers up to [upToHeight] are
  /// stored they are checked (zvj part 1): a match records the real block
  /// hash, a mismatch reverts the confirmation like a reorganization does.
  /// Proofs whose header is still unknown stay as they are.
  Future<void> _recheckUnverifiedProofs(int upToHeight) async {
    try {
      final unverified = await _storage.getMerkleProofsForBlock(_unverifiedBlockHash);
      if (unverified.isEmpty) return;

      final reverted = <String>[];
      for (final proof in unverified) {
        if (proof.blockHeight > upToHeight) continue;
        final outcome = await _recheckProof(proof);
        if (outcome == null || outcome.status == ProofHeaderStatus.headerUnknown) continue;

        final wallets = [
          for (final tx in await _storage.getTransactionsByStatus(TransactionStatus.confirmed))
            if (tx.txid == proof.txid && tx.walletId != null && tx.walletId!.isNotEmpty) tx.walletId!,
        ];
        _revertConfirmation(proof.txid, wallets, proof,
            'proof imported before its block header does not match header at height '
            '${proof.blockHeight}: ${outcome.status.name}${outcome.detail == null ? '' : ' (${outcome.detail})'}');
        reverted.add(proof.txid);
      }
      if (reverted.isNotEmpty) {
        _log.severe('${reverted.length} imported proof(s) do not match the block headers that arrived; '
            'confirmations reverted: $reverted');
        _arcActor?.tell(TransactionConfirmationsRevertedMessage(reverted));
      }
    } catch (e, st) {
      _log.warning('Failed to re-check unverified proofs: $e', e, st);
    }
  }

  /// Block hash the projection stores for a proof whose header is unknown.
  static const String _unverifiedBlockHash = 'pending';

  /// Check a stored [proof] against the active header chain. Returns null
  /// when it verifies (after recording the active block's hash on the proof
  /// if it differed), otherwise the failed check.
  Future<ProofHeaderCheck?> _recheckProof(MerkleProof proof) async {
    // A proof that is not a single stored BUMP (pre-SPV-06 layout) does not
    // parse and comes back malformed.
    final check = await checkBumpHexAgainstHeaders(
      txid: proof.txid,
      bumpHex: proof.merkleProof.length == 1 ? proof.merkleProof.single : '',
      headerAt: _storage.getBlockHeaderByHeight,
    );
    if (!check.isVerified) return check;
    if (check.blockHash != proof.blockHash || check.txIndex != proof.position) {
      await _storage.storeMerkleProof(proof.txid, MerkleProof(
        txid: proof.txid,
        blockHash: check.blockHash!,
        blockHeight: check.blockHeight!,
        merkleProof: proof.merkleProof,
        position: check.txIndex!,
      ));
    }
    return null;
  }

  Future<List<int>> _confirmedHeights(String txid, List<String> walletIds) async {
    final heights = <int>[];
    for (final walletId in walletIds) {
      final height = (await _storage.getTransaction(txid, walletId: walletId))?.blockHeight;
      if (height != null) heights.add(height);
    }
    return heights;
  }

  void _revertConfirmation(String txid, List<String> walletIds, MerkleProof? proof, String reason) {
    for (final walletId in walletIds.toSet()) {
      _walletManager.tell(WalletCommandMessage(walletId, RevertTransactionConfirmationCommand(
        walletId: walletId,
        txid: txid,
        blockHeight: proof?.blockHeight,
        blockHash: proof?.blockHash,
        merkleProof: proof?.merkleProof,
        reason: reason,
      )));
    }
  }

  /// Handle BEEF validation (enhanced transaction format)
  Future<void> _handleValidateBEEF(ValidateBEEFMessage msg) async {
    
    try {
      final beef = BEEF.parse(Uint8List.fromList(hex.decode(msg.beefData)));
      final isValid = beef.validate();

      if (!isValid) {
        context.sender?.tell(BEEFValidationResult(
          isValid: false,
          error: 'BEEF data failed validation check',
          targetWalletId: msg.targetWalletId,
          requestId: msg.requestId,
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
        requestId: msg.requestId,
      );
      
      context.sender?.tell(result);
      
      
    } catch (e) {
      context.sender?.tell(BEEFValidationResult(
        isValid: false,
        error: e.toString(),
        targetWalletId: msg.targetWalletId,
        requestId: msg.requestId,
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
          requestId: msg.requestId,
        ));
        break;
    }
  }

  @override
  void postStop() {
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
    // Use effectiveAmount to handle both legacy and multi-output invoices
    final expectedAmount = invoice.effectiveAmount;
    if (totalReceived < expectedAmount) {
      return _InvoiceValidationResult(
        isValid: false,
        error: 'Payment amount ($totalReceived sats) is less than invoice amount ($expectedAmount sats)',
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
          }
        }
      }
      
      // Get block height from BUMP if transaction has merkle proof
      int? blockHeight;
      String bumpProof = '';
      
      if (beef.hasMerkle[txIndex]) {
        final bump = _bumpFor(beef, txIndex);
        blockHeight = bump.blockHeight;
        // Serialize BUMP for storage
        bumpProof = hex.encode(bump.serialize());
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

  /// Check if a P2MS output matches any P2MSOutputSpec in the invoice outputs
  ///
  /// Compares by matching public keys (as sets) and threshold
  bool _matchesP2MSInvoiceOutput(
    List<String> txPubKeys,
    int txThreshold,
    List<InvoiceOutputSpec> invoiceOutputs,
  ) {
    // Normalize public keys to lowercase for comparison
    final txPubKeySet = txPubKeys.map((pk) => pk.toLowerCase()).toSet();

    for (final output in invoiceOutputs) {
      if (output is P2MSOutputSpec) {
        // Check threshold matches
        if (output.threshold != txThreshold) continue;

        // Check public key count matches
        if (output.publicKeys.length != txPubKeys.length) continue;

        // Compare public keys as sets (order independent)
        final invoicePubKeySet =
            output.publicKeys.map((pk) => pk.toLowerCase()).toSet();

        if (txPubKeySet.containsAll(invoicePubKeySet) &&
            invoicePubKeySet.containsAll(txPubKeySet)) {
          return true;
        }
      }
    }
    return false;
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