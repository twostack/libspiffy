import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;

import 'arc_service_config.dart';

/// Status of a transaction in the ARC system
enum ArcTransactionStatus {
  unknown,
  queued,
  received,
  stored,
  announcedToNetwork,
  requestedByNetwork,
  sentToNetwork,
  acceptedByNetwork,
  seenInOrphanMempool,
  seenOnNetwork,
  doubleSpendAttempted,
  minedInStaleBlock,
  rejected,
  mined
}

/// Response from submitting a transaction to ARC
class ArcSubmitResponse {
  final String txid;
  final ArcTransactionStatus status;
  final String? message;
  final int? blockHeight;
  final String? blockHash;
  final String? timestamp;  // date-time string, not integer
  final List<String>? doubleSpendTxids;

  ArcSubmitResponse({
    required this.txid,
    required this.status,
    this.message,
    this.blockHeight,
    this.blockHash,
    this.timestamp,
    this.doubleSpendTxids,
  });

  factory ArcSubmitResponse.fromJson(Map<String, dynamic> json) {
    ArcTransactionStatus status = ArcTransactionStatus.unknown;
    if (json['txStatus'] != null) {
      switch (json['txStatus']) {
        case 'QUEUED':
          status = ArcTransactionStatus.queued;
          break;
        case 'RECEIVED':
          status = ArcTransactionStatus.received;
          break;
        case 'STORED':
          status = ArcTransactionStatus.stored;
          break;
        case 'ANNOUNCED_TO_NETWORK':
          status = ArcTransactionStatus.announcedToNetwork;
          break;
        case 'REQUESTED_BY_NETWORK':
          status = ArcTransactionStatus.requestedByNetwork;
          break;
        case 'SENT_TO_NETWORK':
          status = ArcTransactionStatus.sentToNetwork;
          break;
        case 'ACCEPTED_BY_NETWORK':
          status = ArcTransactionStatus.acceptedByNetwork;
          break;
        case 'SEEN_IN_ORPHAN_MEMPOOL':
          status = ArcTransactionStatus.seenInOrphanMempool;
          break;
        case 'SEEN_ON_NETWORK':
          status = ArcTransactionStatus.seenOnNetwork;
          break;
        case 'DOUBLE_SPEND_ATTEMPTED':
          status = ArcTransactionStatus.doubleSpendAttempted;
          break;
        case 'MINED_IN_STALE_BLOCK':
          status = ArcTransactionStatus.minedInStaleBlock;
          break;
        case 'REJECTED':
          status = ArcTransactionStatus.rejected;
          break;
        case 'MINED':
          status = ArcTransactionStatus.mined;
          break;
        default:
          status = ArcTransactionStatus.unknown;
      }
    }

    return ArcSubmitResponse(
      txid: json['txid'] ?? '',
      status: status,
      message: json['message'],
      blockHeight: json['blockHeight'] is String 
          ? int.tryParse(json['blockHeight']) 
          : json['blockHeight'] as int?,
      blockHash: json['blockHash'],
      timestamp: json['timestamp']?.toString(),  // Keep as date-time string
      doubleSpendTxids: json['doubleSpendTxids'] != null
          ? List<String>.from(json['doubleSpendTxids'])
          : null,
    );
  }
}

/// Response from querying a transaction status from ARC
class ArcTransactionResponse {
  final String txid;
  final ArcTransactionStatus status;
  final String? message;
  final int? blockHeight;
  final String? blockHash;
  final String? timestamp;  // date-time string, not integer
  final List<String>? doubleSpendTxids;
  final String? rawTx;
  final List<String>? merklePath;
  final String? merkleRoot;

  ArcTransactionResponse({
    required this.txid,
    required this.status,
    this.message,
    this.blockHeight,
    this.blockHash,
    this.timestamp,
    this.doubleSpendTxids,
    this.rawTx,
    this.merklePath,
    this.merkleRoot,
  });

