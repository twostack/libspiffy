import 'dart:io';

/// One address P2P dials, and the peer entry it came from.
class PeerAddress {
  final String host;
  final int port;

  /// The `host:port` entry this address was resolved from; the same as
  /// [endpoint] for an entry that named an address.
  final String source;

  const PeerAddress(this.host, this.port, this.source);

  String get endpoint => '$host:$port';

  /// The address as a failure names it: with the seed it came from, when it
  /// came from one.
  String get label => source == endpoint ? endpoint : '$endpoint (from $source)';

  @override
  bool operator ==(Object other) => other is PeerAddress && other.host == host && other.port == port;

  @override
  int get hashCode => Object.hash(host, port);
}

/// Peer entries (`host:port`) turned into the addresses P2P dials.
///
/// A DNS seed is a name for many nodes, and at any time some of them are
/// dead or accept a connection and never answer. Dialling the name reaches
/// whichever address the resolver lists first, so a seed with live nodes
/// still failed whenever that one was down. Each name is therefore resolved
/// to every address it holds, and each address is its own peer.
class PeerAddresses {
  /// The addresses to dial, in the order the entries named them, each once.
  final List<PeerAddress> addresses;

  /// Entries that yielded no address, with the reason.
  final Map<String, String> failures;

  const PeerAddresses._(this.addresses, this.failures);

  /// Resolves [entries]; [lookup] is the resolver, replaceable in tests.
  static Future<PeerAddresses> resolve(
    List<String> entries, {
    Future<List<InternetAddress>> Function(String host) lookup = InternetAddress.lookup,
  }) async {
    final resolved = await Future.wait(entries.map((entry) => _resolve(entry, lookup)));
    final addresses = <PeerAddress>{};
    final failures = <String, String>{};
    for (int i = 0; i < entries.length; i++) {
      final (found, failure) = resolved[i];
      if (failure != null) {
        failures[entries[i]] = failure;
      } else {
        addresses.addAll(found);
      }
    }
    return PeerAddresses._(addresses.toList(), failures);
  }

  static Future<(List<PeerAddress>, String?)> _resolve(
      String entry, Future<List<InternetAddress>> Function(String) lookup) async {
    final colon = entry.lastIndexOf(':');
    final port = colon < 0 ? null : int.tryParse(entry.substring(colon + 1));
    final host = colon < 0 ? '' : entry.substring(0, colon);
    if (host.isEmpty || port == null || port <= 0 || port > 65535) {
      return (const <PeerAddress>[], 'not host:port');
    }
    if (InternetAddress.tryParse(host) != null) return ([PeerAddress(host, port, entry)], null);
    try {
      final found = await lookup(host);
      if (found.isEmpty) return (const <PeerAddress>[], 'the name resolves to no address');
      return ([for (final a in found) PeerAddress(a.address, port, entry)], null);
    } on SocketException catch (e) {
      return (const <PeerAddress>[], 'the name does not resolve: ${e.osError?.message ?? e.message}');
    }
  }
}
