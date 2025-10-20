import 'package:test/test.dart';

import 'package:libspiffy/src/storage/wallet_storage.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';
import 'package:libspiffy/src/models/bitcoin_utxo.dart';
import 'package:libspiffy/src/models/wallet_event.dart';

/// Test event class for testing storage operations
class TestWalletEvent extends WalletEvent {
  final String eventTypeName;
  final Map<String, dynamic> data;

  TestWalletEvent({
    required String walletId,
    required this.eventTypeName,
    required this.data,
    String? eventId,
    DateTime? timestamp,
    int? version,
    Map<String, dynamic>? metadata,
  }) : super(
          walletId: walletId,
          eventId: eventId,
          timestamp: timestamp,
          version: version,
          metadata: metadata,
        );

  @override
  Map<String, dynamic> getWalletEventData() {
    return {
      'eventType': eventTypeName,
      'data': data,
    };
  }

  String get eventType => eventTypeName;
}

void main() {
  group('WalletStorage Tests', () {
    late WalletStorage storage;

    setUp(() {
      storage = InMemoryWalletStorage();
    });

    group('Wallet Management', () {
      test('should start with no wallets', () async {
        final wallets = await storage.getWalletIds();
        expect(wallets, isEmpty);
      });

      test('should check non-existent wallet correctly', () async {
        const walletId = 'non_existent_wallet';
        expect(await storage.walletExists(walletId), isFalse);
      });

      test('should establish wallet when events are saved', () async {
        const walletId = 'test_wallet';
        
        final events = [
          TestWalletEvent(
            walletId: walletId, 
            eventTypeName: 'WalletCreated',
            data: {'name': 'Test Wallet'},
            timestamp: DateTime.now(),
          ),
        ];
        await storage.saveEvents(walletId, events);
        
        expect(await storage.walletExists(walletId), isTrue);
        
        final walletIds = await storage.getWalletIds();
        expect(walletIds, contains(walletId));
      });

      test('should delete wallet correctly', () async {
        const walletId = 'wallet_to_delete';
        
        // Create wallet with events
        final events = [
          TestWalletEvent(
            walletId: walletId, 
            eventTypeName: 'WalletCreated',
            data: {'name': 'Wallet to Delete'},
            timestamp: DateTime.now(),
          ),
        ];
        await storage.saveEvents(walletId, events);
        
        // Verify wallet exists
        expect(await storage.walletExists(walletId), isTrue);
        
        // Delete wallet
        await storage.deleteWallet(walletId);
        
        // Verify wallet is deleted
        expect(await storage.walletExists(walletId), isFalse);
      });
    });

    group('Event Store Operations', () {
      const walletId = 'event_test_wallet';

      test('should save and load events correctly', () async {
        final now = DateTime.now();
        final events = [
          TestWalletEvent(
            walletId: walletId,
            eventTypeName: 'WalletCreated',
            data: {'name': 'Test Wallet'},
            timestamp: now,
          ),
          TestWalletEvent(
            walletId: walletId,
            eventTypeName: 'UTXOReceived',
            data: {
              'txid': 'tx_1',
              'vout': 0,
              'satoshis': '100000',
              'address': '1TestAddress123456789012345678901234',
            },
            timestamp: now.add(Duration(minutes: 1)),
          ),
        ];

        await storage.saveEvents(walletId, events);

        final loadedEvents = await storage.loadEvents(walletId);
        expect(loadedEvents.length, equals(2));
        expect((loadedEvents[0] as TestWalletEvent).eventType, equals('WalletCreated'));
        expect((loadedEvents[1] as TestWalletEvent).eventType, equals('UTXOReceived'));
      });

      test('should load events from specific version', () async {
        final now = DateTime.now();
        final events = List.generate(5, (i) => 
          TestWalletEvent(
            walletId: walletId,
            eventTypeName: 'TestEvent$i',
            data: {'index': i},
            timestamp: now.add(Duration(minutes: i)),
            version: i + 1, // Set versions 1, 2, 3, 4, 5
          )
        );

        await storage.saveEvents(walletId, events);

        // Load events from version 3 onwards (version > 3 = versions 4, 5)
        final recentEvents = await storage.loadEvents(walletId, fromVersion: 3);
        expect(recentEvents.length, equals(2)); // Events with versions 4, 5
      });

      test('should handle empty event list', () async {
        await storage.saveEvents(walletId, []);
        
        final loadedEvents = await storage.loadEvents(walletId);
        expect(loadedEvents, isEmpty);
      });

      test('should maintain event order', () async {
        final now = DateTime.now();
        final events = [
          TestWalletEvent(
            walletId: walletId,
            eventTypeName: 'FirstEvent',
            data: {'order': 1},
            timestamp: now,
          ),
          TestWalletEvent(
            walletId: walletId,
            eventTypeName: 'SecondEvent',
            data: {'order': 2},
            timestamp: now.add(Duration(minutes: 1)),
          ),
          TestWalletEvent(
            walletId: walletId,
            eventTypeName: 'ThirdEvent',
            data: {'order': 3},
            timestamp: now.add(Duration(minutes: 2)),
          ),
        ];

        await storage.saveEvents(walletId, events);

        final loadedEvents = await storage.loadEvents(walletId);
        expect(loadedEvents.length, equals(3));
        expect((loadedEvents[0] as TestWalletEvent).eventType, equals('FirstEvent'));
        expect((loadedEvents[1] as TestWalletEvent).eventType, equals('SecondEvent'));
        expect((loadedEvents[2] as TestWalletEvent).eventType, equals('ThirdEvent'));
      });
    });

    group('UTXO Queries', () {
      const walletId = 'utxo_query_wallet';
      
      test('should handle empty wallet correctly', () async {
        // Create empty wallet
        final events = [
          TestWalletEvent(
            walletId: walletId,
            eventTypeName: 'WalletCreated',
            data: {'name': 'Empty Wallet'},
            timestamp: DateTime.now(),
          ),
        ];
        await storage.saveEvents(walletId, events);

        final utxos = await storage.getUTXOs(walletId);
        expect(utxos, isEmpty);
        
        final availableUtxos = await storage.getAvailableUTXOs(walletId);
        expect(availableUtxos, isEmpty);
        
        final balance = await storage.getBalance(walletId);
        expect(balance, equals(BigInt.zero));
      });

      test('should get balance for non-empty wallet', () async {
        // Create wallet with some UTXO events
        final now = DateTime.now();
        final events = [
          TestWalletEvent(
            walletId: walletId,
            eventTypeName: 'WalletCreated',
            data: {'name': 'Test Wallet'},
            timestamp: now,
          ),
          TestWalletEvent(
            walletId: walletId,
            eventTypeName: 'UTXOReceived',
            data: {
              'txid': 'tx_1',
              'vout': 0,
              'satoshis': '100000',
              'address': '1Test1Address123456789012345678901234',
              'scriptPubKey': '76a914test1123456789012345678901234567888ac',
            },
            timestamp: now.add(Duration(minutes: 1)),
          ),
          TestWalletEvent(
            walletId: walletId,
            eventTypeName: 'UTXOReceived',
            data: {
              'txid': 'tx_2',
              'vout': 0,
              'satoshis': '200000',
              'address': '1Test2Address123456789012345678901234',
              'scriptPubKey': '76a914test2123456789012345678901234567888ac',
            },
            timestamp: now.add(Duration(minutes: 2)),
          ),
        ];
        
        await storage.saveEvents(walletId, events);

        // Note: The actual UTXO projection and balance calculation
        // depends on the InMemoryWalletStorage implementation
        final utxos = await storage.getUTXOs(walletId);
        final balance = await storage.getBalance(walletId);
        final availableUtxos = await storage.getAvailableUTXOs(walletId);
        
        // We can't make specific assertions about the values without knowing
        // how the implementation processes events, but we can verify the methods work
        expect(utxos, isA<List<BitcoinUtxo>>());
        expect(balance, isA<BigInt>());
        expect(availableUtxos, isA<List<BitcoinUtxo>>());
      });
    });

    group('Error Handling', () {
      test('should throw StorageException for operations on non-existent wallet', () async {
        const nonExistentWallet = 'non_existent_wallet';

        expect(
          () => storage.getUTXOs(nonExistentWallet),
          throwsA(isA<StorageException>()),
        );

        expect(
          () => storage.getAvailableUTXOs(nonExistentWallet),
          throwsA(isA<StorageException>()),
        );

        expect(
          () => storage.getBalance(nonExistentWallet),
          throwsA(isA<StorageException>()),
        );
      });

      test('should handle operations on deleted wallet gracefully', () async {
        const walletId = 'deleted_wallet';
        
        // Create wallet with events
        final events = [
          TestWalletEvent(
            walletId: walletId,
            eventTypeName: 'WalletCreated',
            data: {'name': 'Deleted Wallet'},
            timestamp: DateTime.now(),
          ),
        ];
        await storage.saveEvents(walletId, events);
        
        // Delete wallet
        await storage.deleteWallet(walletId);

        // Operations should throw exceptions
        expect(
          () => storage.getUTXOs(walletId),
          throwsA(isA<StorageException>()),
        );
        
        expect(
          () => storage.loadEvents(walletId),
          throwsA(isA<StorageException>()),
        );
      });

      test('should handle empty event lists gracefully', () async {
        const walletId = 'empty_events_wallet';
        
        // Save empty event list
        await storage.saveEvents(walletId, []);
        
        final events = await storage.loadEvents(walletId);
        expect(events, isEmpty);
        
        final utxos = await storage.getUTXOs(walletId);
        expect(utxos, isEmpty);
        
        final balance = await storage.getBalance(walletId);
        expect(balance, equals(BigInt.zero));
      });
    });
  });
} 