/// Bead libspiffy-73bj: a merkle proof confirms a transaction the wallet
/// RECEIVED, not only one it sent.
///
/// A counterparty hands us a payment P before it is mined, so the wallet
/// holds it unproven: the transaction row is pending and its output is a
/// pending UTXO. Later the proof reaches us — the counterparty spends P's
/// change and hands us the BEEF of that spend with P inside it carrying its
/// BUMP, or simply re-delivers P now that it is mined. That BUMP, walked to
/// the merkle root of the header we hold, is the same authority that settles
/// our own payments (bead libspiffy-fggl).
///
/// It settled nothing. `ConfirmTransactionCommand(onlyIfRecorded: true)`
/// matched only the records `RecordOutgoingTransactionCommand` journals, so
/// a received transaction was never confirmed in the write model: the
/// aggregate journaled nothing, the proven output stayed pending and
/// unspendable, and whatever the read model showed did not survive a rebuild
/// from the journal — the divergence V-56 was filed for, in the other
/// direction.
///
/// Confirming a received transaction is only half of confirming an outgoing
/// one: it creates UTXOs and spends none of ours, so its pending outputs
/// become spendable and no input is spent.
///
/// End to end through LibSpiffyActorSystem on regtest with real-PoW headers.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:dactor/dactor.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:eventador/eventador.dart';
import 'package:isar/isar.dart';
import 'package:libspiffy/libspiffy.dart';
import 'package:libspiffy/src/actors/spv_messages.dart' show BlockHeadersReceivedMessage;
import 'package:libspiffy/src/core/wallet_events.dart';
import 'package:libspiffy/src/spv/network_params.dart';
import 'package:spiffynode/spiffy_node.dart';
import 'package:test/test.dart';

import '../spv/regtest_chain_builder.dart';
import 'isar_test_helper.dart';
import 'p2p_test_helpers.dart';

