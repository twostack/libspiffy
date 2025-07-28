import 'dart:async';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:logging/logging.dart';
import 'package:spiffynode/spiffy_node.dart';

import '../storage/wallet_storage.dart';

/// Manages the block header chain for SPV validation
/// 
/// This component:
/// - Stores and validates block headers received from SpiffyNode
/// - Maintains an in-memory cache for recent headers (performance)
/// - Validates merkle proofs against the stored header chain
/// - Handles blockchain reorganizations
/// - Provides the foundation for true SPV security
class BlockHeaderChain {
  final WalletStorage _storage;
  final Logger _logger;
  final bool _skipProofOfWorkValidation;

  // In-memory cache for recent headers (last 2016 blocks for difficulty calculation)
  final Map<String, BlockHeader> _headerCache = {};
  final Map<int, String> _heightToHash = {};
  
  // Chain state
  BlockHeader? _chainTip;
  int _bestHeight = 0;

  // Cache management
  static const int _maxCacheSize = 2016; // ~2 weeks of blocks

  BlockHeaderChain(
    this._storage, {
    Logger? logger,
    bool skipProofOfWorkValidation = false,
  }) : _logger = logger ?? Logger('BlockHeaderChain'),
       _skipProofOfWorkValidation = skipProofOfWorkValidation;

  /// Current chain tip header
  BlockHeader? get chainTip => _chainTip;

  /// Best known block height
  int get bestHeight => _bestHeight;

  /// Number of headers in cache
  int get cacheSize => _headerCache.length;

  /// Initialize the header chain by loading the current tip from storage
  Future<void> initialize() async {
    try {
      _chainTip = await _storage.getChainTip();
      _bestHeight = await _storage.getBestHeight();
      
      _logger.info('Initialized header chain: tip at height $_bestHeight');
      
      // Pre-load recent headers into cache
      if (_bestHeight > 0) {
        await _loadRecentHeadersIntoCache();
      }
    } catch (e) {
      _logger.severe('Failed to initialize header chain: $e');
      rethrow;
    }
  }

  /// Validate and store a new block header
  Future<bool> validateAndStoreHeader(BlockHeader header, int height) async {
    try {
      // Basic validation
      if (!await _validateHeader(header, height)) {
        return false;
      }

      // Store to persistent storage
      await _storage.storeBlockHeader(header, height);

      // Update in-memory state
      final headerHash = header.blockHash().toString();
      _headerCache[headerHash] = header;
      _heightToHash[height] = headerHash;

      // Update chain tip if this is the best height
      if (height >= _bestHeight) {
        _bestHeight = height;
        _chainTip = header;
      }

      // Maintain cache size (keep last N blocks)
      _maintainCacheSize();

      _logger.fine('Stored header at height $height: ${headerHash.substring(0, 16)}...');
      return true;
    } catch (e) {
      _logger.warning('Failed to validate/store header at height $height: $e');
      return false;
    }
  }

  /// Get header by hash
  Future<BlockHeader?> getHeaderByHash(String hash) async {
    // Check cache first
    if (_headerCache.containsKey(hash)) {
      return _headerCache[hash];
    }

    // Load from storage
    try {
      final header = await _storage.getBlockHeaderByHash(hash);
      if (header != null) {
        _headerCache[hash] = header;
      }
      return header;
    } catch (e) {
      _logger.warning('Failed to get header by hash $hash: $e');
      return null;
    }
  }

  /// Get header by height
  Future<BlockHeader?> getHeaderByHeight(int height) async {
    final hash = _heightToHash[height];
    if (hash != null) {
      return getHeaderByHash(hash);
    }

    // Load from storage
    try {
      final header = await _storage.getBlockHeaderByHeight(height);
      if (header != null) {
        final headerHash = header.blockHash().toString();
        _headerCache[headerHash] = header;
        _heightToHash[height] = headerHash;
      }
      return header;
    } catch (e) {
      _logger.warning('Failed to get header by height $height: $e');
      return null;
    }
  }

