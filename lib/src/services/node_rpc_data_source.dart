import 'dart:convert';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

import '../models/blockchain_data_models.dart';
import 'blockchain_data_source.dart';

/// BSV node JSON-RPC implementation of [BlockchainDataSource].
///
/// Queries a local BSV node's JSON-RPC API for blockchain data.
/// Designed for regtest environments where WhatsOnChain is unavailable.
///
/// Example:
/// ```dart
/// final dataSource = NodeRpcDataSource(
///   rpcUrl: 'http://localhost:18332',
///   rpcUser: 'bitcoin',
///   rpcPassword: 'bitcoin',
/// );
/// final utxos = await dataSource.getUtxos('n2ar44RA...');
/// ```
class NodeRpcDataSource implements BlockchainDataSource {
  final Logger _logger = Logger('NodeRpcDataSource');
  final String _rpcUrl;
  final String _authHeader;
  final http.Client _client;
  int _requestId = 0;

  NodeRpcDataSource({
    required String rpcUrl,
    required String rpcUser,
    required String rpcPassword,
    http.Client? client,
  })  : _rpcUrl = rpcUrl,
        _authHeader =
            'Basic ${base64Encode(utf8.encode('$rpcUser:$rpcPassword'))}',
        _client = client ?? http.Client();

  @override
  String get networkType => 'regtest';

  // ---------------------------------------------------------------------------
  // JSON-RPC helper
  // ---------------------------------------------------------------------------

  Future<dynamic> _rpcCall(String method,
      [List<dynamic> params = const []]) async {
    _requestId++;
    final body = json.encode({
      'jsonrpc': '2.0',
      'method': method,
      'params': params,
      'id': _requestId,
    });

    final http.Response response;
    try {
      response = await _client.post(
        Uri.parse(_rpcUrl),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': _authHeader,
        },
        body: body,
      );
    } catch (e) {
      throw DataSourceException(
        'RPC connection failed for $method: $e',
        originalError: e,
      );
    }

    if (response.statusCode != 200) {
      throw DataSourceException(
        'RPC call $method failed: HTTP ${response.statusCode}',
      );
    }

    final result = json.decode(response.body) as Map<String, dynamic>;
    if (result['error'] != null) {
      final err = result['error'] as Map<String, dynamic>;
      throw DataSourceException(
        'RPC error in $method: ${err['message']}',
      );
    }