void main() {
  final genesis = NetworkParams.regtest.genesisHeader;

  final counterpartyKey = dartsv.SVPrivateKey.fromHex('7d' * 32, dartsv.NetworkType.TEST);
  final counterpartyLock =
      dartsv.P2PKHLockBuilder.fromAddress(counterpartyKey.publicKey.toAddress(dartsv.NetworkType.TEST));
  final ourLock = dartsv.P2PKHLockBuilder.fromAddress(dartsv.Address(kTestRootAddress));

  dartsv.DefaultTransactionSigner signer() => dartsv.DefaultTransactionSigner(
      dartsv.SighashType.SIGHASH_ALL.value | dartsv.SighashType.SIGHASH_FORKID.value, counterpartyKey);

  /// G: a mined transaction of the counterparty's; nothing to do with us.
  final g = _rawTransaction(
    prevTxid: Uint8List.fromList(List<int>.generate(32, (i) => 0x40 + i)),
    outputs: [(300000, Uint8List.fromList(hex.decode(counterpartyLock.getScriptPubkey().toHex())))],
  );

  /// P: the counterparty pays us 200,000 satoshis from G:0 and keeps 99,000
  /// as change. This is the transaction we receive unproven.
  final p = (dartsv.TransactionBuilder()
        ..spendFromOutpointWithSigner(
          signer(),
          dartsv.TransactionOutpoint(g.id, 0, g.outputs[0].satoshis, g.outputs[0].script),
          dartsv.TransactionInput.MAX_SEQ_NUMBER,
          dartsv.P2PKHUnlockBuilder(counterpartyKey.publicKey),
        )
        ..spendToLockBuilder(ourLock, BigInt.from(200000))
        ..spendToLockBuilder(counterpartyLock, BigInt.from(99000))
        ..withOption(dartsv.TransactionOption.DISABLE_DUST_OUTPUTS))
      .build(false);

  /// B: the counterparty spends P's change (P:1) and pays us again. Its BEEF
  /// carries P as a proven ancestor — that is how P's proof reaches us.
  final b = (dartsv.TransactionBuilder()
        ..spendFromOutpointWithSigner(
          signer(),
          dartsv.TransactionOutpoint(p.id, 1, p.outputs[1].satoshis, p.outputs[1].script),
          dartsv.TransactionInput.MAX_SEQ_NUMBER,
          dartsv.P2PKHUnlockBuilder(counterpartyKey.publicKey),
        )
        ..spendToLockBuilder(ourLock, BigInt.from(50000))
        ..spendToLockBuilder(counterpartyLock, BigInt.from(48000))
        ..withOption(dartsv.TransactionOption.DISABLE_DUST_OUTPUTS))
      .build(false);

  Uint8List internal(String displayTxid) => Uint8List.fromList(hex.decode(displayTxid).reversed.toList());

  BUMP bumpFor(String displayTxid, int blockHeight, int seed) => BUMP.fromMerklePath(
        blockHeight: blockHeight,
        txid: internal(displayTxid),
        index: 0,
        siblings: [Uint8List.fromList(List<int>.generate(32, (i) => (i * seed + seed) & 0xff))],
      );

  Hash rootOf(BUMP bump, String displayTxid) => Hash.fromBytes(bump.computeMerkleRoot(internal(displayTxid)));

  final gBump = bumpFor(g.id, 2, 11);
  final pBump = bumpFor(p.id, 4, 5);
  final a1 = RegtestMiner.mine(parent: genesis, seed: '73bj-A1');
  final a2 = RegtestMiner.mine(parent: a1, merkleRoot: rootOf(gBump, g.id));
  final a3 = RegtestMiner.mine(parent: a2, seed: '73bj-A3');
  final a4 = RegtestMiner.mine(parent: a3, merkleRoot: rootOf(pBump, p.id));

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

  /// P without its proof: G proven, P unproven, P the subject.
  String unprovenP() => beefHex([(g, gBump), (p, null)]);

  /// P with its proof, P the subject: the counterparty re-delivers it mined.
  String provenP() => beefHex([(g, gBump), (p, pBump)]);

  /// B, the later payment, with P inside it as a proven ancestor.
  String provenPUnderB() => beefHex([(g, gBump), (p, pBump), (b, null)]);

  late Directory dir;
  late Isar isar;
  late LibSpiffyActorSystem libspiffy;
  late LocalActorSystem actorSystem;
  late String walletId;
  var receivers = 0;

  setUpAll(() async {
    await ensureIsarInitialized();
  });

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('imported_proof_');
    actorSystem = LocalActorSystem(ActorSystemConfig());
    isar = await Isar.open(
      LibSpiffySchemas.allSchemas,
      directory: dir.path,
      name: 'imported_proof_${DateTime.now().microsecondsSinceEpoch}',
    );
    libspiffy = LibSpiffyActorSystem();
    await libspiffy.initialize(
      actorSystem: actorSystem,
      isar: isar,
      dataDirectory: dir.path,
      networkType: 'regtest',
      enableP2P: false,
      arcService: _SilentArc(),
    );
    walletId = 'imported-proof-${DateTime.now().microsecondsSinceEpoch}';
    await createWallet(
      walletManager: libspiffy.walletManager,
      actorSystem: actorSystem,
      walletId: walletId,
      walletName: 'Imported',
      xpriv: kTestXpriv,
    );
    await _until(() async => await libspiffy.walletStorage.isWalletAddress(walletId, kTestRootAddress),
        'root address projected');
    libspiffy.headerSyncActor.tell(
        BlockHeadersReceivedMessage(peerId: 'peer', headers: [a1, a2, a3, a4], startHeight: 1) as dynamic);
    await _until(() async => libspiffy.headerChain.bestHeight == 4, 'tip at 4');
  });

  tearDown(() async {
    try {
      await libspiffy.shutdown();
    } catch (_) {}
    try {
      await isar.close(deleteFromDisk: true);
    } catch (_) {}
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  });

  ReadModelStorage storage() => libspiffy.walletStorage;
  Future<List<Event>> journal() => libspiffy.eventStore.getEvents('BitcoinWallet_$walletId');

  Future<List<TransactionConfirmedEvent>> confirmations(String txid) async => [
        for (final e in await journal())
          if (e is TransactionConfirmedEvent && e.txid == txid) e,
      ];

  Future<BitcoinUtxo?> utxo(ReadModelStorage from, String txid, int vout) async {
    for (final u in await from.getUTXOs(walletId, includeSpent: true)) {
      if (u.txid == txid && u.vout == vout) return u;
    }
    return null;
  }

  /// Hands [beefHex] to SPVActor as a receive of [subject] and waits for its
  /// verdict.
  Future<void> deliver(String beefHex, String subject) async {
    final done = Completer<SPVValidationResult>();
    final receiver =
        await actorSystem.spawn('spv-receiver-${receivers++}', () => TestReceiverActor<SPVValidationResult>(done));
    libspiffy.spvActor.tell(
      ReceiveTransactionMessage(
        transactionId: subject,
        beef: BEEF.parse(Uint8List.fromList(hex.decode(beefHex))),
        fromCounterparty: 'counterparty',
        targetWalletId: walletId,
      ),
      sender: receiver,
    );
    final result = await done.future.timeout(const Duration(seconds: 15));
    expect(result.isValid, isTrue, reason: result.validationError);
  }

  /// Waits until the wallet aggregate has handled every command sent so far
  /// and the projection has applied their events: a command sent now lands
  /// behind them in the same mailbox. Needed before asserting that something
  /// was NOT journaled — the commands of a receive are told to the aggregate
  /// before the SPV verdict reaches us.
  Future<void> barrier() async {
    final address = await generateAddress(
      walletManager: libspiffy.walletManager,
      actorSystem: actorSystem,
      walletId: walletId,
    );
    await _until(() async => await storage().getAddressMetadata(walletId, address) != null,
        'the wallet and its projection caught up');
  }

  /// A read model rebuilt from the wallet's journal alone (the headers are
  /// copied over: they are synced, not journaled).
  Future<InMemoryWalletStorage> rebuildFromJournal() async {
    final fresh = InMemoryWalletStorage();
    for (var h = 1; h <= libspiffy.headerChain.bestHeight; h++) {
      final header = await storage().getBlockHeaderByHeight(h);
      if (header != null) await fresh.storeBlockHeader(header, h);
    }
    final projection = WalletProjection(
      projectionId: '73bj-rebuild-${DateTime.now().microsecondsSinceEpoch}',
      eventStore: libspiffy.eventStore,
      storage: fresh,
    );
    for (final event in await journal()) {
      await projection.handle(event);
    }
    return fresh;
  }

  /// P received unproven: pending row, pending output, nothing confirmed.
  Future<void> receivedUnproven() async {
    await deliver(unprovenP(), p.id);
    // Both rows, not one: the output row and the transaction row are written
    // from two different journal events (UTXOReceived, TransactionImported),
    // and nothing orders them for an observer. Waiting on the output alone
    // and then asserting the transaction exists raced under full-suite load.
    await _until(
        () async =>
            (await utxo(storage(), p.id, 0))?.status == UTXOStatus.pending &&
            await storage().getTransaction(p.id, walletId: walletId) != null,
        'P:0 received, pending without a proof, and P recorded');
    expect((await storage().getTransaction(p.id, walletId: walletId))!.status, TransactionStatus.pending);
    await barrier();
    expect(await confirmations(p.id), isEmpty);
  }

  test('73bj (1): a BUMP for a received transaction, carried as an ancestor of a later payment, '
      'confirms it in the journal', () async {
    await receivedUnproven();

    await deliver(provenPUnderB(), b.id);
    await _until(() async => (await confirmations(p.id)).isNotEmpty,
        'the wallet journals the confirmation of the payment it received');

    // The confirmation carries the proof, at the height the header we hold
    // is at.
    final confirmed = (await confirmations(p.id)).single;
    expect((confirmed.blockHeight, confirmed.bumpHex), (4, pBump.toHex()));
    expect(confirmed.blockHash, a4.blockHash().toString());

    // Received funds, not a spend: nothing of ours is spent by confirming it.
    expect((await journal()).whereType<UTXOSpentEvent>(), isEmpty,
        reason: 'confirming a transaction we received spent one of our inputs');

    // The proven output is spendable now; B, which nothing proves, is not.
    await _until(() async => (await utxo(storage(), p.id, 0))?.status == UTXOStatus.available,
        'the proven output of the received payment becomes spendable');
    expect((await utxo(storage(), b.id, 0))!.status, UTXOStatus.pending,
        reason: 'a proven ancestor does not mine the transaction that spends it');

    // The read model agrees.
    final row = await storage().getTransaction(p.id, walletId: walletId);
    expect((row?.status, row?.blockHeight), (TransactionStatus.confirmed, 4));

    // The counterparty's own funding transaction is none of our business.
    expect(await confirmations(g.id), isEmpty,
        reason: 'a proof for a counterparty transaction wrote to the wallet journal');

    // The journal is the source of truth: the confirmation survives a rebuild.
    final rebuilt = await rebuildFromJournal();
    final rebuiltRow = await rebuilt.getTransaction(p.id, walletId: walletId);
    expect((rebuiltRow?.status, rebuiltRow?.blockHeight), (TransactionStatus.confirmed, 4),
        reason: 'a read model rebuilt from the journal lost the confirmation of a received transaction');
    expect((await utxo(rebuilt, p.id, 0))!.status, UTXOStatus.available,
        reason: 'a rebuilt read model lost that the received output is spendable');
    final rebuiltProof = await rebuilt.getMerkleProof(p.id);
    expect((rebuiltProof?.status, rebuiltProof?.blockHeight), (MerkleProofStatus.verified, 4),
        reason: 'the proof that confirmed the received transaction is not in the journal');
  });

  test('73bj (2): the same proof delivered twice confirms once', () async {
    await receivedUnproven();

    await deliver(provenPUnderB(), b.id);
    await _until(() async => (await confirmations(p.id)).isNotEmpty, 'confirmed once');
    await deliver(provenPUnderB(), b.id);
    await barrier();

    expect((await confirmations(p.id)).length, 1, reason: 'a redelivered BEEF confirmed the receipt twice');
    expect((await utxo(storage(), p.id, 0))!.status, UTXOStatus.available);
  });

  test('73bj (3): the counterparty re-delivering the received transaction with its proof confirms it '
      'in the journal, not only in the read model', () async {
    await receivedUnproven();

    await deliver(provenP(), p.id);
    await _until(() async => (await confirmations(p.id)).isNotEmpty,
        'the wallet journals the confirmation of the re-delivered payment');
    await _until(() async => (await utxo(storage(), p.id, 0))?.status == UTXOStatus.available,
        'the proven output becomes spendable');

    final rebuilt = await rebuildFromJournal();
    final rebuiltRow = await rebuilt.getTransaction(p.id, walletId: walletId);
    expect((rebuiltRow?.status, rebuiltRow?.blockHeight), (TransactionStatus.confirmed, 4));
    expect((await utxo(rebuilt, p.id, 0))!.status, UTXOStatus.available,
        reason: 'a rebuilt read model lost that the received output is spendable');
  });
}

/// A raw transaction with one input spending [prevTxid]:0 (wire order) with
/// an OP_TRUE scriptSig.
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

/// ARC that knows no transaction at all: every confirmation here comes from
/// a BEEF a counterparty handed us.
class _SilentArc extends ArcService {
  _SilentArc() : super(baseUrl: 'fake://arc');

  @override
  Future<ArcTransactionResponse> getTransaction(String txid) async {
    throw ArcException('Failed to get transaction: {"status":404}');
  }
}
