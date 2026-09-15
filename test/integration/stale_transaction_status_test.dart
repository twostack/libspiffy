/// Bead libspiffy-7dj part 1, end to end through LibSpiffyActorSystem on
/// regtest: a later, less complete record of a confirmed transaction took
/// its confirmation back outside the reorganization path.
///
/// The records that did it:
/// * ARC's answer to a broadcast of a transaction the wallet already holds
///   as confirmed (the recipient settling a proven BEEF, a retry-queue
///   resubmission, a status report that lags the MINED one): ARCActor sends
///   UpdateTransactionStatusCommand(seenOnNetwork) and the projection stored
///   the row with that status.
/// * The same transaction recorded again without its proof (a counterparty
///   re-delivering the unproven BEEF after the wallet confirmed it, an import
///   replay): the projection stored a pending row without a block height.
///
/// Only a reorganization or a rejected proof takes a confirmation back
/// (test/integration/reorg_confirmation_revert_test.dart).
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:dactor/dactor.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:isar/isar.dart';
import 'package:libspiffy/libspiffy.dart';
import 'package:libspiffy/src/actors/spv_messages.dart' show BlockHeadersReceivedMessage;
import 'package:libspiffy/src/core/wallet_commands.dart';
import 'package:libspiffy/src/core/wallet_events.dart';
import 'package:libspiffy/src/spv/network_params.dart';
import 'package:spiffynode/spiffy_node.dart';
import 'package:test/test.dart';

import '../spv/regtest_chain_builder.dart';
import '../spv/testnet_proof_fixture.dart';
import 'isar_test_helper.dart';
import 'p2p_test_helpers.dart';

