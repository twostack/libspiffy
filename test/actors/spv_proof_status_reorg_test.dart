/// Proof status through header-chain reorganizations (beads libspiffy-10r,
/// libspiffy-hg0, libspiffy-yix part b).
///
/// * 10r (1): a rejected proof (the header at its height contradicted it) was
///   never checked again when a reorganization made active a chain on which
///   it verifies; only ARC re-polling could bring the confirmation back.
/// * 10r (2): the reorganization handler marked a pendingHeader proof above
///   the fork point whose header is still unknown orphaned (and reverted its
///   confirmation) instead of leaving it pendingHeader.
/// * 10r (3): the guard that reverts a rejected-only confirmation once lasted
///   for the actor's lifetime, so a later, different rejected-only
///   confirmation of the same txid was only caught after a restart.
/// * hg0: an orphaned proof was never revived when its block became active
///   again (a reorganization of a reorganization).
/// * yix (b): pendingHeader proofs whose header arrived while the node was
///   down were only checked on the next header notification.
///
/// SPVActor runs against an in-memory read model with no projection: the
/// wallet manager and ARC are recorders, so the commands it sends are
/// observed and the transaction rows only change when a test changes them.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart' show sha256;
import 'package:dactor/dactor.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:libspiffy/src/actors/spv_actor.dart';
import 'package:libspiffy/src/actors/spv_messages.dart' show BlockHeaderStoredMessage;
import 'package:libspiffy/src/actors/wallet_messages.dart';
import 'package:libspiffy/src/core/wallet_commands.dart';
import 'package:libspiffy/src/models/bitcoin_transaction.dart';
import 'package:libspiffy/src/models/bitcoin_utxo.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';
import 'package:libspiffy/src/storage/read_model_storage.dart';
import 'package:libspiffy/src/utils/beef.dart';
import 'package:libspiffy/src/utils/bump.dart';
import 'package:spiffynode/spiffy_node.dart';
import 'package:test/test.dart';

import '../spv/testnet_proof_fixture.dart';

String _hex64(String tag) => sha256.convert(utf8.encode(tag)).toString();

/// A BUMP proving [txid] at [height] in a two-transaction block ([variant]
/// changes the sibling, so the same txid gets a different proof), and the
/// merkle root that block's header must carry.
(String, Hash) _proofFor(String txid, int height, {String variant = ''}) {
  final internal = displayHexToInternal(txid);
  final sibling = Uint8List.fromList(hex.decode(_hex64('sibling-$txid-$height$variant')));
  final bump = BUMP.fromMerklePath(blockHeight: height, txid: internal, index: 0, siblings: [sibling]);
  return (bump.toHex(), Hash.fromBytes(bump.computeMerkleRoot(internal)));
}

BlockHeader _header(String seed, {Hash? merkleRoot}) => BlockHeader(
      version: 1,
      prevBlock: Hash.fromHex(_hex64('prev-$seed')),
      merkleRoot: merkleRoot ?? Hash.fromHex(_hex64('root-$seed')),
      timestamp: DateTime.fromMillisecondsSinceEpoch(1600000000000 + seed.hashCode.abs() % 100000, isUtc: true),
      bits: 0x1d00ffff,
      nonce: seed.hashCode.abs(),
    );

BitcoinTransaction _row(String walletId, String txid, TransactionStatus status, int? height, DateTime at) =>
    BitcoinTransaction(
      walletId: walletId,
      txid: txid,
      rawHex: '0100000000000000000000',
      status: status,
      blockHeight: height,
      confirmations: status == TransactionStatus.confirmed ? 6 : 0,
      inputValue: BigInt.zero,
      outputValue: BigInt.zero,
      fee: BigInt.zero,
      receivingAddresses: const [],
      sendingAddresses: const [],
      netAmount: BigInt.zero,
      createdAt: DateTime.utc(2026, 9, 1, 12),
      updatedAt: at,
      lockTime: 0,
      version: 2,
    );

