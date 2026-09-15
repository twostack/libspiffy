/// Transaction row status and counterparty contract shared by the three
/// [ReadModelStorage] backends (bead libspiffy-7dj).
///
/// 1. A later, less complete record of a transaction (a stale ARC report, a
///    re-delivered BEEF without its proof, an import replay) never lowers the
///    stored status: a confirmed row keeps its status, block height and
///    confirmations, and a row never goes back along created, signed,
///    broadcast / pending, seenOnNetwork. Only
///    [ReadModelStorage.storeRevertedTransaction] (a reorganization or a
///    rejected proof) takes a confirmation back.
/// 2. The stored primary counterparty is the same on every backend that
///    stores one: the first sending address of an incoming transaction, the
///    first receiving address of an outgoing one, none otherwise.
library;

import 'package:test/test.dart';

import 'package:libspiffy/src/models/bitcoin_transaction.dart';
import 'package:libspiffy/src/storage/read_model_storage.dart';

import 'read_model_keying_contract.dart' show contractHex64;

BitcoinTransaction _tx(
  String txid, {
  required TransactionStatus status,
  int? height,
  int? confirmations,
  int second = 0,
  int net = 1000,
  String rawHex = '0100000000000000000000',
  List<String> receiving = const [],
  List<String> sending = const [],
}) =>
    BitcoinTransaction(
      txid: txid,
      rawHex: rawHex,
      status: status,
      blockHeight: height,
      confirmations: confirmations ?? (status == TransactionStatus.confirmed ? 1 : 0),
      inputValue: BigInt.from(5000),
      outputValue: BigInt.from(4800),
      fee: BigInt.from(200),
      receivingAddresses: receiving,
      sendingAddresses: sending,
      netAmount: BigInt.from(net),
      createdAt: DateTime.utc(2026, 9, 15, 12),
      updatedAt: DateTime.utc(2026, 9, 15, 12, 0, second),
      lockTime: 0,
      version: 1,
    );

/// The counterparty columns a backend stores for a transaction row.
typedef StoredCounterparty = ({String? primaryCounterparty, String? counterparty});

