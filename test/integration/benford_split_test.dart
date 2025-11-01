import 'dart:async';
import 'dart:io';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:test/test.dart';
import 'package:dactor/dactor.dart';
import 'package:eventador/eventador.dart';
import 'package:isar/isar.dart';
import 'package:libspiffy/libspiffy.dart';
import 'package:libspiffy/src/storage/isar_wallet_storage.dart';

import '../mocks/mock_arc_service.dart';

/// Integration tests for Benford UTXO Splitting
/// 
/// Tests cover:
/// - Complete split flow with multiple UTXOs
/// - Benford distribution verification
/// - Transaction building and signing
/// - CQRS integration (UTXOs marked as spent/received)
/// - Event emission and tracking
/// - Error handling scenarios

// =============================================================================
// TEST DATA - Real Testnet Wallet (same as import_actor_test.dart)
// =============================================================================

/// Test xpriv with real testnet history
const kTestXpriv = 'tprv8ZgxMBicQKsPeMiDjtXBGAyFY1wEMGgomjwf54ZmiZfKTNYvVdBa6GqWUwnvtHm6NKVkQkhCKxaobd9JPxNEXgDfVgJ5RNHJ3ivogSG3V1R';

/// Root address (m/0/0) derived from test xpriv
const kTestRootAddress = 'mqCnSf8i6kmaQaJ54HjQ8EUJnuK4AnCv12';

/// Real testnet transaction IDs for test UTXOs
/// Transaction 1: Block 1239645, pays 200000000 sats to root address at vout 1
const kTx1Id = 'a05924fcc63712d3e4b94b0c88baad234c2c8ad3d369704f53765e21a53a2101';

/// Transaction 2: Block 1701169, spends from tx1
const kTx2Id = '05c4d800ac77703bb00e41d8bf9d006c0e52f8405ba92c4506b80ad8f5337ae1';

/// Transaction 3: Another test transaction for multi-UTXO tests
const kTx3Id = 'f4184fc596403b9d638783cf57adfe4c75c605f6356fbc91338530e9831e9e16';

// =============================================================================
// TEST HELPER FUNCTIONS
// =============================================================================

/// Create test infrastructure
class BenfordTestContext {
  final Directory testDir;
  final LocalActorSystem actorSystem;
  final Isar isar;
  final LibSpiffyActorSystem libspiffy;
  final IsarWalletStorage storage;
  final EventStore eventStore;
  final DartSVCryptoService cryptoService;
  final InMemorySecureStorage secureStorage;
  final MockArcService mockArcService;
  final List<WalletEvent> capturedEvents = [];
  final List<String> broadcastedTransactions = [];

  BenfordTestContext({
    required this.testDir,
    required this.actorSystem,
    required this.isar,
    required this.libspiffy,
    required this.storage,
    required this.eventStore,
    required this.cryptoService,
    required this.secureStorage,
    required this.mockArcService,
  });

  /// Cleanup resources
  Future<void> dispose() async {
    await libspiffy.shutdown();
    await isar.close(deleteFromDisk: true);
    testDir.deleteSync(recursive: true);
  }
}

/// Setup test infrastructure for Benford splitting
Future<BenfordTestContext> setupBenfordTestContext() async {
  await Isar.initializeIsarCore(download: true);

  final testDir = Directory.systemTemp.createTempSync('benford-split-test-');
  final actorSystem = LocalActorSystem(ActorSystemConfig());

  // Open Isar with all required schemas
  final isar = await Isar.open(
    LibSpiffySchemas.allSchemas,
    directory: testDir.path,
    name: 'test_benford_db',
  );

  // Create MockArcService for testing
  final mockArcService = MockArcService();
  
  // Initialize LibSpiffy actor system (this registers all event types)
  final libspiffy = LibSpiffyActorSystem();
  await libspiffy.initialize(
    actorSystem: actorSystem,
    isar: isar,
    dataDirectory: testDir.path,
    enableP2P: false,
    arcService: mockArcService,  // ← Pass mock service for testing!
  );

  final storage = libspiffy.walletStorage as IsarWalletStorage;
  
  // Create event store (event types are now registered by libspiffy initialization)
  final eventStore = IsarEventStore(isar);
  
  // Create shared crypto service and secure storage for consistent key management
  final cryptoService = DartSVCryptoService();
  final secureStorage = InMemorySecureStorage();

  return BenfordTestContext(
    testDir: testDir,
    actorSystem: actorSystem,
    isar: isar,
    libspiffy: libspiffy,
    storage: storage,
    eventStore: eventStore,
    cryptoService: cryptoService,
    secureStorage: secureStorage,
    mockArcService: mockArcService,
  );
}

