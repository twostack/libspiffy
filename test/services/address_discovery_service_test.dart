/// AddressDiscoveryService tests.
///
/// Covers audit finding KM-7 / A-L5 (doc/audit-2026-09-14.md): the xpub
/// must not be written to the log at INFO during discovery.

import 'dart:async';
import 'package:test/test.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:logging/logging.dart';

import 'package:libspiffy/src/models/address_chain.dart';
import 'package:libspiffy/src/models/blockchain_data_models.dart';
import 'package:libspiffy/src/services/address_discovery_service.dart';
import 'package:libspiffy/src/services/blockchain_data_source.dart';

void main() {
  final hdPublicKey = dartsv.HDPrivateKey.fromSeed('000102030405060708090a0b0c0d0e0f', dartsv.NetworkType.TEST).hdPublicKey;
  String receive(int i) => hdPublicKey.deriveChildKey('m/0/$i').publicKey.toAddress(dartsv.NetworkType.TEST).toString();

  group('a failed lookup is not an unused address', () {
    test('discovery stops with the error instead of ending the chain as if the gap were real', () async {
      // Used at 0 and 4; the lookups of 1..3 fail. Counted as unused, as
      // they once were, a gap of 3 would end the scan before index 4.
      final source = _ScriptedDataSource(
        used: {receive(0), receive(4)},
        failing: {receive(1), receive(2), receive(3)},
      );
      await expectLater(
        AddressDiscoveryService(source).discoverAddresses(hdPublicKey: hdPublicKey, networkType: 'test', gapLimit: 3),
        throwsA(isA<DataSourceException>().having((e) => e.address, 'address', receive(1))),
      );
    });

    test('an error that is not a DataSourceException is reported as one, naming the address', () async {
      final source = _ScriptedDataSource(used: const {}, failing: {receive(0)}, error: StateError('boom'));
      await expectLater(
        AddressDiscoveryService(source).discoverAddresses(hdPublicKey: hdPublicKey, networkType: 'test', gapLimit: 2),
        throwsA(isA<DataSourceException>()
            .having((e) => e.address, 'address', receive(0))
            .having((e) => e.originalError, 'originalError', isA<StateError>())),
      );
    });

    test('a range scan stops the same way', () async {
      final source = _ScriptedDataSource(used: {receive(0)}, failing: {receive(1)});
      await expectLater(
        AddressDiscoveryService(source).discoverAddressRange(
            hdPublicKey: hdPublicKey, networkType: 'test', chain: AddressChain.receive, startIndex: 0, endIndex: 3),
        throwsA(isA<DataSourceException>()),
      );
    });

    test('with every lookup answering, a gap wider than the limit still ends the chain', () async {
      final source = _ScriptedDataSource(used: {receive(0), receive(4)}, failing: const {});
      final result = await AddressDiscoveryService(source).discoverAddresses(hdPublicKey: hdPublicKey, networkType: 'test', gapLimit: 3);
      expect(result.usedAddresses.map((a) => a.address), [receive(0)]);
      final wider = await AddressDiscoveryService(source).discoverAddresses(hdPublicKey: hdPublicKey, networkType: 'test', gapLimit: 4);
      expect(wider.usedAddresses.map((a) => a.address), [receive(0), receive(4)]);
    });
  });

  group('KM-7: xpub is not logged', () {
    test('discoverAddresses emits no log record containing the xpub', () async {
      final hdPrivateKey = dartsv.HDPrivateKey.fromSeed(
        '000102030405060708090a0b0c0d0e0f',
        dartsv.NetworkType.TEST,
      );
      final hdPublicKey = hdPrivateKey.hdPublicKey;
      final xpub = hdPublicKey.xpubkey;
      expect(xpub, isNotEmpty);

      final records = <LogRecord>[];
      final previousLevel = Logger.root.level;
      Logger.root.level = Level.ALL;
      final subscription = Logger.root.onRecord.listen(records.add);
      try {
        final result = await AddressDiscoveryService(_EmptyDataSource())
            .discoverAddresses(
          hdPublicKey: hdPublicKey,
          networkType: 'test',
          gapLimit: 2,
        );
        expect(result.usedAddresses, isEmpty);
      } finally {
        await subscription.cancel();
        Logger.root.level = previousLevel;
      }

      final leaking = records
          .where((r) => r.message.contains(xpub))
          .map((r) => '[${r.loggerName}/${r.level.name}] ${r.message}')
          .toList();
      expect(leaking, isEmpty, reason: 'xpub found in log output');
    });
  });
}

/// History at [used] addresses, a failed lookup at [failing] ones.
class _ScriptedDataSource implements BlockchainDataSource {
  final Set<String> used;
  final Set<String> failing;
  final Object? error;
  _ScriptedDataSource({required this.used, required this.failing, this.error});

  @override
  String get networkType => 'test';

  @override
  Future<List<TransactionInfo>> getTransactionHistory(String address, {int? limit, int? offset}) async {
    if (failing.contains(address)) {
      throw error ?? DataSourceException('HTTP 429', address: address);
    }
    return used.contains(address) ? [TransactionInfo(txid: 'tx-$address', blockHeight: 100)] : const [];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('${invocation.memberName}');
}

/// Data source with no history for any address.
class _EmptyDataSource implements BlockchainDataSource {
  @override
  String get networkType => 'test';

  @override
  Future<List<TransactionInfo>> getTransactionHistory(String address,
          {int? limit, int? offset}) async =>
      const [];

  @override
  Future<String> getRawTransaction(String txid) =>
      throw DataSourceException('not found', txid: txid);

  @override
  Future<MerkleProofData> getMerkleProof(String txid) =>
      throw DataSourceException('not found', txid: txid);

  @override
  Future<List<UtxoInfo>> getUtxos(String address) async => const [];

  @override
  Future<List<AddressScriptInfo>> getAddressScripts(String address) async =>
      const [];

  @override
  Future<List<TransactionInfo>> getScriptHistory(String scriptHash,
          {int? limit, int? offset}) async =>
      const [];

  @override
  Future<int> getCurrentBlockHeight() async => 0;

  @override
  Future<String> submitTransaction(String rawTxHex) =>
      throw UnimplementedError();
}
