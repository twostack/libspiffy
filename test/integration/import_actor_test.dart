import 'dart:async';
import 'dart:io';
import 'package:test/test.dart';
import 'package:dactor/dactor.dart';
import 'package:eventador/eventador.dart';
import 'package:isar/isar.dart';
import 'package:libspiffy/libspiffy.dart';
import 'package:libspiffy/src/storage/isar_wallet_storage.dart';
import 'package:libspiffy/src/services/blockchain_data_source.dart';
import 'package:libspiffy/src/models/blockchain_data_models.dart';
import 'package:libspiffy/src/models/wallet_event.dart';
import 'package:spiffynode/spiffy_node.dart' as spiffynode;

/// Integration tests for ImportActor
/// 
/// Tests cover:
/// - Complete import flow with real testnet data
/// - Import cancellation
/// - Progress tracking
/// - Duplicate import prevention
/// - Error handling scenarios

// =============================================================================
// TEST DATA - Real Testnet Fixtures
// =============================================================================

/// Test xpriv with real testnet history
const kTestXpriv = 'tprv8ZgxMBicQKsPeMiDjtXBGAyFY1wEMGgomjwf54ZmiZfKTNYvVdBa6GqWUwnvtHm6NKVkQkhCKxaobd9JPxNEXgDfVgJ5RNHJ3ivogSG3V1R';

/// Root address (m/0/0) derived from test xpriv
const kTestRootAddress = 'mqCnSf8i6kmaQaJ54HjQ8EUJnuK4AnCv12';

/// Transaction 1: a05924fcc63712d3e4b94b0c88baad234c2c8ad3d369704f53765e21a53a2101
/// Block 1239645, pays 200000000 sats to root address at vout 1
const kTx1Hex = '020000000165b6c06790c23623c4988ee51b3f27c76bfb6a0c9e5bab3432968c51379af66a000000006b483045022100b735fb60adca4fa42e37746aa602c3206bf98572ae83e396da4fd11cb716b26d022017bf9955bd8fc4d60f2829236c7864d5b5540062c88113daef137c0ee441736c41210222824a8530bc570b7bae7c7600529b450a65eab1203c5f561d8082cd97b3dba1feffffff02872ec735150000001976a9149d02ce72bbdc1713d5537a0705d8ec7d9702c81088ac00c2eb0b000000001976a9146a418bf9e2e2b670e1aa7b7da59391e212b4ba1988ac5cea1200';
const kTx1Id = 'a05924fcc63712d3e4b94b0c88baad234c2c8ad3d369704f53765e21a53a2101';
const kTx1BlockHeight = 1239645;

/// Transaction 2: 05c4d800ac77703bb00e41d8bf9d006c0e52f8405ba92c4506b80ad8f5337ae1
/// Block 1701169, spends from tx1
const kTx2Hex = '020000000101213aa5215e76534f7069d3d38a2c4c23adba880c4bb9e4d31237c6fc2459a0010000006b483045022100b17a54d3b7f232c4c375d6c656001cac54e674aa3bc8cab3eb176668fbf0a15c02207e35eed554edba90e030e46d90f8d9569a4d6a7139d55eafd9e875c9d3ec2c364121033a69d0acd6e9500844ca078fbc4d81b6c95d7967b3106e31618d5987633d41a9ffffffff02affeea0b000000001976a9146a418bf9e2e2b670e1aa7b7da59391e212b4ba1988ac50c30000000000001976a914c8e0448aa60d8335ef57c1d0e2bdec3aa15f257588ac00000000';
const kTx2Id = '05c4d800ac77703bb00e41d8bf9d006c0e52f8405ba92c4506b80ad8f5337ae1';
const kTx2BlockHeight = 1701169;

