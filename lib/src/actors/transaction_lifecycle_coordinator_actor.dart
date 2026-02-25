import 'dart:async';
import 'package:dactor/dactor.dart';
import 'package:logging/logging.dart';
import '../core/wallet_events.dart';
import '../models/bitcoin_transaction.dart';
import '../models/wallet_event.dart';
import '../storage/read_model_storage.dart';
import 'wallet_messages.dart';

/// Coordinator actor for transaction lifecycle management
/// 
/// Responsibilities:
/// - Recovery: Re-register pending transactions with ARCActor on startup
/// - Registration: Listen for TransactionBroadcastEvent and register with ARCActor
/// - Cleanup: Listen for TransactionConfirmedEvent and unregister from ARCActor
/// 
/// This ensures ARCActor maintains proper monitoring state even after app restarts.
class TransactionLifecycleCoordinator extends Actor {
  final _log = Logger('TransactionLifecycleCoordinator');
  final ActorRef _arcActor;
  final ReadModelStorage _storage;
  final Stream<WalletEvent> _eventStream;
  
  // Track subscriptions
  StreamSubscription? _eventSubscription;
  
  TransactionLifecycleCoordinator({
    required ActorRef arcActor,
    required ReadModelStorage storage,
    required Stream<WalletEvent> eventStream,
  })  : _arcActor = arcActor,
        _storage = storage,
        _eventStream = eventStream;

  @override
  void preStart() {
    _recoverPendingTransactions();
    _subscribeToEvents();
  }

  @override
  Future<void> onMessage(dynamic message) async {
    // This actor primarily reacts to events via subscription
    // Could handle manual recovery requests in the future
  }

  /// Subscribe to wallet events from event stream
  void _subscribeToEvents() {
    
    _eventSubscription = _eventStream.listen((event) {
      if (event is TransactionBroadcastEvent) {
        _handleTransactionBroadcast(event);
      } else if (event is TransactionConfirmedEvent) {
        _handleTransactionConfirmed(event);
      }
    });
  }

  /// Handle TransactionBroadcastEvent - register with ARCActor
  void _handleTransactionBroadcast(TransactionBroadcastEvent event) {
    
    // Note: We need to get the vouts from storage
    // The TransactionBroadcastEvent doesn't include output details
    _registerTransactionForMonitoring(event.walletId, event.txid);
  }

  /// Handle TransactionConfirmedEvent - unregister from ARCActor
  void _handleTransactionConfirmed(TransactionConfirmedEvent event) {
    // ARCActor handles this internally via status checks
  }

  /// Register a transaction for monitoring with ARCActor
  Future<void> _registerTransactionForMonitoring(
    String walletId,
    String txid,
  ) async {
    try {
      // Get transaction from storage to find our output indices
      final tx = await _storage.getTransaction(txid);
      if (tx == null) {
        return;
      }

      // For now, we'll register all outputs since we don't have explicit vout tracking
      // This could be optimized by storing which outputs belong to the wallet
      // TODO: Track which specific vouts are ours in TransactionRecordedEvent
      
      _arcActor.tell(RegisterTransactionOutputsMessage(
        txid: txid,
        walletId: walletId,
        vouts: [], // Empty list means monitor the whole transaction
      ));
      
    } catch (e) {
      _log.warning('Failed to register transaction for monitoring: $e');
    }
  }

  /// Recover pending transactions on startup
  Future<void> _recoverPendingTransactions() async {
    
    try {
      // Query all pending transactions across all wallets
      final pendingTxs = await _storage.getTransactionsByStatus(
        TransactionStatus.pending,
      );
      
      if (pendingTxs.isEmpty) {
        return;
      }
      
      
      // Re-register each pending transaction with ARCActor
      for (final tx in pendingTxs) {
        // Get wallet ID from transaction
        final walletId = tx.walletId;
        if (walletId == null || walletId.isEmpty) {
          continue;
        }
        
        await _registerTransactionForMonitoring(walletId, tx.txid);
      }
      
      
    } catch (e, stackTrace) {
      _log.warning('Failed to recover pending transactions: $e');
    }
  }

  @override
  void postStop() {
    _eventSubscription?.cancel();
  }
}

