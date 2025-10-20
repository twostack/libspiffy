import 'dart:async';
import 'package:test/test.dart';
import 'package:dactor/dactor.dart';
import 'package:libspiffy/src/actors/invoice_manager_actor.dart';
import 'package:libspiffy/src/actors/invoice_messages.dart';
import 'package:libspiffy/src/actors/wallet_messages.dart';
import 'package:libspiffy/src/core/wallet_commands.dart';

void main() {
  group('InvoiceManagerActor', () {
    late LocalActorSystem actorSystem;
    late ActorRef mockWalletManager;
    late ActorRef invoiceManager;

    setUp(() async {
      actorSystem = LocalActorSystem(ActorSystemConfig());
      
      // Create mock wallet manager that responds with addresses
      mockWalletManager = await actorSystem.spawn(
        'mock-wallet-manager',
        () => _MockWalletManagerActor(),
      );
      
      invoiceManager = await actorSystem.spawn(
        'invoice-manager',
        () => InvoiceManagerActor(
          walletManager: mockWalletManager,
          storage: null,
        ),
      );
    });

    tearDown(() async {
      await actorSystem.shutdown();
    });

    test('creates invoice with single address', () async {
      final completer = Completer<InvoiceCreatedMessage>();
      final receiver = await actorSystem.spawn(
        'test-receiver',
        () => _TestReceiverActor<InvoiceCreatedMessage>(completer),
      );

      invoiceManager.tell(
        CreateInvoiceMessage(
          walletId: 'test-wallet',
          amount: BigInt.from(100000),
          description: 'Test invoice',
        ),
        sender: receiver,
      );

      final response = await completer.future.timeout(Duration(seconds: 5));
      
      expect(response.success, isTrue);
      expect(response.walletId, equals('test-wallet'));
      expect(response.addresses.length, equals(1));
      expect(response.amount, equals(BigInt.from(100000)));
      expect(response.description, equals('Test invoice'));
      expect(response.invoiceId, isNotEmpty);
    });

    test('creates invoice with multiple addresses', () async {
      final completer = Completer<InvoiceCreatedMessage>();
      final receiver = await actorSystem.spawn(
        'test-receiver-multi',
        () => _TestReceiverActor<InvoiceCreatedMessage>(completer),
      );

      invoiceManager.tell(
        CreateInvoiceMessage(
          walletId: 'test-wallet',
          amount: BigInt.from(200000),
          numberOfAddresses: 3,
        ),
        sender: receiver,
      );

      final response = await completer.future.timeout(Duration(seconds: 5));
      
      expect(response.success, isTrue);
      expect(response.addresses.length, equals(3));
      expect(response.addresses[0], isNotEmpty);
      expect(response.addresses[1], isNotEmpty);
      expect(response.addresses[2], isNotEmpty);
    });

    test('retrieves invoice details', () async {
      // First create an invoice
      final createCompleter = Completer<InvoiceCreatedMessage>();
      final createReceiver = await actorSystem.spawn(
        'create-receiver',
        () => _TestReceiverActor<InvoiceCreatedMessage>(createCompleter),
      );

      invoiceManager.tell(
        CreateInvoiceMessage(
          walletId: 'test-wallet',
          amount: BigInt.from(100000),
        ),
        sender: createReceiver,
      );

      final createResponse = await createCompleter.future;
      final invoiceId = createResponse.invoiceId;

      // Now query the invoice
      final queryCompleter = Completer<InvoiceDetailsResponse>();
      final queryReceiver = await actorSystem.spawn(
        'query-receiver',
        () => _TestReceiverActor<InvoiceDetailsResponse>(queryCompleter),
      );

      invoiceManager.tell(
        CheckInvoiceMessage(invoiceId),
        sender: queryReceiver,
      );

      final queryResponse = await queryCompleter.future.timeout(Duration(seconds: 5));
      
      expect(queryResponse.found, isTrue);
      expect(queryResponse.invoiceId, equals(invoiceId));
      expect(queryResponse.status, equals(InvoiceStatus.pending));
      expect(queryResponse.amount, equals(BigInt.from(100000)));
      expect(queryResponse.addresses.length, equals(1));
    });

    test('marks invoice as paid', () async {
      // Create invoice
      final createCompleter = Completer<InvoiceCreatedMessage>();
      final createReceiver = await actorSystem.spawn(
        'create-receiver-paid',
        () => _TestReceiverActor<InvoiceCreatedMessage>(createCompleter),
      );

      invoiceManager.tell(
        CreateInvoiceMessage(
          walletId: 'test-wallet',
          amount: BigInt.from(100000),
        ),
        sender: createReceiver,
      );

      final createResponse = await createCompleter.future;
      final invoiceId = createResponse.invoiceId;
      final addresses = createResponse.addresses;

      // Mark as paid
      final paidCompleter = Completer<InvoiceStatusMessage>();
      final paidReceiver = await actorSystem.spawn(
        'paid-receiver',
        () => _TestReceiverActor<InvoiceStatusMessage>(paidCompleter),
      );

      invoiceManager.tell(
        MarkInvoicePaidMessage(
          invoiceId: invoiceId,
          txid: 'test-txid-123',
          amountReceived: BigInt.from(150000),
          addressesPaidTo: addresses,
        ),
        sender: paidReceiver,
      );

      final paidResponse = await paidCompleter.future.timeout(Duration(seconds: 5));
      
      expect(paidResponse.status, equals(InvoiceStatus.paid));
      expect(paidResponse.txid, equals('test-txid-123'));

      // Verify status changed
      final queryCompleter = Completer<InvoiceDetailsResponse>();
      final queryReceiver = await actorSystem.spawn(
        'query-receiver-paid',
        () => _TestReceiverActor<InvoiceDetailsResponse>(queryCompleter),
      );

      invoiceManager.tell(
        CheckInvoiceMessage(invoiceId),
        sender: queryReceiver,
      );

      final queryResponse = await queryCompleter.future;
      expect(queryResponse.status, equals(InvoiceStatus.paid));
      expect(queryResponse.paymentTxid, equals('test-txid-123'));
    });

    test('cancels invoice', () async {
      // Create invoice
      final createCompleter = Completer<InvoiceCreatedMessage>();
      final createReceiver = await actorSystem.spawn(
        'create-receiver-cancel',
        () => _TestReceiverActor<InvoiceCreatedMessage>(createCompleter),
      );

      invoiceManager.tell(
        CreateInvoiceMessage(
          walletId: 'test-wallet',
          amount: BigInt.from(100000),
        ),
        sender: createReceiver,
      );

      final createResponse = await createCompleter.future;
      final invoiceId = createResponse.invoiceId;

      // Cancel invoice
      final cancelCompleter = Completer<InvoiceStatusMessage>();
      final cancelReceiver = await actorSystem.spawn(
        'cancel-receiver',
        () => _TestReceiverActor<InvoiceStatusMessage>(cancelCompleter),
      );

      invoiceManager.tell(
        CancelInvoiceMessage(
          invoiceId: invoiceId,
          reason: 'Test cancellation',
        ),
        sender: cancelReceiver,
      );

      final cancelResponse = await cancelCompleter.future.timeout(Duration(seconds: 5));
      
      expect(cancelResponse.status, equals(InvoiceStatus.cancelled));

      // Verify status changed
      final queryCompleter = Completer<InvoiceDetailsResponse>();
      final queryReceiver = await actorSystem.spawn(
        'query-receiver-cancel',
        () => _TestReceiverActor<InvoiceDetailsResponse>(queryCompleter),
      );

      invoiceManager.tell(
        CheckInvoiceMessage(invoiceId),
        sender: queryReceiver,
      );

      final queryResponse = await queryCompleter.future;
      expect(queryResponse.status, equals(InvoiceStatus.cancelled));
    });

    test('lists invoices', () async {
      // Create multiple invoices
      for (int i = 0; i < 3; i++) {
        final completer = Completer<InvoiceCreatedMessage>();
        final receiver = await actorSystem.spawn(
          'create-receiver-$i',
          () => _TestReceiverActor<InvoiceCreatedMessage>(completer),
        );

        invoiceManager.tell(
          CreateInvoiceMessage(
            walletId: 'test-wallet',
            amount: BigInt.from(100000 * (i + 1)),
          ),
          sender: receiver,
        );

        await completer.future;
      }

      // List all invoices
      final listCompleter = Completer<InvoicesListMessage>();
      final listReceiver = await actorSystem.spawn(
        'list-receiver',
        () => _TestReceiverActor<InvoicesListMessage>(listCompleter),
      );

      invoiceManager.tell(
        ListInvoicesMessage(walletId: 'test-wallet'),
        sender: listReceiver,
      );

      final listResponse = await listCompleter.future.timeout(Duration(seconds: 5));
      
      expect(listResponse.invoices.length, greaterThanOrEqualTo(3));
      expect(listResponse.invoices.every((inv) => inv.walletId == 'test-wallet'), isTrue);
    });

    test('returns not found for non-existent invoice', () async {
      final queryCompleter = Completer<InvoiceDetailsResponse>();
      final queryReceiver = await actorSystem.spawn(
        'query-receiver-notfound',
        () => _TestReceiverActor<InvoiceDetailsResponse>(queryCompleter),
      );

      invoiceManager.tell(
        CheckInvoiceMessage('non-existent-id'),
        sender: queryReceiver,
      );

      final queryResponse = await queryCompleter.future.timeout(Duration(seconds: 5));
      
      expect(queryResponse.found, isFalse);
      expect(queryResponse.error, isNotNull);
    });
  });
}

/// Mock wallet manager that generates test addresses
class _MockWalletManagerActor extends Actor {
  int _addressCounter = 0;

  @override
  Future<void> onMessage(dynamic message) async {
    if (message is WalletCommandMessage) {
      final command = message.command;
      if (command is GenerateAddressCommand) {
        _addressCounter++;
        final address = '1TestAddress${_addressCounter}XXXXXXXXXXXXXXXXXX';
        
        context.sender?.tell(AddressGeneratedResponse(
          walletId: message.walletId,
          address: address,
          derivationIndex: _addressCounter,
          success: true,
        ));
      }
    }
  }
}

/// Test actor that receives a specific message type
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

