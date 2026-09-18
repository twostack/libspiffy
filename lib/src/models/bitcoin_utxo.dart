import 'package:dartsv/dartsv.dart' as dartsv;

/// Sentinel value for copyWith to distinguish between null and not provided
const _sentinel = Object();

/// Enumeration of UTXO statuses
enum UTXOStatus {
  /// UTXO is pending network confirmation (not yet spendable)
  pending,
  /// UTXO is available for spending
  available,
  /// UTXO is reserved for a pending transaction
  reserved,
  /// UTXO has been spent
  spent,

  /// The output of a transaction the wallet resolved as one the network will
  /// not settle: a deferred payment that failed, was cancelled, or was
  /// reclaimed by the wallet's own self-spend of its inputs (bead
  /// libspiffy-3arz).
  ///
  /// The row is kept exactly as it is — nothing is ever deleted
  /// (spv-understanding.md, Data Retention) — but it is not funds on the way:
  /// it counts towards no balance bucket (`WalletBalances.bucketOf`) and is
  /// never selected for spending. It says what is true about the output
  /// instead of leaving it [pending] forever behind a transaction that can
  /// never be mined.
  ///
  /// It is **not** terminal against evidence. A merkle proof on the active
  /// header chain outranks any resolution we recorded (a cancelled payment
  /// the recipient broadcast after all, bead libspiffy-4r0), so confirming
  /// the transaction makes its voided outputs [available], exactly as it
  /// does its [pending] ones, and recording the same payment again takes
  /// them back to [pending].
  ///
  /// Appended after [spent]: statuses are journaled and stored by name, so a
  /// journal, snapshot or read-model row written before this status reads
  /// back unchanged.
  voided,
}

/// Represents a Bitcoin UTXO (Unspent Transaction Output) in the wallet.
/// 
/// Based on the BitcoinUtxo model from speculative code, adapted for
/// the event-sourced wallet architecture with DartSV integration.
class BitcoinUtxo {
  /// Transaction ID that created this UTXO
  final String txid;
  
  /// Output index within the transaction
  final int vout;
  
  /// Amount in satoshis (using DartSV's Coin for precision)
  final dartsv.Coin value;
  
  /// Script that locks this UTXO
  final String scriptPubKey;
  
  /// Address that owns this UTXO
  final String address;
  
  /// Current status of this UTXO
  final UTXOStatus status;
  
  /// Block height where this UTXO was confirmed (null if unconfirmed)
  final int? blockHeight;
  
  /// Number of confirmations (null if unconfirmed)
  final int? confirmations;
  
  /// Timestamp when this UTXO was first detected
  final DateTime createdAt;
  
  /// Timestamp when this UTXO was last updated
  final DateTime updatedAt;
  
  /// Transaction ID that reserved this UTXO (if status is reserved)
  final String? reservedByTxId;
  
  /// When the reservation expires (if status is reserved)
  final DateTime? reservationExpiresAt;
  
  /// Priority of the reservation (higher numbers = higher priority)
  final int? reservationPriority;
  
  /// Reason for the reservation (if status is reserved)
  final String? reservationReason;
  
  /// Derivation index used to generate the address (for HD wallets)
  final int? derivationIndex;

  /// Status the UTXO had when it was reserved ([UTXOStatus.pending] or
  /// [UTXOStatus.available]); null when not reserved, or when the value is
  /// unknown (loaded from a store that does not record it).
  /// [releaseReservation] restores it, so releasing a reservation on an
  /// unconfirmed UTXO does not make it spendable (audit 2026-09-14 M4).
  final UTXOStatus? statusBeforeReservation;

  /// Transaction that spent this UTXO, when [status] is [UTXOStatus.spent]
  /// and the spend was recorded with it (null for UTXOs spent before this
  /// field existed, or loaded from a store that does not record it).
  final String? spentInTxId;

  /// Plugin-provided metadata for token/custom script UTXOs.
  ///
  /// Populated by [ScriptPlugin.extractMetadata()] during UTXO indexing.
  /// Contains plugin-specific data such as tokenId, token type, owner,
  /// and amount, under the 'pluginId' of the plugin that manages the UTXO
  /// ([isPluginManaged]). Read-model rows also carry script-analysis
  /// metadata here (script type, address) for plain outputs, without a
  /// 'pluginId'.
  final Map<String, dynamic>? pluginMetadata;

  const BitcoinUtxo({
    required this.txid,
    required this.vout,
    required this.value,
    required this.scriptPubKey,
    required this.address,
    required this.status,
    this.blockHeight,
    this.confirmations,
    required this.createdAt,
    required this.updatedAt,
    this.reservedByTxId,
    this.reservationExpiresAt,
    this.reservationPriority,
    this.reservationReason,
    this.derivationIndex,
    this.pluginMetadata,
    this.statusBeforeReservation,
    this.spentInTxId,
  });
  
