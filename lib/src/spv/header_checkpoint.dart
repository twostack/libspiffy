/// A window of recent block headers shipped with an app, so a fresh install
/// starts its header chain at a checkpoint instead of at genesis (epic
/// spiffyvault-emk).
library;

import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:spiffynode/spiffy_node.dart';

import 'block_header_chain.dart' show BlockHeaderAnchor;
import 'network_params.dart';

/// The newest headers of one network at the time an app was released.
///
/// The lowest header is the checkpoint: a fresh install anchors its
/// [BlockHeaderChain] there ([anchor]) and holds every header of the window
/// at once, so it only has to catch up from [tipHeight] to the network's tip
/// before it can check payments. Headers below the checkpoint are filled in
/// later (spiffyvault-emk.3).
///
/// The window is trusted as the genesis block is: it ships inside the app.
/// [decode] still checks it is whole: every header meets its own proof of
/// work, and the last header hashes to the hash written after it.
///
/// File layout (`.svhc`, little-endian integers):
///
/// | bytes            | content                                         |
/// |------------------|-------------------------------------------------|
/// | 4                | `SVHC`                                          |
/// | 1                | format version (1)                              |
/// | 1                | length N of the network name                    |
/// | N                | network name (`mainnet`, `testnet`, `regtest`)  |
/// | 4                | height of the first header                      |
/// | 4                | number of headers                               |
/// | 80               | the first header, whole                         |
/// | 48 × (count − 1) | each later header without `prevBlock`           |
/// | 32               | hash of the last header (wire byte order)       |
///
/// `prevBlock` is the hash of the header before, so it is rebuilt rather
/// than stored: 48 bytes a header instead of 80 (about 9.6 MB for 200,000).
class HeaderCheckpoint {
  /// Canonical network name ([NetworkParams.name]).
  final String network;

  /// Height of [headers].first: the checkpoint.
  final int startHeight;

  /// The window, oldest first, each linking to the one before.
  final List<BlockHeader> headers;

  HeaderCheckpoint._(this.network, this.startHeight, this.headers);

  /// The anchor a chain seeded from this window uses: its lowest header.
  BlockHeaderAnchor get anchor => BlockHeaderAnchor(headers.first, startHeight);

  /// Height of the newest header.
  int get tipHeight => startHeight + headers.length - 1;

  static const List<int> _magic = [0x53, 0x56, 0x48, 0x43]; // SVHC
  static const int _formatVersion = 1;
  static const int _fullHeader = 80;
  static const int _compactHeader = 48;
  static const int _hashLength = 32;

  /// Encodes [headers] (oldest first, at [startHeight] on [network]).
  ///
  /// Throws [ArgumentError] when the headers do not link one to the next:
  /// a window that would not decode is never written.
  static Uint8List encode(String network, int startHeight, List<BlockHeader> headers) {
    if (headers.isEmpty) throw ArgumentError.value(headers, 'headers', 'is empty');
    if (startHeight < 0) throw ArgumentError.value(startHeight, 'startHeight', 'is negative');
    final name = utf8.encode(network);
    if (name.isEmpty || name.length > 255) throw ArgumentError.value(network, 'network');

    final out = BytesBuilder(copy: false);
    final head = ByteData(4 + 1 + 1);
    for (var i = 0; i < 4; i++) {
      head.setUint8(i, _magic[i]);
    }
    head.setUint8(4, _formatVersion);
    head.setUint8(5, name.length);
    out.add(head.buffer.asUint8List());
    out.add(name);
    final range = ByteData(8)
      ..setUint32(0, startHeight, Endian.little)
      ..setUint32(4, headers.length, Endian.little);
    out.add(range.buffer.asUint8List());

    var previous = headers.first.serialize();
    out.add(previous);
    var previousHash = _sha256d(previous);
    for (var i = 1; i < headers.length; i++) {
      final bytes = headers[i].serialize();
      if (!_equal(Uint8List.sublistView(bytes, 4, 36), previousHash)) {
        throw ArgumentError('the header at height ${startHeight + i} does not link to the one before it');
      }
      out.add(Uint8List.sublistView(bytes, 0, 4));
      out.add(Uint8List.sublistView(bytes, 36, 80));
      previous = bytes;
      previousHash = _sha256d(bytes);
    }
    out.add(previousHash);
    return out.takeBytes();
  }

