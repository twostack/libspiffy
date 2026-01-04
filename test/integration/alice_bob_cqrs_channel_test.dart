/// Alice-to-Bob CQRS Payment Channel Integration Test
///
/// This test demonstrates a complete CQRS-based payment channel lifecycle
/// between two independent LibSpiffy instances (Alice and Bob).
///
/// Key difference from alice_bob_payment_channel_test.dart:
/// - Uses PaymentChannelManagerActor (CQRS/Event Sourcing)
/// - NOT PaymentChannelService (old service-based approach)
///
/// Flow:
/// 1. Alice initiates channel (generates client keys)
/// 2. Bob accepts channel (generates server keys)
/// 3. Bob builds refund transaction
/// 4. Bob signs refund transaction (server signature)
/// 5. Alice records Bob's refund signature
/// 6. Alice opens channel (funding TX broadcast simulation)
/// 7. Both aggregates have complete, event-sourced channel state

import 'dart:async';
import 'dart:io';
import 'package:test/test.dart';
import 'package:dactor/dactor.dart';
import 'package:dactor_test/dactor_test.dart';
import 'package:isar/isar.dart';
import 'package:eventador/eventador.dart';
import 'package:dartsv/dartsv.dart';
import 'package:libspiffy/src/actors/payment_channel_manager_actor.dart';
import 'package:libspiffy/src/actors/payment_channel_messages.dart';
import 'package:libspiffy/src/actors/wallet_messages.dart';
import 'package:libspiffy/src/actors/wallet_manager_actor.dart';
import 'package:libspiffy/src/core/channel_events.dart';
import 'package:libspiffy/src/core/wallet_events.dart';
import 'package:libspiffy/src/services/dartsv_crypto_service.dart';
import 'package:libspiffy/src/storage/in_memory_secure_storage.dart';

