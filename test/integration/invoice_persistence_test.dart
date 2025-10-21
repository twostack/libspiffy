/// Invoice Persistence Integration Test
/// 
/// Tests that the invoice CQRS flow properly persists invoices to Isar storage:
/// - Invoice creation events are stored
/// - Invoice read models are persisted
/// - Invoice status updates are saved
/// - Invoice queries work correctly

import 'dart:async';
import 'dart:io';
import 'package:test/test.dart';
import 'package:dactor/dactor.dart';
import 'package:isar/isar.dart';
import 'package:eventador/eventador.dart';
import 'package:libspiffy/libspiffy.dart';
import 'package:libspiffy/src/actors/libspiffy_actor_system.dart';
import 'package:libspiffy/src/actors/invoice_messages.dart';
import 'package:libspiffy/src/actors/wallet_messages.dart';
import 'package:libspiffy/src/storage/isar_wallet_storage.dart';

void main() {
  group('Invoice Persistence Tests', () {
    late LibSpiffyActorSystem libspiffy;
    late Isar isar;
    late LocalActorSystem actorSystem;
    late Directory testDir;
    late String walletId;

    setUp(() async {
      // Initialize Isar
      await Isar.initializeIsarCore(download: true);
      
      // Create test directory
      testDir = await Directory.systemTemp.createTemp('invoice_persist_test_');
      
      // Open Isar with required schemas
      isar = await Isar.open(
        [
          ...LibSpiffySchemas.walletSchemas,
          EventEnvelopeSchema,
          SnapshotEnvelopeSchema,
        ],
        directory: testDir.path,
        name: 'invoice_test_db',
      );
      
      // Create actor system
      actorSystem = LocalActorSystem(ActorSystemConfig());
      
      // Initialize LibSpiffy
      libspiffy = LibSpiffyActorSystem();
      await libspiffy.initialize(
        actorSystem: actorSystem,
        isar: isar,
        dataDirectory: testDir.path,
      );
      
      // Create a wallet first
      walletId = 'test-wallet-${DateTime.now().millisecondsSinceEpoch}';
      final walletCompleter = Completer<WalletCreatedMessage>();
      final walletReceiver = await actorSystem.spawn(
        'wallet-receiver',
        () => _TestReceiverActor(walletCompleter),
      );
      
      libspiffy.walletManager.tell(
        CreateWalletMessage(walletId, 'Test Wallet'),
        sender: walletReceiver,
      );
      
      final walletResponse = await walletCompleter.future.timeout(Duration(seconds: 5));
      expect(walletResponse.success, isTrue);
      
      print('✓ Test wallet created: $walletId');
    });

    tearDown(() async {
      await actorSystem.shutdown();
      await isar.close();
      try {
        await testDir.delete(recursive: true);
      } catch (e) {
        print('Warning: Could not delete test directory: $e');
      }
    });

    test('Invoice is persisted to Isar on creation', () async {
      print('\n=== Test: Invoice Persistence on Creation ===');
      
      // Create invoice
      final createCompleter = Completer<InvoiceCreatedMessage>();
      final createReceiver = await actorSystem.spawn(
        'create-receiver',
        () => _TestReceiverActor<InvoiceCreatedMessage>(createCompleter),
      );
      
      print('Sending CreateInvoiceMessage...');
      libspiffy.invoiceManager.tell(
        CreateInvoiceMessage(
          walletId: walletId,
          amount: BigInt.from(100000),
          description: 'Test invoice',
        ),
        sender: createReceiver,
      );
      
      final invoice = await createCompleter.future.timeout(Duration(seconds: 5));
      print('✓ Invoice created: ${invoice.invoiceId}');
      print('  Addresses: ${invoice.addresses}');
      print('  Amount: ${invoice.amount}');
      
      // Give storage a moment to persist
      await Future.delayed(Duration(milliseconds: 200));
      
      // Verify in Isar database
      print('Checking Isar database...');
      final invoiceEntity = await isar.invoiceEntitys
          .filter()
          .invoiceIdEqualTo(invoice.invoiceId)
          .findFirst();
      
      if (invoiceEntity == null) {
        print('❌ Invoice NOT found in database');
        print('   Checking all invoices in DB:');
        final allInvoices = await isar.invoiceEntitys.where().findAll();
        print('   Total invoices in DB: ${allInvoices.length}');
        for (final inv in allInvoices) {
          print('   - ${inv.invoiceId}: ${inv.status}');
        }
      } else {
        print('✓ Invoice found in database');
        print('  Status: ${invoiceEntity.status}');
        print('  Wallet ID: ${invoiceEntity.walletId}');
        print('  Amount: ${invoiceEntity.amount}');
      }
      
      expect(invoiceEntity, isNotNull, reason: 'Invoice should be persisted to Isar');
      expect(invoiceEntity!.invoiceId, equals(invoice.invoiceId));
      expect(invoiceEntity.walletId, equals(walletId));
      expect(invoiceEntity.status, equals('pending'));
      expect(BigInt.parse(invoiceEntity.amount), equals(BigInt.from(100000)));
    });

    test('Invoice status update is persisted', () async {
      print('\n=== Test: Invoice Status Update Persistence ===');
      
      // Create invoice
      final createCompleter = Completer<InvoiceCreatedMessage>();
      final createReceiver = await actorSystem.spawn(
        'create-receiver-2',
        () => _TestReceiverActor<InvoiceCreatedMessage>(createCompleter),
      );
      
      libspiffy.invoiceManager.tell(
        CreateInvoiceMessage(
          walletId: walletId,
          amount: BigInt.from(50000),
        ),
        sender: createReceiver,
      );
      
      final invoice = await createCompleter.future.timeout(Duration(seconds: 5));
      print('✓ Invoice created: ${invoice.invoiceId}');
      
      // Wait for persistence
      await Future.delayed(Duration(milliseconds: 200));
      
      // Verify initial status
      var invoiceEntity = await isar.invoiceEntitys
          .filter()
          .invoiceIdEqualTo(invoice.invoiceId)
          .findFirst();
      
      expect(invoiceEntity, isNotNull);
      expect(invoiceEntity!.status, equals('pending'));
      print('✓ Initial status: pending');
      
      // Mark as paid
      final paidCompleter = Completer<InvoiceStatusMessage>();
      final paidReceiver = await actorSystem.spawn(
        'paid-receiver',
        () => _TestReceiverActor<InvoiceStatusMessage>(paidCompleter),
      );
      
      libspiffy.invoiceManager.tell(
        MarkInvoicePaidMessage(
          invoiceId: invoice.invoiceId,
          txid: 'test_txid_123',
          amountReceived: BigInt.from(50000),
          addressesPaidTo: invoice.addresses,
        ),
        sender: paidReceiver,
      );
      
      final paidStatus = await paidCompleter.future.timeout(Duration(seconds: 5));
      expect(paidStatus.status, equals(InvoiceStatus.paid));
      print('✓ Invoice marked as paid in memory');
      
      // Wait for persistence
      await Future.delayed(Duration(milliseconds: 200));
      
      // Verify updated status in database
      invoiceEntity = await isar.invoiceEntitys
          .filter()
          .invoiceIdEqualTo(invoice.invoiceId)
          .findFirst();
      
      expect(invoiceEntity, isNotNull);
      expect(invoiceEntity!.status, equals('paid'), 
          reason: 'Invoice status should be updated to paid in database');
      expect(invoiceEntity.paymentTxid, equals('test_txid_123'));
      print('✓ Updated status persisted: paid');
    });

    test('Multiple invoices for same wallet are persisted', () async {
      print('\n=== Test: Multiple Invoice Persistence ===');
      
      final invoiceIds = <String>[];
      
      // Create 3 invoices
      for (int i = 0; i < 3; i++) {
        final completer = Completer<InvoiceCreatedMessage>();
        final receiver = await actorSystem.spawn(
          'create-multi-$i',
          () => _TestReceiverActor<InvoiceCreatedMessage>(completer),
        );
        
        libspiffy.invoiceManager.tell(
          CreateInvoiceMessage(
            walletId: walletId,
            amount: BigInt.from(10000 * (i + 1)),
          ),
          sender: receiver,
        );
        
        final invoice = await completer.future.timeout(Duration(seconds: 5));
        invoiceIds.add(invoice.invoiceId);
        print('✓ Created invoice ${i + 1}: ${invoice.invoiceId}');
      }
      
      // Wait for persistence
      await Future.delayed(Duration(milliseconds: 300));
      
      // Verify all in database
      for (final id in invoiceIds) {
        final entity = await isar.invoiceEntitys
            .filter()
            .invoiceIdEqualTo(id)
            .findFirst();
        
        expect(entity, isNotNull, reason: 'Invoice $id should be in database');
        print('✓ Invoice $id verified in database');
      }
      
      // Verify count
      final count = await isar.invoiceEntitys
          .filter()
          .walletIdEqualTo(walletId)
          .count();
      
      expect(count, greaterThanOrEqualTo(3), 
          reason: 'Should have at least 3 invoices for wallet');
      print('✓ Total invoices for wallet: $count');
    });

    test('Invoice can be queried from storage', () async {
      print('\n=== Test: Invoice Query from Storage ===');
      
      // Create invoice
      final createCompleter = Completer<InvoiceCreatedMessage>();
      final createReceiver = await actorSystem.spawn(
        'create-query-test',
        () => _TestReceiverActor<InvoiceCreatedMessage>(createCompleter),
      );
      
      libspiffy.invoiceManager.tell(
        CreateInvoiceMessage(
          walletId: walletId,
          amount: BigInt.from(75000),
        ),
        sender: createReceiver,
      );
      
      final invoice = await createCompleter.future.timeout(Duration(seconds: 5));
      print('✓ Invoice created: ${invoice.invoiceId}');
      
      // Wait for persistence
      await Future.delayed(Duration(milliseconds: 200));
      
      // Query via invoice manager
      final queryCompleter = Completer<InvoiceDetailsResponse>();
      final queryReceiver = await actorSystem.spawn(
        'query-receiver',
        () => _TestReceiverActor<InvoiceDetailsResponse>(queryCompleter),
      );
      
      libspiffy.invoiceManager.tell(
        CheckInvoiceMessage(invoice.invoiceId),
        sender: queryReceiver,
      );
      
      final details = await queryCompleter.future.timeout(Duration(seconds: 5));
      expect(details.found, isTrue, reason: 'Invoice should be found');
      expect(details.status, equals(InvoiceStatus.pending));
      print('✓ Invoice queried successfully');
      print('  Status: ${details.status}');
      print('  Addresses: ${details.addresses}');
    });

    test('Invoice manager loads invoices from storage on startup', () async {
      print('\n=== Test: Invoice Loading on Startup ===');
      
      // Create an invoice
      final createCompleter = Completer<InvoiceCreatedMessage>();
      final createReceiver = await actorSystem.spawn(
        'create-load-test',
        () => _TestReceiverActor<InvoiceCreatedMessage>(createCompleter),
      );
      
      libspiffy.invoiceManager.tell(
        CreateInvoiceMessage(
          walletId: walletId,
          amount: BigInt.from(60000),
        ),
        sender: createReceiver,
      );
      
      final invoice = await createCompleter.future.timeout(Duration(seconds: 5));
      final invoiceId = invoice.invoiceId;
      print('✓ Invoice created: $invoiceId');
      
      // Wait for persistence
      await Future.delayed(Duration(milliseconds: 200));
      
      // Verify in database
      final entityBeforeShutdown = await isar.invoiceEntitys
          .filter()
          .invoiceIdEqualTo(invoiceId)
          .findFirst();
      expect(entityBeforeShutdown, isNotNull);
      print('✓ Invoice persisted before shutdown');
      
      // Shutdown and restart actor system (but keep Isar open)
      print('Shutting down actor system...');
      await actorSystem.shutdown();
      
      // Create new actor system and LibSpiffy instance
      print('Restarting actor system...');
      final newActorSystem = LocalActorSystem(ActorSystemConfig());
      final newLibspiffy = LibSpiffyActorSystem();
      await newLibspiffy.initialize(
        actorSystem: newActorSystem,
        isar: isar, // Reuse same Isar instance
        dataDirectory: testDir.path,
      );
      
      print('✓ New LibSpiffy instance initialized');
      
      // Give it time to load from storage
      await Future.delayed(Duration(milliseconds: 500));
      
      // Query the invoice
      final queryCompleter = Completer<InvoiceDetailsResponse>();
      final queryReceiver = await newActorSystem.spawn(
        'query-after-restart',
        () => _TestReceiverActor<InvoiceDetailsResponse>(queryCompleter),
      );
      
      newLibspiffy.invoiceManager.tell(
        CheckInvoiceMessage(invoiceId),
        sender: queryReceiver,
      );
      
      final details = await queryCompleter.future.timeout(Duration(seconds: 5));
      expect(details.found, isTrue, 
          reason: 'Invoice should be loaded from storage on startup');
      print('✓ Invoice found after restart');
      print('  Loaded from storage: $invoiceId');
      
      // Cleanup new actor system
      await newActorSystem.shutdown();
    });
  });
}

/// Simple test receiver actor
class _TestReceiverActor<T> extends Actor {
  final Completer<T> completer;
  
  _TestReceiverActor(this.completer);
  
  @override
  Future<void> onMessage(dynamic message) async {
    if (message is T && !completer.isCompleted) {
      completer.complete(message);
    }
  }
}

