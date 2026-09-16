/// Bead libspiffy-b81q: a BEEF our own headers contradict is refused, and
/// kept.
///
/// V-56 made the proven-subject branch keep a contradicted proof as a
/// `rejected` row; the unproven-subject branch still failed the receive and
/// dropped everything — the raw transactions and the BUMPs went nowhere. The
/// asymmetry was real: a rejected proof is evidence that a counterparty
/// handed us something that does not match our chain, and no block scan, no
/// indexer and no ARC can hand it to us again.
///
/// Both fatal paths now retain first and fail after. The receive still fails:
/// this is about retention, not about accepting a bad proof. A rejected row
/// never becomes a transaction's current proof and never displaces a verified
/// one.
///
/// End to end through LibSpiffyActorSystem on regtest with real-PoW headers
/// and an ARC that knows nothing.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:dactor/dactor.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:isar/isar.dart';
import 'package:libspiffy/coordinator.dart' as coord;
import 'package:libspiffy/libspiffy.dart';
import 'package:libspiffy/src/actors/spv_messages.dart' show BlockHeadersReceivedMessage;
import 'package:libspiffy/src/spv/network_params.dart';
import 'package:spiffynode/spiffy_node.dart';
import 'package:test/test.dart';

import '../spv/regtest_chain_builder.dart';
import 'isar_test_helper.dart';
import 'p2p_test_helpers.dart';

