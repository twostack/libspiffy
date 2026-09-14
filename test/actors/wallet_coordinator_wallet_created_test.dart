/// WalletCoordinatorActor: WalletCreatedEvent waits for the read model
/// (libspiffy-p56).
///
/// The coordinator emitted WalletCreatedEvent as soon as WalletManagerActor
/// replied, before the wallet projection had written the wallet row and its
/// root address. A caller that imported a transaction right after the event
/// raced SPVActor.isWalletAddress against the projection and intermittently
/// lost the wallet's outputs (import_transaction_command_test, ~1 in 12).
///
/// The projection here is a real eventador ProjectionActor running the
/// WalletProjection over storage whose writes block on a gate, so "the
/// projection has not applied WalletCreated yet" is a state the test holds
/// for as long as it likes instead of a timing window.
import 'dart:async';

import 'package:dactor/dactor.dart';
import 'package:eventador/eventador.dart';
import 'package:test/test.dart';

import 'package:libspiffy/src/actors/coordinator_messages.dart';
import 'package:libspiffy/src/actors/wallet_coordinator_actor.dart';
import 'package:libspiffy/src/actors/wallet_messages.dart' as wm;
import 'package:libspiffy/src/core/wallet_events.dart' as domain;
import 'package:libspiffy/src/models/address_metadata.dart';
import 'package:libspiffy/src/models/wallet_type.dart';
import 'package:libspiffy/src/projections/wallet_projection.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';

import 'in_memory_event_store.dart';

const _walletId = 'wallet-p56';
const _rootAddress = 'mqCnSf8i6kmaQaJ54HjQ8EUJnuK4AnCv12';

