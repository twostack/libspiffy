import 'package:eventador/eventador.dart';

/// Base class for all channel commands
abstract class ChannelCommand extends Command {
  final String channelId;

  ChannelCommand({
    required this.channelId,
    String? commandId,
    DateTime? timestamp,
    Map<String, dynamic>? metadata,
  }) : super(
          commandId: commandId,
          timestamp: timestamp,
          metadata: metadata,
        );

  String get commandType;
}

// =============================================================================
// CHANNEL LIFECYCLE COMMANDS
// =============================================================================

/// Client requests to open a channel with a server
/// 
/// Flow: Client → RequestChannelCommand → ChannelRequestedEvent → P2P → Server
/// 
/// Note: clientPubKeyHex, clientAddressB58, and derivationIndex must be 
/// pre-computed by WalletManager before creating this command.
class RequestChannelCommand extends ChannelCommand {
  final String walletId;
  final String clientPeerId;
  final String serverPeerId;
  final String clientPubKeyHex;  // Pre-computed by WalletManager
  final String clientAddressB58;  // Pre-computed by WalletManager
  final int derivationIndex;  // Pre-computed by WalletManager
  final BigInt fundingAmountSats;
  final int lockTimeDurationSeconds;
  final String? context;

  RequestChannelCommand({
    required String channelId,
    required this.walletId,
    required this.clientPeerId,
    required this.serverPeerId,
    required this.clientPubKeyHex,
    required this.clientAddressB58,
    required this.derivationIndex,
    required this.fundingAmountSats,
    required this.lockTimeDurationSeconds,
    this.context,
    String? commandId,
    DateTime? timestamp,
    Map<String, dynamic>? metadata,
  }) : super(
          channelId: channelId,
          commandId: commandId,
          timestamp: timestamp,
          metadata: metadata,
        );

  @override
  String get commandType => 'RequestChannelCommand';
}

/// Server accepts a channel request
/// 
/// Flow: Server → AcceptChannelCommand → ChannelAcceptedEvent → P2P → Client
/// 
/// Note: serverPubKeyHex, serverAddressB58, and derivationIndex must be 
/// pre-computed by WalletManager before creating this command.
class AcceptChannelCommand extends ChannelCommand {
  final String walletId;
  final String clientPeerId;
  final String clientPubKeyHex;
  final String clientAddressB58;
  final String serverPubKeyHex;  // Pre-computed by WalletManager
  final String serverAddressB58;  // Pre-computed by WalletManager
  final int derivationIndex;  // Pre-computed by WalletManager
  final BigInt fundingAmountSats;
  final int lockTimeUnix;
  final String? context;

  /// The accepting node's own peer id, journaled with the acceptance.
  final String? serverPeerId;

  AcceptChannelCommand({
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
    String? commandId,
    DateTime? timestamp,
    Map<String, dynamic>? metadata,
  }) : super(
          channelId: channelId,
          commandId: commandId,
          timestamp: timestamp,
          metadata: metadata,
        );

  @override
  String get commandType => 'AcceptChannelCommand';
}

/// Client records that the server accepted the channel
/// 
/// This command is used by the client after receiving the server's
/// acceptance via P2P. It updates the client's aggregate with the
/// server's public key and address for building transactions.
class RecordServerAcceptanceCommand extends ChannelCommand {
  final String serverPubKeyHex;
  final String serverAddressB58;

  RecordServerAcceptanceCommand({
    required String channelId,
    required this.serverPubKeyHex,
    required this.serverAddressB58,
    String? commandId,
    DateTime? timestamp,
    Map<String, dynamic>? metadata,
  }) : super(
          channelId: channelId,
          commandId: commandId,
          timestamp: timestamp,
          metadata: metadata,
        );

  @override
  String get commandType => 'RecordServerAcceptanceCommand';
}

/// Server rejects a channel request
class RejectChannelCommand extends ChannelCommand {
  final String reason;

  RejectChannelCommand({
    required String channelId,
    required this.reason,
    String? commandId,
    DateTime? timestamp,
    Map<String, dynamic>? metadata,
  }) : super(
          channelId: channelId,
          commandId: commandId,
          timestamp: timestamp,
          metadata: metadata,
        );

  @override
  String get commandType => 'RejectChannelCommand';
}

