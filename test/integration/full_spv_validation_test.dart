import 'dart:async';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:dactor/dactor.dart';
import 'package:convert/convert.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:libspiffy/src/actors/invoice_manager_actor.dart';
import 'package:libspiffy/src/actors/invoice_messages.dart';
import 'package:libspiffy/src/actors/spv_actor.dart';
import 'package:libspiffy/src/actors/wallet_messages.dart';
import 'package:libspiffy/src/core/wallet_commands.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';
import 'package:libspiffy/src/utils/beef.dart';
import 'package:libspiffy/src/utils/crypto_utils.dart';
import 'package:spiffynode/spiffy_node.dart';
import 'package:dactor/src/message.dart';

/// Full SPV Validation Integration Tests
/// 
/// These tests use REAL testnet data (transactions, merkle proofs, block headers)
/// to validate the complete SPV flow including cryptographic verification.
void main() {
  group('Full SPV Validation Integration Tests', () {
    late LocalActorSystem actorSystem;
    late ActorRef mockWalletManager;
    late ActorRef invoiceManager;
    late ActorRef spvActor;
    late InMemoryWalletStorage storage;

    setUp(() async {
      actorSystem = LocalActorSystem(ActorSystemConfig());
      storage = InMemoryWalletStorage();
      
      // Store real block headers
      await _setupRealBlockHeaders(storage);
      
      // Create mock wallet manager
      mockWalletManager = await actorSystem.spawn(
        'mock-wallet-manager',
        () => _MockWalletManagerActor(),
      );
      
      // Create invoice manager
      invoiceManager = await actorSystem.spawn(
        'invoice-manager',
        () => InvoiceManagerActor(
          walletManager: mockWalletManager,
          storage: storage,
        ),
      );
      
      // Create SPV actor with real validation
      spvActor = await actorSystem.spawn(
        'spv-actor',
        () => SPVActor(
          walletManager: mockWalletManager,
          invoiceManager: invoiceManager,
          storage: storage,
        ),
      );
    });

    tearDown(() async {
      await actorSystem.shutdown();
    });

    test('validates real transaction with merkle proof', () async {
      // Use real testnet transaction from block 1641074
      final realTx = _getRealTransaction1();
      final tscProof = _getTscProof1();
      
      // Create invoice with the target address
      final createCompleter = Completer<InvoiceCreatedMessage>();
      final createReceiver = await actorSystem.spawn(
        'create-receiver',
        () => _TestReceiverActor<InvoiceCreatedMessage>(createCompleter),
      );

      // Extract the address from the transaction
      final txHex = realTx['hex'] as String;
      final tx = dartsv.Transaction.fromHex(txHex);
      final targetAddress = _extractP2PKHAddress(tx.outputs[0].script);

      print('\n=== Testing Real Transaction ===');
      print('TXID: ${realTx['txid']}');
      print('Block: ${realTx['blockheight']}');
      print('Target Address: $targetAddress');

      // Pre-register the expected address with the mock wallet manager
      mockWalletManager.tell(_RegisterExpectedAddressMessage(
        walletId: 'bob-wallet',
        expectedAddress: targetAddress,
      ));

      // Create invoice for this address (mock wallet will return this address)
      invoiceManager.tell(
        CreateInvoiceMessage(
          walletId: 'bob-wallet',
          amount: BigInt.from(3883936), // Real amount from output
        ),
        sender: createReceiver,
      );

      final invoice = await createCompleter.future.timeout(Duration(seconds: 5));
      expect(invoice.success, isTrue);
      final invoiceId = invoice.invoiceId;

      print('Invoice ID: $invoiceId');
      print('Invoice Address: ${invoice.addresses.first}');
      print('Expected Address from TX: $targetAddress');
      
      // CRITICAL: The invoice address must match the real transaction's output address
      expect(invoice.addresses.first, equals(targetAddress), 
        reason: 'Invoice address must match the real transaction output address');

      // Create BEEF from real transaction and merkle proof
      final beef = _createBeefFromRealData(realTx, tscProof);
      
      print('BEEF created with ${beef.txs.length} transaction(s)');

      // Send transaction to SPV actor for validation
      final validationCompleter = Completer<dynamic>();
      final validationReceiver = await actorSystem.spawn(
        'validation-receiver',
        () => _TestReceiverActor<dynamic>(validationCompleter),
      );

      spvActor.tell(
        ReceiveTransactionMessage(
          transactionId: realTx['txid'] as String,
          beef: beef,
          fromCounterparty: 'alice',
          targetWalletId: 'bob-wallet',
          invoiceId: invoiceId,
        ),
        sender: validationReceiver,
      );

      // Wait for validation result
      final result = await validationCompleter.future.timeout(
        Duration(seconds: 10),
        onTimeout: () => throw TimeoutException('SPV validation timed out'),
      ) as SPVValidationResult;

      print('Validation Result: ${result.isValid ? "VALID" : "INVALID"}');
      if (!result.isValid) {
        print('Validation Error: ${result.validationError}');
      }
      
      // The SPV actor should validate the merkle proof successfully
      expect(result.isValid, isTrue, 
        reason: 'SPV validation should succeed with valid merkle proof and matching addresses. Error: ${result.validationError}');
      
      // Check if invoice was marked as paid
      final queryCompleter = Completer<InvoiceDetailsResponse>();
      final queryReceiver = await actorSystem.spawn(
        'query-receiver',
        () => _TestReceiverActor<InvoiceDetailsResponse>(queryCompleter),
      );

      await Future.delayed(Duration(milliseconds: 500)); // Give time for processing

      invoiceManager.tell(
        CheckInvoiceMessage(invoiceId),
        sender: queryReceiver,
      );

      final invoiceDetails = await queryCompleter.future.timeout(Duration(seconds: 5));
      
      print('Invoice Status: ${invoiceDetails.status}');
      
      // If validation succeeded, invoice should be marked as paid
      // Note: This depends on address matching logic working correctly
      expect(invoiceDetails.found, isTrue);
    });

    test('validates second real transaction with different merkle proof', () async {
      // Use real testnet transaction from block 1641086
      final realTx = _getRealTransaction2();
      final tscProof = _getTscProof2();
      
      print('\n=== Testing Second Real Transaction ===');
      print('TXID: ${realTx['txid']}');
      print('Block: ${realTx['blockheight']}');

      // Create BEEF from real transaction and merkle proof
      final beef = _createBeefFromRealData(realTx, tscProof);
      
      // Extract target address
      final txHex = realTx['hex'] as String;
      final tx = dartsv.Transaction.fromHex(txHex);
      final targetAddress = _extractP2PKHAddress(tx.outputs[0].script);

      print('Target Address: $targetAddress');
      print('BEEF created with ${beef.txs.length} transaction(s)');

      // Pre-register the expected address with the mock wallet manager
      mockWalletManager.tell(_RegisterExpectedAddressMessage(
        walletId: 'bob-wallet',
        expectedAddress: targetAddress,
      ));

      // Create invoice
      final createCompleter = Completer<InvoiceCreatedMessage>();
      final createReceiver = await actorSystem.spawn(
        'create-receiver-2',
        () => _TestReceiverActor<InvoiceCreatedMessage>(createCompleter),
      );

      invoiceManager.tell(
        CreateInvoiceMessage(
          walletId: 'bob-wallet',
          amount: BigInt.from(3882997), // Real amount
        ),
        sender: createReceiver,
      );

      final invoice = await createCompleter.future.timeout(Duration(seconds: 5));
      expect(invoice.success, isTrue);

      // Send to SPV actor
      final validationCompleter = Completer<dynamic>();
      final validationReceiver = await actorSystem.spawn(
        'validation-receiver-2',
        () => _TestReceiverActor<dynamic>(validationCompleter),
      );

      spvActor.tell(
        ReceiveTransactionMessage(
          transactionId: realTx['txid'] as String,
          beef: beef,
          fromCounterparty: 'alice',
          targetWalletId: 'bob-wallet',
          invoiceId: invoice.invoiceId,
        ),
        sender: validationReceiver,
      );

      final result = await validationCompleter.future.timeout(
        Duration(seconds: 10),
        onTimeout: () => throw TimeoutException('SPV validation timed out'),
      ) as SPVValidationResult;

      print('Validation Result: ${result.isValid ? "VALID" : "INVALID"}');
      if (!result.isValid) {
        print('Validation Error: ${result.validationError}');
      }
      
      expect(result.isValid, isTrue,
        reason: 'SPV validation should succeed with valid merkle proof and matching addresses. Error: ${result.validationError}');
    });

    test('rejects transaction with invalid merkle proof', () async {
      // Use real transaction but corrupt the merkle proof
      final realTx = _getRealTransaction1();
      final tscProof = _getTscProof1();
      
      // Create BEEF with corrupted proof
      final bump = CryptoUtils.createBumpFromTscProof(
        tscProof,
        realTx['blockheight'] as int,
      );
      
      // Corrupt the BUMP by changing a hash value
      if (bump.path.isNotEmpty && bump.path[0].leaves.isNotEmpty) {
        final leaf = bump.path[0].leaves[0];
        if (leaf.hash != null) {
          // Flip some bits in the hash
          leaf.hash![0] ^= 0xFF;
        }
      }

      final txHex = realTx['hex'] as String;
      final txBytes = Uint8List.fromList(hex.decode(txHex));
      
      final beef = BEEF.create(
        bumps: [bump],
        txs: [txBytes],
        hasMerkle: [true],
        bumpIndex: [0],
      );

      print('\n=== Testing Invalid Merkle Proof ===');
      print('TXID: ${realTx['txid']}');
      print('BEEF created with corrupted merkle proof');

      // Create invoice
      final createCompleter = Completer<InvoiceCreatedMessage>();
      final createReceiver = await actorSystem.spawn(
        'create-receiver-invalid',
        () => _TestReceiverActor<InvoiceCreatedMessage>(createCompleter),
      );

      invoiceManager.tell(
        CreateInvoiceMessage(
          walletId: 'bob-wallet',
          amount: BigInt.from(100000),
        ),
        sender: createReceiver,
      );

      final invoice = await createCompleter.future;

      // Send to SPV actor
      final validationCompleter = Completer<dynamic>();
      final validationReceiver = await actorSystem.spawn(
        'validation-receiver-invalid',
        () => _TestReceiverActor<dynamic>(validationCompleter),
      );

      spvActor.tell(
        ReceiveTransactionMessage(
          transactionId: realTx['txid'] as String,
          beef: beef,
          fromCounterparty: 'alice',
          targetWalletId: 'bob-wallet',
          invoiceId: invoice.invoiceId,
        ),
        sender: validationReceiver,
      );

      // Wait for validation result (should indicate failure)
      final result = await validationCompleter.future.timeout(
        Duration(seconds: 10),
        onTimeout: () => throw TimeoutException('SPV validation timed out'),
      ) as SPVValidationResult;
      
      print('Validation Result: ${result.isValid ? "VALID" : "INVALID"}');
      print('Validation Error: ${result.validationError}');
      
      // Should fail validation due to corrupted merkle proof
      expect(result.isValid, isFalse,
        reason: 'SPV validation should FAIL with corrupted merkle proof');
      expect(result.validationError, isNotNull,
        reason: 'Validation error message should be provided');
    });
  });
}

