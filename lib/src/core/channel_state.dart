import 'package:eventador/eventador.dart';

/// State for a payment channel aggregate
///
/// Represents the current state of a payment channel at a specific point in time.
/// This state is rebuilt from events during aggregate recovery.
///
/// Immutable (bead libspiffy-mmb): every field is final and
/// [fundingAncestorTxids] is an unmodifiable copy. Applying an event produces
/// a new state with [copyWith].
class ChannelState extends State {
  final String channelId;
  final String? walletId;
  final ChannelStatus status;
  final ChannelRole? role;

  // Peer information
  final String? clientPeerId;
  final String? serverPeerId;

  // Cryptographic material
  final String? clientPubKeyHex;
  final String? serverPubKeyHex;
  final String? clientAddressB58;
  final String? serverAddressB58;
  final int? derivationIndex;

  // Funding
  final BigInt fundingAmountSats;
  final String? fundingTxId;
  final String? fundingTxHex;
  final int? fundingOutputIndex;
  final List<String> fundingAncestorTxids;

  /// BEEF of the funding transaction journaled with the opening.
  final String? fundingBeefHex;

  /// Total input value of the funding transaction, when known.
  final int? fundingInputSats;

  /// Broadcasts of the funding transaction started so far (client).
  final int fundingBroadcastAttempts;

  /// A funding broadcast was started and has not failed (client): the
  /// channel may be opened for it.
  final bool fundingBroadcastInFlight;

  /// Error of the last failed funding broadcast, cleared by the next start.
  final String? fundingBroadcastError;

  /// The funding transaction is recorded in the client wallet.
  final bool fundingRecordedInWallet;

  // Refund (T2)
  final int? lockTimeUnix;

  /// The refund template as built (unsigned), or on the server side the
  /// refund it signed.
  final String? refundTxHex;
  final String? refundClientSigHex;
  final String? refundServerSigHex;

  /// The fully signed refund the client holds, verified against the funding
  /// output (libspiffy-b83).
  final String? signedRefundTxHex;

  // Current balances
  final BigInt clientBalanceSats;
  final BigInt serverBalanceSats;

  // Payment state
  final int latestSequenceNumber;
  final String? latestPaymentTxHex;
  final String? latestPaymentTxId;

  /// The client's own signature over the latest payment (bead
  /// libspiffy-z2px). Kept because the 2-of-2 funding output needs both
  /// halves and the server's arrives later, in `payment_ack`: without this
  /// the client cannot assemble the settlement it is owed after a restart.
  /// Null on the server, which holds both halves at acknowledgement.
  final String? latestClientSignatureHex;

  /// Whether this side's wallet already holds the transaction that ended the
  /// channel and paid it back (bead libspiffy-lfrv). The counterpart of
  /// [fundingRecordedInWallet]; what lets a close or an expiry interrupted
  /// before its wallet write be resumed.
  final bool returnLegRecordedInWallet;

  // Metadata
  final String? context;

  /// The app's opaque marker for the counterparty of this channel (bead
  /// libspiffy-bps1, spv-understanding.md "Core Data Management"
  /// requirement 5), journaled with the request or the acceptance.
  ///
  /// It is what the channel stamps on the wallet transactions it records.
  /// Null means the app supplied none, and the recording falls back to the
  /// counterparty's peer id. Kept apart from [context], which is
  /// address-derivation and labelling metadata.
  final String? counterpartyMarker;

  final DateTime? createdAt;
  final DateTime? closedAt;

  @override
  final int version;

