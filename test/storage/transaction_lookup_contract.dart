/// Transaction lookup contract shared by the three [ReadModelStorage]
/// backends (bead libspiffy-ctkm): every wallet's rows of given txids
/// ([ReadModelStorage.getTransactionsByTxids]) and the confirmed rows at or
/// above a block height
/// ([ReadModelStorage.getConfirmedTransactionsFromHeight]), which SPVActor
/// uses instead of reading the confirmed history.
///
/// A Postgres database outlives a run and the height lookup spans every
/// wallet, so results are compared on the wallets of the running test only.
library;

import 'package:test/test.dart';

import 'package:libspiffy/src/models/bitcoin_transaction.dart';
import 'package:libspiffy/src/storage/read_model_storage.dart';

import 'read_model_keying_contract.dart' show contractHex64;

BitcoinTransaction _tx(
  String txid, {
  TransactionStatus status = TransactionStatus.confirmed,
  int? height,
  int minute = 0,
  int net = 1000,
  String rawHex = '0100000000000000000000',
}) =>
    BitcoinTransaction(
      txid: txid,
      rawHex: rawHex,
      status: status,
      blockHeight: height,
      confirmations: status == TransactionStatus.confirmed ? 1 : 0,
      inputValue: BigInt.from(2000),
      outputValue: BigInt.from(1800),
      fee: BigInt.from(200),
      receivingAddresses: const [],
      sendingAddresses: const [],
      netAmount: BigInt.from(net),
      createdAt: DateTime.utc(2026, 9, 15, 12, minute),
      updatedAt: DateTime.utc(2026, 9, 15, 12, minute),
      lockTime: 0,
      version: 1,
    );