  factory ArcTransactionResponse.fromJson(Map<String, dynamic> json) {
    ArcTransactionStatus status = ArcTransactionStatus.unknown;
    if (json['txStatus'] != null) {
      switch (json['txStatus']) {
        case 'QUEUED':
          status = ArcTransactionStatus.queued;
          break;
        case 'RECEIVED':
          status = ArcTransactionStatus.received;
          break;
        case 'STORED':
          status = ArcTransactionStatus.stored;
          break;
        case 'ANNOUNCED_TO_NETWORK':
          status = ArcTransactionStatus.announcedToNetwork;
          break;
        case 'REQUESTED_BY_NETWORK':
          status = ArcTransactionStatus.requestedByNetwork;
          break;
        case 'SENT_TO_NETWORK':
          status = ArcTransactionStatus.sentToNetwork;
          break;
        case 'ACCEPTED_BY_NETWORK':
          status = ArcTransactionStatus.acceptedByNetwork;
          break;
        case 'SEEN_IN_ORPHAN_MEMPOOL':
          status = ArcTransactionStatus.seenInOrphanMempool;
          break;
        case 'SEEN_ON_NETWORK':
          status = ArcTransactionStatus.seenOnNetwork;
          break;
        case 'DOUBLE_SPEND_ATTEMPTED':
          status = ArcTransactionStatus.doubleSpendAttempted;
          break;
        case 'MINED_IN_STALE_BLOCK':
          status = ArcTransactionStatus.minedInStaleBlock;
          break;
        case 'REJECTED':
          status = ArcTransactionStatus.rejected;
          break;
        case 'MINED':
          status = ArcTransactionStatus.mined;
          break;
        default:
          status = ArcTransactionStatus.unknown;
      }
    }

    return ArcTransactionResponse(
      txid: json['txid'] ?? '',
      status: status,
      message: json['message'],
      blockHeight: json['blockHeight'] is String 
          ? int.tryParse(json['blockHeight']) 
          : json['blockHeight'] as int?,
      blockHash: json['blockHash'],
      timestamp: json['timestamp']?.toString(),  // Keep as date-time string
      doubleSpendTxids: json['doubleSpendTxids'] != null
          ? List<String>.from(json['doubleSpendTxids'])
          : null,
      rawTx: json['rawTx'],
      merklePath: json['merklePath'] != null
          ? List<String>.from(json['merklePath'])
          : null,
      merkleRoot: json['merkleRoot'],
    );
  }
}

/// Policy settings response from ARC
class ArcPolicyResponse {
  final int maxTxSize;
  final double minFeePerKb;
  final double standardFeePerKb;
  final double dataFeePerKb;

  ArcPolicyResponse({
    required this.maxTxSize,
    required this.minFeePerKb,
    required this.standardFeePerKb,
    required this.dataFeePerKb,
  });

  factory ArcPolicyResponse.fromJson(Map<String, dynamic> json) {
    return ArcPolicyResponse(
      maxTxSize: json['maxTxSize'] is String 
          ? int.tryParse(json['maxTxSize']) ?? 100000000
          : (json['maxTxSize'] as int?) ?? 100000000,
      minFeePerKb: json['minFeePerKb'] is String 
          ? double.tryParse(json['minFeePerKb']) ?? 0.5
          : (json['minFeePerKb'] as double?) ?? 0.5,
      standardFeePerKb: json['standardFeePerKb'] is String 
          ? double.tryParse(json['standardFeePerKb']) ?? 0.5
          : (json['standardFeePerKb'] as double?) ?? 0.5,
      dataFeePerKb: json['dataFeePerKb'] is String 
          ? double.tryParse(json['dataFeePerKb']) ?? 0.5
          : (json['dataFeePerKb'] as double?) ?? 0.5,
    );
  }
}

/// Health status response from ARC
class ArcHealthResponse {
  final bool healthy;
  final String? message;

  ArcHealthResponse({
    required this.healthy,
    this.message,
  });

  factory ArcHealthResponse.fromJson(Map<String, dynamic> json) {
    return ArcHealthResponse(
      healthy: json['healthy'] ?? false,
      message: json['message'],
    );
  }
}

/// Merkle proof response for BEEF format support
class ArcMerkleProofResponse {
  final String txid;
  final List<String> merklePath;
  final String merkleRoot;
  final int blockHeight;
  final String? blockHash;

  ArcMerkleProofResponse({
    required this.txid,
    required this.merklePath,
    required this.merkleRoot,
    required this.blockHeight,
    this.blockHash,
  });

  factory ArcMerkleProofResponse.fromJson(Map<String, dynamic> json) {
    return ArcMerkleProofResponse(
      txid: json['txid'] ?? '',
      merklePath: json['merklePath'] != null
          ? List<String>.from(json['merklePath'])
          : [],
      merkleRoot: json['merkleRoot'] ?? '',
      blockHeight: json['blockHeight'] is String 
          ? int.tryParse(json['blockHeight']) ?? 0
          : (json['blockHeight'] as int?) ?? 0,
      blockHash: json['blockHash'],
    );
  }
}

