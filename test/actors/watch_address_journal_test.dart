/// libspiffy-p4kv: watch addresses were not journaled.
///
/// WalletCoordinatorActor wrote a RegisterWatchAddressCommand straight into
/// the read model; no event reached the wallet's journal. A read model
/// rebuilt from the journal (fresh storage, every event replayed through
/// WalletProjection, or a move to another backend) had no watch addresses,
/// and since the wallet aggregate answers attribution from its own state
/// (bead 29t) a payment to a watch address was not credited unless the read
/// model still happened to hold the row.
///
/// The stack here is the real one minus the network: WalletManagerActor,
/// SPVActor, WalletCoordinatorActor and a ProjectionActor running
/// WalletProjection, over an in-memory journal whose appends feed the
/// projection's event stream.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:dactor/dactor.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:eventador/eventador.dart';
import 'package:libspiffy/src/actors/coordinator_messages.dart'
    show CoordinatorEvent, RegisterWatchAddressCommand, WatchAddressRegisteredEvent;
import 'package:libspiffy/src/actors/spv_actor.dart';
import 'package:libspiffy/src/actors/wallet_coordinator_actor.dart';
import 'package:libspiffy/src/actors/wallet_manager_actor.dart';
import 'package:libspiffy/src/actors/wallet_messages.dart';
import 'package:libspiffy/src/actors/libspiffy_actor_system.dart';
import 'package:libspiffy/src/core/wallet_commands.dart' show GenerateAddressCommand;
import 'package:libspiffy/src/core/wallet_events.dart';
import 'package:libspiffy/src/projections/wallet_projection.dart';
import 'package:libspiffy/src/services/dartsv_crypto_service.dart';
import 'package:libspiffy/src/storage/in_memory_secure_storage.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';
import 'package:libspiffy/src/utils/beef.dart';
import 'package:test/test.dart';

import '../spv/testnet_proof_fixture.dart';
import 'in_memory_event_store.dart';

/// The key the fixture transaction's output 1 pays.
const _payerXpriv =
    'tprv8ZgxMBicQKsPeMiDjtXBGAyFY1wEMGgomjwf54ZmiZfKTNYvVdBa6GqWUwnvtHm6NKVkQkhCKxaobd9JPxNEXgDfVgJ5RNHJ3ivogSG3V1R';
const _payerRootAddress = 'mqCnSf8i6kmaQaJ54HjQ8EUJnuK4AnCv12';
const _mnemonic = 'legal winner thank year wave sausage worth useful legal winner thank yellow';
const _walletId = 'watcher';

