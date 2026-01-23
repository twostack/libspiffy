import 'dart:async';
import 'dart:typed_data';
import 'dart:collection';

import 'package:spiffynode/src/wire/block_header.dart';
import 'package:spiffynode/src/wire/messages/msg_headers.dart';
import 'package:spiffynode/src/spv/chain_tip_tracker.dart';
import 'package:spiffynode/src/chaincfg/hash.dart';

/// Service for managing block headers in SPV clients
/// Provides merkle root verification for BEEF/BUMP validation
class BlockHeaderService {
  final ChainTipTracker chainTipTracker;
  
  // Block header storage (height -> header)
  final Map<int, StoredBlockHeader> _headers = {};
  
  // Hash to height lookup for fast access
  final Map<Hash, int> _hashToHeight = {};
  
  // Reorganization handling
  final Map<int, List<StoredBlockHeader>> _orphanedHeaders = {};
  
  // Event streams
  final StreamController<BlockHeaderEvent> _eventController = 
      StreamController<BlockHeaderEvent>.broadcast();
  
  // Configuration
  final BlockHeaderServiceConfig config;
  
  // Statistics
  int _totalHeadersReceived = 0;
  int _reorganizationsHandled = 0;
  DateTime? _lastReorgAt;
  
  late StreamSubscription<ChainTipEvent> _chainTipSubscription;

  BlockHeaderService({
    required this.chainTipTracker,
    BlockHeaderServiceConfig? config,
  }) : config = config ?? const BlockHeaderServiceConfig() {
    _initializeChainTipMonitoring();
  }

  /// Current number of stored headers
  int get headerCount => _headers.length;
  
  /// Current chain height from stored headers
  int get chainHeight => _headers.keys.fold<int>(0, (max, height) => height > max ? height : max);
  
  /// Events when headers are processed
  Stream<BlockHeaderEvent> get headerEvents => _eventController.stream;
  
  /// Statistics about header service
  Map<String, dynamic> get statistics => {
    'headerCount': headerCount,
    'chainHeight': chainHeight,
    'totalHeadersReceived': _totalHeadersReceived,
    'reorganizationsHandled': _reorganizationsHandled,
    'lastReorganizationAt': _lastReorgAt?.toIso8601String(),
    'orphanedHeaders': _orphanedHeaders.length,
    'networkHeight': chainTipTracker.networkHeight,
    'syncProgress': chainHeight / (chainTipTracker.networkHeight == 0 ? 1 : chainTipTracker.networkHeight),
  };

  /// Initialize chain tip monitoring for reorganization detection
  void _initializeChainTipMonitoring() {
    _chainTipSubscription = chainTipTracker.tipEvents.listen((event) {
      _handleChainTipEvent(event);
    });
  }

  /// Handle chain tip events for reorganization management
  Future<void> _handleChainTipEvent(ChainTipEvent event) async {
    switch (event.type) {
      case ChainTipEventType.reorganization:
        await _handleChainReorganization(event);
        break;
        
      case ChainTipEventType.heightIncrease:
        // Check if we need to request more headers
        if (chainHeight < event.newTip.height - config.headerLookAhead) {
          _fireEvent(BlockHeaderEvent(
            type: BlockHeaderEventType.syncNeeded,
            description: 'Need to sync headers up to height ${event.newTip.height}',
          ));
        }
        break;
        
      default:
        // Handle other events if needed
        break;
    }
  }

