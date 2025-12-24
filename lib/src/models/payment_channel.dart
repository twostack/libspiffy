/// Payment Channel Model
///
/// Represents a payment channel between two parties (client and server).
/// Supports nLockTime-based payment channels with refund fallback.

/// State of a payment channel
enum PaymentChannelState {
  /// Channel is being opened (funding tx not yet broadcast)
  opening,

  /// Channel is open and ready for payments
  open,

  /// Channel is being closed cooperatively
  closing,

  /// Channel is closed (final state broadcast)
  closed,

  /// Channel expired and refund was claimed
  expired,
}

/// Role in a payment channel
enum PaymentChannelRole {
  /// Client (funder) who opens the channel
  client,

  /// Server (receiver) who receives payments
  server,
}

/// Payment channel model
class PaymentChannel {
  /// Unique identifier for this channel
  final String channelId;

  /// Wallet ID that owns this channel
  final String walletId;

  /// Role in the channel (client or server)
  final PaymentChannelRole role;

  /// Peer ID of the client (funder)
  final String clientPeerId;

  /// Peer ID of the server (receiver)
  final String serverPeerId;

  /// Transaction ID of the funding transaction (T1)
  final String fundingTxId;

  /// Raw hex of the funding transaction
  final String fundingTxHex;

  /// Output index in funding transaction
  final int fundingOutputIndex;

  /// Total amount locked in the channel (satoshis)
  final BigInt fundingAmountSats;

  /// Client's public key (hex encoded)
  final String clientPubKeyHex;

  /// Server's public key (hex encoded)
  final String serverPubKeyHex;

  /// Client's address for receiving funds on close
  final String clientAddressB58;

  /// Server's address for receiving funds on close
  final String serverAddressB58;

  /// Unix timestamp when refund (T2) becomes valid
  final int lockTimeUnix;

  /// Current state of the channel
  PaymentChannelState state;

  /// Client's current balance (satoshis)
  BigInt clientBalanceSats;

  /// Server's current balance (satoshis)
  BigInt serverBalanceSats;

  /// Latest sequence number used in payment transactions
  int latestSequenceNumber;

  /// Raw hex of the latest payment transaction (T3)
  String? latestPaymentTxHex;

  /// Raw hex of the refund transaction (T2)
  String? refundTxHex;

  /// Client's signature on the refund transaction
  String? refundClientSigHex;

  /// Server's signature on the refund transaction
  String? refundServerSigHex;

  /// TXIDs of ancestor transactions for BEEF construction
  List<String> fundingAncestorTxids;

  /// Optional context/purpose for this channel
  String? context;

  /// When the channel was created
  final DateTime createdAt;

  /// When the channel was closed (null if still open)
  DateTime? closedAt;

  /// Whether funding transaction has a merkle proof
  bool hasFundingMerkleProof = false;

  PaymentChannel({
    required this.channelId,
    required this.walletId,
    required this.role,
    required this.clientPeerId,
    required this.serverPeerId,
    required this.fundingTxId,
    required this.fundingTxHex,
    required this.fundingOutputIndex,
    required this.fundingAmountSats,
    required this.clientPubKeyHex,
    required this.serverPubKeyHex,
    required this.clientAddressB58,
    required this.serverAddressB58,
    required this.lockTimeUnix,
    required this.state,
    required this.clientBalanceSats,
    required this.serverBalanceSats,
    required this.latestSequenceNumber,
    this.latestPaymentTxHex,
    this.refundTxHex,
    this.refundClientSigHex,
    this.refundServerSigHex,
    required this.fundingAncestorTxids,
    this.context,
    required this.createdAt,
    this.closedAt,
  });

  /// Whether this wallet is the client (funder)
  bool get isClient => role == PaymentChannelRole.client;

  /// Whether this wallet is the server (receiver)
  bool get isServer => role == PaymentChannelRole.server;

  /// Whether the channel is open for payments
  bool get isOpen => state == PaymentChannelState.open;

  /// Whether the channel is closed
  bool get isClosed =>
      state == PaymentChannelState.closed || state == PaymentChannelState.expired;

  /// Whether the refund transaction is valid (locktime passed)
  bool get isExpired {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return now >= lockTimeUnix;
  }

  /// Seconds until refund becomes valid
  int get secondsUntilRefundValid {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return lockTimeUnix - now;
  }

  /// Total amount paid to server so far
  BigInt get totalPaid => serverBalanceSats;

  /// Remaining balance available for payments
  BigInt get remainingBalance => clientBalanceSats;

  @override
  String toString() {
    return 'PaymentChannel('
        'id: $channelId, '
        'role: ${role.name}, '
        'state: ${state.name}, '
        'funding: $fundingAmountSats sats, '
        'balances: client=$clientBalanceSats server=$serverBalanceSats, '
        'seq: $latestSequenceNumber'
        ')';
  }
}

/// Result of a payment channel operation
class PaymentChannelResult {
  final bool success;
  final PaymentChannel? channel;
  final String? transactionHex;
  final String? beefHex;
  final String? error;

  PaymentChannelResult.success({
    required this.channel,
    this.transactionHex,
    this.beefHex,
  })  : success = true,
        error = null;

  PaymentChannelResult.failure(this.error)
      : success = false,
        channel = null,
        transactionHex = null,
        beefHex = null;
}
