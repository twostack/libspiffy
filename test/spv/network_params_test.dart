import 'package:libspiffy/src/spv/network_params.dart';
import 'package:test/test.dart';

void main() {
  group('NetworkParams genesis data is self-consistent', () {
    for (final params in [NetworkParams.mainnet, NetworkParams.testnet, NetworkParams.regtest]) {
      test('${params.name}: stored hash equals double-SHA256 of the stored header bytes', () {
        final header = params.genesisHeader;
        expect(header.blockHash().toString(), equals(params.genesisHash));
      });

      test('${params.name}: genesis links to nothing, carries the pow limit and satisfies it', () {
        final header = params.genesisHeader;
        expect(header.prevBlock.toString(), equals('0' * 64));
        expect(header.version, equals(1));
        expect(header.bits, equals(params.powLimitBits));
        expect(NetworkParams.hashToBigInt(params.genesisHash) <= params.powLimit, isTrue,
            reason: 'genesis hash must be at or below the network pow limit');
      });
    }

    test('mainnet and testnet share the pow limit; regtest is easier', () {
      expect(NetworkParams.mainnet.powLimit, equals(NetworkParams.testnet.powLimit));
      expect(NetworkParams.regtest.powLimit > NetworkParams.mainnet.powLimit, isTrue);
      expect(NetworkParams.mainnet.powLimit.toRadixString(16).padLeft(64, '0'),
          equals('00000000ffff0000000000000000000000000000000000000000000000000000'));
    });
  });

  group('NetworkParams.forNetwork', () {
    test('accepts every spelling', () {
      for (final n in ['main', 'mainnet', 'livenet']) {
        expect(NetworkParams.forNetwork(n), same(NetworkParams.mainnet), reason: n);
      }
      for (final n in ['test', 'testnet', null, 'anything-else']) {
        expect(NetworkParams.forNetwork(n), same(NetworkParams.testnet), reason: '$n');
      }
      expect(NetworkParams.forNetwork('regtest'), same(NetworkParams.regtest));
    });
  });

  group('compact target encoding', () {
    test('bitsToTarget and targetToBits round-trip the pow limits', () {
      for (final bits in [0x1d00ffff, 0x207fffff, 0x1b0404cb, 0x18009645]) {
        final target = NetworkParams.bitsToTarget(bits);
        expect(NetworkParams.targetToBits(target), equals(bits), reason: bits.toRadixString(16));
      }
    });

    test('known vector: 0x1b0404cb', () {
      expect(NetworkParams.bitsToTarget(0x1b0404cb).toRadixString(16).padLeft(64, '0'),
          equals('00000000000404cb000000000000000000000000000000000000000000000000'));
    });

    test('negative or zero mantissa yields an unmeetable zero target', () {
      expect(NetworkParams.bitsToTarget(0x1d800000), equals(BigInt.zero));
      expect(NetworkParams.bitsToTarget(0x1d000000), equals(BigInt.zero));
    });
  });
}
