import 'dart:async';
import 'package:dactor/dactor.dart';
import 'package:eventador/eventador.dart';
import 'package:logging/logging.dart';

import '../core/bitcoin_wallet_aggregate.dart';
import '../core/wallet_commands.dart';
import '../core/wallet_events.dart' show BeefAncestor;
import '../models/bitcoin_utxo.dart' show UTXOStatus;
import '../services/crypto_service.dart';
import '../storage/secure_storage.dart';
import 'wallet_messages.dart';
import 'invoice_messages.dart';
import 'libspiffy_actor_system.dart';

/// Central coordinator that manages multiple wallet aggregates and routes commands
class WalletManagerActor extends Actor {
  final _log = Logger('WalletManagerActor');
  final EventStore _eventStore;
  final CryptoService _cryptoService;
  final SecureStorage _secureStorage;
  final Map<String, ActorRef> _walletActors = {};
  
  // Track pending wallet creation requests to route responses back to original callers
  final Map<String, ActorRef?> _pendingWalletCreations = {};
  
  // Track wallets that are currently being loaded to prevent duplicate load attempts
  final Set<String> _loadingWallets = {};
  
  // Queue of commands waiting for a wallet to finish loading
  // Key: walletId, Value: list of (command, sender) pairs
  final Map<String, List<_PendingCommand>> _pendingCommands = {};
  
  // Invoice manager reference for invoice-based payments
  ActorRef? _invoiceManager;

  // ARC actor reference (set via SetArcActorMessage). Nothing is registered
  // with it any more: ARC status tracking is storage-backed (A-L4).
  // ignore: unused_field
  ActorRef? _arcActor;
  
  // Benford coordinator for privacy-focused UTXO splitting
  ActorRef? _benfordCoordinator;
  
  // SPV actors are coordinated at the LibSpiffyActorSystem level
  // and accessed via message passing rather than direct references
  
  // Timer for automated UTXO reservation cleanup
  Timer? _reservationCleanupTimer;

  /// Idle eviction (A-M10): a loaded aggregate that has not been routed a
  /// command for [_aggregateIdleTimeout] is stopped; the next command for
  /// that wallet recovers it from the journal. Null disables eviction.
  final Duration? _aggregateIdleTimeout;
  final Duration _idleCheckInterval;
  Timer? _idleCheckTimer;

  /// Last time each loaded aggregate was created, loaded or routed a command.
  final Map<String, DateTime> _lastUsed = {};

  WalletManagerActor({
    required EventStore eventStore,
    required CryptoService cryptoService,
    required SecureStorage secureStorage,
    Duration? aggregateIdleTimeout = const Duration(minutes: 30),
    Duration idleCheckInterval = const Duration(minutes: 1),
  })  : _eventStore = eventStore,
        _cryptoService = cryptoService,
        _secureStorage = secureStorage,
        _aggregateIdleTimeout = aggregateIdleTimeout,
        _idleCheckInterval = idleCheckInterval;

  @override
  void preStart() {
    _startReservationCleanupTimer();
    if (_aggregateIdleTimeout != null) {
      // The sweep runs in the mailbox, serialized with command routing, so
      // an aggregate cannot be stopped between being looked up and being
      // told a command.
      final self = context.self;
      _idleCheckTimer = Timer.periodic(_idleCheckInterval, (_) {
        self.tell(LocalMessage(payload: const _EvictIdleAggregates()));
      });
    }
  }

  void _touch(String walletId) {
    _lastUsed[walletId] = DateTime.now();
  }

  /// The loaded aggregate for [walletId], or null when none is loaded.
  ///
  /// An aggregate stops itself when a journal write fails (a rejected command
  /// leaves it running, libspiffy-201); a cached ref that is no longer alive
  /// is forgotten here so the caller loads a replacement from the journal
  /// instead of telling a dead actor (whose messages go to dead letters).
  ActorRef? _loadedWallet(String walletId) {
    final ref = _walletActors[walletId];
    if (ref == null || ref.isAlive) return ref;
    _walletActors.remove(walletId);
    _lastUsed.remove(walletId);
    return null;
  }