// =============================================================================
// REFUND SIGNING COMMANDS
// =============================================================================

/// Client journals the refund transaction it built, with its own signature
/// and the signed funding transaction the refund spends (libspiffy-b83).
///
/// The aggregate checks the funding output is the channel's 2-of-2 holding
/// the funding amount, the refund spends exactly that output back to the
/// client with the channel lockTime (and a non-final input sequence), and
/// the client signature is valid; then emits [RefundBuiltEvent].
class RecordRefundBuiltCommand extends ChannelCommand {
  final String fundingTxId;
  final int fundingOutputIndex;
  final String fundingTxHex;
  final String refundTxHex;
  final String clientSignatureHex;
  final int? fundingInputSats;

  RecordRefundBuiltCommand({
    required String channelId,
    required this.fundingTxId,
    required this.fundingOutputIndex,
    required this.fundingTxHex,
    required this.refundTxHex,
    required this.clientSignatureHex,
    this.fundingInputSats,
    String? commandId,
    DateTime? timestamp,
    Map<String, dynamic>? metadata,
  }) : super(
          channelId: channelId,
          commandId: commandId,
          timestamp: timestamp,
          metadata: metadata,
        );

  @override
  String get commandType => 'RecordRefundBuiltCommand';
}

/// Server journals its signature on the client's refund transaction.
///
/// Note: Signing is delegated to WalletManager. The signature must be
/// obtained before creating this command.
///
/// The aggregate accepts it only for a refund that spends exactly
/// [fundingTxId]:[fundingOutputIndex] with the channel lockTime and a
/// non-final input sequence and, when [fundingTxHex] is given, only if that
/// output locks the agreed amount in the channel's 2-of-2 (libspiffy-fsy).
class RequestRefundSignatureCommand extends ChannelCommand {
  final String fundingTxId;
  final int fundingOutputIndex;
  final String refundTxHex;
  final int lockTimeUnix;
  final String serverSignatureHex;  // Pre-computed by WalletManager

  /// The funding transaction the refund spends, as the client sent it.
  final String? fundingTxHex;

  RequestRefundSignatureCommand({
    required String channelId,
    required this.fundingTxId,
    required this.fundingOutputIndex,
    required this.refundTxHex,
    required this.lockTimeUnix,
    required this.serverSignatureHex,
    this.fundingTxHex,
    String? commandId,
    DateTime? timestamp,
    Map<String, dynamic>? metadata,
  }) : super(
          channelId: channelId,
          commandId: commandId,
          timestamp: timestamp,
          metadata: metadata,
        );

  @override
  String get commandType => 'RequestRefundSignatureCommand';
}

/// Client records the server's signature on its refund transaction.
///
/// The aggregate combines it with the journaled template and client
/// signature and accepts it only if the fully signed refund satisfies the
/// script interpreter against the funding output (libspiffy-b83).
class ProvideRefundSignatureCommand extends ChannelCommand {
  final String serverSignatureHex;

  ProvideRefundSignatureCommand({
    required String channelId,
    required this.serverSignatureHex,
    String? commandId,
    DateTime? timestamp,
    Map<String, dynamic>? metadata,
  }) : super(
          channelId: channelId,
          commandId: commandId,
          timestamp: timestamp,
          metadata: metadata,
        );

  @override
  String get commandType => 'ProvideRefundSignatureCommand';
}

// =============================================================================
// CHANNEL OPENING COMMANDS
// =============================================================================

/// Mark channel as open after funding transaction is broadcast.
///
/// Client: only after [StartFundingBroadcastCommand] for this funding
/// transaction and a successful broadcast. Server: only for a funding
/// transaction whose output pays the agreed amount to the channel's 2-of-2,
/// which is the one whose refund it signed, carried in [fundingBeefHex]
/// (the manager SPV-validates that BEEF first, libspiffy-fsy).
class OpenChannelCommand extends ChannelCommand {
  final String fundingTxId;
  final int fundingOutputIndex;
  final String fundingTxHex;
  final List<String> fundingAncestorTxids;

  /// BEEF of the funding transaction (journaled with the opening).
  final String? fundingBeefHex;

