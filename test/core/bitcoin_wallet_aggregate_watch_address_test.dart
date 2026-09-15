/// Bead libspiffy-p4kv: the wallet aggregate journals its watch addresses.
///
/// A watch address is an address the wallet holds no key for whose payments
/// it attributes to itself. It used to exist only as a read-model row, so
/// the aggregate (which answers attribution since bead 29t) could not know
/// it and a read model rebuilt from the journal lost it.
library;

import 'package:eventador/eventador.dart';
import 'package:test/test.dart';

import 'package:libspiffy/src/core/bitcoin_wallet_aggregate.dart';
import 'package:libspiffy/src/core/wallet_commands.dart';
import 'package:libspiffy/src/core/wallet_events.dart';
import 'package:libspiffy/src/models/wallet_state.dart';
import 'package:libspiffy/src/models/wallet_type.dart';
import 'package:libspiffy/src/services/dartsv_crypto_service.dart';
import 'package:libspiffy/src/storage/in_memory_secure_storage.dart';

const _w = 'watch-wallet';
const _root = 'mrootaddress0000000000000000000000';
const _watch = 'mo6CPsdW8EsnWdmSSCrQ6225VVDtpMBTug';
const _other = 'mkHS9ne12qx9pS9VojpwU5xtRd4T7X7ZUt';

class _NoStore implements EventStore {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('${invocation.memberName}');
}

/// A live aggregate: commands are handled against its state and their events
/// applied and kept as the journal.
class _Wallet {
  final BitcoinWalletAggregate aggregate = BitcoinWalletAggregate(
    aggregateId: _w,
    aggregateType: 'BitcoinWallet',
    eventStore: _NoStore(),
    cryptoService: DartSVCryptoService(),
    secureStorage: InMemorySecureStorage(),
  );
  final List<Event> journal = [];

  _Wallet({bool created = true}) {
    if (created) {
      apply([
        WalletCreatedEvent(
          walletId: _w,
          walletName: 'w',
          rootAddress: _root,
          walletType: WalletType.hd,
          walletMetadata: {'network': 'testnet'},
          version: 1,
          timestamp: DateTime.utc(2026),
        ),
      ]);
    }
  }

  WalletState get state => aggregate.currentState;

  void apply(List<Event> events) {
    for (final e in events) {
      aggregate.eventHandler(e);
      journal.add(e);
    }
  }

  Future<List<Event>> handle(WalletCommand command) async {
    final state = aggregate.isInitialized ? aggregate.currentState : aggregate.createInitialState();
    final events = await aggregate.handleCommand(state, command);
    apply(events);
    return events;
  }
}

