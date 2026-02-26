/// Payment Channel Model
///
/// Unified model representing a payment channel between two parties (client and server).
/// Supports nLockTime-based unidirectional payment channels with refund fallback.
///
/// Channel Structure:
/// - T1 (Funding TX): On-chain, locks funds in 2-of-2 multisig
/// - T2 (Refund TX): Held by client, spendable after locktime
/// - T3 (Payment TX): Updated off-chain, higher nSequence replaces lower

/// State of a payment channel in its lifecycle
enum PaymentChannelState {
  /// Channel negotiation in progress (awaiting peer acceptance)
  negotiating,

  /// Waiting for funding TX confirmation
  funding,

  /// Channel is being opened (funding tx not yet broadcast) - legacy alias for funding
  opening,

  /// Channel is open and ready for payments
  open,

  /// Channel is being closed cooperatively
  closing,

  /// Channel is closed (final state broadcast)
  closed,

  /// Channel expired and refund was claimed
  expired,

  /// Channel failed during setup or operation
  failed;

  String toJson() => name;

  static PaymentChannelState fromJson(String value) =>
      PaymentChannelState.values.firstWhere(
        (e) => e.name == value,
        orElse: () => PaymentChannelState.negotiating,
      );
}

/// Role in a payment channel
enum PaymentChannelRole {
  /// Client (funder) who opens the channel and makes payments
  client,

  /// Server (receiver) who receives payments and can settle
  server;

  String toJson() => name;

  static PaymentChannelRole fromJson(String value) =>
      PaymentChannelRole.values.firstWhere(
        (e) => e.name == value,
        orElse: () => PaymentChannelRole.client,
      );
}

