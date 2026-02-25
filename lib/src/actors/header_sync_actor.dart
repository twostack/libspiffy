import 'dart:async';
import 'package:dactor/dactor.dart';
import 'package:libspiffy/src/actors/spv_messages.dart';
import 'package:logging/logging.dart';
import 'package:spiffynode/spiffy_node.dart';

import '../spv/block_header_chain.dart';

// =============================================================================
// HEADER SYNC ACTOR MESSAGES
// =============================================================================

/// Message to set the SpiffyNode bridge reference after P2P initialization
class SetSpiffyNodeBridgeMessage implements Message {
  final dynamic bridge;

  SetSpiffyNodeBridgeMessage(this.bridge);

  @override
  String get correlationId => 'set-bridge-${DateTime.now().millisecondsSinceEpoch}';
  @override
  Map<String, dynamic> get metadata => {};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// Message to set the PeerManager reference after P2P initialization
class SetPeerManagerMessage implements Message {
  final dynamic peerManager;

  SetPeerManagerMessage(this.peerManager);

  @override
  String get correlationId => 'set-peer-manager-${DateTime.now().millisecondsSinceEpoch}';
  @override
  Map<String, dynamic> get metadata => {};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// Message to initiate header sync after P2P setup is complete
class InitiateHeaderSyncMessage implements Message {
  final int? startHeight;

  InitiateHeaderSyncMessage({this.startHeight});

  @override
  String get correlationId => 'initiate-sync-${DateTime.now().millisecondsSinceEpoch}';
  @override
  Map<String, dynamic> get metadata => {};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// Actor responsible for managing block header synchronization and storage
/// 
/// This actor:
/// - Manages BlockHeaderChain for header validation and storage
/// - Receives block header events from SpiffyNode integration
/// - Sends getHeaders requests to peers to fetch headers
/// - Notifies SPVActor and other components of header updates
/// - Handles blockchain reorganizations
/// - Provides the bridge between SpiffyNode's network layer and LibSpiffy's SPV validation
class HeaderSyncActor extends Actor {
  final BlockHeaderChain _headerChain;
  final ActorRef? _spvActor;
  final Logger _logger;
  
  // SpiffyNode bridge reference for peer information
  dynamic _spiffyNodeBridge; // Will be set after bridge connection
  dynamic _peerManager; // PeerManager for sending getHeaders requests
  
  // Integration state
  bool _isInitialized = false;
  int _lastProcessedHeight = 0;
  int? _startHeight; // Configured starting height for sync
  
  // Statistics
  int _headersProcessed = 0;
  int _reorgsHandled = 0;
  DateTime? _lastHeaderAt;
  
  // Pending messages queue (for messages received before initialization)
  final List<BlockHeadersReceivedMessage> _pendingMessages = [];
  
  // Sync state guard to prevent concurrent header requests
  bool _syncInProgress = false;

  HeaderSyncActor({
    required BlockHeaderChain headerChain,
    ActorRef? spvActor,
    dynamic spiffyNodeBridge,
    dynamic peerManager,
    int? startHeight,
    Logger? logger,
  }) : _headerChain = headerChain,
       _spvActor = spvActor,
       _spiffyNodeBridge = spiffyNodeBridge,
       _peerManager = peerManager,
       _startHeight = startHeight,
       _logger = logger ?? Logger('HeaderSyncActor');

  /// Initiate header sync after P2P setup is complete
  /// Called internally via InitiateHeaderSyncMessage
  void _initiateSyncAfterP2PSetup() {
    if (!_isInitialized) {
      _logger.warning('Cannot initiate sync: HeaderSyncActor not initialized yet');
      return;
    }
    
    if (_peerManager == null) {
      _logger.warning('Cannot initiate sync: PeerManager not set');
      return;
    }
    
    _logger.info('P2P setup complete, initiating header sync...');
    _triggerHeaderSync();
  }

  @override
  void preStart() {
    _logger.info('HeaderSyncActor starting - initializing block header management');
    _initializeState();
  }

