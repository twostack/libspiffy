/// 9ek (libspiffy-9ek): merkle proofs received from ARC were never journaled.
///
/// ARCActor stored a verified MINED proof straight into the read model and
/// told the wallet ConfirmTransactionCommand, whose TransactionConfirmedEvent
/// carried only txid, block height and block hash. The journal is the source
/// of truth: a read model rebuilt from it (fresh storage, the header chain,
/// every journal event replayed through WalletProjection) had no proof for
/// the transaction, and after a re-mine kept only the orphaned proof.
///
/// End to end through LibSpiffyActorSystem on regtest with real-PoW header
/// chains and a fake ARC; the transaction is the real testnet fixture
/// transaction, placed in a regtest block of its own (a two-leaf tree).
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:dactor/dactor.dart';
import 'package:eventador/eventador.dart';
import 'package:isar/isar.dart';
import 'package:libspiffy/libspiffy.dart';
import 'package:libspiffy/src/actors/libspiffy_actor_system.dart';
import 'package:libspiffy/src/actors/spv_messages.dart' show BlockHeadersReceivedMessage;
import 'package:libspiffy/src/actors/wallet_messages.dart';
import 'package:libspiffy/src/core/wallet_commands.dart';
import 'package:libspiffy/src/core/wallet_events.dart';
import 'package:libspiffy/src/models/bitcoin_transaction.dart';
import 'package:libspiffy/src/projections/wallet_projection.dart';
import 'package:libspiffy/src/spv/network_params.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';
import 'package:libspiffy/src/utils/beef.dart';
import 'package:libspiffy/src/utils/bump.dart';
import 'package:spiffynode/spiffy_node.dart';
import 'package:test/test.dart';

