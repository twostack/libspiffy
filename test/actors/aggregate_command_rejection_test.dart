/// A rejected command no longer stops the aggregate actor (libspiffy-201).
///
/// eventador's AggregateRoot answers a failed command through
/// onCommandFailure and then rethrows; dactor stops an unsupervised actor
/// whose onMessage throws. The aggregates are spawned by their managers with
/// `context.system.spawn`, so every rejected command (reserving an unknown
/// UTXO, an underpaid invoice, a bad WIF) killed the aggregate while the
/// manager kept the dead ref: the next command for that wallet or invoice
/// went to dead letters and its caller timed out.
///
/// Now a rejection (the command failed before anything was written to the
/// journal) is answered once and the aggregate keeps running with its state
/// untouched: no journal recovery per bad command. A failure while writing
/// to the journal still fails the command, and the aggregate takes itself
/// out of service (marked retiring) before the failure reply leaves, so the
/// manager replaces it (recovering from the journal) on the next command. The
/// out-of-service incarnation stops once retired, after answering what was
/// queued to it (libspiffy-u0x, aggregate_journal_failure_queue_test.dart).
library;

import 'dart:async';

import 'package:dactor/dactor.dart';
import 'package:dactor_test/dactor_test.dart';
import 'package:eventador/eventador.dart';
import 'package:test/test.dart';

import 'package:libspiffy/src/actors/invoice_coordinator_actor.dart';
import 'package:libspiffy/src/actors/invoice_messages.dart';
import 'package:libspiffy/src/actors/wallet_manager_actor.dart';
import 'package:libspiffy/src/actors/wallet_messages.dart';
import 'package:libspiffy/src/core/aggregate_command_failures.dart';
import 'package:libspiffy/src/core/bitcoin_wallet_aggregate.dart';
import 'package:libspiffy/src/core/invoice_events.dart';
import 'package:libspiffy/src/core/wallet_commands.dart';
import 'package:libspiffy/src/models/invoice_output_spec.dart';
import 'package:libspiffy/src/services/dartsv_crypto_service.dart';
import 'package:libspiffy/src/storage/in_memory_secure_storage.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';

import 'in_memory_event_store.dart';

const _mnemonic = 'abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon abandon abandon about';
const _walletId = 'w-201';
const _walletPid = 'BitcoinWallet_$_walletId';
const _address = 'mkHS9ne12qx9pS9VojpwU5xtRd4T7X7ZUt'; // testnet
const _wait = Duration(seconds: 5);

/// No further reply may arrive within this window after the first one.
const _quiet = Duration(milliseconds: 300);

