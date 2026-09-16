/// Bead libspiffy-68mz: a BEEF we cannot judge yet is kept, not thrown away.
///
/// A counterparty hands us a payment whose ancestor is proven in a block our
/// header chain has not reached. That says nothing about the proof — it may
/// be perfectly good — but the unproven-subject branch of SPVActor failed the
/// whole receive, and the raw transactions and BUMPs went nowhere. Nothing
/// can hand them to us again: there is no block scanning, no indexer, and ARC
/// knows only what we broadcast ourselves. Meanwhile the proven-subject
/// branch had already been made lenient (V-56), so the two branches
/// disagreed about what "we have no header there" means.
///
/// Now the two cases are told apart: a header we hold that contradicts a
/// proof is still fatal, while a height we have not synced retains the BEEF
/// and re-runs the receive when the header arrives — the counterparty does
/// not re-send.
///
/// End to end through LibSpiffyActorSystem on regtest with real-PoW headers
/// and an ARC that knows nothing, so nothing here is settled by a status
/// string.
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
import 'package:libspiffy/src/core/wallet_events.dart' as domain;
import 'package:libspiffy/src/spv/network_params.dart';
import 'package:spiffynode/spiffy_node.dart';
import 'package:test/test.dart';

import '../spv/regtest_chain_builder.dart';
import 'isar_test_helper.dart';
import 'p2p_test_helpers.dart';

