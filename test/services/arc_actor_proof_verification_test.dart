/// ARCActor: SPV-09 (bead libspiffy-nci) and A-M3 (bead libspiffy-7xz).
///
/// SPV-09: when ARC reported a transaction MINED the actor sent
/// ConfirmTransactionCommand with ARC's block height and stored ARC's proof
/// (at position 0) without looking at a single block header. Whoever
/// answers as "ARC" could confirm anything.
///
/// A-M3: the 30 s timer and every header batch (CheckStoragePendingUTXOs,
/// one per stored header) each ran a full scan of non-terminal
/// transactions; scans overlapped and a header sync queued one scan per
/// header behind the mailbox.
///
/// Fixture: a real testnet transaction, its real BRC-74 proof (what ARC
/// returns as `merklePath`) and the real header of its block.
import 'dart:async';

import 'package:dactor/dactor.dart';
import 'package:libspiffy/src/actors/arc_actor.dart';
import 'package:libspiffy/src/actors/spv_messages.dart' show BlockHeaderStoredMessage;
import 'package:libspiffy/src/actors/wallet_messages.dart';
import 'package:libspiffy/src/core/wallet_commands.dart';
import 'package:libspiffy/src/models/bitcoin_transaction.dart';
import 'package:libspiffy/src/models/bitcoin_utxo.dart';
import 'package:libspiffy/src/services/arc_service.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';
import 'package:libspiffy/src/storage/read_model_storage.dart' show MerkleProof;
import 'package:test/test.dart';

import '../spv/testnet_proof_fixture.dart';

const _wallet = 'w';

