/// A wallet signs a message with the key of one of its addresses
/// (SignMessageCommand, bead overnode_v2-l6bx.7): the signature checks as a
/// Bitcoin Signed Message against that address, and a key the wallet does
/// not hold, only watches, or is not its one WIF key, is refused.
library;

import 'dart:convert';
import 'dart:io';

import 'package:convert/convert.dart';
import 'package:dactor/dactor.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:isar_community/isar.dart';
import 'package:test/test.dart';

import 'package:libspiffy/coordinator.dart' as coord;
import 'package:libspiffy/libspiffy.dart';

import 'isar_test_helper.dart';

const _mnemonic = 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';

void main() {
  late Directory dir;
  late Isar isar;
  late LibSpiffyActorSystem libspiffy;

  setUpAll(ensureIsarInitialized);

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('sign-message-');
    isar = await Isar.open(LibSpiffySchemas.allSchemas,
        directory: dir.path, name: 'sign_message_${DateTime.now().microsecondsSinceEpoch}');
    libspiffy = LibSpiffyActorSystem();
    await libspiffy.initialize(
      actorSystem: LocalActorSystem(ActorSystemConfig()),
      isar: isar,
      dataDirectory: dir.path,
      enableP2P: false,
      secureStorage: InMemorySecureStorage(),
    );
  });

  tearDown(() async {
    await libspiffy.shutdown();
    await isar.close(deleteFromDisk: true);
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<T> next<T extends coord.CoordinatorEvent>(bool Function(T) where) => libspiffy.coordinatorEvents!
      .where((e) => e is T && where(e))
      .cast<T>()
      .first
      .timeout(const Duration(seconds: 20));

  Future<void> createWallet(String walletId, {String? mnemonic, String? wif, String? xpub}) async {
    final created = next<coord.WalletCreatedEvent>((e) => e.walletId == walletId);
    libspiffy.coordinator.tell(
        coord.CreateWalletCommand(walletId: walletId, name: walletId, mnemonic: mnemonic, wif: wif, xpub: xpub));
    expect((await created).success, isTrue);
  }

  Future<String> newAddress(String walletId) async {
    final generated = next<coord.AddressGeneratedEvent>((e) => e.walletId == walletId);
    libspiffy.coordinator.tell(coord.GenerateAddressCommand(walletId: walletId, label: 'token'));
    final event = await generated;
    expect(event.success, isTrue, reason: event.error);
    return event.address!;
  }

  Future<coord.MessageSignedEvent> sign(String walletId, String pubkeyHash, List<int> message) {
    final answer = next<coord.MessageSignedEvent>((e) => e.walletId == walletId);
    libspiffy.coordinator
        .tell(coord.SignMessageCommand(walletId: walletId, pubkeyHash: pubkeyHash, message: message));
    return answer;
  }

  String hashOf(String address) => dartsv.Address.fromBase58(address).pubkeyHash160;

  test('a message signed with an address key checks against that address, and against no other', () async {
    await createWallet('carol', mnemonic: _mnemonic);
    final address = await newAddress('carol');
    final other = await newAddress('carol');
    final message = utf8.encode('referrals/CreateLink\nissuer\ntoken\nnonce');

    final signed = await sign('carol', hashOf(address), message);
    expect(signed.success, isTrue, reason: signed.error);
    expect(hex.encode(dartsv.hash160(hex.decode(signed.publicKey!))), hashOf(address));
    final checked = dartsv.Message(message);
    expect(checked.verifyFromAddress(dartsv.Address.fromBase58(address), signed.signature!), isTrue);
    expect(checked.verifyFromAddress(dartsv.Address.fromBase58(other), signed.signature!), isFalse);
    expect(dartsv.Message(utf8.encode('another message')).verifyFromAddress(dartsv.Address.fromBase58(address), signed.signature!),
        isFalse);

    // Upper-case hex names the same key.
    expect((await sign('carol', hashOf(address).toUpperCase(), message)).signature, signed.signature);
  });

  test('a key the wallet does not hold is refused, and so is a hash that is not one', () async {
    await createWallet('carol', mnemonic: _mnemonic);
    final notOurs = await sign('carol', '11' * 20, utf8.encode('m'));
    expect(notOurs.success, isFalse);
    expect(notOurs.error, contains('holds no key'));

    final notAHash = await sign('carol', 'abc', utf8.encode('m'));
    expect(notAHash.success, isFalse);
    expect(notAHash.error, contains('40 hex'));
  });

  test('a watch-only wallet signs nothing; a WIF wallet signs only with its one key', () async {
    final crypto = DartSVCryptoService();
    final xpub = crypto.deriveHDPublicKey(await crypto.mnemonicToHDPrivateKey(_mnemonic)).xpubkey;
    await createWallet('watcher', xpub: xpub);
    final watched = await newAddress('watcher');
    final refused = await sign('watcher', hashOf(watched), utf8.encode('m'));
    expect(refused.success, isFalse);

    final key = dartsv.SVPrivateKey(networkType: dartsv.NetworkType.TEST);
    await createWallet('single', wif: key.toWIF());
    final own = hex.encode(dartsv.hash160(hex.decode(key.publicKey.toHex())));
    final signed = await sign('single', own, utf8.encode('m'));
    expect(signed.success, isTrue, reason: signed.error);
    expect(signed.publicKey, key.publicKey.toHex());

    final another = await sign('single', '22' * 20, utf8.encode('m'));
    expect(another.success, isFalse);
    expect(another.error, contains('holds no key'));
  });
}
