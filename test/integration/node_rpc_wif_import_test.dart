import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dactor/dactor.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:http/http.dart' as http;
import 'package:isar/isar.dart';
import 'package:libspiffy/libspiffy.dart';
import 'package:libspiffy/internals.dart';
import 'package:libspiffy/src/storage/isar_wallet_storage.dart';
import 'package:test/test.dart';

import 'isar_test_helper.dart';

/// Full WIF import integration test against a live regtest node.
///
/// This test exercises the complete ImportActor pipeline:
///   ImportActor → AddressDiscoveryService → TransactionImportService
/// using a real NodeRpcDataSource against the regtest node.
///
/// Prerequisites:
///   - localnet running (docker compose up -d)
///   - Node RPC at 192.168.50.241:18332
///
/// Run:
///   dart test test/integration/node_rpc_wif_import_test.dart --timeout 60s

const _rpcUrl = 'http://192.168.50.241:18332';
const _rpcUser = 'bitcoin';
const _rpcPassword = 'bitcoin';

// The production WIF that failed in-app
const _testWif = 'cTQt7QmW5BnbjaHRGgf4X1H51EXTW8sT6UVSS6YsvBNDQDtKN51c';
const _expectedAddr = 'micocA8ttajyG1NihapQmxXu8FqWbKSJ79';

Future<dynamic> _bitcoinRpc(String method,
    [List<dynamic> params = const []]) async {
  final client = http.Client();
  try {
    final auth = base64Encode(utf8.encode('$_rpcUser:$_rpcPassword'));
    final resp = await client.post(
      Uri.parse(_rpcUrl),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Basic $auth',
      },
      body: json.encode({
        'jsonrpc': '2.0',
        'method': method,
        'params': params,
        'id': 1,
      }),
    );
    final result = json.decode(resp.body) as Map<String, dynamic>;
    if (result['error'] != null) throw Exception('RPC error: ${result['error']}');
    return result['result'];
  } finally {
    client.close();
  }
}

Future<bool> _isNodeReachable() async {
  try {
    await _bitcoinRpc('getblockcount');
    return true;
  } catch (_) {
    return false;
  }
}

class TestContext {
  final Directory testDir;
  final LocalActorSystem actorSystem;
  final Isar isar;
  final LibSpiffyActorSystem libspiffy;
  final IsarWalletStorage storage;
  final List<WalletEvent> capturedEvents = [];

  TestContext({
    required this.testDir,
    required this.actorSystem,
    required this.isar,
    required this.libspiffy,
    required this.storage,
  });

  Future<void> dispose() async {
    await libspiffy.shutdown();
    await isar.close(deleteFromDisk: true);
    testDir.deleteSync(recursive: true);
  }
}

Future<TestContext> setupTestContext() async {
  await ensureIsarInitialized();

  final testDir = Directory.systemTemp.createTempSync('wif-import-regtest-');
  final actorSystem = LocalActorSystem(ActorSystemConfig());

  final isar = await Isar.open(
    LibSpiffySchemas.allSchemas,
    directory: testDir.path,
    name: 'test_wif_import_${DateTime.now().millisecondsSinceEpoch}',
  );

  final dataSource = NodeRpcDataSource(
    rpcUrl: _rpcUrl,
    rpcUser: _rpcUser,
    rpcPassword: _rpcPassword,
  );

  final libspiffy = LibSpiffyActorSystem();
  await libspiffy.initialize(
    actorSystem: actorSystem,
    isar: isar,
    dataDirectory: testDir.path,
    blockchainDataSource: dataSource,
    enableP2P: false,
  );

  final storage = libspiffy.walletStorage as IsarWalletStorage;

  return TestContext(
    testDir: testDir,
    actorSystem: actorSystem,
    isar: isar,
    libspiffy: libspiffy,
    storage: storage,
  );
}

