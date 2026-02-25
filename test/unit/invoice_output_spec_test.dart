import 'dart:convert';

import 'package:test/test.dart';
import 'package:libspiffy/src/models/invoice_output_spec.dart';
import 'package:libspiffy/src/models/bitcoin_transaction.dart';

void main() {
  group('InvoiceOutputSpec', () {
    group('P2PKHOutputSpec', () {
      test('creates P2PKH output with address and amount', () {
        final output = P2PKHOutputSpec(
          address: 'mxyz123456789abcdef',
          amount: BigInt.from(10000),
          label: 'Payment portion',
        );

        expect(output.address, equals('mxyz123456789abcdef'));
        expect(output.amount, equals(BigInt.from(10000)));
        expect(output.label, equals('Payment portion'));
        expect(output.scriptType, equals(BitcoinScriptType.p2pkh));
      });

      test('serializes to map correctly', () {
        final output = P2PKHOutputSpec(
          address: 'mTestAddress123',
          amount: BigInt.from(50000),
          label: 'Test label',
        );

        final map = output.toMap();

        expect(map['type'], equals('p2pkh'));
        expect(map['address'], equals('mTestAddress123'));
        expect(map['amount'], equals('50000'));
        expect(map['label'], equals('Test label'));
      });

      test('deserializes from map correctly', () {
        final map = {
          'type': 'p2pkh',
          'address': 'mDeserializedAddr',
          'amount': '75000',
          'label': 'Deserialized',
        };

        final output = InvoiceOutputSpec.fromMap(map) as P2PKHOutputSpec;

        expect(output.address, equals('mDeserializedAddr'));
        expect(output.amount, equals(BigInt.from(75000)));
        expect(output.label, equals('Deserialized'));
      });

      test('handles null label in serialization', () {
        final output = P2PKHOutputSpec(
          address: 'mNoLabel',
          amount: BigInt.from(1000),
        );

        final map = output.toMap();
        expect(map.containsKey('label'), isFalse);

        final restored = InvoiceOutputSpec.fromMap(map) as P2PKHOutputSpec;
        expect(restored.label, isNull);
      });

      test('equality works correctly', () {
        final output1 = P2PKHOutputSpec(
          address: 'mSameAddress',
          amount: BigInt.from(5000),
          label: 'Same',
        );
        final output2 = P2PKHOutputSpec(
          address: 'mSameAddress',
          amount: BigInt.from(5000),
          label: 'Same',
        );
        final output3 = P2PKHOutputSpec(
          address: 'mDifferentAddress',
          amount: BigInt.from(5000),
          label: 'Same',
        );

        expect(output1, equals(output2));
        expect(output1, isNot(equals(output3)));
        expect(output1.hashCode, equals(output2.hashCode));
      });
    });

    group('P2MSOutputSpec', () {
      // Valid compressed public keys (must be valid EC points on secp256k1)
      final validPubKey1 =
          '0335cd55d33889f942e8c445cf4d9e9488a3be4bc4d4e91ccc9b57dcaa49c0f7a8';
      final validPubKey2 =
          '028f10cd0e0e9bc7352adb192484d576867a71cbd82295cd87c3ceffc5fbd74acc';
      final validPubKey3 =
          '02a7472269ad70ea6cf1ecc7fe25a23fb6bc47f928a9ec755e34bada052bd355ce';

      test('creates P2MS output with public keys and threshold', () {
        final output = P2MSOutputSpec(
          publicKeys: [validPubKey1, validPubKey2, validPubKey3],
          threshold: 2,
          amount: BigInt.from(50000),
          label: 'Escrow',
        );

        expect(output.publicKeys.length, equals(3));
        expect(output.threshold, equals(2));
        expect(output.totalKeys, equals(3));
        expect(output.amount, equals(BigInt.from(50000)));
        expect(output.scriptType, equals(BitcoinScriptType.p2ms));
      });

      test('isValid returns true for valid 2-of-3 multisig', () {
        final output = P2MSOutputSpec(
          publicKeys: [validPubKey1, validPubKey2, validPubKey3],
          threshold: 2,
          amount: BigInt.from(10000),
        );

        expect(output.isValid, isTrue);
      });

      test('isValid returns true for valid 1-of-2 multisig', () {
        final output = P2MSOutputSpec(
          publicKeys: [validPubKey1, validPubKey2],
          threshold: 1,
          amount: BigInt.from(10000),
        );

        expect(output.isValid, isTrue);
      });

      test('isValid returns false when threshold > totalKeys', () {
        final output = P2MSOutputSpec(
          publicKeys: [validPubKey1, validPubKey2],
          threshold: 3, // More than 2 keys
          amount: BigInt.from(10000),
        );

        expect(output.isValid, isFalse);
      });

      test('isValid returns false when threshold is 0', () {
        final output = P2MSOutputSpec(
          publicKeys: [validPubKey1, validPubKey2],
          threshold: 0,
          amount: BigInt.from(10000),
        );

        expect(output.isValid, isFalse);
      });

      test('isValid returns false for invalid public key length', () {
        final invalidPubKey = '03invalid'; // Too short

        final output = P2MSOutputSpec(
          publicKeys: [validPubKey1, invalidPubKey],
          threshold: 1,
          amount: BigInt.from(10000),
        );

        expect(output.isValid, isFalse);
      });

      test('isValid returns false when more than 16 keys', () {
        // Create 17 valid public keys
        final manyKeys = List.generate(
          17,
          (i) =>
              '03${i.toString().padLeft(2, '0')}${validPubKey1.substring(4)}',
        );

        final output = P2MSOutputSpec(
          publicKeys: manyKeys,
          threshold: 10,
          amount: BigInt.from(10000),
        );

        expect(output.isValid, isFalse);
      });

      test('serializes to map correctly', () {
        final output = P2MSOutputSpec(
          publicKeys: [validPubKey1, validPubKey2],
          threshold: 2,
          amount: BigInt.from(100000),
          label: 'Multisig escrow',
        );

        final map = output.toMap();

        expect(map['type'], equals('p2ms'));
        expect(map['publicKeys'], equals([validPubKey1, validPubKey2]));
        expect(map['threshold'], equals(2));
        expect(map['amount'], equals('100000'));
        expect(map['label'], equals('Multisig escrow'));
      });

      test('deserializes from map correctly', () {
        final map = {
          'type': 'p2ms',
          'publicKeys': [validPubKey1, validPubKey2, validPubKey3],
          'threshold': 2,
          'amount': '200000',
          'label': 'Restored multisig',
        };

        final output = InvoiceOutputSpec.fromMap(map) as P2MSOutputSpec;

        expect(output.publicKeys.length, equals(3));
        expect(output.threshold, equals(2));
        expect(output.amount, equals(BigInt.from(200000)));
        expect(output.label, equals('Restored multisig'));
      });

      test('roundtrip serialization preserves data', () {
        final original = P2MSOutputSpec(
          publicKeys: [validPubKey1, validPubKey2],
          threshold: 2,
          amount: BigInt.from(50000),
          label: 'Roundtrip test',
        );

        final map = original.toMap();
        final restored = InvoiceOutputSpec.fromMap(map) as P2MSOutputSpec;

        expect(restored.publicKeys, equals(original.publicKeys));
        expect(restored.threshold, equals(original.threshold));
        expect(restored.amount, equals(original.amount));
        expect(restored.label, equals(original.label));
      });

      test('equality works correctly', () {
        final output1 = P2MSOutputSpec(
          publicKeys: [validPubKey1, validPubKey2],
          threshold: 2,
          amount: BigInt.from(5000),
        );
        final output2 = P2MSOutputSpec(
          publicKeys: [validPubKey1, validPubKey2],
          threshold: 2,
          amount: BigInt.from(5000),
        );
        final output3 = P2MSOutputSpec(
          publicKeys: [validPubKey1, validPubKey2],
          threshold: 1, // Different threshold
          amount: BigInt.from(5000),
        );

        expect(output1, equals(output2));
        expect(output1, isNot(equals(output3)));
        expect(output1.hashCode, equals(output2.hashCode));
      });

      test('toString provides readable output', () {
        final output = P2MSOutputSpec(
          publicKeys: [validPubKey1, validPubKey2, validPubKey3],
          threshold: 2,
          amount: BigInt.from(50000),
          label: 'Test',
        );

        final str = output.toString();
        expect(str, contains('threshold: 2'));
        expect(str, contains('totalKeys: 3'));
        expect(str, contains('amount: 50000'));
      });
    });

    group('OPReturnOutputSpec', () {
      final testData1 = utf8.encode('Hello, blockchain!');
      final testData2 = utf8.encode('Second chunk');

      test('creates OP_RETURN output with data chunks', () {
        final output = OPReturnOutputSpec(
          dataChunks: [testData1, testData2],
          label: 'Data carrier',
        );

        expect(output.dataChunks.length, equals(2));
        expect(output.amount, equals(BigInt.zero));
        expect(output.label, equals('Data carrier'));
        expect(output.scriptType, equals(BitcoinScriptType.opReturn));
      });

      test('amount is always zero', () {
        final output = OPReturnOutputSpec(
          dataChunks: [testData1],
        );

        expect(output.amount, equals(BigInt.zero));
      });

      test('isValid returns true for valid data chunks', () {
        final output = OPReturnOutputSpec(
          dataChunks: [testData1],
        );

        expect(output.isValid, isTrue);
      });

      test('isValid returns false for empty data chunks list', () {
        final output = OPReturnOutputSpec(
          dataChunks: [],
        );

        expect(output.isValid, isFalse);
      });

      test('isValid returns false when all chunks are empty', () {
        final output = OPReturnOutputSpec(
          dataChunks: [[], []],
        );

        expect(output.isValid, isFalse);
      });

      test('isValid returns false when total data exceeds limit', () {
        final largeChunk = List<int>.filled(OPReturnOutputSpec.maxTotalDataSize + 1, 0);
        final output = OPReturnOutputSpec(
          dataChunks: [largeChunk],
        );

        expect(output.isValid, isFalse);
      });

      test('serializes to map correctly', () {
        final output = OPReturnOutputSpec(
          dataChunks: [testData1, testData2],
          label: 'Test OP_RETURN',
        );

        final map = output.toMap();

        expect(map['type'], equals('op_return'));
        expect(map['dataChunks'], isA<List>());
        expect((map['dataChunks'] as List).length, equals(2));
        expect(map['label'], equals('Test OP_RETURN'));
        // Amount is not serialized (always zero)
      });

      test('deserializes from map correctly', () {
        final map = {
          'type': 'op_return',
          'dataChunks': [
            '48656c6c6f2c20626c6f636b636861696e21', // "Hello, blockchain!" in hex
            '5365636f6e64206368756e6b',                // "Second chunk" in hex
          ],
          'label': 'Restored OP_RETURN',
        };

        final output = InvoiceOutputSpec.fromMap(map) as OPReturnOutputSpec;

        expect(output.dataChunks.length, equals(2));
        expect(utf8.decode(output.dataChunks[0]), equals('Hello, blockchain!'));
        expect(utf8.decode(output.dataChunks[1]), equals('Second chunk'));
        expect(output.amount, equals(BigInt.zero));
        expect(output.label, equals('Restored OP_RETURN'));
      });

      test('roundtrip serialization preserves data', () {
        final original = OPReturnOutputSpec(
          dataChunks: [testData1, testData2],
          label: 'Roundtrip',
        );

        final map = original.toMap();
        final restored = InvoiceOutputSpec.fromMap(map) as OPReturnOutputSpec;

        expect(utf8.decode(restored.dataChunks[0]), equals(utf8.decode(testData1)));
        expect(utf8.decode(restored.dataChunks[1]), equals(utf8.decode(testData2)));
        expect(restored.amount, equals(original.amount));
        expect(restored.label, equals(original.label));
      });

      test('handles null label in serialization', () {
        final output = OPReturnOutputSpec(
          dataChunks: [testData1],
        );

        final map = output.toMap();
        expect(map.containsKey('label'), isFalse);

        final restored = InvoiceOutputSpec.fromMap(map) as OPReturnOutputSpec;
        expect(restored.label, isNull);
      });

      test('equality works correctly', () {
        final output1 = OPReturnOutputSpec(
          dataChunks: [testData1, testData2],
          label: 'Same',
        );
        final output2 = OPReturnOutputSpec(
          dataChunks: [testData1, testData2],
          label: 'Same',
        );
        final output3 = OPReturnOutputSpec(
          dataChunks: [testData1], // Different chunks
          label: 'Same',
        );

        expect(output1, equals(output2));
        expect(output1, isNot(equals(output3)));
        expect(output1.hashCode, equals(output2.hashCode));
      });

      test('separateOutputs defaults to false', () {
        final output = OPReturnOutputSpec(
          dataChunks: [testData1],
        );

        expect(output.separateOutputs, isFalse);
      });

      test('separateOutputs can be set to true', () {
        final output = OPReturnOutputSpec(
          dataChunks: [testData1, testData2],
          separateOutputs: true,
        );

        expect(output.separateOutputs, isTrue);
      });

      test('separateOutputs roundtrip serialization', () {
        final original = OPReturnOutputSpec(
          dataChunks: [testData1],
          separateOutputs: true,
        );

        final map = original.toMap();
        expect(map['separateOutputs'], isTrue);

        final restored = InvoiceOutputSpec.fromMap(map) as OPReturnOutputSpec;
        expect(restored.separateOutputs, isTrue);
      });

      test('separateOutputs=false is omitted from map', () {
        final output = OPReturnOutputSpec(
          dataChunks: [testData1],
          separateOutputs: false,
        );

        final map = output.toMap();
        expect(map.containsKey('separateOutputs'), isFalse);
      });

      test('equality distinguishes separateOutputs', () {
        final concat = OPReturnOutputSpec(
          dataChunks: [testData1],
          separateOutputs: false,
        );
        final separate = OPReturnOutputSpec(
          dataChunks: [testData1],
          separateOutputs: true,
        );

        expect(concat, isNot(equals(separate)));
      });

      test('toString provides readable output', () {
        final output = OPReturnOutputSpec(
          dataChunks: [testData1, testData2],
          label: 'Test',
        );

        final str = output.toString();
        expect(str, contains('chunks: 2'));
        expect(str, contains('totalBytes:'));
        expect(str, contains('label: Test'));
      });
    });

    group('Mixed outputs', () {
      final validPubKey1 =
          '0335cd55d33889f942e8c445cf4d9e9488a3be4bc4d4e91ccc9b57dcaa49c0f7a8';
      final validPubKey2 =
          '028f10cd0e0e9bc7352adb192484d576867a71cbd82295cd87c3ceffc5fbd74acc';

      test('can create list of mixed P2PKH and P2MS outputs', () {
        final outputs = <InvoiceOutputSpec>[
          P2PKHOutputSpec(
            address: 'mPaymentAddr',
            amount: BigInt.from(10000),
            label: 'Payment',
          ),
          P2PKHOutputSpec(
            address: 'mFeeAddr',
            amount: BigInt.from(5000),
            label: 'Fee',
          ),
          P2MSOutputSpec(
            publicKeys: [validPubKey1, validPubKey2],
            threshold: 2,
            amount: BigInt.from(50000),
            label: 'Escrow',
          ),
        ];

        expect(outputs.length, equals(3));
        expect(outputs[0], isA<P2PKHOutputSpec>());
        expect(outputs[1], isA<P2PKHOutputSpec>());
        expect(outputs[2], isA<P2MSOutputSpec>());

        // Calculate total amount
        final totalAmount = outputs.fold<BigInt>(
          BigInt.zero,
          (sum, o) => sum + o.amount,
        );
        expect(totalAmount, equals(BigInt.from(65000)));
      });

      test('can serialize and deserialize list of mixed outputs', () {
        final originalOutputs = <InvoiceOutputSpec>[
          P2PKHOutputSpec(
            address: 'mAddr1',
            amount: BigInt.from(1000),
          ),
          P2MSOutputSpec(
            publicKeys: [validPubKey1, validPubKey2],
            threshold: 1,
            amount: BigInt.from(2000),
          ),
        ];

        // Serialize
        final serialized = originalOutputs.map((o) => o.toMap()).toList();

        // Deserialize
        final restored = serialized
            .map((m) => InvoiceOutputSpec.fromMap(m))
            .toList();

        expect(restored.length, equals(2));
        expect(restored[0], isA<P2PKHOutputSpec>());
        expect(restored[1], isA<P2MSOutputSpec>());
        expect(restored[0].amount, equals(BigInt.from(1000)));
        expect(restored[1].amount, equals(BigInt.from(2000)));
      });

      test('pattern matching with sealed class works', () {
        final outputs = <InvoiceOutputSpec>[
          P2PKHOutputSpec(address: 'mAddr', amount: BigInt.from(1000)),
          P2MSOutputSpec(
            publicKeys: [validPubKey1, validPubKey2],
            threshold: 2,
            amount: BigInt.from(2000),
          ),
          OPReturnOutputSpec(
            dataChunks: [utf8.encode('test data')],
          ),
        ];

        final results = <String>[];

        for (final output in outputs) {
          switch (output) {
            case P2PKHOutputSpec p2pkh:
              results.add('P2PKH: ${p2pkh.address}');
            case P2MSOutputSpec p2ms:
              results.add('P2MS: ${p2ms.threshold}-of-${p2ms.totalKeys}');
            case OPReturnOutputSpec opReturn:
              results.add('OP_RETURN: ${opReturn.dataChunks.length} chunks');
          }
        }

        expect(results[0], equals('P2PKH: mAddr'));
        expect(results[1], equals('P2MS: 2-of-2'));
        expect(results[2], equals('OP_RETURN: 1 chunks'));
      });
    });

    group('Error handling', () {
      test('fromMap throws for unknown type', () {
        final map = {
          'type': 'p2sh', // Not supported yet
          'amount': '1000',
        };

        expect(
          () => InvoiceOutputSpec.fromMap(map),
          throwsA(isA<ArgumentError>()),
        );
      });
    });
  });
}
