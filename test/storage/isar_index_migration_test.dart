/// Audit 2026-09-14 S-16 (bead libspiffy-ei4) changed two Isar indexes:
/// AddressEntity `walletId` became `(walletId, purpose)` and
/// BitcoinTransactionEntity `status` became `(status, walletId)`. A store
/// written with the former indexes must open with the current schemas and
/// answer the queries that use the new indexes, with every row.
library;

// The former schemas are rebuilt from the generated ones.
// ignore_for_file: invalid_use_of_protected_member, experimental_member_use

import 'dart:io';

import 'package:isar/isar.dart';
import 'package:test/test.dart';

import 'package:libspiffy/src/models/address_metadata.dart';
import 'package:libspiffy/src/models/bitcoin_transaction.dart';
import 'package:libspiffy/src/storage/isar_wallet_storage.dart';
import 'package:libspiffy/src/storage/libspiffy_schemas.dart';

import '../integration/isar_test_helper.dart';

/// [schema] with [indexes] in place of its own.
CollectionSchema<T> _withIndexes<T>(CollectionSchema<T> schema, Map<String, IndexSchema> indexes) =>
    CollectionSchema<T>(
      id: schema.id,
      name: schema.name,
      properties: schema.properties,
      estimateSize: schema.estimateSize,
      serialize: schema.serialize,
      deserialize: schema.deserialize,
      deserializeProp: schema.deserializeProp,
      idName: schema.idName,
      indexes: indexes,
      links: schema.links,
      embeddedSchemas: schema.embeddedSchemas,
      getId: schema.getId,
      getLinks: schema.getLinks,
      attach: schema.attach,
      version: schema.version,
    );

IndexSchema _hashIndex(int id, String property) => IndexSchema(
      id: id,
      name: property,
      unique: false,
      replace: false,
      properties: [IndexPropertySchema(name: property, type: IndexType.hash, caseSensitive: true)],
    );

/// The schemas as generated before the S-16 index change (index ids from
/// libspiffy_schemas.g.dart at commit 354da12).
List<CollectionSchema<dynamic>> _formerSchemas() => [
      for (final schema in LibSpiffySchemas.allSchemas)
        if (schema.name == AddressEntitySchema.name)
          _withIndexes<AddressEntity>(AddressEntitySchema, {
            for (final e in AddressEntitySchema.indexes.entries)
              if (e.key != 'walletId_purpose') e.key: e.value,
            'walletId': _hashIndex(-1783113319798776304, 'walletId'),
          })
        else if (schema.name == BitcoinTransactionEntitySchema.name)
          _withIndexes<BitcoinTransactionEntity>(BitcoinTransactionEntitySchema, {
            for (final e in BitcoinTransactionEntitySchema.indexes.entries)
              if (e.key != 'status_walletId') e.key: e.value,
            'status': _hashIndex(-107785170620420283, 'status'),
          })
        else
          schema,
    ];

BitcoinTransaction _tx(String txid, TransactionStatus status, int minute) => BitcoinTransaction(
      txid: txid,
      rawHex: '0100000000000000000000',
      status: status,
      blockHeight: null,
      confirmations: 0,
      inputValue: BigInt.from(2000),
      outputValue: BigInt.from(1800),
      fee: BigInt.from(200),
      receivingAddresses: const [],
      sendingAddresses: const [],
      netAmount: BigInt.from(1800),
      createdAt: DateTime.utc(2026, 9, 1, 12, minute),
      updatedAt: DateTime.utc(2026, 9, 1, 12, minute),
      lockTime: 0,
      version: 1,
    );

AddressMetadata _address(String address, String purpose, int index) => AddressMetadata(
      address: address,
      scriptType: 'p2pkh',
      derivationIndex: index,
      isChange: false,
      purpose: purpose,
      usageCount: 0,
      balance: BigInt.zero,
      createdAt: DateTime.utc(2026, 9, 1, 12, index),
      isWatched: purpose == 'watch',
    );

