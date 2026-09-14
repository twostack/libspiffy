import 'dart:io';

import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:eventador/eventador.dart';
import 'package:isar/isar.dart';
import 'package:test/test.dart';

import 'package:libspiffy/src/core/wallet_events.dart';
import 'package:libspiffy/src/models/bitcoin_utxo.dart';
import 'package:libspiffy/src/models/wallet_type.dart';
import 'package:libspiffy/src/projections/wallet_projection.dart';
import 'package:libspiffy/src/services/script_type_registry.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';
import 'package:libspiffy/src/storage/isar_wallet_storage.dart';
import 'package:libspiffy/src/storage/libspiffy_schemas.dart';
import 'package:libspiffy/src/storage/read_model_storage.dart';
import 'package:libspiffy/src/utils/network_name.dart';

import '../integration/isar_test_helper.dart';

const _walletId = 'projection-test-wallet';
const _txid = '1111111111111111111111111111111111111111111111111111111111111111';

/// P2PKH locking script and the matching address for a fixed pubkey hash.
const _pubKeyHash = '89abcdefabbaabbaabbaabbaabbaabbaabbaabba';
const _scriptPubKey = '76a914${_pubKeyHash}88ac';
String _addressFor(dartsv.NetworkType network) =>
    dartsv.Address.fromPubkeyHash(_pubKeyHash, network).toBase58();

WalletProjection _projection(ReadModelStorage storage) => WalletProjection(
      projectionId: 'wallet-projection-test',
      eventStore: _NoopEventStore(),
      storage: storage,
    );

WalletCreatedEvent _created({required String network, required String rootAddress}) =>
    WalletCreatedEvent(
      walletId: _walletId,
      walletName: 'Projection Test',
      rootAddress: rootAddress,
      walletType: WalletType.hd,
      walletMetadata: {'network': network},
      version: 1,
      timestamp: DateTime.utc(2026, 1, 1),
    );

UTXOReceivedEvent _received({required String address, required int satoshis, int version = 2}) =>
    UTXOReceivedEvent(
      walletId: _walletId,
      txid: _txid,
      vout: 0,
      satoshis: satoshis,
      scriptPubKey: _scriptPubKey,
      address: address,
      confirmations: 0,
      version: version,
      timestamp: DateTime.utc(2026, 1, 2),
    );

