import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:synchronized/synchronized.dart';
import 'package:logging/logging.dart';

import '../models/blockchain_data_models.dart';
import 'blockchain_data_source.dart';

/// WhatsOnChain implementation of BlockchainDataSource
///
/// This provides access to Bitcoin SV blockchain data through the
/// WhatsOnChain API (https://whatsonchain.com).
///
/// Features:
/// - Rate limiting (3 requests/second)
/// - Automatic retry with exponential backoff
/// - Support for mainnet and testnet
/// - TSC format merkle proofs
///
/// Example usage:
/// ```dart
/// final dataSource = WhatsOnChainDataSource(networkType: 'test');
/// final history = await dataSource.getTransactionHistory('address...');
/// ```
class WhatsOnChainDataSource implements BlockchainDataSource {
  final Logger _logger = Logger('WhatsOnChainDataSource');

  // Base URLs for WhatsOnChain API
  static const Map<String, String> _baseUrls = {
    'main': 'https://api.whatsonchain.com/v1/bsv/main',
    'test': 'https://api.whatsonchain.com/v1/bsv/test',
  };

  final String _networkType;
  final http.Client _client;

  // Rate limiting parameters
  final int _maxRetries;
  final int _initialBackoffMs;
  final int _requestsPerSecondLimit;

  // Rate limiting state
  final List<DateTime> _recentRequests = [];
  final _rateLimitLock = Lock();

  WhatsOnChainDataSource({
    required String networkType,
    http.Client? client,
    int maxRetries = 3,
    int initialBackoffMs = 1000,
    int requestsPerSecondLimit = 3,
  })  : _networkType = networkType,
        _client = client ?? http.Client(),
        _maxRetries = maxRetries,
        _initialBackoffMs = initialBackoffMs,
        _requestsPerSecondLimit = requestsPerSecondLimit {
    if (!_baseUrls.containsKey(networkType)) {
      throw ArgumentError('Unsupported network type: $networkType');
    }
  }

  String get _baseUrl => _baseUrls[_networkType]!;

  @override
  String get networkType => _networkType;

  @override
  Future<List<TransactionInfo>> getTransactionHistory(
    String address, {
    int? limit,
    int? offset,
  }) async {
    _logger.fine('Getting transaction history for $address');

    final transactions = <TransactionInfo>[];
    String? nextToken;
    int fetchedCount = 0;
    final requestLimit = (limit != null && limit <= 1000) ? limit : 1000;

    // Keep fetching pages until we have all transactions or reach the limit
    do {
      final history = await _getConfirmedHistory(
        address,
        limit: requestLimit,
        token: nextToken,
      );

      final result = history['result'] as List?;

      if (result == null || result.isEmpty) {
        break;
      }

      for (final tx in result) {
        if (tx is Map<String, dynamic>) {
          transactions.add(TransactionInfo(
            txid: tx['tx_hash'] as String? ?? '',
            blockHeight: tx['height'] as int?,
            blockHash: null, // WhatsOnChain doesn't provide this in history
            blockIndex: null, // Not provided in history endpoint
            timestamp: null, // Not provided in history endpoint
          ));
          fetchedCount++;

          // If we have a specific limit and reached it, stop
          if (limit != null && fetchedCount >= limit) {
            break;
          }
        }
      }

      // Get the next page token if available
      nextToken = history['token'] as String?;

      // Continue if we have a token and haven't reached the limit
    } while (nextToken != null && 
             nextToken.isNotEmpty && 
             (limit == null || fetchedCount < limit));

    _logger.fine('Fetched ${transactions.length} transactions for $address');

    // Apply offset if specified
    if (offset != null && offset > 0) {
      if (offset >= transactions.length) {
        return [];
      }
      return transactions.sublist(offset);
    }

    return transactions;
  }

  @override
  Future<String> getRawTransaction(String txid) async {
    _logger.fine('Getting raw transaction for $txid');

    return _retryApiCall<String>(
      () async {
        final response = await _client.get(
          Uri.parse('$_baseUrl/tx/$txid/hex'),
        );

        if (response.statusCode == 200) {
          return response.body;
        } else if (response.statusCode == 404) {
          throw DataSourceException(
            'Transaction not found',
            txid: txid,
          );
        } else {
          throw DataSourceException(
            'Failed to get raw transaction: ${response.statusCode}',
            txid: txid,
          );
        }
      },
      'Error getting raw transaction',
    );
  }

