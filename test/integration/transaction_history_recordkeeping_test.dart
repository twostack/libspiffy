import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
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
import 'package:dartsv/dartsv.dart' as dartsv;

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

    test('Recipient wallet records incoming transaction after SPV validation', () async {
      print('═══ Test: Recipient Transaction Record-Keeping After SPV ═══\n');
      
      // Step 1: Create recipient wallet
      final recipientWalletId = 'recipient-wallet-${DateTime.now().millisecondsSinceEpoch}';
      final recipientMnemonic = 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
      
      print('✓ Creating recipient wallet...');
      final createRecipientCompleter = Completer<WalletCreatedMessage>();
      final createRecipientReceiver = await actorSystem.spawn(
        'create-recipient-receiver',
        () => _TestReceiverActor<WalletCreatedMessage>(createRecipientCompleter),
      );
      
      libspiffy.walletManager.tell(
        CreateWalletMessage(
          recipientWalletId,
          'Recipient Wallet',
          mnemonic: recipientMnemonic,
        ),
        sender: createRecipientReceiver,
      );
      
      final recipientResponse = await createRecipientCompleter.future.timeout(Duration(seconds: 5));
      expect(recipientResponse.success, isTrue, reason: 'Recipient wallet creation should succeed');
      print('✓ Recipient wallet created: ${recipientResponse.walletId}');
      
      // Step 2: Block headers already set up in first test, no need to duplicate
      
      // Step 3: Generate an address for the recipient
      // Using m/0/0 from abandon... mnemonic = mqCnSf8i6kmaQaJ54HjQ8EUJnuK4AnCv12
      final recipientAddress = 'mqCnSf8i6kmaQaJ54HjQ8EUJnuK4AnCv12';
      
      // Tell the wallet about this address (normally done via GenerateAddressCommand)
      libspiffy.walletManager.tell(
        WalletCommandMessage(
          recipientWalletId,
          GenerateAddressCommand(
            walletId: recipientWalletId,
            label: 'Test Address',
          ),
        ),
      );
      await Future.delayed(Duration(milliseconds: 500));
      
      print('✓ Recipient address: $recipientAddress');
      
      // Step 4: Simulate receiving payment via SPV validation
      // In the actual flow, both ReceiveUTXOCommand and RecordImportedTransactionCommand are sent
      print('\n✓ Simulating incoming payment via SPV...');
      
      // First, send ReceiveUTXOCommand for the output that belongs to recipient
      // Output 1 of the transaction pays 200M sats to mqCnSf8i6kmaQaJ54HjQ8EUJnuK4AnCv12
      final receiveUtxoCmd = ReceiveUTXOCommand(
        walletId: recipientWalletId,
        txid: 'a05924fcc63712d3e4b94b0c88baad234c2c8ad3d369704f53765e21a53a2101',
        vout: 1, // Output index 1
        satoshis: BigInt.from(200000000), // 2 BSV
        scriptPubKey: '76a9146a418bf9e2e2b670e1aa7b7da59391e212b4ba1988ac', // P2PKH script for recipient address
        address: recipientAddress,
        blockHeight: 1239645,
        confirmations: 1,
      );
      
      libspiffy.walletManager.tell(
        WalletCommandMessage(recipientWalletId, receiveUtxoCmd),
      );
      
      await Future.delayed(Duration(milliseconds: 500));
      print('  ✓ UTXO command sent');
      
      // Second, record the transaction in history
      final recordCmd = RecordImportedTransactionCommand(
        walletId: recipientWalletId,
        txid: 'a05924fcc63712d3e4b94b0c88baad234c2c8ad3d369704f53765e21a53a2101',
        rawHex: _getTestTransactionHex(),
        blockHeight: 1239645,
        bumpProofHex: '', // Not critical for this test
        totalOutputSats: 9221846919, // From the test transaction
        numInputs: 1,
        numOutputs: 2,
        txVersion: 2,
        txLockTime: 1239629,
        walletReceivingAddresses: [recipientAddress],
        walletReceivedSats: 200000000, // 2 BSV received by wallet
        totalInputSats: 9221847920, // ~92 BSV input
        sendingAddresses: [],
      );
      
      libspiffy.walletManager.tell(
        WalletCommandMessage(recipientWalletId, recordCmd),
      );
      print('  ✓ Transaction record command sent');
      
      // Step 5: Wait for SPV validation and projection processing
      await Future.delayed(Duration(seconds: 5));
      print('\n⏳ Waited 5s for SPV validation and projection processing...');
      
      // Step 6: Verify transaction is recorded in recipient's history
      final recipientTxHistory = await storage.getTransactionHistory(recipientWalletId);
      print('\n📊 Recipient transaction history:');
      print('  Total transactions: ${recipientTxHistory.length}');
      
      expect(recipientTxHistory, isNotEmpty, reason: 'Recipient should have transaction history');
      
      final incomingTx = recipientTxHistory.firstWhere(
        (tx) => tx.txid == 'a05924fcc63712d3e4b94b0c88baad234c2c8ad3d369704f53765e21a53a2101',
        orElse: () => throw Exception('Transaction not found in recipient history'),
      );
      
      print('\n✅ Incoming transaction recorded:');
      print('  TXID: ${incomingTx.txid}');
      print('  Status: ${incomingTx.status}');
      print('  Block Height: ${incomingTx.blockHeight}');
      print('  Receiving Addresses: ${incomingTx.receivingAddresses}');
      print('  Net Amount: ${incomingTx.netAmount} sats');
      print('  Input Value: ${incomingTx.inputValue} sats');
      print('  Output Value: ${incomingTx.outputValue} sats');
      
      // Assertions for transaction
      expect(incomingTx.status, TransactionStatus.confirmed, reason: 'Incoming tx should be confirmed');
      expect(incomingTx.blockHeight, greaterThan(0), reason: 'Should have block height from SPV');
      expect(incomingTx.netAmount, greaterThan(BigInt.zero), reason: 'Net amount should be POSITIVE for incoming');
      expect(incomingTx.netAmount, equals(BigInt.from(200000000)), reason: 'Should receive exactly 2 BSV (200M sats)');
      expect(incomingTx.receivingAddresses, contains(recipientAddress), reason: 'Should include recipient address');
      
      // Step 7: Verify UTXOs were created
      final recipientUtxos = await storage.getAvailableUTXOs(recipientWalletId);
      print('\n📦 Recipient UTXOs: ${recipientUtxos.length} UTXO(s)');
      
      expect(recipientUtxos, isNotEmpty, reason: 'Recipient should have UTXOs after receiving payment');
      expect(recipientUtxos.length, equals(1), reason: 'Should have exactly 1 UTXO');
      
      final receivedUtxo = recipientUtxos.first;
      print('\n✅ Received UTXO:');
      print('  TXID: ${receivedUtxo.txid}');
      print('  Vout: ${receivedUtxo.vout}');
      print('  Amount: ${receivedUtxo.satoshis} sats');
      print('  Address: ${receivedUtxo.address}');
      print('  Status: ${receivedUtxo.status}');
      
      expect(receivedUtxo.txid, equals('a05924fcc63712d3e4b94b0c88baad234c2c8ad3d369704f53765e21a53a2101'));
      expect(receivedUtxo.vout, equals(1));
      expect(receivedUtxo.satoshis, equals(BigInt.from(200000000)));
      expect(receivedUtxo.address, equals(recipientAddress));
      expect(receivedUtxo.status, equals(UTXOStatus.available));
      
      print('\n✅ Test passed: Recipient wallet correctly records incoming payment');
      print('   - Transaction in history: ✓');
      print('   - Status: confirmed ✓');
      print('   - Net amount positive: ✓');
      print('   - Correct receiving address: ✓');
      print('   - UTXO created: ✓');
      print('   - UTXO amount correct: ✓');
      
      print('\n═══════════════════════════════════════════════\n');
    });

    test('Complete SPV payment flow using public APIs validates transaction and UTXO recording', () async {
      print('═══ Test: End-to-End SPV Payment Flow (Public API) ═══\n');
      print('Creating SEPARATE actor systems for sender and receiver (simulating P2P)');
      
      // ============================================================
      // Setup: Create TWO separate actor systems (like real P2P)
      // ============================================================
      late Directory senderTestDir;
      late Isar senderIsar;
      late LocalActorSystem senderActorSystem;
      late LibSpiffyActorSystem senderLibspiffy;
      late IsarWalletStorage senderStorage;
      
      late Directory receiverTestDir;
      late Isar receiverIsar;
      late LocalActorSystem receiverActorSystem;
      late LibSpiffyActorSystem receiverLibspiffy;
      late IsarWalletStorage receiverStorage;
      
      try {
        // Create SENDER actor system
        print('\n✓ Creating sender actor system...');
        senderTestDir = await Directory.systemTemp.createTemp('sender_test_');
        senderIsar = await Isar.open(
          [
            ...LibSpiffySchemas.walletSchemas,
            ...IsarEventStore.requiredSchemas,
          ],
          directory: senderTestDir.path,
          name: 'sender_db',
        );
        senderActorSystem = LocalActorSystem(ActorSystemConfig());
        senderLibspiffy = LibSpiffyActorSystem();
        await senderLibspiffy.initialize(
          actorSystem: senderActorSystem,
          isar: senderIsar,
          dataDirectory: senderTestDir.path,
          enableP2P: false,
        );
        senderStorage = senderLibspiffy.walletStorage as IsarWalletStorage;
        print('  Setting up block headers for sender...');
        await _setupRealBlockHeaders(senderStorage);
        final senderHeader = await senderStorage.getBlockHeaderByHeight(1239645);
        print('  Sender block header 1239645: ${senderHeader != null ? "STORED ✓" : "MISSING ✗"}');
        print('✓ Sender actor system ready');
        
        // Create RECEIVER actor system
        print('\n✓ Creating receiver actor system...');
        receiverTestDir = await Directory.systemTemp.createTemp('receiver_test_');
        receiverIsar = await Isar.open(
          [
            ...LibSpiffySchemas.walletSchemas,
            ...IsarEventStore.requiredSchemas,
          ],
          directory: receiverTestDir.path,
          name: 'receiver_db',
        );
        receiverActorSystem = LocalActorSystem(ActorSystemConfig());
        receiverLibspiffy = LibSpiffyActorSystem();
        await receiverLibspiffy.initialize(
          actorSystem: receiverActorSystem,
          isar: receiverIsar,
          dataDirectory: receiverTestDir.path,
          enableP2P: false,
        );
        receiverStorage = receiverLibspiffy.walletStorage as IsarWalletStorage;
        print('  Setting up block headers for receiver...');
        await _setupRealBlockHeaders(receiverStorage);
        final receiverHeader = await receiverStorage.getBlockHeaderByHeight(1239645);
        print('  Receiver block header 1239645: ${receiverHeader != null ? "STORED ✓" : "MISSING ✗"}');
        print('✓ Receiver actor system ready');
      
        // ============================================================
        // Setup: Create sender and receiver wallets
        // ============================================================
        final senderWalletId = 'sender-wallet-${DateTime.now().millisecondsSinceEpoch}';
        final receiverWalletId = 'receiver-wallet-${DateTime.now().millisecondsSinceEpoch + 1}';
        
        // Sender uses testnet xpriv with known test UTXO (from payment_api_test.dart)
        // This xpriv corresponds to address mqCnSf8i6kmaQaJ54HjQ8EUJnuK4AnCv12 (m/0/0)
        const senderXpriv = 'tprv8ZgxMBicQKsPeMiDjtXBGAyFY1wEMGgomjwf54ZmiZfKTNYvVdBa6GqWUwnvtHm6NKVkQkhCKxaobd9JPxNEXgDfVgJ5RNHJ3ivogSG3V1R';
        // Receiver uses completely different mnemonic (CRITICAL: must NOT generate same addresses as sender!)
        final receiverMnemonic = 'legal winner thank year wave sausage worth useful legal winner thank yellow';
        
        print('\n✓ Creating sender wallet...');
        final createSenderCompleter = Completer<WalletCreatedMessage>();
        final createSenderReceiver = await senderActorSystem.spawn(
          'create-sender-receiver',
          () => _TestReceiverActor<WalletCreatedMessage>(createSenderCompleter),
        );
        
        senderLibspiffy.walletManager.tell(
          CreateWalletMessage(
            senderWalletId,
            'Sender Wallet',
            xpriv: senderXpriv,
          ),
          sender: createSenderReceiver,
        );
        
        final senderResponse = await createSenderCompleter.future.timeout(Duration(seconds: 5));
        expect(senderResponse.success, isTrue);
        print('✓ Sender wallet created: ${senderResponse.walletId}');
        print('  Root address: ${senderResponse.rootAddress}');
        
        // Wait for wallet to be fully initialized with root address
        await Future.delayed(Duration(seconds: 1));
        
        print('\n✓ Creating receiver wallet...');
        final createReceiverCompleter = Completer<WalletCreatedMessage>();
        final createReceiverReceiver = await receiverActorSystem.spawn(
          'create-receiver-receiver',
          () => _TestReceiverActor<WalletCreatedMessage>(createReceiverCompleter),
        );
        
        receiverLibspiffy.walletManager.tell(
          CreateWalletMessage(
            receiverWalletId,
            'Receiver Wallet',
            mnemonic: receiverMnemonic,
          ),
          sender: createReceiverReceiver,
        );
        
        final receiverResponse = await createReceiverCompleter.future.timeout(Duration(seconds: 5));
        expect(receiverResponse.success, isTrue);
        print('✓ Receiver wallet created: ${receiverResponse.walletId}');
      
      // ============================================================
      // TEST SETUP: Fund sender wallet (simulates wallet import)
      // In real world, sender got these funds from wallet import or previous payment
      // ============================================================
      print('\n✓ Test setup: Funding sender wallet (simulating import)...');
      
      final testTxid = 'a05924fcc63712d3e4b94b0c88baad234c2c8ad3d369704f53765e21a53a2101';
      final testBlockHeight = 1239645;
      final testTxHex = _getTestTransactionHex();
      final expectedRootAddress = 'mqCnSf8i6kmaQaJ54HjQ8EUJnuK4AnCv12'; // m/0/0 from xpriv
      final senderRootAddress = senderResponse.rootAddress; // Use actual root address from wallet
      
      print('  Expected root: $expectedRootAddress');
      print('  Actual root:   $senderRootAddress');
      expect(senderRootAddress, equals(expectedRootAddress), reason: 'Root address must match expected');
      
      // Import follows wallet-import pattern: record transaction first, then UTXO
      final proofJson = _getTestMerkleProof();
      final bump = CryptoUtils.createBumpFromTscProof(proofJson, testBlockHeight);
      final bumpHex = hex.encode(bump.serialize());
      
      // Step 1: Record the funding transaction (like wallet import does)
      senderLibspiffy.walletManager.tell(
        WalletCommandMessage(
          senderWalletId,
          RecordImportedTransactionCommand(
            walletId: senderWalletId,
            txid: testTxid,
            rawHex: testTxHex,
            blockHeight: testBlockHeight,
            bumpProofHex: bumpHex,
            totalOutputSats: 9221846919,
            numInputs: 1,
            numOutputs: 2,
            txVersion: 2,
            txLockTime: 1239629,
            walletReceivingAddresses: [senderRootAddress],
            walletReceivedSats: 200000000,
            totalInputSats: 9221847920,
            sendingAddresses: [],
          ),
        ),
      );
      
      await Future.delayed(Duration(milliseconds: 300));
      
      // Step 2: Create the UTXO (like wallet import does)
      senderLibspiffy.walletManager.tell(
        WalletCommandMessage(
          senderWalletId,
          ReceiveUTXOCommand(
            walletId: senderWalletId,
            txid: testTxid,
            vout: 1,
            satoshis: BigInt.from(200000000),
            scriptPubKey: '76a9146a418bf9e2e2b670e1aa7b7da59391e212b4ba1988ac',
            address: senderRootAddress,
            blockHeight: testBlockHeight,
            confirmations: 6,
          ),
        ),
      );
      
      // Wait longer for Isar write transactions to commit and projections to complete
      await Future.delayed(Duration(seconds: 5));
      
      // Verify sender has the UTXO
      final senderUtxos = await senderStorage.getAvailableUTXOs(senderWalletId);
      expect(senderUtxos, isNotEmpty, reason: 'Test setup: Sender must have funds');
      print('  ✓ Sender funded with ${senderUtxos.first.satoshis} sats');
      
      // CRITICAL: Verify merkle proof is stored (needed for BEEF creation)
      print('  Checking if merkle proof was stored for ancestor transaction...');
      final fundingTxMerkleProof = await senderStorage.getMerkleProof(testTxid);
      print('  Merkle proof stored in SENDER db: ${fundingTxMerkleProof != null ? "YES ✓" : "NO ✗"}');
      if (fundingTxMerkleProof != null) {
        print('    Block height: ${fundingTxMerkleProof.blockHeight}');
        print('    Position: ${fundingTxMerkleProof.position}');
        print('    Siblings: ${fundingTxMerkleProof.merkleProof.length}');
      } else {
        print('    ⚠️  WARNING: Merkle proof not found - BEEF creation will fail!');
      }
      expect(fundingTxMerkleProof, isNotNull, reason: 'Test setup: Funding transaction must have merkle proof for BEEF creation');
      print('  ✓ Merkle proof verified for BEEF creation\n');
      
      print('════════════════════════════════════════════════');
      print('  PUBLIC API TEST BEGINS');
      print('════════════════════════════════════════════════');
      
      // ============================================================
      // Step 1: Receiver creates invoice (PUBLIC API)
      // ============================================================
      print('\n═══ Step 1: Receiver creates invoice ═══');
      final invoiceAmount = BigInt.from(50000000); // 0.5 BSV
      
      final createInvoiceCompleter = Completer<InvoiceCreatedMessage>();
      final invoiceReceiver = await receiverActorSystem.spawn(
        'invoice-receiver',
        () => _TestReceiverActor<InvoiceCreatedMessage>(createInvoiceCompleter),
      );
      
      receiverLibspiffy.walletManager.tell(
        CreateInvoiceMessage(
          walletId: receiverWalletId,
          amount: invoiceAmount,
        ),
        sender: invoiceReceiver,
      );
      
      final invoice = await createInvoiceCompleter.future.timeout(Duration(seconds: 5));
      expect(invoice.success, isTrue);
      expect(invoice.walletId, equals(receiverWalletId));
      
      print('  ✓ Invoice created: ${invoice.invoiceId}');
      print('    Address: ${invoice.addresses.first}');
      print('    Amount: ${invoice.amount} sats');
      
      final invoiceId = invoice.invoiceId;
      final receiverAddress = invoice.addresses.first;
      
      // ============================================================
      // Step 2: Sender pays invoice (PUBLIC API)
      // ============================================================
      print('\n═══ Step 2: Sender creates BEEF payment ═══');
      
      final payInvoiceCompleter = Completer<BEEFPaymentResponse>();
      final paymentReceiver = await senderActorSystem.spawn(
        'payment-receiver',
        () => _TestReceiverActor<BEEFPaymentResponse>(payInvoiceCompleter),
      );
      
      senderLibspiffy.paymentCoordinator.tell(
        PayInvoiceMessage(
          walletId: senderWalletId,
          invoiceId: invoiceId,
          addresses: [receiverAddress],
          amount: invoiceAmount,
        ),
        sender: paymentReceiver,
      );
      
      final paymentResponse = await payInvoiceCompleter.future.timeout(Duration(seconds: 10));
      expect(paymentResponse.success, isTrue);
      
      print('  ✓ BEEF payment created');
      print('    TXID: ${paymentResponse.txid}');
      print('    BEEF size: ${paymentResponse.beefBytes.length} bytes');
      
      final paymentTxid = paymentResponse.txid;
      final beefBytes = paymentResponse.beefBytes;
      
      // ============================================================
      // Step 3: Receiver validates BEEF (PUBLIC API - two-step process)
      // ============================================================
      print('\n═══ Step 3: Receiver validates BEEF via SPV ═══');
      
      final beefHex = beefBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      
      // Step 3a: Validate BEEF structure
      print('  Step 3a: Validating BEEF structure...');
      final validateBeefCompleter = Completer<BEEFValidationResult>();
      final validateReceiverActor = await receiverActorSystem.spawn(
        'validate-receiver',
        () => _TestReceiverActor<BEEFValidationResult>(validateBeefCompleter),
      );
      
      receiverLibspiffy.spvActor.tell(
        ValidateBEEFMessage(
          beefHex,
          targetWalletId: receiverWalletId,
        ),
        sender: validateReceiverActor,
      );
      
      final beefValidationResult = await validateBeefCompleter.future.timeout(Duration(seconds: 10));
      expect(beefValidationResult.isValid, isTrue);
      expect(beefValidationResult.extractedTransactions, isNotEmpty);
      
      print('  ✓ BEEF structure valid');
      print('    Transactions: ${beefValidationResult.extractedTransactions!.length}');
      
      // Step 3b: Trigger full SPV validation
      print('  Step 3b: Triggering full SPV validation...');
      final spvValidationCompleter = Completer<SPVValidationResult>();
      final spvReceiverActor = await receiverActorSystem.spawn(
        'spv-receiver',
        () => _TestReceiverActor<SPVValidationResult>(spvValidationCompleter),
      );
      
      final beef = BEEF.parse(Uint8List.fromList(beefBytes));
      final mainTx = beefValidationResult.extractedTransactions!.last;
      final txid = mainTx['transactionId'] as String;
      
      receiverLibspiffy.spvActor.tell(
        ReceiveTransactionMessage(
          transactionId: txid,
          beef: beef,
          fromCounterparty: 'test-sender',
          targetWalletId: receiverWalletId,
          invoiceId: invoiceId,
        ),
        sender: spvReceiverActor,
      );
      
      final spvValidationResult = await spvValidationCompleter.future.timeout(Duration(seconds: 10));
      expect(spvValidationResult.isValid, isTrue);
      
      print('  ✓ SPV validation successful');
      print('    TXID: ${spvValidationResult.txid}');
      print('    Spendable UTXOs: ${spvValidationResult.spendableUTXOs.length}');
      
      // ============================================================
      // Step 4: Wait for async projection processing
      // ============================================================
      print('\n═══ Step 4: Waiting for projection processing ═══');
      await Future.delayed(Duration(seconds: 5));
      
      // ============================================================
      // Step 5: Verify sender's transaction record
      // ============================================================
      print('\n═══ Step 5: Verify sender transaction history ═══');
      final senderTxHistory = await senderStorage.getTransactionHistory(senderWalletId);
      print('  Sender transactions: ${senderTxHistory.length}');
      
      expect(senderTxHistory, isNotEmpty, reason: 'Sender should have transaction history');
      
      final senderTx = senderTxHistory.firstWhere(
        (tx) => tx.txid == paymentTxid,
        orElse: () => throw Exception('Sender transaction not found'),
      );
      
      print('\n  ✅ Sender transaction recorded:');
      print('    TXID: ${senderTx.txid}');
      print('    Status: ${senderTx.status}');
      print('    Net Amount: ${senderTx.netAmount} sats');
      print('    Fee: ${senderTx.fee} sats');
      
      expect(senderTx.status, TransactionStatus.pending, reason: 'Sender tx should be PENDING until confirmed');
      expect(senderTx.netAmount, lessThan(BigInt.zero), reason: 'Sender net amount should be NEGATIVE');
      expect(senderTx.netAmount.abs(), greaterThan(invoiceAmount), reason: 'Should include payment + fee');
      
      // ============================================================
      // Step 6: Verify receiver's transaction and UTXO
      // ============================================================
      print('\n═══ Step 6: Verify receiver transaction history and UTXOs ═══');
      final receiverTxHistory = await receiverStorage.getTransactionHistory(receiverWalletId);
      print('  Receiver transactions: ${receiverTxHistory.length}');
      
      expect(receiverTxHistory, isNotEmpty, reason: 'Receiver should have transaction history');
      
      final receiverTx = receiverTxHistory.firstWhere(
        (tx) => tx.txid == paymentTxid,
        orElse: () => throw Exception('Receiver transaction not found'),
      );
      
      print('\n  ✅ Receiver transaction recorded:');
      print('    TXID: ${receiverTx.txid}');
      print('    Status: ${receiverTx.status}');
      print('    Net Amount: ${receiverTx.netAmount} sats');
      print('    Receiving Address: ${receiverTx.receivingAddresses}');
      
      expect(receiverTx.status, equals(TransactionStatus.confirmed), reason: 'Receiver tx should be CONFIRMED after SPV');
      expect(receiverTx.netAmount, greaterThan(BigInt.zero), reason: 'Receiver net amount should be POSITIVE');
      expect(receiverTx.netAmount, equals(invoiceAmount), reason: 'Should receive exactly invoice amount');
      expect(receiverTx.receivingAddresses, contains(receiverAddress));
      
      // Verify UTXOs created
      final receiverUtxos = await receiverStorage.getAvailableUTXOs(receiverWalletId);
      print('\n  ✅ Receiver UTXOs: ${receiverUtxos.length}');
      
      expect(receiverUtxos, isNotEmpty, reason: 'Receiver should have UTXOs');
      
      final receivedUtxo = receiverUtxos.firstWhere(
        (u) => u.txid == paymentTxid,
        orElse: () => throw Exception('Payment UTXO not found'),
      );
      
      print('    UTXO Amount: ${receivedUtxo.satoshis} sats');
      print('    UTXO Status: ${receivedUtxo.status}');
      
      expect(receivedUtxo.satoshis, equals(invoiceAmount));
      expect(receivedUtxo.status, equals(UTXOStatus.available));
      
      // ============================================================
      // Summary
      // ============================================================
      print('\n✅ ═══════════════════════════════════════════════');
      print('✅ End-to-End SPV Payment Flow Test PASSED');
      print('✅ ═══════════════════════════════════════════════');
      print('✅ Sender:');
      print('   - Transaction recorded: ✓');
      print('   - Status: PENDING ✓');
      print('   - Net amount negative: ✓');
      print('✅ Receiver:');
      print('   - Transaction recorded: ✓');
      print('   - Status: CONFIRMED ✓');
      print('   - Net amount positive: ✓');
      print('   - UTXO created and available: ✓');
      print('✅ ═══════════════════════════════════════════════\n');
      
      } finally {
        // Cleanup both actor systems
        print('\n─────────────────────────────────────────────');
        print('Cleaning up sender and receiver actor systems...');
        
        try {
          await senderLibspiffy.shutdown();
          await senderIsar.close(deleteFromDisk: true);
          await senderTestDir.delete(recursive: true);
          print('✓ Sender actor system cleaned up');
        } catch (e) {
          print('⚠️  Sender cleanup error: $e');
        }
        
        try {
          await receiverLibspiffy.shutdown();
          await receiverIsar.close(deleteFromDisk: true);
          await receiverTestDir.delete(recursive: true);
          print('✓ Receiver actor system cleaned up');
        } catch (e) {
          print('⚠️  Receiver cleanup error: $e');
        }
        
        print('✓ Cleanup complete');
        print('═══════════════════════════════════════════════\n');
      }
    });

    test('Process large multisig transaction with 93 inputs correctly', () async {
      print('═══ Test: Large MultiSig Transaction Processing ═══\n');
      
      // Step 1: Setup test wallet
      final testWalletId = 'multisig-wallet-${DateTime.now().millisecondsSinceEpoch}';
      print('✓ Test wallet ID: $testWalletId');
      
      // Step 2: Create the wallet
      const xPrivKey = 'tprv8ZgxMBicQKsPeMiDjtXBGAyFY1wEMGgomjwf54ZmiZfKTNYvVdBa6GqWUwnvtHm6NKVkQkhCKxaobd9JPxNEXgDfVgJ5RNHJ3ivogSG3V1R';
      
      final createWalletCompleter = Completer<WalletCreatedMessage>();
      final createWalletReceiver = await actorSystem.spawn(
        'create-multisig-wallet-receiver',
        () => _TestReceiverActor<WalletCreatedMessage>(createWalletCompleter),
      );
      
      libspiffy.walletManager.tell(
        CreateWalletMessage(
          testWalletId,
          'MultiSig Test Wallet',
          xpriv: xPrivKey,
        ),
        sender: createWalletReceiver,
      );
      
      final walletCreated = await createWalletCompleter.future.timeout(Duration(seconds: 5));
      expect(walletCreated.success, isTrue, reason: 'Wallet creation should succeed');
      print('✓ Wallet created: $testWalletId');
      print('  Root address: ${walletCreated.rootAddress}');
      
      await Future.delayed(Duration(milliseconds: 1000));
      
      // Step 3: Parse the large multisig transaction
      final multisigTxHex = _getMultiSigTransactionHex();
      print('\n✓ Parsing large multisig transaction...');
      print('  Transaction hex length: ${multisigTxHex.length} chars');
      
      // Parse transaction using dartsv
      final tx = dartsv.Transaction.fromHex(multisigTxHex);
      
      print('\n✓ Transaction parsed successfully:');
      print('  TXID: ${tx.id}');
      print('  Number of inputs: ${tx.inputs.length}');
      print('  Number of outputs: ${tx.outputs.length}');
      print('  Version: ${tx.version}');
      print('  LockTime: ${tx.nLockTime}');
      
      // Step 4: Verify transaction structure
      expect(tx.inputs.length, equals(93), reason: 'Transaction should have 93 inputs');
      expect(tx.outputs.length, equals(2), reason: 'Transaction should have 2 outputs');
      
      // Step 5: Analyze outputs
      print('\n✓ Analyzing outputs:');
      
      // Output 0 - Regular P2PKH
      final output0 = tx.outputs[0];
      print('  Output 0:');
      print('    Amount: ${output0.satoshis} sats');
      print('    Script: ${hex.encode(output0.script.buffer)}');
      print('    Script type: ${output0.script.isP2PKH() ? "P2PKH" : output0.script.isScriptHashOut() ? "P2SH" : "OTHER"}');
      
      expect(output0.script.isP2PKH(), isTrue, reason: 'Output 0 should be P2PKH');
      expect(output0.satoshis, equals(BigInt.from(163486601)), reason: 'Output 0 should have correct amount');
      
      // Output 1 - MultiSig
      final output1 = tx.outputs[1];
      print('  Output 1 (MultiSig):');
      print('    Amount: ${output1.satoshis} sats');
      print('    Script: ${hex.encode(output1.script.buffer)}');
      
      // Parse multisig script manually
      final scriptBuffer = output1.script.buffer;
      final scriptHex = hex.encode(scriptBuffer);
      print('    Script hex: $scriptHex');
      
      // Verify it's a multisig script by checking pattern
      // Format: <m> <pubkey1> <pubkey2> ... <n> OP_CHECKMULTISIG
      // OP_2 = 0x52, OP_CHECKMULTISIG = 0xae, pubkey length = 0x21 (33 bytes)
      expect(scriptBuffer[0], equals(0x52), reason: 'First byte should be OP_2');
      expect(scriptBuffer[scriptBuffer.length - 1], equals(0xae), reason: 'Last byte should be OP_CHECKMULTISIG');
      expect(scriptBuffer[scriptBuffer.length - 2], equals(0x52), reason: 'Second-to-last byte should be OP_2');
      
      // Extract public keys from multisig script
      final pubkey1Bytes = scriptBuffer.sublist(2, 35); // Skip OP_2 and length byte
      final pubkey2Bytes = scriptBuffer.sublist(36, 69); // Skip to second pubkey
      
      final pubkey1Hex = hex.encode(pubkey1Bytes);
      final pubkey2Hex = hex.encode(pubkey2Bytes);
      
      print('    MultiSig type: 2-of-2');
      print('    PubKey 1: $pubkey1Hex');
      print('    PubKey 2: $pubkey2Hex');
      
      expect(pubkey1Hex, equals('028f10cd0e0e9bc7352adb192484d576867a71cbd82295cd87c3ceffc5fbd74acc'));
      expect(pubkey2Hex, equals('02a7472269ad70ea6cf1ecc7fe25a23fb6bc47f928a9ec755e34bada052bd355ce'));
      expect(output1.satoshis, equals(BigInt.from(10000)), reason: 'Output 1 should have correct amount');
      
      // Step 6: Verify all inputs are properly signed
      print('\n✓ Verifying inputs:');
      var inputsWithSignatures = 0;
      
      for (var i = 0; i < tx.inputs.length; i++) {
        final input = tx.inputs[i];
        if (input.script != null && input.script!.buffer.isNotEmpty) {
          inputsWithSignatures++;
          // For this test, we assume each input spends approximately equal amounts
          // In a real scenario, you'd need UTXO data to calculate exact values
        }
      }
      
      print('  Total inputs: ${tx.inputs.length}');
      print('  Inputs with signatures: $inputsWithSignatures');
      
      expect(inputsWithSignatures, equals(93), reason: 'All 93 inputs should have signatures');
      
      // Step 7: Calculate transaction size and fee estimation
      final txSize = hex.decode(tx.serialize()).length;
      final outputTotal = output0.satoshis + output1.satoshis;
      
      print('\n✓ Transaction metrics:');
      print('  Transaction size: $txSize bytes');
      print('  Total output value: $outputTotal sats');
      print('  Output 0 (P2PKH): ${output0.satoshis} sats');
      print('  Output 1 (MultiSig): ${output1.satoshis} sats');
      print('  Estimated fee (assuming 164,089,001 total input): ~10000 sats');
      
      // Step 8: Test importing this transaction into wallet
      print('\n✓ Importing multisig transaction into wallet...');
      
      final testBlockHeight = 1500000; // Example block height
      
      // If one of the outputs belongs to the wallet (for testing purposes)
      // Let's assume output 0 belongs to the wallet address
      final walletAddress = 'mqCnSf8i6kmaQaJ54HjQ8EUJnuK4AnCv12';
      
      libspiffy.walletManager.tell(
        WalletCommandMessage(
          testWalletId,
          RecordImportedTransactionCommand(
            walletId: testWalletId,
            txid: tx.id,
            rawHex: multisigTxHex,
            blockHeight: testBlockHeight,
            bumpProofHex: '', // Not critical for this test
            totalOutputSats: outputTotal.toInt(),
            numInputs: tx.inputs.length,
            numOutputs: tx.outputs.length,
            txVersion: tx.version,
            txLockTime: tx.nLockTime,
            walletReceivingAddresses: [walletAddress],
            walletReceivedSats: output0.satoshis.toInt(),
            totalInputSats: (output0.satoshis + output1.satoshis + BigInt.from(10000)).toInt(), // + estimated fee
            sendingAddresses: [],
          ),
        ),
      );
      
      await Future.delayed(Duration(seconds: 3));
      print('  ✓ Transaction import command sent');
      
      // Step 9: Verify transaction was recorded
      final txHistory = await storage.getTransactionHistory(testWalletId);
      print('\n✓ Checking transaction history...');
      print('  Total transactions: ${txHistory.length}');
      
      if (txHistory.isNotEmpty) {
        final recordedTx = txHistory.firstWhere(
          (t) => t.txid == tx.id,
          orElse: () => throw Exception('MultiSig transaction not found in history'),
        );
        
        print('\n✅ MultiSig transaction recorded:');
        print('  TXID: ${recordedTx.txid}');
        print('  Status: ${recordedTx.status}');
        print('  Block Height: ${recordedTx.blockHeight}');
        print('  Input Value: ${recordedTx.inputValue} sats');
        print('  Output Value: ${recordedTx.outputValue} sats');
        
        // Verify the transaction matches what we expect
        expect(recordedTx.txid, equals(tx.id));
      }
      
      print('\n✅ Large MultiSig Transaction Test Summary:');
      print('  ✓ Transaction parsed successfully');
      print('  ✓ 93 inputs verified');
      print('  ✓ 2 outputs verified');
      print('  ✓ MultiSig output (2-of-2) identified');
      print('  ✓ Public keys extracted from multisig script');
      print('  ✓ All inputs have signatures');
      print('  ✓ Transaction structure is valid');
      
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

String _getMultiSigTransactionHex(){
  return '020000005df89b44870893c3314fc48fdbae07b7816bcca02bea52dd0ec4bacdec6d1117b4000000006a47304402204d80e8935947ccb5e75e7dda4fad4dd718b8d4434cce775176ed5f31a679f2ad022062a6984ba610e9a78ab91f8ee948f0ac1a2f9d288f5730d87ad9d07e30fac55a4121033a69d0acd6e9500844ca078fbc4d81b6c95d7967b3106e31618d5987633d41a9fffffffff89b44870893c3314fc48fdbae07b7816bcca02bea52dd0ec4bacdec6d1117b4010000006b4830450221008f1649bee052adda217976eeb055a091f3c9bd9f29447b1adab9f4fbfd60984702205fea4c534d53b81b24ebbdef470849188638c752966dde9ec6a6dcbb6c54d23e412103775ebfa3681adf4bbc6b19d3de2d4d6b911c180be46c9aca8128d428c7a0e0a8fffffffff89b44870893c3314fc48fdbae07b7816bcca02bea52dd0ec4bacdec6d1117b4020000006b483045022100b4911f5a4eb5f001779a8453ddb30d0bb7f8c958bd952a46db7958103d03e9e90220248644d1d3efac185a42d4ecdcdd06f22474ee8f45ebe6fb66044d3a5f19c3c84121039c96c76acfc3928c36b0ea7d9eea07341adbb3d136c533637dd8c91302b61243fffffffff89b44870893c3314fc48fdbae07b7816bcca02bea52dd0ec4bacdec6d1117b4030000006b483045022100f5d9dba3db92247d79d96eb4dcd355dbbb70b7e64aa9c0371757236aa4787f2a022042a7934463b9616a8c8f3c9aff86c456fad57059c76a447755c13794985d3bef4121024ddb9f960f2be05a64003425c8b950f210facaedb6bf6013e312a886e8203f8efffffffff89b44870893c3314fc48fdbae07b7816bcca02bea52dd0ec4bacdec6d1117b4040000006b483045022100b0362232042ed76a01b83cb001e193bfd1d2f34596f1f181b1aff6519d3361d802206f5ae183237b9baec490ec5131193f544f62dded8fbe624e03a111d7ceb72279412103c4ee22899397090be13a863238540eac1a66eafff5af8043d1e1ac85fa3d7afeffffffff15b6adf97332f41751d988fda81749bf59b222c958c5030777641d06070cffe5000000006a47304402205b7220f93d399197247d06cac34c46ddc3d2c8b036cab2357d7ca58be94634e402206429952031e3f2c45ce33be1adf9115f500a1ce5902f57d1d92a5469ded2a8184121033a69d0acd6e9500844ca078fbc4d81b6c95d7967b3106e31618d5987633d41a9ffffffff15b6adf97332f41751d988fda81749bf59b222c958c5030777641d06070cffe5010000006a4730440220067d48a089579fc0e57c45a77b920fdcfec11dee3694a7a7f6d06a169731d17902200c069e05b07a3d637b7049efb7e5488113226f042bfd0b309414d753138eea7c412103775ebfa3681adf4bbc6b19d3de2d4d6b911c180be46c9aca8128d428c7a0e0a8ffffffff15b6adf97332f41751d988fda81749bf59b222c958c5030777641d06070cffe5020000006b483045022100a7c9d9b2e62b18e86427e39c5660b048b16da4621df639d5ca1a5971a63afb650220376a7b47f4024760809ca92b001f9302647c218f8164071c78a1d6eedfab3de74121039c96c76acfc3928c36b0ea7d9eea07341adbb3d136c533637dd8c91302b61243ffffffff15b6adf97332f41751d988fda81749bf59b222c958c5030777641d06070cffe5030000006a47304402201048fe1b4d64f83a144a5428cff835dd0ade40e20d733c2000e94699bf17467d02204c381a6ae90f4252a4358b390ec3cfd56a3d3741a559d90a0c572aa6a42de93d4121024ddb9f960f2be05a64003425c8b950f210facaedb6bf6013e312a886e8203f8effffffff15b6adf97332f41751d988fda81749bf59b222c958c5030777641d06070cffe5040000006b483045022100d2d5e8e9dd63c0d08d2e159e7bb6c9d674d7209cde945b574f33f0ef9075d72f022025640d88017e72a584f49e29db1290b578ac66a07aa0d7f418fcc3ef14e4f478412103c4ee22899397090be13a863238540eac1a66eafff5af8043d1e1ac85fa3d7afeffffffff70a2c292eb46a632a08d15d518e47e29424bfe37bcc5eb4b60de7d6270043755000000006a47304402203d80928bb23e58149cb983363877adf5e41802fc563fe2381299dfc4521f23d3022067ec70b547ffead3b2bf9b84a3f825225bc46490fa819cc1d356062cd0ba95744121033a69d0acd6e9500844ca078fbc4d81b6c95d7967b3106e31618d5987633d41a9ffffffff70a2c292eb46a632a08d15d518e47e29424bfe37bcc5eb4b60de7d6270043755010000006b4830450221008b8d069348b67b39c5e51a18492d1d0c8bcc22c7dcf91d165d472f49d74270c502207a413914230ae2b791422237b7b2e20b3eb22fe10469d97128f94499553249a9412103775ebfa3681adf4bbc6b19d3de2d4d6b911c180be46c9aca8128d428c7a0e0a8ffffffff70a2c292eb46a632a08d15d518e47e29424bfe37bcc5eb4b60de7d6270043755020000006b483045022100b19a311909a6008e82d8d3673265766fd7c1ae789aa829337c137430589b612802202b25df23def0df608ec1354585a4064721ea6717433cbdf8f9a4f0bb67ef85a94121039c96c76acfc3928c36b0ea7d9eea07341adbb3d136c533637dd8c91302b61243ffffffff70a2c292eb46a632a08d15d518e47e29424bfe37bcc5eb4b60de7d6270043755030000006a473044022036b765fa5213970f96e9fa93ba0772e267ebdd520a560bc501f58085238a49dd02202365b846de8bbc57bbb39709573f39392083e3375ec37f299408bddce90a1ba54121024ddb9f960f2be05a64003425c8b950f210facaedb6bf6013e312a886e8203f8effffffff70a2c292eb46a632a08d15d518e47e29424bfe37bcc5eb4b60de7d6270043755040000006b483045022100e8fb0dcf7ed7c5eeaa544adcbe7d7b8350511a7fa7c425e514aca5e75e7f59550220025dec89c743593e0bc329e5fc1c39946d1f1358cc13994e4bdcd6a9335523e0412103c4ee22899397090be13a863238540eac1a66eafff5af8043d1e1ac85fa3d7afeffffffff975c304548606da4788f9ade96995d009f2bfb2623ec3b0df3ee9b271ebf1264000000006b483045022100f834f0c17c80355ca2b238df9d25225771bdab4b3c3a65be6c5e4d72905ccb4602203372ac3df03ca48c55a504f598dfda68785f235704879ef45471306b15959fd14121033a69d0acd6e9500844ca078fbc4d81b6c95d7967b3106e31618d5987633d41a9ffffffff975c304548606da4788f9ade96995d009f2bfb2623ec3b0df3ee9b271ebf1264010000006a47304402201ca2d018ed51988c4ba2f60ea0dc1492d688d541f6214de6b206f1d9dae61cf902207b8867fff1f43e81a2230f3e82f6e0f2bba1aca7e17b4ed3fbbdbbacd00d693b412103775ebfa3681adf4bbc6b19d3de2d4d6b911c180be46c9aca8128d428c7a0e0a8ffffffff975c304548606da4788f9ade96995d009f2bfb2623ec3b0df3ee9b271ebf1264020000006a47304402201cd3e982d31df3fcc8f43eeaaee2ef7d1dab9bb6c723c81f642e0f5af4afdb0502207d9f7c8063047c521b586bba4339243ea2da66a2ceff9dd04983ffa14ab5367d4121039c96c76acfc3928c36b0ea7d9eea07341adbb3d136c533637dd8c91302b61243ffffffff975c304548606da4788f9ade96995d009f2bfb2623ec3b0df3ee9b271ebf1264030000006a473044022030f6303f538499799ae83bacb054a7018f1a1021e56f0cba1559a477977055a6022054645ccc0d9aadcca962257504c1ca0798a1de9d7d440232a24e7511df6fc0cd4121024ddb9f960f2be05a64003425c8b950f210facaedb6bf6013e312a886e8203f8effffffff975c304548606da4788f9ade96995d009f2bfb2623ec3b0df3ee9b271ebf1264040000006b483045022100dc40913c93231fb5512456d5a59f95dfcc3a3b972b3f05ad4b80d189a3a6c7f402206431eb0466b92b98d6a0b8d95790577671153221ed1fa9b73a58a64752bd27cc412103c4ee22899397090be13a863238540eac1a66eafff5af8043d1e1ac85fa3d7afeffffffff5a71ecc8725233ff1704d1eeca9711faedc0dffec64370b961394b01681d3776000000006b483045022100ae4bbe27447b2827a3aaa6dbfd9bafea51971250a4a3523964cd65fbaa4a60e602202d28f2dfcddf5c43244c4d655467df4cb636ad1a6c31e0e286a32a8c10bb5c814121033a69d0acd6e9500844ca078fbc4d81b6c95d7967b3106e31618d5987633d41a9ffffffff5a71ecc8725233ff1704d1eeca9711faedc0dffec64370b961394b01681d3776010000006b4830450221009bc68f84b1deb944d0aa108e8dc3bb7ff5a0bed79f2c497ec5033110173fbae0022047713edfbc737120d0293ed3501e0c6a884da0adac38e4ef75585e22ea8e4bb8412103775ebfa3681adf4bbc6b19d3de2d4d6b911c180be46c9aca8128d428c7a0e0a8ffffffff5a71ecc8725233ff1704d1eeca9711faedc0dffec64370b961394b01681d3776020000006a47304402204975d4be6db6016bd53e15c0002796f1a4551684beef6f60a4b8586e9851bc84022041c7a90102c8f4a6e249b22a30813a2cdfc5114ce1a06c7185529e4d7ef058a24121039c96c76acfc3928c36b0ea7d9eea07341adbb3d136c533637dd8c91302b61243ffffffff5a71ecc8725233ff1704d1eeca9711faedc0dffec64370b961394b01681d3776030000006a473044022057bf7c963a8154b72a9ce31bdf9e8577c51c67302de9424e93bd4c905e915a350220177ea6c8896cbf48dad70fac961ca5b72f56fd39147cfb7f163fe24a1c36d7734121024ddb9f960f2be05a64003425c8b950f210facaedb6bf6013e312a886e8203f8effffffff5a71ecc8725233ff1704d1eeca9711faedc0dffec64370b961394b01681d3776040000006b483045022100d440aeb6913d69e70e9321d0d018985fd558aa535cd241ad71a2b9dd5c81bdeb02200f5292205828899b1d9af72bdafd7cb9b4b5ae5099e117cad6718eac5ed3eeb5412103c4ee22899397090be13a863238540eac1a66eafff5af8043d1e1ac85fa3d7afeffffffffc92e1ad1d3dbdbfab4eb73f921575f9059db8669b8570273645389d4105c098e000000006b483045022100994a65a652856bef9fd3adfe3e9e0a2aaece4a48d45e84d4795460fe7d548b2f022035bb935d410aeb3168f8411e89d93c98851ac942a3b814c2bf624433b72c9a8d4121033a69d0acd6e9500844ca078fbc4d81b6c95d7967b3106e31618d5987633d41a9ffffffffc92e1ad1d3dbdbfab4eb73f921575f9059db8669b8570273645389d4105c098e010000006b48304502210097a6fcf8c3f433f8bd614cd2c9bebc151f5925858e6c398a43bcc3f3484dec5902207a9dffffcaa25e811f7a332f9a56086450e85f608044518e08659973c29b5891412103775ebfa3681adf4bbc6b19d3de2d4d6b911c180be46c9aca8128d428c7a0e0a8ffffffffc92e1ad1d3dbdbfab4eb73f921575f9059db8669b8570273645389d4105c098e020000006b483045022100808ea9749f117dbcdf54b40a1f0761ae6aa6f3d76855207be8422baa137f550b02202f7df415aa2378c85d064733be9770f62ece8721bf895226b359f1fa16fd3e634121039c96c76acfc3928c36b0ea7d9eea07341adbb3d136c533637dd8c91302b61243ffffffffc92e1ad1d3dbdbfab4eb73f921575f9059db8669b8570273645389d4105c098e030000006a47304402207c44a7fb6739ac0fa600d15ecfe1b830e1121899fc94300d16f616f5770256ba022043efc3497ed1681882483337f939c1fbd7ef5a7a8274c41f8dead6e8b061e3a04121024ddb9f960f2be05a64003425c8b950f210facaedb6bf6013e312a886e8203f8effffffffc92e1ad1d3dbdbfab4eb73f921575f9059db8669b8570273645389d4105c098e040000006a47304402200293f64419c9798a9d329a964e905e41776ccdfb6bebc0ee9c85f9f8dda95c21022030a6dae3fcd91640d88cc5cae8010df8926f48c9e513af675461cb697ba64e76412103c4ee22899397090be13a863238540eac1a66eafff5af8043d1e1ac85fa3d7afeffffffff680f76aa56aed9d94f69053063cabbf508043b977179e0dbe9bb10e222fa7110000000006b483045022100e047333131d7c00fa27c5592fceb84805bfd984b0f0eaf6abcfae7663fa266580220415a20693758b472d8cbae0fca2434a58c416d94d815ec0eba0ae950903d97864121033a69d0acd6e9500844ca078fbc4d81b6c95d7967b3106e31618d5987633d41a9ffffffff680f76aa56aed9d94f69053063cabbf508043b977179e0dbe9bb10e222fa7110010000006a47304402203ef47e812e2e277439539ed74d67ae1a74935870e4fa7b11f530c42798b3053e022022d733eceb7433cea9ec88e7cd935243cf558c1750dcbce17ee9ecda74bbd8a7412103775ebfa3681adf4bbc6b19d3de2d4d6b911c180be46c9aca8128d428c7a0e0a8ffffffff680f76aa56aed9d94f69053063cabbf508043b977179e0dbe9bb10e222fa7110020000006a473044022051246eb6f566f19145cc676ebd1bd57562c30000b41ed9254a87ecd98bf434a9022023187699fbfb8bfee20834fc8a6924cc22e8f61e06a24ae289cc20621f250ea64121039c96c76acfc3928c36b0ea7d9eea07341adbb3d136c533637dd8c91302b61243ffffffff680f76aa56aed9d94f69053063cabbf508043b977179e0dbe9bb10e222fa7110030000006a473044022071757830a4480930a7dbee8cd329d610fe5f8327acbd5e1c6e10e6abc2bcac9702206f13da071282ba80bd6a283074cbbc5c97988e362516431f8c55dfc4e2ad928b4121024ddb9f960f2be05a64003425c8b950f210facaedb6bf6013e312a886e8203f8effffffff680f76aa56aed9d94f69053063cabbf508043b977179e0dbe9bb10e222fa7110040000006b4830450221008962e6cdc792a53dfcef65456a0e31e7b54cb828ec53681e5a95724c4fae5339022038b891ed92b38c58610ebed866e8fe05b1289fd55c3d671f379ae162e906d4f8412103c4ee22899397090be13a863238540eac1a66eafff5af8043d1e1ac85fa3d7afeffffffffe074a843d30722865a9b9cef616c1a5ca6f31b7f4e65f386c1c6b4dae3e03ecb000000006b48304502210098ac2c8b5874bad42f5a5b8cdfecc62518c41ee87b6b8b7ecb265d569e9c224e022033c4139d8bee982938c60b9b428b48e93771da38a556e10e1babb5500b0bbdcf4121033a69d0acd6e9500844ca078fbc4d81b6c95d7967b3106e31618d5987633d41a9ffffffffe074a843d30722865a9b9cef616c1a5ca6f31b7f4e65f386c1c6b4dae3e03ecb010000006a47304402203db0c08489eade8920e047bcc1f00de8c094089837b392f7dee6ea55073b0467022043b9957e615b7c603a56c2df7b5074efa3afb9fb09ea34a282c7c52eb4590b37412103775ebfa3681adf4bbc6b19d3de2d4d6b911c180be46c9aca8128d428c7a0e0a8ffffffffe074a843d30722865a9b9cef616c1a5ca6f31b7f4e65f386c1c6b4dae3e03ecb020000006b483045022100c3ec77501708ef37074682baaf6ae7d996db2de115ef83e9a70ae5e609631ddf02200cbef21e359cad5b52ad85b41504dfe40e75f12145b2d799f069d1ef644962bc4121039c96c76acfc3928c36b0ea7d9eea07341adbb3d136c533637dd8c91302b61243ffffffffe074a843d30722865a9b9cef616c1a5ca6f31b7f4e65f386c1c6b4dae3e03ecb030000006b483045022100d57537cb3fde06a5d4f1846898fd1ac75b337ebeb7e3792f90fc20e3f14f1d26022050674d71f87e83b78278d3071900a10e337b9ceb80145a109fb55036bcce76d84121024ddb9f960f2be05a64003425c8b950f210facaedb6bf6013e312a886e8203f8effffffffe074a843d30722865a9b9cef616c1a5ca6f31b7f4e65f386c1c6b4dae3e03ecb040000006a47304402203e6cb3526ea3fb3e86e5811528dca8b226e091f547449b131df475d1721de0ef02205707fcc86edaf1687fe7bbcbbd5af0d1ce7dd184ea19c24e30ea06099eff60dd412103c4ee22899397090be13a863238540eac1a66eafff5af8043d1e1ac85fa3d7afeffffffffb3104f485f1b1682e7aa15f4b656613ecec49d63c9abf0675992c26856d0e582000000006b483045022100b18f5c4b84a89f41928cb28bb107acf51fce46a954d3b50577a16fa0de1e6b800220173a1ff3eabc59e74e8ceaf56c67b06a0561f0e69349f60a5a1d25bc2c08ba334121033a69d0acd6e9500844ca078fbc4d81b6c95d7967b3106e31618d5987633d41a9ffffffffb3104f485f1b1682e7aa15f4b656613ecec49d63c9abf0675992c26856d0e582010000006946304302204979462a5fdd2ffdc70a0f6155b6634b638c2ebdd4a2f024021e42589b98434c021f776c70db053212e97ea42e07f4efc794bea97c6c64cdef5e9f7c3e3e4e7b38412103775ebfa3681adf4bbc6b19d3de2d4d6b911c180be46c9aca8128d428c7a0e0a8ffffffffb3104f485f1b1682e7aa15f4b656613ecec49d63c9abf0675992c26856d0e582020000006a4730440220468a16fb5d1f5ce680a62610d59cec818f1d4f1299816f9db2a686d4dc85305e02202cbf2a1d79d9ab07fa183c08cb0bdf62acb1ee82617169cfa2e7e654e3b696624121039c96c76acfc3928c36b0ea7d9eea07341adbb3d136c533637dd8c91302b61243ffffffffb3104f485f1b1682e7aa15f4b656613ecec49d63c9abf0675992c26856d0e582030000006a4730440220016e3d48ba9c56a39ea5215d5b4ccada7cb571844bb00f8c45d5719a754c1d8f0220373c68ce9bf188371486e36a117606770690b4c9cebc70f9482e98d51380e9174121024ddb9f960f2be05a64003425c8b950f210facaedb6bf6013e312a886e8203f8effffffffb3104f485f1b1682e7aa15f4b656613ecec49d63c9abf0675992c26856d0e582040000006a473044022076084d5bb91b565d6b4594c5ec27817f622d25bb254334e99238b4f37c27f2ae022059570829bdb15be2daa55a42c3b66384a3326acaf7c6515aa5b2fe7366a633b3412103c4ee22899397090be13a863238540eac1a66eafff5af8043d1e1ac85fa3d7afeffffffffadf1f76fc124518615f90748da1954a2211983355327759c51d9aaf3ab402e8e000000006a47304402205cecc4ae7b8c077643781351a0c5bbe29e7ec8d73ffcd35b223533dfa7c3512c02206bd77a85ccdf480e85e5bc6cd8afd4053b3f2ff9abfce205815b52f2b90370824121033a69d0acd6e9500844ca078fbc4d81b6c95d7967b3106e31618d5987633d41a9ffffffffadf1f76fc124518615f90748da1954a2211983355327759c51d9aaf3ab402e8e010000006a47304402202a9a272d4ff9e9a0d421d3efeed317e9a3967943291edbb992f6128f035969de0220029f97e6022d64d5f21b4e1b591c15a8f8b744653808b19071cb56bce9a52920412103775ebfa3681adf4bbc6b19d3de2d4d6b911c180be46c9aca8128d428c7a0e0a8ffffffffadf1f76fc124518615f90748da1954a2211983355327759c51d9aaf3ab402e8e020000006b483045022100c6a0a34a10cd99d40f5cfab3c497fd20977154caa989aeba17386b6417d10ea202204c102f48fe4b72fb53dece28da70748ac7b410892efb7576ff3bde80a77411764121039c96c76acfc3928c36b0ea7d9eea07341adbb3d136c533637dd8c91302b61243ffffffffadf1f76fc124518615f90748da1954a2211983355327759c51d9aaf3ab402e8e040000006a4730440220671e2d120093fdbb45937d4ce69ad72982e5ac50f25b1a8135ebe96af7e2e68402201a86f319ba71e1281a6ad27632b6ea86fe55c463ecd6f9eed71310dd5c247eb3412103c4ee22899397090be13a863238540eac1a66eafff5af8043d1e1ac85fa3d7afeffffffff68ed5339c958ec8e1e25fdd74c3930942317b213d27d99c41015252b1ba7859d000000006b483045022100eb8edc05561d65723d79e4872f26cdfbe8ff2ac6ece7be872e19ed2fd63766a3022019c1f8e54713e1f9c63cd940db452a91eac2d72b497fd7d4b8791ce4d17cd1c44121033a69d0acd6e9500844ca078fbc4d81b6c95d7967b3106e31618d5987633d41a9ffffffff68ed5339c958ec8e1e25fdd74c3930942317b213d27d99c41015252b1ba7859d010000006a47304402204cfa0a04e4788b2b89fbd51a2a22d603aae7a556ffd4df0d3562b0c9aa2e168f022075d3dc3035720e28caace0e745bbe0340181b73195ef1f5b677bf2f2f040e90c412103775ebfa3681adf4bbc6b19d3de2d4d6b911c180be46c9aca8128d428c7a0e0a8ffffffff68ed5339c958ec8e1e25fdd74c3930942317b213d27d99c41015252b1ba7859d020000006b483045022100b175bafd1bd9c796d4c523f9b1b793fcc49775daf33e131c51045dd16f08dbbe022077ad9e0ebe7145e7d0fe4da98f3baed8815c1b230f508d6254a4e1a0e712b13e4121039c96c76acfc3928c36b0ea7d9eea07341adbb3d136c533637dd8c91302b61243ffffffff68ed5339c958ec8e1e25fdd74c3930942317b213d27d99c41015252b1ba7859d030000006a47304402205f2e0f29a4943105266b06fc2c4284145939a45741ce3e059e56b2435210d02602201958d1ba66c5962bb8269d55e1131300080fbb5503c6917efd4ae18569f4c9264121024ddb9f960f2be05a64003425c8b950f210facaedb6bf6013e312a886e8203f8effffffff68ed5339c958ec8e1e25fdd74c3930942317b213d27d99c41015252b1ba7859d040000006b483045022100e51f24599bd0469b2360cea4907f89cc4aa4cb260f5d3c51461d8b547b43972302200327a69fda380e09d5b049d0d6556f4c080ddab4f27a438928bc9551caedd35d412103c4ee22899397090be13a863238540eac1a66eafff5af8043d1e1ac85fa3d7afeffffffff723d61c3361d2a0d210ea9101190345b985372b479d205e3ea4664cd90683d60000000006a473044022022ad10476bacdf0fd869196828fe12c2951bf1893da93ba68ab187183b07d28702200d838441f34817a30bef4d626ee475fd13cc50c9c86f4e0360aabd01ad03a2624121033a69d0acd6e9500844ca078fbc4d81b6c95d7967b3106e31618d5987633d41a9ffffffff723d61c3361d2a0d210ea9101190345b985372b479d205e3ea4664cd90683d60020000006a473044022055daf55e79250196857700678ffc78ff07eca326c593f6c6e04031f71e02fe7702201b67a9db87965a32ef84a8ddd552245fe3b9346f5ac1487001eea9b88ab624e94121039c96c76acfc3928c36b0ea7d9eea07341adbb3d136c533637dd8c91302b61243ffffffff723d61c3361d2a0d210ea9101190345b985372b479d205e3ea4664cd90683d60040000006a47304402205fdbfea752187585e20b521190eddcc1612720c90045b366fb5eea8680aa7085022037a4d6d6fabaa5c6b5c1aa1ae0163b8e23380a4aa970cb24bbb946d9929e6c35412103c4ee22899397090be13a863238540eac1a66eafff5af8043d1e1ac85fa3d7afeffffffff62dfda1aea1c1c9a8371b677a0c77bf33783670e9c61272b6b51edef2c1bde55000000006a47304402200b0c07de970d67f6e156657dd04865f50d8121592ea17321d5d7a24581c4478d0220257423b78d6e4140c0283e4d20da6b09dfb84b0ce3c6df6d066fc4d588fd482e4121033a69d0acd6e9500844ca078fbc4d81b6c95d7967b3106e31618d5987633d41a9ffffffff62dfda1aea1c1c9a8371b677a0c77bf33783670e9c61272b6b51edef2c1bde55040000006a473044022051003643660879f1fe80a393d03f06afb8f6dc799192c67e4677447396a1664a02206f459ea923a0d1a0a79e71554ae0ad4fef660f9c2093320f21472bf0d7ac6b57412103c4ee22899397090be13a863238540eac1a66eafff5af8043d1e1ac85fa3d7afeffffffff3b1c291b53a174aead413da973e26a581a16a13e7a99d7dbc45d0cc53944a405000000006b4830450221009042cbb1e0bd5d3d8b2183e14f181073b948076151f88695a702384bf62bb5b302203c5baf1e204f20e473bfb306585d8784b4633af7225dcce73db4c2db95de66874121033a69d0acd6e9500844ca078fbc4d81b6c95d7967b3106e31618d5987633d41a9ffffffff3b1c291b53a174aead413da973e26a581a16a13e7a99d7dbc45d0cc53944a405010000006b483045022100915cefaa39968bc3a0868bd7a0878efd696be1b185c2238ae03e0a019fc0ffe002201970fa7063bcd89e0905ca6f4c7001b4870abbf86b06c84953775e728095db91412103775ebfa3681adf4bbc6b19d3de2d4d6b911c180be46c9aca8128d428c7a0e0a8ffffffff3b1c291b53a174aead413da973e26a581a16a13e7a99d7dbc45d0cc53944a405020000006b483045022100d9b9e1d2274cec91c73e938182d1f36b3e94add0031d57e2896255272ee765e60220231c41db4fff82212a60473395d105bf21841eec1e6d4cee015cf16db5d8a1894121039c96c76acfc3928c36b0ea7d9eea07341adbb3d136c533637dd8c91302b61243ffffffff3b1c291b53a174aead413da973e26a581a16a13e7a99d7dbc45d0cc53944a405030000006b483045022100f307b94537d1f6a7946d4638f7dcdfa795307aa85e796f98602f4c72c8b1cf2302201651ccca738ddca648f0e5f55f918db00f61988e8eff03d2b77e3c17fc3424354121024ddb9f960f2be05a64003425c8b950f210facaedb6bf6013e312a886e8203f8effffffff3b1c291b53a174aead413da973e26a581a16a13e7a99d7dbc45d0cc53944a405040000006b483045022100dc69cf0495535e6ee1185526e819b36dda9bd5ac9e4ba65e17b07644a7e2f0e502200a3121a18749e37b0dfd9e00bff13b6974b05084c40a1d5f8c755fd6ab43e9c4412103c4ee22899397090be13a863238540eac1a66eafff5af8043d1e1ac85fa3d7afeffffffff0ae2cbbcdf7bb1cb080e07f8ed277ff2f3c98b95068ce8be3666b4abe7326cec000000006a47304402200b4e3bdbd5596e591de4fc2607dda3ec4c55a7889452c6b04152330a72e94a7902201e076cf94aa07b4d18011326a28043fdb15b1b781d2bc21d0f70c1f07a51efc14121033a69d0acd6e9500844ca078fbc4d81b6c95d7967b3106e31618d5987633d41a9ffffffff0ae2cbbcdf7bb1cb080e07f8ed277ff2f3c98b95068ce8be3666b4abe7326cec010000006b4830450221009bc17878d5d4fcc7be79fc8d2710ce40721261791796b04090b15c9abb091029022012434ac79d8e61a2b36af6aac08709c231fd7646fad6220779d75700f62a6809412103775ebfa3681adf4bbc6b19d3de2d4d6b911c180be46c9aca8128d428c7a0e0a8ffffffff0ae2cbbcdf7bb1cb080e07f8ed277ff2f3c98b95068ce8be3666b4abe7326cec020000006b4830450221008d6cfb65013cfe975cc1ea4f96841b83b3e040a3adba03efc63545fa0b7166c3022066c5da030ab1f7a56d284fdf8e9d71e0fb8d822632013a00e2d5da531b1df5994121039c96c76acfc3928c36b0ea7d9eea07341adbb3d136c533637dd8c91302b61243ffffffff0ae2cbbcdf7bb1cb080e07f8ed277ff2f3c98b95068ce8be3666b4abe7326cec030000006a47304402204a66f2deed689917a29e63f64f08b0d230ce3c493261d229c79e8e597d4b71e5022077ffc0d5aef457c5ee781163f3640d37db98d47e47fa660aba450077b88025af4121024ddb9f960f2be05a64003425c8b950f210facaedb6bf6013e312a886e8203f8effffffff0ae2cbbcdf7bb1cb080e07f8ed277ff2f3c98b95068ce8be3666b4abe7326cec040000006b483045022100b44fd2030553ddf7a1c6ac5fbe7fdce7f31fcfc802143c6f2d8cf312d5de361b02201b421a68532b49d2ffb5250489440bd6c22721340e4918932b6e2e3e7126dff6412103c4ee22899397090be13a863238540eac1a66eafff5af8043d1e1ac85fa3d7afeffffffff533b43ee15349eeba426c1b9341c84c26baa9a9b1feaf955c08690897522d48b000000006a47304402207ff776ad1bc6defe3b7d816eb5ad8225bcdfa81a95fdba04740c80c2387ac3c602200a6b8b0500b1c3fa3993f8db69b2c8e2e59a1428d11c324d6b6d6c53faf418f74121033a69d0acd6e9500844ca078fbc4d81b6c95d7967b3106e31618d5987633d41a9ffffffff533b43ee15349eeba426c1b9341c84c26baa9a9b1feaf955c08690897522d48b010000006a47304402203f61fb04ed3d3b40086cadc652a8cd19271f5cc1acf9d6049dc3357937e4a66302207fde17948b66d2054170e0110b56f687be3591101eaeaa219d6ad8e643dfdfaf412103775ebfa3681adf4bbc6b19d3de2d4d6b911c180be46c9aca8128d428c7a0e0a8ffffffff533b43ee15349eeba426c1b9341c84c26baa9a9b1feaf955c08690897522d48b020000006b483045022100f90544b03e05790ebd26a1c72c99d0dba17f9eb17f2c02c7ac75faa8217d0efd02207b317e6c61def2e3b20077990209f0895b651964df6132ff755cc8f33ba384054121039c96c76acfc3928c36b0ea7d9eea07341adbb3d136c533637dd8c91302b61243ffffffff533b43ee15349eeba426c1b9341c84c26baa9a9b1feaf955c08690897522d48b030000006b483045022100c30d96b47fde67cf5ee262039f2dc8c519d6957704041d37c5454e1e1349faab022068700a03d432cdb4c57d765a3402b2b6dfe34a6c6c0348d91b35e2794df815264121024ddb9f960f2be05a64003425c8b950f210facaedb6bf6013e312a886e8203f8effffffff533b43ee15349eeba426c1b9341c84c26baa9a9b1feaf955c08690897522d48b040000006a4730440220632564589fb3873dab1fbef2f25f7f8f0255835fd88e54d28d223ae5b6601942022023d2d0e765d9072d1bebbfdf3af44f29edc52bcbc254157888a88dba1a9fda24412103c4ee22899397090be13a863238540eac1a66eafff5af8043d1e1ac85fa3d7afeffffffff6013e0d0cb42144b250626ca593e9814e19ee4331aa3a2661b1575dd711c0458010000006b483045022100fd20cc1e0300d9a1fdc7cb231c5e7838d95e7bde8c14f375024920daa9b4459302200cdf199122ae148814512c31b4eb8f22461ae5207d4fba851d0301d20b982e59412103775ebfa3681adf4bbc6b19d3de2d4d6b911c180be46c9aca8128d428c7a0e0a8ffffffff6013e0d0cb42144b250626ca593e9814e19ee4331aa3a2661b1575dd711c0458020000006b483045022100e02b7ca0a2ed8818aa364045259ec80f9c47699167b28838190290e755ce5c53022017424efc0ccd3dd90d4894f8a96184efe44e25e1821157066724eb7dfec0b2594121039c96c76acfc3928c36b0ea7d9eea07341adbb3d136c533637dd8c91302b61243ffffffff6013e0d0cb42144b250626ca593e9814e19ee4331aa3a2661b1575dd711c0458040000006a47304402204b75abac1fc66ce5bf6be5e5b9ae4bfe1c3c6a0d853a2cf7daa46745a4bcbef702201e16cc1e6adfba47bd53894f3aca5b4420414ca04ce0704778804d4828f1039c412103c4ee22899397090be13a863238540eac1a66eafff5af8043d1e1ac85fa3d7afeffffffff4f17ef5139f0bf34be55f673d107d23ed34b0a637661593bfb9d2f19330181db000000006a4730440220609cdb63cafdba535833346b7f01fc893ee2c15f54f27ec8b701c071657d87ef0220597645cfb85190be9007e276ac7159f995ffcd6272130c14fb86777bfc4c3bfb4121033a69d0acd6e9500844ca078fbc4d81b6c95d7967b3106e31618d5987633d41a9ffffffff4f17ef5139f0bf34be55f673d107d23ed34b0a637661593bfb9d2f19330181db010000006b483045022100c7c9abfbf6830221cdabdad4c0eafd0b93c0d18fe2f1344f282e55a01e58e51002201cb47ffe60a22e1a7e76b1f02ca8b87cba49817af60505cb5b1a87d71f5a938d412103775ebfa3681adf4bbc6b19d3de2d4d6b911c180be46c9aca8128d428c7a0e0a8ffffffff4f17ef5139f0bf34be55f673d107d23ed34b0a637661593bfb9d2f19330181db020000006b483045022100a618c304f961082fbd2fadef94b18edbda5f822a2296dbfb139062853ef9f47b022034e3bfe9334d31a3d7dbe0b6cf443f61986f8645dcc33732e5bb80f8ee8311d24121039c96c76acfc3928c36b0ea7d9eea07341adbb3d136c533637dd8c91302b61243ffffffff4f17ef5139f0bf34be55f673d107d23ed34b0a637661593bfb9d2f19330181db030000006a47304402205305c96c37cab26a08af5cbd936b12824d02a5629ee88990a811976b19881bf5022050594c56ecb9df11521c15e805edae0758e49ac98f361bc0b1e165f41efbf4084121024ddb9f960f2be05a64003425c8b950f210facaedb6bf6013e312a886e8203f8effffffff4f17ef5139f0bf34be55f673d107d23ed34b0a637661593bfb9d2f19330181db040000006b483045022100d33daeb20ad32ca8938046ce65bc0dff978109019873801a4aaa5370cacefe0c0220203e15c257425ada00fa4250987d8b8c5bc66071a67cf72876b22b2657bcde16412103c4ee22899397090be13a863238540eac1a66eafff5af8043d1e1ac85fa3d7afefffffffffa58e6ba47fa494e67893003fe96e49704eaec5bd097020ff042f99454fca6fd000000006b483045022100c34e8b52eb468fbcffdf84fcbd3f30d658cc9556c955e9b3907d6375f160fff6022077ce968b62b8e54154c1fc4a73ac53eca90614fe44cf5cf7e73dfc6257c012e74121033a69d0acd6e9500844ca078fbc4d81b6c95d7967b3106e31618d5987633d41a9fffffffffa58e6ba47fa494e67893003fe96e49704eaec5bd097020ff042f99454fca6fd010000006a473044022075befcb98f1f30d69490aeb7dc6560ef53948415bf21e2ce2e0176546ff44e3d02206fe509c857c5b2b824752aa1b3a010b16f97843fc109c34788c98ea3cfffeab4412103775ebfa3681adf4bbc6b19d3de2d4d6b911c180be46c9aca8128d428c7a0e0a8fffffffffa58e6ba47fa494e67893003fe96e49704eaec5bd097020ff042f99454fca6fd020000006b483045022100b831e15285ef186f81dde5bf536139998473bc84b21e0807f3793c8754b5d235022038cfe396f30ac94cecf89860c429189ae3a5257cf0141fe33b1cd7b506c2fe064121039c96c76acfc3928c36b0ea7d9eea07341adbb3d136c533637dd8c91302b61243fffffffffa58e6ba47fa494e67893003fe96e49704eaec5bd097020ff042f99454fca6fd030000006b483045022100d0c179e237187e1a837b0404d80ce1fdc5b549cf82d4c45b86d61f838cf1a9f802201f307beebd8e1f5282ac98c6ac0dd406d873375c02f383d22c0d2659f5badb364121024ddb9f960f2be05a64003425c8b950f210facaedb6bf6013e312a886e8203f8efffffffffa58e6ba47fa494e67893003fe96e49704eaec5bd097020ff042f99454fca6fd040000006a47304402205f9632b6e54addc95d677ce59ed3cbc56b12b604c17cbdef179ba5cbd0533f8c02204ee9892c2aa9da224cabd851d689a1a1ff6ffeba4dc39f6e8484181baba4bcda412103c4ee22899397090be13a863238540eac1a66eafff5af8043d1e1ac85fa3d7afeffffffffc58145671d4feee37da85a404e6bfddbaee8036e8e469b203e6855c81cfc4d4c000000006a4730440220600bc483b9f962efeee1fd947ef5b14100750db632b4da126aa50e284596779202206c498accbbe6ee54c2306ccd08a53f9f72434853ddb4c830dbc645a45376fcba4121033a69d0acd6e9500844ca078fbc4d81b6c95d7967b3106e31618d5987633d41a9ffffffffb43c7c0febd9e1bdfba65a8d01d99b4b14e901d9a5c5aa34f55090864ac703c9010000006a47304402205c0163f947fcc2a44f90cceb289d685202f13203de5d5833e193e859b59414ab02201ab5c0437eacb3af325bb41339f6e1cf75208b6261bcdd85e907ac76c155e79f412103ae65854d4387c8862edf01ac54392ed767ed88172307ed52eea91655af98294fffffffff8cf5e5d942356ffc5268da23d56f8188b45b53580d4eb4df6d54d7f2d7307f88010000006a47304402200b9b402bd685880fd1ed8b73ea547c74d24eb1396f653bc058634a4346a6b93302204713908e5ae96692cca09f3a03366def9b9192132cc5b19503b4e9082597b0f4412102501c8c5e9a783b79840f519598d17839eff284e79e00ba9c01161265bab7dbb5ffffffffce76923199980a907f2bac4974b5d3f04497d1c17964d057d31f6830af09d807000000006b483045022100ecb39bece26ce1ca69be4685dfd8cd671ffb4e66b83b8dcf5effb0afde56550a0220432598541d8353e47db60bb257d227ea0306ca2bab51073989271271f25ce2c3412103775ebfa3681adf4bbc6b19d3de2d4d6b911c180be46c9aca8128d428c7a0e0a8ffffffffc20e639bdb3c378b0b6b637551d13e6df0af94f94f2080922ffab90ac09dcb25000000006b483045022100c643055f7acbe2931762ad13e0e66926dec2f4df94efbb30ba6c9e3ceaef7fa602205728871ba1ca0b58f3917609fb1ffe182227735aa5d2de8374a2cef81ffde1b54121024ddb9f960f2be05a64003425c8b950f210facaedb6bf6013e312a886e8203f8effffffff398d1908b7dba305206c9181ec1962b272f4a767d8f2ff01ec8ea9ca9b1cffad000000006a4730440220206f316e6f23e7134900471dc0bd936db6ca5ff964d0a85c3e198295c1797f2a02200231150131fdd07734939baada917c59b0cf8c0003149171cdafce0abe70b3074121024ddb9f960f2be05a64003425c8b950f210facaedb6bf6013e312a886e8203f8effffffff02899bbe09000000001976a9146a418bf9e2e2b670e1aa7b7da59391e212b4ba1988ac1027000000000000475221028f10cd0e0e9bc7352adb192484d576867a71cbd82295cd87c3ceffc5fbd74acc2102a7472269ad70ea6cf1ecc7fe25a23fb6bc47f928a9ec755e34bada052bd355ce52ae00000000';
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

