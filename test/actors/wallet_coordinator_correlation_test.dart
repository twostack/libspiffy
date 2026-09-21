/// WalletCoordinatorActor correlation and projection-await tests.
///
/// Covers audit findings (doc/audit-2026-09-14.md):
/// - A-M1: BEEF validation correlation was keyed by walletId, so two
///   concurrent ValidateBEEF requests for one wallet overwrote each other:
///   one caller got the other's result and the other got nothing.
/// - A-M2: the coordinator registered its projection awaiter only after the
///   SPV result arrived, so a TransactionImportedEvent the projection had
///   already applied was never seen (30 s timeout, success:false); and the
///   wait ran inside onMessage, blocking the public mailbox for up to 32 s.
///
/// The coordinator is built directly: a real SPVActor for the BEEF tests, a
/// real eventador ProjectionActor running the WalletProjection over
/// InMemoryWalletStorage for the "already applied" test, and probe actors
/// everywhere else.
import 'dart:async';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:dactor/dactor.dart';
import 'package:eventador/eventador.dart';
import 'package:test/test.dart';

import 'package:libspiffy/src/actors/coordinator_messages.dart';
import 'package:libspiffy/src/actors/spv_actor.dart';
import 'package:libspiffy/src/actors/wallet_coordinator_actor.dart';
import 'package:libspiffy/src/actors/wallet_messages.dart' as wm;
import 'package:libspiffy/src/core/wallet_events.dart' as domain;
import 'package:libspiffy/src/projections/wallet_projection.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';
import 'package:libspiffy/src/utils/beef.dart';

import 'in_memory_event_store.dart';

const _walletId = 'wallet-1';

// Two real testnet transactions (test/integration/full_spv_validation_test.dart).
const _tx1Hex =
    '02000000013706d29b641d2061b0b7b22c81ec6a5670104826bee4472a7513619f4fc298df000000006a473044022021fb2500cfd69bf3d7eee8f16d2e1d6d49528dbe23e9105744202bd9e5b5789102204ff801667c156b97e92209c19dce9bbdd955ee35cea7b815cf9e3b0c1b6727174121022036646b3fd79dee41351f727f0a6e10d0e7f98585961bc14e7aadaf5f4b66ab0100000002a0443b00000000001976a914f82d58dd8487044d8d0879c15a2a3516a425de2a88ac96000000000000001976a914f82d58dd8487044d8d0879c15a2a3516a425de2a88ac00000000';
const _tx1Id = 'dd6e7547df0fe893a9a19f66f0377eca72fdcd18fd9f6185fde9c91461a8e8a9';
const _tx2Hex =
    '020000000143fa91a1cc2b03e80646d2f15c0c75fd5a2e48270838d075f46e121a866dd3c4000000006a473044022031e9fe7d9279938ae04ccd543f620b99f7ccb9e755c4fd5de2f4d1053858db4802207c21fb144d19544ab934cd557936acb6bd67e99aa132f73a71e892609bfaabee4121022036646b3fd79dee41351f727f0a6e10d0e7f98585961bc14e7aadaf5f4b66ab0100000002f53c3b00000000001976a914f82d58dd8487044d8d0879c15a2a3516a425de2a88ac96000000000000001976a914f82d58dd8487044d8d0879c15a2a3516a425de2a88ac00000000';
const _tx2Id = 'fb4087a12b03caa64a687ae09a2ce36a22a9a4273f177d4e83e6f8095331369a';

/// A structurally valid BEEF holding one unproven transaction.
String _beefHexFor(String txHex) => hex.encode(BEEF
    .create(
      bumps: const [],
      txs: [Uint8List.fromList(hex.decode(txHex))],
      hasMerkle: const [false],
      bumpIndex: const [],
    )
    .serialize());

