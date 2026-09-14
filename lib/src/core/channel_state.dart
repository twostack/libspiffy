import 'package:eventador/eventador.dart';

/// State for a payment channel aggregate
/// 
/// Represents the current state of a payment channel at a specific point in time.
/// This state is rebuilt from events during aggregate recovery.
/// 
/// NOTE: Fields are mutable to allow direct state updates in eventHandler.
/// This follows the Eventador AggregateRoot pattern with imperative state management.
class ChannelState extends State {
  final String channelId;
  String? walletId;
  ChannelStatus status;
  ChannelRole? role;
  
  // Peer information
  String? clientPeerId;
  String? serverPeerId;
  
  // Cryptographic material
  String? clientPubKeyHex;
  String? serverPubKeyHex;
  String? clientAddressB58;
  String? serverAddressB58;
  int? derivationIndex;
  
  // Funding
  BigInt fundingAmountSats;
  String? fundingTxId;
  String? fundingTxHex;
  int? fundingOutputIndex;
  List<String> fundingAncestorTxids;

  /// BEEF of the funding transaction journaled with the opening.
  String? fundingBeefHex;

  /// Total input value of the funding transaction, when known.
  int? fundingInputSats;

  /// Broadcasts of the funding transaction started so far (client).
  int fundingBroadcastAttempts;

  /// A funding broadcast was started and has not failed (client): the
  /// channel may be opened for it.
  bool fundingBroadcastInFlight;

  /// Error of the last failed funding broadcast, cleared by the next start.
  String? fundingBroadcastError;

  /// The funding transaction is recorded in the client wallet.
  bool fundingRecordedInWallet;
  
  // Refund (T2)
  int? lockTimeUnix;

  /// The refund template as built (unsigned), or on the server side the
  /// refund it signed.
  String? refundTxHex;
  String? refundClientSigHex;
  String? refundServerSigHex;

  /// The fully signed refund the client holds, verified against the funding
  /// output (libspiffy-b83).
  String? signedRefundTxHex;
  
  // Current balances
  BigInt clientBalanceSats;
  BigInt serverBalanceSats;
  
  // Payment state
  int latestSequenceNumber;
  String? latestPaymentTxHex;
  String? latestPaymentTxId;
  
  // Metadata
  String? context;
  DateTime? createdAt;
  DateTime? closedAt;

  /// Override parent State version/lastModified with mutable fields
  @override
  int version;

  @override
  DateTime lastModified;

  ChannelState({
    required this.channelId,
    this.walletId,
    this.status = ChannelStatus.pending,
    this.role,
    this.clientPeerId,
    this.serverPeerId,
    this.clientPubKeyHex,
    this.serverPubKeyHex,
    this.clientAddressB58,
    this.serverAddressB58,
    this.derivationIndex,
    BigInt? fundingAmountSats,
    this.fundingTxId,
    this.fundingTxHex,
    this.fundingOutputIndex,
    List<String>? fundingAncestorTxids,
    this.fundingBeefHex,
    this.fundingInputSats,
    this.fundingBroadcastAttempts = 0,
    this.fundingBroadcastInFlight = false,
    this.fundingBroadcastError,
    this.fundingRecordedInWallet = false,
    this.lockTimeUnix,
    this.refundTxHex,
    this.refundClientSigHex,
    this.refundServerSigHex,
    this.signedRefundTxHex,
    BigInt? clientBalanceSats,
    BigInt? serverBalanceSats,
    this.latestSequenceNumber = 0,
    this.latestPaymentTxHex,
    this.latestPaymentTxId,
    this.context,
    this.createdAt,
    this.closedAt,
    this.version = 0,
    DateTime? lastModified,
  })  : fundingAmountSats = fundingAmountSats ?? BigInt.zero,
        clientBalanceSats = clientBalanceSats ?? BigInt.zero,
        serverBalanceSats = serverBalanceSats ?? BigInt.zero,
        fundingAncestorTxids = fundingAncestorTxids ?? [],
        lastModified = lastModified ?? DateTime.now(),
        super(version: version, lastModified: lastModified ?? DateTime.now());

  /// Create empty initial state
  factory ChannelState.empty(String channelId) => ChannelState(
        channelId: channelId,
        version: 0,
        lastModified: DateTime.now(),
      );

  @override
  State copyWith({int? version, DateTime? lastModified}) {
    // We don't use copyWith pattern in this implementation
    // State mutations happen directly in eventHandler
    throw UnimplementedError('copyWith not used for ChannelState');
  }

  // Computed properties
  bool get isOpen => status == ChannelStatus.open;
  bool get isClient => role == ChannelRole.client;
  bool get isServer => role == ChannelRole.server;
  bool get isExpired {
    if (lockTimeUnix == null) return false;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return now >= lockTimeUnix!;
  }

  BigInt get remainingBalance => clientBalanceSats;
  BigInt get totalPaid => serverBalanceSats;

  @override
  String toString() {
    return 'ChannelState(channelId: $channelId, status: ${status.name}, '
        'role: ${role?.name}, balances: client=$clientBalanceSats server=$serverBalanceSats, '
        'seq: $latestSequenceNumber)';
  }
}

/// Status of a payment channel
enum ChannelStatus {
  pending,      // Channel requested, awaiting acceptance
  accepted,     // Server accepted, awaiting refund signing
  refundSigned, // Refund signed, awaiting funding broadcast
  open,         // Channel open, can make payments
  closing,      // Close initiated
  closed,       // Channel closed (settlement broadcast)
  expired,      // Refund claimed after timeout
  rejected,     // Channel request rejected
}

/// Role in a payment channel
enum ChannelRole {
  client, // Funder - opens channel, makes payments
  server, // Receiver - accepts payments
}

