import 'package:eventador/eventador.dart';
import '../core/channel_events.dart';
import '../storage/read_model_storage.dart';
import '../storage/payment_channel_entity.dart';

/// Channel projection that builds read models from channel events
/// 
/// This projection subscribes to payment channel events from the EventStore and
/// maintains denormalized `PaymentChannelEntity` in Isar for fast queries.
/// Separates write concerns (aggregate) from read concerns (queries).
/// 
/// STATELESS DESIGN: This projection does NOT cache state in memory.
/// Storage (Isar) is the source of truth. Checkpoints track which events
/// have been processed, but all state is read from/written to storage.
/// This design survives app restarts correctly - no checkpoint/state mismatch.
class ChannelProjection extends Projection<void> {
  final ReadModelStorage _storage;
  final String _projectionId;
  int _checkpoint = 0;
  
  // NOTE: No in-memory state caching. Storage IS the read model.
  // This prevents checkpoint/state mismatch bugs on restart.
  
  ChannelProjection({
    required String projectionId,
    required EventStore eventStore,
    required ReadModelStorage storage,
  })  : _storage = storage,
        _projectionId = projectionId,
        super();
  
  @override
  String get projectionId => _projectionId;
  
  @override
  void get readModel => null; // Storage is the read model, query it directly
  
  @override
  List<Type> get interestedEventTypes => [
        ChannelRequestedEvent,
        ChannelAcceptedEvent,
        ChannelRejectedEvent,
        ServerAcceptanceRecordedEvent,
        RefundBuiltEvent,
        RefundCountersignedEvent,
        ChannelOpenedEvent,
        PaymentRecordedEvent,
        PaymentAcknowledgedEvent,
        ChannelClosingEvent,
        ChannelClosedEvent,
        RefundClaimedEvent,
        ChannelExpiredEvent,
      ];
  
  @override
  Future<int> getCheckpoint() async {
    // Checkpoint persistence is now handled automatically by ProjectionManager
    // This is only used as a fallback if ProjectionManager doesn't have Isar
    return _checkpoint;
  }
  
  @override
  Future<void> updateCheckpoint(int checkpoint) async {
    // Checkpoint persistence is now handled automatically by ProjectionManager
    // We just maintain an in-memory checkpoint for backward compatibility
    _checkpoint = checkpoint;
  }
  
  @override
  Future<void> reset() async {
    // Reset is handled by clearing projection checkpoint in ProjectionManager
    // The read model (Isar) can be cleared if needed, but typically we just replay events
    _checkpoint = 0;
  }
  
  @override
  Future<void> rebuild() async {
    await reset();
    // Projection manager will replay events after rebuild
  }
  
  @override
  Future<bool> handle(Event event) async {
    if (event is! ChannelEvent) return false;
    
    try {
      switch (event.runtimeType) {
        case ChannelRequestedEvent:
          await _handleChannelRequested(event as ChannelRequestedEvent);
          return true;
        case ChannelAcceptedEvent:
          await _handleChannelAccepted(event as ChannelAcceptedEvent);
          return true;
        case ChannelRejectedEvent:
          await _handleChannelRejected(event as ChannelRejectedEvent);
          return true;
        case ServerAcceptanceRecordedEvent:
          await _handleServerAcceptanceRecorded(event as ServerAcceptanceRecordedEvent);
          return true;
        case RefundBuiltEvent:
          await _handleRefundBuilt(event as RefundBuiltEvent);
          return true;
        case RefundCountersignedEvent:
          await _handleRefundCountersigned(event as RefundCountersignedEvent);
          return true;
        case ChannelOpenedEvent:
          await _handleChannelOpened(event as ChannelOpenedEvent);
          return true;
        case PaymentRecordedEvent:
          await _handlePaymentRecorded(event as PaymentRecordedEvent);
          return true;
        case PaymentAcknowledgedEvent:
          await _handlePaymentAcknowledged(event as PaymentAcknowledgedEvent);
          return true;
        case ChannelClosingEvent:
          await _handleChannelClosing(event as ChannelClosingEvent);
          return true;
        case ChannelClosedEvent:
          await _handleChannelClosed(event as ChannelClosedEvent);
          return true;
        case RefundClaimedEvent:
          await _handleRefundClaimed(event as RefundClaimedEvent);
          return true;
        case ChannelExpiredEvent:
          await _handleChannelExpired(event as ChannelExpiredEvent);
          return true;
        default:
          return false;
      }
    } catch (e, stack) {
      rethrow;
    }
  }
  
