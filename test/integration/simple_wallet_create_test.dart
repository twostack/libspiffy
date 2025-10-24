/// Simple isolated test to verify wallet creation works
/// This test helps debug the Alice-Bob P2P test by isolating the wallet creation flow

import 'dart:async';
import 'dart:io';
import 'package:test/test.dart';
import 'package:dactor/dactor.dart';
import 'package:isar/isar.dart';
import 'package:eventador/eventador.dart';
import 'package:libspiffy/libspiffy.dart';
import 'package:libspiffy/src/actors/libspiffy_actor_system.dart';
import 'package:libspiffy/src/actors/wallet_messages.dart';
import 'package:libspiffy/src/storage/isar_wallet_storage.dart';

void main() {
  test('Simple wallet creation test', () async {
    print('\n=== Simple Wallet Creation Test ===');
    
    // Initialize Isar
    await Isar.initializeIsarCore(download: true);
    
    // Create test directory
    final testDir = await Directory.systemTemp.createTemp('simple_test_');
    print('Test DB: ${testDir.path}');
    
    // Open Isar with required schemas
    final isar = await Isar.open(
      [
        ...LibSpiffySchemas.walletSchemas,
        EventEnvelopeSchema,
        SnapshotEnvelopeSchema,
      ],
      directory: testDir.path,
      name: 'simple_test_db',
    );
    print('✓ Isar opened');
    
    // Create actor system
    final actorSystem = LocalActorSystem(ActorSystemConfig());
    print('✓ Actor system created');
    
    // Initialize LibSpiffy
    final libspiffy = LibSpiffyActorSystem();
    await libspiffy.initialize(
      actorSystem: actorSystem,
      isar: isar,
      dataDirectory: testDir.path,
      enableP2P: false
    );
    print('✓ LibSpiffy initialized');
    
    // Create a test receiver actor
    final completer = Completer<WalletCreatedMessage>();
    final receiver = await actorSystem.spawn(
      'test-receiver',
      () => _TestReceiverActor(completer),
    );
    print('✓ Test receiver spawned');
    
    // Send wallet creation message
    final walletId = 'test-wallet-${DateTime.now().millisecondsSinceEpoch}';
    print('Sending CreateWalletMessage for: $walletId');
    
    libspiffy.walletManager.tell(
      CreateWalletMessage(walletId, 'Test Wallet'),
      sender: receiver,
    );
    
    print('Waiting for response...');
    
    try {
      final response = await completer.future.timeout(
        Duration(seconds: 10),
        onTimeout: () {
          print('❌ TIMEOUT: No response received after 10 seconds');
          print('This means the aggregate is not sending back WalletCreatedResponse');
          throw TimeoutException('Wallet creation timeout');
        },
      );
      
      print('✓ Received response!');
      print('  Wallet ID: ${response.walletId}');
      print('  Root Address: ${response.rootAddress}');
      print('  Success: ${response.success}');
      
      if (response.error != null) {
        print('  Error: ${response.error}');
      }
      
      expect(response.success, isTrue, reason: 'Wallet creation should succeed');
      expect(response.walletId, equals(walletId));
      expect(response.rootAddress, isNotEmpty, reason: 'Should have a root address');
      
      print('\n✅ Test passed!');
    } catch (e, stackTrace) {
      print('\n❌ Test failed: $e');
      print('Stack trace: $stackTrace');
      rethrow;
    } finally {
      // Cleanup
      await actorSystem.shutdown();
      await isar.close();
      try {
        await testDir.delete(recursive: true);
      } catch (e) {
        print('Warning: Could not delete test directory: $e');
      }
    }
  }, timeout: Timeout(Duration(seconds: 15)));
}

/// Simple test receiver that prints all messages it receives
class _TestReceiverActor extends Actor {
  final Completer<WalletCreatedMessage> completer;
  
  _TestReceiverActor(this.completer);
  
  @override
  Future<void> onMessage(dynamic message) async {
    print('TestReceiver got message: ${message.runtimeType}');
    
    if (message is WalletCreatedMessage) {
      print('  → WalletCreatedMessage received!');
      if (!completer.isCompleted) {
        completer.complete(message);
      }
    } else if (message is WalletCreatedResponse) {
      print('  → WalletCreatedResponse received! (unexpected type)');
      // This shouldn't happen but let's check
    } else {
      print('  → Unexpected message type: $message');
    }
  }
}

