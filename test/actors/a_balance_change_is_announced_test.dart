/// Bead libspiffy-7ye4: an app is told when its balance changes.
///
/// `BalanceUpdatedEvent` was exported and nothing in the library ever
/// constructed it, so the only way an application could learn that money had
/// arrived, been spent, been reserved or lost its proof was to send
/// `GetBalanceQuery` again and compare two answers. That is polling, and
/// between two polls a change is invisible.
///
/// It is announced from the events the wallet read model applied (V-153's
/// `readModelEvents`), like the confirmation and the reverted confirmation
/// before it, so a balance an app hears about is one the read model already
/// holds.
///
/// The numbers are the ones `GetBalanceQuery` answers with, from the one
/// computation (`WalletCoordinatorActor._balancesOf`). The event used to
/// declare only confirmed, unconfirmed and total, which would have left out
/// the wallet's reserved, watch-only and pending funds — exactly the money
/// beads libspiffy-a5h8, libspiffy-87a2 and libspiffy-z84j each found
/// reported nowhere. An app must not be told one balance by the event and a
/// different one by the query.
library;

import 'dart:async';

import 'package:dactor/dactor.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:eventador/eventador.dart';
import 'package:test/test.dart';

import 'package:libspiffy/src/actors/coordinator_messages.dart';
import 'package:libspiffy/src/actors/wallet_coordinator_actor.dart';
import 'package:libspiffy/src/core/wallet_events.dart' as domain;
import 'package:libspiffy/src/models/address_metadata.dart';
import 'package:libspiffy/src/models/bitcoin_utxo.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';
import 'package:libspiffy/src/models/address_chain.dart';

const _walletId = 'wallet-7ye4';
final _t0 = DateTime.utc(2026, 1, 1);
final _address = dartsv.SVPrivateKey.fromHex('33' * 32, dartsv.NetworkType.TEST)
    .publicKey
    .toAddress(dartsv.NetworkType.TEST)
    .toBase58();
final _stranger = dartsv.SVPrivateKey.fromHex('44' * 32, dartsv.NetworkType.TEST)
    .publicKey
    .toAddress(dartsv.NetworkType.TEST)
    .toBase58();

String _txid(int n) => n.toRadixString(16).padLeft(64, '0');

String _p2pkh(String address) =>
    dartsv.P2PKHLockBuilder.fromAddress(dartsv.Address.fromBase58(address))
        .getScriptPubkey()
        .toHex();

BitcoinUtxo _utxo(
  int n,
  int sats, {
  UTXOStatus status = UTXOStatus.available,
  int? provenHeight = 900000,
  String? address,
}) =>
    BitcoinUtxo.create(
      txid: _txid(n),
      vout: 0,
      satoshis: BigInt.from(sats),
      scriptPubKey: _p2pkh(address ?? _address),
      address: address ?? _address,
      blockHeight: provenHeight,
      status: status,
      createdAt: _t0,
    );

/// A domain event of a kind the wallet read model recalculates balances for.
/// Which one it is does not matter to any test here — what the balance
/// became is read from the rows — so one stands for all of them.
domain.UTXOReceivedEvent _received(int n) => domain.UTXOReceivedEvent(
      walletId: _walletId,
      txid: _txid(n),
      vout: 0,
      satoshis: 1,
      scriptPubKey: _p2pkh(_address),
      address: _address,
    );