  /// Stops aggregates idle for longer than [_aggregateIdleTimeout].
  Future<void> _evictIdleAggregates() async {
    final idleTimeout = _aggregateIdleTimeout;
    if (idleTimeout == null) return;
    final cutoff = DateTime.now().subtract(idleTimeout);
    final idle = [
      for (final walletId in _walletActors.keys)
        if (!_loadingWallets.contains(walletId) &&
            !_pendingWalletCreations.containsKey(walletId) &&
            !_pendingCommands.containsKey(walletId) &&
            (_lastUsed[walletId] ?? DateTime.fromMillisecondsSinceEpoch(0))
                .isBefore(cutoff))
          walletId,
    ];
    for (final walletId in idle) {
      final ref = _walletActors.remove(walletId);
      _lastUsed.remove(walletId);
      if (ref == null) continue;
      try {
        await context.system.stop(ref);
        _log.fine('Evicted idle wallet aggregate $walletId');
      } catch (e, stackTrace) {
        _log.warning('Failed to stop idle wallet aggregate $walletId: $e',
            e, stackTrace);
      }
    }
  }

  /// Start periodic timer to clean up expired UTXO reservations
  /// Runs every 5 minutes to free up UTXOs whose reservations have expired
  void _startReservationCleanupTimer() {
    _reservationCleanupTimer = Timer.periodic(
      const Duration(minutes: 5),
      (_) => _cleanupExpiredReservations(),
    );
  }

  /// Clean up expired UTXO reservations across all active wallets
  Future<void> _cleanupExpiredReservations() async {
    
    int walletsProcessed = 0;
    for (final entry in _walletActors.entries) {
      final walletId = entry.key;
      final walletRef = entry.value;
      
      try {
        // Send cleanup command to each wallet
        final cleanupCommand = CleanupExpiredReservationsCommand(
          walletId: walletId,
          cutoffTime: DateTime.now(),
        );
        
        walletRef.tell(WalletCommandMessage(walletId, cleanupCommand));
        walletsProcessed++;
      } catch (e, stackTrace) {
        _log.warning(
            'Failed to cleanup expired reservations for wallet $walletId: $e',
            e, stackTrace);
      }
    }

    if (walletsProcessed > 0) {
    }
  }

  @override
  Future<void> onMessage(dynamic message) async {
    if (message is _EvictIdleAggregates) {
      await _evictIdleAggregates();
      return;
    }
    try {
      switch (message.runtimeType) {
        case CreateWalletMessage:
          await _handleCreateWallet(message as CreateWalletMessage);
          break;
          
        case WalletCommandMessage:
          await _handleWalletCommand(message as WalletCommandMessage);
          break;
          
        case ListWalletsMessage:
          await _handleListWallets(message as ListWalletsMessage);
          break;

        case SPVValidationResult:
          await _handleSPVValidationResult(message as SPVValidationResult);
          break;

        case WalletOwnershipQuery:
          await _handleWalletOwnershipQuery(message as WalletOwnershipQuery);
          break;

        case WalletCreatedResponse:
          await _handleWalletCreatedResponse(message as WalletCreatedResponse);
          break;
        
        case CreateInvoiceMessage:
          await _handleCreateInvoice(message as CreateInvoiceMessage);
          break;
          
        case CheckInvoiceMessage:
        case CancelInvoiceMessage:
        case ListInvoicesMessage:
          // Forward invoice queries directly to InvoiceManager
          _invoiceManager?.tell(message, sender: context.sender);
          break;
        
        case SetInvoiceManagerMessage:
          // Internal message to set invoice manager reference
          _invoiceManager = (message as SetInvoiceManagerMessage).invoiceManager;
          break;
          
        case SetArcActorMessage:
          // Internal message to set ARC actor reference
          _arcActor = (message as SetArcActorMessage).arcActor;
          break;
          
        case SetBenfordCoordinatorMessage:
          // Internal message to set Benford coordinator reference
          _benfordCoordinator = (message as SetBenfordCoordinatorMessage).benfordCoordinator;
          break;
          
        default:
      }
    } catch (e, stackTrace) {
      _log.warning('Failed to handle ${message.runtimeType}: $e', e, stackTrace);
      if (context.sender != null) {
        context.sender!.tell(LocalMessage(
          payload: {'error': e.toString(), 'type': 'wallet_manager_error'},
        ));
      }
    }
  }

