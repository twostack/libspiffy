import 'dart:async';
import 'package:test/test.dart';
import 'package:dactor/dactor.dart';
import 'package:libspiffy/src/actors/invoice_messages.dart';
import 'package:libspiffy/src/models/invoice_output_spec.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';

void main() {
  group('Multi-Output Invoice Tests', () {
    late LocalActorSystem actorSystem;
    late ActorRef invoiceManager;
    late InMemoryWalletStorage storage;

    // Valid compressed public keys (must be valid EC points on secp256k1)
    final validPubKey1 =
        '0335cd55d33889f942e8c445cf4d9e9488a3be4bc4d4e91ccc9b57dcaa49c0f7a8';
    final validPubKey2 =
        '028f10cd0e0e9bc7352adb192484d576867a71cbd82295cd87c3ceffc5fbd74acc';
    final validPubKey3 =
        '02a7472269ad70ea6cf1ecc7fe25a23fb6bc47f928a9ec755e34bada052bd355ce';

    setUp(() async {
      actorSystem = LocalActorSystem(ActorSystemConfig());
      storage = InMemoryWalletStorage();

      // Create mock invoice manager that supports outputs
      invoiceManager = await actorSystem.spawn(
        'mock-invoice-manager',
        () => _MockInvoiceManagerWithOutputsActor(storage),
      );
    });

    tearDown(() async {
      await actorSystem.shutdown();
    });

    group('P2PKH Multi-Output Invoices', () {
      test('creates invoice with multiple P2PKH outputs', () async {
        final createCompleter = Completer<InvoiceCreatedMessage>();
        final createReceiver = await actorSystem.spawn(
          'create-receiver-p2pkh-multi',
          () => _TestReceiverActor<InvoiceCreatedMessage>(createCompleter),
        );

        final outputs = [
          P2PKHOutputSpec(
            address: 'mPaymentAddr1',
            amount: BigInt.from(10000),
            label: 'Payment portion 1',
          ),
          P2PKHOutputSpec(
            address: 'mPaymentAddr2',
            amount: BigInt.from(5000),
            label: 'Payment portion 2',
          ),
          P2PKHOutputSpec(
            address: 'mFeeAddr',
            amount: BigInt.from(1000),
            label: 'Service fee',
          ),
        ];

        invoiceManager.tell(
          CreateInvoiceMessage(
            walletId: 'bob-wallet',
            outputs: outputs,
            description: 'Multi-output P2PKH payment',
          ),
          sender: createReceiver,
        );

        final invoice =
            await createCompleter.future.timeout(Duration(seconds: 5));

        expect(invoice.success, isTrue);
        expect(invoice.outputs, isNotNull);
        expect(invoice.outputs!.length, equals(3));
        expect(invoice.effectiveAmount, equals(BigInt.from(16000)));

        // All should be P2PKH
        for (final output in invoice.outputs!) {
          expect(output, isA<P2PKHOutputSpec>());
        }

        // Legacy addresses should contain all P2PKH addresses
        expect(invoice.addresses.length, equals(3));
        expect(invoice.addresses, contains('mPaymentAddr1'));
        expect(invoice.addresses, contains('mPaymentAddr2'));
        expect(invoice.addresses, contains('mFeeAddr'));

        print('✓ Created multi-P2PKH invoice: ${invoice.invoiceId}');
        print('  Total amount: ${invoice.effectiveAmount} satoshis');
        print('  Outputs: ${invoice.outputs!.length}');
      });

      test('creates invoice with different amounts per P2PKH output', () async {
        final createCompleter = Completer<InvoiceCreatedMessage>();
        final createReceiver = await actorSystem.spawn(
          'create-receiver-p2pkh-amounts',
          () => _TestReceiverActor<InvoiceCreatedMessage>(createCompleter),
        );

        final outputs = [
          P2PKHOutputSpec(address: 'mLarge', amount: BigInt.from(100000)),
          P2PKHOutputSpec(address: 'mMedium', amount: BigInt.from(50000)),
          P2PKHOutputSpec(address: 'mSmall', amount: BigInt.from(1000)),
        ];

        invoiceManager.tell(
          CreateInvoiceMessage(
            walletId: 'bob-wallet',
            outputs: outputs,
          ),
          sender: createReceiver,
        );

        final invoice = await createCompleter.future;

        expect(invoice.success, isTrue);
        expect(invoice.effectiveAmount, equals(BigInt.from(151000)));

        // Verify individual amounts preserved
        final p2pkhOutputs =
            invoice.outputs!.whereType<P2PKHOutputSpec>().toList();
        expect(p2pkhOutputs[0].amount, equals(BigInt.from(100000)));
        expect(p2pkhOutputs[1].amount, equals(BigInt.from(50000)));
        expect(p2pkhOutputs[2].amount, equals(BigInt.from(1000)));

        print('✓ Created invoice with varied amounts');
      });
    });

    group('P2MS Multisig Invoices', () {
      test('creates invoice with single P2MS output (2-of-3)', () async {
        final createCompleter = Completer<InvoiceCreatedMessage>();
        final createReceiver = await actorSystem.spawn(
          'create-receiver-p2ms-single',
          () => _TestReceiverActor<InvoiceCreatedMessage>(createCompleter),
        );

        final outputs = [
          P2MSOutputSpec(
            publicKeys: [validPubKey1, validPubKey2, validPubKey3],
            threshold: 2,
            amount: BigInt.from(100000),
            label: '2-of-3 escrow',
          ),
        ];

        invoiceManager.tell(
          CreateInvoiceMessage(
            walletId: 'escrow-wallet',
            outputs: outputs,
            description: '2-of-3 multisig escrow payment',
          ),
          sender: createReceiver,
        );

        final invoice = await createCompleter.future;

        expect(invoice.success, isTrue);
        expect(invoice.outputs, isNotNull);
        expect(invoice.outputs!.length, equals(1));
        expect(invoice.effectiveAmount, equals(BigInt.from(100000)));

        final p2msOutput = invoice.outputs!.first as P2MSOutputSpec;
        expect(p2msOutput.threshold, equals(2));
        expect(p2msOutput.totalKeys, equals(3));
        expect(p2msOutput.publicKeys, contains(validPubKey1));
        expect(p2msOutput.publicKeys, contains(validPubKey2));
        expect(p2msOutput.publicKeys, contains(validPubKey3));

        print('✓ Created 2-of-3 multisig invoice: ${invoice.invoiceId}');
        print('  Amount: ${invoice.effectiveAmount} satoshis');
      });

      test('creates invoice with 1-of-2 multisig', () async {
        final createCompleter = Completer<InvoiceCreatedMessage>();
        final createReceiver = await actorSystem.spawn(
          'create-receiver-p2ms-1of2',
          () => _TestReceiverActor<InvoiceCreatedMessage>(createCompleter),
        );

        final outputs = [
          P2MSOutputSpec(
            publicKeys: [validPubKey1, validPubKey2],
            threshold: 1,
            amount: BigInt.from(50000),
            label: '1-of-2 backup wallet',
          ),
        ];

        invoiceManager.tell(
          CreateInvoiceMessage(
            walletId: 'backup-wallet',
            outputs: outputs,
          ),
          sender: createReceiver,
        );

        final invoice = await createCompleter.future;

        expect(invoice.success, isTrue);
        final p2msOutput = invoice.outputs!.first as P2MSOutputSpec;
        expect(p2msOutput.threshold, equals(1));
        expect(p2msOutput.totalKeys, equals(2));

        print('✓ Created 1-of-2 multisig invoice');
      });
    });

    group('Mixed P2PKH and P2MS Invoices', () {
      test('creates invoice with mixed P2PKH and P2MS outputs', () async {
        final createCompleter = Completer<InvoiceCreatedMessage>();
        final createReceiver = await actorSystem.spawn(
          'create-receiver-mixed',
          () => _TestReceiverActor<InvoiceCreatedMessage>(createCompleter),
        );

        final outputs = <InvoiceOutputSpec>[
          // Standard payment to merchant
          P2PKHOutputSpec(
            address: 'mMerchantAddr',
            amount: BigInt.from(80000),
            label: 'Merchant payment',
          ),
          // Platform fee
          P2PKHOutputSpec(
            address: 'mPlatformFee',
            amount: BigInt.from(5000),
            label: 'Platform fee',
          ),
          // Escrow portion requiring 2-of-3 signatures
          P2MSOutputSpec(
            publicKeys: [validPubKey1, validPubKey2, validPubKey3],
            threshold: 2,
            amount: BigInt.from(15000),
            label: 'Escrow portion',
          ),
        ];

        invoiceManager.tell(
          CreateInvoiceMessage(
            walletId: 'marketplace-wallet',
            outputs: outputs,
            description: 'Marketplace order with escrow',
          ),
          sender: createReceiver,
        );

        final invoice = await createCompleter.future;

        expect(invoice.success, isTrue);
        expect(invoice.outputs, isNotNull);
        expect(invoice.outputs!.length, equals(3));
        expect(invoice.effectiveAmount, equals(BigInt.from(100000)));

        // Verify output types
        final p2pkhOutputs =
            invoice.outputs!.whereType<P2PKHOutputSpec>().toList();
        final p2msOutputs =
            invoice.outputs!.whereType<P2MSOutputSpec>().toList();

        expect(p2pkhOutputs.length, equals(2));
        expect(p2msOutputs.length, equals(1));

        // Verify P2PKH amounts
        expect(
          p2pkhOutputs.map((o) => o.amount).toList(),
          containsAll([BigInt.from(80000), BigInt.from(5000)]),
        );

        // Verify P2MS
        expect(p2msOutputs.first.threshold, equals(2));
        expect(p2msOutputs.first.amount, equals(BigInt.from(15000)));

        // Legacy addresses should only contain P2PKH addresses
        expect(invoice.addresses.length, equals(2));
        expect(invoice.addresses, contains('mMerchantAddr'));
        expect(invoice.addresses, contains('mPlatformFee'));

        print('✓ Created mixed P2PKH/P2MS invoice: ${invoice.invoiceId}');
        print('  Total: ${invoice.effectiveAmount} satoshis');
        print('  P2PKH outputs: ${p2pkhOutputs.length}');
        print('  P2MS outputs: ${p2msOutputs.length}');
      });

      test('serialization roundtrip preserves mixed outputs', () async {
        final createCompleter = Completer<InvoiceCreatedMessage>();
        final createReceiver = await actorSystem.spawn(
          'create-receiver-roundtrip',
          () => _TestReceiverActor<InvoiceCreatedMessage>(createCompleter),
        );

        final originalOutputs = <InvoiceOutputSpec>[
          P2PKHOutputSpec(
            address: 'mAddr1',
            amount: BigInt.from(1000),
            label: 'First',
          ),
          P2MSOutputSpec(
            publicKeys: [validPubKey1, validPubKey2],
            threshold: 2,
            amount: BigInt.from(2000),
            label: 'Second',
          ),
        ];

        invoiceManager.tell(
          CreateInvoiceMessage(
            walletId: 'test-wallet',
            outputs: originalOutputs,
          ),
          sender: createReceiver,
        );

        final invoice = await createCompleter.future;

        // Verify data integrity
        expect(invoice.outputs!.length, equals(2));

        final restored0 = invoice.outputs![0] as P2PKHOutputSpec;
        expect(restored0.address, equals('mAddr1'));
        expect(restored0.amount, equals(BigInt.from(1000)));
        expect(restored0.label, equals('First'));

        final restored1 = invoice.outputs![1] as P2MSOutputSpec;
        expect(restored1.publicKeys, equals([validPubKey1, validPubKey2]));
        expect(restored1.threshold, equals(2));
        expect(restored1.amount, equals(BigInt.from(2000)));
        expect(restored1.label, equals('Second'));

        print('✓ Roundtrip serialization successful');
      });
    });

    group('Backward Compatibility', () {
      test('legacy invoice creation still works', () async {
        final createCompleter = Completer<InvoiceCreatedMessage>();
        final createReceiver = await actorSystem.spawn(
          'create-receiver-legacy',
          () => _TestReceiverActor<InvoiceCreatedMessage>(createCompleter),
        );

        // Legacy style: amount + numberOfAddresses
        invoiceManager.tell(
          CreateInvoiceMessage(
            walletId: 'legacy-wallet',
            amount: BigInt.from(50000),
            numberOfAddresses: 2,
          ),
          sender: createReceiver,
        );

        final invoice = await createCompleter.future;

        expect(invoice.success, isTrue);
        expect(invoice.amount, equals(BigInt.from(50000)));
        expect(invoice.addresses.length, equals(2));

        // Outputs may be null for legacy-only invoices
        // or converted to P2PKH outputs depending on implementation

        print('✓ Legacy invoice creation works');
      });

      test('effectiveAmount works for both legacy and output-based', () async {
        // Test legacy
        final legacyCompleter = Completer<InvoiceCreatedMessage>();
        final legacyReceiver = await actorSystem.spawn(
          'legacy-receiver',
          () => _TestReceiverActor<InvoiceCreatedMessage>(legacyCompleter),
        );

        invoiceManager.tell(
          CreateInvoiceMessage(
            walletId: 'wallet1',
            amount: BigInt.from(10000),
          ),
          sender: legacyReceiver,
        );

        final legacy = await legacyCompleter.future;
        expect(legacy.effectiveAmount, equals(BigInt.from(10000)));

        // Test outputs-based
        final outputsCompleter = Completer<InvoiceCreatedMessage>();
        final outputsReceiver = await actorSystem.spawn(
          'outputs-receiver',
          () => _TestReceiverActor<InvoiceCreatedMessage>(outputsCompleter),
        );

        invoiceManager.tell(
          CreateInvoiceMessage(
            walletId: 'wallet2',
            outputs: [
              P2PKHOutputSpec(address: 'mAddr', amount: BigInt.from(3000)),
              P2PKHOutputSpec(address: 'mAddr2', amount: BigInt.from(7000)),
            ],
          ),
          sender: outputsReceiver,
        );

        final outputsBased = await outputsCompleter.future;
        expect(outputsBased.effectiveAmount, equals(BigInt.from(10000)));

        print('✓ effectiveAmount consistent for both modes');
      });
    });

    group('Invoice Details with Outputs', () {
      test('CheckInvoiceMessage returns outputs in response', () async {
        // Create invoice with outputs
        final createCompleter = Completer<InvoiceCreatedMessage>();
        final createReceiver = await actorSystem.spawn(
          'create-for-details',
          () => _TestReceiverActor<InvoiceCreatedMessage>(createCompleter),
        );

        final outputs = [
          P2PKHOutputSpec(address: 'mCheckAddr', amount: BigInt.from(5000)),
          P2MSOutputSpec(
            publicKeys: [validPubKey1, validPubKey2],
            threshold: 2,
            amount: BigInt.from(10000),
          ),
        ];

        invoiceManager.tell(
          CreateInvoiceMessage(walletId: 'check-wallet', outputs: outputs),
          sender: createReceiver,
        );

        final invoice = await createCompleter.future;

        // Check invoice details
        final checkCompleter = Completer<InvoiceDetailsResponse>();
        final checkReceiver = await actorSystem.spawn(
          'check-receiver',
          () => _TestReceiverActor<InvoiceDetailsResponse>(checkCompleter),
        );

        invoiceManager.tell(
          CheckInvoiceMessage(invoice.invoiceId),
          sender: checkReceiver,
        );

        final details = await checkCompleter.future;

        expect(details.found, isTrue);
        expect(details.outputs, isNotNull);
        expect(details.outputs!.length, equals(2));
        expect(details.effectiveAmount, equals(BigInt.from(15000)));

        print('✓ Invoice details include outputs');
      });
    });
  });
}