    return result['result'];
  }

  // ---------------------------------------------------------------------------
  // BlockchainDataSource — required methods
  // ---------------------------------------------------------------------------

  @override
  Future<List<TransactionInfo>> getTransactionHistory(
    String address, {
    int? limit,
    int? offset,
  }) async {
    _logger.info('📡 getTransactionHistory for $address');

    // Safety net: ensure the node wallet tracks this address (idempotent).
    // Fails silently for addresses already in the wallet.
    try {
      await _rpcCall('importaddress', [address, '', false]);
    } catch (_) {
      // Expected to fail if address is already a wallet key (not watch-only)
    }

    // Fetch all wallet transactions and filter by address
    final txList =
        await _rpcCall('listtransactions', ['*', 9999, 0, true]) as List;

    // Current block height for computing blockHeight from confirmations
    final blockCount = await _rpcCall('getblockcount') as int;

    // Deduplicate by txid (same tx can appear as both 'send' and 'receive')
    final seen = <String>{};
    final results = <TransactionInfo>[];

    for (final entry in txList) {
      final txAddress = entry['address'] as String?;
      if (txAddress != address) continue;

      final txid = entry['txid'] as String;
      if (!seen.add(txid)) continue;

      final confirmations = entry['confirmations'] as int? ?? 0;
      final blockHeight = confirmations > 0 ? blockCount - confirmations + 1 : null;
      final blockHash = entry['blockhash'] as String?;

      results.add(TransactionInfo(
        txid: txid,
        blockHeight: blockHeight,
        blockHash: blockHash,
      ));
    }

    _logger.info('   Found ${results.length} transactions for $address');

    // Apply offset/limit
    var output = results;
    if (offset != null && offset > 0) {
      output = output.skip(offset).toList();
    }
    if (limit != null && limit > 0) {
      output = output.take(limit).toList();
    }

    return output;
  }

  @override
  Future<String> getRawTransaction(String txid) async {
    _logger.fine('📡 getRawTransaction $txid');
    final rawHex = await _rpcCall('getrawtransaction', [txid, 0]);
    return rawHex as String;
  }

  @override
  Future<MerkleProofData> getMerkleProof(String txid) async {
    _logger.info('📡 getMerkleProof for $txid');

    // 1. Get transaction details (blockhash, blockheight)
    final txDetails =
        await _rpcCall('getrawtransaction', [txid, true]) as Map<String, dynamic>;
    final blockHash = txDetails['blockhash'] as String?;
    final blockHeight = txDetails['blockheight'] as int?;

    if (blockHash == null || blockHeight == null) {
      throw DataSourceException(
        'Transaction $txid is unconfirmed — cannot produce merkle proof',
        txid: txid,
      );
    }

    // 2. Get block with ordered txid list
    final block =
        await _rpcCall('getblock', [blockHash, 1]) as Map<String, dynamic>;
    final blockTxids = (block['tx'] as List).cast<String>();
    final merkleRoot = block['merkleroot'] as String;

    // 3. Find target index
    final targetIndex = blockTxids.indexOf(txid);
    if (targetIndex < 0) {
      throw DataSourceException(
        'Transaction $txid not found in block $blockHash',
        txid: txid,
      );
    }

    // 4. Compute merkle proof
    final siblingHashes = _computeMerkleProof(blockTxids, targetIndex);

    _logger.info(
        '   Proof: block $blockHeight, index $targetIndex, ${siblingHashes.length} siblings');

    return MerkleProofData(
      txid: txid,
      blockHeight: blockHeight,
      merkleRoot: merkleRoot,
      index: targetIndex,
      nodes: siblingHashes,
      format: 'tsc',
    );
  }

  @override
  Future<List<UtxoInfo>> getUtxos(String address) async {
    _logger.info('📡 getUtxos for $address');

    final utxoList =
        await _rpcCall('listunspent', [0, 9999999, [address]]) as List;

    final results = utxoList.map((u) {
      final amount = u['amount'] as num;
      final satoshis = (amount * 100000000).round();
      return UtxoInfo(
        txid: u['txid'] as String,
        vout: u['vout'] as int,
        value: satoshis,
        height: null, // listunspent doesn't directly provide block height
        scriptPubKey: u['scriptPubKey'] as String?,
        address: u['address'] as String?,
      );
    }).toList();

    _logger.info('   Found ${results.length} UTXOs for $address');
    return results;
  }

  @override
  Future<List<AddressScriptInfo>> getAddressScripts(String address) async {
    // Not needed for import flow
    return const [];
  }

  @override
  Future<List<TransactionInfo>> getScriptHistory(
    String scriptHash, {
    int? limit,
    int? offset,
  }) async {
    // Not needed for import flow
    return const [];
  }

  // ---------------------------------------------------------------------------
  // BlockchainDataSource — optional methods
  // ---------------------------------------------------------------------------

  @override
  Future<String> submitTransaction(String rawTxHex) async {
    _logger.info('📡 submitTransaction');
    final txid = await _rpcCall('sendrawtransaction', [rawTxHex]);
    return txid as String;
  }

  @override
  Future<int> getCurrentBlockHeight() async {
    final count = await _rpcCall('getblockcount');
    return count as int;
  }

  // ---------------------------------------------------------------------------
  // Merkle proof computation
  // ---------------------------------------------------------------------------

  /// Compute merkle proof sibling hashes from block txid list.
  ///
  /// Returns sibling hashes in big-endian display hex (matching TSC/WoC format
  /// expected by [TscConverter]).
  ///
  /// For single-tx blocks, returns the txid itself as a self-sibling so that
  /// downstream converters receive a non-empty nodes list.
  List<String> _computeMerkleProof(List<String> txids, int targetIndex) {
    if (txids.length == 1) {
      // Single-tx block: merkle root == txid. Provide txid as self-sibling.
      return [txids[0]];
    }

    // Convert display-format txids (big-endian) to internal byte arrays (little-endian)
    var level = txids.map(_displayToInternal).toList();
    var idx = targetIndex;
    final siblings = <String>[];

    while (level.length > 1) {
      // If odd count, duplicate last element
      if (level.length.isOdd) {
        level.add(Uint8List.fromList(level.last));
      }

      // Record sibling
      final siblingIdx = idx ^ 1;
      siblings.add(_internalToDisplay(level[siblingIdx]));

      // Build next level
      final nextLevel = <Uint8List>[];
      for (var i = 0; i < level.length; i += 2) {
        nextLevel.add(_doubleSha256(
          Uint8List.fromList([...level[i], ...level[i + 1]]),
        ));
      }

      level = nextLevel;
      idx = idx ~/ 2;
    }

    return siblings;
  }

  /// Double SHA-256 hash (Bitcoin standard).
  Uint8List _doubleSha256(Uint8List data) {
    final first = sha256.convert(data);
    final second = sha256.convert(first.bytes);
    return Uint8List.fromList(second.bytes);
  }

  /// Convert big-endian display hex to little-endian internal bytes.
  Uint8List _displayToInternal(String displayHex) {
    final bytes = hex.decode(displayHex);
    return Uint8List.fromList(bytes.reversed.toList());
  }

  /// Convert little-endian internal bytes to big-endian display hex.
  String _internalToDisplay(Uint8List internalBytes) {
    return hex.encode(internalBytes.reversed.toList());
  }
}
