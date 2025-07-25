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
        final now = DateTime.now();
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
  });
} 