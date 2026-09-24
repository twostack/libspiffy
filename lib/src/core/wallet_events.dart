import 'package:libspiffy/src/models/bitcoin_transaction.dart';
import 'package:libspiffy/src/models/bitcoin_utxo.dart';

import '../models/address_chain.dart';
import '../models/key_path.dart';
import '../models/persistent_map.dart';
import '../models/wallet_event.dart';
import '../models/wallet_type.dart';

// =============================================================================
// WALLET LIFECYCLE EVENTS
// =============================================================================

/// Event fired when a wallet is created
class WalletCreatedEvent extends WalletEvent {
  /// Journal identifier of this event type. Stored with every event and
  /// independent of the class name; never change it (audit 2026-09-14 M8).
  static const String stableTypeName = 'wallet.created';

  @override
  String get typeName => stableTypeName;

  final String walletName;
  final String rootAddress; // Initial address generated from mnemonic/wif/xpriv
  final WalletType walletType; // Type of wallet (hd, wif, xpriv)
  final Map<String, dynamic>? walletMetadata;

  /// Never persisted, and no longer set by the wallet aggregate.
  ///
  /// The account xpub exposes every address and the balance of the wallet,
  /// so it is kept only in secure storage (`wallet_hdpubkey_<walletId>`),
  /// which the aggregate reads when it derives addresses. Earlier releases
  /// also wrote it into this event: such rows still replay and [fromMap]
  /// still reads the value into this field (so a recovery tool can use it),
  /// but [toMap] never writes it again (audit 2026-09-14 KM-8).
  @Deprecated('The xpub is kept out of the event journal; read it from '
      'SecureStorage (wallet_hdpubkey_<walletId>). Will be removed.')
  final String? hdPublicKeyXpub;

  WalletCreatedEvent({
    required String walletId,
    required this.walletName,
    required this.rootAddress,
    required this.walletType,
    Map<String, dynamic>? walletMetadata,
    @Deprecated('Not persisted; see the hdPublicKeyXpub field.')
    this.hdPublicKeyXpub,
    String? eventId,
    DateTime? timestamp,
    int? version,
    Map<String, dynamic>? metadata,
  })  : walletMetadata = frozenPlainMapOrNull(walletMetadata),
        super(
          walletId: walletId,
          eventId: eventId,
          timestamp: timestamp,
          version: version,
          metadata: metadata,
        );

  @override
  Map<String, dynamic> getWalletEventData() {
    return {
      'walletName': walletName,
      'rootAddress': rootAddress,
      'walletType': walletType.toStorageString(),
      'walletMetadata': walletMetadata,
      // No 'hdPublicKeyXpub': the xpub stays out of the journal (KM-8).
    };
  }

  static WalletCreatedEvent fromMap(Map<String, dynamic> map) {
    return WalletCreatedEvent(
      walletId: map['walletId'] as String,
      walletName: map['walletName'] as String,
      rootAddress: map['rootAddress'] as String,
      walletType: WalletTypeExtension.fromStorageString(
        map['walletType'] as String? ?? 'hd', // Default to HD for backwards compatibility
      ),
      walletMetadata: map['walletMetadata'] as Map<String, dynamic>?,
      // Rows written before KM-8 carry the xpub. Keep it readable in memory
      // (nothing read from the journal is dropped); toMap never writes it.
      // ignore: deprecated_member_use_from_same_package
      hdPublicKeyXpub: map['hdPublicKeyXpub'] as String?,
      eventId: map['eventId'] as String?,
      timestamp: map['timestamp'] != null
          ? (map['timestamp'] is String
              ? DateTime.parse(map['timestamp'] as String)
              : map['timestamp'] as DateTime)
          : null,
      version: map['version'] as int?,
      metadata: map['metadata'] as Map<String, dynamic>?,
    );
  }
}

/// Event fired when a wallet is permanently deleted
class WalletDeletedEvent extends WalletEvent {
  /// Journal identifier of this event type. Stored with every event and
  /// independent of the class name; never change it (audit 2026-09-14 M8).
  static const String stableTypeName = 'wallet.deleted';

  @override
  String get typeName => stableTypeName;

  final String? reason;

  WalletDeletedEvent({
    required String walletId,
    this.reason,
    String? eventId,
    DateTime? timestamp,
    int? version,
    Map<String, dynamic>? metadata,
  }) : super(
          walletId: walletId,
          eventId: eventId,
          timestamp: timestamp,
          version: version,
          metadata: metadata,
        );

  @override
  Map<String, dynamic> getWalletEventData() {
    return {
      if (reason != null) 'reason': reason,
    };
  }

  static WalletDeletedEvent fromMap(Map<String, dynamic> map) {
    return WalletDeletedEvent(
      walletId: map['walletId'] as String,
      reason: map['reason'] as String?,
      eventId: map['eventId'] as String?,
      timestamp: map['timestamp'] != null
          ? (map['timestamp'] is String
              ? DateTime.parse(map['timestamp'] as String)
              : map['timestamp'] as DateTime)
          : null,
      version: map['version'] as int?,
      metadata: map['metadata'] as Map<String, dynamic>?,
    );
  }
}

/// Event fired when wallet configuration is updated
class WalletConfigurationUpdatedEvent extends WalletEvent {
  /// Journal identifier of this event type. Stored with every event and
  /// independent of the class name; never change it (audit 2026-09-14 M8).
  static const String stableTypeName = 'wallet.configuration_updated';

  @override
  String get typeName => stableTypeName;

  final String? newName;
  final Map<String, dynamic>? newMetadata;

  WalletConfigurationUpdatedEvent({
    required String walletId,
    this.newName,
    Map<String, dynamic>? newMetadata,
    String? eventId,
    DateTime? timestamp,
    int? version,
    Map<String, dynamic>? metadata,
  })  : newMetadata = frozenPlainMapOrNull(newMetadata),
        super(
          walletId: walletId,
          eventId: eventId,
          timestamp: timestamp,
          version: version,
          metadata: metadata,
        );

  @override
  Map<String, dynamic> getWalletEventData() {
    return {
      'newName': newName,
      'newMetadata': newMetadata,
    };
  }

  static WalletConfigurationUpdatedEvent fromMap(Map<String, dynamic> map) {
    return WalletConfigurationUpdatedEvent(
      walletId: map['walletId'] as String,
      newName: map['newName'] as String?,
      newMetadata: map['newMetadata'] as Map<String, dynamic>?,
      eventId: map['eventId'] as String?,
      timestamp: map['timestamp'] != null
          ? (map['timestamp'] is String 
              ? DateTime.parse(map['timestamp'] as String)
              : map['timestamp'] as DateTime)
          : null,
      version: map['version'] as int?,
      metadata: map['metadata'] as Map<String, dynamic>?,
    );
  }
}

/// Event fired when an address is discovered during import
class AddressDiscoveredEvent extends WalletEvent {
  /// Journal identifier of this event type. Stored with every event and
  /// independent of the class name; never change it (audit 2026-09-14 M8).
  static const String stableTypeName = 'wallet.address.discovered';

  @override
  String get typeName => stableTypeName;

  final String address;
  final int derivationIndex;

  /// The chain the address is on. Events journaled before the delegated
  /// chain existed carry only `isChange` ([AddressChain.fromRecord]).
  final AddressChain chain;
  final int transactionCount;

  AddressDiscoveredEvent({
    required String walletId,
    required this.address,
    required this.derivationIndex,
    required this.chain,
    required this.transactionCount,
    String? eventId,
    DateTime? timestamp,
    int? version,
    Map<String, dynamic>? metadata,
  }) : super(
          walletId: walletId,
          eventId: eventId,
          timestamp: timestamp,
          version: version,
          metadata: metadata,
        );

  @override
  Map<String, dynamic> getWalletEventData() {
    return {
      'address': address,
      'derivationIndex': derivationIndex,
      'chain': chain.index,
      // Kept so a release that knows only `isChange` still reads the event.
      'isChange': chain == AddressChain.change,
      'transactionCount': transactionCount,
    };
  }

  static AddressDiscoveredEvent fromMap(Map<String, dynamic> map) {
    return AddressDiscoveredEvent(
      walletId: map['walletId'] as String,
      address: map['address'] as String,
      derivationIndex: map['derivationIndex'] as int,
      chain: AddressChain.fromRecord(chain: map['chain'], isChange: map['isChange']),
      transactionCount: map['transactionCount'] as int,
      eventId: map['eventId'] as String?,
      timestamp: map['timestamp'] != null
          ? (map['timestamp'] is String
              ? DateTime.parse(map['timestamp'] as String)
              : map['timestamp'] as DateTime)
          : null,
      version: map['version'] as int?,
      metadata: map['metadata'] as Map<String, dynamic>?,
    );
  }
}

/// A transaction a received BEEF carried as an ancestor of the paid
/// transaction, with its BUMP when it is proven (bead libspiffy-zsh).
///
/// Journaled on [TransactionImportedEvent.ancestors] so that the received
/// outputs can be spent before the paid transaction is mined: an outgoing
/// BEEF must carry the paid transaction's ancestors back to proven ones, and
/// nothing can supply them later.
class BeefAncestor {
  /// Display-order txid of [rawHex].
  final String txid;

  /// The raw transaction.
  final String rawHex;

  /// Hex of the BRC-74 BUMP proving [txid]; empty for an unproven ancestor
  /// (one whose own parents are further ancestors).
  final String bumpHex;

  const BeefAncestor({required this.txid, required this.rawHex, this.bumpHex = ''});

  bool get isProven => bumpHex.isNotEmpty;

  Map<String, dynamic> toMap() => {
        'txid': txid,
        'rawHex': rawHex,
        if (bumpHex.isNotEmpty) 'bumpHex': bumpHex,
      };

  factory BeefAncestor.fromMap(Map<dynamic, dynamic> map) => BeefAncestor(
        txid: map['txid'] as String,
        rawHex: map['rawHex'] as String,
        bumpHex: map['bumpHex'] as String? ?? '',
      );

  @override
  bool operator ==(Object other) =>
      other is BeefAncestor && other.txid == txid && other.rawHex == rawHex && other.bumpHex == bumpHex;

  @override
  int get hashCode => Object.hash(txid, rawHex, bumpHex);

  @override
  String toString() => 'BeefAncestor($txid${isProven ? ', proven' : ''})';
}

/// Event fired when a transaction is imported
class TransactionImportedEvent extends WalletEvent {
  /// Journal identifier of this event type. Stored with every event and
  /// independent of the class name; never change it (audit 2026-09-14 M8).
  static const String stableTypeName = 'wallet.transaction.imported';

  @override
  String get typeName => stableTypeName;

  final String txid;
  final String rawHex;

  /// The block a verified merkle proof puts this transaction in, and null
  /// when nothing proves it is in one (bead libspiffy-nys0). An unproven
  /// import used to journal height 0 — the genesis block — because this
  /// could not hold an absence. Set together with [bumpProof]: a height
  /// here means the BUMP in [bumpProof] checked out against a header on
  /// our active chain, which is what "confirmed" means anywhere in this
  /// library (bead libspiffy-jc3h).
  final int? blockHeight;
  final String bumpProof; // Serialized BUMP format
  
  // Parsed transaction data (from BEEF import)
  final int totalOutputSats;
  final int numInputs;
  final int numOutputs;
  final int txVersion;
  final int txLockTime;
  
  // Wallet-specific data (which outputs belong to us)
  final List<String> walletReceivingAddresses; // Our addresses that received funds
  final int walletReceivedSats; // Total sats received by wallet in this tx
  
  // Input data (extracted from parent transactions in BEEF)
  final int totalInputSats; // Total value of all inputs (from parent tx outputs)
  final List<String> sendingAddresses; // Addresses that inputs are spending from

  /// For a transaction received unproven (empty [bumpProof]): the ancestors
  /// its BEEF carried back to proven transactions, with their BUMPs, parents
  /// first (bead libspiffy-zsh). Empty for a proven transaction and for rows
  /// journaled before the field existed (the key is written only when not
  /// empty, so such rows and events without ancestors serialize as before).
  final List<BeefAncestor> ancestors;

