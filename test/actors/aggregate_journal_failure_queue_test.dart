/// Bead libspiffy-u0x (b): commands queued behind a journal failure were lost.
///
/// An aggregate whose journal write fails takes itself out of service
/// (libspiffy-201). It used to stop itself at once, and dactor disposes a
/// stopped actor's mailbox: every command already queued behind the failed
/// one (routed by WalletManagerActor or InvoiceCoordinatorActor while the
/// write was in flight) vanished, and its caller waited for a reply that
/// never came.
///
/// Now the out-of-service incarnation answers every command still queued to
/// it with a failure (typed like any failure reply of that command, so the
/// caller can retry) and stops only when its manager retires it, after the
/// manager's last command to it. Commands arriving after the failure go to an
/// aggregate recovered from the journal. A failure reply rather than a retry:
/// a queued command may have been issued on the assumption that the one
/// ahead of it succeeded, so only its caller can decide to send it again.
library;

import 'dart:async';

import 'package:dactor/dactor.dart';
import 'package:dactor_test/dactor_test.dart';
import 'package:eventador/eventador.dart';
import 'package:libspiffy/src/actors/invoice_coordinator_actor.dart';
import 'package:libspiffy/src/actors/invoice_messages.dart';
import 'package:libspiffy/src/actors/wallet_manager_actor.dart';
import 'package:libspiffy/src/actors/wallet_messages.dart';
import 'package:libspiffy/src/core/invoice_events.dart';
import 'package:libspiffy/src/core/wallet_commands.dart';
import 'package:libspiffy/src/models/invoice_output_spec.dart';
import 'package:libspiffy/src/services/dartsv_crypto_service.dart';
import 'package:libspiffy/src/storage/in_memory_secure_storage.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';
import 'package:test/test.dart';

import 'in_memory_event_store.dart';

const _mnemonic = 'abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon abandon abandon about';
const _walletId = 'w-u0x-b';
const _address = 'mkHS9ne12qx9pS9VojpwU5xtRd4T7X7ZUt'; // testnet
const _wait = Duration(seconds: 5);

void main() {
  late TestActorSystem system;
  late _GatedEventStore store;
  late _Recorder recorder;
  late ActorRef recorderRef;

  setUp(() async {
    system = TestActorSystem();
    store = _GatedEventStore();
    recorder = _Recorder();
    recorderRef = await system.spawn('recorder', () => recorder);
  });

  tearDown(() => system.shutdown());

  test('WalletManagerActor: every command queued behind a failed journal write is answered, '
      'and the next one is served by a recovered aggregate', () async {
    final manager = await system.spawn(
      'wallet-manager',
      () => WalletManagerActor(
        eventStore: store,
        cryptoService: DartSVCryptoService(),
        secureStorage: InMemorySecureStorage(),
      ),
    );
    final created = await manager.ask<WalletCreatedMessage>(
      CreateWalletMessage(_walletId, 'Wallet u0x', mnemonic: _mnemonic),
      const Duration(seconds: 10),
    );
    expect(created.success, isTrue, reason: created.error);
    void send(String label) => manager.tell(
        WalletCommandMessage(_walletId, GenerateAddressCommand(walletId: _walletId, label: label)),
        sender: recorderRef);

    store.gate = Completer<void>();
    store.failPersist = true;
    send('first');
    await store.waitForBlockedWrite();
    send('queued-1');
    send('queued-2');
    // Routed by the manager into the aggregate's mailbox, behind 'first'.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    store.gate!.complete();

    // Old code: one reply; the two queued commands were dropped with the
    // stopped aggregate's mailbox.
    final replies = await recorder.waitForCount<AddressGeneratedResponse>(3);
    expect(replies.map((r) => r.success), [false, false, false]);
    expect(replies.first.error, contains('journal unavailable'));
    for (final queued in replies.skip(1)) {
      expect(queued.error, contains('not processed'));
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(recorder.received.whereType<AddressGeneratedResponse>(), hasLength(3), reason: 'one reply each');

    store.failPersist = false;
    send('after');
    final after = await recorder.waitForCount<AddressGeneratedResponse>(4);
    expect(after.last.success, isTrue, reason: after.last.error);
    expect(store.recoveries('BitcoinWallet_$_walletId'), 2);
  });

  test('InvoiceCoordinatorActor: every payment queued behind a failed journal write is answered', () async {
    final coordinator = await system.spawn(
      'invoice-coordinator',
      () => InvoiceCoordinatorActor(
        walletManager: recorderRef,
        storage: InMemoryWalletStorage(),
        eventStore: store,
      ),
    );
    coordinator.tell(
      CreateInvoiceMessage(
        walletId: 'w',
        outputs: [P2PKHOutputSpec(address: _address, amount: BigInt.from(5000))],
      ),
      sender: recorderRef,
    );
    final invoice = await recorder.waitForCount<InvoiceCreatedMessage>(1);
    expect(invoice.single.success, isTrue, reason: invoice.single.error);
    final invoiceId = invoice.single.invoiceId;
    await _eventually(() => store.allEvents.whereType<InvoiceCreatedEvent>().isNotEmpty);
    void pay(String txid) => coordinator.tell(
        MarkInvoicePaidMessage(
          invoiceId: invoiceId,
          txid: txid,
          amountReceived: BigInt.from(5000),
          addressesPaidTo: const [_address],
        ),
        sender: recorderRef);

    store.gate = Completer<void>();
    store.failPersist = true;
    pay('a' * 64);
    await store.waitForBlockedWrite();
    pay('b' * 64);
    pay('c' * 64);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    store.gate!.complete();

    // Old code: only the first payment was answered.
    final replies = await recorder.waitForCount<InvoiceStatusMessage>(3);
    expect(replies.map((r) => r.status), everyElement(InvoiceStatus.pending));
    expect(replies.first.statusMessage, contains('journal unavailable'));

    store.failPersist = false;
    pay('d' * 64);
    final paid = await recorder.waitFor<InvoiceStatusMessage>((m) => m.status == InvoiceStatus.paid);
    expect(paid.txid, 'd' * 64);
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
  void Function(dynamic message)? onReceive;

  @override
  Future<void> onMessage(dynamic message) async {
    onReceive?.call(message);
    received.add(message);
  }

  Future<List<T>> waitForCount<T>(int count) async {
    final deadline = DateTime.now().add(_wait);
    while (received.whereType<T>().length < count) {
      if (DateTime.now().isAfter(deadline)) {
        fail('expected $count $T within $_wait; received: $received');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    return received.whereType<T>().toList();
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

/// In-memory journal that counts recoveries and whose writes can be held at
/// a gate or made to fail.
class _GatedEventStore extends InMemoryEventStore {
  Completer<void>? gate;
  bool failPersist = false;
  int _blockedWrites = 0;
  final Map<String, int> _reads = {};

  int recoveries(String persistenceId) => _reads[persistenceId] ?? 0;

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
  Future<List<Event>> getEvents(String persistenceId, {int fromSequence = 0, int? toSequence}) {
    _reads[persistenceId] = recoveries(persistenceId) + 1;
    return super.getEvents(persistenceId, fromSequence: fromSequence, toSequence: toSequence);
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
