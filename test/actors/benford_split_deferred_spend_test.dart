/// Bead libspiffy-ypp: BenfordCoordinatorActor lost track of a split.
///
/// * It told ARCActor to broadcast the split before the wallet had recorded
///   it: a broadcast that reaches miners while the recording fails (or the
///   process stops) spends the wallet's coin with no record of where it went.
/// * It spent the source UTXO at once (SpendUTXOCommand) instead of deferring
///   the spend like every other payment (V-16: applied when ARC reports the
///   transaction on the network): a split ARC rejects left the coin spent.
/// * It read the wallet type (and the UTXOs) from the read model, which lags
///   the wallet's journal: a split right after the wallet was created through
///   the wallet manager was refused with "Wallet not found".
///
/// Now the split is recorded with a deferred spend (the wallet holds the
/// source, as for any deferred payment) and broadcast only once the wallet
/// has journaled it; ARC's answer settles the hold (SEEN_ON_NETWORK spends
/// it, REJECTED releases it). Wallet type and splittable UTXOs come from the
/// wallet aggregate through WalletManagerActor.
///
/// No wallet projection runs: the read model knows nothing unless a test
/// seeds it, the limit of a lagging projection.
library;

import 'dart:async';

import 'package:dactor/dactor.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:eventador/eventador.dart';
import 'package:libspiffy/src/actors/arc_actor.dart';
import 'package:libspiffy/src/actors/benford_coordinator_actor.dart';
import 'package:libspiffy/src/actors/wallet_manager_actor.dart';
import 'package:libspiffy/src/actors/wallet_messages.dart';
import 'package:libspiffy/src/core/wallet_commands.dart';
import 'package:libspiffy/src/core/wallet_events.dart';
import 'package:libspiffy/src/models/bitcoin_utxo.dart';
import 'package:libspiffy/src/services/arc_service.dart';
import 'package:libspiffy/src/services/dartsv_crypto_service.dart';
import 'package:libspiffy/src/storage/in_memory_secure_storage.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';
import 'package:test/test.dart';

import 'in_memory_event_store.dart';

const _xpriv =
    'tprv8ZgxMBicQKsPeMiDjtXBGAyFY1wEMGgomjwf54ZmiZfKTNYvVdBa6GqWUwnvtHm6NKVkQkhCKxaobd9JPxNEXgDfVgJ5RNHJ3ivogSG3V1R';
const _walletId = 'benford-ypp';
final _sourceTxid = 'a1' * 32;
final _sourceKey = '$_sourceTxid:0';
const _wait = Duration(seconds: 10);

