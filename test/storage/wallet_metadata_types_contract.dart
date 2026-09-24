/// Wallet row metadata value types, shared by the three [ReadModelStorage]
/// backends (bead libspiffy-k7na).
///
/// The wallet row's derived values (`WalletMetadataKeys.readModel`) have
/// types: balances are decimal strings, counts, the derivation index and the
/// aggregate version are integers, the wallet type and the JSON columns are
/// strings. The Isar backend cast them without a check (a non-string
/// `confirmedBalance` threw a cast error inside the projection), and wrote
/// `{}` in place of the whole metadata when a value was not JSON; Postgres
/// threw the JSON encoder's error; the in-memory backend stored anything.
///
/// Every backend now converts a value of such a key that has an unambiguous
/// reading (an integer balance, a numeric string count, a list for a JSON
/// column) and rejects any other value, and any value that is not JSON, with
/// an [ArgumentError] naming the key, before it writes anything.
library;

import 'package:test/test.dart';

import 'package:libspiffy/src/storage/read_model_storage.dart';

/// Registers the wallet metadata type contract tests.
void defineWalletMetadataTypesContract(
  ReadModelStorage Function() storage, {
  required String Function() unique,
}) {
  group('wallet metadata types (k7na)', () {
    test('derived values of a convertible type are stored with their type, on creation and on update', () async {
      final s = storage();
      final wallet = 'wmt-convert-${unique()}';
      await s.storeWallet(wallet, 'W', networkType: 'testnet', metadata: {
        'confirmedBalance': 1234,
        'unconfirmedBalance': BigInt.from(5),
        'totalBalance': '1239',
        'derivationIndex': '7',
        'aggregateVersion': 3.0,
        'utxoCount': '2',
        'addressesJson': ['mkHS9ne12qx9pS9VojpwU5xtRd4T7X7ZUt'],
        'walletType': 'hd',
        'label': 'savings',
      });
      var metadata = (await s.getWallet(wallet))!['metadata'] as Map<String, dynamic>;
      expect(metadata['confirmedBalance'], '1234');
      expect(metadata['unconfirmedBalance'], '5');
      expect(metadata['totalBalance'], '1239');
      expect(metadata['derivationIndex'], 7);
      expect(metadata['aggregateVersion'], 3);
      expect(metadata['utxoCount'], 2);
      expect(metadata['addressesJson'], '["mkHS9ne12qx9pS9VojpwU5xtRd4T7X7ZUt"]');
      expect(metadata['label'], 'savings');

      await s.storeWallet(wallet, 'W', metadata: {...metadata, 'confirmedBalance': 99, 'spentUtxoCount': '4'});
      metadata = (await s.getWallet(wallet))!['metadata'] as Map<String, dynamic>;
      expect(metadata['confirmedBalance'], '99');
      expect(metadata['spentUtxoCount'], 4);
      expect(metadata['label'], 'savings');
      expect((await s.getWallet(wallet))!['network'], 'testnet');
    });

    // Bead libspiffy-bfs1: the read side's balances ask the row's
    // `walletType` whether the wallet holds keys at all. Postgres wrote 'hd'
    // for every wallet and the in-memory backend wrote no `walletType`, so an
    // xpub wallet's money was spendable there.
    test('the wallet type given on creation is the row\'s walletType, kept by a later update', () async {
      final s = storage();
      final wallet = 'wmt-type-${unique()}';
      await s.storeWallet(wallet, 'W', networkType: 'testnet', metadata: {'walletType': 'xpub', 'totalBalance': '0'});
      expect((await s.getWallet(wallet))!['walletType'], 'xpub');
      await s.storeWallet(wallet, 'W', metadata: {'totalBalance': '5'});
      expect((await s.getWallet(wallet))!['walletType'], 'xpub');

      final plain = 'wmt-type-hd-${unique()}';
      await s.storeWallet(plain, 'W', networkType: 'testnet');
      expect((await s.getWallet(plain))!['walletType'], 'hd', reason: 'a row created without a type');
    });

    test('a value that cannot be read as its type, or is not JSON, is rejected naming its key; nothing is written',
        () async {
      final s = storage();
      final wallet = 'wmt-reject-${unique()}';
      await s.storeWallet(wallet, 'W', metadata: {'confirmedBalance': '100', 'label': 'kept'});
      final before = (await s.getWallet(wallet))!['metadata'] as Map<String, dynamic>;

      for (final (key, value) in <(String, Object)>[
        ('confirmedBalance', 'lots'),
        ('confirmedBalance', 1.5),
        ('watchOnlyBalance', <String>[]),
        ('derivationIndex', 'seven'),
        ('aggregateVersion', 2.5),
        ('utxoCount', true),
        ('walletType', 5),
        ('addressesJson', 42),
        ('openedAt', DateTime.utc(2026, 9, 16)),
      ]) {
        final what = '$key: $value (${value.runtimeType})';
        await expectLater(
          s.storeWallet(wallet, 'W', metadata: {...before, key: value}),
          throwsA(isA<ArgumentError>().having((e) => e.name, 'name', key)),
          reason: what,
        );
        expect((await s.getWallet(wallet))!['metadata'], before, reason: '$what: the row is unchanged');
      }

      final created = 'wmt-reject-new-${unique()}';
      await expectLater(s.storeWallet(created, 'W', metadata: {'derivationIndex': 'first'}),
          throwsA(isA<ArgumentError>().having((e) => e.name, 'name', 'derivationIndex')));
      expect(await s.getWallet(created), isNull, reason: 'a rejected creation creates no wallet');
    });
  });
}
