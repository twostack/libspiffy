/// Merkle proof retention contract shared by the three [ReadModelStorage]
/// backends (audit bead libspiffy-mny).
///
/// Until bead mny a proof whose block left the active chain was deleted
/// (`deleteMerkleProof`, audit 3b0) and storing a proof for a txid replaced
/// the earlier one (S-13). A proof cannot be fetched again, so proofs now
/// keep a [MerkleProofStatus] and are never deleted: a transaction may have
/// several rows (orphaned ones plus at most one current one).
library;

import 'package:test/test.dart';

import 'package:libspiffy/src/storage/read_model_storage.dart';

import 'read_model_keying_contract.dart' show contractHex64;

/// Registers the retention contract tests. [storage] returns the storage for
/// the running test; [unique] a string unique per test run (the Postgres
/// database outlives a run).
void defineMerkleProofRetentionContract(
  ReadModelStorage Function() storage, {
  required String Function() unique,
}) {
  group('merkle proof retention contract (mny)', () {
    MerkleProof proof(String txid, String? blockHash, String bump,
            {int height = 10, MerkleProofStatus? status}) =>
        MerkleProof(
          txid: txid,
          blockHash: blockHash,
          blockHeight: height,
          merkleProof: [bump],
          position: 1,
          status: status,
        );
    String bumpHex(String tag) => 'fe${contractHex64('bump-$tag')}';

    test('mny: an orphaned proof is kept in the history and is no longer the current proof', () async {
      final s = storage();
      final u = unique();
      final txid = contractHex64('ret-orphan-$u');
      final blockA = contractHex64('ret-orphan-block-$u');
      final bumpA = bumpHex('orphan-$u');
      await s.storeMerkleProof(txid, proof(txid, blockA, bumpA));
      expect((await s.getMerkleProof(txid))!.status, MerkleProofStatus.verified);

      // Another proof or another block than the stored one is not marked.
      expect(await s.markMerkleProofOrphaned(txid, onlyIfMerkleProof: ['ffff']), isFalse);
      expect(await s.markMerkleProofOrphaned(txid, blockHash: contractHex64('other-$u')), isFalse);
      expect(await s.getMerkleProof(txid), isNotNull);

      final at = DateTime.utc(2026, 9, 14, 21);
      expect(await s.markMerkleProofOrphaned(txid, blockHash: blockA, onlyIfMerkleProof: [bumpA], at: at),
          isTrue);

      expect(await s.getMerkleProof(txid), isNull, reason: 'an orphaned proof is not the current proof');
      expect(await s.getMerkleProofsBatch([txid]), isEmpty);
      expect(await s.getMerkleProofsForBlock(blockA), isEmpty);

      final history = await s.getMerkleProofHistory(txid);
      expect(history, hasLength(1), reason: 'the orphaned proof must still be stored');
      expect(history.single.status, MerkleProofStatus.orphaned);
      expect(history.single.blockHash, blockA);
      expect(history.single.merkleProof, [bumpA]);
      expect(history.single.statusChangedAt!.isAtSameMomentAs(at), isTrue);
      expect([for (final p in await s.getMerkleProofsByStatus(MerkleProofStatus.orphaned)) p.txid],
          contains(txid));

      // Idempotent (a projection replay marks again).
      expect(await s.markMerkleProofOrphaned(txid, blockHash: blockA, onlyIfMerkleProof: [bumpA]), isFalse);
      expect(await s.getMerkleProofHistory(txid), hasLength(1));
    });

    test('mny: a replacement proof in another block keeps both rows and becomes current', () async {
      final s = storage();
      final u = unique();
      final txid = contractHex64('ret-replace-$u');
      final blockA = contractHex64('ret-replace-a-$u');
      final blockB = contractHex64('ret-replace-b-$u');
      final bumpA = bumpHex('replace-a-$u');
      final bumpB = bumpHex('replace-b-$u');

      await s.storeMerkleProof(txid, proof(txid, blockA, bumpA));
      await s.markMerkleProofOrphaned(txid, blockHash: blockA, onlyIfMerkleProof: [bumpA]);
      // Re-mined in block B (ARCActor stores the new proof).
      await s.storeMerkleProof(txid, proof(txid, blockB, bumpB, height: 11));

      final current = (await s.getMerkleProof(txid))!;
      expect(current.blockHash, blockB);
      expect(current.merkleProof, [bumpB]);
      expect((await s.getMerkleProofsBatch([txid]))[txid]!.blockHash, blockB);
      final history = await s.getMerkleProofHistory(txid);
      expect([for (final p in history) (p.blockHash, p.status)], [
        (blockA, MerkleProofStatus.orphaned),
        (blockB, MerkleProofStatus.verified),
      ]);

      // A stale revert naming the orphaned proof leaves the replacement alone.
      expect(await s.markMerkleProofOrphaned(txid, blockHash: blockA, onlyIfMerkleProof: [bumpA]), isFalse);
      expect((await s.getMerkleProof(txid))!.blockHash, blockB);
    });

    test('mny: storing a proof in another block keeps the displaced proof as orphaned', () async {
      final s = storage();
      final u = unique();
      final txid = contractHex64('ret-displace-$u');
      final blockA = contractHex64('ret-displace-a-$u');
      final blockB = contractHex64('ret-displace-b-$u');

      await s.storeMerkleProof(txid, proof(txid, blockA, bumpHex('displace-a-$u')));
      await s.storeMerkleProof(txid, proof(txid, blockB, bumpHex('displace-b-$u'), height: 11));

      expect((await s.getMerkleProof(txid))!.blockHash, blockB);
      final history = await s.getMerkleProofHistory(txid);
      expect([for (final p in history) (p.blockHash, p.status)], [
        (blockA, MerkleProofStatus.orphaned),
        (blockB, MerkleProofStatus.verified),
      ], reason: 'the proof of block A must not be destroyed');
      expect(history.first.merkleProof, [bumpHex('displace-a-$u')]);
      expect(history.first.statusChangedAt, isNotNull);
    });

    test('mny: at most one non-orphaned proof per txid, one row per (txid, block)', () async {
      final s = storage();
      final u = unique();
      final txid = contractHex64('ret-one-$u');
      final blockA = contractHex64('ret-one-a-$u');
      final blockB = contractHex64('ret-one-b-$u');
      final bumpA = bumpHex('one-a-$u');
      final bumpB = bumpHex('one-b-$u');
      final bumpP = bumpHex('one-p-$u');
      final bumpC = bumpHex('one-c-$u');

      Future<List<(String?, MerkleProofStatus)>> rows() async =>
          [for (final p in await s.getMerkleProofHistory(txid)) (p.blockHash, p.status)];
      Future<void> expectOneCurrent() async {
        final current = [for (final p in await s.getMerkleProofHistory(txid)) if (p.isCurrent) p];
        expect(current, hasLength(1), reason: 'exactly one current proof');
        expect((await s.getMerkleProof(txid))!.merkleProof, current.single.merkleProof);
      }

      await s.storeMerkleProof(txid, proof(txid, blockA, bumpA));
      await s.storeMerkleProof(txid, proof(txid, null, bumpP, height: 12)); // header unknown
      await expectOneCurrent();
      await s.storeMerkleProof(txid, proof(txid, blockB, bumpB, height: 11));
      await s.storeMerkleProof(txid, proof(txid, blockB, bumpB, height: 11)); // stored again
      await expectOneCurrent();
      expect(await rows(), [
        (blockA, MerkleProofStatus.orphaned),
        (null, MerkleProofStatus.orphaned),
        (blockB, MerkleProofStatus.verified),
      ]);

      // Block A becomes active again: its row is revived, not duplicated.
      await s.storeMerkleProof(txid, proof(txid, blockA, bumpA));
      await expectOneCurrent();
      expect((await s.getMerkleProof(txid))!.blockHash, blockA);
      expect(await rows(), [
        (blockA, MerkleProofStatus.verified),
        (null, MerkleProofStatus.orphaned),
        (blockB, MerkleProofStatus.orphaned),
      ]);

      // Storing an orphaned proof (a replay of a proof whose block is gone)
      // records it without touching the current proof; storing it again
      // adds nothing.
      await s.storeMerkleProof(txid, proof(txid, null, bumpC, status: MerkleProofStatus.orphaned));
      await s.storeMerkleProof(txid, proof(txid, null, bumpC, status: MerkleProofStatus.orphaned));
      await s.storeMerkleProof(txid, proof(txid, null, bumpB, height: 11, status: MerkleProofStatus.orphaned));
      await expectOneCurrent();
      expect((await s.getMerkleProof(txid))!.blockHash, blockA);
      expect(await rows(), [
        (blockA, MerkleProofStatus.verified),
        (null, MerkleProofStatus.orphaned),
        (blockB, MerkleProofStatus.orphaned),
        (null, MerkleProofStatus.orphaned),
      ]);
    });

    test('mny: a pendingHeader proof is found by status and becomes verified in place', () async {
      final s = storage();
      final u = unique();
      final txid = contractHex64('ret-pending-$u');
      final block = contractHex64('ret-pending-block-$u');
      final bump = bumpHex('pending-$u');

      await s.storeMerkleProof(txid, proof(txid, null, bump));
      final pending = (await s.getMerkleProof(txid))!;
      expect(pending.status, MerkleProofStatus.pendingHeader);
      expect(pending.blockHash, isNull);
      expect((await s.getMerkleProofsBatch([txid]))[txid], isNotNull,
          reason: 'a pendingHeader proof is still the current proof (used in BEEFs)');
      expect([for (final p in await s.getMerkleProofsByStatus(MerkleProofStatus.pendingHeader)) p.txid],
          contains(txid));

      // The header arrives and matches (SPVActor).
      await s.storeMerkleProof(txid, proof(txid, block, bump, status: MerkleProofStatus.verified));

      final history = await s.getMerkleProofHistory(txid);
      expect(history, hasLength(1), reason: 'the pending row itself is verified, not copied');
      expect(history.single.status, MerkleProofStatus.verified);
      expect(history.single.blockHash, block);
      expect(history.single.statusChangedAt, isNotNull);
      expect([for (final p in await s.getMerkleProofsByStatus(MerkleProofStatus.pendingHeader)) p.txid],
          isNot(contains(txid)));
      expect([for (final p in await s.getMerkleProofsByStatus(MerkleProofStatus.verified)) p.txid],
          contains(txid));
      expect([for (final p in await s.getMerkleProofsForBlock(block)) p.txid], [txid]);
    });

    test('mny: a pendingHeader proof whose header does not match is marked orphaned', () async {
      final s = storage();
      final u = unique();
      final txid = contractHex64('ret-pending-bad-$u');
      final bump = bumpHex('pending-bad-$u');
      await s.storeMerkleProof(txid, proof(txid, null, bump));

      expect(await s.markMerkleProofOrphaned(txid, onlyIfMerkleProof: [bump]), isTrue);
      expect(await s.getMerkleProof(txid), isNull);
      final history = await s.getMerkleProofHistory(txid);
      expect([for (final p in history) (p.blockHash, p.status)], [(null, MerkleProofStatus.orphaned)]);
      expect([for (final p in await s.getMerkleProofsByStatus(MerkleProofStatus.pendingHeader)) p.txid],
          isNot(contains(txid)));
    });

    // azl (libspiffy-azl): a proof the header at its height contradicts was
    // stored as pendingHeader and stayed the current proof (BEEFs used it).
    Future<List<(String?, MerkleProofStatus, String)>> shape(ReadModelStorage s, String txid) async =>
        [for (final p in await s.getMerkleProofHistory(txid)) (p.blockHash, p.status, p.merkleProof.join())];

    test('azl: a rejected proof is kept and found by status, and is never the current proof', () async {
      final s = storage();
      final u = unique();
      final txid = contractHex64('ret-rejected-$u');
      final bump = bumpHex('rejected-$u');

      await s.storeMerkleProof(txid, proof(txid, null, bump, status: MerkleProofStatus.rejected));

      expect(await s.getMerkleProof(txid), isNull, reason: 'a rejected proof is not the current proof');
      expect(await s.getMerkleProofsBatch([txid]), isEmpty, reason: 'BEEFs are built from this batch');
      expect(await shape(s, txid), [(null, MerkleProofStatus.rejected, bump)]);
      expect([for (final p in await s.getMerkleProofsByStatus(MerkleProofStatus.rejected)) p.txid], contains(txid));
      expect([for (final p in await s.getMerkleProofsByStatus(MerkleProofStatus.pendingHeader)) p.txid],
          isNot(contains(txid)));
      expect((await s.getMerkleProofHistory(txid)).single.isCurrent, isFalse);

      // Stored again (a replay): the same row, no second one.
      await s.storeMerkleProof(txid, proof(txid, null, bump, status: MerkleProofStatus.rejected));
      expect(await shape(s, txid), [(null, MerkleProofStatus.rejected, bump)]);
      // Marking orphaned only ever touches a current proof.
      expect(await s.markMerkleProofOrphaned(txid, onlyIfMerkleProof: [bump]), isFalse);
    });

    test('azl: a rejected proof never displaces the current proof, even one naming the same block', () async {
      final s = storage();
      final u = unique();
      final txid = contractHex64('ret-rejected-keep-$u');
      final block = contractHex64('ret-rejected-keep-block-$u');
      final good = bumpHex('rejected-keep-good-$u');
      final forged = bumpHex('rejected-keep-forged-$u');
      final other = bumpHex('rejected-keep-other-$u');

      await s.storeMerkleProof(txid, proof(txid, block, good));
      await s.storeMerkleProof(txid, proof(txid, null, other, status: MerkleProofStatus.rejected));
      // A rejected proof claiming the verified proof's block is stored
      // without a block hash: it cannot overwrite that block's row.
      await s.storeMerkleProof(txid, proof(txid, block, forged, status: MerkleProofStatus.rejected));

      final current = (await s.getMerkleProof(txid))!;
      expect((current.blockHash, current.status, current.merkleProof.join()), (block, MerkleProofStatus.verified, good));
      expect((await s.getMerkleProofsBatch([txid]))[txid]!.merkleProof, [good]);
      expect([for (final p in await s.getMerkleProofsForBlock(block)) p.merkleProof.join()], [good]);
      expect(await shape(s, txid), [
        (block, MerkleProofStatus.verified, good),
        (null, MerkleProofStatus.rejected, other),
        (null, MerkleProofStatus.rejected, forged),
      ]);
    });

    test('azl: a pendingHeader proof whose header contradicts it becomes rejected in place', () async {
      final s = storage();
      final u = unique();
      final txid = contractHex64('ret-pending-rejected-$u');
      final bump = bumpHex('pending-rejected-$u');
      await s.storeMerkleProof(txid, proof(txid, null, bump));
      expect((await s.getMerkleProof(txid))!.status, MerkleProofStatus.pendingHeader);

      final at = DateTime.utc(2026, 9, 15, 3);
      await s.storeMerkleProof(txid, MerkleProof(
          txid: txid,
          blockHash: null,
          blockHeight: 10,
          merkleProof: [bump],
          position: 1,
          status: MerkleProofStatus.rejected,
          statusChangedAt: at));

      expect(await s.getMerkleProof(txid), isNull);
      final history = await s.getMerkleProofHistory(txid);
      expect(await shape(s, txid), [(null, MerkleProofStatus.rejected, bump)], reason: 'the same row, not a copy');
      expect(history.single.statusChangedAt!.isAtSameMomentAs(at), isTrue);
      expect([for (final p in await s.getMerkleProofsByStatus(MerkleProofStatus.pendingHeader)) p.txid],
          isNot(contains(txid)));
    });

    test('azl: a later proof that verifies becomes the current proof; a rejected row stays rejected', () async {
      final s = storage();
      final u = unique();
      // The same proof, verified once the active header at its height matches.
      final sameTx = contractHex64('ret-rejected-same-$u');
      final block = contractHex64('ret-rejected-same-block-$u');
      final bump = bumpHex('rejected-same-$u');
      await s.storeMerkleProof(sameTx, proof(sameTx, null, bump, status: MerkleProofStatus.rejected));
      await s.storeMerkleProof(sameTx, proof(sameTx, block, bump, status: MerkleProofStatus.verified));
      expect((await s.getMerkleProof(sameTx))!.blockHash, block);
      expect(await shape(s, sameTx), [(block, MerkleProofStatus.verified, bump)]);

      // Another proof (ARC's, for the block the transaction is really in).
      final otherTx = contractHex64('ret-rejected-other-$u');
      final otherBlock = contractHex64('ret-rejected-other-block-$u');
      final bad = bumpHex('rejected-other-bad-$u');
      final real = bumpHex('rejected-other-real-$u');
      final pending = bumpHex('rejected-other-pending-$u');
      await s.storeMerkleProof(otherTx, proof(otherTx, null, bad, status: MerkleProofStatus.rejected));
      await s.storeMerkleProof(otherTx, proof(otherTx, null, pending, height: 12));
      expect((await s.getMerkleProof(otherTx))!.merkleProof, [pending], reason: 'a pendingHeader proof is current');
      await s.storeMerkleProof(otherTx, proof(otherTx, otherBlock, real, height: 11));

      expect((await s.getMerkleProofsBatch([otherTx]))[otherTx]!.merkleProof, [real]);
      expect(await shape(s, otherTx), [
        (null, MerkleProofStatus.rejected, bad),
        (null, MerkleProofStatus.orphaned, pending),
        (otherBlock, MerkleProofStatus.verified, real),
      ], reason: 'the rejected row is kept as rejected, not turned into orphaned');
    });

    test('mny: getMerkleProofsBatch never returns an orphaned proof', () async {
      final s = storage();
      final u = unique();
      final orphanedTx = contractHex64('ret-batch-orphaned-$u');
      final currentTx = contractHex64('ret-batch-current-$u');
      final replacedTx = contractHex64('ret-batch-replaced-$u');
      final block = contractHex64('ret-batch-block-$u');
      final newBlock = contractHex64('ret-batch-new-block-$u');

      await s.storeMerkleProof(orphanedTx, proof(orphanedTx, block, bumpHex('b-o-$u')));
      await s.storeMerkleProof(currentTx, proof(currentTx, block, bumpHex('b-c-$u')));
      await s.storeMerkleProof(replacedTx, proof(replacedTx, block, bumpHex('b-r-$u')));
      await s.markMerkleProofOrphaned(orphanedTx, blockHash: block);
      await s.storeMerkleProof(replacedTx, proof(replacedTx, newBlock, bumpHex('b-r2-$u'), height: 11));

      final batch = await s.getMerkleProofsBatch([orphanedTx, currentTx, replacedTx]);
      expect(batch.keys.toSet(), {currentTx, replacedTx});
      expect(batch[replacedTx]!.merkleProof, [bumpHex('b-r2-$u')]);
      expect(batch.values.every((p) => p.status != MerkleProofStatus.orphaned), isTrue);
      expect([for (final p in await s.getMerkleProofsForBlock(block)) p.txid], [currentTx]);
    });
  });
}
