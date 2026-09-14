@Tags(['postgres', 'integration'])
library;

import 'dart:io';

import 'package:test/test.dart';

import 'package:libspiffy/src/storage/postgres/postgres_config.dart';
import 'package:libspiffy/src/storage/postgres/postgres_migrations.dart';
import 'package:libspiffy/src/storage/postgres/postgres_wallet_storage.dart';

import '../merkle_proof_delete_contract.dart';

void main() {
  final config = PostgresConfig(
    host: Platform.environment['POSTGRES_HOST'] ?? 'localhost',
    port: int.tryParse(Platform.environment['POSTGRES_PORT'] ?? '5432') ?? 5432,
    database: Platform.environment['POSTGRES_DATABASE'] ?? 'libspiffy_test',
    username: Platform.environment['POSTGRES_USER'] ?? 'postgres',
    password: Platform.environment['POSTGRES_PASSWORD'] ?? 'postgres',
    maxConnections: 2,
    enableSsl: false, // the local test server has no TLS
  );

  test('PostgresWalletStorage deletes only the named merkle proof', () async {
    await PostgresMigrations(config).migrate();
    final storage = PostgresWalletStorage(config);
    await storage.initialize();
    try {
      await runMerkleProofDeleteContract(storage, suffix: '3b');
    } finally {
      await storage.deleteMerkleProof('ab' * 31 + '3b');
      await storage.deleteMerkleProof('cd' * 31 + '3b');
      await storage.close();
    }
  });
}
