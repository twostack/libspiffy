import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

/// Where the wallet asks for the merkle proof of a transaction it holds but
/// that its broadcaster never heard of: a payment the payee broadcast
/// through another service (spiffyvault-ri8). A broadcaster answers only
/// for what was submitted to it; a node holds every block.
///
/// The answer is a lead, never evidence: the wallet confirms only when the
/// proof matches a header it stores (`checkBumpHexAgainstHeaders`).
abstract interface class MerkleProofSource {
  /// The merkle path (BUMP, BRC-74) of [txid] as hex, or null when the
  /// source holds none: the transaction is not mined, or not known to it.
  /// Throws when the source cannot be asked.
  Future<String?> merkleProofHex(String txid);
}

/// A Teranode node's asset service: `GET {baseUrl}/merkle_proof/{txid}/hex`
/// answers the BUMP of the block that mined [txid], from the txid alone.
///
/// Not every node exposes the route: the BSV Association's testnet hubs
/// answer 404 for it, GorillaPool's testnet node serves it.
class TeranodeMerkleProofSource implements MerkleProofSource {
  static final Logger _log = Logger('TeranodeMerkleProofSource');

  /// GorillaPool's testnet Teranode asset service.
  static const String gorillaPoolTestnet = 'https://testnet.gorillanode.io/api/v1';

  static final RegExp _hex = RegExp(r'^(?:[0-9a-fA-F]{2})+$');

  /// The asset service's API root, without a trailing slash.
  final String baseUrl;
  final http.Client _client;
  final Duration _requestTimeout;

  TeranodeMerkleProofSource({
    required String baseUrl,
    http.Client? client,
    Duration requestTimeout = const Duration(seconds: 20),
  })  : baseUrl = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl,
        _client = client ?? http.Client(),
        _requestTimeout = requestTimeout;

  @override
  Future<String?> merkleProofHex(String txid) async {
    final response =
        await _client.get(Uri.parse('$baseUrl/merkle_proof/$txid/hex')).timeout(_requestTimeout);
    // A transaction the node does not hold is answered 500 ("subtree ...
    // does not exist"), not 404: any answer but 200 is "no proof".
    if (response.statusCode != 200) {
      _log.fine('No merkle proof for $txid at $baseUrl (${response.statusCode})');
      return null;
    }
    final body = response.body.trim();
    if (!_hex.hasMatch(body)) {
      _log.warning('The merkle proof of $txid from $baseUrl is not hex; ignored');
      return null;
    }
    return body.toLowerCase();
  }
}