void main() {
  late TestActorSystem system;
  late _CountingEventStore store;
  late _Recorder recorder;
  late ActorRef recorderRef;

  setUp(() async {
    system = TestActorSystem();
    store = _CountingEventStore();
    recorder = _Recorder();
    recorderRef = await system.spawn('recorder', () => recorder);
  });

  tearDown(() async {
    await system.shutdown();
  });

  group('WalletManagerActor', () {
    late ActorRef manager;

    setUp(() async {
      manager = await system.spawn(
        'wallet-manager',
        () => WalletManagerActor(
          eventStore: store,
          cryptoService: DartSVCryptoService(),
          secureStorage: InMemorySecureStorage(),
        ),
      );
    });

    Future<void> createWallet() async {
      final created = await manager.ask<WalletCreatedMessage>(
        CreateWalletMessage(_walletId, 'Wallet 201', mnemonic: _mnemonic),
        const Duration(seconds: 10),
      );
      expect(created.success, isTrue, reason: created.error);
    }

    void send(WalletCommand command) =>
        manager.tell(WalletCommandMessage(_walletId, command), sender: recorderRef);

    test('a rejected command is answered once and the same aggregate serves '
        'the next command without a journal recovery', () async {
      await createWallet();
      final aggregateBefore = system.getActor('wallet-$_walletId');
      expect(aggregateBefore, isNotNull);
      expect(store.recoveries(_walletPid), 1);

      send(ReserveUTXOCommand(
        walletId: _walletId,
        utxoKey: '${'c' * 64}:0',
        reservedByTxId: 'tx-201',
      ));
      final rejected = await recorder.waitFor<UTXOReservedResponse>((_) => true);
      expect(rejected.success, isFalse);
      expect(rejected.error, contains('not found'));

      send(GenerateAddressCommand(walletId: _walletId, label: 'after rejection'));
      // Old code: the rejection stopped wallet-w-201, the manager forwarded
      // this command to the dead ref (dead letters) and no reply came.
      final generated = await recorder.waitFor<AddressGeneratedResponse>((_) => true);
      expect(generated.success, isTrue, reason: generated.error);
      await Future<void>.delayed(_quiet);

      expect(recorder.received.whereType<UTXOReservedResponse>(), hasLength(1),
          reason: 'exactly one reply to the rejected command');
      expect(recorder.received.whereType<AddressGeneratedResponse>(), hasLength(1));
      expect(identical(system.getActor('wallet-$_walletId'), aggregateBefore), isTrue,
          reason: 'the aggregate that rejected the command is still the live one');
      expect(store.recoveries(_walletPid), 1,
          reason: 'a rejection must not cost a journal recovery');
    });

    test('a rejected CreateWalletMessage can be retried', () async {
      final rejected = await manager.ask<WalletCreatedMessage>(
        CreateWalletMessage(_walletId, 'Wallet 201', wif: 'not-a-wif'),
        const Duration(seconds: 10),
      );
      expect(rejected.success, isFalse);
      expect(store.journal[_walletPid], isNull);

      // Old code: the manager still held the (dead) aggregate of the failed
      // creation and answered "Wallet already exists".
      final created = await manager.ask<WalletCreatedMessage>(
        CreateWalletMessage(_walletId, 'Wallet 201', mnemonic: _mnemonic),
        const Duration(seconds: 10),
      );
      expect(created.success, isTrue, reason: created.error);
      expect(created.rootAddress, isNotEmpty);
    });

    test('a journal write failure is reported once, and the next command is '
        'served by an aggregate recovered from the journal', () async {
      await createWallet();
      store.failPersist = true;

      send(GenerateAddressCommand(walletId: _walletId, label: 'lost'));
      final failed = await recorder.waitFor<AddressGeneratedResponse>((_) => true);
      expect(failed.success, isFalse);
      expect(failed.error, contains('journal unavailable'));
      await Future<void>.delayed(_quiet);
      expect(recorder.received.whereType<AddressGeneratedResponse>(), hasLength(1),
          reason: 'exactly one reply to the failed command');

      store.failPersist = false;
      send(GenerateAddressCommand(walletId: _walletId, label: 'kept'));
      // Old code: the failure stopped the aggregate and the manager kept
      // forwarding to the dead ref.
      final generated = await recorder.waitFor<AddressGeneratedResponse>((r) => r.success);
      expect(generated.success, isTrue);
      await Future<void>.delayed(_quiet);
      expect(recorder.received.whereType<AddressGeneratedResponse>(), hasLength(2));
      expect(store.recoveries(_walletPid), 2,
          reason: 'the replacement aggregate recovered from the journal');
    });
  });

  group('BitcoinWalletAggregate actor', () {
    Future<ActorRef> spawnAggregate() async {
      final secureStorage = InMemorySecureStorage();
      final ref = await system.spawn(
        'wallet-$_walletId',
        () => BitcoinWalletAggregate(
          aggregateId: _walletId,
          aggregateType: 'BitcoinWallet',
          eventStore: store,
          cryptoService: DartSVCryptoService(),
          secureStorage: secureStorage,
        ),
      );
      ref.tell(CreateWalletCommand(
          walletId: _walletId, walletName: 'Wallet 201', mnemonic: _mnemonic),
          sender: recorderRef);
      final created = await recorder.waitFor<WalletCreatedResponse>((_) => true);
      expect(created.success, isTrue, reason: created.error);
      return ref;
    }

    test('a rejection leaves the actor running', () async {
      final ref = await spawnAggregate();

      ref.tell(ReleaseUTXOCommand(walletId: _walletId, utxoKey: '${'d' * 64}:1'),
          sender: recorderRef);
      await recorder.waitFor<dynamic>((m) => m is WalletCommandFailed);
      await Future<void>.delayed(_quiet);

      expect(ref.isAlive, isTrue,
          reason: 'old code: dactor stopped the aggregate after the rethrow');
    });

    test('a journal write failure takes the actor out of service before the '
        'failure reply is sent', () async {
      final ref = await spawnAggregate();
      store.failPersist = true;
      recorder.onReceive = (message) {
        if (message is AddressGeneratedResponse) {
          recorder.aliveAtReply.add(!CommandFailureContainment.isRetiring(ref));
        }
      };

      ref.tell(GenerateAddressCommand(walletId: _walletId), sender: recorderRef);
      final failed = await recorder.waitFor<AddressGeneratedResponse>((_) => true);
      await Future<void>.delayed(_quiet);

      expect(failed.success, isFalse);
      expect(recorder.received.whereType<AddressGeneratedResponse>(), hasLength(1));
      expect(recorder.aliveAtReply, [false],
          reason: 'a manager that sees the failure must already see the aggregate '
              'out of service, so its next command goes to a recovered replacement');

      // It stops once retired (libspiffy-u0x: stopping at once discarded the
      // commands queued behind the failed one).
      ref.tell(GenerateAddressCommand(walletId: _walletId), sender: recorderRef);
      await CommandFailureContainment.retire(ref).timeout(_wait);
      expect(ref.isAlive, isFalse);
      final replies = recorder.received.whereType<AddressGeneratedResponse>().toList();
      expect(replies, hasLength(2), reason: 'the command queued before the retirement is answered');
      expect(replies.last.success, isFalse);
      expect(replies.last.error, contains('not processed'));
    });

    test('an optimistic concurrency conflict counts as an infrastructure '
        'failure: answered once, actor out of service', () async {
      final ref = await spawnAggregate();

      ref.tell(_StaleVersionCommand(), sender: recorderRef);
      final reply = await recorder.waitFor<dynamic>((m) => m is WalletCommandFailed);
      await Future<void>.delayed(_quiet);

      expect((reply as WalletCommandFailed).error,
          contains('OptimisticConcurrencyException'));
      expect(recorder.received.whereType<WalletCommandFailed>(), hasLength(1),
          reason: 'answered exactly once');
      expect(CommandFailureContainment.isRetiring(ref), isTrue,
          reason: 'a version conflict means the in-memory state may be stale');
      await CommandFailureContainment.retire(ref).timeout(_wait);
      expect(ref.isAlive, isFalse);
    });
  });

  group('InvoiceCoordinatorActor', () {
    Future<(ActorRef, String)> createInvoice({ActorRef? projection}) async {
      final coordinator = await system.spawn(
        'invoice-coordinator',
        () => InvoiceCoordinatorActor(
          walletManager: recorderRef,
          storage: InMemoryWalletStorage(),
          eventStore: store,
          invoiceProjection: projection,
        ),
      );
      coordinator.tell(
        CreateInvoiceMessage(
          walletId: _walletId,
          outputs: [P2PKHOutputSpec(address: _address, amount: BigInt.from(5000))],
        ),
        sender: recorderRef,
      );
      final created = await recorder.waitFor<InvoiceCreatedMessage>((_) => true);
      expect(created.success, isTrue, reason: created.error);
      await _eventually(() => store.allEvents.whereType<InvoiceCreatedEvent>().isNotEmpty);
      return (coordinator, created.invoiceId);
    }

    MarkInvoicePaidMessage payment(String invoiceId, int sats, String txid) =>
        MarkInvoicePaidMessage(
          invoiceId: invoiceId,
          txid: txid,
          amountReceived: BigInt.from(sats),
          addressesPaidTo: const [_address],
        );

    test('an underpayment is rejected once and the same aggregate records the '
        'full payment without a journal recovery', () async {
      final (coordinator, invoiceId) = await createInvoice();
      final aggregateBefore = system.getActor('invoice-aggregate-$invoiceId');
      expect(aggregateBefore, isNotNull);

      coordinator.tell(payment(invoiceId, 1000, 'a' * 64), sender: recorderRef);
      final rejected = await recorder.waitFor<InvoiceStatusMessage>((_) => true);
      expect(rejected.status, InvoiceStatus.pending);
      expect(rejected.statusMessage, contains('less than invoice amount'));

      coordinator.tell(payment(invoiceId, 5000, 'b' * 64), sender: recorderRef);
      // Old code: the rejection stopped the aggregate; this payment went to
      // dead letters and no paid status ever came.
      final paid = await recorder.waitFor<InvoiceStatusMessage>(
          (m) => m.status == InvoiceStatus.paid);
      expect(paid.txid, 'b' * 64);
      await Future<void>.delayed(_quiet);

      expect(recorder.received.whereType<InvoiceStatusMessage>(), hasLength(2),
          reason: 'exactly one reply per command (old code answered the '
              'rejection twice)');
      expect(identical(system.getActor('invoice-aggregate-$invoiceId'), aggregateBefore),
          isTrue);
      expect(store.recoveries('Invoice_$invoiceId'), 1);
    });

    test('with the invoice projection wired, a payment after a rejected one '
        'is recorded', () async {
      final projection =
          await system.spawn('invoice-projection', () => _JournalProjection(store));
      final (coordinator, invoiceId) = await createInvoice(projection: projection);

      coordinator.tell(payment(invoiceId, 1000, 'a' * 64), sender: recorderRef);
      final rejected = await recorder.waitFor<InvoiceStatusMessage>((_) => true);
      expect(rejected.status, InvoiceStatus.pending);

      coordinator.tell(payment(invoiceId, 5000, 'b' * 64), sender: recorderRef);
      final second = await recorder.waitFor<InvoiceStatusMessage>(
          (m) => !identical(m, rejected));
      // Old code: 'Mark-paid projection timeout' (the payment never reached
      // a live aggregate).
      expect(second.status, InvoiceStatus.paid, reason: second.statusMessage);
      expect(store.allEvents.whereType<InvoicePaidEvent>(), hasLength(1));
    });

    test('a payment for an unknown invoice is answered at once and leaves no '
        'aggregate running', () async {
      final projection =
          await system.spawn('invoice-projection', () => _JournalProjection(store));
      await createInvoice(projection: projection);
      final coordinator = system.getActor('invoice-coordinator')!;
      final stopwatch = Stopwatch()..start();

      coordinator.tell(payment('no-such-invoice', 5000, 'a' * 64), sender: recorderRef);
      final reply = await recorder.waitFor<InvoiceStatusMessage>((_) => true);
      stopwatch.stop();

      expect(reply.status, InvoiceStatus.pending);
      expect(reply.statusMessage, contains('not found'));
      // Old code spawned an aggregate for the unknown id (which rejected the
      // payment unanswered and, now that rejections keep aggregates running,
      // would stay loaded) and replied only when the projection wait gave up.
      expect(system.getActor('invoice-aggregate-no-such-invoice'), isNull);
      expect(stopwatch.elapsed, lessThan(const Duration(milliseconds: 900)));
    });

    test('a journal write failure is reported, and the next payment is '
        'recorded by a recovered aggregate', () async {
      final (coordinator, invoiceId) = await createInvoice();
      store.failPersist = true;

      coordinator.tell(payment(invoiceId, 5000, 'a' * 64), sender: recorderRef);
      final failed = await recorder.waitFor<InvoiceStatusMessage>((_) => true);
      expect(failed.status, InvoiceStatus.pending);
      expect(failed.statusMessage, contains('journal unavailable'));
      await Future<void>.delayed(_quiet);
      expect(recorder.received.whereType<InvoiceStatusMessage>(), hasLength(1));

      store.failPersist = false;
      coordinator.tell(payment(invoiceId, 5000, 'b' * 64), sender: recorderRef);
      final paid = await recorder.waitFor<InvoiceStatusMessage>(
          (m) => m.status == InvoiceStatus.paid);
      expect(paid.txid, 'b' * 64);
      expect(store.recoveries('Invoice_$invoiceId'), 2);
    });
  });
}