  /// Create a new UTXO from transaction output
  factory BitcoinUtxo.create({
    required String txid,
    required int vout,
    required BigInt satoshis,
    required String scriptPubKey,
    required String address,
    int? blockHeight,
    int? confirmations,
    int? derivationIndex,
    Map<String, dynamic>? pluginMetadata,
    UTXOStatus status = UTXOStatus.pending,
    DateTime? createdAt,
  }) {
    // Event handlers pass the event's timestamp, so replaying the event
    // yields the same UTXO (audit 2026-09-14 L1).
    final now = createdAt ?? DateTime.now();
    return BitcoinUtxo(
      txid: txid,
      vout: vout,
      value: dartsv.Coin.ofSat(satoshis),
      scriptPubKey: scriptPubKey,
      address: address,
      status: status,
      blockHeight: blockHeight,
      confirmations: confirmations,
      createdAt: now,
      updatedAt: now,
      derivationIndex: derivationIndex,
      pluginMetadata: pluginMetadata,
    );
  }
  
  /// Unique key for this UTXO (txid:vout)
  String get key => '$txid:$vout';
  
  /// Amount in satoshis as BigInt
  BigInt get satoshis => value.getValue();
  
  /// Check if this UTXO is confirmed
  bool get isConfirmed => blockHeight != null && (confirmations ?? 0) > 0;
  
  /// Check if this UTXO is available for spending
  bool get isAvailable => status == UTXOStatus.available;
  
  /// Check if this UTXO is reserved
  bool get isReserved => status == UTXOStatus.reserved;
  
  /// Check if this UTXO is spent
  bool get isSpent => status == UTXOStatus.spent;

  /// Whether this output belongs to a transaction the network will not
  /// settle ([UTXOStatus.voided], bead libspiffy-3arz).
  bool get isVoided => status == UTXOStatus.voided;

  /// Create a copy with updated fields
  BitcoinUtxo copyWith({
    String? txid,
    int? vout,
    dartsv.Coin? value,
    String? scriptPubKey,
    String? address,
    UTXOStatus? status,
    int? blockHeight,
    int? confirmations,
    DateTime? createdAt,
    DateTime? updatedAt,
    Object? reservedByTxId = _sentinel,
    Object? reservationExpiresAt = _sentinel,
    Object? reservationPriority = _sentinel,
    Object? reservationReason = _sentinel,
    int? derivationIndex,
    Object? pluginMetadata = _sentinel,
    Object? statusBeforeReservation = _sentinel,
    Object? spentInTxId = _sentinel,
  }) {
    return BitcoinUtxo(
      txid: txid ?? this.txid,
      vout: vout ?? this.vout,
      value: value ?? this.value,
      scriptPubKey: scriptPubKey ?? this.scriptPubKey,
      address: address ?? this.address,
      status: status ?? this.status,
      blockHeight: blockHeight ?? this.blockHeight,
      confirmations: confirmations ?? this.confirmations,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      reservedByTxId: reservedByTxId == _sentinel ? this.reservedByTxId : reservedByTxId as String?,
      reservationExpiresAt: reservationExpiresAt == _sentinel ? this.reservationExpiresAt : reservationExpiresAt as DateTime?,
      reservationPriority: reservationPriority == _sentinel ? this.reservationPriority : reservationPriority as int?,
      reservationReason: reservationReason == _sentinel ? this.reservationReason : reservationReason as String?,
      derivationIndex: derivationIndex ?? this.derivationIndex,
      pluginMetadata: pluginMetadata == _sentinel ? this.pluginMetadata : pluginMetadata as Map<String, dynamic>?,
      statusBeforeReservation: statusBeforeReservation == _sentinel
          ? this.statusBeforeReservation
          : statusBeforeReservation as UTXOStatus?,
      spentInTxId: spentInTxId == _sentinel ? this.spentInTxId : spentInTxId as String?,
    );
  }
  
  // Every transition below takes an optional [timestamp]: the time the
  // change happened. Code applying an event must pass the event's timestamp
  // so that state rebuilt from the journal equals the state that applied the
  // event live (audit 2026-09-14 L1); it defaults to the current time.

