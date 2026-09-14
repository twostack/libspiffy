/// AddressDiscoveryService tests.
///
/// Covers audit finding KM-7 / A-L5 (doc/audit-2026-09-14.md): the xpub
/// must not be written to the log at INFO during discovery.

import 'dart:async';
import 'package:test/test.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:logging/logging.dart';

import 'package:libspiffy/src/models/blockchain_data_models.dart';
import 'package:libspiffy/src/services/address_discovery_service.dart';
import 'package:libspiffy/src/services/blockchain_data_source.dart';

void main() {
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
