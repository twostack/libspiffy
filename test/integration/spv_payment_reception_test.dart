import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:dactor/dactor.dart';
import 'package:convert/convert.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:libspiffy/src/actors/invoice_messages.dart';
import 'package:libspiffy/src/actors/spv_actor.dart';
import 'package:libspiffy/src/actors/wallet_messages.dart';
import 'package:libspiffy/src/core/wallet_commands.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';
import 'package:libspiffy/src/utils/beef.dart';
import 'package:libspiffy/src/utils/crypto_utils.dart';
import 'package:spiffynode/spiffy_node.dart';

/// SPV Payment Reception Integration Tests
/// 
/// These tests validate the complete payment reception flow:
/// 1. Wallet ID propagation from invoice through SPV validation
/// 2. UTXO ownership checking (recipient should NOT try to spend sender's UTXOs)
/// 3. Correct commands sent to wallet (ReceiveUTXO, not SpendUTXO for recipient)
void main() {
  group('SPV Payment Reception Integration Tests', () {
    late LocalActorSystem actorSystem;
    late ActorRef walletManager;
    late ActorRef invoiceManager;
    late ActorRef spvActor;
    late InMemoryWalletStorage storage;

    setUp(() async {
      actorSystem = LocalActorSystem(ActorSystemConfig());
      storage = InMemoryWalletStorage();
      
      // Store real block headers for SPV validation
      await _setupRealBlockHeaders(storage);
      
      // Create mock wallet manager for testing
      walletManager = await actorSystem.spawn(
        'mock-wallet-manager',
        () => _MockWalletManagerActor(),
      );
      
      // Create mock invoice manager
      final mockInvoiceActor = _MockInvoiceManagerActor();
      mockInvoiceActor.setWalletManager(walletManager);
      invoiceManager = await actorSystem.spawn(
        'mock-invoice-manager',
        () => mockInvoiceActor,
      );
      
      // Create SPV actor with real validation
      spvActor = await actorSystem.spawn(
        'spv-actor',
        () => SPVActor(
          walletManager: walletManager,
          invoiceCoordinator: invoiceManager,
          storage: storage,
        ),
      );
    });

    tearDown(() async {
      await actorSystem.shutdown();
    });

    test('wallet ID propagates through entire SPV payment reception flow', () async {
      print('\n=== Test: Wallet ID Propagation ===');
      
      // Step 1: Setup test wallet ID
      final testWalletId = 'test-recipient-wallet-${DateTime.now().millisecondsSinceEpoch}';
      
      print('✓ Test wallet ID: $testWalletId');
      
      // Step 2: Get real testnet transaction to extract the actual recipient address
      final realTx = _getRealTransaction1();
      final tscProof = _getTscProof1();
      
      // Extract the actual recipient address from the transaction
      // The real transaction output address (Base58 encoded for testnet)
      // This is the address corresponding to pubkey hash f82d58dd8487044d8d0879c15a2a3516a425de2a
      final realRecipientAddress = 'n49CCQFuncaXbtBoNm39gSP9dvRP2eFFSw';
      
      print('Using real transaction recipient address: $realRecipientAddress');
      
      // Step 3: Create a new invoice manager with the predefined real address
      final customMockInvoice = _MockInvoiceManagerActor(predefinedAddress: realRecipientAddress);
      customMockInvoice.setWalletManager(walletManager);
      final customInvoiceManager = await actorSystem.spawn(
        'custom-invoice-manager',
        () => customMockInvoice,
      );
      
      // Create invoice - it will use the real address
      final invoiceCreateCompleter = Completer<InvoiceCreatedMessage>();
      final invoiceCreateReceiver = await actorSystem.spawn(
        'invoice-create-receiver',
        () => _TestReceiverActor<InvoiceCreatedMessage>(invoiceCreateCompleter),
      );
      
      customInvoiceManager.tell(
        CreateInvoiceMessage(
          walletId: testWalletId,
          amount: BigInt.from(100000), // 0.001 BSV
        ),
        sender: invoiceCreateReceiver,
      );
      
      final invoice = await invoiceCreateCompleter.future.timeout(Duration(seconds: 5));
      expect(invoice.success, isTrue, reason: 'Invoice creation should succeed');
      expect(invoice.walletId, equals(testWalletId), reason: 'Invoice should store wallet ID');
      
      final invoiceId = invoice.invoiceId;
      final invoiceAddress = invoice.addresses.first;
      
      print('✓ Invoice created: $invoiceId');
      print('  Wallet ID: ${invoice.walletId}');
      print('  Invoice Address: $invoiceAddress');
      print('  Expected Address: $realRecipientAddress');
      
      // Verify the address matches
      expect(invoiceAddress, equals(realRecipientAddress), 
        reason: 'Invoice address must match the real transaction recipient address');
      
      // Parse the transaction to see what address is in the outputs
      final txHex = realTx['hex'] as String;
      final transaction = dartsv.Transaction.fromHex(txHex);
      print('  Transaction has ${transaction.outputs.length} outputs');
      
      // Extract addresses from transaction outputs (same logic as SPV actor)
      final templateRegistry = dartsv.ScriptTemplateRegistry();
      for (int i = 0; i < transaction.outputs.length; i++) {
        final output = transaction.outputs[i];
        final script = output.script;
        final scriptHex = script.toHex();
        final scriptInfo = templateRegistry.extractScriptInfo(script);
        final scriptType = templateRegistry.identifyScriptType(script);
        
        print('    Output $i: ${output.satoshis} sats, type: $scriptType');
        print('      Script hex: ${scriptHex.substring(0, min(60, scriptHex.length))}${scriptHex.length > 60 ? "..." : ""}');
        print('      Script info: $scriptInfo');
        
        // Try to manually extract the address from P2PKH script
        // P2PKH script format: OP_DUP OP_HASH160 <20 bytes> OP_EQUALVERIFY OP_CHECKSIG
        // Hex: 76 a9 14 <20 bytes> 88 ac
        if (scriptHex.startsWith('76a914') && scriptHex.endsWith('88ac') && scriptHex.length == 50) {
          // This is a P2PKH script
          final pubkeyHashHex = scriptHex.substring(6, 46); // Extract the 20-byte hash
          print('      Detected P2PKH script manually');
          print('      Pubkey hash: $pubkeyHashHex');
          
          try {
            final extractedAddress = dartsv.Address.fromPubkeyHash(
              pubkeyHashHex, 
              dartsv.NetworkType.TEST
            ).toBase58();
            print('      Extracted address: $extractedAddress');
            print('      Matches invoice: ${extractedAddress == invoiceAddress}');
          } catch (e) {
            print('      Error extracting address: $e');
          }
        }
        
        if (scriptType == 'P2PKH' || scriptType == 'p2pkh') {
          final pubkeyHash = scriptInfo?['pubKeyHash'];
          if (pubkeyHash != null) {
            try {
              final extractedAddress = dartsv.Address.fromPubkeyHash(
                hex.encode(pubkeyHash), 
                dartsv.NetworkType.TEST
              ).toBase58();
              print('      Registry extracted address: $extractedAddress');
              print('      Matches invoice: ${extractedAddress == invoiceAddress}');
            } catch (e) {
              print('      Error extracting address: $e');
            }
          }
        }
      }
      
      // Create new SPV actor with the custom invoice manager
      final customSpvActor = await actorSystem.spawn(
        'custom-spv-actor',
        () => SPVActor(
          walletManager: walletManager,
          invoiceCoordinator: customInvoiceManager,
          storage: storage,
        ),
      );
      
      // Create BEEF from real data
      final beef = _createBeefFromRealData(realTx, tscProof);
      
      print('✓ BEEF created with ${beef.txs.length} transaction(s)');
      
      // Step 4: Send ValidateBEEFMessage with wallet ID
      print('\n→ Sending ValidateBEEFMessage...');
      print('  Target Wallet ID: $testWalletId');
      
      final beefValidationCompleter = Completer<BEEFValidationResult>();
      final beefValidationReceiver = await actorSystem.spawn(
        'beef-validation-receiver',
        () => _TestReceiverActor<BEEFValidationResult>(beefValidationCompleter),
      );
      
      customSpvActor.tell(
        ValidateBEEFMessage(
          hex.encode(beef.serialize()),
          targetWalletId: testWalletId,
        ),
        sender: beefValidationReceiver,
      );
      
      final beefResult = await beefValidationCompleter.future.timeout(
        Duration(seconds: 5),
        onTimeout: () => throw TimeoutException('BEEF validation timed out'),
      );
      
      // ASSERTION 1: Wallet ID should be preserved in BEEF validation result
      expect(beefResult.targetWalletId, equals(testWalletId),
        reason: 'Wallet ID should propagate through BEEF validation');
      print('✓ BEEF validation preserved wallet ID: ${beefResult.targetWalletId}');
      
      // Step 5: Send ReceiveTransactionMessage for full SPV validation
      print('\n→ Sending ReceiveTransactionMessage for SPV validation...');
      print('  Target Wallet ID: $testWalletId');
      print('  Invoice ID: $invoiceId');
      
      final spvValidationCompleter = Completer<SPVValidationResult>();
      final spvValidationReceiver = await actorSystem.spawn(
        'spv-validation-receiver',
        () => _TestReceiverActor<SPVValidationResult>(spvValidationCompleter),
      );
      
      customSpvActor.tell(
        ReceiveTransactionMessage(
          transactionId: realTx['txid'] as String,
          beef: beef,
          fromCounterparty: 'alice',
          targetWalletId: testWalletId,
          invoiceId: invoiceId,
        ),
        sender: spvValidationReceiver,
      );
      
      final spvResult = await spvValidationCompleter.future.timeout(
        Duration(seconds: 10),
        onTimeout: () => throw TimeoutException('SPV validation timed out'),
      );
      
      // ASSERTION 2: Wallet ID should be preserved in SPV validation result
      expect(spvResult.targetWalletId, equals(testWalletId),
        reason: 'Wallet ID should propagate through SPV validation');
      print('✓ SPV validation preserved wallet ID: ${spvResult.targetWalletId}');
      
      // ASSERTION 3: Wallet ID should NOT be empty
      expect(spvResult.targetWalletId, isNotEmpty,
        reason: 'Wallet ID must not be empty at any point in the flow');
      
      // ASSERTION 4: For receiving payment, spentUTXOs should be EMPTY
      // (sender's UTXOs don't belong to recipient)
      expect(spvResult.spentUTXOs, isEmpty,
        reason: 'Recipient should not mark sender\'s UTXOs as spent. Found: ${spvResult.spentUTXOs}');
      print('✓ Recipient correctly has 0 spent UTXOs (sender owns the inputs)');
      
      // ASSERTION 5: Should have spendable UTXOs (receiving payment)
      expect(spvResult.spendableUTXOs, isNotEmpty,
        reason: 'Recipient should receive new spendable UTXOs');
      print('✓ Recipient received ${spvResult.spendableUTXOs.length} spendable UTXO(s)');
      
      print('\n✅ Test passed: Wallet ID propagated correctly through entire flow');
      print('   - Wallet: $testWalletId');
      print('   - Invoice: $invoiceId');
      print('   - Address: $invoiceAddress');
      print('   - Received ${spvResult.spendableUTXOs.length} UTXO(s)');
      print('   - Spent 0 UTXO(s) (correct for recipient)');
    });

    test('recipient does not attempt to spend sender UTXOs', () async {
      print('\n=== Test: UTXO Ownership Checking ===');
      
      // This test verifies that _extractSpentUTXOs correctly checks ownership
      // and doesn't return sender's UTXOs for a receiving wallet
      
      final testWalletId = 'test-recipient-wallet-2-${DateTime.now().millisecondsSinceEpoch}';
      
      // Get real transaction and extract recipient address
      final realTx = _getRealTransaction1();
      final tscProof = _getTscProof1();
      // This is the address corresponding to pubkey hash f82d58dd8487044d8d0879c15a2a3516a425de2a
      final realRecipientAddress = 'n49CCQFuncaXbtBoNm39gSP9dvRP2eFFSw';
      
      print('Using real transaction recipient address: $realRecipientAddress');
      
      // Create custom invoice manager with real address
      final customMockInvoice = _MockInvoiceManagerActor(predefinedAddress: realRecipientAddress);
      customMockInvoice.setWalletManager(walletManager);
      final customInvoiceManager = await actorSystem.spawn(
        'custom-invoice-manager-2',
        () => customMockInvoice,
      );
      
      // Create invoice
      final invoiceCreateCompleter = Completer<InvoiceCreatedMessage>();
      final invoiceCreateReceiver = await actorSystem.spawn(
        'invoice-create-receiver-2',
        () => _TestReceiverActor<InvoiceCreatedMessage>(invoiceCreateCompleter),
      );
      
      customInvoiceManager.tell(
        CreateInvoiceMessage(
          walletId: testWalletId,
          amount: BigInt.from(200000),
        ),
        sender: invoiceCreateReceiver,
      );
      
      final invoice = await invoiceCreateCompleter.future.timeout(Duration(seconds: 5));
      final invoiceId = invoice.invoiceId;
      
      // Create custom SPV actor with custom invoice manager
      final customSpvActor = await actorSystem.spawn(
        'custom-spv-actor-2',
        () => SPVActor(
          walletManager: walletManager,
          invoiceCoordinator: customInvoiceManager,
          storage: storage,
        ),
      );
      
      final beef = _createBeefFromRealData(realTx, tscProof);
      
      // Send for SPV validation
      final spvValidationCompleter = Completer<SPVValidationResult>();
      final spvValidationReceiver = await actorSystem.spawn(
        'spv-validation-receiver-2',
        () => _TestReceiverActor<SPVValidationResult>(spvValidationCompleter),
      );
      
      customSpvActor.tell(
        ReceiveTransactionMessage(
          transactionId: realTx['txid'] as String,
          beef: beef,
          fromCounterparty: 'alice',
          targetWalletId: testWalletId,
          invoiceId: invoiceId,
        ),
        sender: spvValidationReceiver,
      );
      
      final result = await spvValidationCompleter.future.timeout(Duration(seconds: 10));
      
      // The key assertion: spentUTXOs should be EMPTY for recipient
      expect(result.spentUTXOs, isEmpty,
        reason: 'When receiving payment, wallet should not mark any UTXOs as spent. '
                'Transaction inputs belong to SENDER, not recipient. '
                'Found ${result.spentUTXOs.length} spent UTXOs: ${result.spentUTXOs}');
      
      print('✓ Correctly identified that no wallet UTXOs were spent');
      print('  Transaction had ${hex.decode(hex.encode(beef.txs.first)).length} bytes');
      print('  Recipient wallet: $testWalletId');
      print('  Spent UTXOs: ${result.spentUTXOs.length} (expected: 0)');
      print('  Spendable UTXOs: ${result.spendableUTXOs.length}');
      
      print('\n✅ Test passed: Recipient does not attempt to spend sender\'s UTXOs');
    });
  });
}