  /// Process headers received from the network
  Future<void> processHeaders(MsgHeaders headersMessage, String peerId) async {
    if (headersMessage.isEmpty) return;
    
    final newHeaders = <StoredBlockHeader>[];
    final orphanedHeaders = <StoredBlockHeader>[];
    
    for (final header in headersMessage.headers) {
      _totalHeadersReceived++;
      
      final blockHash = header.blockHash();
      final height = _calculateHeight(header);
      
      if (height == null) {
        // Can't determine height - might be orphaned
        final stored = StoredBlockHeader(
          header: header,
          height: -1, // Unknown height
          receivedAt: DateTime.now(),
          receivedFrom: peerId,
        );
        orphanedHeaders.add(stored);
        continue;
      }
      
      // Check for potential reorganization
      final existingHeader = _headers[height];
      if (existingHeader != null && existingHeader.header.blockHash() != blockHash) {
        await _handlePotentialReorganization(height, existingHeader, header, peerId);
      } else {
        // Store the new header
        final stored = StoredBlockHeader(
          header: header,
          height: height,
          receivedAt: DateTime.now(),
          receivedFrom: peerId,
        );
        
        _headers[height] = stored;
        _hashToHeight[blockHash] = height;
        newHeaders.add(stored);
      }
    }
    
    // Store orphaned headers for later processing
    if (orphanedHeaders.isNotEmpty) {
      for (final orphan in orphanedHeaders) {
        final orphanHeight = orphan.height == -1 ? 0 : orphan.height;
        _orphanedHeaders.putIfAbsent(orphanHeight, () => []).add(orphan);
      }
    }
    
    // Fire events for processed headers
    if (newHeaders.isNotEmpty) {
      _fireEvent(BlockHeaderEvent(
        type: BlockHeaderEventType.headersReceived,
        description: 'Received ${newHeaders.length} new headers from $peerId',
        headers: newHeaders,
      ));
    }
    
    if (orphanedHeaders.isNotEmpty) {
      _fireEvent(BlockHeaderEvent(
        type: BlockHeaderEventType.orphanHeaders,
        description: 'Received ${orphanedHeaders.length} orphaned headers from $peerId',
        headers: orphanedHeaders,
      ));
    }
  }

  /// Get merkle root for a specific block height
  String? getMerkleRoot(int blockHeight) {
    final stored = _headers[blockHeight];
    if (stored == null) return null;
    
    return stored.header.merkleRoot.toString();
  }

  /// Get block header for a specific height
  BlockHeader? getHeader(int blockHeight) {
    return _headers[blockHeight]?.header;
  }

  /// Get block header by hash
  BlockHeader? getHeaderByHash(Hash blockHash) {
    final height = _hashToHeight[blockHash];
    if (height == null) return null;
    
    return _headers[height]?.header;
  }

  /// Get headers in a range
  List<BlockHeader> getHeadersInRange(int startHeight, int endHeight) {
    final headers = <BlockHeader>[];
    
    for (int height = startHeight; height <= endHeight; height++) {
      final header = _headers[height]?.header;
      if (header != null) {
        headers.add(header);
      }
    }
    
    return headers;
  }

  /// Validate a chain of headers
  bool validateHeaderChain(List<BlockHeader> headers) {
    if (headers.isEmpty) return true;
    
    for (int i = 1; i < headers.length; i++) {
      final current = headers[i];
      final previous = headers[i - 1];
      
      // Check that current header's prevBlock matches previous header's hash
      if (current.prevBlock != previous.blockHash()) {
        return false;
      }
      
      // Additional validation could include:
      // - Timestamp checks
      // - Difficulty target validation
      // - Proof of work validation
    }
    
    return true;
  }

  /// Check if we have all headers up to a specific height
  bool hasContinuousChain(int toHeight) {
    for (int height = 1; height <= toHeight; height++) {
      if (!_headers.containsKey(height)) {
        return false;
      }
    }
    return true;
  }

  /// Get missing header heights in a range
  List<int> getMissingHeights(int startHeight, int endHeight) {
    final missing = <int>[];
    
    for (int height = startHeight; height <= endHeight; height++) {
      if (!_headers.containsKey(height)) {
        missing.add(height);
      }
    }
    
    return missing;
  }

  /// Calculate height for a header based on existing chain
  int? _calculateHeight(BlockHeader header) {
    // If this is the genesis block
    if (header.prevBlock == Hash.zero()) {
      return 0;
    }
    
    // Look up the previous block's height
    final prevHeight = _hashToHeight[header.prevBlock];
    if (prevHeight != null) {
      return prevHeight + 1;
    }
    
    // Can't determine height - might be out of order
    return null;
  }

  /// Handle potential reorganization
  Future<void> _handlePotentialReorganization(
    int height,
    StoredBlockHeader existingHeader,
    BlockHeader newHeader,
    String peerId,
  ) async {
    
    // Move existing header to orphaned list
    _orphanedHeaders.putIfAbsent(height, () => []).add(existingHeader);
    
    // Store new header
    final newStored = StoredBlockHeader(
      header: newHeader,
      height: height,
      receivedAt: DateTime.now(),
      receivedFrom: peerId,
    );
    
    _headers[height] = newStored;
    _hashToHeight.remove(existingHeader.header.blockHash());
    _hashToHeight[newHeader.blockHash()] = height;
    
    _reorganizationsHandled++;
    _lastReorgAt = DateTime.now();
    
    _fireEvent(BlockHeaderEvent(
      type: BlockHeaderEventType.reorganization,
      description: 'Header reorganization at height $height',
      headers: [newStored],
      oldHeaders: [existingHeader],
    ));
  }

