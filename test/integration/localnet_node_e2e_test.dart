/// A libspiffy node on the real BSV regtest network (see
/// localnet_harness.dart): it syncs the node's headers over P2P, follows
/// the blocks mined after, and goes on following them across a restart.
///
/// Tagged `localnet` and skipped by default; run with
///   dart test -P localnet test/integration/localnet_node_e2e_test.dart
@Tags(['localnet'])
library;

import 'package:test/test.dart';

import 'package:libspiffy/libspiffy.dart';

import 'isar_test_helper.dart';
import 'localnet_harness.dart';

void main() {
  String? unavailable;
  final timing = ChannelTiming(
    settlementMargin: Duration(seconds: 30),
    minimumLifetime: Duration(minutes: 2),
  );

  setUpAll(() async {
    unavailable = await localnetProblem();
    if (unavailable != null) return;
    await ensureIsarInitialized();
  });

  setUp(() {
    if (unavailable != null) markTestSkipped(unavailable!);
  });

  // Bead libspiffy-3pyc: a node restarted at the tip asked for headers,
  // was answered with none, and never asked again.
  test('a node syncs the headers, follows each new block, and still follows them after a restart at the tip',
      () async {
    if (unavailable != null) return;
    final node = await LocalnetNode.start('follower', timing);
    addTearDown(node.stop);

    await node.headersAt(await rpc('getblockcount') as int);
    await node.headersAt(await mine(), timeout: const Duration(seconds: 20));

    await node.restart();
    await Future<void>.delayed(const Duration(seconds: 2));
    await node.headersAt(await mine(), timeout: const Duration(seconds: 20));
    await node.headersAt(await mine(), timeout: const Duration(seconds: 20));
  }, timeout: const Timeout(Duration(minutes: 3)));
}
