import 'dart:io';

import 'package:libspiffy/src/integration/peer_addresses.dart';
import 'package:libspiffy/src/integration/sync_order.dart';
import 'package:libspiffy/src/spv/network_params.dart';
import 'package:spiffynode/spiffy_node.dart' show BitcoinNetwork, Peer;
import 'package:test/test.dart';

/// A seed is dialled at every address it holds, not at whichever the
/// resolver lists first, and header sync asks the peer furthest ahead.
void main() {
  Future<List<InternetAddress>> Function(String) resolver(Map<String, List<String>> names) => (host) async {
        final found = names[host];
        if (found == null) throw SocketException('Failed host lookup: \'$host\'', osError: const OSError('nodename nor servname provided, or not known', 8));
        return [for (final a in found) InternetAddress(a)];
      };

  group('PeerAddresses.resolve', () {
    test('a name becomes every address it holds, each labelled with the name', () async {
      final r = await PeerAddresses.resolve(['seed.example:18333'],
          lookup: resolver({
            'seed.example': ['3.123.101.88', '23.22.19.204', '54.152.215.212'],
          }));
      expect([for (final a in r.addresses) a.endpoint], ['3.123.101.88:18333', '23.22.19.204:18333', '54.152.215.212:18333']);
      expect(r.addresses.first.label, '3.123.101.88:18333 (from seed.example:18333)');
      expect(r.failures, isEmpty);
    });

    test('an address is dialled as it is, and not looked up', () async {
      final r = await PeerAddresses.resolve(['198.154.93.206:18333'], lookup: (h) => fail('looked up $h'));
      expect(r.addresses.single.endpoint, '198.154.93.206:18333');
      expect(r.addresses.single.label, '198.154.93.206:18333');
    });

    test('an address named twice, or by two seeds, is dialled once', () async {
      final r = await PeerAddresses.resolve(['a.example:18333', 'b.example:18333', '3.123.101.88:18333'],
          lookup: resolver({
            'a.example': ['3.123.101.88', '51.79.25.225'],
            'b.example': ['51.79.25.225'],
          }));
      expect([for (final a in r.addresses) a.endpoint], ['3.123.101.88:18333', '51.79.25.225:18333']);
    });

    test('an entry that yields nothing is a failure naming why, and the rest still resolve', () async {
      final r = await PeerAddresses.resolve(
          ['gone.example:18333', 'empty.example:18333', 'no-port', 'host:port', 'host:70000', ':18333', 'ok.example:18333'],
          lookup: resolver({
            'empty.example': [],
            'ok.example': ['76.214.114.66'],
          }));
      expect(r.addresses.single.endpoint, '76.214.114.66:18333');
      expect(r.failures.keys, ['gone.example:18333', 'empty.example:18333', 'no-port', 'host:port', 'host:70000', ':18333']);
      expect(r.failures['gone.example:18333'], contains('does not resolve'));
      expect(r.failures['empty.example:18333'], contains('no address'));
      expect(r.failures['no-port'], 'not host:port');
    });
  });

  group('the networks\' DNS seeds', () {
    test('mainnet starts from the seeds the Bitcoin SV node ships', () {
      expect(NetworkParams.mainnet.dnsSeeds,
          ['seed.bitcoinsv.io:8333', 'seed.satoshisvision.network:8333', 'seed.bitcoinseed.directory:8333']);
    });

    test('testnet starts from the node\'s seeds and GorillaPool\'s nodes, on the testnet port', () {
      expect(NetworkParams.testnet.dnsSeeds, contains('testnet-seed.bitcoinsv.io:18333'));
      expect(NetworkParams.testnet.dnsSeeds, contains('testnet.gorillapool.io:18333'));
      expect(NetworkParams.testnet.dnsSeeds.every((s) => s.endsWith(':18333')), isTrue);
    });

    test('regtest has none', () => expect(NetworkParams.regtest.dnsSeeds, isEmpty));
  });

  group('inSyncOrder', () {
    test('the highest reported height first, and a peer reporting none last', () {
      final heights = {'stuck': 413551, 'silent': null, 'tip': 968293, 'behind': 968290};
      expect(inSyncOrder(['stuck', 'silent', 'tip', 'behind'], reportedHeight: (p) => heights[p]),
          ['tip', 'behind', 'stuck', 'silent']);
    });

    test('equals keep the order they came in', () {
      expect(inSyncOrder(['a', 'b', 'c'], reportedHeight: (_) => 7), ['a', 'b', 'c']);
      expect(inSyncOrder(['a', 'b', 'c'], reportedHeight: (_) => null), ['a', 'b', 'c']);
    });

    test('by default a peer\'s height is the one its version handshake reported, and none before it', () {
      final unshaken = Peer(address: '127.0.0.1', port: 1, network: BitcoinNetwork.regtest);
      expect(unshaken.remoteVersion, isNull);
      expect(inSyncOrder(['not a peer', unshaken]), ['not a peer', unshaken]);
    });
  });
}
