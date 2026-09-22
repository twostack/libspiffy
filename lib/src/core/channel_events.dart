import 'package:eventador/eventador.dart';

import '../models/persistent_map.dart';

/// Base class for all channel events.
///
/// An aggregate event of the `PaymentChannel` aggregate, keyed by
/// [channelId]. Serialization goes through [SerializableEvent], so the map
/// carries only [persistableMetadata]: transient values such as a `replyTo`
/// ActorRef stay on the in-memory event and never reach the journal (audit
/// 2026-09-14 L2).
abstract class ChannelEvent extends AggregateEventBase with SerializableEvent {
  final String channelId;

  ChannelEvent({
    required this.channelId,
    String? eventId,
    DateTime? timestamp,
    int? version,
    Map<String, dynamic>? metadata,
  }) : super(
          aggregateId: channelId,
          aggregateType: 'PaymentChannel',
          eventId: eventId,
          timestamp: timestamp,
          version: version,
          metadata: metadata,
        );

  /// Override to provide event-specific data for serialization
  Map<String, dynamic> getChannelEventData();

  @override
  Map<String, dynamic> getEventData() => {
        'channelId': channelId,
        ...getChannelEventData(),
      };

  /// Helper to parse timestamp from either String or DateTime
  /// Handles both Isar (preserves DateTime) and JSON/CBOR (stores as String)
  static DateTime? _parseTimestamp(dynamic value) {
    if (value == null) return null;
    if (value is DateTime) return value;
    if (value is String) return DateTime.parse(value);
    throw ArgumentError('Invalid timestamp type: ${value.runtimeType}');
  }
}

// =============================================================================
// CHANNEL LIFECYCLE EVENTS
// =============================================================================

/// Channel has been requested by a client
class ChannelRequestedEvent extends ChannelEvent {
  /// Journal identifier of this event type. Stored with every event and
  /// independent of the class name; never change it (audit 2026-09-14 M8).
  static const String stableTypeName = 'channel.requested';

  @override
  String get typeName => stableTypeName;

  final String walletId;
  final String clientPeerId;
  final String serverPeerId;
  final String clientPubKeyHex;
  final String clientAddressB58;
  final int derivationIndex;
  final BigInt fundingAmountSats;
  final int lockTimeUnix;
  final String? context;

  /// The app's opaque marker for the counterparty of this channel (bead
  /// libspiffy-bps1). Journaled so a restart can still stamp it on the
  /// wallet transactions the channel records. Null on rows written before
  /// it was journaled, and when the app supplied none — the recording then
  /// falls back to the counterparty's peer id.
  final String? counterpartyMarker;

  ChannelRequestedEvent({
    required String channelId,
    required this.walletId,
    required this.clientPeerId,
    required this.serverPeerId,
    required this.clientPubKeyHex,
    required this.clientAddressB58,
    required this.derivationIndex,
    required this.fundingAmountSats,
    required this.lockTimeUnix,
    this.context,
    this.counterpartyMarker,
    String? eventId,
    DateTime? timestamp,
    int? version,
    Map<String, dynamic>? metadata,
  }) : super(
          channelId: channelId,
          eventId: eventId,
          timestamp: timestamp,
          version: version,
          metadata: metadata,
        );

  @override
  Map<String, dynamic> getChannelEventData() => {
        'walletId': walletId,
        'clientPeerId': clientPeerId,
        'serverPeerId': serverPeerId,
        'clientPubKeyHex': clientPubKeyHex,
        'clientAddressB58': clientAddressB58,
        'derivationIndex': derivationIndex,
        'fundingAmountSats': fundingAmountSats.toString(),
        'lockTimeUnix': lockTimeUnix,
        'context': context,
        'counterpartyMarker': counterpartyMarker,
      };

  factory ChannelRequestedEvent.fromMap(Map<String, dynamic> map) {
    return ChannelRequestedEvent(
      channelId: map['channelId'] as String,
      walletId: map['walletId'] as String,
      clientPeerId: map['clientPeerId'] as String,
      serverPeerId: map['serverPeerId'] as String,
      clientPubKeyHex: map['clientPubKeyHex'] as String,
      clientAddressB58: map['clientAddressB58'] as String,
      derivationIndex: map['derivationIndex'] as int,
      fundingAmountSats: BigInt.parse(map['fundingAmountSats'] as String),
      lockTimeUnix: map['lockTimeUnix'] as int,
      context: map['context'] as String?,
      counterpartyMarker: map['counterpartyMarker'] as String?,
      eventId: map['eventId'] as String?,
      timestamp: ChannelEvent._parseTimestamp(map['timestamp']),
      version: map['version'] as int?,
      metadata: map['metadata'] as Map<String, dynamic>?,
    );
  }
}

/// Server has accepted a channel request
class ChannelAcceptedEvent extends ChannelEvent {
  /// Journal identifier of this event type. Stored with every event and
  /// independent of the class name; never change it (audit 2026-09-14 M8).
  static const String stableTypeName = 'channel.accepted';

  @override
  String get typeName => stableTypeName;

  final String walletId;
  final String clientPeerId;
  final String clientPubKeyHex;
  final String clientAddressB58;
  final String serverPubKeyHex;
  final String serverAddressB58;
  final int derivationIndex;
  final BigInt fundingAmountSats;
  final int lockTimeUnix;
  final String? context;

