/// Audit 2026-09-14 S-16 (bead libspiffy-ei4): Isar queries must read only
/// the rows they need, through an index, instead of scanning whole
/// collections, every row of a wallet, or loading rows to filter, sort and
/// page them in Dart.
///
/// Isar 3 has no query explain and results are identical either way, so
/// these tests observe the queries themselves: [IsarWalletStorage.onQuery]
/// hands over every query before it runs, and the test replays its parts:
///
/// * rows in range: the rows its where clauses cover (with no where clause,
///   the whole collection). Isar reads every one of them, so a range holding
///   another wallet's rows, spent UTXOs or unrelated rows is a scan.
/// * rows returned: what the complete query (filter, sort, offset, limit)
///   hands to Dart to deserialize.
library;

// buildQuery replays the recorded parts of a query.
// ignore_for_file: experimental_member_use

import 'dart:io';

import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:isar/isar.dart';
import 'package:test/test.dart';

import 'package:libspiffy/src/actors/invoice_messages.dart' show InvoiceStatus;
import 'package:libspiffy/src/models/address_metadata.dart';
import 'package:libspiffy/src/models/bitcoin_transaction.dart';
import 'package:libspiffy/src/models/bitcoin_utxo.dart';
import 'package:libspiffy/src/models/deferred_payment.dart';
import 'package:libspiffy/src/models/transaction_address_link.dart';
import 'package:libspiffy/src/storage/isar_wallet_storage.dart';
import 'package:libspiffy/src/storage/libspiffy_schemas.dart';
import 'package:libspiffy/src/storage/read_model_storage.dart' show MerkleProof, MerkleProofStatus;

import '../integration/isar_test_helper.dart';
import 'channel_read_model_contract.dart' show fullFieldChannel;
import 'deferred_payment_contract.dart' show contractDeferredPayment, contractTxid;
import 'invoice_read_model_contract.dart' show contractInvoice;

/// One query a storage operation ran.
class _Trace {
  final String operation;
  final QueryBuilderInternal<dynamic> query;
  _Trace(this.operation, this.query);

  IsarCollection<dynamic> get _collection => query.collection!;

  bool get isWalletScoped => _collection.schema.properties.containsKey('walletId');

  /// Rows the where clauses cover, optionally only those matching [filter].
  Future<int> rowsInRange({FilterOperation? filter}) => _collection
      .buildQuery<dynamic>(
        whereClauses: query.whereClauses,
        whereDistinct: query.whereDistinct,
        whereSort: query.whereSort,
        filter: filter,
      )
      .count();

  /// Rows the complete query returns to Dart.
  Future<int> rowsReturned() async => (await _collection
          .buildQuery<dynamic>(
            whereClauses: query.whereClauses,
            whereDistinct: query.whereDistinct,
            whereSort: query.whereSort,
            filter: query.filter.filters.isEmpty ? null : query.filter,
            sortBy: query.sortByProperties,
            distinctBy: query.distinctByProperties,
            offset: query.offset,
            limit: query.limit,
          )
          .findAll())
      .length;

  @override
  String toString() => '$operation on ${_collection.name}';
}

DateTime _at(int minute) => DateTime.utc(2026, 9, 1, 12).add(Duration(minutes: minute));

String _txid(String tag) => contractTxid(tag);

BitcoinTransaction _tx(String txid, {int minute = 0, TransactionStatus status = TransactionStatus.confirmed}) =>
    BitcoinTransaction(
      txid: txid,
      rawHex: '0100000000000000000000',
      status: status,
      blockHeight: status == TransactionStatus.confirmed ? 800000 : null,
      confirmations: status == TransactionStatus.confirmed ? 1 : 0,
      inputValue: BigInt.from(2000),
      outputValue: BigInt.from(1800),
      fee: BigInt.from(200),
      receivingAddresses: const [],
      sendingAddresses: const [],
      netAmount: BigInt.from(1800),
      createdAt: _at(minute),
      updatedAt: _at(minute),
      lockTime: 0,
      version: 1,
    );