  /// Handle chain reorganization from ChainTipTracker
  Future<void> _handleChainReorganization(ChainTipEvent event) async {
    
    // If the new tip is lower, we might need to rollback some headers
    if (event.oldTip != null && event.newTip.height < event.oldTip!.height) {
      final rollbackHeaders = <StoredBlockHeader>[];
      
      // Move headers above the new tip height to orphaned list
      for (int height = event.newTip.height + 1; height <= event.oldTip!.height; height++) {
        final stored = _headers.remove(height);
        if (stored != null) {
          _hashToHeight.remove(stored.header.blockHash());
          _orphanedHeaders.putIfAbsent(height, () => []).add(stored);
          rollbackHeaders.add(stored);
        }
      }
      
      if (rollbackHeaders.isNotEmpty) {
        _fireEvent(BlockHeaderEvent(
          type: BlockHeaderEventType.rollback,
          description: 'Rolled back ${rollbackHeaders.length} headers due to reorganization',
          oldHeaders: rollbackHeaders,
        ));
      }
    }
  }

  /// Clean up old orphaned headers
  void cleanupOrphanedHeaders() {
    final cutoff = DateTime.now().subtract(config.orphanTimeout);
    final heightsToRemove = <int>[];
    
    for (final entry in _orphanedHeaders.entries) {
      final height = entry.key;
      final orphans = entry.value;
      
      // Remove old orphaned headers
      orphans.removeWhere((orphan) => orphan.receivedAt.isBefore(cutoff));
      
      if (orphans.isEmpty) {
        heightsToRemove.add(height);
      }
    }
    
    for (final height in heightsToRemove) {
      _orphanedHeaders.remove(height);
    }
  }

  /// Fire a block header event
  void _fireEvent(BlockHeaderEvent event) {
    _eventController.add(event);
  }

  /// Shutdown the service
  Future<void> shutdown() async {
    await _chainTipSubscription.cancel();
    await _eventController.close();
    
    _headers.clear();
    _hashToHeight.clear();
    _orphanedHeaders.clear();
  }
}

/// Stored block header with metadata
class StoredBlockHeader {
  final BlockHeader header;
  final int height;
  final DateTime receivedAt;
  final String receivedFrom;

  StoredBlockHeader({
    required this.header,
    required this.height,
    required this.receivedAt,
    required this.receivedFrom,
  });

  @override
  String toString() => 'StoredBlockHeader(height: $height, hash: ${header.blockHash().toString().substring(0, 8)}..., from: $receivedFrom)';
}

/// Block header event types
enum BlockHeaderEventType {
  headersReceived,
  orphanHeaders,
  reorganization,
  rollback,
  syncNeeded,
}

/// Block header event
class BlockHeaderEvent {
  final BlockHeaderEventType type;
  final String description;
  final List<StoredBlockHeader>? headers;
  final List<StoredBlockHeader>? oldHeaders;

  BlockHeaderEvent({
    required this.type,
    required this.description,
    this.headers,
    this.oldHeaders,
  });

  @override
  String toString() => 'BlockHeaderEvent($type: $description)';
}

/// Configuration for block header service
class BlockHeaderServiceConfig {
  /// How far ahead to keep requesting headers
  final int headerLookAhead;
  
  /// How long to keep orphaned headers
  final Duration orphanTimeout;
  
  /// Maximum number of headers to store
  final int maxHeaders;

  const BlockHeaderServiceConfig({
    this.headerLookAhead = 2016, // ~2 weeks of blocks
    this.orphanTimeout = const Duration(hours: 24),
    this.maxHeaders = 100000, // ~2 years of blocks
  });
}

/// Exception thrown by block header service
class BlockHeaderException implements Exception {
  final String message;
  
  BlockHeaderException(this.message);
  
  @override
  String toString() => 'BlockHeaderException: $message';
} 