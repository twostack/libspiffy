/// InvoiceCoordinatorActor expiry sweep.
///
/// Covers the InvoiceCoordinator half of audit finding A-M10 (libspiffy-rit,
/// doc/audit-2026-09-14.md): the periodic expiry check ran straight from the
/// Timer callback, concurrently with the actor's handlers, and a tick fired
/// while the previous sweep was still querying storage started a second
/// sweep over the same invoices (both spawning the same aggregate).

import 'dart:async';

import 'package:dactor/dactor.dart';
import 'package:dactor_test/dactor_test.dart';
import 'package:test/test.dart';

import 'package:libspiffy/src/actors/invoice_coordinator_actor.dart';
import 'package:libspiffy/src/actors/invoice_messages.dart' show InvoiceStatus;
import 'package:libspiffy/src/models/invoice_read_model.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';

import 'in_memory_event_store.dart';

void main() {
  late TestActorSystem actorSystem;

  setUp(() {
    actorSystem = TestActorSystem();
  });

  tearDown(() async {
    await actorSystem.shutdown();
  });

  test('A-M10: overlapping expiry ticks run the sweep once', () async {
    final storage = _BlockingInvoiceStorage();
    final walletManager =
        await actorSystem.spawn('wallet-manager', () => _NoopActor());
    await actorSystem.spawn(
      'invoice-coordinator',
      () => InvoiceCoordinatorActor(
        walletManager: walletManager,
        storage: storage,
        eventStore: InMemoryEventStore(),
        expirySweepInterval: const Duration(milliseconds: 20),
      ),
    );

    // The first sweep's storage query does not return; ~15 more ticks fire.
    await storage.firstQuery.future.timeout(const Duration(seconds: 2));
    await Future.delayed(const Duration(milliseconds: 300));
    expect(storage.pendingQueries, equals(1),
        reason: 'ticks that fire while a sweep is in flight must be skipped');

    // Once it finishes, later ticks sweep again.
    storage.release();
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (storage.pendingQueries < 2 && DateTime.now().isBefore(deadline)) {
      await Future.delayed(const Duration(milliseconds: 20));
    }
    expect(storage.pendingQueries, greaterThanOrEqualTo(2),
        reason: 'the sweep must run again after the in-flight one completes');
  });
}

/// Counts pending-invoice queries; the first one blocks until [release].
class _BlockingInvoiceStorage extends InMemoryWalletStorage {
  final Completer<void> firstQuery = Completer<void>();
  final Completer<void> _gate = Completer<void>();
  int pendingQueries = 0;

  void release() {
    if (!_gate.isCompleted) _gate.complete();
  }

  @override
  Future<List<InvoiceReadModel>> listInvoices({
    String? walletId,
    InvoiceStatus? status,
  }) async {
    if (status == InvoiceStatus.pending) {
      pendingQueries++;
      if (!firstQuery.isCompleted) firstQuery.complete();
      await _gate.future;
      return const [];
    }
    return super.listInvoices(walletId: walletId, status: status);
  }
}

class _NoopActor extends Actor {
  @override
  Future<void> onMessage(dynamic message) async {}
}
