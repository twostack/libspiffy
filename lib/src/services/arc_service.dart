import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:http/http.dart' as http;

import '../utils/bump.dart';

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

  /// ARC's `merklePath` when the submission is already MINED: the BRC-74
  /// BUMP as hex in a one-element list, as in [ArcTransactionResponse].
  final List<String>? merklePath;

  /// The BUMP hex when ARC returned a merkle path, else null.
  String? get merklePathHex =>
      (merklePath != null && merklePath!.length == 1 && merklePath!.single.isNotEmpty)
          ? merklePath!.single
          : null;

  ArcSubmitResponse({
    required this.txid,
    required this.status,
    this.message,
    this.blockHeight,
    this.blockHash,
    this.timestamp,
    this.doubleSpendTxids,
    this.merklePath,
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
      merklePath: switch (json['merklePath']) {
        final List<dynamic> list => [for (final e in list) e.toString()],
        final String s when s.isNotEmpty => [s],
        _ => null,
      },
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
  /// ARC's `merklePath`: the BRC-74 BUMP as hex, wrapped in a one-element
  /// list (the same `[rawBumpHex]` form `MerkleProof.merkleProof` stores).
  final List<String>? merklePath;
  final String? merkleRoot;

  /// The BUMP hex when ARC returned a merkle path, else null.
  String? get merklePathHex =>
      (merklePath != null && merklePath!.length == 1 && merklePath!.single.isNotEmpty)
          ? merklePath!.single
          : null;

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

    // Safely parse lists that might be strings or other types
    List<String>? parseStringList(dynamic value) {
      if (value == null) return null;
      if (value is List) {
        return value.map((e) => e.toString()).toList();
      }
      if (value is String && value.isNotEmpty) {
        return [value]; // Wrap single string in list
      }
      return null;
    }
    
    return ArcTransactionResponse(
      txid: json['txid'] ?? '',
      status: status,
      message: json['message'] ?? json['extraInfo'], // API uses 'extraInfo' sometimes
      blockHeight: json['blockHeight'] is String 
          ? int.tryParse(json['blockHeight']) 
          : json['blockHeight'] as int?,
      blockHash: json['blockHash'],
      timestamp: json['timestamp']?.toString(),  // Keep as date-time string
      // API uses 'competingTxs' field name, not 'doubleSpendTxids'
      doubleSpendTxids: parseStringList(json['competingTxs'] ?? json['doubleSpendTxids']),
      rawTx: json['rawTx'],
      merklePath: parseStringList(json['merklePath']),
      merkleRoot: json['merkleRoot'],
    );
  }
}

/// `miningFee` of an ARC policy: [satoshis] per [bytes].
class ArcFeeAmount {
  final int satoshis;
  final int bytes;

  const ArcFeeAmount({required this.satoshis, required this.bytes});

  /// Satoshis per 1000 bytes.
  double get satoshisPerKb => bytes <= 0 ? 0 : satoshis * 1000 / bytes;

  /// Fee for a transaction of [sizeBytes], rounded up.
  BigInt feeFor(int sizeBytes) =>
      bytes <= 0 ? BigInt.zero : BigInt.from((sizeBytes * satoshis + bytes - 1) ~/ bytes);
}

/// Policy returned by `GET /v1/policy`.
///
/// Shape (ARC OpenAPI spec, bitcoin-sv/arc `pkg/api/arc.yaml`, schemas
/// `PolicyResponse`, `Policy`, `FeeAmount`):
///
/// ```json
/// {
///   "timestamp": "2023-01-01T00:00:00Z",
///   "policy": {
///     "maxscriptsizepolicy": 500000,
///     "maxtxsigopscountspolicy": 4294967295,
///     "maxtxsizepolicy": 10000000,
///     "miningFee": {"satoshis": 1, "bytes": 1000},
///     "standardFormatSupported": true
///   }
/// }
/// ```
///
/// `miningFee`, `maxscriptsizepolicy`, `maxtxsigopscountspolicy` and
/// `maxtxsizepolicy` are required by the spec; a response without a usable
/// `miningFee` is rejected with [ArcException] rather than silently priced
/// with a default. A flat object (the `policy` members at top level) is
/// accepted too.
class ArcPolicyResponse {
  final String? timestamp;
  final int maxScriptSize;
  final int maxTxSigopsCount;
  final int maxTxSize;
  final ArcFeeAmount miningFee;
  final bool standardFormatSupported;

