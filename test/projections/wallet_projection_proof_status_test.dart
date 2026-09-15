/// Bead libspiffy-mny (projection side): WalletProjection stored a proof
/// whose header was unknown under the placeholder block hash 'pending', and
/// on TransactionConfirmationRevertedEvent deleted the proof. Proofs now
/// carry a status and are never deleted; the revert handler marks, and a
/// replay changes nothing.
///
/// Real data: the testnet fixture transaction, its BUMP and its block header.
import 'package:eventador/eventador.dart';
import 'package:test/test.dart';

import 'package:libspiffy/src/core/wallet_events.dart';
import 'package:libspiffy/src/projections/wallet_projection.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';
import 'package:libspiffy/src/storage/read_model_storage.dart';

import '../spv/testnet_proof_fixture.dart';

void main() {
  const walletId = 'projection-proof-status-wallet';
  final bumpHex = fixtureBumpHex();

  late InMemoryWalletStorage storage;
  late WalletProjection projection;

  setUp(() {
    storage = InMemoryWalletStorage();
    projection = WalletProjection(
      projectionId: 'wallet-projection-proof-status-test',
      eventStore: _NoopEventStore(),
      storage: storage,
    );
  });

  TransactionImportedEvent imported() => TransactionImportedEvent(
        walletId: walletId,
        txid: kFixtureTxid,
        rawHex: kFixtureTxHex,
        blockHeight: kFixtureHeight,
        bumpProof: bumpHex,
        totalOutputSats: 91296559239,
        numInputs: 1,
        numOutputs: 2,
        txVersion: 2,
        txLockTime: 0,
        walletReceivingAddresses: const [],
        walletReceivedSats: 0,
        totalInputSats: 0,
        sendingAddresses: const [],
        version: 1,
        timestamp: DateTime.utc(2026, 9, 1),
      );

  TransactionConfirmationRevertedEvent reverted() => TransactionConfirmationRevertedEvent(
        walletId: walletId,
        txid: kFixtureTxid,
        blockHeight: kFixtureHeight,
        blockHash: kFixtureBlockHash,
        merkleProof: [bumpHex],
        reason: 'reorganization',
        version: 2,
        timestamp: DateTime.utc(2026, 9, 2),
      );

  List<(String?, MerkleProofStatus)> shape(List<MerkleProof> rows) =>
      [for (final p in rows) (p.blockHash, p.status)];

  test('mny: a proof imported before its header is pendingHeader with no block hash', () async {
    await projection.handle(imported());

    final proof = (await storage.getMerkleProof(kFixtureTxid))!;
    expect(proof.status, MerkleProofStatus.pendingHeader);
    expect(proof.blockHash, isNull, reason: "no 'pending' placeholder");
    expect([for (final p in await storage.getMerkleProofsByStatus(MerkleProofStatus.pendingHeader)) p.txid],
        [kFixtureTxid]);
  });

  test('mny: a proof imported with its header stored is verified with that block hash', () async {
    await storage.storeBlockHeader(fixtureHeader(), kFixtureHeight);
    await projection.handle(imported());

    final proof = (await storage.getMerkleProof(kFixtureTxid))!;
    expect((proof.blockHash, proof.status), (kFixtureBlockHash, MerkleProofStatus.verified));
  });

  // A proof that does not match the stored header was left pendingHeader
  // here until bead azl; it is rejected now (group 'azl' below).

  test('mny: a reverted confirmation marks the proof orphaned, and a replay changes nothing', () async {
    await storage.storeBlockHeader(fixtureHeader(), kFixtureHeight);
    await projection.handle(imported());
    await projection.handle(reverted());

    expect(await storage.getMerkleProof(kFixtureTxid), isNull);
    var history = await storage.getMerkleProofHistory(kFixtureTxid);
    expect(shape(history), [(kFixtureBlockHash, MerkleProofStatus.orphaned)],
        reason: 'the proof is kept, not deleted');
    expect(history.single.merkleProof, [bumpHex]);
    expect(history.single.statusChangedAt, DateTime.utc(2026, 9, 2), reason: 'the event time');

    await projection.handle(reverted());
    history = await storage.getMerkleProofHistory(kFixtureTxid);
    expect(shape(history), [(kFixtureBlockHash, MerkleProofStatus.orphaned)]);
    expect(history.single.statusChangedAt, DateTime.utc(2026, 9, 2));
  });

  test('mny: replaying import and revert after a re-mine keeps the newer proof current', () async {
    // The fixture block left the active chain (another header at its height)
    // and ARCActor stored the proof of the block the transaction was mined
    // in again.
    await storage.storeBlockHeader(otherHeaderAtFixtureHeight(), kFixtureHeight);
    final newBlock = 'ab' * 32;
    await storage.storeMerkleProof(kFixtureTxid, MerkleProof(
      txid: kFixtureTxid,
      blockHash: newBlock,
      blockHeight: kFixtureHeight + 5,
      position: 0,
      merkleProof: ['fe${'cd' * 32}'],
      status: MerkleProofStatus.verified,
    ));

    await projection.handle(imported());
    await projection.handle(reverted());

    expect((await storage.getMerkleProof(kFixtureTxid))!.blockHash, newBlock,
        reason: 'the replayed, orphaned proof must not displace the current one');
    final history = await storage.getMerkleProofHistory(kFixtureTxid);
    // azl: the replayed proof is rejected against today's header, then the
    // revert names the block it was verified in: orphaned there, as live.
    expect(shape(history), [(newBlock, MerkleProofStatus.verified), (kFixtureBlockHash, MerkleProofStatus.orphaned)]);
    expect(history.last.merkleProof, [bumpHex]);
  });

  // 9ek (libspiffy-9ek): a confirmation from ARC journals the proof that
  // backs it; the projection stores that proof from the event.
  group('9ek: TransactionConfirmedEvent carries its proof', () {
    TransactionConfirmedEvent confirmed({String? bump}) => TransactionConfirmedEvent(
          walletId: walletId,
          txid: kFixtureTxid,
          blockHeight: kFixtureHeight,
          blockHash: kFixtureBlockHash,
          bumpHex: bump,
          version: 3,
          timestamp: DateTime.utc(2026, 9, 3),
        );

    List<(String?, MerkleProofStatus, String, int)> rows(List<MerkleProof> history) =>
        [for (final p in history) (p.blockHash, p.status, p.merkleProof.join(), p.position)];

    test('with its header stored the proof is verified, bound to that block at the txid position', () async {
      await storage.storeBlockHeader(fixtureHeader(), kFixtureHeight);
      await projection.handle(confirmed(bump: bumpHex));

      final proof = (await storage.getMerkleProof(kFixtureTxid))!;
      expect((proof.blockHash, proof.status), (kFixtureBlockHash, MerkleProofStatus.verified));
      expect(proof.merkleProof, [bumpHex]);
      expect(proof.position, kFixtureIndex, reason: 'position is the txid offset in the block');
      expect(proof.blockHeight, kFixtureHeight);
    });

    test('without its header the proof is pendingHeader, for SPVActor to verify when the header arrives', () async {
      await projection.handle(confirmed(bump: bumpHex));

      final proof = (await storage.getMerkleProof(kFixtureTxid))!;
      expect((proof.blockHash, proof.status), (null, MerkleProofStatus.pendingHeader));
    });

    test('replaying the journal twice yields the same proof rows and statuses', () async {
      await storage.storeBlockHeader(fixtureHeader(), kFixtureHeight);
      final journal = [imported(), reverted(), confirmed(bump: bumpHex)];
      for (final e in journal) {
        await projection.handle(e);
      }
      final once = rows(await storage.getMerkleProofHistory(kFixtureTxid));
      expect(once, [(kFixtureBlockHash, MerkleProofStatus.verified, bumpHex, kFixtureIndex)]);

      for (final e in journal) {
        await projection.handle(e);
      }
      expect(rows(await storage.getMerkleProofHistory(kFixtureTxid)), once);
    });

    test('a row journaled before the BUMP was carried replays: no proof, no error', () async {
      await storage.storeBlockHeader(fixtureHeader(), kFixtureHeight);
      final legacy = confirmed().toMap();
      expect(legacy.containsKey('bumpHex'), isFalse, reason: 'an event without a BUMP writes the old row shape');

      final event = TransactionConfirmedEvent.fromMap(legacy);
      expect(event.bumpHex, isNull);
      await projection.handle(event);
      expect(await storage.getMerkleProofHistory(kFixtureTxid), isEmpty);

      final roundTrip = TransactionConfirmedEvent.fromMap(confirmed(bump: bumpHex).toMap());
      expect(roundTrip.bumpHex, bumpHex);
    });
  });
  // azl (libspiffy-azl): a proof whose root contradicts the stored header at
  // its height was stored as pendingHeader, so it stayed the transaction's
  // current proof and AncestorChainService put it into BEEFs.
  group('azl: a proof that contradicts the stored header', () {
    final tamperedHex = fixtureBumpHex(tamperLevel: 0);

    TransactionConfirmedEvent confirmedWith(String bump, {int version = 3}) => TransactionConfirmedEvent(
          walletId: walletId,
          txid: kFixtureTxid,
          blockHeight: kFixtureHeight,
          blockHash: kFixtureBlockHash,
          bumpHex: bump,
          version: version,
          timestamp: DateTime.utc(2026, 9, 3),
        );

    List<(String?, String, String)> rows(List<MerkleProof> history) =>
        [for (final p in history) (p.blockHash, p.status.name, p.merkleProof.join())];

    test('imported against another header at its height: kept, but not the current proof', () async {
      await storage.storeBlockHeader(otherHeaderAtFixtureHeight(), kFixtureHeight);
      await projection.handle(imported());

      expect(await storage.getMerkleProof(kFixtureTxid), isNull,
          reason: 'a proof our header chain contradicts is not the current proof');
      expect(await storage.getMerkleProofsBatch([kFixtureTxid]), isEmpty);
      expect(rows(await storage.getMerkleProofHistory(kFixtureTxid)), [(null, 'rejected', bumpHex)],
          reason: 'the proof is kept (retention), with no block hash');
      expect(await storage.getMerkleProofsByStatus(MerkleProofStatus.pendingHeader), isEmpty,
          reason: 'it is not waiting for a header: the header is here and does not match');
    });

    test('a tampered BUMP confirmed against the real header is rejected, and a replay changes nothing', () async {
      await storage.storeBlockHeader(fixtureHeader(), kFixtureHeight);
      await projection.handle(confirmedWith(tamperedHex));

      expect(await storage.getMerkleProof(kFixtureTxid), isNull);
      final once = rows(await storage.getMerkleProofHistory(kFixtureTxid));
      expect(once, [(null, 'rejected', tamperedHex)]);

      await projection.handle(confirmedWith(tamperedHex));
      expect(rows(await storage.getMerkleProofHistory(kFixtureTxid)), once);
    });

    test('a rejected proof does not displace the verified proof of the transaction', () async {
      await storage.storeBlockHeader(fixtureHeader(), kFixtureHeight);
      await projection.handle(confirmedWith(bumpHex));
      await projection.handle(confirmedWith(tamperedHex, version: 4));

      final current = (await storage.getMerkleProof(kFixtureTxid))!;
      expect((current.blockHash, current.status.name, current.merkleProof.join()),
          (kFixtureBlockHash, 'verified', bumpHex));
      expect(rows(await storage.getMerkleProofHistory(kFixtureTxid)), [
        (kFixtureBlockHash, 'verified', bumpHex),
        (null, 'rejected', tamperedHex),
      ]);
    });

    test('a later valid proof of the transaction becomes the current proof; the rejected one stays', () async {
      await storage.storeBlockHeader(fixtureHeader(), kFixtureHeight);
      await projection.handle(confirmedWith(tamperedHex));
      await projection.handle(confirmedWith(bumpHex, version: 4));

      final current = (await storage.getMerkleProof(kFixtureTxid))!;
      expect((current.blockHash, current.status.name, current.merkleProof.join()),
          (kFixtureBlockHash, 'verified', bumpHex));
      expect(rows(await storage.getMerkleProofHistory(kFixtureTxid)), [
        (null, 'rejected', tamperedHex),
        (kFixtureBlockHash, 'verified', bumpHex),
      ]);
    });

    test('the same proof verifies in place once the active header at its height matches', () async {
      await storage.storeBlockHeader(otherHeaderAtFixtureHeight(), kFixtureHeight);
      await projection.handle(imported());
      await storage.storeBlockHeader(fixtureHeader(), kFixtureHeight); // the chain moved to the proof's block
      await projection.handle(imported());

      expect(rows(await storage.getMerkleProofHistory(kFixtureTxid)), [(kFixtureBlockHash, 'verified', bumpHex)]);
    });

    test('a verified proof whose header at its height changed is orphaned, not left current', () async {
      await storage.storeBlockHeader(fixtureHeader(), kFixtureHeight);
      await projection.handle(imported());
      await storage.storeBlockHeader(otherHeaderAtFixtureHeight(), kFixtureHeight); // its block left the chain
      await projection.handle(imported()); // replay over the existing read model

      expect(await storage.getMerkleProof(kFixtureTxid), isNull);
      expect(rows(await storage.getMerkleProofHistory(kFixtureTxid)), [(kFixtureBlockHash, 'orphaned', bumpHex)]);
    });

    test('a rebuild after a reorganization records the reverted proof as orphaned on its block, as live', () async {
      // Live: the proof was verified in the fixture block, the block left the
      // chain, SPVActor marked the proof orphaned and journaled the revert.
      // A rebuild meets the proof against today's header (rejected) and then
      // the revert naming its block: the proof was verified once, so orphaned.
      await storage.storeBlockHeader(otherHeaderAtFixtureHeight(), kFixtureHeight);
      await projection.handle(imported());
      await projection.handle(reverted());

      expect(rows(await storage.getMerkleProofHistory(kFixtureTxid)), [(kFixtureBlockHash, 'orphaned', bumpHex)]);
      await projection.handle(imported());
      await projection.handle(reverted());
      expect(rows(await storage.getMerkleProofHistory(kFixtureTxid)), [(kFixtureBlockHash, 'orphaned', bumpHex)],
          reason: 'a second replay changes nothing');
    });

    test('yix: a rebuild without the header at its height still records the reverted proof on its block', () async {
      // Live: verified in the fixture block, then orphaned there. A rebuild
      // before headers are synced stores the proof pendingHeader (no block
      // hash); the revert names the block, and the orphaned row keeps it.
      await projection.handle(imported());
      await projection.handle(reverted());

      expect(rows(await storage.getMerkleProofHistory(kFixtureTxid)), [(kFixtureBlockHash, 'orphaned', bumpHex)]);
      await projection.handle(imported());
      await projection.handle(reverted());
      expect(rows(await storage.getMerkleProofHistory(kFixtureTxid)), [(kFixtureBlockHash, 'orphaned', bumpHex)],
          reason: 'a second replay changes nothing');
    });

    test('a received ancestor whose BUMP contradicts the stored header is not a current proof', () async {
      await storage.storeBlockHeader(fixtureHeader(), kFixtureHeight);
      await projection.handle(TransactionImportedEvent(
        walletId: walletId,
        txid: kFixture2Txid,
        rawHex: kFixture2TxHex,
        blockHeight: 0,
        bumpProof: '',
        totalOutputSats: 200000000,
        numInputs: 1,
        numOutputs: 2,
        txVersion: 2,
        txLockTime: 0,
        walletReceivingAddresses: const [],
        walletReceivedSats: 0,
        totalInputSats: 0,
        sendingAddresses: const [],
        ancestors: [BeefAncestor(txid: kFixtureTxid, rawHex: kFixtureTxHex, bumpHex: tamperedHex)],
        version: 1,
        timestamp: DateTime.utc(2026, 9, 1),
      ));

      expect(await storage.getAncestorTransactionsBatch([kFixtureTxid]), {kFixtureTxid: kFixtureTxHex});
      expect(await storage.getMerkleProof(kFixtureTxid), isNull);
      expect(rows(await storage.getMerkleProofHistory(kFixtureTxid)), [(null, 'rejected', tamperedHex)]);
    });
  });

}

/// WalletProjection takes an EventStore but never reads from it; handle() is
/// driven directly here.
class _NoopEventStore implements EventStore {
  @override
  Future<void> persistEvent(String persistenceId, Event event, int expectedVersion) async {}

  @override
  Future<void> persistEvents(String persistenceId, List<Event> events, int expectedVersion) async {}

  @override
  Future<List<Event>> getEvents(String persistenceId, {int fromSequence = 0, int? toSequence}) async => [];

  @override
  Future<int> getHighestSequenceNumber(String persistenceId) async => 0;

  @override
  Future<void> saveSnapshot(String persistenceId, dynamic state, int sequenceNumber) async {}

  @override
  Future<SnapshotData?> loadSnapshot(String persistenceId) async => null;

  @override
  Future<void> deleteOldSnapshots(String persistenceId, int keepCount) async {}

  @override
  Future<void> close() async {}
}