  /// Handle wallet creation requests
  Future<void> _handleCreateWallet(CreateWalletMessage msg) async {
    try {
      
      // Check if wallet already exists: being created, or present in the
      // journal (loaded or not). A loaded aggregate with no journal is left
      // over from a creation it rejected and is reused below; it used to
      // make every retry answer "Wallet already exists".
      final loaded = _loadedWallet(msg.walletId);
      if (_pendingWalletCreations.containsKey(msg.walletId) ||
          await _eventStore.getHighestSequenceNumber(
                  'BitcoinWallet_${msg.walletId}') >
              0) {
        // Wrapped like the success path: dactor's ask() reply channel only
        // accepts LocalMessage, so a bare reply surfaced as a StateError.
        context.sender?.tell(LocalMessage(payload: WalletCreatedMessage(
          msg.walletId,
          '',
          false,
          error: 'Wallet already exists',
        )));
        return;
      }

      // Spawn wallet aggregate as actor (AggregateRoot extends Actor)
      final walletActor = loaded ?? await context.system.spawn(
        'wallet-${msg.walletId}',
        () => BitcoinWalletAggregate(
          aggregateId: msg.walletId,
          aggregateType: 'BitcoinWallet',
          eventStore: _eventStore,
          cryptoService: _cryptoService,
          secureStorage: _secureStorage,
        ),
      );

      // Store reference
      _walletActors[msg.walletId] = walletActor;
      _touch(msg.walletId);

      // Track the original sender so we can route the WalletCreatedResponse back to them
      _pendingWalletCreations[msg.walletId] = context.sender;

      // spawn() returns once recovery has completed (dactor 1.3 awaits
      // preStart and eventador 3.0 recovers inside it), so the command can
      // be sent immediately.

      // Send create wallet command to the aggregate
      // The aggregate will respond with WalletCreatedResponse via onCommandProcessed hook
      final createCommand = CreateWalletCommand(
        walletId: msg.walletId,
        walletName: msg.name,
        mnemonic: msg.mnemonic,
        wif: msg.wif,
        xpriv: msg.xpriv,
        xpub: msg.xpub,
        walletMetadata: msg.walletMetadata,
      );

      // Send command directly - AggregateRoot handles Command objects directly
      walletActor.tell(createCommand, sender: context.self);


    } catch (e, stackTrace) {
      _log.warning('Failed to create wallet ${msg.walletId}: $e', e, stackTrace);
      context.sender?.tell(LocalMessage(payload: WalletCreatedMessage(
        msg.walletId,
        '',
        false,
        error: e.toString(),
      )));
      _pendingWalletCreations.remove(msg.walletId);
    }
  }

  /// Handle wallet creation response from BitcoinWalletAggregate
  /// This receives the actual root address from the WalletCreatedEvent
  Future<void> _handleWalletCreatedResponse(WalletCreatedResponse response) async {
    
    // Get the original sender who requested the wallet creation
    final originalSender = _pendingWalletCreations.remove(response.walletId);
    
    if (originalSender != null) {
      // Forward the response with real root address to the original caller
      final message = WalletCreatedMessage(
        response.walletId,
        response.rootAddress,
        response.success,
        error: response.error,
      );
      
      // Wrap in LocalMessage for ask() pattern compatibility:
      // _TemporaryActorRef.tell() requires LocalMessage wrapping.
      originalSender.tell(LocalMessage(payload: message));

    } else {
    }
  }

