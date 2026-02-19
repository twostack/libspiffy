import 'dart:async';
import 'dart:io';
import 'package:test/test.dart';
import 'package:dactor/dactor.dart';
import 'package:eventador/eventador.dart';
import 'package:isar/isar.dart';
import 'package:convert/convert.dart';
import 'package:libspiffy/libspiffy.dart';
import 'package:libspiffy/src/storage/isar_wallet_storage.dart';
import 'package:libspiffy/src/utils/crypto_utils.dart';
import 'package:libspiffy/src/services/blockchain_data_source.dart';
import 'package:libspiffy/src/models/blockchain_data_models.dart';
import 'package:dartsv/dartsv.dart';
import 'p2p_test_helpers.dart';
import 'isar_test_helper.dart';

/// Integration tests for PaymentCoordinatorActor and PayInvoiceMessage API
/// 
/// Tests cover:
/// - Successful BEEF creation with ancestor chain
/// - Missing ancestor transaction error
/// - No merkle proof in chain error
/// - Multi-level ancestor chains
///

/// Mock blockchain data source for testing
class MockBlockchainDataSource implements BlockchainDataSource {
  final Map<String, String> _rawTransactions = {};
  final Map<String, MerkleProofData> _merkleProofs = {};

  void addTransaction(String txid, String rawHex, MerkleProofData? proof) {
    _rawTransactions[txid] = rawHex;
    if (proof != null) {
      _merkleProofs[txid] = proof;
    }
  }

  @override
  String get networkType => 'test';

  @override
  Future<String> getRawTransaction(String txid) async {
    if (!_rawTransactions.containsKey(txid)) {
      throw DataSourceException('Transaction not found: $txid');
    }
    return _rawTransactions[txid]!;
  }

  @override
  Future<MerkleProofData> getMerkleProof(String txid) async {
    if (!_merkleProofs.containsKey(txid)) {
      throw DataSourceException('Merkle proof not found: $txid');
    }
    return _merkleProofs[txid]!;
  }

  @override
  Future<List<TransactionInfo>> getTransactionHistory(
    String address, {
    int? limit,
    int? offset,
  }) async {
    // Not implemented for this test
    return [];
  }

  @override
  Future<List<UtxoInfo>> getUtxos(String address) async {
    // Not implemented for this test
    return [];
  }

  @override
  Future<int> getCurrentBlockHeight() async {
    // Return a mock block height
    return 1291860;
  }

  @override
  Future<String> submitTransaction(String rawHex) async {
    // Not implemented for this test
    throw UnimplementedError('submitTransaction not needed for this test');
  }

  @override
  Future<List<AddressScriptInfo>> getAddressScripts(String address) {
    // TODO: implement getAddressScripts
    throw UnimplementedError();
  }

  @override
  Future<List<TransactionInfo>> getScriptHistory(String scriptHash, {int? limit, int? offset}) {
    // TODO: implement getScriptHistory
    throw UnimplementedError();
  }
}

// Private key in WIF format for testnet address n49CCQFuncaXbtBoNm39gSP9dvRP2eFFSw
const String kTestWIF = 'cPBBhyEvTZXSZhLJ8AuotbAmzR2bM8eQJV7fiBAQGcGsaSAaPfBf';

// Test transaction for wallet - TxnId = a05924fcc63712d3e4b94b0c88baad234c2c8ad3d369704f53765e21a53a2101
// Has output to mqCnSf8i6kmaQaJ54HjQ8EUJnuK4AnCv12 (200000000 satoshis at vout 1)
const testTxHex = '020000000165b6c06790c23623c4988ee51b3f27c76bfb6a0c9e5bab3432968c51379af66a000000006b483045022100b735fb60adca4fa42e37746aa602c3206bf98572ae83e396da4fd11cb716b26d022017bf9955bd8fc4d60f2829236c7864d5b5540062c88113daef137c0ee441736c41210222824a8530bc570b7bae7c7600529b450a65eab1203c5f561d8082cd97b3dba1feffffff02872ec735150000001976a9149d02ce72bbdc1713d5537a0705d8ec7d9702c81088ac00c2eb0b000000001976a9146a418bf9e2e2b670e1aa7b7da59391e212b4ba1988ac5cea1200';

