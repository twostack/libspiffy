/// Bead libspiffy-5bju (2): ARCActor polls recently failed transactions.
///
/// `_checkNonTerminalTransactions` walks pending, broadcast, seenOnNetwork
/// and orphaned rows only, so nothing ever asked ARC about a transaction it
/// had reported REJECTED. But REJECTED is not the last word: a competing
/// spend can lose, the report can be stale, and the transaction can be mined
/// after all. Such a transaction was confirmed only if a proof happened to
/// arrive through SPV proof revival or the user issued an explicit
/// CheckDeferredPaymentStatusCommand.
///
/// The poll is speculative work on a terminal state, so it is bounded three
/// ways and the tests below hold it to all three: a recent window, a row cap,
/// and an interval much longer than the main scan. It never reads a wallet's
/// whole failed history — the old rows are neither read nor asked about.
///
/// And a MINED answer still proves nothing on its own (V-55): the
/// confirmation comes from a merkle path checked against our own headers.
library;

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

const _wallet = 'w-failed-poll';

void main() {
  late LocalActorSystem system;
  late _RecordingStorage storage;
  late _Recorder walletManager;
  late _PollArc arc;
  late ActorRef arcActor;
  late DateTime now;

  /// A failed row whose status last changed [ago] before now.
  Future<void> storeFailed(String txid, Duration ago, {String rawHex = '0100000000000000000000'}) =>
      storage.storeTransaction(
        _wallet,
        BitcoinTransaction(
          walletId: _wallet,
          txid: txid,
          rawHex: rawHex,
          status: TransactionStatus.failed,
          inputValue: BigInt.zero,
          outputValue: BigInt.zero,
          fee: BigInt.zero,
          receivingAddresses: const [],
          sendingAddresses: const [],
          netAmount: BigInt.zero,
          createdAt: DateTime.now().subtract(ago),
          updatedAt: DateTime.now().subtract(ago),
          lockTime: 0,
          version: 1,
        ),
      );

  ArcTransactionResponse minedResponse(String txid, {String? merklePath}) => ArcTransactionResponse.fromJson({
        'timestamp': '2026-09-16T08:00:00Z',
        'txid': txid,
        'txStatus': 'MINED',
        'blockHash': kFixtureBlockHash,
        'blockHeight': kFixtureHeight,
        if (merklePath != null) 'merklePath': merklePath,
      });

  Future<void> spawnActor({
    Duration failedCheckInterval = const Duration(minutes: 30),
    Duration failedCheckWindow = const Duration(days: 7),
    int failedCheckLimit = 25,
  }) async {
    final wm = await system.spawn('wallet-manager', () => walletManager);
    arcActor = await system.spawn(
      'arc',
      () => ARCActor(
        walletManager: wm,
        storage: storage,
        arcService: arc,
        // Long enough that the periodic timer never fires in a test; scans
        // are driven by the header notification below.
        statusCheckInterval: const Duration(minutes: 30),
        headerTriggerDebounce: const Duration(milliseconds: 10),
        failedCheckInterval: failedCheckInterval,
        failedCheckWindow: failedCheckWindow,
        failedCheckLimit: failedCheckLimit,
        clock: () => now,
      ),
    );
    // Let preStart finish before the first scan.
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }

  /// One scan, waited for.
  Future<void> scan() async {
    arcActor.tell(CheckStoragePendingUTXOsMessage(triggerBlockHeight: kFixtureHeight));
    await Future<void>.delayed(const Duration(milliseconds: 400));
  }

  List<ConfirmTransactionCommand> confirms() =>
      walletManager.commands.whereType<ConfirmTransactionCommand>().toList();

  setUp(() {
    system = LocalActorSystem(ActorSystemConfig());
    storage = _RecordingStorage();
    walletManager = _Recorder();
    arc = _PollArc();
    now = DateTime.utc(2026, 9, 16, 10);
  });

  tearDown(() => system.shutdown());

  test('a failed transaction that is mined after all is confirmed by the poll, from a proof that matches '
      'our headers', () async {
    await storage.storeBlockHeader(fixtureHeader(), kFixtureHeight);
    await storeFailed(kFixtureTxid, const Duration(minutes: 5), rawHex: kFixtureTxHex);
    arc.statusResponses[kFixtureTxid] = minedResponse(kFixtureTxid, merklePath: fixtureBumpHex());
    await spawnActor();

    await scan();

    expect(arc.queried, [kFixtureTxid], reason: 'the failed row was never polled');
    expect(confirms().map((c) => (c.txid, c.blockHeight, c.blockHash, c.bumpHex)), [
      (kFixtureTxid, kFixtureHeight, kFixtureBlockHash, fixtureBumpHex()),
    ]);
  });

  test('a MINED answer without a proof that matches our headers confirms nothing', () async {
    // The header we hold at that height is another block.
    await storage.storeBlockHeader(otherHeaderAtFixtureHeight(), kFixtureHeight);
    await storeFailed(kFixtureTxid, const Duration(minutes: 5), rawHex: kFixtureTxHex);
    arc.statusResponses[kFixtureTxid] = minedResponse(kFixtureTxid, merklePath: fixtureBumpHex());
    await spawnActor();

    await scan();

    expect(arc.queried, [kFixtureTxid]);
    expect(confirms(), isEmpty, reason: 'ARC\'s MINED outranked our own header chain');
  });

  test('the poll is bounded: only the recent window is read, capped, in one indexed query — never every '
      'failed row', () async {
    // Forty failed rows: three in the window, thirty-seven long past it.
    final recent = [for (var i = 0; i < 3; i++) _txid(0xa0 + i)];
    final old = [for (var i = 0; i < 37; i++) _txid(0x10 + i)];
    for (final txid in old) {
      await storeFailed(txid, const Duration(days: 30));
    }
    for (final txid in recent) {
      await storeFailed(txid, const Duration(minutes: 5));
    }
    await spawnActor(failedCheckWindow: const Duration(days: 1), failedCheckLimit: 10);

    await scan();

    // One bounded query, with the window and the cap the actor was given.
    expect(storage.sinceQueries, hasLength(1));
    final (status, since, limit) = storage.sinceQueries.single;
    expect(status, TransactionStatus.failed);
    expect(limit, 10);
    expect(since.isAfter(DateTime.now().subtract(const Duration(days: 2))), isTrue,
        reason: 'the window must be recent, not the whole history: $since');

    // And never the unbounded read of every failed row.
    expect(storage.statusQueries, isNot(contains(TransactionStatus.failed)),
        reason: 'the poll read every failed row ever stored');
    expect(storage.rowsFromSince, 3, reason: 'rows outside the window must not be read');
    expect(arc.queried.toSet(), recent.toSet());
    expect(arc.queried.toSet().intersection(old.toSet()), isEmpty,
        reason: 'a transaction that failed a month ago was polled');
  });

  test('the row cap holds when more rows than it fit in the window', () async {
    final txids = [for (var i = 0; i < 12; i++) _txid(0xb0 + i)];
    for (final txid in txids) {
      await storeFailed(txid, const Duration(minutes: 5));
    }
    await spawnActor(failedCheckLimit: 4);

    await scan();

    expect(storage.rowsFromSince, 4);
    expect(arc.queried, hasLength(4));
    expect(txids.toSet().containsAll(arc.queried), isTrue);
  });

  test('the poll runs at most once per interval, however many scans there are, and again after it', () async {
    await storeFailed(kFixtureTxid, const Duration(minutes: 5), rawHex: kFixtureTxHex);
    await spawnActor(failedCheckInterval: const Duration(minutes: 30));

    await scan();
    expect(storage.sinceQueries, hasLength(1));

    // Several more scans well inside the interval.
    now = now.add(const Duration(minutes: 29));
    await scan();
    await scan();
    expect(storage.sinceQueries, hasLength(1),
        reason: 'the failed poll must not run on every status scan');

    // Past the interval it runs again.
    now = now.add(const Duration(minutes: 2));
    await scan();
    expect(storage.sinceQueries, hasLength(2));
  });

  test('a zero row cap turns the poll off', () async {
    await storeFailed(kFixtureTxid, const Duration(minutes: 5), rawHex: kFixtureTxHex);
    await spawnActor(failedCheckLimit: 0);

    await scan();

    expect(storage.sinceQueries, isEmpty);
    expect(arc.queried, isEmpty);
  });
}