  /// The app's opaque marker for the counterparty this payment was with
  /// (bead libspiffy-cq16, spv-understanding.md "Core Data Management"
  /// requirement 5): an Ed25519 identity key, an email address, a peer id,
  /// an internal account id. libspiffy stores it and never interprets it.
  /// It is not an address and not the address-derived counterparty columns
  /// of the read model. Null when the app supplied none, and on rows
  /// journaled before the field existed, which replay unchanged: the key is
  /// written only when there is a marker, so an event without one
  /// serializes exactly as before.
  final String? counterpartyMarker;

  TransactionImportedEvent({
    required String walletId,
    required this.txid,
    required this.rawHex,
    required this.blockHeight,
    required this.bumpProof,
    required this.totalOutputSats,
    required this.numInputs,
    required this.numOutputs,
    required this.txVersion,
    required this.txLockTime,
    required List<String> walletReceivingAddresses,
    required this.walletReceivedSats,
    required this.totalInputSats,
    required List<String> sendingAddresses,
    List<BeefAncestor> ancestors = const [],
    this.counterpartyMarker,
    String? eventId,
    DateTime? timestamp,
    int? version,
    Map<String, dynamic>? metadata,
  })  : walletReceivingAddresses = frozenList(walletReceivingAddresses),
        sendingAddresses = frozenList(sendingAddresses),
        ancestors = frozenList(ancestors),
        super(
          walletId: walletId,
          eventId: eventId,
          timestamp: timestamp,
          version: version,
          metadata: metadata,
        );

  @override
  Map<String, dynamic> getWalletEventData() {
    return {
      'txid': txid,
      'rawHex': rawHex,
      'blockHeight': blockHeight,
      'bumpProof': bumpProof,
      'totalOutputSats': totalOutputSats,
      'numInputs': numInputs,
      'numOutputs': numOutputs,
      'txVersion': txVersion,
      'txLockTime': txLockTime,
      'walletReceivingAddresses': walletReceivingAddresses,
      'walletReceivedSats': walletReceivedSats,
      'totalInputSats': totalInputSats,
      'sendingAddresses': sendingAddresses,
      if (ancestors.isNotEmpty) 'ancestors': [for (final a in ancestors) a.toMap()],
      if (counterpartyMarker != null) 'counterpartyMarker': counterpartyMarker,
    };
  }

  static TransactionImportedEvent fromMap(Map<String, dynamic> map) {
    return TransactionImportedEvent(
      walletId: map['walletId'] as String,
      txid: map['txid'] as String,
      rawHex: map['rawHex'] as String,
      // Null on a transaction nothing proves (bead libspiffy-nys0).
      blockHeight: map['blockHeight'] as int?,
      bumpProof: map['bumpProof'] as String,
      totalOutputSats: map['totalOutputSats'] as int,
      numInputs: map['numInputs'] as int,
      numOutputs: map['numOutputs'] as int,
      txVersion: map['txVersion'] as int,
      txLockTime: map['txLockTime'] as int,
      walletReceivingAddresses: (map['walletReceivingAddresses'] as List<dynamic>).cast<String>(),
      walletReceivedSats: map['walletReceivedSats'] as int,
      totalInputSats: map['totalInputSats'] as int,
      sendingAddresses: (map['sendingAddresses'] as List<dynamic>).cast<String>(),
      ancestors: [
        for (final a in (map['ancestors'] as List<dynamic>? ?? const []))
          BeefAncestor.fromMap(a as Map<dynamic, dynamic>),
      ],
      // Absent on rows journaled before cq16: they replay with no marker.
      counterpartyMarker: map['counterpartyMarker'] as String?,
      eventId: map['eventId'] as String?,
      timestamp: map['timestamp'] != null
          ? (map['timestamp'] is String
              ? DateTime.parse(map['timestamp'] as String)
              : map['timestamp'] as DateTime)
          : null,
      version: map['version'] as int?,
      metadata: map['metadata'] as Map<String, dynamic>?,
    );
  }
}

// =============================================================================
// ADDRESS MANAGEMENT EVENTS
// =============================================================================

/// Event fired when a new address is generated
class AddressGeneratedEvent extends WalletEvent {
  /// Journal identifier of this event type. Stored with every event and
  /// independent of the class name; never change it (audit 2026-09-14 M8).
  static const String stableTypeName = 'wallet.address.generated';

  @override
  String get typeName => stableTypeName;

  final String address;
  final int derivationIndex;
  final String? label;
  final String? purpose;
  final String? publicKeyHex; // Optional: Public key hex (for multisig/channels)

  /// The chain the address was derived on. Defaults from [purpose] (change
  /// for `'change'`, receive otherwise), which is all an event journaled
  /// before the delegated chain existed carries.
  final AddressChain chain;

  AddressGeneratedEvent({
    required String walletId,
    required this.address,
    required this.derivationIndex,
    this.label,
    this.purpose,
    this.publicKeyHex,
    AddressChain? chain,
    String? correlationId,
    String? eventId,
    DateTime? timestamp,
    int? version,
    Map<String, dynamic>? metadata,
  })  : chain = chain ?? AddressChain.fromRecord(isChange: purpose == 'change'),
        super(
          walletId: walletId,
          eventId: eventId,
          timestamp: timestamp,
          version: version,
          metadata: {
            ...?metadata,
            if (correlationId != null) 'correlationId': correlationId,
          },
        );

  /// Get the optional correlation ID from metadata
  String? getCorrelationId() => metadata['correlationId'] as String?;

  @override
  Map<String, dynamic> getWalletEventData() {
    return {
      'address': address,
      'derivationIndex': derivationIndex,
      'label': label,
      'purpose': purpose,
      'publicKeyHex': publicKeyHex,
      'chain': chain.index,
    };
  }

  static AddressGeneratedEvent fromMap(Map<String, dynamic> map) {
    return AddressGeneratedEvent(
      walletId: map['walletId'] as String,
      address: map['address'] as String,
      derivationIndex: map['derivationIndex'] as int,
      label: map['label'] as String?,
      purpose: map['purpose'] as String?,
      publicKeyHex: map['publicKeyHex'] as String?,
      chain: AddressChain.fromRecord(chain: map['chain'], isChange: map['purpose'] == 'change'),
      correlationId: map['correlationId'] as String? ?? map['metadata']?['correlationId'] as String?,
      eventId: map['eventId'] as String?,
      timestamp: map['timestamp'] != null
          ? (map['timestamp'] is String 
              ? DateTime.parse(map['timestamp'] as String)
              : map['timestamp'] as DateTime)
          : null,
      version: map['version'] as int?,
      metadata: map['metadata'] as Map<String, dynamic>?,
    );
  }
}


/// Event fired when an address label is updated
class AddressLabelUpdatedEvent extends WalletEvent {
  /// Journal identifier of this event type. Stored with every event and
  /// independent of the class name; never change it (audit 2026-09-14 M8).
  static const String stableTypeName = 'wallet.address.label_updated';

  @override
  String get typeName => stableTypeName;

  final String address;
  final String? newLabel;
  final String? oldLabel;

  AddressLabelUpdatedEvent({
    required String walletId,
    required this.address,
    this.newLabel,
    this.oldLabel,
    String? eventId,
    DateTime? timestamp,
    int? version,
    Map<String, dynamic>? metadata,
  }) : super(
          walletId: walletId,
          eventId: eventId,
          timestamp: timestamp,
          version: version,
          metadata: metadata,
        );

  @override
  Map<String, dynamic> getWalletEventData() {
    return {
      'address': address,
      'newLabel': newLabel,
      'oldLabel': oldLabel,
    };
  }

  static AddressLabelUpdatedEvent fromMap(Map<String, dynamic> map) {
    return AddressLabelUpdatedEvent(
      walletId: map['walletId'] as String,
      address: map['address'] as String,
      newLabel: map['newLabel'] as String?,
      oldLabel: map['oldLabel'] as String?,
      eventId: map['eventId'] as String?,
      timestamp: map['timestamp'] != null
          ? (map['timestamp'] is String 
              ? DateTime.parse(map['timestamp'] as String)
              : map['timestamp'] as DateTime)
          : null,
      version: map['version'] as int?,
      metadata: map['metadata'] as Map<String, dynamic>?,
    );
  }
}

/// A watch address was added to the wallet (bead libspiffy-p4kv).
///
/// A watch address is an address the wallet holds no key for whose payments
/// it attributes to itself (RegisterWatchAddressCommand on the coordinator).
/// Journaled so that the wallet aggregate knows it (it answers ownership
/// for it) and a read model rebuilt from the journal has its row.
///
/// [reconciled] is true for an address registered before watch addresses
/// were journaled: the wallet manager found it in the read model when it
/// loaded the wallet, and [registeredAt] is that row's creation time.
class WatchAddressAddedEvent extends WalletEvent {
  /// Journal identifier of this event type. Stored with every event and
  /// independent of the class name; never change it (audit 2026-09-14 M8).
  static const String stableTypeName = 'wallet.watch_address.added';

  @override
  String get typeName => stableTypeName;

  final String address;
  final String scriptType;
  final String? label;
  final DateTime registeredAt;
  final bool reconciled;

  WatchAddressAddedEvent({
    required String walletId,
    required this.address,
    required this.scriptType,
    this.label,
    required this.registeredAt,
    this.reconciled = false,
    String? eventId,
    DateTime? timestamp,
    int? version,
    Map<String, dynamic>? metadata,
  }) : super(
          walletId: walletId,
          eventId: eventId,
          timestamp: timestamp,
          version: version,
          metadata: metadata,
        );

  @override
  Map<String, dynamic> getWalletEventData() => {
        'address': address,
        'scriptType': scriptType,
        'label': label,
        'registeredAt': registeredAt.toIso8601String(),
        'reconciled': reconciled,
      };

  static DateTime _date(Object? value) => value is DateTime ? value : DateTime.parse(value as String);

  static WatchAddressAddedEvent fromMap(Map<String, dynamic> map) => WatchAddressAddedEvent(
        walletId: map['walletId'] as String,
        address: map['address'] as String,
        scriptType: map['scriptType'] as String,
        label: map['label'] as String?,
        registeredAt: _date(map['registeredAt']),
        reconciled: map['reconciled'] as bool? ?? false,
        eventId: map['eventId'] as String?,
        timestamp: map['timestamp'] != null ? _date(map['timestamp']) : null,
        version: map['version'] as int?,
        metadata: map['metadata'] as Map<String, dynamic>?,
      );
}

/// A payer's type-42 address was recorded (bead libspiffy-zxkd): [address]
/// is the anchor key's type-42 child for [derivation], which the wallet
/// derived itself from its anchor private key. The wallet signs for it with
/// that child key, derived again for each signature; the key itself is
/// never journaled.
class Type42AddressRecordedEvent extends WalletEvent {
  /// Journal identifier of this event type. Stored with every event and
  /// independent of the class name; never change it (audit 2026-09-14 M8).
  static const String stableTypeName = 'wallet.type42_address.recorded';

  @override
  String get typeName => stableTypeName;

  final String address;
  final Type42Derivation derivation;

  Type42AddressRecordedEvent({
    required String walletId,
    required this.address,
    required this.derivation,
    String? eventId,
    DateTime? timestamp,
    int? version,
    Map<String, dynamic>? metadata,
  }) : super(walletId: walletId, eventId: eventId, timestamp: timestamp, version: version, metadata: metadata);

  @override
  Map<String, dynamic> getWalletEventData() => {'address': address, ...derivation.toMap()};

  static Type42AddressRecordedEvent fromMap(Map<String, dynamic> map) => Type42AddressRecordedEvent(
        walletId: map['walletId'] as String,
        address: map['address'] as String,
        derivation: Type42Derivation.fromMap(map)!,
        eventId: map['eventId'] as String?,
        timestamp: map['timestamp'] == null
            ? null
            : map['timestamp'] is DateTime
                ? map['timestamp'] as DateTime
                : DateTime.parse(map['timestamp'] as String),
        version: map['version'] as int?,
        metadata: map['metadata'] as Map<String, dynamic>?,
      );
}

