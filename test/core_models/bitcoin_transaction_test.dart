import 'package:test/test.dart';
import 'package:dartsv/dartsv.dart' as dartsv;

import 'package:libspiffy/src/models/bitcoin_transaction.dart';

void main() {
  group('BitcoinTransaction Tests', () {
    group('Transaction Creation', () {
      test('should create transaction with all required fields', () {
        final now = DateTime.now();
        final transaction = BitcoinTransaction(
          txid: 'abc123def456',
          rawHex: '0100000001abcd...',
          status: TransactionStatus.created,
          blockHeight: null,
          confirmations: null,
          inputValue: BigInt.from(150000),
          outputValue: BigInt.from(140000),
          fee: BigInt.from(10000),
          receivingAddresses: ['1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2'],
          sendingAddresses: ['1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa'],
          netAmount: BigInt.from(-150000),
          createdAt: now,
          updatedAt: now,
          memo: 'Test transaction',
          lockTime: 0,
          version: 1,
        );

        expect(transaction.txid, equals('abc123def456'));
        expect(transaction.rawHex, equals('0100000001abcd...'));
        expect(transaction.status, equals(TransactionStatus.created));
        expect(transaction.blockHeight, isNull);
        expect(transaction.confirmations, isNull);
        expect(transaction.inputValue, equals(BigInt.from(150000)));
        expect(transaction.outputValue, equals(BigInt.from(140000)));
        expect(transaction.fee, equals(BigInt.from(10000)));
        expect(transaction.receivingAddresses, contains('1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2'));
        expect(transaction.sendingAddresses, contains('1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa'));
        expect(transaction.netAmount, equals(BigInt.from(-150000)));
        expect(transaction.memo, equals('Test transaction'));
        expect(transaction.lockTime, equals(0));
        expect(transaction.version, equals(1));
      });

      test('should create transaction with DartSV integration', () {
        // Test the factory method with mock data
        final transaction = BitcoinTransaction.fromDartSvTransaction(
          transaction: dartsv.Transaction(), // Empty transaction for testing
          status: TransactionStatus.signed,
          receivingAddresses: ['1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2'],
          sendingAddresses: ['1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa'],
          netAmount: BigInt.from(150000),
          blockHeight: 750000,
          confirmations: 6,
          memo: 'From DartSV',
          inputValue: BigInt.from(200000),
        );

        expect(transaction.status, equals(TransactionStatus.signed));
        expect(transaction.inputValue, equals(BigInt.from(200000)));
        expect(transaction.fee, equals(BigInt.from(200000))); // inputValue - outputValue (0)
        expect(transaction.blockHeight, equals(750000));
        expect(transaction.confirmations, equals(6));
        expect(transaction.memo, equals('From DartSV'));
      });

      test('should handle zero input value in DartSV factory', () {
        final transaction = BitcoinTransaction.fromDartSvTransaction(
          transaction: dartsv.Transaction(),
          status: TransactionStatus.created,
          receivingAddresses: [],
          sendingAddresses: [],
          netAmount: BigInt.zero,
        );

        expect(transaction.inputValue, equals(BigInt.zero));
        expect(transaction.fee, equals(BigInt.zero));
      });
    });

    group('Transaction Status Properties', () {
      test('should correctly identify confirmed transactions', () {
        final transaction = _createTestTransaction(
          status: TransactionStatus.confirmed,
          confirmations: 6,
        );

        expect(transaction.isConfirmed, isTrue);
        expect(transaction.isPending, isFalse);
        expect(transaction.isFailed, isFalse);
      });

      test('should correctly identify pending transactions', () {
        final transaction = _createTestTransaction(
          status: TransactionStatus.pending,
          confirmations: 0,
        );

        expect(transaction.isConfirmed, isFalse);
        expect(transaction.isPending, isTrue);
        expect(transaction.isFailed, isFalse);
      });

      test('should correctly identify failed transactions', () {
        final transaction = _createTestTransaction(
          status: TransactionStatus.failed,
        );

        expect(transaction.isConfirmed, isFalse);
        expect(transaction.isPending, isFalse);
        expect(transaction.isFailed, isTrue);
      });

      test('should not consider confirmed transaction with 0 confirmations as confirmed', () {
        final transaction = _createTestTransaction(
          status: TransactionStatus.confirmed,
          confirmations: 0,
        );

        expect(transaction.isConfirmed, isFalse);
      });
    });

    group('DartSV Coin Integration', () {
      test('should provide correct coin values', () {
        final transaction = _createTestTransaction(
          inputValue: BigInt.from(100000),
          outputValue: BigInt.from(90000),
          fee: BigInt.from(10000),
          netAmount: BigInt.from(-100000),
        );

        expect(transaction.inputCoin.getValue(), equals(BigInt.from(100000)));
        expect(transaction.outputCoin.getValue(), equals(BigInt.from(90000)));
        expect(transaction.feeCoin.getValue(), equals(BigInt.from(10000)));
        expect(transaction.netCoin.getValue(), equals(BigInt.from(-100000)));
      });

      test('should handle negative net amounts correctly', () {
        final transaction = _createTestTransaction(
          netAmount: BigInt.from(-50000),
        );

        expect(transaction.netCoin.getValue(), equals(BigInt.from(-50000)));
      });
    });

    group('Transaction Direction Properties', () {
      test('should determine outgoing transaction', () {
        final transaction = _createTestTransaction(
          netAmount: BigInt.from(-100000),
        );

        expect(transaction.isOutgoing, isTrue);
        expect(transaction.isIncoming, isFalse);
      });

      test('should determine incoming transaction', () {
        final transaction = _createTestTransaction(
          netAmount: BigInt.from(100000),
        );

        expect(transaction.isIncoming, isTrue);
        expect(transaction.isOutgoing, isFalse);
      });

      test('should handle zero net amount', () {
        final transaction = _createTestTransaction(
          netAmount: BigInt.zero,
        );

        expect(transaction.isIncoming, isFalse);
        expect(transaction.isOutgoing, isFalse);
      });
    });

    group('Transaction Status Updates', () {
      test('should mark transaction as failed', () {
        final transaction = _createTestTransaction(status: TransactionStatus.broadcast);
        final failedTx = transaction.markFailed();

        expect(failedTx.status, equals(TransactionStatus.failed));
        expect(failedTx.updatedAt.isAfter(transaction.updatedAt), isTrue);
        expect(failedTx.txid, equals(transaction.txid)); // Other fields unchanged
      });

      test('should update confirmation info', () {
        final transaction = _createTestTransaction(
          status: TransactionStatus.confirmed,
          blockHeight: 750000,
          confirmations: 1,
        );
        
        final updatedTx = transaction.updateConfirmations(
          status: TransactionStatus.confirmed,
          blockHeight: 750000,
          confirmations: 6,
        );

        expect(updatedTx.confirmations, equals(6));
        expect(updatedTx.blockHeight, equals(750000));
        expect(updatedTx.status, equals(TransactionStatus.confirmed));
        expect(updatedTx.updatedAt.isAfter(transaction.updatedAt), isTrue);
      });
    });

    group('CopyWith Functionality', () {
      test('should copy with changed status', () {
        final original = _createTestTransaction();
        final copied = original.copyWith(status: TransactionStatus.broadcast);

        expect(copied.status, equals(TransactionStatus.broadcast));
        expect(copied.txid, equals(original.txid));
        expect(copied.rawHex, equals(original.rawHex));
      });

      test('should copy with changed block info', () {
        final original = _createTestTransaction();
        final copied = original.copyWith(
          blockHeight: 750000,
          confirmations: 6,
        );

        expect(copied.blockHeight, equals(750000));
        expect(copied.confirmations, equals(6));
        expect(copied.status, equals(original.status));
      });

      test('should copy with changed amounts', () {
        final original = _createTestTransaction();
        final copied = original.copyWith(
          inputValue: BigInt.from(200000),
          outputValue: BigInt.from(180000),
          fee: BigInt.from(20000),
          netAmount: BigInt.from(-200000),
        );

        expect(copied.inputValue, equals(BigInt.from(200000)));
        expect(copied.outputValue, equals(BigInt.from(180000)));
        expect(copied.fee, equals(BigInt.from(20000)));
        expect(copied.netAmount, equals(BigInt.from(-200000)));
      });

      test('should copy with changed addresses', () {
        final original = _createTestTransaction();
        final newReceiving = ['1NewReceivingAddress'];
        final newSending = ['1NewSendingAddress'];
        
        final copied = original.copyWith(
          receivingAddresses: newReceiving,
          sendingAddresses: newSending,
        );

        expect(copied.receivingAddresses, equals(newReceiving));
        expect(copied.sendingAddresses, equals(newSending));
      });

      test('should copy with updated timestamp', () {
        final original = _createTestTransaction();
        final newTime = DateTime.now().add(Duration(hours: 1));
        
        final copied = original.copyWith(updatedAt: newTime);

        expect(copied.updatedAt, equals(newTime));
        expect(copied.createdAt, equals(original.createdAt));
      });
    });

    group('Serialization', () {
      test('should serialize to map correctly', () {
        final now = DateTime.now();
        final transaction = BitcoinTransaction(
          txid: 'test123',
          rawHex: '0100000001...',
          status: TransactionStatus.confirmed,
          blockHeight: 750000,
          confirmations: 6,
          inputValue: BigInt.from(100000),
          outputValue: BigInt.from(90000),
          fee: BigInt.from(10000),
          receivingAddresses: ['1Receiving'],
          sendingAddresses: ['1Sending'],
          netAmount: BigInt.from(90000),
          createdAt: now,
          updatedAt: now,
          memo: 'Test memo',
          lockTime: 500000,
          version: 2,
        );

        final map = transaction.toMap();

        expect(map['txid'], equals('test123'));
        expect(map['rawHex'], equals('0100000001...'));
        expect(map['status'], equals('confirmed'));
        expect(map['blockHeight'], equals(750000));
        expect(map['confirmations'], equals(6));
        expect(map['inputValue'], equals('100000'));
        expect(map['outputValue'], equals('90000'));
        expect(map['fee'], equals('10000'));
        expect(map['receivingAddresses'], equals(['1Receiving']));
        expect(map['sendingAddresses'], equals(['1Sending']));
        expect(map['netAmount'], equals('90000'));
        expect(map['createdAt'], equals(now.toIso8601String()));
        expect(map['updatedAt'], equals(now.toIso8601String()));
        expect(map['memo'], equals('Test memo'));
        expect(map['lockTime'], equals(500000));
        expect(map['version'], equals(2));
      });

      test('should deserialize from map correctly', () {
        final now = DateTime.now();
        final map = {
          'txid': 'test123',
          'rawHex': '0100000001...',
          'status': 'confirmed',
          'blockHeight': 750000,
          'confirmations': 6,
          'inputValue': '100000',
          'outputValue': '90000',
          'fee': '10000',
          'receivingAddresses': ['1Receiving'],
          'sendingAddresses': ['1Sending'],
          'netAmount': '90000',
          'createdAt': now.toIso8601String(),
          'updatedAt': now.toIso8601String(),
          'memo': 'Test memo',
          'lockTime': 500000,
          'version': 2,
        };

        final transaction = BitcoinTransaction.fromMap(map);

        expect(transaction.txid, equals('test123'));
        expect(transaction.rawHex, equals('0100000001...'));
        expect(transaction.status, equals(TransactionStatus.confirmed));
        expect(transaction.blockHeight, equals(750000));
        expect(transaction.confirmations, equals(6));
        expect(transaction.inputValue, equals(BigInt.from(100000)));
        expect(transaction.outputValue, equals(BigInt.from(90000)));
        expect(transaction.fee, equals(BigInt.from(10000)));
        expect(transaction.receivingAddresses, equals(['1Receiving']));
        expect(transaction.sendingAddresses, equals(['1Sending']));
        expect(transaction.netAmount, equals(BigInt.from(90000)));
        expect(transaction.createdAt, equals(now));
        expect(transaction.updatedAt, equals(now));
        expect(transaction.memo, equals('Test memo'));
        expect(transaction.lockTime, equals(500000));
        expect(transaction.version, equals(2));
      });

      test('should handle null values in serialization', () {
        final transaction = _createTestTransaction(
          blockHeight: null,
          confirmations: null,
          memo: null,
        );

        final map = transaction.toMap();
        expect(map['blockHeight'], isNull);
        expect(map['confirmations'], isNull);
        expect(map['memo'], isNull);

        final deserialized = BitcoinTransaction.fromMap(map);
        expect(deserialized.blockHeight, isNull);
        expect(deserialized.confirmations, isNull);
        expect(deserialized.memo, isNull);
      });

      test('should handle unknown status in deserialization', () {
        final map = {
          'txid': 'test123',
          'rawHex': '0100000001...',
          'status': 'unknown_status',
          'inputValue': '100000',
          'outputValue': '90000',
          'fee': '10000',
          'receivingAddresses': <String>[],
          'sendingAddresses': <String>[],
          'netAmount': '0',
          'createdAt': DateTime.now().toIso8601String(),
          'updatedAt': DateTime.now().toIso8601String(),
          'lockTime': 0,
          'version': 1,
        };

        final transaction = BitcoinTransaction.fromMap(map);
        expect(transaction.status, equals(TransactionStatus.created));
      });

      test('should maintain serialization roundtrip integrity', () {
        final original = _createTestTransaction();
        final map = original.toMap();
        final deserialized = BitcoinTransaction.fromMap(map);

        expect(deserialized, equals(original));
        expect(deserialized.hashCode, equals(original.hashCode));
      });
    });

    group('Equality and HashCode', () {
      test('should be equal if txids are the same', () {
        final tx1 = _createTestTransaction(txid: 'same_txid');
        final tx2 = _createTestTransaction(
          txid: 'same_txid',
          status: TransactionStatus.confirmed, // Different status
        );

        expect(tx1, equals(tx2));
        expect(tx1.hashCode, equals(tx2.hashCode));
      });

      test('should not be equal if txids are different', () {
        final tx1 = _createTestTransaction(txid: 'txid1');
        final tx2 = _createTestTransaction(txid: 'txid2');

        expect(tx1, isNot(equals(tx2)));
        expect(tx1.hashCode, isNot(equals(tx2.hashCode)));
      });

      test('should be equal to itself', () {
        final tx = _createTestTransaction();
        expect(tx, equals(tx));
      });

      test('should not be equal to null or different type', () {
        final tx = _createTestTransaction();
        expect(tx, isNot(equals(null)));
        expect(tx, isNot(equals('not a transaction')));
      });
    });

    group('String Representation', () {
      test('should provide meaningful toString', () {
        final transaction = _createTestTransaction(
          txid: 'abc123',
          status: TransactionStatus.confirmed,
          netAmount: BigInt.from(50000),
          confirmations: 6,
        );

        final str = transaction.toString();
        expect(str, contains('abc123'));
        expect(str, contains('confirmed'));
        expect(str, contains('50000'));
        expect(str, contains('6'));
      });

      test('should handle null confirmations in toString', () {
        final transaction = _createTestTransaction(
          confirmations: null,
        );

        final str = transaction.toString();
        expect(str, contains('null'));
      });
    });

    group('Edge Cases and Error Conditions', () {
      test('should handle zero amounts', () {
        final transaction = _createTestTransaction(
          inputValue: BigInt.zero,
          outputValue: BigInt.zero,
          fee: BigInt.zero,
          netAmount: BigInt.zero,
        );

        expect(transaction.inputValue, equals(BigInt.zero));
        expect(transaction.outputValue, equals(BigInt.zero));
        expect(transaction.fee, equals(BigInt.zero));
        expect(transaction.netAmount, equals(BigInt.zero));
        expect(transaction.inputCoin.getValue(), equals(BigInt.zero));
      });

      test('should handle very large amounts', () {
        final largeAmount = BigInt.parse('2100000000000000'); // 21M BTC in satoshis
        final transaction = _createTestTransaction(
          inputValue: largeAmount,
          outputValue: largeAmount - BigInt.from(1000),
          fee: BigInt.from(1000),
          netAmount: largeAmount,
        );

        expect(transaction.inputValue, equals(largeAmount));
        expect(transaction.outputValue, equals(largeAmount - BigInt.from(1000)));
        expect(transaction.fee, equals(BigInt.from(1000)));
      });

      test('should handle empty address lists', () {
        final transaction = _createTestTransaction(
          receivingAddresses: [],
          sendingAddresses: [],
        );

        expect(transaction.receivingAddresses, isEmpty);
        expect(transaction.sendingAddresses, isEmpty);
      });

      test('should handle very old and future dates', () {
        final veryOld = DateTime(2009, 1, 3); // Bitcoin genesis block
        final future = DateTime(2030, 1, 1);
        
        final transaction = _createTestTransaction(
          createdAt: veryOld,
          updatedAt: future,
        );

        expect(transaction.createdAt, equals(veryOld));
        expect(transaction.updatedAt, equals(future));
      });
    });

    group('Transaction Status and Script Type Enums', () {
      test('should cover all transaction statuses', () {
        final statuses = TransactionStatus.values;
        expect(statuses, contains(TransactionStatus.created));
        expect(statuses, contains(TransactionStatus.signed));
        expect(statuses, contains(TransactionStatus.broadcast));
        expect(statuses, contains(TransactionStatus.pending));
        expect(statuses, contains(TransactionStatus.confirmed));
        expect(statuses, contains(TransactionStatus.failed));
        expect(statuses.length, equals(6));
      });

      test('should cover all script types', () {
        final types = BitcoinScriptType.values;
        expect(types, contains(BitcoinScriptType.p2pkh));
        expect(types, contains(BitcoinScriptType.p2pk));
        expect(types, contains(BitcoinScriptType.p2ms));
        expect(types, contains(BitcoinScriptType.opReturn));
        expect(types, contains(BitcoinScriptType.p2sh));
        expect(types, contains(BitcoinScriptType.custom));
        expect(types, contains(BitcoinScriptType.unknown));
        expect(types.length, equals(7));
      });

      test('should serialize direction to JSON correctly', () {
        expect(BitcoinTransactionDirection.incoming.toJson(), equals('incoming'));
        expect(BitcoinTransactionDirection.outgoing.toJson(), equals('outgoing'));
        expect(BitcoinTransactionDirection.self.toJson(), equals('self'));
        expect(BitcoinTransactionDirection.unknown.toJson(), equals('unknown'));
      });
    });
  });
}

