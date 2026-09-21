import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:mockito/mockito.dart';
import 'package:mockito/annotations.dart';
import 'package:http/http.dart' as http;

import 'package:libspiffy/src/services/arc_service.dart';
import 'package:libspiffy/src/services/arc_service_config.dart';
import 'package:libspiffy/internals.dart';

import 'arc_service_test.mocks.dart';
import '../spv/testnet_proof_fixture.dart';

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
        expect(ArcServiceConfig.taalTestnet().baseUrl, equals('https://arc-test.taal.com/v1'));
        expect(ArcServiceConfig.taalMainnet().baseUrl, equals('https://arc.taal.com/v1'));
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
            Uri.parse('$baseUrl/txs'),
            headers: anyNamed('headers'),
            body: argThat(
              equals('[{"rawTx":"tx1"},{"rawTx":"tx2"},{"rawTx":"tx3"}]'),
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
          when(mockClient.get(
            any,
            headers: anyNamed('headers'),
          )).thenAnswer((invocation) async {
            final uri = invocation.positionalArguments.first as Uri;
            return uri.path.endsWith('txid1')
                ? http.Response(jsonEncode({'txid': 'txid1', 'txStatus': 'MINED', 'blockHeight': 100}), 200)
                : http.Response(jsonEncode({'txid': 'txid2', 'txStatus': 'SEEN_ON_NETWORK'}), 200);
          });

          final results = await arcService.getBatchTransactions(['txid1', 'txid2']);

          expect(results, hasLength(2));
          expect(results[0].txid, equals('txid1'));
          expect(results[0].status, equals(ArcTransactionStatus.mined));
          expect(results[0].blockHeight, equals(100));
          expect(results[1].txid, equals('txid2'));
          expect(results[1].status, equals(ArcTransactionStatus.seenOnNetwork));

          // ARC has no batch status endpoint: one GET /tx/{txid} each.
          verify(mockClient.get(Uri.parse('$baseUrl/tx/txid1'), headers: anyNamed('headers')));
          verify(mockClient.get(Uri.parse('$baseUrl/tx/txid2'), headers: anyNamed('headers')));
          verifyNever(mockClient.post(any, headers: anyNamed('headers'), body: anyNamed('body')));
        });
      });
    });

    group('Merkle Proof Operations', () {
      group('getMerkleProof', () {
        test('should get merkle proof successfully', () async {
          final responseJson = {
            'txid': kFixtureTxid,
            'txStatus': 'MINED',
            'merklePath': fixtureBumpHex(),
            'blockHeight': kFixtureHeight,
            'blockHash': kFixtureBlockHash,
          };

          when(mockClient.get(
            any,
            headers: anyNamed('headers'),
          )).thenAnswer((_) async => http.Response(
            jsonEncode(responseJson),
            200,
          ));

          final result = await arcService.getMerkleProof(kFixtureTxid);

          expect(result, isNotNull);
          expect(result!.txid, equals(kFixtureTxid));
          expect(result.merklePath, equals([fixtureBumpHex()]));
          expect(result.merkleRoot, equals(fixtureHeader().merkleRoot.toString()));
          expect(result.blockHeight, equals(kFixtureHeight));
          expect(result.blockHash, equals(kFixtureBlockHash));

          verify(mockClient.get(
            Uri.parse('$baseUrl/tx/$kFixtureTxid'),
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
        test('should collect proofs of mined transactions via GET /tx/{txid}', () async {
          when(mockClient.get(
            any,
            headers: anyNamed('headers'),
          )).thenAnswer((invocation) async {
            final uri = invocation.positionalArguments.first as Uri;
            if (uri.path.endsWith(kFixtureTxid)) {
              return http.Response(
                  jsonEncode({
                    'txid': kFixtureTxid,
                    'txStatus': 'MINED',
                    'blockHeight': kFixtureHeight,
                    'merklePath': fixtureBumpHex(),
                  }),
                  200);
            }
            return http.Response('{"txid":"x","txStatus":"SEEN_ON_NETWORK"}', 200);
          });

          final results = await arcService.getBatchMerkleProofs([kFixtureTxid, 'txid2']);

          expect(results, hasLength(1));
          expect(results[0].txid, equals(kFixtureTxid));
          expect(results[0].blockHeight, equals(kFixtureHeight));
        });

        test('should omit transactions whose status request fails', () async {
          when(mockClient.get(
            any,
            headers: anyNamed('headers'),
          )).thenAnswer((_) async => http.Response(
            'Service unavailable',
            503,
          ));

          expect(await arcService.getBatchMerkleProofs(['txid1']), isEmpty);
        });
      });
    });

    group('Policy and Health', () {
      group('getPolicy', () {
        test('should get policy successfully', () async {
          const responseJson = {
            'timestamp': '2026-09-14T08:00:00Z',
            'policy': {
              'maxscriptsizepolicy': 500000,
              'maxtxsigopscountspolicy': 4294967295,
              'maxtxsizepolicy': 100000000,
              'miningFee': {'satoshis': 1, 'bytes': 2000},
              'standardFormatSupported': true,
            },
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
          expect(result.miningFee.satoshisPerKb, equals(0.5));

          verify(mockClient.get(
            Uri.parse('$baseUrl/policy'),
            headers: anyNamed('headers'),
          ));
        });

        test('should reject a policy without miningFee', () async {
          const responseJson = {}; // Empty response

          when(mockClient.get(
            any,
            headers: anyNamed('headers'),
          )).thenAnswer((_) async => http.Response(
            jsonEncode(responseJson),
            200,
          ));

          await expectLater(arcService.getPolicy(), throwsA(isA<ArcException>()));
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
        test('ey2: reads the competing transactions ARC names competingTxs', () {
          final response = ArcSubmitResponse.fromJson({
            'txid': testTxId,
            'txStatus': 'DOUBLE_SPEND_ATTEMPTED',
            'competingTxs': ['c1'],
          });
          // Old code read only 'doubleSpendTxids': null.
          expect(response.doubleSpendTxids, ['c1']);
        });

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

  // Audit finding SPV-11 (timeouts): every ARC request used to await the
  // http.Client with no upper bound, so a stalled connection hung the caller
  // (and the broadcast queue behind it) forever.
  group('ArcService request timeouts (SPV-11)', () {
    late _NeverRespondingClient hangingClient;
    late ArcService arcService;

    setUp(() {
      hangingClient = _NeverRespondingClient();
      arcService = ArcService(
        baseUrl: 'https://arc-test.taal.com/v1',
        apiKey: 'test-api-key',
        client: hangingClient,
        requestTimeout: const Duration(milliseconds: 200),
      );
    });

    test('submitTransaction fails with TimeoutException when the server never answers',
        () async {
      final stopwatch = Stopwatch()..start();
      await expectLater(
        arcService.submitTransaction('00').timeout(const Duration(seconds: 3)),
        throwsA(isA<TimeoutException>()
            .having((e) => e.duration, 'duration',
                const Duration(milliseconds: 200))),
      );
      stopwatch.stop();
      expect(hangingClient.requests, equals(1));
      expect(stopwatch.elapsedMilliseconds, lessThan(1000));
    });

    test('getTransaction fails with TimeoutException when the server never answers',
        () async {
      final stopwatch = Stopwatch()..start();
      await expectLater(
        arcService.getTransaction('a' * 64).timeout(const Duration(seconds: 3)),
        throwsA(isA<TimeoutException>()
            .having((e) => e.duration, 'duration',
                const Duration(milliseconds: 200))),
      );
      stopwatch.stop();
      expect(hangingClient.requests, equals(1));
      expect(stopwatch.elapsedMilliseconds, lessThan(1000));
    });

    test('ArcService.fromConfig carries ArcServiceConfig.requestTimeout', () {
      final service = ArcService.fromConfig(
        const ArcServiceConfig(
          baseUrl: 'https://arc-test.taal.com/v1',
          requestTimeout: Duration(seconds: 7),
        ),
        client: hangingClient,
      );
      expect(service.requestTimeout, equals(const Duration(seconds: 7)));
      expect(
        ArcService(baseUrl: 'https://arc-test.taal.com/v1', client: hangingClient)
            .requestTimeout,
        equals(const Duration(seconds: 30)),
      );
    });
  });

  // Audit finding SPV-11 (remainder, libspiffy-98l). The client called
  // `/tx/{txid}/proof`, `/tx/proofs` and `/tx/batch`, none of which exist,
  // and parsed a flat `standardFeePerKb` policy that ARC never returns.
  //
  // Shapes below are ARC's OpenAPI spec (bitcoin-sv/arc, pkg/api/arc.yaml):
  //   GET  /v1/tx/{txid} -> TransactionStatus {timestamp, txid, txStatus,
  //        blockHash, blockHeight, merklePath (BRC-74 hex), extraInfo,
  //        competingTxs}; 404 when unknown.
  //   GET  /v1/policy    -> {timestamp, policy: {maxscriptsizepolicy,
  //        maxtxsigopscountspolicy, maxtxsizepolicy,
  //        miningFee: {satoshis, bytes}, standardFormatSupported}}
  //   POST /v1/txs       -> body: JSON array of {rawTx}
  group('ArcService against the real ARC API shapes (SPV-11)', () {
    const baseUrl = 'https://arc-test.taal.com/v1';
    late MockClient client;
    late ArcService arc;
    late List<Uri> requested;

    /// Serves [routes] (path -> body) with 200 and everything else with 404,
    /// the way ARC does.
    void serveGet(Map<String, Object> routes) {
      when(client.get(any, headers: anyNamed('headers'))).thenAnswer((invocation) async {
        final uri = invocation.positionalArguments.first as Uri;
        requested.add(uri);
        final body = routes[uri.toString()];
        if (body == null) return http.Response('{"status":404,"title":"Not found"}', 404);
        return http.Response(jsonEncode(body), 200);
      });
    }

    const policyBody = {
      'timestamp': '2026-09-14T08:00:00Z',
      'policy': {
        'maxscriptsizepolicy': 500000,
        'maxtxsigopscountspolicy': 4294967295,
        'maxtxsizepolicy': 10000000,
        'miningFee': {'satoshis': 50, 'bytes': 1000},
        'standardFormatSupported': true,
      },
    };

    setUp(() {
      client = MockClient();
      arc = ArcService(baseUrl: baseUrl, client: client);
      requested = [];
    });

    test('getMerkleProof returns the BRC-74 merklePath from GET /tx/{txid}', () async {
      serveGet({
        '$baseUrl/tx/$kFixtureTxid': {
          'timestamp': '2026-09-14T08:00:00Z',
          'txid': kFixtureTxid,
          'txStatus': 'MINED',
          'blockHash': kFixtureBlockHash,
          'blockHeight': kFixtureHeight,
          'merklePath': fixtureBumpHex(),
          'extraInfo': '',
          'competingTxs': null,
        },
      });

      final proof = await arc.getMerkleProof(kFixtureTxid);

      expect(requested.map((u) => u.path), everyElement('/v1/tx/$kFixtureTxid'));
      expect(proof, isNotNull, reason: 'a MINED transaction has a proof');
      expect(proof!.merklePath, equals([fixtureBumpHex()]));
      expect(proof.blockHeight, equals(kFixtureHeight));
      expect(proof.blockHash, equals(kFixtureBlockHash));
      // Root computed from the BUMP, equal to the real header's root.
      expect(proof.merkleRoot, equals(fixtureHeader().merkleRoot.toString()));
    });

    test('getMerkleProof is null for a transaction that is not mined yet', () async {
      serveGet({
        '$baseUrl/tx/$kFixtureTxid': {
          'timestamp': '2026-09-14T08:00:00Z',
          'txid': kFixtureTxid,
          'txStatus': 'SEEN_ON_NETWORK',
        },
      });
      expect(await arc.getMerkleProof(kFixtureTxid), isNull);
    });

    test('getBatchMerkleProofs uses GET /tx/{txid} per transaction', () async {
      serveGet({
        '$baseUrl/tx/$kFixtureTxid': {
          'txid': kFixtureTxid,
          'txStatus': 'MINED',
          'blockHash': kFixtureBlockHash,
          'blockHeight': kFixtureHeight,
          'merklePath': fixtureBumpHex(),
        },
      });
      final proofs = await arc.getBatchMerkleProofs([kFixtureTxid, 'b' * 64]);
      expect(proofs.map((p) => p.txid), equals([kFixtureTxid]));
      verifyNever(client.post(any, headers: anyNamed('headers'), body: anyNamed('body')));
    });

    test('policy parsing takes the fee from policy.miningFee', () async {
      serveGet({'$baseUrl/policy': policyBody});

      final policy = await arc.getPolicy();

      expect(policy.miningFee.satoshisPerKb, equals(50.0));
      expect(policy.maxTxSize, equals(10000000));
      expect(policy.miningFee.satoshis, equals(50));
      expect(policy.miningFee.bytes, equals(1000));
      expect(policy.maxScriptSize, equals(500000));
      expect(policy.maxTxSigopsCount, equals(4294967295));
      expect(policy.standardFormatSupported, isTrue);
      expect(policy.timestamp, equals('2026-09-14T08:00:00Z'));
    });

    test('a policy without miningFee is an error, not a silent default', () async {
      serveGet({
        '$baseUrl/policy': {'timestamp': 'x', 'policy': {'maxtxsizepolicy': 1}},
      });
      await expectLater(arc.getPolicy(), throwsA(isA<ArcException>()));
    });

    test('submitBatchTransactions posts a JSON array of {rawTx} to /txs', () async {
      when(client.post(any, headers: anyNamed('headers'), body: anyNamed('body')))
          .thenAnswer((_) async => http.Response(
              jsonEncode([
                {'txid': 't1', 'txStatus': 'SEEN_ON_NETWORK'},
                {'txid': 't2', 'txStatus': 'STORED'},
              ]),
              200));

      final results = await arc.submitBatchTransactions(['aa', 'bb']);

      expect(results.map((r) => r.status),
          equals([ArcTransactionStatus.seenOnNetwork, ArcTransactionStatus.stored]));
      final captured = verify(client.post(captureAny,
              headers: anyNamed('headers'), body: captureAnyNamed('body')))
          .captured;
      expect((captured[0] as Uri).toString(), equals('$baseUrl/txs'));
      expect(jsonDecode(captured[1] as String), equals([
        {'rawTx': 'aa'},
        {'rawTx': 'bb'},
      ]));
    });
  });
}

/// An [http.Client] whose requests are accepted and then never complete,
/// like a TCP connection that stalls after the request is written.
class _NeverRespondingClient extends http.BaseClient {
  int requests = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    requests++;
    return Completer<http.StreamedResponse>().future;
  }
}
