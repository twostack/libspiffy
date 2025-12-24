/// Alice-to-Bob Payment Channel Integration Test
///
/// This test demonstrates a complete payment channel lifecycle between two
/// independent LibSpiffy instances (Alice and Bob).
///
/// Flow:
/// 1. Alice opens a channel to Bob (funding transaction)
/// 2. Alice makes multiple payments to Bob through the channel
/// 3. Channel is closed cooperatively
/// 4. Extended BEEF validation with unconfirmed funding transaction

import 'dart:async';
import 'dart:io';
import 'package:test/test.dart';
import 'package:dactor/dactor.dart';
import 'package:isar/isar.dart';
import 'package:eventador/eventador.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:libspiffy/libspiffy.dart';
import 'package:libspiffy/src/actors/libspiffy_actor_system.dart';
import 'package:libspiffy/src/storage/isar_wallet_storage.dart';
import 'package:libspiffy/src/services/payment_channel_service.dart';
import 'package:libspiffy/src/services/dartsv_crypto_service.dart';
import 'package:libspiffy/src/models/payment_channel.dart';
import '../mocks/mock_arc_service.dart';
import 'p2p_test_helpers.dart';

/// Get public key hex for a wallet
Future<String> getWalletPublicKeyHex({
  required LibSpiffyActorSystem libspiffy,
  required String walletId,
}) async {
  final cryptoService = DartSVCryptoService();
  
  // Get mnemonic from secure storage
  final mnemonic = await libspiffy.secureStorage.getMnemonic(walletId);
  if (mnemonic == null) {
    throw Exception('No mnemonic found for wallet $walletId');
  }
  
  // Derive HD private key
  final hdPrivateKey = await cryptoService.mnemonicToHDPrivateKey(
    mnemonic,
    network: dartsv.NetworkType.TEST,
  );
  
  // Derive a private key (using index 0)
  final privateKey = await cryptoService.derivePrivateKey(hdPrivateKey, 0, 0);
  
  // Get public key
  final publicKey = cryptoService.getPublicKey(privateKey);
  
  return publicKey.toHex();
}

