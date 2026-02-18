import 'dart:typed_data';

import 'package:crypto/crypto.dart' hide Hash;
import 'package:spiffynode/spiffy_node.dart';
import 'package:test/test.dart';

import 'package:libspiffy/src/spv/cdn_manifest.dart';
import 'package:libspiffy/src/spv/block_header_chain.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';

/// Real Bitcoin mainnet block headers (blocks 0-6) for testing.
/// These form a valid chain where each prevBlock links to the previous hash.
final _realHeaders = [
  BlockHeader(
    version: 1,
    prevBlock: Hash.fromHex('0' * 64),
    merkleRoot: Hash.fromHex('4a5e1e4baab89f3a32518a88c31bc87f618f76673e2cc77ab2127b7afdeda33b'),
    timestamp: DateTime.fromMillisecondsSinceEpoch(1231006505 * 1000),
    bits: 0x1d00ffff,
    nonce: 2083236893,
  ), // block 0
  BlockHeader(
    version: 1,
    prevBlock: Hash.fromHex('000000000019d6689c085ae165831e934ff763ae46a2a6c172b3f1b60a8ce26f'),
    merkleRoot: Hash.fromHex('0e3e2357e806b6cdb1f70b54c3a3a17b6714ee1f0e68bebb44a74b1efd512098'),
    timestamp: DateTime.fromMillisecondsSinceEpoch(1231469665 * 1000),
    bits: 0x1d00ffff,
    nonce: 2573394689,
  ), // block 1
  BlockHeader(
    version: 1,
    prevBlock: Hash.fromHex('00000000839a8e6886ab5951d76f411475428afc90947ee320161bbf18eb6048'),
    merkleRoot: Hash.fromHex('9b0fc92260312ce44e74ef369f5c66bbb85848f2eddd5a7a1cde251e54ccfdd5'),
    timestamp: DateTime.fromMillisecondsSinceEpoch(1231469744 * 1000),
    bits: 0x1d00ffff,
    nonce: 1639830024,
  ), // block 2
  BlockHeader(
    version: 1,
    prevBlock: Hash.fromHex('000000006a625f06636b8bb6ac7b960a8d03705d1ace08b1a19da3fdcc99ddbd'),
    merkleRoot: Hash.fromHex('999e1c837c76a1b7fbb7e57baf87b309960f5ffefbf2a9b95dd890602272f644'),
    timestamp: DateTime.fromMillisecondsSinceEpoch(1231470173 * 1000),
    bits: 0x1d00ffff,
    nonce: 1844305925,
  ), // block 3
  BlockHeader(
    version: 1,
    prevBlock: Hash.fromHex('0000000082b5015589a3fdf2d4baff403e6f0be035a5d9742c1cae6295464449'),
    merkleRoot: Hash.fromHex('df2b060fa2e5e9c8ed5eaf6a45c13753ec8c63282b2688322eba40cd98ea067a'),
    timestamp: DateTime.fromMillisecondsSinceEpoch(1231470988 * 1000),
    bits: 0x1d00ffff,
    nonce: 2850094635,
  ), // block 4
  BlockHeader(
    version: 1,
    prevBlock: Hash.fromHex('000000004ebadb55ee9096c9a2f8880e09da59c0d68b1c228da88e48844a1485'),
    merkleRoot: Hash.fromHex('63522845d294ee9b0188ae5cac91bf389a0c3723f084ca1025e7d9cdfe481ce1'),
    timestamp: DateTime.fromMillisecondsSinceEpoch(1231471428 * 1000),
    bits: 0x1d00ffff,
    nonce: 2011431709,
  ), // block 5
  BlockHeader(
    version: 1,
    prevBlock: Hash.fromHex('000000009b7262315dbf071787ad3656097b892abffd1f95a1a022f896f533fc'),
    merkleRoot: Hash.fromHex('20251a76e64e920e58291a30d4b212939aae976baca40e70818ceaa596fb9d37'),
    timestamp: DateTime.fromMillisecondsSinceEpoch(1231471789 * 1000),
    bits: 0x1d00ffff,
    nonce: 2538380312,
  ), // block 6
];

