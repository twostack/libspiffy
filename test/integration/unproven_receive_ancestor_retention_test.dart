/// zsh (libspiffy-zsh): the ancestors of a received, unproven transaction
/// were not retained.
///
/// A counterparty pays wallet A with a BRC-62 BEEF for a payment P that is
/// not mined yet; the BEEF carries P's parent G with G's BUMP. SPVActor
/// validated G's proof against A's headers, but only P (rawHex, no proof)
/// reached the journal and the read model. When A spent P's output before P
/// was mined, AncestorChainService walked P -> G, found no G and the payment
/// failed: G and its BUMP cannot be fetched from anywhere (no block
/// scanning, no indexer; ARC only knows transactions it mined or we
/// broadcast).
///
/// End to end through LibSpiffyActorSystem on regtest with real-PoW headers
/// and a fake ARC: receive through WalletCoordinatorActor
/// (ValidateBEEFCommand), P's output made spendable by ARC reporting P
/// SEEN_ON_NETWORK, payment through PayInvoiceCommand, and the outgoing BEEF
/// validated by a separate SPVActor that only shares the headers. Then the
/// same after a restart onto a read model rebuilt from the journal, and the
/// ARC-mined P no longer needing G.
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
import 'package:libspiffy/src/services/ancestor_chain_service.dart';
import 'package:libspiffy/src/spv/network_params.dart';
import 'package:spiffynode/spiffy_node.dart';
import 'package:test/test.dart';

import '../spv/regtest_chain_builder.dart';
import 'isar_test_helper.dart';
import 'p2p_test_helpers.dart';
import 'receive_helpers.dart';

