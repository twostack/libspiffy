/// A merkle proof on our active header chain is the authority, at every
/// point of the proof's life (beads libspiffy-65ji and libspiffy-5bju).
///
/// * 65ji: a proof that arrived before its block header (pendingHeader) and
///   verifies once that header syncs confirms the transaction the wallet
///   recorded. SPVActor rewrote the row as verified and then waited for ARC,
///   which inverts the SPV model: the proof is better evidence than any
///   status string ARC can return, and ARC only knows transactions we
///   broadcast ourselves.
/// * 5bju (1): the mirror rule. A confirmation must rest on at least one
///   proof that is verified on the active chain, so a confirmation whose last
///   supporting proof was orphaned is reverted. Only proofs the projection
///   marked `rejected` were covered before; an orphaned one fell between the
///   rules. The proof row itself is kept either way — a reorganization can
///   put its block back on the active chain, and `_reviveProofs` restores the
///   confirmation from that very row.
///
/// SPVActor runs against an in-memory read model with no projection: the
/// wallet manager and ARC are recorders, so nothing but this actor moves.
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
  late LocalActorSystem system;
  late InMemoryWalletStorage storage;
  late _Recorder walletManager;
  late _Recorder arc;
  late ActorRef spv;
  late ActorRef walletManagerRef;
  late ActorRef arcRef;

  BitcoinTransaction row(String walletId, TransactionStatus status) => BitcoinTransaction(
        walletId: walletId,
        txid: kFixtureTxid,
        rawHex: kFixtureTxHex,
        status: status,
        blockHeight: status == TransactionStatus.confirmed ? kFixtureHeight : null,
        confirmations: status == TransactionStatus.confirmed ? 6 : 0,
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

  MerkleProof proofOf(MerkleProofStatus status, {String? blockHash}) => MerkleProof(
        txid: kFixtureTxid,
        blockHash: blockHash,
        blockHeight: kFixtureHeight,
        position: kFixtureIndex,
        merkleProof: [fixtureBumpHex()],
        status: status,
      );

  setUp(() async {
    system = LocalActorSystem(ActorSystemConfig());
    storage = InMemoryWalletStorage();
    final tag = DateTime.now().microsecondsSinceEpoch;
    walletManager = _Recorder();
    arc = _Recorder();
    walletManagerRef = await system.spawn('wm-$tag', () => walletManager);
    arcRef = await system.spawn('arc-$tag', () => arc);
    // No header is stored yet: the actor starts on an empty chain, so
    // nothing runs before the notification each test sends.
    spv = await system.spawn(
        'spv-$tag',
        () => SPVActor(
              walletManager: walletManagerRef,
              invoiceCoordinator: walletManagerRef,
              storage: storage,
              arcActor: arcRef,
            ));
  });

  tearDown(() => system.shutdown());

  /// One header notification, and wait until SPVActor has handled it (its
  /// mailbox is sequential) and the recorders have recorded what it sent.
  Future<void> notifyHeaderStored({int? height}) async {
    spv.tell(BlockHeaderStoredMessage(header: fixtureHeader(), height: height ?? kFixtureHeight));
    final done = Completer<void>();
    final barrier = await system.spawn('barrier-${DateTime.now().microsecondsSinceEpoch}', () => _Barrier(done));
    spv.tell(
      ReceiveTransactionMessage(
        transactionId: 'barrier',
        beef: BEEF.create(
            bumps: const [],
            txs: [Uint8List.fromList(hex.decode(kFixture2TxHex))],
            hasMerkle: [false],
            bumpIndex: const []),
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

  List<ConfirmTransactionCommand> confirmations() => [
        for (final m in walletManager.messages)
          if (m is WalletCommandMessage && m.command is ConfirmTransactionCommand) m.command as ConfirmTransactionCommand,
      ];

  List<RevertTransactionConfirmationCommand> reverts() => [
        for (final m in walletManager.messages)
          if (m is WalletCommandMessage && m.command is RevertTransactionConfirmationCommand)
            m.command as RevertTransactionConfirmationCommand,
      ];

  /// Everything told to ARC other than the routine "check storage pending
  /// UTXOs" nudge every header notification carries.
  List<Object?> arcWork() => [
        for (final m in arc.messages)
          if (m is! CheckStoragePendingUTXOsMessage) m,
      ];

  group('65ji: a pendingHeader proof that verifies confirms the transaction', () {
    test('the header arrives and the recorded transaction is confirmed, with no ARC involvement', () async {
      // Our own payment, recorded and outstanding; its proof reached us
      // before the header at its height.
      await storage.storeTransaction('w1', row('w1', TransactionStatus.pending));
      await storage.storeMerkleProof(kFixtureTxid, proofOf(MerkleProofStatus.pendingHeader));
      expect((await storage.getMerkleProof(kFixtureTxid))!.status, MerkleProofStatus.pendingHeader);

      // The header lands.
      await storage.storeBlockHeader(fixtureHeader(), kFixtureHeight);
      await notifyHeaderStored();

      expect([for (final c in confirmations()) (c.walletId, c.txid, c.blockHeight, c.blockHash, c.bumpHex)], [
        ('w1', kFixtureTxid, kFixtureHeight, kFixtureBlockHash, fixtureBumpHex()),
      ], reason: 'a proof that verifies on our chain must settle the transaction without waiting for ARC');
      expect(reverts(), isEmpty);
      expect(arcWork(), isEmpty, reason: 'the confirmation came from the proof alone');
      final proof = await storage.getMerkleProof(kFixtureTxid);
      expect((proof?.status, proof?.blockHash), (MerkleProofStatus.verified, kFixtureBlockHash));
    });

    test('a second notification does not confirm it again', () async {
      await storage.storeTransaction('w1', row('w1', TransactionStatus.pending));
      await storage.storeMerkleProof(kFixtureTxid, proofOf(MerkleProofStatus.pendingHeader));
      await storage.storeBlockHeader(fixtureHeader(), kFixtureHeight);

      await notifyHeaderStored();
      await notifyHeaderStored(height: kFixtureHeight + 1);

      expect(confirmations().length, 1,
          reason: 'the proof is verified after the first pass, so it is no longer a pendingHeader candidate');
    });

    test('a proof whose header still has not arrived confirms nothing', () async {
      await storage.storeTransaction('w1', row('w1', TransactionStatus.pending));
      await storage.storeMerkleProof(kFixtureTxid, proofOf(MerkleProofStatus.pendingHeader));

      await notifyHeaderStored();

      expect(confirmations(), isEmpty);
      expect((await storage.getMerkleProof(kFixtureTxid))!.status, MerkleProofStatus.pendingHeader);
    });
  });

  group('5bju (1): a confirmation resting only on an orphaned proof is reverted', () {
    /// Stores the proof verified and then takes its block off the active
    /// chain, the way a reorganization does; the row is kept, orphaned.
    ///
    /// The header now on the active chain at that height is another block,
    /// so the proof really is off the chain: one that still walks to the
    /// active header's root is revived and re-confirmed instead
    /// ([SPVActor._reviveProofs]), which is a different rule.
    Future<void> orphanTheOnlyProof() async {
      await storage.storeBlockHeader(otherHeaderAtFixtureHeight(), kFixtureHeight);
      await storage.storeMerkleProof(kFixtureTxid, proofOf(MerkleProofStatus.verified, blockHash: kFixtureBlockHash));
      expect(
          await storage.markMerkleProofOrphaned(kFixtureTxid,
              blockHash: kFixtureBlockHash, onlyIfMerkleProof: [fixtureBumpHex()]),
          isTrue);
      expect(await storage.getMerkleProof(kFixtureTxid), isNull, reason: 'no proof backs the confirmation any more');
    }

    test('the full sweep reverts it and keeps the proof row', () async {
      await storage.storeTransaction('w1', row('w1', TransactionStatus.confirmed));
      await storage.storeTransaction('w2', row('w2', TransactionStatus.confirmed));
      await orphanTheOnlyProof();

      await notifyHeaderStored();
      await notifyHeaderStored(); // before any projection has applied the revert

      expect([for (final r in reverts()) (r.walletId, r.txid)]..sort((a, b) => a.$1.compareTo(b.$1)), [
        ('w1', kFixtureTxid),
        ('w2', kFixtureTxid),
      ], reason: 'a confirmation with no proof on the active chain is not a confirmation');
      expect(arcWork(), [
        isA<TransactionConfirmationsRevertedMessage>(),
      ], reason: 'ARC is asked once for a real proof');
      expect([for (final p in await storage.getMerkleProofHistory(kFixtureTxid)) p.status],
          [MerkleProofStatus.orphaned],
          reason: 'the orphaned proof is kept: a reorganization can make its block active again');
      expect(confirmations(), isEmpty);
    });

    test('the incremental feed reverts a confirmation orphaned after the first pass', () async {
      await storage.storeBlockHeader(otherHeaderAtFixtureHeight(), kFixtureHeight);
      // First pass: nothing to do, and it sets the incremental starting point.
      await notifyHeaderStored();
      expect(reverts(), isEmpty);

      await storage.storeTransaction('w1', row('w1', TransactionStatus.confirmed));
      await orphanTheOnlyProof();
      await notifyHeaderStored();

      expect([for (final r in reverts()) (r.walletId, r.txid)], [('w1', kFixtureTxid)]);
      expect([for (final p in await storage.getMerkleProofHistory(kFixtureTxid)) p.status],
          [MerkleProofStatus.orphaned]);
    });

    test('a confirmation a verified proof still backs is left alone', () async {
      await storage.storeTransaction('w1', row('w1', TransactionStatus.confirmed));
      await storage.storeMerkleProof(kFixtureTxid, proofOf(MerkleProofStatus.verified, blockHash: kFixtureBlockHash));
      await storage.storeBlockHeader(fixtureHeader(), kFixtureHeight);

      await notifyHeaderStored();

      expect(reverts(), isEmpty);
      expect(arcWork(), isEmpty);
    });
  });
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