/// Create a test wallet with UTXOs using the actor system
Future<String> createTestWalletWithUtxos(
  BenfordTestContext context, {
  required String walletId,
  required int utxoCount,
  required List<BigInt> utxoAmounts,
}) async {
  // Store the xpriv in secure storage for HD key derivation
  await context.secureStorage.setXPriv(walletId, kTestXpriv);

  // Create wallet through the actor system (proper flow)
  final createCommand = CreateWalletCommand(
    walletId: walletId,
    walletName: 'Benford Test Wallet',
    xpriv: kTestXpriv,
    walletMetadata: {'network': 'testnet'},
  );

  context.libspiffy.walletManager.tell(WalletCommandMessage(
    walletId,
    createCommand,
  ));
  
  // Wait for wallet creation to propagate through projections
  await Future.delayed(const Duration(milliseconds: 500));

  // Generate addresses for each UTXO
  final addresses = <String>[];
  for (int i = 0; i < utxoCount; i++) {
    final addrCommand = GenerateAddressCommand(
      walletId: walletId,
      purpose: 'receive',
    );
    context.libspiffy.walletManager.tell(WalletCommandMessage(
      walletId,
      addrCommand,
    ));
    await Future.delayed(const Duration(milliseconds: 100));

    // Get addresses from projection
    final walletAddresses = await context.storage.getWalletAddresses(walletId);
    if (walletAddresses.length > i) {
      addresses.add(walletAddresses[i]);
    }
  }
  
  // Wait for address generation to complete
  await Future.delayed(const Duration(milliseconds: 500));
  final allAddresses = await context.storage.getWalletAddresses(walletId);
  
  // Use generated addresses or derive them directly
  if (allAddresses.length >= utxoCount) {
    addresses.clear();
    addresses.addAll(allAddresses.take(utxoCount));
  } else {
    // Fallback: derive addresses directly
    final hdPubkey = await context.secureStorage.getString('wallet_hdpubkey_$walletId');
    if (hdPubkey != null) {
      final hdKey = dartsv.HDPublicKey.fromXpub(hdPubkey);
      for (int i = 0; i < utxoCount; i++) {
        final addr = context.cryptoService.generateReceivingAddress(
          hdKey,
          i,
          network: dartsv.NetworkType.TEST,
        );
        if (!addresses.contains(addr)) {
          addresses.add(addr);
        }
      }
    }
  }

  // Add UTXOs to the wallet using real testnet transaction IDs
  final realTxIds = [kTx1Id, kTx2Id, kTx3Id];
  
  for (int i = 0; i < utxoCount; i++) {
    final utxoCommand = ReceiveUTXOCommand(
      walletId: walletId,
      txid: realTxIds[i % realTxIds.length],
      vout: i,
      satoshis: utxoAmounts[i],
      scriptPubKey: _createP2PKHScript(addresses[i]),
      address: addresses[i],
      blockHeight: 1239645 + i,
      confirmations: 10,
      initialStatus: UTXOStatus.available,
    );
    context.libspiffy.walletManager.tell(WalletCommandMessage(
      walletId,
      utxoCommand,
    ));
    await Future.delayed(const Duration(milliseconds: 100));
  }
  
  // Wait for UTXO commands to propagate
  await Future.delayed(const Duration(milliseconds: 500));

  print('✓ Created test wallet with $utxoCount UTXOs');
  for (int i = 0; i < utxoCount && i < addresses.length; i++) {
    print('  UTXO $i: ${utxoAmounts[i]} sats at ${addresses[i]}');
  }

  return walletId;
}

