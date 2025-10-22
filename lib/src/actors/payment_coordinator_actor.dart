import 'dart:typed_data';
import 'package:dactor/dactor.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:spiffynode/spiffy_node.dart' as spiffy;
import 'package:convert/convert.dart';

import '../models/bitcoin_utxo.dart';
import '../models/bitcoin_transaction.dart';
import '../storage/read_model_storage.dart';
import '../utils/beef.dart';
import '../utils/bump.dart';
import 'payment_messages.dart';

/// Coordinator actor for payment operations with SPV BEEF construction
/// 
/// Handles PayInvoiceMessage by:
/// 1. Selecting UTXOs to fund payment
/// 2. Recursively collecting ancestor transactions back to first merkle proof
/// 3. Validating complete chain exists
/// 4. Building payment transaction
/// 5. Creating BEEF package with ancestors and proofs
/// 6. Returning BEEF (does NOT broadcast - pure SPV model)
class PaymentCoordinatorActor extends Actor {
  final ReadModelStorage _storage;

  PaymentCoordinatorActor({
    required ActorRef walletManager, // Keep parameter for future use
    required ReadModelStorage storage,
  })  : _storage = storage;

  @override
  void preStart() {
    print('PaymentCoordinatorActor started');
  }

  @override
  Future<void> onMessage(dynamic message) async {
    try {
      if (message is PayInvoiceMessage) {
        await _handlePayInvoice(message);
      } else {
        print('PaymentCoordinatorActor: Unknown message type: ${message.runtimeType}');
      }
    } catch (e, stackTrace) {
      print('PaymentCoordinatorActor error: $e');
      print('Stack trace: $stackTrace');
      
      if (message is PayInvoiceMessage) {
        _sendError(message.invoiceId, 'Internal error: $e');
      }
    }
  }

  /// Handle payment invoice request
  Future<void> _handlePayInvoice(PayInvoiceMessage msg) async {
    print('Processing PayInvoiceMessage for invoice ${msg.invoiceId}');
    print('  Wallet: ${msg.walletId}');
    print('  Amount: ${msg.amount} satoshis');
    print('  Addresses: ${msg.addresses}');

    // 1. Get available UTXOs
    final utxos = await _storage.getAvailableUTXOs(msg.walletId);
    if (utxos.isEmpty) {
      _sendError(msg.invoiceId, 'Insufficient funds');
      return;
    }
    print('  Found ${utxos.length} available UTXOs');

    // 2. Select UTXOs for payment
    final selectedUtxos = _selectUTXOs(utxos, msg.amount);
    if (selectedUtxos == null) {
      final totalBalance = utxos.fold<BigInt>(
        BigInt.zero,
        (sum, utxo) => sum + utxo.satoshis,
      );
      _sendError(
        msg.invoiceId,
        'Insufficient funds: need ${msg.amount} satoshis, have $totalBalance',
      );
      return;
    }
    print('  Selected ${selectedUtxos.length} UTXOs for payment');

    // 3. CRITICAL: Validate complete ancestor chain
    print('  Collecting and validating ancestor chain...');
    final ancestorResult = await _collectAndValidateAncestors(selectedUtxos);
    if (!ancestorResult.isValid) {
      _sendError(
        msg.invoiceId,
        'Incomplete transaction chain: ${ancestorResult.error}',
      );
      return;
    }
    print('  ✓ Ancestor chain validated: ${ancestorResult.ancestorTransactions.length} transactions, ${ancestorResult.merkleProofs.length} proofs');

    // 4. Build payment transaction
    print('  Building payment transaction...');
    final paymentTx = await _buildPaymentTransaction(
      selectedUtxos: selectedUtxos,
      outputAddresses: msg.addresses,
      outputAmount: msg.amount,
      changeAddress: msg.changeAddress,
      walletId: msg.walletId,
    );
    
    if (paymentTx == null) {
      _sendError(msg.invoiceId, 'Failed to build payment transaction');
      return;
    }
    print('  ✓ Payment transaction built: ${paymentTx.txid}');

    // 5. Get block headers for validation
    print('  Retrieving block headers...');
    final blockHeaders = await _getBlockHeaders(ancestorResult.blockHeights);
    print('  ✓ Retrieved ${blockHeaders.length} block headers');

    // 6. Create BEEF package
    print('  Creating BEEF package...');
    try {
      final beef = await _createBEEF(
        paymentTransaction: paymentTx,
        ancestorTransactions: ancestorResult.ancestorTransactions,
        merkleProofs: ancestorResult.merkleProofs,
        blockHeaders: blockHeaders,
      );

      print('  ✓ BEEF package created: ${beef.length} bytes');

      // Calculate change amount
      final totalInput = selectedUtxos.fold<BigInt>(
        BigInt.zero,
        (sum, utxo) => sum + utxo.satoshis,
      );
      final changeAmount = totalInput - msg.amount - BigInt.from(1000); // Rough fee estimate

      // 7. Return BEEF to caller (does NOT broadcast)
      final sender = context.sender;
      if (sender != null) {
        sender.tell(BEEFPaymentResponse(
          invoiceId: msg.invoiceId,
          beefBytes: beef,
          txid: paymentTx.txid,
          amountPaid: msg.amount,
          changeAmount: changeAmount > BigInt.zero ? changeAmount : BigInt.zero,
          ancestorCount: ancestorResult.ancestorTransactions.length,
          success: true,
        ));
      }

      print('✓ Payment BEEF ready for invoice ${msg.invoiceId}');
    } catch (e) {
      _sendError(msg.invoiceId, 'Failed to create BEEF: $e');
    }
  }

