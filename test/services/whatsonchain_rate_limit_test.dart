import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:libspiffy/libspiffy.dart';
import 'package:test/test.dart';

/// An import fetches a transaction's parents in parallel; the requests it
/// makes together still keep to the data source's rate limit.
void main() {
  test('requests made at the same time keep to the limit a second', () async {
    final sent = <DateTime>[];
    final source = WhatsOnChainDataSource(
      networkType: 'main',
      requestsPerSecondLimit: 3,
      client: MockClient((request) async {
        sent.add(DateTime.now());
        return http.Response('00', 200);
      }),
    );

    await Future.wait([for (var i = 0; i < 7; i++) source.getRawTransaction('ab' * 32)]);

    expect(sent, hasLength(7));
    for (var i = 0; i + 3 < sent.length; i++) {
      expect(sent[i + 3].difference(sent[i]).inMilliseconds, greaterThanOrEqualTo(1000),
          reason: 'request ${i + 4} came within a second of request ${i + 1}');
    }
  });
}