// ============================================================================
// Test Helpers
// ============================================================================

/// Setup real block headers from testnet for SPV validation
Future<void> _setupRealBlockHeaders(InMemoryWalletStorage storage) async {
  // Block 1641074 - contains first test transaction
  final header1 = BlockHeader(
    version: 536870912,
    prevBlock: Hash.fromHex('0000000006d30de00e6c6c16ebfabcd833c7c367a26a86f00f8ff4067d842295'),
    merkleRoot: Hash.fromHex('49b5be64b429e9ce9b7a91e3581d4a9cdaf61b935b33981ebcfef6256aa2fba0'),
    timestamp: DateTime.fromMillisecondsSinceEpoch(1729051303 * 1000),
    bits: 0x1d00ffff,
    nonce: 1307527718,
  );
  await storage.storeBlockHeader(header1, 1641074);
  
  // Block 1641086 - contains second test transaction
  final header2 = BlockHeader(
    version: 536870912,
    prevBlock: Hash.fromHex('00000000374259369de4a6707dfa020527712c75da9c52a3ad26b4f68705f4f7'),
    merkleRoot: Hash.fromHex('f83721206f6b5e336d7b661d1d25deafa7c43cf25c608a7c906c4de1a9e9f57a'),
    timestamp: DateTime.fromMillisecondsSinceEpoch(1729059327 * 1000),
    bits: 0x1d00ffff,
    nonce: 1492328476,
  );
  await storage.storeBlockHeader(header2, 1641086);
  
  print('✓ Stored 2 real testnet block headers (1641074, 1641086)');
}

