import 'dart:async';
import 'dart:io';
import 'package:convert/convert.dart';
import 'package:test/test.dart';
import 'package:dactor/dactor.dart';
import 'package:isar/isar.dart';
import 'package:eventador/eventador.dart';
import 'package:libspiffy/libspiffy.dart';
import 'package:libspiffy/src/actors/payment_messages.dart';
import 'package:libspiffy/src/actors/wallet_messages.dart';
import 'package:libspiffy/src/core/wallet_commands.dart';
import 'package:libspiffy/src/storage/isar_wallet_storage.dart';
import 'package:libspiffy/src/storage/libspiffy_schemas.dart';
import 'package:libspiffy/src/utils/crypto_utils.dart';
import 'package:spiffynode/spiffy_node.dart';

/// Integration test for transaction record-keeping after payment creation
/// 
/// This test validates that:
/// 1. After payment creation, transactions are recorded in transaction history
/// 2. UTXO state is updated correctly
/// 3. Transaction details (inputs, outputs, fees) are accurately captured
void main() {
  group('Transaction History Record-Keeping Integration Tests', () {
    late Directory testDir;
    late Isar isar;
    late LocalActorSystem actorSystem;
    late LibSpiffyActorSystem libspiffy;
    late IsarWalletStorage storage;
    
    setUp(() async {
      print('\n═══════════════════════════════════════════════');
      print('Setting up Transaction History Record-Keeping Test');
      print('═══════════════════════════════════════════════\n');
      
      // Initialize Isar
      await Isar.initializeIsarCore(download: true);
      
      // Create temporary directory for test database
      testDir = await Directory.systemTemp.createTemp('tx_history_test_');
      print('✓ Test directory created: ${testDir.path}');
      
      // Open Isar with LibSpiffy and Eventador schemas
      isar = await Isar.open(
        [
          ...LibSpiffySchemas.walletSchemas,
          ...IsarEventStore.requiredSchemas,
        ],
        directory: testDir.path,
        name: 'tx_history_test_${DateTime.now().millisecondsSinceEpoch}',
      );
      print('✓ Isar database opened');
      
      // Create actor system
      actorSystem = LocalActorSystem(ActorSystemConfig());
      
      // Initialize LibSpiffyActorSystem for complete actor setup
      libspiffy = LibSpiffyActorSystem();
      await libspiffy.initialize(
        actorSystem: actorSystem,
        isar: isar,
        dataDirectory: testDir.path,
        enableP2P: false,
      );
      
      storage = libspiffy.walletStorage as IsarWalletStorage;
      
      // Store real block headers for SPV validation
      await _setupRealBlockHeaders(storage);
      
      print('✓ LibSpiffy actor system initialized with Isar storage\n');
    });
    
    tearDown(() async {
      print('\n─────────────────────────────────────────────');
      print('Cleaning up...');
      
      try {
        await libspiffy.shutdown();
        await isar.close(deleteFromDisk: true);
        await testDir.delete(recursive: true);
        print('✓ Test directory cleaned up');
      } catch (e) {
        print('⚠️  Cleanup error: $e');
      }
      
      print('✓ Cleanup complete');
      print('═══════════════════════════════════════════════\n');
    });
    
    test('Wallet records payment transaction in history after successful creation', () async {
      print('═══ Test: Transaction Record-Keeping After Payment ═══\n');
      
      // Step 1: Setup test wallet ID
      final testWalletId = 'test-wallet-${DateTime.now().millisecondsSinceEpoch}';
      print('✓ Test wallet ID: $testWalletId');
      
      // Step 2: Create the wallet using xpriv (same as payment_api_test.dart)
      // This xpriv corresponds to the "abandon..." mnemonic and generates m/0/0 address mqCnSf8i6kmaQaJ54HjQ8EUJnuK4AnCv12
      const xPrivKey = 'tprv8ZgxMBicQKsPeMiDjtXBGAyFY1wEMGgomjwf54ZmiZfKTNYvVdBa6GqWUwnvtHm6NKVkQkhCKxaobd9JPxNEXgDfVgJ5RNHJ3ivogSG3V1R';
      
      final createWalletCompleter = Completer<WalletCreatedMessage>();
      final createWalletReceiver = await actorSystem.spawn(
        'create-wallet-receiver',
        () => _TestReceiverActor<WalletCreatedMessage>(createWalletCompleter),
      );
      
      libspiffy.walletManager.tell(
        CreateWalletMessage(
          testWalletId,
          'Test Wallet',
          xpriv: xPrivKey,
        ),
        sender: createWalletReceiver,
      );
      
      final walletCreated = await createWalletCompleter.future.timeout(Duration(seconds: 5));
      expect(walletCreated.success, isTrue, reason: 'Wallet creation should succeed');
      print('✓ Wallet created: $testWalletId');
      print('  Root address: ${walletCreated.rootAddress}');
      
      // Wait for wallet creation to be fully processed
      await Future.delayed(Duration(milliseconds: 1000));
      
      // Step 3: Fund the wallet with a test UTXO
      // This uses a real testnet transaction that pays to the wallet's m/0/0 address
      final testTxid = 'a05924fcc63712d3e4b94b0c88baad234c2c8ad3d369704f53765e21a53a2101';
      final testBlockHeight = 1239645;
      final testTxHex = _getTestTransactionHex();
      final testAddress = 'mqCnSf8i6kmaQaJ54HjQ8EUJnuK4AnCv12'; // m/0/0 from test mnemonic
      
      print('\n✓ Funding wallet with test UTXO:');
      print('  TXID: $testTxid');
      print('  Address: $testAddress');
      print('  Amount: 200000000 sats (2 BSV)');
      
      // Import the funding transaction
      final proofJson = _getTestMerkleProof();
      final bump = CryptoUtils.createBumpFromTscProof(proofJson, testBlockHeight);
      final bumpHex = hex.encode(bump.serialize());
      
      libspiffy.walletManager.tell(
        WalletCommandMessage(
          testWalletId,
          RecordImportedTransactionCommand(
            walletId: testWalletId,
            txid: testTxid,
            rawHex: testTxHex,
            blockHeight: testBlockHeight,
            bumpProofHex: bumpHex,
            totalOutputSats: 91296559239,
            numInputs: 1,
            numOutputs: 2,
            txVersion: 2,
            txLockTime: 1239644,
            walletReceivingAddresses: [testAddress],
            walletReceivedSats: 200000000,
            totalInputSats: 91296563777,
            sendingAddresses: ['n3u5CyoJwQMzrQL1NoooagCxLJQrJdWEA1'],
          ),
        ),
      );
      
      await Future.delayed(Duration(milliseconds: 300));
      
      // Create the UTXO
      libspiffy.walletManager.tell(
        WalletCommandMessage(
          testWalletId,
          ReceiveUTXOCommand(
            walletId: testWalletId,
            txid: testTxid,
            vout: 1,
            satoshis: BigInt.from(200000000), // 2 BSV
            scriptPubKey: '76a9146a418bf9e2e2b670e1aa7b7da59391e212b4ba1988ac',
            address: testAddress,
            blockHeight: testBlockHeight,
            confirmations: 6,
          ),
        ),
      );
      
      await Future.delayed(Duration(milliseconds: 500));
      print('✓ Wallet funded');
      
      // Step 4: Create a payment address (can be any address for testing)
      final paymentAddress = 'muq9kAb9ri62VChAMRkuwK5bTve4iDLWBg'; // testnet address
      final invoiceId = 'test-invoice-${DateTime.now().millisecondsSinceEpoch}';
      
      print('\n✓ Preparing payment:');
      print('  Invoice ID: $invoiceId');
      print('  Payment Address: $paymentAddress');
      
      // Step 5: Use PayInvoiceMessage to create payment transaction
      print('\n✓ Creating payment transaction...');
      final payInvoiceCompleter = Completer<BEEFPaymentResponse>();
      final payInvoiceReceiver = await actorSystem.spawn(
        'pay-invoice-receiver',
        () => _TestReceiverActor<BEEFPaymentResponse>(payInvoiceCompleter),
      );
      
      libspiffy.paymentCoordinator.tell(
        PayInvoiceMessage(
          walletId: testWalletId,
          invoiceId: invoiceId,
          addresses: [paymentAddress],
          amount: BigInt.from(50000000),
        ),
        sender: payInvoiceReceiver,
      );
      
      final paymentResponse = await payInvoiceCompleter.future.timeout(Duration(seconds: 10));
      expect(paymentResponse.success, isTrue, reason: 'Payment creation should succeed');
      expect(paymentResponse.beefBytes, isNotEmpty, reason: 'BEEF should be generated');
      
      print('✓ Payment transaction created');
      print('  BEEF size: ${paymentResponse.beefBytes.length} bytes');
      print('  Payment TXID: ${paymentResponse.txid}');
      
      final paymentTxid = paymentResponse.txid;
      
      // Step 6: Wait for async processing (transaction creation, event persistence, projection updates)
      await Future.delayed(Duration(milliseconds: 5000));
      print('\n⏳ Waited 5s for projection to process TransactionRecordedEvent...');
      
      // Step 7: Verify transaction is recorded in history
      final txHistory = await storage.getTransactionHistory(testWalletId);
      print('\n📊 Transaction history query result:');
      print('  Total transactions: ${txHistory.length}');
      
      // ASSERT: Transaction must be recorded (test should fail if not)
      expect(txHistory, isNotEmpty, reason: 'Transaction history should not be empty after payment creation');
      
      final recordedTx = txHistory.firstWhere(
        (tx) => tx.txid == paymentTxid,
        orElse: () => throw Exception('Transaction $paymentTxid not found in history'),
      );
      
      print('\n✅ Transaction recorded in history:');
      print('  TXID: ${recordedTx.txid}');
      print('  Status: ${recordedTx.status}');
      print('  Block Height: ${recordedTx.blockHeight}');
      print('  Receiving Addresses: ${recordedTx.receivingAddresses}');
      print('  Sending Addresses: ${recordedTx.sendingAddresses}');
      print('  Net Amount: ${recordedTx.netAmount} sats');
      print('  Input Value: ${recordedTx.inputValue} sats');
      print('  Output Value: ${recordedTx.outputValue} sats');
      print('  Fee: ${recordedTx.fee} sats');
      
      // Verify transaction data correctness
      expect(recordedTx.txid, equals(paymentTxid));
      expect(recordedTx.inputValue, greaterThan(BigInt.zero), reason: 'Input value must be positive');
      expect(recordedTx.outputValue, greaterThan(BigInt.zero), reason: 'Output value must be positive');
      
      // The wallet should show negative net amount (outgoing payment + fee)
      expect(recordedTx.netAmount, lessThan(BigInt.zero), reason: 'Net amount should be negative for outgoing payment');
      
      // Verify fee is reasonable
      final fee = recordedTx.inputValue - recordedTx.outputValue;
      expect(fee, greaterThan(BigInt.zero), reason: 'Fee must be positive');
      expect(fee, lessThan(BigInt.from(10000)), reason: 'Fee should be reasonable (< 10000 sats)');
      
      print('  Fee calculated: $fee sats');
      
      // Step 8: Verify UTXOs are updated (should have change UTXO)
      final utxos = await storage.getUTXOs(testWalletId);
      print('\n📦 UTXOs: ${utxos.length} UTXO(s)');
      expect(utxos, isNotEmpty, reason: 'Should have change UTXO from payment');
      
      print('\n═══════════════════════════════════════════════\n');
    });
  });
}

