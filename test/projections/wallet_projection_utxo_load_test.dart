/// What one UTXO event costs the wallet projection to read.
///
/// * Audit 2026-09-14 M7 (libspiffy-5nd): each UTXO event loaded every UTXO
///   row of the wallet, spent ones included, TWICE -- once to find the row
///   the event is about and again to recompute the address and wallet
///   balances. The first test counts the loads.
/// * Bead libspiffy-36jt: one load per event is still one load of the
///   wallet's whole spend history, and a spend history is never purged
///   (`spv-understanding.md`, Data Retention), so the cost of every future
///   event grew with every spend the wallet had ever made. The second test
///   counts the ROWS, which is the thing that grew, and the measurement is
///   that they do not grow.
library;

import 'dart:io';

import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:eventador/eventador.dart';
import 'package:test/test.dart';

import 'package:libspiffy/src/core/wallet_events.dart';
import 'package:libspiffy/src/models/bitcoin_utxo.dart';
import 'package:libspiffy/src/models/wallet_event.dart';
import 'package:libspiffy/src/models/wallet_type.dart';
import 'package:libspiffy/src/projections/wallet_projection.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';

const _walletId = 'projection-load-wallet';
const _pubKeyHash = '89abcdefabbaabbaabbaabbaabbaabbaabbaabba';
const _scriptPubKey = '76a914${_pubKeyHash}88ac';
final _address = dartsv.Address.fromPubkeyHash(_pubKeyHash, dartsv.NetworkType.TEST).toBase58();

/// In-memory read model that counts full UTXO loads, and the UTXO rows it
/// hands the projection.
///
/// `countSpentUTXOs` adds nothing to [rowsRead]: no row crosses the boundary,
/// which is the whole point of it -- Postgres counts through
/// `idx_utxos_wallet_status` and Isar through the `(walletId, status)` index,
/// pinned by `test/storage/isar_query_access_test.dart`.
class _CountingStorage extends InMemoryWalletStorage {
  int utxoLoads = 0;
  int rowsRead = 0;
  int spentCounts = 0;

  @override
  Future<List<BitcoinUtxo>> getUTXOs(String walletId, {bool includeSpent = false}) async {
    utxoLoads++;
    final rows = await super.getUTXOs(walletId, includeSpent: includeSpent);
    rowsRead += rows.length;
    return rows;
  }

  @override
  Future<BitcoinUtxo?> getUTXO(String walletId, String txid, int vout) async {
    final row = await super.getUTXO(walletId, txid, vout);
    if (row != null) rowsRead++;
    return row;
  }

  @override
  Future<List<BitcoinUtxo>> getUTXOsByTxid(String walletId, String txid,
      {bool includeSpent = false}) async {
    final rows = await super.getUTXOsByTxid(walletId, txid, includeSpent: includeSpent);
    rowsRead += rows.length;
    return rows;
  }

  @override
  Future<int> countSpentUTXOs(String walletId) {
    spentCounts++;
    return super.countSpentUTXOs(walletId);
  }
}

String _txid(int n) => n.toRadixString(16).padLeft(64, '0');

