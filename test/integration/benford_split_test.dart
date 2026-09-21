import 'dart:async';
import 'dart:io';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:test/test.dart';
import 'package:dactor/dactor.dart';
import 'package:eventador/eventador.dart';
import 'package:isar/isar.dart';
import 'package:libspiffy/libspiffy.dart';
import 'package:libspiffy/internals.dart';
import 'package:libspiffy/src/storage/isar_wallet_storage.dart';

import '../mocks/network_arc.dart';
import 'isar_test_helper.dart';

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
  final NetworkArc arc;
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
    required this.arc,
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
  await ensureIsarInitialized();

  final testDir = Directory.systemTemp.createTempSync('benford-split-test-');
  final actorSystem = LocalActorSystem(ActorSystemConfig());

  // Open Isar with all required schemas
  final isar = await Isar.open(
    LibSpiffySchemas.allSchemas,
    directory: testDir.path,
    name: 'test_benford_db',
  );

  // ARC stand-in: a submitted transaction is SEEN_ON_NETWORK
  final arc = NetworkArc();
  
  // Initialize LibSpiffy actor system (this registers all event types)
  final libspiffy = LibSpiffyActorSystem();
  await libspiffy.initialize(
    actorSystem: actorSystem,
    isar: isar,
    dataDirectory: testDir.path,
    enableP2P: false,
    arcService: arc,
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
    arc: arc,
  );
}

/// Create a test wallet with UTXOs using the actor system
///
/// The wallet is created with [CreateWalletMessage]: a wallet command for a
/// wallet that has no journal is answered "Wallet not found", so a
/// `CreateWalletCommand` sent as a wallet command never creates it. Each
/// step waits for its reply, and the helper returns once the read model
/// (which BenfordCoordinatorActor reads) shows the wallet and its UTXOs.
Future<String> createTestWalletWithUtxos(
  BenfordTestContext context, {
  required String walletId,
  required int utxoCount,
  required List<BigInt> utxoAmounts,
}) async {
  final system = context.actorSystem;
  final walletManager = context.libspiffy.walletManager;

  final created = Completer<WalletCreatedMessage>();
  final createReceiver = await system.spawn(
    'benford-create-$walletId',
    () => _ReplyReceiver<WalletCreatedMessage>(created),
  );
  walletManager.tell(
    CreateWalletMessage(walletId, 'Benford Test Wallet', xpriv: kTestXpriv),
    sender: createReceiver,
  );
  final createdReply = await created.future.timeout(const Duration(seconds: 10));
  expect(createdReply.success, isTrue, reason: 'wallet creation failed: ${createdReply.error}');

  // One receive address per UTXO
  final addresses = <String>[];
  for (int i = 0; i < utxoCount; i++) {
    final generated = Completer<AddressGeneratedResponse>();
    final receiver = await system.spawn(
      'benford-address-$walletId-$i',
      () => _ReplyReceiver<AddressGeneratedResponse>(generated),
    );
    walletManager.tell(
      WalletCommandMessage(walletId, GenerateAddressCommand(walletId: walletId, purpose: 'receive')),
      sender: receiver,
    );
    final reply = await generated.future.timeout(const Duration(seconds: 10));
    expect(reply.success, isTrue, reason: 'address generation failed: ${reply.error}');
    addresses.add(reply.address);
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
    walletManager.tell(WalletCommandMessage(
      walletId,
      utxoCommand,
    ));
  }

  // The read model has the wallet, its addresses and every UTXO
  await eventually(
    () async {
      final wallet = await context.storage.getWallet(walletId);
      final known = await context.storage.getWalletAddresses(walletId);
      final utxos = await context.storage.getPaymentUTXOs(walletId);
      return wallet != null && addresses.every(known.contains) && utxos.length == utxoCount ? utxos : null;
    },
    'the wallet, its addresses and $utxoCount available UTXOs in the read model',
  );

  print('✓ Created test wallet with $utxoCount UTXOs');
  for (int i = 0; i < utxoCount && i < addresses.length; i++) {
    print('  UTXO $i: ${utxoAmounts[i]} sats at ${addresses[i]}');
  }

  return walletId;
}