  /// Route commands to specific wallet aggregates
  Future<void> _handleWalletCommand(WalletCommandMessage msg) async {
    
    // Handle PreloadWalletCommand - just loads the wallet without forwarding to aggregate
    if (msg.command is PreloadWalletCommand) {
      await _handlePreloadWallet(msg.walletId);
      return;
    }
    
    // Route Benford split commands directly to BenfordCoordinatorActor
    // The coordinator will handle orchestration (building, signing, broadcasting)
    if (msg.command is SplitUTXOsToBenfordCommand) {
      if (_benfordCoordinator != null) {
        _benfordCoordinator!.tell(msg.command, sender: context.sender);
        return; // Don't send to aggregate
      } else {
        context.sender?.tell(LocalMessage(
          payload: {'error': 'Benford coordinator not available'},
        ));
        return;
      }
    }
    
    try {
      var walletActor = _loadedWallet(msg.walletId);
      
      // Check if wallet is already loaded
      if (walletActor != null) {
        // Forward command directly
        _touch(msg.walletId);
        walletActor.tell(msg.command, sender: context.sender);
        return;
      }
      
      // Check if wallet is currently being loaded (race condition prevention)
      if (_loadingWallets.contains(msg.walletId)) {
        _pendingCommands.putIfAbsent(msg.walletId, () => []);
        _pendingCommands[msg.walletId]!.add(_PendingCommand(msg.command, context.sender));
        return;
      }
      
      // Start loading the wallet
      _loadingWallets.add(msg.walletId);
      
      // Queue the current command to be processed after loading
      _pendingCommands.putIfAbsent(msg.walletId, () => []);
      _pendingCommands[msg.walletId]!.add(_PendingCommand(msg.command, context.sender));
      
      // Load wallet asynchronously
      walletActor = await _loadWalletFromEventStore(msg.walletId);
      
      // Remove from loading set
      _loadingWallets.remove(msg.walletId);
      
      if (walletActor != null) {
        _walletActors[msg.walletId] = walletActor;
        _touch(msg.walletId);

        // Process all queued commands for this wallet
        final queuedCommands = _pendingCommands.remove(msg.walletId) ?? [];
        
        for (final pending in queuedCommands) {
          walletActor.tell(pending.command, sender: pending.sender);
        }
        
      } else {
        
        // Notify all waiting senders that wallet was not found
        final queuedCommands = _pendingCommands.remove(msg.walletId) ?? [];
        for (final pending in queuedCommands) {
          pending.sender?.tell(LocalMessage(
            payload: {'error': 'Wallet not found', 'walletId': msg.walletId},
          ));
        }
      }

    } catch (e, stackTrace) {
      _log.warning('Failed to route command for wallet ${msg.walletId}: $e',
          e, stackTrace);

      // Clean up loading state on error
      _loadingWallets.remove(msg.walletId);
      
      // Notify all waiting senders of the error
      final queuedCommands = _pendingCommands.remove(msg.walletId) ?? [];
      for (final pending in queuedCommands) {
        pending.sender?.tell(LocalMessage(
          payload: {'error': e.toString(), 'walletId': msg.walletId},
        ));
      }
    }
  }

  /// Handle requests for wallet list
  Future<void> _handleListWallets(ListWalletsMessage msg) async {
    final walletIds = _walletActors.keys.toList();
    context.sender?.tell(WalletListMessage(walletIds));
  }

