/// High-level messages for PaymentChannelManager actor
/// 
/// These messages provide a simplified interface for payment channel operations.
/// The PaymentChannelManager handles all the orchestration between WalletManager
/// and PaymentChannelAggregate.

import 'package:dactor/dactor.dart';

// =============================================================================
// CHANNEL LIFECYCLE MESSAGES
// =============================================================================

/// Request to initiate a new payment channel as client
class InitiateChannelMessage extends LocalMessage {
  final String channelId;
  final String walletId;
  final String clientPeerId;
  final String serverPeerId;
  final BigInt fundingAmountSats;
  final int lockTimeDurationSeconds;
  final String? context;

  InitiateChannelMessage({
    required this.channelId,
    required this.walletId,
    required this.clientPeerId,
    required this.serverPeerId,
    required this.fundingAmountSats,
    required this.lockTimeDurationSeconds,
    this.context,
  }) : super(payload: null);

  @override
  dynamic get payload => this;
}

/// Response to channel initiation
class ChannelInitiatedResponse extends LocalMessage {
  final String channelId;
  final String clientPubKeyHex;
  final String clientAddressB58;
  final int derivationIndex;
  final int lockTimeUnix;
  final bool success;
  final String? error;

  ChannelInitiatedResponse({
    required this.channelId,
    required this.clientPubKeyHex,
    required this.clientAddressB58,
    required this.derivationIndex,
    required this.lockTimeUnix,
    required this.success,
    this.error,
  }) : super(payload: null);

  @override
  dynamic get payload => this;
}

/// Request to accept a channel as server
class AcceptChannelMessage extends LocalMessage {
  final String channelId;
  final String walletId;
  final String clientPeerId;
  final String clientPubKeyHex;
  final String clientAddressB58;
  final BigInt fundingAmountSats;
  final int lockTimeUnix;
  final String? context;

  AcceptChannelMessage({
    required this.channelId,
    required this.walletId,
    required this.clientPeerId,
    required this.clientPubKeyHex,
    required this.clientAddressB58,
    required this.fundingAmountSats,
    required this.lockTimeUnix,
    this.context,
  }) : super(payload: null);

  @override
  dynamic get payload => this;
}

/// Response to channel acceptance
class ChannelAcceptedResponse extends LocalMessage {
  final String channelId;
  final String serverPubKeyHex;
  final String serverAddressB58;
  final int derivationIndex;
  final bool success;
  final String? error;

  ChannelAcceptedResponse({
    required this.channelId,
    required this.serverPubKeyHex,
    required this.serverAddressB58,
    required this.derivationIndex,
    required this.success,
    this.error,
  }) : super(payload: null);

  @override
  dynamic get payload => this;
}

/// Client records that server accepted the channel (stores server pubkey/address)
class RecordServerAcceptanceMessage extends LocalMessage {
  final String channelId;
  final String serverPubKeyHex;
  final String serverAddressB58;

  RecordServerAcceptanceMessage({
    required this.channelId,
    required this.serverPubKeyHex,
    required this.serverAddressB58,
  }) : super(payload: null);

  @override
  dynamic get payload => this;
}

// =============================================================================
// REFUND TRANSACTION MESSAGES
// =============================================================================

/// Request to build refund transaction (client side, after server accepts)
class BuildRefundTransactionMessage extends LocalMessage {
  final String channelId;
  final String walletId;
  final String fundingTxId;
  final int fundingOutputIndex;
  final BigInt fundingAmountSats;
  final String clientPubKeyHex;
  final String clientAddressB58;
  final String serverPubKeyHex;
  final String serverAddressB58;
  final int lockTimeUnix;

  BuildRefundTransactionMessage({
    required this.channelId,
    required this.walletId,
    required this.fundingTxId,
    required this.fundingOutputIndex,
    required this.fundingAmountSats,
    required this.clientPubKeyHex,
    required this.clientAddressB58,
    required this.serverPubKeyHex,
    required this.serverAddressB58,
    required this.lockTimeUnix,
  }) : super(payload: null);

  @override
  dynamic get payload => this;
}

/// Response with built refund transaction
class RefundTransactionBuiltResponse extends LocalMessage {
  final String channelId;
  final String refundTxHex;
  final bool success;
  final String? error;

  RefundTransactionBuiltResponse({
    required this.channelId,
    required this.refundTxHex,
    required this.success,
    this.error,
  }) : super(payload: null);

  @override
  dynamic get payload => this;
}

