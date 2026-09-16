/// Bead libspiffy-0lx (part 1): an output whose proven ancestor's block is
/// orphaned says so, and becomes spendable again when a fresh proof arrives.
///
/// We hold an output of P, a payment that is not mined yet. Spending it means
/// handing a counterparty a BEEF that walks back from P to a transaction with
/// a merkle proof — its ancestor G, proven in block 3. A reorganization takes
/// block 3 off the active chain: G's proof is kept (a reorganization can put
/// the block back) but no longer counts, and the walk now runs off the end of
/// what we store. The output is unspendable, and nothing said so: no block
/// scanning, no address monitoring, ARC is polled only for transactions we
/// broadcast, and the counterparty that gave us G is never asked again.
///
/// Now the wallet says it:
/// `ReadModelStorage.getOutputsAwaitingAncestorProof` lists the output and
/// the ancestor it waits on, SPVActor logs it, and — the one question the
/// model allows without scanning — ARC is asked, once per interval, whether
/// it has a proof for that ancestor. A proof ARC returns is used only after
/// it verifies against our own headers.
///
/// SPVActor runs against an in-memory read model with no projection: the
/// wallet manager is a recorder, so nothing but this actor moves.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:dactor/dactor.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:libspiffy/src/actors/spv_actor.dart';
import 'package:libspiffy/src/actors/spv_messages.dart' show BlockHeaderStoredMessage;
import 'package:libspiffy/src/actors/wallet_messages.dart';
import 'package:libspiffy/src/models/bitcoin_transaction.dart';
import 'package:libspiffy/src/models/bitcoin_utxo.dart';
import 'package:libspiffy/src/services/ancestor_chain_service.dart';
import 'package:libspiffy/src/spv/network_params.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';
import 'package:libspiffy/src/storage/read_model_storage.dart';
import 'package:libspiffy/src/utils/beef.dart';
import 'package:libspiffy/src/utils/bump.dart';
import 'package:spiffynode/spiffy_node.dart';
import 'package:test/test.dart';

import '../spv/regtest_chain_builder.dart';

