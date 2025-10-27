import 'dart:typed_data';
import 'package:convert/convert.dart';
import 'package:libspiffy/libspiffy.dart';
import 'package:mockito/mockito.dart';
import 'package:mockito/annotations.dart';
import 'package:spiffynode/spiffy_node.dart';
import 'package:test/test.dart';

// Generate mock classes
@GenerateMocks([BlockHeaderService])
import 'beef_test.mocks.dart';

void main() {
  const String validBEEFHex = '0100beef01fe636d0c0007021400fe507c0c7aa754cef1f7889d5fd395cf1f785dd7de98eed895dbedfe4e5bc70d1502ac4e164f5bc16746bb0868404292ac8318bbac3800e4aad13a014da427adce3e010b00bc4ff395efd11719b277694cface5aa50d085a0bb81f613f70313acd28cf4557010400574b2d9142b8d28b61d88e3b2c3f44d858411356b49a28a4643b6d1a6a092a5201030051a05fc84d531b5d250c23f4f886f6812f9fe3f402d61607f977b4ecd2701c19010000fd781529d58fc2523cf396a7f25440b409857e7e221766c57214b1d38c7b481f01010062f542f45ea3660f86c013ced80534cb5fd4c19d66c56e7e8c5d4bf2d40acc5e010100b121e91836fd7cd5102b654e9f72f3cf6fdbfd0b161c53a9c54b12c841126331020100000001cd4e4cac3c7b56920d1e7655e7e260d31f29d9a388d04910f1bbd72304a79029010000006b483045022100e75279a205a547c445719420aa3138bf14743e3f42618e5f86a19bde14bb95f7022064777d34776b05d816daf1699493fcdf2ef5a5ab1ad710d9c97bfb5b8f7cef3641210263e2dee22b1ddc5e11f6fab8bcd2378bdd19580d640501ea956ec0e786f93e76ffffffff013e660000000000001976a9146bfd5c7fbe21529d45803dbcf0c87dd3c71efbc288ac0000000001000100000001ac4e164f5bc16746bb0868404292ac8318bbac3800e4aad13a014da427adce3e000000006a47304402203a61a2e931612b4bda08d541cfb980885173b8dcf64a3471238ae7abcd368d6402204cbf24f04b9aa2256d8901f0ed97866603d2be8324c2bfb7a37bf8fc90edd5b441210263e2dee22b1ddc5e11f6fab8bcd2378bdd19580d640501ea956ec0e786f93e76ffffffff013c660000000000001976a9146bfd5c7fbe21529d45803dbcf0c87dd3c71efbc288ac0000000000';

  const String beefHEX2 = '0100beef01fe5dea120007010202a05924fcc63712d3e4b94b0c88baad234c2c8ad3d369704f53765e21a53a21010103002bb617ed9b7950dcc9ddd952364a5d039742b40b786d3ef8a3984a5cf5495640010000e0c82744e0d7c7a1e72102b82fa37ae09f4e6018ebb18773f888617b83250e750106009991c11c2ecb5087a29032a279d926bfe03c926c582a30743c902b57a3d98039010a009d54821a3821713dadeeb3a614921f8c63866f82686cbcf019ed7a6c20a36d2b011200a1e33369efb20fa5a1311ddfed20747de1996fdc814aa19691106eafe28b3e5d0122005a2f7dcc9b1fddc64f57157e7c59082729622050a76cb6956ae6b15f1a9ff0c402020000000165b6c06790c23623c4988ee51b3f27c76bfb6a0c9e5bab3432968c51379af66a000000006b483045022100b735fb60adca4fa42e37746aa602c3206bf98572ae83e396da4fd11cb716b26d022017bf9955bd8fc4d60f2829236c7864d5b5540062c88113daef137c0ee441736c41210222824a8530bc570b7bae7c7600529b450a65eab1203c5f561d8082cd97b3dba1feffffff02872ec735150000001976a9149d02ce72bbdc1713d5537a0705d8ec7d9702c81088ac00c2eb0b000000001976a9146a418bf9e2e2b670e1aa7b7da59391e212b4ba1988ac5cea12000100020000000101213aa5215e76534f7069d3d38a2c4c23adba880c4bb9e4d31237c6fc2459a00100000000ffffffff0164000000000000001976a914c0be1d0305c0a7451bf9a8e69b38ecdb3d981a2888ac0000000000';
  Uint8List hexToBytes(String hex) {
    final result = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < hex.length; i += 2) {
      result[i ~/ 2] = int.parse(hex.substring(i, i + 2), radix: 16);
    }
    return result;
  }

  String bytesToHex(Uint8List bytes) {
    return bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join('');
  }
  
  // Helper function to compare two Uint8List objects
  bool listEquals(Uint8List a, Uint8List b) {
    if (a.length != b.length) {
      return false;
    }
    
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) {
        return false;
      }
    }
    
    return true;
  }

  group('BEEF Tests', () {
    test('Parse and dump this test BEEF', (){

      final ser = Uint8List.fromList(hex.decode(beefHEX2));
      final beef = BEEF.parse(ser);

      final txns = beef.getVerifiedTransactions();
      for (BUMP bump in beef.bumps){
        for (final txMap in txns) {
          print(" Merkle Root : " + hex.encode(bump.computeMerkleRoot(txMap['txid'])));
        }
      }

    });


    test('Parse and Serialize', () {

      // Parse the valid BEEF hex
      final vb = '0100beef01fe636d0c0007021400fe507c0c7aa754cef1f7889d5fd395cf1f785dd7de98eed895dbedfe4e5bc70d1502ac4e164f5bc16746bb0868404292ac8318bbac3800e4aad13a014da427adce3e010b00bc4ff395efd11719b277694cface5aa50d085a0bb81f613f70313acd28cf4557010400574b2d9142b8d28b61d88e3b2c3f44d858411356b49a28a4643b6d1a6a092a5201030051a05fc84d531b5d250c23f4f886f6812f9fe3f402d61607f977b4ecd2701c19010000fd781529d58fc2523cf396a7f25440b409857e7e221766c57214b1d38c7b481f01010062f542f45ea3660f86c013ced80534cb5fd4c19d66c56e7e8c5d4bf2d40acc5e010100b121e91836fd7cd5102b654e9f72f3cf6fdbfd0b161c53a9c54b12c841126331020100000001cd4e4cac3c7b56920d1e7655e7e260d31f29d9a388d04910f1bbd72304a79029010000006b483045022100e75279a205a547c445719420aa3138bf14743e3f42618e5f86a19bde14bb95f7022064777d34776b05d816daf1699493fcdf2ef5a5ab1ad710d9c97bfb5b8f7cef3641210263e2dee22b1ddc5e11f6fab8bcd2378bdd19580d640501ea956ec0e786f93e76ffffffff013e660000000000001976a9146bfd5c7fbe21529d45803dbcf0c87dd3c71efbc288ac0000000001000100000001ac4e164f5bc16746bb0868404292ac8318bbac3800e4aad13a014da427adce3e000000006a47304402203a61a2e931612b4bda08d541cfb980885173b8dcf64a3471238ae7abcd368d6402204cbf24f04b9aa2256d8901f0ed97866603d2be8324c2bfb7a37bf8fc90edd5b441210263e2dee22b1ddc5e11f6fab8bcd2378bdd19580d640501ea956ec0e786f93e76ffffffff013c660000000000001976a9146bfd5c7fbe21529d45803dbcf0c87dd3c71efbc288ac0000000000';
      final data = hexToBytes(vb);
      
      final beef = BEEF.parse(data);
      
      // Verify basic structure
      expect(beef.version, beefMagicAndVersion);
      expect(beef.bumps.length, 1);
      expect(beef.txs.length, 2);
      expect(beef.hasMerkle, [true, false]);
      expect(beef.bumpIndex, [0]);
      
      // Verify BUMP details
      final bump = beef.bumps[0];
      expect(bump.blockHeight, 814435); // fe636d0c -> VarInt encoding
      expect(bump.path.length, 7);      // Tree height is 7
      
      // Verify first transaction has merkle proof
      expect(beef.hasMerkle[0], true);
      expect(beef.bumpIndex[0], 0);
      
      // Verify second transaction doesn't have merkle proof
      expect(beef.hasMerkle[1], false);
      
      // Test serialization
      final serialized = beef.serialize();
      
      // Parse the serialized data again
      final beef2 = BEEF.parse(serialized);
      
      // Verify the structures match
      expect(beef2.version, beef.version);
      expect(beef2.bumps.length, beef.bumps.length);
      expect(beef2.txs.length, beef.txs.length);
      expect(beef2.hasMerkle, beef.hasMerkle);
      expect(beef2.bumpIndex, beef.bumpIndex);
      
      // Verify the serialized bytes match the original
      expect(bytesToHex(serialized), validBEEFHex);
    });
    
    test('Parse Errors', () {
      final testCases = [
        {
          'name': 'empty data',
          'data': Uint8List(0),
          'wantErr': 'Invalid BEEF format: data too short'
        },
        {
          'name': 'invalid version',
          'data': hexToBytes('00000000'),
          'wantErr': 'Invalid BEEF version'
        },
        {
          'name': 'truncated after version',
          'data': hexToBytes('0100BEEF'),
          'wantErr': 'Not enough bytes to read'
        },
      ];
      
      for (final testCase in testCases) {
        try {
          BEEF.parse(testCase['data'] as Uint8List);
          fail('Expected error for test case: ${testCase['name']}');
        } catch (e) {
          expect(e.toString(), contains(testCase['wantErr'] as String));
        }
      }
    });
    
    test('Validate', () {

      // Parse the valid BEEF hex
      final data = hexToBytes(validBEEFHex);
      final beef = BEEF.parse(data);
      
      // Verify validation passes
      expect(beef.validate(), true);
      
      // Create an invalid BEEF with mismatched bumpIndex length
      final invalidBeef = BEEF(
        version: beefMagicAndVersion,
        bumps: beef.bumps,
        txs: beef.txs,
        hasMerkle: [true, true], // Both transactions have merkle proofs
        bumpIndex: [0], // But only one bumpIndex
      );
      
      // Verify validation fails
      expect(invalidBeef.validate(), false);
      
      // Create an invalid BEEF with invalid bumpIndex
      final invalidBeef2 = BEEF(
        version: beefMagicAndVersion,
        bumps: beef.bumps,
        txs: beef.txs,
        hasMerkle: [true, false],
        bumpIndex: [99], // Invalid index
      );
      
      // Verify validation fails
      expect(invalidBeef2.validate(), false);
    });
    
    test('Transaction Validation', () {
      // Create a simple BEEF with one transaction and one BUMP
      final txData = hexToBytes('0100000001cd4e4cac3c7b56920d1e7655e7e260d31f29d9a388d04910f1bbd72304a79029010000006b483045022100e75279a205a547c445719420aa3138bf14743e3f42618e5f86a19bde14bb95f7022064777d34776b05d816daf1699493fcdf2ef5a5ab1ad710d9c97bfb5b8f7cef3641210263e2dee22b1ddc5e11f6fab8bcd2378bdd19580d640501ea956ec0e786f93e76ffffffff013e660000000000001976a9146bfd5c7fbe21529d45803dbcf0c87dd3c71efbc288ac00000000');
      
      // Calculate the TXID
      final beef = BEEF(
        version: beefMagicAndVersion,
        bumps: [],
        txs: [],
        hasMerkle: [],
        bumpIndex: [],
      );
      
      final txid = beef.calculateTxid(txData);
      
      // Create a BUMP with a merkle path that includes this transaction
      final bump = BUMP(
        blockHeight: 123456,
        path: [
          Level(leaves: [
            // The transaction ID
            Leaf(
              offset: 0,
              duplicate: false,
              isTxid: true,
              hash: txid,
            ),
            // A sibling hash
            Leaf(
              offset: 1,
              duplicate: false,
              isTxid: false,
              hash: hexToBytes('abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890'),
            ),
          ]),
        ],
      );
      
      // Create the BEEF with the transaction and BUMP
      final beefWithTx = BEEF(
        version: beefMagicAndVersion,
        bumps: [bump],
        txs: [txData],
        hasMerkle: [true],
        bumpIndex: [0],
      );
      
      // Test finding the transaction by TXID
      final txInfo = beefWithTx.findTransactionByTxid(txid);
      expect(txInfo, isNotNull);
      expect(txInfo!['index'], 0);
      expect(txInfo['hasMerkleProof'], true);
      expect(txInfo['bumpIndex'], 0);
      
      // Test validating the transaction
      expect(beefWithTx.validateTransaction(txid), true);
      
      // Test with an invalid TXID
      final invalidTxid = hexToBytes('0000000000000000000000000000000000000000000000000000000000000000');
      expect(beefWithTx.findTransactionByTxid(invalidTxid), isNull);
      expect(beefWithTx.validateTransaction(invalidTxid), false);
      
      // Test getVerifiedTransactions
      final verifiedTxs = beefWithTx.getVerifiedTransactions();
      expect(verifiedTxs.length, 1);
      expect(listEquals(verifiedTxs[0]['txid'], txid), true);
      expect(verifiedTxs[0]['blockHeight'], 123456);
    });
    
    test('Block Header Validation', () async {
      // Create a mock BlockHeaderService
      final mockBlockHeaderService = MockBlockHeaderService();
      
      // Create a sample block header with all required fields
      final blockHeader = BlockHeader(
        version: 1,
        prevBlock: Hash.fromHex('0000000000000000000000000000000000000000000000000000000000000000'),
        merkleRoot: Hash.fromHex('4a5e1e4baab89f3a32518a88c31bc87f618f76673e2cc77ab2127b7afdeda33b'),
        timestamp: DateTime.fromMillisecondsSinceEpoch(1231006505 * 1000),
        bits: 486604799,
        nonce: 2083236893,
      );
      
      // Set up the mock to return our sample block header
      when(mockBlockHeaderService.getHeader(123456))
          .thenReturn(blockHeader);
      
      // Create a simple BEEF with one transaction and one BUMP
      final txData = hexToBytes('0100000001cd4e4cac3c7b56920d1e7655e7e260d31f29d9a388d04910f1bbd72304a79029010000006b483045022100e75279a205a547c445719420aa3138bf14743e3f42618e5f86a19bde14bb95f7022064777d34776b05d816daf1699493fcdf2ef5a5ab1ad710d9c97bfb5b8f7cef3641210263e2dee22b1ddc5e11f6fab8bcd2378bdd19580d640501ea956ec0e786f93e76ffffffff013e660000000000001976a9146bfd5c7fbe21529d45803dbcf0c87dd3c71efbc288ac00000000');
      
      // Calculate the TXID
      final beef = BEEF(
        version: beefMagicAndVersion,
        bumps: [],
        txs: [],
        hasMerkle: [],
        bumpIndex: [],
      );
      
      final txid = beef.calculateTxid(txData);
      
      // Create a BUMP with a merkle path that includes this transaction
      final bump = BUMP(
        blockHeight: 123456, // Match the block header height
        path: [
          Level(leaves: [
            // The transaction ID
            Leaf(
              offset: 0,
              duplicate: false,
              isTxid: true,
              hash: txid,
            ),
            // A sibling hash
            Leaf(
              offset: 1,
              duplicate: false,
              isTxid: false,
              hash: hexToBytes('abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890'),
            ),
          ]),
        ],
      );
      
      // Mock the merkle root computation to match the block header's merkle root
      final blockHeaderWithMerkleRoot = BlockHeader(
        version: 1,
        prevBlock: Hash.fromHex('0000000000000000000000000000000000000000000000000000000000000000'),
        // Use the actual computed merkle root from the BUMP
        merkleRoot: Hash.fromBytes(bump.computeMerkleRoot(txid)),
        timestamp: DateTime.fromMillisecondsSinceEpoch(1231006505 * 1000),
        bits: 486604799,
        nonce: 2083236893,
      );
      
      when(mockBlockHeaderService.getHeader(123456))
          .thenReturn(blockHeaderWithMerkleRoot);
      
      // Create the BEEF with the transaction and BUMP
      final beefWithTx = BEEF(
        version: beefMagicAndVersion,
        bumps: [bump],
        txs: [txData],
        hasMerkle: [true],
        bumpIndex: [0],
      );
      
      // Test validating the transaction with block header
      final isValid = await beefWithTx.validateTransactionWithBlockHeaderService(
        txid, 
        mockBlockHeaderService
      );
      expect(isValid, true);
      
      // Test with a non-matching merkle root but with a matching one in another header at the same height
      final nonMatchingHeader = BlockHeader(
        version: 1,
        prevBlock: Hash.fromHex('0000000000000000000000000000000000000000000000000000000000000000'),
        merkleRoot: Hash.fromHex('0000000000000000000000000000000000000000000000000000000000000000'), // non_matching_merkle_root
        timestamp: DateTime.fromMillisecondsSinceEpoch(1231006505 * 1000),
        bits: 486604799,
        nonce: 2083236893,
      );
      
      final matchingHeader = BlockHeader(
        version: 1,
        prevBlock: Hash.fromHex('0000000000000000000000000000000000000000000000000000000000000000'),
        merkleRoot: Hash.fromBytes(bump.computeMerkleRoot(txid)),
        timestamp: DateTime.fromMillisecondsSinceEpoch(1231006505 * 1000),
        bits: 486604799,
        nonce: 2083236893,
      );
      
      when(mockBlockHeaderService.getHeader(123456))
          .thenReturn(matchingHeader);
      
      final isValidWithFork = await beefWithTx.validateTransactionWithBlockHeaderService(
        txid, 
        mockBlockHeaderService
      );
      expect(isValidWithFork, true);
      
      // Test with an invalid block height
      when(mockBlockHeaderService.getHeader(999999))
          .thenReturn(null);
      
      final invalidBump = BUMP(
        blockHeight: 999999, // Higher than our latest block
        path: bump.path,
      );
      
      final beefWithInvalidHeight = BEEF(
        version: beefMagicAndVersion,
        bumps: [invalidBump],
        txs: [txData],
        hasMerkle: [true],
        bumpIndex: [0],
      );
      
      final isInvalidHeightValid = await beefWithInvalidHeight.validateTransactionWithBlockHeaderService(
        txid, 
        mockBlockHeaderService
      );
      expect(isInvalidHeightValid, false);
      
      // Test getBlockHeaderValidatedTransactions
      when(mockBlockHeaderService.getHeader(123456))
          .thenReturn(matchingHeader);
      
      final validatedTxs = await beefWithTx.getBlockHeaderValidatedTransactions(
        mockBlockHeaderService
      );
      expect(validatedTxs.length, 1);
      expect(validatedTxs[0]['validatedWithBlockHeader'], true);
      expect(listEquals(validatedTxs[0]['txid'], txid), true);
    });
  });
}