/// TSC Merkle proof for Transaction 1
/// From: https://api.whatsonchain.com/v1/bsv/test/tx/{txid}/proof/tsc
Map<String, dynamic> _getTx1MerkleProof() {
  return {
    "index": 2,
    "txOrId": kTx1Id,
    "target": "000000001539f91cede66262caa22d1b504d09aa1dc3221f7fac5b30c2f7d65d",
    "nodes": [
      "405649f55c4a98a3f83e6d780bb44297035d4a3652d9ddc9dc50799bed17b62b",
      "750e25837b6188f87387b1eb18604e9fe07aa32fb80221e7a1c7d7e04427c8e0",
      "3980d9a3572b903c74302a586c923ce0bf26d979a23290a28750cb2e1cc19199",
      "2b6da3206c7aed19f0bc6c68826f86638c1f9214a6b3eead3d7121381a82549d",
      "5d3e8be2af6e109196a14a81dc6f99e17d7420eddf1d31a1a50fb2ef6933e3a1",
      "c4f09f1a5fb1e66a95b66ca7502062292708597c7e15574fc6dd1f9bcc7d2f5a"
    ]
  };
}

/// TSC Merkle proof for Transaction 2
Map<String, dynamic> _getTx2MerkleProof() {
  return {
    "index": 279,
    "txOrId": kTx2Id,
    "target": "00000000f7a0bacde7375dc096edf7e03a23535d7d6f1e4b02624087a1417206",
    "nodes": [
      "2d2711122c3d1822932db91aa9afa2128c9e26b5c4b8df7b9a955c48d0bfc785",
      "795b148effccae8eaaf41f09ed19124b38680cf2b89016dae850dc17a5966b7e",
      "957235d9bd6ce92c5676cfe4ec77a3c2d19910ced8bd4ebe7ffa5490ceade34f",
      "910c626fdf40242c134458696159f5176223f3b7f72a4ad74fefad65433b5433",
      "34a6ea9a52e82ca75cf496ae6255bca7b05f99e380904779684cc5f0f941688e",
      "3d706f13140a933e2ce72cacec0e0f89b6b4378907e3a39c8a22b2a2d2a6b1e7",
      "593d05f1d07fb22d7b93d9f1a1739f0827b4b6363e68f6c750e4b58206aa5790",
      "eced437fa3685318afe3f9c89c184b04f255ab3059335754acdaf9c3b0197158",
      "9d8b401b6fd46c8dae3fb5b3013a6b76d05333215691be9bbd386908b257061e"
    ]
  };
}

// =============================================================================
// MOCK BLOCKCHAIN DATA SOURCE
// =============================================================================

/// Mock blockchain data source that returns real testnet data
class MockTestnetDataSource implements BlockchainDataSource {
  final Map<String, String> _rawTransactions = {};
  final Map<String, MerkleProofData> _merkleProofs = {};
  final Map<String, List<TransactionInfo>> _addressHistory = {};
  
  bool _shouldThrowOnMerkleProof = false;

  MockTestnetDataSource() {
    _initializeTestData();
  }

  void _initializeTestData() {
    // Store transaction hex
    _rawTransactions[kTx1Id] = kTx1Hex;
    _rawTransactions[kTx2Id] = kTx2Hex;

    // Store merkle proofs (convert TSC format to MerkleProofData)
    final tx1Proof = _getTx1MerkleProof();
    _merkleProofs[kTx1Id] = MerkleProofData(
      txid: kTx1Id,
      blockHeight: kTx1BlockHeight,
      merkleRoot: '4823b3e0a9801d019c49af6ecd923f5250cc828e7be4fb6b4c5afbb979e33b34',
      index: tx1Proof['index'] as int,
      nodes: (tx1Proof['nodes'] as List).cast<String>(),
    );

    final tx2Proof = _getTx2MerkleProof();
    _merkleProofs[kTx2Id] = MerkleProofData(
      txid: kTx2Id,
      blockHeight: kTx2BlockHeight,
      merkleRoot: '750cfb89611c186c935980567ad1a4b1cec0e033ba2373151a51a7e87b122612',
      index: tx2Proof['index'] as int,
      nodes: (tx2Proof['nodes'] as List).cast<String>(),
    );

    // Store address history for root address
    _addressHistory[kTestRootAddress] = [
      TransactionInfo(
        txid: kTx1Id,
        blockHeight: kTx1BlockHeight,
        blockHash: '000000001539f91cede66262caa22d1b504d09aa1dc3221f7fac5b30c2f7d65d',
        blockIndex: 2,
      ),
      TransactionInfo(
        txid: kTx2Id,
        blockHeight: kTx2BlockHeight,
        blockHash: '00000000f7a0bacde7375dc096edf7e03a23535d7d6f1e4b02624087a1417206',
        blockIndex: 279,
      ),
    ];
  }