  /// The accepting node's own peer id (libspiffy-36f). Null in rows written
  /// before it was journaled, and when the node was not given one.
  final String? serverPeerId;

  /// The app's opaque marker for the counterparty of this channel (bead
  /// libspiffy-bps1). Journaled so a restart can still stamp it on the
  /// wallet transactions the channel records. Null on rows written before
  /// it was journaled, and when the app supplied none — the recording then
  /// falls back to the counterparty's peer id.
  final String? counterpartyMarker;

  ChannelAcceptedEvent({
    required String channelId,
    required this.walletId,
    required this.clientPeerId,
    required this.clientPubKeyHex,
    required this.clientAddressB58,
    required this.serverPubKeyHex,
    required this.serverAddressB58,
    required this.derivationIndex,
    required this.fundingAmountSats,
    required this.lockTimeUnix,
    this.context,
    this.serverPeerId,
    this.counterpartyMarker,
    String? eventId,
    DateTime? timestamp,
    int? version,
    Map<String, dynamic>? metadata,
  }) : super(
          channelId: channelId,
          eventId: eventId,
          timestamp: timestamp,
          version: version,
          metadata: metadata,
        );

  @override
  Map<String, dynamic> getChannelEventData() => {
        'walletId': walletId,
        'clientPeerId': clientPeerId,
        'serverPeerId': serverPeerId,
        'clientPubKeyHex': clientPubKeyHex,
        'clientAddressB58': clientAddressB58,
        'serverPubKeyHex': serverPubKeyHex,
        'serverAddressB58': serverAddressB58,
        'derivationIndex': derivationIndex,
        'fundingAmountSats': fundingAmountSats.toString(),
        'lockTimeUnix': lockTimeUnix,
        'context': context,
        'counterpartyMarker': counterpartyMarker,
      };

  factory ChannelAcceptedEvent.fromMap(Map<String, dynamic> map) {
    return ChannelAcceptedEvent(
      channelId: map['channelId'] as String,
      walletId: map['walletId'] as String,
      clientPeerId: map['clientPeerId'] as String,
      clientPubKeyHex: map['clientPubKeyHex'] as String,
      clientAddressB58: map['clientAddressB58'] as String,
      serverPubKeyHex: map['serverPubKeyHex'] as String,
      serverAddressB58: map['serverAddressB58'] as String,
      derivationIndex: map['derivationIndex'] as int,
      fundingAmountSats: BigInt.parse(map['fundingAmountSats'] as String),
      lockTimeUnix: map['lockTimeUnix'] as int,
      context: map['context'] as String?,
      serverPeerId: map['serverPeerId'] as String?,
      counterpartyMarker: map['counterpartyMarker'] as String?,
      eventId: map['eventId'] as String?,
      timestamp: ChannelEvent._parseTimestamp(map['timestamp']),
      version: map['version'] as int?,
      metadata: map['metadata'] as Map<String, dynamic>?,
    );
  }
}

/// Server has rejected a channel request
class ChannelRejectedEvent extends ChannelEvent {
  /// Journal identifier of this event type. Stored with every event and
  /// independent of the class name; never change it (audit 2026-09-14 M8).
  static const String stableTypeName = 'channel.rejected';

  @override
  String get typeName => stableTypeName;

  final String reason;

  ChannelRejectedEvent({
    required String channelId,
    required this.reason,
    String? eventId,
    DateTime? timestamp,
    int? version,
    Map<String, dynamic>? metadata,
  }) : super(
          channelId: channelId,
          eventId: eventId,
          timestamp: timestamp,
          version: version,
          metadata: metadata,
        );

  @override
  Map<String, dynamic> getChannelEventData() => {'reason': reason};

  factory ChannelRejectedEvent.fromMap(Map<String, dynamic> map) {
    return ChannelRejectedEvent(
      channelId: map['channelId'] as String,
      reason: map['reason'] as String,
      eventId: map['eventId'] as String?,
      timestamp: ChannelEvent._parseTimestamp(map['timestamp']),
      version: map['version'] as int?,
      metadata: map['metadata'] as Map<String, dynamic>?,
    );
  }
}

/// Client has recorded server's acceptance (server pubkey/address)
/// 
/// This event is emitted by the client's aggregate after receiving
/// the server's acceptance via P2P. It stores the server's cryptographic
/// info needed for building channel transactions.
class ServerAcceptanceRecordedEvent extends ChannelEvent {
  /// Journal identifier of this event type. Stored with every event and
  /// independent of the class name; never change it (audit 2026-09-14 M8).
  static const String stableTypeName = 'channel.server_acceptance_recorded';

  @override
  String get typeName => stableTypeName;

  final String serverPubKeyHex;
  final String serverAddressB58;

  ServerAcceptanceRecordedEvent({
    required String channelId,
    required this.serverPubKeyHex,
    required this.serverAddressB58,
    String? eventId,
    DateTime? timestamp,
    int? version,
    Map<String, dynamic>? metadata,
  }) : super(
          channelId: channelId,
          eventId: eventId,
          timestamp: timestamp,
          version: version,
          metadata: metadata,
        );

