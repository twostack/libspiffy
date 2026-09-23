/// Bead libspiffy-hzkf: an app told a payment confirmed is told when the
/// chain takes it back.
///
/// The wallet already did the right thing on a reorganization — the
/// transaction goes back to unconfirmed, its outputs stop being spendable,
/// the proof of the block that left is kept and marked orphaned — and said
/// nothing about it. `TransactionConfirmedEvent` was announced from the read
/// model and had no counterpart, so an application that shipped goods on a
/// confirmation could only find out by asking again.
///
/// Both announcements come from the same place: the events the wallet
/// projection applied (V-153's `readModelEvents`), so what an app hears is
/// what the read model holds, not what some actor hoped it would hold.
library;

import 'dart:async';

import 'package:dactor/dactor.dart';
import 'package:eventador/eventador.dart';
import 'package:test/test.dart';

import 'package:libspiffy/src/actors/coordinator_messages.dart';
import 'package:libspiffy/src/actors/wallet_coordinator_actor.dart';
import 'package:libspiffy/src/core/wallet_events.dart' as domain;
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';

const _walletId = 'wallet-hzkf';
const _txid = 'cc11';
const _blockHash = '0000000000000000000000000000000000000000000000000000000000000abc';

void main() {
  late ActorSystem actorSystem;
  late StreamController<Event> readModel;
  late List<CoordinatorEvent> announced;
  late StreamSubscription<CoordinatorEvent> sub;

  setUp(() async {
    actorSystem = LocalActorSystem();
    readModel = StreamController<Event>.broadcast();
    announced = [];

    final noop = await actorSystem.spawn('noop', () => _Noop());
    final coordinator = WalletCoordinatorActor(
      walletManager: noop,
      invoiceCoordinator: noop,
      paymentCoordinator: noop,
      spvActor: noop,
      arcActor: noop,
      headerSyncActor: noop,
      benfordCoordinator: noop,
      channelManager: noop,
      walletProjection: noop,
      storage: InMemoryWalletStorage(),
      readModelEvents: readModel.stream,
    );
    sub = coordinator.events.listen(announced.add);
    await actorSystem.spawn('coordinator', () => coordinator);
  });

  tearDown(() async {
    await sub.cancel();
    await readModel.close();
    await actorSystem.shutdown();
  });

  /// What the coordinator announced, once it has had a turn.
  Future<List<T>> heard<T extends CoordinatorEvent>() async {
    final deadline = DateTime.now().add(const Duration(milliseconds: 500));
    while (announced.whereType<T>().isEmpty && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    return announced.whereType<T>().toList();
  }

  test('the block a confirmation rested on left the chain: the app is told', () async {
    readModel.add(domain.TransactionConfirmationRevertedEvent(
      walletId: _walletId,
      txid: _txid,
      blockHeight: 15000,
      blockHash: _blockHash,
      reason: 'reorganization at height 14999: headerMismatch',
    ));

    final reverted = (await heard<TransactionConfirmationRevertedEvent>()).single;
    expect((reverted.walletId, reverted.txid, reverted.blockHeight), (_walletId, _txid, 15000));
    expect(reverted.blockHash, _blockHash,
        reason: 'the block that left the chain, so an app can say which one');
    expect(reverted.reason, 'reorganization at height 14999: headerMismatch');
  });

  test('a confirmation with no height or block is still announced', () async {
    readModel.add(domain.TransactionConfirmationRevertedEvent(
      walletId: _walletId,
      txid: _txid,
      reason: 'reorganization at height 14999: confirmed above the fork point '
          'with no stored proof',
    ));

    final reverted = (await heard<TransactionConfirmationRevertedEvent>()).single;
    expect((reverted.txid, reverted.blockHeight, reverted.blockHash), (_txid, null, null));
  });

  test('the confirmation itself is still announced', () async {
    readModel.add(domain.TransactionConfirmedEvent(
        walletId: _walletId, txid: _txid, blockHeight: 15000));

    final confirmed = (await heard<TransactionConfirmedEvent>()).single;
    expect((confirmed.walletId, confirmed.txid, confirmed.blockHeight), (_walletId, _txid, 15000));
    expect(announced.whereType<TransactionConfirmationRevertedEvent>(), isEmpty);
  });

  test('a confirmation and the revert that follows it are announced in order', () async {
    readModel.add(domain.TransactionConfirmedEvent(
        walletId: _walletId, txid: _txid, blockHeight: 15000));
    await heard<TransactionConfirmedEvent>();
    readModel.add(domain.TransactionConfirmationRevertedEvent(
      walletId: _walletId,
      txid: _txid,
      blockHeight: 15000,
      blockHash: _blockHash,
      reason: 'reorganization at height 14999: blockOrphaned',
    ));
    await heard<TransactionConfirmationRevertedEvent>();

    expect(
        announced
            .where((e) =>
                e is TransactionConfirmedEvent || e is TransactionConfirmationRevertedEvent)
            .map((e) => e.runtimeType.toString()),
        ['TransactionConfirmedEvent', 'TransactionConfirmationRevertedEvent'],
        reason: 'an app hears the confirmation and then hears it taken back');
  });
}

class _Noop extends Actor {
  @override
  Future<void> onMessage(dynamic message) async {}
}