void main() {
  group('Alice-to-Bob Payment Channel Integration', () {
    // Alice's independent LibSpiffy system
    late LibSpiffyActorSystem aliceLibSpiffy;
    late Isar aliceIsar;
    late LocalActorSystem aliceActorSystem;
    late Directory aliceTestDir;
    late String aliceWalletId;
    late PaymentChannelService aliceChannelService;

    // Bob's independent LibSpiffy system
    late LibSpiffyActorSystem bobLibSpiffy;
    late Isar bobIsar;
    late LocalActorSystem bobActorSystem;
    late Directory bobTestDir;
    late String bobWalletId;
    late PaymentChannelService bobChannelService;

    // Mocked external services
    late MockArcService mockArc;

    // Database names for restart tests
    late String aliceDbName;
    late String bobDbName;

    setUp(() async {
      print('\n--- Setting up Alice and Bob systems for payment channels ---');

      // Initialize Isar core
      await Isar.initializeIsarCore(download: true);

      // Initialize mocks
      mockArc = MockArcService();

      // Create temporary directories
      aliceTestDir = await Directory.systemTemp.createTemp('alice_channel_');
      bobTestDir = await Directory.systemTemp.createTemp('bob_channel_');

      print('Alice DB: ${aliceTestDir.path}');
      print('Bob DB: ${bobTestDir.path}');

      // Initialize Alice's system
      aliceActorSystem = LocalActorSystem(ActorSystemConfig());
      aliceDbName = 'alice_channel_${DateTime.now().microsecondsSinceEpoch}';
      aliceIsar = await Isar.open(
        [
          ...LibSpiffySchemas.walletSchemas,
          EventEnvelopeSchema,
          SnapshotEnvelopeSchema,
        ],
        directory: aliceTestDir.path,
        name: aliceDbName,
      );
      aliceLibSpiffy = LibSpiffyActorSystem();
      await aliceLibSpiffy.initialize(
        actorSystem: aliceActorSystem,
        isar: aliceIsar,
        dataDirectory: aliceTestDir.path,
        enableP2P: false,
      );

      // Setup test headers for Alice
      await setupTestHeaders(aliceLibSpiffy.walletStorage as IsarWalletStorage);

      // Create Alice's wallet
      aliceWalletId = 'alice-wallet-${DateTime.now().millisecondsSinceEpoch}';
      await createWallet(
        walletManager: aliceLibSpiffy.walletManager,
        actorSystem: aliceActorSystem,
        walletId: aliceWalletId,
        walletName: 'Alice Wallet',
      );

      // Create Alice's channel service
      aliceChannelService = PaymentChannelService(
        storage: aliceLibSpiffy.walletStorage,
        secureStorage: aliceLibSpiffy.secureStorage,
        cryptoService: DartSVCryptoService(),
      );

      print('✓ Alice system initialized with wallet: $aliceWalletId');

      // Initialize Bob's system
      bobActorSystem = LocalActorSystem(ActorSystemConfig());
      bobDbName = 'bob_channel_${DateTime.now().microsecondsSinceEpoch}';
      bobIsar = await Isar.open(
        [
          ...LibSpiffySchemas.walletSchemas,
          EventEnvelopeSchema,
          SnapshotEnvelopeSchema,
        ],
        directory: bobTestDir.path,
        name: bobDbName,
      );
      bobLibSpiffy = LibSpiffyActorSystem();
      await bobLibSpiffy.initialize(
        actorSystem: bobActorSystem,
        isar: bobIsar,
        dataDirectory: bobTestDir.path,
        enableP2P: false,
      );

      // Setup test headers for Bob
      await setupTestHeaders(bobLibSpiffy.walletStorage as IsarWalletStorage);

      // Create Bob's wallet
      bobWalletId = 'bob-wallet-${DateTime.now().millisecondsSinceEpoch}';
      await createWallet(
        walletManager: bobLibSpiffy.walletManager,
        actorSystem: bobActorSystem,
        walletId: bobWalletId,
        walletName: 'Bob Wallet',
      );

      // Create Bob's channel service
      bobChannelService = PaymentChannelService(
        storage: bobLibSpiffy.walletStorage,
        secureStorage: bobLibSpiffy.secureStorage,
        cryptoService: DartSVCryptoService(),
      );

      print('✓ Bob system initialized with wallet: $bobWalletId');

      // Fund Alice's wallet so she can open channels
      await fundWallet(
        walletManager: aliceLibSpiffy.walletManager,
        actorSystem: aliceActorSystem,
        walletId: aliceWalletId,
        amount: BigInt.from(1000000), // 1 million satoshis
      );

      print('✓ Alice funded with 1,000,000 satoshis');
      print('--- Setup complete ---\n');
    });

    tearDown(() async {
      print('\n--- Cleanup ---');

      // Shutdown LibSpiffy systems
      await aliceLibSpiffy.shutdown();
      await bobLibSpiffy.shutdown();

      // Clean up test directories
      try {
        await aliceTestDir.delete(recursive: true);
        await bobTestDir.delete(recursive: true);
      } catch (e) {
        print('Warning: Could not delete test directories: $e');
      }

      print('✓ Cleanup complete\n');
    });

    test('Complete payment channel lifecycle', () async {
      print('\n=== STEP 1: Alice opens channel to Bob ===');

      // Get Bob's public key (in real scenario, exchanged via P2P)
      final bobPubKeyHex = await getWalletPublicKeyHex(
        libspiffy: bobLibSpiffy,
        walletId: bobWalletId,
      );
      print('  Bob public key: ${bobPubKeyHex.substring(0, 16)}...');

      final lockTimeUnix =
          DateTime.now().add(Duration(hours: 24)).millisecondsSinceEpoch ~/
              1000;

      final openResult = await aliceChannelService.openChannel(
        walletId: aliceWalletId,
        clientPeerId: 'alice_peer_id',
        serverPeerId: 'bob_peer_id',
        serverPubKeyHex: bobPubKeyHex,
        fundingAmountSats: BigInt.from(100000),
        lockTimeUnix: lockTimeUnix,
        context: 'test_channel',
      );

      expect(openResult.success, isTrue,
          reason: 'Channel opening should succeed');
      expect(openResult.channel, isNotNull);
      expect(openResult.channel!.state, equals(PaymentChannelState.opening));

      final channelId = openResult.channel!.channelId;
      print('✓ Channel opened: $channelId');
      print('  Funding TX: ${openResult.channel!.fundingTxId}');
      print('  Initial balance: ${openResult.channel!.clientBalanceSats} sats');

      print('\n=== STEP 2: Verify channel stored ===');

      final storedChannel =
          await aliceLibSpiffy.walletStorage.getPaymentChannel(channelId);
      expect(storedChannel, isNotNull);
      expect(storedChannel.channelId, equals(channelId));

      print('✓ Channel persisted in storage');

      print('\n=== STEP 3: Mark channel as open (simulate funding confirmed) ===');

      // In real scenario, funding tx would be broadcast and confirmed
      // For test, we manually update state
      await aliceLibSpiffy.walletStorage.updatePaymentChannelState(
        channelId,
        PaymentChannelState.open.name,
      );

      print('✓ Channel marked as open');

      print('\n=== STEP 4: Create payment update ===');

      final paymentResult = await aliceChannelService.createPayment(
        channelId: channelId,
        amountSats: BigInt.from(10000),
      );

      expect(paymentResult.success, isTrue,
          reason: 'Payment creation should succeed');
      expect(paymentResult.channel, isNotNull);
      expect(paymentResult.channel!.serverBalanceSats, equals(BigInt.from(10000)));
      expect(paymentResult.channel!.clientBalanceSats, equals(BigInt.from(90000)));
      expect(paymentResult.channel!.latestSequenceNumber, equals(1));

      print('✓ Payment created');
      print('  New balances: client=${paymentResult.channel!.clientBalanceSats}, '
          'server=${paymentResult.channel!.serverBalanceSats}');

      print('\n=== STEP 5: Create second payment ===');

      final payment2Result = await aliceChannelService.createPayment(
        channelId: channelId,
        amountSats: BigInt.from(5000),
      );

      expect(payment2Result.success, isTrue);
      expect(payment2Result.channel!.serverBalanceSats, equals(BigInt.from(15000)));
      expect(payment2Result.channel!.clientBalanceSats, equals(BigInt.from(85000)));
      expect(payment2Result.channel!.latestSequenceNumber, equals(2));

      print('✓ Second payment created');
      print('  Final balances: client=${payment2Result.channel!.clientBalanceSats}, '
          'server=${payment2Result.channel!.serverBalanceSats}');

      print('\n=== STEP 6: Close channel cooperatively ===');

      final closeResult =
          await aliceChannelService.closeChannelCooperative(channelId);

      expect(closeResult.success, isTrue);
      expect(closeResult.channel!.state, equals(PaymentChannelState.closing));

      print('✓ Channel closed cooperatively');

      print('\n=== Payment channel lifecycle completed successfully ===\n');
    });

    test('Extended BEEF with unconfirmed funding', () async {
      print('\n=== Testing extended BEEF for unconfirmed funding ===');

      // This test would verify that when funding tx is unconfirmed,
      // the payment update includes the full ancestor chain in BEEF

      // TODO: Implement full test with:
      // 1. Open channel (funding tx unconfirmed)
      // 2. Create payment update
      // 3. Verify BEEF contains ancestors
      // 4. Parse and validate BEEF structure

      print('✓ Extended BEEF test placeholder\n');
    }, skip: 'TODO: Implement full extended BEEF test');

    test('Channel state persistence across restart', () async {
      print('\n=== Testing channel persistence ===');

      // TODO: Implement test that:
      // 1. Opens channel
      // 2. Makes payment
      // 3. Shuts down and restarts system
      // 4. Verifies channel state is restored

      print('✓ Persistence test placeholder\n');
    }, skip: 'TODO: Implement persistence test');
  });
}