  @override
  Map<String, dynamic> getChannelEventData() => {
        'serverPubKeyHex': serverPubKeyHex,
        'serverAddressB58': serverAddressB58,
      };

  factory ServerAcceptanceRecordedEvent.fromMap(Map<String, dynamic> map) {
    return ServerAcceptanceRecordedEvent(
      channelId: map['channelId'] as String,
      serverPubKeyHex: map['serverPubKeyHex'] as String,
      serverAddressB58: map['serverAddressB58'] as String,
      eventId: map['eventId'] as String?,
      timestamp: ChannelEvent._parseTimestamp(map['timestamp']),
      version: map['version'] as int?,
      metadata: map['metadata'] as Map<String, dynamic>?,
    );
  }
}

// =============================================================================
// REFUND SIGNING EVENTS
// =============================================================================

/// Refund transaction has been built (client side).
///
/// Journals the unsigned refund template ([refundTxHex]), the client's own
/// signature on it and the signed funding transaction it spends, after the
/// aggregate checked that the funding output is the channel's 2-of-2 with
/// the agreed amount and that the refund carries the channel lockTime
/// (libspiffy-b83).
class RefundBuiltEvent extends ChannelEvent {
  /// Journal identifier of this event type. Stored with every event and
  /// independent of the class name; never change it (audit 2026-09-14 M8).
  static const String stableTypeName = 'channel.refund.built';

  @override
  String get typeName => stableTypeName;

  final String fundingTxId;
  final int fundingOutputIndex;
  final String fundingTxHex;
  final String refundTxHex;
  final String clientSignatureHex;

  /// Total value of the funding transaction's inputs, when known (null in
  /// rows written before libspiffy-9f7).
  final int? fundingInputSats;

  RefundBuiltEvent({
    required String channelId,
    required this.fundingTxId,
    required this.fundingOutputIndex,
    required this.fundingTxHex,
    required this.refundTxHex,
    required this.clientSignatureHex,
    this.fundingInputSats,
    String? eventId,
    DateTime? timestamp,
    int? version,
    Map<String, dynamic>? metadata,
  }) : super(
          channelId: channelId,
          eventId: eventId,
          timestamp: timestamp,
          version: version,
          metadata: metadata,
        );

  @override
  Map<String, dynamic> getChannelEventData() => {
        'fundingTxId': fundingTxId,
        'fundingOutputIndex': fundingOutputIndex,
        'fundingTxHex': fundingTxHex,
        'refundTxHex': refundTxHex,
        'clientSignatureHex': clientSignatureHex,
        'fundingInputSats': fundingInputSats,
      };

  factory RefundBuiltEvent.fromMap(Map<String, dynamic> map) {
    return RefundBuiltEvent(
      channelId: map['channelId'] as String,
      fundingTxId: map['fundingTxId'] as String,
      fundingOutputIndex: map['fundingOutputIndex'] as int,
      fundingTxHex: map['fundingTxHex'] as String,
      refundTxHex: map['refundTxHex'] as String,
      clientSignatureHex: map['clientSignatureHex'] as String,
      fundingInputSats: map['fundingInputSats'] as int?,
      eventId: map['eventId'] as String?,
      timestamp: ChannelEvent._parseTimestamp(map['timestamp']),
      version: map['version'] as int?,
      metadata: map['metadata'] as Map<String, dynamic>?,
    );
  }
}

/// Server has signed the refund transaction.
///
/// On the server side it records the server's signature. On the client side
/// it is journaled only once that signature verified, and carries the fully
/// signed refund ([signedRefundTxHex]: template plus both signatures, checked
/// by the script interpreter against the funding output) that lets the
/// client recover its funds after the lockTime (libspiffy-b83).
///
/// On the server side it also journals the refund it signed and the funding
/// transaction that refund spends (libspiffy-fsy): the channel may only be
/// opened for that funding transaction, and the state survives a restart.
class RefundCountersignedEvent extends ChannelEvent {
  /// Journal identifier of this event type. Stored with every event and
  /// independent of the class name; never change it (audit 2026-09-14 M8).
  static const String stableTypeName = 'channel.refund.countersigned';

  @override
  String get typeName => stableTypeName;

  final String serverSignatureHex;

  /// The fully signed refund transaction (client side). Null on the server
  /// side and in rows written before libspiffy-b83.
  final String? signedRefundTxHex;

  /// Server side (libspiffy-fsy): the refund template the server signed and
  /// the funding transaction it spends. Null on the client side and in rows
  /// written before they were journaled.
  final String? refundTxHex;
  final String? fundingTxId;
  final int? fundingOutputIndex;
  final String? fundingTxHex;

  RefundCountersignedEvent({
    required String channelId,
    required this.serverSignatureHex,
    this.signedRefundTxHex,
    this.refundTxHex,
    this.fundingTxId,
    this.fundingOutputIndex,
    this.fundingTxHex,
    String? eventId,
    DateTime? timestamp,
    int? version,
    Map<String, dynamic>? metadata,
  }) : super(
          channelId: channelId,
          eventId: eventId,
          timestamp: timestamp,
          version: version,
          metadata: metadata,
        );

  @override
  Map<String, dynamic> getChannelEventData() => {
        'serverSignatureHex': serverSignatureHex,
        'signedRefundTxHex': signedRefundTxHex,
        'refundTxHex': refundTxHex,
        'fundingTxId': fundingTxId,
        'fundingOutputIndex': fundingOutputIndex,
        'fundingTxHex': fundingTxHex,
      };

