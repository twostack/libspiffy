/// Bead libspiffy-z84j: money the wallet holds but cannot spend yet was
/// reported nowhere, so an application saw it as gone.
///
/// The same silence bead libspiffy-a5h8 found for reserved money, in the
/// same handler. `_handleGetBalance` counted the rows that are
/// `isAvailable || isReserved`, so a pending UTXO — the network is not
/// known to hold the transaction that pays it — fell out before any bucket
/// was computed. It is not in `confirmedBalance`, not in
/// `unconfirmedBalance`, not in `totalBalance`, not in `watchOnlyBalance`,
/// not in `reservedBalance`. Zero.
///
/// At its worst that is what an owner is shown after a reorganization. A
/// payment confirms; the block it was proven in leaves the active chain;
/// the wallet correctly takes the confirmation back and moves the UTXO from
/// available to pending, because an output whose proof left the chain
/// cannot be put in a BEEF anyone can verify (bead libspiffy-0lx); and the
/// balance API then says the money is gone, for as long as it takes a fresh
/// proof to arrive — measured on the localnet stack at between fifteen
/// seconds and over four minutes, gated on ARC's block processing.
///
/// It is reported as `pendingBalance` and kept out of `totalBalance`, the
/// treatment `reservedBalance` and `watchOnlyBalance` already have: the
/// wallet's own money, and not spendable.
library;

import 'dart:async';

import 'package:dactor/dactor.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:eventador/eventador.dart';
import 'package:test/test.dart';

import 'package:libspiffy/src/actors/coordinator_messages.dart' as coord;
import 'package:libspiffy/src/actors/wallet_coordinator_actor.dart';
import 'package:libspiffy/src/core/wallet_events.dart' as domain;
import 'package:libspiffy/src/models/address_metadata.dart';
import 'package:libspiffy/src/models/bitcoin_utxo.dart';
import 'package:libspiffy/src/projections/wallet_projection.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';
import 'package:libspiffy/src/storage/read_model_storage.dart';
import 'package:libspiffy/src/models/address_chain.dart';

const _w = 'z84j';
final _t0 = DateTime.utc(2026, 1, 1);
final _key = dartsv.SVPrivateKey.fromHex('11' * 32, dartsv.NetworkType.TEST).publicKey;
final _address = _key.toAddress(dartsv.NetworkType.TEST).toBase58();
final _stranger = dartsv.SVPrivateKey.fromHex('22' * 32, dartsv.NetworkType.TEST)
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
  Map<String, dynamic>? pluginMetadata,
}) =>
    BitcoinUtxo.create(
      txid: _txid(n),
      vout: 0,
      satoshis: BigInt.from(sats),
      scriptPubKey: _p2pkh(address ?? _address),
      address: address ?? _address,
      blockHeight: provenHeight,
      status: status,
      pluginMetadata: pluginMetadata,
      createdAt: _t0,
    );

