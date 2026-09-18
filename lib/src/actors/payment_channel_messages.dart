/// High-level messages for PaymentChannelManager actor
/// 
/// These messages provide a simplified interface for payment channel operations.
/// The PaymentChannelManager handles all the orchestration between WalletManager
/// and PaymentChannelAggregate.

import 'package:dactor/dactor.dart';
import 'internal_messages.dart';

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
class ChannelInitiatedResponse extends ActorResponse {
  final String channelId;
  final String clientPubKeyHex;
  final String clientAddressB58;
  final int derivationIndex;
  final int lockTimeUnix;
  @override
  final bool success;
  @override
  final String? error;

  ChannelInitiatedResponse({
    required this.channelId,
    required this.clientPubKeyHex,
    required this.clientAddressB58,
    required this.derivationIndex,
    required this.lockTimeUnix,
    required this.success,
    this.error,
  });
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

  /// This node's own peer id, journaled with the acceptance.
  final String? serverPeerId;

  AcceptChannelMessage({
    required this.channelId,
    required this.walletId,
    required this.clientPeerId,
    required this.clientPubKeyHex,
    required this.clientAddressB58,
    required this.fundingAmountSats,
    required this.lockTimeUnix,
    this.context,
    this.serverPeerId,
  }) : super(payload: null);

  @override
  dynamic get payload => this;
}

/// Response to channel acceptance
class ChannelAcceptedResponse extends ActorResponse {
  final String channelId;
  final String serverPubKeyHex;
  final String serverAddressB58;
  final int derivationIndex;
  @override
  final bool success;
  @override
  final String? error;

  ChannelAcceptedResponse({
    required this.channelId,
    required this.serverPubKeyHex,
    required this.serverAddressB58,
    required this.derivationIndex,
    required this.success,
    this.error,
  });
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

/// Response to [RecordServerAcceptanceMessage]: `success: false` carries the
/// channel aggregate's rejection (e.g. the channel is not pending).
class ServerAcceptanceRecordedResponse extends ActorResponse {
  final String channelId;
  @override
  final bool success;
  @override
  final String? error;

  ServerAcceptanceRecordedResponse({
    required this.channelId,
    required this.success,
    this.error,
  });
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

  /// The signed funding transaction the refund spends. Required on the
  /// client side of a channel: the client journals it with the refund
  /// (libspiffy-b83) and broadcasts it once the refund is countersigned
  /// (libspiffy-9f7). A server-side build, which only returns the refund,
  /// ignores it.
  final String? fundingTxHex;

  /// Total value of the funding transaction's inputs (what the wallet
  /// spent), so the recorded funding transaction carries its fee.
  final int? fundingInputSats;

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
    this.fundingTxHex,
    this.fundingInputSats,
  }) : super(payload: null);

  @override
  dynamic get payload => this;
}

/// Response with built refund transaction
class RefundTransactionBuiltResponse extends ActorResponse {
  final String channelId;
  final String refundTxHex;
  @override
  final bool success;
  @override
  final String? error;

  RefundTransactionBuiltResponse({
    required this.channelId,
    required this.refundTxHex,
    required this.success,
    this.error,
  });
}

/// Request to sign refund transaction (server side)
///
/// The server signs with the key of the wallet that accepted the channel, at
/// the key index, public keys, amount and lockTime its channel journal holds
/// (libspiffy-36f): [walletId], [clientPubKeyHex], [serverPubKeyHex],
/// [derivationIndex], [fundingAmountSats] and [lockTimeUnix] are not used to
/// sign, and a request whose non-empty [walletId] is not the channel's wallet
/// is refused.
///
/// [fundingTxId], [fundingOutputIndex] and [fundingTxHex] name the funding
/// output the refund spends (from refund_sign_request); the server refuses a
/// refund that spends anything else, and journals them (libspiffy-fsy).
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
  final String? fundingTxId;
  final int? fundingOutputIndex;
  final String? fundingTxHex;

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
    this.fundingTxId,
    this.fundingOutputIndex,
    this.fundingTxHex,
  }) : super(payload: null);

  @override
  dynamic get payload => this;
}

/// Response with refund signature
class RefundTransactionSignedResponse extends ActorResponse {
  final String channelId;
  final String serverSignatureHex;
  @override
  final bool success;
  @override
  final String? error;

  RefundTransactionSignedResponse({
    required this.channelId,
    required this.serverSignatureHex,
    required this.success,
    this.error,
  });
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
class RefundSignatureRecordedResponse extends ActorResponse {
  final String channelId;
  @override
  final bool success;
  @override
  final String? error;

