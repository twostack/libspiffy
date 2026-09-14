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

  test('mny: a proof that does not match the stored header is left pendingHeader for SPVActor', () async {
    // Not verified, and not the projection's to reject: SPVActor re-checks
    // pendingHeader proofs when headers arrive and takes the confirmation
    // back (reorg_confirmation_revert_test.dart).
    await storage.storeBlockHeader(otherHeaderAtFixtureHeight(), kFixtureHeight);
    await projection.handle(imported());

    final proof = (await storage.getMerkleProof(kFixtureTxid))!;
    expect((proof.blockHash, proof.status), (null, MerkleProofStatus.pendingHeader));
  });

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
    expect(shape(history), [(newBlock, MerkleProofStatus.verified), (null, MerkleProofStatus.orphaned)]);
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
