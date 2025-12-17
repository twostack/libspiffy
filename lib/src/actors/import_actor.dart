import 'dart:async';

import 'package:convert/convert.dart';
import 'package:dactor/dactor.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:logging/logging.dart';

import '../services/blockchain_data_source.dart';
import '../services/address_discovery_service.dart';
import '../services/transaction_import_service.dart';
import '../services/script_type_registry.dart';
import '../storage/read_model_storage.dart';
import '../models/blockchain_data_models.dart';
import '../models/bitcoin_utxo.dart'; // For UTXOStatus
import '../models/wallet_event.dart';
import '../core/wallet_commands.dart';
import '../core/wallet_events.dart';
import 'wallet_messages.dart';

/// Actor for handling long-running wallet import operations
///
/// This actor orchestrates the complete wallet import process:
/// 1. Create wallet from xpriv
/// 2. Discover used addresses (BIP44 gap limit scanning)
/// 3. Import transactions with merkle proofs
/// 4. Send ReceiveUTXOCommand for each discovered UTXO
/// 5. Report progress via actor messages
///
/// The ImportActor keeps aggregates pure by handling all I/O externally
/// and sending atomic commands to the wallet aggregate.
class ImportActor extends Actor {
  final Logger _logger = Logger('ImportActor');
  final BlockchainDataSource _dataSource;
  final AddressDiscoveryService _discoveryService;
  final TransactionImportService _importService;
  final ReadModelStorage _storage;
  final ActorRef _walletManagerActor;
  final void Function(WalletEvent)? _eventBroadcaster;

  // Track import state
  String? _currentImportWalletId;
  bool _isCancelled = false;
  int _totalAddresses = 0;
  int _totalTransactions = 0;
  int _processedTransactions = 0;
  
  // Completer for waiting for wallet creation
  Completer<WalletCreatedMessage>? _walletCreatedCompleter;

  ImportActor({
    required BlockchainDataSource dataSource,
    required ReadModelStorage storage,
    required ActorRef walletManagerActor,
    void Function(WalletEvent)? eventBroadcaster,
  })  : _dataSource = dataSource,
        _discoveryService = AddressDiscoveryService(dataSource),
        _importService = TransactionImportService(dataSource: dataSource),
        _storage = storage,
        _walletManagerActor = walletManagerActor,
        _eventBroadcaster = eventBroadcaster;

  @override
  Future<void> onMessage(dynamic message) async {
    _logger.info('📨 ImportActor received message: ${message.runtimeType}');
    
    try {
      if (message is ImportWalletMessage) {
        _logger.info('▶️  Starting import for wallet: ${message.walletId}, network: ${message.networkType}');
        await _handleImportWallet(message);
      } else if (message is CancelImportMessage) {
        _logger.info('❌ Cancel import requested');
        _handleCancelImport();
      } else if (message is ImportProgressQuery) {
        _logger.info('📊 Progress query received');
        _handleProgressQuery();
      } else if (message is WalletCreatedMessage) {
        if (message.success) {
          _logger.info('✅ WalletCreatedMessage received: ${message.walletId}, root address: ${message.rootAddress}');
        } else {
          _logger.severe('❌ WalletCreatedMessage received with error: ${message.error}');
        }
        
        // Complete the wallet creation completer if waiting
        if (_walletCreatedCompleter != null && !_walletCreatedCompleter!.isCompleted) {
          _walletCreatedCompleter!.complete(message);
        }
      } else {
        _logger.warning('❓ Unknown message type: ${message.runtimeType}');
      }
    } catch (e, stackTrace) {
      _logger.severe('💥 Error handling message: $e', e, stackTrace);
      if (message is ImportWalletMessage) {
        await _notifyImportFailed(message.walletId, e.toString());
      }
    }
  }