void main() {
  test('each UTXO event loads the wallet UTXO rows at most once', () async {
    final storage = _CountingStorage();
    final projection = WalletProjection(
      projectionId: 'load-test',
      eventStore: _NoopEventStore(),
      storage: storage,
    );

    var version = 0;
    var clock = DateTime.utc(2024, 1, 1);
    DateTime tick() => clock = clock.add(const Duration(minutes: 1));

    await projection.handle(WalletCreatedEvent(
      walletId: _walletId,
      walletName: 'Load test',
      rootAddress: _address,
      walletType: WalletType.hd,
      walletMetadata: {'network': 'testnet'},
      version: ++version,
      timestamp: tick(),
    ));

    const n = 20;
    final utxoEvents = <WalletEvent>[
      for (var i = 0; i < n; i++)
        UTXOReceivedEvent(
          walletId: _walletId,
          txid: _txid(i),
          vout: 0,
          satoshis: 1000 + i,
          scriptPubKey: _scriptPubKey,
          address: _address,
          confirmations: 0,
          version: ++version,
          timestamp: tick(),
        ),
      for (var i = 0; i < n; i++)
        UTXOConfirmationUpdatedEvent(
          walletId: _walletId,
          txid: _txid(i),
          vout: 0,
          confirmations: 6,
          blockHeight: 100,
          version: ++version,
          timestamp: tick(),
        ),
      for (var i = 0; i < n; i += 2)
        UTXOReservedEvent(
          walletId: _walletId,
          txid: _txid(i),
          vout: 0,
          reservedByTxId: 'payment',
          expiresAt: clock.add(const Duration(hours: 1)),
          version: ++version,
          timestamp: tick(),
        ),
      for (var i = 0; i < n; i += 4)
        UTXOReleasedEvent(
          walletId: _walletId,
          txid: _txid(i),
          vout: 0,
          restoredStatus: UTXOStatus.available,
          version: ++version,
          timestamp: tick(),
        ),
      for (var i = 1; i < n; i += 2)
        UTXOSpentEvent(
          walletId: _walletId,
          txid: _txid(i),
          vout: 0,
          spentInTxId: _txid(999),
          version: ++version,
          timestamp: tick(),
        ),
    ];

    final loadsPerEvent = <String, int>{};
    for (final event in utxoEvents) {
      final before = storage.utxoLoads;
      await projection.handle(event);
      final loads = storage.utxoLoads - before;
      final type = event.runtimeType.toString();
      loadsPerEvent[type] = loads > (loadsPerEvent[type] ?? 0) ? loads : loadsPerEvent[type]!;
    }

    expect(loadsPerEvent.values.every((loads) => loads <= 1), isTrue,
        reason: 'most full UTXO loads per event, by event type: $loadsPerEvent');

    // The read model is still right.
    final rows = await storage.getUTXOs(_walletId, includeSpent: true);
    expect(rows.length, n);
    var unspent = BigInt.zero;
    var reserved = BigInt.zero;
    for (final u in rows) {
      final i = int.parse(u.txid, radix: 16);
      if (i.isOdd) {
        expect(u.status, UTXOStatus.spent, reason: u.key);
      } else if (i % 4 == 0) {
        expect(u.status, UTXOStatus.available, reason: u.key);
        expect(u.updatedAt.isUtc && u.updatedAt.year == 2024, isTrue,
            reason: 'transitions are stamped with the event time');
      } else {
        expect(u.status, UTXOStatus.reserved, reason: u.key);
        reserved += u.satoshis;
      }
      if (!u.isSpent) unspent += u.satoshis;
    }
    final wallet = await storage.getWallet(_walletId);
    final metadata = wallet!['metadata'] as Map<String, dynamic>;
    expect(metadata['reservedBalance'], reserved.toString());
    // The UTXOConfirmationUpdatedEvents above report a count and a height
    // nothing verified, so nothing here is confirmed (beads libspiffy-jc3h
    // and libspiffy-pq8p): the rows keep no height and the unreserved
    // amounts sit in the unconfirmed bucket. This asserted the confirmed
    // bucket while a count of six decided the split.
    expect(metadata['confirmedBalance'], '0');
    expect(metadata['unconfirmedBalance'], (unspent - reserved).toString());
    expect(metadata['utxoCount'], n);
    expect(metadata['spentUtxoCount'], n ~/ 2);
    final address = await storage.getAddressMetadata(_walletId, _address);
    expect(address!.balance, unspent);
    expect(address.usageCount, n);
  });

  _spendHistoryCostTest();
}


