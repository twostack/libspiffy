import 'dart:convert';
import 'dart:typed_data';

import 'package:dartsv/dartsv.dart';
import 'package:test/test.dart';
import 'package:libspiffy/src/services/transaction/builder/op_return_lockbuilder.dart';

void main() {
  group('OpReturnLockBuilder', () {
    test('produces script starting with OP_FALSE OP_RETURN', () {
      final builder = OpReturnLockBuilder([utf8.encode('test')]);
      final script = builder.getScriptPubkey();
      final chunks = script.chunks;

      expect(chunks.length, greaterThanOrEqualTo(2));
      expect(chunks[0].opcodenum, equals(OpCodes.OP_FALSE));
      expect(chunks[1].opcodenum, equals(OpCodes.OP_RETURN));
    });

    test('encodes single data chunk correctly', () {
      final data = utf8.encode('Hello, world!');
      final builder = OpReturnLockBuilder([data]);
      final script = builder.getScriptPubkey();
      final chunks = script.chunks;

      // OP_FALSE, OP_RETURN, <data>
      expect(chunks.length, equals(3));
      expect(chunks[2].buf, equals(Uint8List.fromList(data)));
    });

    test('encodes multiple data chunks correctly', () {
      final chunk1 = utf8.encode('chunk one');
      final chunk2 = utf8.encode('chunk two');
      final chunk3 = utf8.encode('chunk three');
      final builder = OpReturnLockBuilder([chunk1, chunk2, chunk3]);
      final script = builder.getScriptPubkey();
      final chunks = script.chunks;

      // OP_FALSE, OP_RETURN, <chunk1>, <chunk2>, <chunk3>
      expect(chunks.length, equals(5));
      expect(chunks[2].buf, equals(Uint8List.fromList(chunk1)));
      expect(chunks[3].buf, equals(Uint8List.fromList(chunk2)));
      expect(chunks[4].buf, equals(Uint8List.fromList(chunk3)));
    });

    test('handles empty data chunks list', () {
      final builder = OpReturnLockBuilder([]);
      final script = builder.getScriptPubkey();
      final chunks = script.chunks;

      // Just OP_FALSE, OP_RETURN
      expect(chunks.length, equals(2));
    });

    test('handles binary data (non-UTF8)', () {
      final binaryData = [0x00, 0xFF, 0xDE, 0xAD, 0xBE, 0xEF];
      final builder = OpReturnLockBuilder([binaryData]);
      final script = builder.getScriptPubkey();
      final chunks = script.chunks;

      expect(chunks.length, equals(3));
      expect(chunks[2].buf, equals(Uint8List.fromList(binaryData)));
    });

    test('parse recovers data chunks from script', () {
      final original = OpReturnLockBuilder([
        utf8.encode('first'),
        utf8.encode('second'),
      ]);
      final script = original.getScriptPubkey();

      final parsed = OpReturnLockBuilder.fromScript(script);

      expect(parsed.dataChunks.length, equals(2));
      expect(utf8.decode(parsed.dataChunks[0]), equals('first'));
      expect(utf8.decode(parsed.dataChunks[1]), equals('second'));
    });

    test('parse throws for script not starting with OP_FALSE OP_RETURN', () {
      // Build a P2PKH-like script
      final scriptBuilder = ScriptBuilder();
      scriptBuilder.opCode(OpCodes.OP_DUP).opCode(OpCodes.OP_HASH160);
      final script = scriptBuilder.build();

      expect(
        () => OpReturnLockBuilder.fromScript(script),
        throwsA(isA<ScriptException>()),
      );
    });

    test('parse throws for script with fewer than 2 chunks', () {
      final scriptBuilder = ScriptBuilder();
      scriptBuilder.opFalse();
      final script = scriptBuilder.build();

      expect(
        () => OpReturnLockBuilder.fromScript(script),
        throwsA(isA<ScriptException>()),
      );
    });

    test('roundtrip build and parse preserves data', () {
      final data = [
        utf8.encode('protocol:v1'),
        [0xCA, 0xFE, 0xBA, 0xBE],
        utf8.encode('metadata'),
      ];
      final builder = OpReturnLockBuilder(data);
      final script = builder.getScriptPubkey();
      final parsed = OpReturnLockBuilder.fromScript(script);

      expect(parsed.dataChunks.length, equals(3));
      expect(utf8.decode(parsed.dataChunks[0]), equals('protocol:v1'));
      expect(parsed.dataChunks[1], equals([0xCA, 0xFE, 0xBA, 0xBE]));
      expect(utf8.decode(parsed.dataChunks[2]), equals('metadata'));
    });
  });
}
