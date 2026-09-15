/// Bead libspiffy-u0x (a) and (c): InvoiceCoordinatorActor's replies.
///
/// (a) With the invoice projection wired, MarkInvoicePaidMessage was told to
///     the aggregate without a sender and the coordinator waited for the
///     projection to apply InvoicePaidEvent. A payment the aggregate rejected
///     journals no event, so the caller got 'Mark-paid projection timeout'
///     after the projection's 10 s wait instead of the rejection.
/// (c) Without a projection, invoice creation replied success as soon as the
///     command was told to the aggregate: before the InvoiceCreatedEvent was
///     persisted, and even when persisting it failed.
///
/// Now the coordinator waits for the aggregate's own answer: a rejection is
/// passed on at once, and a creation is answered only once it is journaled.
library;

import 'dart:async';

import 'package:dactor/dactor.dart';
import 'package:eventador/eventador.dart';
import 'package:libspiffy/src/actors/invoice_coordinator_actor.dart';
import 'package:libspiffy/src/actors/invoice_messages.dart';
import 'package:libspiffy/src/core/invoice_events.dart';
import 'package:libspiffy/src/models/invoice_output_spec.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';
import 'package:test/test.dart';

import 'in_memory_event_store.dart';

const _walletId = 'w-u0x';
const _address = 'mkHS9ne12qx9pS9VojpwU5xtRd4T7X7ZUt'; // testnet
const _wait = Duration(seconds: 15);

void main() {
  late LocalActorSystem system;
  late _GatedEventStore store;
  late _Recorder recorder;
  late ActorRef recorderRef;

  setUp(() async {
    system = LocalActorSystem(ActorSystemConfig());
    store = _GatedEventStore();
    recorder = _Recorder();
    recorderRef = await system.spawn('recorder', () => recorder);
  });

  tearDown(() => system.shutdown());

  Future<ActorRef> coordinator({ActorRef? projection}) => system.spawn(
        'invoice-coordinator',
        () => InvoiceCoordinatorActor(
          walletManager: recorderRef,
          storage: InMemoryWalletStorage(),
          eventStore: store,
          invoiceProjection: projection,
        ),
      );

  CreateInvoiceMessage invoice() => CreateInvoiceMessage(
        walletId: _walletId,
        outputs: [P2PKHOutputSpec(address: _address, amount: BigInt.from(5000))],
      );

  test('(a) with the projection wired, a rejected payment is answered at once with the aggregate\'s reason',
      () async {
    final projection = await system.spawn('invoice-projection', () => _JournalProjection(store));
    final invoices = await coordinator(projection: projection);
    invoices.tell(invoice(), sender: recorderRef);
    final created = await recorder.waitFor<InvoiceCreatedMessage>((_) => true);
    expect(created.success, isTrue, reason: created.error);

    final stopwatch = Stopwatch()..start();
    invoices.tell(
      MarkInvoicePaidMessage(
        invoiceId: created.invoiceId,
        txid: 'a' * 64,
        amountReceived: BigInt.from(1000),
        addressesPaidTo: const [_address],
      ),
      sender: recorderRef,
    );
    final reply = await recorder.waitFor<InvoiceStatusMessage>((_) => true);
    stopwatch.stop();

    // Old code: 'Mark-paid projection timeout: ...' after the 10 s wait.
    expect(reply.status, InvoiceStatus.pending);
    expect(reply.statusMessage, contains('less than invoice amount'));
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 3)));
  });

  test('(a) with the projection wired, an accepted payment is still answered once the projection applied it',
      () async {
    final projection = await system.spawn('invoice-projection', () => _JournalProjection(store));
    final invoices = await coordinator(projection: projection);
    invoices.tell(invoice(), sender: recorderRef);
    final created = await recorder.waitFor<InvoiceCreatedMessage>((_) => true);

    invoices.tell(
      MarkInvoicePaidMessage(
        invoiceId: created.invoiceId,
        txid: 'b' * 64,
        amountReceived: BigInt.from(5000),
        addressesPaidTo: const [_address],
      ),
      sender: recorderRef,
    );
    final reply = await recorder.waitFor<InvoiceStatusMessage>((_) => true);

    expect(reply.status, InvoiceStatus.paid, reason: reply.statusMessage);
    expect(reply.txid, 'b' * 64);
  });

  test('(c) without a projection, an invoice is answered only once its creation is journaled', () async {
    final invoices = await coordinator();
    store.gate = Completer<void>();

    invoices.tell(invoice(), sender: recorderRef);
    await store.waitForBlockedWrite();
    await Future<void>.delayed(const Duration(milliseconds: 300));

    // Old code: InvoiceCreatedMessage(success: true) was already sent.
    expect(recorder.received.whereType<InvoiceCreatedMessage>(), isEmpty,
        reason: 'the invoice was reported created before InvoiceCreatedEvent was persisted');

    store.gate!.complete();
    final created = await recorder.waitFor<InvoiceCreatedMessage>((_) => true);
    expect(created.success, isTrue, reason: created.error);
    expect(store.allEvents.whereType<InvoiceCreatedEvent>().single.invoiceId, created.invoiceId);
  });

  test('(c) without a projection, an invoice whose creation cannot be journaled is reported failed', () async {
    final invoices = await coordinator();
    store.failPersist = true;

    invoices.tell(invoice(), sender: recorderRef);
    final created = await recorder.waitFor<InvoiceCreatedMessage>((_) => true);

    // Old code: success true, an invoice id nobody can look up or pay.
    expect(created.success, isFalse);
    expect(created.error, contains('journal unavailable'));
    expect(store.allEvents, isEmpty);
  });
}

/// Records every message it receives.
class _Recorder extends Actor {
  final List<dynamic> received = [];

  @override
  Future<void> onMessage(dynamic message) async => received.add(message);

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
/// a matching event is in the journal, or with AwaitFailed after the
/// request's own timeout (as the real projection does).
class _JournalProjection extends Actor {
  final InMemoryEventStore store;
  _JournalProjection(this.store);

  @override
  Future<void> onMessage(dynamic message) async {
    if (message is! AwaitEventApplied) return;
    // ignore: invalid_use_of_internal_member
    final sender = context.sender;
    final deadline = DateTime.now().add(message.timeout);
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

/// In-memory journal whose writes can be held at a gate or made to fail.
class _GatedEventStore extends InMemoryEventStore {
  Completer<void>? gate;
  bool failPersist = false;
  int _blockedWrites = 0;

  Future<void> waitForBlockedWrite() async {
    final deadline = DateTime.now().add(_wait);
    while (_blockedWrites == 0) {
      if (DateTime.now().isAfter(deadline)) fail('no journal write reached the gate');
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  Future<void> _pass() async {
    final g = gate;
    if (g != null && !g.isCompleted) {
      _blockedWrites++;
      await g.future;
    }
    if (failPersist) throw StateError('journal unavailable');
  }

  @override
  Future<void> persistEvents(String persistenceId, List<Event> events, int expectedVersion) async {
    await _pass();
    await super.persistEvents(persistenceId, events, expectedVersion);
  }

  @override
  Future<void> persistEvent(String persistenceId, Event event, int expectedVersion) async {
    await _pass();
    await super.persistEvent(persistenceId, event, expectedVersion);
  }
}
