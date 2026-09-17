/// Bead libspiffy-a2v3: **asking the counterparty for a fresh merkle proof**
/// when a reorganization takes an ancestor's block off the active chain.
///
/// Bead libspiffy-0lx built the first recovery route (the block comes back)
/// and proved the second one works when the counterparty happens to re-send
/// (test/integration/orphaned_ancestor_reproof_test.dart). Nothing could
/// *ask*. This is the protocol that asks, both halves of it, driven between
/// two real wallets: A's request goes out as a [coord.P2PMessageToSendEvent],
/// the test carries it (JSON round tripped, as an app's transport would) into
/// B's coordinator as a [coord.P2PMessageReceived], B answers from its own
/// storage, and A takes the answer in through the ordinary receive path.
///
/// There is no transport here and there is none in the library: no socket, no
/// HTTP client, no peer address book. There is no block scanning and no
/// address monitoring, and ARC is not asked — an ARC instance answers for
/// what was submitted through it and nothing else, so it has no standing to
/// prove a counterparty's transaction (spv-understanding.md §2, §4 and
/// Critical Implementation Note 2).
///
/// The scenario is 0lx's: G is a mined transaction, P spends G:0 and pays
/// wallet A, and a heavier branch orphans G's block so P:0 cannot be put into
/// a BEEF. What is new is that A now asks B for G's fresh proof instead of
/// waiting for B to think of re-sending.
///
/// Wallet B holds P with wallet A recorded as its counterparty, and holds G's
/// proof in the block that won. B reaches that state here by taking P in
/// through its own receive path, which is a shortcut for "B is the other side
/// of this payment": after a payment both wallets hold a row for P naming the
/// other as the counterparty (bead libspiffy-cq16, V-68), and it is that row
/// the protocol turns on.
library;

import 'dart:async';
import 'dart:convert';
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

/// What wallet A calls wallet B, and what B's row for P records as its
/// counterparty. An opaque, app-chosen string: libspiffy compares it and
/// nothing more.
const kPeerB = 'peer-b';

/// What wallet B calls wallet A, and what A's row for P records.
const kPeerA = 'peer-a';