String _txid(int seed) => List<int>.generate(32, (i) => (seed + i) & 0xff)
    .map((b) => b.toRadixString(16).padLeft(2, '0'))
    .join();

/// Records which transaction queries the actor issues, and how many rows the
/// bounded feed returned.
class _RecordingStorage extends InMemoryWalletStorage {
  final List<(TransactionStatus, DateTime, int)> sinceQueries = [];
  final List<TransactionStatus> statusQueries = [];
  int rowsFromSince = 0;

  @override
  Future<List<BitcoinTransaction>> getTransactionsByStatusSince(
    TransactionStatus status,
    DateTime since, {
    int limit = 100,
  }) async {
    sinceQueries.add((status, since, limit));
    final rows = await super.getTransactionsByStatusSince(status, since, limit: limit);
    rowsFromSince += rows.length;
    return rows;
  }

  @override
  Future<List<BitcoinTransaction>> getTransactionsByStatus(TransactionStatus status, {String? walletId}) {
    statusQueries.add(status);
    return super.getTransactionsByStatus(status, walletId: walletId);
  }
}

class _PollArc extends ArcService {
  _PollArc() : super(baseUrl: 'fake://arc');

  final Map<String, ArcTransactionResponse> statusResponses = {};
  final List<String> queried = [];

  @override
  Future<ArcTransactionResponse> getTransaction(String txid) async {
    queried.add(txid);
    final response = statusResponses[txid];
    if (response == null) throw ArcException('Failed to get transaction: {"status":404}');
    return response;
  }
}

class _Recorder extends Actor {
  final List<WalletCommand> commands = [];

  @override
  Future<void> onMessage(dynamic message) async {
    if (message is WalletCommandMessage) commands.add(message.command);
  }
}