void main() {
  final genesis = NetworkParams.regtest.genesisHeader;
  final txidInternal = displayHexToInternal(kFixtureTxid);

  late Directory dir;
  late LibSpiffyActorSystem libspiffy;
  late LocalActorSystem actorSystem;
  late _SeenOnNetworkArc arc;
  late String walletId;

  setUpAll(() async {
    await ensureIsarInitialized();
  });

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('stale_status_');
    actorSystem = LocalActorSystem(ActorSystemConfig());
    final isar = await Isar.open(
      LibSpiffySchemas.allSchemas,
      directory: dir.path,
      name: 'stale_${DateTime.now().microsecondsSinceEpoch}',
    );
    arc = _SeenOnNetworkArc();
    libspiffy = LibSpiffyActorSystem();
    await libspiffy.initialize(
      actorSystem: actorSystem,
      isar: isar,
      dataDirectory: dir.path,
      networkType: 'regtest',
      enableP2P: false,
      arcService: arc,
    );
    walletId = 'stale-wallet-${DateTime.now().microsecondsSinceEpoch}';
    await createWallet(
      walletManager: libspiffy.walletManager,
      actorSystem: actorSystem,
      walletId: walletId,
      walletName: 'Stale',
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

  ReadModelStorage storage() => libspiffy.walletStorage;
  Future<BitcoinTransaction?> tx() => storage().getTransaction(kFixtureTxid, walletId: walletId);
  Future<List<Object>> journal() async => await libspiffy.eventStore.getEvents('BitcoinWallet_$walletId');

  /// The fixture transaction confirmed at height 2 of a regtest chain whose
  /// block 2 commits to it, received with its proof as from a counterparty.
  Future<void> receiveConfirmed() async {
    final sibling = Uint8List.fromList(List<int>.generate(32, (i) => (i * 7 + 2) & 0xff));
    final bump = BUMP.fromMerklePath(blockHeight: 2, txid: txidInternal, index: 0, siblings: [sibling]);
    final a1 = RegtestMiner.mine(parent: genesis, seed: 'A1');
    final a2 = RegtestMiner.mine(parent: a1, merkleRoot: Hash.fromBytes(bump.computeMerkleRoot(txidInternal)));
    final a3 = RegtestMiner.mine(parent: a2, seed: 'A3');
    libspiffy.headerSyncActor.tell(
        BlockHeadersReceivedMessage(peerId: 'peer', headers: [a1, a2, a3], startHeight: 1) as dynamic);
    await _until(() async => libspiffy.headerChain.bestHeight == 3, 'tip at 3');

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
    await _until(() async {
      final t = await tx();
      return t?.status == TransactionStatus.confirmed &&
          await storage().getMerkleProof(kFixtureTxid) != null &&
          (await storage().getUTXOs(walletId)).any((u) => u.txid == kFixtureTxid && u.status == UTXOStatus.available);
    }, 'confirmed with its proof');
    final t = (await tx())!;
    expect(t.blockHeight, 2);
    // The next record is distinguishable by its update time.
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }

  /// Waits until the projection has stored the row for [event].
  Future<void> applied<E extends WalletEvent>(String what) async {
    await _until(() async => (await journal()).whereType<E>().isNotEmpty, '$what journaled');
    final event = (await journal()).whereType<E>().last;
    await _until(() async {
      final t = await tx();
      return t != null && !t.updatedAt.isBefore(event.timestamp.subtract(const Duration(milliseconds: 1)));
    }, '$what applied to the read model');
  }

  Future<void> expectStillConfirmed() async {
    final t = (await tx())!;
    expect(t.status, TransactionStatus.confirmed);
    expect(t.blockHeight, 2);
    expect(t.rawHex, kFixtureTxHex);
    expect((await storage().getMerkleProof(kFixtureTxid))?.blockHeight, 2);
    expect([for (final c in await storage().getConfirmedTransactionsFromHeight(2)) if (c.walletId == walletId) c.txid],
        [kFixtureTxid], reason: 'a later reorganization past block 2 still finds the confirmation');
    expect((await journal()).whereType<TransactionConfirmationRevertedEvent>(), isEmpty);
  }

  test('ARC answering SEEN_ON_NETWORK to a broadcast of a confirmed transaction keeps the confirmation', () async {
    await receiveConfirmed();

    // The recipient settles the transaction it holds with a proof.
    libspiffy.arcActor.tell(BroadcastTransactionMessage(walletId, kFixtureTxHex, kFixtureTxid));
    await _until(() async => arc.submitted.contains(kFixtureTxid), 'submitted to ARC');
    await applied<TransactionStatusUpdatedEvent>('the ARC status');
    expect((await journal()).whereType<TransactionStatusUpdatedEvent>().last.newStatus,
        TransactionStatus.seenOnNetwork);

    await expectStillConfirmed();
  });

  test('the transaction recorded again without its proof keeps the confirmation', () async {
    await receiveConfirmed();
    final importsBefore = (await journal()).whereType<TransactionImportedEvent>().length;

    // As WalletManagerActor records a re-delivered BEEF whose subject has no
    // BUMP (or ImportActor replays an import).
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
    await _until(() async => (await journal()).whereType<TransactionImportedEvent>().length > importsBefore,
        'the second record journaled');
    await applied<TransactionImportedEvent>('the second record');

    await expectStillConfirmed();
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

/// ARC that has the transaction in its mempool view: a submission answers
/// SEEN_ON_NETWORK; a status query knows nothing.
class _SeenOnNetworkArc extends ArcService {
  _SeenOnNetworkArc() : super(baseUrl: 'fake://arc');

  final List<String> submitted = [];

  @override
  Future<ArcSubmitResponse> submitTransaction(String rawTx, {String? callbackUrl}) async {
    final txid = dartsv.Transaction.fromHex(rawTx).id;
    submitted.add(txid);
    return ArcSubmitResponse(txid: txid, status: ArcTransactionStatus.seenOnNetwork);
  }

  @override
  Future<ArcTransactionResponse> getTransaction(String txid) async {
    throw ArcException('Failed to get transaction: {"status":404}');
  }
}
