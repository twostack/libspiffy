import '../models/blockchain_data_models.dart';

/// Abstract interface for blockchain data providers
///
/// This interface allows LibSpiffy to work with different blockchain
/// data sources (WhatsOnChain, Electrum, custom nodes, etc.) without
/// being tightly coupled to any specific implementation.
///
/// Applications can:
/// 1. Use the built-in WhatsOnChainDataSource implementation
/// 2. Implement their own custom data source
/// 3. Swap implementations without changing wallet code
///
/// Example:
/// ```dart
/// // Use built-in WhatsOnChain implementation
/// final dataSource = WhatsOnChainDataSource(networkType: 'test');
/// libspiffy.registerDataSource(dataSource);
///
/// // Or implement custom source
/// class MyCustomDataSource implements BlockchainDataSource {
///   @override
///   Future<List<TransactionInfo>> getTransactionHistory(String address) async {
///     // Custom implementation
///   }
///   // ... other methods
/// }
/// ```
abstract class BlockchainDataSource {
  /// Get transaction history for an address
  ///
  /// Returns transactions in reverse chronological order (newest first).
  /// Implementations should handle pagination internally if needed.
  ///
  /// Parameters:
  /// - [address]: Bitcoin address to query
  /// - [limit]: Optional maximum number of transactions to return
  /// - [offset]: Optional offset for pagination
  ///
  /// Returns list of [TransactionInfo] with at minimum:
  /// - txid
  /// - blockHeight (if confirmed)
  /// - blockIndex (if available, needed for merkle proofs)
  Future<List<TransactionInfo>> getTransactionHistory(
    String address, {
    int? limit,
    int? offset,
  });

  /// Get raw transaction hex by transaction ID
  ///
  /// Returns the complete raw transaction in hexadecimal format.
  ///
  /// Throws [DataSourceException] if transaction not found.
  Future<String> getRawTransaction(String txid);

  /// Get merkle proof for a confirmed transaction
  ///
  /// Returns proof data that can be converted to BUMP format for SPV validation.
  ///
  /// Must include:
  /// - Transaction index in block
  /// - Merkle root
  /// - Sibling hashes for merkle path
  ///
  /// Throws [DataSourceException] if:
  /// - Transaction not found
  /// - Transaction is unconfirmed
  /// - Merkle proof unavailable
  Future<MerkleProofData> getMerkleProof(String txid);

  /// Get unspent transaction outputs (UTXOs) for an address
  ///
  /// Returns all UTXOs currently spendable for the given address.
  ///
  /// Parameters:
  /// - [address]: Bitcoin address to query
  ///
  /// Returns list of [UtxoInfo] with:
  /// - txid and vout identifying the UTXO
  /// - value in satoshis
  /// - height (if available)
  Future<List<UtxoInfo>> getUtxos(String address);

  /// Get all scripts associated with an address
  ///
  /// Returns all script types (P2PKH, P2MS, P2SH, etc.) that include
  /// this address's public key. This enables discovery of multisig
  /// involvement and other script types beyond standard P2PKH.
  ///
  /// Parameters:
  /// - [address]: Bitcoin address to query
  ///
  /// Returns list of [AddressScriptInfo] with script hashes and types.
  /// Empty list if address has no associated scripts.
  Future<List<AddressScriptInfo>> getAddressScripts(String address);

  /// Get transaction history for a specific script hash
  ///
  /// Returns transactions involving a specific script (identified by hash).
  /// Useful for fetching multisig or other non-standard script transactions.
  ///
  /// Parameters:
  /// - [scriptHash]: Script hash (hex string) to query
  /// - [limit]: Optional maximum number of transactions to return
  /// - [offset]: Optional offset for pagination
  ///
  /// Returns list of [TransactionInfo] for transactions using this script.
  Future<List<TransactionInfo>> getScriptHistory(
    String scriptHash, {
    int? limit,
    int? offset,
  });

  /// Optional: Submit a raw transaction to the network
  ///
  /// Implementations may throw [UnsupportedError] if broadcast
  /// is not supported by this data source.
  ///
  /// Returns the transaction ID if successful.
  ///
  /// Throws [DataSourceException] if submission fails.
  Future<String> submitTransaction(String rawTxHex) {
    throw UnsupportedError(
      'Transaction submission not supported by this data source',
    );
  }

  /// Optional: Get current block height
  ///
  /// Useful for determining confirmation counts.
  ///
  /// Throws [UnsupportedError] if not supported.
  Future<int> getCurrentBlockHeight() {
    throw UnsupportedError(
      'Block height query not supported by this data source',
    );
  }

  /// Network type this data source is configured for
  ///
  /// Returns 'main' for mainnet, 'test' for testnet, or other network identifiers.
  String get networkType;
}

/// Exception thrown by blockchain data sources
class DataSourceException implements Exception {
  final String message;
  final String? txid;
  final String? address;
  final dynamic originalError;

  DataSourceException(
    this.message, {
    this.txid,
    this.address,
    this.originalError,
  });

  @override
  String toString() {
    final buffer = StringBuffer('DataSourceException: $message');
    if (txid != null) buffer.write(' (txid: $txid)');
    if (address != null) buffer.write(' (address: $address)');
    if (originalError != null) buffer.write('\nCaused by: $originalError');
    return buffer.toString();
  }
}