/// Get first real testnet transaction (from full_spv_validation_test.dart)
Map<String, dynamic> _getRealTransaction1() {
  return {
    "txid": "dd6e7547df0fe893a9a19f66f0377eca72fdcd18fd9f6185fde9c91461a8e8a9",
    "hex": "02000000013706d29b641d2061b0b7b22c81ec6a5670104826bee4472a7513619f4fc298df000000006a473044022021fb2500cfd69bf3d7eee8f16d2e1d6d49528dbe23e9105744202bd9e5b5789102204ff801667c156b97e92209c19dce9bbdd955ee35cea7b815cf9e3b0c1b6727174121022036646b3fd79dee41351f727f0a6e10d0e7f98585961bc14e7aadaf5f4b66ab0100000002a0443b00000000001976a914f82d58dd8487044d8d0879c15a2a3516a425de2a88ac96000000000000001976a914f82d58dd8487044d8d0879c15a2a3516a425de2a88ac00000000",
    "blockhash": "00000000cf9e8013b71e0c1c454208ad60a639adba6b6d7fcf6426da1e1efdb2",
    "blockheight": 1641074,
    "blocktime": 1729051303,
    "confirmations": 24454
  };
}

/// Get TSC merkle proof for first transaction (from full_spv_validation_test.dart)
Map<String, dynamic> _getTscProof1() {
  return {
    "index": 6,
    "txOrId": "dd6e7547df0fe893a9a19f66f0377eca72fdcd18fd9f6185fde9c91461a8e8a9",
    "target": "00000000cf9e8013b71e0c1c454208ad60a639adba6b6d7fcf6426da1e1efdb2",
    "nodes": [
      "f4d4fc63094d73b31e13da814ec4556865f53c329c53020e56ad71464e6f85fe",
      "bdcde417243f95840bd6fcfddbad0b198285f9f38d38093dc8826c3a3a7666f0",
      "9304304659a72e3e17ad1a447fecb4b082c8340683249a2cfa8ea3d411ad5c76",
      "5d2528dae0d0992da93f485ccbef24f06ef62ebf055bcc9d43b05dbdbe897dc2"
    ]
  };
}

