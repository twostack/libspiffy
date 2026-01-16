import 'dart:async';
import 'package:dactor/dactor.dart';
import 'package:dartsv/dartsv.dart' as dartsv;

import '../core/wallet_commands.dart';
import '../core/wallet_events.dart';
import '../models/bitcoin_utxo.dart';
import '../storage/secure_storage.dart';
import '../storage/read_model_storage.dart';
import '../utils/benford_distribution.dart';
import 'wallet_messages.dart';

/// Coordinator actor for Benford UTXO splitting operations
/// 
/// This actor handles the orchestration of splitting UTXOs according to
/// Benford's Law distribution. It listens for UTXOSplitInitiatedEvent and:
/// 1. Fetches UTXO details from read model storage
/// 2. Generates new addresses for outputs
/// 3. Calculates Benford-distributed amounts
/// 4. Builds and signs transactions
/// 5. Broadcasts via ARCActor
/// 6. Sends CQRS commands to update wallet state
class BenfordCoordinatorActor extends Actor {
  final ActorRef _walletManager;
  final ActorRef _arcActor;
  final SecureStorage _secureStorage;
  final ReadModelStorage _storage;

  BenfordCoordinatorActor({
    required ActorRef walletManager,
    required ActorRef arcActor,
    required SecureStorage secureStorage,
    required ReadModelStorage storage,
  })  : _walletManager = walletManager,
        _arcActor = arcActor,
        _secureStorage = secureStorage,
        _storage = storage;

  @override
  void preStart() {
    print('[BenfordCoordinatorActor] Started');
  }

  @override
  Future<void> onMessage(dynamic message) async {
    try {
      if (message is UTXOSplitInitiatedEvent) {
        await _handleSplitInitiated(message);
      } else if (message is SplitUTXOsToBenfordCommand) {
        // Command can be sent directly to coordinator
        await _handleSplitCommand(message);
      } else {
        print('[BenfordCoordinatorActor] Unknown message type: ${message.runtimeType}');
      }
    } catch (e, stackTrace) {
      print('[BenfordCoordinatorActor] Error: $e');
      print('[BenfordCoordinatorActor] Stack trace: $stackTrace');
    }
  }

  /// Handle SplitUTXOsToBenfordCommand sent directly to coordinator
  Future<void> _handleSplitCommand(SplitUTXOsToBenfordCommand command) async {
    print('[BenfordCoordinatorActor] Handling SplitUTXOsToBenfordCommand');
    
    // Get wallet info to check wallet type
    final wallet = await _storage.getWallet(command.walletId);
    if (wallet == null) {
      print('[BenfordCoordinatorActor] Wallet not found: ${command.walletId}');
      _sendErrorResponse(command, 'Wallet not found: ${command.walletId}');
      return;
    }
    
    // Business rule: Watch-only (xpub) wallets cannot sign transactions
    if (wallet['walletType'] == 'xpub') {
      print('[BenfordCoordinatorActor] Cannot split UTXOs for watch-only wallet');
      _sendErrorResponse(command, 'Signing (split) not supported for watch-only wallets');
      return;
    }
    
    // Get available UTXOs from read model
    final utxos = await _storage.getUTXOs(command.walletId);
    final availableUtxos = utxos
        .where((u) => u.status == UTXOStatus.available)
        .toList();

    if (availableUtxos.isEmpty) {
      print('[BenfordCoordinatorActor] No available UTXOs to split');
      _sendErrorResponse(command, 'No available UTXOs to split');
      return;
    }

    // Determine how many UTXOs to split
    final utxosToSplit = command.maxUtxosToSplit != null
        ? availableUtxos.take(command.maxUtxosToSplit!).toList()
        : availableUtxos;

    print('[BenfordCoordinatorActor] Splitting ${utxosToSplit.length} of ${availableUtxos.length} available UTXOs');
    if (command.maxUtxosToSplit != null) {
      print('[BenfordCoordinatorActor]   Keeping ${availableUtxos.length - utxosToSplit.length} UTXOs available for transactions');
    }

    // Process each UTXO and track results
    final txids = <String>[];
    int successfulSplits = 0;
    
    for (final sourceUtxo in utxosToSplit) {
      final txid = await _splitSingleUtxo(
        walletId: command.walletId,
        sourceUtxo: sourceUtxo,
        targetCount: command.targetUtxoCount,
        feeRate: command.feeRate ?? BigInt.one,
      );
      
      if (txid != null) {
        txids.add(txid);
        successfulSplits++;
      }
    }
    
    // Send success response
    final sender = context.sender;
    if (sender != null) {
      sender.tell(SplitUTXOsResponse(
        walletId: command.walletId,
        success: true,
        splitCount: successfulSplits * command.targetUtxoCount,
        txids: txids,
      ));
    }
    
    print('[BenfordCoordinatorActor] Split operation completed: $successfulSplits/${utxosToSplit.length} UTXOs split successfully');
  }

