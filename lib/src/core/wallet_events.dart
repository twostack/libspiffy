import 'package:libspiffy/src/models/bitcoin_transaction.dart';
import 'package:libspiffy/src/models/bitcoin_utxo.dart';

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
  final String? hdPublicKeyXpub; // HD public key xpub string (safe public data for post-persistence storage)

  WalletCreatedEvent({
    required String walletId,
    required this.walletName,
    required this.rootAddress,
    required this.walletType,
    this.walletMetadata,
    this.hdPublicKeyXpub,
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
      if (hdPublicKeyXpub != null) 'hdPublicKeyXpub': hdPublicKeyXpub,
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
  final String walletName;
  final int addressGapLimit;

  WalletImportStartedEvent({
    required String walletId,
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
      'walletName': walletName,
      'addressGapLimit': addressGapLimit,
    };
  }

  static WalletImportStartedEvent fromMap(Map<String, dynamic> map) {
    return WalletImportStartedEvent(
      walletId: map['walletId'] as String,
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

/// Event fired during wallet import to report progress
class WalletImportProgressEvent extends WalletEvent {
  final String phase;
  final String message;
  final double progress;
  final int addressesFound;
  final int totalAddresses;
  final int transactionsProcessed;
  final int totalTransactions;

  WalletImportProgressEvent({
    required String walletId,
    required this.phase,
    required this.message,
    required this.progress,
    required this.addressesFound,
    required this.totalAddresses,
    required this.transactionsProcessed,
    required this.totalTransactions,
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
      'phase': phase,
      'message': message,
      'progress': progress,
      'addressesFound': addressesFound,
      'totalAddresses': totalAddresses,
      'transactionsProcessed': transactionsProcessed,
      'totalTransactions': totalTransactions,
    };
  }

  static WalletImportProgressEvent fromMap(Map<String, dynamic> map) {
    return WalletImportProgressEvent(
      walletId: map['walletId'] as String,
      phase: map['phase'] as String,
      message: map['message'] as String,
      progress: (map['progress'] as num).toDouble(),
      addressesFound: map['addressesFound'] as int,
      totalAddresses: map['totalAddresses'] as int,
      transactionsProcessed: map['transactionsProcessed'] as int,
      totalTransactions: map['totalTransactions'] as int,
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
  final String? publicKeyHex; // Optional: Public key hex (for multisig/channels)

  AddressGeneratedEvent({
    required String walletId,
    required this.address,
    required this.derivationIndex,
    this.label,
    this.purpose,
    this.publicKeyHex,
    String? correlationId,
    String? eventId,
    DateTime? timestamp,
    int? version,
    Map<String, dynamic>? metadata,
  }) : super(
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
  final UTXOStatus initialStatus; // Initial status when creating the UTXO
  final int? derivationIndex;
  final Map<String, dynamic>? pluginMetadata;

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
    this.pluginMetadata,
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
      'initialStatus': initialStatus.name,
      'derivationIndex': derivationIndex,
      'pluginMetadata': pluginMetadata,
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

/// Event fired when an outgoing transaction is recorded (in pending state)
class TransactionRecordedEvent extends WalletEvent {
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
    required this.spentUtxoKeys,
    required this.recipientAddresses,
    required this.paymentAmount,
    this.changeAddress,
    this.changeAmount,
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
  final String txid;
  final int? blockHeight;
  final String? blockHash;

  TransactionConfirmedEvent({
    required String walletId,
    required this.txid,
    this.blockHeight,
    this.blockHash,
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
    };
  }

  static TransactionConfirmedEvent fromMap(Map<String, dynamic> map) {
    return TransactionConfirmedEvent(
      walletId: map['walletId'] as String,
      txid: map['txid'] as String,
      blockHeight: map['blockHeight'] as int?,
      blockHash: map['blockHash'] as String?,
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

// =============================================================================
// PRIVACY EVENTS - Benford UTXO Splitting
// =============================================================================

/// Event fired when UTXO split operation is initiated by the aggregate
/// 
/// The aggregate validates the request and emits this event with the list of
/// UTXO keys to split. The BenfordCoordinatorActor listens to this event and
/// performs the actual orchestration (building, signing, broadcasting).
class UTXOSplitInitiatedEvent extends WalletEvent {
  final List<String> utxoKeysToSplit;
  final int targetUtxoCount;
  final BigInt feeRate;

  UTXOSplitInitiatedEvent({
    required String walletId,
    required this.utxoKeysToSplit,
    required this.targetUtxoCount,
    required this.feeRate,
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

/// Event fired when a single UTXO has been successfully split
/// 
/// Emitted by BenfordCoordinatorActor after building, signing, and broadcasting
/// the split transaction. This is informational only - actual state changes
/// happen via CQRS commands (SpendUTXO, ReceiveUTXO, RecordTransaction).
class UTXOSplitCompletedEvent extends WalletEvent {
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

/// Event fired when all UTXOs have been processed
class AllUTXOsSplitCompletedEvent extends WalletEvent {
  final int totalUtxosSplit;
  final int totalOutputsCreated;
  final String totalFeesPaid; // Store as string
  final List<String> transactionIds;

  AllUTXOsSplitCompletedEvent({
    required String walletId,
    required this.totalUtxosSplit,
    required this.totalOutputsCreated,
    required this.totalFeesPaid,
    required this.transactionIds,
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