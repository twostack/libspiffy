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
// Both message libraries declare RetrieveMerkleProofMessage; ARCActor handles
// the one in wallet_messages.dart (bead libspiffy-0lx).
import 'wallet_messages.dart' as wmsg show RetrieveMerkleProofMessage;
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
    Duration rejectedProofFullSweepInterval = const Duration(hours: 1),
    Duration awaitingProofSweepInterval = const Duration(minutes: 30),
    DateTime Function()? clock,
  }) : _walletManager = walletManager,
       _invoiceCoordinator = invoiceCoordinator,
       _storage = storage,
       _networkType = networkType,
       _arcActor = arcActor,
       _headerSyncActor = headerSyncActor,
       _rejectedProofFullSweepInterval = rejectedProofFullSweepInterval,
       _awaitingProofSweepInterval = awaitingProofSweepInterval,
       _clock = clock ?? DateTime.now;

  /// How long a check for confirmations resting only on rejected proofs may
  /// go on reading only recent status changes before one reads every
  /// rejected proof again ([_revertRejectedConfirmations], bead hccp).
  final Duration _rejectedProofFullSweepInterval;

  /// The time source of those checks (injectable for tests).
  final DateTime Function() _clock;
  
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
  /// (bead libspiffy-yix) and replays the receives parked for headers we now
  /// hold (bead libspiffy-vfai): headers that arrived while the node was
  /// down, or a check a shutdown interrupted, are not left until the next
  /// header notification. Runs before the first message is handled.
  @override
  Future<void> preStart() async {
    await _loadCurrentChainState();
    if (_currentHeight > 0) {
      await _recheckUnverifiedProofs(_currentHeight);
      // Receives parked before the last shutdown whose headers have arrived
      // since (bead libspiffy-vfai): the wallet is credited without the
      // counterparty sending the BEEF again.
      await _replayParkedReceives(_currentHeight);
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
  Future<void> _handleReceiveTransaction(ReceiveTransactionMessage msg) async =>
      _runReceive(msg, context.sender);

  /// One pass of the receive: validate, then tell the wallet manager and
  /// [replyTo]. Called for a fresh delivery and again for a receive that was
  /// parked waiting for a block header (bead libspiffy-68mz), which is why
  /// the sender is a parameter rather than `context.sender`.
  Future<void> _runReceive(ReceiveTransactionMessage msg, ActorRef? replyTo) async {
    _awaitingHeaderHeight = null;
    try {
      // This is the core SPV process
      final validated = await _validateReceivedTransaction(
        msg.transactionId,
        msg.beef,
        msg.targetWalletId,
        msg.invoiceId,
      );
      // Who handed it to us, carried to the wallet so the payment is
      // journaled with its counterparty marker (bead libspiffy-cq16). One
      // place, so every branch above that builds a result carries it.
      final validationResult = validated.withCounterpartyMarker(msg.fromCounterparty, requestId: msg.requestId);

      if (_awaitingHeaderHeight case final height?) {
        _awaitingHeaderHeight = null;
        await _parkReceive(msg, replyTo, height);
      } else {
        // A verdict more headers cannot change: the receive stops waiting
        // (bead libspiffy-vfai). The row is kept with what became of it.
        await _resolveParked(msg, validationResult.isValid
            ? 'recorded'
            : 'failed: ${validationResult.validationError}');
      }

      // Send validation result to WalletManager
      _walletManager.tell(validationResult);

      // Also respond to sender if this was a request
      replyTo?.tell(validationResult);


    } catch (e) {
      _awaitingHeaderHeight = null;
      await _resolveParked(msg, 'failed: $e');

      final errorResult = SPVValidationResult(
        txid: msg.transactionId, // Placeholder
        isValid: false,
        validationError: e.toString(),
        targetWalletId: msg.targetWalletId,
      ).withCounterpartyMarker(msg.fromCounterparty, requestId: msg.requestId);

      _walletManager.tell(errorResult);
      replyTo?.tell(errorResult);
    }
  }

  /// Retrieve Block header from storage with opportunistic P2P fetch fallback
  /// 
  /// First tries to retrieve the header from local storage. If not found and
  /// HeaderSyncActor is available, attempts to fetch the header from the Bitcoin
  /// P2P network. This enables SPV validation to succeed even when the counterparty
  /// references block headers we haven't synced yet.
  /// Throws [_HeaderUnavailable] when we have no header at [blockHeight] and
  /// none can be fetched (bead libspiffy-68mz): that proves nothing either
  /// way, unlike a header we hold that contradicts a proof, and callers keep
  /// the evidence and try again once the header arrives.
  Future<BlockHeader> _getBlockHeader(int blockHeight) async {
    // Try local storage first
    final BlockHeader? header;
    try {
      header = await _storage.getBlockHeaderByHeight(blockHeight);
    } catch (e) {
      throw _HeaderUnavailable(blockHeight, 'reading the stored header failed: $e');
    }
    if (header != null) {
      return header;
    }

    // Header not found locally - try opportunistic fetch from P2P network

    if (_headerSyncActor == null) {
      throw _HeaderUnavailable(blockHeight, 'not synced, and no HeaderSyncActor for an opportunistic fetch');
    }

    // Request specific header from HeaderSyncActor. A reply that is not a
    // SpecificHeaderResponseMessage (an older HeaderSyncActor answering with
    // SPVErrorMessage, bead libspiffy-lplr) throws a cast error here; it
    // means the same thing as an unsuccessful response: no header.
    final SpecificHeaderResponseMessage response;
    try {
      response = await _headerSyncActor!.ask<SpecificHeaderResponseMessage>(
        RequestSpecificHeaderMessage(
          blockHeight: blockHeight,
          timeout: Duration(seconds: 10),
        ),
        Duration(seconds: 15),
      );
    } catch (e) {
      throw _HeaderUnavailable(blockHeight, 'the header sync actor did not answer: $e');
    }

    if (response.success && response.header != null) {
      return response.header!;
    }
    throw _HeaderUnavailable(blockHeight, 'not synced and no peer supplied it: ${response.error}');
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
        // cannot be spent without (bead zsh); for a proven subject they are
        // retained too (bead libspiffy-fggl), since nothing can hand us a
        // BEEF's transactions and proofs again.
        var ancestors = const <BeefAncestor>[];

        // The BEEF members whose BUMP verifies against our active header
        // chain, subject and ancestor alike (bead libspiffy-fggl): each is
        // proven mined, and the wallet confirms the ones it recorded itself.
        final provenTxids = <String>{};
        final proven = <ProvenTransaction>[];

        if (hasProof) {
          // This transaction has a proof - validate it directly via SPV

          final bump = _bumpFor(beef, txIndex);
          final BlockHeader blockHeader;
          try {
            blockHeader = await _getBlockHeader(bump.blockHeight);
          } on _HeaderUnavailable catch (e) {
            // Not synced that far: the proof is neither good nor bad yet
            // (bead libspiffy-68mz). Keep the BEEF and try again when the
            // header lands, rather than dropping evidence nothing can hand
            // us again.
            return await _retainUntilHeaders(beef, txidHex, walletId, {e.blockHeight}, e.toString());
          }


          // Validate this transaction's merkle proof
          final isValidTx = await beef.validateTransactionWithBlockHeader(txid, blockHeader);

          if (!isValidTx) {
            // The header we hold at that height contradicts the subject's own
            // proof. The receive fails, but the BEEF is kept first (bead
            // libspiffy-b81q): its transactions and its contradicted BUMPs
            // are evidence of what a counterparty handed us, and nothing can
            // hand them to us again.
            await _retainContradictedBeef(beef, txidHex,
                'its own merkle proof does not match the header at that height');
            return SPVValidationResult(
              txid: txidHex,
              isValid: false,
              validationError: 'Transaction not connected to existing blockheader',
              targetWalletId: walletId,
            );
          }
          provenTxids.add(txidHex);
          proven.add(ProvenTransaction(
            txid: txidHex,
            bumpHex: bump.toHex(),
            blockHeight: bump.blockHeight,
            blockHash: blockHeader.blockHash().toString(),
          ));

          // The rest of the BEEF is examined too (bead libspiffy-fggl): it
          // held proofs we cannot fetch again, and one of its members may be
          // a transaction of ours that is mined. Only the subject's own
          // proof decides whether this receive is valid, so a member whose
          // block header we do not have, or whose proof does not match, is
          // retained unproven (its BUMP is still kept) instead of failing
          // the receive.
          for (var i = 0; i < beef.txs.length; i++) {
            if (i == txIndex || !beef.hasMerkle[i]) continue;
            try {
              final member = await _verifyProvenMember(beef, i);
              provenTxids.add(member.txid);
              proven.add(member);
            } catch (e) {
              _log.warning('Transaction $i of the BEEF carrying $txidHex is not proven against our '
                  'headers, and is retained unconfirmed: $e');
            }
          }

          ancestors = _ancestorsToRetain(beef, txidHex, provenTxids);
        } else {
          // This transaction has NO proof (unconfirmed payment transaction)
          // Validate that all its ancestors (inputs) have valid merkle proofs
          
          // Validate ALL transactions in BEEF that have proofs.
          //
          // Two failures that used to look alike are told apart (bead
          // libspiffy-68mz): a header we hold that contradicts the proof is
          // fatal — the counterparty's evidence is wrong — while a height we
          // have not synced to proves nothing either way, so the BEEF is
          // retained and the receive tried again when the header arrives.
          // The proven-subject branch is already lenient about a member it
          // cannot verify (V-56); the two branches now agree on what "we
          // have no header there" means.
          final missingHeights = <int>{};
          final unavailable = <String>[];
          for (int i = 0; i < beef.txs.length; i++) {
            if (!beef.hasMerkle[i]) {
              continue; // Skip transactions without proofs (like this payment tx)
            }

            final ProvenTransaction member;
            try {
              member = await _verifyProvenMember(beef, i);
            } on _ProofRejected catch (rejected) {
              // A header we hold contradicts this ancestor's proof: fatal,
              // and it stays fatal. The BEEF is retained first (bead
              // libspiffy-b81q), transactions and contradicted BUMPs alike,
              // as the proven-subject branch has done since V-56: a rejected
              // proof is evidence, and it cannot be fetched again.
              await _retainContradictedBeef(beef, txidHex, '$rejected');
              return SPVValidationResult(
                txid: txidHex,
                isValid: false,
                validationError: 'Ancestor transaction at index $i failed merkle proof validation',
                targetWalletId: walletId,
              );
            } on _HeaderUnavailable catch (e) {
              missingHeights.add(e.blockHeight);
              unavailable.add('index $i: $e');
              continue;
            }
            provenTxids.add(member.txid);
            proven.add(member);
          }
          if (missingHeights.isNotEmpty) {
            return await _retainUntilHeaders(beef, txidHex, walletId, missingHeights, unavailable.join('; '));
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
          provenTransactions: proven,
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

  /// The BEEF cannot be judged yet because we hold no header at [heights]
  /// (bead libspiffy-68mz).
  ///
  /// Nothing is dropped: every transaction of the BEEF goes into the shared
  /// ancestor store and every BUMP is filed as a
  /// [MerkleProofStatus.pendingHeader] proof, so the evidence survives even
  /// if this process dies before the header arrives — the counterparty
  /// cannot hand it to us again. The receive itself is parked
  /// ([_parkReceive], set up by [_handleReceiveTransaction]) and replayed
  /// from [_handleBlockHeaderStored], so the wallet is credited without the
  /// counterparty re-sending.
  ///
  /// The caller is still answered now, with an invalid result naming the
  /// missing heights: a receive that silently never answers is worse than
  /// one that says "not yet".
  Future<SPVValidationResult> _retainUntilHeaders(
      BEEF beef, String txidHex, String? walletId, Set<int> heights, String detail) async {
    final needed = heights.reduce((a, b) => a > b ? a : b);
    try {
      await _retainBeef(beef);
    } catch (e, st) {
      _log.severe('Failed to retain the BEEF carrying $txidHex while its block header(s) '
          '${heights.toList()..sort()} are missing: $e', e, st);
    }
    _awaitingHeaderHeight = needed;
    _log.info('Transaction $txidHex is retained until the block header(s) '
        '${heights.toList()..sort()} arrive: $detail');
    return SPVValidationResult(
      txid: txidHex,
      isValid: false,
      validationError: 'Block header(s) at height(s) ${(heights.toList()..sort()).join(', ')} are not synced yet, '
          'so the merkle proof(s) in this BEEF prove nothing yet. The BEEF is retained and the receive is '
          'retried automatically once the headers arrive ($detail)',
      targetWalletId: walletId,
    );
  }

  /// Store every transaction of [beef] as ancestor evidence and every BUMP
  /// it carries as a proof row (beads libspiffy-68mz and libspiffy-b81q).
  ///
  /// One retention rule for a received BEEF, whatever the verdict on the
  /// receive: nothing can hand us these transactions and proofs again.
  /// Each BUMP is filed under the same rule the projection uses for the
  /// proofs it journals:
  /// * it verifies against the active header at its height: stored
  ///   [MerkleProofStatus.verified] with that block's hash;
  /// * we hold no header there: stored [MerkleProofStatus.pendingHeader], to
  ///   be checked when the header arrives;
  /// * the header we hold contradicts it, or it cannot be walked at all:
  ///   stored [MerkleProofStatus.rejected] — evidence that a counterparty
  ///   handed us something that does not match our chain, which is exactly
  ///   what the receive was failed for.
  ///
  /// A transaction that already has a current proof keeps it: a verified or
  /// pendingHeader row is never displaced here, and a rejected row never
  /// becomes the current proof (`storeMerkleProof` stores it without a block
  /// hash and leaves the current proof alone). Nothing is ever deleted.
  Future<void> _retainBeef(BEEF beef) async {
    final txids = [for (final tx in beef.txs) hex.encode(beef.calculateTxid(tx))];
    for (var i = 0; i < beef.txs.length; i++) {
      await _storage.storeAncestorTransaction(txids[i], hex.encode(beef.txs[i]));
    }
    final current = await _storage.getMerkleProofsBatch(txids);
    for (var i = 0; i < beef.txs.length; i++) {
      if (!beef.hasMerkle[i]) continue;
      final BUMP bump;
      try {
        bump = _bumpFor(beef, i);
      } catch (e) {
        _log.warning('BUMP of ${txids[i]} not retained: $e');
        continue;
      }
      final check = await checkBumpAgainstHeaders(
        txid: txids[i],
        bump: bump,
        headerAt: _storage.getBlockHeaderByHeight,
      );
      if (check.txIndex == null) {
        // The BUMP does not place this txid in a block at all: there is no
        // row to write (a proof row is keyed by its position).
        _log.warning('BUMP of ${txids[i]} not retained: it does not prove that transaction ($check)');
        continue;
      }
      final MerkleProofStatus status;
      switch (check.status) {
        case ProofHeaderStatus.verified:
        case ProofHeaderStatus.headerUnknown:
          // Never displace the transaction's current proof.
          if (current.containsKey(txids[i])) continue;
          status = check.isVerified ? MerkleProofStatus.verified : MerkleProofStatus.pendingHeader;
        case ProofHeaderStatus.rootMismatch:
        case ProofHeaderStatus.malformed:
          status = MerkleProofStatus.rejected;
      }
      await _storage.storeMerkleProof(txids[i], MerkleProof(
        txid: txids[i],
        blockHash: check.isVerified ? check.blockHash : null,
        blockHeight: bump.blockHeight,
        position: check.txIndex!,
        merkleProof: [bump.toHex()],
        status: status,
      ));
    }
  }

  /// A BEEF whose proof our own header chain contradicts (bead
  /// libspiffy-b81q). The receive fails — that is not in question — but the
  /// evidence is kept first: the transactions go to the ancestor store and
  /// the contradicted BUMPs are filed as rejected proof rows, which is what
  /// the proven-subject branch has done since V-56 (through the journal).
  /// A rejected row never displaces a verified one.
  ///
  /// Retention must never turn a bad receive into a good one, so a failure
  /// here is logged and the receive still fails.
  Future<void> _retainContradictedBeef(BEEF beef, String txidHex, String reason) async {
    try {
      await _retainBeef(beef);
      _log.warning('The receive of $txidHex is refused ($reason); its transactions and its '
          'contradicted proof(s) are retained as evidence');
    } catch (e, st) {
      _log.severe('Failed to retain the BEEF carrying $txidHex after refusing it ($reason): $e', e, st);
    }
  }

  /// Set by [_retainUntilHeaders] while a receive is being validated: the
  /// header height that receive is waiting for. Read (and cleared) by
  /// [_handleReceiveTransaction], which holds the message and the sender.
  /// Safe as actor state because a message is handled to completion before
  /// the next one is taken from the mailbox.
  int? _awaitingHeaderHeight;

  /// The reply targets of the receives this process parked, by
  /// [_parkKey]. In memory only: an ActorRef cannot be stored, and after a
  /// restart there is nobody left waiting for an answer. The receive itself
  /// is durable ([PendingReceive]), so losing an entry here loses the direct
  /// reply, never the retry.
  final Map<String, ActorRef> _parkedSenders = {};

  /// The receives this process parked or replayed ([_parkKey]), so a verdict
  /// on one of them resolves its stored row and a fresh delivery that never
  /// waited writes nothing.
  final Set<String> _parkedKeys = {};

  /// How many reply targets are remembered. Beyond this the oldest is
  /// forgotten: its receive is still replayed from storage, and its result
  /// still reaches the wallet manager, but the original caller is not told.
  static const int _maxParkedSenders = 64;

  /// How many parked receives one header notification replays. The rest are
  /// read by the next notification (and at the next start), so the bound
  /// costs time, never a receive.
  static const int _maxReplayedPerNotification = 64;

  /// Key of a parked receive: the wallet it names (empty for none) and the
  /// subject txid, exactly as [PendingReceive] is keyed.
  static String _parkKey(String? walletId, String txid) => '${walletId ?? ''}|$txid';

  /// Park [msg] until headers reach [neededHeight] (bead libspiffy-vfai).
  ///
  /// The receive is stored as it was handed to us, so the header arriving
  /// after a restart still credits the wallet: nothing can ask the
  /// counterparty to send the BEEF again. Re-parking the same (wallet, txid)
  /// updates that row rather than queueing it twice, so a BEEF delivered
  /// twice is replayed once.
  Future<void> _parkReceive(ReceiveTransactionMessage msg, ActorRef? sender, int neededHeight) async {
    final key = _parkKey(msg.targetWalletId, msg.transactionId);
    _parkedKeys.add(key);
    if (sender != null) {
      _parkedSenders[key] = sender;
      while (_parkedSenders.length > _maxParkedSenders) {
        final dropped = _parkedSenders.keys.first;
        _parkedSenders.remove(dropped);
        _log.info('More than $_maxParkedSenders receives are waiting for block headers; the caller that '
            'delivered $dropped is no longer told its outcome directly (the receive itself is stored '
            'and still replayed when the headers arrive)');
      }
    }
    final now = DateTime.now();
    try {
      await _storage.storePendingReceive(PendingReceive(
        walletId: msg.targetWalletId ?? '',
        txid: msg.transactionId,
        beefHex: hex.encode(msg.beef.serialize()),
        fromCounterparty: msg.fromCounterparty,
        invoiceId: msg.invoiceId,
        neededHeight: neededHeight,
        createdAt: now,
        updatedAt: now,
      ));
    } catch (e, st) {
      _log.severe('The receive of ${msg.transactionId} waiting for the header at height $neededHeight '
          'could not be stored: it is retried only while this process lives ($e)', e, st);
      _parkedSendersFallback[key] = (msg, sender, neededHeight);
    }
  }

  /// Receives that could not be stored (the storage refused): retried from
  /// memory, so a storage failure is not also a lost retry.
  final Map<String, (ReceiveTransactionMessage, ActorRef?, int)> _parkedSendersFallback = {};

  /// Record what became of the receive of [msg], if it was parked. Keeps the
  /// row (evidence of what a counterparty handed us) and stops it being
  /// replayed by every later header.
  Future<void> _resolveParked(ReceiveTransactionMessage msg, String resolution) async {
    final key = _parkKey(msg.targetWalletId, msg.transactionId);
    _parkedSendersFallback.remove(key);
    // Only a receive this process parked or replayed can have a row; a fresh
    // delivery that never waited costs no write.
    if (!_parkedKeys.remove(key)) return;
    try {
      await _storage.resolvePendingReceive(
          msg.targetWalletId ?? '', msg.transactionId, resolution);
    } catch (e) {
      _log.warning('Could not record the outcome of the parked receive of ${msg.transactionId}: $e');
    }
  }

  /// Replays the receives parked for headers up to [height]
  /// (beads libspiffy-68mz and libspiffy-vfai). Each runs the full validation
  /// again, so a BEEF whose proofs now check out is recorded exactly as a
  /// fresh delivery would be, without the counterparty re-sending — after a
  /// restart too, since the parked receives are read from storage.
  Future<void> _replayParkedReceives(int height) async {
    final List<PendingReceive> waiting;
    try {
      waiting = await _storage.getPendingReceivesUpToHeight(height, limit: _maxReplayedPerNotification);
    } catch (e, st) {
      _log.warning('Could not read the receives waiting for block headers up to $height: $e', e, st);
      return;
    }
    final fallback = [
      for (final entry in _parkedSendersFallback.entries.toList())
        if (entry.value.$3 <= height) entry,
    ];
    if (waiting.isEmpty && fallback.isEmpty) return;

    for (final row in waiting) {
      final ReceiveTransactionMessage msg;
      try {
        msg = ReceiveTransactionMessage(
          transactionId: row.txid,
          beef: BEEF.parse(Uint8List.fromList(hex.decode(row.beefHex))),
          fromCounterparty: row.fromCounterparty,
          targetWalletId: row.walletId.isEmpty ? null : row.walletId,
          invoiceId: row.invoiceId,
        );
      } catch (e) {
        _log.severe('The stored BEEF of the parked receive of ${row.txid} does not parse: $e');
        await _storage.resolvePendingReceive(row.walletId, row.txid, 'the stored BEEF does not parse: $e');
        continue;
      }
      _log.info('Block headers reached $height: retrying the retained receive of ${row.txid}');
      final key = _parkKey(msg.targetWalletId, row.txid);
      _parkedKeys.add(key);
      await _runReceive(msg, _parkedSenders.remove(key));
    }

    for (final entry in fallback) {
      final (msg, sender, _) = entry.value;
      _parkedSendersFallback.remove(entry.key);
      _log.info('Block headers reached $height: retrying the receive of ${msg.transactionId} '
          'that could not be stored');
      await _runReceive(msg, sender);
    }
  }

  /// Verifies the BUMP of the BEEF member at [index] against our active
  /// header chain and returns what it proves (bead libspiffy-fggl).
  ///
  /// Throws [_ProofRejected] when the proof does not reproduce the merkle
  /// root of the header at its height, and whatever [_getBlockHeader] throws
  /// when we do not have that header: neither proves anything, and a caller
  /// that can carry on without this member catches both.
  Future<ProvenTransaction> _verifyProvenMember(BEEF beef, int index) async {
    final memberTxid = beef.calculateTxid(beef.txs[index]);
    final bump = _bumpFor(beef, index);
    final blockHeader = await _getBlockHeader(bump.blockHeight);
    if (!await beef.validateTransactionWithBlockHeader(memberTxid, blockHeader)) {
      throw _ProofRejected('the BUMP of ${hex.encode(memberTxid)} does not match the header at '
          'height ${bump.blockHeight}');
    }
    return ProvenTransaction(
      txid: hex.encode(memberTxid),
      bumpHex: bump.toHex(),
      blockHeight: bump.blockHeight,
      blockHash: blockHeader.blockHash().toString(),
    );
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
  ///
  /// Every BUMP the BEEF carries is kept, [provenTxids] or not (bead
  /// libspiffy-fggl): a proof for a block whose header we have not synced
  /// cannot be fetched again either, and the projection stores it
  /// pendingHeader until the header arrives. Only [provenTxids] stops the
  /// walk, so an ancestor we could not verify is still followed back.
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
            bumpHex: beef.hasMerkle[entry.value] ? _bumpFor(beef, entry.value).toHex() : '',
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

      // A BEEF held back because we had no header at a proof's height is
      // judged now (beads libspiffy-68mz, libspiffy-vfai): the counterparty
      // does not have to deliver it again.
      await _replayParkedReceives(msg.height);

      // Outputs that cannot be proven because an ancestor's proof left the
      // active chain (bead libspiffy-0lx): logged, and ARC asked once per
      // interval whether it has a fresh proof.
      await _sweepOutputsAwaitingProof();

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
    // The transactions whose proof left the active chain here: outputs of
    // ours that are only provable through one of them cannot be spent until
    // a fresh proof arrives (bead libspiffy-0lx).
    final leftTheChain = <String>{};
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
          leftTheChain.add(proof.txid);
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
        if (await _recheckProof(proof) != null) {
          await _markOrphaned(proof);
          leftTheChain.add(proof.txid);
        }
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
    await _reportOutputsAwaitingProof(leftTheChain);
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
  /// each wallet holding the transaction unconfirmed (failed included: a
  /// proof on the active chain outranks ARC's REJECTED, bead hccp) is sent
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

      final wallets = await _confirmFromVerifiedProofs(revived, justReverted: justReverted);
      _log.warning('${revived.length} orphaned or rejected proof(s) at heights $fromHeight-$toHeight verify on the '
          'active chain again: ${revived.keys.toList()}; confirmation restored in $wallets wallet(s)');
    } catch (e, st) {
      _log.warning('Failed to re-check orphaned and rejected proofs at heights $fromHeight-$toHeight: $e', e, st);
    }
  }

  /// Confirm the transactions of [verified] (txid -> the stored proof and the
  /// check that verified it against our active header chain) in every wallet
  /// holding them unconfirmed. Returns the number of wallets written to.
  ///
  /// A merkle proof on the active chain is the authority (V-55/V-56): a
  /// failed row is confirmed too, since ARC's REJECTED can be stale and a
  /// competing spend can lose. Each wallet is sent
  /// ConfirmTransactionCommand with the BUMP (journaled in
  /// TransactionConfirmedEvent, so a read model rebuilt from the journal
  /// keeps the proof) and MarkUTXOAvailableCommand for its pending outputs
  /// of the transaction.
  ///
  /// A row in [justReverted] ((wallet, txid) whose revert was just sent, not
  /// yet applied) is confirmed although it still reads confirmed, and its
  /// available outputs are made available again after the revert.
  ///
  /// Shared by the two paths that can turn a stored proof into a
  /// confirmation without asking anybody: a proof whose block came back onto
  /// the active chain ([_reviveProofs]) and a pendingHeader proof whose
  /// header has now arrived ([_recheckUnverifiedProofs], bead libspiffy-65ji
  /// — that path rewrote the proof row as verified and then waited for ARC,
  /// which inverts the SPV model).
  Future<int> _confirmFromVerifiedProofs(
    Map<String, (MerkleProof, ProofHeaderCheck)> verified, {
    Set<(String, String)> justReverted = const {},
  }) async {
    if (verified.isEmpty) return 0;
    final restore = <String, Set<String>>{}; // walletId -> txids
    for (final tx in await _storage.getTransactionsByTxids(verified.keys.toList())) {
      final walletId = tx.walletId;
      if (walletId == null || walletId.isEmpty) continue;
      // A failed row is confirmed too (bead hccp): the proof verifies
      // against the active chain, so the transaction is mined whatever ARC
      // reported (a REJECTED can be stale, a competing spend can lose).
      final unconfirmed = tx.status != TransactionStatus.confirmed || justReverted.contains((walletId, tx.txid));
      if (!unconfirmed) continue;
      restore.putIfAbsent(walletId, () => {}).add(tx.txid);
    }
    for (final MapEntry(key: walletId, value: txids) in restore.entries) {
      for (final txid in txids) {
        final (proof, check) = verified[txid]!;
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
    return restore.length;
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
      // The proofs that just verified: a merkle proof on our active header
      // chain is authority enough to confirm (bead libspiffy-65ji).
      final settled = <String, (MerkleProof, ProofHeaderCheck)>{};
      for (final proof in unverified) {
        if (proof.blockHeight > upToHeight) continue;
        final check = await _checkProof(proof);
        if (check.isVerified) {
          settled.putIfAbsent(proof.txid, () => (proof, check));
          continue;
        }
        if (check.status == ProofHeaderStatus.headerUnknown) continue;

        if (proof.blockHash == null) {
          await _markRejected(proof);
        } else {
          await _markOrphaned(proof);
        }
        failed.add((proof, check));
      }

      // Confirm before reverting: the two sets are disjoint (a proof either
      // verified or did not), and a transaction whose proof just verified
      // must not wait for ARC — a proof beats any status string.
      if (settled.isNotEmpty) {
        final wallets = await _confirmFromVerifiedProofs(settled);
        if (wallets > 0) {
          _log.info('${settled.length} proof(s) imported before their block header verify now that headers reach '
              '$upToHeight: ${settled.keys.toList()}; confirmed in $wallets wallet(s)');
        }
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
    // A proof the arriving header contradicts leaves outputs that rest on it
    // unprovable (bead libspiffy-0lx).
    await _reportOutputsAwaitingProof(reverted.toSet());
  }

  /// A proof left the active header chain, so outputs that can only be
  /// proven through it cannot be spent until a fresh proof for it arrives
  /// (bead libspiffy-0lx).
  ///
  /// The model allows exactly two ways for that proof to come, and neither
  /// of them is a block scan or a question to a service:
  /// * the reorganization puts the block back, or the transaction is mined
  ///   again in a block whose header we hold — [_reviveProofs] and
  ///   [_recheckUnverifiedProofs] restore the proof from the row we kept;
  /// * the counterparty who supplied the transaction hands us a fresh BEEF
  ///   carrying a new BUMP for it, which the receive path stores.
  ///
  /// ARC is **not** one of them. An ARC instance answers only for
  /// transactions submitted through it, so it has no standing to prove a
  /// counterparty's transaction, and asking would make the wallet depend on
  /// a coincidence instead of on the counterparty's obligation. ARC is asked
  /// only about transactions this wallet broadcast itself.
  ///
  /// So the wallet must *say* it is waiting instead of holding an output
  /// that quietly cannot be paid with: every affected output is logged, and
  /// [ReadModelStorage.getOutputsAwaitingAncestorProof] lists them with the
  /// ancestor each is waiting for. Asking the counterparty for a fresh proof
  /// needs a message the library does not have yet; that is the one part of
  /// the recovery left to the application.
  Future<void> _reportOutputsAwaitingProof(Set<String> leftTheChain) async {
    if (leftTheChain.isEmpty) return;
    await _logOutputsAwaitingProof();
  }

  /// The same check on a timer ([_awaitingProofSweepInterval], from the
  /// injectable clock), run from a header notification: an output can be
  /// waiting for a proof that left the chain long before this actor started,
  /// and the outputs it blocks are worth naming again.
  Future<void> _sweepOutputsAwaitingProof() async {
    final now = _clock();
    if (_lastAwaitingProofSweep case final last?
        when now.difference(last) < _awaitingProofSweepInterval) {
      return;
    }
    _lastAwaitingProofSweep = now;
    await _logOutputsAwaitingProof();
  }

  /// When the last sweep ran.
  DateTime? _lastAwaitingProofSweep;

  /// Logs every wallet output waiting for a fresh ancestor proof and returns
  /// the ancestors they are waiting on. Reads each wallet's unspent UTXO rows
  /// and the proofs and raw transactions on the way back to a proof.
  Future<Set<String>> _logOutputsAwaitingProof() async {
    final blocking = <String>{};
    try {
      for (final walletId in await _storage.listWallets()) {
        final awaiting = await _storage.getOutputsAwaitingAncestorProof(walletId);
        if (awaiting.isEmpty) continue;
        final waitingOn = {for (final output in awaiting) for (final a in output.ancestors) a.txid};
        blocking.addAll(waitingOn);
        _log.warning('${awaiting.length} output(s) of wallet $walletId cannot be spent until a fresh merkle '
            'proof arrives for ${waitingOn.toList()}: ${[for (final o in awaiting) o.outpoint]}. '
            'Ask the counterparty that supplied them for a new BEEF, or wait for the block to come back; '
            'ReadModelStorage.getOutputsAwaitingAncestorProof lists them.');
      }
    } catch (e, st) {
      _log.warning('Could not work out which outputs are waiting for a fresh proof: $e', e, st);
    }
    return blocking;
  }

  /// How often a header notification sweeps for outputs waiting on a proof
  /// (constructor parameter, default 30 minutes; timed by the injectable
  /// clock).
  final Duration _awaitingProofSweepInterval;

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

  /// The rule (bead libspiffy-5bju, extending azl): **a confirmation must
  /// rest on at least one proof that is verified on the active header chain**
  /// — [MerkleProofStatus.verified] or a [MerkleProofStatus.pendingHeader]
  /// row that still may become one, which is exactly
  /// [ReadModelStorage.getMerkleProof] returning something. When a
  /// transaction held as confirmed has no such proof and does have a
  /// [MerkleProofStatus.rejected] or [MerkleProofStatus.orphaned] one, every
  /// wallet holding it as confirmed has the confirmation reverted
  /// (RevertTransactionConfirmationCommand) and ARCActor is asked to poll for
  /// a real proof. Txids in [alreadyReverted] (their confirmed rows were just
  /// reverted) are skipped.
  ///
  /// * rejected: the header at that height contradicts the proof
  ///   (WalletProjection stores it so on a replay after that header changed,
  ///   or on a header change between the live check and the event);
  /// * orphaned: the proof's block left the active chain. A reorganization
  ///   normally reverts the confirmation itself, but a confirmation whose
  ///   last supporting proof was orphaned without that (another path marked
  ///   it, or the reorganization predates the confirmation's row) was
  ///   covered by no rule at all before 5bju.
  ///
  /// The proof row is never deleted either way (bead mny): an orphaned block
  /// can become active again, and [_reviveProofs] restores the confirmation
  /// from that very row.
  ///
  /// Proofs read (bead hccp): the first check of an actor (at start, or on
  /// its first header notification) reads every rejected and orphaned proof.
  /// After that such a confirmation can only form when a proof becomes
  /// rejected or orphaned (the projection or this actor stores it so) with
  /// the transaction row written confirmed around that time; the height of a
  /// new header says nothing about it. So later checks read only the proofs
  /// whose status became rejected or orphaned since
  /// [_rejectedProofRecheckOverlap] before the previous check started
  /// ([ReadModelStorage.getMerkleProofsByStatusChangedSince]), the rows of
  /// their transactions, and the proof history of those they revert.
  ///
  /// A confirmation written confirmed long after its proof became rejected
  /// (a replay whose journal lacks the revert) is outside that feed. So a
  /// check reads every such proof again once the last full read is
  /// older than the full-sweep interval (constructor parameter, default one
  /// hour, timed by the injectable clock): that case is caught within the
  /// interval while the actor runs, not only at its next start.
  Future<void> _revertRejectedConfirmations({Set<String> alreadyReverted = const {}}) async {
    // Storage stamps status changes with the wall clock, so the feed's
    // starting point does too; the injectable clock times the full sweeps.
    final startedAt = DateTime.now();
    final now = _clock();
    final lastFull = _lastFullRejectedProofSweep;
    final full = _rejectedProofsCheckedFrom == null ||
        lastFull == null ||
        now.difference(lastFull) >= _rejectedProofFullSweepInterval;
    try {
      await _revertRejectedConfirmationsSince(full ? null : _rejectedProofsCheckedFrom, alreadyReverted);
      _rejectedProofsCheckedFrom = startedAt.subtract(_rejectedProofRecheckOverlap);
      if (full) _lastFullRejectedProofSweep = now;
    } catch (e, st) {
      // The next check reads from the same point again.
      _log.warning('Failed to revert confirmations resting on rejected proofs: $e', e, st);
    }
  }

  /// Status changes this long before the previous check started are read
  /// again by the next ([_revertRejectedConfirmations]): a proof whose write
  /// committed after that check read the proofs, or whose transaction row
  /// was written confirmed after that check read the rows, is not missed.
  static const Duration _rejectedProofRecheckOverlap = Duration(minutes: 10);

  /// Where the next [_revertRejectedConfirmations] starts reading status
  /// changes; null until a check of this actor has completed (the next then
  /// reads every rejected proof).
  DateTime? _rejectedProofsCheckedFrom;

  /// When ([_clock]) the last check that read every rejected proof ran.
  DateTime? _lastFullRejectedProofSweep;

  Future<void> _revertRejectedConfirmationsSince(DateTime? since, Set<String> alreadyReverted) async {
    // txid -> the proof that says the confirmation has lost its footing
    // (rejected preferred over orphaned, for the message), when every such
    // proof is read.
    final unsupported = <String, MerkleProof>{};
    final candidates = <String>{};
    if (since == null) {
      for (final status in const [MerkleProofStatus.orphaned, MerkleProofStatus.rejected]) {
        for (final proof in await _storage.getMerkleProofsByStatus(status)) {
          final held = unsupported[proof.txid];
          if (held == null || held.status != MerkleProofStatus.rejected) unsupported[proof.txid] = proof;
        }
      }
      candidates.addAll(unsupported.keys);
    } else {
      for (final status in const [MerkleProofStatus.rejected, MerkleProofStatus.orphaned]) {
        for (final proof in await _storage.getMerkleProofsByStatusChangedSince(status, since)) {
          candidates.add(proof.txid);
        }
      }
    }
    candidates.removeAll(alreadyReverted);
    if (candidates.isEmpty) return;

    for (final txid in (await _storage.getMerkleProofsBatch(candidates.toList())).keys) {
      candidates.remove(txid); // a current proof backs the transaction
    }
    if (candidates.isEmpty) return;
    // The rows of those transactions only (ctkm). A rejected proof of a
    // received ancestor belongs to no wallet transaction.
    final rows = await _storage.getTransactionsByTxids(candidates.toList());
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

    final reverted = <String>[];
    for (final entry in wallets.entries) {
      var proof = unsupported[entry.key];
      if (proof == null && since != null) {
        MerkleProof? orphanedRow;
        for (final row in await _storage.getMerkleProofHistory(entry.key)) {
          if (row.status == MerkleProofStatus.rejected) proof = row; // the newest
          if (row.status == MerkleProofStatus.orphaned) orphanedRow = row; // the newest
        }
        // A confirmation resting only on an orphaned proof is reverted too
        // (bead libspiffy-5bju): the rule is the same either way, and the
        // proof row itself is kept — a reorganization can put its block back
        // on the active chain, and [_reviveProofs] needs it to do so.
        proof ??= orphanedRow;
      }
      if (proof == null) continue; // nothing says this confirmation lost its proof
      // The rule is about the active chain now, not about a status written
      // earlier: a header stored since (a reorganization back onto this
      // proof's branch) can make the proof verify again, and then the
      // confirmation stands. Read-only on purpose — marking the row verified
      // here would take it out of [_reviveProofs]' feed, which is what
      // restores the wallets that did lose the confirmation.
      final onChain = await checkBumpHexAgainstHeaders(
        txid: entry.key,
        bumpHex: proof.merkleProof.length == 1 ? proof.merkleProof.single : '',
        headerAt: _storage.getBlockHeaderByHeight,
      );
      if (onChain.isVerified) continue;
      _revertConfirmation(entry.key, [for (final tx in entry.value) tx.walletId!], proof,
          proof.status == MerkleProofStatus.rejected
              ? 'its only proof does not match the block header at height ${proof.blockHeight} (rejected)'
              : 'no proof of it is on the active header chain: its last supporting proof, at height '
                  '${proof.blockHeight}, left the chain (orphaned)');
      _noteReverted(entry.value);
      reverted.add(entry.key);
    }
    if (reverted.isEmpty) return;
    _log.severe('${reverted.length} confirmation(s) rested on no proof that is verified on the active chain; '
        'reverted: $reverted');
    _arcActor?.tell(TransactionConfirmationsRevertedMessage(reverted));
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

/// A BUMP in a received BEEF that does not match the block header at its
/// height on our active chain ([SPVActor._verifyProvenMember]).
class _ProofRejected implements Exception {
  final String reason;
  _ProofRejected(this.reason);

  @override
  String toString() => reason;
}

/// We hold no block header at [blockHeight] and none could be fetched
/// ([SPVActor._getBlockHeader], bead libspiffy-68mz).
///
/// Unlike [_ProofRejected] this says nothing about the proof: it may well be
/// sound, and the header that would settle it can arrive at any time. A
/// receive that hits it keeps the evidence and is tried again then.
class _HeaderUnavailable implements Exception {
  final int blockHeight;
  final String reason;
  _HeaderUnavailable(this.blockHeight, this.reason);

  @override
  String toString() => 'no block header at height $blockHeight: $reason';
}
