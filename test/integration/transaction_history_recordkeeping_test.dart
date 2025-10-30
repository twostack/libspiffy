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

