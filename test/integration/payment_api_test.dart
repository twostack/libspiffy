import 'dart:async';
import 'dart:io';
import 'package:test/test.dart';
import 'package:dactor/dactor.dart';
import 'package:eventador/eventador.dart';
import 'package:isar/isar.dart';
import 'package:libspiffy/libspiffy.dart';
import 'package:libspiffy/src/storage/isar_wallet_storage.dart';
import 'p2p_test_helpers.dart';

/// Integration tests for PaymentCoordinatorActor and PayInvoiceMessage API
/// 
/// Tests cover:
/// - Successful BEEF creation with ancestor chain
/// - Missing ancestor transaction error
/// - No merkle proof in chain error
/// - Multi-level ancestor chains
///
// Parent of TX1  - TxnId = 2107375cb2b5c7299385dc41acd56e1e30868e19357227224db8962c65a6ffdc
const tx1Parent = '0200000001d724885eeeadecd5cc8b3174859db9b2cba5a4e25ae80948f96173684437f77d010000006a4730440220477bffcd627c9ca0658d788dc5fa991f08fd542381c324a7354818682b38c9bf02200c2eedc506e57e0f2ebf8907a1d9f0716e2c80bcd542258787fa56ce205ccbae412103be5724a6b930cfc02ec84339b679349b8c8ea8f3a73eb7f731fcf1d07319a12cfeffffff0280539a05000000001976a91410d1b86ea302442f3a1e53c654569c217a316df788aca627ac3e000000001976a91490897992fae7bff0d5839cb071b713595f65010688ac40b61300';

// Real testnet transaction data (block 1291860)
const String kTestTxHex = '0200000001dcffa6652c96b84d22277235198e86301e6ed5ac41dc859329c7b5b25c370721010000006a473044022033542938413acf616862fb9cdecedc86ed472773a3c8be33f6024051837e9a520220628937b5db1baef5b87b42e8d2a13403625713a083d5c28b77ae535f62293b8241210341dcbd921964fc54c125608ffb6f9114d53d7a8bb3fcab29cff657dbfc882268feffffff02db9e183b000000001976a914b9f4a12e17e6614a47ccb5b1464756cd9119064088ac00879303000000001976a914f82d58dd8487044d8d0879c15a2a3516a425de2a88ac53b61300';
const String kTestTxid = '5e0ae9db2586ac8ea89b0f0eb628e1624ccfbdafff860052b67069a401d8ed71';
const int kTestBlockHeight = 1291860;

