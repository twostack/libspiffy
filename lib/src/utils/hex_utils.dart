import 'dart:typed_data';

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
/// Throws if [hexString] has an odd number of characters.
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