/// Request to sign refund transaction (server side)
class SignRefundTransactionMessage extends LocalMessage {
  final String channelId;
  final String walletId;
  final String refundTxHex;
  final String clientPubKeyHex;
  final String serverPubKeyHex;
  final String serverAddressB58;
  final int derivationIndex;
  final BigInt fundingAmountSats;
  final int lockTimeUnix;

  SignRefundTransactionMessage({
    required this.channelId,
    required this.walletId,
    required this.refundTxHex,
    required this.clientPubKeyHex,
    required this.serverPubKeyHex,
    required this.serverAddressB58,
    required this.derivationIndex,
    required this.fundingAmountSats,
    required this.lockTimeUnix,
  }) : super(payload: null);

  @override
  dynamic get payload => this;
}

/// Response with refund signature
class RefundTransactionSignedResponse extends LocalMessage {
  final String channelId;
  final String serverSignatureHex;
  final bool success;
  final String? error;

  RefundTransactionSignedResponse({
    required this.channelId,
    required this.serverSignatureHex,
    required this.success,
    this.error,
  }) : super(payload: null);

  @override
  dynamic get payload => this;
}

/// Request to record server's refund signature (client side, received via P2P)
class RecordRefundSignatureMessage extends LocalMessage {
  final String channelId;
  final String serverSignatureHex;

  RecordRefundSignatureMessage({
    required this.channelId,
    required this.serverSignatureHex,
  }) : super(payload: null);

  @override
  dynamic get payload => this;
}

/// Response to recording refund signature
class RefundSignatureRecordedResponse extends LocalMessage {
  final String channelId;
  final bool success;
  final String? error;

  RefundSignatureRecordedResponse({
    required this.channelId,
    required this.success,
    this.error,
  }) : super(payload: null);

  @override
  dynamic get payload => this;
}

// =============================================================================
// CHANNEL OPENING MESSAGES
// =============================================================================

/// Message to finalize channel opening after funding TX is broadcast
class OpenChannelMessage extends LocalMessage {
  final String channelId;
  final String fundingTxId;
  final int fundingOutputIndex;
  final String fundingTxHex;

  OpenChannelMessage({
    required this.channelId,
    required this.fundingTxId,
    required this.fundingOutputIndex,
    required this.fundingTxHex,
  }) : super(payload: null);

  @override
  dynamic get payload => this;
}

/// Response to channel opening
class ChannelOpenedResponse extends LocalMessage {
  final String channelId;
  final bool success;
  final String? error;

  ChannelOpenedResponse({
    required this.channelId,
    required this.success,
    this.error,
  }) : super(payload: null);

  @override
  dynamic get payload => this;
}

// =============================================================================
// PAYMENT MESSAGES
// =============================================================================

/// Request to record a payment as client
class RecordPaymentMessage extends LocalMessage {
  final String channelId;
  final String walletId;
  final BigInt amountSats;
  final String? purpose;
  final String? invoiceId;

  RecordPaymentMessage({
    required this.channelId,
    required this.walletId,
    required this.amountSats,
    this.purpose,
    this.invoiceId,
  }) : super(payload: null);

  @override
  dynamic get payload => this;
}

/// Response to payment recording
class PaymentRecordedResponse extends LocalMessage {
  final String channelId;
  final BigInt amountSats;
  final int sequenceNumber;
  final String paymentTxHex;
  final String clientSignatureHex;
  final BigInt newClientBalanceSats;
  final BigInt newServerBalanceSats;
  final bool success;
  final String? error;

  PaymentRecordedResponse({
    required this.channelId,
    required this.amountSats,
    required this.sequenceNumber,
    required this.paymentTxHex,
    required this.clientSignatureHex,
    required this.newClientBalanceSats,
    required this.newServerBalanceSats,
    required this.success,
    this.error,
  }) : super(payload: null);

  @override
  dynamic get payload => this;
}

/// Request to acknowledge a payment as server
class AcknowledgePaymentMessage extends LocalMessage {
  final String channelId;
  final String walletId;
  final BigInt amountSats;  // Incremental payment amount
  final String paymentTxHex;
  final String clientSignatureHex;
  final int proposedSequence;
  final BigInt proposedClientBalance;
  final BigInt proposedServerBalance;

  AcknowledgePaymentMessage({
    required this.channelId,
    required this.walletId,
    required this.amountSats,
    required this.paymentTxHex,
    required this.clientSignatureHex,
    required this.proposedSequence,
    required this.proposedClientBalance,
    required this.proposedServerBalance,
  }) : super(payload: null);

  @override
  dynamic get payload => this;
}

