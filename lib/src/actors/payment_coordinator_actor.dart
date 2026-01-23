import 'dart:typed_data';
import 'dart:async';
import 'package:dactor/dactor.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:spiffynode/spiffy_node.dart' as spiffy;
import 'package:convert/convert.dart';

import '../models/bitcoin_utxo.dart';
import '../models/bitcoin_transaction.dart';
import '../models/invoice_output_spec.dart';
import '../storage/read_model_storage.dart';
import '../storage/secure_storage.dart';
import '../services/ancestor_chain_service.dart';
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
  late final AncestorChainService _ancestorService;

  PaymentCoordinatorActor({
    required ActorRef walletManager,
    required ReadModelStorage storage,
    required SecureStorage secureStorage,
  })  : _storage = storage,
        _secureStorage = secureStorage,
        _walletManager = walletManager {
    _ancestorService = AncestorChainService(storage: storage);
  }

  @override
  void preStart() {
  }

  @override
  Future<void> onMessage(dynamic message) async {
    try {
      if (message is PayInvoiceMessage) {
        await _handlePayInvoice(message);
      } else {
      }
    } catch (e, stackTrace) {
      
      if (message is PayInvoiceMessage) {
        _sendError(message.invoiceId, 'Internal error: $e');
      }
    }
  }

  /// Handle payment invoice request
  Future<void> _handlePayInvoice(PayInvoiceMessage msg) async {
    // Calculate effective amount (from outputs or legacy amount)
    final effectiveAmount = msg.effectiveAmount;

    // 1. Get available UTXOs
    final utxos = await _storage.getAvailableUTXOs(msg.walletId);
    if (utxos.isEmpty) {
      _sendError(msg.invoiceId, 'Insufficient funds');
      return;
    }

    // 2. Select UTXOs for payment
    final selectedUtxos = _selectUTXOs(utxos, effectiveAmount);
    if (selectedUtxos == null) {
      final totalBalance = utxos.fold<BigInt>(
        BigInt.zero,
        (sum, utxo) => sum + utxo.satoshis,
      );
      _sendError(
        msg.invoiceId,
        'Insufficient funds: need $effectiveAmount satoshis, have $totalBalance',
      );
      return;
    }

    // 3. CRITICAL: Validate complete ancestor chain using AncestorChainService
    final ancestorResult = await _ancestorService.collectAncestorChainForUtxos(
      selectedUtxos.map((u) => u.txid).toList(),
    );
    if (!ancestorResult.isValid) {
      _sendError(
        msg.invoiceId,
        'Incomplete transaction chain: ${ancestorResult.error}',
      );
      return;
    }

    final publicKeys = await _getPublicKeysForUTXOs(msg.walletId, selectedUtxos);

    // 4. Build payment transaction (with outputs if provided)
    final paymentTx = await _buildPaymentTransactionWithOutputs(
      selectedUtxos: selectedUtxos,
      outputs: msg.outputs,
      legacyAddresses: msg.addresses,
      legacyAmount: msg.amount,
      changeAddress: msg.changeAddress,
      walletId: msg.walletId,
      publicKeys: publicKeys,
    );

    if (paymentTx == null) {
      _sendError(msg.invoiceId, 'Failed to build payment transaction');
      return;
    }

    // 4b. Sign the transaction
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
    // IMPORTANT: TXID DOES change after signing because scriptSig changes the raw bytes
    // We must recalculate TXID from the signed transaction
    final signedDartsvTx = dartsv.Transaction.fromHex(signedTxHex);
    final signedTxid = signedDartsvTx.id;

    final signedPaymentTx = BitcoinTransaction(
      txid: signedTxid, // Recalculated from signed transaction
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

    // 4c. Record the outgoing transaction in PENDING state

    // CRITICAL: Use the actual change address (same logic as _buildPaymentTransaction)
    // If no changeAddress was provided, we use the first UTXO's address as change destination
    final actualChangeAddress = msg.changeAddress ?? selectedUtxos.first.address;

    // Get recipient addresses for recording
    final recipientAddresses = _getRecipientAddresses(msg.outputs, msg.addresses);

    await _recordOutgoingTransaction(
      walletId: msg.walletId,
      transaction: signedPaymentTx,
      spentUtxoKeys: utxoKeys,
      recipientAddresses: recipientAddresses,
      paymentAmount: effectiveAmount,
      changeAddress: actualChangeAddress,
    );

    // 5. Get block headers for validation
    final blockHeaders = await _getBlockHeaders(ancestorResult.blockHeights);

    // 6. Create BEEF package
    try {
      final beef = await _createBEEF(
        paymentTransaction: signedPaymentTx,
        ancestorTransactions: ancestorResult.ancestorTransactions,
        merkleProofs: ancestorResult.merkleProofs,
        blockHeaders: blockHeaders,
      );

      // Calculate change amount
      final totalInput = selectedUtxos.fold<BigInt>(
        BigInt.zero,
        (sum, utxo) => sum + utxo.satoshis,
      );
      final changeAmount = totalInput - effectiveAmount - BigInt.from(1000); // Rough fee estimate

      // 7. Return BEEF to caller (does NOT broadcast)
      final sender = context.sender;
      if (sender != null) {
        final response = BEEFPaymentResponse(
          invoiceId: msg.invoiceId,
          beefBytes: beef,
          txid: signedPaymentTx.txid, // Use signed transaction's txid
          amountPaid: effectiveAmount,
          changeAmount: changeAmount > BigInt.zero ? changeAmount : BigInt.zero,
          ancestorCount: ancestorResult.ancestorTransactions.length,
          success: true,
        );
        sender.tell(response);
      }
    } catch (e) {
      _sendError(msg.invoiceId, 'Failed to create BEEF: $e');
    }
  }

  /// Extract recipient addresses from outputs or legacy addresses
  List<String> _getRecipientAddresses(List<InvoiceOutputSpec>? outputs, List<String> legacyAddresses) {
    if (outputs == null || outputs.isEmpty) {
      return legacyAddresses;
    }
    // For P2PKH outputs, return addresses; for P2MS, return "multisig" placeholder
    return outputs.map((o) {
      if (o is P2PKHOutputSpec) {
        return o.address;
      } else if (o is P2MSOutputSpec) {
        return 'multisig:${o.threshold}-of-${o.totalKeys}';
      }
      return 'unknown';
    }).toList();
  }

  // Ancestor collection methods removed - now using AncestorChainService

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

  /// Build payment transaction with support for multiple output types (P2PKH, P2MS)
  Future<BitcoinTransaction?> _buildPaymentTransactionWithOutputs({
    required List<BitcoinUtxo> selectedUtxos,
    List<InvoiceOutputSpec>? outputs,
    required List<String> legacyAddresses,
    required BigInt legacyAmount,
    String? changeAddress,
    required String walletId,
    required List<dartsv.SVPublicKey> publicKeys,
  }) async {
    try {
      // Calculate total input
      final totalInput = selectedUtxos.fold<BigInt>(
        BigInt.zero,
        (sum, utxo) => sum + utxo.satoshis,
      );

      // Build transaction using TransactionBuilder pattern
      final txBuilder = dartsv.TransactionBuilder();

      // Track receiving addresses for record
      final receivingAddresses = <String>[];
      BigInt totalOutputAmount = BigInt.zero;

      // Add payment outputs based on outputs or legacy addresses
      if (outputs != null && outputs.isNotEmpty) {
        // New multi-output mode
        for (final output in outputs) {
          totalOutputAmount += output.amount;

          switch (output) {
            case P2PKHOutputSpec p2pkh:
              final toAddress = dartsv.Address.fromBase58(p2pkh.address);
              final recipientBuilder = dartsv.P2PKHLockBuilder.fromAddress(toAddress);
              txBuilder.spendToLockBuilder(recipientBuilder, p2pkh.amount);
              receivingAddresses.add(p2pkh.address);

            case P2MSOutputSpec p2ms:
              // Build multisig output
              final pubKeys = p2ms.publicKeys
                  .map((hex) => dartsv.SVPublicKey.fromHex(hex))
                  .toList();
              final msLockBuilder = dartsv.P2MSLockBuilder(
                pubKeys,
                p2ms.threshold,
                sorting: true, // BIP67 lexicographical sorting for determinism
              );
              txBuilder.spendToLockBuilder(msLockBuilder, p2ms.amount);
              receivingAddresses.add('multisig:${p2ms.threshold}-of-${p2ms.totalKeys}');
          }
        }
      } else {
        // Legacy mode - split amount across addresses
        totalOutputAmount = legacyAmount;
        for (final address in legacyAddresses) {
          final toAddress = dartsv.Address.fromBase58(address);
          final amountPerAddress = legacyAmount ~/ BigInt.from(legacyAddresses.length);

          final recipientBuilder = dartsv.P2PKHLockBuilder.fromAddress(toAddress);
          txBuilder.spendToLockBuilder(recipientBuilder, amountPerAddress);
          receivingAddresses.add(address);
        }
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
        final unlockBuilder = dartsv.P2PKHUnlockBuilder(publicKey);
        txBuilder.spendFromOutpoint(outpoint, dartsv.TransactionInput.MAX_SEQ_NUMBER, unlockBuilder);
      }

      // Apply transaction settings (proven pattern)
      txBuilder
          .withFeePerKb(1) // Low fee rate valid for BSV network
          .withOption(dartsv.TransactionOption.DISABLE_DUST_OUTPUTS);

      // Build unsigned transaction (skip sanity checks for flexibility)
      final unsignedTx = txBuilder.build(false);
      final rawHex = unsignedTx.serialize();
      final txid = unsignedTx.id;

      // Calculate actual fee and change from built transaction
      final totalOutput = unsignedTx.outputs.fold<BigInt>(
        BigInt.zero,
        (sum, output) => sum + output.satoshis,
      );
      final fee = totalInput - totalOutput;

      // Create transaction record
      return BitcoinTransaction(
        txid: txid,
        rawHex: rawHex,
        status: TransactionStatus.created,
        inputValue: totalInput,
        outputValue: totalOutput,
        fee: fee,
        receivingAddresses: receivingAddresses,
        sendingAddresses: selectedUtxos.map((u) => u.address).toList(),
        netAmount: -(totalOutputAmount + fee),
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        lockTime: 0,
        version: 2,
      );
    } catch (e, stackTrace) {
      return null;
    }
  }

  /// Build payment transaction from selected UTXOs (legacy - for backward compatibility)
  /// Using proven patterns from transaction_builder_service.dart
  Future<BitcoinTransaction?> _buildPaymentTransaction({
    required List<BitcoinUtxo> selectedUtxos,
    required List<String> outputAddresses,
    required BigInt outputAmount,
    String? changeAddress,
    required String walletId,
    required List<dartsv.SVPublicKey> publicKeys,
  }) async {
    return _buildPaymentTransactionWithOutputs(
      selectedUtxos: selectedUtxos,
      outputs: null,
      legacyAddresses: outputAddresses,
      legacyAmount: outputAmount,
      changeAddress: changeAddress,
      walletId: walletId,
      publicKeys: publicKeys,
    );
  }

  /// Get public keys for all UTXOs being spent
  /// 
  /// For each UTXO, this method:
  /// 1. Retrieves the address metadata to find the derivation index
  /// 2. Derives the private key for that address from the wallet's xpriv or mnemonic
  /// 3. Extracts the public key from the private key
  Future<List<dartsv.SVPublicKey>> _getPublicKeysForUTXOs(
    String walletId,
    List<BitcoinUtxo> utxos,
  ) async {
    final publicKeys = <dartsv.SVPublicKey>[];
    
    // Get the wallet's extended private key
    dartsv.HDPrivateKey hdPrivateKey;
    
    final xpriv = await _secureStorage.getXPriv(walletId);
    if (xpriv != null) {
      // Parse the extended private key directly
      hdPrivateKey = dartsv.HDPrivateKey.fromXpriv(xpriv);
    } else {
      // Try mnemonic if xpriv not available (e.g., wallet created from seed phrase)
      final mnemonic = await _secureStorage.getMnemonic(walletId);
      if (mnemonic == null) {
        throw Exception('Wallet xpriv or mnemonic not found in secure storage');
      }
      
      // Get wallet network type from storage
      final walletData = await _storage.getWallet(walletId);
      final networkStr = walletData?['network'] as String? ?? 'test';
      final networkType = networkStr == 'main' 
          ? dartsv.NetworkType.MAIN 
          : dartsv.NetworkType.TEST;
      
      // Derive HD private key from mnemonic
      hdPrivateKey = dartsv.HDPrivateKey.fromSeed(
        dartsv.Mnemonic().toSeedHex(mnemonic, ''),
        networkType,
      );
    }
    
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
      return null;
    }
    
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
      for (final ancestor in ancestorTransactions) {
      }
      for (final proof in merkleProofs) {
      }
      
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
      
      // Debug: Log what we're passing to BEEF.create()
      for (int i = 0; i < txBytes.length; i++) {
      }


      // 5. Create BEEF using the existing BEEF.create() method
      final beef = BEEF.create(
        bumps: bumps,
        txs: txBytes,
        hasMerkle: hasMerkle,
        bumpIndex: bumpIndex,
      );
      
      // 6. Serialize BEEF
      final serialized = beef.serialize();
      Future.delayed(Duration(seconds: 1)); //debug delay so BEEF hex can dump to console
      
      // 7. Verify BEEF can be parsed (sanity check)
      try {
        final parsed = BEEF.parse(serialized);
      } catch (e, stackTrace) {
        throw Exception('Created BEEF is invalid: $e');
      }
      
      return serialized;
    } catch (e) {
      rethrow;
    }
  }


  /// Build a BUMP from a MerkleProof
  /// 
  /// Converts our MerkleProof storage format to the BUMP structure needed for BEEF.
  /// Based on CryptoUtils.createBumpFromTscProof() implementation.
  /// 
  /// Supports two storage formats:
  /// 1. Raw BUMP hex string (single element > 64 chars) - parse directly
  /// 2. List of sibling hashes (each 64 chars) - build BUMP from scratch
  BUMP _buildBUMPFromMerkleProof(MerkleProof proof) {
    // Check if merkleProof contains a raw BUMP serialization (single element > 64 chars)
    // or a list of sibling hashes (each exactly 64 chars for a 32-byte hash)
    if (proof.merkleProof.length == 1 && proof.merkleProof[0].length > 64) {
      // This is a raw BUMP hex string - parse it directly
      try {
        final bumpBytes = Uint8List.fromList(hex.decode(proof.merkleProof[0]));
        final bump = BUMP.fromBytes(bumpBytes);
        return bump;
      } catch (e) {
        rethrow;
      }
    }
    
    // Otherwise, build BUMP from sibling hashes (original logic)
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
    context.sender?.tell(BEEFPaymentResponse.error(
      invoiceId: invoiceId,
      error: error,
    ));
  }

  /// Record outgoing transaction in wallet history (in PENDING state)
  Future<void> _recordOutgoingTransaction({
    required String walletId,
    required BitcoinTransaction transaction,
    required List<String> spentUtxoKeys,
    required List<String> recipientAddresses,
    required BigInt paymentAmount,
    String? changeAddress,
  }) async {
    // Calculate change amount
    final changeAmount = transaction.outputValue - paymentAmount;
    
    final command = RecordOutgoingTransactionCommand(
      walletId: walletId,
      txid: transaction.txid,
      rawHex: transaction.rawHex,
      totalInputSats: transaction.inputValue.toInt(),
      totalOutputSats: transaction.outputValue.toInt(),
      fee: transaction.fee.toInt(),
      numInputs: spentUtxoKeys.length,
      numOutputs: recipientAddresses.length + (changeAddress != null ? 1 : 0),
      txVersion: transaction.version,
      txLockTime: transaction.lockTime,
      spentUtxoKeys: spentUtxoKeys,
      recipientAddresses: recipientAddresses,
      paymentAmount: paymentAmount,
      changeAddress: changeAddress,
      changeAmount: changeAmount > BigInt.zero ? changeAmount : null,
    );
    
    _walletManager.tell(
      WalletCommandMessage(walletId, command),
      sender: context.self,
    );
  }

  @override
  Future<void> postStop() async {
  }
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

