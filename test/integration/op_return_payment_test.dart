/// OP_RETURN BEEF Transaction Integration Test via External API
///
/// Tests the complete OP_RETURN payment flow through the public actor message API:
/// CreateInvoiceMessage → invoiceCoordinator, then PayInvoiceMessage → paymentCoordinator
/// → BEEFPaymentResponse.
///
/// This mirrors the exact path the mobile client uses when creating timestamp transactions.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:dactor/dactor.dart';
import 'package:isar/isar.dart';
import 'package:libspiffy/libspiffy.dart';
import 'package:libspiffy/src/actors/libspiffy_actor_system.dart';
import 'package:libspiffy/src/actors/invoice_messages.dart';
import 'package:libspiffy/src/actors/payment_messages.dart';
import 'package:libspiffy/src/storage/isar_wallet_storage.dart';
import 'package:libspiffy/src/utils/beef.dart';
import 'isar_test_helper.dart';
import 'p2p_test_helpers.dart';

void main() {
  group('OP_RETURN Payment via External API', () {
    late LibSpiffyActorSystem libSpiffy;
    late Isar isar;
    late LocalActorSystem actorSystem;
    late Directory testDir;
    late String walletId;

    setUpAll(() async {
      await ensureIsarInitialized();
    });

    setUp(() async {
      print('\n--- Setting up OP_RETURN test system ---');

      testDir = await Directory.systemTemp.createTemp('op_return_test_');
      actorSystem = LocalActorSystem(ActorSystemConfig());

      final dbName = 'op_return_db_${DateTime.now().microsecondsSinceEpoch}';
      isar = await Isar.open(
        [...LibSpiffySchemas.allSchemas],
        directory: testDir.path,
        name: dbName,
      );

      libSpiffy = LibSpiffyActorSystem();
      await libSpiffy.initialize(
        actorSystem: actorSystem,
        isar: isar,
        dataDirectory: testDir.path,
        enableP2P: false,
      );

      await setupTestHeaders(libSpiffy.walletStorage as IsarWalletStorage);

      walletId = 'op-return-wallet-${DateTime.now().millisecondsSinceEpoch}';
      await createWallet(
        walletManager: libSpiffy.walletManager,
        actorSystem: actorSystem,
        walletId: walletId,
        walletName: 'OP_RETURN Test Wallet',
        xpriv: kTestXpriv,
      );

      await fundWallet(
        walletManager: libSpiffy.walletManager,
        actorSystem: actorSystem,
        walletId: walletId,
        amount: BigInt.from(200000000), // 2 BSV
      );

      print('--- Setup complete ---\n');
    });

    tearDown(() async {
      await libSpiffy.shutdown();
      try {
        await testDir.delete(recursive: true);
      } catch (e) {
        print('Warning: Could not delete test directory: $e');
      }
    });

    test('Create invoice with OP_RETURN output and pay it → valid BEEF response', () async {
      print('\n=== Test: OP_RETURN invoice → pay → BEEF ===');

      // Create a SHA-256 hash to embed as timestamp data
      final timestampData = utf8.encode('timestamp-${DateTime.now().toIso8601String()}');
      final sha256Hash = sha256.convert(timestampData).bytes;

      // Step 1: Create invoice with OP_RETURN output
      final createCompleter = Completer<InvoiceCreatedMessage>();
      final createReceiver = await actorSystem.spawn(
        'op-return-create-receiver',
        () => TestReceiverActor<InvoiceCreatedMessage>(createCompleter),
      );

      libSpiffy.invoiceCoordinator.tell(
        CreateInvoiceMessage(
          walletId: walletId,
          outputs: [
            OPReturnOutputSpec(dataChunks: [sha256Hash]),
          ],
          description: 'Timestamp OP_RETURN',
        ),
        sender: createReceiver,
      );

      final invoice = await createCompleter.future.timeout(Duration(seconds: 10));
      expect(invoice.success, isTrue, reason: 'Invoice creation should succeed: ${invoice.error}');
      print('Invoice created: ${invoice.invoiceId}');

      // Step 2: Pay the invoice via paymentCoordinator
      final payCompleter = Completer<BEEFPaymentResponse>();
      final payReceiver = await actorSystem.spawn(
        'op-return-pay-receiver',
        () => TestReceiverActor<BEEFPaymentResponse>(payCompleter),
      );

      libSpiffy.paymentCoordinator.tell(
        PayInvoiceMessage(
          walletId: walletId,
          invoiceId: invoice.invoiceId,
          addresses: invoice.addresses,
          amount: invoice.amount,
          outputs: invoice.outputs,
        ),
        sender: payReceiver,
      );

      final response = await payCompleter.future.timeout(Duration(seconds: 15));
      print('Payment response: success=${response.success}, txid=${response.txid}, error=${response.error}');

      expect(response.success, isTrue, reason: 'Payment should succeed: ${response.error}');
      expect(response.txid, isNotEmpty, reason: 'TXID should be non-empty');
      expect(response.beefBytes, isNotEmpty, reason: 'BEEF bytes should be non-empty');

      // Step 3: Parse and validate BEEF structure
      final beef = BEEF.parse(response.beefBytes);
      expect(beef.txs, isNotEmpty, reason: 'BEEF should contain at least one transaction');
      expect(beef.validate(), isTrue, reason: 'BEEF should be structurally valid');
      print('BEEF validated: ${beef.txs.length} tx(s), ${beef.bumps.length} BUMP(s)');

      print('=== OP_RETURN → BEEF test passed ===\n');
    });

    test('OP_RETURN + P2PKH combined (data embed + value transfer)', () async {
      print('\n=== Test: OP_RETURN + P2PKH combined ===');

      final dataToEmbed = utf8.encode('combined-test-data');
      final dataHash = sha256.convert(dataToEmbed).bytes;

      // Create invoice with both P2PKH and OP_RETURN outputs
      final createCompleter = Completer<InvoiceCreatedMessage>();
      final createReceiver = await actorSystem.spawn(
        'combined-create-receiver',
        () => TestReceiverActor<InvoiceCreatedMessage>(createCompleter),
      );

      libSpiffy.invoiceCoordinator.tell(
        CreateInvoiceMessage(
          walletId: walletId,
          outputs: [
            P2PKHOutputSpec(
              address: kTestRootAddress,
              amount: BigInt.from(10000),
            ),
            OPReturnOutputSpec(dataChunks: [dataHash]),
          ],
          description: 'Combined P2PKH + OP_RETURN',
        ),
        sender: createReceiver,
      );

      final invoice = await createCompleter.future.timeout(Duration(seconds: 10));
      expect(invoice.success, isTrue, reason: 'Invoice creation should succeed: ${invoice.error}');
      print('Invoice created with ${invoice.outputs?.length ?? 0} output specs');

      // Pay via paymentCoordinator
      final payCompleter = Completer<BEEFPaymentResponse>();
      final payReceiver = await actorSystem.spawn(
        'combined-pay-receiver',
        () => TestReceiverActor<BEEFPaymentResponse>(payCompleter),
      );

      libSpiffy.paymentCoordinator.tell(
        PayInvoiceMessage(
          walletId: walletId,
          invoiceId: invoice.invoiceId,
          addresses: invoice.addresses,
          amount: invoice.effectiveAmount,
          outputs: invoice.outputs,
        ),
        sender: payReceiver,
      );

      final response = await payCompleter.future.timeout(Duration(seconds: 15));
      print('Payment response: success=${response.success}, txid=${response.txid}, error=${response.error}');

      expect(response.success, isTrue, reason: 'Payment should succeed: ${response.error}');
      expect(response.txid, isNotEmpty);
      expect(response.beefBytes, isNotEmpty);

      final beef = BEEF.parse(response.beefBytes);
      expect(beef.txs, isNotEmpty);
      expect(beef.validate(), isTrue);
      print('BEEF validated: ${beef.txs.length} tx(s), ${beef.bumps.length} BUMP(s)');

      print('=== Combined test passed ===\n');
    });

    test('OP_RETURN with multiple data chunks (separateOutputs=false)', () async {
      print('\n=== Test: OP_RETURN multiple chunks, single output ===');

      final chunk1 = utf8.encode('chunk-one');
      final chunk2 = utf8.encode('chunk-two');
      final chunk3 = utf8.encode('chunk-three');

      // Create invoice with multiple chunks in a single OP_RETURN
      final createCompleter = Completer<InvoiceCreatedMessage>();
      final createReceiver = await actorSystem.spawn(
        'multi-chunk-create-receiver',
        () => TestReceiverActor<InvoiceCreatedMessage>(createCompleter),
      );

      libSpiffy.invoiceCoordinator.tell(
        CreateInvoiceMessage(
          walletId: walletId,
          outputs: [
            OPReturnOutputSpec(
              dataChunks: [chunk1, chunk2, chunk3],
              separateOutputs: false,
            ),
          ],
          description: 'Multi-chunk single OP_RETURN',
        ),
        sender: createReceiver,
      );

      final invoice = await createCompleter.future.timeout(Duration(seconds: 10));
      expect(invoice.success, isTrue, reason: 'Invoice creation should succeed: ${invoice.error}');

      // Pay via paymentCoordinator
      final payCompleter = Completer<BEEFPaymentResponse>();
      final payReceiver = await actorSystem.spawn(
        'multi-chunk-pay-receiver',
        () => TestReceiverActor<BEEFPaymentResponse>(payCompleter),
      );

      libSpiffy.paymentCoordinator.tell(
        PayInvoiceMessage(
          walletId: walletId,
          invoiceId: invoice.invoiceId,
          addresses: invoice.addresses,
          amount: invoice.effectiveAmount,
          outputs: invoice.outputs,
        ),
        sender: payReceiver,
      );

      final response = await payCompleter.future.timeout(Duration(seconds: 15));
      print('Payment response: success=${response.success}, txid=${response.txid}, error=${response.error}');

      expect(response.success, isTrue, reason: 'Payment should succeed: ${response.error}');
      expect(response.txid, isNotEmpty);
      expect(response.beefBytes, isNotEmpty);

      final beef = BEEF.parse(response.beefBytes);
      expect(beef.txs, isNotEmpty);
      expect(beef.validate(), isTrue);
      print('BEEF validated: ${beef.txs.length} tx(s)');

      print('=== Multi-chunk single output test passed ===\n');
    });

    test('OP_RETURN with separateOutputs=true', () async {
      print('\n=== Test: OP_RETURN separateOutputs=true ===');

      final chunk1 = utf8.encode('separate-one');
      final chunk2 = utf8.encode('separate-two');

      // Create invoice with separateOutputs=true
      final createCompleter = Completer<InvoiceCreatedMessage>();
      final createReceiver = await actorSystem.spawn(
        'separate-create-receiver',
        () => TestReceiverActor<InvoiceCreatedMessage>(createCompleter),
      );

      libSpiffy.invoiceCoordinator.tell(
        CreateInvoiceMessage(
          walletId: walletId,
          outputs: [
            OPReturnOutputSpec(
              dataChunks: [chunk1, chunk2],
              separateOutputs: true,
            ),
          ],
          description: 'Separate OP_RETURN outputs',
        ),
        sender: createReceiver,
      );

      final invoice = await createCompleter.future.timeout(Duration(seconds: 10));
      expect(invoice.success, isTrue, reason: 'Invoice creation should succeed: ${invoice.error}');

      // Pay via paymentCoordinator
      final payCompleter = Completer<BEEFPaymentResponse>();
      final payReceiver = await actorSystem.spawn(
        'separate-pay-receiver',
        () => TestReceiverActor<BEEFPaymentResponse>(payCompleter),
      );

      libSpiffy.paymentCoordinator.tell(
        PayInvoiceMessage(
          walletId: walletId,
          invoiceId: invoice.invoiceId,
          addresses: invoice.addresses,
          amount: invoice.effectiveAmount,
          outputs: invoice.outputs,
        ),
        sender: payReceiver,
      );

      final response = await payCompleter.future.timeout(Duration(seconds: 15));
      print('Payment response: success=${response.success}, txid=${response.txid}, error=${response.error}');

      expect(response.success, isTrue, reason: 'Payment should succeed: ${response.error}');
      expect(response.txid, isNotEmpty);
      expect(response.beefBytes, isNotEmpty);

      final beef = BEEF.parse(response.beefBytes);
      expect(beef.txs, isNotEmpty);
      expect(beef.validate(), isTrue);
      print('BEEF validated: ${beef.txs.length} tx(s)');

      print('=== Separate outputs test passed ===\n');
    });

    test('OverNode-style: PayInvoiceMessage direct to paymentCoordinator (no invoice creation)', () async {
      print('\n=== Test: OverNode timestamp flow (direct PayInvoiceMessage) ===');

      // Replicate exactly how overnode_v2 wallet_coordinator_actor.dart:1420-1494
      // creates an OP_RETURN timestamp transaction:
      //   1. Build multiple OPReturnOutputSpec (header + per-file-hash)
      //   2. Send PayInvoiceMessage directly to paymentCoordinator
      //      with addresses: [], amount: BigInt.zero, outputs: [...]
      //   3. No CreateInvoiceMessage step

      final archiveId = 'test-archive-${DateTime.now().millisecondsSinceEpoch}';

      // Simulate 3 file hashes (SHA-256)
      final fileHash1 = sha256.convert(utf8.encode('file-one.pdf')).bytes;
      final fileHash2 = sha256.convert(utf8.encode('file-two.jpg')).bytes;
      final fileHash3 = sha256.convert(utf8.encode('file-three.txt')).bytes;

      // Build outputs exactly as OverNode does
      final outputs = <InvoiceOutputSpec>[];

      // Output 0: protocol header with archive ID (2 data chunks in one OP_RETURN)
      outputs.add(OPReturnOutputSpec(
        dataChunks: [
          utf8.encode('overnode.ts.v1'),
          utf8.encode(archiveId),
        ],
        label: 'Timestamp header',
      ));

      // Outputs 1..N: one OP_RETURN per file hash (raw 32 bytes each)
      for (final hashBytes in [fileHash1, fileHash2, fileHash3]) {
        outputs.add(OPReturnOutputSpec(
          dataChunks: [hashBytes],
          label: 'File hash',
        ));
      }

      // Generate correlation ID same way OverNode does
      final invoiceId = 'ts-$archiveId-${DateTime.now().millisecondsSinceEpoch}';

      print('Archive ID: $archiveId');
      print('Invoice ID: $invoiceId');
      print('Outputs: ${outputs.length} (1 header + 3 file hashes)');

      // Send PayInvoiceMessage directly — no CreateInvoiceMessage
      final payCompleter = Completer<BEEFPaymentResponse>();
      final payReceiver = await actorSystem.spawn(
        'overnode-ts-pay-receiver',
        () => TestReceiverActor<BEEFPaymentResponse>(payCompleter),
      );

      libSpiffy.paymentCoordinator.tell(
        PayInvoiceMessage(
          walletId: walletId,
          invoiceId: invoiceId,
          addresses: [],          // OverNode passes empty list
          amount: BigInt.zero,    // OverNode passes zero
          outputs: outputs,
        ),
        sender: payReceiver,
      );

      final response = await payCompleter.future.timeout(Duration(seconds: 15));
      print('Payment response: success=${response.success}, txid=${response.txid}, error=${response.error}');

      expect(response.success, isTrue, reason: 'Payment should succeed: ${response.error}');
      expect(response.txid, isNotEmpty, reason: 'TXID should be non-empty');
      expect(response.beefBytes, isNotEmpty, reason: 'BEEF bytes should be non-empty');
      expect(response.amountPaid, equals(BigInt.zero),
          reason: 'OP_RETURN-only payment amount should be zero');

      // Parse and validate BEEF
      final beef = BEEF.parse(response.beefBytes);
      expect(beef.txs, isNotEmpty, reason: 'BEEF should contain transactions');
      expect(beef.validate(), isTrue, reason: 'BEEF should be structurally valid');

      // The payment tx should be the last tx in BEEF (ancestors come first)
      // It should have: 1 input (funding UTXO) + 4 OP_RETURN outputs + 1 change output = 5 outputs
      print('BEEF validated: ${beef.txs.length} tx(s), ${beef.bumps.length} BUMP(s)');
      print('Ancestor count: ${response.ancestorCount}');
      print('Change amount: ${response.changeAmount} sats');

      expect(response.changeAmount, greaterThan(BigInt.zero),
          reason: 'Should have change returned from funding UTXO');

      print('=== OverNode timestamp flow test passed ===\n');
    });
  });
}
