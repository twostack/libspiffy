import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:convert/convert.dart';
import '../../lib/src/utils/beef.dart';
import '../../lib/src/utils/bump.dart';

/// Mock ARC service for testing
/// Simulates transaction broadcasting and merkle proof generation
class MockArcService {
  final Map<String, String> _broadcastedTransactions = {};
  final Map<String, Map<String, dynamic>> _merkleProofs = {};
  
  // Test data - real merkle proofs from test data
  final Map<String, Map<String, dynamic>> _testProofs = {
    '5e0ae9db2586ac8ea89b0f0eb628e1624ccfbdafff860052b67069a401d8ed71': {
      'index': 2,
      'path': [
        'a7026883d1074d1477d23c030f9997ff9fa45d07641a8a9c95f9116a2ac1cdd5',
        '378e4682082a1307d1e4a64807f93fc786e34bf5dc79760688613e18c41cda20',
        '04586929cfce578ca23105f4d1f059af87f108aac1fee23955c3193d617198d6',
      ],
      'blockHeight': 1291860,
    },
    'c652c5c422f29c0487a142cd56c192f2c99483f3792b69b290d0d4016819ad40': {
      'index': 3,
      'path': [
        '61b11dae69abb7bc69d28add139479de2cbf356689f8480f9981ea49aaeee25e',
        '7d6c093ae9f3f6305f9b3616de9b2dfc496e943587bddaee96dd2c8d7cb5474c',
        '9a6a236a16dea8996d5aece3bbdbde01031ceff1745308f08e01172faa8a5ca4',
      ],
      'blockHeight': 1358861,
    },
    '61b11dae69abb7bc69d28add139479de2cbf356689f8480f9981ea49aaeee25e': {
      'index': 2,
      'path': [
        'c652c5c422f29c0487a142cd56c192f2c99483f3792b69b290d0d4016819ad40',
        '7d6c093ae9f3f6305f9b3616de9b2dfc496e943587bddaee96dd2c8d7cb5474c',
        '9a6a236a16dea8996d5aece3bbdbde01031ceff1745308f08e01172faa8a5ca4',
      ],
      'blockHeight': 1358861,
    },
    '1948a7b0eb35b512ed66d416740b9db934530148c03e6136fc63018c031305df': {
      'index': 2,
      'path': [
        '1948a7b0eb35b512ed66d416740b9db934530148c03e6136fc63018c031305df',
        'b9569f8484d2b70bd7a8fcf7823a3f65897ddfe6e715e291a125386f37d338d1',
      ],
      'blockHeight': 1359485,
    },
  };
  
  /// Broadcast a transaction and return txid
  Future<String> broadcastTransaction(String txHex) async {
    // Simulate network delay
    await Future.delayed(Duration(milliseconds: 50));
    
    // Calculate txid (in real implementation, would parse transaction)
    // For mock, we'll generate a deterministic txid based on hex
    final txid = _calculateMockTxid(txHex);
    
    _broadcastedTransactions[txid] = txHex;
    
    // Generate mock merkle proof
    _merkleProofs[txid] = _generateMockMerkleProof(txid);
    
    return txid;
  }
  
  /// Get merkle proof for a transaction
  Future<Map<String, dynamic>> getMerkleProof(String txid) async {
    // Simulate network delay
    await Future.delayed(Duration(milliseconds: 50));
    
    // Check if we have a real test proof
    if (_testProofs.containsKey(txid)) {
      return _testProofs[txid]!;
    }
    
    // Return mock proof if we have one
    if (_merkleProofs.containsKey(txid)) {
      return _merkleProofs[txid]!;
    }
    
    throw Exception('Merkle proof not available for txid: $txid');
  }
  
  /// Create BEEF with transaction and merkle proof
  Future<String> createBEEF(String txHex, String txid) async {
    final proof = await getMerkleProof(txid);
    
    // Create BUMP from merkle proof
    final bump = _createBUMPFromProof(proof);
    
    // Create BEEF
    final beef = BEEF(
      version: 0x0100BEEF,
      bumps: [bump],
      txs: [Uint8List.fromList(hex.decode(txHex))],
      hasMerkle: [true],
      bumpIndex: [0],
    );
    
    return hex.encode(beef.serialize());
  }
  
  /// Get transaction hex by txid
  String? getTransactionHex(String txid) {
    return _broadcastedTransactions[txid];
  }
  
  /// Check if transaction was broadcasted
  bool wasTransactionBroadcasted(String txid) {
    return _broadcastedTransactions.containsKey(txid);
  }
  
  /// Reset mock state
  void reset() {
    _broadcastedTransactions.clear();
    _merkleProofs.clear();
  }
  
  // Private helper methods
  
  String _calculateMockTxid(String txHex) {
    // Simple hash for testing - in reality would be double SHA256
    final bytes = utf8.encode(txHex);
    final hash = bytes.fold<int>(0, (sum, byte) => sum + byte);
    return hash.toRadixString(16).padLeft(64, '0');
  }
  
  Map<String, dynamic> _generateMockMerkleProof(String txid) {
    return {
      'index': 1,
      'path': [
        'mock_hash_1_$txid',
        'mock_hash_2_$txid',
      ],
      'blockHeight': 1291860, // Use first test block
    };
  }
  
  BUMP _createBUMPFromProof(Map<String, dynamic> proof) {
    final blockHeight = proof['blockHeight'] as int;
    final index = proof['index'] as int;
    final pathHashes = (proof['path'] as List).cast<String>();
    
    // Create levels for the merkle tree
    final levels = <Level>[];
    
    for (int i = 0; i < pathHashes.length; i++) {
      final hash = pathHashes[i];
      final hashBytes = Uint8List.fromList(hex.decode(hash));
      
      levels.add(Level(leaves: [
        Leaf(
          offset: index >> i, // Position at this level
          duplicate: false,
          isTxid: i == 0, // First level contains txids
          hash: hashBytes,
        ),
      ]));
    }
    
    return BUMP(
      blockHeight: blockHeight,
      path: levels,
    );
  }
}

