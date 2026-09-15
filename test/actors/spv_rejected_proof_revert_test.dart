/// azl (libspiffy-azl): a confirmation whose only proof the header chain
/// contradicts is not a confirmation. SPVActor, on a header notification,
/// takes back such confirmations: a pendingHeader proof that fails its
/// header becomes rejected and its confirmation is reverted; a confirmation
/// resting only on a proof WalletProjection stored as rejected is reverted
/// too. Each is reverted once, however many notifications arrive before the
/// projection applies the revert.
///
/// SPVActor runs against an in-memory read model with no projection: the
/// wallet manager and ARC are recorders, so a transaction stays confirmed in
/// the read model and a second revert would show.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:dactor/dactor.dart';
import 'package:libspiffy/src/actors/spv_actor.dart';
import 'package:libspiffy/src/actors/spv_messages.dart' show BlockHeaderStoredMessage;
import 'package:libspiffy/src/actors/wallet_messages.dart';
import 'package:libspiffy/src/core/wallet_commands.dart';
import 'package:libspiffy/src/models/bitcoin_transaction.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';
import 'package:libspiffy/src/storage/read_model_storage.dart';
import 'package:libspiffy/src/utils/beef.dart';
import 'package:test/test.dart';

import '../spv/testnet_proof_fixture.dart';