  /// Reserve this UTXO for a transaction
  BitcoinUtxo reserve(String transactionId, {
    Duration? duration,
    int priority = 0,
    String? reason,
    DateTime? timestamp,
  }) {
    final now = timestamp ?? DateTime.now();
    final expiresAt = duration != null ? now.add(duration) : null;

    return copyWith(
      status: UTXOStatus.reserved,
      statusBeforeReservation: statusToRestoreOnRelease,
      reservedByTxId: transactionId,
      reservationExpiresAt: expiresAt,
      reservationPriority: priority,
      reservationReason: reason,
      updatedAt: now,
    );
  }
  
  /// Mark this UTXO as spent (by [spentInTxId], when known)
  BitcoinUtxo markSpent({DateTime? timestamp, String? spentInTxId}) {
    return copyWith(
      status: UTXOStatus.spent,
      spentInTxId: spentInTxId ?? this.spentInTxId,
      updatedAt: timestamp ?? DateTime.now(),
    );
  }
  
  /// Mark this output as one of a transaction the network will not settle
  /// ([UTXOStatus.voided], bead libspiffy-3arz). Nothing else changes: the
  /// row, its amount, its script and its history are kept.
  BitcoinUtxo markVoided({DateTime? timestamp}) {
    return copyWith(
      status: UTXOStatus.voided,
      updatedAt: timestamp ?? DateTime.now(),
    );
  }

  /// Mark this UTXO as available for spending
  BitcoinUtxo markAvailable({DateTime? timestamp}) {
    return copyWith(
      status: UTXOStatus.available,
      updatedAt: timestamp ?? DateTime.now(),
    );
  }
  
  /// The status a reservation placed now should restore on release: the
  /// current status, or the remembered one when this UTXO is already
  /// reserved (a higher-priority reservation replacing a lower one).
  UTXOStatus get statusToRestoreOnRelease => status == UTXOStatus.reserved
      ? (statusBeforeReservation ?? UTXOStatus.available)
      : status;

  /// Release reservation on this UTXO, restoring the status it had before
  /// it was reserved ([restoreStatus] overrides it; unknown means
  /// [UTXOStatus.available], the behaviour before the status was recorded).
  BitcoinUtxo releaseReservation({UTXOStatus? restoreStatus, DateTime? timestamp}) {
    return copyWith(
      status: restoreStatus ?? statusBeforeReservation ?? UTXOStatus.available,
      statusBeforeReservation: null,
      reservedByTxId: null,
      reservationExpiresAt: null,
      reservationPriority: null,
      reservationReason: null,
      updatedAt: timestamp ?? DateTime.now(),
    );
  }

  /// Renew/extend the reservation on this UTXO. A reservation without an
  /// expiry is extended from [timestamp] (default: now).
  BitcoinUtxo renewReservation(Duration extension, {String? reason, DateTime? timestamp}) {
    if (status != UTXOStatus.reserved) {
      throw StateError('Cannot renew reservation on non-reserved UTXO');
    }
    
    final now = timestamp ?? DateTime.now();
    final currentExpiry = reservationExpiresAt ?? now;
    final newExpiry = currentExpiry.add(extension);
    
    return copyWith(
      reservationExpiresAt: newExpiry,
      reservationReason: reason ?? reservationReason,
      updatedAt: now,
    );
  }

  /// Check if this UTXO's reservation has expired
  bool get isReservationExpired {
    if (status != UTXOStatus.reserved || reservationExpiresAt == null) {
      return false;
    }
    return DateTime.now().isAfter(reservationExpiresAt!);
  }

  /// Check if this UTXO is effectively available (either truly available or reservation expired)
  bool get isEffectivelyAvailable {
    return status == UTXOStatus.available || 
           (status == UTXOStatus.reserved && isReservationExpired);
  }

  /// Whether this UTXO carries any [pluginMetadata]. In the read model
  /// every row carries script-analysis metadata (script type, address), so
  /// this does not say the UTXO belongs to a plugin: [isPluginManaged] does.
  bool get hasPluginMetadata => pluginMetadata != null;

  /// Whether this UTXO is managed by a script plugin (e.g. a token protocol,
  /// or a funding earmark): its [pluginMetadata] names a `pluginId`.
  /// Plugin-managed UTXOs are spent by their plugin and are never selected
  /// or counted as balance for ordinary BSV payments.
  ///
  /// The one rule for both the wallet aggregate and the read side (bead
  /// libspiffy-ecy8): metadata without a `pluginId` (the read model's
  /// script analysis of a plain output, or a label) does not make a UTXO
  /// plugin-managed.
  bool get isPluginManaged => pluginMetadata?['pluginId'] != null;

  /// Get time remaining on reservation (null if not reserved or no expiry)
  Duration? get reservationTimeRemaining {
    if (status != UTXOStatus.reserved || reservationExpiresAt == null) {
      return null;
    }
    final remaining = reservationExpiresAt!.difference(DateTime.now());
    return remaining.isNegative ? Duration.zero : remaining;
  }
  
