/// Bead libspiffy-3egy on the real stack: the network reports a payment while
/// the read model holds its transaction row and not yet its outputs.
///
/// The projection applies a recording one event at a time, and the journal
/// has the transaction (TransactionRecordedEvent) before its wallet outputs
/// (UTXOReceivedEvent). ARC answers a submission in one round trip. ARCActor
/// worked out the deferred spend from the read model, so a report in that
/// gap spent the inputs, found no output to promote, and armed no recheck
/// (the row was there): the change stayed pending until the next status
/// scan, 30 s later, and a CheckDeferredPaymentStatusCommand sent meanwhile
/// did not answer until then. Reported from lt-spiffy-plugin, where settling
/// a payment and checking it at once took 29.6 s.
///
/// Here the gap is held open: the read model does not write a pending output
/// until the test lets it. The wallet aggregate decides the spend from its
/// own state (ApplyDeferredSpendCommand), so nothing waits for a scan.
library;

import 'dart:async';
import 'dart:io';

import 'package:convert/convert.dart';
import 'package:dactor/dactor.dart';
import 'package:isar_community/isar.dart';
import 'package:test/test.dart';

import 'package:libspiffy/libspiffy.dart';
import 'package:libspiffy/coordinator.dart';

import '../mocks/network_arc.dart';
import '../spv/testnet_proof_fixture.dart';
import 'isar_test_helper.dart';
import 'p2p_test_helpers.dart';

const _fundingKey = 'a05924fcc63712d3e4b94b0c88baad234c2c8ad3d369704f53765e21a53a2101:1';
const _recipient = 'muq9kAb9ri62VChAMRkuwK5bTve4iDLWBg';