/// Create a P2PKH script for an address (dummy for testing)
String _createP2PKHScript(String address) {
  return dartsv.P2PKHLockBuilder.fromAddress(dartsv.Address.fromBase58(address)).script.toString();
}

/// Verify that amounts follow Benford's Law distribution
bool verifyBenfordDistribution(List<BigInt> amounts, {double tolerance = 0.15}) {
  if (amounts.isEmpty) return false;

  final distribution = BenfordDistribution.analyzeDistribution(amounts);
  
  print('\n📊 Benford Distribution Analysis:');
  for (int digit = 1; digit <= 9; digit++) {
    final actual = distribution[digit] ?? 0.0;
    final expected = BenfordDistribution.benfordProbabilities[digit]!;
    final diff = (actual - expected).abs();
    final symbol = diff <= tolerance ? '✓' : '✗';
    print('  Digit $digit: ${(actual * 100).toStringAsFixed(1)}% '
          '(expected: ${(expected * 100).toStringAsFixed(1)}%) '
          '$symbol');
  }

  // Check if distribution is reasonably close to Benford's Law
  int matchingDigits = 0;
  for (int digit = 1; digit <= 9; digit++) {
    final actual = distribution[digit] ?? 0.0;
    final expected = BenfordDistribution.benfordProbabilities[digit]!;
    if ((actual - expected).abs() <= tolerance) {
      matchingDigits++;
    }
  }

  final isValid = matchingDigits >= 6; // At least 6 out of 9 digits should match
  print('  Result: $matchingDigits/9 digits match (${isValid ? "PASS" : "FAIL"})');
  
  return isValid;
}

// =============================================================================
// INTEGRATION TESTS
// =============================================================================

