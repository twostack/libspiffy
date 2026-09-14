/// Ancestor transaction contract shared by the three [ReadModelStorage]
/// backends (audit bead libspiffy-zsh).
///
/// A BEEF paying us for an unmined transaction carries its ancestors back to
/// mined ones. They are needed to spend the received outputs before the
/// payment is mined and cannot be fetched again, so they are kept: keyed by
/// txid, apart from every wallet's transaction rows, and never deleted.
library;

import 'package:test/test.dart';

import 'package:libspiffy/src/models/bitcoin_transaction.dart';
import 'package:libspiffy/src/storage/read_model_storage.dart';

import 'read_model_keying_contract.dart' show contractHex64;

BitcoinTransaction _walletTx(String txid) => BitcoinTransaction(
      txid: txid,
      rawHex: '0100000000000000000000',
      status: TransactionStatus.pending,
      confirmations: 0,
      inputValue: BigInt.from(2000),
      outputValue: BigInt.from(1800),
      fee: BigInt.from(200),
      receivingAddresses: const ['mkHS9ne12qx9pS9VojpwU5xtRd4T7X7ZUt'],
      sendingAddresses: const [],
      netAmount: BigInt.from(1800),
      createdAt: DateTime.utc(2026, 9, 14, 12),
      updatedAt: DateTime.utc(2026, 9, 14, 12),
      lockTime: 0,
      version: 1,
    );

/// Registers the contract tests. [storage] returns the storage for the
/// running test; [unique] a string unique per test run (the Postgres database
/// outlives a run).
void defineAncestorTransactionContract(
  ReadModelStorage Function() storage, {
  required String Function() unique,
}) {
  group('ancestor transaction contract (zsh)', () {
    test('zsh: stored ancestors are read back by txid; unknown txids are absent', () async {
      final s = storage();
      final u = unique();
      final a = contractHex64('anc-a-$u');
      final b = contractHex64('anc-b-$u');
      final unknown = contractHex64('anc-unknown-$u');

      await s.storeAncestorTransaction(a, '01000000aa');
      await s.storeAncestorTransaction(b, '01000000bb');

      expect(await s.getAncestorTransactionsBatch([a, b, unknown]), {a: '01000000aa', b: '01000000bb'});
      expect(await s.getAncestorTransactionsBatch([unknown]), isEmpty);
      expect(await s.getAncestorTransactionsBatch(const []), isEmpty);
    });

    test('zsh: storing a txid again changes nothing', () async {
      final s = storage();
      final a = contractHex64('anc-again-${unique()}');

      await s.storeAncestorTransaction(a, '01000000aa');
      await s.storeAncestorTransaction(a, '01000000aa');
      await s.storeAncestorTransaction(a, '02000000ff');

      expect(await s.getAncestorTransactionsBatch([a]), {a: '01000000aa'});
    });

    test('zsh: an ancestor is no wallet transaction and survives a wallet deletion', () async {
      final s = storage();
      final u = unique();
      final wallet = 'anc-wallet-$u';
      final ancestor = contractHex64('anc-kept-$u');
      final paid = contractHex64('anc-paid-$u');

      await s.storeWallet(wallet, 'W');
      await s.storeTransaction(wallet, _walletTx(paid));
      await s.storeAncestorTransaction(ancestor, '01000000cc');

      expect(await s.getTransaction(ancestor), isNull);
      expect(await s.getTransaction(ancestor, walletId: wallet), isNull);
      expect(await s.getTransactionsBatch([ancestor]), isEmpty);
      expect((await s.getTransactionHistory(wallet)).map((t) => t.txid), [paid]);
      final pending = await s.getTransactionsByStatus(TransactionStatus.pending);
      expect(pending.map((t) => t.txid), isNot(contains(ancestor)));
      expect(await s.getBalance(wallet), BigInt.zero);

      await s.deleteWallet(wallet);
      expect(await s.getAncestorTransactionsBatch([ancestor]), {ancestor: '01000000cc'});
    });

    test('zsh: a txid that is both an ancestor and a wallet transaction keeps both rows apart', () async {
      final s = storage();
      final u = unique();
      final wallet = 'anc-both-$u';
      final txid = contractHex64('anc-both-tx-$u');

      await s.storeWallet(wallet, 'W');
      await s.storeAncestorTransaction(txid, '0100000000000000000000');
      await s.storeTransaction(wallet, _walletTx(txid));

      expect((await s.getTransaction(txid, walletId: wallet))?.walletId, wallet);
      expect(await s.getAncestorTransactionsBatch([txid]), {txid: '0100000000000000000000'});
      await s.deleteWallet(wallet);
      expect(await s.getTransaction(txid), isNull);
      expect(await s.getAncestorTransactionsBatch([txid]), {txid: '0100000000000000000000'});
    });
  });
}
