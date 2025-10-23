import 'dart:async';
import 'dart:typed_data';
import 'package:dactor/dactor.dart';
import 'package:logging/logging.dart';
import 'package:spiffynode/spiffy_node.dart';

import '../actors/spv_messages.dart';

/// Integration bridge between SpiffyNode and LibSpiffy
/// 
/// This component:
/// - Connects to SpiffyNode's ChainTipTracker events
/// - Translates events to LibSpiffy actor messages
/// - Sends messages to HeaderSyncActor for processing
/// - Provides the missing link for automatic header synchronization
/// 
/// Usage:
/// ```dart
/// final bridge = SpiffyNodeBridge(
///   peerManager: spiffyNodePeerManager,
///   headerSyncActor: libspiffyHeaderSyncActor,
/// );
/// await bridge.initialize();
/// ```
class SpiffyNodeBridge {
  final PeerManager _peerManager;
  final ActorRef _headerSyncActor;
  final Logger _logger;
  
  // Event subscriptions
  StreamSubscription<ChainTipEvent>? _chainTipSubscription;
  
  // State tracking
  bool _isInitialized = false;
  int _eventsProcessed = 0;
  DateTime? _lastEventAt;

  SpiffyNodeBridge({
    required PeerManager peerManager,
    required ActorRef headerSyncActor,
    Logger? logger,
  }) : _peerManager = peerManager,
       _headerSyncActor = headerSyncActor,
       _logger = logger ?? Logger('SpiffyNodeBridge');

  /// Initialize the bridge and start listening to SpiffyNode events
  Future<void> initialize() async {
    if (_isInitialized) {
      _logger.warning('SpiffyNodeBridge already initialized');
      return;
    }

    _logger.info('Initializing SpiffyNode-LibSpiffy integration bridge');

    try {
      // Subscribe to ChainTipTracker events
      _chainTipSubscription = _peerManager.chainTipTracker.tipEvents.listen(
        _handleChainTipEvent,
        onError: _handleEventError,
      );

      _logger.info('Bridge initialized successfully');
      _logger.info('Listening for SpiffyNode ChainTip events');
      
      _isInitialized = true;
      
    } catch (e, stackTrace) {
      _logger.severe('Failed to initialize SpiffyNodeBridge: $e\n$stackTrace');
      rethrow;
    }
  }

  /// Handle chain tip events from SpiffyNode
  void _handleChainTipEvent(ChainTipEvent event) async {
    if (!_isInitialized) return;

    _logger.fine('Received chain tip event: ${event.type} at height ${event.newTip.height}');

    try {
      // Translate SpiffyNode ChainTipEvent to LibSpiffy ChainTipEventMessage
      // Pass through the original ChainTip objects as they're already the correct type
      final chainTipMessage = ChainTipEventMessage(
        newTip: event.newTip,
        oldTip: event.oldTip,
        eventType: event.isReorganization ? ChainTipEventType.reorganization : ChainTipEventType.heightIncrease,
        description: 'Chain tip ${event.isReorganization ? "reorganization" : "update"} at height ${event.newTip.height}',
      );

      // Send message to HeaderSyncActor for processing
      _headerSyncActor.tell(chainTipMessage as dynamic);
      
      _eventsProcessed++;
      _lastEventAt = DateTime.now();

    } catch (e, stackTrace) {
      _logger.severe('Error handling chain tip event: $e\n$stackTrace');
    }
  }

  /// Convert SpiffyNode ChainTip to LibSpiffy format
  /// 
  /// Note: This creates a simple data structure since we don't have direct
  /// access to the full ChainTip class structure
  dynamic _createChainTipFromSpiffyNode(dynamic spiffyNodeTip) {
    // Return a simple object with the properties LibSpiffy expects
    // Convert Hash to string if needed
    final blockHash = spiffyNodeTip.blockHash != null 
        ? spiffyNodeTip.blockHash.toString() 
        : 'unknown';
    
    return _SimpleChainTip(
      blockHash: blockHash,
      height: spiffyNodeTip.height ?? 0,
      peerCount: spiffyNodeTip.peerCount ?? 1,
      confidence: spiffyNodeTip.confidence ?? 1.0,
    );
  }