  factory RefundCountersignedEvent.fromMap(Map<String, dynamic> map) {
    return RefundCountersignedEvent(
      channelId: map['channelId'] as String,
      serverSignatureHex: map['serverSignatureHex'] as String,
      signedRefundTxHex: map['signedRefundTxHex'] as String?,
      refundTxHex: map['refundTxHex'] as String?,
      fundingTxId: map['fundingTxId'] as String?,
      fundingOutputIndex: map['fundingOutputIndex'] as int?,
      fundingTxHex: map['fundingTxHex'] as String?,
      eventId: map['eventId'] as String?,
      timestamp: ChannelEvent._parseTimestamp(map['timestamp']),
      version: map['version'] as int?,
      metadata: map['metadata'] as Map<String, dynamic>?,
    );
  }
}

// =============================================================================
// CHANNEL OPENING EVENTS
// =============================================================================

/// The client is about to broadcast its funding transaction (libspiffy-9f7).
///
/// Journaled before the transaction is handed to ARC, and only by a client
/// whose journal already holds the verified, fully signed refund: the
/// aggregate refuses it otherwise. [attempt] counts broadcasts of this
/// funding transaction (a retry after [FundingBroadcastFailedEvent] is the
/// next attempt).
class FundingBroadcastStartedEvent extends ChannelEvent {
  /// Journal identifier of this event type. Stored with every event and
  /// independent of the class name; never change it (audit 2026-09-14 M8).
  static const String stableTypeName = 'channel.funding.broadcast_started';

  @override
  String get typeName => stableTypeName;

  final String fundingTxId;
  final int attempt;

  FundingBroadcastStartedEvent({
    required String channelId,
    required this.fundingTxId,
    required this.attempt,
    String? eventId,
    DateTime? timestamp,
    int? version,
    Map<String, dynamic>? metadata,
  }) : super(
          channelId: channelId,
          eventId: eventId,
          timestamp: timestamp,
          version: version,
          metadata: metadata,
        );

  @override
  Map<String, dynamic> getChannelEventData() => {
        'fundingTxId': fundingTxId,
        'attempt': attempt,
      };

  factory FundingBroadcastStartedEvent.fromMap(Map<String, dynamic> map) {
    return FundingBroadcastStartedEvent(
      channelId: map['channelId'] as String,
      fundingTxId: map['fundingTxId'] as String,
      attempt: map['attempt'] as int,
      eventId: map['eventId'] as String?,
      timestamp: ChannelEvent._parseTimestamp(map['timestamp']),
      version: map['version'] as int?,
      metadata: map['metadata'] as Map<String, dynamic>?,
    );
  }
}

/// Broadcasting the client's funding transaction failed (libspiffy-9f7).
///
/// The channel does not open: it stays refund-signed, awaiting funding, and
/// the same funding transaction may be broadcast again (its inputs stay
/// reserved for it). [walletRecorded] says whether the transaction was
/// already recorded in the client wallet, so a retry does not record it
/// twice.
class FundingBroadcastFailedEvent extends ChannelEvent {
  /// Journal identifier of this event type. Stored with every event and
  /// independent of the class name; never change it (audit 2026-09-14 M8).
  static const String stableTypeName = 'channel.funding.broadcast_failed';

  @override
  String get typeName => stableTypeName;

  final String fundingTxId;
  final String error;
  final bool walletRecorded;

  FundingBroadcastFailedEvent({
    required String channelId,
    required this.fundingTxId,
    required this.error,
    required this.walletRecorded,
    String? eventId,
    DateTime? timestamp,
    int? version,
    Map<String, dynamic>? metadata,
  }) : super(
          channelId: channelId,
          eventId: eventId,
          timestamp: timestamp,
          version: version,
          metadata: metadata,
        );

  @override
  Map<String, dynamic> getChannelEventData() => {
        'fundingTxId': fundingTxId,
        'error': error,
        'walletRecorded': walletRecorded,
      };

  factory FundingBroadcastFailedEvent.fromMap(Map<String, dynamic> map) {
    return FundingBroadcastFailedEvent(
      channelId: map['channelId'] as String,
      fundingTxId: map['fundingTxId'] as String,
      error: map['error'] as String,
      walletRecorded: map['walletRecorded'] as bool? ?? false,
      eventId: map['eventId'] as String?,
      timestamp: ChannelEvent._parseTimestamp(map['timestamp']),
      version: map['version'] as int?,
      metadata: map['metadata'] as Map<String, dynamic>?,
    );
  }
}

/// The client wallet recorded the funding transaction (libspiffy-fsy).
///
/// Journaled once the wallet read model shows the transaction, before it is
/// handed to ARC: a broadcast resumed after a restart does not record the
/// funding transaction in the wallet again.
class FundingRecordedInWalletEvent extends ChannelEvent {
  /// Journal identifier of this event type. Stored with every event and
  /// independent of the class name; never change it (audit 2026-09-14 M8).
  static const String stableTypeName = 'channel.funding.wallet_recorded';

  @override
  String get typeName => stableTypeName;

  final String fundingTxId;

