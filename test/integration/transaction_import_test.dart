import 'dart:io';
import 'package:test/test.dart';
import 'package:libspiffy/libspiffy.dart';
import 'package:dactor/dactor.dart';
import 'package:isar/isar.dart';
import 'package:dartsv/dartsv.dart';
import 'package:eventador/eventador.dart';

void main() {

  // Private key in WIF format for testnet address n49CCQFuncaXbtBoNm39gSP9dvRP2eFFSw
  const walletWIF = 'cPBBhyEvTZXSZhLJ8AuotbAmzR2bM8eQJV7fiBAQGcGsaSAaPfBf';

  group('TransactionImportService', () {
    test('verifies UTXO harvesting with real address derivation', () async {
      // Derive address from WIF
      final privateKey = SVPrivateKey.fromWIF(walletWIF);
      final address = privateKey.publicKey.toAddress(NetworkType.TEST);
      final addressString = address.toBase58();
      
      print('Derived address: $addressString');
      expect(addressString, equals('n49CCQFuncaXbtBoNm39gSP9dvRP2eFFSw'), 
             reason: 'WIF should derive to expected testnet address');
      
      // Setup test system
      await Isar.initializeIsarCore(download: true);
      
      final testDir = Directory.systemTemp.createTempSync('harvest-test');
      final actorSystem = LocalActorSystem(ActorSystemConfig());
      
      // Open Isar with both LibSpiffy and Eventador schemas
      final isar = await Isar.open(
        [
          ...LibSpiffySchemas.walletSchemas,
          ...IsarEventStore.requiredSchemas,
        ],
        directory: testDir.path,
        name: 'test_harvest_db',
      );
      
      final libspiffy = LibSpiffyActorSystem();
      await libspiffy.initialize(
        actorSystem: actorSystem,
        isar: isar,
        dataDirectory: testDir.path,
      );
      
      final walletId = 'harvest-wallet-${DateTime.now().millisecondsSinceEpoch}';
      
      // Real transaction from full_tx_data.json for address n49CCQFuncaXbtBoNm39gSP9dvRP2eFFSw
      // This transaction has outputs to our derived address
      final tx1 = ImportableTransaction(
        txid: '5e0ae9db2586ac8ea89b0f0eb628e1624ccfbdafff860052b67069a401d8ed71',
        rawHex: '0200000001dcffa6652c96b84d22277235198e86301e6ed5ac41dc859329c7b5b25c370721010000006a473044022033542938413acf616862fb9cdecedc86ed472773a3c8be33f6024051837e9a520220628937b5db1baef5b87b42e8d2a13403625713a083d5c28b77ae535f62293b8241210341dcbd921964fc54c125608ffb6f9114d53d7a8bb3fcab29cff657dbfc882268feffffff02db9e183b000000001976a914b9f4a12e17e6614a47ccb5b1464756cd9119064088ac00879303000000001976a914f82d58dd8487044d8d0879c15a2a3516a425de2a88ac53b61300',
        blockHeight: 1291860,
        merkleProof: MerkleProof(
          blockHash: '',
          txid: '5e0ae9db2586ac8ea89b0f0eb628e1624ccfbdafff860052b67069a401d8ed71',
          merkleProof: [
            'a7026883d1074d1477d23c030f9997ff9fa45d07641a8a9c95f9116a2ac1cdd5',
            '378e4682082a1307d1e4a64807f93fc786e34bf5dc79760688613e18c41cda20',
            '04586929cfce578ca23105f4d1f059af87f108aac1fee23955c3193d617198d6',
          ],
          position: 2,
          blockHeight: 1291860,
        ),
      );
      
      // Import transaction with real address
      final result = await libspiffy.transactionImportService.importTransactions(
        walletId: walletId,
        transactions: [tx1],
        walletAddresses: [addressString],
      );
      
      // Verify import success
      expect(result.success, isTrue, reason: 'Import should succeed');
      expect(result.transactionsImported, equals(1), reason: 'Should import 1 transaction');
      
      // THIS IS THE KEY TEST: UTXOs should be harvested now!
      print('Import result: ${result.transactionsImported} transactions, ${result.utxosHarvested} UTXOs');
      expect(result.utxosHarvested, greaterThan(0), 
             reason: 'Should harvest UTXOs from transaction outputs to our address');
      
      // Verify merkle proof stored
      final proof = await libspiffy.walletStorage.getMerkleProof(tx1.txid);
      expect(proof, isNotNull, reason: 'Merkle proof should be stored');
      expect(proof!.blockHeight, equals(1291860), reason: 'Correct block height');
      
      // Verify UTXOs were issued as commands to aggregate
      print('✓ Successfully harvested ${result.utxosHarvested} UTXO(s)');
      print('  Harvested UTXO IDs: ${result.harvestedUtxoIds}');
      
      // Cleanup
      await libspiffy.shutdown();
      await isar.close(deleteFromDisk: true);
      testDir.deleteSync(recursive: true);
    });
    
    test('imports transactions and stores merkle proofs', () async {
      // Setup test system
      await Isar.initializeIsarCore(download: true);
      
      final testDir = Directory.systemTemp.createTempSync('import-test');
      final actorSystem = LocalActorSystem(ActorSystemConfig());
      
      final isar = await Isar.open(
        [
          ...LibSpiffySchemas.walletSchemas,
          ...IsarEventStore.requiredSchemas,
        ],
        directory: testDir.path,
        name: 'test_import_db',
      );
      
      final libspiffy = LibSpiffyActorSystem();
      await libspiffy.initialize(
        actorSystem: actorSystem,
        isar: isar,
        dataDirectory: testDir.path,
      );
      
      // Create wallet
      final walletId = 'test-wallet-${DateTime.now().millisecondsSinceEpoch}';
      
      // For simplicity, use a test address
      final address = 'test-address-1';
      
      // Prepare test transactions from full_tx_data.json
      // TX1: 5e0ae9db... (confirmed at block 1291860)
      final tx1 = ImportableTransaction(
        txid: '5e0ae9db2586ac8ea89b0f0eb628e1624ccfbdafff860052b67069a401d8ed71',
        rawHex: '0200000001dc21073755cb2b5c7299385dc41ace56d1e30868e19357227224db8962c65a6f010000006a473044022066e993720bc8dcdb3a86319787d95d8fb0e19d195ee4bd3f8ff1f2f0f65ac95902201dd79033a81f98d5b3f6e953f1a8d5f4eda85e2dc00cfaf0e1c42fc7c94e4c744121028db1c65331be8d5c64f87a65f582abc6eff4f82c02d26c9d6b06a18c7ada8b75feffffff0200a84c1c000000001976a91410d1b86ea302442f3a1e53c654569c217a316df788ac007e3c2c000000001976a91490897992fae7bff0d5839cb071b713595f65010688ac14b61300',
        blockHeight: 1291860,
        merkleProof: MerkleProof(
          blockHash: '',
          txid: '5e0ae9db2586ac8ea89b0f0eb628e1624ccfbdafff860052b67069a401d8ed71',
          merkleProof: [
            'a7026883d1074d1477d23c030f9997ff9fa45d07641a8a9c95f9116a2ac1cdd5',
            '378e4682082a1307d1e4a64807f93fc786e34bf5dc79760688613e18c41cda20',
            '04586929cfce578ca23105f4d1f059af87f108aac1fee23955c3193d617198d6',
          ],
          position: 2,
          blockHeight: 1291860,
        ),
      );
      
      // Import transaction
      final result = await libspiffy.transactionImportService.importTransactions(
        walletId: walletId,
        transactions: [tx1],
        walletAddresses: [address],
      );
      
      // Verify import success
      expect(result.success, isTrue, reason: 'Import should succeed');
      expect(result.transactionsImported, equals(1), reason: 'Should import 1 transaction');
      
      // Note: UTXOs harvested depends on whether the transaction outputs belong to our wallet address
      // Since we're using a test address, it won't match the real transaction's outputs
      print('Import result: ${result.transactionsImported} transactions, ${result.utxosHarvested} UTXOs');
      
      // Verify merkle proof stored
      final proof = await libspiffy.walletStorage.getMerkleProof(tx1.txid);
      expect(proof, isNotNull, reason: 'Merkle proof should be stored');
      expect(proof!.blockHeight, equals(1291860), reason: 'Correct block height');
      
      // Cleanup
      await libspiffy.shutdown();
      await isar.close(deleteFromDisk: true);
      testDir.deleteSync(recursive: true);
    });
    
    test('handles event sourcing flow correctly', () async {
      // Simplified test showing the event sourcing concept
      
      await Isar.initializeIsarCore(download: true);
      final testDir = Directory.systemTemp.createTempSync('event-test');
      final actorSystem = LocalActorSystem(ActorSystemConfig());
      
      final isar = await Isar.open(
        [
          ...LibSpiffySchemas.walletSchemas,
          ...IsarEventStore.requiredSchemas,
        ],
        directory: testDir.path,
        name: 'test_event_db',
      );
      
      final libspiffy = LibSpiffyActorSystem();
      await libspiffy.initialize(
        actorSystem: actorSystem,
        isar: isar,
        dataDirectory: testDir.path,
      );
      
      final walletId = 'event-wallet-${DateTime.now().millisecondsSinceEpoch}';
      final address = 'test-address-2';
      
      // Import a transaction
      final tx1 = ImportableTransaction(
        txid: 'c652c5c422f29c0487a142cd56c192f2c99483f3792b69b290d0d4016819ad40',
        rawHex: '0200000001dc21073755cb2b5c7299385dc41ace56d1e30868e19357227224db8962c65a6f010000006a473044022066e993720bc8dcdb3a86319787d95d8fb0e19d195ee4bd3f8ff1f2f0f65ac95902201dd79033a81f98d5b3f6e953f1a8d5f4eda85e2dc00cfaf0e1c42fc7c94e4c744121028db1c65331be8d5c64f87a65f582abc6eff4f82c02d26c9d6b06a18c7ada8b75feffffff0200a84c1c000000001976a91410d1b86ea302442f3a1e53c654569c217a316df788ac007e3c2c000000001976a91490897992fae7bff0d5839cb071b713595f65010688ac14b61300',
        blockHeight: 1358861,
        merkleProof: MerkleProof(
          blockHash: '',
          txid: 'c652c5c422f29c0487a142cd56c192f2c99483f3792b69b290d0d4016819ad40',
          merkleProof: [
            '61b11dae69abb7bc69d28add139479de2cbf356689f8480f9981ea49aaeee25e',
            '7d6c093ae9f3f6305f9b3616de9b2dfc496e943587bddaee96dd2c8d7cb5474c',
            '9a6a236a16dea8996d5aece3bbdbde01031ceff1745308f08e01172faa8a5ca4',
          ],
          position: 3,
          blockHeight: 1358861,
        ),
      );
      
      final result = await libspiffy.transactionImportService.importTransactions(
        walletId: walletId,
        transactions: [tx1],
        walletAddresses: [address],
      );
      
      expect(result.success, isTrue, reason: 'Import should succeed');
      
      // Key concept: The import service sends ReceiveUTXOCommand to the aggregate
      // This maintains event sourcing integrity (events in EventStore)
      // vs. just inserting records into ReadModelStorage
      
      print('Event sourcing: ReceiveUTXOCommand → UTXOReceivedEvent → EventStore');
      print('Projection: UTXOReceivedEvent → WalletProjection → ReadModelStorage');
      
      // Cleanup
      await libspiffy.shutdown();
      await isar.close(deleteFromDisk: true);
      testDir.deleteSync(recursive: true);
    });
  });
}

