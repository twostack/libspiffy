/// Integration test for XPub (Watch-Only) Wallet Lifecycle
/// Verifies creation, address generation, and strict signing restrictions
import 'dart:async';
import 'dart:io';
import 'package:test/test.dart';
import 'package:dactor/dactor.dart';
import 'package:isar/isar.dart';
import 'package:eventador/eventador.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:libspiffy/libspiffy.dart';
import 'package:libspiffy/internals.dart';
import 'package:libspiffy/src/actors/libspiffy_actor_system.dart';
import 'package:libspiffy/src/actors/wallet_messages.dart';
import 'package:libspiffy/src/storage/isar_wallet_storage.dart';
import 'isar_test_helper.dart';

void main() {
  group('XPub Wallet Integration Tests', () {
    setUpAll(() async {
      await ensureIsarInitialized();
    });

    test('XPub Wallet Lifecycle Test', () async {
    print('\n=== XPub Wallet Lifecycle Test ===');
    final testDir = await Directory.systemTemp.createTemp('xpub_test_');
    final dbName = 'xpub_test_${DateTime.now().microsecondsSinceEpoch}';
    
    final isar = await Isar.open(
      LibSpiffySchemas.allSchemas,
      directory: testDir.path,
      name: dbName,
    );

    final actorSystem = LocalActorSystem(ActorSystemConfig());
    final libspiffy = LibSpiffyActorSystem();
    await libspiffy.initialize(
      actorSystem: actorSystem,
      isar: isar,
      dataDirectory: testDir.path,
      enableP2P: false
    );

    try {
      // Step 0: Generate a valid XPUB from a temporary mnemonic
      final cryptoService = DartSVCryptoService();
      final mnemonic = await cryptoService.generateMnemonic();
      final hdPriv = await cryptoService.mnemonicToHDPrivateKey(mnemonic, network: dartsv.NetworkType.TEST);
      final hdPub = cryptoService.deriveHDPublicKey(hdPriv);
      final xpub = hdPub.xpubkey;
      print('✓ Generated test xpub: ${xpub.substring(0, 10)}...');

      // Setup receiver with broadcast StreamController (allows multiple listeners)
      final controller = StreamController<dynamic>.broadcast();
      final receiver = await actorSystem.spawn('test-receiver', () => _TestReceiverActor(controller));

      // Step 1: Create XPub Wallet
      print('\n[Step 1] Creating XPub Wallet...');
      final walletId = 'xpub-wallet-${DateTime.now().millisecondsSinceEpoch}';
      
      libspiffy.walletManager.tell(
        CreateWalletMessage(walletId, 'Watch Only', xpub: xpub),
        sender: receiver,
      );

      final createResponse = await _waitForMessage<WalletCreatedMessage>(controller.stream);
      expect(createResponse.success, isTrue);
      expect(createResponse.walletId, equals(walletId));
      expect(createResponse.rootAddress, isNotEmpty);
      print('✓ XPub Wallet created with root address: ${createResponse.rootAddress}');


      
      libspiffy.walletManager.tell(
        WalletCommandMessage(
          walletId,
          GenerateAddressCommand(walletId: walletId),
        ),
        sender: receiver,
      );

      final addrResponse = await _waitForMessage<AddressGeneratedResponse>(controller.stream);
      expect(addrResponse.success, isTrue);
      expect(addrResponse.derivationIndex, greaterThan(0));
      print('✓ Address generated: ${addrResponse.address} (index ${addrResponse.derivationIndex})');

      // Step 3: Attempt Signing (Should FAIL)
      print('\n[Step 3] Attempting Signing (Expect Failure)...');

      final dummyTxHex = '01000000000000000000'; // Invalid hex but checks happen before strict parsing validation in some cases

      libspiffy.walletManager.tell(
        WalletCommandMessage(
          walletId,
          SignTransactionCommand(
            walletId: walletId,
            transactionId: 'tx-dummy',
            rawTransaction: dummyTxHex,
            utxoKeys: ['dummy:0'],
            publicKeys: ['pubkey'],
          ),
        ),
        sender: receiver,
      );

      final signResponse = await _waitForMessage<TransactionSignedResponse>(controller.stream);
      
      print('Response success: ${signResponse.success}');
      print('Response error: ${signResponse.error}');

      expect(signResponse.success, isFalse);
      expect(signResponse.error, contains('watch-only'));
      print('✓ Signing attempt correctly rejected');
      
      await controller.close();

    } catch (e, st) {
      print('TEST FAILED: $e');
      print(st);
      rethrow;
    } finally {
      // Shutdown in correct order: libspiffy first (which uses isar), then isar
      await libspiffy.shutdown();
      // Give async projections time to complete before closing isar
      await Future.delayed(Duration(milliseconds: 100));
      await actorSystem.shutdown();
      if (isar.isOpen) {
        await isar.close();
      }
      try {
        await testDir.delete(recursive: true);
      } catch (_) {}
    }
  }, timeout: Timeout(Duration(seconds: 30)));

    test('XPub Wallet Multiple Address Generation', () async {
      print('\n=== XPub Wallet Multiple Address Generation Test ===');

      // Setup: Initialize Isar and Actor System
      await ensureIsarInitialized();
      final testDir = await Directory.systemTemp.createTemp('xpub_multi_addr_test_');
      final dbName = 'xpub_multi_addr_test_${DateTime.now().microsecondsSinceEpoch}';
      
      final isar = await Isar.open(
        LibSpiffySchemas.allSchemas,
        directory: testDir.path,
        name: dbName,
      );

      final actorSystem = LocalActorSystem(ActorSystemConfig());
      final libspiffy = LibSpiffyActorSystem();
      await libspiffy.initialize(
        actorSystem: actorSystem,
        isar: isar,
        dataDirectory: testDir.path,
        enableP2P: false
      );

      try {
        // Generate a valid XPUB
        final cryptoService = DartSVCryptoService();
        final mnemonic = await cryptoService.generateMnemonic();
        final hdPriv = await cryptoService.mnemonicToHDPrivateKey(mnemonic, network: dartsv.NetworkType.TEST);
        final hdPub = cryptoService.deriveHDPublicKey(hdPriv);
        final xpub = hdPub.xpubkey;

        final controller = StreamController<dynamic>.broadcast();
        final receiver = await actorSystem.spawn('test-receiver', () => _TestReceiverActor(controller));

        // Create XPub Wallet
        final walletId = 'xpub-multi-addr-${DateTime.now().millisecondsSinceEpoch}';
        libspiffy.walletManager.tell(
          CreateWalletMessage(walletId, 'Multi Address Wallet', xpub: xpub),
          sender: receiver,
        );

        final createResponse = await _waitForMessage<WalletCreatedMessage>(controller.stream);
        expect(createResponse.success, isTrue);
        print('✓ Wallet created with root address (index 0)');

        // Generate first address (index 1)
        libspiffy.walletManager.tell(
          WalletCommandMessage(walletId, GenerateAddressCommand(walletId: walletId, label: 'Address 1')),
          sender: receiver,
        );

        final addr1Response = await _waitForMessage<AddressGeneratedResponse>(controller.stream);
        expect(addr1Response.success, isTrue);
        expect(addr1Response.derivationIndex, equals(1));
        print('✓ Address 1 generated at index ${addr1Response.derivationIndex}');

        // Generate second address (index 2)
        libspiffy.walletManager.tell(
          WalletCommandMessage(walletId, GenerateAddressCommand(walletId: walletId, label: 'Address 2')),
          sender: receiver,
        );

        final addr2Response = await _waitForMessage<AddressGeneratedResponse>(controller.stream);
        expect(addr2Response.success, isTrue);
        expect(addr2Response.derivationIndex, equals(2));
        print('✓ Address 2 generated at index ${addr2Response.derivationIndex}');

        // Generate third address (index 3)
        libspiffy.walletManager.tell(
          WalletCommandMessage(walletId, GenerateAddressCommand(walletId: walletId, label: 'Address 3')),
          sender: receiver,
        );

        final addr3Response = await _waitForMessage<AddressGeneratedResponse>(controller.stream);
        expect(addr3Response.success, isTrue);
        expect(addr3Response.derivationIndex, equals(3));
        print('✓ Address 3 generated at index ${addr3Response.derivationIndex}');

        // Verify all addresses are different
        expect(addr1Response.address, isNot(equals(createResponse.rootAddress)));
        expect(addr2Response.address, isNot(equals(addr1Response.address)));
        expect(addr3Response.address, isNot(equals(addr2Response.address)));

        await controller.close();

      } catch (e, st) {
        print('TEST FAILED: $e');
        print(st);
        rethrow;
      } finally {
        await libspiffy.shutdown();
        await Future.delayed(Duration(milliseconds: 100));
        await actorSystem.shutdown();
        if (isar.isOpen) {
          await isar.close();
        }
        try {
          await testDir.delete(recursive: true);
        } catch (_) {}
      }
    }, timeout: Timeout(Duration(seconds: 30)));

    test('XPub Wallet UTXO Reception', () async {
      print('\n=== XPub Wallet UTXO Reception Test ===');

      // Setup: Initialize Isar and Actor System
      await ensureIsarInitialized();
      final testDir = await Directory.systemTemp.createTemp('xpub_utxo_test_');
      final dbName = 'xpub_utxo_test_${DateTime.now().microsecondsSinceEpoch}';
      
      final isar = await Isar.open(
        LibSpiffySchemas.allSchemas,
        directory: testDir.path,
        name: dbName,
      );

      final actorSystem = LocalActorSystem(ActorSystemConfig());
      final libspiffy = LibSpiffyActorSystem();
      await libspiffy.initialize(
        actorSystem: actorSystem,
        isar: isar,
        dataDirectory: testDir.path,
        enableP2P: false
      );

      try {
        // Generate a valid XPUB
        final cryptoService = DartSVCryptoService();
        final mnemonic = await cryptoService.generateMnemonic();
        final hdPriv = await cryptoService.mnemonicToHDPrivateKey(mnemonic, network: dartsv.NetworkType.TEST);
        final hdPub = cryptoService.deriveHDPublicKey(hdPriv);
        final xpub = hdPub.xpubkey;

        final controller = StreamController<dynamic>.broadcast();
        final receiver = await actorSystem.spawn('test-receiver', () => _TestReceiverActor(controller));

        // Create XPub Wallet
        final walletId = 'xpub-utxo-${DateTime.now().millisecondsSinceEpoch}';
        libspiffy.walletManager.tell(
          CreateWalletMessage(walletId, 'UTXO Test Wallet', xpub: xpub),
          sender: receiver,
        );

        final createResponse = await _waitForMessage<WalletCreatedMessage>(controller.stream);
        expect(createResponse.success, isTrue);
        final rootAddress = createResponse.rootAddress;
        print('✓ Wallet created with root address: $rootAddress');

        // Simulate receiving a UTXO
        libspiffy.walletManager.tell(
          WalletCommandMessage(
            walletId,
            ReceiveUTXOCommand(
              walletId: walletId,
              txid: '0000000000000000000000000000000000000000000000000000000000000abc',
              vout: 0,
              satoshis: BigInt.from(500000),
              scriptPubKey: '76a914000000000000000000000000000000000000000088ac',
              address: rootAddress,
              blockHeight: 800000,
              confirmations: 6,
            ),
          ),
          sender: receiver,
        );

        final utxoResponse = await _waitForMessage<UTXOReceivedResponse>(controller.stream);
        expect(utxoResponse.success, isTrue);
        expect(utxoResponse.txid, equals('0000000000000000000000000000000000000000000000000000000000000abc'));
        expect(utxoResponse.vout, equals(0));
        print('✓ UTXO received successfully');

        await controller.close();

      } catch (e, st) {
        print('TEST FAILED: $e');
        print(st);
        rethrow;
      } finally {
        await libspiffy.shutdown();
        await Future.delayed(Duration(milliseconds: 100));
        await actorSystem.shutdown();
        if (isar.isOpen) {
          await isar.close();
        }
        try {
          await testDir.delete(recursive: true);
        } catch (_) {}
      }
    }, timeout: Timeout(Duration(seconds: 30)));

    test('XPub Wallet Rejects All Signing Operations', () async {
      print('\n=== XPub Wallet Rejects All Signing Operations Test ===');

      // Setup: Initialize Isar and Actor System
      await ensureIsarInitialized();
      final testDir = await Directory.systemTemp.createTemp('xpub_signing_test_');
      final dbName = 'xpub_signing_test_${DateTime.now().microsecondsSinceEpoch}';
      
      final isar = await Isar.open(
        LibSpiffySchemas.allSchemas,
        directory: testDir.path,
        name: dbName,
      );

      final actorSystem = LocalActorSystem(ActorSystemConfig());
      final libspiffy = LibSpiffyActorSystem();
      await libspiffy.initialize(
        actorSystem: actorSystem,
        isar: isar,
        dataDirectory: testDir.path,
        enableP2P: false
      );

      try {
        // Generate a valid XPUB
        final cryptoService = DartSVCryptoService();
        final mnemonic = await cryptoService.generateMnemonic();
        final hdPriv = await cryptoService.mnemonicToHDPrivateKey(mnemonic, network: dartsv.NetworkType.TEST);
        final hdPub = cryptoService.deriveHDPublicKey(hdPriv);
        final xpub = hdPub.xpubkey;

        final controller = StreamController<dynamic>.broadcast();
        final receiver = await actorSystem.spawn('test-receiver', () => _TestReceiverActor(controller));

        // Create XPub Wallet
        final walletId = 'xpub-signing-${DateTime.now().millisecondsSinceEpoch}';
        libspiffy.walletManager.tell(
          CreateWalletMessage(walletId, 'Signing Test Wallet', xpub: xpub),
          sender: receiver,
        );

        final createResponse = await _waitForMessage<WalletCreatedMessage>(controller.stream);
        expect(createResponse.success, isTrue);
        print('✓ Wallet created');

        // Test 1: SignTransactionCommand
        print('\n[Test 1] SignTransactionCommand...');
        libspiffy.walletManager.tell(
          WalletCommandMessage(
            walletId,
            SignTransactionCommand(
              walletId: walletId,
              transactionId: 'tx-test',
              rawTransaction: '01000000000000000000',
              utxoKeys: ['dummy:0'],
              publicKeys: ['pubkey'],
            ),
          ),
          sender: receiver,
        );

        final signResponse = await _waitForMessage<TransactionSignedResponse>(controller.stream);
        expect(signResponse.success, isFalse);
        expect(signResponse.error, contains('watch-only'));
        print('✓ SignTransactionCommand correctly rejected');

        // Test 2: SignMultisigTransactionCommand
        print('\n[Test 2] SignMultisigTransactionCommand...');
        libspiffy.walletManager.tell(
          WalletCommandMessage(
            walletId,
            SignMultisigTransactionCommand(
              walletId: walletId,
              transactionId: 'tx-multisig',
              rawTransaction: '01000000000000000000',
              derivationIndex: 0,
              inputIndex: 0,
              prevOutValue: 100000,
              redeemScriptHex: 'script',
            ),
          ),
          sender: receiver,
        );

        final multisigResponse = await _waitForMessage<MultisigTransactionSignedResponse>(controller.stream);
        expect(multisigResponse.success, isFalse);
        expect(multisigResponse.error, contains('watch-only'));
        print('✓ SignMultisigTransactionCommand correctly rejected');

        // Test 3: BuildFundingTransactionCommand
        print('\n[Test 3] BuildFundingTransactionCommand...');
        libspiffy.walletManager.tell(
          WalletCommandMessage(
            walletId,
            BuildFundingTransactionCommand(
              walletId: walletId,
              correlationId: 'test-corr',
              channelId: 'test-channel',
              clientPubKeyHex: 'client-key',
              serverPubKeyHex: 'server-key',
              fundingAmountSats: 100000,
              changeAddressBase58: 'change-addr',
            ),
          ),
          sender: receiver,
        );

        final fundingResponse = await _waitForMessage<FundingTransactionBuiltResponse>(controller.stream);
        expect(fundingResponse.success, isFalse);
        expect(fundingResponse.error, contains('watch-only'));
        print('✓ BuildFundingTransactionCommand correctly rejected');

        // Test 4: SplitUTXOsToBenfordCommand
        print('\n[Test 4] SplitUTXOsToBenfordCommand...');
        libspiffy.walletManager.tell(
          WalletCommandMessage(
            walletId,
            SplitUTXOsToBenfordCommand(
              walletId: walletId,
              targetUtxoCount: 5,
            ),
          ),
          sender: receiver,
        );

        final splitResponse = await _waitForMessage<SplitUTXOsResponse>(controller.stream);
        expect(splitResponse.success, isFalse);
        expect(splitResponse.error, contains('watch-only'));
        print('✓ SplitUTXOsToBenfordCommand correctly rejected');

        await controller.close();

      } catch (e, st) {
        print('TEST FAILED: $e');
        print(st);
        rethrow;
      } finally {
        await libspiffy.shutdown();
        await Future.delayed(Duration(milliseconds: 100));
        await actorSystem.shutdown();
        if (isar.isOpen) {
          await isar.close();
        }
        try {
          await testDir.delete(recursive: true);
        } catch (_) {}
      }
    }, timeout: Timeout(Duration(seconds: 45)));
  });
}

// Helper to wait for specific response type from stream
Future<T> _waitForMessage<T>(Stream<dynamic> stream) async {
  // We need to listen to the broadcast stream (if it is one) or just take first.
  // Since we process sequentially, we can just take the next event.
  // But standard StreamController is single-subscription.
  // Note: Actor messages might come in any order if parallel, but here we invoke sequentially.
  // HOWEVER, we need to filter/skip unrelated messages if any (unlikely in test).
  
  // This helper assumes the NEXT message is the one we want.
  // Ideally, we filter.
  
  try {
     await for (final message in stream) {
       if (message is T) {
         return message as T;
       }
       // Ignore other messages? Or throw? 
       // For this strict test, let's print and continue if it's not what we want but maybe log it.
       print('Ignoring unexpected message: ${message.runtimeType}');
     }
  } catch (e) {
     throw Exception('Stream error or closed before receiving ${T.toString()}: $e');
  }
  throw Exception('Stream closed before receiving ${T.toString()}');
}

class _TestReceiverActor extends Actor {
  final StreamController<dynamic> _controller;
  
  _TestReceiverActor(this._controller);
  
  @override
  Future<void> onMessage(dynamic message) async {
    if (!_controller.isClosed) {
      _controller.add(message);
    }
  }
}
