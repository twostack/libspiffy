/// InvoiceCoordinatorActor failure-path tests with a stubbed WalletManager.
///
/// Covers audit findings (doc/audit-2026-09-14.md):
/// - A-H6: a failed address generation must fail the invoice instead of
///   creating one with an empty address and reporting success.
/// - A-M6 (invoice part): a failure reply from WalletManager
///   must fail the pending invoice instead of leaking it (caller hangs).
/// - A-H2: the AwaitEventApplied ask must outlast the awaiter window, so a
///   projection that is slow but succeeds does not surface as a failure.
/// - libspiffy-q5jv: a wallet-manager error fails only the invoice whose
///   address request it answers, promptly; an uncorrelated one fails none.

import 'dart:async';
import 'package:test/test.dart';
import 'package:dactor/dactor.dart';
import 'package:dactor_test/dactor_test.dart';
import 'package:eventador/eventador.dart';

import 'package:libspiffy/src/actors/invoice_coordinator_actor.dart';
import 'package:libspiffy/src/actors/invoice_messages.dart';
import 'package:libspiffy/src/actors/wallet_manager_actor.dart';
import 'package:libspiffy/src/services/dartsv_crypto_service.dart';
import 'package:libspiffy/src/storage/in_memory_secure_storage.dart';
import 'package:libspiffy/src/actors/wallet_messages.dart';
import 'package:libspiffy/src/core/invoice_events.dart';
import 'package:libspiffy/src/core/wallet_commands.dart';
import 'package:libspiffy/src/models/invoice_output_spec.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';
import 'package:libspiffy/src/storage/read_model_storage.dart';
import 'package:libspiffy/src/models/address_chain.dart';

import 'in_memory_event_store.dart';
import '../storage/invoice_read_model_contract.dart';

const _walletId = 'wallet-1';
const _otherWalletId = 'wallet-2';
const _testnetAddress = 'mkHS9ne12qx9pS9VojpwU5xtRd4T7X7ZUt';

