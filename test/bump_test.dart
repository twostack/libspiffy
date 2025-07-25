import 'dart:convert';
import 'dart:typed_data';
import 'package:buffer/buffer.dart';
import 'package:convert/convert.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:libspiffy/src/utils/beef.dart';
import 'package:libspiffy/src/utils/bump.dart';
import 'package:libspiffy/src/utils/crypto_utils.dart';
import 'package:spiffynode/spiffy_node.dart';
import 'package:test/test.dart';

void main() {
  // Example BUMP data from the BEEF example
  const String validBUMPHex = 'fe636d0c0007021400fe507c0c7aa754cef1f7889d5fd395cf1f785dd7de98eed895dbedfe4e5bc70d1502ac4e164f5bc16746bb0868404292ac8318bbac3800e4aad13a014da427adce3e010b00bc4ff395efd11719b277694cface5aa50d085a0bb81f613f70313acd28cf4557010400574b2d9142b8d28b61d88e3b2c3f44d858411356b49a28a4643b6d1a6a092a5201030051a05fc84d531b5d250c23f4f886f6812f9fe3f402d61607f977b4ecd2701c19010000fd781529d58fc2523cf396a7f25440b409857e7e221766c57214b1d38c7b481f01010062f542f45ea3660f86c013ced80534cb5fd4c19d66c56e7e8c5d4bf2d40acc5e010100b121e91836fd7cd5102b654e9f72f3cf6fdbfd0b161c53a9c54b12c841126331';


  final realTransactions = [
    {
      "txid": "dd6e7547df0fe893a9a19f66f0377eca72fdcd18fd9f6185fde9c91461a8e8a9",
      "hex": "02000000013706d29b641d2061b0b7b22c81ec6a5670104826bee4472a7513619f4fc298df000000006a473044022021fb2500cfd69bf3d7eee8f16d2e1d6d49528dbe23e9105744202bd9e5b5789102204ff801667c156b97e92209c19dce9bbdd955ee35cea7b815cf9e3b0c1b6727174121022036646b3fd79dee41351f727f0a6e10d0e7f98585961bc14e7aadaf5f4b66ab0100000002a0443b00000000001976a914f82d58dd8487044d8d0879c15a2a3516a425de2a88ac96000000000000001976a914f82d58dd8487044d8d0879c15a2a3516a425de2a88ac00000000",
      "blockhash": "00000000cf9e8013b71e0c1c454208ad60a639adba6b6d7fcf6426da1e1efdb2",
      "blockheight": 1641074,
      "blocktime": 1729051303,
      "confirmations": 24454
    },
    {
      "txid": "fb4087a12b03caa64a687ae09a2ce36a22a9a4273f177d4e83e6f8095331369a",
      "hex": "020000000143fa91a1cc2b03e80646d2f15c0c75fd5a2e48270838d075f46e121a866dd3c4000000006a473044022031e9fe7d9279938ae04ccd543f620b99f7ccb9e755c4fd5de2f4d1053858db4802207c21fb144d19544ab934cd557936acb6bd67e99aa132f73a71e892609bfaabee4121022036646b3fd79dee41351f727f0a6e10d0e7f98585961bc14e7aadaf5f4b66ab0100000002f53c3b00000000001976a914f82d58dd8487044d8d0879c15a2a3516a425de2a88ac96000000000000001976a914f82d58dd8487044d8d0879c15a2a3516a425de2a88ac00000000",
      "blockhash": "00000000dd5232b75661ece6943790f9671755490af7d233891201dc92f76a92",
      "blockheight": 1641086,
      "blocktime": 1729059327,
      "confirmations": 24442
    }
  ];

  final tscProofs = [
    {
      "index": 6,
      "txOrId": "dd6e7547df0fe893a9a19f66f0377eca72fdcd18fd9f6185fde9c91461a8e8a9",
      "target": "00000000cf9e8013b71e0c1c454208ad60a639adba6b6d7fcf6426da1e1efdb2",
      "nodes": [
        "f4d4fc63094d73b31e13da814ec4556865f53c329c53020e56ad71464e6f85fe",
        "bdcde417243f95840bd6fcfddbad0b198285f9f38d38093dc8826c3a3a7666f0",
        "9304304659a72e3e17ad1a447fecb4b082c8340683249a2cfa8ea3d411ad5c76",
        "5d2528dae0d0992da93f485ccbef24f06ef62ebf055bcc9d43b05dbdbe897dc2"
      ]
    },
    {
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
    }
  ];

  final blockHeaders = [
    {
      "hash": "00000000cf9e8013b71e0c1c454208ad60a639adba6b6d7fcf6426da1e1efdb2",
      "confirmations": 24454,
      "size": 2655,
      "height": 1641074,
      "version": 536870912,
      "versionHex": "20000000",
      "merkleroot": "49b5be64b429e9ce9b7a91e3581d4a9cdaf61b935b33981ebcfef6256aa2fba0",
      "time": 1729051303,
      "mediantime": 1729047305,
      "nonce": 1307527718,
      "bits": "1d00ffff",
      "difficulty": 1,
      "chainwork": "000000000000000000000000000000000000000000000157bf2772d94a10cd53",
      "previousblockhash": "0000000006d30de00e6c6c16ebfabcd833c7c367a26a86f00f8ff4067d842295",
      "nextblockhash": "0000000002dac0d24282e19b08ff97267f8fba6b16f3e043e57f50a7ccc9fafb",
      "nTx": 0,
      "num_tx": 10
    },
    {
      "hash": "00000000dd5232b75661ece6943790f9671755490af7d233891201dc92f76a92",
      "confirmations": 24442,
      "size": 6147915,
      "height": 1641086,
      "version": 536870912,
      "versionHex": "20000000",
      "merkleroot": "f83721206f6b5e336d7b661d1d25deafa7c43cf25c608a7c906c4de1a9e9f57a",
      "time": 1729059327,
      "mediantime": 1729056659,
      "nonce": 1492328476,
      "bits": "1d00ffff",
      "difficulty": 1,
      "chainwork": "000000000000000000000000000000000000000000000157bf2772fa0461bb94",
      "previousblockhash": "00000000374259369de4a6707dfa020527712c75da9c52a3ad26b4f68705f4f7",
      "nextblockhash": "0000000011f95ded991b2f0c8c35c63b3bbf81de221b5e155acf16009ee95af4",
      "nTx": 0,
      "num_tx": 131
    }
  ];


  // Helper function to convert hex to bytes
  Uint8List hexToBytes(String hex) {
    final result = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < hex.length; i += 2) {
      result[i ~/ 2] = int.parse(hex.substring(i, i + 2), radix: 16);
    }
    return result;
  }

  // Helper function to convert bytes to hex
  String bytesToHex(Uint8List bytes) {
    return bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join('');
  }

  // Use CryptoUtils.reverseBytes instead of our own implementation
  String reverseHexBytes(String hex) {
    return CryptoUtils.reverseBytes(hex);
  }

  // Calculate transaction ID from raw transaction bytes
  Uint8List calculateTxid(Uint8List txBytes) {
    final hash = dartsv.sha256Twice(txBytes);
    // TXID is displayed in reverse byte order
    return Uint8List.fromList(hash.reversed.toList());
  }


  group('BUMP Tests', () {
    test('Parse and Serialize', () {
      // Parse the valid BUMP hex
      final data = hexToBytes(validBUMPHex);
      
      final reader = ByteDataReader();
      reader.add(data);
      final bump = BUMP.parse(reader);
      
      // Verify basic structure
      expect(bump.blockHeight, 814435); // fe636d0c -> VarInt encoding
      expect(bump.path.length, 7);      // Tree height is 7
      
      // Verify first level
      expect(bump.path[0].leaves.length, 2);
      expect(bump.path[0].leaves[0].offset, 20);
      expect(bump.path[0].leaves[0].duplicate, false);
      expect(bump.path[0].leaves[0].isTxid, false);
      expect(bump.path[0].leaves[0].hash, isNotNull);
      expect(bump.path[0].leaves[0].hash!.length, 32);
      
      // Test serialization
      final serialized = bump.serialize();
      
      // Parse the serialized data again
      final reader2 = ByteDataReader();
      reader2.add(serialized);
      final bump2 = BUMP.parse(reader2);
      
      // Verify the structures match
      expect(bump2.blockHeight, bump.blockHeight);
      expect(bump2.path.length, bump.path.length);
      
      for (var i = 0; i < bump.path.length; i++) {
        expect(bump2.path[i].leaves.length, bump.path[i].leaves.length);
        
        for (var j = 0; j < bump.path[i].leaves.length; j++) {
          expect(bump2.path[i].leaves[j].offset, bump.path[i].leaves[j].offset);
          expect(bump2.path[i].leaves[j].duplicate, bump.path[i].leaves[j].duplicate);
          expect(bump2.path[i].leaves[j].isTxid, bump.path[i].leaves[j].isTxid);
          
          if (bump.path[i].leaves[j].hash != null) {
            expect(
              bytesToHex(bump2.path[i].leaves[j].hash!), 
              bytesToHex(bump.path[i].leaves[j].hash!)
            );
          } else {
            expect(bump2.path[i].leaves[j].hash, isNull);
          }
        }
      }
      
      // Verify the serialized bytes match the original
      expect(bytesToHex(serialized), validBUMPHex);
    });
    
    test('Parse Errors', () {
      final testCases = [
        {
          'name': 'empty data',
          'data': Uint8List(0),
          'wantErr': 'Not enough bytes to read'
        },
        {
          'name': 'truncated after block height',
          'data': hexToBytes('fe636d0c'),
          'wantErr': 'Not enough bytes to read'
        },
        {
          'name': 'invalid tree height',
          'data': hexToBytes('fe636d0cff'),
          'wantErr': 'Not enough bytes to read'
        },
      ];
      
      for (final testCase in testCases) {
        try {
          final reader = ByteDataReader();
          reader.add(testCase['data'] as Uint8List);
          BUMP.parse(reader);
          fail('Expected error for test case: ${testCase['name']}');
        } catch (e) {
          expect(e.toString(), contains(testCase['wantErr'] as String));
        }
      }
    });

    test('Validate Merkle Path', () {
      // Create a simple merkle path with a single transaction
      final txid = hexToBytes('1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef');
      final siblingHash = hexToBytes('abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890');
      
      // Create the BUMP object
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
            // The sibling hash
            Leaf(
              offset: 1,
              duplicate: false,
              isTxid: false,
              hash: siblingHash,
            ),
          ]),
        ],
      );
      
      // Validate the merkle path with the correct txid
      expect(bump.validateMerklePath(txid), true);
      
      // Validate with an incorrect txid
      final wrongTxid = hexToBytes('0000000000000000000000000000000000000000000000000000000000000000');
      expect(bump.validateMerklePath(wrongTxid), false);
    });
    
    test('Create BUMP from TSC Proof - First Transaction', () {
      // Create a BUMP from the first TSC proof
      final tscProof = tscProofs[0];
      final transaction = realTransactions[0];
      final blockHeader = blockHeaders[0];
      
      // Verify TXID in correct format
      final txid = transaction['txid'] as String;
      
      // Create the BUMP using CryptoUtils
      final bump = CryptoUtils.createBumpFromTscProof(
        tscProof, 
        transaction['blockheight'] as int
      );
      
      // Verify basic structure
      expect(bump.blockHeight, transaction['blockheight']);
      expect(bump.path.length, (tscProof['nodes'] as List<dynamic>).length + 1);
      
      // Verify TXID in the BUMP matches the transaction
      final txidBytes = hexToBytes(reverseHexBytes(txid));
      expect(bump.validateMerklePath(txidBytes), true);
      
      // Print debugging information
      print('Transaction: $txid');
      print('Block Height: ${transaction['blockheight']}');
      print('Block Merkle Root: ${blockHeader['merkleroot']}');
      
      // Try direct validation with CryptoUtils.validateMerkleProofWithByteReversal
      // This is the approach used in the _validateMerkleProof method
      final nodesList = (tscProof['nodes'] as List<dynamic>).cast<String>();
      final index = tscProof['index'] as int;
      
      final directValidation = CryptoUtils.validateMerkleProofWithByteReversal(
        txid, 
        nodesList, 
        blockHeader['merkleroot'] as String, 
        index
      );
      
      print('Direct Validation Result: ${directValidation ? "VALID" : "INVALID"}');
      
      // The critical assertion - this is what the wallet uses for validation
      expect(directValidation, true, reason: 'Merkle proof should validate successfully');
    });
    
    test('Create BUMP from TSC Proof - Second Transaction', () {
      // Create a BUMP from the second TSC proof
      final tscProof = tscProofs[1];
      final transaction = realTransactions[1];
      final blockHeader = blockHeaders[1];
      
      // Verify TXID in correct format
      final txid = transaction['txid'] as String;
      
      // Create the BUMP using CryptoUtils
      final bump = CryptoUtils.createBumpFromTscProof(
        tscProof, 
        transaction['blockheight'] as int
      );
      
      // Verify basic structure
      expect(bump.blockHeight, transaction['blockheight']);
      expect(bump.path.length, (tscProof['nodes'] as List<dynamic>).length + 1);
      
      // Verify TXID in the BUMP matches the transaction
      final txidBytes = hexToBytes(reverseHexBytes(txid));
      expect(bump.validateMerklePath(txidBytes), true);
      
      // Print debugging information
      print('Transaction: $txid');
      print('Block Height: ${transaction['blockheight']}');
      print('Block Merkle Root: ${blockHeader['merkleroot']}');
      
      // Try direct validation with CryptoUtils.validateMerkleProofWithByteReversal
      // This is the approach used in the _validateMerkleProof method
      final nodesList = (tscProof['nodes'] as List<dynamic>).cast<String>();
      final index = tscProof['index'] as int;
      
      final directValidation = CryptoUtils.validateMerkleProofWithByteReversal(
        txid, 
        nodesList, 
        blockHeader['merkleroot'] as String, 
        index
      );
      
      print('Direct Validation Result: ${directValidation ? "VALID" : "INVALID"}');
      
      // The critical assertion - this is what the wallet uses for validation
      expect(directValidation, true, reason: 'Merkle proof should validate successfully');
    });
    
    test('Verify Transaction TXID Calculation', () {
      // Verify that we can correctly calculate the TXID from raw transaction hex
      for (final tx in realTransactions) {
        final txBytes = hexToBytes(tx['hex'] as String);
        final calculatedTxid = calculateTxid(txBytes);
        final expectedTxid = hexToBytes(tx['txid'] as String);
        
        expect(
          bytesToHex(calculatedTxid),
          bytesToHex(expectedTxid),
          reason: 'TXID calculation failed for ${tx["txid"]}'
        );
      }
    });
    
    test('Combine Multiple BUMPs', () {
      // Create two simple BUMPs with the same tree height and block height for testing
      final txid1 = hexToBytes(reverseHexBytes(realTransactions[0]['txid'] as String));
      final txid2 = hexToBytes(reverseHexBytes(realTransactions[1]['txid'] as String));
      
      // Create simplified BUMPs with just level 0
      final bump1 = BUMP(
        blockHeight: 123456,
        path: [
          Level(leaves: [
            Leaf(
              offset: 0,
              duplicate: false,
              isTxid: true,
              hash: txid1,
            ),
          ]),
        ],
      );
      
      final bump2 = BUMP(
        blockHeight: 123456, // Same block height
        path: [
          Level(leaves: [
            Leaf(
              offset: 1, // Different offset
              duplicate: false,
              isTxid: true,
              hash: txid2,
            ),
          ]),
        ],
      );
      
      // Create a combined BUMP using CryptoUtils
      final combinedBump = CryptoUtils.combineBumps([bump1, bump2]);
      
      // Verify basic structure
      expect(combinedBump.blockHeight, 123456);
      expect(combinedBump.path.length, 1);
      expect(combinedBump.path[0].leaves.length, 2); // Should have both leaves
      
      // Verify we can find both transactions in the combined BUMP
      expect(combinedBump.validateMerklePath(txid1), true);
      expect(combinedBump.validateMerklePath(txid2), true);
    });
    
    test('BUMP Handles Duplicate Flag Correctly', () {
      // Create a BUMP with duplicate flag set on some leaves
      final txid = hexToBytes(reverseHexBytes(realTransactions[0]['txid'] as String));
      
      final bump = BUMP(
        blockHeight: 123456,
        path: [
          Level(leaves: [
            Leaf(
              offset: 0,
              duplicate: false,
              isTxid: true,
              hash: txid,
            ),
            Leaf(
              offset: 1,
              duplicate: true, // This leaf should duplicate the working hash
              isTxid: false,
              hash: null, // No hash should be provided when duplicate is true
            ),
          ]),
        ],
      );
      
      // Serialize and parse back
      final serialized = bump.serialize();
      final reader = ByteDataReader();
      reader.add(serialized);
      final parsedBump = BUMP.parse(reader);
      
      // Verify the structures match
      expect(parsedBump.blockHeight, bump.blockHeight);
      expect(parsedBump.path.length, bump.path.length);
      expect(parsedBump.path[0].leaves.length, bump.path[0].leaves.length);
      
      // Verify duplicate flag
      expect(parsedBump.path[0].leaves[1].duplicate, true);
      expect(parsedBump.path[0].leaves[1].hash, isNull);
      
      // Validate that the merkle path still works with duplicate flags
      expect(parsedBump.validateMerklePath(txid), true);
    });
    
    test('Compute Merkle Root in Block Header Format - First Transaction', () {
      // Create a BUMP from the first TSC proof
      final tscProof = tscProofs[0];
      final transaction = realTransactions[0];
      final blockHeader = blockHeaders[0];
      
      // Verify TXID in correct format
      final txid = transaction['txid'] as String;
      
      // Create the BUMP using CryptoUtils
      final bump = CryptoUtils.createBumpFromTscProof(
        tscProof, 
        transaction['blockheight'] as int
      );
      
      // Get the TSC proof data directly
      final nodesList = (tscProof['nodes'] as List<dynamic>).cast<String>();
      final index = tscProof['index'] as int;
      
      // Validate using the method from _validateMerkleProof()
      final isValid = CryptoUtils.validateMerkleProofWithByteReversal(
        txid, 
        nodesList, 
        blockHeader['merkleroot'] as String, 
        index
      );
      
      print('Transaction: $txid');
      print('Block Header Merkle Root: ${blockHeader['merkleroot']}');
      print('Direct Validation Result: ${isValid ? "VALID" : "INVALID"}');
      
      // The critical test - the merkle proof should validate against the block header
      expect(isValid, true, reason: 'Merkle proof validation should succeed');
    });
    
    test('Compute Merkle Root in Block Header Format - Second Transaction', () {
      // Create a BUMP from the second TSC proof
      final tscProof = tscProofs[1];
      final transaction = realTransactions[1];
      final blockHeader = blockHeaders[1];
      
      // Verify TXID in correct format
      final txid = transaction['txid'] as String;
      
      // Create the BUMP using CryptoUtils
      final bump = CryptoUtils.createBumpFromTscProof(
        tscProof, 
        transaction['blockheight'] as int
      );
      
      // Get the TSC proof data directly
      final nodesList = (tscProof['nodes'] as List<dynamic>).cast<String>();
      final index = tscProof['index'] as int;
      
      // Validate using the method from _validateMerkleProof()
      final isValid = CryptoUtils.validateMerkleProofWithByteReversal(
        txid, 
        nodesList, 
        blockHeader['merkleroot'] as String, 
        index
      );
      
      print('Transaction: $txid');
      print('Block Header Merkle Root: ${blockHeader['merkleroot']}');
      print('Direct Validation Result: ${isValid ? "VALID" : "INVALID"}');
      
      // The critical test - the merkle proof should validate against the block header
      expect(isValid, true, reason: 'Merkle proof validation should succeed');
    });

    test('can create and validate the following bump structure', () async {

     const jsonProof = '{"index":2,"path":["d194ec91b4f931ac613437f78fe8fd1a3c83d9d45179c2a94fd13999bc70dee3","c7437c9dd1e6292b9c54e367530ec6988b08bb88f2e6c2531d6fc41a9040431b"]}';
     //[{"index":2,"txOrId":"d194ec91b4f931ac613437f78fe8fd1a3c83d9d45179c2a94fd13999bc70dee3","target":"000000000000000273312eecee76b164f6d3ab00fa2a7426ce04228a6efe9f2b","nodes":["d194ec91b4f931ac613437f78fe8fd1a3c83d9d45179c2a94fd13999bc70dee3","c7437c9dd1e6292b9c54e367530ec6988b08bb88f2e6c2531d6fc41a9040431b"]}]

    final merkleProofJson = jsonDecode(jsonProof);
            
    final merkleRoot = CryptoUtils.computeMerkleRootFromBrc71("d194ec91b4f931ac613437f78fe8fd1a3c83d9d45179c2a94fd13999bc70dee3", jsonDecode(jsonProof));

     // Convert BRC-71 format to BUMP
     final bump = CryptoUtils.convertBrc71PathToBump( merkleProofJson, 1578586, "d194ec91b4f931ac613437f78fe8fd1a3c83d9d45179c2a94fd13999bc70dee3" );

     // bump.validateMerklePath(txid);
     final bumpRoot = bump.computeMerkleRoot(Uint8List.fromList(hex.decode("d194ec91b4f931ac613437f78fe8fd1a3c83d9d45179c2a94fd13999bc70dee3")));
     final bumpRootHex = hex.encode(bumpRoot);


     expect(bumpRootHex, merkleRoot); //the computed merkle root from BUMP must match the known-good calculation from merkleRoo

     const rawTx = "0200000001ecda13a4f024b84f096064f7cc63e2970b6fa3d927de6b1e8867411d9a645d21010000006b483045022100e02985dfdffe26d87a6053cc3a4d7af834de1271ba9e7608fa4dd74f6d627aa4022003fecf482c7228385eba23be698964c676891f7224b365eaef91579226c7f0974121028fa64c7d1931de5c0a41fa67b2c3db1b747fa2ff8bcc1ba94d512ce620fac2ac0100000002e803000000000000fda6032097dfd76851bf465e8f715593b217714858bbe9570ff3bd5e33840a34e20ff0262102ba79df5f8ae7604a9830f03c7933028186aede0675a16f025dc4f8be8eec0382201008ce7480da41702918d1ec8e6849ba32b4d65b1e40dc669c31a1e6306b266c0000144e07670dfb42341d1708e17b8813424ce7646c3b035a1618610079040065cd1d9f690079547a75537a537a537a5179537a75527a527a7575615579014161517957795779210ac407f0e4bd44bfc207355a778b046225a7068fc59ee7eda43ad905aadbffc800206c266b30e6a1319c66dc401e5bd6b432ba49688eecd118297041da8074ce081059795679615679aa0079610079517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e01007e81517a75615779567956795679567961537956795479577995939521414136d08c5ed2bf3ba048afe6dcaebafeffffffffffffffffffffffffffffff00517951796151795179970079009f63007952799367007968517a75517a75517a7561527a75517a517951795296a0630079527994527a75517a6853798277527982775379012080517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e01205279947f7754537993527993013051797e527e54797e58797e527e53797e52797e57797e0079517a75517a75517a75517a75517a75517a75517a75517a75517a75517a75517a75517a75517a756100795779ac517a75517a75517a75517a75517a75517a75517a75517a75517a7561517a75517a756169557961007961007982775179517954947f75517958947f77517a75517a756161007901007e81517a7561517a7561040065cd1d9f6955796100796100798277517951790128947f755179012c947f77517a75517a756161007901007e81517a7561517a756105ffffffff009f69557961007961007982775179517954947f75517958947f77517a75517a756161007901007e81517a7561517a75615279a2695679a95179876957795779ac777777777777777716e5a435000000001976a9144e07670dfb42341d1708e17b8813424ce7646c3b88ac00000000";

    final beef = BEEF.create(
      bumps: [bump],
      txs: [Uint8List.fromList(hex.decode(rawTx))],
      hasMerkle: [true],
      bumpIndex: [0],
    );

     final blockHeaderWithMerkleRoot = BlockHeader(
       version: 1,
       prevBlock: Hash.fromHex('000000000000001365b00b48c462a9345f92b3683a5c0496e287970666b0b2d6'),
       merkleRoot: Hash.fromHex('f8f0c910c6b26a66822638435f0fcf58ca25154ccc349ff83445ab1262c464ea'),
       timestamp: DateTime.fromMicrosecondsSinceEpoch(1698044011),
       bits: 0,
       nonce: 2009140124,
     );

     expect(merkleRoot, hex.encode(blockHeaderWithMerkleRoot.merkleRoot.bytes.reversed.toList()));

     final txn = dartsv.Transaction.fromHex(rawTx);

     final isBeefValid = await beef.validateTransactionWithBlockHeader(Uint8List.fromList(hex.decode(txn.id)), blockHeaderWithMerkleRoot );

     expect(isBeefValid, true);

     // final isValid = CryptoUtils.validateMerkleProofWithByteReversal(txid, proof.path, blockHeader, index);
     // expect(isValid, true);
    });
  });
}