  /// Handle wallet preloading - loads the wallet aggregate without forwarding any command
  /// 
  /// This is used during system startup to ensure wallet aggregates are ready
  /// before real commands arrive, eliminating race conditions.
  Future<void> _handlePreloadWallet(String walletId) async {
    // Already loaded?
    if (_loadedWallet(walletId) != null) {
      return;
    }
    
    // Already being loaded?
    if (_loadingWallets.contains(walletId)) {
      return;
    }
    
    // Load the wallet
    _loadingWallets.add(walletId);
    
    try {
      final walletActor = await _loadWalletFromEventStore(walletId);
      
      _loadingWallets.remove(walletId);
      
      if (walletActor != null) {
        _walletActors[walletId] = walletActor;
        _touch(walletId);
      } else {
      }
    } catch (e, stackTrace) {
      _log.warning('Failed to preload wallet $walletId: $e', e, stackTrace);
      _loadingWallets.remove(walletId);
    }
  }

  /// Hands a [WalletOwnershipQuery] to the wallet's aggregate, which answers
  /// the asker from its event-sourced state (bead libspiffy-29t). A wallet
  /// with no journal is answered here as not found.
  Future<void> _handleWalletOwnershipQuery(WalletOwnershipQuery query) async {
    // ignore: invalid_use_of_internal_member
    final asker = context.sender;
    final walletActor = await _getOrLoadWallet(query.walletId);
    if (walletActor == null) {
      _log.warning('Ownership query for unknown wallet ${query.walletId}');
      asker?.tell(WalletOwnershipResponse(
        walletId: query.walletId,
        walletFound: false,
        error: 'Wallet ${query.walletId} not found',
      ));
      return;
    }
    walletActor.tell(query, sender: asker);
  }

  /// Handle SPV validation results from SPVActor (NEW for correct SPV)
  Future<void> _handleSPVValidationResult(SPVValidationResult result) async {
    
    try {
      if (!result.isValid) {
        // Could notify relevant parties of validation failure
        return;
      }

      // A result without a target wallet is rejected (A-L3). SPVActor
      // attributes outputs and spent inputs only to a target wallet, so such
      // a result says nothing about which wallet it belongs to; recording it
      // into every loaded wallet credited wallets that were never paid.
      final walletId = result.targetWalletId;
      if (walletId == null) {
        _log.warning('SPV result for ${result.txid} names no target wallet; '
            'not recorded');
        return;
      }
      await _processSPVResultForWallet(walletId, result);
    } catch (e, stackTrace) {
      _log.warning('Failed to handle SPV validation result ${result.txid}: $e',
          e, stackTrace);
    }
  }

