/// Wallet lifecycle, ordering, pagination, round-trip and data-retention
/// contract shared by the three [ReadModelStorage] backends (audit
/// 2026-09-14 S-15, S-16, S-19, S-20).
///
/// [defineWalletLifecycleContract] registers the same tests for every
/// backend; each backend's test file supplies a fresh storage per test (the
/// Postgres database is shared, so every id is made unique per run).
///
/// The rules:
/// * A wallet exists when its metadata row exists ([ReadModelStorage.storeWallet]).
///   UTXO or transaction rows alone do not create a wallet.
/// * [ReadModelStorage.deleteWallet] is a hard delete of every row of the
///   wallet (metadata, addresses, UTXOs, transactions, transaction-address
///   links, invoices, payment channels). Storing the wallet again creates it
///   afresh.
/// * Queries for an unknown wallet return empty results, never throw.
/// * List queries return newest first (`createdAt` descending).
/// * History is never lost by an update: a later store of a transaction
///   without raw hex or block height keeps the stored ones, and spent UTXO
///   rows stay (an SPV wallet cannot re-fetch them, see
///   `spv-understanding.md`).
library;

import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:test/test.dart';

import 'package:libspiffy/src/actors/invoice_messages.dart' show InvoiceStatus;
import 'package:libspiffy/src/models/address_metadata.dart';
import 'package:libspiffy/src/models/bitcoin_transaction.dart';
import 'package:libspiffy/src/models/bitcoin_utxo.dart';
import 'package:libspiffy/src/models/invoice_read_model.dart';
import 'package:libspiffy/src/models/payment_channel.dart';
import 'package:libspiffy/src/models/transaction_address_link.dart';
import 'package:libspiffy/src/storage/read_model_storage.dart';

import 'read_model_keying_contract.dart' show contractHex64;

final _t0 = DateTime.utc(2026, 9, 14, 12);

DateTime _at(int seconds) => _t0.add(Duration(seconds: seconds));

BitcoinTransaction _tx(String txid, DateTime createdAt,
        {DateTime? updatedAt,
        TransactionStatus status = TransactionStatus.pending,
        String? walletId,
        String rawHex = '0100000000000000000000',
        int? blockHeight}) =>
    BitcoinTransaction(
      walletId: walletId,
      txid: txid,
      rawHex: rawHex,
      status: status,
      blockHeight: blockHeight,
      confirmations: 0,
      inputValue: BigInt.from(2000),
      outputValue: BigInt.from(1800),
      fee: BigInt.from(200),
      receivingAddresses: const ['mkHS9ne12qx9pS9VojpwU5xtRd4T7X7ZUt'],
      sendingAddresses: const [],
      netAmount: BigInt.from(1800),
      createdAt: createdAt,
      updatedAt: updatedAt ?? createdAt,
      lockTime: 0,
      version: 1,
    );

BitcoinUtxo _utxo(String txid, int vout,
        {int sats = 1000,
        UTXOStatus status = UTXOStatus.available,
        DateTime? createdAt,
        DateTime? updatedAt,
        Map<String, dynamic>? pluginMetadata,
        int? blockHeight,
        int? confirmations}) =>
    BitcoinUtxo(
      txid: txid,
      vout: vout,
      value: dartsv.Coin.ofSat(BigInt.from(sats)),
      scriptPubKey: '76a914000000000000000000000000000000000000000088ac',
      address: 'mkHS9ne12qx9pS9VojpwU5xtRd4T7X7ZUt',
      status: status,
      blockHeight: blockHeight,
      confirmations: confirmations,
      createdAt: createdAt ?? _t0,
      updatedAt: updatedAt ?? createdAt ?? _t0,
      pluginMetadata: pluginMetadata,
    );

AddressMetadata _address(String address, int index, DateTime createdAt) =>
    AddressMetadata(
      address: address,
      scriptType: 'p2pkh',
      derivationPath: 'm/0/$index',
      derivationIndex: index,
      isChange: false,
      purpose: 'receive',
      usageCount: 0,
      balance: BigInt.zero,
      createdAt: createdAt,
      isWatched: true,
    );

