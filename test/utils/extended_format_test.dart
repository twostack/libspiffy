/// Extended Format (BRC-30), the form ARC is sent a transaction in when its
/// parents are at hand: checked against dartsv's own reading of the real
/// testnet fixture (kFixture2 spends output 1 of kFixture).
library;

import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:libspiffy/src/utils/extended_format.dart';
import 'package:test/test.dart';

import '../spv/testnet_proof_fixture.dart';

Uint8List _bytes(String h) => Uint8List.fromList(hex.decode(h));

void main() {
  final child = _bytes(kFixture2TxHex);
  final parent = _bytes(kFixtureTxHex);

  test('names the transactions a transaction spends', () {
    final tx = dartsv.Transaction.fromHex(kFixture2TxHex);
    expect(ExtendedFormat.spentTxids(child), [for (final i in tx.inputs) i.prevTxnId]);
    expect(ExtendedFormat.spentTxids(child), contains(kFixtureTxid));
  });

  test('each input carries the satoshis and locking script of the output it spends', () {
    final tx = dartsv.Transaction.fromHex(kFixture2TxHex);
    expect(tx.inputs, hasLength(1), reason: 'the fixture has one input');
    final input = tx.inputs.single;
    final spent = dartsv.Transaction.fromHex(kFixtureTxHex).outputs[input.prevTxnOutputIndex];

    final ef = ExtendedFormat.encode(child, {kFixtureTxid: parent})!;

    final expected = BytesBuilder()
      ..add(child.sublist(0, 4))
      ..add(const [0, 0, 0, 0, 0, 0xEF])
      ..add(dartsv.VarInt.fromInt(1).encode())
      ..add(input.serialize())
      ..add((ByteData(8)..setUint64(0, spent.satoshis.toInt(), Endian.little)).buffer.asUint8List())
      ..add(dartsv.VarInt.fromInt(spent.script.buffer.length).encode())
      ..add(spent.script.buffer);
    // The outputs and lock time follow, as in the raw transaction.
    final rawInputEnd = 4 + 1 + input.serialize().length;
    expected.add(child.sublist(rawInputEnd));
    expect(hex.encode(ef), hex.encode(expected.toBytes()));
  });

  test('read back as the raw transaction it extends', () {
    final ef = ExtendedFormat.encode(child, {kFixtureTxid: parent})!;
    expect(ExtendedFormat.isExtended(ef), isTrue);
    expect(ExtendedFormat.isExtended(child), isFalse);
    expect(ExtendedFormat.rawHexOf(hex.encode(ef)), kFixture2TxHex);
    expect(ExtendedFormat.rawHexOf(kFixture2TxHex), kFixture2TxHex);
  });

  test('no extended form without the transaction an input spends', () {
    expect(ExtendedFormat.encode(child, const {}), isNull);
  });

  test('a source that is not the transaction its txid names is not used', () {
    expect(ExtendedFormat.encode(child, {kFixtureTxid: child}), isNull);
  });
}