/// Registers the transaction lookup contract tests.
///
/// [storage] returns the storage for the running test; [unique] a string
/// unique per test run.
void defineTransactionLookupContract(
  ReadModelStorage Function() storage, {
  required String Function() unique,
}) {
  group('transaction lookup contract (ctkm)', () {
    test('rows by txid: one row per wallet holding each txid, newest first, nothing for unknown txids',
        () async {
      final s = storage();
      final u = unique();
      final walletA = 'tl-a-$u';
      final walletB = 'tl-b-$u';
      final shared = contractHex64('tl-shared-$u');
      final onlyB = contractHex64('tl-only-b-$u');
      final other = contractHex64('tl-other-$u');
      final ancestor = contractHex64('tl-ancestor-$u');
      await s.storeWallet(walletA, 'A');
      await s.storeWallet(walletB, 'B');

      // A pays B; B also holds a pending transaction; A holds one not asked for.
      await s.storeTransaction(walletA, _tx(shared, height: 700, minute: 1, net: -1200));
      await s.storeTransaction(walletB, _tx(shared, height: 700, minute: 3, net: 1000));
      await s.storeTransaction(walletB, _tx(onlyB, status: TransactionStatus.pending, minute: 2));
      await s.storeTransaction(walletA, _tx(other, height: 701, minute: 4));
      await s.storeAncestorTransaction(ancestor, '01000000');

      final rows = await s.getTransactionsByTxids(
          [shared, onlyB, shared, ancestor, contractHex64('tl-unknown-$u')]);

      expect([for (final t in rows) (t.walletId, t.txid, t.status, t.netAmount.toInt())], [
        (walletB, shared, TransactionStatus.confirmed, 1000),
        (walletB, onlyB, TransactionStatus.pending, 1000),
        (walletA, shared, TransactionStatus.confirmed, -1200),
      ]);
      expect(rows.first.rawHex, '0100000000000000000000');
      expect(rows.first.blockHeight, 700);
      expect(await s.getTransactionsByTxids(const []), isEmpty);
      expect(await s.getTransactionsByTxids([ancestor]), isEmpty,
          reason: 'ancestor transactions are not wallet rows');
    });

    test('rows by txid follow updates and wallet deletion', () async {
      final s = storage();
      final u = unique();
      final walletA = 'tl-da-$u';
      final walletB = 'tl-db-$u';
      final txid = contractHex64('tl-del-$u');
      await s.storeWallet(walletA, 'A');
      await s.storeWallet(walletB, 'B');
      await s.storeTransaction(walletA, _tx(txid, status: TransactionStatus.pending, minute: 1));
      await s.storeTransaction(walletB, _tx(txid, status: TransactionStatus.pending, minute: 2));

      await s.storeTransaction(walletA, _tx(txid, height: 800, minute: 1, rawHex: ''));
      var rows = await s.getTransactionsByTxids([txid]);
      expect([for (final t in rows) (t.walletId, t.status, t.blockHeight)], [
        (walletB, TransactionStatus.pending, null),
        (walletA, TransactionStatus.confirmed, 800),
      ]);
      expect(rows.last.rawHex, '0100000000000000000000', reason: 'an update without raw hex keeps it');

      await s.deleteWallet(walletB);
      rows = await s.getTransactionsByTxids([txid]);
      expect([for (final t in rows) t.walletId], [walletA]);
    });

    test('confirmed rows from a height: the boundary height included, lower heights and other statuses excluded',
        () async {
      final s = storage();
      final u = unique();
      final walletA = 'tl-ha-$u';
      final walletB = 'tl-hb-$u';
      await s.storeWallet(walletA, 'A');
      await s.storeWallet(walletB, 'B');
      String t(String tag) => contractHex64('tl-h-$tag-$u');
      const fork = 900;

      await s.storeTransaction(walletA, _tx(t('below'), height: fork - 1, minute: 1));
      await s.storeTransaction(walletA, _tx(t('at'), height: fork, minute: 2));
      await s.storeTransaction(walletB, _tx(t('at'), height: fork, minute: 3));
      await s.storeTransaction(walletB, _tx(t('above'), height: fork + 1, minute: 4));
      await s.storeTransaction(walletA, _tx(t('no-height'), minute: 5));
      await s.storeTransaction(walletB, _tx(t('pending'), status: TransactionStatus.pending, height: fork + 5, minute: 6));
      await s.storeTransaction(walletA, _tx(t('failed'), status: TransactionStatus.failed, minute: 7));

      Future<List<(String?, String, int?)>> fromHeight(int minHeight, {bool includeWithoutHeight = false}) async => [
            for (final tx in await s.getConfirmedTransactionsFromHeight(minHeight,
                includeWithoutHeight: includeWithoutHeight))
              if (tx.walletId == walletA || tx.walletId == walletB) (tx.walletId, tx.txid, tx.blockHeight),
          ];

      expect(await fromHeight(fork), [
        (walletB, t('above'), fork + 1),
        (walletB, t('at'), fork),
        (walletA, t('at'), fork),
      ]);
      expect(await fromHeight(fork + 1), [(walletB, t('above'), fork + 1)]);
      expect(await fromHeight(fork + 2), isEmpty);
      expect(await fromHeight(fork + 2, includeWithoutHeight: true), [(walletA, t('no-height'), null)]);
      expect(await fromHeight(fork - 1, includeWithoutHeight: true), [
        (walletA, t('no-height'), null),
        (walletB, t('above'), fork + 1),
        (walletB, t('at'), fork),
        (walletA, t('at'), fork),
        (walletA, t('below'), fork - 1),
      ]);
      final row = (await s.getConfirmedTransactionsFromHeight(fork + 1))
          .firstWhere((tx) => tx.walletId == walletB);
      expect((row.status, row.rawHex, row.netAmount.toInt()), (TransactionStatus.confirmed, '0100000000000000000000', 1000));
    });

    test('confirmed rows from a height follow confirmation, reverted confirmation, height change and wallet deletion',
        () async {
      final s = storage();
      final u = unique();
      final walletA = 'tl-ua-$u';
      final walletB = 'tl-ub-$u';
      await s.storeWallet(walletA, 'A');
      await s.storeWallet(walletB, 'B');
      String t(String tag) => contractHex64('tl-u-$tag-$u');
      const fork = 950;

      Future<List<(String?, String, int?)>> fromFork() async => [
            for (final tx in await s.getConfirmedTransactionsFromHeight(fork, includeWithoutHeight: true))
              if (tx.walletId == walletA || tx.walletId == walletB) (tx.walletId, tx.txid, tx.blockHeight),
          ];

      // Received unconfirmed, then confirmed above the fork.
      await s.storeTransaction(walletA, _tx(t('x'), status: TransactionStatus.pending, minute: 1));
      expect(await fromFork(), isEmpty);
      await s.storeTransaction(walletA, _tx(t('x'), height: fork + 2, minute: 1));
      // A confirmed update without a height keeps the stored height.
      await s.storeTransaction(walletA, _tx(t('x'), minute: 1));
      expect(await fromFork(), [(walletA, t('x'), fork + 2)]);

      // Re-mined lower: moves below the fork.
      await s.storeTransaction(walletA, _tx(t('x'), height: fork - 10, minute: 1));
      expect(await fromFork(), isEmpty);

      // Confirmation reverted (reorg): pending, height cleared.
      await s.storeTransaction(walletB, _tx(t('y'), height: fork + 1, minute: 2));
      expect(await fromFork(), [(walletB, t('y'), fork + 1)]);
      await s.storeTransaction(walletB, _tx(t('y'), status: TransactionStatus.pending, minute: 2));
      expect(await fromFork(), isEmpty);
      expect((await s.getTransactionsByTxids([t('y')])).single.blockHeight, isNull);

      // Deleting a wallet removes its rows.
      await s.storeTransaction(walletB, _tx(t('z'), height: fork + 3, minute: 3));
      await s.storeTransaction(walletA, _tx(t('z'), height: fork + 3, minute: 4));
      expect(await fromFork(), [(walletA, t('z'), fork + 3), (walletB, t('z'), fork + 3)]);
      await s.deleteWallet(walletA);
      expect(await fromFork(), [(walletB, t('z'), fork + 3)]);
    });
  });
}
