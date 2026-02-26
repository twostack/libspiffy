/// Payment Channel Entity for Isar Storage
///
/// Stores payment channel state in the database for persistence across restarts.

import 'package:isar/isar.dart';
import '../models/payment_channel.dart';

part 'payment_channel_entity.g.dart';

@collection
class PaymentChannelEntity {
  Id id = Isar.autoIncrement;

  /// Unique identifier for this channel
  @Index(unique: true)
  late String channelId;

  /// Wallet ID that owns this channel
  @Index()
  late String walletId;

  /// Role in the channel (client or server)
  late String role;

  /// Peer ID of the client (funder)
  @Index()
  late String clientPeerId;

  /// Peer ID of the server (receiver)
  @Index()
  late String serverPeerId;

  /// Transaction ID of the funding transaction (T1)
  String? fundingTxId;

  /// Raw hex of the funding transaction
  String? fundingTxHex;

  /// Output index in funding transaction
  int? fundingOutputIndex;

  /// Total amount locked in the channel (satoshis as string)
  late String fundingAmountSats;

  /// Client's public key (hex encoded)
  late String clientPubKeyHex;

  /// Server's public key (hex encoded)
  late String serverPubKeyHex;

  /// Client's address for receiving funds on close
  String? clientAddressB58;

  /// Server's address for receiving funds on close
  String? serverAddressB58;

  /// Unix timestamp when refund (T2) becomes valid
  late int lockTimeUnix;

  /// Current state of the channel
  @Index()
  late String state;

  /// Client's current balance (satoshis as string)
  late String clientBalanceSats;

  /// Server's current balance (satoshis as string)
  late String serverBalanceSats;

  /// Latest sequence number used in payment transactions
  late int latestSequenceNumber;

  /// Raw hex of the latest payment transaction (T3)
  String? latestPaymentTxHex;

  /// Latest payment transaction ID
  String? latestPaymentTxId;

  /// Raw hex of the refund transaction (T2)
  String? refundTxHex;

  /// Client's signature on the refund transaction
  String? refundClientSigHex;

  /// Server's signature on the refund transaction
  String? refundServerSigHex;

  /// TXIDs of ancestor transactions (stored as JSON array)
  late List<String> fundingAncestorTxids;

  /// Optional context/purpose for this channel
  String? context;

  /// When the channel was created
  late DateTime createdAt;

  /// When the channel was closed (null if still open)
  DateTime? closedAt;

  /// Settlement transaction ID (set when channel closes cooperatively)
  String? settlementTxId;

  /// Error message if channel failed
  String? errorMessage;

  /// Whether funding transaction has a merkle proof
  late bool hasFundingMerkleProof;

  /// Convert from PaymentChannel model
  static PaymentChannelEntity fromPaymentChannel(PaymentChannel channel) {
    return PaymentChannelEntity()
      ..channelId = channel.channelId
      ..walletId = channel.walletId
      ..role = channel.role.name
      ..clientPeerId = channel.clientPeerId
      ..serverPeerId = channel.serverPeerId
      ..fundingTxId = channel.fundingTxId
      ..fundingTxHex = channel.fundingTxHex
      ..fundingOutputIndex = channel.fundingOutputIndex
      ..fundingAmountSats = channel.fundingAmountSats.toString()
      ..clientPubKeyHex = channel.clientPubKeyHex
      ..serverPubKeyHex = channel.serverPubKeyHex
      ..clientAddressB58 = channel.clientAddressB58
      ..serverAddressB58 = channel.serverAddressB58
      ..lockTimeUnix = channel.lockTimeUnix
      ..state = channel.state.name
      ..clientBalanceSats = channel.clientBalanceSats.toString()
      ..serverBalanceSats = channel.serverBalanceSats.toString()
      ..latestSequenceNumber = channel.latestSequenceNumber
      ..latestPaymentTxHex = channel.latestPaymentTxHex
      ..latestPaymentTxId = channel.latestPaymentTxId
      ..refundTxHex = channel.refundTxHex
      ..refundClientSigHex = channel.refundClientSigHex
      ..refundServerSigHex = channel.refundServerSigHex
      ..fundingAncestorTxids = List<String>.from(channel.fundingAncestorTxids)
      ..context = channel.context
      ..createdAt = channel.createdAt
      ..closedAt = channel.closedAt
      ..settlementTxId = channel.settlementTxId
      ..errorMessage = channel.errorMessage
      ..hasFundingMerkleProof = channel.hasFundingMerkleProof;
  }

  /// Convert to PaymentChannel model
  PaymentChannel toPaymentChannel() {
    final channel = PaymentChannel(
      channelId: channelId,
      walletId: walletId,
      role: PaymentChannelRole.values.firstWhere(
        (r) => r.name == role,
        orElse: () => PaymentChannelRole.client,
      ),
      clientPeerId: clientPeerId,
      serverPeerId: serverPeerId,
      clientPubKeyHex: clientPubKeyHex,
      serverPubKeyHex: serverPubKeyHex,
      clientAddressB58: clientAddressB58,
      serverAddressB58: serverAddressB58,
      fundingAmountSats: BigInt.parse(fundingAmountSats),
      lockTimeUnix: lockTimeUnix,
      state: PaymentChannelState.values.firstWhere(
        (s) => s.name == state,
        orElse: () => PaymentChannelState.negotiating,
      ),
      clientBalanceSats: BigInt.parse(clientBalanceSats),
      serverBalanceSats: BigInt.parse(serverBalanceSats),
      fundingTxId: fundingTxId,
      fundingTxHex: fundingTxHex,
      fundingOutputIndex: fundingOutputIndex,
      refundTxHex: refundTxHex,
      refundClientSigHex: refundClientSigHex,
      refundServerSigHex: refundServerSigHex,
      latestSequenceNumber: latestSequenceNumber,
      latestPaymentTxHex: latestPaymentTxHex,
      latestPaymentTxId: latestPaymentTxId,
      settlementTxId: settlementTxId,
      fundingAncestorTxids: List<String>.from(fundingAncestorTxids),
      hasFundingMerkleProof: hasFundingMerkleProof,
      context: context,
      createdAt: createdAt,
      closedAt: closedAt,
      errorMessage: errorMessage,
    );
    return channel;
  }
}