  @override
  Future<void> onMessage(dynamic message) async {
    try {
      if (message is SetSpiffyNodeBridgeMessage) {
        _spiffyNodeBridge = message.bridge;
        _logger.info('SpiffyNode bridge set via message');
      } else if (message is SetPeerManagerMessage) {
        _peerManager = message.peerManager;
        _logger.info('PeerManager set via message');
      } else if (message is InitiateHeaderSyncMessage) {
        _startHeight = message.startHeight;
        _initiateSyncAfterP2PSetup();
      } else if (message is BlockHeadersReceivedMessage) {
        await _handleBlockHeadersReceived(message);
      } else if (message is ChainTipEventMessage) {
        await _handleChainTipEvent(message);
      } else if (message is RequestHeaderSyncMessage) {
        await _handleHeaderSyncRequest(message);
      } else if (message is RequestSpecificHeaderMessage) {
        await _handleSpecificHeaderRequest(message);
      } else if (message is GetSPVStatusMessage) {
        await _handleGetSPVStatus(message);
      } else {
        _logger.warning('HeaderSyncActor received unknown message: ${message.runtimeType}');
      }
    } catch (e, stackTrace) {
      _logger.severe('Error in HeaderSyncActor: $e\n$stackTrace');
      
      // Send error response if sender expects one
      if (context.sender != null) {
        _sendErrorResponse(message, e.toString());
      }
    }
  }

  /// Initialize the actor state (BlockHeaderChain already initialized by system)
  void _initializeState() {
    // BlockHeaderChain is already initialized by LibSpiffyActorSystem
    _isInitialized = true;
    _lastProcessedHeight = _headerChain.bestHeight;
    
    _logger.info('HeaderSyncActor initialized successfully');
    _logger.info('Current chain state: height ${_headerChain.bestHeight}');
    
    // Process any pending messages that arrived before initialization
    if (_pendingMessages.isNotEmpty) {
      _logger.info('Processing ${_pendingMessages.length} queued messages');
      for (final msg in _pendingMessages) {
        _handleBlockHeadersReceived(msg);
      }
      _pendingMessages.clear();
    }
    
    // Notify SPVActor that header chain is ready
    if (_spvActor != null) {
      _spvActor.tell(SPVStatusMessage(
        currentHeight: _headerChain.bestHeight,
        networkHeight: _headerChain.bestHeight, // Assume synced initially
        isSynced: true,
        headersCached: _headerChain.cacheSize,
        merkleProofsStored: 0, // Will be queried from storage when needed
        lastHeaderUpdate: DateTime.now(),
        connectedPeers: _spiffyNodeBridge?.getConnectedPeerIds() ?? [],
        isHealthy: true,
        statusMessage: 'Header chain initialized and ready for SPV validation',
      ) as dynamic);
    }
    
    // NOTE: Do NOT trigger sync here - PeerManager is set after spawn
    // Sync will be triggered by initiateSyncAfterP2PSetup() call from system
  }
  