  /// Process SPV validation result for a specific wallet
  Future<void> _processSPVResultForWallet(String walletId, SPVValidationResult result) async {
    try {
      // Loaded, or loaded now (with race condition protection)
      final walletActor = await _getOrLoadWallet(walletId);

      if (walletActor == null) {
        _log.warning('SPV result ${result.txid} names wallet $walletId, which '
            'does not exist; not recorded');
        return;
      }

      // CRITICAL: Check if we have the merkle proof IN HAND (not just whether it could be fetched)
      // bumpProof is populated when the BEEF contains the merkle proof for this transaction
      final bumpProof = result.transactionData?['bumpProof'] as String? ?? '';
      final hasMerkleProof = bumpProof.isNotEmpty;
      final blockHeight = result.transactionData?['blockHeight'] as int? ?? 0;
      

      // Process new spendable UTXOs
      // If we have the merkle proof in hand, UTXOs are immediately available
      // If we don't have the proof yet, UTXOs start as pending until proof is obtained
      for (final utxoData in result.spendableUTXOs) {
        final command = ReceiveUTXOCommand(
          walletId: walletId,
          txid: utxoData['txid'] ?? result.txid,
          vout: utxoData['vout'] ?? 0,
          satoshis: BigInt.tryParse(utxoData['satoshis'].toString()) ?? BigInt.zero,
          scriptPubKey: utxoData['script'] ?? '',
          address: utxoData['address'],
          blockHeight: hasMerkleProof ? blockHeight : null,
          confirmations: hasMerkleProof ? 1 : 0,
          // CRITICAL FIX: Set initial status based on WHETHER WE HAVE THE PROOF
          // - Have proof: immediately available (SPV validated with proof in hand)
          // - No proof: pending (will be upgraded by ARCActor when proof is fetched)
          initialStatus: hasMerkleProof ? UTXOStatus.available : UTXOStatus.pending,
        );
        
        walletActor.tell(command);
      }

    // Process spent UTXOs
    for (final utxoData in result.spentUTXOs) {
      final utxoKey = '${utxoData['txid']}:${utxoData['vout']}';
      
      // Use the calculated transaction fee from SPV validation
      // If fee is null, fall back to BigInt.zero (shouldn't happen in practice)
      final fee = result.transactionFee ?? BigInt.zero;
      
      final command = SpendUTXOCommand(
        walletId: walletId,
        utxoKey: utxoKey,
        spendingTxId: result.txid,
        fee: fee,
      );
      
      walletActor.tell(command);
    }

    // ✨ NEW: Record the transaction in transaction history
    // This is critical for maintaining an accurate transaction history
    if (result.transactionData != null) {
      final txData = result.transactionData!;
      
      // Record the imported transaction (this will emit TransactionImportedEvent)
      final command = RecordImportedTransactionCommand(
        walletId: walletId,
        txid: result.txid,
        rawHex: txData['rawHex'] ?? '',
        blockHeight: txData['blockHeight'] ?? 0,
        bumpProofHex: txData['bumpProof'] ?? '',
        totalOutputSats: txData['totalOutputSats'] ?? 0,
        numInputs: txData['numInputs'] ?? 0,
        numOutputs: txData['numOutputs'] ?? 0,
        txVersion: txData['txVersion'] ?? 1,
        txLockTime: txData['txLockTime'] ?? 0,
        walletReceivingAddresses: List<String>.from(txData['walletReceivingAddresses'] ?? []),
        walletReceivedSats: txData['walletReceivedSats'] ?? 0,
        totalInputSats: txData['totalInputSats'] ?? 0,
        sendingAddresses: List<String>.from(txData['sendingAddresses'] ?? []),
        ancestors: List<BeefAncestor>.from(txData['ancestors'] ?? const <BeefAncestor>[]),
      );
      
      walletActor.tell(command);
    } else {
    }

  } catch (e, stackTrace) {
    _log.warning('Failed to process SPV result ${result.txid} for wallet '
        '$walletId: $e', e, stackTrace);
  }
}

  /// Load wallet from event store and spawn actor.
  ///
  /// Returns null when no journal exists for [walletId], so commands for an
  /// unknown wallet are answered with "Wallet not found" instead of being
  /// forwarded to an empty aggregate that rejects each of them with its own
  /// "non-existent wallet" error.
  Future<ActorRef?> _loadWalletFromEventStore(String walletId) async {
    try {
      final persistenceId = 'BitcoinWallet_$walletId';
      final journalLength =
          await _eventStore.getHighestSequenceNumber(persistenceId);
      if (journalLength == 0) {
        return null;
      }

      // Spawn wallet aggregate as actor (AggregateRoot extends Actor).
      // Recovery runs inside preStart and spawn() awaits it (dactor 1.3), so
      // the returned ref is fully recovered.
      final walletActor = await context.system.spawn(
        'wallet-$walletId',
        () => BitcoinWalletAggregate(
          aggregateId: walletId,
          aggregateType: 'BitcoinWallet',
          eventStore: _eventStore,
          cryptoService: _cryptoService,
          secureStorage: _secureStorage,
        ),
      );

      // Journal the holds of deferred payments recorded before holds were
      // journaled (bead libspiffy-7p2), ahead of any command queued for the
      // wallet: the mailbox is FIFO. No events when there is nothing to do.
      walletActor.tell(ReconcileDeferredSpendsCommand(walletId: walletId));

      return walletActor;

    } catch (e, stack) {
      _log.warning('Failed to load wallet $walletId from event store: $e', e, stack);
      return null;
    }
  }
  
