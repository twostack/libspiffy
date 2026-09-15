/// ctkm (libspiffy-ctkm): SPVActor used to read every wallet's whole
/// confirmed history (raw hex included) with
/// `getTransactionsByStatus(confirmed)` on each header-chain reorganization,
/// once per failing proof in the pendingHeader recheck (N+1), and once more
/// for confirmations resting on rejected proofs. It now reads only the rows
/// it acts on: confirmed rows above the fork point (and those with no
/// height), and rows of the txids whose proofs it checks.
///
/// The first group pins the commands and ARC notifications SPVActor sends,
/// and the proof statuses it leaves, for the same inputs; it passed on the
/// code before ctkm and must keep passing. The second group observes the
/// transaction rows read (InMemoryWalletStorage.transactionRowsRead) and that
/// the whole-history query is not called.
///
/// SPVActor runs against an in-memory read model with no projection: the
/// wallet manager and ARC are recorders.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart' show sha256;
import 'package:dactor/dactor.dart';
import 'package:libspiffy/src/actors/spv_actor.dart';
import 'package:libspiffy/src/actors/spv_messages.dart' show BlockHeaderStoredMessage;
import 'package:libspiffy/src/actors/wallet_messages.dart';
import 'package:libspiffy/src/core/wallet_commands.dart';
import 'package:libspiffy/src/models/bitcoin_transaction.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';
import 'package:libspiffy/src/storage/read_model_storage.dart';
import 'package:libspiffy/src/utils/beef.dart';
import 'package:libspiffy/src/utils/bump.dart';
import 'package:spiffynode/spiffy_node.dart';
import 'package:test/test.dart';

import '../spv/testnet_proof_fixture.dart';

/// A 64-hex id derived from [tag].
String _hex64(String tag) => sha256.convert(utf8.encode(tag)).toString();

/// A BUMP proving [txid] at [height] in a two-transaction block, and the
/// merkle root that block's header must carry.
(String, Hash) _proofFor(String txid, int height) {
  final internal = displayHexToInternal(txid);
  final sibling = Uint8List.fromList(hex.decode(_hex64('sibling-$txid-$height')));
  final bump = BUMP.fromMerklePath(blockHeight: height, txid: internal, index: 0, siblings: [sibling]);
  return (bump.toHex(), Hash.fromBytes(bump.computeMerkleRoot(internal)));
}

BlockHeader _header(int seed, {Hash? merkleRoot}) => BlockHeader(
      version: 1,
      prevBlock: Hash.fromHex(_hex64('prev-$seed')),
      merkleRoot: merkleRoot ?? Hash.fromHex(_hex64('root-$seed')),
      timestamp: DateTime.fromMillisecondsSinceEpoch((1600000000 + seed) * 1000, isUtc: true),
      bits: 0x1d00ffff,
      nonce: seed,
    );

BitcoinTransaction _row(String walletId, String txid, TransactionStatus status, int? height, int minute) =>
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
      createdAt: DateTime.utc(2026, 9, 1, 12, minute),
      updatedAt: DateTime.utc(2026, 9, 1, 12, minute),
      lockTime: 0,
      version: 2,
    );