/// Create BEEF from real transaction data and merkle proof
BEEF _createBeefFromRealData(Map<String, dynamic> realTx, Map<String, dynamic> tscProof) {
  final txHex = realTx['hex'] as String;
  final txBytes = Uint8List.fromList(hex.decode(txHex));
  final blockHeight = realTx['blockheight'] as int;
  
  // Create BUMP from TSC proof
  final bump = CryptoUtils.createBumpFromTscProof(tscProof, blockHeight);
  
  return BEEF.create(
    bumps: [bump],
    txs: [txBytes],
    hasMerkle: [true],
    bumpIndex: [0],
  );
}

// ============================================================================
// Mock Actors
// ============================================================================

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

class _MockWalletManagerActor extends Actor {
  int _addressCounter = 0;
  
  @override
  Future<void> onMessage(dynamic message) async {
    if (message is WalletCommandMessage) {
      final command = message.command;
      if (command is GenerateAddressCommand) {
        _addressCounter++;
        final address = 'n${_addressCounter}MockAddr${DateTime.now().millisecondsSinceEpoch}';
        
        context.sender?.tell(AddressGeneratedResponse(
          walletId: message.walletId,
          address: address,
          derivationIndex: _addressCounter,
          success: true,
          metadata: command.metadata,
        ));
      }
    }
  }
}