void main() {
  const walletId = '0lx-wallet';
  final genesis = NetworkParams.regtest.genesisHeader;

  final bobKey = dartsv.SVPrivateKey.fromHex('11' * 32, dartsv.NetworkType.TEST);
  final bobLock = dartsv.P2PKHLockBuilder.fromAddress(bobKey.publicKey.toAddress(dartsv.NetworkType.TEST));
  final ourKey = dartsv.SVPrivateKey.fromHex('22' * 32, dartsv.NetworkType.TEST);
  final ourAddress = ourKey.publicKey.toAddress(dartsv.NetworkType.TEST);
  final ourLock = dartsv.P2PKHLockBuilder.fromAddress(ourAddress);

  dartsv.DefaultTransactionSigner bobSigner() => dartsv.DefaultTransactionSigner(
      dartsv.SighashType.SIGHASH_ALL.value | dartsv.SighashType.SIGHASH_FORKID.value, bobKey);

  /// G: Bob's mined coin, the proven ancestor.
  final g = _rawTransaction(
    prevTxid: Uint8List.fromList(List<int>.generate(32, (i) => 0x60 + i)),
    outputs: [(700000, Uint8List.fromList(hex.decode(bobLock.getScriptPubkey().toHex())))],
  );

  /// P: Bob spends G and pays us 200,000 satoshis. Not mined.
  final p = (dartsv.TransactionBuilder()
        ..spendFromOutpointWithSigner(
          bobSigner(),
          dartsv.TransactionOutpoint(g.id, 0, g.outputs[0].satoshis, g.outputs[0].script),
          dartsv.TransactionInput.MAX_SEQ_NUMBER,
          dartsv.P2PKHUnlockBuilder(bobKey.publicKey),
        )
        ..spendToLockBuilder(ourLock, BigInt.from(200000))
        ..spendToLockBuilder(bobLock, BigInt.from(490000))
        ..withOption(dartsv.TransactionOption.DISABLE_DUST_OUTPUTS))
      .build(false);

  Uint8List internalTxid(String displayTxid) => Uint8List.fromList(hex.decode(displayTxid).reversed.toList());

  BUMP bumpFor(String displayTxid, int blockHeight, int seed) => BUMP.fromMerklePath(
        blockHeight: blockHeight,
        txid: internalTxid(displayTxid),
        index: 0,
        siblings: [Uint8List.fromList(List<int>.generate(32, (i) => (i * seed + seed) & 0xff))],
      );

  Hash rootOf(BUMP bump, String displayTxid) => Hash.fromBytes(bump.computeMerkleRoot(internalTxid(displayTxid)));

  /// The branch we are on: G is in block A3.
  final gBumpA = bumpFor(g.id, 3, 13);
  final a1 = RegtestMiner.mine(parent: genesis, seed: '0lx-A1');
  final a2 = RegtestMiner.mine(parent: a1, seed: '0lx-A2');
  final a3 = RegtestMiner.mine(parent: a2, merkleRoot: rootOf(gBumpA, g.id));

  /// The branch that wins: G is mined again, in B3, under a different path.
  final gBumpB = bumpFor(g.id, 3, 37);
  final b3 = RegtestMiner.mine(parent: a2, merkleRoot: rootOf(gBumpB, g.id));

  late LocalActorSystem system;
  late InMemoryWalletStorage storage;
  late _Recorder walletManager;
  late _FakeArcActor arc;
  late ActorRef spv;
  late ActorRef arcRef;
  late AncestorChainService chains;

  /// Builds the BEEF that spending P:0 needs, the way PaymentCoordinatorActor
  /// would: the real test of whether the output can be spent.
  Future<AncestorChainResult> canSpendP() => chains.collectAncestorChainForUtxos([p.id]);

  setUp(() async {
    system = LocalActorSystem(ActorSystemConfig());
    storage = InMemoryWalletStorage();
    chains = AncestorChainService(storage: storage);
    final tag = DateTime.now().microsecondsSinceEpoch;

    // Our branch, and the wallet that holds P's output.
    await storage.storeWallet(walletId, 'wallet');
    for (final (header, height) in [(a1, 1), (a2, 2), (a3, 3)]) {
      await storage.storeBlockHeader(header, height);
    }
    await storage.storeAncestorTransaction(g.id, g.serialize());
    await storage.storeMerkleProof(
      g.id,
      MerkleProof(
        txid: g.id,
        blockHash: a3.blockHash().toString(),
        blockHeight: 3,
        position: 0,
        merkleProof: [gBumpA.toHex()],
        status: MerkleProofStatus.verified,
      ),
    );
    await storage.storeTransaction(
      walletId,
      BitcoinTransaction(
        walletId: walletId,
        txid: p.id,
        rawHex: p.serialize(),
        status: TransactionStatus.pending,
        inputValue: BigInt.from(700000),
        outputValue: BigInt.from(690000),
        fee: BigInt.from(10000),
        receivingAddresses: [ourAddress.toBase58()],
        sendingAddresses: const [],
        netAmount: BigInt.from(200000),
        createdAt: DateTime.utc(2026, 9, 1),
        updatedAt: DateTime.utc(2026, 9, 1),
        lockTime: 0,
        version: 1,
      ),
    );
    await storage.upsertUTXO(
      walletId,
      BitcoinUtxo(
        txid: p.id,
        vout: 0,
        value: dartsv.Coin.ofSat(BigInt.from(200000)),
        scriptPubKey: p.outputs[0].script.toHex(),
        address: ourAddress.toBase58(),
        status: UTXOStatus.available,
        createdAt: DateTime.utc(2026, 9, 1),
        updatedAt: DateTime.utc(2026, 9, 1),
      ),
    );

    walletManager = _Recorder();
    arc = _FakeArcActor();
    final walletManagerRef = await system.spawn('wm-$tag', () => walletManager);
    arcRef = await system.spawn('arc-$tag', () => arc);
    spv = await system.spawn(
        'spv-$tag',
        () => SPVActor(
              walletManager: walletManagerRef,
              invoiceCoordinator: walletManagerRef,
              storage: storage,
              arcActor: arcRef,
              // Every header notification sweeps, and ARC may be asked about
              // the same ancestor again: the test drives the clock.
              ancestorReproofInterval: Duration.zero,
            ));
  });

  tearDown(() => system.shutdown());

  /// Waits until SPVActor has handled everything told to it so far (its
  /// mailbox is sequential, and the reply below is sent from the same
  /// handler queue).
  Future<void> settle() async {
    final done = Completer<void>();
    final barrier = await system.spawn('barrier-${DateTime.now().microsecondsSinceEpoch}', () => _Barrier(done));
    spv.tell(
      ReceiveTransactionMessage(
        transactionId: 'barrier',
        beef: BEEF.create(
            bumps: const [],
            txs: [Uint8List.fromList(hex.decode(g.serialize()))],
            hasMerkle: [false],
            bumpIndex: const []),
        fromCounterparty: 'barrier',
      ),
      sender: barrier,
    );
    await done.future.timeout(const Duration(seconds: 10));
  }

  test('0lx: an output whose ancestor\'s block is orphaned is not spendable, says which proof it '
      'waits for, and becomes spendable again when a fresh proof arrives', () async {
    // Before the reorganization the output can be put into a BEEF.
    expect((await canSpendP()).isValid, isTrue, reason: 'the output should be spendable to begin with');
    expect(await storage.getOutputsAwaitingAncestorProof(walletId), isEmpty);

    // Block 3 is replaced. ARC knows nothing yet, as it will not for a
    // transaction we did not broadcast.
    await storage.markHeaderAsOrphaned(a3.blockHash().toString());
    await storage.storeBlockHeader(b3, 3);
    spv.tell(HeaderChainReorganizedMessage(
      forkHeight: 2,
      orphanedBlockHashes: [a3.blockHash().toString()],
      newTipHeight: 3,
    ));
    await settle();

    // The ancestor's proof is kept, but no longer counts...
    expect(await storage.getMerkleProof(g.id), isNull, reason: 'the orphaned proof is still current');
    expect([for (final row in await storage.getMerkleProofHistory(g.id)) row.status],
        contains(MerkleProofStatus.orphaned),
        reason: 'the proof row must be kept: a reorganization can put its block back');

    // ...so the output cannot be spent, and the wallet says exactly why.
    final spend = await canSpendP();
    expect(spend.isValid, isFalse, reason: 'the BEEF was built from an orphaned proof');
    final awaiting = await storage.getOutputsAwaitingAncestorProof(walletId);
    expect(awaiting.map((o) => o.outpoint), ['${p.id}:0'],
        reason: 'the wallet holds an unspendable output and says nothing about it');
    expect(awaiting.single.ancestors.map((a) => (a.txid, a.lastProofStatus, a.blockHeight)),
        [(g.id, MerkleProofStatus.orphaned, 3)]);

    expect(arc.asked, [g.id], reason: 'ARC was never asked whether it has a fresh proof for the ancestor');

    // A fresh proof turns up: the ancestor was mined again in the block that
    // won, and ARC now answers for it. (A counterparty re-sending the BEEF
    // is the other way, and goes through the receive path.)
    arc.proofOf[g.id] = (gBumpB, 3, b3.blockHash().toString());
    spv.tell(BlockHeaderStoredMessage(header: b3, height: 3));
    await settle();

    final restored = await storage.getMerkleProof(g.id);
    expect((restored?.status, restored?.blockHeight, restored?.merkleProof.single),
        (MerkleProofStatus.verified, 3, gBumpB.toHex()),
        reason: 'the fresh proof was not stored');
    expect((await canSpendP()).isValid, isTrue,
        reason: 'the output is still unspendable after a fresh proof for its ancestor arrived');
    expect(await storage.getOutputsAwaitingAncestorProof(walletId), isEmpty,
        reason: 'the output is still reported as waiting for a proof');
  });

  test('0lx: a proof ARC offers that our own headers contradict is not used', () async {
    await storage.markHeaderAsOrphaned(a3.blockHash().toString());
    await storage.storeBlockHeader(b3, 3);
    // ARC offers the path for the block that lost: it does not match B3.
    arc.proofOf[g.id] = (gBumpA, 3, a3.blockHash().toString());

    spv.tell(HeaderChainReorganizedMessage(
      forkHeight: 2,
      orphanedBlockHashes: [a3.blockHash().toString()],
      newTipHeight: 3,
    ));
    await settle();

    expect(await storage.getMerkleProof(g.id), isNull,
        reason: 'a proof our own header contradicts became the current proof');
    expect((await canSpendP()).isValid, isFalse);
    expect(await storage.getOutputsAwaitingAncestorProof(walletId), hasLength(1));
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

/// Records everything told to it.
class _Recorder extends Actor {
  final List<Object?> messages = [];

  @override
  Future<void> onMessage(dynamic message) async {
    messages.add(message);
  }
}

/// ARC that answers `RetrieveMerkleProofMessage` from [proofOf] — the BUMP,
/// its height and its block hash — and records what it was asked about.
class _FakeArcActor extends Actor {
  final List<String> asked = [];
  final Map<String, (BUMP, int, String)> proofOf = {};

  @override
  Future<void> onMessage(dynamic message) async {
    if (message is! RetrieveMerkleProofMessage) return;
    asked.add(message.txid);
    final entry = proofOf[message.txid];
    if (entry == null) {
      // ignore: invalid_use_of_internal_member
      context.sender?.tell(MerkleProofMessage(
        txid: message.txid,
        success: false,
        error: 'Transaction not found',
      ));
      return;
    }
    final (bump, height, blockHash) = entry;
    // ignore: invalid_use_of_internal_member
    context.sender?.tell(MerkleProofMessage(
      txid: message.txid,
      success: true,
      merkleProof: {
        'txid': message.txid,
        'blockHeight': height,
        'merklePath': [bump.toHex()],
        'blockHash': blockHash,
        'position': 0,
        // ARCActor sets this from its own check against the stored headers;
        // both fixtures here really are paths for the block they name.
        'headerVerified': true,
      },
    ));
  }
}

/// Replies to the message that follows the work under test, so the test can
/// wait for the actor's mailbox to drain.
class _Barrier extends Actor {
  final Completer<void> done;

  _Barrier(this.done);

  @override
  Future<void> onMessage(dynamic message) async {
    if (!done.isCompleted) done.complete();
  }
}
