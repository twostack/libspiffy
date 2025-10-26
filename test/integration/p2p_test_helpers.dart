import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dactor/dactor.dart';
import 'package:isar/isar.dart';
import 'package:test/test.dart';
import 'package:convert/convert.dart';
import 'package:spiffynode/spiffy_node.dart';
import 'package:libspiffy/libspiffy.dart';
import 'package:libspiffy/src/actors/libspiffy_actor_system.dart';
import 'package:libspiffy/src/actors/wallet_messages.dart';
import 'package:libspiffy/src/actors/invoice_messages.dart';
import 'package:libspiffy/src/core/wallet_commands.dart';
import 'package:libspiffy/src/utils/crypto_utils.dart';
import '../mocks/mock_arc_service.dart';
import '../mocks/mock_peer_manager.dart';

/// Test receiver actor that completes a future when it receives a specific message type
class TestReceiverActor<T> extends Actor {
  final Completer<T> completer;
  
  TestReceiverActor(this.completer);
  
  @override
  Future<void> onMessage(dynamic message) async {
    if (message is T && !completer.isCompleted) {
      completer.complete(message);
    }
  }
}

/// Initialize a LibSpiffy system for testing
Future<LibSpiffyActorSystem> initializeTestSystem({
  required String name,
  required Directory testDir,
  required MockArcService mockArc,
  required MockPeerManager mockPeerManager,
}) async {
  // Initialize Isar core if not already done
  await Isar.initializeIsarCore(download: true);
  
  // Create Isar database
  final isar = await Isar.open(
    LibSpiffySchemas.walletSchemas,
    directory: testDir.path,
    name: '${name}_db',
  );
  
  // Create actor system
  final actorSystem = LocalActorSystem(ActorSystemConfig());
  
  // Initialize LibSpiffy
  final libspiffy = LibSpiffyActorSystem();
  await libspiffy.initialize(
    actorSystem: actorSystem,
    isar: isar,
    dataDirectory: testDir.path,
  );
  
  // Setup test block headers
  await setupTestHeaders(libspiffy.walletStorage as IsarWalletStorage);
  
  return libspiffy;
}

/// Create a wallet and return its ID
Future<String> createWallet({
  required ActorRef walletManager,
  required ActorSystem actorSystem,
  required String walletId,
  required String walletName,
  String? mnemonic,
  String? wif,
  String? xpriv,
}) async {
  final completer = Completer<WalletCreatedMessage>();
  final receiver = await actorSystem.spawn(
    'create-wallet-receiver-$walletId',
    () => TestReceiverActor<WalletCreatedMessage>(completer),
  );
  
  walletManager.tell(
    CreateWalletMessage(
      walletId,
      walletName,
      mnemonic: mnemonic,
      wif: wif,
      xpriv: xpriv,
    ),
    sender: receiver,
  );
  
  final response = await completer.future.timeout(Duration(seconds: 5));
  if (!response.success) {
    throw Exception('Failed to create wallet: ${response.error}');
  }
  
  return response.walletId;
}

