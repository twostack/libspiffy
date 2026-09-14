/// 3b0 (libspiffy-3b0) and zvj part 1 (libspiffy-zvj), end to end through
/// LibSpiffyActorSystem on regtest with real-PoW header chains.
///
/// 3b0: after SPV-03 the header chain reorganizes correctly, but nothing
/// acted on it. SPVActor only sent BlockchainReorganizationNotification,
/// which no actor handled, so a transaction confirmed in an orphaned block
/// kept its confirmation, its merkle proof and its spendable UTXOs.
///
/// zvj part 1: a transaction imported before the header at its proof's
/// height was synced is stored with an unverified proof (block hash
/// 'pending') and was never checked once the header arrived.
///
/// mny (libspiffy-mny): proofs are never deleted. The orphaned or mismatching
/// proof stays stored with the status orphaned; a proof stored before its
/// header has the status pendingHeader (no placeholder block hash).
///
/// The transaction is the real testnet fixture transaction; each test puts
/// it in a regtest block of its own (a two-leaf merkle tree) so that the
/// block header commits to it.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:dactor/dactor.dart';
import 'package:isar/isar.dart';
import 'package:libspiffy/libspiffy.dart';
import 'package:libspiffy/src/actors/libspiffy_actor_system.dart';
import 'package:libspiffy/src/actors/spv_messages.dart' show BlockHeadersReceivedMessage;
import 'package:libspiffy/src/actors/wallet_messages.dart';
import 'package:libspiffy/src/core/wallet_commands.dart';
import 'package:libspiffy/src/core/wallet_events.dart';
import 'package:libspiffy/src/models/bitcoin_transaction.dart';
import 'package:libspiffy/src/models/bitcoin_utxo.dart';
import 'package:libspiffy/src/spv/network_params.dart';
import 'package:libspiffy/src/utils/beef.dart';
import 'package:libspiffy/src/utils/bump.dart';
import 'package:spiffynode/spiffy_node.dart';
import 'package:test/test.dart';

import '../spv/regtest_chain_builder.dart';
import '../spv/testnet_proof_fixture.dart';
import 'isar_test_helper.dart';
import 'p2p_test_helpers.dart';

/// Output 1 of the fixture transaction pays the kTestXpriv root address.
const _walletVout = 1;
const _walletOutputScript = '76a9146a418bf9e2e2b670e1aa7b7da59391e212b4ba1988ac';