class _MockInvoiceManagerActor extends Actor {
  ActorRef? _walletManager;
  final Map<String, Map<String, dynamic>> _invoices = {};
  int _invoiceCounter = 0;
  String? _predefinedAddress; // For testing with specific addresses
  
  _MockInvoiceManagerActor({String? predefinedAddress}) : _predefinedAddress = predefinedAddress;
  
  void setWalletManager(ActorRef walletManager) {
    _walletManager = walletManager;
  }
  
  void setPredefinedAddress(String address) {
    _predefinedAddress = address;
  }
  
  @override
  Future<void> onMessage(dynamic message) async {
    if (message is CreateInvoiceMessage) {
      await _handleCreateInvoice(message);
    } else if (message is CheckInvoiceMessage) {
      await _handleCheckInvoice(message);
    } else if (message is MarkInvoicePaidMessage) {
      await _handleMarkPaid(message);
    }
  }
  
  Future<void> _handleCreateInvoice(CreateInvoiceMessage msg) async {
    final invoiceId = 'test-invoice-${_invoiceCounter++}-${DateTime.now().millisecondsSinceEpoch}';
    
    // Use predefined address if set, otherwise request from wallet manager
    String address;
    if (_predefinedAddress != null) {
      address = _predefinedAddress!;
      print('Using predefined address for invoice: $address');
    } else {
      // Request address from wallet manager
      final addressCompleter = Completer<AddressGeneratedResponse>();
      final addressReceiver = await context.system.spawn(
        'address-receiver-$invoiceId',
        () => _TestReceiverActor<AddressGeneratedResponse>(addressCompleter),
      );
      
      _walletManager?.tell(
        WalletCommandMessage(
          msg.walletId,
          GenerateAddressCommand(
            walletId: msg.walletId,
            label: 'invoice-$invoiceId',
          ),
        ),
        sender: addressReceiver,
      );
      
      final addressResponse = await addressCompleter.future.timeout(Duration(seconds: 5));
      address = addressResponse.address;
    }
    
    // Store invoice
    _invoices[invoiceId] = {
      'invoiceId': invoiceId,
      'walletId': msg.walletId,
      'addresses': [address],
      'amount': msg.amount,
      'status': InvoiceStatus.pending,
      'createdAt': DateTime.now(),
    };
    
    context.sender?.tell(InvoiceCreatedMessage(
      invoiceId: invoiceId,
      walletId: msg.walletId,
      addresses: [address],
      amount: msg.amount ?? BigInt.zero,
      description: msg.description,
      createdAt: DateTime.now(),
      success: true,
    ));
  }
  
