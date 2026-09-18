/// Bead libspiffy-fggl: a merkle proof in a received BEEF confirms a
/// transaction the wallet recorded, wherever it sits in the BEEF.
///
/// Wallet A pays Bob and records the payment T as a deferred spend: its
/// inputs are held, its change is pending, the payment is outstanding, and
/// nothing but ARC could ever move it on. Later Bob spends what T paid him
/// and hands us the BEEF of that spend, with T inside it as an ancestor
/// carrying its BUMP. That BUMP, validated against our active header chain,
/// is the first hard evidence we get that our own transaction was mined, and
/// it arrives the way the peer-to-peer model intends: from a counterparty,
/// with no scanning and no polling.
///
/// The BEEF was thrown away: an ancestor proof was filed as SPV evidence and
/// compared against nothing, a proven subject the wallet had recorded flipped
/// the read-model row to confirmed without journaling the confirmation, and
/// the proven-subject branch dropped every other member of the BEEF.
///
/// End to end through LibSpiffyActorSystem on regtest with real-PoW headers
/// and an ARC that knows nothing (so every confirmation here comes from the
/// BEEF alone).
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:dactor/dactor.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:eventador/eventador.dart';
import 'package:isar/isar.dart';
import 'package:libspiffy/coordinator.dart' as coord;
import 'package:libspiffy/libspiffy.dart';
import 'package:libspiffy/src/actors/spv_messages.dart' show BlockHeadersReceivedMessage;
import 'package:libspiffy/src/core/wallet_events.dart' as domain;
import 'package:libspiffy/src/spv/network_params.dart';
import 'package:spiffynode/spiffy_node.dart';
import 'package:test/test.dart';

import '../spv/regtest_chain_builder.dart';
import 'isar_test_helper.dart';
import 'p2p_test_helpers.dart';