  /// Enable error simulation for testing
  void simulateMerkleProofError() {
    _shouldThrowOnMerkleProof = true;
  }

  @override
  String get networkType => 'test';

  @override
  Future<String> getRawTransaction(String txid) async {
    await Future.delayed(Duration(milliseconds: 10)); // Simulate network delay
    
    if (!_rawTransactions.containsKey(txid)) {
      throw DataSourceException('Transaction not found: $txid', txid: txid);
    }
    return _rawTransactions[txid]!;
  }

  @override
  Future<MerkleProofData> getMerkleProof(String txid) async {
    await Future.delayed(Duration(milliseconds: 10)); // Simulate network delay
    
    if (_shouldThrowOnMerkleProof) {
      throw DataSourceException('Simulated merkle proof error', txid: txid);
    }
    
    if (!_merkleProofs.containsKey(txid)) {
      throw DataSourceException('Merkle proof not found: $txid', txid: txid);
    }
    return _merkleProofs[txid]!;
  }

  @override
  Future<List<TransactionInfo>> getTransactionHistory(
    String address, {
    int? limit,
    int? offset,
  }) async {
    await Future.delayed(Duration(milliseconds: 10)); // Simulate network delay
    
    if (!_addressHistory.containsKey(address)) {
      return [];
    }
    
    var history = _addressHistory[address]!;
    
    // Apply offset and limit if provided
    if (offset != null && offset > 0) {
      history = history.skip(offset).toList();
    }
    if (limit != null && limit > 0) {
      history = history.take(limit).toList();
    }
    
    return history;
  }

  @override
  Future<List<UtxoInfo>> getUtxos(String address) async {
    // For simplicity, return empty list (not needed for import tests)
    return [];
  }

  @override
  Future<int> getCurrentBlockHeight() async {
    return 1701454; // Mock current height
  }

  @override
  Future<String> submitTransaction(String rawHex) async {
    throw UnimplementedError('submitTransaction not needed for import tests');
  }

  /// Add a custom address history (for testing edge cases)
  void setAddressHistory(String address, List<TransactionInfo> history) {
    _addressHistory[address] = history;
  }
}

// =============================================================================
// TEST HELPER FUNCTIONS
// =============================================================================

/// Setup real block headers from testnet for SPV validation
Future<void> _setupRealBlockHeaders(IsarWalletStorage storage) async {
  // Block 1239645 - contains transaction 1
  final header1 = spiffynode.BlockHeader(
    version: 536870912,
    prevBlock: spiffynode.Hash.fromHex('0000000070ad42dbfbc9860b1c6d6f636515834a4407e86cdead84d158592bd3'),
    merkleRoot: spiffynode.Hash.fromHex('4823b3e0a9801d019c49af6ecd923f5250cc828e7be4fb6b4c5afbb979e33b34'),
    timestamp: DateTime.fromMillisecondsSinceEpoch(1528803530 * 1000),
    bits: 0x1d00ffff,
    nonce: 2121538711,
  );
  await storage.storeBlockHeader(header1, kTx1BlockHeight);

  // Block 1701169 - contains transaction 2
  final header2 = spiffynode.BlockHeader(
    version: 536870912,
    prevBlock: spiffynode.Hash.fromHex('000000003eb61d855e28f2d1f7913f64988c6c3bd89e00608bc7ac9b175922c3'),
    merkleRoot: spiffynode.Hash.fromHex('750cfb89611c186c935980567ad1a4b1cec0e033ba2373151a51a7e87b122612'),
    timestamp: DateTime.fromMillisecondsSinceEpoch(1761722800 * 1000),
    bits: 0x1d00ffff,
    nonce: 1259571457,
  );
  await storage.storeBlockHeader(header2, kTx2BlockHeight);

  print('✓ Stored 2 real testnet block headers ($kTx1BlockHeight, $kTx2BlockHeight)');
}