void main() {
  test('WIF import via ImportActor against regtest node', () async {
    if (!await _isNodeReachable()) {
      print('⚠️  Regtest node not reachable at $_rpcUrl — skipping');
      return;
    }

    print('\n=== WIF Import Integration Test (regtest) ===\n');

    final context = await setupTestContext();
    final walletId = 'regtest-wif-${DateTime.now().millisecondsSinceEpoch}';

    try {
      // Subscribe to wallet events
      final eventSub = context.libspiffy.subscribeToWalletEvents(walletId).listen((event) {
        context.capturedEvents.add(event);
        print('📢 ${event.runtimeType}');
      });

      // Step 1: Verify address derivation
      final pk = dartsv.SVPrivateKey.fromWIF(_testWif);
      final derivedAddr = dartsv.Address.fromPublicKey(
        pk.publicKey,
        dartsv.NetworkType.TEST,
      ).toBase58();
      print('Step 1 — Address: $derivedAddr');
      expect(derivedAddr, equals(_expectedAddr));

      // Step 2: Trigger WIF import through LibSpiffy
      print('Step 2 — Starting importWalletFromWif...');
      context.libspiffy.importWalletFromWif(
        walletId: walletId,
        wif: _testWif,
        walletName: 'Regtest WIF Test',
        networkType: 'regtest',
      );

      // Step 3: Wait for import to complete
      print('Step 3 — Waiting for import completion (max 30s)...');
      final completer = Completer<WalletImportCompletedEvent>();
      final completionSub = context.libspiffy.subscribeToWalletEvents(walletId).listen((event) {
        if (event is WalletImportCompletedEvent && !completer.isCompleted) {
          completer.complete(event);
        }
      });

      final completedEvent = await completer.future.timeout(
        const Duration(seconds: 30),
        onTimeout: () {
          print('❌ TIMEOUT — events received so far:');
          for (final e in context.capturedEvents) {
            print('   ${e.runtimeType}');
          }
          throw TimeoutException('Import did not complete within 30s');
        },
      );
      await completionSub.cancel();
      await eventSub.cancel();

      print('   ✅ Import completed!');
      print('   Addresses: ${completedEvent.totalAddresses}');
      print('   Transactions: ${completedEvent.totalTransactions}');
      print('   UTXOs: ${completedEvent.importedUtxos.length}');

      // Step 4: Verify wallet created
      print('Step 4 — Verifying wallet...');
      final wallet = await context.storage.getWallet(walletId);
      expect(wallet, isNotNull, reason: 'Wallet should exist');
      print('   ✅ Wallet created: ${wallet!['name']}');

      // Step 5: Verify address discovered
      print('Step 5 — Verifying addresses...');
      final addresses = await context.storage.getWalletAddresses(walletId);
      expect(addresses, isNotEmpty);
      expect(addresses, contains(_expectedAddr));
      print('   ✅ Address discovered: ${addresses.join(", ")}');

      // Step 6: Verify transactions imported
      print('Step 6 — Verifying transactions...');
      final txHistory = await context.storage.getTransactionHistory(walletId);
      print('   Transactions: ${txHistory.length}');
      for (final tx in txHistory) {
        print('   ${tx.txid} (block ${tx.blockHeight})');
      }
      expect(txHistory, isNotEmpty,
          reason: 'Should have imported at least 1 transaction');

      // Step 7: Verify UTXOs
      print('Step 7 — Verifying UTXOs...');
      final utxos = await context.storage.getUTXOs(walletId);
      print('   UTXOs: ${utxos.length}');
      for (final u in utxos) {
        print('   ${u.txid}:${u.vout} = ${u.value.getValue()} sats (${u.status})');
      }
      expect(utxos, isNotEmpty, reason: 'Should have at least 1 UTXO');

      print('\n✅ Full WIF import integration test PASSED!\n');
    } finally {
      await context.dispose();
    }
  }, timeout: Timeout(Duration(seconds: 60)));
}