  @override
  Future<MerkleProofData> getMerkleProof(String txid) async {
    _logger.fine('Getting merkle proof for $txid');

    return _retryApiCall<MerkleProofData>(
      () async {
        final response = await _client.get(
          Uri.parse('$_baseUrl/tx/$txid/proof/tsc'),
        );

        if (response.statusCode == 200) {
          if (response.body.contains('null')) {
            throw DataSourceException(
              'Transaction not confirmed or proof not available',
              txid: txid,
            );
          }

          final decoded = json.decode(response.body);
          final standardizedProof = _standardizeTscProof(decoded, txid);

          // Get block height from transaction details
          final txDetails = await _getTransactionDetails(txid);
          final blockHeight = txDetails['blockheight'] as int? ?? 0;

          return MerkleProofData(
            txid: standardizedProof['txOrId'] as String,
            blockHeight: blockHeight,
            merkleRoot: standardizedProof['target'] as String,
            index: standardizedProof['index'] as int,
            nodes: (standardizedProof['nodes'] as List).cast<String>(),
            format: 'tsc',
            rawData: standardizedProof,
          );
        } else if (response.statusCode == 404) {
          throw DataSourceException(
            'Transaction not found or not confirmed',
            txid: txid,
          );
        } else {
          throw DataSourceException(
            'Failed to get merkle proof: ${response.statusCode}',
            txid: txid,
          );
        }
      },
      'Error getting merkle proof',
    );
  }

  @override
  Future<List<UtxoInfo>> getUtxos(String address) async {
    _logger.fine('Getting UTXOs for $address');

    return _retryApiCall<List<UtxoInfo>>(
      () async {
        final response = await _client.get(
          Uri.parse('$_baseUrl/address/$address/unspent/all'),
        );

        if (response.statusCode == 200) {
          final responseData = json.decode(response.body);
          final List<dynamic> result;

          if (responseData is Map<String, dynamic>) {
            result = responseData['result'] as List? ?? [];
          } else if (responseData is List) {
            result = responseData;
          } else {
            return [];
          }

          return result
              .where((utxo) {
                // Filter out UTXOs spent in mempool
                final isSpentInMempool =
                    utxo['isSpentInMempoolTx'] as bool? ?? false;
                return !isSpentInMempool;
              })
              .map((utxo) {
                final status = utxo['status'] as String? ?? 'unknown';
                final isConfirmed = status == 'confirmed';

                return UtxoInfo(
                  txid: utxo['tx_hash'] as String? ?? '',
                  vout: utxo['tx_pos'] as int? ?? 0,
                  value: utxo['value'] as int? ?? 0,
                  height: isConfirmed ? (utxo['height'] as int?) : null,
                  scriptPubKey: utxo['hex'] as String?,
                  address: address,
                );
              })
              .where((utxo) => utxo.txid.isNotEmpty && utxo.value > 0)
              .toList();
        } else if (response.statusCode == 404) {
          return []; // Address has no UTXOs
        } else {
          throw DataSourceException(
            'Failed to get UTXOs: ${response.statusCode}',
            address: address,
          );
        }
      },
      'Error getting UTXOs',
    );
  }

  @override
  Future<String> submitTransaction(String rawTxHex) async {
    _logger.fine('Submitting transaction');

    return _retryApiCall<String>(
      () async {
        final response = await _client.post(
          Uri.parse('$_baseUrl/tx/raw'),
          headers: {'Content-Type': 'application/json'},
          body: json.encode({'txhex': rawTxHex}),
        );

        if (response.statusCode == 200) {
          return response.body.trim();
        } else {
          throw DataSourceException(
            'Failed to submit transaction: ${response.body}',
          );
        }
      },
      'Error submitting transaction',
    );
  }

  @override
  Future<int> getCurrentBlockHeight() async {
    _logger.fine('Getting current block height');

    return _retryApiCall<int>(
      () async {
        final response = await _client.get(
          Uri.parse('$_baseUrl/chain/info'),
        );

        if (response.statusCode == 200) {
          final data = json.decode(response.body);
          return data['blocks'] as int;
        } else {
          throw DataSourceException(
            'Failed to get block height: ${response.statusCode}',
          );
        }
      },
      'Error getting current block height',
    );
  }

  // Private helper methods

  Future<Map<String, dynamic>> _getConfirmedHistory(
    String address, {
    int? limit,
    String? token,
  }) async {
    return _retryApiCall<Map<String, dynamic>>(
      () async {
        final queryParams = <String, String>{};
        if (limit != null && limit >= 1 && limit <= 1000) {
          queryParams['limit'] = limit.toString();
        }
        if (token != null && token.isNotEmpty) {
          queryParams['token'] = token;
        }

        final uri = Uri.parse('$_baseUrl/address/$address/confirmed/history')
            .replace(queryParameters: queryParams);

        final response = await _client.get(uri);

        if (response.statusCode == 200) {
          final responseData = json.decode(response.body);
          if (responseData is Map<String, dynamic>) {
            responseData['address'] = address;
            return responseData;
          } else {
            return {
              'address': address,
              'result': [],
              'error': 'Unexpected response format'
            };
          }
        } else if (response.statusCode == 404) {
          return {
            'address': address,
            'result': [],
            'error': 'Address not found or no history'
          };
        } else {
          throw Exception(
            'Failed to get confirmed history: ${response.statusCode}',
          );
        }
      },
      'Error getting confirmed transaction history',
    );
  }