  /// Get height for a given block hash
  Future<int?> getHeightByHash(String hash) async {
    // Check if we have it in our height mapping
    for (final entry in _heightToHash.entries) {
      if (entry.value == hash) {
        return entry.key;
      }
    }

    // Query storage
    try {
      return await _storage.getHeightByBlockHash(hash);
    } catch (e) {
      _logger.warning('Failed to get height by hash $hash: $e');
      return null;
    }
  }

  /// Validate merkle proof against the header chain
  Future<bool> validateMerkleProof(MerkleProof proof) async {
    try {
      // Get the block header for this proof
      final header = await getHeaderByHash(proof.blockHash);
      if (header == null) {
        _logger.warning('Block header not found for merkle proof: ${proof.blockHash}');
        return false;
      }

      // Reconstruct merkle root from proof
      final computedRoot = _computeMerkleRoot(
        proof.txid,
        proof.merkleProof,
        proof.position,
      );

      // Compare with header's merkle root
      final headerMerkleRoot = header.merkleRoot.toString();
      final isValid = computedRoot == headerMerkleRoot;

      if (isValid) {
        _logger.fine('✅ Merkle proof validated for tx ${proof.txid}');
      } else {
        _logger.warning('❌ Invalid merkle proof for tx ${proof.txid}');
        _logger.fine('  Computed root: $computedRoot');
        _logger.fine('  Header root:   $headerMerkleRoot');
      }

      return isValid;
    } catch (e) {
      _logger.warning('Merkle proof validation failed: $e');
      return false;
    }
  }

  /// Handle blockchain reorganization
  Future<void> handleReorganization(
    List<BlockHeader> orphanedHeaders,
    List<BlockHeader> newHeaders,
  ) async {
    _logger.info('Handling blockchain reorganization: '
        '${orphanedHeaders.length} orphaned, ${newHeaders.length} new');

    try {
      // Remove orphaned headers from cache and mark in storage
      for (final header in orphanedHeaders) {
        final hash = header.blockHash().toString();
        _headerCache.remove(hash);
        await _storage.markHeaderAsOrphaned(hash);
      }

      // Add new headers
      var height = _bestHeight - orphanedHeaders.length + 1;
      for (final header in newHeaders) {
        await validateAndStoreHeader(header, height);
        height++;
      }

      // Update chain tip
      if (newHeaders.isNotEmpty) {
        _chainTip = newHeaders.last;
        _bestHeight = height - 1;
      }

      _logger.info('Reorganization complete: new tip at height $_bestHeight');
    } catch (e) {
      _logger.severe('Failed to handle reorganization: $e');
      rethrow;
    }
  }

  /// Get recent headers for caching/display
  Future<List<BlockHeader>> getRecentHeaders(int count) async {
    try {
      return await _storage.getRecentHeaders(count);
    } catch (e) {
      _logger.warning('Failed to get recent headers: $e');
      return [];
    }
  }

  /// Validate a block header against the previous header and basic rules
  Future<bool> _validateHeader(BlockHeader header, int height) async {
    try {
      // Validate against previous header if we have it
      if (height > 0) {
        final prevHeader = await getHeaderByHeight(height - 1);
        if (prevHeader != null) {
          final prevHash = prevHeader.blockHash().toString();
          final headerPrevHash = header.prevBlock.toString();

          if (prevHash != headerPrevHash) {
            _logger.warning('Header prev block mismatch at height $height');
            _logger.fine('  Expected: $prevHash');
            _logger.fine('  Got:      $headerPrevHash');
            return false;
          }
        }
      }

      // Additional basic validations
      if (header.timestamp.isBefore(DateTime.fromMillisecondsSinceEpoch(0))) {
        _logger.warning('Invalid timestamp in header at height $height');
        return false;
      }

      // Validate header hash meets difficulty target (skip for testing)
      if (!_skipProofOfWorkValidation && !_validateProofOfWork(header)) {
        _logger.warning('Header does not meet difficulty target at height $height');
        return false;
      }

      return true;
    } catch (e) {
      _logger.warning('Header validation failed at height $height: $e');
      return false;
    }
  }