void main() {
  late ActorSystem actorSystem;
  late _StaggeredStorage storage;
  late StreamController<Event> readModel;
  late List<CoordinatorEvent> announced;
  late StreamSubscription<CoordinatorEvent> sub;
  late ActorRef coordinatorRef;
  late WalletCoordinatorActor coordinator;

  setUp(() async {
    actorSystem = LocalActorSystem();
    storage = _StaggeredStorage();
    await storage.storeWallet(_walletId, 'w',
        rootAddress: _address, networkType: 'testnet');
    readModel = StreamController<Event>.broadcast();
    announced = [];

    final noop = await actorSystem.spawn('noop', () => _Noop());
    coordinator = WalletCoordinatorActor(
      walletManager: noop,
      invoiceCoordinator: noop,
      paymentCoordinator: noop,
      spvActor: noop,
      arcActor: noop,
      headerSyncActor: noop,
      benfordCoordinator: noop,
      channelManager: noop,
      walletProjection: noop,
      storage: storage,
      readModelEvents: readModel.stream,
    );
    sub = coordinator.events.listen(announced.add);
    coordinatorRef = await actorSystem.spawn('coordinator', () => coordinator);
  });

  tearDown(() async {
    await sub.cancel();
    await readModel.close();
    await actorSystem.shutdown();
  });

  /// Pushes [event] onto the read model's applied events and returns the
  /// balances announced because of it, once the coordinator has had a turn.
  Future<List<BalanceUpdatedEvent>> announce(Event event) async {
    final before = announced.whereType<BalanceUpdatedEvent>().length;
    readModel.add(event);
    final deadline = DateTime.now().add(const Duration(milliseconds: 500));
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final now = announced.whereType<BalanceUpdatedEvent>().toList();
      if (now.length > before) return now.skip(before).toList();
    }
    return const [];
  }

  var queries = 0;

  /// What [GetBalanceQuery] answers right now.
  Future<BalanceResponse> queried() async {
    final queryId = 'q${queries++}';
    coordinatorRef.tell(GetBalanceQuery(walletId: _walletId, queryId: queryId));
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (DateTime.now().isBefore(deadline)) {
      final answered = announced
          .whereType<BalanceResponse>()
          .where((e) => e.queryId == queryId);
      if (answered.isNotEmpty) return answered.first;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('no BalanceResponse within 5s');
  }

  test('money the read model credited is announced, unasked', () async {
    await storage.upsertUTXO(_walletId, _utxo(1, 70000));

    final updated = (await announce(_received(1))).single;
    expect(updated.walletId, _walletId);
    expect(updated.confirmedBalance, BigInt.from(70000));
    expect(updated.totalBalance, BigInt.from(70000));
  });

  test('the event says what the query would say', () async {
    // One UTXO in each bucket the balance API reports apart, so a number
    // dropped from the announcement cannot pass unnoticed.
    await storage.upsertAddress(
        _walletId,
        AddressMetadata(
          address: _stranger,
          scriptType: 'p2pkh',
          chain: AddressChain.receive,
          purpose: 'watch',
          usageCount: 0,
          balance: BigInt.zero,
          createdAt: _t0,
          isWatched: true,
        ));
    await storage.upsertUTXO(_walletId, _utxo(2, 70000));
    await storage.upsertUTXO(_walletId, _utxo(3, 30000, provenHeight: null));
    await storage.upsertUTXO(_walletId, _utxo(4, 11000, status: UTXOStatus.reserved));
    await storage.upsertUTXO(_walletId,
        _utxo(5, 50000, status: UTXOStatus.pending, provenHeight: null));
    await storage.upsertUTXO(_walletId, _utxo(6, 9000, address: _stranger));

    final updated = (await announce(_received(2))).single;
    final answer = await queried();
    expect(
      (
        updated.confirmedBalance,
        updated.unconfirmedBalance,
        updated.totalBalance,
        updated.pendingBalance,
        updated.watchOnlyBalance,
        updated.reservedBalance,
      ),
      (
        answer.confirmedBalance,
        answer.unconfirmedBalance,
        answer.totalBalance,
        answer.pendingBalance,
        answer.watchOnlyBalance,
        answer.reservedBalance,
      ),
      reason: 'an app must not be told one balance by the event and another '
          'by the query',
    );
    expect(updated.reservedBalance, BigInt.from(11000));
    expect(updated.watchOnlyBalance, BigInt.from(9000));
    expect(updated.pendingBalance, BigInt.from(50000));
    expect(updated.totalBalance, BigInt.from(100000));
  });

  test('an event that leaves the money alone is silent', () async {
    await storage.upsertUTXO(_walletId, _utxo(7, 70000));
    expect(await announce(_received(7)), hasLength(1));

    expect(await announce(_received(7)), isEmpty,
        reason: 'nothing moved, so there is nothing to announce');
  });

  test('a wallet that holds nothing is not announced', () async {
    expect(await announce(_received(8)), isEmpty,
        reason: 'an app already assumes zero of a wallet it has heard nothing '
            'about; a zero announcement tells it nothing');
  });

  test('a confirmation the chain took back is announced as a balance change',
      () async {
    await storage.upsertUTXO(_walletId, _utxo(9, 50000));
    expect((await announce(_received(9))).single.confirmedBalance,
        BigInt.from(50000));

    // What the read model does on a revert: the proven height comes off and
    // the output stops being spendable (bead libspiffy-0lx).
    await storage.upsertUTXO(_walletId,
        _utxo(9, 50000, status: UTXOStatus.pending, provenHeight: null));

    final updated = (await announce(domain.TransactionConfirmationRevertedEvent(
      walletId: _walletId,
      txid: _txid(9),
      blockHeight: 900000,
      reason: 'reorganization at height 899999: blockOrphaned',
    )))
        .single;
    expect(updated.confirmedBalance, BigInt.zero);
    expect(updated.totalBalance, BigInt.zero);
    expect(updated.pendingBalance, BigInt.from(50000),
        reason: 'the money is the wallet\'s, waiting for a fresh proof');
  });

  test('balances are announced in the order the read model moved them',
      () async {
    // Each announcement reads the wallet's UTXO rows, so two that overlap can
    // finish in either order. Here the first read holds its rows for 300ms
    // before answering while the second answers at once, which is the order
    // that would have an application shown its older balance last.
    storage.holdRowsFor = [const Duration(milliseconds: 300)];
    await storage.upsertUTXO(_walletId, _utxo(10, 10000));
    readModel.add(_received(10));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await storage.upsertUTXO(_walletId, _utxo(11, 20000));
    readModel.add(_received(11));

    await Future<void>.delayed(const Duration(milliseconds: 700));
    expect(
        announced.whereType<BalanceUpdatedEvent>().map((e) => e.totalBalance),
        [BigInt.from(10000), BigInt.from(30000)],
        reason: 'an announcement that started earlier reports first, so the '
            'last balance an app hears is the balance the wallet holds');
  });

  test('shutdown waits for a balance that is being read', () async {
    // The read runs off the mailbox and the host closes its storage once
    // `LibSpiffyActorSystem.shutdown` returns. With Isar a read that lands in
    // a closed store is a native segmentation fault that takes the process
    // down — not an exception anything can catch — which is how this was
    // found: every suite after the one that shut down first was skipped.
    storage.holdRowsFor = [const Duration(milliseconds: 300)];
    await storage.upsertUTXO(_walletId, _utxo(14, 40000));
    readModel.add(_received(14));
    while (storage.readsInFlight == 0) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }

    await coordinator.stopAnnouncements();
    final inFlight = storage.readsInFlight;

    expect(inFlight, 0,
        reason: 'shutdown returned while a read was still running, and the '
            'store is closed next');
    // The event stream delivers in a later turn than the announcement.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(announced.whereType<BalanceUpdatedEvent>().single.totalBalance,
        BigInt.from(40000),
        reason: 'the read that was already running still reports');
  });

  test('nothing is read after shutdown has waited', () async {
    await storage.upsertUTXO(_walletId, _utxo(15, 40000));
    await announce(_received(15));
    await coordinator.stopAnnouncements();
    final reads = storage.reads;

    await storage.upsertUTXO(_walletId, _utxo(16, 60000));
    expect(await announce(_received(16)), isEmpty);
    expect(storage.reads, reads,
        reason: 'a balance read after shutdown lands in a closed store');
  });

  test('an event of a kind that cannot move money is not read', () async {
    await storage.upsertUTXO(_walletId, _utxo(13, 70000));

    expect(
        await announce(domain.AddressLabelUpdatedEvent(
          walletId: _walletId,
          address: _address,
          newLabel: 'rent',
        )),
        isEmpty,
        reason: 'a label is not money: reading every wallet UTXO to find that '
            'out is work the read model deliberately skips too');
  });
}

class _Noop extends Actor {
  @override
  Future<void> onMessage(dynamic message) async {}
}

/// Storage whose first reads hold the rows they read before answering.
///
/// The rows are taken before the delay, so `_balancesOf` sees the state at
/// the moment its read started rather than the state at the moment it was
/// answered — which is what makes an overtaking announcement stale.
class _StaggeredStorage extends InMemoryWalletStorage {
  /// How long each successive [getUTXOs] holds its rows; reads past the end
  /// of this list answer at once.
  List<Duration> holdRowsFor = const [];

  /// Reads started, and reads started but not yet answered.
  int reads = 0;
  int readsInFlight = 0;

  @override
  Future<List<BitcoinUtxo>> getUTXOs(String walletId,
      {bool includeSpent = false}) async {
    final hold = reads < holdRowsFor.length ? holdRowsFor[reads] : Duration.zero;
    reads++;
    readsInFlight++;
    try {
      final rows = await super.getUTXOs(walletId, includeSpent: includeSpent);
      if (hold > Duration.zero) await Future<void>.delayed(hold);
      return rows;
    } finally {
      readsInFlight--;
    }
  }
}
