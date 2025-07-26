import 'dart:async';
import 'package:dactor/dactor.dart';
import 'package:eventador/eventador.dart';

import '../core/bitcoin_wallet_aggregate.dart';
import '../core/wallet_commands.dart';
import 'wallet_messages.dart';

/// Central coordinator that manages multiple wallet aggregates and routes commands
class WalletManagerActor extends Actor {
  final EventStore _eventStore;
  final Map<String, ActorRef> _walletActors = {};
  
  ActorRef? _spvActor;
  ActorRef? _arcActor;

  WalletManagerActor({
    required EventStore eventStore,
  }) : _eventStore = eventStore;

  @override
  void preStart() {
    print('WalletManagerActor started');
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
          
        default:
          print('WalletManagerActor received unknown message: ${message.runtimeType}');
      }
    } catch (e, stackTrace) {
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

      // Spawn new wallet aggregate actor
      final walletActor = await context.system.spawn(
        'wallet-${msg.walletId}',
        () => BitcoinWalletAggregate(
          aggregateId: msg.walletId,
          aggregateType: 'BitcoinWallet',
          eventStore: _eventStore,
        ),
      );

      // Store reference
      _walletActors[msg.walletId] = walletActor;

      // Send create wallet command to the aggregate
      final createCommand = CreateWalletCommand(
        walletId: msg.walletId,
        walletName: msg.name,
        walletMetadata: msg.walletMetadata,
      );

      // Use fire-and-forget for now
      walletActor.tell(LocalMessage(payload: createCommand));
      
      // TODO: Get actual root address from wallet response
      final rootAddress = 'placeholder_${msg.walletId}';
      
      context.sender?.tell(WalletCreatedMessage(
        msg.walletId,
        rootAddress,
        true,
      ));

      print('Wallet created successfully: ${msg.walletId}');

    } catch (e) {
      print('Error creating wallet ${msg.walletId}: $e');
      context.sender?.tell(WalletCreatedMessage(
        msg.walletId,
        '',
        false,
        error: e.toString(),
      ));
    }
  }

  /// Route commands to specific wallet aggregates
  Future<void> _handleWalletCommand(WalletCommandMessage msg) async {
    try {
      var walletActor = _walletActors[msg.walletId];
      
      // Load wallet if not already in memory
      if (walletActor == null) {
        walletActor = await _loadWalletFromEventStore(msg.walletId);
        if (walletActor != null) {
          _walletActors[msg.walletId] = walletActor;
        }
      }

      if (walletActor == null) {
        print('Wallet not found: ${msg.walletId}');
        context.sender?.tell(LocalMessage(
          payload: {'error': 'Wallet not found', 'walletId': msg.walletId},
        ));
        return;
      }

      // Forward command to wallet aggregate
      walletActor.tell(LocalMessage(payload: msg.command), sender: context.sender);

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
        
        walletActor.tell(LocalMessage(payload: command));
        print('Sent ReceiveUTXO command to wallet $walletId');
      }

      // Process spent UTXOs
      for (final utxoData in result.spentUTXOs) {
        final utxoKey = '${utxoData['txid']}:${utxoData['vout']}';
        final command = SpendUTXOCommand(
          walletId: walletId,
          utxoKey: utxoKey,
          spendingTxId: result.txid,
          fee: BigInt.zero, // TODO: Get actual fee from transaction
        );
        
        walletActor.tell(LocalMessage(payload: command));
        print('Sent SpendUTXO command to wallet $walletId');
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
      print('Loading wallet from event store: $walletId');
      
      // Check if wallet has events in store
      final events = await _eventStore.getEvents(walletId);
      if (events.isEmpty) {
        print('No events found for wallet: $walletId');
        return null;
      }

      // Spawn wallet aggregate actor
      final walletActor = await context.system.spawn(
        'wallet-$walletId',
        () => BitcoinWalletAggregate(
          aggregateId: walletId,
          aggregateType: 'BitcoinWallet',
          eventStore: _eventStore,
        ),
      );

      print('Wallet loaded successfully: $walletId');
      return walletActor;

    } catch (e) {
      print('Error loading wallet $walletId: $e');
      return null;
    }
  }

  @override
  void postStop() {
    print('WalletManagerActor stopped');
  }
} 