import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dactor/dactor.dart';
import 'package:isar/isar.dart';
import 'package:test/test.dart';
import 'package:spiffynode/spiffy_node.dart';
import 'package:libspiffy/libspiffy.dart';
import 'package:libspiffy/src/actors/libspiffy_actor_system.dart';
import 'package:libspiffy/src/actors/wallet_messages.dart';
import 'package:libspiffy/src/actors/invoice_messages.dart';
import 'package:libspiffy/src/core/wallet_commands.dart';
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
}) async {
  final completer = Completer<WalletCreatedMessage>();
  final receiver = await actorSystem.spawn(
    'create-wallet-receiver-$walletId',
    () => TestReceiverActor<WalletCreatedMessage>(completer),
  );
  
  walletManager.tell(
    CreateWalletMessage(walletId, walletName),
    sender: receiver,
  );
  
  final response = await completer.future.timeout(Duration(seconds: 5));
  if (!response.success) {
    throw Exception('Failed to create wallet: ${response.error}');
  }
  
  return response.walletId;
}

/// Fund a wallet with UTXOs for testing
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
  
  // Create a mock UTXO
  // Create a mock P2PKH scriptPubKey (OP_DUP OP_HASH160 <20 bytes> OP_EQUALVERIFY OP_CHECKSIG)
  final mockPubKeyHash = '0' * 40; // 20 bytes in hex
  final utxo = BitcoinUtxo.create(
    txid: 'funding_tx_${DateTime.now().millisecondsSinceEpoch}',
    vout: 0,
    satoshis: amount,
    scriptPubKey: '76a914${mockPubKeyHash}88ac', // P2PKH script
    address: targetAddress,
    blockHeight: 1291860,
    confirmations: 10,
  );
  
  // Send receive UTXO command
  final completer = Completer<dynamic>();
  final uniqueId = DateTime.now().microsecondsSinceEpoch;
  final receiver = await actorSystem.spawn(
    'fund-receiver-$walletId-$uniqueId',
    () => TestReceiverActor<dynamic>(completer),
  );
  
  walletManager.tell(
    WalletCommandMessage(
      walletId,
      ReceiveUTXOCommand(
        walletId: walletId,
        txid: utxo.txid,
        vout: utxo.vout,
        satoshis: utxo.satoshis,
        scriptPubKey: utxo.scriptPubKey,
        address: utxo.address,
        blockHeight: utxo.blockHeight,
        confirmations: utxo.confirmations,
      ),
    ),
    sender: receiver,
  );
  
  // Give it time to process
  await Future.delayed(Duration(milliseconds: 200));
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