void main() {
  final payerKey = dartsv.HDPrivateKey.fromXpriv(_payerXpriv)
      .deriveChildNumber(0)
      .deriveChildNumber(0)
      .privateKey;
  // A key the wallet does not hold: its address is what gets watched.
  final watchAddress =
      dartsv.SVPrivateKey.fromHex('22' * 32, dartsv.NetworkType.TEST).publicKey.toAddress(dartsv.NetworkType.TEST).toBase58();
  final g = dartsv.Transaction.fromHex(kFixtureTxHex);

  /// An unproven payment of the fixture's output 1 (2 BSV) to [address],
  /// with the fixture as its proven ancestor.
  (String txid, BEEF beef) paymentTo(String address) {
    final out = g.outputs[1];
    final tx = (dartsv.TransactionBuilder()
          ..spendFromOutpointWithSigner(
            dartsv.DefaultTransactionSigner(
                dartsv.SighashType.SIGHASH_ALL.value | dartsv.SighashType.SIGHASH_FORKID.value, payerKey),
            dartsv.TransactionOutpoint(g.id, 1, out.satoshis, out.script),
            dartsv.TransactionInput.MAX_SEQ_NUMBER,
            dartsv.P2PKHUnlockBuilder(payerKey.publicKey),
          )
          ..spendToLockBuilder(dartsv.P2PKHLockBuilder.fromAddress(dartsv.Address(address)), BigInt.from(150000000))
          ..spendToLockBuilder(
              dartsv.P2PKHLockBuilder.fromAddress(dartsv.Address(_payerRootAddress)), BigInt.from(49990000))
          ..withOption(dartsv.TransactionOption.DISABLE_DUST_OUTPUTS))
        .build(false);
    Uint8List bytes(String h) => Uint8List.fromList(hex.decode(h));
    return (
      tx.id,
      BEEF.create(
        bumps: [fixtureBump()],
        txs: [bytes(kFixtureTxHex), bytes(tx.serialize())],
        hasMerkle: [true, false],
        bumpIndex: [0],
      ),
    );
  }

  setUpAll(LibSpiffyActorSystem.registerEventTypes);

  late _StreamingEventStore journal;
  late InMemoryWalletStorage readModel;
  late LocalActorSystem system;
  late ActorRef walletManager;
  late ActorRef coordinator;
  late List<CoordinatorEvent> coordinatorEvents;
  final systems = <LocalActorSystem>[];

  Future<InMemoryWalletStorage> headersOnly() async {
    final storage = InMemoryWalletStorage();
    await storage.storeBlockHeader(fixtureHeader(), kFixtureHeight);
    return storage;
  }

  setUp(() async {
    journal = _StreamingEventStore();
    readModel = await headersOnly();
    system = LocalActorSystem(ActorSystemConfig());
    systems.add(system);
    final projection = await system.spawn(
      'wallet-projection',
      () => ProjectionActor(
        WalletProjection(projectionId: 'wallet', eventStore: journal, storage: readModel),
        journal,
      ),
    );
    walletManager = await system.spawn(
      'wallet-manager',
      () => WalletManagerActor(
        eventStore: journal,
        cryptoService: DartSVCryptoService(),
        secureStorage: InMemorySecureStorage(),
        aggregateIdleTimeout: null,
      ),
    );
    final sink = await system.spawn('sink', () => _Sink());
    final spv = await system.spawn(
      'spv',
      () => SPVActor(walletManager: walletManager, invoiceCoordinator: sink, storage: readModel),
    );
    coordinatorEvents = [];
    final actor = WalletCoordinatorActor(
      walletManager: walletManager,
      invoiceCoordinator: sink,
      paymentCoordinator: sink,
      spvActor: spv,
      arcActor: sink,
      headerSyncActor: sink,
      benfordCoordinator: sink,
      channelManager: sink,
      walletProjection: projection,
      storage: readModel,
    );
    actor.events.listen(coordinatorEvents.add);
    coordinator = await system.spawn('coordinator', () => actor);

    final created = await walletManager.ask<WalletCreatedMessage>(
      CreateWalletMessage(_walletId, _walletId, mnemonic: _mnemonic),
      const Duration(seconds: 10),
    );
    expect(created.success, isTrue, reason: created.error);
  });

  tearDown(() async {
    for (final s in systems) {
      await s.shutdown();
    }
    systems.clear();
  });

  Future<T> next<T extends CoordinatorEvent>(bool Function(T e) where) async {
    final deadline = DateTime.now().add(const Duration(seconds: 40));
    while (DateTime.now().isBefore(deadline)) {
      final match = coordinatorEvents.whereType<T>().where(where);
      if (match.isNotEmpty) return match.first;
      await Future.delayed(const Duration(milliseconds: 10));
    }
    fail('no $T');
  }

  Future<void> registerWatch(String address, {String? label}) async {
    final before = coordinatorEvents.whereType<WatchAddressRegisteredEvent>().length;
    coordinator.tell(RegisterWatchAddressCommand(
      walletId: _walletId,
      address: address,
      scriptType: 'p2pkh',
      label: label,
    ));
    final registered = await next<WatchAddressRegisteredEvent>(
        (e) => coordinatorEvents.whereType<WatchAddressRegisteredEvent>().toList().indexOf(e) >= before);
    expect(registered.success, isTrue, reason: registered.error);
  }

  List<Event> walletJournal() => journal.journal['BitcoinWallet_$_walletId'] ?? const [];

  /// A read model rebuilt from the journal: fresh storage holding the
  /// header, every journal event of the wallet replayed through
  /// WalletProjection.
  Future<InMemoryWalletStorage> rebuildFromJournal() async {
    final fresh = await headersOnly();
    final projection = WalletProjection(projectionId: 'rebuild', eventStore: journal, storage: fresh);
    for (final event in walletJournal()) {
      await projection.handle(event);
    }
    return fresh;
  }

  /// A second process on the same journal: a wallet manager that loads the
  /// wallet from the journal and an SPVActor whose read model is [storage].
  Future<(ActorRef manager, ActorRef spv)> restart(InMemoryWalletStorage storage) async {
    await system.shutdown();
    systems.remove(system);
    final second = LocalActorSystem(ActorSystemConfig());
    systems.add(second);
    final manager = await second.spawn(
      'wallet-manager',
      () => WalletManagerActor(
        eventStore: journal,
        cryptoService: DartSVCryptoService(),
        secureStorage: InMemorySecureStorage(),
        aggregateIdleTimeout: null,
      ),
    );
    final sink = await second.spawn('sink', () => _Sink());
    final spv = await second.spawn(
      'spv',
      () => SPVActor(walletManager: manager, invoiceCoordinator: sink, storage: storage),
    );
    return (manager, spv);
  }

  test('a registered watch address is in a read model rebuilt from the journal', () async {
    await registerWatch(watchAddress, label: 'cold storage');
    expect((await readModel.getAddressMetadata(_walletId, watchAddress))?.purpose, 'watch',
        reason: 'the coordinator reports success once the read model has the row');

    final rebuilt = await rebuildFromJournal();
    final row = await rebuilt.getAddressMetadata(_walletId, watchAddress);
    expect(row, isNotNull, reason: 'the watch address must survive a rebuild of the read model from the journal');
    expect(row!.purpose, 'watch');
    expect(row.label, 'cold storage');
    expect(row.scriptType, 'p2pkh');
    expect(await rebuilt.isWalletAddress(_walletId, watchAddress), isTrue);
  });

  test('after a restart on a read model that never learned the watch address, the wallet owns it and a payment to it is credited',
      () async {
    await registerWatch(watchAddress);
    final (manager, spv) = await restart(await headersOnly());

    final owned = await manager.ask<WalletOwnershipResponse>(
      WalletOwnershipQuery(walletId: _walletId, addresses: {watchAddress}, outpoints: const {}),
      const Duration(seconds: 10),
    );
    expect(owned.ownedAddresses, {watchAddress},
        reason: 'the wallet aggregate answers for its watch addresses from its journal-backed state');

    final (txid, beef) = paymentTo(watchAddress);
    final done = Completer<SPVValidationResult>();
    final receiver = await systems.last.spawn('receiver', () => _Receiver(done));
    spv.tell(
      ReceiveTransactionMessage(transactionId: txid, beef: beef, fromCounterparty: 'payer', targetWalletId: _walletId),
      sender: receiver,
    );
    final result = await done.future.timeout(const Duration(seconds: 20));
    expect(result.isValid, isTrue, reason: result.validationError);

    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (!walletJournal().whereType<TransactionImportedEvent>().any((e) => e.txid == txid)) {
      if (DateTime.now().isAfter(deadline)) fail('the wallet never recorded $txid');
      await Future.delayed(const Duration(milliseconds: 10));
    }
    expect(
      [for (final e in walletJournal().whereType<UTXOReceivedEvent>().where((e) => e.txid == txid)) (e.vout, e.address)],
      [(0, watchAddress)],
      reason: 'the output paying the watch address is credited',
    );
  });

  test('registering an address the wallet already derives leaves its row (derivation index, purpose) intact',
      () async {
    final generated = await walletManager.ask<AddressGeneratedResponse>(
      WalletCommandMessage(_walletId, GenerateAddressCommand(walletId: _walletId)),
      const Duration(seconds: 10),
    );
    expect(generated.success, isTrue, reason: generated.error);
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (await readModel.getAddressMetadata(_walletId, generated.address) == null) {
      if (DateTime.now().isAfter(deadline)) fail('address never projected');
      await Future.delayed(const Duration(milliseconds: 10));
    }

    await registerWatch(generated.address, label: 'mine');

    final row = await readModel.getAddressMetadata(_walletId, generated.address);
    expect(row!.derivationIndex, generated.derivationIndex,
        reason: 'signing reads the derivation index from this row; losing it signs with the wrong key');
    expect(row.purpose, isNot('watch'));
  });
}