void main() {
  final genesis = NetworkParams.regtest.genesisHeader;

  // Bob: he holds a mined coin and pays us from it.
  final bobKey = dartsv.SVPrivateKey.fromHex('5e' * 32, dartsv.NetworkType.TEST);
  final bobLock = dartsv.P2PKHLockBuilder.fromAddress(bobKey.publicKey.toAddress(dartsv.NetworkType.TEST));
  final ourLock = dartsv.P2PKHLockBuilder.fromAddress(dartsv.Address(kTestRootAddress));

  dartsv.DefaultTransactionSigner bobSigner() => dartsv.DefaultTransactionSigner(
      dartsv.SighashType.SIGHASH_ALL.value | dartsv.SighashType.SIGHASH_FORKID.value, bobKey);

  /// G: Bob's mined coin, the ancestor whose proof we cannot check yet.
  final g = _rawTransaction(
    prevTxid: Uint8List.fromList(List<int>.generate(32, (i) => 0x40 + i)),
    outputs: [(400000, Uint8List.fromList(hex.decode(bobLock.getScriptPubkey().toHex())))],
  );

  Uint8List internalTxid(String displayTxid) => Uint8List.fromList(hex.decode(displayTxid).reversed.toList());

  BUMP bumpFor(String displayTxid, int blockHeight, int seed) => BUMP.fromMerklePath(
        blockHeight: blockHeight,
        txid: internalTxid(displayTxid),
        index: 0,
        siblings: [Uint8List.fromList(List<int>.generate(32, (i) => (i * seed + seed) & 0xff))],
      );

  Hash rootOf(BUMP bump, String displayTxid) => Hash.fromBytes(bump.computeMerkleRoot(internalTxid(displayTxid)));

  /// G is mined in block 3; the wallet's chain is only ever told about 1-2
  /// until the test says otherwise.
  final gBump = bumpFor(g.id, 3, 23);
  final a1 = RegtestMiner.mine(parent: genesis, seed: '68mz-A1');
  final a2 = RegtestMiner.mine(parent: a1, seed: '68mz-A2');
  final a3 = RegtestMiner.mine(parent: a2, merkleRoot: rootOf(gBump, g.id));

  /// P: Bob spends G and pays wallet A 90,000 satoshis. Unproven itself, so
  /// its ancestor's proof is what the receive rests on.
  final p = (dartsv.TransactionBuilder()
        ..spendFromOutpointWithSigner(
          bobSigner(),
          dartsv.TransactionOutpoint(g.id, 0, g.outputs[0].satoshis, g.outputs[0].script),
          dartsv.TransactionInput.MAX_SEQ_NUMBER,
          dartsv.P2PKHUnlockBuilder(bobKey.publicKey),
        )
        ..spendToLockBuilder(ourLock, BigInt.from(90000))
        ..spendToLockBuilder(bobLock, BigInt.from(300000))
        ..withOption(dartsv.TransactionOption.DISABLE_DUST_OUTPUTS))
      .build(false);

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
  late _FakeArc arc;
  late LibSpiffyActorSystem system;
  late InMemoryWalletStorage readModel;
  const walletId = '68mz-wallet-a';

  setUpAll(() async {
    await ensureIsarInitialized();
  });

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('m68mz_beef_retained_');
    isar = await Isar.open(
      LibSpiffySchemas.allSchemas,
      directory: dir.path,
      name: 'm68mz_${DateTime.now().microsecondsSinceEpoch}',
    );
    arc = _FakeArc();
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

  /// The coordinator's next verdict on [subjectTxid] without sending
  /// anything: what the retained receive produces on its own.
  Future<coord.TransactionImportedEvent> nextVerdict(String subjectTxid) => system.coordinatorEvents!
      .where((e) => e is coord.TransactionImportedEvent && e.transactionId == subjectTxid)
      .cast<coord.TransactionImportedEvent>()
      .first
      .timeout(const Duration(seconds: 25));

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

  test('68mz: a BEEF whose ancestor proof is above our chain tip is retained, and the receive completes '
      'when the header arrives — without the counterparty re-sending', () async {
    await sendHeaders([a1, a2], 1, 2);
    await createTheWallet();

    final beef = beefHex([(g, gBump), (p, null)]);

    // Our chain stops at 2, G claims block 3: nothing can be checked.
    final tooEarly = await receive(beef, p.id);
    expect(tooEarly.success, isFalse, reason: 'an unverifiable proof must not credit the wallet');
    expect(tooEarly.error, contains('3'), reason: 'the caller is told which header is missing: ${tooEarly.error}');
    await barrier();
    expect(await utxosOf(p.id), isEmpty, reason: 'nothing is credited before a proof checks out');

    // Retained: both raw transactions are in the shared ancestor store and
    // the BUMP is filed as a pendingHeader proof. Nothing could hand these
    // to us again.
    expect((await readModel.getAncestorTransactionsBatch([g.id, p.id])).keys.toSet(), {g.id, p.id},
        reason: 'the BEEF was dropped: its transactions cannot be fetched from anywhere');
    final held = await readModel.getMerkleProof(g.id);
    expect((held?.status, held?.blockHeight, held?.merkleProof.single),
        (MerkleProofStatus.pendingHeader, 3, gBump.toHex()),
        reason: 'the BUMP was dropped');

    // The header for block 3 arrives. Bob sends nothing.
    final verdict = nextVerdict(p.id);
    await sendHeaders([a3], 3, 3);

    final settled = await verdict;
    expect(settled.success, isTrue, reason: settled.error);
    await _until(() async => (await utxosOf(p.id)).isNotEmpty, 'the retained receive credits the wallet');
    final ours = (await utxosOf(p.id)).where((u) => u.satoshis == BigInt.from(90000)).toList();
    expect(ours.map((u) => u.status), [UTXOStatus.pending],
        reason: 'the subject is unmined, so its outputs are pending — a BEEF proves the funding history only');

    // And the ancestor's proof is verified against the header we now hold.
    final proof = await readModel.getMerkleProof(g.id);
    expect((proof?.status, proof?.blockHeight), (MerkleProofStatus.verified, 3));
  });

  test('68mz: a proof the header at its height contradicts stays fatal, and is never retried', () async {
    // Block 3 really holds G under `gBump`; the counterparty hands us a path
    // over another root, and we hold the real header.
    final forged = bumpFor(g.id, 3, 41);
    expect(rootOf(forged, g.id).toString(), isNot(rootOf(gBump, g.id).toString()));
    await sendHeaders([a1, a2, a3], 1, 3);
    await createTheWallet();

    final rejected = await receive(beefHex([(g, forged), (p, null)]), p.id);
    expect(rejected.success, isFalse, reason: 'a proof our own header contradicts was accepted');
    expect(rejected.error, contains('failed merkle proof validation'));
    await barrier();
    expect(await utxosOf(p.id), isEmpty);

    // A later header notification must not resurrect it: the evidence is
    // wrong, not merely early.
    await sendHeaders([RegtestMiner.mine(parent: a3, seed: '68mz-A4')], 4, 4);
    await barrier();
    expect(await utxosOf(p.id), isEmpty, reason: 'a contradicted BEEF was retried and credited the wallet');
  });

  test('68mz: no confirmation rests on a proof we could not check', () async {
    await sendHeaders([a1, a2], 1, 2);
    await createTheWallet();

    final tooEarly = await receive(beefHex([(g, gBump), (p, null)]), p.id);
    expect(tooEarly.success, isFalse);
    await barrier();

    final confirmations = [
      for (final event in await system.eventStore.getEvents('BitcoinWallet_$walletId'))
        if (event is domain.TransactionConfirmedEvent) event.txid,
    ];
    expect(confirmations, isEmpty, reason: 'a retained, unchecked proof confirmed something');
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
    {Duration timeout = const Duration(seconds: 15)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!await condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for: $what');
    }
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}

/// ARC that knows no transaction at all: nothing here is settled by a status
/// string.
class _FakeArc extends ArcService {
  _FakeArc() : super(baseUrl: 'fake://arc');

  @override
  Future<ArcTransactionResponse> getTransaction(String txid) async {
    throw ArcException('Failed to get transaction: {"status":404}');
  }
}
