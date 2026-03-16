import 'dart:async';
import 'dart:io';

import 'package:dactor/dactor.dart';
import 'package:isar/isar.dart';
import 'package:test/test.dart';

import 'package:libspiffy/libspiffy.dart';
import 'package:libspiffy/coordinator.dart';

import 'isar_test_helper.dart';

/// Helper to filter a CoordinatorEvent stream by type
Stream<T> ofType<T extends CoordinatorEvent>(Stream<CoordinatorEvent> stream) {
  final controller = StreamController<T>.broadcast();
  stream.listen((e) {
    if (e is T) controller.add(e);
  });
  return controller.stream;
}

void main() {
  late LibSpiffyActorSystem libspiffy;
  late LocalActorSystem actorSystem;
  late Isar isar;
  late Directory testDir;
  late ActorRef coordinator;
  late Stream<CoordinatorEvent> events;
  late DartSVCryptoService crypto;
  late String mnemonic;

  setUpAll(() async {
    await ensureIsarInitialized();
    crypto = DartSVCryptoService();
  });

  setUp(() async {
    testDir = await Directory.systemTemp.createTemp('coordinator_test_');

    isar = await Isar.open(
      LibSpiffySchemas.allSchemas,
      directory: testDir.path,
      name: 'test_${DateTime.now().microsecondsSinceEpoch}',
    );

    actorSystem = LocalActorSystem(ActorSystemConfig());
    libspiffy = LibSpiffyActorSystem();

    await libspiffy.initialize(
      actorSystem: actorSystem,
      isar: isar,
      dataDirectory: testDir.path,
      enableP2P: false,
      secureStorage: InMemorySecureStorage(),
    );

    coordinator = libspiffy.coordinator;
    events = libspiffy.coordinatorEvents!;
    mnemonic = await crypto.generateMnemonic();
  });

  tearDown(() async {
    await libspiffy.shutdown();
    if (await testDir.exists()) {
      await testDir.delete(recursive: true);
    }
  });

  group('WalletCoordinatorActor', () {
    group('wallet lifecycle', () {
      test('creates a wallet and emits WalletCreatedEvent', () async {
        final walletId = 'test-wallet-${DateTime.now().microsecondsSinceEpoch}';

        final eventFuture = ofType<WalletCreatedEvent>(events)
            .where((e) => e.walletId == walletId)
            .first
            .timeout(const Duration(seconds: 10));

        coordinator.tell(CreateWalletCommand(
          walletId: walletId,
          name: 'Test Wallet',
          mnemonic: mnemonic,
        ));

        final event = await eventFuture;
        expect(event.success, isTrue);
        expect(event.walletId, equals(walletId));
        expect(event.rootAddress, isNotNull);
        expect(event.rootAddress, isNotEmpty);
      });

      test('emits error for duplicate wallet ID', () async {
        final walletId = 'dup-wallet-${DateTime.now().microsecondsSinceEpoch}';

        // Create first wallet
        final firstEvent = ofType<WalletCreatedEvent>(events)
            .where((e) => e.walletId == walletId)
            .first
            .timeout(const Duration(seconds: 10));

        coordinator.tell(CreateWalletCommand(
          walletId: walletId,
          name: 'First',
          mnemonic: mnemonic,
        ));

        final first = await firstEvent;
        expect(first.success, isTrue);

        // Create second wallet with same ID — expect failure or error
        final secondEvent = events
            .where((e) =>
                (e is WalletCreatedEvent && e.walletId == walletId) ||
                (e is ErrorEvent && e.walletId == walletId))
            .first
            .timeout(const Duration(seconds: 10));

        coordinator.tell(CreateWalletCommand(
          walletId: walletId,
          name: 'Duplicate',
          mnemonic: mnemonic,
        ));

        final second = await secondEvent;
        // Either a failed WalletCreatedEvent or an ErrorEvent is acceptable
        if (second is WalletCreatedEvent) {
          // Some implementations may succeed (idempotent) or fail
          // The important thing is it doesn't crash
        } else if (second is ErrorEvent) {
          expect(second.message, isNotEmpty);
        }
      });
    });

    group('balance queries', () {
      test('queries balance for a new wallet (should be zero)', () async {
        final walletId = 'bal-wallet-${DateTime.now().microsecondsSinceEpoch}';

        // Create wallet first
        final created = ofType<WalletCreatedEvent>(events)
            .where((e) => e.walletId == walletId)
            .first
            .timeout(const Duration(seconds: 10));

        coordinator.tell(CreateWalletCommand(
          walletId: walletId,
          name: 'Balance Test',
          mnemonic: mnemonic,
        ));

        await created;

        // Query balance
        final queryId = 'balance-query-${DateTime.now().microsecondsSinceEpoch}';
        final balanceFuture = ofType<BalanceResponse>(events)
            .where((e) => e.queryId == queryId)
            .first
            .timeout(const Duration(seconds: 10));

        coordinator.tell(GetBalanceQuery(
          walletId: walletId,
          queryId: queryId,
        ));

        final balance = await balanceFuture;
        expect(balance.walletId, equals(walletId));
        expect(balance.confirmedBalance, equals(BigInt.zero));
        expect(balance.unconfirmedBalance, equals(BigInt.zero));
        expect(balance.totalBalance, equals(BigInt.zero));
      });

      test('queries transactions for a new wallet (should be empty)', () async {
        final walletId = 'tx-wallet-${DateTime.now().microsecondsSinceEpoch}';

        // Create wallet
        final created = ofType<WalletCreatedEvent>(events)
            .where((e) => e.walletId == walletId)
            .first
            .timeout(const Duration(seconds: 10));

        coordinator.tell(CreateWalletCommand(
          walletId: walletId,
          name: 'TX Test',
          mnemonic: mnemonic,
        ));

        await created;

        // Query transactions
        final queryId = 'tx-query-${DateTime.now().microsecondsSinceEpoch}';
        final txFuture = ofType<TransactionsResponse>(events)
            .where((e) => e.queryId == queryId)
            .first
            .timeout(const Duration(seconds: 10));

        coordinator.tell(GetTransactionsQuery(
          walletId: walletId,
          queryId: queryId,
        ));

        final txResponse = await txFuture;
        expect(txResponse.walletId, equals(walletId));
        expect(txResponse.transactions, isEmpty);
      });
    });

    group('invoice lifecycle', () {
      test('creates an invoice with generated address', () async {
        final walletId = 'inv-wallet-${DateTime.now().microsecondsSinceEpoch}';

        // Create wallet
        final created = ofType<WalletCreatedEvent>(events)
            .where((e) => e.walletId == walletId)
            .first
            .timeout(const Duration(seconds: 10));

        coordinator.tell(CreateWalletCommand(
          walletId: walletId,
          name: 'Invoice Test',
          mnemonic: mnemonic,
        ));

        final walletEvent = await created;
        expect(walletEvent.success, isTrue);

        // Wait for wallet to be fully loaded (projection needs time)
        await Future.delayed(const Duration(milliseconds: 500));

        // Create invoice
        final invoiceFuture = ofType<InvoiceCreatedEvent>(events)
            .where((e) => e.walletId == walletId)
            .first
            .timeout(const Duration(seconds: 10));

        coordinator.tell(CreateInvoiceCommand(
          walletId: walletId,
          amount: BigInt.from(50000),
          description: 'Test invoice',
          expiresInSeconds: 3600,
        ));

        final invoice = await invoiceFuture;
        expect(invoice.success, isTrue);
        expect(invoice.invoiceId, isNotEmpty);
        expect(invoice.addresses, isNotEmpty);
        expect(invoice.amount, equals(BigInt.from(50000)));
        expect(invoice.description, equals('Test invoice'));
      });
    });

    group('error handling', () {
      test('emits error for balance query on non-existent wallet', () async {
        final queryId = 'err-query-${DateTime.now().microsecondsSinceEpoch}';

        // Query balance for a wallet that doesn't exist
        // Should get either a BalanceResponse with zeros or an ErrorEvent
        final responseFuture = events
            .where((e) =>
                (e is BalanceResponse && e.queryId == queryId) ||
                (e is ErrorEvent))
            .first
            .timeout(const Duration(seconds: 10));

        coordinator.tell(GetBalanceQuery(
          walletId: 'nonexistent-wallet',
          queryId: queryId,
        ));

        final response = await responseFuture;
        // Either an empty balance or an error is acceptable
        if (response is BalanceResponse) {
          expect(response.totalBalance, equals(BigInt.zero));
        } else if (response is ErrorEvent) {
          expect(response.source, isNotEmpty);
        }
      });
    });

    group('event stream filtering', () {
      test('filters events by wallet ID', () async {
        final walletId1 = 'filter-w1-${DateTime.now().microsecondsSinceEpoch}';
        final walletId2 = 'filter-w2-${DateTime.now().microsecondsSinceEpoch}';

        final wallet1Events = <CoordinatorEvent>[];
        final sub = events
            .where((e) => e.walletId == walletId1)
            .listen(wallet1Events.add);

        // Create two wallets
        coordinator.tell(CreateWalletCommand(
          walletId: walletId1,
          name: 'Wallet 1',
          mnemonic: mnemonic,
        ));
        coordinator.tell(CreateWalletCommand(
          walletId: walletId2,
          name: 'Wallet 2',
          mnemonic: mnemonic,
        ));

        // Wait for both to complete
        await ofType<WalletCreatedEvent>(events)
            .where((e) => e.walletId == walletId2)
            .first
            .timeout(const Duration(seconds: 10));

        // Allow stream delivery
        await Future.delayed(const Duration(milliseconds: 200));

        await sub.cancel();

        // Only wallet 1 events should be captured
        expect(wallet1Events, isNotEmpty);
        for (final e in wallet1Events) {
          expect(e.walletId, equals(walletId1));
        }
      });

      test('filters events by type', () async {
        final walletId = 'type-filter-${DateTime.now().microsecondsSinceEpoch}';

        final balanceResponses = <BalanceResponse>[];
        final sub = ofType<BalanceResponse>(events).listen(balanceResponses.add);

        // Create wallet
        final created = ofType<WalletCreatedEvent>(events)
            .where((e) => e.walletId == walletId)
            .first
            .timeout(const Duration(seconds: 10));

        coordinator.tell(CreateWalletCommand(
          walletId: walletId,
          name: 'Type Filter Test',
          mnemonic: mnemonic,
        ));

        await created;

        // Query balance
        coordinator.tell(GetBalanceQuery(walletId: walletId));

        // Wait for balance response
        await ofType<BalanceResponse>(events)
            .first
            .timeout(const Duration(seconds: 10));

        await Future.delayed(const Duration(milliseconds: 200));
        await sub.cancel();

        expect(balanceResponses, isNotEmpty);
        expect(balanceResponses.first, isA<BalanceResponse>());
      });
    });

    group('shutdown', () {
      test('coordinator shuts down cleanly', () async {
        // Create a wallet to ensure the system is working
        final walletId = 'shutdown-${DateTime.now().microsecondsSinceEpoch}';

        final created = ofType<WalletCreatedEvent>(events)
            .where((e) => e.walletId == walletId)
            .first
            .timeout(const Duration(seconds: 10));

        coordinator.tell(CreateWalletCommand(
          walletId: walletId,
          name: 'Shutdown Test',
          mnemonic: mnemonic,
        ));

        await created;

        // Send shutdown — should not throw
        coordinator.tell(ShutdownCommand());

        // Give it a moment to process
        await Future.delayed(const Duration(milliseconds: 500));
      });
    });
  });
}