/// The wallet issued its anchor key for a context (bead libspiffy-fdal):
/// [anchorPublicKey] is the key at `m/3'/0'/k1'/k2'` for [anchorContext]
/// (hex). Journaled once per context, so a hand-off that names only the
/// anchor is matched to the context that derives its key. Nothing here is
/// a private key.
class AnchorKeyIssuedEvent extends WalletEvent {
  /// Journal identifier of this event type. Stored with every event and
  /// independent of the class name; never change it (audit 2026-09-14 M8).
  static const String stableTypeName = 'wallet.anchor_key.issued';

  @override
  String get typeName => stableTypeName;

  final String anchorPublicKey;
  final String anchorContext;

  AnchorKeyIssuedEvent({
    required String walletId,
    required this.anchorPublicKey,
    required this.anchorContext,
    String? eventId,
    DateTime? timestamp,
    int? version,
    Map<String, dynamic>? metadata,
  }) : super(walletId: walletId, eventId: eventId, timestamp: timestamp, version: version, metadata: metadata);

  @override
  Map<String, dynamic> getWalletEventData() => {'anchorPublicKey': anchorPublicKey, 'anchorContext': anchorContext};

  static AnchorKeyIssuedEvent fromMap(Map<String, dynamic> map) => AnchorKeyIssuedEvent(
        walletId: map['walletId'] as String,
        anchorPublicKey: map['anchorPublicKey'] as String,
        anchorContext: map['anchorContext'] as String,
        eventId: map['eventId'] as String?,
        timestamp: map['timestamp'] == null
            ? null
            : map['timestamp'] is DateTime
                ? map['timestamp'] as DateTime
                : DateTime.parse(map['timestamp'] as String),
        version: map['version'] as int?,
        metadata: map['metadata'] as Map<String, dynamic>?,
      );
}

/// The wallet derived a type-42 destination as a payer (bead
/// libspiffy-zxkd): it used payer key [Type42Destination.payerKeyIndex],
/// which it never uses again, and [destination] is the hand-off the
/// recipient takes the payment in with. Nothing here is a private key.
class Type42DestinationDerivedEvent extends WalletEvent {
  /// Journal identifier of this event type. Stored with every event and
  /// independent of the class name; never change it (audit 2026-09-14 M8).
  static const String stableTypeName = 'wallet.type42_destination.derived';

  @override
  String get typeName => stableTypeName;

  final Type42Destination destination;

  Type42DestinationDerivedEvent({
    required String walletId,
    required this.destination,
    String? eventId,
    DateTime? timestamp,
    int? version,
    Map<String, dynamic>? metadata,
  }) : super(walletId: walletId, eventId: eventId, timestamp: timestamp, version: version, metadata: metadata);

  @override
  Map<String, dynamic> getWalletEventData() => destination.toMap();

  static Type42DestinationDerivedEvent fromMap(Map<String, dynamic> map) => Type42DestinationDerivedEvent(
        walletId: map['walletId'] as String,
        destination: Type42Destination.fromMap(map)!,
        eventId: map['eventId'] as String?,
        timestamp: map['timestamp'] == null
            ? null
            : map['timestamp'] is DateTime
                ? map['timestamp'] as DateTime
                : DateTime.parse(map['timestamp'] as String),
        version: map['version'] as int?,
        metadata: map['metadata'] as Map<String, dynamic>?,
      );
}

// =============================================================================
// UTXO MANAGEMENT EVENTS
// =============================================================================

/// Event fired when a UTXO is received
class UTXOReceivedEvent extends WalletEvent {
  /// Journal identifier of this event type. Stored with every event and
  /// independent of the class name; never change it (audit 2026-09-14 M8).
  static const String stableTypeName = 'wallet.utxo.received';

  @override
  String get typeName => stableTypeName;

  final String txid;
  final int vout;
  final int satoshis;
  final String scriptPubKey;
  final String address;
  final int? blockHeight;
  final int? confirmations;
  final UTXOStatus initialStatus; // Initial status when creating the UTXO
  final int? derivationIndex;
  final Map<String, dynamic>? pluginMetadata;

  /// The app's opaque marker for the counterparty this payment was with
  /// (bead libspiffy-cq16, spv-understanding.md "Core Data Management"
  /// requirement 5): an Ed25519 identity key, an email address, a peer id,
  /// an internal account id. libspiffy stores it and never interprets it.
  /// It is not an address and not the address-derived counterparty columns
  /// of the read model. Null when the app supplied none, and on rows
  /// journaled before the field existed, which replay unchanged: the key is
  /// written only when there is a marker, so an event without one
  /// serializes exactly as before.
  final String? counterpartyMarker;

  UTXOReceivedEvent({
    required String walletId,
    required this.txid,
    required this.vout,
    required this.satoshis,
    required this.scriptPubKey,
    required this.address,
    this.blockHeight,
    this.confirmations,
    this.initialStatus = UTXOStatus.pending, // Default to pending
    this.derivationIndex,
    Map<String, dynamic>? pluginMetadata,
    this.counterpartyMarker,
    String? eventId,
    DateTime? timestamp,
    int? version,
    Map<String, dynamic>? metadata,
  })  : pluginMetadata = frozenPlainMapOrNull(pluginMetadata),
        super(
          walletId: walletId,
          eventId: eventId,
          timestamp: timestamp,
          version: version,
          metadata: metadata,
        );

  @override
  Map<String, dynamic> getWalletEventData() {
    return {
      'txid': txid,
      'vout': vout,
      'satoshis': satoshis,
      'scriptPubKey': scriptPubKey,
      'address': address,
      'blockHeight': blockHeight,
      'confirmations': confirmations,
      'initialStatus': initialStatus.name,
      'derivationIndex': derivationIndex,
      'pluginMetadata': pluginMetadata,
      if (counterpartyMarker != null) 'counterpartyMarker': counterpartyMarker,
    };
  }

  static UTXOReceivedEvent fromMap(Map<String, dynamic> map) {
    // Parse initialStatus, defaulting to pending for backwards compatibility
    UTXOStatus initialStatus = UTXOStatus.pending;
    if (map.containsKey('initialStatus')) {
      final statusName = map['initialStatus'] as String;
      initialStatus = UTXOStatus.values.firstWhere(
        (s) => s.name == statusName,
        orElse: () => UTXOStatus.pending,
      );
    }
    
    return UTXOReceivedEvent(
      walletId: map['walletId'] as String,
      txid: map['txid'] as String,
      vout: map['vout'] as int,
      satoshis: map['satoshis'] as int,
      scriptPubKey: map['scriptPubKey'] as String,
      address: map['address'] as String,
      blockHeight: map['blockHeight'] as int?,
      confirmations: map['confirmations'] as int?,
      initialStatus: initialStatus,
      derivationIndex: map['derivationIndex'] as int?,
      pluginMetadata: map['pluginMetadata'] as Map<String, dynamic>?,
      // Absent on rows journaled before cq16: they replay with no marker.
      counterpartyMarker: map['counterpartyMarker'] as String?,
      eventId: map['eventId'] as String?,
      timestamp: map['timestamp'] != null
          ? (map['timestamp'] is String 
              ? DateTime.parse(map['timestamp'] as String)
              : map['timestamp'] as DateTime)
          : null,
      version: map['version'] as int?,
      metadata: map['metadata'] as Map<String, dynamic>?,
    );
  }
}

/// Event fired when UTXO becomes available for spending
class UTXOMarkedAvailableEvent extends WalletEvent {
  /// Journal identifier of this event type. Stored with every event and
  /// independent of the class name; never change it (audit 2026-09-14 M8).
  static const String stableTypeName = 'wallet.utxo.marked_available';

  @override
  String get typeName => stableTypeName;

  final String txid;
  final int vout;
  
  UTXOMarkedAvailableEvent({
    required String walletId,
    required this.txid,
    required this.vout,
    String? eventId,
    DateTime? timestamp,
    int? version,
    Map<String, dynamic>? metadata,
  }) : super(
          walletId: walletId,
          eventId: eventId,
          timestamp: timestamp,
          version: version,
          metadata: metadata,
        );
  
  @override
  Map<String, dynamic> getWalletEventData() {
    return {
      'txid': txid,
      'vout': vout,
    };
  }
  
  static UTXOMarkedAvailableEvent fromMap(Map<String, dynamic> map) {
    return UTXOMarkedAvailableEvent(
      walletId: map['walletId'] as String,
      txid: map['txid'] as String,
      vout: map['vout'] as int,
      eventId: map['eventId'] as String?,
      timestamp: map['timestamp'] != null
          ? (map['timestamp'] is String 
              ? DateTime.parse(map['timestamp'] as String)
              : map['timestamp'] as DateTime)
          : null,
      version: map['version'] as int?,
      metadata: map['metadata'] as Map<String, dynamic>?,
    );
  }
}

/// Event fired when a UTXO is spent
class UTXOSpentEvent extends WalletEvent {
  /// Journal identifier of this event type. Stored with every event and
  /// independent of the class name; never change it (audit 2026-09-14 M8).
  static const String stableTypeName = 'wallet.utxo.spent';

  @override
  String get typeName => stableTypeName;

  final String txid;
  final int vout;
  final String spentInTxId;

  UTXOSpentEvent({
    required String walletId,
    required this.txid,
    required this.vout,
    required this.spentInTxId,
    String? eventId,
    DateTime? timestamp,
    int? version,
    Map<String, dynamic>? metadata,
  }) : super(
          walletId: walletId,
          eventId: eventId,
          timestamp: timestamp,
          version: version,
          metadata: metadata,
        );

  @override
  Map<String, dynamic> getWalletEventData() {
    return {
      'txid': txid,
      'vout': vout,
      'spentInTxId': spentInTxId,
    };
  }

  static UTXOSpentEvent fromMap(Map<String, dynamic> map) {
    return UTXOSpentEvent(
      walletId: map['walletId'] as String,
      txid: map['txid'] as String,
      vout: map['vout'] as int,
      spentInTxId: map['spentInTxId'] as String,
      eventId: map['eventId'] as String?,
      timestamp: map['timestamp'] != null
          ? (map['timestamp'] is String 
              ? DateTime.parse(map['timestamp'] as String)
              : map['timestamp'] as DateTime)
          : null,
      version: map['version'] as int?,
      metadata: map['metadata'] as Map<String, dynamic>?,
    );
  }
}

/// Event fired when a confirmation count reported for a UTXO is recorded.
///
/// It records a **claim**, never evidence (bead libspiffy-8oaq): applying it
/// writes the count onto the row and deliberately leaves the status alone,
/// so it cannot make anything spendable. Availability comes from
/// [UTXOMarkedAvailableEvent] or from [TransactionConfirmedEvent], whose
/// height is derived from a merkle proof checked against our own headers.
///
/// The height it carries reaches no row either (bead libspiffy-pq8p).
/// `blockHeight != null` is what "confirmed" means at every layer
/// (`WalletBalances.bucketOf`, `BitcoinUtxo.isConfirmed`), so recording an
/// unverified height let a claim report as confirmed balance. The event
/// keeps carrying it because the journal records what we were told; the
/// apply is where it is given no authority.
class UTXOConfirmationUpdatedEvent extends WalletEvent {
  /// Journal identifier of this event type. Stored with every event and
  /// independent of the class name; never change it (audit 2026-09-14 M8).
  static const String stableTypeName = 'wallet.utxo.confirmation_updated';

  @override
  String get typeName => stableTypeName;

  final String txid;
  final int vout;
  final int confirmations;

  /// The height the count was reported at, or null when none was given.
  /// Null is "no height", not height 0: journaling an absent height as 0 said
  /// the output was mined in the genesis block (bead libspiffy-8oaq).
  final int? blockHeight;