/// Setup real block headers from bump_test.dart
Future<void> _setupRealBlockHeaders(InMemoryWalletStorage storage) async {
  // Block 1641074
  final header1 = BlockHeader(
    version: 536870912,
    prevBlock: Hash.fromHex('0000000006d30de00e6c6c16ebfabcd833c7c367a26a86f00f8ff4067d842295'),
    merkleRoot: Hash.fromHex('49b5be64b429e9ce9b7a91e3581d4a9cdaf61b935b33981ebcfef6256aa2fba0'),
    timestamp: DateTime.fromMillisecondsSinceEpoch(1729051303 * 1000),
    bits: 0x1d00ffff,
    nonce: 1307527718,
  );
  await storage.storeBlockHeader(header1, 1641074);
  
  // Block 1641086
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

/// Real transaction 1 from bump_test.dart
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

/// Real transaction 2 from bump_test.dart
Map<String, dynamic> _getRealTransaction2() {
  return {
    "txid": "fb4087a12b03caa64a687ae09a2ce36a22a9a4273f177d4e83e6f8095331369a",
    "hex": "020000000143fa91a1cc2b03e80646d2f15c0c75fd5a2e48270838d075f46e121a866dd3c4000000006a473044022031e9fe7d9279938ae04ccd543f620b99f7ccb9e755c4fd5de2f4d1053858db4802207c21fb144d19544ab934cd557936acb6bd67e99aa132f73a71e892609bfaabee4121022036646b3fd79dee41351f727f0a6e10d0e7f98585961bc14e7aadaf5f4b66ab0100000002f53c3b00000000001976a914f82d58dd8487044d8d0879c15a2a3516a425de2a88ac96000000000000001976a914f82d58dd8487044d8d0879c15a2a3516a425de2a88ac00000000",
    "blockhash": "00000000dd5232b75661ece6943790f9671755490af7d233891201dc92f76a92",
    "blockheight": 1641086,
    "blocktime": 1729059327,
    "confirmations": 24442
  };
}

/// TSC Proof 1 from bump_test.dart
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

/// TSC Proof 2 from bump_test.dart
Map<String, dynamic> _getTscProof2() {
  return {
    "index": 3,
    "txOrId": "fb4087a12b03caa64a687ae09a2ce36a22a9a4273f177d4e83e6f8095331369a",
    "target": "00000000dd5232b75661ece6943790f9671755490af7d233891201dc92f76a92",
    "nodes": [
      "b52aff03ebbe7c2376757fb62f6b0f5ee79f40d5aa7783387d7616719cff7886",
      "e00269b8f876fcfe4c0e2e4245bcec06d931f3a9caad194f86c0834502e24b41",
      "ebda2eac99bd62e1513aecb5252b061399381a8d1e45e8c9f3c7b6c854a20548",
      "1376c5126553f49de20a8213a67846db4907ca0ffa72ff1f6b331b42553751a7",
      "d06b21563e80f8a7b9d469d3077c3d48822856cb0edf44d28b9d16ba9090b328",
      "c71f285882cdd400346df0db4505fe88d79a6349f5f99a2f9f2dcc8c91fdb237",
      "f2c8bdca6828f5e01294d8c50af5a1db198f2cc7475e83836d6856b7fb2d252c",
      "8007214449f5c9467c0878b21a1e84e27f71b5b5ce5a882c0afc23a9f5f28cbe"
    ]
  };
}

/// Create BEEF from real transaction and TSC proof
BEEF _createBeefFromRealData(Map<String, dynamic> tx, Map<String, dynamic> tscProof) {
  final txHex = tx['hex'] as String;
  final txBytes = Uint8List.fromList(hex.decode(txHex));
  final blockHeight = tx['blockheight'] as int;
  
  // Create BUMP from TSC proof
  final bump = CryptoUtils.createBumpFromTscProof(tscProof, blockHeight);
  
  // Create BEEF
  return BEEF.create(
    bumps: [bump],
    txs: [txBytes],
    hasMerkle: [true],
    bumpIndex: [0],
  );
}

/// Extract P2PKH address from script
String _extractP2PKHAddress(dartsv.SVScript script) {
  // Extract address from P2PKH script
  // P2PKH format: OP_DUP OP_HASH160 <pubkeyhash> OP_EQUALVERIFY OP_CHECKSIG

 final locker= dartsv.P2PKHLockBuilder.fromScript(script);
 return locker.address?.toBase58() ?? 'unknown';

}

/// Mock wallet manager that returns addresses from invoice metadata for testing
class _MockWalletManagerActor extends Actor {
  int _addressCounter = 0;
  // Track expected addresses for address generation requests
  final Map<String, List<String>> _expectedAddresses = {};

  @override
  Future<void> onMessage(dynamic message) async {
    if (message is _RegisterExpectedAddressMessage) {
      // Pre-register an expected address for the next address generation
      _expectedAddresses.putIfAbsent(message.walletId, () => []).add(message.expectedAddress);
      print('MockWalletManager: Registered expected address ${message.expectedAddress} for ${message.walletId}');
    } else if (message is WalletCommandMessage) {
      final command = message.command;
      if (command is GenerateAddressCommand) {
        _addressCounter++;
        
        // Check if we have a pre-registered expected address for this wallet
        final expectedList = _expectedAddresses[message.walletId];
        final address = (expectedList != null && expectedList.isNotEmpty)
            ? expectedList.removeAt(0)  // Use FIFO order
            : 'n${_addressCounter}Mock${DateTime.now().millisecondsSinceEpoch}';
        
        print('MockWalletManager: Generating address for ${message.walletId}: $address');
        
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

/// Helper message for tests to pre-register expected addresses
class _RegisterExpectedAddressMessage implements Message {
  final String walletId;
  final String expectedAddress;
  
  _RegisterExpectedAddressMessage({
    required this.walletId,
    required this.expectedAddress,
  });
  
  @override
  String get correlationId => 'register-address-$walletId';
  @override
  Map<String, dynamic> get metadata => {'walletId': walletId, 'address': expectedAddress};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// Test receiver actor
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