  OpenChannelCommand({
    required String channelId,
    required this.fundingTxId,
    required this.fundingOutputIndex,
    required this.fundingTxHex,
    this.fundingAncestorTxids = const [],
    this.fundingBeefHex,
    String? commandId,
    DateTime? timestamp,
    Map<String, dynamic>? metadata,
  }) : super(
          channelId: channelId,
          commandId: commandId,
          timestamp: timestamp,
          metadata: metadata,
        );

  @override
  String get commandType => 'OpenChannelCommand';
}

/// Client asks to broadcast its funding transaction (libspiffy-9f7).
///
/// Accepted only from the client of a channel whose journal holds the
/// verified, fully signed refund of this funding transaction; emits
/// [FundingBroadcastStartedEvent], after which (and only after which) the
/// transaction is handed to ARC.
class StartFundingBroadcastCommand extends ChannelCommand {
  final String fundingTxId;

  StartFundingBroadcastCommand({
    required String channelId,
    required this.fundingTxId,
    String? commandId,
    DateTime? timestamp,
    Map<String, dynamic>? metadata,
  }) : super(
          channelId: channelId,
          commandId: commandId,
          timestamp: timestamp,
          metadata: metadata,
        );

  @override
  String get commandType => 'StartFundingBroadcastCommand';
}

/// Client records that its wallet holds the funding transaction of the
/// broadcast in progress; emits [FundingRecordedInWalletEvent]
/// (libspiffy-fsy).
class RecordFundingInWalletCommand extends ChannelCommand {
  final String fundingTxId;

  RecordFundingInWalletCommand({
    required String channelId,
    required this.fundingTxId,
    String? commandId,
    DateTime? timestamp,
    Map<String, dynamic>? metadata,
  }) : super(
          channelId: channelId,
          commandId: commandId,
          timestamp: timestamp,
          metadata: metadata,
        );

  @override
  String get commandType => 'RecordFundingInWalletCommand';
}

/// Client records that broadcasting its funding transaction failed; emits
/// [FundingBroadcastFailedEvent] and leaves the channel unopened.
class RecordFundingBroadcastFailedCommand extends ChannelCommand {
  final String fundingTxId;
  final String error;

  /// Whether the funding transaction was recorded in the wallet before the
  /// broadcast failed.
  final bool walletRecorded;

  RecordFundingBroadcastFailedCommand({
    required String channelId,
    required this.fundingTxId,
    required this.error,
    required this.walletRecorded,
    String? commandId,
    DateTime? timestamp,
    Map<String, dynamic>? metadata,
  }) : super(
          channelId: channelId,
          commandId: commandId,
          timestamp: timestamp,
          metadata: metadata,
        );

  @override
  String get commandType => 'RecordFundingBroadcastFailedCommand';
}

// =============================================================================
// PAYMENT COMMANDS
// =============================================================================

/// Client records a payment with pre-built and pre-signed payment TX
/// 
/// Note: TX building and signing are delegated to WalletManager. The payment
/// transaction and signature must be obtained before creating this command.
/// 
/// This command triggers:
/// 1. Validation (channel open, balance sufficient, sequence incrementing)
/// 2. PaymentRecordedEvent emission
class RecordPaymentCommand extends ChannelCommand {
  final BigInt amountSats;
  final int sequenceNumber;               // New sequence number for this payment
  final String paymentTxHex;              // Pre-built payment TX (from WalletManager)
  final String paymentTxId;               // Transaction ID
  final String clientSignatureHex;        // Pre-computed client signature (from WalletManager)
  final BigInt newClientBalanceSats;      // New client balance after payment
  final BigInt newServerBalanceSats;      // New server balance after payment
  final String? purpose;
  final String? invoiceId;

  RecordPaymentCommand({
    required String channelId,
    required this.amountSats,
    required this.sequenceNumber,
    required this.paymentTxHex,
    required this.paymentTxId,
    required this.clientSignatureHex,
    required this.newClientBalanceSats,
    required this.newServerBalanceSats,
    this.purpose,
    this.invoiceId,
    String? commandId,
    DateTime? timestamp,
    Map<String, dynamic>? metadata,
  }) : super(
          channelId: channelId,
          commandId: commandId,
          timestamp: timestamp,
          metadata: metadata,
        );

  @override
  String get commandType => 'RecordPaymentCommand';
}