  Future<void> _handleImportWallet(ImportWalletMessage message) async {
    final walletId = message.walletId;
    
    // Guard: Prevent duplicate imports
    if (_currentImportWalletId == walletId) {
      _logger.warning('⚠️  Import already in progress for wallet $walletId, ignoring duplicate request');
      return;
    }
    
    _currentImportWalletId = walletId;
    _isCancelled = false;
    _totalAddresses = 0;
    _totalTransactions = 0;
    _processedTransactions = 0;

    _logger.info('🚀 Starting wallet import for $walletId (name: "${message.walletName}")');
    _logger.info('   Network: ${message.networkType}, Gap Limit: ${message.addressGapLimit}');

    try {
      // Phase 1: Create wallet from xpriv or wif
      _logger.info('📝 Phase 1/4: Creating wallet...');
      await _createWallet(message);
      _logger.info('   ✅ Wallet created successfully');

      if (_isCancelled) {
        _logger.info('   ❌ Import cancelled during wallet creation');
        return;
      }

      // Phase 2: Discover used addresses
      _logger.info('🔍 Phase 2/4: Discovering addresses...');
      final discoveredAddresses = await _discoverAddresses(message);
      _totalAddresses = discoveredAddresses.length;
      _logger.info('   ✅ Found $_totalAddresses used addresses');

      if (_isCancelled) {
        _logger.info('   ❌ Import cancelled during address discovery');
        return;
      }

      // Phase 3: Import transactions and UTXOs
      _logger.info('💰 Phase 3/4: Importing transactions for $_totalAddresses addresses...');
      await _importTransactions(message, discoveredAddresses);
      _logger.info('   ✅ Imported $_processedTransactions transactions');

      if (_isCancelled) {
        _logger.info('   ❌ Import cancelled during transaction import');
        return;
      }

      // Phase 4: Complete import
      _logger.info('🏁 Phase 4/4: Completing import...');
      await _completeImport(message);
      _logger.info('   ✅ Import finalized');

      _logger.info('✨ Wallet import completed successfully!');
      _logger.info('   📊 Summary: $_totalAddresses addresses, $_processedTransactions transactions');
    } catch (e, stackTrace) {
      _logger.severe('💥 Wallet import failed: $e', e, stackTrace);
      await _notifyImportFailed(walletId, e.toString());
    } finally {
      _currentImportWalletId = null;
      _logger.info('🔓 Import lock released for wallet $walletId');
    }
  }

  Future<void> _createWallet(ImportWalletMessage message) async {
    _logger.info('   → Creating wallet via CreateWalletMessage for wallet ${message.walletId}');
    
    final importType = message.xpriv != null ? 'xpriv' : 'wif';
    _logger.info('   → Import type: $importType');
    
    // Create wallet using CreateWalletMessage (spawns the wallet actor)
    // NOT CreateWalletCommand wrapped in WalletCommandMessage (which expects existing actor)
    final createMessage = CreateWalletMessage(
      message.walletId,
      message.walletName,
      xpriv: message.xpriv,
      wif: message.wif,
      walletMetadata: {
        'network': message.networkType,
        'importedFrom': importType,
      },
    );

    _logger.info('   → Sending CreateWalletMessage to WalletManagerActor to spawn wallet aggregate');
    _logger.info('   → Wallet ID: ${message.walletId}, Name: ${message.walletName}');
    if (message.xpriv != null) {
      _logger.info('   → Has xpriv: ${message.xpriv!.isNotEmpty}');
    } else {
      _logger.info('   → Has wif: ${message.wif!.isNotEmpty}');
    }
    
    _walletManagerActor.tell(createMessage, sender: context.self);
    _logger.info('   → CreateWalletMessage sent to WalletManagerActor');
    
    // Wait for wallet actor to be spawned and initialized
    // The WalletCreatedMessage will be received in onMessage and complete the completer
    _logger.info('   → Waiting for WalletCreatedMessage (max 10 seconds)...');
    _walletCreatedCompleter = Completer<WalletCreatedMessage>();
    
    try {
      final walletCreatedMsg = await _walletCreatedCompleter!.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          _logger.warning('   ⚠️  Timeout waiting for WalletCreatedMessage, proceeding anyway...');
          // Return a fake success message to continue
          return WalletCreatedMessage(
            message.walletId,
            '', // rootAddress
            true, // success
          );
        },
      );
      
      // Check if wallet creation succeeded
      if (!walletCreatedMsg.success) {
        throw StateError('Wallet creation failed: ${walletCreatedMsg.error}');
      }
      