  FundingRecordedInWalletEvent({
    required String channelId,
    required this.fundingTxId,
    String? eventId,
    DateTime? timestamp,
    int? version,
    Map<String, dynamic>? metadata,
  }) : super(
          channelId: channelId,
          eventId: eventId,
          timestamp: timestamp,
          version: version,
          metadata: metadata,
        );

  @override
  Map<String, dynamic> getChannelEventData() => {'fundingTxId': fundingTxId};

  factory FundingRecordedInWalletEvent.fromMap(Map<String, dynamic> map) {
    return FundingRecordedInWalletEvent(
      channelId: map['channelId'] as String,
      fundingTxId: map['fundingTxId'] as String,
      eventId: map['eventId'] as String?,
      timestamp: ChannelEvent._parseTimestamp(map['timestamp']),
      version: map['version'] as int?,
      metadata: map['metadata'] as Map<String, dynamic>?,
    );
  }
}

/// Channel is now open (funding TX broadcast)
///
/// [fundingBeefHex] is the BEEF of the funding transaction (its ancestors
/// with their BUMPs): the one the client sent, and on the server the one it
/// SPV-validated before opening (libspiffy-fsy). Null in rows written before
/// it was journaled.
class ChannelOpenedEvent extends ChannelEvent {
  /// Journal identifier of this event type. Stored with every event and
  /// independent of the class name; never change it (audit 2026-09-14 M8).
  static const String stableTypeName = 'channel.opened';

  @override
  String get typeName => stableTypeName;

  final String fundingTxId;
  final int fundingOutputIndex;
  final String fundingTxHex;
  final List<String> fundingAncestorTxids;
  final BigInt initialClientBalanceSats;
  final BigInt initialServerBalanceSats;
  final String? fundingBeefHex;

  ChannelOpenedEvent({
    required String channelId,
    required this.fundingTxId,
    required this.fundingOutputIndex,
    required this.fundingTxHex,
    List<String> fundingAncestorTxids = const [],
    required this.initialClientBalanceSats,
    required this.initialServerBalanceSats,
    this.fundingBeefHex,
    String? eventId,
    DateTime? timestamp,
    int? version,
    Map<String, dynamic>? metadata,
  })  : fundingAncestorTxids = frozenList(fundingAncestorTxids),
        super(
          channelId: channelId,
          eventId: eventId,
          timestamp: timestamp,
          version: version,
          metadata: metadata,
        );

  @override
  Map<String, dynamic> getChannelEventData() => {
        'fundingTxId': fundingTxId,
        'fundingOutputIndex': fundingOutputIndex,
        'fundingTxHex': fundingTxHex,
        'fundingAncestorTxids': fundingAncestorTxids,
        'initialClientBalanceSats': initialClientBalanceSats.toString(),
        'initialServerBalanceSats': initialServerBalanceSats.toString(),
        'fundingBeefHex': fundingBeefHex,
      };

  factory ChannelOpenedEvent.fromMap(Map<String, dynamic> map) {
    return ChannelOpenedEvent(
      channelId: map['channelId'] as String,
      fundingTxId: map['fundingTxId'] as String,
      fundingOutputIndex: map['fundingOutputIndex'] as int,
      fundingTxHex: map['fundingTxHex'] as String,
      fundingAncestorTxids: List<String>.from(map['fundingAncestorTxids'] ?? []),
      initialClientBalanceSats:
          BigInt.parse(map['initialClientBalanceSats'] as String),
      initialServerBalanceSats:
          BigInt.parse(map['initialServerBalanceSats'] as String),
      fundingBeefHex: map['fundingBeefHex'] as String?,
      eventId: map['eventId'] as String?,
      timestamp: ChannelEvent._parseTimestamp(map['timestamp']),
      version: map['version'] as int?,
      metadata: map['metadata'] as Map<String, dynamic>?,
    );
  }
}

// =============================================================================
// PAYMENT EVENTS
// =============================================================================

/// Payment has been recorded (client side - built and signed)
class PaymentRecordedEvent extends ChannelEvent {
  /// Journal identifier of this event type. Stored with every event and
  /// independent of the class name; never change it (audit 2026-09-14 M8).
  static const String stableTypeName = 'channel.payment.recorded';

  @override
  String get typeName => stableTypeName;

  final BigInt amountSats;
  final BigInt newClientBalanceSats;
  final BigInt newServerBalanceSats;
  final int sequenceNumber;
  final String paymentTxHex;
  final String paymentTxId;
  final String clientSignatureHex;
  final String? purpose;
  final String? invoiceId;

  PaymentRecordedEvent({
    required String channelId,
    required this.amountSats,
    required this.newClientBalanceSats,
    required this.newServerBalanceSats,
    required this.sequenceNumber,
    required this.paymentTxHex,
    required this.paymentTxId,
    required this.clientSignatureHex,
    this.purpose,
    this.invoiceId,
    String? eventId,
    DateTime? timestamp,
    int? version,
    Map<String, dynamic>? metadata,
  }) : super(
          channelId: channelId,
          eventId: eventId,
          timestamp: timestamp,
          version: version,
          metadata: metadata,
        );

