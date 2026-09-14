import 'dart:io';

import 'package:isar/isar.dart';
import 'package:test/test.dart';

import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';
import 'package:libspiffy/src/storage/isar_wallet_storage.dart';
import 'package:libspiffy/src/storage/libspiffy_schemas.dart';

import '../integration/isar_test_helper.dart';
import 'merkle_proof_delete_contract.dart';

void main() {
  test('InMemoryWalletStorage deletes only the named merkle proof', () async {
    await runMerkleProofDeleteContract(InMemoryWalletStorage());
  });

  test('IsarWalletStorage deletes only the named merkle proof', () async {
    await ensureIsarInitialized();
    final dir = await Directory.systemTemp.createTemp('merkle_proof_delete_');
    final isar = await Isar.open(
      LibSpiffySchemas.allSchemas,
      directory: dir.path,
      name: 'proof_delete_${DateTime.now().microsecondsSinceEpoch}',
    );
    try {
      await runMerkleProofDeleteContract(IsarWalletStorage(isar));
    } finally {
      await isar.close(deleteFromDisk: true);
      await dir.delete(recursive: true);
    }
  });
}