// ============================================================================
// Test Helpers
// ============================================================================

/// Setup real block headers from testnet for SPV validation
Future<void> _setupRealBlockHeaders(IsarWalletStorage storage) async {
  // Block 1239645 - contains funding transaction
  final header0 = BlockHeader(
    version: 536870912,
    prevBlock: Hash.fromHex('0000000011b488d1d83e4a73b5c70c4e70f9c96bea4e1e09bfe3b96c46f06f8b'),
    merkleRoot: Hash.fromHex('3b1c4d24bf3cad81a38981b16294284fff09272d067739fc7a17ba1400000000'),
    timestamp: DateTime.fromMillisecondsSinceEpoch(1701709220 * 1000),
    bits: 0x1d00ffff,
    nonce: 1119085398,
  );
  await storage.storeBlockHeader(header0, 1239645);
  
  print('✓ Stored 1 real testnet block header (1239645)');
}

/// Get test transaction hex for funding the wallet
/// This is the same transaction used in payment_api_test.dart
/// Transaction pays to mqCnSf8i6kmaQaJ54HjQ8EUJnuK4AnCv12 (m/0/0 from abandon... mnemonic)
String _getTestTransactionHex() {
  return '020000000165b6c06790c23623c4988ee51b3f27c76bfb6a0c9e5bab3432968c51379af66a000000006b483045022100b735fb60adca4fa42e37746aa602c3206bf98572ae83e396da4fd11cb716b26d022017bf9955bd8fc4d60f2829236c7864d5b5540062c88113daef137c0ee441736c41210222824a8530bc570b7bae7c7600529b450a65eab1203c5f561d8082cd97b3dba1feffffff02872ec735150000001976a9149d02ce72bbdc1713d5537a0705d8ec7d9702c81088ac00c2eb0b000000001976a9146a418bf9e2e2b670e1aa7b7da59391e212b4ba1988ac5cea1200';
}

