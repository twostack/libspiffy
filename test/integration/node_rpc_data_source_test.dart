import 'dart:convert';
import 'dart:io';

import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:http/http.dart' as http;
import 'package:libspiffy/libspiffy.dart';
import 'package:libspiffy/src/utils/tsc_converter.dart';
import 'package:test/test.dart';

/// Integration tests for NodeRpcDataSource against a live regtest node.
///
/// Prerequisites:
///   - localnet running: docker compose up -d (from ../localnet)
///   - Node RPC at localhost:18332, user/pass: bitcoin/bitcoin
///
/// Run:
///   dart test test/integration/node_rpc_data_source_test.dart

const _rpcUrl = 'http://192.168.50.241:18332';
const _rpcUser = 'bitcoin';
const _rpcPassword = 'bitcoin';

/// Direct RPC call helper (bypasses NodeRpcDataSource for test setup).
Future<dynamic> _bitcoinRpc(String method,
    [List<dynamic> params = const []]) async {
  final client = http.Client();
  try {
    final auth = base64Encode(utf8.encode('$_rpcUser:$_rpcPassword'));
    final response = await client.post(
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
    final result = json.decode(response.body) as Map<String, dynamic>;
    if (result['error'] != null) {
      throw Exception('RPC error: ${result['error']}');
    }
    return result['result'];
  } finally {
    client.close();
  }
}

/// Check that the regtest node is reachable.
Future<bool> _isNodeReachable() async {
  try {
    await _bitcoinRpc('getblockcount');
    return true;
  } catch (_) {
    return false;
  }
}

void main() {
  late NodeRpcDataSource dataSource;

  setUpAll(() async {
    if (!await _isNodeReachable()) {
      print('⚠️  Regtest node not reachable at $_rpcUrl — skipping tests');
      return;
    }
  });

  setUp(() {
    dataSource = NodeRpcDataSource(
      rpcUrl: _rpcUrl,
      rpcUser: _rpcUser,
      rpcPassword: _rpcPassword,
    );
  });

  group('NodeRpcDataSource basics', () {
    test('getCurrentBlockHeight returns positive value', () async {
      if (!await _isNodeReachable()) return;

      final height = await dataSource.getCurrentBlockHeight();
      expect(height, greaterThan(0));
      print('Block height: $height');
    });

    test('networkType is regtest', () {
      expect(dataSource.networkType, equals('regtest'));
    });
  });

  group('WIF import flow — end-to-end', () {
    late String miningAddr;
    late String targetAddr;
    late String targetWif;
    late String sendTxid;

    setUpAll(() async {
      if (!await _isNodeReachable()) return;

      // 1. Create a mining address and mine mature coins
      miningAddr = await _bitcoinRpc('getnewaddress') as String;
      print('Mining address: $miningAddr');

      await _bitcoinRpc('generatetoaddress', [101, miningAddr]);
      print('Mined 101 blocks to $miningAddr');

      // 2. Create target address and fund with a normal (non-coinbase) tx
      targetAddr = await _bitcoinRpc('getnewaddress') as String;
      print('Target address: $targetAddr');

      sendTxid = await _bitcoinRpc('sendtoaddress', [targetAddr, 1.0]) as String;
      print('Sent 1.0 BSV to $targetAddr, txid: $sendTxid');

      // 3. Mine 1 block to confirm
      await _bitcoinRpc('generatetoaddress', [1, miningAddr]);
      print('Mined 1 confirmation block');

      // 4. Get WIF
      targetWif = await _bitcoinRpc('dumpprivkey', [targetAddr]) as String;
      print('Target WIF: $targetWif');
    });

    test('listunspent sees the funded UTXO', () async {
      if (!await _isNodeReachable()) return;

      // Sanity: confirm node sees the UTXO via raw RPC
      final utxos = await _bitcoinRpc(
          'listunspent', [0, 9999999, [targetAddr]]) as List;
      print('Raw RPC listunspent: ${json.encode(utxos)}');
      expect(utxos, isNotEmpty, reason: 'Node should see UTXO for $targetAddr');
    });

    test('address derived from WIF matches node address', () async {
      if (!await _isNodeReachable()) return;

      // Derive address the same way ImportActor does
      final privateKey = dartsv.SVPrivateKey.fromWIF(targetWif);
      final derivedAddr = dartsv.Address.fromPublicKey(
        privateKey.publicKey,
        dartsv.NetworkType.TEST, // ImportActor uses TEST for regtest
      ).toBase58();

      print('Node address:    $targetAddr');
      print('Derived address: $derivedAddr');

      expect(derivedAddr, equals(targetAddr),
          reason: 'Address derived from WIF must match node address');
    });

    test('listtransactions raw RPC returns the target address tx', () async {
      if (!await _isNodeReachable()) return;

      // Check what listtransactions actually returns for filtering
      final txList =
          await _bitcoinRpc('listtransactions', ['*', 9999, 0, true]) as List;

      final matching =
          txList.where((tx) => tx['address'] == targetAddr).toList();
      print('listtransactions entries matching $targetAddr: ${matching.length}');
      for (final tx in matching) {
        print('  txid=${tx['txid']} category=${tx['category']} '
            'amount=${tx['amount']} confirmations=${tx['confirmations']}');
      }

      expect(matching, isNotEmpty,
          reason: 'listtransactions should contain entry for $targetAddr');
    });

    test('getTransactionHistory returns funded tx', () async {
      if (!await _isNodeReachable()) return;

      final history = await dataSource.getTransactionHistory(targetAddr);
      print('getTransactionHistory returned ${history.length} transactions');
      for (final tx in history) {
        print('  txid=${tx.txid} blockHeight=${tx.blockHeight}');
      }

      expect(history, isNotEmpty,
          reason: 'getTransactionHistory should find the funded tx');
      expect(history.any((tx) => tx.txid == sendTxid), isTrue,
          reason: 'Should contain the sendtoaddress txid');
    });

    test('getUtxos returns funded UTXO', () async {
      if (!await _isNodeReachable()) return;

      final utxos = await dataSource.getUtxos(targetAddr);
      print('getUtxos returned ${utxos.length} UTXOs');
      for (final u in utxos) {
        print('  txid=${u.txid} vout=${u.vout} value=${u.value} sats');
      }

      expect(utxos, isNotEmpty);
      expect(utxos.first.value, equals(100000000),
          reason: '1.0 BSV = 100000000 satoshis');
    });

    test('getRawTransaction returns hex for funded tx', () async {
      if (!await _isNodeReachable()) return;

      final rawHex = await dataSource.getRawTransaction(sendTxid);
      print('getRawTransaction: ${rawHex.length} hex chars');

      expect(rawHex, isNotEmpty);
      // Verify it parses
      final tx = dartsv.Transaction.fromHex(rawHex);
      expect(tx.id, equals(sendTxid));
    });

    test('getMerkleProof returns valid proof for funded tx', () async {
      if (!await _isNodeReachable()) return;

      final proof = await dataSource.getMerkleProof(sendTxid);
      print('getMerkleProof:');
      print('  blockHeight=${proof.blockHeight}');
      print('  merkleRoot=${proof.merkleRoot}');
      print('  index=${proof.index}');
      print('  nodes=${proof.nodes.length} siblings');
      for (var i = 0; i < proof.nodes.length; i++) {
        print('    [$i] ${proof.nodes[i]}');
      }

      expect(proof.blockHeight, greaterThan(0));
      expect(proof.nodes, isNotEmpty,
          reason: 'Multi-tx block should have sibling hashes');
    });

    test('full WIF import simulation: derive address → history → raw tx → proof',
        () async {
      if (!await _isNodeReachable()) return;

      // Replicate exactly what ImportActor does

      // Step 1: derive address from WIF
      final privateKey = dartsv.SVPrivateKey.fromWIF(targetWif);
      final address = dartsv.Address.fromPublicKey(
        privateKey.publicKey,
        dartsv.NetworkType.TEST,
      ).toBase58();
      print('Step 1 — derived address: $address');

      // Step 2: get transaction history
      final history = await dataSource.getTransactionHistory(address);
      print('Step 2 — transaction history: ${history.length} txs');
      expect(history, isNotEmpty, reason: 'Must find transactions for address');

      // Step 3: for each transaction, get raw tx + merkle proof
      for (final txInfo in history) {
        print('Step 3 — importing tx ${txInfo.txid}');

        final rawHex = await dataSource.getRawTransaction(txInfo.txid);
        print('  raw tx: ${rawHex.length} hex chars');
        expect(rawHex, isNotEmpty);

        final proof = await dataSource.getMerkleProof(txInfo.txid);
        print('  proof: height=${proof.blockHeight}, '
            'index=${proof.index}, ${proof.nodes.length} siblings');
        expect(proof.blockHeight, greaterThan(0));

        // Step 4: verify TscConverter can convert to BUMP
        final converter = TscConverter();
        final bump = converter.convertToBump(proof);
        print('  BUMP: ${bump.path.length} levels, blockHeight=${bump.blockHeight}');
        expect(converter.validateBump(bump), isTrue,
            reason: 'Generated BUMP should be valid');
      }

      print('\n✅ Full WIF import simulation passed!');
    });
  });

  group('Reproduce production failure — WIF cTQt7Q...', () {
    const prodWif = 'cTQt7QmW5BnbjaHRGgf4X1H51EXTW8sT6UVSS6YsvBNDQDtKN51c';
    const expectedAddr = 'micocA8ttajyG1NihapQmxXu8FqWbKSJ79';

    test('address derivation matches', () async {
      if (!await _isNodeReachable()) return;

      final pk = dartsv.SVPrivateKey.fromWIF(prodWif);
      final addr = dartsv.Address.fromPublicKey(
        pk.publicKey,
        dartsv.NetworkType.TEST,
      ).toBase58();
      print('Expected: $expectedAddr');
      print('Derived:  $addr');
      expect(addr, equals(expectedAddr));
    });

    test('getTransactionHistory finds transactions', () async {
      if (!await _isNodeReachable()) return;

      final history = await dataSource.getTransactionHistory(expectedAddr);
      print('getTransactionHistory: ${history.length} txs');
      for (final tx in history) {
        print('  txid=${tx.txid} blockHeight=${tx.blockHeight}');
      }
      expect(history, isNotEmpty,
          reason: 'Production address should have transactions');
    });

    test('getUtxos finds UTXO', () async {
      if (!await _isNodeReachable()) return;

      final utxos = await dataSource.getUtxos(expectedAddr);
      print('getUtxos: ${utxos.length} UTXOs');
      for (final u in utxos) {
        print('  txid=${u.txid} vout=${u.vout} value=${u.value} sats');
      }
      expect(utxos, isNotEmpty,
          reason: 'Production address should have UTXOs');
    });

    test('full import simulation succeeds', () async {
      if (!await _isNodeReachable()) return;

      // Step 1: derive address
      final pk = dartsv.SVPrivateKey.fromWIF(prodWif);
      final addr = dartsv.Address.fromPublicKey(
        pk.publicKey,
        dartsv.NetworkType.TEST,
      ).toBase58();
      print('1. Address: $addr');

      // Step 2: transaction history
      final history = await dataSource.getTransactionHistory(addr);
      print('2. Transactions: ${history.length}');
      expect(history, isNotEmpty);

      // Step 3: raw tx + merkle proof for each
      for (final txInfo in history) {
        print('3. Importing ${txInfo.txid}');

        final rawHex = await dataSource.getRawTransaction(txInfo.txid);
        print('   raw: ${rawHex.length} hex chars');

        final proof = await dataSource.getMerkleProof(txInfo.txid);
        print('   proof: height=${proof.blockHeight}, '
            'index=${proof.index}, ${proof.nodes.length} siblings');

        final converter = TscConverter();
        final bump = converter.convertToBump(proof);
        print('   BUMP: ${bump.path.length} levels');
        expect(converter.validateBump(bump), isTrue);
      }

      // Step 4: UTXOs
      final utxos = await dataSource.getUtxos(addr);
      print('4. UTXOs: ${utxos.length}');
      for (final u in utxos) {
        print('   ${u.txid}:${u.vout} = ${u.value} sats');
      }
      expect(utxos, isNotEmpty);

      print('\n✅ Production WIF import simulation passed!');
    });
  });
}