void main() {
  group('Benford UTXO Splitting Integration Tests', () {
    
    test('aggregate validates and emits initiation event', () async {
      print('\n=== Test: Aggregate Validation ===\n');
      
      final context = await setupBenfordTestContext();
      final walletId = 'benford-test-${DateTime.now().millisecondsSinceEpoch}';
      
      try {
        print('Step 1: Create test wallet with 1 UTXO');
        await createTestWalletWithUtxos(
          context,
          walletId: walletId,
          utxoCount: 1,
          utxoAmounts: [BigInt.from(100000)],
        );

        print('\nStep 2: Create aggregate and process SplitUTXOsToBenfordCommand');
        final aggregate = BitcoinWalletAggregate(
          aggregateId: walletId,
          aggregateType: 'Wallet',
          eventStore: context.eventStore,
          cryptoService: context.cryptoService,
          secureStorage: context.secureStorage,
        );

        // Start the actor to trigger recovery
        aggregate.preStart();
        await Future.delayed(const Duration(milliseconds: 100));

        // Send split command
        final splitCommand = SplitUTXOsToBenfordCommand(
          walletId: walletId,
          targetUtxoCount: 10,
          feeRate: BigInt.one,
        );

        print('  Processing command...');
        final events = await aggregate.handleCommand(
          aggregate.currentState,
          splitCommand,
        );

        print('\nStep 3: Verify initiation event was emitted');
        expect(events, isNotEmpty, reason: 'Should emit events');
        
        final initiatedEvents = events.whereType<UTXOSplitInitiatedEvent>();
        expect(initiatedEvents.length, equals(1), 
          reason: 'Should emit UTXOSplitInitiatedEvent');
        print('✓ UTXOSplitInitiatedEvent emitted');

        final initiatedEvent = initiatedEvents.first;
        expect(initiatedEvent.utxoKeysToSplit.length, equals(1),
          reason: 'Should have 1 UTXO to split');
        expect(initiatedEvent.targetUtxoCount, equals(10),
          reason: 'Target count should be 10');
        expect(initiatedEvent.feeRate, equals(BigInt.one),
          reason: 'Fee rate should be 1');
        print('✓ Event contains correct split parameters');

        print('\n✅ Aggregate validation test PASSED\n');
      } finally {
        await context.dispose();
      }
    });

    test('split multiple UTXOs', () async {
      print('\n=== Test: Split Multiple UTXOs ===\n');
      
      final context = await setupBenfordTestContext();
      final walletId = 'multi-benford-${DateTime.now().millisecondsSinceEpoch}';
      
      try {
        print('Step 1: Create test wallet with 3 UTXOs');
        await createTestWalletWithUtxos(
          context,
          walletId: walletId,
          utxoCount: 3,
          utxoAmounts: [
            BigInt.from(150000),
            BigInt.from(250000),
            BigInt.from(100000),
          ],
        );

        print('\nStep 2: Process split command');
        // Use the same secure storage and crypto service from context
        final aggregate = BitcoinWalletAggregate(
          aggregateId: walletId,
          aggregateType: 'Wallet',
          eventStore: context.eventStore,
          cryptoService: context.cryptoService,
          secureStorage: context.secureStorage,
        );

        // Start the actor to trigger recovery (will load wallet from events)
        aggregate.preStart();
        await Future.delayed(const Duration(milliseconds: 100));

        final splitCommand = SplitUTXOsToBenfordCommand(
          walletId: walletId,
          targetUtxoCount: 8,
          feeRate: BigInt.one,
        );

        final events = await aggregate.handleCommand(
          aggregate.currentState,
          splitCommand,
        );

        print('\nStep 3: Verify initiation event contains all UTXOs');
        final initiatedEvents = events.whereType<UTXOSplitInitiatedEvent>();
        expect(initiatedEvents.length, equals(1),
          reason: 'Should emit single initiation event');
        
        final initiatedEvent = initiatedEvents.first;
        expect(initiatedEvent.utxoKeysToSplit.length, equals(3),
          reason: 'Should have 3 UTXOs to split');
        expect(initiatedEvent.targetUtxoCount, equals(8),
          reason: 'Target count should be 8');
        print('✓ Initiation event contains all 3 UTXOs');

        print('\n✅ Multiple UTXOs split test PASSED\n');
      } finally {
        await context.dispose();
      }
    });

    test('Benford distribution utility validation', () async {
      print('\n=== Test: Benford Distribution Utility ===\n');
      
      print('Step 1: Test distribution with 10 outputs');
      final amounts10 = BenfordDistribution.distribute(
        BigInt.from(100000),
        10,
      );
      expect(amounts10.length, equals(10));
      print('✓ Generated 10 amounts');

      // Verify sum equals input
      final sum10 = amounts10.fold<BigInt>(BigInt.zero, (a, b) => a + b);
      expect(sum10, equals(BigInt.from(100000)));
      print('✓ Sum matches input: $sum10');

      print('\nStep 2: Test distribution with 20 outputs');
      final amounts20 = BenfordDistribution.distribute(
        BigInt.from(1000000),
        20,
      );
      expect(amounts20.length, equals(20));
      final followsBenford20 = verifyBenfordDistribution(amounts20, tolerance: 0.15);
      expect(followsBenford20, isTrue);
      print('✓ 20-output distribution follows Benford\'s Law');

      print('\nStep 3: Test with small amounts (1 sat minimum)');
      final amountsSmall = BenfordDistribution.distribute(
        BigInt.from(100),
        10,
        minOutputAmount: BigInt.one,
      );
      expect(amountsSmall.every((a) => a >= BigInt.one), isTrue);
      print('✓ All outputs ≥ 1 satoshi (no dust)');

      print('\nStep 4: Test edge case - minimum viable split');
      final amountsMin = BenfordDistribution.distribute(
        BigInt.from(50),
        5,
        minOutputAmount: BigInt.one,
      );
      expect(amountsMin.length, equals(5));
      final sumMin = amountsMin.fold<BigInt>(BigInt.zero, (a, b) => a + b);
      expect(sumMin, equals(BigInt.from(50)));
      print('✓ Minimum split works correctly');

      print('\nStep 5: Verify error handling');
      expect(
        () => BenfordDistribution.distribute(BigInt.from(10), 1),
        throwsArgumentError,
        reason: 'Should require at least 2 outputs',
      );
      print('✓ Validates minimum output count');

      expect(
        () => BenfordDistribution.distribute(BigInt.from(5), 10),
        throwsArgumentError,
        reason: 'Should validate total amount',
      );
      print('✓ Validates total amount sufficiency');

      print('\n✅ Benford distribution utility test PASSED\n');
    });

    test('command validation', () async {
      print('\n=== Test: Command Validation ===\n');
      
      final walletId = 'validation-test';
      
      print('Step 1: Test valid command creation');
      final validCommand = SplitUTXOsToBenfordCommand(
        walletId: walletId,
        targetUtxoCount: 10,
      );
      expect(validCommand.targetUtxoCount, equals(10));
      print('✓ Valid command created');

      print('\nStep 2: Test invalid target count (too low)');
      expect(
        () => SplitUTXOsToBenfordCommand(
          walletId: walletId,
          targetUtxoCount: 1,
        ),
        throwsArgumentError,
        reason: 'Should require at least 2 outputs',
      );
      print('✓ Rejects targetUtxoCount < 2');

      print('\nStep 3: Test invalid target count (too high)');
      expect(
        () => SplitUTXOsToBenfordCommand(
          walletId: walletId,
          targetUtxoCount: 101,
        ),
        throwsArgumentError,
        reason: 'Should limit to 100 outputs',
      );
      print('✓ Rejects targetUtxoCount > 100');

      print('\nStep 4: Test invalid fee rate');
      expect(
        () => SplitUTXOsToBenfordCommand(
          walletId: walletId,
          targetUtxoCount: 10,
          feeRate: BigInt.zero,
        ),
        throwsArgumentError,
        reason: 'Should require positive fee rate',
      );
      print('✓ Rejects non-positive fee rate');

      print('\n✅ Command validation test PASSED\n');
    });

    test('event serialization and deserialization', () async {
      print('\n=== Test: Event Serialization ===\n');
      
      final walletId = 'event-test';
      
      print('Step 1: Test UTXOSplitInitiatedEvent');
      final initiatedEvent = UTXOSplitInitiatedEvent(
        walletId: walletId,
        utxoKeysToSplit: ['tx1:0', 'tx2:1', 'tx3:0'],
        targetUtxoCount: 10,
        feeRate: BigInt.one,
        version: 1,
        timestamp: DateTime.now(),
      );
      final initiatedMap = initiatedEvent.toMap();
      expect(initiatedMap['utxoKeysToSplit'], hasLength(3));
      expect(initiatedMap['targetUtxoCount'], equals(10));
      print('✓ UTXOSplitInitiatedEvent serializes correctly');

      print('\nStep 2: Test UTXOSplitCompletedEvent');
      final completedEvent = UTXOSplitCompletedEvent(
        walletId: walletId,
        originalUtxoKey: 'tx1:0',
        originalAmount: '100000',
        splitTxid: 'split_tx_123',
        outputsCreated: 10,
        feePaid: '224',
        version: 2,
        timestamp: DateTime.now(),
      );
      final completedMap = completedEvent.toMap();
      expect(completedMap['outputsCreated'], equals(10));
      expect(completedMap['splitTxid'], equals('split_tx_123'));
      print('✓ UTXOSplitCompletedEvent serializes correctly');

      print('\nStep 3: Test AllUTXOsSplitCompletedEvent');
      final allCompleteEvent = AllUTXOsSplitCompletedEvent(
        walletId: walletId,
        totalUtxosSplit: 3,
        totalOutputsCreated: 30,
        totalFeesPaid: '672',
        transactionIds: ['tx1', 'tx2', 'tx3'],
        version: 5,
        timestamp: DateTime.now(),
      );
      final allCompleteMap = allCompleteEvent.toMap();
      expect(allCompleteMap['totalUtxosSplit'], equals(3));
      expect(allCompleteMap['transactionIds'], hasLength(3));
      print('✓ AllUTXOsSplitCompletedEvent serializes correctly');

      print('\n✅ Event serialization test PASSED\n');
    });

    test('end-to-end split flow with full actor system', () async {
      print('\n=== Test: End-to-End Benford Split ===\n');
      
      final context = await setupBenfordTestContext();
      final walletId = 'e2e-benford-${DateTime.now().millisecondsSinceEpoch}';
      
      try {
        print('Step 1: Import wallet with real testnet data (like import_actor_test)');
        // Create test wallet with UTXOs using the same pattern as import_actor_test
        await createTestWalletWithUtxos(
          context,
          walletId: walletId,
          utxoCount: 2,
          utxoAmounts: [
            BigInt.from(100000),  // 100,000 sats
            BigInt.from(250000),  // 250,000 sats
          ],
        );
        
        print('✓ Wallet created with 2 UTXOs (100k and 250k sats)');

        print('\nStep 2: Verify initial wallet state in projection');
        
        // Debug: Check what's actually in Isar
        print('  Querying wallet ID: $walletId');
        
        // Check wallet exists
        final wallet = await context.storage.getWallet(walletId);
        print('  Wallet found: ${wallet != null}');
        if (wallet != null) {
          print('    Wallet name: ${wallet['name']}');
          print('    Wallet type: ${wallet['type']}');
        }
        
        // Check addresses
        final addresses = await context.storage.getWalletAddresses(walletId);
        print('  Addresses found: ${addresses.length}');

        // Check UTXOs (including spent)
        final allUtxos = await context.storage.getUTXOs(walletId, includeSpent: true);
        print('  Total UTXOs (including spent): ${allUtxos.length}');
        for (final utxo in allUtxos) {
          print('    UTXO: ${utxo.txid}:${utxo.vout} - ${utxo.satoshis} sats (${utxo.status.name})');
        }
        
        // Check available UTXOs
        final initialUtxos = await context.storage.getUTXOs(walletId);
        print('  Available UTXOs: ${initialUtxos.length}');
        
        expect(initialUtxos.length, equals(2), reason: 'Should have 2 initial UTXOs');
        final initialAvailable = initialUtxos.where((u) => u.status == UTXOStatus.available).length;
        expect(initialAvailable, equals(2), reason: 'Both UTXOs should be available');
        print('✓ Projection shows 2 available UTXOs');

        final initialBalance = initialUtxos.fold<BigInt>(
          BigInt.zero,
          (sum, utxo) => sum + utxo.satoshis,
        );
        print('  Initial balance: $initialBalance sats');

        print('\nStep 3: Send SplitUTXOsToBenfordCommand through actor system');
        final splitCommand = SplitUTXOsToBenfordCommand(
          walletId: walletId,
          targetUtxoCount: 5,  // Split each UTXO into 5 outputs
          feeRate: BigInt.one,
        );

        // Send command through WalletManager (simulating public API)
        context.libspiffy.walletManager.tell(WalletCommandMessage(
          walletId,
          splitCommand,
        ));

        print('  Command sent, waiting for coordinator to process...');
        
        print('\nStep 4: Wait for split operations to complete');
        // The coordinator will:
        // 1. Build and sign transactions
        // 2. Broadcast via MockArcService
        // 3. Send CQRS commands (SpendUTXO, ReceiveUTXO, RecordTransaction)
        // 4. Wallet projection will update the database
        await Future.delayed(const Duration(seconds: 5));

        print('\nStep 5: Verify split transactions were broadcast');
        // Check MockArcService for broadcast transactions
        final broadcastCount = context.mockArcService.getBroadcastCount();
        expect(broadcastCount, greaterThanOrEqualTo(2), 
          reason: 'Should broadcast 2 transactions (one per source UTXO)');
        print('✓ Broadcast $broadcastCount transaction(s)');

        print('\nStep 6: Verify wallet projection updated UTXOs');
        // Wait a bit more for projections to process events
        await Future.delayed(const Duration(seconds: 2));
        
        final finalUtxos = await context.storage.getUTXOs(walletId);
        print('  Total UTXOs in projection: ${finalUtxos.length}');
        
        // Should have:
        // - 2 original UTXOs (now spent)
        // - 10 new UTXOs (2 source UTXOs × 5 outputs each)
        expect(finalUtxos.length, greaterThanOrEqualTo(10),
          reason: 'Should have at least 10 new UTXOs');

        final spentUtxos = finalUtxos.where((u) => u.status == UTXOStatus.spent).toList();
        final pendingUtxos = finalUtxos.where((u) => u.status == UTXOStatus.pending).toList();
        
        print('  Spent UTXOs: ${spentUtxos.length}');
        print('  Pending UTXOs: ${pendingUtxos.length}');
        
        expect(spentUtxos.length, equals(2), 
          reason: 'Original 2 UTXOs should be spent');
        expect(pendingUtxos.length, greaterThanOrEqualTo(10),
          reason: 'Should have 10 pending UTXOs from split');

        print('\nStep 7: Verify Benford distribution of new UTXOs');
        final newUtxoAmounts = pendingUtxos
            .map((u) => u.satoshis)
            .toList();
        
        // Verify distribution follows Benford's Law
        final followsBenford = verifyBenfordDistribution(newUtxoAmounts, tolerance: 0.25);
        expect(followsBenford, isTrue,
          reason: 'New UTXO amounts should follow Benford distribution');
        print('✓ New UTXO amounts follow Benford\'s Law');

        print('\nStep 8: Verify transactions recorded in projection');
        final txHistory = await context.storage.getTransactionHistory(walletId);
        print('  Total transactions: ${txHistory.length}');
        
        // Should have original UTXO creation txs + 2 split txs
        expect(txHistory.length, greaterThanOrEqualTo(4),
          reason: 'Should have initial txs + split txs');

        final splitTxs = txHistory.where((tx) {
          final txn = dartsv.Transaction.fromHex(tx.rawHex);
          return txn.inputs.length == 1 && txn.outputs.length == 5;
        }).toList();
        expect(splitTxs.length, greaterThanOrEqualTo(2),
          reason: 'Should have 2 split transactions (1 input -> 5 outputs each)');
        print('✓ Split transactions recorded in projection');

        print('\nStep 9: Verify balance conservation (accounting for fees)');
        final finalBalance = pendingUtxos.fold<BigInt>(
          BigInt.zero,
          (sum, utxo) => sum + utxo.satoshis,
        );
        
        // Calculate total fees from split transactions
        final totalFees = splitTxs.fold<BigInt>(
          BigInt.zero,
          (sum, tx) => sum + tx.fee,
        );
        
        print('  Initial balance: $initialBalance sats');
        print('  Final balance: $finalBalance sats');
        print('  Total fees: $totalFees sats');
        
        expect(finalBalance + totalFees, equals(initialBalance),
          reason: 'Final balance + fees should equal initial balance');
        print('✓ Balance conserved (initial = final + fees)');

        print('\nStep 10: Verify addresses were generated correctly');
        final genAddr = await context.storage.getWalletAddresses(walletId);
        print('  Total addresses: ${addresses.length}');
        
        // Should have generated new addresses for each split output
        expect(genAddr.length, greaterThanOrEqualTo(12),
          reason: 'Should have initial addresses + 10 new addresses for split outputs');
        print('✓ New addresses generated for split outputs');

        print('\n✅ End-to-end Benford split test PASSED\n');
        print('Summary:');
        print('  - Started with 2 UTXOs ($initialBalance sats)');
        print('  - Split into ${pendingUtxos.length} new UTXOs');
        print('  - Created ${splitTxs.length} split transactions');
        print('  - Paid $totalFees sats in fees');
        print('  - Generated ${genAddr.length} addresses');
        print('  - Benford distribution verified ✓');
        
      } finally {
        await context.dispose();
      }
    });
  });
}