/// Get TSC merkle proof for the funding transaction
Map<String, dynamic> _getTestMerkleProof() {
  return {
    'index': 2,
    'txOrId': 'a05924fcc63712d3e4b94b0c88baad234c2c8ad3d369704f53765e21a53a2101',
    'target': '0000000014ba177afc3977062d2709ff4f289462b18189a381ad3cbf244d1c3b',
    'nodes': [
      '2bb617ed9b7950dcc9ddd952364a5d039742b40b786d3ef8a3984a5cf5495640',
      'e0c82744e0d7c7a1e72102b82fa37ae09f4e6018ebb18773f888617b83250e75',
      '9991c11c2ecb5087a29032a279d926bfe03c926c582a30743c902b57a3d98039',
      '9d54821a3821713dadeeb3a614921f8c63866f82686cbcf019ed7a6c20a36d2b',
      'a1e33369efb20fa5a1311ddfed20747de1996fdc814aa19691106eafe28b3e5d',
      '5a2f7dcc9b1fddc64f57157e7c59082729622050a76cb6956ae6b15f1a9ff0c4',
    ],
  };
}

// ============================================================================
// Mock Actors
// ============================================================================

class _TestReceiverActor<T> extends Actor {
  final Completer<T> completer;
  
  _TestReceiverActor(this.completer);
  
  @override
  Future<void> onMessage(dynamic message) async {
    if (message is T && !completer.isCompleted) {
      completer.complete(message);
    }
  }
}

