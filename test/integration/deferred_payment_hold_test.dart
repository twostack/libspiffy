/// Bead libspiffy-7p2: a payment handed to its recipient keeps its inputs.
///
/// In the peer-to-peer model the sender hands the signed transaction (BEEF)
/// to the recipient, who normally broadcasts it (spv-understanding.md). The
/// payment coordinator reserved the inputs for two minutes and recorded the
/// transaction with a deferred spend; the periodic reservation cleanup then
/// returned them to available. A later payment could select the same inputs
/// and double-spend the payment the recipient still holds.
///
/// Through LibSpiffyActorSystem (Isar, no network): pay an invoice, run the
/// cleanup past the reservation expiry, pay again. Also after a restart
/// (journal replay) and for a journal written before holds were journaled.
import 'dart:async';
import 'dart:io';

import 'package:dactor/dactor.dart';
import 'package:eventador/eventador.dart';
import 'package:isar/isar.dart';
import 'package:libspiffy/libspiffy.dart';
import 'package:libspiffy/src/actors/libspiffy_actor_system.dart';
import 'package:libspiffy/src/actors/payment_messages.dart';
import 'package:libspiffy/src/actors/wallet_messages.dart';
import 'package:libspiffy/src/core/wallet_commands.dart';
import 'package:libspiffy/src/core/wallet_events.dart';
import 'package:libspiffy/src/models/bitcoin_utxo.dart';
import 'package:libspiffy/src/storage/isar_wallet_storage.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:test/test.dart';

import 'isar_test_helper.dart';
import 'p2p_test_helpers.dart';

const _fundingTxid = 'a05924fcc63712d3e4b94b0c88baad234c2c8ad3d369704f53765e21a53a2101';
const _fundingKey = '$_fundingTxid:1';
const _recipient = 'muq9kAb9ri62VChAMRkuwK5bTve4iDLWBg';

