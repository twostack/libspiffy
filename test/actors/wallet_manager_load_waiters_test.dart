/// WalletManagerActor: requests that arrive for a wallet whose aggregate is
/// not loaded (bead libspiffy-a5l).
///
/// Every request that needs the aggregate (routed commands, ownership
/// queries, invoice creation, SPV results, preloads) goes through one
/// load-or-wait path. These are characterization tests: they pin what callers
/// see when several such requests arrive together, when the wallet has no
/// journal, and when the journal cannot be read. They pass before and after
/// the polling wait was replaced by a shared load future.
library;

import 'dart:async';

import 'package:dactor/dactor.dart';
import 'package:dactor_test/dactor_test.dart';
import 'package:eventador/eventador.dart';
import 'package:test/test.dart';

import 'package:libspiffy/src/actors/invoice_coordinator_actor.dart';
import 'package:libspiffy/src/actors/internal_messages.dart';
import 'package:libspiffy/src/actors/invoice_messages.dart';
import 'package:libspiffy/src/actors/wallet_manager_actor.dart';
import 'package:libspiffy/src/actors/wallet_messages.dart';
import 'package:libspiffy/src/core/wallet_commands.dart';
import 'package:libspiffy/src/services/dartsv_crypto_service.dart';
import 'package:libspiffy/src/storage/in_memory_secure_storage.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';

import 'in_memory_event_store.dart';

const _mnemonic = 'abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon abandon abandon about';
const _ask = Duration(seconds: 10);

/// Counts journal replays per persistence id (one per aggregate recovery,
/// so one per wallet load) and can be told to fail journal reads.
class _CountingEventStore extends InMemoryEventStore {
  final Map<String, int> replays = {};
  bool failReads = false;

  @override
  Future<List<Event>> getEvents(String persistenceId,
      {int fromSequence = 0, int? toSequence}) {
    replays[persistenceId] = (replays[persistenceId] ?? 0) + 1;
    return super.getEvents(persistenceId,
        fromSequence: fromSequence, toSequence: toSequence);
  }

  @override
  Future<int> getHighestSequenceNumber(String persistenceId) async {
    if (failReads) throw StateError('journal unavailable');
    return super.getHighestSequenceNumber(persistenceId);
  }
}

/// The manager's reply for a wallet it has no journal for.
void _expectNotFound(dynamic reply, String walletId) {
  expect(reply, isA<WalletManagerFailure>(), reason: 'got $reply');
  expect((reply as WalletManagerFailure).error, 'Wallet not found');
  expect(reply.walletId, walletId);
  expect(reply.success, isFalse);
}