void main() {
  group('AddWatchAddressCommand', () {
    test('journals the watch address; the state holds it apart from the derived addresses', () async {
      final wallet = _Wallet();
      final events = await wallet.handle(
          AddWatchAddressCommand(walletId: _w, address: _watch, scriptType: 'p2pkh', label: 'cold'));

      final added = events.single as WatchAddressAddedEvent;
      expect((added.address, added.scriptType, added.label, added.reconciled), (_watch, 'p2pkh', 'cold', false));
      expect(added.version, 2);
      expect(wallet.state.watchAddresses, {_watch: 'p2pkh'});
      expect(wallet.state.addresses.containsKey(_watch), isFalse,
          reason: 'signing derives keys for state.addresses; the wallet has no key for a watch address');
    });

    test('is idempotent, and an address the wallet derived journals nothing', () async {
      final wallet = _Wallet();
      await wallet.handle(AddWatchAddressCommand(walletId: _w, address: _watch, scriptType: 'p2pkh'));
      expect(await wallet.handle(AddWatchAddressCommand(walletId: _w, address: _watch, scriptType: 'p2pkh', label: 'x')),
          isEmpty);
      expect(await wallet.handle(AddWatchAddressCommand(walletId: _w, address: _root, scriptType: 'p2pkh')), isEmpty);
      expect(wallet.journal.whereType<WatchAddressAddedEvent>(), hasLength(1));
      expect(wallet.state.watchAddresses.keys, [_watch]);
    });

    test('is refused for a wallet that does not exist or was deleted, and for an empty address', () async {
      final refused = isA<StateError>().having((e) => e.message, 'message', contains('non-existent wallet'));
      expect(() => _Wallet(created: false).handle(AddWatchAddressCommand(walletId: _w, address: _watch, scriptType: 'p2pkh')),
          throwsA(refused));
      final deleted = _Wallet()..apply([WalletDeletedEvent(walletId: _w, version: 2, timestamp: DateTime.utc(2026))]);
      expect(() => deleted.handle(AddWatchAddressCommand(walletId: _w, address: _watch, scriptType: 'p2pkh')),
          throwsA(refused));
      expect(() => _Wallet().handle(AddWatchAddressCommand(walletId: _w, address: ' ', scriptType: 'p2pkh')),
          throwsA(isA<ArgumentError>()));
    });

    test('a replay of the journal restores the watch addresses', () async {
      final wallet = _Wallet();
      await wallet.handle(AddWatchAddressCommand(walletId: _w, address: _watch, scriptType: 'p2pkh'));
      await wallet.handle(AddWatchAddressCommand(walletId: _w, address: _other, scriptType: 'p2pk'));

      final replayed = _Wallet(created: false)..apply(wallet.journal);
      expect(replayed.state.watchAddresses, {_watch: 'p2pkh', _other: 'p2pk'});
      expect(replayed.state.version, wallet.state.version);
    });

    test('the event round-trips through its map', () async {
      final wallet = _Wallet();
      final added = (await wallet.handle(
          AddWatchAddressCommand(walletId: _w, address: _watch, scriptType: 'p2pkh', label: 'cold')))
          .single as WatchAddressAddedEvent;
      final restored = WatchAddressAddedEvent.fromMap(added.toMap());
      expect(restored.toMap(), added.toMap());
      expect(restored.registeredAt, added.registeredAt);
    });
  });

  group('ReconcileWatchAddressesCommand', () {
    LegacyWatchAddress legacy(String address, {String? label}) => LegacyWatchAddress(
        address: address, scriptType: 'p2pkh', label: label, registeredAt: DateTime.utc(2025, 6, 1));

    test('journals the read model\'s watch addresses the wallet lacks, once', () async {
      final wallet = _Wallet();
      await wallet.handle(AddWatchAddressCommand(walletId: _w, address: _other, scriptType: 'p2pkh'));

      final events = await wallet.handle(ReconcileWatchAddressesCommand(walletId: _w, addresses: [
        legacy(_watch, label: 'old'),
        legacy(_watch), // listed twice
        legacy(_other), // already journaled
        legacy(_root), // derived by the wallet
      ]));

      final added = events.cast<WatchAddressAddedEvent>().single;
      expect((added.address, added.label, added.reconciled, added.registeredAt),
          (_watch, 'old', true, DateTime.utc(2025, 6, 1)));
      expect(added.version, wallet.journal.length);
      expect(wallet.state.watchAddresses.keys.toSet(), {_watch, _other});
      expect(await wallet.handle(ReconcileWatchAddressesCommand(walletId: _w, addresses: [legacy(_watch)])), isEmpty,
          reason: 'sending it again journals nothing');
    });

    test('journals nothing for a wallet that does not exist or was deleted', () async {
      expect(await _Wallet(created: false).handle(ReconcileWatchAddressesCommand(walletId: _w, addresses: [legacy(_watch)])),
          isEmpty);
      final deleted = _Wallet()..apply([WalletDeletedEvent(walletId: _w, version: 2, timestamp: DateTime.utc(2026))]);
      expect(await deleted.handle(ReconcileWatchAddressesCommand(walletId: _w, addresses: [legacy(_watch)])), isEmpty);
    });
  });

  test('WalletState.fromMap reads a snapshot written before watch addresses existed', () {
    final map = WalletState.initial(walletId: _w, name: 'w', rootAddress: _root, networkType: 'testnet').toMap()
      ..remove('watchAddresses');
    expect(WalletState.fromMap(map).watchAddresses, isEmpty);
  });
}
