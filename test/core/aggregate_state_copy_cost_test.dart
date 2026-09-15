/// libspiffy-mmb: the cost of copy-on-write wallet state.
///
/// Every event now yields a new WalletState. Copying the UTXO map (or the
/// address or transaction records) for each event would make a replay of N
/// events O(N^2); the state's collections are persistent maps instead, and
/// an event replaces only the collections it changes. These tests observe
/// the work done during a replay (slots copied, collections shared), not
/// wall-clock time.
library;

import 'package:test/test.dart';

import 'package:libspiffy/src/core/bitcoin_wallet_aggregate.dart';
import 'package:libspiffy/src/models/bitcoin_utxo.dart';
import 'package:libspiffy/src/models/persistent_map.dart';
import 'package:libspiffy/src/models/wallet_event.dart';
import 'package:libspiffy/src/models/wallet_state.dart';
import 'package:libspiffy/src/services/dartsv_crypto_service.dart';
import 'package:libspiffy/src/storage/in_memory_secure_storage.dart';

import '../actors/in_memory_event_store.dart';
import 'wallet_event_fixtures.dart';

const _walletId = 'mmb-copy-cost';

BitcoinWalletAggregate _wallet() => BitcoinWalletAggregate(
      aggregateId: _walletId,
      aggregateType: 'BitcoinWallet',
      eventStore: InMemoryEventStore(),
      cryptoService: DartSVCryptoService(),
      secureStorage: InMemorySecureStorage(),
    );

/// A large journal: [n] UTXOs received, confirmed, a third reserved and
/// released, a third spent, [n] ~/ 4 addresses and transaction records.
List<WalletEvent> _largeJournal(int n) {
  final j = WalletJournalBuilder(_walletId)..created();
  for (var i = 0; i < n; i++) {
    j.received(i, 0, sats: 1000 + i);
    if (i % 4 == 0) j.address('maddress$i', i + 1, change: i % 8 == 0);
  }
  for (var i = 0; i < n; i++) {
    j.confirmed(i, 0, 1 + i % 8);
  }
  for (var i = 0; i < n; i += 3) {
    j.reserved(i, 0);
    j.released(i, 0, restored: UTXOStatus.available);
  }
  for (var i = 1; i < n; i += 3) {
    j.spent(i, 0);
  }
  for (var i = 0; i < n; i += 4) {
    j.imported(100000 + i);
    j.recorded(200000 + i);
    j.txConfirmed(200000 + i);
  }
  return j.events;
}

void main() {
  group('mmb: copy-on-write cost', () {
    test('replaying N events copies O(log n) slots per event, never a whole collection', () {
      const n = 4000;
      final journal = _largeJournal(n);
      final wallet = _wallet();
      wallet.replay(journal.sublist(0, 1));

      PersistentMapStats.reset();
      var maxPerEvent = 0;
      for (final event in journal.skip(1)) {
        final before = PersistentMapStats.copiedSlots;
        wallet.eventHandler(event);
        final copied = PersistentMapStats.copiedSlots - before;
        if (copied > maxPerEvent) maxPerEvent = copied;
      }
      final events = journal.length - 1;
      final perEvent = PersistentMapStats.copiedSlots / events;

      expect(wallet.currentState.utxos.length, n);
      // One copy of the UTXO map alone would be n = 4000 slots; replaying
      // with such copies would copy about n / 2 slots per UTXO event.
      expect(maxPerEvent, lessThan(600), reason: 'the most slots one event copied');
      expect(perEvent, lessThan(250), reason: 'slots copied per event on average over $events events');
      expect(PersistentMapStats.fullBuilds, lessThan(events),
          reason: 'only small records are built whole (one per record written)');

      // The replayed state equals one built without structural sharing.
      final rebuilt = WalletState.fromMap(wallet.currentState.toMap());
      expect(rebuilt.toMap(), wallet.currentState.toMap());
    });

    test('an event replaces only the collections it changes', () {
      final journal = _largeJournal(40);
      final wallet = _wallet()..replay(journal);
      final j = WalletJournalBuilder(_walletId, start: DateTime.utc(2030), firstVersion: journal.length + 1);

      void expectShared(WalletState before, WalletState after, Set<String> changed, String what) {
        final collections = {
          'utxos': (before.utxos, after.utxos),
          'addresses': (before.addresses, after.addresses),
          'watchAddresses': (before.watchAddresses, after.watchAddresses),
          'metadata': (before.metadata, after.metadata),
        };
        for (final MapEntry(key: name, value: (a, b)) in collections.entries) {
          expect(identical(a, b), !changed.contains(name),
              reason: '$what ${changed.contains(name) ? 'replaces' : 'shares'} $name');
        }
      }

      final steps = <(WalletEvent, Set<String>, String)>[
        (j.received(9000, 1), {'utxos'}, 'a received UTXO'),
        (j.confirmed(9000, 1, 3), {'utxos'}, 'a confirmation'),
        (j.address('mnewaddress', 99), {'addresses', 'metadata'}, 'a generated address'),
        (j.recorded(9001), {'metadata'}, 'a recorded transaction'),
      ];
      for (final (event, changed, what) in steps) {
        final before = wallet.currentState;
        wallet.eventHandler(event);
        expectShared(before, wallet.currentState, changed, what);
      }

      // Within metadata, only the records the event wrote are replaced.
      final before = wallet.currentState;
      wallet.eventHandler(j.imported(9002));
      expect(identical(before.metadata['outgoingTransactions'], wallet.currentState.metadata['outgoingTransactions']),
          isTrue);
      expect(identical(before.metadata['address_indices'], wallet.currentState.metadata['address_indices']), isTrue);
      expect(identical(before.metadata['importedTransactions'], wallet.currentState.metadata['importedTransactions']),
          isFalse);
    });
  });
}