  const ArcPolicyResponse({
    this.timestamp,
    required this.maxScriptSize,
    required this.maxTxSigopsCount,
    required this.maxTxSize,
    required this.miningFee,
    this.standardFormatSupported = false,
  });

  /// Mining fee rate in satoshis per 1000 bytes.
  double get standardFeePerKb => miningFee.satoshisPerKb;

  /// ARC publishes a single mining fee; there is no separate relay fee.
  double get minFeePerKb => miningFee.satoshisPerKb;

  /// ARC publishes a single mining fee; data outputs are priced the same.
  double get dataFeePerKb => miningFee.satoshisPerKb;

  factory ArcPolicyResponse.fromJson(Map<String, dynamic> json) {
    final policy = json['policy'] is Map ? Map<String, dynamic>.from(json['policy'] as Map) : json;

    int? asInt(dynamic v) =>
        v is int ? v : (v is num ? v.toInt() : (v is String ? int.tryParse(v) : null));

    final fee = policy['miningFee'];
    final satoshis = fee is Map ? asInt(fee['satoshis']) : null;
    final bytes = fee is Map ? asInt(fee['bytes']) : null;
    if (satoshis == null || bytes == null || bytes <= 0 || satoshis < 0) {
      throw ArcException('ARC policy has no valid miningFee {satoshis, bytes}: ${jsonEncode(json)}');
    }

    return ArcPolicyResponse(
      timestamp: json['timestamp']?.toString(),
      maxScriptSize: asInt(policy['maxscriptsizepolicy']) ?? 0,
      maxTxSigopsCount: asInt(policy['maxtxsigopscountspolicy']) ?? 0,
      maxTxSize: asInt(policy['maxtxsizepolicy']) ?? 0,
      miningFee: ArcFeeAmount(satoshis: satoshis, bytes: bytes),
      standardFormatSupported: policy['standardFormatSupported'] == true,
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
      // ARC's Health schema names it `reason`.
      message: json['reason'] ?? json['message'],
    );
  }
}

