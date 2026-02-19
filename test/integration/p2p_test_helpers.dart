import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dactor/dactor.dart';
import 'package:isar/isar.dart';
import 'package:test/test.dart';
import 'package:convert/convert.dart';
import 'package:spiffynode/spiffy_node.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:libspiffy/libspiffy.dart';
import 'package:libspiffy/src/actors/libspiffy_actor_system.dart';
import 'package:libspiffy/src/actors/wallet_messages.dart';
import 'package:libspiffy/src/actors/invoice_messages.dart';
import 'package:libspiffy/src/core/wallet_commands.dart';
import 'package:libspiffy/src/utils/crypto_utils.dart';
import 'package:libspiffy/src/models/bitcoin_utxo.dart';
import 'package:libspiffy/src/models/bitcoin_transaction.dart';
import '../mocks/mock_arc_service.dart';
import '../mocks/mock_peer_manager.dart';
import 'isar_test_helper.dart';

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
  await ensureIsarInitialized();
  
  // Create Isar database
  final isar = await Isar.open(
    LibSpiffySchemas.walletSchemas,
    directory: testDir.path,
    name: '${name}_db_${DateTime.now().microsecondsSinceEpoch}',
  );
  
  // Create actor system
  final actorSystem = LocalActorSystem(ActorSystemConfig());
  
  // Initialize LibSpiffy
  final libspiffy = LibSpiffyActorSystem();
  await libspiffy.initialize(
    actorSystem: actorSystem,
    isar: isar,
    dataDirectory: testDir.path,
    enableP2P: false,
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
  // Generate a mnemonic if none provided and no wif/xpriv
  String? finalMnemonic = mnemonic;
  if (finalMnemonic == null && wif == null && xpriv == null) {
    final cryptoService = DartSVCryptoService();
    finalMnemonic = await cryptoService.generateMnemonic();
  }
  
  final completer = Completer<WalletCreatedMessage>();
  final receiver = await actorSystem.spawn(
    'create-wallet-receiver-$walletId',
    () => TestReceiverActor<WalletCreatedMessage>(completer),
  );
  
  walletManager.tell(
    CreateWalletMessage(
      walletId,
      walletName,
      mnemonic: finalMnemonic,
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

/// Test xpriv with real testnet history - use this when creating wallets for payment tests
const kTestXpriv = 'tprv8ZgxMBicQKsPeMiDjtXBGAyFY1wEMGgomjwf54ZmiZfKTNYvVdBa6GqWUwnvtHm6NKVkQkhCKxaobd9JPxNEXgDfVgJ5RNHJ3ivogSG3V1R';

/// Root address (m/0/0) derived from test xpriv
const kTestRootAddress = 'mqCnSf8i6kmaQaJ54HjQ8EUJnuK4AnCv12';

/// Fund a wallet with UTXOs for testing
///
/// Uses real testnet transaction data linked to kTestXpriv.
/// IMPORTANT: The wallet MUST be created with kTestXpriv for this to work!
/// This is required for BEEF creation which needs the full ancestor chain.
Future<void> fundWallet({
  required ActorRef walletManager,
  required ActorSystem actorSystem,
  required String walletId,
  required BigInt amount,
  String? address,
}) async {
  // Use the known root address from the test xpriv
  // The wallet MUST be created with kTestXpriv for signing to work
  String targetAddress = address ?? kTestRootAddress;

  // Use real testnet transaction data from block 1239645
  // This transaction pays 200,000,000 sats to mqCnSf8i6kmaQaJ54HjQ8EUJnuK4AnCv12 at vout 1
  // This is the root address (m/0/0) derived from kTestXpriv
  final fundingTxid = 'a05924fcc63712d3e4b94b0c88baad234c2c8ad3d369704f53765e21a53a2101';
  final fundingTxHex = '020000000165b6c06790c23623c4988ee51b3f27c76bfb6a0c9e5bab3432968c51379af66a000000006b483045022100b735fb60adca4fa42e37746aa602c3206bf98572ae83e396da4fd11cb716b26d022017bf9955bd8fc4d60f2829236c7864d5b5540062c88113daef137c0ee441736c41210222824a8530bc570b7bae7c7600529b450a65eab1203c5f561d8082cd97b3dba1feffffff02872ec735150000001976a9149d02ce72bbdc1713d5537a0705d8ec7d9702c81088ac00c2eb0b000000001976a9146a418bf9e2e2b670e1aa7b7da59391e212b4ba1988ac5cea1200';
  final blockHeight = 1239645;

  // Real TSC proof for this transaction (position 2 in block 1239645)
  final tscProof = {
    'index': 2,
    'txOrId': fundingTxid,
    'target': '0000000014ba177afc3977062d2709ff4f289462b18189a381ad3cbf244d1c3b',
    'nodes': [
      '2bb617ed9b7950dcc9ddd952364a5d039742b40b786d3ef8a3984a5cf5495640',
      'e0c82744e0d7c7a1e72102b82fa37ae09f4e6018ebb18773f888617b83250e75',
      '9991c11c2ecb5087a29032a279d926bfe03c926c582a30743c902b57a3d98039',
      '9d54821a3821713dadeeb3a614921f8c63866f82686cbcf019ed7a6c20a36d2b',
      'a1e33369efb20fa5a1311ddfed20747de1996fdc814aa19691106eafe28b3e5d',
      '5a2f7dcc9b1fddc64f57157e7c59082729622050a76cb6956ae6b15f1a9ff0c4',
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
  
  // Real transaction has 2 outputs:
  // Output 0: 91096559239 sats to muq9kAb9ri62VChAMRkuwK5bTve4iDLWBg (not ours)
  // Output 1: 200000000 sats (2 BSV) to mqCnSf8i6kmaQaJ54HjQ8EUJnuK4AnCv12 (our root address)
  final output0Amount = 91096559239;
  final output1Amount = 200000000;
  
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
  
  // Now send the UTXO (using output 1 which pays to our root address)
  final utxoCompleter = Completer<dynamic>();
  final utxoReceiver = await actorSystem.spawn(
    'fund-receiver-$walletId-${DateTime.now().microsecondsSinceEpoch}',
    () => TestReceiverActor<dynamic>(utxoCompleter),
  );

  // Use the exact scriptPubKey from the real transaction for vout 1
  // This is the P2PKH script for mqCnSf8i6kmaQaJ54HjQ8EUJnuK4AnCv12
  const scriptPubKey = '76a9146a418bf9e2e2b670e1aa7b7da59391e212b4ba1988ac';

  walletManager.tell(
    WalletCommandMessage(
      walletId,
      ReceiveUTXOCommand(
        walletId: walletId,
        txid: fundingTxid,
        vout: 1, // Use output 1 which pays to our root address
        satoshis: amount,
        scriptPubKey: scriptPubKey,
        address: targetAddress,
        blockHeight: blockHeight,
        confirmations: 10,
        initialStatus: UTXOStatus.available, // Must be available for spending
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
  // Block 1239645 - Real testnet data (used by fundWallet with kTestXpriv)
  // Transaction a05924fcc63712d3e4b94b0c88baad234c2c8ad3d369704f53765e21a53a2101
  final existingHeader0 = await storage.getBlockHeaderByHeight(1239645);
  if (existingHeader0 == null) {
    final header0 = BlockHeader(
      version: 536870912,
      prevBlock: Hash.fromHex('000000001539f91cede66262caa22d1b504d09aa1dc3221f7fac5b30c2f7d65d'),
      merkleRoot: Hash.fromHex('5a2f7dcc9b1fddc64f57157e7c59082729622050a76cb6956ae6b15f1a9ff0c4'),
      timestamp: DateTime.fromMillisecondsSinceEpoch(1528803530 * 1000),
      bits: 0x1d00ffff,
      nonce: 12345, // Placeholder - actual nonce not needed for merkle validation
    );
    await storage.storeBlockHeader(header0, 1239645);
  }

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

/// Verify UTXO exists with expected status (with retry for async projection)
Future<void> verifyUTXOStatus({
  required IsarWalletStorage storage,
  required String walletId,
  required String txid,
  required int vout,
  required UTXOStatus expectedStatus,
  Duration timeout = const Duration(seconds: 5),
  Duration retryInterval = const Duration(milliseconds: 100),
}) async {
  final startTime = DateTime.now();
  final expectedStatusStr = expectedStatus.toString().split('.').last;
  int attempts = 0;

  while (DateTime.now().difference(startTime) < timeout) {
    attempts++;
    final utxos = await storage.getUTXOs(walletId, includeSpent: true);

    try {
      final utxo = utxos.firstWhere(
        (u) => u.txid == txid && u.vout == vout,
      );

      if (utxo.status == expectedStatus) {
        print('✓ UTXO $txid:$vout verified with status $expectedStatusStr after $attempts attempts');
        return; // Success!
      }

      if (attempts % 10 == 0) {
        print('  Waiting for UTXO status: current is "${utxo.status}", expecting "$expectedStatus" (attempt $attempts)');
      }
    } catch (e) {
      // UTXO not found yet, keep waiting
      if (attempts % 10 == 0) {
        print('  Waiting for UTXO $txid:$vout to appear (attempt $attempts)');
      }
    }

    await Future.delayed(retryInterval);
  }

  // Timeout reached - provide detailed error
  final utxos = await storage.getUTXOs(walletId, includeSpent: true);
  final utxo = utxos.where((u) => u.txid == txid && u.vout == vout).firstOrNull;

  if (utxo == null) {
    fail('UTXO $txid:$vout not found in wallet $walletId after ${DateTime.now().difference(startTime).inMilliseconds}ms ($attempts attempts)');
  } else {
    fail('UTXO $txid:$vout has status ${utxo.status}, expected $expectedStatus after ${DateTime.now().difference(startTime).inMilliseconds}ms ($attempts attempts)');
  }
}

/// Verify transaction exists with expected status (with retry for async projection)
Future<void> verifyTransactionStatus({
  required IsarWalletStorage storage,
  required String walletId,
  required String txid,
  required TransactionStatus expectedStatus,
  Duration timeout = const Duration(seconds: 5),
  Duration retryInterval = const Duration(milliseconds: 100),
}) async {
  final startTime = DateTime.now();
  final expectedStatusStr = expectedStatus.toString().split('.').last;
  int attempts = 0;

  while (DateTime.now().difference(startTime) < timeout) {
    attempts++;
    final tx = await storage.getTransaction(txid);

    if (tx != null && tx.status == expectedStatus) {
      print('✓ Transaction $txid verified with status $expectedStatusStr after $attempts attempts');
      return; // Success!
    }

    if (tx != null && attempts % 10 == 0) {
      print('  Waiting for transaction status: current is "${tx.status}", expecting "$expectedStatus" (attempt $attempts)');
    } else if (tx == null && attempts % 10 == 0) {
      print('  Waiting for transaction $txid to appear (attempt $attempts)');
    }

    await Future.delayed(retryInterval);
  }

  // Timeout reached - provide detailed error
  final tx = await storage.getTransaction(txid);

  if (tx == null) {
    fail('Transaction $txid not found after ${DateTime.now().difference(startTime).inMilliseconds}ms ($attempts attempts)');
  } else {
    fail('Transaction $txid has status ${tx.status}, expected $expectedStatus after ${DateTime.now().difference(startTime).inMilliseconds}ms ($attempts attempts)');
  }
}

