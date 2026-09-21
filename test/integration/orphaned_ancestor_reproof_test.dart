/// Bead libspiffy-0lx, second recovery route, end to end: an output whose
/// only proven ancestor was orphaned by a reorganization becomes spendable
/// again when **the counterparty hands us a fresh BEEF** carrying a new BUMP
/// for that ancestor.
///
/// We hold P:0, an output of a payment P that is not mined. Spending it means
/// handing a counterparty a BEEF that walks back from P to a transaction with
/// a merkle proof — its ancestor G, which the counterparty proved in block A2
/// when it paid us. A heavier branch orphans A2: G's proof row is kept (a
/// reorganization can put the block back) but no longer counts, so the walk
/// runs off the end of what we store and P:0 is unspendable.
///
/// Nothing fetches the missing proof. There is no block scanning and no
/// address monitoring, and ARC answers only for transactions we broadcast
/// ourselves, so it has no standing to prove a counterparty's transaction.
/// Exactly two things can restore the output: the block returns to the active
/// chain (SPVActor revives the kept row), or the counterparty re-sends —
/// which is what this test drives, through the real receive path
/// (`ValidateBEEFCommand` or `ImportTransactionCommand` -> SPVActor -> the wallet aggregate ->
/// `WalletProjection._storeAncestors`). The projection's write is the point:
/// the fresh VERIFIED proof has to supersede the ORPHANED current row under
/// `ReadModelStorage.storeMerkleProof`'s retention rules (beads
/// libspiffy-mny, libspiffy-azl, libspiffy-b81q), and nothing in the test
/// writes a proof by hand.
///
/// End to end through LibSpiffyActorSystem on regtest with real-PoW header
/// branches and a fake ARC, as
/// test/integration/unproven_receive_ancestor_retention_test.dart does; the
/// same scenario at the unit level (SPVActor with no projection) is
/// test/actors/output_awaiting_ancestor_proof_test.dart.
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
import 'package:libspiffy/src/services/ancestor_chain_service.dart';
import 'package:libspiffy/src/spv/network_params.dart';
import 'package:spiffynode/spiffy_node.dart';
import 'package:test/test.dart';

import '../spv/regtest_chain_builder.dart';
import 'isar_test_helper.dart';
import 'p2p_test_helpers.dart';
import 'receive_helpers.dart';
import '../mocks/offline_arc.dart';