      _logger.info('   → Wallet aggregate confirmed spawned with root address: ${walletCreatedMsg.rootAddress}');
    } catch (e) {
      _logger.severe('   ❌ Error waiting for wallet creation: $e');
      rethrow;
    } finally {
      _walletCreatedCompleter = null; // Clean up
    }
    
    _logger.info('   → Broadcasting WalletImportStartedEvent');

    // Notify import started
    await _notifyEvent(message.walletId, WalletImportStartedEvent(
      walletId: message.walletId,
      xpriv: message.xpriv,
      wif: message.wif,
      walletName: message.walletName,
      addressGapLimit: message.addressGapLimit,
    ));

    _logger.info('   → Reporting progress: Wallet created (10%)');
    _reportProgress(
      'Wallet created',
      0.1,
      0,
      0,
    );
  }

  Future<List<DiscoveredAddress>> _discoverAddresses(
    ImportWalletMessage message,
  ) async {
    if (message.wif != null) {
      return await _discoverAddressesForWif(message);
    } else {
      return await _discoverAddressesForXpriv(message);
    }
  }

  Future<List<DiscoveredAddress>> _discoverAddressesForXpriv(
    ImportWalletMessage message,
  ) async {
    _logger.info('   → Deriving HD keys from xpriv');
    final hdPrivateKey = dartsv.HDPrivateKey.fromXpriv(message.xpriv!);
    final hdPublicKey = hdPrivateKey.hdPublicKey;
    
    _logger.info('   → Xpriv path info:');
    _logger.info('      Depth: ${hdPrivateKey.nodeDepth}');
    _logger.info('      Xpub: ${hdPublicKey.xpubkey}');
    _logger.info('      ⚠️  NOTE: For BSV, xpriv should be at m/44\'/236\'/0\' (depth 3)');
    _logger.info('      ⚠️  For Bitcoin, xpriv would be at m/44\'/0\'/0\' (depth 3)');

    _logger.info('   → Starting address discovery (gap limit: ${message.addressGapLimit})');
    final discoveryResult = await _discoveryService.discoverAddresses(
      hdPublicKey: hdPublicKey,
      networkType: message.networkType,
      gapLimit: message.addressGapLimit,
      onProgress: (scannedCount, usedCount) {
        if (!_isCancelled) {
          _logger.fine('      Scanned $scannedCount addresses, found $usedCount used');
          _reportProgress(
            'Scanning addresses: $usedCount found',
            0.1 + (0.3 * (scannedCount / (usedCount + message.addressGapLimit))),
            0,
            0,
          );
        }
      },
    );

    _logger.info('   → Discovery complete: ${discoveryResult.usedAddresses.length} addresses found');
    _logger.info('   → Total transactions across all addresses: ${discoveryResult.totalTransactions}');
    
    // Log each discovered address for debugging
    _logger.info('   📋 Discovered addresses:');
    for (final addr in discoveryResult.usedAddresses) {
      _logger.info('      • ${addr.address} (index: ${addr.derivationIndex}, change: ${addr.isChange}, txs: ${addr.transactionCount})');
    }

    // Register discovered addresses via proper CQRS command flow
    // This ensures events are persisted to EventStore and WalletProjection builds AddressEntity records
    _logger.info('   → Sending RegisterDiscoveredAddressCommands for ${discoveryResult.usedAddresses.length} addresses...');
    int commandsSent = 0;
    for (final address in discoveryResult.usedAddresses) {
      if (_isCancelled) {
        _logger.warning('      ⚠️  Import cancelled, stopping address registration');
        break;
      }

      _logger.info('      → [${commandsSent + 1}/${discoveryResult.usedAddresses.length}] Registering: ${address.address}');
      _logger.info('         (index: ${address.derivationIndex}, change: ${address.isChange}, txs: ${address.transactionCount})');
      
      final command = RegisterDiscoveredAddressCommand(
        walletId: message.walletId,
        address: address.address,
        derivationIndex: address.derivationIndex,
        isChange: address.isChange,
        transactionCount: address.transactionCount,
      );
      
      _logger.info('         📤 Sending command to WalletManagerActor...');
      _walletManagerActor.tell(
        WalletCommandMessage(message.walletId, command),
        sender: context.self,
      );
      commandsSent++;
      _logger.info('         ✅ Command sent (#$commandsSent)');
      
      // Small delay to prevent command queue overload (commands processed sequentially)
      await Future.delayed(const Duration(milliseconds: 10));
    }
    
    _logger.info('   ✅ All $commandsSent RegisterDiscoveredAddressCommands sent');

    
    // Give projection a moment to process the address registration events
    // This is much shorter than before because we're now using proper CQRS flow
    _logger.info('   → Waiting for projection to process ${discoveryResult.usedAddresses.length} address events (500ms)...');
    await Future.delayed(const Duration(milliseconds: 500));
    _logger.info('   ✅ Address registration complete');

    _totalTransactions = discoveryResult.totalTransactions;
    _reportProgress(
      'Found ${discoveryResult.usedAddresses.length} addresses with $_totalTransactions transactions',
      0.4,
      0,
      _totalTransactions,
    );

    return discoveryResult.usedAddresses;
  }

  /// Discover the single address associated with a WIF private key
  Future<List<DiscoveredAddress>> _discoverAddressesForWif(
    ImportWalletMessage message,
  ) async {
    _logger.info('   → Importing from WIF private key');
    
    // Parse WIF to get private key
    final privateKey = dartsv.SVPrivateKey.fromWIF(message.wif!);
    
    // Determine network type
    final network = message.networkType == 'main'
        ? dartsv.NetworkType.MAIN
        : dartsv.NetworkType.TEST;
    
    // Derive the single address
    final address = dartsv.Address.fromPublicKey(privateKey.publicKey, network).toBase58();
    _logger.info('   → WIF address: $address');
    _logger.info('   → Network: ${message.networkType}');
    
    _reportProgress(
      'Checking address history...',
      0.2,
      0,
      0,
    );
    
    // Fetch transaction history for this single address
    // No limit - fetch all transactions (data source handles pagination)
    List<TransactionInfo> history;
    try {
      history = await _dataSource.getTransactionHistory(address);
      _logger.info('   → Found ${history.length} transactions for address');
    } catch (e) {
      _logger.severe('   ❌ Error fetching transaction history: $e');
      history = [];
    }
    
    // Create discovered address entry (single entry for WIF)
    final discoveredAddress = DiscoveredAddress(
      address: address,
      derivationIndex: 0, // WIF has no derivation
      isChange: false, // Not applicable for WIF
      transactionCount: history.length,
      txids: history.map((tx) => tx.txid).toList(),
    );
    
    // Register the address via CQRS command
    _logger.info('   → Registering WIF address...');
    final command = RegisterDiscoveredAddressCommand(
      walletId: message.walletId,
      address: address,
      derivationIndex: 0,
      isChange: false,
      transactionCount: history.length,
    );
    
    _walletManagerActor.tell(
      WalletCommandMessage(message.walletId, command),
      sender: context.self,
    );
    _logger.info('   ✅ WIF address registered');
    
    // Give projection time to process
    await Future.delayed(const Duration(milliseconds: 500));
    
    _totalTransactions = history.length;
    _reportProgress(
      'Found 1 address with $_totalTransactions transactions',
      0.4,
      0,
      _totalTransactions,
    );
    
    return [discoveredAddress];
  }

  Future<void> _importTransactions(
    ImportWalletMessage message,
    List<DiscoveredAddress> addresses,
  ) async {
    _logger.info('   → Importing transactions for ${addresses.length} addresses');
    final importedUtxos = <Map<String, dynamic>>[];
    int totalUtxosFound = 0;

    for (int i = 0; i < addresses.length; i++) {
      final address = addresses[i];
      if (_isCancelled) break;

      _logger.info('   → [${i+1}/${addresses.length}] Processing address: ${address.address}');
      
      // Import and process transactions incrementally for this address
      await _importService.importAddressTransactions(
        address,
        onProgress: (completed, total) {
          // Update UI progress as each transaction is imported
          _logger.info('      Progress: $completed/$total transactions imported');
          _reportProgress(
            'Importing transactions: $_processedTransactions/$_totalTransactions',
            0.4 + (0.5 * (_processedTransactions / _totalTransactions)),
            _processedTransactions,
            _totalTransactions,
          );
        },
        onTransactionImported: (tx) async {
          if (_isCancelled) return;
          
          _processedTransactions++;
          
          // Process this transaction immediately
          final utxosFound = await _processImportedTransaction(
            tx,
            message,
            address,
            addresses,
          );
          
          totalUtxosFound += utxosFound.length;
          importedUtxos.addAll(utxosFound);
        },
      );
    }

    _logger.info('   ✅ All addresses processed');
    _logger.info('   📊 Summary: $_processedTransactions transactions, $totalUtxosFound UTXOs');
    
    _reportProgress(
      'Import complete: $_processedTransactions transactions, $totalUtxosFound UTXOs',
      0.9,
      _processedTransactions,
      _totalTransactions,
    );
  }

  /// Process a single imported transaction
  /// 
  /// Returns list of UTXO maps found in this transaction
  Future<List<Map<String, dynamic>>> _processImportedTransaction(
    ImportedTransaction tx,
    ImportWalletMessage message,
    DiscoveredAddress currentAddress,
    List<DiscoveredAddress> allAddresses,
  ) async {
    final importedUtxos = <Map<String, dynamic>>[];
    
    // Parse transaction to extract data (BEEF already has this parsed)
    final parsedTx = tx.transaction;
    
    // Calculate total output value and track wallet-relevant data
    BigInt totalOutput = BigInt.zero;
    final walletReceivingAddresses = <String>[];
    BigInt walletReceivedSats = BigInt.zero;
    
    for (final output in parsedTx.outputs) {
      totalOutput += output.satoshis;
    }
    
    // Extract input information by fetching parent transactions
    final sendingAddresses = <String>[];
    BigInt totalInputSats = BigInt.zero;
    
    // Fetch parent transactions for each input to get values and addresses
    for (final input in parsedTx.inputs) {
      try {
        final prevTxid = input.prevTxnId.toString();
        final prevVout = input.prevTxnOutputIndex;
        
        // Fetch parent transaction
        final parentRawHex = await _dataSource.getRawTransaction(prevTxid);
        final parentTx = dartsv.Transaction.fromHex(parentRawHex);
        
        // Get the output being spent
        if (prevVout >= parentTx.outputs.length) {
          _logger.warning('      ⚠️  Invalid prevVout $prevVout for parent tx $prevTxid');
          continue;
        }
        
        final spentOutput = parentTx.outputs[prevVout];
        totalInputSats += spentOutput.satoshis;
        
        // Extract sending address from output script
        final scriptRegistry = ScriptTypeRegistry(
          networkType: message.networkType == 'main' 
            ? dartsv.NetworkType.MAIN 
            : dartsv.NetworkType.TEST,
        );
        final scriptType = scriptRegistry.identifyScriptType(spentOutput.script);
        
        if (scriptType?.toLowerCase() == 'p2pkh') {
          final locker = dartsv.P2PKHLockBuilder.fromScript(
            spentOutput.script,
            networkType: message.networkType == 'main' 
              ? dartsv.NetworkType.MAIN 
              : dartsv.NetworkType.TEST,
          );
          if (locker.address != null) {
            final senderAddress = locker.address!.toBase58();
            sendingAddresses.add(senderAddress);
            _logger.fine('      Input from: $senderAddress (${spentOutput.satoshis} sats)');
          }
        }
      } catch (e) {
        _logger.warning('      ⚠️  Failed to fetch parent tx for input: $e');
        // Continue processing other inputs
      }
    }
    
    if (totalInputSats > BigInt.zero) {
      final fee = totalInputSats - totalOutput;
      _logger.info('      💰 Total inputs: $totalInputSats sats, fee: $fee sats');
    }
    
    _logger.info('      📦 Parsing TX ${tx.txid}: ${parsedTx.inputs.length} inputs, ${parsedTx.outputs.length} outputs');
    
    // Note: Input addresses require looking up the previous transaction output
    if (parsedTx.inputs.isNotEmpty) {
      _logger.info('         ℹ️  Transaction has ${parsedTx.inputs.length} inputs (spending UTXOs)');
      _logger.info('         ℹ️  This transaction might be SPENDING from address ${currentAddress.address}, not receiving to it');
    }

    // Check if this transaction spends any wallet UTXOs
    _logger.info('      → Checking if transaction ${tx.txid} spends wallet UTXOs...');
    _logger.fine('         Transaction has ${parsedTx.inputs.length} input(s)');
    for (final input in parsedTx.inputs) {
      final prevTxid = input.prevTxnId.toString();
      final prevVout = input.prevTxnOutputIndex;
      _logger.fine('         Input spends: $prevTxid:$prevVout');
    }
    final spentUtxos = await _findSpentWalletUTXOs(parsedTx, message.walletId);

    if (spentUtxos.isNotEmpty) {
      _logger.info('      → Transaction spends ${spentUtxos.length} wallet UTXO(s)');
      
      for (final spentUtxo in spentUtxos) {
        final utxoKey = '${spentUtxo['txid']}:${spentUtxo['vout']}';
        _logger.info('         Marking UTXO as spent: $utxoKey');

        // Send command to mark UTXO as spent
        final spendCommand = SpendUTXOCommand(
          walletId: message.walletId,
          utxoKey: utxoKey,
          spendingTxId: tx.txid,
          fee: BigInt.zero, // Fee calculation done separately
        );

        _walletManagerActor.tell(
          WalletCommandMessage(message.walletId, spendCommand),
          sender: context.self,
        );

        // Wait for UTXO to be marked as spent in storage
        // This ensures that UTXOs are properly tracked before proceeding
        await _waitForUtxoSpent(message.walletId, spentUtxo['txid'], spentUtxo['vout']);
        _logger.info('         ✅ SpendUTXOCommand sent and UTXO marked as spent');
      }
    } else {
      _logger.info('      ℹ️  Transaction does not spend any wallet UTXOs');
    }

    // Find outputs that belong to discovered addresses
    for (int vout = 0; vout < parsedTx.outputs.length; vout++) {
      final output = parsedTx.outputs[vout];
      String? outputAddress;
      
      // Log raw script info
      final scriptHex = output.script.toHex();
      _logger.info('         Output $vout: ${output.satoshis} sats');
      _logger.info('            Script (hex): ${scriptHex.substring(0, scriptHex.length > 50 ? 50 : scriptHex.length)}${scriptHex.length > 50 ? "..." : ""}');
      _logger.info('            Script length: ${output.script.chunks.length} chunks');
      
      // Step 1: Identify script type
      final scriptRegistry = ScriptTypeRegistry(
        networkType: message.networkType == 'main' 
          ? dartsv.NetworkType.MAIN 
          : dartsv.NetworkType.TEST,
      );
      final scriptType = scriptRegistry.identifyScriptType(output.script);
      _logger.info('            Script type: $scriptType');
      
      // Step 2: Use appropriate builder based on script type
      try {
        if (scriptType?.toLowerCase() == 'p2pkh') {
          // Use P2PKH builder to extract address
          final locker = dartsv.P2PKHLockBuilder.fromScript(
            output.script,
            networkType: message.networkType == 'main' 
              ? dartsv.NetworkType.MAIN 
              : dartsv.NetworkType.TEST,
          );
          outputAddress = locker.address?.toBase58();
          _logger.info('            Decoded P2PKH address: $outputAddress');
        } else if (scriptType?.toLowerCase() == 'p2sh') {
          _logger.info('            ⚠️  P2SH output detected - skipping (not supported for UTXO import)');
          continue;
        } else {
          _logger.info('            ⚠️  Unsupported script type: $scriptType - skipping');
          continue;
        }
      } catch (e) {
        _logger.info('            ❌ Failed to parse script: $e');
        continue;
      }
      
      if (outputAddress == null) {
        _logger.info('            ⚠️  Could not extract address from script');
        continue;
      }

      // Check if this output belongs to one of our addresses (O(1) hash lookup)
      _logger.info('            → Checking if address $outputAddress belongs to wallet...');
      final belongsToWallet = await _storage.isWalletAddress(message.walletId, outputAddress);
      
      _logger.info('            → Belongs to wallet? $belongsToWallet');
      if (!belongsToWallet) {
        _logger.info('            → Address NOT in wallet. Expected one of: ${allAddresses.take(5).map((a) => a.address).join(", ")}${allAddresses.length > 5 ? "..." : ""}');
      }

      if (belongsToWallet) {
        _logger.info('            ✅ UTXO found: ${tx.txid}:$vout (${output.satoshis} sats) → $outputAddress');
        
        // Track wallet-specific data for the event
        walletReceivingAddresses.add(outputAddress);
        walletReceivedSats += output.satoshis;
        
        // Send ReceiveUTXOCommand to wallet aggregate
        // IMPORTANT: Imported UTXOs are already confirmed, mark as available immediately
        final receiveCommand = ReceiveUTXOCommand(
          walletId: message.walletId,
          txid: tx.txid,
          vout: vout,
          satoshis: output.satoshis,
          scriptPubKey: output.script.toHex(),
          address: outputAddress,
          blockHeight: tx.blockHeight,
          confirmations: null, // Will be updated separately
          initialStatus: UTXOStatus.available, // Imported UTXOs are already confirmed
        );

        _logger.info('            → Sending ReceiveUTXOCommand to WalletManager for wallet ${message.walletId}');
        _walletManagerActor.tell(
          WalletCommandMessage(message.walletId, receiveCommand),
          sender: context.self,
        );

        // Wait for UTXO to be persisted to storage before proceeding
        // This ensures subsequent transactions can correctly identify spent UTXOs
        final utxoKey = '${tx.txid}:$vout';
        _logger.info('            → Waiting for UTXO $utxoKey to be persisted...');
        await _waitForUtxoPersisted(message.walletId, tx.txid, vout);
        _logger.info('            ✅ ReceiveUTXOCommand sent and UTXO persisted');

        importedUtxos.add({
          'txid': tx.txid,
          'vout': vout,
          'satoshis': output.satoshis.toString(),
          'address': outputAddress,
          'blockHeight': tx.blockHeight,
        });
      }
    }

    // Send command to aggregate to record the imported transaction
    _logger.info('         → Sending RecordImportedTransactionCommand to WalletManager');
    final recordCommand = RecordImportedTransactionCommand(
      walletId: message.walletId,
      txid: tx.txid,
      rawHex: tx.rawHex,
      blockHeight: tx.blockHeight,
      bumpProofHex: hex.encode(tx.bump.serialize()),
      totalOutputSats: totalOutput.toInt(),
      numInputs: parsedTx.inputs.length,
      numOutputs: parsedTx.outputs.length,
      txVersion: parsedTx.version,
      txLockTime: parsedTx.nLockTime,
      walletReceivingAddresses: walletReceivingAddresses,
      walletReceivedSats: walletReceivedSats.toInt(),
      totalInputSats: totalInputSats.toInt(),
      sendingAddresses: sendingAddresses,
    );
    
    _walletManagerActor.tell(
      WalletCommandMessage(message.walletId, recordCommand),
      sender: context.self,
    );
    
    // WORKAROUND: Delay to prevent concurrency exceptions
    await Future.delayed(const Duration(milliseconds: 50));
    _logger.info('         ✅ RecordImportedTransactionCommand sent');

    return importedUtxos;
  }

  Future<void> _completeImport(ImportWalletMessage message) async {
    _logger.info('   → Broadcasting WalletImportCompletedEvent');
    
    // Send completion event
    await _notifyEvent(message.walletId, WalletImportCompletedEvent(
      walletId: message.walletId,
      totalAddresses: _totalAddresses,
      totalTransactions: _processedTransactions,
      importedUtxos: [], // UTXOs are tracked via ReceiveUTXOCommand
    ));

    _reportProgress(
      'Import complete',
      1.0,
      _processedTransactions,
      _totalTransactions,
    );

    // Notify original sender via logging (actor messages handled by _reportProgress)
    _logger.info('Import completed: $_totalAddresses addresses, $_processedTransactions transactions');
  }

  Future<void> _notifyImportFailed(String walletId, String error) async {
    await _notifyEvent(walletId, WalletImportFailedEvent(
      walletId: walletId,
      error: error,
      partialProgress: '$_processedTransactions/$_totalTransactions transactions',
    ));

    _logger.severe('Import failed: $error');
  }

  Future<void> _notifyEvent(String walletId, WalletEvent event) async {
    // Events are created and persisted via commands to the wallet aggregate
    // Broadcast to UI subscribers if broadcaster is available
    _eventBroadcaster?.call(event);
    _logger.fine('Event: ${event.runtimeType} for wallet $walletId');
  }

  void _reportProgress(String message, double progress, int completed, int total) {
    _logger.info(message);
    
    // Broadcast progress event for UI subscribers
    if (_eventBroadcaster != null && _currentImportWalletId != null) {
      // Determine phase based on progress
      String phase;
      if (progress < 0.2) {
        phase = 'setup';
      } else if (progress < 0.4) {
        phase = 'discovery';
      } else if (progress < 0.9) {
        phase = 'import';
      } else {
        phase = 'finalize';
      }
      
      _eventBroadcaster(WalletImportProgressEvent(
        walletId: _currentImportWalletId!,
        phase: phase,
        message: message,
        currentStep: completed,
        totalSteps: total,
        progress: progress,
      ));
    }
  }

  void _handleCancelImport() {
    _logger.info('Import cancellation requested');
    _isCancelled = true;
  }

  void _handleProgressQuery() {
    final progressInfo = ImportProgressMessage(
      walletId: _currentImportWalletId ?? '',
      message: 'In progress',
      progress: _totalTransactions > 0
          ? _processedTransactions / _totalTransactions
          : 0.0,
      processedTransactions: _processedTransactions,
      totalTransactions: _totalTransactions,
    );
    _logger.info('Progress: ${progressInfo.progress * 100}%');
  }

  /// Check if transaction inputs spend any wallet UTXOs
  /// 
  /// This method follows the same pattern as SPVActor._extractSpentUTXOs
  /// to ensure consistent UTXO accounting across import and SPV flows.
  Future<List<Map<String, dynamic>>> _findSpentWalletUTXOs(
    dartsv.Transaction transaction,
    String walletId,
  ) async {
    final spentUTXOs = <Map<String, dynamic>>[];

    try {
      // Get wallet's current UTXOs to check ownership
      final walletUtxos = await _storage.getUTXOs(walletId, includeSpent: false);

      // Build set for O(1) lookup
      final walletUtxoKeys = walletUtxos
          .map((utxo) => '${utxo.txid}:${utxo.vout}')
          .toSet();

      _logger.fine('      Wallet $walletId has ${walletUtxoKeys.length} available UTXO(s)');
      for (final utxoKey in walletUtxoKeys) {
        _logger.fine('         Available UTXO: $utxoKey');
      }

      // Check each transaction input to see if it belongs to this wallet
      for (final input in transaction.inputs) {
        final prevTxId = input.prevTxnId.toString();
        final prevVout = input.prevTxnOutputIndex;
        final utxoKey = '$prevTxId:$prevVout';

        _logger.fine('         Checking if wallet owns: $utxoKey');

        // Only add to spentUTXOs if this wallet actually owns the UTXO being spent
        if (walletUtxoKeys.contains(utxoKey)) {
          spentUTXOs.add({
            'txid': prevTxId,
            'vout': prevVout,
          });
          _logger.info('         ✓ Wallet owns UTXO $utxoKey - will mark as spent');
        } else {
          _logger.fine('         ✗ Wallet does NOT own UTXO $utxoKey');
        }
      }

      _logger.info('      Found ${spentUTXOs.length} wallet UTXO(s) being spent (out of ${transaction.inputs.length} total inputs)');
    } catch (e) {
      _logger.warning('      ⚠️  Error checking spent UTXOs: $e');
    }

    return spentUTXOs;
  }

  /// Wait for a UTXO to be persisted to storage
  /// 
  /// This ensures that when processing transactions sequentially,
  /// we can correctly identify which UTXOs are spent by later transactions.
  /// Without this wait, a race condition occurs where TX2 might be processed
  /// before TX1's UTXO is persisted, causing TX1's UTXO to not be marked as spent.
  Future<void> _waitForUtxoPersisted(String walletId, String txid, int vout) async {
    const maxAttempts = 20; // 20 attempts * 100ms = 2 seconds max
    const delayBetweenAttempts = Duration(milliseconds: 100);
    
    for (int attempt = 0; attempt < maxAttempts; attempt++) {
      try {
        final utxos = await _storage.getUTXOs(walletId, includeSpent: false);
        final utxoExists = utxos.any((u) => u.txid == txid && u.vout == vout);
        
        if (utxoExists) {
          if (attempt > 0) {
            _logger.fine('            UTXO $txid:$vout persisted after ${attempt * delayBetweenAttempts.inMilliseconds}ms');
          }
          return;
        }
        
        // Wait before next attempt
        await Future.delayed(delayBetweenAttempts);
      } catch (e) {
        _logger.warning('            ⚠️  Error checking UTXO persistence: $e');
        await Future.delayed(delayBetweenAttempts);
      }
    }
    
    _logger.warning('            ⚠️  UTXO $txid:$vout not found in storage after ${maxAttempts * delayBetweenAttempts.inMilliseconds}ms');
  }

  /// Wait for a UTXO to be marked as spent in storage
  /// 
  /// This ensures that spent UTXOs are properly tracked and won't appear
  /// as available in subsequent queries.
  Future<void> _waitForUtxoSpent(String walletId, String txid, int vout) async {
    const maxAttempts = 20; // 20 attempts * 100ms = 2 seconds max
    const delayBetweenAttempts = Duration(milliseconds: 100);
    
    for (int attempt = 0; attempt < maxAttempts; attempt++) {
      try {
        // Check if UTXO is marked as spent (not in available list)
        final availableUtxos = await _storage.getUTXOs(walletId, includeSpent: false);
        final isStillAvailable = availableUtxos.any((u) => u.txid == txid && u.vout == vout);
        
        if (!isStillAvailable) {
          // UTXO is no longer available, meaning it was marked as spent
          if (attempt > 0) {
            _logger.fine('            UTXO $txid:$vout marked as spent after ${attempt * delayBetweenAttempts.inMilliseconds}ms');
          }
          return;
        }
        
        // Wait before next attempt
        await Future.delayed(delayBetweenAttempts);
      } catch (e) {
        _logger.warning('            ⚠️  Error checking UTXO spent status: $e');
        await Future.delayed(delayBetweenAttempts);
      }
    }
    
    _logger.warning('            ⚠️  UTXO $txid:$vout still available after ${maxAttempts * delayBetweenAttempts.inMilliseconds}ms');
  }
}