void main() {
  final tamperedHex = fixtureBumpHex(tamperLevel: 0);

  late LocalActorSystem system;
  late _CountingStorage storage;
  late _Recorder walletManager;
  late _Recorder arc;
  late ActorRef spv;
  late ActorRef walletManagerRef;
  late ActorRef arcRef;

  BitcoinTransaction confirmedRow(String walletId, String txid, String rawHex) => BitcoinTransaction(
        walletId: walletId,
        txid: txid,
        rawHex: rawHex,
        status: TransactionStatus.confirmed,
        blockHeight: kFixtureHeight,
        confirmations: 6,
        inputValue: BigInt.zero,
        outputValue: BigInt.zero,
        fee: BigInt.zero,
        receivingAddresses: const [],
        sendingAddresses: const [],
        netAmount: BigInt.zero,
        createdAt: DateTime.utc(2026, 9, 1),
        updatedAt: DateTime.utc(2026, 9, 1),
        lockTime: 0,
        version: 2,
      );

  MerkleProof proofOf(String txid, String bump, MerkleProofStatus status, {String? blockHash}) => MerkleProof(
        txid: txid,
        blockHash: blockHash,
        blockHeight: kFixtureHeight,
        position: kFixtureIndex,
        merkleProof: [bump],
        status: status,
      );

  setUp(() async {
    system = LocalActorSystem(ActorSystemConfig());
    storage = _CountingStorage();
    await storage.storeBlockHeader(fixtureHeader(), kFixtureHeight);
    final tag = DateTime.now().microsecondsSinceEpoch;
    walletManager = _Recorder();
    arc = _Recorder();
    walletManagerRef = await system.spawn('wm-$tag', () => walletManager);
    arcRef = await system.spawn('arc-$tag', () => arc);
    spv = await system.spawn('spv-$tag',
        () => SPVActor(walletManager: walletManagerRef, invoiceCoordinator: walletManagerRef, storage: storage, arcActor: arcRef));
  });

  tearDown(() => system.shutdown());

  /// One header notification, and wait until SPVActor has handled it (its
  /// mailbox is sequential: the reply to a later message comes after), then
  /// until the recorders have received what it sent (bead snhj: a recorder
  /// may not have run yet when SPVActor's barrier reply arrives).
  Future<void> notifyHeaderStored() async {
    spv.tell(BlockHeaderStoredMessage(header: fixtureHeader(), height: kFixtureHeight + 1));
    final done = Completer<void>();
    final barrier = await system.spawn('barrier-${DateTime.now().microsecondsSinceEpoch}', () => _Barrier(done));
    spv.tell(
      ReceiveTransactionMessage(
        transactionId: 'barrier',
        beef: BEEF.create(bumps: const [], txs: [Uint8List.fromList(hex.decode(kFixture2TxHex))], hasMerkle: [false], bumpIndex: const []),
        fromCounterparty: 'barrier',
      ),
      sender: barrier,
    );
    await done.future.timeout(const Duration(seconds: 10));
    for (final recorder in [walletManagerRef, arcRef]) {
      final flushed = _Flush();
      recorder.tell(flushed);
      await flushed.done.future.timeout(const Duration(seconds: 10));
    }
  }

  List<RevertTransactionConfirmationCommand> reverts() => [
        for (final m in walletManager.messages)
          if (m is WalletCommandMessage && m.command is RevertTransactionConfirmationCommand)
            m.command as RevertTransactionConfirmationCommand,
      ];

  List<List<String>> arcPolls() => [
        for (final m in arc.messages)
          if (m is TransactionConfirmationsRevertedMessage) m.txids,
      ];

  test('a confirmation resting only on a rejected proof is reverted once, in every wallet holding it', () async {
    await storage.storeTransaction('w1', confirmedRow('w1', kFixtureTxid, kFixtureTxHex));
    await storage.storeTransaction('w2', confirmedRow('w2', kFixtureTxid, kFixtureTxHex));
    await storage.storeMerkleProof(kFixtureTxid, proofOf(kFixtureTxid, tamperedHex, MerkleProofStatus.rejected));

    await notifyHeaderStored();
    await notifyHeaderStored(); // before any projection has applied the revert

    expect([for (final r in reverts()) (r.walletId, r.txid, r.blockHash, r.merkleProof?.join())]..sort((a, b) => a.$1.compareTo(b.$1)), [
      ('w1', kFixtureTxid, null, tamperedHex),
      ('w2', kFixtureTxid, null, tamperedHex),
    ]);
    expect(arcPolls(), [
      [kFixtureTxid]
    ], reason: 'ARC is asked once for a real proof');
    expect([for (final p in await storage.getMerkleProofHistory(kFixtureTxid)) p.status], [MerkleProofStatus.rejected],
        reason: 'the proof is kept');
  });

  test('a pendingHeader proof that fails its header is rejected in place and its confirmation reverted once', () async {
    await storage.storeTransaction('w1', confirmedRow('w1', kFixtureTxid, kFixtureTxHex));
    await storage.storeMerkleProof(kFixtureTxid, proofOf(kFixtureTxid, tamperedHex, MerkleProofStatus.pendingHeader));

    await notifyHeaderStored();
    await notifyHeaderStored();

    expect([for (final p in await storage.getMerkleProofHistory(kFixtureTxid)) (p.blockHash, p.status, p.merkleProof.join())],
        [(null, MerkleProofStatus.rejected, tamperedHex)]);
    expect(await storage.getMerkleProof(kFixtureTxid), isNull);
    expect([for (final r in reverts()) (r.walletId, r.txid)], [('w1', kFixtureTxid)],
        reason: 'the rejected-proof pass must not revert it a second time');
    expect(arcPolls(), [
      [kFixtureTxid]
    ]);
  });

  test('a rejected proof reverts nothing when a current proof backs the transaction or no wallet holds it', () async {
    // Backed by a verified proof.
    await storage.storeTransaction('w1', confirmedRow('w1', kFixtureTxid, kFixtureTxHex));
    await storage.storeMerkleProof(
        kFixtureTxid, proofOf(kFixtureTxid, fixtureBumpHex(), MerkleProofStatus.verified, blockHash: kFixtureBlockHash));
    await storage.storeMerkleProof(kFixtureTxid, proofOf(kFixtureTxid, tamperedHex, MerkleProofStatus.rejected));
    // A received ancestor: no wallet transaction row.
    await storage.storeAncestorTransaction(kFixture2Txid, kFixture2TxHex);
    await storage.storeMerkleProof(kFixture2Txid, proofOf(kFixture2Txid, 'fe${'ab' * 40}', MerkleProofStatus.rejected));

    storage.confirmedScans = 0;
    await notifyHeaderStored();

    expect(reverts(), isEmpty);
    expect(arcPolls(), isEmpty);
    expect(storage.confirmedScans, 0,
        reason: 'rejected proofs no wallet transaction rests on do not load every confirmed transaction');
    expect((await storage.getMerkleProof(kFixtureTxid))!.status, MerkleProofStatus.verified);
  });
}

class _CountingStorage extends InMemoryWalletStorage {
  int confirmedScans = 0;

  @override
  Future<List<BitcoinTransaction>> getTransactionsByStatus(TransactionStatus status, {String? walletId}) {
    if (status == TransactionStatus.confirmed) confirmedScans++;
    return super.getTransactionsByStatus(status, walletId: walletId);
  }
}

class _Recorder extends Actor {
  final List<Object?> messages = [];

  @override
  Future<void> onMessage(dynamic message) async {
    if (message is _Flush) {
      message.done.complete();
    } else {
      messages.add(message);
    }
  }
}

/// Completed by the recorder that receives it: every message told to it
/// before has been recorded.
class _Flush implements Message {
  final done = Completer<void>();
  final DateTime _timestamp = DateTime.now();

  @override
  String get correlationId => 'flush-${_timestamp.microsecondsSinceEpoch}';
  @override
  Map<String, dynamic> get metadata => const {};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => _timestamp;
}

class _Barrier extends Actor {
  final Completer<void> done;
  _Barrier(this.done);

  @override
  Future<void> onMessage(dynamic message) async {
    if (!done.isCompleted) done.complete();
  }
}