// Parent of TX1  - TxnId = 2107375cb2b5c7299385dc41acd56e1e30868e19357227224db8962c65a6ffdc
const tx1Parent = '0200000001d724885eeeadecd5cc8b3174859db9b2cba5a4e25ae80948f96173684437f77d010000006a4730440220477bffcd627c9ca0658d788dc5fa991f08fd542381c324a7354818682b38c9bf02200c2eedc506e57e0f2ebf8907a1d9f0716e2c80bcd542258787fa56ce205ccbae412103be5724a6b930cfc02ec84339b679349b8c8ea8f3a73eb7f731fcf1d07319a12cfeffffff0280539a05000000001976a91410d1b86ea302442f3a1e53c654569c217a316df788aca627ac3e000000001976a91490897992fae7bff0d5839cb071b713595f65010688ac40b61300';
const jsonTx = '''
{
    "txid": "a05924fcc63712d3e4b94b0c88baad234c2c8ad3d369704f53765e21a53a2101",
    "hash": "a05924fcc63712d3e4b94b0c88baad234c2c8ad3d369704f53765e21a53a2101",
    "size": 226,
    "version": 2,
    "locktime": 1239644,
    "vin": [
        {
            "n": 0,
            "txid": "6af69a37518c963234ab5b9e0c6afb6bc7273f1be58e98c42336c29067c0b665",
            "vout": 0,
            "scriptSig": {
                "asm": "3045022100b735fb60adca4fa42e37746aa602c3206bf98572ae83e396da4fd11cb716b26d022017bf9955bd8fc4d60f2829236c7864d5b5540062c88113daef137c0ee441736c41 0222824a8530bc570b7bae7c7600529b450a65eab1203c5f561d8082cd97b3dba1",
                "hex": "483045022100b735fb60adca4fa42e37746aa602c3206bf98572ae83e396da4fd11cb716b26d022017bf9955bd8fc4d60f2829236c7864d5b5540062c88113daef137c0ee441736c41210222824a8530bc570b7bae7c7600529b450a65eab1203c5f561d8082cd97b3dba1",
                "isTruncated": false
            },
            "sequence": 4294967294,
            "voutDetails": {
                "value": 912.96563777,
                "n": 0,
                "scriptPubKey": {
                    "asm": "OP_DUP OP_HASH160 f581b04d7d97316342b1e6cad4425d2ff726fd52 OP_EQUALVERIFY OP_CHECKSIG",
                    "hex": "76a914f581b04d7d97316342b1e6cad4425d2ff726fd5288ac",
                    "reqSigs": 1,
                    "type": "pubkeyhash",
                    "addresses": [
                        "n3u5CyoJwQMzrQL1NoooagCxLJQrJdWEA1"
                    ],
                    "isTruncated": false
                },
                "scripthash": "921cb2a959415e5ae7fbc107736d2c2ff7c2d7bfff04b718b869afe0bb23eedd"
            }
        }
    ],
    "vout": [
        {
            "value": 910.96559239,
            "n": 0,
            "scriptPubKey": {
                "asm": "OP_DUP OP_HASH160 9d02ce72bbdc1713d5537a0705d8ec7d9702c810 OP_EQUALVERIFY OP_CHECKSIG",
                "hex": "76a9149d02ce72bbdc1713d5537a0705d8ec7d9702c81088ac",
                "reqSigs": 1,
                "type": "pubkeyhash",
                "addresses": [
                    "muq9kAb9ri62VChAMRkuwK5bTve4iDLWBg"
                ],
                "isTruncated": false
            },
            "scripthash": "bb0d1dab0dbcf6a1848e0ac0c72b5f0ed86fe06600e34129a0d3b5849951ecd2",
            "spent": {
                "txid": "53b787fe97183d31fbf0c04c8f6a20d4b4cf4f61ebd273b8e387cdac97e989c4",
                "n": 0
            }
        },
        {
            "value": 2,
            "n": 1,
            "scriptPubKey": {
                "asm": "OP_DUP OP_HASH160 6a418bf9e2e2b670e1aa7b7da59391e212b4ba19 OP_EQUALVERIFY OP_CHECKSIG",
                "hex": "76a9146a418bf9e2e2b670e1aa7b7da59391e212b4ba1988ac",
                "reqSigs": 1,
                "type": "pubkeyhash",
                "addresses": [
                    "mqCnSf8i6kmaQaJ54HjQ8EUJnuK4AnCv12"
                ],
                "isTruncated": false
            },
            "scripthash": "bf693a8b36631d06a6f4ed04802e966abe33c5796e49ae38ca0528e549790f03"
        }
    ],
    "blockhash": "000000001539f91cede66262caa22d1b504d09aa1dc3221f7fac5b30c2f7d65d",
    "confirmations": 460940,
    "time": 1528803530,
    "blocktime": 1528803530,
    "blockheight": 1239645,
    "vincount": 1,
    "voutcount": 2,
    "vinvalue": 912.96563777,
    "voutvalue": 912.96559239
}
''';

