/// Bead libspiffy-vfai: a receive parked for a block header survives a
/// restart.
///
/// V-57 (bead libspiffy-68mz) keeps the *evidence* of a BEEF whose merkle
/// proof names a block our headers have not reached: its transactions go to
/// the ancestor store and its BUMPs are filed as `pendingHeader` proofs. The
/// waiting RECEIVE, though, sat in an in-memory queue. So after a restart the
/// header could arrive, the proof could verify — and the subject's new
/// outputs were never credited, because nothing replayed the receive. No
/// counterparty can be asked to send the BEEF again: there is no block
/// scanning, no indexer, and ARC knows only what we broadcast ourselves.
///
/// The parked receive is now a durable row (`PendingReceive`), read back at
/// start and on every header notification, and resolved once a verdict more
/// headers cannot change is reached.
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
import 'package:libspiffy/src/spv/network_params.dart';
import 'package:spiffynode/spiffy_node.dart';
import 'package:test/test.dart';

import '../spv/regtest_chain_builder.dart';
import 'isar_test_helper.dart';
import 'p2p_test_helpers.dart';

void main() {
  final genesis = NetworkParams.regtest.genesisHeader;

  // Bob holds a mined coin and pays us from it.
  final bobKey = dartsv.SVPrivateKey.fromHex('7c' * 32, dartsv.NetworkType.TEST);
  final bobLock = dartsv.P2PKHLockBuilder.fromAddress(bobKey.publicKey.toAddress(dartsv.NetworkType.TEST));
  final ourLock = dartsv.P2PKHLockBuilder.fromAddress(dartsv.Address(kTestRootAddress));

  dartsv.DefaultTransactionSigner bobSigner() => dartsv.DefaultTransactionSigner(
      dartsv.SighashType.SIGHASH_ALL.value | dartsv.SighashType.SIGHASH_FORKID.value, bobKey);

  /// G: Bob's mined coin, the ancestor whose proof we cannot check yet.
  final g = _rawTransaction(
    prevTxid: Uint8List.fromList(List<int>.generate(32, (i) => 0x90 + i)),
    outputs: [(500000, Uint8List.fromList(hex.decode(bobLock.getScriptPubkey().toHex())))],
  );

  Uint8List internalTxid(String displayTxid) => Uint8List.fromList(hex.decode(displayTxid).reversed.toList());

  BUMP bumpFor(String displayTxid, int blockHeight, int seed) => BUMP.fromMerklePath(
        blockHeight: blockHeight,
        txid: internalTxid(displayTxid),
        index: 0,
        siblings: [Uint8List.fromList(List<int>.generate(32, (i) => (i * seed + seed) & 0xff))],
      );

  Hash rootOf(BUMP bump, String displayTxid) => Hash.fromBytes(bump.computeMerkleRoot(internalTxid(displayTxid)));

  /// G is mined in block 3; the wallet's chain hears only of 1-2 until the
  /// test says otherwise.
  final gBump = bumpFor(g.id, 3, 29);
  final a1 = RegtestMiner.mine(parent: genesis, seed: 'vfai-A1');
  final a2 = RegtestMiner.mine(parent: a1, seed: 'vfai-A2');
  final a3 = RegtestMiner.mine(parent: a2, merkleRoot: rootOf(gBump, g.id));

  /// P: Bob spends G and pays us 120,000 satoshis. Unproven itself, so its
  /// ancestor's proof is what the receive rests on.
  final p = (dartsv.TransactionBuilder()
        ..spendFromOutpointWithSigner(
          bobSigner(),
          dartsv.TransactionOutpoint(g.id, 0, g.outputs[0].satoshis, g.outputs[0].script),
          dartsv.TransactionInput.MAX_SEQ_NUMBER,
          dartsv.P2PKHUnlockBuilder(bobKey.publicKey),
        )
        ..spendToLockBuilder(ourLock, BigInt.from(120000))
        ..spendToLockBuilder(bobLock, BigInt.from(370000))
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
  late LibSpiffyActorSystem system;
  late InMemoryWalletStorage readModel;
  late InMemorySecureStorage secureStorage;
  const walletId = 'vfai-wallet-a';

  setUpAll(() async {
    await ensureIsarInitialized();
  });

  /// One process: a LibSpiffyActorSystem over the Isar journal and read model
  /// the previous one left behind.
  Future<LibSpiffyActorSystem> boot() async {
    final booted = LibSpiffyActorSystem();
    await booted.initialize(
      actorSystem: LocalActorSystem(ActorSystemConfig()),
      isar: isar,
      readModelStorage: readModel,
      secureStorage: secureStorage,
      dataDirectory: dir.path,
      networkType: 'regtest',
      enableP2P: false,
      arcService: _FakeArc(),
    );
    return booted;
  }

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('vfai_parked_receive_');
    isar = await Isar.open(
      LibSpiffySchemas.allSchemas,
      directory: dir.path,
      name: 'vfai_${DateTime.now().microsecondsSinceEpoch}',
    );
    readModel = InMemoryWalletStorage();
    secureStorage = InMemorySecureStorage();
    system = await boot();
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
  /// and the projection has applied their events: a command sent now lands
  /// behind them in the same mailbox. Needed before asserting that something
  /// was NOT journaled.
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

  test('vfai: a receive parked for a block header is replayed after a restart, and the wallet is '
      'credited without the counterparty re-sending', () async {
    await sendHeaders([a1, a2], 1, 2);
    await createTheWallet();

    // Our chain stops at 2, G claims block 3: nothing can be checked yet.
    final tooEarly = await receive(beefHex([(g, gBump), (p, null)]), p.id);
    expect(tooEarly.success, isFalse, reason: 'an unverifiable proof must not credit the wallet');
    await barrier();
    expect(await utxosOf(p.id), isEmpty, reason: 'nothing is credited before a proof checks out');

    // The receive itself is retained, not only the BEEF's evidence.
    final parked = await readModel.getPendingReceive(walletId, p.id);
    expect(parked, isNotNull, reason: 'the parked receive is in memory only: a restart loses the retry');
    expect((parked!.neededHeight, parked.isWaiting, parked.fromCounterparty), (3, true, 'bob'));

    // The process dies. Nothing but storage survives.
    await system.shutdown();
    system = await boot();

    // The header for block 3 arrives at the new process. Bob sends nothing.
    await sendHeaders([a3], 3, 3);

    await _until(() async => (await utxosOf(p.id)).isNotEmpty,
        'the parked receive is replayed after the restart and credits the wallet');
    final ours = (await utxosOf(p.id)).where((u) => u.satoshis == BigInt.from(120000)).toList();
    expect(ours.map((u) => u.status), [UTXOStatus.pending],
        reason: 'the subject is unmined, so its outputs are pending — a BEEF proves the funding history only');

    // The ancestor's proof is verified against the header we now hold, and
    // the parked row records that the receive is done: it is not replayed on
    // every later header.
    final proof = await readModel.getMerkleProof(g.id);
    expect((proof?.status, proof?.blockHeight), (MerkleProofStatus.verified, 3));
    final settled = await readModel.getPendingReceive(walletId, p.id);
    expect((settled?.isWaiting, settled?.resolution), (false, 'recorded'));
    expect(settled?.beefHex, parked.beefHex, reason: 'the BEEF a counterparty handed us is kept');
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('vfai: a parked receive is replayed once, and a second header notification does not '
      'credit the wallet again', () async {
    await sendHeaders([a1, a2], 1, 2);
    await createTheWallet();

    expect((await receive(beefHex([(g, gBump), (p, null)]), p.id)).success, isFalse);
    await barrier();

    await sendHeaders([a3], 3, 3);
    await _until(() async => (await utxosOf(p.id)).isNotEmpty, 'the retained receive credits the wallet');
    await barrier();

    final a4 = RegtestMiner.mine(parent: a3, seed: 'vfai-A4');
    await sendHeaders([a4], 4, 4);
    await barrier();

    final credited = await utxosOf(p.id);
    expect(credited.where((u) => u.satoshis == BigInt.from(120000)).length, 1,
        reason: 'the receive was replayed again after it had already been recorded');
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

/// ARC that knows no transaction at all: nothing here is settled by a status
/// string.
class _FakeArc extends ArcService {
  _FakeArc() : super(baseUrl: 'fake://arc');

  @override
  Future<ArcTransactionResponse> getTransaction(String txid) async {
    throw ArcException('Failed to get transaction: {"status":404}');
  }
}