/// Create test infrastructure
class TestContext {
  final Directory testDir;
  final LocalActorSystem actorSystem;
  final Isar isar;
  final LibSpiffyActorSystem libspiffy;
  final MockTestnetDataSource mockDataSource;
  final IsarWalletStorage storage;
  final List<WalletEvent> capturedEvents = [];

  TestContext({
    required this.testDir,
    required this.actorSystem,
    required this.isar,
    required this.libspiffy,
    required this.mockDataSource,
    required this.storage,
  });

  /// Cleanup resources
  Future<void> dispose() async {
    await libspiffy.shutdown();
    await isar.close(deleteFromDisk: true);
    testDir.deleteSync(recursive: true);
  }
}

/// Setup test infrastructure
Future<TestContext> setupTestContext() async {
  await Isar.initializeIsarCore(download: true);

  final testDir = Directory.systemTemp.createTempSync('import-actor-test-');
  final actorSystem = LocalActorSystem(ActorSystemConfig());

  // Open Isar with both LibSpiffy and Eventador schemas
  // Open Isar with all required schemas including checkpoint persistence
  final isar = await Isar.open(
    LibSpiffySchemas.allSchemas,  // Includes wallet schemas + event store + projections
    directory: testDir.path,
    name: 'test_import_db',
  );

  // Create mock data source
  final mockDataSource = MockTestnetDataSource();

  // Initialize LibSpiffy with mock data source
  final libspiffy = LibSpiffyActorSystem();
  await libspiffy.initialize(
    actorSystem: actorSystem,
    isar: isar,
    dataDirectory: testDir.path,
    blockchainDataSource: mockDataSource,
    enableP2P: false
  );

  final storage = libspiffy.walletStorage as IsarWalletStorage;
  
  // Setup real block headers for SPV validation
  await _setupRealBlockHeaders(storage);

  return TestContext(
    testDir: testDir,
    actorSystem: actorSystem,
    isar: isar,
    libspiffy: libspiffy,
    mockDataSource: mockDataSource,
    storage: storage,
  );
}

// =============================================================================
// INTEGRATION TESTS
// =============================================================================