void main() {
  late LocalActorSystem system;
  late InMemoryEventStore eventStore;
  late InMemoryWalletStorage readModel;
  late _ObservingArc arc;
  late ActorRef walletManager;
  late ActorRef benford;

  setUp(() async {
    system = LocalActorSystem(ActorSystemConfig());
    eventStore = InMemoryEventStore();
    readModel = InMemoryWalletStorage();
    arc = _ObservingArc(eventStore);
    walletManager = await system.spawn(
      'wallet-manager',
      () => WalletManagerActor(
        eventStore: eventStore,
        cryptoService: DartSVCryptoService(),
        secureStorage: InMemorySecureStorage(),
        aggregateIdleTimeout: null,
        readModelStorage: readModel,
      ),
    );
    final arcActor = await system.spawn(
      'arc',
      () => ARCActor(
        walletManager: walletManager,
        storage: readModel,
        arcService: arc,
        statusCheckInterval: const Duration(minutes: 10),
      ),
    );
    benford = await system.spawn(
      'benford',
      () => BenfordCoordinatorActor(walletManager: walletManager, arcActor: arcActor, storage: readModel),
    );
  });

  tearDown(() => system.shutdown());

  List<Event> journal() => eventStore.journal['BitcoinWallet_$_walletId'] ?? const [];

  /// Creates the wallet and gives it one 100 000 sat UTXO at a generated
  /// address, each step acknowledged by the wallet aggregate.
  Future<String> walletWithOneUtxo() async {
    final created = await walletManager.ask<WalletCreatedMessage>(
      CreateWalletMessage(_walletId, 'Benford', xpriv: _xpriv),
      _wait,
    );
    expect(created.success, isTrue, reason: created.error);
    final generated = await walletManager.ask<AddressGeneratedResponse>(
      WalletCommandMessage(_walletId, GenerateAddressCommand(walletId: _walletId)),
      _wait,
    );
    expect(generated.success, isTrue, reason: generated.error);
    final address = generated.address;
    final received = await walletManager.ask<UTXOReceivedResponse>(
      WalletCommandMessage(
        _walletId,
        ReceiveUTXOCommand(
          walletId: _walletId,
          txid: _sourceTxid,
          vout: 0,
          satoshis: BigInt.from(100000),
          scriptPubKey: dartsv.P2PKHLockBuilder.fromAddress(dartsv.Address(address)).getScriptPubkey().toHex(),
          address: address,
          blockHeight: 100,
          confirmations: 6,
          initialStatus: UTXOStatus.available,
        ),
      ),
      _wait,
    );
    expect(received.success, isTrue, reason: received.error);
    return address;
  }

  /// The read model as a projection that has caught up would show it.
  Future<void> seedReadModel(String address) async {
    await readModel.storeWallet(_walletId, 'Benford', networkType: 'testnet', metadata: {'walletType': 'hd'});
    await readModel.upsertUTXO(
      _walletId,
      BitcoinUtxo.create(
        txid: _sourceTxid,
        vout: 0,
        satoshis: BigInt.from(100000),
        scriptPubKey: dartsv.P2PKHLockBuilder.fromAddress(dartsv.Address(address)).getScriptPubkey().toHex(),
        address: address,
        status: UTXOStatus.available,
      ),
    );
  }

  Future<SplitUTXOsResponse> split() => benford.ask<SplitUTXOsResponse>(
        SplitUTXOsToBenfordCommand(walletId: _walletId, targetUtxoCount: 3, feeRate: BigInt.one),
        const Duration(seconds: 40),
      );

  Future<void> until(bool Function() condition, String what) async {
    final deadline = DateTime.now().add(_wait);
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) fail('Timed out waiting for $what');
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  test('a split right after the wallet was created through the wallet manager is not refused', () async {
    await walletWithOneUtxo();

    final response = await split();

    // Old code: 'Wallet not found: benford-ypp' (the read model had no row).
    expect(response.success, isTrue, reason: response.error);
    expect(response.txids, hasLength(1));
  });

  test('the split is recorded, its source held, before the broadcast is attempted', () async {
    final address = await walletWithOneUtxo();
    await seedReadModel(address);

    final response = await split();
    expect(response.success, isTrue, reason: response.error);
    await until(() => arc.submissions.isNotEmpty, 'the broadcast');

    final submission = arc.submissions.single;
    expect(submission.txid, response.txids!.single);
    // Old code: broadcast first, recorded afterwards.
    expect(submission.recordedAtBroadcast, isTrue, reason: 'broadcast before the wallet recorded the split');
    expect(submission.heldAtBroadcast, isTrue, reason: 'the source was not held as a deferred spend');
    expect(journal().whereType<UTXOSpentEvent>().where((e) => '${e.txid}:${e.vout}' == _sourceKey), isEmpty,
        reason: 'the source is spent only when ARC reports the split on the network');
  });

  test('a split ARC rejects leaves the source spendable', () async {
    final address = await walletWithOneUtxo();
    await seedReadModel(address);
    arc.submitStatus = 'REJECTED';

    final response = await split();
    expect(response.success, isTrue, reason: response.error);
    final txid = response.txids!.single;
    final deadline = DateTime.now().add(_wait);
    while (!journal().any((e) => e is DeferredTransactionFailedEvent && e.txid == txid) &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }

    // Old code: the source was spent before ARC answered, and stayed spent.
    final reserved = await walletManager.ask<UTXOReservedResponse>(
      WalletCommandMessage(
        _walletId,
        ReserveUTXOCommand(walletId: _walletId, utxoKey: _sourceKey, reservedByTxId: 'next-payment'),
      ),
      _wait,
    );
    expect(reserved.success, isTrue, reason: reserved.error);
    expect(journal().whereType<UTXOSpentEvent>(), isEmpty);
  });
}

/// One submission ARC received, and what the wallet journal held then.
class _Submission {
  final String txid;
  final bool recordedAtBroadcast;
  final bool heldAtBroadcast;
  _Submission(this.txid, this.recordedAtBroadcast, this.heldAtBroadcast);
}

/// ARC without a network that looks at the wallet journal when a
/// transaction is submitted.
class _ObservingArc extends ArcService {
  final InMemoryEventStore store;
  _ObservingArc(this.store) : super(baseUrl: 'fake://arc');

  final List<_Submission> submissions = [];
  String submitStatus = 'SEEN_ON_NETWORK';

  @override
  Future<ArcSubmitResponse> submitTransaction(String rawTx, {String? callbackUrl}) async {
    final txid = dartsv.Transaction.fromHex(rawTx).id;
    final journal = store.journal['BitcoinWallet_$_walletId'] ?? const [];
    submissions.add(_Submission(
      txid,
      journal.any((e) => e is TransactionRecordedEvent && e.txid == txid),
      journal.any((e) => e is TransactionSpendDeferredEvent && e.txid == txid && e.heldUtxoKeys.contains(_sourceKey)),
    ));
    return ArcSubmitResponse.fromJson({'txid': txid, 'txStatus': submitStatus});
  }

  @override
  Future<ArcTransactionResponse> getTransaction(String txid) async =>
      throw ArcException('Failed to get transaction: {"status":404}', statusCode: 404);
}