/// An in-memory journal that is also the projection's event stream.
class _StreamingEventStore implements EventStore, EventStream {
  final _store = InMemoryEventStore();
  final _controller = StreamController<(Event, int)>.broadcast(sync: true);
  var _sequence = 0;

  Map<String, List<Event>> get journal => _store.journal;

  @override
  Future<void> persistEvent(String persistenceId, Event event, int expectedVersion) async {
    await _store.persistEvent(persistenceId, event, expectedVersion);
    _controller.add((event, ++_sequence));
  }

  @override
  Future<void> persistEvents(String persistenceId, List<Event> events, int expectedVersion) async {
    await _store.persistEvents(persistenceId, events, expectedVersion);
    for (final event in events) {
      _controller.add((event, ++_sequence));
    }
  }

  @override
  Future<List<Event>> getEvents(String persistenceId, {int fromSequence = 0, int? toSequence}) =>
      _store.getEvents(persistenceId, fromSequence: fromSequence, toSequence: toSequence);

  @override
  Future<int> getHighestSequenceNumber(String persistenceId) => _store.getHighestSequenceNumber(persistenceId);

  @override
  Future<void> saveSnapshot(String persistenceId, dynamic state, int sequenceNumber) async {}

  @override
  Future<SnapshotData?> loadSnapshot(String persistenceId) async => null;

  @override
  Future<void> deleteOldSnapshots(String persistenceId, int keepCount) async {}

  @override
  Future<void> close() async {}

  @override
  Stream<(Event, int)> allEventsWithSequence({int fromSequence = 0, bool live = true}) =>
      _controller.stream.where((r) => r.$2 > fromSequence);

  @override
  Stream<Event> allEvents({int fromSequence = 0, bool live = true}) =>
      allEventsWithSequence(fromSequence: fromSequence, live: live).map((r) => r.$1);

  @override
  Stream<Event> eventsByTag(String tag, {int fromSequence = 0, bool live = true}) =>
      allEvents(fromSequence: fromSequence, live: live);

  @override
  Stream<Event> eventsByPersistenceId(String persistenceId, {int fromSequence = 0, bool live = true}) =>
      allEvents(fromSequence: fromSequence, live: live);

  @override
  Stream<String> currentPersistenceIds() => const Stream.empty();
}

class _Sink extends Actor {
  @override
  Future<void> onMessage(dynamic message) async {}
}

class _Receiver extends Actor {
  final Completer<SPVValidationResult> done;
  _Receiver(this.done);

  @override
  Future<void> onMessage(dynamic message) async {
    if (message is SPVValidationResult && !done.isCompleted) done.complete(message);
  }
}
