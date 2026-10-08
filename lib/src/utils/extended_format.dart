import 'dart:typed_data';

import 'package:buffer/buffer.dart';
import 'package:convert/convert.dart';
import 'package:dartsv/dartsv.dart' as dartsv;

import '../spv/merkle.dart' as merkle;

/// Extended Format (BRC-30): a transaction whose every input carries the
/// satoshis and locking script of the output it spends.
///
/// ARC checks an extended transaction without looking up its parents. Sent
/// raw, a transaction spending a coin from a block ARC never saw, or from a
/// transaction it was never sent, is refused with 460, "parent transaction
/// not found".
class ExtendedFormat {
  ExtendedFormat._();

  static const _marker = [0, 0, 0, 0, 0, 0xEF];

  /// The txids (display order, hex) of the transactions [rawTx] spends, one
  /// per input.
  static List<String> spentTxids(Uint8List rawTx) {
    final reader = ByteDataReader()..add(rawTx);
    reader.read(4);
    final inputCount = dartsv.readVarIntNum(reader);
    final txids = <String>[];
    for (var i = 0; i < inputCount; i++) {
      txids.add(hex.encode(reader.read(32).reversed.toList()));
      reader.read(4);
      reader.read(dartsv.readVarIntNum(reader));
      reader.read(4);
    }
    return txids;
  }

  /// [rawTx] in Extended Format, the outputs its inputs spend read from
  /// [sources] (raw transactions by txid). Null when a source is missing,
  /// is not the transaction its txid names, or lacks the output spent.
  static Uint8List? encode(Uint8List rawTx, Map<String, Uint8List> sources) {
    final reader = ByteDataReader()..add(rawTx);
    final out = BytesBuilder(copy: false)
      ..add(reader.read(4))
      ..add(_marker);
    final inputCount = dartsv.readVarIntNum(reader);
    out.add(dartsv.VarInt.fromInt(inputCount).encode());
    for (var i = 0; i < inputCount; i++) {
      final prevTxid = reader.read(32);
      final voutBytes = reader.read(4);
      final scriptLength = dartsv.readVarIntNum(reader);
      final script = reader.read(scriptLength);
      final sequence = reader.read(4);
      final txid = hex.encode(prevTxid.reversed.toList());
      final source = sources[txid];
      if (source == null || hex.encode(merkle.txidDisplayBytes(source)) != txid) return null;
      final vout = ByteData.sublistView(Uint8List.fromList(voutBytes)).getUint32(0, Endian.little);
      final spent = _output(source, vout);
      if (spent == null) return null;
      out
        ..add(prevTxid)
        ..add(voutBytes)
        ..add(dartsv.VarInt.fromInt(scriptLength).encode())
        ..add(script)
        ..add(sequence)
        ..add(spent);
    }
    // The outputs and lock time are as in the raw transaction.
    out.add(reader.read(reader.remainingLength));
    return out.toBytes();
  }

  /// Whether [tx] is in Extended Format: its marker follows the version.
  static bool isExtended(Uint8List tx) {
    if (tx.length < 10) return false;
    for (var i = 0; i < _marker.length; i++) {
      if (tx[4 + i] != _marker[i]) return false;
    }
    return true;
  }

  /// The raw transaction of [tx] (hex), which may be extended: what a
  /// service that accepts both reads it as. Anything else is returned as
  /// given.
  static String rawHexOf(String tx) {
    final bytes = Uint8List.fromList(hex.decode(tx));
    if (!isExtended(bytes)) return tx;
    final reader = ByteDataReader()..add(bytes);
    final out = BytesBuilder(copy: false)..add(reader.read(4));
    reader.read(_marker.length);
    final inputCount = dartsv.readVarIntNum(reader);
    out.add(dartsv.VarInt.fromInt(inputCount).encode());
    for (var i = 0; i < inputCount; i++) {
      out.add(reader.read(36));
      final scriptLength = dartsv.readVarIntNum(reader);
      out
        ..add(dartsv.VarInt.fromInt(scriptLength).encode())
        ..add(reader.read(scriptLength))
        ..add(reader.read(4));
      // The spent output's satoshis and locking script.
      reader.read(8);
      reader.read(dartsv.readVarIntNum(reader));
    }
    out.add(reader.read(reader.remainingLength));
    return hex.encode(out.toBytes());
  }

  /// Output [vout] of [rawTx] as serialized (satoshis, script length,
  /// script), or null when it has no such output.
  static Uint8List? _output(Uint8List rawTx, int vout) {
    final reader = ByteDataReader()..add(rawTx);
    reader.read(4);
    final inputCount = dartsv.readVarIntNum(reader);
    for (var i = 0; i < inputCount; i++) {
      reader.read(36);
      reader.read(dartsv.readVarIntNum(reader));
      reader.read(4);
    }
    final outputCount = dartsv.readVarIntNum(reader);
    if (vout >= outputCount) return null;
    for (var i = 0; i < outputCount; i++) {
      final satoshis = reader.read(8);
      final scriptLength = dartsv.readVarIntNum(reader);
      final script = reader.read(scriptLength);
      if (i == vout) {
        return (BytesBuilder(copy: false)
              ..add(satoshis)
              ..add(dartsv.VarInt.fromInt(scriptLength).encode())
              ..add(script))
            .toBytes();
      }
    }
    return null;
  }
}