  UTXOConfirmationUpdatedEvent({
    required String walletId,
    required this.txid,
    required this.vout,
    required this.confirmations,
    this.blockHeight,
    String? eventId,
    DateTime? timestamp,
    int? version,
    Map<String, dynamic>? metadata,
  }) : super(
          walletId: walletId,
          eventId: eventId,
          timestamp: timestamp,
          version: version,
          metadata: metadata,
        );

  @override
  Map<String, dynamic> getWalletEventData() {
    return {
      'txid': txid,
      'vout': vout,
      'confirmations': confirmations,
      'blockHeight': blockHeight,
    };
  }

  static UTXOConfirmationUpdatedEvent fromMap(Map<String, dynamic> map) {
    return UTXOConfirmationUpdatedEvent(
      walletId: map['walletId'] as String,
      txid: map['txid'] as String,
      vout: map['vout'] as int,
      confirmations: map['confirmations'] as int,
      blockHeight: map['blockHeight'] as int?,
      eventId: map['eventId'] as String?,
      timestamp: map['timestamp'] != null
          ? (map['timestamp'] is String 
              ? DateTime.parse(map['timestamp'] as String)
              : map['timestamp'] as DateTime)
          : null,
      version: map['version'] as int?,
      metadata: map['metadata'] as Map<String, dynamic>?,
    );
  }
}

/// Event fired when a UTXO is reserved for a transaction
class UTXOReservedEvent extends WalletEvent {
  /// Journal identifier of this event type. Stored with every event and
  /// independent of the class name; never change it (audit 2026-09-14 M8).
  static const String stableTypeName = 'wallet.utxo.reserved';

  @override
  String get typeName => stableTypeName;

  final String txid;
  final int vout;
  final String reservedByTxId;
  final String? reservationReason;
  final DateTime expiresAt;
  final int priority;

  UTXOReservedEvent({
    required String walletId,
    required this.txid,
    required this.vout,
    required this.reservedByTxId,
    this.reservationReason,
    required this.expiresAt,
    this.priority = 0,
    String? eventId,
    DateTime? timestamp,
    int? version,
    Map<String, dynamic>? metadata,
  }) : super(
          walletId: walletId,
          eventId: eventId,
          timestamp: timestamp,
          version: version,
          metadata: metadata,
        );

  @override
  Map<String, dynamic> getWalletEventData() {
    return {
      'txid': txid,
      'vout': vout,
      'reservedByTxId': reservedByTxId,
      'reservationReason': reservationReason,
      'expiresAt': expiresAt.toIso8601String(),
      'priority': priority,
    };
  }

  static UTXOReservedEvent fromMap(Map<String, dynamic> map) {
    // Handle expiresAt - may be String (from JSON) or DateTime (from CBOR/Isar)
    final expiresAtValue = map['expiresAt'];
    final DateTime expiresAt;
    if (expiresAtValue is String) {
      expiresAt = DateTime.parse(expiresAtValue);
    } else if (expiresAtValue is DateTime) {
      expiresAt = expiresAtValue;
    } else {
      throw ArgumentError('expiresAt must be String or DateTime, got ${expiresAtValue.runtimeType}');
    }
    
    return UTXOReservedEvent(
      walletId: map['walletId'] as String,
      txid: map['txid'] as String,
      vout: map['vout'] as int,
      reservedByTxId: map['reservedByTxId'] as String,
      reservationReason: map['reservationReason'] as String?,
      expiresAt: expiresAt,
      priority: map['priority'] as int? ?? 0,
      eventId: map['eventId'] as String?,
      timestamp: map['timestamp'] != null
          ? (map['timestamp'] is String 
              ? DateTime.parse(map['timestamp'] as String)
              : map['timestamp'] as DateTime)
          : null,
      version: map['version'] as int?,
      metadata: map['metadata'] as Map<String, dynamic>?,
    );
  }
}

/// Event fired when a UTXO reservation is released
class UTXOReleasedEvent extends WalletEvent {
  /// Journal identifier of this event type. Stored with every event and
  /// independent of the class name; never change it (audit 2026-09-14 M8).
  static const String stableTypeName = 'wallet.utxo.released';

  @override
  String get typeName => stableTypeName;

  final String txid;
  final int vout;
  final String? releaseReason;
  final bool wasExpired;

  /// Status the UTXO returns to: the status it had before it was reserved
  /// (audit 2026-09-14 M4). Null on events journaled before this field
  /// existed, which released to [UTXOStatus.available].
  final UTXOStatus? restoredStatus;

  UTXOReleasedEvent({
    required String walletId,
    required this.txid,
    required this.vout,
    this.releaseReason,
    this.wasExpired = false,
    this.restoredStatus,
    String? eventId,
    DateTime? timestamp,
    int? version,
    Map<String, dynamic>? metadata,
  }) : super(
          walletId: walletId,
          eventId: eventId,
          timestamp: timestamp,
          version: version,
          metadata: metadata,
        );

  @override
  Map<String, dynamic> getWalletEventData() {
    return {
      'txid': txid,
      'vout': vout,
      'releaseReason': releaseReason,
      'wasExpired': wasExpired,
      if (restoredStatus != null) 'restoredStatus': restoredStatus!.name,
    };
  }

  static UTXOReleasedEvent fromMap(Map<String, dynamic> map) {
    return UTXOReleasedEvent(
      walletId: map['walletId'] as String,
      txid: map['txid'] as String,
      vout: map['vout'] as int,
      releaseReason: map['releaseReason'] as String?,
      wasExpired: map['wasExpired'] as bool? ?? false,
      restoredStatus: UTXOStatus.values
          .where((s) => s.name == map['restoredStatus'])
          .firstOrNull,
      eventId: map['eventId'] as String?,
      timestamp: map['timestamp'] != null
          ? (map['timestamp'] is String 
              ? DateTime.parse(map['timestamp'] as String)
              : map['timestamp'] as DateTime)
          : null,
      version: map['version'] as int?,
      metadata: map['metadata'] as Map<String, dynamic>?,
    );
  }
}

/// Event fired when a UTXO reservation is renewed/extended
class UTXOReservationRenewedEvent extends WalletEvent {
  /// Journal identifier of this event type. Stored with every event and
  /// independent of the class name; never change it (audit 2026-09-14 M8).
  static const String stableTypeName = 'wallet.utxo.reservation_renewed';

  @override
  String get typeName => stableTypeName;

  final String txid;
  final int vout;
  final DateTime newExpiresAt;
  final DateTime oldExpiresAt;
  final String? renewalReason;

  UTXOReservationRenewedEvent({
    required String walletId,
    required this.txid,
    required this.vout,
    required this.newExpiresAt,
    required this.oldExpiresAt,
    this.renewalReason,
    String? eventId,
    DateTime? timestamp,
    int? version,
    Map<String, dynamic>? metadata,
  }) : super(
          walletId: walletId,
          eventId: eventId,
          timestamp: timestamp,
          version: version,
          metadata: metadata,
        );

  @override
  Map<String, dynamic> getWalletEventData() {
    return {
      'txid': txid,
      'vout': vout,
      'newExpiresAt': newExpiresAt.toIso8601String(),
      'oldExpiresAt': oldExpiresAt.toIso8601String(),
      'renewalReason': renewalReason,
    };
  }

  static UTXOReservationRenewedEvent fromMap(Map<String, dynamic> map) {
    // Helper to parse DateTime that may be String (from JSON) or DateTime (from CBOR/Isar)
    DateTime parseDateTime(dynamic value, String fieldName) {
      if (value is String) return DateTime.parse(value);
      if (value is DateTime) return value;
      throw ArgumentError('$fieldName must be String or DateTime, got ${value.runtimeType}');
    }
    
    return UTXOReservationRenewedEvent(
      walletId: map['walletId'] as String,
      txid: map['txid'] as String,
      vout: map['vout'] as int,
      newExpiresAt: parseDateTime(map['newExpiresAt'], 'newExpiresAt'),
      oldExpiresAt: parseDateTime(map['oldExpiresAt'], 'oldExpiresAt'),
      renewalReason: map['renewalReason'] as String?,
      eventId: map['eventId'] as String?,
      timestamp: map['timestamp'] != null
          ? (map['timestamp'] is String 
              ? DateTime.parse(map['timestamp'] as String)
              : map['timestamp'] as DateTime)
          : null,
      version: map['version'] as int?,
      metadata: map['metadata'] as Map<String, dynamic>?,
    );
  }
}

// =============================================================================
// TRANSACTION EVENTS
// =============================================================================

/// Event fired when a transaction is created
/// Event fired when a transaction is signed
class TransactionSignedEvent extends WalletEvent {
  /// Journal identifier of this event type. Stored with every event and
  /// independent of the class name; never change it (audit 2026-09-14 M8).
  static const String stableTypeName = 'wallet.transaction.signed';

  @override
  String get typeName => stableTypeName;

  final String txid;
  final String signedRawHex;

  TransactionSignedEvent({
    required String walletId,
    required this.txid,
    required this.signedRawHex,
    String? eventId,
    DateTime? timestamp,
    int? version,
    Map<String, dynamic>? metadata,
  }) : super(
          walletId: walletId,
          eventId: eventId,
          timestamp: timestamp,
          version: version,
          metadata: metadata,
        );

  @override
  Map<String, dynamic> getWalletEventData() {
    return {
      'txid': txid,
      'signedRawHex': signedRawHex,
    };
  }

  static TransactionSignedEvent fromMap(Map<String, dynamic> map) {
    return TransactionSignedEvent(
      walletId: map['walletId'] as String,
      txid: map['txid'] as String,
      signedRawHex: map['signedRawHex'] as String,
      eventId: map['eventId'] as String?,
      timestamp: map['timestamp'] != null
          ? (map['timestamp'] is String 
              ? DateTime.parse(map['timestamp'] as String)
              : map['timestamp'] as DateTime)
          : null,
      version: map['version'] as int?,
      metadata: map['metadata'] as Map<String, dynamic>?,
    );
  }
}

/// Event fired when a transaction is broadcast
class TransactionBroadcastEvent extends WalletEvent {
  /// Journal identifier of this event type. Stored with every event and
  /// independent of the class name; never change it (audit 2026-09-14 M8).
  static const String stableTypeName = 'wallet.transaction.broadcast';

  @override
  String get typeName => stableTypeName;

  final String txid;

  /// What the broadcaster was told, as ARC's wire status name
  /// (`SEEN_ON_NETWORK`, `REJECTED`, ...), or null when the broadcast was
  /// recorded without an answer to go with it.
  ///
  /// Nullable since bead libspiffy-f0sj: this used to be a non-null String
  /// that the aggregate filled with the constant `'broadcast_success'`,
  /// because [BroadcastTransactionCommand] had no field to carry ARC's real
  /// answer. Events written before that change replay unaltered and still
  /// read `'broadcast_success'`; they are not evidence of anything ARC said.
  final String? broadcastResponse;

  TransactionBroadcastEvent({
    required String walletId,
    required this.txid,
    this.broadcastResponse,
    String? eventId,
    DateTime? timestamp,
    int? version,
    Map<String, dynamic>? metadata,
  }) : super(
          walletId: walletId,
          eventId: eventId,
          timestamp: timestamp,
          version: version,
          metadata: metadata,
        );

  @override
  Map<String, dynamic> getWalletEventData() {
    return {
      'txid': txid,
      // Absent, not a placeholder, when no answer was recorded.
      if (broadcastResponse != null) 'broadcastResponse': broadcastResponse,
    };
  }

  static TransactionBroadcastEvent fromMap(Map<String, dynamic> map) {
    return TransactionBroadcastEvent(
      walletId: map['walletId'] as String,
      txid: map['txid'] as String,
      // Old journals carry the constant 'broadcast_success' here; newer ones
      // carry ARC's wire status, or nothing at all.
      broadcastResponse: map['broadcastResponse'] as String?,
      eventId: map['eventId'] as String?,
      timestamp: map['timestamp'] != null
          ? (map['timestamp'] is String 
              ? DateTime.parse(map['timestamp'] as String)
              : map['timestamp'] as DateTime)
          : null,
      version: map['version'] as int?,
      metadata: map['metadata'] as Map<String, dynamic>?,
    );
  }
}