  /// Request headers from connected peers
  Future<void> _triggerHeaderSync() async {
    try {
      if (_syncInProgress) {
        _logger.fine('Header sync already in progress, skipping duplicate request');
        return;
      }
      
      if (_peerManager == null) {
        _logger.warning('Cannot trigger header sync: no peer manager available');
        return;
      }
      
      final currentHeight = _headerChain.bestHeight;
      _logger.info('Triggering header sync from height $currentHeight...');
      
      // Mark sync as in progress
      _syncInProgress = true;
      
      final peers = _peerManager.getPeers();
      if (peers.isEmpty) {
        _logger.warning('No peers available for header sync');
        return;
      }
      
      // Build block locator hashes for efficient sync
      // Use current chain tip to request headers from where we left off
      final blockLocators = <Hash>[];
      
      if (currentHeight > 0) {
        // Get the header at our current tip to use as locator
        final tipHeader = await _headerChain.getHeaderByHeight(currentHeight);
        if (tipHeader != null) {
          // SpiffyNode BlockHeader uses blockHash() method
          final tipHash = tipHeader.blockHash();
          blockLocators.add(tipHash);
          _logger.info('Using tip hash as locator: ${tipHash.toString()} at height $currentHeight');
        } else {
          _logger.warning('Could not get header at height $currentHeight, using zero hash');
          blockLocators.add(Hash.zero());
        }
      } else {
        // Starting from genesis
        blockLocators.add(Hash.zero());
      }
      
      final getHeadersMsg = MsgGetHeaders(
        protocolVersion: 70016,
        blockLocatorHashes: blockLocators,
        hashStop: Hash.zero(), // No stop hash - get all available
      );
      
      // Send to first healthy peer (others will respond too, but we only need one)
      var sentCount = 0;
      for (final peer in peers) {
        try {
          peer.writeMessage(getHeadersMsg);
          sentCount++;
          _logger.info('Sent getHeaders request to ${peer.toString()} from height $currentHeight');
          break; // Only send to one peer to avoid duplicate responses
        } catch (e) {
          _logger.warning('Failed to send getHeaders to ${peer.toString()}: $e');
        }
      }
      
      if (sentCount > 0) {
        _logger.info('✓ Requested next batch of headers from height $currentHeight');
      } else {
        _logger.warning('❌ Failed to send getHeaders to any peer');
        _syncInProgress = false; // Clear flag if no request was sent
      }
      
    } catch (e, stackTrace) {
      _logger.severe('Error triggering header sync: $e\n$stackTrace');
      _syncInProgress = false; // Clear flag on error
    }
  }

  /// Handle incoming block headers from SpiffyNode
  Future<void> _handleBlockHeadersReceived(BlockHeadersReceivedMessage msg) async {
    if (!_isInitialized) {
      _logger.warning('HeaderSyncActor not initialized, queuing headers from ${msg.peerId}');
      _pendingMessages.add(msg);
      return;
    }

    _logger.info('Processing ${msg.headers.length} headers from peer ${msg.peerId}');
    
    var successCount = 0;
    var failureCount = 0;
    var currentHeight = msg.startHeight;

    try {
      for (final header in msg.headers) {
        final success = await _headerChain.validateAndStoreHeader(header, currentHeight);
        
        if (success) {
          successCount++;
          _lastProcessedHeight = currentHeight;
          _lastHeaderAt = DateTime.now();
        } else {
          failureCount++;
          _logger.warning('Failed to validate header at height $currentHeight');
        }
        
        currentHeight++;
      }
      
      _headersProcessed += successCount;
      
      _logger.info('Header processing complete: $successCount stored, $failureCount failed');
      _logger.info('Current height: $_lastProcessedHeight');
      
      // Clear sync-in-progress flag BEFORE potentially triggering next batch
      _syncInProgress = false;
      
      // Check if we received a full batch (2000 = protocol limit = more headers available)
      if (successCount >= 2000) {
        _logger.info('📡 Received full batch (2000 headers), requesting more...');
        _triggerHeaderSync(); // Request next batch automatically
      } else {
        _logger.info('✅ Sync complete: received ${successCount} headers (less than 2000)');
      }
      
      // Notify SPVActor of new headers (using the last header stored)
      if (_spvActor != null && successCount > 0 && msg.headers.isNotEmpty) {
        _spvActor.tell(BlockHeaderStoredMessage(
          header: msg.headers.last,
          height: _lastProcessedHeight,
          isReorg: msg.isReorganization,
        ) as dynamic);
      }
      
      // Send response to sender
      if (context.sender != null) {
        context.sender!.tell(BlockHeadersProcessedMessage(
          processed: successCount,
          failed: failureCount,
          currentHeight: _lastProcessedHeight,
        ) as dynamic);
      }
      
    } catch (e) {
      _logger.severe('Error processing headers from ${msg.peerId}: $e');
      _syncInProgress = false; // Clear flag on error
      
      if (context.sender != null) {
        context.sender!.tell(SPVErrorMessage(
          operation: 'process_headers',
          error: e.toString(),
        ) as dynamic);
      }
    }
  }