  /// Handle UTXOSplitInitiatedEvent from aggregate
  Future<void> _handleSplitInitiated(UTXOSplitInitiatedEvent event) async {
    print('[BenfordCoordinatorActor] Handling UTXOSplitInitiatedEvent');
    print('[BenfordCoordinatorActor]   Wallet: ${event.walletId}');
    print('[BenfordCoordinatorActor]   UTXOs to split: ${event.utxoKeysToSplit.length}');
    
    // Fetch UTXO details from read model
    final allUtxos = await _storage.getUTXOs(event.walletId);
    final utxoMap = {for (var u in allUtxos) u.key: u};

    // Process each UTXO key
    for (final utxoKey in event.utxoKeysToSplit) {
      final sourceUtxo = utxoMap[utxoKey];
      if (sourceUtxo == null) {
        print('[BenfordCoordinatorActor]   ⚠️ UTXO $utxoKey not found in read model');
        continue;
      }

      await _splitSingleUtxo(
        walletId: event.walletId,
        sourceUtxo: sourceUtxo,
        targetCount: event.targetUtxoCount,
        feeRate: event.feeRate,
      );
    }
  }

  /// Split a single UTXO into multiple outputs following Benford distribution
  /// Returns the transaction ID if successful, null otherwise
  Future<String?> _splitSingleUtxo({
    required String walletId,
    required BitcoinUtxo sourceUtxo,
    required int targetCount,
    required BigInt feeRate,
  }) async {
    print('[BenfordCoordinatorActor] Splitting UTXO: ${sourceUtxo.key}');
    
    try {
      // 1. Estimate fee
      final estimatedTxSize = 180 + (targetCount * 34) + 10;
      final estimatedFee = feeRate * BigInt.from(estimatedTxSize);

      // Check if UTXO is large enough
      final minTotalNeeded = BigInt.from(targetCount) + estimatedFee;
      if (sourceUtxo.satoshis < minTotalNeeded) {
        print('[BenfordCoordinatorActor]   ⚠️ UTXO too small (${sourceUtxo.satoshis} < $minTotalNeeded), skipping');
        return null;
      }

      // 2. Calculate Benford distribution
      final amountToDistribute = sourceUtxo.satoshis - estimatedFee;
      final outputAmounts = BenfordDistribution.distribute(
        amountToDistribute,
        targetCount,
      );

      // 3. Generate new addresses
      final outputAddresses = await _generateAddresses(
        walletId: walletId,
        count: targetCount,
      );

      // 4. Build and sign transaction
      final txResult = await _buildAndSignTransaction(
        walletId: walletId,
        sourceUtxo: sourceUtxo,
        outputAddresses: outputAddresses,
        outputAmounts: outputAmounts,
        feeRate: feeRate,
      );

      if (txResult == null) {
        print('[BenfordCoordinatorActor]   ✗ Failed to build transaction');
        return null;
      }

      final txid = txResult['txid'] as String;
      final txHex = txResult['txHex'] as String;
      final actualFee = txResult['actualFee'] as BigInt;

      print('[BenfordCoordinatorActor]   ✓ Transaction built: $txid');

      // 5. Broadcast via ARCActor
      print('[BenfordCoordinatorActor]   Broadcasting transaction...');
      _arcActor.tell(BroadcastTransactionMessage(
        walletId,
        txHex,
        txid,
      ));

      // 6. Send CQRS commands to update wallet state
      
      // 6a. Mark source UTXO as spent
      _walletManager.tell(WalletCommandMessage(
        walletId,
        SpendUTXOCommand(
          walletId: walletId,
          utxoKey: sourceUtxo.key,
          spendingTxId: txid,
          fee: actualFee,
        ),
      ));

      // 6b. Register new UTXOs (pending status)
      for (int i = 0; i < outputAmounts.length; i++) {
        _walletManager.tell(WalletCommandMessage(
          walletId,
          ReceiveUTXOCommand(
            walletId: walletId,
            txid: txid,
            vout: i,
            satoshis: outputAmounts[i],
            scriptPubKey: _createScriptPubKeyHex(outputAddresses[i]),
            address: outputAddresses[i],
            initialStatus: UTXOStatus.pending,
          ),
        ));
      }

      // 6c. Record transaction
      _walletManager.tell(WalletCommandMessage(
        walletId,
        RecordOutgoingTransactionCommand(
          walletId: walletId,
          txid: txid,
          rawHex: txHex,
          totalInputSats: sourceUtxo.satoshis.toInt(),
          totalOutputSats: outputAmounts.fold<BigInt>(
            BigInt.zero,
            (sum, amount) => sum + amount,
          ).toInt(),
          fee: actualFee.toInt(),
          numInputs: 1,
          numOutputs: outputAmounts.length,
          txVersion: 2,
          txLockTime: 0,
          spentUtxoKeys: [sourceUtxo.key],
          recipientAddresses: outputAddresses,
          paymentAmount: outputAmounts.fold<BigInt>(
            BigInt.zero,
            (sum, amount) => sum + amount,
          ),
        ),
      ));

      // 7. Register outputs with ARCActor for status tracking
      _arcActor.tell(RegisterTransactionOutputsMessage(
        txid: txid,
        walletId: walletId,
        vouts: List.generate(outputAmounts.length, (i) => i),
      ));

      print('[BenfordCoordinatorActor]   ✓ Split completed for ${sourceUtxo.key}');
      
      return txid;

    } catch (e, stackTrace) {
      print('[BenfordCoordinatorActor]   ✗ Error splitting UTXO: $e');
      print('[BenfordCoordinatorActor]   Stack trace: $stackTrace');
      return null;
    }
  }

