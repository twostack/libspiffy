import 'dart:async';
import 'package:dactor/dactor.dart';
import 'package:libspiffy/src/actors/spv_messages.dart';
import 'package:logging/logging.dart';
import 'package:spiffynode/spiffy_node.dart';

import '../spv/block_header_chain.dart';
import 'internal_messages.dart';
import 'wallet_messages.dart' show HeaderChainReorganizedMessage;

// The header sync wiring messages moved to internal_messages.dart.
export 'internal_messages.dart'
    show SetSpiffyNodeBridgeMessage, SetPeerManagerMessage, InitiateHeaderSyncMessage;

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
  
  /// When the getHeaders request in flight was sent; null when none is.
  /// One request at a time: its answer (a batch, possibly empty) clears
  /// it. One never answered — the peer dropped, or ignored it — expires
  /// after [_syncRequestTimeout], so it cannot hold off every later sync
  /// (bead libspiffy-3pyc).
  DateTime? _syncRequestedAt;
  final Duration _syncRequestTimeout;

  // Consecutive batches whose first header had no known parent; each one
  // triggers a re-request with a full locator, up to this many times.
  int _unknownParentBatches = 0;
  static const int _maxUnknownParentRetries = 3;

  /// Specific-header requests waiting for a header that has not been synced
  /// yet, keyed by height. Resolved by [_resolvePendingHeaderRequests].
  final Map<int, List<_PendingHeaderRequest>> _pendingHeaderRequests = {};

  HeaderSyncActor({
    required BlockHeaderChain headerChain,
    ActorRef? spvActor,
    dynamic spiffyNodeBridge,
    dynamic peerManager,
    int? startHeight,
    Logger? logger,
    Duration syncRequestTimeout = const Duration(seconds: 30),
  }) : _headerChain = headerChain,
       _syncRequestTimeout = syncRequestTimeout,
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
      final requestedAt = _syncRequestedAt;
      if (requestedAt != null) {
        if (DateTime.now().difference(requestedAt) < _syncRequestTimeout) {
          _logger.fine('Header sync already in progress, skipping duplicate request');
          return;
        }
        _logger.warning('The getHeaders request sent at $requestedAt was never answered; asking again');
      }
      
      if (_peerManager == null) {
        _logger.warning('Cannot trigger header sync: no peer manager available');
        return;
      }
      
      final currentHeight = _headerChain.bestHeight;

      final peers = _peerManager.getPeers();
      _logger.info('Triggering header sync from height $currentHeight... (${peers.length} peers, states: ${peers.map((p) => p.state).toList()})');
      if (peers.isEmpty) {
        // Not marked in progress: nothing was sent, so nothing will arrive to
        // clear the flag, and every later trigger would be skipped forever.
        _logger.warning('No peers available for header sync');
        return;
      }

      // Mark sync as in progress
      _syncRequestedAt = DateTime.now();

      // Dense-then-sparse locator down to the anchor: a peer on another
      // branch answers from the first hash it recognises, so after a reorg
      // the reply starts at the fork point rather than at our stale tip.
      final blockLocators = await _headerChain.buildBlockLocator();

      final getHeadersMsg = MsgGetHeaders(
        protocolVersion: 70016,
        blockLocatorHashes: blockLocators,
        hashStop: Hash.zero(), // No stop hash - get all available
      );
      
      // Send to first healthy peer
      var sentCount = 0;
      _logger.info('getHeaders locators: ${getHeadersMsg.blockLocatorHashes.map((h) => h.toString().substring(0, 16)).toList()}');
      for (final peer in peers) {
        try {
          _logger.info('Sending getHeaders to ${peer.toString()} (state: ${peer.state})');
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
        _syncRequestedAt = null; // Clear flag if no request was sent
      }
      
    } catch (e, stackTrace) {
      _logger.severe('Error triggering header sync: $e\n$stackTrace');
      _syncRequestedAt = null; // Clear flag on error
    }
  }

  /// Handle incoming block headers from SpiffyNode
  Future<void> _handleBlockHeadersReceived(BlockHeadersReceivedMessage msg) async {
    // preStart initializes the actor before its mailbox delivers anything,
    // so there is no pre-initialization queue (audit A-L2).
    _logger.info('Processing ${msg.headers.length} headers from peer ${msg.peerId} '
        '(sender says start height ${msg.startHeight})');

    var successCount = 0;
    var failureCount = 0;
    var reorganized = false;
    int? forkHeight;
    final orphanedHashes = <String>{};
    var firstParentUnknown = false;
    BlockHeader? lastStored;

    try {
      for (var i = 0; i < msg.headers.length; i++) {
        final header = msg.headers[i];
        // The chain derives the height from the header's parent. The
        // sender's startHeight is not trusted: after a reorg the peer sends
        // from the fork point, which is below our tip.
        final result = await _headerChain.acceptHeader(header);

        if (result.accepted) {
          successCount++;
          lastStored = header;
          _lastProcessedHeight = result.height ?? _lastProcessedHeight;
          _lastHeaderAt = DateTime.now();
          if (result.reorganized) {
            reorganized = true;
            _reorgsHandled++;
            final fork = result.forkHeight ?? 0;
            if (forkHeight == null || fork < forkHeight) forkHeight = fork;
            orphanedHashes.addAll(result.orphaned.map((h) => h.blockHash().toString()));
            _logger.warning('Reorganization applied: fork at height ${result.forkHeight}, '
                '${result.orphaned.length} header(s) orphaned, new tip at height ${result.height}');
          }
        } else {
          failureCount++;
          _logger.warning('Rejected header from ${msg.peerId}: ${result.reason} - ${result.detail}');
          if (i == 0 && result.reason == HeaderRejectReason.unknownParent) {
            firstParentUnknown = true;
          }
        }
      }

      _headersProcessed += successCount;

      await _resolvePendingHeaderRequests();

      _logger.info('Header processing complete: $successCount stored, $failureCount failed');
      _logger.info('Current height: $_lastProcessedHeight');

      // Clear sync-in-progress flag BEFORE potentially triggering next batch
      _syncRequestedAt = null;

      if (firstParentUnknown && successCount == 0) {
        // The peer answered from a point we do not know (its branch forks
        // below anything in our locator, or it ignored the locator). Ask
        // again with a fresh locator; bounded so a misbehaving peer cannot
        // keep us in a loop.
        _unknownParentBatches++;
        if (_unknownParentBatches <= _maxUnknownParentRetries) {
          _logger.warning('Batch from ${msg.peerId} does not connect to any known header; '
              're-requesting with a full block locator (attempt $_unknownParentBatches)');
          _triggerHeaderSync();
        } else {
          _logger.severe('Giving up on unconnectable batches from ${msg.peerId} after '
              '$_maxUnknownParentRetries attempts');
        }
      } else if (successCount > 0) {
        _unknownParentBatches = 0;
      }

      // Check if we received a full batch (2000 = protocol limit = more headers available)
      if (successCount >= 2000) {
        _logger.info('📡 Received full batch (2000 headers), requesting more...');
        _triggerHeaderSync(); // Request next batch automatically
      } else if (successCount > 0) {
        _logger.info('✅ Sync complete: received ${successCount} headers (less than 2000)');
      }

      // A reorganization first: SPVActor takes back confirmations that rested
      // on the orphaned blocks before the header notification below makes
      // ARCActor poll again (audit 3b0).
      if (_spvActor != null && reorganized) {
        _spvActor.tell(HeaderChainReorganizedMessage(
          forkHeight: forkHeight ?? 0,
          orphanedBlockHashes: orphanedHashes.toList(),
          newTipHeight: _headerChain.bestHeight,
        ) as dynamic);
      }

      // Notify SPVActor of new headers (using the last header stored)
      if (_spvActor != null && successCount > 0 && lastStored != null) {
        _spvActor.tell(BlockHeaderStoredMessage(
          header: lastStored,
          height: _lastProcessedHeight,
          isReorg: reorganized || msg.isReorganization,
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
      _syncRequestedAt = null; // Clear flag on error
      
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
      // The tip event carries no headers, only the new tip. Ask the peers
      // for headers with a full block locator: a peer on the new branch
      // replies from the fork point, and _handleBlockHeadersReceived places
      // those headers by their parents and moves the tip on chainwork.
      // _reorgsHandled is counted there, when the chain actually reorganizes.
      final newTipHash = msg.newTip.blockHash.toString();
      if (await _headerChain.getHeaderByHash(newTipHash) != null) {
        _logger.info('Reorganized tip $newTipHash is already our active tip');
        return;
      }
      _syncRequestedAt = null; // a tip change supersedes any in-flight request
      await _triggerHeaderSync();

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
      
      final blockLocators = await _headerChain.buildBlockLocator();

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

      // The headers arrive as BlockHeadersReceivedMessage on this actor's
      // own mailbox and are stored by _handleBlockHeadersReceived. Polling
      // storage from inside this handler could never see them (the mailbox
      // is held by this handler), so every fetch timed out and blocked
      // header sync for the whole timeout. Park the request instead; it is
      // answered from _handleBlockHeadersReceived, or by the timer.
      final sender = context.sender;
      late final _PendingHeaderRequest pending;
      pending = _PendingHeaderRequest(
        height: msg.blockHeight,
        sender: sender,
        correlationId: msg.correlationId,
        timer: Timer(msg.timeout, () {
          final list = _pendingHeaderRequests[msg.blockHeight];
          if (list == null || !list.remove(pending)) return;
          if (list.isEmpty) _pendingHeaderRequests.remove(msg.blockHeight);
          _logger.warning(
              '⏰ Timeout waiting for header at height ${msg.blockHeight} after ${msg.timeout.inSeconds}s');
          sender?.tell(SpecificHeaderResponseMessage(
            blockHeight: msg.blockHeight,
            header: null,
            success: false,
            error: 'Timeout waiting for header at height ${msg.blockHeight}',
            correlationId: msg.correlationId,
          ));
        }),
      );
      _pendingHeaderRequests.putIfAbsent(msg.blockHeight, () => []).add(pending);
      return;

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
  ///
  /// A specific-header request is answered with the message its caller asks
  /// for (bead libspiffy-lplr). SPVActor._getBlockHeader does a typed
  /// `ask<SpecificHeaderResponseMessage>`, so an SPVErrorMessage here threw a
  /// cast error at the caller instead of taking its `response.error` path,
  /// and "we have not synced that header" could not be told apart from a
  /// real failure. The height is read defensively: whatever made the handler
  /// fail may be the very field that cannot be read.
  void _sendErrorResponse(dynamic message, String error) {
    switch (message) {
      case RequestSpecificHeaderMessage():
        int height;
        String? correlationId;
        try {
          height = message.blockHeight;
        } catch (_) {
          height = -1;
        }
        try {
          correlationId = message.correlationId;
        } catch (_) {
          correlationId = null;
        }
        context.sender?.tell(SpecificHeaderResponseMessage(
          blockHeight: height,
          header: null,
          success: false,
          error: error,
          correlationId: correlationId,
        ) as dynamic);
        break;
      case BlockHeadersReceivedMessage():
        context.sender?.tell(SPVErrorMessage(
          operation: 'process_headers',
          error: error,
        ) as dynamic);
        break;
      case RequestHeaderSyncMessage():
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
    for (final list in _pendingHeaderRequests.values) {
      for (final p in list) {
        p.timer.cancel();
      }
    }
    _pendingHeaderRequests.clear();
    _logger.info('HeaderSyncActor stopped');
  }

  /// Answers any parked RequestSpecificHeaderMessage whose header is now
  /// stored. Called after each batch of headers has been processed.
  Future<void> _resolvePendingHeaderRequests() async {
    if (_pendingHeaderRequests.isEmpty) return;
    for (final height in _pendingHeaderRequests.keys.toList()) {
      final header = await _headerChain.getHeaderByHeight(height);
      if (header == null) continue;
      final list = _pendingHeaderRequests.remove(height) ?? const [];
      for (final p in list) {
        p.timer.cancel();
        _logger.info('✅ Header at height $height arrived; answering parked request');
        p.sender?.tell(SpecificHeaderResponseMessage(
          blockHeight: height,
          header: header,
          success: true,
          correlationId: p.correlationId,
        ));
      }
    }
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
class BlockHeadersProcessedMessage extends ActorResponse implements SPVMessage {
  final int processed;
  final int failed;
  final int currentHeight;

  /// Whether the batch was processed at all. [failed] counts the headers
  /// within a batch that were rejected; [success] says whether processing
  /// ran (bead libspiffy-97zj).
  @override
  final bool success;

  @override
  final String? error;

  BlockHeadersProcessedMessage({
    required this.processed,
    required this.failed,
    required this.currentHeight,
    this.success = true,
    this.error,
    String? correlationId,
    ActorRef? replyTo,
    Map<String, dynamic>? metadata,
  }) : super(
          correlationId: correlationId ?? 'headers_processed_${DateTime.now().millisecondsSinceEpoch}',
          replyTo: replyTo,
          metadata: metadata ?? {},
        );

  @override
  String toString() => 'BlockHeadersProcessedMessage(processed: $processed, '
      'failed: $failed, currentHeight: $currentHeight)';
}

/// Message for header sync status
class HeaderSyncStatusMessage extends ActorResponse implements SPVMessage {
  final int requestedHeight;
  final int currentHeight;
  final bool isUpToDate;
  final String message;

  /// Whether the sync status could be reported. [isUpToDate] says what the
  /// chain looks like; [success] says whether we could look (bead
  /// libspiffy-97zj).
  @override
  final bool success;

  @override
  final String? error;

  HeaderSyncStatusMessage({
    required this.requestedHeight,
    required this.currentHeight,
    required this.isUpToDate,
    required this.message,
    this.success = true,
    this.error,
    String? correlationId,
    ActorRef? replyTo,
    Map<String, dynamic>? metadata,
  }) : super(
          correlationId: correlationId ?? 'sync_status_${DateTime.now().millisecondsSinceEpoch}',
          replyTo: replyTo,
          metadata: metadata ?? {},
        );

  @override
  String toString() => 'HeaderSyncStatusMessage(requested: $requestedHeight, '
      'current: $currentHeight, upToDate: $isUpToDate)';
} 

/// A RequestSpecificHeaderMessage parked until its header is stored.
class _PendingHeaderRequest {
  final int height;
  final ActorRef? sender;
  final String? correlationId;
  final Timer timer;

  _PendingHeaderRequest({
    required this.height,
    required this.sender,
    required this.correlationId,
    required this.timer,
  });
}
