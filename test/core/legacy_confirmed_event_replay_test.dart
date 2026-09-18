// Data retention for bead libspiffy-9ek: TransactionConfirmedEvent now
// carries the BUMP that proved the confirmation (`bumpHex`). Journals written
// before it have TransactionConfirmedEvent rows without that key; they must
// still load in the wallet aggregate and replay through WalletProjection
// (without a proof, since none was journaled), next to new rows that carry it.
import 'dart:io';

import 'package:eventador/eventador.dart';
import 'package:libspiffy/internals.dart';
import 'package:libspiffy/libspiffy.dart';
import 'package:libspiffy/src/projections/wallet_projection.dart';
import 'package:test/test.dart';

import '../integration/isar_test_helper.dart';
import '../spv/testnet_proof_fixture.dart';

const _mnemonic =
    'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';

/// A row exactly as the release before 9ek stored it.
class _OldRow extends Event {
  final Map<String, dynamic> payload;

  _OldRow(this.payload, Event original)
      : super(
          eventId: original.eventId,
          timestamp: original.timestamp,
          version: original.version,
        );

  @override
  String get typeName => payload['type'] as String;

  @override
  Map<String, dynamic> toMap() => payload;
}

void main() {
  final crypto = DartSVCryptoService();
  late Directory dir;
  late IsarEventStore store;

  setUpAll(ensureIsarInitialized);

  setUp(() async {
    EventRegistry.clear();
    LibSpiffyActorSystem.registerEventTypes();
    dir = await Directory.systemTemp.createTemp('legacy_confirmed_');
    store = await IsarEventStore.create(
        directory: dir.path, name: 'legacy_confirmed_${DateTime.now().microsecondsSinceEpoch}');
  });

  tearDown(() async {
    await store.close();
    await dir.delete(recursive: true);
  });

  test('9ek: a TransactionConfirmedEvent row without bumpHex loads and replays; a new row stores its proof',
      () async {
    const walletId = 'legacy-confirmed-wallet';
    const persistenceId = 'Wallet_$walletId';
    final secrets = InMemorySecureStorage();

    BitcoinWalletAggregate aggregate() => BitcoinWalletAggregate(
          aggregateId: walletId,
          aggregateType: 'Wallet',
          eventStore: store,
          cryptoService: crypto,
          secureStorage: secrets,
        );

    final writer = aggregate();
    await writer.preStart();
    await writer.commandHandler(CreateWalletCommand(walletId: walletId, walletName: 'w', mnemonic: _mnemonic));
    await writer.commandHandler(RecordImportedTransactionCommand(
      walletId: walletId,
      txid: kFixtureTxid,
      rawHex: kFixtureTxHex,
      blockHeight: null,
      bumpProofHex: '',
      totalOutputSats: 91296559239,
      numInputs: 1,
      numOutputs: 2,
      txVersion: 2,
      txLockTime: 0,
      walletReceivingAddresses: const [],
      walletReceivedSats: 0,
      totalInputSats: 0,
      sendingAddresses: const [],
    ));

    // The pre-9ek row: txid, blockHeight and blockHash only.
    final seq = await store.getHighestSequenceNumber(persistenceId);
    final original = TransactionConfirmedEvent(
      walletId: walletId,
      txid: kFixtureTxid,
      blockHeight: kFixtureHeight,
      blockHash: kFixtureBlockHash,
      version: seq + 1,
      timestamp: DateTime.utc(2026, 9, 1),
    );
    final oldPayload = Map<String, dynamic>.of(original.toMap())..remove('bumpHex');
    expect(oldPayload.keys, isNot(contains('bumpHex')));
    await store.persistEvent(persistenceId, _OldRow(oldPayload, original), seq);

    // The aggregate recovers over the old row and keeps accepting commands.
    final reader = aggregate();
    await reader.preStart();
    expect(reader.currentState.version, seq + 1);
    await reader.commandHandler(ConfirmTransactionCommand(
      walletId: walletId,
      txid: kFixtureTxid,
      blockHeight: kFixtureHeight,
      blockHash: kFixtureBlockHash,
      bumpHex: fixtureBumpHex(),
    ));

    final events = await store.getEvents(persistenceId);
    final confirmations = events.whereType<TransactionConfirmedEvent>().toList();
    expect([for (final e in confirmations) e.bumpHex], [null, fixtureBumpHex()],
        reason: 'the old row loads with no BUMP; the new row keeps its BUMP through the journal');

    // Replay the old part of the journal: the transaction is confirmed, no
    // proof (none was journaled), no error.
    final storage = InMemoryWalletStorage();
    await storage.storeBlockHeader(fixtureHeader(), kFixtureHeight);
    final projection = WalletProjection(projectionId: 'legacy-confirmed', eventStore: store, storage: storage);
    final oldJournal = events.takeWhile((e) => !identical(e, confirmations.last)).toList();
    for (final e in oldJournal) {
      await projection.handle(e);
    }
    final tx = (await storage.getTransaction(kFixtureTxid, walletId: walletId))!;
    expect((tx.status, tx.blockHeight), (TransactionStatus.confirmed, kFixtureHeight));
    expect(await storage.getMerkleProofHistory(kFixtureTxid), isEmpty);

    // The new row stores the journaled proof.
    await projection.handle(confirmations.last);
    final proof = (await storage.getMerkleProof(kFixtureTxid))!;
    expect((proof.blockHash, proof.status), (kFixtureBlockHash, MerkleProofStatus.verified));
    expect(proof.merkleProof, [fixtureBumpHex()]);
  });
}