void main() {
  final genesis = NetworkParams.regtest.genesisHeader;

  final counterpartyKey = dartsv.SVPrivateKey.fromHex('7c' * 32, dartsv.NetworkType.TEST);
  final counterpartyLock =
      dartsv.P2PKHLockBuilder.fromAddress(counterpartyKey.publicKey.toAddress(dartsv.NetworkType.TEST));

  /// G: a mined transaction, the proven ancestor. Proven by its BUMP alone,
  /// so an orphaned BUMP leaves the walk with nowhere to go.
  final g = _rawTransaction(
    prevTxid: Uint8List.fromList(List<int>.generate(32, (i) => 0xc0 + i)),
    outputs: [(300000, Uint8List.fromList(hex.decode(counterpartyLock.getScriptPubkey().toHex())))],
  );

  /// P: the payment, spending G:0 to the wallets' root address. Unmined.
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

  /// Branch A: G is in A2, at height 2.
  final gBumpA = bumpForG(index: 1, seed: 13);
  final a1 = RegtestMiner.mine(parent: genesis, seed: 'a2v3-A1');
  final a2 = RegtestMiner.mine(parent: a1, merkleRoot: rootOf(gBumpA));
  final a3 = RegtestMiner.mine(parent: a2, seed: 'a2v3-A3');

  /// Branch B, which wins: forks at A1, so A2 and A3 leave the chain, and G
  /// is mined again in B2 under a different merkle path.
  final gBumpB = bumpForG(index: 0, seed: 37);
  final b2 = RegtestMiner.mine(parent: a1, merkleRoot: rootOf(gBumpB));
  final b3 = RegtestMiner.mine(parent: b2, seed: 'a2v3-B3');
  final b4 = RegtestMiner.mine(parent: b3, seed: 'a2v3-B4');

  /// A BUMP for G that names height 2 but no block we hold: B2's header
  /// contradicts it, so a proof response carrying it must be rejected.
  final gBumpBogus = bumpForG(index: 0, seed: 99);

  String beefHexWith(BUMP gBump) => hex.encode(BEEF
      .create(
        bumps: [gBump],
        txs: [Uint8List.fromList(hex.decode(g.serialize())), Uint8List.fromList(hex.decode(p.serialize()))],
        hasMerkle: [true, false],
        bumpIndex: [0],
      )
      .serialize());

  late Directory dir;
  final systems = <LibSpiffyActorSystem>[];
  final isars = <Isar>[];
  final subscriptions = <StreamSubscription<dynamic>>[];

  setUpAll(() async {
    await ensureIsarInitialized();
  });

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('a2v3_proof_request_');
  });

  tearDown(() async {
    for (final sub in subscriptions) {
      await sub.cancel();
    }
    subscriptions.clear();
    for (final s in systems) {
      try {
        await s.shutdown();
      } catch (_) {}
    }
    systems.clear();
    isars.clear();
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  });

  /// One wallet, its own Isar database, storage and actor system.
  Future<_Wallet> start(String name) async {
    final isar = await Isar.open(
      LibSpiffySchemas.allSchemas,
      directory: dir.path,
      name: '${name}_${DateTime.now().microsecondsSinceEpoch}',
    );
    isars.add(isar);
    final arc = _FakeArc();
    final system = LibSpiffyActorSystem();
    await system.initialize(
      actorSystem: LocalActorSystem(ActorSystemConfig()),
      isar: isar,
      readModelStorage: InMemoryWalletStorage(),
      secureStorage: InMemorySecureStorage(),
      dataDirectory: dir.path,
      networkType: 'regtest',
      enableP2P: false,
      arcService: arc,
    );
    systems.add(system);
    final events = <coord.CoordinatorEvent>[];
    subscriptions.add(system.coordinatorEvents!.listen(events.add));
    return _Wallet(name: name, walletId: 'a2v3-$name', system: system, arc: arc, events: events);
  }

  Future<void> sendHeaders(_Wallet w, List<BlockHeader> headers, int tip) async {
    w.system.headerSyncActor.tell(BlockHeadersReceivedMessage(
      peerId: 'peer',
      headers: headers,
      startHeight: 1,
    ) as dynamic);
    await _until(() async => w.system.headerChain.bestHeight == tip, '${w.name}: tip at $tip');
  }

  /// A BEEF arrives from [from] through the public receive path.
  Future<void> receive(_Wallet w, String beefHex, {required String? from}) async {
    final imported = w.system.coordinatorEvents!
        .where((e) => e is coord.TransactionImportedEvent && e.transactionId == p.id)
        .cast<coord.TransactionImportedEvent>()
        .first
        .timeout(const Duration(seconds: 20));
    w.system.coordinator.tell(coord.ReceiveTransactionCommand(
      walletId: w.walletId,
      beefHex: beefHex,
      fromCounterparty: from,
    ));
    final result = await imported;
    expect(result.success, isTrue, reason: result.error);
  }

  Future<BitcoinUtxo?> receivedUtxo(_Wallet w) async {
    for (final u in await w.system.walletStorage.getUTXOs(w.walletId, includeSpent: true)) {
      if (u.txid == p.id && u.vout == 0) return u;
    }
    return null;
  }

  /// Wallet A: headers on branch A, P received from [from], then the
  /// reorganization that orphans G's block. Its output is left unspendable
  /// and awaiting a proof for G.
  Future<_Wallet> walletAAwaitingProof({required String? from}) async {
    final a = await start('a');
    await sendHeaders(a, [a1, a2, a3], 3);
    await createWallet(
      walletManager: a.system.walletManager,
      actorSystem: a.system.actorSystem,
      walletId: a.walletId,
      walletName: 'A',
      xpriv: kTestXpriv,
    );
    await _until(() async => await a.system.walletStorage.isWalletAddress(a.walletId, kTestRootAddress),
        'A: root address projected');
    await receive(a, beefHexWith(gBumpA), from: from);

    // Make P's output spendable, as 0lx does: ARC answers for P because we
    // hold its output, i.e. it is a transaction we would broadcast.
    a.arc.responses[p.id] = ArcTransactionResponse.fromJson({
      'timestamp': '2026-09-17T08:00:00Z',
      'txid': p.id,
      'txStatus': 'SEEN_ON_NETWORK',
    });
    a.system.arcActor.tell(CheckStoragePendingUTXOsMessage(triggerBlockHeight: 3));
    await _until(() async => (await receivedUtxo(a))?.status == UTXOStatus.available,
        'A: P output available', timeout: const Duration(seconds: 12));

    // The heavier branch orphans A2 and A3: G's proof is kept but no longer
    // counts, so the walk back from P runs off the end of what we store.
    await sendHeaders(a, [a1, b2, b3, b4], 4);
    await _until(() async => await a.system.walletStorage.getMerkleProof(g.id) == null,
        "A: G's proof left the active chain", timeout: const Duration(seconds: 12));
    return a;
  }

  /// Wallet B: the other side of the payment. Holds P with wallet A recorded
  /// as its counterparty, and G proven in the block that won.
  Future<_Wallet> walletBHoldingTheProof() async {
    final b = await start('b');
    await sendHeaders(b, [a1, b2, b3, b4], 4);
    await createWallet(
      walletManager: b.system.walletManager,
      actorSystem: b.system.actorSystem,
      walletId: b.walletId,
      walletName: 'B',
      xpriv: kTestXpriv,
    );
    await _until(() async => await b.system.walletStorage.isWalletAddress(b.walletId, kTestRootAddress),
        'B: root address projected');
    await receive(b, beefHexWith(gBumpB), from: kPeerA);
    await _until(() async => await b.system.walletStorage.getMerkleProof(g.id) != null,
        "B: G's proof is current", timeout: const Duration(seconds: 12));
    expect((await b.system.walletStorage.getTransaction(p.id))?.counterpartyMarker, kPeerA,
        reason: "B's row for P must name wallet A as the counterparty");
    return b;
  }

  /// Carry proof-protocol messages between the two coordinators the way an
  /// app's transport would: JSON on the wire, and the receiver is told who
  /// sent it in the receiver's own naming.
  ///
  /// [tamper] may rewrite a payload before it is delivered, to stand in for a
  /// counterparty that answers with something that does not hold up.
  void relay(_Wallet from, _Wallet to, String senderIsCalled,
      {Map<String, dynamic> Function(Map<String, dynamic>)? tamper}) {
    subscriptions.add(from.system.coordinatorEvents!
        .where((e) => e is coord.P2PMessageToSendEvent && coord.ProofP2PAdapter.handles(e.messageType))
        .cast<coord.P2PMessageToSendEvent>()
        .listen((e) {
      final onTheWire = jsonDecode(jsonEncode(e.payload)) as Map<String, dynamic>;
      to.system.coordinator.tell(coord.P2PMessageReceived(
        fromPeerId: senderIsCalled,
        messageType: e.messageType,
        payload: tamper == null ? onTheWire : tamper(onTheWire),
      ));
    }));
  }

  Future<coord.AncestorProofResponseEvent> responseOn(_Wallet w) => w.system.coordinatorEvents!
      .where((e) => e is coord.AncestorProofResponseEvent)
      .cast<coord.AncestorProofResponseEvent>()
      .first
      .timeout(const Duration(seconds: 30));

  test('a2v3: wallet A asks the counterparty recorded on the payment, wallet B answers from its own '
      'storage, and the orphaned output becomes spendable again', () async {
    final a = await walletAAwaitingProof(from: kPeerB);
    final b = await walletBHoldingTheProof();
    final storage = a.system.walletStorage;
    final chains = AncestorChainService(storage: storage);

    // The output cannot be put into a BEEF, and the wallet names who to ask:
    // the counterparty of P, not of G (whom we have never dealt with).
    expect((await chains.collectAncestorChainForUtxos([p.id])).isValid, isFalse);
    final awaiting = await storage.getOutputsAwaitingAncestorProof(a.walletId);
    expect(awaiting.map((o) => (o.outpoint, o.counterpartyMarker)), [('${p.id}:0', kPeerB)],
        reason: 'the query must name the counterparty to ask for a fresh proof');
    expect(awaiting.single.ancestors.map((x) => (x.txid, x.lastProofStatus)), [(g.id, MerkleProofStatus.orphaned)]);

    relay(a, b, kPeerA);
    relay(b, a, kPeerB);

    final answered = responseOn(a);
    final asking = a.system.coordinatorEvents!
        .where((e) => e is coord.AncestorProofRequestedEvent)
        .cast<coord.AncestorProofRequestedEvent>()
        .first
        .timeout(const Duration(seconds: 15));
    final servingOnB = b.system.coordinatorEvents!
        .where((e) => e is coord.AncestorProofRequestReceivedEvent)
        .cast<coord.AncestorProofRequestReceivedEvent>()
        .first
        .timeout(const Duration(seconds: 15));

    a.system.coordinator.tell(coord.RequestAncestorProofCommand(walletId: a.walletId, txid: p.id));

    // A asked exactly the counterparty its row names, and asked about G.
    final asked = await asking;
    expect((asked.success, asked.toPeerId, asked.txid), (true, kPeerB, p.id));
    expect(asked.ancestorTxids, [g.id],
        reason: 'the request names the ancestor the output is waiting on');

    // B answered, having checked that the requester is the counterparty it
    // recorded for P.
    final servedOnB = await servingOnB;
    expect((servedOnB.fromPeerId, servedOnB.txid, servedOnB.answered, servedOnB.reason),
        (kPeerA, p.id, true, null));

    final response = await answered;
    expect((response.success, response.error, response.fromPeerId), (true, null, kPeerB));

    // The fresh proof B supplied superseded the orphaned row — through the
    // ordinary receive path, verified against A's own header chain. Nothing
    // in this test wrote a proof by hand. (The verdict comes back before the
    // projection has written it, so wait for the row.)
    await _until(() async => await storage.getMerkleProof(g.id) != null,
        "A: G's fresh proof became the current proof", timeout: const Duration(seconds: 15));
    final restored = (await storage.getMerkleProof(g.id))!;
    expect((restored.status, restored.blockHeight, restored.blockHash, restored.merkleProof.single),
        (MerkleProofStatus.verified, 2, b2.blockHash().toString(), gBumpB.toHex()));
    expect([for (final row in await storage.getMerkleProofHistory(g.id)) (row.merkleProof.single, row.status)],
        containsAll([
          (gBumpA.toHex(), MerkleProofStatus.orphaned),
          (gBumpB.toHex(), MerkleProofStatus.verified),
        ]),
        reason: 'the orphaned row is evidence and is never deleted');

    // The output is spendable again and no longer reported as awaiting.
    final after = await chains.collectAncestorChainForUtxos([p.id]);
    expect(after.isValid, isTrue, reason: after.error);
    expect(after.merkleProofs.map((m) => (m.txid, m.merkleProof.single)), [(g.id, gBumpB.toHex())]);
    expect(await storage.getOutputsAwaitingAncestorProof(a.walletId), isEmpty);

    final ready = a.system.coordinatorEvents!
        .where((e) => e is coord.PaymentReadyEvent && e.invoiceId == 'a2v3-invoice')
        .cast<coord.PaymentReadyEvent>()
        .first
        .timeout(const Duration(seconds: 20));
    a.system.coordinator.tell(coord.PayInvoiceCommand(
      walletId: a.walletId,
      invoiceId: 'a2v3-invoice',
      addresses: ['mfWxJ45yp2SFn7UciZyNpvDKrzbhyfKrY8'],
      amount: BigInt.from(50000),
    ));
    final payment = await ready;
    expect(payment.success, isTrue, reason: payment.error);
    expect(BEEF.parse(payment.beefBytes).bumps.map((x) => x.toHex()), [gBumpB.toHex()],
        reason: 'the payment BEEF carries the fresh BUMP the counterparty supplied');
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('a2v3: a proof response that does not verify against our own header chain is rejected, the output '
      'stays awaiting, and the BEEF is still retained', () async {
    final a = await walletAAwaitingProof(from: kPeerB);
    final b = await walletBHoldingTheProof();
    final storage = a.system.walletStorage;

    relay(a, b, kPeerA);
    // B's answer is replaced in flight with a BEEF whose BUMP for G names
    // height 2 but a merkle root B2's header contradicts. We asked for it,
    // which is no reason to trust it.
    relay(b, a, kPeerB, tamper: (payload) => {...payload, 'beefHex': beefHexWith(gBumpBogus)});

    final answered = responseOn(a);
    a.system.coordinator.tell(coord.RequestAncestorProofCommand(walletId: a.walletId, txid: p.id));
    final response = await answered;

    expect(response.success, isFalse,
        reason: 'a proof that does not verify against our own headers must be rejected');
    expect(response.error, contains('merkle proof'),
        reason: 'the rejection must come from the proof check, not from a transport mishap');

    // The output is exactly where it was: no current proof, still awaiting.
    expect(await storage.getMerkleProof(g.id), isNull,
        reason: 'a rejected proof must never become the current proof');
    final awaiting = await storage.getOutputsAwaitingAncestorProof(a.walletId);
    expect(awaiting.map((o) => o.outpoint), ['${p.id}:0'],
        reason: 'the output must stay awaiting a proof');
    expect((await AncestorChainService(storage: storage).collectAncestorChainForUtxos([p.id])).isValid, isFalse);

    // And it is retained: a counterparty handed us something that does not
    // match our chain, which is evidence, and it cannot be fetched again.
    final history = [
      for (final row in await storage.getMerkleProofHistory(g.id)) (row.merkleProof.single, row.status)
    ];
    expect(history, containsAll([
      (gBumpA.toHex(), MerkleProofStatus.orphaned),
      (gBumpBogus.toHex(), MerkleProofStatus.rejected),
    ]), reason: 'the rejected proof is retained and the orphaned row is untouched');
    expect(history.map((h) => h.$1), isNot(contains(gBumpB.toHex())));
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('a2v3: a proof request from someone who is not the recorded counterparty is refused, and tells '
      'them nothing about the transaction', () async {
    final b = await walletBHoldingTheProof();

    Future<(coord.P2PMessageToSendEvent, coord.AncestorProofRequestReceivedEvent)> ask(String who) async {
      final sent = b.system.coordinatorEvents!
          .where((e) => e is coord.P2PMessageToSendEvent && e.messageType == coord.ProofP2PAdapter.proofResponseType)
          .cast<coord.P2PMessageToSendEvent>()
          .first
          .timeout(const Duration(seconds: 15));
      final served = b.system.coordinatorEvents!
          .where((e) => e is coord.AncestorProofRequestReceivedEvent)
          .cast<coord.AncestorProofRequestReceivedEvent>()
          .first
          .timeout(const Duration(seconds: 15));
      b.system.coordinator.tell(coord.P2PMessageReceived(
        fromPeerId: who,
        messageType: coord.ProofP2PAdapter.proofRequestType,
        payload: {'requestId': 'req-$who', 'txid': p.id, 'ancestors': [g.id]},
      ));
      return (await sent, await served);
    }

    final (toMallory, malloryServed) = await ask('mallory');
    expect(toMallory.toPeerId, 'mallory');
    expect(toMallory.payload.containsKey('beefHex'), isFalse,
        reason: 'a peer that is not the recorded counterparty must get no BEEF');
    expect(toMallory.payload['error'], coord.ProofP2PAdapter.refusalOnTheWire,
        reason: 'the refusal on the wire must not say whether we know the transaction');
    expect(malloryServed.answered, isFalse);
    expect(malloryServed.reason, contains('not the counterparty recorded'));

    // A transaction we do not hold at all is refused in exactly the same
    // words, so asking cannot map out what a wallet knows.
    final (toStranger, _) = await _askAs(b, 'mallory', 'ff' * 32);
    expect(toStranger.payload['error'], coord.ProofP2PAdapter.refusalOnTheWire);
    expect(toStranger.payload.containsKey('beefHex'), isFalse);

    // The counterparty B actually recorded is answered.
    final (toPeerA, peerAServed) = await ask(kPeerA);
    expect(peerAServed.answered, isTrue);
    expect(toPeerA.payload['error'], isNull);
    final beef = BEEF.parse(Uint8List.fromList(hex.decode(toPeerA.payload['beefHex'] as String)));
    expect([
      for (var i = 0; i < beef.txs.length; i++) (hex.encode(beef.calculateTxid(beef.txs[i])), beef.hasMerkle[i])
    ], [
      (g.id, true),
      (p.id, false),
    ]);
    expect(beef.bumps.map((x) => x.toHex()), [gBumpB.toHex()],
        reason: 'the answer carries a BUMP built from our current proofs and headers');
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('a2v3: an unsolicited proof response from someone who is not the recorded counterparty is refused, '
      'however good its proof', () async {
    final a = await walletAAwaitingProof(from: kPeerB);
    final storage = a.system.walletStorage;

    final answered = responseOn(a);
    // A perfectly valid fresh BEEF, from a peer that is not the counterparty
    // recorded for P. Being handed a good proof by a stranger is not a
    // relationship, and we asked nobody.
    a.system.coordinator.tell(coord.P2PMessageReceived(
      fromPeerId: 'mallory',
      messageType: coord.ProofP2PAdapter.proofResponseType,
      payload: {'txid': p.id, 'beefHex': beefHexWith(gBumpB)},
    ));
    final response = await answered;

    expect(response.success, isFalse);
    expect(response.error, contains('not the counterparty recorded'));
    expect(await storage.getMerkleProof(g.id), isNull,
        reason: 'nothing a stranger sends may reach the receive path on the strength of having been asked for');
    expect((await storage.getOutputsAwaitingAncestorProof(a.walletId)).map((o) => o.outpoint),
        ['${p.id}:0']);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('a2v3: with no counterparty marker on the payment there is nobody to ask, and no request goes out',
      () async {
    final a = await walletAAwaitingProof(from: null);
    final storage = a.system.walletStorage;

    expect((await storage.getTransaction(p.id))?.counterpartyMarker, isNull,
        reason: 'no marker was supplied when the payment was received');
    final awaiting = await storage.getOutputsAwaitingAncestorProof(a.walletId);
    expect(awaiting.map((o) => (o.outpoint, o.counterpartyMarker)), [('${p.id}:0', null)]);

    final asked = a.system.coordinatorEvents!
        .where((e) => e is coord.AncestorProofRequestedEvent)
        .cast<coord.AncestorProofRequestedEvent>()
        .first
        .timeout(const Duration(seconds: 15));
    a.system.coordinator.tell(coord.RequestAncestorProofCommand(walletId: a.walletId, txid: p.id));
    final result = await asked;

    expect((result.success, result.toPeerId), (false, null));
    expect(result.error, contains('unrecoverable by request'));
    expect(
        a.events.where((e) =>
            e is coord.P2PMessageToSendEvent && e.messageType == coord.ProofP2PAdapter.proofRequestType),
        isEmpty,
        reason: 'no request may go out when there is nobody to send it to');
  }, timeout: const Timeout(Duration(minutes: 3)));
}

/// Ask [w] about [txid] as [who], and return what went back on the wire.
Future<(coord.P2PMessageToSendEvent, coord.AncestorProofRequestReceivedEvent)> _askAs(
    _Wallet w, String who, String txid) async {
  final sent = w.system.coordinatorEvents!
      .where((e) => e is coord.P2PMessageToSendEvent && e.messageType == coord.ProofP2PAdapter.proofResponseType)
      .cast<coord.P2PMessageToSendEvent>()
      .first
      .timeout(const Duration(seconds: 15));
  final served = w.system.coordinatorEvents!
      .where((e) => e is coord.AncestorProofRequestReceivedEvent)
      .cast<coord.AncestorProofRequestReceivedEvent>()
      .first
      .timeout(const Duration(seconds: 15));
  w.system.coordinator.tell(coord.P2PMessageReceived(
    fromPeerId: who,
    messageType: coord.ProofP2PAdapter.proofRequestType,
    payload: {'requestId': 'req-unknown', 'txid': txid},
  ));
  return (await sent, await served);
}

class _Wallet {
  final String name;
  final String walletId;
  final LibSpiffyActorSystem system;
  final _FakeArc arc;
  final List<coord.CoordinatorEvent> events;

  _Wallet({
    required this.name,
    required this.walletId,
    required this.system,
    required this.arc,
    required this.events,
  });
}

/// A raw transaction with one input spending [prevTxid]:0 with an OP_TRUE
/// scriptSig.
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

/// ARC that answers from [responses] and knows no other transaction.
class _FakeArc extends ArcService {
  _FakeArc() : super(baseUrl: 'fake://arc');

  final Map<String, ArcTransactionResponse> responses = {};

  @override
  Future<ArcTransactionResponse> getTransaction(String txid) async {
    final response = responses[txid];
    if (response == null) throw ArcException('Failed to get transaction: {"status":404}');
    return response;
  }
}