void main() {
  late ActorSystem actorSystem;
  late _GatedStorage storage;
  late _InMemoryEventStream eventStream;
  late List<CoordinatorEvent> events;
  late StreamSubscription<CoordinatorEvent> eventSub;

  Future<ActorRef> spawnCoordinator({
    required ActorRef walletManager,
    required ActorRef walletProjection,
  }) async {
    final noop = await actorSystem.spawn('noop', () => _ProbeActor());
    final coordinator = WalletCoordinatorActor(
      walletManager: walletManager,
      invoiceCoordinator: noop,
      paymentCoordinator: noop,
      spvActor: noop,
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

  Future<T> nextEvent<T extends CoordinatorEvent>(Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final match = events.whereType<T>();
      if (match.isNotEmpty) return match.first;
      await Future.delayed(const Duration(milliseconds: 10));
    }
    throw TimeoutException('no $T within $timeout', timeout);
  }

  /// Every message the coordinator received before this call has been
  /// handled once this returns (its mailbox is FIFO).
  Future<void> drainCoordinator(ActorRef coordinator) async {
    final before = events.whereType<TransactionDetailResponse>().length;
    coordinator.tell(GetTransactionDetailQuery(walletId: 'barrier', txid: 'x'));
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (events.whereType<TransactionDetailResponse>().length == before) {
      if (DateTime.now().isAfter(deadline)) fail('coordinator never drained');
      await Future.delayed(const Duration(milliseconds: 5));
    }
  }

  setUp(() {
    actorSystem = LocalActorSystem();
    storage = _GatedStorage();
    eventStream = _InMemoryEventStream();
    events = [];
  });

  tearDown(() async {
    storage.open();
    await eventSub.cancel();
    await actorSystem.shutdown();
    await eventStream.close();
  });

  test('WalletCreatedEvent is emitted only after the projection wrote the '
      'wallet and its root address', () async {
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
    final walletManager = await actorSystem.spawn(
      'wallet-manager',
      () => _CreatingWalletManager(eventStream),
    );
    final coordinator = await spawnCoordinator(
      walletManager: walletManager,
      walletProjection: projection,
    );

    coordinator.tell(CreateWalletCommand(walletId: _walletId, name: 'P56'));

    // The aggregate persisted WalletCreated and the manager replied; the
    // projection is now blocked inside its first read-model write.
    await storage.entered.future.timeout(const Duration(seconds: 5));
    await drainCoordinator(coordinator);

    expect(await storage.isWalletAddress(_walletId, _rootAddress), isFalse,
        reason: 'precondition: the projection has not written the address');
    expect(events.whereType<WalletCreatedEvent>(), isEmpty,
        reason: 'WalletCreatedEvent was emitted while the read model had no '
            'row for the wallet or its root address');

    storage.open();

    final created =
        await nextEvent<WalletCreatedEvent>(const Duration(seconds: 5));
    expect(created.success, isTrue, reason: created.error);
    expect(created.rootAddress, _rootAddress);
    expect(await storage.isWalletAddress(_walletId, _rootAddress), isTrue);
    expect(await storage.getWallet(_walletId), isNotNull);
  });

  test('a creation the projection applied before the coordinator saw the '
      'reply is reported at once', () async {
    storage.open();
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
    final walletManager = await actorSystem.spawn(
      'wallet-manager',
      () => _CreatingWalletManager(eventStream, replyAfter: () async {
        // Reply only once the row exists: the awaiter registered afterwards
        // can no longer see the event.
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        while (await storage.getWallet(_walletId) == null) {
          if (DateTime.now().isAfter(deadline)) return;
          await Future.delayed(const Duration(milliseconds: 5));
        }
      }),
    );
    final coordinator = await spawnCoordinator(
      walletManager: walletManager,
      walletProjection: projection,
    );

    coordinator.tell(CreateWalletCommand(walletId: _walletId, name: 'P56'));

    final created =
        await nextEvent<WalletCreatedEvent>(const Duration(seconds: 3));
    expect(created.success, isTrue, reason: created.error);
  });

  test('a failed creation is reported without waiting on the projection',
      () async {
    // A projection that never answers: any wait on it would time out.
    final silentProjection =
        await actorSystem.spawn('projection-silent', () => _ProbeActor());
    final walletManager = await actorSystem.spawn(
      'wallet-manager',
      () => _FailingWalletManager(),
    );
    final coordinator = await spawnCoordinator(
      walletManager: walletManager,
      walletProjection: silentProjection,
    );

    coordinator.tell(CreateWalletCommand(walletId: _walletId, name: 'P56'));

    final created =
        await nextEvent<WalletCreatedEvent>(const Duration(seconds: 2));
    expect(created.success, isFalse);
    expect(created.error, 'Wallet already exists');
  });
}

/// Stands in for WalletManagerActor + the wallet aggregate: persists
/// WalletCreated (to the projection's stream) and replies success.
class _CreatingWalletManager extends Actor {
  final _InMemoryEventStream stream;
  final Future<void> Function()? replyAfter;
  _CreatingWalletManager(this.stream, {this.replyAfter});

  @override
  Future<void> onMessage(dynamic message) async {
    if (message is! wm.CreateWalletMessage) return;
    stream.emit(
      domain.WalletCreatedEvent(
        walletId: message.walletId,
        walletName: message.name,
        rootAddress: _rootAddress,
        walletType: WalletType.hd,
        walletMetadata: const {'network': 'test'},
      ),
      1,
    );
    final sender = context.sender;
    await replyAfter?.call();
    sender?.tell(LocalMessage(
      payload: wm.WalletCreatedMessage(message.walletId, _rootAddress, true),
    ));
  }
}

class _FailingWalletManager extends Actor {
  @override
  Future<void> onMessage(dynamic message) async {
    if (message is! wm.CreateWalletMessage) return;
    context.sender?.tell(LocalMessage(
      payload: wm.WalletCreatedMessage(message.walletId, '', false,
          error: 'Wallet already exists'),
    ));
  }
}

/// In-memory read model whose address and wallet writes wait for [open].
class _GatedStorage extends InMemoryWalletStorage {
  final Completer<void> _gate = Completer<void>();
  final Completer<void> entered = Completer<void>();

  void open() {
    if (!_gate.isCompleted) _gate.complete();
  }

  Future<void> _pass() async {
    if (!entered.isCompleted) entered.complete();
    await _gate.future;
  }

  @override
  Future<void> upsertAddress(String walletId, AddressMetadata metadata) async {
    await _pass();
    return super.upsertAddress(walletId, metadata);
  }

  @override
  Future<void> storeWallet(
    String walletId,
    String name, {
    String? rootAddress,
    String? networkType,
    Map<String, dynamic>? metadata,
  }) async {
    await _pass();
    return super.storeWallet(walletId, name,
        rootAddress: rootAddress, networkType: networkType, metadata: metadata);
  }
}

/// Records nothing, answers nothing.
class _ProbeActor extends Actor {
  @override
  Future<void> onMessage(dynamic message) async {}
}

/// Manual `(Event, sequence)` stream for a ProjectionActor.
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