void main() {
  group('Alice-to-Bob CQRS Payment Channel Integration', () {
    // Alice's system
    late Directory aliceTestDir;
    late Isar aliceIsar;
    late TestActorSystem aliceActorSystem;
    late EventStore aliceEventStore;
    late InMemorySecureStorage aliceSecureStorage;
    late ActorRef aliceWalletManager;
    late ActorRef aliceChannelManager;
    late String aliceWalletId;

    // Bob's system
    late Directory bobTestDir;
    late Isar bobIsar;
    late TestActorSystem bobActorSystem;
    late EventStore bobEventStore;
    late InMemorySecureStorage bobSecureStorage;
    late ActorRef bobWalletManager;
    late ActorRef bobChannelManager;
    late String bobWalletId;

    // Shared crypto service
    late DartSVCryptoService cryptoService;

    setUp(() async {
      print('\n--- Setting up Alice and Bob CQRS systems ---');

      // Initialize Isar core
      await Isar.initializeIsarCore(download: true);

      cryptoService = DartSVCryptoService();

      // Create temporary directories
      aliceTestDir = await Directory.systemTemp.createTemp('alice_cqrs_channel_');
      bobTestDir = await Directory.systemTemp.createTemp('bob_cqrs_channel_');

      print('Alice DB: ${aliceTestDir.path}');
      print('Bob DB: ${bobTestDir.path}');

      // ========== Initialize Alice's system ==========
      aliceIsar = await Isar.open(
        [EventEnvelopeSchema, SnapshotEnvelopeSchema],
        directory: aliceTestDir.path,
        name: 'alice_cqrs_${DateTime.now().microsecondsSinceEpoch}',
      );
      aliceEventStore = IsarEventStore(aliceIsar);
      aliceSecureStorage = InMemorySecureStorage();

      // Register events for Alice
      EventRegistry.register<WalletCreatedEvent>(
        'WalletCreatedEvent',
        (map) => WalletCreatedEvent.fromMap(map),
      );
      EventRegistry.register<AddressGeneratedEvent>(
        'AddressGeneratedEvent',
        (map) => AddressGeneratedEvent.fromMap(map),
      );
      EventRegistry.register<ChannelRequestedEvent>(
        'ChannelRequestedEvent',
        (map) => ChannelRequestedEvent.fromMap(map),
      );
      EventRegistry.register<ChannelAcceptedEvent>(
        'ChannelAcceptedEvent',
        (map) => ChannelAcceptedEvent.fromMap(map),
      );
      EventRegistry.register<RefundCountersignedEvent>(
        'RefundCountersignedEvent',
        (map) => RefundCountersignedEvent.fromMap(map),
      );
      EventRegistry.register<ChannelOpenedEvent>(
        'ChannelOpenedEvent',
        (map) => ChannelOpenedEvent.fromMap(map),
      );

      // Create Alice's actor system
      aliceActorSystem = TestActorSystem();

      // Spawn Alice's WalletManager
      aliceWalletManager = await aliceActorSystem.spawn(
        'alice-wallet-manager',
        () => WalletManagerActor(
          eventStore: aliceEventStore,
          secureStorage: aliceSecureStorage,
          cryptoService: cryptoService,
        ),
      );

      // Spawn Alice's ChannelManager
      aliceChannelManager = await aliceActorSystem.spawn(
        'alice-channel-manager',
        () => PaymentChannelManagerActor(
          walletManager: aliceWalletManager,
          eventStore: aliceEventStore,
          cryptoService: cryptoService,
          networkType: NetworkType.TEST,
        ),
      );

      // Create Alice's wallet
      const aliceMnemonic = 'abandon abandon abandon abandon abandon abandon '
          'abandon abandon abandon abandon abandon about';
      aliceWalletId = 'alice-cqrs-${DateTime.now().millisecondsSinceEpoch}';

      final aliceCreateProbe = await aliceActorSystem.createProbe();
      aliceWalletManager.tell(
        CreateWalletMessage(aliceWalletId, 'Alice CQRS Wallet', mnemonic: aliceMnemonic),
        sender: aliceCreateProbe.ref,
      );

      final aliceCreateResponse = await aliceCreateProbe.expectMsgType<WalletCreatedMessage>(
        timeout: Duration(seconds: 5),
      );

      if (!aliceCreateResponse.success) {
        throw Exception('Failed to create Alice wallet: ${aliceCreateResponse.error}');
      }

      print('✓ Alice system initialized with wallet: $aliceWalletId');

      // ========== Initialize Bob's system ==========
      bobIsar = await Isar.open(
        [EventEnvelopeSchema, SnapshotEnvelopeSchema],
        directory: bobTestDir.path,
        name: 'bob_cqrs_${DateTime.now().microsecondsSinceEpoch}',
      );
      bobEventStore = IsarEventStore(bobIsar);
      bobSecureStorage = InMemorySecureStorage();

      // Note: EventRegistry is global, so we don't need to re-register for Bob

      // Create Bob's actor system
      bobActorSystem = TestActorSystem();

      // Spawn Bob's WalletManager
      bobWalletManager = await bobActorSystem.spawn(
        'bob-wallet-manager',
        () => WalletManagerActor(
          eventStore: bobEventStore,
          secureStorage: bobSecureStorage,
          cryptoService: cryptoService,
        ),
      );

      // Spawn Bob's ChannelManager
      bobChannelManager = await bobActorSystem.spawn(
        'bob-channel-manager',
        () => PaymentChannelManagerActor(
          walletManager: bobWalletManager,
          eventStore: bobEventStore,
          cryptoService: cryptoService,
          networkType: NetworkType.TEST,
        ),
      );

      // Create Bob's wallet
      const bobMnemonic = 'zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo wrong';
      bobWalletId = 'bob-cqrs-${DateTime.now().millisecondsSinceEpoch}';

      final bobCreateProbe = await bobActorSystem.createProbe();
      bobWalletManager.tell(
        CreateWalletMessage(bobWalletId, 'Bob CQRS Wallet', mnemonic: bobMnemonic),
        sender: bobCreateProbe.ref,
      );

      final bobCreateResponse = await bobCreateProbe.expectMsgType<WalletCreatedMessage>(
        timeout: Duration(seconds: 5),
      );

      if (!bobCreateResponse.success) {
        throw Exception('Failed to create Bob wallet: ${bobCreateResponse.error}');
      }

      print('✓ Bob system initialized with wallet: $bobWalletId');
      print('--- Setup complete ---\n');
    });

    tearDown(() async {
      print('\n--- Cleanup ---');

      // Shutdown actor systems
      await aliceActorSystem.shutdown();
      await bobActorSystem.shutdown();

      // Close databases
      await aliceIsar.close();
      await bobIsar.close();

      // Clean up test directories
      try {
        await aliceTestDir.delete(recursive: true);
        await bobTestDir.delete(recursive: true);
      } catch (e) {
        print('Warning: Could not delete test directories: $e');
      }

      print('✓ Cleanup complete\n');
    });

    test('Complete CQRS channel opening with refund signature exchange', () async {
      print('\n=== STEP 1: Alice initiates channel ===');

      final channelId = 'test-channel-${DateTime.now().millisecondsSinceEpoch}';
      final fundingAmountSats = BigInt.from(100000);
      final lockTimeDurationSeconds = 86400; // 24 hours

      final aliceInitiateProbe = await aliceActorSystem.createProbe();
      aliceChannelManager.tell(
        InitiateChannelMessage(
          channelId: channelId,
          walletId: aliceWalletId,
          clientPeerId: 'alice_peer_id',
          serverPeerId: 'bob_peer_id',
          fundingAmountSats: fundingAmountSats,
          lockTimeDurationSeconds: lockTimeDurationSeconds,
        ),
        sender: aliceInitiateProbe.ref,
      );

      final aliceInitiateResponse = await aliceInitiateProbe.expectMsgType<ChannelInitiatedResponse>(
        timeout: Duration(seconds: 10),
      );

      expect(aliceInitiateResponse.success, isTrue,
          reason: aliceInitiateResponse.error ?? 'Alice channel initiation should succeed');
      expect(aliceInitiateResponse.clientPubKeyHex, isNotEmpty);
      expect(aliceInitiateResponse.clientAddressB58, isNotEmpty);

      final lockTimeUnix = aliceInitiateResponse.lockTimeUnix;

      print('✓ Alice initiated channel: $channelId');
      print('  Client pubkey: ${aliceInitiateResponse.clientPubKeyHex.substring(0, 16)}...');
      print('  Client address: ${aliceInitiateResponse.clientAddressB58}');
      print('  Lock time: $lockTimeUnix');

      // Verify event was persisted
      await Future.delayed(Duration(milliseconds: 500));
      final aliceEvents = await aliceEventStore.getEvents('PaymentChannel_$channelId');
      expect(aliceEvents.any((e) => e.runtimeType.toString() == 'ChannelRequestedEvent'), isTrue);
      print('  ✓ ChannelRequestedEvent persisted');

      print('\n=== STEP 2: Bob accepts channel (simulated P2P request received) ===');

      // In real scenario, Alice would send InitiateChannelMessage data to Bob via P2P
      final bobAcceptProbe = await bobActorSystem.createProbe();
      bobChannelManager.tell(
        AcceptChannelMessage(
          channelId: channelId,
          walletId: bobWalletId,
          clientPeerId: 'alice_peer_id',
          clientPubKeyHex: aliceInitiateResponse.clientPubKeyHex,
          clientAddressB58: aliceInitiateResponse.clientAddressB58,
          fundingAmountSats: fundingAmountSats,
          lockTimeUnix: lockTimeUnix,
        ),
        sender: bobAcceptProbe.ref,
      );

      final bobAcceptResponse = await bobAcceptProbe.expectMsgType<ChannelAcceptedResponse>(
        timeout: Duration(seconds: 10),
      );

      expect(bobAcceptResponse.success, isTrue,
          reason: bobAcceptResponse.error ?? 'Bob channel acceptance should succeed');
      expect(bobAcceptResponse.serverPubKeyHex, isNotEmpty);
      expect(bobAcceptResponse.serverAddressB58, isNotEmpty);

      print('✓ Bob accepted channel: $channelId');
      print('  Server pubkey: ${bobAcceptResponse.serverPubKeyHex.substring(0, 16)}...');
      print('  Server address: ${bobAcceptResponse.serverAddressB58}');

      // Verify event was persisted
      await Future.delayed(Duration(milliseconds: 500));
      final bobEvents = await bobEventStore.getEvents('PaymentChannel_$channelId');
      expect(bobEvents.any((e) => e.runtimeType.toString() == 'ChannelAcceptedEvent'), isTrue);
      print('  ✓ ChannelAcceptedEvent persisted');

      print('\n=== STEP 3: Bob builds refund transaction ===');

      // Mock funding transaction ID (64 hex chars)
      final mockFundingTxId = 'a' * 64;

      final bobRefundProbe = await bobActorSystem.createProbe();
      bobChannelManager.tell(
        BuildRefundTransactionMessage(
          channelId: channelId,
          walletId: bobWalletId,
          fundingTxId: mockFundingTxId,
          fundingOutputIndex: 0,
          fundingAmountSats: fundingAmountSats,
          clientPubKeyHex: aliceInitiateResponse.clientPubKeyHex,
          clientAddressB58: aliceInitiateResponse.clientAddressB58,
          serverPubKeyHex: bobAcceptResponse.serverPubKeyHex,
          serverAddressB58: bobAcceptResponse.serverAddressB58,
          lockTimeUnix: lockTimeUnix,
        ),
        sender: bobRefundProbe.ref,
      );

      final bobRefundResponse = await bobRefundProbe.expectMsgType<RefundTransactionBuiltResponse>(
        timeout: Duration(seconds: 10),
      );

      expect(bobRefundResponse.success, isTrue,
          reason: bobRefundResponse.error ?? 'Refund TX building should succeed');
      expect(bobRefundResponse.refundTxHex, isNotEmpty);

      print('✓ Bob built refund TX');
      print('  Refund TX hex: ${bobRefundResponse.refundTxHex.substring(0, 40)}...');

      print('\n=== STEP 4: Bob signs refund transaction (server signature) ===');

      final bobSignProbe = await bobActorSystem.createProbe();
      bobChannelManager.tell(
        SignRefundTransactionMessage(
          channelId: channelId,
          walletId: bobWalletId,
          refundTxHex: bobRefundResponse.refundTxHex,
          clientPubKeyHex: aliceInitiateResponse.clientPubKeyHex,
          serverPubKeyHex: bobAcceptResponse.serverPubKeyHex,
          serverAddressB58: bobAcceptResponse.serverAddressB58,
          derivationIndex: bobAcceptResponse.derivationIndex,
          fundingAmountSats: fundingAmountSats,
          lockTimeUnix: lockTimeUnix,
        ),
        sender: bobSignProbe.ref,
      );

      final bobSignResponse = await bobSignProbe.expectMsgType<RefundTransactionSignedResponse>(
        timeout: Duration(seconds: 10),
      );

      expect(bobSignResponse.success, isTrue,
          reason: bobSignResponse.error ?? 'Refund TX signing should succeed');
      expect(bobSignResponse.serverSignatureHex, isNotEmpty);

      print('✓ Bob signed refund TX');
      print('  Server signature: ${bobSignResponse.serverSignatureHex.substring(0, 40)}...');

      // Verify RefundCountersignedEvent was persisted for Bob
      await Future.delayed(Duration(milliseconds: 500));
      final bobEventsAfterSign = await bobEventStore.getEvents('PaymentChannel_$channelId');
      expect(bobEventsAfterSign.any((e) => e.runtimeType.toString() == 'RefundCountersignedEvent'), isTrue);
      print('  ✓ RefundCountersignedEvent persisted in Bob\'s aggregate');

      print('\n=== STEP 5: Alice records Bob\'s refund signature (simulated P2P delivery) ===');

      // In real scenario, Bob would send serverSignatureHex to Alice via P2P
      // Alice's P2P layer (OverNode) would then call LibSpiffy's API to record it

      final aliceRecordProbe = await aliceActorSystem.createProbe();
      aliceChannelManager.tell(
        RecordRefundSignatureMessage(
          channelId: channelId,
          serverSignatureHex: bobSignResponse.serverSignatureHex,
        ),
        sender: aliceRecordProbe.ref,
      );

      final aliceRecordResponse = await aliceRecordProbe.expectMsgType<RefundSignatureRecordedResponse>(
        timeout: Duration(seconds: 10),
      );

      expect(aliceRecordResponse.success, isTrue,
          reason: aliceRecordResponse.error ?? 'Recording refund signature should succeed');

      print('✓ Alice recorded Bob\'s refund signature');

      // Verify RefundCountersignedEvent was persisted for Alice
      await Future.delayed(Duration(milliseconds: 500));
      final aliceEventsAfterRefund = await aliceEventStore.getEvents('PaymentChannel_$channelId');
      expect(aliceEventsAfterRefund.any((e) => e.runtimeType.toString() == 'RefundCountersignedEvent'), isTrue);
      print('  ✓ RefundCountersignedEvent persisted in Alice\'s aggregate');

      print('\n=== STEP 6: Alice opens channel (funding TX broadcast simulation) ===');

      // Now that Alice has the refund signature, she can safely broadcast the funding TX
      // and open the channel

      final mockFundingTxHex = '01000000' + ('00' * 100); // Mock transaction hex

      final aliceOpenProbe = await aliceActorSystem.createProbe();
      aliceChannelManager.tell(
        OpenChannelMessage(
          channelId: channelId,
          fundingTxId: mockFundingTxId,
          fundingOutputIndex: 0,
          fundingTxHex: mockFundingTxHex,
        ),
        sender: aliceOpenProbe.ref,
      );

      final aliceOpenResponse = await aliceOpenProbe.expectMsgType<ChannelOpenedResponse>(
        timeout: Duration(seconds: 10),
      );

      expect(aliceOpenResponse.success, isTrue,
          reason: aliceOpenResponse.error ?? 'Channel opening should succeed now that refund is signed');

      print('✓ Alice opened channel: $channelId');
      print('  Funding TX ID: $mockFundingTxId');

      // Verify ChannelOpenedEvent was persisted
      await Future.delayed(Duration(milliseconds: 500));
      final aliceEventsAfterOpen = await aliceEventStore.getEvents('PaymentChannel_$channelId');
      expect(aliceEventsAfterOpen.any((e) => e.runtimeType.toString() == 'ChannelOpenedEvent'), isTrue);
      print('  ✓ ChannelOpenedEvent persisted');

      print('\n=== STEP 7: Verify complete event history ===');

      print('\nAlice\'s event history:');
      for (final event in aliceEventsAfterOpen) {
        print('  - ${event.runtimeType}');
      }
      expect(aliceEventsAfterOpen.length, equals(3),
          reason: 'Alice should have 3 events: Requested, RefundCountersigned, Opened');

      print('\nBob\'s event history:');
      for (final event in bobEventsAfterSign) {
        print('  - ${event.runtimeType}');
      }
      expect(bobEventsAfterSign.length, equals(2),
          reason: 'Bob should have 2 events: Accepted, RefundCountersigned');

      print('\n=== STEP 8: Verify system isolation ===');

      // Verify separate actor systems
      expect(aliceActorSystem, isNot(equals(bobActorSystem)));
      expect(aliceWalletManager, isNot(equals(bobWalletManager)));

      // Verify separate databases
      expect(aliceTestDir.path, isNot(equals(bobTestDir.path)));

      print('✓ Database isolation verified');
      print('✓ Actor system isolation verified');

      print('\n=== Complete CQRS channel opening flow successful ===\n');
    });

    test('Channel opening fails without refund signature (security test)', () async {
      print('\n=== Testing security constraint: no refund signature ===');

      final channelId = 'security-test-${DateTime.now().millisecondsSinceEpoch}';
      final fundingAmountSats = BigInt.from(50000);
      final lockTimeDurationSeconds = 86400;

      print('\nSTEP 1: Alice initiates channel');
      final aliceInitiateProbe = await aliceActorSystem.createProbe();
      aliceChannelManager.tell(
        InitiateChannelMessage(
          channelId: channelId,
          walletId: aliceWalletId,
          clientPeerId: 'alice_peer_id',
          serverPeerId: 'bob_peer_id',
          fundingAmountSats: fundingAmountSats,
          lockTimeDurationSeconds: lockTimeDurationSeconds,
        ),
        sender: aliceInitiateProbe.ref,
      );

      final aliceInitiateResponse = await aliceInitiateProbe.expectMsgType<ChannelInitiatedResponse>(
        timeout: Duration(seconds: 10),
      );

      expect(aliceInitiateResponse.success, isTrue);
      print('✓ Channel initiated');

      print('\nSTEP 2: Attempt to open without refund signature');
      final mockFundingTxId = 'b' * 64;
      final mockFundingTxHex = '01000000' + ('00' * 100);

      final aliceOpenProbe = await aliceActorSystem.createProbe();
      aliceChannelManager.tell(
        OpenChannelMessage(
          channelId: channelId,
          fundingTxId: mockFundingTxId,
          fundingOutputIndex: 0,
          fundingTxHex: mockFundingTxHex,
        ),
        sender: aliceOpenProbe.ref,
      );

      final aliceOpenResponse = await aliceOpenProbe.expectMsgType<ChannelOpenedResponse>(
        timeout: Duration(seconds: 10),
      );

      expect(aliceOpenResponse.success, isFalse,
          reason: 'Opening should fail without refund signature');
      expect(aliceOpenResponse.error, contains('Refund not signed'),
          reason: 'Error message should indicate missing refund signature');

      print('✓ Channel opening correctly rejected');
      print('  Error: ${aliceOpenResponse.error}');

      print('\n=== Security constraint verified ===\n');
    });
  });
}