  // ==========================================================================
  // EVENT HANDLERS
  // ==========================================================================
  
  Future<void> _handleChannelRequested(ChannelRequestedEvent event) async {
    
    // Create new channel entity
    final entity = PaymentChannelEntity()
      ..channelId = event.channelId
      ..walletId = event.walletId
      ..role = 'client'
      ..clientPeerId = event.clientPeerId
      ..serverPeerId = event.serverPeerId
      ..clientPubKeyHex = event.clientPubKeyHex
      ..clientAddressB58 = event.clientAddressB58
      ..serverPubKeyHex = '' // Will be set on accept
      ..serverAddressB58 = '' // Will be set on accept
      ..fundingAmountSats = event.fundingAmountSats.toString()
      ..fundingTxId = '' // Will be set on open
      ..fundingTxHex = '' // Will be set on open
      ..fundingOutputIndex = 0 // Will be set on open
      ..lockTimeUnix = event.lockTimeUnix
      ..state = 'opening' // ChannelStatus.pending → 'opening'
      ..clientBalanceSats = event.fundingAmountSats.toString()
      ..serverBalanceSats = '0'
      ..latestSequenceNumber = 0
      ..fundingAncestorTxids = []
      ..context = event.context
      ..createdAt = event.timestamp
      ..hasFundingMerkleProof = false;
    
    await _storage.storePaymentChannel(entity);
  }
  
  Future<void> _handleChannelAccepted(ChannelAcceptedEvent event) async {
    
    final existing = await _storage.getPaymentChannel(event.channelId);
    if (existing == null) {
      // Server side: create entity on accept if it doesn't exist
      // Event now includes all necessary data from AcceptChannelCommand
      final entity = PaymentChannelEntity()
        ..channelId = event.channelId
        ..walletId = event.walletId
        ..role = 'server'
        ..clientPeerId = event.clientPeerId
        ..serverPeerId = '' // Server's own peer ID not needed in entity
        ..clientPubKeyHex = event.clientPubKeyHex
        ..clientAddressB58 = event.clientAddressB58
        ..serverPubKeyHex = event.serverPubKeyHex
        ..serverAddressB58 = event.serverAddressB58
        ..fundingAmountSats = event.fundingAmountSats.toString()
        ..fundingTxId = ''
        ..fundingTxHex = ''
        ..fundingOutputIndex = 0
        ..lockTimeUnix = event.lockTimeUnix
        ..state = 'opening' // ChannelStatus.accepted → 'opening'
        ..clientBalanceSats = event.fundingAmountSats.toString()
        ..serverBalanceSats = '0'
        ..latestSequenceNumber = 0
        ..fundingAncestorTxids = []
        ..context = event.context
        ..createdAt = event.timestamp
        ..hasFundingMerkleProof = false;
      
      await _storage.storePaymentChannel(entity);
    } else {
      // Client side: update existing entity with server info
      final entity = existing as PaymentChannelEntity;
      entity.serverPubKeyHex = event.serverPubKeyHex;
      entity.serverAddressB58 = event.serverAddressB58;
      entity.state = 'opening'; // ChannelStatus.accepted → 'opening'
      
      await _storage.storePaymentChannel(entity);
    }
  }
  
  Future<void> _handleChannelRejected(ChannelRejectedEvent event) async {
    
    await _storage.updatePaymentChannelState(event.channelId, 'closed');
  }
  
  Future<void> _handleServerAcceptanceRecorded(ServerAcceptanceRecordedEvent event) async {
    
    final existing = await _storage.getPaymentChannel(event.channelId);
    if (existing == null) {
      return;
    }
    
    // Client side: update entity with server info
    final entity = existing as PaymentChannelEntity;
    entity.serverPubKeyHex = event.serverPubKeyHex;
    entity.serverAddressB58 = event.serverAddressB58;
    
    await _storage.storePaymentChannel(entity);
  }
  
