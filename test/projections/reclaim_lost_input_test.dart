/// A reclaim that lost the race to the payment it reclaimed: the payee
/// broadcast the payment, it was mined, and the wallet learns it from a
/// spend of one input (the in-flight resolver, bead libspiffy-4kfq). The
/// order of events is the one an iPhone journaled on 2026-10-19
/// (spiffyvault-ri8).
library;

import 'dart:io';

import 'package:isar_community/isar.dart';
import 'package:test/test.dart';

import 'package:libspiffy/src/core/wallet_events.dart';
import 'package:libspiffy/src/models/bitcoin_transaction.dart';
import 'package:libspiffy/src/models/bitcoin_utxo.dart';
import 'package:libspiffy/src/models/deferred_payment.dart';
import 'package:libspiffy/src/models/wallet_event.dart';
import 'package:libspiffy/src/models/wallet_type.dart';
import 'package:libspiffy/src/projections/wallet_projection.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';
import 'package:libspiffy/src/storage/isar_wallet_storage.dart';
import 'package:libspiffy/src/storage/libspiffy_schemas.dart';
import 'package:libspiffy/src/storage/read_model_storage.dart';

import '../integration/isar_test_helper.dart';

import 'package:eventador/eventador.dart' show EventStore;

class _NoStore implements EventStore {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('${invocation.memberName}');
}

const _w = 'reclaim-lost-wallet';
final _a = '${'a1' * 32}:3';
final _b = '${'b2' * 32}:7';
final _payment = '15' * 32;
final _reclaim = 'ea' * 32;

void main() {
  for (final isarBacked in [false, true]) {
    group(isarBacked ? 'Isar' : 'in memory', () => _cases(isarBacked));
  }
}