void main() {
  late ActorSystem actorSystem;
  late InMemoryWalletStorage storage;
  late List<CoordinatorEvent> events;
  late StreamSubscription<CoordinatorEvent> eventSub;

  Future<ActorRef> spawnCoordinator({
    required ActorRef spvActor,
    required ActorRef walletProjection,
  }) async {
    final noop = await actorSystem.spawn('noop', () => _ProbeActor());
    final coordinator = WalletCoordinatorActor(
      walletManager: noop,
      invoiceCoordinator: noop,
      paymentCoordinator: noop,
      spvActor: spvActor,
      arcActor: noop,
      headerSyncActor: noop,
      benfordCoordinator: noop,
      channelManager: noop,
      walletProjection: walletProjection,
      storage: storage,
    );
    eventSub = coordinator.events.listen(events.add);
    return actorSystem.spawn('coordinator', () => coordinator);
  }

  Future<T> nextEvent<T extends CoordinatorEvent>(
      bool Function(T e) where, Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      for (final e in events) {
        if (e is T && where(e)) return e;
      }
      await Future.delayed(const Duration(milliseconds: 10));
    }
    throw TimeoutException(
        'no $T within $timeout; events: ${events.map(_describe).toList()}',
        timeout);
  }

  setUp(() {
    actorSystem = LocalActorSystem();
    storage = InMemoryWalletStorage();
    events = [];
  });

  tearDown(() async {
    await eventSub.cancel();
    await actorSystem.shutdown();
  });

  group('A-M1: concurrent ValidateBEEF for one wallet', () {
    test('each request receives its own result', () async {
      final probe = await actorSystem.spawn('probe', () => _ProbeActor());
      final spv = await actorSystem.spawn(
        'spv-actor',
        () => SPVActor(
          walletManager: probe,
          invoiceCoordinator: probe,
          storage: storage,
        ),
      );
      final coordinator = await spawnCoordinator(
        spvActor: spv,
        walletProjection: probe,
      );

      // Both requests are in the coordinator's mailbox before either SPV
      // result, which is what two callers racing on one wallet looks like.
      coordinator.tell(ValidateBEEFCommand(
        walletId: _walletId,
        beefHex: _beefHexFor(_tx1Hex),
        invoiceId: 'invoice-1',
      ));
      coordinator.tell(ValidateBEEFCommand(
        walletId: _walletId,
        beefHex: _beefHexFor(_tx2Hex),
        invoiceId: 'invoice-2',
      ));

      final first = await nextEvent<BEEFValidationResultEvent>(
          (e) => e.invoiceId == 'invoice-1', const Duration(seconds: 5));
      final second = await nextEvent<BEEFValidationResultEvent>(
          (e) => e.invoiceId == 'invoice-2', const Duration(seconds: 5));

      expect(first.txid, equals(_tx1Id),
          reason: 'invoice-1 must get the result for its own BEEF');
      expect(second.txid, equals(_tx2Id),
          reason: 'invoice-2 must get the result for its own BEEF');
      expect(events.whereType<BEEFValidationResultEvent>(), hasLength(2));
    });

    test('a structurally invalid BEEF fails only its own request', () async {
      final probe = await actorSystem.spawn('probe', () => _ProbeActor());
      final spv = await actorSystem.spawn(
        'spv-actor',
        () => SPVActor(
          walletManager: probe,
          invoiceCoordinator: probe,
          storage: storage,
        ),
      );
      final coordinator = await spawnCoordinator(
        spvActor: spv,
        walletProjection: probe,
      );

      // A transaction flagged as proven with no BUMP to point at: SPVActor
      // rejects it at the structural step.
      final invalidBeefHex = hex.encode(BEEF
          .create(
            bumps: const [],
            txs: [Uint8List.fromList(hex.decode(_tx1Hex))],
            hasMerkle: const [true],
            bumpIndex: const [0],
          )
          .serialize());

      coordinator.tell(ValidateBEEFCommand(
        walletId: _walletId,
        beefHex: invalidBeefHex,
        invoiceId: 'invoice-bad',
      ));
      coordinator.tell(ValidateBEEFCommand(
        walletId: _walletId,
        beefHex: _beefHexFor(_tx2Hex),
        invoiceId: 'invoice-good',
      ));

      final bad = await nextEvent<BEEFValidationResultEvent>(
          (e) => e.txid == null, const Duration(seconds: 5));
      final good = await nextEvent<BEEFValidationResultEvent>(
          (e) => e.txid == _tx2Id, const Duration(seconds: 5));

      expect(bad.invoiceId, equals('invoice-bad'));
      expect(bad.valid, isFalse);
      expect(good.invoiceId, equals('invoice-good'));
    });
  });

  group('A-M2: projection awaiter for imported transactions', () {
    test('an event the projection applied before the awaiter registers '
        'resolves immediately', () async {
      final eventStream = _InMemoryEventStream();
      final projection = await actorSystem.spawn(
        'projection-wallet',
        () => ProjectionActor(
          WalletProjection(
            projectionId: 'wallet-projection',
            eventStore: InMemoryEventStore(),
            storage: storage,
          ),
          eventStream,
        ),
      );
      final probe = await actorSystem.spawn('probe', () => _ProbeActor());
      final coordinator = await spawnCoordinator(
        spvActor: probe,
        walletProjection: projection,
      );

      // The wallet aggregate persisted TransactionImportedEvent and the
      // projection applied it before the coordinator saw the SPV result
      // (e.g. its mailbox was busy).
      eventStream.emit(_importedEvent(_tx1Id, _tx1Hex), 1);
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (await storage.getTransaction(_tx1Id) == null) {
        if (DateTime.now().isAfter(deadline)) fail('projection never applied');
        await Future.delayed(const Duration(milliseconds: 10));
      }

      // An import: its BEEF carried the subject's proof (a payment is
      // answered with BEEFValidationResultEvent instead).
      coordinator.tell(wm.SPVValidationResult(
        txid: _tx1Id,
        isValid: true,
        targetWalletId: _walletId,
        subjectCarriesProof: true,
      ));

      final imported = await nextEvent<TransactionImportedEvent>(
          (e) => e.transactionId == _tx1Id, const Duration(seconds: 3));
      expect(imported.success, isTrue, reason: imported.error);
      await eventStream.close();
    });

    test('the coordinator answers other messages while an import awaits the '
        'projection', () async {
      // A projection that never answers: the import's wait can only end by
      // timeout.
      final silentProjection =
          await actorSystem.spawn('projection-silent', () => _ProbeActor());
      final probe = await actorSystem.spawn('probe', () => _ProbeActor());
      final coordinator = await spawnCoordinator(
        spvActor: probe,
        walletProjection: silentProjection,
      );

      // An import: its BEEF carried the subject's proof (a payment is
      // answered with BEEFValidationResultEvent instead).
      coordinator.tell(wm.SPVValidationResult(
        txid: _tx1Id,
        isValid: true,
        targetWalletId: _walletId,
        subjectCarriesProof: true,
      ));
      coordinator.tell(GetTransactionDetailQuery(
        walletId: _walletId,
        txid: _tx2Id,
      ));

      final detail = await nextEvent<TransactionDetailResponse>(
          (e) => e.walletId == _walletId, const Duration(seconds: 2));
      expect(detail.found, isFalse);
      expect(
          events.whereType<TransactionImportedEvent>(), isEmpty,
          reason: 'the import is still waiting on the projection');
    });
  });
}