/// Event fired when an outgoing transaction is recorded (in pending state)
class TransactionRecordedEvent extends WalletEvent {
  /// Journal identifier of this event type. Stored with every event and
  /// independent of the class name; never change it (audit 2026-09-14 M8).
  static const String stableTypeName = 'wallet.transaction.recorded';

  @override
  String get typeName => stableTypeName;

  final String txid;
  final String rawHex;
  final int totalInputSats;
  final int totalOutputSats;
  final int fee;
  final int numInputs;
  final int numOutputs;
  final int txVersion;
  final int txLockTime;
  final List<String> spentUtxoKeys;
  final List<String> recipientAddresses;
  final String paymentAmount; // Store as string to avoid BigInt serialization issues
  final String? changeAddress;
  final String? changeAmount;

  /// The app's opaque marker for the counterparty this payment was with
  /// (bead libspiffy-cq16, spv-understanding.md "Core Data Management"
  /// requirement 5): an Ed25519 identity key, an email address, a peer id,
  /// an internal account id. libspiffy stores it and never interprets it.
  /// It is not an address and not the address-derived counterparty columns
  /// of the read model. Null when the app supplied none, and on rows
  /// journaled before the field existed, which replay unchanged: the key is
  /// written only when there is a marker, so an event without one
  /// serializes exactly as before.
  final String? counterpartyMarker;

  TransactionRecordedEvent({
    required String walletId,
    required this.txid,
    required this.rawHex,
    required this.totalInputSats,
    required this.totalOutputSats,
    required this.fee,
    required this.numInputs,
    required this.numOutputs,
    required this.txVersion,
    required this.txLockTime,
    required List<String> spentUtxoKeys,
    required List<String> recipientAddresses,
    required this.paymentAmount,
    this.changeAddress,
    this.changeAmount,
    this.counterpartyMarker,
    String? eventId,
    DateTime? timestamp,
    int? version,
    Map<String, dynamic>? metadata,
  })  : spentUtxoKeys = frozenList(spentUtxoKeys),
        recipientAddresses = frozenList(recipientAddresses),
        super(
          walletId: walletId,
          eventId: eventId,
          timestamp: timestamp,
          version: version,
          metadata: metadata,
        );

  @override
  Map<String, dynamic> getWalletEventData() {
    return {
      'txid': txid,
      'rawHex': rawHex,
      'totalInputSats': totalInputSats,
      'totalOutputSats': totalOutputSats,
      'fee': fee,
      'numInputs': numInputs,
      'numOutputs': numOutputs,
      'txVersion': txVersion,
      'txLockTime': txLockTime,
      'spentUtxoKeys': spentUtxoKeys,
      'recipientAddresses': recipientAddresses,
      'paymentAmount': paymentAmount,
      'changeAddress': changeAddress,
      'changeAmount': changeAmount,
      if (counterpartyMarker != null) 'counterpartyMarker': counterpartyMarker,
    };
  }

  static TransactionRecordedEvent fromMap(Map<String, dynamic> map) {
    return TransactionRecordedEvent(
      walletId: map['walletId'] as String,
      txid: map['txid'] as String,
      rawHex: map['rawHex'] as String,
      totalInputSats: map['totalInputSats'] as int,
      totalOutputSats: map['totalOutputSats'] as int,
      fee: map['fee'] as int,
      numInputs: map['numInputs'] as int,
      numOutputs: map['numOutputs'] as int,
      txVersion: map['txVersion'] as int,
      txLockTime: map['txLockTime'] as int,
      spentUtxoKeys: List<String>.from(map['spentUtxoKeys'] as List),
      recipientAddresses: List<String>.from(map['recipientAddresses'] as List),
      paymentAmount: map['paymentAmount'] as String,
      changeAddress: map['changeAddress'] as String?,
      changeAmount: map['changeAmount'] as String?,
      // Absent on rows journaled before cq16: they replay with no marker.
      counterpartyMarker: map['counterpartyMarker'] as String?,
      eventId: map['eventId'] as String?,
      timestamp: map['timestamp'] != null
          ? (map['timestamp'] is String 
              ? DateTime.parse(map['timestamp'] as String)
              : map['timestamp'] as DateTime)
          : null,
      version: map['version'] as int?,
      metadata: map['metadata'] as Map<String, dynamic>?,
    );
  }
}

/// Event fired when a pending transaction is confirmed
class TransactionConfirmedEvent extends WalletEvent {
  /// Journal identifier of this event type. Stored with every event and
  /// independent of the class name; never change it (audit 2026-09-14 M8).
  static const String stableTypeName = 'wallet.transaction.confirmed';

  @override
  String get typeName => stableTypeName;

  final String txid;
  final int? blockHeight;
  final String? blockHash;

  /// The hex-encoded BRC-74 BUMP that proved the confirmation (ARC's
  /// `merklePath`, checked against the local header before the command was
  /// sent). WalletProjection stores the merkle proof from it, so the journal,
  /// not the read model alone, holds the proof (bead libspiffy-9ek). Null in
  /// rows journaled before it existed; those replay without a proof.
  final String? bumpHex;

  TransactionConfirmedEvent({
    required String walletId,
    required this.txid,
    this.blockHeight,
    this.blockHash,
    this.bumpHex,
    String? eventId,
    DateTime? timestamp,
    int? version,
    Map<String, dynamic>? metadata,
  }) : super(
          walletId: walletId,
          eventId: eventId,
          timestamp: timestamp,
          version: version,
          metadata: metadata,
        );

  @override
  Map<String, dynamic> getWalletEventData() {
    return {
      'txid': txid,
      'blockHeight': blockHeight,
      'blockHash': blockHash,
      if (bumpHex != null) 'bumpHex': bumpHex,
    };
  }

  static TransactionConfirmedEvent fromMap(Map<String, dynamic> map) {
    return TransactionConfirmedEvent(
      walletId: map['walletId'] as String,
      txid: map['txid'] as String,
      blockHeight: map['blockHeight'] as int?,
      blockHash: map['blockHash'] as String?,
      bumpHex: map['bumpHex'] as String?,
      eventId: map['eventId'] as String?,
      timestamp: map['timestamp'] != null
          ? (map['timestamp'] is String 
              ? DateTime.parse(map['timestamp'] as String)
              : map['timestamp'] as DateTime)
          : null,
      version: map['version'] as int?,
      metadata: map['metadata'] as Map<String, dynamic>?,
    );
  }
}

/// Event fired when a transaction's status is updated (e.g., from ARC status transitions)
class TransactionStatusUpdatedEvent extends WalletEvent {
  /// Journal identifier of this event type. Stored with every event and
  /// independent of the class name; never change it (audit 2026-09-14 M8).
  static const String stableTypeName = 'wallet.transaction.status_updated';

  @override
  String get typeName => stableTypeName;

  final String txid;
  final TransactionStatus newStatus;

  TransactionStatusUpdatedEvent({
    required String walletId,
    required this.txid,
    required this.newStatus,
    String? eventId,
    DateTime? timestamp,
    int? version,
    Map<String, dynamic>? metadata,
  }) : super(
          walletId: walletId,
          eventId: eventId,
          timestamp: timestamp,
          version: version,
          metadata: metadata,
        );

  @override
  Map<String, dynamic> getWalletEventData() {
    return {
      'txid': txid,
      'newStatus': newStatus.name,
    };
  }

  static TransactionStatusUpdatedEvent fromMap(Map<String, dynamic> map) {
    return TransactionStatusUpdatedEvent(
      walletId: map['walletId'] as String,
      txid: map['txid'] as String,
      newStatus: TransactionStatus.values.firstWhere(
        (s) => s.name == map['newStatus'],
        orElse: () => TransactionStatus.pending,
      ),
      eventId: map['eventId'] as String?,
      timestamp: map['timestamp'] != null
          ? (map['timestamp'] is String
              ? DateTime.parse(map['timestamp'] as String)
              : map['timestamp'] as DateTime)
          : null,
      version: map['version'] as int?,
      metadata: map['metadata'] as Map<String, dynamic>?,
    );
  }
}

// =============================================================================
// UTXO RESERVATION EVENTS
// =============================================================================

/// Event fired when UTXOs are reserved for transaction creation.
///
/// **Nothing in `lib/` emits this event** (reachability sweep 2026-09-18,
/// section 2). Reservations are journaled as [UTXOReservedEvent] instead:
/// `UtxoReservations.reserveMany` used to emit this event, which nothing
/// applied, and was changed to emit [UTXOReservedEvent] per UTXO by audit
/// 2026-09-14 M3.
///
/// That history is exactly why the class stays — journals written before M3
/// really do contain these events.
///
/// **DO NOT DELETE THIS CLASS.** It is deprecated, not dead. It is registered
/// for replay in `LibSpiffyActorSystem` under the stable type name
/// `wallet.utxo_reservation.placed`, and a journal written by an earlier
/// release may already contain events with that name. A journal is permanent
/// and its contents are never rewritten, so deleting the class (or its
/// [fromMap], or its registration) would make such a journal unreplayable —
/// which the data-retention rule in `spv-understanding.md` forbids outright.
/// The deprecation marks it as "do not emit anything new"; it says nothing
/// about removability.
@Deprecated(
    'Nothing emits this event; do not journal new ones. The class MUST be '
    'kept: it is registered for replay as wallet.utxo_reservation.placed and '
    'a journal written by an earlier release may contain it, so deleting the '
    'class would make that journal unreplayable. Not scheduled for removal.')
class UTXOReservationPlacedEvent extends WalletEvent {
  /// Journal identifier of this event type. Stored with every event and
  /// independent of the class name; never change it (audit 2026-09-14 M8).
  static const String stableTypeName = 'wallet.utxo_reservation.placed';

  @override
  String get typeName => stableTypeName;

  final List<Map<String, dynamic>> utxoIdentifiers; // {txid, vout}
  final String reservationId;
  final DateTime expiresAt;

  UTXOReservationPlacedEvent({
    required String walletId,
    required List<Map<String, dynamic>> utxoIdentifiers,
    required this.reservationId,
    required this.expiresAt,
    String? eventId,
    DateTime? timestamp,
    int? version,
    Map<String, dynamic>? metadata,
  })  : utxoIdentifiers = frozenMapList(utxoIdentifiers),
        super(
          walletId: walletId,
          eventId: eventId,
          timestamp: timestamp,
          version: version,
          metadata: metadata,
        );

  @override
  Map<String, dynamic> getWalletEventData() {
    return {
      'utxoIdentifiers': utxoIdentifiers,
      'reservationId': reservationId,
      'expiresAt': expiresAt.toIso8601String(),
    };
  }

  static UTXOReservationPlacedEvent fromMap(Map<String, dynamic> map) {
    return UTXOReservationPlacedEvent(
      walletId: map['walletId'] as String,
      utxoIdentifiers: List<Map<String, dynamic>>.from(map['utxoIdentifiers']),
      reservationId: map['reservationId'] as String,
      expiresAt: map['expiresAt'] is String 
          ? DateTime.parse(map['expiresAt'] as String)
          : map['expiresAt'] as DateTime,
      eventId: map['eventId'] as String?,
      timestamp: map['timestamp'] != null
          ? (map['timestamp'] is String 
              ? DateTime.parse(map['timestamp'] as String)
              : map['timestamp'] as DateTime)
          : null,
      version: map['version'] as int?,
      metadata: map['metadata'] as Map<String, dynamic>?,
    );
  }
}