BitcoinUtxo _utxo(String txid, int vout,
        {UTXOStatus status = UTXOStatus.available, Map<String, dynamic>? pluginMetadata, int minute = 0}) =>
    BitcoinUtxo(
      txid: txid,
      vout: vout,
      value: dartsv.Coin.ofSat(BigInt.from(1000 + vout)),
      scriptPubKey: '76a914000000000000000000000000000000000000000088ac',
      address: 'mkHS9ne12qx9pS9VojpwU5xtRd4T7X7ZUt',
      status: status,
      createdAt: _at(minute),
      updatedAt: _at(minute),
      pluginMetadata: pluginMetadata,
    );

AddressMetadata _address(String address, {int index = 0, String purpose = 'receive'}) => AddressMetadata(
      address: address,
      scriptType: 'p2pkh',
      derivationPath: purpose == 'watch' ? null : 'm/0/0/$index',
      derivationIndex: purpose == 'watch' ? null : index,
      isChange: false,
      purpose: purpose,
      usageCount: index.isEven ? 1 : 0,
      balance: BigInt.zero,
      createdAt: _at(index),
      isWatched: purpose == 'watch',
    );

void main() {
  late Directory dir;
  late Isar isar;
  late IsarWalletStorage storage;
  final traces = <_Trace>[];

  /// The queries [body] ran.
  Future<List<_Trace>> queriesOf(Future<void> Function() body) async {
    traces.clear();
    await body();
    return List.of(traces);
  }

  setUpAll(() async {
    await ensureIsarInitialized();
  });

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('isar_query_access_');
    isar = await Isar.open(
      LibSpiffySchemas.allSchemas,
      directory: dir.path,
      name: 'query_access_${DateTime.now().microsecondsSinceEpoch}',
    );
    storage = IsarWalletStorage(isar)..onQuery = (operation, query) => traces.add(_Trace(operation, query));
  });

  tearDown(() async {
    await isar.close(deleteFromDisk: true);
    await dir.delete(recursive: true);
  });

  test('S-16: no wallet-scoped query reads a row of another wallet', () async {
    const target = 'target';
    const noise = 'noise';
    final sharedAddresses = [for (var i = 0; i < 3; i++) 'addr-shared-$i'];
    final sharedTxids = [for (var i = 0; i < 3; i++) _txid('shared-$i')];

    // The target wallet: a few rows of every kind.
    await storage.storeWallet(target, 'Target');
    for (var i = 0; i < sharedAddresses.length; i++) {
      await storage.upsertAddress(target, _address(sharedAddresses[i], index: i));
    }
    await storage.upsertAddress(target, _address('addr-target-watch', purpose: 'watch'));
    for (var i = 0; i < sharedTxids.length; i++) {
      await storage.storeTransaction(target, _tx(sharedTxids[i], minute: i));
      await storage.upsertUTXO(target, _utxo(sharedTxids[i], 0, minute: i));
      await storage.storeTransactionAddresses(target, sharedTxids[i],
          [TransactionAddressLink(address: sharedAddresses[i], direction: 'output', amount: BigInt.one, vout: 0)]);
      await storage.storeDeferredPayment(
          contractDeferredPayment(walletId: target, txid: sharedTxids[i], minutesAfterBase: i));
    }
    await storage.storeInvoice(contractInvoice(invoiceId: 'inv-target', walletId: target));
    await storage.storePaymentChannel(fullFieldChannel(channelId: 'ch-target', walletId: target));

    // Another wallet holding the same addresses and transactions, and many
    // rows of its own.
    await storage.storeWallet(noise, 'Noise');
    for (var i = 0; i < 40; i++) {
      final address = i < sharedAddresses.length ? sharedAddresses[i] : 'addr-noise-$i';
      final txid = i < sharedTxids.length ? sharedTxids[i] : _txid('noise-$i');
      await storage.upsertAddress(noise, _address(address, index: i, purpose: i.isEven ? 'watch' : 'receive'));
      await storage.storeTransaction(noise, _tx(txid, minute: i));
      await storage.upsertUTXO(noise, _utxo(txid, 0, minute: i));
      await storage.storeTransactionAddresses(noise, txid,
          [TransactionAddressLink(address: address, direction: 'output', amount: BigInt.one, vout: 0)]);
      await storage.storeDeferredPayment(contractDeferredPayment(walletId: noise, txid: txid, minutesAfterBase: i));
      await storage.storeInvoice(contractInvoice(invoiceId: 'inv-noise-$i', walletId: noise));
      await storage.storePaymentChannel(fullFieldChannel(channelId: 'ch-noise-$i', walletId: noise));
    }

    final operations = <String, Future<void> Function()>{
      'getWallet': () => storage.getWallet(target),
      'walletExists': () => storage.walletExists(target),
      'getWalletAddresses': () => storage.getWalletAddresses(target),
      'isWalletAddress': () => storage.isWalletAddress(target, sharedAddresses[0]),
      'getAddressMetadata': () => storage.getAddressMetadata(target, sharedAddresses[0]),
      'checkAddresses': () => storage.checkAddresses(target, [...sharedAddresses, 'addr-unknown']),
      'getAddressesWithMetadata': () =>
          storage.getAddressesWithMetadata(target, includeUnused: false, isChange: false, limit: 2, offset: 0),
      'getAddressRange': () => storage.getAddressRange(target, startIndex: 0, count: 2),
      'getAddressesByPurpose': () => storage.getAddressesByPurpose(target, 'watch'),
      'getAddressCount': () => storage.getAddressCount(target),
      'upsertAddress': () => storage.upsertAddress(target, _address(sharedAddresses[1], index: 1)),
      'updateAddressUsage': () => storage.updateAddressUsage(target, sharedAddresses[2], usedAt: _at(99)),
      'storeTransactionAddresses': () => storage.storeTransactionAddresses(target, sharedTxids[0],
          [TransactionAddressLink(address: sharedAddresses[0], direction: 'output', amount: BigInt.two, vout: 0)]),
      'getTransactionsByAddress': () => storage.getTransactionsByAddress(target, sharedAddresses[0]),
      'getTransactionAddresses': () => storage.getTransactionAddresses(target, sharedTxids[0]),
      'getAddressTransactionCount': () => storage.getAddressTransactionCount(target, sharedAddresses[0]),
      'getUTXOs': () => storage.getUTXOs(target),
      'getUTXOs(includeSpent)': () => storage.getUTXOs(target, includeSpent: true),
      'getUTXO': () => storage.getUTXO(target, sharedTxids[0], 0),
      'getUTXOsByTxid': () => storage.getUTXOsByTxid(target, sharedTxids[0]),
      'getUTXOsByTxid(includeSpent)': () =>
          storage.getUTXOsByTxid(target, sharedTxids[0], includeSpent: true),
      'countSpentUTXOs': () => storage.countSpentUTXOs(target),
      'getAvailableUTXOs': () => storage.getAvailableUTXOs(target),
      'getPaymentUTXOs': () => storage.getPaymentUTXOs(target),
      'getUTXOsByPlugin': () => storage.getUTXOsByPlugin(target, 'tstoken'),
      'getBalance': () => storage.getBalance(target),
      'upsertUTXO': () => storage.upsertUTXO(target, _utxo(sharedTxids[0], 0, status: UTXOStatus.spent)),
      'getTransactionHistory': () => storage.getTransactionHistory(target, limit: 2, offset: 1),
      'getTransaction': () => storage.getTransaction(sharedTxids[0], walletId: target),
      'getTransactionsByStatus': () => storage.getTransactionsByStatus(TransactionStatus.confirmed, walletId: target),
      'storeTransaction': () => storage.storeTransaction(target, _tx(sharedTxids[1], minute: 1)),
      'listDeferredPayments': () => storage.listDeferredPayments(target,
          query: const DeferredPaymentQuery(states: DeferredPaymentQuery.allStates, limit: 2)),
      'listInvoices(walletId)': () => storage.listInvoices(walletId: target),
      'listInvoices(walletId, status)': () => storage.listInvoices(walletId: target, status: InvoiceStatus.pending),
      'getPaymentChannelsForWallet': () => storage.getPaymentChannelsForWallet(target),
      'deleteUTXO': () => storage.deleteUTXO(target, sharedTxids[2], 0),
    };

    final offenders = <String>[];
    for (final entry in operations.entries) {
      final queries = await queriesOf(entry.value);
      expect(queries, isNotEmpty, reason: '${entry.key} ran no traced query');
      for (final query in queries.where((q) => q.isWalletScoped)) {
        final foreign = await query.rowsInRange(
            filter: const FilterCondition.equalTo(property: 'walletId', value: noise));
        if (foreign > 0) {
          offenders.add('${entry.key}: $query reads $foreign row(s) of another wallet '
              '(${await query.rowsInRange()} rows in range)');
        }
      }
    }
    expect(offenders, isEmpty);
  });

  group('S-16: a query reads only the rows it needs within the wallet', () {
    const walletId = 'w';

    setUp(() async {
      await storage.storeWallet(walletId, 'W');
    });

    test('unspent UTXO lists do not read spent rows (retained forever by design)', () async {
      for (var i = 0; i < 60; i++) {
        await storage.upsertUTXO(walletId, _utxo(_txid('spent-$i'), 0, status: UTXOStatus.spent, minute: i));
      }
      await storage.upsertUTXO(walletId, _utxo(_txid('open-0'), 0, minute: 100));
      await storage.upsertUTXO(walletId, _utxo(_txid('open-1'), 1, status: UTXOStatus.reserved, minute: 101));

      final queries = await queriesOf(() async {
        expect((await storage.getUTXOs(walletId)).map((u) => u.txid), [_txid('open-1'), _txid('open-0')]);
      });
      expect([for (final q in queries) await q.rowsInRange()], [2]);

      final available = await queriesOf(() async {
        expect((await storage.getAvailableUTXOs(walletId)).map((u) => u.txid), [_txid('open-0')]);
      });
      expect([for (final q in available) await q.rowsInRange()], [1]);
    });

    test('36jt: the outpoint, by-txid and spent-count lookups do not read the '
        'spend history', () async {
      // The shape the projection meets: a wallet that has been used, so its
      // spend history dwarfs what it still holds. It is never purged
      // (spv-understanding.md, Data Retention), so anything that reads it
      // per event costs more for the life of the wallet.
      const spent = 80;
      for (var i = 0; i < spent; i++) {
        await storage.upsertUTXO(walletId,
            _utxo(_txid('hist-$i'), 0, status: UTXOStatus.spent, minute: i));
      }
      final live = _txid('live');
      await storage.upsertUTXO(walletId, _utxo(live, 0, minute: 100));
      await storage.upsertUTXO(walletId, _utxo(live, 1, minute: 101));
      await storage.upsertUTXO(walletId,
          _utxo(live, 2, status: UTXOStatus.spent, minute: 102));
      await storage.upsertUTXO(walletId, _utxo(_txid('other'), 0, minute: 103));

      final point = await queriesOf(() async {
        expect((await storage.getUTXO(walletId, live, 1))?.vout, 1);
        expect((await storage.getUTXO(walletId, _txid('hist-3'), 0))?.status,
            UTXOStatus.spent);
        expect(await storage.getUTXO(walletId, live, 9), isNull);
      });
      expect([for (final q in point) await q.rowsInRange()],
          everyElement(lessThanOrEqualTo(1)),
          reason: 'getUTXO is the unique (utxoKey, walletId) index: one row, '
              'whatever the wallet has spent -- including when the answer is '
              'a spent row or no row at all');

      final byTxid = await queriesOf(() async {
        expect((await storage.getUTXOsByTxid(walletId, live)).map((u) => u.vout),
            [1, 0]);
      });
      expect([for (final q in byTxid) await q.rowsInRange()], [3],
          reason: 'the composite (walletId, txid) index: this transaction\'s '
              'three outputs, not the wallet\'s other rows');

      final counted = await queriesOf(() async {
        expect(await storage.countSpentUTXOs(walletId), spent + 1);
      });
      // What is pinned here is the index RANGE. The count runs `.count()`,
      // which walks index entries and deserializes nothing, but this harness
      // replays a query with findAll and so cannot tell a count from a read
      // -- the range is what it can prove. A range of exactly the spent rows
      // is the (walletId, status) index doing the selecting; the whole
      // wallet in range would be a filter over a scan.
      expect([for (final q in counted) await q.rowsInRange()], [spent + 1],
          reason: 'countSpentUTXOs selects through the (walletId, status) '
              'index');
      expect(
          await storage.getUTXOs(walletId, includeSpent: true), hasLength(spent + 4),
          reason: 'and the wallet has more rows than that, so the range is '
              'not simply everything it holds');
    });

    test('address lookups by (address, wallet) read one row', () async {
      for (var i = 0; i < 50; i++) {
        await storage.upsertAddress(walletId, _address('addr-$i', index: i));
      }
      final operations = <String, Future<void> Function()>{
        'upsertAddress (update)': () => storage.upsertAddress(walletId, _address('addr-7', index: 7)),
        'upsertAddress (insert)': () => storage.upsertAddress(walletId, _address('addr-new', index: 99)),
        'updateAddressUsage': () => storage.updateAddressUsage(walletId, 'addr-8', usedAt: _at(1)),
        'isWalletAddress': () => storage.isWalletAddress(walletId, 'addr-9'),
        'getAddressMetadata': () => storage.getAddressMetadata(walletId, 'addr-10'),
      };
      for (final entry in operations.entries) {
        final queries = await queriesOf(entry.value);
        expect([for (final q in queries) await q.rowsInRange()], everyElement(lessThanOrEqualTo(1)),
            reason: entry.key);
      }
      final checked = await queriesOf(() async {
        expect(await storage.checkAddresses(walletId, ['addr-1', 'addr-2', 'nope']),
            {'addr-1': true, 'addr-2': true, 'nope': false});
      });
      expect([for (final q in checked) await q.rowsInRange()], [2]);

      // No address: no where clause would mean the whole collection.
      final none = await queriesOf(() async {
        expect(await storage.checkAddresses(walletId, []), isEmpty);
      });
      expect([for (final q in none) await q.rowsInRange()], everyElement(0));
    });

    test('watch addresses are read without the wallet\'s derived addresses', () async {
      for (var i = 0; i < 50; i++) {
        await storage.upsertAddress(walletId, _address('addr-$i', index: i));
      }
      await storage.upsertAddress(walletId, _address('watch-0', purpose: 'watch'));
      await storage.upsertAddress(walletId, _address('watch-1', purpose: 'watch'));

      final queries = await queriesOf(() async {
        expect((await storage.getAddressesByPurpose(walletId, 'watch')).map((a) => a.address).toSet(),
            {'watch-0', 'watch-1'});
      });
      expect([for (final q in queries) await q.rowsInRange()], [2]);
    });

    test('transaction-address links are read by (wallet, txid) and (wallet, address)', () async {
      for (var i = 0; i < 40; i++) {
        await storage.storeTransactionAddresses(walletId, _txid('t$i'), [
          TransactionAddressLink(address: 'addr-common', direction: 'output', amount: BigInt.one, vout: 0),
          TransactionAddressLink(address: 'addr-$i', direction: 'input', amount: BigInt.one, vin: 0),
        ]);
      }
      final byTxid = await queriesOf(() async {
        final links = await storage.getTransactionAddresses(walletId, _txid('t5'));
        expect(links.inputs.single.address, 'addr-5');
      });
      expect([for (final q in byTxid) await q.rowsInRange()], [2]);

      final byAddress = await queriesOf(() async {
        expect(await storage.getAddressTransactionCount(walletId, 'addr-6'), 1);
        expect(await storage.getTransactionsByAddress(walletId, 'addr-6'), [_txid('t6')]);
      });
      expect([for (final q in byAddress) await q.rowsInRange()], [1, 1]);
    });

    test('a history page is read from the index in order: Dart receives only the page', () async {
      for (var i = 0; i < 40; i++) {
        await storage.storeTransaction(walletId, _tx(_txid('h$i'), minute: i));
      }
      final queries = await queriesOf(() async {
        final page = await storage.getTransactionHistory(walletId, limit: 5, offset: 10);
        expect(page.map((t) => t.txid), [for (var i = 29; i > 24; i--) _txid('h$i')]);
      });
      expect(queries, hasLength(1));
      expect(await queries.single.rowsReturned(), 5);
      expect(queries.single.query.sortByProperties, isEmpty,
          reason: 'a sort after the where clause sorts every row of the wallet before paging');
    });

    test('transactions by status for one wallet read only that wallet\'s rows with the status', () async {
      for (var i = 0; i < 30; i++) {
        await storage.storeTransaction(walletId, _tx(_txid('c$i'), minute: i));
        await storage.storeTransaction('other', _tx(_txid('o$i'), minute: i, status: TransactionStatus.pending));
      }
      await storage.storeTransaction(walletId, _tx(_txid('p0'), minute: 50, status: TransactionStatus.pending));
      final queries = await queriesOf(() async {
        expect((await storage.getTransactionsByStatus(TransactionStatus.pending, walletId: walletId)).map((t) => t.txid),
            [_txid('p0')]);
      });
      expect([for (final q in queries) await q.rowsInRange()], [1]);
    });

    test('a deferred-payment page hands Dart at most a page per state, not the retained history', () async {
      for (var i = 0; i < 120; i++) {
        await storage.storeDeferredPayment(contractDeferredPayment(
            walletId: walletId, txid: _txid('mined-$i'), minutesAfterBase: i, state: DeferredPaymentState.mined));
      }
      const query = DeferredPaymentQuery(states: DeferredPaymentQuery.allStates, limit: 10);
      final queries = await queriesOf(() async {
        final page = await storage.listDeferredPayments(walletId, query: query);
        expect(page.payments.map((p) => p.txid), [for (var i = 119; i > 109; i--) _txid('mined-$i')]);
        expect(page.nextCursor, isNotNull);
      });
      final returned = [for (final q in queries) await q.rowsReturned()];
      expect(returned, everyElement(lessThanOrEqualTo(query.effectiveLimit + 1)), reason: '$returned');
    });

    test('deferred-payment paging is exact when page boundaries cut through equal creation times', () async {
      // Groups of payments sharing a creation time, one microsecond apart,
      // each stored out of txid order (the index holds equal times in
      // insertion order), in several states; paged with time filters.
      final t = DateTime.utc(2026, 9, 1, 12, 10);
      const micro = Duration(microseconds: 1);
      final rows = <(String, DateTime, DeferredPaymentState)>[
        for (final tag in ['g', 'c', 'h', 'a', 'f', 'b', 'e', 'd']) ('at-$tag', t, DeferredPaymentState.outstanding),
        for (final tag in ['q', 'n', 'p', 'm', 'o']) ('after-$tag', t.add(micro), DeferredPaymentState.outstanding),
        for (final tag in ['y', 'w', 'z', 'x']) ('before-$tag', t.subtract(micro), DeferredPaymentState.outstanding),
        ('at-s', t, DeferredPaymentState.seen),
        ('after-s', t.add(micro), DeferredPaymentState.seen),
        ('old', t.subtract(const Duration(minutes: 9)), DeferredPaymentState.outstanding),
        ('new', t.add(const Duration(minutes: 10)), DeferredPaymentState.mined),
      ];
      for (final (txid, createdAt, state) in rows) {
        final p = contractDeferredPayment(walletId: walletId, txid: txid, state: state);
        await storage.storeDeferredPayment(DeferredPayment(
          walletId: p.walletId,
          txid: p.txid,
          invoiceId: p.invoiceId,
          purpose: p.purpose,
          recipientAddresses: p.recipientAddresses,
          amount: p.amount,
          fee: p.fee,
          heldInputs: p.heldInputs,
          state: p.state,
          createdAt: createdAt,
          updatedAt: createdAt,
          resolvedAt: p.resolvedAt,
        ));
      }

      final queries = <String, DeferredPaymentQuery Function(int limit, String? cursor, bool oldestFirst)>{
        'no time filter': (limit, cursor, oldestFirst) => DeferredPaymentQuery(
            states: DeferredPaymentQuery.allStates, limit: limit, cursor: cursor, oldestFirst: oldestFirst),
        'createdBefore t+1us': (limit, cursor, oldestFirst) => DeferredPaymentQuery(
            states: DeferredPaymentQuery.allStates,
            createdBefore: t.add(micro),
            limit: limit,
            cursor: cursor,
            oldestFirst: oldestFirst),
        'createdAfter t': (limit, cursor, oldestFirst) => DeferredPaymentQuery(
            states: DeferredPaymentQuery.allStates,
            createdAfter: t,
            limit: limit,
            cursor: cursor,
            oldestFirst: oldestFirst),
      };
      for (final entry in queries.entries) {
        for (final oldestFirst in [false, true]) {
          final order = '${entry.key}, ${oldestFirst ? 'oldest' : 'newest'} first';
          final reference = entry.value(1000, null, oldestFirst);
          final expected = [
            for (final (txid, createdAt, state) in rows)
              if (reference.states.contains(state) &&
                  (reference.createdBefore == null || createdAt.isBefore(reference.createdBefore!)) &&
                  (reference.createdAfter == null || !createdAt.isBefore(reference.createdAfter!)))
                (txid, createdAt),
          ]..sort((a, b) {
              final byTime = a.$2.compareTo(b.$2);
              final c = byTime != 0 ? byTime : a.$1.compareTo(b.$1);
              return oldestFirst ? c : -c;
            });
          final expectedTxids = [for (final e in expected) e.$1];
          expect([for (final p in (await storage.listDeferredPayments(walletId, query: reference)).payments) p.txid],
              expectedTxids,
              reason: '$order, one page');

          for (final limit in [1, 2, 3, 4, 7]) {
            final seen = <String>[];
            String? cursor;
            var pages = 0;
            do {
              final page = await storage.listDeferredPayments(walletId, query: entry.value(limit, cursor, oldestFirst));
              expect(page.payments.length, lessThanOrEqualTo(limit));
              seen.addAll(page.payments.map((p) => p.txid));
              cursor = page.nextCursor;
              pages++;
            } while (cursor != null && pages < 50);
            expect(seen, expectedTxids, reason: '$order, limit $limit');
          }
        }
      }
    });

    test('invoices of one wallet are read without other invoices', () async {
      for (var i = 0; i < 30; i++) {
        await storage.storeInvoice(contractInvoice(invoiceId: 'other-$i', walletId: 'other'));
      }
      await storage.storeInvoice(contractInvoice(invoiceId: 'mine', walletId: walletId));
      final queries = await queriesOf(() async {
        expect((await storage.listInvoices(walletId: walletId)).map((i) => i.invoiceId), ['mine']);
      });
      expect([for (final q in queries) await q.rowsInRange()], [1]);

      final pending = await queriesOf(() async {
        expect(await storage.listInvoices(status: InvoiceStatus.paid), isEmpty);
      });
      expect([for (final q in pending) await q.rowsInRange()], [0]);
    });

    test('UTXOs of one plugin are read without the wallet\'s payment UTXOs', () async {
      for (var i = 0; i < 50; i++) {
        await storage.upsertUTXO(walletId, _utxo(_txid('pay-$i'), 0, minute: i));
      }
      await storage.upsertUTXO(
          walletId, _utxo(_txid('tok-0'), 0, pluginMetadata: {'pluginId': 'tstoken', 'tokenId': 'a'}, minute: 60));
      await storage.upsertUTXO(
          walletId, _utxo(_txid('tok-1'), 0, pluginMetadata: {'pluginId': 'tstoken', 'tokenId': 'b'}, minute: 61));
      await storage.upsertUTXO(
          walletId, _utxo(_txid('ord-0'), 0, pluginMetadata: {'pluginId': 'ordinals'}, minute: 62));
      // Script analysis metadata without a plugin id is a payment UTXO.
      await storage.upsertUTXO(
          walletId, _utxo(_txid('meta-0'), 0, pluginMetadata: {'scriptType': 'p2pkh'}, minute: 63));

      final queries = await queriesOf(() async {
        expect((await storage.getUTXOsByPlugin(walletId, 'tstoken')).map((u) => u.txid),
            [_txid('tok-1'), _txid('tok-0')]);
        expect(
            (await storage.getUTXOsByPlugin(walletId, 'tstoken', metadataFilter: {'tokenId': 'a'})).map((u) => u.txid),
            [_txid('tok-0')]);
      });
      final returned = [for (final q in queries) await q.rowsReturned()];
      expect(returned.fold<int>(0, (a, b) => a + b), lessThanOrEqualTo(2 * 3), reason: '$returned');
    });
  });

  group('ctkm: SPVActor lookups read the rows they return, not the confirmed history', () {
    // _tx gives confirmed rows a height; a pending row has none to keep.
    BitcoinTransaction confirmedAt(String txid, int? height, {int minute = 0}) =>
        _tx(txid, minute: minute, status: TransactionStatus.pending)
            .copyWith(status: TransactionStatus.confirmed, blockHeight: height);

    setUp(() async {
      // Two wallets with a long confirmed history below height 1000.
      for (final wallet in ['h1', 'h2']) {
        for (var i = 0; i < 60; i++) {
          await storage.storeTransaction(wallet, confirmedAt(_txid('$wallet-hist-$i'), 100 + i, minute: i));
        }
      }
    });

    test('confirmed rows from a height (and without one) are read from the (status, blockHeight) index', () async {
      await storage.storeTransaction('h1', confirmedAt(_txid('fork'), 1000, minute: 1));
      await storage.storeTransaction('h2', confirmedAt(_txid('fork'), 1000, minute: 2));
      await storage.storeTransaction('h2', confirmedAt(_txid('above'), 1003, minute: 3));
      await storage.storeTransaction('h1', confirmedAt(_txid('no-height'), null, minute: 4));
      await storage.storeTransaction(
          'h1', _tx(_txid('pending-high'), status: TransactionStatus.pending, minute: 5).copyWith(blockHeight: 2000));

      final withHeight = await queriesOf(() async {
        expect((await storage.getConfirmedTransactionsFromHeight(1000)).map((t) => (t.walletId, t.txid)),
            [('h2', _txid('above')), ('h2', _txid('fork')), ('h1', _txid('fork'))]);
      });
      expect([for (final q in withHeight) await q.rowsInRange()], [3]);

      final withoutHeight = await queriesOf(() async {
        expect((await storage.getConfirmedTransactionsFromHeight(1001, includeWithoutHeight: true)).map((t) => t.txid),
            [_txid('no-height'), _txid('above')]);
      });
      expect([for (final q in withoutHeight) await q.rowsInRange()], [2]);
    });

    test('rows by txid are read from the txid index: every wallet\'s row of those txids only', () async {
      final queries = await queriesOf(() async {
        expect(
            (await storage.getTransactionsByTxids([_txid('h1-hist-7'), _txid('h2-hist-7'), _txid('h1-hist-7')]))
                .map((t) => t.walletId),
            ['h1', 'h2']);
      });
      expect([for (final q in queries) await q.rowsInRange()], [2]);
    });
  });

  test('hg0: orphaned proofs at a range of heights are read from the (status, blockHeight) index', () async {
    // A long orphaned history below the reorganized heights, and current
    // proofs at them.
    for (var i = 0; i < 80; i++) {
      final txid = _txid('orphaned-history-$i');
      await storage.storeMerkleProof(txid, MerkleProof(
          txid: txid, blockHash: _txid('old-block-$i'), blockHeight: 100 + i, position: 0, merkleProof: ['fe$i']));
      await storage.markMerkleProofOrphaned(txid);
    }
    for (var h = 1000; h <= 1003; h++) {
      final txid = _txid('verified-$h');
      await storage.storeMerkleProof(
          txid, MerkleProof(txid: txid, blockHash: _txid('block-$h'), blockHeight: h, position: 0, merkleProof: ['fe$h']));
    }
    for (final h in [1001, 1002]) {
      final txid = _txid('orphaned-$h');
      await storage.storeMerkleProof(
          txid, MerkleProof(txid: txid, blockHash: _txid('orphaned-block-$h'), blockHeight: h, position: 0, merkleProof: ['ff$h']));
      await storage.markMerkleProofOrphaned(txid);
    }

    final queries = await queriesOf(() async {
      expect([for (final p in await storage.getMerkleProofsByStatusBetweenHeights(MerkleProofStatus.orphaned, 1001, 1003)) p.txid],
          [_txid('orphaned-1001'), _txid('orphaned-1002')]);
    });
    expect([for (final q in queries) await q.rowsInRange()], [2]);
  });
}