void main() {
  final genesis = NetworkParams.regtest.genesisHeader;

  final bobKey = dartsv.SVPrivateKey.fromHex('3a' * 32, dartsv.NetworkType.TEST);
  final bobLock = dartsv.P2PKHLockBuilder.fromAddress(bobKey.publicKey.toAddress(dartsv.NetworkType.TEST));
  final ourLock = dartsv.P2PKHLockBuilder.fromAddress(dartsv.Address(kTestRootAddress));

  dartsv.DefaultTransactionSigner bobSigner() => dartsv.DefaultTransactionSigner(
      dartsv.SighashType.SIGHASH_ALL.value | dartsv.SighashType.SIGHASH_FORKID.value, bobKey);

  /// G: Bob's mined coin, really in block 3 under [gBump].
  final g = _rawTransaction(
    prevTxid: Uint8List.fromList(List<int>.generate(32, (i) => 0x20 + i)),
    outputs: [(600000, Uint8List.fromList(hex.decode(bobLock.getScriptPubkey().toHex())))],
  );

  Uint8List internalTxid(String displayTxid) => Uint8List.fromList(hex.decode(displayTxid).reversed.toList());

  BUMP bumpFor(String displayTxid, int blockHeight, int seed) => BUMP.fromMerklePath(
        blockHeight: blockHeight,
        txid: internalTxid(displayTxid),
        index: 0,
        siblings: [Uint8List.fromList(List<int>.generate(32, (i) => (i * seed + seed) & 0xff))],
      );

  Hash rootOf(BUMP bump, String displayTxid) => Hash.fromBytes(bump.computeMerkleRoot(internalTxid(displayTxid)));

  final gBump = bumpFor(g.id, 3, 17);

  /// The path a counterparty invents for G over another root. Our block 3
  /// header contradicts it.
  final forgedGBump = bumpFor(g.id, 3, 53);

  final a1 = RegtestMiner.mine(parent: genesis, seed: 'b81q-A1');
  final a2 = RegtestMiner.mine(parent: a1, seed: 'b81q-A2');
  final a3 = RegtestMiner.mine(parent: a2, merkleRoot: rootOf(gBump, g.id));

  /// P: Bob spends G and pays us 150,000 satoshis. Unproven itself.
  final p = (dartsv.TransactionBuilder()
        ..spendFromOutpointWithSigner(
          bobSigner(),
          dartsv.TransactionOutpoint(g.id, 0, g.outputs[0].satoshis, g.outputs[0].script),
          dartsv.TransactionInput.MAX_SEQ_NUMBER,
          dartsv.P2PKHUnlockBuilder(bobKey.publicKey),
        )
        ..spendToLockBuilder(ourLock, BigInt.from(150000))
        ..spendToLockBuilder(bobLock, BigInt.from(440000))
        ..withOption(dartsv.TransactionOption.DISABLE_DUST_OUTPUTS))
      .build(false);

  /// A path a counterparty invents for P itself, so the *proven*-subject
  /// branch meets a contradicted proof.
  final forgedPBump = bumpFor(p.id, 3, 71);

  String beefHex(List<(dartsv.Transaction, BUMP?)> members) {
    final bumps = <BUMP>[];
    final bumpIndex = <int>[];
    for (final (_, bump) in members) {
      if (bump == null) continue;
      bumpIndex.add(bumps.length);
      bumps.add(bump);
    }
    return hex.encode(BEEF
        .create(
          bumps: bumps,
          txs: [for (final (tx, _) in members) Uint8List.fromList(hex.decode(tx.serialize()))],
          hasMerkle: [for (final (_, bump) in members) bump != null],
          bumpIndex: bumpIndex,
        )
        .serialize());
  }

  late Directory dir;
  late Isar isar;
  late LibSpiffyActorSystem system;
  late InMemoryWalletStorage readModel;
  const walletId = 'b81q-wallet-a';

  setUpAll(() async {
    await ensureIsarInitialized();
  });

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('b81q_beef_rejected_');
    isar = await Isar.open(
      LibSpiffySchemas.allSchemas,
      directory: dir.path,
      name: 'b81q_${DateTime.now().microsecondsSinceEpoch}',
    );
    readModel = InMemoryWalletStorage();
    system = LibSpiffyActorSystem();
    await system.initialize(
      actorSystem: LocalActorSystem(ActorSystemConfig()),
      isar: isar,
      readModelStorage: readModel,
      secureStorage: InMemorySecureStorage(),
      dataDirectory: dir.path,
      networkType: 'regtest',
      enableP2P: false,
      arcService: _FakeArc(),
    );
  });

  tearDown(() async {
    try {
      await system.shutdown();
    } catch (_) {}
    try {
      await isar.close(deleteFromDisk: true);
    } catch (_) {}
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  });

  Future<void> sendHeaders(List<BlockHeader> headers, int startHeight, int tip) async {
    system.headerSyncActor.tell(BlockHeadersReceivedMessage(
      peerId: 'peer',
      headers: headers,
      startHeight: startHeight,
    ) as dynamic);
    await _until(() async => system.headerChain.bestHeight == tip, 'header chain at $tip');
  }

  Future<coord.TransactionImportedEvent> receive(String beef, String subjectTxid) async {
    final imported = system.coordinatorEvents!
        .where((e) => e is coord.TransactionImportedEvent && e.transactionId == subjectTxid)
        .cast<coord.TransactionImportedEvent>()
        .first
        .timeout(const Duration(seconds: 20));
    system.coordinator.tell(coord.ReceiveTransactionCommand(
      walletId: walletId,
      beefHex: beef,
      fromCounterparty: 'bob',
    ));
    return imported;
  }

  Future<List<BitcoinUtxo>> utxosOf(String txid) async => [
        for (final u in await readModel.getUTXOs(walletId, includeSpent: true))
          if (u.txid == txid) u,
      ];

  /// Waits until the wallet aggregate has handled every command sent so far
  /// and the projection has applied their events. Needed before asserting
  /// that something was NOT journaled.
  Future<void> barrier() async {
    final address = await generateAddress(
      walletManager: system.walletManager,
      actorSystem: system.actorSystem,
      walletId: walletId,
    );
    await _until(() async => await readModel.getAddressMetadata(walletId, address) != null,
        'the wallet and its projection caught up');
  }

  Future<void> createTheWallet() async {
    await createWallet(
      walletManager: system.walletManager,
      actorSystem: system.actorSystem,
      walletId: walletId,
      walletName: 'A',
      xpriv: kTestXpriv,
    );
    await _until(() async => await readModel.isWalletAddress(walletId, kTestRootAddress), 'root address projected');
  }

  /// The rows stored for [txid] with [status], by their BUMP hex.
  Future<List<String>> proofRows(String txid, MerkleProofStatus status) async => [
        for (final row in await readModel.getMerkleProofHistory(txid))
          if (row.status == status) row.merkleProof.single,
      ];

  test('b81q: a BEEF whose ancestor proof our header contradicts still fails, and its transactions '
      'and contradicted BUMP are retained as rejected evidence', () async {
    await sendHeaders([a1, a2, a3], 1, 3);
    await createTheWallet();

    expect(rootOf(forgedGBump, g.id).toString(), isNot(rootOf(gBump, g.id).toString()),
        reason: 'the forged path must really disagree with block 3');

    final refused = await receive(beefHex([(g, forgedGBump), (p, null)]), p.id);
    expect(refused.success, isFalse, reason: 'a proof our own header contradicts was accepted');
    expect(refused.error, contains('failed merkle proof validation'));
    await barrier();
    expect(await utxosOf(p.id), isEmpty, reason: 'a refused receive must credit nothing');

    // Retained: both raw transactions, and the contradicted BUMP as a
    // rejected row. Nothing can hand these to us again.
    expect((await readModel.getAncestorTransactionsBatch([g.id, p.id])).keys.toSet(), {g.id, p.id},
        reason: 'the refused BEEF was dropped: its transactions cannot be fetched from anywhere');
    expect(await proofRows(g.id, MerkleProofStatus.rejected), [forgedGBump.toHex()],
        reason: 'the contradicted BUMP was dropped instead of being kept as evidence');

    // A rejected row is never a current proof, so it can never be used.
    expect(await readModel.getMerkleProof(g.id), isNull,
        reason: 'a rejected proof must never become the transaction\'s current proof');
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('b81q: a rejected row never displaces the verified proof the same transaction already has',
      () async {
    await sendHeaders([a1, a2, a3], 1, 3);
    await createTheWallet();

    // The honest BEEF first: G is proven in block 3 against our own header.
    final good = await receive(beefHex([(g, gBump), (p, null)]), p.id);
    expect(good.success, isTrue, reason: good.error);
    await _until(() async => (await readModel.getMerkleProof(g.id))?.status == MerkleProofStatus.verified,
        'the honest ancestor proof is verified');

    // Now the same ancestor with an invented path.
    final refused = await receive(beefHex([(g, forgedGBump), (p, null)]), p.id);
    expect(refused.success, isFalse);
    await barrier();

    final current = await readModel.getMerkleProof(g.id);
    expect((current?.status, current?.blockHeight, current?.merkleProof.single),
        (MerkleProofStatus.verified, 3, gBump.toHex()),
        reason: 'a rejected proof displaced a verified one');
    expect(await proofRows(g.id, MerkleProofStatus.rejected), [forgedGBump.toHex()],
        reason: 'the contradicted BUMP is kept alongside the verified one');
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('b81q: the proven-subject branch retains too when the subject\'s own proof is contradicted',
      () async {
    await sendHeaders([a1, a2, a3], 1, 3);
    await createTheWallet();

    final refused = await receive(beefHex([(g, gBump), (p, forgedPBump)]), p.id);
    expect(refused.success, isFalse, reason: 'a subject proof our own header contradicts was accepted');
    await barrier();
    expect(await utxosOf(p.id), isEmpty);

    expect((await readModel.getAncestorTransactionsBatch([g.id, p.id])).keys.toSet(), {g.id, p.id},
        reason: 'the refused BEEF was dropped');
    expect(await proofRows(p.id, MerkleProofStatus.rejected), [forgedPBump.toHex()],
        reason: 'the subject\'s contradicted BUMP was dropped');
    // The honest BUMP that travelled in the same BEEF is kept as well.
    final ancestorProof = await readModel.getMerkleProof(g.id);
    expect((ancestorProof?.status, ancestorProof?.blockHeight), (MerkleProofStatus.verified, 3));
  }, timeout: const Timeout(Duration(minutes: 2)));
}

/// A raw transaction with one input spending [prevTxid]:0 (display order
/// bytes reversed into the wire order) with an OP_TRUE scriptSig.
dartsv.Transaction _rawTransaction({required Uint8List prevTxid, required List<(int, Uint8List)> outputs}) {
  final b = BytesBuilder();
  void u32(int v) => b.add([v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff]);
  u32(1);
  b.addByte(1);
  b.add(prevTxid);
  u32(0);
  b.add([1, 0x51]);
  u32(0xffffffff);
  b.addByte(outputs.length);
  for (final (sats, script) in outputs) {
    final v = ByteData(8)..setUint64(0, sats, Endian.little);
    b.add(v.buffer.asUint8List());
    b.addByte(script.length);
    b.add(script);
  }
  u32(0);
  return dartsv.Transaction.fromHex(hex.encode(b.toBytes()));
}

Future<void> _until(Future<bool> Function() condition, String what,
    {Duration timeout = const Duration(seconds: 20)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!await condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for: $what');
    }
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}

/// ARC that knows no transaction at all.
class _FakeArc extends ArcService {
  _FakeArc() : super(baseUrl: 'fake://arc');

  @override
  Future<ArcTransactionResponse> getTransaction(String txid) async {
    throw ArcException('Failed to get transaction: {"status":404}');
  }
}
