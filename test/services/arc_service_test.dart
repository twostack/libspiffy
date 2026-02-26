import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:mockito/mockito.dart';
import 'package:mockito/annotations.dart';
import 'package:http/http.dart' as http;

import 'package:libspiffy/src/services/arc_service.dart';
import 'package:libspiffy/src/services/arc_service_config.dart';

import 'arc_service_test.mocks.dart';

@GenerateMocks([http.Client])
void main() {
  group('ArcService', () {
    late MockClient mockClient;
    late ArcService arcService;
    
    const baseUrl = 'https://arc-test.taal.com/v1';
    const apiKey = 'test-api-key';
    const testTxId = 'a1b2c3d4e5f6789012345678901234567890123456789012345678901234567890';
    const testRawTx = '0100000001a1b2c3d4e5f6789012345678901234567890123456789012345678901234567890000000006a47304402203e3f...'; // Mock raw transaction hex
    const testBeefHex = '0100beef01deadbeef'; // Mock BEEF hex

    setUp(() {
      mockClient = MockClient();
      arcService = ArcService(
        baseUrl: baseUrl,
        apiKey: apiKey,
        client: mockClient,
      );
    });

    group('Configuration and Setup', () {
      test('should create service with baseUrl and apiKey', () {
        expect(arcService.baseUrl, equals(baseUrl));
        expect(arcService.apiKey, equals(apiKey));
      });

      test('should create service without apiKey', () {
        final service = ArcService(
          baseUrl: baseUrl,
          client: mockClient,
        );
        expect(service.baseUrl, equals(baseUrl));
        expect(service.apiKey, isNull);
      });

      test('should create service from config', () {
        const config = ArcServiceConfig(
          baseUrl: baseUrl,
          apiKey: apiKey,
        );
        final service = ArcService.fromConfig(config, client: mockClient);
        expect(service.baseUrl, equals(baseUrl));
        expect(service.apiKey, equals(apiKey));
      });

      test('should use predefined config constants', () {
        expect(ArcServiceConfig.taalTestnet.baseUrl, equals('https://arc-test.taal.com/v1'));
        expect(ArcServiceConfig.taalMainnet.baseUrl, equals('https://arc.taal.com/v1'));
      });

      test('should create custom config', () {
        final config = ArcServiceConfig.custom(
          baseUrl: 'https://custom.arc.com/v1',
          apiKey: 'custom-key',
          defaultCallbackUrl: 'https://callback.com/webhook',
        );
        expect(config.baseUrl, equals('https://custom.arc.com/v1'));
        expect(config.apiKey, equals('custom-key'));
        expect(config.defaultCallbackUrl, equals('https://callback.com/webhook'));
      });
    });

    group('Transaction Operations', () {
      group('submitTransaction', () {
        test('should submit transaction successfully', () async {
          const responseJson = {
            'txid': testTxId,
            'txStatus': 'RECEIVED',
            'message': 'Transaction received',
            'timestamp': 1641234567,
          };

          when(mockClient.post(
            any,
            headers: anyNamed('headers'),
            body: anyNamed('body'),
          )).thenAnswer((_) async => http.Response(
            jsonEncode(responseJson),
            200,
          ));

          final result = await arcService.submitTransaction(testRawTx);

          expect(result.txid, equals(testTxId));
          expect(result.status, equals(ArcTransactionStatus.received));
          expect(result.message, equals('Transaction received'));
          expect(result.timestamp, equals('1641234567'));

          verify(mockClient.post(
            Uri.parse('$baseUrl/tx'),
            headers: argThat(
              containsPair('Authorization', 'Bearer $apiKey'),
              named: 'headers',
            ),
            body: argThat(
              contains('"rawTx":"$testRawTx"'),
              named: 'body',
            ),
          ));
        });

        test('should submit transaction with callback URL', () async {
          const callbackUrl = 'https://callback.com/webhook';
          const responseJson = {
            'txid': testTxId,
            'txStatus': 'QUEUED',
          };

          when(mockClient.post(
            any,
            headers: anyNamed('headers'),
            body: anyNamed('body'),
          )).thenAnswer((_) async => http.Response(
            jsonEncode(responseJson),
            201,
          ));

          final result = await arcService.submitTransaction(
            testRawTx,
            callbackUrl: callbackUrl,
          );

          expect(result.status, equals(ArcTransactionStatus.queued));

          verify(mockClient.post(
            any,
            headers: argThat(
              containsPair('X-CallbackUrl', callbackUrl),
              named: 'headers',
            ),
            body: anyNamed('body'),
          ));
        });

        test('should handle transaction submission error', () async {
          when(mockClient.post(
            any,
            headers: anyNamed('headers'),
            body: anyNamed('body'),
          )).thenAnswer((_) async => http.Response(
            'Transaction rejected: Invalid signature',
            400,
          ));

          expect(
            () => arcService.submitTransaction(testRawTx),
            throwsA(isA<ArcException>().having(
              (e) => e.message,
              'message',
              contains('Failed to submit transaction'),
            )),
          );
        });
      });


      group('getTransaction', () {
        test('should get transaction status successfully', () async {
          const responseJson = {
            'txid': testTxId,
            'txStatus': 'MINED',
            'blockHeight': 123456,
            'blockHash': 'block-hash-123',
            'timestamp': 1641234567,
            'rawTx': testRawTx,
            'merklePath': ['merkle1', 'merkle2'],
            'merkleRoot': 'merkle-root-123',
          };

          when(mockClient.get(
            any,
            headers: anyNamed('headers'),
          )).thenAnswer((_) async => http.Response(
            jsonEncode(responseJson),
            200,
          ));

          final result = await arcService.getTransaction(testTxId);

          expect(result.txid, equals(testTxId));
          expect(result.status, equals(ArcTransactionStatus.mined));
          expect(result.blockHeight, equals(123456));
          expect(result.blockHash, equals('block-hash-123'));
          expect(result.rawTx, equals(testRawTx));
          expect(result.merklePath, equals(['merkle1', 'merkle2']));
          expect(result.merkleRoot, equals('merkle-root-123'));

          verify(mockClient.get(
            Uri.parse('$baseUrl/tx/$testTxId'),
            headers: argThat(
              containsPair('Authorization', 'Bearer $apiKey'),
              named: 'headers',
            ),
          ));
        });

        test('should handle transaction not found', () async {
          when(mockClient.get(
            any,
            headers: anyNamed('headers'),
          )).thenAnswer((_) async => http.Response(
            'Transaction not found',
            404,
          ));

          expect(
            () => arcService.getTransaction(testTxId),
            throwsA(isA<ArcException>().having(
              (e) => e.message,
              'message',
              contains('Failed to get transaction'),
            )),
          );
        });
      });

      group('getRawTransaction', () {
        test('should get raw transaction successfully', () async {
          const responseJson = {
            'rawTx': testRawTx,
          };

          when(mockClient.get(
            any,
            headers: anyNamed('headers'),
          )).thenAnswer((_) async => http.Response(
            jsonEncode(responseJson),
            200,
          ));

          final result = await arcService.getRawTransaction(testTxId);

          expect(result, equals(testRawTx));

          verify(mockClient.get(
            Uri.parse('$baseUrl/tx/$testTxId/raw'),
            headers: anyNamed('headers'),
          ));
        });

        test('should handle missing rawTx field', () async {
          const responseJson = {};

          when(mockClient.get(
            any,
            headers: anyNamed('headers'),
          )).thenAnswer((_) async => http.Response(
            jsonEncode(responseJson),
            200,
          ));

          final result = await arcService.getRawTransaction(testTxId);

          expect(result, equals(''));
        });
      });

      group('submitBatchTransactions', () {
        test('should submit batch transactions successfully', () async {
          const rawTxs = ['tx1', 'tx2', 'tx3'];
          const responseJson = [
            {'txid': 'txid1', 'txStatus': 'RECEIVED'},
            {'txid': 'txid2', 'txStatus': 'QUEUED'},
            {'txid': 'txid3', 'txStatus': 'STORED'},
          ];

          when(mockClient.post(
            any,
            headers: anyNamed('headers'),
            body: anyNamed('body'),
          )).thenAnswer((_) async => http.Response(
            jsonEncode(responseJson),
            200,
          ));

          final results = await arcService.submitBatchTransactions(rawTxs);

          expect(results, hasLength(3));
          expect(results[0].txid, equals('txid1'));
          expect(results[0].status, equals(ArcTransactionStatus.received));
          expect(results[1].txid, equals('txid2'));
          expect(results[1].status, equals(ArcTransactionStatus.queued));
          expect(results[2].txid, equals('txid3'));
          expect(results[2].status, equals(ArcTransactionStatus.stored));

          verify(mockClient.post(
            Uri.parse('$baseUrl/tx/batch'),
            headers: anyNamed('headers'),
            body: argThat(
              contains('"rawTxs":["tx1","tx2","tx3"]'),
              named: 'body',
            ),
          ));
        });

        test('should handle batch submission error', () async {
          when(mockClient.post(
            any,
            headers: anyNamed('headers'),
            body: anyNamed('body'),
          )).thenAnswer((_) async => http.Response(
            'Batch limit exceeded',
            413,
          ));

          expect(
            () => arcService.submitBatchTransactions(['tx1', 'tx2']),
            throwsA(isA<ArcException>().having(
              (e) => e.message,
              'message',
              contains('Failed to submit batch transactions'),
            )),
          );
        });
      });

      group('getBatchTransactions', () {
        test('should get batch transactions successfully', () async {
          const txids = ['txid1', 'txid2'];
          const responseJson = [
            {'txid': 'txid1', 'txStatus': 'MINED', 'blockHeight': 100},
            {'txid': 'txid2', 'txStatus': 'SEEN_ON_NETWORK'},
          ];

          when(mockClient.post(
            any,
            headers: anyNamed('headers'),
            body: anyNamed('body'),
          )).thenAnswer((_) async => http.Response(
            jsonEncode(responseJson),
            200,
          ));

          final results = await arcService.getBatchTransactions(txids);

          expect(results, hasLength(2));
          expect(results[0].txid, equals('txid1'));
          expect(results[0].status, equals(ArcTransactionStatus.mined));
          expect(results[0].blockHeight, equals(100));
          expect(results[1].txid, equals('txid2'));
          expect(results[1].status, equals(ArcTransactionStatus.seenOnNetwork));

          verify(mockClient.post(
            Uri.parse('$baseUrl/tx/batch'),
            headers: anyNamed('headers'),
            body: argThat(
              contains('"txids":["txid1","txid2"]'),
              named: 'body',
            ),
          ));
        });
      });
    });

    group('Merkle Proof Operations', () {
      group('getMerkleProof', () {
        test('should get merkle proof successfully', () async {
          const responseJson = {
            'txid': testTxId,
            'merklePath': ['proof1', 'proof2', 'proof3'],
            'merkleRoot': 'merkle-root-123',
            'blockHeight': 123456,
            'blockHash': 'block-hash-123',
          };

          when(mockClient.get(
            any,
            headers: anyNamed('headers'),
          )).thenAnswer((_) async => http.Response(
            jsonEncode(responseJson),
            200,
          ));

          final result = await arcService.getMerkleProof(testTxId);

          expect(result, isNotNull);
          expect(result!.txid, equals(testTxId));
          expect(result.merklePath, equals(['proof1', 'proof2', 'proof3']));
          expect(result.merkleRoot, equals('merkle-root-123'));
          expect(result.blockHeight, equals(123456));
          expect(result.blockHash, equals('block-hash-123'));

          verify(mockClient.get(
            Uri.parse('$baseUrl/tx/$testTxId/proof'),
            headers: anyNamed('headers'),
          ));
        });

        test('should return null when proof not available', () async {
          when(mockClient.get(
            any,
            headers: anyNamed('headers'),
          )).thenAnswer((_) async => http.Response(
            'Proof not available',
            404,
          ));

          final result = await arcService.getMerkleProof(testTxId);

          expect(result, isNull);
        });

        test('should return null on network error', () async {
          when(mockClient.get(
            any,
            headers: anyNamed('headers'),
          )).thenThrow(const SocketException('Network error'));

          final result = await arcService.getMerkleProof(testTxId);

          expect(result, isNull);
        });
      });

      group('getBatchMerkleProofs', () {
        test('should get batch merkle proofs successfully', () async {
          const txids = ['txid1', 'txid2'];
          const responseJson = [
            {
              'txid': 'txid1',
              'merklePath': ['proof1'],
              'merkleRoot': 'root1',
              'blockHeight': 100,
            },
            {
              'txid': 'txid2',
              'merklePath': ['proof2'],
              'merkleRoot': 'root2',
              'blockHeight': 101,
            },
          ];

          when(mockClient.post(
            any,
            headers: anyNamed('headers'),
            body: anyNamed('body'),
          )).thenAnswer((_) async => http.Response(
            jsonEncode(responseJson),
            200,
          ));

          final results = await arcService.getBatchMerkleProofs(txids);

          expect(results, hasLength(2));
          expect(results[0].txid, equals('txid1'));
          expect(results[0].blockHeight, equals(100));
          expect(results[1].txid, equals('txid2'));
          expect(results[1].blockHeight, equals(101));

          verify(mockClient.post(
            Uri.parse('$baseUrl/tx/proofs'),
            headers: anyNamed('headers'),
            body: argThat(
              contains('"txids":["txid1","txid2"]'),
              named: 'body',
            ),
          ));
        });

        test('should handle batch merkle proof error', () async {
          when(mockClient.post(
            any,
            headers: anyNamed('headers'),
            body: anyNamed('body'),
          )).thenAnswer((_) async => http.Response(
            'Service unavailable',
            503,
          ));

          expect(
            () => arcService.getBatchMerkleProofs(['txid1']),
            throwsA(isA<ArcException>().having(
              (e) => e.message,
              'message',
              contains('Failed to get batch merkle proofs'),
            )),
          );
        });
      });
    });

    group('Policy and Health', () {
      group('getPolicy', () {
        test('should get policy successfully', () async {
          const responseJson = {
            'maxTxSize': 100000000,
            'minFeePerKb': 0.5,
            'standardFeePerKb': 0.5,
            'dataFeePerKb': 0.25,
          };

          when(mockClient.get(
            any,
            headers: anyNamed('headers'),
          )).thenAnswer((_) async => http.Response(
            jsonEncode(responseJson),
            200,
          ));

          final result = await arcService.getPolicy();

          expect(result.maxTxSize, equals(100000000));
          expect(result.minFeePerKb, equals(0.5));
          expect(result.standardFeePerKb, equals(0.5));
          expect(result.dataFeePerKb, equals(0.25));

          verify(mockClient.get(
            Uri.parse('$baseUrl/policy'),
            headers: anyNamed('headers'),
          ));
        });

        test('should use default values for missing policy fields', () async {
          const responseJson = {}; // Empty response

          when(mockClient.get(
            any,
            headers: anyNamed('headers'),
          )).thenAnswer((_) async => http.Response(
            jsonEncode(responseJson),
            200,
          ));

          final result = await arcService.getPolicy();

          expect(result.maxTxSize, equals(100000000));
          expect(result.minFeePerKb, equals(0.5));
          expect(result.standardFeePerKb, equals(0.5));
          expect(result.dataFeePerKb, equals(0.5));
        });

        test('should handle policy error', () async {
          when(mockClient.get(
            any,
            headers: anyNamed('headers'),
          )).thenAnswer((_) async => http.Response(
            'Unauthorized',
            401,
          ));

          expect(
            () => arcService.getPolicy(),
            throwsA(isA<ArcException>().having(
              (e) => e.message,
              'message',
              contains('Failed to get policy'),
            )),
          );
        });
      });

      group('getHealth', () {
        test('should get health status successfully', () async {
          const responseJson = {
            'healthy': true,
            'message': 'Service is operational',
          };

          when(mockClient.get(
            any,
            headers: anyNamed('headers'),
          )).thenAnswer((_) async => http.Response(
            jsonEncode(responseJson),
            200,
          ));

          final result = await arcService.getHealth();

          expect(result.healthy, isTrue);
          expect(result.message, equals('Service is operational'));

          verify(mockClient.get(
            Uri.parse('$baseUrl/health'),
            headers: anyNamed('headers'),
          ));
        });

        test('should handle unhealthy service', () async {
          const responseJson = {
            'healthy': false,
            'message': 'Database connection failed',
          };

          when(mockClient.get(
            any,
            headers: anyNamed('headers'),
          )).thenAnswer((_) async => http.Response(
            jsonEncode(responseJson),
            200,
          ));

          final result = await arcService.getHealth();

          expect(result.healthy, isFalse);
          expect(result.message, equals('Database connection failed'));
        });

        test('should use default values for missing health fields', () async {
          const responseJson = {};

          when(mockClient.get(
            any,
            headers: anyNamed('headers'),
          )).thenAnswer((_) async => http.Response(
            jsonEncode(responseJson),
            200,
          ));

          final result = await arcService.getHealth();

          expect(result.healthy, isFalse);
          expect(result.message, isNull);
        });
      });

      group('estimateFee', () {
        test('should estimate fee correctly', () async {
          const policyJson = {
            'maxTxSize': 100000000,
            'minFeePerKb': 0.5,
            'standardFeePerKb': 1.0,
            'dataFeePerKb': 0.5,
          };

          when(mockClient.get(
            any,
            headers: anyNamed('headers'),
          )).thenAnswer((_) async => http.Response(
            jsonEncode(policyJson),
            200,
          ));

          final fee = await arcService.estimateFee(
            inputCount: 2,
            outputCount: 3,
            dataSize: 100,
          );

          // Expected calculation:
          // Size = 25 + (2 * 148) + (3 * 34) + 100 = 521 bytes = 0.521 KB
          // Fee = 0.521 * 1.0 = 0.521 satoshis, rounded up to 1
          expect(fee, equals(BigInt.from(1)));
        });

        test('should estimate fee with larger transaction', () async {
          const policyJson = {
            'standardFeePerKb': 0.5,
          };

          when(mockClient.get(
            any,
            headers: anyNamed('headers'),
          )).thenAnswer((_) async => http.Response(
            jsonEncode(policyJson),
            200,
          ));

          final fee = await arcService.estimateFee(
            inputCount: 10,
            outputCount: 5,
          );

          // Expected calculation:
          // Size = 25 + (10 * 148) + (5 * 34) = 1675 bytes = 1.675 KB
          // Fee = 1.675 * 0.5 = 0.8375 satoshis, rounded up to 1
          expect(fee, equals(BigInt.from(1)));
        });
      });
    });

    group('Response Models', () {
      group('ArcTransactionStatus', () {
        test('should parse all transaction status values', () {
          final testCases = {
            'UNKNOWN': ArcTransactionStatus.unknown,
            'QUEUED': ArcTransactionStatus.queued,
            'RECEIVED': ArcTransactionStatus.received,
            'STORED': ArcTransactionStatus.stored,
            'ANNOUNCED_TO_NETWORK': ArcTransactionStatus.announcedToNetwork,
            'REQUESTED_BY_NETWORK': ArcTransactionStatus.requestedByNetwork,
            'SENT_TO_NETWORK': ArcTransactionStatus.sentToNetwork,
            'ACCEPTED_BY_NETWORK': ArcTransactionStatus.acceptedByNetwork,
            'SEEN_IN_ORPHAN_MEMPOOL': ArcTransactionStatus.seenInOrphanMempool,
            'SEEN_ON_NETWORK': ArcTransactionStatus.seenOnNetwork,
            'DOUBLE_SPEND_ATTEMPTED': ArcTransactionStatus.doubleSpendAttempted,
            'MINED_IN_STALE_BLOCK': ArcTransactionStatus.minedInStaleBlock,
            'REJECTED': ArcTransactionStatus.rejected,
            'MINED': ArcTransactionStatus.mined,
          };

          for (final entry in testCases.entries) {
            final response = ArcSubmitResponse.fromJson({
              'txid': 'test',
              'txStatus': entry.key,
            });
            expect(response.status, equals(entry.value), reason: 'Failed for ${entry.key}');
          }
        });

        test('should default to unknown for invalid status', () {
          final response = ArcSubmitResponse.fromJson({
            'txid': 'test',
            'txStatus': 'INVALID_STATUS',
          });
          expect(response.status, equals(ArcTransactionStatus.unknown));
        });
      });

      group('ArcSubmitResponse', () {
        test('should parse complete response', () {
          const json = {
            'txid': testTxId,
            'txStatus': 'MINED',
            'message': 'Transaction mined',
            'blockHeight': 123456,
            'blockHash': 'block-hash',
            'timestamp': 1641234567,
            'doubleSpendTxids': ['txid1', 'txid2'],
          };

          final response = ArcSubmitResponse.fromJson(json);

          expect(response.txid, equals(testTxId));
          expect(response.status, equals(ArcTransactionStatus.mined));
          expect(response.message, equals('Transaction mined'));
          expect(response.blockHeight, equals(123456));
          expect(response.blockHash, equals('block-hash'));
          expect(response.timestamp, equals('1641234567'));
          expect(response.doubleSpendTxids, equals(['txid1', 'txid2']));
        });

        test('should handle minimal response', () {
          const json = {
            'txid': testTxId,
          };

          final response = ArcSubmitResponse.fromJson(json);

          expect(response.txid, equals(testTxId));
          expect(response.status, equals(ArcTransactionStatus.unknown));
          expect(response.message, isNull);
          expect(response.blockHeight, isNull);
          expect(response.doubleSpendTxids, isNull);
        });
      });

      group('ArcMerkleProofResponse', () {
        test('should parse complete merkle proof response', () {
          const json = {
            'txid': testTxId,
            'merklePath': ['proof1', 'proof2'],
            'merkleRoot': 'root123',
            'blockHeight': 123456,
            'blockHash': 'hash123',
          };

          final response = ArcMerkleProofResponse.fromJson(json);

          expect(response.txid, equals(testTxId));
          expect(response.merklePath, equals(['proof1', 'proof2']));
          expect(response.merkleRoot, equals('root123'));
          expect(response.blockHeight, equals(123456));
          expect(response.blockHash, equals('hash123'));
        });

        test('should handle minimal merkle proof response', () {
          const Map<String, dynamic> json = {};

          final response = ArcMerkleProofResponse.fromJson(json);

          expect(response.txid, equals(''));
          expect(response.merklePath, isEmpty);
          expect(response.merkleRoot, equals(''));
          expect(response.blockHeight, equals(0));
          expect(response.blockHash, isNull);
        });
      });
    });

    group('Error Handling', () {
      test('should handle network errors gracefully', () async {
        when(mockClient.get(
          any,
          headers: anyNamed('headers'),
        )).thenThrow(const SocketException('No Internet connection'));

        expect(
          () => arcService.getTransaction(testTxId),
          throwsA(isA<SocketException>()),
        );
      });

      test('should handle timeout errors', () async {
        when(mockClient.post(
          any,
          headers: anyNamed('headers'),
          body: anyNamed('body'),
        )).thenThrow(TimeoutException('Request timeout', const Duration(seconds: 30)));

        expect(
          () => arcService.submitTransaction(testRawTx),
          throwsA(isA<TimeoutException>()),
        );
      });

      test('should handle invalid JSON response', () async {
        when(mockClient.get(
          any,
          headers: anyNamed('headers'),
        )).thenAnswer((_) async => http.Response(
          'Invalid JSON{',
          200,
        ));

        expect(
          () => arcService.getTransaction(testTxId),
          throwsA(isA<FormatException>()),
        );
      });

      test('should handle authentication errors', () async {
        when(mockClient.get(
          any,
          headers: anyNamed('headers'),
        )).thenAnswer((_) async => http.Response(
          'Unauthorized: Invalid API key',
          401,
        ));

        expect(
          () => arcService.getPolicy(),
          throwsA(isA<ArcException>().having(
            (e) => e.message,
            'message',
            contains('Unauthorized'),
          )),
        );
      });
    });

    group('Authentication', () {
      test('should include Authorization header when API key provided', () async {
        when(mockClient.get(
          any,
          headers: anyNamed('headers'),
        )).thenAnswer((_) async => http.Response('{"healthy": true}', 200));

        await arcService.getHealth();

        verify(mockClient.get(
          any,
          headers: argThat(
            containsPair('Authorization', 'Bearer $apiKey'),
            named: 'headers',
          ),
        ));
      });

      test('should not include Authorization header when no API key', () async {
        final serviceWithoutKey = ArcService(
          baseUrl: baseUrl,
          client: mockClient,
        );

        when(mockClient.get(
          any,
          headers: anyNamed('headers'),
        )).thenAnswer((_) async => http.Response('{"healthy": true}', 200));

        await serviceWithoutKey.getHealth();

        verify(mockClient.get(
          any,
          headers: argThat(
            isNot(contains('Authorization')),
            named: 'headers',
          ),
        ));
      });

      test('should always include standard headers', () async {
        when(mockClient.get(
          any,
          headers: anyNamed('headers'),
        )).thenAnswer((_) async => http.Response('{"healthy": true}', 200));

        await arcService.getHealth();

        verify(mockClient.get(
          any,
          headers: argThat(
            allOf([
              containsPair('Content-Type', 'application/json'),
              containsPair('Accept', 'application/json'),
            ]),
            named: 'headers',
          ),
        ));
      });
    });

    group('Resource Management', () {
      test('should dispose HTTP client', () {
        arcService.dispose();
        verify(mockClient.close());
      });
    });
  });
}
