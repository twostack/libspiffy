import 'package:uuid/uuid.dart';
import 'package:eventador/eventador.dart';

/// Base class for all wallet events that integrates with Eventador event sourcing
/// 
/// Events represent immutable facts about things that have happened
/// in the wallet domain. Each event should contain all the information
/// needed to reconstruct the state change it represents.
abstract class WalletEvent extends AggregateEventBase with SerializableEvent {
  /// ID of the wallet this event belongs to (same as aggregateId)
  String get walletId => aggregateId;
  
  WalletEvent({
    required String walletId,
    String? eventId,
    DateTime? timestamp,
    int? version,
    Map<String, dynamic>? metadata,
  }) : super(
          aggregateId: walletId,
          aggregateType: 'Wallet',
          eventId: eventId,
          timestamp: timestamp,
          version: version,
          metadata: metadata,
        );
  
  /// Wallet-specific event data (to be implemented by concrete events)
  Map<String, dynamic> getWalletEventData();

  /// Implementation of SerializableEvent.getEventData
  @override
  Map<String, dynamic> getEventData() {
    final data = getWalletEventData();
    data['walletId'] = walletId;
    return data;
  }
} 