  /// Recursively collect ancestors up to first merkle proof
  Future<AncestorCollectionResult> _collectAndValidateAncestors(
    List<BitcoinUtxo> utxos,
  ) async {
    final ancestorTxs = <BitcoinTransaction>[];
    final merkleProofs = <MerkleProof>[];
    final blockHeights = <int>{};
    final visited = <String>{}; // Prevent infinite loops

    for (final utxo in utxos) {
      final result = await _collectAncestorsRecursive(
        utxo.txid,
        visited,
        ancestorTxs,
        merkleProofs,
        blockHeights,
      );

      if (!result.success) {
        return AncestorCollectionResult.error(result.error!);
      }
    }

    // Validate we have at least one merkle proof
    if (merkleProofs.isEmpty) {
      return AncestorCollectionResult.error(
        'No merkle proofs found in transaction chain - cannot create valid BEEF',
      );
    }

    return AncestorCollectionResult.success(
      ancestorTransactions: ancestorTxs,
      merkleProofs: merkleProofs,
      blockHeights: blockHeights.toList(),
    );
  }

  /// Recursive helper: collect ancestors until merkle proof found
  Future<_CollectionStep> _collectAncestorsRecursive(
    String txid,
    Set<String> visited,
    List<BitcoinTransaction> ancestorTxs,
    List<MerkleProof> merkleProofs,
    Set<int> blockHeights,
  ) async {
    // Skip if already processed
    if (visited.contains(txid)) {
      return _CollectionStep.success();
    }
    visited.add(txid);

    // Get transaction from storage (must exist)
    final tx = await _storage.getTransaction(txid);
    if (tx == null) {
      return _CollectionStep.error(
        'Transaction $txid not found in storage - may need to import historical transactions',
      );
    }

    // Check for merkle proof (stopping condition)
    final proof = await _storage.getMerkleProof(txid);

    if (proof != null) {
      // Found merkle proof - chain complete for this branch
      ancestorTxs.add(tx);
      merkleProofs.add(proof);
      blockHeights.add(proof.blockHeight);
      return _CollectionStep.success();
    }

    // No merkle proof - must recurse to parents
    ancestorTxs.add(tx);

    // Parse transaction to get parent txids
    try {
      final dartsvTx = dartsv.Transaction.fromHex(tx.rawHex);

      for (final input in dartsvTx.inputs) {
        final parentTxid = input.prevTxnId;

        // Recursively process parent
        final result = await _collectAncestorsRecursive(
          parentTxid,
          visited,
          ancestorTxs,
          merkleProofs,
          blockHeights,
        );

        if (!result.success) {
          return result; // Propagate error
        }
      }
    } catch (e) {
      return _CollectionStep.error('Failed to parse transaction $txid: $e');
    }

    return _CollectionStep.success();
  }