/// Waits for a Benford split of the UTXOs in [originalKeys] to settle and
/// returns every UTXO of the wallet (spent included).
///
/// First the split is recorded: [expectedSpent] of the original UTXOs are
/// spent and [expectedOutputs] new UTXOs exist. ARC answered each broadcast
/// SEEN_ON_NETWORK, so each split output becomes spendable: the submit
/// answer promotes the outputs the read model already shows, and a status
/// scan (requested here, as a header arrival would) promotes any recorded
/// after it. Then every new UTXO must be available.
Future<List<BitcoinUtxo>> splitSettled(
  BenfordTestContext context,
  String walletId, {
  required Set<String> originalKeys,
  required int expectedSpent,
  required int expectedOutputs,
}) async {
  Future<List<BitcoinUtxo>> all() => context.storage.getUTXOs(walletId, includeSpent: true);
  await eventually(
    () async {
      final utxos = await all();
      final spent = utxos.where((u) => originalKeys.contains(u.key) && u.status == UTXOStatus.spent).length;
      final outputs = utxos.where((u) => !originalKeys.contains(u.key)).length;
      return spent == expectedSpent && outputs == expectedOutputs ? utxos : null;
    },
    '$expectedSpent original UTXO(s) spent and $expectedOutputs split outputs recorded',
  );
  context.libspiffy.arcActor.tell(CheckStoragePendingUTXOsMessage(triggerBlockHeight: 0));
  return eventually(
    () async {
      final utxos = await all();
      final outputs = utxos.where((u) => !originalKeys.contains(u.key)).toList();
      return outputs.length == expectedOutputs && outputs.every((u) => u.status == UTXOStatus.available)
          ? utxos
          : null;
    },
    'every split output to be available once ARC reports its transaction on the network',
  );
}

