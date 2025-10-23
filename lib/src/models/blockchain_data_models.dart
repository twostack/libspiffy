/// Data models for blockchain data sources
///
/// These models provide a standard interface between LibSpiffy's core
/// wallet functionality and external blockchain data providers.

/// Information about a single transaction
class TransactionInfo {
  /// Transaction ID (hex string)
  final String txid;

  /// Block height where transaction was confirmed (null if unconfirmed)
  final int? blockHeight;

  /// Block hash where transaction was confirmed (null if unconfirmed)
  final String? blockHash;

  /// Transaction position/index in the block (null if unconfirmed)
  final int? blockIndex;

  /// Unix timestamp of block confirmation (null if unconfirmed)
  final int? timestamp;

  /// Raw transaction hex
  final String? rawHex;

  /// Transaction inputs (optional, for detailed parsing)
  final List<TxInput>? inputs;

  /// Transaction outputs (optional, for detailed parsing)
  final List<TxOutput>? outputs;

  TransactionInfo({
    required this.txid,
    this.blockHeight,
    this.blockHash,
    this.blockIndex,
    this.timestamp,
    this.rawHex,
    this.inputs,
    this.outputs,
  });

  factory TransactionInfo.fromJson(Map<String, dynamic> json) {
    return TransactionInfo(
      txid: json['txid'] as String,
      blockHeight: json['blockHeight'] as int?,
      blockHash: json['blockHash'] as String?,
      blockIndex: json['blockIndex'] as int?,
      timestamp: json['timestamp'] as int?,
      rawHex: json['rawHex'] as String?,
      inputs: (json['inputs'] as List?)
          ?.map((e) => TxInput.fromJson(e as Map<String, dynamic>))
          .toList(),
      outputs: (json['outputs'] as List?)
          ?.map((e) => TxOutput.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'txid': txid,
      if (blockHeight != null) 'blockHeight': blockHeight,
      if (blockHash != null) 'blockHash': blockHash,
      if (blockIndex != null) 'blockIndex': blockIndex,
      if (timestamp != null) 'timestamp': timestamp,
      if (rawHex != null) 'rawHex': rawHex,
      if (inputs != null) 'inputs': inputs!.map((e) => e.toJson()).toList(),
      if (outputs != null)
        'outputs': outputs!.map((e) => e.toJson()).toList(),
    };
  }
}

/// Transaction input
class TxInput {
  final String txid;
  final int vout;
  final String? scriptSig;
  final int? sequence;

  TxInput({
    required this.txid,
    required this.vout,
    this.scriptSig,
    this.sequence,
  });

  factory TxInput.fromJson(Map<String, dynamic> json) {
    return TxInput(
      txid: json['txid'] as String,
      vout: json['vout'] as int,
      scriptSig: json['scriptSig'] as String?,
      sequence: json['sequence'] as int?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'txid': txid,
      'vout': vout,
      if (scriptSig != null) 'scriptSig': scriptSig,
      if (sequence != null) 'sequence': sequence,
    };
  }
}

/// Transaction output
class TxOutput {
  final int vout;
  final int value;
  final String? scriptPubKey;
  final String? address;

  TxOutput({
    required this.vout,
    required this.value,
    this.scriptPubKey,
    this.address,
  });

  factory TxOutput.fromJson(Map<String, dynamic> json) {
    return TxOutput(
      vout: json['vout'] as int,
      value: json['value'] as int,
      scriptPubKey: json['scriptPubKey'] as String?,
      address: json['address'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'vout': vout,
      'value': value,
      if (scriptPubKey != null) 'scriptPubKey': scriptPubKey,
      if (address != null) 'address': address,
    };
  }
}

/// Information about an unspent transaction output (UTXO)
class UtxoInfo {
  /// Transaction ID containing this UTXO
  final String txid;

  /// Output index in the transaction
  final int vout;

  /// Value in satoshis
  final int value;

  /// Block height where UTXO was created
  final int? height;

  /// Script pubkey hex
  final String? scriptPubKey;

  /// Address that owns this UTXO
  final String? address;

  UtxoInfo({
    required this.txid,
    required this.vout,
    required this.value,
    this.height,
    this.scriptPubKey,
    this.address,
  });

  factory UtxoInfo.fromJson(Map<String, dynamic> json) {
    return UtxoInfo(
      txid: json['txid'] as String,
      vout: json['vout'] as int,
      value: json['value'] as int,
      height: json['height'] as int?,
      scriptPubKey: json['scriptPubKey'] as String?,
      address: json['address'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'txid': txid,
      'vout': vout,
      'value': value,
      if (height != null) 'height': height,
      if (scriptPubKey != null) 'scriptPubKey': scriptPubKey,
      if (address != null) 'address': address,
    };
  }
}

/// Merkle proof data in a generic format
///
/// Implementations may provide proofs in different formats (TSC, BUMP, etc.)
/// Converters translate these to LibSpiffy's BUMP format for validation.
class MerkleProofData {
  /// Transaction ID being proved
  final String txid;

  /// Block height
  final int blockHeight;

  /// Merkle root (target)
  final String merkleRoot;

  /// Transaction index in block
  final int index;

  /// Sibling hashes in the merkle path
  final List<String> nodes;

  /// Optional: Format identifier ('tsc', 'bump', etc.)
  final String? format;

  /// Optional: Raw proof data for format-specific processing
  final Map<String, dynamic>? rawData;

  MerkleProofData({
    required this.txid,
    required this.blockHeight,
    required this.merkleRoot,
    required this.index,
    required this.nodes,
    this.format,
    this.rawData,
  });

  factory MerkleProofData.fromJson(Map<String, dynamic> json) {
    return MerkleProofData(
      txid: json['txid'] as String,
      blockHeight: json['blockHeight'] as int,
      merkleRoot: json['merkleRoot'] as String,
      index: json['index'] as int,
      nodes: (json['nodes'] as List).cast<String>(),
      format: json['format'] as String?,
      rawData: json['rawData'] as Map<String, dynamic>?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'txid': txid,
      'blockHeight': blockHeight,
      'merkleRoot': merkleRoot,
      'index': index,
      'nodes': nodes,
      if (format != null) 'format': format,
      if (rawData != null) 'rawData': rawData,
    };
  }
}

/// Result of address discovery scan
class AddressDiscoveryResult {
  /// List of addresses that have transaction history
  final List<DiscoveredAddress> usedAddresses;

  /// Last derivation index checked
  final int lastCheckedIndex;

  /// Total number of transactions found across all addresses
  final int totalTransactions;

  AddressDiscoveryResult({
    required this.usedAddresses,
    required this.lastCheckedIndex,
    required this.totalTransactions,
  });
}

/// Information about a discovered address
class DiscoveredAddress {
  /// The Bitcoin address
  final String address;

  /// BIP44 derivation index
  final int derivationIndex;

  /// Whether this is a change address (m/44'/0'/0'/1/x) vs receiving (m/44'/0'/0'/0/x)
  final bool isChange;

  /// Number of transactions for this address
  final int transactionCount;

  /// List of transaction IDs for this address
  final List<String> txids;

  DiscoveredAddress({
    required this.address,
    required this.derivationIndex,
    required this.isChange,
    required this.transactionCount,
    required this.txids,
  });
}