void main() {
  late TestActorSystem actorSystem;
  late InMemoryEventStore eventStore;
  late _StubWalletManager stubWalletManager;
  late ActorRef walletManagerRef;
  late TestProbe caller;

  Future<ActorRef> spawnCoordinator({
    ActorRef? invoiceProjection,
    ReadModelStorage? storage,
    Duration addressRequestTimeout = const Duration(seconds: 60),
  }) {
    return actorSystem.spawn(
      'invoice-coordinator',
      () => InvoiceCoordinatorActor(
        walletManager: walletManagerRef,
        storage: storage ?? InMemoryWalletStorage(),
        eventStore: eventStore,
        invoiceProjection: invoiceProjection,
        addressRequestTimeout: addressRequestTimeout,
      ),
    );
  }

  setUp(() async {
    actorSystem = TestActorSystem();
    eventStore = InMemoryEventStore();
    stubWalletManager = _StubWalletManager();
    walletManagerRef =
        await actorSystem.spawn('wallet-manager', () => stubWalletManager);
    caller = await actorSystem.createProbe();
  });

  tearDown(() async {
    await actorSystem.shutdown();
  });

  group('A-H6: failed address generation', () {
    for (final variant in [
      (
        name: 'AddressGeneratedResponse with success:false',
        reply: (GenerateAddressCommand cmd) => AddressGeneratedResponse(
              walletId: cmd.walletId,
              address: '',
              derivationIndex: 0,
              chain: AddressChain.receive,
              success: false,
              error: 'key derivation failed',
              metadata: cmd.metadata,
            ),
        expectedError: 'key derivation failed',
      ),
      (
        name: 'AddressGeneratedResponse with success:true but empty address',
        reply: (GenerateAddressCommand cmd) => AddressGeneratedResponse(
              walletId: cmd.walletId,
              address: '',
              derivationIndex: 0,
              chain: AddressChain.receive,
              success: true,
              metadata: cmd.metadata,
            ),
        expectedError: 'Address generation failed',
      ),
    ]) {
      test('${variant.name} fails the invoice and persists nothing', () async {
        stubWalletManager.onGenerateAddress = variant.reply;
        final coordinator = await spawnCoordinator();

        coordinator.tell(
          CreateInvoiceMessage(
            walletId: _walletId,
            amount: BigInt.from(10000),
            description: 'needs an address',
          ),
          sender: caller.ref,
        );

        final reply = await caller.expectMsgType<InvoiceCreatedMessage>(
          timeout: const Duration(seconds: 5),
        );

        // Old code appended the empty address, spawned the aggregate, and
        // replied success:true with addresses: [''].
        expect(reply.success, isFalse,
            reason: 'invoice must not be reported created: ${reply.addresses}');
        expect(reply.error, contains(variant.expectedError));
        expect(reply.addresses.where((a) => a.isEmpty), isEmpty);
        expect(eventStore.allEvents.whereType<InvoiceCreatedEvent>(), isEmpty,
            reason: 'no InvoiceCreatedEvent may be persisted');
      });
    }
  });

  group('A-M6: WalletManager error-map reply', () {
    test('fails the pending invoice instead of leaking it', () async {
      stubWalletManager.onGenerateAddress = null; // reply with the error map
      final coordinator = await spawnCoordinator();

      coordinator.tell(
        CreateInvoiceMessage(
          walletId: _walletId,
          amount: BigInt.from(10000),
        ),
        sender: caller.ref,
      );

      // Old code ignored the map in its default branch, so the caller never
      // got a reply (it hung until its own ask timeout).
      final reply = await caller.expectMsgType<InvoiceCreatedMessage>(
        timeout: const Duration(seconds: 3),
      );
      expect(reply.success, isFalse);
      expect(reply.error, 'Wallet not found');
      expect(reply.walletId, _walletId);
      expect(eventStore.allEvents.whereType<InvoiceCreatedEvent>(), isEmpty);
    });
  });

  /// libspiffy-q5jv: a wallet-manager error is applied only to the invoice
  /// whose address request it answers. The old coordinator failed every
  /// pending invoice on an error map without a walletId (the shape of
  /// WalletManagerActor's catch-all reply) and every pending invoice of the
  /// wallet on one with a walletId, whichever request it belonged to.
  group('q5jv: wallet-manager errors fail only the invoice they answer', () {
    late _HoldingWalletManager holding;
    late _InvoiceInbox inbox;
    late ActorRef inboxRef;

    setUp(() async {
      holding = _HoldingWalletManager();
      walletManagerRef =
          await actorSystem.spawn('holding-wallet-manager', () => holding);
      inbox = _InvoiceInbox();
      inboxRef = await actorSystem.spawn('invoice-inbox', () => inbox);
    });

    AddressGeneratedResponse addressFor(GenerateAddressCommand cmd) =>
        AddressGeneratedResponse(
          walletId: cmd.walletId,
          address: _testnetAddress,
          derivationIndex: 0,
          chain: AddressChain.receive,
          success: true,
          metadata: cmd.metadata,
        );

    /// Waits for [count] InvoiceCreatedEvents (the coordinator replies before
    /// the aggregate has journaled when no projection is wired).
    Future<void> invoicesJournaled(int count) async {
      Iterable<InvoiceCreatedEvent> journaled() =>
          eventStore.allEvents.whereType<InvoiceCreatedEvent>();
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (journaled().length < count && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(journaled(), hasLength(count));
    }

    /// Two invoices waiting for their addresses, the second for [secondWallet].
    Future<ActorRef> twoPendingInvoices(String secondWallet) async {
      final coordinator = await spawnCoordinator();
      coordinator.tell(
        CreateInvoiceMessage(walletId: _walletId, amount: BigInt.from(1000)),
        sender: inboxRef,
      );
      coordinator.tell(
        CreateInvoiceMessage(walletId: secondWallet, amount: BigInt.from(2000)),
        sender: inboxRef,
      );
      await holding.waitForRequests(2);
      return coordinator;
    }

    for (final secondWallet in [_otherWalletId, _walletId]) {
      final walletCase =
          secondWallet == _walletId ? 'the same wallet' : 'different wallets';

      for (final unrelated in [
        (
          name: 'catch-all failure naming no wallet',
          reply: WalletManagerFailure(
              error: 'unrelated failure', request: 'CreateWalletMessage'),
        ),
        (
          name: 'failure naming a wallet',
          reply: WalletManagerFailure(
              error: 'unrelated failure',
              request: 'WalletCommandMessage',
              walletId: secondWallet),
        ),
      ]) {
        test('an unrelated ${unrelated.name} error fails neither invoice for '
            '$walletCase; both complete when their addresses arrive', () async {
          final coordinator = await twoPendingInvoices(secondWallet);

          // An error reply to some other request of the coordinator's.
          coordinator.tell(unrelated.reply);
          for (final request in holding.requests) {
            request.sender!.tell(addressFor(request.command));
          }

          final replies = await inbox.waitFor(2);
          for (final reply in replies) {
            expect(reply.success, isTrue,
                reason: 'invoice for ${reply.amount} sats failed: ${reply.error}');
          }
          expect(replies.map((r) => r.amount).toSet(),
              {BigInt.from(1000), BigInt.from(2000)});
          await invoicesJournaled(2);
        });
      }

      for (final correlated in [
        (
          name: 'catch-all failure naming no wallet',
          reply: WalletManagerFailure(
              error: 'request failed', request: 'CreateWalletMessage'),
        ),
        (
          name: 'failure naming a wallet',
          reply: WalletManagerFailure(
              error: 'request failed',
              request: 'WalletCommandMessage',
              walletId: _walletId),
        ),
      ]) {
        test('a ${correlated.name} error answering one request fails only '
            'that invoice ($walletCase), promptly', () async {
          await twoPendingInvoices(secondWallet);

          final [first, second] = holding.requests;
          first.sender!.tell(correlated.reply);
          second.sender!.tell(addressFor(second.command));

          // Well inside the address-request timeout: the failure is the
          // error reply's doing, not a timeout's.
          final replies = await inbox.waitFor(2);
          final failed =
              replies.singleWhere((r) => r.amount == BigInt.from(1000));
          final created =
              replies.singleWhere((r) => r.amount == BigInt.from(2000));
          expect(failed.success, isFalse);
          expect(failed.error, 'request failed');
          expect(failed.walletId, _walletId);
          expect(created.success, isTrue,
              reason: 'the other invoice failed: ${created.error}');
          expect(created.walletId, secondWallet);
          await invoicesJournaled(1);
        });
      }
    }

    test('an invoice needing two addresses completes after both replies and '
        'fails on an error answering its second request', () async {
      final coordinator = await spawnCoordinator();
      coordinator.tell(
        CreateInvoiceMessage(
            walletId: _walletId, amount: BigInt.from(1000), numberOfAddresses: 2),
        sender: inboxRef,
      );
      coordinator.tell(
        CreateInvoiceMessage(
            walletId: _walletId, amount: BigInt.from(2000), numberOfAddresses: 2),
        sender: inboxRef,
      );
      await holding.waitForRequests(2);
      final [first, second] = holding.requests;
      first.sender!.tell(addressFor(first.command));
      second.sender!.tell(addressFor(second.command));

      await holding.waitForRequests(4);
      final [_, _, third, fourth] = holding.requests;
      expect(third.command.metadata['invoiceId'],
          first.command.metadata['invoiceId']);
      third.sender!.tell(WalletManagerFailure(
        error: 'Wallet not found',
        request: 'WalletCommandMessage',
        walletId: _walletId,
      ));
      fourth.sender!.tell(addressFor(fourth.command));

      final replies = await inbox.waitFor(2);
      final failed = replies.singleWhere((r) => r.amount == BigInt.from(1000));
      final created = replies.singleWhere((r) => r.amount == BigInt.from(2000));
      expect(failed.success, isFalse);
      expect(failed.error, 'Wallet not found');
      expect(created.success, isTrue, reason: created.error);
      expect(created.addresses, hasLength(2));
      await invoicesJournaled(1);
    });

    test('a request WalletManager never answers fails its invoice after the '
        'address-request timeout', () async {
      final coordinator = await spawnCoordinator(
        addressRequestTimeout: const Duration(milliseconds: 200),
      );
      coordinator.tell(
        CreateInvoiceMessage(walletId: _walletId, amount: BigInt.from(1000)),
        sender: inboxRef,
      );
      await holding.waitForRequests(1);

      // Old code kept the request pending forever: the caller got no reply.
      final [reply] = await inbox.waitFor(1);
      expect(reply.success, isFalse);
      expect(reply.error, contains('timed out'));
      expect(eventStore.allEvents.whereType<InvoiceCreatedEvent>(), isEmpty);
    });

    test("WalletManagerActor's own error reply fails the invoice promptly",
        () async {
      walletManagerRef = await actorSystem.spawn(
        'real-wallet-manager',
        () => WalletManagerActor(
          eventStore: eventStore,
          cryptoService: DartSVCryptoService(),
          secureStorage: InMemorySecureStorage(),
        ),
      );
      // The default 60 s address-request timeout: only the error reply can
      // fail the invoice within the inbox's 5 s.
      final coordinator = await spawnCoordinator();
      coordinator.tell(
        CreateInvoiceMessage(walletId: 'ghost', amount: BigInt.from(1000)),
        sender: inboxRef,
      );

      final [reply] = await inbox.waitFor(1);
      expect(reply.success, isFalse);
      expect(reply.error, 'Wallet not found');
      expect(reply.walletId, 'ghost');
    });
  });

  /// Audit 2026-09-14 S-07: the coordinator's `_invoiceFromMap` accepted an
  /// `Invoice` or a `Map`, but every backend stores the `InvoiceReadModel`
  /// that InvoiceProjection hands it, so CheckInvoice / ListInvoices threw
  /// a type error on the in-memory and Postgres backends.
  group('S-07: CheckInvoice / ListInvoices consume the stored InvoiceReadModel',
      () {
    const invoiceId = 'inv-s07';
    late InMemoryWalletStorage storage;

    setUp(() async {
      storage = InMemoryWalletStorage();
      // Exactly what InvoiceProjection._handleInvoiceCreated stores.
      await storage.storeInvoice(
        contractInvoice(invoiceId: invoiceId, walletId: _walletId),
      );
    });

    test('CheckInvoice answers found:true with the stored fields', () async {
      final coordinator = await spawnCoordinator(storage: storage);

      coordinator.tell(CheckInvoiceMessage(invoiceId), sender: caller.ref);

      final reply = await caller.expectMsgType<InvoiceDetailsResponse>(
        timeout: const Duration(seconds: 5),
      );
      // Old code: `type 'InvoiceReadModel' is not a subtype of type
      // 'Map<String, dynamic>' in type cast` -> found:false.
      expect(reply.found, isTrue, reason: 'error: ${reply.error}');
      expect(reply.error, isNull);
      expect(reply.invoiceId, equals(invoiceId));
      expect(reply.walletId, equals(_walletId));
      expect(reply.amount, equals(contractInvoiceAmount));
      expect(reply.status, equals(InvoiceStatus.pending));
      expect(reply.addresses,
          equals([contractInvoiceAddress1, contractInvoiceAddress2]));
      expect(reply.description, equals('contract invoice'));
      expect(reply.expiresAt, equals(contractInvoiceExpiresAt));
      expect(reply.outputs, hasLength(2),
          reason: 'structured outputs must reach the caller');
    });

    test('ListInvoices by wallet returns the stored invoice', () async {
      final coordinator = await spawnCoordinator(storage: storage);

      coordinator.tell(ListInvoicesMessage(walletId: _walletId),
          sender: caller.ref);

      final reply = await caller.expectMsgType<InvoicesListMessage>(
        timeout: const Duration(seconds: 5),
      );
      // Old code swallowed the type error and answered an empty list.
      expect(reply.invoices, hasLength(1));
      expect(reply.invoices.single.invoiceId, equals(invoiceId));
      expect(reply.invoices.single.status, equals(InvoiceStatus.pending));
      expect(reply.invoices.single.amount, equals(contractInvoiceAmount));
    });

    test('ListInvoices by status returns the stored invoice', () async {
      final coordinator = await spawnCoordinator(storage: storage);

      coordinator.tell(ListInvoicesMessage(filterStatus: InvoiceStatus.pending),
          sender: caller.ref);

      final reply = await caller.expectMsgType<InvoicesListMessage>(
        timeout: const Duration(seconds: 5),
      );
      expect(reply.invoices.map((i) => i.invoiceId), contains(invoiceId));
    });

    test('a read model whose status was updated is reported with the new status',
        () async {
      await storage.updateInvoiceStatus(
        invoiceId,
        InvoiceStatus.paid,
        txid: contractInvoicePaidTxid,
        amountReceived: contractInvoiceAmount,
        paidAt: contractInvoicePaidAt,
      );
      final coordinator = await spawnCoordinator(storage: storage);

      coordinator.tell(CheckInvoiceMessage(invoiceId), sender: caller.ref);

      final reply = await caller.expectMsgType<InvoiceDetailsResponse>(
        timeout: const Duration(seconds: 5),
      );
      expect(reply.found, isTrue, reason: 'error: ${reply.error}');
      expect(reply.status, equals(InvoiceStatus.paid));
      expect(reply.paymentTxid, equals(contractInvoicePaidTxid));
      expect(reply.paidAt, equals(contractInvoicePaidAt));
    });
  });

  group('A-H2: AwaitEventApplied ask outlasts the awaiter window', () {
    test('a projection that replies after 6 s still yields success', () async {
      // The awaiter window at this site is 10 s; dactor's default ask
      // timeout is 5 s. A projection that is slow but succeeds within the
      // window must not surface as a failed invoice.
      final projection = await actorSystem.spawn(
        'slow-invoice-projection',
        () => _SlowProjection(const Duration(seconds: 6)),
      );
      final coordinator = await spawnCoordinator(invoiceProjection: projection);

      coordinator.tell(
        CreateInvoiceMessage(
          walletId: _walletId,
          outputs: [
            P2PKHOutputSpec(address: _testnetAddress, amount: BigInt.from(1000)),
          ],
        ),
        sender: caller.ref,
      );

      final reply = await caller.expectMsgType<InvoiceCreatedMessage>(
        timeout: const Duration(seconds: 10),
      );
      expect(reply.success, isTrue, reason: 'error: ${reply.error}');
      expect(reply.addresses, [_testnetAddress]);
      expect(eventStore.allEvents.whereType<InvoiceCreatedEvent>(), hasLength(1));
    });
  });
}

/// Stands in for WalletManagerActor. Replies to GenerateAddressCommand with
/// whatever [onGenerateAddress] builds, or with the same
/// [WalletManagerFailure] the real manager sends for a wallet it cannot
/// load.
class _StubWalletManager extends Actor {
  AddressGeneratedResponse Function(GenerateAddressCommand cmd)?
      onGenerateAddress;

  @override
  Future<void> onMessage(dynamic message) async {
    if (message is! WalletCommandMessage) return;
    final cmd = message.command;
    if (cmd is! GenerateAddressCommand) return;
    final builder = onGenerateAddress;
    if (builder == null) {
      context.sender?.tell(WalletManagerFailure(
        error: 'Wallet not found',
        request: 'WalletCommandMessage',
        walletId: message.walletId,
      ));
      return;
    }
    context.sender?.tell(builder(cmd));
  }
}

/// Answers every AwaitEventApplied after [delay] with EventAppliedResponse.
class _SlowProjection extends Actor {
  final Duration delay;
  _SlowProjection(this.delay);

  @override
  Future<void> onMessage(dynamic message) async {
    if (message is AwaitEventApplied) {
      final sender = context.sender;
      Timer(delay, () => sender?.tell(EventAppliedResponse()));
    }
  }
}

/// Holds every GenerateAddressCommand it is sent, with the ref to answer it
/// on, and answers none: the test replies.
class _HoldingWalletManager extends Actor {
  final List<({GenerateAddressCommand command, ActorRef? sender})> requests = [];
  final List<({int count, Completer<void> waiter})> _waiters = [];

  Future<void> waitForRequests(int count) {
    if (requests.length >= count) return Future.value();
    final waiter = Completer<void>();
    _waiters.add((count: count, waiter: waiter));
    return waiter.future.timeout(const Duration(seconds: 5));
  }

  @override
  Future<void> onMessage(dynamic message) async {
    if (message is! WalletCommandMessage) return;
    final cmd = message.command;
    if (cmd is! GenerateAddressCommand) return;
    // ignore: invalid_use_of_internal_member
    requests.add((command: cmd, sender: context.sender));
    final ready = _waiters.where((w) => requests.length >= w.count).toList();
    for (final w in ready) {
      _waiters.remove(w);
      w.waiter.complete();
    }
  }
}

/// Collects every InvoiceCreatedMessage it is sent (a TestProbe drops the
/// messages that arrive while no expectation is registered).
class _InvoiceInbox extends Actor {
  final List<InvoiceCreatedMessage> received = [];
  final _arrivals = StreamController<void>.broadcast();

  /// The first [count] replies, once they have arrived.
  Future<List<InvoiceCreatedMessage>> waitFor(int count,
      {Duration timeout = const Duration(seconds: 5)}) async {
    final deadline = DateTime.now().add(timeout);
    while (received.length < count) {
      final left = deadline.difference(DateTime.now());
      if (left <= Duration.zero) {
        fail('expected $count InvoiceCreatedMessage replies within $timeout, '
            'got ${received.length}: '
            '${received.map((r) => '${r.amount}: ${r.success} ${r.error}')}');
      }
      await _arrivals.stream.first.timeout(left, onTimeout: () {});
    }
    return received.sublist(0, count);
  }

  @override
  Future<void> onMessage(dynamic message) async {
    if (message is InvoiceCreatedMessage) {
      received.add(message);
      _arrivals.add(null);
    }
  }
}
