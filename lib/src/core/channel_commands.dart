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

/// Client provides refund transaction with server's pre-computed signature
/// 
/// Note: Signing is delegated to WalletManager. The signature must be
/// obtained before creating this command.
class RequestRefundSignatureCommand extends ChannelCommand {
  final String fundingTxId;
  final int fundingOutputIndex;
  final String refundTxHex;
  final int lockTimeUnix;
  final String serverSignatureHex;  // Pre-computed by WalletManager

  RequestRefundSignatureCommand({
    required String channelId,
    required this.fundingTxId,
    required this.fundingOutputIndex,
    required this.refundTxHex,
    required this.lockTimeUnix,
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
  String get commandType => 'RequestRefundSignatureCommand';
}

/// Server provides their signature on the refund transaction
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

/// Mark channel as open after funding transaction is broadcast
class OpenChannelCommand extends ChannelCommand {
  final String fundingTxId;
  final int fundingOutputIndex;
  final String fundingTxHex;
  final List<String> fundingAncestorTxids;

  OpenChannelCommand({
    required String channelId,
    required this.fundingTxId,
    required this.fundingOutputIndex,
    required this.fundingTxHex,
    this.fundingAncestorTxids = const [],
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

/// Claim refund after channel expiry (non-cooperative close)
class ClaimRefundCommand extends ChannelCommand {
  ClaimRefundCommand({
    required String channelId,
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

