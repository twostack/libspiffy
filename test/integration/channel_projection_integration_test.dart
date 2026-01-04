/// Channel Projection Integration Test
/// 
/// Tests that payment channel events properly update the ChannelProjection read model:
/// - Commands → Aggregate → Events → Projection → Isar
/// - Verifies PaymentChannelEntity is created and updated correctly

import 'dart:async';
import 'dart:io';
import 'package:test/test.dart';
import 'package:dactor/dactor.dart';
import 'package:isar/isar.dart';
import 'package:eventador/eventador.dart';
import 'package:libspiffy/libspiffy.dart';
import 'package:libspiffy/src/actors/libspiffy_actor_system.dart';
import 'package:libspiffy/src/actors/payment_channel_messages.dart';
import 'package:libspiffy/src/actors/payment_channel_manager_actor.dart';
import 'package:libspiffy/src/actors/wallet_messages.dart';
import 'package:libspiffy/src/storage/payment_channel_entity.dart';
import 'package:libspiffy/src/core/channel_events.dart';

void main() {
  group('Channel Projection Integration Tests', () {
    late LibSpiffyActorSystem libspiffy;
    late Isar isar;
    late LocalActorSystem actorSystem;
    late ActorRef channelManager;
    late Directory testDir;
    late String walletId;
    late String dbName;

    setUp(() async {
      await Isar.initializeIsarCore(download: true);
      testDir = await Directory.systemTemp.createTemp('channel_projection_test_');
      dbName = 'channel_test_${DateTime.now().microsecondsSinceEpoch}';
      isar = await Isar.open(
        [
          ...LibSpiffySchemas.walletSchemas,
          EventEnvelopeSchema,
          SnapshotEnvelopeSchema,
          ProjectionCheckpointSchema,
        ],
        directory: testDir.path,
        name: dbName,
      );
      
      // Create actor system
      actorSystem = LocalActorSystem(ActorSystemConfig());
      
      // Initialize LibSpiffy
      libspiffy = LibSpiffyActorSystem();
      await libspiffy.initialize(
        actorSystem: actorSystem,
        isar: isar,
        dataDirectory: testDir.path,
        enableP2P: false,
      );
      
      // Register channel events for deserialization
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
      
      // The ChannelProjection is already registered by LibSpiffy during initialization
      // We don't need to register it manually
      
      // Spawn PaymentChannelManagerActor manually
      channelManager = await actorSystem.spawn(
        'test-channel-manager',
        () => PaymentChannelManagerActor(
          walletManager: libspiffy.walletManager,
          eventStore: libspiffy.eventStore,
          cryptoService: libspiffy.cryptoService,
        ),
      );
      
      // Create a test wallet
      walletId = 'test-wallet-${DateTime.now().millisecondsSinceEpoch}';
      final cryptoService = DartSVCryptoService();
      final mnemonic = await cryptoService.generateMnemonic();
      
      final walletCompleter = Completer<WalletCreatedMessage>();
      final walletReceiver = await actorSystem.spawn(
        'wallet-receiver',
        () => _TestReceiverActor(walletCompleter),
      );
      
      libspiffy.walletManager.tell(
        CreateWalletMessage(walletId, 'Test Wallet', mnemonic: mnemonic),
        sender: walletReceiver,
      );
      
      final walletResponse = await walletCompleter.future.timeout(Duration(seconds: 5));
      expect(walletResponse.success, isTrue);
      
      print('✓ Test environment initialized');
      print('  - LibSpiffy actor system ready');
      print('  - Test wallet created: $walletId');
      print('  - Channel projection registered');
    });

    tearDown(() async {
      try {
        await libspiffy.shutdown();
      } catch (e) {
        print('Note: Error during teardown: $e');
      }
      
      try {
        await testDir.delete(recursive: true);
      } catch (e) {
        print('Warning: Could not delete test directory: $e');
      }
    });

    test('InitiateChannelMessage creates PaymentChannelEntity via projection', () async {
      print('\n=== Test: Channel Initiation Projection ===');
      
      final channelId = 'channel-test-1';
      
      // Send InitiateChannelMessage through channel manager
      final cmdCompleter = Completer<ChannelInitiatedResponse>();
      final cmdReceiver = await actorSystem.spawn(
        'cmd-receiver',
        () => _TestReceiverActor(cmdCompleter),
      );
      
      print('Sending InitiateChannelMessage...');
      channelManager.tell(
        InitiateChannelMessage(
          channelId: channelId,
          walletId: walletId,
          clientPeerId: 'client-peer-1',
          serverPeerId: 'server-peer-1',
          fundingAmountSats: BigInt.from(100000),
          lockTimeDurationSeconds: 3600,
        ),
        sender: cmdReceiver,
      );
      
      // Wait for command processing
      final response = await cmdCompleter.future.timeout(Duration(seconds: 10));
      expect(response.success, isTrue);
      print('  ✓ Channel initiated successfully');
      
      // Wait for projection to process events
      print('Waiting for projection to process events...');
      await Future.delayed(Duration(milliseconds: 1000));
      
      // Verify PaymentChannelEntity was created by projection
      print('Checking Isar database for PaymentChannelEntity...');
      
      // Debug: Check if any channels exist
      final allChannels = await isar.paymentChannelEntitys.where().findAll();
      print('  Total channels in database: ${allChannels.length}');
      if (allChannels.isNotEmpty) {
        for (final ch in allChannels) {
          print('    - ${ch.channelId}: ${ch.state}');
        }
      }
      
      final channelEntity = await isar.paymentChannelEntitys
          .where()
          .channelIdEqualTo(channelId)
          .findFirst();
      
      expect(channelEntity, isNotNull, reason: 'PaymentChannelEntity should be created by ChannelProjection');
      expect(channelEntity!.walletId, equals(walletId));
      expect(channelEntity.state, equals('opening'));
      expect(channelEntity.role, equals('client'));
      expect(channelEntity.fundingAmountSats, equals('100000'));
      
      print('✓ PaymentChannelEntity verified:');
      print('   Channel ID: ${channelEntity.channelId}');
      print('   State: ${channelEntity.state}');
      print('   Role: ${channelEntity.role}');
      print('   Funding: ${channelEntity.fundingAmountSats} sats');
    });

    test('Full channel lifecycle updates projection correctly', () async {
      print('\n=== Test: Full Channel Lifecycle Projection ===');
      
      final channelId = 'channel-lifecycle-${DateTime.now().millisecondsSinceEpoch}';
      
      // Step 1: Initiate channel (client)
      print('Step 1: Initiating channel...');
      final initiateCompleter = Completer<ChannelInitiatedResponse>();
      final initiateReceiver = await actorSystem.spawn(
        'initiate-receiver',
        () => _TestReceiverActor(initiateCompleter),
      );
      
      channelManager.tell(
        InitiateChannelMessage(
          channelId: channelId,
          walletId: walletId,
          clientPeerId: 'client-peer',
          serverPeerId: 'server-peer',
          fundingAmountSats: BigInt.from(200000),
          lockTimeDurationSeconds: 3600,
        ),
        sender: initiateReceiver,
      );
      
      final initiateResponse = await initiateCompleter.future.timeout(Duration(seconds: 10));
      expect(initiateResponse.success, isTrue);
      print('  ✓ Channel initiated');
      
      // Wait for projection
      await Future.delayed(Duration(milliseconds: 500));
      
      // Verify initial state
      var entity = await isar.paymentChannelEntitys
          .where()
          .channelIdEqualTo(channelId)
          .findFirst();
      
      expect(entity, isNotNull);
      expect(entity!.state, equals('opening'));
      expect(entity.role, equals('client'));
      print('  ✓ Projection state: opening');
      
      // Step 2: Accept channel (server)
      print('Step 2: Accepting channel...');
      final acceptCompleter = Completer<ChannelAcceptedResponse>();
      final acceptReceiver = await actorSystem.spawn(
        'accept-receiver',
        () => _TestReceiverActor(acceptCompleter),
      );
      
      channelManager.tell(
        AcceptChannelMessage(
          channelId: channelId,
          walletId: walletId,
          clientPeerId: 'client-peer',
          clientPubKeyHex: initiateResponse.clientPubKeyHex,
          clientAddressB58: initiateResponse.clientAddressB58,
          fundingAmountSats: BigInt.from(200000),
          lockTimeUnix: DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600,
        ),
        sender: acceptReceiver,
      );
      
      final acceptResponse = await acceptCompleter.future.timeout(Duration(seconds: 10));
      expect(acceptResponse.success, isTrue);
      print('  ✓ Channel accepted');
      
      // Wait for projection
      await Future.delayed(Duration(milliseconds: 500));
      
      // Verify accepted state
      entity = await isar.paymentChannelEntitys
          .where()
          .channelIdEqualTo(channelId)
          .findFirst();
      
      expect(entity, isNotNull);
      expect(entity!.state, equals('opening'));
      expect(entity.serverPubKeyHex, isNotEmpty);
      print('  ✓ Projection updated with server keys');
      
      print('✓ Channel lifecycle projection test completed');
    });
  });
}

/// Test actor that receives responses and completes futures
class _TestReceiverActor extends Actor {
  final Completer _completer;
  
  _TestReceiverActor(this._completer);
  
  @override
  Future<void> onMessage(dynamic message) async {
    if (!_completer.isCompleted) {
      _completer.complete(message);
    }
  }
}