/// Registers the transaction status and counterparty contract tests.
///
/// [storage] returns the storage for the running test; [unique] a string
/// unique per test run. [storedCounterparty] reads the stored counterparty
/// columns of a row (null when the row is missing); a backend that stores no
/// such columns (the in-memory one) passes none and skips those tests.
void defineTransactionStatusContract(
  ReadModelStorage Function() storage, {
  required String Function() unique,
  Future<StoredCounterparty?> Function(String walletId, String txid)? storedCounterparty,
}) {
  group('transaction status contract (7dj)', () {
    test('a stale record after the confirmation keeps confirmed, its height, confirmations and proof', () async {
      final s = storage();
      final u = unique();
      final wallet = 'ts-stale-$u';
      await s.storeWallet(wallet, 'W');
      final txid = contractHex64('ts-stale-tx-$u');
      const height = 870;

      await s.storeTransaction(wallet, _tx(txid, status: TransactionStatus.broadcast));
      await s.storeTransaction(wallet, _tx(txid, status: TransactionStatus.confirmed, height: height, confirmations: 3));
      await s.storeMerkleProof(txid, MerkleProof(
        txid: txid,
        blockHash: contractHex64('ts-stale-block-$u'),
        blockHeight: height,
        merkleProof: ['fe${contractHex64('ts-stale-bump-$u')}'],
        position: 1,
      ));

      var second = 1;
      for (final stale in [
        // ARC SEEN_ON_NETWORK processed after MINED: the projection copies
        // the stored row with the new status (height kept).
        _tx(txid, status: TransactionStatus.seenOnNetwork, height: height, confirmations: 3),
        // A re-delivered BEEF or an import replay without the proof.
        _tx(txid, status: TransactionStatus.pending, rawHex: ''),
        _tx(txid, status: TransactionStatus.broadcast),
        // A stale REJECTED / orphan-mempool report.
        _tx(txid, status: TransactionStatus.failed),
        _tx(txid, status: TransactionStatus.orphaned),
      ]) {
        await s.storeTransaction(wallet, _tx(
          txid,
          status: stale.status,
          height: stale.blockHeight,
          confirmations: stale.confirmations,
          rawHex: stale.rawHex,
          second: second++,
        ));
        final row = (await s.getTransaction(txid, walletId: wallet))!;
        final what = 'after a stale ${stale.status.name} record';
        expect(row.status, TransactionStatus.confirmed, reason: what);
        expect(row.blockHeight, height, reason: what);
        expect(row.confirmations, 3, reason: what);
        expect(row.rawHex, '0100000000000000000000', reason: what);
        expect([for (final t in await s.getTransactionsByStatus(TransactionStatus.confirmed, walletId: wallet)) t.txid],
            [txid], reason: what);
        expect(await s.getTransactionsByStatus(stale.status, walletId: wallet), isEmpty, reason: what);
        expect([
          for (final t in await s.getConfirmedTransactionsFromHeight(height))
            if (t.walletId == wallet) (t.txid, t.blockHeight)
        ], [(txid, height)], reason: '$what: a reorganization still finds the confirmation');
        expect((await s.getMerkleProof(txid))?.blockHeight, height, reason: what);
      }
    });

    test('a stale record does not take a transaction back along its lifecycle', () async {
      final s = storage();
      final u = unique();
      final wallet = 'ts-order-$u';
      await s.storeWallet(wallet, 'W');
      final txid = contractHex64('ts-order-tx-$u');
      Future<TransactionStatus> statusAfter(TransactionStatus status, int second) async {
        await s.storeTransaction(wallet, _tx(txid, status: status, second: second));
        return (await s.getTransaction(txid, walletId: wallet))!.status;
      }

      expect(await statusAfter(TransactionStatus.created, 0), TransactionStatus.created);
      expect(await statusAfter(TransactionStatus.signed, 1), TransactionStatus.signed);
      expect(await statusAfter(TransactionStatus.created, 2), TransactionStatus.signed);
      // Recorded pending, then ARC's first answer (STORED): the same stage.
      expect(await statusAfter(TransactionStatus.pending, 3), TransactionStatus.pending);
      expect(await statusAfter(TransactionStatus.broadcast, 4), TransactionStatus.broadcast);
      expect(await statusAfter(TransactionStatus.pending, 5), TransactionStatus.pending);
      expect(await statusAfter(TransactionStatus.seenOnNetwork, 6), TransactionStatus.seenOnNetwork);
      for (final stale in [
        TransactionStatus.broadcast,
        TransactionStatus.pending,
        TransactionStatus.signed,
        TransactionStatus.created,
      ]) {
        expect(await statusAfter(stale, 7), TransactionStatus.seenOnNetwork, reason: 'stale ${stale.name}');
      }
    });

    test('a later status still applies: orphan mempool, failure and a confirmation after either', () async {
      final s = storage();
      final u = unique();
      final wallet = 'ts-later-$u';
      await s.storeWallet(wallet, 'W');
      final txid = contractHex64('ts-later-tx-$u');
      Future<TransactionStatus> statusAfter(TransactionStatus status, int second) async {
        await s.storeTransaction(wallet, _tx(txid, status: status, second: second, height: status == TransactionStatus.confirmed ? 900 : null));
        return (await s.getTransaction(txid, walletId: wallet))!.status;
      }

      expect(await statusAfter(TransactionStatus.seenOnNetwork, 0), TransactionStatus.seenOnNetwork);
      expect(await statusAfter(TransactionStatus.orphaned, 1), TransactionStatus.orphaned);
      expect(await statusAfter(TransactionStatus.broadcast, 2), TransactionStatus.broadcast,
          reason: 'rebroadcast after orphan remediation');
      expect(await statusAfter(TransactionStatus.seenOnNetwork, 3), TransactionStatus.seenOnNetwork);
      expect(await statusAfter(TransactionStatus.failed, 4), TransactionStatus.failed,
          reason: 'DOUBLE_SPEND_ATTEMPTED after SEEN_ON_NETWORK');
      expect(await statusAfter(TransactionStatus.seenOnNetwork, 5), TransactionStatus.seenOnNetwork);
      expect(await statusAfter(TransactionStatus.confirmed, 6), TransactionStatus.confirmed);
      expect((await s.getTransaction(txid, walletId: wallet))!.blockHeight, 900);
    });

    test('only a reverted record takes the confirmation back; the row is kept and can confirm again', () async {
      final s = storage();
      final u = unique();
      final wallet = 'ts-revert-$u';
      final other = 'ts-revert-other-$u';
      await s.storeWallet(wallet, 'W');
      await s.storeWallet(other, 'O');
      final txid = contractHex64('ts-revert-tx-$u');
      Future<List<(String?, int?)>> fromHeight(int height) async => [
            for (final t in await s.getConfirmedTransactionsFromHeight(height, includeWithoutHeight: true))
              if (t.walletId == wallet || t.walletId == other) (t.walletId, t.blockHeight)
          ];

      await s.storeTransaction(wallet, _tx(txid, status: TransactionStatus.confirmed, height: 700, confirmations: 2));
      await s.storeTransaction(other, _tx(txid, status: TransactionStatus.confirmed, height: 700));
      expect(await fromHeight(700), unorderedEquals([(wallet, 700), (other, 700)]));

      // A reorganization past block 700.
      await s.storeRevertedTransaction(wallet, _tx(txid, status: TransactionStatus.pending, rawHex: '', second: 1));
      var row = (await s.getTransaction(txid, walletId: wallet))!;
      expect(row.status, TransactionStatus.pending);
      expect(row.blockHeight, isNull);
      expect(row.confirmations ?? 0, 0);
      expect(row.rawHex, '0100000000000000000000', reason: 'the transaction itself is kept');
      expect(await fromHeight(700), [(other, 700)], reason: "another wallet's row is not touched");

      // Seen again, then mined again in the new chain.
      await s.storeTransaction(wallet, _tx(txid, status: TransactionStatus.seenOnNetwork, second: 2));
      expect((await s.getTransaction(txid, walletId: wallet))!.status, TransactionStatus.seenOnNetwork);
      await s.storeTransaction(wallet, _tx(txid, status: TransactionStatus.confirmed, height: 702, second: 3));
      row = (await s.getTransaction(txid, walletId: wallet))!;
      expect((row.status, row.blockHeight), (TransactionStatus.confirmed, 702));
    });

    if (storedCounterparty != null) {
      test('the primary counterparty of a multi-input, multi-output transaction', () async {
        final s = storage();
        final u = unique();
        final wallet = 'ts-cp-$u';
        await s.storeWallet(wallet, 'W');
        final incoming = contractHex64('ts-cp-in-$u');
        final outgoing = contractHex64('ts-cp-out-$u');
        final self = contractHex64('ts-cp-self-$u');

        // Received: two inputs from two senders, paying two of our addresses.
        await s.storeTransaction(wallet, _tx(incoming,
            status: TransactionStatus.pending,
            net: 3000,
            receiving: const ['ours-1', 'ours-2'],
            sending: const ['sender-1', 'sender-2']));
        // Sent: two payees (change is not listed).
        await s.storeTransaction(wallet, _tx(outgoing,
            status: TransactionStatus.pending,
            net: -2200,
            receiving: const ['payee-1', 'payee-2'],
            sending: const ['ours-3', 'ours-4']));
        // Moved between our own addresses: no counterparty.
        await s.storeTransaction(wallet, _tx(self,
            status: TransactionStatus.pending,
            net: 0,
            receiving: const ['ours-5', 'ours-6'],
            sending: const ['ours-1', 'ours-2']));

        expect(await storedCounterparty(wallet, incoming), (primaryCounterparty: 'sender-1', counterparty: 'sender-1'));
        expect(await storedCounterparty(wallet, outgoing), (primaryCounterparty: 'payee-1', counterparty: 'payee-1'));
        expect(await storedCounterparty(wallet, self), (primaryCounterparty: null, counterparty: null));

        // An update keeps the columns derived from the stored record.
        await s.storeTransaction(wallet, _tx(incoming,
            status: TransactionStatus.confirmed,
            height: 10,
            net: 3000,
            second: 1,
            receiving: const ['ours-1', 'ours-2'],
            sending: const ['sender-1', 'sender-2']));
        expect(await storedCounterparty(wallet, incoming), (primaryCounterparty: 'sender-1', counterparty: 'sender-1'));
      });
    }
  });
}