import '../spv/regtest_chain_builder.dart';
import '../spv/testnet_proof_fixture.dart';
import 'isar_test_helper.dart';
import 'p2p_test_helpers.dart';

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
  late _MinedArc arc;
  late String walletId;

  setUpAll(() async {
    await ensureIsarInitialized();
  });

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('arc_proof_journal_');
    actorSystem = LocalActorSystem(ActorSystemConfig());
    final isar = await Isar.open(
      LibSpiffySchemas.allSchemas,
      directory: dir.path,
      name: 'arc_proof_${DateTime.now().microsecondsSinceEpoch}',
    );
    arc = _MinedArc();
    libspiffy = LibSpiffyActorSystem();
    await libspiffy.initialize(
      actorSystem: actorSystem,
      isar: isar,
      dataDirectory: dir.path,
      networkType: 'regtest',
      enableP2P: false,
      arcService: arc,
    );
    walletId = 'arc-proof-wallet-${DateTime.now().microsecondsSinceEpoch}';
    await createWallet(
      walletManager: libspiffy.walletManager,
      actorSystem: actorSystem,
      walletId: walletId,
      walletName: 'ArcProof',
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

  Future<void> sendHeaders(List<BlockHeader> headers, int expectedTip) async {
    libspiffy.headerSyncActor.tell(BlockHeadersReceivedMessage(
      peerId: 'peer',
      headers: headers,
      startHeight: 1,
    ) as dynamic);
    await _until(() async => libspiffy.headerChain.bestHeight == expectedTip, 'tip at $expectedTip');
  }

  Future<List<Event>> journal() => libspiffy.eventStore.getEvents('BitcoinWallet_$walletId');

  /// A read model rebuilt from the journal: fresh storage holding the active
  /// header chain (headers are synced, not journaled), with every journal
  /// event of the wallet replayed through WalletProjection.
  Future<InMemoryWalletStorage> rebuildFromJournal() async {
    final fresh = InMemoryWalletStorage();
    for (var h = 1; h <= libspiffy.headerChain.bestHeight; h++) {
      final header = await storage().getBlockHeaderByHeight(h);
      if (header != null) await fresh.storeBlockHeader(header, h);
    }
    final projection = WalletProjection(
      projectionId: 'rebuild-${DateTime.now().microsecondsSinceEpoch}',
      eventStore: libspiffy.eventStore,
      storage: fresh,
    );
    for (final event in await journal()) {
      await projection.handle(event);
    }
    return fresh;
  }

  List<(String, MerkleProofStatus)> contentAndStatus(List<MerkleProof> rows) =>
      [for (final p in rows) (p.merkleProof.join(), p.status)]..sort((a, b) => a.$1.compareTo(b.$1));

  ArcTransactionResponse minedAt(BUMP bump, BlockHeader block) => ArcTransactionResponse.fromJson({
        'timestamp': '2026-09-14T08:00:00Z',
        'txid': kFixtureTxid,
        'txStatus': 'MINED',
        'blockHash': block.blockHash().toString(),
        'blockHeight': bump.blockHeight,
        'merklePath': bump.toHex(),
      });

  test('9ek: a proof ARC supplied survives a rebuild of the read model from the journal', () async {
    final (bump, root) = blockFor(2);
    final a1 = RegtestMiner.mine(parent: genesis, seed: 'A1');
    final a2 = RegtestMiner.mine(parent: a1, merkleRoot: root);
    final a3 = RegtestMiner.mine(parent: a2, seed: 'A3');
    await sendHeaders([a1, a2, a3], 3);

    // The wallet holds the transaction unconfirmed (no proof in hand).
    libspiffy.walletManager.tell(WalletCommandMessage(walletId, RecordImportedTransactionCommand(
      walletId: walletId,
      txid: kFixtureTxid,
      rawHex: kFixtureTxHex,
      blockHeight: 0,
      bumpProofHex: '',
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
    await _until(() async => (await tx())?.status == TransactionStatus.pending, 'transaction held as pending');
    expect(await storage().getMerkleProof(kFixtureTxid), isNull);

    arc.responses[kFixtureTxid] = minedAt(bump, a2);
    libspiffy.arcActor.tell(CheckStoragePendingUTXOsMessage(triggerBlockHeight: 3));
    await _until(() async => (await tx())?.status == TransactionStatus.confirmed &&
        (await storage().getMerkleProof(kFixtureTxid))?.status == MerkleProofStatus.verified,
        'confirmed through ARC with a verified proof');

    final confirmed = (await journal()).whereType<TransactionConfirmedEvent>().toList();
    expect(confirmed, hasLength(1));

    final rebuilt = await rebuildFromJournal();
    final proof = await rebuilt.getMerkleProof(kFixtureTxid);
    expect(proof, isNotNull, reason: 'the ARC proof must be in the journal, not only in the read model');
    expect(proof!.merkleProof, [bump.toHex()]);
    expect(proof.status, MerkleProofStatus.verified);
    expect(proof.blockHash, a2.blockHash().toString());
    expect(proof.position, 0);
    expect((await rebuilt.getTransaction(kFixtureTxid, walletId: walletId))!.status, TransactionStatus.confirmed);

    // The journaled event carries the BUMP ARC supplied.
    expect(confirmed.single.bumpHex, bump.toHex());

    // A second replay over the rebuilt read model changes no proof row.
    final before = contentAndStatus(await rebuilt.getMerkleProofHistory(kFixtureTxid));
    final projection = WalletProjection(projectionId: 'replay-again', eventStore: libspiffy.eventStore, storage: rebuilt);
    for (final event in await journal()) {
      await projection.handle(event);
    }
    expect(contentAndStatus(await rebuilt.getMerkleProofHistory(kFixtureTxid)), before);
  });

  test('9ek: after a reorganization and a re-mine, a rebuild keeps the orphaned proof and the new current one',
      () async {
    final (bumpA, rootA) = blockFor(2);
    final (bumpB, rootB) = blockFor(3);
    final a1 = RegtestMiner.mine(parent: genesis, seed: 'A1');
    final a2 = RegtestMiner.mine(parent: a1, merkleRoot: rootA);
    final a3 = RegtestMiner.mine(parent: a2, seed: 'A3');
    await sendHeaders([a1, a2, a3], 3);

    // Received from a counterparty with its proof in block A2.
    final done = Completer<SPVValidationResult>();
    final receiver = await actorSystem.spawn('spv-receiver', () => TestReceiverActor<SPVValidationResult>(done));
    libspiffy.spvActor.tell(
      ReceiveTransactionMessage(
        transactionId: kFixtureTxid,
        beef: BEEF.create(
          bumps: [bumpA],
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
    await _until(() async => (await tx())?.status == TransactionStatus.confirmed &&
        (await storage().getMerkleProof(kFixtureTxid))?.blockHash == a2.blockHash().toString(),
        'confirmed in A2');

    // A heavier branch orphans A2; the transaction is mined again in B3,
    // which ARC reports once the confirmation has been taken back.
    final b2 = RegtestMiner.mine(parent: a1, seed: 'B2');
    final b3 = RegtestMiner.mine(parent: b2, merkleRoot: rootB);
    final b4 = RegtestMiner.mine(parent: b3, seed: 'B4');
    arc.responses[kFixtureTxid] = minedAt(bumpB, b3);
    await sendHeaders([b2, b3, b4], 4);

    await _until(() async {
      final t = await tx();
      return t?.status == TransactionStatus.confirmed && t?.blockHeight == 3 &&
          (await storage().getMerkleProof(kFixtureTxid))?.blockHash == b3.blockHash().toString();
    }, 'reverted, then confirmed again in B3 through ARC', timeout: const Duration(seconds: 12));

    final expected = [
      (bumpA.toHex(), MerkleProofStatus.orphaned),
      (bumpB.toHex(), MerkleProofStatus.verified),
    ]..sort((a, b) => a.$1.compareTo(b.$1));
    expect(contentAndStatus(await storage().getMerkleProofHistory(kFixtureTxid)), expected,
        reason: 'the live read model');

    final events = await journal();
    expect(events.whereType<TransactionConfirmationRevertedEvent>(), hasLength(1));

    final rebuilt = await rebuildFromJournal();
    expect(contentAndStatus(await rebuilt.getMerkleProofHistory(kFixtureTxid)), expected,
        reason: 'the rebuilt read model holds the orphaned proof and the re-mined one');
    final current = (await rebuilt.getMerkleProof(kFixtureTxid))!;
    expect((current.blockHash, current.status), (b3.blockHash().toString(), MerkleProofStatus.verified));
    expect((await rebuilt.getTransaction(kFixtureTxid, walletId: walletId))!.blockHeight, 3);

    // Replaying the journal again over the rebuilt model yields the same rows.
    final projection = WalletProjection(projectionId: 'replay-again', eventStore: libspiffy.eventStore, storage: rebuilt);
    for (final event in events) {
      await projection.handle(event);
    }
    expect(contentAndStatus(await rebuilt.getMerkleProofHistory(kFixtureTxid)), expected);
    expect((await rebuilt.getMerkleProof(kFixtureTxid))!.blockHash, b3.blockHash().toString());
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

/// ARC that answers from [responses] and knows no other transaction.
class _MinedArc extends ArcService {
  _MinedArc() : super(baseUrl: 'fake://arc');

  final Map<String, ArcTransactionResponse> responses = {};

  @override
  Future<ArcTransactionResponse> getTransaction(String txid) async {
    final response = responses[txid];
    if (response == null) throw ArcException('Failed to get transaction: {"status":404}');
    return response;
  }
}
