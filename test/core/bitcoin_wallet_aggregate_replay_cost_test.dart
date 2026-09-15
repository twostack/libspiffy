/// Audit 2026-09-14 M7 (libspiffy-5nd), aggregate part: recovery cost.
///
/// Every UTXO event recomputed the three balances by walking every UTXO the
/// wallet ever held (spent ones included), so replaying a journal of N UTXO
/// events walked O(N^2) UTXOs. Imported and outgoing transactions were
/// append-only lists, and confirming an outgoing transaction searched the
/// list linearly.
///
/// The fix keeps the balances incrementally (each transition moves only the
/// changed UTXO's amount between buckets) and keys the transaction records by
/// txid. These tests observe the work done (UTXOs visited during a replay),
/// and check that the incremental balances equal a full recomputation over a
/// randomized command sequence.
library;

import 'dart:math';

import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:test/test.dart';

import 'package:libspiffy/src/core/bitcoin_wallet_aggregate.dart';
import 'package:libspiffy/src/core/wallet_commands.dart';
import 'package:libspiffy/src/models/bitcoin_utxo.dart';
import 'package:libspiffy/src/models/persistent_map.dart';
import 'package:libspiffy/src/models/wallet_state.dart';
import 'package:libspiffy/src/models/wallet_type.dart';
import 'package:libspiffy/src/services/dartsv_crypto_service.dart';
import 'package:libspiffy/src/storage/in_memory_secure_storage.dart';

import '../actors/in_memory_event_store.dart';
import 'wallet_event_fixtures.dart';

const _walletId = 'wallet-replay-cost';
const _mnemonic = 'abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon abandon abandon about';

/// A wallet aggregate on a testnet initial state. UTXO visits are counted by
/// PersistentMapStats: the state copies any map it is given into a persistent
/// map, so a counting map can no longer be injected (bead libspiffy-mmb).
class _CountingWallet extends BitcoinWalletAggregate {

  _CountingWallet()
      : super(
          aggregateId: _walletId,
          aggregateType: 'BitcoinWallet',
          eventStore: InMemoryEventStore(),
          cryptoService: DartSVCryptoService(),
          secureStorage: InMemorySecureStorage(),
        );

  @override
  WalletState createInitialState() => WalletState(
        walletId: _walletId,
        name: '',
        isCreated: false,
        networkType: 'testnet',
        walletType: WalletType.hd,
        timestamp: DateTime.utc(2020),
        utxos: const {},
        addresses: {},
        nextDerivationIndex: 0,
        metadata: {},
        confirmedBalance: dartsv.Coin.ofSat(BigInt.zero),
        unconfirmedBalance: dartsv.Coin.ofSat(BigInt.zero),
        reservedBalance: dartsv.Coin.ofSat(BigInt.zero),
      );
}

void _expectBalancesMatchFullRecompute(WalletState state, String when) {
  final full = state.recalculateBalances();
  expect(state.confirmedBalance.getValue(), full.confirmedBalance.getValue(),
      reason: 'confirmed balance $when');
  expect(state.unconfirmedBalance.getValue(), full.unconfirmedBalance.getValue(),
      reason: 'unconfirmed balance $when');
  expect(state.reservedBalance.getValue(), full.reservedBalance.getValue(),
      reason: 'reserved balance $when');
}