  @override
  Map<String, dynamic> getChannelEventData() => {
        'amountSats': amountSats.toString(),
        'newClientBalanceSats': newClientBalanceSats.toString(),
        'newServerBalanceSats': newServerBalanceSats.toString(),
        'sequenceNumber': sequenceNumber,
        'paymentTxHex': paymentTxHex,
        'paymentTxId': paymentTxId,
        'clientSignatureHex': clientSignatureHex,
        'purpose': purpose,
        'invoiceId': invoiceId,
      };

  factory PaymentRecordedEvent.fromMap(Map<String, dynamic> map) {
    return PaymentRecordedEvent(
      channelId: map['channelId'] as String,
      amountSats: BigInt.parse(map['amountSats'] as String),
      newClientBalanceSats: BigInt.parse(map['newClientBalanceSats'] as String),
      newServerBalanceSats: BigInt.parse(map['newServerBalanceSats'] as String),
      sequenceNumber: map['sequenceNumber'] as int,
      paymentTxHex: map['paymentTxHex'] as String,
      paymentTxId: map['paymentTxId'] as String,
      clientSignatureHex: map['clientSignatureHex'] as String,
      purpose: map['purpose'] as String?,
      invoiceId: map['invoiceId'] as String?,
      eventId: map['eventId'] as String?,
      timestamp: ChannelEvent._parseTimestamp(map['timestamp']),
      version: map['version'] as int?,
      metadata: map['metadata'] as Map<String, dynamic>?,
    );
  }
}

/// This side's wallet holds the transaction that ended the channel and paid
/// it back (bead libspiffy-lfrv).
///
/// The counterpart of [FundingRecordedInWalletEvent]: the channel's own
/// record that the wallet write happened, so a close or an expiry interrupted
/// between journaling its outcome and writing the wallet can be resumed
/// instead of silently losing the money coming back.
class ReturnLegRecordedInWalletEvent extends ChannelEvent {
  /// Journal identifier of this event type. Stored with every event and
  /// independent of the class name; never change it (audit 2026-09-14 M8).
  static const String stableTypeName = 'channel.return_leg.wallet_recorded';

  @override
  String get typeName => stableTypeName;

  /// The transaction recorded: a cooperative settlement, or a refund.
  final String txId;

  ReturnLegRecordedInWalletEvent({
    required String channelId,
    required this.txId,
    String? eventId,
    DateTime? timestamp,
    int? version,
    Map<String, dynamic>? metadata,
  }) : super(
          channelId: channelId,
          eventId: eventId,
          timestamp: timestamp,
          version: version,
          metadata: metadata,
        );

  @override
  Map<String, dynamic> getChannelEventData() => {'txId': txId};

  factory ReturnLegRecordedInWalletEvent.fromMap(Map<String, dynamic> map) {
    return ReturnLegRecordedInWalletEvent(
      channelId: map['channelId'] as String,
      txId: map['txId'] as String,
      eventId: map['eventId'] as String?,
      timestamp: ChannelEvent._parseTimestamp(map['timestamp']),
      version: map['version'] as int?,
      metadata: map['metadata'] as Map<String, dynamic>?,
    );
  }
}

/// The client held the server's countersignature of the latest payment
/// (bead libspiffy-z2px).
///
/// No longer journaled: the server sends no signature, because with it the
/// client held a spend of every state and could broadcast the one paying
/// the server least (bead libspiffy-pkg5). The client closes with the
/// settlement the server broadcast instead. Kept, registered and applied so
/// journals that hold it replay (Data Retention).
@Deprecated('Replay only: clients no longer journal a countersignature (libspiffy-pkg5)')
class PaymentCountersignedEvent extends ChannelEvent {
  /// Journal identifier of this event type. Stored with every event and
  /// independent of the class name; never change it (audit 2026-09-14 M8).
  static const String stableTypeName = 'channel.payment.countersigned';

  @override
  String get typeName => stableTypeName;

  final int sequenceNumber;
  final String serverSignatureHex;

  /// The settlement as both parties signed it, verified against the funding
  /// output before this event was emitted.
  final String fullySignedPaymentTxHex;

  /// Its txid — the one the signed transaction really has, which the
  /// template's is not.
  final String fullySignedPaymentTxId;

  PaymentCountersignedEvent({
    required String channelId,
    required this.sequenceNumber,
    required this.serverSignatureHex,
    required this.fullySignedPaymentTxHex,
    required this.fullySignedPaymentTxId,
    String? eventId,
    DateTime? timestamp,
    int? version,
    Map<String, dynamic>? metadata,
  }) : super(
          channelId: channelId,
          eventId: eventId,
          timestamp: timestamp,
          version: version,
          metadata: metadata,
        );

  @override
  Map<String, dynamic> getChannelEventData() => {
        'sequenceNumber': sequenceNumber,
        'serverSignatureHex': serverSignatureHex,
        'fullySignedPaymentTxHex': fullySignedPaymentTxHex,
        'fullySignedPaymentTxId': fullySignedPaymentTxId,
      };

  factory PaymentCountersignedEvent.fromMap(Map<String, dynamic> map) {
    return PaymentCountersignedEvent(
      channelId: map['channelId'] as String,
      sequenceNumber: map['sequenceNumber'] as int,
      serverSignatureHex: map['serverSignatureHex'] as String,
      fullySignedPaymentTxHex: map['fullySignedPaymentTxHex'] as String,
      fullySignedPaymentTxId: map['fullySignedPaymentTxId'] as String,
      eventId: map['eventId'] as String?,
      timestamp: ChannelEvent._parseTimestamp(map['timestamp']),
      version: map['version'] as int?,
      metadata: map['metadata'] as Map<String, dynamic>?,
    );
  }
}

