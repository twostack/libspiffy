/// Bead libspiffy-p4kv: watch addresses registered before they were journaled
/// exist only as read-model rows (purpose `watch`). WalletManagerActor
/// journals them when it loads a wallet from the journal, so the wallet
/// answers ownership for them and a read model rebuilt from the journal keeps
/// them. The rows themselves are never removed.
library;

import 'package:dactor/dactor.dart';
import 'package:eventador/eventador.dart';
import 'package:libspiffy/src/actors/libspiffy_actor_system.dart';
import 'package:libspiffy/src/actors/wallet_manager_actor.dart';
import 'package:libspiffy/src/actors/wallet_messages.dart';
import 'package:libspiffy/src/core/wallet_events.dart';
import 'package:libspiffy/src/models/address_metadata.dart';
import 'package:libspiffy/src/projections/wallet_projection.dart';
import 'package:libspiffy/src/services/dartsv_crypto_service.dart';
import 'package:libspiffy/src/storage/in_memory_secure_storage.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';
import 'package:test/test.dart';
import 'package:libspiffy/src/models/address_chain.dart';

import 'in_memory_event_store.dart';

const _walletId = 'legacy-watcher';
const _mnemonic = 'legal winner thank year wave sausage worth useful legal winner thank yellow';
const _watch = 'mo6CPsdW8EsnWdmSSCrQ6225VVDtpMBTug';
const _watch2 = 'mkHS9ne12qx9pS9VojpwU5xtRd4T7X7ZUt';
final _registered = DateTime.utc(2025, 6, 1, 8, 30);

/// Read-model storage whose watch-address lookup fails [failures] times.
class _FlakyStorage extends InMemoryWalletStorage {
  int failures;
  int lookups = 0;
  _FlakyStorage(this.failures);

  @override
  Future<List<AddressMetadata>> getAddressesByPurpose(String walletId, String purpose) async {
    lookups++;
    if (failures > 0) {
      failures--;
      throw StateError('read model unavailable');
    }
    return super.getAddressesByPurpose(walletId, purpose);
  }
}

AddressMetadata _legacyRow(String address, {String? label}) => AddressMetadata(
      address: address,
      scriptType: 'p2pkh',
      chain: AddressChain.receive,
      purpose: 'watch',
      label: label,
      usageCount: 3,
      balance: BigInt.from(4200),
      createdAt: _registered,
      isWatched: true,
    );