/// Payment channel data model
///
/// Tracks the complete state of a unidirectional payment channel including
/// all transaction data needed for safety (refund TX, latest payment TX).
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

  /// Client's public key for 2-of-2 multisig (hex encoded)
  final String clientPubKeyHex;

  /// Server's public key for 2-of-2 multisig (hex encoded)
  final String serverPubKeyHex;

  /// Client's Bitcoin address for receiving funds on close
  String? clientAddressB58;

  /// Server's Bitcoin address for receiving funds on close
  String? serverAddressB58;

  /// Total amount locked in the channel (satoshis)
  final BigInt fundingAmountSats;

  /// Unix timestamp when refund (T2) becomes valid (nLockTime value)
  final int lockTimeUnix;

  /// Current state of the channel
  PaymentChannelState state;

  /// Client's current balance (satoshis)
  BigInt clientBalanceSats;

  /// Server's current balance (satoshis)
  BigInt serverBalanceSats;

  /// Transaction ID of the funding transaction (T1)
  String? fundingTxId;

  /// Raw hex of the funding transaction
  String? fundingTxHex;

  /// Output index in funding transaction
  int? fundingOutputIndex;

  /// Raw hex of the refund transaction (T2)
  String? refundTxHex;

  /// Client's signature on the refund transaction
  String? refundClientSigHex;

  /// Server's signature on the refund transaction
  String? refundServerSigHex;

  /// Latest sequence number used in payment transactions
  int latestSequenceNumber;

  /// Raw hex of the latest payment transaction (T3)
  String? latestPaymentTxHex;

  /// Latest payment transaction ID
  String? latestPaymentTxId;

  /// Settlement transaction ID (set when channel closes cooperatively)
  String? settlementTxId;

  /// TXIDs of ancestor transactions for BEEF construction
  List<String> fundingAncestorTxids;

  /// Whether funding transaction has a merkle proof
  bool hasFundingMerkleProof;

  /// Optional context/purpose for this channel (e.g., "audiospace:meeting-123")
  String? context;

  /// When the channel was created
  final DateTime createdAt;

  /// When the channel was closed (null if still open)
  DateTime? closedAt;

  /// Error message if channel failed
  String? errorMessage;

  PaymentChannel({
    required this.channelId,
    required this.walletId,
    required this.role,
    required this.clientPeerId,
    required this.serverPeerId,
    required this.clientPubKeyHex,
    required this.serverPubKeyHex,
    this.clientAddressB58,
    this.serverAddressB58,
    required this.fundingAmountSats,
    required this.lockTimeUnix,
    this.state = PaymentChannelState.negotiating,
    BigInt? clientBalanceSats,
    BigInt? serverBalanceSats,
    this.fundingTxId,
    this.fundingTxHex,
    this.fundingOutputIndex,
    this.refundTxHex,
    this.refundClientSigHex,
    this.refundServerSigHex,
    this.latestSequenceNumber = 0,
    this.latestPaymentTxHex,
    this.latestPaymentTxId,
    this.settlementTxId,
    List<String>? fundingAncestorTxids,
    this.hasFundingMerkleProof = false,
    this.context,
    DateTime? createdAt,
    this.closedAt,
    this.errorMessage,
  })  : clientBalanceSats = clientBalanceSats ?? fundingAmountSats,
        serverBalanceSats = serverBalanceSats ?? BigInt.zero,
        fundingAncestorTxids = fundingAncestorTxids ?? [],
        createdAt = createdAt ?? DateTime.now();

  // ===========================================================================
  // Role Getters
  // ===========================================================================

  /// Whether this wallet is the client (funder)
  bool get isClient => role == PaymentChannelRole.client;

  /// Whether this wallet is the server (receiver)
  bool get isServer => role == PaymentChannelRole.server;

  /// Our peer ID (based on role)
  String get myPeerId => isClient ? clientPeerId : serverPeerId;

  /// Counterparty peer ID
  String get counterpartyPeerId => isClient ? serverPeerId : clientPeerId;

  /// Our public key
  String get myPubKeyHex => isClient ? clientPubKeyHex : serverPubKeyHex;

  /// Counterparty's public key
  String get counterpartyPubKeyHex =>
      isClient ? serverPubKeyHex : clientPubKeyHex;

  // ===========================================================================
  // State Getters
  // ===========================================================================

  /// Whether the channel is open for payments
  bool get isOpen => state == PaymentChannelState.open;

  /// Whether the channel is active and can process payments (alias for isOpen)
  bool get isActive => state == PaymentChannelState.open;

  /// Whether the channel is closed
  bool get isClosed =>
      state == PaymentChannelState.closed ||
      state == PaymentChannelState.expired;

  /// Whether the channel is in negotiation phase
  bool get isNegotiating => state == PaymentChannelState.negotiating;

  /// Whether the channel is waiting for funding confirmation
  bool get isFunding =>
      state == PaymentChannelState.funding ||
      state == PaymentChannelState.opening;

  /// Whether the channel failed
  bool get isFailed => state == PaymentChannelState.failed;

  // ===========================================================================
  // Expiry Getters
  // ===========================================================================

  /// Lock time as DateTime for convenience
  DateTime get lockTime =>
      DateTime.fromMillisecondsSinceEpoch(lockTimeUnix * 1000);

  /// Whether the refund transaction is valid (locktime passed)
  bool get isExpired {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return now >= lockTimeUnix;
  }

  /// Time until channel expires
  Duration get timeUntilExpiry => lockTime.difference(DateTime.now());

  /// Seconds until refund becomes valid
  int get secondsUntilRefundValid {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return lockTimeUnix - now;
  }

  /// Whether refund can be broadcast (channel expired and refund TX exists)
  bool get canBroadcastRefund => isExpired && refundTxHex != null;

  // ===========================================================================
  // Balance Getters
  // ===========================================================================

  /// Total amount paid to server so far
  BigInt get totalPaid => serverBalanceSats;

  /// Total amount paid through this channel (int convenience)
  int get totalPaidSats => serverBalanceSats.toInt();

  /// Remaining balance available for payments
  BigInt get remainingBalance => clientBalanceSats;

  /// Current client balance as int (for compatibility)
  int get currentClientBalanceSats => clientBalanceSats.toInt();

  /// Current server balance as int (for compatibility)
  int get currentServerBalanceSats => serverBalanceSats.toInt();

  /// Funding amount as int (for compatibility)
  int get fundingAmountSatsInt => fundingAmountSats.toInt();

  // ===========================================================================
  // Serialization
  // ===========================================================================

  factory PaymentChannel.fromJson(Map<String, dynamic> json) {
    return PaymentChannel(
      channelId: json['channelId'] as String,
      walletId: json['walletId'] as String? ?? '',
      role: PaymentChannelRole.fromJson(json['role'] as String),
      clientPeerId: json['clientPeerId'] as String,
      serverPeerId: json['serverPeerId'] as String,
      clientPubKeyHex: (json['clientPubKeyHex'] ?? json['clientPubKey']) as String,
      serverPubKeyHex: (json['serverPubKeyHex'] ?? json['serverPubKey']) as String,
      clientAddressB58: (json['clientAddressB58'] ?? json['clientAddress']) as String?,
      serverAddressB58: (json['serverAddressB58'] ?? json['serverAddress']) as String?,
      fundingAmountSats: _parseBigInt(json['fundingAmountSats']),
      lockTimeUnix: _parseLockTime(json),
      state: PaymentChannelState.fromJson(json['state'] as String),
      clientBalanceSats: _parseBigIntOptional(
          json['clientBalanceSats'] ?? json['currentClientBalanceSats']),
      serverBalanceSats: _parseBigIntOptional(
          json['serverBalanceSats'] ?? json['currentServerBalanceSats']),
      fundingTxId: json['fundingTxId'] as String?,
      fundingTxHex: json['fundingTxHex'] as String?,
      fundingOutputIndex: json['fundingOutputIndex'] as int?,
      refundTxHex: json['refundTxHex'] as String?,
      refundClientSigHex: json['refundClientSigHex'] as String?,
      refundServerSigHex: json['refundServerSigHex'] as String?,
      latestSequenceNumber: json['latestSequenceNumber'] as int? ?? 0,
      latestPaymentTxHex: json['latestPaymentTxHex'] as String?,
      latestPaymentTxId: json['latestPaymentTxId'] as String?,
      settlementTxId: json['settlementTxId'] as String?,
      fundingAncestorTxids: (json['fundingAncestorTxids'] as List<dynamic>?)
              ?.cast<String>()
              .toList() ??
          [],
      hasFundingMerkleProof: json['hasFundingMerkleProof'] as bool? ?? false,
      context: json['context'] as String?,
      createdAt: json['createdAt'] != null
          ? DateTime.parse(json['createdAt'] as String)
          : null,
      closedAt: json['closedAt'] != null
          ? DateTime.parse(json['closedAt'] as String)
          : null,
      errorMessage: json['errorMessage'] as String?,
    );
  }

  static BigInt _parseBigInt(dynamic value) {
    if (value is BigInt) return value;
    if (value is int) return BigInt.from(value);
    if (value is String) return BigInt.parse(value);
    throw ArgumentError('Cannot parse BigInt from $value');
  }

  static BigInt? _parseBigIntOptional(dynamic value) {
    if (value == null) return null;
    return _parseBigInt(value);
  }

  static int _parseLockTime(Map<String, dynamic> json) {
    if (json.containsKey('lockTimeUnix')) {
      return json['lockTimeUnix'] as int;
    }
    if (json.containsKey('lockTime')) {
      final lockTime = json['lockTime'];
      if (lockTime is int) return lockTime;
      if (lockTime is String) {
        // Try parsing as ISO date string
        return DateTime.parse(lockTime).millisecondsSinceEpoch ~/ 1000;
      }
    }
    throw ArgumentError('Missing lockTimeUnix or lockTime in JSON');
  }

  Map<String, dynamic> toJson() {
    return {
      'channelId': channelId,
      'walletId': walletId,
      'role': role.toJson(),
      'clientPeerId': clientPeerId,
      'serverPeerId': serverPeerId,
      'clientPubKeyHex': clientPubKeyHex,
      'serverPubKeyHex': serverPubKeyHex,
      if (clientAddressB58 != null) 'clientAddressB58': clientAddressB58,
      if (serverAddressB58 != null) 'serverAddressB58': serverAddressB58,
      'fundingAmountSats': fundingAmountSats.toString(),
      'lockTimeUnix': lockTimeUnix,
      'state': state.toJson(),
      'clientBalanceSats': clientBalanceSats.toString(),
      'serverBalanceSats': serverBalanceSats.toString(),
      if (fundingTxId != null) 'fundingTxId': fundingTxId,
      if (fundingTxHex != null) 'fundingTxHex': fundingTxHex,
      if (fundingOutputIndex != null) 'fundingOutputIndex': fundingOutputIndex,
      if (refundTxHex != null) 'refundTxHex': refundTxHex,
      if (refundClientSigHex != null) 'refundClientSigHex': refundClientSigHex,
      if (refundServerSigHex != null) 'refundServerSigHex': refundServerSigHex,
      'latestSequenceNumber': latestSequenceNumber,
      if (latestPaymentTxHex != null) 'latestPaymentTxHex': latestPaymentTxHex,
      if (latestPaymentTxId != null) 'latestPaymentTxId': latestPaymentTxId,
      if (settlementTxId != null) 'settlementTxId': settlementTxId,
      'fundingAncestorTxids': fundingAncestorTxids,
      'hasFundingMerkleProof': hasFundingMerkleProof,
      if (context != null) 'context': context,
      'createdAt': createdAt.toIso8601String(),
      if (closedAt != null) 'closedAt': closedAt!.toIso8601String(),
      if (errorMessage != null) 'errorMessage': errorMessage,
    };
  }

  // ===========================================================================
  // copyWith
  // ===========================================================================

  PaymentChannel copyWith({
    String? channelId,
    String? walletId,
    PaymentChannelRole? role,
    String? clientPeerId,
    String? serverPeerId,
    String? clientPubKeyHex,
    String? serverPubKeyHex,
    String? clientAddressB58,
    String? serverAddressB58,
    BigInt? fundingAmountSats,
    int? lockTimeUnix,
    PaymentChannelState? state,
    BigInt? clientBalanceSats,
    BigInt? serverBalanceSats,
    String? fundingTxId,
    String? fundingTxHex,
    int? fundingOutputIndex,
    String? refundTxHex,
    String? refundClientSigHex,
    String? refundServerSigHex,
    int? latestSequenceNumber,
    String? latestPaymentTxHex,
    String? latestPaymentTxId,
    String? settlementTxId,
    List<String>? fundingAncestorTxids,
    bool? hasFundingMerkleProof,
    String? context,
    DateTime? createdAt,
    DateTime? closedAt,
    String? errorMessage,
  }) {
    return PaymentChannel(
      channelId: channelId ?? this.channelId,
      walletId: walletId ?? this.walletId,
      role: role ?? this.role,
      clientPeerId: clientPeerId ?? this.clientPeerId,
      serverPeerId: serverPeerId ?? this.serverPeerId,
      clientPubKeyHex: clientPubKeyHex ?? this.clientPubKeyHex,
      serverPubKeyHex: serverPubKeyHex ?? this.serverPubKeyHex,
      clientAddressB58: clientAddressB58 ?? this.clientAddressB58,
      serverAddressB58: serverAddressB58 ?? this.serverAddressB58,
      fundingAmountSats: fundingAmountSats ?? this.fundingAmountSats,
      lockTimeUnix: lockTimeUnix ?? this.lockTimeUnix,
      state: state ?? this.state,
      clientBalanceSats: clientBalanceSats ?? this.clientBalanceSats,
      serverBalanceSats: serverBalanceSats ?? this.serverBalanceSats,
      fundingTxId: fundingTxId ?? this.fundingTxId,
      fundingTxHex: fundingTxHex ?? this.fundingTxHex,
      fundingOutputIndex: fundingOutputIndex ?? this.fundingOutputIndex,
      refundTxHex: refundTxHex ?? this.refundTxHex,
      refundClientSigHex: refundClientSigHex ?? this.refundClientSigHex,
      refundServerSigHex: refundServerSigHex ?? this.refundServerSigHex,
      latestSequenceNumber: latestSequenceNumber ?? this.latestSequenceNumber,
      latestPaymentTxHex: latestPaymentTxHex ?? this.latestPaymentTxHex,
      latestPaymentTxId: latestPaymentTxId ?? this.latestPaymentTxId,
      settlementTxId: settlementTxId ?? this.settlementTxId,
      fundingAncestorTxids: fundingAncestorTxids ?? this.fundingAncestorTxids,
      hasFundingMerkleProof:
          hasFundingMerkleProof ?? this.hasFundingMerkleProof,
      context: context ?? this.context,
      createdAt: createdAt ?? this.createdAt,
      closedAt: closedAt ?? this.closedAt,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }

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

/// Channel payment update record
///
/// Represents a single payment increment within a channel.
/// Each update increases the server's balance and decrements the client's.
class ChannelUpdate {
  /// Channel this update belongs to
  final String channelId;

  /// New server balance after this update (in satoshis)
  final BigInt newServerBalanceSats;

  /// Sequence number for this update (must be > previous)
  final int sequenceNumber;

  /// Client's signature on the payment TX
  final String clientSignature;

  /// Update timestamp
  final DateTime timestamp;

  /// Optional description/purpose for this payment
  final String? description;

  ChannelUpdate({
    required this.channelId,
    required this.newServerBalanceSats,
    required this.sequenceNumber,
    required this.clientSignature,
    DateTime? timestamp,
    this.description,
  }) : timestamp = timestamp ?? DateTime.now();

  /// New server balance as int (for compatibility)
  int get newServerBalanceSatsInt => newServerBalanceSats.toInt();

  /// Payment amount (delta from previous state)
  BigInt paymentAmount(BigInt previousServerBalance) {
    return newServerBalanceSats - previousServerBalance;
  }

  /// Payment amount as int (for compatibility)
  int paymentAmountSats(int previousServerBalance) {
    return newServerBalanceSats.toInt() - previousServerBalance;
  }

  factory ChannelUpdate.fromJson(Map<String, dynamic> json) {
    return ChannelUpdate(
      channelId: json['channelId'] as String,
      newServerBalanceSats:
          PaymentChannel._parseBigInt(json['newServerBalanceSats']),
      sequenceNumber: json['sequenceNumber'] as int,
      clientSignature: json['clientSignature'] as String,
      timestamp: json['timestamp'] != null
          ? DateTime.parse(json['timestamp'] as String)
          : null,
      description: json['description'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'channelId': channelId,
      'newServerBalanceSats': newServerBalanceSats.toString(),
      'sequenceNumber': sequenceNumber,
      'clientSignature': clientSignature,
      'timestamp': timestamp.toIso8601String(),
      if (description != null) 'description': description,
    };
  }
}

/// Common error codes for payment channels
class ChannelErrorCodes {
  static const String insufficientFunds = 'INSUFFICIENT_FUNDS';
  static const String invalidSignature = 'INVALID_SIGNATURE';
  static const String invalidSequence = 'INVALID_SEQUENCE';
  static const String channelNotFound = 'CHANNEL_NOT_FOUND';
  static const String channelClosed = 'CHANNEL_CLOSED';
  static const String channelExpired = 'CHANNEL_EXPIRED';
  static const String fundingFailed = 'FUNDING_FAILED';
  static const String invalidState = 'INVALID_STATE';
  static const String timeout = 'TIMEOUT';
  static const String networkError = 'NETWORK_ERROR';
  static const String peerOffline = 'PEER_OFFLINE';
  static const String protocolError = 'PROTOCOL_ERROR';
}