/// Payment has been acknowledged (server side - verified and countersigned)
class PaymentAcknowledgedEvent extends ChannelEvent {
  /// Journal identifier of this event type. Stored with every event and
  /// independent of the class name; never change it (audit 2026-09-14 M8).
  static const String stableTypeName = 'channel.payment.acknowledged';

  @override
  String get typeName => stableTypeName;

  final BigInt amountSats;
  final int sequenceNumber;
  final BigInt newClientBalanceSats;
  final BigInt newServerBalanceSats;
  final String fullySignedPaymentTxHex;
  final String serverSignatureHex;

  PaymentAcknowledgedEvent({
    required String channelId,
    required this.amountSats,
    required this.sequenceNumber,
    required this.newClientBalanceSats,
    required this.newServerBalanceSats,
    required this.fullySignedPaymentTxHex,
    required this.serverSignatureHex,
    String? eventId,
    DateTime? timestamp,
    int? version,
    Map<String, dynamic>? metadata,
  }) : super(
          channelId: channelId,
          eventId: eventId,
          timestamp: timestamp,
          version: version,
          metadata: metadata,
        );

  @override
  Map<String, dynamic> getChannelEventData() => {
        'amountSats': amountSats.toString(),
        'sequenceNumber': sequenceNumber,
        'newClientBalanceSats': newClientBalanceSats.toString(),
        'newServerBalanceSats': newServerBalanceSats.toString(),
        'fullySignedPaymentTxHex': fullySignedPaymentTxHex,
        'serverSignatureHex': serverSignatureHex,
      };

  factory PaymentAcknowledgedEvent.fromMap(Map<String, dynamic> map) {
    return PaymentAcknowledgedEvent(
      channelId: map['channelId'] as String,
      amountSats: BigInt.parse(map['amountSats'] as String),
      sequenceNumber: map['sequenceNumber'] as int,
      newClientBalanceSats: BigInt.parse(map['newClientBalanceSats'] as String),
      newServerBalanceSats: BigInt.parse(map['newServerBalanceSats'] as String),
      fullySignedPaymentTxHex: map['fullySignedPaymentTxHex'] as String,
      serverSignatureHex: map['serverSignatureHex'] as String,
      eventId: map['eventId'] as String?,
      timestamp: ChannelEvent._parseTimestamp(map['timestamp']),
      version: map['version'] as int?,
      metadata: map['metadata'] as Map<String, dynamic>?,
    );
  }
}

// =============================================================================
// CHANNEL CLOSING EVENTS
// =============================================================================

/// Channel close has been initiated
class ChannelClosingEvent extends ChannelEvent {
  /// Journal identifier of this event type. Stored with every event and
  /// independent of the class name; never change it (audit 2026-09-14 M8).
  static const String stableTypeName = 'channel.closing';

  @override
  String get typeName => stableTypeName;

  final String? reason;
  final String initiator; // 'client' or 'server'
  final BigInt clientBalanceSats;
  final BigInt serverBalanceSats;

  ChannelClosingEvent({
    required String channelId,
    this.reason,
    required this.initiator,
    required this.clientBalanceSats,
    required this.serverBalanceSats,
    String? eventId,
    DateTime? timestamp,
    int? version,
    Map<String, dynamic>? metadata,
  }) : super(
          channelId: channelId,
          eventId: eventId,
          timestamp: timestamp,
          version: version,
          metadata: metadata,
        );

  @override
  Map<String, dynamic> getChannelEventData() => {
        'reason': reason,
        'initiator': initiator,
        'clientBalanceSats': clientBalanceSats.toString(),
        'serverBalanceSats': serverBalanceSats.toString(),
      };

  factory ChannelClosingEvent.fromMap(Map<String, dynamic> map) {
    return ChannelClosingEvent(
      channelId: map['channelId'] as String,
      reason: map['reason'] as String?,
      initiator: map['initiator'] as String,
      clientBalanceSats: BigInt.parse(map['clientBalanceSats'] as String? ?? '0'),
      serverBalanceSats: BigInt.parse(map['serverBalanceSats'] as String? ?? '0'),
      eventId: map['eventId'] as String?,
      timestamp: ChannelEvent._parseTimestamp(map['timestamp']),
      version: map['version'] as int?,
      metadata: map['metadata'] as Map<String, dynamic>?,
    );
  }
}

/// Channel has been closed (settlement TX broadcast)
class ChannelClosedEvent extends ChannelEvent {
  /// Journal identifier of this event type. Stored with every event and
  /// independent of the class name; never change it (audit 2026-09-14 M8).
  static const String stableTypeName = 'channel.closed';

  @override
  String get typeName => stableTypeName;

  final String settlementTxId;
  final BigInt finalClientBalanceSats;
  final BigInt finalServerBalanceSats;

  /// The settlement itself (bead libspiffy-u6q6): the server broadcast it,
  /// and hands it to the client in `channel_closed` so the client can
  /// record its return leg. Null in events journaled before it was kept.
  final String? settlementTxHex;