/// Mock invoice manager that fully supports outputs
class _MockInvoiceManagerWithOutputsActor extends Actor {
  final Map<String, Invoice> _invoices = {};
  int _invoiceCounter = 0;

  _MockInvoiceManagerWithOutputsActor(InMemoryWalletStorage storage);

  @override
  Future<void> onMessage(dynamic message) async {
    if (message is CreateInvoiceMessage) {
      _invoiceCounter++;
      final invoiceId = 'test-invoice-$_invoiceCounter';

      await Future.delayed(Duration(milliseconds: 10));

      // Determine outputs
      List<InvoiceOutputSpec>? finalOutputs;
      List<String> addresses;
      BigInt amount;

      if (message.outputs != null && message.outputs!.isNotEmpty) {
        // New mode: use outputs directly
        finalOutputs = message.outputs;
        addresses = message.outputs!
            .whereType<P2PKHOutputSpec>()
            .map((o) => o.address)
            .toList();
        amount = message.outputs!
            .fold<BigInt>(BigInt.zero, (sum, o) => sum + o.amount);
      } else {
        // Legacy mode: generate addresses
        addresses = List.generate(
          message.numberOfAddresses,
          (index) => 'mock-address-${_invoiceCounter}-${index + 1}',
        );
        amount = message.amount ?? BigInt.zero;
        // Optionally convert to outputs for consistency
        final amountPerAddr = amount ~/ BigInt.from(addresses.length);
        finalOutputs = addresses
            .map((addr) => P2PKHOutputSpec(address: addr, amount: amountPerAddr))
            .toList();
      }

      final invoice = Invoice(
        invoiceId: invoiceId,
        walletId: message.walletId,
        addresses: addresses,
        amount: amount,
        outputs: finalOutputs,
        description: message.description,
        status: InvoiceStatus.pending,
        createdAt: DateTime.now(),
        expiresAt: message.expiresIn != null
            ? DateTime.now().add(message.expiresIn!)
            : null,
        metadata: message.invoiceMetadata,
      );

      _invoices[invoiceId] = invoice;

      context.sender?.tell(InvoiceCreatedMessage(
        invoiceId: invoiceId,
        walletId: message.walletId,
        addresses: addresses,
        amount: amount,
        outputs: finalOutputs,
        description: message.description,
        createdAt: invoice.createdAt,
        expiresAt: invoice.expiresAt,
        success: true,
        error: null,
      ));
    } else if (message is MarkInvoicePaidMessage) {
      final invoice = _invoices[message.invoiceId];
      if (invoice != null) {
        _invoices[message.invoiceId] = Invoice(
          invoiceId: invoice.invoiceId,
          walletId: invoice.walletId,
          addresses: invoice.addresses,
          amount: invoice.amount,
          outputs: invoice.outputs,
          description: invoice.description,
          status: InvoiceStatus.paid,
          createdAt: invoice.createdAt,
          expiresAt: invoice.expiresAt,
          paidAt: message.paidAt,
          paymentTxid: message.txid,
          amountReceived: message.amountReceived,
          metadata: invoice.metadata,
        );
      }

      context.sender?.tell(InvoiceStatusMessage(
        invoiceId: message.invoiceId,
        status: InvoiceStatus.paid,
        paidAt: message.paidAt,
        txid: message.txid,
        statusMessage: 'Invoice marked as paid',
      ));
    } else if (message is CheckInvoiceMessage) {
      final invoice = _invoices[message.invoiceId];
      if (invoice != null) {
        context.sender?.tell(InvoiceDetailsResponse(
          invoiceId: invoice.invoiceId,
          walletId: invoice.walletId,
          addresses: invoice.addresses,
          amount: invoice.amount,
          outputs: invoice.outputs,
          description: invoice.description,
          status: invoice.status,
          createdAt: invoice.createdAt,
          expiresAt: invoice.expiresAt,
          paidAt: invoice.paidAt,
          paymentTxid: invoice.paymentTxid,
          found: true,
        ));
      } else {
        context.sender?.tell(InvoiceDetailsResponse(
          invoiceId: message.invoiceId,
          addresses: [],
          amount: BigInt.zero,
          status: InvoiceStatus.pending,
          createdAt: DateTime.now(),
          found: false,
        ));
      }
    } else if (message is CancelInvoiceMessage) {
      final invoice = _invoices[message.invoiceId];
      if (invoice != null) {
        _invoices[message.invoiceId] = Invoice(
          invoiceId: invoice.invoiceId,
          walletId: invoice.walletId,
          addresses: invoice.addresses,
          amount: invoice.amount,
          outputs: invoice.outputs,
          description: invoice.description,
          status: InvoiceStatus.cancelled,
          createdAt: invoice.createdAt,
          expiresAt: invoice.expiresAt,
          metadata: invoice.metadata,
        );
      }

      context.sender?.tell(InvoiceStatusMessage(
        invoiceId: message.invoiceId,
        status: InvoiceStatus.cancelled,
        statusMessage: 'Invoice cancelled',
      ));
    }
  }
}

/// Generic test receiver actor
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