  Future<Map<String, dynamic>> _getTransactionDetails(String txid) async {
    return _retryApiCall<Map<String, dynamic>>(
      () async {
        final response = await _client.get(
          Uri.parse('$_baseUrl/tx/hash/$txid'),
        );

        if (response.statusCode == 200) {
          return json.decode(response.body) as Map<String, dynamic>;
        } else if (response.statusCode == 404) {
          throw DataSourceException(
            'Transaction not found',
            txid: txid,
          );
        } else {
          throw DataSourceException(
            'Failed to get transaction details: ${response.statusCode}',
            txid: txid,
          );
        }
      },
      'Error getting transaction details',
    );
  }

  Map<String, dynamic> _standardizeTscProof(dynamic decoded, String txid) {
    Map<String, dynamic> standardizedProof = {
      'index': 0,
      'txOrId': txid,
      'target': '',
      'nodes': <String>[],
    };

    // Handle list format
    if (decoded is List) {
      if (decoded.isEmpty) {
        throw DataSourceException('Empty merkle proof', txid: txid);
      }

      if (decoded.first is Map<String, dynamic>) {
        Map<String, dynamic> firstProof =
            Map<String, dynamic>.from(decoded.first);

        standardizedProof['index'] = firstProof['index'] ?? 0;
        standardizedProof['txOrId'] = firstProof['txOrId'] ?? txid;
        standardizedProof['target'] = firstProof['target'] ?? '';

        if (firstProof.containsKey('nodes') && firstProof['nodes'] is List) {
          List<dynamic> nodes = firstProof['nodes'];
          standardizedProof['nodes'] = nodes
              .where((node) => node is String && node != '*')
              .cast<String>()
              .toList();
        }
      } else {
        // Legacy array format [txid, merkleroot, nodes, index]
        standardizedProof['txOrId'] = txid;
        standardizedProof['target'] = decoded.length > 1 ? decoded[1] : '';

        if (decoded.length > 2 && decoded[2] is List) {
          standardizedProof['nodes'] = decoded[2]
              .where((node) => node is String && node != '*')
              .cast<String>()
              .toList();
        }

        standardizedProof['index'] = decoded.length > 3 ? decoded[3] : 0;
      }
    }
    // Handle map format
    else if (decoded is Map) {
      Map<String, dynamic> proofMap = Map<String, dynamic>.from(decoded);

      standardizedProof['index'] = proofMap['index'] ?? 0;
      standardizedProof['txOrId'] =
          proofMap['txOrId'] ?? proofMap['hash'] ?? txid;
      standardizedProof['target'] =
          proofMap['target'] ?? proofMap['merkleroot'] ?? '';

      if (proofMap.containsKey('nodes') && proofMap['nodes'] is List) {
        List<dynamic> nodes = proofMap['nodes'];
        standardizedProof['nodes'] = nodes
            .where((node) => node is String && node != '*')
            .cast<String>()
            .toList();
      }
    } else {
      throw DataSourceException('Unexpected merkle proof format', txid: txid);
    }

    return standardizedProof;
  }

  Future<T> _retryApiCall<T>(
    Future<T> Function() apiCall,
    String errorPrefix,
  ) async {
    int retryCount = 0;
    int backoffMs = _initialBackoffMs;

    while (true) {
      try {
        await _waitForRateLimit();
        await _recordRequest();
        return await apiCall();
      } catch (e) {
        if (retryCount >= _maxRetries) {
          throw DataSourceException(
            '$errorPrefix (max retries exceeded)',
            originalError: e,
          );
        }

        final isRateLimitError = e.toString().contains('429');
        if (!isRateLimitError) {
          rethrow;
        }

        retryCount++;
        _logger.warning(
          'Rate limit hit, retrying in ${backoffMs}ms (attempt $retryCount of $_maxRetries)',
        );

        await Future.delayed(Duration(milliseconds: backoffMs));
        backoffMs *= 2;
      }
    }
  }

  Future<void> _waitForRateLimit() async {
    final now = DateTime.now();

    await _rateLimitLock.synchronized(() {
      _recentRequests.removeWhere(
        (requestTime) => now.difference(requestTime).inMilliseconds > 1000,
      );
    });

    if (_recentRequests.length < _requestsPerSecondLimit) {
      return;
    }

    final oldestAllowedRequest = await _rateLimitLock.synchronized(() {
      return _recentRequests.first;
    });

    final timeToWait =
        1000 - now.difference(oldestAllowedRequest).inMilliseconds + 50;

    if (timeToWait > 0) {
      _logger.fine('Rate limit approaching, waiting ${timeToWait}ms');
      await Future.delayed(Duration(milliseconds: timeToWait));
    }
  }

  Future<void> _recordRequest() async {
    final now = DateTime.now();
    await _rateLimitLock.synchronized(() {
      _recentRequests.add(now);
    });
  }

  /// Close the HTTP client
  void dispose() {
    _client.close();
  }
}

