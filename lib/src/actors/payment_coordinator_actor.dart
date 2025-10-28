import 'dart:typed_data';
import 'dart:async';
import 'package:dactor/dactor.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:spiffynode/spiffy_node.dart' as spiffy;
import 'package:convert/convert.dart';

import '../models/bitcoin_utxo.dart';
import '../models/bitcoin_transaction.dart';
import '../storage/read_model_storage.dart';
import '../storage/secure_storage.dart';
import '../utils/beef.dart';
import '../utils/bump.dart';
import '../core/wallet_commands.dart';
import 'payment_messages.dart';
import 'wallet_messages.dart';

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
  final SecureStorage _secureStorage;
  final ActorRef _walletManager;

  PaymentCoordinatorActor({
    required ActorRef walletManager,
    required ReadModelStorage storage,
    required SecureStorage secureStorage,
  })  : _storage = storage,
        _secureStorage = secureStorage,
        _walletManager = walletManager;

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


    final publicKeys = await _getPublicKeysForUTXOs(msg.walletId, selectedUtxos);

    // 4. Build payment transaction
    print('  Building payment transaction...');
    final paymentTx = await _buildPaymentTransaction(
      selectedUtxos: selectedUtxos,
      outputAddresses: msg.addresses,
      outputAmount: msg.amount,
      changeAddress: msg.changeAddress,
      walletId: msg.walletId,
      publicKeys: publicKeys,
    );
    
    if (paymentTx == null) {
      _sendError(msg.invoiceId, 'Failed to build payment transaction');
      return;
    }
    print('  ✓ Unsigned transaction built: ${paymentTx.txid}');

    // 4b. Sign the transaction
    print('  Signing transaction...');
    final utxoKeys = selectedUtxos.map((u) => '${u.txid}:${u.vout}').toList();
    final signedTxHex = await _signTransaction(
      walletId: msg.walletId,
      txid: paymentTx.txid,
      unsignedTxHex: paymentTx.rawHex,
      utxoKeys: utxoKeys,
      publicKeys: publicKeys,
    );

    if (signedTxHex == null) {
      _sendError(msg.invoiceId, 'Failed to sign transaction');
      return;
    }

    // Update payment transaction with signed hex
    final signedPaymentTx = BitcoinTransaction(
      txid: paymentTx.txid, // TXID doesn't change after signing
      rawHex: signedTxHex,
      status: paymentTx.status,
      inputValue: paymentTx.inputValue,
      outputValue: paymentTx.outputValue,
      fee: paymentTx.fee,
      receivingAddresses: paymentTx.receivingAddresses,
      sendingAddresses: paymentTx.sendingAddresses,
      netAmount: paymentTx.netAmount,
      createdAt: paymentTx.createdAt,
      updatedAt: DateTime.now(),
      lockTime: paymentTx.lockTime,
      version: paymentTx.version,
    );

    print('  ✓ Transaction signed: ${signedPaymentTx.txid}');

    // 5. Get block headers for validation
    print('  Retrieving block headers...');
    final blockHeaders = await _getBlockHeaders(ancestorResult.blockHeights);
    print('  ✓ Retrieved ${blockHeaders.length} block headers');

    // 6. Create BEEF package
    print('  Creating BEEF package...');
    try {
      final beef = await _createBEEF(
        paymentTransaction: signedPaymentTx,
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
      print('  📤 Sending response to sender: ${sender != null ? "YES" : "NULL"}');
      if (sender != null) {
        final response = BEEFPaymentResponse(
          invoiceId: msg.invoiceId,
          beefBytes: beef,
          txid: signedPaymentTx.txid, // Use signed transaction's txid
          amountPaid: msg.amount,
          changeAmount: changeAmount > BigInt.zero ? changeAmount : BigInt.zero,
          ancestorCount: ancestorResult.ancestorTransactions.length,
          success: true,
        );
        print('  📤 Response: invoiceId=${response.invoiceId}, txid=${response.txid}, success=${response.success}');
        sender.tell(response);
        print('  ✅ Response sent to sender');
      } else {
        print('  ⚠️  WARNING: sender is null, cannot send response!');
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
  /// Using proven patterns from transaction_builder_service.dart
  Future<BitcoinTransaction?> _buildPaymentTransaction({
    required List<BitcoinUtxo> selectedUtxos,
    required List<String> outputAddresses,
    required BigInt outputAmount,
    String? changeAddress,
    required String walletId,
    required List<dartsv.SVPublicKey> publicKeys,
  }) async {
    try {
      print('    Building transaction with ${selectedUtxos.length} inputs');
      
      
      // Calculate total input
      final totalInput = selectedUtxos.fold<BigInt>(
        BigInt.zero,
        (sum, utxo) => sum + utxo.satoshis,
      );
      
      // Build transaction using proven TransactionBuilder pattern
      final txBuilder = dartsv.TransactionBuilder();
      
      // Add payment outputs first (proven pattern from transaction_builder_service.dart)
      for (final address in outputAddresses) {
        final toAddress = dartsv.Address.fromBase58(address);
        final amountPerAddress = outputAmount ~/ BigInt.from(outputAddresses.length);
        
        final recipientBuilder = dartsv.P2PKHLockBuilder.fromAddress(toAddress);
        txBuilder.spendToLockBuilder(recipientBuilder, amountPerAddress);
      }
      
      // Add change address (proven pattern)
      final changeAddr = changeAddress ?? selectedUtxos.first.address;
      final changeAddress_ = dartsv.Address.fromBase58(changeAddr);
      txBuilder.sendChangeToPKH(changeAddress_);
      
      // Add inputs from selected UTXOs with public keys
      for (int i = 0; i < selectedUtxos.length; i++) {
        final utxo = selectedUtxos[i];
        final publicKey = publicKeys[i];
        
        final lockedAddress = dartsv.Address.fromBase58(utxo.address);
        final lockingScript = dartsv.P2PKHLockBuilder.fromAddress(lockedAddress).getScriptPubkey();
        
        final outpoint = dartsv.TransactionOutpoint(
          utxo.txid,
          utxo.vout,
          utxo.satoshis,
          lockingScript,
        );

        // Prime the scriptSig with the public key for this UTXO
        // Signing will populate the signature later
        final unlockBuilder = dartsv.P2PKHUnlockBuilder(publicKey);
        txBuilder.spendFromOutpoint(outpoint, dartsv.TransactionInput.MAX_SEQ_NUMBER, unlockBuilder);
      }

      // txBuilder.sendChangeToPKH(changeAddress);

      // Apply transaction settings (proven pattern)
      txBuilder
          .withFeePerKb(1) // Low fee rate (proven from transaction_builder_service.dart) valid for BSV network
          .withOption(dartsv.TransactionOption.DISABLE_DUST_OUTPUTS);
      
      // Build unsigned transaction (proven pattern: skip sanity checks for flexibility)
      final unsignedTx = txBuilder.build(false);
      final rawHex = unsignedTx.serialize();
      final txid = unsignedTx.id;
      
      // Calculate actual fee and change from built transaction
      final totalOutput = unsignedTx.outputs.fold<BigInt>(
        BigInt.zero,
        (sum, output) => sum + output.satoshis,
      );
      final fee = totalInput - totalOutput;
      
      print('    ✓ Transaction built: $txid (${rawHex.length ~/ 2} bytes)');
      print('      Total input: $totalInput, Total output: $totalOutput, Fee: $fee');
      print('      Outputs: ${unsignedTx.outputs.length}');
      
      // Create transaction record
      return BitcoinTransaction(
        txid: txid,
        rawHex: rawHex,
        status: TransactionStatus.created,
        inputValue: totalInput,
        outputValue: totalOutput,
        fee: fee,
        receivingAddresses: outputAddresses,
        sendingAddresses: selectedUtxos.map((u) => u.address).toList(),
        netAmount: -(outputAmount + fee),
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        lockTime: 0,
        version: 2,
      );
    } catch (e, stackTrace) {
      print('Error building payment transaction: $e');
      print('Stack trace: $stackTrace');
      return null;
    }
  }

  /// Get public keys for all UTXOs being spent
  /// 
  /// For each UTXO, this method:
  /// 1. Retrieves the address metadata to find the derivation index
  /// 2. Derives the private key for that address from the wallet's xpriv
  /// 3. Extracts the public key from the private key
  Future<List<dartsv.SVPublicKey>> _getPublicKeysForUTXOs(
    String walletId,
    List<BitcoinUtxo> utxos,
  ) async {
    final publicKeys = <dartsv.SVPublicKey>[];
    
    // Get the wallet's extended private key
    final xpriv = await _secureStorage.getXPriv(walletId);
    if (xpriv == null) {
      throw Exception('Wallet xpriv not found in secure storage');
    }
    
    // Parse the extended private key
    final hdPrivateKey = dartsv.HDPrivateKey.fromXpriv(xpriv);
    
    // For each UTXO, derive its public key
    for (final utxo in utxos) {
      // Get address metadata to find derivation index
      final addressMetadata = await _storage.getAddressMetadata(walletId, utxo.address);
      if (addressMetadata == null) {
        throw Exception('Address metadata not found for ${utxo.address}');
      }
      
      final derivationPath = "m/0/${addressMetadata.derivationIndex}";
      
      final derivedHdKey = hdPrivateKey.deriveChildKey(derivationPath);
      final privateKey = derivedHdKey.privateKey;
      final publicKey = privateKey.publicKey;
      
      publicKeys.add(publicKey);
    }
    
    return publicKeys;
  }

  /// Request wallet to sign the transaction
  /// Returns signed transaction hex or null on failure
  Future<String?> _signTransaction({
    required String walletId,
    required String txid,
    required String unsignedTxHex,
    required List<String> utxoKeys,
    required List<dartsv.SVPublicKey> publicKeys,
  }) async {
    print('    Requesting signature from wallet...');
    
    final completer = Completer<TransactionSignedResponse>();
    final receiver = await context.system.spawn(
      'sign-receiver-$txid',
      () => _SigningReceiverActor(completer),
    );
    
    // Send SignTransactionCommand to wallet
    _walletManager.tell(
      WalletCommandMessage(
        walletId,
        SignTransactionCommand(
          walletId: walletId,
          transactionId: txid,
          rawTransaction: unsignedTxHex,
          utxoKeys: utxoKeys,
          publicKeys: publicKeys.map((key) => key.toHex()).toList(),
        ),
      ),
      sender: receiver,
    );
    
    // Wait for signing response
    final response = await completer.future.timeout(
      Duration(seconds: 10),
      onTimeout: () {
        print('    ⚠️ Signing timeout after 10 seconds');
        return TransactionSignedResponse(
          walletId: walletId,
          txid: txid,
          signedHex: '',
          success: false,
          error: 'Signing timeout',
        );
      },
    );
    
    if (!response.success) {
      print('    ❌ Signing failed: ${response.error}');
      return null;
    }
    
    print('    ✓ Transaction signed successfully');
    return response.signedHex;
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
      print('  📥 _createBEEF inputs:');
      print('    Payment transaction: ${paymentTransaction.txid}');
      print('      Raw hex length: ${paymentTransaction.rawHex.length} chars');
      print('    Ancestor transactions: ${ancestorTransactions.length}');
      for (final ancestor in ancestorTransactions) {
        print('      - ${ancestor.txid} (${ancestor.rawHex.length} chars)');
      }
      print('    Merkle proofs: ${merkleProofs.length}');
      for (final proof in merkleProofs) {
        print('      - ${proof.txid} at height ${proof.blockHeight}, position ${proof.position}');
      }
      
      // 1. Convert all transactions to raw bytes
      final txBytes = <Uint8List>[];
      
      // Add ancestor transactions first (in order they were collected)
      for (final tx in ancestorTransactions) {
        txBytes.add(Uint8List.fromList(hex.decode(tx.rawHex)));
        print('  Ancestor Transaction: ${tx.rawHex}');
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
      
      // Debug: Log what we're passing to BEEF.create()
      print('  📊 BEEF.create() inputs:');
      print('    txBytes: ${txBytes.length} transactions');
      for (int i = 0; i < txBytes.length; i++) {
        print('      [$i] ${txBytes[i].length} bytes');
      }
      print('    bumps: ${bumps.length} merkle proofs');
      print('    hasMerkle: ${hasMerkle.length} flags = $hasMerkle');
      print('    bumpIndex: ${bumpIndex.length} indices = $bumpIndex');

      print('  Payment Transaction: ${paymentTransaction.rawHex}');

      // 5. Create BEEF using the existing BEEF.create() method
      final beef = BEEF.create(
        bumps: bumps,
        txs: txBytes,
        hasMerkle: hasMerkle,
        bumpIndex: bumpIndex,
      );
      
      // 6. Serialize BEEF
      final serialized = beef.serialize();
      print('  ✓ BEEF serialized: ${serialized.length} bytes');
      print('    BEEF HEX: ${hex.encode(serialized)}');
      Future.delayed(Duration(seconds: 1)); //debug delay so BEEF hex can dump to console
      
      // 7. Verify BEEF can be parsed (sanity check)
      try {
        final parsed = BEEF.parse(serialized);
        print('  ✓ BEEF parse verification passed');
        print('    Parsed ${parsed.txs.length} transactions');
        print('    Parsed ${parsed.bumps.length} merkle proofs');
      } catch (e, stackTrace) {
        print('  ❌ BEEF parse verification FAILED: $e');
        print('  Stack trace: $stackTrace');
        throw Exception('Created BEEF is invalid: $e');
      }
      
      return serialized;
    } catch (e) {
      print('Error creating BEEF: $e');
      rethrow;
    }
  }


  /// Build a BUMP from a MerkleProof
  /// 
  /// Converts our MerkleProof storage format to the BUMP structure needed for BEEF.
  /// Based on CryptoUtils.createBumpFromTscProof() implementation.
  BUMP _buildBUMPFromMerkleProof(MerkleProof proof) {
    final levels = <Level>[];
    
    // Level 0: Transaction ID at its position in the block
    // This matches CryptoUtils.createBumpFromTscProof() implementation
    // CRITICAL: proof.txid is in display format (big-endian) from database
    // but BUMP stores txids in internal format (little-endian)
    final reversedTxid = _reverseHexBytes(proof.txid);
    levels.add(Level(leaves: [
      Leaf(
        offset: proof.position,
        duplicate: false,
        isTxid: true,
        hash: Uint8List.fromList(hex.decode(reversedTxid)),
      ),
    ]));
    
    // Subsequent levels: merkle path siblings with calculated offsets
    // Each hash in the merkleProof list is a sibling at the next level up
    // Sibling offset calculation matches CryptoUtils.createBumpFromTscProof()
    for (int i = 0; i < proof.merkleProof.length; i++) {
      // Calculate sibling offset using bit manipulation
      // In a Merkle tree, if index bit at level i is 0, then sibling is at (index | (1 << i))
      // If index bit at level i is 1, then sibling is at (index & ~(1 << i))
      final indexBit = (proof.position >> i) & 1;
      final siblingOffset = indexBit == 0 
          ? (proof.position | (1 << i)) 
          : (proof.position & ~(1 << i));
      
      // CRITICAL: proof.merkleProof[i] is in display format (big-endian) from database
      // but BUMP stores hashes in internal format (little-endian)
      // We must reverse the bytes when converting
      final siblingHashHex = proof.merkleProof[i];
      final reversedHash = _reverseHexBytes(siblingHashHex);
      
      levels.add(Level(leaves: [
        Leaf(
          offset: siblingOffset,
          duplicate: false,
          isTxid: false,
          hash: Uint8List.fromList(hex.decode(reversedHash)),
        ),
      ]));
    }
    
    return BUMP(
      blockHeight: proof.blockHeight,
      path: levels,
    );
  }

  /// Reverse bytes in a hex string (for Bitcoin's little-endian format)
  /// 
  /// Converts between display format (big-endian) and internal format (little-endian)
  String _reverseHexBytes(String hexString) {
    if (hexString.length % 2 != 0) {
      throw Exception('Hex string must have an even number of characters: $hexString');
    }

    final result = StringBuffer();
    for (int i = hexString.length - 2; i >= 0; i -= 2) {
      result.write(hexString.substring(i, i + 2));
    }
    return result.toString();
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

/// Helper actor to receive signing response
class _SigningReceiverActor extends Actor {
  final Completer<TransactionSignedResponse> completer;
  
  _SigningReceiverActor(this.completer);
  
  @override
  Future<void> onMessage(dynamic message) async {
    if (message is TransactionSignedResponse && !completer.isCompleted) {
      completer.complete(message);
    }
  }
}