void main() {
  late LocalActorSystem system;
  late _CountingStorage storage;
  late _Recorder walletManager;
  late _Recorder arc;
  late ActorRef spv;
  late ActorRef walletManagerRef;
  late ActorRef arcRef;

  /// Test txid for [tag], and back.
  final tags = <String, String>{};
  String tx(String tag) {
    final h = _hex64('tx-$tag');
    tags[h] = tag;
    return h;
  }

  final hashTags = <String, String>{};
  String blockHash(String tag) {
    final h = _hex64('block-$tag');
    hashTags[h] = tag;
    return h;
  }

  String tagOf(String? h) => h == null ? 'null' : (tags[h] ?? hashTags[h] ?? h);

  MerkleProof proof(String txid, int height, MerkleProofStatus status, {String? hash, String? bumpHex}) =>
      MerkleProof(
        txid: txid,
        blockHash: hash,
        blockHeight: height,
        position: 0,
        merkleProof: [bumpHex ?? _proofFor(txid, height).$1],
        status: status,
      );

  setUp(() async {
    tags.clear();
    hashTags.clear();
    system = LocalActorSystem(ActorSystemConfig());
    storage = _CountingStorage();
    final tag = DateTime.now().microsecondsSinceEpoch;
    walletManager = _Recorder();
    arc = _Recorder();
    walletManagerRef = await system.spawn('wm-$tag', () => walletManager);
    arcRef = await system.spawn('arc-$tag', () => arc);
    spv = await system.spawn('spv-$tag',
        () => SPVActor(walletManager: walletManagerRef, invoiceCoordinator: walletManagerRef, storage: storage, arcActor: arcRef));
  });

  tearDown(() => system.shutdown());

  /// Tell SPVActor [message] and wait until it has handled it (its mailbox is
  /// sequential: the reply to a later message comes after), then until the
  /// recorders have received what it sent.
  Future<void> deliver(Message message) async {
    spv.tell(message);
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

  /// Each revert as `wallet txTag h=<proof height> hash=<block tag> proof=<bool> <reason without detail>`.
  List<String> reverts() => [
        for (final m in walletManager.messages)
          if (m is WalletCommandMessage && m.command is RevertTransactionConfirmationCommand)
            () {
              final c = m.command as RevertTransactionConfirmationCommand;
              expect(m.walletId, c.walletId);
              return '${c.walletId} ${tagOf(c.txid)} h=${c.blockHeight} hash=${tagOf(c.blockHash)} '
                  'proof=${c.merkleProof != null} ${c.reason.split(' (').first}';
            }(),
      ];

  List<List<String>> arcPolls() => [
        for (final m in arc.messages)
          if (m is TransactionConfirmationsRevertedMessage) [for (final t in m.txids) tagOf(t)],
      ];

  Future<List<String>> proofHistory(String txid) async =>
      [for (final p in await storage.getMerkleProofHistory(txid)) '${p.status.name}:${tagOf(p.blockHash)}'];

  /// A reorganization at height 100 (new tip 103) that orphaned the blocks
  /// O101 and O102, over two wallets holding confirmed transactions below,
  /// at and above the fork point, with and without heights and proofs.
  Future<void> seedReorganization() async {
    const fork = 100;
    // Active headers after the reorganization.
    await storage.storeBlockHeader(_header(95, merkleRoot: _proofFor(tx('A'), 95).$2), 95);
    await storage.storeBlockHeader(_header(99), 99);
    await storage.storeBlockHeader(_header(fork), fork);
    await storage.storeBlockHeader(_header(101), 101);
    await storage.storeBlockHeader(_header(102, merkleRoot: _proofFor(tx('D'), 102).$2), 102);
    await storage.storeBlockHeader(_header(103), 103);
    final n95 = (await storage.getBlockHeaderByHeight(95))!.blockHash().toString();
    hashTags[n95] = 'N95';
    hashTags[(await storage.getBlockHeaderByHeight(102))!.blockHash().toString()] = 'N102';

    const c = TransactionStatus.confirmed;
    // A: below the fork, proven on the active chain.
    await storage.storeTransaction('w1', _row('w1', tx('A'), c, 95, 1));
    await storage.storeMerkleProof(tx('A'), proof(tx('A'), 95, MerkleProofStatus.verified, hash: n95));
    // B: two wallets, proof on orphaned block O101.
    await storage.storeTransaction('w1', _row('w1', tx('B'), c, 101, 2));
    await storage.storeTransaction('w2', _row('w2', tx('B'), c, 101, 9));
    await storage.storeMerkleProof(tx('B'), proof(tx('B'), 101, MerkleProofStatus.verified, hash: blockHash('O101')));
    // C: above the fork, no proof.
    await storage.storeTransaction('w1', _row('w1', tx('C'), c, 102, 3));
    // D: proof on orphaned O102 that still verifies against the new block 102.
    await storage.storeTransaction('w2', _row('w2', tx('D'), c, 102, 4));
    await storage.storeMerkleProof(tx('D'), proof(tx('D'), 102, MerkleProofStatus.verified, hash: blockHash('O102')));
    // E: no height, no proof.
    await storage.storeTransaction('w1', _row('w1', tx('E'), c, null, 5));
    // F: no height, proof below the fork on a block the active header contradicts.
    await storage.storeTransaction('w1', _row('w1', tx('F'), c, null, 6));
    await storage.storeMerkleProof(tx('F'), proof(tx('F'), 99, MerkleProofStatus.verified, hash: blockHash('S99')));
    // G: above the new tip, header unknown.
    await storage.storeTransaction('w1', _row('w1', tx('G'), c, 104, 7));
    await storage.storeMerkleProof(tx('G'), proof(tx('G'), 104, MerkleProofStatus.verified, hash: blockHash('O104')));
    // H: recorded below the fork, but its proof names orphaned O101.
    await storage.storeTransaction('w2', _row('w2', tx('H'), c, 90, 8));
    await storage.storeMerkleProof(tx('H'), proof(tx('H'), 101, MerkleProofStatus.verified, hash: blockHash('O101')));
    // I: not confirmed, proof on orphaned O101.
    await storage.storeTransaction('w1', _row('w1', tx('I'), TransactionStatus.pending, 101, 10));
    await storage.storeMerkleProof(tx('I'), proof(tx('I'), 101, MerkleProofStatus.verified, hash: blockHash('O101')));
    // J: pendingHeader proof the new header at 101 contradicts.
    await storage.storeTransaction('w1', _row('w1', tx('J'), c, 101, 11));
    await storage.storeMerkleProof(tx('J'), proof(tx('J'), 101, MerkleProofStatus.pendingHeader));
    // K: exactly at the fork point, no proof.
    await storage.storeTransaction('w1', _row('w1', tx('K'), c, fork, 12));
  }

  HeaderChainReorganizedMessage reorganization() => HeaderChainReorganizedMessage(
        forkHeight: 100,
        orphanedBlockHashes: [blockHash('O101'), blockHash('O102')],
        newTipHeight: 103,
      );

  /// Proofs imported before their headers (pendingHeader) and rejected
  /// proofs, checked when the header at height 202 is stored.
  Future<void> seedProofRecheck() async {
    await storage.storeBlockHeader(_header(200), 200);
    await storage.storeBlockHeader(_header(201, merkleRoot: _proofFor(tx('P'), 201).$2), 201);
    hashTags[(await storage.getBlockHeaderByHeight(201))!.blockHash().toString()] = 'N201';
    const c = TransactionStatus.confirmed;
    const pendingHeader = MerkleProofStatus.pendingHeader;

    // M: two wallets, pendingHeader proof the header at 200 contradicts.
    await storage.storeTransaction('w1', _row('w1', tx('M'), c, 200, 1));
    await storage.storeTransaction('w2', _row('w2', tx('M'), c, 200, 2));
    await storage.storeMerkleProof(tx('M'), proof(tx('M'), 200, pendingHeader));
    // N: failing pendingHeader proof, no wallet holds it as confirmed.
    await storage.storeTransaction('w1', _row('w1', tx('N'), TransactionStatus.pending, null, 20));
    await storage.storeMerkleProof(tx('N'), proof(tx('N'), 200, pendingHeader));
    // P: pendingHeader proof that verifies.
    await storage.storeTransaction('w1', _row('w1', tx('P'), c, 201, 21));
    await storage.storeMerkleProof(tx('P'), proof(tx('P'), 201, pendingHeader));
    // Q: pendingHeader proof above the stored height.
    await storage.storeTransaction('w1', _row('w1', tx('Q'), c, 205, 22));
    await storage.storeMerkleProof(tx('Q'), proof(tx('Q'), 205, pendingHeader));
    // R: legacy pendingHeader row naming a block, contradicted.
    await storage.storeTransaction('w2', _row('w2', tx('R'), c, 200, 23));
    await storage.storeMerkleProof(tx('R'), proof(tx('R'), 200, pendingHeader, hash: blockHash('S200')));
    // S: two wallets, only a rejected proof.
    await storage.storeTransaction('w1', _row('w1', tx('S'), c, 200, 3));
    await storage.storeTransaction('w2', _row('w2', tx('S'), c, 200, 4));
    await storage.storeMerkleProof(tx('S'), proof(tx('S'), 200, MerkleProofStatus.rejected));
    // T: rejected proof, but a current proof backs the transaction.
    await storage.storeTransaction('w1', _row('w1', tx('T'), c, 201, 24));
    await storage.storeMerkleProof(tx('T'), proof(tx('T'), 201, MerkleProofStatus.verified, hash: blockHash('T201')));
    await storage.storeMerkleProof(tx('T'), proof(tx('T'), 200, MerkleProofStatus.rejected));
    // U: rejected proof of a received ancestor (no wallet row).
    await storage.storeAncestorTransaction(tx('U'), '0100000000000000000000');
    await storage.storeMerkleProof(tx('U'), proof(tx('U'), 200, MerkleProofStatus.rejected));
    // V: rejected proof of a transaction no wallet holds as confirmed.
    await storage.storeTransaction('w2', _row('w2', tx('V'), TransactionStatus.pending, null, 25));
    await storage.storeMerkleProof(tx('V'), proof(tx('V'), 200, MerkleProofStatus.rejected));
  }

  BlockHeaderStoredMessage headerStored() => BlockHeaderStoredMessage(header: _header(202), height: 202);

  group('characterization: commands and proof statuses are unchanged', () {
    test('a reorganization reverts the confirmations above the fork or on orphaned blocks, once per wallet', () async {
      await seedReorganization();

      await deliver(reorganization());

      expect(reverts(), [
        'w1 J h=101 hash=null proof=true reorganization at height 100: rootMismatch',
        'w2 B h=101 hash=O101 proof=true reorganization at height 100: rootMismatch',
        'w1 B h=101 hash=O101 proof=true reorganization at height 100: rootMismatch',
        'w2 H h=101 hash=O101 proof=true reorganization at height 100: rootMismatch',
        'w1 G h=104 hash=O104 proof=true reorganization at height 100: headerUnknown',
        'w1 F h=99 hash=S99 proof=true reorganization at height 100: rootMismatch',
        'w1 C h=null hash=null proof=false reorganization at height 100: confirmed above the fork point with no stored proof',
      ]);
      expect(arcPolls(), [
        ['J', 'B', 'H', 'G', 'F', 'C']
      ]);
      expect({
        for (final t in ['A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K']) t: await proofHistory(tx(t)),
      }, {
        'A': ['verified:N95'],
        'B': ['orphaned:O101'],
        'C': <String>[],
        'D': ['orphaned:O102', 'verified:N102'],
        'E': <String>[],
        'F': ['orphaned:S99'],
        'G': ['orphaned:O104'],
        'H': ['orphaned:O101'],
        'I': ['orphaned:O101'],
        'J': ['rejected:null'],
        'K': <String>[],
      }, reason: 'proofs are marked, never deleted');
      expect((await storage.getTransactionHistory('w1')).length, 9, reason: 'no transaction row is removed');
      expect((await storage.getTransactionHistory('w2')).length, 3);
    });

    test('stored headers reject failing pendingHeader proofs and revert them and rejected-only confirmations once',
        () async {
      await seedProofRecheck();

      await deliver(headerStored());
      await deliver(headerStored()); // before any projection has applied the reverts

      const mismatch = 'proof imported before its block header does not match header at height 200: rootMismatch';
      expect(reverts(), [
        'w2 M h=200 hash=null proof=true $mismatch',
        'w1 M h=200 hash=null proof=true $mismatch',
        'w2 R h=200 hash=S200 proof=true $mismatch',
        'w2 S h=200 hash=null proof=true its only proof does not match the block header at height 200',
        'w1 S h=200 hash=null proof=true its only proof does not match the block header at height 200',
      ]);
      expect(arcPolls(), [
        ['M', 'N', 'R'],
        ['S'],
      ]);
      expect({
        for (final t in ['M', 'N', 'P', 'Q', 'R', 'S', 'T', 'U', 'V']) t: await proofHistory(tx(t)),
      }, {
        'M': ['rejected:null'],
        'N': ['rejected:null'],
        'P': ['verified:N201'],
        'Q': ['pendingHeader:null'],
        'R': ['orphaned:S200'],
        'S': ['rejected:null'],
        'T': ['verified:T201', 'rejected:null'],
        'U': ['rejected:null'],
        'V': ['rejected:null'],
      });
    });
  });

  group('ctkm: reads are bounded by the rows acted on', () {
    /// [count] confirmed transactions of one wallet, well below any fork.
    Future<void> seedHistory(int count) async {
      for (var i = 0; i < count; i++) {
        await storage.storeTransaction(
            'w-history', _row('w-history', _hex64('history-$i'), TransactionStatus.confirmed, 10 + i % 50, i % 60));
      }
    }

    test('a reorganization touching one transaction reads that row, not the confirmed history', () async {
      await seedHistory(300);
      await storage.storeBlockHeader(_header(1000), 1000);
      await storage.storeTransaction('w1', _row('w1', tx('above'), TransactionStatus.confirmed, 1001, 1));
      storage.resetCounters();

      await deliver(HeaderChainReorganizedMessage(forkHeight: 1000, orphanedBlockHashes: const [], newTipHeight: 1001));

      expect(reverts(), ['w1 above h=null hash=null proof=false '
          'reorganization at height 1000: confirmed above the fork point with no stored proof']);
      expect(storage.transactionRowsRead, lessThanOrEqualTo(1), reason: 'transaction rows read');
      expect(storage.confirmedHistoryScans, 0, reason: 'getTransactionsByStatus(confirmed) loads every wallet\'s history');
    });

    test('failing pendingHeader proofs read the rows of their txids once, not the history per proof', () async {
      await seedHistory(300);
      await storage.storeBlockHeader(_header(200), 200);
      for (final t in ['x', 'y', 'z']) {
        await storage.storeTransaction('w1', _row('w1', tx(t), TransactionStatus.confirmed, 200, 1));
        await storage.storeMerkleProof(tx(t), proof(tx(t), 200, MerkleProofStatus.pendingHeader));
      }
      storage.resetCounters();

      await deliver(headerStored());

      expect(reverts().map((r) => r.split(' ').take(2).join(' ')), ['w1 x', 'w1 y', 'w1 z']);
      expect(storage.transactionRowsRead, lessThanOrEqualTo(3), reason: 'transaction rows read');
      expect(storage.confirmedHistoryScans, 0);
    });

    test('confirmations resting on rejected proofs read the rows of those txids only', () async {
      await seedHistory(300);
      for (final t in ['r1', 'r2']) {
        await storage.storeTransaction('w1', _row('w1', tx(t), TransactionStatus.confirmed, 200, 1));
        await storage.storeTransaction('w2', _row('w2', tx(t), TransactionStatus.confirmed, 200, 2));
        await storage.storeMerkleProof(tx(t), proof(tx(t), 200, MerkleProofStatus.rejected));
      }
      storage.resetCounters();

      await deliver(headerStored());

      expect(reverts().map((r) => r.split(' ').take(2).join(' ')).toSet(), {'w1 r1', 'w2 r1', 'w1 r2', 'w2 r2'});
      expect(storage.transactionRowsRead, lessThanOrEqualTo(4), reason: 'transaction rows read');
      expect(storage.confirmedHistoryScans, 0);
    });
  });
}

class _CountingStorage extends InMemoryWalletStorage {
  int confirmedHistoryScans = 0;

  void resetCounters() {
    confirmedHistoryScans = 0;
    transactionRowsRead = 0;
  }

  @override
  Future<List<BitcoinTransaction>> getTransactionsByStatus(TransactionStatus status, {String? walletId}) {
    if (status == TransactionStatus.confirmed) confirmedHistoryScans++;
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