  @override
  final DateTime lastModified;

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
    this.latestClientSignatureHex,
    this.returnLegRecordedInWallet = false,
    this.context,
    this.counterpartyMarker,
    this.createdAt,
    this.closedAt,
    this.version = 0,
    DateTime? lastModified,
  })  : fundingAmountSats = fundingAmountSats ?? BigInt.zero,
        clientBalanceSats = clientBalanceSats ?? BigInt.zero,
        serverBalanceSats = serverBalanceSats ?? BigInt.zero,
        fundingAncestorTxids = List<String>.unmodifiable(fundingAncestorTxids ?? const <String>[]),
        lastModified = lastModified ?? DateTime.now(),
        super(version: version, lastModified: lastModified ?? DateTime.now());

  /// Create empty initial state
  factory ChannelState.empty(String channelId) => ChannelState(
        channelId: channelId,
        version: 0,
        lastModified: DateTime.now(),
      );

  static const Object _unset = Object();

  /// A copy of this state with the given fields replaced. The nullable
  /// fields take an explicit null (e.g. `fundingBroadcastError: null`
  /// clears it); a field not given keeps its value.
  @override
  ChannelState copyWith({
    int? version,
    DateTime? lastModified,
    Object? walletId = _unset,
    ChannelStatus? status,
    Object? role = _unset,
    Object? clientPeerId = _unset,
    Object? serverPeerId = _unset,
    Object? clientPubKeyHex = _unset,
    Object? serverPubKeyHex = _unset,
    Object? clientAddressB58 = _unset,
    Object? serverAddressB58 = _unset,
    Object? derivationIndex = _unset,
    BigInt? fundingAmountSats,
    Object? fundingTxId = _unset,
    Object? fundingTxHex = _unset,
    Object? fundingOutputIndex = _unset,
    List<String>? fundingAncestorTxids,
    Object? fundingBeefHex = _unset,
    Object? fundingInputSats = _unset,
    int? fundingBroadcastAttempts,
    bool? fundingBroadcastInFlight,
    Object? fundingBroadcastError = _unset,
    bool? fundingRecordedInWallet,
    Object? lockTimeUnix = _unset,
    Object? refundTxHex = _unset,
    Object? refundClientSigHex = _unset,
    Object? refundServerSigHex = _unset,
    Object? signedRefundTxHex = _unset,
    BigInt? clientBalanceSats,
    BigInt? serverBalanceSats,
    int? latestSequenceNumber,
    Object? latestPaymentTxHex = _unset,
    Object? latestPaymentTxId = _unset,
    Object? latestClientSignatureHex = _unset,
    bool? returnLegRecordedInWallet,
    Object? context = _unset,
    Object? counterpartyMarker = _unset,
    Object? createdAt = _unset,
    Object? closedAt = _unset,
  }) {
    T? pick<T>(Object? given, T? current) => identical(given, _unset) ? current : given as T?;
    return ChannelState(
      channelId: channelId,
      walletId: pick<String>(walletId, this.walletId),
      status: status ?? this.status,
      role: pick<ChannelRole>(role, this.role),
      clientPeerId: pick<String>(clientPeerId, this.clientPeerId),
      serverPeerId: pick<String>(serverPeerId, this.serverPeerId),
      clientPubKeyHex: pick<String>(clientPubKeyHex, this.clientPubKeyHex),
      serverPubKeyHex: pick<String>(serverPubKeyHex, this.serverPubKeyHex),
      clientAddressB58: pick<String>(clientAddressB58, this.clientAddressB58),
      serverAddressB58: pick<String>(serverAddressB58, this.serverAddressB58),
      derivationIndex: pick<int>(derivationIndex, this.derivationIndex),
      fundingAmountSats: fundingAmountSats ?? this.fundingAmountSats,
      fundingTxId: pick<String>(fundingTxId, this.fundingTxId),
      fundingTxHex: pick<String>(fundingTxHex, this.fundingTxHex),
      fundingOutputIndex: pick<int>(fundingOutputIndex, this.fundingOutputIndex),
      fundingAncestorTxids: fundingAncestorTxids ?? this.fundingAncestorTxids,
      fundingBeefHex: pick<String>(fundingBeefHex, this.fundingBeefHex),
      fundingInputSats: pick<int>(fundingInputSats, this.fundingInputSats),
      fundingBroadcastAttempts: fundingBroadcastAttempts ?? this.fundingBroadcastAttempts,
      fundingBroadcastInFlight: fundingBroadcastInFlight ?? this.fundingBroadcastInFlight,
      fundingBroadcastError: pick<String>(fundingBroadcastError, this.fundingBroadcastError),
      fundingRecordedInWallet: fundingRecordedInWallet ?? this.fundingRecordedInWallet,
      lockTimeUnix: pick<int>(lockTimeUnix, this.lockTimeUnix),
      refundTxHex: pick<String>(refundTxHex, this.refundTxHex),
      refundClientSigHex: pick<String>(refundClientSigHex, this.refundClientSigHex),
      refundServerSigHex: pick<String>(refundServerSigHex, this.refundServerSigHex),
      signedRefundTxHex: pick<String>(signedRefundTxHex, this.signedRefundTxHex),
      clientBalanceSats: clientBalanceSats ?? this.clientBalanceSats,
      serverBalanceSats: serverBalanceSats ?? this.serverBalanceSats,
      latestSequenceNumber: latestSequenceNumber ?? this.latestSequenceNumber,
      latestPaymentTxHex: pick<String>(latestPaymentTxHex, this.latestPaymentTxHex),
      latestPaymentTxId: pick<String>(latestPaymentTxId, this.latestPaymentTxId),
      latestClientSignatureHex:
          pick<String>(latestClientSignatureHex, this.latestClientSignatureHex),
      returnLegRecordedInWallet:
          returnLegRecordedInWallet ?? this.returnLegRecordedInWallet,
      context: pick<String>(context, this.context),
      counterpartyMarker:
          pick<String>(counterpartyMarker, this.counterpartyMarker),
      createdAt: pick<DateTime>(createdAt, this.createdAt),
      closedAt: pick<DateTime>(closedAt, this.closedAt),
      version: version ?? this.version,
      lastModified: lastModified ?? this.lastModified,
    );
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