  /// Generate N new addresses for the wallet
  /// 
  /// For HD wallets, this waits for address persistence before returning
  /// to ensure addresses are in the database before transactions are broadcast.
  Future<List<String>> _generateAddresses({
    required String walletId,
    required int count,
  }) async {
    final addresses = <String>[];
    
    // Get wallet info to determine wallet type
    final wallet = await _storage.getWallet(walletId);
    if (wallet == null) {
      throw StateError('Wallet not found: $walletId');
    }

    print('[BenfordCoordinatorActor] Generating $count addresses for wallet type: ${wallet['walletType']}');

    // For WIF wallets, all outputs go to the same address
    if (wallet['walletType'] == 'wif') {
      final wifKey = await _secureStorage.getWIF(walletId);
      if (wifKey == null) {
        throw StateError('WIF key not found for wallet: $walletId');
      }
      final privKey = dartsv.SVPrivateKey.fromWIF(wifKey);
      final networkType = wallet['network'] == 'mainnet' 
        ? dartsv.NetworkType.MAIN 
        : dartsv.NetworkType.TEST;
      final address = dartsv.Address.fromPublicKey(privKey.publicKey, networkType);
      
      for (int i = 0; i < count; i++) {
        addresses.add(address.toString());
      }
      return addresses;
    }

    // For HD wallets, generate addresses and WAIT for persistence
    final futures = <Future<String>>[];

    for (int i = 0; i < count; i++) {
      final completer = Completer<String>();
      
      // Spawn temporary actor to receive response
      final receiverName = 'benford-addr-receiver-$i-${DateTime.now().millisecondsSinceEpoch}';
      print('[BenfordCoordinatorActor]   Spawning receiver actor: $receiverName');
      final receiver = await context.system.spawn(
        receiverName,
        () => _AddressReceiverActor(completer),
      );

      // Create command with UNIQUE commandId to prevent sender overwriting
      // Each command needs its own ID so BitcoinWalletAggregate can track senders separately
      final command = GenerateAddressCommand(
        walletId: walletId,
        commandId: 'benford-addr-gen-$i-${DateTime.now().microsecondsSinceEpoch}',
      );
      
      // Send command WITH sender for response routing
      print('[BenfordCoordinatorActor]   Sending GenerateAddressCommand #$i (${command.commandId}) with sender: $receiverName');
      _walletManager.tell(
        WalletCommandMessage(walletId, command),
        sender: receiver,
      );

      futures.add(completer.future);
      
      // Small delay to ensure unique timestamps for commandId
      await Future.delayed(const Duration(microseconds: 10));
    }

    // Wait for ALL addresses to be generated and persisted
    try {
      final generatedAddresses = await Future.wait(futures)
          .timeout(const Duration(seconds: 30));
      addresses.addAll(generatedAddresses);
      print('[BenfordCoordinatorActor] Generated ${addresses.length} addresses (persisted)');
    } on TimeoutException {
      print('[BenfordCoordinatorActor] Timeout waiting for address generation');
      throw StateError('Address generation timed out after 30 seconds');
    } catch (e) {
      print('[BenfordCoordinatorActor] Error generating addresses: $e');
      rethrow;
    }

    return addresses;
  }