void main() {
  late Directory dir;

  setUpAll(() async {
    await ensureIsarInitialized();
  });

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('isar_index_migration_');
  });

  tearDown(() async {
    await dir.delete(recursive: true);
  });

  test('S-16: a store written with the former indexes answers the new indexed queries', () async {
    const name = 'index_migration';
    final former = await Isar.open(_formerSchemas(), directory: dir.path, name: name);
    expect(former.addressEntitys.schema.indexes.keys, contains('walletId'));
    await former.writeTxn(() async {
      for (final wallet in ['w1', 'w2']) {
        for (var i = 0; i < 6; i++) {
          await former.addressEntitys
              .put(_address('$wallet-a$i', i < 2 ? 'watch' : 'receive', i).toEntity(wallet));
          await former.bitcoinTransactionEntitys.put(BitcoinTransactionEntity.fromDomain(
              _tx('$wallet-t$i', i < 3 ? TransactionStatus.pending : TransactionStatus.confirmed, i),
              walletId: wallet));
        }
      }
    });
    await former.close();

    final isar = await Isar.open(LibSpiffySchemas.allSchemas, directory: dir.path, name: name);
    addTearDown(() => isar.close(deleteFromDisk: true));
    expect(isar.addressEntitys.schema.indexes.keys, containsAll(['walletId_purpose']));
    final ranges = <int>[];
    final storage = IsarWalletStorage(isar)
      ..onQuery = (operation, query) => ranges.add(query.collection!
          .buildQuery<dynamic>(whereClauses: query.whereClauses, whereSort: query.whereSort)
          .countSync());

    expect((await storage.getAddressesByPurpose('w1', 'watch')).map((a) => a.address).toSet(), {'w1-a0', 'w1-a1'});
    expect((await storage.getWalletAddresses('w2')).toSet(), {for (var i = 0; i < 6; i++) 'w2-a$i'});
    expect(await storage.getAddressCount('w1'), 6);
    expect((await storage.getTransactionsByStatus(TransactionStatus.pending, walletId: 'w2')).map((t) => t.txid),
        ['w2-t2', 'w2-t1', 'w2-t0']);
    expect((await storage.getTransactionsByStatus(TransactionStatus.confirmed)).map((t) => t.txid).toSet(),
        {'w1-t3', 'w1-t4', 'w1-t5', 'w2-t3', 'w2-t4', 'w2-t5'});
    // Every row written before the change is in the new indexes' ranges.
    expect(ranges, [2, 6, 6, 3, 6]);

    // The former where clauses, kept deprecated for hosts, read the same rows.
    // ignore: deprecated_member_use_from_same_package
    expect(await isar.addressEntitys.where().walletIdEqualTo('w1').count(), 6);
    // ignore: deprecated_member_use_from_same_package
    expect(await isar.addressEntitys.where().walletIdNotEqualTo('w1').count(), 6);
    // ignore: deprecated_member_use_from_same_package
    expect(await isar.bitcoinTransactionEntitys.where().statusEqualTo(TransactionStatus.pending.name).count(), 6);
    expect(
        // ignore: deprecated_member_use_from_same_package
        await isar.bitcoinTransactionEntitys.where().statusNotEqualTo(TransactionStatus.pending.name).count(), 6);
  });

  test('ctkm: a store written before the (status, blockHeight) index answers the height lookup with every row',
      () async {
    const name = 'height_index_migration';
    final former = await Isar.open([
      for (final schema in LibSpiffySchemas.allSchemas)
        if (schema.name == BitcoinTransactionEntitySchema.name)
          _withIndexes<BitcoinTransactionEntity>(BitcoinTransactionEntitySchema, {
            for (final e in BitcoinTransactionEntitySchema.indexes.entries)
              if (e.key != 'status_blockHeight') e.key: e.value,
          })
        else
          schema,
    ], directory: dir.path, name: name);
    expect(former.bitcoinTransactionEntitys.schema.indexes.keys, isNot(contains('status_blockHeight')));
    await former.writeTxn(() async {
      for (var i = 0; i < 6; i++) {
        final status = i < 4 ? TransactionStatus.confirmed : TransactionStatus.pending;
        await former.bitcoinTransactionEntitys.put(BitcoinTransactionEntity.fromDomain(
            _tx('t$i', status, i).copyWith(blockHeight: i == 3 ? null : 500 + i),
            walletId: 'w${i % 2}'));
      }
    });
    await former.close();

    final isar = await Isar.open(LibSpiffySchemas.allSchemas, directory: dir.path, name: name);
    addTearDown(() => isar.close(deleteFromDisk: true));
    expect(isar.bitcoinTransactionEntitys.schema.indexes.keys, contains('status_blockHeight'));
    final storage = IsarWalletStorage(isar);

    expect((await storage.getConfirmedTransactionsFromHeight(501)).map((t) => t.txid), ['t2', 't1']);
    expect((await storage.getConfirmedTransactionsFromHeight(0, includeWithoutHeight: true)).map((t) => t.txid),
        ['t3', 't2', 't1', 't0']);
  });
}