void _cases(bool isarBacked) {
  late ReadModelStorage storage;
  Isar? isar;
  Directory? dir;
  late WalletProjection projection;
  final events = <WalletEvent>[];
  var clock = DateTime.utc(2026, 10, 15);

  T add<T extends WalletEvent>(T Function(int version, DateTime at) make) {
    clock = clock.add(const Duration(minutes: 1));
    final e = make(events.length + 1, clock);
    events.add(e);
    return e;
  }

  Future<Map<String, BitcoinUtxo>> utxos() async =>
      {for (final u in await storage.getUTXOs(_w, includeSpent: true)) u.key: u};

  tearDown(() async {
    await isar?.close(deleteFromDisk: true);
    await dir?.delete(recursive: true);
    isar = null;
  });

  setUp(() async {
    if (isarBacked) {
      await ensureIsarInitialized();
      dir = await Directory.systemTemp.createTemp('reclaim_lost_');
      isar = await Isar.open(LibSpiffySchemas.allSchemas, directory: dir!.path, name: 'reclaim_lost_${DateTime.now().microsecondsSinceEpoch}');
      storage = IsarWalletStorage(isar!);
    } else {
      storage = InMemoryWalletStorage();
    }
    projection = WalletProjection(projectionId: 'reclaim-lost-test', eventStore: _NoStore(), storage: storage);
    events.clear();
    add((v, at) => WalletCreatedEvent(
        walletId: _w, walletName: 'w', rootAddress: 'mroot', walletType: WalletType.hd,
        walletMetadata: {'network': 'testnet'}, version: v, timestamp: at));
    for (final (key, sats) in [(_a, 93680881), (_b, 93501562)]) {
      final sep = key.indexOf(':');
      add((v, at) => UTXOReceivedEvent(
          walletId: _w, txid: key.substring(0, sep), vout: int.parse(key.substring(sep + 1)), satoshis: sats,
          scriptPubKey: '76a914${'00' * 20}88ac', address: 'mroot',
          initialStatus: UTXOStatus.available, version: v, timestamp: at));
    }
    // The payment, handed to the payee: it holds both coins.
    add((v, at) => TransactionRecordedEvent(
        walletId: _w, txid: _payment, rawHex: '00', totalInputSats: 187182443, totalOutputSats: 187182442,
        fee: 1, numInputs: 2, numOutputs: 3, txVersion: 2, txLockTime: 0, spentUtxoKeys: [_a, _b],
        recipientAddresses: const ['mpayee'], paymentAmount: '100000000', version: v, timestamp: at));
    add((v, at) => TransactionSpendDeferredEvent(
        walletId: _w, txid: _payment,
        heldInputs: [
          {'utxoKey': _a, 'satoshis': '93680881'},
          {'utxoKey': _b, 'satoshis': '93501562'},
        ],
        recipientAddresses: const ['mpayee'], paymentAmount: '100000000', fee: 1, version: v, timestamp: at));
    // Four days later: the reclaim's self-spend takes the hold over.
    add((v, at) => TransactionRecordedEvent(
        walletId: _w, txid: _reclaim, rawHex: '00', totalInputSats: 187182443, totalOutputSats: 187182442,
        fee: 1, numInputs: 2, numOutputs: 1, txVersion: 2, txLockTime: 0, spentUtxoKeys: [_b, _a],
        recipientAddresses: const ['mroot'], paymentAmount: '187182442', version: v, timestamp: at));
    add((v, at) => TransactionSpendDeferredEvent(
        walletId: _w, txid: _reclaim,
        heldInputs: [
          {'utxoKey': _b, 'satoshis': '93501562'},
          {'utxoKey': _a, 'satoshis': '93680881'},
        ],
        recipientAddresses: const ['mroot'], paymentAmount: '187182442', fee: 1,
        purpose: DeferredPaymentPurpose.reclaimOf(_payment), supersedes: _payment, version: v, timestamp: at));
    add((v, at) => DeferredSpendReclaimedEvent(
        walletId: _w, txid: _payment, reclaimTxid: _reclaim, reclaimedUtxoKeys: [_b, _a],
        reason: 'Never taken', version: v, timestamp: at));
    add((v, at) => TransactionStatusUpdatedEvent(
        walletId: _w, txid: _reclaim, newStatus: TransactionStatus.broadcast, version: v, timestamp: at));
    add((v, at) => TransactionBroadcastEvent(walletId: _w, txid: _reclaim, version: v, timestamp: at));
    add((v, at) => TransactionNetworkStatusCheckedEvent(
        walletId: _w, txid: _reclaim, networkStatus: 'SENT_TO_NETWORK', source: 'arc', checkedAt: at,
        version: v, timestamp: at));
  });

  Future<void> project() async {
    for (final e in events) {
      await projection.handle(e);
    }
  }

  test('failed by the resolver: the payment keeps the coin the resolver did not name', () async {
    // The resolver fails the reclaim, then spends the coin it found spent
    // (arc_actor _resolveIfInputSpent).
    add((v, at) => DeferredTransactionFailedEvent(
        walletId: _w, txid: _reclaim, networkStatus: 'INPUT_SPENT',
        reason: 'Input $_a is already spent by $_payment, a confirmed transaction',
        releasedInputs: [
          ReleasedDeferredInput(utxoKey: _a, restoredStatus: UTXOStatus.available),
          ReleasedDeferredInput(utxoKey: _b, restoredStatus: UTXOStatus.available),
        ],
        version: v, timestamp: at));
    add((v, at) => TransactionStatusUpdatedEvent(
        walletId: _w, txid: _reclaim, newStatus: TransactionStatus.failed, version: v, timestamp: at));
    add((v, at) => UTXOSpentEvent(
        walletId: _w, txid: 'a1' * 32, vout: 3, spentInTxId: _payment, version: v, timestamp: at));
    await project();

    final rows = await utxos();
    expect((rows[_a]!.status, rows[_a]!.spentInTxId), (UTXOStatus.spent, _payment));
    expect((rows[_b]!.status, rows[_b]!.reservedByTxId), (UTXOStatus.reserved, _payment),
        reason: 'the mined payment spent it too; it must not be spendable again');
    expect((await storage.getDeferredPayment(_w, _reclaim))!.state, DeferredPaymentState.failed);
  });

  test('lost when the payment is seen spending its coin: the reclaim and its row fail', () async {
    // The payment proven mined: its deferred spend spends both coins.
    add((v, at) => UTXOSpentEvent(
        walletId: _w, txid: 'a1' * 32, vout: 3, spentInTxId: _payment, version: v, timestamp: at));
    add((v, at) => UTXOSpentEvent(
        walletId: _w, txid: 'b2' * 32, vout: 7, spentInTxId: _payment, version: v, timestamp: at));
    await project();

    expect((await storage.getDeferredPayment(_w, _reclaim))!.state, DeferredPaymentState.failed);
    expect((await storage.getTransaction(_reclaim, walletId: _w))!.status, TransactionStatus.failed,
        reason: 'left broadcasting, the self-spend showed as on its way for ever');
    final rows = await utxos();
    expect([rows[_a]!.status, rows[_b]!.status], [UTXOStatus.spent, UTXOStatus.spent]);
  });

  test('won when the self-spend is seen: the payment is reclaimed and its row fails', () async {
    // spiffyvault-56z: the payee never broadcast the payment, and the
    // reclaim reached the network.
    add((v, at) => TransactionNetworkStatusCheckedEvent(
        walletId: _w, txid: _reclaim, networkStatus: 'SEEN_ON_NETWORK', source: 'arc', checkedAt: at,
        version: v, timestamp: at));
    await project();

    expect((await storage.getDeferredPayment(_w, _payment))!.state, DeferredPaymentState.reclaimed);
    expect((await storage.getTransaction(_payment, walletId: _w))!.status, TransactionStatus.failed,
        reason: 'left pending, the reclaimed payment showed as on its way for ever');
    expect((await storage.getTransaction(_reclaim, walletId: _w))!.status, isNot(TransactionStatus.failed));
  });
}