/// Server acknowledges payment with pre-computed server signature
/// 
/// Note: Signing is delegated to WalletManager. The server signature must be
/// obtained before creating this command.
/// 
/// This command triggers:
/// 1. Validation (sequence incrementing, amounts correct)
/// 2. PaymentAcknowledgedEvent emission with fully signed TX
class AcknowledgePaymentCommand extends ChannelCommand {
  final BigInt amountSats;                  // Incremental payment amount
  final String paymentTxHex;
  final String clientSignatureHex;
  final String serverSignatureHex;         // Pre-computed by WalletManager
  final String fullySignedPaymentTxHex;    // Fully signed TX (from WalletManager)
  final int proposedSequence;
  final BigInt proposedClientBalance;
  final BigInt proposedServerBalance;

  AcknowledgePaymentCommand({
    required String channelId,
    required this.amountSats,
    required this.paymentTxHex,
    required this.clientSignatureHex,
    required this.serverSignatureHex,
    required this.fullySignedPaymentTxHex,
    required this.proposedSequence,
    required this.proposedClientBalance,
    required this.proposedServerBalance,
    String? commandId,
    DateTime? timestamp,
    Map<String, dynamic>? metadata,
  }) : super(
          channelId: channelId,
          commandId: commandId,
          timestamp: timestamp,
          metadata: metadata,
        );

  @override
  String get commandType => 'AcknowledgePaymentCommand';
}

// =============================================================================
// CHANNEL CLOSING COMMANDS
// =============================================================================

/// Initiate channel close (cooperative)
class CloseChannelCommand extends ChannelCommand {
  final String? reason;

  CloseChannelCommand({
    required String channelId,
    this.reason,
    String? commandId,
    DateTime? timestamp,
    Map<String, dynamic>? metadata,
  }) : super(
          channelId: channelId,
          commandId: commandId,
          timestamp: timestamp,
          metadata: metadata,
        );

  @override
  String get commandType => 'CloseChannelCommand';
}

/// Finalize channel close after settlement TX is broadcast
class FinalizeCloseCommand extends ChannelCommand {
  final String settlementTxId;
  final BigInt finalClientBalanceSats;
  final BigInt finalServerBalanceSats;

  FinalizeCloseCommand({
    required String channelId,
    required this.settlementTxId,
    required this.finalClientBalanceSats,
    required this.finalServerBalanceSats,
    String? commandId,
    DateTime? timestamp,
    Map<String, dynamic>? metadata,
  }) : super(
          channelId: channelId,
          commandId: commandId,
          timestamp: timestamp,
          metadata: metadata,
        );

  @override
  String get commandType => 'FinalizeCloseCommand';
}

/// Record that a channel has expired (lockTime elapsed).
///
/// Issued by the expiry monitor when the channel passes its lockTime.
/// Emits [ChannelExpiredEvent]. The aggregate enforces that the channel
/// is genuinely past its lockTime and not already terminated.
///
/// This is distinct from [ClaimRefundCommand] (which broadcasts the refund TX
/// and emits [RefundClaimedEvent]); the expiry monitor uses [ExpireChannelCommand]
/// to update the read model in lock-step with the event store regardless of
/// whether a refund/settlement TX was broadcast.
class ExpireChannelCommand extends ChannelCommand {
  final String observedBy; // 'client' or 'server'
  final String? settlementOrRefundTxId;

  ExpireChannelCommand({
    required String channelId,
    required this.observedBy,
    this.settlementOrRefundTxId,
    String? commandId,
    DateTime? timestamp,
    Map<String, dynamic>? metadata,
  }) : super(
          channelId: channelId,
          commandId: commandId,
          timestamp: timestamp,
          metadata: metadata,
        );

  @override
  String get commandType => 'ExpireChannelCommand';
}

/// Claim refund after channel expiry (non-cooperative close)
class ClaimRefundCommand extends ChannelCommand {
  /// Raw hex of the refund transaction being claimed (typically the fully
  /// signed refund). When null, the refund transaction the channel built is
  /// used. Its txid is what the journaled [RefundClaimedEvent] records.
  final String? refundTxHex;

  ClaimRefundCommand({
    required String channelId,
    this.refundTxHex,
    String? commandId,
    DateTime? timestamp,
    Map<String, dynamic>? metadata,
  }) : super(
          channelId: channelId,
          commandId: commandId,
          timestamp: timestamp,
          metadata: metadata,
        );

  @override
  String get commandType => 'ClaimRefundCommand';
}