/// Helper function to create a test transaction with sensible defaults
BitcoinTransaction _createTestTransaction({
  String? txid,
  String? rawHex,
  TransactionStatus? status,
  int? blockHeight,
  int? confirmations,
  BigInt? inputValue,
  BigInt? outputValue,
  BigInt? fee,
  List<String>? receivingAddresses,
  List<String>? sendingAddresses,
  BigInt? netAmount,
  DateTime? createdAt,
  DateTime? updatedAt,
  String? memo,
  int? lockTime,
  int? version,
}) {
  final now = DateTime.now();
  return BitcoinTransaction(
    txid: txid ?? 'test_txid_123',
    rawHex: rawHex ?? '0100000001abcd1234...',
    status: status ?? TransactionStatus.created,
    blockHeight: blockHeight,
    confirmations: confirmations,
    inputValue: inputValue ?? BigInt.from(100000),
    outputValue: outputValue ?? BigInt.from(90000),
    fee: fee ?? BigInt.from(10000),
    receivingAddresses: receivingAddresses ?? ['1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2'],
    sendingAddresses: sendingAddresses ?? ['1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa'],
    netAmount: netAmount ?? BigInt.from(90000),
    createdAt: createdAt ?? now,
    updatedAt: updatedAt ?? now,
    memo: memo,
    lockTime: lockTime ?? 0,
    version: version ?? 1,
  );
} 