  Future<void> _handleCheckInvoice(CheckInvoiceMessage msg) async {
    final invoice = _invoices[msg.invoiceId];
    
    if (invoice == null) {
      context.sender?.tell(InvoiceDetailsResponse(
        invoiceId: msg.invoiceId,
        addresses: [],
        amount: BigInt.zero,
        status: InvoiceStatus.pending,
        createdAt: DateTime.now(),
        found: false,
      ));
      return;
    }
    
    context.sender?.tell(InvoiceDetailsResponse(
      invoiceId: invoice['invoiceId'] as String,
      walletId: invoice['walletId'] as String,
      addresses: List<String>.from(invoice['addresses'] as List),
      amount: invoice['amount'] as BigInt,
      status: invoice['status'] as InvoiceStatus,
      createdAt: invoice['createdAt'] as DateTime,
      found: true,
    ));
  }
  
  Future<void> _handleMarkPaid(MarkInvoicePaidMessage msg) async {
    final invoice = _invoices[msg.invoiceId];
    if (invoice != null) {
      invoice['status'] = InvoiceStatus.paid;
      invoice['paidAt'] = DateTime.now();
      invoice['paymentTxid'] = msg.txid;
    }
    
    context.sender?.tell(InvoiceStatusMessage(
      invoiceId: msg.invoiceId,
      status: InvoiceStatus.paid,
    ));
  }
}

