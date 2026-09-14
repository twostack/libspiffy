import 'package:test/test.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:eventador/eventador.dart';

import 'package:libspiffy/src/core/bitcoin_wallet_aggregate.dart';
import 'package:libspiffy/src/core/wallet_commands.dart';
import 'package:libspiffy/src/core/wallet_events.dart';
import 'package:libspiffy/src/models/wallet_event.dart';
import 'package:libspiffy/src/services/dartsv_crypto_service.dart';
import 'package:libspiffy/src/storage/in_memory_secure_storage.dart';
import 'package:libspiffy/src/storage/secure_storage.dart';

import '../actors/in_memory_event_store.dart';

/// Audit 2026-09-14 H4 (libspiffy-3u7): key material was written to secure
/// storage only after the WalletCreatedEvent had been persisted (and after
/// the success reply was sent). A failing secure-storage write therefore
/// left a wallet whose events exist but that can never sign, and a retried
/// CreateWalletCommand was dropped as a duplicate.
///
/// The fix writes the secrets first; the event is persisted only once they
/// are safely stored, and they are removed again if persistence fails.
void main() {
  const mnemonic =
      'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';

  late DartSVCryptoService cryptoService;

  setUp(() {
    cryptoService = DartSVCryptoService();
  });

  BitcoinWalletAggregate aggregate(String walletId, EventStore store, SecureStorage storage) {
    return BitcoinWalletAggregate(
      aggregateId: walletId,
      aggregateType: 'Wallet',
      eventStore: store,
      cryptoService: cryptoService,
      secureStorage: storage,
    );
  }

  Future<String> testnetWif() async =>
      dartsv.SVPrivateKey(networkType: dartsv.NetworkType.TEST).toWIF();

  Future<String> testnetXpriv() async {
    final hd = await cryptoService.mnemonicToHDPrivateKey(mnemonic,
        network: dartsv.NetworkType.TEST);
    return hd.xprivkey;
  }

  group('H4: key material ordering', () {
    for (final variant in ['mnemonic', 'wif', 'xpriv']) {
      test('$variant: a failing secure-storage write fails the command and persists no event',
          () async {
        final store = InMemoryEventStore();
        final storage = _ThrowingSecureStorage();
        const walletId = 'wallet-h4-throw';
        final wallet = aggregate(walletId, store, storage);
        await wallet.preStart();

        final command = CreateWalletCommand(
          walletId: walletId,
          walletName: 'Keyless wallet',
          mnemonic: variant == 'mnemonic' ? mnemonic : null,
          wif: variant == 'wif' ? await testnetWif() : null,
          xpriv: variant == 'xpriv' ? await testnetXpriv() : null,
        );

        await expectLater(
          wallet.commandHandler(command),
          throwsA(isA<SecureStorageException>()),
        );

        expect(store.allEvents.whereType<WalletCreatedEvent>(), isEmpty,
            reason: 'no WalletCreatedEvent may be journaled when the keys were not stored');
        expect(wallet.currentState.isCreated, isFalse);
        expect(await storage.getAll(), isEmpty);
      });
    }

    test('secrets are in secure storage before the WalletCreatedEvent is persisted', () async {
      final log = <String>[];
      final storage = _RecordingSecureStorage(log);
      final store = _RecordingEventStore(log, storage);
      const walletId = 'wallet-h4-order';
      final wallet = aggregate(walletId, store, storage);
      await wallet.preStart();

      await wallet.commandHandler(CreateWalletCommand(
        walletId: walletId,
        walletName: 'Ordered wallet',
        mnemonic: mnemonic,
        passphrase: 'pass',
      ));

      final persistAt = log.indexWhere((e) => e.startsWith('persist:'));
      expect(persistAt, greaterThanOrEqualTo(0));
      final secretWrites = log.where((e) => e.startsWith('set:')).toList();
      expect(secretWrites, isNotEmpty);
      for (final write in secretWrites) {
        expect(log.indexOf(write), lessThan(persistAt),
            reason: '$write must precede event persistence; log=$log');
      }
      expect(store.mnemonicPresentAtPersist, isTrue,
          reason: 'the mnemonic must be readable when the event is persisted');
      expect(store.passphrasePresentAtPersist, isTrue);
      expect(store.allEvents.whereType<WalletCreatedEvent>().length, equals(1));
      expect(wallet.currentState.isCreated, isTrue);
    });

    test('secrets are removed again when event persistence fails', () async {
      final storage = InMemorySecureStorage();
      final store = _FailingEventStore();
      const walletId = 'wallet-h4-persist-fail';
      final wallet = aggregate(walletId, store, storage);
      await wallet.preStart();

      await expectLater(
        wallet.commandHandler(CreateWalletCommand(
          walletId: walletId,
          walletName: 'Unpersistable wallet',
          mnemonic: mnemonic,
          passphrase: 'pass',
        )),
        throwsA(isA<StateError>()),
      );

      expect(await storage.getAll(), isEmpty,
          reason: 'compensation must remove every secret written for the wallet');
      expect(wallet.currentState.isCreated, isFalse);
    });

    test('a wallet whose creation succeeded can sign immediately', () async {
      final store = InMemoryEventStore();
      final storage = InMemorySecureStorage();
      const walletId = 'wallet-h4-ok';
      final wallet = aggregate(walletId, store, storage);
      await wallet.preStart();
      await wallet.commandHandler(CreateWalletCommand(
        walletId: walletId,
        walletName: 'Good wallet',
        mnemonic: mnemonic,
      ));
      expect(await storage.getMnemonic(walletId), equals(mnemonic));
      expect(await storage.getString('wallet_hdpubkey_$walletId'), isNotNull);
      await wallet.commandHandler(GenerateAddressCommand(walletId: walletId, label: 'a'));
      expect(wallet.currentState.addresses.length, equals(2));
    });
  });
}