  /// Reads only the checkpoint ([anchor]) and the window's range, without
  /// rebuilding or checking the headers: what a start with a header store
  /// already in place needs.
  static ({BlockHeaderAnchor anchor, int tipHeight}) readAnchor(Uint8List bytes, NetworkParams params) {
    final (startHeight, count, offset) = _readHead(bytes, params);
    final first = BlockHeader.deserialize(Uint8List.sublistView(bytes, offset, offset + _fullHeader));
    return (anchor: BlockHeaderAnchor(first, startHeight), tipHeight: startHeight + count - 1);
  }

  /// [decode] on another isolate: rebuilding and checking 200,000 headers
  /// takes a second or more on a phone.
  static Future<HeaderCheckpoint> load(Uint8List bytes, NetworkParams params) =>
      Isolate.run(() => decode(bytes, params));

  /// Rebuilds the window and checks it: the network matches [params], every
  /// header meets its own proof of work, and the last one hashes to the hash
  /// the file ends with. A window starting at height 0 must start with the
  /// network's genesis block.
  ///
  /// Throws [FormatException] for anything else.
  static HeaderCheckpoint decode(Uint8List bytes, NetworkParams params) {
    final (startHeight, count, offset) = _readHead(bytes, params);
    final expectedLength = offset + _fullHeader + _compactHeader * (count - 1) + _hashLength;
    if (bytes.length != expectedLength) {
      throw FormatException('a window of $count headers is $expectedLength bytes, not ${bytes.length}');
    }

    final headers = <BlockHeader>[];
    final full = Uint8List(_fullHeader);
    full.setRange(0, _fullHeader, bytes, offset);
    var at = offset + _fullHeader;
    for (var i = 0; i < count; i++) {
      if (i > 0) {
        // version, then the previous header's hash, then the rest.
        full.setRange(0, 4, bytes, at);
        full.setRange(36, _fullHeader, bytes, at + 4);
        at += _compactHeader;
      }
      final header = BlockHeader.deserialize(Uint8List.fromList(full));
      final hash = _sha256d(full);
      final height = startHeight + i;
      final hashHex = _displayHex(hash);
      if (height == 0 && hashHex != params.genesisHash) {
        throw FormatException('the window starts at height 0 with $hashHex, not the ${params.name} genesis block');
      }
      final pow = params.checkProofOfWork(header.bits, hashHex);
      if (pow.failure != null) {
        throw FormatException('the header at height $height fails its proof of work (${pow.failure!.name})');
      }
      headers.add(header);
      full.setRange(4, 36, hash);
    }

    final tipHash = Uint8List.sublistView(bytes, at, at + _hashLength);
    if (!_equal(tipHash, Uint8List.sublistView(full, 4, 36))) {
      throw const FormatException('the last header does not hash to the hash the window ends with');
    }
    return HeaderCheckpoint._(params.name, startHeight, headers);
  }

  /// (start height, count, offset of the first header).
  static (int, int, int) _readHead(Uint8List bytes, NetworkParams params) {
    if (bytes.length < 6) throw const FormatException('not a header window: too short');
    for (var i = 0; i < 4; i++) {
      if (bytes[i] != _magic[i]) throw const FormatException('not a header window: no SVHC mark');
    }
    if (bytes[4] != _formatVersion) {
      throw FormatException('header window format ${bytes[4]} is not supported');
    }
    final nameLength = bytes[5];
    final offset = 6 + nameLength + 8;
    if (bytes.length < offset + _fullHeader + _hashLength) {
      throw const FormatException('not a header window: too short');
    }
    final network = utf8.decode(Uint8List.sublistView(bytes, 6, 6 + nameLength));
    if (network != params.name) {
      throw FormatException('the header window is for $network, not ${params.name}');
    }
    final range = ByteData.sublistView(bytes, 6 + nameLength, offset);
    final startHeight = range.getUint32(0, Endian.little);
    final count = range.getUint32(4, Endian.little);
    if (count == 0) throw const FormatException('the header window is empty');
    return (startHeight, count, offset);
  }

  static Uint8List _sha256d(List<int> data) =>
      Uint8List.fromList(crypto.sha256.convert(crypto.sha256.convert(data).bytes).bytes);

  /// A hash in wire byte order, as the reversed hex block explorers show.
  static String _displayHex(Uint8List hash) {
    final sb = StringBuffer();
    for (var i = hash.length - 1; i >= 0; i--) {
      sb.write(hash[i].toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  static bool _equal(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
