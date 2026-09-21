/// Bead libspiffy-wyxn: what ARCActor's status scan reads on the in-memory
/// backend.
///
/// The scan asks storage for the pending, broadcast, seen-on-network and
/// orphaned rows -- four `getTransactionsByStatus` calls -- and the in-memory
/// backend answered each by filtering every row of every wallet. A wallet
/// with a long settled history paid for all of it four times on every scan,
/// every 30 seconds, to find the handful of transactions still in flight.
/// The backend already kept a status index (for the failed-row poll, bead
/// libspiffy-5bju); the status query now walks it.
///
/// Observed as rows read (`InMemoryWalletStorage.transactionRowsRead`),
/// never as time.
library;

import 'package:dactor/dactor.dart';
import 'package:test/test.dart';

import 'package:libspiffy/src/actors/arc_actor.dart';
import 'package:libspiffy/src/actors/wallet_messages.dart';
import 'package:libspiffy/src/models/bitcoin_transaction.dart';
import 'package:libspiffy/src/services/arc_service.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';

const _settled = 300;

void main() {
  late LocalActorSystem system;
  late InMemoryWalletStorage storage;

  BitcoinTransaction row(String walletId, String txid, TransactionStatus status, int n) => BitcoinTransaction(
        walletId: walletId,
        txid: txid,
        rawHex: '',
        status: status,
        blockHeight: status == TransactionStatus.confirmed ? 1000 + n : null,
        inputValue: BigInt.zero,
        outputValue: BigInt.zero,
        fee: BigInt.zero,
        receivingAddresses: const [],
        sendingAddresses: const [],
        netAmount: BigInt.zero,
        createdAt: DateTime(2026, 1, 1).add(Duration(minutes: n)),
        updatedAt: DateTime(2026, 1, 1).add(Duration(minutes: n)),
      );

  String txid(int n) => n.toRadixString(16).padLeft(64, '0');

  setUp(() async {
    system = LocalActorSystem(ActorSystemConfig());
    storage = InMemoryWalletStorage();
    // Two wallets with a long settled history, and three transactions in
    // flight between them.
    for (var n = 0; n < _settled; n++) {
      await storage.storeTransaction(n.isEven ? 'a' : 'b', row(n.isEven ? 'a' : 'b', txid(n), TransactionStatus.confirmed, n));
    }
    await storage.storeTransaction('a', row('a', txid(1000), TransactionStatus.pending, 1000));
    await storage.storeTransaction('b', row('b', txid(1001), TransactionStatus.broadcast, 1001));
    await storage.storeTransaction('a', row('a', txid(1002), TransactionStatus.seenOnNetwork, 1002));
  });

  tearDown(() => system.shutdown());

  test('wyxn: a status scan reads the transactions in flight, not the settled history', () async {
    final arc = _CountingArc();
    final walletManager = await system.spawn('wallet-manager', () => _Silent());
    final arcActor = await system.spawn(
      'arc',
      () => ARCActor(
        walletManager: walletManager,
        storage: storage,
        arcService: arc,
        statusCheckInterval: const Duration(minutes: 30),
        failedCheckInterval: const Duration(minutes: 30),
        failedCheckLimit: 0,
      ),
    );
    final before = storage.transactionRowsRead;

    arcActor.tell(CheckStoragePendingUTXOsMessage(triggerBlockHeight: 1));
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (arc.asked.length < 3 && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(arc.asked.toSet(), {txid(1000), txid(1001), txid(1002)},
        reason: 'the scan still finds every transaction in flight');
    // Old code: 4 statuses x 303 rows = 1212.
    expect(storage.transactionRowsRead - before, 3);
  });

  test('wyxn: the status query answers from the index as it did from the rows', () async {
    // A row that changes status leaves its old status's answer.
    await storage.storeTransaction('a', row('a', txid(1000), TransactionStatus.broadcast, 1003));

    expect([for (final tx in await storage.getTransactionsByStatus(TransactionStatus.pending)) tx.txid], isEmpty);
    expect([for (final tx in await storage.getTransactionsByStatus(TransactionStatus.broadcast)) tx.txid],
        [txid(1000), txid(1001)],
        reason: 'newest first (createdAt descending; the re-stored row is the newer)');
    expect([
      for (final tx in await storage.getTransactionsByStatus(TransactionStatus.broadcast, walletId: 'a')) tx.txid
    ], [txid(1000)]);
    expect((await storage.getTransactionsByStatus(TransactionStatus.confirmed)).length, _settled);

    await storage.deleteWallet('b');
    expect([for (final tx in await storage.getTransactionsByStatus(TransactionStatus.broadcast)) tx.txid],
        [txid(1000)], reason: 'a deleted wallet\'s rows are gone from the index');
  });
}

/// ARC that records which transactions it is asked about.
class _CountingArc extends ArcService {
  _CountingArc() : super(baseUrl: 'fake://arc');

  final List<String> asked = [];

  @override
  Future<ArcTransactionResponse> getTransaction(String txid) async {
    asked.add(txid);
    throw ArcException('Failed to get transaction: {"status":404}', statusCode: 404);
  }
}

class _Silent extends Actor {
  @override
  Future<void> onMessage(dynamic message) async {}
}