  /// Validate that the header meets the proof-of-work difficulty target
  bool _validateProofOfWork(BlockHeader header) {
    try {
      final blockHash = header.blockHash();
      final target = _bitsToTarget(header.bits);
      
      // Convert block hash to big integer for comparison
      final hashBytes = _hexToBytes(blockHash.toString());
      final hashBigInt = _bytesToBigInt(hashBytes.reversed.toList()); // Little-endian
      
      return hashBigInt <= target;
    } catch (e) {
      _logger.warning('Proof of work validation failed: $e');
      return false;
    }
  }

  /// Convert difficulty bits to target value
  BigInt _bitsToTarget(int bits) {
    final exponent = bits >> 24;
    final mantissa = bits & 0x00ffffff;
    
    if (exponent <= 3) {
      return BigInt.from(mantissa >> (8 * (3 - exponent)));
    } else {
      return BigInt.from(mantissa) << (8 * (exponent - 3));
    }
  }

  /// Compute merkle root from transaction ID and proof
  String _computeMerkleRoot(String txid, List<String> merkleProof, int position) {
    var current = txid;
    var currentPos = position;

    for (final proof in merkleProof) {
      String left, right;
      if (currentPos % 2 == 0) {
        // Current hash is on the left
        left = current;
        right = proof;
      } else {
        // Current hash is on the right
        left = proof;
        right = current;
      }

      // Compute hash of concatenated pair
      current = _hashPair(left, right);
      currentPos = currentPos ~/ 2;
    }

    return current;
  }

  /// Hash a pair of hashes (double SHA256)
  String _hashPair(String left, String right) {
    final leftBytes = _hexToBytes(left);
    final rightBytes = _hexToBytes(right);
    final combined = Uint8List.fromList([...leftBytes, ...rightBytes]);

    // Double SHA256
    final firstHash = sha256.convert(combined);
    final secondHash = sha256.convert(firstHash.bytes);

    return secondHash.toString();
  }

  /// Convert hex string to bytes
  Uint8List _hexToBytes(String hex) {
    final cleanHex = hex.replaceAll('0x', '');
    final bytes = <int>[];
    for (var i = 0; i < cleanHex.length; i += 2) {
      final byte = int.parse(cleanHex.substring(i, i + 2), radix: 16);
      bytes.add(byte);
    }
    return Uint8List.fromList(bytes);
  }

  /// Convert bytes to big integer
  BigInt _bytesToBigInt(List<int> bytes) {
    var result = BigInt.zero;
    for (var i = 0; i < bytes.length; i++) {
      result += BigInt.from(bytes[i]) << (8 * i);
    }
    return result;
  }

  /// Load recent headers into cache for performance
  Future<void> _loadRecentHeadersIntoCache() async {
    final cacheCount = _maxCacheSize ~/ 2; // Load half the cache size
    final recentHeaders = await _storage.getRecentHeaders(cacheCount);

    for (final header in recentHeaders) {
      final hash = header.blockHash().toString();
      _headerCache[hash] = header;
      
      // We'd need to also load the height mapping, but for now skip it
      // as it would require additional storage queries
    }
    
    _logger.fine('Loaded ${recentHeaders.length} recent headers into cache');
  }

  /// Maintain cache size by removing oldest entries
  void _maintainCacheSize() {
    if (_headerCache.length > _maxCacheSize) {
      // Remove oldest entries (simple FIFO for now)
      final excessCount = _headerCache.length - _maxCacheSize;
      final hashesToRemove = _headerCache.keys.take(excessCount).toList();
      
      for (final hash in hashesToRemove) {
        _headerCache.remove(hash);
      }
      
      // Clean up height mapping for removed hashes
      _heightToHash.removeWhere((height, hash) => hashesToRemove.contains(hash));
    }
  }
} 