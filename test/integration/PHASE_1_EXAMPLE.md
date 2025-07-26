# Phase 1 Expansion Example: ARC Service Integration

## Overview
This shows how I would expand the current integration tests to include real-world service connectivity, starting with the ARC (Application Resource Center) service integration.

## Current vs Expanded Testing

### Current State ✅
```dart
// Current basic transaction test
test('should create transactions with proper structure', () async {
  final wallet = await _createFundedTestWallet(eventStore);
  
  final outputs = [
    TransactionOutput(address: testAddress, satoshis: BigInt.from(50000)),
  ];

  await wallet.commandHandler(CreateTransactionCommand(
    walletId: wallet.aggregateId,
    transactionId: 'test_transaction_001',
    outputs: outputs,
    feeRate: BigInt.from(1),
  ));

  expect(wallet.currentState.version, greaterThan(1));
});
```

### Expanded with ARC Integration 🚀
```dart
// Expanded test with real ARC service integration
test('should broadcast transaction through ARC service', () async {
  final arcService = MockARCService();
  final wallet = await _createWalletWithARCService(arcService, eventStore);
  
  // Setup ARC mock responses
  when(arcService.broadcastTransaction(any)).thenAnswer((_) async => 
    ARCBroadcastResponse(success: true, txid: 'broadcast_tx_12345')
  );
  
  // Create, sign, and broadcast transaction
  final txId = await wallet.createAndSignTransaction([
    TransactionOutput(address: testAddress, satoshis: BigInt.from(50000))
  ]);
  
  final result = await wallet.broadcastTransactionViaARC(txId);
  
  // Verify ARC service integration
  expect(result.success, isTrue);
  expect(result.txid, isNotEmpty);
  verify(arcService.broadcastTransaction(any)).called(1);
  
  // Verify wallet state reflects broadcast
  expect(wallet.currentState.broadcastTransactions.contains(txId), isTrue);
});
```

## Additional ARC Integration Tests

### 1. Fee Estimation Integration
```dart
test('should get dynamic fee estimates from ARC service', () async {
  final arcService = MockARCService();
  when(arcService.getFeeEstimate()).thenAnswer((_) async => FeeEstimate(
    fastestFee: BigInt.from(10),
    economyFee: BigInt.from(1),
  ));
  
  final wallet = await _createWalletWithARCService(arcService, eventStore);
  
  final fees = await wallet.getARCFeeEstimate();
  expect(fees.economyFee, lessThan(fees.fastestFee));
});
```

### 2. Merkle Proof Verification
```dart
test('should retrieve and validate merkle proofs from ARC', () async {
  final arcService = MockARCService();
  final mockProof = MerkleProof(
    txid: 'proof_tx_123',
    blockHeight: 750000,
    proof: ['proof_node_1', 'proof_node_2'],
  );
  
  when(arcService.getMerkleProof('proof_tx_123')).thenAnswer((_) async => mockProof);
  
  final wallet = await _createWalletWithARCService(arcService, eventStore);
  final proof = await wallet.getMerkleProofFromARC('proof_tx_123');
  
  expect(proof.txid, equals('proof_tx_123'));
  expect(await wallet.validateMerkleProof(proof), isTrue);
});
```

### 3. Real-time Status Tracking
```dart
test('should track transaction confirmations via ARC', () async {
  final arcService = MockARCService();
  when(arcService.getTransactionStatus(any)).thenAnswer((_) async => 
    TransactionStatus(txid: 'status_tx_456', confirmations: 6)
  );
  
  final wallet = await _createWalletWithARCService(arcService, eventStore);
  
  final status = await wallet.getTransactionStatusFromARC('status_tx_456');
  expect(status.confirmations, equals(6));
});
```

## Wallet Extensions Required

To support ARC integration, the `BitcoinWalletAggregate` would need these extensions:

```dart
extension ARCIntegration on BitcoinWalletAggregate {
  Future<ARCBroadcastResponse> broadcastTransactionViaARC(String txId) async {
    // Get signed transaction from wallet state
    final signedTx = currentState.getSignedTransaction(txId);
    
    // Broadcast through ARC service
    final result = await arcService.broadcastTransaction(signedTx);
    
    // Update wallet state and emit events
    if (result.success) {
      await commandHandler(TransactionBroadcastSuccessEvent(
        walletId: aggregateId,
        transactionId: txId,
        broadcastTxId: result.txid,
      ));
    }
    
    return result;
  }
  
  Future<FeeEstimate> getARCFeeEstimate() async {
    return await arcService.getFeeEstimate();
  }
  
  Future<MerkleProof> getMerkleProofFromARC(String txid) async {
    return await arcService.getMerkleProof(txid);
  }
}
```

## New Command and Event Classes

### Commands
```dart
class BroadcastTransactionCommand extends WalletCommand {
  final String transactionId;
  final ARCService arcService;
  
  BroadcastTransactionCommand({
    required String walletId,
    required this.transactionId,
    required this.arcService,
  }) : super(walletId: walletId);
}
```

### Events
```dart
class TransactionBroadcastEvent extends WalletEvent {
  final String transactionId;
  final bool success;
  final String? broadcastTxId;
  final String? errorMessage;
  
  TransactionBroadcastEvent({
    required String walletId,
    required this.transactionId,
    required this.success,
    this.broadcastTxId,
    this.errorMessage,
    required DateTime timestamp,
  }) : super(walletId: walletId, timestamp: timestamp);
}
```

## Test Infrastructure Improvements

### Enhanced Test Utilities
```dart
Future<BitcoinWalletAggregate> _createWalletWithARCService(
    MockARCService arcService, EventStore eventStore) async {
  final wallet = BitcoinWalletAggregate(
    aggregateId: 'arc-wallet-${DateTime.now().millisecondsSinceEpoch}',
    aggregateType: 'Wallet',
    eventStore: eventStore,
    arcService: arcService, // Inject ARC service
  );
  
  // Initialize wallet and add funding
  await _initializeWalletWithFunding(wallet);
  
  return wallet;
}
```

## Benefits of This Expansion

1. **Real-world Validation**: Tests actual service integration, not just isolated logic
2. **Network Resilience**: Tests how wallet handles network failures and retries
3. **Performance Insights**: Identifies bottlenecks in service communication
4. **Error Handling**: Validates graceful degradation when services are unavailable
5. **Fee Optimization**: Tests dynamic fee adjustment based on network conditions

## Implementation Timeline

- **Week 1**: Implement basic ARC service mocks and interfaces
- **Week 2**: Add transaction broadcasting integration tests
- **Week 3**: Add fee estimation and merkle proof tests
- **Week 4**: Add real-time status tracking and error handling tests

This Phase 1 expansion would provide confidence that the wallet works correctly in real-world scenarios with actual Bitcoin network services. 