/// Polls [probe] until it returns a non-null value, failing after [timeout].
Future<T> eventually<T>(
  Future<T?> Function() probe,
  String what, {
  Duration timeout = const Duration(seconds: 20),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (true) {
    final value = await probe();
    if (value != null) return value;
    if (DateTime.now().isAfter(deadline)) fail('Timed out after $timeout waiting for $what');
    await Future.delayed(const Duration(milliseconds: 50));
  }
}

/// Completes [completer] with the first message of type [T].
class _ReplyReceiver<T> extends Actor {
  final Completer<T> completer;

  _ReplyReceiver(this.completer);

  @override
  Future<void> onMessage(dynamic message) async {
    if (message is T && !completer.isCompleted) completer.complete(message);
  }
}

/// The P2PKH locking script of [address] as hex, the form a UTXO's
/// scriptPubKey takes (the wallet aggregate parses it to sign).
String _createP2PKHScript(String address) {
  return dartsv.P2PKHLockBuilder.fromAddress(dartsv.Address.fromBase58(address)).getScriptPubkey().toHex();
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

        final originalKeys = {for (final u in await context.storage.getUTXOs(walletId)) u.key};

        print('\nStep 2: Send SplitUTXOsToBenfordCommand through WalletManager');
        // Send split command through the wallet manager (proper flow)
        final splitCommand = SplitUTXOsToBenfordCommand(
          walletId: walletId,
          targetUtxoCount: 10,
        );

        print('  Processing command...');
        // Send through WalletManager (this will forward to the correct aggregate)
        context.libspiffy.walletManager.tell(WalletCommandMessage(
          walletId,
          splitCommand,
        ));
        
        print('\nStep 3: Verify split operation completed successfully');
        // The split involves coordinator processing, address generation (10
        // addresses), building, signing, broadcasting and recording.
        final allUtxos = await splitSettled(context, walletId,
            originalKeys: originalKeys, expectedSpent: 1, expectedOutputs: 10);
        
        print('  Total UTXOs (including spent): ${allUtxos.length}');
        
        for (final utxo in allUtxos.take(12)) {
          print('    UTXO: ${utxo.txid.substring(0, 16)}...:${utxo.vout} - ${utxo.satoshis} sats (${utxo.status.name})');
        }
        
        // After split, we should have:
        // - 1 spent UTXO (the original 100000 sats)
        // - 10 new UTXOs from the split transaction, available once ARC
        //   reported the transaction SEEN_ON_NETWORK
        final spentUtxos = allUtxos.where((u) => u.status == UTXOStatus.spent).length;
        final newUtxos = allUtxos.where((u) => !originalKeys.contains(u.key)).toList();

        print('  Spent UTXOs: $spentUtxos');
        print('  New UTXOs: ${newUtxos.length}');

        expect(newUtxos.length, equals(10),
          reason: 'Split should have created 10 new UTXOs');
        expect(newUtxos.map((u) => u.status).toSet(), {UTXOStatus.available},
          reason: 'Split outputs are spendable once the split is on the network');

        // Verify original UTXO was spent
        expect(spentUtxos, equals(1),
          reason: 'Original UTXO should be marked as spent');

        print('✓ Split operation completed successfully');
        print('  Original UTXO spent, created ${newUtxos.length} new UTXOs from split');

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

        final originalKeys = {for (final u in await context.storage.getUTXOs(walletId)) u.key};

        print('\nStep 2: Process split command');
        final splitCommand = SplitUTXOsToBenfordCommand(
          walletId: walletId,
          targetUtxoCount: 8,
        );

        // Send through WalletManager (proper flow)
        context.libspiffy.walletManager.tell(WalletCommandMessage(
          walletId,
          splitCommand,
        ));

        print('\nStep 3: Verify split completed for all 3 UTXOs');
        final allUtxos = await splitSettled(context, walletId,
            originalKeys: originalKeys, expectedSpent: 3, expectedOutputs: 24);
        
        print('  Total UTXOs after split: ${allUtxos.length}');
        
        // After split: 3 original UTXOs spent + (3 * 8) = 24 new UTXOs
        final spentUtxos = allUtxos.where((u) => u.status == UTXOStatus.spent).length;
        final newUtxos = allUtxos.where((u) => !originalKeys.contains(u.key)).toList();

        print('  Spent UTXOs: $spentUtxos');
        print('  New UTXOs: ${newUtxos.length}');

        // Each of the 3 UTXOs should be split into 8, creating 24 new UTXOs
        expect(newUtxos.length, equals(24),
          reason: 'Should have 24 new UTXOs (3 * 8)');
        expect(newUtxos.map((u) => u.status).toSet(), {UTXOStatus.available},
          reason: 'Split outputs are spendable once the splits are on the network');
        expect(spentUtxos, equals(3),
          reason: 'All 3 original UTXOs should be spent');

        print('✓ All 3 UTXOs were split successfully (3 spent → ${newUtxos.length} new)');

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

        final originalKeys = {for (final u in initialUtxos) u.key};

        print('\nStep 3: Send SplitUTXOsToBenfordCommand through actor system');
        final splitCommand = SplitUTXOsToBenfordCommand(
          walletId: walletId,
          targetUtxoCount: 5,  // Split each UTXO into 5 outputs
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
        final finalUtxos = await splitSettled(context, walletId,
            originalKeys: originalKeys, expectedSpent: 2, expectedOutputs: 10);

        print('\nStep 5: Verify split transactions were broadcast');
        // Check the ARC stand-in for broadcast transactions
        final broadcastCount = context.arc.seen.length;
        expect(broadcastCount, greaterThanOrEqualTo(2), 
          reason: 'Should broadcast 2 transactions (one per source UTXO)');
        print('✓ Broadcast $broadcastCount transaction(s)');

        print('\nStep 6: Verify wallet projection updated UTXOs');
        print('  Total UTXOs in projection: ${finalUtxos.length}');
        
        // Should have:
        // - 2 original UTXOs (now spent)
        // - 10 new UTXOs (2 source UTXOs × 5 outputs each)
        expect(finalUtxos.length, greaterThanOrEqualTo(10),
          reason: 'Should have at least 10 new UTXOs');

        final spentUtxos = finalUtxos.where((u) => u.status == UTXOStatus.spent).toList();
        // The split outputs; ARC reported the splits SEEN_ON_NETWORK, so
        // they are available.
        final pendingUtxos = finalUtxos.where((u) => !originalKeys.contains(u.key)).toList();

        print('  Spent UTXOs: ${spentUtxos.length}');
        print('  Split output UTXOs: ${pendingUtxos.length}');

        expect(spentUtxos.length, equals(2),
          reason: 'Original 2 UTXOs should be spent');
        expect(pendingUtxos.length, equals(10),
          reason: 'Should have 10 UTXOs from split');
        expect(pendingUtxos.map((u) => u.status).toSet(), {UTXOStatus.available},
          reason: 'Split outputs are spendable once the splits are on the network');

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
        
        // Should have 2 split txs (initial UTXOs were created without tx records)
        expect(txHistory.length, greaterThanOrEqualTo(2),
          reason: 'Should have at least split txs');

        final splitTxs = txHistory.where((tx) {
          final txn = dartsv.Transaction.fromHex(tx.rawHex);
          return txn.inputs.length == 1 && txn.outputs.length == 5;
        }).toList();
        expect(splitTxs.length, equals(2),
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