domain.TransactionImportedEvent _importedEvent(String txid, String rawHex) =>
    domain.TransactionImportedEvent(
      walletId: _walletId,
      txid: txid,
      rawHex: rawHex,
      blockHeight: null,
      bumpProof: '',
      totalOutputSats: 1000,
      numInputs: 1,
      numOutputs: 2,
      txVersion: 2,
      txLockTime: 0,
      walletReceivingAddresses: const [],
      walletReceivedSats: 1000,
      totalInputSats: 0,
      sendingAddresses: const [],
    );

String _describe(CoordinatorEvent e) {
  if (e is BEEFValidationResultEvent) {
    return 'BEEFValidationResultEvent(invoice=${e.invoiceId}, txid=${e.txid}, '
        'valid=${e.valid}, error=${e.error})';
  }
  if (e is TransactionImportedEvent) {
    return 'TransactionImportedEvent(${e.transactionId}, success=${e.success}, '
        'error=${e.error})';
  }
  if (e is ErrorEvent) return 'ErrorEvent(${e.source}: ${e.message})';
  return e.runtimeType.toString();
}

/// Records every message; answers nothing.
class _ProbeActor extends Actor {
  final List<dynamic> received = [];

  @override
  Future<void> onMessage(dynamic message) async {
    received.add(message);
  }
}

/// Manual `(Event, sequence)` stream for a ProjectionActor (same double as
/// eventador's own projection_actor_test.dart).
class _InMemoryEventStream implements EventStream {
  final StreamController<(Event, int)> _controller =
      StreamController<(Event, int)>.broadcast();

  void emit(Event event, int envelopeId) =>
      _controller.add((event, envelopeId));

  Future<void> close() => _controller.close();

  @override
  Stream<(Event, int)> allEventsWithSequence(
          {int fromSequence = 0, bool live = true}) =>
      _controller.stream.where((record) => record.$2 > fromSequence);

  @override
  Stream<Event> allEvents({int fromSequence = 0, bool live = true}) =>
      allEventsWithSequence(fromSequence: fromSequence, live: live)
          .map((r) => r.$1);

  @override
  Stream<Event> eventsByTag(String tag,
          {int fromSequence = 0, bool live = true}) =>
      allEvents(fromSequence: fromSequence, live: live);

  @override
  Stream<Event> eventsByPersistenceId(String persistenceId,
          {int fromSequence = 0, bool live = true}) =>
      allEvents(fromSequence: fromSequence, live: live);

  @override
  Stream<String> currentPersistenceIds() => const Stream.empty();
}
