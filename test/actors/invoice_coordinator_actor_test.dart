/// InvoiceCoordinatorActor failure-path tests with a stubbed WalletManager.
///
/// Covers audit findings (doc/audit-2026-09-14.md):
/// - A-H6: a failed address generation must fail the invoice instead of
///   creating one with an empty address and reporting success.
/// - A-M6 (invoice part): a `{'error': ...}` map reply from WalletManager
///   must fail the pending invoice instead of leaking it (caller hangs).
/// - A-H2: the AwaitEventApplied ask must outlast the awaiter window, so a
///   projection that is slow but succeeds does not surface as a failure.

import 'dart:async';
import 'package:test/test.dart';
import 'package:dactor/dactor.dart';
import 'package:dactor_test/dactor_test.dart';
import 'package:eventador/eventador.dart';

import 'package:libspiffy/src/actors/invoice_coordinator_actor.dart';
import 'package:libspiffy/src/actors/invoice_messages.dart';
import 'package:libspiffy/src/actors/wallet_messages.dart';
import 'package:libspiffy/src/core/invoice_events.dart';
import 'package:libspiffy/src/core/wallet_commands.dart';
import 'package:libspiffy/src/models/invoice_output_spec.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';

import 'in_memory_event_store.dart';

const _walletId = 'wallet-1';
const _testnetAddress = 'mkHS9ne12qx9pS9VojpwU5xtRd4T7X7ZUt';

void main() {
  late TestActorSystem actorSystem;
  late InMemoryEventStore eventStore;
  late _StubWalletManager stubWalletManager;
  late ActorRef walletManagerRef;
  late TestProbe caller;

  Future<ActorRef> spawnCoordinator({ActorRef? invoiceProjection}) {
    return actorSystem.spawn(
      'invoice-coordinator',
      () => InvoiceCoordinatorActor(
        walletManager: walletManagerRef,
        storage: InMemoryWalletStorage(),
        eventStore: eventStore,
        invoiceProjection: invoiceProjection,
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
/// `{'error': ..., 'walletId': ...}` map the real manager sends for a wallet
/// it cannot load.
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
      context.sender?.tell(LocalMessage(
        payload: {'error': 'Wallet not found', 'walletId': message.walletId},
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
