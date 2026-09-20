// Bead libspiffy-atl2: a wallet whose `wallet_hdpubkey_<id>` is missing could
// never derive another address, for the life of the wallet, although the key
// material the xpub comes from was sitting beside it in the same secure
// storage. `privateKeyAtIndex` already walked xpriv -> mnemonic for the
// private side; `generateAddress` read one hard-coded key and threw.
//
// The recovery is only safe because it is VERIFIED: a recovered xpub is
// trusted only if it re-derives the wallet's journaled root address (m/0/0).
// A mnemonic wallet's xpub depends on its BIP39 passphrase, so a secure
// storage that lost the hdpubkey may derive a DIFFERENT wallet from the
// mnemonic alone, and handing that back would generate addresses the wallet
// cannot sign for.
import 'dart:io';

import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:eventador/eventador.dart';
import 'package:libspiffy/internals.dart';
import 'package:libspiffy/libspiffy.dart';
import 'package:test/test.dart';

import '../integration/isar_test_helper.dart';

const _mnemonic =
    'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
const _passphrase = 'correct horse battery staple';

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
    dir = await Directory.systemTemp.createTemp('atl2_');
    store = await IsarEventStore.create(
        directory: dir.path,
        name: 'atl2_${DateTime.now().microsecondsSinceEpoch}');
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

  String receivingAddress(int index) => crypto.generateReceivingAddress(
      dartsv.HDPublicKey.fromXpub(xpub), index,
      network: dartsv.NetworkType.TEST);

  /// A wallet as the journal holds it, with the `wallet_hdpubkey_` key taken
  /// back out: the state this bead is about. Whatever [seed] leaves behind is
  /// all the recovery has to work with.
  Future<BitcoinWalletAggregate> walletWithoutHdPubKey(
    String walletId, {
    required CreateWalletCommand create,
    Future<void> Function()? afterCreate,
  }) async {
    final first = await startAggregate(walletId);
    await first.commandHandler(create);
    expect(first.currentState.isCreated, isTrue);
    expect(await secrets.getString('wallet_hdpubkey_$walletId'), isNotNull,
        reason: 'sanity: creation writes the key this test then removes');

    await secrets.delete('wallet_hdpubkey_$walletId');
    await afterCreate?.call();

    return startAggregate(walletId);
  }

  group('an HD wallet whose account xpub is missing from secure storage', () {
    test('re-derives it from the mnemonic and generates the next address',
        () async {
      const walletId = 'atl2-mnemonic';
      final wallet = await walletWithoutHdPubKey(
        walletId,
        create: CreateWalletCommand(
          walletId: walletId,
          walletName: 'recovered',
          mnemonic: _mnemonic,
          walletMetadata: const {'network': 'test'},
        ),
      );

      await wallet.commandHandler(GenerateAddressCommand(walletId: walletId));

      expect(
          (await store.getEvents('Wallet_$walletId'))
              .whereType<AddressGeneratedEvent>()
              .single
              .address,
          receivingAddress(1),
          reason: 'the address is the one the wallet would have derived all '
              'along, on the chain it can sign for');
    });

    test('re-derives it from the xpriv', () async {
      const walletId = 'atl2-xpriv';
      final wallet = await walletWithoutHdPubKey(
        walletId,
        create: CreateWalletCommand(
          walletId: walletId,
          walletName: 'recovered',
          xpriv: xpriv,
          walletMetadata: const {'network': 'test'},
        ),
      );

      await wallet.commandHandler(GenerateAddressCommand(walletId: walletId));

      expect(
          (await store.getEvents('Wallet_$walletId'))
              .whereType<AddressGeneratedEvent>()
              .single
              .address,
          receivingAddress(1));
    });

    test('takes it from the watch-only xpub of an xpub wallet', () async {
      const walletId = 'atl2-xpub';
      final wallet = await walletWithoutHdPubKey(
        walletId,
        create: CreateWalletCommand(
          walletId: walletId,
          walletName: 'recovered',
          xpub: xpub,
          walletMetadata: const {'network': 'test'},
        ),
      );

      await wallet.commandHandler(GenerateAddressCommand(walletId: walletId));

      expect(
          (await store.getEvents('Wallet_$walletId'))
              .whereType<AddressGeneratedEvent>()
              .single
              .address,
          receivingAddress(1));
    });

    test('writes the recovered xpub back, so the recovery happens once',
        () async {
      const walletId = 'atl2-backfill';
      final wallet = await walletWithoutHdPubKey(
        walletId,
        create: CreateWalletCommand(
          walletId: walletId,
          walletName: 'recovered',
          mnemonic: _mnemonic,
          walletMetadata: const {'network': 'test'},
        ),
      );

      await wallet.commandHandler(GenerateAddressCommand(walletId: walletId));
      expect(await secrets.getString('wallet_hdpubkey_$walletId'), xpub,
          reason: 'the verified xpub is restored to its own key');

      // With the seed gone, a wallet that had not been backfilled would be
      // bricked again; this one derives from the restored key.
      await secrets.delete('wallet_mnemonic_$walletId');
      await wallet.commandHandler(GenerateAddressCommand(walletId: walletId));
      expect(
          (await store.getEvents('Wallet_$walletId'))
              .whereType<AddressGeneratedEvent>()
              .map((e) => e.address),
          [receivingAddress(1), receivingAddress(2)]);
    });
  });

  group('a recovery that cannot be verified is refused', () {
    test('a mnemonic wallet whose BIP39 passphrase was lost too', () async {
      // The dangerous case. The mnemonic alone derives a DIFFERENT wallet,
      // and its addresses are ones this wallet can never sign for.
      const walletId = 'atl2-lost-seed-secret';
      final wallet = await walletWithoutHdPubKey(
        walletId,
        create: CreateWalletCommand(
          walletId: walletId,
          walletName: 'passphrase',
          mnemonic: _mnemonic,
          passphrase: _passphrase,
          walletMetadata: const {'network': 'test'},
        ),
        afterCreate: () => secrets.delete('wallet_passphrase_$walletId'),
      );

      await expectLater(
        wallet.commandHandler(GenerateAddressCommand(walletId: walletId)),
        throwsA(isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains(walletId),
              contains('wallet_mnemonic_'),
              contains('passphrase'),
              contains('root address'),
            ))),
        reason: 'the refusal names the key it found, what it could not '
            'confirm, and the passphrase as the likely cause',
      );

      expect(await secrets.getString('wallet_hdpubkey_$walletId'), isNull,
          reason: 'an unverified xpub must never be written back');
      expect(
          (await store.getEvents('Wallet_$walletId'))
              .whereType<AddressGeneratedEvent>(),
          isEmpty,
          reason: 'no address on a chain the wallet cannot sign for');
    });

    test('a wallet with no key material at all says so', () async {
      // The H4 window: the event was journaled before the secrets were
      // written, so an interrupted creation left a wallet with nothing.
      const walletId = 'atl2-no-material';
      final wallet = await walletWithoutHdPubKey(
        walletId,
        create: CreateWalletCommand(
          walletId: walletId,
          walletName: 'empty',
          mnemonic: _mnemonic,
          walletMetadata: const {'network': 'test'},
        ),
        afterCreate: () => secrets.delete('wallet_mnemonic_$walletId'),
      );

      await expectLater(
        wallet.commandHandler(GenerateAddressCommand(walletId: walletId)),
        throwsA(isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains(walletId),
              contains('wallet_hdpubkey_'),
              contains('wallet_xpriv_'),
              contains('wallet_mnemonic_'),
            ))),
        reason: 'the failure names every key that was looked for, so a host '
            'can tell a lost secret from a lost derived key',
      );
    });
  });

  test('a wallet that still has its xpub never reads the fallbacks', () async {
    // The recovery is for the broken case only: an intact wallet must not
    // start depending on key material a watch-only host does not hold.
    const walletId = 'atl2-intact';
    final first = await startAggregate(walletId);
    await first.commandHandler(CreateWalletCommand(
      walletId: walletId,
      walletName: 'intact',
      mnemonic: _mnemonic,
      walletMetadata: const {'network': 'test'},
    ));
    await secrets.delete('wallet_mnemonic_$walletId');

    final wallet = await startAggregate(walletId);
    await wallet.commandHandler(GenerateAddressCommand(walletId: walletId));

    expect(
        (await store.getEvents('Wallet_$walletId'))
            .whereType<AddressGeneratedEvent>()
            .single
            .address,
        receivingAddress(1));
  });
}
