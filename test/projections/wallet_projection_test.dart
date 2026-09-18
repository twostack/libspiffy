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
  _tolerantAndIdempotentGroups();

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


/// Opens a fresh Isar in a temp dir with a mainnet wallet already created.
/// The in-memory backend stubs the address APIs (S-18), so read-model
/// behaviour that involves addresses is exercised against Isar.
class _IsarFixture {
  late Directory tempDir;
  late Isar isar;
  late IsarWalletStorage storage;
  late WalletProjection projection;

  Future<void> open() async {
    await ensureIsarInitialized();
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
  }

  Future<void> close() async {
    await isar.close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  }
}

const _spendingTxid = '2222222222222222222222222222222222222222222222222222222222222222';

UTXOReceivedEvent _receivedAt(String address, int vout, int satoshis) => UTXOReceivedEvent(
      walletId: _walletId,
      txid: _txid,
      vout: vout,
      satoshis: satoshis,
      scriptPubKey: _scriptPubKey,
      address: address,
      confirmations: 0,
      version: 10 + vout,
      timestamp: DateTime.utc(2026, 1, 2, 0, vout),
    );

UTXOSpentEvent _spent(int vout) => UTXOSpentEvent(
      walletId: _walletId,
      txid: _txid,
      vout: vout,
      spentInTxId: _spendingTxid,
      version: 20 + vout,
      timestamp: DateTime.utc(2026, 1, 3, 0, vout),
    );

UTXOConfirmationUpdatedEvent _confirmed(int vout, int confirmations) => UTXOConfirmationUpdatedEvent(
      walletId: _walletId,
      txid: _txid,
      vout: vout,
      confirmations: confirmations,
      blockHeight: 800000,
      version: 30 + vout,
      timestamp: DateTime.utc(2026, 1, 4, 0, vout),
    );

UTXOReservedEvent _reserved(int vout) => UTXOReservedEvent(
      walletId: _walletId,
      txid: _txid,
      vout: vout,
      reservedByTxId: _spendingTxid,
      expiresAt: DateTime.utc(2026, 1, 5),
      version: 40 + vout,
      timestamp: DateTime.utc(2026, 1, 3, 12, vout),
    );

/// Everything the projection maintains for [address] and the wallet, minus
/// wall-clock fields, so two read models can be compared for equality.
Future<Map<String, Object?>> _snapshot(IsarWalletStorage storage, String address) async {
  final meta = await storage.getAddressMetadata(_walletId, address);
  final wallet = await storage.getWallet(_walletId);
  final walletMeta = Map<String, dynamic>.from(wallet!['metadata'] as Map)
    ..remove('lastUpdated');
  final utxos = (await storage.getUTXOs(_walletId, includeSpent: true))
      .map((u) => '${u.txid}:${u.vout}:${u.satoshis}:${u.status.name}:${u.confirmations}')
      .toList()
    ..sort();
  return {
    'addressBalance': meta?.balance.toString(),
    'addressUsageCount': meta?.usageCount,
    'addressFirstUsedAt': meta?.firstUsedAt?.toUtc().toIso8601String(),
    'addressLastUsedAt': meta?.lastUsedAt?.toUtc().toIso8601String(),
    'addressCount': (await storage.getWalletAddresses(_walletId)).length,
    'wallet': walletMeta.toString(),
    'utxos': utxos.join(','),
  };
}