void main() {
  // ScriptTypeRegistry is a process-wide singleton pinned to the first
  // network it is constructed with, so every wallet in this file is mainnet.

  /// Audit 2026-09-14 H5: the projection created a new address with the
  /// first UTXO's balance/usage already applied and then applied them again
  /// through updateAddressUsage (double count), and never debited the
  /// address balance when the UTXO was spent. The in-memory backend stubs
  /// the address APIs (S-18), so this runs against Isar in a temp dir.
  group('WalletProjection address balance (audit H5)', () {
    late Directory tempDir;
    late Isar isar;
    late IsarWalletStorage storage;
    late WalletProjection projection;
    final address = _addressFor(dartsv.NetworkType.MAIN);

    setUpAll(() async {
      await ensureIsarInitialized();
    });

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('wallet_projection_test_');
      isar = await Isar.open(
        LibSpiffySchemas.allSchemas,
        directory: tempDir.path,
        name: 'projection_${DateTime.now().microsecondsSinceEpoch}',
      );
      storage = IsarWalletStorage(isar);
      projection = _projection(storage);
      await projection.handle(_created(
        network: 'mainnet',
        rootAddress: '1BitcoinEaterAddressDontSendf59kuE',
      ));
    });

    tearDown(() async {
      await isar.close();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('first UTXO for a new address credits the balance and usage exactly once', () async {
      expect(await storage.getAddressMetadata(_walletId, address), isNull);

      await projection.handle(_received(address: address, satoshis: 50000));

      final meta = await storage.getAddressMetadata(_walletId, address);
      expect(meta, isNotNull, reason: 'projection creates unknown addresses on receipt');
      expect(meta!.balance, equals(BigInt.from(50000)));
      expect(meta.usageCount, equals(1));
      expect(meta.firstUsedAt, isNotNull);
    });

    test('spending the UTXO debits the address balance back to zero', () async {
      await projection.handle(_received(address: address, satoshis: 50000));
      await projection.handle(UTXOSpentEvent(
        walletId: _walletId,
        txid: _txid,
        vout: 0,
        spentInTxId: '2222222222222222222222222222222222222222222222222222222222222222',
        version: 3,
        timestamp: DateTime.utc(2026, 1, 3),
      ));

      final utxos = await storage.getUTXOs(_walletId, includeSpent: true);
      expect(utxos.single.status, equals(UTXOStatus.spent));
      final meta = await storage.getAddressMetadata(_walletId, address);
      expect(meta!.balance, equals(BigInt.zero));
    });

    test('creates transaction-address junctions for an imported mainnet transaction', () async {
      // In a running system output scanning pins the ScriptTypeRegistry
      // singleton to the wallet network before any transaction is imported.
      ScriptTypeRegistry(networkType: dartsv.NetworkType.MAIN);
      await projection.handle(_received(address: address, satoshis: 50000));

      final tx = dartsv.Transaction()
        ..version = 1
        ..nLockTime = 0;
      tx.inputs.add(dartsv.TransactionInput('c' * 64, 0, dartsv.TransactionInput.MAX_SEQ_NUMBER));
      tx.outputs.add(dartsv.TransactionOutput(BigInt.from(50000), dartsv.SVScript.fromHex(_scriptPubKey)));

      await projection.handle(TransactionImportedEvent(
        walletId: _walletId,
        txid: tx.id,
        rawHex: tx.serialize(),
        blockHeight: 1,
        bumpProof: '',
        totalOutputSats: 50000,
        numInputs: 1,
        numOutputs: 1,
        txVersion: 1,
        txLockTime: 0,
        walletReceivingAddresses: [address],
        walletReceivedSats: 50000,
        totalInputSats: 51000,
        sendingAddresses: const [],
        version: 3,
        timestamp: DateTime.utc(2026, 1, 3),
      ));

      expect(await storage.getTransaction(tx.id), isNotNull);
      final junctions = await storage.getTransactionAddresses(_walletId, tx.id);
      expect(junctions.outputAddresses, contains(address),
          reason: 'the output paying our address must be linked to it');
    });
  });

  /// Audit 2026-09-14 KM-3 / H1 (projection side): the projection read the
  /// wallet's network and root address back under keys ('network_type',
  /// 'root_address') that no backend returns, so every metadata rewrite
  /// dropped them and received UTXOs were always decoded as testnet.
  group('WalletProjection network handling (audit KM-3 / H1)', () {
    late InMemoryWalletStorage storage;
    late WalletProjection projection;
    final mainnetRoot = _addressFor(dartsv.NetworkType.MAIN);

    setUp(() async {
      storage = InMemoryWalletStorage();
      projection = _projection(storage);
      await projection.handle(_created(network: 'main', rootAddress: mainnetRoot));
    });

    test("stores the canonical network for a wallet created with 'main'", () async {
      final wallet = await storage.getWallet(_walletId);
      expect(wallet!['network'], equals('mainnet'));
      expect(wallet['rootAddress'], equals(mainnetRoot));
    });

    test('preserves network and root address across a metadata rewrite', () async {
      // AddressGeneratedEvent makes the projection re-store the wallet with
      // the address count, reading network/rootAddress back from storage.
      await projection.handle(AddressGeneratedEvent(
        walletId: _walletId,
        address: _addressFor(dartsv.NetworkType.MAIN),
        derivationIndex: 1,
        version: 2,
        timestamp: DateTime.utc(2026, 1, 2),
      ));

      // Preservation only: the canonical spelling is asserted above.
      final wallet = await storage.getWallet(_walletId);
      expect(NetworkName.isMainnet(wallet!['network'] as String?), isTrue,
          reason: 'network must survive the rewrite, got ${wallet['network']}');
      expect(wallet['rootAddress'], equals(mainnetRoot));
    });

    test('decodes a received P2PKH output with the mainnet address prefix', () async {
      final address = _addressFor(dartsv.NetworkType.MAIN);
      expect(address, startsWith('1'));

      await projection.handle(_received(address: address, satoshis: 1000));

      final utxo = (await storage.getUTXOs(_walletId, includeSpent: true)).single;
      expect(utxo.pluginMetadata?['scriptType'], equals('p2pkh'));
      expect(utxo.pluginMetadata?['address'], equals(address),
          reason: 'script metadata must be derived with the wallet network, not testnet');
    });
  });
}

/// WalletProjection takes an EventStore but never reads from it; the
/// projection manager feeds it events. handle() is driven directly here.
class _NoopEventStore implements EventStore {
  @override
  Future<void> persistEvent(String persistenceId, Event event, int expectedVersion) async {}

  @override
  Future<void> persistEvents(String persistenceId, List<Event> events, int expectedVersion) async {}

  @override
  Future<List<Event>> getEvents(String persistenceId, {int fromSequence = 0, int? toSequence}) async => [];

  @override
  Future<int> getHighestSequenceNumber(String persistenceId) async => 0;

  @override
  Future<void> saveSnapshot(String persistenceId, dynamic state, int sequenceNumber) async {}

  @override
  Future<SnapshotData?> loadSnapshot(String persistenceId) async => null;

  @override
  Future<void> deleteOldSnapshots(String persistenceId, int keepCount) async {}

  @override
  Future<void> close() async {}
}
