import 'dart:async';
import 'dart:typed_data';
import 'package:collection/collection.dart' show mergeSort;
import 'package:convert/convert.dart';
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
import '../core/wallet_commands.dart'
    show ConfirmTransactionCommand, MarkUTXOAvailableCommand, RevertTransactionConfirmationCommand;
import '../core/wallet_events.dart' show BeefAncestor;
import '../models/bitcoin_transaction.dart' show BitcoinTransaction, TransactionStatus;
import '../models/bitcoin_utxo.dart' show UTXOStatus;
import '../spv/merkle_proof_header_check.dart';
import '../core/wallet_output_ownership.dart' show BareMultisigScript;

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

  /// Loads the chain height, then checks the pendingHeader proofs up to it
  /// (bead libspiffy-yix): headers that arrived while the node was down, or a
  /// check a shutdown interrupted, are not left until the next header
  /// notification. Runs before the first message is handled.
  @override
  Future<void> preStart() async {
    await _loadCurrentChainState();
    if (_currentHeight > 0) {
      await _recheckUnverifiedProofs(_currentHeight);
    }
  }

  @override
  Future<void> onMessage(dynamic message) async {
    try {
      switch (message) {
        case final ReceiveTransactionMessage msg:
          await _handleReceiveTransaction(msg);
          break;
          
        case final BlockHeaderUpdateMessage msg:
          await _handleBlockHeaderUpdate(msg);
          break;
          
        case final BlockHeaderStoredMessage msg:
          await _handleBlockHeaderStored(msg);
          break;

        case final HeaderChainReorganizedMessage msg:
          await _handleHeaderChainReorganized(msg);
          break;
          
        case final SetArcActorForSPVMessage msg:
          _handleSetArcActor(msg);
          break;
          
        case final SetHeaderSyncActorMessage msg:
          _handleSetHeaderSyncActor(msg);
          break;
          
        case final ValidateBEEFMessage msg:
          await _handleValidateBEEF(msg);
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

  /// Load current chain state from storage
  ///
  /// Note: Block header synchronization is handled by SpiffyNode, not the SPV actor.
  /// The SPV actor only consumes headers that SpiffyNode has already stored.
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

        // The ancestors (and their BUMPs) an unproven transaction's outputs
        // cannot be spent without (bead zsh); none for a proven one.
        var ancestors = const <BeefAncestor>[];

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
          ancestors = _ancestorsToRetain(beef, txidHex, provenTxids);
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
        

        // Step 3: Which outputs and inputs are the target wallet's. The
        // wallet decides from its own event-sourced state: the read model
        // lags its journal, and a payment to a freshly created wallet or a
        // just-generated address validated with nothing credited (bead
        // libspiffy-29t). A wallet that cannot answer fails the result
        // rather than letting it through with the wallet's outputs dropped.
        final outputLocks = [for (final output in transaction.outputs) _decodeOutputLock(output)];
        final WalletOwnershipResponse? ownership;
        try {
          ownership = walletId == null ? null : await _askWalletOwnership(walletId, transaction, outputLocks);
        } on _OwnershipUnavailable catch (e) {
          _log.warning('Transaction $txidHex for wallet $walletId is not received: ${e.reason}');
          return SPVValidationResult(
            txid: txidHex,
            isValid: false,
            validationError: 'Cannot tell which outputs of $txidHex belong to wallet $walletId: '
                '${e.reason}. Nothing was recorded; receive the transaction again once the wallet can answer',
            targetWalletId: walletId,
          );
        }

        // Outputs nothing could read are listed in the result, not dropped
        // silently (bead libspiffy-rp6x). The transaction is still
        // recorded whole, so they can be read again later.
        final unreadableOutputs = [
          for (final (vout, lock) in outputLocks.indexed)
            if (lock.readError case final reason?)
              {
                'vout': vout,
                'satoshis': transaction.outputs[vout].satoshis.toInt(),
                'script': transaction.outputs[vout].script.toHex(),
                if (lock.scriptType case final scriptType?) 'scriptType': scriptType,
                'reason': reason,
              },
        ];
        if (unreadableOutputs.isNotEmpty) {
          _log.warning('Transaction $txidHex for wallet $walletId: could not read the locking script of '
              'output(s) ${[for (final o in unreadableOutputs) o['vout']]}; they are not attributed to the wallet '
              'and are listed in the result: ${[for (final o in unreadableOutputs) '${o['vout']}: ${o['reason']}']}');
        }

        // A payment for an invoice is checked against that invoice. When the
        // invoice cannot be looked up (no answer, or no such invoice) the
        // result fails: validating it with the outputs dropped told the
        // payer it had paid while nothing was recorded and the invoice
        // stayed unpaid (bead libspiffy-n8b9).
        InvoiceDetailsResponse? invoice;
        if (invoiceId != null) {
          invoice = await _getInvoiceDetails(invoiceId);
          final String? lookupError;
          if (invoice == null) {
            lookupError = 'the invoice coordinator did not answer. Nothing was recorded; '
                'receive the transaction again once the invoice can be looked up';
          } else if (!invoice.found) {
            lookupError = 'no such invoice${invoice.error == null ? '' : ' (${invoice.error})'}. Nothing was '
                'recorded; receive the transaction without an invoice id to record it as a payment to the wallet';
          } else {
            lookupError = null;
          }
          if (lookupError != null) {
            _log.warning('Transaction $txidHex for wallet $walletId is not received: '
                'invoice $invoiceId cannot be checked: $lookupError');
            return SPVValidationResult(
              txid: txidHex,
              isValid: false,
              validationError: 'Cannot check $txidHex against invoice $invoiceId: $lookupError',
              targetWalletId: walletId,
              unreadableOutputs: unreadableOutputs,
            );
          }
        }

        // If invoice ID is provided, validate outputs match invoice addresses
        // The wallet's UTXOs, and the outputs that pay the invoice: an
        // invoice's multisig output the wallet cannot spend alone pays the
        // invoice but is no wallet UTXO (bead libspiffy-n0p).
        final (:spendableUTXOs, :invoiceOutputs) =
            _extractSpendableUTXOs(transaction, outputLocks, ownership, walletId, invoice);
        final spentUTXOs = _extractSpentUTXOs(transaction, ownership);
        
        // Step 3.5: Calculate transaction fee (if there are spent UTXOs)
        BigInt? transactionFee;
        if (spentUTXOs.isNotEmpty) {
          transactionFee = await _calculateTransactionFee(transaction, beef);
          if (transactionFee != null) {
          }
        }

        // Step 4: If invoice-based, verify payment matches invoice
        // expectations, also when no output pays it (that is an underpayment,
        // not a valid receive with nothing in it).
        if (invoiceId != null && invoice != null) {
          final invoiceValidation = _validateInvoicePayment(invoiceId, invoice, invoiceOutputs);
          if (!invoiceValidation.isValid) {
            final error = invoiceValidation.error ?? 'Payment does not match invoice $invoiceId';
            _log.warning('Transaction $txidHex for wallet $walletId is not received: $error');
            return SPVValidationResult(
              txid: txidHex,
              isValid: false,
              validationError: unreadableOutputs.isEmpty
                  ? error
                  : '$error (output(s) ${[for (final o in unreadableOutputs) o['vout']]} could not be read)',
              targetWalletId: walletId,
              unreadableOutputs: unreadableOutputs,
            );
          }
          
          // Mark invoice as paid
          _invoiceCoordinator.tell(MarkInvoicePaidMessage(
            invoiceId: invoiceId,
            txid: txidHex,
            amountReceived: invoiceValidation.totalReceived,
            addressesPaidTo: invoiceOutputs.map((u) => u['address'] as String).toList(),
          ), sender: context.self);
        }


        // Build complete transaction data for recording in transaction history
        final transactionData = await _buildTransactionData(
          transaction,
          beef,
          txIndex,
          spendableUTXOs,
          spentUTXOs,
          ancestors,
        );

        return SPVValidationResult(
          txid: txidHex,
          isValid: true,
          spendableUTXOs: spendableUTXOs,
          spentUTXOs: spentUTXOs,
          targetWalletId: walletId,
          transactionFee: transactionFee,
          transactionData: transactionData,
          unreadableOutputs: unreadableOutputs,
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

  /// The transactions of [beef] that an outgoing BEEF spending outputs of the
  /// unproven [subjectTxid] must carry (bead libspiffy-zsh): every in-BEEF
  /// ancestor reached by walking inputs back from the subject, stopping at
  /// proven transactions ([provenTxids], BUMPs validated), each proven one
  /// with its BUMP. In the BEEF's order; transactions of the BEEF that the
  /// subject does not descend from are left out. Call after
  /// [_checkAncestorCoverage] accepted the subject.
  ///
  /// We cannot fetch these again (no block scanning, no indexer, and ARC
  /// knows only transactions it mined or we broadcast), so they are
  /// journaled with the received transaction.
  List<BeefAncestor> _ancestorsToRetain(BEEF beef, String subjectTxid, Set<String> provenTxids) {
    final indexByTxid = <String, int>{};
    for (var i = 0; i < beef.txs.length; i++) {
      indexByTxid.putIfAbsent(hex.encode(beef.calculateTxid(beef.txs[i])), () => i);
    }

    final needed = <String>{};
    final pending = <String>[subjectTxid];
    while (pending.isNotEmpty) {
      final index = indexByTxid[pending.removeLast()];
      if (index == null) continue;
      final tx = dartsv.Transaction.fromHex(hex.encode(beef.txs[index]));
      for (final input in tx.inputs) {
        final parent = input.prevTxnId;
        if (parent == subjectTxid || !indexByTxid.containsKey(parent) || !needed.add(parent)) continue;
        if (!provenTxids.contains(parent)) pending.add(parent);
      }
    }

    return [
      for (final entry in indexByTxid.entries.toList()..sort((a, b) => a.value.compareTo(b.value)))
        if (needed.contains(entry.key))
          BeefAncestor(
            txid: entry.key,
            rawHex: hex.encode(beef.txs[entry.value]),
            bumpHex: provenTxids.contains(entry.key) ? _bumpFor(beef, entry.value).toHex() : '',
          ),
    ];
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

  /// Asks the wallet (through WalletManagerActor; the aggregate answers
  /// from its event-sourced state) which of the addresses [locks] pay or are
  /// keyed to, and which of [transaction]'s inputs, are its own (watch
  /// addresses included).
  ///
  /// Throws [_OwnershipUnavailable] when the wallet does not exist or does
  /// not answer within [_walletOwnershipTimeout].
  Future<WalletOwnershipResponse> _askWalletOwnership(
    String walletId,
    dartsv.Transaction transaction,
    List<_OutputLock> locks,
  ) async {
    final network = NetworkName.toDartsv(_networkType);
    final query = WalletOwnershipQuery(
      walletId: walletId,
      addresses: {for (final lock in locks) ...lock.candidateAddresses(network)},
      outpoints: {for (final input in transaction.inputs) '${input.prevTxnId}:${input.prevTxnOutputIndex}'},
    );
    final WalletOwnershipResponse answer;
    try {
      answer = await _walletManager.ask<WalletOwnershipResponse>(query, _walletOwnershipTimeout);
    } catch (e) {
      throw _OwnershipUnavailable('wallet $walletId did not answer ($e)');
    }
    if (!answer.walletFound) {
      throw _OwnershipUnavailable(answer.error ?? 'wallet $walletId not found');
    }
    // Watch addresses included: they are journaled and the wallet answers
    // for them; WalletManagerActor journals the ones registered before that
    // from the read model when it loads the wallet (bead libspiffy-p4kv).
    return answer;
  }

  /// How long [_askWalletOwnership] waits for the wallet's answer.
  static const _walletOwnershipTimeout = Duration(seconds: 30);

  /// [output]'s locking script as attribution reads it: its script type,
  /// the address it pays, its multisig keys, or a plugin's reading of it.
  ///
  /// When reading the script throws (a template or a plugin), the lock
  /// carries the [_OutputLock.readError] and no address: the output is
  /// attributed to nobody and reported in the result (bead libspiffy-rp6x).
  _OutputLock _decodeOutputLock(dartsv.TransactionOutput output) {
    String? recognisedAs;
    try {
      // Ensure templates are registered (P2PKH, P2PK, P2SH, etc.)
      // This is idempotent - safe to call multiple times
      dartsv.TemplateRegistry.initialize();
      final templateRegistry = dartsv.ScriptTemplateRegistry();
      final script = output.script;
      final scriptType = templateRegistry.identifyScriptType(script);
      recognisedAs = scriptType;
      final scriptInfo = templateRegistry.extractScriptInfo(script);

      if (scriptInfo == null || scriptType == null) {
        // Fall back to registered plugins
        final pluginResult = PluginRegistry().identifyScript(script);
        if (pluginResult == null) return const _OutputLock();
        recognisedAs = '${pluginResult.pluginId}:${pluginResult.scriptType}';
        final metadata = PluginRegistry().getPlugin(pluginResult.pluginId)?.extractMetadata(script);
        return _OutputLock(
          scriptType: '${pluginResult.pluginId}:${pluginResult.scriptType}',
          address: metadata?['ownerAddress'] as String?,
          pluginMetadata: metadata,
          isPlugin: true,
        );
      }

      String? address;
      BareMultisigScript? multisig;
      switch (scriptType.toLowerCase()) {
        case 'p2pkh':
          // Extract address from pubkey hash
          final pubkeyHash = scriptInfo['pubKeyHash'];
          if (pubkeyHash != null) {
            try {
              address = dartsv.Address.fromPubkeyHash(hex.encode(pubkeyHash), NetworkName.toDartsv(_networkType)).toBase58();
            } catch (e) {
              _log.warning('Failed to derive P2PKH address from pubkey hash: $e');
            }
          }
          break;
        case 'p2pk':
          // dartsv names the key 'publicKey' (an SVPublicKey, with the hex
          // under 'publicKeyHex'); reading 'pubKey' never matched, so no
          // P2PK output was ever credited (bead libspiffy-4fq). The address
          // is the key's P2PKH address, which is how the wallet knows it.
          final pubkey = scriptInfo['publicKey'];
          final pubKeyObj = pubkey is dartsv.SVPublicKey
              ? pubkey
              : pubkey is String
                  ? dartsv.SVPublicKey.fromHex(pubkey)
                  : throw StateError('P2PK script info has no public key');
          address = dartsv.Address.fromPublicKey(pubKeyObj, NetworkName.toDartsv(_networkType)).toBase58();
          break;
        case 'p2sh':
          // P2SH address extraction (placeholder: dartsv may not have
          // direct P2SH address support)
          final scriptHash = scriptInfo['scriptHash'];
          if (scriptHash != null) {
            address = 'p2sh:$scriptHash';
          }
          break;
        case 'p2ms':
          // A bare multisig output. Parsed here, not from dartsv's script
          // info: that names the keys 'publicKeys' (as SVPublicKey), so
          // reading 'pubKeys' never matched and an invoice paid with its
          // multisig output went unrecognised.
          multisig = BareMultisigScript.parse(script);
          break;
      }
      return _OutputLock(scriptType: scriptType, address: address, multisig: multisig);
    } catch (e) {
      return _OutputLock(scriptType: recognisedAs, readError: '$e');
    }
  }

  /// Extract UTXOs we can spend from this transaction
  ///
  /// This method analyzes transaction outputs ([locks], one per output) to
  /// identify those that belong to the specified wallet: by the invoice's
  /// addresses when invoiceId is provided, otherwise by the wallet's own
  /// answer ([ownership]); multisig keys always by the wallet's answer.
  ///
  /// [spendableUTXOs] are the wallet's UTXOs. [invoiceOutputs] are the
  /// outputs that pay the invoice: the wallet UTXOs among them plus any
  /// invoice multisig output the wallet cannot spend alone (bead
  /// libspiffy-n0p), which is attributed to a 'p2ms:m-of-n' descriptor.
  /// Without an invoice both lists hold the wallet UTXOs.
  ///
  /// [invoice] is the invoice the payment is for, already looked up and
  /// found by the caller.
  ({List<Map<String, dynamic>> spendableUTXOs, List<Map<String, dynamic>> invoiceOutputs})
      _extractSpendableUTXOs(
    dartsv.Transaction transaction,
    List<_OutputLock> locks,
    WalletOwnershipResponse? ownership,
    String? walletId,
    InvoiceDetailsResponse? invoice,
  ) {
    final spendableUTXOs = <Map<String, dynamic>>[];
    final invoiceOutputs = <Map<String, dynamic>>[];
    final result = (spendableUTXOs: spendableUTXOs, invoiceOutputs: invoiceOutputs);

    if (walletId == null || ownership == null) {
      return result;
    }

    void addWalletUtxo(Map<String, dynamic> utxo) {
      spendableUTXOs.add(utxo);
      invoiceOutputs.add(utxo);
    }

    // An output paying [address] is ours: with an invoice when the address
    // is one of the invoice's, otherwise when the wallet says it is its own.
    bool paysUs(String address) =>
        invoice != null ? invoice.addresses.contains(address) : ownership.ownedAddresses.contains(address);

    final network = NetworkName.toDartsv(_networkType);
    for (int outputIndex = 0; outputIndex < transaction.outputs.length; outputIndex++) {
      final output = transaction.outputs[outputIndex];
      final lock = locks[outputIndex];
      final address = lock.address;

      if (lock.isPlugin) {
        if (address != null && paysUs(address)) {
          addWalletUtxo({
            'txid': transaction.id,
            'vout': outputIndex,
            'satoshis': output.satoshis.toInt(),
            'script': output.script.toHex(),
            'scriptType': lock.scriptType,
            'address': address,
            'pluginMetadata': lock.pluginMetadata,
          });
        }
        continue;
      }

      final multisig = lock.multisig;
      if (multisig != null) {
        // With an invoice only its outputs count, as for P2PKH.
        if (invoice != null &&
            !_matchesP2MSInvoiceOutput(multisig.publicKeysHex, multisig.threshold, invoice.outputs ?? const [])) {
          continue;
        }
        // One ownership rule for every path (beads viy, n0p): the output
        // is a wallet UTXO only when the wallet holds at least m of its
        // keys. An escrow the wallet cannot spend alone still pays the
        // invoice; the transaction is recorded whole either way.
        final owner = multisig.spendableAloneBy(ownership.ownedAddresses.contains, network);
        Map<String, dynamic> entry(String address) => {
              'txid': transaction.id,
              'vout': outputIndex,
              'satoshis': output.satoshis.toInt(),
              'script': output.script.toHex(),
              'scriptType': lock.scriptType,
              'address': address,
              'publicKeys': multisig.publicKeysHex,
              'threshold': multisig.threshold,
            };
        // The invoice is paid to its multisig output, named by shape;
        // a wallet UTXO is attributed to the first wallet key, as on
        // every other path.
        if (owner != null) spendableUTXOs.add(entry(owner));
        if (invoice != null) {
          invoiceOutputs.add(entry('p2ms:${multisig.threshold}-of-${multisig.publicKeysHex.length}'));
        } else if (owner != null) {
          invoiceOutputs.add(entry(owner));
        } else {
          _log.info('Multisig output ${transaction.id}:$outputIndex is not spendable by '
              'wallet $walletId alone; not a wallet UTXO');
        }
        continue;
      }

      // Check if address matches invoice (if invoice-based) or wallet
      if (address != null && paysUs(address)) {
        addWalletUtxo({
          'txid': transaction.id,
          'vout': outputIndex,  // Use 'vout' to match WalletManagerActor expectation
          'satoshis': output.satoshis.toInt(),
          'script': output.script.toHex(),
          'scriptType': lock.scriptType,
          'address': address,
        });
      }
    }

    return result;
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
  /// The inputs of [transaction] that spend UTXOs the wallet holds unspent,
  /// by the wallet's own answer ([ownership]; bead libspiffy-29t: the read
  /// model may not have a UTXO the wallet received moments earlier).
  ///
  /// CRITICAL: Only returns inputs that the wallet actually owns. When receiving
  /// a payment, this will return empty list since inputs belong to the sender.
  List<Map<String, dynamic>> _extractSpentUTXOs(dartsv.Transaction transaction, WalletOwnershipResponse? ownership) {
    if (ownership == null) return [];
    return [
      for (final (inputIndex, input) in transaction.inputs.indexed)
        if (ownership.unspentOutpoints.contains('${input.prevTxnId}:${input.prevTxnOutputIndex}'))
          {
            'txid': input.prevTxnId,
            'vout': input.prevTxnOutputIndex,
            'inputIndex': inputIndex,
          },
    ];
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

      // Heights above the previous tip: a block a reorganization orphaned
      // (or whose header contradicted a proof) may be active there now,
      // arriving in a later batch than the reorganization (hg0, 10r).
      if (msg.height > _currentHeight) {
        await _reviveProofs(_currentHeight + 1, msg.height);
      }

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
  /// pending and its UTXOs lose their confirmations. The proof is marked
  /// orphaned, here and again (idempotently) by the projection of that event
  /// (rejected instead when it is a pendingHeader proof the active header
  /// contradicts: it never verified, bead azl); it is kept, never deleted
  /// (bead mny). A proof on an orphaned block whose
  /// transaction no wallet holds as confirmed is marked orphaned too. ARCActor
  /// is then told to poll the transactions again; a new proof it obtains is
  /// verified against the active chain before the transaction is confirmed
  /// again.
  ///
  /// Only the rows that may rest on a changed block are read: confirmed rows
  /// above the fork point or without a height
  /// ([ReadModelStorage.getConfirmedTransactionsFromHeight]) and the rows of
  /// the transactions whose proofs name an orphaned block
  /// ([ReadModelStorage.getTransactionsByTxids]), not the confirmed history
  /// of every wallet (bead ctkm).
  ///
  /// A pendingHeader proof whose header is still unknown is left as it is
  /// (bead 10r). Then orphaned and rejected proofs above the fork point that
  /// verify on the new active chain are verified again and their
  /// confirmations restored ([_reviveProofs], beads hg0 and 10r).
  Future<void> _handleHeaderChainReorganized(HeaderChainReorganizedMessage msg) async {
    _currentHeight = msg.newTipHeight;
    final reverted = <String>[];
    final revertedRows = <(String, String)>{}; // (wallet, txid)
    try {
      final orphaned = msg.orphanedBlockHashes.toSet();
      final onOrphanedBlocks = <String, MerkleProof>{};
      for (final hash in orphaned) {
        for (final proof in await _storage.getMerkleProofsForBlock(hash)) {
          onOrphanedBlocks[proof.txid] = proof;
        }
      }

      // Confirmed rows above the fork point or without a height, and the
      // confirmed rows of transactions proven on orphaned blocks; newest
      // first, one entry per (wallet, txid).
      final rows = [
        ...await _storage.getConfirmedTransactionsFromHeight(msg.forkHeight + 1, includeWithoutHeight: true),
        if (onOrphanedBlocks.isNotEmpty)
          for (final tx in await _storage.getTransactionsByTxids(onOrphanedBlocks.keys.toList()))
            if (tx.status == TransactionStatus.confirmed) tx,
      ];
      final candidates = <String, List<BitcoinTransaction>>{}; // txid -> confirmed rows
      final seen = <(String, String)>{};
      for (final tx in _newestFirst(rows)) {
        final walletId = tx.walletId;
        if (walletId == null || walletId.isEmpty || !seen.add((walletId, tx.txid))) continue;
        final height = tx.blockHeight;
        if (onOrphanedBlocks.containsKey(tx.txid) || height == null || height > msg.forkHeight) {
          candidates.putIfAbsent(tx.txid, () => []).add(tx);
        }
      }

      for (final entry in candidates.entries) {
        final walletIds = [for (final tx in entry.value) tx.walletId!];
        final proof = await _storage.getMerkleProof(entry.key);
        final String reason;
        if (proof == null) {
          // Nothing to re-verify. Only a confirmation recorded above the fork
          // point can rest on a changed block; one with no height is left
          // alone rather than reverted on every reorganization.
          if (!entry.value.any((tx) => tx.blockHeight != null && tx.blockHeight! > msg.forkHeight)) continue;
          reason = 'reorganization at height ${msg.forkHeight}: confirmed above the fork point with no stored proof';
        } else {
          final outcome = await _recheckProof(proof);
          if (outcome == null) continue; // still proven on the active chain
          if (outcome.status == ProofHeaderStatus.headerUnknown &&
              ((proof.blockHeight <= msg.forkHeight && !orphaned.contains(proof.blockHash)) ||
                  // Never checked against a header and still none at its
                  // height: nothing it rests on changed (10r).
                  (proof.status == MerkleProofStatus.pendingHeader && proof.blockHash == null))) {
            continue;
          }
          reason = 'reorganization at height ${msg.forkHeight}: ${outcome.status.name}'
              '${outcome.detail == null ? '' : ' (${outcome.detail})'}';
          // A proof that never named a block (pendingHeader) and that the
          // active header contradicts was never verified: rejected (azl).
          if (proof.blockHash == null && outcome.status != ProofHeaderStatus.headerUnknown) {
            await _markRejected(proof);
          } else {
            await _markOrphaned(proof);
          }
        }
        _revertConfirmation(entry.key, walletIds, proof, reason);
        _noteReverted(entry.value);
        reverted.add(entry.key);
        revertedRows.addAll([for (final walletId in walletIds) (walletId, entry.key)]);
      }

      // Proofs on orphaned blocks of transactions no wallet holds as
      // confirmed: no confirmation to take back, but the proof's status
      // must still say its block left the active chain.
      for (final proof in onOrphanedBlocks.values) {
        if (candidates.containsKey(proof.txid)) continue;
        if (await _recheckProof(proof) != null) await _markOrphaned(proof);
      }

      if (reverted.isNotEmpty) {
        _log.warning('Reorganization at height ${msg.forkHeight} (${orphaned.length} block(s) orphaned): '
            'reverted ${reverted.length} confirmation(s)');
        _arcActor?.tell(TransactionConfirmationsRevertedMessage(reverted));
      }
    } catch (e, st) {
      _log.severe('Failed to re-check confirmations after the reorganization at height ${msg.forkHeight}: $e', e, st);
    }
    // After the proofs on the orphaned blocks are marked: a transaction whose
    // current proof was just orphaned may be proven again by an older proof
    // (its rows still read confirmed until the revert above is applied).
    await _reviveProofs(msg.forkHeight + 1, msg.newTipHeight, justReverted: revertedRows);
  }

  /// Orphaned and rejected proofs at heights [fromHeight]..[toHeight], whose
  /// active headers just changed, are checked against the active chain again
  /// (beads hg0 and 10r): an orphaned proof whose block is active again (a
  /// reorganization of a reorganization), or a rejected proof the header
  /// that contradicted it no longer does, verifies. It is stored verified
  /// with the active block's hash (its own row when that row names this
  /// block or none; no row is deleted), unless the transaction has a current
  /// proof.
  ///
  /// The confirmation is restored the way a proof ARC supplies confirms:
  /// each wallet holding the transaction unconfirmed (not failed) is sent
  /// ConfirmTransactionCommand with the BUMP (journaled in
  /// TransactionConfirmedEvent, so a rebuilt read model has the proof) and
  /// MarkUTXOAvailableCommand for its pending outputs of the transaction
  /// (the reverted confirmation had made them pending).
  ///
  /// A row in [justReverted] ((wallet, txid) whose revert was just sent, not
  /// yet applied) is restored although it still reads confirmed, and its
  /// available outputs are made available again after the revert.
  ///
  /// Reads the proofs of those statuses at those heights only
  /// ([ReadModelStorage.getMerkleProofsByStatusBetweenHeights]), and the
  /// transaction rows of the proofs that verify.
  Future<void> _reviveProofs(int fromHeight, int toHeight, {Set<(String, String)> justReverted = const {}}) async {
    if (toHeight < fromHeight) return;
    try {
      final candidates = [
        ...await _storage.getMerkleProofsByStatusBetweenHeights(MerkleProofStatus.orphaned, fromHeight, toHeight),
        ...await _storage.getMerkleProofsByStatusBetweenHeights(MerkleProofStatus.rejected, fromHeight, toHeight),
      ];
      if (candidates.isEmpty) return;
      final current = await _storage.getMerkleProofsBatch({for (final p in candidates) p.txid}.toList());

      final revived = <String, (MerkleProof, ProofHeaderCheck)>{};
      for (final proof in candidates) {
        if (current.containsKey(proof.txid) || revived.containsKey(proof.txid)) continue;
        final check = await _checkProof(proof);
        if (check.isVerified) revived[proof.txid] = (proof, check);
      }
      if (revived.isEmpty) return;

      final restore = <String, Set<String>>{}; // walletId -> txids
      for (final tx in await _storage.getTransactionsByTxids(revived.keys.toList())) {
        final walletId = tx.walletId;
        if (walletId == null || walletId.isEmpty) continue;
        final unconfirmed = tx.status != TransactionStatus.confirmed || justReverted.contains((walletId, tx.txid));
        if (!unconfirmed || tx.status == TransactionStatus.failed) continue;
        restore.putIfAbsent(walletId, () => {}).add(tx.txid);
      }
      for (final MapEntry(key: walletId, value: txids) in restore.entries) {
        for (final txid in txids) {
          final (proof, check) = revived[txid]!;
          _walletManager.tell(WalletCommandMessage(walletId, ConfirmTransactionCommand(
            walletId: walletId,
            txid: txid,
            blockHeight: check.blockHeight,
            blockHash: check.blockHash,
            bumpHex: proof.merkleProof.single,
          )));
        }
        for (final utxo in await _storage.getUTXOs(walletId)) {
          if (!txids.contains(utxo.txid)) continue;
          // A revert just sent (not applied yet) makes an available output
          // pending before this command reaches the wallet.
          final demoted = justReverted.contains((walletId, utxo.txid))
              ? const {UTXOStatus.pending, UTXOStatus.available}
              : const {UTXOStatus.pending};
          final pendingOutput = demoted.contains(utxo.status) ||
              (utxo.status == UTXOStatus.reserved && demoted.contains(utxo.statusBeforeReservation));
          if (!pendingOutput) continue;
          _walletManager.tell(WalletCommandMessage(walletId, MarkUTXOAvailableCommand(
            walletId: walletId,
            txid: utxo.txid,
            vout: utxo.vout,
          )));
        }
      }
      _log.warning('${revived.length} orphaned or rejected proof(s) at heights $fromHeight-$toHeight verify on the '
          'active chain again: ${revived.keys.toList()}; confirmation restored in ${restore.length} wallet(s)');
    } catch (e, st) {
      _log.warning('Failed to re-check orphaned and rejected proofs at heights $fromHeight-$toHeight: $e', e, st);
    }
  }

  /// Proofs stored before their block header was known have the status
  /// [MerkleProofStatus.pendingHeader] (WalletProjection). Once headers up to
  /// [upToHeight] are stored they are checked (zvj part 1): a match marks the
  /// proof verified with the real block hash; a mismatch marks it rejected
  /// (kept, beads mny and azl; a pendingHeader row that still names a block,
  /// which projections before azl could leave, is marked orphaned instead)
  /// and reverts the confirmation like a reorganization does. Proofs whose
  /// header is still unknown stay as they are. Then confirmations whose only
  /// proof is rejected are taken back ([_revertRejectedConfirmations]).
  ///
  /// The wallets holding the failed transactions as confirmed are read once,
  /// by txid, after the checks: not the confirmed history per proof (ctkm).
  Future<void> _recheckUnverifiedProofs(int upToHeight) async {
    final reverted = <String>[];
    try {
      final unverified = await _storage.getMerkleProofsByStatus(MerkleProofStatus.pendingHeader);

      final failed = <(MerkleProof, ProofHeaderCheck)>[];
      for (final proof in unverified) {
        if (proof.blockHeight > upToHeight) continue;
        final outcome = await _recheckProof(proof);
        if (outcome == null || outcome.status == ProofHeaderStatus.headerUnknown) continue;

        if (proof.blockHash == null) {
          await _markRejected(proof);
        } else {
          await _markOrphaned(proof);
        }
        failed.add((proof, outcome));
      }

      if (failed.isNotEmpty) {
        final confirmed = _confirmedRowsOf(await _storage.getTransactionsByTxids([for (final (proof, _) in failed) proof.txid]));
        for (final (proof, outcome) in failed) {
          final rows = confirmed[proof.txid] ?? const <BitcoinTransaction>[];
          _revertConfirmation(proof.txid, [for (final tx in rows) tx.walletId!], proof,
              'proof imported before its block header does not match header at height '
              '${proof.blockHeight}: ${outcome.status.name}${outcome.detail == null ? '' : ' (${outcome.detail})'}');
          _noteReverted(rows);
          reverted.add(proof.txid);
        }
      }
      if (reverted.isNotEmpty) {
        _log.severe('${reverted.length} imported proof(s) do not match the block headers that arrived; '
            'confirmations reverted: $reverted');
        _arcActor?.tell(TransactionConfirmationsRevertedMessage(reverted));
      }
    } catch (e, st) {
      _log.warning('Failed to re-check unverified proofs: $e', e, st);
    }
    // The rows of the txids just reverted were read above: every confirmed
    // one was reverted, so they are not read again.
    await _revertRejectedConfirmations(alreadyReverted: reverted.toSet());
  }

  /// The confirmations a revert was sent for: (wallet, txid) -> `updatedAt`
  /// of the confirmed row it was sent for. Later header notifications do not
  /// revert that same confirmation again before the projection has applied
  /// the first revert; a later confirmation of the transaction (its row
  /// written again) is a different one and is reverted too if it also rests
  /// only on a rejected proof (bead 10r: the guard was per txid, for the
  /// actor's lifetime).
  final Map<(String, String), DateTime> _revertsSent = {};

  /// Record that a revert was sent for each confirmed row of [rows].
  void _noteReverted(Iterable<BitcoinTransaction> rows) {
    for (final tx in rows) {
      final walletId = tx.walletId;
      if (walletId != null && walletId.isNotEmpty) _revertsSent[(walletId, tx.txid)] = tx.updatedAt;
    }
  }

  /// A transaction held as confirmed whose proof is
  /// [MerkleProofStatus.rejected] and which has no current proof is not
  /// confirmed (bead azl). WalletProjection stores such a proof when the
  /// header at its height contradicts it (a replay after that header
  /// changed, or a header change between the live check and the event).
  /// Each wallet holding it as confirmed has the confirmation reverted, as
  /// for a pendingHeader proof that fails its header, and ARCActor is asked
  /// to poll for a real proof. Txids in [alreadyReverted] (their confirmed
  /// rows were just reverted) are skipped.
  Future<void> _revertRejectedConfirmations({Set<String> alreadyReverted = const {}}) async {
    try {
      final rejected = <String, MerkleProof>{
        for (final proof in await _storage.getMerkleProofsByStatus(MerkleProofStatus.rejected))
          if (!alreadyReverted.contains(proof.txid)) proof.txid: proof,
      };
      if (rejected.isEmpty) return;

      for (final txid in (await _storage.getMerkleProofsBatch(rejected.keys.toList())).keys) {
        rejected.remove(txid); // a current proof backs the transaction
      }
      if (rejected.isEmpty) return;
      // The rows of those transactions only (ctkm). A rejected proof of a
      // received ancestor belongs to no wallet transaction.
      final rows = await _storage.getTransactionsByTxids(rejected.keys.toList());
      for (final tx in rows) {
        // A row that changed since its revert was sent: the revert was
        // applied (or the transaction confirmed again), so forget it.
        final key = (tx.walletId ?? '', tx.txid);
        final sentFor = _revertsSent[key];
        if (sentFor != null && (tx.status != TransactionStatus.confirmed || sentFor != tx.updatedAt)) {
          _revertsSent.remove(key);
        }
      }
      final wallets = _confirmedRowsOf([
        for (final tx in rows)
          if (_revertsSent[(tx.walletId ?? '', tx.txid)] != tx.updatedAt) tx,
      ]);
      if (wallets.isEmpty) return;

      for (final entry in wallets.entries) {
        final proof = rejected[entry.key]!;
        _revertConfirmation(entry.key, [for (final tx in entry.value) tx.walletId!], proof,
            'its only proof does not match the block header at height ${proof.blockHeight} (rejected)');
        _noteReverted(entry.value);
      }
      _log.severe('${wallets.length} confirmation(s) rested only on rejected proofs; reverted: ${wallets.keys.toList()}');
      _arcActor?.tell(TransactionConfirmationsRevertedMessage(wallets.keys.toList()));
    } catch (e, st) {
      _log.warning('Failed to revert confirmations resting on rejected proofs: $e', e, st);
    }
  }

  /// Mark the pendingHeader [proof] (no block hash) rejected: the header at
  /// its height contradicts it (bead azl). Its own row is updated in place
  /// and a current proof of the transaction is left alone.
  Future<void> _markRejected(MerkleProof proof) async {
    await _storage.storeMerkleProof(proof.txid, MerkleProof(
      txid: proof.txid,
      blockHash: null,
      blockHeight: proof.blockHeight,
      position: proof.position,
      merkleProof: proof.merkleProof,
      createdAt: proof.createdAt,
      status: MerkleProofStatus.rejected,
    ));
  }

  /// Mark [proof] orphaned if it is still the current proof of its
  /// transaction (a newer proof stored meanwhile is left alone).
  Future<void> _markOrphaned(MerkleProof proof) async {
    await _storage.markMerkleProofOrphaned(
      proof.txid,
      blockHash: proof.blockHash,
      onlyIfMerkleProof: proof.merkleProof,
    );
  }

  /// Check a stored [proof] against the active header chain. Returns null
  /// when it verifies (after recording it as verified with the active
  /// block's hash, if it was not already), otherwise the failed check.
  Future<ProofHeaderCheck?> _recheckProof(MerkleProof proof) async {
    final check = await _checkProof(proof);
    return check.isVerified ? null : check;
  }

  /// [_recheckProof], returning the check whatever its outcome.
  Future<ProofHeaderCheck> _checkProof(MerkleProof proof) async {
    // A proof that is not a single stored BUMP (pre-SPV-06 layout) does not
    // parse and comes back malformed.
    final check = await checkBumpHexAgainstHeaders(
      txid: proof.txid,
      bumpHex: proof.merkleProof.length == 1 ? proof.merkleProof.single : '',
      headerAt: _storage.getBlockHeaderByHeight,
    );
    if (!check.isVerified) return check;
    if (check.blockHash != proof.blockHash ||
        check.txIndex != proof.position ||
        proof.status != MerkleProofStatus.verified) {
      await _storage.storeMerkleProof(proof.txid, MerkleProof(
        txid: proof.txid,
        blockHash: check.blockHash!,
        blockHeight: check.blockHeight!,
        merkleProof: proof.merkleProof,
        position: check.txIndex!,
        status: MerkleProofStatus.verified,
      ));
    }
    return check;
  }

  /// txid -> the confirmed rows in [rows] (each with a wallet id), newest
  /// row first (the order the confirmed listing gave before ctkm).
  static Map<String, List<BitcoinTransaction>> _confirmedRowsOf(List<BitcoinTransaction> rows) {
    final confirmed = <String, List<BitcoinTransaction>>{};
    for (final tx in _newestFirst(rows)) {
      final walletId = tx.walletId;
      if (tx.status == TransactionStatus.confirmed && walletId != null && walletId.isNotEmpty) {
        confirmed.putIfAbsent(tx.txid, () => []).add(tx);
      }
    }
    return confirmed;
  }

  /// [rows] sorted newest first (`createdAt` descending); rows with equal
  /// times keep their order. Storage returns them in this order already.
  static List<BitcoinTransaction> _newestFirst(List<BitcoinTransaction> rows) {
    final sorted = List.of(rows);
    mergeSort<BitcoinTransaction>(sorted, compare: (a, b) => b.createdAt.compareTo(a.createdAt));
    return sorted;
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
        final txid = hex.encode(beef.calculateTxid(txData));
        
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
    switch (message) {
      case final ReceiveTransactionMessage msg:
        context.sender?.tell(SPVValidationResult(
          txid: msg.transactionId,
          isValid: false,
          validationError: error,
          targetWalletId: msg.targetWalletId,
        ));
        break;
      case final ValidateBEEFMessage msg:
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
  ///
  /// [invoice] is the found invoice [invoiceId] (looked up once per receive).
  _InvoiceValidationResult _validateInvoicePayment(
    String invoiceId,
    InvoiceDetailsResponse invoice,
    List<Map<String, dynamic>> spendableUTXOs,
  ) {
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
        error: 'Payment amount ($totalReceived sats) is less than invoice amount ($expectedAmount sats) '
            'of invoice $invoiceId',
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
    List<BeefAncestor> ancestors,
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
        'ancestors': ancestors,
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
        'ancestors': ancestors,
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
/// An output's locking script as SPVActor reads it for attribution.
class _OutputLock {
  /// dartsv's template type ('p2pkh', 'p2ms', ...), or
  /// '<pluginId>:<scriptType>' for a script a plugin recognises; null when
  /// nothing recognises the script.
  final String? scriptType;

  /// The address the output pays: a P2PKH or P2PK address, a 'p2sh:<hash>'
  /// placeholder, or a plugin script's owner address.
  final String? address;

  /// The script as bare multisig, when it is one.
  final BareMultisigScript? multisig;

  final Map<String, dynamic>? pluginMetadata;
  final bool isPlugin;

  /// Why the script could not be read (a template or plugin threw); null
  /// when it was read, or when nothing recognises it.
  final String? readError;

  const _OutputLock({
    this.scriptType,
    this.address,
    this.multisig,
    this.pluginMetadata,
    this.isPlugin = false,
    this.readError,
  });

  /// The addresses whose ownership decides whether the output is the
  /// wallet's: the address it pays and, for multisig, each key's address.
  Iterable<String> candidateAddresses(dartsv.NetworkType network) => [
        if (address case final address?) address,
        if (multisig case final multisig?)
          for (final keyAddress in multisig.keyAddresses(network))
            if (keyAddress != null) keyAddress,
      ];
}

/// The target wallet cannot say which outputs are its own ([reason]).
class _OwnershipUnavailable implements Exception {
  final String reason;
  _OwnershipUnavailable(this.reason);

  @override
  String toString() => reason;
}
