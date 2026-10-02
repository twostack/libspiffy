/// The BEEF formats BRC-100 wallets exchange: BEEF V2 (BRC-96) and Atomic
/// BEEF (BRC-95), read into and written from libspiffy's V1 [BEEF].
library;

import 'dart:typed_data';

import 'package:buffer/buffer.dart';
import 'package:convert/convert.dart';
import 'package:dartsv/dartsv.dart' as dartsv hide BlockHeader;

import '../spv/merkle.dart' as merkle;
import 'beef.dart';
import 'bump.dart';

/// BEEF V2's magic and version, `0200BEEF` (BRC-96).
const int beefV2MagicAndVersion = 0x0200BEEF;

/// Atomic BEEF's prefix, `01010101` (BRC-95).
const int atomicBeefPrefix = 0x01010101;

/// A BEEF as BRC-100 wallets send it, read into a V1 [beef]; [subjectTxid]
/// (display hex) is the transaction an Atomic BEEF is about, null for a
/// bare BEEF.
typedef ReadBeef = ({BEEF beef, String? subjectTxid});

/// Reading and writing the BEEF forms of BRC-62, BRC-95 and BRC-96.
///
/// Everything inside libspiffy stays BEEF V1; these convert at the edge.
class Brc95 {
  Brc95._();

  /// Reads a BEEF V1, a BEEF V2, or an Atomic BEEF wrapping either, as a V1
  /// [BEEF]. Throws [BEEFException] for anything malformed, for a V2
  /// transaction given by txid only (nothing here can verify one), and for
  /// an Atomic BEEF whose subject is not among its transactions.
  static ReadBeef read(List<int> data) {
    final bytes = Uint8List.fromList(data);
    if (bytes.length >= 4 && _magic(bytes, 0) == atomicBeefPrefix) {
      if (bytes.length < 36) throw BEEFException('Atomic BEEF is too short to name its subject');
      final subject = hex.encode(bytes.sublist(4, 36).reversed.toList());
      final beef = _readBeef(bytes.sublist(36));
      if (beef.findTransactionByTxid(Uint8List.fromList(hex.decode(subject))) == null) {
        throw BEEFException('Atomic BEEF subject $subject is not among its transactions');
      }
      return (beef: beef, subjectTxid: subject);
    }
    return (beef: _readBeef(bytes), subjectTxid: null);
  }

  static BEEF _readBeef(Uint8List bytes) {
    if (bytes.length >= 4 && _magic(bytes, 0) == beefV2MagicAndVersion) {
      try {
        return _readV2(bytes);
      } on BEEFException {
        rethrow;
      } catch (e) {
        throw BEEFException('Malformed BEEF V2: $e');
      }
    }
    return BEEF.parse(bytes);
  }

  /// V2: `0200BEEF ‖ nBumps ‖ BUMPs ‖ nTxs ‖` per transaction a format byte
  /// then `rawTx` (0), `bumpIndex ‖ rawTx` (1) or a txid (2). Rewritten as
  /// V1 and parsed by [BEEF.parse], so it is checked the same way.
  static BEEF _readV2(Uint8List bytes) {
    final reader = ByteDataReader()..add(bytes);
    reader.read(4);
    final nBumps = dartsv.readVarIntNum(reader);
    final bumps = [for (var i = 0; i < nBumps; i++) BUMP.parse(reader)];
    final nTxs = dartsv.readVarIntNum(reader);
    final txs = <Uint8List>[];
    final hasMerkle = <bool>[];
    final bumpIndex = <int>[];
    for (var i = 0; i < nTxs; i++) {
      final format = reader.readUint8();
      switch (format) {
        case 0:
          txs.add(_rawTx(reader, bytes));
          hasMerkle.add(false);
        case 1:
          final index = dartsv.readVarIntNum(reader);
          if (index >= nBumps) throw BEEFException('Invalid BUMP index $index for tx $i: exceeds number of BUMPs');
          txs.add(_rawTx(reader, bytes));
          hasMerkle.add(true);
          bumpIndex.add(index);
        case 2:
          throw BEEFException('BEEF V2 transaction $i is given by txid only: it cannot be verified');
        default:
          throw BEEFException('BEEF V2 transaction $i has unknown format $format');
      }
    }
    if (reader.remainingLength != 0) {
      throw BEEFException('Invalid BEEF V2: ${reader.remainingLength} trailing byte(s) after the last transaction');
    }
    return BEEF.parse(
        BEEF.create(bumps: bumps, txs: txs, hasMerkle: hasMerkle, bumpIndex: bumpIndex).serialize());
  }

  // A transaction's bytes exactly as sent (re-serialising could change its
  // txid).
  static Uint8List _rawTx(ByteDataReader reader, Uint8List bytes) {
    final start = bytes.length - reader.remainingLength;
    dartsv.Transaction.fromBufferReader(reader);
    return bytes.sublist(start, bytes.length - reader.remainingLength);
  }

  /// [beef] as an Atomic BEEF about [subjectTxid] (display hex), wrapping
  /// V1 as the reference PeerPay sender does: `01010101 ‖ txid (internal
  /// byte order) ‖ BEEF`.
  ///
  /// BRC-100 readers take only a BEEF that holds the subject and its
  /// ancestors and nothing else, so this throws [BEEFException] when the
  /// subject is missing or another transaction is not one of its
  /// ancestors.
  static Uint8List wrap(BEEF beef, String subjectTxid) {
    final subject = subjectTxid.toLowerCase();
    final byTxid = <String, dartsv.Transaction>{
      for (final raw in beef.txs) hex.encode(merkle.txidDisplayBytes(raw)): dartsv.Transaction.fromHex(hex.encode(raw)),
    };
    if (!byTxid.containsKey(subject)) {
      throw BEEFException('The BEEF does not hold the subject $subject');
    }
    if (byTxid.length != beef.txs.length) {
      throw BEEFException('The BEEF holds a transaction twice');
    }
    final needed = <String>{};
    final pending = [subject];
    while (pending.isNotEmpty) {
      final txid = pending.removeLast();
      // A proven transaction's ancestors need not travel with it.
      if (!needed.add(txid) || beef.carriesProofOf(txid)) continue;
      for (final input in byTxid[txid]!.inputs) {
        if (byTxid.containsKey(input.prevTxnId)) pending.add(input.prevTxnId);
      }
    }
    final extra = byTxid.keys.where((txid) => !needed.contains(txid)).toList();
    if (extra.isNotEmpty) {
      throw BEEFException('The BEEF holds transactions the subject does not depend on: ${extra.join(', ')}');
    }
    final txid = hex.decode(subject).reversed;
    return Uint8List.fromList([1, 1, 1, 1, ...txid, ...beef.serialize()]);
  }

  static int _magic(Uint8List b, int at) => (b[at] << 24) | (b[at + 1] << 16) | (b[at + 2] << 8) | b[at + 3];
}
