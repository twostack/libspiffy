/// A fresh address of the wallet's own, from the public API (bead
/// libspiffy-u5qe): `GenerateAddressCommand` on the coordinator, answered
/// with `AddressGeneratedEvent` once the read model holds the address, with
/// the key's public key when asked for.
library;

import 'dart:io';

import 'package:dactor/dactor.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:isar_community/isar.dart';
import 'package:libspiffy/coordinator.dart' as coord;
import 'package:libspiffy/libspiffy.dart';
import 'package:test/test.dart';

import 'isar_test_helper.dart';
import 'p2p_test_helpers.dart' show kTestXpriv;

void main() {
  late Directory dir;
  late LocalActorSystem actors;
  late Isar isar;
  late LibSpiffyActorSystem spiffy;
  late String walletId;

  setUpAll(ensureIsarInitialized);

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('generate-address-');
    actors = LocalActorSystem(ActorSystemConfig());
    isar = await Isar.open(LibSpiffySchemas.allSchemas,
        directory: dir.path, name: 'generate_address_${DateTime.now().microsecondsSinceEpoch}');
    spiffy = LibSpiffyActorSystem();
    await spiffy.initialize(actorSystem: actors, isar: isar, dataDirectory: dir.path, enableP2P: false);
    walletId = 'w-${DateTime.now().microsecondsSinceEpoch}';
    final created = spiffy.coordinatorEvents!
        .where((e) => e is coord.WalletCreatedEvent && e.walletId == walletId)
        .first
        .timeout(const Duration(seconds: 15));
    spiffy.coordinator.tell(coord.CreateWalletCommand(walletId: walletId, name: 'w', xpriv: kTestXpriv));
    await created;
  });

  tearDown(() async {
    await spiffy.shutdown();
    await isar.close(deleteFromDisk: true);
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<coord.AddressGeneratedEvent> generate(String requestId, {String wallet = '', bool includePublicKey = false}) {
    final answered = spiffy.coordinatorEvents!
        .where((e) => e is coord.AddressGeneratedEvent && e.requestId == requestId)
        .cast<coord.AddressGeneratedEvent>()
        .first
        .timeout(const Duration(seconds: 30));
    spiffy.coordinator.tell(coord.GenerateAddressCommand(
        walletId: wallet.isEmpty ? walletId : wallet, requestId: requestId, includePublicKey: includePublicKey));
    return answered;
  }

  test('a fresh address, with its public key when asked for, held by the read model when it is announced',
      () async {
    final first = await generate('k1', includePublicKey: true);
    expect(first.success, isTrue, reason: first.error);
    final address = first.address!;
    expect(first.chain, AddressChain.receive);
    final publicKey = dartsv.SVPublicKey.fromHex(first.publicKeyHex!);
    expect(dartsv.Address.fromPublicKey(publicKey, dartsv.NetworkType.TEST).toBase58(), address,
        reason: 'the public key is the address\'s');
    final row = await spiffy.walletStorage.getAddressMetadata(walletId, address);
    expect(row, isNotNull, reason: 'the read model holds it: a payment to it attributes');
    expect(row!.derivationIndex, first.derivationIndex);

    final second = await generate('k2');
    expect(second.success, isTrue, reason: second.error);
    expect(second.address, isNot(address), reason: 'fresh every time');
    expect(second.derivationIndex, first.derivationIndex! + 1);
    expect(second.publicKeyHex, isNull, reason: 'not asked for');
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('a wallet that does not exist: a failure with the reason, no address', () async {
    final event = await generate('k3', wallet: 'nobody');
    expect(event.success, isFalse);
    expect(event.address, isNull);
    expect(event.error, isNotNull);
  }, timeout: const Timeout(Duration(minutes: 1)));
}