/// Fund a wallet with UTXOs for testing
/// 
/// Uses real testnet transaction data (from full_spv_validation_test.dart)
/// to create a complete transaction with valid merkle proof.
/// This is required for BEEF creation which needs the full ancestor chain.
Future<void> fundWallet({
  required ActorRef walletManager,
  required ActorSystem actorSystem,
  required String walletId,
  required BigInt amount,
  String? address,
}) async {
  // Generate an address if not provided
  String targetAddress = address ?? await generateAddress(
    walletManager: walletManager,
    actorSystem: actorSystem,
    walletId: walletId,
  );
  
  // Use real testnet transaction data from block 1641074
  // This transaction has a valid merkle proof that can be used for BEEF
  final fundingTxid = 'dd6e7547df0fe893a9a19f66f0377eca72fdcd18fd9f6185fde9c91461a8e8a9';
  final fundingTxHex = '02000000013706d29b641d2061b0b7b22c81ec6a5670104826bee4472a7513619f4fc298df000000006a473044022021fb2500cfd69bf3d7eee8f16d2e1d6d49528dbe23e9105744202bd9e5b5789102204ff801667c156b97e92209c19dce9bbdd955ee35cea7b815cf9e3b0c1b6727174121022036646b3fd79dee41351f727f0a6e10d0e7f98585961bc14e7aadaf5f4b66ab0100000002a0443b00000000001976a914f82d58dd8487044d8d0879c15a2a3516a425de2a88ac96000000000000001976a914f82d58dd8487044d8d0879c15a2a3516a425de2a88ac00000000';
  final blockHeight = 1641074;
  
  // Real TSC proof for this transaction
  final tscProof = {
    'index': 6,
    'txOrId': fundingTxid,
    'target': '00000000cf9e8013b71e0c1c454208ad60a639adba6b6d7fcf6426da1e1efdb2',
    'nodes': [
      'f4d4fc63094d73b31e13da814ec4556865f53c329c53020e56ad71464e6f85fe',
      'bdcde417243f95840bd6fcfddbad0b198285f9f38d38093dc8826c3a3a7666f0',
      '9304304659a72e3e17ad1a447fecb4b082c8340683249a2cfa8ea3d411ad5c76',
      '5d2528dae0d0992da93f485ccbef24f06ef62ebf055bcc9d43b05dbdbe897dc2',
    ],
  };
  
  // Create BUMP from TSC proof
  final bump = CryptoUtils.createBumpFromTscProof(tscProof, blockHeight);
  final bumpBytes = bump.serialize();
  final bumpHex = hex.encode(bumpBytes);
  
  // Import the transaction with merkle proof
  final importCompleter = Completer<dynamic>();
  final importReceiver = await actorSystem.spawn(
    'import-receiver-$walletId-${DateTime.now().microsecondsSinceEpoch}',
    () => TestReceiverActor<dynamic>(importCompleter),
  );
  
  // Real transaction has 2 outputs, both to the same address
  // Output 0: 3883936 sats
  // Output 1: 150 sats
  final output0Amount = 3883936;
  final output1Amount = 150;
  
  walletManager.tell(
    WalletCommandMessage(
      walletId,
      RecordImportedTransactionCommand(
        walletId: walletId,
        txid: fundingTxid,
        rawHex: fundingTxHex,
        blockHeight: blockHeight,
        bumpProofHex: bumpHex,
        totalOutputSats: output0Amount + output1Amount,
        numInputs: 1,
        numOutputs: 2,
        txVersion: 2,
        txLockTime: 0,
        walletReceivingAddresses: [targetAddress],
        walletReceivedSats: amount.toInt(), // Use requested amount
        totalInputSats: output0Amount + output1Amount + 1000, // Assume ~1000 sat fee
        sendingAddresses: [],
      ),
    ),
    sender: importReceiver,
  );
  
  // Wait for import to complete
  await Future.delayed(Duration(milliseconds: 300));
  
  // Now send the UTXO (using output 0 which has enough funds)
  final utxoCompleter = Completer<dynamic>();
  final utxoReceiver = await actorSystem.spawn(
    'fund-receiver-$walletId-${DateTime.now().microsecondsSinceEpoch}',
    () => TestReceiverActor<dynamic>(utxoCompleter),
  );
  
  // Create UTXO from the real transaction's output
  final scriptPubKey = '76a914f82d58dd8487044d8d0879c15a2a3516a425de2a88ac'; // From real tx
  
  walletManager.tell(
    WalletCommandMessage(
      walletId,
      ReceiveUTXOCommand(
        walletId: walletId,
        txid: fundingTxid,
        vout: 0, // Use first output
        satoshis: amount,
        scriptPubKey: scriptPubKey,
        address: targetAddress,
        blockHeight: blockHeight,
        confirmations: 10,
      ),
    ),
    sender: utxoReceiver,
  );
  
  // Give it time to process
  await Future.delayed(Duration(milliseconds: 300));
}

