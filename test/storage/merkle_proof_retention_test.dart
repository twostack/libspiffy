/// Bead libspiffy-mny: merkle proofs keep a status instead of being deleted,
/// on the in-memory and Isar backends (Postgres:
/// postgres/postgres_merkle_proof_retention_test.dart).
import 'dart:io';

import 'package:isar/isar.dart';
import 'package:test/test.dart';

import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';
import 'package:libspiffy/src/storage/isar_wallet_storage.dart';
import 'package:libspiffy/src/storage/libspiffy_schemas.dart';
import 'package:libspiffy/src/storage/read_model_storage.dart';

import '../integration/isar_test_helper.dart';
import 'ancestor_transaction_contract.dart';
import 'pending_receive_contract.dart';
import 'merkle_proof_retention_contract.dart';

void main() {
  group('InMemoryWalletStorage', () {
    late InMemoryWalletStorage storage;
    var counter = 0;
    setUp(() => storage = InMemoryWalletStorage());
    defineMerkleProofRetentionContract(() => storage, unique: () => 'm${counter++}');
    defineAncestorTransactionContract(() => storage, unique: () => 'm${counter++}');
    definePendingReceiveContract(() => storage, unique: () => 'm${counter++}');
  });

  group('IsarWalletStorage', () {
    late Directory dir;
    late Isar isar;
    late IsarWalletStorage storage;
    var counter = 0;

    setUpAll(() async {
      await ensureIsarInitialized();
    });

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('merkle_proof_retention_');
      isar = await Isar.open(
        LibSpiffySchemas.allSchemas,
        directory: dir.path,
        name: 'proof_retention_${DateTime.now().microsecondsSinceEpoch}',
      );
      storage = IsarWalletStorage(isar);
    });

    tearDown(() async {
      await isar.close(deleteFromDisk: true);
      await dir.delete(recursive: true);
    });

    defineMerkleProofRetentionContract(() => storage, unique: () => 'i${counter++}');
    defineAncestorTransactionContract(() => storage, unique: () => 'i${counter++}');
    definePendingReceiveContract(() => storage, unique: () => 'i${counter++}');

    test('mny: rows written before the status existed read as pendingHeader or verified', () async {
      final pendingTx = 'aa' * 32;
      final verifiedTx = 'bb' * 32;
      final block = 'cc' * 32;
      MerkleProofEntity legacy(String txid, String blockHash) => MerkleProofEntity()
        ..txid = txid
        ..blockHash = blockHash
        ..blockHeight = 7
        ..position = 0
        ..merkleProofJson = 'fe$txid'
        ..createdAt = DateTime.utc(2026, 9, 1);
      await isar.writeTxn(() async {
        await isar.merkleProofEntitys.putAll([legacy(pendingTx, 'pending'), legacy(verifiedTx, block)]);
      });

      final pending = (await storage.getMerkleProof(pendingTx))!;
      expect(pending.status, MerkleProofStatus.pendingHeader);
      expect(pending.blockHash, isNull, reason: "the 'pending' placeholder reads as no block hash");
      expect((await storage.getMerkleProof(verifiedTx))!.status, MerkleProofStatus.verified);
      expect([for (final p in await storage.getMerkleProofsByStatus(MerkleProofStatus.pendingHeader)) p.txid],
          [pendingTx]);
      expect([for (final p in await storage.getMerkleProofsByStatus(MerkleProofStatus.verified)) p.txid],
          [verifiedTx]);

      // The header arrives: the legacy row is updated, not duplicated.
      await storage.storeMerkleProof(pendingTx, MerkleProof(
        txid: pendingTx,
        blockHash: block,
        blockHeight: 7,
        position: 0,
        merkleProof: ['fe$pendingTx'],
        status: MerkleProofStatus.verified,
      ));
      final history = await storage.getMerkleProofHistory(pendingTx);
      expect([for (final p in history) (p.blockHash, p.status)], [(block, MerkleProofStatus.verified)]);
      expect(await storage.getMerkleProofsByStatus(MerkleProofStatus.pendingHeader), isEmpty);
    });
  });
}
