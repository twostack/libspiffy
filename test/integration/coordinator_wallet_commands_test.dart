/// Coordinator commands an app needs instead of reaching the wallet
/// aggregate or ARC itself (bead overnode_v2-rww): recording type-42 keys,
/// renaming a wallet, broadcasting a transaction.
library;

import 'dart:convert';
import 'dart:io';

import 'package:dactor/dactor.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:isar_community/isar.dart';
import 'package:test/test.dart';

import 'package:libspiffy/coordinator.dart' as coord;
import 'package:libspiffy/libspiffy.dart';

import 'isar_test_helper.dart';

const _mnemonic = 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
final _identity = utf8.encode('carol|epoch-0');

void main() {
  late Directory dir;
  late Isar isar;
  late LibSpiffyActorSystem libspiffy;

  setUpAll(ensureIsarInitialized);

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('coordinator-commands-');
    isar = await Isar.open(LibSpiffySchemas.allSchemas,
        directory: dir.path, name: 'commands_${DateTime.now().microsecondsSinceEpoch}');
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

  Future<T> ask<T extends coord.CoordinatorReply>(coord.CoordinatorRequest<T> request) async {
    final answer = libspiffy.coordinatorEvents!
        .where((e) => e is T && e.requestId == request.requestId)
        .cast<T>()
        .first
        .timeout(const Duration(seconds: 30));
    libspiffy.coordinator.tell(request);
    return answer;
  }

  Future<void> createWallet(String walletId) async {
    final created = await ask(coord.CreateWalletCommand(walletId: walletId, name: walletId, mnemonic: _mnemonic));
    expect(created.success, isTrue);
  }

  group('RecordType42AddressesCommand', () {
    test('records a key of the wallet\'s anchor, answers once the read model holds it, and again the same', () async {
      await createWallet('w1');
      final anchor = (await ask(coord.IssueAnchorKeyCommand(walletId: 'w1', anchorContext: _identity))).publicKey!;
      final derivation = Type42Derivation(
          anchorPublicKey: anchor, anchorContext: _identity, senderPublicKey: anchor, invoiceNumber: '1-tokens-1');

      final recorded = await ask(coord.RecordType42AddressesCommand(walletId: 'w1', derivations: [derivation]));
      expect(recorded.success, isTrue, reason: recorded.error);
      final address = recorded.addresses.single;
      final row = await libspiffy.walletStorage.getAddressMetadata('w1', address);
      expect(row?.keyPath, Type42KeyPath(derivation.withAnchorContext(derivation.anchorContext!)));

      final again = await ask(coord.RecordType42AddressesCommand(walletId: 'w1', derivations: [derivation]));
      expect(again.addresses, [address]);
    });

    test('refuses a derivation from an anchor the wallet never issued', () async {
      await createWallet('w1');
      final stranger = dartsv.SVPrivateKey().publicKey.toHex();
      final refused = await ask(coord.RecordType42AddressesCommand(walletId: 'w1', derivations: [
        Type42Derivation(anchorPublicKey: stranger, senderPublicKey: stranger, invoiceNumber: '1-tokens-1'),
      ]));
      expect(refused.success, isFalse);
      expect(refused.failure, contains('never issued'));
    });
  });

  group('RenameWalletCommand', () {
    test('answers once the wallet row holds the new name', () async {
      await createWallet('w1');
      final renamed = await ask(coord.RenameWalletCommand(walletId: 'w1', name: 'Holiday fund'));
      expect(renamed.success, isTrue, reason: renamed.error);
      expect((await libspiffy.walletStorage.getWallet('w1'))?['name'], 'Holiday fund');
    });

    test('refuses a wallet that does not exist', () async {
      final refused = await ask(coord.RenameWalletCommand(walletId: 'nope', name: 'x'));
      expect(refused.success, isFalse);
    });
  });

  group('BroadcastTransactionCommand', () {
    test('refuses what is not a transaction', () async {
      final refused = await ask(coord.BroadcastTransactionCommand(walletId: 'w1', txHex: 'beef'));
      expect(refused.success, isFalse);
      expect(refused.failure, contains('Not a transaction'));
    });

    test('answers with ARC\'s answer: here, that there is no ARC', () async {
      final tx = dartsv.Transaction()..version = 1;
      final answer = await ask(coord.BroadcastTransactionCommand(walletId: 'w1', txHex: tx.serialize()));
      expect(answer.success, isFalse);
      expect(answer.txid, tx.id);
    });
  });

  test('AnchorKeys gives the wallet\'s anchor path and key', () async {
    await createWallet('w1');
    final anchor = (await ask(coord.IssueAnchorKeyCommand(walletId: 'w1', anchorContext: _identity))).publicKey!;
    final root = Bip32.masterFromSeed(dartsv.Mnemonic().toSeedHex(_mnemonic), dartsv.NetworkType.TEST);
    expect(AnchorKeys.publicKey(root, _identity), anchor);
    // pinned in type42_wallet_test.dart for WalletKeys.anchorPath
    expect(AnchorKeys.path(utf8.encode('identity-A|epoch-0')), "m/3'/0'/1625108111'/142083867'");
  });
}