void main() {
  final genesis = NetworkParams.regtest.genesisHeader;
  final txidInternal = displayHexToInternal(kFixtureTxid);

  /// A BUMP for the fixture transaction at [height] in a two-transaction
  /// block, and the merkle root that block's header must carry.
  (BUMP, Hash) blockFor(int height) {
    final sibling = Uint8List.fromList(List<int>.generate(32, (i) => (i * 7 + height) & 0xff));
    final bump = BUMP.fromMerklePath(blockHeight: height, txid: txidInternal, index: 0, siblings: [sibling]);
    return (bump, Hash.fromBytes(bump.computeMerkleRoot(txidInternal)));
  }

  late Directory dir;
  late LibSpiffyActorSystem libspiffy;
  late LocalActorSystem actorSystem;
  late _RecordingArc arc;
  late String walletId;

  setUpAll(() async {
    await ensureIsarInitialized();
  });

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('reorg_revert_');
    actorSystem = LocalActorSystem(ActorSystemConfig());
    final isar = await Isar.open(
      LibSpiffySchemas.allSchemas,
      directory: dir.path,
      name: 'reorg_${DateTime.now().microsecondsSinceEpoch}',
    );
    arc = _RecordingArc();
    libspiffy = LibSpiffyActorSystem();
    await libspiffy.initialize(
      actorSystem: actorSystem,
      isar: isar,
      dataDirectory: dir.path,
      networkType: 'regtest',
      enableP2P: false,
      arcService: arc,
    );
    walletId = 'reorg-wallet-${DateTime.now().microsecondsSinceEpoch}';
    await createWallet(
      walletManager: libspiffy.walletManager,
      actorSystem: actorSystem,
      walletId: walletId,
      walletName: 'Reorg',
      xpriv: kTestXpriv,
    );
    await _until(() async => await libspiffy.walletStorage.isWalletAddress(walletId, kTestRootAddress),
        'root address projected');
  });

  tearDown(() async {
    await libspiffy.shutdown();
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  });

  final storage = () => libspiffy.walletStorage;

  Future<BitcoinTransaction?> tx() => storage().getTransaction(kFixtureTxid, walletId: walletId);

  Future<BitcoinUtxo?> walletUtxo() async {
    final utxos = await storage().getUTXOs(walletId, includeSpent: true);
    return utxos.where((u) => u.txid == kFixtureTxid && u.vout == _walletVout).firstOrNull;
  }

  Future<void> sendHeaders(List<BlockHeader> headers, int expectedTip) async {
    libspiffy.headerSyncActor.tell(BlockHeadersReceivedMessage(
      peerId: 'peer',
      headers: headers,
      startHeight: 1,
    ) as dynamic);
    await _until(() async => libspiffy.headerChain.bestHeight == expectedTip, 'tip at $expectedTip');
  }

  /// The wallet receives the fixture transaction with its proof through
  /// SPVActor, as from a counterparty.
  Future<void> receiveWithProof(BUMP bump) async {
    final done = Completer<SPVValidationResult>();
    final receiver = await actorSystem.spawn('spv-receiver', () => TestReceiverActor<SPVValidationResult>(done));
    libspiffy.spvActor.tell(
      ReceiveTransactionMessage(
        transactionId: kFixtureTxid,
        beef: BEEF.create(
          bumps: [bump],
          txs: [Uint8List.fromList(hex.decode(kFixtureTxHex))],
          hasMerkle: [true],
          bumpIndex: [0],
        ),
        fromCounterparty: 'alice',
        targetWalletId: walletId,
      ),
      sender: receiver,
    );
    final result = await done.future.timeout(const Duration(seconds: 10));
    expect(result.isValid, isTrue, reason: result.validationError);
  }

  /// The wallet imports the fixture transaction with its proof, as
  /// ImportActor does, while no header at the proof's height is stored.
  void importWithProof(BUMP bump) {
    libspiffy.walletManager.tell(WalletCommandMessage(walletId, RecordImportedTransactionCommand(
      walletId: walletId,
      txid: kFixtureTxid,
      rawHex: kFixtureTxHex,
      blockHeight: bump.blockHeight,
      bumpProofHex: bump.toHex(),
      totalOutputSats: 91296559239,
      numInputs: 1,
      numOutputs: 2,
      txVersion: 2,
      txLockTime: 0,
      walletReceivingAddresses: [kTestRootAddress],
      walletReceivedSats: 200000000,
      totalInputSats: 0,
      sendingAddresses: const [],
    )));
    libspiffy.walletManager.tell(WalletCommandMessage(walletId, ReceiveUTXOCommand(
      walletId: walletId,
      txid: kFixtureTxid,
      vout: _walletVout,
      satoshis: BigInt.from(200000000),
      scriptPubKey: _walletOutputScript,
      address: kTestRootAddress,
      blockHeight: bump.blockHeight,
      confirmations: 1,
      initialStatus: UTXOStatus.available,
    )));
  }

  Future<List<Object>> journal() async =>
      await libspiffy.eventStore.getEvents('BitcoinWallet_$walletId');

  group('a reorganization past the confirming block (3b0)', () {
    test('takes back the confirmation, keeps that proof as orphaned, keeps the transaction and re-polls ARC',
        () async {
      final (bump, root) = blockFor(2);
      final a1 = RegtestMiner.mine(parent: genesis, seed: 'A1');
      final a2 = RegtestMiner.mine(parent: a1, merkleRoot: root);
      final a3 = RegtestMiner.mine(parent: a2, seed: 'A3');
      await sendHeaders([a1, a2, a3], 3);

      await receiveWithProof(bump);
      await _until(() async {
        final t = await tx();
        final u = await walletUtxo();
        return t?.status == TransactionStatus.confirmed &&
            await storage().getMerkleProof(kFixtureTxid) != null &&
            u?.status == UTXOStatus.available;
      }, 'confirmed with proof and an available UTXO');
      expect((await storage().getMerkleProof(kFixtureTxid))!.blockHash, a2.blockHash().toString());

      // The other transaction of A2 (the fixture's sibling leaf), whose
      // proof is stored but which no wallet holds as confirmed.
      final siblingInternal = bump.path[0].leaves.firstWhere((l) => !l.isTxid).hash!;
      final siblingTxid = hex.encode(siblingInternal.reversed.toList());
      final siblingBump = BUMP.fromMerklePath(
          blockHeight: 2, txid: siblingInternal, index: 1, siblings: [txidInternal]);
      await storage().storeMerkleProof(siblingTxid, MerkleProof(
          txid: siblingTxid,
          blockHash: a2.blockHash().toString(),
          blockHeight: 2,
          position: 1,
          merkleProof: [siblingBump.toHex()]));

      // A heavier branch forks at height 1 and orphans A2 (the confirming
      // block) and A3.
      final b = RegtestMiner.mineChain(a1, 3, seed: 'B');
      await sendHeaders(b, 4);

      await _until(() async => (await tx())?.status != TransactionStatus.confirmed,
          'confirmation taken back after the reorganization');

      final t = (await tx())!;
      expect(t.status, TransactionStatus.pending);
      expect(t.blockHeight, isNull);
      expect(t.confirmations ?? 0, 0);
      expect(t.rawHex, kFixtureTxHex, reason: 'the transaction itself is retained');

      await _until(() async => await storage().getMerkleProof(kFixtureTxid) == null,
          'the orphaned proof is no longer the current proof');
      final history = await storage().getMerkleProofHistory(kFixtureTxid);
      expect(history, hasLength(1), reason: 'the orphaned proof is kept (mny)');
      expect(history.single.status, MerkleProofStatus.orphaned);
      expect(history.single.blockHash, a2.blockHash().toString());
      expect(history.single.merkleProof, [bump.toHex()]);

      final u = (await walletUtxo())!;
      expect(u.status, UTXOStatus.pending, reason: 'no longer spendable on the strength of the orphaned proof');
      expect(u.confirmations ?? 0, 0);
      expect(u.isConfirmed, isFalse);

      final reverted = (await journal()).whereType<TransactionConfirmationRevertedEvent>().toList();
      expect(reverted, hasLength(1), reason: 'the revert is journaled, so a replay keeps it');
      expect(reverted.single.txid, kFixtureTxid);
      expect(reverted.single.blockHash, a2.blockHash().toString());
      expect(reverted.single.merkleProof, [bump.toHex()], reason: 'the orphaned proof is named in the journal');

      await _until(() async => arc.queried.contains(kFixtureTxid), 'ARC polled again for a new proof');

      // No confirmation to take back for the sibling, but its proof names an
      // orphaned block: marked orphaned, kept.
      expect(await storage().getMerkleProof(siblingTxid), isNull);
      expect([for (final p in await storage().getMerkleProofHistory(siblingTxid)) p.status],
          [MerkleProofStatus.orphaned]);
      expect(arc.queried, isNot(contains(siblingTxid)));
    });

    test('a reorganization above the confirming block leaves the confirmation and proof alone', () async {
      final (bump, root) = blockFor(2);
      final a1 = RegtestMiner.mine(parent: genesis, seed: 'A1');
      final a2 = RegtestMiner.mine(parent: a1, merkleRoot: root);
      final a3 = RegtestMiner.mine(parent: a2, seed: 'A3');
      await sendHeaders([a1, a2, a3], 3);
      await receiveWithProof(bump);
      await _until(() async => await storage().getMerkleProof(kFixtureTxid) != null &&
          (await walletUtxo())?.status == UTXOStatus.available, 'confirmed');

      final c = RegtestMiner.mineChain(a2, 2, seed: 'C'); // orphans A3 only
      await sendHeaders(c, 4);
      await Future<void>.delayed(const Duration(milliseconds: 1500));

      expect((await tx())!.status, TransactionStatus.confirmed);
      expect((await storage().getMerkleProof(kFixtureTxid))!.status, MerkleProofStatus.verified);
      expect((await walletUtxo())!.status, UTXOStatus.available);
      expect((await journal()).whereType<TransactionConfirmationRevertedEvent>(), isEmpty);
    });
  });

  group('a proof imported before its header was synced (zvj part 1)', () {
    test('is verified when the header arrives', () async {
      final (bump, root) = blockFor(2);
      importWithProof(bump);
      await _until(() async => (await storage().getMerkleProof(kFixtureTxid))?.status == MerkleProofStatus.pendingHeader,
          'imported with an unverified proof');
      expect((await storage().getMerkleProof(kFixtureTxid))!.blockHash, isNull);
      expect([for (final p in await storage().getMerkleProofsByStatus(MerkleProofStatus.pendingHeader)) p.txid],
          [kFixtureTxid]);

      final a1 = RegtestMiner.mine(parent: genesis, seed: 'A1');
      final a2 = RegtestMiner.mine(parent: a1, merkleRoot: root);
      await sendHeaders([a1, a2], 2);

      await _until(() async => (await storage().getMerkleProof(kFixtureTxid))?.blockHash == a2.blockHash().toString(),
          'proof bound to the header that verifies it');
      final history = await storage().getMerkleProofHistory(kFixtureTxid);
      expect([for (final p in history) (p.blockHash, p.status)],
          [(a2.blockHash().toString(), MerkleProofStatus.verified)],
          reason: 'the pendingHeader proof itself becomes verified');
      expect(await storage().getMerkleProofsByStatus(MerkleProofStatus.pendingHeader), isEmpty);
      expect((await tx())!.status, TransactionStatus.confirmed);
      expect((await walletUtxo())!.status, UTXOStatus.available);
    });

    test('whose root does not match the header that arrives loses its confirmation', () async {
      final (bump, _) = blockFor(2);
      importWithProof(bump);
      await _until(() async => (await storage().getMerkleProof(kFixtureTxid))?.status == MerkleProofStatus.pendingHeader &&
          (await walletUtxo())?.status == UTXOStatus.available, 'imported with an unverified proof');

      // The block at height 2 on our chain does not contain the transaction.
      final headers = RegtestMiner.mineChain(genesis, 2, seed: 'other');
      await sendHeaders(headers, 2);

      await _until(() async => (await tx())?.status == TransactionStatus.pending, 'confirmation taken back');
      await _until(() async => await storage().getMerkleProof(kFixtureTxid) == null,
          'the mismatching proof is no longer the current proof');
      final history = await storage().getMerkleProofHistory(kFixtureTxid);
      expect([for (final p in history) (p.merkleProof.join(), p.status)], [
        (bump.toHex(), MerkleProofStatus.orphaned)
      ], reason: 'the mismatching proof is kept as orphaned (mny)');
      expect((await walletUtxo())!.status, UTXOStatus.pending);
      expect((await tx())!.rawHex, kFixtureTxHex);
    });
  });
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

/// ARC that knows no transaction and records what was asked.
class _RecordingArc extends ArcService {
  _RecordingArc() : super(baseUrl: 'fake://arc');

  final List<String> queried = [];

  @override
  Future<ArcTransactionResponse> getTransaction(String txid) async {
    queried.add(txid);
    throw ArcException('Failed to get transaction: {"status":404}');
  }
}