void main() {
  late _CountingEventStore eventStore;
  late InMemorySecureStorage secureStorage;
  late TestActorSystem actorSystem;
  late ActorRef walletManager;

  /// Journals wallet [walletId] in a separate actor system that is then shut
  /// down, so the manager under test starts with the wallet unloaded.
  Future<void> journalWallet(String walletId) async {
    final creator = TestActorSystem();
    try {
      final manager = await creator.spawn(
        'wallet-manager',
        () => WalletManagerActor(
          eventStore: eventStore,
          cryptoService: DartSVCryptoService(),
          secureStorage: secureStorage,
        ),
      );
      final created = await manager.ask<WalletCreatedMessage>(
        CreateWalletMessage(walletId, 'Wallet $walletId', mnemonic: _mnemonic),
        _ask,
      );
      expect(created.success, isTrue, reason: created.error);
    } finally {
      await creator.shutdown();
    }
  }

  setUp(() async {
    eventStore = _CountingEventStore();
    secureStorage = InMemorySecureStorage();
    await journalWallet('w1');
    eventStore.replays.clear();

    actorSystem = TestActorSystem();
    walletManager = await actorSystem.spawn(
      'wallet-manager',
      () => WalletManagerActor(
        eventStore: eventStore,
        cryptoService: DartSVCryptoService(),
        secureStorage: secureStorage,
      ),
    );
  });

  tearDown(() async {
    await actorSystem.shutdown();
  });

  Future<AddressGeneratedResponse> generateAddress(String walletId) =>
      walletManager.ask<AddressGeneratedResponse>(
        WalletCommandMessage(
          walletId,
          GenerateAddressCommand(walletId: walletId, purpose: 'receive'),
        ),
        _ask,
      );

  Future<WalletOwnershipResponse> ownership(String walletId) =>
      walletManager.ask<WalletOwnershipResponse>(
        WalletOwnershipQuery(
            walletId: walletId, addresses: const {}, outpoints: const {}),
        _ask,
      );

  test('two concurrent commands for an unloaded wallet both succeed and the '
      'wallet is loaded once', () async {
    expect(actorSystem.getActor('wallet-w1'), isNull);

    final replies =
        await Future.wait([generateAddress('w1'), generateAddress('w1')]);

    for (final reply in replies) {
      expect(reply.success, isTrue, reason: reply.error);
      expect(reply.address, isNotEmpty);
    }
    expect(replies[0].address, isNot(replies[1].address));
    expect(eventStore.replays['BitcoinWallet_w1'], 1,
        reason: 'the aggregate is recovered (loaded) once');
    expect(actorSystem.getActor('wallet-w1'), isNotNull);
  });

  test('a preload, a command and an ownership query arriving together are '
      'all answered from one load', () async {
    walletManager.tell(
        WalletCommandMessage('w1', PreloadWalletCommand(walletId: 'w1')));
    final results = await Future.wait<dynamic>([
      generateAddress('w1'),
      ownership('w1'),
      generateAddress('w1'),
    ]);

    expect((results[0] as AddressGeneratedResponse).success, isTrue);
    expect((results[1] as WalletOwnershipResponse).walletFound, isTrue);
    expect((results[2] as AddressGeneratedResponse).success, isTrue);
    expect(eventStore.replays['BitcoinWallet_w1'], 1);
  });

  test('concurrent requests for a wallet with no journal are all answered '
      '"not found"', () async {
    final results = await Future.wait<dynamic>([
      walletManager.ask<dynamic>(
        WalletCommandMessage('ghost', GenerateAddressCommand(walletId: 'ghost')),
        _ask,
      ),
      ownership('ghost'),
      walletManager.ask<dynamic>(
        WalletCommandMessage('ghost', GenerateAddressCommand(walletId: 'ghost')),
        _ask,
      ),
    ]);

    _expectNotFound(results[0], 'ghost');
    final query = results[1] as WalletOwnershipResponse;
    expect(query.walletFound, isFalse);
    expect(query.error, 'Wallet ghost not found');
    _expectNotFound(results[2], 'ghost');
    expect(actorSystem.getActor('wallet-ghost'), isNull);
  });

  test('when the journal cannot be read, every waiting request is answered '
      'and a later request retries the load', () async {
    eventStore.failReads = true;
    final results = await Future.wait<dynamic>([
      walletManager.ask<dynamic>(
        WalletCommandMessage('w1', GenerateAddressCommand(walletId: 'w1')),
        _ask,
      ),
      ownership('w1'),
      walletManager.ask<dynamic>(
        WalletCommandMessage('w1', GenerateAddressCommand(walletId: 'w1')),
        _ask,
      ),
    ]);

    // A load that throws is reported like a wallet with no journal.
    _expectNotFound(results[0], 'w1');
    expect((results[1] as WalletOwnershipResponse).walletFound, isFalse);
    _expectNotFound(results[2], 'w1');

    // Nothing is left marked as loading: the next request loads the wallet.
    eventStore.failReads = false;
    final reply = await generateAddress('w1');
    expect(reply.success, isTrue, reason: reply.error);
  });

  test('invoices requested together for an unloaded wallet are created once '
      'their addresses arrive', () async {
    final invoiceCoordinator = await actorSystem.spawn(
      'invoice-coordinator',
      () => InvoiceCoordinatorActor(
        walletManager: walletManager,
        storage: InMemoryWalletStorage(),
        eventStore: eventStore,
      ),
    );
    walletManager.tell(SetInvoiceManagerMessage(invoiceCoordinator));

    Future<InvoiceCreatedMessage> createInvoice(int sats) =>
        walletManager.ask<InvoiceCreatedMessage>(
          CreateInvoiceMessage(walletId: 'w1', amount: BigInt.from(sats)),
          _ask,
        );

    final invoices = await Future.wait([createInvoice(1000), createInvoice(2000)]);

    for (final invoice in invoices) {
      expect(invoice.success, isTrue, reason: invoice.error);
      expect(invoice.walletId, 'w1');
      expect(invoice.addresses, hasLength(1));
      expect(invoice.addresses.single, isNotEmpty);
    }
    expect(invoices[0].amount, BigInt.from(1000));
    expect(invoices[1].amount, BigInt.from(2000));
    expect(invoices[0].addresses.single, isNot(invoices[1].addresses.single));
    expect(eventStore.replays['BitcoinWallet_w1'], 1);
  });
}