void main() {
  late Directory dir;
  late Isar isar;
  late LibSpiffyActorSystem libspiffy;
  late LocalActorSystem actorSystem;
  late NetworkArc arc;
  late _OutputsHeldBack readModel;
  late Stream<CoordinatorEvent> events;
  const walletId = 'outputs-held-back';

  setUpAll(() async {
    await ensureIsarInitialized();
  });

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('deferred_spend_gap_');
    actorSystem = LocalActorSystem(ActorSystemConfig());
    isar = await Isar.open(
      LibSpiffySchemas.allSchemas,
      directory: dir.path,
      name: 'deferred_spend_gap_${DateTime.now().microsecondsSinceEpoch}',
    );
    arc = NetworkArc();
    readModel = _OutputsHeldBack();
    libspiffy = LibSpiffyActorSystem();
    await libspiffy.initialize(
      actorSystem: actorSystem,
      isar: isar,
      readModelStorage: readModel,
      dataDirectory: dir.path,
      enableP2P: false,
      arcService: arc,
      secureStorage: InMemorySecureStorage(),
    );
    // The header the funding proof verifies against.
    await readModel.storeBlockHeader(fixtureHeader(), kFixtureHeight);
    events = libspiffy.coordinatorEvents!;
    await createWallet(
      walletManager: libspiffy.walletManager,
      actorSystem: actorSystem,
      walletId: walletId,
      walletName: 'Gap',
      xpriv: kTestXpriv,
    );
    await fundWallet(
      walletManager: libspiffy.walletManager,
      actorSystem: actorSystem,
      walletId: walletId,
      amount: BigInt.from(1000000),
    );
  });

  tearDown(() async {
    readModel.release();
    await libspiffy.shutdown();
    try {
      await isar.close(deleteFromDisk: true);
    } catch (_) {}
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  });

  Future<T> send<T extends CoordinatorEvent>(Message command, bool Function(T e) where) async {
    final result =
        events.where((e) => e is T && where(e)).cast<T>().first.timeout(const Duration(seconds: 60));
    libspiffy.coordinator.tell(command);
    return result;
  }

  /// A payment whose recording the read model holds as far as its
  /// transaction row and its hold, and none of its outputs; settled, so ARC
  /// has reported it SEEN_ON_NETWORK.
  Future<PaymentReadyEvent> paidAndSettledInTheGap() async {
    readModel.holdBack();
    final ready = await send<PaymentReadyEvent>(
      PayInvoiceCommand(
          walletId: walletId, invoiceId: 'inv-gap', addresses: const [_recipient], amount: BigInt.from(100000)),
      (e) => e.invoiceId == 'inv-gap',
    );
    expect(ready.success, isTrue, reason: ready.error);
    expect(await readModel.getTransaction(ready.txid, walletId: walletId), isNotNull,
        reason: 'precondition: the transaction row is projected');
    expect(await readModel.getUTXOsByTxid(walletId, ready.txid), isEmpty,
        reason: 'precondition: its change output is not');

    final settled = await send<BEEFSettledEvent>(
        SettleBEEFCommand(walletId: walletId, beefHex: hex.encode(ready.beefBytes), txid: ready.txid),
        (e) => e.txid == ready.txid);
    expect(settled.success, isTrue, reason: settled.error);
    expect(arc.seen, contains(ready.txid));
    expect(await readModel.getUTXOsByTxid(walletId, ready.txid), isEmpty,
        reason: 'precondition: ARC reported the payment before the read model held its change');
    return ready;
  }

  Future<UTXOStatus?> statusOf(String key) async {
    for (final u in await readModel.getUTXOs(walletId, includeSpent: true)) {
      if (u.key == key) return u.status;
    }
    return null;
  }

  test('the change is spendable as soon as the read model catches up, not at the next status scan', () async {
    final ready = await paidAndSettledInTheGap();
    final watch = Stopwatch()..start();

    readModel.release();

    BitcoinUtxo? change;
    while (change?.status != UTXOStatus.available && watch.elapsed < const Duration(seconds: 10)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      change = (await readModel.getUTXOsByTxid(walletId, ready.txid)).firstOrNull;
    }
    // Old code: pending until the scan, statusCheckInterval (30 s) later.
    expect(change?.status, UTXOStatus.available);
    expect(await statusOf(_fundingKey), UTXOStatus.spent);
  });

  test('a status check sent in the gap answers once the read model shows the change available, '
      'without waiting for a status scan', () async {
    final ready = await paidAndSettledInTheGap();
    final watch = Stopwatch()..start();

    final answer = send<DeferredPaymentStatusEvent>(
        CheckDeferredPaymentStatusCommand(walletId: walletId, txid: ready.txid, requestId: 'gap'),
        (e) => e.requestId == 'gap');
    // The check is on its way through ARC and the wallet; then the
    // projection catches up.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(await readModel.getUTXOsByTxid(walletId, ready.txid), isEmpty);
    readModel.release();
    final checked = await answer;

    // What the read model shows the moment the answer arrives.
    final change = (await readModel.getUTXOsByTxid(walletId, ready.txid)).firstOrNull;
    final funding = await statusOf(_fundingKey);
    expect(checked.success, isTrue, reason: checked.error);
    expect(checked.networkStatus, DeferredNetworkStatus.seenOnNetwork);
    expect(checked.error, isNull);
    expect(change?.status, UTXOStatus.available,
        reason: 'an app that reads its balance on hearing the answer sees the change');
    expect(funding, UTXOStatus.spent);
    // Old code: the answer waited for the scan that promoted the change,
    // statusCheckInterval (30 s) after the report.
    expect(watch.elapsed, lessThan(const Duration(seconds: 10)));
  });
}

/// A read model that, while held back, does not write a pending UTXO: the
/// projection has applied a recording as far as its outputs and no further.
class _OutputsHeldBack extends InMemoryWalletStorage {
  Completer<void>? _held;

  void holdBack() => _held = Completer<void>();

  void release() {
    _held?.complete();
    _held = null;
  }

  @override
  Future<void> upsertUTXO(String walletId, BitcoinUtxo utxo) async {
    final held = _held;
    if (held != null && utxo.status == UTXOStatus.pending) await held.future;
    return super.upsertUTXO(walletId, utxo);
  }
}