/// Service for interacting with the ARC API (Advanced Relayer Console)
/// 
/// ARC is the successor to mAPI (merchant API) and implements the BIP-239 
/// standard for BEEF (Background Evaluation Extended Format) transaction submission.
/// 
/// **TAAL ARC Endpoints:**
/// - Mainnet: https://arc.taal.com/v1
/// - Testnet: https://arc-test.taal.com/v1
/// 
/// **Authentication:**
/// All requests include an Authorization header when an API key is provided.
/// The testnet default configuration includes a testnet API key automatically.
/// Format: `Authorization: Bearer <apiKey>`
/// 
/// **Documentation:**
/// - API Reference: https://bitcoin-sv.github.io/arc/api.html
/// - BIP-239 Standard: https://github.com/bitcoin-sv/arc/blob/master/doc/BIP-239.md
/// - GitHub: https://github.com/bitcoin-sv/arc
class ArcService {
  final String baseUrl;
  final String? apiKey;
  final http.Client _client;
  
  /// Create a new ARC service
  /// 
  /// [baseUrl] - The base URL of the ARC API (e.g., https://arc.taal.com/v1 for mainnet,
  ///             https://arc-test.taal.com/v1 for testnet)
  /// [apiKey] - Optional API key for authentication (required for TAAL production use)
  ArcService({
    required this.baseUrl,
    this.apiKey,
    http.Client? client,
  }) : _client = client ?? http.Client();

  /// Create ARC service from configuration
  factory ArcService.fromConfig(ArcServiceConfig config, {http.Client? client}) {
    return ArcService(
      baseUrl: config.baseUrl,
      apiKey: config.apiKey,
      client: client,
    );
  }

  /// Get the default headers for API requests
  Map<String, String> get _headers {
    final headers = {
      'Content-Type': 'application/json',
      'Accept': 'application/json',
    };

    if (apiKey != null) {
      headers['Authorization'] = 'Bearer $apiKey';
    }

    return headers;
  }

  /// Submit a raw transaction to the network
  /// 
  /// [rawTx] - The raw transaction in hex format
  /// [callbackUrl] - Optional callback URL to receive transaction status updates
  Future<ArcSubmitResponse> submitTransaction(String rawTx, {String? callbackUrl}) async {
    final url = '$baseUrl/tx';
    
    final headers = Map<String, String>.from(_headers);
    if (callbackUrl != null) {
      headers['X-CallbackUrl'] = callbackUrl;
    }
    
    final response = await _client.post(
      Uri.parse(url),
      headers: headers,
      body: jsonEncode({
        'rawTx': rawTx,
      }),
    );

    if (response.statusCode == 200 || response.statusCode == 201) {
      return ArcSubmitResponse.fromJson(jsonDecode(response.body));
    } else {
      throw ArcException('Failed to submit transaction: ${response.body}');
    }
  }

  /// Submit BEEF transactions via Extended Format (EF)
  /// 
  /// **Note**: This method has been replaced by the ARCActor's internal
  /// Extended Format conversion. BEEF packages are now:
  /// 1. Parsed to extract the payment transaction and ancestors
  /// 2. Converted to Extended Format (EF) which includes previous output data
  /// 3. Submitted via `submitTransaction()` to the `/tx` endpoint
  /// 
  /// Extended Format (BRC-30/BIP-239) allows nodes to validate transactions
  /// without UTXO lookup by including the previous output script and value
  /// for each input directly in the transaction format.
  /// 
  /// See: `ARCActor._convertToExtendedFormat()` for implementation details.

  /// Get the status of a transaction
  /// 
  /// [txid] - The transaction ID
  Future<ArcTransactionResponse> getTransaction(String txid) async {
    final url = '$baseUrl/tx/$txid';
    
    final response = await _client.get(
      Uri.parse(url),
      headers: _headers,
    );

    if (response.statusCode == 200) {
      return ArcTransactionResponse.fromJson(jsonDecode(response.body));
    } else {
      throw ArcException('Failed to get transaction: ${response.body}');
    }
  }

