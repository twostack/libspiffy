import 'dart:async';

import 'package:convert/convert.dart';
import 'package:dactor/dactor.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:eventador/eventador.dart' show AwaitEventApplied, AwaitFailed;
import 'package:logging/logging.dart';

import '../services/blockchain_data_source.dart';
import '../services/address_discovery_service.dart';
import '../services/transaction_import_service.dart';
import '../services/script_type_registry.dart';
import '../storage/read_model_storage.dart';
import '../models/address_chain.dart';
import '../models/blockchain_data_models.dart';
import '../models/bitcoin_utxo.dart'; // For UTXOStatus
import '../core/wallet_commands.dart';
import '../core/wallet_events.dart';
import '../core/wallet_output_ownership.dart';
import 'wallet_messages.dart';
import '../utils/network_name.dart';

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
///
/// The import itself runs as a background job outside [onMessage], so the
/// mailbox stays live: [ImportProgressQuery] is answered and
/// [CancelImportMessage] takes effect between steps of a running import.
/// Every wait is on an actual acknowledgement (an `ask` reply, the aggregate's
/// response, or the wallet projection applying the resulting event); there
/// are no fixed sleeps. Imports for different wallets queue up and run one
/// after another.
class ImportActor extends Actor {
  final Logger _logger = Logger('ImportActor');
  final BlockchainDataSource _dataSource;
  final AddressDiscoveryService _discoveryService;
  final TransactionImportService _importService;
  final ReadModelStorage _storage;
  final ActorRef _walletManagerActor;
  final ActorRef? _walletProjection;
  final void Function(WalletImportNotification)? _eventBroadcaster;

  /// Window for a single acknowledgement (aggregate reply or projection
  /// apply). `ask` timeouts are this plus [_askSlack] so dactor's own timeout
  /// never fires before the awaiter's (see the coordinator actors).
  final Duration _ackTimeout;
  static const Duration _askSlack = Duration(seconds: 2);

  // Track import state
  String? _currentImportWalletId;
  bool _isCancelled = false;
  Completer<void>? _cancelSignal;
  final List<ImportWalletMessage> _queuedImports = [];
  String _phase = 'idle';
  String _progressMessage = '';
  double _progress = 0.0;
  int _addressesFound = 0;
  int _totalAddresses = 0;
  int _totalTransactions = 0;
  int _processedTransactions = 0;

  /// Aggregate acknowledgements awaited when no wallet projection is wired.
  final Map<String, Completer<TransactionRecordedResponse>> _pendingRecordAcks = {};

  ImportActor({
    required BlockchainDataSource dataSource,
    required ReadModelStorage storage,
    required ActorRef walletManagerActor,
    ActorRef? walletProjection,
    void Function(WalletImportNotification)? eventBroadcaster,
    Duration ackTimeout = const Duration(seconds: 30),
  })  : _dataSource = dataSource,
        _discoveryService = AddressDiscoveryService(dataSource),
        _importService = TransactionImportService(
          dataSource: dataSource,
          // SPV-09: imported proofs are checked against the stored headers.
          headerAtHeight: storage.getBlockHeaderByHeight,
        ),
        _storage = storage,
        _walletManagerActor = walletManagerActor,
        _walletProjection = walletProjection,
        _eventBroadcaster = eventBroadcaster,
        _ackTimeout = ackTimeout;

  /// True while an import job is running.
  bool get isImporting => _currentImportWalletId != null;

  @override
  Future<void> onMessage(dynamic message) async {
    _logger.fine('📨 ImportActor received message: ${message.runtimeType}');

    try {
      if (message is ImportWalletMessage) {
        _enqueueImport(message);
      } else if (message is CancelImportMessage) {
        _handleCancelImport(message);
      } else if (message is ImportProgressQuery) {
        _handleProgressQuery();
      } else if (message is TransactionRecordedResponse) {
        if (message.success) {
          _logger.info('✅ Transaction recorded: ${message.txid}');
        } else {
          _logger.severe('❌ Transaction recording FAILED: ${message.txid} — ${message.error}');
        }
        final ack = _pendingRecordAcks.remove(message.txid);
        if (ack != null && !ack.isCompleted) ack.complete(message);
        _eventBroadcaster?.call(WalletImportTransactionConfirmedEvent(
          walletId: message.walletId,
          txid: message.txid,
          success: message.success,
          error: message.error,
        ));
      } else if (message is UTXOReceivedResponse) {
        if (message.success) {
          _logger.info('✅ UTXO received: ${message.txid}:${message.vout}');
        } else {
          _logger.severe('❌ UTXO receive FAILED: ${message.txid}:${message.vout} — ${message.error}');
        }
        _eventBroadcaster?.call(WalletImportUTXOConfirmedEvent(
          walletId: message.walletId,
          txid: message.txid,
          vout: message.vout,
          success: message.success,
          error: message.error,
        ));
      } else {
        _logger.warning('❓ Unknown message type: ${message.runtimeType}');
      }
    } catch (e, stackTrace) {
      _logger.severe('💥 Error handling message: $e', e, stackTrace);
    }
  }