  RefundSignatureRecordedResponse({
    required this.channelId,
    required this.success,
    this.error,
  });
}

// =============================================================================
// CHANNEL OPENING MESSAGES
// =============================================================================

/// Message to finalize channel opening after funding TX is broadcast
///
/// Server side (from channel_open), [fundingBeefHex] must be the BEEF of the
/// funding transaction: the channel opens only once it passes SPV validation
/// (libspiffy-fsy). On the client the manager builds the BEEF itself.
class OpenChannelMessage extends LocalMessage {
  final String channelId;
  final String fundingTxId;
  final int fundingOutputIndex;
  final String fundingTxHex;
  final String? fundingBeefHex;

  OpenChannelMessage({
    required this.channelId,
    required this.fundingTxId,
    required this.fundingOutputIndex,
    required this.fundingTxHex,
    this.fundingBeefHex,
  }) : super(payload: null);

  @override
  dynamic get payload => this;
}

/// Response to channel opening
class ChannelOpenedResponse extends ActorResponse {
  final String channelId;
  @override
  final bool success;
  @override
  final String? error;

  ChannelOpenedResponse({
    required this.channelId,
    required this.success,
    this.error,
  });
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
class PaymentRecordedResponse extends ActorResponse {
  final String channelId;
  final BigInt amountSats;
  final int sequenceNumber;
  final String paymentTxHex;
  final String clientSignatureHex;
  final BigInt newClientBalanceSats;
  final BigInt newServerBalanceSats;
  @override
  final bool success;
  @override
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
  });
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
class PaymentAcknowledgedResponse extends ActorResponse {
  final String channelId;
  final int sequenceNumber;
  final String fullySignedPaymentTxHex;
  final String serverSignatureHex;
  @override
  final bool success;
  @override
  final String? error;

  PaymentAcknowledgedResponse({
    required this.channelId,
    this.sequenceNumber = 0,
    this.fullySignedPaymentTxHex = '',
    this.serverSignatureHex = '',
    required this.success,
    this.error,
  });
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
class ChannelExpiredResponse extends ActorResponse {
  final String channelId;
  @override
  final bool success;
  @override
  final String? error;

  ChannelExpiredResponse({
    required this.channelId,
    required this.success,
    this.error,
  });
}

/// Response to channel close
class ChannelClosedResponse extends ActorResponse {
  final String channelId;
  @override
  final bool success;
  @override
  final String? error;

  ChannelClosedResponse({
    required this.channelId,
    required this.success,
    this.error,
  });
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
class ChannelStateResponse extends ActorResponse {
  final String channelId;
  final String status;
  final BigInt? clientBalanceSats;
  final BigInt? serverBalanceSats;
  final int? latestSequenceNumber;
  @override
  final bool success;
  @override
  final String? error;

  ChannelStateResponse({
    required this.channelId,
    required this.status,
    this.clientBalanceSats,
    this.serverBalanceSats,
    this.latestSequenceNumber,
    required this.success,
    this.error,
  });
}

/// Asks the channel manager for a channel's full journaled state (the
/// aggregate is recovered from its journal when not loaded); answered with
/// [FullChannelStateResponse], `success: false` for an unknown channel.
/// The P2P adapter rebuilds its channel records from it after a restart
/// (libspiffy-fsy, libspiffy-36f).
class ChannelDetailsQueryMessage extends LocalMessage {
  final String channelId;

  ChannelDetailsQueryMessage({
    required this.channelId,
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
class FullChannelStateResponse extends ActorResponse {
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

  /// The fully signed refund transaction the client holds (null until the
  /// server's signature is verified, and on the server side).
  final String? signedRefundTxHex;

  /// Total input value of the funding transaction, when known.
  final int? fundingInputSats;

  /// Whether the funding transaction is already recorded in the client
  /// wallet by an earlier broadcast attempt.
  final bool fundingRecordedInWallet;

  /// A funding broadcast was started and has neither failed nor opened.
  final bool fundingBroadcastInFlight;

  final String? clientPeerId;
  final String? serverPeerId;
  final String? context;

  /// Client: the refund template as built. Server: the refund it signed.
  final String? refundTxHex;

  /// BEEF of the funding transaction journaled with the opening.
  final String? fundingBeefHex;

  /// The latest payment transaction of the channel. On the server (which
  /// holds both signatures when it acknowledges) this is the fully signed
  /// settlement; on the client it is the unsigned template it signed, whose
  /// txid is not the one the signed transaction will have. Null before the
  /// first payment. Read by the close path to find the transaction that
  /// ends the channel (bead libspiffy-f5p2).
  final String? latestPaymentTxHex;

  @override
  final bool success;
  @override
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
    this.signedRefundTxHex,
    this.fundingInputSats,
    this.fundingRecordedInWallet = false,
    this.fundingBroadcastInFlight = false,
    this.clientPeerId,
    this.serverPeerId,
    this.context,
    this.refundTxHex,
    this.fundingBeefHex,
    this.latestPaymentTxHex,
    required this.success,
    this.error,
  });
}

