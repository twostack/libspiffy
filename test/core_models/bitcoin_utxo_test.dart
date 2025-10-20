import 'package:test/test.dart';
import 'package:dartsv/dartsv.dart' as dartsv;

import 'package:libspiffy/src/models/bitcoin_utxo.dart';

void main() {
  group('BitcoinUtxo Tests', () {
    group('UTXO Creation and Basic Properties', () {
      test('should create UTXO with required fields', () {
        final now = DateTime.now();
        final coin = dartsv.Coin.ofSat(BigInt.from(100000));
        final utxo = BitcoinUtxo(
          txid: 'abc123',
          vout: 0,
          value: coin,
          address: '1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2',
          scriptPubKey: '76a914abcd1234efgh5678ijkl9012mnop3456qrst88ac',
          status: UTXOStatus.available,
          createdAt: now,
          updatedAt: now,
        );

        expect(utxo.txid, equals('abc123'));
        expect(utxo.vout, equals(0));
        expect(utxo.value.getValue(), equals(BigInt.from(100000)));
        expect(utxo.satoshis, equals(BigInt.from(100000)));
        expect(utxo.address, equals('1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2'));
        expect(utxo.scriptPubKey, equals('76a914abcd1234efgh5678ijkl9012mnop3456qrst88ac'));
        expect(utxo.status, equals(UTXOStatus.available));
        expect(utxo.isAvailable, isTrue);
        expect(utxo.isConfirmed, isFalse);
        expect(utxo.key, equals('abc123:0'));
        expect(utxo.blockHeight, isNull);
        expect(utxo.confirmations, isNull);
      });

      test('should create UTXO with all optional fields', () {
        final now = DateTime.now();
        final coin = dartsv.Coin.ofSat(BigInt.from(50000));
        
        final utxo = BitcoinUtxo(
          txid: 'def456',
          vout: 1,
          value: coin,
          address: '1ABC123def456GHI789jkl012MNO345pqr678',
          scriptPubKey: '76a914xyz789abc123def456ghi789jkl012mno345pqr88ac',
          status: UTXOStatus.reserved,
          blockHeight: 750000,
          confirmations: 6,
          createdAt: now,
          updatedAt: now,
          reservedByTxId: 'reserve_tx_123',
          derivationIndex: 5,
        );

        expect(utxo.status, equals(UTXOStatus.reserved));
        expect(utxo.blockHeight, equals(750000));
        expect(utxo.confirmations, equals(6));
        expect(utxo.reservedByTxId, equals('reserve_tx_123'));
        expect(utxo.derivationIndex, equals(5));
        expect(utxo.isReserved, isTrue);
        expect(utxo.isConfirmed, isTrue);
        expect(utxo.key, equals('def456:1'));
      });

      test('should create UTXO using factory method', () {
        final utxo = BitcoinUtxo.create(
          txid: 'factory_test',
          vout: 2,
          satoshis: BigInt.from(75000),
          scriptPubKey: '76a914factory123456789012345678901234567888ac',
          address: '1FactoryTest123456789012345678901234',
          blockHeight: 750001,
          confirmations: 3,
          derivationIndex: 10,
        );

        expect(utxo.txid, equals('factory_test'));
        expect(utxo.vout, equals(2));
        expect(utxo.satoshis, equals(BigInt.from(75000)));
        expect(utxo.status, equals(UTXOStatus.available));
        expect(utxo.blockHeight, equals(750001));
        expect(utxo.confirmations, equals(3));
        expect(utxo.derivationIndex, equals(10));
        expect(utxo.isConfirmed, isTrue);
        expect(utxo.isAvailable, isTrue);
      });
    });

    group('UTXO Status Management', () {
      late BitcoinUtxo utxo;

      setUp(() {
        final now = DateTime.now();
        final coin = dartsv.Coin.ofSat(BigInt.from(100000));
        utxo = BitcoinUtxo(
          txid: 'status_test',
          vout: 0,
          value: coin,
          address: '1StatusTest123456789012345678901234',
          scriptPubKey: '76a914status123456789012345678901234567888ac',
          status: UTXOStatus.available,
          createdAt: now,
          updatedAt: now,
        );
      });

      test('should start with available status', () {
        expect(utxo.status, equals(UTXOStatus.available));
        expect(utxo.isAvailable, isTrue);
        expect(utxo.isReserved, isFalse);
        expect(utxo.isSpent, isFalse);
      });

      test('should update status correctly', () {
        final reserved = utxo.copyWith(status: UTXOStatus.reserved);
        expect(reserved.status, equals(UTXOStatus.reserved));
        expect(reserved.isReserved, isTrue);
        expect(reserved.isAvailable, isFalse);
        expect(reserved.txid, equals(utxo.txid)); // Other fields unchanged

        final spent = reserved.copyWith(status: UTXOStatus.spent);
        expect(spent.status, equals(UTXOStatus.spent));
        expect(spent.isSpent, isTrue);
        expect(spent.isReserved, isFalse);
      });

      test('should handle all UTXO status types', () {
        final statuses = [
          UTXOStatus.available,
          UTXOStatus.reserved,
          UTXOStatus.spent,
        ];

        for (final status in statuses) {
          final updated = utxo.copyWith(status: status);
          expect(updated.status, equals(status));
        }
      });
    });

    group('UTXO State Methods', () {
      late BitcoinUtxo utxo;

      setUp(() {
        final now = DateTime.now();
        final coin = dartsv.Coin.ofSat(BigInt.from(100000));
        utxo = BitcoinUtxo(
          txid: 'state_test',
          vout: 0,
          value: coin,
          address: '1StateTest123456789012345678901234',
          scriptPubKey: '76a914state123456789012345678901234567888ac',
          status: UTXOStatus.available,
          createdAt: now,
          updatedAt: now,
        );
      });

      test('should reserve UTXO correctly', () {
        final reserved = utxo.reserve('tx_123');
        
        expect(reserved.status, equals(UTXOStatus.reserved));
        expect(reserved.reservedByTxId, equals('tx_123'));
        expect(reserved.isReserved, isTrue);
        expect(reserved.isAvailable, isFalse);
        expect(reserved.updatedAt.isAfter(utxo.updatedAt), isTrue);
      });

      test('should mark UTXO as spent correctly', () {
        final spent = utxo.markSpent();
        
        expect(spent.status, equals(UTXOStatus.spent));
        expect(spent.isSpent, isTrue);
        expect(spent.isAvailable, isFalse);
        expect(spent.updatedAt.isAfter(utxo.updatedAt), isTrue);
      });

      test('should release reservation correctly', () {
        final reserved = utxo.reserve('tx_456');
        final released = reserved.releaseReservation();
        
        expect(released.status, equals(UTXOStatus.available));
        expect(released.reservedByTxId, isNull);
        expect(released.isAvailable, isTrue);
        expect(released.isReserved, isFalse);
        expect(released.updatedAt.isAfter(reserved.updatedAt), isTrue);
      });

      test('should update confirmations correctly', () {
        final updated = utxo.updateConfirmations(
          blockHeight: 750123,
          confirmations: 5,
        );
        
        expect(updated.blockHeight, equals(750123));
        expect(updated.confirmations, equals(5));
        expect(updated.isConfirmed, isTrue);
        expect(updated.updatedAt.isAfter(utxo.updatedAt), isTrue);
      });
    });

    group('DartSV Coin Integration', () {
      test('should handle various satoshi amounts correctly', () {
        final testAmounts = [
          BigInt.from(546),      // Dust limit
          BigInt.from(1000),     // Small amount
          BigInt.from(100000),   // 0.001 BSV
          BigInt.from(10000000), // 0.1 BSV
          BigInt.from(100000000), // 1 BSV
        ];

        for (final amount in testAmounts) {
          final utxo = BitcoinUtxo.create(
            txid: 'amount_test_${amount}',
            vout: 0,
            satoshis: amount,
            address: '1AmountTest123456789012345678901234',
            scriptPubKey: '76a914amount123456789012345678901234567888ac',
          );

          expect(utxo.value.getValue(), equals(amount));
          expect(utxo.satoshis, equals(amount));
        }
      });

      test('should handle zero and maximum values', () {
        // Zero value (valid for OP_RETURN outputs)
        final zeroUtxo = BitcoinUtxo.create(
          txid: 'zero_test',
          vout: 0,
          satoshis: BigInt.zero,
          address: '',
          scriptPubKey: '6a04deadbeef', // OP_RETURN
        );
        expect(zeroUtxo.value.getValue(), equals(BigInt.zero));
        expect(zeroUtxo.satoshis, equals(BigInt.zero));

        // Large value
        final largeAmount = BigInt.from(2100000000000000); // ~21M BSV
        final largeUtxo = BitcoinUtxo.create(
          txid: 'large_test',
          vout: 0,
          satoshis: largeAmount,
          address: '1LargeTest123456789012345678901234',
          scriptPubKey: '76a914large1234567890123456789012345678888ac',
        );
        expect(largeUtxo.value.getValue(), equals(largeAmount));
        expect(largeUtxo.satoshis, equals(largeAmount));
      });
    });

    group('UTXO Confirmation Status', () {
      test('should correctly identify unconfirmed UTXOs', () {
        final now = DateTime.now();
        final coin = dartsv.Coin.ofSat(BigInt.from(100000));
        final utxo = BitcoinUtxo(
          txid: 'unconfirmed_test',
          vout: 0,
          value: coin,
          address: '1UnconfirmedTest123456789012345678901234',
          scriptPubKey: '76a914unconfirmed123456789012345678901234567888ac',
          status: UTXOStatus.available,
          createdAt: now,
          updatedAt: now,
          // No blockHeight or confirmations
        );

        expect(utxo.isConfirmed, isFalse);
        expect(utxo.blockHeight, isNull);
        expect(utxo.confirmations, isNull);
      });

      test('should correctly identify confirmed UTXOs', () {
        final now = DateTime.now();
        final coin = dartsv.Coin.ofSat(BigInt.from(100000));
        final utxo = BitcoinUtxo(
          txid: 'confirmed_test',
          vout: 0,
          value: coin,
          address: '1ConfirmedTest123456789012345678901234',
          scriptPubKey: '76a914confirmed123456789012345678901234567888ac',
          status: UTXOStatus.available,
          blockHeight: 750456,
          confirmations: 3,
          createdAt: now,
          updatedAt: now,
        );

        expect(utxo.isConfirmed, isTrue);
        expect(utxo.blockHeight, equals(750456));
        expect(utxo.confirmations, equals(3));
      });

      test('should handle edge case of zero confirmations with block height', () {
        final now = DateTime.now();
        final coin = dartsv.Coin.ofSat(BigInt.from(100000));
        final utxo = BitcoinUtxo(
          txid: 'edge_case_test',
          vout: 0,
          value: coin,
          address: '1EdgeCaseTest123456789012345678901234',
          scriptPubKey: '76a914edgecase123456789012345678901234567888ac',
          status: UTXOStatus.available,
          blockHeight: 750789,
          confirmations: 0, // Zero confirmations but has block height
          createdAt: now,
          updatedAt: now,
        );

        expect(utxo.isConfirmed, isFalse); // Zero confirmations = not confirmed
        expect(utxo.blockHeight, equals(750789));
        expect(utxo.confirmations, equals(0));
      });
    });

    group('UTXO Equality and Hashing', () {
      test('should correctly compare UTXOs for equality', () {
        final now = DateTime.now();
        final coin1 = dartsv.Coin.ofSat(BigInt.from(100000));
        final coin2 = dartsv.Coin.ofSat(BigInt.from(100000));
        
        final utxo1 = BitcoinUtxo(
          txid: 'equality_test',
          vout: 0,
          value: coin1,
          address: '1EqualityTest123456789012345678901234',
          scriptPubKey: '76a914equality123456789012345678901234567888ac',
          status: UTXOStatus.available,
          createdAt: now,
          updatedAt: now,
        );

        final utxo2 = BitcoinUtxo(
          txid: 'equality_test',
          vout: 0,
          value: coin2,
          address: '1EqualityTest123456789012345678901234',
          scriptPubKey: '76a914equality123456789012345678901234567888ac',
          status: UTXOStatus.available,
          createdAt: now,
          updatedAt: now,
        );

        final utxo3 = BitcoinUtxo(
          txid: 'equality_test',
          vout: 1, // Different vout
          value: coin1,
          address: '1EqualityTest123456789012345678901234',
          scriptPubKey: '76a914equality123456789012345678901234567888ac',
          status: UTXOStatus.available,
          createdAt: now,
          updatedAt: now,
        );

        expect(utxo1, equals(utxo2));
        expect(utxo1, isNot(equals(utxo3)));
        expect(utxo1.hashCode, equals(utxo2.hashCode));
        expect(utxo1.key, equals(utxo2.key));
        expect(utxo1.key, isNot(equals(utxo3.key)));
      });

      test('should generate consistent string representation', () {
        final now = DateTime.now();
        final coin = dartsv.Coin.ofSat(BigInt.from(123456));
        final utxo = BitcoinUtxo(
          txid: 'string_test',
          vout: 2,
          value: coin,
          address: '1StringTest123456789012345678901234',
          scriptPubKey: '76a914string123456789012345678901234567888ac',
          status: UTXOStatus.reserved,
          blockHeight: 750123,
          confirmations: 5,
          createdAt: now,
          updatedAt: now,
        );

        final stringRep = utxo.toString();
        expect(stringRep, contains('string_test:2'));
        expect(stringRep, contains('123456'));
        expect(stringRep, contains('reserved'));
        expect(stringRep, contains('1StringTest'));
        expect(stringRep, contains('confirmations: 5'));
      });
    });

    group('UTXO copyWith Functionality', () {
      late BitcoinUtxo originalUtxo;

      setUp(() {
        final now = DateTime.now();
        final coin = dartsv.Coin.ofSat(BigInt.from(100000));
        originalUtxo = BitcoinUtxo(
          txid: 'copywith_test',
          vout: 0,
          value: coin,
          address: '1CopyWithTest123456789012345678901234',
          scriptPubKey: '76a914copywith123456789012345678901234567888ac',
          status: UTXOStatus.available,
          createdAt: now,
          updatedAt: now,
        );
      });

      test('should create copy with status change', () {
        final reservedUtxo = originalUtxo.copyWith(status: UTXOStatus.reserved);
        
        expect(reservedUtxo.status, equals(UTXOStatus.reserved));
        expect(reservedUtxo.txid, equals(originalUtxo.txid));
        expect(reservedUtxo.value.getValue(), equals(originalUtxo.value.getValue()));
        expect(originalUtxo.status, equals(UTXOStatus.available)); // Original unchanged
      });

      test('should create copy with confirmation updates', () {
        final confirmedUtxo = originalUtxo.copyWith(
          blockHeight: 750999,
          confirmations: 10,
        );
        
        expect(confirmedUtxo.blockHeight, equals(750999));
        expect(confirmedUtxo.confirmations, equals(10));
        expect(confirmedUtxo.isConfirmed, isTrue);
        expect(confirmedUtxo.txid, equals(originalUtxo.txid));
        expect(originalUtxo.blockHeight, isNull); // Original unchanged
      });

      test('should create copy with reservation details', () {
        final reservedUtxo = originalUtxo.copyWith(
          status: UTXOStatus.reserved,
          reservedByTxId: 'reservation_tx_789',
        );
        
        expect(reservedUtxo.status, equals(UTXOStatus.reserved));
        expect(reservedUtxo.reservedByTxId, equals('reservation_tx_789'));
        expect(reservedUtxo.isReserved, isTrue);
        expect(originalUtxo.reservedByTxId, isNull); // Original unchanged
      });

      test('should create copy with multiple changes', () {
        final updatedTime = DateTime.now().add(Duration(minutes: 5));
        final modifiedUtxo = originalUtxo.copyWith(
          status: UTXOStatus.spent,
          blockHeight: 751000,
          confirmations: 15,
          updatedAt: updatedTime,
          derivationIndex: 25,
        );
        
        expect(modifiedUtxo.status, equals(UTXOStatus.spent));
        expect(modifiedUtxo.blockHeight, equals(751000));
        expect(modifiedUtxo.confirmations, equals(15));
        expect(modifiedUtxo.updatedAt, equals(updatedTime));
        expect(modifiedUtxo.derivationIndex, equals(25));
        expect(modifiedUtxo.txid, equals(originalUtxo.txid)); // Core identity unchanged
        expect(modifiedUtxo.vout, equals(originalUtxo.vout)); // Core identity unchanged
      });
    });

    group('UTXO Serialization', () {
      test('should serialize to map correctly', () {
        final utxo = BitcoinUtxo.create(
          txid: 'serialize_test',
          vout: 3,
          satoshis: BigInt.from(250000),
          scriptPubKey: '76a914serialize123456789012345678901234567888ac',
          address: '1SerializeTest123456789012345678901234',
          blockHeight: 751234,
          confirmations: 7,
          derivationIndex: 15,
        );

        final map = utxo.toMap();
        
        expect(map['txid'], equals('serialize_test'));
        expect(map['vout'], equals(3));
        expect(map['satoshis'], equals('250000'));
        expect(map['scriptPubKey'], equals('76a914serialize123456789012345678901234567888ac'));
        expect(map['address'], equals('1SerializeTest123456789012345678901234'));
        expect(map['status'], equals('available'));
        expect(map['blockHeight'], equals(751234));
        expect(map['confirmations'], equals(7));
        expect(map['derivationIndex'], equals(15));
        expect(map['createdAt'], isA<String>());
        expect(map['updatedAt'], isA<String>());
      });

      test('should deserialize from map correctly', () {
        final now = DateTime.now();
        final map = {
          'txid': 'deserialize_test',
          'vout': 4,
          'satoshis': '300000',
          'scriptPubKey': '76a914deserialize123456789012345678901234567888ac',
          'address': '1DeserializeTest123456789012345678901234',
          'status': 'reserved',
          'blockHeight': 751456,
          'confirmations': 8,
          'createdAt': now.toIso8601String(),
          'updatedAt': now.toIso8601String(),
          'reservedByTxId': 'reserve_tx_999',
          'derivationIndex': 20,
        };

        final utxo = BitcoinUtxo.fromMap(map);
        
        expect(utxo.txid, equals('deserialize_test'));
        expect(utxo.vout, equals(4));
        expect(utxo.satoshis, equals(BigInt.from(300000)));
        expect(utxo.scriptPubKey, equals('76a914deserialize123456789012345678901234567888ac'));
        expect(utxo.address, equals('1DeserializeTest123456789012345678901234'));
        expect(utxo.status, equals(UTXOStatus.reserved));
        expect(utxo.blockHeight, equals(751456));
        expect(utxo.confirmations, equals(8));
        expect(utxo.reservedByTxId, equals('reserve_tx_999'));
        expect(utxo.derivationIndex, equals(20));
        expect(utxo.createdAt, equals(now));
        expect(utxo.updatedAt, equals(now));
      });

      test('should handle round-trip serialization', () {
        final originalUtxo = BitcoinUtxo.create(
          txid: 'roundtrip_test',
          vout: 5,
          satoshis: BigInt.from(500000),
          scriptPubKey: '76a914roundtrip123456789012345678901234567888ac',
          address: '1RoundtripTest123456789012345678901234',
          blockHeight: 751789,
          confirmations: 12,
          derivationIndex: 30,
        );

        final map = originalUtxo.toMap();
        final deserializedUtxo = BitcoinUtxo.fromMap(map);
        
        expect(deserializedUtxo.txid, equals(originalUtxo.txid));
        expect(deserializedUtxo.vout, equals(originalUtxo.vout));
        expect(deserializedUtxo.satoshis, equals(originalUtxo.satoshis));
        expect(deserializedUtxo.status, equals(originalUtxo.status));
        expect(deserializedUtxo.blockHeight, equals(originalUtxo.blockHeight));
        expect(deserializedUtxo.confirmations, equals(originalUtxo.confirmations));
        expect(deserializedUtxo.derivationIndex, equals(originalUtxo.derivationIndex));
        expect(deserializedUtxo, equals(originalUtxo)); // Should be equal
      });
    });

    group('UTXO Edge Cases and Validation', () {
      test('should handle edge case vout values', () {
        // vout 0 (common)
        final utxo0 = BitcoinUtxo.create(
          txid: 'vout_test',
          vout: 0,
          satoshis: BigInt.from(1000),
          address: '1VoutTest123456789012345678901234',
          scriptPubKey: '76a914vout123456789012345678901234567888ac',
        );
        expect(utxo0.vout, equals(0));
        expect(utxo0.key, equals('vout_test:0'));

        // Large vout (rare but valid)
        final utxoLarge = BitcoinUtxo.create(
          txid: 'vout_test',
          vout: 255,
          satoshis: BigInt.from(1000),
          address: '1VoutTest123456789012345678901234',
          scriptPubKey: '76a914vout123456789012345678901234567888ac',
        );
        expect(utxoLarge.vout, equals(255));
        expect(utxoLarge.key, equals('vout_test:255'));
      });

      test('should handle various script types', () {
        // P2PKH script
        final p2pkhUtxo = BitcoinUtxo.create(
          txid: 'p2pkh_test',
          vout: 0,
          satoshis: BigInt.from(100000),
          address: '1P2PKHTest123456789012345678901234',
          scriptPubKey: '76a914abcd1234efgh5678ijkl9012mnop3456qrst88ac',
        );
        expect(p2pkhUtxo.scriptPubKey, contains('76a914')); // OP_DUP OP_HASH160
        expect(p2pkhUtxo.address, isNotEmpty);

        // OP_RETURN script (unspendable)
        final opReturnUtxo = BitcoinUtxo.create(
          txid: 'opreturn_test',
          vout: 1,
          satoshis: BigInt.zero,
          address: '', // OP_RETURN outputs typically have no address
          scriptPubKey: '6a0848656c6c6f20425356', // OP_RETURN "Hello BSV"
        );
        expect(opReturnUtxo.scriptPubKey, startsWith('6a')); // OP_RETURN
        expect(opReturnUtxo.address, isEmpty);
        expect(opReturnUtxo.satoshis, equals(BigInt.zero));
      });

      test('should handle dust limit amounts', () {
        final dustUtxo = BitcoinUtxo.create(
          txid: 'dust_test',
          vout: 0,
          satoshis: BigInt.from(546), // Standard dust limit
          address: '1DustTest123456789012345678901234',
          scriptPubKey: '76a914dust123456789012345678901234567888ac',
        );

        expect(dustUtxo.satoshis, equals(BigInt.from(546)));
        expect(dustUtxo.isAvailable, isTrue);
      });

      test('should handle invalid status gracefully in deserialization', () {
        final map = {
          'txid': 'invalid_status_test',
          'vout': 0,
          'satoshis': '100000',
          'scriptPubKey': '76a914invalid123456789012345678901234567888ac',
          'address': '1InvalidTest123456789012345678901234',
          'status': 'invalid_status', // Invalid status
          'createdAt': DateTime.now().toIso8601String(),
          'updatedAt': DateTime.now().toIso8601String(),
        };

        final utxo = BitcoinUtxo.fromMap(map);
        expect(utxo.status, equals(UTXOStatus.available)); // Should default to available
      });
    });

    group('UTXO Reservation System', () {
      late BitcoinUtxo utxo;

      setUp(() {
        final now = DateTime.now();
        final coin = dartsv.Coin.ofSat(BigInt.from(100000));
        utxo = BitcoinUtxo(
          txid: 'reservation_test',
          vout: 0,
          value: coin,
          address: '1ReservationTest123456789012345678',
          scriptPubKey: '76a914reservation123456789012345678901234567888ac',
          status: UTXOStatus.available,
          createdAt: now,
          updatedAt: now,
        );
      });

      group('Basic Reservation', () {
        test('should reserve UTXO with transaction ID only', () {
          final reserved = utxo.reserve('tx_123');
          
          expect(reserved.status, equals(UTXOStatus.reserved));
          expect(reserved.reservedByTxId, equals('tx_123'));
          expect(reserved.reservationPriority, equals(0)); // Default priority
          expect(reserved.reservationReason, isNull);
          expect(reserved.reservationExpiresAt, isNull); // No duration specified
          expect(reserved.isReserved, isTrue);
          expect(reserved.isAvailable, isFalse);
        });

        test('should reserve UTXO with duration', () {
          final duration = Duration(minutes: 30);
          final beforeReserve = DateTime.now();
          final reserved = utxo.reserve('tx_456', duration: duration);
          final afterReserve = DateTime.now();
          
          expect(reserved.status, equals(UTXOStatus.reserved));
          expect(reserved.reservedByTxId, equals('tx_456'));
          expect(reserved.reservationExpiresAt, isNotNull);
          
          final expiresAt = reserved.reservationExpiresAt!;
          final expectedMin = beforeReserve.add(duration);
          final expectedMax = afterReserve.add(duration);
          
          expect(expiresAt.isAfter(expectedMin) || expiresAt.isAtSameMomentAs(expectedMin), isTrue);
          expect(expiresAt.isBefore(expectedMax) || expiresAt.isAtSameMomentAs(expectedMax), isTrue);
        });

        test('should reserve UTXO with priority and reason', () {
          final reserved = utxo.reserve(
            'tx_789',
            priority: 5,
            reason: 'High priority transaction',
          );
          
          expect(reserved.status, equals(UTXOStatus.reserved));
          expect(reserved.reservedByTxId, equals('tx_789'));
          expect(reserved.reservationPriority, equals(5));
          expect(reserved.reservationReason, equals('High priority transaction'));
        });

        test('should reserve UTXO with all parameters', () {
          final duration = Duration(hours: 2);
          final reserved = utxo.reserve(
            'tx_complete',
            duration: duration,
            priority: 10,
            reason: 'Complete test reservation',
          );
          
          expect(reserved.status, equals(UTXOStatus.reserved));
          expect(reserved.reservedByTxId, equals('tx_complete'));
          expect(reserved.reservationPriority, equals(10));
          expect(reserved.reservationReason, equals('Complete test reservation'));
          expect(reserved.reservationExpiresAt, isNotNull);
        });
      });

      group('Reservation Release', () {
        test('should release reservation and clear all reservation fields', () {
          final reserved = utxo.reserve(
            'tx_release_test',
            duration: Duration(minutes: 30),
            priority: 5,
            reason: 'Test reservation',
          );
          
          expect(reserved.status, equals(UTXOStatus.reserved));
          
          final released = reserved.releaseReservation();
          
          expect(released.status, equals(UTXOStatus.available));
          expect(released.reservedByTxId, isNull);
          expect(released.reservationExpiresAt, isNull);
          expect(released.reservationPriority, isNull);
          expect(released.reservationReason, isNull);
          expect(released.isAvailable, isTrue);
          expect(released.isReserved, isFalse);
        });

        test('should update timestamp when releasing reservation', () {
          final reserved = utxo.reserve('tx_timestamp_test');
          final originalTimestamp = reserved.updatedAt;
          
          // Small delay to ensure timestamp difference
          Future.delayed(Duration(milliseconds: 1));
          
          final released = reserved.releaseReservation();
          
          expect(released.updatedAt.isAfter(originalTimestamp), isTrue);
        });
      });

      group('Reservation Renewal', () {
        test('should renew reservation with extension', () {
          final initialDuration = Duration(minutes: 30);
          final reserved = utxo.reserve('tx_renew_test', duration: initialDuration);
          final originalExpiry = reserved.reservationExpiresAt!;
          
          final extension = Duration(minutes: 15);
          final renewed = reserved.renewReservation(extension);
          
          expect(renewed.status, equals(UTXOStatus.reserved));
          expect(renewed.reservedByTxId, equals('tx_renew_test'));
          expect(renewed.reservationExpiresAt, isNotNull);
          expect(renewed.reservationExpiresAt!.isAfter(originalExpiry), isTrue);
          
          final expectedNewExpiry = originalExpiry.add(extension);
          final actualNewExpiry = renewed.reservationExpiresAt!;
          expect(actualNewExpiry.difference(expectedNewExpiry).abs().inMilliseconds, lessThan(100)); // Allow small timing difference
        });

        test('should renew reservation with new reason', () {
          final reserved = utxo.reserve('tx_reason_test', reason: 'Original reason');
          
          final renewed = reserved.renewReservation(
            Duration(minutes: 10),
            reason: 'Updated reason',
          );
          
          expect(renewed.reservationReason, equals('Updated reason'));
        });

        test('should throw error when renewing non-reserved UTXO', () {
          expect(
            () => utxo.renewReservation(Duration(minutes: 10)),
            throwsA(isA<StateError>()),
          );
        });

        test('should keep existing reason when not provided in renewal', () {
          final reserved = utxo.reserve('tx_keep_reason', reason: 'Keep this reason');
          
          final renewed = reserved.renewReservation(Duration(minutes: 10));
          
          expect(renewed.reservationReason, equals('Keep this reason'));
        });
      });

      group('Reservation Expiration', () {
        test('should detect expired reservation', () {
          final pastTime = DateTime.now().subtract(Duration(minutes: 10));
          final expiredUtxo = utxo.copyWith(
            status: UTXOStatus.reserved,
            reservedByTxId: 'tx_expired',
            reservationExpiresAt: pastTime,
          );
          
          expect(expiredUtxo.isReservationExpired, isTrue);
          expect(expiredUtxo.isEffectivelyAvailable, isTrue);
        });

        test('should detect non-expired reservation', () {
          final futureTime = DateTime.now().add(Duration(minutes: 10));
          final activeUtxo = utxo.copyWith(
            status: UTXOStatus.reserved,
            reservedByTxId: 'tx_active',
            reservationExpiresAt: futureTime,
          );
          
          expect(activeUtxo.isReservationExpired, isFalse);
          expect(activeUtxo.isEffectivelyAvailable, isFalse);
        });

        test('should handle reservation without expiry time', () {
          final noExpiryUtxo = utxo.copyWith(
            status: UTXOStatus.reserved,
            reservedByTxId: 'tx_no_expiry',
          );
          
          expect(noExpiryUtxo.isReservationExpired, isFalse);
          expect(noExpiryUtxo.isEffectivelyAvailable, isFalse);
        });

        test('should handle available UTXO (no reservation to expire)', () {
          expect(utxo.isReservationExpired, isFalse);
          expect(utxo.isEffectivelyAvailable, isTrue);
        });
      });

      group('Reservation Time Remaining', () {
        test('should calculate time remaining for active reservation', () {
          final futureTime = DateTime.now().add(Duration(minutes: 15));
          final activeUtxo = utxo.copyWith(
            status: UTXOStatus.reserved,
            reservedByTxId: 'tx_time_remaining',
            reservationExpiresAt: futureTime,
          );
          
          final remaining = activeUtxo.reservationTimeRemaining;
          expect(remaining, isNotNull);
          expect(remaining!.inMinutes, greaterThanOrEqualTo(14)); // Should be close to 15 minutes
          expect(remaining.inMinutes, lessThan(16));
        });

        test('should return zero for expired reservation', () {
          final pastTime = DateTime.now().subtract(Duration(minutes: 5));
          final expiredUtxo = utxo.copyWith(
            status: UTXOStatus.reserved,
            reservedByTxId: 'tx_expired_time',
            reservationExpiresAt: pastTime,
          );
          
          final remaining = expiredUtxo.reservationTimeRemaining;
          expect(remaining, isNotNull);
          expect(remaining!, equals(Duration.zero));
        });

        test('should return null for non-reserved UTXO', () {
          expect(utxo.reservationTimeRemaining, isNull);
        });

        test('should return null for reservation without expiry', () {
          final noExpiryUtxo = utxo.copyWith(
            status: UTXOStatus.reserved,
            reservedByTxId: 'tx_no_expiry_time',
          );
          
          expect(noExpiryUtxo.reservationTimeRemaining, isNull);
        });
      });

      group('Effectively Available Status', () {
        test('should be effectively available when truly available', () {
          expect(utxo.isEffectivelyAvailable, isTrue);
        });

        test('should not be effectively available when actively reserved', () {
          final futureTime = DateTime.now().add(Duration(minutes: 10));
          final reservedUtxo = utxo.copyWith(
            status: UTXOStatus.reserved,
            reservedByTxId: 'tx_active_reservation',
            reservationExpiresAt: futureTime,
          );
          
          expect(reservedUtxo.isEffectivelyAvailable, isFalse);
        });

        test('should be effectively available when reservation expired', () {
          final pastTime = DateTime.now().subtract(Duration(minutes: 5));
          final expiredUtxo = utxo.copyWith(
            status: UTXOStatus.reserved,
            reservedByTxId: 'tx_expired_reservation',
            reservationExpiresAt: pastTime,
          );
          
          expect(expiredUtxo.isEffectivelyAvailable, isTrue);
        });

        test('should not be effectively available when spent', () {
          final spentUtxo = utxo.copyWith(status: UTXOStatus.spent);
          expect(spentUtxo.isEffectivelyAvailable, isFalse);
        });
      });

      group('copyWith with Reservation Fields', () {
        test('should update reservation fields with copyWith', () {
          final futureTime = DateTime.now().add(Duration(minutes: 30));
          
          final updated = utxo.copyWith(
            status: UTXOStatus.reserved,
            reservedByTxId: 'tx_copy_with',
            reservationExpiresAt: futureTime,
            reservationPriority: 7,
            reservationReason: 'CopyWith test',
          );
          
          expect(updated.status, equals(UTXOStatus.reserved));
          expect(updated.reservedByTxId, equals('tx_copy_with'));
          expect(updated.reservationExpiresAt, equals(futureTime));
          expect(updated.reservationPriority, equals(7));
          expect(updated.reservationReason, equals('CopyWith test'));
        });

        test('should clear reservation fields with copyWith null values', () {
          final reserved = utxo.reserve('tx_clear_test', priority: 5, reason: 'Clear me');
          
          final cleared = reserved.copyWith(
            status: UTXOStatus.available,
            reservedByTxId: null,
            reservationExpiresAt: null,
            reservationPriority: null,
            reservationReason: null,
          );
          
          expect(cleared.status, equals(UTXOStatus.available));
          expect(cleared.reservedByTxId, isNull);
          expect(cleared.reservationExpiresAt, isNull);
          expect(cleared.reservationPriority, isNull);
          expect(cleared.reservationReason, isNull);
        });
      });
    });
  });
} 