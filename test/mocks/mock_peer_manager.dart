import 'dart:async';
import 'package:spiffynode/spiffy_node.dart';

/// Mock PeerManager for testing
/// Simulates SpiffyNode peer management without actual network connections
class MockPeerManager implements PeerManager {
  final List<MockPeer> _peers = [];
  final MockChainTipTracker _chainTipTracker;
  
  MockPeerManager({int networkHeight = 1359485})
      : _chainTipTracker = MockChainTipTracker(networkHeight: networkHeight) {
    // Add some mock peers
    _peers.addAll([
      MockPeer('127.0.0.1:18333', 1),
      MockPeer('127.0.0.1:18334', 2),
      MockPeer('127.0.0.1:18335', 3),
    ]);
  }
  
  @override
  List<PeerI> getPeers() => _peers;
  
  @override
  MockChainTipTracker get chainTipTracker => _chainTipTracker;
  
  /// Update network height (for testing)
  void setNetworkHeight(int height) {
    _chainTipTracker.setNetworkHeight(height);
  }
  
  /// Add a mock peer
  @override
  Future<void> addPeer(PeerI peer) async {
    if (peer is MockPeer) {
      _peers.add(peer);
    }
  }
  
  /// Remove all peers
  void clearPeers() {
    _peers.clear();
  }
  
  // Implement other PeerManager methods as no-ops for testing
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// Mock Peer implementation
class MockPeer implements PeerI {
  final String _address;
  final int _id;
  
  MockPeer(this._address, this._id);
  
  @override
  String toString() => _address;
  
  int get id => _id;
  
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// Mock ChainTipTracker implementation
class MockChainTipTracker implements ChainTipTracker {
  int _networkHeight;
  final StreamController<ChainTipEvent> _tipEventsController;
  
  MockChainTipTracker({required int networkHeight})
      : _networkHeight = networkHeight,
        _tipEventsController = StreamController<ChainTipEvent>.broadcast();
  
  @override
  int get networkHeight => _networkHeight;
  
  @override
  Stream<ChainTipEvent> get tipEvents => _tipEventsController.stream;
  
  /// Update network height and emit event
  void setNetworkHeight(int height) {
    _networkHeight = height;
    // Could emit ChainTipEvent here if needed for testing
  }
  
  /// Emit a chain tip event (for testing)
  void emitTipEvent(ChainTipEvent event) {
    _tipEventsController.add(event);
  }
  
  /// Close the stream
  void close() {
    _tipEventsController.close();
  }
  
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

