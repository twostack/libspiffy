/// The replies the wallet gives through `WalletCoordinator.ask` on the real
/// actor system (bead libspiffy-xc78.1): requests that had no answer of
/// their own (a deletion, a release) and the import of a mnemonic wallet,
/// which created the wallet and imported nothing.
import 'dart:io';

import 'package:dactor/dactor.dart';
import 'package:isar_community/isar.dart';
import 'package:test/test.dart';

import 'package:libspiffy/coordinator.dart';
import 'package:libspiffy/libspiffy.dart';

import 'isar_test_helper.dart';

const _mnemonic = 'abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon abandon abandon about';

/// How long a test waits for an answer that should come at once.
const _wait = Duration(seconds: 20);

/// A chain on which no address has ever been used.
class _UnusedChain implements BlockchainDataSource {
  @override
  String get networkType => 'test';
  @override
  Future<List<TransactionInfo>> getTransactionHistory(String address, {int? limit, int? offset}) async => [];
  @override
  Future<List<TransactionInfo>> getScriptHistory(String scriptHash, {int? limit, int? offset}) async => [];
  @override
  Future<List<UtxoInfo>> getUtxos(String address) async => [];
  @override
  Future<List<AddressScriptInfo>> getAddressScripts(String address) async => [];
  @override
  Future<String> getRawTransaction(String txid) => throw DataSourceException('no transaction $txid');
  @override
  Future<MerkleProofData> getMerkleProof(String txid) => throw DataSourceException('no transaction $txid');
  @override
  Future<String> submitTransaction(String rawTxHex) => throw UnsupportedError('submit');
  @override
  Future<int> getCurrentBlockHeight() async => 1000;
}

void main() {
  late Directory dir;
  late Isar isar;
  late LibSpiffyActorSystem libspiffy;
  late InMemorySecureStorage secrets;

  setUpAll(ensureIsarInitialized);

  Future<WalletCoordinator> start({BlockchainDataSource? chain}) async {
    dir = await Directory.systemTemp.createTemp('coordinator_ask_');
    isar = await Isar.open(LibSpiffySchemas.allSchemas,
        directory: dir.path, name: 'ask_${DateTime.now().microsecondsSinceEpoch}');
    libspiffy = LibSpiffyActorSystem();
    secrets = InMemorySecureStorage();
    await libspiffy.initialize(
      actorSystem: LocalActorSystem(ActorSystemConfig()),
      isar: isar,
      dataDirectory: dir.path,
      enableP2P: false,
      secureStorage: secrets,
      blockchainDataSource: chain,
    );
    return libspiffy.coordinator;
  }

  tearDown(() async {
    await libspiffy.shutdown();
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  test('a wallet is created, then deleted, each answered once the read model shows it', () async {
    final coordinator = await start();
    final create = CreateWalletCommand(walletId: 'w', name: 'w', mnemonic: _mnemonic);

    final created = await coordinator.ask(create, timeout: _wait);
    expect(created.requestId, create.requestId);
    expect(created.rootAddress, isNotEmpty);
    expect(await libspiffy.walletStorage.getWallet('w'), isNotNull);

    final deleted = await coordinator.ask(DeleteWalletCommand(walletId: 'w', reason: 'done'), timeout: _wait);
    expect(deleted.success, isTrue);
    expect(await libspiffy.walletStorage.getWallet('w'), isNull,
        reason: 'answered once the read model no longer holds the wallet');

    final again = await coordinator
        .ask(DeleteWalletCommand(walletId: 'w'), timeout: _wait)
        .then<Object>((_) => 'answered', onError: (Object e) => e);
    expect(again, isA<CoordinatorFailure>().having((f) => f.event, 'event', isA<WalletDeletedEvent>()));
  });

  test('a release is answered, naming no UTXO when the reservation held none', () async {
    final coordinator = await start();
    await coordinator.ask(CreateWalletCommand(walletId: 'w', name: 'w', mnemonic: _mnemonic), timeout: _wait);

    final released = await coordinator.ask(ReleaseUTXOsCommand(walletId: 'w', reservationId: 'nothing'), timeout: _wait);

    expect(released.success, isTrue);
    expect(released.reservationId, 'nothing');
    expect(released.releasedUtxoKeys, isEmpty);
  });

  test('a mnemonic wallet is imported, not only created: it ends with its import', () async {
    final coordinator = await start(chain: _UnusedChain());
    final request = ImportWalletCommand(walletId: 'm', walletName: 'm', mnemonic: _mnemonic, gapLimit: 2);

    final imported = await coordinator.ask(request, timeout: _wait);

    expect(imported.requestId, request.requestId);
    expect(imported.success, isTrue);
    expect(imported.transactionCount, 0);
    expect(await secrets.getMnemonic('m'), _mnemonic, reason: 'the wallet keeps the mnemonic it was imported from');
    expect(await libspiffy.walletStorage.getWallet('m'), isNotNull);
  });

  test('without a blockchain data source an import is refused, not answered with a bare creation', () async {
    final coordinator = await start();

    final refused = await coordinator
        .ask(ImportWalletCommand(walletId: 'm', walletName: 'm', mnemonic: _mnemonic), timeout: _wait)
        .then<Object>((_) => 'answered', onError: (Object e) => e);

    expect(refused, isA<CoordinatorFailure>().having((f) => f.message, 'message', contains('blockchain data source')));
    expect(await libspiffy.walletStorage.getWallet('m'), isNull);
  });
}