/// Drives a wallet whose spend history is [spentRows] deep and whose live
/// set is always the same three outputs, then measures what one more event
/// of each kind reads.
///
/// Returns the rows read per event type, and the storage that counted them.
Future<(Map<String, int>, _CountingStorage)> _rowsPerEvent(int spentRows) async {
  final storage = _CountingStorage();
  final projection = WalletProjection(
    projectionId: 'cost-$spentRows',
    eventStore: _NoopEventStore(),
    storage: storage,
  );

  var version = 0;
  var clock = DateTime.utc(2024, 1, 1);
  DateTime tick() => clock = clock.add(const Duration(minutes: 1));

  await projection.handle(WalletCreatedEvent(
    walletId: _walletId,
    walletName: 'Cost',
    rootAddress: _address,
    walletType: WalletType.hd,
    walletMetadata: {'network': 'testnet'},
    version: ++version,
    timestamp: tick(),
  ));

  Future<void> receive(String txid) => projection.handle(UTXOReceivedEvent(
        walletId: _walletId,
        txid: txid,
        vout: 0,
        satoshis: 5000,
        scriptPubKey: _scriptPubKey,
        address: _address,
        confirmations: 0,
        version: ++version,
        timestamp: tick(),
      ));

  // The spend history: received and spent, so the live set never grows with
  // it and only the spent rows accumulate.
  for (var i = 0; i < spentRows; i++) {
    final txid = _txid(1000 + i);
    await receive(txid);
    await projection.handle(UTXOSpentEvent(
      walletId: _walletId,
      txid: txid,
      vout: 0,
      spentInTxId: _txid(900000 + i),
      version: ++version,
      timestamp: tick(),
    ));
  }

  // The live set, identical whatever the history above. Four outputs, each
  // its own transaction: the fourth is left alone throughout, so an event
  // that touches rows it has no business touching shows up in the balances.
  final live = [for (var i = 0; i < 4; i++) _txid(500 + i)];
  for (final txid in live) {
    await receive(txid);
  }

  final rows = <String, int>{};
  Future<void> measure(String name, WalletEvent event) async {
    final before = storage.rowsRead;
    await projection.handle(event);
    rows[name] = storage.rowsRead - before;
  }

  // One event that writes and recomputes balances...
  await measure(
      'UTXOReserved',
      UTXOReservedEvent(
        walletId: _walletId,
        txid: live[0],
        vout: 0,
        reservedByTxId: 'payment',
        expiresAt: clock.add(const Duration(hours: 1)),
        version: ++version,
        timestamp: tick(),
      ));
  await measure(
      'UTXOSpent',
      UTXOSpentEvent(
        walletId: _walletId,
        txid: live[1],
        vout: 0,
        spentInTxId: _txid(800000),
        version: ++version,
        timestamp: tick(),
      ));
  // ...and one that decides it has nothing to do. It must read the one row
  // it decided on and no other. The first of these promotes the pending
  // output, so it is the REPLAY of it that has nothing to do -- which is the
  // common case a projection meets.
  await projection.handle(UTXOMarkedAvailableEvent(
    walletId: _walletId,
    txid: live[2],
    vout: 0,
    version: ++version,
    timestamp: tick(),
  ));
  await measure(
      'UTXOMarkedAvailable (replayed, already available)',
      UTXOMarkedAvailableEvent(
        walletId: _walletId,
        txid: live[2],
        vout: 0,
        version: ++version,
        timestamp: tick(),
      ));
  // A confirmation: it stamps the proven height on that transaction's own
  // outputs and then recomputes balances WITHOUT handing over the rows, so
  // it exercises the other side of the recalculation -- the one that reads
  // the set itself.
  await measure(
      'TransactionConfirmed',
      TransactionConfirmedEvent(
        walletId: _walletId,
        txid: live[2],
        blockHeight: 800000,
        version: ++version,
        timestamp: tick(),
      ));
  await measure(
      'UTXOReservationRenewed (not reserved)',
      UTXOReservationRenewedEvent(
        walletId: _walletId,
        txid: live[2],
        vout: 0,
        oldExpiresAt: clock.add(const Duration(hours: 1)),
        newExpiresAt: clock.add(const Duration(hours: 2)),
        version: ++version,
        timestamp: tick(),
      ));

  // The read model is still right, whatever it read to get there.
  final wallet = await storage.getWallet(_walletId);
  final metadata = wallet!['metadata'] as Map<String, dynamic>;
  expect(metadata['spentUtxoCount'], spentRows + 1,
      reason: 'the history, plus the live output just spent');
  expect(metadata['utxoCount'], spentRows + 4,
      reason: 'the history plus the four live outputs: every row the wallet '
          'has ever held is still counted, and the count no longer comes '
          'from reading them');
  expect(metadata['reservedBalance'], '5000');
  expect(metadata['confirmedBalance'], '5000',
      reason: 'the third live output and only it: the confirmation proved a '
          'height for ITS transaction, and a height reaches no other row');
  expect(metadata['unconfirmedBalance'], '5000',
      reason: 'the fourth, which nothing in this run touched');
  return (rows, storage);
}

