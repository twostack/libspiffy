/// Audit 2026-09-14 L1 (libspiffy-69i): applying a wallet event must depend
/// on the event alone.
///
/// The UTXO transitions used by the aggregate's apply handlers
/// (BitcoinUtxo.create, markSpent, markAvailable, updateConfirmations,
/// releaseReservation, renewReservation) stamped `DateTime.now()`, so a
/// UTXO's createdAt/updatedAt after a replay (restart, snapshot, eviction and
/// reload) differed from the live state that applied the same events.
library;

import 'package:test/test.dart';

import 'package:libspiffy/src/core/bitcoin_wallet_aggregate.dart';
import 'package:libspiffy/src/models/bitcoin_utxo.dart';
import 'package:libspiffy/src/services/dartsv_crypto_service.dart';
import 'package:libspiffy/src/storage/in_memory_secure_storage.dart';

import '../actors/in_memory_event_store.dart';
import 'wallet_event_fixtures.dart';

const _walletId = 'wallet-deterministic-apply';

BitcoinWalletAggregate _aggregate() => BitcoinWalletAggregate(
      aggregateId: _walletId,
      aggregateType: 'BitcoinWallet',
      eventStore: InMemoryEventStore(),
      cryptoService: DartSVCryptoService(),
      secureStorage: InMemorySecureStorage(),
    );

void main() {
  group('L1: UTXO timestamps come from the events', () {
    test('every UTXO transition records its event timestamp', () {
      final j = WalletJournalBuilder(_walletId);
      final wallet = _aggregate();
      BitcoinUtxo utxo(int tx) => wallet.currentState.utxos['${WalletJournalBuilder.txid(tx)}:0']!;

      j.created();
      final receivedA = j.received(1, 0);
      final receivedB = j.received(2, 0);
      wallet.replay(j.events);
      expect(utxo(1).createdAt, receivedA.timestamp);
      expect(utxo(1).updatedAt, receivedA.timestamp);
      expect(utxo(2).createdAt, receivedB.timestamp);

      final confirmedA = j.confirmed(1, 0, 3);
      wallet.replay(j.events);
      expect(utxo(1).status, UTXOStatus.available);
      expect(utxo(1).updatedAt, confirmedA.timestamp, reason: 'updateConfirmations');
      expect(utxo(1).createdAt, receivedA.timestamp);

      final availableB = j.markedAvailable(2, 0);
      wallet.replay(j.events);
      expect(utxo(2).updatedAt, availableB.timestamp, reason: 'markAvailable');

      final reservedA = j.reserved(1, 0);
      wallet.replay(j.events);
      expect(utxo(1).updatedAt, reservedA.timestamp, reason: 'reserve');

      final renewedA = j.renewed(1, 0, reservedA.expiresAt, const Duration(minutes: 10));
      wallet.replay(j.events);
      expect(utxo(1).updatedAt, renewedA.timestamp, reason: 'renewReservation');
      expect(utxo(1).reservationExpiresAt, renewedA.newExpiresAt);

      final releasedA = j.released(1, 0, restored: UTXOStatus.available);
      wallet.replay(j.events);
      expect(utxo(1).status, UTXOStatus.available);
      expect(utxo(1).updatedAt, releasedA.timestamp, reason: 'releaseReservation');

      final spentB = j.spent(2, 0);
      wallet.replay(j.events);
      expect(utxo(2).status, UTXOStatus.spent);
      expect(utxo(2).updatedAt, spentB.timestamp, reason: 'markSpent');
    });

    test('two replays of one journal produce identical UTXO state', () async {
      final j = WalletJournalBuilder(_walletId)..created();
      for (var i = 0; i < 5; i++) {
        j.received(i, 0);
      }
      j.confirmed(0, 0, 7);
      j.markedAvailable(1, 0);
      j.reserved(2, 0);
      j.released(2, 0, restored: UTXOStatus.pending);
      j.spent(1, 0);

      final first = _aggregate()..replay(j.events);
      await Future<void>.delayed(const Duration(milliseconds: 2));
      final second = _aggregate()..replay(j.events);

      expect(
        second.currentState.utxos.map((k, u) => MapEntry(k, u.toMap())),
        first.currentState.utxos.map((k, u) => MapEntry(k, u.toMap())),
      );
    });
  });
}