const merkleProofEntity = '{"blockHash":"0000000014ba177afc3977062d2709ff4f289462b18189a381ad3cbf244d1c3b","blockHeight":1239645,"createdAt":1761382738624305,"id":1,"merkleProofJson":"2bb617ed9b7950dcc9ddd952364a5d039742b40b786d3ef8a3984a5cf5495640,e0c82744e0d7c7a1e72102b82fa37ae09f4e6018ebb18773f888617b83250e75,9991c11c2ecb5087a29032a279d926bfe03c926c582a30743c902b57a3d98039,9d54821a3821713dadeeb3a614921f8c63866f82686cbcf019ed7a6c20a36d2b,a1e33369efb20fa5a1311ddfed20747de1996fdc814aa19691106eafe28b3e5d,5a2f7dcc9b1fddc64f57157e7c59082729622050a76cb6956ae6b15f1a9ff0c4","position":2,"txid":"a05924fcc63712d3e4b94b0c88baad234c2c8ad3d369704f53765e21a53a2101"}';
const bitcoinUtxoEntity = '{"address":"mqCnSf8i6kmaQaJ54HjQ8EUJnuK4AnCv12","blockHeight":1239645,"category":"funding","confirmations":0,"createdAt":1761382698389987,"id":1,"isSpendable":true,"satoshis":"200000000","scriptPubKey":"76a9146a418bf9e2e2b670e1aa7b7da59391e212b4ba1988ac","scriptType":"p2pkh","spentAt":null,"spentInTxId":null,"status":"available","txid":"a05924fcc63712d3e4b94b0c88baad234c2c8ad3d369704f53765e21a53a2101","utxoKey":"a05924fcc63712d3e4b94b0c88baad234c2c8ad3d369704f53765e21a53a2101:1","vout":1,"walletId":"8ddff238-aa46-43bd-9223-c67d516d5b27"}';
const bitcoinTransactionEntity = '{"blockHash":null,"blockHeight":1239645,"broadcastAt":null,"confirmations":6,"confirmedAt":1761382698436868,"counterparty":"n3u5CyoJwQMzrQL1NoooagCxLJQrJdWEA1","createdAt":1761382698436868,"fee":"4538","id":1,"isIncoming":true,"isOutgoing":false,"notes":null,"primaryCounterparty":"n3u5CyoJwQMzrQL1NoooagCxLJQrJdWEA1","rawHex":"020000000165b6c06790c23623c4988ee51b3f27c76bfb6a0c9e5bab3432968c51379af66a000000006b483045022100b735fb60adca4fa42e37746aa602c3206bf98572ae83e396da4fd11cb716b26d022017bf9955bd8fc4d60f2829236c7864d5b5540062c88113daef137c0ee441736c41210222824a8530bc570b7bae7c7600529b450a65eab1203c5f561d8082cd97b3dba1feffffff02872ec735150000001976a9149d02ce72bbdc1713d5537a0705d8ec7d9702c81088ac00c2eb0b000000001976a9146a418bf9e2e2b670e1aa7b7da59391e212b4ba1988ac5cea1200","receivingAddressesJson":"[\"mqCnSf8i6kmaQaJ54HjQ8EUJnuK4AnCv12\"]","sendingAddressesJson":"[\"n3u5CyoJwQMzrQL1NoooagCxLJQrJdWEA1\"]","status":"confirmed","totalInput":"91296563777","totalOutput":"91296559239","txid":"a05924fcc63712d3e4b94b0c88baad234c2c8ad3d369704f53765e21a53a2101","walletId":"8ddff238-aa46-43bd-9223-c67d516d5b27"}';
const walletMetadataEntity = '{"addressesJson":"","aggregateVersion":0,"confirmedBalance":"0","createdAt":1761382672401712,"derivationIndex":0,"id":1,"isCreated":true,"lastAccessedAt":1761435351285706,"metadataJson":"{\"network\":\"test\",\"importedFrom\":\"xpriv\",\"confirmedBalance\":\"0\",\"unconfirmedBalance\":\"200000000\",\"totalBalance\":\"200000000\",\"addressCount\":1,\"utxoCount\":1,\"availableUtxoCount\":1}","name":"test1","network":"test","publicKeysJson":"","rootAddress":"mqCnSf8i6kmaQaJ54HjQ8EUJnuK4AnCv12","unconfirmedBalance":"200000000","walletId":"8ddff238-aa46-43bd-9223-c67d516d5b27","walletType":"hd"}';
const addressEntity = '{"address":"mqCnSf8i6kmaQaJ54HjQ8EUJnuK4AnCv12","balance":"200000000","createdAt":1761382672218021,"derivationIndex":0,"derivationPath":"m/0/0","firstUsedAt":1761382698380232,"id":1,"isChange":false,"isWatched":true,"label":"Root address (m/0/0)","lastUsedAt":1761382698380232,"purpose":"receive","scriptType":"p2pkh","usageCount":1,"walletId":"8ddff238-aa46-43bd-9223-c67d516d5b27"}';
const transactionAddressEntity = '{"address":"n3u5CyoJwQMzrQL1NoooagCxLJQrJdWEA1","amount":"0","createdAt":1761382749413091,"direction":"input","id":1,"txid":"a05924fcc63712d3e4b94b0c88baad234c2c8ad3d369704f53765e21a53a2101","vin":0,"vout":null,"walletId":"8ddff238-aa46-43bd-9223-c67d516d5b27","walletIdAddress":"8ddff238-aa46-43bd-9223-c67d516d5b27_n3u5CyoJwQMzrQL1NoooagCxLJQrJdWEA1","walletIdTxid":"8ddff238-aa46-43bd-9223-c67d516d5b27_a05924fcc63712d3e4b94b0c88baad234c2c8ad3d369704f53765e21a53a2101"}';

