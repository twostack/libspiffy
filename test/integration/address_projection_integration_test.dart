/// Address Projection Integration Test
/// 
/// Tests that the address CQRS flow properly persists addresses to Isar via projection:
/// - RegisterDiscoveredAddressCommand → AddressDiscoveredEvent → WalletProjection → AddressEntity
/// - Address generation creates AddressEntity records
/// - Address metadata is tracked correctly
/// - Transaction-address junctions are created
/// - O(1) address lookups work through projection

import 'dart:async';
import 'dart:io';
import 'package:test/test.dart';
import 'package:dactor/dactor.dart';
import 'package:isar/isar.dart';
import 'package:eventador/eventador.dart';
import 'package:libspiffy/libspiffy.dart';
import 'package:libspiffy/src/actors/libspiffy_actor_system.dart';
import 'package:libspiffy/src/actors/wallet_messages.dart';
import 'isar_test_helper.dart';

void main() {
  group('Address Projection Integration Tests', () {
    late LibSpiffyActorSystem libspiffy;
    late Isar isar;
    late LocalActorSystem actorSystem;
    late Directory testDir;
    late String walletId;
    late String dbName; // Store DB name for restart test

    setUpAll(() async {
      await ensureIsarInitialized();
    });

    setUp(() async {
      // Create test directory
      testDir = await Directory.systemTemp.createTemp('address_projection_test_');

      // Open Isar with required schemas (unique name per test run)
      dbName = 'address_test_${DateTime.now().microsecondsSinceEpoch}';
      isar = await Isar.open(
        [
          ...LibSpiffySchemas.walletSchemas,
          EventEnvelopeSchema,
          SnapshotEnvelopeSchema,
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
      
      // Generate mnemonic for test wallet
      final cryptoService = DartSVCryptoService();
      final mnemonic = await cryptoService.generateMnemonic();
      
      // Create a wallet first
      walletId = 'test-wallet-${DateTime.now().millisecondsSinceEpoch}';
      final walletCompleter = Completer<WalletCreatedMessage>();
      final walletReceiver = await actorSystem.spawn(
        'wallet-receiver',
        () => _TestReceiverActor(walletCompleter),
      );
      
      libspiffy.walletManager.tell(
        CreateWalletMessage(walletId, 'Test Wallet for Addresses', mnemonic: mnemonic),
        sender: walletReceiver,
      );
      
      final walletResponse = await walletCompleter.future.timeout(Duration(seconds: 5));
      expect(walletResponse.success, isTrue);
      
      print('✓ Test wallet created: $walletId');
    });

    tearDown(() async {
      try {
        await libspiffy.shutdown();
      } catch (e) {
        print('Note: LibSpiffy already shut down or error during shutdown: $e');
      }
      
      try {
        await testDir.delete(recursive: true);
      } catch (e) {
        print('Warning: Could not delete test directory: $e');
      }
    });

    test('RegisterDiscoveredAddressCommand creates AddressEntity via projection', () async {
      print('\n=== Test: Discovered Address Projection ===');
      
      // Send RegisterDiscoveredAddressCommand through wallet manager
      final cmdCompleter = Completer();
      final cmdReceiver = await actorSystem.spawn(
        'cmd-receiver',
        () => _TestReceiverActor(cmdCompleter),
      );
      
      final registerCmd = RegisterDiscoveredAddressCommand(
        walletId: walletId,
        address: '1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa',
        derivationIndex: 0,
        isChange: false,
        transactionCount: 5,
      );
      
      print('Sending RegisterDiscoveredAddressCommand...');
      libspiffy.walletManager.tell(
        WalletCommandMessage(walletId, registerCmd),
        sender: cmdReceiver,
      );
      
      // Wait for command processing and projection update
      await Future.delayed(Duration(milliseconds: 500));
      
      // Verify AddressEntity was created by projection
      print('Checking Isar database for AddressEntity...');
      final addressEntity = await isar.addressEntitys
          .filter()
          .walletIdEqualTo(walletId)
          .and()
          .addressEqualTo('1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa')
          .findFirst();
      
      if (addressEntity == null) {
        print('❌ AddressEntity NOT found in database');
        print('   Checking all addresses in DB:');
        final allAddresses = await isar.addressEntitys
            .filter()
            .walletIdEqualTo(walletId)
            .findAll();
        print('   Total addresses for wallet: ${allAddresses.length}');
        for (final addr in allAddresses) {
          print('   - ${addr.address}: ${addr.scriptType}');
        }
      } else {
        print('✓ AddressEntity found in database');
        print('  Address: ${addressEntity.address}');
        print('  Script Type: ${addressEntity.scriptType}');
        print('  Derivation Index: ${addressEntity.derivationIndex}');
        print('  Is Change: ${addressEntity.isChange}');
      }
      
      expect(addressEntity, isNotNull, 
          reason: 'AddressEntity should be created by WalletProjection');
      expect(addressEntity!.address, equals('1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa'));
      expect(addressEntity.scriptType, equals('p2pkh'));
      expect(addressEntity.derivationIndex, equals(0));
      expect(addressEntity.isChange, isFalse);
      expect(addressEntity.purpose, isIn(['receive', 'change', 'Imported (receive #0)']));
    });

    test('Multiple discovered addresses are all persisted via projection', () async {
      print('\n=== Test: Multiple Discovered Addresses ===');
      
      final addresses = [
        ('1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2', 1, false),
        ('1HLoD9E4SDFFPDiYfNYnkBLQ85Y51J3Zb1', 2, false),
        ('1JfbZRwdDHKZmuiZgYArJZhcuYzU5m9f5z', 3, true), // change
      ];
      
      final cmdReceiver = await actorSystem.spawn(
        'multi-cmd-receiver',
        () => _TestReceiverActor(Completer()),
      );
      
      // Send multiple RegisterDiscoveredAddressCommand
      for (final (address, index, isChange) in addresses) {
        final registerCmd = RegisterDiscoveredAddressCommand(
          walletId: walletId,
          address: address,
          derivationIndex: index,
          isChange: isChange,
          transactionCount: 1,
        );
        
        libspiffy.walletManager.tell(
          WalletCommandMessage(walletId, registerCmd),
          sender: cmdReceiver,
        );
        
        print('✓ Sent RegisterDiscoveredAddressCommand for $address');
      }
      
      // Wait for all projections to update
      await Future.delayed(Duration(milliseconds: 800));
      
      // Verify all addresses in database
      print('Verifying addresses in database...');
      for (final (address, index, isChange) in addresses) {
        final entity = await isar.addressEntitys
            .filter()
            .walletIdEqualTo(walletId)
            .and()
            .addressEqualTo(address)
            .findFirst();
        
        expect(entity, isNotNull, reason: 'Address $address should be in database');
        expect(entity!.derivationIndex, equals(index));
        expect(entity.isChange, equals(isChange));
        print('✓ Address $address verified: index=$index, isChange=$isChange');
      }
      
      // Verify total count
      final count = await isar.addressEntitys
          .filter()
          .walletIdEqualTo(walletId)
          .count();
      
      expect(count, greaterThanOrEqualTo(3), 
          reason: 'Should have at least 3 addresses for wallet');
      print('✓ Total addresses for wallet: $count');
    });

    test('GenerateAddressCommand creates AddressEntity via projection', () async {
      print('\n=== Test: Generated Address Projection ===');
      
      // Send GenerateAddressCommand through wallet manager
      final completer = Completer<AddressGeneratedResponse>();
      final receiver = await actorSystem.spawn(
        'gen-receiver',
        () => _TestReceiverActor(completer),
      );
      
      final genCmd = GenerateAddressCommand(
        walletId: walletId,
        label: 'Test Generated Address',
        purpose: 'receive',
      );
      
      print('Sending GenerateAddressCommand...');
      libspiffy.walletManager.tell(
        WalletCommandMessage(walletId, genCmd),
        sender: receiver,
      );
      
      final response = await completer.future.timeout(Duration(seconds: 5));
      expect(response.success, isTrue);
      final generatedAddress = response.address;
      
      print('✓ Address generated: $generatedAddress');
      
      // Wait for projection
      await Future.delayed(Duration(milliseconds: 500));
      
      // Verify AddressEntity created by projection
      final addressEntity = await isar.addressEntitys
          .filter()
          .walletIdEqualTo(walletId)
          .and()
          .addressEqualTo(generatedAddress)
          .findFirst();
      
      expect(addressEntity, isNotNull, 
          reason: 'Generated address should be in database via projection');
      expect(addressEntity!.address, equals(generatedAddress));
      expect(addressEntity.scriptType, equals('p2pkh'));
      expect(addressEntity.label, equals('Test Generated Address'));
      expect(addressEntity.purpose, equals('receive'));
      print('✓ Generated address found in database with correct metadata');
    });

    test('Address lookup via storage reflects projection updates', () async {
      print('\n=== Test: Address Lookup via Storage ===');
      
      // Register address via command
      final cmdReceiver = await actorSystem.spawn(
        'lookup-cmd-receiver',
        () => _TestReceiverActor(Completer()),
      );
      
      final testAddress = '12cbQLTFMXRnSzktFkuoG3eHoMeFtpTu3S';
      final registerCmd = RegisterDiscoveredAddressCommand(
        walletId: walletId,
        address: testAddress,
        derivationIndex: 10,
        isChange: false,
        transactionCount: 3,
      );
      
      libspiffy.walletManager.tell(
        WalletCommandMessage(walletId, registerCmd),
        sender: cmdReceiver,
      );
      
      // Wait for projection
      await Future.delayed(Duration(milliseconds: 500));
      
      // Query via walletStorage (O(1) lookup)
      print('Testing O(1) address lookup via walletStorage...');
      final stopwatch = Stopwatch()..start();
      final exists = await libspiffy.walletStorage.isWalletAddress(walletId, testAddress);
      stopwatch.stop();
      
      expect(exists, isTrue, reason: 'Address should be found via O(1) lookup');
      print('✓ O(1 lookup found address in ${stopwatch.elapsedMicroseconds}μs');
      
      // Get metadata
      final metadata = await libspiffy.walletStorage.getAddressMetadata(walletId, testAddress);
      expect(metadata, isNotNull);
      expect(metadata!.address, equals(testAddress));
      expect(metadata.derivationIndex, equals(10));
      print('✓ Address metadata retrieved correctly');
      print('  Script Type: ${metadata.scriptType}');
      print('  Derivation Index: ${metadata.derivationIndex}');
    });

    test('Batch address check reflects projection state', () async {
      print('\n=== Test: Batch Address Check ===');
      
      // Register multiple addresses
      final cmdReceiver = await actorSystem.spawn(
        'batch-cmd-receiver',
        () => _TestReceiverActor(Completer()),
      );
      
      final testAddresses = [
        '1MuuKTCy6Cq8J7rCHqHZpHHWdj5MZb5Mts',
        '1P5ZEDWTKTFGxQjZphgWPQUpe554WKDfHQ',
        '1QLbz7JHiBTspS962RLKV8GndWFwi5j6Qr',
      ];
      
      // Register first two addresses
      for (int i = 0; i < 2; i++) {
        final registerCmd = RegisterDiscoveredAddressCommand(
          walletId: walletId,
          address: testAddresses[i],
          derivationIndex: 20 + i,
          isChange: false,
          transactionCount: 1,
        );
        
        libspiffy.walletManager.tell(
          WalletCommandMessage(walletId, registerCmd),
          sender: cmdReceiver,
        );
      }
      
      // Wait for projection
      await Future.delayed(Duration(milliseconds: 600));
      
      // Batch check all three (third one not registered)
      print('Testing batch address check...');
      final results = await libspiffy.walletStorage.checkAddresses(walletId, testAddresses);
      
      expect(results[testAddresses[0]], isTrue, reason: 'First address should exist');
      expect(results[testAddresses[1]], isTrue, reason: 'Second address should exist');
      expect(results[testAddresses[2]], isFalse, reason: 'Third address should not exist');
      
      print('✓ Batch check results:');
      print('  ${testAddresses[0]}: ${results[testAddresses[0]]}');
      print('  ${testAddresses[1]}: ${results[testAddresses[1]]}');
      print('  ${testAddresses[2]}: ${results[testAddresses[2]]}');
    });

    test('Address persists across LibSpiffy restart', () async {
      print('\n=== Test: Address Persistence Across Restart ===');
      
      // Register address
      final cmdReceiver = await actorSystem.spawn(
        'restart-cmd-receiver',
        () => _TestReceiverActor(Completer()),
      );
      
      final testAddress = '1FoWyxwPXuj4C6abqwhjDWdz6D4PZgYRjA';
      final registerCmd = RegisterDiscoveredAddressCommand(
        walletId: walletId,
        address: testAddress,
        derivationIndex: 99,
        isChange: true,
        transactionCount: 7,
      );
      
      libspiffy.walletManager.tell(
        WalletCommandMessage(walletId, registerCmd),
        sender: cmdReceiver,
      );
      
      // Wait for projection and persistence
      await Future.delayed(Duration(milliseconds: 500));
      
      // Verify in database before shutdown
      final entityBeforeShutdown = await isar.addressEntitys
          .filter()
          .walletIdEqualTo(walletId)
          .and()
          .addressEqualTo(testAddress)
          .findFirst();
      expect(entityBeforeShutdown, isNotNull);
      print('✓ Address persisted before shutdown');
      
      // Shutdown LibSpiffy
      print('Shutting down LibSpiffy...');
      await libspiffy.shutdown();
      
      // Close the original Isar instance before reopening
      print('Closing original Isar instance...');
      await isar.close();
      
      // Reopen Isar with same directory and name
      print('Reopening Isar database...');
      final newIsar = await Isar.open(
        [
          ...LibSpiffySchemas.walletSchemas,
          EventEnvelopeSchema,
          SnapshotEnvelopeSchema,
        ],
        directory: testDir.path,
        name: dbName, // Use same DB name
      );
      
      // Create new actor system and LibSpiffy
      print('Restarting actor system...');
      final newActorSystem = LocalActorSystem(ActorSystemConfig());
      final newLibspiffy = LibSpiffyActorSystem();
      await newLibspiffy.initialize(
        actorSystem: newActorSystem,
        isar: newIsar,
        dataDirectory: testDir.path,
        enableP2P: false,
      );
      
      print('✓ New LibSpiffy instance initialized');
      
      // Give projection time to load
      await Future.delayed(Duration(milliseconds: 500));
      
      // Query via storage
      final exists = await newLibspiffy.walletStorage.isWalletAddress(walletId, testAddress);
      expect(exists, isTrue, 
          reason: 'Address should be loaded from database on restart');
      print('✓ Address found after restart via O(1) lookup');
      
      // Get full metadata
      final metadata = await newLibspiffy.walletStorage.getAddressMetadata(walletId, testAddress);
      expect(metadata, isNotNull);
      expect(metadata!.address, equals(testAddress));
      expect(metadata.derivationIndex, equals(99));
      expect(metadata.isChange, isTrue);
      print('✓ Address metadata preserved after restart');
      print('  Address: ${metadata.address}');
      print('  Derivation Index: ${metadata.derivationIndex}');
      print('  Is Change: ${metadata.isChange}');
      
      // Cleanup new instance
      await newLibspiffy.shutdown();
    });

    test('Idempotent address registration does not duplicate entities', () async {
      print('\n=== Test: Idempotent Address Registration ===');
      
      final cmdReceiver = await actorSystem.spawn(
        'idempotent-receiver',
        () => _TestReceiverActor(Completer()),
      );
      
      final testAddress = '1NgD4tcVQa6sLrBMGXNSUJfYsDGJMJ1eG8';
      
      // Send same command twice
      for (int i = 0; i < 2; i++) {
        final registerCmd = RegisterDiscoveredAddressCommand(
          walletId: walletId,
          address: testAddress,
          derivationIndex: 50,
          isChange: false,
          transactionCount: 1,
        );
        
        libspiffy.walletManager.tell(
          WalletCommandMessage(walletId, registerCmd),
          sender: cmdReceiver,
        );
        
        print('✓ Sent RegisterDiscoveredAddressCommand #${i + 1}');
        await Future.delayed(Duration(milliseconds: 200));
      }
      
      // Wait for all projections
      await Future.delayed(Duration(milliseconds: 500));
      
      // Count entities for this address
      final count = await isar.addressEntitys
          .filter()
          .walletIdEqualTo(walletId)
          .and()
          .addressEqualTo(testAddress)
          .count();
      
      expect(count, equals(1), 
          reason: 'Idempotent command should not create duplicate AddressEntity');
      print('✓ Only 1 AddressEntity created despite 2 commands (idempotent)');
    });

    test('Address filtering works via projection state', () async {
      print('\n=== Test: Address Filtering ===');
      
      final cmdReceiver = await actorSystem.spawn(
        'filter-receiver',
        () => _TestReceiverActor(Completer()),
      );
      
      // Register mix of receiving and change addresses
      final addresses = [
        ('1Filter1Receive1AAAAAAAAAAAAAAAA', 60, false),
        ('1Filter2Receive2BBBBBBBBBBBBBBBB', 61, false),
        ('1Filter3Change1CCCCCCCCCCCCCCCC', 62, true),
        ('1Filter4Change2DDDDDDDDDDDDDDDD', 63, true),
      ];
      
      for (final (address, index, isChange) in addresses) {
        final registerCmd = RegisterDiscoveredAddressCommand(
          walletId: walletId,
          address: address,
          derivationIndex: index,
          isChange: isChange,
          transactionCount: 1,
        );
        
        libspiffy.walletManager.tell(
          WalletCommandMessage(walletId, registerCmd),
          sender: cmdReceiver,
        );
      }
      
      // Wait for projection
      await Future.delayed(Duration(milliseconds: 800));
      
      // Filter receiving addresses
      print('Filtering receiving addresses...');
      final receiving = await libspiffy.walletStorage.getAddressesWithMetadata(
        walletId,
        isChange: false,
      );
      
      final receivingAddrs = receiving.map((a) => a.address).toList();
      expect(receivingAddrs, contains('1Filter1Receive1AAAAAAAAAAAAAAAA'));
      expect(receivingAddrs, contains('1Filter2Receive2BBBBBBBBBBBBBBBB'));
      expect(receivingAddrs, isNot(contains('1Filter3Change1CCCCCCCCCCCCCCCC')));
      print('✓ Receiving addresses filtered correctly (${receiving.length} found)');
      
      // Filter change addresses
      print('Filtering change addresses...');
      final change = await libspiffy.walletStorage.getAddressesWithMetadata(
        walletId,
        isChange: true,
      );
      
      final changeAddrs = change.map((a) => a.address).toList();
      expect(changeAddrs, contains('1Filter3Change1CCCCCCCCCCCCCCCC'));
      expect(changeAddrs, contains('1Filter4Change2DDDDDDDDDDDDDDDD'));
      expect(changeAddrs, isNot(contains('1Filter1Receive1AAAAAAAAAAAAAAAA')));
      print('✓ Change addresses filtered correctly (${change.length} found)');
    });
  });
}

/// Simple test receiver actor
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