void _tolerantAndIdempotentGroups() {
  /// Audit 2026-09-14 M2: handlers threw StateError for read-model rows they
  /// could not find; under ProjectionActor a throwing handler skips the event
  /// for good (awaiters never resolve, the checkpoint moves past it later),
  /// so the read model silently diverged. Replay also double-applied the
  /// delta-based address balance from H5.
  group('WalletProjection tolerates read-model gaps (audit M2)', () {
    final fx = _IsarFixture();
    final address = _addressFor(dartsv.NetworkType.MAIN);

    setUp(fx.open);
    tearDown(fx.close);

    test('UTXOSpent for an unknown UTXO does not throw and the next event is still applied', () async {
      final handled = await fx.projection.handle(_spent(7));
      expect(handled, isTrue);

      await fx.projection.handle(_receivedAt(address, 0, 50000));
      final utxos = await fx.storage.getUTXOs(_walletId, includeSpent: true);
      expect(utxos.map((u) => u.vout), equals([0]));
      final meta = await fx.storage.getAddressMetadata(_walletId, address);
      expect(meta!.balance, equals(BigInt.from(50000)));
      final wallet = await fx.storage.getWallet(_walletId);
      expect((wallet!['metadata'] as Map)['totalBalance'], equals('50000'));
    });

    test('UTXO status and confirmation events for an unknown UTXO do not throw', () async {
      await fx.projection.handle(_confirmed(7, 1));
      await fx.projection.handle(_reserved(7));
      await fx.projection.handle(UTXOReleasedEvent(
        walletId: _walletId, txid: _txid, vout: 7, version: 50, timestamp: DateTime.utc(2026, 1, 4)));
      await fx.projection.handle(UTXOMarkedAvailableEvent(
        walletId: _walletId, txid: _txid, vout: 7, version: 51, timestamp: DateTime.utc(2026, 1, 4)));
      expect(await fx.storage.getUTXOs(_walletId, includeSpent: true), isEmpty,
          reason: 'none of these events carries enough data to rebuild the UTXO row');
    });

    test('UTXOReceived for a wallet with no wallet row still stores the UTXO and the address', () async {
      await fx.storage.deleteWallet(_walletId);
      await fx.projection.handle(_receivedAt(address, 0, 50000));
      final utxos = await fx.storage.getUTXOs(_walletId, includeSpent: true);
      expect(utxos.single.satoshis, equals(BigInt.from(50000)));
      final meta = await fx.storage.getAddressMetadata(_walletId, address);
      expect(meta!.balance, equals(BigInt.from(50000)));
    });

    test('replaying the same UTXOReceived + UTXOSpent sequence yields the read model of one pass', () async {
      final sequence = <Event>[
        _receivedAt(address, 0, 50000),
        _receivedAt(address, 1, 30000),
        _spent(0),
      ];
      for (final e in sequence) {
        await fx.projection.handle(e);
      }
      final once = await _snapshot(fx.storage, address);
      expect(once['addressBalance'], equals('30000'));
      expect(once['addressUsageCount'], equals(2));

      for (final e in sequence) {
        await fx.projection.handle(e);
      }
      expect(await _snapshot(fx.storage, address), equals(once));
    });

    test('replaying from wallet creation (address generation included) is idempotent', () async {
      final sequence = <Event>[
        _created(network: 'mainnet', rootAddress: '1BitcoinEaterAddressDontSendf59kuE'),
        AddressGeneratedEvent(
          walletId: _walletId,
          address: address,
          derivationIndex: 1,
          version: 2,
          timestamp: DateTime.utc(2026, 1, 1, 12),
        ),
        _receivedAt(address, 0, 50000),
        _receivedAt(address, 1, 30000),
        _reserved(1),
        _confirmed(1, 3),
        _spent(0),
      ];
      for (final e in sequence) {
        await fx.projection.handle(e);
      }
      final once = await _snapshot(fx.storage, address);
      expect(once['addressBalance'], equals('30000'));
      expect(once['addressUsageCount'], equals(2));

      for (final e in sequence) {
        await fx.projection.handle(e);
      }
      expect(await _snapshot(fx.storage, address), equals(once));
    });
  });

  /// Audit 2026-09-14 M1: a confirmation update forced every UTXO with
  /// confirmations > 0 to `available`, resurrecting spent and reserved coins
  /// in the read model (and in the available balance).
  group('WalletProjection confirmation updates keep the UTXO status (audit M1)', () {
    final fx = _IsarFixture();
    final address = _addressFor(dartsv.NetworkType.MAIN);

    setUp(fx.open);
    tearDown(fx.close);

    Future<BitcoinUtxo> utxo(int vout) async =>
        (await fx.storage.getUTXOs(_walletId, includeSpent: true)).singleWhere((u) => u.vout == vout);

    test('a reserved UTXO stays reserved', () async {
      await fx.projection.handle(_receivedAt(address, 0, 50000));
      await fx.projection.handle(_reserved(0));
      await fx.projection.handle(_confirmed(0, 1));
      final u = await utxo(0);
      expect(u.status, equals(UTXOStatus.reserved));
      expect(u.confirmations, equals(1));
      // Bead libspiffy-pq8p: the height the event reported reaches no row.
      expect(u.blockHeight, isNull);
    });

    test('a spent UTXO stays spent and out of the balance', () async {
      await fx.projection.handle(_receivedAt(address, 0, 50000));
      await fx.projection.handle(_spent(0));
      await fx.projection.handle(_confirmed(0, 1));
      final u = await utxo(0);
      expect(u.status, equals(UTXOStatus.spent));
      expect(u.confirmations, equals(1));
      final wallet = await fx.storage.getWallet(_walletId);
      expect((wallet!['metadata'] as Map)['totalBalance'], equals('0'));
    });

    // Bead libspiffy-8oaq, read-model side: the count and the height in this
    // event come straight from a caller and were verified against nothing, so
    // the row records the count and keeps its status. The read model must
    // agree with the aggregate, or the wallet would show as spendable an
    // output the aggregate refuses to select.
    //
    // Bead libspiffy-pq8p: the height is not recorded either. It used to be,
    // and since `blockHeight != null` is what "confirmed" means at every
    // layer (libspiffy-jc3h), that made an unproven claim report as
    // confirmed balance.
    test('a pending UTXO stays pending: a reported count is not evidence', () async {
      await fx.projection.handle(_receivedAt(address, 0, 50000));
      expect((await utxo(0)).status, equals(UTXOStatus.pending));
      await fx.projection.handle(_confirmed(0, 1));
      final u = await utxo(0);
      expect(u.status, equals(UTXOStatus.pending));
      expect(u.confirmations, equals(1), reason: 'the claim is still recorded');
      expect(u.blockHeight, isNull, reason: 'the claimed height is not');
      expect(u.isConfirmed, isFalse);
      final wallet = await fx.storage.getWallet(_walletId);
      expect((wallet!['metadata'] as Map)['confirmedBalance'], equals('0'));
      expect((wallet['metadata'] as Map)['unconfirmedBalance'], equals('50000'));
    });

    test('UTXOMarkedAvailableEvent is what makes a pending UTXO available', () async {
      await fx.projection.handle(_receivedAt(address, 0, 50000));
      await fx.projection.handle(_confirmed(0, 1));
      await fx.projection.handle(UTXOMarkedAvailableEvent(
        walletId: _walletId, txid: _txid, vout: 0, version: 60, timestamp: DateTime.utc(2026, 1, 5)));
      expect((await utxo(0)).status, equals(UTXOStatus.available));
    });

    test('an event with no block height does not stamp the row with the genesis block', () async {
      await fx.projection.handle(_receivedAt(address, 0, 50000));
      await fx.projection.handle(UTXOConfirmationUpdatedEvent(
        walletId: _walletId, txid: _txid, vout: 0, confirmations: 1,
        version: 61, timestamp: DateTime.utc(2026, 1, 5)));
      final u = await utxo(0);
      expect(u.blockHeight, isNull, reason: 'no height given is not height 0');
      expect(u.isConfirmed, isFalse);
    });
  });

  /// Audit 2026-09-14 M4, read-model side: the aggregate now restores the
  /// status a UTXO had before it was reserved and records it on
  /// UTXOReleasedEvent.restoredStatus. The read model does not persist the
  /// pre-reservation status, so the projection must take it from the event;
  /// releasing a reserved pending UTXO showed it as available.
  group('WalletProjection release restores the pre-reservation status (audit M4)', () {
    final fx = _IsarFixture();
    final address = _addressFor(dartsv.NetworkType.MAIN);

    setUp(fx.open);
    tearDown(fx.close);

    Future<BitcoinUtxo> utxo(int vout) async =>
        (await fx.storage.getUTXOs(_walletId, includeSpent: true)).singleWhere((u) => u.vout == vout);

    UTXOReleasedEvent released(int vout, UTXOStatus? restored) => UTXOReleasedEvent(
          walletId: _walletId,
          txid: _txid,
          vout: vout,
          releaseReason: 'test',
          restoredStatus: restored,
          version: 50 + vout,
          timestamp: DateTime.utc(2026, 1, 3, 18, vout),
        );

    test('a reserved pending UTXO is pending again after release', () async {
      await fx.projection.handle(_receivedAt(address, 0, 50000));
      await fx.projection.handle(_reserved(0));
      expect((await utxo(0)).status, equals(UTXOStatus.reserved));
      await fx.projection.handle(released(0, UTXOStatus.pending));
      expect((await utxo(0)).status, equals(UTXOStatus.pending));
    });

    test('a release event journaled before restoredStatus existed releases to available', () async {
      await fx.projection.handle(_receivedAt(address, 0, 50000));
      await fx.projection.handle(_reserved(0));
      await fx.projection.handle(released(0, null));
      expect((await utxo(0)).status, equals(UTXOStatus.available));
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