void _spendHistoryCostTest() {
  test('36jt: what an event reads does not grow with the spend history',
      () async {
    // A wallet that has spent four times and one that has spent two hundred,
    // with the same live outputs. A spend history is never purged, so
    // anything read per event that scales with it costs more for the life of
    // the wallet -- which is what loading every row, spent ones included,
    // did on every UTXO event.
    final (shallow, shallowStorage) = await _rowsPerEvent(4);
    final (deep, _) = await _rowsPerEvent(200);

    expect(deep, shallow,
        reason: 'rows read per event, 4 spends deep vs 200: '
            'shallow=$shallow deep=$deep');

    // And the absolute numbers, so this says what the cost IS and not only
    // that it is stable. The live set is three outputs.
    expect(shallow['UTXOMarkedAvailable (replayed, already available)'], 1,
        reason: 'an event that decides it has nothing to do reads the one '
            'row it decided on');
    expect(shallow['UTXOReservationRenewed (not reserved)'], 1);
    expect(shallow['UTXOReserved'], lessThanOrEqualTo(5),
        reason: 'the outpoint, then the live set to recompute balances -- '
            'never the spend history');
    expect(shallow['UTXOSpent'], lessThanOrEqualTo(5));
    expect(shallow['TransactionConfirmed'], lessThanOrEqualTo(5),
        reason: 'the outputs of that one transaction, then the live set: a '
            'confirmation recomputes balances without being handed the rows, '
            'so its own read of them must leave the history out too');

    // And it is stable because the two counts the recalculation publishes
    // now come from the read model instead of from reading every row.
    expect(shallowStorage.spentCounts, greaterThan(0));
  });

  test('36jt: nothing in the library reads a wallet\'s spend history', () {
    // The guard on the guard. The test above measures the paths it drives;
    // this one states the property for the whole library, because the cost
    // it removes comes back the moment any code asks for the rows again --
    // and a spend history is never purged, so the ask grows for ever.
    //
    // `includeSpent: true` stays in the API: an app may legitimately want
    // every row a wallet has ever held. What must not come back is libspiffy
    // asking for them on a path that runs per event.
    final offenders = <String>[];
    for (final file in Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        // The backends implement the parameter; they are not callers of it.
        .where((f) => !f.path.startsWith('lib/src/storage/'))) {
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        if (line.trimLeft().startsWith('//') || line.trimLeft().startsWith('///')) {
          continue;
        }
        if (line.contains('includeSpent: true')) {
          offenders.add('${file.path}:${i + 1}: ${line.trim()}');
        }
      }
    }
    expect(offenders, isEmpty,
        reason: 'use getUTXO for one outpoint, getUTXOsByTxid for one '
            'transaction\'s outputs, or countSpentUTXOs when the answer is a '
            'count -- none of them reads the spend history (bead '
            'libspiffy-36jt)');
  });
}

class _NoopEventStore implements EventStore {
  @override
  Future<void> persistEvent(String persistenceId, Event event, int expectedVersion) async {}

  @override
  Future<void> persistEvents(String persistenceId, List<Event> events, int expectedVersion) async {}

  @override
  Future<List<Event>> getEvents(String persistenceId, {int fromSequence = 0, int? toSequence}) async =>
      [];

  @override
  Future<int> getHighestSequenceNumber(String persistenceId) async => 0;

  @override
  Future<void> saveSnapshot(String persistenceId, dynamic state, int sequenceNumber) async {}

  @override
  Future<SnapshotData?> loadSnapshot(String persistenceId) async => null;

  @override
  Future<void> deleteOldSnapshots(String persistenceId, int keepCount) async {}

  @override
  Future<void> close() async {}
}