void main() {
  late Directory dir;
  late Isar isar;
  late LocalActorSystem actorSystem;
  late LibSpiffyActorSystem libspiffy;
  late String walletId;
  late InMemorySecureStorage secureStorage; // survives the restarts, like a device keystore
  late _ScriptedArc arc;
  var receivers = 0;

  setUpAll(() async {
    await ensureIsarInitialized();
  });

  Future<void> start() async {
    actorSystem = LocalActorSystem(ActorSystemConfig());
    libspiffy = LibSpiffyActorSystem();
    await libspiffy.initialize(
      actorSystem: actorSystem,
      isar: isar,
      dataDirectory: dir.path,
      enableP2P: false,
      arcService: arc,
      secureStorage: secureStorage,
    );
    await setupTestHeaders(libspiffy.walletStorage as IsarWalletStorage);
  }

  Future<void> stop() => libspiffy.shutdown();

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('deferred_hold_');
    secureStorage = InMemorySecureStorage();
    arc = _ScriptedArc();
    isar = await Isar.open(
      LibSpiffySchemas.allSchemas,
      directory: dir.path,
      name: 'deferred_hold_${DateTime.now().microsecondsSinceEpoch}',
    );
    await start();
    walletId = 'hold-wallet-${DateTime.now().microsecondsSinceEpoch}';
    await createWallet(
      walletManager: libspiffy.walletManager,
      actorSystem: actorSystem,
      walletId: walletId,
      walletName: 'Hold',
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
    await stop();
    await isar.close(deleteFromDisk: true);
    await dir.delete(recursive: true);
  });

  ReadModelStorage storage() => libspiffy.walletStorage;

  Future<BitcoinUtxo?> fundingUtxo() async => (await storage().getUTXOs(walletId, includeSpent: true))
      .where((u) => u.key == _fundingKey)
      .firstOrNull;

  Future<BEEFPaymentResponse> pay(String invoiceId, {int amount = 100000}) async {
    final completer = Completer<BEEFPaymentResponse>();
    final receiver = await actorSystem.spawn(
      'pay-receiver-${receivers++}-${DateTime.now().microsecondsSinceEpoch}',
      () => TestReceiverActor<BEEFPaymentResponse>(completer),
    );
    libspiffy.paymentCoordinator.tell(
      PayInvoiceMessage(
        walletId: walletId,
        invoiceId: invoiceId,
        addresses: const [_recipient],
        amount: BigInt.from(amount),
      ),
      sender: receiver,
    );
    return completer.future.timeout(const Duration(seconds: 20));
  }

  /// Waits until the wallet aggregate and the projection have handled every
  /// command sent so far: an address generated now is projected after them.
  Future<void> barrier() async {
    final address = await generateAddress(
      walletManager: libspiffy.walletManager,
      actorSystem: actorSystem,
      walletId: walletId,
    );
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (await storage().getAddressMetadata(walletId, address) == null) {
      if (DateTime.now().isAfter(deadline)) fail('the projection did not apply address $address');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  /// The periodic cleanup, run as if the reservation expiry had passed.
  Future<void> cleanupPastExpiry() async {
    libspiffy.walletManager.tell(WalletCommandMessage(
      walletId,
      CleanupExpiredReservationsCommand(
        walletId: walletId,
        cutoffTime: DateTime.now().add(const Duration(hours: 1)),
      ),
    ));
    await barrier();
  }

  /// A second payment must not spend [heldKey]: it either fails or funds
  /// itself from other coins.
  Future<void> expectSecondPaymentDoesNotReuse(String heldKey) async {
    // A different amount: an identical payment would be the same transaction.
    final second = await pay('invoice-2-${DateTime.now().microsecondsSinceEpoch}', amount: 90000);
    expect(second.success ? second.spentUtxoKeys : const <String>[], isNot(contains(heldKey)),
        reason: 'the second payment reused an input of a payment the recipient still holds');
  }

  test('past the reservation expiry and a cleanup, the payment\'s input stays held and a second payment '
      'does not reuse it', () async {
    final first = await pay('invoice-1');
    expect(first.success, isTrue, reason: first.error);
    expect(first.spentUtxoKeys, [_fundingKey]);

    await cleanupPastExpiry();

    await expectSecondPaymentDoesNotReuse(_fundingKey);
    expect((await fundingUtxo())!.status, UTXOStatus.reserved,
        reason: 'the cleanup returned the handed-over payment\'s input to available');
  });

  test('after a restart (the wallet replayed from its journal) the hold survives the cleanup', () async {
    final first = await pay('invoice-1');
    expect(first.success, isTrue, reason: first.error);

    await stop();
    await start();

    await cleanupPastExpiry();
    expect((await fundingUtxo())!.status, UTXOStatus.reserved);
    await expectSecondPaymentDoesNotReuse(_fundingKey);
  });

  /// An outgoing transaction spending the funding output, as the payment
  /// coordinator recorded it before holds were journaled.
  String legacyPaymentHex() {
    final tx = dartsv.Transaction();
    tx.addInput(dartsv.TransactionInput(_fundingTxid, 1, dartsv.TransactionInput.MAX_SEQ_NUMBER));
    tx.addOutput(dartsv.TransactionOutput(
      BigInt.from(100000),
      dartsv.SVScript.fromHex('76a9149d02ce72bbdc1713d5537a0705d8ec7d9702c81088ac'),
    ));
    return tx.serialize();
  }

  for (final released in [false, true]) {
    test('a journal written before holds: a recorded deferred payment whose reservation '
        '${released ? 'the old cleanup already released' : 'already expired'} is held after the upgrade',
        () async {
      await barrier();
      await stop();

      // Append what the old payment flow journaled, while no aggregate runs.
      final rawHex = legacyPaymentHex();
      final txid = dartsv.Transaction.fromHex(rawHex).id;
      final journal = IsarEventStore(isar);
      final persistenceId = 'BitcoinWallet_$walletId';
      var version = await journal.getHighestSequenceNumber(persistenceId);
      final recordedAt = DateTime.now().subtract(const Duration(hours: 2));
      final legacy = <WalletEvent>[
        UTXOReservedEvent(
          walletId: walletId,
          txid: _fundingTxid,
          vout: 1,
          reservedByTxId: 'payment-legacy-1',
          reservationReason: 'payment',
          expiresAt: recordedAt.add(const Duration(minutes: 2)),
          version: version + 1,
          timestamp: recordedAt,
        ),
        TransactionRecordedEvent(
          walletId: walletId,
          txid: txid,
          rawHex: rawHex,
          totalInputSats: 1000000,
          totalOutputSats: 100000,
          fee: 900000,
          numInputs: 1,
          numOutputs: 1,
          txVersion: 1,
          txLockTime: 0,
          spentUtxoKeys: const [_fundingKey],
          recipientAddresses: const [_recipient],
          paymentAmount: '100000',
          version: version + 2,
          timestamp: recordedAt,
        ),
        if (released)
          UTXOReleasedEvent(
            walletId: walletId,
            txid: _fundingTxid,
            vout: 1,
            releaseReason: 'Expired reservation cleanup',
            wasExpired: true,
            restoredStatus: UTXOStatus.available,
            version: version + 3,
            timestamp: recordedAt.add(const Duration(minutes: 5)),
          ),
      ];
      for (final event in legacy) {
        await journal.persistEvent(persistenceId, event, version++);
      }

      await start();
      // Loading the wallet journals the hold (no cleanup or payment needed).
      await barrier();
      final loaded = (await fundingUtxo())!;
      expect(loaded.reservedByTxId, txid, reason: 'the hold is not journaled when the wallet loads');
      expect(loaded.reservationExpiresAt, isNull);

      await cleanupPastExpiry();

      expect((await fundingUtxo())!.status, UTXOStatus.reserved,
          reason: 'the old deferred payment\'s input is not held');
      await expectSecondPaymentDoesNotReuse(_fundingKey);
    });
  }

  /// One ARC status scan (the header trigger), waited for through the wallet.
  Future<void> arcScan() async {
    final calls = arc.statusQueries;
    libspiffy.arcActor.tell(CheckStoragePendingUTXOsMessage(triggerBlockHeight: 1));
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (arc.statusQueries <= calls) {
      if (DateTime.now().isAfter(deadline)) fail('no ARC status scan');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await barrier();
  }

  /// Scans until ARC was asked about [txid] once more.
  Future<void> arcScanOf(String txid) async {
    final calls = arc.queriesOf(txid);
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    var nextTrigger = DateTime.now();
    while (arc.queriesOf(txid) <= calls) {
      if (DateTime.now().isAfter(deadline)) fail('ARC was not asked about $txid again');
      // A trigger restarts the scan's debounce: not more than once a second.
      if (!DateTime.now().isBefore(nextTrigger)) {
        libspiffy.arcActor.tell(CheckStoragePendingUTXOsMessage(triggerBlockHeight: 1));
        nextTrigger = DateTime.now().add(const Duration(seconds: 1));
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await barrier();
  }

  test('ey2: ARC reports DOUBLE_SPEND_ATTEMPTED: the input stays held, the status is recorded, ARC keeps '
      'being asked, and SEEN_ON_NETWORK of ours then spends the input', () async {
    final first = await pay('invoice-1');
    expect(first.success, isTrue, reason: first.error);
    arc.status[first.txid] = 'DOUBLE_SPEND_ATTEMPTED';

    await arcScanOf(first.txid);

    // Old code: the payment failed and its input was released for reuse.
    expect((await fundingUtxo())!.status, UTXOStatus.reserved);
    final row = (await storage().getDeferredPayment(walletId, first.txid))!;
    expect(row.state, DeferredPaymentState.outstanding);
    expect(row.lastNetworkStatus, 'DOUBLE_SPEND_ATTEMPTED');
    expect((await storage().getTransaction(first.txid, walletId: walletId))!.status,
        isNot(TransactionStatus.failed), reason: 'a failed transaction is no longer polled');
    await cleanupPastExpiry();
    await expectSecondPaymentDoesNotReuse(_fundingKey);

    arc.status[first.txid] = 'SEEN_ON_NETWORK';
    await arcScanOf(first.txid);

    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while ((await fundingUtxo())!.status != UTXOStatus.spent) {
      if (DateTime.now().isAfter(deadline)) fail('the contested payment seen on the network did not spend its input');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect((await storage().getDeferredPayment(walletId, first.txid))!.state, DeferredPaymentState.seen);
  });

  for (final failure in ['REJECTED']) {
    test('ARC reports $failure: the payment\'s input is released at once, and it can pay again', () async {
      final first = await pay('invoice-1');
      expect(first.success, isTrue, reason: first.error);
      arc.status[first.txid] = failure;

      await arcScan();

      final utxo = (await fundingUtxo())!;
      expect(utxo.status, UTXOStatus.available,
          reason: 'a definitively failed payment must not keep its input (it stayed reserved until expiry)');
      final second = await pay('invoice-2', amount: 90000);
      expect(second.success, isTrue, reason: second.error);
      expect(second.spentUtxoKeys, [_fundingKey]);
    });
  }

  for (final unreachable in [false, true]) {
    test('ARC ${unreachable ? 'is unreachable' : 'does not know the payment yet (404)'}: the input stays held',
        () async {
      final first = await pay('invoice-1');
      expect(first.success, isTrue, reason: first.error);
      arc.unreachable = unreachable;

      await arcScan();
      await cleanupPastExpiry();

      expect((await fundingUtxo())!.status, UTXOStatus.reserved);
      await expectSecondPaymentDoesNotReuse(_fundingKey);
    });
  }
}

/// ARC without a network: a txid in [status] reports that `txStatus`; any
/// other is unknown (404); [unreachable] fails every request.
class _ScriptedArc extends ArcService {
  _ScriptedArc() : super(baseUrl: 'fake://arc');

  final Map<String, String> status = {};
  bool unreachable = false;
  int statusQueries = 0;
  final Map<String, int> _queries = {};

  int queriesOf(String txid) => _queries[txid] ?? 0;

  @override
  Future<ArcSubmitResponse> submitTransaction(String rawTx, {String? callbackUrl}) async {
    throw ArcException('not used');
  }

  @override
  Future<ArcTransactionResponse> getTransaction(String txid) async {
    statusQueries++;
    _queries[txid] = queriesOf(txid) + 1;
    if (unreachable) throw ArcException('ARC unreachable');
    final txStatus = status[txid];
    if (txStatus == null) throw ArcException('Failed to get transaction: {"status":404}');
    return ArcTransactionResponse.fromJson({'txid': txid, 'txStatus': txStatus});
  }
}
