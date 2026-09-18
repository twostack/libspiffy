/// Audit 2026-09-14 M7 (libspiffy-5nd), projection part.
///
/// Each UTXO event made the wallet projection load every UTXO row of the
/// wallet (spent ones included) twice: once to find the row the event is
/// about, and again to recompute the address and wallet balances. These tests
/// count the full UTXO loads with a counting storage.
///
/// `ReadModelStorage` has no point lookup for one outpoint, so one full load
/// per event remains (follow-up for the storage lane).
library;

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

/// In-memory read model that counts full UTXO loads.
class _CountingStorage extends InMemoryWalletStorage {
  int utxoLoads = 0;

  @override
  Future<List<BitcoinUtxo>> getUTXOs(String walletId, {bool includeSpent = false}) {
    utxoLoads++;
    return super.getUTXOs(walletId, includeSpent: includeSpent);
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
