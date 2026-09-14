import 'dart:convert';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:eventador/eventador.dart';
import 'package:test/test.dart';

import 'package:libspiffy/src/core/wallet_events.dart';
import 'package:libspiffy/src/models/wallet_type.dart';
import 'package:libspiffy/src/projections/wallet_projection.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';
import 'package:libspiffy/src/utils/bump.dart';
import 'package:libspiffy/src/utils/crypto_utils.dart';

/// Audit 2026-09-14 SPV-06 (projection side): `_storeMerkleProofFromBump`
/// derived the transaction position from "the first leaf's offset" assuming
/// the library's own non-standard layout (level 0 = sibling only). Given a
/// real BRC-74 BUMP (level 0 = txid AND sibling, ordered by offset) it stored
/// the sibling's position for any even-indexed transaction, and flattened
/// every hash in the BUMP into a sibling list that no longer described the
/// path. The projection must store the raw BUMP and the txid leaf's offset.
void main() {
  const walletId = 'projection-merkle-proof-wallet';
  const pubKeyHash = '89abcdefabbaabbaabbaabbaabbaabbaabbaabba';
  const scriptPubKey = '76a914${pubKeyHash}88ac';
  final rootAddress =
      dartsv.Address.fromPubkeyHash(pubKeyHash, dartsv.NetworkType.MAIN).toBase58();

  Uint8List sha256d(List<int> data) =>
      Uint8List.fromList(sha256.convert(sha256.convert(data).bytes).bytes);
  Uint8List hashPair(Uint8List l, Uint8List r) => sha256d([...l, ...r]);
  Uint8List leaf(int i) => sha256d(utf8.encode('projection-merkle-leaf-$i'));

  late InMemoryWalletStorage storage;
  late WalletProjection projection;

  setUp(() async {
    storage = InMemoryWalletStorage();
    projection = WalletProjection(
      projectionId: 'wallet-projection-merkle-test',
      eventStore: _NoopEventStore(),
      storage: storage,
    );
    await projection.handle(WalletCreatedEvent(
      walletId: walletId,
      walletName: 'Merkle Proof Test',
      rootAddress: rootAddress,
      walletType: WalletType.hd,
      walletMetadata: {'network': 'main'},
      version: 1,
      timestamp: DateTime.utc(2026, 1, 1),
    ));
  });

  /// Imports [tx] with [bumpHex] and returns the stored proof.
  Future<dynamic> importWithBump(dartsv.Transaction tx, String bumpHex) async {
    await projection.handle(TransactionImportedEvent(
      walletId: walletId,
      txid: tx.id,
      rawHex: tx.serialize(),
      blockHeight: 500,
      bumpProof: bumpHex,
      totalOutputSats: 1000,
      numInputs: 1,
      numOutputs: 1,
      txVersion: 1,
      txLockTime: 0,
      walletReceivingAddresses: const [],
      walletReceivedSats: 0,
      totalInputSats: 1100,
      sendingAddresses: const [],
      version: 2,
      timestamp: DateTime.utc(2026, 1, 2),
    ));
    return storage.getMerkleProof(tx.id);
  }

  dartsv.Transaction sampleTx() {
    final tx = dartsv.Transaction()
      ..version = 1
      ..nLockTime = 0;
    tx.inputs.add(dartsv.TransactionInput('c' * 64, 0, dartsv.TransactionInput.MAX_SEQ_NUMBER));
    tx.outputs.add(dartsv.TransactionOutput(
        BigInt.from(1000), dartsv.SVScript.fromHex(scriptPubKey)));
    return tx;
  }

  test('a real-layout BUMP with the txid at an even position stores that position', () async {
    // 8-leaf block, our tx at index 4: level 0 (sorted by offset) lists the
    // txid leaf (4) BEFORE its sibling (5).
    final tx = sampleTx();
    final txidInternal = Uint8List.fromList(hex.decode(tx.id).reversed.toList());
    final leaves = [for (var i = 0; i < 8; i++) i == 4 ? txidInternal : leaf(i)];
    final l1 = [for (var i = 0; i < 8; i += 2) hashPair(leaves[i], leaves[i + 1])];
    final l2 = [hashPair(l1[0], l1[1]), hashPair(l1[2], l1[3])];
    final root = hashPair(l2[0], l2[1]);

    final bump = BUMP(blockHeight: 500, path: [
      Level(leaves: [
        Leaf(offset: 4, duplicate: false, isTxid: true, hash: txidInternal),
        Leaf(offset: 5, duplicate: false, isTxid: false, hash: leaves[5]),
      ]),
      Level(leaves: [Leaf(offset: 3, duplicate: false, isTxid: false, hash: l1[3])]),
      Level(leaves: [Leaf(offset: 0, duplicate: false, isTxid: false, hash: l2[0])]),
    ]);
    expect(hex.encode(bump.computeMerkleRoot(txidInternal)), hex.encode(root),
        reason: 'fixture sanity');
    final bumpHex = hex.encode(bump.serialize());

    final stored = await importWithBump(tx, bumpHex);
    expect(stored, isNotNull, reason: 'the proof must be stored');
    expect(stored.position, 4, reason: 'position is the txid leaf offset, not the sibling');
    expect(stored.blockHeight, 500);
    expect(stored.merkleProof, [bumpHex], reason: 'the raw BRC-74 BUMP is stored verbatim');

    // What the payment coordinator / ancestor chain service rebuild from
    // storage must be the same proof and reach the same root.
    final rebuilt = CryptoUtils.buildBUMPFromMerkleProof(stored);
    expect(hex.encode(rebuilt.serialize()), bumpHex);
    expect(hex.encode(rebuilt.computeMerkleRoot(txidInternal)), hex.encode(root));
  });

  test('a real-layout BUMP with a duplicate sibling stores the txid position', () async {
    // 3-leaf block, our tx at index 2: its level-0 sibling is a duplicate.
    final tx = sampleTx();
    final txidInternal = Uint8List.fromList(hex.decode(tx.id).reversed.toList());
    final l1 = [hashPair(leaf(0), leaf(1)), hashPair(txidInternal, txidInternal)];
    final bump = BUMP(blockHeight: 500, path: [
      Level(leaves: [
        Leaf(offset: 2, duplicate: false, isTxid: true, hash: txidInternal),
        Leaf(offset: 3, duplicate: true, isTxid: false),
      ]),
      Level(leaves: [Leaf(offset: 0, duplicate: false, isTxid: false, hash: l1[0])]),
    ]);
    final bumpHex = hex.encode(bump.serialize());

    final stored = await importWithBump(tx, bumpHex);
    expect(stored, isNotNull);
    expect(stored.position, 2);
    expect(stored.merkleProof, [bumpHex]);
  });

  test('a BUMP that does not contain the imported txid is not stored', () async {
    final tx = sampleTx();
    final other = leaf(9);
    final bump = BUMP(blockHeight: 500, path: [
      Level(leaves: [
        Leaf(offset: 0, duplicate: false, isTxid: true, hash: other),
        Leaf(offset: 1, duplicate: false, isTxid: false, hash: leaf(1)),
      ]),
    ]);
    final stored = await importWithBump(tx, hex.encode(bump.serialize()));
    expect(stored, isNull);
  });
}

/// WalletProjection takes an EventStore but never reads from it; handle() is
/// driven directly here.
class _NoopEventStore implements EventStore {
  @override
  Future<void> persistEvent(String persistenceId, Event event, int expectedVersion) async {}

  @override
  Future<void> persistEvents(
      String persistenceId, List<Event> events, int expectedVersion) async {}

  @override
  Future<List<Event>> getEvents(String persistenceId,
          {int fromSequence = 0, int? toSequence}) async =>
      [];

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