/// Generate an address for a wallet
Future<String> generateAddress({
  required ActorRef walletManager,
  required ActorSystem actorSystem,
  required String walletId,
}) async {
  final completer = Completer<AddressGeneratedResponse>();
  final uniqueId = DateTime.now().microsecondsSinceEpoch;
  final receiver = await actorSystem.spawn(
    'gen-address-receiver-$walletId-$uniqueId',
    () => TestReceiverActor<AddressGeneratedResponse>(completer),
  );
  
  walletManager.tell(
    WalletCommandMessage(
      walletId,
      GenerateAddressCommand(walletId: walletId),
    ),
    sender: receiver,
  );
  
  final response = await completer.future.timeout(Duration(seconds: 5));
  if (!response.success) {
    throw Exception('Failed to generate address: ${response.error}');
  }
  
  return response.address;
}

/// Setup test block headers from existing test data
/// Idempotent - skips headers that already exist
Future<void> setupTestHeaders(IsarWalletStorage storage) async {
  // Block 1291860 - Real testnet data
  final existingHeader1 = await storage.getBlockHeaderByHeight(1291860);
  if (existingHeader1 == null) {
    final header1 = BlockHeader(
      version: 536870912,
      prevBlock: Hash.fromHex('00000000000000f789c089187720163628764945e9c694e260c35ad81f863338'),
      merkleRoot: Hash.fromHex('4baf0b15bbc9c92db8f9360a3a1dd1bd258d96b59bb93a754bf32346d6ff5d1f'),
      timestamp: DateTime.fromMillisecondsSinceEpoch(1553178908 * 1000),
      bits: 0x1a02f043,
      nonce: 333457262,
    );
    await storage.storeBlockHeader(header1, 1291860);
  }
  
  // Block 1358861 - Real testnet data
  final existingHeader2 = await storage.getBlockHeaderByHeight(1358861);
  if (existingHeader2 == null) {
    final header2 = BlockHeader(
      version: 536870912,
      prevBlock: Hash.fromHex('000000000000005eac106af39f73bdd7bbc4b7b5b550c0b14dcb2de473aefc99'),
      merkleRoot: Hash.fromHex('0161129d1c9fc51739b5de8be89ecf9ffb9505dfbe0c53f02ace6b11b96fe373'),
      timestamp: DateTime.fromMillisecondsSinceEpoch(1586816355 * 1000),
      bits: 0x1d00ffff,
      nonce: 354199361,
    );
    await storage.storeBlockHeader(header2, 1358861);
  }
  
  // Block 1359485 - Real testnet data
  final existingHeader3 = await storage.getBlockHeaderByHeight(1359485);
  if (existingHeader3 == null) {
    final header3 = BlockHeader(
      version: 536870912,
      prevBlock: Hash.fromHex('0000000000000017e934c5ea8dbff86c2acb79a6775d15636ad5acc3ed177c2c'),
      merkleRoot: Hash.fromHex('a6941deb95c11e72842ec13c8f2e8db9c48f1492bf8f77ca4115acd79bf46331'),
      timestamp: DateTime.fromMillisecondsSinceEpoch(1587144912 * 1000),
      bits: 0x1d00ffff,
      nonce: 2278258890,
    );
    await storage.storeBlockHeader(header3, 1359485);
  }
  
  // Block 1641074 - Real testnet data (used by fundWallet)
  final existingHeader4 = await storage.getBlockHeaderByHeight(1641074);
  if (existingHeader4 == null) {
    final header4 = BlockHeader(
      version: 536870912,
      prevBlock: Hash.fromHex('0000000006d30de00e6c6c16ebfabcd833c7c367a26a86f00f8ff4067d842295'),
      merkleRoot: Hash.fromHex('49b5be64b429e9ce9b7a91e3581d4a9cdaf61b935b33981ebcfef6256aa2fba0'),
      timestamp: DateTime.fromMillisecondsSinceEpoch(1729051303 * 1000),
      bits: 0x1d00ffff,
      nonce: 1307527718,
    );
    await storage.storeBlockHeader(header4, 1641074);
  }
}

