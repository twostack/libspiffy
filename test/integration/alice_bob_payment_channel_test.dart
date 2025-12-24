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
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:dactor/dactor.dart';
import 'package:isar/isar.dart';
import 'package:eventador/eventador.dart';
import 'package:convert/convert.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:libspiffy/libspiffy.dart';
import 'package:libspiffy/src/actors/libspiffy_actor_system.dart';
import 'package:libspiffy/src/storage/isar_wallet_storage.dart';
import 'package:libspiffy/src/services/payment_channel_service.dart';
import 'package:libspiffy/src/services/dartsv_crypto_service.dart';
import 'package:libspiffy/src/models/payment_channel.dart';
import 'package:libspiffy/src/utils/beef.dart';
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

      // Get Bob's public key
      final bobPubKeyHex = await getWalletPublicKeyHex(
        libspiffy: bobLibSpiffy,
        walletId: bobWalletId,
      );

      final lockTimeUnix =
          DateTime.now().add(Duration(hours: 24)).millisecondsSinceEpoch ~/
              1000;

      print('\n=== STEP 1: Open channel (funding will be unconfirmed) ===');

      final openResult = await aliceChannelService.openChannel(
        walletId: aliceWalletId,
        clientPeerId: 'alice_peer_id',
        serverPeerId: 'bob_peer_id',
        serverPubKeyHex: bobPubKeyHex,
        fundingAmountSats: BigInt.from(50000),
        lockTimeUnix: lockTimeUnix,
        context: 'beef_test_channel',
      );

      expect(openResult.success, isTrue, reason: 'Channel should open');
      final channel = openResult.channel!;
      print('✓ Channel opened: ${channel.channelId}');
      print('  Funding TX: ${channel.fundingTxId}');
      print('  Ancestors collected: ${channel.fundingAncestorTxids.length}');

      // Mark channel as open (without confirming funding tx)
      await aliceLibSpiffy.walletStorage.updatePaymentChannelState(
        channel.channelId,
        PaymentChannelState.open.name,
      );

      print('\n=== STEP 2: Create payment (funding still unconfirmed) ===');

      final paymentResult = await aliceChannelService.createPayment(
        channelId: channel.channelId,
        amountSats: BigInt.from(10000),
      );

      expect(paymentResult.success, isTrue, reason: 'Payment should succeed');
      expect(paymentResult.beefHex, isNotNull,
          reason: 'Should have extended BEEF for unconfirmed funding');

      print('✓ Payment created with extended BEEF');
      print('  BEEF hex length: ${paymentResult.beefHex!.length} chars');

      print('\n=== STEP 3: Parse and validate BEEF structure ===');

      // Parse the BEEF
      final beefBytes = Uint8List.fromList(hex.decode(paymentResult.beefHex!));
      final beef = BEEF.parse(beefBytes);

      print('  BEEF version: 0x${beef.version.toRadixString(16)}');
      print('  Number of BUMPs: ${beef.bumps.length}');
      print('  Number of transactions: ${beef.txs.length}');
      print('  hasMerkle flags: ${beef.hasMerkle}');
      print('  bumpIndex: ${beef.bumpIndex}');

      // Validate BEEF structure
      // Should have at least 3 transactions:
      // 1. Ancestor(s) with merkle proof
      // 2. Funding TX (unconfirmed, no proof)
      // 3. Payment TX (new, no proof)
      expect(beef.txs.length, greaterThanOrEqualTo(3),
          reason: 'BEEF should contain at least ancestor + funding + payment');

      // Should have at least 1 BUMP (for the confirmed ancestor)
      expect(beef.bumps.length, greaterThanOrEqualTo(1),
          reason: 'BEEF should have at least one merkle proof');

      // Verify hasMerkle flags
      expect(beef.hasMerkle.length, equals(beef.txs.length),
          reason: 'hasMerkle should have one flag per transaction');

      // First transaction(s) should have merkle proof, last two should not
      // (funding tx and payment tx are unconfirmed)
      expect(beef.hasMerkle.last, isFalse,
          reason: 'Payment TX should not have merkle proof');
      expect(beef.hasMerkle[beef.hasMerkle.length - 2], isFalse,
          reason: 'Funding TX should not have merkle proof');

      // At least one transaction should have a merkle proof
      expect(beef.hasMerkle.any((has) => has), isTrue,
          reason: 'At least one ancestor should have merkle proof');

      print('\n=== STEP 4: Verify transaction order in BEEF ===');

      // Parse each transaction to get txids
      final txids = <String>[];
      for (int i = 0; i < beef.txs.length; i++) {
        final tx = dartsv.Transaction.fromHex(hex.encode(beef.txs[i]));
        txids.add(tx.id);
        final hasProof = beef.hasMerkle[i] ? '✓ proof' : '✗ no proof';
        print('  TX $i: ${tx.id.substring(0, 16)}... ($hasProof)');
      }

      // Verify funding TX is in the BEEF
      expect(txids.contains(channel.fundingTxId), isTrue,
          reason: 'BEEF should contain the funding transaction');

      // Verify payment TX is last
      final paymentTxId = paymentResult.channel!.latestPaymentTxHex != null
          ? dartsv.Transaction.fromHex(paymentResult.channel!.latestPaymentTxHex!).id
          : null;
      if (paymentTxId != null) {
        expect(txids.last, equals(paymentTxId),
            reason: 'Payment TX should be last in BEEF');
      }

      print('\n=== STEP 5: Verify BUMP structure ===');

      for (int i = 0; i < beef.bumps.length; i++) {
        final bump = beef.bumps[i];
        print('  BUMP $i: blockHeight=${bump.blockHeight}, levels=${bump.path.length}');
        expect(bump.blockHeight, greaterThan(0),
            reason: 'BUMP should have valid block height');
        expect(bump.path.isNotEmpty, isTrue,
            reason: 'BUMP should have merkle path');
      }

      print('\n=== Extended BEEF validation completed successfully ===\n');
    });

    test('Channel state persistence across restart', () async {
      print('\n=== Testing channel persistence across restart ===');

      // Get Bob's public key
      final bobPubKeyHex = await getWalletPublicKeyHex(
        libspiffy: bobLibSpiffy,
        walletId: bobWalletId,
      );

      final lockTimeUnix =
          DateTime.now().add(Duration(hours: 24)).millisecondsSinceEpoch ~/
              1000;

      print('\n=== STEP 1: Open channel and make payment ===');

      final openResult = await aliceChannelService.openChannel(
        walletId: aliceWalletId,
        clientPeerId: 'alice_peer_id',
        serverPeerId: 'bob_peer_id',
        serverPubKeyHex: bobPubKeyHex,
        fundingAmountSats: BigInt.from(75000),
        lockTimeUnix: lockTimeUnix,
        context: 'persistence_test',
      );

      expect(openResult.success, isTrue);
      final channelId = openResult.channel!.channelId;
      final fundingTxId = openResult.channel!.fundingTxId;
      print('✓ Channel opened: $channelId');

      // Mark as open and make a payment
      await aliceLibSpiffy.walletStorage.updatePaymentChannelState(
        channelId,
        PaymentChannelState.open.name,
      );

      final paymentResult = await aliceChannelService.createPayment(
        channelId: channelId,
        amountSats: BigInt.from(25000),
      );

      expect(paymentResult.success, isTrue);
      final expectedClientBalance = paymentResult.channel!.clientBalanceSats;
      final expectedServerBalance = paymentResult.channel!.serverBalanceSats;
      final expectedSequence = paymentResult.channel!.latestSequenceNumber;
      print('✓ Payment made: client=$expectedClientBalance, server=$expectedServerBalance');

      print('\n=== STEP 2: Shutdown LibSpiffy (keep Isar) ===');

      // Shutdown LibSpiffy but keep Isar open
      await aliceLibSpiffy.shutdown();
      print('✓ LibSpiffy shutdown');

      // Close Isar to simulate full restart
      await aliceIsar.close();
      print('✓ Isar closed');

      print('\n=== STEP 3: Restart with same database ===');

      // Reopen Isar with same name and directory
      final newAliceIsar = await Isar.open(
        [
          ...LibSpiffySchemas.walletSchemas,
          EventEnvelopeSchema,
          SnapshotEnvelopeSchema,
        ],
        directory: aliceTestDir.path,
        name: aliceDbName,
      );
      print('✓ Isar reopened');

      // Create new actor system
      final newActorSystem = LocalActorSystem(ActorSystemConfig());

      // Initialize new LibSpiffy
      final newAliceLibSpiffy = LibSpiffyActorSystem();
      await newAliceLibSpiffy.initialize(
        actorSystem: newActorSystem,
        isar: newAliceIsar,
        dataDirectory: aliceTestDir.path,
        enableP2P: false,
      );
      print('✓ LibSpiffy restarted');

      print('\n=== STEP 4: Verify channel state restored ===');

      // Get channel from storage
      final restoredChannel = await newAliceLibSpiffy.walletStorage.getPaymentChannel(channelId);

      expect(restoredChannel, isNotNull, reason: 'Channel should be restored');
      print('✓ Channel found in storage');

      // Verify all fields
      expect(restoredChannel.channelId, equals(channelId),
          reason: 'Channel ID should match');
      expect(restoredChannel.fundingTxId, equals(fundingTxId),
          reason: 'Funding TX ID should match');
      expect(restoredChannel.clientBalanceSats, equals(expectedClientBalance),
          reason: 'Client balance should be restored');
      expect(restoredChannel.serverBalanceSats, equals(expectedServerBalance),
          reason: 'Server balance should be restored');
      expect(restoredChannel.latestSequenceNumber, equals(expectedSequence),
          reason: 'Sequence number should be restored');
      expect(restoredChannel.state, equals(PaymentChannelState.open),
          reason: 'Channel state should be open');
      expect(restoredChannel.context, equals('persistence_test'),
          reason: 'Context should be restored');

      print('  ✓ channelId: ${restoredChannel.channelId}');
      print('  ✓ fundingTxId: ${restoredChannel.fundingTxId}');
      print('  ✓ clientBalance: ${restoredChannel.clientBalanceSats}');
      print('  ✓ serverBalance: ${restoredChannel.serverBalanceSats}');
      print('  ✓ sequenceNumber: ${restoredChannel.latestSequenceNumber}');
      print('  ✓ state: ${restoredChannel.state}');
      print('  ✓ context: ${restoredChannel.context}');

      print('\n=== STEP 5: Create new payment with restored channel ===');

      // Create new channel service with restarted system
      final newChannelService = PaymentChannelService(
        storage: newAliceLibSpiffy.walletStorage,
        secureStorage: newAliceLibSpiffy.secureStorage,
        cryptoService: DartSVCryptoService(),
      );

      // Make another payment to prove channel is fully functional
      final payment2Result = await newChannelService.createPayment(
        channelId: channelId,
        amountSats: BigInt.from(5000),
      );

      expect(payment2Result.success, isTrue,
          reason: 'Payment should work after restart');
      expect(payment2Result.channel!.latestSequenceNumber, equals(expectedSequence + 1),
          reason: 'Sequence should increment');
      expect(payment2Result.channel!.serverBalanceSats,
          equals(expectedServerBalance + BigInt.from(5000)),
          reason: 'Server balance should increase');

      print('✓ Payment after restart successful');
      print('  New sequence: ${payment2Result.channel!.latestSequenceNumber}');
      print('  New balances: client=${payment2Result.channel!.clientBalanceSats}, '
          'server=${payment2Result.channel!.serverBalanceSats}');

      // Cleanup: update references so tearDown works
      aliceIsar = newAliceIsar;
      aliceLibSpiffy = newAliceLibSpiffy;
      aliceActorSystem = newActorSystem;

      print('\n=== Channel persistence test completed successfully ===\n');
    });
  });
}