  /// Handle chain tip events from SpiffyNode
  Future<void> _handleChainTipEvent(ChainTipEventMessage msg) async {
    if (!_isInitialized) {
      _logger.warning('HeaderSyncActor not initialized, ignoring chain tip event');
      return;
    }

    _logger.info('Processing chain tip event: ${msg.eventType}');
    
    try {
      // Handle reorganization
      if (msg.isReorganization) {
        await _handleReorganization(msg);
      }
      
      // Check if we're behind and need to catch up
      final behindBy = msg.newTip.height - _lastProcessedHeight;
      if (behindBy > 100) {
        // Significantly behind - trigger catch-up sync
        _logger.info('⚠️  Behind by $behindBy blocks (${msg.newTip.height} > $_lastProcessedHeight), triggering catch-up sync...');
        _triggerHeaderSync();
      } else if (behindBy > 0) {
        _logger.info('Slightly behind by $behindBy blocks, will catch up naturally');
      }
      
      // Notify SPVActor of chain tip change
      if (_spvActor != null) {
        _spvActor.tell(msg as dynamic); // Forward the message
      }
      
    } catch (e) {
      _logger.severe('Error handling chain tip event: $e');
    }
  }

  /// Handle blockchain reorganization
  Future<void> _handleReorganization(ChainTipEventMessage msg) async {
    _logger.warning('Handling blockchain reorganization: ${msg.description}');
    
    try {
      // Use BlockHeaderChain's reorganization handling
      // Note: ChainTipEventMessage doesn't contain actual headers, only heights
      await _headerChain.handleReorganization(
        [], // orphanedHeaders - would need from SpiffyNode 
        [], // newHeaders - would need from SpiffyNode
      );
      
      _reorgsHandled++;
      
      _logger.info('Reorganization handled successfully');
      
    } catch (e) {
      _logger.severe('Failed to handle reorganization: $e');
      rethrow;
    }
  }

  /// Handle header sync requests
  Future<void> _handleHeaderSyncRequest(RequestHeaderSyncMessage msg) async {
    if (!_isInitialized) {
      context.sender?.tell(SPVErrorMessage(
        operation: 'header_sync_request',
        error: 'HeaderSyncActor not initialized',
      ) as dynamic);
      return;
    }

    _logger.info('Processing header sync request from height ${msg.fromHeight}');
    
    try {
      final currentHeight = _headerChain.bestHeight;
      final requestedHeight = msg.fromHeight ?? 0;
      
      // Trigger header sync to fetch any missing headers
      _triggerHeaderSync();
      
      context.sender?.tell(HeaderSyncStatusMessage(
        requestedHeight: requestedHeight,
        currentHeight: currentHeight,
        isUpToDate: currentHeight >= requestedHeight,
        message: currentHeight >= requestedHeight 
          ? 'Headers are up to date'
          : 'Headers needed from height $requestedHeight',
      ) as dynamic);
      
    } catch (e) {
      _logger.severe('Error handling header sync request: $e');
      
      context.sender?.tell(SPVErrorMessage(
        operation: 'header_sync_request',
        error: e.toString(),
      ) as dynamic);
    }
  }

  /// Handle SPV status requests
  Future<void> _handleGetSPVStatus(GetSPVStatusMessage msg) async {
    try {
      final status = SPVStatusMessage(
        currentHeight: _isInitialized ? _headerChain.bestHeight : 0,
        networkHeight: _isInitialized ? _headerChain.bestHeight : 0, // Assume synced
        isSynced: _isInitialized,
        headersCached: _isInitialized ? _headerChain.cacheSize : 0,
        merkleProofsStored: 0, // Will be queried from storage when needed
        lastHeaderUpdate: _lastHeaderAt ?? DateTime.now(),
        connectedPeers: _spiffyNodeBridge?.getConnectedPeerIds() ?? [],
        isHealthy: _isInitialized,
        statusMessage: _isInitialized 
          ? 'Header sync active and ready'
          : 'Header sync initializing',
      );
      
      context.sender?.tell(status as dynamic);
      
    } catch (e) {
      _logger.severe('Error getting SPV status: $e');
      
      context.sender?.tell(SPVErrorMessage(
        operation: 'get_spv_status',
        error: e.toString(),
      ) as dynamic);
    }
  }

