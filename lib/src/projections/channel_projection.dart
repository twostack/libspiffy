import 'package:eventador/eventador.dart';
import 'package:logging/logging.dart';
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
  final _log = Logger('ChannelProjection');
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
        FundingBroadcastStartedEvent,
        FundingBroadcastFailedEvent,
        FundingRecordedInWalletEvent,
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

    switch (event) {
      case final ChannelRequestedEvent evt:
        await _handleChannelRequested(evt);
        return true;
      case final ChannelAcceptedEvent evt:
        await _handleChannelAccepted(evt);
        return true;
      case final ChannelRejectedEvent evt:
        await _handleChannelRejected(evt);
        return true;
      case final ServerAcceptanceRecordedEvent evt:
        await _handleServerAcceptanceRecorded(evt);
        return true;
      case final RefundBuiltEvent evt:
        await _handleRefundBuilt(evt);
        return true;
      case final RefundCountersignedEvent evt:
        await _handleRefundCountersigned(evt);
        return true;
      case final FundingBroadcastStartedEvent evt:
        await _handleFundingBroadcastStarted(evt);
        return true;
      case final FundingBroadcastFailedEvent evt:
        await _handleFundingBroadcastFailed(evt);
        return true;
      case FundingRecordedInWalletEvent():
        // Channel-side bookkeeping only; the wallet read model holds the
        // transaction itself.
        return true;
      case final ChannelOpenedEvent evt:
        await _handleChannelOpened(evt);
        return true;
      case final PaymentRecordedEvent evt:
        await _handlePaymentRecorded(evt);
        return true;
      case final PaymentAcknowledgedEvent evt:
        await _handlePaymentAcknowledged(evt);
        return true;
      case ReturnLegRecordedInWalletEvent():
        // Channel-side bookkeeping only, as FundingRecordedInWalletEvent is:
        // it records that the WALLET write happened so an interrupted ending
        // can be resumed. The wallet read model holds the transaction itself,
        // and the channel row's own state is set by the closing or expiry
        // event (bead libspiffy-lfrv).
        return true;
      case final PaymentCountersignedEvent evt:
        await _handlePaymentCountersigned(evt);
        return true;
      case final ChannelClosingEvent evt:
        await _handleChannelClosing(evt);
        return true;
      case final ChannelClosedEvent evt:
        await _handleChannelClosed(evt);
        return true;
      case final RefundClaimedEvent evt:
        await _handleRefundClaimed(evt);
        return true;
      case final ChannelExpiredEvent evt:
        await _handleChannelExpired(evt);
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
        // The node's own peer id, when it was given one (libspiffy-36f).
        serverPeerId: event.serverPeerId ?? '',
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

    // Client side: the stored refund becomes the fully signed one the
    // aggregate verified (libspiffy-b83). The unsigned template stays in the
    // journal (RefundBuiltEvent) and is the signed transaction without its
    // unlocking script. Server side: the refund it signed and the funding
    // transaction that refund spends (libspiffy-fsy).
    await _storage.storePaymentChannel(existing.copyWith(
      refundServerSigHex: event.serverSignatureHex,
      refundTxHex: event.signedRefundTxHex ?? event.refundTxHex,
      fundingTxId: event.fundingTxId,
      fundingOutputIndex: event.fundingOutputIndex,
      fundingTxHex: event.fundingTxHex,
      state: PaymentChannelState.opening, // ChannelStatus.refundSigned → opening
    ));
  }

  Future<void> _handleFundingBroadcastStarted(
      FundingBroadcastStartedEvent event) async {
    final existing = await _storage.getPaymentChannel(event.channelId);
    if (existing == null) {
      return;
    }

    await _storage.storePaymentChannel(existing.copyWith(
      state: PaymentChannelState.funding,
      clearErrorMessage: true,
    ));
  }

  /// The channel stays unopened, awaiting funding, with the broadcast error.
  Future<void> _handleFundingBroadcastFailed(
      FundingBroadcastFailedEvent event) async {
    final existing = await _storage.getPaymentChannel(event.channelId);
    if (existing == null) {
      return;
    }

    await _storage.storePaymentChannel(existing.copyWith(
      state: PaymentChannelState.funding,
      errorMessage: 'Funding broadcast failed: ${event.error}',
    ));
  }

  Future<void> _handleChannelOpened(ChannelOpenedEvent event) async {
    final existing = await _storage.getPaymentChannel(event.channelId);
    if (existing == null) {
      return;
    }

    await _storage.storePaymentChannel(existing.copyWith(
      state: PaymentChannelState.open,
      clearErrorMessage: true,
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

  /// The client now holds the settlement both parties signed (bead
  /// libspiffy-z2px), in place of the unsigned template it recorded when it
  /// made the payment. Balances and sequence are untouched: they were settled
  /// by the payment this countersigns.
  Future<void> _handlePaymentCountersigned(PaymentCountersignedEvent event) async {
    final existing = await _storage.getPaymentChannel(event.channelId);
    if (existing == null) {
      return;
    }

    await _storage.storePaymentChannel(existing.copyWith(
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
      settlementTxId: _firstClosingTxId(existing, event.settlementTxId, event.channelId),
      closedAt: event.timestamp,
    ));
  }

  /// Records the transaction that reclaimed the funding output.
  ///
  /// Audit bead libspiffy-cqc (a): the txid the event carries used to be
  /// dropped here, so the read model could not say which transaction claimed
  /// the refund even though the wallet had been handed that fact.
  ///
  /// It lands in `settlementTxId`, the column [_handleChannelExpired] already
  /// uses for a refund txid: exactly one transaction can ever spend the 2-of-2
  /// funding output (BSV, first seen wins — a mined spend cannot be replaced),
  /// so a channel has exactly one closing txid, and `state` distinguishes a
  /// cooperative settlement (`closed`) from a refund (`expired`).
  Future<void> _handleRefundClaimed(RefundClaimedEvent event) async {
    final existing = await _storage.getPaymentChannel(event.channelId);
    if (existing == null) {
      return;
    }

    await _storage.storePaymentChannel(existing.copyWith(
      state: PaymentChannelState.expired,
      settlementTxId: _firstClosingTxId(existing, event.refundTxId, event.channelId),
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
      settlementTxId: _firstClosingTxId(existing, event.settlementOrRefundTxId, event.channelId),
      closedAt: event.timestamp,
    ));
  }

  /// The closing txid to store: the one already recorded if there is one, else
  /// [observed].
  ///
  /// Written once and never replaced (spv-understanding.md, Data Retention).
  /// A second, different txid for the same funding output cannot both be true
  /// — only one spend of an output is ever mined — and the first record is the
  /// one we can evidence, so a later observation never erases it. All three
  /// closing routes go through this, so the rule holds whichever order the
  /// events arrive in; a conflict is reported rather than silently dropped,
  /// because the wallet cannot adjudicate between two claimed spends without
  /// a proof and should not pretend it did.
  String? _firstClosingTxId(PaymentChannel existing, String? observed, String channelId) {
    final recorded = existing.settlementTxId;
    if (recorded == null) return observed;
    if (observed != null && observed != recorded) {
      _log.warning('Channel $channelId is already closed by $recorded; keeping it '
          'and not recording the conflicting $observed. Only one spend of the '
          'funding output can be mined.');
    }
    return recorded;
  }
}