void main() {
  final genesis = NetworkParams.regtest.genesisHeader;

  // The counterparty's key; G pays it, P spends G:0 with it.
  final counterpartyKey = dartsv.SVPrivateKey.fromHex('7c' * 32, dartsv.NetworkType.TEST);
  final counterpartyLock =
      dartsv.P2PKHLockBuilder.fromAddress(counterpartyKey.publicKey.toAddress(dartsv.NetworkType.TEST));

  /// G: a mined transaction of the counterparty, the proven ancestor. Its own
  /// funding is in no BEEF of ours: G is proven by its BUMP alone, so an
  /// orphaned BUMP leaves the walk with nowhere to go.
  final g = _rawTransaction(
    prevTxid: Uint8List.fromList(List<int>.generate(32, (i) => 0xc0 + i)),
    outputs: [(300000, Uint8List.fromList(hex.decode(counterpartyLock.getScriptPubkey().toHex())))],
  );

  /// P: the counterparty pays wallet A's root address from G:0, unmined.
  final p = (dartsv.TransactionBuilder()
        ..spendFromOutpointWithSigner(
          dartsv.DefaultTransactionSigner(
              dartsv.SighashType.SIGHASH_ALL.value | dartsv.SighashType.SIGHASH_FORKID.value, counterpartyKey),
          dartsv.TransactionOutpoint(g.id, 0, g.outputs[0].satoshis, g.outputs[0].script),
          dartsv.TransactionInput.MAX_SEQ_NUMBER,
          dartsv.P2PKHUnlockBuilder(counterpartyKey.publicKey),
        )
        ..spendToLockBuilder(dartsv.P2PKHLockBuilder.fromAddress(dartsv.Address(kTestRootAddress)), BigInt.from(200000))
        ..spendToLockBuilder(counterpartyLock, BigInt.from(99000))
        ..withOption(dartsv.TransactionOption.DISABLE_DUST_OUTPUTS))
      .build(false);

  final gInternal = Uint8List.fromList(hex.decode(g.id).reversed.toList());

  BUMP bumpForG({required int index, required int seed}) => BUMP.fromMerklePath(
        blockHeight: 2,
        txid: gInternal,
        index: index,
        siblings: [Uint8List.fromList(List<int>.generate(32, (i) => (i * seed + seed) & 0xff))],
      );

  Hash rootOf(BUMP bump) => Hash.fromBytes(bump.computeMerkleRoot(gInternal));

  /// The branch we are on when the payment arrives: G is in A2, at height 2.
  final gBumpA = bumpForG(index: 1, seed: 13);
  final a1 = RegtestMiner.mine(parent: genesis, seed: '0lx-e2e-A1');
  final a2 = RegtestMiner.mine(parent: a1, merkleRoot: rootOf(gBumpA));
  final a3 = RegtestMiner.mine(parent: a2, seed: '0lx-e2e-A3');

  /// The branch that wins: it forks at A1, so A2 and A3 leave the chain, and
  /// G is mined again in B2 under a different merkle path.
  final gBumpB = bumpForG(index: 0, seed: 37);
  final b2 = RegtestMiner.mine(parent: a1, merkleRoot: rootOf(gBumpB));
  final b3 = RegtestMiner.mine(parent: b2, seed: '0lx-e2e-B3');
  final b4 = RegtestMiner.mine(parent: b3, seed: '0lx-e2e-B4');

  /// What the counterparty hands wallet A: G with the BUMP [gBump], then P
  /// (unproven). The first delivery carries [gBumpA], the re-send [gBumpB].
  String beefHexWith(BUMP gBump) => hex.encode(BEEF
      .create(
        bumps: [gBump],
        txs: [Uint8List.fromList(hex.decode(g.serialize())), Uint8List.fromList(hex.decode(p.serialize()))],
        hasMerkle: [true, false],
        bumpIndex: [0],
      )
      .serialize());

  late Directory dir;
  late Isar isar;
  late InMemorySecureStorage secrets;
  late _FakeArc arc;
  final systems = <LibSpiffyActorSystem>[];
  const walletId = '0lx-e2e-wallet-a';
  const recipient = 'mfWxJ45yp2SFn7UciZyNpvDKrzbhyfKrY8';

  setUpAll(() async {
    await ensureIsarInitialized();
  });

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('0lx_reproof_');
    isar = await Isar.open(
      LibSpiffySchemas.allSchemas,
      directory: dir.path,
      name: 'reproof_${DateTime.now().microsecondsSinceEpoch}',
    );
    secrets = InMemorySecureStorage();
    arc = _FakeArc();
  });

  tearDown(() async {
    for (final s in systems) {
      try {
        await s.shutdown();
      } catch (_) {}
    }
    systems.clear();
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  });

  Future<LibSpiffyActorSystem> start() async {
    final system = LibSpiffyActorSystem();
    await system.initialize(
      actorSystem: LocalActorSystem(ActorSystemConfig()),
      isar: isar,
      readModelStorage: InMemoryWalletStorage(),
      secureStorage: secrets,
      dataDirectory: dir.path,
      networkType: 'regtest',
      enableP2P: false,
      arcService: arc,
    );
    systems.add(system);
    return system;
  }

  Future<void> sendHeaders(LibSpiffyActorSystem system, List<BlockHeader> headers, int tip) async {
    system.headerSyncActor.tell(BlockHeadersReceivedMessage(
      peerId: 'peer',
      headers: headers,
      startHeight: 1,
    ) as dynamic);
    await _until(() async => system.headerChain.bestHeight == tip, 'tip at $tip');
  }

  Future<BitcoinUtxo?> receivedUtxo(ReadModelStorage storage) async {
    for (final u in await storage.getUTXOs(walletId, includeSpent: true)) {
      if (u.txid == p.id && u.vout == 0) return u;
    }
    return null;
  }

  /// The counterparty delivers a BEEF for P through the public receive path.
  Future<void> receive(LibSpiffyActorSystem system, String beefHex) async {
    final result = await receiveBeef(system, walletId, beefHex, p.id, fromCounterparty: 'counterparty');
    expect(result.success, isTrue, reason: result.error);
  }

  /// Wallet A with headers to height 3 on branch A, holding P's output as
  /// received from the counterparty and made spendable by ARC seeing P on the
  /// network (P is ours to poll for: we hold its output).
  Future<LibSpiffyActorSystem> receiveUnprovenPayment() async {
    final system = await start();
    await sendHeaders(system, [a1, a2, a3], 3);
    await createWallet(
      walletManager: system.walletManager,
      actorSystem: system.actorSystem,
      walletId: walletId,
      walletName: 'A',
      xpriv: kTestXpriv,
    );
    await _until(() async => await system.walletStorage.isWalletAddress(walletId, kTestRootAddress),
        'root address projected');

    await receive(system, beefHexWith(gBumpA));
    expect((await receivedUtxo(system.walletStorage))?.status, UTXOStatus.pending);

    arc.responses[p.id] = ArcTransactionResponse.fromJson({
      'timestamp': '2026-09-17T08:00:00Z',
      'txid': p.id,
      'txStatus': 'SEEN_ON_NETWORK',
    });
    system.arcActor.tell(CheckStoragePendingUTXOsMessage(triggerBlockHeight: 3));
    await _until(() async => (await receivedUtxo(system.walletStorage))?.status == UTXOStatus.available,
        "P's output made available by SEEN_ON_NETWORK", timeout: const Duration(seconds: 12));
    return system;
  }

  Future<coord.PaymentReadyEvent> pay(LibSpiffyActorSystem system, String invoiceId) async {
    final ready = system.coordinatorEvents!
        .where((e) => e is coord.PaymentReadyEvent && e.invoiceId == invoiceId)
        .cast<coord.PaymentReadyEvent>()
        .first
        .timeout(const Duration(seconds: 20));
    system.coordinator.tell(coord.PayInvoiceCommand(
      walletId: walletId,
      invoiceId: invoiceId,
      addresses: [recipient],
      amount: BigInt.from(50000),
    ));
    return ready;
  }

  /// A receiver that shares nothing with wallet A but the header chain.
  Future<SPVValidationResult> validateOnFreshReceiver(
      Uint8List beefBytes, String txid, List<BlockHeader> chain) async {
    final storage = InMemoryWalletStorage();
    await storage.storeBlockHeader(genesis, 0);
    for (var i = 0; i < chain.length; i++) {
      await storage.storeBlockHeader(chain[i], i + 1);
    }
    final actors = LocalActorSystem(ActorSystemConfig());
    try {
      final sink = await actors.spawn('sink', () => _Sink());
      final spv = await actors.spawn(
          'spv', () => SPVActor(walletManager: sink, invoiceCoordinator: sink, storage: storage, networkType: 'regtest'));
      final done = Completer<SPVValidationResult>();
      final receiver = await actors.spawn('receiver', () => TestReceiverActor<SPVValidationResult>(done));
      spv.tell(
        ReceiveTransactionMessage(transactionId: txid, beef: BEEF.parse(beefBytes), fromCounterparty: 'wallet-a'),
        sender: receiver,
      );
      return await done.future.timeout(const Duration(seconds: 10));
    } finally {
      await actors.shutdown();
    }
  }

  test('0lx: a counterparty re-sending a BEEF with a fresh BUMP for the orphaned ancestor makes the output '
      'spendable again, through the real projection', () async {
    final system = await receiveUnprovenPayment();
    final storage = system.walletStorage;
    final chains = AncestorChainService(storage: storage);

    // 1. The output is spendable: the walk back from P reaches G, proven in
    //    A2 on our active chain.
    final gProofOnA = await storage.getMerkleProof(g.id);
    expect((gProofOnA?.status, gProofOnA?.blockHash, gProofOnA?.merkleProof.single),
        (MerkleProofStatus.verified, a2.blockHash().toString(), gBumpA.toHex()),
        reason: "the received BEEF's ancestor proof was stored by the projection");
    final before = await chains.collectAncestorChainForUtxos([p.id]);
    expect(before.isValid, isTrue, reason: before.error);
    expect(before.ancestorTransactions.map((t) => t.txid).toSet(), {g.id, p.id});
    expect(before.merkleProofs.map((m) => (m.txid, m.merkleProof.single)), [(g.id, gBumpA.toHex())]);
    expect(await storage.getOutputsAwaitingAncestorProof(walletId), isEmpty);

    // 2. A heavier branch forks at A1 and orphans A2 (G's block) and A3.
    await sendHeaders(system, [a1, b2, b3, b4], 4);
    await _until(() async => await storage.getMerkleProof(g.id) == null,
        "G's orphaned proof is no longer the current proof", timeout: const Duration(seconds: 12));

    // The row is kept: a reorganization can put A2 back.
    expect([for (final row in await storage.getMerkleProofHistory(g.id)) (row.merkleProof.single, row.status)],
        [(gBumpA.toHex(), MerkleProofStatus.orphaned)],
        reason: 'the proof row must be kept, not deleted (bead mny)');
    expect((await receivedUtxo(storage))?.status, UTXOStatus.available,
        reason: "P's own row is untouched: it is the ancestor's proof that left the chain");

    // So the output cannot be put into a BEEF, and the wallet says why.
    final blocked = await chains.collectAncestorChainForUtxos([p.id]);
    expect(blocked.isValid, isFalse, reason: 'the BEEF was built from an orphaned proof');
    final awaiting = await storage.getOutputsAwaitingAncestorProof(walletId);
    expect(awaiting.map((o) => o.outpoint), ['${p.id}:0']);
    expect(awaiting.single.ancestors.map((a) => (a.txid, a.lastProofStatus, a.blockHeight)),
        [(g.id, MerkleProofStatus.orphaned, 2)]);

    // 3. The counterparty re-sends: the same unproven P, with G's new BUMP in
    //    the block that won. Nothing else is touched, and no proof is written
    //    by hand: the receive path and WalletProjection do it.
    await receive(system, beefHexWith(gBumpB));

    // 4. The fresh verified proof supersedes the orphaned current row.
    await _until(() async => await storage.getMerkleProof(g.id) != null, "G's fresh proof became the current proof",
        timeout: const Duration(seconds: 12));
    final restored = (await storage.getMerkleProof(g.id))!;
    expect((restored.status, restored.blockHeight, restored.blockHash, restored.merkleProof.single),
        (MerkleProofStatus.verified, 2, b2.blockHash().toString(), gBumpB.toHex()),
        reason: 'the fresh proof the counterparty supplied is not the current proof');

    // Nothing was deleted: the orphaned row is still in the history.
    expect([for (final row in await storage.getMerkleProofHistory(g.id)) (row.merkleProof.single, row.status)],
        containsAll([
          (gBumpA.toHex(), MerkleProofStatus.orphaned),
          (gBumpB.toHex(), MerkleProofStatus.verified),
        ]),
        reason: 'the orphaned row is evidence of what we were given and is never deleted (bead mny)');

    // The output is spendable again, and the wallet no longer reports it.
    final after = await chains.collectAncestorChainForUtxos([p.id]);
    expect(after.isValid, isTrue, reason: after.error);
    expect(after.merkleProofs.map((m) => (m.txid, m.merkleProof.single)), [(g.id, gBumpB.toHex())]);
    expect(await storage.getOutputsAwaitingAncestorProof(walletId), isEmpty,
        reason: 'the output is still reported as waiting for a proof');

    // And a real payment from it validates on a receiver that shares nothing
    // with us but the winning header chain.
    final payment = await pay(system, '0lx-e2e-invoice');
    expect(payment.success, isTrue, reason: payment.error);
    final beef = BEEF.parse(payment.beefBytes);
    expect([
      for (var i = 0; i < beef.txs.length; i++) (hex.encode(beef.calculateTxid(beef.txs[i])), beef.hasMerkle[i]),
    ], [
      (g.id, true),
      (p.id, false),
      (payment.txid, false),
    ], reason: 'parents first: G with its BUMP, then P, then the new transaction');
    expect(beef.bumps.map((b) => b.toHex()), [gBumpB.toHex()], reason: 'the BEEF carries the fresh BUMP');

    final validation = await validateOnFreshReceiver(payment.beefBytes, payment.txid, [a1, b2, b3, b4]);
    expect(validation.isValid, isTrue, reason: validation.validationError);
  });
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
    {Duration timeout = const Duration(seconds: 8)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!await condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for: $what');
    }
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}

class _Sink extends Actor {
  @override
  Future<void> onMessage(dynamic message) async {}
}

/// ARC that answers from [responses] and knows no other transaction.
class _FakeArc extends OfflineArc {
  _FakeArc() : super(baseUrl: 'fake://arc');

  /// A payment we receive is ours to submit (bead libspiffy-xggs). ARC holds
  /// it and nothing more: whatever this test settles, it settles another way.
  @override
  Future<ArcSubmitResponse> submitTransaction(String rawTx, {String? callbackUrl}) async =>
      ArcSubmitResponse.fromJson({'txStatus': 'STORED'});

  final Map<String, ArcTransactionResponse> responses = {};

  @override
  Future<ArcTransactionResponse> getTransaction(String txid) async {
    final response = responses[txid];
    if (response == null) throw ArcException('Failed to get transaction: {"status":404}');
    return response;
  }
}