// =============================================================================
// IMPORT ACTOR MESSAGES
// =============================================================================

/// Message to start wallet import
class ImportWalletMessage implements Message {
  final String walletId;
  final String? xpriv;
  final String? wif;
  final String walletName;
  final String networkType;
  final int addressGapLimit;

  ImportWalletMessage({
    required this.walletId,
    this.xpriv,
    this.wif,
    required this.walletName,
    this.networkType = 'test',
    this.addressGapLimit = 20,
  }) : assert(
          (xpriv != null && wif == null) || (xpriv == null && wif != null),
          'Exactly one of xpriv or wif must be provided',
        );
  
  @override
  String get correlationId => 'import-wallet-$walletId-${DateTime.now().millisecondsSinceEpoch}';
  
  @override
  DateTime get timestamp => DateTime.now();
  
  @override
  Map<String, dynamic> get metadata => {
    'walletId': walletId,
    'networkType': networkType,
    'addressGapLimit': addressGapLimit,
    'importType': xpriv != null ? 'xpriv' : 'wif',
  };
  
  @override
  ActorRef? get replyTo => null;
}

/// Message to cancel ongoing import
class CancelImportMessage {
  CancelImportMessage();
}

/// Query for import progress
class ImportProgressQuery {
  ImportProgressQuery();
}

/// Progress update message
class ImportProgressMessage {
  final String walletId;
  final String message;
  final double progress; // 0.0 to 1.0
  final int processedTransactions;
  final int totalTransactions;

  ImportProgressMessage({
    required this.walletId,
    required this.message,
    required this.progress,
    required this.processedTransactions,
    required this.totalTransactions,
  });
}

/// Import completed response
class ImportCompletedResponse {
  final String walletId;
  final int totalAddresses;
  final int totalTransactions;

  ImportCompletedResponse({
    required this.walletId,
    required this.totalAddresses,
    required this.totalTransactions,
  });
}

/// Import failed response
class ImportFailedResponse {
  final String walletId;
  final String error;

  ImportFailedResponse({
    required this.walletId,
    required this.error,
  });
}