  Future<void> _handleRefundBuilt(RefundBuiltEvent event) async {
    
    final existing = await _storage.getPaymentChannel(event.channelId);
    if (existing == null) {
      return;
    }
    
    final entity = existing as PaymentChannelEntity;
    entity.fundingTxId = event.fundingTxId;
    entity.fundingOutputIndex = event.fundingOutputIndex;
    entity.fundingTxHex = event.fundingTxHex;
    entity.refundTxHex = event.refundTxHex;
    entity.refundClientSigHex = event.clientSignatureHex;
    
    await _storage.storePaymentChannel(entity);
  }
  
  Future<void> _handleRefundCountersigned(RefundCountersignedEvent event) async {
    
    final existing = await _storage.getPaymentChannel(event.channelId);
    if (existing == null) {
      return;
    }
    
    final entity = existing as PaymentChannelEntity;
    entity.refundServerSigHex = event.serverSignatureHex;
    entity.state = 'opening'; // ChannelStatus.refundSigned → 'opening'
    
    await _storage.storePaymentChannel(entity);
  }
  
  Future<void> _handleChannelOpened(ChannelOpenedEvent event) async {
    
    final existing = await _storage.getPaymentChannel(event.channelId);
    if (existing == null) {
      return;
    }
    
    final entity = existing as PaymentChannelEntity;
    entity.state = 'open'; // ChannelStatus.open → 'open'
    entity.fundingTxId = event.fundingTxId;
    entity.fundingOutputIndex = event.fundingOutputIndex;
    entity.fundingTxHex = event.fundingTxHex;
    entity.fundingAncestorTxids = event.fundingAncestorTxids;
    entity.clientBalanceSats = event.initialClientBalanceSats.toString();
    entity.serverBalanceSats = event.initialServerBalanceSats.toString();
    
    await _storage.storePaymentChannel(entity);
  }
  
  Future<void> _handlePaymentRecorded(PaymentRecordedEvent event) async {
    
    final existing = await _storage.getPaymentChannel(event.channelId);
    if (existing == null) {
      return;
    }
    
    final entity = existing as PaymentChannelEntity;
    entity.clientBalanceSats = event.newClientBalanceSats.toString();
    entity.serverBalanceSats = event.newServerBalanceSats.toString();
    entity.latestSequenceNumber = event.sequenceNumber;
    entity.latestPaymentTxHex = event.paymentTxHex;
    
    await _storage.storePaymentChannel(entity);
  }
  
  Future<void> _handlePaymentAcknowledged(PaymentAcknowledgedEvent event) async {
    
    final existing = await _storage.getPaymentChannel(event.channelId);
    if (existing == null) {
      return;
    }
    
    final entity = existing as PaymentChannelEntity;
    entity.clientBalanceSats = event.newClientBalanceSats.toString();
    entity.serverBalanceSats = event.newServerBalanceSats.toString();
    entity.latestSequenceNumber = event.sequenceNumber;
    entity.latestPaymentTxHex = event.fullySignedPaymentTxHex;
    
    await _storage.storePaymentChannel(entity);
  }
  
  Future<void> _handleChannelClosing(ChannelClosingEvent event) async {
    
    await _storage.updatePaymentChannelState(event.channelId, 'closing');
  }
  
  Future<void> _handleChannelClosed(ChannelClosedEvent event) async {
    
    final existing = await _storage.getPaymentChannel(event.channelId);
    if (existing == null) {
      return;
    }
    
    final entity = existing as PaymentChannelEntity;
    entity.state = 'closed'; // ChannelStatus.closed → 'closed'
    entity.clientBalanceSats = event.finalClientBalanceSats.toString();
    entity.serverBalanceSats = event.finalServerBalanceSats.toString();
    entity.closedAt = event.timestamp;
    
    await _storage.storePaymentChannel(entity);
  }
  
  Future<void> _handleRefundClaimed(RefundClaimedEvent event) async {

    final existing = await _storage.getPaymentChannel(event.channelId);
    if (existing == null) {
      return;
    }

    final entity = existing as PaymentChannelEntity;
    entity.state = 'expired'; // ChannelStatus.expired → 'expired'
    entity.closedAt = event.timestamp;

    await _storage.storePaymentChannel(entity);
  }

  Future<void> _handleChannelExpired(ChannelExpiredEvent event) async {
    final existing = await _storage.getPaymentChannel(event.channelId);
    if (existing == null) {
      return;
    }

    final entity = existing as PaymentChannelEntity;
    entity.state = 'expired';
    entity.closedAt = event.timestamp;

    await _storage.storePaymentChannel(entity);
  }
}