  ChannelClosedEvent({
    required String channelId,
    required this.settlementTxId,
    required this.finalClientBalanceSats,
    required this.finalServerBalanceSats,
    this.settlementTxHex,
    String? eventId,
    DateTime? timestamp,
    int? version,
    Map<String, dynamic>? metadata,
  }) : super(
          channelId: channelId,
          eventId: eventId,
          timestamp: timestamp,
          version: version,
          metadata: metadata,
        );

  @override
  Map<String, dynamic> getChannelEventData() => {
        'settlementTxId': settlementTxId,
        'finalClientBalanceSats': finalClientBalanceSats.toString(),
        'finalServerBalanceSats': finalServerBalanceSats.toString(),
        if (settlementTxHex != null) 'settlementTxHex': settlementTxHex,
      };

  factory ChannelClosedEvent.fromMap(Map<String, dynamic> map) {
    return ChannelClosedEvent(
      channelId: map['channelId'] as String,
      settlementTxId: map['settlementTxId'] as String,
      finalClientBalanceSats:
          BigInt.parse(map['finalClientBalanceSats'] as String),
      finalServerBalanceSats:
          BigInt.parse(map['finalServerBalanceSats'] as String),
      settlementTxHex: map['settlementTxHex'] as String?,
      eventId: map['eventId'] as String?,
      timestamp: ChannelEvent._parseTimestamp(map['timestamp']),
      version: map['version'] as int?,
      metadata: map['metadata'] as Map<String, dynamic>?,
    );
  }
}

/// Channel has expired (lockTime elapsed).
///
/// Emitted when a channel's lockTime has passed and the periodic expiry
/// monitor records the expiry through the aggregate. Distinct from:
/// - [ChannelClosedEvent]: cooperative close via settlement TX.
/// - [RefundClaimedEvent]: client successfully reclaimed funding via refund TX.
///
/// This event captures the read-model transition to `expired` regardless of
/// whether a refund/settlement TX was broadcast. The optional [settlementOrRefundTxId]
/// records the broadcast txid if any (best-effort — the broadcast itself is
/// handled out-of-band by the expiry manager).
class ChannelExpiredEvent extends ChannelEvent {
  /// Journal identifier of this event type. Stored with every event and
  /// independent of the class name; never change it (audit 2026-09-14 M8).
  static const String stableTypeName = 'channel.expired';

  @override
  String get typeName => stableTypeName;

  /// Optional txid of refund (client) or settlement (server) TX broadcast
  /// in response to the expiry. Null when nothing was broadcast (e.g., no
  /// refund TX available, or server received no payments).
  final String? settlementOrRefundTxId;

  /// 'client' or 'server' — captures which side observed and recorded the expiry.
  final String observedBy;

  ChannelExpiredEvent({
    required String channelId,
    required this.observedBy,
    this.settlementOrRefundTxId,
    String? eventId,
    DateTime? timestamp,
    int? version,
    Map<String, dynamic>? metadata,
  }) : super(
          channelId: channelId,
          eventId: eventId,
          timestamp: timestamp,
          version: version,
          metadata: metadata,
        );

  @override
  Map<String, dynamic> getChannelEventData() => {
        'observedBy': observedBy,
        'settlementOrRefundTxId': settlementOrRefundTxId,
      };

  factory ChannelExpiredEvent.fromMap(Map<String, dynamic> map) {
    return ChannelExpiredEvent(
      channelId: map['channelId'] as String,
      observedBy: map['observedBy'] as String,
      settlementOrRefundTxId: map['settlementOrRefundTxId'] as String?,
      eventId: map['eventId'] as String?,
      timestamp: ChannelEvent._parseTimestamp(map['timestamp']),
      version: map['version'] as int?,
      metadata: map['metadata'] as Map<String, dynamic>?,
    );
  }
}

/// Refund has been claimed after channel expiry
class RefundClaimedEvent extends ChannelEvent {
  /// Journal identifier of this event type. Stored with every event and
  /// independent of the class name; never change it (audit 2026-09-14 M8).
  static const String stableTypeName = 'channel.refund.claimed';

  @override
  String get typeName => stableTypeName;

  final String refundTxId;
  final BigInt refundAmountSats;

  RefundClaimedEvent({
    required String channelId,
    required this.refundTxId,
    required this.refundAmountSats,
    String? eventId,
    DateTime? timestamp,
    int? version,
    Map<String, dynamic>? metadata,
  }) : super(
          channelId: channelId,
          eventId: eventId,
          timestamp: timestamp,
          version: version,
          metadata: metadata,
        );

  @override
  Map<String, dynamic> getChannelEventData() => {
        'refundTxId': refundTxId,
        'refundAmountSats': refundAmountSats.toString(),
      };

  factory RefundClaimedEvent.fromMap(Map<String, dynamic> map) {
    return RefundClaimedEvent(
      channelId: map['channelId'] as String,
      refundTxId: map['refundTxId'] as String,
      refundAmountSats: BigInt.parse(map['refundAmountSats'] as String),
      eventId: map['eventId'] as String?,
      timestamp: ChannelEvent._parseTimestamp(map['timestamp']),
      version: map['version'] as int?,
      metadata: map['metadata'] as Map<String, dynamic>?,
    );
  }
}