/// Merkle proof of a mined transaction, taken from `GET /v1/tx/{txid}`.
///
/// [merklePath] is `[bumpHex]`: ARC's `merklePath` field, a BRC-74 BUMP.
/// [merkleRoot] is computed from that BUMP (display hex); it is what the
/// proof claims, not something ARC vouches for. Compare it with a local
/// block header before trusting it.
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
    this.requestTimeout = const Duration(seconds: 30),
  }) : _client = client ?? http.Client();

  /// Upper bound on any single HTTP request; see [ArcServiceConfig.requestTimeout].
  final Duration requestTimeout;

  /// Create ARC service from configuration
  factory ArcService.fromConfig(ArcServiceConfig config, {http.Client? client}) {
    return ArcService(
      baseUrl: config.baseUrl,
      apiKey: config.apiKey,
      client: client,
      requestTimeout: config.requestTimeout,
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
    ).timeout(requestTimeout);

    if (response.statusCode == 200 || response.statusCode == 201) {
      return ArcSubmitResponse.fromJson(jsonDecode(response.body));
    } else {
      throw ArcException('Failed to submit transaction: ${response.body}');
    }
  }


  /// Get the status of a transaction
  /// 
  /// [txid] - The transaction ID
  Future<ArcTransactionResponse> getTransaction(String txid) async {
    final url = '$baseUrl/tx/$txid';
    
    final response = await _client.get(
      Uri.parse(url),
      headers: _headers,
    ).timeout(requestTimeout);

    if (response.statusCode == 200) {
      return ArcTransactionResponse.fromJson(jsonDecode(response.body));
    } else {
      throw ArcException('Failed to get transaction: ${response.body}');
    }
  }

  /// Merkle proof of a mined transaction.
  ///
  /// ARC has no proof endpoint; the proof is the `merklePath` (BRC-74 hex)
  /// of `GET /v1/tx/{txid}`, present once the transaction is `MINED`.
  /// Returns null when the transaction is unknown (404), not mined yet, or
  /// the request fails.
  Future<ArcMerkleProofResponse?> getMerkleProof(String txid) async {
    final ArcTransactionResponse status;
    try {
      status = await getTransaction(txid);
    } catch (e) {
      return null;
    }
    return _proofFrom(txid, status);
  }

  ArcMerkleProofResponse? _proofFrom(String txid, ArcTransactionResponse status) {
    final bumpHex = status.merklePathHex;
    if (status.status != ArcTransactionStatus.mined || bumpHex == null) return null;

    final BUMP bump;
    try {
      bump = BUMP.fromHex(bumpHex);
    } catch (_) {
      return null;
    }
    var root = '';
    try {
      root = bump.computeMerkleRootForBlockHeader(
          Uint8List.fromList(hex.decode(txid).reversed.toList()));
    } catch (_) {
      // txid not in the path: leave the root empty; a header check rejects it.
    }
    return ArcMerkleProofResponse(
      txid: txid,
      merklePath: [bumpHex],
      merkleRoot: root,
      blockHeight: status.blockHeight ?? bump.blockHeight,
      blockHash: status.blockHash,
    );
  }

  /// Merkle proofs for several transactions: one `GET /v1/tx/{txid}` each
  /// (ARC has no batch proof endpoint). Transactions without a proof are
  /// omitted.
  Future<List<ArcMerkleProofResponse>> getBatchMerkleProofs(List<String> txids) async {
    final proofs = await Future.wait(txids.map(getMerkleProof));
    return proofs.whereType<ArcMerkleProofResponse>().toList();
  }

  /// Get the policy settings
  Future<ArcPolicyResponse> getPolicy() async {
    final url = '$baseUrl/policy';
    
    final response = await _client.get(
      Uri.parse(url),
      headers: _headers,
    ).timeout(requestTimeout);

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
    ).timeout(requestTimeout);

    if (response.statusCode == 200) {
      return ArcHealthResponse.fromJson(jsonDecode(response.body));
    } else {
      throw ArcException('Failed to get health status: ${response.body}');
    }
  }

  /// Submit multiple transactions in one request: `POST /v1/txs` with a
  /// JSON array of `{rawTx}` (ARC OpenAPI spec). The response is an array
  /// of transaction responses; a `{transactions: [...]}` envelope is
  /// accepted too.
  ///
  /// [rawTxs] - List of raw transactions in hex format
  /// [callbackUrl] - Optional callback URL to receive transaction status updates
  Future<List<ArcSubmitResponse>> submitBatchTransactions(
    List<String> rawTxs,
    {String? callbackUrl}
  ) async {
    final url = '$baseUrl/txs';

    final headers = Map<String, String>.from(_headers);
    if (callbackUrl != null) {
      headers['X-CallbackUrl'] = callbackUrl;
    }

    final response = await _client.post(
      Uri.parse(url),
      headers: headers,
      body: jsonEncode([
        for (final rawTx in rawTxs) {'rawTx': rawTx},
      ]),
    ).timeout(requestTimeout);

    if (response.statusCode == 200 || response.statusCode == 201) {
      final decoded = jsonDecode(response.body);
      final List<dynamic> data = decoded is Map && decoded['transactions'] is List
          ? decoded['transactions'] as List
          : decoded as List;
      return data
          .map((item) => ArcSubmitResponse.fromJson(Map<String, dynamic>.from(item as Map)))
          .toList();
    } else {
      throw ArcException('Failed to submit batch transactions: ${response.body}');
    }
  }

  /// Status of several transactions: one `GET /v1/tx/{txid}` each (ARC has
  /// no batch status endpoint). Throws if any request fails.
  ///
  /// [txids] - List of transaction IDs
  Future<List<ArcTransactionResponse>> getBatchTransactions(List<String> txids) =>
      Future.wait(txids.map(getTransaction));

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
    
    // ARC's miningFee: satoshis per bytes, rounded up
    return policy.miningFee.feeFor(estimatedSize);
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