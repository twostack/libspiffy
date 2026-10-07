import 'package:spiffynode/spiffy_node.dart' show Peer;

/// [peers] in the order header sync asks them: the highest height a peer
/// reported in its version handshake first, and a peer that reported none
/// last, keeping the given order among equals.
///
/// Header sync sends each `getheaders` to one peer. It used to be the first
/// connected, and once every address of a DNS seed is dialled that can be a
/// node stuck far behind the tip (a mainnet seed listed one at height
/// 413,551 in 2026), which answers with nothing past its own height and
/// stalls the sync. A peer claiming a height it does not have costs a
/// request: its headers are checked like any other's.
List<P> inSyncOrder<P>(Iterable<P> peers, {int? Function(P peer)? reportedHeight}) {
  final heightOf = reportedHeight ?? handshakeHeight;
  final indexed = [
    for (final (i, p) in peers.indexed) (i, p, heightOf(p) ?? -1),
  ]..sort((a, b) => b.$3 != a.$3 ? b.$3.compareTo(a.$3) : a.$1.compareTo(b.$1));
  return [for (final e in indexed) e.$2];
}

/// The height [peer] reported in its version handshake; null for a peer
/// that reported none.
int? handshakeHeight(Object? peer) => peer is Peer ? peer.remoteVersion?.startHeight : null;

/// The network's tip as best we know it: the higher of the heights [peers]
/// reported in their handshake and [localHeight], our own chain's (blocks
/// mined after a peer connected are announced and fetched, so our chain
/// passes its handshake height). 0 when no peer reported a height, so a
/// caller can tell "unknown" from "caught up".
int networkHeightOf(Iterable<Object?> peers, int localHeight) {
  var reported = 0;
  for (final peer in peers) {
    final height = handshakeHeight(peer) ?? 0;
    if (height > reported) reported = height;
  }
  if (reported == 0) return 0;
  return reported > localHeight ? reported : localHeight;
}
