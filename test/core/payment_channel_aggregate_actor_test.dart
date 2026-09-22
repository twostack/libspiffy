/// Payment Channel Aggregate - Actor System Integration Tests
/// 
/// These tests validate the PaymentChannelAggregate working through the
/// DActor actor system, testing real-world actor messaging patterns.
/// 
/// Key Differences from Unit Tests:
/// - Commands sent via actor messaging (tell/ask) instead of direct method calls
/// - Uses real Isar-backed event store instead of in-memory mock
/// - Tests concurrent multi-actor scenarios
/// - Validates event sourcing recovery from persistent storage
/// 
/// Testing Pattern:
/// - Aggregates are spawned as actors in the actor system
/// - Commands are sent via `tell` (fire-and-forget, realistic pattern)
/// - Results are verified by querying the persistent event store
/// - This matches the production pattern used by WalletManagerActor

import 'dart:io';
import 'package:test/test.dart';
import 'package:isar/isar.dart';
import 'package:eventador/eventador.dart';
import 'package:dactor_test/dactor_test.dart';
import 'package:libspiffy/libspiffy.dart';
import 'package:libspiffy/src/core/channel_commands.dart';
import 'package:libspiffy/src/core/channel_events.dart';
import 'package:libspiffy/src/core/payment_channel_aggregate.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:libspiffy/src/actors/payment_channel_messages.dart';
import '../mocks/test_channel_timing.dart';

/// Test mnemonic for generating predictable keys
const testMnemonic = 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';

/// Helper to generate pre-computed keys (simulating WalletManager)
class PrecomputedKeys {
  final String publicKeyHex;
  final String addressB58;
  final int derivationIndex;
  
  PrecomputedKeys({
    required this.publicKeyHex,
    required this.addressB58,
    required this.derivationIndex,
  });
  
  /// Receive indexes handed out in order, one per [generate] call.
  ///
  /// This used m/0/(clock % 1000000), which failed about once in 256 calls:
  /// dartsv threw 'Too few elements' for keys with a leading zero byte
  /// (libspiffy-hvp). The sequence now starts with the three such indexes of
  /// [testMnemonic] below 1000 (so every run covers them) and then counts up
  /// from 1000, which keeps the keys distinct within a run.
  static const _shortKeyIndexes = [113, 349, 945];
  static var _generated = 0;

  static Future<PrecomputedKeys> generate(CryptoService cryptoService) async {
    final hdKey = await cryptoService.mnemonicToHDPrivateKey(testMnemonic);
    final n = _generated++;
    final derivationIndex =
        n < _shortKeyIndexes.length ? _shortKeyIndexes[n] : 1000 + n;
    final privateKey = await cryptoService.derivePrivateKey(hdKey, 0, derivationIndex);
    final publicKey = privateKey.publicKey;
    final address = publicKey.toAddress(dartsv.NetworkType.TEST);
    
    return PrecomputedKeys(
      publicKeyHex: publicKey.toHex(),
      addressB58: address.toBase58(),
      derivationIndex: derivationIndex,
    );
  }
}