void main() {
  final genesis = NetworkParams.regtest.genesisHeader;

  // The counterparty's key; G pays it, P spends G:0 with it.
  final counterpartyKey = dartsv.SVPrivateKey.fromHex('7a' * 32, dartsv.NetworkType.TEST);
  final counterpartyLock =
      dartsv.P2PKHLockBuilder.fromAddress(counterpartyKey.publicKey.toAddress(dartsv.NetworkType.TEST));

  /// G: a mined transaction of the counterparty (its own funding is not in
  /// any BEEF; G is proven by its BUMP).
  final g = _rawTransaction(
    prevTxid: Uint8List.fromList(List<int>.generate(32, (i) => 0xa0 + i)),
    outputs: [(300000, Uint8List.fromList(hex.decode(counterpartyLock.getScriptPubkey().toHex())))],
  );

  /// P: the counterparty pays wallet A's root address from G:0, unmined.
  dartsv.Transaction buildP() {
    final out = g.outputs[0];
    final builder = dartsv.TransactionBuilder()
      ..spendFromOutpointWithSigner(
        dartsv.DefaultTransactionSigner(
            dartsv.SighashType.SIGHASH_ALL.value | dartsv.SighashType.SIGHASH_FORKID.value, counterpartyKey),
        dartsv.TransactionOutpoint(g.id, 0, out.satoshis, out.script),
        dartsv.TransactionInput.MAX_SEQ_NUMBER,
        dartsv.P2PKHUnlockBuilder(counterpartyKey.publicKey),
      )
      ..spendToLockBuilder(dartsv.P2PKHLockBuilder.fromAddress(dartsv.Address(kTestRootAddress)), BigInt.from(200000))
      ..spendToLockBuilder(counterpartyLock, BigInt.from(99000))
      ..withOption(dartsv.TransactionOption.DISABLE_DUST_OUTPUTS);
    return builder.build(false);
  }

  final p = buildP();

  /// G's BUMP in a two-transaction block at height 2 and the block's root.
  final gInternal = Uint8List.fromList(hex.decode(g.id).reversed.toList());
  final gBump = BUMP.fromMerklePath(
    blockHeight: 2,
    txid: gInternal,
    index: 1,
    siblings: [Uint8List.fromList(List<int>.generate(32, (i) => (i * 13 + 5) & 0xff))],
  );
  final a1 = RegtestMiner.mine(parent: genesis, seed: 'zsh-A1');
  final a2 = RegtestMiner.mine(parent: a1, merkleRoot: Hash.fromBytes(gBump.computeMerkleRoot(gInternal)));
  final a3 = RegtestMiner.mine(parent: a2, seed: 'zsh-A3');

  /// P mined later at height 4 (index 0 of a two-transaction block).
  final pInternal = Uint8List.fromList(hex.decode(p.id).reversed.toList());
  final pBump = BUMP.fromMerklePath(
    blockHeight: 4,
    txid: pInternal,
    index: 0,
    siblings: [Uint8List.fromList(List<int>.generate(32, (i) => (i * 3 + 1) & 0xff))],
  );
  final a4 = RegtestMiner.mine(parent: a3, merkleRoot: Hash.fromBytes(pBump.computeMerkleRoot(pInternal)));

  /// What the counterparty hands wallet A: G (with its BUMP), then P.
  String receivedBeefHex() => hex.encode(BEEF
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
  const walletId = 'zsh-wallet-a';
  const recipient = 'mfWxJ45yp2SFn7UciZyNpvDKrzbhyfKrY8';

  setUpAll(() async {
    await ensureIsarInitialized();
  });

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('zsh_ancestors_');
    isar = await Isar.open(
      LibSpiffySchemas.allSchemas,
      directory: dir.path,
      name: 'zsh_${DateTime.now().microsecondsSinceEpoch}',
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

  Future<LibSpiffyActorSystem> start(ReadModelStorage? readModel) async {
    final system = LibSpiffyActorSystem();
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
    systems.add(system);
    return system;
  }

  Future<void> sendHeaders(LibSpiffyActorSystem system, List<BlockHeader> headers, int startHeight, int tip) async {
    system.headerSyncActor.tell(BlockHeadersReceivedMessage(
      peerId: 'peer',
      headers: headers,
      startHeight: startHeight,
    ) as dynamic);
    await _until(() async => system.headerChain.bestHeight == tip, 'tip at $tip');
  }

  Future<BitcoinUtxo?> receivedUtxo(ReadModelStorage storage) async {
    for (final u in await storage.getUTXOs(walletId, includeSpent: true)) {
      if (u.txid == p.id && u.vout == 0) return u;
    }
    return null;
  }

  /// Wallet A with headers to height 3, holding P's output as received from
  /// the counterparty and made spendable by ARC seeing P on the network.
  Future<LibSpiffyActorSystem> receiveUnprovenPayment() async {
    final system = await start(InMemoryWalletStorage());
    await sendHeaders(system, [a1, a2, a3], 1, 3);
    await createWallet(
      walletManager: system.walletManager,
      actorSystem: system.actorSystem,
      walletId: walletId,
      walletName: 'A',
      xpriv: kTestXpriv,
    );
    await _until(() async => await system.walletStorage.isWalletAddress(walletId, kTestRootAddress),
        'root address projected');

    final result = await receiveBeef(system, walletId, receivedBeefHex(), p.id, fromCounterparty: 'counterparty');
    expect(result.success, isTrue, reason: result.error);
    expect((await receivedUtxo(system.walletStorage))?.status, UTXOStatus.pending);

    arc.responses[p.id] = ArcTransactionResponse.fromJson({
      'timestamp': '2026-09-14T08:00:00Z',
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
  Future<SPVValidationResult> validateOnFreshReceiver(Uint8List beefBytes, String txid,
      {List<BlockHeader>? headers}) async {
    final storage = InMemoryWalletStorage();
    await storage.storeBlockHeader(genesis, 0);
    final chain = headers ?? [a1, a2, a3];
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

  List<(String, bool)> txidsAndProofFlags(BEEF beef) => [
        for (var i = 0; i < beef.txs.length; i++) (hex.encode(beef.calculateTxid(beef.txs[i])), beef.hasMerkle[i]),
      ];

  /// A read model rebuilt from the journal: fresh storage with the header
  /// chain (synced, not journaled) and every journal event replayed.
  Future<InMemoryWalletStorage> rebuildFromJournal(LibSpiffyActorSystem system) async {
    final fresh = InMemoryWalletStorage();
    for (var h = 0; h <= system.headerChain.bestHeight; h++) {
      final header = await system.walletStorage.getBlockHeaderByHeight(h);
      if (header != null) await fresh.storeBlockHeader(header, h);
    }
    final projection = WalletProjection(
      projectionId: 'rebuild-${DateTime.now().microsecondsSinceEpoch}',
      eventStore: system.eventStore,
      storage: fresh,
    );
    final List<Event> events = await system.eventStore.getEvents('BitcoinWallet_$walletId');
    for (final event in events) {
      await projection.handle(event);
    }
    return fresh;
  }

  test('zsh: spending an unproven received output sends a BEEF with P, its parent G and G\'s BUMP', () async {
    final system = await receiveUnprovenPayment();

    final payment = await pay(system, 'zsh-invoice-1');
    expect(payment.success, isTrue, reason: payment.error);

    final beef = BEEF.parse(payment.beefBytes);
    expect(txidsAndProofFlags(beef), [(g.id, true), (p.id, false), (payment.txid, false)],
        reason: 'parents first: G with its BUMP, then P, then the new transaction');
    expect(beef.bumps.map((b) => b.toHex()), [gBump.toHex()]);

    final validation = await validateOnFreshReceiver(payment.beefBytes, payment.txid);
    expect(validation.isValid, isTrue, reason: validation.validationError);

    // G is retained as SPV evidence, not as a wallet transaction.
    final storage = system.walletStorage;
    final history = await storage.getTransactionHistory(walletId);
    expect(history.map((t) => t.txid), isNot(contains(g.id)));
    expect(await storage.getTransaction(g.id, walletId: walletId), isNull);
    final proof = await storage.getMerkleProof(g.id);
    expect((proof?.status, proof?.blockHash), (MerkleProofStatus.verified, a2.blockHash().toString()));
  });

  test('zsh: after a restart onto a read model rebuilt from the journal the payment still builds a valid BEEF',
      () async {
    final first = await receiveUnprovenPayment();
    final rebuilt = await rebuildFromJournal(first);
    await first.shutdown();
    systems.remove(first);

    final second = await start(rebuilt);
    expect((await receivedUtxo(rebuilt))?.status, UTXOStatus.available);

    final payment = await pay(second, 'zsh-invoice-restart');
    expect(payment.success, isTrue, reason: payment.error);
    final beef = BEEF.parse(payment.beefBytes);
    expect(txidsAndProofFlags(beef), [(g.id, true), (p.id, false), (payment.txid, false)]);

    final validation = await validateOnFreshReceiver(payment.beefBytes, payment.txid);
    expect(validation.isValid, isTrue, reason: validation.validationError);

    // Replaying the journal again over the rebuilt model changes nothing
    // AncestorChainService relies on.
    final projection = WalletProjection(projectionId: 'replay-again', eventStore: second.eventStore, storage: rebuilt);
    for (final event in await second.eventStore.getEvents('BitcoinWallet_$walletId')) {
      await projection.handle(event);
    }
    expect((await rebuilt.getMerkleProofHistory(g.id)).map((r) => (r.merkleProof.single, r.status)),
        [(gBump.toHex(), MerkleProofStatus.verified)]);
    expect((await rebuilt.getTransactionHistory(walletId)).map((t) => t.txid), isNot(contains(g.id)));
  });

  test('zsh: once ARC reports P mined, the chain stops at P and G is no longer needed', () async {
    final system = await receiveUnprovenPayment();
    await sendHeaders(system, [a4], 4, 4);
    arc.responses[p.id] = ArcTransactionResponse.fromJson({
      'timestamp': '2026-09-14T09:00:00Z',
      'txid': p.id,
      'txStatus': 'MINED',
      'blockHash': a4.blockHash().toString(),
      'blockHeight': 4,
      'merklePath': pBump.toHex(),
    });
    system.arcActor.tell(CheckStoragePendingUTXOsMessage(triggerBlockHeight: 4));
    await _until(() async => (await system.walletStorage.getMerkleProof(p.id))?.status == MerkleProofStatus.verified,
        'P confirmed through ARC', timeout: const Duration(seconds: 12));

    final chain = await AncestorChainService(storage: system.walletStorage).collectAncestorChainForUtxos([p.id]);
    expect(chain.isValid, isTrue, reason: chain.error);
    expect(chain.ancestorTransactions.map((t) => t.txid), [p.id]);

    final payment = await pay(system, 'zsh-invoice-mined');
    expect(payment.success, isTrue, reason: payment.error);
    final beef = BEEF.parse(payment.beefBytes);
    expect(txidsAndProofFlags(beef), [(p.id, true), (payment.txid, false)]);
    final validation = await validateOnFreshReceiver(payment.beefBytes, payment.txid, headers: [a1, a2, a3, a4]);
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
class _FakeArc extends ArcService {
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