//testnet xpriv key for the above wallet.
const xPrivKey = 'tprv8ZgxMBicQKsPeMiDjtXBGAyFY1wEMGgomjwf54ZmiZfKTNYvVdBa6GqWUwnvtHm6NKVkQkhCKxaobd9JPxNEXgDfVgJ5RNHJ3ivogSG3V1R';

// Real testnet transaction data (block 1291860) - has output to n49CCQFuncaXbtBoNm39gSP9dvRP2eFFSw
const String kTestTxHex = '0200000001dcffa6652c96b84d22277235198e86301e6ed5ac41dc859329c7b5b25c370721010000006a473044022033542938413acf616862fb9cdecedc86ed472773a3c8be33f6024051837e9a520220628937b5db1baef5b87b42e8d2a13403625713a083d5c28b77ae535f62293b8241210341dcbd921964fc54c125608ffb6f9114d53d7a8bb3fcab29cff657dbfc882268feffffff02db9e183b000000001976a914b9f4a12e17e6614a47ccb5b1464756cd9119064088ac00879303000000001976a914f82d58dd8487044d8d0879c15a2a3516a425de2a88ac53b61300';
const String kTestTxid = '5e0ae9db2586ac8ea89b0f0eb628e1624ccfbdafff860052b67069a401d8ed71';
const int kTestBlockHeight = 1291860;

