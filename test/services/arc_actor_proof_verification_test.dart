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
import 'package:libspiffy/src/actors/wallet_messages.dart';
import 'package:libspiffy/src/core/wallet_commands.dart';
import 'package:libspiffy/src/models/bitcoin_transaction.dart';
import 'package:libspiffy/src/services/arc_service.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';
import 'package:test/test.dart';

import '../spv/testnet_proof_fixture.dart';

const _wallet = 'w';

void main() {
  late LocalActorSystem system;
  late InMemoryWalletStorage storage;
  late _RecordingWalletManager walletManager;
  late _FakeArc arc;
  late ActorRef arcActor;

  Future<void> storeTx(String txid, TransactionStatus status, {String rawHex = ''}) =>
      storage.storeTransaction(
        _wallet,
        BitcoinTransaction(
          walletId: _wallet,
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
    storage = InMemoryWalletStorage();
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

      final proof = await storage.getMerkleProof(kFixtureTxid);
      expect(proof, isNotNull);
      expect(proof!.merkleProof, equals([fixtureBumpHex()]));
      expect(proof.position, kFixtureIndex, reason: 'position is the txid offset in the block');
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