void main() {
  late ActorSystem system;
  late InMemoryWalletStorage storage;
  late ActorRef ref;
  late List<coord.CoordinatorEvent> events;

  setUp(() async {
    system = LocalActorSystem();
    storage = InMemoryWalletStorage();
    await storage.storeWallet(_w, 'w', rootAddress: _address, networkType: 'testnet');
    final noop = await system.spawn('noop', () => _Noop());
    final coordinator = WalletCoordinatorActor(
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
    );
    events = [];
    final sub = coordinator.events.listen(events.add);
    addTearDown(sub.cancel);
    ref = await system.spawn('coordinator', () => coordinator);
  });

  tearDown(() async {
    await system.shutdown();
  });

  var queries = 0;

  Future<coord.BalanceResponse> balance() async {
    final queryId = 'q${queries++}';
    ref.tell(coord.GetBalanceQuery(walletId: _w, queryId: queryId));
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (DateTime.now().isBefore(deadline)) {
      final answered =
          events.whereType<coord.BalanceResponse>().where((e) => e.queryId == queryId);
      if (answered.isNotEmpty) return answered.first;
      final failed = events.whereType<coord.ErrorEvent>();
      if (failed.isNotEmpty) fail('the balance query failed: ${failed.first.message}');
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('no BalanceResponse within 5s');
  }

  test('money the network is not known to hold is reported, not lost', () async {
    await storage.upsertUTXO(_w, _utxo(1, 50000, status: UTXOStatus.pending, provenHeight: null));

    final answer = await balance();
    expect(answer.pendingBalance, BigInt.from(50000));
    expect((answer.confirmedBalance, answer.unconfirmedBalance, answer.totalBalance),
        (BigInt.zero, BigInt.zero, BigInt.zero),
        reason: 'it cannot be spent, so it is not part of the spendable balance');
  });

  test('a confirmation the chain took back leaves the money reported as pending', () async {
    // A payment of Bob's, confirmed: available, at a proven height.
    await storage.upsertUTXO(_w, _utxo(2, 50000));
    await storage.storeMerkleProof(
        _txid(2),
        MerkleProof(
          blockHash: '0' * 63 + '1',
          txid: _txid(2),
          merkleProof: const ['00'],
          position: 0,
          blockHeight: 900000,
        ));
    expect((await balance()).confirmedBalance, BigInt.from(50000));

    // The block it was proven in leaves the active chain.
    final projection = WalletProjection(
      projectionId: 'z84j-projection',
      eventStore: _NoopEventStore(),
      storage: storage,
    );
    await projection.handle(domain.TransactionConfirmationRevertedEvent(
      walletId: _w,
      txid: _txid(2),
      blockHeight: 900000,
      blockHash: '0' * 63 + '1',
      reason: 'reorganization at height 899999: blockOrphaned',
    ));

    final after = await balance();
    expect(after.confirmedBalance, BigInt.zero, reason: 'nothing proves it any more');
    expect(after.pendingBalance, BigInt.from(50000),
        reason: 'the money is the wallet\'s, waiting for a fresh proof, and an '
            'application must not be told it is gone');
  });

  test('pending money moves no other bucket', () async {
    await storage.upsertUTXO(_w, _utxo(3, 70000));
    await storage.upsertUTXO(_w, _utxo(4, 30000, provenHeight: null));
    await storage.upsertUTXO(_w, _utxo(5, 50000, status: UTXOStatus.pending, provenHeight: null));

    final answer = await balance();
    expect(answer.confirmedBalance, BigInt.from(70000));
    expect(answer.unconfirmedBalance, BigInt.from(30000));
    expect(answer.totalBalance, BigInt.from(100000));
    expect(answer.pendingBalance, BigInt.from(50000));
  });

  test('pending money at a watch address is not the wallet\'s to spend', () async {
    await storage.upsertAddress(_w, AddressMetadata(
      address: _stranger,
      scriptType: 'p2pkh',
      chain: AddressChain.receive,
      purpose: 'watch',
      usageCount: 0,
      balance: BigInt.zero,
      createdAt: _t0,
      isWatched: true,
    ));
    await storage.upsertUTXO(
        _w,
        _utxo(6, 50000,
            status: UTXOStatus.pending, provenHeight: null, address: _stranger));

    final answer = await balance();
    expect(answer.pendingBalance, BigInt.zero,
        reason: 'a watch-only output is reported as watch-only, pending or not');
  });

  test('a plugin\'s pending output is not the wallet\'s payment money', () async {
    await storage.upsertUTXO(
        _w,
        _utxo(7, 50000,
            status: UTXOStatus.pending,
            provenHeight: null,
            pluginMetadata: {'pluginId': 'token'}));

    expect((await balance()).pendingBalance, BigInt.zero);
  });

  test('a spent output is not pending money', () async {
    await storage.upsertUTXO(_w, _utxo(8, 50000, status: UTXOStatus.spent));

    final answer = await balance();
    expect(answer.pendingBalance, BigInt.zero);
    expect(answer.totalBalance, BigInt.zero);
  });
}

class _Noop extends Actor {
  @override
  Future<void> onMessage(dynamic message) async {}
}

class _NoopEventStore implements EventStore {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}