/// Event fired when UTXO reservation is released.
///
/// **Nothing in `lib/` emits this event** (reachability sweep 2026-09-18,
/// section 2). Releases are journaled as [UTXOReleasedEvent], one per UTXO:
/// `UtxoReservations.releaseMany` used to emit this event, which released
/// nothing, and was changed by audit 2026-09-14 M3.
///
/// **DO NOT DELETE THIS CLASS.** It is deprecated, not dead. It is registered
/// for replay in `LibSpiffyActorSystem` under the stable type name
/// `wallet.utxo_reservation.released`, and journals written before M3 do
/// contain events with that name. A journal is permanent and its contents are
/// never rewritten, so deleting the class (or its [fromMap], or its
/// registration) would make such a journal unreplayable — which the
/// data-retention rule in `spv-understanding.md` forbids outright. The
/// deprecation marks it as "do not emit anything new"; it says nothing about
/// removability.
@Deprecated(
    'Nothing emits this event; do not journal new ones. The class MUST be '
    'kept: it is registered for replay as wallet.utxo_reservation.released '
    'and a journal written by an earlier release may contain it, so deleting '
    'the class would make that journal unreplayable. Not scheduled for '
    'removal.')
class UTXOReservationReleasedEvent extends WalletEvent {
  /// Journal identifier of this event type. Stored with every event and
  /// independent of the class name; never change it (audit 2026-09-14 M8).
  static const String stableTypeName = 'wallet.utxo_reservation.released';

  @override
  String get typeName => stableTypeName;

  final String reservationId;
  final List<Map<String, dynamic>> utxoIdentifiers; // {txid, vout}

  UTXOReservationReleasedEvent({
    required String walletId,
    required this.reservationId,
    required List<Map<String, dynamic>> utxoIdentifiers,
    String? eventId,
    DateTime? timestamp,
    int? version,
    Map<String, dynamic>? metadata,
  })  : utxoIdentifiers = frozenMapList(utxoIdentifiers),
        super(
          walletId: walletId,
          eventId: eventId,
          timestamp: timestamp,
          version: version,
          metadata: metadata,
        );

  @override
  Map<String, dynamic> getWalletEventData() {
    return {
      'reservationId': reservationId,
      'utxoIdentifiers': utxoIdentifiers,
    };
  }

  static UTXOReservationReleasedEvent fromMap(Map<String, dynamic> map) {
    return UTXOReservationReleasedEvent(
      walletId: map['walletId'] as String,
      reservationId: map['reservationId'] as String,
      utxoIdentifiers: List<Map<String, dynamic>>.from(map['utxoIdentifiers']),
      eventId: map['eventId'] as String?,
      timestamp: map['timestamp'] != null
          ? (map['timestamp'] is String 
              ? DateTime.parse(map['timestamp'] as String)
              : map['timestamp'] as DateTime)
          : null,
      version: map['version'] as int?,
      metadata: map['metadata'] as Map<String, dynamic>?,
    );
  }
}

/// Event fired when UTXO reservation expires.
///
/// **Nothing in `lib/` emits this event** (reachability sweep 2026-09-18,
/// section 2). Expiry is journaled as [UTXOReleasedEvent] with
/// `wasExpired: true`.
///
/// **DO NOT DELETE THIS CLASS.** It is deprecated, not dead. It is registered
/// for replay in `LibSpiffyActorSystem` under the stable type name
/// `wallet.utxo_reservation.expired`, and a journal written by an earlier
/// release may already contain events with that name. A journal is permanent
/// and its contents are never rewritten, so deleting the class (or its
/// [fromMap], or its registration) would make such a journal unreplayable —
/// which the data-retention rule in `spv-understanding.md` forbids outright.
/// The deprecation marks it as "do not emit anything new"; it says nothing
/// about removability.
@Deprecated(
    'Nothing emits this event; do not journal new ones. The class MUST be '
    'kept: it is registered for replay as wallet.utxo_reservation.expired and '
    'a journal written by an earlier release may contain it, so deleting the '
    'class would make that journal unreplayable. Not scheduled for removal.')
class UTXOReservationExpiredEvent extends WalletEvent {
  /// Journal identifier of this event type. Stored with every event and
  /// independent of the class name; never change it (audit 2026-09-14 M8).
  static const String stableTypeName = 'wallet.utxo_reservation.expired';

  @override
  String get typeName => stableTypeName;

  final String reservationId;
  final List<Map<String, dynamic>> utxoIdentifiers; // {txid, vout}

  UTXOReservationExpiredEvent({
    required String walletId,
    required this.reservationId,
    required List<Map<String, dynamic>> utxoIdentifiers,
    String? eventId,
    DateTime? timestamp,
    int? version,
    Map<String, dynamic>? metadata,
  })  : utxoIdentifiers = frozenMapList(utxoIdentifiers),
        super(
          walletId: walletId,
          eventId: eventId,
          timestamp: timestamp,
          version: version,
          metadata: metadata,
        );

  @override
  Map<String, dynamic> getWalletEventData() {
    return {
      'reservationId': reservationId,
      'utxoIdentifiers': utxoIdentifiers,
    };
  }

  static UTXOReservationExpiredEvent fromMap(Map<String, dynamic> map) {
    return UTXOReservationExpiredEvent(
      walletId: map['walletId'] as String,
      reservationId: map['reservationId'] as String,
      utxoIdentifiers: List<Map<String, dynamic>>.from(map['utxoIdentifiers']),
      eventId: map['eventId'] as String?,
      timestamp: map['timestamp'] != null
          ? (map['timestamp'] is String 
              ? DateTime.parse(map['timestamp'] as String)
              : map['timestamp'] as DateTime)
          : null,
      version: map['version'] as int?,
      metadata: map['metadata'] as Map<String, dynamic>?,
    );
  }
} 

// =============================================================================
// PRIVACY EVENTS - Benford UTXO Splitting
// =============================================================================

/// A split the wallet aggregate was asked for, in a journal written by an
/// earlier release.
///
/// Nothing emits it any more (bead libspiffy-lph4). The split command never
/// reached the aggregate — `WalletManagerActor` hands it to
/// `BenfordCoordinatorActor`, which builds, records and broadcasts the split
/// through commands of its own — so the aggregate's handler, which emitted
/// this event, was reachable only by calling the aggregate directly. Its
/// [feeRate] is the satoshis-per-byte rate that command carried; every fee
/// is now ARC's published policy rate.
@Deprecated(
    'Nothing emits this event; do not journal new ones. The class MUST be '
    'kept: it is registered for replay as wallet.utxo_split.initiated and '
    'a journal written by an earlier release may contain it, so deleting the '
    'class would make that journal unreplayable. Not scheduled for removal.')
class UTXOSplitInitiatedEvent extends WalletEvent {
  /// Journal identifier of this event type. Stored with every event and
  /// independent of the class name; never change it (audit 2026-09-14 M8).
  static const String stableTypeName = 'wallet.utxo_split.initiated';

  @override
  String get typeName => stableTypeName;

  final List<String> utxoKeysToSplit;
  final int targetUtxoCount;
  final BigInt feeRate;

  UTXOSplitInitiatedEvent({
    required String walletId,
    required List<String> utxoKeysToSplit,
    required this.targetUtxoCount,
    required this.feeRate,
    String? eventId,
    DateTime? timestamp,
    int? version,
    Map<String, dynamic>? metadata,
  })  : utxoKeysToSplit = frozenList(utxoKeysToSplit),
        super(
          walletId: walletId,
          eventId: eventId,
          timestamp: timestamp,
          version: version,
          metadata: metadata,
        );

  @override
  Map<String, dynamic> getWalletEventData() {
    return {
      'utxoKeysToSplit': utxoKeysToSplit,
      'targetUtxoCount': targetUtxoCount,
      'feeRate': feeRate.toString(),
    };
  }

  static UTXOSplitInitiatedEvent fromMap(Map<String, dynamic> map) {
    return UTXOSplitInitiatedEvent(
      walletId: map['walletId'] as String,
      utxoKeysToSplit: List<String>.from(map['utxoKeysToSplit']),
      targetUtxoCount: map['targetUtxoCount'] as int,
      feeRate: BigInt.parse(map['feeRate'] as String),
      eventId: map['eventId'] as String?,
      timestamp: map['timestamp'] != null
          ? (map['timestamp'] is String
              ? DateTime.parse(map['timestamp'] as String)
              : map['timestamp'] as DateTime)
          : null,
      version: map['version'] as int?,
      metadata: map['metadata'] as Map<String, dynamic>?,
    );
  }
}

/// Event fired when a single UTXO has been successfully split.
///
/// Informational only: the actual state changes happen via CQRS commands
/// (SpendUTXO, ReceiveUTXO, RecordTransaction).
///
/// **Nothing in `lib/` emits this event any more** (reachability sweep
/// 2026-09-18, section 2). `BenfordCoordinatorActor` journals the split's
/// effects through those commands; [UTXOSplitInitiatedEvent] is replay-only
/// too since bead libspiffy-lph4.
///
/// **DO NOT DELETE THIS CLASS.** It is deprecated, not dead. It is registered
/// for replay in `LibSpiffyActorSystem` under the stable type name
/// `wallet.utxo_split.completed`, and a journal written by an earlier release
/// may already contain events with that name. A journal is permanent and its
/// contents are never rewritten, so deleting the class (or its [fromMap], or
/// its registration) would make such a journal unreplayable — which the
/// data-retention rule in `spv-understanding.md` forbids outright. The
/// deprecation marks it as "do not emit anything new"; it says nothing about
/// removability.
@Deprecated(
    'Nothing emits this event; do not journal new ones. The class MUST be '
    'kept: it is registered for replay as wallet.utxo_split.completed and a '
    'journal written by an earlier release may contain it, so deleting the '
    'class would make that journal unreplayable. Not scheduled for removal.')
class UTXOSplitCompletedEvent extends WalletEvent {
  /// Journal identifier of this event type. Stored with every event and
  /// independent of the class name; never change it (audit 2026-09-14 M8).
  static const String stableTypeName = 'wallet.utxo_split.completed';

  @override
  String get typeName => stableTypeName;

  final String originalUtxoKey;
  final String originalAmount;
  final String splitTxid;
  final int outputsCreated;
  final String feePaid;

  UTXOSplitCompletedEvent({
    required String walletId,
    required this.originalUtxoKey,
    required this.originalAmount,
    required this.splitTxid,
    required this.outputsCreated,
    required this.feePaid,
    String? eventId,
    DateTime? timestamp,
    int? version,
    Map<String, dynamic>? metadata,
  }) : super(
          walletId: walletId,
          eventId: eventId,
          timestamp: timestamp,
          version: version,
          metadata: metadata,
        );

  @override
  Map<String, dynamic> getWalletEventData() {
    return {
      'originalUtxoKey': originalUtxoKey,
      'originalAmount': originalAmount,
      'splitTxid': splitTxid,
      'outputsCreated': outputsCreated,
      'feePaid': feePaid,
    };
  }

  static UTXOSplitCompletedEvent fromMap(Map<String, dynamic> map) {
    return UTXOSplitCompletedEvent(
      walletId: map['walletId'] as String,
      originalUtxoKey: map['originalUtxoKey'] as String,
      originalAmount: map['originalAmount'] as String,
      splitTxid: map['splitTxid'] as String,
      outputsCreated: map['outputsCreated'] as int,
      feePaid: map['feePaid'] as String,
      eventId: map['eventId'] as String?,
      timestamp: map['timestamp'] != null
          ? (map['timestamp'] is String
              ? DateTime.parse(map['timestamp'] as String)
              : map['timestamp'] as DateTime)
          : null,
      version: map['version'] as int?,
      metadata: map['metadata'] as Map<String, dynamic>?,
    );
  }
}