/// Load test transaction data
List<Map<String, dynamic>> loadTestTransactions() {
  final jsonFile = File('test/data/full_tx_data.json');
  if (!jsonFile.existsSync()) {
    return [];
  }
  
  final jsonString = jsonFile.readAsStringSync();
  final List<dynamic> data = json.decode(jsonString);
  return data.cast<Map<String, dynamic>>();
}

/// Verify invoice exists in database with expected status
/// Uses retry mechanism to wait for asynchronous projection to complete
Future<void> verifyInvoiceInDatabase({
  required Isar isar,
  required String invoiceId,
  required InvoiceStatus expectedStatus,
  Duration timeout = const Duration(seconds: 5),
  Duration retryInterval = const Duration(milliseconds: 100),
}) async {
  final startTime = DateTime.now();
  final expectedStatusStr = expectedStatus.toString().split('.').last;
  InvoiceEntity? invoice;
  int attempts = 0;
  
  // Retry until invoice appears with correct status or timeout
  while (DateTime.now().difference(startTime) < timeout) {
    attempts++;
    invoice = await isar.invoiceEntitys
        .filter()
        .invoiceIdEqualTo(invoiceId)
        .findFirst();
    
    if (invoice != null && invoice.status == expectedStatusStr) {
      print('✓ Invoice verified after ${attempts} attempts (${DateTime.now().difference(startTime).inMilliseconds}ms)');
      return; // Success!
    }
    
    if (invoice != null && attempts % 10 == 0) {
      print('  Waiting for projection: invoice status is "${invoice.status}", expecting "$expectedStatusStr" (attempt $attempts)');
    }
    
    await Future.delayed(retryInterval);
  }
  
  // Timeout reached - provide detailed error
  expect(invoice, isNotNull, 
      reason: 'Invoice $invoiceId should exist in database (waited ${DateTime.now().difference(startTime).inMilliseconds}ms, $attempts attempts)');
  expect(invoice!.status, equals(expectedStatusStr), 
      reason: 'Invoice status should be $expectedStatusStr after ${DateTime.now().difference(startTime).inMilliseconds}ms ($attempts attempts)');
}

/// Verify invoice does NOT exist in database
Future<void> verifyInvoiceNotInDatabase({
  required Isar isar,
  required String invoiceId,
}) async {
  final invoice = await isar.invoiceEntitys
      .filter()
      .invoiceIdEqualTo(invoiceId)
      .findFirst();
  
  expect(invoice, isNull, reason: 'Invoice $invoiceId should NOT exist in this database');
}

/// Verify database isolation between two systems
Future<void> verifyDatabaseIsolation({
  required Isar aliceIsar,
  required Isar bobIsar,
  required String aliceWalletId,
  required String bobWalletId,
}) async {
  // Bob's DB should not have Alice's wallet invoices
  final bobHasAliceInvoices = await bobIsar.invoiceEntitys
      .filter()
      .walletIdEqualTo(aliceWalletId)
      .count();
  expect(bobHasAliceInvoices, equals(0), 
      reason: 'Bob\'s database should not contain Alice\'s invoices');
  
  // Alice's DB should not have Bob's wallet invoices
  final aliceHasBobInvoices = await aliceIsar.invoiceEntitys
      .filter()
      .walletIdEqualTo(bobWalletId)
      .count();
  expect(aliceHasBobInvoices, equals(0),
      reason: 'Alice\'s database should not contain Bob\'s invoices');
}

