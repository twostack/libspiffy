/// ImportActor network-name and logging tests.
///
/// Covers audit findings (doc/audit-2026-09-14.md):
/// - KM-3 (importer part, bead libspiffy-ecd): the importer writes
///   `network: 'main'` while the aggregate used to compare against
///   `'mainnet'`, so a mainnet WIF was rejected and a testnet WIF was
///   accepted into a 'main' wallet. NetworkName now reconciles both.
/// - KM-7 / A-L5: the xpub is not logged at INFO during an xpriv import.
///
/// Runs the real ImportActor through LibSpiffyActorSystem with a data
/// source that has no history, so imports finish in well under a second.

import 'dart:async';
import 'dart:io';
import 'package:test/test.dart';
import 'package:dactor/dactor.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:isar/isar.dart';
import 'package:logging/logging.dart' as logging;
import 'package:libspiffy/libspiffy.dart';
import 'package:libspiffy/internals.dart';
import 'package:libspiffy/src/models/blockchain_data_models.dart';
import 'package:libspiffy/src/services/blockchain_data_source.dart';
import 'isar_test_helper.dart';

/// Fixed, unfunded private key scalar; WIFs for each network are derived
/// from it deterministically.
const _privHex =
    'a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90';

String _wif(dartsv.NetworkType network) =>
    dartsv.SVPrivateKey.fromHex(_privHex, network).toWIF();

void main() {
  late Directory testDir;
  late LocalActorSystem actorSystem;
  late Isar isar;
  late LibSpiffyActorSystem libspiffy;

  setUpAll(() async {
    await ensureIsarInitialized();
  });

  setUp(() async {
    testDir = await Directory.systemTemp.createTemp('import_network_test_');
    actorSystem = LocalActorSystem(ActorSystemConfig());
    isar = await Isar.open(
      LibSpiffySchemas.allSchemas,
      directory: testDir.path,
      name: 'import_network_${DateTime.now().microsecondsSinceEpoch}',
    );
    libspiffy = LibSpiffyActorSystem();
    await libspiffy.initialize(
      actorSystem: actorSystem,
      isar: isar,
      dataDirectory: testDir.path,
      blockchainDataSource: _EmptyDataSource(),
      enableP2P: false,
    );
  });

  tearDown(() async {
    try {
      await libspiffy.shutdown();
    } catch (_) {}
    try {
      await testDir.delete(recursive: true);
    } catch (_) {}
  });

  /// Resolves with the terminal import event (completed or failed).
  Future<WalletImportNotification> awaitImportOutcome(String walletId) {
    return libspiffy
        .subscribeToImportNotifications(walletId)
        .firstWhere((e) =>
            e is WalletImportCompletedEvent || e is WalletImportFailedEvent)
        .timeout(const Duration(seconds: 30));
  }

  /// The projection writes the wallet row asynchronously after the import
  /// actor reports completion, so poll briefly for it.
  Future<Map<String, dynamic>?> waitForWallet(String walletId) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (DateTime.now().isBefore(deadline)) {
      final wallet = await libspiffy.walletStorage.getWallet(walletId);
      if (wallet != null) return wallet;
      await Future.delayed(const Duration(milliseconds: 50));
    }
    return null;
  }

  group('KM-3: WIF network is validated against the wallet network', () {
    test('mainnet WIF imports into a wallet created with networkType main',
        () async {
      final walletId = 'main-wif-${DateTime.now().microsecondsSinceEpoch}';
      final outcome = awaitImportOutcome(walletId);

      libspiffy.importWalletFromWif(
        walletId: walletId,
        wif: _wif(dartsv.NetworkType.MAIN),
        walletName: 'Mainnet WIF',
        networkType: 'main',
      );

      final event = await outcome;
      // Old code compared 'main' to 'mainnet', resolved the wallet as
      // testnet and rejected the key with "WIF network type does not match".
      expect(event, isA<WalletImportCompletedEvent>(),
          reason: event is WalletImportFailedEvent ? event.error : null);

      final wallet = await waitForWallet(walletId);
      expect(wallet, isNotNull, reason: 'wallet row not projected');
      expect(wallet!['network'], 'mainnet');
      expect((wallet['rootAddress'] as String).startsWith('1'), isTrue,
          reason: 'root address must be mainnet P2PKH: ${wallet['rootAddress']}');
    });

    test('testnet WIF is rejected by a wallet created with networkType main',
        () async {
      final walletId = 'test-wif-${DateTime.now().microsecondsSinceEpoch}';
      final outcome = awaitImportOutcome(walletId);

      libspiffy.importWalletFromWif(
        walletId: walletId,
        wif: _wif(dartsv.NetworkType.TEST),
        walletName: 'Testnet WIF into mainnet wallet',
        networkType: 'main',
      );

      final event = await outcome;
      // Old code resolved 'main' as testnet, so the testnet key passed.
      expect(event, isA<WalletImportFailedEvent>());
      expect((event as WalletImportFailedEvent).error,
          contains('WIF network type does not match'));
    });
  });

  group('KM-7: xpub is not logged during import', () {
    test('xpriv import emits no log record containing the xpub', () async {
      final hdPrivateKey = dartsv.HDPrivateKey.fromSeed(
        '000102030405060708090a0b0c0d0e0f',
        dartsv.NetworkType.TEST,
      );
      final xpub = hdPrivateKey.hdPublicKey.xpubkey;

      final walletId = 'xpriv-${DateTime.now().microsecondsSinceEpoch}';
      final outcome = awaitImportOutcome(walletId);

      final records = <logging.LogRecord>[];
      final previousLevel = logging.Logger.root.level;
      logging.Logger.root.level = logging.Level.ALL;
      final subscription = logging.Logger.root.onRecord.listen(records.add);
      try {
        libspiffy.importWalletFromXpriv(
          walletId: walletId,
          xpriv: hdPrivateKey.xprivkey,
          walletName: 'Xpriv import',
          networkType: 'test',
          addressGapLimit: 1,
        );
        final event = await outcome;
        expect(event, isA<WalletImportCompletedEvent>(),
            reason: event is WalletImportFailedEvent ? event.error : null);
      } finally {
        await subscription.cancel();
        logging.Logger.root.level = previousLevel;
      }

      final leaking = records
          .where((r) => r.message.contains(xpub))
          .map((r) => '[${r.loggerName}/${r.level.name}] ${r.message}')
          .toList();
      expect(leaking, isEmpty, reason: 'xpub found in log output');
    });
  });
}

/// Data source with no history for any address.
class _EmptyDataSource implements BlockchainDataSource {
  @override
  String get networkType => 'test';

  @override
  Future<List<TransactionInfo>> getTransactionHistory(String address,
          {int? limit, int? offset}) async =>
      const [];

  @override
  Future<String> getRawTransaction(String txid) =>
      throw DataSourceException('not found', txid: txid);

  @override
  Future<MerkleProofData> getMerkleProof(String txid) =>
      throw DataSourceException('not found', txid: txid);

  @override
  Future<List<UtxoInfo>> getUtxos(String address) async => const [];

  @override
  Future<List<AddressScriptInfo>> getAddressScripts(String address) async =>
      const [];

  @override
  Future<List<TransactionInfo>> getScriptHistory(String scriptHash,
          {int? limit, int? offset}) async =>
      const [];

  @override
  Future<int> getCurrentBlockHeight() async => 0;

  @override
  Future<String> submitTransaction(String rawTxHex) =>
      throw UnimplementedError();
}
