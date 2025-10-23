import '../models/wallet_event.dart';
import '../models/wallet_type.dart';

// =============================================================================
// WALLET LIFECYCLE EVENTS
// =============================================================================

/// Event fired when a wallet is created
class WalletCreatedEvent extends WalletEvent {
  final String walletName;
  final String rootAddress; // Initial address generated from mnemonic/wif/xpriv
  final WalletType walletType; // Type of wallet (hd, wif, xpriv)
  final Map<String, dynamic>? walletMetadata;

  WalletCreatedEvent({
    required String walletId,
    required this.walletName,
    required this.rootAddress,
    required this.walletType,
    this.walletMetadata,
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
      'walletName': walletName,
      'rootAddress': rootAddress,
      'walletType': walletType.toStorageString(),
      'walletMetadata': walletMetadata,
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
  final String? newName;
  final Map<String, dynamic>? newMetadata;

  WalletConfigurationUpdatedEvent({
    required String walletId,
    this.newName,
    this.newMetadata,
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

/// Event fired when wallet import starts
class WalletImportStartedEvent extends WalletEvent {
  final String xpriv;
  final String walletName;
  final int addressGapLimit;

  WalletImportStartedEvent({
    required String walletId,
    required this.xpriv,
    required this.walletName,
    required this.addressGapLimit,
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
      'xpriv': xpriv,
      'walletName': walletName,
      'addressGapLimit': addressGapLimit,
    };
  }

  static WalletImportStartedEvent fromMap(Map<String, dynamic> map) {
    return WalletImportStartedEvent(
      walletId: map['walletId'] as String,
      xpriv: map['xpriv'] as String,
      walletName: map['walletName'] as String,
      addressGapLimit: map['addressGapLimit'] as int,
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
  final String address;
  final int derivationIndex;
  final bool isChange;
  final int transactionCount;

  AddressDiscoveredEvent({
    required String walletId,
    required this.address,
    required this.derivationIndex,
    required this.isChange,
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
      'isChange': isChange,
      'transactionCount': transactionCount,
    };
  }

  static AddressDiscoveredEvent fromMap(Map<String, dynamic> map) {
    return AddressDiscoveredEvent(
      walletId: map['walletId'] as String,
      address: map['address'] as String,
      derivationIndex: map['derivationIndex'] as int,
      isChange: map['isChange'] as bool,
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

/// Event fired when a transaction is imported
class TransactionImportedEvent extends WalletEvent {
  final String txid;
  final String rawHex;
  final int blockHeight;
  final Map<String, dynamic> bumpProof; // Serialized BUMP format
  
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
    required this.walletReceivingAddresses,
    required this.walletReceivedSats,
    required this.totalInputSats,
    required this.sendingAddresses,
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
    };
  }

  static TransactionImportedEvent fromMap(Map<String, dynamic> map) {
    return TransactionImportedEvent(
      walletId: map['walletId'] as String,
      txid: map['txid'] as String,
      rawHex: map['rawHex'] as String,
      blockHeight: map['blockHeight'] as int,
      bumpProof: map['bumpProof'] as Map<String, dynamic>,
      totalOutputSats: map['totalOutputSats'] as int,
      numInputs: map['numInputs'] as int,
      numOutputs: map['numOutputs'] as int,
      txVersion: map['txVersion'] as int,
      txLockTime: map['txLockTime'] as int,
      walletReceivingAddresses: (map['walletReceivingAddresses'] as List<dynamic>).cast<String>(),
      walletReceivedSats: map['walletReceivedSats'] as int,
      totalInputSats: map['totalInputSats'] as int,
      sendingAddresses: (map['sendingAddresses'] as List<dynamic>).cast<String>(),
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

/// Event fired when wallet import completes
class WalletImportCompletedEvent extends WalletEvent {
  final int totalAddresses;
  final int totalTransactions;
  final List<Map<String, dynamic>> importedUtxos; // Serialized UTXO data

  WalletImportCompletedEvent({
    required String walletId,
    required this.totalAddresses,
    required this.totalTransactions,
    required this.importedUtxos,
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
      'totalAddresses': totalAddresses,
      'totalTransactions': totalTransactions,
      'importedUtxos': importedUtxos,
    };
  }

  static WalletImportCompletedEvent fromMap(Map<String, dynamic> map) {
    return WalletImportCompletedEvent(
      walletId: map['walletId'] as String,
      totalAddresses: map['totalAddresses'] as int,
      totalTransactions: map['totalTransactions'] as int,
      importedUtxos: (map['importedUtxos'] as List)
          .cast<Map<String, dynamic>>(),
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

/// Event fired when wallet import fails
class WalletImportFailedEvent extends WalletEvent {
  final String error;
  final String? partialProgress;

  WalletImportFailedEvent({
    required String walletId,
    required this.error,
    this.partialProgress,
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
      'error': error,
      'partialProgress': partialProgress,
    };
  }

  static WalletImportFailedEvent fromMap(Map<String, dynamic> map) {
    return WalletImportFailedEvent(
      walletId: map['walletId'] as String,
      error: map['error'] as String,
      partialProgress: map['partialProgress'] as String?,
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
  final String address;
  final int derivationIndex;
  final String? label;
  final String? purpose;

  AddressGeneratedEvent({
    required String walletId,
    required this.address,
    required this.derivationIndex,
    this.label,
    this.purpose,
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
      'label': label,
      'purpose': purpose,
    };
  }

  static AddressGeneratedEvent fromMap(Map<String, dynamic> map) {
    return AddressGeneratedEvent(
      walletId: map['walletId'] as String,
      address: map['address'] as String,
      derivationIndex: map['derivationIndex'] as int,
      label: map['label'] as String?,
      purpose: map['purpose'] as String?,
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

// =============================================================================
// UTXO MANAGEMENT EVENTS
// =============================================================================

/// Event fired when a UTXO is received
class UTXOReceivedEvent extends WalletEvent {
  final String txid;
  final int vout;
  final int satoshis;
  final String scriptPubKey;
  final String address;
  final int? blockHeight;
  final int? confirmations;

  UTXOReceivedEvent({
    required String walletId,
    required this.txid,
    required this.vout,
    required this.satoshis,
    required this.scriptPubKey,
    required this.address,
    this.blockHeight,
    this.confirmations,
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
      'satoshis': satoshis,
      'scriptPubKey': scriptPubKey,
      'address': address,
      'blockHeight': blockHeight,
      'confirmations': confirmations,
    };
  }

  static UTXOReceivedEvent fromMap(Map<String, dynamic> map) {
    return UTXOReceivedEvent(
      walletId: map['walletId'] as String,
      txid: map['txid'] as String,
      vout: map['vout'] as int,
      satoshis: map['satoshis'] as int,
      scriptPubKey: map['scriptPubKey'] as String,
      address: map['address'] as String,
      blockHeight: map['blockHeight'] as int?,
      confirmations: map['confirmations'] as int?,
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

/// Event fired when UTXO confirmation count is updated
class UTXOConfirmationUpdatedEvent extends WalletEvent {
  final String txid;
  final int vout;
  final int confirmations;
  final int blockHeight;

  UTXOConfirmationUpdatedEvent({
    required String walletId,
    required this.txid,
    required this.vout,
    required this.confirmations,
    required this.blockHeight,
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
      blockHeight: map['blockHeight'] as int,
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
    return UTXOReservedEvent(
      walletId: map['walletId'] as String,
      txid: map['txid'] as String,
      vout: map['vout'] as int,
      reservedByTxId: map['reservedByTxId'] as String,
      reservationReason: map['reservationReason'] as String?,
      expiresAt: DateTime.parse(map['expiresAt'] as String),
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
  final String txid;
  final int vout;
  final String? releaseReason;
  final bool wasExpired;

  UTXOReleasedEvent({
    required String walletId,
    required this.txid,
    required this.vout,
    this.releaseReason,
    this.wasExpired = false,
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
    };
  }

  static UTXOReleasedEvent fromMap(Map<String, dynamic> map) {
    return UTXOReleasedEvent(
      walletId: map['walletId'] as String,
      txid: map['txid'] as String,
      vout: map['vout'] as int,
      releaseReason: map['releaseReason'] as String?,
      wasExpired: map['wasExpired'] as bool? ?? false,
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
    return UTXOReservationRenewedEvent(
      walletId: map['walletId'] as String,
      txid: map['txid'] as String,
      vout: map['vout'] as int,
      newExpiresAt: DateTime.parse(map['newExpiresAt'] as String),
      oldExpiresAt: DateTime.parse(map['oldExpiresAt'] as String),
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
class TransactionCreatedEvent extends WalletEvent {
  final String txid;
  final String rawHex;
  final int totalInput;
  final int totalOutput;
  final int fee;
  final bool isIncoming;
  final bool isOutgoing;
  final List<String> receivingAddresses;
  final List<String> sendingAddresses;
  final int txVersion;
  final int txLockTime;
  final Map<String, dynamic>? transactionMetadata;

  TransactionCreatedEvent({
    required String walletId,
    required this.txid,
    required this.rawHex,
    required this.totalInput,
    required this.totalOutput,
    required this.fee,
    required this.isIncoming,
    required this.isOutgoing,
    required this.receivingAddresses,
    required this.sendingAddresses,
    required this.txVersion,
    required this.txLockTime,
    this.transactionMetadata,
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
      'rawHex': rawHex,
      'totalInput': totalInput,
      'totalOutput': totalOutput,
      'fee': fee,
      'isIncoming': isIncoming,
      'isOutgoing': isOutgoing,
      'receivingAddresses': receivingAddresses,
      'sendingAddresses': sendingAddresses,
      'txVersion': txVersion,
      'txLockTime': txLockTime,
      'transactionMetadata': transactionMetadata,
    };
  }

  static TransactionCreatedEvent fromMap(Map<String, dynamic> map) {
    return TransactionCreatedEvent(
      walletId: map['walletId'] as String,
      txid: map['txid'] as String,
      rawHex: map['rawHex'] as String,
      totalInput: map['totalInput'] as int,
      totalOutput: map['totalOutput'] as int,
      fee: map['fee'] as int,
      isIncoming: map['isIncoming'] as bool,
      isOutgoing: map['isOutgoing'] as bool,
      receivingAddresses: (map['receivingAddresses'] as List<dynamic>).cast<String>(),
      sendingAddresses: (map['sendingAddresses'] as List<dynamic>).cast<String>(),
      txVersion: map['txVersion'] as int,
      txLockTime: map['txLockTime'] as int,
      transactionMetadata: map['transactionMetadata'] as Map<String, dynamic>?,
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

/// Event fired when a transaction is signed
class TransactionSignedEvent extends WalletEvent {
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
  final String txid;
  final String broadcastResponse;

  TransactionBroadcastEvent({
    required String walletId,
    required this.txid,
    required this.broadcastResponse,
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
      'broadcastResponse': broadcastResponse,
    };
  }

  static TransactionBroadcastEvent fromMap(Map<String, dynamic> map) {
    return TransactionBroadcastEvent(
      walletId: map['walletId'] as String,
      txid: map['txid'] as String,
      broadcastResponse: map['broadcastResponse'] as String,
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

/// Event fired when UTXOs are reserved for transaction creation
class UTXOReservationPlacedEvent extends WalletEvent {
  final List<Map<String, dynamic>> utxoIdentifiers; // {txid, vout}
  final String reservationId;
  final DateTime expiresAt;

  UTXOReservationPlacedEvent({
    required String walletId,
    required this.utxoIdentifiers,
    required this.reservationId,
    required this.expiresAt,
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

/// Event fired when UTXO reservation is released
class UTXOReservationReleasedEvent extends WalletEvent {
  final String reservationId;
  final List<Map<String, dynamic>> utxoIdentifiers; // {txid, vout}

  UTXOReservationReleasedEvent({
    required String walletId,
    required this.reservationId,
    required this.utxoIdentifiers,
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

/// Event fired when UTXO reservation expires
class UTXOReservationExpiredEvent extends WalletEvent {
  final String reservationId;
  final List<Map<String, dynamic>> utxoIdentifiers; // {txid, vout}

  UTXOReservationExpiredEvent({
    required String walletId,
    required this.reservationId,
    required this.utxoIdentifiers,
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