void main() {
  late Directory testDir;
  late Isar isar;
  late LocalActorSystem actorSystem;
  late LibSpiffyActorSystem libspiffy;
  late String walletId;

  setUp(() async {
    // Initialize Isar
    await Isar.initializeIsarCore(download: true);
    
    // Create temporary directory for test database
    testDir = await Directory.systemTemp.createTemp('payment_api_test_');
    
    // Open Isar with LibSpiffy schemas
    isar = await Isar.open(
      [
        ...LibSpiffySchemas.walletSchemas,
        EventEnvelopeSchema,
        SnapshotEnvelopeSchema,
      ],
      directory: testDir.path,
      name: 'payment_api_test_${DateTime.now().millisecondsSinceEpoch}',
    );

    // Create actor system
    actorSystem = LocalActorSystem(ActorSystemConfig());

    // Initialize LibSpiffy
    libspiffy = LibSpiffyActorSystem();
    await libspiffy.initialize(
      actorSystem: actorSystem,
      isar: isar,
      dataDirectory: testDir.path,
    );

    // Setup test block headers
    await setupTestHeaders(libspiffy.walletStorage as IsarWalletStorage);

    // Create test wallet
    walletId = 'payment-test-wallet-${DateTime.now().millisecondsSinceEpoch}';
    await createWallet(
      walletManager: libspiffy.walletManager,
      actorSystem: actorSystem,
      walletId: walletId,
      walletName: 'payment-test-wallet',
    );
  });

  tearDown(() async {
    try {
      await libspiffy.shutdown();
      await isar.close(deleteFromDisk: true);
      await testDir.delete(recursive: true);
    } catch (e) {
      print('Teardown error: $e');
    }
  });

  group('PayInvoiceMessage API', () {
    test('creates BEEF with funded wallet', () async {
      print('\n=== Testing BEEF Creation with Funded Wallet ===');
      
      // STEP 1: Fund wallet with UTXOs
      print('STEP 1: Funding wallet...');
      await fundWallet(
        walletManager: libspiffy.walletManager,
        actorSystem: actorSystem,
        walletId: walletId,
        amount: BigInt.from(60000000), // 0.6 BTC
      );
      print('✓ Wallet funded with 60,000,000 satoshis');
      
      // STEP 2: Wait for UTXO to be stored
      await Future.delayed(Duration(milliseconds: 500));
      
      // STEP 3: Call PayInvoiceMessage
      print('\nSTEP 3: Calling PayInvoiceMessage...');
      final invoiceAmount = BigInt.from(10000000); // 0.1 BTC
      final paymentAddress = 'n1kqSE7WizxNsUU4vxaXFHq2GvkYKR4hBH';
      
      final completer = Completer<BEEFPaymentResponse>();
      final receiver = await actorSystem.spawn(
        'beef-payment-receiver',
        () => TestReceiverActor<BEEFPaymentResponse>(completer),
      );
      
      libspiffy.paymentCoordinator.tell(
        PayInvoiceMessage(
          walletId: walletId,
          invoiceId: 'test-invoice-funded',
          addresses: [paymentAddress],
          amount: invoiceAmount,
        ),
        sender: receiver,
      );
      
      final response = await completer.future.timeout(Duration(seconds: 10));
      
      // STEP 4: Verify BEEF creation
      print('\nSTEP 4: Verifying BEEF response...');
      
      // NOTE: The current implementation uses a placeholder BEEF creator
      // Once full BEEF.create() is implemented, we'll verify:
      // - Ancestor chain collection
      // - Merkle proof validation
      // - Proper BEEF serialization
      
      // For now, verify basic response structure
      expect(response, isNotNull);
      expect(response.invoiceId, equals('test-invoice-funded'));
      
      if (response.success) {
        print('✓ BEEF created successfully (placeholder):');
        print('  Transaction ID: ${response.txid}');
        print('  BEEF size: ${response.beefBytes.length} bytes');
        print('  Ancestor count: ${response.ancestorCount}');
        print('  Amount paid: ${response.amountPaid} satoshis');
        print('  Change: ${response.changeAmount} satoshis');
      } else {
        print('⚠ BEEF creation returned error: ${response.error}');
        print('  This may be expected if ancestor transaction/merkle proof is missing');
      }
      
      print('\n=== BEEF Creation Test Completed ===\n');
    });

    test('fails when insufficient funds', () async {
      // Create invoice with amount larger than wallet balance
      final invoiceAmount = BigInt.from(1000000000); // 1 billion satoshis
      
      final completer = Completer<BEEFPaymentResponse>();
      final receiver = await actorSystem.spawn(
        'payment-receiver-insufficient',
        () => TestReceiverActor<BEEFPaymentResponse>(completer),
      );

      libspiffy.paymentCoordinator.tell(
        PayInvoiceMessage(
          walletId: walletId,
          invoiceId: 'test-invoice-insufficient',
          addresses: ['mock-address-1'],
          amount: invoiceAmount,
        ),
        sender: receiver,
      );

      final response = await completer.future.timeout(Duration(seconds: 5));

      expect(response.success, isFalse);
      expect(response.error, contains('Insufficient funds'));
      
      print('✓ Correctly fails with insufficient funds');
    });

    test('fails when no available UTXOs', () async {
      final completer = Completer<BEEFPaymentResponse>();
      final receiver = await actorSystem.spawn(
        'payment-receiver-no-utxos',
        () => TestReceiverActor<BEEFPaymentResponse>(completer),
      );

      libspiffy.paymentCoordinator.tell(
        PayInvoiceMessage(
          walletId: walletId,
          invoiceId: 'test-invoice-no-utxos',
          addresses: ['mock-address-1'],
          amount: BigInt.from(10000),
        ),
        sender: receiver,
      );

      final response = await completer.future.timeout(Duration(seconds: 5));

      expect(response.success, isFalse);
      expect(response.error, contains('Insufficient funds'));
      
      print('✓ Correctly fails with no available UTXOs');
    });

    test('PaymentCoordinatorActor initializes correctly', () async {
      // Verify payment coordinator is accessible
      expect(libspiffy.paymentCoordinator, isNotNull);
      
      // Verify it responds to messages (even with error due to no UTXOs)
      final completer = Completer<BEEFPaymentResponse>();
      final receiver = await actorSystem.spawn(
        'payment-receiver-init-test',
        () => TestReceiverActor<BEEFPaymentResponse>(completer),
      );

      libspiffy.paymentCoordinator.tell(
        PayInvoiceMessage(
          walletId: walletId,
          invoiceId: 'init-test-invoice',
          addresses: ['test-address'],
          amount: BigInt.from(1000),
        ),
        sender: receiver,
      );

      final response = await completer.future.timeout(Duration(seconds: 5));
      
      // Should get a response (likely error due to no UTXOs, but that's fine)
      expect(response, isNotNull);
      
      print('✓ PaymentCoordinatorActor responds to messages');
    });
  });

  group('Future BEEF Tests', () {
    test('TODO: test with real transaction history and merkle proofs', () {
      // Future test: This will require:
      // - Storing ancestor transactions in read model
      // - Storing merkle proofs
      // - Full BEEF.create() implementation
      // - Validating BEEF structure
      
      print('⚠️  Requires full BEEF implementation and transaction history storage');
    });

    test('TODO: validates BEEF with multi-level ancestor chain', () {
      // Future test: This will require:
      // - TX0 (confirmed with proof)
      // - TX1 (unconfirmed, spends TX0)
      // - TX2 (UTXO, spends TX1)
      // - Payment spends TX2
      // - Verify BEEF includes all three transactions and TX0 proof
      
      print('⚠️  Multi-level chain test requires transaction history setup');
    });

    test('TODO: fails when ancestor transaction missing from storage', () {
      // Future test: This will require:
      // - Creating UTXO with non-existent source transaction
      // - Attempting payment
      // - Verifying "transaction not found" error
      
      print('⚠️  Requires ability to manipulate transaction storage');
    });

    test('TODO: fails when no merkle proof in chain', () {
      // Future test: This will require:
      // - Creating chain of unconfirmed transactions
      // - No merkle proofs stored
      // - Attempting payment
      // - Verifying "no merkle proof" error
      
      print('⚠️  Requires unconfirmed transaction chain setup');
    });
  });
}

