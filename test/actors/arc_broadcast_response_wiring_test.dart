/// Bead libspiffy-f0sj (sweep D-2), the wiring half.
///
/// `test/core/broadcast_response_recorded_test.dart` proves the aggregate
/// records whatever `BroadcastTransactionCommand.broadcastResponse` carries.
/// That is only worth something if something actually fills it in, and the
/// whole point of the libspiffy-1kd5 sweep is that a capability nothing
/// reaches reads exactly like a finished one. This drives ARCActor's broadcast
/// path over an ARC stand-in and asserts ARC's real answer reaches the journal.
library;

import 'dart:async';

import 'package:dactor/dactor.dart';
import 'package:eventador/eventador.dart';
import 'package:libspiffy/src/actors/arc_actor.dart';
import 'package:libspiffy/src/actors/wallet_manager_actor.dart';
import 'package:libspiffy/src/actors/wallet_messages.dart';
import 'package:libspiffy/src/core/wallet_events.dart';
import 'package:libspiffy/src/services/arc_service.dart';
import 'package:libspiffy/src/services/dartsv_crypto_service.dart';
import 'package:libspiffy/src/storage/in_memory_secure_storage.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';
import 'package:test/test.dart';

import 'in_memory_event_store.dart';

const _xpriv =
    'tprv8ZgxMBicQKsPeMiDjtXBGAyFY1wEMGgomjwf54ZmiZfKTNYvVdBa6GqWUwnvtHm6NKVkQkhCKxaobd9JPxNEXgDfVgJ5RNHJ3ivogSG3V1R';
const _walletId = 'f0sj-wiring';
final _txid = 'ab' * 32;
const _wait = Duration(seconds: 10);

void main() {
  late LocalActorSystem system;
  late InMemoryEventStore eventStore;
  late InMemoryWalletStorage readModel;
  late _StatusArc arc;
  late ActorRef walletManager;

  setUp(() async {
    system = LocalActorSystem(ActorSystemConfig());
    eventStore = InMemoryEventStore();
    readModel = InMemoryWalletStorage();
    arc = _StatusArc();
    walletManager = await system.spawn(
      'wallet-manager',
      () => WalletManagerActor(
        eventStore: eventStore,
        cryptoService: DartSVCryptoService(),
        secureStorage: InMemorySecureStorage(),
        aggregateIdleTimeout: null,
        readModelStorage: readModel,
      ),
    );
    final created = await walletManager.ask<WalletCreatedMessage>(
      CreateWalletMessage(_walletId, 'f0sj', xpriv: _xpriv),
      _wait,
    );
    expect(created.success, isTrue, reason: created.error);
  });

  tearDown(() => system.shutdown());

  List<Event> journal() => eventStore.journal['BitcoinWallet_$_walletId'] ?? const [];

  Future<TransactionBroadcastEvent> broadcastWith(String arcStatus) async {
    arc.status = arcStatus;
    final arcActor = await system.spawn(
      'arc-${DateTime.now().microsecondsSinceEpoch}',
      () => ARCActor(
        walletManager: walletManager,
        storage: readModel,
        arcService: arc,
        statusCheckInterval: const Duration(minutes: 10),
      ),
    );
    arcActor.tell(BroadcastTransactionMessage(_walletId, '00', _txid));

    final deadline = DateTime.now().add(_wait);
    while (DateTime.now().isBefore(deadline)) {
      final events = journal().whereType<TransactionBroadcastEvent>();
      if (events.isNotEmpty) return events.single;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    fail('no TransactionBroadcastEvent was journaled within $_wait');
  }

  test("ARC's answer reaches the journal, not a constant", () async {
    final event = await broadcastWith('SEEN_ON_NETWORK');
    expect(event.txid, _txid);
    expect(event.broadcastResponse, 'SEEN_ON_NETWORK',
        reason: 'ARCActor must pass what ARC answered into the command');
  });

  test('a different ARC answer produces a different record', () async {
    // The real guard: a hard-coded string passes the test above by accident.
    final event = await broadcastWith('DOUBLE_SPEND_ATTEMPTED');
    expect(event.broadcastResponse, 'DOUBLE_SPEND_ATTEMPTED');
  });
}

/// An ARC that answers with [status] and never touches a network. It does not
/// parse the hex it is given: this lane is about what is recorded, not about
/// transaction building.
class _StatusArc extends ArcService {
  _StatusArc() : super(baseUrl: 'fake://arc');

  String status = 'SEEN_ON_NETWORK';

  @override
  Future<ArcSubmitResponse> submitTransaction(String rawTx, {String? callbackUrl}) async =>
      ArcSubmitResponse.fromJson({'txid': _txid, 'txStatus': status});

  @override
  Future<ArcTransactionResponse> getTransaction(String txid) async =>
      throw ArcException('Failed to get transaction: {"status":404}', statusCode: 404);
}