Future<void> _eventually(bool Function() condition) async {
  final deadline = DateTime.now().add(_wait);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('condition not met within $_wait');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

/// Records every message it receives.
class _Recorder extends Actor {
  final List<dynamic> received = [];
  final List<bool> aliveAtReply = [];
  void Function(dynamic message)? onReceive;

  @override
  Future<void> onMessage(dynamic message) async {
    onReceive?.call(message);
    received.add(message);
  }

  Future<T> waitFor<T>(bool Function(T) match) async {
    final deadline = DateTime.now().add(_wait);
    while (DateTime.now().isBefore(deadline)) {
      for (final m in received.whereType<T>()) {
        if (match(m)) return m;
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('no matching $T within $_wait; received: $received');
  }
}

/// Stands in for the invoice ProjectionActor: answers AwaitEventApplied once
/// a matching event is in the journal, or with AwaitFailed after one second.
class _JournalProjection extends Actor {
  final InMemoryEventStore store;
  _JournalProjection(this.store);

  @override
  Future<void> onMessage(dynamic message) async {
    if (message is! AwaitEventApplied) return;
    // ignore: invalid_use_of_internal_member
    final sender = context.sender;
    final deadline = DateTime.now().add(const Duration(seconds: 1));
    unawaited(() async {
      while (DateTime.now().isBefore(deadline)) {
        for (final event in store.allEvents) {
          if (message.predicate(event)) {
            sender?.tell(EventAppliedResponse(matchedEvent: event));
            return;
          }
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      sender?.tell(AwaitFailed(reason: 'timeout'));
    }());
  }
}

/// In-memory journal that counts recoveries (event reads per persistence id)
/// and whose writes can be made to fail.
class _CountingEventStore extends InMemoryEventStore {
  bool failPersist = false;
  final Map<String, int> _reads = {};

  int recoveries(String persistenceId) => _reads[persistenceId] ?? 0;

  @override
  Future<List<Event>> getEvents(String persistenceId,
      {int fromSequence = 0, int? toSequence}) {
    _reads[persistenceId] = recoveries(persistenceId) + 1;
    return super.getEvents(persistenceId,
        fromSequence: fromSequence, toSequence: toSequence);
  }

  @override
  Future<void> persistEvents(
      String persistenceId, List<Event> events, int expectedVersion) async {
    if (failPersist) throw StateError('journal unavailable');
    await super.persistEvents(persistenceId, events, expectedVersion);
  }

  @override
  Future<void> persistEvent(
      String persistenceId, Event event, int expectedVersion) async {
    if (failPersist) throw StateError('journal unavailable');
    await super.persistEvent(persistenceId, event, expectedVersion);
  }
}

/// A wallet command that expects a journal version the aggregate is not at.
class _StaleVersionCommand extends WalletCommand with TargetedCommand {
  _StaleVersionCommand() : super(walletId: _walletId);

  @override
  String get commandType => 'StaleVersionCommand';

  @override
  String get aggregateId => _walletId;

  @override
  int? get expectedVersion => 99;
}
