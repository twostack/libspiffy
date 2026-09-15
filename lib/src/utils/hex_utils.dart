import 'dart:typed_data';

import 'package:convert/convert.dart';

/// Convert a hex string to bytes.
///
/// Strips an optional '0x' prefix before parsing.
Uint8List hexToBytes(String hexString) {
  final cleanHex = hexString.replaceAll('0x', '');
  final bytes = <int>[];
  for (var i = 0; i < cleanHex.length; i += 2) {
    bytes.add(int.parse(cleanHex.substring(i, i + 2), radix: 16));
  }
  return Uint8List.fromList(bytes);
}

/// Convert a list of bytes to a lowercase hex string.
String bytesToHex(List<int> bytes) {
  return bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join('');
}

/// Reverse the byte-order of a hex string.
///
/// Converts between display format (big-endian) and internal format
/// (little-endian) as used throughout Bitcoin data structures.
///
/// Throws if [hexString] has an odd number of characters. The one
/// hex-string reversal in the library (`CryptoUtils.reverseBytes` forwards
/// here).
String reverseHexBytes(String hexString) {
  if (hexString.length % 2 != 0) {
    throw Exception('Hex string must have an even number of characters: $hexString');
  }

  final result = StringBuffer();
  for (int i = hexString.length - 2; i >= 0; i -= 2) {
    result.write(hexString.substring(i, i + 2));
  }
  return result.toString();
}

/// [bytes] in reverse order (a new list).
///
/// Converts a hash between internal (little-endian) and display
/// (big-endian) byte order.
Uint8List reverseBytes(List<int> bytes) {
  final out = Uint8List(bytes.length);
  for (var i = 0, j = bytes.length - 1; j >= 0; i++, j--) {
    out[i] = bytes[j];
  }
  return out;
}

/// Internal-order bytes of a display-order hex hash (txid, block hash,
/// merkle root). Throws [FormatException] when [displayHex] is not hex.
Uint8List displayToInternal(String displayHex) => reverseBytes(hex.decode(displayHex));

/// Display-order hex of an internal-order hash.
String internalToDisplay(List<int> internal) => hex.encode(reverseBytes(internal));

/// Whether [a] and [b] hold the same bytes.
bool bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