/// Secure storage whose writes always fail.
class _ThrowingSecureStorage extends InMemorySecureStorage {
  @override
  Future<void> setString(String key, String value) async {
    throw SecureStorageException('disk full: $key');
  }
}

/// Secure storage that appends `set:<key>` to a shared log on every write.
class _RecordingSecureStorage extends InMemorySecureStorage {
  final List<String> log;
  _RecordingSecureStorage(this.log);

  @override
  Future<void> setString(String key, String value) async {
    log.add('set:$key');
    await super.setString(key, value);
  }
}

/// Event store that appends `persist:<n>` to the shared log and snapshots
/// whether the wallet's secrets were readable at that moment.
class _RecordingEventStore extends InMemoryEventStore {
  final List<String> log;
  final SecureStorage storage;
  bool mnemonicPresentAtPersist = false;
  bool passphrasePresentAtPersist = false;
  _RecordingEventStore(this.log, this.storage);

  @override
  Future<void> persistEvents(
      String persistenceId, List<Event> events, int expectedVersion) async {
    log.add('persist:${events.length}');
    final walletId = (events.first as WalletEvent).walletId;
    mnemonicPresentAtPersist = await storage.getMnemonic(walletId) != null;
    passphrasePresentAtPersist =
        await storage.getString('wallet_passphrase_$walletId') != null;
    await super.persistEvents(persistenceId, events, expectedVersion);
  }

  @override
  Future<void> persistEvent(
      String persistenceId, Event event, int expectedVersion) async {
    return persistEvents(persistenceId, [event], expectedVersion);
  }
}

/// Event store whose writes always fail.
class _FailingEventStore extends InMemoryEventStore {
  @override
  Future<void> persistEvents(
      String persistenceId, List<Event> events, int expectedVersion) async {
    throw StateError('journal unavailable');
  }

  @override
  Future<void> persistEvent(
      String persistenceId, Event event, int expectedVersion) async {
    throw StateError('journal unavailable');
  }
}