void main() {
  group('PaymentChannelAggregate - Actor System Integration', () {
    late Isar isar;
    late EventStore eventStore;
    late Directory tempDir;
    late CryptoService cryptoService;
    late SecureStorage secureStorage;
    late TestActorSystem actorSystem;
    late TestProbe probe;

    setUpAll(() async {
      // Create temporary directory for test database
      tempDir = await Directory.systemTemp.createTemp('libspiffy_channel_test_');
    });

    setUp(() async {
      // Initialize Isar database for each test
      await Isar.initializeIsarCore(download: true);
      isar = await Isar.open(
        [EventEnvelopeSchema, SnapshotEnvelopeSchema],
        directory: tempDir.path,
        name: 'test_${DateTime.now().millisecondsSinceEpoch}',
      );
      eventStore = IsarEventStore(isar);

      // Initialize services
      cryptoService = DartSVCryptoService();
      secureStorage = InMemorySecureStorage();

      // Set up test wallet xpriv
      final hdKey = await cryptoService.mnemonicToHDPrivateKey(testMnemonic);
      await secureStorage.setXPriv('wallet-123', hdKey.toString());

      // Initialize test actor system
      actorSystem = TestActorSystem();
      probe = await actorSystem.createProbe();

      // Register channel event types for deserialization
      _registerChannelEvents();
    });

    tearDown(() async {
      await actorSystem.shutdown();
      await isar.close();
    });

    tearDownAll(() async {
      // Clean up temporary directory
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('should spawn channel aggregate actor and process commands', () async {
      // Spawn the aggregate as an actor
      final aggregateRef = await actorSystem.spawn(
        'channel-actor-test',
        () => PaymentChannelAggregate(
          aggregateId: 'channel-actor-test',
          eventStore: eventStore,
          cryptoService: cryptoService,
          networkType: dartsv.NetworkType.TEST,
        ),
      );

      // Pre-compute keys (simulating what WalletManager would do)
      final clientKeys = await PrecomputedKeys.generate(cryptoService);

      // Send a request command from probe with pre-computed keys
      final requestCmd = RequestChannelCommand(timing: testChannelTiming, 
        channelId: 'channel-actor-test',
        walletId: 'wallet-123',
        clientPeerId: 'peer-client',
        serverPeerId: 'peer-server',
        clientPubKeyHex: clientKeys.publicKeyHex,
        clientAddressB58: clientKeys.addressB58,
        derivationIndex: clientKeys.derivationIndex,
        fundingAmountSats: BigInt.from(1000),
        lockTimeDurationSeconds: 7200, // Above the one-hour minimum: the acceptance comes later (ywbk).
      );

      aggregateRef.tell(requestCmd, sender: probe.ref);

      // Wait for response using probe - no arbitrary delays!
      // Note: Dactor automatically extracts payload from LocalMessage before passing to onMessage
      final response = (await probe.expectMsgType<ChannelCommandResult>(
        timeout: Duration(seconds: 3),
      ))
          .events;
      
      // Verify response contains expected event
      expect(response.length, 1);
      expect(response[0], isA<ChannelRequestedEvent>());

      final event = response[0] as ChannelRequestedEvent;
      expect(event.channelId, 'channel-actor-test');
      expect(event.fundingAmountSats, BigInt.from(1000));

      // Verify events were also persisted
      final persistedEvents = await eventStore.getEvents('PaymentChannel_channel-actor-test');
      expect(persistedEvents.length, 1);
      expect(persistedEvents[0], isA<ChannelRequestedEvent>());
    });

    test('should handle sequential commands through actor system', () async {
      final aggregateRef = await actorSystem.spawn(
        'channel-seq-test',
        () => PaymentChannelAggregate(
          aggregateId: 'channel-seq-test',
          eventStore: eventStore,
          cryptoService: cryptoService,
          networkType: dartsv.NetworkType.TEST,
        ),
      );

      // 1. Request channel
      final clientKeys = await PrecomputedKeys.generate(cryptoService);
      final requestCmd = RequestChannelCommand(timing: testChannelTiming, 
        channelId: 'channel-seq-test',
        walletId: 'wallet-123',
        clientPeerId: 'peer-client',
        serverPeerId: 'peer-server',
        clientPubKeyHex: clientKeys.publicKeyHex,
        clientAddressB58: clientKeys.addressB58,
        derivationIndex: clientKeys.derivationIndex,
        fundingAmountSats: BigInt.from(1000),
        lockTimeDurationSeconds: 7200, // Above the one-hour minimum: the acceptance comes later (ywbk).
      );

      aggregateRef.tell(requestCmd, sender: probe.ref);
      var response =
          (await probe.expectMsgType<ChannelCommandResult>(timeout: Duration(seconds: 3))).events;
      
      expect(response.length, 1);
      expect(response[0], isA<ChannelRequestedEvent>());
      final requestEvent = response[0] as ChannelRequestedEvent;

      // 2. Accept channel
      final serverKeys = await PrecomputedKeys.generate(cryptoService);
      final acceptCmd = AcceptChannelCommand(timing: testChannelTiming, 
        channelId: 'channel-seq-test',
        walletId: 'wallet-123',
        clientPeerId: 'peer-client',
        clientPubKeyHex: requestEvent.clientPubKeyHex,
        clientAddressB58: requestEvent.clientAddressB58,
        serverPubKeyHex: serverKeys.publicKeyHex,
        serverAddressB58: serverKeys.addressB58,
        derivationIndex: serverKeys.derivationIndex,
        fundingAmountSats: BigInt.from(1000),
        lockTimeUnix: requestEvent.lockTimeUnix,
      );

      aggregateRef.tell(acceptCmd, sender: probe.ref);
      response =
          (await probe.expectMsgType<ChannelCommandResult>(timeout: Duration(seconds: 3))).events;
      
      expect(response.length, 1);
      expect(response[0], isA<ChannelAcceptedEvent>());

      // Verify both events were persisted
      final events = await eventStore.getEvents('PaymentChannel_channel-seq-test');
      expect(events.length, 2); // Request + Accept

      // 3. Reject channel (should fail - already accepted)
      // Invalid command won't send a response back
      final rejectCmd = RejectChannelCommand(
        channelId: 'channel-seq-test',
        reason: 'Testing invalid transition',
      );

      aggregateRef.tell(rejectCmd, sender: probe.ref);
      
      // No response expected for invalid command (it will throw internally)
      // Give it a moment to process
      await Future.delayed(Duration(milliseconds: 100));

      // Verify no additional events were persisted (still just 2)
      final finalEvents = await eventStore.getEvents('PaymentChannel_channel-seq-test');
      expect(finalEvents.length, 2); // Still Request + Accept
    });

    test('should handle concurrent commands to different channels', () async {
      // Create separate probes for each channel
      final probe1 = await actorSystem.createProbe();
      final probe2 = await actorSystem.createProbe();
      
      // Spawn multiple channel aggregates
      final channel1Ref = await actorSystem.spawn(
        'channel-1',
        () => PaymentChannelAggregate(
          aggregateId: 'channel-1',
          eventStore: eventStore,
          cryptoService: cryptoService,
          networkType: dartsv.NetworkType.TEST,
        ),
      );

      final channel2Ref = await actorSystem.spawn(
        'channel-2',
        () => PaymentChannelAggregate(
          aggregateId: 'channel-2',
          eventStore: eventStore,
          cryptoService: cryptoService,
          networkType: dartsv.NetworkType.TEST,
        ),
      );

      // Send commands to both channels concurrently
      final keys1 = await PrecomputedKeys.generate(cryptoService);
      final cmd1 = RequestChannelCommand(timing: testChannelTiming, 
        channelId: 'channel-1',
        walletId: 'wallet-123',
        clientPeerId: 'peer-client-1',
        serverPeerId: 'peer-server-1',
        clientPubKeyHex: keys1.publicKeyHex,
        clientAddressB58: keys1.addressB58,
        derivationIndex: keys1.derivationIndex,
        fundingAmountSats: BigInt.from(1000),
        lockTimeDurationSeconds: 7200, // Above the one-hour minimum: the acceptance comes later (ywbk).
      );

      final keys2 = await PrecomputedKeys.generate(cryptoService);
      final cmd2 = RequestChannelCommand(timing: testChannelTiming, 
        channelId: 'channel-2',
        walletId: 'wallet-123',
        clientPeerId: 'peer-client-2',
        serverPeerId: 'peer-server-2',
        clientPubKeyHex: keys2.publicKeyHex,
        clientAddressB58: keys2.addressB58,
        derivationIndex: keys2.derivationIndex,
        fundingAmountSats: BigInt.from(2000),
        lockTimeDurationSeconds: 7200,
      );

      // Send commands concurrently with separate probes
      channel1Ref.tell(cmd1, sender: probe1.ref);
      channel2Ref.tell(cmd2, sender: probe2.ref);

      // Wait for both responses concurrently - no arbitrary delays!
      final results = await Future.wait([
        probe1.expectMsgType<ChannelCommandResult>(timeout: Duration(seconds: 3)),
        probe2.expectMsgType<ChannelCommandResult>(timeout: Duration(seconds: 3)),
      ]);

      // Verify both channels processed commands correctly
      expect((results[0].events[0] as ChannelRequestedEvent).fundingAmountSats, BigInt.from(1000));
      expect((results[1].events[0] as ChannelRequestedEvent).fundingAmountSats, BigInt.from(2000));

      // Verify events were persisted separately
      final channel1Events = await eventStore.getEvents('PaymentChannel_channel-1');
      final channel2Events = await eventStore.getEvents('PaymentChannel_channel-2');

      expect(channel1Events.length, 1);
      expect(channel2Events.length, 1);
    });

    test('should recover aggregate state from event store', () async {
      // First, create and persist some events
      final probe1 = await actorSystem.createProbe();
      
      final aggregateRef1 = await actorSystem.spawn(
        'channel-recovery-test-1',
        () => PaymentChannelAggregate(
          aggregateId: 'channel-recovery-test',
          eventStore: eventStore,
          cryptoService: cryptoService,
          networkType: dartsv.NetworkType.TEST,
        ),
      );

      // Create a channel and make some state changes
      final clientKeys = await PrecomputedKeys.generate(cryptoService);
      final requestCmd = RequestChannelCommand(timing: testChannelTiming, 
        channelId: 'channel-recovery-test',
        walletId: 'wallet-123',
        clientPeerId: 'peer-client',
        serverPeerId: 'peer-server',
        clientPubKeyHex: clientKeys.publicKeyHex,
        clientAddressB58: clientKeys.addressB58,
        derivationIndex: clientKeys.derivationIndex,
        fundingAmountSats: BigInt.from(1000),
        lockTimeDurationSeconds: 7200, // Above the one-hour minimum: the acceptance comes later (ywbk).
      );

      aggregateRef1.tell(requestCmd, sender: probe1.ref);
      var response =
          (await probe1.expectMsgType<ChannelCommandResult>(timeout: Duration(seconds: 3))).events;
      final requestEvent = response[0] as ChannelRequestedEvent;

      final serverKeys = await PrecomputedKeys.generate(cryptoService);
      final acceptCmd = AcceptChannelCommand(timing: testChannelTiming, 
        channelId: 'channel-recovery-test',
        walletId: 'wallet-123',
        clientPeerId: 'peer-client',
        clientPubKeyHex: requestEvent.clientPubKeyHex,
        clientAddressB58: requestEvent.clientAddressB58,
        serverPubKeyHex: serverKeys.publicKeyHex,
        serverAddressB58: serverKeys.addressB58,
        derivationIndex: serverKeys.derivationIndex,
        fundingAmountSats: BigInt.from(1000),
        lockTimeUnix: requestEvent.lockTimeUnix,
      );

      aggregateRef1.tell(acceptCmd, sender: probe1.ref);
      await probe1.expectMsgType<ChannelCommandResult>(timeout: Duration(seconds: 3));

      // Stop the first actor
      actorSystem.stop(aggregateRef1);

      // Give time for actor to stop
      await Future.delayed(Duration(milliseconds: 100));

      // Spawn a new aggregate with the same ID - it should recover state
      await actorSystem.spawn(
        'channel-recovery-test-2',
        () => PaymentChannelAggregate(
          aggregateId: 'channel-recovery-test',
          eventStore: eventStore,
          cryptoService: cryptoService,
          networkType: dartsv.NetworkType.TEST,
        ),
      );

      // Give some time for recovery to complete
      await Future.delayed(Duration(milliseconds: 200));

      // Verify events persisted and can be recovered
      final recoveredEvents = await eventStore.getEvents('PaymentChannel_channel-recovery-test');
      expect(recoveredEvents.length, 2); // Request + Accept
      expect(recoveredEvents[0], isA<ChannelRequestedEvent>());
      expect(recoveredEvents[1], isA<ChannelAcceptedEvent>());
    });

    test('should handle command validation through actor system', () async {
      final validationProbe = await actorSystem.createProbe();
      
      final aggregateRef = await actorSystem.spawn(
        'channel-validation-test',
        () => PaymentChannelAggregate(
          aggregateId: 'channel-validation-test',
          eventStore: eventStore,
          cryptoService: cryptoService,
          networkType: dartsv.NetworkType.TEST,
        ),
      );

      // Try to request a channel with zero amount (should fail)
      final keys = await PrecomputedKeys.generate(cryptoService);
      final invalidCmd = RequestChannelCommand(timing: testChannelTiming, 
        channelId: 'channel-validation-test',
        walletId: 'wallet-123',
        clientPeerId: 'peer-client',
        serverPeerId: 'peer-server',
        clientPubKeyHex: keys.publicKeyHex,
        clientAddressB58: keys.addressB58,
        derivationIndex: keys.derivationIndex,
        fundingAmountSats: BigInt.zero, // Invalid!
        lockTimeDurationSeconds: 7200, // Above the one-hour minimum: the acceptance comes later (ywbk).
      );

      // Send invalid command - actor will handle error internally, no response
      aggregateRef.tell(invalidCmd, sender: validationProbe.ref);
      
      // Give it a moment - invalid commands don't send responses
      await Future.delayed(Duration(milliseconds: 300));

      // Verify no events were persisted (command validation failed)
      final events = await eventStore.getEvents('PaymentChannel_channel-validation-test');
      expect(events.length, 0);
    });

    test('ExpireChannelCommand emits ChannelExpiredEvent after lockTime elapses',
        () async {
      final aggregateRef = await actorSystem.spawn(
        'channel-expire-test',
        () => PaymentChannelAggregate(
          aggregateId: 'channel-expire-test',
          eventStore: eventStore,
          cryptoService: cryptoService,
          networkType: dartsv.NetworkType.TEST,
        ),
      );

      // Open with a 1-second lockTime so the aggregate is past its lockTime
      // shortly after we issue the expire command.
      final clientKeys = await PrecomputedKeys.generate(cryptoService);
      final requestCmd = RequestChannelCommand(
        // A one-second channel needs a one-second minimum (bead
        // libspiffy-ywbk).
        timing: ChannelTiming(
            settlementMargin: const Duration(milliseconds: 500), minimumLifetime: const Duration(seconds: 1)),
        channelId: 'channel-expire-test',
        walletId: 'wallet-123',
        clientPeerId: 'peer-client',
        serverPeerId: 'peer-server',
        clientPubKeyHex: clientKeys.publicKeyHex,
        clientAddressB58: clientKeys.addressB58,
        derivationIndex: clientKeys.derivationIndex,
        fundingAmountSats: BigInt.from(1000),
        lockTimeDurationSeconds: 1,
      );
      aggregateRef.tell(requestCmd, sender: probe.ref);
      await probe.expectMsgType<ChannelCommandResult>(timeout: Duration(seconds: 3));

      // Wait past lockTime.
      await Future.delayed(Duration(milliseconds: 1100));

      final expireCmd = ExpireChannelCommand(
        channelId: 'channel-expire-test',
        observedBy: 'client',
        settlementOrRefundTxId: 'refund-tx-abc',
      );
      aggregateRef.tell(expireCmd, sender: probe.ref);

      final response =
          (await probe.expectMsgType<ChannelCommandResult>(timeout: Duration(seconds: 3)))
              .events;
      expect(response.length, 1);
      expect(response[0], isA<ChannelExpiredEvent>());

      final event = response[0] as ChannelExpiredEvent;
      expect(event.channelId, 'channel-expire-test');
      expect(event.observedBy, 'client');
      expect(event.settlementOrRefundTxId, 'refund-tx-abc');

      // Re-issuing should fail (already terminated). No response is sent on
      // failure, so just verify only the original ChannelExpiredEvent was
      // persisted.
      aggregateRef.tell(expireCmd, sender: probe.ref);
      await Future.delayed(Duration(milliseconds: 200));

      final events =
          await eventStore.getEvents('PaymentChannel_channel-expire-test');
      final expiredEvents =
          events.whereType<ChannelExpiredEvent>().toList();
      expect(expiredEvents.length, 1,
          reason: 'ExpireChannelCommand must be idempotent once terminated');
    });
  });
}

/// Register channel event types for deserialization
void _registerChannelEvents() {
  LibSpiffyActorSystem.registerEventTypes();
}

