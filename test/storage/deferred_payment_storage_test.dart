/// Bead libspiffy-7p2: the deferred-payment read model on the in-memory and
/// Isar backends (PostgreSQL: postgres/postgres_deferred_payment_test.dart).
import 'dart:io';

import 'package:isar/isar.dart';
import 'package:test/test.dart';

import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';
import 'package:libspiffy/src/storage/isar_wallet_storage.dart';
import 'package:libspiffy/src/storage/libspiffy_schemas.dart';
import 'package:libspiffy/src/storage/read_model_storage.dart';

import '../integration/isar_test_helper.dart';
import 'deferred_payment_contract.dart';

void main() {
  group('InMemoryWalletStorage', () {
    late InMemoryWalletStorage storage;
    var counter = 0;
    setUp(() => storage = InMemoryWalletStorage());
    defineDeferredPaymentContract(() => storage, unique: () => 'm${counter++}');

    test('the outstanding-only listing reads only outstanding rows, not the resolved history', () async {
      const walletId = 'w-scan';
      for (var i = 0; i < 200; i++) {
        await storage.storeDeferredPayment(contractDeferredPayment(
          walletId: walletId,
          txid: contractTxid('resolved$i'),
          minutesAfterBase: i,
          state: i.isEven ? DeferredPaymentState.mined : DeferredPaymentState.seen,
        ));
      }
      for (var i = 0; i < 3; i++) {
        await storage.storeDeferredPayment(
            contractDeferredPayment(walletId: walletId, txid: contractTxid('open$i'), minutesAfterBase: i));
      }
      storage.deferredPaymentRowsRead = 0;

      final page = await storage.listDeferredPayments(walletId);

      expect(page.payments, hasLength(3));
      expect(storage.deferredPaymentRowsRead, 3);
    });
  });

  group('IsarWalletStorage', () {
    late Directory dir;
    late Isar isar;
    late IsarWalletStorage storage;
    var counter = 0;

    setUpAll(() async {
      await ensureIsarInitialized();
    });

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('deferred_payment_storage_');
      isar = await Isar.open(
        LibSpiffySchemas.allSchemas,
        directory: dir.path,
        name: 'deferred_payments_${DateTime.now().microsecondsSinceEpoch}',
      );
      storage = IsarWalletStorage(isar);
    });

    tearDown(() async {
      await isar.close(deleteFromDisk: true);
      await dir.delete(recursive: true);
    });

    defineDeferredPaymentContract(() => storage, unique: () => 'i${counter++}');

    test('the outstanding-only listing uses the (walletId, state, createdAt) index range', () async {
      const walletId = 'w-index';
      await storage.storeDeferredPayment(
          contractDeferredPayment(walletId: walletId, txid: contractTxid('open'), minutesAfterBase: 1));
      await storage.storeDeferredPayment(contractDeferredPayment(
          walletId: walletId, txid: contractTxid('done'), state: DeferredPaymentState.mined));
      // The index range the listing reads holds exactly the outstanding row.
      final range = await isar.deferredPaymentEntitys
          .where()
          .walletIdStateEqualToAnyCreatedAt(walletId, DeferredPaymentState.outstanding.name)
          .findAll();
      expect([for (final e in range) e.txid], [contractTxid('open')]);
      expect([for (final p in (await storage.listDeferredPayments(walletId)).payments) p.txid],
          [contractTxid('open')]);
    });
  });
}