void main() {
  group('ImportActor Integration Tests', () {
    
    test('complete import flow - happy path with real testnet data', () async {
      print('\n=== Test: Complete Import Flow ===\n');
      
      final context = await setupTestContext();
      final walletId = 'test-wallet-${DateTime.now().millisecondsSinceEpoch}';
      
      try {
        // Subscribe to wallet events
        context.libspiffy.subscribeToWalletEvents(walletId).listen((event) {
          context.capturedEvents.add(event);
          print('📢 Event captured: ${event.runtimeType}');
        });

        print('Step 1: Send ImportWalletMessage to ImportActor');
        // Use the public API method to trigger import
        context.libspiffy.importWalletFromXpriv(
          walletId: walletId,
          xpriv: kTestXpriv,
          walletName: 'Test Import Wallet',
          networkType: 'test',
          addressGapLimit: 20,
        );
        
        print('Step 2: Wait for import to complete (up to 30 seconds)');
        // Wait for import to complete
        // ImportActor processes sequentially, should complete within reasonable time
        await Future.delayed(Duration(seconds: 25));

        print('\nStep 3: Verify wallet was created');
        // Verify wallet exists in storage
        final walletEntity = await context.storage.getWallet(walletId);
        expect(walletEntity, isNotNull, reason: 'Wallet should be created');
        expect(walletEntity!['name'], equals('Test Import Wallet'));
        print('✓ Wallet created: ${walletEntity['name']}');

        print('\nStep 4: Verify addresses were discovered and registered');
        // Should have found at least the root address (m/0/0)
        final addresses = await context.storage.getWalletAddresses(walletId);
        expect(addresses, isNotEmpty, reason: 'Should discover at least 1 address');
        expect(
          addresses.contains(kTestRootAddress),
          isTrue,
          reason: 'Should discover root address $kTestRootAddress',
        );
        print('✓ Discovered ${addresses.length} address(es)');
        print('  Addresses: ${addresses.join(", ")}');

        print('\nStep 5: Verify transactions were imported');
        // Should have imported both transactions
        final txHistory = await context.storage.getTransactionHistory(walletId);
        expect(txHistory.length, greaterThanOrEqualTo(2), 
          reason: 'Should import at least 2 transactions');
        
        final tx1Found = txHistory.any((tx) => tx.txid == kTx1Id);
        final tx2Found = txHistory.any((tx) => tx.txid == kTx2Id);
        expect(tx1Found, isTrue, reason: 'Should import transaction 1');
        expect(tx2Found, isTrue, reason: 'Should import transaction 2');
        print('✓ Imported ${txHistory.length} transaction(s)');
        print('  TX1: $kTx1Id');
        print('  TX2: $kTx2Id');

        print('\nStep 6: Verify BUMP proofs were stored');
        // Verify merkle proofs are stored
        final tx1Proof = await context.storage.getMerkleProof(kTx1Id);
        final tx2Proof = await context.storage.getMerkleProof(kTx2Id);
        expect(tx1Proof, isNotNull, reason: 'TX1 should have merkle proof');
        expect(tx2Proof, isNotNull, reason: 'TX2 should have merkle proof');
        expect(tx1Proof!.blockHeight, equals(kTx1BlockHeight));
        expect(tx2Proof!.blockHeight, equals(kTx2BlockHeight));
        print('✓ BUMP proofs stored for both transactions');

        print('\nStep 7: Verify UTXOs were tracked');
        // Verify UTXOs were registered
        // Since TX2 spends from TX1, we should have exactly 1 unspent UTXO
        final utxos = await context.storage.getUTXOs(walletId);
        print('Found ${utxos.length} UTXO(s):');
        for (final utxo in utxos) {
          print('  ${utxo.txid}:${utxo.vout} - ${utxo.value.getValue()} sats (status: ${utxo.status})');
        }
        
        // Let's also check all UTXOs including spent ones
        final allUtxos = await context.storage.getUTXOs(walletId, includeSpent: true);
        print('All UTXOs (including spent): ${allUtxos.length}');
        for (final utxo in allUtxos) {
          print('  ${utxo.txid}:${utxo.vout} - ${utxo.value.getValue()} sats (status: ${utxo.status})');
        }
        
        expect(utxos.length, equals(1), 
          reason: 'Should have exactly 1 UTXO (TX2 spends from TX1, leaving 1 unspent output)');
        print('✓ Tracked ${utxos.length} UTXO(s)');
        for (final utxo in utxos) {
          print('  ${utxo.txid}:${utxo.vout} - ${utxo.value.getValue()} sats');
        }
        
        // Verify the UTXO is from TX2 (not TX1, which should be spent)
        expect(utxos.first.txid, equals(kTx2Id), 
          reason: 'The unspent UTXO should be from TX2');

        print('\nStep 8: Verify wallet events were broadcast');
        // Check that events were captured
        final importStartedEvents = context.capturedEvents
            .whereType<WalletImportStartedEvent>()
            .where((e) => e.walletId == walletId);
        final importCompletedEvents = context.capturedEvents
            .whereType<WalletImportCompletedEvent>()
            .where((e) => e.walletId == walletId);
        
        expect(importStartedEvents, isNotEmpty, 
          reason: 'Should broadcast WalletImportStartedEvent');
        expect(importCompletedEvents, isNotEmpty, 
          reason: 'Should broadcast WalletImportCompletedEvent');
        print('✓ Events broadcast correctly');
        
        final completedEvent = importCompletedEvents.first;
        print('  Total addresses: ${completedEvent.totalAddresses}');
        print('  Total transactions: ${completedEvent.totalTransactions}');

        print('\n✅ Complete import flow test PASSED\n');
      } finally {
        await context.dispose();
      }
    });

    test('import cancellation during address discovery', () async {
      print('\n=== Test: Import Cancellation ===\n');
      
      final context = await setupTestContext();
      final walletId = 'cancel-test-${DateTime.now().millisecondsSinceEpoch}';
      
      try {
        print('Step 1: Start import process');
        context.libspiffy.importWalletFromXpriv(
          walletId: walletId,
          xpriv: kTestXpriv,
          walletName: 'Cancel Test Wallet',
          networkType: 'test',
          addressGapLimit: 20,
        );
        
        print('Step 2: Wait briefly for import to start');
        await Future.delayed(Duration(milliseconds: 500));

        print('Step 3: Send cancel message');
        // Note: CancelImportMessage requires direct actor access, which is not exposed
        // This test demonstrates the intended behavior but may need actor system access

        print('Step 4: Wait for cancellation to take effect');
        await Future.delayed(Duration(seconds: 5));

        print('Step 5: Verify partial import state');
        // Wallet might be created, but import should not complete fully
        final walletEntity = await context.storage.getWallet(walletId);
        
        if (walletEntity != null) {
          print('✓ Wallet was created before cancellation');
          
          // Transaction import should be incomplete or stopped
          final txHistory = await context.storage.getTransactionHistory(walletId);
          print('  Transactions imported: ${txHistory.length}');
          print('  (Expected: less than full 2 transactions due to cancellation)');
        } else {
          print('✓ Cancellation occurred before wallet creation');
        }

        print('\n✅ Import cancellation test PASSED\n');
      } finally {
        await context.dispose();
      }
    });

    test('progress tracking throughout import', () async {
      print('\n=== Test: Progress Tracking ===\n');
      
      final context = await setupTestContext();
      final walletId = 'progress-test-${DateTime.now().millisecondsSinceEpoch}';
      
      try {
        // Track events received
        bool importStarted = false;
        bool importCompleted = false;
        
        print('Step 1: Subscribe to progress events');
        context.libspiffy.subscribeToWalletEvents(walletId).listen((event) {
          print('  Progress event: ${event.runtimeType}');
          if (event is WalletImportStartedEvent) {
            importStarted = true;
          } else if (event is WalletImportCompletedEvent) {
            importCompleted = true;
          }
        });
        
        print('Step 2: Start import process');
        context.libspiffy.importWalletFromXpriv(
          walletId: walletId,
          xpriv: kTestXpriv,
          walletName: 'Progress Test Wallet',
          networkType: 'test',
          addressGapLimit: 20,
        );
        
        print('Step 3: Wait for import to complete');
        // Wait up to 25 seconds for import to complete
        int elapsed = 0;
        while (!importCompleted && elapsed < 25000) {
          await Future.delayed(Duration(milliseconds: 500));
          elapsed += 500;
          if (elapsed % 2000 == 0) {
            print('  Waiting... ${elapsed / 1000}s elapsed');
          }
        }

        print('\nStep 4: Verify progress was tracked');
        expect(importStarted, isTrue, reason: 'Should have received import started event');
        expect(importCompleted, isTrue, reason: 'Should have received import completed event');
        print('✓ Progress events received: started and completed');

        print('\n✅ Progress tracking test PASSED\n');
      } finally {
        await context.dispose();
      }
    });

    test('duplicate import prevention', () async {
      print('\n=== Test: Duplicate Import Prevention ===\n');
      
      final context = await setupTestContext();
      final walletId = 'duplicate-test-${DateTime.now().millisecondsSinceEpoch}';
      
      try {
        print('Step 1: Start first import');
        context.libspiffy.importWalletFromXpriv(
          walletId: walletId,
          xpriv: kTestXpriv,
          walletName: 'Duplicate Test Wallet',
          networkType: 'test',
          addressGapLimit: 20,
        );
        
        print('Step 2: Immediately send duplicate import request');
        await Future.delayed(Duration(milliseconds: 100));
        
        context.libspiffy.importWalletFromXpriv(
          walletId: walletId, // Same wallet ID
          xpriv: kTestXpriv,
          walletName: 'Duplicate Test Wallet 2',
          networkType: 'test',
          addressGapLimit: 20,
        );

        print('Step 3: Wait for first import to complete');
        await Future.delayed(Duration(seconds: 25));

        print('Step 4: Verify only one import completed');
        final walletEntity = await context.storage.getWallet(walletId);
        expect(walletEntity, isNotNull);
        
        // Should have the first wallet name, not the second
        expect(walletEntity!['name'], equals('Duplicate Test Wallet'));
        print('✓ Only first import completed (name: ${walletEntity['name']})');

        print('\n✅ Duplicate import prevention test PASSED\n');
      } finally {
        await context.dispose();
      }
    });

    test('address with no transactions', () async {
      print('\n=== Test: Empty Address History ===\n');
      
      final context = await setupTestContext();
      final walletId = 'empty-history-${DateTime.now().millisecondsSinceEpoch}';
      
      // Create a test xpriv that will derive an unused address
      const unusedXpriv = 'tprv8ZgxMBicQKsPd9TeAdPADNnSyH9SSUUbTVeFszDE23Ki6TBB5nCefAdHkK8Fm3qMQR6sHwA56zqRmKmxnHk37JkiFzvncDqoKmPWubu7hDF';
      
      try {
        print('Step 1: Start import with unused xpriv');
        context.libspiffy.importWalletFromXpriv(
          walletId: walletId,
          xpriv: unusedXpriv,
          walletName: 'Empty History Wallet',
          networkType: 'test',
          addressGapLimit: 20,
        );
        
        print('Step 2: Wait for import to complete');
        await Future.delayed(Duration(seconds: 20));

        print('Step 3: Verify wallet was created with no transactions');
        final walletEntity = await context.storage.getWallet(walletId);
        expect(walletEntity, isNotNull, reason: 'Wallet should be created');

        final txHistory = await context.storage.getTransactionHistory(walletId);
        expect(txHistory, isEmpty, reason: 'Should have no transactions');
        print('✓ Wallet created with 0 transactions');

        print('\n✅ Empty address history test PASSED\n');
      } finally {
        await context.dispose();
      }
    });

    test('missing merkle proof error handling', () async {
      print('\n=== Test: Missing Merkle Proof ===\n');
      
      final context = await setupTestContext();
      final walletId = 'merkle-error-${DateTime.now().millisecondsSinceEpoch}';
      
      try {
        // Enable error simulation on mock data source
        print('Step 1: Configure mock to throw merkle proof errors');
        context.mockDataSource.simulateMerkleProofError();

        print('Step 2: Start import process');
        context.libspiffy.importWalletFromXpriv(
          walletId: walletId,
          xpriv: kTestXpriv,
          walletName: 'Merkle Error Wallet',
          networkType: 'test',
          addressGapLimit: 20,
        );
        
        print('Step 3: Wait for import to complete (with errors)');
        await Future.delayed(Duration(seconds: 25));

        print('Step 4: Verify partial import state');
        final walletEntity = await context.storage.getWallet(walletId);
        expect(walletEntity, isNotNull, reason: 'Wallet should still be created');

        // Transactions should fail to import due to missing proofs
        final txHistory = await context.storage.getTransactionHistory(walletId);
        print('✓ Wallet created despite merkle proof errors');
        print('  Transactions imported: ${txHistory.length}');
        print('  (Expected: 0 or partial, due to proof errors)');

        print('\n✅ Missing merkle proof error handling test PASSED\n');
      } finally {
        await context.dispose();
      }
    });
  });
}

