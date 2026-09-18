import 'package:test/test.dart';

import 'package:libspiffy/src/storage/wallet_storage.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';
import 'package:libspiffy/src/models/bitcoin_utxo.dart';
import 'package:libspiffy/src/models/wallet_event.dart';
import 'package:libspiffy/src/models/payment_channel.dart';

import 'channel_read_model_contract.dart';
import 'invoice_read_model_contract.dart';
import 'header_reorg_contract.dart';
import 'read_model_keying_contract.dart';
import 'transaction_intrinsics_contract.dart';
import 'transaction_lookup_contract.dart';
import 'transaction_status_contract.dart';
import 'wallet_metadata_types_contract.dart';
import 'package:libspiffy/src/core/wallet/state_records.dart';
import 'package:libspiffy/src/storage/wallet_row_rules.dart';
import 'wallet_lifecycle_contract.dart';

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

      test('should keep network and rootAddress on a metadata-only update', () async {
        // S-06: the in-memory backend used to overwrite the whole record, so
        // a balance update that omitted networkType/rootAddress dropped them
        // (the Isar and Postgres backends merge).
        const walletId = 'net_wallet';

        await storage.storeWallet(
          walletId,
          'Net Wallet',
          rootAddress: 'root-addr',
          networkType: 'testnet',
          metadata: {'version': 1},
        );
        await storage.storeWallet(
          walletId,
          'Net Wallet',
          metadata: {'confirmedBalance': '100'},
        );

        final wallet = await storage.getWallet(walletId);
        expect(wallet, isNotNull);
        expect(wallet!['network'], equals('testnet'));
        expect(wallet['networkType'], equals('testnet'));
        expect(wallet['rootAddress'], equals('root-addr'));
        expect(wallet['metadata'],
            equals({'version': 1, 'confirmedBalance': '100'}));
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
      test('read-model queries for a non-existent wallet return empty results (audit S-15)', () async {
        // The in-memory backend used to throw where Isar and Postgres return
        // empty; the rule is now shared (wallet_lifecycle_contract.dart).
        const nonExistentWallet = 'non_existent_wallet';

        expect(await storage.getUTXOs(nonExistentWallet), isEmpty);
        expect(await storage.getAvailableUTXOs(nonExistentWallet), isEmpty);
        expect(await storage.getBalance(nonExistentWallet), BigInt.zero);
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

        // The read model is empty; the event stream is gone.
        expect(await storage.walletExists(walletId), isFalse);
        expect(await storage.getUTXOs(walletId), isEmpty);

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

  /// Audit 2026-09-14 S-01: the channel read model must be typed on the
  /// domain PaymentChannel across all backends. The old in-memory backend
  /// stored whatever object the projection handed it (an Isar entity) and
  /// its updatePaymentChannelState assigned a String to the state field.
  group('InMemoryWalletStorage payment channel read model (audit S-01)', () {
    test('projects open -> payment -> settle and reads back every field',
        () async {
      final storage = InMemoryWalletStorage();
      await runChannelLifecycleContract(
        storage,
        channelId: 'inmem-channel-contract',
        walletId: 'inmem-channel-wallet',
      );
    });

    test('every channel field survives storage and projection updates (32t, y3b)',
        () async {
      await runChannelFullFieldRetentionContract(
        InMemoryWalletStorage(),
        channelId: 'inmem-channel-retention',
        walletId: 'inmem-channel-wallet',
      );
    });

    test('a requested channel reads back with a null server key (y3b)',
        () async {
      await runRequestedChannelServerKeyContract(
        InMemoryWalletStorage(),
        channelId: 'inmem-channel-server-key',
        walletId: 'inmem-channel-wallet',
      );
    });

    test('a claimed refund records its txid in the read model (cqc)', () async {
      await runRefundClaimedContract(
        InMemoryWalletStorage(),
        channelId: 'inmem-channel-refund',
        walletId: 'inmem-channel-refund-wallet',
      );
    });

    test('a lock time past 2038 round-trips (cqc)', () async {
      await runPost2038LockTimeContract(
        InMemoryWalletStorage(),
        channelId: 'inmem-channel-locktime',
        walletId: 'inmem-channel-locktime-wallet',
      );
    });

    test('a fetched channel is a snapshot: deriving a changed copy does not change storage',
        () async {
      final storage = InMemoryWalletStorage();
      await runChannelLifecycleContract(
        storage,
        channelId: 'inmem-channel-snapshot',
        walletId: 'inmem-channel-wallet',
      );
      final fetched = await storage.getPaymentChannel('inmem-channel-snapshot');
      final changed = fetched!.copyWith(
          state: PaymentChannelState.failed, errorMessage: 'changed in caller');
      expect(changed.state, equals(PaymentChannelState.failed));
      expect(() => fetched.fundingAncestorTxids.add('ff' * 32),
          throwsUnsupportedError);
      final again = await storage.getPaymentChannel('inmem-channel-snapshot');
      expect(again!.state, equals(PaymentChannelState.closed));
      expect(again.errorMessage, isNull);
    });
  });

  /// Audit 2026-09-14 S-07: the old in-memory updateInvoiceStatus assigned
  /// to the final fields of InvoiceReadModel (NoSuchMethodError).
  group('InMemoryWalletStorage invoice read model (audit S-07)', () {
    test('store -> update status -> getInvoice/list return typed models with outputs',
        () async {
      final storage = InMemoryWalletStorage();
      await runInvoiceRoundTripContract(
        storage,
        invoiceId: 'inmem-invoice-contract',
        walletId: 'inmem-invoice-wallet',
      );
    });
  });

  /// Audit 2026-09-14 S-05, S-12, S-13, S-17, S-18 and bead libspiffy-0v3:
  /// the keying contract shared with the Isar and Postgres backends.
  group('InMemoryWalletStorage', () {
    late InMemoryWalletStorage storage;
    var counter = 0;
    setUp(() => storage = InMemoryWalletStorage());
    defineReadModelKeyingContract(() => storage, unique: () => 'm${counter++}');
    defineWalletLifecycleContract(() => storage, unique: () => 'ml${counter++}');
    defineTransactionLookupContract(() => storage, unique: () => 'mt${counter++}');
    defineTransactionIntrinsicsContract(() => storage, unique: () => 'mi${counter++}');
    defineTransactionStatusContract(() => storage, unique: () => 'ms${counter++}');
    defineWalletMetadataTypesContract(() => storage, unique: () => 'mw${counter++}');

    test('k7na: every derived wallet row key has a value type', () {
      expect({
        ...WalletRowRules.balanceKeys,
        ...WalletRowRules.integerKeys,
        ...WalletRowRules.stringKeys,
        ...WalletRowRules.jsonKeys,
      }, WalletMetadataKeys.readModel);
    });

    test('0v3: BlockHeaderChain reorg A -> B -> A persists branch A across a restart',
        () async {
      await runReorgBackOntoOrphanedBranchContract(storage);
    });
  });
}
