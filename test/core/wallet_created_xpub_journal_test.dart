// Audit 2026-09-14 KM-8: the account xpub reveals the wallet's whole address
// graph and balance. It lives in secure storage (encrypted by
// PostgresSecureStorage) and must not also sit in plaintext in the event
// journal. Journals that already carry it must still replay.
import 'dart:io';

import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:eventador/eventador.dart';
import 'package:isar/isar.dart';
import 'package:libspiffy/internals.dart';
import 'package:libspiffy/libspiffy.dart';
import 'package:test/test.dart';

import '../integration/isar_test_helper.dart';

const _mnemonic =
    'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';

/// A row as an earlier release wrote it: class-name type, xpub included.
class _LegacyRow extends Event {
  final Map<String, dynamic> payload;

  _LegacyRow(this.payload)
      : super(
          eventId: payload['eventId'] as String,
          version: payload['version'] as int,
        );

  @override
  String get typeName => payload['type'] as String;

  @override
  Map<String, dynamic> toMap() => payload;
}

void main() {
  final crypto = DartSVCryptoService();
  late Directory dir;
  late IsarEventStore store;
  late InMemorySecureStorage secrets;
  late String xpub;
  late String xpriv;

  setUpAll(() async {
    await ensureIsarInitialized();
    final hd = await crypto.mnemonicToHDPrivateKey(_mnemonic,
        network: dartsv.NetworkType.TEST);
    xpriv = hd.xprivkey;
    xpub = crypto.deriveHDPublicKey(hd).xpubkey;
  });

  setUp(() async {
    EventRegistry.clear();
    LibSpiffyActorSystem.registerEventTypes();
    dir = await Directory.systemTemp.createTemp('lane3_km8_');
    store = await IsarEventStore.create(
        directory: dir.path,
        name: 'km8_${DateTime.now().microsecondsSinceEpoch}');
    secrets = InMemorySecureStorage();
  });

  tearDown(() async {
    await store.close();
    await dir.delete(recursive: true);
  });

  Future<BitcoinWalletAggregate> startAggregate(String walletId) async {
    final aggregate = BitcoinWalletAggregate(
      aggregateId: walletId,
      aggregateType: 'Wallet',
      eventStore: store,
      cryptoService: crypto,
      secureStorage: secrets,
    );
    await aggregate.preStart();
    return aggregate;
  }

  Future<List<int>> storedBytes(String walletId) async {
    final envelopes = await store.isar.eventEnvelopes.where().findAll();
    return envelopes
        .where((e) => e.persistenceId == 'Wallet_$walletId')
        .expand((e) => e.eventData)
        .toList();
  }

  String receivingAddress(int index) => crypto.deriveAddress(
      dartsv.HDPublicKey.fromXpub(xpub), index,
      network: dartsv.NetworkType.TEST);

  /// What an xpub wallet issues: the delegated chain (bead libspiffy-m8qu).
  String delegatedAddress(int index) => crypto.deriveAddress(
      dartsv.HDPublicKey.fromXpub(xpub), index,
      chain: AddressChain.delegated, network: dartsv.NetworkType.TEST);

  for (final variant in ['mnemonic', 'xpriv', 'xpub']) {
    test('$variant wallet: the journaled WalletCreatedEvent carries no xpub', () async {
      final walletId = 'km8-$variant';
      final wallet = await startAggregate(walletId);
      await wallet.commandHandler(CreateWalletCommand(
        walletId: walletId,
        walletName: 'KM-8 $variant',
        mnemonic: variant == 'mnemonic' ? _mnemonic : null,
        xpriv: variant == 'xpriv' ? xpriv : null,
        xpub: variant == 'xpub' ? xpub : null,
      ));
      expect(wallet.currentState.isCreated, isTrue);

      final persisted = await store.getEvents('Wallet_$walletId');
      final created = persisted.whereType<WalletCreatedEvent>().single;
      expect(created.toMap().containsKey('hdPublicKeyXpub'), isFalse,
          reason: 'WalletCreatedEvent map still holds the xpub');
      final stored = String.fromCharCodes(await storedBytes(walletId));
      expect(stored, contains(created.rootAddress),
          reason: 'sanity: the stored row was found');
      expect(stored, isNot(contains(xpub)),
          reason: 'the xpub is in the stored event bytes');

      // The aggregate still has what it needs: the xpub in secure storage.
      expect(await secrets.getString('wallet_hdpubkey_$walletId'), xpub);
    });
  }

  test('a watch-only xpub wallet replays from the journal and derives addresses', () async {
    const walletId = 'km8-replay';
    final first = await startAggregate(walletId);
    await first.commandHandler(CreateWalletCommand(
        walletId: walletId, walletName: 'watch', xpub: xpub));

    final replayed = await startAggregate(walletId);
    expect(replayed.currentState.isCreated, isTrue);
    expect(replayed.currentState.walletType, WalletType.xpub);
    expect(replayed.currentState.rootAddress, receivingAddress(0));

    await replayed.commandHandler(GenerateAddressCommand(walletId: walletId));
    final generated = (await store.getEvents('Wallet_$walletId'))
        .whereType<AddressGeneratedEvent>()
        .single;
    expect(generated.address, delegatedAddress(1));
  });

  test('an old journal whose WalletCreatedEvent holds the xpub still replays', () async {
    const walletId = 'km8-legacy';
    // What an earlier release left behind: secrets in secure storage and a
    // class-name row with the xpub in the payload.
    await secrets.setXPub(walletId, xpub);
    // This wallet still HAS its derived key, which is the KM-8 case. A
    // journaled wallet whose wallet_hdpubkey_ is missing is a different
    // matter and is covered by wallet_account_xpub_recovery_test.dart
    // (bead libspiffy-atl2).
    await secrets.setString('wallet_hdpubkey_$walletId', xpub);
    final oldPayload = WalletCreatedEvent(
      walletId: walletId,
      walletName: 'legacy',
      rootAddress: receivingAddress(0),
      walletType: WalletType.xpub,
      walletMetadata: {'network': 'test'},
      version: 1,
    ).toMap()
      ..['type'] = 'WalletCreatedEvent'
      ..['hdPublicKeyXpub'] = xpub;
    await store.persistEvent('Wallet_$walletId', _LegacyRow(oldPayload), 0);

    final wallet = await startAggregate(walletId);
    expect(wallet.currentState.isCreated, isTrue);
    expect(wallet.currentState.walletType, WalletType.xpub);

    final restored = (await store.getEvents('Wallet_$walletId'))
        .whereType<WalletCreatedEvent>()
        .single;
    // Nothing read from the old row is dropped...
    // ignore: deprecated_member_use
    expect(restored.hdPublicKeyXpub, xpub);
    // ...but re-serializing it does not carry the xpub forward.
    expect(restored.toMap().containsKey('hdPublicKeyXpub'), isFalse,
        reason: 're-serializing an old event must not carry the xpub forward');

    await wallet.commandHandler(GenerateAddressCommand(walletId: walletId));
    expect(
        (await store.getEvents('Wallet_$walletId'))
            .whereType<AddressGeneratedEvent>()
            .single
            .address,
        delegatedAddress(1));
  });
}
