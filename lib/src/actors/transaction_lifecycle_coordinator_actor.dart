import 'package:dactor/dactor.dart';
import '../models/wallet_event.dart';
import '../storage/read_model_storage.dart';

/// Placeholder for transaction lifecycle management; it currently does
/// nothing.
///
/// It used to re-register pending transactions with ARCActor on startup and
/// on every TransactionBroadcastEvent, but ARCActor ignored those
/// registrations (its transaction monitoring reads pending UTXOs from
/// storage), and the broadcast subscription never fired because only
/// ImportActor feeds the wallet event broadcaster. Both were removed
/// (audit A-L4). The actor is still spawned by LibSpiffyActorSystem and
/// exposed as `transactionLifecycleCoordinator`, so the class and its
/// constructor are kept for compatibility.
class TransactionLifecycleCoordinator extends Actor {
  /// All parameters are unused; they are accepted for compatibility with
  /// existing callers.
  TransactionLifecycleCoordinator({
    required ActorRef arcActor,
    required ReadModelStorage storage,
    required Stream<WalletEvent> eventStream,
  });

  @override
  Future<void> onMessage(dynamic message) async {}
}