  // ===========================================================================
  // JOB CONTROL
  // ===========================================================================

  void _enqueueImport(ImportWalletMessage message) {
    final walletId = message.walletId;
    final alreadyQueued = _queuedImports.any((m) => m.walletId == walletId);
    if (_currentImportWalletId == walletId || alreadyQueued) {
      _logger.warning('⚠️  Import already in progress for wallet $walletId, ignoring duplicate request');
      return;
    }
    if (_currentImportWalletId != null) {
      _logger.info('⏳ Import for $walletId queued behind $_currentImportWalletId');
      _queuedImports.add(message);
      return;
    }
    _startImport(message);
  }

  void _startImport(ImportWalletMessage message) {
    _currentImportWalletId = message.walletId;
    _isCancelled = false;
    _cancelSignal = Completer<void>();
    _phase = 'setup';
    _progressMessage = 'Starting';
    _progress = 0.0;
    _addressesFound = 0;
    _totalAddresses = 0;
    _totalTransactions = 0;
    _processedTransactions = 0;
    _logger.info('▶️  Starting import for wallet: ${message.walletId}, network: ${message.networkType}');
    // Deliberately not awaited: the job runs outside the message handler so
    // the mailbox keeps serving progress queries, cancellations and replies.
    unawaited(_runImport(message));
  }

  Future<void> _runImport(ImportWalletMessage message) async {
    final walletId = message.walletId;
    _logger.info('🚀 Starting wallet import for $walletId (name: "${message.walletName}")');
    _logger.info('   Network: ${message.networkType}, Gap Limit: ${message.addressGapLimit}');

    try {
      _logger.info('📝 Phase 1/4: Creating wallet...');
      await _createWallet(message);
      _throwIfCancelled();

      _logger.info('🔍 Phase 2/4: Discovering addresses...');
      final discoveredAddresses = await _discoverAddresses(message);
      _totalAddresses = discoveredAddresses.length;
      _logger.info('   ✅ Found $_totalAddresses used addresses');
      _throwIfCancelled();

      _logger.info('💰 Phase 3/4: Importing transactions for $_totalAddresses addresses...');
      await _importTransactions(message, discoveredAddresses);
      _logger.info('   ✅ Imported $_processedTransactions transactions');
      _throwIfCancelled();

      _logger.info('🏁 Phase 4/4: Completing import...');
      await _completeImport(message);
      _logger.info('✨ Wallet import completed: $_totalAddresses addresses, $_processedTransactions transactions');
    } on ImportCancelledException {
      _logger.info('❌ Import cancelled for wallet $walletId after $_processedTransactions/$_totalTransactions transactions');
      await _notifyImportFailed(walletId, 'Import cancelled', cancelled: true);
    } catch (e, stackTrace) {
      _logger.severe('💥 Wallet import failed: $e', e, stackTrace);
      await _notifyImportFailed(walletId, e.toString());
    } finally {
      _currentImportWalletId = null;
      _cancelSignal = null;
      _phase = 'idle';
      _pendingRecordAcks.clear();
      _logger.info('🔓 Import lock released for wallet $walletId');
      if (_queuedImports.isNotEmpty) {
        _startImport(_queuedImports.removeAt(0));
      }
    }
  }

  void _throwIfCancelled() {
    if (_isCancelled) throw const ImportCancelledException();
  }

