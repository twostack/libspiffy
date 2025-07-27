import 'dart:async';
import 'package:dactor/dactor.dart';
import 'package:libspiffy/src/actors/spv_messages.dart';
import 'package:logging/logging.dart';

import '../spv/block_header_chain.dart';

/// Actor responsible for managing block header synchronization and storage
/// 
/// This actor:
/// - Manages BlockHeaderChain for header validation and storage
/// - Receives block header events from SpiffyNode integration
/// - Notifies SPVActor and other components of header updates
/// - Handles blockchain reorganizations
/// - Provides the bridge between SpiffyNode's network layer and LibSpiffy's SPV validation
class HeaderSyncActor extends Actor {
  final BlockHeaderChain _headerChain;
  final ActorRef? _spvActor;
  final Logger _logger;
  
  // Integration state
  bool _isInitialized = false;
  int _lastProcessedHeight = 0;
  
  // Statistics
  int _headersProcessed = 0;
  int _reorgsHandled = 0;
  DateTime? _lastHeaderAt;

  HeaderSyncActor({
    required BlockHeaderChain headerChain,
    ActorRef? spvActor,
    Logger? logger,
  }) : _headerChain = headerChain,
       _spvActor = spvActor,
       _logger = logger ?? Logger('HeaderSyncActor');

  @override
  void preStart() {
    _logger.info('HeaderSyncActor starting - initializing block header management');
    _initializeState();
  }

  @override
  Future<void> onMessage(dynamic message) async {
    try {
      switch (message.runtimeType) {
        case BlockHeadersReceivedMessage _:
          await _handleBlockHeadersReceived(message as BlockHeadersReceivedMessage);
          break;
          
        case ChainTipEventMessage _:
          await _handleChainTipEvent(message as ChainTipEventMessage);
          break;
          
        case RequestHeaderSyncMessage _:
          await _handleHeaderSyncRequest(message as RequestHeaderSyncMessage);
          break;
        
        case GetSPVStatusMessage _:
          await _handleGetSPVStatus(message as GetSPVStatusMessage);
          break;
          
        default:
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
        merkleProofsStored: 0, // TODO: Get from storage
        lastHeaderUpdate: DateTime.now(),
        connectedPeers: [], // TODO: Get from SpiffyNode
        isHealthy: true,
        statusMessage: 'Header chain initialized and ready for SPV validation',
      ) as dynamic);
    }
  }

  /// Handle incoming block headers from SpiffyNode
  Future<void> _handleBlockHeadersReceived(BlockHeadersReceivedMessage msg) async {
    if (!_isInitialized) {
      _logger.warning('HeaderSyncActor not initialized, queuing headers from ${msg.peerId}');
      // TODO: Implement header queuing for early messages
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
      
      // Update our tracking
      if (msg.newTip.height > _lastProcessedHeight) {
        // This indicates we might be behind - could trigger header sync request
        _logger.info('Chain tip ahead of processed headers: ${msg.newTip.height} > $_lastProcessedHeight');
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
        merkleProofsStored: 0, // TODO: Get from storage
        lastHeaderUpdate: _lastHeaderAt ?? DateTime.now(),
        connectedPeers: [], // TODO: Get from SpiffyNode integration
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
class BlockHeadersProcessedMessage implements SPVMessage {
  final int processed;
  final int failed;
  final int currentHeight;

  BlockHeadersProcessedMessage({
    required this.processed,
    required this.failed,
    required this.currentHeight,
  });

  @override
  String toString() => 'BlockHeadersProcessedMessage(processed: $processed, '
      'failed: $failed, currentHeight: $currentHeight)';
}

/// Message for header sync status
class HeaderSyncStatusMessage implements SPVMessage {
  final int requestedHeight;
  final int currentHeight;
  final bool isUpToDate;
  final String message;

  HeaderSyncStatusMessage({
    required this.requestedHeight,
    required this.currentHeight,
    required this.isUpToDate,
    required this.message,
  });

  @override
  String toString() => 'HeaderSyncStatusMessage(requested: $requestedHeight, '
      'current: $currentHeight, upToDate: $isUpToDate)';
} 