  /// Handle request for a specific block header by height (opportunistic fetching)
  /// 
  /// This enables SPV validation to succeed even when the counterparty references
  /// block headers we haven't synced yet. The method will:
  /// 1. Check if header already exists locally
  /// 2. If not, trigger P2P sync to fetch missing headers
  /// 3. Wait for the header to arrive (with timeout)
  /// 4. Return the header to the requesting actor
  Future<void> _handleSpecificHeaderRequest(RequestSpecificHeaderMessage msg) async {
    _logger.info('📡 Received request for specific block header at height ${msg.blockHeight}');
    
    try {
      // Check if we already have this header
      final existingHeader = await _headerChain.getHeaderByHeight(msg.blockHeight);
      
      if (existingHeader != null) {
        _logger.info('✅ Header at height ${msg.blockHeight} already available locally');
        context.sender?.tell(SpecificHeaderResponseMessage(
          blockHeight: msg.blockHeight,
          header: existingHeader,
          success: true,
          correlationId: msg.correlationId,
        ));
        return;
      }
      
      // Check if we have P2P connectivity
      if (_peerManager == null) {
        throw Exception('PeerManager not available for header fetch');
      }
      
      final peers = _peerManager.getPeers();
      if (peers.isEmpty) {
        throw Exception('No peers available for header fetch');
      }
      
      // Determine the range to fetch
      final currentHeight = _headerChain.bestHeight;
      
      if (msg.blockHeight <= currentHeight) {
        // We should have this header but don't - database issue?
        throw Exception('Header at height ${msg.blockHeight} should exist (current height: $currentHeight) but not found in storage');
      }
      
      _logger.info('⚠️  Requested height ${msg.blockHeight} is ahead of current height $currentHeight');
      _logger.info('📡 Triggering header sync to fetch missing headers...');
      
      // Build block locator starting from current tip
      final blockLocators = <Hash>[];
      final tipHeader = await _headerChain.getHeaderByHeight(currentHeight);
      if (tipHeader != null) {
        blockLocators.add(tipHeader.blockHash());
      } else {
        blockLocators.add(Hash.zero());
      }
      
      // Send getHeaders request
      final getHeadersMsg = MsgGetHeaders(
        protocolVersion: 70016,
        blockLocatorHashes: blockLocators,
        hashStop: Hash.zero(),
      );
      
      // Send to first available peer
      var sent = false;
      for (final peer in peers) {
        try {
          await peer.writeMessage(getHeadersMsg);
          _logger.info('✉️  Sent getHeaders request to peer ${peer.toString()}');
          sent = true;
          break;
        } catch (e) {
          _logger.warning('Failed to send getHeaders to peer: $e');
        }
      }
      
      if (!sent) {
        throw Exception('Failed to send getHeaders request to any peer');
      }
      
      // Wait for headers to arrive (with timeout)
      // Poll for the header with exponential backoff
      final startTime = DateTime.now();
      var pollInterval = 500; // Start with 500ms
      const maxPollInterval = 2000; // Max 2 seconds between polls
      
      while (DateTime.now().difference(startTime) < msg.timeout) {
        await Future.delayed(Duration(milliseconds: pollInterval));
        
        final header = await _headerChain.getHeaderByHeight(msg.blockHeight);
        if (header != null) {
          _logger.info('✅ Successfully fetched header at height ${msg.blockHeight}');
          
          context.sender?.tell(SpecificHeaderResponseMessage(
            blockHeight: msg.blockHeight,
            header: header,
            success: true,
            correlationId: msg.correlationId,
          ));
          return;
        }
        
        // Exponential backoff
        pollInterval = (pollInterval * 1.5).toInt().clamp(500, maxPollInterval);
      }
      
      // Timeout reached
      throw Exception('Timeout waiting for header at height ${msg.blockHeight} after ${msg.timeout.inSeconds}s');
      
    } catch (e) {
      _logger.severe('❌ Failed to fetch specific header at height ${msg.blockHeight}: $e');
      
      context.sender?.tell(SpecificHeaderResponseMessage(
        blockHeight: msg.blockHeight,
        success: false,
        error: e.toString(),
        correlationId: msg.correlationId,
      ));
    }
  }