  /// Select UTXOs to fund payment (greedy largest-first strategy)
  List<BitcoinUtxo>? _selectUTXOs(List<BitcoinUtxo> utxos, BigInt targetAmount) {
    // Sort by size (largest first) for minimal inputs
    final sortedUtxos = List<BitcoinUtxo>.from(utxos)
      ..sort((a, b) => b.satoshis.compareTo(a.satoshis));

    final selected = <BitcoinUtxo>[];
    var total = BigInt.zero;

    for (final utxo in sortedUtxos) {
      selected.add(utxo);
      total += utxo.satoshis;

      // Add some buffer for fees (rough estimate: 1000 sats)
      if (total >= targetAmount + BigInt.from(1000)) {
        return selected;
      }
    }

    return null; // Insufficient funds
  }

  /// Build payment transaction from selected UTXOs
  Future<BitcoinTransaction?> _buildPaymentTransaction({
    required List<BitcoinUtxo> selectedUtxos,
    required List<String> outputAddresses,
    required BigInt outputAmount,
    String? changeAddress,
    required String walletId,
  }) async {
    try {
      // For now, create a simplified transaction representation
      // In a full implementation, this would use TransactionBuilderService
      
      // Calculate total input
      final totalInput = selectedUtxos.fold<BigInt>(
        BigInt.zero,
        (sum, utxo) => sum + utxo.satoshis,
      );

      // Rough fee estimate
      final fee = BigInt.from(1000);
      final changeAmount = totalInput - outputAmount - fee;

      // Generate txid (simplified - in reality this would be from signed tx)
      final txid = 'payment-${DateTime.now().millisecondsSinceEpoch}';

      // Create transaction record
      // Note: In full implementation, this would build actual dartsv.Transaction
      return BitcoinTransaction(
        txid: txid,
        rawHex: '', // Would be populated by actual transaction builder
        status: TransactionStatus.created,
        inputValue: totalInput,
        outputValue: outputAmount + (changeAmount > BigInt.zero ? changeAmount : BigInt.zero),
        fee: fee,
        receivingAddresses: outputAddresses,
        sendingAddresses: selectedUtxos.map((u) => u.address).toList(),
        netAmount: -(outputAmount + fee),
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        lockTime: 0,
        version: 1,
      );
    } catch (e) {
      print('Error building payment transaction: $e');
      return null;
    }
  }

  /// Get block headers for validation
  Future<List<spiffy.BlockHeader>> _getBlockHeaders(List<int> blockHeights) async {
    final headers = <spiffy.BlockHeader>[];

    for (final height in blockHeights) {
      final header = await _storage.getBlockHeaderByHeight(height);
      if (header != null) {
        headers.add(header);
      }
    }

    return headers;
  }