  /// Get wallet actor from memory, or load it safely with race condition protection.
  /// 
  /// This helper ensures that only one load attempt happens at a time for a given wallet.
  /// If a load is already in progress, this method waits for it to complete.
  Future<ActorRef?> _getOrLoadWallet(String walletId) async {
    // Check if already loaded
    var walletActor = _loadedWallet(walletId);
    if (walletActor != null) {
      _touch(walletId);
      return walletActor;
    }
    
    // Check if currently being loaded - wait for it
    if (_loadingWallets.contains(walletId)) {
      // Poll until loading completes (with timeout)
      const maxWaitMs = 5000;
      const pollIntervalMs = 50;
      var waitedMs = 0;
      
      while (_loadingWallets.contains(walletId) && waitedMs < maxWaitMs) {
        await Future.delayed(const Duration(milliseconds: pollIntervalMs));
        waitedMs += pollIntervalMs;
      }
      
      // Check if loaded now
      walletActor = _loadedWallet(walletId);
      if (walletActor != null) {
        _touch(walletId);
        return walletActor;
      }
      
      return null;
    }
    
    // Not loaded and not loading - start loading
    _loadingWallets.add(walletId);
    
    try {
      walletActor = await _loadWalletFromEventStore(walletId);
      
      if (walletActor != null) {
        _walletActors[walletId] = walletActor;
        _touch(walletId);
      }

      return walletActor;
      
    } finally {
      _loadingWallets.remove(walletId);
    }
  }

  /// Handle invoice creation - coordinate with InvoiceManager
  Future<void> _handleCreateInvoice(CreateInvoiceMessage msg) async {
    try {
      if (_invoiceManager == null) {
        context.sender?.tell(InvoiceCreatedMessage(
          invoiceId: '',
          walletId: msg.walletId,
          addresses: [],
          amount: msg.amount ?? BigInt.zero,
          createdAt: DateTime.now(),
          success: false,
          error: 'InvoiceManager not available',
        ));
        return;
      }
      
      
      // Ensure wallet is loaded (with race condition protection)
      final walletActor = await _getOrLoadWallet(msg.walletId);
      if (walletActor == null) {
        context.sender?.tell(InvoiceCreatedMessage(
          invoiceId: '',
          walletId: msg.walletId,
          addresses: [],
          amount: msg.amount ?? BigInt.zero,
          createdAt: DateTime.now(),
          success: false,
          error: 'Wallet ${msg.walletId} not found',
        ));
        return;
      }
      
      // Forward to InvoiceManager (which will handle address generation)
      _invoiceManager!.tell(msg, sender: context.sender);
      
    } catch (e, stackTrace) {
      _log.warning('Failed to create invoice for wallet ${msg.walletId}: $e',
          e, stackTrace);
      context.sender?.tell(InvoiceCreatedMessage(
        invoiceId: '',
        walletId: msg.walletId,
        addresses: [],
        amount: msg.amount ?? BigInt.zero,
        createdAt: DateTime.now(),
        success: false,
        error: e.toString(),
      ));
    }
  }

  @override
  void postStop() {
    _reservationCleanupTimer?.cancel();
    _idleCheckTimer?.cancel();
    // Stop the aggregates this manager spawned, so a host-owned actor system
    // does not keep them running after libspiffy shuts down (A-M5).
    final system = context.system;
    for (final ref in _walletActors.values) {
      unawaited(system.stop(ref));
    }
    _walletActors.clear();
    _lastUsed.clear();
  }
}

/// Internal tick for the idle-aggregate sweep.
class _EvictIdleAggregates {
  const _EvictIdleAggregates();
}

/// Helper class to store pending commands while wallet is loading
class _PendingCommand {
  final WalletCommand command;
  final ActorRef? sender;
  
  _PendingCommand(this.command, this.sender);
} 