  /// Await [future], but return early (by throwing [ImportCancelledException])
  /// as soon as the running import is cancelled.
  Future<T> _cancellable<T>(Future<T> future) async {
    final signal = _cancelSignal;
    if (signal == null) return future;
    final result = await Future.any<Object?>([
      future,
      signal.future.then((_) => const _CancelSentinel()),
    ]);
    if (result is _CancelSentinel || _isCancelled) {
      // The abandoned future must not surface as an unhandled error later.
      unawaited(future.then((_) {}, onError: (_) {}));
      throw const ImportCancelledException();
    }
    return result as T;
  }

  /// Register an awaiter on the wallet projection for [predicate]. Must be
  /// called BEFORE the command that produces the event is sent, otherwise a
  /// fast projection could apply the event before the awaiter is registered.
  Future<dynamic>? _awaitApplied(bool Function(dynamic event) predicate) {
    final projection = _walletProjection;
    if (projection == null) return null;
    return projection.ask<dynamic>(
      AwaitEventApplied(predicate, timeout: _ackTimeout),
      _ackTimeout + _askSlack,
    );
  }

  // ===========================================================================
  // PHASES
  // ===========================================================================

  Future<void> _createWallet(ImportWalletMessage message) async {
    final importType = message.xpriv != null ? 'xpriv' : 'wif';
    _logger.info('   → Creating wallet via CreateWalletMessage ($importType) for wallet ${message.walletId}');

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

    // Registered before the command is sent (see _awaitApplied). Once the
    // projection has applied WalletCreatedEvent the read model holds the
    // wallet and its root address, which _registerAddresses relies on.
    final applied = _awaitApplied(
        (e) => e is WalletCreatedEvent && e.walletId == message.walletId);

    // ask() replies through a temporary ref, independent of this mailbox.
    final walletCreatedMsg = await _cancellable(
      _walletManagerActor.ask<WalletCreatedMessage>(
        createMessage,
        _ackTimeout + _askSlack,
      ),
    );

    if (!walletCreatedMsg.success) {
      throw StateError('Wallet creation failed: ${walletCreatedMsg.error}');
    }

    _logger.info('   → Wallet aggregate confirmed spawned with root address: ${walletCreatedMsg.rootAddress}');

    if (applied != null) {
      final response = await _cancellable(applied);
      if (response is AwaitFailed) {
        throw StateError('Wallet ${message.walletId} was created but the wallet read model '
            'did not apply it (${response.reason})');
      }
      _logger.info('   → Wallet confirmed in the wallet read model');
    }

    await _notifyEvent(message.walletId, WalletImportStartedEvent(
      walletId: message.walletId,
      walletName: message.walletName,
      addressGapLimit: message.addressGapLimit,
    ));

    _reportProgress('Wallet created', 0.1, 0, 0, 0, 0);
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
    _logger.info('   → Xpriv depth: ${hdPrivateKey.nodeDepth} (BSV account level is m/44\'/236\'/0\', depth 3)');

    _logger.info('   → Starting address discovery (gap limit: ${message.addressGapLimit})');
    final discoveryResult = await _cancellable(_discoveryService.discoverAddresses(
      hdPublicKey: hdPublicKey,
      networkType: message.networkType,
      gapLimit: message.addressGapLimit,
      shouldStop: () => _isCancelled,
      onProgress: (scannedCount, usedCount) {
        if (!_isCancelled) {
          _reportProgress(
            'Scanning addresses: $usedCount found',
            0.1 + (0.3 * (scannedCount / (usedCount + message.addressGapLimit))),
            usedCount, // addressesFound
            usedCount, // totalAddresses (estimate during discovery)
            0, // transactionsProcessed
            0, // totalTransactions (not known yet)
          );
        }
      },
    ));
    _throwIfCancelled();

    _logger.info('   → Discovery complete: ${discoveryResult.usedAddresses.length} addresses, '
        '${discoveryResult.totalTransactions} transactions');
    for (final addr in discoveryResult.usedAddresses) {
      _logger.fine('      • ${addr.address} (index: ${addr.derivationIndex}, chain: ${addr.chain.name}, txs: ${addr.transactionCount})');
    }

    await _registerAddresses(message.walletId, discoveryResult.usedAddresses);

    _totalTransactions = discoveryResult.totalTransactions;
    _reportProgress(
      'Found ${discoveryResult.usedAddresses.length} addresses with $_totalTransactions transactions',
      0.4,
      discoveryResult.usedAddresses.length,
      discoveryResult.usedAddresses.length,
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
    final privateKey = dartsv.SVPrivateKey.fromWIF(message.wif!);
    final network = NetworkName.toDartsv(message.networkType);
    final address = dartsv.Address.fromPublicKey(privateKey.publicKey, network).toBase58();
    _logger.info('   → WIF address: $address (network: ${message.networkType})');

    _reportProgress('Checking address history...', 0.2, 0, 1, 0, 0);

    // Fetch transaction history for this single address
    // No limit - fetch all transactions (data source handles pagination)
    List<TransactionInfo> history;
    try {
      history = await _cancellable(_dataSource.getTransactionHistory(address));
      _logger.info('   → Found ${history.length} transactions for address');
    } on ImportCancelledException {
      rethrow;
    } catch (e) {
      _logger.severe('   ❌ Error fetching transaction history: $e');
      history = [];
    }

    final discoveredAddress = DiscoveredAddress(
      address: address,
      derivationIndex: 0, // WIF has no derivation
      chain: AddressChain.receive, // Not applicable for WIF
      transactionCount: history.length,
      txids: history.map((tx) => tx.txid).toList(),
    );

    await _registerAddresses(message.walletId, [discoveredAddress]);

    _totalTransactions = history.length;
    _reportProgress('Found 1 address with $_totalTransactions transactions', 0.4, 1, 1, 0, _totalTransactions);

    return [discoveredAddress];
  }

  /// Register discovered addresses through the CQRS command flow and wait
  /// until the wallet projection has applied the AddressDiscoveredEvent of the
  /// last address that is new to the wallet (events are applied in order, so
  /// the earlier ones are in by then). Addresses the read model already holds
  /// (the root address the aggregate registers on creation, for one) are
  /// idempotent no-ops in the aggregate and produce no event, so they are not
  /// waited on. Without a projection reference there is nothing to await;
  /// ownership checks use the in-memory discovered list anyway.
  Future<void> _registerAddresses(String walletId, List<DiscoveredAddress> addresses) async {
    if (addresses.isEmpty) return;
    _logger.info('   → Registering ${addresses.length} discovered address(es)...');

    Future<dynamic>? applied;
    if (_walletProjection != null) {
      final known = (await _cancellable(_storage.getWalletAddresses(walletId))).toSet();
      final fresh = addresses.where((a) => !known.contains(a.address)).toList();
      _logger.info('   → ${fresh.length} of ${addresses.length} address(es) are new to the wallet');
      if (fresh.isNotEmpty) {
        final last = fresh.last;
        applied = _awaitApplied((e) =>
            e is AddressDiscoveredEvent && e.walletId == walletId && e.address == last.address);
      }
    }

    for (final address in addresses) {
      _walletManagerActor.tell(
        WalletCommandMessage(walletId, RegisterDiscoveredAddressCommand(
          walletId: walletId,
          address: address.address,
          derivationIndex: address.derivationIndex,
          chain: address.chain,
          transactionCount: address.transactionCount,
        )),
        sender: context.self,
      );
    }

    if (applied == null) {
      if (_walletProjection == null) {
        _logger.warning('   ⚠️  No wallet projection wired; not waiting for address persistence');
      }
      return;
    }
    final response = await _cancellable(applied);
    if (response is AwaitFailed) {
      throw StateError('Address registration was not applied by the wallet read model '
          '(${response.reason}); ${addresses.length} address(es) sent');
    }
    _logger.info('   ✅ ${addresses.length} address(es) confirmed in the wallet read model');
  }

  /// Import transactions for all discovered addresses
  ///
  /// Uses a three-phase approach to ensure correct ordering:
  /// 1. Collect all transactions from all addresses
  /// 2. Sort by block height (oldest first) to ensure parent TXs are processed
  ///    before child TXs that spend their outputs
  /// 3. Process in sorted order
  Future<void> _importTransactions(
    ImportWalletMessage message,
    List<DiscoveredAddress> addresses,
  ) async {
    _logger.info('   → Importing transactions for ${addresses.length} addresses');

    // PHASE 1: Collect all transactions from all addresses
    _logger.info('   📥 Phase 1: Collecting all transactions...');
    final allTransactions = <ImportedTransaction>[];
    final addressMap = <String, DiscoveredAddress>{}; // txid -> address that found it

    for (int i = 0; i < addresses.length; i++) {
      final address = addresses[i];
      _throwIfCancelled();

      _logger.fine('   → [${i+1}/${addresses.length}] Fetching transactions for: ${address.address}');

      // Report progress during collection phase
      _reportProgress(
        'Collecting transactions from address ${i+1}/${addresses.length}',
        0.4 + (0.15 * (i / addresses.length)), // Progress from 0.4 to 0.55
        _totalAddresses, // addressesFound
        _totalAddresses, // totalAddresses
        0, // transactionsProcessed (not processing yet, just collecting)
        _totalTransactions, // totalTransactions (known from discovery)
      );

      // Import transactions but don't process yet - just collect them
      await _cancellable(_importService.importAddressTransactions(
        address,
        shouldStop: () => _isCancelled,
        onProgress: (completed, total) {
          _logger.fine('      Progress: $completed/$total transactions fetched');
        },
        onTransactionImported: (tx) async {
          if (_isCancelled) return;

          // Only add if not already in collection (same tx can appear for multiple addresses)
          if (!allTransactions.any((t) => t.txid == tx.txid)) {
            allTransactions.add(tx);
            addressMap[tx.txid] = address;
            _logger.fine('      📦 Collected: ${tx.txid} (block: ${tx.blockHeight})');
          } else {
            _logger.fine('      ⏭️ Skipping duplicate: ${tx.txid}');
          }
        },
      ));
    }

    _throwIfCancelled();

    if (allTransactions.isEmpty) {
      _logger.info('   ℹ️ No transactions found to import');
      _reportProgress(
        'Import complete: 0 transactions',
        0.9,
        _totalAddresses, // addressesFound
        _totalAddresses, // totalAddresses
        0, // transactionsProcessed
        0, // totalTransactions
      );
      return;
    }

    // Report progress after collection completes
    _reportProgress(
      'Collected ${allTransactions.length} transactions, preparing to process',
      0.55,
      _totalAddresses, // addressesFound
      _totalAddresses, // totalAddresses
      0, // transactionsProcessed
      allTransactions.length, // totalTransactions (now we know the exact count)
    );

    // PHASE 2: Sort by block height (ascending - oldest first)
    // This ensures parent transactions are processed before transactions that spend their outputs
    _logger.info('   🔄 Phase 2: Sorting ${allTransactions.length} transactions by block height...');
    allTransactions.sort((a, b) => a.blockHeight.compareTo(b.blockHeight));

    _logger.info('   ✅ Sorted: first block ${allTransactions.first.blockHeight}, '
        'last block ${allTransactions.last.blockHeight}');

    // PHASE 3: Process transactions in sorted order
    _logger.info('   ⚙️ Phase 3: Processing ${allTransactions.length} transactions in block order...');
    _totalTransactions = allTransactions.length;
    _processedTransactions = 0;

    final importedUtxos = <Map<String, dynamic>>[];
    int totalUtxosFound = 0;

    for (final tx in allTransactions) {
      _throwIfCancelled();

      _processedTransactions++;
      _reportProgress(
        'Processing transactions: $_processedTransactions/$_totalTransactions',
        0.55 + (0.35 * (_processedTransactions / _totalTransactions)), // Adjusted from 0.4-0.9 to 0.55-0.9
        _totalAddresses, // addressesFound
        _totalAddresses, // totalAddresses
        _processedTransactions, // transactionsProcessed
        _totalTransactions, // totalTransactions
      );

      final currentAddress = addressMap[tx.txid]!;

      final utxosFound = await _processImportedTransaction(
        tx,
        message,
        currentAddress,
        addresses,
      );

      totalUtxosFound += utxosFound.length;
      importedUtxos.addAll(utxosFound);
    }

    _logger.info('   ✅ All transactions processed');
    _logger.info('   📊 Summary: $_processedTransactions transactions, $totalUtxosFound UTXOs');

    _reportProgress(
      'Finalizing import: $_processedTransactions transactions, $totalUtxosFound UTXOs',
      0.9,
      _totalAddresses, // addressesFound
      _totalAddresses, // totalAddresses
      _processedTransactions, // transactionsProcessed
      _totalTransactions, // totalTransactions
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
    final walletId = message.walletId;

    // Register the acknowledgement we will wait on BEFORE any command for
    // this transaction is sent: the projection applying TransactionImportedEvent
    // (which follows the UTXO events in order), or, without a projection, the
    // aggregate's TransactionRecordedResponse delivered to this mailbox.
    final applied = _awaitApplied((e) =>
        e is TransactionImportedEvent && e.walletId == walletId && e.txid == tx.txid);
    Completer<TransactionRecordedResponse>? recordAck;
    if (applied == null) {
      recordAck = Completer<TransactionRecordedResponse>();
      _pendingRecordAcks[tx.txid] = recordAck;
    }

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

        // Fetch parent transaction - check database cache first
        dartsv.Transaction parentTx;
        final cachedTx = await _storage.getTransaction(prevTxid);
        if (cachedTx != null && cachedTx.rawHex.isNotEmpty) {
          parentTx = dartsv.Transaction.fromHex(cachedTx.rawHex);
          _logger.fine('      ✓ Cache hit for parent tx: $prevTxid');
        } else {
          final parentRawHex = await _dataSource.getRawTransaction(prevTxid);
          parentTx = dartsv.Transaction.fromHex(parentRawHex);
          _logger.fine('      ✗ Cache miss, fetched from API: $prevTxid');
        }

        // Get the output being spent
        if (prevVout >= parentTx.outputs.length) {
          _logger.warning('      ⚠️  Invalid prevVout $prevVout for parent tx $prevTxid');
          continue;
        }

        final spentOutput = parentTx.outputs[prevVout];
        totalInputSats += spentOutput.satoshis;

        // Extract sending address from output script
        final scriptRegistry = ScriptTypeRegistry(
          networkType: NetworkName.toDartsv(message.networkType),
        );
        final scriptType = scriptRegistry.identifyScriptType(spentOutput.script);

        if (scriptType?.toLowerCase() == 'p2pkh') {
          final locker = dartsv.P2PKHLockBuilder.fromScript(
            spentOutput.script,
            networkType: NetworkName.toDartsv(message.networkType),
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

      // Send all spend commands in batch
      for (final spentUtxo in spentUtxos) {
        final utxoKey = '${spentUtxo['txid']}:${spentUtxo['vout']}';
        _logger.info('         Marking UTXO as spent: $utxoKey');

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
      }
      _logger.info('         ✅ ${spentUtxos.length} SpendUTXOCommand(s) sent');
    } else {
      _logger.info('      ℹ️  Transaction does not spend any wallet UTXOs');
    }

    // Find outputs that belong to discovered addresses
    for (int vout = 0; vout < parsedTx.outputs.length; vout++) {
      final output = parsedTx.outputs[vout];
      String? outputAddress;

      // Log raw script info
      final scriptHex = output.script.toHex();
      _logger.fine('         Output $vout: ${output.satoshis} sats');
      _logger.fine('            Script (hex): ${scriptHex.substring(0, scriptHex.length > 50 ? 50 : scriptHex.length)}${scriptHex.length > 50 ? "..." : ""}');
      _logger.fine('            Script length: ${output.script.chunks.length} chunks');

      // Step 1: Identify script type
      final scriptRegistry = ScriptTypeRegistry(
        networkType: NetworkName.toDartsv(message.networkType),
      );
      final scriptType = scriptRegistry.identifyScriptType(output.script);
      _logger.fine('            Script type: $scriptType');

      // Step 2: Use appropriate builder based on script type
      bool belongsToWallet = false;

      try {
        if (scriptType?.toLowerCase() == 'p2pkh') {
          // Use P2PKH builder to extract address
          final locker = dartsv.P2PKHLockBuilder.fromScript(
            output.script,
            networkType: NetworkName.toDartsv(message.networkType),
          );
          outputAddress = locker.address?.toBase58();
          _logger.fine('            Decoded P2PKH address: $outputAddress');

          if (outputAddress != null) {
            // Check against in-memory discovered addresses (not Isar)
            // to avoid race with projection persistence.
            belongsToWallet = allAddresses.any((a) => a.address == outputAddress);
          }
        } else if (scriptType?.toLowerCase() == 'p2ms') {
          // A bare multisig output is the wallet's only when the wallet holds
          // as many of its keys as it requires; a payment channel's 2-of-2
          // output needs the other party too (bead libspiffy-viy).
          outputAddress = BareMultisigScript.parse(output.script)?.spendableAloneBy(
            (address) => allAddresses.any((a) => a.address == address),
            NetworkName.toDartsv(message.networkType),
          );
          belongsToWallet = outputAddress != null;
          if (!belongsToWallet) {
            _logger.info('            ℹ️  Multisig output not spendable by the wallet alone');
          }
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

      if (outputAddress == null && belongsToWallet) {
        _logger.warning('            ⚠️  Wallet owns output but could not determine address');
        continue;
      }

      if (outputAddress != null && !belongsToWallet) {
        _logger.fine('            → Address $outputAddress NOT in wallet');
      }

      if (belongsToWallet && outputAddress != null) {
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

    // Wait for the acknowledgement registered above. The aggregate processes
    // its mailbox in order, so once the record command is acknowledged every
    // spend/receive command sent before it has been handled too.
    final totalUtxoCommands = spentUtxos.length + importedUtxos.length;
    if (applied != null) {
      final response = await _cancellable(applied);
      if (response is AwaitFailed) {
        throw StateError('Transaction ${tx.txid} was not applied by the wallet read model '
            '(${response.reason})');
      }
    } else {
      try {
        final response = await _cancellable(recordAck!.future.timeout(
          _ackTimeout,
          onTimeout: () => throw TimeoutException(
              'No TransactionRecordedResponse for ${tx.txid} within $_ackTimeout'),
        ));
        if (!response.success) {
          throw StateError('Recording transaction ${tx.txid} failed: ${response.error}');
        }
      } finally {
        _pendingRecordAcks.remove(tx.txid);
      }
    }
    _logger.info('         ✅ Transaction ${tx.txid} and $totalUtxoCommands UTXO command(s) acknowledged');

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
      _totalAddresses, // addressesFound
      _totalAddresses, // totalAddresses
      _processedTransactions, // transactionsProcessed
      _totalTransactions, // totalTransactions
    );

    // Notify original sender via logging (actor messages handled by _reportProgress)
    _logger.info('Import completed: $_totalAddresses addresses, $_processedTransactions transactions');
  }

  Future<void> _notifyImportFailed(String walletId, String error, {bool cancelled = false}) async {
    await _notifyEvent(walletId, WalletImportFailedEvent(
      walletId: walletId,
      error: error,
      partialProgress: '$_processedTransactions/$_totalTransactions transactions',
      metadata: {'cancelled': cancelled},
    ));

    if (cancelled) {
      _logger.info('Import cancelled: $error');
    } else {
      _logger.severe('Import failed: $error');
    }
  }

  Future<void> _notifyEvent(String walletId, WalletImportNotification event) async {
    // Events are created and persisted via commands to the wallet aggregate
    // Broadcast to UI subscribers if broadcaster is available
    _eventBroadcaster?.call(event);
    _logger.fine('Event: ${event.runtimeType} for wallet $walletId');
  }

  void _reportProgress(
    String message,
    double progress,
    int addressesFound,
    int totalAddresses,
    int transactionsProcessed,
    int totalTransactions,
  ) {
    _logger.info(message);

    // Determine phase based on progress
    if (progress < 0.2) {
      _phase = 'setup';
    } else if (progress < 0.4) {
      _phase = 'discovery';
    } else if (progress < 0.9) {
      _phase = 'import';
    } else {
      _phase = 'finalize';
    }
    _progressMessage = message;
    _progress = progress;
    _addressesFound = addressesFound;
    _totalAddresses = totalAddresses;
    _processedTransactions = transactionsProcessed;
    _totalTransactions = totalTransactions;

    // Broadcast progress event for UI subscribers
    final walletId = _currentImportWalletId;
    if (_eventBroadcaster != null && walletId != null) {
      _eventBroadcaster(WalletImportProgressEvent(
        walletId: walletId,
        phase: _phase,
        message: message,
        progress: progress,
        addressesFound: addressesFound,
        totalAddresses: totalAddresses,
        transactionsProcessed: transactionsProcessed,
        totalTransactions: totalTransactions,
      ));
    }
  }

  void _handleCancelImport(CancelImportMessage message) {
    final target = message.walletId;
    if (target != null && target != _currentImportWalletId) {
      final before = _queuedImports.length;
      _queuedImports.removeWhere((m) => m.walletId == target);
      final dequeued = before != _queuedImports.length;
      _logger.info(dequeued
          ? '❌ Queued import for $target removed'
          : '❌ Cancel requested for $target but no such import is running or queued');
      context.sender?.tell(ImportCancelResponse(walletId: target, accepted: dequeued));
      if (dequeued) {
        _eventBroadcaster?.call(WalletImportFailedEvent(
          walletId: target,
          error: 'Import cancelled',
          partialProgress: 'not started',
          metadata: const {'cancelled': true},
        ));
      }
      return;
    }
    final running = _currentImportWalletId;
    if (running == null) {
      _logger.info('❌ Cancel requested but no import is running');
      context.sender?.tell(ImportCancelResponse(walletId: target, accepted: false));
      return;
    }
    _logger.info('❌ Import cancellation requested for $running');
    _isCancelled = true;
    final signal = _cancelSignal;
    if (signal != null && !signal.isCompleted) signal.complete();
    context.sender?.tell(ImportCancelResponse(walletId: running, accepted: true));
  }

  void _handleProgressQuery() {
    final progressInfo = ImportProgressMessage(
      walletId: _currentImportWalletId ?? '',
      message: _currentImportWalletId == null ? 'Idle' : _progressMessage,
      progress: _progress,
      processedTransactions: _processedTransactions,
      totalTransactions: _totalTransactions,
      phase: _phase,
      addressesFound: _addressesFound,
      totalAddresses: _totalAddresses,
      isRunning: _currentImportWalletId != null,
      queuedWalletIds: _queuedImports.map((m) => m.walletId).toList(),
    );
    _logger.info('Progress: ${(progressInfo.progress * 100).toStringAsFixed(1)}%');
    context.sender?.tell(progressInfo);
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
          _logger.fine('         ✓ Wallet owns UTXO $utxoKey - will mark as spent');
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

/// Thrown inside the import job when a [CancelImportMessage] arrives.
class ImportCancelledException implements Exception {
  const ImportCancelledException();

  @override
  String toString() => 'ImportCancelledException: import cancelled';
}

class _CancelSentinel {
  const _CancelSentinel();
}

/// Message to cancel an ongoing (or queued) import.
///
/// Without [walletId] the running import is cancelled. Reply (when sent with a
/// sender / via `ask`): [ImportCancelResponse].
class CancelImportMessage implements Message {
  final String? walletId;

  CancelImportMessage({this.walletId});

  @override
  String get correlationId => 'cancel-import-${walletId ?? 'current'}-${DateTime.now().microsecondsSinceEpoch}';
  @override
  DateTime get timestamp => DateTime.now();
  @override
  Map<String, dynamic> get metadata => {'walletId': walletId};
  @override
  ActorRef? get replyTo => null;
}

/// Reply to [CancelImportMessage].
class ImportCancelResponse extends ActorResponse {
  final String? walletId;

  /// True when an import was running/queued and has been told to stop.
  /// Also reported as [success] (bead libspiffy-97zj).
  final bool accepted;

  @override
  final String? error;

  @override
  bool get success => accepted;

  ImportCancelResponse(
      {required this.walletId, required this.accepted, this.error});
}

/// Query for import progress. Reply: [ImportProgressMessage].
class ImportProgressQuery implements Message {
  ImportProgressQuery();

  @override
  String get correlationId => 'import-progress-${DateTime.now().microsecondsSinceEpoch}';
  @override
  DateTime get timestamp => DateTime.now();
  @override
  Map<String, dynamic> get metadata => const {};
  @override
  ActorRef? get replyTo => null;
}

/// Progress update message (reply to [ImportProgressQuery]).
class ImportProgressMessage extends ActorResponse {
  final String walletId;
  final String message;
  final double progress; // 0.0 to 1.0
  final int processedTransactions;
  final int totalTransactions;
  final String phase;
  final int addressesFound;
  final int totalAddresses;
  final bool isRunning;
  final List<String> queuedWalletIds;

  /// Whether progress could be reported. [isRunning] says whether an import
  /// is under way; [success] says whether we could look (bead
  /// libspiffy-97zj).
  @override
  final bool success;

  @override
  final String? error;

  ImportProgressMessage({
    required this.walletId,
    required this.message,
    required this.progress,
    required this.processedTransactions,
    required this.totalTransactions,
    this.phase = 'idle',
    this.addressesFound = 0,
    this.totalAddresses = 0,
    this.isRunning = false,
    this.queuedWalletIds = const [],
    this.success = true,
    this.error,
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