/// Event fired when all UTXOs have been processed.
///
/// **Nothing in `lib/` emits this event** (reachability sweep 2026-09-18,
/// section 2). `BenfordCoordinatorActor` journals a split run's effects
/// through CQRS commands instead.
///
/// **DO NOT DELETE THIS CLASS.** It is deprecated, not dead. It is registered
/// for replay in `LibSpiffyActorSystem` under the stable type name
/// `wallet.utxo_split.all_completed`, and a journal written by an earlier
/// release may already contain events with that name. A journal is permanent
/// and its contents are never rewritten, so deleting the class (or its
/// [fromMap], or its registration) would make such a journal unreplayable —
/// which the data-retention rule in `spv-understanding.md` forbids outright.
/// The deprecation marks it as "do not emit anything new"; it says nothing
/// about removability.
@Deprecated(
    'Nothing emits this event; do not journal new ones. The class MUST be '
    'kept: it is registered for replay as wallet.utxo_split.all_completed and '
    'a journal written by an earlier release may contain it, so deleting the '
    'class would make that journal unreplayable. Not scheduled for removal.')
class AllUTXOsSplitCompletedEvent extends WalletEvent {
  /// Journal identifier of this event type. Stored with every event and
  /// independent of the class name; never change it (audit 2026-09-14 M8).
  static const String stableTypeName = 'wallet.utxo_split.all_completed';

  @override
  String get typeName => stableTypeName;

  final int totalUtxosSplit;
  final int totalOutputsCreated;
  final String totalFeesPaid; // Store as string
  final List<String> transactionIds;

  AllUTXOsSplitCompletedEvent({
    required String walletId,
    required this.totalUtxosSplit,
    required this.totalOutputsCreated,
    required this.totalFeesPaid,
    required List<String> transactionIds,
    String? eventId,
    DateTime? timestamp,
    int? version,
    Map<String, dynamic>? metadata,
  })  : transactionIds = frozenList(transactionIds),
        super(
          walletId: walletId,
          eventId: eventId,
          timestamp: timestamp,
          version: version,
          metadata: metadata,
        );

  @override
  Map<String, dynamic> getWalletEventData() {
    return {
      'totalUtxosSplit': totalUtxosSplit,
      'totalOutputsCreated': totalOutputsCreated,
      'totalFeesPaid': totalFeesPaid,
      'transactionIds': transactionIds,
    };
  }

  static AllUTXOsSplitCompletedEvent fromMap(Map<String, dynamic> map) {
    return AllUTXOsSplitCompletedEvent(
      walletId: map['walletId'] as String,
      totalUtxosSplit: map['totalUtxosSplit'] as int,
      totalOutputsCreated: map['totalOutputsCreated'] as int,
      totalFeesPaid: map['totalFeesPaid'] as String,
      transactionIds: List<String>.from(map['transactionIds']),
      eventId: map['eventId'] as String?,
      timestamp: map['timestamp'] != null
          ? (map['timestamp'] is String
              ? DateTime.parse(map['timestamp'] as String)
              : map['timestamp'] as DateTime)
          : null,
      version: map['version'] as int?,
      metadata: map['metadata'] as Map<String, dynamic>?,
    );
  }
} 

// =============================================================================
// WALLET IMPORT NOTIFICATIONS (in-process only, never journaled)
// =============================================================================

/// Progress of a wallet import, broadcast in-process by the ImportActor.
///
/// These are notifications, not events: they are not persisted, not
/// registered with the event registry, and never applied by the wallet
/// aggregate. What an import durably changes is journaled by the ordinary
/// wallet events it causes (WalletCreatedEvent, AddressGeneratedEvent,
/// UTXOReceivedEvent, TransactionRecordedEvent, ...). Subscribe with
/// `LibSpiffyActorSystem.subscribeToImportNotifications` (audit 2026-09-14
/// L4). The `...Event` class names are kept so existing subscribers'
/// type tests still compile.
sealed class WalletImportNotification {
  /// Wallet being imported.
  final String walletId;

  /// When the notification was raised.
  final DateTime timestamp;

  /// Free-form details (for example `{'cancelled': true}` on a failure).
  final Map<String, dynamic> metadata;

  WalletImportNotification({
    required this.walletId,
    DateTime? timestamp,
    Map<String, dynamic>? metadata,
  })  : timestamp = timestamp ?? DateTime.now(),
        metadata = frozenPlainMap(metadata ?? const {});

  @override
  String toString() => '$runtimeType(walletId: $walletId, timestamp: $timestamp)';
}

/// An import job has created (or confirmed) the wallet and is starting.
class WalletImportStartedEvent extends WalletImportNotification {
  final String walletName;
  final int addressGapLimit;

  WalletImportStartedEvent({
    required super.walletId,
    required this.walletName,
    required this.addressGapLimit,
    super.timestamp,
    super.metadata,
  });
}

/// Periodic progress of a running import.
class WalletImportProgressEvent extends WalletImportNotification {
  final String phase;
  final String message;
  final double progress;
  final int addressesFound;
  final int totalAddresses;
  final int transactionsProcessed;
  final int totalTransactions;

  WalletImportProgressEvent({
    required super.walletId,
    required this.phase,
    required this.message,
    required this.progress,
    required this.addressesFound,
    required this.totalAddresses,
    required this.transactionsProcessed,
    required this.totalTransactions,
    super.timestamp,
    super.metadata,
  });
}

/// The import finished.
class WalletImportCompletedEvent extends WalletImportNotification {
  final int totalAddresses;
  final int totalTransactions;
  final List<Map<String, dynamic>> importedUtxos;

  WalletImportCompletedEvent({
    required super.walletId,
    required this.totalAddresses,
    required this.totalTransactions,
    required List<Map<String, dynamic>> importedUtxos,
    super.timestamp,
    super.metadata,
  }) : importedUtxos = frozenMapList(importedUtxos);
}

/// The import failed or was cancelled (`metadata['cancelled'] == true`).
class WalletImportFailedEvent extends WalletImportNotification {
  final String error;
  final String? partialProgress;

  WalletImportFailedEvent({
    required super.walletId,
    required this.error,
    this.partialProgress,
    super.timestamp,
    super.metadata,
  });
}

/// The wallet aggregate acknowledged (or rejected) an imported UTXO.
class WalletImportUTXOConfirmedEvent extends WalletImportNotification {
  final String txid;
  final int vout;
  final bool success;
  final String? error;

  WalletImportUTXOConfirmedEvent({
    required super.walletId,
    required this.txid,
    required this.vout,
    required this.success,
    this.error,
    super.timestamp,
    super.metadata,
  });
}

/// The wallet aggregate acknowledged (or rejected) an imported transaction.
class WalletImportTransactionConfirmedEvent extends WalletImportNotification {
  final String txid;
  final bool success;
  final String? error;

  WalletImportTransactionConfirmedEvent({
    required super.walletId,
    required this.txid,
    required this.success,
    this.error,
    super.timestamp,
    super.metadata,
  });
}

/// Event fired when a transaction's confirmation is taken back (audit 3b0):
/// its block left the active chain, or its proof does not match the block
/// header at the proof's height.
///
/// Applying it returns the transaction to pending, sets the confirmations
/// of its UTXOs to zero (spendable ones become pending) and, in the read
/// model, deletes the stored proof if it is still [merkleProof].
class TransactionConfirmationRevertedEvent extends WalletEvent {
  static const String stableTypeName = 'wallet.transaction.confirmation_reverted';

  @override
  String get typeName => stableTypeName;

  final String txid;
  final int? blockHeight;
  final String? blockHash;
  final List<String>? merkleProof;
  final String reason;

  TransactionConfirmationRevertedEvent({
    required String walletId,
    required this.txid,
    required this.reason,
    this.blockHeight,
    this.blockHash,
    List<String>? merkleProof,
    String? eventId,
    DateTime? timestamp,
    int? version,
    Map<String, dynamic>? metadata,
  })  : merkleProof = frozenListOrNull(merkleProof),
        super(
          walletId: walletId,
          eventId: eventId,
          timestamp: timestamp,
          version: version,
          metadata: metadata,
        );

  @override
  Map<String, dynamic> getWalletEventData() {
    return {
      'txid': txid,
      'blockHeight': blockHeight,
      'blockHash': blockHash,
      'merkleProof': merkleProof,
      'reason': reason,
    };
  }

  static TransactionConfirmationRevertedEvent fromMap(Map<String, dynamic> map) {
    return TransactionConfirmationRevertedEvent(
      walletId: map['walletId'] as String,
      txid: map['txid'] as String,
      blockHeight: map['blockHeight'] as int?,
      blockHash: map['blockHash'] as String?,
      merkleProof: map['merkleProof'] == null ? null : List<String>.from(map['merkleProof'] as List),
      reason: map['reason'] as String? ?? '',
      eventId: map['eventId'] as String?,
      timestamp: map['timestamp'] != null
          ? (map['timestamp'] is String
              ? DateTime.parse(map['timestamp'] as String)
              : map['timestamp'] as DateTime)
          : null,
      version: map['version'] as int?,
      metadata: map['metadata'] as Map<String, dynamic>?,
    );
  }
}

// =============================================================================
// DEFERRED PAYMENTS (bead libspiffy-7p2)
// =============================================================================

DateTime? _deferredDate(Object? value) => value == null
    ? null
    : value is DateTime
        ? value
        : DateTime.parse(value.toString());

/// A UTXO a deferred payment's failure or cancellation released, and the
/// status it returned to.
class ReleasedDeferredInput {
  final String utxoKey;
  final UTXOStatus restoredStatus;

  const ReleasedDeferredInput({required this.utxoKey, required this.restoredStatus});

  Map<String, dynamic> toMap() => {'utxoKey': utxoKey, 'restoredStatus': restoredStatus.name};

  factory ReleasedDeferredInput.fromMap(Map<dynamic, dynamic> map) => ReleasedDeferredInput(
        utxoKey: map['utxoKey'].toString(),
        restoredStatus: UTXOStatus.values.firstWhere(
          (s) => s.name == map['restoredStatus'],
          orElse: () => UTXOStatus.available,
        ),
      );

  static List<ReleasedDeferredInput> listFrom(Object? value) => value is List
      ? [for (final e in value) if (e is Map) ReleasedDeferredInput.fromMap(e)]
      : const [];
}

/// A recorded outgoing transaction's spend is deferred: the wallet holds its
/// inputs until the network settles it (bead libspiffy-7p2).
///
/// Each held input becomes reserved by [txid] with no expiry, so reservation
/// expiry, `CleanupExpiredReservationsCommand` and higher-priority
/// reservations cannot release or take it. The hold ends when the network
/// reports the transaction (the inputs are spent), when ARC reports it
/// definitively failed ([DeferredTransactionFailedEvent]) or when the user
/// cancels it ([DeferredTransactionCancelledEvent]).
///
/// Journaled with the `TransactionRecordedEvent` of a `deferSpend` recording,
/// or later with [inferred] true for a record journaled before holds existed,
/// or with [reactivated] true when a cancelled deferred payment is recorded
/// again (bead libspiffy-4r0).
class TransactionSpendDeferredEvent extends WalletEvent {
  static const String stableTypeName = 'wallet.transaction.spend_deferred';

  @override
  String get typeName => stableTypeName;

  final String txid;

  /// The inputs held (`{'utxoKey': 'txid:vout', 'satoshis': '1000'}`): the
  /// wallet's unspent UTXOs the transaction spends that no other deferred
  /// payment already holds.
  final List<Map<String, dynamic>> heldInputs;

  final List<String> recipientAddresses;
  final String paymentAmount;
  final int fee;
  final String? invoiceId;
  final String? purpose;

  /// True when inferred from an older journal (see class doc).
  final bool inferred;

  /// True when the same transaction, a cancelled deferred payment, was
  /// recorded again with a deferred spend: the payment is outstanding again
  /// and holds [heldInputs]. The cancellation stays in the journal before
  /// it (bead libspiffy-4r0).
  final bool reactivated;

  /// When the transaction was recorded (the record's time for an inferred
  /// hold; otherwise the event time).
  final DateTime recordedAt;

  /// The deferred payment whose hold on these inputs this one takes over:
  /// the payment being reclaimed by this self-spend (bead libspiffy-87a).
  /// Null for every other hold, and for every hold journaled before
  /// reclaims existed, so the rule "the first hold wins" is unchanged
  /// everywhere else.
  final String? supersedes;