  /// Store headers received from enhanced SpiffyNode integration
  /// 
  /// This method can be called when SpiffyNode is enhanced to provide
  /// individual headers (not just tips)
  Future<bool> storeHeaders(List<BlockHeader> headers, int startHeight) async {
    if (!_isInitialized) {
      _logger.warning('Bridge not initialized, cannot store headers');
      return false;
    }

    _logger.info('Forwarding ${headers.length} headers to HeaderSyncActor starting at height $startHeight');

    try {
      // Send headers to HeaderSyncActor for processing
      final headersMessage = BlockHeadersReceivedMessage(
        peerId: 'spiffynode-bridge',
        headers: headers,
        startHeight: startHeight,
        isReorganization: false,
      );
      
      _headerSyncActor.tell(headersMessage as dynamic);
      
      return true;
      
    } catch (e, stackTrace) {
      _logger.severe('Error forwarding headers: $e\n$stackTrace');
      return false;
    }
  }

  /// Handle event stream errors
  void _handleEventError(dynamic error, [StackTrace? stackTrace]) {
    _logger.severe('SpiffyNode event stream error: $error\n${stackTrace ?? ''}');
  }

  /// Shutdown the bridge and cleanup subscriptions
  Future<void> shutdown() async {
    if (!_isInitialized) return;

    _logger.info('Shutting down SpiffyNode-LibSpiffy bridge');

    try {
      await _chainTipSubscription?.cancel();
      
      _isInitialized = false;
      
      _logger.info('Bridge shutdown complete');
      
    } catch (e) {
      _logger.severe('Error during bridge shutdown: $e');
    }
  }

  /// Get list of connected peer IDs
  List<String> getConnectedPeerIds() {
    if (!_isInitialized) return [];
    
    try {
      // Get connected peers from PeerManager
      // PeerManager.getPeers() returns a List<PeerI> .
      // These are peers on the bitcoin network. toString() returns address:port
      return _peerManager.getPeers().map((peer) => peer.toString()).toList();
    } catch (e) {
      _logger.warning('Failed to get connected peer IDs: $e');
      return [];
    }
  }

  /// Get current chain tip height from SpiffyNode
  int get currentHeight => _peerManager.chainTipTracker.networkHeight;
  
  /// Get the ActorRef to HeaderSyncActor for querying stats
  ActorRef get headerSyncActor => _headerSyncActor;
  
  /// Get bridge statistics (enhanced with HeaderSyncActor stats)
  Map<String, dynamic> get statistics => {
    'initialized': _isInitialized,
    'eventsProcessed': _eventsProcessed,
    'lastEventAt': _lastEventAt?.toIso8601String(),
    'spiffyNodeHeight': _peerManager.chainTipTracker.networkHeight,
    'connectedPeers': getConnectedPeerIds(),
    'peerCount': getConnectedPeerIds().length,
    // Note: For HeaderSyncActor stats (blockHeight, headerCount), 
    // query via LibSpiffyActorSystem.getHeaderSyncStats()
  };
}

/// Simple ChainTip data structure for LibSpiffy messages
class _SimpleChainTip {
  final String blockHash;
  final int height;
  final int peerCount;
  final double confidence;

  _SimpleChainTip({
    required this.blockHash,
    required this.height,
    required this.peerCount,
    required this.confidence,
  });
}

/// Enhanced PeerHandler that captures headers for LibSpiffy storage
/// 
/// This handler can be used with SpiffyNode's PeerManager to automatically
/// capture incoming headers and forward them to HeaderSyncActor.
class LibSpiffyPeerHandler implements PeerHandlerI {
  final SpiffyNodeBridge _bridge;
  final PeerHandlerI? _userHandler;
  final Logger _logger;
  final dynamic _headerChain; // Reference to BlockHeaderChain for querying actual height