void main() {
  setUpAll(LibSpiffyActorSystem.registerEventTypes);

  late InMemoryEventStore eventStore;
  final systems = <LocalActorSystem>[];

  setUp(() async {
    eventStore = InMemoryEventStore();
    // The wallet's journal, written by an earlier process.
    final earlier = LocalActorSystem(ActorSystemConfig());
    final manager = await earlier.spawn(
      'wallet-manager',
      () => WalletManagerActor(
        eventStore: eventStore,
        cryptoService: DartSVCryptoService(),
        secureStorage: InMemorySecureStorage(),
        aggregateIdleTimeout: null,
      ),
    );
    final created = await manager.ask<WalletCreatedMessage>(
      CreateWalletMessage(_walletId, _walletId, mnemonic: _mnemonic),
      const Duration(seconds: 10),
    );
    expect(created.success, isTrue, reason: created.error);
    await earlier.shutdown();
  });

  tearDown(() async {
    for (final s in systems) {
      await s.shutdown();
    }
    systems.clear();
  });

  List<Event> journal() => eventStore.journal['BitcoinWallet_$_walletId'] ?? const [];

  /// A process that loads the wallet from the journal with [readModel].
  Future<ActorRef> start(InMemoryWalletStorage readModel) async {
    final system = LocalActorSystem(ActorSystemConfig());
    systems.add(system);
    return system.spawn(
      'wallet-manager',
      () => WalletManagerActor(
        eventStore: eventStore,
        cryptoService: DartSVCryptoService(),
        secureStorage: InMemorySecureStorage(),
        aggregateIdleTimeout: null,
        readModelStorage: readModel,
      ),
    );
  }

  Future<Set<String>> owned(ActorRef manager, Set<String> addresses) async => (await manager.ask<WalletOwnershipResponse>(
        WalletOwnershipQuery(walletId: _walletId, addresses: addresses, outpoints: const {}),
        const Duration(seconds: 10),
      ))
          .ownedAddresses;

  test('legacy watch rows are journaled once on load; a rebuilt read model keeps them; the rows stay', () async {
    final readModel = InMemoryWalletStorage();
    await readModel.upsertAddress(_walletId, _legacyRow(_watch, label: 'cold'));
    await readModel.upsertAddress(_walletId, _legacyRow(_watch2));

    final manager = await start(readModel);
    expect(await owned(manager, {_watch, _watch2, 'mnotmine'}), {_watch, _watch2});
    final added = journal().whereType<WatchAddressAddedEvent>().toList();
    expect([for (final e in added) (e.address, e.label, e.reconciled, e.registeredAt)]..sort((a, b) => a.$1.compareTo(b.$1)),
        [(_watch2, null, true, _registered), (_watch, 'cold', true, _registered)]..sort((a, b) => a.$1.compareTo(b.$1)));

    // Another process loads the wallet again: nothing more is journaled.
    final length = journal().length;
    await systems.removeAt(0).shutdown();
    final again = await start(readModel);
    expect(await owned(again, {_watch, _watch2}), {_watch, _watch2});
    expect(journal(), hasLength(length));

    // The legacy rows were not touched.
    final row = await readModel.getAddressMetadata(_walletId, _watch);
    expect((row!.purpose, row.usageCount, row.balance, row.label), ('watch', 3, BigInt.from(4200), 'cold'));

    // A read model rebuilt from the journal has them, with their original
    // registration time and label.
    final rebuilt = InMemoryWalletStorage();
    final projection = WalletProjection(projectionId: 'rebuild', eventStore: eventStore, storage: rebuilt);
    for (final event in journal()) {
      await projection.handle(event);
    }
    final rebuiltRow = await rebuilt.getAddressMetadata(_walletId, _watch);
    expect((rebuiltRow?.purpose, rebuiltRow?.label, rebuiltRow?.scriptType), ('watch', 'cold', 'p2pkh'));
    expect(rebuiltRow!.createdAt.isAtSameMomentAs(_registered), isTrue);
    expect(await rebuilt.isWalletAddress(_walletId, _watch2), isTrue);
    expect((await rebuilt.getWallet(_walletId))?['metadata']?['addressCount'], 3,
        reason: 'the root address and the two watch addresses');

    // Applying the events over the original read model (the live projection
    // does) keeps the legacy rows' usage and balance.
    final replayed = WalletProjection(projectionId: 'replay', eventStore: eventStore, storage: readModel);
    for (final event in journal().whereType<WatchAddressAddedEvent>()) {
      await replayed.handle(event);
    }
    final kept = await readModel.getAddressMetadata(_walletId, _watch);
    expect((kept!.usageCount, kept.balance, kept.purpose), (3, BigInt.from(4200), 'watch'));
  });

  test('when the read model cannot be read at load, the next ownership query retries first', () async {
    final readModel = _FlakyStorage(1);
    await readModel.upsertAddress(_walletId, _legacyRow(_watch));

    final manager = await start(readModel);
    expect(await owned(manager, {_watch}), {_watch},
        reason: 'the load failed to read the rows; the query itself must not miss the watch address');
    expect(readModel.lookups, 2);
    expect(journal().whereType<WatchAddressAddedEvent>().single.address, _watch);

    expect(await owned(manager, {_watch}), {_watch});
    expect(readModel.lookups, 2, reason: 'no lookups once the reconciliation succeeded');
  });

  test('a wallet with no legacy watch rows journals nothing', () async {
    final length = journal().length;
    final manager = await start(InMemoryWalletStorage());
    expect(await owned(manager, {_watch}), isEmpty);
    expect(journal(), hasLength(length));
  });
}