/// Response to payment acknowledgment
class PaymentAcknowledgedResponse extends LocalMessage {
  final String channelId;
  final int sequenceNumber;
  final String fullySignedPaymentTxHex;
  final String serverSignatureHex;
  final bool success;
  final String? error;

  PaymentAcknowledgedResponse({
    required this.channelId,
    this.sequenceNumber = 0,
    this.fullySignedPaymentTxHex = '',
    this.serverSignatureHex = '',
    required this.success,
    this.error,
  }) : super(payload: null);

  @override
  dynamic get payload => this;
}

// =============================================================================
// CHANNEL CLOSING MESSAGES
// =============================================================================

/// Request to close a channel
class CloseChannelMessage extends LocalMessage {
  final String channelId;
  final String? reason;

  CloseChannelMessage({
    required this.channelId,
    this.reason,
  }) : super(payload: null);

  @override
  dynamic get payload => this;
}

/// Request to record that a channel has expired (lockTime elapsed).
///
/// Sent by the expiry monitor when it detects a channel past its lockTime.
/// Routes to `PaymentChannelAggregate` via [ExpireChannelCommand], emitting
/// [ChannelExpiredEvent] so the read model picks up the transition.
class ExpireChannelMessage extends LocalMessage {
  final String channelId;
  final String observedBy; // 'client' or 'server'
  final String? settlementOrRefundTxId;

  ExpireChannelMessage({
    required this.channelId,
    required this.observedBy,
    this.settlementOrRefundTxId,
  }) : super(payload: null);

  @override
  dynamic get payload => this;
}

/// Response to channel expiry recording
class ChannelExpiredResponse extends LocalMessage {
  final String channelId;
  final bool success;
  final String? error;

  ChannelExpiredResponse({
    required this.channelId,
    required this.success,
    this.error,
  }) : super(payload: null);

  @override
  dynamic get payload => this;
}

/// Response to channel close
class ChannelClosedResponse extends LocalMessage {
  final String channelId;
  final bool success;
  final String? error;

  ChannelClosedResponse({
    required this.channelId,
    required this.success,
    this.error,
  }) : super(payload: null);

  @override
  dynamic get payload => this;
}

// =============================================================================
// QUERY MESSAGES
// =============================================================================

/// Query current state of a channel
class QueryChannelStateMessage extends LocalMessage {
  final String channelId;

  QueryChannelStateMessage({
    required this.channelId,
  }) : super(payload: null);

  @override
  dynamic get payload => this;
}

/// Response with channel state
class ChannelStateResponse extends LocalMessage {
  final String channelId;
  final String status;
  final BigInt? clientBalanceSats;
  final BigInt? serverBalanceSats;
  final int? latestSequenceNumber;
  final bool success;
  final String? error;

  ChannelStateResponse({
    required this.channelId,
    required this.status,
    this.clientBalanceSats,
    this.serverBalanceSats,
    this.latestSequenceNumber,
    required this.success,
    this.error,
  }) : super(payload: null);

  @override
  dynamic get payload => this;
}

/// Direct query to aggregate for full state (for building transactions)
class ChannelStateQuery extends LocalMessage {
  final String channelId;

  ChannelStateQuery({
    required this.channelId,
  }) : super(payload: null);

  @override
  dynamic get payload => this;
}

/// Full channel state response from aggregate (for building transactions)
class FullChannelStateResponse extends LocalMessage {
  final String channelId;
  final String walletId;
  final String status;
  final String? role;
  final BigInt clientBalanceSats;
  final BigInt serverBalanceSats;
  final int latestSequenceNumber;
  final BigInt fundingAmountSats;
  final String? fundingTxId;
  final String? fundingTxHex;
  final int? fundingOutputIndex;
  final String? clientPubKeyHex;
  final String? serverPubKeyHex;
  final String? clientAddressB58;
  final String? serverAddressB58;
  final int? derivationIndex;
  final int? lockTimeUnix;
  final bool success;
  final String? error;

  FullChannelStateResponse({
    required this.channelId,
    required this.walletId,
    required this.status,
    this.role,
    required this.clientBalanceSats,
    required this.serverBalanceSats,
    required this.latestSequenceNumber,
    required this.fundingAmountSats,
    this.fundingTxId,
    this.fundingTxHex,
    this.fundingOutputIndex,
    this.clientPubKeyHex,
    this.serverPubKeyHex,
    this.clientAddressB58,
    this.serverAddressB58,
    this.derivationIndex,
    this.lockTimeUnix,
    required this.success,
    this.error,
  }) : super(payload: null);

  @override
  dynamic get payload => this;
}

