import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

import 'package:libspiffy/src/core/wallet_events.dart';
import 'package:libspiffy/src/models/wallet_event.dart';

void main() {
  group('Wallet Events Tests', () {
    group('Base WalletEvent', () {
      test('should create event with all required fields', () {
        const walletId = 'test_wallet_123';
        const eventId = 'event_123';
        final timestamp = DateTime.now();
        const version = 5;
        final metadata = {'key': 'value'};

        final event = TestWalletEvent(
          walletId: walletId,
          eventId: eventId,
          timestamp: timestamp,
          version: version,
          metadata: metadata,
        );

        expect(event.walletId, equals(walletId));
        expect(event.aggregateId, equals(walletId)); // walletId is same as aggregateId
        expect(event.aggregateType, equals('Wallet'));
        expect(event.eventId, equals(eventId));
        expect(event.timestamp, equals(timestamp));
        expect(event.version, equals(version));
        expect(event.metadata, equals(metadata));
      });

      test('should generate ID for eventId if not provided', () {
        final event = TestWalletEvent(walletId: 'test_wallet');
        expect(event.eventId, isNotNull);
        expect(event.eventId!.length, greaterThan(10)); // Should be some reasonable length
      });

      test('should use current time for timestamp if not provided', () {
        final before = DateTime.now();
        final event = TestWalletEvent(walletId: 'test_wallet');
        final after = DateTime.now();
        
        expect(event.timestamp, isNotNull);
        expect(event.timestamp!.isAfter(before.subtract(Duration(seconds: 1))), isTrue);
        expect(event.timestamp!.isBefore(after.add(Duration(seconds: 1))), isTrue);
      });

      test('should include wallet event data in getEventData', () {
        final event = TestWalletEvent(
          walletId: 'test_wallet',
          testData: 'test_value',
        );

        final eventData = event.getEventData();
        expect(eventData['walletId'], equals('test_wallet'));
        expect(eventData['testData'], equals('test_value'));
      });
    });

    group('WalletCreatedEvent', () {
      test('should create wallet created event with all fields', () {
        const walletId = 'new_wallet_123';
        const walletName = 'My New Wallet';
        const rootAddress = '1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2';
        final walletMetadata = {'network': 'mainnet', 'purpose': 'savings'};

        final event = WalletCreatedEvent(
          walletId: walletId,
          walletName: walletName,
          rootAddress: rootAddress,
          walletMetadata: walletMetadata,
        );

        expect(event.walletId, equals(walletId));
        expect(event.walletName, equals(walletName));
        expect(event.rootAddress, equals(rootAddress));
        expect(event.walletMetadata, equals(walletMetadata));
      });

      test('should serialize and deserialize correctly', () {
        final original = WalletCreatedEvent(
          walletId: 'wallet_123',
          walletName: 'Test Wallet',
          rootAddress: '1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2',
          walletMetadata: {'key': 'value'},
          eventId: 'event_123',
          timestamp: DateTime(2024, 1, 1, 12, 0, 0),
          version: 1,
          metadata: {'context': 'test'},
        );

        final eventData = original.getWalletEventData();
        expect(eventData['walletName'], equals('Test Wallet'));
        expect(eventData['rootAddress'], equals('1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2'));
        expect(eventData['walletMetadata'], equals({'key': 'value'}));

        final fullEventData = original.getEventData();
        expect(fullEventData['walletId'], equals('wallet_123'));
        expect(fullEventData['walletName'], equals('Test Wallet'));

        // Test fromMap deserialization
        final map = {
          'walletId': 'wallet_123',
          'walletName': 'Test Wallet',
          'rootAddress': '1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2',
          'walletMetadata': {'key': 'value'},
          'eventId': 'event_123',
          'timestamp': '2024-01-01T12:00:00.000',
          'version': 1,
          'metadata': {'context': 'test'},
        };

        final deserialized = WalletCreatedEvent.fromMap(map);
        expect(deserialized.walletId, equals(original.walletId));
        expect(deserialized.walletName, equals(original.walletName));
        expect(deserialized.rootAddress, equals(original.rootAddress));
        expect(deserialized.walletMetadata, equals(original.walletMetadata));
        expect(deserialized.eventId, equals(original.eventId));
        expect(deserialized.version, equals(original.version));
      });

      test('should handle null wallet metadata', () {
        final event = WalletCreatedEvent(
          walletId: 'wallet_123',
          walletName: 'Test Wallet',
          rootAddress: '1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2',
          walletMetadata: null,
        );

        expect(event.walletMetadata, isNull);

        final eventData = event.getWalletEventData();
        expect(eventData['walletMetadata'], isNull);
      });
    });

    group('WalletConfigurationUpdatedEvent', () {
      test('should create configuration update event', () {
        const walletId = 'wallet_123';
        const newName = 'Updated Wallet Name';
        final newMetadata = {'theme': 'dark', 'currency': 'USD'};

        final event = WalletConfigurationUpdatedEvent(
          walletId: walletId,
          newName: newName,
          newMetadata: newMetadata,
        );

        expect(event.walletId, equals(walletId));
        expect(event.newName, equals(newName));
        expect(event.newMetadata, equals(newMetadata));
      });

      test('should handle name-only update', () {
        final event = WalletConfigurationUpdatedEvent(
          walletId: 'wallet_123',
          newName: 'New Name Only',
          newMetadata: null,
        );

        expect(event.newName, equals('New Name Only'));
        expect(event.newMetadata, isNull);

        final eventData = event.getWalletEventData();
        expect(eventData['newName'], equals('New Name Only'));
        expect(eventData['newMetadata'], isNull);
      });

      test('should handle metadata-only update', () {
        final event = WalletConfigurationUpdatedEvent(
          walletId: 'wallet_123',
          newName: null,
          newMetadata: {'setting': 'value'},
        );

        expect(event.newName, isNull);
        expect(event.newMetadata, equals({'setting': 'value'}));
      });

      test('should serialize and deserialize correctly', () {
        final original = WalletConfigurationUpdatedEvent(
          walletId: 'wallet_123',
          newName: 'Updated Name',
          newMetadata: {'key': 'value'},
          eventId: 'event_123',
          timestamp: DateTime(2024, 1, 1, 12, 0, 0),
          version: 2,
        );

        final map = {
          'walletId': 'wallet_123',
          'newName': 'Updated Name',
          'newMetadata': {'key': 'value'},
          'eventId': 'event_123',
          'timestamp': '2024-01-01T12:00:00.000',
          'version': 2,
        };

        final deserialized = WalletConfigurationUpdatedEvent.fromMap(map);
        expect(deserialized.walletId, equals(original.walletId));
        expect(deserialized.newName, equals(original.newName));
        expect(deserialized.newMetadata, equals(original.newMetadata));
        expect(deserialized.eventId, equals(original.eventId));
        expect(deserialized.version, equals(original.version));
      });
    });

    group('AddressGeneratedEvent', () {
      test('should create address generated event', () {
        const walletId = 'wallet_123';
        const address = '1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2';
        const derivationIndex = 5;
        const label = 'Receiving Address';
        const purpose = 'receive';

        final event = AddressGeneratedEvent(
          walletId: walletId,
          address: address,
          derivationIndex: derivationIndex,
          label: label,
          purpose: purpose,
        );

        expect(event.walletId, equals(walletId));
        expect(event.address, equals(address));
        expect(event.derivationIndex, equals(derivationIndex));
        expect(event.label, equals(label));
        expect(event.purpose, equals(purpose));
      });

      test('should handle optional fields', () {
        const walletId = 'wallet_123';
        const address = '1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2';
        const derivationIndex = 0;

        final event = AddressGeneratedEvent(
          walletId: walletId,
          address: address,
          derivationIndex: derivationIndex,
        );

        expect(event.label, isNull);
        expect(event.purpose, isNull);
      });

      test('should include address data in event data', () {
        final event = AddressGeneratedEvent(
          walletId: 'wallet_123',
          address: '1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2',
          derivationIndex: 5,
          label: 'Test Address',
          purpose: 'receive',
        );

        final eventData = event.getWalletEventData();
        expect(eventData['address'], equals('1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2'));
        expect(eventData['derivationIndex'], equals(5));
        expect(eventData['label'], equals('Test Address'));
        expect(eventData['purpose'], equals('receive'));
      });
    });

    group('UTXOReceivedEvent', () {
      test('should create UTXO received event', () {
        const walletId = 'wallet_123';
        const txid = 'abc123def456';
        const vout = 0;
        const satoshis = 100000;
        const address = '1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2';
        const scriptPubKey = '76a914abcd1234...88ac';
        const blockHeight = 750000;
        const confirmations = 6;

        final event = UTXOReceivedEvent(
          walletId: walletId,
          txid: txid,
          vout: vout,
          satoshis: satoshis,
          address: address,
          scriptPubKey: scriptPubKey,
          blockHeight: blockHeight,
          confirmations: confirmations,
        );

        expect(event.walletId, equals(walletId));
        expect(event.txid, equals(txid));
        expect(event.vout, equals(vout));
        expect(event.satoshis, equals(satoshis));
        expect(event.address, equals(address));
        expect(event.scriptPubKey, equals(scriptPubKey));
        expect(event.blockHeight, equals(blockHeight));
        expect(event.confirmations, equals(confirmations));
      });

      test('should include UTXO data in event data', () {
        final event = UTXOReceivedEvent(
          walletId: 'wallet_123',
          txid: 'abc123def456',
          vout: 0,
          satoshis: 100000,
          address: '1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2',
          scriptPubKey: '76a914abcd1234...88ac',
        );

        final eventData = event.getWalletEventData();
        expect(eventData['txid'], equals('abc123def456'));
        expect(eventData['vout'], equals(0));
        expect(eventData['satoshis'], equals(100000));
        expect(eventData['address'], equals('1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2'));
        expect(eventData['scriptPubKey'], equals('76a914abcd1234...88ac'));
      });
    });

    group('TransactionCreatedEvent', () {
      test('should create transaction created event', () {
        const walletId = 'wallet_123';
        const txid = 'transaction_123';
        const rawHex = '0100000001abc123...';
        const totalInput = 100000;
        const totalOutput = 90000;
        const fee = 10000;
        const isIncoming = false;
        const isOutgoing = true;
        final transactionMetadata = {'type': 'payment', 'memo': 'Test transaction'};

        final event = TransactionCreatedEvent(
          walletId: walletId,
          txid: txid,
          rawHex: rawHex,
          totalInput: totalInput,
          totalOutput: totalOutput,
          fee: fee,
          isIncoming: isIncoming,
          isOutgoing: isOutgoing,
          transactionMetadata: transactionMetadata,
        );

        expect(event.walletId, equals(walletId));
        expect(event.txid, equals(txid));
        expect(event.rawHex, equals(rawHex));
        expect(event.totalInput, equals(totalInput));
        expect(event.totalOutput, equals(totalOutput));
        expect(event.fee, equals(fee));
        expect(event.isIncoming, equals(isIncoming));
        expect(event.isOutgoing, equals(isOutgoing));
        expect(event.transactionMetadata, equals(transactionMetadata));
      });

      test('should include transaction data in event data', () {
        final event = TransactionCreatedEvent(
          walletId: 'wallet_123',
          txid: 'transaction_123',
          rawHex: '0100000001abc123...',
          totalInput: 100000,
          totalOutput: 90000,
          fee: 10000,
          isIncoming: false,
          isOutgoing: true,
        );

        final eventData = event.getWalletEventData();
        expect(eventData['txid'], equals('transaction_123'));
        expect(eventData['rawHex'], equals('0100000001abc123...'));
        expect(eventData['totalInput'], equals(100000));
        expect(eventData['totalOutput'], equals(90000));
        expect(eventData['fee'], equals(10000));
        expect(eventData['isIncoming'], equals(false));
        expect(eventData['isOutgoing'], equals(true));
      });
    });

    group('Event Inheritance and Polymorphism', () {
      test('should work with WalletEvent base type', () {
        final events = <WalletEvent>[
          WalletCreatedEvent(
            walletId: 'wallet_1',
            walletName: 'Wallet 1',
            rootAddress: '1Address1',
          ),
          WalletConfigurationUpdatedEvent(
            walletId: 'wallet_1',
            newName: 'Updated Name',
          ),
          AddressGeneratedEvent(
            walletId: 'wallet_1',
            address: '1NewAddress',
            derivationIndex: 1,
          ),
        ];

        expect(events.length, equals(3));
        expect(events[0], isA<WalletCreatedEvent>());
        expect(events[1], isA<WalletConfigurationUpdatedEvent>());
        expect(events[2], isA<AddressGeneratedEvent>());

        // All should have the same walletId
        for (final event in events) {
          expect(event.walletId, equals('wallet_1'));
          expect(event.aggregateId, equals('wallet_1'));
          expect(event.aggregateType, equals('Wallet'));
        }
      });

      test('should maintain event type information', () {
        final walletCreated = WalletCreatedEvent(
          walletId: 'wallet_1',
          walletName: 'Test Wallet',
          rootAddress: '1Address1',
        );

        final configUpdated = WalletConfigurationUpdatedEvent(
          walletId: 'wallet_1',
          newName: 'Updated Name',
        );

        expect(walletCreated.runtimeType, equals(WalletCreatedEvent));
        expect(configUpdated.runtimeType, equals(WalletConfigurationUpdatedEvent));
        expect(walletCreated is WalletEvent, isTrue);
        expect(configUpdated is WalletEvent, isTrue);
      });
    });

    group('Edge Cases and Error Conditions', () {
      test('should handle empty strings and zero values', () {
        final event = TransactionCreatedEvent(
          walletId: '',
          txid: '',
          rawHex: '',
          totalInput: 0,
          totalOutput: 0,
          fee: 0,
          isIncoming: false,
          isOutgoing: false,
        );

        expect(event.walletId, isEmpty);
        expect(event.txid, isEmpty);
        expect(event.rawHex, isEmpty);
        expect(event.totalInput, equals(0));
        expect(event.totalOutput, equals(0));
        expect(event.fee, equals(0));
        expect(event.isIncoming, isFalse);
        expect(event.isOutgoing, isFalse);
      });

      test('should handle very large amounts', () {
        const largeAmount = 2100000000000000; // 21M BTC in satoshis (int max safe range)
        final event = UTXOReceivedEvent(
          walletId: 'wallet_123',
          txid: 'large_tx',
          vout: 0,
          satoshis: largeAmount,
          address: '1Address',
          scriptPubKey: 'script',
        );

        expect(event.satoshis, equals(largeAmount));

        final eventData = event.getWalletEventData();
        expect(eventData['satoshis'], equals(largeAmount));
      });

      test('should handle long derivation indices', () {
        const largeIndex = 2147483647; // Max 32-bit signed int
        final event = AddressGeneratedEvent(
          walletId: 'wallet_123',
          address: '1Address',
          derivationIndex: largeIndex,
        );

        expect(event.derivationIndex, equals(largeIndex));
      });

      test('should handle DateTime serialization edge cases', () {
        final veryOld = DateTime(2009, 1, 3); // Bitcoin genesis block
        final future = DateTime(2030, 1, 1);

        final event1 = WalletCreatedEvent(
          walletId: 'wallet_old',
          walletName: 'Old Wallet',
          rootAddress: '1Address',
          timestamp: veryOld,
        );

        final event2 = WalletCreatedEvent(
          walletId: 'wallet_future',
          walletName: 'Future Wallet',
          rootAddress: '1Address',
          timestamp: future,
        );

        expect(event1.timestamp, equals(veryOld));
        expect(event2.timestamp, equals(future));
      });
    });

    group('UTXO Reservation Events', () {
      group('UTXOReservedEvent', () {
        test('should create UTXOReservedEvent with all required fields', () {
          final expiresAt = DateTime.now().add(Duration(minutes: 30));
          final event = UTXOReservedEvent(
            walletId: 'wallet_123',
            txid: 'test_txid',
            vout: 0,
            reservedByTxId: 'reserve_tx_123',
            expiresAt: expiresAt,
          );

          expect(event.walletId, equals('wallet_123'));
          expect(event.txid, equals('test_txid'));
          expect(event.vout, equals(0));
          expect(event.reservedByTxId, equals('reserve_tx_123'));
          expect(event.expiresAt, equals(expiresAt));
          expect(event.priority, equals(0)); // Default priority
          expect(event.reservationReason, isNull);
        });

        test('should create UTXOReservedEvent with all fields', () {
          final expiresAt = DateTime.now().add(Duration(hours: 1));
          final event = UTXOReservedEvent(
            walletId: 'wallet_456',
            txid: 'test_txid_2',
            vout: 1,
            reservedByTxId: 'reserve_tx_456',
            reservationReason: 'High priority transaction',
            expiresAt: expiresAt,
            priority: 5,
            version: 10,
          );

          expect(event.reservationReason, equals('High priority transaction'));
          expect(event.priority, equals(5));
          expect(event.version, equals(10));
        });

        test('should serialize and deserialize correctly', () {
          final expiresAt = DateTime.now().add(Duration(minutes: 45));
          final originalEvent = UTXOReservedEvent(
            walletId: 'wallet_serialize',
            txid: 'serialize_txid',
            vout: 2,
            reservedByTxId: 'reserve_serialize',
            reservationReason: 'Serialization test',
            expiresAt: expiresAt,
            priority: 3,
            version: 5,
          );

          final eventData = originalEvent.getWalletEventData();
          expect(eventData['txid'], equals('serialize_txid'));
          expect(eventData['vout'], equals(2));
          expect(eventData['reservedByTxId'], equals('reserve_serialize'));
          expect(eventData['reservationReason'], equals('Serialization test'));
          expect(eventData['expiresAt'], equals(expiresAt.toIso8601String()));
          expect(eventData['priority'], equals(3));

          final deserializedEvent = UTXOReservedEvent.fromMap({
            'walletId': 'wallet_serialize',
            'txid': 'serialize_txid',
            'vout': 2,
            'reservedByTxId': 'reserve_serialize',
            'reservationReason': 'Serialization test',
            'expiresAt': expiresAt.toIso8601String(),
            'priority': 3,
            'version': 5,
          });

          expect(deserializedEvent.walletId, equals(originalEvent.walletId));
          expect(deserializedEvent.txid, equals(originalEvent.txid));
          expect(deserializedEvent.vout, equals(originalEvent.vout));
          expect(deserializedEvent.reservedByTxId, equals(originalEvent.reservedByTxId));
          expect(deserializedEvent.reservationReason, equals(originalEvent.reservationReason));
          expect(deserializedEvent.expiresAt, equals(originalEvent.expiresAt));
          expect(deserializedEvent.priority, equals(originalEvent.priority));
        });
      });

      group('UTXOReleasedEvent', () {
        test('should create UTXOReleasedEvent with required fields', () {
          final event = UTXOReleasedEvent(
            walletId: 'wallet_release',
            txid: 'release_txid',
            vout: 0,
          );

          expect(event.walletId, equals('wallet_release'));
          expect(event.txid, equals('release_txid'));
          expect(event.vout, equals(0));
          expect(event.releaseReason, isNull);
          expect(event.wasExpired, isFalse); // Default
        });

        test('should create UTXOReleasedEvent with all fields', () {
          final event = UTXOReleasedEvent(
            walletId: 'wallet_release_complete',
            txid: 'release_txid_complete',
            vout: 1,
            releaseReason: 'Transaction cancelled',
            wasExpired: true,
            version: 7,
          );

          expect(event.releaseReason, equals('Transaction cancelled'));
          expect(event.wasExpired, isTrue);
          expect(event.version, equals(7));
        });

        test('should serialize and deserialize correctly', () {
          final originalEvent = UTXOReleasedEvent(
            walletId: 'wallet_release_serialize',
            txid: 'release_serialize_txid',
            vout: 2,
            releaseReason: 'Manual release',
            wasExpired: false,
            version: 3,
          );

          final eventData = originalEvent.getWalletEventData();
          expect(eventData['txid'], equals('release_serialize_txid'));
          expect(eventData['vout'], equals(2));
          expect(eventData['releaseReason'], equals('Manual release'));
          expect(eventData['wasExpired'], isFalse);

          final deserializedEvent = UTXOReleasedEvent.fromMap({
            'walletId': 'wallet_release_serialize',
            'txid': 'release_serialize_txid',
            'vout': 2,
            'releaseReason': 'Manual release',
            'wasExpired': false,
            'version': 3,
          });

          expect(deserializedEvent.walletId, equals(originalEvent.walletId));
          expect(deserializedEvent.txid, equals(originalEvent.txid));
          expect(deserializedEvent.vout, equals(originalEvent.vout));
          expect(deserializedEvent.releaseReason, equals(originalEvent.releaseReason));
          expect(deserializedEvent.wasExpired, equals(originalEvent.wasExpired));
        });
      });

      group('UTXOReservationRenewedEvent', () {
        test('should create UTXOReservationRenewedEvent with required fields', () {
          final oldExpiry = DateTime.now().add(Duration(minutes: 15));
          final newExpiry = DateTime.now().add(Duration(minutes: 30));
          
          final event = UTXOReservationRenewedEvent(
            walletId: 'wallet_renewal',
            txid: 'renewal_txid',
            vout: 0,
            newExpiresAt: newExpiry,
            oldExpiresAt: oldExpiry,
          );

          expect(event.walletId, equals('wallet_renewal'));
          expect(event.txid, equals('renewal_txid'));
          expect(event.vout, equals(0));
          expect(event.newExpiresAt, equals(newExpiry));
          expect(event.oldExpiresAt, equals(oldExpiry));
          expect(event.renewalReason, isNull);
        });

        test('should create UTXOReservationRenewedEvent with reason', () {
          final oldExpiry = DateTime.now().add(Duration(minutes: 10));
          final newExpiry = DateTime.now().add(Duration(hours: 1));
          
          final event = UTXOReservationRenewedEvent(
            walletId: 'wallet_renewal_reason',
            txid: 'renewal_reason_txid',
            vout: 1,
            newExpiresAt: newExpiry,
            oldExpiresAt: oldExpiry,
            renewalReason: 'Need more time for complex signing',
            version: 8,
          );

          expect(event.renewalReason, equals('Need more time for complex signing'));
          expect(event.version, equals(8));
        });

        test('should serialize and deserialize correctly', () {
          final oldExpiry = DateTime.now().add(Duration(minutes: 20));
          final newExpiry = DateTime.now().add(Duration(minutes: 50));
          
          final originalEvent = UTXOReservationRenewedEvent(
            walletId: 'wallet_renewal_serialize',
            txid: 'renewal_serialize_txid',
            vout: 2,
            newExpiresAt: newExpiry,
            oldExpiresAt: oldExpiry,
            renewalReason: 'Serialization renewal test',
            version: 12,
          );

          final eventData = originalEvent.getWalletEventData();
          expect(eventData['txid'], equals('renewal_serialize_txid'));
          expect(eventData['vout'], equals(2));
          expect(eventData['newExpiresAt'], equals(newExpiry.toIso8601String()));
          expect(eventData['oldExpiresAt'], equals(oldExpiry.toIso8601String()));
          expect(eventData['renewalReason'], equals('Serialization renewal test'));

          final deserializedEvent = UTXOReservationRenewedEvent.fromMap({
            'walletId': 'wallet_renewal_serialize',
            'txid': 'renewal_serialize_txid',
            'vout': 2,
            'newExpiresAt': newExpiry.toIso8601String(),
            'oldExpiresAt': oldExpiry.toIso8601String(),
            'renewalReason': 'Serialization renewal test',
            'version': 12,
          });

          expect(deserializedEvent.walletId, equals(originalEvent.walletId));
          expect(deserializedEvent.txid, equals(originalEvent.txid));
          expect(deserializedEvent.vout, equals(originalEvent.vout));
          expect(deserializedEvent.newExpiresAt, equals(originalEvent.newExpiresAt));
          expect(deserializedEvent.oldExpiresAt, equals(originalEvent.oldExpiresAt));
          expect(deserializedEvent.renewalReason, equals(originalEvent.renewalReason));
        });
      });

      group('Event Generation', () {
        test('should generate unique event IDs', () {
          final expiresAt = DateTime.now().add(Duration(minutes: 30));
          
          final event1 = UTXOReservedEvent(
            walletId: 'wallet_unique',
            txid: 'unique_txid_1',
            vout: 0,
            reservedByTxId: 'reserve_tx_1',
            expiresAt: expiresAt,
          );

          final event2 = UTXOReservedEvent(
            walletId: 'wallet_unique',
            txid: 'unique_txid_2',
            vout: 1,
            reservedByTxId: 'reserve_tx_2',
            expiresAt: expiresAt,
          );

          expect(event1.eventId, isNotNull);
          expect(event2.eventId, isNotNull);
          expect(event1.eventId, isNot(equals(event2.eventId)));
        });

        test('should generate timestamps for events', () {
          final before = DateTime.now();
          
          final event = UTXOReleasedEvent(
            walletId: 'wallet_timestamp',
            txid: 'timestamp_txid',
            vout: 0,
          );
          
          final after = DateTime.now();

          expect(event.timestamp, isNotNull);
          expect(event.timestamp!.isAfter(before.subtract(Duration(seconds: 1))), isTrue);
          expect(event.timestamp!.isBefore(after.add(Duration(seconds: 1))), isTrue);
        });
      });
    });
  });
}

/// Test implementation of WalletEvent for testing base functionality
class TestWalletEvent extends WalletEvent {
  final String? testData;

  TestWalletEvent({
    required String walletId,
    this.testData,
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
      if (testData != null) 'testData': testData,
    };
  }
} 