  TransactionSpendDeferredEvent({
    required String walletId,
    required this.txid,
    required List<Map<String, dynamic>> heldInputs,
    List<String> recipientAddresses = const [],
    this.paymentAmount = '0',
    this.fee = 0,
    this.invoiceId,
    this.purpose,
    this.inferred = false,
    this.reactivated = false,
    this.supersedes,
    DateTime? recordedAt,
    String? eventId,
    DateTime? timestamp,
    int? version,
    Map<String, dynamic>? metadata,
  })  : heldInputs = frozenMapList(heldInputs),
        recipientAddresses = frozenList(recipientAddresses),
        recordedAt = recordedAt ?? timestamp ?? DateTime.now(),
        super(
          walletId: walletId,
          eventId: eventId,
          timestamp: timestamp,
          version: version,
          metadata: metadata,
        );

  /// `txid:vout` of every held input.
  List<String> get heldUtxoKeys => [for (final i in heldInputs) i['utxoKey'].toString()];

  @override
  Map<String, dynamic> getWalletEventData() => {
        'txid': txid,
        'heldInputs': heldInputs,
        'recipientAddresses': recipientAddresses,
        'paymentAmount': paymentAmount,
        'fee': fee,
        'invoiceId': invoiceId,
        'purpose': purpose,
        'inferred': inferred,
        if (reactivated) 'reactivated': true,
        if (supersedes != null) 'supersedes': supersedes,
        'recordedAt': recordedAt.toIso8601String(),
      };

  static TransactionSpendDeferredEvent fromMap(Map<String, dynamic> map) => TransactionSpendDeferredEvent(
        walletId: map['walletId'] as String,
        txid: map['txid'] as String,
        heldInputs: [
          for (final e in (map['heldInputs'] as List? ?? const []))
            if (e is Map) {for (final entry in e.entries) entry.key.toString(): entry.value},
        ],
        recipientAddresses: List<String>.from(map['recipientAddresses'] as List? ?? const []),
        paymentAmount: map['paymentAmount']?.toString() ?? '0',
        fee: (map['fee'] as num?)?.toInt() ?? 0,
        invoiceId: map['invoiceId'] as String?,
        purpose: map['purpose'] as String?,
        inferred: map['inferred'] as bool? ?? false,
        reactivated: map['reactivated'] as bool? ?? false,
        supersedes: map['supersedes'] as String?,
        recordedAt: _deferredDate(map['recordedAt']),
        eventId: map['eventId'] as String?,
        timestamp: _deferredDate(map['timestamp']),
        version: map['version'] as int?,
        metadata: map['metadata'] as Map<String, dynamic>?,
      );
}

/// A network status observed for a deferred payment (ARC or the configured
/// data source). The periodic status scan journals a status only when it
/// differs from the last one; an explicit check or broadcast always does.
///
/// SEEN_ON_NETWORK and MINED move an outstanding (or failed / cancelled)
/// payment to seen. MINED is never a confirmation: that takes a merkle proof
/// checked against the local headers (TransactionConfirmedEvent).
class TransactionNetworkStatusCheckedEvent extends WalletEvent {
  static const String stableTypeName = 'wallet.transaction.network_status_checked';

  @override
  String get typeName => stableTypeName;

  final String txid;
  final String networkStatus;

  /// `arc` or `dataSource`.
  final String source;
  final DateTime checkedAt;
  final int? blockHeight;

  /// True for a user-requested check or broadcast.
  final bool explicit;

  /// The competing transactions ARC named with this status (`competingTxs`,
  /// reported with DOUBLE_SPEND_ATTEMPTED; bead libspiffy-pkum). Written
  /// only when there are any; an event journaled before reads back with none.
  final List<String> competingTxids;

  TransactionNetworkStatusCheckedEvent({
    required String walletId,
    required this.txid,
    required this.networkStatus,
    required this.source,
    required this.checkedAt,
    this.blockHeight,
    this.explicit = false,
    List<String> competingTxids = const [],
    String? eventId,
    DateTime? timestamp,
    int? version,
    Map<String, dynamic>? metadata,
  })  : competingTxids = frozenList(competingTxids),
        super(
          walletId: walletId,
          eventId: eventId,
          timestamp: timestamp,
          version: version,
          metadata: metadata,
        );

  @override
  Map<String, dynamic> getWalletEventData() => {
        'txid': txid,
        'networkStatus': networkStatus,
        'source': source,
        'checkedAt': checkedAt.toIso8601String(),
        'blockHeight': blockHeight,
        'explicit': explicit,
        if (competingTxids.isNotEmpty) 'competingTxids': competingTxids,
      };

  static TransactionNetworkStatusCheckedEvent fromMap(Map<String, dynamic> map) =>
      TransactionNetworkStatusCheckedEvent(
        walletId: map['walletId'] as String,
        txid: map['txid'] as String,
        networkStatus: map['networkStatus'] as String,
        source: map['source'] as String? ?? 'arc',
        checkedAt: _deferredDate(map['checkedAt']) ?? DateTime.fromMillisecondsSinceEpoch(0),
        blockHeight: map['blockHeight'] as int?,
        explicit: map['explicit'] as bool? ?? false,
        competingTxids: [
          if (map['competingTxids'] case final List<dynamic> txids)
            for (final txid in txids) txid.toString(),
        ],
        eventId: map['eventId'] as String?,
        timestamp: _deferredDate(map['timestamp']),
        version: map['version'] as int?,
        metadata: map['metadata'] as Map<String, dynamic>?,
      );
}

/// ARC reported a deferred payment definitively failed (REJECTED; journals
/// written before bead libspiffy-ey2 also hold this event for
/// DOUBLE_SPEND_ATTEMPTED and replay it as written): its held inputs return
/// to the status they had before they were reserved.
class DeferredTransactionFailedEvent extends WalletEvent {
  static const String stableTypeName = 'wallet.transaction.deferred_failed';

  @override
  String get typeName => stableTypeName;

  final String txid;
  final String networkStatus;
  final String? reason;
  final List<ReleasedDeferredInput> releasedInputs;

  DeferredTransactionFailedEvent({
    required String walletId,
    required this.txid,
    required this.networkStatus,
    this.reason,
    List<ReleasedDeferredInput> releasedInputs = const [],
    String? eventId,
    DateTime? timestamp,
    int? version,
    Map<String, dynamic>? metadata,
  })  : releasedInputs = frozenList(releasedInputs),
        super(
          walletId: walletId,
          eventId: eventId,
          timestamp: timestamp,
          version: version,
          metadata: metadata,
        );

  @override
  Map<String, dynamic> getWalletEventData() => {
        'txid': txid,
        'networkStatus': networkStatus,
        'reason': reason,
        'releasedInputs': [for (final r in releasedInputs) r.toMap()],
      };

  static DeferredTransactionFailedEvent fromMap(Map<String, dynamic> map) => DeferredTransactionFailedEvent(
        walletId: map['walletId'] as String,
        txid: map['txid'] as String,
        networkStatus: map['networkStatus'] as String,
        reason: map['reason'] as String?,
        releasedInputs: ReleasedDeferredInput.listFrom(map['releasedInputs']),
        eventId: map['eventId'] as String?,
        timestamp: _deferredDate(map['timestamp']),
        version: map['version'] as int?,
        metadata: map['metadata'] as Map<String, dynamic>?,
      );
}

/// The user cancelled an outstanding deferred payment the network did not
/// know (or the wallet cancelled a payment it never handed over): its held
/// inputs return to the status they had before they were reserved. This does
/// not revoke a signed transaction the recipient holds.
class DeferredTransactionCancelledEvent extends WalletEvent {
  static const String stableTypeName = 'wallet.transaction.deferred_cancelled';

  @override
  String get typeName => stableTypeName;

  final String txid;
  final String? reason;

  /// The status the network check before the cancellation returned (null
  /// when the cancellation did not check, e.g. a payment never handed over).
  final String? networkStatus;
  final List<ReleasedDeferredInput> releasedInputs;

  DeferredTransactionCancelledEvent({
    required String walletId,
    required this.txid,
    this.reason,
    this.networkStatus,
    List<ReleasedDeferredInput> releasedInputs = const [],
    String? eventId,
    DateTime? timestamp,
    int? version,
    Map<String, dynamic>? metadata,
  })  : releasedInputs = frozenList(releasedInputs),
        super(
          walletId: walletId,
          eventId: eventId,
          timestamp: timestamp,
          version: version,
          metadata: metadata,
        );

  @override
  Map<String, dynamic> getWalletEventData() => {
        'txid': txid,
        'reason': reason,
        'networkStatus': networkStatus,
        'releasedInputs': [for (final r in releasedInputs) r.toMap()],
      };

  static DeferredTransactionCancelledEvent fromMap(Map<String, dynamic> map) =>
      DeferredTransactionCancelledEvent(
        walletId: map['walletId'] as String,
        txid: map['txid'] as String,
        reason: map['reason'] as String?,
        networkStatus: map['networkStatus'] as String?,
        releasedInputs: ReleasedDeferredInput.listFrom(map['releasedInputs']),
        eventId: map['eventId'] as String?,
        timestamp: _deferredDate(map['timestamp']),
        version: map['version'] as int?,
        metadata: map['metadata'] as Map<String, dynamic>?,
      );
}

/// A deferred payment is being reclaimed: the wallet recorded its own
/// transaction ([reclaimTxid]) spending that payment's held inputs back to
/// itself, and the hold on those inputs moved to it (bead libspiffy-87a).
///
/// Journaled together with the self-spend's own record and hold, before it
/// is broadcast. It does NOT resolve the payment: the payment becomes
/// [DeferredPaymentState.reclaimed] only once the network has the
/// self-spend (it is seen or mined). Nothing is deleted or overwritten — the
/// reclaimed payment keeps its record, its stored transaction and its raw
/// hex, and its txid stays queryable.
///
/// **This is Bitcoin SV: first seen wins.** The self-spend pays the standard
/// policy fee. Whether it or the recipient's copy is mined is decided by
/// which reached the network first, never by what either pays.
class DeferredSpendReclaimedEvent extends WalletEvent {
  static const String stableTypeName = 'wallet.transaction.deferred_reclaimed';

  @override
  String get typeName => stableTypeName;

  /// The deferred payment being reclaimed.
  final String txid;

  /// The wallet's self-spend of that payment's held inputs.
  final String reclaimTxid;

  /// The inputs whose hold moved from [txid] to [reclaimTxid].
  final List<String> reclaimedUtxoKeys;

  /// Why the payment was reclaimed (recorded as the resolution reason).
  final String? reason;

  DeferredSpendReclaimedEvent({
    required String walletId,
    required this.txid,
    required this.reclaimTxid,
    List<String> reclaimedUtxoKeys = const [],
    this.reason,
    String? eventId,
    DateTime? timestamp,
    int? version,
    Map<String, dynamic>? metadata,
  })  : reclaimedUtxoKeys = frozenList(reclaimedUtxoKeys),
        super(
          walletId: walletId,
          eventId: eventId,
          timestamp: timestamp,
          version: version,
          metadata: metadata,
        );

  @override
  Map<String, dynamic> getWalletEventData() => {
        'txid': txid,
        'reclaimTxid': reclaimTxid,
        'reclaimedUtxoKeys': reclaimedUtxoKeys,
        'reason': reason,
      };

  static DeferredSpendReclaimedEvent fromMap(Map<String, dynamic> map) => DeferredSpendReclaimedEvent(
        walletId: map['walletId'] as String,
        txid: map['txid'] as String,
        reclaimTxid: map['reclaimTxid'] as String,
        reclaimedUtxoKeys: [for (final k in (map['reclaimedUtxoKeys'] as List? ?? const [])) k.toString()],
        reason: map['reason'] as String?,
        eventId: map['eventId'] as String?,
        timestamp: _deferredDate(map['timestamp']),
        version: map['version'] as int?,
        metadata: map['metadata'] as Map<String, dynamic>?,
      );
}