  /// Update confirmation information
  /// When confirmations > 0 and UTXO is pending, it becomes available
  BitcoinUtxo updateConfirmations({
    required int blockHeight,
    required int confirmations,
    DateTime? timestamp,
  }) {
    // If UTXO is pending and now has confirmations, make it available. A
    // voided output whose transaction turns out to be mined after all is
    // available too (bead libspiffy-3arz): the proof outranks the resolution
    // that voided it.
    final newStatus =
        ((status == UTXOStatus.pending || status == UTXOStatus.voided) && confirmations > 0)
            ? UTXOStatus.available
            : status;
    // A reserved UTXO stays reserved, but what its release restores follows
    // the confirmation: a pending coin confirmed while reserved is available
    // once released.
    final restore = (status == UTXOStatus.reserved &&
            statusBeforeReservation == UTXOStatus.pending &&
            confirmations > 0)
        ? UTXOStatus.available
        : statusBeforeReservation;

    return copyWith(
      status: newStatus,
      statusBeforeReservation: restore,
      blockHeight: blockHeight,
      confirmations: confirmations,
      updatedAt: timestamp ?? DateTime.now(),
    );
  }
  
  /// Convert to map for serialization. Every field is included, so
  /// [BitcoinUtxo.fromMap] restores an equal UTXO (aggregate snapshots rely
  /// on it; audit 2026-09-14 M6). Dates are ISO-8601 strings and amounts
  /// decimal strings.
  Map<String, dynamic> toMap() {
    return {
      'txid': txid,
      'vout': vout,
      'satoshis': satoshis.toString(),
      'scriptPubKey': scriptPubKey,
      'address': address,
      'status': status.name,
      'blockHeight': blockHeight,
      'confirmations': confirmations,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
      'reservedByTxId': reservedByTxId,
      if (reservationExpiresAt != null)
        'reservationExpiresAt': reservationExpiresAt!.toIso8601String(),
      if (reservationPriority != null) 'reservationPriority': reservationPriority,
      if (reservationReason != null) 'reservationReason': reservationReason,
      'derivationIndex': derivationIndex,
      if (pluginMetadata != null) 'pluginMetadata': pluginMetadata,
      if (statusBeforeReservation != null)
        'statusBeforeReservation': statusBeforeReservation!.name,
      if (spentInTxId != null) 'spentInTxId': spentInTxId,
    };
  }
  
  /// Create from map (deserialization)
  factory BitcoinUtxo.fromMap(Map<String, dynamic> map) {
    return BitcoinUtxo(
      txid: map['txid'] as String,
      vout: map['vout'] as int,
      value: dartsv.Coin.ofSat(BigInt.parse(map['satoshis'] as String)),
      scriptPubKey: map['scriptPubKey'] as String,
      address: map['address'] as String,
      status: UTXOStatus.values.firstWhere(
        (s) => s.name == map['status'],
        orElse: () => UTXOStatus.available,
      ),
      blockHeight: map['blockHeight'] as int?,
      confirmations: map['confirmations'] as int?,
      createdAt: _parseDate(map['createdAt'])!,
      updatedAt: _parseDate(map['updatedAt'])!,
      reservedByTxId: map['reservedByTxId'] as String?,
      reservationExpiresAt: _parseDate(map['reservationExpiresAt']),
      reservationPriority: map['reservationPriority'] as int?,
      reservationReason: map['reservationReason'] as String?,
      derivationIndex: map['derivationIndex'] as int?,
      pluginMetadata: map['pluginMetadata'] != null
          ? Map<String, dynamic>.from(map['pluginMetadata'] as Map)
          : null,
      statusBeforeReservation: UTXOStatus.values
          .where((s) => s.name == map['statusBeforeReservation'])
          .firstOrNull,
      spentInTxId: map['spentInTxId'] as String?,
    );
  }
  
  /// An ISO-8601 string, or a [DateTime] (a CBOR round trip of a map that
  /// held one decodes it as a date).
  static DateTime? _parseDate(Object? value) => switch (value) {
        null => null,
        DateTime d => d,
        _ => DateTime.parse(value as String),
      };

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is BitcoinUtxo &&
        other.txid == txid &&
        other.vout == vout;
  }
  
  @override
  int get hashCode => txid.hashCode ^ vout.hashCode;
  
  @override
  String toString() {
    return 'BitcoinUtxo(key: $key, value: $satoshis sats, status: ${status.name}, '
        'address: $address, confirmations: $confirmations)';
  }
} 