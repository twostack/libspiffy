import 'dart:async';
import 'package:dactor/dactor.dart';
import 'package:eventador/eventador.dart';
import 'package:logging/logging.dart';

import '../core/bitcoin_wallet_aggregate.dart';
import '../core/wallet_commands.dart';
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

  // ARC actor reference for transaction status tracking
  ActorRef? _arcActor;
  
  // Benford coordinator for privacy-focused UTXO splitting
  ActorRef? _benfordCoordinator;
  
  // SPV actors are coordinated at the LibSpiffyActorSystem level
  // and accessed via message passing rather than direct references
  
  // Timer for automated UTXO reservation cleanup
  Timer? _reservationCleanupTimer;

  WalletManagerActor({
    required EventStore eventStore,
    required CryptoService cryptoService,
    required SecureStorage secureStorage,
  })  : _eventStore = eventStore,
        _cryptoService = cryptoService,
        _secureStorage = secureStorage;

  @override
  void preStart() {
    _startReservationCleanupTimer();
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
      } catch (e) {
        _log.warning('Failed to cleanup expired reservations for wallet $walletId: $e');
      }
    }

    if (walletsProcessed > 0) {
    }
  }

  @override
  Future<void> onMessage(dynamic message) async {
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
    } catch (e) {
      
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
      
      // Check if wallet already exists
      if (_walletActors.containsKey(msg.walletId)) {
        context.sender?.tell(WalletCreatedMessage(
          msg.walletId,
          '',
          false,
          error: 'Wallet already exists',
        ));
        return;
      }

      // Spawn wallet aggregate as actor (AggregateRoot extends Actor)
      final walletActor = await context.system.spawn(
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

      // Track the original sender so we can route the WalletCreatedResponse back to them
      _pendingWalletCreations[msg.walletId] = context.sender;

      // IMPORTANT: Wait for aggregate recovery to complete before sending commands
      // PersistentActor drops messages that arrive during recovery
      await Future.delayed(Duration(milliseconds: 200));

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


    } catch (e) {
      context.sender?.tell(WalletCreatedMessage(
        msg.walletId,
        '',
        false,
        error: e.toString(),
      ));
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
      
      originalSender.tell(message);
      
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
      var walletActor = _walletActors[msg.walletId];
      
      // Check if wallet is already loaded
      if (walletActor != null) {
        // Forward command directly
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

    } catch (e) {
      
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
    if (_walletActors.containsKey(walletId)) {
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
      } else {
      }
    } catch (e) {
      _log.warning('Failed to preload wallet $walletId: $e');
      _loadingWallets.remove(walletId);
    }
  }

  /// Handle SPV validation results from SPVActor (NEW for correct SPV)
  Future<void> _handleSPVValidationResult(SPVValidationResult result) async {
    
    try {
      if (!result.isValid) {
        // Could notify relevant parties of validation failure
        return;
      }

      // Route to appropriate wallet if specified
      if (result.targetWalletId != null) {
        await _processSPVResultForWallet(result.targetWalletId!, result);
      } else {
        // If no specific wallet, might need to determine which wallet(s) this affects
        await _processSPVResultForAllWallets(result);
      }
      
    } catch (e) {
      _log.warning('Failed to handle SPV validation result: $e');
    }
  }

  /// Process SPV validation result for a specific wallet
  Future<void> _processSPVResultForWallet(String walletId, SPVValidationResult result) async {
    try {
      var walletActor = _walletActors[walletId];
      
      // Load wallet if not in memory (with race condition protection)
      if (walletActor == null) {
        walletActor = await _getOrLoadWallet(walletId);
      }

      if (walletActor == null) {
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

      // Register received UTXOs with ARC actor for status tracking
      if (result.spendableUTXOs.isNotEmpty && _arcActor != null) {
        final txid = result.txid;
        final vouts = result.spendableUTXOs
            .map((utxoData) => utxoData['vout'] as int? ?? 0)
            .toList();
        
        final registerMsg = RegisterTransactionOutputsMessage(
          txid: txid,
          walletId: walletId,
          vouts: vouts,
        );
        
        _arcActor!.tell(registerMsg);
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
      );
      
      walletActor.tell(command);
    } else {
    }

  } catch (e) {
    _log.warning('Failed to process SPV result for wallet: $e');
  }
}

  /// Process SPV validation result for all wallets (when target not specified)
  Future<void> _processSPVResultForAllWallets(SPVValidationResult result) async {
    // This might happen with BEEF bundles or when we can't determine the target wallet
    
    // For now, we could iterate through all wallets, but this should be rare
    // In a proper implementation, we'd have better ways to route transactions
    for (final walletId in _walletActors.keys) {
      await _processSPVResultForWallet(walletId, result);
    }
  }

  /// Load wallet from event store and spawn actor
  Future<ActorRef?> _loadWalletFromEventStore(String walletId) async {
    try {

      // Spawn wallet aggregate as actor (AggregateRoot extends Actor)
      // The PersistentActor framework will automatically recover state from events
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

      
      // IMPORTANT: Wait for aggregate recovery to complete before returning
      // Use RecoveryStatusQuery to reliably wait for recovery completion
      // instead of an arbitrary delay that might not be sufficient
      try {
        final recoveryResponse = await walletActor.ask<RecoveryStatusResponse>(
          RecoveryStatusQuery(),
          Duration(seconds: 30), // 30 second timeout for recovery
        );
        
        if (recoveryResponse.isRecovered) {
        } else {
        }
      } on TimeoutException {
        // Continue anyway - the wallet might still work
      } catch (e) {
        // Continue anyway - the wallet might still work
      }
      
      return walletActor;

    } catch (e) {
      return null;
    }
  }
  
  /// Get wallet actor from memory, or load it safely with race condition protection.
  /// 
  /// This helper ensures that only one load attempt happens at a time for a given wallet.
  /// If a load is already in progress, this method waits for it to complete.
  Future<ActorRef?> _getOrLoadWallet(String walletId) async {
    // Check if already loaded
    var walletActor = _walletActors[walletId];
    if (walletActor != null) {
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
      walletActor = _walletActors[walletId];
      if (walletActor != null) {
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
      
    } catch (e) {
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
  }
}

/// Helper class to store pending commands while wallet is loading
class _PendingCommand {
  final WalletCommand command;
  final ActorRef? sender;
  
  _PendingCommand(this.command, this.sender);
} 