  /// Get the raw transaction data
  /// 
  /// [txid] - The transaction ID
  Future<String> getRawTransaction(String txid) async {
    final url = '$baseUrl/tx/$txid/raw';
    
    final response = await _client.get(
      Uri.parse(url),
      headers: _headers,
    );

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      return data['rawTx'] ?? '';
    } else {
      throw ArcException('Failed to get raw transaction: ${response.body}');
    }
  }

  /// Get merkle proof for a transaction (BEEF support)
  /// 
  /// [txid] - The transaction ID
  Future<ArcMerkleProofResponse?> getMerkleProof(String txid) async {
    final url = '$baseUrl/tx/$txid/proof';
    
    try {
      final response = await _client.get(
        Uri.parse(url),
        headers: _headers,
      );

      if (response.statusCode == 200) {
        return ArcMerkleProofResponse.fromJson(jsonDecode(response.body));
      } else {
        return null; // Proof not available yet
      }
    } catch (e) {
      return null; // Proof not available
    }
  }

  /// Get merkle proofs for multiple transactions (BEEF support)
  /// 
  /// [txids] - List of transaction IDs
  Future<List<ArcMerkleProofResponse>> getBatchMerkleProofs(List<String> txids) async {
    final url = '$baseUrl/tx/proofs';
    
    final response = await _client.post(
      Uri.parse(url),
      headers: _headers,
      body: jsonEncode({
        'txids': txids,
      }),
    );

    if (response.statusCode == 200) {
      final List<dynamic> data = jsonDecode(response.body);
      return data.map((item) => ArcMerkleProofResponse.fromJson(item)).toList();
    } else {
      throw ArcException('Failed to get batch merkle proofs: ${response.body}');
    }
  }

  /// Get the policy settings
  Future<ArcPolicyResponse> getPolicy() async {
    final url = '$baseUrl/policy';
    
    final response = await _client.get(
      Uri.parse(url),
      headers: _headers,
    );

    if (response.statusCode == 200) {
      return ArcPolicyResponse.fromJson(jsonDecode(response.body));
    } else {
      throw ArcException('Failed to get policy: ${response.body}');
    }
  }

  /// Check the health of the ARC service
  Future<ArcHealthResponse> getHealth() async {
    final url = '$baseUrl/health';
    
    final response = await _client.get(
      Uri.parse(url),
      headers: _headers,
    );

    if (response.statusCode == 200) {
      return ArcHealthResponse.fromJson(jsonDecode(response.body));
    } else {
      throw ArcException('Failed to get health status: ${response.body}');
    }
  }

  /// Submit multiple transactions in a batch
  /// 
  /// [rawTxs] - List of raw transactions in hex format
  /// [callbackUrl] - Optional callback URL to receive transaction status updates
  Future<List<ArcSubmitResponse>> submitBatchTransactions(
    List<String> rawTxs, 
    {String? callbackUrl}
  ) async {
    final url = '$baseUrl/tx/batch';
    
    final headers = Map<String, String>.from(_headers);
    if (callbackUrl != null) {
      headers['X-CallbackUrl'] = callbackUrl;
    }
    
    final response = await _client.post(
      Uri.parse(url),
      headers: headers,
      body: jsonEncode({
        'rawTxs': rawTxs,
      }),
    );

    if (response.statusCode == 200 || response.statusCode == 201) {
      final List<dynamic> data = jsonDecode(response.body);
      return data.map((item) => ArcSubmitResponse.fromJson(item)).toList();
    } else {
      throw ArcException('Failed to submit batch transactions: ${response.body}');
    }
  }

  /// Get the status of multiple transactions
  /// 
  /// [txids] - List of transaction IDs
  Future<List<ArcTransactionResponse>> getBatchTransactions(List<String> txids) async {
    final url = '$baseUrl/tx/batch';
    
    final response = await _client.post(
      Uri.parse(url),
      headers: _headers,
      body: jsonEncode({
        'txids': txids,
      }),
    );

    if (response.statusCode == 200) {
      final List<dynamic> data = jsonDecode(response.body);
      return data.map((item) => ArcTransactionResponse.fromJson(item)).toList();
    } else {
      throw ArcException('Failed to get batch transactions: ${response.body}');
    }
  }

  /// Estimate fee for a transaction based on ARC policy
  /// 
  /// [inputCount] - Number of inputs in the transaction
  /// [outputCount] - Number of outputs in the transaction
  /// [dataSize] - Additional data size in bytes (for OP_RETURN outputs)
  Future<BigInt> estimateFee({
    required int inputCount, 
    required int outputCount,
    int dataSize = 0,
  }) async {
    final policy = await getPolicy();
    
    // Estimate transaction size (rough calculation)
    // Input: ~148 bytes (P2PKH), Output: ~34 bytes (P2PKH), ~25 bytes base
    final estimatedSize = 25 + (inputCount * 148) + (outputCount * 34) + dataSize;
    final estimatedSizeKb = estimatedSize / 1000.0;
    
    // Use standard fee rate
    final feeInSatoshis = (estimatedSizeKb * policy.standardFeePerKb).ceil();
    
    return BigInt.from(feeInSatoshis);
  }

  /// Close the HTTP client
  void dispose() {
    _client.close();
  }
}

/// Exception thrown by ARC service operations
class ArcException implements Exception {
  final String message;
  
  ArcException(this.message);
  
  @override
  String toString() => 'ArcException: $message';
} 