  LibSpiffyPeerHandler({
    required SpiffyNodeBridge bridge,
    PeerHandlerI? userHandler,
    Logger? logger,
    dynamic headerChain, // BlockHeaderChain reference
  }) : _bridge = bridge,
       _userHandler = userHandler,
       _logger = logger ?? Logger('LibSpiffyPeerHandler'),
       _headerChain = headerChain;

  @override
  Future<void> handleHeaders(WireMessage message, PeerI peer) async {
    if (message is MsgHeaders && message.headers.isNotEmpty) {
      _logger.info('📥 Capturing ${message.headers.length} headers from ${peer.toString()}');
      
      try {
        // Query actual chain height from BlockHeaderChain (not cached counter)
        // Bitcoin's getHeaders returns blocks AFTER the locator, so next height is bestHeight + 1
        final currentBestHeight = _headerChain?.bestHeight ?? 0;
        final startHeight = currentBestHeight > 0 ? currentBestHeight + 1 : 0;
        final batchSize = message.headers.length;
        
        _logger.info('Forwarding ${batchSize} headers starting at height $startHeight (current tip: $currentBestHeight)');
        
        // Forward headers to HeaderSyncActor via bridge
        await _bridge.storeHeaders(message.headers, startHeight);
        
        final endHeight = startHeight + batchSize - 1;
        _logger.info('✓ Forwarded ${batchSize} headers (expected range: $startHeight-$endHeight)');
        
      } catch (e) {
        _logger.severe('❌ Failed to forward headers from ${peer.toString()}: $e');
      }
    }

    // Delegate to user handler
    if (_userHandler != null) {
      await _userHandler.handleHeaders(message, peer);
    }
  }

  @override
  Future<void> handleVersion(WireMessage msg, PeerI peer) async {
    // Delegate to user handler
    if (_userHandler != null) {
      await _userHandler.handleVersion(msg, peer);
    }
  }

  @override
  Future<void> handleTransaction(WireMessage msg, PeerI peer) async {
    // Delegate to user handler
    if (_userHandler != null) {
      await _userHandler.handleTransaction(msg, peer);
    }
  }

  @override
  Future<void> handleTransactionAnnouncement(InvVect inv, PeerI peer) async {
    // Delegate to user handler
    if (_userHandler != null) {
      await _userHandler.handleTransactionAnnouncement(inv, peer);
    }
  }

  @override
  Future<void> handleTransactionSent(WireMessage msg, PeerI peer) async {
    // Delegate to user handler
    if (_userHandler != null) {
      await _userHandler.handleTransactionSent(msg, peer);
    }
  }

  @override
  Future<void> handleTransactionRejection(WireMessage rejMsg, PeerI peer) async {
    // Delegate to user handler
    if (_userHandler != null) {
      await _userHandler.handleTransactionRejection(rejMsg, peer);
    }
  }

  @override
  Future<List<Uint8List>> handleTransactionsGet(List<InvVect> msgs, PeerI peer) async {
    // Delegate to user handler
    if (_userHandler != null) {
      return await _userHandler.handleTransactionsGet(msgs, peer);
    }
    return [];
  }

  @override
  Future<void> handleBlock(WireMessage msg, PeerI peer) async {
    // Delegate to user handler
    if (_userHandler != null) {
      await _userHandler.handleBlock(msg, peer);
    }
  }

  @override
  Future<void> handleBlockAnnouncement(InvVect inv, PeerI peer) async {
    // Delegate to user handler
    if (_userHandler != null) {
      await _userHandler.handleBlockAnnouncement(inv, peer);
    }
  }

  @override
  Future<void> handleAddresses(WireMessage msg, PeerI peer) async {
    // Delegate to user handler
    if (_userHandler != null) {
      await _userHandler.handleAddresses(msg, peer);
    }
  }
} 