  /// Send error response based on message type
  void _sendErrorResponse(dynamic message, String error) {
    switch (message.runtimeType) {
      case BlockHeadersReceivedMessage _:
        context.sender?.tell(SPVErrorMessage(
          operation: 'process_headers',
          error: error,
        ) as dynamic);
        break;
      case RequestHeaderSyncMessage _:
        context.sender?.tell(SPVErrorMessage(
          operation: 'header_sync_request',
          error: error,
        ) as dynamic);
        break;
      default:
        context.sender?.tell(SPVErrorMessage(
          operation: 'unknown',
          error: error,
        ) as dynamic);
    }
  }

  @override
  void postStop() {
    _logger.info('HeaderSyncActor stopped');
  }

  /// Get current header chain status
  Map<String, dynamic> get statistics => {
    'initialized': _isInitialized,
    'currentHeight': _isInitialized ? _headerChain.bestHeight : 0,
    'headersProcessed': _headersProcessed,
    'reorgsHandled': _reorgsHandled,
    'lastProcessedHeight': _lastProcessedHeight,
    'lastHeaderAt': _lastHeaderAt?.toIso8601String(),
  };
}

/// Message for headers processed response
class BlockHeadersProcessedMessage implements SPVMessage, Message {
  final int processed;
  final int failed;
  final int currentHeight;
  final String _correlationId;
  final ActorRef? _replyTo;
  final Map<String, dynamic> _metadata;

  BlockHeadersProcessedMessage({
    required this.processed,
    required this.failed,
    required this.currentHeight,
    String? correlationId,
    ActorRef? replyTo,
    Map<String, dynamic>? metadata,
  }) : _correlationId = correlationId ?? 'headers_processed_${DateTime.now().millisecondsSinceEpoch}',
       _replyTo = replyTo,
       _metadata = metadata ?? {};

  @override
  String get correlationId => _correlationId;

  @override
  ActorRef? get replyTo => _replyTo;

  @override
  DateTime get timestamp => DateTime.now();

  @override
  Map<String, dynamic> get metadata => _metadata;

  @override
  String toString() => 'BlockHeadersProcessedMessage(processed: $processed, '
      'failed: $failed, currentHeight: $currentHeight)';
}

/// Message for header sync status
class HeaderSyncStatusMessage implements SPVMessage, Message {
  final int requestedHeight;
  final int currentHeight;
  final bool isUpToDate;
  final String message;
  final String _correlationId;
  final ActorRef? _replyTo;
  final Map<String, dynamic> _metadata;

  HeaderSyncStatusMessage({
    required this.requestedHeight,
    required this.currentHeight,
    required this.isUpToDate,
    required this.message,
    String? correlationId,
    ActorRef? replyTo,
    Map<String, dynamic>? metadata,
  }) : _correlationId = correlationId ?? 'sync_status_${DateTime.now().millisecondsSinceEpoch}',
       _replyTo = replyTo,
       _metadata = metadata ?? {};

  @override
  String get correlationId => _correlationId;

  @override
  ActorRef? get replyTo => _replyTo;

  @override
  DateTime get timestamp => DateTime.now();

  @override
  Map<String, dynamic> get metadata => _metadata;

  @override
  String toString() => 'HeaderSyncStatusMessage(requested: $requestedHeight, '
      'current: $currentHeight, upToDate: $isUpToDate)';
} 