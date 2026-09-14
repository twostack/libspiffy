// Audit 2026-09-14 L4: wallet import progress is an in-process notification,
// not a journal event (it was never persisted or registered, and the
// aggregate's apply handlers for it were unreachable).
import 'dart:async';

import 'package:dactor/dactor.dart';
import 'package:eventador/eventador.dart';
import 'package:libspiffy/internals.dart';
import 'package:libspiffy/libspiffy.dart';
import 'package:libspiffy/src/actors/coordinator_messages.dart';
import 'package:test/test.dart';

const _w = 'wallet-1';

List<WalletImportNotification> _allNotifications() => [
      WalletImportStartedEvent(
          walletId: _w, walletName: 'n', addressGapLimit: 20),
      WalletImportProgressEvent(
          walletId: _w, phase: 'import', message: 'm', progress: 0.5,
          addressesFound: 1, totalAddresses: 2, transactionsProcessed: 3,
          totalTransactions: 4),
      WalletImportCompletedEvent(
          walletId: _w, totalAddresses: 2, totalTransactions: 4,
          importedUtxos: []),
      WalletImportFailedEvent(walletId: _w, error: 'e'),
      WalletImportUTXOConfirmedEvent(
          walletId: _w, txid: 't', vout: 0, success: true),
      WalletImportTransactionConfirmedEvent(
          walletId: _w, txid: 't', success: true),
    ];

class _ProbeActor extends Actor {
  @override
  Future<void> onMessage(dynamic message) async {}
}

void main() {
  test('import notifications are not journal events', () {
    for (final Object notification in _allNotifications()) {
      expect(notification, isNot(isA<Event>()),
          reason: '${notification.runtimeType} is still an eventador Event');
      expect(notification, isNot(isA<WalletEvent>()));
    }
  });

  test('the wallet coordinator forwards import notifications as coordinator events', () async {
    final system = LocalActorSystem();
    final notifications = StreamController<WalletImportNotification>.broadcast();
    final importStarted = Completer<void>();
    final events = <CoordinatorEvent>[];
    try {
      final probe = await system.spawn('probe', () => _ProbeActor());
      final coordinator = WalletCoordinatorActor(
        walletManager: probe,
        invoiceCoordinator: probe,
        paymentCoordinator: probe,
        spvActor: probe,
        arcActor: probe,
        headerSyncActor: probe,
        benfordCoordinator: probe,
        channelManager: probe,
        walletProjection: probe,
        storage: InMemoryWalletStorage(),
        importNotifications: notifications.stream,
        importWalletFromWif: ({
          required String walletId,
          required String wif,
          required String walletName,
          String networkType = 'test',
        }) {
          importStarted.complete();
        },
      );
      final sub = coordinator.events.listen(events.add);
      final ref = await system.spawn('coordinator', () => coordinator);

      ref.tell(ImportWalletCommand(walletId: _w, walletName: 'n', wif: 'wif'));
      await importStarted.future.timeout(const Duration(seconds: 5));

      // Another wallet's notification is not forwarded.
      notifications.add(WalletImportFailedEvent(walletId: 'other', error: 'x'));
      for (final n in _allNotifications()) {
        notifications.add(n);
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(events.whereType<ImportProgressEvent>().single.progress, 0.5);
      expect(events.whereType<ImportUTXOConfirmedEvent>(), isEmpty,
          reason: 'completion ends the subscription before later notifications');
      final complete = events.whereType<ImportCompleteEvent>().single;
      expect(complete.walletId, _w);
      expect(complete.success, isTrue);
      expect(complete.addressCount, 2);
      expect(complete.transactionCount, 4);
      await sub.cancel();
    } finally {
      await notifications.close();
      await system.shutdown();
    }
  });
}