  /// Build and sign a split transaction
  Future<Map<String, dynamic>?> _buildAndSignTransaction({
    required String walletId,
    required BitcoinUtxo sourceUtxo,
    required List<String> outputAddresses,
    required List<BigInt> outputAmounts,
    required BigInt feeRate,
  }) async {
    try {
      // Get private key for source UTXO
      final privateKey = await _getPrivateKeyForAddress(
        walletId: walletId,
        address: sourceUtxo.address,
      );

      // Build transaction
      final txBuilder = dartsv.TransactionBuilder();

      // Create locking script for the UTXO
      final lockedAddress = dartsv.Address.fromBase58(sourceUtxo.address);
      final lockingScript = dartsv.P2PKHLockBuilder.fromAddress(lockedAddress)
          .getScriptPubkey();

      // Create signer
      final signer = dartsv.TransactionSigner(
        dartsv.SighashType.SIGHASH_ALL.value | dartsv.SighashType.SIGHASH_FORKID.value,
        privateKey,
      );

      // Create UTXO outpoint
      final outpoint = dartsv.TransactionOutpoint(
        sourceUtxo.txid,
        sourceUtxo.vout,
        sourceUtxo.satoshis,
        lockingScript,
      );

      // Add input with signer
      txBuilder.spendFromOutpointWithSigner(
        signer,
        outpoint,
        dartsv.TransactionInput.MAX_SEQ_NUMBER,
        dartsv.P2PKHUnlockBuilder(privateKey.publicKey),
      );

      // Add outputs
      for (int i = 0; i < outputAmounts.length; i++) {
        final address = dartsv.Address.fromBase58(outputAddresses[i]);
        txBuilder.spendToPKH(address, outputAmounts[i]);
      }

      // Set fee rate and build
      txBuilder
          .withFeePerKb(feeRate.toInt())
          .withOption(dartsv.TransactionOption.DISABLE_DUST_OUTPUTS);

      // Build and sign transaction
      final signedTx = txBuilder.build(false); // Skip sanity checks
      final txid = signedTx.id;
      final txHex = signedTx.serialize();

      // Calculate actual fee
      final actualFee = sourceUtxo.satoshis - outputAmounts.fold<BigInt>(
        BigInt.zero,
        (sum, amount) => sum + amount,
      );

      return {
        'txid': txid,
        'txHex': txHex,
        'actualFee': actualFee,
      };
    } catch (e) {
      print('[BenfordCoordinatorActor] Error building transaction: $e');
      return null;
    }
  }

