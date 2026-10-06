/// The Isar database must hold on disk about what its file length says.
///
/// libmdbx v0.13.8-temp-upstream-fix, which the published isar_community
/// 3.3.2 binaries are built on, preallocates the whole new file size past
/// the end of the file every time the database grows on macOS and iOS, and
/// never releases it (isar-community/isar-community#85). The space held
/// grows with the square of the file: a 135 MiB header store held 1.9 GiB,
/// a full testnet header store about 59 GiB. pubspec.yaml overrides
/// isar_community with a build on libmdbx v0.13.12 for that reason.
library;

import 'dart:io';

import 'package:isar_community/isar.dart';
import 'package:spiffynode/spiffy_node.dart';
import 'package:test/test.dart';

import 'package:libspiffy/src/storage/isar_wallet_storage.dart';
import 'package:libspiffy/src/storage/libspiffy_schemas.dart';

import '../integration/isar_test_helper.dart';

/// Bytes the file system has allocated to [file], which is not its length:
/// space preallocated past the end of a file counts here only.
int _allocatedBytes(File file) {
  final format = Platform.isMacOS ? ['-f', '%b'] : ['-c', '%b'];
  final result = Process.runSync('stat', [...format, file.path]);
  expect(result.exitCode, 0, reason: '${result.stderr}');
  return int.parse((result.stdout as String).trim()) * 512;
}

void main() {
  setUpAll(ensureIsarInitialized);

  test('a header store that grew holds no more disk space than its length', () async {
    final tempDir = await Directory.systemTemp.createTemp('isar_disk_allocation_test_');
    addTearDown(() => tempDir.delete(recursive: true));
    final isar = await Isar.open(
      [BlockHeaderEntitySchema],
      directory: tempDir.path,
      name: 'headers',
    );
    final storage = IsarWalletStorage(isar);

    // 60 batches the size bulkImportHeaders writes: about 30 MiB, six growth
    // steps of 5 MiB past the 1 MiB the database starts with.
    var prev = Hash.fromHex('00' * 32);
    final merkleRoot = Hash.fromHex('11' * 32);
    for (var height = 0; height < 60000;) {
      final batch = <(BlockHeader, int)>[];
      for (var i = 0; i < 1000; i++, height++) {
        final header = BlockHeader(
          version: 1,
          prevBlock: prev,
          merkleRoot: merkleRoot,
          timestamp: DateTime.fromMillisecondsSinceEpoch((1600000000 + height) * 1000),
          bits: 0x1d00ffff,
          nonce: height,
        );
        prev = header.blockHash();
        batch.add((header, height));
      }
      await storage.storeBlockHeadersBulk(batch);
    }
    await isar.close();

    final file = File('${tempDir.path}/headers.isar');
    final length = file.lengthSync();
    expect(length, greaterThan(20 * 1024 * 1024),
        reason: 'the store must have grown several steps for the check to mean anything');
    expect(_allocatedBytes(file), lessThanOrEqualTo(length * 1.1),
        reason: 'the database holds disk space past the end of its ${length ~/ (1024 * 1024)} MiB file');
  }, skip: Platform.isWindows ? 'needs stat' : null);
}
