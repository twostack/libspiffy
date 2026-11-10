/// spiffyvault-emk.4: a restored transaction whose merkle proof could not be
/// checked against a block header we hold is not confirmed.
///
/// A fresh install starts its header chain at a checkpoint (emk.1), so a
/// restore finds transactions below it before the older headers are filled
/// in. The importer then journals the BUMP without a height (the height is
/// what says "confirmed"); the read model keeps the transaction pending and
/// the proof waiting for its header, also when that header is stored by
/// the time the event is handled, because the wallet has not confirmed it.
/// SPVActor confirms it from the waiting proof (covered by
/// spv_proof_settles_confirmation_test.dart).
///
/// Real data: the testnet fixture transaction, its BUMP and its block header.
import 'package:eventador/eventador.dart';
import 'package:test/test.dart';

import 'package:libspiffy/src/core/wallet_events.dart';
import 'package:libspiffy/src/models/bitcoin_transaction.dart';
import 'package:libspiffy/src/projections/wallet_projection.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';
import 'package:libspiffy/src/storage/read_model_storage.dart';

import '../spv/testnet_proof_fixture.dart';

void main() {
  const walletId = 'unchecked-import-wallet';
  final bumpHex = fixtureBumpHex();

  late InMemoryWalletStorage storage;
  late WalletProjection projection;

  setUp(() {
    storage = InMemoryWalletStorage();
    projection = WalletProjection(
      projectionId: 'wallet-projection-unchecked-import-test',
      eventStore: _NoopEventStore(),
      storage: storage,
    );
  });

  TransactionImportedEvent imported({required int? height, int version = 1}) => TransactionImportedEvent(
        walletId: walletId,
        txid: kFixtureTxid,
        rawHex: kFixtureTxHex,
        blockHeight: height,
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
        version: version,
        timestamp: DateTime.utc(2026, 11, 10),
      );

  Future<BitcoinTransaction> row() async =>
      (await storage.getTransactionsByTxids([kFixtureTxid])).single;

  test('a proof journaled without a height leaves the transaction pending and the proof waiting', () async {
    await projection.handle(imported(height: null));

    final tx = await row();
    expect((tx.status, tx.blockHeight), (TransactionStatus.pending, null));
    final proof = (await storage.getMerkleProof(kFixtureTxid))!;
    expect((proof.status, proof.blockHash), (MerkleProofStatus.pendingHeader, null));
    expect(proof.merkleProof, [bumpHex], reason: 'the BUMP is kept for the check once the header arrives');
  });

  test('the proof waits even when its header is stored by the time the event is handled', () async {
    await storage.storeBlockHeader(fixtureHeader(), kFixtureHeight);
    await projection.handle(imported(height: null));

    expect((await row()).status, TransactionStatus.pending);
    expect((await storage.getMerkleProof(kFixtureTxid))!.status, MerkleProofStatus.pendingHeader,
        reason: 'the wallet has not confirmed it: SPVActor must find it among the waiting proofs');
  });

  test('a proof journaled with a height confirms, as before', () async {
    await storage.storeBlockHeader(fixtureHeader(), kFixtureHeight);
    await projection.handle(imported(height: kFixtureHeight));

    final tx = await row();
    expect((tx.status, tx.blockHeight), (TransactionStatus.confirmed, kFixtureHeight));
    final proof = (await storage.getMerkleProof(kFixtureTxid))!;
    expect((proof.status, proof.blockHash), (MerkleProofStatus.verified, kFixtureBlockHash));
  });

  test('a re-delivery without a height keeps the confirmation its proof already made', () async {
    await storage.storeBlockHeader(fixtureHeader(), kFixtureHeight);
    await projection.handle(imported(height: kFixtureHeight));
    await projection.handle(imported(height: null, version: 2));

    final proof = (await storage.getMerkleProof(kFixtureTxid))!;
    expect((proof.status, proof.blockHash), (MerkleProofStatus.verified, kFixtureBlockHash));
    expect((await row()).status, TransactionStatus.confirmed);
  });
}

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