void main() {
  group('M7: replay cost', () {
    test('replaying N UTXO events does not walk the UTXO set per event', () {
      const n = 300;
      final j = WalletJournalBuilder(_walletId)..created();
      for (var i = 0; i < n; i++) {
        j.received(i, 0, sats: 1000 + i);
      }
      for (var i = 0; i < n; i++) {
        j.confirmed(i, 0, 1 + i % 8);
      }
      for (var i = 0; i < n; i += 3) {
        j.reserved(i, 0);
      }
      for (var i = 0; i < n; i += 6) {
        j.released(i, 0, restored: UTXOStatus.available);
      }
      for (var i = 1; i < n; i += 3) {
        j.spent(i, 0);
      }
      final utxoEvents = j.events.length - 1;

      PersistentMapStats.reset();
      final wallet = _CountingWallet()..replay(j.events);
      final visited = PersistentMapStats.iteratedEntries;

      expect(wallet.currentState.utxos.length, n);
      expect(visited, lessThan(utxoEvents),
          reason: 'a replay of $utxoEvents UTXO events must visit O(N) UTXOs, '
              'not every UTXO per event');
      _expectBalancesMatchFullRecompute(wallet.currentState, 'after the replay');
    });

    test('imported and outgoing transactions are recorded once per txid', () {
      final j = WalletJournalBuilder(_walletId)..created();
      final firstImport = j.imported(1, blockHeight: 10);
      j.imported(1, blockHeight: 11); // re-import of the same transaction
      j.imported(2);
      j.recorded(3);
      final firstRecord = j.recorded(4);
      j.txConfirmed(4);
      j.recorded(4); // recorded again after confirmation

      final wallet = _CountingWallet()..replay(j.events);
      final metadata = wallet.currentState.metadata;

      final imported = metadata['importedTransactions'];
      expect(imported, isA<Map>(), reason: 'keyed by txid, not a list searched linearly');
      expect((imported as Map).keys.toList(),
          [WalletJournalBuilder.txid(1), WalletJournalBuilder.txid(2)],
          reason: 'one record per transaction, in first-import order');
      expect(imported[WalletJournalBuilder.txid(1)]['blockHeight'], 11);
      expect(imported[WalletJournalBuilder.txid(1)]['importedAt'],
          firstImport.timestamp.toIso8601String());

      final outgoing = metadata['outgoingTransactions'];
      expect(outgoing, isA<Map>());
      expect((outgoing as Map).keys.toList(),
          [WalletJournalBuilder.txid(3), WalletJournalBuilder.txid(4)]);
      expect(outgoing[WalletJournalBuilder.txid(4)]['recordedAt'],
          firstRecord.timestamp.toIso8601String());
      expect(outgoing[WalletJournalBuilder.txid(3)]['status'], 'pending');
      expect(outgoing[WalletJournalBuilder.txid(4)]['status'], 'confirmed',
          reason: 'a repeated record must not undo the confirmation');
      expect(outgoing[WalletJournalBuilder.txid(4)]['blockHeight'], 300);
    });
  });

  group('M7: incremental balances equal a full recomputation', () {
    for (final seed in [1, 2, 3, 42, 2026]) {
      test('randomized commands (seed $seed)', () async {
        final random = Random(seed);
        final store = InMemoryEventStore();
        final secureStorage = InMemorySecureStorage();
        final crypto = DartSVCryptoService();
        BitcoinWalletAggregate newWallet() => BitcoinWalletAggregate(
              aggregateId: _walletId,
              aggregateType: 'BitcoinWallet',
              eventStore: store,
              cryptoService: crypto,
              secureStorage: secureStorage,
            );

        final wallet = newWallet();
        await wallet.preStart();
        await wallet.commandHandler(CreateWalletCommand(
          walletId: _walletId,
          walletName: 'Random',
          mnemonic: _mnemonic,
        ));
        final address = wallet.currentState.rootAddress!;
        final script = dartsv.P2PKHLockBuilder.fromAddress(dartsv.Address.fromBase58(address))
            .getScriptPubkey()
            .toHex();

        final keys = <String>[];
        String anyKey() => keys[random.nextInt(keys.length)];
        var applied = 0;

        for (var step = 0; step < 250; step++) {
          final choice = keys.isEmpty ? 0 : random.nextInt(11);
          WalletCommand command;
          switch (choice) {
            case 0:
              final txid = WalletJournalBuilder.txid(step + 1);
              keys.add('$txid:0');
              command = ReceiveUTXOCommand(
                walletId: _walletId,
                txid: txid,
                vout: 0,
                satoshis: BigInt.from(500 + random.nextInt(100000)),
                scriptPubKey: script,
                address: address,
                initialStatus: random.nextBool() ? UTXOStatus.pending : UTXOStatus.available,
                confirmations: random.nextInt(8),
              );
            case 1:
              command = UpdateUTXOConfirmationsCommand(
                walletId: _walletId,
                utxoKey: anyKey(),
                confirmations: random.nextInt(10),
                blockHeight: 1000 + step,
              );
            case 2:
              command = ReserveUTXOCommand(
                walletId: _walletId,
                utxoKey: anyKey(),
                reservedByTxId: 'r${random.nextInt(3)}',
                priority: random.nextInt(3),
                reservationDuration: Duration(minutes: random.nextInt(3) - 1),
              );
            case 3:
              command = ReleaseUTXOCommand(walletId: _walletId, utxoKey: anyKey());
            case 4:
              command = SpendUTXOCommand(
                walletId: _walletId,
                utxoKey: anyKey(),
                spendingTxId: 'r${random.nextInt(3)}',
                fee: BigInt.zero,
              );
            case 5:
              final parts = anyKey().split(':');
              command = MarkUTXOAvailableCommand(
                  walletId: _walletId, txid: parts[0], vout: int.parse(parts[1]));
            case 6:
              command = ReserveUTXOsCommand(
                walletId: _walletId,
                utxoKeys: [anyKey(), anyKey()],
                reservationId: 'g${random.nextInt(2)}',
              );
            case 7:
              command = ReleaseUTXOsCommand(
                  walletId: _walletId, reservationId: 'g${random.nextInt(2)}');
            case 8:
              command = CleanupExpiredReservationsCommand(walletId: _walletId);
            case 9:
              command = RenewUTXOReservationCommand(
                walletId: _walletId,
                utxoKey: anyKey(),
                extensionDuration: const Duration(minutes: 5),
              );
            default:
              final txid = WalletJournalBuilder.txid(100000 + step);
              keys.add('$txid:1');
              command = ReceiveUTXOCommand(
                walletId: _walletId,
                txid: txid,
                vout: 1,
                satoshis: BigInt.from(1 + random.nextInt(5000)),
                scriptPubKey: script,
                address: address,
                initialStatus: UTXOStatus.available,
                confirmations: 6,
              );
          }
          try {
            await wallet.commandHandler(command);
            applied++;
          } on StateError {
            // Rejected by a business rule: nothing journaled.
          } on ArgumentError {
            // Rejected by a business rule: nothing journaled.
          }
          _expectBalancesMatchFullRecompute(
              wallet.currentState, 'after step $step (${command.runtimeType})');
        }
        expect(applied, greaterThan(100), reason: 'the sequence must exercise the rules');

        // Recovery from the journal lands on the same balances and UTXOs.
        final recovered = newWallet();
        await recovered.preStart();
        _expectBalancesMatchFullRecompute(recovered.currentState, 'after recovery');
        expect(recovered.currentState.confirmedBalance.getValue(),
            wallet.currentState.confirmedBalance.getValue());
        expect(recovered.currentState.unconfirmedBalance.getValue(),
            wallet.currentState.unconfirmedBalance.getValue());
        expect(recovered.currentState.reservedBalance.getValue(),
            wallet.currentState.reservedBalance.getValue());
        expect(
          recovered.currentState.utxos.map((k, u) => MapEntry(k, u.toMap())),
          wallet.currentState.utxos.map((k, u) => MapEntry(k, u.toMap())),
        );
      });
    }
  });
}
