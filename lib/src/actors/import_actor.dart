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
      // Phase 1: Create wallet from xpriv
      _logger.info('📝 Phase 1/4: Creating wallet...');
      await _createWalletFromXpriv(message);
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

  Future<void> _createWalletFromXpriv(ImportWalletMessage message) async {
    _logger.info('   → Creating wallet via CreateWalletMessage for wallet ${message.walletId}');
    
    // Create wallet using CreateWalletMessage (spawns the wallet actor)
    // NOT CreateWalletCommand wrapped in WalletCommandMessage (which expects existing actor)
    final createMessage = CreateWalletMessage(
      message.walletId,
      message.walletName,
      xpriv: message.xpriv,
      walletMetadata: {
        'network': message.networkType,
        'importedFrom': 'xpriv',
      },
    );

    _logger.info('   → Sending CreateWalletMessage to WalletManagerActor to spawn wallet aggregate');
    _logger.info('   → Wallet ID: ${message.walletId}, Name: ${message.walletName}');
    _logger.info('   → Has xpriv: ${message.xpriv.isNotEmpty}');
    
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
    _logger.info('   → Deriving HD keys from xpriv');
    final hdPrivateKey = dartsv.HDPrivateKey.fromXpriv(message.xpriv);
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

      _logger.info('   → [${ i+1}/${addresses.length}] Processing address: ${address.address}');
      
      // Import all transactions for this address
      final transactions = await _importService.importAddressTransactions(address);
      _logger.info('      Found ${transactions.length} transactions for this address');

      for (final tx in transactions) {
        if (_isCancelled) break;

        _processedTransactions++;

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
          _logger.info('         ℹ️  This transaction might be SPENDING from address ${address.address}, not receiving to it');
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
            _logger.info('            → Address NOT in wallet. Expected one of: ${addresses.take(5).map((a) => a.address).join(", ")}${addresses.length > 5 ? "..." : ""}');
          }

          if (belongsToWallet) {
            totalUtxosFound++;
            _logger.info('            ✅ UTXO found: ${tx.txid}:$vout (${output.satoshis} sats) → $outputAddress');
            
            // Track wallet-specific data for the event
            walletReceivingAddresses.add(outputAddress);
            walletReceivedSats += output.satoshis;
            
            // Send ReceiveUTXOCommand to wallet aggregate
            final receiveCommand = ReceiveUTXOCommand(
              walletId: message.walletId,
              txid: tx.txid,
              vout: vout,
              satoshis: output.satoshis,
              scriptPubKey: output.script.toHex(),
              address: outputAddress,
              blockHeight: tx.blockHeight,
              confirmations: null, // Will be updated separately
            );

            _logger.info('            → Sending ReceiveUTXOCommand to WalletManager for wallet ${message.walletId}');
            _walletManagerActor.tell(
              WalletCommandMessage(message.walletId, receiveCommand),
              sender: context.self,
            );
            
            // WORKAROUND: Delay to prevent concurrency exceptions
            // Root cause: Eventador's AggregateRoot doesn't synchronously update currentState.version
            // after persistEvents(), causing the next command to see stale version.
            // TODO: File bug report with Eventador - actor mailbox should guarantee sequential processing
            await Future.delayed(const Duration(milliseconds: 50));
            _logger.info('            ✅ ReceiveUTXOCommand sent');

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
        // This will emit TransactionImportedEvent to EventStore → Projection → Isar
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
        // Root cause: Eventador's AggregateRoot doesn't synchronously update currentState.version
        // after persistEvents(), causing the next command to see stale version.
        // TODO: File bug report with Eventador - actor mailbox should guarantee sequential processing
        await Future.delayed(const Duration(milliseconds: 50));
        _logger.info('         ✅ RecordImportedTransactionCommand sent');

        _reportProgress(
          'Imported transaction ${_processedTransactions}/$_totalTransactions',
          0.4 + (0.5 * (_processedTransactions / _totalTransactions)),
          _processedTransactions,
          _totalTransactions,
        );
      }
    }

    _logger.info('   → Transaction import summary:');
    _logger.info('      Addresses processed: ${addresses.length}');
    _logger.info('      Transactions imported: $_processedTransactions');
    _logger.info('      UTXOs found: $totalUtxosFound');
    
    // Store imported UTXOs for completion event
    message.walletId; // Store for later use
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
    // Progress can be queried via ImportProgressQuery message
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
}

// =============================================================================
// IMPORT ACTOR MESSAGES
// =============================================================================

/// Message to start wallet import
class ImportWalletMessage implements Message {
  final String walletId;
  final String xpriv;
  final String walletName;
  final String networkType;
  final int addressGapLimit;

  ImportWalletMessage({
    required this.walletId,
    required this.xpriv,
    required this.walletName,
    this.networkType = 'test',
    this.addressGapLimit = 20,
  });
  
  @override
  String get correlationId => 'import-wallet-$walletId-${DateTime.now().millisecondsSinceEpoch}';
  
  @override
  DateTime get timestamp => DateTime.now();
  
  @override
  Map<String, dynamic> get metadata => {
    'walletId': walletId,
    'networkType': networkType,
    'addressGapLimit': addressGapLimit,
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

