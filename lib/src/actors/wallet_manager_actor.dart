import 'dart:async';
import 'package:dactor/dactor.dart';
import 'package:eventador/eventador.dart';

import '../core/bitcoin_wallet_aggregate.dart';
import '../core/wallet_commands.dart';
import '../services/crypto_service.dart';
import '../storage/secure_storage.dart';
import 'wallet_messages.dart';
import 'invoice_messages.dart';
import 'libspiffy_actor_system.dart';

/// Central coordinator that manages multiple wallet aggregates and routes commands
class WalletManagerActor extends Actor {
  final EventStore _eventStore;
  final CryptoService _cryptoService;
  final SecureStorage _secureStorage;
  final Map<String, ActorRef> _walletActors = {};
  
  // Track pending wallet creation requests to route responses back to original callers
  final Map<String, ActorRef?> _pendingWalletCreations = {};
  
  // Invoice manager reference for invoice-based payments
  ActorRef? _invoiceManager;
  
  // ARC actor reference for transaction status tracking
  ActorRef? _arcActor;
  
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
    print('WalletManagerActor started');
    _startReservationCleanupTimer();
  }

  /// Start periodic timer to clean up expired UTXO reservations
  /// Runs every 5 minutes to free up UTXOs whose reservations have expired
  void _startReservationCleanupTimer() {
    _reservationCleanupTimer = Timer.periodic(
      const Duration(minutes: 5),
      (_) => _cleanupExpiredReservations(),
    );
    print('UTXO reservation cleanup timer started (runs every 5 minutes)');
  }

  /// Clean up expired UTXO reservations across all active wallets
  Future<void> _cleanupExpiredReservations() async {
    print('Running automated UTXO reservation cleanup...');
    
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
        print('Warning: Failed to cleanup reservations for wallet $walletId: $e');
      }
    }
    
    if (walletsProcessed > 0) {
      print('Sent cleanup commands to $walletsProcessed wallets');
    }
  }

  @override
  Future<void> onMessage(dynamic message) async {
    print('[WalletManagerActor] Received message: ${message.runtimeType}');
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
          print('InvoiceManager reference set in WalletManager');
          break;
          
        case SetArcActorMessage:
          // Internal message to set ARC actor reference
          _arcActor = (message as SetArcActorMessage).arcActor;
          print('ARC actor reference set in WalletManager');
          break;
          
        default:
          print('WalletManagerActor received unknown message: ${message.runtimeType}');
      }
    } catch (e) {
      print('Error in WalletManagerActor: $e');
      
      if (context.sender != null) {
        context.sender!.tell(LocalMessage(
          payload: {'error': e.toString(), 'type': 'wallet_manager_error'},
        ));
      }
    }
  }

  /// Handle wallet creation requests
  Future<void> _handleCreateWallet(CreateWalletMessage msg) async {
    print('[WalletManagerActor] 🔧 _handleCreateWallet called for: ${msg.walletId}');
    print('[WalletManagerActor]    Name: ${msg.name}');
    print('[WalletManagerActor]    Has xpriv: ${msg.xpriv != null && msg.xpriv!.isNotEmpty}');
    try {
      print('Creating wallet: ${msg.walletId}');
      
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
        walletMetadata: msg.walletMetadata,
      );

      // Send command directly - AggregateRoot handles Command objects directly
      walletActor.tell(createCommand, sender: context.self);

      print('Wallet creation command sent to aggregate: ${msg.walletId}');

    } catch (e) {
      print('Error creating wallet ${msg.walletId}: $e');
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
    print('[WalletManagerActor] Received wallet creation response for: ${response.walletId}');
    print('[WalletManagerActor]   Success: ${response.success}');
    print('[WalletManagerActor]   Root address: ${response.rootAddress}');
    print('[WalletManagerActor]   Error: ${response.error}');
    
    // Get the original sender who requested the wallet creation
    final originalSender = _pendingWalletCreations.remove(response.walletId);
    print('[WalletManagerActor]   Original sender exists: ${originalSender != null}');
    
    if (originalSender != null) {
      // Forward the response with real root address to the original caller
      final message = WalletCreatedMessage(
        response.walletId,
        response.rootAddress,
        response.success,
        error: response.error,
      );
      
      print('[WalletManagerActor]   Sending WalletCreatedMessage to original sender...');
      originalSender.tell(message);
      
      print('[WalletManagerActor] ✓ Wallet created successfully: ${response.walletId} with root address: ${response.rootAddress}');
    } else {
      print('[WalletManagerActor] ⚠️ Warning: No pending request found for wallet ${response.walletId}');
    }
  }

  /// Route commands to specific wallet aggregates
  Future<void> _handleWalletCommand(WalletCommandMessage msg) async {
    print('[WalletManagerActor] Handling command for wallet: ${msg.walletId}');
    print('[WalletManagerActor] Command type: ${msg.command.runtimeType}');
    print('[WalletManagerActor] Wallets in memory: ${_walletActors.keys.toList()}');
    
    try {
      var walletActor = _walletActors[msg.walletId];
      
      // Load wallet if not already in memory
      if (walletActor == null) {
        print('[WalletManagerActor] Wallet not in memory, trying to load from event store...');
        walletActor = await _loadWalletFromEventStore(msg.walletId);
        if (walletActor != null) {
          _walletActors[msg.walletId] = walletActor;
          print('[WalletManagerActor] ✓ Wallet loaded from event store');
        }
      } else {
        print('[WalletManagerActor] ✓ Wallet found in memory');
      }

      if (walletActor == null) {
        print('[WalletManagerActor] ❌ Wallet not found: ${msg.walletId}');
        context.sender?.tell(LocalMessage(
          payload: {'error': 'Wallet not found', 'walletId': msg.walletId},
        ));
        return;
      }

      // Forward command to wallet aggregate (send command directly, not wrapped)
      print('[WalletManagerActor] → Forwarding ${msg.command.runtimeType} to wallet aggregate');
      walletActor.tell(msg.command, sender: context.sender);
      print('[WalletManagerActor] ✓ Command forwarded');

    } catch (e) {
      print('Error handling wallet command for ${msg.walletId}: $e');
      context.sender?.tell(LocalMessage(
        payload: {'error': e.toString(), 'walletId': msg.walletId},
      ));
    }
  }

  /// Handle requests for wallet list
  Future<void> _handleListWallets(ListWalletsMessage msg) async {
    final walletIds = _walletActors.keys.toList();
    context.sender?.tell(WalletListMessage(walletIds));
  }

  /// Handle SPV validation results from SPVActor (NEW for correct SPV)
  Future<void> _handleSPVValidationResult(SPVValidationResult result) async {
    print('Processing SPV validation result for transaction ${result.txid}: ${result.isValid ? 'VALID' : 'INVALID'}');
    
    try {
      if (!result.isValid) {
        print('SPV validation failed: ${result.validationError}');
        // Could notify relevant parties of validation failure
        return;
      }

      // Route to appropriate wallet if specified
      if (result.targetWalletId != null) {
        await _processSPVResultForWallet(result.targetWalletId!, result);
      } else {
        // If no specific wallet, might need to determine which wallet(s) this affects
        print('SPV result has no target wallet - processing for all wallets');
        await _processSPVResultForAllWallets(result);
      }
      
    } catch (e) {
      print('Error processing SPV validation result: $e');
    }
  }

  /// Process SPV validation result for a specific wallet
  Future<void> _processSPVResultForWallet(String walletId, SPVValidationResult result) async {
    try {
      var walletActor = _walletActors[walletId];
      
      // Load wallet if not in memory
      if (walletActor == null) {
        walletActor = await _loadWalletFromEventStore(walletId);
        if (walletActor != null) {
          _walletActors[walletId] = walletActor;
        }
      }

      if (walletActor == null) {
        print('Cannot process SPV result - wallet $walletId not found');
        return;
      }

      // Process new spendable UTXOs
      for (final utxoData in result.spendableUTXOs) {
        final command = ReceiveUTXOCommand(
          walletId: walletId,
          txid: utxoData['txid'] ?? result.txid,
          vout: utxoData['vout'] ?? 0,
          satoshis: BigInt.tryParse(utxoData['satoshis'].toString()) ?? BigInt.zero,
          scriptPubKey: utxoData['scriptPubKey'] ?? '',
          address: utxoData['address'],
          blockHeight: utxoData['blockHeight'],
          confirmations: utxoData['confirmations'] ?? 0,
        );
        
        walletActor.tell(command);
        print('Sent ReceiveUTXO command to wallet $walletId');
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
        print('✅ Registered ${vouts.length} received output(s) with ARC actor for status tracking: $txid');
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
      print('Sent SpendUTXO command to wallet $walletId (fee: $fee satoshis)');
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
      print('✅ Sent RecordImportedTransaction command to wallet $walletId for transaction ${result.txid}');
    } else {
      print('⚠️ Warning: SPV result missing transaction data - cannot record in history');
    }

  } catch (e) {
    print('Error processing SPV result for wallet $walletId: $e');
  }
}

  /// Process SPV validation result for all wallets (when target not specified)
  Future<void> _processSPVResultForAllWallets(SPVValidationResult result) async {
    // This might happen with BEEF bundles or when we can't determine the target wallet
    print('Processing SPV result for all wallets - this is unusual and might need investigation');
    
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

      print('Wallet loaded successfully: $walletId');
      
      // IMPORTANT: Wait for aggregate recovery to complete before returning
      // PersistentActor needs time to replay events and initialize state
      // Without this delay, commands sent immediately after loading will be dropped
      await Future.delayed(Duration(milliseconds: 200));
      print('Wallet recovery complete: $walletId');
      
      return walletActor;

    } catch (e) {
      print('Error loading wallet $walletId: $e');
      return null;
    }
  }

  /// Handle invoice creation - coordinate with InvoiceManager
  Future<void> _handleCreateInvoice(CreateInvoiceMessage msg) async {
    try {
      if (_invoiceManager == null) {
        print('Error: InvoiceManager not initialized');
        context.sender?.tell(InvoiceCreatedMessage(
          invoiceId: '',
          walletId: msg.walletId,
          addresses: [],
          amount: msg.amount,
          createdAt: DateTime.now(),
          success: false,
          error: 'InvoiceManager not available',
        ));
        return;
      }
      
      print('Creating invoice for wallet ${msg.walletId}, amount: ${msg.amount}');
      
      // Ensure wallet is loaded
      var walletActor = _walletActors[msg.walletId];
      if (walletActor == null) {
        // Try to load from event store
        walletActor = await _loadWalletFromEventStore(msg.walletId);
        if (walletActor == null) {
          print('Wallet ${msg.walletId} not found');
          context.sender?.tell(InvoiceCreatedMessage(
            invoiceId: '',
            walletId: msg.walletId,
            addresses: [],
            amount: msg.amount,
            createdAt: DateTime.now(),
            success: false,
            error: 'Wallet ${msg.walletId} not found',
          ));
          return;
        }
      }
      
      // Forward to InvoiceManager (which will handle address generation)
      _invoiceManager!.tell(msg, sender: context.sender);
      
    } catch (e) {
      print('Error creating invoice: $e');
      context.sender?.tell(InvoiceCreatedMessage(
        invoiceId: '',
        walletId: msg.walletId,
        addresses: [],
        amount: msg.amount,
        createdAt: DateTime.now(),
        success: false,
        error: e.toString(),
      ));
    }
  }

  @override
  void postStop() {
    _reservationCleanupTimer?.cancel();
    print('WalletManagerActor stopped');
  }
} 