void main() {
  final genesis = NetworkParams.regtest.genesisHeader;

  // Bob: we pay him, and he spends what we paid him.
  final bobKey = dartsv.SVPrivateKey.fromHex('3c' * 32, dartsv.NetworkType.TEST);
  final bobLock = dartsv.P2PKHLockBuilder.fromAddress(bobKey.publicKey.toAddress(dartsv.NetworkType.TEST));
  final bobScript = bobLock.getScriptPubkey().toHex();
  final ourLock = dartsv.P2PKHLockBuilder.fromAddress(dartsv.Address(kTestRootAddress));

  dartsv.DefaultTransactionSigner bobSigner() => dartsv.DefaultTransactionSigner(
      dartsv.SighashType.SIGHASH_ALL.value | dartsv.SighashType.SIGHASH_FORKID.value, bobKey);

  /// F: a mined transaction paying wallet A's root address; our only coin.
  final f = _rawTransaction(
    prevTxid: Uint8List.fromList(List<int>.generate(32, (i) => 0xc0 + i)),
    outputs: [(500000, Uint8List.fromList(hex.decode(ourLock.getScriptPubkey().toHex())))],
  );

  /// G: a mined transaction of Bob's, nothing to do with our wallet; Bob
  /// spends it alongside what we paid him.
  final g = _rawTransaction(
    prevTxid: Uint8List.fromList(List<int>.generate(32, (i) => 0x20 + i)),
    outputs: [(300000, Uint8List.fromList(hex.decode(bobScript)))],
  );

  Uint8List internalTxid(String displayTxid) =>
      Uint8List.fromList(hex.decode(displayTxid).reversed.toList());

  BUMP bumpFor(String displayTxid, int blockHeight, int seed) => BUMP.fromMerklePath(
        blockHeight: blockHeight,
        txid: internalTxid(displayTxid),
        index: 0,
        siblings: [Uint8List.fromList(List<int>.generate(32, (i) => (i * seed + seed) & 0xff))],
      );

  Hash rootOf(BUMP bump, String displayTxid) => Hash.fromBytes(bump.computeMerkleRoot(internalTxid(displayTxid)));

  final fBump = bumpFor(f.id, 2, 7);
  final gBump = bumpFor(g.id, 3, 11);
  final a1 = RegtestMiner.mine(parent: genesis, seed: 'fggl-A1');
  final a2 = RegtestMiner.mine(parent: a1, merkleRoot: rootOf(fBump, f.id));
  final a3 = RegtestMiner.mine(parent: a2, merkleRoot: rootOf(gBump, g.id));

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
  late InMemorySecureStorage secrets;
  late _FakeArc arc;
  late LibSpiffyActorSystem system;
  late InMemoryWalletStorage readModel;
  const walletId = 'fggl-wallet-a';

  setUpAll(() async {
    await ensureIsarInitialized();
  });

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('fggl_beef_proof_');
    isar = await Isar.open(
      LibSpiffySchemas.allSchemas,
      directory: dir.path,
      name: 'fggl_${DateTime.now().microsecondsSinceEpoch}',
    );
    secrets = InMemorySecureStorage();
    arc = _FakeArc();
    readModel = InMemoryWalletStorage();
    system = LibSpiffyActorSystem();
    await system.initialize(
      actorSystem: LocalActorSystem(ActorSystemConfig()),
      isar: isar,
      readModelStorage: readModel,
      secureStorage: secrets,
      dataDirectory: dir.path,
      networkType: 'regtest',
      enableP2P: false,
      arcService: arc,
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

  /// Hands [beef] to the wallet and returns the coordinator's verdict.
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

  Future<BitcoinUtxo?> utxo(String txid, int vout) async {
    for (final u in await readModel.getUTXOs(walletId, includeSpent: true)) {
      if (u.txid == txid && u.vout == vout) return u;
    }
    return null;
  }

  Future<List<BitcoinUtxo>> utxosOf(String txid) async => [
        for (final u in await readModel.getUTXOs(walletId, includeSpent: true))
          if (u.txid == txid) u,
      ];

  /// Waits until the wallet aggregate has handled every command sent so far
  /// and the projection has applied their events: a command sent now lands
  /// behind them in the same mailbox. Needed before asserting that something
  /// was NOT journaled — the commands of a receive are told to the aggregate
  /// before the coordinator's verdict reaches us.
  Future<void> barrier() async {
    final address = await generateAddress(
      walletManager: system.walletManager,
      actorSystem: system.actorSystem,
      walletId: walletId,
    );
    await _until(() async => await readModel.getAddressMetadata(walletId, address) != null,
        'the wallet and its projection caught up');
  }

  Future<List<domain.TransactionConfirmedEvent>> confirmations(String txid) async => [
        for (final event in await system.eventStore.getEvents('BitcoinWallet_$walletId'))
          if (event is domain.TransactionConfirmedEvent && event.txid == txid) event,
      ];

  /// Wallet A, its headers up to height 3, holding F's 500,000 satoshis.
  Future<void> fundedWallet() async {
    await sendHeaders([a1, a2, a3], 1, 3);
    await createWallet(
      walletManager: system.walletManager,
      actorSystem: system.actorSystem,
      walletId: walletId,
      walletName: 'A',
      xpriv: kTestXpriv,
    );
    await _until(() async => await readModel.isWalletAddress(walletId, kTestRootAddress), 'root address projected');

    final funded = await receive(beefHex([(f, fBump)]), f.id);
    expect(funded.success, isTrue, reason: funded.error);
    await _until(() async => (await utxo(f.id, 0))?.status == UTXOStatus.available, 'F:0 available');
  }

  /// The deferred payment T: wallet A pays Bob 50,000 satoshis and keeps the
  /// change. Its input F:0 is held, not spent.
  Future<dartsv.Transaction> payBob() async {
    final ready = system.coordinatorEvents!
        .where((e) => e is coord.PaymentReadyEvent && e.invoiceId == 'fggl-invoice')
        .cast<coord.PaymentReadyEvent>()
        .first
        .timeout(const Duration(seconds: 25));
    system.coordinator.tell(coord.PayInvoiceCommand(
      walletId: walletId,
      invoiceId: 'fggl-invoice',
      addresses: [bobKey.publicKey.toAddress(dartsv.NetworkType.TEST).toString()],
      amount: BigInt.from(50000),
    ));
    final payment = await ready;
    expect(payment.success, isTrue, reason: payment.error);

    final beef = BEEF.parse(payment.beefBytes);
    for (var i = 0; i < beef.txs.length; i++) {
      if (hex.encode(beef.calculateTxid(beef.txs[i])) == payment.txid) {
        final t = dartsv.Transaction.fromHex(hex.encode(beef.txs[i]));
        // Recorded, deferred, its input held and its change pending.
        await _until(() async => (await readModel.getDeferredPayment(walletId, t.id)) != null,
            'the payment is recorded as deferred');
        expect((await readModel.getDeferredPayment(walletId, t.id))!.state, DeferredPaymentState.outstanding);
        expect((await utxo(f.id, 0))!.status, isNot(UTXOStatus.spent));
        return t;
      }
    }
    fail('the payment BEEF does not hold ${payment.txid}');
  }

  /// The output of [t] that pays Bob, and the one that pays us back.
  ({int bob, int change}) outputsOf(dartsv.Transaction t) {
    final bob = t.outputs.indexWhere((o) => o.script.toHex() == bobScript);
    final change = t.outputs.indexWhere((o) => o.script.toHex() != bobScript);
    expect(bob, isNot(-1), reason: 'the payment has no output for Bob');
    expect(change, isNot(-1), reason: 'the payment has no change output');
    return (bob: bob, change: change);
  }

  /// B: Bob spends what we paid him ([t]'s output [bobVout]) together with
  /// his own coin G, and pays 30,000 satoshis back to wallet A.
  dartsv.Transaction bobSpends(dartsv.Transaction t, int bobVout) {
    final paid = t.outputs[bobVout];
    return (dartsv.TransactionBuilder()
          ..spendFromOutpointWithSigner(
            bobSigner(),
            dartsv.TransactionOutpoint(t.id, bobVout, paid.satoshis, paid.script),
            dartsv.TransactionInput.MAX_SEQ_NUMBER,
            dartsv.P2PKHUnlockBuilder(bobKey.publicKey),
          )
          ..spendFromOutpointWithSigner(
            bobSigner(),
            dartsv.TransactionOutpoint(g.id, 0, g.outputs[0].satoshis, g.outputs[0].script),
            dartsv.TransactionInput.MAX_SEQ_NUMBER,
            dartsv.P2PKHUnlockBuilder(bobKey.publicKey),
          )
          ..spendToLockBuilder(ourLock, BigInt.from(30000))
          ..spendToLockBuilder(bobLock, BigInt.from(300000))
          ..withOption(dartsv.TransactionOption.DISABLE_DUST_OUTPUTS))
        .build(false);
  }

  test('fggl (1): the BUMP of our own payment, carried as an ancestor of the transaction that spends it, '
      'confirms the payment', () async {
    await fundedWallet();
    final t = await payBob();
    final (bob: bobVout, change: changeVout) = outputsOf(t);

    // T is mined at height 4; Bob spends its output and hands us the BEEF.
    final tBump = bumpFor(t.id, 4, 13);
    await sendHeaders([RegtestMiner.mine(parent: a3, merkleRoot: rootOf(tBump, t.id))], 4, 4);
    final b = bobSpends(t, bobVout);

    final received = await receive(beefHex([(g, gBump), (t, tBump), (b, null)]), b.id);
    expect(received.success, isTrue, reason: received.error);

    await _until(() async => (await confirmations(t.id)).isNotEmpty,
        'the wallet journals the confirmation of its own payment');

    // The write model: the deferred payment is mined and its held input spent.
    expect((await readModel.getDeferredPayment(walletId, t.id))!.state, DeferredPaymentState.mined);
    expect((await utxo(f.id, 0))!.status, UTXOStatus.spent);
    expect((await utxo(f.id, 0))!.spentInTxId, t.id);

    // The read model: confirmed at the proven height, change spendable.
    final row = await readModel.getTransaction(t.id, walletId: walletId);
    expect((row?.status, row?.blockHeight), (TransactionStatus.confirmed, 4));
    final change = (await utxo(t.id, changeVout))!;
    expect(change.status, UTXOStatus.available);
    // Bead libspiffy-4dja: the same proof that puts the transaction row at
    // height 4 puts its own change output there. The two rows of one wallet
    // must not disagree about the block.
    expect(change.blockHeight, 4,
        reason: 'the change output of a payment confirmed from a BEEF proof kept no block height');
    expect(change.blockHeight, row!.blockHeight, reason: 'the transaction row and its own output disagree');

    // The proof is kept, verified against the header we hold.
    final proof = await readModel.getMerkleProof(t.id);
    expect((proof?.status, proof?.blockHeight), (MerkleProofStatus.verified, 4));

    // Bob's own funding transaction is proven too, and is none of this
    // wallet's business: no confirmation is journaled for it.
    expect(await confirmations(g.id), isEmpty,
        reason: 'a proof for a counterparty transaction wrote to the wallet journal');

    // The subject itself is unproven: what it pays us stays pending.
    final ours = (await utxosOf(b.id)).where((u) => u.satoshis == BigInt.from(30000));
    expect(ours.map((u) => u.status), [UTXOStatus.pending],
        reason: 'the ancestors of an unmined transaction being proven does not mine it');
  });

  test('fggl (1b): the same BEEF delivered twice confirms once', () async {
    await fundedWallet();
    final t = await payBob();
    final (bob: bobVout, change: changeVout) = outputsOf(t);
    final tBump = bumpFor(t.id, 4, 13);
    await sendHeaders([RegtestMiner.mine(parent: a3, merkleRoot: rootOf(tBump, t.id))], 4, 4);
    final b = bobSpends(t, bobVout);
    final beef = beefHex([(g, gBump), (t, tBump), (b, null)]);

    expect((await receive(beef, b.id)).success, isTrue);
    await _until(() async => (await confirmations(t.id)).isNotEmpty, 'confirmed once');
    expect((await receive(beef, b.id)).success, isTrue);
    // The second delivery runs through the same commands; give them time to
    // reach the journal before counting.
    await _until(() async => (await readModel.getUTXOs(walletId, includeSpent: true)).isNotEmpty, 'read model settled');
    await Future<void>.delayed(const Duration(milliseconds: 400));

    expect((await confirmations(t.id)).length, 1, reason: 'a redelivered BEEF confirmed the payment twice');
    expect((await utxo(t.id, changeVout))!.status, UTXOStatus.available);
    expect((await utxo(f.id, 0))!.status, UTXOStatus.spent);
  });

  test('fggl (2): a BEEF whose subject is our own recorded payment journals the confirmation, '
      'not only a read-model row', () async {
    await fundedWallet();
    final t = await payBob();
    final (bob: _, change: changeVout) = outputsOf(t);
    final tBump = bumpFor(t.id, 4, 13);
    await sendHeaders([RegtestMiner.mine(parent: a3, merkleRoot: rootOf(tBump, t.id))], 4, 4);

    final received = await receive(beefHex([(t, tBump)]), t.id);
    expect(received.success, isTrue, reason: received.error);
    await _until(() async => (await confirmations(t.id)).isNotEmpty,
        'the confirmation of the proven subject is journaled');

    // A read model rebuilt from the journal alone: what the write model says.
    final rebuilt = await _rebuildFromJournal(system, walletId, readModel);
    expect((await rebuilt.getDeferredPayment(walletId, t.id))!.state, DeferredPaymentState.mined,
        reason: 'the aggregate never took the deferred payment to mined');
    expect((await rebuilt.getTransaction(t.id, walletId: walletId))?.status, TransactionStatus.confirmed);

    expect((await utxo(t.id, changeVout))!.status, UTXOStatus.available);
    expect((await utxo(f.id, 0))!.status, UTXOStatus.spent);
  });

  test('fggl (3): a proven subject does not discard the rest of the BEEF', () async {
    await fundedWallet();
    final t = await payBob();
    final (bob: bobVout, change: _) = outputsOf(t);
    final tBump = bumpFor(t.id, 4, 13);
    final a4 = RegtestMiner.mine(parent: a3, merkleRoot: rootOf(tBump, t.id));
    final b = bobSpends(t, bobVout);
    final bBump = bumpFor(b.id, 5, 17);
    final a5 = RegtestMiner.mine(parent: a4, merkleRoot: rootOf(bBump, b.id));
    await sendHeaders([a4, a5], 4, 5);

    final received = await receive(beefHex([(g, gBump), (t, tBump), (b, bBump)]), b.id);
    expect(received.success, isTrue, reason: received.error);

    // Bob's own funding transaction is evidence we cannot fetch again: kept
    // with its proof, and not as a wallet transaction.
    await _until(() async => (await readModel.getAncestorTransactionsBatch([g.id])).isNotEmpty,
        'the ancestor transactions of a proven subject are retained, not discarded');
    expect(await readModel.getAncestorTransactionsBatch([g.id]), {g.id: g.serialize()});
    final gProof = await readModel.getMerkleProof(g.id);
    expect((gProof?.status, gProof?.blockHeight), (MerkleProofStatus.verified, 3));
    expect(await readModel.getTransaction(g.id, walletId: walletId), isNull);

    // And the ancestor that is ours is confirmed at its proven height.
    await _until(() async => (await confirmations(t.id)).isNotEmpty, 'our payment is confirmed from the BEEF');
    final row = await readModel.getTransaction(t.id, walletId: walletId);
    expect((row?.status, row?.blockHeight), (TransactionStatus.confirmed, 4));
  });

  test('fggl (4): a proof for a block whose header we do not have confirms nothing, and confirms once '
      'the header arrives', () async {
    await fundedWallet();
    final t = await payBob();
    final (bob: bobVout, change: _) = outputsOf(t);
    final tBump = bumpFor(t.id, 4, 13);
    final a4 = RegtestMiner.mine(parent: a3, merkleRoot: rootOf(tBump, t.id));
    final b = bobSpends(t, bobVout);
    final beef = beefHex([(g, gBump), (t, tBump), (b, null)]);

    // Our header chain stops at 3: nothing checks out at height 4.
    final tooEarly = await receive(beef, b.id);
    expect(tooEarly.success, isFalse, reason: 'a proof we cannot check against a header was accepted');
    expect(await confirmations(t.id), isEmpty, reason: 'an unverified proof confirmed our payment');
    expect((await readModel.getDeferredPayment(walletId, t.id))!.state, DeferredPaymentState.outstanding);
    expect((await utxo(f.id, 0))!.status, isNot(UTXOStatus.spent));

    // The header arrives and the counterparty delivers again.
    await sendHeaders([a4], 4, 4);
    final now = await receive(beef, b.id);
    expect(now.success, isTrue, reason: now.error);
    await _until(() async => (await confirmations(t.id)).isNotEmpty, 'confirmed once the header is known');
    expect((await readModel.getDeferredPayment(walletId, t.id))!.state, DeferredPaymentState.mined);
  });

  /// The BUMP must be walked to the merkle root of the header we hold, not
  /// merely be a BUMP at a height we have a header for. Confirming from a
  /// BEEF settles a deferred payment — the held inputs are spent and the
  /// change released — so a path that does not reproduce our header's root
  /// must prove nothing. Both tests hold the real header at T's claimed
  /// height and hand us a path over a different root.

  test('fggl (5): an ancestor BUMP that does not reproduce the header\'s merkle root proves nothing, '
      'and the receive is rejected', () async {
    await fundedWallet();
    final t = await payBob();
    final (bob: bobVout, change: changeVout) = outputsOf(t);

    // Block 4 really holds T under `mined`; the counterparty hands us a path
    // over another root.
    final mined = bumpFor(t.id, 4, 13);
    final forged = bumpFor(t.id, 4, 29);
    expect(rootOf(forged, t.id).toString(), isNot(rootOf(mined, t.id).toString()));
    await sendHeaders([RegtestMiner.mine(parent: a3, merkleRoot: rootOf(mined, t.id))], 4, 4);
    final b = bobSpends(t, bobVout);

    final received = await receive(beefHex([(g, gBump), (t, forged), (b, null)]), b.id);
    expect(received.success, isFalse,
        reason: 'a BUMP that does not walk to the merkle root of the header at its height was accepted');
    await barrier();

    expect(await confirmations(t.id), isEmpty, reason: 'a forged proof confirmed our own payment');
    expect((await readModel.getDeferredPayment(walletId, t.id))!.state, DeferredPaymentState.outstanding);
    expect((await utxo(f.id, 0))!.status, isNot(UTXOStatus.spent));
    expect((await utxo(t.id, changeVout))!.status, UTXOStatus.pending);
  });

  test('fggl (5b): under a proven subject, a member whose BUMP contradicts our header is retained '
      'but confirms nothing', () async {
    await fundedWallet();
    final t = await payBob();
    final (bob: bobVout, change: changeVout) = outputsOf(t);

    final mined = bumpFor(t.id, 4, 13);
    final forged = bumpFor(t.id, 4, 29);
    final a4 = RegtestMiner.mine(parent: a3, merkleRoot: rootOf(mined, t.id));
    final b = bobSpends(t, bobVout);
    final bBump = bumpFor(b.id, 5, 17);
    final a5 = RegtestMiner.mine(parent: a4, merkleRoot: rootOf(bBump, b.id));
    await sendHeaders([a4, a5], 4, 5);

    // The subject's own proof is sound, so the receive stands; the member's
    // is not, so it is evidence of nothing.
    final received = await receive(beefHex([(g, gBump), (t, forged), (b, bBump)]), b.id);
    expect(received.success, isTrue, reason: received.error);
    // Retained: a contradicted proof is kept as a rejected row (never a
    // current one, so `getMerkleProof` does not return it) and the raw
    // transaction stays in the ancestor store.
    await _until(() async => (await readModel.getMerkleProofHistory(t.id)).isNotEmpty,
        'the contradicted proof is retained, not dropped');
    expect((await readModel.getMerkleProofHistory(t.id)).map((r) => (r.merkleProof.single, r.status)),
        [(forged.toHex(), MerkleProofStatus.rejected)]);
    expect(await readModel.getMerkleProof(t.id), isNull, reason: 'a contradicted proof became the current one');
    expect(await readModel.getAncestorTransactionsBatch([t.id]), {t.id: t.serialize()});
    await barrier();

    expect(await confirmations(t.id), isEmpty, reason: 'a forged proof confirmed our own payment');
    expect((await readModel.getDeferredPayment(walletId, t.id))!.state, DeferredPaymentState.outstanding);
    expect((await utxo(f.id, 0))!.status, isNot(UTXOStatus.spent));
    expect((await utxo(t.id, changeVout))!.status, UTXOStatus.pending);
    expect((await readModel.getTransaction(t.id, walletId: walletId))?.status, isNot(TransactionStatus.confirmed));
  });
}

/// A read model rebuilt from the wallet's journal alone (the headers are
/// copied over: they are synced, not journaled).
Future<InMemoryWalletStorage> _rebuildFromJournal(
    LibSpiffyActorSystem system, String walletId, ReadModelStorage live) async {
  final fresh = InMemoryWalletStorage();
  for (var h = 0; h <= system.headerChain.bestHeight; h++) {
    final header = await live.getBlockHeaderByHeight(h);
    if (header != null) await fresh.storeBlockHeader(header, h);
  }
  final projection = WalletProjection(
    projectionId: 'fggl-rebuild-${DateTime.now().microsecondsSinceEpoch}',
    eventStore: system.eventStore,
    storage: fresh,
  );
  final List<Event> events = await system.eventStore.getEvents('BitcoinWallet_$walletId');
  for (final event in events) {
    await projection.handle(event);
  }
  return fresh;
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
    {Duration timeout = const Duration(seconds: 12)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!await condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for: $what');
    }
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}

/// ARC that knows no transaction at all: every confirmation in these tests
/// comes from a BEEF.
class _FakeArc extends ArcService {
  _FakeArc() : super(baseUrl: 'fake://arc');

  @override
  Future<ArcTransactionResponse> getTransaction(String txid) async {
    throw ArcException('Failed to get transaction: {"status":404}');
  }
}