/// Same instant, whatever the time zone the backend hands back.
Matcher _sameMoment(DateTime expected) => isA<DateTime>().having(
    (d) => d.toUtc().millisecondsSinceEpoch,
    'utc ms',
    expected.toUtc().millisecondsSinceEpoch);

/// Lets `DateTime.now()` advance between two stores whose order a backend
/// records with its own clock.
Future<void> _tick() => Future<void>.delayed(const Duration(milliseconds: 5));

/// Registers the contract tests. [storage] returns the storage for the
/// running test; [unique] a string unique per test run.
void defineWalletLifecycleContract(
  ReadModelStorage Function() storage, {
  required String Function() unique,
}) {
  group('wallet lifecycle contract', () {
    // ------------------------------------------------------------------
    // S-15: existence, delete, re-create, unknown wallets
    // ------------------------------------------------------------------

    test('S-15: UTXO and transaction rows alone do not make a wallet exist',
        () async {
      final s = storage();
      final u = unique();
      final wallet = 'lc-rows-$u';
      await s.upsertUTXO(wallet, _utxo(contractHex64('rows-$u'), 0));
      await s.storeTransaction(wallet, _tx(contractHex64('rows-tx-$u'), _t0));

      expect(await s.walletExists(wallet), isFalse,
          reason: 'existence is the metadata row, not derived from UTXOs');
      expect(await s.listWallets(), isNot(contains(wallet)));
      expect(await s.getWalletIds(), isNot(contains(wallet)));

      await s.storeWallet(wallet, 'Rows');
      expect(await s.walletExists(wallet), isTrue);
      expect(await s.listWallets(), contains(wallet));
      expect(await s.getWalletIds(), contains(wallet),
          reason: 'getWalletIds lists the same wallets as listWallets');
    });

    test('S-15: a deleted wallet is gone and storing it again re-creates it',
        () async {
      final s = storage();
      final u = unique();
      final wallet = 'lc-recreate-$u';

      await s.storeWallet(wallet, 'First', networkType: 'testnet');
      await s.deleteWallet(wallet);
      expect(await s.walletExists(wallet), isFalse);
      expect(await s.getWallet(wallet), isNull,
          reason: 'a deleted wallet has no metadata');
      expect(await s.listWallets(), isNot(contains(wallet)));
      expect(await s.getWalletIds(), isNot(contains(wallet)));

      await s.storeWallet(wallet, 'Second');
      expect(await s.walletExists(wallet), isTrue);
      expect(await s.listWallets(), contains(wallet),
          reason: 'a re-created wallet must be listed again');
      expect(await s.getWalletIds(), contains(wallet));
      final meta = await s.getWallet(wallet);
      expect(meta?['name'], 'Second');
      expect(meta?['network'], 'mainnet',
          reason: 'the re-created wallet starts afresh (hard delete)');
    });

    test('S-15: deleteWallet removes every row of the wallet and no other',
        () async {
      final s = storage();
      final u = unique();
      final wallet = 'lc-del-$u';
      final other = 'lc-del-other-$u';
      final txid = contractHex64('del-tx-$u');
      final address = 'addr-del-$u';

      for (final w in [wallet, other]) {
        await s.storeWallet(w, w);
        await s.upsertAddress(w, _address(address, 0, _t0));
        await s.upsertUTXO(w, _utxo(txid, 0));
        await s.storeTransaction(w, _tx(txid, _t0));
        await s.storeTransactionAddresses(w, txid, [
          TransactionAddressLink(
              address: address, direction: 'output', amount: BigInt.from(1000), vout: 0),
        ]);
        await s.storeInvoice(InvoiceReadModel(
          invoiceId: 'inv-$w',
          walletId: w,
          addresses: [address],
          amount: BigInt.from(1000),
          status: InvoiceStatus.pending,
          createdAt: _t0,
          lastUpdated: _t0,
          metadata: const {},
        ));
        await s.storePaymentChannel(PaymentChannel(
          channelId: 'chan-$w',
          walletId: w,
          role: PaymentChannelRole.client,
          clientPeerId: 'c',
          serverPeerId: 's',
          clientPubKeyHex: '02${'ab' * 32}',
          serverPubKeyHex: '03${'cd' * 32}',
          fundingAmountSats: BigInt.from(5000),
          lockTimeUnix: 1800000000,
        ));
      }

      await s.deleteWallet(wallet);

      expect(await s.getAddressCount(wallet), 0);
      expect(await s.getUTXOs(wallet, includeSpent: true), isEmpty);
      expect(await s.getTransactionHistory(wallet), isEmpty);
      expect(await s.getTransaction(txid, walletId: wallet), isNull);
      expect((await s.getTransactionAddresses(wallet, txid)).allAddresses, isEmpty,
          reason: 'transaction-address links must be deleted with the wallet');
      expect(await s.getTransactionsByAddress(wallet, address), isEmpty);
      expect(await s.getInvoicesByWallet(wallet), isEmpty);
      expect(await s.getInvoice('inv-$wallet'), isNull);
      expect(await s.getPaymentChannelsForWallet(wallet), isEmpty,
          reason: 'payment channels must be deleted with the wallet');
      expect(await s.getPaymentChannel('chan-$wallet'), isNull);

      // The other wallet keeps everything.
      expect(await s.walletExists(other), isTrue);
      expect(await s.getAddressCount(other), 1);
      expect(await s.getUTXOs(other), hasLength(1));
      expect(await s.getTransactionHistory(other), hasLength(1));
      expect((await s.getTransactionAddresses(other, txid)).outputs, hasLength(1));
      expect(await s.getInvoicesByWallet(other), hasLength(1));
      expect(await s.getPaymentChannelsForWallet(other), hasLength(1));
    });

    test('S-15: queries for an unknown wallet return empty results', () async {
      final s = storage();
      final wallet = 'lc-unknown-${unique()}';

      expect(await s.walletExists(wallet), isFalse);
      expect(await s.getWallet(wallet), isNull);
      expect(await s.getUTXOs(wallet), isEmpty);
      expect(await s.getUTXOs(wallet, includeSpent: true), isEmpty);
      expect(await s.getAvailableUTXOs(wallet), isEmpty);
      expect(await s.getPaymentUTXOs(wallet), isEmpty);
      expect(await s.getUTXOsByPlugin(wallet, 'tstoken'), isEmpty);
      expect(await s.getBalance(wallet), BigInt.zero);
      expect(await s.getTransactionHistory(wallet), isEmpty);
      expect(await s.getTransactionHistory(wallet, limit: 10, offset: 5), isEmpty);
      expect(await s.getTransactionsByStatus(TransactionStatus.pending, walletId: wallet),
          isEmpty);
      expect(await s.getWalletAddresses(wallet), isEmpty);
      expect(await s.getAddressesWithMetadata(wallet), isEmpty);
      expect(await s.getAddressCount(wallet), 0);
      expect(await s.getInvoicesByWallet(wallet), isEmpty);
      expect(await s.getPaymentChannelsForWallet(wallet), isEmpty);
      await s.deleteWallet(wallet); // no-op, no throw
    });

    // ------------------------------------------------------------------
    // S-19: newest first on every backend
    // ------------------------------------------------------------------

    test('S-19: listWallets returns the newest wallet first', () async {
      final s = storage();
      final u = unique();
      final ids = ['lc-order-a-$u', 'lc-order-b-$u', 'lc-order-c-$u'];
      for (final id in ids) {
        await s.storeWallet(id, id);
        await _tick();
      }
      final listed = (await s.listWallets()).where(ids.contains).toList();
      expect(listed, ids.reversed.toList());
      final viaIds = (await s.getWalletIds()).where(ids.contains).toList();
      expect(viaIds, ids.reversed.toList());
    });

    test('S-19: transaction history is newest first whatever the store order',
        () async {
      final s = storage();
      final u = unique();
      final wallet = 'lc-hist-$u';
      await s.storeWallet(wallet, 'hist');
      final mid = contractHex64('hist-mid-$u');
      final newest = contractHex64('hist-new-$u');
      final oldest = contractHex64('hist-old-$u');
      await s.storeTransaction(wallet, _tx(mid, _at(20)));
      await s.storeTransaction(wallet, _tx(newest, _at(30)));
      await s.storeTransaction(wallet, _tx(oldest, _at(10)));

      expect((await s.getTransactionHistory(wallet)).map((t) => t.txid),
          [newest, mid, oldest]);
      expect(
          (await s.getTransactionsByStatus(TransactionStatus.pending, walletId: wallet))
              .map((t) => t.txid),
          [newest, mid, oldest]);
    });

    test('S-19: UTXO lists are newest first', () async {
      final s = storage();
      final u = unique();
      final wallet = 'lc-utxo-order-$u';
      await s.storeWallet(wallet, 'utxo order');
      final txid = contractHex64('utxo-order-$u');
      const plugin = {'pluginId': 'tstoken', 'scriptType': 'pp1_nft'};
      await s.upsertUTXO(wallet, _utxo(txid, 1, createdAt: _at(20), pluginMetadata: plugin));
      await s.upsertUTXO(wallet, _utxo(txid, 2, createdAt: _at(30), pluginMetadata: plugin));
      await s.upsertUTXO(wallet, _utxo(txid, 0, createdAt: _at(10), pluginMetadata: plugin));

      expect((await s.getUTXOs(wallet)).map((x) => x.vout), [2, 1, 0]);
      expect((await s.getUTXOsByPlugin(wallet, 'tstoken')).map((x) => x.vout), [2, 1, 0]);
    });

    test('S-19: addresses with metadata are newest first (by the stored createdAt)',
        () async {
      final s = storage();
      final u = unique();
      final wallet = 'lc-addr-order-$u';
      final a0 = 'addr-o0-$u';
      final a1 = 'addr-o1-$u';
      final a2 = 'addr-o2-$u';
      // Stored out of both index and time order.
      await s.upsertAddress(wallet, _address(a1, 1, _at(1)));
      await s.upsertAddress(wallet, _address(a2, 2, _at(2)));
      await s.upsertAddress(wallet, _address(a0, 0, _at(0)));

      expect((await s.getAddressesWithMetadata(wallet)).map((a) => a.address),
          [a2, a1, a0]);
      expect(
          (await s.getAddressesWithMetadata(wallet, limit: 1, offset: 1))
              .map((a) => a.address),
          [a1]);
      expect((await s.getAddressMetadata(wallet, a1))!.createdAt, _sameMoment(_at(1)));
    });

    test('S-19: transactions by address are newest first', () async {
      final s = storage();
      final u = unique();
      final wallet = 'lc-txaddr-order-$u';
      final address = 'addr-txaddr-$u';
      // txids in ascending lexical order, stored oldest first.
      final txids = ['aa', 'bb', 'cc']
          .map((p) => '$p${contractHex64('txaddr-$p-$u').substring(2)}')
          .toList();
      for (final txid in txids) {
        await s.storeTransactionAddresses(wallet, txid, [
          TransactionAddressLink(
              address: address, direction: 'output', amount: BigInt.from(1), vout: 0),
        ]);
        await _tick();
      }
      expect(await s.getTransactionsByAddress(wallet, address), txids.reversed.toList());
      expect(await s.getTransactionsByAddress(wallet, address, limit: 1, offset: 1),
          [txids[1]]);
    });

    // ------------------------------------------------------------------
    // S-16: pagination at the boundaries
    // ------------------------------------------------------------------

    test('S-16: transaction history pagination is exact at the boundaries',
        () async {
      final s = storage();
      final u = unique();
      final wallet = 'lc-page-$u';
      await s.storeWallet(wallet, 'page');
      // Five transactions stored in scrambled time order.
      final bySecond = <int, String>{};
      for (final second in [3, 1, 5, 2, 4]) {
        final txid = contractHex64('page-$second-$u');
        bySecond[second] = txid;
        await s.storeTransaction(wallet, _tx(txid, _at(second)));
      }
      final newestFirst = [5, 4, 3, 2, 1].map((i) => bySecond[i]!).toList();

      Future<List<String>> page({int? limit, int? offset}) async =>
          (await s.getTransactionHistory(wallet, limit: limit, offset: offset))
              .map((t) => t.txid)
              .toList();

      expect(await page(), newestFirst);
      expect(await page(limit: 2), newestFirst.sublist(0, 2));
      expect(await page(limit: 2, offset: 2), newestFirst.sublist(2, 4));
      expect(await page(limit: 2, offset: 4), newestFirst.sublist(4));
      expect(await page(limit: 2, offset: 5), isEmpty);
      expect(await page(offset: 3), newestFirst.sublist(3));
      expect(await page(limit: 10), newestFirst);
      expect(await page(limit: 5, offset: 0), newestFirst);
    });

    // ------------------------------------------------------------------
    // S-20: round trips
    // ------------------------------------------------------------------

    test('S-20: a UTXO reads back with its createdAt, updatedAt and fields',
        () async {
      final s = storage();
      final u = unique();
      final wallet = 'lc-utxo-rt-$u';
      await s.storeWallet(wallet, 'rt');
      final txid = contractHex64('utxo-rt-$u');
      await s.upsertUTXO(
          wallet,
          _utxo(txid, 3,
              sats: 4321,
              status: UTXOStatus.reserved,
              createdAt: _at(10),
              updatedAt: _at(70),
              blockHeight: 900,
              confirmations: 2,
              pluginMetadata: {'scriptType': 'p2pkh'}));

      final got = (await s.getUTXOs(wallet)).single;
      expect(got.createdAt, _sameMoment(_at(10)));
      expect(got.updatedAt, _sameMoment(_at(70)),
          reason: 'updatedAt must not be replaced by createdAt');
      expect(got.status, UTXOStatus.reserved);
      expect(got.satoshis, BigInt.from(4321));
      expect(got.blockHeight, 900);
      expect(got.confirmations, 2);
      expect(got.pluginMetadata, {'scriptType': 'p2pkh'});

      // Spent later: the update carries the spend time.
      await s.upsertUTXO(wallet, got.copyWith(status: UTXOStatus.spent, updatedAt: _at(90)));
      final spent = (await s.getUTXOs(wallet, includeSpent: true)).single;
      expect(spent.status, UTXOStatus.spent);
      expect(spent.createdAt, _sameMoment(_at(10)));
      expect(spent.updatedAt, _sameMoment(_at(90)));
      expect(await s.getUTXOs(wallet), isEmpty);
    });

    test(
        'viy: a reserved UTXO reads back with its reservation, status before '
        'reservation and derivation index; a release clears the reservation',
        () async {
      final s = storage();
      final u = unique();
      final wallet = 'lc-utxo-resv-$u';
      await s.storeWallet(wallet, 'reservation');
      final txid = contractHex64('utxo-resv-$u');
      final base = BitcoinUtxo(
        txid: txid,
        vout: 1,
        value: dartsv.Coin.ofSat(BigInt.from(100000)),
        scriptPubKey: '76a914000000000000000000000000000000000000000088ac',
        address: 'mkHS9ne12qx9pS9VojpwU5xtRd4T7X7ZUt',
        status: UTXOStatus.pending,
        createdAt: _at(10),
        updatedAt: _at(10),
        derivationIndex: 7,
      );
      await s.upsertUTXO(wallet, base);
      await s.upsertUTXO(
          wallet,
          base.reserve('channel:c1',
              duration: const Duration(days: 30),
              priority: 1000,
              reason: 'Payment channel c1 funding',
              timestamp: _at(20)));

      Future<BitcoinUtxo> read() async =>
          (await s.getUTXOs(wallet, includeSpent: true)).single;

      final reserved = await read();
      expect(reserved.status, UTXOStatus.reserved);
      expect(reserved.reservedByTxId, 'channel:c1');
      expect(reserved.reservationReason, 'Payment channel c1 funding');
      expect(reserved.reservationPriority, 1000);
      expect(reserved.reservationExpiresAt, _sameMoment(_at(20).add(const Duration(days: 30))));
      expect(reserved.statusBeforeReservation, UTXOStatus.pending,
          reason: 'releasing must restore pending, not make the coin spendable');
      expect(reserved.derivationIndex, 7);

      // Released: the reservation fields are cleared, the index stays.
      await s.upsertUTXO(wallet, reserved.releaseReservation(timestamp: _at(30)));
      final released = await read();
      expect(released.status, UTXOStatus.pending);
      expect(released.reservedByTxId, isNull);
      expect(released.reservationReason, isNull);
      expect(released.reservationPriority, isNull);
      expect(released.reservationExpiresAt, isNull);
      expect(released.statusBeforeReservation, isNull);
      expect(released.derivationIndex, 7);

      // An update that lacks the derivation index keeps the stored one.
      await s.upsertUTXO(
          wallet,
          BitcoinUtxo(
            txid: txid,
            vout: 1,
            value: released.value,
            scriptPubKey: released.scriptPubKey,
            address: released.address,
            status: UTXOStatus.available,
            createdAt: _at(10),
            updatedAt: _at(40),
            confirmations: 1,
            blockHeight: 800,
          ));
      expect((await read()).derivationIndex, 7);
    });

    test('viy: a spent UTXO reads back with the transaction that spent it, never overwritten',
        () async {
      final s = storage();
      final u = unique();
      final wallet = 'lc-utxo-spentin-$u';
      await s.storeWallet(wallet, 'spent in');
      final txid = contractHex64('utxo-spentin-$u');
      final spender = contractHex64('utxo-spender-$u');
      final utxo = _utxo(txid, 0, createdAt: _at(1));
      await s.upsertUTXO(wallet, utxo);
      await s.upsertUTXO(wallet, utxo.markSpent(timestamp: _at(2), spentInTxId: spender));

      final spent = (await s.getUTXOs(wallet, includeSpent: true)).single;
      expect(spent.status, UTXOStatus.spent);
      expect(spent.spentInTxId, spender);

      // A later update of the row without it (or with another one) keeps the
      // spend history.
      await s.upsertUTXO(wallet,
          _utxo(txid, 0, status: UTXOStatus.spent, createdAt: _at(1), updatedAt: _at(3)));
      await s.upsertUTXO(wallet,
          utxo.markSpent(timestamp: _at(4), spentInTxId: contractHex64('other-$u')));
      expect((await s.getUTXOs(wallet, includeSpent: true)).single.spentInTxId, spender);
    });

    test('S-20: a transaction reads back with its walletId, createdAt and updatedAt',
        () async {
      final s = storage();
      final u = unique();
      final wallet = 'lc-tx-rt-$u';
      await s.storeWallet(wallet, 'rt');
      final txid = contractHex64('tx-rt-$u');
      // The caller's model carries no wallet id: the storage key supplies it.
      await s.storeTransaction(wallet, _tx(txid, _at(10), updatedAt: _at(40)));

      void check(BitcoinTransaction? tx, String via) {
        expect(tx, isNotNull, reason: via);
        expect(tx!.walletId, wallet, reason: '$via: walletId');
        expect(tx.createdAt, _sameMoment(_at(10)), reason: '$via: createdAt');
        expect(tx.updatedAt, _sameMoment(_at(40)), reason: '$via: updatedAt');
      }

      check((await s.getTransactionHistory(wallet)).single, 'history');
      check(await s.getTransaction(txid, walletId: wallet), 'getTransaction(walletId)');
      check(await s.getTransaction(txid), 'getTransaction');
      check((await s.getTransactionsBatch([txid]))[txid], 'batch');
      check(
          (await s.getTransactionsByStatus(TransactionStatus.pending, walletId: wallet))
              .single,
          'byStatus');

      // An update moves updatedAt, not createdAt.
      await s.storeTransaction(wallet,
          _tx(txid, _at(10), updatedAt: _at(80), status: TransactionStatus.confirmed));
      final updated = await s.getTransaction(txid, walletId: wallet);
      expect(updated!.status, TransactionStatus.confirmed);
      expect(updated.createdAt, _sameMoment(_at(10)));
      expect(updated.updatedAt, _sameMoment(_at(80)));
    });

    // ------------------------------------------------------------------
    // Data retention: an update never erases history
    // ------------------------------------------------------------------

    test('retention: an update without raw hex or block height keeps the stored ones',
        () async {
      final s = storage();
      final u = unique();
      final wallet = 'lc-keep-$u';
      await s.storeWallet(wallet, 'keep');
      final txid = contractHex64('keep-$u');
      const rawHex = '0200000001deadbeef';
      await s.storeTransaction(wallet,
          _tx(txid, _at(10), rawHex: rawHex, blockHeight: 800123,
              status: TransactionStatus.confirmed));

      // A later record of the same transaction that lacks the raw bytes and
      // the height (e.g. a status-only update built without them).
      await s.storeTransaction(wallet,
          _tx(txid, _at(10), updatedAt: _at(50), rawHex: '', blockHeight: null,
              status: TransactionStatus.confirmed));

      final stored = await s.getTransaction(txid, walletId: wallet);
      expect(stored!.rawHex, rawHex,
          reason: 'the raw transaction cannot be re-fetched; it must survive the update');
      expect(stored.blockHeight, 800123);
      expect(stored.updatedAt, _sameMoment(_at(50)));
    });

    test('a confirmation taken back (reorg) clears the stored block height',
        () async {
      // The retention rule above keeps a height a confirmed update lacks; it
      // must not stop a reorg from taking the confirmation back (audit 3b0).
      final s = storage();
      final u = unique();
      final wallet = 'lc-revert-$u';
      await s.storeWallet(wallet, 'revert');
      final txid = contractHex64('revert-$u');
      const rawHex = '0200000001feedface';
      await s.storeTransaction(wallet,
          _tx(txid, _at(10), rawHex: rawHex, blockHeight: 800200,
              status: TransactionStatus.confirmed));
      await s.upsertUTXO(wallet,
          _utxo(txid, 0, createdAt: _at(10), blockHeight: 800200, confirmations: 3));

      // The revert path (7dj): an ordinary store keeps a confirmation.
      await s.storeRevertedTransaction(wallet,
          _tx(txid, _at(10), updatedAt: _at(60), rawHex: '', blockHeight: null,
              status: TransactionStatus.pending));
      await s.upsertUTXO(wallet,
          _utxo(txid, 0, status: UTXOStatus.pending, createdAt: _at(10),
              updatedAt: _at(60), confirmations: 0));

      final stored = await s.getTransaction(txid, walletId: wallet);
      expect(stored!.blockHeight, isNull, reason: 'a pending transaction has no block');
      expect(stored.rawHex, rawHex, reason: 'the raw transaction is still retained');
      final utxo = (await s.getUTXOs(wallet, includeSpent: true)).single;
      expect(utxo.blockHeight, isNull, reason: 'a zero-confirmation UTXO has no block');
    });

    test('retention: a spent UTXO row stays after later updates', () async {
      final s = storage();
      final u = unique();
      final wallet = 'lc-keep-utxo-$u';
      await s.storeWallet(wallet, 'keep utxo');
      final txid = contractHex64('keep-utxo-$u');
      await s.upsertUTXO(wallet, _utxo(txid, 0, createdAt: _at(1)));
      await s.upsertUTXO(wallet,
          _utxo(txid, 0, status: UTXOStatus.spent, createdAt: _at(1), updatedAt: _at(2)));
      // A replayed confirmation update of the spent row.
      await s.upsertUTXO(wallet,
          _utxo(txid, 0, status: UTXOStatus.spent, createdAt: _at(1), updatedAt: _at(3),
              blockHeight: 900, confirmations: 3));

      final rows = await s.getUTXOs(wallet, includeSpent: true);
      expect(rows.map((r) => '${r.vout}:${r.status.name}'), ['0:spent']);
      expect(rows.single.createdAt, _sameMoment(_at(1)));
      expect(await s.getUTXOs(wallet), isEmpty);
    });
  });
}