  /// Get private key for an address
  Future<dartsv.SVPrivateKey> _getPrivateKeyForAddress({
    required String walletId,
    required String address,
  }) async {
    // Get wallet info
    final wallet = await _storage.getWallet(walletId);
    if (wallet == null) {
      throw StateError('Wallet not found: $walletId');
    }

    print('[BenfordCoordinatorActor] Getting private key for wallet type: ${wallet['walletType']}');

    // For WIF wallets
    if (wallet['walletType'] == 'wif') {
      final wifKey = await _secureStorage.getWIF(walletId);
      if (wifKey == null) {
        throw StateError('WIF key not found for wallet: $walletId');
      }
      return dartsv.SVPrivateKey.fromWIF(wifKey);
    }

    // For HD wallets, derive the key
    final xpriv = await _secureStorage.getXPriv(walletId);
    if (xpriv == null) {
      throw StateError('Extended private key not found for wallet: $walletId');
    }

    // Try to get derivation index from UTXO first
    int? derivationIndex;
    final utxos = await _storage.getUTXOs(walletId);
    final utxo = utxos.firstWhere(
      (u) => u.address == address,
      orElse: () => throw StateError('UTXO with address not found: $address'),
    );
    derivationIndex = utxo.derivationIndex;
    
    // If UTXO doesn't have derivationIndex, look up from address metadata
    if (derivationIndex == null) {
      final addressMeta = await _storage.getAddressMetadata(walletId, address);
      if (addressMeta != null) {
        derivationIndex = addressMeta.derivationIndex;
        print('[BenfordCoordinatorActor]    → Using derivation index from address metadata: $derivationIndex');
      }
    }
    
    // Default to 0 only if still unknown (shouldn't happen for properly imported wallets)
    if (derivationIndex == null) {
      print('[BenfordCoordinatorActor]    ⚠️ Warning: No derivation index found for address $address, defaulting to 0');
      derivationIndex = 0;
    }

    // Derive the private key using derivation index
    final hdPrivateKey = dartsv.HDPrivateKey.fromXpriv(xpriv);
    final derivationPath = 'm/0/$derivationIndex';
    print('[BenfordCoordinatorActor]    → Deriving key at path: $derivationPath');
    final derivedKey = hdPrivateKey.deriveChildKey(derivationPath);
    
    return derivedKey.privateKey;
  }

  /// Create script pubkey hex for an address
  String _createScriptPubKeyHex(String address) {
    final addr = dartsv.Address.fromBase58(address);
    final script = dartsv.P2PKHLockBuilder.fromAddress(addr).getScriptPubkey();
    return script.toHex();
  }
  
  /// Send error response back to the sender
  void _sendErrorResponse(SplitUTXOsToBenfordCommand command, String error) {
    final sender = context.sender;
    if (sender != null) {
      sender.tell(SplitUTXOsResponse(
        walletId: command.walletId,
        success: false,
        error: error,
      ));
    }
  }
}

/// Helper actor to receive address generation responses
class _AddressReceiverActor extends Actor {
  final Completer<String> completer;

  _AddressReceiverActor(this.completer);
  
  @override
  void preStart() {
    print('[_AddressReceiverActor] Started');
  }

  @override
  Future<void> onMessage(dynamic message) async {
    print('[_AddressReceiverActor] Received message: ${message.runtimeType}');
    if (message is AddressGeneratedResponse && !completer.isCompleted) {
      print('[_AddressReceiverActor] Processing AddressGeneratedResponse: success=${message.success}, address=${message.address}');
      if (message.success) {
        completer.complete(message.address);
        print('[_AddressReceiverActor] Completer completed with address: ${message.address}');
      } else {
        completer.completeError(
          Exception(message.error ?? 'Address generation failed'),
        );
        print('[_AddressReceiverActor] Completer completed with error');
      }
    } else if (message is AddressGeneratedResponse) {
      print('[_AddressReceiverActor] Ignoring message - completer already completed');
    } else {
      print('[_AddressReceiverActor] Ignoring message - unexpected type: ${message.runtimeType}');
    }
  }
}

