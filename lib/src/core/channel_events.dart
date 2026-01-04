import 'package:eventador/eventador.dart';

/// Base class for all channel events
abstract class ChannelEvent extends Event {
  final String channelId;

  ChannelEvent({
    required this.channelId,
    String? eventId,
    DateTime? timestamp,
    int? version,
    Map<String, dynamic>? metadata,
  }) : super(
          eventId: eventId,
          timestamp: timestamp,
          version: version,
          metadata: metadata,
        );

  /// Override to provide event-specific data for serialization
  Map<String, dynamic> getChannelEventData();

  @override
  Map<String, dynamic> toMap() {
    return {
      'type': runtimeType.toString(),  // Must match eventador's Event.toMap()
      'eventId': eventId,
      'timestamp': timestamp.toIso8601String(),
      'version': version,
      'channelId': channelId,
      'metadata': metadata,
      ...getChannelEventData(),
    };
  }

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
  final String walletId;
  final String clientPeerId;
  final String serverPeerId;
  final String clientPubKeyHex;
  final String clientAddressB58;
  final int derivationIndex;
  final BigInt fundingAmountSats;
  final int lockTimeUnix;
  final String? context;

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
      eventId: map['eventId'] as String?,
      timestamp: ChannelEvent._parseTimestamp(map['timestamp']),
      version: map['version'] as int?,
      metadata: map['metadata'] as Map<String, dynamic>?,
    );
  }
}

/// Server has accepted a channel request
class ChannelAcceptedEvent extends ChannelEvent {
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
        'clientPubKeyHex': clientPubKeyHex,
        'clientAddressB58': clientAddressB58,
        'serverPubKeyHex': serverPubKeyHex,
        'serverAddressB58': serverAddressB58,
        'derivationIndex': derivationIndex,
        'fundingAmountSats': fundingAmountSats.toString(),
        'lockTimeUnix': lockTimeUnix,
        'context': context,
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
      eventId: map['eventId'] as String?,
      timestamp: ChannelEvent._parseTimestamp(map['timestamp']),
      version: map['version'] as int?,
      metadata: map['metadata'] as Map<String, dynamic>?,
    );
  }
}

/// Server has rejected a channel request
class ChannelRejectedEvent extends ChannelEvent {
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

/// Refund transaction has been built (client side)
class RefundBuiltEvent extends ChannelEvent {
  final String fundingTxId;
  final int fundingOutputIndex;
  final String fundingTxHex;
  final String refundTxHex;
  final String clientSignatureHex;

  RefundBuiltEvent({
    required String channelId,
    required this.fundingTxId,
    required this.fundingOutputIndex,
    required this.fundingTxHex,
    required this.refundTxHex,
    required this.clientSignatureHex,
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
      };

  factory RefundBuiltEvent.fromMap(Map<String, dynamic> map) {
    return RefundBuiltEvent(
      channelId: map['channelId'] as String,
      fundingTxId: map['fundingTxId'] as String,
      fundingOutputIndex: map['fundingOutputIndex'] as int,
      fundingTxHex: map['fundingTxHex'] as String,
      refundTxHex: map['refundTxHex'] as String,
      clientSignatureHex: map['clientSignatureHex'] as String,
      eventId: map['eventId'] as String?,
      timestamp: ChannelEvent._parseTimestamp(map['timestamp']),
      version: map['version'] as int?,
      metadata: map['metadata'] as Map<String, dynamic>?,
    );
  }
}

/// Server has signed the refund transaction
class RefundCountersignedEvent extends ChannelEvent {
  final String serverSignatureHex;

  RefundCountersignedEvent({
    required String channelId,
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
        'serverSignatureHex': serverSignatureHex,
      };

  factory RefundCountersignedEvent.fromMap(Map<String, dynamic> map) {
    return RefundCountersignedEvent(
      channelId: map['channelId'] as String,
      serverSignatureHex: map['serverSignatureHex'] as String,
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

/// Channel is now open (funding TX broadcast)
class ChannelOpenedEvent extends ChannelEvent {
  final String fundingTxId;
  final int fundingOutputIndex;
  final String fundingTxHex;
  final List<String> fundingAncestorTxids;
  final BigInt initialClientBalanceSats;
  final BigInt initialServerBalanceSats;

  ChannelOpenedEvent({
    required String channelId,
    required this.fundingTxId,
    required this.fundingOutputIndex,
    required this.fundingTxHex,
    this.fundingAncestorTxids = const [],
    required this.initialClientBalanceSats,
    required this.initialServerBalanceSats,
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
        'fundingAncestorTxids': fundingAncestorTxids,
        'initialClientBalanceSats': initialClientBalanceSats.toString(),
        'initialServerBalanceSats': initialServerBalanceSats.toString(),
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

/// Payment has been acknowledged (server side - verified and countersigned)
class PaymentAcknowledgedEvent extends ChannelEvent {
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
  final String settlementTxId;
  final BigInt finalClientBalanceSats;
  final BigInt finalServerBalanceSats;

  ChannelClosedEvent({
    required String channelId,
    required this.settlementTxId,
    required this.finalClientBalanceSats,
    required this.finalServerBalanceSats,
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
      };

  factory ChannelClosedEvent.fromMap(Map<String, dynamic> map) {
    return ChannelClosedEvent(
      channelId: map['channelId'] as String,
      settlementTxId: map['settlementTxId'] as String,
      finalClientBalanceSats:
          BigInt.parse(map['finalClientBalanceSats'] as String),
      finalServerBalanceSats:
          BigInt.parse(map['finalServerBalanceSats'] as String),
      eventId: map['eventId'] as String?,
      timestamp: ChannelEvent._parseTimestamp(map['timestamp']),
      version: map['version'] as int?,
      metadata: map['metadata'] as Map<String, dynamic>?,
    );
  }
}

/// Refund has been claimed after channel expiry
class RefundClaimedEvent extends ChannelEvent {
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

