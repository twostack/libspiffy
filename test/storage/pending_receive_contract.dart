/// Parked-receive contract shared by the three [ReadModelStorage] backends
/// (bead libspiffy-vfai).
///
/// A BEEF whose merkle proof names a block our headers have not reached
/// proves nothing yet, so the receive waits. The wait has to survive a
/// restart: no counterparty can be asked to send the BEEF again.
library;

import 'package:test/test.dart';

import 'package:libspiffy/src/storage/read_model_storage.dart';

import 'read_model_keying_contract.dart' show contractHex64;

/// Registers the contract tests. [storage] returns the storage for the
/// running test; [unique] a string unique per test run (the Postgres database
/// outlives a run).
void definePendingReceiveContract(
  ReadModelStorage Function() storage, {
  required String Function() unique,
}) {
  PendingReceive parked(
    String walletId,
    String txid, {
    required int neededHeight,
    String beefHex = '0100beef',
    String? invoiceId,
    DateTime? createdAt,
  }) =>
      PendingReceive(
        walletId: walletId,
        txid: txid,
        beefHex: beefHex,
        fromCounterparty: 'bob',
        invoiceId: invoiceId,
        neededHeight: neededHeight,
        createdAt: createdAt ?? DateTime.utc(2026, 9, 16, 12),
        updatedAt: createdAt ?? DateTime.utc(2026, 9, 16, 12),
      );

  group('parked receive contract (vfai)', () {
    test('vfai: a parked receive is read back whole, by wallet and txid', () async {
      final u = unique();
      final s = storage();
      final wallet = 'pr-wallet-$u';
      final txid = contractHex64('pr-a-$u');

      await s.storePendingReceive(parked(wallet, txid, neededHeight: 812345, invoiceId: 'inv-$u'));

      final row = await s.getPendingReceive(wallet, txid);
      expect(
          (row?.beefHex, row?.fromCounterparty, row?.invoiceId, row?.neededHeight, row?.isWaiting),
          ('0100beef', 'bob', 'inv-$u', 812345, true));
      expect(await s.getPendingReceive(wallet, contractHex64('pr-none-$u')), isNull);
      expect(await s.getPendingReceive('pr-other-$u', txid), isNull,
          reason: 'rows are keyed by wallet and txid');
    });

    test('vfai: parking the same receive again updates the row and keeps its first time', () async {
      final u = unique();
      final s = storage();
      final wallet = 'pr-again-$u';
      final txid = contractHex64('pr-again-tx-$u');
      final first = DateTime.utc(2026, 9, 16, 9);

      await s.storePendingReceive(parked(wallet, txid, neededHeight: 10, createdAt: first));
      await s.storePendingReceive(PendingReceive(
        walletId: wallet,
        txid: txid,
        beefHex: '0100beef22',
        fromCounterparty: 'bob',
        neededHeight: 12,
        createdAt: DateTime.utc(2026, 9, 16, 11),
        updatedAt: DateTime.utc(2026, 9, 16, 11),
      ));

      final row = (await s.getPendingReceive(wallet, txid))!;
      expect((row.beefHex, row.neededHeight), ('0100beef22', 12));
      expect(row.createdAt.toUtc(), first, reason: 'the row keeps the time it was first parked');
      expect((await s.getPendingReceivesUpToHeight(12)).where((r) => r.txid == txid), hasLength(1),
          reason: 'one receive must be replayed once, not twice');
    });

    test('vfai: only the waiting receives at or below the height are read, oldest first', () async {
      final u = unique();
      final s = storage();
      final wallet = 'pr-height-$u';
      final early = contractHex64('pr-early-$u');
      final later = contractHex64('pr-later-$u');
      final tooHigh = contractHex64('pr-high-$u');

      await s.storePendingReceive(
          parked(wallet, later, neededHeight: 100, createdAt: DateTime.utc(2026, 9, 16, 10)));
      await s.storePendingReceive(
          parked(wallet, early, neededHeight: 90, createdAt: DateTime.utc(2026, 9, 16, 8)));
      await s.storePendingReceive(
          parked(wallet, tooHigh, neededHeight: 200, createdAt: DateTime.utc(2026, 9, 16, 9)));

      final ready = [
        for (final row in await s.getPendingReceivesUpToHeight(100))
          if (row.walletId == wallet) row.txid,
      ];
      expect(ready, [early, later], reason: 'oldest first, and nothing above the height');

      final capped = await s.getPendingReceivesUpToHeight(100, limit: 1);
      expect(capped, hasLength(1), reason: 'the limit bounds one replay pass');
      expect(() => s.getPendingReceivesUpToHeight(100, limit: 0), throwsA(isA<ArgumentError>()));
    });

    test('vfai: a resolved receive keeps its BEEF and is never replayed again', () async {
      final u = unique();
      final s = storage();
      final wallet = 'pr-resolve-$u';
      final txid = contractHex64('pr-resolve-tx-$u');

      await s.storePendingReceive(parked(wallet, txid, neededHeight: 5));
      expect(await s.resolvePendingReceive(wallet, txid, 'recorded'), isTrue);
      expect(await s.resolvePendingReceive(wallet, txid, 'recorded'), isFalse,
          reason: 'resolving again changes nothing');
      expect(await s.resolvePendingReceive(wallet, contractHex64('pr-absent-$u'), 'recorded'), isFalse);

      final row = (await s.getPendingReceive(wallet, txid))!;
      expect((row.isWaiting, row.resolution, row.beefHex), (false, 'recorded', '0100beef'),
          reason: 'the BEEF a counterparty handed us is kept with the outcome');
      expect((await s.getPendingReceivesUpToHeight(1000)).where((r) => r.txid == txid), isEmpty);
    });

    test('vfai: a wallet deletion removes its parked receives', () async {
      final u = unique();
      final s = storage();
      final wallet = 'pr-deleted-$u';
      final other = 'pr-kept-$u';
      final txid = contractHex64('pr-deleted-tx-$u');

      await s.storeWallet(wallet, 'W');
      await s.storeWallet(other, 'W2');
      await s.storePendingReceive(parked(wallet, txid, neededHeight: 7));
      await s.storePendingReceive(parked(other, txid, neededHeight: 7));

      await s.deleteWallet(wallet);

      expect(await s.getPendingReceive(wallet, txid), isNull);
      expect(await s.getPendingReceive(other, txid), isNotNull,
          reason: 'another wallet parked the same txid and keeps its row');
    });
  });
}