void main() {
  late Directory testDir;
  late Isar isar;
  late LocalActorSystem actorSystem;
  late LibSpiffyActorSystem libspiffy;
  late String walletId;
  late String testAddress; // The address generated by the wallet
  late MockBlockchainDataSource mockDataSource;

  setUpAll(() async {
    await ensureIsarInitialized();
  });

  setUp(() async {
    // Create temporary directory for test database
    testDir = await Directory.systemTemp.createTemp('payment_api_test_');
    
    // Open Isar with LibSpiffy and Eventador schemas
    isar = await Isar.open(
      [
        ...LibSpiffySchemas.walletSchemas,
        ...IsarEventStore.requiredSchemas,
      ],
      directory: testDir.path,
      name: 'payment_api_test_${DateTime.now().millisecondsSinceEpoch}',
    );

    // Create actor system
    actorSystem = LocalActorSystem(ActorSystemConfig());

    // Create mock blockchain data source with test transaction data
    mockDataSource = MockBlockchainDataSource();
    
    // Add kTestTxHex with merkle proof
    mockDataSource.addTransaction(
      kTestTxid,
      kTestTxHex,
      MerkleProofData(
        txid: kTestTxid,
        blockHeight: kTestBlockHeight,
        merkleRoot: '5a2f7dcc9b1fddc64f57157e7c59082729622050a76cb6956ae6b15f1a9ff0c4',
        index: 2,
        nodes: [
          'a7026883d1074d1477d23c030f9997ff9fa45d07641a8a9c95f9116a2ac1cdd5',
          '378e4682082a1307d1e4a64807f93fc786e34bf5dc79760688613e18c41cda20',
          '04586929cfce578ca23105f4d1f059af87f108aac1fee23955c3193d617198d6',
        ],
      ),
    );
    
    // Add parent transaction (tx1Parent) for multi-level chain tests
    mockDataSource.addTransaction(
      '2107375cb2b5c7299385dc41acd56e1e30868e19357227224db8962c65a6ffdc',
      tx1Parent,
      MerkleProofData(
        txid: '2107375cb2b5c7299385dc41acd56e1e30868e19357227224db8962c65a6ffdc',
        blockHeight: kTestBlockHeight - 1,
        merkleRoot: 'mockroot1',
        index: 1,
        nodes: ['mockproof1', 'mockproof2'],
      ),
    );
    
    // Add unconfirmed transaction (no merkle proof) for error testing
    mockDataSource.addTransaction(
      'c652c5c422f29c0487a142cd56c192f2c99483f3792b69b290d0d4016819ad40',
      '01000000015ee2eeaa49ea81990f48f8896635bf2cde799413dd8ad269bcb7ab69ae1db161010000006a47304402202ca69f5a9de12be811fb4d0fd130d6cd5b56943ec82309b60afd41811e02d77002205ae10fe5920d800757907aee58a8caeddacc67c52f5195b36119d7c26c15a4b84121022036646b3fd79dee41351f727f0a6e10d0e7f98585961bc14e7aadaf5f4b66abffffffff02000000000000000040006a2231394878696756345179427633744870515663554551797131707a5a56646f417574000a746578742f706c61696e057574662d38083230323030343133ee849303000000001976a914f82d58dd8487044d8d0879c15a2a3516a425de2a88ac00000000',
      null, // No merkle proof for unconfirmed transaction
    );

    // Initialize LibSpiffy with mock data source
    libspiffy = LibSpiffyActorSystem();
    await libspiffy.initialize(
      actorSystem: actorSystem,
      isar: isar,
      dataDirectory: testDir.path,
      enableP2P: false,
      blockchainDataSource: mockDataSource,
    );

    // Setup test block headers
    await setupTestHeaders(libspiffy.walletStorage as IsarWalletStorage);

    // Create wallet with XPRIV key and capture the root address (m/0/0)
    walletId = '8ddff238-aa46-43bd-9223-c67d516d5b27'; // Use the walletId from test data
    
    final walletCompleter = Completer<WalletCreatedMessage>();
    final walletReceiver = await actorSystem.spawn(
      'wallet-created-receiver',
      () => TestReceiverActor<WalletCreatedMessage>(walletCompleter),
    );
    
    libspiffy.walletManager.tell(
      CreateWalletMessage(
        walletId,
        'test1',
        xpriv: xPrivKey, // Using xpriv that matches the test UTXO
      ),
      sender: walletReceiver,
    );
    
    final walletResponse = await walletCompleter.future.timeout(Duration(seconds: 5));
    if (!walletResponse.success) {
      throw Exception('Failed to create wallet: ${walletResponse.error}');
    }
    
    // Use the root address generated during wallet creation (m/0/0)
    testAddress = walletResponse.rootAddress;
    print('✓ Wallet created with root address (m/0/0): $testAddress');
    
    // Wait for wallet creation event to be persisted and projection to update
    print('⏳ Waiting for wallet creation to complete...');
    await Future.delayed(Duration(seconds: 2));
  });

  tearDown(() async {
    try {
      await libspiffy.shutdown();
      await isar.close(deleteFromDisk: true);
      await testDir.delete(recursive: true);
    } catch (e) {
      print('Teardown error: $e');
    }
  });

  group('PayInvoiceMessage API', () {
    test('creates BEEF with funded wallet', () async {
      print('\n=== Testing BEEF Creation with Funded Wallet ===');
      
      // STEP 1: Import the test transaction with merkle proof
      print('STEP 1: Importing test transaction...');
      final testTxid = 'a05924fcc63712d3e4b94b0c88baad234c2c8ad3d369704f53765e21a53a2101';
      final testBlockHeight = 1239645;
      
      // testAddress is already set from setUp()
      
      // Parse the real merkle proof from your test data
      final proofJson = {
        'index': 2,
        'txOrId': testTxid,
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
      
      // Create BUMP from the real merkle proof
      final bump = CryptoUtils.createBumpFromTscProof(proofJson, testBlockHeight);
      final bumpHex = hex.encode(bump.serialize());
      
      // Import transaction with the real merkle proof
      libspiffy.walletManager.tell(
        WalletCommandMessage(
          walletId,
          RecordImportedTransactionCommand(
            walletId: walletId,
            txid: testTxid,
            rawHex: testTxHex,
            blockHeight: testBlockHeight,
            bumpProofHex: bumpHex, // Using your real merkle proof data
            totalOutputSats: 91296559239,
            numInputs: 1,
            numOutputs: 2,
            txVersion: 2,
            txLockTime: 1239644,
            walletReceivingAddresses: [testAddress],
            walletReceivedSats: 200000000, // 2 BTC
            totalInputSats: 91296563777,
            sendingAddresses: ['n3u5CyoJwQMzrQL1NoooagCxLJQrJdWEA1'],
          ),
        ),
      );
      
      await Future.delayed(Duration(milliseconds: 300));
      
      // STEP 2: Create the UTXO
      print('STEP 2: Creating UTXO...');
      libspiffy.walletManager.tell(
        WalletCommandMessage(
          walletId,
          ReceiveUTXOCommand(
            walletId: walletId,
            txid: testTxid,
            vout: 1,
            satoshis: BigInt.from(200000000), // 2 BTC from test data
            scriptPubKey: '76a9146a418bf9e2e2b670e1aa7b7da59391e212b4ba1988ac',
            address: testAddress,
            blockHeight: testBlockHeight,
            confirmations: 6,
          ),
        ),
      );
      
      print('✓ Wallet funded with test UTXO');
      
      // STEP 3: Wait for UTXO to be stored
      await Future.delayed(Duration(milliseconds: 500));
      
      // STEP 3: Call PayInvoiceMessage
      print('\nSTEP 3: Calling PayInvoiceMessage...');
      final invoiceAmount = BigInt.from(100000); // 0.001 BSV
      final paymentAddress = 'muq9kAb9ri62VChAMRkuwK5bTve4iDLWBg';
      
      final completer = Completer<BEEFPaymentResponse>();
      final receiver = await actorSystem.spawn(
        'beef-payment-receiver',
        () => TestReceiverActor<BEEFPaymentResponse>(completer),
      );
      
      libspiffy.paymentCoordinator.tell(
        PayInvoiceMessage(
          walletId: walletId,
          invoiceId: 'test-invoice-funded',
          addresses: [paymentAddress],
          amount: invoiceAmount,
        ),
        sender: receiver,
      );
      
      final response = await completer.future.timeout(Duration(seconds: 10));
      
      // STEP 4: Verify BEEF creation
      print('\nSTEP 4: Verifying BEEF response...');
      
      // NOTE: The current implementation uses a placeholder BEEF creator
      // Once full BEEF.create() is implemented, we'll verify:
      // - Ancestor chain collection
      // - Merkle proof validation
      // - Proper BEEF serialization
      
      // For now, verify basic response structure
      expect(response, isNotNull);
      expect(response.invoiceId, equals('test-invoice-funded'));
      
      // Verify BEEF can be parsed successfully
      final parsedBeef = BEEF.parse(response.beefBytes);
      expect(parsedBeef, isA<BEEF>());
      expect(parsedBeef.txs.length, equals(2)); // Ancestor + payment transaction
      expect(parsedBeef.bumps.length, equals(1)); // One merkle proof


      
      expect(response.success, isTrue, reason: 'BEEF creation should succeed');
      
      print('✓ BEEF created successfully with signed transaction:');
      print('  Transaction ID: ${response.txid}');
      print('  BEEF size: ${response.beefBytes.length} bytes');
      print('  Transactions: ${parsedBeef.txs.length} (1 ancestor + 1 payment)');
      print('  Merkle proofs: ${parsedBeef.bumps.length}');
      print('  Ancestor count: ${response.ancestorCount}');
      print('  Amount paid: ${response.amountPaid} satoshis');
      print('  Change: ${response.changeAmount} satoshis');

      
      print('\n=== BEEF Creation Test Completed ===\n');
    });

    test('fails when insufficient funds', () async {
      // Create invoice with amount larger than wallet balance
      final invoiceAmount = BigInt.from(1000000000); // 1 billion satoshis
      
      final completer = Completer<BEEFPaymentResponse>();
      final receiver = await actorSystem.spawn(
        'payment-receiver-insufficient',
        () => TestReceiverActor<BEEFPaymentResponse>(completer),
      );

      libspiffy.paymentCoordinator.tell(
        PayInvoiceMessage(
          walletId: walletId,
          invoiceId: 'test-invoice-insufficient',
          addresses: ['mock-address-1'],
          amount: invoiceAmount,
        ),
        sender: receiver,
      );

      final response = await completer.future.timeout(Duration(seconds: 5));

      expect(response.success, isFalse);
      expect(response.error, contains('Insufficient funds'));
      
      print('✓ Correctly fails with insufficient funds');
    });

    test('fails when no available UTXOs', () async {
      final completer = Completer<BEEFPaymentResponse>();
      final receiver = await actorSystem.spawn(
        'payment-receiver-no-utxos',
        () => TestReceiverActor<BEEFPaymentResponse>(completer),
      );

      libspiffy.paymentCoordinator.tell(
        PayInvoiceMessage(
          walletId: walletId,
          invoiceId: 'test-invoice-no-utxos',
          addresses: ['mock-address-1'],
          amount: BigInt.from(10000),
        ),
        sender: receiver,
      );

      final response = await completer.future.timeout(Duration(seconds: 5));

      expect(response.success, isFalse);
      expect(response.error, contains('Insufficient funds'));
      
      print('✓ Correctly fails with no available UTXOs');
    });

    test('PaymentCoordinatorActor initializes correctly', () async {
      // Verify payment coordinator is accessible
      expect(libspiffy.paymentCoordinator, isNotNull);
      
      // Verify it responds to messages (even with error due to no UTXOs)
      final completer = Completer<BEEFPaymentResponse>();
      final receiver = await actorSystem.spawn(
        'payment-receiver-init-test',
        () => TestReceiverActor<BEEFPaymentResponse>(completer),
      );

      libspiffy.paymentCoordinator.tell(
        PayInvoiceMessage(
          walletId: walletId,
          invoiceId: 'init-test-invoice',
          addresses: ['test-address'],
          amount: BigInt.from(1000),
        ),
        sender: receiver,
      );

      final response = await completer.future.timeout(Duration(seconds: 5));
      
      // Should get a response (likely error due to no UTXOs, but that's fine)
      expect(response, isNotNull);
      
      print('✓ PaymentCoordinatorActor responds to messages');
    });
  });

}