void main() {
  late LocalActorSystem system;
  late _ProofWriteRecordingStorage storage;
  late _RecordingWalletManager walletManager;
  late _FakeArc arc;
  late ActorRef arcActor;

  Future<void> storeTx(String txid, TransactionStatus status, {String rawHex = '', String wallet = _wallet}) =>
      storage.storeTransaction(
        wallet,
        BitcoinTransaction(
          walletId: wallet,
          txid: txid,
          rawHex: rawHex,
          status: status,
          inputValue: BigInt.zero,
          outputValue: BigInt.zero,
          fee: BigInt.zero,
          receivingAddresses: const [],
          sendingAddresses: const [],
          netAmount: BigInt.zero,
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
          lockTime: 0,
          version: 1,
        ),
      );

  ArcTransactionResponse mined({String? bumpHex}) => ArcTransactionResponse.fromJson({
        'timestamp': '2026-09-14T08:00:00Z',
        'txid': kFixtureTxid,
        'txStatus': 'MINED',
        'blockHash': kFixtureBlockHash,
        'blockHeight': kFixtureHeight,
        'merklePath': bumpHex ?? fixtureBumpHex(),
      });

  Future<void> spawnActor() async {
    final wm = await system.spawn('wallet-manager', () => walletManager);
    arcActor = await system.spawn(
      'arc',
      () => ARCActor(walletManager: wm, storage: storage, arcService: arc),
    );
  }

  /// Header batch notification, as SPVActor sends it per stored header.
  void headersArrived() => arcActor.tell(CheckStoragePendingUTXOsMessage(triggerBlockHeight: kFixtureHeight));

  /// Waits until ARC has answered [calls] status requests and the actor has
  /// had time to act on the answers.
  Future<void> settleAfterArcCalls(int calls) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (arc.getTransactionCalls < calls && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }

  setUp(() {
    system = LocalActorSystem(ActorSystemConfig());
    storage = _ProofWriteRecordingStorage();
    walletManager = _RecordingWalletManager();
    arc = _FakeArc();
  });

  tearDown(() => system.shutdown());

  group('ARC MINED is checked against the local header chain (SPV-09)', () {
    test('a proof whose root matches the header confirms, with the header hash and tx position', () async {
      await storage.storeBlockHeader(fixtureHeader(), kFixtureHeight);
      await storeTx(kFixtureTxid, TransactionStatus.seenOnNetwork);
      arc.responses[kFixtureTxid] = mined();
      await spawnActor();

      headersArrived();
      await settleAfterArcCalls(1);

      final confirms = walletManager.commands.whereType<ConfirmTransactionCommand>().toList();
      expect(confirms, hasLength(1));
      expect(confirms.single.blockHeight, kFixtureHeight);
      expect(confirms.single.blockHash, kFixtureBlockHash);
    });

    // 9ek (libspiffy-9ek): the actor stored the proof straight into the read
    // model and journaled only txid, height and hash, so a read model rebuilt
    // from the journal had no proof. The verified BUMP now travels in the
    // command (and so the event); the actor writes no proof itself.
    test('9ek: the verified BUMP goes to the wallet in the command; the actor writes no proof to the read model',
        () async {
      await storage.storeBlockHeader(fixtureHeader(), kFixtureHeight);
      await storeTx(kFixtureTxid, TransactionStatus.seenOnNetwork);
      arc.responses[kFixtureTxid] = mined();
      await spawnActor();

      headersArrived();
      await settleAfterArcCalls(1);

      final confirms = walletManager.commands.whereType<ConfirmTransactionCommand>().toList();
      expect(confirms, hasLength(1));
      expect(storage.proofWrites, isEmpty, reason: 'proofs reach the read model only through the journal');
      expect(await storage.getMerkleProof(kFixtureTxid), isNull);
      expect(confirms.single.bumpHex, fixtureBumpHex());
    });

    test('9ek: every wallet holding the transaction gets its own confirmation with the BUMP', () async {
      await storage.storeBlockHeader(fixtureHeader(), kFixtureHeight);
      await storeTx(kFixtureTxid, TransactionStatus.seenOnNetwork);
      await storeTx(kFixtureTxid, TransactionStatus.broadcast, wallet: 'w2');
      arc.responses[kFixtureTxid] = mined();
      await spawnActor();

      headersArrived();
      await settleAfterArcCalls(2);

      final confirms = walletManager.commands.whereType<ConfirmTransactionCommand>().toList();
      expect([for (final c in confirms) c.walletId]..sort(), ['w', 'w2'],
          reason: 'one command per wallet, in the same scan');
      expect(confirms.map((c) => c.bumpHex).toSet(), {fixtureBumpHex()});
      expect(storage.proofWrites, isEmpty);
    });

    test('9ek: a MINED report held for its header confirms every wallet that met it once the header arrives',
        () async {
      await storeTx(kFixtureTxid, TransactionStatus.seenOnNetwork);
      await storeTx(kFixtureTxid, TransactionStatus.seenOnNetwork, wallet: 'w2');
      arc.responses[kFixtureTxid] = mined();
      await spawnActor();

      headersArrived();
      await settleAfterArcCalls(2);
      expect(walletManager.commands.whereType<ConfirmTransactionCommand>(), isEmpty);

      arc.responses.remove(kFixtureTxid); // ARC unreachable: only the held reports can confirm
      await storage.storeBlockHeader(fixtureHeader(), kFixtureHeight);
      arcActor.tell(BlockHeaderStoredMessage(height: kFixtureHeight, header: fixtureHeader()));
      await Future<void>.delayed(const Duration(milliseconds: 300));

      final confirms = walletManager.commands.whereType<ConfirmTransactionCommand>().toList();
      expect([for (final c in confirms) c.walletId]..sort(), ['w', 'w2']);
      expect(confirms.map((c) => c.bumpHex).toSet(), {fixtureBumpHex()});
    });

    test('a proof whose root does not match the header at that height does not confirm', () async {
      await storage.storeBlockHeader(fixtureHeader(), kFixtureHeight);
      await storeTx(kFixtureTxid, TransactionStatus.seenOnNetwork);
      arc.responses[kFixtureTxid] = mined(bumpHex: fixtureBumpHex(tamperLevel: 4));
      await spawnActor();

      headersArrived();
      await settleAfterArcCalls(1);

      expect(walletManager.commands.whereType<ConfirmTransactionCommand>(), isEmpty);
      expect(
          walletManager.commands
              .whereType<UpdateTransactionStatusCommand>()
              .where((c) => c.newStatus == TransactionStatus.confirmed),
          isEmpty);
      expect(await storage.getMerkleProof(kFixtureTxid), isNull);
    });

    test('a genuine proof does not confirm when our header at that height is a different block', () async {
      await storage.storeBlockHeader(otherHeaderAtFixtureHeight(), kFixtureHeight);
      await storeTx(kFixtureTxid, TransactionStatus.seenOnNetwork);
      arc.responses[kFixtureTxid] = mined();
      await spawnActor();

      headersArrived();
      await settleAfterArcCalls(1);

      expect(walletManager.commands.whereType<ConfirmTransactionCommand>(), isEmpty);
    });

    test('MINED before the header is known is deferred, then confirmed once the header arrives', () async {
      await storeTx(kFixtureTxid, TransactionStatus.seenOnNetwork);
      arc.responses[kFixtureTxid] = mined();
      await spawnActor();

      headersArrived();
      await settleAfterArcCalls(1);
      expect(walletManager.commands.whereType<ConfirmTransactionCommand>(), isEmpty,
          reason: 'no header at the height yet: must not confirm');

      await storage.storeBlockHeader(fixtureHeader(), kFixtureHeight);
      headersArrived();
      await settleAfterArcCalls(2);

      final confirms = walletManager.commands.whereType<ConfirmTransactionCommand>().toList();
      expect(confirms, hasLength(1));
      expect(confirms.single.blockHash, kFixtureBlockHash);
    });
  });

  // zvj part 3 (libspiffy-zvj): only SEEN_ON_NETWORK applied the deferred
  // spend. A transaction ARC first reports as MINED (broadcast, then mined
  // before the next scan) kept its inputs unspent and its outputs pending.
  group('A transaction reported MINED straight from broadcast (zvj part 3)', () {
    const fundingTxid = '6af69a37518c963234ab5b9e0c6afb6bc7273f1be58e98c42336c29067c0b665';

    Future<void> storeUtxo(String txid, int vout, UTXOStatus status) => storage.upsertUTXO(
          _wallet,
          BitcoinUtxo.create(
            txid: txid,
            vout: vout,
            satoshis: BigInt.from(1000),
            scriptPubKey: '76a914${'00' * 20}88ac',
            address: 'addr-$txid-$vout',
            status: status,
          ),
        );

    test('marks the wallet inputs spent and the wallet outputs available on confirmation', () async {
      await storage.storeBlockHeader(fixtureHeader(), kFixtureHeight);
      await storeTx(kFixtureTxid, TransactionStatus.broadcast, rawHex: kFixtureTxHex);
      await storeUtxo(fundingTxid, 0, UTXOStatus.reserved); // the input it spends
      await storeUtxo(kFixtureTxid, 1, UTXOStatus.pending); // change back to the wallet
      arc.responses[kFixtureTxid] = mined();
      await spawnActor();

      headersArrived();
      await settleAfterArcCalls(1);

      expect(walletManager.commands.whereType<ConfirmTransactionCommand>(), hasLength(1));
      final spends = walletManager.commands.whereType<SpendUTXOCommand>().toList();
      expect(spends.map((c) => c.utxoKey), equals(['$fundingTxid:0']));
      expect(spends.single.spendingTxId, kFixtureTxid);
      final available = walletManager.commands.whereType<MarkUTXOAvailableCommand>().toList();
      expect(available.map((c) => '${c.txid}:${c.vout}'), equals(['$kFixtureTxid:1']),
          reason: 'output 0 is not a wallet UTXO; only wallet outputs are promoted');
    });

    test('an input already spent (SEEN_ON_NETWORK applied it) is not spent again', () async {
      await storage.storeBlockHeader(fixtureHeader(), kFixtureHeight);
      await storeTx(kFixtureTxid, TransactionStatus.seenOnNetwork, rawHex: kFixtureTxHex);
      await storeUtxo(fundingTxid, 0, UTXOStatus.spent);
      await storeUtxo(kFixtureTxid, 1, UTXOStatus.available);
      arc.responses[kFixtureTxid] = mined();
      await spawnActor();

      headersArrived();
      await settleAfterArcCalls(1);

      expect(walletManager.commands.whereType<ConfirmTransactionCommand>(), hasLength(1));
      expect(walletManager.commands.whereType<SpendUTXOCommand>(), isEmpty);
      expect(walletManager.commands.whereType<MarkUTXOAvailableCommand>(), isEmpty);
    });
  });

  group('ARCActor status checks are coalesced and incremental (A-M3)', () {
    test('a burst of header notifications runs the status check once', () async {
      await storeTx(kFixtureTxid, TransactionStatus.broadcast);
      arc.responses[kFixtureTxid] = ArcTransactionResponse.fromJson({'txid': kFixtureTxid, 'txStatus': 'STORED'});
      arc.delay = const Duration(milliseconds: 50);
      await spawnActor();

      for (var i = 0; i < 5; i++) {
        headersArrived();
      }
      await settleAfterArcCalls(1);
      await Future<void>.delayed(const Duration(milliseconds: 700));

      expect(arc.getTransactionCalls, 1, reason: 'five triggers in a burst must coalesce into one scan');
    });

    test('timer ticks never overlap a running scan', () async {
      await storeTx(kFixtureTxid, TransactionStatus.broadcast);
      arc.responses[kFixtureTxid] = ArcTransactionResponse.fromJson({'txid': kFixtureTxid, 'txStatus': 'STORED'});
      arc.delay = const Duration(milliseconds: 250);
      final wm = await system.spawn('wallet-manager', () => walletManager);
      arcActor = await system.spawn(
        'arc',
        () => ARCActor(
          walletManager: wm,
          storage: storage,
          arcService: arc,
          statusCheckInterval: const Duration(milliseconds: 20),
        ),
      );

      await Future<void>.delayed(const Duration(milliseconds: 900));

      expect(arc.maxInFlight, 1, reason: 'a tick that finds a scan running must be skipped');
      expect(arc.getTransactionCalls, inInclusiveRange(2, 4),
          reason: 'about one scan per 250 ms, not one per 20 ms tick');
    });

    test('notifications during a running scan fold into one follow-up scan', () async {
      await storeTx(kFixtureTxid, TransactionStatus.broadcast);
      arc.responses[kFixtureTxid] = ArcTransactionResponse.fromJson({'txid': kFixtureTxid, 'txStatus': 'STORED'});
      arc.delay = const Duration(milliseconds: 700);
      final wm = await system.spawn('wallet-manager', () => walletManager);
      arcActor = await system.spawn(
        'arc',
        () => ARCActor(
          walletManager: wm,
          storage: storage,
          arcService: arc,
          headerTriggerDebounce: const Duration(milliseconds: 10),
        ),
      );

      headersArrived();
      await settleAfterArcCalls(0);
      expect(arc.inFlight, 1, reason: 'first scan is running');
      for (var i = 0; i < 5; i++) {
        headersArrived();
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      await Future<void>.delayed(const Duration(milliseconds: 1500));

      expect(arc.maxInFlight, 1);
      expect(arc.getTransactionCalls, 2, reason: 'the running scan plus exactly one follow-up');
    });

    test('a pending transaction ARC does not know is not re-queried on the next scan', () async {
      await storeTx(kFixtureTxid, TransactionStatus.pending);
      await spawnActor();

      headersArrived();
      await settleAfterArcCalls(1);
      expect(arc.getTransactionCalls, 1);

      headersArrived();
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      expect(arc.getTransactionCalls, 1, reason: 'unknown-to-ARC pending transactions back off');
    });
  });
}

/// Records every proof write the actor makes to the read model.
class _ProofWriteRecordingStorage extends InMemoryWalletStorage {
  final List<String> proofWrites = [];

  @override
  Future<void> storeMerkleProof(String txid, MerkleProof proof) async {
    proofWrites.add(txid);
    await super.storeMerkleProof(txid, proof);
  }

  @override
  Future<bool> markMerkleProofOrphaned(String txid,
      {String? blockHash, List<String>? onlyIfMerkleProof, DateTime? at}) async {
    proofWrites.add('orphaned:$txid');
    return super.markMerkleProofOrphaned(txid,
        blockHash: blockHash, onlyIfMerkleProof: onlyIfMerkleProof, at: at);
  }
}

class _RecordingWalletManager extends Actor {
  final List<WalletCommand> commands = [];

  @override
  Future<void> onMessage(dynamic message) async {
    if (message is WalletCommandMessage) commands.add(message.command);
  }
}

class _FakeArc extends ArcService {
  _FakeArc() : super(baseUrl: 'fake://arc');

  final Map<String, ArcTransactionResponse> responses = {};
  Duration delay = Duration.zero;
  int getTransactionCalls = 0;
  int inFlight = 0;
  int maxInFlight = 0;

  @override
  Future<ArcTransactionResponse> getTransaction(String txid) async {
    getTransactionCalls++;
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    try {
      if (delay > Duration.zero) await Future<void>.delayed(delay);
      final response = responses[txid];
      if (response == null) throw ArcException('Failed to get transaction: {"status":404}');
      return response;
    } finally {
      inFlight--;
    }
  }
}