BitcoinUtxo _utxo(String txid, int vout, UTXOStatus status) => BitcoinUtxo(
      txid: txid,
      vout: vout,
      value: dartsv.Coin.ofSat(BigInt.from(1000 + vout)),
      scriptPubKey: '76a914000000000000000000000000000000000000000088ac',
      address: 'mkHS9ne12qx9pS9VojpwU5xtRd4T7X7ZUt',
      status: status,
      createdAt: DateTime.utc(2026, 9, 1, 12),
      updatedAt: DateTime.utc(2026, 9, 1, 12),
    );

void main() {
  late LocalActorSystem system;
  late InMemoryWalletStorage storage;
  late _Recorder walletManager;
  late _Recorder arc;
  late ActorRef walletManagerRef;
  late ActorRef arcRef;
  ActorRef? spv;

  final tags = <String, String>{};
  String tx(String tag) {
    final h = _hex64('tx-$tag');
    tags[h] = tag;
    return h;
  }

  String tagOf(String? h) => h == null ? 'null' : (tags[h] ?? h);

  /// Store [header] as the active header at [height] and name its hash [tag].
  Future<String> activate(String tag, int height, {Hash? merkleRoot}) async {
    final header = _header(tag, merkleRoot: merkleRoot);
    await storage.storeBlockHeader(header, height);
    final hash = header.blockHash().toString();
    tags[hash] = tag;
    return hash;
  }

  String blockHash(String tag) {
    final h = _hex64('block-$tag');
    tags[h] = tag;
    return h;
  }

  MerkleProof proof(String txid, int height, MerkleProofStatus status, {String? hash, String variant = ''}) =>
      MerkleProof(
        txid: txid,
        blockHash: hash,
        blockHeight: height,
        position: 0,
        merkleProof: [_proofFor(txid, height, variant: variant).$1],
        status: status,
      );

  Future<ActorRef> spawnSpv() async => spv = await system.spawn('spv-${DateTime.now().microsecondsSinceEpoch}',
      () => SPVActor(walletManager: walletManagerRef, invoiceCoordinator: walletManagerRef, storage: storage, arcActor: arcRef));

  setUp(() async {
    tags.clear();
    spv = null;
    system = LocalActorSystem(ActorSystemConfig());
    storage = InMemoryWalletStorage();
    final tag = DateTime.now().microsecondsSinceEpoch;
    walletManager = _Recorder();
    arc = _Recorder();
    walletManagerRef = await system.spawn('wm-$tag', () => walletManager);
    arcRef = await system.spawn('arc-$tag', () => arc);
  });

  tearDown(() => system.shutdown());

  /// Wait until the recorders have received everything told to them so far.
  Future<void> flushRecorders() async {
    for (final recorder in [walletManagerRef, arcRef]) {
      final flushed = _Flush();
      recorder.tell(flushed);
      await flushed.done.future.timeout(const Duration(seconds: 10));
    }
  }

  /// Tell SPVActor [message] (if any) and wait until it has handled it, then
  /// until the recorders have received what it sent.
  Future<void> deliver([Message? message]) async {
    if (message != null) spv!.tell(message);
    final done = Completer<void>();
    final barrier = await system.spawn('barrier-${DateTime.now().microsecondsSinceEpoch}', () => _Barrier(done));
    spv!.tell(
      ReceiveTransactionMessage(
        transactionId: 'barrier',
        beef: BEEF.create(bumps: const [], txs: [Uint8List.fromList(hex.decode(kFixture2TxHex))], hasMerkle: [false], bumpIndex: const []),
        fromCounterparty: 'barrier',
      ),
      sender: barrier,
    );
    await done.future.timeout(const Duration(seconds: 10));
    await flushRecorders();
  }

  /// Each wallet command as `<Command> wallet txTag ...`.
  List<String> commands() => [
        for (final m in walletManager.messages)
          if (m is WalletCommandMessage)
            switch (m.command) {
              final RevertTransactionConfirmationCommand c =>
                'revert ${c.walletId} ${tagOf(c.txid)} proof=${c.merkleProof?.join()}',
              final ConfirmTransactionCommand c =>
                'confirm ${c.walletId} ${tagOf(c.txid)} h=${c.blockHeight} hash=${tagOf(c.blockHash)} bump=${c.bumpHex}',
              final MarkUTXOAvailableCommand c => 'available ${c.walletId} ${tagOf(c.txid)}:${c.vout}',
              final other => other.runtimeType.toString(),
            },
      ];

  List<List<String>> arcPolls() => [
        for (final m in arc.messages)
          if (m is TransactionConfirmationsRevertedMessage) [for (final t in m.txids) tagOf(t)],
      ];

  Future<List<String>> proofHistory(String txid) async =>
      [for (final p in await storage.getMerkleProofHistory(txid)) '${p.status.name}:${tagOf(p.blockHash)}'];

  const c = TransactionStatus.confirmed;
  const pending = TransactionStatus.pending;

  group('hg0: an orphaned proof whose block is active again', () {
    test('a reorganization back to its block verifies it again and restores the confirmation through the wallet',
        () async {
      await spawnSpv();
      await activate('N100', 100);
      final (bumpO, rootO) = _proofFor(tx('O'), 101);
      // O was confirmed in X101; a reorganization orphaned X101 and took the
      // confirmation back (its row and UTXO are pending); X101 is active again.
      final x101 = await activate('X101', 101, merkleRoot: rootO);
      await storage.storeMerkleProof(tx('O'), proof(tx('O'), 101, MerkleProofStatus.verified, hash: x101));
      expect(await storage.markMerkleProofOrphaned(tx('O'), blockHash: x101), isTrue);
      await storage.storeTransaction('w1', _row('w1', tx('O'), pending, null, DateTime.utc(2026, 9, 2)));
      await storage.upsertUTXO('w1', _utxo(tx('O'), 0, UTXOStatus.pending));
      await storage.upsertUTXO('w1', _utxo(tx('O'), 1, UTXOStatus.spent));
      // Z: orphaned in Y101, which stays off the active chain.
      await storage.storeMerkleProof(tx('Z'), proof(tx('Z'), 101, MerkleProofStatus.verified, hash: blockHash('Y101')));
      await storage.markMerkleProofOrphaned(tx('Z'));
      await storage.storeTransaction('w1', _row('w1', tx('Z'), pending, null, DateTime.utc(2026, 9, 2)));

      await deliver(HeaderChainReorganizedMessage(
          forkHeight: 100, orphanedBlockHashes: [blockHash('B101')], newTipHeight: 101));

      expect(await proofHistory(tx('O')), ['verified:X101'], reason: 'the same row, verified again (never deleted)');
      expect(await proofHistory(tx('Z')), ['orphaned:Y101']);
      expect(commands(), [
        'confirm w1 O h=101 hash=X101 bump=$bumpO',
        'available w1 O:0',
      ]);
      expect(arcPolls(), isEmpty);
    });

    test('a block that becomes active after the reorganization (a later header batch) revives its proofs', () async {
      await spawnSpv();
      await activate('N100', 100);
      await activate('N101', 101);
      final (bumpO, rootO) = _proofFor(tx('O'), 102);
      final x102 = _header('X102', merkleRoot: rootO).blockHash().toString();
      tags[x102] = 'X102';
      await storage.storeMerkleProof(tx('O'), proof(tx('O'), 102, MerkleProofStatus.verified, hash: x102));
      await storage.markMerkleProofOrphaned(tx('O'), blockHash: x102);
      await storage.storeTransaction('w1', _row('w1', tx('O'), pending, null, DateTime.utc(2026, 9, 2)));
      await storage.storeTransaction('w2', _row('w2', tx('O'), c, null, DateTime.utc(2026, 9, 2)));

      // The switch back to X's branch arrives with a tip below X102 ...
      await deliver(HeaderChainReorganizedMessage(
          forkHeight: 100, orphanedBlockHashes: [blockHash('B101'), blockHash('B102')], newTipHeight: 101));
      expect(await proofHistory(tx('O')), ['orphaned:X102']);
      expect(commands(), isEmpty);

      // ... and X102 in the next batch.
      await activate('X102', 102, merkleRoot: rootO);
      await deliver(BlockHeaderStoredMessage(header: _header('X102', merkleRoot: rootO), height: 102));

      expect(await proofHistory(tx('O')), ['verified:X102']);
      expect(commands(), ['confirm w1 O h=102 hash=X102 bump=$bumpO'],
          reason: 'the wallet that still holds it as confirmed needs nothing');
    });

    test('a transaction re-mined on the branch that loses again is confirmed on its first block, after the revert',
        () async {
      await spawnSpv();
      await activate('N100', 100);
      // O was mined in A101, orphaned there, mined again in B102 (its current
      // proof, confirmed in w1). The A branch becomes active again.
      final (bumpA, rootA) = _proofFor(tx('O'), 101);
      final a101 = await activate('A101', 101, merkleRoot: rootA);
      await storage.storeMerkleProof(tx('O'), proof(tx('O'), 101, MerkleProofStatus.verified, hash: a101));
      await storage.markMerkleProofOrphaned(tx('O'), blockHash: a101);
      await storage.storeMerkleProof(
          tx('O'), proof(tx('O'), 102, MerkleProofStatus.verified, hash: blockHash('B102'), variant: 'b'));
      await storage.storeTransaction('w1', _row('w1', tx('O'), c, 102, DateTime.utc(2026, 9, 2)));
      await storage.upsertUTXO('w1', _utxo(tx('O'), 0, UTXOStatus.available));
      await activate('A102', 102);

      await deliver(HeaderChainReorganizedMessage(
          forkHeight: 100, orphanedBlockHashes: [blockHash('B101'), blockHash('B102')], newTipHeight: 102));

      expect(await proofHistory(tx('O')), ['verified:A101', 'orphaned:B102']);
      expect(commands(), [
        'revert w1 O proof=${_proofFor(tx('O'), 102, variant: 'b').$1}',
        'confirm w1 O h=101 hash=A101 bump=$bumpA',
        'available w1 O:0',
      ], reason: 'the row still reads confirmed when the revert is sent; the wallet applies revert then confirm');
    });

    test('an orphaned proof is not revived over a current proof of the transaction', () async {
      await spawnSpv();
      final (_, rootO) = _proofFor(tx('O'), 101);
      final x101 = await activate('X101', 101, merkleRoot: rootO);
      await storage.storeMerkleProof(tx('O'), proof(tx('O'), 101, MerkleProofStatus.verified, hash: x101));
      await storage.storeMerkleProof(tx('O'), proof(tx('O'), 150, MerkleProofStatus.pendingHeader, variant: 'later'));
      await storage.storeTransaction('w1', _row('w1', tx('O'), pending, null, DateTime.utc(2026, 9, 2)));

      await deliver(HeaderChainReorganizedMessage(forkHeight: 100, orphanedBlockHashes: const [], newTipHeight: 101));

      expect(await proofHistory(tx('O')), ['orphaned:X101', 'pendingHeader:null']);
      expect(commands(), isEmpty);
    });
  });

  group('10r', () {
    test('(1) a rejected proof that verifies on the chain a reorganization makes active is verified and confirms',
        () async {
      await spawnSpv();
      await activate('N100', 100);
      final (bumpR, rootR) = _proofFor(tx('R'), 101);
      // Rejected against the header at 101 on the branch active then; its
      // confirmation was taken back.
      await storage.storeMerkleProof(tx('R'), proof(tx('R'), 101, MerkleProofStatus.rejected));
      await storage.storeTransaction('w1', _row('w1', tx('R'), pending, null, DateTime.utc(2026, 9, 2)));
      await storage.upsertUTXO('w1', _utxo(tx('R'), 0, UTXOStatus.pending));
      // The branch whose block 101 contains R becomes active.
      await activate('R101', 101, merkleRoot: rootR);

      await deliver(HeaderChainReorganizedMessage(
          forkHeight: 100, orphanedBlockHashes: [blockHash('S101')], newTipHeight: 101));

      expect(await proofHistory(tx('R')), ['verified:R101']);
      expect(commands(), ['confirm w1 R h=101 hash=R101 bump=$bumpR', 'available w1 R:0']);
    });

    test('(2) a pendingHeader proof above the fork point whose header is still unknown stays pendingHeader', () async {
      await spawnSpv();
      for (final h in [100, 101, 102, 103]) {
        await activate('N$h', h);
      }
      await storage.storeTransaction('w1', _row('w1', tx('P'), c, 105, DateTime.utc(2026, 9, 2)));
      await storage.storeMerkleProof(tx('P'), proof(tx('P'), 105, MerkleProofStatus.pendingHeader));

      await deliver(HeaderChainReorganizedMessage(
          forkHeight: 100, orphanedBlockHashes: [blockHash('O101')], newTipHeight: 103));

      expect(await proofHistory(tx('P')), ['pendingHeader:null'],
          reason: 'it never named a block, and nothing is known at its height yet');
      expect(commands(), isEmpty, reason: 'nothing it rests on changed');
      expect(arcPolls(), isEmpty);
    });

    test('(3) a later, different rejected-only confirmation of the same txid is reverted too', () async {
      await spawnSpv();
      await activate('N200', 200);
      final (bump1, _) = _proofFor(tx('S'), 200);
      final (bump2, _) = _proofFor(tx('S'), 200, variant: 'second');
      await storage.storeTransaction('w1', _row('w1', tx('S'), c, 200, DateTime.utc(2026, 9, 2)));
      await storage.storeMerkleProof(tx('S'), proof(tx('S'), 200, MerkleProofStatus.rejected));
      final stored = BlockHeaderStoredMessage(header: _header('N201'), height: 201);

      await deliver(stored);
      await deliver(stored); // before the projection applied the revert
      expect(commands(), ['revert w1 S proof=$bump1']);

      // The projection applies the revert (its one way to lower a confirmed
      // row, 7dj) ...
      await storage.storeRevertedTransaction('w1', _row('w1', tx('S'), pending, null, DateTime.utc(2026, 9, 3)));
      await deliver(stored);
      // ... then the transaction is confirmed again, on another proof the
      // header chain contradicts.
      await storage.storeMerkleProof(tx('S'), proof(tx('S'), 200, MerkleProofStatus.rejected, variant: 'second'));
      await storage.storeTransaction('w1', _row('w1', tx('S'), c, 200, DateTime.utc(2026, 9, 4)));
      await deliver(stored);
      await deliver(stored);

      expect(commands(), ['revert w1 S proof=$bump1', 'revert w1 S proof=$bump2']);
      expect(arcPolls(), [
        ['S'],
        ['S'],
      ]);
    });
  });

  group('yix (b): startup', () {
    test('pendingHeader proofs whose headers arrived while the node was down are checked when SPVActor starts',
        () async {
      await activate('N200', 200);
      final (_, rootV) = _proofFor(tx('V'), 201);
      await activate('V201', 201, merkleRoot: rootV);
      // V verifies, M is contradicted (and confirmed in w1), Q is above the tip.
      await storage.storeMerkleProof(tx('V'), proof(tx('V'), 201, MerkleProofStatus.pendingHeader));
      await storage.storeTransaction('w1', _row('w1', tx('M'), c, 200, DateTime.utc(2026, 9, 2)));
      final (bumpM, _) = _proofFor(tx('M'), 200);
      await storage.storeMerkleProof(tx('M'), proof(tx('M'), 200, MerkleProofStatus.pendingHeader));
      await storage.storeMerkleProof(tx('Q'), proof(tx('Q'), 205, MerkleProofStatus.pendingHeader));

      await spawnSpv();
      await deliver(); // no header notification

      expect(await proofHistory(tx('V')), ['verified:V201']);
      expect(await proofHistory(tx('M')), ['rejected:null']);
      expect(await proofHistory(tx('Q')), ['pendingHeader:null']);
      expect(commands(), ['revert w1 M proof=$bumpM']);
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
