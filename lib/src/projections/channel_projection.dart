import 'package:eventador/eventador.dart';
import '../core/channel_events.dart';
import '../models/payment_channel.dart';
import '../storage/read_model_storage.dart';

/// Channel projection that builds read models from channel events
///
/// This projection subscribes to payment channel events from the EventStore and
/// maintains a denormalized domain [PaymentChannel] per channel in
/// [ReadModelStorage] for fast queries. Each backend (Isar, Postgres,
/// in-memory) converts to its own representation internally.
/// Separates write concerns (aggregate) from read concerns (queries).
///
/// STATELESS DESIGN: This projection does NOT cache state in memory.
/// Storage is the source of truth. Checkpoints track which events
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
    // The read model can be cleared if needed, but typically we just replay events
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
  }

  // ==========================================================================
  // EVENT HANDLERS
  // ==========================================================================

  Future<void> _handleChannelRequested(ChannelRequestedEvent event) async {
    // Client side: the channel exists from the request on. Server data and
    // funding data are filled in by later events.
    await _storage.storePaymentChannel(PaymentChannel(
      channelId: event.channelId,
      walletId: event.walletId,
      role: PaymentChannelRole.client,
      clientPeerId: event.clientPeerId,
      serverPeerId: event.serverPeerId,
      clientPubKeyHex: event.clientPubKeyHex,
      // No serverPubKeyHex: the server key is recorded on acceptance.
      clientAddressB58: event.clientAddressB58,
      fundingAmountSats: event.fundingAmountSats,
      lockTimeUnix: event.lockTimeUnix,
      state: PaymentChannelState.opening, // ChannelStatus.pending → opening
      clientBalanceSats: event.fundingAmountSats,
      serverBalanceSats: BigInt.zero,
      context: event.context,
      createdAt: event.timestamp,
    ));
  }

  Future<void> _handleChannelAccepted(ChannelAcceptedEvent event) async {
    final existing = await _storage.getPaymentChannel(event.channelId);
    if (existing == null) {
      // Server side: create the channel on accept if it doesn't exist.
      // Event includes all necessary data from AcceptChannelCommand.
      await _storage.storePaymentChannel(PaymentChannel(
        channelId: event.channelId,
        walletId: event.walletId,
        role: PaymentChannelRole.server,
        clientPeerId: event.clientPeerId,
        serverPeerId: '', // Server's own peer ID is not carried by the event
        clientPubKeyHex: event.clientPubKeyHex,
        serverPubKeyHex: event.serverPubKeyHex,
        clientAddressB58: event.clientAddressB58,
        serverAddressB58: event.serverAddressB58,
        fundingAmountSats: event.fundingAmountSats,
        lockTimeUnix: event.lockTimeUnix,
        state: PaymentChannelState.opening, // ChannelStatus.accepted → opening
        clientBalanceSats: event.fundingAmountSats,
        serverBalanceSats: BigInt.zero,
        context: event.context,
        createdAt: event.timestamp,
      ));
    } else {
      // Client side: record the server's key and address.
      await _storage.storePaymentChannel(existing.copyWith(
        serverPubKeyHex: event.serverPubKeyHex,
        serverAddressB58: event.serverAddressB58,
        state: PaymentChannelState.opening,
      ));
    }
  }

  Future<void> _handleChannelRejected(ChannelRejectedEvent event) async {
    final existing = await _storage.getPaymentChannel(event.channelId);
    if (existing == null) {
      await _storage.updatePaymentChannelState(
          event.channelId, PaymentChannelState.closed.name);
      return;
    }
    await _storage.storePaymentChannel(existing.copyWith(
      state: PaymentChannelState.closed,
      errorMessage: event.reason,
    ));
  }

  Future<void> _handleServerAcceptanceRecorded(ServerAcceptanceRecordedEvent event) async {
    final existing = await _storage.getPaymentChannel(event.channelId);
    if (existing == null) {
      return;
    }

    // Client side: record the server's key and address.
    await _storage.storePaymentChannel(existing.copyWith(
      serverPubKeyHex: event.serverPubKeyHex,
      serverAddressB58: event.serverAddressB58,
    ));
  }

  Future<void> _handleRefundBuilt(RefundBuiltEvent event) async {
    final existing = await _storage.getPaymentChannel(event.channelId);
    if (existing == null) {
      return;
    }

    await _storage.storePaymentChannel(existing.copyWith(
      fundingTxId: event.fundingTxId,
      fundingOutputIndex: event.fundingOutputIndex,
      fundingTxHex: event.fundingTxHex,
      refundTxHex: event.refundTxHex,
      refundClientSigHex: event.clientSignatureHex,
    ));
  }

  Future<void> _handleRefundCountersigned(RefundCountersignedEvent event) async {
    final existing = await _storage.getPaymentChannel(event.channelId);
    if (existing == null) {
      return;
    }

    await _storage.storePaymentChannel(existing.copyWith(
      refundServerSigHex: event.serverSignatureHex,
      state: PaymentChannelState.opening, // ChannelStatus.refundSigned → opening
    ));
  }

  Future<void> _handleChannelOpened(ChannelOpenedEvent event) async {
    final existing = await _storage.getPaymentChannel(event.channelId);
    if (existing == null) {
      return;
    }

    await _storage.storePaymentChannel(existing.copyWith(
      state: PaymentChannelState.open,
      fundingTxId: event.fundingTxId,
      fundingOutputIndex: event.fundingOutputIndex,
      fundingTxHex: event.fundingTxHex,
      fundingAncestorTxids: List<String>.from(event.fundingAncestorTxids),
      clientBalanceSats: event.initialClientBalanceSats,
      serverBalanceSats: event.initialServerBalanceSats,
    ));
  }

  Future<void> _handlePaymentRecorded(PaymentRecordedEvent event) async {
    final existing = await _storage.getPaymentChannel(event.channelId);
    if (existing == null) {
      return;
    }

    await _storage.storePaymentChannel(existing.copyWith(
      clientBalanceSats: event.newClientBalanceSats,
      serverBalanceSats: event.newServerBalanceSats,
      latestSequenceNumber: event.sequenceNumber,
      latestPaymentTxHex: event.paymentTxHex,
      latestPaymentTxId: event.paymentTxId,
    ));
  }

  Future<void> _handlePaymentAcknowledged(PaymentAcknowledgedEvent event) async {
    final existing = await _storage.getPaymentChannel(event.channelId);
    if (existing == null) {
      return;
    }

    await _storage.storePaymentChannel(existing.copyWith(
      clientBalanceSats: event.newClientBalanceSats,
      serverBalanceSats: event.newServerBalanceSats,
      latestSequenceNumber: event.sequenceNumber,
      latestPaymentTxHex: event.fullySignedPaymentTxHex,
    ));
  }

  Future<void> _handleChannelClosing(ChannelClosingEvent event) async {
    await _storage.updatePaymentChannelState(
        event.channelId, PaymentChannelState.closing.name);
  }

  Future<void> _handleChannelClosed(ChannelClosedEvent event) async {
    final existing = await _storage.getPaymentChannel(event.channelId);
    if (existing == null) {
      return;
    }

    await _storage.storePaymentChannel(existing.copyWith(
      state: PaymentChannelState.closed,
      clientBalanceSats: event.finalClientBalanceSats,
      serverBalanceSats: event.finalServerBalanceSats,
      settlementTxId: event.settlementTxId,
      closedAt: event.timestamp,
    ));
  }

  Future<void> _handleRefundClaimed(RefundClaimedEvent event) async {
    final existing = await _storage.getPaymentChannel(event.channelId);
    if (existing == null) {
      return;
    }

    await _storage.storePaymentChannel(existing.copyWith(
      state: PaymentChannelState.expired,
      closedAt: event.timestamp,
    ));
  }

  Future<void> _handleChannelExpired(ChannelExpiredEvent event) async {
    final existing = await _storage.getPaymentChannel(event.channelId);
    if (existing == null) {
      return;
    }

    await _storage.storePaymentChannel(existing.copyWith(
      state: PaymentChannelState.expired,
      settlementTxId: event.settlementOrRefundTxId ?? existing.settlementTxId,
      closedAt: event.timestamp,
    ));
  }
}