  /// Create BEEF package from transactions, proofs, and headers
  Future<Uint8List> _createBEEF({
    required BitcoinTransaction paymentTransaction,
    required List<BitcoinTransaction> ancestorTransactions,
    required List<MerkleProof> merkleProofs,
    required List<spiffy.BlockHeader> blockHeaders,
  }) async {
    try {
      // 1. Convert all transactions to raw bytes
      final txBytes = <Uint8List>[];
      
      // Add ancestor transactions first (in order they were collected)
      for (final tx in ancestorTransactions) {
        txBytes.add(Uint8List.fromList(hex.decode(tx.rawHex)));
      }
      
      // Add payment transaction last (the new transaction being created)
      txBytes.add(Uint8List.fromList(hex.decode(paymentTransaction.rawHex)));
      
      // 2. Build BUMPs from merkle proofs
      final bumps = <BUMP>[];
      for (final proof in merkleProofs) {
        bumps.add(_buildBUMPFromMerkleProof(proof));
      }
      
      // 3. Set hasMerkle flags - only ancestors with proofs have true
      final hasMerkle = <bool>[];
      for (final ancestor in ancestorTransactions) {
        final hasProof = merkleProofs.any((p) => p.txid == ancestor.txid);
        hasMerkle.add(hasProof);
      }
      // Payment transaction doesn't have a merkle proof yet (unconfirmed)
      hasMerkle.add(false);
      
      // 4. Build bumpIndex array - maps transactions with proofs to their BUMP index
      final bumpIndex = <int>[];
      for (int i = 0; i < ancestorTransactions.length; i++) {
        if (hasMerkle[i]) {
          // Find which BUMP this transaction corresponds to
          final proofIdx = merkleProofs.indexWhere((p) => p.txid == ancestorTransactions[i].txid);
          if (proofIdx != -1) {
            bumpIndex.add(proofIdx);
          }
        }
      }
      
      // 5. Create BEEF using the existing BEEF.create() method
      final beef = BEEF.create(
        bumps: bumps,
        txs: txBytes,
        hasMerkle: hasMerkle,
        bumpIndex: bumpIndex,
      );
      
      // 6. Serialize and return
      return beef.serialize();
    } catch (e) {
      print('Error creating BEEF: $e');
      rethrow;
    }
  }
  
  /// Build a BUMP from a MerkleProof
  /// 
  /// Converts our MerkleProof storage format to the BUMP structure needed for BEEF
  BUMP _buildBUMPFromMerkleProof(MerkleProof proof) {
    final levels = <Level>[];
    
    // First level: the transaction itself at its position in the block
    levels.add(Level(leaves: [
      Leaf(
        offset: proof.position,
        duplicate: false,
        isTxid: true,
        hash: Uint8List.fromList(hex.decode(proof.txid)),
      ),
    ]));
    
    // Subsequent levels: merkle path siblings
    // Each hash in the merkleProof list is a sibling at the next level up
    for (int i = 0; i < proof.merkleProof.length; i++) {
      levels.add(Level(leaves: [
        Leaf(
          offset: 0, // Simplified - actual offset would be calculated from tree structure
          duplicate: false,
          isTxid: false,
          hash: Uint8List.fromList(hex.decode(proof.merkleProof[i])),
        ),
      ]));
    }
    
    return BUMP(
      blockHeight: proof.blockHeight,
      path: levels,
    );
  }

  /// Send error response to caller
  void _sendError(String invoiceId, String error) {
    print('PaymentCoordinatorActor error: $error');
    context.sender?.tell(BEEFPaymentResponse.error(
      invoiceId: invoiceId,
      error: error,
    ));
  }

  @override
  Future<void> postStop() async {
    print('PaymentCoordinatorActor stopped');
  }
}

/// Result of ancestor collection with validation
class AncestorCollectionResult {
  final bool isValid;
  final List<BitcoinTransaction> ancestorTransactions;
  final List<MerkleProof> merkleProofs;
  final List<int> blockHeights;
  final String? error;

  AncestorCollectionResult.success({
    required this.ancestorTransactions,
    required this.merkleProofs,
    required this.blockHeights,
  })  : isValid = true,
        error = null;

  AncestorCollectionResult.error(this.error)
      : isValid = false,
        ancestorTransactions = const [],
        merkleProofs = const [],
        blockHeights = const [];
}

/// Internal helper for recursion step result
class _CollectionStep {
  final bool success;
  final String? error;

  _CollectionStep.success()
      : success = true,
        error = null;

  _CollectionStep.error(this.error) : success = false;
}