void main() {
  group('CdnManifest', () {
    test('should parse from JSON and round-trip', () {
      final json = {
        'version': 1,
        'network': 'testnet',
        'generatedAt': '2026-02-18T12:00:00.000Z',
        'totalHeaders': 50000,
        'chunkSize': 50000,
        'headerSizeBytes': 80,
        'chunks': [
          {
            'filename': 'headers_0000000_0049999.bin',
            'startHeight': 0,
            'endHeight': 49999,
            'headerCount': 50000,
            'sha256': 'abc123',
            'sizeBytes': 4000000,
          }
        ],
        'checkpoints': {
          '0': '000000000019d6689c085ae165831e934ff763ae46a2a6c172b3f1b60a8ce26f',
        },
      };

      final manifest = CdnManifest.fromJson(json);
      expect(manifest.version, equals(1));
      expect(manifest.network, equals('testnet'));
      expect(manifest.totalHeaders, equals(50000));
      expect(manifest.chunkSize, equals(50000));
      expect(manifest.chunks.length, equals(1));
      expect(manifest.chunks.first.filename, equals('headers_0000000_0049999.bin'));
      expect(manifest.chunks.first.startHeight, equals(0));
      expect(manifest.chunks.first.endHeight, equals(49999));
      expect(manifest.checkpoints.length, equals(1));
      expect(manifest.checkpoints[0], equals('000000000019d6689c085ae165831e934ff763ae46a2a6c172b3f1b60a8ce26f'));

      // Round-trip
      final roundTripped = CdnManifest.fromJson(manifest.toJson());
      expect(roundTripped.version, equals(manifest.version));
      expect(roundTripped.network, equals(manifest.network));
      expect(roundTripped.totalHeaders, equals(manifest.totalHeaders));
      expect(roundTripped.chunks.length, equals(manifest.chunks.length));
      expect(roundTripped.checkpoints, equals(manifest.checkpoints));
    });

    test('should handle missing optional fields gracefully', () {
      final json = {
        'version': 1,
        'network': 'mainnet',
        'generatedAt': '2026-01-01T00:00:00.000Z',
        'totalHeaders': 100,
        'chunkSize': 100,
        'chunks': <Map<String, dynamic>>[],
      };

      final manifest = CdnManifest.fromJson(json);
      expect(manifest.headerSizeBytes, equals(80));
      expect(manifest.checkpoints, isEmpty);
    });

    test('should parse multiple chunks and checkpoints', () {
      final json = {
        'version': 1,
        'network': 'testnet',
        'generatedAt': '2026-02-18T00:00:00.000Z',
        'totalHeaders': 100000,
        'chunkSize': 50000,
        'chunks': [
          {
            'filename': 'headers_0000000_0049999.bin',
            'startHeight': 0,
            'endHeight': 49999,
            'headerCount': 50000,
            'sha256': 'aaa',
            'sizeBytes': 4000000,
          },
          {
            'filename': 'headers_0050000_0099999.bin',
            'startHeight': 50000,
            'endHeight': 99999,
            'headerCount': 50000,
            'sha256': 'bbb',
            'sizeBytes': 4000000,
          },
        ],
        'checkpoints': {
          '0': 'hash0',
          '50000': 'hash50000',
        },
      };

      final manifest = CdnManifest.fromJson(json);
      expect(manifest.chunks.length, equals(2));
      expect(manifest.checkpoints.length, equals(2));
      expect(manifest.checkpoints[50000], equals('hash50000'));
    });
  });

  group('CdnChunkInfo', () {
    test('should serialize and deserialize', () {
      final chunk = CdnChunkInfo(
        filename: 'headers_0000000_0049999.bin',
        startHeight: 0,
        endHeight: 49999,
        headerCount: 50000,
        sha256: 'deadbeef',
        sizeBytes: 4000000,
      );

      final json = chunk.toJson();
      final restored = CdnChunkInfo.fromJson(json);

      expect(restored.filename, equals(chunk.filename));
      expect(restored.startHeight, equals(chunk.startHeight));
      expect(restored.endHeight, equals(chunk.endHeight));
      expect(restored.headerCount, equals(chunk.headerCount));
      expect(restored.sha256, equals(chunk.sha256));
      expect(restored.sizeBytes, equals(chunk.sizeBytes));
    });
  });

  group('Binary header serialization round-trip', () {
    test('should serialize and deserialize real block headers', () {
      for (var i = 0; i < _realHeaders.length; i++) {
        final original = _realHeaders[i];
        final bytes = original.serialize();
        expect(bytes.length, equals(80), reason: 'Header $i should be 80 bytes');

        final restored = BlockHeader.deserialize(bytes);
        expect(restored.version, equals(original.version),
            reason: 'Header $i version mismatch');
        expect(restored.prevBlock.toString(), equals(original.prevBlock.toString()),
            reason: 'Header $i prevBlock mismatch');
        expect(restored.merkleRoot.toString(), equals(original.merkleRoot.toString()),
            reason: 'Header $i merkleRoot mismatch');
        expect(restored.timestamp, equals(original.timestamp),
            reason: 'Header $i timestamp mismatch');
        expect(restored.bits, equals(original.bits),
            reason: 'Header $i bits mismatch');
        expect(restored.nonce, equals(original.nonce),
            reason: 'Header $i nonce mismatch');
      }
    });

    test('should concatenate multiple headers into a valid chunk', () {
      // Simulate chunk creation: concatenate serialized headers
      final buffer = BytesBuilder(copy: false);
      for (final header in _realHeaders) {
        buffer.add(header.serialize());
      }
      final chunkData = buffer.toBytes();

      expect(chunkData.length, equals(80 * _realHeaders.length));

      // Parse chunk back into individual headers
      final parsed = <BlockHeader>[];
      for (var i = 0; i < _realHeaders.length; i++) {
        final offset = i * 80;
        final headerBytes = Uint8List.sublistView(chunkData, offset, offset + 80);
        parsed.add(BlockHeader.deserialize(headerBytes));
      }

      // Verify all headers match
      for (var i = 0; i < _realHeaders.length; i++) {
        expect(parsed[i].blockHash().toString(),
            equals(_realHeaders[i].blockHash().toString()),
            reason: 'Header $i hash mismatch after chunk round-trip');
      }
    });
  });

  group('Chain continuity validation', () {
    test('should validate a correct chain', () {
      // Verify blocks 0-6 form a valid chain
      for (var i = 1; i < _realHeaders.length; i++) {
        final prevHash = _realHeaders[i - 1].blockHash().toString();
        final headerPrevHash = _realHeaders[i].prevBlock.toString();
        expect(prevHash, equals(headerPrevHash),
            reason: 'Block $i prevBlock should match block ${i - 1} hash');
      }
    });

    test('should detect a broken chain link', () {
      // Create a chain with a corrupted prevBlock at index 3
      final corruptedHeaders = List<BlockHeader>.from(_realHeaders);
      corruptedHeaders[3] = BlockHeader(
        version: _realHeaders[3].version,
        prevBlock: Hash.fromHex('deadbeef' * 8), // Wrong prevBlock
        merkleRoot: _realHeaders[3].merkleRoot,
        timestamp: _realHeaders[3].timestamp,
        bits: _realHeaders[3].bits,
        nonce: _realHeaders[3].nonce,
      );

      // Check that continuity breaks at index 3
      var breakFound = false;
      for (var i = 1; i < corruptedHeaders.length; i++) {
        final prevHash = corruptedHeaders[i - 1].blockHash().toString();
        final headerPrevHash = corruptedHeaders[i].prevBlock.toString();
        if (prevHash != headerPrevHash) {
          expect(i, equals(3), reason: 'Chain break should be at index 3');
          breakFound = true;
          break;
        }
      }
      expect(breakFound, isTrue, reason: 'Should detect the broken chain link');
    });
  });

  group('Chunk integrity (SHA-256)', () {
    test('should verify correct chunk hash', () {
      final buffer = BytesBuilder(copy: false);
      for (final header in _realHeaders) {
        buffer.add(header.serialize());
      }
      final chunkData = buffer.toBytes();
      final expectedHash = sha256.convert(chunkData).toString();

      // Verify hash matches
      final actualHash = sha256.convert(chunkData).toString();
      expect(actualHash, equals(expectedHash));
    });

    test('should detect corrupted chunk data', () {
      final buffer = BytesBuilder(copy: false);
      for (final header in _realHeaders) {
        buffer.add(header.serialize());
      }
      final chunkData = buffer.toBytes();
      final correctHash = sha256.convert(chunkData).toString();

      // Corrupt one byte
      final corrupted = Uint8List.fromList(chunkData);
      corrupted[42] = (corrupted[42] + 1) % 256;
      final corruptedHash = sha256.convert(corrupted).toString();

      expect(corruptedHash, isNot(equals(correctHash)));
    });
  });

  group('Checkpoint verification', () {
    test('should pass with correct checkpoint hashes', () {
      final checkpoints = <int, String>{
        0: _realHeaders[0].blockHash().toString(),
        3: _realHeaders[3].blockHash().toString(),
        6: _realHeaders[6].blockHash().toString(),
      };

      for (final entry in checkpoints.entries) {
        final actualHash = _realHeaders[entry.key].blockHash().toString();
        expect(actualHash, equals(entry.value),
            reason: 'Checkpoint at height ${entry.key} should match');
      }
    });

    test('should detect incorrect checkpoint hash', () {
      final wrongCheckpoint = 'deadbeef' * 8;
      final actualHash = _realHeaders[3].blockHash().toString();
      expect(actualHash, isNot(equals(wrongCheckpoint)));
    });
  });

  group('Chunk determination logic', () {
    test('should skip chunks already below bestHeight', () {
      final chunks = [
        CdnChunkInfo(filename: 'a.bin', startHeight: 0, endHeight: 49999, headerCount: 50000, sha256: '', sizeBytes: 0),
        CdnChunkInfo(filename: 'b.bin', startHeight: 50000, endHeight: 99999, headerCount: 50000, sha256: '', sizeBytes: 0),
        CdnChunkInfo(filename: 'c.bin', startHeight: 100000, endHeight: 149999, headerCount: 50000, sha256: '', sizeBytes: 0),
      ];

      // Simulate currentHeight = 75000
      final currentHeight = 75000;
      final needed = chunks.where((c) => c.endHeight > currentHeight).toList();

      expect(needed.length, equals(2));
      expect(needed[0].filename, equals('b.bin'));
      expect(needed[1].filename, equals('c.bin'));
    });

    test('should return empty when fully synced', () {
      final chunks = [
        CdnChunkInfo(filename: 'a.bin', startHeight: 0, endHeight: 49999, headerCount: 50000, sha256: '', sizeBytes: 0),
      ];

      final currentHeight = 50000;
      final needed = chunks.where((c) => c.endHeight > currentHeight).toList();
      expect(needed, isEmpty);
    });
  });

  group('BlockHeaderChain.bulkImportHeaders', () {
    late InMemoryWalletStorage storage;
    late BlockHeaderChain headerChain;

    setUp(() async {
      storage = InMemoryWalletStorage();
      headerChain = BlockHeaderChain(storage, skipProofOfWorkValidation: true);
      await headerChain.initialize();
    });

    test('should bulk import headers and update chain state', () async {
      await headerChain.bulkImportHeaders(_realHeaders, 0);

      expect(headerChain.bestHeight, equals(6));
      expect(headerChain.chainTip, isNotNull);
      expect(headerChain.chainTip!.blockHash().toString(),
          equals(_realHeaders.last.blockHash().toString()));
    });

    test('should make headers retrievable by height after bulk import', () async {
      await headerChain.bulkImportHeaders(_realHeaders, 0);

      for (var i = 0; i < _realHeaders.length; i++) {
        final header = await headerChain.getHeaderByHeight(i);
        expect(header, isNotNull, reason: 'Header at height $i should exist');
        expect(header!.blockHash().toString(),
            equals(_realHeaders[i].blockHash().toString()),
            reason: 'Header at height $i hash mismatch');
      }
    });

    test('should make headers retrievable by hash after bulk import', () async {
      await headerChain.bulkImportHeaders(_realHeaders, 0);

      for (var i = 0; i < _realHeaders.length; i++) {
        final hash = _realHeaders[i].blockHash().toString();
        final header = await headerChain.getHeaderByHash(hash);
        expect(header, isNotNull, reason: 'Header with hash $hash should exist');
      }
    });

    test('should handle empty header list', () async {
      await headerChain.bulkImportHeaders([], 0);
      expect(headerChain.bestHeight, equals(0));
    });

    test('should handle import at non-zero start height', () async {
      // Simulate importing a later chunk
      final laterHeaders = _realHeaders.sublist(3);
      await headerChain.bulkImportHeaders(laterHeaders, 3);

      expect(headerChain.bestHeight, equals(6));

      final header = await headerChain.getHeaderByHeight(5);
      expect(header, isNotNull);
      expect(header!.blockHash().toString(),
          equals(_realHeaders[5].blockHash().toString()));
    });
  });

  group('storeBlockHeadersBulk', () {
    late InMemoryWalletStorage storage;

    setUp(() {
      storage = InMemoryWalletStorage();
    });

    test('should store multiple headers in a single bulk call', () async {
      final pairs = <(BlockHeader, int)>[];
      for (var i = 0; i < _realHeaders.length; i++) {
        pairs.add((_realHeaders[i], i));
      }

      await storage.storeBlockHeadersBulk(pairs);

      // Verify all headers are stored
      for (var i = 0; i < _realHeaders.length; i++) {
        final header = await storage.getBlockHeaderByHeight(i);
        expect(header, isNotNull, reason: 'Header at height $i should exist');
        expect(header!.blockHash().toString(),
            equals(_realHeaders[i].blockHash().toString()));
      }
    });

    test('should handle empty bulk insert', () async {
      await storage.storeBlockHeadersBulk([]);
      // Should not throw
    });
  });
}
